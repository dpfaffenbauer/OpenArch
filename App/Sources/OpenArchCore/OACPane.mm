#import "OACPane.h"
#import "OACInternal.h"

#import <objc/runtime.h>

#include <algorithm>
#include <vector>

#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

@interface OACPane (Callbacks)
- (void)oac_windowCreated:(CefRefPtr<CefWindow>)window;
- (void)oac_windowDestroyed;
- (void)oac_browserViewAddedToWindow:(CefRefPtr<CefWindow>)window;
- (void)oac_browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)oac_browserClosed;
- (void)oac_titleDidChange:(NSString*)title;
- (void)oac_addressDidChange:(NSString*)url;
- (void)oac_faviconURLsDidChange:(const std::vector<CefString>&)urls;
- (void)oac_faviconDidLoad:(NSImage*)image;
- (void)oac_loadingStateDidChange:(BOOL)isLoading
                        canGoBack:(BOOL)canGoBack
                     canGoForward:(BOOL)canGoForward;
- (void)oac_wantsNewTabWithURL:(NSString*)url background:(BOOL)background;
- (BOOL)oac_handleChromeCommand:(int)commandID;
- (void)oac_didActivate;
- (void)oac_consoleMessage:(NSString*)message
                    source:(NSString*)source
                      line:(NSInteger)line;
- (void)oac_mainFrameLoadStarted:(BOOL)started url:(NSString*)url;
- (BOOL)oac_shouldInterceptNavigationToURL:(NSString*)url;
- (void)oac_willToggleFullScreen;
@end

namespace {

void (^g_external_tab_handler)(NSString*) = nil;

NSMapTable<NSWindow*, OACPane*>* PanesByWindow() {
  static NSMapTable<NSWindow*, OACPane*>* table =
      [NSMapTable weakToWeakObjectsMapTable];
  return table;
}

// Pane windows are Chrome's windows with two changes, patched once per
// Chrome window class and for pane windows only (popups and DevTools keep
// Chrome's behavior; subclassing at runtime would break KVO on them):
// - They may become key (they take the keyboard) but never main, so
//   OpenArch's window stays main and keeps active window buttons.
// - When a page goes full screen, the window leaves OpenArch's window for
//   its own full screen space, like a Chrome window, and comes back after.
void PatchPaneWindowClass(NSWindow* window) {
  static NSMutableSet<Class>* patched = [NSMutableSet set];
  Class cls = [window class];
  if ([patched containsObject:cls]) {
    return;
  }
  [patched addObject:cls];

  SEL canBecomeMain = @selector(canBecomeMainWindow);
  Method mainMethod = class_getInstanceMethod(cls, canBecomeMain);
  BOOL (*originalMain)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(mainMethod);
  IMP mainReplacement = imp_implementationWithBlock(^BOOL(NSWindow* self) {
    if ([PanesByWindow() objectForKey:self]) {
      return NO;
    }
    return originalMain(self, canBecomeMain);
  });
  if (!class_addMethod(cls, canBecomeMain, mainReplacement, method_getTypeEncoding(mainMethod))) {
    method_setImplementation(mainMethod, mainReplacement);
  }

  SEL toggle = @selector(toggleFullScreen:);
  Method toggleMethod = class_getInstanceMethod(cls, toggle);
  void (*originalToggle)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(toggleMethod);
  IMP toggleReplacement = imp_implementationWithBlock(^(NSWindow* self, id sender) {
    [[PanesByWindow() objectForKey:self] oac_willToggleFullScreen];
    originalToggle(self, toggle, sender);
  });
  if (!class_addMethod(cls, toggle, toggleReplacement, method_getTypeEncoding(toggleMethod))) {
    method_setImplementation(toggleMethod, toggleReplacement);
  }
}

NSWindow* WindowFromHandle(CefWindowHandle handle) {
  id object = (__bridge id)handle;
  if ([object isKindOfClass:NSWindow.class]) {
    return object;
  }
  if ([object isKindOfClass:NSView.class]) {
    return [(NSView*)object window];
  }
  return nil;
}

class FaviconCallback : public CefDownloadImageCallback {
 public:
  explicit FaviconCallback(OACPane* pane) : pane_(pane) {}

