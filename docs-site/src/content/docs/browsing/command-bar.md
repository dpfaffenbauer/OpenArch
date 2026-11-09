---
title: "The command bar"
description: "One field for addresses, searches, open tabs, history, archived tabs and OpenArch's commands, opened with ⌘T or ⌘L."
---

The command bar is where you open pages, search, go back to a tab and run OpenArch's commands, all from one field. It works like Arc's: <kbd>⌘T</kbd> brings it up for a new tab, <kbd>⌘L</kbd> for the address of the tab in front.

## Opening it

| Key | The field shows | Return |
| --- | --- | --- |
| <kbd>⌘T</kbd> | **Suchen oder URL eingeben …** | opens the page in a new tab at the top of today's tabs |
| <kbd>⌘L</kbd> | the address of the tab in front, selected | loads it in that tab |
| <kbd>⌃⇧=</kbd> | **Neben dem aktuellen Tab öffnen …** | opens the page beside the tab in [split view](/browsing/split-view/) |

The **Neuer Tab** row in the sidebar opens it like <kbd>⌘T</kbd>. A click on the address at the top of the sidebar (if you show it: **Settings › Allgemein › Tabs › Adresse oben in der Sidebar**) opens it like <kbd>⌘L</kbd>. A new window (<kbd>⌘N</kbd>) starts with the command bar open.

With nothing typed yet, the command bar lists the six tabs of the current space you used last, so <kbd>⌘T</kbd> and Return is a quick way back.

Moving through the results with the arrow keys puts each row's address or search text into the field, as in Chrome. <kbd>Esc</kbd> brings back what you typed; a second <kbd>Esc</kbd> closes the bar.

## Addresses

Text without spaces that looks like an address opens as one. `example.com` becomes `https://example.com`. `localhost`, names ending in `.local` or `.test` and IP addresses get `http://`. Addresses with a scheme (`https://`, `file://`, `chrome://`, `view-source:` …) open as typed. Anything else is a search.

While you type, OpenArch completes the address from your history, like Chrome does. Up to the first `/` it fills in the site you visit most whose name starts with what you typed; after a `/` it fills in the page you visit most. The completed part is selected:

- Type on, and your typing replaces it.
- <kbd>→</kbd> or <kbd>⌘→</kbd> keeps it, so you can type on after it.
- <kbd>⌫</kbd> removes it and leaves what you typed.

