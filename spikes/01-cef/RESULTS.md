# Spike 01: CEF with a native AppKit shell

**Question:** Can OpenArch embed Chromium (CEF prebuilt binaries) in its own
native Swift/AppKit UI with per-Space profiles and working Chrome extensions?

**Setup:** CEF 156.0.14 (Chromium 156.0.8078.48), macOS 27, Swift 6.4.
Architecture as planned for OpenArch: Chromium behind a narrow Objective-C
bridge (`OpenArchCore`), Swift UI on top. Each tab is a CEF browser embedded
as a child `NSView`, which on macOS always means CEF "Alloy" style.

## Run it

```sh
./build.sh                                              # builds build/OpenArchSpike.app
open build/OpenArchSpike.app                            # interactive
build/OpenArchSpike.app/Contents/MacOS/OpenArchSpike --selftest   # automated checks
```

Interactive: sidebar with three Spaces (dots at the bottom), ⌘T new tab,
⌘W close tab, ⌘⇧N opens a Chrome-style window on `chrome://extensions`.

## Results (`--selftest`, 2026-10-27)

| Check | Embedded (Alloy) | Chrome-style window |
|---|---|---|
| Browser embedded in own AppKit view | ✅ | n/a (Chrome's own window) |
| Separate profile per Space (cookies, localStorage) | ✅ | ✅ |
| Extension loaded via `--load-extension` | ✅ in every profile | ✅ |
| Content scripts | ✅ | ✅ |
| Content script ↔ service worker messaging | ✅ | ✅ |
| `chrome.storage` | ✅ | ✅ |
| `declarativeNetRequest` blocking (uBlock Origin Lite's base) | ✅ (control request passes) | ✅ |
| `sender.tab.id` | ✅ | ✅ |
| `chrome.tabs.query` sees the tab | ❌ **0 tabs** | ✅ |
| Extension toolbar / action popup | ❌ no toolbar, no CEF API | ✅ Chrome's toolbar |
| Clean shutdown | ✅ | ✅ |

## Findings

1. **Embedded browsers are invisible to Chrome's tab model.** Everything that
   runs inside a page works, but anything that asks Chrome for tabs does not:
   `chrome.tabs.*`, the "active tab" a popup acts on, tab-based extension UI.
   Password managers (fill in this tab), uBlock's per-site popup and tab
   managers depend on exactly that. Not fixable from the outside; it needs a
   change inside CEF/Chromium.
2. **There is no API for extension actions in Alloy style.** We would have to
   draw toolbar buttons ourselves, and their popups would hit finding 1.
3. **Profiles must be direct children of `root_cache_path`** (Chrome rule).
   `Profiles/<id>` fails with "Cannot create profile at path".
4. **New profiles initialize asynchronously.** `CreateBrowserSync` fails for
   them; use `CreateBrowser` and pick the browser up in `OnAfterCreated`.
5. **`DoClose` must return `true` for embedded tabs**, otherwise CEF sends
   `performClose:` to the whole window when a single tab closes.
6. `--load-extension` needs `--disable-features=DisableLoadExtensionCommandLineSwitch`
   since Chromium 137, and `--use-mock-keychain` avoids keychain prompts for
   unsigned builds.

## Verdict

Embedded CEF is good enough for the shell (sidebar, Spaces, profiles,
performance) but **not for a daily driver with extensions**, because of
findings 1 and 2.

## Outcome

Spike 02 went straight into the app. Each tab is a Chrome-style CEF browser in
its own borderless window, attached as a child window over the content area.
`chrome.tabs`, action popups and split view all work that way. See `App/` and
the architecture section of the top-level README.
