// OpenArchProtectedVideo: Netflix and Disney+ in a Chromium page, played
// with Apple's FairPlay (ProtectedVideo.swift in the app, protected-video.js
// in the built-in extension). Adapted from Ardia, see NOTICE.
//
// The page's script hands over what the site's player appends to its
// MediaSource and asks of its key system. OAProtectedVideo decodes and
// draws it with Apple's sample-buffer player in a view over the page's
// <video>, with the keys from AVContentKeySession (the page's own code
// trades the key requests for licences with the service). OAVideoMirror
// draws a copy of the site's own controls over that picture.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What the player needs from the app for one page. The app keeps one
/// object per page and passes the same one every time.
NS_SWIFT_UI_ACTOR
@protocol OAPVPage <NSObject>
/// The page's view in OpenArch's window, nil while the page is not shown.
@property(readonly, nullable) NSView* pageView;
/// The tab's speaker is off.
@property(readonly) BOOL isMuted;
/// The page is gone.
@property(readonly) BOOL isClosed;
/// Sends |json| to the page's script (|kind| is "protectedVideo" or
/// "videoMirror").
- (void)deliver:(NSString*)kind json:(NSString*)json;
/// The player started or stopped playing.
- (void)playingChanged;
/// "played", "failed" (with "step") and other events worth knowing.
- (void)report:(NSDictionary<NSString*, id>*)payload;
/// Picture in Picture's button back to the tab was pressed.
- (void)backToTab;
@end

NS_SWIFT_UI_ACTOR
@interface OAProtectedVideo : NSObject
/// Writes what the player does to the log (never keys or media).
@property(class) BOOL traces;
/// A message of the page's script.
+ (void)page:(id<OAPVPage>)page message:(NSDictionary<NSString*, id>*)message;
/// The page closed, or went somewhere else.
+ (void)pageGone:(id<OAPVPage>)page;
+ (void)muteChanged:(id<OAPVPage>)page;
/// A video is attached and has started.
+ (BOOL)isActive:(id<OAPVPage>)page;
+ (BOOL)plays:(id<OAPVPage>)page;
/// How many frames Apple's player has shown for the page's video (the
/// self-test: that it decodes, not only counts time).
+ (NSInteger)shownFrames:(id<OAPVPage>)page;
+ (BOOL)startPictureInPicture:(id<OAPVPage>)page;
+ (void)exitPictureInPicture:(id<OAPVPage>)page;
@end

NS_SWIFT_UI_ACTOR
@interface OAVideoMirror : NSObject
/// The applier script (video_mirror.js) the copy's web view runs.
@property(class, copy, nullable) NSString* applierSource;
@property(class) BOOL traces;
/// The self-test: a folder for video-mirror.json (what the copy has
/// applied and where it is) and video-mirror.png (what it shows).
@property(class, copy, nullable) NSString* statsDirectory;
/// A message of the page's script; |origin| is the page's.
+ (void)page:(id<OAPVPage>)page origin:(NSString*)origin message:(NSDictionary<NSString*, id>*)message;
+ (void)pageGone:(id<OAPVPage>)page;
@end

NS_ASSUME_NONNULL_END
