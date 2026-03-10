(function(window) {
  'use strict';

  var G = window.IntuneGraph;
  var CHUNK_SIZE = 1 * 1024 * 1024; // 1 MiB (matches PowerShell)

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  function arrayBufferToBase64(buffer) {
    var bytes = new Uint8Array(buffer);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return window.btoa(binary);
  }

  function sleep(ms) {
    return new Promise(function(resolve) { setTimeout(resolve, ms); });
  }

  // ---------------------------------------------------------------------------
  // Encryption — matches PowerShell EncryptFile / EncryptFileWithIV exactly
  //
  // Encrypted file layout:  HMAC(32 bytes) + IV(16 bytes) + AES-CBC ciphertext
  //
  // HMAC-SHA256 is computed over (IV + ciphertext), i.e. everything after the
  // first 32 bytes of the output.
  // ---------------------------------------------------------------------------

  function encryptFile(file) {
    var aesKeyBytes, hmacKeyBytes, ivBytes;
    var plaintextBuffer;

    return file.arrayBuffer().then(function(buf) {
      plaintextBuffer = buf;

      // Generate random AES-256 key (32 bytes), HMAC key (32 bytes), IV (16 bytes)
      aesKeyBytes = window.crypto.getRandomValues(new Uint8Array(32));
      hmacKeyBytes = window.crypto.getRandomValues(new Uint8Array(32));
      ivBytes = window.crypto.getRandomValues(new Uint8Array(16));

      // Import AES key
      return window.crypto.subtle.importKey(
        'raw', aesKeyBytes, { name: 'AES-CBC' }, false, ['encrypt']
      );
    }).then(function(aesKey) {
      // Encrypt plaintext
      return window.crypto.subtle.encrypt(
        { name: 'AES-CBC', iv: ivBytes }, aesKey, plaintextBuffer
      );
    }).then(function(ciphertext) {
      var ciphertextBytes = new Uint8Array(ciphertext);

      // Build the IV + ciphertext portion (this is what HMAC covers)
      var ivAndCiphertext = new Uint8Array(ivBytes.length + ciphertextBytes.length);
      ivAndCiphertext.set(ivBytes, 0);
      ivAndCiphertext.set(ciphertextBytes, ivBytes.length);

      // Import HMAC key and compute HMAC-SHA256 over (IV + ciphertext)
      return window.crypto.subtle.importKey(
        'raw', hmacKeyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
      ).then(function(hmacKey) {
        return window.crypto.subtle.sign('HMAC', hmacKey, ivAndCiphertext);
      }).then(function(hmacSig) {
        var hmacBytes = new Uint8Array(hmacSig);

        // Assemble encrypted file: HMAC(32) + IV(16) + ciphertext
        var encryptedData = new Uint8Array(hmacBytes.length + ivAndCiphertext.length);
        encryptedData.set(hmacBytes, 0);
        encryptedData.set(ivAndCiphertext, hmacBytes.length);

        // Compute SHA-256 digest of the original plaintext
        return window.crypto.subtle.digest('SHA-256', plaintextBuffer).then(function(digestBuf) {
          var fileDigestBytes = new Uint8Array(digestBuf);

          // Build encryptionInfo — single base64 of raw key bytes (matches PowerShell)
          var encryptionInfo = {
            encryptionKey: arrayBufferToBase64(aesKeyBytes.buffer),
            macKey: arrayBufferToBase64(hmacKeyBytes.buffer),
            initializationVector: arrayBufferToBase64(ivBytes.buffer),
            mac: arrayBufferToBase64(hmacBytes.buffer),
            fileDigest: arrayBufferToBase64(fileDigestBytes.buffer),
            fileDigestAlgorithm: 'SHA256',
            profileIdentifier: 'ProfileVersion1'
          };

          return {
            encryptedData: encryptedData,
            encryptionInfo: encryptionInfo,
            sizeOriginal: plaintextBuffer.byteLength,
            sizeEncrypted: encryptedData.byteLength
          };
        });
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Chunked Azure Blob Upload
  //
  // Block IDs: zero-padded 8-char string prefixed with "block-", then base64
  // encoded.  PUT each block, then commit with XML block list.
  // ---------------------------------------------------------------------------

  function uploadToAzure(sasUri, encryptedData, onProgress) {
    var totalSize = encryptedData.byteLength;
    var chunkCount = Math.ceil(totalSize / CHUNK_SIZE);
    var blockIds = [];

    function uploadChunk(index) {
      if (index >= chunkCount) {
        return finalizeUpload(sasUri, blockIds);
      }

      var start = index * CHUNK_SIZE;
      var end = Math.min(start + CHUNK_SIZE, totalSize);
      var chunk = encryptedData.slice(start, end);

      // Block ID: zero-padded 4-char index, then base64 encoded (matches PowerShell)
      var rawId = ('0000' + index).slice(-4);
      var blockId = window.btoa(rawId);
      blockIds.push(blockId);

      var url = sasUri + '&comp=block&blockid=' + encodeURIComponent(blockId);

      return G.rawPut(url, chunk, {
        'x-ms-blob-type': 'BlockBlob',
        'Content-Type': 'application/octet-stream'
      }).then(function() {
        if (onProgress) {
          var pct = Math.round(((index + 1) / chunkCount) * 100);
          onProgress('uploading', pct);
        }
        return uploadChunk(index + 1);
      });
    }

    return uploadChunk(0);
  }

  function finalizeUpload(sasUri, blockIds) {
    var xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>';
    for (var i = 0; i < blockIds.length; i++) {
      xml += '<Latest>' + blockIds[i] + '</Latest>';
    }
    xml += '</BlockList>';

    var url = sasUri + '&comp=blocklist';
    return G.rawPut(url, xml, { 'Content-Type': 'text/plain' });
  }

  // ---------------------------------------------------------------------------
  // Polling helpers
  // ---------------------------------------------------------------------------

  function pollFileState(fileUri, targetState, maxAttempts) {
    maxAttempts = maxAttempts || 60;
    var attempt = 0;
    var successState = targetState + 'Success';
    var pendingState = targetState + 'Pending';

    function poll() {
      return G.graphRequest('GET', fileUri).then(function(file) {
        if (file.uploadState === successState) {
          return file;
        }
        if (file.uploadState !== pendingState) {
          throw new Error('Unexpected upload state: ' + file.uploadState);
        }
        attempt++;
        if (attempt >= maxAttempts) {
          throw new Error('Polling timed out waiting for ' + successState);
        }
        return sleep(1000).then(poll);
      });
    }

    return poll();
  }

  // ---------------------------------------------------------------------------
  // Full Upload Flow
  // ---------------------------------------------------------------------------

  function uploadPkg(appInfo, file, onProgress) {
    var mobileAppId, contentVersionId, contentVersionFileId;
    var encResult;

    function progress(stage, pct) {
      if (onProgress) onProgress(stage, pct);
    }

    // Step 1: Create the app
    progress('creating_app', 0);

    var appBody = {
      '@odata.type': '#microsoft.graph.macOSPkgApp',
      displayName: appInfo.displayName,
      publisher: appInfo.publisher || '',
      description: appInfo.description || appInfo.displayName,
      fileName: file.name,
      primaryBundleId: appInfo.primaryBundleId,
      primaryBundleVersion: appInfo.primaryBundleVersion,
      includedApps: (appInfo.includedApps || []).map(function(a) {
        return {
          '@odata.type': '#microsoft.graph.macOSIncludedApp',
          bundleId: a.bundleId,
          bundleVersion: a.bundleVersion
        };
      }),
      ignoreVersionDetection: true,
      minimumSupportedOperatingSystem: { v10_13: true },
      isFeatured: false,
      categories: [],
      informationUrl: '',
      privacyInformationUrl: '',
      developer: '',
      notes: '',
      owner: ''
    };

    return G.graphRequest('POST', '/deviceAppManagement/mobileApps', appBody)
      .then(function(app) {
        mobileAppId = app.id;
        progress('creating_app', 50);

        // Step 2: Create content version
        return G.graphRequest(
          'POST',
          '/deviceAppManagement/mobileApps/' + mobileAppId + '/microsoft.graph.macOSPkgApp/contentVersions',
          {}
        );
      })
      .then(function(cv) {
        contentVersionId = cv.id;
        progress('creating_app', 100);

        // Step 3: Encrypt the file
        progress('encrypting', 0);
        return encryptFile(file);
      })
      .then(function(result) {
        encResult = result;
        progress('encrypting', 100);

        // Step 4: Create content file
        var fileBody = {
          '@odata.type': '#microsoft.graph.mobileAppContentFile',
          name: file.name,
          size: encResult.sizeOriginal,
          sizeEncrypted: encResult.sizeEncrypted,
          manifest: null,
          isDependency: false
        };

        return G.graphRequest(
          'POST',
          '/deviceAppManagement/mobileApps/' + mobileAppId +
            '/microsoft.graph.macOSPkgApp/contentVersions/' + contentVersionId + '/files',
          fileBody
        );
      })
      .then(function(cf) {
        contentVersionFileId = cf.id;

        // Step 5: Poll for SAS URI
        var fileUri = '/deviceAppManagement/mobileApps/' + mobileAppId +
          '/microsoft.graph.macOSPkgApp/contentVersions/' + contentVersionId +
          '/files/' + contentVersionFileId;

        return pollFileState(fileUri, 'azureStorageUriRequest');
      })
      .then(function(fileWithSas) {
        // Step 6: Upload encrypted data to Azure
        progress('uploading', 0);
        return uploadToAzure(fileWithSas.azureStorageUri, encResult.encryptedData, onProgress);
      })
      .then(function() {
        progress('uploading', 100);

        // Step 7: Commit the file with encryption info
        progress('committing', 0);
        var commitBody = {
          fileEncryptionInfo: encResult.encryptionInfo
        };

        return G.graphRequest(
          'POST',
          '/deviceAppManagement/mobileApps/' + mobileAppId +
            '/microsoft.graph.macOSPkgApp/contentVersions/' + contentVersionId +
            '/files/' + contentVersionFileId + '/commit',
          commitBody
        );
      })
      .then(function() {
        // Step 8: Poll for commit success
        var fileUri = '/deviceAppManagement/mobileApps/' + mobileAppId +
          '/microsoft.graph.macOSPkgApp/contentVersions/' + contentVersionId +
          '/files/' + contentVersionFileId;

        return pollFileState(fileUri, 'commitFile');
      })
      .then(function() {
        progress('committing', 50);

        // Step 9: Patch the app with committed content version
        var patchBody = {
          '@odata.type': '#microsoft.graph.macOSPkgApp',
          committedContentVersion: '1'
        };

        return G.graphRequest(
          'PATCH',
          '/deviceAppManagement/mobileApps/' + mobileAppId,
          patchBody
        );
      })
      .then(function() {
        progress('committing', 100);

        // Step 10: Wait then verify published state (matches PowerShell)
        progress('verifying', 0);
        return sleep(5000).then(function() {
          return G.graphRequest('GET', '/deviceAppManagement/mobileApps/' + mobileAppId);
        });
      })
      .then(function(app) {
        if (app && app.publishingState === 'published') {
          progress('done', 100);
          return { id: mobileAppId };
        }
        // Not published yet — poll a few more times
        var verifyAttempt = 0;
        function verifyPoll() {
          return sleep(3000).then(function() {
            return G.graphRequest('GET', '/deviceAppManagement/mobileApps/' + mobileAppId);
          }).then(function(a) {
            if (a && a.publishingState === 'published') {
              progress('done', 100);
              return { id: mobileAppId };
            }
            verifyAttempt++;
            if (verifyAttempt >= 10) {
              throw new Error('App not published after waiting (state: ' + (a && a.publishingState) + ')');
            }
            progress('verifying', Math.round((verifyAttempt / 10) * 100));
            return verifyPoll();
          });
        }
        return verifyPoll();
      });
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  window.IntunePkgUpload = {
    uploadPkg: uploadPkg,
    encryptFile: encryptFile
  };

})(window);
