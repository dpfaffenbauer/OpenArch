# OpenArch

An open-source, Chromium-based browser for macOS in the spirit of Arc:
sidebar with favorites, pinned folders and today tabs, Spaces with their own
profiles, a command bar, split view, and real Chrome extensions.

Status: early, but usable as a daily browser for testing.

## Build and run

```sh
App/build.sh                      # fetches CEF, builds App/build/OpenArch.app
open App/build/OpenArch.app
App/build/OpenArch.app/Contents/MacOS/OpenArch --selftest   # automated checks, runs behind other windows
```

Requires Xcode 16+ (Swift 6), CMake and Ninja.

GitHub Actions builds every push (`.github/workflows/build.yml`) and keeps
the newest build of `main` as the
[nightly release](https://github.com/dpfaffenbauer/OpenArch/releases/tag/nightly).
Once a day, `update-cef.yml` checks for a newer stable CEF (Chromium) build.
When there is one, it builds OpenArch with it, commits the update to `main`
and publishes a new nightly. A failed build stops the update and shows up as
a failed workflow run. Data lives in
`~/Library/Application Support/OpenArch` (`Library.json` for the sidebar,
`Chromium/` for Chromium's profiles).

## What works

- **Sidebar:** favorites grid, pinned tabs in folders and subfolders, today
  tabs under the line, drag and drop, inline renaming, context menus.
- **Spaces:** name, icon (SF Symbol or emoji), color, and a profile each.
  Profiles keep logins (e.g. a different Google account per space), cookies,
  history, passwords and extensions apart.
- **Command bar** (⌘T, ⌘L): URL or search with suggestions, switch to open
  tabs, pinned tabs and favorites, history, archived tabs, commands.
- **Split view:** up to four tabs side by side, with resizable dividers.
  Use ⌃⇧=, or drag a tab from the sidebar onto the left or right half of
  the page.
- **Library** (⌥⌘B): media (images in Downloads and screenshots on the
  Desktop), downloads, spaces and archived tabs, searchable.
- **Arc's look:** your space's color with white text, Arc's row sizes, and
  favicons taken from Arc's own icon cache. Drag the sidebar edge far to the
  left to collapse it, ⌘S brings it back.
- **Arc's gestures and shortcuts:** swipe sideways over the sidebar
  (trackpad or Magic Mouse) to change spaces, and past the first one to open
  the library. Arc's shortcuts are there too: ⌘T, ⌘L, ⌘S, ⌘D, ⌘⇧K, ⌘⇧L,
  ⌘⇧J, ⌃Tab, ⌘1–9, ⌃1–9, ⌘⌥←/→, ⌃⇧= / ⌃⇧-, ⌃⇧1–4, ⌘⇧⌥C and more. They take
  precedence over the page, like in Arc.
- **Little OpenArch** (⌥⌘N): a small window for quick links. Links from
  other apps open there too. "In Space öffnen" moves the page into the main
  window without reloading it.
- **AI control:** turn it on under Settings › KI. OpenArch then opens Chrome's
  DevTools protocol on 127.0.0.1:9222, so Claude Code can drive the real
  browser and its tabs:
  `claude mcp add openarch -- npx -y chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222`.
  An antenna icon in the sidebar shows while the port is open.
- **Settings** in Arc's style: General, Profiles, Links, AI, Import, Info.
- **Real Chrome tabs:** extensions incl. popups, `chrome.tabs`, side panels,
  `declarativeNetRequest`, native messaging. Also DevTools, find, zoom,
  downloads, printing, the password manager and chrome:// pages.
- **Housekeeping:** today tabs are archived after 12 hours (configurable),
  and ⌘⇧T reopens closed tabs.
- **Import from Arc:** spaces, favorites, pinned folders, today tabs and split
  views (from Arc's `StorableSidebar.json`). "Alles übernehmen" also brings
  logins and cookies, saved passwords, history, website data and the
  installed extensions with their settings. Arc's profile is cloned, and
  encrypted values are re-encrypted with OpenArch's key.
- **Default browser:** OpenArch can be set as the default browser and opens
  links from other apps.

## Architecture

```
Swift/AppKit/SwiftUI app (App/Sources/OpenArch)
  sidebar, command bar, spaces, library, Arc import
        │  narrow Objective-C API
OpenArchCore (App/Sources/OpenArchCore, Objective-C++)
  OACEngine, OACProfile, OACPane
        │
CEF 156 (Chromium 156), prebuilt binaries in Vendor/cef
```

Each tab is an `OACPane`: a Chrome-style CEF browser in its own borderless
Views window. That window is attached as a child window over OpenArch's
content area. Chrome therefore treats every tab as a real tab (see
`spikes/01-cef/RESULTS.md` for why embedded "Alloy" browsers are not enough).
CEF allows one Chrome-style browser per window, so split view simply places
several pane windows side by side.

Lessons learned on the way:

- CEF already disables Chrome features it does not support via
  `--disable-features`. Overwriting that switch, instead of appending to it,
  crashes Views-hosted Chrome browsers in Chrome's Actor UI.
- Chrome-style browsers need a fully loaded profile. Create them only after
  `OnContextInitialized` or `OnRequestContextInitialized`.
- Frameless Views windows need non-empty initial bounds.

## Known limitations

- **Unsigned builds.** Builds are signed ad hoc and use Chromium's mock
  keychain, so saved cookies and passwords are not protected by the login
  keychain. A real signing identity fixes both.
- **Logins and extensions are not migrated** from Arc. You sign in once and
  install extensions from the Chrome Web Store, once per profile.
- **No Widevine.** DRM video such as Netflix does not play, and Google sync
  for Chromium forks is not available.
- **Focus appearance.** While a page has focus, the window buttons look
  inactive, because the page lives in a child window.
- **Not built yet:** Peek, Boosts, Easels, multiple windows, and showing a
  collapsed sidebar by hovering at the window edge.
- **Untested:** window full screen and HTML full screen.

## Layout

- `App/`: the browser
- `website/`: the website, published by `.github/workflows/pages.yml`
- `scripts/fetch-cef.sh`: downloads the pinned CEF binary distribution into `Vendor/cef`
- `scripts/update-cef.sh`: moves the pin to the newest stable CEF build
- `scripts/patch-cef.swift`: lowers CEF's 2 s wait before extension popups appear
- `spikes/01-cef/`: first spike, CEF embedded in AppKit ([results](spikes/01-cef/RESULTS.md))
