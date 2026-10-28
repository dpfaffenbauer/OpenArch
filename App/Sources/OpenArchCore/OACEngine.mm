#import "OACEngine.h"
#import "OACInternal.h"

#include <crt_externs.h>

#include <set>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

CefScopedLibraryLoader* g_library_loader = nullptr;
std::vector<CefRefPtr<CefBrowser>> g_browsers;
std::set<int> g_refusing_close;  // Self-test only.
bool g_quitting = false;
bool g_loop_quit = false;
bool g_loop_returned = false;
NSString* g_root_cache_path = @"";
bool g_ready = false;
int g_remote_debugging_port = 0;
NSMutableArray<dispatch_block_t>* g_ready_blocks;
void (^g_relaunch_handler)(NSArray<NSString*>*) = nil;

void QuitMessageLoopOnce() {
  if (g_loop_quit) {
    return;
  }
  g_loop_quit = true;
  CefQuitMessageLoop();
}

class OACApp : public CefApp, public CefBrowserProcessHandler {
 public:
  OACApp(std::vector<std::string> extension_paths,
         bool use_mock_keychain,
         std::vector<std::string> extra_switches)
      : extension_paths_(std::move(extension_paths)),
        use_mock_keychain_(use_mock_keychain),
        extra_switches_(std::move(extra_switches)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;
    }
    if (use_mock_keychain_) {
      command_line->AppendSwitch("use-mock-keychain");
    }
    for (const auto& entry : extra_switches_) {
      const auto equals = entry.find('=');
      if (equals == std::string::npos) {
        command_line->AppendSwitch(entry);
      } else {
        command_line->AppendSwitchWithValue(entry.substr(0, equals),
                                            entry.substr(equals + 1));
      }
    }
    if (!extension_paths_.empty()) {
      std::string joined;
      for (const auto& path : extension_paths_) {
        joined += (joined.empty() ? "" : ",") + path;
      }
      command_line->AppendSwitchWithValue("load-extension", joined);
      // Chromium 137+ ignores --load-extension unless this feature is off.
      DisableFeature(command_line, "DisableLoadExtensionCommandLineSwitch");
    }
  }

  // Appending a switch replaces its value, and CEF already uses
  // --disable-features for Chrome features it does not support (Glic, the
  // Actor UI). Overwriting that list crashes Views-hosted browsers.
  static void DisableFeature(CefRefPtr<CefCommandLine> command_line,
                             const std::string& feature) {
    std::string features =
        command_line->GetSwitchValue("disable-features").ToString();
    features += (features.empty() ? "" : ",") + feature;
    command_line->AppendSwitchWithValue("disable-features", features);
  }

  // CefBrowserProcessHandler

  void OnContextInitialized() override {
    g_ready = true;
    [OACProfile.defaultProfile oac_markReady];
    NSArray<dispatch_block_t>* blocks = [g_ready_blocks copy];
    g_ready_blocks = nil;
    for (dispatch_block_t block in blocks) {
      block();
    }
  }

  CefRefPtr<CefClient> GetDefaultClient() override {
    return OACCreateDefaultClient();
  }

  bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine> command_line,
                                   const CefString& current_directory) override {
    if (!g_relaunch_handler) {
      return false;
    }
    std::vector<CefString> arguments;
    command_line->GetArguments(arguments);
    NSMutableArray<NSString*>* list = [NSMutableArray array];
    for (const auto& argument : arguments) {
      [list addObject:OACToNSString(argument)];
    }
    g_relaunch_handler(list);
    return true;
  }

 private:
  std::vector<std::string> extension_paths_;
  bool use_mock_keychain_;
  std::vector<std::string> extra_switches_;

  IMPLEMENT_REFCOUNTING(OACApp);
};

}  // namespace

bool OACEngineIsReady() {
  return g_ready;
}

bool OACRemoteDebuggingEnabled() {
  return g_remote_debugging_port > 0;
}

NSString* OACRootCachePath() {
  return g_root_cache_path;
}

void OACBrowserCreated(CefRefPtr<CefBrowser> browser) {
  g_browsers.push_back(browser);
}

