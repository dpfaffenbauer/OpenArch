// Runs in the page's own world, so it sees the page's getUserMedia calls,
// its media session actions and its Document Picture-in-Picture window.
// Tells OpenArch through the console whether the page is in a call (it
// uses the camera or the microphone) and whether a floating window shows
// the call, and opens or closes that window on OpenArch's "openarch-call"
// event (sent with a user gesture, which Document Picture-in-Picture needs):
//
// - A site with a picture-in-picture of its own (Google Meet registers the
//   media session action "enterpictureinpicture") gets asked for it, as
//   Chrome does when you leave the tab.
// - Any other call gets OpenArch's own window: the call's video tiles (its
//   <video> elements with a live stream, or a large <canvas> as Zoom draws
//   them), and buttons for the microphone, the camera, hanging up and
//   going back to the tab. The page's own media session actions
//   (togglemicrophone, togglecamera, hangup) come first; without them the
//   buttons switch the tracks off, and hanging up clicks the site's leave
//   button.
(() => {
  if (window.top !== window) return;
  const MARKER = '__openarch_call__';
  const media = navigator.mediaDevices;
  const tracks = new Set();
  const handlers = new Map();
  // What the page told its media session (setMicrophoneActive and
  // setCameraActive), null while it said nothing.
  const active = { microphone: null, camera: null };
  let own = null;
  let site = null;
  let opening = false;
  // A "pip" on its way (leaving a space also leaves its tab).
  let busy = false;
  // Whether OpenArch still wants it (not back at the tab since).
  let wanted = false;
  let last = '';
  // Whether this page used the camera or microphone itself (a call in a
  // frame shows only in Chrome's recording indicator).
  let hadTracks = false;
  let timer = 0;

  const live = (kind) => [...tracks].some((t) => t.kind === kind && t.readyState === 'live');
  const enabled = (kind) => [...tracks].some((t) => t.kind === kind && t.readyState === 'live' && t.enabled);
  const isOn = (kind) => (active[kind === 'audio' ? 'microphone' : 'camera'] ?? enabled(kind));

  function report() {
    for (const track of tracks) {
      if (track.readyState === 'ended') tracks.delete(track);
    }
    const state = {
      camera: live('video'),
      microphone: live('audio'),
      sitePip: handlers.has('enterpictureinpicture'),
      pip: own ? 'own' : site ? 'site' : document.pictureInPictureElement ? 'video' : '',
    };
    const json = JSON.stringify(state);
    if (json !== last) {
      last = json;
      console.debug(MARKER + ' ' + json);
    }
    if (own) own.update();
    if (!tracks.size && timer) {
      clearInterval(timer);
      timer = 0;
    }
  }

  // Camera and microphone.
  if (media && typeof media.getUserMedia === 'function') {
    const getUserMedia = media.getUserMedia.bind(media);
    media.getUserMedia = async function (...args) {
      const stream = await getUserMedia(...args);
      for (const track of stream.getTracks()) {
        hadTracks = true;
        tracks.add(track);
        track.addEventListener('ended', report);
      }
      report();
      // A page that stops its own track gets no "ended" event.
      if (!timer) timer = setInterval(report, 1500);
      return stream;
    };
  }

  // The page's media session: which actions it has, and what it says about
  // its microphone and camera.
  const proto = globalThis.MediaSession?.prototype;
  if (proto?.setActionHandler) {
    proto.setActionHandler = new Proxy(proto.setActionHandler, {
      apply(target, session, args) {
        const result = Reflect.apply(target, session, args);
        const [action, handler] = args;
        if (typeof handler === 'function') handlers.set(String(action), handler);
        else handlers.delete(String(action));
        report();
        return result;
      },
    });
    for (const [name, key] of [['setMicrophoneActive', 'microphone'], ['setCameraActive', 'camera']]) {
      if (typeof proto[name] !== 'function') continue;
      proto[name] = new Proxy(proto[name], {
        apply(target, session, args) {
          active[key] = !!args[0];
          if (own) own.update();
          return Reflect.apply(target, session, args);
        },
      });
    }
  }

  // The site's own Document Picture-in-Picture window.
  const dpip = window.documentPictureInPicture;
  if (dpip && typeof dpip.requestWindow === 'function') {
    const requestWindow = dpip.requestWindow.bind(dpip);
    dpip.requestWindow = async function (...args) {
      const pip = await requestWindow(...args);
      if (!opening) {
        site = pip;
        pip.addEventListener('pagehide', () => {
          if (site === pip) site = null;
          report();
        });
        report();
      }
      return pip;
    };
  }

  const invoke = (action) => {
    const handler = handlers.get(action);
    if (!handler) return false;
    try {
      handler({ action });
    } catch (error) {
      console.debug(MARKER + '-error ' + error.message);
    }
    return true;
  };

  function toggle(kind) {
    if (invoke(kind === 'audio' ? 'togglemicrophone' : 'togglecamera')) return;
    const on = !enabled(kind);
    for (const track of tracks) if (track.kind === kind) track.enabled = on;
  }

  // The site's leave button, for sites without a "hangup" action.
  const LEAVE = [
    '[data-tid="hangup-main-btn"]', '#hangup-button', '[data-tid="call-hangup"]',
    'button.footer__leave-btn', '[data-qa="huddle_mini_player_leave_button"]', '[data-qa="huddle_leave_button"]',
    'button[aria-label^="Leave" i]', 'button[aria-label^="Hang up" i]', 'button[aria-label^="End call" i]',
    'button[aria-label*="Auflegen" i]', 'button[aria-label*="verlassen" i]', 'button[aria-label^="Anruf beenden" i]',
  ];

  function hangUp() {
    if (!invoke('hangup')) {
      const button = LEAVE.map((s) => document.querySelector(s)).find(Boolean);
      if (button) button.click();
      else for (const track of tracks) track.stop();
    }
    closeAll();
    report();
  }

  function closeAll() {
    try { dpip?.window?.close(); } catch (_) {}
    if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
  }

  // The call's pictures: videos showing a live stream, and large canvases.
  function sources() {
    const videos = [...document.querySelectorAll('video')].filter((v) =>
      v.srcObject instanceof MediaStream && v.srcObject.getVideoTracks().some((t) => t.readyState === 'live'));
    const canvases = videos.length ? [] : [...document.querySelectorAll('canvas')]
      .filter((c) => c.width >= 240 && c.height >= 135 && c.getBoundingClientRect().width >= 160);
    return [...videos, ...canvases].slice(0, 9);
  }

  const SVG = 'http://www.w3.org/2000/svg';
  function icon(doc, paths, slashed) {
    const svg = doc.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('width', '20');
    svg.setAttribute('height', '20');
    for (const d of slashed ? [...paths, 'M4 4 20 20'] : paths) {
      const path = doc.createElementNS(SVG, 'path');
      path.setAttribute('d', d);
      path.setAttribute('fill', 'none');
      path.setAttribute('stroke', 'currentColor');
      path.setAttribute('stroke-width', '2');
      path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round');
      svg.append(path);
    }
    return svg;
  }
  const MIC = ['M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3z', 'M5 11a7 7 0 0 0 14 0', 'M12 18v3'];
  const CAMERA = ['M3 7h12v10H3z', 'M15 10l6-3v10l-6-3'];
  const HANGUP = ['M3 14c4-4 14-4 18 0l-2 3-4-1v-2a10 10 0 0 0-6 0v2l-4 1z'];
  const BACK = ['M15 18l-6-6 6-6'];

  // OpenArch's own picture-in-picture window for a call.
  async function openOwn() {
    if (!dpip) {
      // Without Document Picture-in-Picture: the largest video floats.
      const video = sources().filter((s) => s instanceof HTMLVideoElement)
        .sort((a, b) => b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight)[0];
      if (video) await video.requestPictureInPicture();
      return;
    }
    opening = true;
    let pip;
    try {
      pip = await dpip.requestWindow({ width: 360, height: 240 });
    } finally {
      opening = false;
    }
    const doc = pip.document;
    doc.title = document.title;
    Object.assign(doc.body.style, {
      margin: '0', background: '#111', color: 'white', overflow: 'hidden', height: '100vh',
      font: '13px -apple-system, system-ui, sans-serif', userSelect: 'none',
    });
    const grid = doc.createElement('div');
    Object.assign(grid.style, { position: 'absolute', inset: '0', display: 'grid', gap: '4px', padding: '4px' });
    const empty = doc.createElement('div');
    Object.assign(empty.style, {
      position: 'absolute', inset: '0', display: 'flex', alignItems: 'center', justifyContent: 'center',
      padding: '0 24px', textAlign: 'center', opacity: '0.7',
    });
    empty.textContent = document.title || location.hostname;
    const bar = doc.createElement('div');
    Object.assign(bar.style, {
      position: 'absolute', left: '0', right: '0', bottom: '10px', display: 'flex', justifyContent: 'center', gap: '10px',
    });
    const button = (label, paths, action) => {
      const b = doc.createElement('button');
      b.title = label;
      b.setAttribute('aria-label', label);
      Object.assign(b.style, {
        width: '38px', height: '38px', borderRadius: '19px', border: 'none', display: 'flex', alignItems: 'center',
        justifyContent: 'center', color: 'white', background: 'rgba(60,60,60,0.85)', cursor: 'pointer', padding: '0',
      });
      b.addEventListener('click', action);
      b.paths = paths;
      return b;
    };
    const mic = button('Mikrofon', MIC, () => { toggle('audio'); setTimeout(update, 100); });
    const camera = button('Kamera', CAMERA, () => { toggle('video'); setTimeout(update, 100); });
    const leave = button('Auflegen', HANGUP, hangUp);
    leave.style.background = '#e5483c';
    leave.style.width = '52px';
    leave.append(icon(doc, HANGUP));
    const back = button('Zurück zum Tab', BACK, () => console.debug(MARKER + '-back'));
    Object.assign(back.style, { position: 'absolute', top: '8px', left: '8px', width: '28px', height: '28px' });
    back.append(icon(doc, BACK));
    bar.append(mic, camera, leave);
    doc.body.append(grid, empty, bar, back);

    const tiles = new Map();
    function update() {
      if (pip.closed) return;
      const now = sources();
      for (const [source, tile] of tiles) {
        if (!now.includes(source)) {
          tile.remove();
          tiles.delete(source);
        }
      }
      for (const source of now) {
        if (tiles.has(source)) continue;
        const video = doc.createElement('video');
        video.muted = true;
        video.autoplay = true;
        video.playsInline = true;
        video.srcObject = source instanceof HTMLCanvasElement ? source.captureStream(15) : source.srcObject;
        Object.assign(video.style, { width: '100%', height: '100%', objectFit: 'cover', borderRadius: '6px', background: '#222' });
        grid.append(video);
        video.play().catch(() => {});
        tiles.set(source, video);
      }
      const columns = Math.ceil(Math.sqrt(tiles.size || 1));
      grid.style.gridTemplateColumns = `repeat(${columns}, 1fr)`;
      empty.style.display = tiles.size ? 'none' : 'flex';
      for (const [b, kind] of [[mic, 'audio'], [camera, 'video']]) {
        const shown = live(kind) || handlers.has(kind === 'audio' ? 'togglemicrophone' : 'togglecamera');
        b.style.display = shown ? 'flex' : 'none';
        const on = isOn(kind);
        b.replaceChildren(icon(doc, b.paths, !on));
        b.style.background = on ? 'rgba(60,60,60,0.85)' : 'white';
        b.style.color = on ? 'white' : '#e5483c';
      }
    }
    const refresh = setInterval(update, 1000);
    own = { pip, update };
    pip.addEventListener('pagehide', () => {
      clearInterval(refresh);
      if (own?.pip === pip) own = null;
      report();
    });
    update();
    report();
  }

  document.addEventListener('openarch-call', async (event) => {
    try {
      switch (event.detail) {
        case 'pip':
          wanted = true;
          // Hung up a moment ago (a stopped track sends no "ended").
          report();
          if (hadTracks && !tracks.size) break;
          if (busy || own || site || dpip?.window || document.pictureInPictureElement) break;
          busy = true;
          try {
            if (invoke('enterpictureinpicture')) {
              // The site opens its own window; if it does not, OpenArch's.
              await new Promise((resolve) => setTimeout(resolve, 1000));
              if (!wanted || site || dpip?.window || document.pictureInPictureElement) break;
            }
            await openOwn();
          } finally {
            busy = false;
            // Back at the tab before the window was there.
            if (!wanted) closeAll();
          }
          break;
        case 'exitpip':
          wanted = false;
          closeAll();
          break;
        case 'microphone':
          toggle('audio');
          break;
        case 'camera':
          toggle('video');
          break;
        case 'hangup':
          hangUp();
          break;
      }
    } catch (error) {
      console.debug(MARKER + '-error ' + error.message);
    }
    report();
  });
  document.addEventListener('enterpictureinpicture', report, true);
  document.addEventListener('leavepictureinpicture', report, true);
})();
