---
title: "Tidy tabs with AI"
description: "Let Claude sort a space's tabs under the line into named folders and shorten long titles, with a proposal to check first and one step to undo it."
---

When the tabs under the line pile up, "Tabs mit KI aufräumen" (Tidy tabs with
AI) asks Claude to sort them into a few folders by topic or task and to suggest
shorter titles for long ones. You see the proposal first; nothing changes until
you take it.

## Tidy up

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

## What Claude proposes

Claude is asked for:

- two to seven folders by topic or task, with short names of one to three
  words, usually with an emoji in front;
- at least two tabs per folder, each tab in at most one folder; tabs that fit
  nowhere stay outside;
- shorter, clear titles of about 30 characters for tabs whose title is long or
  unclear, in the language of the title.

OpenArch drops folders with fewer than two tabs from the answer, and cuts
folder names at 40 characters and titles at 60. If the answer holds nothing it
can use, the panel says "Claude hat keinen brauchbaren Vorschlag gemacht.
Versuch es noch einmal." (Claude made no usable proposal. Try again.)

## After Übernehmen

The new folders go to the top of the tabs under the line, in the order of the
proposal; the other tabs stay below them in their order. Tabs get their new
titles as if you had renamed them.

Folders from an earlier tidy that end up empty are removed. Folders under the
line also go away on their own once all their tabs have gone to the archive.

A toast says how many folders were made ("3 Ordner angelegt"), with a button
**Rückgängig** (Undo).

## Undo

While the toast shows, for about eight seconds, <kbd>⌘Z</kbd> or
**Rückgängig** puts the tabs under the line back as they were: their order,
their folders and their titles. Tabs you closed since stay closed; tabs you
opened since stay at the top.

## What stays untouched

- Pinned tabs and favorites.
- Other spaces.
- Tabs in a split view.
- Agent chats under the line: only tabs are sorted.
- Titles you gave tabs yourself: Claude's suggestion for them is not used.

Tabs already in a folder under the line, from an earlier tidy for example, are
sorted along with the others and can move into a new folder. If a space has
more than 80 tabs under the line, the first 80 are sorted.

## What Claude gets and what it may do

Claude gets a numbered list of the tabs' titles and addresses, and nothing of
the pages: no text, no cookies, no history. It is told not to use any tools and
to answer with the proposal only.

This is one run of Claude Code on your own login, in a folder of OpenArch's,
`~/Library/Application Support/OpenArch/TabTidy`, with Claude Code's default
permissions. If there is no answer after four minutes, the run stops and the
panel shows the error. Without Claude Code on the Mac, or without its login,
the panel says so and how to fix it.

How the runs work in detail: [How OpenArch talks to Claude](/ai/how-it-works/).
