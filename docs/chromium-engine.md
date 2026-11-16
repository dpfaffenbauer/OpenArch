# Chromium engine: OpenArch on Chrome's own framework, without CEF

Decided 16 Nov 2026, after spikes/02-chromium. OpenArch moved from CEF to
Chrome's own framework (`//chrome:chrome_framework`) with a layer of
OpenArch's code linked in. The Swift app keeps its bridge,
`App/Sources/OpenArchCore/include` (`OACEngine`, `OACPane`, `OACProfile`,
`OACPage`): the layer implements those headers. Since 16 Nov 2026 it is the
only engine; CEF is gone (`App/build.sh` builds on Chrome's framework).

The shape follows Cra (github.com/VictorKildahl/cra, MIT,
`docs/chromium-engine.md` there), which made the same move on 13 Nov 2026.

## Why

- **Memory.** CEF's Chrome-style browsers each sit in their own window, and
  OpenArch shows each tab as such a window: with 20 tabs ~3.5 GB, ~2.3 GB of
  it GPU memory for hidden tabs' windows. The spike, all tabs as views in one
  window: ~0.6 GB (spikes/02-chromium/README.md).
- **Chrome releases on the day.** No waiting for a CEF branch (CEF skipped
  157); Chrome stable tags build as they ship.
- **Same cost to build.** OpenArch already builds Chromium for its codecs
  (`.github/workflows/cef-codecs.yml`); Chrome's framework needs the same.

## Shape

- **One hidden Chrome `Browser` per profile**, normal type: its tab strip
  holds the profile's pages as background tabs, so `chrome.tabs`, popups,
  extension popups, permission prompts, autofill and passkeys work as in
  Chrome. Chrome's window for it never shows.
- **OpenArch shows each page's view** (the `WebContents`' NSView) in its own
  window, where `OACPane` puts it, and tells Chromium which pages are on
  screen (the active tab, split panes, Peek, Little OpenArch).
- **The layer** (`engine/chromium/openarch`, copied into the tree as
  `//openarch`): `OpenArchEngineMain` (sets the hooks, runs `ChromeMain`) and
  the bridge's Objective-C classes, exported from the framework.
- **Hooks** (`engine/chromium/apply.sh`): `ChromeBrowserMainParts::Create`
  adds OpenArch's start-up part; `ChromeBrowserMainPartsMac` leaves
  OpenArch's app delegate and menus alone; the framework exports
  `OpenArchEngineMain` and the bridge's classes; `chrome_dll` links
  `//openarch:core`.
- **Patches** (`engine/chromium/patches`, later): changes to Chrome's own
  code where a hook isn't enough.

## Steps

1. **Build**: `scripts/build-chromium.sh` checks out the tag in
   `engine/chromium/VERSION`, applies the layer, builds `chrome`.
   `OPENARCH_ENGINE=chromium App/build.sh` builds OpenArch.app on it.
2. **Start-up**: OpenArch's own app runs on Chrome's framework, its window
   and menus, Chrome's none.
3. **The bridge**, in the order the self-test needs it: page lifecycle and
   navigation, show/hide/frames, JavaScript and the DevTools protocol, popups
   and new tabs, keys and focus, downloads, permissions, DevTools, find,
   Picture in Picture, extensions, profiles and private windows, prefs.
4. **Release build**: official, PGO, codecs, OpenArch's branding; the CI
   chain builds it like the CEF one today (see "CI" below).
5. **Switch**: the self-test and `scripts/memory-bench.sh` on the new
   build, then the release.

## CI

- `.github/workflows/chromium-engine.yml` builds the engine on GitHub's Macs
  (`scripts/chromium-engine-ci.sh`): Chrome's tag from
  `engine/chromium/VERSION`, the layer, an official build (ThinLTO, PGO,
  H.264/AAC, ninja instead of siso so a job can stop and the next one carry
  on). As for CEF, a chain of up to 20 jobs of five hours, the tree passed
  on as an artifact. It publishes `Chromium.app`, zipped, as the
  pre-release `engine-<version>-<key>`.
- The key (`scripts/fetch-chromium-engine.sh --key`) is a hash of what the
  engine is built from here: `engine/chromium` (the layer, hooks,
  `apply.sh`), the bridge's headers and the build scripts. Every change to
  them on main starts a build; one already published is not built again.
- `OPENARCH_ENGINE=chromium App/build.sh` takes `OPENARCH_ENGINE_APP`, else
  a local build in `~/chromium`, else downloads the release for its version
  and key into `Vendor/engine`. Without a local Chromium checkout, a change
  to the layer takes a CI run (days) before an app can be built on it;
  changes to the Swift app take none.
