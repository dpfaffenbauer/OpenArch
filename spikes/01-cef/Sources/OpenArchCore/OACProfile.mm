#import "OACProfile.h"
#import "OACInternal.h"

@implementation OACProfile {
  CefRefPtr<CefRequestContext> _context;
}

+ (OACProfile*)defaultProfile {
  static OACProfile* profile;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    profile = [[OACProfile alloc]
        initWithContext:CefRequestContext::GetGlobalContext()
             identifier:@"Default"];
  });
  return profile;
}

- (instancetype)initWithIdentifier:(NSString*)identifier {
  // Chrome only accepts profiles that are direct children of the user data
  // directory (root_cache_path), like its own "Default" or "Profile 1".
  NSString* path = [OACRootCachePath()
      stringByAppendingPathComponent:[@"Space-" stringByAppendingString:identifier]];
  CefRequestContextSettings settings;
  settings.persist_session_cookies = true;
  CefString(&settings.cache_path) = path.UTF8String;
  return [self initWithContext:CefRequestContext::CreateContext(settings, nullptr)
                    identifier:identifier];
}

- (instancetype)initWithContext:(CefRefPtr<CefRequestContext>)context
                     identifier:(NSString*)identifier {
  if ((self = [super init])) {
    _context = context;
    _identifier = [identifier copy];
  }
  return self;
}

- (CefRefPtr<CefRequestContext>)cefContext {
  return _context;
}

@end
