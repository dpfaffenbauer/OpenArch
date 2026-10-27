#import "OACBrowserView.h"
#import "OACInternal.h"

#include "include/cef_client.h"

@interface OACBrowserView (ClientCallbacks)
- (void)oac_browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)oac_titleDidChange:(NSString*)title;
- (void)oac_addressDidChange:(NSString*)url;
- (void)oac_loadingStateDidChange:(BOOL)isLoading
                        canGoBack:(BOOL)canGoBack
                     canGoForward:(BOOL)canGoForward;
- (void)oac_didFinishLoading;
- (void)oac_consoleMessage:(NSString*)message
                    source:(NSString*)source
                      line:(NSInteger)line;
- (void)oac_wantsNewTabWithURL:(NSString*)url;
- (void)oac_browserDidClose;
@end

namespace {

// Routes CEF callbacks (always on the main thread on macOS) to the view.
// A client without a view serves Chrome-style windows, which manage
// themselves.
class OACClient : public CefClient,
                  public CefLifeSpanHandler,
                  public CefDisplayHandler,
                  public CefLoadHandler {
 public:
  explicit OACClient(OACBrowserView* view) : view_(view) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

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
    OACBrowserView* view = view_;
    if (!view) {
      return false;
    }
    // Popups become tabs in our own UI instead of CEF-created windows.
    [view oac_wantsNewTabWithURL:OACToNSString(target_url)];
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    OACBrowserCreated(browser);
    [view_ oac_browserCreated:browser];
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // The browser lives in a tab, not in its own window: tear down only its
    // view instead of letting CEF send performClose: to our whole window.
    NSView* cefView =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    [cefView removeFromSuperview];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    OACBrowserClosed(browser);
    [view_ oac_browserDidClose];
  }

  // CefDisplayHandler

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    [view_ oac_titleDidChange:OACToNSString(title)];
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame->IsMain()) {
      [view_ oac_addressDidChange:OACToNSString(url)];
    }
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override {
    if (!view_) {
      // Chrome-style windows have no view to report to.
      fprintf(stderr, "[OpenArchCore] chrome-style console: %s\n",
              message.ToString().c_str());
    }
    [view_ oac_consoleMessage:OACToNSString(message)
                       source:OACToNSString(source)
                         line:line];
    return false;
  }

  // CefLoadHandler

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    [view_ oac_loadingStateDidChange:isLoading
                           canGoBack:canGoBack
                        canGoForward:canGoForward];
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (frame->IsMain()) {
      [view_ oac_didFinishLoading];
    }
  }

 private:
  __weak OACBrowserView* view_;

  IMPLEMENT_REFCOUNTING(OACClient);
};

}  // namespace

@implementation OACBrowserView {
  NSString* _initialURL;
  CefRefPtr<CefBrowser> _browser;
  BOOL _creating;
  BOOL _closed;
}

- (instancetype)initWithProfile:(OACProfile*)profile url:(NSString*)url {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _profile = profile;
    _initialURL = [url copy];
    self.autoresizesSubviews = YES;
  }
  return self;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window && !_browser && !_creating && !_closed) {
    [self createBrowser];
  }
}

// Asynchronous on purpose: a new profile initializes asynchronously and
// CreateBrowserSync fails until it is ready. The browser arrives in
// oac_browserCreated:.
- (void)createBrowser {
  NSRect bounds = self.bounds;
  CefWindowInfo windowInfo;
  windowInfo.SetAsChild(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(self),
      CefRect(0, 0, (int)bounds.size.width, (int)bounds.size.height));
  CefBrowserSettings browserSettings;
  _creating = CefBrowserHost::CreateBrowser(
      windowInfo, new OACClient(self), _initialURL.UTF8String, browserSettings,
      nullptr, [_profile cefContext]);
  if (!_creating) {
    NSLog(@"OpenArch: failed to create browser for %@", _initialURL);
  }
}

- (void)oac_browserCreated:(CefRefPtr<CefBrowser>)browser {
  _creating = NO;
  _browser = browser;
  NSView* cefView =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  cefView.frame = self.bounds;
  cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (self.hidden) {
    browser->GetHost()->WasHidden(true);
  }
  if (_closed) {
    browser->GetHost()->CloseBrowser(true);
  }
}

- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  if (_browser) {
    _browser->GetHost()->WasHidden(hidden);
  }
}

- (void)loadURL:(NSString*)url {
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(url.UTF8String);
  } else {
    _initialURL = [url copy];
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

- (void)executeJavaScript:(NSString*)script {
  if (!_browser) {
    return;
  }
  CefRefPtr<CefFrame> frame = _browser->GetMainFrame();
  frame->ExecuteJavaScript(script.UTF8String, frame->GetURL(), 0);
}

- (void)showDevTools {
  if (!_browser) {
    return;
  }
  CefWindowInfo windowInfo;
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(windowInfo, nullptr, settings, CefPoint());
}

- (void)close {
  _closed = YES;
  if (_browser) {
    _browser->GetHost()->CloseBrowser(true);
  } else if (!_creating) {
    [self oac_browserDidClose];
  }
}

+ (void)openChromeStyleWindowWithURL:(NSString*)url profile:(OACProfile*)profile {
  CefWindowInfo windowInfo;
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings;
  CefBrowserHost::CreateBrowser(windowInfo, new OACClient(nil), url.UTF8String,
                                settings, nullptr, [profile cefContext]);
}

#pragma mark - Client callbacks

- (void)oac_titleDidChange:(NSString*)title {
  if ([self.delegate respondsToSelector:@selector(browserView:titleDidChange:)]) {
    [self.delegate browserView:self titleDidChange:title];
  }
}

- (void)oac_addressDidChange:(NSString*)url {
  if ([self.delegate respondsToSelector:@selector(browserView:addressDidChange:)]) {
    [self.delegate browserView:self addressDidChange:url];
  }
}

- (void)oac_loadingStateDidChange:(BOOL)isLoading
                        canGoBack:(BOOL)canGoBack
                     canGoForward:(BOOL)canGoForward {
  if ([self.delegate respondsToSelector:@selector
                     (browserView:loadingStateDidChange:canGoBack:canGoForward:)]) {
    [self.delegate browserView:self
         loadingStateDidChange:isLoading
                     canGoBack:canGoBack
                  canGoForward:canGoForward];
  }
}

- (void)oac_didFinishLoading {
  if ([self.delegate respondsToSelector:@selector(browserViewDidFinishLoading:)]) {
    [self.delegate browserViewDidFinishLoading:self];
  }
}

- (void)oac_consoleMessage:(NSString*)message
                    source:(NSString*)source
                      line:(NSInteger)line {
  if ([self.delegate respondsToSelector:@selector
                     (browserView:consoleMessage:source:line:)]) {
    [self.delegate browserView:self consoleMessage:message source:source line:line];
  }
}

- (void)oac_wantsNewTabWithURL:(NSString*)url {
  if ([self.delegate respondsToSelector:@selector(browserView:wantsNewTabWithURL:)]) {
    [self.delegate browserView:self wantsNewTabWithURL:url];
  }
}

- (void)oac_browserDidClose {
  _browser = nullptr;
  if ([self.delegate respondsToSelector:@selector(browserViewDidClose:)]) {
    [self.delegate browserViewDidClose:self];
  }
}

@end
