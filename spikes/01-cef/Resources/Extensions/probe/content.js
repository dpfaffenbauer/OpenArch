// Results go into data-* attributes on <html>: the page's main world can read
// them, so the self-test can collect them with plain JavaScript.
const root = document.documentElement;
root.dataset.openarchProbe = 'running';
console.log('[probe] content script running on ' + location.href);

const badge = document.createElement('div');
badge.textContent = 'OpenArch Probe: Content Script aktiv';
badge.style.cssText =
  'position:fixed;right:12px;bottom:12px;z-index:2147483647;padding:6px 10px;' +
  'font:12px -apple-system,sans-serif;color:#fff;background:#6d4aff;border-radius:6px;';
document.body.append(badge);

const results = {};
const publish = () => {
  root.dataset.openarchProbeChecks = JSON.stringify(results);
};

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((resolve) => setTimeout(() => resolve({ error: 'timeout' }), ms)),
  ]);
}

for (const check of ['ping', 'storage', 'tabs', 'sender']) {
  results[check] = 'pending';
  withTimeout(chrome.runtime.sendMessage({ check }), 2500)
    .then((reply) => {
      results[check] = reply?.error ? 'error: ' + reply.error : reply?.result;
    })
    .catch((error) => {
      results[check] = 'error: ' + error.message;
    })
    .finally(publish);
}

// Same origin and the same 404 path shape; only the first matches the
// extension's block rule.
for (const [key, path] of [['blocked', 'openarch-probe-blocked'], ['control', 'openarch-probe-allowed']]) {
  fetch(location.origin + '/' + path)
    .then((response) => {
      results['dnr_' + key] = 'not blocked (HTTP ' + response.status + ')';
    })
    .catch(() => {
      results['dnr_' + key] = 'failed';
    })
    .finally(publish);
}
publish();
setTimeout(() => console.log('[probe] checks ' + JSON.stringify(results)), 3000);
