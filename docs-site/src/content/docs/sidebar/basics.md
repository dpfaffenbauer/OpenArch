---
title: "The sidebar"
description: "How the sidebar is laid out, how favorites, pinned tabs, folders and today tabs work, and how to select, drag, rename, hide and resize it."
---

The sidebar holds everything a tab strip and a bookmarks bar would: the sites you use all the time, the tabs that belong to a space, and whatever you opened today. It works like Arc's. This page covers its parts and how to move things around in it.

## From top to bottom

- **The top bar**, beside the window buttons: the sidebar button, the site settings (the sliders, see [Site controls](/browsing/site-controls/)), back, forward and reload.
- **The address** of the page in front, if you turn on **Settings › Allgemein › Tabs › Adresse oben in der Sidebar**. Click it, or press <kbd>⌘L</kbd>, to change it. Resting the pointer on it shows a button that copies it (<kbd>⇧⌘C</kbd>).
- **Favorites**, a grid of icons.
- **The space's name**, then its **pinned tabs and folders**.
- **The line**, then **Neuer Tab** (New tab) and the **today tabs**.
- **Cards** for what is playing, a meeting and screen sharing, when there is one. See [Player, meetings and screen sharing](/sidebar/cards/).
- **The space bar**: the [library](/browsing/library/) button, one icon per [space](/sidebar/spaces/), and **+**. With agent chats on, ✨ for [Agents](/ai/agent-chats/) sits before the space icons.

A private window, and a window made from a dragged-out tab, have only today tabs. See [Windows](/browsing/windows/).

## Favorites

Favorites are the icons at the top, for the sites you open all the time. Drag a tab onto the grid, or right-click it and choose **Zu Favoriten hinzufügen**. The grid has three columns, four once there are more than nine favorites.