  void OnDownloadImageFinished(const CefString& image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    if (!image || image->IsEmpty()) {
      return;
    }
    int width = 0;
    int height = 0;
    CefRefPtr<CefBinaryValue> png = image->GetAsPNG(2.0f, true, width, height);
    if (!png) {
      return;
    }
    NSMutableData* data = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(data.mutableBytes, data.length, 0);
    NSImage* favicon = [[NSImage alloc] initWithData:data];
    if (favicon) {
      // The PNG is rendered at 2x; report the size in points.
      favicon.size = NSMakeSize(width / 2.0, height / 2.0);
      [pane_ oac_faviconDidLoad:favicon];
    }
  }

 private:
  __weak OACPane* pane_;

  IMPLEMENT_REFCOUNTING(FaviconCallback);
};

// Routes CEF callbacks (always on the main thread on macOS) to the pane.
// Without a pane it serves browsers Chrome opened by itself and only keeps
// track of them.
class PaneClient : public CefClient,
                   public CefLifeSpanHandler,
                   public CefDisplayHandler,
                   public CefLoadHandler,
                   public CefCommandHandler,
                   public CefFocusHandler,
                   public CefRequestHandler {
 public:
  explicit PaneClient(OACPane* pane) : pane_(pane) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefLifeSpanHandler

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    OACPane* pane = pane_;
    if (!pane) {
      return false;
    }
    switch (target_disposition) {
      case CEF_WOD_NEW_FOREGROUND_TAB:
      case CEF_WOD_NEW_BACKGROUND_TAB:
      case CEF_WOD_NEW_WINDOW:
      case CEF_WOD_SINGLETON_TAB:
      case CEF_WOD_SWITCH_TO_TAB:
        // Tabs belong in OpenArch's sidebar, not in Chrome windows.
        [pane oac_wantsNewTabWithURL:OACToNSString(target_url)
                          background:target_disposition ==
                                     CEF_WOD_NEW_BACKGROUND_TAB];
        return true;
      default:
        // Real popups (window.open with features, OAuth flows) keep their
        // opener and get a small window of their own.
        return false;
    }
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    OACBrowserCreated(browser);
    OACPane* pane = pane_;
    if (pane) {
      [pane oac_browserCreated:browser];
    } else if (IsAdoptable(browser)) {
      // A tab Chrome opened by itself: keep its window out of sight until
      // the URL is known, then hand the URL to OpenArch.
      adopting_.push_back(browser->GetIdentifier());
      NSView* view =
          CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
      view.window.alphaValue = 0;
      TryAdopt(browser);
    }
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    OACBrowserClosed(browser);
    [pane_ oac_browserClosed];
  }

