---
title: "Install and update"
description: "Download OpenArch, make it your default browser, and how it keeps itself up to date."
---

OpenArch runs on Macs with Apple silicon and macOS 15 or later. It is free and open source.

## Install

1. Download [OpenArch.zip](https://github.com/dpfaffenbauer/OpenArch/releases/latest/download/OpenArch.zip) from GitHub.
2. Open the zip and drag **OpenArch** into your **Applications** folder.
3. Open it. macOS asks once whether to open an app downloaded from the internet.

The download is the newest build of OpenArch: GitHub builds every change, and the newest one is published as the [nightly release](https://github.com/dpfaffenbauer/OpenArch/releases/tag/nightly).

## The first launch

The first time OpenArch opens, a small window walks you through setting it up before the browser window appears. Every step has a way past it: the whole thing takes a couple of minutes, or less than a minute if you skip. <kbd>Esc</kbd> goes back a step. The window has no title bar; drag it by its background.

1. **Willkommen.** Click **Los geht’s**.
2. **Nimm dein Arc mit.** If Arc is on the Mac, OpenArch reads its sidebar and builds it again in a small picture as it goes: each space with its icon and color, the favorites and pinned tabs, and a count such as "3 Spaces · 2 Profile · 12 Favoriten · 84 angeheftete Tabs". Choose **Alles übernehmen**, **Auswählen …** to tick the spaces you want (and whether favorites and Arc's logins come along), or **Neu anfangen** for one empty space. Without Arc, the step says so and OpenArch starts with one space.
3. **Gleich fragt macOS nach deinem Passwort.** Only when Arc's logins come along: this explains the keychain question that follows. Click **Weiter**, and macOS asks whether OpenArch may read "Arc Safe Storage"; or **Logins überspringen** to take the sidebar without them. Arc is quit first if it is running. The import then runs in the background, with a small progress pill at the bottom of the window, while you go on.
4. **Spaces und Konten.** Each profile with its spaces and the Google accounts signed in to it. **Mit Google anmelden** opens Google's sign-in in a small window of that profile, for a profile that has none; it closes by itself once you are signed in.
5. **Mach es zu deinem.** A color for each space, and **Wie macOS**, **Hell** or **Dunkel** for pages and windows. The browser window behind shows each change at once.
6. **OpenArch als Standardbrowser.** Only if it is not yet: **Als Standard festlegen**, and macOS asks you to confirm.
7. **Alles bereit.** **OpenArch öffnen** grows the window into the browser window.

Quitting halfway brings the steps back at the next launch. If you used OpenArch before it had them, you never see them; **Settings › Allgemein › Einführung › Erneut zeigen** opens them any time.

:::tip[Coming from Arc?]
What the import takes, and how Arc's logins come over: [Move over from Arc](/start/import-from-arc/).
:::

## Make it your default browser

So that links from Mail, Slack and other apps open in OpenArch: **Settings › Allgemein** (or **Settings › Links**) › **Standardbrowser** › **Als Standard festlegen**. macOS asks you to confirm.

Which window or space a link opens in is up to you; see [Links from other apps](/browsing/links/).

## Updates

OpenArch updates itself. It looks for a new build when it starts and every six hours after that, and downloads it in the background. When it is ready, **Update bereit** shows at the bottom of the sidebar:

- Click **Neu starten** to install it right away. Your windows and tabs come back as they were.
- Or keep working: the update installs the next time you quit OpenArch.

**Settings › Info › Updates** shows the version you have, and has **Jetzt prüfen** to look for an update at once. **Automatisch aktualisieren** turns the automatic checks off.

:::note[Only OpenArch's own builds]
OpenArch only installs an update that comes from its own GitHub releases and is signed with OpenArch's Developer ID. A download that is incomplete or signed by anyone else is thrown away.
:::

## Where your data is

Everything OpenArch keeps lives in `~/Library/Application Support/OpenArch`: your sidebar and settings, Chromium's profiles with your logins and history, and the AI features' folders. **Settings › Info › Daten** opens it. More in [Data and privacy](/reference/data-and-privacy/).

## Uninstall

Quit OpenArch and move it from **Applications** to the trash. To remove your data too, delete `~/Library/Application Support/OpenArch`.
