// Tells OpenArch what the page plays (for the media controls in the sidebar
// and picture-in-picture when you switch tabs) and carries out OpenArch's
// commands. Reports go through the console like background.js; commands
// arrive as an "openarch-media" DOM event, sent with a user gesture so
// play() and requestPictureInPicture() are allowed.
(() => {
  const MARKER = '__openarch_media__';
  let current = null;
  let last = '';

  const isMedia = (node) => node instanceof HTMLMediaElement;

  function report() {
    const el = current?.isConnected ? current : [...document.querySelectorAll('video, audio')].find((m) => m.currentTime > 0);
    if (!el) return;
    const metadata = navigator.mediaSession?.metadata;
    const state = {
      playing: !el.paused && !el.ended,
      video: el instanceof HTMLVideoElement && el.videoWidth > 0,
      audible: !el.muted && el.volume > 0,
      title: metadata?.title || '',
      artist: metadata?.artist || '',
      pip: !!document.pictureInPictureElement,
    };
    const json = JSON.stringify(state);
    if (json === last) return;
    last = json;
    console.debug(MARKER + ' ' + json);
  }

  for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'enterpictureinpicture', 'leavepictureinpicture']) {
    document.addEventListener(type, (event) => {
      const target = event.composedPath()[0];
      if (isMedia(target) && (type === 'play' || type === 'playing' || !current)) current = target;
      report();
    }, true);
  }

  document.addEventListener('openarch-media', async (event) => {
    const el = current?.isConnected ? current : document.querySelector('video, audio');
    try {
      switch (event.detail) {
        case 'toggle':
          if (el) el.paused ? await el.play() : el.pause();
          break;
        case 'pip':
          if (el instanceof HTMLVideoElement && !el.paused && !el.disablePictureInPicture && !document.pictureInPictureElement) {
            await el.requestPictureInPicture();
          }
          break;
        case 'exitpip':
          if (document.pictureInPictureElement) await document.exitPictureInPicture();
          break;
      }
    } catch (error) {
      console.debug(MARKER + '-error ' + error.message);
    }
    report();
  });
})();
