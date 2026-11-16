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

## Manage all spaces

**Spaces verwalten …** opens a card over the page with a row per space: its icon, its name, its profile and how many tabs it has pinned and open. Find it in the **…** menu beside a space's name, in a space icon's menu, and in the [library](/browsing/library/) under **Spaces**.

- Drag a row up or down to sort the spaces.
- Click a name to rename it; <kbd>↩</kbd> keeps the new name, <kbd>Esc</kbd> the old one.
- Click an icon for the space's editor: symbol, color and profile.
- The bin deletes the space, after asking (see below).
- **Neuer Space** at the bottom makes one.

**Fertig**, <kbd>Esc</kbd> or a click beside the card closes it.

## Move tabs between spaces

Drag a tab, folder or split view onto a space's icon in the space bar, or right-click it and choose **In Space verschieben**. A pinned tab or folder lands in the other space's pinned tabs, a today tab at the top of its today tabs. A link dropped on a space's icon opens there as a new tab.

If the other space uses a different profile, the moved tabs load again in that profile.

## Delete a space

Choose **Space löschen …** from the **…** menu beside its name or from its icon's menu, or click the bin in **Spaces verwalten …**. OpenArch asks first, and says how many tabs are pinned (in how many folders) and open. Those tabs go to the [archive](/sidebar/tabs/#the-archive), where you can open them again; <kbd>⇧⌘T</kbd> brings back the open ones first. The folders themselves are gone, and agent chats in the space are deleted. The data of its profile (logins, cookies) stays. The last space cannot be deleted.

## Profiles

A profile is one of Chromium's profiles: it keeps logins, cookies, history, saved passwords and extensions apart. Give your work spaces one profile and your private spaces another, and you are signed in to a different Google account in each, without signing in and out.

- Each space uses exactly one profile. Several spaces can share one.
- [Favorites](/sidebar/basics/#favorites) belong to the profile: spaces with the same profile show the same favorites.
- [Live folders](/sidebar/live-folders/) ask GitHub with the login of their space's profile.
- Chromium's history (**Verlauf › Verlauf anzeigen**, <kbd>⌘Y</kbd>) is per profile. The list of visited pages the command bar searches is OpenArch's own and covers all profiles.

The first profile is called **Persönlich**. A space's profile is set in its editor, under **Profil**. When you change it, the space's open tabs load again in the new profile.

### Which profile a space uses

Rest the pointer on a space's name above its pinned tabs. A card shows the profile's name and color, the Google account signed in to that profile (picture, name and email), and which other spaces use the same profile. To find the account, OpenArch asks Google for the list of accounts signed in to that profile's cookies, the same list Chrome asks for. It asks only when you rest the pointer on the name, at most every five minutes per profile, and keeps the answer in memory only. Without a connection the card says the account is unknown.

Once there is more than one profile, each space's icon in the space bar has a thin ring in its profile's color, and resting the pointer on the icon names the profile. A profile's color follows from its place in **Settings › Profile**.

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
