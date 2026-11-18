// Tells OpenArch what the page plays (for the player in the sidebar and
// picture-in-picture when you switch tabs) and carries out OpenArch's
// commands. Reports go through the console like background.js; commands
// arrive as an "openarch-media" DOM event, sent with a user gesture so
// play() and requestPictureInPicture() are allowed. The page's own previous
// and next track and seeking (its media session) go through
// media-session.js, which runs in the page's world. What OpenArch plays for
// the page with Apple's FairPlay (fairplay.js: Spotify's music;
// protected-video.js: Netflix's and Disney+'s video) is reported from what
// those scripts say: the page's element never plays itself.
(() => {
  const MARKER = '__openarch_media__';
  let current = null;
  let actions = new Set();
  // The last report without its position, and where playback was then:
  // OpenArch moves the position on by itself, so a report only goes out
  // when something else changed or the position jumped.
  let last = '';
  let sent = null;
  // What fairplay.js or protected-video.js plays for the page:
  // { playing, time, duration, audible, video, pip }.
  let bridge = null;

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
    const el = bridge ? null : element();
    if (!el && !bridge) return;
    const metadata = navigator.mediaSession?.metadata;
    const playing = bridge ? bridge.playing : !el.paused && !el.ended;
    const state = {
      playing,
      video: bridge ? bridge.video : el instanceof HTMLVideoElement && el.videoWidth > 0,
      audible: bridge ? bridge.audible : !el.muted && el.volume > 0,
      title: metadata?.title || '',
      artist: metadata?.artist || '',
      album: metadata?.album || '',
      artwork: artwork(metadata, el),
      pip: bridge ? bridge.pip : !!document.pictureInPictureElement,
      duration: bridge ? bridge.duration : Number.isFinite(el.duration) ? el.duration : 0,
      live: !bridge && el.duration === Infinity,
      rate: bridge ? 1 : el.playbackRate,
      previous: actions.has('previoustrack'),
      next: actions.has('nexttrack'),
    };
    const time = bridge ? bridge.time : el.currentTime;
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
  // fairplay.js and protected-video.js: what plays now, as JSON; '' when it
  // stopped.
  document.addEventListener('openarch-media-bridge', (event) => {
    const had = !!bridge;
    try {
      const state = typeof event.detail === 'string' && event.detail ? JSON.parse(event.detail) : null;
      bridge = state && {
        playing: state.playing === true,
        time: Number(state.time) || 0,
        duration: Number(state.duration) || 0,
        audible: state.audible === true,
        video: state.video === true,
        pip: state.pip === true,
      };
    } catch (error) {
      bridge = null;
    }
    if (bridge) {
      report();
    } else if (had) {
      // Nothing plays any more: say so once, since the element (which
      // never played itself) may have nothing to report.
      last = '';
      sent = null;
      console.debug(MARKER + ' ' + JSON.stringify({
        playing: false, video: false, audible: false, title: '', artist: '', album: '', artwork: '', pip: false,
        duration: 0, live: false, rate: 1, previous: false, next: false, time: 0,
      }));
    }
  });
  document.dispatchEvent(new CustomEvent('openarch-media-hello'));

  const invoke = (action) => document.dispatchEvent(new CustomEvent('openarch-media-invoke', { detail: action }));
  const invokeBridge = (command) =>
    document.dispatchEvent(new CustomEvent('openarch-media-bridge-invoke', { detail: command }));

  document.addEventListener('openarch-media', async (event) => {
    // While one of those scripts plays, the element is not the player.
    const el = bridge ? null : current?.isConnected ? current : document.querySelector('video, audio');
    const [command, value] = String(event.detail).split(':');
    try {
      switch (command) {
        case 'toggle':
          if (bridge) invokeBridge('toggle');
          else if (el) el.paused ? await el.play() : el.pause();
          break;
        case 'previous':
          // Without the page's own previous track, back to the start.
          if (actions.has('previoustrack')) invoke('previoustrack');
          else if (bridge) invokeBridge('seek 0');
          else if (el) el.currentTime = 0;
          break;
        case 'next':
          if (actions.has('nexttrack')) invoke('nexttrack');
          break;
        case 'seek': {
          const time = Number(value);
          if (!Number.isFinite(time) || time < 0) break;
          if (actions.has('seekto')) invoke('seekto ' + time);
          else if (bridge) invokeBridge('seek ' + time);
          else if (el) el.currentTime = time;
          break;
        }
        case 'pip':
          if (bridge) invokeBridge('pip');
          else if (el instanceof HTMLVideoElement && !el.paused && !el.disablePictureInPicture && !document.pictureInPictureElement) {
            await el.requestPictureInPicture();
          }
          break;
        case 'exitpip':
          if (bridge) invokeBridge('exitpip');
          else if (document.pictureInPictureElement) await document.exitPictureInPicture();
          break;
      }
    } catch (error) {
      console.debug(MARKER + '-error ' + error.message);
    }
    report();
  });
})();
