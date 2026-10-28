#import <AppKit/AppKit.h>

#import "OACProfile.h"

NS_ASSUME_NONNULL_BEGIN

@class OACPane;

/// Chrome command ids (see include/cef_command_ids.h) that OpenArch handles
/// itself instead of Chrome.
typedef NS_ENUM(NSInteger, OACChromeCommand) {
  OACChromeCommandBack = 33000,
  OACChromeCommandForward = 33001,
  OACChromeCommandReload = 33002,
  OACChromeCommandStop = 33006,
  OACChromeCommandReloadBypassingCache = 33007,
  OACChromeCommandNewWindow = 34000,
  OACChromeCommandNewIncognitoWindow = 34001,
  OACChromeCommandCloseWindow = 34012,
  OACChromeCommandNewTab = 34014,
  OACChromeCommandCloseTab = 34015,
  OACChromeCommandSelectNextTab = 34016,
  OACChromeCommandSelectPreviousTab = 34017,
  OACChromeCommandSelectTab0 = 34018,
  OACChromeCommandSelectTab7 = 34025,
  OACChromeCommandSelectLastTab = 34026,
  OACChromeCommandDuplicateTab = 34027,
  OACChromeCommandRestoreTab = 34028,
  OACChromeCommandFullscreen = 34030,
  OACChromeCommandExit = 34031,
  OACChromeCommandNewSplitTab = 34057,
  OACChromeCommandCopyURL = 34071,
  OACChromeCommandBookmarkThisTab = 35000,
  OACChromeCommandViewSource = 35002,
  OACChromeCommandPrint = 35003,
  OACChromeCommandSavePage = 35004,
  OACChromeCommandFind = 37000,
  OACChromeCommandFindNext = 37001,
  OACChromeCommandFindPrevious = 37002,
  OACChromeCommandZoomPlus = 38001,
  OACChromeCommandZoomNormal = 38002,
  OACChromeCommandZoomMinus = 38003,
  OACChromeCommandFocusLocation = 39001,
  OACChromeCommandDevTools = 40004,
  OACChromeCommandDevToolsConsole = 40005,
  OACChromeCommandShowBookmarkBar = 40009,
  OACChromeCommandShowHistory = 40010,
  OACChromeCommandShowBookmarkManager = 40011,
  OACChromeCommandShowDownloads = 40012,
  OACChromeCommandClearBrowsingData = 40013,
  OACChromeCommandOptions = 40015,
  OACChromeCommandManageExtensions = 40022,
  OACChromeCommandDevToolsInspect = 40023,
  OACChromeCommandDevToolsToggle = 40237,
  OACChromeCommandTabSearch = 52500,
};

/// A download a page started. Chrome saves it in the Downloads folder and
/// shows it in its toolbar; OpenArch gets its progress.
@interface OACDownload : NSObject
@property(readonly) uint32_t identifier;
/// The file name, as far as known.
@property(readonly, copy) NSString* fileName;
/// Where the file goes; empty until Chrome has chosen it.
@property(readonly, copy) NSString* path;
/// 0–100, or -1 while the size is unknown.
@property(readonly) NSInteger percentComplete;
@property(readonly) BOOL isComplete;
/// Cancelled or interrupted: it will not complete.
@property(readonly) BOOL isFailed;
@end

NS_SWIFT_UI_ACTOR
@protocol OACPaneDelegate <NSObject>
@optional
- (void)pane:(OACPane*)pane titleDidChange:(NSString*)title;
- (void)pane:(OACPane*)pane addressDidChange:(NSString*)url;
- (void)pane:(OACPane*)pane faviconDidChange:(NSImage*)favicon;
- (void)pane:(OACPane*)pane
    loadingStateDidChange:(BOOL)isLoading
                canGoBack:(BOOL)canGoBack
             canGoForward:(BOOL)canGoForward;
/// A link or script asked for a new tab. |background| is true for
/// middle/cmd-clicks.
- (void)pane:(OACPane*)pane
    wantsNewTabWithURL:(NSString*)url
            background:(BOOL)background;
/// Return YES if OpenArch handled the command, NO to let Chrome run it.
- (BOOL)pane:(OACPane*)pane handleChromeCommand:(NSInteger)commandID;
/// The pane's window became key (the user clicked or typed into it).
- (void)paneDidBecomeActive:(OACPane*)pane;
- (void)pane:(OACPane*)pane
    consoleMessage:(NSString*)message
            source:(NSString*)source
              line:(NSInteger)line;
/// The browser is gone (closed by the page, a crash or -close).
- (void)paneDidClose:(OACPane*)pane;
/// A new document started (YES) or finished (NO) loading in the main frame.
- (void)pane:(OACPane*)pane mainFrameLoadStarted:(BOOL)started url:(NSString*)url;
/// A link the user clicked is about to replace the page. Return YES to
/// take it over (the navigation is cancelled), e.g. to show it in Peek.
- (BOOL)pane:(OACPane*)pane shouldInterceptNavigationToURL:(NSString*)url;
/// The page went to an address another app opens (bambustudioopen:,
/// zoommtg:, mailto: ...). The navigation was cancelled.
- (void)pane:(OACPane*)pane wantsToOpenExternalURL:(NSString*)url;
@end

