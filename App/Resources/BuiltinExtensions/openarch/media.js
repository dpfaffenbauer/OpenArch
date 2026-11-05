// Tells OpenArch what the page plays (for the player in the sidebar and
// picture-in-picture when you switch tabs) and carries out OpenArch's
// commands. Reports go through the console like background.js; commands
// arrive as an "openarch-media" DOM event, sent with a user gesture so
// play() and requestPictureInPicture() are allowed. The page's own previous
// and next track and seeking (its media session) go through
// media-session.js, which runs in the page's world.
(() => {
  const MARKER = '__openarch_media__';
  let current = null;
  let actions = new Set();
  // The last report without its position, and where playback was then:
  // OpenArch moves the position on by itself, so a report only goes out
  // when something else changed or the position jumped.
  let last = '';
  let sent = null;

  const isMedia = (node) => node instanceof HTMLMediaElement;
  const element = () =>
    current?.isConnected ? current : [...document.querySelectorAll('video, audio')].find((m) => m.currentTime > 0);

  // The cover: the smallest of the page's media session artwork that is
  // still sharp in the sidebar, or a video's poster.
  function artwork(metadata, el) {
    const size = (image) => Math.max(0, ...String(image.sizes || '').split(/\s+/).map((s) => parseInt(s, 10) || 0));
    const images = [...(metadata?.artwork || [])]
      .filter((image) => /^https?:/.test(image.src) || (/^data:image\//.test(image.src) && image.src.length < 300000))
      .sort((a, b) => size(a) - size(b));
    const best = images.find((image) => size(image) >= 128) || images[images.length - 1];
    if (best) return best.src;
    return el instanceof HTMLVideoElement && /^https?:/.test(el.poster) ? el.poster : '';
  }

  function report() {
    const el = element();
    if (!el) return;
    const metadata = navigator.mediaSession?.metadata;
    const playing = !el.paused && !el.ended;
    const state = {
      playing,
      video: el instanceof HTMLVideoElement && el.videoWidth > 0,
      audible: !el.muted && el.volume > 0,
      title: metadata?.title || '',
      artist: metadata?.artist || '',
      album: metadata?.album || '',
      artwork: artwork(metadata, el),
      pip: !!document.pictureInPictureElement,
      duration: Number.isFinite(el.duration) ? el.duration : 0,
      live: el.duration === Infinity,
      rate: el.playbackRate,
      previous: actions.has('previoustrack'),
      next: actions.has('nexttrack'),
    };
    const time = el.currentTime;
    const now = performance.now();
    const json = JSON.stringify(state);
    if (json === last && sent) {
      const expected = sent.time + (sent.playing ? ((now - sent.at) / 1000) * sent.rate : 0);
      if (Math.abs(expected - time) < 1.5) return;
    }
    last = json;
    sent = { time, playing, rate: state.rate, at: now };
    console.debug(MARKER + ' ' + JSON.stringify({ ...state, time }));
  }

  const events = [
    'play', 'playing', 'pause', 'ended', 'volumechange', 'seeked', 'ratechange', 'durationchange',
    'loadedmetadata', 'emptied', 'enterpictureinpicture', 'leavepictureinpicture',
  ];
  for (const type of events) {
    document.addEventListener(type, (event) => {
      const target = event.composedPath()[0];
      if (isMedia(target) && (type === 'play' || type === 'playing' || !current)) current = target;
      report();
    }, true);
  }
  // A new title often comes without any other event (the next song on the
  // same element); this notices it, and costs nothing when nothing changed.
  document.addEventListener('timeupdate', (event) => {
    if (event.composedPath()[0] === current) report();
  }, true);

  document.addEventListener('openarch-media-actions', (event) => {
    actions = new Set(String(event.detail).split(' ').filter(Boolean));
    report();
  });
  document.dispatchEvent(new CustomEvent('openarch-media-hello'));

  const invoke = (action) => document.dispatchEvent(new CustomEvent('openarch-media-invoke', { detail: action }));

  document.addEventListener('openarch-media', async (event) => {
    const el = current?.isConnected ? current : document.querySelector('video, audio');
    const [command, value] = String(event.detail).split(':');
    try {
      switch (command) {
        case 'toggle':
          if (el) el.paused ? await el.play() : el.pause();
          break;
        case 'previous':
          // Without the page's own previous track, back to the start.
          if (actions.has('previoustrack')) invoke('previoustrack');
          else if (el) el.currentTime = 0;
          break;
        case 'next':
          if (actions.has('nexttrack')) invoke('nexttrack');
          break;
        case 'seek': {
          const time = Number(value);
          if (!Number.isFinite(time) || time < 0) break;
          if (actions.has('seekto')) invoke('seekto ' + time);
          else if (el) el.currentTime = time;
          break;
        }
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
