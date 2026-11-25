// OACPane on Chrome's framework. Each pane is a tab of its profile's hidden
// Chrome window (a normal Browser, never shown), so Chrome treats it as a
// real tab: extensions, popups, permission prompts. OpenArch shows the tab's
// view in its own window, where the pane is put, and tells Chromium whether
// it is on screen.

#include "openarch/internal.h"
#import "openarch/findbar.h"
#import "openarch/page_window.h"
#import "openarch/toolbar.h"

#import <AppKit/AppKit.h>

#include <deque>
#include <map>
#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/values.h"
#include "chrome/browser/devtools/devtools_contents_resizing_strategy.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/download/download_core_service.h"
#include "chrome/browser/file_select_helper.h"
#include "chrome/browser/openarch_engine_hooks.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/javascript_dialogs/javascript_tab_modal_dialog_manager_delegate_desktop.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/javascript_dialogs/tab_modal_dialog_manager.h"
#include "content/public/browser/invalidate_type.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "third_party/blink/public/mojom/window_features/window_features.mojom.h"
#include "content/public/browser/web_contents_delegate.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "ui/base/base_window.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "third_party/blink/public/mojom/devtools/console_message.mojom.h"
#include "ui/gfx/image/image.h"
#include "url/url_constants.h"
#include "base/functional/callback_helpers.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "components/download/public/common/download_item.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/context_menu_params.h"
#include "ui/menus/simple_menu_model.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/views/controls/webview/openarch_hosted_page.h"
#include "url/gurl.h"

@interface OACDownload () {
 @package
  uint32_t _identifier;
  NSString* _fileName;
  NSString* _path;
  NSInteger _percentComplete;
  BOOL _isComplete;
  BOOL _isFailed;
}
@end

@interface OACPane ()
- (void)titleChanged;
- (void)addressChanged;
- (void)loadingChanged;
- (void)progressChanged:(double)progress;
- (void)mainFrameLoad:(BOOL)started url:(const GURL&)url;
- (void)webContentsDestroyed;
- (BOOL)pageFullScreen;
- (void)enterPageFullScreen;
- (void)exitPageFullScreen;
- (void)gotFocus;
- (void)consoleMessage:(NSString*)message source:(NSString*)source line:(NSInteger)line;
- (void)faviconChanged:(NSImage*)image;
- (BOOL)takeNewTabWithURL:(const GURL&)url disposition:(WindowOpenDisposition)disposition;
- (BOOL)interceptsNavigationToURL:(const GURL&)url;
- (BOOL)handsOffNavigationToURL:(const GURL&)url method:(NSString*)method;
- (void)mediaAccessChangedVideo:(BOOL)video audio:(BOOL)audio;
- (void)wantsExternalURL:(const GURL&)url;
- (void)openHistoryEntryInNewTab:(NSInteger)offset background:(BOOL)background;
- (void)pageColorChanged;
- (void)devToolsClosed;
- (void)adoptDevTools;
- (void)layoutViews;
- (void)makeActiveTab;
@end

namespace {

// Which hidden Chrome window holds which profile's pages.
std::map<Profile*, raw_ptr<BrowserWindowInterface>>& HiddenBrowsers() {
  static base::NoDestructor<std::map<Profile*, raw_ptr<BrowserWindowInterface>>> browsers;
  return *browsers;
}

void (^g_external_tab_handler_early)(NSString*) = nil;

// A tab Chrome opened in a hidden window by itself (View Source, an
// extension's chrome.tabs.create, ...): once its address is known it goes to
// OACPane.externalTabHandler (OpenArch's sidebar), and Chrome's tab closes.
class ChromeTabWatcher : public content::WebContentsObserver {
 public:
  explicit ChromeTabWatcher(content::WebContents* contents)
      : content::WebContentsObserver(contents) {
    const GURL& url = contents->GetVisibleURL();
    if (url.is_valid() && !url.IsAboutBlank()) {
      Adopt(url);
    }
  }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) {
      Adopt(handle->GetURL());
    }
  }
  void WebContentsDestroyed() override { delete this; }

 private:
  void Adopt(const GURL& url) {
    if (adopted_) {
      return;
    }
    adopted_ = true;
    // Not while Chrome is still adding the tab or starting its navigation.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ChromeTabWatcher::Hand, weak_factory_.GetWeakPtr(), url));
  }

  void Hand(const GURL& url) {
    void (^handler)(NSString*) = g_external_tab_handler_early;
    content::WebContents* contents = web_contents();
    if (!handler || !contents) {
      return;
    }
    for (BrowserWindowInterface* browser : GetAllBrowserWindowInterfaces()) {
      TabStripModel* tabs = browser->GetTabStripModel();
      int index = tabs->GetIndexOfWebContents(contents);
      if (index != TabStripModel::kNoTab) {
        handler(openarch::ToNSString(url.spec()));
        tabs->DetachAndDeleteWebContentsAt(index);  // deletes this
        return;
      }
    }
  }

  bool adopted_ = false;
  base::WeakPtrFactory<ChromeTabWatcher> weak_factory_{this};
};

class ChromeTabCatcher : public TabStripModelObserver {
 public:
  static ChromeTabCatcher* Get() {
    static base::NoDestructor<ChromeTabCatcher> catcher;
    return catcher.get();
  }
  void OnTabStripModelChanged(TabStripModel*,
                              const TabStripModelChange& change,
                              const TabStripSelectionChange&) override {
    if (change.type() != TabStripModelChange::kInserted) {
      return;
    }
    for (const auto& item : change.GetInsert()->contents) {
      if (!item.contents->GetUserData(views::OpenArchHostedPageKey())) {
        new ChromeTabWatcher(item.contents);  // deletes itself
      }
    }
  }
};

// Forgets a hidden Chrome window once Chrome closes it (its last tab closed).
class BrowserCloseObserver : public BrowserCollectionObserver {
 public:
  static void Ensure() {
    static BrowserCloseObserver* observer = nullptr;
    if (!observer) {
      observer = new BrowserCloseObserver();
      observer->observation_.Observe(GlobalBrowserCollection::GetInstance());
    }
  }
  void OnBrowserClosed(BrowserWindowInterface* browser) override {
    for (auto it = HiddenBrowsers().begin(); it != HiddenBrowsers().end(); ++it) {
      if (it->second == browser) {
        HiddenBrowsers().erase(it);
        return;
      }
    }
  }

 private:
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver> observation_{this};
};

NSMapTable<NSWindow*, NSHashTable<OACPane*>*>* g_panes_by_window = nil;
// The pane of each WebContents OpenArch shows (weak).
NSMapTable<NSValue*, OACPane*>* g_panes_by_contents = nil;

OACPane* PaneForContents(content::WebContents* contents) {
  if (!contents || !g_panes_by_contents) {
    return nil;
  }
  return [g_panes_by_contents objectForKey:[NSValue valueWithPointer:contents]];
}

void RegisterContents(content::WebContents* contents, OACPane* pane) {
  if (!g_panes_by_contents) {
    g_panes_by_contents = [NSMapTable strongToWeakObjectsMapTable];
  }
  NSValue* key = [NSValue valueWithPointer:contents];
  if (pane) {
    [g_panes_by_contents setObject:pane forKey:key];
  } else {
    [g_panes_by_contents removeObjectForKey:key];
  }
}

// Schemes Chromium loads itself; anything else is another app's (mailto:,
// zoommtg:, ...), which OpenArch hands to macOS.
bool IsWebScheme(const GURL& url) {
  static const char* const kSchemes[] = {
      "http", "https", "file", "data", "about", "blob", "javascript", "chrome",
      "chrome-extension", "chrome-untrusted", "devtools", "view-source", "filesystem",
      "ws", "wss", "chrome-error"};
  for (const char* scheme : kSchemes) {
    if (url.SchemeIs(scheme)) {
      return true;
    }
  }
  return false;
}
OACDevToolsDock g_devtools_dock = OACDevToolsDockRight;
void (^g_devtools_dock_handler)(OACDevToolsDock) = nil;
void (^g_external_tab_handler)(NSString*) = nil;
void (^g_about_page_handler)(void) = nil;
NSString* g_ask_about_selection_title = nil;
void (^g_download_handler)(OACDownload*) = nil;
void (^g_extensions_changed_handler)(void) = nil;
void (^g_render_process_gone_handler)(NSString*, int) = nil;

// Forwards a WebContents' events to its pane.
class PaneObserver : public content::WebContentsObserver,
                     public favicon::FaviconDriverObserver {
 public:
  PaneObserver(content::WebContents* contents, OACPane* pane)
      : content::WebContentsObserver(contents), pane_(pane) {
    favicons_ = favicon::ContentFaviconDriver::FromWebContents(contents);
    if (favicons_) {
      favicons_->AddObserver(this);
    }
  }
  ~PaneObserver() override {
    if (favicons_) {
      favicons_->RemoveObserver(this);
    }
  }

  // Chrome's tab helpers are attached when the tab joins a tab strip.
  void WatchFaviconsIfNeeded() {
    if (!favicons_ && web_contents()) {
      favicons_ = favicon::ContentFaviconDriver::FromWebContents(web_contents());
      if (favicons_) {
        favicons_->AddObserver(this);
      }
    }
  }

  // A renderer that ended unexpectedly, to OACPane.renderProcessGoneHandler.
  // Ones killed on purpose (closing, discarding) don't count.
  // However the page left full screen, its own window goes too.
  void DidToggleFullscreenModeForTab(bool entered, bool) override {
    if (!entered) {
      [pane_ exitPageFullScreen];
    }
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus status) override {
    const char* name = nullptr;
    switch (status) {
      case base::TERMINATION_STATUS_PROCESS_CRASHED:
        name = "crashed";
        break;
      case base::TERMINATION_STATUS_OOM:
        name = "oom";
        break;
      case base::TERMINATION_STATUS_ABNORMAL_TERMINATION:
        name = "abnormal";
        break;
      case base::TERMINATION_STATUS_LAUNCH_FAILED:
        name = "launch-failed";
        break;
      default:
        return;
    }
    if (g_render_process_gone_handler) {
      g_render_process_gone_handler(@(name), web_contents()->GetCrashedErrorCode());
    }
  }

  void OnDidAddMessageToConsole(content::RenderFrameHost* frame,
                                blink::mojom::ConsoleMessageLevel level,
                                const std::u16string& message,
                                int32_t line,
                                const std::u16string& source,
                                const std::optional<std::u16string>&) override {
    [pane_ consoleMessage:openarch::ToNSString(message)
                   source:openarch::ToNSString(source)
                     line:line];
  }

  void OnFaviconUpdated(favicon::FaviconDriver*,
                        NotificationIconType type,
                        const GURL&,
                        bool,
                        const gfx::Image& image) override {
    if (type == NON_TOUCH_16_DIP && !image.IsEmpty()) {
      [pane_ faviconChanged:image.ToNSImage()];
    }
  }

  void TitleWasSet(content::NavigationEntry* entry) override { [pane_ titleChanged]; }
  void PrimaryPageChanged(content::Page& page) override { [pane_ addressChanged]; }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) {
      [pane_ addressChanged];
      [pane_ loadingChanged];
    }
  }
  void DidStartLoading() override { [pane_ loadingChanged]; }
  void DidStopLoading() override { [pane_ loadingChanged]; }
  void LoadProgressChanged(double progress) override { [pane_ progressChanged:progress]; }
  void DidChangeThemeColor() override { [pane_ pageColorChanged]; }
  void OnBackgroundColorChanged() override { [pane_ pageColorChanged]; }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame() && !handle->IsSameDocument()) {
      [pane_ mainFrameLoad:YES url:handle->GetURL()];
    }
  }
  void DidFinishLoad(content::RenderFrameHost* frame, const GURL& url) override {
    if (frame->IsInPrimaryMainFrame()) {
      [pane_ mainFrameLoad:NO url:url];
    }
  }
  void OnWebContentsFocused(content::RenderWidgetHost*) override { [pane_ gotFocus]; }
  void WebContentsDestroyed() override {
    if (favicons_) {
      favicons_->RemoveObserver(this);
      favicons_ = nullptr;
    }
    [pane_ webContentsDestroyed];
  }

 private:
  __weak OACPane* pane_;
  raw_ptr<favicon::ContentFaviconDriver> favicons_ = nullptr;
};

