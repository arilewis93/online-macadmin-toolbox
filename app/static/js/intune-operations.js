(function(window) {
  'use strict';

  var G = window.IntuneGraph;

  // ---------------------------------------------------------------------------
  // Prerequisites
  // ---------------------------------------------------------------------------

  function checkAPNs() {
    return G.graphRequest('GET', '/deviceManagement/applePushNotificationCertificate')
      .then(function(data) {
        return { status: true, message: 'APNs certificate found (expires ' + data.expirationDateTime + ')' };
      })
      .catch(function() {
        return { status: false, message: 'No Apple Push Notification certificate configured' };
      });
  }

  function checkABM() {
    return G.graphRequest('GET', '/deviceManagement/depOnboardingSettings')
      .then(function(data) {
        var tokens = data.value || [];
        if (tokens.length > 0) {
          return { status: true, message: tokens.length + ' ABM token(s) connected' };
        }
        return { status: false, message: 'No Apple Business Manager tokens found' };
      })
      .catch(function() {
        return { status: false, message: 'Unable to check ABM status' };
      });
  }

  function checkVPP() {
    return G.graphRequest('GET', '/deviceAppManagement/vppTokens', null, 'v1.0')
      .then(function(data) {
        var tokens = data.value || [];
        if (tokens.length > 0) {
          return { status: true, message: tokens.length + ' VPP token(s) connected' };
        }
        return { status: false, message: 'No VPP/ABM content tokens found' };
      })
      .catch(function() {
        return { status: false, message: 'Unable to check VPP status' };
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
      payloadFileName: fileName,
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

  function createEnrollmentProfile(depSettingId, profileBody) {
    var endpoint = '/deviceManagement/depOnboardingSettings/' + depSettingId + '/enrollmentProfiles';
    return G.graphRequest('POST', endpoint, profileBody);
  }

  function createFileVault(policyJson) {
    return G.graphRequest('POST', '/deviceManagement/configurationPolicies', policyJson);
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
