// OACApplication, OACEngineSettings and OACEngine on Chrome's framework.

#include "openarch/internal.h"

#include <crt_externs.h>

#include <memory>
#include <string>
#include <vector>

#include "base/command_line.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/os_crypt/common/keychain_password_mac.h"
#include "chrome/browser/openarch_engine_hooks.h"
#include "components/version_info/version_info.h"

extern "C" int OpenArchEngineMain(int argc, const char** argv);

namespace {

OACEngineSettings* g_settings = nil;
NSMutableArray<dispatch_block_t>* g_ready_blocks = nil;
bool g_ready = false;
void (^g_relaunch_handler)(NSArray<NSString*>*) = nil;
// What AppController holds in Chrome: without it Chrome quits once no
// browser window is left, and OpenArch's pages live in hidden ones.
ScopedKeepAlive* g_keep_alive = nullptr;

}  // namespace

namespace openarch {

std::string ToStdString(NSString* string) {
  return string ? base::SysNSStringToUTF8(string) : std::string();
}

NSString* ToNSString(const std::string& string) {
  return base::SysUTF8ToNSString(string);
}

NSString* ToNSString(const std::u16string& string) {
  return base::SysUTF16ToNSString(string);
}

bool IsReady() {
  return g_ready;
}

void Relaunched(const base::CommandLine& command_line) {
  if (!g_relaunch_handler) {
    return;
  }
  NSMutableArray<NSString*>* arguments = [NSMutableArray array];
  for (const auto& argument : command_line.argv()) {
    [arguments addObject:ToNSString(argument)];
  }
  g_relaunch_handler(arguments);
}

void RunReadyBlocks() {
  g_relaunch_hook = &Relaunched;
  g_keep_alive = new ScopedKeepAlive(KeepAliveOrigin::APP_CONTROLLER,
                                     KeepAliveRestartOption::DISABLED);
  InstallPaneHooks();
  InstallDialogHooks();
  g_ready = true;
  NSArray<dispatch_block_t>* blocks = [g_ready_blocks copy];
  g_ready_blocks = nil;
  for (dispatch_block_t block in blocks) {
    block();
  }
}

void StopBridge() {
  delete g_keep_alive;
  g_keep_alive = nullptr;
}

std::vector<std::string> EngineArguments(int argc, const char** argv) {
  std::vector<std::string> args(argv, argv + argc);
  if (!g_settings) {
    return args;
  }
  // OpenArch makes its own windows; Chrome opens none at start-up.
  args.push_back("--no-startup-window");
  args.push_back("--no-first-run");
  args.push_back("--no-default-browser-check");
  // Chrome starts on the profile used last otherwise (Local State's
  // profile.last_used); OpenArch's default profile is "Default".
  args.push_back("--profile-directory=Default");
  if (g_settings.rootCachePath.length) {
    args.push_back("--user-data-dir=" + ToStdString(g_settings.rootCachePath));
  }
  if (g_settings.remoteDebuggingPort > 0) {
    args.push_back("--remote-debugging-port=" +
                   std::to_string(g_settings.remoteDebuggingPort));
  }
  if (g_settings.useMockKeychain) {
    args.push_back("--use-mock-keychain");
  } else {
    // The login keychain item with the encryption key, OpenArch's
    // ("OpenArch Safe Storage"), not Chromium's.
    if (g_settings.keychainServiceName.length) {
      KeychainPassword::GetServiceName() = ToStdString(g_settings.keychainServiceName);
    }
    if (g_settings.keychainAccountName.length) {
      KeychainPassword::GetAccountName() = ToStdString(g_settings.keychainAccountName);
    }
  }
  std::vector<std::string> features_off;
  if (g_settings.extensionPaths.count) {
    std::vector<std::string> paths;
    for (NSString* path in g_settings.extensionPaths) {
      paths.push_back(ToStdString(path));
    }
    args.push_back("--load-extension=" + base::JoinString(paths, ","));
    // Chromium 137+ ignores --load-extension unless this feature is off.
    features_off.push_back("DisableLoadExtensionCommandLineSwitch");
  }
  for (NSString* entry in g_settings.extraSwitches) {
    std::string value = ToStdString(entry);
    if (base::StartsWith(value, "disable-features=")) {
      features_off.push_back(value.substr(strlen("disable-features=")));
      continue;
    }
    args.push_back("--" + value);
  }
  if (!features_off.empty()) {
    args.push_back("--disable-features=" + base::JoinString(features_off, ","));
  }
  return args;
}

}  // namespace openarch

@implementation OACApplication

+ (void)load {
  // Chrome's application class reads the command line while NSApp is made,
  // before ChromeMain sets it up; OpenArchEngineMain replaces this one.
  if (!base::CommandLine::InitializedForCurrentProcess()) {
    base::CommandLine::Init(*_NSGetArgc(), *_NSGetArgv());
  }
}

// BrowserCrApplication asks Chrome's AppController to terminate, which
// OpenArch doesn't have (making it would replace OpenArch's delegate).
// Instead: ask OpenArch's delegate, then close every browser and quit.
- (void)terminate:(id)sender {
  if ([self.delegate respondsToSelector:@selector(applicationShouldTerminate:)] &&
      [self.delegate applicationShouldTerminate:self] == NSTerminateCancel) {
    return;
  }
  [OACEngine quit];
}

- (void)cancelTerminate:(id)sender {
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
  // Linked at launch: nothing to load.
  return YES;
}

+ (BOOL)startWithSettings:(OACEngineSettings*)settings {
  g_settings = settings;
  return YES;
}

+ (void)whenReady:(dispatch_block_t)block {
  if (g_ready) {
    block();
    return;
  }
  if (!g_ready_blocks) {
    g_ready_blocks = [NSMutableArray array];
  }
  [g_ready_blocks addObject:[block copy]];
}

+ (void)runMessageLoop {
  // Chrome runs the whole browser, start to quit, and returns here.
  OpenArchEngineMain(*_NSGetArgc(), const_cast<const char**>(*_NSGetArgv()));
}

+ (void)quit {
  if (!g_ready) {
    return;
  }
  // Chrome ends once nothing keeps it alive: let go of what stood in for
  // AppController's keep-alive, or quitting would wait for it forever.
  delete g_keep_alive;
  g_keep_alive = nullptr;
  chrome::CloseAllBrowsersAndQuit();
}

+ (void)shutdown {
  // ChromeMain has shut Chromium down already.
}

+ (NSString*)versionString {
  return openarch::ToNSString(std::string(version_info::GetVersionNumber()));
}

+ (NSInteger)remoteDebuggingPort {
  return g_settings ? g_settings.remoteDebuggingPort : 0;
}

+ (void (^)(NSArray<NSString*>*))relaunchHandler {
  return g_relaunch_handler;
}

+ (void)setRelaunchHandler:(void (^)(NSArray<NSString*>*))handler {
  g_relaunch_handler = [handler copy];
}

@end
