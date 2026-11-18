// Adapted from Ardia (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios/ArdiaVideoMirror.mm), Apache License 2.0,
// Copyright 2026 Mantra Patel. Changed for OpenArch. See NOTICE.

#import "Support.h"

#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

#include <cmath>

using namespace oa_runtime;

static const double kMaxParts = 1024;
static const NSUInteger kMaxPartChars = 20000;
static const NSUInteger kMaxBatchChars = 8200000;
static const NSUInteger kMaxQueued = 240;
static const NSTimeInterval kPlaceInterval = 0.25;
static const NSTimeInterval kResyncGap = 1;
static const NSTimeInterval kReportGap = 1;

static NSString *const kShell =
    @"<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
    @"style-src * data: 'unsafe-inline'; img-src * data:; font-src * data:; script-src 'none'; frame-src 'none'; object-src 'none'; "
    @"media-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'\"></head><body></body></html>";

static WKWebsiteDataStore *SharedDataStore() {
  static WKWebsiteDataStore *store = WKWebsiteDataStore.nonPersistentDataStore;
  return store;
}

static NSString *gApplierSource;
static BOOL gTraces = NO;
// The self-test's folder for video-mirror.json and video-mirror.png: what
// the copy shows, to check from outside.
static NSString *gStatsDirectory;

static BOOL TestMode() {
  return gStatsDirectory.length > 0;
}

static BOOL Tracing() {
  return gTraces;
}

static NSString *ApplierSource() {
  return gApplierSource;
}

static void CallPage(id<OAPVPage> tab, NSString *json) {
  if (tab && !tab.isClosed) [tab deliver:@"videoMirror" json:json];
}

static bool WholeNumber(NSDictionary *d, NSString *key, double low, double high, double *out) {
  return Finite(d, key, out) && *out == floor(*out) && *out >= low && *out <= high;
}

@interface OAVideoMirrorView : WKWebView
@end

@implementation OAVideoMirrorView
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
- (BOOL)acceptsFirstResponder {
  return NO;
}
- (BOOL)becomeFirstResponder {
  return NO;
}
- (void)addTrackingArea:(NSTrackingArea *)trackingArea {
}
- (void)updateTrackingAreas {
}
- (void)resetCursorRects {
}
- (void)cursorUpdate:(NSEvent *)event {
}
- (void)registerForDraggedTypes:(NSArray<NSPasteboardType> *)newTypes {
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  return nil;
}
- (BOOL)isAccessibilityElement {
  return NO;
}
- (NSArray *)accessibilityChildren {
  return @[];
}
@end

@interface OAVideoMirrorClip : NSView
@end

@implementation OAVideoMirrorClip
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
- (BOOL)isOpaque {
  return NO;
}
@end

@interface OAVideoMirrorSession : NSObject <WKNavigationDelegate>
- (instancetype)initWithPage:(id<OAPVPage>)tab origin:(NSString *)origin;
- (void)handle:(NSDictionary *)message;
- (void)close;
@end

@implementation OAVideoMirrorSession {
  __weak id<OAPVPage> _tab;
  NSString *_origin;
  OAVideoMirrorView *_view;
  OAVideoMirrorClip *_clip;
  WKContentWorld *_world;
  NSTimer *_timer;
  NSMutableArray<NSString *> *_queue;
  NSMutableArray<NSString *> *_parts;
  double _assembling;
  double _expected;
  NSUInteger _chars;
  BOOL _loaded;
  BOOL _shown;
  BOOL _closed;
  double _scale;
  CFTimeInterval _resyncAt;
  CFTimeInterval _reportAt;
  NSUInteger _batches, _snapshots, _failures;
  double _pageMs, _pageMsMax, _applyMs, _applyMsMax, _latencyMs, _latencyMsMax, _nodes;
  NSUInteger _patches;
  double _patchPageMs, _patchPageMsMax, _patchLatencyMs, _patchLatencyMsMax;
}

