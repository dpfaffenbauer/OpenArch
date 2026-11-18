// Adapted from Ardia's page script (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios/page_script.js: its protected video bridge and its
// video mirror), Apache License 2.0, Copyright 2026 Mantra Patel. Changed
// for OpenArch. See NOTICE.
//
// Netflix and Disney+ in a Chromium page (Settings › Allgemein › Geschützte
// Inhalte › „Streamingdienste in Chromium abspielen“, ProtectedVideo.swift).
// Chromium has no DRM these services accept, macOS has Apple's FairPlay. So
// this script, in the page's own world before the page's scripts, makes the
// page look like Safari to the site's player: Safari's user agent,
// FairPlay as the key system, and a MediaSource whose buffers do not go to
// Chromium's decoder but to OpenArch, which decodes and draws them with
// Apple's player in a view over the <video> (OpenArchProtectedVideo). The
// page's own code trades the key requests for licences with the service.
// The <video> itself never plays: it answers the page (currentTime, paused,
// buffered, its events) with what OpenArch reports. Because that view
// covers the site's controls, the "video mirror" below sends a copy of the
// player's DOM, which OpenArch draws over the picture; clicks go through it
// to the real controls underneath.
//
// The built-in extension's background.js registers this script only while
// the setting is on (protected-video-relay.js tells it). Netflix also wants
// Safari's user agent on the requests themselves: a small extension of its
// own does that (OptionalExtensions/safari-user-agent), loaded at launch
// while the setting is on.
//
// To OpenArch: messages wait in a queue that OpenArch fetches with the
// DevTools protocol (a console message only says that something waits), so
// megabytes of video a second never go through the console. From OpenArch:
// an "openarch-pv" DOM event.
//
// The first part (to "Ardia's code") is OpenArch's; the rest is Ardia's
// code, kept close to it (its formatting too) so that its fixes can follow.
(() => {
  "use strict";
  // The self-test runs this script by hand in a page of its own.
  const test = globalThis.__openarchFairPlayTest === true;
  if (window !== window.top) return;
  if (!test && !["https://www.netflix.com", "https://www.disneyplus.com"].includes(location.origin)) return;

  const MARKER = "__openarch_pv__";
  // What one fetch carries at most (characters of JSON).
  const TAKE_CHARS = 4000000;
  // The page's scripts run after this one and may wrap the console.
  const pageConsole = console;
  const debug = console.debug;
  const isTop = true;
  const handlers = Object.create(null);
  const { stringify: toJSON } = JSON;
  const apply = Reflect.apply;
  const asNative = (native, call) => {
    const { getPrototypeOf: protoOf, setPrototypeOf: setProtoOf } = Reflect;
    const disguised = new Proxy(native, {
      apply: (target, self, args) => call(target, self, args),
      setPrototypeOf(target, next) {
        for (let link = next; link !== null; link = protoOf(link))
          if (link === disguised || link === target) throw new TypeError("Cyclic __proto__ value");
        return setProtoOf(target, next);
      },
    });
    return disguised;
  };
  const { keys, setPrototypeOf } = Object;
  const { isArray } = Array;
  const { isFinite } = Number;
  const plain = (value, depth) => {
    if (value === null || typeof value === "string" || typeof value === "boolean") return value;
    if (typeof value === "number") return isFinite(value) ? value : null;
    if (typeof value !== "object" || depth > 4) return null;
    const out = setPrototypeOf(isArray(value) ? [] : {}, null);
    const names = keys(value);
    for (let i = 0; i < names.length; i++) {
      const v = value[names[i]];
      if (v !== undefined && typeof v !== "function") out[names[i]] = plain(v, depth + 1);
    }
    return out;
  };

  // This document's name: what OpenArch fetched from the one before it in
  // this tab does not count here.
  const DOC = Math.random().toString(36).slice(2);
  // Messages for OpenArch, oldest first; firstSeq is the first one's number.
  const outbox = [];
  let firstSeq = 1;
  // Nothing waits and OpenArch knows it: the next message has to say so.
  let idle = true;
  const send = (kind, data) => {
    outbox.push(toJSON({ kind, data: plain(data, 0) }));
    if (!idle) return;
    idle = false;
    apply(debug, pageConsole, [MARKER + " nudge"]);
  };
  // A new document: what OpenArch had from the one before is over.
  apply(debug, pageConsole, [MARKER + " start"]);
  // OpenArch fetches: it has everything up to |ack|, and gets what waits
  // (its event's detail is an object of this world, the answer goes into it).
  document.addEventListener("openarch-pv-take", (event) => {
    const take = event.detail;
    if (!take || typeof take !== "object") return;
    const ack = take.doc === DOC ? Math.floor(+take.ack || 0) : 0;
    const acked = Math.min(Math.max(ack - firstSeq + 1, 0), outbox.length);
    if (acked) {
      outbox.splice(0, acked);
      firstSeq += acked;
    }
    let count = 0;
    let chars = 0;
    while (count < outbox.length && (!count || chars + outbox[count].length <= TAKE_CHARS)) chars += outbox[count++].length;
    if (!count) idle = true;
    take.out =
      '{"doc":"' + DOC + '","from":' + firstSeq + ',"viewport":[' + innerWidth + "," + innerHeight + "," + devicePixelRatio + '],"messages":[' +
      outbox.slice(0, count).join(",") + "]}";
  });
  // The self-test measures what this way carries.
  if (test) globalThis.__openarchPVSend = send;
  const guard = (fn) =>
    function () {
      try {
        return apply(fn, this, arguments);
      } catch (e) {}
    };

  document.addEventListener("openarch-pv", (event) => {
    const m = event.detail;
    if (!m || typeof m !== "object") return;
    const handler = handlers[m.kind];
    if (handler) guard(handler)(m.message);
  });
  // The extension's relay asks whether this script runs in the page.
  document.addEventListener("openarch-pv-ping", (event) => event.preventDefault());

  // The page's own play and pause (its media session), for Picture in
  // Picture's button.
  const actions = new Map();
  const mediaSession = navigator.mediaSession;
  const mediaSessionProto = mediaSession && Object.getPrototypeOf(mediaSession);
  if (mediaSessionProto && mediaSessionProto.setActionHandler) {
    mediaSessionProto.setActionHandler = asNative(mediaSessionProto.setActionHandler, (target, self, args) => {
      const result = apply(target, self, args);
      if (typeof args[1] === "function") actions.set(String(args[0]), args[1]);
      else actions.delete(String(args[0]));
      return result;
    });
  }
  const askSiteToMatch = guard((paused) => {
    const action = paused ? "pause" : "play";
    actions.get(action)?.({ action });
  });

  // ---- Ardia's code.

  const raf = window.requestAnimationFrame;
  const holds = (outer, inner) => {
    for (let n = inner; n; n = n.parentNode || n.host) if (n === outer) return true;
    return false;
  };
  const pinnedOver = (el, x, y) => {
    for (let e = document.elementFromPoint(x, y); e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
      if (holds(e, el)) return null;
      const position = getComputedStyle(e).position;
      if (position === "fixed" || position === "sticky") return e.getBoundingClientRect();
    }
    return null;
  };
  const opaqueBackground = (el) => {
    for (let e = el; e; e = e.parentElement) {
      const m = /^rgba?\(([^)]*)\)$/.exec(getComputedStyle(e).backgroundColor);
      const parts = m ? m[1].split(/[\s,/]+/).filter(Boolean).map(Number) : [];
      if (parts.length >= 3 && (parts.length < 4 || parts[3] >= 0.98)) return parts.slice(0, 3);
    }
    return null;
  };
  const cornerRadius = (el, r) => {
    for (let e = el, depth = 0; e && e !== document.body && depth < 8; e = e.parentElement, depth++) {
      const style = getComputedStyle(e);
      const radius = parseFloat(style.borderTopLeftRadius) || 0;
      if (radius <= 0 || (e !== el && style.overflow === "visible")) continue;
      const box = e.getBoundingClientRect();
      const near = (a, b) => Math.abs(a - b) < 2;
      if (!(near(box.left, r.left) && near(box.right, r.right) && near(box.top, r.top) && near(box.bottom, r.bottom))) break;
      return { radius, backdrop: opaqueBackground(e.parentElement) };
    }
    return { radius: 0, backdrop: null };
  };
  const pinnedCover = (el, r) => {
    const left = Math.max(r.left, 0);
    const right = Math.min(r.right, innerWidth);
    const top = Math.max(r.top, 0);
    const bottom = Math.min(r.bottom, innerHeight);
    const cover = { top: 0, bottom: 0, radius: 0, backdrop: null };
    if (right - left < 2 || bottom - top < 2) return cover;
    const corner = cornerRadius(el, r);
    cover.radius = corner.radius;
    cover.backdrop = corner.backdrop;
    for (let i = 1; i <= 3; i++) {
      const x = left + ((right - left) * i) / 4;
      const above = pinnedOver(el, x, top + 1);
      if (above && above.top <= top + 1) cover.top = Math.max(cover.top, Math.min(above.bottom, bottom) - r.top);
      const below = pinnedOver(el, x, bottom - 1);
      if (below && below.bottom >= bottom - 1) cover.bottom = Math.max(cover.bottom, r.bottom - Math.max(below.top, top));
    }
    return cover;
  };

  const videoMirror = (() => {
    const MIRROR_ORIGINS = ["https://www.netflix.com", "https://www.disneyplus.com", "https://www.youtube.com"];
    const PLAYER_ROOTS = {
      "https://www.netflix.com": [".watch-video", "[data-uia='watch-video']"],
      "https://www.disneyplus.com": [".btm-media-player", "#hudson-wrapper", "disney-web-player"],
      "https://www.youtube.com": ["#movie_player", ".html5-video-player"],
    };
    if (test) {
      MIRROR_ORIGINS.push(location.origin);
      PLAYER_ROOTS[location.origin] = ["#player"];
    }
    const PLAYER_OVERLAYS = {
      "https://www.netflix.com": [".player-info"],
    };
    const CAPTION_REGIONS = {
      "https://www.disneyplus.com": { region: ".timed-text-override-region", box: ".hive-subtitle-renderer-cue-positioning-box", relayoutEvent: "webkitfullscreenchange" },
    };
    const CAPTION_SEARCH_MS = 1000;
    const PART_CHARS = 16000;
    const PART_BYTES = 63000;
    const SLOW_MS = 500;
    const RETRY_MS = 2000;
    const RETRY_LIMIT = 5;
    const ROOT_GROWTH = 1.5;
    const COVER = 0.9;
    const CANVAS_PIXELS = 160000;
    const CANVAS_CHARS = 48000;
    const BLOB_PICTURES = 64;
    const VALUE_CHARS = 2000;
    const ATTR_CHARS = 100000;
    const BATCH_CHARS = 8000000;
    const SVG_NS = "http://www.w3.org/2000/svg";
    const MATH_NS = "http://www.w3.org/1998/Math/MathML";
    const DROPPED = new Set(["script", "noscript", "template", "base", "meta", "title", "link", "style", "track", "param"]);
    const BLANKED = new Set(["iframe", "frame", "frameset", "object", "embed", "portal", "fencedframe", "applet"]);
    const MEDIA = new Set(["video", "audio"]);
    const URL_ATTRS = new Set(["href", "src", "xlink:href", "action", "formaction", "data", "poster", "background", "ping", "srcset", "lowsrc"]);
    const PSEUDO = /(?<!\\):(focus-visible|focus-within|popover-open|-webkit-full-screen|fullscreen|hover|focus|active|modal|defined)(?![\w-])/g;
    const PSEUDO_STATE = { "-webkit-full-screen": "fullscreen" };
    const STATES = ["hover", "active", "focus", "focus-within", "focus-visible", "fullscreen", "popover-open", "modal", "clear"];
    const idle = { start() {}, ensure() {}, stop() {}, prepare() {} };
    if (!isTop) return idle;
    const MO = window.MutationObserver;
    const RO = window.ResizeObserver;
    const repeat = window.setInterval;
    const unrepeat = window.clearInterval;
    const frameLater = window.requestAnimationFrame;
    const clock = performance;
    const clockNow = clock.now;
    const now = () => apply(clockNow, clock, []);
    const encoder = new TextEncoder();
    const closedRoots = new WeakMap();
    const awaitingDefinition = new WeakSet();
    let s = null;
    let testMode = false;
    let retryVideo = null;
    let retryAt = 0;
    let retries = 0;

    const composedParent = (n) => {
      const p = n.parentNode;
      return p && p.nodeType === 11 ? p.host : p;
    };
    const shadowOf = (el) => (el.nodeType === 1 && (el.shadowRoot || closedRoots.get(el))) || null;
    const composedContains = (outer, n) => {
      for (let x = n; x; x = composedParent(x)) if (x === outer) return true;
      return false;
    };
    if (MIRROR_ORIGINS.includes(location.origin) && typeof Element.prototype.attachShadow === "function")
      Element.prototype.attachShadow = asNative(Element.prototype.attachShadow, (target, self, args) => {
        const root = apply(target, self, args);
        if (args[0] && args[0].mode === "closed") closedRoots.set(self, root);
        if (s && s.known.has(self)) {
          s.newShadows.add(self);
          schedule();
        }
        return root;
      });

    const rewriteSelector = (text) =>
      text.replace(PSEUDO, (m, name) => (name === "defined" ? ":not([data-ardia-undefined])" : `[data-ardia-${PSEUDO_STATE[name] || name}]`));
    const absolutize = (text, base) =>
      text.replace(/url\(\s*(['"]?)([^'")]*)\1\s*\)/g, (m, q, u) => {
        const url = u.trim();
        if (!url || /^(data:|blob:|about:|#)/i.test(url)) return m;
        try {
          return `url("${new URL(url, base).href}")`;
        } catch (e) {
          return m;
        }
      });
    const listText = (rules) => {
      let out = "";
      for (let i = 0; i < rules.length; i++) out += ruleText(rules[i]) + "\n";
      return out;
    };
    const ruleText = (rule) => {
      const inner = rule.cssRules;
      if (rule instanceof CSSStyleRule) return rewriteSelector(rule.selectorText) + "{" + rule.style.cssText + (inner && inner.length ? listText(inner) : "") + "}";
      if (inner && !(rule instanceof CSSKeyframesRule)) {
        const text = rule.cssText;
        const brace = text.indexOf("{");
        if (brace > 0) return text.slice(0, brace) + "{" + listText(inner) + "}";
      }
      return rule.cssText;
    };
    const fetched = new Map();
    const fetchSheet = (href) => {
      if (fetched.has(href) || !/^https:/.test(href)) return;
      fetched.set(href, null);
      fetch(href, { credentials: "omit", mode: "cors" })
        .then((r) => (r.ok ? r.text() : null))
        .then((text) => {
          if (text === null) return;
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(text);
          fetched.set(href, absolutize(listText(sheet.cssRules), href));
          schedule();
        })
        .catch(() => {});
    };
    const sheetIds = new WeakMap();
    let sheetSeq = 0;
    const sheetEdits = new WeakMap();
    const noteSheetEdit = (sheet) => {
      if (!sheet) return;
      sheetEdits.set(sheet, (sheetEdits.get(sheet) || 0) + 1);
      if (s) schedule();
    };
    const watchSheetEdits = (proto, names, sheetOf) => {
      if (!proto) return;
      const edited = (target, self, args) => {
        const result = apply(target, self, args);
        const sheet = sheetOf(self);
        noteSheetEdit(sheet);
        if (result && typeof result.then === "function") result.then(() => noteSheetEdit(sheet), () => noteSheetEdit(sheet));
        return result;
      };
      for (const name of names) {
        const was = Object.getOwnPropertyDescriptor(proto, name);
        if (was && typeof was.value === "function") Object.defineProperty(proto, name, { ...was, value: asNative(was.value, edited) });
        else if (was && was.set) Object.defineProperty(proto, name, { ...was, set: asNative(was.set, edited) });
      }
    };
    if (MIRROR_ORIGINS.includes(location.origin)) {
      const ruleSheet = (rule) => rule && rule.parentStyleSheet;
      watchSheetEdits(window.CSSStyleSheet && CSSStyleSheet.prototype, ["insertRule", "deleteRule", "addRule", "removeRule", "replace", "replaceSync"], (sheet) => sheet);
      watchSheetEdits(window.CSSGroupingRule && CSSGroupingRule.prototype, ["insertRule", "deleteRule"], ruleSheet);
      watchSheetEdits(window.CSSKeyframesRule && CSSKeyframesRule.prototype, ["appendRule", "deleteRule"], ruleSheet);
      watchSheetEdits(window.CSSStyleRule && CSSStyleRule.prototype, ["selectorText"], ruleSheet);
      watchSheetEdits(window.CSSStyleDeclaration && CSSStyleDeclaration.prototype, ["setProperty", "removeProperty", "cssText"], (style) => ruleSheet(style.parentRule));
    }
    const sheetEntry = (sheet) => {
      let rules = null;
      try {
        rules = sheet.cssRules;
      } catch (e) {}
      const media = sheet.media && sheet.media.mediaText;
      const wrap = (text) => (media ? `@media ${media}{${text}}` : text);
      if (rules) return { sig: `r${rules.length}|${sheetEdits.get(sheet) || 0}|${media || ""}`, x: () => wrap(absolutize(listText(rules), sheet.href || document.baseURI)) };
      if (!sheet.href) return null;
      const text = fetched.get(sheet.href);
      if (text) return { sig: "f|" + (media || ""), x: () => wrap(text) };
      fetchSheet(sheet.href);
      return { sig: "h|" + (media || ""), h: sheet.href, m: media || "" };
    };
    const sheetList = (scope, pre) => {
      const ids = [];
      const all = [...scope.styleSheets, ...(scope.adoptedStyleSheets || [])];
      for (const sheet of all) {
        if (sheet.disabled) continue;
        let id = sheetIds.get(sheet);
        if (!id) sheetIds.set(sheet, (id = ++sheetSeq));
        const entry = sheetEntry(sheet);
        if (!entry) continue;
        ids.push(id);
        if (s.sheetSigs.get(id) === entry.sig) continue;
        s.sheetSigs.set(id, entry.sig);
        pre.push(entry.h ? { o: "put", id, h: entry.h, m: entry.m } : { o: "put", id, x: entry.x() });
      }
      return ids;
    };
    const syncSheets = (pre) => {
      const scopes = [[0, document]];
      for (const root of s.shadows) if (s.known.has(root.host)) scopes.push([s.ids.get(root.host), root]);
      for (const [key, scope] of scopes) {
        const ids = sheetList(scope, pre);
        const joined = ids.join(",");
        if (s.sheetLists.get(key) === joined) continue;
        s.sheetLists.set(key, joined);
        pre.push({ o: "sl", i: key, l: ids });
      }
    };

    const idOf = (n) => {
      let id = s.ids.get(n);
      if (!id) s.ids.set(n, (id = ++s.idSeq));
      return id;
    };
    const cleanAttr = (tag, name, value) => {
      const lower = name.toLowerCase();
      if (lower.startsWith("on") || lower === "nonce" || lower === "srcdoc" || lower === "autofocus" || lower.startsWith("data-ardia-")) return null;
      if (MEDIA.has(tag) && (lower === "src" || lower === "poster" || lower === "autoplay" || lower === "controls")) return null;
      if (BLANKED.has(tag) && (lower === "src" || lower === "data")) return null;
      if (URL_ATTRS.has(lower) && /^(javascript|vbscript|blob):/.test(value.replace(/[\u0000-\u0020]/g, "").toLowerCase())) return null;
      return value.length > ATTR_CHARS ? null : value;
    };
    const attrsOf = (el) => {
      const tag = el.localName;
      const out = [];
      const list = el.attributes;
      for (let i = 0; i < list.length; i++) {
        const value = cleanAttr(tag, list[i].name, list[i].value);
        if (value !== null) out.push([list[i].name, value]);
      }
      if (tag.includes("-") && !customElements.get(tag)) {
        out.push(["data-ardia-undefined", ""]);
        if (awaitingDefinition.has(el)) return out;
        awaitingDefinition.add(el);
        customElements.whenDefined(tag).then(() => {
          if (s && s.known.has(el)) {
            s.dirtyAttrs.add(el);
            schedule();
          }
        });
      }
      if (tag === "video" && !el.hasAttribute("width") && el.videoWidth) out.push(["width", String(el.videoWidth)], ["height", String(el.videoHeight)]);
      if (tag === "img" && /^blob:/i.test((el.getAttribute("src") || "").trim())) {
        const picture = blobPicture(el);
        if (picture) out.push(["src", picture]);
      }
      return out;
    };
    const formState = (el, out) => {
      if (el.type === "password") return out;
      if (el.type === "checkbox" || el.type === "radio") out.k = !!el.checked;
      else if (typeof el.value === "string") out.v = el.value.slice(0, VALUE_CHARS);
      return out;
    };
    const canvasPicture = (c) => {
      const pixels = c.width * c.height;
      if (!pixels || pixels > CANVAS_PIXELS) return null;
      try {
        const url = c.toDataURL();
        return url.length <= CANVAS_CHARS ? url : null;
      } catch (e) {
        return null;
      }
    };
    const blobPictures = new Map();
    const loadWatched = new WeakSet();
    const repaintOnLoad = (img) => {
      if (loadWatched.has(img)) return;
      loadWatched.add(img);
      img.addEventListener("load", () => {
        if (!s || !s.known.has(img)) return;
        s.dirtyAttrs.add(img);
        schedule();
      });
    };
    const dataUrlOf = (blob) =>
      new Promise((resolve) => {
        const reader = new FileReader();
        reader.onloadend = () => resolve(reader.result);
        reader.readAsDataURL(blob);
      });
    const blobPicture = (img) => {
      const src = img.currentSrc || img.src;
      if (blobPictures.has(src)) return blobPictures.get(src);
      repaintOnLoad(img);
      const w = img.naturalWidth;
      const h = img.naturalHeight;
      if (!img.complete || !w || !h) return null;
      blobPictures.set(src, null);
      if (blobPictures.size > BLOB_PICTURES) blobPictures.delete(blobPictures.keys().next().value);
      const scale = Math.min(1, Math.sqrt(CANVAS_PIXELS / (w * h)));
      const c = new OffscreenCanvas(Math.max(1, Math.round(w * scale)), Math.max(1, Math.round(h * scale)));
      try {
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
      } catch (e) {
        return null;
      }
      c.convertToBlob({ type: "image/jpeg", quality: 0.85 })
        .then(dataUrlOf)
        .then((url) => {
          if (typeof url !== "string" || url.length > CANVAS_CHARS || !blobPictures.has(src)) return;
          blobPictures.set(src, url);
          if (!s || !s.known.has(img)) return;
          s.dirtyAttrs.add(img);
          schedule();
        })
        .catch(() => {});
      return null;
    };
    const remember = (n, fresh) => {
      s.known.add(n);
      fresh.add(n);
      return idOf(n);
    };
    const describe = (n, fresh) => {
      if (n.nodeType === 3) return { i: remember(n, fresh), x: n.data };
      if (n.nodeType !== 1) return null;
      const tag = n.localName;
      if (DROPPED.has(tag)) return null;
      const out = { i: remember(n, fresh), t: BLANKED.has(tag) ? "div" : tag, a: attrsOf(n) };
      if (n.namespaceURI === SVG_NS) out.n = "s";
      else if (n.namespaceURI === MATH_NS) out.n = "m";
      if (n.scrollTop || n.scrollLeft) {
        out.sx = n.scrollLeft;
        out.sy = n.scrollTop;
      }
      if (MEDIA.has(tag) || BLANKED.has(tag)) return out;
      if (tag === "canvas") out.cv = canvasPicture(n);
      if (tag === "input" || tag === "textarea" || tag === "select") formState(n, out);
      out.c = childrenOf(n, fresh);
      const root = shadowOf(n);
      if (root) out.sh = describeShadow(root, fresh);
      return out;
    };
    const describeShadow = (root, fresh) => {
      watchShadow(root);
      return { c: childrenOf(root, fresh) };
    };
    const childrenOf = (parent, fresh) => {
      const out = [];
      for (let n = parent.firstChild; n; n = n.nextSibling) {
        if (s.known.has(n) && !fresh.has(n)) out.push({ r: s.ids.get(n) });
        else {
          const d = describe(n, fresh);
          if (d) out.push(d);
        }
      }
      if (parent === s.root)
        for (const o of s.overlays) {
          const d = s.known.has(o) && !fresh.has(o) ? { r: s.ids.get(o) } : describe(o, fresh);
          if (d) out.push(d);
        }
      return out;
    };
    const forget = (n) => {
      if (!s.known.has(n)) return;
      s.known.delete(n);
      for (let c = n.firstChild; c; c = c.nextSibling) forget(c);
      const root = shadowOf(n);
      if (root) {
        if (s.shadows.delete(root)) listenShadow(root, false);
        for (let c = root.firstChild; c; c = c.nextSibling) forget(c);
      }
    };
    const options = { childList: true, subtree: true, attributes: true, characterData: true };
    const SHADOW_EVENTS = ["scroll", "change"];
    const listenShadow = (root, on) => {
      for (const type of SHADOW_EVENTS) (on ? root.addEventListener : root.removeEventListener).call(root, type, listeners[type], { capture: true, passive: true });
    };
    const unwatchShadows = (st) => {
      for (const root of st.shadows) listenShadow(root, false);
      st.shadows.clear();
    };
    const watchShadow = (root) => {
      if (s.shadows.has(root)) return;
      s.shadows.add(root);
      s.observer.observe(root, options);
      listenShadow(root, true);
    };

    const captionRelayout = (() => {
      const spec = CAPTION_REGIONS[location.origin];
      if (!spec || !RO) return { start() {}, stop() {} };
      let region = null;
      let height = 0;
      let timer = 0;
      const findRegion = (scope) => {
        const hit = scope.querySelector(spec.region);
        if (hit) return hit;
        for (const el of scope.querySelectorAll("*")) {
          const root = shadowOf(el);
          const found = root && findRegion(root);
          if (found) return found;
        }
        return null;
      };
      const relayout = () => {
        if (!region) return;
        const was = height;
        height = region.getBoundingClientRect().height;
        const delta = height - was;
        if (!was || !delta) return;
        for (const box of region.querySelectorAll(spec.box)) {
          const top = parseFloat(box.style.top);
          if (isFinite(top) && top + box.offsetHeight / 2 > was / 2) box.style.top = top + delta + "px";
        }
        document.dispatchEvent(new Event(spec.relayoutEvent));
      };
      const observer = new RO(guard(relayout));
      const track = () => {
        if (region && region.isConnected) return;
        observer.disconnect();
        region = findRegion(document);
        height = 0;
        if (region) observer.observe(region);
      };
      return {
        start() {
          if (timer) return;
          track();
          timer = apply(repeat, window, [guard(track), CAPTION_SEARCH_MS]);
        },
        stop() {
          if (!timer) return;
          apply(unrepeat, window, [timer]);
          timer = 0;
          observer.disconnect();
          region = null;
        },
      };
    })();

    const pickRoot = (video) => {
      for (const selector of PLAYER_ROOTS[location.origin] || []) {
        let found = null;
        try {
          found = document.querySelector(selector);
        } catch (e) {}
        if (found && composedContains(found, video)) return found;
      }
      const base = video.getBoundingClientRect();
      const limit = Math.max(base.width * base.height, 1) * ROOT_GROWTH;
      let best = composedParent(video);
      for (let n = best && composedParent(best); n && n !== document.body && n !== document.documentElement; n = composedParent(n)) {
        const r = n.getBoundingClientRect();
        if (r.width * r.height > limit) break;
        best = n;
      }
      while (best && best.getRootNode() !== document) best = best.getRootNode().host || null;
      return best && best !== document.body && best !== document.documentElement ? best : null;
    };
    const overlaysOf = (root) => {
      const out = [];
      for (const selector of PLAYER_OVERLAYS[location.origin] || []) {
        let found = null;
        try {
          found = document.querySelector(selector);
        } catch (e) {}
        if (found && !composedContains(root, found) && !composedContains(found, root)) out.push(found);
      }
      return out;
    };
    const syncOverlays = () => {
      const found = overlaysOf(s.root);
      if (found.length === s.overlays.length && found.every((o, i) => o === s.overlays[i])) return;
      for (const o of s.overlays) if (!found.includes(o)) forget(o);
      for (const o of found) if (!s.overlays.includes(o)) s.observer.observe(o, options);
      s.overlays = found;
      s.dirtyChildren.add(s.root);
    };
    const pollOverlayValues = () => {
      for (const o of s.overlays)
        for (const el of o.querySelectorAll("textarea,input,select")) {
          if (!s.known.has(el) || s.sentValues.get(el) === el.value) continue;
          s.sentValues.set(el, el.value);
          s.dirtyValues.add(el);
        }
    };
    const shellsOf = (root) => {
      const list = [];
      for (let n = root.parentElement; n; n = n.parentElement) list.unshift(n);
      return list;
    };

    const deepActive = () => {
      let el = document.activeElement;
      for (let depth = 0; el && depth < 32; depth++) {
        const root = shadowOf(el);
        const inner = root && root.activeElement;
        if (!inner) break;
        el = inner;
      }
      return el;
    };
    const pointed = () => {
      if (!s.pointer) return null;
      const { x, y } = s.pointer;
      let el = document.elementFromPoint(x, y);
      for (let depth = 0; el && depth < 32; depth++) {
        const root = shadowOf(el);
        const inner = root && root.elementFromPoint(x, y);
        if (!inner || inner === el) break;
        el = inner;
      }
      return el;
    };
    const chainOf = (el) => {
      const out = [];
      for (let n = el; n && n.nodeType === 1; n = composedParent(n)) if (s.known.has(n)) out.push(s.ids.get(n));
      return out;
    };
    const idsOf = (list) => list.filter((el) => el && s.known.has(el)).map((el) => s.ids.get(el));
    const alphaOf = (c) => {
      if (!c || c === "transparent") return 0;
      const slash = c.lastIndexOf("/");
      if (slash >= 0) return parseFloat(c.slice(slash + 1));
      const m = /^rgba\((.*)\)$/.exec(c);
      return m ? parseFloat(m[1].split(",")[3]) : 1;
    };
    const clearList = () => {
      const box = s.video.getBoundingClientRect();
      const v = { left: Math.max(box.left, 0), top: Math.max(box.top, 0), right: Math.min(box.right, innerWidth), bottom: Math.min(box.bottom, innerHeight) };
      const area = Math.max(0, v.right - v.left) * Math.max(0, v.bottom - v.top);
      const out = [];
      if (area < 1) return out;
      const visit = (el) => {
        if (el.nodeType !== 1 || !s.known.has(el)) return;
        if (el.offsetWidth * el.offsetHeight >= area * COVER || el === s.root) {
          const r = el.getBoundingClientRect();
          const w = Math.min(r.right, v.right) - Math.max(r.left, v.left);
          const h = Math.min(r.bottom, v.bottom) - Math.max(r.top, v.top);
          if (w > 0 && h > 0 && w * h >= area * COVER && alphaOf(getComputedStyle(el).backgroundColor) >= 0.98) out.push(s.ids.get(el));
        }
        for (let c = el.firstElementChild; c; c = c.nextElementSibling) visit(c);
        const root = shadowOf(el);
        if (root) for (let c = root.firstElementChild; c; c = c.nextElementSibling) visit(c);
      };
      visit(s.root);
      return out;
    };
    const deepFullscreen = () => {
      let el = document.fullscreenElement;
      for (let depth = 0; el && depth < 32; depth++) {
        const root = shadowOf(el);
        const inner = root && root.fullscreenElement;
        if (!inner) break;
        el = inner;
      }
      return el;
    };
    const matching = (selector) => {
      try {
        return [...s.root.querySelectorAll(selector)];
      } catch (e) {
        return [];
      }
    };
    const stateOps = (ops) => {
      const focused = deepActive();
      let visible = false;
      try {
        visible = !!focused && focused.matches(":focus-visible");
      } catch (e) {}
      const lists = {
        hover: chainOf(pointed()),
        active: s.pressed ? s.pressed : [],
        focus: idsOf([focused]),
        "focus-within": chainOf(focused),
        "focus-visible": visible ? idsOf([focused]) : [],
        fullscreen: idsOf([deepFullscreen()]),
        "popover-open": idsOf(matching(":popover-open")),
        modal: idsOf(matching(":modal")),
        clear: s.clear,
      };
      for (const k of STATES) {
        const joined = lists[k].join(",");
        if (s.stateSent.get(k) === joined) continue;
        s.stateSent.set(k, joined);
        ops.push({ o: "st", k, l: lists[k] });
      }
    };
    const round = (v) => Math.round(v * 100) / 100;
    const frameOp = (ops) => {
      const r = s.root.getBoundingClientRect();
      const f = { o: "f", x: round(r.left), y: round(r.top), w: round(r.width), h: round(r.height), vw: innerWidth, vh: innerHeight, dpr: devicePixelRatio };
      const joined = [f.x, f.y, f.w, f.h, f.vw, f.vh, f.dpr].join(",");
      if (s.frameSent === joined) return;
      if (!s.frameSent || !s.frameSent.endsWith("," + f.vw + "," + f.vh + "," + f.dpr)) send("videoMirror", { op: "frame", dpr: f.dpr, vw: f.vw, vh: f.vh });
      s.frameSent = joined;
      ops.push(f);
    };

    const ship = (batch) => {
      const text = toJSON(batch);
      if (text.length > BATCH_CHARS) return stop();
      const seq = ++s.seq;
      const parts = [];
      for (let at = 0; at < text.length; ) {
        let len = Math.min(PART_CHARS, text.length - at);
        for (;;) {
          const code = text.charCodeAt(at + len - 1);
          if (at + len < text.length && code >= 0xd800 && code <= 0xdbff) len--;
          const chunk = text.slice(at, at + len);
          const escaped = toJSON(chunk);
          if (len <= 64 || escaped.length * 3 <= PART_BYTES || encoder.encode(escaped).length <= PART_BYTES) break;
          len >>= 1;
        }
        parts.push(text.slice(at, at + len));
        at += len;
      }
      for (let part = 0; part < parts.length; part++) send("videoMirror", { op: "part", seq, part, parts: parts.length, data: parts[part] });
    };
    const resetTracking = () => {
      s.known = new WeakSet();
      s.dirtyChildren.clear();
      s.dirtyAttrs.clear();
      s.dirtyText.clear();
      s.dirtyValues.clear();
      s.dirtyScroll.clear();
      s.removed.clear();
      s.newShadows.clear();
      unwatchShadows(s);
      s.sheetSigs.clear();
      s.sheetLists.clear();
      s.stateSent.clear();
      s.frameSent = "";
      s.observer.disconnect();
    };
    const snapshot = () => {
      const t0 = now();
      const root = pickRoot(s.video);
      if (!root) return stop();
      if (root !== s.root) {
        if (s.resizer) s.resizer.disconnect();
        s.root = root;
        if (s.resizer) s.resizer.observe(root);
      }
      resetTracking();
      s.overlays = overlaysOf(root);
      s.sentValues = new WeakMap();
      const fresh = new Set();
      const shellNodes = shellsOf(root);
      s.shellChain = shellNodes;
      const shells = shellNodes.map((n) => ({ i: remember(n, fresh), t: n.localName, a: attrsOf(n) }));
      s.observer.observe(root, options);
      for (const o of s.overlays) s.observer.observe(o, options);
      for (const n of shellNodes) s.observer.observe(n, { attributes: true });
      if (document.head) s.observer.observe(document.head, { childList: true, subtree: true, characterData: true });
      const tree = describe(root, fresh);
      const pre = [];
      syncSheets(pre);
      s.clear = clearList();
      const ops = [];
      stateOps(ops);
      frameOp(ops);
      ship({ t: "s", pre, shells, root: tree, ops, pm: round(now() - t0), pt: Date.now() });
    };
    const childOp = (parent, fresh, ops) => {
      if (parent.nodeType === 11) {
        const host = parent.host;
        if (host && s.known.has(host) && !fresh.has(host)) ops.push({ o: "c", i: s.ids.get(host), s: 1, c: childrenOf(parent, fresh) });
        return;
      }
      if (!s.known.has(parent) || fresh.has(parent) || MEDIA.has(parent.localName) || BLANKED.has(parent.localName)) return;
      if (s.shellChain.includes(parent)) return;
      ops.push({ o: "c", i: s.ids.get(parent), c: childrenOf(parent, fresh) });
    };
    const inRoot = (n) => {
      for (let x = n; x; x = composedParent(x)) if (x === s.root || s.overlays.includes(x)) return true;
      return false;
    };
    const flush = () => {
      s.queued = false;
      if (!s.video.isConnected) return stop();
      const shells = shellsOf(s.root);
      if (!s.root.isConnected || !composedContains(s.root, s.video) || shells.length !== s.shellChain.length || shells.some((n, i) => n !== s.shellChain[i]))
        return snapshot();
      const t0 = now();
      syncOverlays();
      if (s.slowDue) pollOverlayValues();
      const fresh = new Set();
      const pre = [];
      const ops = [];
      for (const host of s.newShadows) {
        const root = shadowOf(host);
        if (root && s.known.has(host) && !fresh.has(host)) ops.push({ o: "sr", i: s.ids.get(host), sh: describeShadow(root, fresh) });
      }
      s.newShadows.clear();
      for (const parent of s.dirtyChildren) childOp(parent, fresh, ops);
      for (const el of s.dirtyAttrs) if (s.known.has(el) && !fresh.has(el)) ops.push({ o: "a", i: s.ids.get(el), a: attrsOf(el) });
      for (const t of s.dirtyText) if (s.known.has(t) && !fresh.has(t)) ops.push({ o: "x", i: s.ids.get(t), x: t.data });
      for (const el of s.dirtyValues) if (s.known.has(el)) ops.push({ o: "v", i: s.ids.get(el), ...formState(el, {}) });
      for (const el of s.dirtyScroll) if (s.known.has(el)) ops.push({ o: "sc", i: s.ids.get(el), x: el.scrollLeft, y: el.scrollTop });
      for (const n of s.removed) if (!inRoot(n)) forget(n);
      s.dirtyChildren.clear();
      s.dirtyAttrs.clear();
      s.dirtyText.clear();
      s.dirtyValues.clear();
      s.dirtyScroll.clear();
      s.removed.clear();
      syncSheets(pre);
      if (s.slowDue) {
        s.slowDue = false;
        s.clear = clearList();
      }
      stateOps(ops);
      frameOp(ops);
      if (!pre.length && !ops.length) return;
      ship({ t: "p", pre, ops, pm: round(now() - t0), pt: Date.now() });
    };
    const schedule = () => {
      if (!s || s.queued) return;
      s.queued = true;
      apply(frameLater, window, [guard(() => s && flush())]);
    };

    const onRecords = (records) => {
      if (!s) return;
      for (const r of records) {
        if (r.type === "childList") {
          s.dirtyChildren.add(r.target);
          for (const n of r.removedNodes) s.removed.add(n);
        } else if (r.type === "attributes") s.dirtyAttrs.add(r.target);
        else if (r.type === "characterData") s.dirtyText.add(r.target);
      }
      schedule();
    };
    const eventTarget = (e) => {
      const path = e.composedPath();
      return path.length ? path[0] : e.target;
    };
    const listeners = {
      pointermove: (e) => {
        s.pointer = { x: e.clientX, y: e.clientY };
        schedule();
      },
      pointerdown: (e) => {
        s.pointer = { x: e.clientX, y: e.clientY };
        s.pressed = chainOf(pointed());
        schedule();
      },
      pointerup: () => {
        s.pressed = null;
        schedule();
      },
      pointercancel: () => {
        s.pressed = null;
        schedule();
      },
      mouseout: (e) => {
        if (e.relatedTarget) return;
        s.pointer = null;
        schedule();
      },
      input: (e) => {
        s.dirtyValues.add(eventTarget(e));
        schedule();
      },
      change: (e) => {
        s.dirtyValues.add(eventTarget(e));
        schedule();
      },
      scroll: (e) => {
        const target = eventTarget(e);
        if (target && target.nodeType === 1) s.dirtyScroll.add(target);
        schedule();
      },
      focusin: () => schedule(),
      focusout: () => schedule(),
      keydown: () => schedule(),
      fullscreenchange: () => schedule(),
      resize: () => schedule(),
    };
    const start = (video) => {
      if (!video || video.localName !== "video") return;
      if (s && s.video === video) return;
      if (!video.isConnected) return;
      if (s) stop();
      s = {
        video,
        root: null,
        overlays: [],
        sentValues: new WeakMap(),
        idSeq: 0,
        ids: new WeakMap(),
        known: new WeakSet(),
        shellChain: [],
        dirtyChildren: new Set(),
        dirtyAttrs: new Set(),
        dirtyText: new Set(),
        dirtyValues: new Set(),
        dirtyScroll: new Set(),
        removed: new Set(),
        newShadows: new Set(),
        shadows: new Set(),
        sheetSigs: new Map(),
        sheetLists: new Map(),
        stateSent: new Map(),
        frameSent: "",
        clear: [],
        pointer: null,
        pressed: null,
        queued: false,
        slowDue: false,
        seq: 0,
        observer: new MO(guard(onRecords)),
        resizer: RO ? new RO(guard(() => schedule())) : null,
        timer: 0,
      };
      for (const type of keys(listeners)) window.addEventListener(type, listeners[type], { capture: true, passive: true });
      s.timer = apply(repeat, window, [
        guard(() => {
          if (!s) return;
          s.slowDue = true;
          schedule();
        }),
        SLOW_MS,
      ]);
      guard(snapshot)();
      captionRelayout.start();
    };
    const stop = () => {
      if (!s) return;
      const was = s;
      s = null;
      captionRelayout.stop();
      was.observer.disconnect();
      unwatchShadows(was);
      if (was.resizer) was.resizer.disconnect();
      apply(unrepeat, window, [was.timer]);
      for (const type of keys(listeners)) window.removeEventListener(type, listeners[type], { capture: true });
      send("videoMirror", { op: "stop" });
    };
    const startOnPlay = (e) => {
      const target = e.target;
      if (testMode && target && target.localName === "video" && (!s || !s.video.isConnected)) start(target);
    };
    handlers.videoMirror = (message) => {
      if (!message) return;
      if (message.test && !testMode) {
        testMode = true;
        document.addEventListener("playing", startOnPlay, true);
        const playing = [...document.querySelectorAll("video")].find((v) => !v.paused);
        if (playing) start(playing);
      }
      if (message.resync && s) snapshot();
    };
    const ensure = (video) => {
      if (s || !video || !video.isConnected) return;
      if (video !== retryVideo) {
        retryVideo = video;
        retries = 0;
        retryAt = 0;
      }
      if (retries >= RETRY_LIMIT || now() - retryAt < RETRY_MS) return;
      retries++;
      retryAt = now();
      start(video);
    };
    const prepare = () => {
      if (s || !MIRROR_ORIGINS.includes(location.origin)) return;
      send("videoMirror", { op: "frame", dpr: devicePixelRatio, vw: innerWidth, vh: innerHeight });
    };
    return { start: guard(start), ensure: guard(ensure), stop: guard(stop), prepare: guard(prepare) };
  })();
  const PROTECTED_VIDEO_ORIGINS = ["https://www.netflix.com", "https://www.disneyplus.com"];
  if (test) PROTECTED_VIDEO_ORIGINS.push(location.origin);
  const PROTECTED_VIDEO_ON = true;
  try {
    if (isTop && PROTECTED_VIDEO_ON && PROTECTED_VIDEO_ORIGINS.includes(location.origin) && window.MediaSource) {
      const SAFARI_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15";
      const PLAYER_ROUTE = location.origin === "https://www.netflix.com" ? /^\/watch\// : /^\/play\//;
      const UNDECODABLE = /av01|vp0?9|dvh1|dvhe|dav1/i;
      const FAIRPLAY = /^com\.apple\.fps/;
      const OTHER_KEY_SYSTEMS = /^com\.(widevine|microsoft|chromecast|youtube)/;
      const PART_BYTES = 45000;
      const MAX_KEY_BYTES = 45000;
      const MAX_PENDING_BYTES = 64e6;
      const MAX_BUFFER_ID = 64;
      const TICK_MS = 250;
      const FRAME_RATE = 24;
      const KEY_WAIT_MS = 15000;
      const AHEAD_LIMIT_S = 1;
      const KEEP_BEHIND_S = 5;
      const VIDEO_QUOTA = 200e6;
      const AUDIO_QUOTA = 24e6;
      const { defineProperty, getOwnPropertyDescriptor, create } = Object;
      const fromCharCode = String.fromCharCode;
      const { btoa, atob } = window;
      const clock = performance;
      const clockNow = clock.now;
      const now = () => apply(clockNow, clock, []);
      const soon = (fn, ms) => setTimeout(guard(fn), ms);
      const face = { userAgent: SAFARI_UA, appVersion: SAFARI_UA.slice(8), vendor: "Apple Computer, Inc.", platform: "MacIntel", userAgentData: undefined };
      for (const name of keys(face)) {
        const was = getOwnPropertyDescriptor(Navigator.prototype, name);
        if (was && was.get) defineProperty(Navigator.prototype, name, { ...was, get: asNative(was.get, () => face[name]) });
      }
      try {
        delete window.chrome;
      } catch (e) {}

      const mp4 = (() => {
        const fourcc = (u, i) => String.fromCharCode(u[i], u[i + 1], u[i + 2], u[i + 3]);
        const viewOf = (u) => new DataView(u.buffer, u.byteOffset, u.byteLength);
        const boxes = (u, start, end) => {
          const view = viewOf(u);
          const found = [];
          let at = start;
          while (at + 8 <= end) {
            let size = view.getUint32(at);
            let header = 8;
            if (size === 1) {
              if (at + 16 > end) break;
              size = view.getUint32(at + 8) * 4294967296 + view.getUint32(at + 12);
              header = 16;
            } else if (size === 0) size = end - at;
            if (size < header || at + size > end) break;
            found.push({ type: fourcc(u, at + 4), start: at, body: at + header, end: at + size });
            at += size;
          }
          return found;
        };
        const child = (u, box, type) => box && boxes(u, box.body, box.end).find((b) => b.type === type);
        const describeInit = (u) => {
          const view = viewOf(u);
          const info = { timescale: 1, sampleDuration: 0, width: 0, height: 0, duration: 0 };
          const moov = boxes(u, 0, u.length).find((b) => b.type === "moov");
          const trak = child(u, moov, "trak");
          const tkhd = child(u, trak, "tkhd");
          if (tkhd) {
            const at = tkhd.body + (u[tkhd.body] === 1 ? 88 : 76);
            if (at + 8 <= tkhd.end) {
              info.width = view.getUint32(at) >>> 16;
              info.height = view.getUint32(at + 4) >>> 16;
            }
          }
          const mdhd = child(u, child(u, trak, "mdia"), "mdhd");
          if (mdhd) info.timescale = view.getUint32(mdhd.body + (u[mdhd.body] === 1 ? 20 : 12)) || 1;
          const trex = child(u, child(u, moov, "mvex"), "trex");
          if (trex) info.sampleDuration = view.getUint32(trex.body + 12);
          const wideAt = (at) => view.getUint32(at) * 4294967296 + view.getUint32(at + 4);
          const mvhd = child(u, moov, "mvhd");
          if (mvhd && mvhd.body + 32 <= mvhd.end) {
            const wide = u[mvhd.body] === 1;
            const scale = view.getUint32(mvhd.body + (wide ? 20 : 12));
            const whole = wide ? wideAt(mvhd.body + 24) : view.getUint32(mvhd.body + 16);
            const mehd = child(u, child(u, moov, "mvex"), "mehd");
            const fragments = mehd && mehd.body + (u[mehd.body] === 1 ? 12 : 8) <= mehd.end ? (u[mehd.body] === 1 ? wideAt(mehd.body + 4) : view.getUint32(mehd.body + 4)) : 0;
            const unknown = (n) => n === 0xffffffff || n >= Number.MAX_SAFE_INTEGER;
            const longest = Math.max(unknown(whole) ? 0 : whole, unknown(fragments) ? 0 : fragments);
            if (scale && longest) info.duration = longest / scale;
          }
          return info;
        };
        const fragmentTimes = (u, info) => {
          const view = viewOf(u);
          let start = null;
          let duration = 0;
          for (const moof of boxes(u, 0, u.length)) {
            if (moof.type !== "moof") continue;
            const traf = child(u, moof, "traf");
            if (!traf) continue;
            let sampleDuration = info.sampleDuration;
            const tfhd = child(u, traf, "tfhd");
            if (tfhd) {
              const flags = view.getUint32(tfhd.body) & 0xffffff;
              let at = tfhd.body + 8;
              if (flags & 1) at += 8;
              if (flags & 2) at += 4;
              if (flags & 8) sampleDuration = view.getUint32(at);
            }
            const tfdt = child(u, traf, "tfdt");
            if (tfdt && start === null)
              start = u[tfdt.body] === 1 ? view.getUint32(tfdt.body + 4) * 4294967296 + view.getUint32(tfdt.body + 8) : view.getUint32(tfdt.body + 4);
            for (const trun of boxes(u, traf.body, traf.end)) {
              if (trun.type !== "trun") continue;
              const flags = view.getUint32(trun.body) & 0xffffff;
              const count = view.getUint32(trun.body + 4);
              if (!(flags & 0x100)) {
                duration += count * sampleDuration;
                continue;
              }
              let at = trun.body + 8 + (flags & 1 ? 4 : 0) + (flags & 4 ? 4 : 0);
              const stride = 4 + (flags & 0x200 ? 4 : 0) + (flags & 0x400 ? 4 : 0) + (flags & 0x800 ? 4 : 0);
              for (let k = 0; k < count && at + 4 <= trun.end; k++, at += stride) duration += view.getUint32(at);
            }
          }
          return start === null ? null : [start / info.timescale, (start + duration) / info.timescale];
        };
        const split = (u) => {
          const units = [];
          let lead = 0;
          let fragment = false;
          for (const box of boxes(u, 0, u.length)) {
            if (box.type === "moov") {
              units.push({ kind: "init", bytes: u.subarray(lead, box.end) });
              lead = box.end;
              fragment = false;
            } else if (box.type === "moof") {
              fragment = true;
            } else if (box.type === "mdat") {
              if (fragment) units.push({ kind: "segment", bytes: u.subarray(lead, box.end) });
              lead = box.end;
              fragment = false;
            }
          }
          return { units, rest: lead };
        };
        const merged = (segments) => {
          const out = [];
          for (const s of [...segments].sort((a, b) => a.start - b.start)) {
            const last = out[out.length - 1];
            if (last && s.start <= last[1] + 0.25) last[1] = Math.max(last[1], s.end);
            else out.push([s.start, s.end]);
          }
          return out;
        };
        const intersect = (a, b) => {
          const out = [];
          for (let i = 0, j = 0; i < a.length && j < b.length; ) {
            const start = Math.max(a[i][0], b[j][0]);
            const end = Math.min(a[i][1], b[j][1]);
            if (start < end) out.push([start, end]);
            if (a[i][1] < b[j][1]) i++;
            else j++;
          }
          return out;
        };
        return { boxes, describeInit, fragmentTimes, split, merged, intersect };
      })();

      const bytesOf = (b) =>
        b instanceof ArrayBuffer ? new Uint8Array(b) : ArrayBuffer.isView(b) ? new Uint8Array(b.buffer, b.byteOffset, b.byteLength) : new Uint8Array(0);
      const toBase64 = (bytes) => {
        let text = "";
        for (let i = 0; i < bytes.length; i += 0x8000) text += apply(fromCharCode, null, bytes.subarray(i, i + 0x8000));
        return btoa(text);
      };
      const fromBase64 = (text) => {
        const binary = atob(text);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
      };
      const fire = (target, type) => target.dispatchEvent(new Event(type));
      const fireOwn = (target, type, event = new Event(type)) => {
        target.dispatchEvent(event);
        const handler = target["on" + type];
        if (typeof handler === "function") apply(handler, target, [event]);
      };
      const own = (target, values) => {
        for (const name of keys(values)) defineProperty(target, name, { value: values[name], writable: true, configurable: true, enumerable: true });
        return target;
      };
      const timeRanges = (list) => {
        const out = create(TimeRanges.prototype);
        const at = (i) => {
          if (!(i >= 0 && i < list.length)) throw new DOMException("The index provided is out of range.", "IndexSizeError");
          return list[i];
        };
        defineProperty(out, "length", { value: list.length });
        defineProperty(out, "start", { value: (i) => at(i)[0] });
        defineProperty(out, "end", { value: (i) => at(i)[1] });
        return out;
      };
      const unsupported = () => new DOMException("Unsupported keySystem or supportedConfigurations.", "NotSupportedError");

      const keySessions = new Map();
      const ownKeys = new WeakSet();
      const keysOf = new WeakMap();
      let keySessionSeq = 0;
      const makeKeySession = (keySystem) => {
        const id = ++keySessionSeq;
        const keySession = new EventTarget();
        setPrototypeOf(keySession, MediaKeySession.prototype);
        let closeSession;
        const entry = { keySession, waiting: [] };
        own(keySession, {
          sessionId: "",
          expiration: NaN,
          keyStatuses: new Map(),
          closed: new Promise((resolve) => (closeSession = resolve)),
          onmessage: null,
          onkeystatuseschange: null,
          generateRequest: (initDataType, initData) => {
            const data = bytesOf(initData);
            if (!data.length || data.length > MAX_KEY_BYTES) return Promise.reject(new TypeError("Invalid initData"));
            keySession.sessionId = "ardia-" + id;
            send("protectedVideo", { op: "request", session: id, keySystem, type: String(initDataType).slice(0, 16), data: toBase64(data) });
            return Promise.resolve();
          },
          update: (response) =>
            new Promise((resolve, reject) => {
              const data = bytesOf(response);
              if (!data.length || data.length > MAX_KEY_BYTES) return reject(new TypeError("Invalid response"));
              const waiter = { resolve, reject };
              entry.waiting.push(waiter);
              soon(() => {
                const at = entry.waiting.indexOf(waiter);
                if (at < 0) return;
                entry.waiting.splice(at, 1);
                resolve();
              }, KEY_WAIT_MS);
              send("protectedVideo", { op: "update", session: id, data: toBase64(data) });
            }),
          load: () => Promise.resolve(false),
          remove: () => Promise.resolve(),
          close: () => {
            if (keySessions.delete(id)) send("protectedVideo", { op: "closeSession", session: id });
            closeSession();
            return Promise.resolve();
          },
        });
        keySessions.set(id, entry);
        return keySession;
      };
      const makeKeys = (keySystem) => {
        const mediaKeys = own(create(MediaKeys.prototype), {
          setServerCertificate: (certificate) => {
            const data = bytesOf(certificate);
            if (!data.length || data.length > MAX_KEY_BYTES) return Promise.reject(new TypeError("Invalid certificate"));
            send("protectedVideo", { op: "certificate", data: toBase64(data) });
            return Promise.resolve(true);
          },
          createSession: () => makeKeySession(keySystem),
          getStatusForPolicy: () => Promise.resolve("usable"),
        });
        ownKeys.add(mediaKeys);
        return mediaKeys;
      };
      const keyAccess = (keySystem, configuration) =>
        own(create(MediaKeySystemAccess.prototype), {
          keySystem,
          getConfiguration: () => configuration,
          createMediaKeys: () => Promise.resolve(makeKeys(keySystem)),
        });
      const pickConfiguration = (configurations) => {
        for (const config of isArray(configurations) ? configurations : []) {
          const asked = isArray(config && config.videoCapabilities) ? config.videoCapabilities : [];
          const video = asked.filter((c) => !UNDECODABLE.test(String((c && c.contentType) || "")));
          if (asked.length && !video.length) continue;
          return {
            label: (config && config.label) || "",
            initDataTypes: isArray(config && config.initDataTypes) ? config.initDataTypes : ["cenc"],
            audioCapabilities: isArray(config && config.audioCapabilities) ? config.audioCapabilities : [],
            videoCapabilities: video,
            distinctiveIdentifier: "not-allowed",
            persistentState: "not-allowed",
            sessionTypes: ["temporary"],
          };
        }
        return null;
      };
      const requestAccess = Navigator.prototype.requestMediaKeySystemAccess;
      if (typeof requestAccess === "function")
        Navigator.prototype.requestMediaKeySystemAccess = asNative(requestAccess, (target, self, args) => {
          const keySystem = String(args[0]);
          if (FAIRPLAY.test(keySystem)) {
            const configuration = pickConfiguration(args[1]);
            return configuration ? Promise.resolve(keyAccess(keySystem, configuration)) : Promise.reject(unsupported());
          }
          if (OTHER_KEY_SYSTEMS.test(keySystem)) return Promise.reject(unsupported());
          return apply(target, self, args);
        });
      if (!window.WebKitMediaKeys) {
        const WebKitMediaKeys = function WebKitMediaKeys() {
          throw new TypeError("Illegal constructor");
        };
        WebKitMediaKeys.isTypeSupported = (keySystem, type) => FAIRPLAY.test(String(keySystem)) && !UNDECODABLE.test(String(type || ""));
        defineProperty(window, "WebKitMediaKeys", { value: WebKitMediaKeys, writable: true, configurable: true });
      }
      const capabilities = window.MediaCapabilities && MediaCapabilities.prototype;
      if (capabilities && typeof capabilities.decodingInfo === "function")
        capabilities.decodingInfo = asNative(capabilities.decodingInfo, (target, self, args) => {
          const config = args[0] || {};
          const refused = { supported: false, smooth: false, powerEfficient: false, keySystemAccess: null };
          if (config.video && UNDECODABLE.test(String(config.video.contentType || ""))) return Promise.resolve(refused);
          const keySystem = config.keySystemConfiguration && String(config.keySystemConfiguration.keySystem || "");
          if (keySystem && FAIRPLAY.test(keySystem)) {
            const configuration = {
              initDataTypes: [config.keySystemConfiguration.initDataType || "cenc"],
              videoCapabilities: config.video ? [{ contentType: config.video.contentType, robustness: "" }] : [],
              audioCapabilities: config.audio ? [{ contentType: config.audio.contentType, robustness: "" }] : [],
              distinctiveIdentifier: "not-allowed",
              persistentState: "not-allowed",
              sessionTypes: ["temporary"],
            };
            return Promise.resolve({ supported: true, smooth: true, powerEfficient: true, keySystemAccess: keyAccess(keySystem, configuration) });
          }
          if (keySystem) return Promise.resolve(refused);
          return apply(target, self, args);
        });
      const SourceType = window.MediaSource;
      SourceType.isTypeSupported = asNative(SourceType.isTypeSupported, (target, self, args) => !UNDECODABLE.test(String(args[0])) && apply(target, self, args));

      const Media = HTMLMediaElement.prototype;
      const Video = HTMLVideoElement.prototype;
      const bridgeOf = new WeakMap();
      const bridgeOfSource = new WeakMap();
      const sourceOfUrl = new Map();
      let bridged = null;
      let held = null;
      let mediaSeq = 0;
      const sendMedia = (b, data) => (b.held ? b.backlog.push(data) : send("protectedVideo", data));
      const bufferedOf = (b) => {
        const live = b.states.filter((st) => !st.removed);
        return live.length ? live.map((st) => mp4.merged(st.segments)).reduce(mp4.intersect) : [];
      };
      const holds = (b, time) => bufferedOf(b).some(([start, end]) => time >= start - 0.1 && time < end);
      const durationOf = (b) => {
        const duration = b.source.duration;
        return Number.isNaN(duration) && b.initDuration > 0 ? b.initDuration : duration;
      };
      const positionOf = (b) => {
        if (b.seeking) return b.seekTo;
        if (b.paused || !b.playing) return b.time;
        const duration = durationOf(b);
        return Math.min(b.time + ((now() - b.stamp) / 1000) * b.rate, b.time + AHEAD_LIMIT_S, isFinite(duration) ? duration : Infinity);
      };
      const sendDuration = (b) => {
        const duration = durationOf(b);
        const known = isFinite(duration) && duration > 0 ? duration : 0;
        if (known === b.sentDuration) return;
        b.sentDuration = known;
        sendMedia(b, { op: "duration", media: b.id, duration: known });
      };
      const startMirror = (b) => {
        if (typeof videoMirror === "undefined") return;
        const again = b.mirrored;
        b.mirrored = true;
        guard(() => (again ? videoMirror.ensure(b.el) : videoMirror.start(b.el)))();
      };
      const stopMirror = (b) => {
        if (!b.mirrored) return;
        b.mirrored = false;
        if (typeof videoMirror !== "undefined") guard(() => videoMirror.stop())();
      };
      const finishSeek = (b) => {
        b.seeking = false;
        b.time = b.seekTo;
        b.stamp = now();
        b.playing = false;
        fire(b.el, "seeked");
        fire(b.el, "timeupdate");
      };
      const progress = (b) => {
        if (bridgeOf.get(b.el) !== b) return;
        sendDuration(b);
        if (!b.metadata && b.states.length && b.states.every((st) => st.info)) {
          b.metadata = true;
          fire(b.el, "durationchange");
          fire(b.el, "loadedmetadata");
          fire(b.el, "resize");
        }
        if (b.seeking && holds(b, b.seekTo)) finishSeek(b);
        if (b.metadata && !b.loaded && holds(b, positionOf(b))) {
          b.loaded = true;
          for (const type of ["loadeddata", "canplay", "canplaythrough"]) fire(b.el, type);
        }
      };
      const stopTicking = (b) => {
        clearInterval(b.ticker);
        b.ticker = 0;
      };
      const tick = (b) => {
        if (bridgeOf.get(b.el) !== b || b.paused) return stopTicking(b);
        const position = positionOf(b);
        if (b.playing) {
          b.frames += Math.max(0, position - b.lastPosition) * FRAME_RATE;
          fire(b.el, "timeupdate");
        }
        b.lastPosition = position;
      };
      const startTicking = (b) => {
        if (!b.ticker) b.ticker = setInterval(guard(() => tick(b)), TICK_MS);
      };
      const reportRect = (b) => {
        const r = b.el.getBoundingClientRect();
        const visible = document.visibilityState === "visible" && b.el.isConnected && r.width > 0 && r.height > 0;
        const geometry = [r.left, r.top, r.width, r.height].join();
        if (geometry !== b.coverKey || ++b.coverAge >= 10) {
          b.cover = visible ? pinnedCover(b.el, r) : { top: 0, bottom: 0, radius: 0, backdrop: null };
          b.coverKey = geometry;
          b.coverAge = 0;
        }
        const rect = { op: "rect", media: b.id, x: r.left, y: r.top, width: r.width, height: r.height, scale: devicePixelRatio, visible, coverTop: b.cover.top, coverBottom: b.cover.bottom, radius: b.cover.radius, backdrop: b.cover.backdrop };
        const key = [rect.x, rect.y, rect.width, rect.height, rect.scale, visible, rect.coverTop, rect.coverBottom, rect.radius, rect.backdrop].join();
        if (key === b.rectKey) return;
        b.rectKey = key;
        sendMedia(b, rect);
      };
      const watchRect = (b) => {
        const step = guard(() => {
          if (bridgeOf.get(b.el) !== b) return;
          reportRect(b);
          apply(raf, window, [step]);
        });
        apply(raf, window, [step]);
      };
      const release = (el) => {
        const b = bridgeOf.get(el);
        if (!b) return;
        bridgeOf.delete(el);
        bridgeOfSource.delete(b.source);
        stopTicking(b);
        stopMirror(b);
        sendMedia(b, { op: "detach", media: b.id });
        if (held === b) held = null;
        if (bridged === b) {
          bridged = null;
          if (held) takeOver(held);
        }
      };
      const takeOver = (b) => {
        if (held === b) held = null;
        if (bridged && bridged !== b) release(bridged.el);
        b.held = false;
        bridged = b;
        for (const data of b.backlog.splice(0)) send("protectedVideo", data);
        if (typeof videoMirror !== "undefined") videoMirror.prepare();
      };
      const bridge = (el, source) => {
        const hold = !!(bridged && bridged.played && !bridged.ended && bridged.el !== el);
        if (held) release(held.el);
        if (bridged && !hold) release(bridged.el);
        const b = {
          id: ++mediaSeq,
          el,
          source,
          states: [],
          buffers: [],
          bufferSeq: 0,
          paused: true,
          ended: false,
          seeking: false,
          seekTo: 0,
          seekSeq: 0,
          time: 0,
          stamp: now(),
          playing: false,
          rate: el.playbackRate || 1,
          metadata: false,
          loaded: false,
          sourceEnded: false,
          frames: 0,
          dropped: 0,
          lastPosition: 0,
          error: null,
          size: [0, 0],
          rectKey: "",
          ticker: 0,
          mirrored: false,
          pip: false,
          pipWindow: null,
          pipEnter: [],
          pipExit: [],
          sentDuration: -1,
          initDuration: 0,
          played: false,
          held: hold,
          backlog: [],
        };
        bridgeOf.set(el, b);
        bridgeOfSource.set(source, b);
        if (hold) held = b;
        else bridged = b;
        sendMedia(b, { op: "attach", media: b.id });
        if (!hold && typeof videoMirror !== "undefined") videoMirror.prepare();
        sendMedia(b, { op: "volume", media: b.id, volume: el.volume, muted: el.muted });
        if (b.rate !== 1) sendMedia(b, { op: "rate", media: b.id, rate: b.rate });
        sendDuration(b);
        watchRect(b);
      };
      const ship = (b, st, kind, bytes, start, end) => {
        const seq = ++st.seq;
        const parts = Math.max(1, Math.ceil(bytes.length / PART_BYTES));
        for (let part = 0; part < parts; part++)
          sendMedia(b, {
            op: "append",
            media: b.id,
            buffer: st.id,
            kind,
            seq,
            part,
            parts,
            start,
            end,
            data: toBase64(bytes.subarray(part * PART_BYTES, (part + 1) * PART_BYTES)),
          });
      };
      const dropRange = (b, st, start, end) => {
        const kept = st.segments.filter((s) => {
          const middle = (s.start + s.end) / 2;
          return middle < start || middle >= end;
        });
        if (kept.length === st.segments.length) return;
        st.segments = kept;
        st.bytes = kept.reduce((sum, s) => sum + s.bytes, 0);
        sendMedia(b, { op: "remove", media: b.id, buffer: st.id, start, end: isFinite(end) ? end : 1e8 });
      };
      const makeRoom = (b, st, incoming) => {
        const quota = st.video ? VIDEO_QUOTA : AUDIO_QUOTA;
        if (st.bytes + incoming <= quota) return true;
        const before = positionOf(b) - KEEP_BEHIND_S;
        const old = st.segments.filter((s) => s.end < before).sort((x, y) => x.start - y.start);
        if (old.length) dropRange(b, st, -1e6, old[old.length - 1].end);
        return st.bytes + incoming <= quota;
      };
      const take = (b, st, unit) => {
        if (unit.kind === "init") {
          st.info = mp4.describeInit(unit.bytes);
          if (st.info.duration > 0 && !(b.initDuration > 0)) {
            b.initDuration = st.info.duration;
            if (Number.isNaN(b.source.duration)) {
              if (b.metadata) fire(b.el, "durationchange");
              sendDuration(b);
            }
          }
          if (st.video && st.info.width && st.info.height) {
            const changed = b.size[0] !== st.info.width || b.size[1] !== st.info.height;
            b.size = [st.info.width, st.info.height];
            if (changed && b.metadata) fire(b.el, "resize");
          }
          return ship(b, st, "init", unit.bytes, 0, 0);
        }
        if (!st.info) return;
        const times = mp4.fragmentTimes(unit.bytes, st.info);
        if (!times) return;
        const start = times[0] + st.offset;
        const end = Math.max(times[1] + st.offset, start + 0.001);
        if (end <= st.windowStart || start >= st.windowEnd) return;
        st.segments = st.segments.filter((s) => !(start < s.end - 0.05 && end > s.start + 0.05));
        st.segments.push({ start, end, bytes: unit.bytes.length });
        st.bytes = st.segments.reduce((sum, s) => sum + s.bytes, 0);
        ship(b, st, "segment", unit.bytes, start, end);
      };
      const sourceBufferList = (items) => {
        const out = new EventTarget();
        setPrototypeOf(out, SourceBufferList.prototype);
        defineProperty(out, "length", { value: items.length });
        items.forEach((item, i) => defineProperty(out, i, { value: item, enumerable: true }));
        defineProperty(out, Symbol.iterator, { value: () => items[Symbol.iterator]() });
        return out;
      };
      const makeBuffer = (b, mime) => {
        const sb = new EventTarget();
        setPrototypeOf(sb, SourceBuffer.prototype);
        const st = {
          id: ++b.bufferSeq,
          video: /^video\//i.test(mime),
          info: null,
          pending: new Uint8Array(0),
          segments: [],
          bytes: 0,
          updating: false,
          offset: 0,
          windowStart: 0,
          windowEnd: Infinity,
          mode: "segments",
          seq: 0,
          op: 0,
          removed: false,
        };
        const property = (name, descriptor) => defineProperty(sb, name, { configurable: true, enumerable: true, ...descriptor });
        const busy = () => new DOMException("This SourceBuffer is still processing an 'appendBuffer' or 'remove' operation.", "InvalidStateError");
        const gone = () => new DOMException("This SourceBuffer has been removed from the parent media source.", "InvalidStateError");
        const finish = () => {
          st.updating = false;
          fireOwn(sb, "update");
          fireOwn(sb, "updateend");
          progress(b);
        };
        property("updating", { get: () => st.updating });
        property("buffered", { get: () => timeRanges(mp4.merged(st.segments)) });
        property("timestampOffset", { get: () => st.offset, set: (v) => (st.offset = Number(v) || 0) });
        property("appendWindowStart", { get: () => st.windowStart, set: (v) => (st.windowStart = Number(v) || 0) });
        property("appendWindowEnd", { get: () => st.windowEnd, set: (v) => (st.windowEnd = Number(v)) });
        property("mode", { get: () => st.mode, set: (v) => (st.mode = String(v)) });
        for (const handler of ["onupdatestart", "onupdate", "onupdateend", "onerror", "onabort"]) property(handler, { value: null, writable: true });
        property("appendBuffer", {
          value: (data) => {
            if (st.removed) throw gone();
            if (st.updating) throw busy();
            const incoming = bytesOf(data);
            if (!makeRoom(b, st, incoming.length))
              throw new DOMException("The SourceBuffer is full, and cannot free space to append additional buffers.", "QuotaExceededError");
            const combined = new Uint8Array(st.pending.length + incoming.length);
            combined.set(st.pending);
            combined.set(incoming, st.pending.length);
            st.updating = true;
            const op = ++st.op;
            if (b.sourceEnded) {
              b.sourceEnded = false;
              sendMedia(b, { op: "end", media: b.id, ended: false });
              fire(b.source, "sourceopen");
            }
            soon(() => {
              if (st.op !== op || !st.updating) return;
              fireOwn(sb, "updatestart");
              const { units, rest } = mp4.split(combined);
              st.pending = combined.length - rest > MAX_PENDING_BYTES ? new Uint8Array(0) : combined.slice(rest);
              if (bridgeOf.get(b.el) === b) for (const unit of units) take(b, st, unit);
              finish();
            }, 0);
          },
        });
        property("remove", {
          value: (start, end) => {
            if (st.removed) throw gone();
            if (st.updating) throw busy();
            st.updating = true;
            const op = ++st.op;
            soon(() => {
              if (st.op !== op || !st.updating) return;
              fireOwn(sb, "updatestart");
              dropRange(b, st, Number(start), Number(end));
              finish();
            }, 0);
          },
        });
        property("abort", {
          value: () => {
            st.pending = new Uint8Array(0);
            st.op++;
            if (!st.updating) return;
            st.updating = false;
            fireOwn(sb, "abort");
            fireOwn(sb, "updateend");
          },
        });
        property("changeType", {
          value: (type) => {
            if (UNDECODABLE.test(String(type))) throw new DOMException("The type provided ('" + type + "') is unsupported.", "NotSupportedError");
            st.video = /^video\//i.test(String(type));
            sendMedia(b, { op: "buffer", media: b.id, buffer: st.id, mime: String(type).slice(0, 200) });
          },
        });
        b.states.push(st);
        b.buffers.push(sb);
        sendMedia(b, { op: "buffer", media: b.id, buffer: st.id, mime: mime.slice(0, 200) });
        return { sb, st };
      };

      const SourceProto = SourceType.prototype;
      SourceProto.addSourceBuffer = asNative(SourceProto.addSourceBuffer, (target, self, args) => {
        const type = String(args[0]);
        if (UNDECODABLE.test(type)) throw new DOMException("The type provided ('" + type + "') is unsupported.", "NotSupportedError");
        const b = bridgeOfSource.get(self);
        if (!b || b.states.length >= 8) return apply(target, self, args);
        if (b.bufferSeq >= MAX_BUFFER_ID) throw new DOMException("This MediaSource has reached the limit of SourceBuffer objects it can handle.", "QuotaExceededError");
        return makeBuffer(b, type).sb;
      });
      SourceProto.removeSourceBuffer = asNative(SourceProto.removeSourceBuffer, (target, self, args) => {
        const b = bridgeOfSource.get(self);
        const at = b ? b.buffers.indexOf(args[0]) : -1;
        if (at < 0) return apply(target, self, args);
        const st = b.states[at];
        st.removed = true;
        st.op++;
        st.updating = false;
        b.buffers.splice(at, 1);
        b.states.splice(at, 1);
        sendMedia(b, { op: "dropBuffer", media: b.id, buffer: st.id });
      });
      const sourceGetter = (name, read) => {
        const was = getOwnPropertyDescriptor(SourceProto, name);
        if (was && was.get)
          defineProperty(SourceProto, name, {
            ...was,
            get: asNative(was.get, (target, self, args) => {
              const b = bridgeOfSource.get(self);
              return b ? read(b, () => apply(target, self, args)) : apply(target, self, args);
            }),
          });
      };
      sourceGetter("sourceBuffers", (b) => sourceBufferList(b.buffers));
      sourceGetter("activeSourceBuffers", (b) => sourceBufferList(b.buffers));
      sourceGetter("readyState", (b, real) => (b.sourceEnded ? "ended" : real()));
      SourceProto.endOfStream = asNative(SourceProto.endOfStream, (target, self, args) => {
        const b = bridgeOfSource.get(self);
        if (!b) return apply(target, self, args);
        if (args[0]) return;
        b.sourceEnded = true;
        sendMedia(b, { op: "end", media: b.id, ended: true });
        sendDuration(b);
        fire(self, "sourceended");
      });
      const sourceDuration = getOwnPropertyDescriptor(SourceProto, "duration");
      if (sourceDuration && sourceDuration.set)
        defineProperty(SourceProto, "duration", {
          ...sourceDuration,
          set: asNative(sourceDuration.set, (target, self, args) => {
            const result = apply(target, self, args);
            const b = bridgeOfSource.get(self);
            if (b && bridgeOf.get(b.el) === b) sendDuration(b);
            return result;
          }),
        });
      const createObjectURL = URL.createObjectURL;
      URL.createObjectURL = asNative(createObjectURL, (target, self, args) => {
        const url = apply(target, self, args);
        if (args[0] instanceof SourceType) {
          sourceOfUrl.set(url, args[0]);
          if (sourceOfUrl.size > 32) sourceOfUrl.delete(sourceOfUrl.keys().next().value);
        }
        return url;
      });

      const getter = (proto, name, read) => {
        const was = getOwnPropertyDescriptor(proto, name);
        if (!was || !was.get) return;
        defineProperty(proto, name, {
          ...was,
          get: asNative(was.get, (target, self, args) => {
            const b = bridgeOf.get(self);
            return b ? read(b, self) : apply(target, self, args);
          }),
        });
      };
      const setter = (proto, name, write) => {
        const was = getOwnPropertyDescriptor(proto, name);
        if (!was || !was.set) return;
        defineProperty(proto, name, {
          ...was,
          set: asNative(was.set, (target, self, args) => {
            const b = bridgeOf.get(self);
            return b ? write(b, self, args[0], () => apply(target, self, args)) : apply(target, self, args);
          }),
        });
      };
      const method = (proto, name, call) => {
        const was = proto[name];
        if (typeof was !== "function") return;
        proto[name] = asNative(was, (target, self, args) => {
          const b = bridgeOf.get(self);
          return b ? call(b, self, args, () => apply(target, self, args)) : apply(target, self, args);
        });
      };
      const srcDescriptor = getOwnPropertyDescriptor(Media, "src");
      defineProperty(Media, "src", {
        ...srcDescriptor,
        set: asNative(srcDescriptor.set, (target, self, args) => {
          release(self);
          const result = apply(target, self, args);
          const source = sourceOfUrl.get(String(args[0]));
          if (source && self instanceof HTMLVideoElement && PLAYER_ROUTE.test(location.pathname)) bridge(self, source);
          return result;
        }),
      });
      method(Media, "load", (b, el, args, real) => {
        release(el);
        return real();
      });
      getter(Media, "currentTime", (b) => positionOf(b));
      setter(Media, "currentTime", (b, el, value) => {
        const time = Number(value);
        if (!isFinite(time)) throw new TypeError("Failed to set the 'currentTime' property on 'HTMLMediaElement': The provided double value is non-finite.");
        const duration = durationOf(b);
        const target = Math.max(0, isFinite(duration) ? Math.min(time, duration) : time);
        b.seekSeq++;
        b.ended = false;
        sendMedia(b, { op: "seek", media: b.id, time: target, seq: b.seekSeq });
        if (!b.metadata) {
          b.time = target;
          b.stamp = now();
          return;
        }
        b.seekTo = target;
        b.seeking = true;
        soon(() => {
          if (!b.seeking || b.seekTo !== target) return;
          fire(el, "seeking");
          progress(b);
        }, 0);
      });
      getter(Media, "paused", (b) => b.paused);
      getter(Media, "ended", (b) => b.ended);
      getter(Media, "seeking", (b) => b.seeking);
      getter(Media, "readyState", (b) => (b.metadata ? (holds(b, positionOf(b)) ? 4 : 1) : 0));
      getter(Media, "buffered", (b) => timeRanges(bufferedOf(b)));
      getter(Media, "seekable", (b) => (isFinite(durationOf(b)) ? timeRanges([[0, durationOf(b)]]) : timeRanges(bufferedOf(b))));
      getter(Media, "duration", (b) => durationOf(b));
      getter(Media, "error", (b) => b.error);
      getter(Video, "videoWidth", (b) => b.size[0]);
      getter(Video, "videoHeight", (b) => b.size[1]);
      getter(Video, "webkitDecodedFrameCount", (b) => Math.floor(b.frames));
      const droppedOf = (b) => Math.min(Math.floor(b.dropped), Math.floor(b.frames));
      getter(Video, "webkitDroppedFrameCount", droppedOf);
      getter(Media, "webkitVideoDecodedByteCount", (b) => Math.floor(b.frames) * 30000);
      getter(Media, "webkitAudioDecodedByteCount", (b) => Math.floor(b.frames) * 800);
      method(Video, "getVideoPlaybackQuality", (b) =>
        own(create(VideoPlaybackQuality.prototype), { creationTime: now(), totalVideoFrames: Math.floor(b.frames), droppedVideoFrames: droppedOf(b), corruptedVideoFrames: 0 })
      );
      const frameCallbacks = new Map();
      let frameCallbackSeq = 0;
      method(Video, "requestVideoFrameCallback", (b, el, args) => {
        const handle = ++frameCallbackSeq;
        const callback = args[0];
        const wait = () =>
          frameCallbacks.set(
            handle,
            apply(raf, window, [
              guard((at) => {
                if (!frameCallbacks.has(handle)) return;
                if (b.paused || !b.playing) return wait();
                frameCallbacks.delete(handle);
                callback(at, {
                  presentationTime: at,
                  expectedDisplayTime: at + 16,
                  width: b.size[0],
                  height: b.size[1],
                  mediaTime: positionOf(b),
                  presentedFrames: Math.floor(b.frames),
                  processingDuration: 0.005,
                });
              }),
            ])
          );
        wait();
        return handle;
      });
      method(Video, "cancelVideoFrameCallback", (b, el, args, real) => {
        if (!frameCallbacks.has(args[0])) return real();
        cancelAnimationFrame(frameCallbacks.get(args[0]));
        frameCallbacks.delete(args[0]);
      });
      const fireSoon = (b, el, types) =>
        soon(() => {
          if (bridgeOf.get(el) === b) for (const type of types) fire(el, type);
        }, 0);
      method(Media, "play", (b, el) => {
        if (b.error) return Promise.reject(new DOMException("The element has no supported sources.", "NotSupportedError"));
        b.played = true;
        if (b.held) takeOver(b);
        if (b.paused) {
          b.paused = false;
          b.stamp = now();
          b.lastPosition = positionOf(b);
          fireSoon(b, el, ["play"]);
          sendMedia(b, { op: "play", media: b.id });
        }
        startTicking(b);
        return Promise.resolve();
      });
      method(Media, "pause", (b, el) => {
        if (b.paused) return;
        b.time = positionOf(b);
        b.paused = true;
        b.playing = false;
        sendMedia(b, { op: "pause", media: b.id });
        fireSoon(b, el, ["timeupdate", "pause"]);
      });
      setter(Media, "volume", (b, el, value, real) => {
        real();
        sendMedia(b, { op: "volume", media: b.id, volume: el.volume, muted: el.muted });
      });
      setter(Media, "muted", (b, el, value, real) => {
        real();
        sendMedia(b, { op: "volume", media: b.id, volume: el.volume, muted: el.muted });
      });
      setter(Media, "playbackRate", (b, el, value, real) => {
        real();
        b.time = positionOf(b);
        b.stamp = now();
        b.rate = el.playbackRate || 1;
        sendMedia(b, { op: "rate", media: b.id, rate: b.rate });
      });
      const pictureInPictureWindow = (b) => {
        const out = new EventTarget();
        if (window.PictureInPictureWindow) setPrototypeOf(out, PictureInPictureWindow.prototype);
        return own(out, { width: b.size[0], height: b.size[1], onresize: null });
      };
      const pictureInPictureEvent = (type, pipWindow) => {
        try {
          return new PictureInPictureEvent(type, { bubbles: true, pictureInPictureWindow: pipWindow });
        } catch (e) {
          return own(new Event(type, { bubbles: true }), { pictureInPictureWindow: pipWindow });
        }
      };
      method(Video, "requestPictureInPicture", (b) => {
        if (b.pip) return Promise.resolve(b.pipWindow);
        return new Promise((resolve, reject) => {
          b.pipEnter.push({ resolve, reject });
          sendMedia(b, { op: "pip", media: b.id, enter: true });
        });
      });
      const documentPip = getOwnPropertyDescriptor(Document.prototype, "pictureInPictureElement");
      if (documentPip && documentPip.get)
        defineProperty(Document.prototype, "pictureInPictureElement", {
          ...documentPip,
          get: asNative(documentPip.get, (target, self, args) => {
            if (!bridged || !bridged.pip || self !== document) return apply(target, self, args);
            let el = bridged.el;
            while (el.getRootNode() !== document && el.getRootNode().host) el = el.getRootNode().host;
            return el;
          }),
        });
      const exitPip = Document.prototype.exitPictureInPicture;
      if (typeof exitPip === "function")
        Document.prototype.exitPictureInPicture = asNative(exitPip, (target, self, args) => {
          const b = bridged;
          if (!b || !b.pip || self !== document) return apply(target, self, args);
          return new Promise((resolve) => {
            b.pipExit.push(resolve);
            sendMedia(b, { op: "pip", media: b.id, enter: false });
          });
        });
      const pipChanged = (b, active) => {
        if (active && !b.pip) {
          b.pip = true;
          b.pipWindow = pictureInPictureWindow(b);
          for (const waiter of b.pipEnter.splice(0)) waiter.resolve(b.pipWindow);
          b.el.dispatchEvent(pictureInPictureEvent("enterpictureinpicture", b.pipWindow));
        } else if (!active) {
          for (const waiter of b.pipEnter.splice(0)) waiter.reject(new DOMException("Picture-in-Picture could not start.", "NotAllowedError"));
          for (const resolve of b.pipExit.splice(0)) resolve();
          if (b.pip) {
            b.pip = false;
            b.el.dispatchEvent(pictureInPictureEvent("leavepictureinpicture", b.pipWindow));
          }
        }
      };
      const mediaKeysDescriptor = getOwnPropertyDescriptor(Media, "mediaKeys");
      if (mediaKeysDescriptor && mediaKeysDescriptor.get)
        defineProperty(Media, "mediaKeys", {
          ...mediaKeysDescriptor,
          get: asNative(mediaKeysDescriptor.get, (target, self, args) => (keysOf.has(self) ? keysOf.get(self) : apply(target, self, args))),
        });
      if (typeof Media.setMediaKeys === "function")
        Media.setMediaKeys = asNative(Media.setMediaKeys, (target, self, args) => {
          const mediaKeys = args[0];
          if (mediaKeys && ownKeys.has(mediaKeys)) {
            keysOf.set(self, mediaKeys);
            return Promise.resolve();
          }
          keysOf.delete(self);
          return apply(target, self, args);
        });

      const onKeys = (m) => {
        const entry = keySessions.get(m.session);
        if (!entry) return;
        if (m.event === "message") {
          const message = fromBase64(String(m.data || "")).buffer;
          let event;
          try {
            event = new MediaKeyMessageEvent("message", { messageType: "license-request", message });
          } catch (e) {
            event = own(new Event("message"), { messageType: "license-request", message });
          }
          return fireOwn(entry.keySession, "message", event);
        }
        const waiting = entry.waiting.splice(0);
        if (m.ok !== true) {
          for (const waiter of waiting) waiter.reject(new DOMException("The key system rejected the licence.", "InvalidStateError"));
          return;
        }
        const statuses = new Map(entry.keySession.keyStatuses);
        for (const id of isArray(m.keyIDs) ? m.keyIDs : []) statuses.set(fromBase64(String(id)).buffer, "usable");
        entry.keySession.keyStatuses = statuses;
        for (const waiter of waiting) waiter.resolve();
        fireOwn(entry.keySession, "keystatuseschange");
      };
      handlers.protectedVideo = (m) => {
        if (m.event === "message" || m.event === "keys") return onKeys(m);
        const b = bridged;
        if (!b || m.media !== b.id) return;
        if (m.event === "time") {
          if (m.seq !== b.seekSeq || b.seeking || !isFinite(m.time)) return;
          b.time = m.time;
          b.stamp = now();
          if (isFinite(m.dropped) && m.dropped >= b.dropped) b.dropped = m.dropped;
          const playing = m.playing === true && !b.paused;
          if (playing && !b.playing) {
            b.playing = true;
            b.lastPosition = b.time;
            fire(b.el, "playing");
          } else if (!playing && b.playing) {
            b.playing = false;
            if (!b.paused) fire(b.el, "waiting");
          }
          if (b.playing) startMirror(b);
        } else if (m.event === "paused") {
          if (typeof m.paused === "boolean" && m.paused !== b.paused) askSiteToMatch(m.paused);
          if (m.paused === true && !b.paused) {
            b.time = positionOf(b);
            b.paused = true;
            b.playing = false;
            fire(b.el, "pause");
          } else if (m.paused === false && b.paused) {
            b.paused = false;
            b.stamp = now();
            fire(b.el, "play");
            startTicking(b);
          }
        } else if (m.event === "ended") {
          const duration = durationOf(b);
          b.time = isFinite(duration) ? duration : positionOf(b);
          b.playing = false;
          b.ended = true;
          fire(b.el, "timeupdate");
          if (!b.paused) {
            b.paused = true;
            fire(b.el, "pause");
          }
          fire(b.el, "ended");
        } else if (m.event === "pip") {
          pipChanged(b, m.active === true);
        } else if (m.event === "seekBy") {
          if (typeof m.delta === "number" && isFinite(m.delta) && b.metadata) b.el.currentTime = positionOf(b) + m.delta;
        } else if (m.event === "failed") {
          b.error = own(create(MediaError.prototype), { code: 3, message: "Protected playback failed" });
          b.paused = true;
          b.playing = false;
          stopTicking(b);
          fire(b.el, "error");
        }
      };
      // OpenArch: what plays, for the sidebar's player (media.js, in its
      // own world, cannot see what this script answers for the <video>),
      // and that player's buttons.
      let announced = false;
      const announce = () => {
        const b = bridged;
        if (!b || b.error) {
          if (announced) document.dispatchEvent(new CustomEvent("openarch-media-bridge", { detail: "" }));
          announced = false;
          return;
        }
        announced = true;
        const duration = durationOf(b);
        const state = {
          playing: !b.paused && !b.ended,
          time: positionOf(b),
          duration: isFinite(duration) ? duration : 0,
          audible: !b.el.muted && b.el.volume > 0,
          video: true,
          pip: b.pip === true,
        };
        document.dispatchEvent(new CustomEvent("openarch-media-bridge", { detail: toJSON(state) }));
      };
      const answer = handlers.protectedVideo;
      handlers.protectedVideo = (m) => {
        answer(m);
        // Chromium slows a hidden tab's timers down (to one a minute, in
        // time), and the page's clock with them: while the video plays in
        // Picture in Picture or is only heard, OpenArch's reports keep it.
        if (m.event === "time" && document.hidden && bridged && bridged.playing) fire(bridged.el, "timeupdate");
        announce();
      };
      setInterval(guard(announce), 1000);
      document.addEventListener("openarch-media-hello", guard(announce));
      document.addEventListener(
        "openarch-media-bridge-invoke",
        guard((event) => {
          const b = bridged;
          if (!b || typeof event.detail !== "string") return;
          const [command, value] = event.detail.split(" ");
          if (command === "toggle") {
            if (actions.has(b.paused ? "play" : "pause")) askSiteToMatch(!b.paused);
            else if (b.paused) b.el.play();
            else b.el.pause();
          } else if (command === "seek" && isFinite(Number(value))) {
            b.el.currentTime = Number(value);
          } else if (command === "pip") {
            b.el.requestPictureInPicture().catch(() => {});
          } else if (command === "exitpip") {
            document.exitPictureInPicture().catch(() => {});
          }
          announce();
        })
      );
      addEventListener(
        "visibilitychange",
        guard(() => {
          if (bridged) reportRect(bridged);
        })
      );
      addEventListener(
        "pagehide",
        guard((e) => {
          if (e.isTrusted && bridged) release(bridged.el);
        })
      );
    }
  } catch (e) {}
})();