// The docked DevTools frontend of a pane: tells the pane when it goes.
class FrontendObserver : public content::WebContentsObserver {
 public:
  FrontendObserver(content::WebContents* frontend, OACPane* pane)
      : content::WebContentsObserver(frontend), pane_(pane) {}
  void WebContentsDestroyed() override { [pane_ devToolsClosed]; }

 private:
  __weak OACPane* pane_;
};

// Links the user clicks in OpenArch's pages: ones OpenArch shows elsewhere
// (Peek) and ones to other apps, cancelled before they start.
class PaneNavigationThrottle : public content::NavigationThrottle {
 public:
  explicit PaneNavigationThrottle(content::NavigationThrottleRegistry& registry)
      : content::NavigationThrottle(registry) {}

  ThrottleCheckResult WillStartRequest() override { return Check(); }
  ThrottleCheckResult WillRedirectRequest() override { return Check(); }
  const char* GetNameForLogging() override { return "OpenArchPaneNavigationThrottle"; }

 private:
  ThrottleCheckResult Check() {
    content::NavigationHandle* handle = navigation_handle();
    if (!handle->IsInPrimaryMainFrame()) {
      return PROCEED;
    }
    OACPane* pane = PaneForContents(handle->GetWebContents());
    if (!pane) {
      return PROCEED;
    }
    const GURL& url = handle->GetURL();
    if (!IsWebScheme(url)) {
      [pane wantsExternalURL:url];
      return CANCEL_AND_IGNORE;
    }
    // A page OpenArch shows in WebKit (a streaming service): links,
    // redirects and scripts going there move the tab before the request
    // goes out. Reloads stay.
    if (!ui::PageTransitionCoreTypeIs(handle->GetPageTransition(), ui::PAGE_TRANSITION_RELOAD) &&
        [pane handsOffNavigationToURL:url method:handle->IsPost() ? @"POST" : @"GET"]) {
      return CANCEL_AND_IGNORE;
    }
    bool clicked = handle->IsRendererInitiated() && handle->HasUserGesture() &&
                   ui::PageTransitionCoreTypeIs(handle->GetPageTransition(),
                                                ui::PAGE_TRANSITION_LINK);
    if (clicked && [pane interceptsNavigationToURL:url]) {
      return CANCEL_AND_IGNORE;
    }
    return PROCEED;
  }
};

void AddNavigationThrottle(content::NavigationThrottleRegistry& registry) {
  if (PaneForContents(registry.GetNavigationHandle().GetWebContents())) {
    registry.AddThrottle(std::make_unique<PaneNavigationThrottle>(registry));
  }
}

// Chrome's recording indicator: a page uses the camera or the microphone.
class CaptureWatcher : public MediaStreamCaptureIndicator::Observer {
 public:
  static void Ensure() {
    static base::NoDestructor<CaptureWatcher> watcher;
  }
  CaptureWatcher() {
    indicator_ = MediaCaptureDevicesDispatcher::GetInstance()->GetMediaStreamCaptureIndicator();
    indicator_->AddObserver(this);
  }

  void OnIsCapturingVideoChanged(content::WebContents* contents, bool) override {
    Tell(contents);
  }
  void OnIsCapturingAudioChanged(content::WebContents* contents, bool) override {
    Tell(contents);
  }

 private:
  void Tell(content::WebContents* contents) {
    if (OACPane* pane = PaneForContents(contents)) {
      [pane mediaAccessChangedVideo:indicator_->IsCapturingVideo(contents)
                              audio:indicator_->IsCapturingAudio(contents)];
    }
  }

  scoped_refptr<MediaStreamCaptureIndicator> indicator_;
};

bool TakeNewTab(content::WebContents* source, const GURL& url, WindowOpenDisposition disposition) {
  OACPane* pane = PaneForContents(source);
  return pane && [pane takeNewTabWithURL:url disposition:disposition];
}

// ⌘← (-1) or ⌘→ (1), else 0.
int HistoryArrow(NSEvent* event) {
  NSEventModifierFlags modifiers =
      event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                             NSEventModifierFlagOption | NSEventModifierFlagControl);
  if (modifiers != NSEventModifierFlagCommand || event.charactersIgnoringModifiers.length != 1) {
    return 0;
  }
  switch ([event.charactersIgnoringModifiers characterAtIndex:0]) {
    case NSLeftArrowFunctionKey:
      return -1;
    case NSRightArrowFunctionKey:
      return 1;
    default:
      return 0;
  }
}

// OpenArch's menus get the shortcuts of its pages: ⌘-keys before the page
// (like Chrome's reserved shortcuts), any key the page leaves unhandled.
int HandleKey(content::WebContents* source,
              const input::NativeWebKeyboardEvent& event,
              bool unhandled) {
  OACPane* pane = PaneForContents(source);
  if (!pane) {
    return -1;
  }
  NSEvent* ns_event = event.os_event.Get();
  bool key_down = ns_event && ns_event.type == NSEventTypeKeyDown;
  // ⌘← and ⌘→ go back and forward, as in Safari, unless a text field has
  // the focus: there they move to the start or end of the line. (Not in
  // the menu: Chrome's view would hand them to the menu and never to the
  // page.)
  if (!unhandled && key_down && event.GetType() == blink::WebInputEvent::Type::kRawKeyDown) {
    if (int arrow = HistoryArrow(ns_event)) {
      if (source->IsFocusedElementEditable()) {
        return -1;
      }
      arrow < 0 ? [pane goBack] : [pane goForward];
      return 1;
    }
  }
  if (!unhandled) {
    // Before the page: OpenArch's ⌘-shortcuts, else Chrome's own handling
    // (Esc leaves full screen).
    bool command = key_down && (ns_event.modifierFlags & NSEventModifierFlagCommand);
    return command && [[NSApp mainMenu] performKeyEquivalent:ns_event] ? 1 : -1;
  }
  if (!key_down) {
    return 0;
  }
  return [[NSApp mainMenu] performKeyEquivalent:ns_event] ? 1 : 0;
}

// Every download of a profile, reported to OACPane.downloadHandler.
class DownloadWatcher : public content::DownloadManager::Observer,
                        public download::DownloadItem::Observer {
 public:
  static void Ensure(Profile* profile) {
    static base::NoDestructor<std::map<Profile*, std::unique_ptr<DownloadWatcher>>> watchers;
    if (!watchers->contains(profile) && profile->GetDownloadManager()) {
      (*watchers)[profile] = std::make_unique<DownloadWatcher>(profile->GetDownloadManager());
    }
  }

  explicit DownloadWatcher(content::DownloadManager* manager) : manager_(manager) {
    manager_->AddObserver(this);
  }
  ~DownloadWatcher() override {
    if (manager_) {
      manager_->RemoveObserver(this);
    }
  }

  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem* item) override {
    // Chrome makes an item for every download in the profile's history as
    // it starts; only new ones are OpenArch's business.
    if (item->GetState() != download::DownloadItem::IN_PROGRESS) {
      return;
    }
    item->AddObserver(this);
    Report(item);
  }
  void OnDownloadUpdated(download::DownloadItem* item) override { Report(item); }
  void OnDownloadDestroyed(download::DownloadItem* item) override { item->RemoveObserver(this); }
  void ManagerGoingDown(content::DownloadManager* manager) override {
    manager_->RemoveObserver(this);
    manager_ = nullptr;
  }

 private:
  static void Report(download::DownloadItem* item) {
    if (!g_download_handler) {
      return;
    }
    OACDownload* download = [[OACDownload alloc] init];
    download->_identifier = item->GetId();
    download->_path = openarch::ToNSString(item->GetTargetFilePath().value());
    std::string name = item->GetFileNameToReportUser().AsUTF8Unsafe();
    download->_fileName = name.empty() ? openarch::ToNSString(item->GetURL().ExtractFileName())
                                       : openarch::ToNSString(name);
    download->_percentComplete = item->PercentComplete();
    download->_isComplete = item->GetState() == download::DownloadItem::COMPLETE;
    download->_isFailed = item->GetState() == download::DownloadItem::CANCELLED ||
                          item->GetState() == download::DownloadItem::INTERRUPTED;
    g_download_handler(download);
  }

  raw_ptr<content::DownloadManager> manager_;
};

// A popup (window.open with features: sign-in flows) of a page without a
// Chrome window (private windows): a plain window of its own, keeping its
// opener, gone on window.close() or when its window closes.
class PrivatePopup : public content::WebContentsDelegate {
 public:
  PrivatePopup(std::unique_ptr<content::WebContents> contents, const gfx::Rect& bounds)
      : contents_(std::move(contents)) {
    contents_->SetDelegate(this);
    NSRect frame = NSMakeRect(0, 0, bounds.width() > 0 ? bounds.width() : 500,
                              bounds.height() > 0 ? bounds.height() : 600);
    window_ = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    window_.releasedWhenClosed = NO;
    if (bounds.x() > 0 || bounds.y() > 0) {
      NSRect screen = NSScreen.mainScreen.frame;
      [window_ setFrameTopLeftPoint:NSMakePoint(bounds.x(), NSMaxY(screen) - bounds.y())];
    } else {
      [window_ center];
    }
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    view.frame = window_.contentView.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [window_.contentView addSubview:view];
    view.hidden = NO;
    PrivatePopup* popup = this;
    close_observer_ = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                                        object:window_
                                                                         queue:nil
                                                                    usingBlock:^(NSNotification*) {
                                                                      popup->CloseSoon();
                                                                    }];
    [window_ makeKeyAndOrderFront:nil];
    contents_->WasShown();
    contents_->Focus();
  }

  ~PrivatePopup() override {
    [[NSNotificationCenter defaultCenter] removeObserver:close_observer_];
    contents_.reset();
  }

  void CloseSoon() {
    if (closing_) {
      return;
    }
    closing_ = true;
    [window_ orderOut:nil];
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
  }

  // content::WebContentsDelegate:
  void CloseContents(content::WebContents*) override { CloseSoon(); }
  void NavigationStateChanged(content::WebContents* source, content::InvalidateTypes) override {
    window_.title = openarch::ToNSString(source->GetTitle());
  }

 private:
  std::unique_ptr<content::WebContents> contents_;
  NSWindow* __strong window_;
  id __strong close_observer_;
  bool closing_ = false;
};

