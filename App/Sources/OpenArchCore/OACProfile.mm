#import "OACProfile.h"
#import "OACInternal.h"

namespace {

class ProfileHandler : public CefRequestContextHandler {
 public:
  explicit ProfileHandler(OACProfile* profile) : profile_(profile) {}

  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> request_context) override {
    [profile_ oac_markReady];
  }

 private:
  __weak OACProfile* profile_;

  IMPLEMENT_REFCOUNTING(ProfileHandler);
};

NSMutableDictionary<NSString*, OACProfile*>* ProfilesByDirectory() {
  static NSMutableDictionary<NSString*, OACProfile*>* profiles =
      [NSMutableDictionary dictionary];
  return profiles;
}

}  // namespace

@implementation OACProfile {
  CefRefPtr<CefRequestContext> _context;
  NSMutableArray<dispatch_block_t>* _pending;
}

+ (OACProfile*)defaultProfile {
  static OACProfile* profile;
  if (!profile) {
    profile = [[OACProfile alloc] initWithDirectoryName:@"Default"];
    // The global context is ready once Chromium itself is (see OACEngine).
    profile->_context = CefRequestContext::GetGlobalContext();
    if (OACEngineIsReady()) {
      [profile oac_markReady];
    }
  }
  return profile;
}

+ (OACProfile*)profileWithDirectoryName:(NSString*)directoryName {
  if ([directoryName isEqualToString:@"Default"]) {
    return self.defaultProfile;
  }
  OACProfile* profile = ProfilesByDirectory()[directoryName];
  if (!profile) {
    profile = [[OACProfile alloc] initWithDirectoryName:directoryName];
    // Chrome only accepts profiles that are direct children of the user
    // data directory (root_cache_path), like its own "Default".
    NSString* path =
        [OACRootCachePath() stringByAppendingPathComponent:directoryName];
    CefRequestContextSettings settings;
    settings.persist_session_cookies = true;
    CefString(&settings.cache_path) = path.UTF8String;
    profile->_context = CefRequestContext::CreateContext(
        settings, new ProfileHandler(profile));
    ProfilesByDirectory()[directoryName] = profile;
  }
  return profile;
}

- (instancetype)initWithDirectoryName:(NSString*)directoryName {
  if ((self = [super init])) {
    _directoryName = [directoryName copy];
    _pending = [NSMutableArray array];
  }
  return self;
}

- (void)whenReady:(dispatch_block_t)block {
  if (_isReady) {
    block();
  } else {
    [_pending addObject:block];
  }
}

- (void)oac_markReady {
  if (_isReady) {
    return;
  }
  _isReady = YES;
  NSArray<dispatch_block_t>* pending = [_pending copy];
  [_pending removeAllObjects];
  for (dispatch_block_t block in pending) {
    block();
  }
}

- (CefRefPtr<CefRequestContext>)cefContext {
  return _context;
}

@end
