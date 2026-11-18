---
title: "Architecture"
description: "How OpenArch is put together: a Swift app on Chrome's own framework, where every tab is a real Chrome tab."
---

OpenArch is a native Mac app on Chrome's own framework. The sidebar, the command bar and everything else you see around the page are Swift. The pages are Chrome.

```
Swift / AppKit / SwiftUI app        App/Sources/OpenArch
  sidebar, command bar, spaces, library, Arc import, AI features
        │  a narrow Objective-C API
OpenArchCore (the bridge's headers)  App/Sources/OpenArchCore
  OACEngine, OACProfile, OACPage, OACPane
        │
OpenArch's layer (Objective-C++)    engine/chromium/openarch
  inside Chrome's framework (Chromium Framework.framework)
```

## Every tab is a real Chrome tab

Each tab is an `OACPane`: a tab in a Chrome window of its profile that never shows. Its page's view is shown in OpenArch's window, where the sidebar, split view, Peek or Little OpenArch put it. To Chrome it is an ordinary tab, so extensions, `chrome.tabs`, side panels, DevTools, the password manager and `chrome://` pages work as in Chrome. OpenArch's toolbar above the page has the extensions' buttons and popups.

OpenArch's layer is compiled into Chrome's framework, with a few hooks in Chrome's code (`engine/chromium/apply.sh`): new tabs, keys, navigations, dialogs, permission prompts and the context menu reach OpenArch instead of Chrome's window. All tabs in one window take a fraction of the memory one window per tab did (about 0.6 GB for 20 tabs, against 3.5 GB). `docs/chromium-engine.md` has the details.

## Pages with Safari's engine

Streaming services open in a `WebKitPage` instead (`App/Sources/OpenArch/Browser/WebKitPage.swift`): a `WKWebView` in a borderless window of its own, attached the same way. Both kinds of page meet the `OACPage` protocol (`OACPage.h`) and report to the same delegate, so the sidebar, split view, Peek, Little OpenArch, previews, the media player and sleeping tabs treat them alike. `ProtectedMedia.swift` holds the list of services and decides which engine a page gets; a Chromium page's navigation to a listed site is stopped before its request goes out and the tab gets a WebKit page at that address. The built-in extension's media scripts run in WebKit pages as user scripts. See [Streaming services](/browsing/protected-media/).

## Streaming services in Chromium

With **Streamingdienste in Chromium abspielen** on, Spotify's, Netflix's and Disney+'s pages stay `OACPane`s, and OpenArch plays their media with Apple's FairPlay. Both ways are adapted from Ardia (see `NOTICE`). In both, a script of the built-in extension runs in the page's own world before the site's scripts and answers for the page's media element (`currentTime`, `paused`, its events), which never plays; macOS makes the key request, the page's own code trades it for the licence with the service, and the licence goes back to Apple's player. `OPENARCH_FAIRPLAY_TRACE=1` writes each step to OpenArch's log, without keys, licences or media. `--selftest --fairplay-test` runs both chains with pages of its own and media without DRM. See [Streaming services in Chromium](/browsing/protected-media/#streaming-services-in-chromium).

**Spotify (audio):**

- `fairplay.js` answers the page's request for FairPlay and takes the HLS playlist the player gives its media element.
- `FairPlay.swift` checks what the page sends (sizes, and that the playlist loads over https only) and runs the helper. The page that loads a track owns the helper; a page that had it reads as paused.
- `OpenArchFairPlay` (`App/Sources/OpenArchFairPlay`, in `Contents/Helpers`) is a sandboxed process with `AVPlayer` and `AVContentKeySession`. It also is what macOS shows under Now Playing.
- The page talks to OpenArch through its console and hears back as a DOM event, like the media scripts.

**Netflix and Disney+ (video):**

- `protected-video.js` makes the page look like Safari (user agent, `WebKitMediaKeys`, no `window.chrome`) and replaces the `SourceBuffer`s of the player's `MediaSource`: what the player appends goes to OpenArch instead of Chromium's decoder. It also sends a copy of the player's DOM (the "video mirror"). The extension's background registers the script only while the setting is on; `protected-video-relay.js` tells it, and the background loads a page again that started without it.
- Netflix also wants Safari's user agent on the requests themselves, which takes `declarativeNetRequest`. An extension with that permission sends every page's requests through Chromium's web request proxy, so the rule is not in the built-in extension but in one of its own (`Resources/OptionalExtensions/safari-user-agent`), which `main.swift` loads at launch only while the setting is on. Until that launch, Netflix keeps Safari's engine (`ProtectedVideo.safariUserAgentLoaded`).
- `OpenArchProtectedVideo` (`App/Sources/OpenArchProtectedVideo`, Objective-C++) parses the segments (`AVStreamDataParser`, a private class of AVFoundation), decodes and draws them with `AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer` in a view right above the page's, where the page's `<video>` is, and has the keys from `AVContentKeySession`. `OAVideoMirror` draws the copy of the controls in a `WKWebView` without scripts above that view; clicks go through both to the page.
- `ProtectedVideo.swift` carries the messages. Video is megabytes a second, too much for the console: the page's script queues its messages and says so once through the console, and OpenArch fetches the queue with the DevTools protocol (`Runtime.evaluate`), acknowledging how far it got, until it is empty (about 40 MB a second in the self-test). Answers go back as a DOM event. It finds the page's view by its class (`WebContentsViewCocoa`) at the pane's place on screen, since the bridge does not hand it out: in the window that shows the pane, or in the window of its own that a page in full screen gets.
- `media.js` reports what OpenArch plays to the sidebar's player for both.

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
| `engine/chromium/` | OpenArch's layer in Chrome's framework, its hooks and the Chrome version |
| `scripts/` | Building, fetching and updating the engine; drawing the icons |
