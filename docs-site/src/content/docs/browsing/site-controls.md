---
title: "Site controls, Boosts and DevTools"
description: "What a site may do, its zoom and data in the Site Control Center, Boosts that restyle a site, DevTools beside the page, HTTPS only, and find and print."
---

Everything about the site in front sits in one place, the Site Control Center, as in Arc: what the site may use, its zoom, its boost, and its cookies and data. This page also covers Boosts, which change how a site looks, DevTools, and the settings and commands that act on the page.

## The Site Control Center

Open it with <kbd>⌃⌘I</kbd> (**Ansicht › Website-Einstellungen …**) or with the sliders button at the top of the sidebar. It opens under the sidebar's top bar and is about the tab in front. If the sidebar is hidden, <kbd>⌃⌘I</kbd> shows it first.

At the top are the site's address and whether the connection is secure: **Verbindung ist sicher** for `https://`, **Verbindung ist nicht sicher** for anything else. Chrome's and OpenArch's own pages say **Eine Seite von OpenArch** and have no permissions.

### Permissions

Each permission has a menu. **Standard** does what Chrome does when nothing is chosen, shown in brackets. With **Fragen**, Chrome asks you when the site wants it; **Erlauben** and **Blockieren** decide for good.

| Permission | What it covers | Standard |
| --- | --- | --- |
| **Kamera** | camera | Fragen |
| **Mikrofon** | microphone | Fragen |
| **Standort** | location | Fragen |
| **Mitteilungen** | notifications | Fragen |
| **Pop-ups** | pop-up windows | Blockieren |
| **Ton** | sound | Erlauben |
| **Mehrere Downloads** | several downloads at once | Fragen |
| **Zwischenablage** | reading the clipboard | Fragen |
| **JavaScript** | scripts | Erlauben |

**Pop-ups**, **Ton** and **JavaScript** cannot be set to **Fragen**.

A choice applies to the site's address as you see it at the top (scheme, host and port, say `https://www.example.com`), in the tab's profile. A space with another profile keeps its own choices.

### Zoom

**Zoom** shows the page's size in percent, with **−** and **+** to change it and **Zurücksetzen** to go back to 100 %. Chrome keeps the zoom per site, so every page of the site opens at it. The menu commands do the same:

| Key | Menu item |
| --- | --- |
| <kbd>⌘+</kbd> | **Ansicht › Vergrößern** |
| <kbd>⌘-</kbd> | **Ansicht › Verkleinern** |
| <kbd>⌘0</kbd> | **Ansicht › Originalgröße** |

### Boost, address and data

- **Boost bearbeiten …** opens the Boost editor for the site (below).
- **URL kopieren** copies the page's address.
- **Website-Daten löschen …** deletes the site's cookies and everything it stored. OpenArch asks first. You are signed out of the site, and the page loads again.

## Boosts

A boost changes how a site looks, every time you open it: shifted colors, another font, elements gone, and your own CSS and JavaScript. Open the editor with <kbd>⌃⌘B</kbd> (**Ansicht › Boost bearbeiten …**), "Boost bearbeiten" in the [command bar](/browsing/command-bar/), or the Site Control Center. It opens as a small panel beside the page, titled **Boost · …** with the site's name.

Every change shows on the page at once, and in every other open tab of the site.

| Part | What it does |
| --- | --- |
| switch at the top | turns the boost on or off, without losing it |
| **Farbe** | turns all colors around the color wheel; **Aus** sets it back. Photos and videos keep their colors. |
| **Schrift** | another font for the page's text: **Wie die Seite** (the page's own), Helvetica Neue, Avenir Next, Futura, Georgia, Iowan Old Style, Charter, Menlo or Comic Sans MS. Code and icons keep theirs. |
| **Elemente ausblenden** | **Zap: Elemente anklicken …**, then click anything on the page to hide it. <kbd>Esc</kbd> or **Fertig** ends it. Each hidden element is listed, with a button to bring it back. |
| **CSS** | your own style sheet for the site |
| **JavaScript** | your own script; it runs once on every page of the site, so a change shows after a reload |
| **Boost löschen** | removes the boost |

A boost belongs to a site and its subdomains: one for `github.com` also applies to `gist.github.com`. Boosts apply in every space and profile. They are kept in `Boosts.json` in `~/Library/Application Support/OpenArch`. Boosts work on web pages only (`http://` and `https://`).

## DevTools

<kbd>⌥⌘I</kbd> (**Ansicht › Entwicklertools**) opens Chrome's DevTools for the tab. More entry points:

| Key | Menu item |
| --- | --- |
| <kbd>⌥⌘C</kbd> | **Ansicht › Element untersuchen** |
| <kbd>⌥⌘J</kbd> | **Ansicht › JavaScript-Konsole** |
| <kbd>⌥⌘U</kbd> | **Ansicht › Quelltext anzeigen** |

DevTools dock inside the tab, beside the page: on the right or left they take 40 % of the width, below they take 38 % of the height. Choose where under **Ansicht › DevTools anordnen**: **Rechts** (the default), **Links**, **Unten** or **Eigenes Fenster**. DevTools' own menu (⋮ › Dock side) works too. The choice is kept and applies to every tab; DevTools that are open move at once.

<kbd>⌘W</kbd> in DevTools closes them, not the tab.

## HTTPS only

Turn on **Settings › Allgemein › Sicherheit › Nur HTTPS** to load `http://` addresses over HTTPS first. If a site has no HTTPS, OpenArch warns you before it opens the page unencrypted. This is Chromium's HTTPS-First mode. It is off unless you turn it on.

## Find, print and save

These are Chrome's own commands, for the tab in front:

| Key | Menu item |
| --- | --- |
| <kbd>⌘F</kbd> | **Bearbeiten › Suchen …** |
| <kbd>⌘G</kbd> / <kbd>⇧⌘G</kbd> | **Bearbeiten › Weitersuchen** / **Rückwärts suchen** |
| <kbd>⌘P</kbd> | **Ablage › Drucken …** |
| <kbd>⇧⌘S</kbd> | **Ablage › Seite sichern unter …** |
| <kbd>⇧⌘R</kbd> | **Ansicht › Neu laden ohne Cache** |
| <kbd>⌥⇧⌘C</kbd> | **Bearbeiten › URL als Markdown kopieren** |
