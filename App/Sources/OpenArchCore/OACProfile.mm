#import "OACProfile.h"
#import "OACInternal.h"

#include "include/cef_urlrequest.h"

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

class FetchClient : public CefURLRequestClient {
 public:
  explicit FetchClient(void (^completion)(NSData*, NSInteger))
      : completion_([completion copy]), data_([NSMutableData data]) {}

  void OnRequestComplete(CefRefPtr<CefURLRequest> request) override {
    CefRefPtr<CefResponse> response = request->GetResponse();
    const bool ok = request->GetRequestStatus() == UR_SUCCESS && response;
    completion_(ok ? data_ : nil, ok ? response->GetStatus() : 0);
    completion_ = nil;
  }

  void OnUploadProgress(CefRefPtr<CefURLRequest> request,
                        int64_t current,
                        int64_t total) override {}
  void OnDownloadProgress(CefRefPtr<CefURLRequest> request,
                          int64_t current,
                          int64_t total) override {}

  void OnDownloadData(CefRefPtr<CefURLRequest> request,
                      const void* data,
                      size_t data_length) override {
    [data_ appendBytes:data length:data_length];
  }

  bool GetAuthCredentials(bool isProxy,
                          const CefString& host,
                          int port,
                          const CefString& realm,
                          const CefString& scheme,
                          CefRefPtr<CefAuthCallback> callback) override {
    return false;
  }

 private:
  void (^completion_)(NSData*, NSInteger);
  NSMutableData* data_;

  IMPLEMENT_REFCOUNTING(FetchClient);
};

// Every profile, so a preference set later reaches the private ones too.
NSHashTable<OACProfile*>* AllProfiles() {
  static NSHashTable<OACProfile*>* profiles = [NSHashTable weakObjectsHashTable];
  return profiles;
}

// Preferences for every profile (see +setPreference:boolValue:).
NSMutableDictionary<NSString*, id>* GlobalPreferences() {
  static NSMutableDictionary<NSString*, id>* preferences =
      [NSMutableDictionary dictionary];
  return preferences;
}

void ApplyPreference(CefRefPtr<CefRequestContext> context,
                     NSString* name,
                     id value) {
  if (!context || !context->CanSetPreference(name.UTF8String)) {
    NSLog(@"OpenArch: cannot set preference %@", name);
    return;
  }
  CefRefPtr<CefValue> cefValue = CefValue::Create();
  if ([value isKindOfClass:NSString.class]) {
    cefValue->SetString([value UTF8String]);
  } else if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
    cefValue->SetBool([value boolValue]);
  } else if (CFNumberIsFloatType((__bridge CFNumberRef)value)) {
    cefValue->SetDouble([value doubleValue]);
  } else {
    cefValue->SetInt([value intValue]);
  }
  CefString error;
  if (!context->SetPreference(name.UTF8String, cefValue, error)) {
    NSLog(@"OpenArch: preference %@: %s", name, error.ToString().c_str());
  }
}

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

+ (OACProfile*)makePrivateProfile {
  OACProfile* profile = [[OACProfile alloc] initWithDirectoryName:@""];
  // No cache path: Chromium keeps the profile in memory (incognito).
  CefRequestContextSettings settings;
  profile->_context =
      CefRequestContext::CreateContext(settings, new ProfileHandler(profile));
  return profile;
}

- (instancetype)initWithDirectoryName:(NSString*)directoryName {
  if ((self = [super init])) {
    _directoryName = [directoryName copy];
    _pending = [NSMutableArray array];
    [AllProfiles() addObject:self];
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
  [GlobalPreferences() enumerateKeysAndObjectsUsingBlock:^(
                           NSString* name, id value, BOOL* stop) {
    ApplyPreference(self->_context, name, value);
  }];
  NSArray<dispatch_block_t>* pending = [_pending copy];
  [_pending removeAllObjects];
  for (dispatch_block_t block in pending) {
    block();
  }
}

- (void)fetchURL:(NSString*)url
      completion:(void (^)(NSData* _Nullable, NSInteger))completion {
  [self fetchURL:url headers:@{} completion:completion];
}

- (void)fetchURL:(NSString*)url
         headers:(NSDictionary<NSString*, NSString*>*)headers
      completion:(void (^)(NSData* _Nullable, NSInteger))completion {
  [self whenReady:^{
    CefRefPtr<CefRequest> request = CefRequest::Create();
    request->SetURL(url.UTF8String);
    request->SetMethod("GET");
    request->SetFlags(UR_FLAG_ALLOW_STORED_CREDENTIALS);
    CefRequest::HeaderMap map;
    for (NSString* name in headers) {
      map.insert({name.UTF8String, headers[name].UTF8String});
    }
    if (!map.empty()) {
      request->SetHeaderMap(map);
    }
    CefURLRequest::Create(request, new FetchClient(completion), self->_context);
  }];
}

+ (void)setPreference:(NSString*)name value:(id)value {
  GlobalPreferences()[name] = value;
  for (OACProfile* profile in AllProfiles()) {
    if (profile.isReady) {
      ApplyPreference(profile->_context, name, value);
    }
  }
}

- (CefRefPtr<CefRequestContext>)cefContext {
  return _context;
}

@end
