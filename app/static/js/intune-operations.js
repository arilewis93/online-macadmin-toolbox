(function(window) {
  'use strict';

  var G = window.IntuneGraph;

  // ---------------------------------------------------------------------------
  // Prerequisites
  // ---------------------------------------------------------------------------

  // RAG helper: returns 'success' (green), 'warning' (amber), or 'fail' (red)
  function expiryRAG(dateStr) {
    if (!dateStr) return 'fail';
    var exp = new Date(dateStr);
    var now = new Date();
    var daysLeft = Math.floor((exp - now) / 86400000);
    if (daysLeft < 0) return 'fail';
    if (daysLeft < 30) return 'warning';
    return 'success';
  }

  function formatExpiry(dateStr) {
    if (!dateStr) return 'missing';
    var exp = new Date(dateStr);
    var now = new Date();
    var daysLeft = Math.floor((exp - now) / 86400000);
    var dateFormatted = exp.toLocaleDateString('en-AU', { day: 'numeric', month: 'short', year: 'numeric' });
    if (daysLeft < 0) return 'Expired ' + dateFormatted;
    if (daysLeft < 30) return 'Expires ' + dateFormatted + ' (' + daysLeft + 'd)';
    return 'Expires ' + dateFormatted;
  }

  function checkAPNs() {
    return G.graphRequest('GET', '/deviceManagement/applePushNotificationCertificate')
      .then(function(data) {
        var rag = expiryRAG(data.expirationDateTime);
        return { status: rag, message: formatExpiry(data.expirationDateTime) };
      })
      .catch(function() {
        return { status: 'fail', message: 'Not configured' };
      });
  }

  function checkABM() {
    return G.graphRequest('GET', '/deviceManagement/depOnboardingSettings')
      .then(function(data) {
        var tokens = data.value || [];
        if (tokens.length === 0) return { status: 'fail', message: 'No token found' };
        // Check expiry of first token
        var t = tokens[0];
        var expiry = t.tokenExpirationDateTime || t.lastModifiedDateTime;
        var rag = expiryRAG(expiry);
        return { status: rag, message: tokens.length + ' token(s) \u2014 ' + formatExpiry(expiry) };
      })
      .catch(function() {
        return { status: 'fail', message: 'Not configured' };
      });
  }

  function checkVPP() {
    return G.graphRequest('GET', '/deviceAppManagement/vppTokens', null, 'v1.0')
      .then(function(data) {
        var tokens = data.value || [];
        if (tokens.length === 0) return { status: 'fail', message: 'No token found' };
        var t = tokens[0];
        var rag = expiryRAG(t.expirationDateTime);
        return { status: rag, message: tokens.length + ' token(s) \u2014 ' + formatExpiry(t.expirationDateTime) };
      })
      .catch(function() {
        return { status: 'fail', message: 'Not configured' };
      });
  }

  // ---------------------------------------------------------------------------
  // Groups & Users
  // ---------------------------------------------------------------------------

  function findGroup(displayName) {
    var endpoint = "/groups?$filter=displayName eq '" + encodeURIComponent(displayName) + "'";
    return G.graphRequest('GET', endpoint, null, 'v1.0')
      .then(function(data) {
        var groups = data.value || [];
        return groups.length > 0 ? groups[0] : null;
      });
  }

  function createGroup(displayName) {
    var body = {
      displayName: displayName,
      mailEnabled: false,
      mailNickname: displayName.replace(/[^a-zA-Z0-9]/g, ''),
      securityEnabled: true
    };
    return G.graphRequest('POST', '/groups', body, 'v1.0');
  }

  function ensureGroup(displayName) {
    return findGroup(displayName).then(function(existing) {
      if (existing) return existing;
      return createGroup(displayName);
    });
  }

  function findUser(upn) {
    var endpoint = "/users?$filter=userPrincipalName eq '" + encodeURIComponent(upn) + "'";
    return G.graphRequest('GET', endpoint, null, 'v1.0')
      .then(function(data) {
        var users = data.value || [];
        return users.length > 0 ? users[0] : null;
      });
  }

  function addGroupMember(groupId, userId) {
    var body = {
      '@odata.id': 'https://graph.microsoft.com/v1.0/directoryObjects/' + userId
    };
    return G.graphRequest('POST', '/groups/' + groupId + '/members/$ref', body, 'v1.0')
      .catch(function(err) {
        // Ignore "already exists" errors
        if (err.message && err.message.indexOf('already exist') !== -1) {
          return null;
        }
        throw err;
      });
  }

  // ---------------------------------------------------------------------------
  // Configs & Scripts
  // ---------------------------------------------------------------------------

  function createMobileConfig(displayName, fileName, payloadBase64, platform) {
    var odataType;
    if (platform === 'iOS') {
      odataType = '#microsoft.graph.iosCustomConfiguration';
    } else {
      odataType = '#microsoft.graph.macOSCustomConfiguration';
    }
    var body = {
      '@odata.type': odataType,
      displayName: displayName,
      description: 'Custom ' + platform + ' Configuration ' + displayName,
      payloadName: displayName,
      payloadFileName: fileName,
      deploymentChannel: 'deviceChannel',
      payload: payloadBase64
    };
    return G.graphRequest('POST', '/deviceManagement/deviceConfigurations', body);
  }

  function createSettingsCatalog(policyJson) {
    return G.graphRequest('POST', '/deviceManagement/configurationPolicies', policyJson);
  }

  function createShellScript(displayName, fileName, scriptContentBase64) {
    var body = {
      displayName: displayName,
      fileName: fileName,
      scriptContent: scriptContentBase64,
      runAsAccount: 'system',
      retryCount: 3,
      blockExecutionNotifications: true
    };
    return G.graphRequest('POST', '/deviceManagement/deviceShellScripts', body);
  }

  function createCustomAttribute(displayName, description, fileName, scriptContentBase64) {
    var body = {
      displayName: displayName,
      description: description || '',
      fileName: fileName,
      scriptContent: scriptContentBase64,
      runAsAccount: 'system'
    };
    return G.graphRequest('POST', '/deviceManagement/deviceCustomAttributeShellScripts', body);
  }

  // ---------------------------------------------------------------------------
  // Enrollment
  // ---------------------------------------------------------------------------

  function getDepSettings() {
    return G.graphRequest('GET', '/deviceManagement/depOnboardingSettings');
  }

  function findEnrollmentProfiles(depSettingId) {
    var endpoint = '/deviceManagement/depOnboardingSettings/' + depSettingId + '/enrollmentProfiles';
    return G.graphRequest('GET', endpoint)
      .then(function(data) { return data.value || []; });
  }

  function createEnrollmentProfile(depSettingId, profileBody) {
    var endpoint = '/deviceManagement/depOnboardingSettings/' + depSettingId + '/enrollmentProfiles';
    return G.graphRequest('POST', endpoint, profileBody);
  }

  function createFileVault(policyJson) {
    return G.graphRequest('POST', '/deviceManagement/configurationPolicies', policyJson);
  }

  function findFileVaultPolicies() {
    // Fetch all settings catalog policies and find FileVault ones by checking for FDE setting IDs
    return G.graphRequest('GET', '/deviceManagement/configurationPolicies?$top=100')
      .then(function(data) {
        var policies = data.value || [];
        // Filter to macOS policies that look like FileVault
        return policies.filter(function(p) {
          return p.platforms === 'macOS' && (
            (p.name && p.name.toLowerCase().indexOf('filevault') !== -1) ||
            (p.name && p.name.toLowerCase().indexOf('fde') !== -1) ||
            (p.name && p.name.toLowerCase().indexOf('disk encryption') !== -1)
          );
        });
      });
  }

  function auditFileVaultPolicy(policyId) {
    // Mirrors Test-FileVaultConfiguration from IntuneBaseBuild.psm1
    // Checks actual setting values, not just presence
    return G.graphRequest('GET', '/deviceManagement/configurationPolicies/' + policyId + '?$expand=settings')
      .then(function(fullProfile) {
        var settings = fullProfile.settings || [];

        // Critical settings with expected values (from PowerShell)
        var criticalSettings = {
          'com.apple.mcx.filevault2_enable': { expected: 'com.apple.mcx.filevault2_enable_0', type: 'choice', label: 'Enable' },
          'com.apple.mcx.filevault2_defer': { expected: 'com.apple.mcx.filevault2_defer_true', type: 'choice', label: 'Defer' },
          'com.apple.mcx.filevault2_deferdontaskatuserlogout': { expected: 'com.apple.mcx.filevault2_deferdontaskatuserlogout_true', type: 'choice', label: 'Defer at Logout' },
          'com.apple.mcx.filevault2_deferforceatuserloginmaxbypassattempts': { expected: 0, type: 'integer', label: 'Max Bypass Attempts' },
          'com.apple.mcx.filevault2_showrecoverykey': { expected: 'com.apple.mcx.filevault2_showrecoverykey_false', type: 'choice', label: 'Hide Recovery Key' },
          'com.apple.mcx.filevault2_forceenableinsetupassistant': { expected: 'com.apple.mcx.filevault2_forceenableinsetupassistant_true', type: 'choice', label: 'Force in Setup Assistant' },
          'com.apple.mcx_dontallowfdedisable': { expected: 'com.apple.mcx_dontallowfdedisable_true', type: 'choice', label: 'Prevent Disable' }
        };

        var foundSettings = {};
        var foundEscrow = false;
        var mismatches = [];

        settings.forEach(function(setting) {
          var groups = setting.settingInstance && setting.settingInstance.groupSettingCollectionValue;
          if (!groups) return;
          groups.forEach(function(group) {
            (group.children || []).forEach(function(child) {
              var sid = child.settingDefinitionId;

              // Check escrow location
              if (sid === 'com.apple.security.fderecoverykeyescrow_location') {
                foundEscrow = true;
                var escrowVal = child.simpleSettingValue && child.simpleSettingValue.value;
                if (!escrowVal || !escrowVal.trim()) {
                  mismatches.push('Escrow location is empty');
                }
                return;
              }

              // Check critical settings
              if (criticalSettings[sid]) {
                var spec = criticalSettings[sid];
                var actual;
                if (spec.type === 'integer') {
                  actual = child.simpleSettingValue && child.simpleSettingValue.value;
                } else {
                  actual = child.choiceSettingValue && child.choiceSettingValue.value;
                }
                foundSettings[sid] = actual;
                if (actual !== spec.expected) {
                  mismatches.push(spec.label + ': got \u201c' + actual + '\u201d');
                }
              }
            });
          });
        });

        // Check for missing settings
        var keys = Object.keys(criticalSettings);
        keys.forEach(function(k) {
          if (!(k in foundSettings)) {
            mismatches.push(criticalSettings[k].label + ' missing');
          }
        });
        if (!foundEscrow) {
          mismatches.push('Recovery Key Escrow missing');
        }

        var total = keys.length + 1; // +1 for escrow
        var passed = total - mismatches.length;

        return {
          total: total,
          passed: passed,
          missing: mismatches
        };
      });
  }

  // ---------------------------------------------------------------------------
  // Assignments
  // ---------------------------------------------------------------------------

  function assignApp(appId, groupId, intent) {
    intent = intent || 'required';
    var body = {
      mobileAppAssignments: [
        {
          '@odata.type': '#microsoft.graph.mobileAppAssignment',
          intent: intent,
          target: {
            '@odata.type': '#microsoft.graph.groupAssignmentTarget',
            groupId: groupId
          },
          settings: null
        }
      ]
    };
    return G.graphRequest('POST', '/deviceAppManagement/mobileApps/' + appId + '/assign', body);
  }

  function assignConfig(configId, groupId) {
    var body = {
      assignments: [
        {
          target: {
            '@odata.type': '#microsoft.graph.groupAssignmentTarget',
            groupId: groupId
          }
        }
      ]
    };
    return G.graphRequest('POST', '/deviceManagement/deviceConfigurations/' + configId + '/assign', body);
  }

  function assignScript(scriptId, groupId) {
    var body = {
      deviceManagementScriptAssignments: [
        {
          target: {
            '@odata.type': '#microsoft.graph.groupAssignmentTarget',
            groupId: groupId
          },
          runRemediationScript: false,
          runSchedule: null
        }
      ]
    };
    return G.graphRequest('POST', '/deviceManagement/deviceShellScripts/' + scriptId + '/assign', body);
  }

  function assignCustomAttribute(scriptId, groupId) {
    var body = {
      deviceManagementScriptAssignments: [
        {
          target: {
            '@odata.type': '#microsoft.graph.groupAssignmentTarget',
            groupId: groupId
          },
          runRemediationScript: false,
          runSchedule: null
        }
      ]
    };
    return G.graphRequest('POST', '/deviceManagement/deviceCustomAttributeShellScripts/' + scriptId + '/assign', body);
  }

  function assignSettingsCatalog(policyId, groupId) {
    var body = {
      assignments: [
        {
          target: {
            '@odata.type': '#microsoft.graph.groupAssignmentTarget',
            groupId: groupId
          }
        }
      ]
    };
    return G.graphRequest('POST', '/deviceManagement/configurationPolicies/' + policyId + '/assign', body);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  window.IntuneOps = {
    // Prerequisites
    checkAPNs: checkAPNs,
    checkABM: checkABM,
    checkVPP: checkVPP,

    // Groups & Users
    findGroup: findGroup,
    createGroup: createGroup,
    ensureGroup: ensureGroup,
    findUser: findUser,
    addGroupMember: addGroupMember,

    // Configs & Scripts
    createMobileConfig: createMobileConfig,
    createSettingsCatalog: createSettingsCatalog,
    createShellScript: createShellScript,
    createCustomAttribute: createCustomAttribute,

    // Enrollment
    getDepSettings: getDepSettings,
    findEnrollmentProfiles: findEnrollmentProfiles,
    createEnrollmentProfile: createEnrollmentProfile,
    createFileVault: createFileVault,
    findFileVaultPolicies: findFileVaultPolicies,
    auditFileVaultPolicy: auditFileVaultPolicy,

    // Assignments
    assignApp: assignApp,
    assignConfig: assignConfig,
    assignScript: assignScript,
    assignCustomAttribute: assignCustomAttribute,
    assignSettingsCatalog: assignSettingsCatalog
  };
})(window);
