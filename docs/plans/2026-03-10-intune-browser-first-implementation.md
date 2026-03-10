# Intune Browser-First Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move all Intune operations from the Swift agent + PowerShell to browser JavaScript, leaving the agent as an auth-only broker.

**Architecture:** Agent handles Connect-MgGraph and exposes a `/token` endpoint. Browser JS does everything else: pkg parsing (pkgparser-REAL.js), Graph API calls (fetch + token), AES-CBC encryption, chunked Azure blob upload (adapted from extracted Intune portal JS), prerequisites, configs, scripts, groups, and assignments.

**Tech Stack:** Swift (agent), JavaScript (browser), Microsoft Graph REST API, Web Crypto API (via msrCrypto polyfill from Intune JS), pako (inflate, bundled in pkgparser-REAL.js)

**Reference files (extracted from Intune portal by Cowork):**
- `scripts/pkgparser-REAL.js` — XAR parser, plist parser, `pkgparse()` entry point
- `scripts/GOdg3ZqF15tj-Encrypt-Upload-Commit.js` — `Encryption` class (AES-CBC + HMAC), `AsyncIntuneAppFileUploader`
- `scripts/vTbU1h-51IZv-FileUpload-BlockBlob.js` — `FileReaderHelper`, block blob upload protocol
- `scripts/BZ7Vuy4PV5pR-IntuneAppFileUpload-orchestrator.js` — RPC endpoint definitions
- `scripts/Rk5Zr_wzls2b-IntuneZipFileHelper.js` — Zip archive reader helpers
- `scripts/NgXJAz2UaHm1-inflate-binary.js` — `_oss/zip` library (zip read/write)

**Design doc:** `docs/plans/2026-03-10-intune-browser-first-refactor-design.md`

---

### Task 1: Strip Agent to Auth-Only

**Files:**
- Modify: `agent/Sources/MacAdminToolbox/main.swift` (lines 596-1408)

**Step 1: Simplify state struct**

Replace the current `IntuneState` struct (lines 610-636) with a minimal auth-only version:

```swift
struct IntuneState {
    var connected: Bool = false
    var tenantId: String = ""
    var tenantName: String = ""
    var userEmail: String = ""
    var operation: String = "idle" // idle, connecting, connected
    var error: String = ""
}
```

Remove: `ProgressItem`, `ItemStatus`, `operationLog`, `progressItems`, all operation-related state fields.

**Step 2: Simplify handleConnect (line 949)**

Keep the flow: install PowerShell → install `Microsoft.Graph.Authentication` only → start PS session → `Connect-MgGraph` → extract tenant info. Remove all other module installs from `installGraphModuleIfNeeded()` (line 744). The only module needed is `Microsoft.Graph.Authentication`.

In `installGraphModuleIfNeeded()`, change the module list to only:
```swift
let modules = ["Microsoft.Graph.Authentication"]
```

**Step 3: Add /token endpoint**

Add a new handler that extracts the current access token from the PowerShell session:

```swift
func handleToken(respond: @escaping (Data) -> Void) {
    guard intuneState.connected else {
        let err = try! JSONSerialization.data(withJSONObject: ["error": "not connected"])
        respond(err)
        return
    }
    runPSCommand("(Get-MgContext).AccessToken") { output in
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty || token.contains("Error") {
            let err = try! JSONSerialization.data(withJSONObject: ["error": "no token available"])
            respond(err)
        } else {
            let result = try! JSONSerialization.data(withJSONObject: [
                "token": token,
                "tenantId": intuneState.tenantId,
                "tenantName": intuneState.tenantName
            ])
            respond(result)
        }
    }
}
```

Note: `Get-MgContext` may not expose `.AccessToken` directly in all versions. If not, use:
```powershell
(Get-MgContext | ConvertTo-Json -Depth 5)
```
and extract the token from the JSON. Alternatively, use the MSAL token cache approach:
```powershell
$context = Get-MgContext
[Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.AuthContext.AcquireTokenSilent(
    [string[]]@($context.Scopes),
    $context.Account
).ExecuteAsync().Result.AccessToken
```

Test which approach works during implementation and use the one that reliably returns the token.

**Step 4: Remove unused endpoints**

Remove handlers and route cases for:
- `/prerequisites` (line 1353)
- `/upload` (line 1360)
- `/upload-file` (line 1367)
- `/progress` (line 1342)

Remove the functions:
- `handlePrerequisites()` and all prerequisite logic
- `handleUpload()` and all upload logic
- `handleUploadFile()` and all custom file upload logic

**Step 5: Update route switch**

In `handleIntuneRequest` (line 1337), the routes should be:
```swift
switch (method, path) {
case ("GET", "/status"):
    // return connection state + tenant info
case ("POST", "/connect"):
    handleConnect(respond: respond)
case ("GET", "/token"):
    handleToken(respond: respond)
case ("POST", "/disconnect"):
    handleDisconnect(respond: respond)
default:
    // 404
}
```

**Step 6: Remove IntuneBaseBuild.psm1 dependency**

In the connect flow, remove all references to loading `IntuneBaseBuild.psm1`. The agent no longer needs any custom PowerShell module — only the `Microsoft.Graph.Authentication` module.

Remove from `agent/Resources/` the `IntuneBaseBuild.psm1` and `IntuneBaseBuild.psd1` files (or leave them but stop loading them). The S3 download of these files in the connect flow should also be removed.

**Step 7: Verify and commit**

Build the agent: `cd agent && swift build`
Test manually: launch agent, hit `/connect`, authenticate, then `GET /token` should return a bearer token.

