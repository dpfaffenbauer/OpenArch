#import "OACPane.h"
#import "OACInternal.h"

#import <objc/runtime.h>

#include <algorithm>
#include <map>
#include <vector>

#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

@interface OACPane (Callbacks)
- (void)oac_windowCreated:(CefRefPtr<CefWindow>)window;
- (void)oac_devToolsWindowCreated:(CefRefPtr<CefWindow>)window;
- (void)oac_devToolsWindowDestroyed;
- (void)oac_devToolsOpenedInWindow;
- (void)oac_devToolsDockChosen:(NSString*)side;
- (void)oac_otherBrowserClosed:(CefRefPtr<CefBrowser>)browser;
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
- (void)oac_loadingProgressDidChange:(double)progress;
- (void)oac_wantsNewTabWithURL:(NSString*)url background:(BOOL)background;
- (BOOL)oac_handleChromeCommand:(int)commandID;
- (void)oac_didActivate;
- (void)oac_consoleMessage:(NSString*)message
                    source:(NSString*)source
                      line:(NSInteger)line;
- (void)oac_mainFrameLoadStarted:(BOOL)started url:(NSString*)url;
- (BOOL)oac_shouldInterceptNavigationToURL:(NSString*)url;
- (void)oac_willToggleFullScreen;
- (void)oac_wantsExternalURL:(NSString*)url;
- (void)oac_devToolsResult:(int)messageID success:(BOOL)success data:(NSData*)data;
@end

@interface OACDownload ()
@property(readwrite) uint32_t identifier;
@property(readwrite, copy) NSString* fileName;
@property(readwrite, copy) NSString* path;
@property(readwrite) NSInteger percentComplete;
@property(readwrite) BOOL isComplete;
@property(readwrite) BOOL isFailed;
@end

@implementation OACDownload
@end

