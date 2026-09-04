// ==UserScript==
// @name         Antoine Remote Userscript Loader
// @namespace    https://github.com/MasterSmalll
// @version      1.0.0
// @description  Loads trusted userscript modules from a GitHub-hosted manifest.
// @author       MasterSmalll
// @match        *://*/*
// @run-at       document-start
// @grant        GM_xmlhttpRequest
// @connect      raw.githubusercontent.com
// @updateURL    https://raw.githubusercontent.com/MasterSmalll/yourpods-source/tampermonkey/tampermonkey/loader.user.js
// @downloadURL  https://raw.githubusercontent.com/MasterSmalll/yourpods-source/tampermonkey/tampermonkey/loader.user.js
// ==/UserScript==

(() => {
  'use strict';

  const BASE = 'https://raw.githubusercontent.com/MasterSmalll/yourpods-source/tampermonkey/tampermonkey/';
  const MANIFEST_URL = `${BASE}manifest.json`;
  const TRUSTED_PREFIX = `${BASE}scripts/`;
  const LOG_PREFIX = '[Antoine Loader]';

  const requestText = (url) => new Promise((resolve, reject) => {
    GM_xmlhttpRequest({
      method: 'GET',
      url,
      headers: { 'Cache-Control': 'no-cache' },
      onload: (response) => {
        if (response.status >= 200 && response.status < 300) {
          resolve(response.responseText);
        } else {
          reject(new Error(`HTTP ${response.status} for ${url}`));
        }
      },
      onerror: () => reject(new Error(`Network error for ${url}`)),
      ontimeout: () => reject(new Error(`Timeout for ${url}`)),
      timeout: 10000,
    });
  });

  const wildcardToRegExp = (pattern) => {
    const escaped = pattern
      .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
      .replace(/\*/g, '.*');
    return new RegExp(`^${escaped}$`);
  };

  const matchesCurrentUrl = (patterns = []) => {
    const href = location.href;
    return patterns.some((pattern) => wildcardToRegExp(pattern).test(href));
  };

  const loadModule = async (entry) => {
    if (!entry?.enabled) return;
    if (!entry?.source || !entry.source.startsWith(TRUSTED_PREFIX)) {
      console.warn(LOG_PREFIX, 'Blocked untrusted source:', entry?.source);
      return;
    }
    if (!matchesCurrentUrl(entry.matches || [])) return;

    const sourceUrl = `${entry.source}?v=${encodeURIComponent(entry.version || Date.now())}`;
    const code = await requestText(sourceUrl);

    const run = new Function(
      'context',
      `'use strict';\n${code}\n//# sourceURL=${entry.source}`
    );

    run({
      id: entry.id,
      window,
      document,
      location,
      console,
    });

    console.info(LOG_PREFIX, `Loaded ${entry.id}`);
  };

  const boot = async () => {
    try {
      const manifestRaw = await requestText(`${MANIFEST_URL}?t=${Date.now()}`);
      const manifest = JSON.parse(manifestRaw);

      if (manifest?.version !== 1 || !Array.isArray(manifest?.scripts)) {
        throw new Error('Invalid manifest format');
      }

      for (const entry of manifest.scripts) {
        try {
          await loadModule(entry);
        } catch (error) {
          console.error(LOG_PREFIX, `Failed ${entry?.id || 'unknown'}`, error);
        }
      }
    } catch (error) {
      console.error(LOG_PREFIX, 'Bootstrap failed', error);
    }
  };

  void boot();
})();
