// C++-facing internals shared between the OpenArchCore .mm files.

#import "OACProfile.h"

#include "include/cef_browser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"

@interface OACProfile (Internal)
- (CefRefPtr<CefRequestContext>)cefContext;
@end

/// Directory passed as root_cache_path; profiles must live below it.
NSString* OACRootCachePath();

/// Bookkeeping so that quitting can wait until every browser has closed.
void OACBrowserCreated(CefRefPtr<CefBrowser> browser);
void OACBrowserClosed(CefRefPtr<CefBrowser> browser);

inline NSString* OACToNSString(const CefString& string) {
  return [NSString stringWithUTF8String:string.ToString().c_str()];
}