namespace {

void (^g_external_tab_handler)(NSString*) = nil;
void (^g_download_handler)(OACDownload*) = nil;

// Names of downloads, as Chrome suggested them when they started: later
// updates carry none, and the path is "Unconfirmed 123.crdownload" until
// the download is done.
std::map<uint32_t, std::string>& DownloadNames() {
  static std::map<uint32_t, std::string> names;
  return names;
}

// Schemes Chromium shows itself; any other (bambustudioopen:, zoommtg:,
// mailto: ...) belongs to an app on the Mac.
bool IsExternalScheme(const CefString& url) {
  NSString* string = OACToNSString(url);
  const NSRange colon = [string rangeOfString:@":"];
  if (colon.location == NSNotFound) {
    return false;
  }
  NSString* scheme = [string substringToIndex:colon.location].lowercaseString;
  static NSSet<NSString*>* internal = [NSSet setWithArray:@[
    @"http", @"https", @"file", @"ftp", @"data", @"blob", @"about", @"chrome",
    @"chrome-extension", @"chrome-untrusted", @"chrome-search", @"devtools",
    @"view-source", @"javascript", @"filesystem", @"ws", @"wss"
  ]];
  return scheme.length && ![internal containsObject:scheme];
}

// Running downloads, to cancel them (see +cancelDownload:).
std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>>& DownloadCallbacks() {
  static std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> callbacks;
  return callbacks;
}

// Between the page and its docked DevTools.
constexpr CGFloat kDevToolsGap = 6;

OACDevToolsDock g_devtools_dock = OACDevToolsDockRight;
void (^g_devtools_dock_handler)(OACDevToolsDock) = nil;

// DevTools' own names for the dock sides, in OACDevToolsDock's order.
NSArray<NSString*>* DevToolsDockSides() {
  return @[ @"right", @"left", @"bottom", @"undocked" ];
}

NSString* const kDevToolsDockMarker = @"__openarch_devtools_dock__ ";

// DevTools think a tab of OpenArch cannot dock (Chrome finds no window to
// dock them in), so they hide their Dock side menu. This shows it with the
// side OpenArch docks them on, and reports a choice back to the pane
// (OnConsoleMessage), which docks them there.
std::string DevToolsDockScript() {
  NSString* script = [NSString stringWithFormat:@
      "(async () => { try {"
      // A script run from outside has no base URL for import().
      "  const ui = await import(new URL('./ui/legacy/legacy.js', location.href).href);"
      "  for (let i = 0; i < 100 && !ui.InspectorView.InspectorView.maybeGetInspectorViewInstance(); i++)"
      "    await new Promise((resolve) => setTimeout(resolve, 100));"
      "  const Dock = ui.DockController.DockController;"
      "  Dock.prototype.canDock = () => true;"
      "  const dock = Dock.instance();"
      "  dock.setDockSide('%@');"
      "  dock.addEventListener('DockSideChanged', (event) => console.debug('%@' + event.data.to));"
      "} catch (error) { console.debug('%@error ' + error); } })();",
      DevToolsDockSides()[g_devtools_dock], kDevToolsDockMarker, kDevToolsDockMarker];
  return script.UTF8String;
}

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
                   public CefRequestHandler,
                   public CefDownloadHandler {
 public:
  explicit PaneClient(OACPane* pane) : pane_(pane) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

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
    OACPane* pane = Own(browser);
    if (!pane) {
      return false;
    }
    if (IsExternalScheme(target_url)) {
      [pane oac_wantsExternalURL:OACToNSString(target_url)];
      return true;
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
        // opener and get a small window of their own, and a client of their
        // own: with this one the tab would take the popup for its browser,
        // and count itself closed once the popup closes.
        client = OACCreateDefaultClient();
        return false;
    }
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    OACBrowserCreated(browser);
    OACPane* pane = pane_;
    if (pane && own_id_ == 0) {
      own_id_ = browser->GetIdentifier();
      [pane oac_browserCreated:browser];
    } else if (!pane && IsAdoptable(browser)) {
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
    if (OACPane* pane = Own(browser)) {
      [pane oac_browserClosed];
    } else {
      [pane_ oac_otherBrowserClosed:browser];
    }
  }

  // CefDisplayHandler

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    [Own(browser) oac_titleDidChange:OACToNSString(title)];
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) {
      return;
    }
    OACPane* pane = Own(browser);
    if (pane) {
      [pane oac_addressDidChange:OACToNSString(url)];
    } else {
      TryAdopt(browser);
    }
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override {
    [Own(browser) oac_faviconURLsDidChange:icon_urls];
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                               double progress) override {
    [Own(browser) oac_loadingProgressDidChange:progress];
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override {
    OACPane* pane = Own(browser);
    NSString* text = OACToNSString(message);
    if (!pane && [text hasPrefix:kDevToolsDockMarker]) {
      // DevTools' own Dock side menu (see DevToolsDockScript).
      [pane_ oac_devToolsDockChosen:[text substringFromIndex:kDevToolsDockMarker.length]];
      return true;
    }
    [pane oac_consoleMessage:text source:OACToNSString(source) line:line];
    return false;
  }

  // CefLoadHandler

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    [Own(browser) oac_loadingStateDidChange:isLoading
                           canGoBack:canGoBack
                        canGoForward:canGoForward];
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    if (frame->IsMain()) {
      [Own(browser) oac_mainFrameLoadStarted:YES url:OACToNSString(frame->GetURL())];
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (frame->IsMain()) {
      [Own(browser) oac_mainFrameLoadStarted:NO url:OACToNSString(frame->GetURL())];
    }
    if (!Own(browser) && pane_ && frame->IsMain() &&
        frame->GetURL().ToString().rfind("devtools://devtools/", 0) == 0) {
      frame->ExecuteJavaScript(DevToolsDockScript(), frame->GetURL(), 0);
    }
  }

  // CefDownloadHandler

  // Chrome's own handling: the Downloads folder (or "Ask where to save"),
  // and its downloads bubble.
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (download_item->IsValid() && !suggested_name.empty()) {
      DownloadNames()[download_item->GetId()] = suggested_name.ToString();
    }
    Report(download_item, OACToNSString(suggested_name));
    return false;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (download_item->IsValid()) {
      if (download_item->IsInProgress()) {
        DownloadCallbacks()[download_item->GetId()] = callback;
      } else {
        DownloadCallbacks().erase(download_item->GetId());
      }
    }
    Report(download_item, OACToNSString(download_item->GetSuggestedFileName()));
  }

