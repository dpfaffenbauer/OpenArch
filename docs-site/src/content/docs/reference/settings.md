---
title: "Settings"
description: "Every tab and option in OpenArch's settings window on the Mac, with what it does, its default, and where it is explained."
---

Open the settings with <kbd>⌘,</kbd> or **OpenArch › Einstellungen …**. The
window has eight tabs: **Allgemein** (general), **Profile**, **Links**,
**Teilen** (sharing), **KI** (AI), **Tastatur** (keyboard), **Import** and
**Info**. Changes apply at once, except where a table says otherwise.

The settings of OpenArch for iPhone and iPad are on
[their own page](/iphone-ipad/#settings).

## Allgemein

### Browser

| Setting | What it does | Default |
| --- | --- | --- |
| **Standardbrowser** | **Als Standard festlegen** makes OpenArch the Mac's browser, so links from Mail, Slack and other apps open in it. Shows **Aktiv** once it is. OpenArch also asks once, after its first launch. See [Links from other apps](/browsing/links/). | |

### Suchen

| Setting | What it does | Default |
| --- | --- | --- |
| **Suchmaschine** | Where searches from the [command bar](/browsing/command-bar/) go: Google, DuckDuckGo, Ecosia, Bing or Kagi. | Google |
| **Suchvorschläge** | The command bar asks the search engine for suggestions while you type. | On |

### Tabs

| Setting | What it does | Default |
| --- | --- | --- |
| **Tabs unter dem Strich archivieren** | Today tabs you have not used for this long go to the archive: after 12 hours, 24 hours, 7 days, 30 days, or never. See [Tabs](/sidebar/tabs/). | nach 12 Stunden |
| **Schlafende Tabs** | Tabs you have not looked at for this long free their memory and load again when you come back: after 30 minutes, 1 hour, 2 hours, 6 hours, or never. Tabs playing sound or with unsaved input stay awake. See [Tabs](/sidebar/tabs/). | nach 2 Stunden |
| **Peek** | Links from pinned tabs and favorites to other sites open in a card over the page. See [Peek](/browsing/peek/). | On |
| **Bild-in-Bild beim Tab-Wechsel** | A video playing with sound goes on in a small window when you leave its tab. See [Player, meetings and screen sharing](/sidebar/cards/). | On |
| **Chrome-Toolbar in Tabs** | The address bar, extension icons and downloads above the page (<kbd>⇧⌘D</kbd>). See [Extensions and Chrome features](/browsing/chrome/). | On |
| **Adresse oben in der Sidebar** | The page's address at the top of the sidebar. See [The sidebar](/sidebar/basics/). | Off |

### Kalender

| Setting | What it does | Default |
| --- | --- | --- |
| **Nächstes Meeting in der Sidebar** | The next meeting from the Mac's calendars at the bottom of the sidebar, with a button to join the call. macOS asks for access when you turn it on; if it was refused, **Zugriff erlauben …** opens the right place in System Settings. See [Player, meetings and screen sharing](/sidebar/cards/). | Off |

### Sicherheit

| Setting | What it does | Default |
| --- | --- | --- |
| **Nur HTTPS** | `http://` addresses load encrypted first; if that fails, OpenArch asks before opening the page unencrypted (Chromium's HTTPS-First mode). See [Data and privacy](/reference/data-and-privacy/). | Off |

### Sidebar

| Setting | What it does | Default |
| --- | --- | --- |
| **Breite** | The sidebar's width, from 200 to 440 points. Dragging the sidebar's edge does the same; dragging it far to the left hides the sidebar. See [The sidebar](/sidebar/basics/). | 300 |
| **Glas-Effekt** | The desktop shows through the window. From macOS 26 the sidebar floats on it as Liquid Glass, before that as frosted glass; the pages lie beside it as cards. See [Colors, glass and grain](/sidebar/appearance/). | Off |
| **Tönung** | How much of the space's color is in the glass: little lets more of the desktop through, a lot keeps the text easy to read. Only with **Glas-Effekt** on. | Just left of the middle |
| **Körnung** | Arc's fine grain on the space's color. All the way to the left, it is off. See [Colors, glass and grain](/sidebar/appearance/). | Off |
| **Vorschau beim Überfahren** | Resting the pointer on a tab in the sidebar shows a picture of its page beside it. See [Tabs](/sidebar/tabs/). | On |

### App-Symbol

The Dock icon: twelve takes on the arch, **Space-Farbe** (the color of the
space you are in) or **Jeden Tag** (a different one each day). The fixed
icons also show for OpenArch in the Finder. See
[Colors, glass and grain](/sidebar/appearance/). Default: **Tunnel**,
OpenArch's own.

### Seitensuche

The sites you can search straight from the command bar: type a site's
**Kürzel** (keyword) or name, press <kbd>Tab</kbd>, then what you are looking
for. Each row has a name, a keyword and the search address, with `%s` where
the search goes; **–** removes a site. **Seite hinzufügen** adds one,
**Standard wiederherstellen** puts back the original list. See
[The command bar](/browsing/command-bar/).

Default sites:

| Name | Kürzel |
| --- | --- |
| YouTube | `yt` |
| Google | `g` |
| Wikipedia (German) | `w` |
| GitHub | `gh` |
| Google Maps | `maps` |
| Amazon (amazon.de) | `amz` |
| Stack Overflow | `so` |
| MDN | `mdn` |
| npm | `npm` |
| Claude | `cl` |
| ChatGPT | `gpt` |
| Perplexity | `pp` |

## Profile

Every profile with its name, which you can change, and the spaces that use
it. A profile keeps logins, cookies, history, passwords and extensions apart,
for example for a second Google account. **Neues Profil …** adds one. Which
profile a space uses is set in the space itself: double-click its name in the
sidebar. See [Spaces and profiles](/sidebar/spaces/). Default: one profile,
**Persönlich**.

## Links

### Link-Regeln

Links from other apps whose address matches a rule open straight in the space
you chose, or in Little OpenArch. The first matching rule wins. A rule is an
address such as `github.com` (with its subdomains), `*.atlassian.net` or
`docs.google.com/spreadsheets` (a path). **Regel hinzufügen** adds one,
**–** removes it. There are no rules at first. See
[Links from other apps](/browsing/links/).

### Links aus anderen Apps

| Setting | What it does | Default |
| --- | --- | --- |
| **In Little OpenArch öffnen** | Off: links from Mail, Slack and other apps open as a new tab in the window. On: they open in a small window, from which one click brings them into a space. See [Windows](/browsing/windows/). | Off |
| **Standardbrowser** | As under **Allgemein**. | |

## Teilen

See [Share folders and spaces](/sharing/share/).

| Section | What it does | Default |
| --- | --- | --- |
| **Von diesem Mac geteilt** | Your live shares, with their version and whether they have a password. **Link …** opens a share's link and QR code again. A share whose folder or space you deleted keeps showing its last state; **Beenden** ends it. | Nothing shared |
| **Mit dir geteilt** | The folders and spaces you follow, and when they were last checked. **Nicht mehr folgen** keeps one as it is and stops the updates. **Geteilten Link öffnen …** adds a link; **Jetzt aktualisieren** checks all of them now. | Nothing followed |
| **Server für neue Live-Freigaben** | The relay new live shares go to. Leave it empty for `share.openarch.app`. See [How sharing works](/sharing/how-it-works/#your-own-relay). | Empty |

## KI

### Fragen in der Befehlsleiste

| Setting | What it does | Default |
| --- | --- | --- |
| **Fragen an** | Where a sentence or a question typed in the command bar goes, as a new chat on the site, signed in as you: **Claude** (claude.ai), **ChatGPT** (chatgpt.com) or **Aus** (off). See [Claude and ChatGPT on the web](/ai/web-chats/). | Claude |

### Agents in der Sidebar

| Setting | What it does | Default |
| --- | --- | --- |
| **Agent-Chats** | Chats with Claude Code in the sidebar, started from the sidebar's **+**, the command bar or **Ablage › Neuer Agent-Chat**. See [Agent chats and Agents](/ai/agent-chats/). | Off |
| **Ordner für neue Chats** | The folder a new agent chat works in. **Wählen …** picks another. | Your home folder |
| **Claude Code** | Whether OpenArch found the `claude` command line tool, and where. **Erneut suchen** looks again. | |

### Morning Brief

See [Morning Brief](/ai/morning-brief/).

| Setting | What it does | Default |
| --- | --- | --- |
| **Morning Brief** | Once a day, Claude Code writes a page about the day ahead from your connectors. It runs at the time below, or at the first launch of OpenArch after it. | Off |
| **Uhrzeit** | When the brief is made. | 7:30 |
| **Anweisung** | **Bearbeiten …** opens the instructions for the brief as a file you can change. **Jetzt erstellen** makes a brief now. | |

### KI-Steuerung

See [AI control](/ai/ai-control/).

| Setting | What it does | Default |
| --- | --- | --- |
| **KI-Steuerung erlauben** | Opens Chrome's DevTools protocol on `127.0.0.1`, so Claude Code, Playwright or Puppeteer can drive the browser. While it is on, any program on this Mac can control the browser, including signed-in tabs. Takes effect after a restart: **Jetzt neu starten**. | Off |
| **Port** | The port for it. Also takes effect after a restart. | 9222 |
| **Mit Claude Code verbinden** | The command to run once in Terminal so Claude Code can use OpenArch; **Kopieren** copies it. | |

## Tastatur

Every command of the menu bar with its keyboard shortcut. Click a shortcut
and press new keys to change it; **Alle zurücksetzen** puts all of them
back. See [Keyboard shortcuts](/reference/shortcuts/#change-a-shortcut).

## Import

See [Move over from Arc](/start/import-from-arc/).

| Setting | What it does |
| --- | --- |
| **Sidebar und alles andere** | **Importieren …** takes spaces, favorites, folders and tabs from Arc, and if you choose, logins and cookies, passwords, history, website data and extensions. Greyed out when there is no Arc on this Mac. |
| **Extensions aus Arc** | **Ordner anlegen** puts a folder with a Chrome Web Store link for each of Arc's extensions into the sidebar, to install them again. |

## Info

| Setting | What it does | Default |
| --- | --- | --- |
| Version | OpenArch's version and Chromium's. **Über OpenArch …** opens the About window. | |
| **Update-Kanal** | **Stable** (the published versions) or **Nightly** (the newest build of every change). Never installs a version older than yours: back on Stable, OpenArch waits until Stable catches up. See [Install and update](/start/install/#stable-or-nightly). | The channel of the build you downloaded |
| **Automatisch aktualisieren** | Looks for a new version at launch and every six hours, downloads it and installs it at the next quit. See [Install and update](/start/install/). | On |
| Update status | Whether OpenArch is up to date, with **Jetzt prüfen** (check now); once an update is ready, **Neu starten** installs it. | |
| **Profile, Sidebar und Verlauf** | Where OpenArch keeps its data, `~/Library/Application Support/OpenArch`. **Im Finder zeigen** opens it. See [Data and privacy](/reference/data-and-privacy/). | |
| **Tägliche Sicherung** | Once a day, the sidebar, link rules, boosts and settings into the backup folder; the newest 14 stay. **Jetzt sichern** makes one now. See [Data and privacy](/reference/data-and-privacy/#daily-backup). | On |
| **Ordner** | Where the backups go. **Wählen …** picks another folder, iCloud Drive included; **Zeigen** opens it. | `Backups/` in OpenArch's folder |
| **Export und Import** | **Exportieren …** writes a backup into a folder you choose; **Importieren …** brings one back and restarts OpenArch. | |
| **Nach einem Absturz fragen** | Notes crashes of OpenArch and its processes and asks at the next launch whether to send a report, as a GitHub issue you send yourself. See [Data and privacy](/reference/data-and-privacy/#crash-reports). | On |
| **Vorübergehend abgeschaltet** | Shows only when a feature is switched off from openarch.app or on this Mac, with the reason. See [Data and privacy](/reference/data-and-privacy/#feature-switches). | |
| **Quellcode auf GitHub** | **Öffnen** opens OpenArch's repository in a tab. | |

## Settings outside this window

| Where | Setting | Default |
| --- | --- | --- |
| **Ansicht › DevTools anordnen** | Where DevTools open: **Rechts**, **Links**, **Unten** or **Eigenes Fenster**. DevTools' own dock menu changes it too. See [Site controls, Boosts and DevTools](/browsing/site-controls/). | Rechts |
| Right-click on the library button | **Klick zeigt die letzten Downloads**: a click on the button shows the newest downloads over it instead of the library. **Darin zeigen** chooses which kinds of files they include. See [Library and downloads](/browsing/library/). | On, all kinds |
| **Ansicht › Website-Einstellungen …** (<kbd>⌃⌘I</kbd>) | A site's permissions, zoom and data. See [Site controls, Boosts and DevTools](/browsing/site-controls/). | |
| **Extensions › Browser-Einstellungen** | Chrome's own settings page. | |