- (instancetype)initWithPage:(id<OAPVPage>)tab origin:(NSString *)origin {
  if ((self = [super init])) {
    _tab = tab;
    _origin = [origin copy];
    _queue = [NSMutableArray array];
    _scale = 0;
    _world = [WKContentWorld worldWithName:@"openarch.videoMirror"];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = SharedDataStore();
    config.defaultWebpagePreferences.allowsContentJavaScript = NO;
    config.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    NSString *applier = ApplierSource();
    if (applier)
      [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:applier
                                                                         injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                                      forMainFrameOnly:YES
                                                                        inContentWorld:_world]];
    _view = [[OAVideoMirrorView alloc] initWithFrame:NSZeroRect configuration:config];
    _clip = [[OAVideoMirrorClip alloc] initWithFrame:NSZeroRect];
    _clip.identifier = MirrorViewIdentifier(tab);
    _clip.clipsToBounds = YES;
    _clip.hidden = YES;
    [_clip addSubview:_view];
    _view.navigationDelegate = self;
    _view.allowsMagnification = NO;
    _view.allowsBackForwardNavigationGestures = NO;
    _view.underPageBackgroundColor = NSColor.clearColor;
    [_view setValue:@NO forKey:@"drawsBackground"];
    [_view unregisterDraggedTypes];
    [self keepRenderingWhenOccluded];
    [self loadShell];
    __weak OAVideoMirrorSession *weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:kPlaceInterval repeats:YES block:^(NSTimer *) { [weakSelf place]; }];
  }
  return self;
}

// The self-test's window is behind all others, where WebKit would stop
// drawing the copy.
- (void)keepRenderingWhenOccluded {
  if (!TestMode()) return;
  SEL setDetection = NSSelectorFromString(@"_setWindowOcclusionDetectionEnabled:");
  if ([_view respondsToSelector:setDetection]) ((void (*)(id, SEL, BOOL))objc_msgSend)(_view, setDetection, NO);
}

- (void)loadShell {
  _loaded = NO;
  [_view loadHTMLString:kShell baseURL:[NSURL URLWithString:_origin]];
}

- (void)dealloc {
  [_timer invalidate];
  [_clip removeFromSuperview];
}

- (void)close {
  if (_closed) return;
  _closed = YES;
  [_timer invalidate];
  _timer = nil;
  _view.navigationDelegate = nil;
  [_clip removeFromSuperview];
  _clip = nil;
  _view = nil;
  [_queue removeAllObjects];
}

- (void)handle:(NSDictionary *)message {
  NSString *op = Text(message, @"op", 16);
  if ([op isEqualToString:@"part"]) [self part:message];
  else if ([op isEqualToString:@"frame"]) [self frameChanged:message];
}

- (void)frameChanged:(NSDictionary *)message {
  double dpr;
  if (!Finite(message, @"dpr", &dpr) || dpr < 0.25 || dpr > 16) return;
  _scale = dpr;
  [self place];
}

- (void)part:(NSDictionary *)message {
  double seq, part, parts;
  NSString *data = Field<NSString>(message, @"data");
  if (!WholeNumber(message, @"seq", 1, INT_MAX, &seq) || !WholeNumber(message, @"parts", 1, kMaxParts, &parts) ||
      !WholeNumber(message, @"part", 0, parts - 1, &part) || !data || data.length > kMaxPartChars)
    return [self dropBatch];
  if (part == 0) {
    _assembling = seq;
    _expected = parts;
    _parts = [NSMutableArray arrayWithCapacity:(NSUInteger)parts];
    _chars = 0;
  } else if (seq != _assembling || parts != _expected || part != _parts.count) {
    return [self dropBatch];
  }
  [_parts addObject:data];
  _chars += data.length;
  if (_chars > kMaxBatchChars) return [self dropBatch];
  if (_parts.count < _expected) return;
  NSString *batch = [_parts componentsJoinedByString:@""];
  _parts = nil;
  _assembling = 0;
  [self apply:batch];
}

- (void)dropBatch {
  if (Tracing()) NSLog(@"[videoMirror] dropped batch %.0f at part %lu of %.0f", _assembling, (unsigned long)_parts.count, _expected);
  _parts = nil;
  _assembling = 0;
  [self requestResync];
}

- (void)requestResync {
  const CFTimeInterval now = CACurrentMediaTime();
  if (now - _resyncAt < kResyncGap) return;
  _resyncAt = now;
  if (Tracing()) NSLog(@"[videoMirror] resync requested");
  CallPage(_tab, @"{\"resync\":true}");
}