  void Report(CefRefPtr<CefDownloadItem> item, NSString* suggestedName) {
    if (!g_download_handler || !item->IsValid()) {
      return;
    }
    OACDownload* download = [[OACDownload alloc] init];
    download.identifier = item->GetId();
    download.path = OACToNSString(item->GetFullPath());
    NSString* name = suggestedName;
    auto known = DownloadNames().find(item->GetId());
    if (!name.length && known != DownloadNames().end()) {
      name = [NSString stringWithUTF8String:known->second.c_str()];
    }
    if (!name.length && ![download.path hasSuffix:@".crdownload"]) {
      name = download.path.lastPathComponent;
    }
    download.fileName = name.length ? name : OACToNSString(item->GetURL()).lastPathComponent;
    download.percentComplete = item->GetPercentComplete();
    download.isComplete = item->IsComplete();
    download.isFailed = item->IsCanceled() || item->IsInterrupted();
    if (download.isComplete || download.isFailed) {
      DownloadNames().erase(item->GetId());
    }
    g_download_handler(download);
  }

  // CefRequestHandler

  // ⌘-clicks and middle clicks on links: Chrome would make the tab itself,
  // in a window of its own, and OpenArch could only adopt it afterwards
  // (shown, in front). The sidebar takes it in the background instead.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    OACPane* pane = Own(browser);
    if (!pane) {
      return false;
    }
    if (IsExternalScheme(target_url)) {
      [pane oac_wantsExternalURL:OACToNSString(target_url)];
      return true;
    }
    switch (target_disposition) {
      case CEF_WOD_NEW_FOREGROUND_TAB:
      case CEF_WOD_NEW_BACKGROUND_TAB:
      case CEF_WOD_NEW_WINDOW:
        [pane oac_wantsNewTabWithURL:OACToNSString(target_url)
                          background:target_disposition ==
                                     CEF_WOD_NEW_BACKGROUND_TAB];
        return true;
      default:
        return false;
    }
  }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    OACPane* pane = Own(browser);
    if (pane && IsExternalScheme(request->GetURL())) {
      // Chromium would only show ERR_UNKNOWN_URL_SCHEME; the app is asked.
      [pane oac_wantsExternalURL:OACToNSString(request->GetURL())];
      return true;
    }
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
    OACPane* pane = Own(browser);
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
    [Own(browser) oac_didActivate];
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
  // The pane, for events of the pane's own browser. Other browsers using
  // this client (the tab's DevTools) must not count as the tab: closing
  // them would close it.
  OACPane* Own(CefRefPtr<CefBrowser> browser) const {
    return browser && browser->GetIdentifier() == own_id_ ? pane_ : nil;
  }

  __weak OACPane* pane_;
  int own_id_ = 0;

  IMPLEMENT_REFCOUNTING(PaneClient);
};

