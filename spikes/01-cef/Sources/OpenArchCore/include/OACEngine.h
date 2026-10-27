#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass CEF requires on macOS (implements CefAppProtocol).
/// `OACApplication.shared` must be created before `OACEngine.start`.
@interface OACApplication : NSApplication
@end

@interface OACEngineSettings : NSObject
/// Parent directory for all profile data.
@property(copy) NSString* rootCachePath;
/// Unpacked extensions to load at startup (passed as --load-extension).
@property(copy) NSArray<NSString*>* extensionPaths;
/// Chrome DevTools Protocol port on 127.0.0.1, 0 disables it.
@property NSInteger remoteDebuggingPort;
@end

NS_SWIFT_UI_ACTOR
@interface OACEngine : NSObject

/// Loads the Chromium Embedded Framework. Call first in main().
+ (BOOL)loadFramework;

/// Initializes Chromium. Returns NO if initialization failed.
+ (BOOL)startWithSettings:(OACEngineSettings*)settings;

/// Runs the Chromium message loop (and with it the NSApplication run loop)
/// until `quit` has finished closing all browsers.
+ (void)runMessageLoop;

/// Closes every browser, then ends `runMessageLoop`.
+ (void)quit;

+ (void)shutdown;

@property(class, readonly) NSString* versionString;

@end

NS_ASSUME_NONNULL_END
