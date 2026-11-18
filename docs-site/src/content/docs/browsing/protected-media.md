---
title: "Streaming services"
description: "Spotify, Netflix, Disney+ and other services that protect their media with DRM open with Safari's engine, in the same tab, so they can play."
---

Spotify, Netflix, Disney+ and the other big streaming services protect their music and video with DRM. In a Chromium browser they ask for Widevine with a certification (Verified Media Path) that only Chrome and paid partners have. Safari's engine plays them with Apple's FairPlay, which macOS gives every app. So OpenArch opens these sites with Safari's engine (WebKit), in the same tab, and every other site with Chromium.

The first time a service opens, a message over the page says so: "Spotify spielt mit Safaris Engine". **Warum?** opens the Site Control Center, which explains it; ✕ closes the message. It shows once per service.

## Which sites

A page on one of these sites, or a subdomain, opens with Safari's engine:

open.spotify.com, netflix.com, disneyplus.com, max.com, hbomax.com, primevideo.com, Prime Video on Amazon's stores (amazon.\*/gp/video), Amazon Music (music.amazon.\*), hulu.com, paramountplus.com, peacocktv.com, tv.apple.com, music.apple.com, listen.tidal.com, deezer.com, crunchyroll.com, joyn.\* (any country) and rakuten.tv.

With [Streaming services in Chromium](#streaming-services-in-chromium) on, open.spotify.com, netflix.com and disneyplus.com are not on this list.

The rest of Amazon stays in Chromium. Sign-in pages never count: accounts.spotify.com, login.tidal.com, connect.deezer.com and account.deezer.com stay in the engine they were opened in, because other sites send their "Sign in with Spotify" through them.

## Which engine a page gets

- **An address OpenArch opens** (one you type in the command bar, a new tab, a restored, pinned or favorite tab, a link from another app, Little OpenArch, Peek): Safari's engine for a listed site, Chromium for anything else.
- **A link in a Chromium page** to a listed site opens it with Safari's engine before the page leaves, in the same tab and the same side of a split view. A redirect does the same once it reaches the service (a t.co link, a link from a mail). **A form sent to the service stays in Chromium**: what it sends cannot move.
- **A page with Safari's engine keeps it** for everything it opens by itself, wherever it goes: signing in goes through Google or Apple and has to come back to the same cookies. Only an address you type picks the engine again.
- **A pop-up window** (a sign-in window) keeps the engine of the page that opened it, so it can report back to that page. A link that opens a new tab follows the rules above.

## Your choices

- **Settings › Allgemein › Geschützte Inhalte › DRM-Seiten mit Safaris Engine abspielen** is on. Off, every page you open from then on is Chromium's.
- **Settings › Allgemein › Geschützte Inhalte › Streamingdienste in Chromium abspielen** is off. On, Spotify, Netflix and Disney+ stay in Chromium and play with FairPlay there: see [Streaming services in Chromium](#streaming-services-in-chromium).
- **Site Control Center › Safaris Engine**: switch it off on a service to send the site back to Chromium, or on for any other site to try it with Safari's engine. The page opens again in the other engine at once. These choices, and which services' message you have seen, are kept in `protected-media.json` in OpenArch's data folder.

## Streaming services in Chromium

Spotify, Netflix and Disney+ can stay Chromium pages, with your Chrome extensions, your password manager and the logins Chromium already has. Turn on **Settings › Allgemein › Geschützte Inhalte › Streamingdienste in Chromium abspielen**. It is off by default and applies to pages you open from then on; Netflix follows after OpenArch starts again, and opens with Safari's engine until then. In a private window these services open with Safari's engine as before.

Chromium still has no DRM that these services accept, so picture and sound do not come from Chromium. OpenArch offers the site's player FairPlay, as Safari does, and plays what the player hands over with Apple's own player. The licence is asked for by the site's own code in the page, signed in as you, and the media stays encrypted until Apple's decoder.

### Spotify

The player hands over each track's playlist, and a small helper process inside OpenArch plays it.

- **The tab shows its speaker**, and muting the tab mutes the track.
- **The media player in the sidebar** has the title, the cover, play and pause, Spotify's own next and previous track and the position.
- **macOS shows the track under Now Playing**, as OpenArch, and the media keys reach it.
- **The helper fetches the track's audio and its cover**, not the page: from Spotify's servers over https, with macOS's network settings. Chrome extensions do not see these requests.
- **Only Spotify's music.** Its music videos and video podcasts do not play this way.

### Netflix and Disney+

The page tells these sites it is Safari, and so do the requests to Netflix, which a small extension of OpenArch's own changes. It is loaded when OpenArch starts with the setting on, which is why Netflix waits for a restart. Their player loads the film as it does in Safari, and OpenArch draws the picture over the page's video, with a copy of the site's own controls on top. The controls look and work as on the site: a click goes through the copy to the real ones.

- **The tab shows its speaker**, muting the tab mutes the film, and the media player in the sidebar has play, pause and the position.
- **Picture in Picture** is macOS's own, with play, pause and skip, also when you leave the tab while the film plays.
- **Full screen** is the page's own, as on other pages: the picture and the controls go with the page into its full-screen space and come back with it.
- **The copy of the controls** is drawn by Safari's engine without cookies, which loads the site's style sheets, fonts and images for it once more.

**Other services** (Prime Video, Max, Apple TV and the rest of the list) open with Safari's engine as before.

### When something does not play

A message says so once per page. **Mit Safaris Engine öffnen** sends the site to Safari's engine and keeps it there; the Site Control Center switches it back. This way of playing depends on the sites' players: when a service changes its player, it may stop working until OpenArch follows, and Safari's engine plays the service meanwhile.

## Your data on these pages

Each profile has its own WebKit store for cookies, storage and cache, and a private window has one in memory only, gone when it closes. Logins from Chromium, including those imported from Arc, are not in it: you sign in to each service once more. The stores live under `~/Library/WebKit/dev.openarch.browser/WebsiteDataStore/`. The pages tell the sites they are Safari, with this Mac's Safari version, because the services choose their DRM by browser.

## What works the same

The tab in the sidebar with its title and icon, split view, Peek, Little OpenArch, tab previews and the <kbd>⌃Tab</kbd> switcher, the media player in the sidebar (title, artist, play and pause, the service's own next and previous track), picture-in-picture when you leave a tab with a playing video, sleeping tabs, find (<kbd>⌘F</kbd>, with the number of matches), zoom, printing, downloads (into the Downloads folder and the library), boosts, the page chat and clearing a site's data in the Site Control Center.

## What does not

- **Chrome extensions** do not run on these pages, password managers' autofill included, and there is no Chrome toolbar. Sign in by hand, or from the password manager's own app.
- **Chrome's DevTools**: <kbd>⌥⌘I</kbd> opens Safari's Web Inspector in a window of its own.
- **Chromium's site settings** (camera, microphone, notifications …) do not apply; Safari's engine asks itself.
- **Browser tools that click and type** for the page chat and agents work only on Chromium pages; reading, screenshots and scrolling work on both.
- **Screen sharing** from these pages does not show the red card in the sidebar.

## Widevine in Chromium

Chromium's own Widevine module is installed by Google's component updater, as in every Chromium. Pages may use it only with **Settings › Allgemein › Geschützte Inhalte › Geschützte Inhalte (Widevine)** on, which is off and takes effect after OpenArch starts again. It plays streams whose licence servers ask for no certification, such as Shaka Player's public demo streams, not Netflix or Spotify.
