---
title: "Spaces and profiles"
description: "Make a space for each part of your day, switch between them, and give them profiles so logins, cookies and extensions stay apart."
---

A space is a sidebar of its own: its own pinned tabs and folders, its own today tabs, a name, an icon and a color. Use one for work, one for home, one per project. Each space also uses a profile, which decides which logins and cookies its tabs see. Spaces work as they did in Arc.

## Make a space

Click **+** at the right of the space bar and choose **Neuer Space**. The menu bar has it too, under **Spaces › Neuer Space**, and so does the command bar ("Neuer Space").

A new space is called **Neuer Space**, gets a color no other space has yet, and uses the profile of the space you were in. Its editor opens right away.

## Edit a space

Double-click the space's name above its pinned tabs, or choose **Space bearbeiten …** from:

- the **…** menu beside the space's name,
- the menu of the space's icon in the space bar (right-click),
- **Spaces › Space bearbeiten …** in the menu bar,
- the command bar ("Space bearbeiten").

The editor has:

- **Name**.
- **Symbol** (icon): one of 30 symbols, or any emoji typed into the field beside **oder Emoji**.
- **Theme**: Arc's theme picker, with one to three colors on a color disc, Arc's nine swatches, **Auto**, **Hell** or **Dunkel**, **Intensität** and **Körnung**. The sidebar and the window around the pages take the theme, the Dock icon (if you choose it) its first color. See [Themes, glass and the sidebar's side](/sidebar/appearance/).
- **Profil**: which profile the space uses, and **Neues Profil …** to make one.

Changes apply as you make them.

## Switch spaces

| How | What it does |
| --- | --- |
| Click an icon in the space bar | Goes to that space. Resting the pointer on it shows its name and shortcut. |
| <kbd>⌃1</kbd> … <kbd>⌃9</kbd> | Goes to the first to ninth space. |
| <kbd>⌥⌘→</kbd> / <kbd>⌥⌘←</kbd> | Next or previous space (**Spaces › Nächster Space**, **Vorheriger Space**). After the last comes the first again. |
| Swipe sideways over the sidebar | Two fingers on a trackpad, one finger on a Magic Mouse. The sidebar follows your fingers. |
| The command bar | "Zu Space „Work“ wechseln". |

Swiping with your fingers to the right goes to the previous space. Swiping past the first space opens the [library](/browsing/library/); swiping back closes it. The swipe works over the sidebar's tabs, not over the space bar itself.

Each space remembers the tab you last had in front and shows it again when you come back.

## Put spaces in order

Drag an icon in the space bar to where you want it; the others make room as it moves. Its menu has **Nach links** and **Nach rechts** too. The order is the order of <kbd>⌃1</kbd> … <kbd>⌃9</kbd>.

## Move tabs between spaces

Drag a tab, folder or split view onto a space's icon in the space bar, or right-click it and choose **In Space verschieben**. A pinned tab or folder lands in the other space's pinned tabs, a today tab at the top of its today tabs. A link dropped on a space's icon opens there as a new tab.

If the other space uses a different profile, the moved tabs load again in that profile.

## Delete a space

Choose **Space löschen …** from the **…** menu beside its name or from its icon's menu. OpenArch asks first. The space's pinned tabs, folders and today tabs go with it; the data of its profile (logins, cookies) stays. The last space cannot be deleted.

## Profiles

A profile is one of Chromium's profiles: it keeps logins, cookies, history, saved passwords and extensions apart. Give your work spaces one profile and your private spaces another, and you are signed in to a different Google account in each, without signing in and out.

- Each space uses exactly one profile. Several spaces can share one.
- [Favorites](/sidebar/basics/#favorites) belong to the profile: spaces with the same profile show the same favorites.
- [Live folders](/sidebar/live-folders/) ask GitHub with the login of their space's profile.
- Chromium's history (**Verlauf › Verlauf anzeigen**, <kbd>⌘Y</kbd>) is per profile. The list of visited pages the command bar searches is OpenArch's own and covers all profiles.

The first profile is called **Persönlich**. A space's profile is set in its editor, under **Profil**. When you change it, the space's open tabs load again in the new profile.

### Make a profile

Any of these opens **Neues Profil anlegen** (New profile), which asks for a name:

- **Neues Profil …** in a space's editor. The new profile goes to that space.
- "Neues Profil" in the command bar. The new profile goes to the space you are in.
- **Settings › Profile › Neues Profil …**.

Each profile needs a name no other profile has.

### Rename and review profiles

**Settings › Profile** lists every profile with the spaces that use it, or **Von keinem Space benutzt** (used by no space). Type in the field beside a profile to rename it.

:::note
Profiles are not synced between Macs. OpenArch has no command to delete a profile; one that no space uses simply stays unused.
:::

## Share a space

**Space teilen …** in the **…** menu beside a space's name turns it into a link and a QR code, for another Mac or your iPhone. See [Share folders and spaces](/sharing/share/).
