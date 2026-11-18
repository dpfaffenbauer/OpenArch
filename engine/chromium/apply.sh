#!/usr/bin/env bash
# apply.sh <chromium src>: puts OpenArch's engine layer into a Chromium
# checkout (docs/chromium-engine.md). Running it again changes nothing.
#
#   - copies engine/chromium/openarch to <src>/openarch (//openarch:core)
#     and the bridge's headers from App/Sources/OpenArchCore/include
#   - Chrome's hooks: chrome/browser/openarch_engine_hooks.h and
#     ui/views/controls/webview/openarch_hosted_page.h;
#     ChromeBrowserMainParts::Create adds OpenArch's start-up part;
#     ChromeBrowserMainPartsMac leaves OpenArch's app delegate and menus
#     alone; Chrome's WebView leaves OpenArch's pages in OpenArch's windows;
#     the framework exports OpenArchEngineMain and the bridge's classes;
#     chrome_dll depends on //openarch:core
#
# Each hook fails with a message when the text it hooks into has moved, so
# a new Chrome version shows at once what to update.
set -euo pipefail

SRC="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
[[ -f "$SRC/chrome/app/chrome_main.cc" ]] || { echo "not a Chromium src: $SRC" >&2; exit 1; }

# Copied, not linked: a link out of the tree confuses gn's and clang's paths.
# --checksum keeps unchanged files' times, so a rerun rebuilds nothing.
rsync -a --checksum --delete --exclude include "$HERE/openarch/" "$SRC/openarch/"
rsync -a --checksum --delete "$REPO/App/Sources/OpenArchCore/include/" "$SRC/openarch/include/"
cmp -s "$HERE/hooks/openarch_engine_hooks.h" "$SRC/chrome/browser/openarch_engine_hooks.h" ||
  cp "$HERE/hooks/openarch_engine_hooks.h" "$SRC/chrome/browser/openarch_engine_hooks.h"
cmp -s "$HERE/hooks/openarch_permission_hook.h" "$SRC/chrome/browser/openarch_permission_hook.h" ||
  cp "$HERE/hooks/openarch_permission_hook.h" "$SRC/chrome/browser/openarch_permission_hook.h"
cmp -s "$HERE/hooks/openarch_hosted_page.h" "$SRC/ui/views/controls/webview/openarch_hosted_page.h" ||
  cp "$HERE/hooks/openarch_hosted_page.h" "$SRC/ui/views/controls/webview/openarch_hosted_page.h"

python3 -I - "$SRC" <<'EOF'
import sys
src = sys.argv[1]

def edit(path, old, new, done):
    p = f"{src}/{path}"
    s = open(p).read()
    if done in s:
        return
    if s.count(old) != 1:
        sys.exit(f"apply.sh: {path} doesn't have the expected text once; update the hook:\n{old}")
    open(p, "w").write(s.replace(old, new))
    print(f"hooked {path}")

hooks = '#include "chrome/browser/openarch_engine_hooks.h"\n'

# 1. OpenArch's start-up part, after Chrome's.
main = "chrome/browser/chrome_browser_main.cc"
notifier = '''  main_parts->AddParts(
      std::make_unique<ChromeBrowserMainExtraPartsThreadNotifier>(
          std::move(threads_ready_closure)));
'''
edit(main, notifier, notifier + '''  if (openarch::g_extra_parts_factory) {  // OpenArch
    main_parts->AddParts(openarch::g_extra_parts_factory());
  }
''', "openarch::g_extra_parts_factory")
edit(main, '#include "chrome/browser/chrome_browser_main.h"\n',
     '#include "chrome/browser/chrome_browser_main.h"\n' + hooks, hooks)

# 2. OpenArch's app keeps its own delegate and main menu.
mac = "chrome/browser/chrome_browser_main_mac.mm"
edit(mac, '#include "chrome/browser/chrome_browser_main_mac.h"\n',
     '#include "chrome/browser/chrome_browser_main_mac.h"\n' + hooks, hooks)
edit(mac, '''  // Create the app delegate by requesting the shared AppController.
  CHECK_EQ(nil, NSApp.delegate);''', '''  // OpenArch's app keeps its own delegate and main menu.
  if (openarch::g_embedder_owns_app) {
    return content::RESULT_CODE_NORMAL_EXIT;
  }

  // Create the app delegate by requesting the shared AppController.
  CHECK_EQ(nil, NSApp.delegate);''', "OpenArch's app keeps its own delegate")