// The frameless window docked DevTools live in, placed by the pane.
class DevToolsWindowDelegate : public CefWindowDelegate {
 public:
  DevToolsWindowDelegate(CefRefPtr<CefBrowserView> browser_view, OACPane* pane)
      : browser_view_(browser_view), pane_(pane) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    CefBoxLayoutSettings settings;
    settings.horizontal = false;
    CefRefPtr<CefBoxLayout> layout = window->SetToBoxLayout(settings);
    window->AddChildView(browser_view_);
    layout->SetFlexForView(browser_view_, 1);
    [pane_ oac_devToolsWindowCreated:window];
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    browser_view_ = nullptr;
    [pane_ oac_devToolsWindowDestroyed];
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
  CefRect GetInitialBounds(CefRefPtr<CefWindow> window) override {
    return CefRect(0, 0, 600, 600);
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

  IMPLEMENT_REFCOUNTING(DevToolsWindowDelegate);
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

  // DevTools: Chrome cannot dock them next to a Views-hosted tab, so the
  // pane does, in its own window beside the page.
  CefRefPtr<CefBrowserViewDelegate> GetDelegateForPopupBrowserView(
      CefRefPtr<CefBrowserView> browser_view,
      const CefBrowserSettings& settings,
      CefRefPtr<CefClient> client,
      bool is_devtools) override {
    if (is_devtools) {
      return new DevToolsViewDelegate();
    }
    return this;
  }

  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> browser_view,
                                 CefRefPtr<CefBrowserView> popup_browser_view,
                                 bool is_devtools) override {
    OACPane* pane = pane_;
    if (!is_devtools || !pane) {
      return false;
    }
    if (g_devtools_dock == OACDevToolsDockWindow) {
      // CEF's own window, with a title bar.
      [pane oac_devToolsOpenedInWindow];
      return false;
    }
    CefWindow::CreateTopLevelWindow(new DevToolsWindowDelegate(popup_browser_view, pane));
    return true;
  }

 private:
  // DevTools need no toolbar of their own.
  class DevToolsViewDelegate : public CefBrowserViewDelegate {
   public:
    ChromeToolbarType GetChromeToolbarType(
        CefRefPtr<CefBrowserView> browser_view) override {
      return CEF_CTT_NONE;
    }
    cef_runtime_style_t GetBrowserRuntimeStyle() override {
      return CEF_RUNTIME_STYLE_CHROME;
    }

   private:
    IMPLEMENT_REFCOUNTING(DevToolsViewDelegate);
  };

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

// Hands DevTools method results (on the UI thread) back to the pane.
class DevToolsObserver : public CefDevToolsMessageObserver {
 public:
  explicit DevToolsObserver(OACPane* pane) : pane_(pane) {}

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override {
    NSData* data = [NSData dataWithBytes:result length:result_size];
    [pane_ oac_devToolsResult:message_id success:success data:data];
  }

 private:
  __weak OACPane* pane_;

