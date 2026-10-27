#import "OACEngine.h"
#import "OACInternal.h"

#include <crt_externs.h>

#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

CefScopedLibraryLoader* g_library_loader = nullptr;
std::vector<CefRefPtr<CefBrowser>> g_browsers;
bool g_quitting = false;
bool g_loop_quit = false;
NSString* g_root_cache_path = @"";

void QuitMessageLoopOnce() {
  if (g_loop_quit) {
    return;
  }
  g_loop_quit = true;
  CefQuitMessageLoop();
}

class OACApp : public CefApp {
 public:
  explicit OACApp(std::vector<std::string> extension_paths)
      : extension_paths_(std::move(extension_paths)) {}

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;
    }
    // Unsigned dev builds would otherwise prompt for "Safe Storage" keychain
    // access on every launch.
    command_line->AppendSwitch("use-mock-keychain");

    if (!extension_paths_.empty()) {
      std::string joined;
      for (const auto& path : extension_paths_) {
        joined += (joined.empty() ? "" : ",") + path;
      }
      command_line->AppendSwitchWithValue("load-extension", joined);
      // Chromium 137+ ignores --load-extension unless this feature is off.
      command_line->AppendSwitchWithValue(
          "disable-features", "DisableLoadExtensionCommandLineSwitch");
    }
  }

 private:
  std::vector<std::string> extension_paths_;

  IMPLEMENT_REFCOUNTING(OACApp);
};

}  // namespace

NSString* OACRootCachePath() {
  return g_root_cache_path;
}

void OACBrowserCreated(CefRefPtr<CefBrowser> browser) {
  g_browsers.push_back(browser);
}

void OACBrowserClosed(CefRefPtr<CefBrowser> browser) {
  fprintf(stderr, "[OpenArchCore] browser %d closed\n", browser->GetIdentifier());
  std::erase_if(g_browsers, [&](const CefRefPtr<CefBrowser>& candidate) {
    return candidate->IsSame(browser);
  });
  if (g_quitting && g_browsers.empty()) {
    QuitMessageLoopOnce();
  }
}

@interface OACApplication () <CefAppProtocol>
@end

@implementation OACApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// AppKit would exit the process right away; Chromium has to close its
// browsers and shut down first.
- (void)terminate:(id)sender {
  [OACEngine quit];
}

@end

@implementation OACEngineSettings

- (instancetype)init {
  if ((self = [super init])) {
    _rootCachePath = @"";
    _extensionPaths = @[];
  }
  return self;
}

@end

@implementation OACEngine

+ (BOOL)loadFramework {
  if (g_library_loader) {
    return YES;
  }
  g_library_loader = new CefScopedLibraryLoader();
  return g_library_loader->LoadInMain();
}

+ (BOOL)startWithSettings:(OACEngineSettings*)engineSettings {
  NSAssert([NSApp isKindOfClass:OACApplication.class],
           @"NSApp must be an OACApplication before starting the engine");
  g_root_cache_path = [engineSettings.rootCachePath copy];

  CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());

  CefSettings settings;
  settings.no_sandbox = true;
  settings.persist_session_cookies = true;
  settings.remote_debugging_port = (int)engineSettings.remoteDebuggingPort;
  CefString(&settings.root_cache_path) = g_root_cache_path.UTF8String;
  CefString(&settings.cache_path) =
      [g_root_cache_path stringByAppendingPathComponent:@"Default"].UTF8String;

  std::vector<std::string> extension_paths;
  for (NSString* path in engineSettings.extensionPaths) {
    extension_paths.emplace_back(path.UTF8String);
  }
  CefRefPtr<OACApp> app(new OACApp(std::move(extension_paths)));
  return CefInitialize(main_args, settings, app.get(), nullptr);
}

+ (void)runMessageLoop {
  CefRunMessageLoop();
}

+ (void)quit {
  if (g_quitting) {
    return;
  }
  g_quitting = true;
  if (g_browsers.empty()) {
    QuitMessageLoopOnce();
    return;
  }
  auto browsers = g_browsers;
  for (auto& browser : browsers) {
    browser->GetHost()->CloseBrowser(true);
  }
  // Spike safety net: never hang on quit if a browser fails to report back.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   if (!g_browsers.empty()) {
                     NSLog(@"OpenArch: %zu browser(s) did not close, quitting",
                           g_browsers.size());
                     g_browsers.clear();
                     QuitMessageLoopOnce();
                   }
                 });
}

+ (void)shutdown {
  CefShutdown();
}

+ (NSString*)versionString {
  return @CEF_VERSION;
}

@end
