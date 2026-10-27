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

/// Shows the pane over |frame| (in |window|'s coordinates), creating the
/// browser on first use. The pane follows |window| when it moves.
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
- (void)executeChromeCommand:(NSInteger)commandID;
- (void)showDevTools;
- (void)setAudioMuted:(BOOL)muted;
/// Closes the browser and its window. The delegate gets -paneDidClose:.
- (void)close;

/// The pane hosting the given NSWindow, if any.
+ (nullable OACPane*)paneForWindow:(NSWindow*)window;

/// Tabs Chrome opens by itself (an extension calling chrome.tabs.create, for
/// example) would get a Chrome window of their own. With a handler set,
/// OpenArch gets the URL instead and Chrome's window is closed. Popup windows
/// and incognito windows are left alone.
@property(class, nonatomic, copy, nullable) void (^externalTabHandler)(NSString* url);

@end

NS_ASSUME_NONNULL_END