// What Chrome's window does for its tabs, for pages without one (private
// windows' own profiles): JavaScript dialogs, file choosers, new tabs and
// keys to OpenArch.
class PrivatePageDelegate : public content::WebContentsDelegate {
 public:
  explicit PrivatePageDelegate(content::WebContents* contents) {
    javascript_dialogs::TabModalDialogManager::CreateForWebContents(
        contents, std::make_unique<JavaScriptTabModalDialogManagerDelegateDesktop>(contents));
  }

  content::JavaScriptDialogManager* GetJavaScriptDialogManager(content::WebContents* source) override {
    return javascript_dialogs::TabModalDialogManager::FromWebContents(source);
  }

  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)> navigation_handle_callback) override {
    if (TakeNewTab(source, params.url, params.disposition)) {
      return nullptr;
    }
    if (params.disposition != WindowOpenDisposition::kCurrentTab) {
      return nullptr;
    }
    content::NavigationController::LoadURLParams load(params);
    base::WeakPtr<content::NavigationHandle> handle = source->GetController().LoadURLWithParams(load);
    if (handle && navigation_handle_callback) {
      std::move(navigation_handle_callback).Run(*handle);
    }
    return source;
  }

  content::WebContents* AddNewContents(content::WebContents* source,
                                       std::unique_ptr<content::WebContents> new_contents,
                                       const GURL& target_url,
                                       WindowOpenDisposition disposition,
                                       const blink::mojom::WindowFeatures& window_features,
                                       bool,
                                       bool*) override {
    if (TakeNewTab(source, target_url, disposition)) {
      return nullptr;
    }
    if (disposition == WindowOpenDisposition::kNewPopup && new_contents) {
      new PrivatePopup(std::move(new_contents), window_features.bounds);  // deletes itself
    }
    return nullptr;
  }

  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      content::WebContents* source,
      const input::NativeWebKeyboardEvent& event) override {
    return HandleKey(source, event, /*unhandled=*/false) == 1
               ? content::KeyboardEventProcessingResult::HANDLED
               : content::KeyboardEventProcessingResult::NOT_HANDLED;
  }

  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override {
    return HandleKey(source, event, /*unhandled=*/true) == 1;
  }

  // File choosers, as Chrome's window runs them (over the pane's window).
  void RunFileChooser(content::RenderFrameHost* render_frame_host,
                      scoped_refptr<content::FileSelectListener> listener,
                      const blink::mojom::FileChooserParams& params) override {
    FileSelectHelper::RunFileChooser(render_frame_host, std::move(listener), params);
  }

  void EnumerateDirectory(content::WebContents* source,
                          scoped_refptr<content::FileSelectListener> listener,
                          const base::FilePath& path) override {
    FileSelectHelper::EnumerateDirectory(source, std::move(listener), path);
  }
};

// The pane's own DevTools protocol client: callDevToolsMethod and
// executeJavaScript (Runtime.evaluate runs in the page's main world).
class DevToolsClient : public content::DevToolsAgentHostClient {
 public:
  using Callback = void (^)(NSDictionary<NSString*, id>*);
  struct Pending {
    std::string method;
    base::DictValue params;
    Callback callback;
    int retries;
  };

  explicit DevToolsClient(content::WebContents* contents) : contents_(contents) {}
  ~DevToolsClient() override {
    if (attached_ && host_) {
      host_->DetachClient(this);
    }
  }

  void Call(const std::string& method, base::DictValue params, Callback callback) {
    // One screenshot at a time: Chrome takes a clipped or scaled one by
    // emulating a smaller viewport and restoring the emulation it found
    // when done. A second one started meanwhile finds the first one's
    // emulation, restores that, and the page stays drawn small.
    if (method == "Page.captureScreenshot") {
      queued_screenshots_.push_back(Pending{method, std::move(params),
                                            callback ? [callback copy] : nil, /*retries=*/1});
      if (!screenshot_in_flight_) {
        NextScreenshot();
      }
      return;
    }
    Send(method, std::move(params), callback ? [callback copy] : nil, /*retries=*/1);
  }

  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t> message) override {
    std::string_view text(reinterpret_cast<const char*>(message.data()), message.size());
    std::optional<base::Value> value = base::JSONReader::Read(text, base::JSON_PARSE_RFC);
    if (!value || !value->is_dict()) {
      return;
    }
    std::optional<int> id = value->GetDict().FindInt("id");
    if (!id) {
      return;  // an event
    }
    if (const base::DictValue* error = value->GetDict().FindDict("error")) {
      LOG(ERROR) << "[openarch] DevTools call " << *id << " failed: " << *error;
    }
    auto it = pending_.find(*id);
    if (it == pending_.end()) {
      return;
    }
    Pending call = std::move(it->second);
    pending_.erase(it);
    const base::DictValue* result = value->GetDict().FindDict("result");
    if (call.callback) {
      call.callback(result ? ToNSDictionary(*result) : nil);
    }
  }

  // Chrome let go of the page's DevTools session (the page changed process,
  // its frames were rebuilt): calls still waiting go once more on a new one.
  void AgentHostClosed(content::DevToolsAgentHost*) override {
    if (getenv("OPENARCH_DEBUG_PAGES")) {
      LOG(ERROR) << "[openarch] DevTools session closed, " << pending_.size() << " calls waiting";
    }
    attached_ = false;
    host_ = nullptr;
    auto pending = std::make_shared<std::map<int, Pending>>(std::move(pending_));
    pending_.clear();
    // Not while Chrome is still closing the session.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&DevToolsClient::Retry, weak_factory_.GetWeakPtr(), pending));
  }

  void Retry(std::shared_ptr<std::map<int, Pending>> pending) {
    for (auto& [id, call] : *pending) {
      if (call.retries > 0) {
        Send(call.method, std::move(call.params), call.callback, call.retries - 1);
      } else if (call.callback) {
        call.callback(nil);
      }
    }
  }

 private:

  void NextScreenshot() {
    if (queued_screenshots_.empty()) {
      screenshot_in_flight_ = false;
      return;
    }
    screenshot_in_flight_ = true;
    Pending call = std::move(queued_screenshots_.front());
    queued_screenshots_.pop_front();
    Callback done = call.callback;
    base::WeakPtr<DevToolsClient> weak = weak_factory_.GetWeakPtr();
    int turn = ++screenshot_turn_;
    Callback next = ^(NSDictionary<NSString*, id>* result) {
      if (done) {
        done(result);
      }
      // After the restore Chrome does on answering.
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&DevToolsClient::ScreenshotDone, weak, turn));
    };
    // One that never answers doesn't hold up the others for good.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&DevToolsClient::ScreenshotDone, weak, turn), base::Seconds(10));
    Send(call.method, std::move(call.params), [next copy], call.retries);
  }

  void ScreenshotDone(int turn) {
    if (turn == screenshot_turn_ && screenshot_in_flight_) {
      NextScreenshot();
    }
  }

  void Send(const std::string& method, base::DictValue params, Callback callback, int retries) {
    if (!attached_) {
      host_ = contents_ ? content::DevToolsAgentHost::GetOrCreateFor(contents_) : nullptr;
      attached_ = host_ && host_->AttachClient(this);
      if (!attached_) {
        LOG(ERROR) << "[openarch] DevTools client could not attach";
        if (callback) {
          callback(nil);
        }
        return;
      }
    }
    int id = ++last_id_;
    base::DictValue message;
    message.Set("id", id);
    message.Set("method", method);
    message.Set("params", params.Clone());
    pending_[id] = Pending{method, std::move(params), callback, retries};
    std::string json = base::WriteJson(message).value_or("{}");
    host_->DispatchProtocolMessage(this, base::as_byte_span(json));
  }

  static NSDictionary<NSString*, id>* ToNSDictionary(const base::DictValue& dict) {
    std::string json = base::WriteJson(dict).value_or("{}");
    NSData* data = [NSData dataWithBytes:json.data() length:json.size()];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
  }

  raw_ptr<content::WebContents> contents_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  bool attached_ = false;
  int last_id_ = 0;
  std::map<int, Pending> pending_;
  std::deque<Pending> queued_screenshots_;  // waiting for the one in flight
  bool screenshot_in_flight_ = false;
  int screenshot_turn_ = 0;  // the screenshot in flight
  base::WeakPtrFactory<DevToolsClient> weak_factory_{this};
};

std::optional<base::DictValue> ToDict(NSDictionary* dictionary) {
  if (!dictionary.count) {
    return base::DictValue();
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:nil];
  if (!data) {
    return std::nullopt;
  }
  std::optional<base::Value> value = base::JSONReader::Read(
      std::string_view(static_cast<const char*>(data.bytes), data.length), base::JSON_PARSE_RFC);
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  return std::move(value->GetDict());
}

}  // namespace