  // CefDisplayHandler

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    [pane_ oac_titleDidChange:OACToNSString(title)];
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) {
      return;
    }
    OACPane* pane = pane_;
    if (pane) {
      [pane oac_addressDidChange:OACToNSString(url)];
    } else {
      TryAdopt(browser);
    }
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override {
    [pane_ oac_faviconURLsDidChange:icon_urls];
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override {
    [pane_ oac_consoleMessage:OACToNSString(message)
                       source:OACToNSString(source)
                         line:line];
    return false;
  }

  // CefLoadHandler

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    [pane_ oac_loadingStateDidChange:isLoading
                           canGoBack:canGoBack
                        canGoForward:canGoForward];
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    if (frame->IsMain()) {
      [pane_ oac_mainFrameLoadStarted:YES url:OACToNSString(frame->GetURL())];
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (frame->IsMain()) {
      [pane_ oac_mainFrameLoadStarted:NO url:OACToNSString(frame->GetURL())];
    }
  }

  // CefRequestHandler

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    OACPane* pane = pane_;
    if (!pane || !frame->IsMain() || !user_gesture || is_redirect) {
      return false;
    }
    // Back/forward and reloads stay in the tab.
    const int transition = request->GetTransitionType();
    if ((transition & TT_FORWARD_BACK_FLAG) || (transition & TT_SOURCE_MASK) == TT_RELOAD) {
      return false;
    }
    return [pane oac_shouldInterceptNavigationToURL:OACToNSString(request->GetURL())];
  }

  // CefCommandHandler

  bool OnChromeCommand(CefRefPtr<CefBrowser> browser,
                       int command_id,
                       cef_window_open_disposition_t disposition) override {
    OACPane* pane = pane_;
    return pane ? [pane oac_handleChromeCommand:command_id] : false;
  }

  bool IsChromeToolbarButtonVisible(
      cef_chrome_toolbar_button_type_t button_type) override {
    switch (button_type) {
      case CEF_CTBT_AVATAR:  // Spaces are OpenArch's profiles.
      case CEF_CTBT_BATTERY_SAVER:
        return false;
      default:
        return true;
    }
  }

  bool IsChromeAppMenuItemVisible(CefRefPtr<CefBrowser> browser,
                                  int command_id) override {
    switch (command_id) {
      case OACChromeCommandNewWindow:
      case OACChromeCommandNewIncognitoWindow:
        return false;
      default:
        return true;
    }
  }

  // CefFocusHandler

  void OnGotFocus(CefRefPtr<CefBrowser> browser) override {
    [pane_ oac_didActivate];
  }

 private:
  // Normal tabs only: not popups (chrome.windows.create type "popup",
  // OAuth windows) and not incognito windows, which have no cache path.
  static bool IsAdoptable(CefRefPtr<CefBrowser> browser) {
    if (!g_external_tab_handler || browser->IsPopup()) {
      return false;
    }
    CefRefPtr<CefRequestContext> context =
        browser->GetHost()->GetRequestContext();
    return context && !context->GetCachePath().empty();
  }

  void TryAdopt(CefRefPtr<CefBrowser> browser) {
    const int id = browser->GetIdentifier();
    auto pending = std::find(adopting_.begin(), adopting_.end(), id);
    if (pending == adopting_.end()) {
      return;
    }
    std::string url = browser->GetMainFrame()->GetURL().ToString();
    if (url == "about:blank" && OACRemoteDebuggingEnabled()) {
      // A blank page from a DevTools client (AI control): leave it in its
      // own window so the client keeps its handle on it.
      url = "devtools://keep";
    } else if (url.empty() || url == "about:blank") {
      return;  // Wait for the real address.
    }
    adopting_.erase(pending);
    if (url.rfind("devtools://", 0) == 0) {
      NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(
          browser->GetHost()->GetWindowHandle());
      view.window.alphaValue = 1;
      return;
    }
    g_external_tab_handler([NSString stringWithUTF8String:url.c_str()]);
    browser->GetHost()->CloseBrowser(true);
  }

  std::vector<int> adopting_;
  __weak OACPane* pane_;

  IMPLEMENT_REFCOUNTING(PaneClient);
};

class PaneBrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  explicit PaneBrowserViewDelegate(OACPane* pane) : pane_(pane) {}

  ChromeToolbarType GetChromeToolbarType(
      CefRefPtr<CefBrowserView> browser_view) override {
    return CEF_CTT_NORMAL;
  }

  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

  // The toolbar only exists once the BrowserView is in a window, and the
  // client has to place it.
  void OnWindowChanged(CefRefPtr<CefView> view, bool added) override {
    if (added) {
      [pane_ oac_browserViewAddedToWindow:view->GetWindow()];
    }
  }

 private:
  __weak OACPane* pane_;

  IMPLEMENT_REFCOUNTING(PaneBrowserViewDelegate);
};

