---
title: "Extensions and Chrome features"
description: "Every tab in OpenArch is a real Chrome tab: extensions with popups and side panels, Chrome's toolbar, the password manager, chrome:// pages, video codecs and the sandbox."
---

OpenArch runs on Chromium, and every tab is a real Chrome tab. So what you know from Chrome works as in Chrome: extensions from the Chrome Web Store with their buttons, popups and side panels, the password manager, Chrome's settings and other pages, DevTools, find, printing, downloads and Chrome's permission prompts. OpenArch adds its sidebar, spaces and command bar around it.

## Chrome's toolbar

Above the page, each tab shows Chrome's toolbar: the address field, your extensions' buttons, the downloads button and Chrome's menu (⋮). Chrome's profile button is not there, because in OpenArch the [space](/sidebar/spaces/) decides the profile.

To hide the toolbar in every tab, press <kbd>⇧⌘D</kbd> (**Ansicht › Chrome-Toolbar ein-/ausblenden**) or turn off **Settings › Allgemein › Tabs › Chrome-Toolbar in Tabs**. [Peek](/browsing/peek/) cards never have it. In [Little OpenArch](/browsing/windows/#little-openarch) it is hidden until you click the puzzle piece in its bar.

## Extensions

### Installing

1. Open the Chrome Web Store: **Extensions › Chrome Web Store** in the menu bar, or "Chrome Web Store" in the [command bar](/browsing/command-bar/).
2. Find the extension and add it, as in Chrome.

An extension goes into the profile of the space you are in. Spaces with another profile do not have it; install it there too if you want it in them. Each profile keeps its own extensions and their settings.

**Extensions › Extensions verwalten** (or "Extensions verwalten" in the command bar) opens Chrome's extensions page, where you turn extensions off, change their options or remove them.

### Using them

An extension's button sits in Chrome's toolbar. As in Chrome, the puzzle piece there lists all of them, and you can pin the ones you want to see. A click on a button opens the extension's popup. Extensions with a side panel open it beside the page, inside the tab.

These work too:

- **Tabs an extension opens** (`chrome.tabs`) open as OpenArch tabs, in the window you used last. Popup windows that an extension opens stay windows of their own.
- **Content blockers** built on `declarativeNetRequest`.
- **Native messaging**, with which extensions talk to an app on the Mac, such as 1Password, Google Drive or Apple Passwords. At every launch, OpenArch copies the connections that Arc and Chrome have set up (from their `NativeMessagingHosts` folders) into its own, so these extensions find their app without setup. A connection OpenArch already has is left as it is.

### Your extensions from Arc

There are two ways to bring them over:

- The full [import from Arc](/start/import-from-arc/) (**Alles übernehmen**) takes your installed extensions along, with their settings.
- **Extensions › Extensions aus Arc …** (also **Settings › Import › Extensions aus Arc › Ordner anlegen**) makes a pinned folder **Extensions aus Arc** with one Chrome Web Store link per extension, if you would rather install them fresh. Open each and add it.

### The OpenArch extension

Chrome's extensions page lists one extension you did not install: **OpenArch**. It is part of the app. It tells the sidebar which tabs play audio or video and what, for the player at the bottom of the sidebar, and which tabs share the screen.

## Passwords

Chrome's password manager saves and fills passwords as in Chrome. Each profile has its own, so a space with another profile has other passwords. To see them, choose **Verlauf › Passwörter** or "Passwörter" in the command bar. The [import from Arc](/start/import-from-arc/) brings your saved passwords along.

Saved passwords are encrypted with OpenArch's key in your login keychain, **OpenArch Safe Storage**. See [Data and privacy](/reference/data-and-privacy/#the-key-to-your-passwords-and-cookies).

## Chrome's own pages

Chrome's pages, such as `chrome://settings` or `chrome://history`, open in a tab like any page. In OpenArch's own places, the command bar and the sidebar, they are shown as `openarch://`: `openarch://settings` is `chrome://settings`. You can type either. Chrome's toolbar in the tab keeps showing `chrome://`.

| Page | Menu item | Command bar | Key |
| --- | --- | --- | --- |
| `chrome://settings` | **Extensions › Browser-Einstellungen** | "Browser-Einstellungen" | |
| `chrome://history` | **Verlauf › Verlauf anzeigen** | "Verlauf" | <kbd>⌘Y</kbd> |
| `chrome://downloads` | **Verlauf › Alle Downloads** | "Downloads" | <kbd>⌥⌘L</kbd> |
| `chrome://password-manager` | **Verlauf › Passwörter** | "Passwörter" | |
| `chrome://extensions` | **Extensions › Extensions verwalten** | "Extensions verwalten" | |

Chrome's history page shows the history of one profile, the one of the space you are in. The command bar searches all of them.

Chrome's About page (`chrome://help`) opens OpenArch's own **Über OpenArch** window instead, which shows both OpenArch's and Chromium's version. **Settings › Info** shows them too.

## Chrome's menu and shortcuts

OpenArch's own shortcuts come first, as in Arc: a page or Chrome cannot take <kbd>⌘T</kbd>, <kbd>⌘L</kbd> or <kbd>⌃Tab</kbd>. When Chrome's menu or one of Chrome's shortcuts asks for something OpenArch does its own way, OpenArch does it its way: a new tab, the address field and tab search open the command bar, and bookmarking the tab pins it. Chrome's menu has no items for new windows; use OpenArch's (see [Windows](/browsing/windows/)).

## Video and audio

OpenArch's Chromium is built with the codecs that the standard Chromium Embedded Framework builds leave out: **H.264**, **AAC** and **HEVC**. Videos and audio in these formats play as in Chrome.

:::note
OpenArch has no Widevine. Video protected with DRM, such as Netflix, does not play. Google's sync for Chrome is not available either.
:::

## Sandbox

Pages, the GPU process and the network service run in Chromium's sandbox, as in Chrome. Every helper process of OpenArch starts the sandbox before it loads Chromium.
