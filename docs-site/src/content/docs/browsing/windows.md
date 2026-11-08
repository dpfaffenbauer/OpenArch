---
title: "Windows"
description: "More windows on the same spaces, private windows, tabs dragged out into windows of their own, Little OpenArch, reopening a closed window and full screen."
---

Most of the time one OpenArch window is enough: spaces do the sorting. When you need more, OpenArch has four kinds of windows. A **normal window** shows the same spaces and tabs as the first one. A **private window** keeps nothing. A tab dragged out of the sidebar becomes a **window of its own**. And **Little OpenArch** is a small window for a quick look at one page.

## Normal windows

<kbd>⌘N</kbd> (**Ablage › Neues Fenster**) opens another window on the same spaces and tabs, with the [command bar](/browsing/command-bar/) open as for a new tab. It starts on the space you chose last, and from then on each window shows its own space.

A tab shows in one window at a time. Choose a tab that another window is showing, and it moves over to this one; the other window shows nothing in its place.

Menu commands and shortcuts act on the window you used last.

## Private windows

<kbd>⇧⌘N</kbd> (**Ablage › Neues privates Fenster**) opens a private window. It has a profile of its own that lives only in memory: you are signed in nowhere, nothing goes into the history, and cookies and site data never reach the disk. Every private window has its own such profile.

The sidebar says **Privates Fenster** at the top. It has no spaces, favorites or pinned tabs, only tabs.

Once the window closes, everything in it is gone. Tabs closed in a private window do not go to the archive, so <kbd>⇧⌘T</kbd> cannot bring them back, and a closed private window cannot be reopened.

## A tab in a window of its own

As in Arc, you can drag a tab out of the sidebar and drop it somewhere no OpenArch window is, on the desktop or another screen. It becomes a window of its own, right there.

- A tab under the line **moves** into the new window and takes its page along, without loading it again. A pinned tab or a favorite stays in the sidebar, and the new window opens a copy of it.
- The window has the **color and profile** of the space the tab came from, so you are signed in as there.
- It has **tabs of its own**: <kbd>⌘T</kbd> in it opens a new tab there. It has no favorites, no pinned tabs and no other spaces, so tabs cannot be pinned in it.
- Dragging a tab out of it again makes another window of its own.

To bring a tab back, right-click it and choose **In Space verschieben**, then a space. The space it came from is first in the list. The tab moves into the main window and shows there. Dragging the tab into the main window's sidebar, or onto a space's icon, does the same.

The window closes by itself once its last tab is gone. When you close it, or quit OpenArch, its tabs go to the [archive](/browsing/library/#archive), for the space they came from.

## Little OpenArch

Little OpenArch is a small window for one page, like Arc's: for a link from another app, or for looking something up without adding a tab.

<kbd>⌥⌘N</kbd> (**Ablage › Neues Little-OpenArch-Fenster**, or "Little OpenArch" in the command bar) opens one with an address field. Type an address or a search and press Return. Each further Little OpenArch window opens a little offset from the last.

The window takes the color and profile of the space you are in. Its bar has:

| Control | What it does |
| --- | --- |
| ← → ↻ | back, forward, reload (<kbd>⌘[</kbd>, <kbd>⌘]</kbd>, <kbd>⌘R</kbd>) |
| the address | click it, or press <kbd>⌘L</kbd>, to type another one |
| puzzle piece | shows Chrome's toolbar, with your extensions |
| link | copies the address (<kbd>⇧⌘C</kbd>) |
| **In Space öffnen** | moves the page into the main window |

**In Space öffnen** moves the page into a new tab of the main window as it is, without loading it again, and closes Little OpenArch. The tab goes into the space you are in, or, if that space has another profile, into the first space with the profile the page was opened in, so you stay signed in.

Links in the page that open a new tab open in the main window. A link clicked with <kbd>⌘</kbd> or <kbd>⌃</kbd> becomes a tab in the background, in the space, and Little OpenArch stays on its page.

<kbd>⌘W</kbd> closes Little OpenArch. Find, zoom, printing and DevTools work in it as in a tab.

Links from other apps can open in Little OpenArch instead of the main window: turn on **Settings › Links › In Little OpenArch öffnen**, or send only some sites there with a link rule. See [Links from other apps](/browsing/links/).

## Closing windows

The red button, or <kbd>⇧⌘W</kbd> (**Ablage › Fenster schließen**), closes a window. The last normal window only hides: its tabs keep running, and a click on OpenArch in the Dock brings it back. Other normal windows close for good; their tabs stay in the sidebar, since they belong to the spaces.

<kbd>⌘W</kbd> closes the tab in front. With no tab in front, it closes the window.

## Reopening a closed window

<kbd>⇧⌘T</kbd> (**Ablage › Geschlossenen Tab wieder öffnen**) brings back what you closed last, as in Chrome and Dia:

- If a window closed after the last tab was closed or archived, <kbd>⇧⌘T</kbd> reopens that window.
- Otherwise it reopens the last closed tab, in its space and at its place.

**Ablage › Geschlossenes Fenster wieder öffnen** always reopens the window that closed last. While there is one, the command bar offers it as "Geschlossenes Fenster wieder öffnen" too.

A window comes back where it was and at its size:

- A **normal window** on the space it showed.
- A **window of its own** with its tabs, in their order. Tabs from it that you have brought back one by one in the meantime are not opened twice.

OpenArch remembers the last ten closed windows until it quits. Private windows are never remembered. A window whose space has been deleted cannot come back; OpenArch takes the one before it instead.

## Full screen

<kbd>⌃⌘F</kbd> (**Ansicht › Vollbild**), or the green window button, puts the window in full screen with its sidebar and tabs. With the sidebar hidden (<kbd>⌘S</kbd>), moving the pointer to the left edge brings it over the page; see [Sidebar basics](/sidebar/basics/).

When a page goes full screen, such as a video, its tab leaves the window for a full screen space of its own, as a Chrome window would. When the page leaves full screen, it goes back to its place in the window.
