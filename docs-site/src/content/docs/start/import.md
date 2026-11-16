---
title: "Move over from another browser"
description: "Bring bookmarks, history and, from Chromium browsers, logins and passwords over from Chrome, Edge, Brave, Firefox, Safari and others, or from an exported file."
---

OpenArch can take your bookmarks and history from the other browsers on
your Mac, and from Chrome and the browsers built on it also your logins,
cookies and saved passwords. Each browser profile becomes an OpenArch
profile with a space of the same name. Coming from Arc? See
[Move over from Arc](/start/import-from-arc/).

## Start the import

Open **Settings › Import**, or choose one of:

- **Ablage › Aus anderem Browser importieren …**
- the **+** at the bottom of the sidebar › **Aus anderem Browser importieren …**
- the command bar (<kbd>⌘T</kbd>): "Aus anderem Browser importieren"

Under **Aus anderen Browsern** (from other browsers), OpenArch lists every
browser it finds, with its profiles:

- Chrome, Chrome Beta, Dev and Canary, Brave, Edge (and its Beta, Dev and
  Canary), Vivaldi, Opera and Opera GX, Chromium, Dia, Helium and Comet, with
  the profiles from their `Local State`, named and colored as in the browser
- Firefox and Zen, with the profiles from their `profiles.ini`
- Safari

Tick the profiles you want, and for each browser what to take:
**Lesezeichen** (bookmarks), **Verlauf** (history) and, for Chromium
browsers, **Logins und Passwörter**. Then click **Importieren**. A bar shows
the progress; when it is done, the page shows how many spaces, profiles,
bookmarks, folders and history entries came over, and under
**Übersprungen** what was left out and why.

## What comes over

- **A profile and a space** for each browser profile, named after it. A
  profile nobody named ("Person 1", Firefox's "default-release") takes the
  browser's name, such as "Chrome". The space takes the profile's color, or
  the browser's.
- **The bookmarks bar** becomes the space's pinned tabs and folders, with
  subfolders. Folders arrive closed.
- **Other bookmarks** become a pinned folder **Weitere Lesezeichen**, and the
  same goes for mobile bookmarks, Firefox's bookmarks menu, and Safari's
  bookmarks menu and reading list.
- **History** (the newest 20,000 pages of each profile) goes into the index
  the command bar searches. It is not added to Chrome's history page in
  OpenArch.

Left out: bookmarklets (`javascript:` links), entries without a usable
address, Firefox's separators and smart folders, more than 10,000 bookmarks
per profile, and folders more than 64 levels deep. The result says how many.

## Import again

Importing the same profile again adds nothing twice. Bookmarks and folders
keep an ID taken from the browser's own bookmark IDs, so OpenArch knows them
the second time; only bookmarks that are new since go in, and into the
folder they are in. If you moved an imported bookmark elsewhere, it stays
where you put it. Two bookmarks that share one ID in the browser's file
still come over as two.

## Logins and passwords

For Chromium browsers, **Logins und Passwörter** also brings the profile's
cookies (so you stay signed in) and saved passwords:

1. After bookmarks and history are in, OpenArch asks **Logins und Passwörter
   übernehmen?** and explains what comes next. **Ohne Logins** stops here.
2. The browser has to be closed. If it is running, OpenArch offers to quit it.
3. OpenArch restarts. Before its Chromium starts, macOS asks once whether
   OpenArch may read the browser's key from your keychain, for example
   "Chrome Safe Storage". The browser encrypts logins with it; OpenArch
   decrypts them and encrypts them again with its own key.
4. The message **Logins und Passwörter importiert** says how many cookies
   and passwords came over, and how many values could not be decrypted.

The cookies and passwords are added to the profile the import made for that
browser profile. Ones already there stay; importing again does not add a
second copy of a password.

## Safari

Safari keeps its bookmarks and history where only apps with **Full Disk
Access** may read them. Until OpenArch has it, Safari's row says so and
offers **Systemeinstellungen …**, which opens **Privacy & Security › Full
Disk Access**. Turn OpenArch on there, restart OpenArch and open
**Settings › Import** again. If macOS also keeps another browser's folder
closed, its row shows the same.

Without Full Disk Access, export Safari's bookmarks instead (**File ›
Export › Bookmarks…** in Safari) and import the file as below.

## Files

Under **Aus Dateien** (from files):

- **Lesezeichen-Datei (HTML)**: **Datei wählen …** takes a bookmarks file
  as Safari, Chrome, Firefox and Edge export it. It becomes one space,
  "Lesezeichen" (or "Safari-Lesezeichen", "Firefox-Lesezeichen" when the
  file shows where it came from), on the current space's profile. The
  bookmarks bar of the file becomes its pinned tabs and folders, other
  folders stay folders, and loose bookmarks go into **Weitere Lesezeichen**.
  The same file imported again adds only what is new.
- **Passwörter (CSV)**: choose the profile in the menu, then **Datei wählen
  …**. OpenArch recognizes the columns of exports from Chrome (and Edge,
  Brave and others built on it), Firefox, Safari's Passwords app,
  1Password and Bitwarden. It shows how many passwords it found, what it
  leaves out (duplicates, rows without an address or password, entries that
  are not website logins), and restarts to add them before its Chromium
  starts. A password already saved for the same site and user is not added
  again.

:::caution
A password export is a plain-text file with all your passwords. OpenArch
only reads it and never changes, moves or logs it. Delete it yourself once
the import is done.
:::

## Back up Arc's data

Arc ends on 22 December 2026. **Settings › Import › Arc-Daten sichern ›
Sichern** writes Arc's own JSON files (the sidebar, spaces and settings)
and its `Local State` (its profiles) into one zip file, "Arc-Sicherung"
with the date and time, in your Documents folder, and shows it in the
Finder. Arc's folder is only read.

## What to expect

- **The other browsers stay as they were.** OpenArch reads their files, or
  private copies of their databases, and writes nothing into their folders.
- **Settings, extensions and open tabs** do not come over from other
  browsers; install extensions again from the Chrome Web Store.
- **Firefox's and Safari's passwords** come only from an exported CSV file.