namespace openarch {

OACPane* PaneForWebContents(content::WebContents* contents) {
  return PaneForContents(contents);
}

void AdoptDockedDevTools(BrowserWindowInterface* browser) {
  TabStripModel* tabs = browser ? browser->GetTabStripModel() : nullptr;
  for (int i = 0; tabs && i < tabs->count(); i++) {
    [PaneForContents(tabs->GetWebContentsAt(i)) adoptDevTools];
  }
}

bool EnterPageFullScreen(content::WebContents* contents) {
  OACPane* pane = contents ? PaneForContents(contents) : nil;
  if (!pane) {
    return false;
  }
  [pane enterPageFullScreen];
  return true;
}

void ExitPageFullScreen(content::WebContents* contents) {
  [(contents ? PaneForContents(contents) : nil) exitPageFullScreen];
}

bool IsPageFullScreen(content::WebContents* contents) {
  return contents && [PaneForContents(contents) pageFullScreen];
}

// "Ask about selection" (OACPane.askAboutSelectionTitle) atop the menu of
// selected text.
void AddMenuItems(content::WebContents* contents,
                  const content::ContextMenuParams& params,
                  ui::SimpleMenuModel* menu) {
  OACPane* pane = PaneForContents(contents);
  if (!pane || !pane.offersAskAboutSelection || !g_ask_about_selection_title.length ||
      params.selection_text.empty() || !pane.delegate ||
      ![pane.delegate respondsToSelector:@selector(pane:askAboutSelection:)]) {
    return;
  }
  menu->InsertItemAt(0, kFirstMenuCommand, base::SysNSStringToUTF16(g_ask_about_selection_title));
  menu->InsertSeparatorAt(1, ui::NORMAL_SEPARATOR);
}

void RunMenuCommand(content::WebContents* contents, const content::ContextMenuParams& params, int command) {
  OACPane* pane = PaneForContents(contents);
  if (command == kFirstMenuCommand && pane &&
      [pane.delegate respondsToSelector:@selector(pane:askAboutSelection:)]) {
    [pane.delegate pane:pane askAboutSelection:openarch::ToNSString(params.selection_text)];
  }
}

BrowserWindow* MakeWindowForBrowser(BrowserWindowInterface* browser);

// The DevTools frontend docked beside a page asks for a new layout (its
// splitter was dragged): the pane places the page where it asks.
bool LayOutDevTools(content::WebContents* inspected) {
  OACPane* pane = PaneForContents(inspected);
  if (!pane) {
    return false;
  }
  [pane layoutViews];
  return true;
}

void InstallPaneHooks() {
  g_devtools_layout_hook = &LayOutDevTools;
  g_context_menu_hook = &AddMenuItems;
  g_context_menu_command_hook = &RunMenuCommand;
  g_new_tab_hook = &TakeNewTab;
  g_key_hook = &HandleKey;
  g_navigation_throttle_hook = &AddNavigationThrottle;
  g_browser_window_hook = &MakeWindowForBrowser;
  CaptureWatcher::Ensure();
}

// Set while OpenArch makes the Browser that holds a profile's pages: its
// window is OpenArch's own (page_window.mm), never a Chrome window.
bool g_making_page_browser = false;

BrowserWindow* MakeWindowForBrowser(BrowserWindowInterface* browser) {
  return g_making_page_browser ? MakePageWindow(browser) : nullptr;
}

BrowserWindowInterface* HiddenBrowserForProfile(Profile* profile) {
  BrowserCloseObserver::Ensure();
  auto it = HiddenBrowsers().find(profile);
  if (it != HiddenBrowsers().end()) {
    return it->second;
  }
  // Private profiles of their own (one per private window) can't have a
  // Chrome browser; their pages live without one.
  if (GetBrowserWindowCreationStatusForProfile(*profile) !=
      BrowserWindowInterface::CreationStatus::kOk) {
    return nullptr;
  }
  // A normal browser whose tab strip holds the pages; its window is
  // OpenArch's (no native window), see page_window.h.
  BrowserWindowCreateParams params(profile, /*from_user_gesture=*/false);
  params.initial_show_state = ui::mojom::WindowShowState::kInactive;
  g_making_page_browser = true;
  BrowserWindowInterface* browser = CreateBrowserWindow(std::move(params));
  g_making_page_browser = false;
  browser->GetTabStripModel()->AddObserver(ChromeTabCatcher::Get());
  HiddenBrowsers()[profile] = browser;
  return browser;
}

// The OpenArch window a Browser's pages are shown in: the key window's
// page first, then any page on screen, then OpenArch's main window.
NSWindow* HostWindowForBrowser(BrowserWindowInterface* browser) {
  NSWindow* any = nil;
  if (browser) {
    TabStripModel* tabs = browser->GetTabStripModel();
    for (int i = 0; i < tabs->count(); ++i) {
      NSWindow* window = PaneForContents(tabs->GetWebContentsAt(i)).window;
      if (!window) {
        continue;
      }
      if (window.isKeyWindow || window == NSApp.keyWindow.parentWindow) {
        return window;
      }
      any = any ?: window;
    }
  }
  return any ?: (NSApp.mainWindow ?: NSApp.keyWindow);
}

// The page of |browser| the user is in: the one on screen in the key
// window, else Chrome's active tab.
content::WebContents* FocusedContentsForBrowser(BrowserWindowInterface* browser) {
  TabStripModel* tabs = browser->GetTabStripModel();
  for (int i = 0; i < tabs->count(); ++i) {
    content::WebContents* contents = tabs->GetWebContentsAt(i);
    NSWindow* window = PaneForContents(contents).window;
    if (window && window.isKeyWindow) {
      NSView* view = contents->GetNativeView().GetNativeNSView();
      NSResponder* responder = window.firstResponder;
      if ([responder isKindOfClass:[NSView class]] && [(NSView*)responder isDescendantOf:view]) {
        return contents;
      }
    }
  }
  return tabs->GetActiveWebContents();
}

}  // namespace openarch

@implementation OACDownload
- (instancetype)initWithIdentifier:(uint32_t)identifier
                          fileName:(NSString*)fileName
                              path:(NSString*)path
                   percentComplete:(NSInteger)percentComplete
                        isComplete:(BOOL)isComplete
                          isFailed:(BOOL)isFailed {
  if ((self = [super init])) {
    _identifier = identifier;
    _fileName = [fileName copy];
    _path = [path copy];
    _percentComplete = percentComplete;
    _isComplete = isComplete;
    _isFailed = isFailed;
  }
  return self;
}
+ (void)report:(OACDownload*)download {
  if (g_download_handler) {
    g_download_handler(download);
  }
}
- (uint32_t)identifier {
  return _identifier;
}
- (NSString*)fileName {
  return _fileName;
}
- (NSString*)path {
  return _path;
}
- (NSInteger)percentComplete {
  return _percentComplete;
}
- (BOOL)isComplete {
  return _isComplete;
}
- (BOOL)isFailed {
  return _isFailed;
}
@end

@implementation OACPane {
  OACProfile* _profile;
  NSString* _initialURL;
  raw_ptr<content::WebContents> _contents;  // owned by the hidden window's tab strip...
  std::unique_ptr<content::WebContents> _ownedContents;  // ...or by the pane (private pages)
  std::unique_ptr<PrivatePageDelegate> _privateDelegate;
  int _captures;  // screenshots in flight while hidden
  OAFindBar* _findBar;  // find in page, once used
  OAExtensionToolbar* _toolbar;  // the extension toolbar, while toolbarVisible
  std::unique_ptr<PrefChangeRegistrar> _devToolsPrefs;  // DevTools' own dock menu
  OASidePanel* _sidePanel;  // an extension's side panel, right of the page
  raw_ptr<content::WebContents> _devToolsFrontend;  // docked beside the page
  std::unique_ptr<FrontendObserver> _frontendObserver;
  std::unique_ptr<PaneObserver> _observer;
  std::unique_ptr<DevToolsClient> _devTools;
  __weak NSWindow* _hostWindow;
  NSRect _frame;
  BOOL _visible;
  BOOL _closing;
  BOOL _toolbarVisible;
  BOOL _activatesOnShow;
  CGFloat _cornerRadius;
  BOOL _offersAskAboutSelection;
  BOOL _refusesToCloseForTesting;
  NSWindow* _fullScreenWindow;  // the page's own window while it is full screen
  id _fullScreenEnterObserver;
  id _fullScreenExitObserver;
  NSImage* _favicon;
}

@synthesize delegate = _delegate;

- (instancetype)initWithProfile:(OACProfile*)profile url:(NSString*)url {
  if ((self = [super init])) {
    _profile = profile;
    _initialURL = [url copy];
    _activatesOnShow = YES;
    _offersAskAboutSelection = YES;
    // Diagnostics: the toolbar on every pane (OPENARCH_SHOW_TOOLBAR=1).
    _toolbarVisible = getenv("OPENARCH_SHOW_TOOLBAR") != nullptr;
  }
  return self;
}

- (void)dealloc {
  [self leavePageFullScreenWindowNotifying:NO];
  [self detachView];
  _observer.reset();
  _devTools.reset();
  if (_contents) {
    RegisterContents(_contents, nil);
  }
  _ownedContents.reset();
}

#pragma mark Properties

- (OACProfile*)profile {
  return _profile;
}

- (NSString*)url {
  if (!_contents) {
    return _initialURL ?: @"";
  }
  return openarch::ToNSString(_contents->GetVisibleURL().spec());
}

- (NSString*)title {
  return _contents ? openarch::ToNSString(_contents->GetTitle()) : @"";
}

- (NSImage*)favicon {
  return _favicon;
}

- (BOOL)isLoading {
  return _contents && _contents->IsLoading();
}

- (BOOL)canGoBack {
  return _contents && _contents->GetController().CanGoBack();
}

- (BOOL)canGoForward {
  return _contents && _contents->GetController().CanGoForward();
}

- (BOOL)isLoaded {
  return _contents != nullptr;
}

- (OACPageEngine)engine {
  return OACPageEngineChromium;
}

- (BOOL)isFullScreen {
  return _contents && _contents->IsFullscreen();
}

// Whether the page has a beforeunload handler, which closing it to sleep
// would skip. YES when it cannot tell.
- (void)checkAsksBeforeLeaving:(void (^)(BOOL asks))completion {
  NSString* group = @"openarch-sleep";
  [self callDevToolsMethod:@"Runtime.evaluate"
                    params:@{@"expression" : @"window", @"objectGroup" : group}
                completion:^(NSDictionary<NSString*, id>* result) {
                  NSDictionary* object = result[@"result"];
                  NSString* objectID =
                      [object isKindOfClass:NSDictionary.class] ? object[@"objectId"] : nil;
                  if (![objectID isKindOfClass:NSString.class]) {
                    completion(YES);
                    return;
                  }
                  [self callDevToolsMethod:@"DOMDebugger.getEventListeners"
                                    params:@{@"objectId" : objectID}
                                completion:^(NSDictionary<NSString*, id>* listeners) {
                                  [self callDevToolsMethod:@"Runtime.releaseObjectGroup"
                                                    params:@{@"objectGroup" : group}
                                                completion:nil];
                                  NSArray* list = listeners[@"listeners"];
                                  if (![list isKindOfClass:NSArray.class]) {
                                    completion(YES);
                                    return;
                                  }
                                  for (NSDictionary* listener in list) {
                                    if ([listener isKindOfClass:NSDictionary.class] &&
                                        [listener[@"type"] isEqual:@"beforeunload"]) {
                                      completion(YES);
                                      return;
                                    }
                                  }
                                  completion(NO);
                                }];
                }];
}

- (BOOL)isVisible {
  return _visible;
}

- (NSWindow*)window {
  // No window of its own: the window it is shown in.
  return _visible ? _hostWindow : nil;
}

- (NSRect)screenFrame {
  NSView* view = [self contentsView];
  if (!_visible || !view.window) {
    return NSZeroRect;
  }
  NSRect frame = [view convertRect:view.bounds toView:nil];
  // The pane's toolbar is part of the pane.
  if (_toolbarVisible && _toolbar.superview == view.superview) {
    frame = NSUnionRect(frame, [_toolbar convertRect:_toolbar.bounds toView:nil]);
  }
  return [view.window convertRectToScreen:frame];
}

+ (BOOL)panesHaveWindows {
  return NO;
}

- (BOOL)toolbarVisible {
  return _toolbarVisible;
}

- (void)setToolbarVisible:(BOOL)toolbarVisible {
  // Chrome's toolbar lives in Chrome's (hidden) window: OpenArch's own
  // extension toolbar (toolbar.mm) sits above the page instead.
  _toolbarVisible = toolbarVisible || getenv("OPENARCH_SHOW_TOOLBAR") != nullptr;
  if (!toolbarVisible) {
    [_toolbar removeFromSuperview];
  }
  [self layoutViews];
}

- (BOOL)activatesOnShow {
  return _activatesOnShow;
}

- (void)setActivatesOnShow:(BOOL)activatesOnShow {
  _activatesOnShow = activatesOnShow;
}

- (CGFloat)cornerRadius {
  return _cornerRadius;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
  _cornerRadius = cornerRadius;
  [self applyCornerRadius];
}