```bash
git add agent/Sources/MacAdminToolbox/main.swift
git commit -m "refactor: strip Intune agent to auth-only broker with /token endpoint"
```

---

### Task 2: Create Browser Graph API Client Module

**Files:**
- Create: `app/static/js/intune-graph-client.js`

**Step 1: Write the Graph API client**

This module handles token fetching from the agent and provides a clean interface for Graph API calls.

```javascript
/**
 * Intune Graph API Client
 * Fetches token from local agent, makes Graph API calls via fetch().
 */
(function(window) {
  'use strict';

  var AGENT_PORT = 8765;
  var AGENT_BASE = 'http://127.0.0.1:' + AGENT_PORT;
  var GRAPH_BASE = 'https://graph.microsoft.com';

  var _cachedToken = null;

  /** Fetch a fresh token from the agent */
  function getToken() {
    return fetch(AGENT_BASE + '/token', { mode: 'cors' })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        if (data.error) throw new Error(data.error);
        _cachedToken = data.token;
        return data.token;
      });
  }

  /** Make a Graph API request */
  function graphRequest(method, endpoint, body, apiVersion) {
    apiVersion = apiVersion || 'beta';
    return getToken().then(function(token) {
      var url = GRAPH_BASE + '/' + apiVersion + endpoint;
      var opts = {
        method: method,
        headers: {
          'Authorization': 'Bearer ' + token,
          'Content-Type': 'application/json'
        }
      };
      if (body && (method === 'POST' || method === 'PATCH' || method === 'PUT')) {
        opts.body = JSON.stringify(body);
      }
      return fetch(url, opts).then(function(r) {
        if (r.status === 204) return null;
        return r.json().then(function(data) {
          if (!r.ok) throw new Error(data.error ? data.error.message : 'Graph API error ' + r.status);
          return data;
        });
      });
    });
  }

  /** Agent request (connect, status, disconnect) */
  function agentRequest(method, path, body) {
    var opts = { method: method, mode: 'cors', headers: { 'Content-Type': 'application/json' } };
    if (body) opts.body = JSON.stringify(body);
    return fetch(AGENT_BASE + path, opts).then(function(r) { return r.json(); });
  }

  /** Upload raw bytes to a URL (for Azure blob) with custom headers */
  function rawPut(url, data, headers) {
    return fetch(url, {
      method: 'PUT',
      headers: headers || {},
      body: data
    }).then(function(r) {
      if (!r.ok) throw new Error('Upload failed: ' + r.status);
      return r;
    });
  }

  window.IntuneGraph = {
    getToken: getToken,
    graphRequest: graphRequest,
    agentRequest: agentRequest,
    rawPut: rawPut,
    GRAPH_BASE: GRAPH_BASE
  };
})(window);
```

**Step 2: Commit**

```bash
git add app/static/js/intune-graph-client.js
git commit -m "feat: add browser-side Graph API client module"
```

---

### Task 3: Create Browser Intune Operations Module

**Files:**
- Create: `app/static/js/intune-operations.js`

**Step 1: Write the operations module**

This wraps all Graph API calls for prerequisites, configs, scripts, groups, assignments.