class PaneWindowDelegate : public CefWindowDelegate {
 public:
  PaneWindowDelegate(CefRefPtr<CefBrowserView> browser_view, OACPane* pane)
      : browser_view_(browser_view), pane_(pane) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    CefBoxLayoutSettings settings;
    settings.horizontal = false;
    CefRefPtr<CefBoxLayout> layout = window->SetToBoxLayout(settings);
    window->AddChildView(browser_view_);
    layout->SetFlexForView(browser_view_, 1);
    [pane_ oac_windowCreated:window];
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    browser_view_ = nullptr;
    [pane_ oac_windowDestroyed];
  }

  void OnWindowActivationChanged(CefRefPtr<CefWindow> window,
                                 bool active) override {
    if (active) {
      [pane_ oac_didActivate];
    }
  }

  bool CanClose(CefRefPtr<CefWindow> window) override {
    CefRefPtr<CefBrowser> browser =
        browser_view_ ? browser_view_->GetBrowser() : nullptr;
    return browser ? browser->GetHost()->TryCloseBrowser() : true;
  }

  bool IsFrameless(CefRefPtr<CefWindow> window) override { return true; }
  bool WithStandardWindowButtons(CefRefPtr<CefWindow> window) override {
    return false;
  }
  bool CanMaximize(CefRefPtr<CefWindow> window) override { return false; }
  bool CanMinimize(CefRefPtr<CefWindow> window) override { return false; }
  // Frameless windows crash without an initial size. The pane sets the real
  // frame before showing.
  CefRect GetInitialBounds(CefRefPtr<CefWindow> window) override {
    return CefRect(0, 0, 800, 600);
  }
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow> window) override {
    return CEF_SHOW_STATE_HIDDEN;
  }
  cef_runtime_style_t GetWindowRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  CefRefPtr<CefBrowserView> browser_view_;
  __weak OACPane* pane_;

  IMPLEMENT_REFCOUNTING(PaneWindowDelegate);
};

}  // namespace

CefRefPtr<CefClient> OACCreateDefaultClient() {
  return new PaneClient(nil);
}

@implementation OACPane {
  CefRefPtr<PaneClient> _client;
  CefRefPtr<CefBrowserView> _browserView;
  CefRefPtr<CefWindow> _cefWindow;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<CefView> _toolbar;
  __weak NSWindow* _window;
  __weak NSWindow* _parent;
  NSRect _frame;
  BOOL _wantsVisible;
  BOOL _creating;
  BOOL _closed;
  // A page has the window full screen, outside OpenArch's window.
  BOOL _fullScreen;
  id _fullScreenObserver;
  NSString* _faviconURL;
}

+ (OACPane*)paneForWindow:(NSWindow*)window {
  return [PanesByWindow() objectForKey:window];
}

+ (void (^)(NSString*))externalTabHandler {
  return g_external_tab_handler;
}

+ (void)setExternalTabHandler:(void (^)(NSString*))handler {
  g_external_tab_handler = [handler copy];
}

- (instancetype)initWithProfile:(OACProfile*)profile url:(NSString*)url {
  if ((self = [super init])) {
    _profile = profile;
    _url = [url copy];
    _title = @"";
    _toolbarVisible = YES;
    _activatesOnShow = YES;
    _cornerRadius = 0;
  }
  return self;
}

- (BOOL)isLoaded {
  return _browser != nullptr;
}

- (NSWindow*)window {
  return _window;
}

#pragma mark - Placement

- (void)showInWindow:(NSWindow*)window frame:(NSRect)frame {
  _parent = window;
  _frame = frame;
  _wantsVisible = YES;
  if (_closed) {
    return;
  }
  if (!_cefWindow) {
    [self createBrowser];  // Attaches in oac_windowCreated:.
    return;
  }
  [self attach];
}

- (void)createBrowser {
  if (_creating) {
    return;
  }
  _creating = YES;
  // Chrome-style browsers need a fully loaded profile.
  __weak OACPane* weakSelf = self;
  [_profile whenReady:^{
    [weakSelf createBrowserNow];
  }];
}

