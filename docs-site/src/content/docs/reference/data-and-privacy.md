---
title: "Data and privacy"
description: "Where OpenArch keeps your data, what leaves your Mac and when, and how to turn each of it off."
---

OpenArch has no account, no analytics and no telemetry. What it keeps stays on your Mac, in one folder. This page lists that folder, and everything OpenArch itself sends anywhere. The websites you open talk to whoever they talk to, as in any browser.

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
| `BuiltinExtensions/` | A copy of the extension built into OpenArch, which tells the sidebar what plays and what is shared |

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
| A check for updates | GitHub (OpenArch's releases) | At launch and every six hours | **Settings › Info › Updates › Automatisch aktualisieren** |
| Your GitHub pull requests and issues | github.com, signed in as the space's profile | Every five minutes, for each [live folder](/sidebar/live-folders/) | Delete the live folder |
| Folders and spaces you share with **Aktuell halten** | share.openarch.app, encrypted | When you change them, and every five minutes for links you follow | **Settings › Teilen › Von diesem Mac geteilt › Beenden**; see [How sharing works](/sharing/how-it-works/) |
| What the AI features give Claude | Anthropic, through Claude Code on your Mac | When you use them | Don't use them; see [How OpenArch talks to Claude](/ai/how-it-works/) |
| A question for Claude or ChatGPT on the web | claude.ai or chatgpt.com, in the address | When you choose it in the command bar | See [Claude and ChatGPT on the web](/ai/web-chats/) |

## What stays on your Mac

- **Your calendar.** The [meeting card](/sidebar/cards/) reads the Mac's calendars, which macOS asks you about first, and sends nothing anywhere.
- **What plays and what is shared.** The media player and the screen sharing card learn it from the pages in your tabs.
- **Shared links' keys.** A shared link's key is in its `#fragment`, which browsers never send to a server. Neither share.openarch.app nor openarch.app sees your bookmarks.

## The page chat's browser tools

A [page chat's browser tools](/ai/page-chat/#acting-in-the-browser) listen on `127.0.0.1`, at a port the system picks. Each chat's address carries a secret of its own, which only its Claude Code runs get, and a request without it is refused. Nothing outside your Mac can reach them.

## AI control opens a port

[AI control](/ai/ai-control/) opens Chrome's DevTools protocol on `127.0.0.1:9222`. Only programs on your Mac can reach it, but any of them can, and with it they can drive your tabs, signed in as you. An antenna in the sidebar shows while it is open. Turn it off in **Settings › KI** when you do not need it.