```javascript
/**
 * Intune Operations - all Graph API calls for base build.
 * Depends on: intune-graph-client.js (window.IntuneGraph)
 */
(function(window) {
  'use strict';

  var G = window.IntuneGraph;

  // ─── PREREQUISITES ───

  function checkAPNs() {
    return G.graphRequest('GET', '/deviceManagement/applePushNotificationCertificate')
      .then(function(data) { return { status: 'success', message: 'APNs certificate found', data: data }; })
      .catch(function(e) { return { status: 'fail', message: 'No APNs certificate: ' + e.message }; });
  }

  function checkABM() {
    return G.graphRequest('GET', '/deviceManagement/depOnboardingSettings')
      .then(function(data) {
        var tokens = data.value || [];
        return tokens.length > 0
          ? { status: 'success', message: tokens.length + ' ABM token(s) found', data: tokens }
          : { status: 'fail', message: 'No ABM tokens configured' };
      });
  }

  function checkVPP() {
    return G.graphRequest('GET', '/deviceAppManagement/vppTokens', null, 'v1.0')
      .then(function(data) {
        var tokens = data.value || [];
        return tokens.length > 0
          ? { status: 'success', message: tokens.length + ' VPP token(s) found', data: tokens }
          : { status: 'fail', message: 'No VPP tokens configured' };
      });
  }

  // ─── GROUPS ───

  function findGroup(displayName) {
    return G.graphRequest('GET', "/groups?$filter=displayName eq '" + encodeURIComponent(displayName) + "'", null, 'v1.0')
      .then(function(data) { return (data.value || [])[0] || null; });
  }

  function createGroup(displayName) {
    var nick = displayName.replace(/[^a-zA-Z0-9]/g, '') + Math.random().toString(36).substring(2, 8);
    return G.graphRequest('POST', '/groups', {
      displayName: displayName,
      description: 'iStore Business PoC Group',
      mailEnabled: false,
      mailNickname: nick,
      securityEnabled: true,
      groupTypes: []
    }, 'v1.0');
  }

  function ensureGroup(displayName) {
    return findGroup(displayName).then(function(group) {
      return group || createGroup(displayName);
    });
  }

  function findUser(upn) {
    return G.graphRequest('GET', "/users?$filter=userPrincipalName eq '" + encodeURIComponent(upn) + "'", null, 'v1.0')
      .then(function(data) { return (data.value || [])[0] || null; });
  }

  function addGroupMember(groupId, userId) {
    return G.graphRequest('POST', '/groups/' + groupId + '/members/$ref', {
      '@odata.id': 'https://graph.microsoft.com/v1.0/directoryObjects/' + userId
    }, 'v1.0').catch(function(e) {
      // Ignore "already a member" errors
      if (e.message && e.message.indexOf('already exist') !== -1) return null;
      throw e;
    });
  }

  // ─── CONFIGS & SCRIPTS ───

  function createMobileConfig(displayName, fileName, payloadBase64, platform) {
    var odataType = platform === 'ios'
      ? '#microsoft.graph.iosCustomConfiguration'
      : '#microsoft.graph.macOSCustomConfiguration';
    return G.graphRequest('POST', '/deviceManagement/deviceConfigurations', {
      '@odata.type': odataType,
      deploymentChannel: 'deviceChannel',
      payload: payloadBase64,
      payloadFileName: fileName,
      payloadName: displayName,
      displayName: displayName,
      description: 'Custom ' + (platform === 'ios' ? 'iOS' : 'macOS') + ' Configuration ' + displayName
    });
  }

  function createSettingsCatalog(policyJson) {
    return G.graphRequest('POST', '/deviceManagement/configurationPolicies', policyJson);
  }

  function createShellScript(displayName, fileName, scriptContentBase64) {
    return G.graphRequest('POST', '/deviceManagement/deviceShellScripts', {
      '@odata.type': '#microsoft.graph.deviceShellScript',
      retryCount: 10,
      blockExecutionNotifications: true,
      displayName: displayName,
      scriptContent: scriptContentBase64,
      runAsAccount: 'system',
      fileName: fileName
    });
  }

  function createCustomAttribute(displayName, description, fileName, scriptContentBase64) {
    return G.graphRequest('POST', '/deviceManagement/deviceCustomAttributeShellScripts', {
      '@odata.type': '#microsoft.graph.deviceCustomAttributeShellScript',
      customAttributeName: displayName,
      customAttributeType: 'string',
      displayName: displayName,
      description: description || '',
      scriptContent: scriptContentBase64,
      runAsAccount: 'system',
      fileName: fileName
    });
  }

  // ─── ENROLLMENT PROFILE ───

  function getDepSettings() {
    return G.graphRequest('GET', '/deviceManagement/depOnboardingSettings')
      .then(function(data) { return data.value || []; });
  }

  function createEnrollmentProfile(depSettingId, profileBody) {
    return G.graphRequest('POST',
      '/deviceManagement/depOnboardingSettings/' + depSettingId + '/enrollmentProfiles',
      profileBody);
  }

  // ─── FILEVAULT ───

  function createFileVault(policyJson) {
    return G.graphRequest('POST', '/deviceManagement/configurationPolicies', policyJson);
  }

  // ─── ASSIGNMENTS ───

  function assignApp(appId, groupId, intent) {
    intent = intent || 'required';
    return G.graphRequest('POST', '/deviceAppManagement/mobileApps/' + appId + '/assign', {
      mobileAppAssignments: [{
        '@odata.type': '#microsoft.graph.mobileAppAssignment',
        intent: intent,
        settings: null,
        target: {
          '@odata.type': '#microsoft.graph.groupAssignmentTarget',
          groupId: groupId
        }
      }]
    });
  }

  function assignConfig(configId, groupId) {
    return G.graphRequest('POST', '/deviceManagement/deviceConfigurations/' + configId + '/assign', {
      assignments: [{
        target: { '@odata.type': '#microsoft.graph.groupAssignmentTarget', groupId: groupId }
      }]
    });
  }

  function assignScript(scriptId, groupId) {
    return G.graphRequest('POST', '/deviceManagement/deviceShellScripts/' + scriptId + '/assign', {
      deviceManagementScriptAssignments: [{
        '@odata.type': '#microsoft.graph.deviceManagementScriptAssignment',
        target: {
          '@odata.type': '#microsoft.graph.groupAssignmentTarget',
          deviceAndAppManagementAssignmentFilterId: null,
          deviceAndAppManagementAssignmentFilterType: 'none',
          groupId: groupId
        }
      }]
    });
  }

  function assignCustomAttribute(scriptId, groupId) {
    return G.graphRequest('POST', '/deviceManagement/deviceCustomAttributeShellScripts/' + scriptId + '/assign', {
      deviceManagementScriptAssignments: [{
        '@odata.type': '#microsoft.graph.deviceManagementScriptAssignment',
        target: {
          '@odata.type': '#microsoft.graph.groupAssignmentTarget',
          deviceAndAppManagementAssignmentFilterId: null,
          deviceAndAppManagementAssignmentFilterType: 'none',
          groupId: groupId
        }
      }]
    });
  }

  function assignSettingsCatalog(policyId, groupId) {
    return G.graphRequest('POST', '/deviceManagement/configurationPolicies/' + policyId + '/assign', {
      assignments: [{
        target: { '@odata.type': '#microsoft.graph.groupAssignmentTarget', groupId: groupId }
      }]
    });
  }

  window.IntuneOps = {
    // Prerequisites
    checkAPNs: checkAPNs,
    checkABM: checkABM,
    checkVPP: checkVPP,
    // Groups
    findGroup: findGroup,
    createGroup: createGroup,
    ensureGroup: ensureGroup,
    findUser: findUser,
    addGroupMember: addGroupMember,
    // Configs
    createMobileConfig: createMobileConfig,
    createSettingsCatalog: createSettingsCatalog,
    createShellScript: createShellScript,
    createCustomAttribute: createCustomAttribute,
    // Enrollment
    getDepSettings: getDepSettings,
    createEnrollmentProfile: createEnrollmentProfile,
    createFileVault: createFileVault,
    // Assignments
    assignApp: assignApp,
    assignConfig: assignConfig,
    assignScript: assignScript,
    assignCustomAttribute: assignCustomAttribute,
    assignSettingsCatalog: assignSettingsCatalog
  };
})(window);
```

