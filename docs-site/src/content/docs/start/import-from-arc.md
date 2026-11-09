---
title: "Move over from Arc"
description: "Bring Arc's spaces, favorites, pinned folders and tabs into OpenArch, and with them, if you like, Arc's logins, passwords, history and extensions."
---

OpenArch can take over your Arc sidebar: spaces, favorites, pinned folders,
today tabs and split views. With **Alles übernehmen** (take over everything)
it also brings Arc's logins and cookies, saved passwords, history, website
data and installed extensions, so you carry on where you left off in Arc.
Arc's own data is only read, never changed.

## Start the import

On its first launch, if Arc is on the Mac, OpenArch offers the import as
the second of its [first-launch steps](/start/install/#the-first-launch),
with a picture of your Arc sidebar. There, **Alles übernehmen** needs no
restart: Arc's logins go into a profile of their own that OpenArch's
Chromium has not opened yet, while you go on with the next steps (see
below). Later, start the import from any of these:

- **Ablage › Aus Arc importieren …**
- the **+** at the bottom of the sidebar › **Aus Arc importieren …**
- the command bar (<kbd>⌘T</kbd>): "Aus Arc importieren"
- **Settings › Import › Aus Arc › Importieren …**

The window **Aus Arc importieren** counts what it found in Arc's sidebar:
spaces, favorites, pinned tabs, folders and open tabs. Then choose:

| Button | What happens |
| --- | --- |
| **Alles übernehmen** | Takes the sidebar, then restarts OpenArch and copies Arc's browser data. |
| **Nur Sidebar** | Takes the sidebar only. OpenArch's logins and other browser data stay as they are. |
| **Abbrechen** | Nothing changes. |

:::caution
The import replaces OpenArch's sidebar. Spaces, favorites, pinned and today
tabs you made in OpenArch before are gone afterwards. Your settings stay.
:::

## What comes over from the sidebar

Both choices read Arc's sidebar file (`StorableSidebar.json`) and take:

- **Spaces** with their name, icon and color. Emoji stay as they are; Arc's
  own icons become the matching SF Symbol where there is one, otherwise a
  dot. The color is the middle tone of the space's Arc theme.
- **Favorites.** Arc keeps them per profile, and so does OpenArch.
- **Pinned tabs and folders**, with subfolders, folder icons and the names
  you gave tabs. Folders arrive closed.
- **Today tabs.** They count as just used, so they are not
  [archived](/sidebar/tabs/) right after the import.
- **Split views**, with Arc's widths, side by side or one above the other.
- **Profiles.** Arc's default profile becomes **Persönlich**; every other
  Arc profile becomes a profile named "Arc – " and the name of its folder.
  Each space keeps its profile (see [Spaces](/sidebar/spaces/)).
- **Icons** from Arc's favicon cache, so tabs show their icons before they
  have loaded.

Other kinds of entries in Arc's sidebar are left out.

## Alles übernehmen

On top of the sidebar, **Alles übernehmen** brings:

- logins and cookies
- saved passwords and payment cards
- history, which the command bar then also finds (the newest 50,000 pages)
- website data: local storage, IndexedDB and service workers
- the installed extensions, with their settings

This is what happens:

1. **Arc has to be closed.** If it is running, OpenArch asks **Arc beenden?**
   and quits it for you; your tabs in Arc stay. If Arc does not quit within
   15 seconds, quit it yourself and start the import again.
2. OpenArch takes the sidebar and restarts.
3. **macOS asks once** whether OpenArch may read "Arc Safe Storage" from your
   keychain. That is the key Arc encrypts logins and passwords with. Allow
   it; without it, the full import stops with a message and you can start
   it again.
4. Before its Chromium starts, OpenArch copies Arc's profile, leaving out
   caches and Arc's open windows. The copy is an APFS clone: it is quick and
   takes no extra disk space until files change. Values Chromium encrypts
   (cookies, passwords, payment cards) are decrypted with Arc's key and
   encrypted again with OpenArch's own key, **OpenArch Safe Storage** in your
   keychain (see [Data and privacy](/reference/data-and-privacy/#the-key-to-your-passwords-and-cookies)).
5. The message **Import aus Arc** says how many cookies, passwords, history
   entries and extensions came over, and how many values could not be
   decrypted and were left out.

From the first launch's steps it goes without the restart: a step explains
the keychain question, macOS asks right after **Weiter**, and the copy runs
in the background while you go on, with a progress pill at the bottom of
the window. The last step shows the same counts.

## What to expect

- **Logins are in your first profile.** The browser data comes from Arc's
  default profile and goes into **Persönlich** (from the first launch, in a
  profile folder of its own, such as `Profile 2`; a later import goes to the
  same one). Spaces that used Arc's
  default profile are signed in; spaces from other Arc profiles get a
  profile of their own, but start signed out.
- **Nothing of OpenArch's is deleted.** The browser data OpenArch had in its
  first profile moves to a folder named `Default (vor Arc-Import …)` with
  the date and time, in `~/Library/Application Support/OpenArch/Chromium`.
- **Arc stays as it was.** OpenArch reads Arc's sidebar file, reads its
  favicons from a copy and clones its profile. It writes nothing into Arc's
  folders, so you can keep using Arc alongside.

:::note
The full import is new. Moving logins, passwords and extensions has been
tested on copies of Arc profiles, not yet on many real ones.
:::

## Back up Arc's data

Arc ends on 22 December 2026. **Settings › Import › Arc-Daten sichern ›
Sichern** puts Arc's JSON files and its `Local State` into a zip file in
your Documents folder. See [Move over from another browser](/start/import/#back-up-arcs-data).

## Only the extensions

If you would rather install Arc's extensions again than copy them, use
**Extensions › Extensions aus Arc …** or **Settings › Import › Extensions aus
Arc › Ordner anlegen**. OpenArch then puts a pinned folder **Extensions aus
Arc** at the top of the current space, with one Chrome Web Store link for each
extension installed in any of Arc's profiles (extensions from the Web Store
only). Open each link and add the extension again. More in
[Extensions and Chrome features](/browsing/chrome/).
