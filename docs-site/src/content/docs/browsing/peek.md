---
title: "Peek"
description: "Links from pinned tabs and favorites to other sites, and ⇧-clicked links, open in a card over the page, which you can close, reopen, turn into a tab or put beside the tab."
---

Pinned tabs and favorites are places you come back to, so they keep their page. When you click a link in one that leads to another site, OpenArch opens it in a card over the page instead, as Arc's Peek did. Read it, then close the card and you are back where you were. If the page is worth keeping, turn the card into a tab.

## When a link opens in Peek

A link opens in Peek when all of this holds:

- You clicked it in a **pinned tab** or a **favorite**. Tabs under the line follow links as usual.
- It leads to **another site** than the one the tab is pinned to. Subdomains count as the same site: from `github.com`, a link to `gist.github.com` stays in the tab.
- It is a web address (`http://` or `https://`).

This covers links that would replace the page and links that open a new tab. A link you open in the background, with <kbd>⌘</kbd>-click or the middle mouse button, still becomes a tab in the background.

## ⇧-click any link

<kbd>⇧</kbd>-click a link on any page, a today tab's too, to open it in Peek. Any site counts here, the tab's own as well. (Chrome would open a new window.)

## The card

The card lies over the page, with the rest of the content area dimmed. Above it are the page's title and three buttons:

| Button | What it does |
| --- | --- |
| **Neben dem Tab öffnen** (two panes) | the page becomes a tab and shows beside the tab it came from, in [split view](/browsing/split-view/) |
| **Als Tab öffnen** (arrows) | the page becomes a tab at the top of today's tabs |
| **Schließen (Esc)** (×) | closes the card |

Both ways of keeping the page move it over as it is, without loading it again: what you typed or scrolled to stays.

To close the card, you can also press <kbd>Esc</kbd> or click anywhere beside it. Going to another tab closes it too.

## Opening it again

Closed the card too soon? Press <kbd>⌘Z</kbd> right after, within 10 seconds and before you type anything else, and the same page opens in Peek again. Any other key in between, and <kbd>⌘Z</kbd> is the page's own undo again.

<kbd>⇧⌘T</kbd> opens the card again too, as long as it closed after the last tab you closed. It opens the address the card showed last, loaded anew.

Inside the card, the page uses the same profile as the tab it came from, so you are signed in the same way. <kbd>⇧⌘C</kbd> copies the address of the page in the card. Links in it that open a new tab open as new tabs in the window. The card has no Chrome toolbar.

## Turning Peek off

Turn off **Settings › Links › Links in Tabs › Peek**, and links from pinned tabs and favorites open the way they do in any other tab. A <kbd>⇧</kbd>-clicked link then opens as a new tab.
