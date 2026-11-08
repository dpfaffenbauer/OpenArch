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

:::tip[Coming from Arc?]
OpenArch can take over your spaces, favorites, pinned folders and today tabs, and with them your logins, passwords, history and extensions. See [Move over from Arc](/start/import-from-arc/). From Chrome, Edge, Brave, Firefox, Safari and others, see [Move over from another browser](/start/import/).
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