- `.github/workflows/update-chromium-engine.yml`, daily
  (`scripts/update-chromium.sh`): a newer stable Chrome for Mac
  (chromiumdash) starts its engine build; once its release is out, OpenArch
  is built on it and the new `VERSION` goes to main as a pull request that
  merges itself (branch `update-chrome-engine`, the GitHub App of
  `update-cef.yml`). A failed build fails the daily run until
  `engine/chromium` is fixed for the new Chrome.
- Not yet: incremental CI builds (keeping the finished tree, so a layer
  change rebuilds only its files), signing, Chrome's own updates between
  stable versions (respins arrive as new versions anyway).

## Log

- 16 Nov 2026: decided; target Chrome 158.0.8127.37 (latest stable).
- 16 Nov 2026, steps 1 and 2: `scripts/build-chromium.sh` builds Chrome
  158 with the layer (release, ~2.5 h on an M2 Max; a new tag fetches only
  itself, gclient's `--with_tags` never finishes; googlesource answers 429
  above ~4 parallel fetches). `OPENARCH_ENGINE=chromium App/build.sh` builds
  `App/build/engine/OpenArch.app`. It starts, makes its own window, menus and
  sidebar, Chrome none; pages load in the profile's hidden Chrome window and
  draw in OpenArch's; extensions load and their content scripts run. Memory
  bench, 20 tabs light: **~630 MB** (browser 101, GPU 75, renderers 430,
  other 22) against ~3470 MB on CEF.
  - Learned: the bridge's classes need `visibility("default")` on their
    `@interface` (`OAC_EXPORT`; `#pragma GCC visibility` doesn't reach
    Objective-C classes); `BrowserCrApplication`'s `terminate:` asks
    Chrome's AppController, so `OACApplication` overrides it as on CEF;
    `Browser::Create` is private in 158, windows come from
    `CreateBrowserWindow` and are handled as `BrowserWindowInterface`; Xcode
    27 needs the Metal Toolchain component for ANGLE.
  - Next: the self-test on the engine build, method by method (popups and
    new tabs, keys and focus, downloads, permissions, DevTools docking,
    find, PiP, private windows, the about page, favicons).