- (void)apply:(NSString *)batch {
  if (_closed) return;
  if (!_loaded) {
    [_queue addObject:batch];
    if (_queue.count > kMaxQueued) {
      [_queue removeAllObjects];
      [self requestResync];
    }
    return;
  }
  __weak OAVideoMirrorSession *weakSelf = self;
  [_view callAsyncJavaScript:@"return window.ardiaVideoMirror ? window.ardiaVideoMirror(batch) : {ok: false}"
                   arguments:@{@"batch" : batch}
                     inFrame:nil
              inContentWorld:_world
           completionHandler:^(id result, NSError *error) {
             [weakSelf applied:[result isKindOfClass:NSDictionary.class] ? result : nil];
           }];
}

- (void)applied:(NSDictionary *)result {
  if (_closed) return;
  if (!Flag(result, @"ok")) {
    if (Tracing()) NSLog(@"[videoMirror] apply failed: %@", result);
    _failures++;
    [self requestResync];
    [self report];
    return;
  }
  double applyMs = 0, pageMs = 0, sentAt = 0, nodes = 0;
  Finite(result, @"ms", &applyMs);
  Finite(result, @"pageMs", &pageMs);
  Finite(result, @"nodes", &nodes);
  const double latency = Finite(result, @"sentAt", &sentAt) && sentAt > 0 ? NSDate.date.timeIntervalSince1970 * 1000 - sentAt : 0;
  _batches++;
  _applyMs += applyMs;
  _pageMs += pageMs;
  _latencyMs += latency;
  _applyMsMax = MAX(_applyMsMax, applyMs);
  _pageMsMax = MAX(_pageMsMax, pageMs);
  _latencyMsMax = MAX(_latencyMsMax, latency);
  _nodes = nodes;
  if ([Text(result, @"kind", 4) isEqualToString:@"s"]) {
    _snapshots++;
    _shown = YES;
    [self place];
  } else {
    _patches++;
    _patchPageMs += pageMs;
    _patchLatencyMs += latency;
    _patchPageMsMax = MAX(_patchPageMsMax, pageMs);
    _patchLatencyMsMax = MAX(_patchLatencyMsMax, latency);
  }
  [self report];
}

- (void)place {
  if (_closed) return;
  id<OAPVPage> tab = _tab;
  if (!tab) return [self close];
  NSView *content = tab.pageView;
  NSView *host = content.superview;
  NSView *video = nil;
  for (NSView *sibling in host.subviews)
    if ([sibling.identifier isEqualToString:VideoViewIdentifier(tab)]) video = sibling;
  const BOOL wanted = _shown && video && !video.hidden;
  if (!wanted || !host || !content.window || content.hiddenOrHasHiddenAncestor) {
    _clip.hidden = YES;
    return;
  }
  NSArray<NSView *> *siblings = host.subviews;
  NSView *below = video && [siblings indexOfObjectIdenticalTo:video] > [siblings indexOfObjectIdenticalTo:content] ? video : content;
  if (_clip.superview != host || [siblings indexOfObjectIdenticalTo:_clip] < [siblings indexOfObjectIdenticalTo:below])
    [host addSubview:_clip positioned:NSWindowAbove relativeTo:below];
  const NSRect clipFrame = video ? NSIntersectionRect(video.frame, content.frame) : content.frame;
  const CGFloat backing = content.window.backingScaleFactor ?: 2;
  const double zoom = MIN(MAX((_scale ?: backing) / backing, 0.25), 5);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (!NSEqualRects(_clip.frame, clipFrame)) _clip.frame = clipFrame;
  const NSRect inClip = [host convertRect:content.frame toView:_clip];
  if (!NSEqualRects(_view.frame, inClip)) _view.frame = inClip;
  if (fabs(_view.pageZoom - zoom) > 0.001) _view.pageZoom = zoom;
  [CATransaction commit];
  _clip.hidden = NSIsEmptyRect(clipFrame);
}

