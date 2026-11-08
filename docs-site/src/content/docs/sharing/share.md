---
title: "Share folders and spaces"
description: "Turn a pinned folder or a space into a link and a QR code, keep it up to date for everyone who added it, and add links others send you."
---

A pinned folder or a whole space becomes a link and a QR code. Send it to a
colleague for a team folder, or scan it with your iPhone to have your Mac's
space there too. There is no account: the link itself is the key, and only
the Mac or iPhone that shared something can change it.

## Share a folder or a space

1. Right-click a pinned folder in the sidebar and choose **Teilen …**
   (share), or
   click the **…** beside the space's name at the top of the sidebar and
   choose **Space teilen …**.
2. The window shows the name and how many bookmarks it holds. Choose:
   - **Aktuell halten** (keep up to date): on for a live link that follows
     your changes, off for a snapshot. It is on at first; OpenArch remembers
     your last choice.
   - **Mit Passwort schützen**: a password of at least four characters,
     asked for before the link opens.
3. Click **Link erstellen**.

You get a QR code, the link, **Link kopieren** and **Senden …** for the
usual macOS sharing. When a share holds too many bookmarks for a QR code,
OpenArch says so; send the link instead.

A folder you share or follow carries a small two-person mark in the sidebar.

### What a share contains

- **A folder:** its tabs and subfolders, with their names and folder icons.
- **A space:** its name, icon and color, and its pinned tabs and folders.
  Favorites and today tabs stay on your Mac.

A tab is shared with its title (the name you gave it, if any) and its pinned
address, not the page it shows right now. A split view is shared as its tabs.
Agent chats are not shared. Whoever opens a share gets its `http` and
`https` links only.

## Live link or snapshot

| | **Aktuell halten** on (live) | **Aktuell halten** off (snapshot) |
| --- | --- | --- |
| Where the bookmarks are | Encrypted on the relay, `share.openarch.app` | Encrypted inside the link itself |
| Your later changes | Reach everyone who added it | Do not reach anyone |
| Server involved | Yes, it only sees encrypted data | No |
| Good for | Your iPhone, a team folder | A few links in a chat or by AirDrop |

A live share uploads itself again about a second after you change the folder
or space. The window then shows its **Stand** (version), when it was last
**Hochgeladen** (uploaded) and whether it has a **Passwort**. Open it again
later from the same menu, or from **Settings › Teilen**.

A snapshot link does not change. **Neuer Link** makes a fresh one with what
the folder or space holds now.

### End a live share

Click **Teilen beenden …** in the share's window. The link shows nothing any
more. People who added the bookmarks keep the last state; ending a share
cannot take back what they already have.

If you delete a shared folder or space, the link keeps showing the last
state. **Settings › Teilen** then marks it as deleted, with **Beenden** to end
it.

## Add a link you were sent

On the Mac, any of these opens the window **Geteilte Lesezeichen**:

- the **+** at the bottom of the sidebar › **Geteilten Link öffnen …**, or
  **Settings › Teilen › Geteilten Link öffnen …**. Both take a link that is
  on the clipboard, or ask for one.
- pasting the link into the command bar (<kbd>⌘T</kbd>) and pressing
  <kbd>↩</kbd>
- clicking the link in another app, when OpenArch is your
  [default browser](/browsing/links/)
- an `openarch://share#…` link, as the web page's **Open in OpenArch** button
  makes

If the share has a password, OpenArch asks for it first. Then the window
shows what the share holds. Under **Hinzufügen als** (add as), choose
**Ordner im aktuellen Space** (a folder in the current space) or **Eigener
Space** (a space of its own); OpenArch suggests what was shared. A new space
takes the shared space's color (or a color no other space has) and the
current space's profile.

For a live share there are two buttons:

- **Hinzufügen und folgen** (add and follow): the folder or space keeps up
  with the owner's changes.
- **Als Kopie hinzufügen** (add as a copy): yours to change, and it never
  changes by itself.

A snapshot has a single **Hinzufügen** button.

On the iPhone and iPad, use **Code scannen** or **Geteilten Link einfügen**;
see [OpenArch for iPhone and iPad](/iphone-ipad/).

## Following a share

A followed folder or space checks for changes every five minutes while
OpenArch runs. To check now, right-click the folder and choose **Geteilten
Ordner jetzt aktualisieren**, or use **Geteilten Space jetzt aktualisieren**
in the space's **…** menu, or **Jetzt aktualisieren** in **Settings › Teilen**.

- Your own changes to a followed folder or space are overwritten by the
  next update. To change it for good, add it as a copy instead.
- On the Mac, a tab the owner removed stays while its page is open.
- **Nicht mehr folgen** (stop following), in the same menus and in
  **Settings › Teilen**, keeps the folder or space as it is now.
- When the owner ends the share, yours stays with the last state, and
  **Settings › Teilen** says **Vom Besitzer beendet**.

## Without OpenArch

A link opens in any browser at `openarch.app/s/`. The page decrypts the
bookmarks in the browser and lists them as links, asks for the password if
there is one, and offers **Open in OpenArch**. The key never leaves the
browser; [How sharing works](/sharing/how-it-works/) explains why.

## Settings › Teilen

- **Von diesem Mac geteilt** lists your live shares, with their version and
  whether they have a password. **Link …** opens a share's window again.
- **Mit dir geteilt** lists what you follow and when it was last checked,
  each with **Nicht mehr folgen**, and has **Geteilten Link öffnen …** and
  **Jetzt aktualisieren**.
- **Teilen-Server** sets the relay for new live shares. Leave it empty for
  `share.openarch.app`. A company can run its own; links made with it name
  that relay, so the people they go to need nothing set up. See
  [How sharing works](/sharing/how-it-works/#your-own-relay).
