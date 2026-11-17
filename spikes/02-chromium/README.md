# Spike 02: Chromium without CEF

**Question:** Can OpenArch run on Chromium directly, without CEF, and how
much memory does that save with 20 tabs?

**Setup:** Chromium 156.0.8078.80 (the version under CEF 156.0.15), built
from source with `setup.sh`. The embedder (`openarch/`) is a source_set in
the Chromium tree that Chrome's framework links; with `--openarch-embedder
--no-startup-window` Chrome opens no window of its own, and the embedder
shows all tabs as `WebContents` (with Chrome's tab helpers) in **one**
AppKit window, 992×784 pt, the page area where OpenArch puts it (right of a
300 pt sidebar, 8 pt inset). `openarch::Pane` is the counterpart of
`OACPane`: show, hide, loadURL. The Swift UI is not connected.

## Why a local checkout, not the CI chain

The CI chain (`.github/workflows/cef-codecs.yml`) takes two to three days
per build, in six-hour jobs. A spike needs a few edit-build-measure rounds,
each a short incremental build; on the CI chain each would be a new chain.
Locally (M2 Max, 12 cores, 64 GB) the first build takes about 5–8 h, and
then each round minutes. Space: ~50 GB checkout without history, ~30 GB
`out/Spike`, about 80 GB of 346 GB free.

The build is release, not official (no ThinLTO, no PGO): hours shorter, and
memory is compared within the same build (Chrome's own window vs. the
embedder), plus Chrome for Testing 156.0.8078.80 (official) as a check.

## Run it

```sh
spikes/02-chromium/setup.sh            # fetch, hook, gen, build (~/chromium)
spikes/02-chromium/measure.sh          # embedder and Chrome's window, light and sites
```

The first build took 2 h on the M2 Max (Xcode 27.2; ANGLE needs the Metal
Toolchain: `xcodebuild -downloadComponent MetalToolchain`); a change in
`openarch/` rebuilds in minutes.

`setup.sh hook` changes three places in Chrome, 14 lines (and fails if one
has moved): `chrome/BUILD.gn` (Chrome's framework library, `chrome_dll`,
links `//openarch`), `ChromeBrowserMainParts::Create` (adds the embedder's
main parts) and a friend in `TabHelpers`.

The build does not run inside a Claude Code sandbox: its helpers' Mach
rendezvous (`org.chromium.Chromium.MachPortRendezvousServer`) is denied
there and pages stay on about:blank. Measure in a normal terminal, screen
unlocked.

## Results

### Chrome for Testing 156.0.8078.80 (no CEF, all tabs in one window)

Before building, the same bench on the official Chrome for Testing of the
same Chromium version: `chrome-bench.sh` does what `scripts/memory-bench.sh`
does (same pages, each tab shown once for 1.5 s, the first in front, 30 s,
footprint per kind of process), with Chrome's own window at 992×784 pt.
Its numbers include Chrome's own UI (the WebUI toolbar and omnibox popup
renderers), which an embedder would not have. Runs of 2026-11-15 (MB):

| 20 tabs | | browser | gpu | renderers | other | total |
|---|---|---|---|---|---|---|
| light | OpenArch (CEF), baseline | ~217 | ~2280 | ~917 | 50 | ~3470 |
| | Chrome for Testing, 8 runs | 100–149 | 118–129 | 358–587 | 22–27 | 611–892 |
| sites | OpenArch (CEF), baseline | ~290 | ~2310 | ~3180 | 130 | ~5920 |
| | Chrome for Testing, 6 runs | 175–181 | 266–357 | 2322–2447 | 91–100 | 2922–3081 |

In every run of mine exactly one tab was visible (`document.visibilityState`). `chrome-bench.sh` now opens the tabs from the command line and counts the windows too (`windows`): tabs made with `/json/new` open in windows of their own when Chrome is not the active app, which would no longer be the one-window model.

The range in light comes from leftover renderers: depending on the run,
up to ~8 short-lived renderers (~16 MB each, from creating the tabs) are
still alive after 30 s. With 90 s they are gone (28 processes, renderers
485 MB, total 778 MB).

**Reading:** the saving is almost all GPU: ~2.2 GB of 2.3 GB, from OpenArch
keeping a window, its buffers and its tiles per tab, which Chrome's one
window does not. Renderers drop by ~0.3–0.8 GB, the browser process by
~70–110 MB. Total: light −74 to −82 %, sites about −50 %. Cra's numbers
(GPU 130 → 95 MB) start from one window already; OpenArch's baseline is
dominated by the window-per-tab model, so most of this would also come
from one window inside CEF (the approach tried in parallel, not here).

### The embedder (spike build)

`measure.sh`, 2026-11-16, the spike build (Chromium 156.0.8078.80, release,
not official) in both modes, 3 runs each, MB (mean, range in brackets). In
every run one tab visible, all 20 loaded; Chrome's window: 1 window.

