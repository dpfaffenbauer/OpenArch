---
title: "Colors, glass and grain"
description: "How the space's color sets OpenArch's look, the glass and Liquid Glass options, Arc's grain, the twelve app icons and the About window."
---

OpenArch looks like Arc by default: the window takes the color of the space you are in, the sidebar sits on it with white text, and the pages lie on top as rounded cards. You can let the desktop show through as glass, add Arc's grain, and pick a Dock icon.

## The space's color

Each [space](/sidebar/spaces/) has a color, set under **Farbe** in its editor. The sidebar, the space bar and the frame around the pages all take it. Switching spaces switches the color.

The text in the sidebar is white on every color except very light ones, which get dark text, as in Arc. Menus and popovers from the sidebar follow along: dark on a dark color, light on a light one.

A window that is not in front shows its color a little darker and grayer, so you can tell which window is active.

Pages keep their own look. [Agent chats](/ai/agent-chats/) follow the Mac's light or dark mode, like pages, not the space's color.

## Glass

Turn on **Settings › Allgemein › Sidebar › Glas-Effekt** (glass effect) to let the desktop show through the window.

- **On macOS 26**, the whole window becomes one sheet of Liquid Glass, tinted with the space's color. The sidebar and the window buttons sit directly on it, and the pages float above as cards.
- **On earlier macOS**, the window is frosted glass with the space's color over it.

**Tönung** (tint), just below, sets how much of the space's color lies in the glass. Less lets more of the desktop through; more keeps the text easy to read. It starts at 40 percent and goes up to 90.

## Grain

Arc put a fine grain on its colors. **Settings › Allgemein › Sidebar › Körnung** (grain) does the same: drag the slider to the right for more. All the way to the left, which is the default, it is off.

The grain lies over the space's color behind the sidebar and around the pages, with glass too. It is the same pattern every time, so it does not flicker.

## App icon

**Settings › Allgemein › App-Symbol** offers twelve takes on the arch for the Dock:

Dusk, Neon, Bänder, **Tunnel** (OpenArch's standard icon), Bauhaus, Sidebar, Moon Gate, Pixel, Origami, Orbit, Candy and Keystone.

Two more change by themselves:

- **Space-Farbe** (space color) draws Tunnel in the color of the space you are in, and changes with it.
- **Jeden Tag** (every day) shows a different one of the twelve each day.

The Dock shows your choice right away. While OpenArch is closed, a Dock tile plug-in keeps showing it. The app itself is never changed, so its code signature stays valid.

## Über OpenArch

**OpenArch › Über OpenArch** opens a window with a flight through OpenArch's arches, its version and Chromium's, and links to GitHub and openarch.app. Click the logo for warp speed: for two seconds the tunnel rushes past. The tunnel leans a little toward the pointer.

**Settings › Info** has a button for it too, **Über OpenArch …**, and so does clicking the icon there; the address `chrome://help` opens it as well. With **Reduce motion** on in the Mac's accessibility settings, the window stands still and the warp is off.
