(function(window) {
  'use strict';

  var AGENT_PORT = 8765;
  var AGENT_BASE = 'http://localhost:' + AGENT_PORT;
  var GRAPH_BASE = 'https://graph.microsoft.com';

  var _cachedToken = null;

  function getToken() {
    if (_cachedToken) return Promise.resolve(_cachedToken);
    return fetch(AGENT_BASE + '/token', { mode: 'cors' })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        if (data.error) throw new Error(data.error);
        _cachedToken = data.token;
        // Token acquired — tell agent to shut down
        fetch(AGENT_BASE + '/disconnect', { method: 'POST', mode: 'cors' }).catch(function() {});
        return _cachedToken;
      });
  }

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
        return r.text().then(function(text) {
          if (!text) return null;
          var data = JSON.parse(text);
          if (!r.ok) throw new Error(data.error ? data.error.message : 'Graph API error ' + r.status);
          return data;
        });
      });
    });
  }

  function agentRequest(method, path, body) {
    var opts = { method: method, mode: 'cors', headers: { 'Content-Type': 'application/json' } };
    if (body) opts.body = JSON.stringify(body);
    return fetch(AGENT_BASE + path, opts).then(function(r) { return r.json(); });
  }

  function rawPut(url, data, headers) {
    // Proxy Azure blob requests through Flask to avoid CORS
    var fetchUrl = url;
    if (url.indexOf('blob.core.windows.net') !== -1) {
      fetchUrl = '/api/azure-blob-proxy?url=' + encodeURIComponent(url);
    }
    return fetch(fetchUrl, {
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