edit(mac, '''void ChromeBrowserMainPartsMac::DidEndMainMessageLoop() {
  [AppController.sharedController didEndMainMessageLoop];''', '''void ChromeBrowserMainPartsMac::DidEndMainMessageLoop() {
  if (openarch::g_embedder_owns_app) {
    return;
  }
  [AppController.sharedController didEndMainMessageLoop];''',
     "if (openarch::g_embedder_owns_app) {\n    return;\n  }\n  [AppController")

# Chrome's windows (DevTools) ask AppController about modal windows, which
# would make it and replace OpenArch's delegate.
widget = "chrome/browser/ui/views/frame/browser_native_widget_mac.mm"
edit(widget, "      result->enable &= ![AppController.sharedController keyWindowIsModal];",
     "      result->enable &= openarch::g_embedder_owns_app ||  // OpenArch\n"
     "                        ![AppController.sharedController keyWindowIsModal];",
     "openarch::g_embedder_owns_app ||")
edit(widget, '#import "chrome/browser/ui/views/frame/browser_native_widget_mac.h"\n',
     '#import "chrome/browser/ui/views/frame/browser_native_widget_mac.h"\n' + hooks, hooks)

# New tabs and keys from OpenArch's pages go to OpenArch, not to the hidden
# Chrome window holding them.
wcd = "chrome/browser/ui/browser_web_contents_delegate/browser_web_contents_delegate.cc"
edit(wcd, '#include "chrome/browser/ui/browser_web_contents_delegate/browser_web_contents_delegate.h"\n',
     '#include "chrome/browser/ui/browser_web_contents_delegate/browser_web_contents_delegate.h"\n' + hooks, hooks)
edit(wcd, '''#if DCHECK_IS_ON()
  CHECK(params.Valid(), base::NotFatalUntil::M162);
#endif
''', '''#if DCHECK_IS_ON()
  CHECK(params.Valid(), base::NotFatalUntil::M162);
#endif
  if (openarch::g_new_tab_hook &&  // OpenArch
      openarch::g_new_tab_hook(source, params.url, params.disposition)) {
    return nullptr;
  }
''', "openarch::g_new_tab_hook(source, params.url")
edit(wcd, '''    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture,
    bool* was_blocked) {
''', '''    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture,
    bool* was_blocked) {
  if (openarch::g_new_tab_hook &&  // OpenArch
      openarch::g_new_tab_hook(source, target_url, disposition)) {
    return nullptr;
  }
''', "openarch::g_new_tab_hook(source, target_url")
edit(wcd, '''    const input::NativeWebKeyboardEvent& event) {
  // Forward keyboard events to the manager for fullscreen / mouse lock. This
''', '''    const input::NativeWebKeyboardEvent& event) {
  if (openarch::g_key_hook) {  // OpenArch
    int handled = openarch::g_key_hook(source, event, /*unhandled=*/false);
    if (handled >= 0) {
      return handled ? content::KeyboardEventProcessingResult::HANDLED
                     : content::KeyboardEventProcessingResult::NOT_HANDLED;
    }
  }
  // Forward keyboard events to the manager for fullscreen / mouse lock. This
''', "openarch::g_key_hook(source, event, /*unhandled=*/false)")
edit(wcd, '''    const input::NativeWebKeyboardEvent& event) {
  DevToolsWindow* devtools_window =
''', '''    const input::NativeWebKeyboardEvent& event) {
  if (openarch::g_key_hook) {  // OpenArch
    int handled = openarch::g_key_hook(source, event, /*unhandled=*/true);
    if (handled >= 0) {
      return handled == 1;
    }
  }
  DevToolsWindow* devtools_window =
''', "openarch::g_key_hook(source, event, /*unhandled=*/true)")

ccbc = "chrome/browser/chrome_content_browser_client.cc"
edit(ccbc, '''    content::NavigationThrottleRegistry& registry) {
  CreateAndAddChromeThrottlesForNavigation(registry);
}''', '''    content::NavigationThrottleRegistry& registry) {
  CreateAndAddChromeThrottlesForNavigation(registry);
  if (openarch::g_navigation_throttle_hook) {  // OpenArch
    openarch::g_navigation_throttle_hook(registry);
  }
}''', "openarch::g_navigation_throttle_hook(registry)")
edit(ccbc, '#include "chrome/browser/chrome_content_browser_client.h"\n',
     '#include "chrome/browser/chrome_content_browser_client.h"\n' + hooks, hooks)

