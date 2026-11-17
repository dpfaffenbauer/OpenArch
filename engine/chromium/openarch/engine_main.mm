// OpenArchEngineMain: OpenArch's entry into Chrome's framework. Sets
// OpenArch's start-up hooks, then runs Chrome's own ChromeMain, which owns
// the process until quit. Exported by chrome/app/framework.exports
// (engine/chromium/apply.sh).

#include <memory>
#include <string>
#include <vector>

#include "base/command_line.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/openarch_engine_hooks.h"
#include "openarch/internal.h"

extern "C" int ChromeMain(int argc, const char** argv);

namespace {

class OpenArchParts : public ChromeBrowserMainExtraParts {
 public:
  void PostBrowserStart() override { openarch::RunReadyBlocks(); }
  void PostMainMessageLoopRun() override { openarch::StopBridge(); }
};

std::unique_ptr<ChromeBrowserMainExtraParts> MakeOpenArchParts() {
  return std::make_unique<OpenArchParts>();
}

}  // namespace

extern "C" __attribute__((visibility("default"))) int OpenArchEngineMain(int argc,
                                                                         const char** argv) {
  openarch::g_extra_parts_factory = &MakeOpenArchParts;
  openarch::g_embedder_owns_app = true;
  // Live for the whole process (Chromium keeps argv); never freed.
  auto& args = *new std::vector<std::string>(openarch::EngineArguments(argc, argv));
  auto& pointers = *new std::vector<const char*>();
  for (const std::string& arg : args) {
    pointers.push_back(arg.c_str());
  }
  // The placeholder +[OACApplication load] made goes; Chrome reads this one.
  if (base::CommandLine::InitializedForCurrentProcess()) {
    base::CommandLine::Reset();
  }
  return ChromeMain(static_cast<int>(pointers.size()), pointers.data());
}
