---
title: "Data and privacy"
description: "Where OpenArch keeps your data, what leaves your Mac and when, and how to turn each of it off."
---

OpenArch has no account, no analytics and no telemetry. Crash reports go out only when you send them yourself. What it keeps stays on your Mac, in one folder. This page lists that folder, and everything OpenArch itself sends anywhere. The websites you open talk to whoever they talk to, as in any browser.

## Where your data is

Everything lives in `~/Library/Application Support/OpenArch`. **Settings › Info › Daten** opens it in Finder.

| In the folder | What it holds |
| --- | --- |
| `Library.json` | Your spaces, favorites, pinned folders, today tabs, the archive and your settings |
| `Chromium/` | Chromium's profiles: cookies and logins, saved passwords, site data, extensions and their settings |
| `History.sqlite` | The history the command bar searches |
| `Shares.json` | Folders and spaces you share or follow, with their keys |
| `Favicons/` | Icons of the sites in your sidebar |
| `Agents/` | Your [agent chats](/ai/agent-chats/) |
| `PageChats/`, `MorningBrief/`, `TabTidy/` | The folders the [AI features](/ai/how-it-works/) run Claude Code in; `MorningBrief/` also keeps each day's brief |
| `Boosts.json` | Your [Boosts](/browsing/site-controls/) |
| `BuiltinExtensions/` | A copy of the extension built into OpenArch, which tells the sidebar what plays and what is shared |
| `CrashReports/` | Crashes noted since the last launch, until you send or dismiss the report |
| `Backups/` | The daily backups, unless you chose another folder |

A private window (<kbd>⇧⌘N</kbd>) keeps nothing: its profile lives in memory and is gone when the window closes.

## The key to your passwords and cookies

As in Chrome, saved passwords, cookies, card numbers and a few other values in `Chromium/` are encrypted with a key from your login keychain. OpenArch keeps it as **OpenArch Safe Storage**; Keychain Access shows it under that name.

OpenArch makes the key itself at its first launch, so macOS does not ask. Updates read it without asking too.

macOS asks only when the key is there but this copy of OpenArch may not read it yet, for example because a copy signed differently made it. OpenArch explains first, then macOS asks for your Mac password. Choose **Immer erlauben** (Always Allow). OpenArch then keeps the key in an item of its own, and the question does not come back.

If you used OpenArch before it had this key, the first launch with it moves your saved passwords and cookies to the new key before any page opens. It copies the files it changes to `Chromium/OpenArch Keychain Backup` first and puts them back if anything fails. The copy is deleted at the next launch.

:::caution[Keep the key]
Don't delete **OpenArch Safe Storage** from your keychain. Without it, OpenArch can't read your saved passwords and cookies, and you sign in to websites again.
:::

## What leaves your Mac

These are the only things OpenArch itself sends. Each row says what goes where, and how to stop it.

| What | Goes to | When | To stop it |
| --- | --- | --- | --- |
| What you type in the command bar | For suggestions: DuckDuckGo or Bing when that is your search engine, Google for all others (also Ecosia and Kagi) | As you type | **Settings › Allgemein › Suchen › Suchvorschläge** |
| A request for a site's icon | That site | When a tab in the sidebar has no icon yet | — |
| A check for updates | GitHub (OpenArch's releases; on Stable, also GitHub's list of them) | At launch and every six hours | **Settings › Info › Updates › Automatisch aktualisieren** |
| A request for the feature switches | openarch.app (`/feature-switches.json`), with nothing about you in it | At launch and every six hours | — |
| A crash report | github.com, as an issue you send yourself | Only when you choose **Bericht senden …** after a crash | **Settings › Info › Absturzberichte** |
| Your GitHub pull requests and issues | github.com, signed in as the space's profile | Every five minutes, for each [live folder](/sidebar/live-folders/) | Delete the live folder |
| Folders and spaces you share with **Aktuell halten** | share.openarch.app, encrypted | When you change them, and every five minutes for links you follow | **Settings › Teilen › Von diesem Mac geteilt › Beenden**; see [How sharing works](/sharing/how-it-works/) |
| What the AI features give Claude | Anthropic, through Claude Code on your Mac | When you use them | Don't use them; see [How OpenArch talks to Claude](/ai/how-it-works/) |
| A question for Claude or ChatGPT on the web | claude.ai or chatgpt.com, in the address | When you choose it in the command bar | See [Claude and ChatGPT on the web](/ai/web-chats/) |

