// OpenArch's hooks into Chrome's start-up (engine/chromium in the OpenArch
// repository, docs/chromium-engine.md). //openarch sets them before
// ChromeMain runs; Chrome itself never does, so nothing here changes
// Chrome's behaviour.
#ifndef CHROME_BROWSER_OPENARCH_ENGINE_HOOKS_H_
#define CHROME_BROWSER_OPENARCH_ENGINE_HOOKS_H_

#include <memory>

#include "ui/base/window_open_disposition.h"

class BrowserWindow;
class BrowserWindowInterface;
class ChromeBrowserMainExtraParts;
class GURL;

namespace base {
class CommandLine;
}

namespace content {
class NavigationThrottleRegistry;
class WebContents;
}
namespace input {
struct NativeWebKeyboardEvent;
}
namespace content {
struct ContextMenuParams;
}
namespace ui {
class SimpleMenuModel;
}

namespace openarch {

// OpenArch's part of the browser process's start-up, added after Chrome's
// own parts.
using ExtraPartsFactory = std::unique_ptr<ChromeBrowserMainExtraParts> (*)();
inline ExtraPartsFactory g_extra_parts_factory = nullptr;

// OpenArch's app made NSApp, its delegate and its main menu before
// ChromeMain: Chrome's AppController (NSApp's delegate in Chrome) and
// Chrome's main menu are never made (chrome_browser_main_mac.mm).
inline bool g_embedder_owns_app = false;

// A page asks for a URL in another tab or window: a ⌘-click or middle click
// (OpenURLFromTab) or a link with target=_blank or window.open as a tab
// (AddNewContents, before the new WebContents is added). Returns true when
// OpenArch takes it: its sidebar opens the tab, Chrome's (hidden) window
// gets nothing. Real popups (window.open with features) stay Chrome's.
using NewTabHook = bool (*)(content::WebContents* source,
                            const GURL& url,
                            WindowOpenDisposition disposition);
inline NewTabHook g_new_tab_hook = nullptr;

// A key in a page OpenArch shows: before the page sees it (`unhandled`
// false) or after the page left it (true). Returns -1 for a page that isn't
// OpenArch's, which keeps Chrome's handling; else 1 handled, 0 not handled.
// OpenArch's menus get the shortcuts, not the hidden Chrome window's.
using KeyHook = int (*)(content::WebContents* source,
                        const input::NativeWebKeyboardEvent& event,
                        bool unhandled);
inline KeyHook g_key_hook = nullptr;

// Adds OpenArch's navigation throttle (links OpenArch shows in Peek, links
// to other apps) to every navigation.
using NavigationThrottleHook = void (*)(content::NavigationThrottleRegistry& registry);
inline NavigationThrottleHook g_navigation_throttle_hook = nullptr;

// Whether a page counts as the one in front, for JavaScript dialogs
// (alert, confirm, beforeunload) and file choosers, which Chrome shows only
// for its window's active tab: -1 for a page that isn't OpenArch's, else 1
// (on screen) or 0.
using PageForemostHook = int (*)(content::WebContents* contents);
inline PageForemostHook g_page_foremost_hook = nullptr;

// The page's context menu (Chrome's RenderViewContextMenu): OpenArch adds
// its own items (Ask about selection) with ids from kFirstMenuCommand up,
// and runs them.
inline constexpr int kFirstMenuCommand = 71001;
inline constexpr int kLastMenuCommand = 71099;
using ContextMenuHook = void (*)(content::WebContents* contents,
                                 const content::ContextMenuParams& params,
                                 ui::SimpleMenuModel* menu);
inline ContextMenuHook g_context_menu_hook = nullptr;
using ContextMenuCommandHook = void (*)(content::WebContents* contents,
                                        const content::ContextMenuParams& params,
                                        int command);
inline ContextMenuCommandHook g_context_menu_command_hook = nullptr;

// OpenArch was launched again while running: the new launch's command line
// (Chrome's process singleton hands it over) goes to OpenArch instead of
// opening a Chrome window.
using RelaunchHook = void (*)(const base::CommandLine& command_line);
inline RelaunchHook g_relaunch_hook = nullptr;

// The window of a Browser Chrome makes (BrowserWindow::CreateBrowserWindow):
// OpenArch's own, without a native window, for the Browsers that hold
// OpenArch's pages; nullptr leaves Chrome's window for every other.
using BrowserWindowHook = BrowserWindow* (*)(BrowserWindowInterface* browser);
inline BrowserWindowHook g_browser_window_hook = nullptr;

}  // namespace openarch

#endif  // CHROME_BROWSER_OPENARCH_ENGINE_HOOKS_H_