  IMPLEMENT_REFCOUNTING(DevToolsObserver);
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
  // DevTools, docked beside the page in a window of their own.
  CefRefPtr<CefWindow> _devToolsCefWindow;
  __weak NSWindow* _devToolsWindow;
  // DevTools in a window of their own are open.
  BOOL _devToolsInWindow;
  // Open the DevTools again once they have closed (the dock changed).
  BOOL _reopenDevTools;
  __weak NSWindow* _window;
  __weak NSWindow* _parent;
  NSRect _frame;
  BOOL _wantsVisible;
  // Shown at least once; until then it is a tab loading in the background.
  BOOL _wasShown;
  BOOL _creating;
  BOOL _closed;
  // A page has the window full screen, outside OpenArch's window.
  BOOL _fullScreen;
  id _fullScreenObserver;
  NSString* _faviconURL;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber*, void (^)(NSDictionary*)>* _devToolsCallbacks;
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

+ (BOOL)cancelDownload:(uint32_t)identifier {
  auto found = DownloadCallbacks().find(identifier);
  if (found == DownloadCallbacks().end()) {
    return NO;
  }
  found->second->Cancel();
  DownloadCallbacks().erase(found);
  return YES;
}

+ (void (^)(OACDownload*))downloadHandler {
  return g_download_handler;
}

+ (void)setDownloadHandler:(void (^)(OACDownload*))handler {
  g_download_handler = [handler copy];
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

- (void)load {
  if (!_closed && !_cefWindow) {
    [self createBrowser];  // The window stays hidden until shown.
  }
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
  [window setFrame:[parent convertRectToScreen:[self pageFrame]] display:NO];
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
    _wasShown = YES;
  }
  [self attachDevTools];
}

- (void)setFrame:(NSRect)frame {
  _frame = frame;
  NSWindow* parent = _parent;
  NSWindow* window = _window;
  if (!_isVisible || !parent || !window || _fullScreen) {
    return;
  }
  [window setFrame:[parent convertRectToScreen:[self pageFrame]] display:YES];
  // Hiding the parent window detaches its child windows; attach again.
  if (window.parentWindow != parent && parent.isVisible) {
    [parent addChildWindow:window ordered:NSWindowAbove];
    [window orderWindow:NSWindowAbove relativeTo:parent.windowNumber];
  }
  NSWindow* devTools = _devToolsWindow;
  if (devTools) {
    [devTools setFrame:[parent convertRectToScreen:[self devToolsFrame]] display:YES];
    if (devTools.parentWindow != parent && parent.isVisible) {
      [parent addChildWindow:devTools ordered:NSWindowAbove];
      [devTools orderWindow:NSWindowAbove relativeTo:parent.windowNumber];
    }
  }
}

- (void)hide {
  _wantsVisible = NO;
  if (!_isVisible) {
    return;
  }
  _isVisible = NO;
  [self detachDevTools];
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
  NSWindow* devTools = _devToolsWindow;
  if (devTools.parentWindow == parent) {
    [parent removeChildWindow:devTools];
    [parent addChildWindow:devTools ordered:NSWindowAbove];
  }
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
  for (NSWindow* window in @[ _window ?: NSNull.null, _devToolsWindow ?: NSNull.null ]) {
    NSView* content = [window isKindOfClass:NSWindow.class] ? window.contentView : nil;
    if (!content) {
      continue;
    }
    content.wantsLayer = YES;
    content.layer.cornerRadius = _cornerRadius;
    content.layer.cornerCurve = kCACornerCurveContinuous;
    content.layer.masksToBounds = _cornerRadius > 0;
  }
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

- (void)callDevToolsMethod:(NSString*)method
                    params:(NSDictionary<NSString*, id>*)params
                completion:(void (^)(NSDictionary<NSString*, id>*))completion {
  if (!_browser) {
    if (completion) {
      completion(nil);
    }
    return;
  }
  if (!_devToolsRegistration) {
    _devToolsRegistration = _browser->GetHost()->AddDevToolsMessageObserver(
        new DevToolsObserver(self));
    _devToolsCallbacks = [NSMutableDictionary dictionary];
  }
  // Far above the IDs CEF picks for ExecuteDevToolsMethod(0, ...).
  static int next_id = 1 << 24;
  const int message_id = next_id++;
  NSData* json = [NSJSONSerialization
      dataWithJSONObject:@{@"id" : @(message_id), @"method" : method, @"params" : params}
                 options:0
                   error:nil];
  if (completion) {
    _devToolsCallbacks[@(message_id)] = [completion copy];
  }
  if (!json || !_browser->GetHost()->SendDevToolsMessage(json.bytes, json.length)) {
    [self oac_devToolsResult:message_id success:NO data:[NSData data]];
  }
}

- (void)oac_devToolsResult:(int)messageID success:(BOOL)success data:(NSData*)data {
  void (^completion)(NSDictionary*) = _devToolsCallbacks[@(messageID)];
  if (!completion) {
    return;
  }
  [_devToolsCallbacks removeObjectForKey:@(messageID)];
  id result = success ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  completion([result isKindOfClass:NSDictionary.class] ? result : nil);
}

- (NSInteger)zoomPercent {
  if (!_browser) {
    return 100;
  }
  // Chrome's zoom levels are powers of 1.2.
  return (NSInteger)lround(pow(1.2, _browser->GetHost()->GetZoomLevel()) * 100);
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

- (void)oac_devToolsWindowCreated:(CefRefPtr<CefWindow>)window {
  _devToolsCefWindow = window;
  NSWindow* nsWindow = WindowFromHandle(window->GetWindowHandle());
  _devToolsWindow = nsWindow;
  nsWindow.hasShadow = NO;
  nsWindow.movable = NO;
  nsWindow.excludedFromWindowsMenu = YES;
  nsWindow.collectionBehavior |= NSWindowCollectionBehaviorIgnoresCycle |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary;
  nsWindow.opaque = NO;
  nsWindow.backgroundColor = NSColor.clearColor;
  [self applyCornerRadius];
  if (_isVisible) {
    [self layoutWindows];
    [self attachDevTools];
  }
}

- (void)oac_devToolsWindowDestroyed {
  _devToolsCefWindow = nullptr;
  _devToolsWindow = nil;
  [self layoutWindows];
  [self reopenDevToolsIfAsked];
}

- (void)oac_devToolsOpenedInWindow {
  _devToolsInWindow = YES;
}

- (void)reopenDevToolsIfAsked {
  if (!_reopenDevTools) {
    return;
  }
  _reopenDevTools = NO;
  __weak OACPane* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf executeChromeCommand:OACChromeCommandDevToolsToggle];
  });
}

- (void)oac_devToolsDockChosen:(NSString*)side {
  const NSUInteger index = [DevToolsDockSides() indexOfObject:side];
  if (index == NSNotFound) {
    NSLog(@"OpenArch: DevTools dock side menu: %@", side);
    return;
  }
  if ((OACDevToolsDock)index == g_devtools_dock) {
    return;
  }
  // Not while DevTools are still handling their click.
  dispatch_async(dispatch_get_main_queue(), ^{
    OACPane.devToolsDock = (OACDevToolsDock)index;
    if (g_devtools_dock_handler) {
      g_devtools_dock_handler((OACDevToolsDock)index);
    }
  });
}

+ (void (^)(OACDevToolsDock))devToolsDockHandler {
  return g_devtools_dock_handler;
}

+ (void)setDevToolsDockHandler:(void (^)(OACDevToolsDock))handler {
  g_devtools_dock_handler = [handler copy];
}

+ (OACDevToolsDock)devToolsDock {
  return g_devtools_dock;
}

+ (void)setDevToolsDock:(OACDevToolsDock)dock {
  const BOOL wasWindow = g_devtools_dock == OACDevToolsDockWindow;
  g_devtools_dock = dock;
  for (OACPane* pane in PanesByWindow().objectEnumerator) {
    const BOOL open = pane->_devToolsWindow != nil || pane->_devToolsInWindow;
    if (open && wasWindow != (dock == OACDevToolsDockWindow)) {
      pane->_reopenDevTools = [pane closeDevTools];
    } else {
      [pane layoutWindows];
    }
  }
}

// The tab's DevTools closed (from their own shortcut, or with the tab):
// their window goes, and the page takes the whole frame again.
- (void)oac_otherBrowserClosed:(CefRefPtr<CefBrowser>)browser {
  if (_devToolsInWindow) {
    _devToolsInWindow = NO;
    [self reopenDevToolsIfAsked];
  }
  CefRefPtr<CefWindow> window = _devToolsCefWindow;
  if (!window) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    window->Close();
  });
}