- (void)createBrowserNow {
  if (_closed) {
    [self oac_browserClosed];
    return;
  }
  _client = new PaneClient(self);
  CefBrowserSettings settings;
  _browserView = CefBrowserView::CreateBrowserView(
      _client, _url.UTF8String, settings, nullptr, [_profile cefContext],
      new PaneBrowserViewDelegate(self));
  CefWindow::CreateTopLevelWindow(new PaneWindowDelegate(_browserView, self));
}

- (void)attach {
  NSWindow* parent = _parent;
  NSWindow* window = _window;
  if (!parent || !window || _fullScreen) {
    return;
  }
  [window setFrame:[parent convertRectToScreen:_frame] display:NO];
  if (window.parentWindow != parent) {
    [window.parentWindow removeChildWindow:window];
    [parent addChildWindow:window ordered:NSWindowAbove];
  }
  if (!_isVisible) {
    if (_activatesOnShow) {
      _cefWindow->Show();
    } else {
      // Right above the parent, wherever that is in the window stack.
      [window orderWindow:NSWindowAbove relativeTo:parent.windowNumber];
    }
    _isVisible = YES;
  }
}

- (void)setFrame:(NSRect)frame {
  _frame = frame;
  NSWindow* parent = _parent;
  NSWindow* window = _window;
  if (!_isVisible || !parent || !window || _fullScreen) {
    return;
  }
  [window setFrame:[parent convertRectToScreen:frame] display:YES];
  // Hiding the parent window detaches its child windows; attach again.
  if (window.parentWindow != parent && parent.isVisible) {
    [parent addChildWindow:window ordered:NSWindowAbove];
    [window orderWindow:NSWindowAbove relativeTo:parent.windowNumber];
  }
}

- (void)hide {
  _wantsVisible = NO;
  if (!_isVisible) {
    return;
  }
  _isVisible = NO;
  NSWindow* window = _window;
  [window.parentWindow removeChildWindow:window];
  // Mirror how the pane was shown: through Views, or directly in AppKit.
  if (_cefWindow && _activatesOnShow) {
    _cefWindow->Hide();
  } else {
    [window orderOut:nil];
  }
}

- (void)focus {
  if (_cefWindow && _isVisible && _activatesOnShow) {
    _cefWindow->Activate();
  }
  if (_browser) {
    _browser->GetHost()->SetFocus(true);
  }
}

- (void)orderFront {
  NSWindow* window = _window;
  NSWindow* parent = window.parentWindow;
  if (!parent) {
    return;
  }
  [parent removeChildWindow:window];
  [parent addChildWindow:window ordered:NSWindowAbove];
}

- (void)setToolbarVisible:(BOOL)toolbarVisible {
  _toolbarVisible = toolbarVisible;
  if (_toolbar) {
    _toolbar->SetVisible(toolbarVisible);
    _cefWindow->Layout();
  }
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
  _cornerRadius = cornerRadius;
  [self applyCornerRadius];
}

- (void)applyCornerRadius {
  NSView* content = _window.contentView;
  if (!content) {
    return;
  }
  content.wantsLayer = YES;
  content.layer.cornerRadius = _cornerRadius;
  content.layer.cornerCurve = kCACornerCurveContinuous;
  content.layer.masksToBounds = _cornerRadius > 0;
}

#pragma mark - Navigation

- (void)loadURL:(NSString*)url {
  _url = [url copy];
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(url.UTF8String);
  }
}

- (void)goBack {
  if (_browser) {
    _browser->GoBack();
  }
}

- (void)goForward {
  if (_browser) {
    _browser->GoForward();
  }
}

- (void)reload {
  if (_browser) {
    _browser->Reload();
  }
}

- (void)stopLoading {
  if (_browser) {
    _browser->StopLoad();
  }
}

- (void)executeJavaScript:(NSString*)script {
  if (!_browser) {
    return;
  }
  CefRefPtr<CefFrame> frame = _browser->GetMainFrame();
  frame->ExecuteJavaScript(script.UTF8String, frame->GetURL(), 0);
}

