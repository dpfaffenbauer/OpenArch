---
title: "Architecture"
description: "How OpenArch is put together: a Swift app around Chromium, where every tab is a real Chrome tab in a window of its own."
---

OpenArch is a native Mac app around Chromium. The sidebar, the command bar and everything else you see around the page are Swift. The pages are Chrome.

```
Swift / AppKit / SwiftUI app        App/Sources/OpenArch
  sidebar, command bar, spaces, library, Arc import, AI features
        │  a narrow Objective-C API
OpenArchCore (Objective-C++)        App/Sources/OpenArchCore
  OACEngine, OACProfile, OACPage, OACPane
        │
CEF (Chromium) with codecs          Vendor/cef
```

## Every tab is a real Chrome tab

Each tab is an `OACPane`: a Chrome-style CEF browser in a borderless window of its own, attached as a child window over OpenArch's content area. To Chromium it is an ordinary Chrome tab, so extensions, `chrome.tabs`, side panels, DevTools, the password manager and `chrome://` pages work as in Chrome. Browsers embedded the simpler way ("Alloy" style) lack most of that; `spikes/01-cef/RESULTS.md` has the details.

CEF allows one Chrome-style browser per window. Split view therefore places several of these windows side by side.

## Pages with Safari's engine

Streaming services open in a `WebKitPage` instead (`App/Sources/OpenArch/Browser/WebKitPage.swift`): a `WKWebView` in a borderless window of its own, attached the same way. Both kinds of page meet the `OACPage` protocol (`OACPage.h`) and report to the same delegate, so the sidebar, split view, Peek, Little OpenArch, previews, the media player and sleeping tabs treat them alike. `ProtectedMedia.swift` holds the list of services and decides which engine a page gets; a Chromium page's navigation to a listed site is stopped in `OnBeforeBrowse` and the tab gets a WebKit page at that address. The built-in extension's media scripts run in WebKit pages as user scripts. See [Streaming services](/browsing/protected-media/).

## Profiles

Every space uses a profile, an `OACProfile`, which is a Chromium profile with its own cookies, logins, history, passwords and extensions. A private window gets a profile that lives only in memory.

## The extension built in

OpenArch loads a small extension of its own into every profile (`App/Resources/BuiltinExtensions/openarch`). It tells the sidebar which tabs play audio and video, and what, and which share the screen. It reports through the page's console, which OpenArch reads.

## The AI features

OpenArch does not talk to a model itself. It starts the Claude Code command line tool and reads its answers; see [How OpenArch talks to Claude](/ai/how-it-works/).

## Sharing

The sharing format, its cryptography and the relay client are a Swift package of their own (`Shared/`), used by the Mac and the iOS app. The relay is a Cloudflare Worker (`relay/`). `docs/sharing.md` describes the format and the threat model; [How sharing works](/sharing/how-it-works/) is the short version.

## The repository

| Folder | What is in it |
| --- | --- |
| `App/` | The Mac app |
| `iOS/` | OpenArch for iPhone and iPad |
| `Shared/` | The Swift package both use for sharing |
| `relay/` | The relay for live shares, a Cloudflare Worker |
| `website/` | openarch.app, and `website/s/`, which shows shared links to people without OpenArch |
| `docs-site/` | These docs |
| `docs/` | The sharing format and App Store notes |
| `scripts/` | Fetching, updating and building CEF; drawing the icons |
| `spikes/` | The first experiments with CEF |