# JavaScript dialogs of OpenArch's pages: shown when the page is on screen.
jsd = "chrome/browser/ui/javascript_dialogs/javascript_tab_modal_dialog_manager_delegate_desktop.cc"
edit(jsd, '''bool JavaScriptTabModalDialogManagerDelegateDesktop::IsWebContentsForemost() {
''', '''bool JavaScriptTabModalDialogManagerDelegateDesktop::IsWebContentsForemost() {
  if (openarch::g_page_foremost_hook) {  // OpenArch
    int foremost = openarch::g_page_foremost_hook(web_contents_);
    if (foremost >= 0) {
      return foremost == 1;
    }
  }
''', "openarch::g_page_foremost_hook(web_contents_)")
edit(jsd, '#include "chrome/browser/ui/javascript_dialogs/javascript_tab_modal_dialog_manager_delegate_desktop.h"\n',
     '#include "chrome/browser/ui/javascript_dialogs/javascript_tab_modal_dialog_manager_delegate_desktop.h"\n' + hooks, hooks)

# File choosers (<input type=file>, showOpenFilePicker): Chrome shows one
# only for its window's active tab, and OpenArch's pages on screen aren't
# the active tab of the hidden window holding them (any pane on screen can
# ask). For OpenArch's pages, being on screen is what counts.
fsh = "chrome/browser/file_select_helper.cc"
edit(fsh, '''  if (tab && !tab->IsActivated()) {
    RunFileChooserEnd();
    return;
  }''', '''  int openarch_foremost = openarch::g_page_foremost_hook  // OpenArch
                              ? openarch::g_page_foremost_hook(web_contents_)
                              : -1;
  if (openarch_foremost == 0 ||
      (openarch_foremost < 0 && tab && !tab->IsActivated())) {
    RunFileChooserEnd();
    return;
  }''', "int openarch_foremost")
edit(fsh, '#include "chrome/browser/file_select_helper.h"\n',
     '#include "chrome/browser/file_select_helper.h"\n' + hooks, hooks)

# Permission prompts of OpenArch's pages are OpenArch's.
ppf = "chrome/browser/ui/views/permissions/permission_prompt_factory.cc"
edit(ppf, '''    permissions::PermissionPrompt::Delegate* delegate) {
  if (delegate->ShouldDropCurrentRequestIfCannotShowQuietly() &&''', '''    permissions::PermissionPrompt::Delegate* delegate) {
  if (openarch::g_permission_prompt_hook) {  // OpenArch
    if (auto prompt = openarch::g_permission_prompt_hook(web_contents, delegate)) {
      return prompt;
    }
  }
  if (delegate->ShouldDropCurrentRequestIfCannotShowQuietly() &&''', "openarch::g_permission_prompt_hook(web_contents, delegate)")
permission_hook = '#include "chrome/browser/openarch_permission_hook.h"\n'
edit(ppf, '#include "chrome/browser/ui/permission_bubble/permission_prompt.h"\n',
     '#include "chrome/browser/ui/permission_bubble/permission_prompt.h"\n' + permission_hook, permission_hook)

# OpenArch's items in the page's context menu.
rvcm = "chrome/browser/renderer_context_menu/render_view_context_menu.cc"
edit(rvcm, '''void RenderViewContextMenu::InitMenu() {
  RenderViewContextMenuBase::InitMenu();
''', '''void RenderViewContextMenu::InitMenu() {
  RenderViewContextMenuBase::InitMenu();
  if (openarch::g_context_menu_hook) {  // OpenArch
    openarch::g_context_menu_hook(source_web_contents_, params_, &menu_model_);
  }
''', "openarch::g_context_menu_hook(source_web_contents_")
edit(rvcm, '''bool RenderViewContextMenu::IsCommandIdEnabled(int id) const {
''', '''bool RenderViewContextMenu::IsCommandIdEnabled(int id) const {
  if (id >= openarch::kFirstMenuCommand && id <= openarch::kLastMenuCommand) {  // OpenArch
    return true;
  }
''', "id >= openarch::kFirstMenuCommand && id <= openarch::kLastMenuCommand) {  // OpenArch\n    return true;")
edit(rvcm, '''void RenderViewContextMenu::ExecuteCommand(int id, int event_flags) {
''', '''void RenderViewContextMenu::ExecuteCommand(int id, int event_flags) {
  if (id >= openarch::kFirstMenuCommand && id <= openarch::kLastMenuCommand) {  // OpenArch
    if (openarch::g_context_menu_command_hook) {
      openarch::g_context_menu_command_hook(source_web_contents_, params_, id);
    }
    return;
  }
''', "openarch::g_context_menu_command_hook(source_web_contents_")
edit(rvcm, '#include "chrome/browser/renderer_context_menu/render_view_context_menu.h"\n',
     '#include "chrome/browser/renderer_context_menu/render_view_context_menu.h"\n' + hooks, hooks)

