---
title: "Split view"
description: "Show up to four tabs side by side or one above the other, start a split from the keyboard or by dragging a tab onto the page, and resize, swap and end it."
---

Split view shows two, three or four tabs at once in the window, side by side or one above the other. Each side is a full tab with its own page. In the sidebar the split is one row, and it stays there until you take it apart, so you can pin it like any tab.

## Starting a split view

There are several ways, all with the tab you want to keep in front:

- **<kbd>⌃⇧=</kbd>** (**Split View › Split View**). The [command bar](/browsing/command-bar/) opens as **Neben dem aktuellen Tab öffnen …**. Type an address or a search, or pick one of your tabs under the line. It opens beside the tab in front.
- **Drag a tab from the sidebar onto the page.** While you drag, the page shows where the tab will go:
  - on the left or right half, it goes beside the tab;
  - on the top or bottom half, it goes above or below it, and the split shows its tabs one above the other.
- **Drag a tab onto another tab in the sidebar.** Over the middle of a row, a split symbol appears at its right end. Drop the tab there, and the two become a split. Dropping on the upper or lower edge of the row moves the tab instead, as usual.
- **Right-click a tab** under the line and choose **Split View mit aktuellem Tab**.
- In [Peek](/browsing/peek/), the button **Neben dem Tab öffnen**.

If you drag the tab that is in front onto its own page, OpenArch pairs it with the tab you used before it.

Favorites and pinned tabs you drag keep their place. Drag one into a split with a tab under the line, and OpenArch opens a copy of it under the line for the split. Two pinned tabs can form a split among the pinned tabs.

While a split view is in front, the same ways add a third and a fourth tab to it. With four, the menu item **Split View** is greyed out.

## Working in a split view

Click into a side to work in it. A ring around it shows which side has the focus, and everything that acts on "the tab", such as <kbd>⌘L</kbd>, <kbd>⌘R</kbd>, back and forward, acts on that side.

From the keyboard:

- <kbd>⌃⇧1</kbd> to <kbd>⌃⇧4</kbd> go to the first to fourth side.
- <kbd>⌃⇧]</kbd> and <kbd>⌃⇧[</kbd> go to the next and the previous side.

The **Split View** menu lists the sides by their page titles, with a check mark at the one in focus.

In the sidebar, the split's row shows each of its tabs. Click one to go to that side.

## Layout

**Side by side or stacked.** A split starts side by side. **Übereinander anzeigen** (in the **Split View** menu, or in the right-click menu of a side in the sidebar) puts the tabs one above the other; **Nebeneinander anzeigen** puts them back. This has no shortcut of its own; you can give it one under **Settings › Tastatur**.

**Dividers.** Drag the gap between two sides to make one larger. A side stays at least 240 points wide, or 160 points high when stacked. OpenArch keeps the sizes with the split. Adding a tab or switching between side by side and stacked starts again from equal sizes.

**Swapping.** <kbd>⌃⇧S</kbd> (**Seiten tauschen**) swaps left and right, or top and bottom. With three or four tabs it reverses their order.

## Ending a split view

- <kbd>⌃⇧-</kbd> (**Split View aufheben**) takes the split apart. Its tabs become separate rows again, and the side in focus stays in front.
- <kbd>⌘W</kbd> closes the side in focus. The others stay in the split. A split with one tab left is simply that tab again.

## Shortcuts

| Key | Menu item | What it does |
| --- | --- | --- |
| <kbd>⌃⇧=</kbd> | **Split View** | a new side, through the command bar |
| <kbd>⌃⇧-</kbd> | **Split View aufheben** | back to separate tabs |
| <kbd>⌃⇧S</kbd> | **Seiten tauschen** | swap the sides |
| | **Übereinander anzeigen** / **Nebeneinander anzeigen** | stacked or side by side |
| <kbd>⌃⇧]</kbd> | **Nächste Seite der Split View** | next side |
| <kbd>⌃⇧[</kbd> | **Vorherige Seite der Split View** | previous side |
| <kbd>⌃⇧1</kbd> … <kbd>⌃⇧4</kbd> | the sides by title | go to that side |

The shortcuts are the defaults; see [Keyboard shortcuts](/reference/shortcuts/) to change them.

:::tip
Split views are saved with the sidebar, and the [import from Arc](/start/import-from-arc/) brings Arc's split views along, side by side or stacked as they were.
:::