**Step 2: Commit**

```bash
git add app/static/js/intune-operations.js
git commit -m "feat: add browser-side Intune operations module (prereqs, configs, groups, assignments)"
```

---

### Task 4: Create Browser PKG Upload Module

**Files:**
- Create: `app/static/js/intune-pkg-upload.js`

**Reference:** `scripts/GOdg3ZqF15tj-Encrypt-Upload-Commit.js` for the encryption + upload flow

**Step 1: Write the pkg upload module**

This adapts the extracted Intune encryption and upload code into a standalone module. Rather than using the minified Intune source directly (which depends on Azure Portal framework globals like `MsPortalFx`, `ko`, `FxImpl`), we rewrite the core logic using the same algorithms but with standard Web APIs.

```javascript
/**
 * Intune PKG Upload - AES-CBC encryption + chunked Azure blob upload.
 * Adapted from Intune portal source (Encrypt-Upload-Commit.js).
 * Depends on: intune-graph-client.js (window.IntuneGraph)
 */
(function(window) {
  'use strict';

  var G = window.IntuneGraph;
  var CHUNK_SIZE = 6 * 1024 * 1024; // 6MB chunks (Intune default)

  // ─── ENCRYPTION (mirrors Services.IntuneAppEncrypt) ───

  function generateEncryptionKeys() {
    var crypto = window.crypto;
    return Promise.all([
      crypto.subtle.generateKey({ name: 'AES-CBC', length: 256 }, true, ['encrypt']),
      crypto.subtle.generateKey({ name: 'HMAC', hash: 'SHA-256' }, true, ['sign'])
    ]).then(function(keys) {
      var iv = crypto.getRandomValues(new Uint8Array(16));
      return { aesKey: keys[0], hmacKey: keys[1], iv: iv };
    });
  }

  function exportKeyBase64(key) {
    return window.crypto.subtle.exportKey('raw', key).then(function(raw) {
      return btoa(String.fromCharCode.apply(null, new Uint8Array(raw)));
    });
  }

  function encryptFile(file, onProgress) {
    return generateEncryptionKeys().then(function(keys) {
      var reader = file.stream().getReader();
      var encryptedChunks = [];
      var sha256Chunks = [];
      var hmacChunks = [];
      var totalRead = 0;
      var fileSize = file.size;

      // We need streaming encryption. AES-CBC in Web Crypto doesn't support
      // streaming natively, so we process in chunks and handle padding manually.
      // Simpler approach: read entire file, encrypt in one shot (works for files
      // up to a few GB with enough memory).
      return file.arrayBuffer().then(function(plainBuffer) {
        var plainBytes = new Uint8Array(plainBuffer);

        // SHA-256 hash of plaintext
        return window.crypto.subtle.digest('SHA-256', plainBytes).then(function(hashBuffer) {
          var fileDigest = btoa(String.fromCharCode.apply(null, new Uint8Array(hashBuffer)));

          // Encrypt with AES-CBC
          return window.crypto.subtle.encrypt(
            { name: 'AES-CBC', iv: keys.iv },
            keys.aesKey,
            plainBytes
          ).then(function(encryptedBuffer) {
            var encryptedBytes = new Uint8Array(encryptedBuffer);

            // HMAC of IV + encrypted data
            var hmacInput = new Uint8Array(keys.iv.byteLength + encryptedBytes.byteLength);
            hmacInput.set(keys.iv, 0);
            hmacInput.set(encryptedBytes, keys.iv.byteLength);

            return window.crypto.subtle.sign('HMAC', keys.hmacKey, hmacInput).then(function(hmacBuffer) {
              var hmacBytes = new Uint8Array(hmacBuffer);
              var hmac = btoa(String.fromCharCode.apply(null, hmacBytes));

              // Build final encrypted file: HMAC(32) + IV(16) + encrypted data
              var finalFile = new Uint8Array(hmacBytes.byteLength + keys.iv.byteLength + encryptedBytes.byteLength);
              finalFile.set(hmacBytes, 0);
              finalFile.set(keys.iv, hmacBytes.byteLength);
              finalFile.set(encryptedBytes, hmacBytes.byteLength + keys.iv.byteLength);

              return Promise.all([
                exportKeyBase64(keys.aesKey),
                exportKeyBase64(keys.hmacKey)
              ]).then(function(exportedKeys) {
                return {
                  encryptedData: finalFile,
                  encryptedSize: finalFile.byteLength,
                  encryptionInfo: {
                    encryptionKey: btoa(exportedKeys[0]),
                    macKey: btoa(exportedKeys[1]),
                    initializationVector: btoa(String.fromCharCode.apply(null, keys.iv)),
                    mac: hmac,
                    fileDigest: fileDigest,
                    fileDigestAlgorithm: 'SHA256',
                    profileIdentifier: 'ProfileVersion1'
                  }
                };
              });
            });
          });
        });
      });
    });
  }

  // ─── CHUNKED AZURE BLOB UPLOAD ───

  function generateBlockId(index) {
    var id = '' + index;
    while (id.length < 8) id = '0' + id;
    return btoa('block-' + id);
  }

  function uploadToAzureBlob(sasUri, encryptedData, onProgress) {
    var blockIds = [];
    var totalChunks = Math.ceil(encryptedData.byteLength / CHUNK_SIZE);
    var uploaded = 0;

    function uploadBlock(index) {
      if (index >= totalChunks) return commitBlocks();
      var start = index * CHUNK_SIZE;
      var end = Math.min(start + CHUNK_SIZE, encryptedData.byteLength);
      var chunk = encryptedData.slice(start, end);
      var blockId = generateBlockId(index);
      blockIds.push(blockId);

      var blockUrl = sasUri + '&comp=block&blockid=' + encodeURIComponent(blockId);
      return G.rawPut(blockUrl, chunk, { 'x-ms-blob-type': 'BlockBlob' })
        .then(function() {
          uploaded++;
          if (onProgress) onProgress(uploaded / totalChunks);
          return uploadBlock(index + 1);
        });
    }

    function commitBlocks() {
      var xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>';
      for (var i = 0; i < blockIds.length; i++) {
        xml += '<Latest>' + blockIds[i] + '</Latest>';
      }
      xml += '</BlockList>';
      var commitUrl = sasUri + '&comp=blocklist';
      return G.rawPut(commitUrl, xml, {
        'x-ms-blob-content-type': 'application/octet-stream'
      });
    }

    return uploadBlock(0);
  }

  // ─── FULL PKG UPLOAD FLOW ───

  /**
   * Upload a .pkg to Intune. Full flow:
   * 1. Create mobile app entry
   * 2. Create content version
   * 3. Encrypt file
   * 4. Create content file (get SAS URI)
   * 5. Upload encrypted data to Azure blob
   * 6. Commit file with encryption info
   * 7. Patch app with committed content version
   *
   * @param {Object} appInfo - { displayName, publisher, description, fileName,
   *                             primaryBundleId, primaryBundleVersion, includedApps }
   * @param {File} file - the .pkg File object
   * @param {Function} onProgress - callback(stage, percent)
   * @returns {Promise<Object>} - the created app object
   */
  function uploadPkg(appInfo, file, onProgress) {
    var appId, contentVersionId, fileId, sasUri;

    function progress(stage, pct) {
      if (onProgress) onProgress(stage, pct);
    }

    // Step 1: Create the app
    progress('creating_app', 0);
    return G.graphRequest('POST', '/deviceAppManagement/mobileApps', {
      '@odata.type': '#microsoft.graph.macOSPkgApp',
      displayName: appInfo.displayName,
      publisher: appInfo.publisher || '',
      description: appInfo.description || appInfo.displayName,
      fileName: appInfo.fileName || file.name,
      primaryBundleId: appInfo.primaryBundleId,
      primaryBundleVersion: appInfo.primaryBundleVersion,
      includedApps: (appInfo.includedApps || [{ bundleId: appInfo.primaryBundleId, bundleVersion: appInfo.primaryBundleVersion }]).map(function(a) {
        return { '@odata.type': 'microsoft.graph.macOSIncludedApp', bundleId: a.bundleId, bundleVersion: a.bundleVersion };
      }),
      ignoreVersionDetection: true,
      minimumSupportedOperatingSystem: { v10_13: true },
      informationUrl: '', privacyInformationUrl: '', developer: '', notes: '', owner: '',
      isFeatured: false, categories: [],
      preInstallScript: appInfo.preInstallScript ? { scriptContent: appInfo.preInstallScript } : null,
      postInstallScript: appInfo.postInstallScript ? { scriptContent: appInfo.postInstallScript } : null
    }).then(function(app) {
      appId = app.id;
      progress('creating_version', 0.05);

      // Step 2: Create content version
      return G.graphRequest('POST',
        '/deviceAppManagement/mobileApps/' + appId + '/microsoft.graph.macOSPkgApp/contentVersions', {});
    }).then(function(version) {
      contentVersionId = version.id;
      progress('encrypting', 0.1);

      // Step 3: Encrypt file
      return encryptFile(file, function(pct) { progress('encrypting', 0.1 + pct * 0.3); });
    }).then(function(encrypted) {
      progress('creating_file', 0.4);

      // Step 4: Create content file
      return G.graphRequest('POST',
        '/deviceAppManagement/mobileApps/' + appId + '/microsoft.graph.macOSPkgApp/contentVersions/' + contentVersionId + '/files', {
        '@odata.type': '#microsoft.graph.mobileAppContentFile',
        name: file.name,
        size: file.size,
        sizeEncrypted: encrypted.encryptedSize,
        manifest: null,
        isDependency: false
      }).then(function(contentFile) {
        fileId = contentFile.id;

        // Step 4b: Poll for SAS URI
        return pollForSasUri(appId, contentVersionId, fileId).then(function(uri) {
          sasUri = uri;
          progress('uploading', 0.45);

          // Step 5: Upload to Azure
          return uploadToAzureBlob(sasUri, encrypted.encryptedData, function(pct) {
            progress('uploading', 0.45 + pct * 0.4);
          });
        }).then(function() {
          progress('committing', 0.85);

          // Step 6: Commit file
          return G.graphRequest('POST',
            '/deviceAppManagement/mobileApps/' + appId + '/microsoft.graph.macOSPkgApp/contentVersions/' + contentVersionId + '/files/' + fileId + '/commit', {
            fileEncryptionInfo: encrypted.encryptionInfo
          });
        });
      });
    }).then(function() {
      // Step 6b: Poll for commit completion
      return pollForCommit(appId, contentVersionId, fileId);
    }).then(function() {
      progress('finalizing', 0.95);

      // Step 7: Patch app
      return G.graphRequest('PATCH', '/deviceAppManagement/mobileApps/' + appId, {
        '@odata.type': '#microsoft.graph.macOSPkgApp',
        committedContentVersion: '' + contentVersionId
      });
    }).then(function() {
      progress('done', 1);
      return { id: appId };
    });
  }

  function pollForSasUri(appId, versionId, fileId) {
    var url = '/deviceAppManagement/mobileApps/' + appId +
              '/microsoft.graph.macOSPkgApp/contentVersions/' + versionId +
              '/files/' + fileId;
    return new Promise(function(resolve, reject) {
      var attempts = 0;
      function check() {
        attempts++;
        if (attempts > 60) return reject(new Error('Timed out waiting for SAS URI'));
        G.graphRequest('GET', url).then(function(data) {
          if (data.uploadState === 'azureStorageUriRequestSuccess' && data.azureStorageUri) {
            resolve(data.azureStorageUri);
          } else if (data.uploadState && data.uploadState.indexOf('Fail') !== -1) {
            reject(new Error('SAS URI request failed: ' + data.uploadState));
          } else {
            setTimeout(check, 2000);
          }
        }).catch(reject);
      }
      check();
    });
  }

  function pollForCommit(appId, versionId, fileId) {
    var url = '/deviceAppManagement/mobileApps/' + appId +
              '/microsoft.graph.macOSPkgApp/contentVersions/' + versionId +
              '/files/' + fileId;
    return new Promise(function(resolve, reject) {
      var attempts = 0;
      function check() {
        attempts++;
        if (attempts > 60) return reject(new Error('Timed out waiting for commit'));
        G.graphRequest('GET', url).then(function(data) {
          if (data.uploadState === 'commitFileSuccess') {
            resolve();
          } else if (data.uploadState && data.uploadState.indexOf('Fail') !== -1) {
            reject(new Error('Commit failed: ' + data.uploadState));
          } else {
            setTimeout(check, 2000);
          }
        }).catch(reject);
      }
      check();
    });
  }

  window.IntunePkgUpload = {
    uploadPkg: uploadPkg,
    encryptFile: encryptFile
  };
})(window);
```

