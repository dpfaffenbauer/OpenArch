#import <AppKit/AppKit.h>

@class OACBrowserView;
@class OACProfile;

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@protocol OACBrowserViewDelegate <NSObject>
@optional
- (void)browserView:(OACBrowserView*)view titleDidChange:(NSString*)title;
- (void)browserView:(OACBrowserView*)view addressDidChange:(NSString*)url;
- (void)browserView:(OACBrowserView*)view
    loadingStateDidChange:(BOOL)isLoading
                canGoBack:(BOOL)canGoBack
             canGoForward:(BOOL)canGoForward;
/// The main frame finished loading.
- (void)browserViewDidFinishLoading:(OACBrowserView*)view;
- (void)browserView:(OACBrowserView*)view
     consoleMessage:(NSString*)message
             source:(NSString*)source
               line:(NSInteger)line;
/// The page tried to open a popup or a link with target=_blank.
- (void)browserView:(OACBrowserView*)view wantsNewTabWithURL:(NSString*)url;
- (void)browserViewDidClose:(OACBrowserView*)view;
@end

/// A Chromium browser embedded as a native AppKit view (CEF "Alloy" style).
/// The browser is created once the view is in a window.
NS_SWIFT_UI_ACTOR
@interface OACBrowserView : NSView

- (instancetype)initWithProfile:(OACProfile*)profile
                            url:(NSString*)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@property(weak, nullable) id<OACBrowserViewDelegate> delegate;
@property(readonly) OACProfile* profile;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)executeJavaScript:(NSString*)script;
- (void)showDevTools;
- (void)close;

/// Opens a top-level window with Chrome's own UI (CEF "Chrome" style),
/// including its toolbar and extensions menu.
+ (void)openChromeStyleWindowWithURL:(NSString*)url profile:(OACProfile*)profile;

@end

NS_ASSUME_NONNULL_END