- (BOOL)closeDevTools {
  if ((!_devToolsCefWindow && !_devToolsInWindow) || !_browser) {
    return NO;
  }
  _browser->GetHost()->CloseDevTools();
  return YES;
}

+ (BOOL)closeDevToolsInWindow:(NSWindow*)window {
  for (OACPane* pane in PanesByWindow().objectEnumerator) {
    if (pane->_devToolsWindow == window) {
      return [pane closeDevTools];
    }
  }
  return NO;
}

// The page and its docked DevTools share _frame: DevTools take 40 % of the
// width on the right or left, or 38 % of the height below.
- (NSRect)pageFrame {
  NSRect page = _frame, devTools;
  [self splitFrame:&page devTools:&devTools];
  return page;
}

- (NSRect)devToolsFrame {
  NSRect page, devTools = _frame;
  [self splitFrame:&page devTools:&devTools];
  return devTools;
}

- (void)splitFrame:(NSRect*)page devTools:(NSRect*)devTools {
  *page = _frame;
  *devTools = NSZeroRect;
  if (!_devToolsWindow) {
    return;
  }
  NSRect first, second;
  if (g_devtools_dock == OACDevToolsDockBottom) {
    const CGFloat height = floor((_frame.size.height - kDevToolsGap) * 0.38);
    NSDivideRect(_frame, devTools, &second, height, NSMinYEdge);
    NSDivideRect(second, &first, &second, kDevToolsGap, NSMinYEdge);
    *page = second;
    return;
  }
  const CGFloat width = floor((_frame.size.width - kDevToolsGap) * 0.4);
  const NSRectEdge edge = g_devtools_dock == OACDevToolsDockLeft ? NSMinXEdge : NSMaxXEdge;
  NSDivideRect(_frame, devTools, &second, width, edge);
  NSDivideRect(second, &first, &second, kDevToolsGap, edge);
  *page = second;
}