**Important implementation note:** The encryption approach above (reading the entire file into memory) works for typical .pkg files (up to ~1-2GB). For very large files, a streaming approach would be needed, but this matches what the current PowerShell module does and is sufficient for base build .pkg files.

The key difference from the Intune portal source: we use standard Web Crypto API directly instead of the `msrCrypto` polyfill, since all modern browsers support `crypto.subtle`. The algorithm (AES-256-CBC + HMAC-SHA256) and the encrypted file format (HMAC + IV + ciphertext) match exactly what Intune expects.

**Step 2: Verify encryption format matches Intune**

Cross-reference with the PowerShell module's encryption at `IntuneBaseBuild.psm1` to confirm:
- Encrypted file layout: `HMAC(32 bytes) + IV(16 bytes) + AES-CBC ciphertext`
- `fileEncryptionInfo` fields match the commit payload
- Block IDs are zero-padded 8-char strings prefixed with "block-", then base64 encoded

**Step 3: Commit**

```bash
git add app/static/js/intune-pkg-upload.js
git commit -m "feat: add browser-side PKG encryption and Azure blob upload"
```

---

### Task 5: Integrate pkgparser-REAL.js for Bundle ID Extraction

**Files:**
- Copy: `scripts/pkgparser-REAL.js` → `app/static/js/vendor/pkgparser.js`
- Create: `app/static/js/intune-pkg-parser.js` (thin wrapper)

