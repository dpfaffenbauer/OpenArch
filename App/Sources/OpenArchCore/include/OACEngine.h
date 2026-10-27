#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass Chromium needs on macOS (CefAppProtocol).
/// Set it as NSPrincipalClass and create it before anything else.
@interface OACApplication : NSApplication
@end

@interface OACEngineSettings : NSObject
/// Chromium's user data directory. Profiles live directly below it.
@property(copy) NSString* rootCachePath;
/// Unpacked extensions loaded into every profile (developer extensions).
@property(copy) NSArray<NSString*>* extensionPaths;
/// 0 disables remote debugging.
@property NSInteger remoteDebuggingPort;
/// Stores Chromium's encryption key in a fake keychain instead of the login
/// keychain. Avoids keychain prompts for ad-hoc signed builds.
@property BOOL useMockKeychain;
/// Additional Chromium command-line switches ("name" or "name=value").
@property(copy) NSArray<NSString*>* extraSwitches;
@end

/// Process-wide Chromium lifecycle.
NS_SWIFT_UI_ACTOR
@interface OACEngine : NSObject

/// Loads the Chromium Embedded Framework. Call first, before NSApp exists.
+ (BOOL)loadFramework;
+ (BOOL)startWithSettings:(OACEngineSettings*)settings;
/// Runs |block| once Chromium is initialized and browsers can be created.
+ (void)whenReady:(dispatch_block_t)block;
+ (void)runMessageLoop;
/// Closes every browser, then ends the message loop.
+ (void)quit;
+ (void)shutdown;

@property(class, readonly) NSString* versionString;
/// The DevTools protocol port (0 when remote control is off).
@property(class, readonly) NSInteger remoteDebuggingPort;

/// OpenArch was launched again while running (Chromium allows one process
/// per profile folder): the new launch's arguments arrive here and the new
/// process exits. Without a handler Chromium opens a plain Chrome window.
@property(class, nonatomic, copy, nullable) void (^relaunchHandler)(NSArray<NSString*>* arguments);

@end

NS_ASSUME_NONNULL_END