- (BOOL)offersAskAboutSelection {
  return _offersAskAboutSelection;
}

- (void)setOffersAskAboutSelection:(BOOL)offers {
  _offersAskAboutSelection = offers;
}

- (BOOL)refusesToCloseForTesting {
  return _refusesToCloseForTesting;
}

- (void)setRefusesToCloseForTesting:(BOOL)refuses {
  _refusesToCloseForTesting = refuses;
}

- (NSInteger)zoomPercent {
  if (!_contents) {
    return 100;
  }
  zoom::ZoomController* zoom = zoom::ZoomController::FromWebContents(_contents);
  return zoom ? zoom->GetZoomPercent() : 100;
}

#pragma mark Creating the tab

- (void)load {
  [self createContents];
}

- (void)createContents {
  if (_contents || _closing) {
    return;
  }
  __weak OACPane* weakSelf = self;
  [_profile withChromeProfile:^(Profile* profile) {
    [weakSelf createContentsInProfile:profile];
  }];
}

- (void)createContentsInProfile:(Profile*)profile {
  if (getenv("OPENARCH_DEBUG_PAGES")) {
    LOG(ERROR) << "[openarch] create " << openarch::ToStdString(_initialURL) << " profile " << (profile != nullptr)
               << " exists " << (_contents != nullptr) << " closing " << _closing;
  }
  if (_contents || _closing || !profile) {
    return;
  }
  BrowserWindowInterface* browser = openarch::HiddenBrowserForProfile(profile);
  DownloadWatcher::Ensure(profile);
  content::WebContents::CreateParams params(profile);
  params.initially_hidden = !_visible;
  std::unique_ptr<content::WebContents> contents = content::WebContents::Create(params);
  // Chrome's window never attaches this page's view (openarch_hosted_page.h).
  contents->SetUserData(views::OpenArchHostedPageKey(),
                        std::make_unique<base::SupportsUserData::Data>());
  _contents = contents.get();
  RegisterContents(_contents, self);
  _observer = std::make_unique<PaneObserver>(_contents, self);
  if (browser) {
    browser->GetTabStripModel()->AppendWebContents(std::move(contents), /*foreground=*/false);
    _observer->WatchFaviconsIfNeeded();
  } else {
    _ownedContents = std::move(contents);
    _privateDelegate = std::make_unique<PrivatePageDelegate>(_contents);
    _contents->SetDelegate(_privateDelegate.get());
  }
  // Its dialogs show over OpenArch's window, not Chrome's hidden one (after
  // the tab joined the tab strip, which makes Chrome's window their host).
  openarch::HostDialogsInPane(_contents, self);
  // A page loaded in the background gets the size it will be shown at (as a
  // background tab in Chrome gets its window's), so it lays out, and
  // pictures of it (the tab switcher) have something to show.
  NSSize size = !NSIsEmptyRect(_frame) ? _frame.size
                : (NSApp.mainWindow.contentView ? NSApp.mainWindow.contentView.bounds.size
                                                : NSMakeSize(1200, 800));
  [self contentsView].frame = NSMakeRect(0, 0, size.width, size.height);
  _contents->Resize(gfx::Rect(0, 0, size.width, size.height));
  if (_initialURL.length) {
    [self loadURL:_initialURL];
  }
  if (_visible && _hostWindow) {
    [self attachViewToWindow:_hostWindow];
    [self makeActiveTab];
  }
}

- (BrowserWindowInterface*)browser {
  if (!_contents) {
    return nullptr;
  }
  for (BrowserWindowInterface* browser : GetAllBrowserWindowInterfaces()) {
    if (browser->GetTabStripModel()->GetIndexOfWebContents(_contents) != TabStripModel::kNoTab) {
      return browser;
    }
  }
  return nullptr;
}

// Chrome's tab strip learns which page is in front: extensions ask it for
// the active tab (chrome.tabs.query({active: true}), a password manager's
// popup, activeTab), and Chrome's commands act on it.
- (void)makeActiveTab {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return;
  }
  TabStripModel* tabs = browser->GetTabStripModel();
  int index = tabs->GetIndexOfWebContents(_contents);
  if (index != TabStripModel::kNoTab && tabs->active_index() != index) {
    tabs->ActivateTabAt(index);
  }
}

#pragma mark Showing

- (NSView*)contentsView {
  return _contents ? _contents->GetNativeView().GetNativeNSView() : nil;
}

- (void)showInWindow:(NSWindow*)window frame:(NSRect)frame {
  if (_hostWindow && _hostWindow != window) {
    [self detachView];
  }
  _hostWindow = window;
  _frame = frame;
  _visible = YES;
  if (!g_panes_by_window) {
    g_panes_by_window = [NSMapTable weakToStrongObjectsMapTable];
  }
  NSHashTable<OACPane*>* panes = [g_panes_by_window objectForKey:window];
  if (!panes) {
    panes = [NSHashTable weakObjectsHashTable];
    [g_panes_by_window setObject:panes forKey:window];
  }
  [panes addObject:self];
  if (!_contents) {
    [self createContents];
    return;  // attached once the tab exists
  }
  [self attachViewToWindow:window];
  [self makeActiveTab];
  if (_activatesOnShow) {
    [NSApp activateIgnoringOtherApps:YES];
  }
}

- (void)attachViewToWindow:(NSWindow*)window {
  if (_fullScreenWindow) {
    return;  // back in place when full screen ends
  }
  NSView* view = [self contentsView];
  NSView* content = window.contentView;
  if (!view || !content) {
    return;
  }
  view.autoresizingMask = NSViewNotSizable;
  // On top, also when it was lent underneath for a picture.
  [view removeFromSuperview];
  [content addSubview:view positioned:NSWindowAbove relativeTo:nil];
  // A WebContents made hidden starts with its NSView hidden; in Chrome the
  // Views host unhides it (WebContentsViewMac::ViewsHostableSetVisible).
  view.hidden = NO;
  [self applyCornerRadius];
  _contents->WasShown();
  [self layoutViews];
}

- (void)applyCornerRadius {
  NSView* view = [self contentsView];
  if (!view || _fullScreenWindow) {
    return;
  }
  view.wantsLayer = YES;
  view.layer.cornerRadius = _cornerRadius;
  view.layer.cornerCurve = kCACornerCurveContinuous;
  view.layer.masksToBounds = _cornerRadius > 0;
  // Under the toolbar only the bottom corners are round: bar and page are
  // one card (the page's view isn't flipped: its bottom is min y).
  BOOL bar = _toolbarVisible && _toolbar.superview;
  view.layer.maskedCorners = bar ? (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner)
                                 : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                    kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
  _toolbar.cornerRadius = _cornerRadius;
}

- (void)setFrame:(NSRect)frame {
  _frame = frame;
  [self layoutViews];
}

// The page, and DevTools docked beside it on the side OACPane.devToolsDock
// says, over the pane's frame.
- (void)layoutViews {
  NSView* view = [self contentsView];
  NSView* content = view.superview;
  if (!_visible || !content || _fullScreenWindow) {
    return;
  }
  NSRect frame = [content convertRect:_frame fromView:nil];
  if (_toolbarVisible) {
    if (!_toolbar) {
      __weak OACPane* weakSelf = self;
      _toolbar = [[OAExtensionToolbar alloc] initWithWebContents:_contents
                                                         browser:[self browser]
                                                         openURL:^(NSString* url) {
                                                           [weakSelf openInNewTab:url];
                                                         }];
      _toolbar.sidePanelHandler = ^(OASidePanel* panel) {
        [weakSelf toggleSidePanel:panel];
      };
      _toolbar.siteControlsHandler = [self siteControlsHandler];
      _toolbar.historyTabHandler = ^(NSInteger offset, BOOL background) {
        [weakSelf openHistoryEntryInNewTab:offset background:background];
      };
    }
    CGFloat height = OAExtensionToolbar.height;
    NSRect bar = content.isFlipped
                     ? NSMakeRect(NSMinX(frame), NSMinY(frame), NSWidth(frame), height)
                     : NSMakeRect(NSMinX(frame), NSMaxY(frame) - height, NSWidth(frame), height);
    if (_toolbar.superview != content) {
      [_toolbar removeFromSuperview];
      [content addSubview:_toolbar positioned:NSWindowAbove relativeTo:view];
    }
    _toolbar.frame = bar;
    _toolbar.cornerRadius = _cornerRadius;
    frame.size.height -= height;
    if (content.isFlipped) {
      frame.origin.y += height;
    }
  }
  // An extension's side panel takes the right of the frame.
  if (_sidePanel) {
    CGFloat width = MIN(360, floor(NSWidth(frame) / 2));
    NSView* panelView = _sidePanel.view;
    if (panelView.superview != content) {
      [panelView removeFromSuperview];
      [content addSubview:panelView positioned:NSWindowAbove relativeTo:view];
    }
    panelView.frame = NSMakeRect(NSMaxX(frame) - width, NSMinY(frame), width, NSHeight(frame));
    panelView.hidden = NO;
    [_sidePanel wasShown];
    frame.size.width -= width;
  }
  NSRect page = frame;
  NSRect tools = NSZeroRect;
  DevToolsContentsResizingStrategy strategy;
  if (_devToolsFrontend &&
      DevToolsWindow::GetInTabWebContents(_contents, &strategy) != _devToolsFrontend) {
    // Closing (Chrome lays out once more while the frontend goes): let go.
    [_devToolsFrontend->GetNativeView().GetNativeNSView() removeFromSuperview];
    _frontendObserver.reset();
    _devToolsFrontend = nullptr;
  }
  if (_devToolsFrontend && g_devtools_dock != OACDevToolsDockWindow) {
    // As in Chrome: the frontend fills the frame and draws its own splitter;
    // the page lies over it at the bounds the frontend asks for (from the
    // frame's top left), which follow the splitter.
    gfx::Rect toolsBounds;
    gfx::Rect pageBounds;
    ApplyDevToolsContentsResizingStrategy(
        strategy, gfx::Rect(0, 0, NSWidth(frame), NSHeight(frame)), &toolsBounds, &pageBounds);
    tools = frame;
    page = NSMakeRect(NSMinX(frame) + pageBounds.x(),
                      content.isFlipped ? NSMinY(frame) + pageBounds.y()
                                        : NSMaxY(frame) - pageBounds.bottom(),
                      pageBounds.width(), pageBounds.height());
  }
  view.frame = page;
  // The toolbar spans the page's column, beside which DevTools dock.
  if (_toolbarVisible && _toolbar.superview == content) {
    NSRect bar = _toolbar.frame;
    _toolbar.frame = NSMakeRect(NSMinX(page), NSMinY(bar), NSWidth(page), NSHeight(bar));
  }
  [self applyCornerRadius];
  if (_findBar.isOpen) {
    [_findBar placeInPageFrame:page];
  }
  NSView* toolsView =
      _devToolsFrontend ? _devToolsFrontend->GetNativeView().GetNativeNSView() : nil;
  if (toolsView) {
    if (NSIsEmptyRect(tools)) {
      toolsView.hidden = YES;
      [toolsView removeFromSuperview];
    } else {
      // Under the page, which covers the frontend's placeholder for it.
      NSArray<NSView*>* views = content.subviews;
      if (toolsView.superview != content ||
          [views indexOfObjectIdenticalTo:toolsView] > [views indexOfObjectIdenticalTo:view]) {
        [toolsView removeFromSuperview];
        [content addSubview:toolsView positioned:NSWindowBelow relativeTo:view];
      }
      toolsView.frame = tools;
      toolsView.hidden = NO;
      _devToolsFrontend->WasShown();
    }
  }
}