**Step 1: Copy the vendor file**

```bash
cp "scripts/pkgparser-REAL.js" "app/static/js/vendor/pkgparser.js"
```

**Step 2: Write the wrapper**

The pkgparser-REAL.js uses AMD `define()`. We need a wrapper that provides a minimal AMD loader and exposes the `pkgparse` function.

```javascript
/**
 * PKG Parser wrapper - loads pkgparser-REAL.js and exposes pkgparse().
 * The vendor file uses AMD define(), so we provide a minimal shim.
 */
(function(window) {
  'use strict';

  // The pkgparser module is loaded as an AMD module via the define() at the
  // end of vendor/pkgparser.js. After it loads, the module's exports are
  // available. We need to capture them.
  //
  // Since pkgparser-REAL.js uses: define(()=>(()=>{ ... return r(4273) })())
  // it's a single anonymous AMD module that returns the full exports.

  var _pkgparseReady = null;
  var _pkgparseModule = null;

  // Check if the module was loaded (it self-executes via define())
  function ensureLoaded() {
    if (_pkgparseModule) return Promise.resolve(_pkgparseModule);
    if (_pkgparseReady) return _pkgparseReady;

    _pkgparseReady = new Promise(function(resolve, reject) {
      // The module should already be loaded via <script> tag.
      // If define() was shimmed, the module is already available.
      if (window._pkgparserExports) {
        _pkgparseModule = window._pkgparserExports;
        resolve(_pkgparseModule);
      } else {
        reject(new Error('pkgparser not loaded. Ensure vendor/pkgparser.js is included.'));
      }
    });
    return _pkgparseReady;
  }

  /**
   * Parse a .pkg file and extract bundle information.
   * @param {ArrayBuffer} buffer - the .pkg file contents
   * @returns {Promise<Array<{name: string, version: string}>>} - list of included apps
   */
  function parsePkg(buffer) {
    return ensureLoaded().then(function(mod) {
      return mod.pkgparse(buffer);
    });
  }

  window.IntunePkgParser = {
    parsePkg: parsePkg
  };
})(window);
```

