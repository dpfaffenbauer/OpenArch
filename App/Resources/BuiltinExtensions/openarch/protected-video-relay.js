// Netflix and Disney+ in Chromium (protected-video.js): that script has to
// run before the page's own, so the extension's background registers it,
// only while OpenArch's setting is on.
// The background cannot ask OpenArch, a page can: this script says hello
// through the console, OpenArch answers with an "openarch-pv-config" DOM
// event ("on" or "off"), and the background gets the answer, with whether
// protected-video.js ran in this page. When that does not match the
// setting, the background loads the page once more.
(() => {
  let answered = false;
  document.addEventListener('openarch-pv-config', (event) => {
    if (event.detail !== 'on' && event.detail !== 'off') return;
    answered = true;
    // protected-video.js, in the page's world, cancels this event.
    const present = !document.dispatchEvent(new CustomEvent('openarch-pv-ping', { cancelable: true }));
    chrome.runtime.sendMessage({ openarch: 'protected-video', on: event.detail === 'on', present }).catch(() => {});
  });
  const hello = () => console.debug('__openarch_pv__ hello');
  hello();
  // Once more, in case OpenArch did not know the page yet.
  for (const delay of [1000, 4000]) setTimeout(() => answered || hello(), delay);
})();