- (void)hide {
  if (!_visible) {
    return;
  }
  _visible = NO;
  [[g_panes_by_window objectForKey:_hostWindow] removeObject:self];
  [self detachView];
}

- (void)detachView {
  NSView* view = [self contentsView];
  if (!view || _fullScreenWindow) {
    return;
  }
  if (_contents) {
    _contents->WasHidden();
  }
  view.hidden = YES;
  [view removeFromSuperview];
  [_toolbar removeFromSuperview];
  [_sidePanel.view removeFromSuperview];
  if (_findBar.isOpen) {
    [_findBar close];
  }
  if (_devToolsFrontend) {
    NSView* toolsView = _devToolsFrontend->GetNativeView().GetNativeNSView();
    _devToolsFrontend->WasHidden();
    toolsView.hidden = YES;
    [toolsView removeFromSuperview];
  }
}

- (void)focus {
  if (!_contents) {
    return;
  }
  [self makeActiveTab];
  if (_activatesOnShow) {
    [NSApp activateIgnoringOtherApps:YES];
    [_hostWindow makeKeyWindow];
  }
  _contents->Focus();
}

- (void)orderFront {
  NSView* view = [self contentsView];
  NSView* superview = view.superview;
  if (superview) {
    [view removeFromSuperview];
    [superview addSubview:view positioned:NSWindowAbove relativeTo:nil];
  }
}

#pragma mark Page full screen

// A page going full screen (a video's full screen button) gets a window of
// its own on its own full screen space, as in Chrome. Its view goes back to
// the pane when that window leaves full screen, however that happens: the
// page, Esc, the green button.
- (BOOL)pageFullScreen {
  return _fullScreenWindow != nil;
}

- (void)enterPageFullScreen {
  NSView* view = [self contentsView];
  if (_fullScreenWindow || !view) {
    return;
  }
  NSScreen* screen = _hostWindow.screen ?: NSScreen.mainScreen;
  NSWindow* window = [[NSWindow alloc]
      initWithContentRect:screen.frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  window.releasedWhenClosed = NO;
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.backgroundColor = NSColor.blackColor;
  window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
  window.title = self.title ?: @"";

  // The page alone: the extension toolbar, a side panel, the find bar and
  // docked DevTools stay behind.
  [self detachView];
  _fullScreenWindow = window;
  [view removeFromSuperview];
  view.layer.cornerRadius = 0;
  view.layer.masksToBounds = NO;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.frame = window.contentView.bounds;
  view.hidden = NO;
  [window.contentView addSubview:view];
  if (_contents) {
    _contents->WasShown();
  }

  __weak OACPane* weakSelf = self;
  _fullScreenEnterObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidEnterFullScreenNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification*) {
                [weakSelf pageFullScreenChanged];
              }];
  _fullScreenExitObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidExitFullScreenNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification*) {
                [weakSelf leavePageFullScreenWindowNotifying:YES];
              }];
  [window makeKeyAndOrderFront:nil];
  [window toggleFullScreen:nil];
  if (_contents) {
    _contents->Focus();
  }
}

- (void)exitPageFullScreen {
  NSWindow* window = _fullScreenWindow;
  if (!window) {
    return;
  }
  if (window.styleMask & NSWindowStyleMaskFullScreen) {
    [window toggleFullScreen:nil];  // back in place once AppKit is done
  } else {
    [self leavePageFullScreenWindowNotifying:YES];
  }
}

- (void)leavePageFullScreenWindowNotifying:(BOOL)notify {
  NSWindow* window = _fullScreenWindow;
  if (!window) {
    return;
  }
  [NSNotificationCenter.defaultCenter removeObserver:_fullScreenEnterObserver];
  [NSNotificationCenter.defaultCenter removeObserver:_fullScreenExitObserver];
  _fullScreenEnterObserver = nil;
  _fullScreenExitObserver = nil;
  _fullScreenWindow = nil;
  NSView* view = [self contentsView];
  [view removeFromSuperview];
  if (_visible && _hostWindow) {
    [self attachViewToWindow:_hostWindow];
    [_hostWindow makeKeyAndOrderFront:nil];
  } else if (view) {
    view.hidden = YES;
    _contents->WasHidden();
  }
  [window orderOut:nil];
  [window close];
  if (!notify) {
    return;
  }
  // Left by the user (Esc in AppKit's hands, the green button): the page
  // leaves full screen too.
  if (_contents && _contents->IsFullscreen()) {
    _contents->ExitFullscreen(/*will_cause_resize=*/true);
  }
  [self pageFullScreenChanged];
  if (_visible && _contents) {
    _contents->Focus();
  }
}

- (void)pageFullScreenChanged {
  BrowserWindowInterface* browser = [self browser];
  ExclusiveAccessManager* manager = browser ? ExclusiveAccessManager::From(browser) : nullptr;
  if (manager) {
    manager->fullscreen_controller()->WindowFullscreenStateChanged();
  }
}

#pragma mark Navigation

- (void)loadURL:(NSString*)url {
  if (!_contents) {
    _initialURL = [url copy];
    return;
  }
  GURL gurl(openarch::ToStdString(url));
  if (!IsWebScheme(gurl)) {
    [self wantsExternalURL:gurl];
    return;
  }
  // Going to Chrome's About page from a page already open shows OpenArch's
  // own; a tab that starts there keeps it.
  if ([OACPane isAboutPageURL:url] && g_about_page_handler &&
      !_contents->GetController().IsInitialNavigation()) {
    g_about_page_handler();
    return;
  }
  content::NavigationController::LoadURLParams params(gurl);
  params.transition_type = ui::PAGE_TRANSITION_TYPED;
  _contents->GetController().LoadURLWithParams(params);
}

- (void)goBack {
  if (_contents && _contents->GetController().CanGoBack()) {
    _contents->GetController().GoBack();
  }
}

- (void)goForward {
  if (_contents && _contents->GetController().CanGoForward()) {
    _contents->GetController().GoForward();
  }
}

- (nullable NSString*)historyURLAtOffset:(NSInteger)offset {
  if (!_contents || offset == 0) {
    return nil;
  }
  content::NavigationEntry* entry =
      _contents->GetController().GetEntryAtOffset(static_cast<int>(offset));
  return entry ? openarch::ToNSString(entry->GetURL().spec()) : nil;
}

- (nullable NSString*)historyTitleAtOffset:(NSInteger)offset {
  if (!_contents || offset == 0) {
    return nil;
  }
  content::NavigationEntry* entry =
      _contents->GetController().GetEntryAtOffset(static_cast<int>(offset));
  return entry ? base::SysUTF16ToNSString(entry->GetTitleForDisplay()) : nil;
}

- (void)goToHistoryOffset:(NSInteger)offset {
  if (_contents && offset != 0 && _contents->GetController().CanGoToOffset(static_cast<int>(offset))) {
    _contents->GetController().GoToOffset(static_cast<int>(offset));
  }
}

// ⌘-click on the toolbar's Back or Forward: that page in a new tab, in
// the background (⌘⇧ in front), as Chrome does.
- (void)openHistoryEntryInNewTab:(NSInteger)offset background:(BOOL)background {
  NSString* url = [self historyURLAtOffset:offset];
  if (url && [_delegate respondsToSelector:@selector(pane:wantsNewTabWithURL:background:)]) {
    [_delegate pane:self wantsNewTabWithURL:url background:background];
  }
}

- (void)reload {
  if (_contents) {
    _contents->GetController().Reload(content::ReloadType::NORMAL, /*check_for_repost=*/true);
  }
}

- (void)stopLoading {
  if (_contents) {
    _contents->Stop();
  }
}

#pragma mark Scripts and the DevTools protocol

- (void)executeJavaScript:(NSString*)script {
  [self executeJavaScript:script userGesture:NO];
}

- (void)executeJavaScript:(NSString*)script userGesture:(BOOL)userGesture {
  [self callDevToolsMethod:@"Runtime.evaluate"
                    params:@{@"expression" : script, @"userGesture" : @(userGesture)}
                completion:nil];
}

- (void)callDevToolsMethod:(NSString*)method
                    params:(NSDictionary<NSString*, id>*)params
                completion:(void (^)(NSDictionary<NSString*, id>*))completion {
  if (!_contents) {
    if (completion) {
      completion(nil);
    }
    return;
  }
  std::optional<base::DictValue> dict = ToDict(params);
  if (!dict) {
    if (completion) {
      completion(nil);
    }
    return;
  }
  if (!_devTools) {
    _devTools = std::make_unique<DevToolsClient>(_contents);
  }
  // A hidden page draws nothing; while a screenshot of it is taken (the tab
  // switcher's pictures), it draws without being shown, as Chrome's own tab
  // thumbnails do.
  if (!_visible && [method isEqualToString:@"Page.captureScreenshot"]) {
    content::WebContents* contents = _contents;
    auto capture = std::make_shared<base::ScopedClosureRunner>(
        contents->IncrementCapturerCount(gfx::Size(), /*stay_hidden=*/true,
                                         /*stay_awake=*/true, /*is_activity=*/false));
    // Without a window the page has no compositor: put its view in one, under
    // everything there, for the moment of the picture.
    NSWindow* window = _hostWindow ?: NSApp.mainWindow ?: NSApp.keyWindow;
    NSView* view = [self contentsView];
    NSView* content = window.contentView;
    BOOL borrowed = view && content && !view.superview;
    if (borrowed) {
      NSRect frame = NSIsEmptyRect(_frame) ? content.bounds : [content convertRect:_frame fromView:nil];
      view.frame = frame;
      [content addSubview:view positioned:NSWindowBelow relativeTo:nil];
      view.hidden = NO;
      _captures++;
    }
    __weak OACPane* owner = self;
    auto release = std::make_shared<base::ScopedClosureRunner>(base::BindOnce(^{
      OACPane* pane = owner;
      if (!borrowed || !pane) {
        return;
      }
      pane->_captures--;
      if (!pane->_visible && pane->_captures == 0) {
        NSView* shown = [pane contentsView];
        shown.hidden = YES;
        [shown removeFromSuperview];
      }
    }));
    void (^done)(NSDictionary*) = [completion copy];
    auto params = std::make_shared<base::DictValue>(std::move(*dict));
    __weak OACPane* weakSelf = self;
    // The first frame takes a moment once the page draws: try again a few
    // times before giving up.
    __block void (^attempt)(int) = ^(int left) {
      OACPane* pane = weakSelf;
      if (!pane || !pane->_devTools) {
        capture->RunAndReset();
        release->RunAndReset();
        if (done) {
          done(nil);
        }
        return;
      }
      pane->_devTools->Call("Page.captureScreenshot", params->Clone(),
                            ^(NSDictionary<NSString*, id>* result) {
                              if (getenv("OPENARCH_DEBUG_PAGES")) {
                                LOG(ERROR) << "[openarch] hidden screenshot "
                                             << (result ? "ok" : "failed") << ", " << left << " left";
                              }
                              if (!result && left > 0) {
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                                               dispatch_get_main_queue(), ^{
                                                 attempt(left - 1);
                                               });
                                return;
                              }
                              capture->RunAndReset();
                              release->RunAndReset();
                              attempt = nil;
                              if (done) {
                                done(result);
                              }
                            });
    };
    attempt(4);
    return;
  }
  if ([method hasPrefix:@"Page."]) {
    // Diagnostics for Page calls (OPENARCH_DEBUG_PAGES=1).
    static const bool debug = getenv("OPENARCH_DEBUG_PAGES") != nullptr;
    if (debug) {
      std::string name = openarch::ToStdString(method) + (_visible ? " shown " : " hidden ") +
                         _contents->GetVisibleURL().spec();
      LOG(ERROR) << "[openarch] call " << name;
      void (^done)(NSDictionary*) = [completion copy];
      completion = ^(NSDictionary<NSString*, id>* result) {
        LOG(ERROR) << "[openarch] answer " << name << (result ? " ok" : " nil");
        if (done) {
          done(result);
        }
      };
    }
  }
  _devTools->Call(openarch::ToStdString(method), std::move(*dict), completion);
}