**Step 3: Add AMD shim before vendor script loads**

In the HTML template, before loading vendor/pkgparser.js, add a minimal AMD shim:

```javascript
// Minimal AMD shim to capture pkgparser module
var define;
if (typeof define === 'undefined') {
  define = function(deps, factory) {
    if (typeof deps === 'function') { factory = deps; deps = []; }
    var result = typeof factory === 'function' ? factory() : factory;
    if (result && result.pkgparse) window._pkgparserExports = result;
  };
  define.amd = true;
}
```

**Step 4: Commit**

```bash
cp "scripts/pkgparser-REAL.js" "app/static/js/vendor/pkgparser.js"
git add app/static/js/vendor/pkgparser.js app/static/js/intune-pkg-parser.js
git commit -m "feat: integrate Intune pkg parser for browser-side bundle ID extraction"
```

---

### Task 6: Rewrite intune_base_build.html Frontend

**Files:**
- Modify: `app/templates/tools/intune_base_build.html` (complete rewrite of JS, lines 499-901)

This is the largest task. The HTML structure (steps 1-4 wizard) stays largely the same, but all JavaScript is rewritten to use the browser-side modules instead of calling the agent.

**Step 1: Update script includes**

Add before the inline script block:

```html
<script>
// Minimal AMD shim for pkgparser vendor module
var define;
if (typeof define === 'undefined') {
  define = function(deps, factory) {
    if (typeof deps === 'function') { factory = deps; deps = []; }
    var result = typeof factory === 'function' ? factory() : factory;
    if (result && result.pkgparse) window._pkgparserExports = result;
  };
  define.amd = true;
}
</script>
<script src="{{ url_for('static', filename='js/vendor/pkgparser.js') }}"></script>
<script src="{{ url_for('static', filename='js/intune-graph-client.js') }}"></script>
<script src="{{ url_for('static', filename='js/intune-operations.js') }}"></script>
<script src="{{ url_for('static', filename='js/intune-pkg-upload.js') }}"></script>
<script src="{{ url_for('static', filename='js/intune-pkg-parser.js') }}"></script>
```

**Step 2: Rewrite Step 1 (Connect)**

The connect flow changes:
- Still launches the agent via URL scheme
- Still polls `/status` until agent is alive
- Calls `POST /connect` which now ONLY does auth (installs pwsh + Microsoft.Graph.Authentication + Connect-MgGraph)
- On success, calls `GET /token` to verify token works
- Stores tenant info from `/status` response

Key change: fewer progress items in the connect step (no more "Install Graph Modules" for 10 modules — just "Install PowerShell" → "Connect to Graph" → "Get Tenant Info").

**Step 3: Rewrite Step 2 (Prerequisites)**

Replace agent `/prerequisites` call with direct browser Graph API calls:

```javascript
function runPrerequisites() {
  var checks = [
    { id: 'apns', label: 'APNs Certificate', fn: IntuneOps.checkAPNs },
    { id: 'abm', label: 'ABM Token', fn: IntuneOps.checkABM },
    { id: 'vpp', label: 'VPP Token', fn: IntuneOps.checkVPP },
    { id: 'group', label: 'Test Group', fn: function() {
      return IntuneOps.ensureGroup('iStore Business PoC')
        .then(function(g) { groupId = g.id; return { status: 'success', message: 'Group ready: ' + g.displayName }; })
        .catch(function(e) { return { status: 'fail', message: e.message }; });
    }},
    { id: 'user', label: 'User Assignment', fn: function() {
      return IntuneGraph.agentRequest('GET', '/status').then(function(s) {
        return IntuneOps.findUser(s.userEmail).then(function(u) {
          if (!u) return { status: 'fail', message: 'User not found' };
          return IntuneOps.addGroupMember(groupId, u.id)
            .then(function() { return { status: 'success', message: 'User assigned' }; });
        });
      }).catch(function(e) { return { status: 'fail', message: e.message }; });
    }},
    { id: 'filevault', label: 'FileVault', fn: function() {
      return IntuneOps.createFileVault(fileVaultPolicyJson)
        .then(function(p) { return { status: 'success', message: 'FileVault created', data: p }; })
        .catch(function(e) { return { status: 'fail', message: e.message }; });
    }},
    { id: 'enrollment', label: 'Enrollment Profile', fn: function() {
      return IntuneOps.getDepSettings().then(function(settings) {
        if (!settings.length) return { status: 'fail', message: 'No DEP settings' };
        return IntuneOps.createEnrollmentProfile(settings[0].id, enrollmentProfileJson)
          .then(function(p) { return { status: 'success', message: 'Profile created' }; });
      }).catch(function(e) { return { status: 'fail', message: e.message }; });
    }}
  ];

  // Run checks sequentially, updating UI after each
  var i = 0;
  function runNext() {
    if (i >= checks.length) { /* done, advance to step 3 */ return; }
    var check = checks[i++];
    setCheckStatus(check.id, 'processing');
    check.fn().then(function(result) {
      setCheckStatus(check.id, result.status, result.message);
      runNext();
    });
  }
  runNext();
}
```

Note: The FileVault policy JSON and enrollment profile JSON need to be defined as constants in the JS (extracted from the current PowerShell module). These are static JSON blobs.

**Step 4: Rewrite Step 3 (Files)**

File loading stays the same (from `/api/intune-file-list`). But add:
- When a .pkg file is selected/dropped, use `IntunePkgParser.parsePkg()` to extract bundle info
- Show extracted bundle ID and version in the UI
- Allow user to edit if needed

