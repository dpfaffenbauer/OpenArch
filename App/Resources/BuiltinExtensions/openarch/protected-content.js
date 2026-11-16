// Chromium's Widevine stays off until Settings › Allgemein › „Geschützte
// Inhalte (Widevine)“ turns it on: Google's component updater installs the
// module anyway, so pages are told it is not there. With the setting on,
// OpenArch replaces this file in its copy of the extension at launch (see
// ProtectedContent.prepare). Streaming services play in WebKit instead.
(() => {
  const nav = globalThis.Navigator?.prototype;
  const request = nav?.requestMediaKeySystemAccess;
  if (typeof request !== 'function') return;
  nav.requestMediaKeySystemAccess = new Proxy(request, {
    apply(target, self, args) {
      if (/widevine/i.test(String(args[0]))) {
        return Promise.reject(new DOMException('Unsupported keySystem or supportedConfigurations.', 'NotSupportedError'));
      }
      return Reflect.apply(target, self, args);
    },
  });
})();
