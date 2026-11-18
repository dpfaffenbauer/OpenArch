# The engine: OpenArch on Chrome's own framework

OpenArch runs on Chrome's own framework (`//chrome:chrome_framework`) with a
layer of OpenArch's code compiled in. The Swift app talks to it through the
bridge, `App/Sources/OpenArchCore/include` (`OACEngine`, `OACPane`,
`OACProfile`, `OACPage`); the layer implements those headers. The Chrome
version is pinned in `engine/chromium/VERSION`.

The shape follows Cra (github.com/VictorKildahl/cra, MIT,
`docs/chromium-engine.md` there).

## Shape

- **One hidden Chrome `Browser` per profile**, normal type: its tab strip
  holds the profile's pages as background tabs, so `chrome.tabs`, popups,
  extension popups, permission prompts, autofill and passkeys work as in
  Chrome. Chrome's window for it never shows.
- **OpenArch shows each page's view** (the `WebContents`' NSView) in its own
  window, where `OACPane` puts it, and tells Chromium which pages are on
  screen (the active tab, split panes, Peek, Little OpenArch). All tabs in
  one window: 20 light tabs take ~630 MB (browser 101, GPU 75, renderers
  430, other 22; `scripts/memory-bench.sh`).
- **The layer** (`engine/chromium/openarch`, copied into the tree as
  `//openarch`): `OpenArchEngineMain` (sets the hooks, runs `ChromeMain`) and
  the bridge's Objective-C classes, exported from the framework.
