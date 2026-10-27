// C++-facing internals shared between the OpenArchCore .mm files.

#import "OACProfile.h"

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"

@interface OACProfile (Internal)
- (CefRefPtr<CefRequestContext>)cefContext;
- (void)oac_markReady;
@end

/// Whether Chromium's global context (and the default profile) is ready.
bool OACEngineIsReady();

/// Whether the DevTools protocol port is open (AI / automation control).
bool OACRemoteDebuggingEnabled();

/// Directory passed as root_cache_path; profiles must live below it.
NSString* OACRootCachePath();

/// Bookkeeping so that quitting can wait until every browser has closed.
void OACBrowserCreated(CefRefPtr<CefBrowser> browser);
void OACBrowserClosed(CefRefPtr<CefBrowser> browser);

/// Client for browsers Chrome creates on its own (windows opened from
/// Chrome UI or extensions). Only tracks them so quitting can close them.
CefRefPtr<CefClient> OACCreateDefaultClient();

inline NSString* OACToNSString(const CefString& string) {
  return [NSString stringWithUTF8String:string.ToString().c_str()];
}