- (void)report {
  if (!TestMode() && !Tracing()) return;
  const CFTimeInterval now = CACurrentMediaTime();
  if (now - _reportAt < kReportGap) return;
  _reportAt = now;
  NSString *dir = TestMode() ? gStatsDirectory : NSTemporaryDirectory();
  if (!dir.length) return;
  const double count = MAX(_batches, 1);
  NSDictionary *stats = @{
    @"batches" : @(_batches),
    @"snapshots" : @(_snapshots),
    @"failures" : @(_failures),
    @"pageMsAvg" : @(_pageMs / count),
    @"pageMsMax" : @(_pageMsMax),
    @"applyMsAvg" : @(_applyMs / count),
    @"applyMsMax" : @(_applyMsMax),
    @"latencyMsAvg" : @(_latencyMs / count),
    @"latencyMsMax" : @(_latencyMsMax),
    @"patches" : @(_patches),
    @"patchPageMsAvg" : @(_patchPageMs / MAX(_patches, 1)),
    @"patchPageMsMax" : @(_patchPageMsMax),
    @"patchLatencyMsAvg" : @(_patchLatencyMs / MAX(_patches, 1)),
    @"patchLatencyMsMax" : @(_patchLatencyMsMax),
    @"nodes" : @(_nodes),
    @"shown" : @(!_clip.hidden),
    @"frame" : NSStringFromRect(_clip.frame),
    @"zoom" : @(_view.pageZoom),
  };
  if (Tracing()) NSLog(@"[videoMirror] %@", JSONText(stats));
  [JSONText(stats) writeToFile:[dir stringByAppendingPathComponent:@"video-mirror.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if (_clip.hidden || NSIsEmptyRect(_view.bounds)) return;
  NSString *picture = [dir stringByAppendingPathComponent:@"video-mirror.png"];
  [_view takeSnapshotWithConfiguration:nil
                     completionHandler:^(NSImage *image, NSError *) {
                       CGImageRef cg = [image CGImageForProposedRect:nil context:nil hints:nil];
                       if (!cg) return;
                       NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:cg] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                       [png writeToFile:picture atomically:YES];
                     }];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  const BOOL shell = !_loaded && action.targetFrame.isMainFrame && action.navigationType == WKNavigationTypeOther &&
                     [action.request.URL.absoluteString hasPrefix:_origin];
  decisionHandler(shell ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  if (_closed || _loaded) return;
  _loaded = YES;
  NSArray<NSString *> *queued = [_queue copy];
  [_queue removeAllObjects];
  for (NSString *batch in queued) [self apply:batch];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  if (_closed) return;
  _shown = NO;
  _clip.hidden = YES;
  [_queue removeAllObjects];
  [self loadShell];
  _resyncAt = 0;
  [self requestResync];
}

@end

@implementation OAVideoMirror

+ (NSMapTable<id<OAPVPage> , OAVideoMirrorSession *> *)sessions {
  static NSMapTable *sessions = [NSMapTable weakToStrongObjectsMapTable];
  return sessions;
}

+ (NSString *)applierSource {
  return gApplierSource;
}

+ (void)setApplierSource:(NSString *)source {
  gApplierSource = [source copy];
}

+ (BOOL)traces {
  return gTraces;
}

+ (void)setTraces:(BOOL)traces {
  gTraces = traces;
}

+ (NSString *)statsDirectory {
  return gStatsDirectory;
}

+ (void)setStatsDirectory:(NSString *)directory {
  gStatsDirectory = [directory copy];
}

// The app passes only messages of pages it plays protected video for.
+ (void)page:(id<OAPVPage>)tab origin:(NSString *)origin message:(NSDictionary *)message {
  if (!tab || tab.isClosed || !origin.length) return;
  OAVideoMirrorSession *session = [self.sessions objectForKey:tab];
  if ([Text(message, @"op", 16) isEqualToString:@"stop"]) return [self pageGone:tab];
  if (!session) {
    session = [[OAVideoMirrorSession alloc] initWithPage:tab origin:origin];
    [self.sessions setObject:session forKey:tab];
  }
  [session handle:message];
}

+ (void)pageGone:(id<OAPVPage>)tab {
  if (!tab) return;
  OAVideoMirrorSession *session = [self.sessions objectForKey:tab];
  if (!session) return;
  [self.sessions removeObjectForKey:tab];
  [session close];
}

@end