# A second launch's command line goes to OpenArch.
edit(main, '''  if (!g_browser_process || g_browser_process->IsShuttingDown() ||
      browser_shutdown::HasShutdownStarted()) {
    return;
  }
''', '''  if (!g_browser_process || g_browser_process->IsShuttingDown() ||
      browser_shutdown::HasShutdownStarted()) {
    return;
  }
  if (openarch::g_relaunch_hook) {  // OpenArch
    openarch::g_relaunch_hook(command_line);
    return;
  }
''', "openarch::g_relaunch_hook(command_line)")

# 3. Chrome's WebView never takes a page OpenArch shows.
webview = "ui/views/controls/webview/webview.cc"
edit(webview, '''  gfx::NativeView view_to_attach = web_contents()->GetNativeView();
  OnBoundsChanged(bounds());''', '''  // OpenArch shows this page in its own window (openarch_hosted_page.h).
  if (web_contents()->GetUserData(OpenArchHostedPageKey())) {
    return;
  }

  gfx::NativeView view_to_attach = web_contents()->GetNativeView();
  OnBoundsChanged(bounds());''', "OpenArchHostedPageKey()")
edit(webview, '#include "ui/views/controls/webview/webview.h"\n',
     '#include "ui/views/controls/webview/webview.h"\n\n'
     '#include "ui/views/controls/webview/openarch_hosted_page.h"\n',
     '#include "ui/views/controls/webview/openarch_hosted_page.h"')
edit("ui/views/controls/webview/BUILD.gn", '''component("webview") {
  sources = [
''', '''component("webview") {
  sources = [
    "openarch_hosted_page.h",
''', '"openarch_hosted_page.h"')

# 3a. No "<extension> was added" bubble after an install: Chrome anchors it
# to its own (hidden) window's toolbar, or opens a window for it.
install_ui = "chrome/browser/ui/extensions/extension_install_ui_desktop.cc"
edit(install_ui, '''  if (IsUiDisabled() || skip_post_install_ui() || extension->is_theme()) {
    return;
  }
''', '''  if (IsUiDisabled() || skip_post_install_ui() || extension->is_theme()) {
    return;
  }
  if (openarch::g_embedder_owns_app) {  // OpenArch
    return;
  }
''', "openarch::g_embedder_owns_app")
edit(install_ui, '#include "chrome/browser/ui/extensions/extension_install_ui_desktop.h"\n',
     '#include "chrome/browser/ui/extensions/extension_install_ui_desktop.h"\n' + hooks, hooks)

# 3c. Dialogs extension APIs open (chrome://extensions' "Remove" confirmation,
# chrome.management.uninstall, ...) go over the window the page is shown in,
# not over the hidden Chrome window holding its tab.
details = "chrome/browser/extensions/chrome_extension_function_details.cc"
edit(details, '''gfx::NativeWindow ChromeExtensionFunctionDetails::GetNativeWindowForUI() {
''', '''gfx::NativeWindow ChromeExtensionFunctionDetails::GetNativeWindowForUI() {
  if (openarch::g_embedder_owns_app) {  // OpenArch
    content::WebContents* sender = function_->GetSenderWebContents();
    if (sender && sender->GetTopLevelNativeWindow()) {
      return sender->GetTopLevelNativeWindow();
    }
  }
''', "openarch::g_embedder_owns_app")
edit(details, '#include "chrome/browser/extensions/chrome_extension_function_details.h"\n',
     '#include "chrome/browser/extensions/chrome_extension_function_details.h"\n' + hooks, hooks)

