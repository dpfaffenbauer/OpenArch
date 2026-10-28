# OpenArch

An open-source, Chromium-based browser for macOS in the spirit of Arc:
sidebar with favorites, pinned folders and today tabs, Spaces with their own
profiles, a command bar, split view, and real Chrome extensions.

Status: early, but usable as a daily browser for testing.
[Download the latest release](https://github.com/dpfaffenbauer/OpenArch/releases/latest)
(Apple silicon, macOS 15 or later) or see [openarch.app](https://openarch.app).

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
OpenArch's Chromium is its own build of CEF with the proprietary codecs
(H.264, AAC, HEVC) that the official CEF builds leave out, made on GitHub by
`cef-codecs.yml` and published as a release (`cef-156.0.14-codecs`). Once a
day, `update-cef.yml` checks for a newer stable CEF. When there is one, it
starts that build (about ten hours); the next check after it has finished
builds OpenArch with it, commits the update to `main` and publishes a new
nightly. A failed build stops the update and shows up as a failed workflow
run. Data lives in
`~/Library/Application Support/OpenArch` (`Library.json` for the sidebar,
`Chromium/` for Chromium's profiles).

## What works

- **Sidebar:** favorites grid, pinned tabs in folders and subfolders, today
  tabs under the line, drag and drop, inline renaming, context menus. The
  × on a pinned tab unpins it; ⌘-click on a link opens it as a tab in the
  background.
- **Spaces:** name, icon (SF Symbol or emoji), color, and a profile each.
  Drag the icons at the bottom of the sidebar into the order you want.
  Profiles keep logins (e.g. a different Google account per space), cookies,
  history, passwords and extensions apart.
- **GitHub live folders** (+ › GitHub-Live-Ordner): pinned folders that
  fill themselves with your open pull requests, review requests or issues,
  every five minutes, with the space's own GitHub login (no token).
- **Command bar** (⌘T, ⌘L): completes the address as you type, like Chrome
  (→ keeps it, Backspace drops it); URL or search with suggestions, switch to open
  tabs, pinned tabs and favorites, history, archived tabs, commands. A
  sentence or a question opens a new chat on Claude or ChatGPT with it,
  signed in as you there (your subscription, no API key; Settings › KI).
- **Split view:** up to four tabs side by side or one above the other,
  with resizable dividers; ⌃⇧S swaps the sides. Use ⌃⇧=, or drag a tab from the sidebar onto a
  half of the page: left or right puts it beside, top or bottom above or
  below. Links dragged from a page, Safari, Mail or Finder onto the
  sidebar become tabs.
- **Library** (⌥⌘B): media (images in Downloads and screenshots on the
  Desktop), downloads, spaces and archived tabs, searchable. A download
  flies into the library button, a ring around it shows the progress, and
  it bounces when the file is there. Running downloads are listed in the
  library with a button to cancel them; resting the pointer on a file shows
  a preview.
- **Links to apps** (bambustudioopen:, zoommtg:, mailto: …) open the app on
  the Mac after asking, as in Chrome; „immer öffnen“ remembers it per site.
- **Arc's look:** your space's color with white text, Arc's row sizes, and
  favicons taken from Arc's own icon cache. Drag the sidebar edge far to the
  left to collapse it, ⌘S brings it back.
- **Arc's gestures and shortcuts:** swipe sideways over the sidebar
  (trackpad or Magic Mouse) to change spaces, and past the first one to open
  the library. Arc's shortcuts are there too: ⌘T, ⌘L, ⌘S, ⌘D, ⌘⇧K, ⌘⇧L,
  ⌘⇧J, ⌃Tab (hold ⌃ for the tab switcher), ⌘1–9, ⌃1–9, ⌘⌥←/→, ⌃⇧= / ⌃⇧-, ⌃⇧1–4, ⌘⇧⌥C and more. They take
  precedence over the page, like in Arc.
- **Little OpenArch** (⌥⌘N): a small window for quick links. Links from
  other apps open as a new tab in the window, or there if you turn it on
  under Settings › Links. It has back, forward and reload, and the puzzle
  button shows Chrome's toolbar with your extensions. "In Space öffnen" moves
  the page into the main window without reloading it.
- **AI control:** turn it on under Settings › KI. OpenArch then opens Chrome's
  DevTools protocol on 127.0.0.1:9222, so Claude Code can drive the real
  browser and its tabs:
  `claude mcp add openarch -- npx -y chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222`.
  An antenna icon in the sidebar shows while the port is open.
- **Windows:** ⌘N opens another window on the same spaces and tabs; a tab
  moves to the window that shows it. ⌘⇧N opens a private window with its
  own in-memory profile and no history.
- **Peek:** links from pinned tabs and favorites to other sites open in a
  card over the page, which can become a tab or a split.
- **Site Control Center** (⌃⌘I, or the sliders at the top of the sidebar):
  camera, microphone, location, notifications, pop-ups, sound, downloads,
  clipboard and JavaScript per site, the page's zoom, its boost, and
  clearing its cookies and data.
- **DevTools** (⌥⌘I) dock beside the page, inside the tab, on the right,
  left or below, or open in a window of their own (DevTools' own ⋮ › Dock
  side, or Ansicht › DevTools anordnen); ⌘W in them closes them, not the tab.
- **Boosts** (⌃⌘B): restyle a site with a color shift, another font,
  zapped elements and your own CSS and JavaScript.
- **Site search:** type a site's keyword or name in the command bar and
  press Tab (yt, gh, w, maps …); the sites are editable in Settings.
- **Link rules:** links from other apps open in a space by address
  (github.com, *.atlassian.net, docs.google.com/spreadsheets).
- **Media:** controls for audio and video playing in another tab at the
  bottom of the sidebar, and picture-in-picture when you leave a tab with a
  video playing.
- **Hover sidebar:** with the sidebar collapsed, the window's left edge
  brings it back over the page.
- **Updates:** OpenArch updates itself from the nightly release (checked
  at launch and every six hours, SHA-256 verified).
- **Settings** in Arc's style: General, Profiles, Links, AI, Import, Info.
- **Über OpenArch:** a flight through OpenArch's arches; click the logo for
  warp speed.
- **App icon:** twelve takes on the arch (Tunnel is the standard one), one
  in the current space's color, or a different one each day.
- **Sandbox:** pages, the GPU and the network service run in Chromium's
  sandbox, as in Chrome; every helper process starts it before loading
  Chromium.
- **Real Chrome tabs:** extensions incl. popups, `chrome.tabs`, side panels,
  `declarativeNetRequest`, native messaging. Also DevTools, find, zoom,
  downloads, printing, the password manager and chrome:// pages.
- **Housekeeping:** today tabs are archived after 12 hours (configurable),
  and ⌘⇧T reopens closed tabs. Tabs you have not looked at for two hours
  (configurable) go to sleep: their page closes and loads again when you
  come back. Tabs playing something, or whose page would ask before
  leaving, stay awake.
- **HTTPS only** (Settings › Allgemein): Chromium's HTTPS-First mode,
  which loads http:// addresses over HTTPS and warns before falling back.
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
CEF 156 (Chromium 156) with codecs, binaries in Vendor/cef
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
- **The full Arc import is new.** Moving logins, passwords and extensions has
  been tested on copies of Arc profiles, not yet on many real ones. Arc's own
  data is never changed.
- **No Widevine.** DRM video such as Netflix does not play, and Google sync
  for Chromium forks is not available.
- **Not built yet:** Easels and Notes.
- **Full screen is new.** Video full screen gets its own space like in
  Chrome; `--selftest --fullscreen-test` checks it visibly.

## Layout

- `App/`: the browser
- `website/`: the website, published by `.github/workflows/pages.yml`
- `scripts/fetch-cef.sh`: downloads the pinned CEF binary distribution into `Vendor/cef`
- `scripts/update-cef.sh`: moves the pin to the newest stable CEF build
- `scripts/patch-cef.swift`: lowers CEF's 2 s wait before extension popups appear
- `scripts/make-icons.sh`: draws the app icon and the website's from `AppIcons.swift`
- `scripts/cef-codecs.sh` and `.github/workflows/cef-codecs.yml`: build CEF
  with H.264/AAC/HEVC on GitHub (started by `update-cef.sh`; about ten hours)
- `spikes/01-cef/`: first spike, CEF embedded in AppKit ([results](spikes/01-cef/RESULTS.md))