- **Hooks** (`engine/chromium/apply.sh`, `engine/chromium/hooks`), small
  edits to Chrome's code:
  - start-up: `ChromeBrowserMainParts::Create` adds OpenArch's part;
    `ChromeBrowserMainPartsMac` leaves OpenArch's app delegate and menus
    alone; the process singleton passes a second launch's command line to
    `OACEngine.relaunchHandler`;
  - pages: new tabs and ⌘-clicks (`BrowserWebContentsDelegate::OpenURLFromTab`,
    `AddNewContents`), keys to OpenArch's menus (`Pre`/`HandleKeyboardEvent`),
    a navigation throttle for Peek, links to other apps and WebKit's sites
    (`CreateThrottlesForNavigation`), "the tab in front" for JavaScript
    dialogs (`IsWebContentsForemost`), permission prompts
    (`CreatePermissionPrompt`), the context menu (`RenderViewContextMenu`,
    command ids 71001–71099; `RenderViewContextMenuMacCocoa::Show` shows
    it without a Views widget, in OpenArch's window), Chrome's WebView never
    taking OpenArch's pages;
  - the keychain item's name configurable at run time ("OpenArch Safe
    Storage");
  - the framework exports `OpenArchEngineMain` and the bridge's classes;
    `chrome_dll` links `//openarch:core`.

## What the layer does

- Console messages (media, audio, boosts, the self-test's answers),
  favicons, theme colors, loading state.
- The DevTools protocol on the page target (`GetOrCreateFor`, not
  `GetOrCreateForTab`: that one has no Runtime or Page). Chrome closes a
  page's session often (~40 times a self-test run); the client attaches
  again and sends waiting calls once more.
- Downloads (`DownloadManager` observers), find in page (`findbar.mm`,
  Chrome's `FindTabHelper`; Chrome's find bar belongs to its window).
- Web-modal dialogs (alert, confirm, prompt, "Leave site?", HTTP sign-in,
  print): the pane is the page's `WebContentsModalDialogManager` delegate
  and host (`dialogs.mm`); with a host that is not a Views widget Chrome
  shows them over OpenArch's window.
- Permission prompts: a sheet on the pane's window, "<site> möchte" with
  Chrome's words per permission, Zulassen or Blockieren.
- DevTools docked beside the page (the frontend `GetInTabWebContents`
  returns, shown in OpenArch's window) or in a window of their own
  (Chrome's dock preference `devtools.preferences.currentDockState`, set
  before they open; DevTools' own dock menu is followed).
- Private windows: an own incognito profile each; Chrome refuses those a
  window, so their pages live without one, owned by the pane, and their
  popups get a plain window of their own.
- OpenArch's toolbar above the page (`toolbar.mm`, `OACPane.toolbarVisible`):
  back, forward, reload, the site, the pinned extensions (Chrome's
  `ToolbarActionsModel`: icon, badge, greyed when off for the page) and the
  site controls. A click runs the action as Chrome's button does
  (`ExtensionActionRunner::RunAction`); popups open below the button
  (`CreatePopupHost`, an `ExtensionView` of OpenArch's, 25×25 to 800×600);
  side panels (`openPanelOnActionClick`) right of the page, 360 pt.
- Tabs Chrome opens by itself (View Source, `chrome.tabs.create`) go to
  `OACPane.externalTabHandler` and close in Chrome.
- Pictures of hidden tabs for the tab switcher: a capturer count, the view
  lent to the window underneath for the moment.
- Camera and microphone (Chrome's `MediaStreamCaptureIndicator`), renderer
  crashes, Peek on ⇧-click, the hand-off of navigations to WebKit pages.
- Chrome's language: the app bundle gets Chromium's (empty) `.lproj`
  folders, so Chrome picks the user's language, not English.

## Learned

- The bridge's classes need `visibility("default")` on their `@interface`
  (`OAC_EXPORT`); `#pragma GCC visibility` doesn't reach Objective-C classes.
- `BrowserCrApplication`'s `terminate:` asks Chrome's AppController, so
  `OACApplication` overrides it; quitting releases OpenArch's keep-alive
  before `chrome::CloseAllBrowsersAndQuit()`, or Chrome never quits.
- `Browser::Create` is private in 158: windows come from
  `CreateBrowserWindow` and are handled as `BrowserWindowInterface`.
- `WasHidden()` inside `WebContentsDestroyed` crashes;
  `DevToolsWindow::AsDevToolsWindow` CHECKs the window type.
- Chrome focuses the active tab of its hidden window by itself, so focus
  counts only for a page on screen in the key window; a page never shown has
  no size until it is given one.
- `LOG(WARNING)` doesn't reach stderr without `--enable-logging`;
  `OPENARCH_DEBUG_PAGES=1` logs page calls at ERROR.
- Xcode 26 and later need the Metal Toolchain component for ANGLE
  (`xcodebuild -downloadComponent MetalToolchain`).
- A new tag fetches only itself (`git fetch --depth=1` of the tag, then
  `gclient sync -r src@<rev>`); gclient's `--with_tags` never finishes, and
  googlesource answers 429 above ~4 parallel fetches.

## Building it

- **Locally**: `scripts/build-chromium.sh` checks out the tag in
  `engine/chromium/VERSION` (~1 h and ~35 GB the first time), applies the
  layer, writes `out/OpenArch/args.gn` and builds `chrome` (~2.5 h on an M2
  Max the first time, minutes after a change to the layer). `App/build.sh`
  then uses `~/chromium/src/out/OpenArch/Chromium.app`.
- **CI**: `.github/workflows/chromium-engine.yml` builds the engine on
  GitHub's Macs (`scripts/chromium-engine-ci.sh`): an official build
  (ThinLTO, PGO, H.264/AAC; ninja instead of siso, so a job can stop and the
  next one carry on), a chain of up to 20 jobs of five hours with the tree
  passed on as an artifact, ~15–17 hours in all. It publishes
  `Chromium.app`, zipped, as the pre-release `engine-<version>-<key>`.
- The key (`scripts/fetch-chromium-engine.sh --key`) is a hash of what the
  engine is built from here: `engine/chromium` (the layer, hooks,
  `apply.sh`), the bridge's headers and the build scripts. A push to main or
  a pull request that changes them starts a build; one already published is
  not built again. `build.yml` needs the release for its key, so a pull
  request that changes the layer is mergeable once its engine is built.
- `App/build.sh` takes `OPENARCH_ENGINE_APP`, else a local build in
  `~/chromium`, else downloads the release for its version and key into
  `Vendor/engine`.
- `.github/workflows/update-chromium-engine.yml`, daily
  (`scripts/update-chromium.sh`): a newer stable Chrome for Mac
  (chromiumdash) starts its engine build; once its release is out, OpenArch
  is built on it and the new `VERSION` goes to main as a pull request that
  merges itself (branch `update-chrome-engine`, OpenArch's GitHub App). A
  failed build fails the daily run until `engine/chromium` is fixed for the
  new Chrome.
- Signing: `App/build.sh` signs Chrome's helpers with OpenArch's
  entitlements by name (Renderer and GPU: JIT; Plugin and the plain
  helper: also other signers' code; Alerts: none).

## Open

- `chrome.sidePanel.open()` from an extension (only the action's click opens
  a panel).
- Incremental CI builds (keeping the finished tree, so a layer change
  rebuilds only its files).
- Branding: Chrome's helpers are still called "Chromium Helper".
- Flaky self-test checks: ⌘⇧C, Escape on the downloads and the switcher's
  pictures fail together in some runs (key events and focus while the Mac
  is in use, parallel steps).