- (void)executeJavaScript:(NSString*)script userGesture:(BOOL)userGesture {
  if (!userGesture) {
    [self executeJavaScript:script];
    return;
  }
  if (!_browser) {
    return;
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", script.UTF8String);
  params->SetBool("userGesture", true);
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
}

- (void)executeChromeCommand:(NSInteger)commandID {
  if (_browser && _browser->GetHost()->CanExecuteChromeCommand((int)commandID)) {
    _browser->GetHost()->ExecuteChromeCommand((int)commandID,
                                              CEF_WOD_CURRENT_TAB);
  }
}

- (void)showDevTools {
  [self executeChromeCommand:OACChromeCommandDevToolsToggle];
}

- (void)setAudioMuted:(BOOL)muted {
  if (_browser) {
    _browser->GetHost()->SetAudioMuted(muted);
  }
}

- (void)close {
  if (_closed) {
    return;
  }
  _closed = YES;
  if (_browser) {
    _browser->GetHost()->CloseBrowser(true);
  } else if (_cefWindow) {
    _cefWindow->Close();
  } else if (!_creating) {
    [self oac_browserClosed];
  }
}

#pragma mark - Callbacks

- (void)oac_windowCreated:(CefRefPtr<CefWindow>)window {
  _cefWindow = window;
  NSWindow* nsWindow = WindowFromHandle(window->GetWindowHandle());
  _window = nsWindow;
  if (nsWindow) {
    [PanesByWindow() setObject:self forKey:nsWindow];
    PatchPaneWindowClass(nsWindow);
    nsWindow.hasShadow = NO;
    nsWindow.movable = NO;
    // Part of OpenArch's window, not a window of its own.
    nsWindow.excludedFromWindowsMenu = YES;
    nsWindow.collectionBehavior |= NSWindowCollectionBehaviorIgnoresCycle |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary;
    nsWindow.opaque = NO;
    nsWindow.backgroundColor = NSColor.clearColor;
    [self applyCornerRadius];
  }
  if (_wantsVisible) {
    [self attach];
  }
}

- (void)oac_windowDestroyed {
  _cefWindow = nullptr;
  _browserView = nullptr;
  _toolbar = nullptr;
  _isVisible = NO;
}

- (void)oac_browserViewAddedToWindow:(CefRefPtr<CefWindow>)window {
  if (_toolbar || !_browserView || !window) {
    return;
  }
  _toolbar = _browserView->GetChromeToolbar();
  if (_toolbar) {
    window->AddChildViewAt(_toolbar, 0);
    _toolbar->SetVisible(_toolbarVisible);
    window->Layout();
  }
}

- (void)oac_browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  if (_closed) {
    browser->GetHost()->CloseBrowser(true);
  }
}

- (void)oac_browserClosed {
  _browser = nullptr;
  _client = nullptr;
  _closed = YES;
  _isVisible = NO;
  if ([self.delegate respondsToSelector:@selector(paneDidClose:)]) {
    [self.delegate paneDidClose:self];
  }
}

- (void)oac_titleDidChange:(NSString*)title {
  _title = [title copy];
  if ([self.delegate respondsToSelector:@selector(pane:titleDidChange:)]) {
    [self.delegate pane:self titleDidChange:title];
  }
}

- (void)oac_addressDidChange:(NSString*)url {
  _url = [url copy];
  if ([self.delegate respondsToSelector:@selector(pane:addressDidChange:)]) {
    [self.delegate pane:self addressDidChange:url];
  }
}

- (void)oac_faviconURLsDidChange:(const std::vector<CefString>&)urls {
  if (urls.empty() || !_browser) {
    return;
  }
  NSString* url = OACToNSString(urls.front());
  if ([url isEqualToString:_faviconURL]) {
    return;
  }
  _faviconURL = url;
  _browser->GetHost()->DownloadImage(urls.front(), true, 64, false,
                                     new FaviconCallback(self));
}