# 3d. Data an engine with KeychainKeyProviderUserDataDirProtection on wrote
# (nightly 181: "v11", the keychain password with the salt "pepper") stays
# readable now that it is off: that key decrypts, "v10" still encrypts.
bpi = "chrome/browser/browser_process_impl.cc"
edit(bpi, '''      providers.emplace_back(
          /*precedence=*/10u,
          std::make_unique<os_crypt_async::KeychainKeyProvider>());
    } else {
''', '''      providers.emplace_back(
          /*precedence=*/10u,
          std::make_unique<os_crypt_async::KeychainKeyProvider>());
      // OpenArch: read "v11" (written with the protection on), never write it.
      providers.emplace_back(
          /*precedence=*/1u,
          std::make_unique<os_crypt_async::KeychainKeyProvider>(
              "v11", std::to_array<uint8_t>({'p', 'e', 'p', 'p', 'e', 'r'})));
    } else {
''', "OpenArch: read \"v11\"")

# 3e. A page asking to be activated (window.focus(), the extension install
# prompt, ...) never brings the hidden Chrome window holding its tab to the
# front: closing that window would close all of the profile's pages.
edit(wcd, '''void BrowserWebContentsDelegate::ActivateContents(
    content::WebContents* contents) {
''', '''void BrowserWebContentsDelegate::ActivateContents(
    content::WebContents* contents) {
  if (openarch::g_embedder_owns_app) {  // OpenArch
    return;
  }
''', "openarch::g_embedder_owns_app) {  // OpenArch\n    return;\n  }\n  // A WebContents can ask")

# 3f. Chrome's dialogs over a window of OpenArch's (install, remove, ...):
# Views can't attach them as sheets to a window that isn't its own, and
# without a host they'd sit at the screen's top; OpenArch places them.
cwv = "components/constrained_window/constrained_window_views.cc"
edit(cwv, '''  views::Widget* widget = views::DialogDelegate::CreateDialogWidget(
      dialog, gfx::NativeWindow(), parent_view);
''', '''  views::Widget* widget = views::DialogDelegate::CreateDialogWidget(
      dialog, gfx::NativeWindow(), parent_view);
  if (parent && openarch_dialog_place_hook) {  // OpenArch
    // Once shown (both callers show it right away), at its real size.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<views::Widget> widget, gfx::NativeWindow parent) {
                         gfx::Rect bounds;
                         if (widget && widget->IsVisible() &&
                             openarch_dialog_place_hook(
                                 parent, widget->GetWindowBoundsInScreen().size(), &bounds)) {
                           widget->SetBounds(bounds);
                         }
                       },
                       widget->GetWeakPtr(), parent));
  }
''', "openarch_dialog_place_hook(\n")
edit(cwv, '''#include "components/constrained_window/constrained_window_views.h"
''', '''#include "components/constrained_window/constrained_window_views.h"

#include "base/functional/bind.h"  // OpenArch
#include "base/task/sequenced_task_runner.h"  // OpenArch
''', "#include \"base/task/sequenced_task_runner.h\"  // OpenArch")
edit(cwv, '''namespace constrained_window {
''', '''// OpenArch: places a dialog over a window that isn't Chrome's (set by
// OpenArch's layer); false leaves it where Views put it.
bool (*openarch_dialog_place_hook)(gfx::NativeWindow parent,
                                   const gfx::Size& size,
                                   gfx::Rect* bounds) = nullptr;

namespace constrained_window {
''', "bool (*openarch_dialog_place_hook)")

# 3g. The Browsers that hold OpenArch's pages get OpenArch's window, which
# has no native window (openarch/page_window.h): nothing of Chrome's own
# window can show, take the focus or be closed.
factory = "chrome/browser/ui/views/frame/browser_window_factory.cc"
edit(factory, '''                                   bool in_tab_dragging) {
''', '''                                   bool in_tab_dragging) {
  if (openarch::g_browser_window_hook) {  // OpenArch
    if (BrowserWindow* window = openarch::g_browser_window_hook(browser)) {
      return std::unique_ptr<BrowserWindow, BrowserWindowDeleter>(window);
    }
  }
''', "openarch::g_browser_window_hook(browser)")
edit(factory, '#include "build/build_config.h"\n',
     '#include "build/build_config.h"\n' + hooks, hooks)

