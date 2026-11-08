---
title: "OpenArch for iPhone and iPad"
description: "The same sidebar on the iPhone and iPad: spaces, favorites, pinned folders and today tabs, and your Mac's spaces brought over with a QR code."
---

OpenArch for iPhone and iPad has the Mac's sidebar: spaces in their colors,
favorites, pinned folders and today tabs that go to the archive on their own.
Your Mac's spaces come over by sharing them and scanning a QR code, and then
follow the Mac. Pages run on WebKit, since iOS allows no other engine.
Chrome extensions and the AI features are only on the Mac.

## The screen

On the **iPhone**, the page fills the screen with a bar below it:

| Button | What it does |
| --- | --- |
| Sidebar icon | Opens the sidebar over the page. |
| ‹ | Back. |
| the address | Edits the address or searches. With no tab open it reads **Suchen oder Adresse**. |
| **+** | A new tab. |
| **⋯** | The page's menu (below). |

On the **iPad**, the sidebar sits beside the page, as on the Mac; the sidebar
button shows and hides it. The bar there also has a › for forward.

With no tab open you see the start page: the space's icon, the address field,
your favorites and **Zuletzt** with the newest of today's tabs.

On a page, swipe from the left or right edge to go back or forward, and pull
down to reload. Links that open a new window become a today tab. `mailto:`,
`tel:` and links to other apps open those apps.

### The page's menu

The **⋯** in the bar has **Neu laden**, **Vorwärts** (when there is a page
to go forward to), **Seite teilen …**
(the system's share sheet), **Link kopieren**, and, depending on where the
tab is:

- a today tab: **Anheften** (pin) and **Zu Favoriten**
- a pinned tab or favorite you have navigated away from: **Zur gespeicherten
  Adresse** (back to its saved address) and **Diese Adresse speichern** (save
  the new one)

Then **Tab schließen** (or **Seite schließen** for a pinned tab or favorite,
which closes only the page) and **Einstellungen**.

## The sidebar

Swipe sideways in the sidebar to change spaces, or tap one of the icons in
the bar at its bottom. From the top:

- **The space's name** with its **⋯** menu: **Space bearbeiten …** (name,
  color, and a symbol or emoji), **Space teilen …**, **Neuer Ordner**,
  **Neuer Space** and **Space löschen**.
- **Favorites**, four in a row. The iPhone has one set of favorites for all
  spaces.
- **Pinned tabs and folders.** Tap a folder to open or close it. A dot beside
  a pinned tab means its page is open.
- **Heute**, the line above today's tabs, with **Aufräumen** to send them all
  to the archive, and **Neuer Tab**.
- **Today tabs.** Swipe one to the left to close it, to the right to pin it,
  or drag it to another place in the list.

Touch and hold a tab for **Teilen …**, **Link kopieren**, **Umbenennen**,
**Anheften** or **Lösen**, **Zu Favoriten**, **In Ordner verschieben** and
**Schließen** (today) or **Löschen** (pinned); a favorite has **Aus Favoriten
entfernen**. A folder has **Umbenennen**,
**Neuer Unterordner**, **Ordner teilen …**, **In Ordner verschieben** and
**Ordner löschen**.

The bar at the bottom has the settings (the gear), your spaces, and **+** for
**Neuer Space**, **Neuer Ordner**, **Code scannen** and **Geteilten Link
einfügen**.

## The address field

Tap the address, or **+** for a new tab. Type an address or a search; the
field suggests searches from your search engine, and lists the open tabs,
pinned tabs and favorites that match (**Zu Tab wechseln**) and tabs from the
archive. With nothing typed, it lists the space's today tabs.

## Your Mac's spaces on the iPhone

Each space comes over on its own:

1. On the Mac, click the **…** beside the space's name and choose **Space
   teilen …**. Leave **Aktuell halten** on and click **Link erstellen**.
2. Scan the QR code:
   - in OpenArch on the iPhone: **+** at the bottom of the sidebar › **Code
     scannen**, or
   - with the iPhone's camera. That opens the link's page on `openarch.app`;
     tap **Open in OpenArch** there.
3. OpenArch shows what the space holds. Keep **Space** under **Hinzufügen
   als** and tap **Hinzufügen und folgen**.

The space then follows the Mac: it checks for changes every five minutes
while OpenArch is open, when it comes to the front, and when you open the
sidebar or pull it down. Only the Mac can change the space; what you change on
the iPhone is overwritten by the next update. To keep your own copy instead,
tap **Als Kopie hinzufügen**. Folders come over the same way.

:::note
A shared space carries its pinned tabs and folders, not the Mac's favorites
or today tabs. All spaces on the iPhone share one set of logins and cookies:
the Mac's [profiles](/sidebar/spaces/) do not come along.
:::

More on links, passwords and following in
[Share folders and spaces](/sharing/share/).

## Sharing from the iPhone

Folders and spaces on the iPhone are shared the same way as on the Mac: touch
and hold a folder and choose **Ordner teilen …**, or choose **Space teilen …**
in the space's **⋯** menu. You get a QR code, **Link kopieren** and **Link
senden …**. A live share can be changed only from the iPhone that made it.

To add a link someone sent you, copy it and choose **Geteilten Link
einfügen**, or tap it in a page in OpenArch.

## Settings

Tap the gear at the bottom of the sidebar, or **Einstellungen** in the page's
menu.

| Setting | What it does | Default |
| --- | --- | --- |
| **Suchmaschine** | Google, DuckDuckGo, Ecosia, Bing or Kagi. | Google |
| **Suchvorschläge** | Suggestions from the search engine while you type. | On |
| **Archivieren** | When today tabs you have not looked at go to the archive: after 12 hours, 24 hours, 7 days, or never. | Nach 12 Stunden |
| **Archiv** | The archived tabs. Tap one to open it again, swipe to remove it, or **Leeren** (empty). | |
| **Teilen** | Your shares and the ones you follow; swipe for **Beenden** (end) or **Nicht mehr folgen**. With **Code scannen** and a button to paste a link. | |
| **Teilen-Server** | The relay for new live shares. Leave it empty for `share.openarch.app`. | Empty |

## iPhone Duo

On iPhone Duo, the page goes to the display's edges as in Safari. The
controls float beside the status bar's symbols and shrink to a single button
while you read; scroll up or tap it to bring them back. While the phone is
partly folded, neither the page nor the sidebar lies across the fold.