- 16 Nov 2026, step 3: **the whole self-test runs on the engine** (first
  run: 162 ok, 27 failed, then a crash). Now 240–242 of 242 pass; the CEF
  build on the same Mac: 239 (its download checks failed that run). The
  bridge has: console messages (media, audio, boosts, the self-test's
  answers), favicons, downloads (`DownloadManager` observers), the
  DevTools protocol on the page target (`GetOrCreateFor`, not
  `GetOrCreateForTab`: that one has no Runtime or Page), new tabs and
  ⌘-clicks (hook in `BrowserWebContentsDelegate::OpenURLFromTab` and
  `AddNewContents`), keys from pages to OpenArch's menus (hook in
  `Pre`/`HandleKeyboardEvent`), Peek and links to other apps (a navigation
  throttle, hook in `CreateThrottlesForNavigation`), DevTools docked beside
  the page (the frontend `GetInTabWebContents` returns, once loaded, shown
  in OpenArch's window), private windows (an own incognito profile each;
  Chrome refuses those a window, so their pages live without one),
  closing without "Leave site?" (`DetachAndDeleteWebContentsAt`, as CEF's
  forced close), pictures of hidden tabs for the tab switcher (a capturer
  count, the view lent to the window underneath for the moment).
  - Learned: `WasHidden()` inside `WebContentsDestroyed` crashes; Chrome
    focuses the active tab of its hidden window by itself, so focus counts
    only for a page on screen in the key window; a page never shown has no
    size until it is given one; `DevToolsWindow::AsDevToolsWindow` CHECKs
    the window type; `LOG(WARNING)` doesn't reach stderr without
    `--enable-logging` (`OPENARCH_DEBUG_PAGES=1` logs page calls at ERROR).
  - The app: `OACPane.panesHaveWindows` and `screenFrame` let the self-test
    check "where is the page" on both engines; Peek shows its card in its
    backdrop window on the engine (as a view in the main window it would
    lie under the backdrop).
  - Later the same day: dialogs, permission prompts, find, context menu,
    Chrome's own tabs, relaunch, DevTools in a window, language. 242 of 242.
    - Web-modal dialogs (alert, confirm, prompt, "Leave site?" on
      navigation, HTTP sign-in, print, ...): the pane is the page's
      `WebContentsModalDialogManager` delegate and host (`dialogs.mm`);
      with a host that is not a Views widget Chrome shows them over
      OpenArch's window. JavaScript dialogs wait for "the tab in front",
      which for OpenArch's pages is the pane on screen (hook in
      `IsWebContentsForemost`).
    - Permission prompts: OpenArch's own, a sheet on the pane's window,
      "<site> möchte" with Chrome's words per permission, Zulassen or
      Blockieren (hook in `CreatePermissionPrompt`,
      `chrome/browser/openarch_permission_hook.h`). Not yet confirmed by
      hand: a click on Zulassen (the test window was behind other windows).
    - Find in page: Chrome's find bar is its window's; the pane has its own
      (`findbar.mm`, Chrome's `FindTabHelper`), for ⌘F, ⌘G, ⇧⌘G.
    - "Ask about selection" atop the context menu of selected text (hooks in
      `RenderViewContextMenu`, command ids 71001–71099).
    - Tabs Chrome opens by itself (View Source, `chrome.tabs.create`) go to
      `OACPane.externalTabHandler` and close in Chrome (a tab strip
      observer on the hidden windows), as on CEF.
    - A second launch's command line goes to `OACEngine.relaunchHandler`
      (hook in Chrome's process singleton callback).
    - DevTools "in a window of their own": Chrome's dock preference
      (`devtools.preferences.currentDockState`) is set before they open;
      switching between docked and a window reopens them.
    - Chrome's language: the app bundle gets Chromium's (empty) `.lproj`
      folders, so Chrome picks the user's language, not English.
  - Open: "the tab loaded in the background shows its page's title" fails
    in some runs too: its title arrives in 0.3 s, but parallel steps of
    the self-test (the tab switcher, dropped links) change the tab in front
    meanwhile.
  - Open (flaky): ⌘⇧C, Escape and the switcher's pictures fail together in
    some runs (key events and focus while the Mac is in use);
    "Escape puts the downloads away" and "the switcher has pictures"
    fail in some runs, both while the self-test opens Little OpenArch at
    the same time (order of parallel steps; Escape passed on CEF in the one
    comparison run).
  - Then: OpenArch's own extension toolbar, side panels, private popups,
    DevTools' dock menu. Self-test 239–242 of 242.
    - The toolbar (`toolbar.mm`, `OACPane.toolbarVisible`): a bar above the
      page's column with the pinned extensions (Chrome's
      `ToolbarActionsModel`: icon, badge, greyed when off for the page) and
      the puzzle piece (every extension, ⌥ to pin or unpin, "Erweiterungen
      verwalten"). A click runs the action as Chrome's button does
      (`ExtensionActionRunner::RunAction`: activeTab, onClicked); a popup
      opens in a small window below the button (`CreatePopupHost`, an
      `ExtensionView` of OpenArch's: sized by the page, 25×25 to 800×600,
      shown once loaded, gone on window.close(), Escape or a click
      elsewhere). No location bar: OpenArch has its own.
    - Side panels (`openPanelOnActionClick`): the action's click shows the
      extension's panel (`SidePanelService` options, `CreateSidePanelHost`)
      right of the page, 360 pt; the same click again hides it.
    - Popups (window.open with features) of private windows' pages: a plain
      window of their own, keeping the opener.
    - DevTools' own dock menu: OpenArch follows Chrome's dock preference
      (side → `devToolsDock`, `devToolsDockHandler`; "undock" lets Chrome
      move the frontend into its own window).
    - The DevTools protocol client attaches again when Chrome closes the
      page's session (it does, often, ~40 times a self-test run) and sends
      waiting calls once more; the tab switcher's pictures depended on it.
  - Not done yet: `chrome.sidePanel.open()` from an extension (only the
    action's click opens a panel), the release build (official, PGO,
    branding, signing, the CI chain).
- 16 Nov 2026, step 5: **the switch.** Merged with main (the `OACPage`
  protocol, WebKit pages for streaming services, Peek on ⇧-click, camera
  and microphone, renderer crashes, the keychain item's name: a hook makes
  Chrome's configurable at run time). Then CEF went: its implementation of
  the bridge, its helper app, `fetch-cef.sh`, `patch-cef.*`, `cef-codecs`,
  `update-cef`. OpenArch is `dev.openarch.browser` with the data folder
  "OpenArch" again: the first launch of the new build opens the profile CEF
  (Chromium 156) wrote, and Chrome 158 moves it to its format, which CEF
  cannot read; the keychain item stays the same, so passwords and cookies
  carry over. `build.yml` takes the engine release for its layer; a pull
  request that changes the layer builds its engine first
  (`chromium-engine.yml` runs for pull requests too).
  - Chrome's helpers are signed with OpenArch's entitlements by name
    (Renderer and GPU: JIT; Plugin and the plain helper: also other
    signers' code; Alerts: none).
  - Crash reports know Chrome's helper names ("Chromium Helper (GPU)").
