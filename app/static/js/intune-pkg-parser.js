(function(window) {
  'use strict';

  function parsePkg(buffer) {
    var mod = window._pkgparserExports;
    if (!mod || !mod.pkgparse) {
      return Promise.reject(new Error('pkgparser not loaded'));
    }
    return mod.pkgparse(buffer);
  }

  window.IntunePkgParser = {
    parsePkg: parsePkg
  };
})(window);