Custom file upload no longer goes to the agent — files are kept in browser memory as `File` objects.

**Step 5: Rewrite Step 4 (Upload)**

Replace agent `/upload` call with browser-side upload logic:

```javascript
function startUpload() {
  var files = getSelectedFiles();
  var i = 0;
  function uploadNext() {
    if (i >= files.length) { /* done */ return; }
    var f = files[i++];
    setFileStatus(f.name, 'processing');

    processFile(f).then(function(result) {
      // Assign to group if we have a groupId
      if (groupId && result && result.id) {
        return assignToGroup(f.type, result.id, groupId).then(function() {
          setFileStatus(f.name, 'success');
        });
      }
      setFileStatus(f.name, 'success');
    }).catch(function(e) {
      setFileStatus(f.name, 'fail', e.message);
    }).then(uploadNext);
  }
  uploadNext();
}

function processFile(f) {
  // Template replacement for text files
  var file = f.file || null; // File object for custom uploads
  var url = f.url || null;   // S3 URL for base build files

  return getFileContent(f).then(function(content) {
    // Apply template replacements
    if (typeof content === 'string') {
      content = content.replace(/\{tenant_id\}/g, tenantId);
      content = content.replace(/\{org_name\}/g, tenantName);
    }

    switch (f.type) {
      case 'pkg':
        return IntunePkgUpload.uploadPkg(f.pkgInfo, f.file, function(stage, pct) {
          updateFileProgress(f.name, stage, pct);
        });
      case 'mobileconfig':
        var name = f.name.replace('.mobileconfig', '');
        return IntuneOps.createMobileConfig(name, f.name, btoa(content), 'macos');
      case 'ios_mobileconfig':
        var name = f.name.replace('.mobileconfig', '').replace('ios_', '');
        return IntuneOps.createMobileConfig(name, f.name, btoa(content), 'ios');
      case 'sh':
        var name = f.name.replace('.sh', '');
        return IntuneOps.createShellScript(name, f.name, btoa(content));
      case 'json':
        return IntuneOps.createSettingsCatalog(JSON.parse(content));
      case 'cash':
        var name = f.name.replace('.cash', '');
        return IntuneOps.createCustomAttribute(name, '', f.name + '.sh', btoa(content));
      default:
        return Promise.reject(new Error('Unknown file type: ' + f.type));
    }
  });
}

function getFileContent(f) {
  if (f.file) {
    return f.type === 'pkg' ? Promise.resolve(null) : f.file.text();
  }
  return fetch(f.url).then(function(r) {
    return f.type === 'pkg' ? r.arrayBuffer() : r.text();
  });
}

function assignToGroup(type, resourceId, groupId) {
  switch (type) {
    case 'pkg': return IntuneOps.assignApp(resourceId, groupId);
    case 'mobileconfig':
    case 'ios_mobileconfig': return IntuneOps.assignConfig(resourceId, groupId);
    case 'sh': return IntuneOps.assignScript(resourceId, groupId);
    case 'json': return IntuneOps.assignSettingsCatalog(resourceId, groupId);
    case 'cash': return IntuneOps.assignCustomAttribute(resourceId, groupId);
    default: return Promise.resolve();
  }
}
```

**Step 6: Extract static policy JSONs**

From `IntuneBaseBuild.psm1`, extract the FileVault policy JSON (lines ~563-698) and enrollment profile JSON (lines ~828-831) as JS constants. These are static policy definitions that get POSTed to Graph API.

**Step 7: Test end-to-end**

1. Launch agent, click Connect, authenticate
2. Run prerequisites — verify each check hits Graph API directly
3. Select files, verify pkg parsing extracts bundle info
4. Upload — verify configs, scripts, and pkgs upload successfully

**Step 8: Commit**

```bash
git add app/templates/tools/intune_base_build.html
git commit -m "refactor: rewrite Intune Base Build frontend to use browser-side Graph API calls"
```

---

### Task 7: Clean Up and Remove Dead Code

**Files:**
- Remove or gut: `agent/Resources/IntuneBaseBuild.psm1`
- Remove or gut: `agent/Resources/IntuneBaseBuild.psd1`
- Modify: `agent/Sources/MacAdminToolbox/main.swift` (remove dead functions)

**Step 1: Remove PowerShell module files**

The agent no longer needs the custom PowerShell module. Either delete the files or leave them for reference but stop loading them.

**Step 2: Remove dead agent code**

Remove all functions that are no longer called:
- `handlePrerequisites()`
- `handleUpload()`
- `handleUploadFile()`
- Any helper functions only used by the above
- PowerShell module download/install code for the custom module

**Step 3: Verify agent builds clean**

```bash
cd agent && swift build
```

**Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove dead PowerShell module and unused agent endpoints"
```

---

### Task 8: Final Verification

**Step 1: Full end-to-end test**

1. Build agent: `cd agent && swift build`
2. Start web app: `python run.py`
3. Navigate to Intune Base Build
4. Connect to a test tenant
5. Run prerequisites
6. Select a mix of file types (mobileconfig, sh, json, pkg)
7. Upload and verify all succeed
8. Check Intune portal to confirm resources were created

**Step 2: Verify agent is minimal**

Confirm the agent:
- Only installs `Microsoft.Graph.Authentication`
- Only has 4 endpoints: `/status`, `/connect`, `/token`, `/disconnect`
- No longer loads `IntuneBaseBuild.psm1`

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat: complete Intune browser-first refactor — agent is auth-only"
```
