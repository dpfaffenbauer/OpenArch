---
title: "Themes, glass and the sidebar's side"
description: "How a space's theme sets OpenArch's look: Arc's gradients, intensity and grain, light or dark, the glass options, the sidebar on the left or right, the twelve app icons and the About window."
---

OpenArch looks like Arc by default: the window takes the theme of the space you are in, the sidebar sits on it, and the pages lie on top as rounded cards. Each space's theme is one to three colors blending across the window, with Arc's intensity and grain. You can let the desktop show through as glass, put the sidebar on the right, and pick a Dock icon.

## A space's theme

Double-click a [space](/sidebar/spaces/)'s name (or **Space bearbeiten …** in its ••• menu) to open its editor. Under **Theme** is Arc's theme picker:

- **The color disc.** The hue goes around it, from dark in the middle to light at the edge. Drag a handle to change its color. Dragging the first, big handle turns the others with it; the others move alone.
- **− and +** take a color away or add one, up to three. A second color starts opposite the first, a third beside them.
- **Auto, Hell, Dunkel** (auto, light, dark): **Auto** follows the Mac's light or dark mode, but very light colors stay light and very dark ones stay dark, as in Arc.
- **Arc's nine swatches** and the color panel at the end set the selected handle's color.
- **Intensität** (intensity): how strongly the colors show. It starts at 0.81, Arc's default; to the left they wash out.
- **Körnung** (grain): Arc's fine grain on the colors. All the way to the left, which is the default, it is off.

Every change shows in the window as you make it, and is saved with the space.

The theme is drawn as Arc draws it. The first two colors blend along the window's 45° diagonal, from the top left, and reach the second color three quarters of the way; they blend in OKLab, so the middle of red and blue is a purple, not a muddy gray. A third color fades in towards the bottom. The colors lie at 0.2 + 0.55 × intensity over white (light) or black (dark), over the window's blur, so a little of the desktop shows through while the window is in front. The grain lies on top.

Where text would no longer read on the colors (a dark navy in a light theme, say), OpenArch washes them out until it does.

A window that is not in front lets no desktop through and shows its grain at a quarter of its strength, so you can tell which window is active.

## What the theme colors

One theme gives every part its colors: the sidebar's text, hover and selected rows, the space bar, the frame around the pages, the floating sidebar, the ⌃Tab switcher, tab previews, Little OpenArch and the library. The command bar's card is near white or deep gray with a little of the theme's hue, and its selected row takes the theme's strongest color. Toasts are a deep pill in the theme's hue. Menus and popovers follow along: dark in a dark theme, light in a light one.

Pages keep their own look. [Agent chats](/ai/agent-chats/) follow the Mac's light or dark mode, like pages, not the space's theme.

## Themes from Arc and from before

The [import from Arc](/start/import-from-arc/) brings each space's theme over exactly: its colors in order (Arc's base colors, then its overlay color), its intensity, its grain and whether it was light or dark. Old Arc files that only kept one color come over with that color at Arc's default intensity.

Spaces from OpenArch versions before themes keep their color as the theme's one handle, at the default intensity, with the grain that was set for all spaces then (**Körnung** used to be in Settings).

## Glass

Turn on **Settings › Allgemein › Sidebar › Glas-Effekt** (glass effect) to let the desktop show through the window.

- **On macOS 26**, the whole window becomes one sheet of Liquid Glass with the space's colors over it. The sidebar and the window buttons sit directly on it, and the pages float above as cards.
- **On earlier macOS**, the window is frosted glass with the space's colors over it.

**Tönung** (tint), just below, sets how much of the space's colors lies on the glass. Less lets more of the desktop through; more keeps the text easy to read. It starts at 40 percent and goes up to 90. The theme's grain lies on the glass too.

## The sidebar on the right

**Settings › Allgemein › Sidebar › Sidebar-Position** puts the sidebar on the window's **Links** (left, as in Arc) or **Rechts** (right). It applies to every window at once, with a short cross-fade.

On the right, everything that hangs off the sidebar's edge moves with it:

- the pages are inset from the window's left edge and end at the sidebar;
- the sidebar is resized from its inner, left edge; dragged far to the right, it collapses;
- with the sidebar hidden (⌘S), the window's right edge brings it back, floating over the page from the right;
- tab previews open to the left of the sidebar;
- a download flies into the library button on the right;
- swiping over the sidebar changes spaces as on the left.

The window buttons stay at the top left, now above the page, which leaves room for them. Dropping a tab on a half of the page for [split view](/browsing/split-view/) works the same on either side. Little OpenArch has no sidebar and keeps its layout.

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
