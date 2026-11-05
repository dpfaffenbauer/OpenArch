// Runs in the page's own world, where the page hands its media session the
// actions it supports (previous and next track, seeking), which media.js
// cannot see from its isolated world. Tells media.js which actions there
// are and calls them for the sidebar's player, as the media keys would.
(() => {
  const proto = globalThis.MediaSession?.prototype;
  if (!proto?.setActionHandler) return;
  const handlers = new Map();
  const announce = () =>
    document.dispatchEvent(new CustomEvent('openarch-media-actions', { detail: [...handlers.keys()].join(' ') }));

  // A proxy, so the page still sees the native function.
  proto.setActionHandler = new Proxy(proto.setActionHandler, {
    apply(target, session, args) {
      // First, so unknown actions throw exactly as before.
      const result = Reflect.apply(target, session, args);
      const [action, handler] = args;
      if (typeof handler === 'function') {
        handlers.set(String(action), handler);
      } else {
        handlers.delete(String(action));
      }
      announce();
      return result;
    },
  });

  document.addEventListener('openarch-media-hello', announce);
  document.addEventListener('openarch-media-invoke', (event) => {
    if (typeof event.detail !== 'string') return;
    const [action, value] = event.detail.split(' ');
    const handler = handlers.get(action);
    if (!handler) return;
    const details = { action };
    if (action === 'seekto') details.seekTime = Number(value);
    try {
      handler(details);
    } catch (error) {
      console.debug('__openarch_media__-error ' + error.message);
    }
  });
})();
