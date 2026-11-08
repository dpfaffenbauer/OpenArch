---
title: "Known limitations"
description: "What OpenArch does not do yet, or does differently from Chrome and Arc."
---

OpenArch is early, but usable as a daily browser. These are the gaps worth knowing before you move over.

## The Mac it runs on

OpenArch runs on Macs with Apple silicon and macOS 15 or later. There is no build for Intel Macs.

## Passwords and cookies

Chrome protects saved passwords and cookies with a key in your login keychain. OpenArch does not use the keychain yet, so they are not protected that way. See [Data and privacy](/reference/data-and-privacy/).

## Streaming with DRM

OpenArch's Chromium does not play the big streaming services: they ask for Widevine with a certification (Verified Media Path) that OpenArch does not have. Spotify, Netflix, Disney+ and the other listed services open with Safari's engine instead, which plays them with FairPlay, but there Chrome extensions do not run and you sign in once more. Chromium's own Widevine is off unless you turn it on, and then plays only streams that ask for no certification. See [Streaming services](/browsing/protected-media/). Other video plays in Chromium, including H.264, AAC and HEVC, which OpenArch's own Chromium build includes.

## Google sync

Google does not offer Chrome sync to other Chromium browsers. Signing in to Google works on websites as usual, but bookmarks, passwords and history do not sync with Chrome.

## Moving over from Arc

The full import, with logins, passwords and extensions, has been tested on copies of Arc profiles, not yet on many real ones. It never changes Arc's own data, so Arc keeps working as it was. See [Move over from Arc](/start/import-from-arc/).

## Not built yet

Arc's **Easels** and **Notes** have no counterpart in OpenArch yet.

## Full screen

Full screen is new. A video in full screen gets a space of its own, as in Chrome.

## AI features

The AI features need the Claude Code command line tool on your Mac, signed in. Without it they say so, and the rest of OpenArch works as usual. See [How OpenArch talks to Claude](/ai/how-it-works/).