- (void)oac_faviconDidLoad:(NSImage*)image {
  _favicon = image;
  if ([self.delegate respondsToSelector:@selector(pane:faviconDidChange:)]) {
    [self.delegate pane:self faviconDidChange:image];
  }
}

- (void)oac_loadingStateDidChange:(BOOL)isLoading
                        canGoBack:(BOOL)canGoBack
                     canGoForward:(BOOL)canGoForward {
  _isLoading = isLoading;
  _canGoBack = canGoBack;
  _canGoForward = canGoForward;
  if ([self.delegate respondsToSelector:@selector
                     (pane:loadingStateDidChange:canGoBack:canGoForward:)]) {
    [self.delegate pane:self
        loadingStateDidChange:isLoading
                    canGoBack:canGoBack
                 canGoForward:canGoForward];
  }
}

- (void)oac_wantsNewTabWithURL:(NSString*)url background:(BOOL)background {
  if ([self.delegate respondsToSelector:@selector
                     (pane:wantsNewTabWithURL:background:)]) {
    [self.delegate pane:self wantsNewTabWithURL:url background:background];
  }
}

- (BOOL)oac_handleChromeCommand:(int)commandID {
  if ([self.delegate respondsToSelector:@selector(pane:handleChromeCommand:)]) {
    return [self.delegate pane:self handleChromeCommand:commandID];
  }
  return NO;
}

- (void)oac_didActivate {
  if ([self.delegate respondsToSelector:@selector(paneDidBecomeActive:)]) {
    [self.delegate paneDidBecomeActive:self];
  }
}

- (void)oac_consoleMessage:(NSString*)message
                    source:(NSString*)source
                      line:(NSInteger)line {
  if ([self.delegate respondsToSelector:@selector
                     (pane:consoleMessage:source:line:)]) {
    [self.delegate pane:self consoleMessage:message source:source line:line];
  }
}

- (void)oac_mainFrameLoadStarted:(BOOL)started url:(NSString*)url {
  if ([self.delegate respondsToSelector:@selector(pane:mainFrameLoadStarted:url:)]) {
    [self.delegate pane:self mainFrameLoadStarted:started url:url];
  }
}

// Entering: the window leaves OpenArch's window and may go full screen on
// its own. Leaving: once AppKit is done, it goes back in place.
- (void)oac_willToggleFullScreen {
  NSWindow* window = _window;
  if (!window || _fullScreen || (window.styleMask & NSWindowStyleMaskFullScreen)) {
    return;
  }
  _fullScreen = YES;
  [window.parentWindow removeChildWindow:window];
  window.collectionBehavior =
      (window.collectionBehavior & ~NSWindowCollectionBehaviorFullScreenAuxiliary) |
      NSWindowCollectionBehaviorFullScreenPrimary;
  NSView* content = window.contentView;
  content.layer.cornerRadius = 0;
  __weak OACPane* weakSelf = self;
  _fullScreenObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidExitFullScreenNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification*) {
                [weakSelf oac_didExitFullScreen];
              }];
}

- (void)oac_didExitFullScreen {
  [NSNotificationCenter.defaultCenter removeObserver:_fullScreenObserver];
  _fullScreenObserver = nil;
  _fullScreen = NO;
  NSWindow* window = _window;
  window.collectionBehavior =
      (window.collectionBehavior & ~NSWindowCollectionBehaviorFullScreenPrimary) |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  [self applyCornerRadius];
  NSWindow* parent = _parent;
  if (_isVisible && parent && window) {
    [window setFrame:[parent convertRectToScreen:_frame] display:YES];
    [parent addChildWindow:window ordered:NSWindowAbove];
  }
}

- (BOOL)oac_shouldInterceptNavigationToURL:(NSString*)url {
  if ([self.delegate respondsToSelector:@selector(pane:shouldInterceptNavigationToURL:)]) {
    return [self.delegate pane:self shouldInterceptNavigationToURL:url];
  }
  return NO;
}

@end
