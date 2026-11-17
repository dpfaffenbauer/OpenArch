// Adapted from Ardia's page script (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios/page_script.js, its FairPlay part for Spotify),
// Apache License 2.0, Copyright 2026 Mantra Patel. Changed for OpenArch.
// See NOTICE.
//
// Spotify in a Chromium page (Settings › Allgemein › Geschützte Inhalte ›
// „Streamingdienste in Chromium abspielen“, FairPlay.swift). Chromium has no DRM
// that Spotify accepts, but macOS has Apple's FairPlay. So this script, in
// the page's own world before the page's scripts, offers Spotify's player
// FairPlay as Safari would. The player then hands its <audio> element an
// HLS playlist and asks for a licence the way it does in Safari. The
// playlist goes to OpenArch, whose helper process plays it with Apple's
// player; the key request comes back from macOS, the page's own code trades
// it for the licence with Spotify, and the licence goes to the helper. The
// element itself never plays: it answers the page (currentTime, paused,
// duration, its events) with what the helper reports.
//
// To OpenArch through the console, like media.js; from OpenArch as an
// "openarch-fairplay" DOM event. media.js gets what plays for the sidebar's
// player ("openarch-media-bridge") and sends its buttons here.
(() => {
  'use strict';
  const MARKER = '__openarch_fairplay__';
  const KEY_SYSTEM = 'com.apple.fps.1_0';
  // The self-test runs this script by hand in a page of its own.
  const test = globalThis.__openarchFairPlayTest === true;
  if (window !== window.top || (!test && location.origin !== 'https://open.spotify.com')) return;
  if (typeof Navigator.prototype.requestMediaKeySystemAccess !== 'function') return;

  const PLAYLIST_PART = 30000;
  const CONFIG_WAIT_MS = 3000;
  const SEEK_GIVE_UP_MS = 2000;
  const ENCRYPTED_DELAY_MS = 100;
  const TICK_MS = 250;
  const READY_GIVE_UP_MS = 45000;
  const PLAYLIST_URL = /^data:application\/(?:vnd\.apple\.mpegurl|x-mpegurl)((?:;[^,]*)?),/i;

  // The page's scripts run after this one and may wrap or replace any of
  // these (Spotify's error reporting wraps the console): keep the originals.
  const apply = Reflect.apply;
  const toJSON = JSON.stringify;
  const { defineProperty, getOwnPropertyDescriptor } = Object;
  const { isFinite } = Number;
  const { btoa, atob } = window;
  const fromCharCode = String.fromCharCode;
  const pageConsole = console;
  const debug = console.debug;
  const clock = performance;
  const clockNow = clock.now;
  const now = () => apply(clockNow, clock, []);
  const encoder = new TextEncoder();
  const Media = HTMLMediaElement.prototype;
  const session = navigator.mediaSession;

  const send = (data) => apply(debug, pageConsole, [MARKER + ' ' + toJSON(data)]);
  const guard = (fn) =>
    function () {
      try {
        return apply(fn, this, arguments);
      } catch (e) {}
    };
  // A proxy, so the page still sees a native function.
  const asNative = (native, call) => new Proxy(native, { apply: (target, self, args) => call(target, self, args) });
  const fire = (el, type) => el.dispatchEvent(new Event(type));
  const bytesOf = (b) =>
    b instanceof ArrayBuffer ? new Uint8Array(b) : ArrayBuffer.isView(b) ? new Uint8Array(b.buffer, b.byteOffset, b.byteLength) : new Uint8Array(0);
  const toBase64 = (bytes) => {
    let text = '';
    for (let i = 0; i < bytes.length; i += 0x8000) text += apply(fromCharCode, null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  };
  const fromBase64 = (text) => {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };

  // Whether the setting is on: OpenArch answers the hello below. Until it
  // has, the page's questions about key systems wait (at most 3 s).
  let enabled = null;
  // OPENARCH_FAIRPLAY_TRACE=1: every step goes to OpenArch's log.
  let tracing = false;
  const trace = (what) => {
    if (tracing) send({ op: 'trace', what: String(what).slice(0, 300) });
  };
  const awaitingConfig = [];
  const configure = (on, traces) => {
    enabled = on;
    tracing = traces;
    for (const resolve of awaitingConfig.splice(0)) resolve();
  };
  const whenConfigured = () => {
    if (enabled !== null) return Promise.resolve();
    // Asked before the answer came: once more, in case the first hello
    // went out before OpenArch knew the page.
    send({ op: 'hello' });
    return new Promise((resolve) => {
      awaitingConfig.push(resolve);
      setTimeout(resolve, CONFIG_WAIT_MS);
    });
  };

  let certificate = '';
  let generation = 0;
  // The element whose track the helper has, the key session waiting for
  // its key request, and that request once macOS made it.
  let media = null;
  let pending = null;
  let request = null;
  let ticker = 0;
  const tracks = new WeakMap();
  const ownKeys = new WeakSet();
  const keysOf = new WeakMap();
  const everKeyed = new WeakSet();
  let keyed = null;
  const sessionGeneration = new WeakMap();

  // The page's own previous and next track, play and pause (its media
  // session), for the media keys and the sidebar's player.
  const actions = new Map();
  const sessionProto = session && Object.getPrototypeOf(session);
  if (sessionProto && sessionProto.setActionHandler) {
    sessionProto.setActionHandler = asNative(sessionProto.setActionHandler, (target, self, args) => {
      const result = apply(target, self, args);
      if (typeof args[1] === 'function') actions.set(String(args[0]), args[1]);
      else actions.delete(String(args[0]));
      return result;
    });
  }

  // ---- The key system: FairPlay, answered here.

  const deliverRequest = () => {
    if (!pending || !request || sessionGeneration.get(pending) !== request.gen) return;
    const target = pending;
    const { message } = request;
    request = null;
    let event;
    try {
      event = new MediaKeyMessageEvent('message', { messageType: 'license-request', message });
    } catch (e) {
      event = new Event('message');
      event.messageType = 'license-request';
      event.message = message;
    }
    target.dispatchEvent(event);
  };
  const createSession = () => {
    const keySession = new EventTarget();
    keySession.sessionId = 'openarch-' + Math.random().toString(36).slice(2);
    keySession.expiration = NaN;
    keySession.keyStatuses = new Map();
    let closeSession;
    keySession.closed = new Promise((resolve) => (closeSession = resolve));
    keySession.generateRequest = () => {
      trace('key session: generateRequest');
      sessionGeneration.set(keySession, generation);
      pending = keySession;
      deliverRequest();
      return Promise.resolve();
    };
    keySession.update = (response) => {
      trace('key session: update, ' + bytesOf(response).length + ' bytes');
      send({ op: 'license', gen: sessionGeneration.get(keySession), ckc: toBase64(bytesOf(response)) });
      keySession.keyStatuses = new Map([[new Uint8Array(16).buffer, 'usable']]);
      keySession.dispatchEvent(new Event('keystatuseschange'));
      return Promise.resolve();
    };
    keySession.load = () => Promise.resolve(false);
    keySession.close = () => {
      closeSession();
      return Promise.resolve();
    };
    keySession.remove = () => Promise.resolve();
    return keySession;
  };
  const createKeys = () => {
    const keys = {
      setServerCertificate(server) {
        const bytes = bytesOf(server);
        trace('certificate: ' + bytes.length + ' bytes');
        if (bytes.length) certificate = toBase64(bytes);
        return Promise.resolve(true);
      },
      createSession,
      getStatusForPolicy: () => Promise.resolve('usable'),
    };
    ownKeys.add(keys);
    return keys;
  };

  defineProperty(Navigator.prototype, 'requestMediaKeySystemAccess', {
    ...getOwnPropertyDescriptor(Navigator.prototype, 'requestMediaKeySystemAccess'),
    value: asNative(Navigator.prototype.requestMediaKeySystemAccess, (target, self, args) => {
      if (args[0] !== KEY_SYSTEM) {
        // With the setting on, the player must not settle for Widevine or
        // PlayReady before it comes to FairPlay.
        if (!/^com\.(?:widevine|microsoft\.playready)(?:\.|$)/.test(String(args[0]))) return apply(target, self, args);
        return whenConfigured().then(() => {
          trace('asked for ' + args[0] + ': ' + (enabled === true ? 'refused' : 'left to Chromium'));
          return enabled === true
            ? Promise.reject(new DOMException('Unsupported keySystem or supportedConfigurations.', 'NotSupportedError'))
            : apply(target, self, args);
        });
      }
      const configurations = args[1];
      return whenConfigured().then(() => {
        trace('asked for ' + KEY_SYSTEM + ': ' + (enabled === true ? 'offered' : 'left to Chromium'));
        if (enabled !== true) return apply(target, self, args);
        const configuration = (configurations && configurations[0]) || {};
        return { keySystem: KEY_SYSTEM, getConfiguration: () => configuration, createMediaKeys: () => Promise.resolve(createKeys()) };
      });
    }),
  });
  const mediaKeys = getOwnPropertyDescriptor(Media, 'mediaKeys');
  defineProperty(Media, 'mediaKeys', {
    ...mediaKeys,
    get() {
      return keysOf.has(this) ? keysOf.get(this) : apply(mediaKeys.get, this, []);
    },
  });
  Media.setMediaKeys = asNative(Media.setMediaKeys, (target, self, args) => {
    if (ownKeys.has(args[0])) {
      trace('setMediaKeys on <' + self.localName + '>');
      keysOf.set(self, args[0]);
      everKeyed.add(self);
      keyed = self;
      return Promise.resolve();
    }
    keysOf.delete(self);
    return apply(target, self, args);
  });

  // ---- The element: what the page reads from it and does with it.

  const positionOf = (t) =>
    t.paused || !t.playing ? t.time : Math.min(Number.isNaN(t.duration) ? Infinity : t.duration, t.time + (now() - t.stamp) / 1000);
  const rangesOf = (t) => ({ length: t.ready ? 1 : 0, start: () => 0, end: () => (Number.isNaN(t.duration) ? 0 : t.duration) });
  const drives = (t) => !t.detached && !t.failed;

  // For the sidebar's player (media.js, in its own world, cannot see what
  // this script answers for the element).
  const announce = () => {
    const t = media && tracks.get(media);
    const detail = t && !t.failed
      ? toJSON({
          playing: !t.paused,
          time: positionOf(t),
          duration: Number.isNaN(t.duration) ? 0 : t.duration,
          audible: !t.muted && t.volume > 0,
        })
      : '';
    document.dispatchEvent(new CustomEvent('openarch-media-bridge', { detail }));
  };

  const stopTicking = () => {
    if (ticker) clearInterval(ticker);
    ticker = 0;
  };
  const startTicking = () => {
    if (ticker) return;
    ticker = setInterval(
      guard(() => {
        const t = media && tracks.get(media);
        if (t && !t.paused) fire(media, 'timeupdate');
        else stopTicking();
      }),
      TICK_MS
    );
  };
  const finishSeek = (t, el) => {
    t.seeking = 0;
    fire(el, 'seeked');
    fire(el, 'timeupdate');
    announce();
  };
  const seek = (t, el, value) => {
    const time = +value;
    if (!isFinite(time) || time < 0) return;
    t.time = time;
    t.stamp = now();
    t.ended = false;
    if (!drives(t)) {
      fire(el, 'seeking');
      fire(el, 'seeked');
      fire(el, 'timeupdate');
      return;
    }
    const seq = ++t.seeks;
    t.seeking = seq;
    send({ op: 'seek', time, seq });
    fire(el, 'seeking');
    setTimeout(
      guard(() => {
        if (t.seeking === seq) finishSeek(t, el);
      }),
      SEEK_GIVE_UP_MS
    );
  };
  const natives = {};
  const override = (name, get, set) => {
    const native = getOwnPropertyDescriptor(Media, name);
    if (!native || !native.get) return;
    natives[name] = native;
    defineProperty(Media, name, {
      ...native,
      get() {
        const t = tracks.get(this);
        return t ? get(t) : apply(native.get, this, []);
      },
      set: native.set
        ? function (value) {
            const t = tracks.get(this);
            if (t && set) set(t, this, value);
            else apply(native.set, this, [value]);
          }
        : undefined,
    });
  };
  override('readyState', (t) => t.ready);
  override('networkState', (t) => (t.ready ? 1 : 2));
  override('duration', (t) => t.duration);
  override('paused', (t) => t.paused);
  override('ended', (t) => t.ended);
  override('error', (t) => t.error);
  override('buffered', rangesOf);
  override('seekable', rangesOf);
  override('webkitAudioDecodedByteCount', (t) => (t.ready ? 1 : 0));
  override('currentTime', positionOf, seek);
  override('volume', (t) => t.volume, (t, el, value) => {
    const volume = Math.min(Math.max(+value || 0, 0), 1);
    t.volume = volume;
    if (drives(t)) send({ op: 'volume', volume });
    fire(el, 'volumechange');
    announce();
  });
  override('muted', (t) => t.muted, (t, el, value) => {
    t.muted = !!value;
    if (drives(t)) send({ op: 'muted', muted: t.muted });
    fire(el, 'volumechange');
    announce();
  });
  const nativeValue = (el, name, fallback) => {
    try {
      return apply(natives[name].get, el, []);
    } catch (e) {
      return fallback;
    }
  };

  Media.play = asNative(Media.play, (target, self, args) => {
    const t = tracks.get(self);
    if (!t) return apply(target, self, args);
    if (t.failed) return Promise.reject(new DOMException('The element has no supported sources.', 'NotSupportedError'));
    if (t.detached) {
      // Another track or tab had the helper meanwhile: load again.
      attach(self, t);
      if (t.time > 0 || t.seeks) send({ op: 'seek', time: t.time, seq: ++t.seeks });
    }
    if (t.paused) {
      if (t.ended) seek(t, self, 0);
      t.paused = false;
      t.ended = false;
      t.stamp = now();
      send({ op: 'play' });
      fire(self, 'play');
      startTicking();
      announce();
    }
    return Promise.resolve();
  });
  Media.pause = asNative(Media.pause, (target, self, args) => {
    const t = tracks.get(self);
    if (!t) return apply(target, self, args);
    if (t.paused) return;
    t.time = positionOf(t);
    t.paused = true;
    t.playing = false;
    send({ op: 'pause' });
    fire(self, 'pause');
    announce();
  });
  Media.load = asNative(Media.load, (target, self, args) => (tracks.has(self) ? undefined : apply(target, self, args)));

  // ---- What plays, for Now Playing.

  const artworkOf = (metadata) => {
    const art = metadata && metadata.artwork;
    if (!art || !art.length) return '';
    const size = (a) => Math.max(0, ...String(a.sizes || '0x0').split(/\s+/).map((s) => parseInt(s, 10) || 0));
    try {
      return new URL([...art].sort((a, b) => size(b) - size(a))[0].src, location.href).href;
    } catch (e) {
      return '';
    }
  };
  const sendMetadata = () => {
    if (!media) return;
    const md = session && session.metadata;
    send({ op: 'metadata', title: (md && md.title) || '', artist: (md && md.artist) || '', album: (md && md.album) || '', artwork: artworkOf(md) });
  };
  const metadata = sessionProto && getOwnPropertyDescriptor(sessionProto, 'metadata');
  if (metadata && metadata.set) {
    defineProperty(sessionProto, 'metadata', {
      ...metadata,
      set(value) {
        apply(metadata.set, this, [value]);
        guard(sendMetadata)();
      },
    });
  }

  // ---- A playlist for the element: the track goes to the helper.

  const encryptedEvent = (skd) => {
    const event = new Event('encrypted');
    event.initDataType = 'cbcs';
    event.initData = encoder.encode(skd);
    event.fromPolyfill = true;
    return event;
  };
  // Whether |value|, about to become |el|'s source, is a FairPlay playlist
  // this script plays instead.
  const bridge = (el, value) => {
    const url = String(value);
    if (enabled !== true || !el || !everKeyed.has(el)) {
      if (enabled === true && url) trace('source ' + url.slice(0, 60) + ': left to Chromium, the element has no FairPlay keys');
      return false;
    }
    const head = url.match(PLAYLIST_URL);
    if (!head) {
      trace('source ' + url.slice(0, 60) + ': left to Chromium, not a playlist');
      return false;
    }
    let playlist;
    try {
      playlist = /;base64/i.test(head[1]) ? atob(url.slice(head[0].length)) : decodeURIComponent(url.slice(head[0].length));
    } catch (e) {
      return false;
    }
    const skd = (playlist.match(/URI="(skd:\/\/[^"]+)"/) || [])[1];
    if (!/^#EXTM3U/.test(playlist) || !skd || !certificate) {
      trace('playlist of ' + playlist.length + ' characters: left to Chromium' + (skd ? '' : ', no skd:// key') + (certificate ? '' : ', no certificate'));
      return false;
    }
    trace('playlist of ' + playlist.length + ' characters: to the helper');
    const previous = tracks.get(el);
    if (media && media !== el) release(media);
    const t = {
      gen: 0,
      playlist,
      cert: certificate,
      loaded: false,
      detached: false,
      ready: 0,
      time: 0,
      stamp: now(),
      duration: NaN,
      paused: true,
      playing: false,
      ended: false,
      error: null,
      failed: false,
      seeks: 0,
      seeking: 0,
      volume: previous ? previous.volume : nativeValue(el, 'volume', 1),
      muted: previous ? previous.muted : nativeValue(el, 'muted', false),
    };
    tracks.set(el, t);
    stopTicking();
    attach(el, t);
    setTimeout(
      guard(() => {
        if (tracks.get(el) === t) el.dispatchEvent(encryptedEvent(skd));
      }),
      ENCRYPTED_DELAY_MS
    );
    return true;
  };
  const parentMedia = (source) => (source.parentElement instanceof HTMLMediaElement ? source.parentElement : null);
  const sourceSrc = getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
  defineProperty(HTMLSourceElement.prototype, 'src', {
    ...sourceSrc,
    set(value) {
      if (guard(bridge)(parentMedia(this) || keyed, value)) return;
      guard(unbridge)(parentMedia(this));
      apply(sourceSrc.set, this, [value]);
    },
  });
  const mediaSrc = getOwnPropertyDescriptor(Media, 'src');
  defineProperty(Media, 'src', {
    ...mediaSrc,
    set(value) {
      if (guard(bridge)(this, value)) return;
      guard(unbridge)(this);
      apply(mediaSrc.set, this, [value]);
    },
  });
  const srcObject = getOwnPropertyDescriptor(Media, 'srcObject');
  if (srcObject && srcObject.set) {
    defineProperty(Media, 'srcObject', {
      ...srcObject,
      set(value) {
        guard(unbridge)(this);
        apply(srcObject.set, this, [value]);
      },
    });
  }
  const ElementProto = Element.prototype;
  const isSrc = (name) => typeof name === 'string' && name.toLowerCase() === 'src';
  defineProperty(Media, 'setAttribute', {
    ...getOwnPropertyDescriptor(ElementProto, 'setAttribute'),
    value: asNative(ElementProto.setAttribute, (target, self, args) => {
      if (isSrc(args[0])) {
        if (guard(bridge)(self, args[1])) return;
        guard(unbridge)(self);
      }
      return apply(target, self, args);
    }),
  });
  defineProperty(Media, 'removeAttribute', {
    ...getOwnPropertyDescriptor(ElementProto, 'removeAttribute'),
    value: asNative(ElementProto.removeAttribute, (target, self, args) => {
      if (isSrc(args[0])) guard(unbridge)(self);
      return apply(target, self, args);
    }),
  });

  // Sends |el|'s track to the helper, in parts a console message carries.
  function attach(el, t) {
    const previousGen = t.gen;
    const gen = ++generation;
    t.gen = gen;
    t.detached = false;
    t.loaded = false;
    if (previousGen && pending && sessionGeneration.get(pending) === previousGen) sessionGeneration.set(pending, gen);
    media = el;
    request = null;
    const { playlist } = t;
    const parts = Math.max(1, Math.ceil(playlist.length / PLAYLIST_PART));
    for (let part = 0; part < parts; part++) {
      const chunk = playlist.slice(part * PLAYLIST_PART, (part + 1) * PLAYLIST_PART);
      send({ op: 'load', gen, part, parts, playlist: chunk, cert: part === 0 ? t.cert : null, volume: t.volume, muted: t.muted });
    }
    sendMetadata();
    announce();
    setTimeout(
      guard(() => {
        if (tracks.get(el) === t && t.gen === gen && !t.loaded && !t.detached) fail(el, t);
      }),
      READY_GIVE_UP_MS
    );
  }
  // The helper plays something else now: the element reads as paused.
  function release(el) {
    const t = tracks.get(el);
    if (!t) return;
    t.detached = true;
    if (t.paused) return;
    t.time = positionOf(t);
    t.paused = true;
    t.playing = false;
    stopTicking();
    fire(el, 'pause');
    announce();
  }
  // The element got another source: it is the page's again.
  function unbridge(el) {
    if (!el || !tracks.has(el)) return;
    tracks.delete(el);
    if (media === el) {
      media = null;
      request = null;
      stopTicking();
      send({ op: 'stop' });
      announce();
    }
    fire(el, 'emptied');
  }
  const fail = (el, t) => {
    if (t.failed) return;
    if (media === el && drives(t)) {
      request = null;
      send({ op: 'stop' });
    }
    t.failed = true;
    t.playing = false;
    t.paused = true;
    stopTicking();
    trace('the track failed');
    t.error = { code: 3, message: 'Protected playback failed', MEDIA_ERR_ABORTED: 1, MEDIA_ERR_NETWORK: 2, MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 };
    fire(el, 'error');
    // OpenArch offers Safari's engine instead.
    send({ op: 'failed' });
    announce();
  };

  // ---- From OpenArch: the helper's events, the media keys, the sidebar.

  const remote = (command, time) => {
    const t = media && tracks.get(media);
    const action = command === 'toggle' ? (t && !t.paused ? 'pause' : 'play') : command;
    const handler = actions.get(action);
    if (handler) return handler(action === 'seekto' ? { action, seekTime: time } : { action });
    if (!media) return;
    if (action === 'play') media.play();
    else if (action === 'pause') media.pause();
    else if (action === 'seekto' && isFinite(time)) media.currentTime = time;
  };
  const handle = (m) => {
    if (m.event === 'config') return configure(m.on === true, m.trace === true);
    if (m.event === 'remote') return remote(m.command, m.time);
    const el = media;
    const t = el && tracks.get(el);
    if (!t || m.gen !== t.gen || t.failed) return;
    if (m.event === 'request') {
      request = { gen: m.gen, message: fromBase64(m.spc).buffer };
      deliverRequest();
    } else if (m.event === 'ready') {
      t.loaded = true;
      t.duration = m.duration;
      t.ready = 4;
      for (const type of ['loadedmetadata', 'durationchange', 'loadeddata', 'canplay', 'canplaythrough']) fire(el, type);
      announce();
    } else if (m.event === 'position') {
      if (m.seq < t.seeks) return;
      t.time = m.time;
      t.stamp = now();
      if (t.seeking) finishSeek(t, el);
      const was = t.playing;
      t.playing = !!m.playing && !t.paused;
      if (t.playing && !was) fire(el, 'playing');
      else if (was && !t.playing && !t.paused) fire(el, 'waiting');
      // Chromium slows a hidden tab's timers down to one a minute; the
      // helper's reports keep the page's clock going.
      if (t.playing && document.hidden) fire(el, 'timeupdate');
      announce();
    } else if (m.event === 'ended') {
      if (!Number.isNaN(t.duration)) t.time = t.duration;
      t.playing = false;
      t.paused = true;
      t.ended = true;
      stopTicking();
      fire(el, 'timeupdate');
      fire(el, 'pause');
      fire(el, 'ended');
      announce();
    } else if (m.event === 'failed') {
      fail(el, t);
    } else if (m.event === 'stolen') {
      release(el);
    }
  };
  document.addEventListener(
    'openarch-fairplay',
    guard((event) => {
      if (event.detail && typeof event.detail === 'object') handle(event.detail);
    })
  );
  // The sidebar's player (media.js): "toggle", "seek <seconds>".
  document.addEventListener(
    'openarch-media-bridge-invoke',
    guard((event) => {
      if (typeof event.detail !== 'string') return;
      const [command, value] = event.detail.split(' ');
      if (command === 'toggle') remote('toggle');
      else if (command === 'seek') remote('seekto', Number(value));
    })
  );
  document.addEventListener('openarch-media-hello', guard(announce));
  addEventListener(
    'pagehide',
    guard((e) => {
      if (!e.isTrusted || !media) return;
      send({ op: 'stop' });
      release(media);
    })
  );
  send({ op: 'hello' });
})();