| 20 tabs | | browser | gpu | renderers | other | total |
|---|---|---|---|---|---|---|
| light | OpenArch (CEF), baseline | ~217 | ~2280 | ~917 | 50 | **~3470** |
| | Chrome's window | 134 (119–163) | 72 | 550 | 28 | 786 (769–818) |
| | **embedder, one AppKit window** | 127 (107–138) | **62** | **402** | 24 | **616 (596–628)** |
| sites | OpenArch (CEF), baseline | ~290 | ~2310 | ~3180 | 130 | **~5920** |
| | Chrome's window | 185 | 132 | 2358 | 94 | 2771 (2722–2851) |
| | **embedder, one AppKit window** | 186 (149–223) | **128** | **2180** | 86 | **2583 (2446–2668)** |

Against the baseline the embedder saves **~2.85 GB (−82 %)** with light
pages and **~3.3 GB (−56 %)** with sites; GPU goes from ~2.3 GB to
60–130 MB. Against Chrome's own window it saves another ~170–190 MB,
mostly the renderers of Chrome's WebUI toolbar and omnibox, which the
embedder does not have (nor anything else of Chrome's UI yet).

Two things to keep in mind: the baseline is an official build with PGO,
the spike build is not (Chrome for Testing, official, came out close to
Chrome's window here); and the embedder has no browser UI, no extensions
UI and no `Browser`, so a full port would add some browser-process memory
back.

**First attempt was black:** a `WebContents` created hidden starts with its
`NSView` hidden (`WebContentsViewMac::CreateView`); in Chrome the Views host
unhides it. Until `Pane` did that, the page loaded and Chromium called it
visible, but nothing was composited, and GPU looked lower than it is.

## What a real port would take

What CEF does for OpenArch today (`OACEngine`, `OACPane`, `OACProfile`;
17 CEF handler interfaces) and what it would take on `//chrome`:

| Area | Today (CEF) | On //chrome | Estimate |
|---|---|---|---|
| App bundle, helpers, startup | CEF framework + helper apps, `CefExecuteProcess` | Chrome's framework and 5 helpers, built by GN; the Swift app links `Chromium Framework` and enters through `ChromeMain`; signing, notarization, crashpad | 1–2 weeks |
| Tabs and windows | one Chrome-style CEF window per tab | tabs in a `Browser`/`TabStripModel` (extensions' `chrome.tabs`, `chrome.windows`, and many Chrome features need one), with an own `BrowserWindow` implementation for the Swift-drawn window instead of Chrome's `BrowserView` | 3–6 weeks, the biggest part |
| Downloads | `CefDownloadHandler` | `DownloadManager` observers; Chrome's download bubble lives in `BrowserView`, so an own UI | 3–5 days |
| Context menus | `CefContextMenuHandler` | `RenderViewContextMenu` (works), own items such as "Ask about selection" via a subclass or observer | 3–5 days |
| Dialogs | `CefJSDialogHandler`, beforeunload; Chrome's own prompts in its window | tab-modal dialogs, permission prompts, HTTP auth, need a `WebContentsModalDialogHost` and bubble anchors in OpenArch's window | 1–2 weeks |
| Profiles, permissions, prefs | `CefRequestContext`, content settings | `Profile`/`ProfileManager`, `HostContentSettingsMap`, `PrefService` directly (simpler, fewer workarounds) | ~1 week |
| DevTools | Chrome's DevTools window, own docking | `DevToolsWindow` undocked works; docking into OpenArch's window means own `DevToolsUIBindings` host; protocol calls via `DevToolsAgentHost` | ~1 week |
| Extensions | `--load-extension`, Chrome's toolbar in the CEF window | work once tabs are in a `Browser`; action popups (`ExtensionPopup`, Views) anchored in OpenArch's toolbar | 1–2 weeks |
| Picture in Picture | Chrome's (Views) | Chrome's, unchanged; Document PiP opens its own `Browser`, which the `BrowserWindow` work has to allow | ~2 days |
| Codecs build | CEF from source in the CI chain | Chromium from source in the same chain, without CEF's patches and branch | ~2 days |

Together about 3–5 months for one person, with the `BrowserWindow` part the
largest risk.

**At each Chrome update** (every four weeks): the three hooks are trivial,
but `//chrome` is not an API. `BrowserWindow`, `WebContentsDelegate`,
`TabHelpers` (moving to `tabs::TabInterface`/`TabFeatures`), permission
prompts and the extension UI change all the time. Expect 1–3 days per
milestone, and 1–2 weeks when a large refactoring lands, plus a full build
(5–8 h locally, 2–3 days on the hosted CI chain, unless a bigger runner is
used). In return no waiting for CEF (today 1–4 weeks after a Chrome
release), and fixes go into Chromium directly instead of through CEF.
