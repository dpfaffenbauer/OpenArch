// The OpenArch spike embedder: with --openarch-embedder, Chrome opens no
// browser window of its own (pass --no-startup-window too) and this shows
// all tabs as WebContents in one plain AppKit window, the layout of
// OpenArch's main window: 992×784 pt, the page area right of a 300 pt
// sidebar, 8 pt inset (BrowserWindowController.contentRect).
//
// --memory-bench <file> does what OpenArch's SelfTest.memoryBench does: one
// tab per URL, each shown for 1.5 s in turn so all of them load, then the
// first one in front, then prints "STEP bench ready"; scripts/memory-bench.sh
// measures from outside.

#import <AppKit/AppKit.h>

#include <stdio.h>

#include <memory>
#include <string>
#include <vector>

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "openarch/pane.h"

namespace openarch {
namespace {

constexpr char kEmbedderSwitch[] = "openarch-embedder";
constexpr char kBenchSwitch[] = "memory-bench";

constexpr double kWindowWidth = 992, kWindowHeight = 784;
constexpr double kSidebarWidth = 300, kInset = 8;

class EmbedderParts : public ChromeBrowserMainExtraParts {
 public:
  void PostBrowserStart() override {
    Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
    if (!profile) {
      fprintf(stderr, "[openarch] no profile loaded\n");
      return;
    }
    profile_ = profile;
    window_ = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(40, 40, kWindowWidth, kWindowHeight)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window_.releasedWhenClosed = NO;
    window_.titlebarAppearsTransparent = YES;
    window_.title = @"OpenArch (Chromium spike)";
    [window_ makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    const base::CommandLine& command_line = *base::CommandLine::ForCurrentProcess();
    if (!command_line.HasSwitch(kBenchSwitch)) {
      Open(/*bench=*/false, {"https://www.chromium.org/"});
      return;
    }
    // "--memory-bench <file>" (as scripts/memory-bench.sh passes it) leaves
    // the switch empty and the file as the first argument.
    base::FilePath file = command_line.GetSwitchValuePath(kBenchSwitch);
    if (file.empty() && !command_line.GetArgs().empty()) {
      file = base::FilePath(command_line.GetArgs()[0]);
    }
    // The UI thread may not block, so the file is read in the thread pool.
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock()},
        base::BindOnce(
            [](base::FilePath path) {
              std::string text;
              base::ReadFileToString(path, &text);
              std::vector<std::string> urls;
              for (const auto& line : base::SplitString(
                       text, "\n", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
                if (!base::StartsWith(line, "#")) {
                  urls.push_back(line);
                }
              }
              return urls;
            },
            file),
        base::BindOnce(&EmbedderParts::Open, base::Unretained(this), /*bench=*/true));
  }

  void PostMainMessageLoopRun() override {
    panes_.clear();
    [window_ close];
    window_ = nil;
  }

 private:
  void Open(bool bench, std::vector<std::string> urls) {
    if (urls.empty()) {
      fprintf(stderr, "[openarch] no URLs\n");
      return;
    }
    for (const auto& url : urls) {
      panes_.push_back(std::make_unique<Pane>(profile_, url));
    }
    Select(0, bench);
  }

  // Shows pane |index| and hides the one shown before, like selecting a tab.
  // In the bench, goes on to the next one after 1.5 s; after the last, back
  // to the first, then reports ready.
  void Select(size_t index, bool bench) {
    if (index >= panes_.size()) {
      Show(0);
      printf("[selftest] STEP bench ready %zu tabs\n", panes_.size());
      fflush(stdout);
      return;
    }
    Show(index);
    if (bench) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
          FROM_HERE,
          base::BindOnce(&EmbedderParts::Select, base::Unretained(this), index + 1, bench),
          base::Milliseconds(1500));
    }
  }

  void Show(size_t index) {
    for (size_t i = 0; i < panes_.size(); ++i) {
      if (i != index) {
        panes_[i]->Hide();
      }
    }
    panes_[index]->ShowInWindow(window_, kSidebarWidth, kInset,
                                kWindowWidth - kSidebarWidth - kInset,
                                kWindowHeight - 2 * kInset);
  }

  raw_ptr<Profile> profile_ = nullptr;
  NSWindow* __strong window_ = nil;
  std::vector<std::unique_ptr<Pane>> panes_;
};

}  // namespace

// Called from ChromeContentBrowserClient::CreateBrowserMainParts (the one
// hook in Chrome's code, see ../setup.sh). Null without --openarch-embedder.
std::unique_ptr<ChromeBrowserMainExtraParts> CreateEmbedderParts() {
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch(kEmbedderSwitch)) {
    return nullptr;
  }
  return std::make_unique<EmbedderParts>();
}

}  // namespace openarch
