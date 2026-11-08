// Runs in the page's own world (not the extension's), so it sees the page's
// getDisplayMedia calls. Tells OpenArch through the console when the page
// shares the screen, a window or a tab, and which tab: every page names
// itself with a capture handle, which the sharing page can read from its
// video track. Pages that set their own handle (Google Slides for Meet)
// keep it; their tab is then just "a tab".
(() => {
  const CAPTURE = '__openarch_capture__';
  const HANDLE = '__openarch_handle__';
  const media = navigator.mediaDevices;
  if (!media || typeof media.getDisplayMedia !== 'function') return;

  // This tab's name for the sharing page.
  const handle = 'openarch-tab:' + Math.random().toString(36).slice(2, 12);
  let ownHandle = false;
  if (window.top === window && typeof media.setCaptureHandleConfig === 'function') {
    const setConfig = media.setCaptureHandleConfig.bind(media);
    try {
      setConfig({ handle, exposeOrigin: false, permittedOrigins: ['*'] });
      ownHandle = true;
    } catch (_) {}
    // The page's own handle wins.
    media.setCaptureHandleConfig = function (config) {
      ownHandle = false;
      return setConfig(config);
    };
  }
  if (ownHandle) console.debug(HANDLE + ' ' + handle);

  const tracks = new Set();
  let last = '';
  // A page that stops its own track gets no "ended" event; look now and then.
  let timer = 0;

  function report() {
    for (const track of tracks) {
      if (track.readyState === 'ended') tracks.delete(track);
    }
    const track = [...tracks][0];
    let state = null;
    if (track) {
      const settings = track.getSettings ? track.getSettings() : {};
      const captured = track.getCaptureHandle ? track.getCaptureHandle() : null;
      state = { surface: settings.displaySurface || '', handle: captured?.handle || '' };
    }
    const json = JSON.stringify(state);
    if (json !== last) {
      last = json;
      console.debug(CAPTURE + ' ' + json);
    }
    if (!track && timer) {
      clearInterval(timer);
      timer = 0;
    }
  }

  const getDisplayMedia = media.getDisplayMedia.bind(media);
  media.getDisplayMedia = async function (...args) {
    const stream = await getDisplayMedia(...args);
    for (const track of stream.getVideoTracks()) {
      tracks.add(track);
      track.addEventListener('ended', report);
      // "Share this tab instead" in Chrome changes what the track shows.
      track.addEventListener('capturehandlechange', report);
    }
    report();
    if (!timer) timer = setInterval(report, 1500);
    return stream;
  };

  // OpenArch's "Teilen beenden": ends the tracks as if the user had stopped
  // sharing in Chrome, so the page notices.
  document.addEventListener('openarch-capture-stop', () => {
    for (const track of tracks) {
      track.stop();
      track.dispatchEvent(new Event('ended'));
    }
    report();
  });
})();
