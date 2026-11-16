// OpenArch (docs/chromium-engine.md in the OpenArch repository): a page
// OpenArch shows in its own windows carries this user data key. A WebView
// never attaches such a page's native view, so Chrome's (never shown) window
// doesn't take it from OpenArch's, whichever tab Chrome has active.
#ifndef UI_VIEWS_CONTROLS_WEBVIEW_OPENARCH_HOSTED_PAGE_H_
#define UI_VIEWS_CONTROLS_WEBVIEW_OPENARCH_HOSTED_PAGE_H_

namespace views {

inline const void* OpenArchHostedPageKey() {
  static const int key = 0;
  return &key;
}

}  // namespace views

#endif  // UI_VIEWS_CONTROLS_WEBVIEW_OPENARCH_HOSTED_PAGE_H_