Favorites belong to a [profile](/sidebar/spaces/#profiles), not to a space: every space with the same profile shows the same ones. A small bar under the icon means its page is loaded.

### Unread dot and calendar date

Some sites count what is unread in their page title: Gmail ("Posteingang (3)"), X, WhatsApp, Slack, Outlook, LinkedIn, Telegram, Discord, Teams, Messenger and Google Chat. While such a favorite or pinned tab is loaded and its title has a count, a dot shows on its icon (on a pinned tab, at the end of its row). Rest the pointer on the dot for the number. Other sites get no dot, and a tab that is not loaded shows none: its saved title is old.

Google Calendar's icon shows today's date, also while the tab is not loaded.

A favorite remembers its address. When you have moved on from it, its menu offers **Zur gespeicherten URL** (back to the saved address) and **Aktuelle URL speichern** (make the current address the saved one). Links from a favorite to another site open in [Peek](/browsing/peek/).

## Pinned tabs and folders

Pinned tabs are the tabs that belong to a space and stay. Press <kbd>⌘D</kbd>, or drag a tab above the line, to pin it. Like a favorite, a pinned tab keeps its address: once you navigate away, a **/** appears before its title, and resting the pointer on it shows a button back to the pinned address. Its menu has **Zur angehefteten URL** and **Aktuelle URL anheften**.

The buttons on a pinned tab:

- **−** (**Entladen**) closes its page but keeps the tab.
- **×** (**Lösen**) unpins it: it moves to the top of the today tabs.

**Löschen** in its menu removes it; it goes to the [archive](/sidebar/tabs/#the-archive).

Folders keep pinned tabs together, and can hold folders of their own. Rest the pointer on a closed folder for a moment (under half a second) and a list of its tabs, those in subfolders too, appears beside it. Type to search it by title or address; click a tab, or press <kbd>↩</kbd> for the first one, to open it without opening the folder. Make one with **+ › Neuer Ordner**, **Ablage › Neuer Ordner**, or **Neuer Unterordner** in a folder's menu. A new folder starts with its name selected, so you can type one. Click a folder to open or close it. **Alle öffnen** in its menu opens every tab in it, and **Ordner löschen …** removes it with its tabs, after asking.

To pin a tab straight into a folder, right-click it and choose **In Ordner verschieben**.

## Today tabs

Everything you open goes under the line. **Neuer Tab** at the top, or <kbd>⌘T</kbd>, opens the [command bar](/browsing/command-bar/). A new tab goes to the top. A tab opened from a link in a today tab goes right below it, in the same folder.

Press <kbd>⌘W</kbd> or the **×** on a today tab to close it. Today tabs you have not used for 12 hours go to the archive by themselves. See [Tabs](/sidebar/tabs/) for the archive, sleeping tabs and <kbd>⇧⌘T</kbd>.

## Clicking

A click shows a tab, or opens or closes a folder.

<kbd>⌘</kbd>-click a tab, or a folder, to load it in the background: the page and its title are there when you come to it, and the tab in front stays. On a folder, this loads every tab in it without opening the folder.

On a page, <kbd>⌘</kbd>-click a link to open it as a today tab in the background, and <kbd>⇧</kbd>-click it to open it in [Peek](/browsing/peek/).

## Selecting several rows

Pinned tabs, folders, split views and today tabs can be selected together:

- <kbd>⇧</kbd>-click a row to select every row from the one you clicked last to this one.
- <kbd>⌘⇧</kbd>-click a row to add it to the selection, or take it out. The tab in front joins the selection the first time.
- While rows are selected, <kbd>⌘</kbd>-click adds or removes one too. Without a selection, <kbd>⌘</kbd>-click still loads a tab in the background.

Selected rows have an outline. A plain click on a row, or switching spaces, ends the selection.

Drag any selected row and all of them move, in their order. Right-click one for the selection's menu:

- **Neuer Ordner mit N Tabs**: a pinned folder in place of the first row, with the selection in it, its name ready to type.
- **URLs kopieren (⇧⌘C)**: every address, one per line. <kbd>⇧⌘C</kbd> does the same while rows are selected.
- **In Space verschieben**: all of them into another space.
- **Archivieren**: today tabs close, pinned tabs and split views are removed; all go to the [archive](/sidebar/tabs/#the-archive). Folders and agent chats in the selection stay.
- **Auswahl aufheben** ends the selection.

## Drag and drop

Drag a row to move it. Where it lands depends on where you let go:

- On the upper or lower edge of a row: before or after it.
- On the middle of a folder: into the folder.
- On the middle of a tab: into a [split view](/browsing/split-view/) with it.
- On the favorites grid: a favorite.
- Above the line: pinned. Under the line: a today tab.
- On a space's icon in the space bar: into that space.
- On the page: a split view. On the desktop: a [window of its own](/browsing/windows/).

A pinned tab or favorite you drop takes its current address as its saved one.

Links from a page, Safari or Mail, files from Finder, and text with an address in it can be dropped on the sidebar too. Each becomes a tab where you drop it.

## Renaming

Right-click a tab or folder and choose **Umbenennen**. Type the name and press <kbd>↩</kbd>; <kbd>Esc</kbd> keeps the old one. An empty name brings back the page's own title.

## Context menus

Right-click anything in the sidebar for what you can do with it. A tab's menu has, among others, **Neu laden**, **Duplizieren**, **Umbenennen**, **URL kopieren**, **Anheften (⌘D)** or **Lösen**, **Zu Favoriten hinzufügen**, **In Ordner verschieben**, **Split View mit aktuellem Tab**, **In Space verschieben** and **Schließen** or **Entladen**. While a tab plays sound, it also has **Stummschalten**; the speaker on the tab does the same.

The space's name has a menu too: rest the pointer on it and click **…**. It edits, shares and deletes the space, makes a folder or a new space, and opens **Spaces verwalten …**. Double-click the name to edit the space. Resting the pointer on the name itself shows the space's profile and its Google account; see [Spaces](/sidebar/spaces/#which-profile-a-space-uses).

## The + menu

**+** at the right of the space bar has:

- **Neuer Space** and **Neuer Ordner**.
- **Neuer Agent-Chat**, when agent chats are on. See [Agent chats](/ai/agent-chats/).
- **GitHub-Live-Ordner**: a folder that fills itself from GitHub. See [GitHub live folders](/sidebar/live-folders/).
- **Geteilten Link öffnen …**: add a folder or space someone shared. See [Sharing](/sharing/share/).
- **Aus Arc importieren …**. See [Move over from Arc](/start/import-from-arc/).
- **Aus anderem Browser importieren …**. See [Move over from another browser](/start/import/).

## Hide and resize the sidebar

Press <kbd>⌘S</kbd>, or click the sidebar button at the top, to hide the sidebar; the page then takes the whole window. Press <kbd>⌘S</kbd> again to bring it back. The menu command is **Ansicht › Sidebar ein-/ausblenden**.

Drag the sidebar's right edge to make it wider or narrower, between 200 and 440 points. Drag it far to the left and it collapses, as in Arc; drag back out without letting go and it opens again. **Settings › Allgemein › Sidebar › Breite** sets the width too. With the sidebar on the right (**Settings › Allgemein › Sidebar › Sidebar-Position**), all of this is mirrored: see [The sidebar on the right](/sidebar/appearance/#the-sidebar-on-the-right).

While the sidebar is hidden, move the pointer to the window's left edge. The sidebar slides in over the page, and slides away again once the pointer has left it for a moment. Click its sidebar button (**Sidebar anheften**) to keep it open.