#pragma mark Chrome

// An extension's side panel beside the page; the same extension again hides
// it, as Chrome's button does.
- (void)toggleSidePanel:(OASidePanel*)panel {
  BOOL same = _sidePanel && [_sidePanel.extensionID isEqualToString:panel.extensionID];
  [_sidePanel.view removeFromSuperview];
  _sidePanel = same ? nil : panel;
  __weak OACPane* weakSelf = self;
  __weak OASidePanel* weakPanel = panel;
  panel.onClose = ^{
    OACPane* pane = weakSelf;
    if (pane && pane->_sidePanel == weakPanel) {
      [pane->_sidePanel.view removeFromSuperview];
      pane->_sidePanel = nil;
      [pane layoutViews];
    }
  };
  [self layoutViews];
}

// The toolbar's site button: OpenArch's site controls, when it has them.
- (void (^)(NSRect))siteControlsHandler {
  if (![_delegate respondsToSelector:@selector(pane:showSiteControlsFromRect:)]) {
    return nil;
  }
  __weak OACPane* weakSelf = self;
  return ^(NSRect rect) {
    OACPane* pane = weakSelf;
    if (pane && [pane.delegate respondsToSelector:@selector(pane:showSiteControlsFromRect:)]) {
      [pane.delegate pane:pane showSiteControlsFromRect:rect];
    }
  };
}

// The extension toolbar, also while it isn't shown: OACPane.extensions and
// running them go through it.
- (OAExtensionToolbar*)extensionToolbar {
  if (!_toolbar && _contents) {
    __weak OACPane* weakSelf = self;
    _toolbar = [[OAExtensionToolbar alloc] initWithWebContents:_contents
                                                       browser:[self browser]
                                                       openURL:^(NSString* url) {
                                                         [weakSelf openInNewTab:url];
                                                       }];
    _toolbar.sidePanelHandler = ^(OASidePanel* panel) {
      [weakSelf toggleSidePanel:panel];
    };
    _toolbar.siteControlsHandler = [self siteControlsHandler];
    _toolbar.historyTabHandler = ^(NSInteger offset, BOOL background) {
      [weakSelf openHistoryEntryInNewTab:offset background:background];
    };
  }
  return _toolbar;
}

- (NSArray<OACExtensionInfo*>*)extensions {
  return [[self extensionToolbar] extensionInfos] ?: @[];
}

- (void)runExtension:(NSString*)identifier fromRect:(NSRect)screenRect {
  [[self extensionToolbar] runExtension:identifier fromScreenRect:screenRect];
}

- (void)setExtension:(NSString*)identifier pinned:(BOOL)pinned {
  [[self extensionToolbar] setExtension:identifier pinned:pinned];
}

// A page for a new OpenArch tab (the toolbar's "Erweiterungen verwalten").
- (void)openInNewTab:(NSString*)url {
  if (g_external_tab_handler) {
    g_external_tab_handler(url);
  } else if ([_delegate respondsToSelector:@selector(pane:wantsNewTabWithURL:background:)]) {
    [_delegate pane:self wantsNewTabWithURL:url background:NO];
  }
}

- (void)find:(NSInteger)commandID {
  NSView* view = [self contentsView];
  if (!_contents || !_visible || !view.superview) {
    return;
  }
  if (!_findBar) {
    _findBar = [[OAFindBar alloc] initWithWebContents:_contents];
  }
  if (commandID == OACChromeCommandFind || !_findBar.isOpen) {
    [_findBar showInView:view.superview pageFrame:view.frame];
  }
  if (commandID != OACChromeCommandFind) {
    [_findBar findNext:commandID == OACChromeCommandFindNext];
  }
}

- (void)executeChromeCommand:(NSInteger)commandID {
  // Chrome's find bar is part of its (hidden) window: the pane has its own.
  if (commandID == OACChromeCommandFind || commandID == OACChromeCommandFindNext ||
      commandID == OACChromeCommandFindPrevious) {
    [self find:commandID];
    return;
  }
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return;
  }
  // Chrome's commands act on the active tab of their window.
  [self makeActiveTab];
  chrome::ExecuteCommand(browser, static_cast<int>(commandID));
}

// Where Chrome opens DevTools: docked (OpenArch then puts the frontend
// beside the page, on its own side) or in a window of their own.
- (void)applyDevToolsDockPreference {
  Profile* profile = Profile::FromBrowserContext(_contents->GetBrowserContext());
  const char* state = g_devtools_dock == OACDevToolsDockWindow ? "\"undocked\""
                      : g_devtools_dock == OACDevToolsDockLeft ? "\"left\""
                      : g_devtools_dock == OACDevToolsDockBottom ? "\"bottom\""
                                                                 : "\"right\"";
  for (const char* name : {prefs::kDevToolsPreferences, prefs::kDevToolsSyncedPreferencesSyncEnabled,
                           prefs::kDevToolsSyncedPreferencesSyncDisabled}) {
    ScopedDictPrefUpdate update(profile->GetPrefs(), name);
    update->Set("currentDockState", state);
  }
}

- (BOOL)hasDevTools {
  return _contents && DevToolsWindow::GetInstanceForInspectedWebContents(_contents);
}

- (void)showDevTools {
  if (!_contents) {
    return;
  }
  [self applyDevToolsDockPreference];
  DevToolsWindow::OpenDevToolsWindow(_contents, DevToolsOpenedByAction::kUnknown);
  [self adoptDevToolsTrying:20];
}

// The frontend counts as docked once it has loaded: look again for a while.
- (void)adoptDevToolsTrying:(int)left {
  [self adoptDevTools];
  if (_devToolsFrontend || left <= 0) {
    return;
  }
  __weak OACPane* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [weakSelf adoptDevToolsTrying:left - 1];
  });
}

// Chrome docks DevTools into the tab's (hidden) window; OpenArch shows the
// frontend beside the page instead.
- (void)adoptDevTools {
  DevToolsContentsResizingStrategy strategy;
  content::WebContents* frontend =
      _contents ? DevToolsWindow::GetInTabWebContents(_contents, &strategy) : nullptr;
  if (!frontend || frontend == _devToolsFrontend) {
    return;
  }
  frontend->SetUserData(views::OpenArchHostedPageKey(),
                        std::make_unique<base::SupportsUserData::Data>());
  _devToolsFrontend = frontend;
  _frontendObserver = std::make_unique<FrontendObserver>(frontend, self);
  [self watchDevToolsDockPreference];
  [self layoutViews];
}

// The dock side picked in DevTools' own menu (⋮ › Dock side) becomes
// OACPane.devToolsDock; "undock" moves the frontend into Chrome's window of
// its own, which then shows it.
- (void)watchDevToolsDockPreference {
  if (_devToolsPrefs || !_contents) {
    return;
  }
  Profile* profile = Profile::FromBrowserContext(_contents->GetBrowserContext());
  _devToolsPrefs = std::make_unique<PrefChangeRegistrar>();
  _devToolsPrefs->Init(profile->GetPrefs());
  __weak OACPane* weakSelf = self;
  for (const char* name : {prefs::kDevToolsPreferences, prefs::kDevToolsSyncedPreferencesSyncEnabled,
                           prefs::kDevToolsSyncedPreferencesSyncDisabled}) {
    _devToolsPrefs->Add(name, base::BindRepeating(^{
                          [weakSelf devToolsDockPreferenceChanged];
                        }));
  }
}

- (void)devToolsDockPreferenceChanged {
  if (!_contents || !_devToolsFrontend) {
    return;
  }
  Profile* profile = Profile::FromBrowserContext(_contents->GetBrowserContext());
  const std::string* state = profile->GetPrefs()->GetDict(prefs::kDevToolsPreferences).FindString("currentDockState");
  OACDevToolsDock dock = g_devtools_dock;
  if (state && *state == "\"left\"") {
    dock = OACDevToolsDockLeft;
  } else if (state && *state == "\"bottom\"") {
    dock = OACDevToolsDockBottom;
  } else if (state && *state == "\"right\"") {
    dock = OACDevToolsDockRight;
  } else if (state && *state == "\"undocked\"") {
    dock = OACDevToolsDockWindow;
  }
  if (dock == g_devtools_dock) {
    return;
  }
  g_devtools_dock = dock;
  if (dock == OACDevToolsDockWindow) {
    // Chrome moves the frontend into a window of its own: let it go.
    content::WebContents* frontend = _devToolsFrontend;
    frontend->RemoveUserData(views::OpenArchHostedPageKey());
    [frontend->GetNativeView().GetNativeNSView() removeFromSuperview];
    _frontendObserver.reset();
    _devToolsFrontend = nullptr;
    [self layoutViews];
  } else {
    for (NSWindow* window in g_panes_by_window) {
      for (OACPane* pane in [[g_panes_by_window objectForKey:window] allObjects]) {
        [pane layoutViews];
      }
    }
  }
  if (g_devtools_dock_handler) {
    g_devtools_dock_handler(dock);
  }
}

- (void)devToolsClosed {
  if (_devToolsFrontend) {
    NSView* toolsView = _devToolsFrontend->GetNativeView().GetNativeNSView();
    [toolsView removeFromSuperview];
  }
  _frontendObserver.reset();
  _devToolsFrontend = nullptr;
  [self layoutViews];
}

