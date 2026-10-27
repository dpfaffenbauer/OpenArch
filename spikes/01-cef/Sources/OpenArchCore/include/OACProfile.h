#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A browsing profile: its own cookies, storage, cache and logins.
/// In Arc terms, every Space can get its own profile.
NS_SWIFT_UI_ACTOR
@interface OACProfile : NSObject

/// Chromium's global profile (the one --load-extension targets).
@property(class, readonly) OACProfile* defaultProfile;

/// An isolated profile stored under <rootCachePath>/Space-<identifier>.
- (instancetype)initWithIdentifier:(NSString*)identifier;

- (instancetype)init NS_UNAVAILABLE;

@property(readonly, copy) NSString* identifier;

@end

NS_ASSUME_NONNULL_END