# 3h. What Chrome only lets a Browser without a BrowserView have in tests
# (or for its own WebUI browser), OpenArch's page Browsers have too: DevTools
# may dock (OpenArch shows the frontend beside the page), and reading mode
# and toasts don't CHECK for a side panel or toolbar that isn't there.
features = "chrome/browser/ui/browser_window/internal/browser_window_features.cc"
edit(features, '''  if (browser_view) {
    devtools_ui_controller_ =
        GetUserDataFactory().CreateInstance<DevtoolsUIController>(
            *browser, browser_, browser_view->GetContentsContainerViews());
  }
''', '''  if (browser_view) {
    devtools_ui_controller_ =
        GetUserDataFactory().CreateInstance<DevtoolsUIController>(
            *browser, browser_, browser_view->GetContentsContainerViews());
  } else if (openarch::g_embedder_owns_app) {  // OpenArch
    devtools_ui_controller_ =
        GetUserDataFactory().CreateInstance<DevtoolsUIController>(
            *browser, browser_,
            std::vector<raw_ptr<ContentsContainerView, DanglingUntriaged>>());
  }
''', "} else if (openarch::g_embedder_owns_app) {  // OpenArch\n    devtools_ui_controller_")
edit(features, '#include "chrome/browser/ui/browser_window/public/browser_window_features.h"\n',
     '#include "chrome/browser/ui/browser_window/public/browser_window_features.h"\n' + hooks, hooks)
for path in ["chrome/browser/ui/read_anything/read_anything_side_panel_controller.cc",
             "chrome/browser/ui/toasts/toast_controller.cc"]:
    edit(path, "    if (!webui_browser::IsWebUIBrowserEnabled()) {\n      CHECK_IS_TEST();",
         "    if (!webui_browser::IsWebUIBrowserEnabled() &&\n"
         "        !openarch::g_embedder_owns_app) {  // OpenArch\n      CHECK_IS_TEST();",
         "!openarch::g_embedder_owns_app) {  // OpenArch")
    header = path.replace(".cc", ".h").split("/")[-1]
    s_inc = '#include "' + path.replace(".cc", ".h") + '"\n'
    edit(path, s_inc, s_inc + hooks, hooks)

# 3b. Chrome's keychain item can be named at run time, so the engine uses
# OpenArch's ("OpenArch Safe Storage").
edit("components/os_crypt/common/BUILD.gn", '''if (is_apple) {
  source_set("keychain_password_mac") {
''', '''if (is_apple) {
  config("openarch_keychain_names") {  # OpenArch
    defines = [ "ALLOW_RUNTIME_CONFIGURABLE_KEY_STORAGE" ]
  }

  source_set("keychain_password_mac") {
    public_configs = [ ":openarch_keychain_names" ]
''', "openarch_keychain_names")

# 4. The framework exports OpenArch's entry and the bridge's classes.
classes = ["OACApplication", "OACEngineSettings", "OACEngine", "OACProfile", "OACPane", "OACDownload",
           "OACExtensionInfo"]
for path in ["chrome/app/framework.exports", "chrome/app/framework.order"]:
    if path.endswith(".exports"):
        edit(path, "_ChromeMain\n", "_ChromeMain\n_OpenArchEngineMain\n", "_OpenArchEngineMain")
    else:
        # framework.order wants _ChromeMain last among the functions.
        edit(path, "\n_ChromeMain\n", "\n_OpenArchEngineMain\n_ChromeMain\n", "_OpenArchEngineMain")
    # Each class once (a class added later is added then): data, after the
    # functions.
    f = f"{src}/{path}"
    s = open(f).read()
    missing = "".join(f"_OBJC_CLASS_$_{c}\n_OBJC_METACLASS_$_{c}\n" for c in classes
                      if f"_OBJC_CLASS_$_{c}\n" not in s)
    if missing:
        s = s.rstrip("\n") + "\n" + missing
        open(f, "w").write(s)
        print(f"hooked {path}")

# 5. chrome_dll (the library in Chrome's framework) links //openarch:core.
p = f"{src}/chrome/BUILD.gn"
s = open(p).read()
if '"//openarch:core"' not in s:
    i = s.index('target(_dll_target_type, "chrome_dll")')
    anchor = '      "//chrome/common/profiler",\n'
    j = s.index(anchor, i)
    s = s[:j + len(anchor)] + '      "//openarch:core",\n' + s[j + len(anchor):]
    open(p, "w").write(s)
    print("hooked chrome/BUILD.gn")
EOF
