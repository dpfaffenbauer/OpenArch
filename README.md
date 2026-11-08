# OpenArch

An open-source, Chromium-based browser for macOS in the spirit of Arc:
sidebar with favorites, pinned folders and today tabs, Spaces with their own
profiles, a command bar, split view, and real Chrome extensions. With a
companion for iPhone and iPad, and folders and spaces shared as encrypted
links, without an account.

Status: early, but usable as a daily browser for testing.
[Download the latest release](https://github.com/dpfaffenbauer/OpenArch/releases/latest)
(Apple silicon, macOS 15 or later) or see [openarch.app](https://openarch.app).
How everything works: [docs.openarch.app](https://docs.openarch.app).

## Build and run

```sh
App/build.sh                      # fetches CEF, builds App/build/OpenArch.app
open App/build/OpenArch.app
App/build/OpenArch.app/Contents/MacOS/OpenArch --selftest   # automated checks, runs behind other windows
App/build/OpenArch.app/Contents/MacOS/OpenArch --selftest --ai-test   # only the AI features, with a stand-in for claude
App/build/OpenArch.app/Contents/MacOS/OpenArch --selftest --sidebar-test   # only the sidebar details below
```

Requires Xcode 16+ (Swift 6), CMake and Ninja.

OpenArch for iPhone and iPad: open `iOS/OpenArch.xcodeproj` in Xcode and run
it (choose your team under Signing for a device). `ios.yml` builds it for the
simulator on every push that touches it, runs its self-test there
(`-selftest`, see `iOS/OpenArch/SelfTest.swift`) and keeps the screenshots.
On iPhone Duo (built with Xcode 27.1 or later), the page goes to the display's
edges, the controls float beside the status bar's symbols and shrink while
reading, and the layout keeps clear of the fold.

The App Store previews come from a debug build's `-demo` run with made-up sites
(`iOS/OpenArch/Demo.swift`), cut by `scripts/app-preview.py`.

GitHub Actions builds every push (`.github/workflows/build.yml`) and keeps
the newest build of `main` as the
[nightly release](https://github.com/dpfaffenbauer/OpenArch/releases/tag/nightly).
OpenArch's Chromium is its own build of CEF with the proprietary codecs
(H.264, AAC, HEVC) that the official CEF builds leave out, made on GitHub by
`cef-codecs.yml` and published as a release (`cef-156.0.14-codecs`). Once a
day, `update-cef.yml` checks for a newer stable CEF. When there is one, it
starts that build (about ten hours); the next check after it has finished
builds OpenArch with it and opens the update as a pull request, which merges
itself once the checks `main` requires have passed and so publishes a new
nightly. A failed build stops the update and shows up as a failed workflow
run. Data lives in
`~/Library/Application Support/OpenArch` (`Library.json` for the sidebar,
`Chromium/` for Chromium's profiles, `Agents/` for agent chats,
`MorningBrief/` for the morning briefs).

## What works

- **Sidebar:** favorites grid, pinned tabs in folders and subfolders, today
  tabs under the line, drag and drop, inline renaming, context menus. The
  × on a pinned tab unpins it; ⌘-click on a link opens it as a tab in the
  background. ⌘-click on a tab (or a folder) in the sidebar loads it in the
  background, so its page and title are there when you come to it.
  ⇧-click selects a range of rows, ⌘⇧-click (or ⌘-click while rows are
  selected) one more; selected rows drag together, and their menu archives
  them, puts them in a new folder ("Neuer Ordner mit N Tabs") or another
  space, and copies their URLs (⇧⌘C too). Resting on a closed folder shows a
  searchable list of its tabs. Favorites and pinned tabs of Gmail, X,
  WhatsApp, Slack, Outlook and the like get a dot while their title reports
  unread items; Google Calendar's icon shows today's date.
- **Spaces:** name, icon (SF Symbol or emoji), color, and a profile each.
  Drag the icons at the bottom of the sidebar into the order you want, or
  sort, rename, edit and delete them in "Spaces verwalten …" (space menu,
  library); deleting one says what happens to its tabs and archives them.
  Resting on the space's name shows its profile and that profile's Google
  account; with several profiles the space icons get a ring in the
  profile's color.
  Profiles keep logins (e.g. a different Google account per space), cookies,
  history, passwords and extensions apart.
- **GitHub live folders** (+ › GitHub-Live-Ordner): pinned folders that
  fill themselves with your open pull requests, review requests or issues,
  every five minutes, with the space's own GitHub login (no token). A pull
  request shows whether its checks passed, failed or still run, as on
  GitHub (a check, a cross or a dotted circle; the pointer on it gives
  GitHub's count).
- **Command bar** (⌘T, ⌘L): completes the address as you type, like Chrome
  (→ keeps it, Backspace drops it); URL or search with suggestions, switch to open
  tabs, pinned tabs and favorites, history, archived tabs, commands. A
  sentence or a question opens a new chat on Claude or ChatGPT with it,
  signed in as you there (your subscription, no API key; Settings › KI).
  "new doc", "new sheet", "new slides", "new meet", "new gist", "new repo",
  "new notion", "new linear" or "new ticket" (also "neues Dokument" …) go
  straight to a new one, as in Dia; "new ticket" opens your company's Jira
  if the history knows it.
- **Split view:** up to four tabs side by side or one above the other,
  with resizable dividers; ⌃⇧S swaps the sides. Use ⌃⇧=, or drag a tab from the sidebar onto a
  half of the page: left or right puts it beside, top or bottom above or
  below. Links dragged from a page, Safari, Mail or Finder onto the
  sidebar become tabs.
- **Library** (⌥⌘B): media (all images and videos in Downloads and on the
  Desktop), downloads, spaces and archived tabs, searchable. A download
  flies into the library button, a ring around it shows the progress, and
  it bounces when the file is there. Running downloads are listed in the
  library with a button to cancel them; resting the pointer on a file shows
  a preview. As in Arc, a click on the library button shows the newest
  downloads over the sidebar, the newest nearest the button: a click opens
  one, and it drags into other apps like a file from Finder. A right click
  on the button opens the library, chooses which kinds of files the
  downloads show, or turns them off so the click opens the library again.
- **Links to apps** (bambustudioopen:, zoommtg:, mailto: …) open the app on
  the Mac after asking, as in Chrome; „Links von <host> immer in „<App>“
  öffnen“ remembers it per site.
- **Arc's look:** your space's color with white text, Arc's row sizes, and
  favicons taken from Arc's own icon cache. Or glass (Settings › Allgemein ›
  Sidebar): the desktop shows through the window, on macOS 26 as one sheet
  of Liquid Glass tinted with the space's color, the sidebar directly on it
  and the pages floating above as cards. Drag the sidebar edge far to the
  left to collapse it, ⌘S brings it back. Settings › Allgemein › Sidebar ›
  Körnung puts Arc's grain on the color.
- **Tab previews:** resting the pointer on a tab in the sidebar shows a
  picture of its page beside the sidebar, with its title and address (and a
  pull request's checks); moving down the list switches it at once.
- **Arc's gestures and shortcuts:** swipe sideways over the sidebar
  (trackpad or Magic Mouse) to change spaces, and past the first one to open
  the library. Arc's shortcuts are there too: ⌘T, ⌘L, ⌘S, ⌘D, ⌘⇧K, ⌘⇧L,
  ⌘⇧J, ⌃Tab (hold ⌃ for the tab switcher), ⌘1–9, ⌃1–9, ⌘⌥←/→, ⌃⇧= / ⌃⇧-, ⌃⇧1–4, ⌘⇧⌥C and more. They take
  precedence over the page, like in Arc. Settings › Tastatur lists every
  menu command: click a shortcut and press new keys (with ⌘ or ⌃) to make it
  your own; a shortcut taken from another command leaves it, ⌫ removes one.
- **Little OpenArch** (⌥⌘N): a small window for quick links. Links from
  other apps open as a new tab in the window, or there if you turn it on
  under Settings › Links. It has back, forward and reload, and the puzzle
  button shows Chrome's toolbar with your extensions. "In Space öffnen" moves
  the page into the main window without reloading it.
- **Agent chats** (Settings › KI › Agents in der Sidebar): a chat with
  Claude Code sits in the sidebar like a tab and shows where the page
  would be. It runs the `claude` command line tool in a folder of your
  choice, on your own login (your subscription, no API key), continues its
  session with every message and keeps working while you are in other
  tabs: a wheel while it works, a dot when it has answered. With AI control
  on, it gets OpenArch's tabs as tools too. What it may do on its own is
  set per chat (ask, edit files, everything); a refused command shows in
  the chat with a button to allow it. Start one from the sidebar's + menu,
  Ablage › Neuer Agent-Chat, or the command bar (a sentence, then
  "Agent-Chat starten"). Beside the chat, as in the Claude app, a panel
  shows where the agent works (folder, repository, branch, model), how full
  its context is, its connectors (MCP servers), the files changed since the
  last commit with their diff, and the output of its last commands.
- **Agents** (the ✨ in the space bar, or ⌃0): like a space of its own,
  the sidebar lists every agent chat and every Claude Code session on this
  Mac from the last 30 days (read from Claude Code's own transcripts in
  `~/.claude/projects`), one line each like in the Claude app, grouped by
  status (waiting for you, at work, open todos, resting) or by project, with
  a search field; the page or chat in front stays. The ✨ gets a dot while
  sessions wait for you. A session continues as an agent chat with its
  history, or in Terminal.
- **Chat with the page** (⌘E, as in Dia): a chat with Claude opens beside
  the page and gets its address, title and text. Text selected on the page
  goes along as the focus of the question (also right-click › Claude
  fragen), and @ in the field lists the space's tabs and adds their text,
  to compare or sum up several. Answers stream in as in agent chats, and
  their links open as tabs. ⌘E or Esc closes the chat; it keeps its
  conversation until the tab closes. Like agent chats it runs the `claude`
  command line tool on your own login, in a folder of its own. It can also
  act in your tabs with OpenArch's own browser tools (`BrowserTools`, an MCP
  server on 127.0.0.1 with a secret per chat; no AI control, no Node):
  reading, screenshots and scrolling at once, clicking, typing and opening after „Erlauben und weiter“
  once per chat. A tool row in a chat opens to the whole command and what
  came back.
- **Skills in the command bar:** typing the name of one of your Claude Code
  skills (`~/.claude/skills`) or slash commands (`~/.claude/commands`) lists
  it with its description, and a / lists them all. Choosing one runs it on
  the page in front, in the page's chat. OpenArch only reads their names
  and descriptions; Claude Code runs them.
- **Morning Brief** (Settings › KI): once a day at the time you choose
  (7:30 unless you change it), or at the first launch after it, Claude Code
  looks through your calendar, new mail, chat messages and open tasks with
  whatever connectors (MCP servers) it has and writes a page about the day.
  It opens as a tab "Morning Brief" at the top of the today tabs, with a dot
  until you read it; "Morning Brief jetzt erstellen" in the command bar
  makes it at once. Claude only gets the connectors' reading tools (get,
  list, search …), so a mail cannot make it send or delete anything. The
  prompt is a file of its own (`App/Resources/MorningBrief.md`; Bearbeiten …
  in the settings makes your own copy). Without `claude` on the Mac, or
  without its login, the tab says so.
- **Tidy tabs with AI** ("Tabs mit KI aufräumen" in the command bar): Claude
  sorts the current space's today tabs into folders with short names, an
  emoji in front, and suggests shorter titles. It gets only the tabs' titles
  and addresses. The proposal shows first and changes nothing until
  "Übernehmen"; then the folders sit at the top under the line, and ⌘Z or
  Rückgängig in the toast puts everything back. Pinned tabs and favorites
  stay as they are.
- **AI control:** turn it on under Settings › KI. OpenArch then opens Chrome's
  DevTools protocol on 127.0.0.1:9222, so Claude Code can drive the real
  browser and its tabs:
  `claude mcp add openarch -- npx -y chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222`.
  An antenna icon in the sidebar shows while the port is open.
- **Windows:** ⌘N opens another window on the same spaces and tabs; a tab
  moves to the window that shows it. ⌘⇧N opens a private window with its
  own in-memory profile and no history. A tab dragged out of the sidebar
  onto the desktop becomes a window of its own there: its space's profile
  and color, tabs of its own, but no favorites, pinned tabs or other
  spaces. "In Space verschieben" (or dragging a tab back into the main
  window) brings a tab back; closing the window puts its tabs in the
  archive. ⌘⇧T brings back the last closed window where it was, tabs and
  all, when it closed after the last tab (as in Chrome and Dia); Ablage ›
  Geschlossenes Fenster wieder öffnen always does.
- **Peek:** links from pinned tabs and favorites to other sites, and
  ⇧-clicks on any link, open in a card over the page, which can become a tab
  or a split. ⌘Z right after closing it, or ⇧⌘T, opens it again; Settings ›
  Links turns it off.
- **Meetings** (Settings › Allgemein › Kalender): the next meeting from the
  Mac's calendars sits at the bottom of the sidebar, with when it starts and
  a button to join the call (Meet, Zoom, Teams, Webex … links in the
  invitation). Shortly before it starts a toast says so. Joining opens the
  call in a folder of its own under the line, and the links you open from
  the call land in it too, as in Dia.
- **Screen sharing:** while a tab shares the screen, a window or a tab (a
  video call), a red card at the bottom of the sidebar says what is shared;
  a click goes to the shared tab, ■ ends the sharing. The sharing tab and
  the shared one carry a red mark in the sidebar.
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
- **Media:** a small player at the bottom of the sidebar for audio and
  video playing in another tab: the cover, title and artist from the page
  (its Media Session) and an equalizer while it plays. Resting the pointer
  on it opens the controls: a position bar to click or drag, the time
  played and left, the page's own previous and next track, play/pause,
  sound and picture-in-picture; ↗ goes to the tab. Spotify on the Mac
  shows there too, from what Spotify tells every app; its buttons control
  Spotify after macOS asks once. Leaving a tab with a video playing keeps
  it going in picture-in-picture.
- **Hover sidebar:** with the sidebar collapsed, the window's left edge
  brings it back over the page.
- **Updates:** OpenArch updates itself from the nightly release (checked
  at launch and every six hours; only builds signed with OpenArch's Developer ID, from its own GitHub releases).
- **Settings** in Arc's style: Allgemein, Profile, Links, Teilen, KI, Import,
  Info.
- **Über OpenArch:** a flight through OpenArch's arches; click the logo for
  warp speed.
- **App icon:** twelve takes on the arch (Tunnel is the standard one), one
  in the current space's color, or a different one each day. While OpenArch
  is closed, a Dock tile plug-in keeps showing it; the app bundle is never
  changed, so its signature stays valid.
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
- **Sharing without an account:** a pinned folder (right-click › Teilen …) or a space
  (Space teilen …) becomes a link and a QR code. *Aktuell halten* keeps it
  live: the bookmarks lie encrypted and signed on a small relay, and
  everyone who added the link gets your changes every five minutes; only
  the Mac or iPhone that shared it can change it. Without it, the bookmarks
  travel inside the link itself and no server is involved. Either can have
  a password. The key is in the link's `#fragment`, so neither the relay
  nor openarch.app ever sees it. A link opens in OpenArch on the Mac or
  iPhone (+ › Geteilten Link öffnen …, or Code scannen on the iPhone), which
  adds it as a folder or a space, following it or as a copy, and on
  openarch.app/s/ for everyone else. Settings › Teilen lists what is
  shared and followed. Format and threat model: [docs/sharing.md](docs/sharing.md).

## OpenArch for iPhone and iPad

The same sidebar on WebKit (iOS only allows WebKit): spaces in their
colors, swiped through sideways; favorites, pinned folders and today tabs,
which go to the archive after twelve hours. The page fills the screen with
a bar below it (sidebar, back, address, new tab, menu); on the iPad the
sidebar sits beside the page, as on the Mac. The address field completes
from the search engine and finds open tabs, favorites and the archive. Your
Mac's spaces come over by sharing them (Space teilen …, Aktuell halten) and
scanning the QR code with the iPhone's camera or Code scannen in OpenArch;
they then follow the Mac. Folders and spaces on the iPhone are shared the
same way.

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

- **Mock keychain.** Every build, the Developer ID builds included, uses
  Chromium's mock keychain (`App/Sources/OpenArch/main.swift`), so saved
  cookies and passwords are not protected by the login keychain. Local
  builds are signed ad hoc.
- **The full Arc import is new.** Moving logins, passwords and extensions has
  been tested on copies of Arc profiles, not yet on many real ones. Arc's own
  data is never changed.
- **No Widevine.** DRM video such as Netflix does not play, and Google sync
  for Chromium forks is not available.
- **Not built yet:** Easels and Notes.
- **Full screen is new.** Video full screen gets its own space like in
  Chrome; `--selftest --fullscreen-test` checks it visibly.

## Hosting

openarch.app, docs.openarch.app and share.openarch.app are Cloudflare
Workers. Cloudflare's GitHub connection (Workers Builds) deploys each from
`main`, so no Cloudflare token lives in this repository:

| Worker | Root directory | Build command | Deploy command |
| --- | --- | --- | --- |
| `openarch` | `website` | – | `npx wrangler deploy` |
| `openarch-docs` | `docs-site` | `npm ci && npm run build` | `npx wrangler deploy` |
| `openarch-share-relay` | `relay` | – | `npx wrangler deploy` |

Each folder's `wrangler.toml` names the Worker and its custom domain;
Cloudflare makes the DNS records and certificates. The docs need Node 24
(`docs-site/.nvmrc`; or the build variable `NODE_VERSION=24`).

## Layout

- `App/`: the browser
- `iOS/`: OpenArch for iPhone and iPad (`OpenArch.xcodeproj`)
- `Shared/`: the Swift package both use for sharing (format, crypto, relay client, tests)
- `relay/`: the relay for live shares, a Cloudflare Worker ([README](relay/README.md))
- `docs/sharing.md`: the sharing format, its threat model and the relay API
- `docs-site/`: the documentation at docs.openarch.app
  ([how the pages are written](docs-site/WRITING.md))
- `website/`: the website at openarch.app;
  `website/s/` shows shared links to people without OpenArch
- `scripts/fetch-cef.sh`: downloads the pinned CEF binary distribution into `Vendor/cef`
- `scripts/update-cef.sh`: moves the pin to the newest stable CEF build
- `scripts/patch-cef.swift`: lowers CEF's 2 s wait before extension popups appear
- `scripts/make-icons.sh`: draws the app icon and the website's from `AppIcons.swift`
- `scripts/cef-codecs.sh` and `.github/workflows/cef-codecs.yml`: build CEF
  with H.264/AAC/HEVC on GitHub (started by `update-cef.sh`; about ten hours)
- `spikes/01-cef/`: first spike, CEF embedded in AppKit ([results](spikes/01-cef/RESULTS.md))