## What stays on your Mac

- **Your calendar.** The [meeting card](/sidebar/cards/) reads the Mac's calendars, which macOS asks you about first, and sends nothing anywhere.
- **What plays and what is shared.** The media player and the screen sharing card learn it from the pages in your tabs.
- **Shared links' keys.** A shared link's key is in its `#fragment`, which browsers never send to a server. Neither share.openarch.app nor openarch.app sees your bookmarks.

## Daily backup

Once a day, OpenArch copies `Library.json` (spaces, favorites, tabs, link rules and the settings kept with them), `Boosts.json` and its other settings (as `Settings.plist`) into a folder named `OpenArch Backup <date>`. The newest 14 stay; older ones are deleted, and nothing else in the folder is touched.

- **Settings › Info › Sicherung › Tägliche Sicherung** turns it off; **Jetzt sichern** makes one now.
- **Ordner › Wählen …** puts the backups elsewhere, for example in a folder in iCloud Drive. At first they go to `Backups/` in OpenArch's folder.
- **Exportieren …** writes a backup into a folder you choose, as `OpenArch Export <date> <time>`.
- **Importieren …** brings one back: choose its folder. OpenArch first backs up what is there now, then restarts with the backup's sidebar, boosts and settings. The library it replaced stays beside it as `Library (vor Import <time>).json`.

A backup does not hold Chromium's profiles (logins, cookies, passwords, history), your shares and their keys, or agent chats.

## Crash reports

When OpenArch crashes, or a tab's page process, the graphics process or one of Chromium's other helper processes ends unexpectedly, OpenArch notes it in `CrashReports/`. It reads macOS's own crash reports of its processes in `~/Library/Logs/DiagnosticReports` for that, from your first launch of this version on.

At the next launch it asks whether to send a report, and shows the report in full. **Bericht senden …** opens a new issue on github.com with the report filled in; you send it from there, signed in to GitHub, or close the tab. **Nicht senden** forgets it. Either way the noted crashes are deleted.

A report holds OpenArch's, Chromium's and macOS's versions, the update channel, which kind of process ended and how, and the names of the functions the crashing thread was in. It never holds addresses, page titles, file paths or anything from a page.

Turn it off in **Settings › Info › Absturzberichte › Nach einem Absturz fragen**, or with **Nicht mehr nach Abstürzen fragen** in the question. Then OpenArch notes nothing.

## Feature switches

A feature that a new version of Chromium broke can be switched off without holding back an update. At launch and every six hours OpenArch reads a short list from `https://openarch.app/feature-switches.json`: only from that address, and without following a redirect. If the list cannot be read, every feature stays on. The request carries nothing about you; the list says which build and Chromium version a switch applies to, and OpenArch compares that on your Mac. A feature switched off shows in **Settings › Info › Absturzberichte** with the reason.

The switches: `peek`, `tabPreviews`, `agentChats` and `boosts`. To switch one off on your Mac only:

```sh
defaults write dev.openarch.browser disabledFeatures -array peek
defaults delete dev.openarch.browser disabledFeatures   # all on again
```

## The page chat's browser tools

A [page chat's browser tools](/ai/page-chat/#acting-in-the-browser) listen on `127.0.0.1`, at a port the system picks. Each chat's address carries a secret of its own, which only its Claude Code runs get, and a request without it is refused. Nothing outside your Mac can reach them.

## AI control opens a port

[AI control](/ai/ai-control/) opens Chrome's DevTools protocol on `127.0.0.1:9222`. Only programs on your Mac can reach it, but any of them can, and with it they can drive your tabs, signed in as you. An antenna in the sidebar shows while it is open. Turn it off in **Settings › KI** when you do not need it.