Chrome's own pages can be typed as `openarch://`: `openarch://settings` opens `chrome://settings`. See [Chrome's pages](/browsing/chrome/#chromes-own-pages).

## Searching

The row with the magnifying glass searches what you typed. Choose the search engine under **Settings › Allgemein › Suchen › Suchmaschine**: Google (the default), DuckDuckGo, Ecosia, Bing or Kagi.

From the second letter on, the command bar asks the search engine for up to four suggestions and lists them at the end. Turn this off under **Settings › Allgemein › Suchen › Suchvorschläge**.

:::note
DuckDuckGo and Bing give their own suggestions. With Google, Ecosia or Kagi, the suggestions come from Google.
:::

## Tabs, history and the archive

Below the address or search, the command bar shows what else matches. For tabs, history and the archive, every word you type has to appear in the title or the address.

- **Tabs:** up to five open tabs, pinned tabs and favorites, from every space. Open ones come first. **Zu Tab wechseln** goes to an open tab; **Öffnen** loads a pinned tab or favorite that is not loaded yet. A tab in another space shows that space's name, and choosing it switches there.
- **Agent chats** whose title matches, with **Zum Chat wechseln**.
- **Commands** (below).
- **History:** pages you visited, the ones you visit often and recently first.
- **Archive:** up to two [archived tabs](/browsing/library/#archive), marked **Archiviert**. Choosing one opens its page again.

## Commands

Type the beginning of any word in a command, or any part of it from three letters on, and up to three matching commands appear. "aufr" finds "Heute aufräumen", "split" finds "Split View".

| Command | Shortcut | What it does |
| --- | --- | --- |
| "Neuer Space", "Space bearbeiten" | | adds a space, or edits the current one |
| "Zu Space „…“ wechseln" | | one for every other space |
| "Neues Profil" | | a new profile for the current space |
| "Neuer Ordner" | | a new pinned folder |
| "Little OpenArch" | <kbd>⌥⌘N</kbd> | a [Little OpenArch](/browsing/windows/#little-openarch) window |
| "Split View" | <kbd>⌃⇧=</kbd> | splits the tab in front with a new one |
| "Sidebar ein-/ausblenden" | <kbd>⌘S</kbd> | |
| "Chrome-Toolbar ein-/ausblenden" | <kbd>⇧⌘D</kbd> | Chrome's toolbar above the page |
| "Geschlossenen Tab wiederherstellen" | <kbd>⇧⌘T</kbd> | the tab closed last |
| "Geschlossenes Fenster wieder öffnen" | | only after a window closed |
| "Heute aufräumen" | <kbd>⇧⌘K</kbd> | archives the space's tabs under the line |
| "Extensions verwalten", "Chrome Web Store" | | see [Extensions](/browsing/chrome/#extensions) |
| "Verlauf" | <kbd>⌘Y</kbd> | Chrome's history page |
| "Downloads" | <kbd>⌥⌘L</kbd> | Chrome's downloads page |
| "Passwörter", "Browser-Einstellungen" | | Chrome's password manager and settings |
| "OpenArch-Einstellungen" | <kbd>⌘,</kbd> | |
| "Aus Arc importieren" | | see [Import from Arc](/start/import-from-arc/) |
| "Aus anderem Browser importieren" | | see [Move over from another browser](/start/import/) |
| "Neuer Agent-Chat", "Agents" | <kbd>⌃0</kbd> for Agents | only with agent chats turned on |

With a tab in front, there are these too:

| Command | Shortcut |
| --- | --- |
| "URL kopieren" | <kbd>⇧⌘C</kbd> |
| "Tab anheften" or "Tab lösen" | <kbd>⌘D</kbd> |
| "Zu Favoriten hinzufügen" | |
| "Entwicklertools" | <kbd>⌥⌘I</kbd> |
| "Neu laden" | <kbd>⌘R</kbd> |
| "Tab duplizieren" | |
| "Boost bearbeiten" | <kbd>⌃⌘B</kbd> |
| "Split View aufheben" (in a split view) | <kbd>⌃⇧-</kbd> |

The shortcuts are the defaults; you can change them under **Settings › Tastatur** (see [Keyboard shortcuts](/reference/shortcuts/)).

## Searching a site with Tab

Type a site's keyword or name and press <kbd>Tab</kbd>: the site's name moves into the field as a chip, and what you type next searches that site. `yt`, <kbd>Tab</kbd>, `lofi` searches YouTube for "lofi".

- An exact keyword or name wins. Otherwise the first site whose name starts with what you typed (two letters or more) is taken.
- While the input matches a site, a row **… durchsuchen** with the keyword and a **Tab** badge shows it.
- Inside the site search, the results are the search itself, pages of that site from your history, and suggestions.
- <kbd>⌫</kbd> in the empty field leaves the site search.

| Site | Keyword | | Site | Keyword |
| --- | --- | --- | --- | --- |
| YouTube | `yt` | | Stack Overflow | `so` |
| Google | `g` | | MDN | `mdn` |
| Wikipedia (German) | `w` | | npm | `npm` |
| GitHub | `gh` | | Claude | `cl` |
| Google Maps | `maps` | | ChatGPT | `gpt` |
| Amazon (amazon.de) | `amz` | | Perplexity | `pp` |

Edit the list under **Settings › Allgemein › Seitensuche**: a name, a keyword and the search address with `%s` where the search text goes. **Seite hinzufügen** adds a site, **Standard wiederherstellen** brings back the list above.

## New documents: "new doc"

"new" followed by one word goes straight to a new document, as in Dia. The new document is the first row, marked **Erstellen**. The German words work too: "neues Dokument", "neue Tabelle", "neuer Termin".

| Type | Opens | Words after "new" |
| --- | --- | --- |
| **Neues Google-Dokument** | docs.new | doc, docs, document, dokument, text |
| **Neue Google-Tabelle** | sheets.new | sheet, sheets, spreadsheet, table, tabelle |
| **Neue Google-Präsentation** | slides.new | slide, slides, presentation, präsentation, folien, deck |
| **Neues Google-Formular** | forms.new | form, forms, formular, umfrage |
| **Neues Google Meet** | meet.new | meet, meeting, call |
| **Neuer Kalendertermin** | cal.new | event, cal, calendar, kalender, termin |
| **Neuer GitHub-Gist** | gist.github.com | gist, snippet |
| **Neues GitHub-Repository** | github.com/new | repo, repository |
| **Neue Notion-Seite** | notion.new | notion, page, seite, note, notiz |
| **Neues Linear-Issue** | linear.new | linear, issue, ticket |
| **Neue Figma-Datei** | figma.new | figma, design |
| **Neues Jira-Ticket** | your company's Jira | jira, ticket, issue, task, aufgabe, bug |

- The first word can be "new", "neu", "neue", "neues", "neuer" or "neuen". "new" on its own offers nothing, so a site whose name starts with "new" is left alone.
- The second word may be cut short: "new sh" offers the sheet. Up to four matches show, exact words first.
- **Jira** lives on your company's own site. Once your history has a visit to a `….atlassian.net` address, "new ticket" opens a new ticket there, ahead of Linear.

## Questions go to Claude or ChatGPT

A sentence or a question opens a new chat on claude.ai or chatgpt.com with it, in a tab, signed in as you there. Text that ends with "?" or has five words or more counts as a sentence: the chat row (**Claude fragen**) comes first and the search second. For a few words it is the other way round.

Choose where questions go under **Settings › KI › Fragen in der Befehlsleiste › Fragen an**: Claude (the default), ChatGPT, or **Aus** to leave the row out. See [Claude and ChatGPT on the web](/ai/web-chats/).

## Agent chats from a sentence

With agent chats turned on (**Settings › KI › Agents in der Sidebar › Agent-Chats**), what you type after <kbd>⌘T</kbd> also offers **Agent-Chat starten**. It starts a chat with Claude Code in the sidebar, with your text as the first message. See [Agent chats](/ai/agent-chats/).

## Skills and AI commands

- Type `/` to list your Claude Code skills and commands. Each runs on the page in front (**Auf diese Seite anwenden**). See [Skills](/ai/skills/).
- "Morning Brief jetzt erstellen" makes today's [Morning Brief](/ai/morning-brief/) now.
- "Tabs mit KI aufräumen" has Claude suggest folders for the space's tabs; see [Tidy tabs](/ai/tidy-tabs/).

## Keys

| Key | In the command bar |
| --- | --- |
| <kbd>↑</kbd> <kbd>↓</kbd> | choose a row |
| <kbd>Return</kbd> | run the chosen row |
| <kbd>Tab</kbd> | search the site you typed, or go to the next row |
| <kbd>→</kbd> or <kbd>⌘→</kbd> | keep the completed address |
| <kbd>⌫</kbd> | remove the completed address; in an empty site search, leave it |
| <kbd>Esc</kbd> | back to what you typed, then close |

## In private windows and windows of their own

In a [private window](/browsing/windows/#private-windows) or a [window of its own](/browsing/windows/#a-tab-in-a-window-of-its-own), the command bar finds only that window's tabs. Commands for pinning and favorites, and agent chats, are left out there.
