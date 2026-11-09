---
title: "Tabs: previews, sleep and the archive"
description: "Preview a tab by resting the pointer on it, let unused tabs sleep, and find closed and archived tabs again with ⇧⌘T and the archive."
---

OpenArch keeps the sidebar tidy for you, as Arc did. Today tabs you stop using go to the archive, tabs you have not looked at in a while give their memory back, and anything that went away can come back. This page covers those, and the preview you get by resting the pointer on a tab.

## Tab previews

Rest the pointer on a tab in the sidebar for a moment. A card opens beside the sidebar with a picture of the page, its title and its address. Move down the list and the card switches to the next tab at once. For a pull request in a [live folder](/sidebar/live-folders/), it also shows the checks, in GitHub's words.

The picture is the page as you last saw it. OpenArch takes a new one when you leave a tab, and when the preview opens on a tab whose page is loaded, even in the background. Until there is a picture, the card shows the site's icon, and for a tab without a loaded page **Nicht geladen** (not loaded) or **Schläft** (asleep). The pictures are kept in memory only, so after a restart they come back one tab at a time.

There is no preview for the tab in front, for favorites, or while the sidebar floats over the page.

To turn previews off, use **Settings › Allgemein › Sidebar › Vorschau beim Überfahren**. Without them, resting the pointer on a tab shows its address as a tooltip instead.

## Sleeping tabs

A tab you have not looked at for two hours goes to sleep: its page closes and gives its memory back. The tab keeps its place, title and address. Its icon turns pale, and resting the pointer on the icon says **Schläft: lädt neu, wenn du den Tab öffnest**. Click it and the page loads again.

This applies to today tabs, pinned tabs and favorites alike. A tab stays awake while:

- it is on screen, in any window,
- it plays sound, or a video in picture-in-picture,
- it is in a call: its page uses the camera or the microphone,
- its page would ask before you leave it, such as a form you have not sent or a document with unsaved changes,
- it is a pinned tab or a favorite of a chat or mail site (see below).

A tab you [loaded in the background](/sidebar/basics/#clicking) counts as used from the moment it loaded.

Set the time under **Settings › Allgemein › Tabs › Schlafende Tabs**: **nach 30 Minuten**, **nach 1 Stunde**, **nach 2 Stunden** (the default), **nach 6 Stunden** or **nie** (never).

To close a pinned tab's page yourself, click **−** (**Entladen**) on it.

### Chat and mail stay awake

Pinned tabs and favorites of chat and mail sites never sleep, so their messages, notifications and calls keep coming. That covers Gmail, Outlook, Proton Mail, Fastmail, HEY, Superhuman and Zoho Mail; Slack, Discord, WhatsApp, Telegram, Microsoft Teams, Google Chat, Google Meet, Google Messages, Messenger, Element, Zulip and Zoom; and Google Calendar. A site counts with every address below it: **slack.com** covers **acme.slack.com**. The same sites as today tabs sleep like any other.

Turn this off under **Settings › Allgemein › Tabs › Chat und Mail wach halten**. Add sites of your own under **Weitere Seiten wach halten**, separated by commas, for example `chat.firma.de, linear.app`.

## Today tabs go to the archive

Today tabs you have not used for 12 hours move to the archive by themselves, as in Arc. Pinned tabs and favorites never do. The tab in front and any tab on screen stay, however old. OpenArch checks once a minute.

Set the time under **Settings › Allgemein › Tabs › Tabs unter dem Strich archivieren**: **nach 12 Stunden** (the default), **nach 24 Stunden**, **nach 7 Tagen**, **nach 30 Tagen** or **nie** (never).

To clear all today tabs of a space at once, rest the pointer on the line and click **Aufräumen**, or press <kbd>⇧⌘K</kbd> (**Ablage › Heute aufräumen**). They all go to the archive. [Agent chats](/ai/agent-chats/) under the line stay where they are. To have AI sort today tabs into folders instead, see [Tidy tabs with AI](/ai/tidy-tabs/).

Closing a today tab (<kbd>⌘W</kbd>, or its **×**) and deleting a pinned tab also put it in the archive. Tabs of a private window never go there.

## Reopen a closed tab

Press <kbd>⇧⌘T</kbd> (**Ablage › Geschlossenen Tab wieder öffnen**). The newest tab in the archive comes back where it was: in its space, at its place under the line. Press it again for the one before.

If you closed a window after the last tab you closed, <kbd>⇧⌘T</kbd> brings back that window first, as in Chrome. See [Windows](/browsing/windows/).

## The archive

The archive is the list of everything that left the sidebar: closed tabs, tabs archived after their time, and tabs cleared with **Aufräumen**. Newest first, it keeps the last 500.

Open it in the [library](/browsing/library/): press <kbd>⇧⌘L</kbd> and choose **Archiv**. Each entry shows its title, address and when it was archived. The field at the top searches titles and addresses.

- Click an entry to bring the tab back where it was.
- Right-click it for **Wiederherstellen** (restore), **URL kopieren** and **Aus dem Archiv entfernen** (remove).
- **Archiv leeren** at the bottom empties it.

The [command bar](/browsing/command-bar/) finds archived tabs too, marked **Archiviert**.