/// One Chrome tab. It is hosted in its own borderless Chrome-style window
/// that OpenArch attaches as a child window over its content area, so that
/// Chrome treats it as a real tab: extensions (chrome.tabs, action popups,
/// side panels), DevTools, find, downloads and permission prompts all work.
NS_SWIFT_UI_ACTOR
@interface OACPane : NSObject

- (instancetype)initWithProfile:(OACProfile*)profile url:(NSString*)url;
- (instancetype)init NS_UNAVAILABLE;

@property(weak, nullable) id<OACPaneDelegate> delegate;
@property(readonly) OACProfile* profile;
@property(readonly, copy) NSString* url;
@property(readonly, copy) NSString* title;
@property(readonly, nullable) NSImage* favicon;
@property(readonly) BOOL isLoading;
@property(readonly) BOOL canGoBack;
@property(readonly) BOOL canGoForward;
/// Whether Chrome's browser exists yet. Panes are created lazily, on the
/// first -showInWindow:frame:.
@property(readonly) BOOL isLoaded;
@property(readonly) BOOL isVisible;
/// The borderless window hosting the tab, once created.
@property(readonly, nullable) NSWindow* window;
/// Chrome's toolbar (location bar, extension buttons, downloads, menu).
@property(nonatomic) BOOL toolbarVisible;
/// Whether showing or focusing the pane activates OpenArch (Chrome's
/// default). Off for the background self-test.
@property(nonatomic) BOOL activatesOnShow;
/// Corner radius of the pane window's content.
@property(nonatomic) CGFloat cornerRadius;
/// Self-test: the browser refuses to close, like one that never finishes
/// closing, so quitting has to get by without it.
@property(nonatomic) BOOL refusesToCloseForTesting;

/// Shows the pane over |frame| (in |window|'s coordinates), creating the
/// browser on first use. The pane follows |window| when it moves.
/// Starts loading the page without showing it: a tab opened in the
/// background. Showing it later needs no load.
- (void)load;
- (void)showInWindow:(NSWindow*)window frame:(NSRect)frame;
/// Updates the frame (in the parent window's coordinates) while visible.
- (void)setFrame:(NSRect)frame;
- (void)hide;
/// Makes the pane's window key and focuses the page.
- (void)focus;
/// Puts the pane's window above its siblings (e.g. below an overlay).
- (void)orderFront;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)executeJavaScript:(NSString*)script;
/// Runs |script| in the main frame as if the user had just clicked, so it
/// may start playback or picture-in-picture (via the DevTools protocol).
- (void)executeJavaScript:(NSString*)script userGesture:(BOOL)userGesture;
/// Calls a DevTools protocol method on the page (e.g.
/// "Storage.clearDataForOrigin"). |completion| gets the method's result, or
/// nil when it failed or the page has no browser yet.
- (void)callDevToolsMethod:(NSString*)method
                    params:(NSDictionary<NSString*, id>*)params
                completion:(nullable void (^)(NSDictionary<NSString*, id>* _Nullable result))completion;
/// The page's zoom in percent (100 = normal). Chrome keeps it per site.
@property(readonly) NSInteger zoomPercent;
- (void)executeChromeCommand:(NSInteger)commandID;
- (void)showDevTools;
- (void)setAudioMuted:(BOOL)muted;
/// Closes the browser and its window. The delegate gets -paneDidClose:.
- (void)close;

/// Where DevTools open: docked beside the page (right, left, below) or in
/// a window of their own.
typedef NS_ENUM(NSInteger, OACDevToolsDock) {
  OACDevToolsDockRight,
  OACDevToolsDockLeft,
  OACDevToolsDockBottom,
  OACDevToolsDockWindow,
};

/// For every tab; open DevTools move (between docked and a window, they
/// close and open again).
@property(class, nonatomic) OACDevToolsDock devToolsDock;
/// Called when the dock side was picked in DevTools' own menu (⋮ › Dock
/// side), after devToolsDock has changed.
@property(class, nonatomic, copy, nullable) void (^devToolsDockHandler)(OACDevToolsDock dock);

/// Closes the tab's DevTools if they are open (docked beside the page).
- (BOOL)closeDevTools;
/// Closes the docked DevTools that |window| shows, if it shows any.
+ (BOOL)closeDevToolsInWindow:(NSWindow*)window;

/// The pane hosting the given NSWindow, if any.
+ (nullable OACPane*)paneForWindow:(NSWindow*)window;

/// Tabs Chrome opens by itself (an extension calling chrome.tabs.create, for
/// example) would get a Chrome window of their own. With a handler set,
/// OpenArch gets the URL instead and Chrome's window is closed. Popup windows
/// and incognito windows are left alone.
@property(class, nonatomic, copy, nullable) void (^externalTabHandler)(NSString* url);

/// Gets every download's progress, from any tab or window, including tabs
/// that closed after starting one.
@property(class, nonatomic, copy, nullable) void (^downloadHandler)(OACDownload* download);
/// Cancels a running download. Returns NO when it is not running.
+ (BOOL)cancelDownload:(uint32_t)identifier;

@end

NS_ASSUME_NONNULL_END
