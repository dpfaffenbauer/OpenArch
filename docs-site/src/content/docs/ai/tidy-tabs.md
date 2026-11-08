---
title: "Tidy tabs with AI"
description: "Give long tab titles short names on your Mac with Apple Intelligence, and let Claude sort a space's tabs under the line into named folders, with a proposal to check first and one step to undo it."
---

OpenArch tidies tabs in two ways. **Tab-Titel kürzen** (Shorten tab titles)
gives long, noisy titles a short name as you go, made on your Mac by Apple's
on-device model, as Arc Max did. "Tabs mit KI aufräumen" (Tidy tabs with AI)
asks Claude, when you want it, to sort the tabs under the line into a few
folders by topic or task. Both keep their short names in the same place.

## Short tab titles on your Mac

| The page's title | In the sidebar |
|---|---|
| Inbox (3) - someone@example.com - Gmail | Gmail Inbox |
| Pull requests · example-org/example-repo · GitHub | GitHub Pull Requests |

Turn it on under **Settings › KI › Tabs › Tab-Titel kürzen**. It is off by
default.

- Pinned tabs and tabs under the line get a short name of up to about four
  words when their title is long or has separators, counts or email
  addresses. Short titles such as "Figma" stay as they are; nothing is asked
  about them.
- The short name shows in the sidebar. The tab preview shows the page's own
  title; with **Vorschau beim Überfahren** off (Settings › Allgemein), the
  tooltip shows it.
- Tabs you renamed, favorites, folders, tabs in a split view and private
  windows keep their titles and are never sent to the model.
- A name is made a moment after a title arrives, when you are not typing or
  scrolling, a few tabs at a time. Each request gets at most four seconds; a
  tab whose request fails or takes longer keeps its title and is tried again
  later.

### What the model sees

For each page: its title with unread counts and email addresses taken out
("Inbox - Gmail"), and its host ("mail.google.com"). Never the rest of the
address, the page's content or your history. The model runs on your Mac.

### What's kept

Names are kept in `ShortTitles.json` in OpenArch's data folder
(`~/Library/Application Support/OpenArch/`), by page address, with a
fingerprint of the title each was made from (its letters, without counts,
numbers or email addresses). A name stays while only a count changes; a page
with a new title gets a new name. The file holds no titles, and keeps up to
1,000 pages. Turning **Tab-Titel kürzen** off deletes the names made on your
Mac.

### Requires Apple Intelligence

It needs Apple Intelligence: macOS 26 or later on a Mac that supports it,
turned on in **System Settings › Apple Intelligence & Siri**, with its model
downloaded. Without it, the switch is greyed out and says what is missing
(with a button to System Settings when Apple Intelligence is off), and every
tab shows its own title. OpenArch still runs on macOS 15.

## Tidy tabs with Claude

When the tabs under the line pile up, "Tabs mit KI aufräumen" asks Claude to
sort them into a few folders by topic or task and to suggest shorter titles
for long ones. While **Tab-Titel kürzen** is on and working, Claude is asked
for folders only. You see the proposal first; nothing changes until you take
it.

### Tidy up

1. Press <kbd>⌘T</kbd>, type "Tabs mit KI aufräumen" (or the first letters of
   it) and press <kbd>↩</kbd>.
2. A panel **Tabs aufräumen** opens over the page and shows "Claude sortiert …
   Tabs" while Claude works.
3. The proposal lists each folder with its tabs. Where Claude suggests a
   shorter title, the old one stands beside it in gray. Tabs that fit no folder
   are listed under **Ohne Ordner** (Without folder).
4. Click **Übernehmen** (Apply) or press <kbd>↩</kbd> to take it, or
   **Abbrechen** (Cancel) or <kbd>Esc</kbd> to leave everything as it is.

It works on the space in front. With fewer than three tabs under the line,
OpenArch only says "Zu wenige Tabs zum Aufräumen" (Too few tabs to tidy).

### What Claude proposes

Claude is asked for:

- two to seven folders by topic or task, with short names of one to three
  words, usually with an emoji in front;
- at least two tabs per folder, each tab in at most one folder; tabs that fit
  nowhere stay outside;
- shorter, clear titles of about 30 characters for tabs whose title is long or
  unclear, in the language of the title (not while **Tab-Titel kürzen** is on
  and working).

OpenArch drops folders with fewer than two tabs from the answer, and cuts
folder names at 40 characters and titles at 60. If the answer holds nothing it
can use, the panel says "Claude hat keinen brauchbaren Vorschlag gemacht.
Versuch es noch einmal." (Claude made no usable proposal. Try again.)

### After Übernehmen

The new folders go to the top of the tabs under the line, in the order of the
proposal; the other tabs stay below them in their order. The new titles go
to the same store as the short names from your Mac, so a tab you rename
later still takes your name, and a tab whose page gets a new title shows that
title again.

Folders from an earlier tidy that end up empty are removed. Folders under the
line also go away on their own once all their tabs have gone to the archive.

A toast says how many folders were made ("3 Ordner angelegt"), with a button
**Rückgängig** (Undo).

### Undo

While the toast shows, for about eight seconds, <kbd>⌘Z</kbd> or
**Rückgängig** puts the tabs under the line back as they were: their order,
their folders and their titles. Tabs you closed since stay closed; tabs you
opened since stay at the top.

### What stays untouched

- Pinned tabs and favorites.
- Other spaces.
- Tabs in a split view.
- Agent chats under the line: only tabs are sorted.
- Titles you gave tabs yourself: Claude's suggestion for them is not used.

Tabs already in a folder under the line, from an earlier tidy for example, are
sorted along with the others and can move into a new folder. If a space has
more than 80 tabs under the line, the first 80 are sorted.

### What Claude gets and what it may do

Claude gets a numbered list of the tabs' titles and addresses, and nothing of
the pages: no text, no cookies, no history. It is told not to use any tools and
to answer with the proposal only.

This is one run of Claude Code on your own login, in a folder of OpenArch's,
`~/Library/Application Support/OpenArch/TabTidy`, with Claude Code's default
permissions. If there is no answer after four minutes, the run stops and the
panel shows the error. Without Claude Code on the Mac, or without its login,
the panel says so and how to fix it.

How the runs work in detail: [How OpenArch talks to Claude](/ai/how-it-works/).
