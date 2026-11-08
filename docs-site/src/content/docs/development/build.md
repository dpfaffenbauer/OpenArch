---
title: "Build from source"
description: "Build OpenArch for the Mac and for iPhone and iPad, run its self-test, and work on these docs."
---

OpenArch is open source under the MIT license. The code is on [GitHub](https://github.com/dpfaffenbauer/OpenArch).

## The Mac app

You need Xcode 16 or later (Swift 6), CMake and Ninja.

```sh
App/build.sh                      # fetches CEF, builds App/build/OpenArch.app
open App/build/OpenArch.app
```

The first build downloads OpenArch's Chromium (CEF with the codecs) into `Vendor/cef`. Builds made this way are signed ad hoc. With `SIGN_IDENTITY` set to a Developer ID, `build.sh` signs with it and the hardened runtime instead, as the releases are.

### The self-test

```sh
App/build/OpenArch.app/Contents/MacOS/OpenArch --selftest
```

It starts OpenArch with a profile of its own, behind your other windows, walks through the features and prints one line per check. It ends with `DONE failures=0` when everything passed. Your own data is not touched.

Parts of it run on their own: `--dia-test` (tab previews, meetings, screen sharing, shortcuts and more) and `--ai-test` (the AI features, with a stand-in for `claude`).

## iPhone and iPad

Open `iOS/OpenArch.xcodeproj` in Xcode and run it; choose your team under **Signing** to run it on a device. The app has its own self-test, `-selftest`.

## How releases are made

GitHub Actions builds every push (`.github/workflows/build.yml`) and publishes the newest build of `main` as the [nightly release](https://github.com/dpfaffenbauer/OpenArch/releases/tag/nightly), which OpenArch updates itself from.

OpenArch's Chromium is its own build of CEF with the proprietary codecs (H.264, AAC, HEVC) that the official CEF builds leave out. `cef-codecs.yml` makes it on GitHub, in about ten hours. Once a day `update-cef.yml` looks for a newer stable CEF, starts that build when there is one, and then opens the update as a pull request, which merges itself once the checks have passed.

## These docs

The docs are in `docs-site/`, built with [Starlight](https://starlight.astro.build). `docs-site/WRITING.md` says how the pages are written.

```sh
cd docs-site
nvm use          # Node 24
npm install
npm run dev      # http://localhost:4321
```

`.github/workflows/docs.yml` builds them for every pull request. Cloudflare publishes `main` to docs.openarch.app.