- (BOOL)closeDevTools {
  if (!_contents) {
    return NO;
  }
  if (_devToolsFrontend) {
    _devToolsFrontend->ClosePage();
    return YES;
  }
  DevToolsWindow* devtools = DevToolsWindow::GetInstanceForInspectedWebContents(_contents);
  if (!devtools) {
    return NO;
  }
  // Undocked DevTools are a Chrome window of their own.
  for (BrowserWindowInterface* browser : GetAllBrowserWindowInterfaces()) {
    if (browser->GetType() == BrowserWindowInterface::Type::TYPE_DEVTOOLS &&
        DevToolsWindow::AsDevToolsWindow(browser) == devtools) {
      browser->GetWindow()->Close();
      return YES;
    }
  }
  return NO;
}

- (void)setAudioMuted:(BOOL)muted {
  if (_contents) {
    _contents->SetAudioMuted(muted);
  }
}

- (void)close {
  if (_closing) {
    return;
  }
  _closing = YES;
  [self hide];
  if (_ownedContents) {
    // Destroying it reports WebContentsDestroyed, as a closed tab does.
    std::unique_ptr<content::WebContents> contents = std::move(_ownedContents);
    contents.reset();
    return;
  }
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    [self webContentsDestroyed];
    return;
  }
  TabStripModel* tabs = browser->GetTabStripModel();
  int index = tabs->GetIndexOfWebContents(_contents);
  if (index != TabStripModel::kNoTab) {
    // The page goes without asking ("Leave site?"): OpenArch already took
    // its tab away.
    tabs->DetachAndDeleteWebContentsAt(index);
  }
}

#pragma mark Events from Chromium

- (void)titleChanged {
  [_toolbar pageChanged];
  if (getenv("OPENARCH_DEBUG_PAGES")) {
    LOG(ERROR) << "[openarch] title " << openarch::ToStdString(self.title) << " " << openarch::ToStdString(self.url)
               << " delegate " << (_delegate != nil);
  }
  if ([_delegate respondsToSelector:@selector(pane:titleDidChange:)]) {
    [_delegate pane:self titleDidChange:self.title];
  }
}

- (void)addressChanged {
  [_toolbar pageChanged];
  if ([_delegate respondsToSelector:@selector(pane:addressDidChange:)]) {
    [_delegate pane:self addressDidChange:self.url];
  }
}

- (void)pageColorChanged {
  [_toolbar pageChanged];
}

- (void)loadingChanged {
  [_toolbar pageChanged];
  if ([_delegate respondsToSelector:@selector(pane:loadingStateDidChange:canGoBack:canGoForward:)]) {
    [_delegate pane:self
        loadingStateDidChange:self.isLoading
                    canGoBack:self.canGoBack
                 canGoForward:self.canGoForward];
  }
}

- (void)progressChanged:(double)progress {
  if ([_delegate respondsToSelector:@selector(pane:loadingProgressDidChange:)]) {
    [_delegate pane:self loadingProgressDidChange:progress];
  }
}

- (void)mainFrameLoad:(BOOL)started url:(const GURL&)url {
  if ([_delegate respondsToSelector:@selector(pane:mainFrameLoadStarted:url:)]) {
    [_delegate pane:self mainFrameLoadStarted:started url:openarch::ToNSString(url.spec())];
  }
}

- (void)gotFocus {
  // Chrome focuses the active tab of its (hidden) window by itself, which
  // may be a page in the background: only a page on screen, in the key
  // window, becomes active.
  if (!_visible || !_hostWindow.isKeyWindow) {
    return;
  }
  [self makeActiveTab];
  if ([_delegate respondsToSelector:@selector(paneDidBecomeActive:)]) {
    [_delegate paneDidBecomeActive:self];
  }
}

- (void)webContentsDestroyed {
  [self leavePageFullScreenWindowNotifying:NO];
  if (_contents) {
    RegisterContents(_contents, nil);
    openarch::StopHostingDialogs(_contents);
    [_findBar detachWebContents];
    _findBar = nil;
    [_toolbar detachWebContents];
    [_toolbar removeFromSuperview];
    _toolbar = nil;
    [_sidePanel.view removeFromSuperview];
    _sidePanel = nil;
    // The page is being destroyed: take its view away, but tell it nothing
    // (WasHidden on a WebContents in its destructor crashes).
    NSView* view = _contents->GetNativeView().GetNativeNSView();
    view.hidden = YES;
    [view removeFromSuperview];
  }
  _devTools.reset();
  _observer.reset();
  _contents = nullptr;
  _visible = NO;
  _closing = YES;
  if ([_delegate respondsToSelector:@selector(paneDidClose:)]) {
    [_delegate paneDidClose:self];
  }
}

- (void)consoleMessage:(NSString*)message source:(NSString*)source line:(NSInteger)line {
  if ([_delegate respondsToSelector:@selector(pane:consoleMessage:source:line:)]) {
    [_delegate pane:self consoleMessage:message source:source line:line];
  }
}

- (void)faviconChanged:(NSImage*)image {
  _favicon = image;
  [_toolbar pageChanged];
  if (image && [_delegate respondsToSelector:@selector(pane:faviconDidChange:)]) {
    [_delegate pane:self faviconDidChange:image];
  }
}

- (BOOL)takeNewTabWithURL:(const GURL&)url disposition:(WindowOpenDisposition)disposition {
  switch (disposition) {
    case WindowOpenDisposition::kNewForegroundTab:
    case WindowOpenDisposition::kNewBackgroundTab:
    case WindowOpenDisposition::kNewWindow:
    case WindowOpenDisposition::kSingletonTab:
    case WindowOpenDisposition::kSwitchToTab:
      break;
    default:
      // Real popups (window.open with features, OAuth flows) keep their
      // opener in a small Chrome window of their own.
      return NO;
  }
  if (!IsWebScheme(url)) {
    [self wantsExternalURL:url];
    return YES;
  }
  // ⇧-click on a link (a new window, for Chrome) opens Peek.
  if (disposition == WindowOpenDisposition::kNewWindow &&
      [_delegate respondsToSelector:@selector(pane:wantsPeekWithURL:)] &&
      [_delegate pane:self wantsPeekWithURL:openarch::ToNSString(url.spec())]) {
    return YES;
  }
  if (![_delegate respondsToSelector:@selector(pane:wantsNewTabWithURL:background:)]) {
    return NO;
  }
  [_delegate pane:self
      wantsNewTabWithURL:openarch::ToNSString(url.spec())
              background:disposition == WindowOpenDisposition::kNewBackgroundTab];
  return YES;
}

- (BOOL)interceptsNavigationToURL:(const GURL&)url {
  return [_delegate respondsToSelector:@selector(pane:shouldInterceptNavigationToURL:)] &&
         [_delegate pane:self shouldInterceptNavigationToURL:openarch::ToNSString(url.spec())];
}

- (BOOL)handsOffNavigationToURL:(const GURL&)url method:(NSString*)method {
  return [_delegate respondsToSelector:@selector(pane:shouldHandOffNavigationToURL:method:)] &&
         [_delegate pane:self
             shouldHandOffNavigationToURL:openarch::ToNSString(url.spec())
                                   method:method];
}

- (void)mediaAccessChangedVideo:(BOOL)video audio:(BOOL)audio {
  if ([_delegate respondsToSelector:@selector(pane:mediaAccessDidChangeVideo:audio:)]) {
    [_delegate pane:self mediaAccessDidChangeVideo:video audio:audio];
  }
}

- (void)wantsExternalURL:(const GURL&)url {
  NSString* address = openarch::ToNSString(url.spec());
  if ([_delegate respondsToSelector:@selector(pane:wantsToOpenExternalURL:)]) {
    [_delegate pane:self wantsToOpenExternalURL:address];
  } else if (NSURL* nsurl = [NSURL URLWithString:address]) {
    [[NSWorkspace sharedWorkspace] openURL:nsurl];
  }
}

#pragma mark Class-wide

+ (OACDevToolsDock)devToolsDock {
  return g_devtools_dock;
}

+ (void)setDevToolsDock:(OACDevToolsDock)dock {
  if (dock == g_devtools_dock) {
    return;
  }
  g_devtools_dock = dock;
  for (NSWindow* window in g_panes_by_window) {
    for (OACPane* pane in [[g_panes_by_window objectForKey:window] allObjects]) {
      if ([pane hasDevTools]) {
        // Open DevTools read their dock side only when they open (their own
        // ⋮ › Dock side aside), and lay out the page by it: they close and
        // open again on the new side.
        [pane closeDevTools];
        __weak OACPane* weakPane = pane;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          [weakPane showDevTools];
        });
      }
    }
  }
}

+ (void (^)(OACDevToolsDock))devToolsDockHandler {
  return g_devtools_dock_handler;
}

+ (void)setDevToolsDockHandler:(void (^)(OACDevToolsDock))handler {
  g_devtools_dock_handler = [handler copy];
}

+ (BOOL)closeDevToolsInWindow:(NSWindow*)window {
  BOOL closed = NO;
  for (OACPane* pane in [[g_panes_by_window objectForKey:window] allObjects]) {
    closed = [pane closeDevTools] || closed;
  }
  return closed;
}

+ (OACPane*)paneForWindow:(NSWindow*)window {
  for (OACPane* pane in [[g_panes_by_window objectForKey:window] allObjects]) {
    if (pane.isVisible) {
      return pane;
    }
  }
  return nil;
}

+ (void (^)(NSString*))externalTabHandler {
  return g_external_tab_handler;
}

+ (void)setExternalTabHandler:(void (^)(NSString*))handler {
  g_external_tab_handler = [handler copy];
  g_external_tab_handler_early = g_external_tab_handler;
}

+ (void (^)(void))aboutPageHandler {
  return g_about_page_handler;
}

+ (void)setAboutPageHandler:(void (^)(void))handler {
  g_about_page_handler = [handler copy];
}

+ (BOOL)isAboutPageURL:(NSString*)url {
  GURL gurl(openarch::ToStdString(url));
  return gurl.SchemeIs("chrome") && gurl.host() == "help";
}

+ (NSString*)askAboutSelectionTitle {
  return g_ask_about_selection_title;
}

+ (void)setAskAboutSelectionTitle:(NSString*)title {
  g_ask_about_selection_title = [title copy];
}

+ (void (^)(NSString*, int))renderProcessGoneHandler {
  return g_render_process_gone_handler;
}

+ (void)setRenderProcessGoneHandler:(void (^)(NSString*, int))handler {
  g_render_process_gone_handler = [handler copy];
}

+ (void (^)(OACDownload*))downloadHandler {
  return g_download_handler;
}

+ (void)setDownloadHandler:(void (^)(OACDownload*))handler {
  g_download_handler = [handler copy];
}

+ (void (^)(void))extensionsChangedHandler {
  return g_extensions_changed_handler;
}

+ (void)setExtensionsChangedHandler:(void (^)(void))handler {
  g_extensions_changed_handler = [handler copy];
}

+ (BOOL)cancelDownload:(uint32_t)identifier {
  for (BrowserWindowInterface* browser : GetAllBrowserWindowInterfaces()) {
    content::DownloadManager* manager = browser->GetProfile()->GetDownloadManager();
    if (download::DownloadItem* item = manager ? manager->GetDownload(identifier) : nullptr) {
      if (item->GetState() == download::DownloadItem::IN_PROGRESS) {
        item->Cancel(/*user_cancel=*/true);
        return YES;
      }
    }
  }
  return NO;
}

@end