void OACSetRefusesToCloseForTesting(CefRefPtr<CefBrowser> browser, bool refuses) {
  if (refuses) {
    g_refusing_close.insert(browser->GetIdentifier());
  } else {
    g_refusing_close.erase(browser->GetIdentifier());
  }
}

void OACBrowserClosed(CefRefPtr<CefBrowser> browser) {
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
  if ([self.delegate respondsToSelector:@selector(applicationShouldTerminate:)] &&
      [self.delegate applicationShouldTerminate:self] == NSTerminateCancel) {
    return;
  }
  [OACEngine quit];
}

@end

@implementation OACEngineSettings

- (instancetype)init {
  if ((self = [super init])) {
    _rootCachePath = @"";
    _extensionPaths = @[];
    _extraSwitches = @[];
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
  // Pages, the GPU and the network service run in Chromium's sandbox; each
  // helper starts it (OpenArchHelper/main.cc).
  settings.no_sandbox = false;
  settings.persist_session_cookies = true;
  settings.remote_debugging_port = (int)engineSettings.remoteDebuggingPort;
  g_remote_debugging_port = settings.remote_debugging_port;
  CefString(&settings.root_cache_path) = g_root_cache_path.UTF8String;
  CefString(&settings.cache_path) =
      [g_root_cache_path stringByAppendingPathComponent:@"Default"].UTF8String;

  std::vector<std::string> extension_paths;
  for (NSString* path in engineSettings.extensionPaths) {
    extension_paths.emplace_back(path.UTF8String);
  }
  std::vector<std::string> extra_switches;
  for (NSString* entry in engineSettings.extraSwitches) {
    extra_switches.emplace_back(entry.UTF8String);
  }
  CefRefPtr<OACApp> app(new OACApp(std::move(extension_paths),
                                   engineSettings.useMockKeychain,
                                   std::move(extra_switches)));
  return CefInitialize(main_args, settings, app.get(), nullptr);
}

+ (void (^)(NSArray<NSString*>*))relaunchHandler {
  return g_relaunch_handler;
}

+ (void)setRelaunchHandler:(void (^)(NSArray<NSString*>*))handler {
  g_relaunch_handler = [handler copy];
}

+ (void)whenReady:(dispatch_block_t)block {
  if (g_ready) {
    block();
    return;
  }
  if (!g_ready_blocks) {
    g_ready_blocks = [NSMutableArray array];
  }
  [g_ready_blocks addObject:block];
}

+ (void)runMessageLoop {
  CefRunMessageLoop();
  g_loop_returned = true;
}

+ (void)quit {
  if (g_quitting) {
    return;
  }
  g_quitting = true;
  // Chrome-style CEF ends its loop only once every browser window has
  // closed, whatever CefQuitMessageLoop says. A browser that ignores the
  // close would keep OpenArch running for good, and an update waiting for
  // it to quit, so it ends the hard way if Chromium has not stopped by then.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   if (!g_loop_returned) {
                     NSLog(@"OpenArch: Chromium did not stop, exiting");
                     _exit(0);
                   }
                 });
  if (g_browsers.empty()) {
    QuitMessageLoopOnce();
    return;
  }
  auto browsers = g_browsers;
  for (auto& browser : browsers) {
    if (g_refusing_close.count(browser->GetIdentifier())) {
      continue;
    }
    browser->GetHost()->CloseBrowser(true);
  }
  // Don't wait for a browser that fails to report back; name it, so the
  // log says which one it was.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   if (g_browsers.empty()) {
                     return;
                   }
                   for (auto& browser : g_browsers) {
                     CefRefPtr<CefFrame> frame = browser->GetMainFrame();
                     NSLog(@"OpenArch: did not close: %s%s",
                           frame ? frame->GetURL().ToString().c_str() : "?",
                           browser->IsPopup() ? " (popup)" : "");
                   }
                   NSLog(@"OpenArch: %zu browser(s) did not close, quitting",
                         g_browsers.size());
                   g_browsers.clear();
                   QuitMessageLoopOnce();
                 });
}

+ (void)shutdown {
  CefShutdown();
}

+ (NSInteger)remoteDebuggingPort {
  return g_remote_debugging_port;
}

+ (NSString*)versionString {
  return @CEF_VERSION;
}

@end
