#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A browsing profile: its own cookies, storage, cache, logins, history and
/// extensions. In Arc terms, every Space uses one profile.
NS_SWIFT_UI_ACTOR
@interface OACProfile : NSObject

/// Chromium's default profile (<root>/Default).
@property(class, readonly) OACProfile* defaultProfile;

/// A profile stored under <rootCachePath>/<directoryName>. Returns the same
/// object for the same directory.
+ (OACProfile*)profileWithDirectoryName:(NSString*)directoryName;

- (instancetype)init NS_UNAVAILABLE;

@property(readonly, copy) NSString* directoryName;
/// Whether Chromium finished loading the profile from disk.
@property(readonly) BOOL isReady;
/// Runs |block| once the profile is ready (immediately if it already is).
- (void)whenReady:(dispatch_block_t)block;

/// Downloads |url| through Chromium's network stack with this profile's
/// cookies and proxy settings. |completion| runs on the main thread with the
/// body and HTTP status (0 when the request failed). macOS's URLSession is
/// unreliable inside a process that runs Chromium.
- (void)fetchURL:(NSString*)url
      completion:(void (^)(NSData* _Nullable data, NSInteger status))completion;

@end

NS_ASSUME_NONNULL_END
