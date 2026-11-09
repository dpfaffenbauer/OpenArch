#import <AppKit/AppKit.h>

#import "OACProfile.h"

NS_ASSUME_NONNULL_BEGIN

@protocol OACPaneDelegate;

/// Which engine draws a page.
typedef NS_ENUM(NSInteger, OACPageEngine) {
  /// Chromium (CEF): every page, unless OpenArch picks WebKit for it.
  OACPageEngineChromium,
  /// The Mac's own WebKit, with Safari's FairPlay: streaming services
  /// whose DRM Chromium cannot play (see ProtectedMedia.swift).
  OACPageEngineWebKit,
};

/// What OpenArch needs from a tab's page, whichever engine draws it. Every
/// page lives in a borderless window of its own that OpenArch attaches as a
/// child window over its content area, so sidebar, split view, Peek, Little
/// OpenArch, previews, the media player, sleeping tabs and the rest work the
/// same for both. OACPane is Chromium's; the app's WebKitPage is WebKit's.
NS_SWIFT_UI_ACTOR
@protocol OACPage <NSObject>

@property(readonly) OACPageEngine engine;
@property(weak, nullable) id<OACPaneDelegate> delegate;
/// The space's Chromium profile. A WebKit page keeps its cookies in a
/// WebKit store of the same profile.
@property(readonly) OACProfile* profile;
@property(readonly, copy) NSString* url;
@property(readonly, copy) NSString* title;
@property(readonly, nullable) NSImage* favicon;
@property(readonly) BOOL isLoading;
@property(readonly) BOOL canGoBack;
@property(readonly) BOOL canGoForward;
/// Whether the page exists yet. Pages are created lazily, on the first
/// -showInWindow:frame: or -load.
@property(readonly) BOOL isLoaded;
@property(readonly) BOOL isVisible;
/// The borderless window hosting the page, once created.
@property(readonly, nullable) NSWindow* window;
/// Chrome's toolbar (location bar, extension buttons, downloads, menu).
/// A WebKit page has none and ignores it.
@property(nonatomic) BOOL toolbarVisible;
/// Whether showing or focusing the page activates OpenArch. Off for the
/// background self-test.
@property(nonatomic) BOOL activatesOnShow;
/// Corner radius of the page window's content.
@property(nonatomic) CGFloat cornerRadius;
/// Whether selected text's context menu offers "Claude fragen".
@property(nonatomic) BOOL offersAskAboutSelection;
/// The page's zoom in percent (100 = normal).
@property(readonly) NSInteger zoomPercent;

/// Starts loading the page without showing it (a tab opened in the
/// background).
- (void)load;
/// Shows the page over |frame| (in |window|'s coordinates), creating it on
/// first use. The page follows |window| when it moves.
- (void)showInWindow:(NSWindow*)window frame:(NSRect)frame;
/// Updates the frame (in the parent window's coordinates) while visible.
- (void)setFrame:(NSRect)frame;
- (void)hide;
/// Makes the page's window key and focuses the page.
- (void)focus;
/// Puts the page's window above its siblings (e.g. below an overlay).
- (void)orderFront;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)executeJavaScript:(NSString*)script;
/// Runs |script| in the main frame as if the user had just clicked, so it
/// may start playback or picture-in-picture.
- (void)executeJavaScript:(NSString*)script userGesture:(BOOL)userGesture;
/// Calls a DevTools protocol method on the page. |completion| gets the
/// method's result, or nil when it failed. A WebKit page answers
/// Runtime.evaluate, Page.getLayoutMetrics, Page.captureScreenshot and
/// Storage.clearDataForOrigin itself, and nil to everything else.
- (void)callDevToolsMethod:(NSString*)method
                    params:(NSDictionary<NSString*, id>*)params
                completion:(nullable void (^)(NSDictionary<NSString*, id>* _Nullable result))completion;
/// Whether the page would ask before it is left (a beforeunload handler:
/// an unsent form, unsaved changes), which closing it to sleep would skip.
/// YES when it cannot tell.
- (void)checkAsksBeforeLeaving:(void (^)(BOOL asks))completion
    NS_SWIFT_NAME(checkAsksBeforeLeaving(_:));
/// Runs a Chrome command (OACChromeCommand) on the page: find, zoom,
/// print, reload … A WebKit page runs the ones it has and ignores others.
- (void)executeChromeCommand:(NSInteger)commandID;
/// Chrome's DevTools, or WebKit's Web Inspector.
- (void)showDevTools;
/// Closes the page's DevTools if they are open (docked beside the page).
- (BOOL)closeDevTools;
- (void)setAudioMuted:(BOOL)muted;
/// Closes the page and its window. The delegate gets -paneDidClose:.
- (void)close;

@end

NS_ASSUME_NONNULL_END