- (void)layoutWindows {
  NSWindow* parent = _parent;
  NSWindow* window = _window;
  if (!_isVisible || !parent || !window || _fullScreen) {
    return;
  }
  [window setFrame:[parent convertRectToScreen:[self pageFrame]] display:YES];
  NSWindow* devTools = _devToolsWindow;
  if (devTools) {
    [devTools setFrame:[parent convertRectToScreen:[self devToolsFrame]] display:YES];
  }
}

- (void)attachDevTools {
  NSWindow* parent = _parent;
  NSWindow* devTools = _devToolsWindow;
  if (!parent || !devTools || _fullScreen) {
    return;
  }
  [devTools setFrame:[parent convertRectToScreen:[self devToolsFrame]] display:NO];
  if (devTools.parentWindow != parent) {
    [devTools.parentWindow removeChildWindow:devTools];
    [parent addChildWindow:devTools ordered:NSWindowAbove];
  }
  if (!devTools.isVisible) {
    if (_activatesOnShow) {
      _devToolsCefWindow->Show();
    } else {
      [devTools orderWindow:NSWindowAbove relativeTo:parent.windowNumber];
    }
  }
}

- (void)detachDevTools {
  NSWindow* devTools = _devToolsWindow;
  if (!devTools) {
    return;
  }
  [devTools.parentWindow removeChildWindow:devTools];
  if (_devToolsCefWindow && _activatesOnShow) {
    _devToolsCefWindow->Hide();
  } else {
    [devTools orderOut:nil];
  }
}

- (void)setRefusesToCloseForTesting:(BOOL)refuses {
  _refusesToCloseForTesting = refuses;
  if (_browser) {
    OACSetRefusesToCloseForTesting(_browser, refuses);
  }
}

- (void)oac_browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  if (_closed) {
    browser->GetHost()->CloseBrowser(true);
  }
}

- (void)oac_browserClosed {
  _devToolsRegistration = nullptr;
  NSDictionary<NSNumber*, void (^)(NSDictionary*)>* callbacks = _devToolsCallbacks;
  _devToolsCallbacks = nil;
  for (NSNumber* messageID in callbacks) {
    callbacks[messageID](nil);
  }
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

- (void)oac_loadingProgressDidChange:(double)progress {
  if ([self.delegate respondsToSelector:@selector
                     (pane:loadingProgressDidChange:)]) {
    [self.delegate pane:self loadingProgressDidChange:progress];
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
  // A tab loading in the background gets focus as Chromium creates it; that
  // is no reason to bring it to the front.
  if (!_wasShown) {
    return;
  }
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

- (void)oac_wantsExternalURL:(NSString*)url {
  if ([self.delegate respondsToSelector:@selector(pane:wantsToOpenExternalURL:)]) {
    [self.delegate pane:self wantsToOpenExternalURL:url];
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
