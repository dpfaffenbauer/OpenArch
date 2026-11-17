#!/usr/bin/env bash
# Downloads OpenArch's engine (Chrome's framework with OpenArch's layer,
# docs/chromium-engine.md) into Vendor/engine/Chromium.app, so that
# App/build.sh needs no Chromium checkout.
#
# .github/workflows/chromium-engine.yml builds the engine and publishes it as
# the release engine-<Chrome version>-<key>. The key is a hash of everything
# the build is made from in this repository (the layer, its hooks, the
# bridge's headers, the build's settings), so a change to any of them asks
# for a new build, and an app is never built on a framework with another
# version of the bridge.
#
#   scripts/fetch-chromium-engine.sh         download, unless already there
#   scripts/fetch-chromium-engine.sh --tag   print the release's tag
#   scripts/fetch-chromium-engine.sh --key   print the key
#
# CHROMIUM_VERSION overrides engine/chromium/VERSION (used by
# scripts/update-chromium.sh for a version not pinned yet).
# Written for bash 3.2.
set -euo pipefail

REPO_SLUG="${ENGINE_REPO:-dpfaffenbauer/OpenArch}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${CHROMIUM_VERSION:-$(cat "$ROOT/engine/chromium/VERSION")}"
TARGET="$ROOT/Vendor/engine"

# What the engine is built from. VERSION is not part of the key's files:
# the tag names it, and the updater computes the key for a version before
# it is pinned.
KEY_PATHS="engine/chromium/apply.sh engine/chromium/hooks engine/chromium/openarch
App/Sources/OpenArchCore/include scripts/build-chromium.sh scripts/chromium-engine-ci.sh"

key() {
  (cd "$ROOT" &&
    find $KEY_PATHS -type f ! -name .DS_Store -print | LC_ALL=C sort |
    while read -r file; do shasum -a 256 "$file"; done |
    shasum -a 256 | cut -c1-12)
}

tag() {
  echo "engine-$VERSION-$(key)"
}

archive_name() {
  echo "openarch-engine-$VERSION-macos-arm64.zip"
}

case "${1:-}" in
  --key) key; exit 0 ;;
  --tag) tag; exit 0 ;;
  --archive) archive_name; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--key|--tag|--archive]" >&2; exit 2 ;;
esac

TAG="$(tag)"
NAME="$(archive_name)"
base="https://github.com/$REPO_SLUG/releases/download/$TAG"
# A release's archive can be replaced (a local build published first, CI's
# official one later): the one here is kept only while its SHA-256 is still
# the release's. Offline, it is kept as it is.
if [[ -f "$TARGET/.tag" && -d "$TARGET/Chromium.app" ]]; then
  read -r have_tag have_sha < "$TARGET/.tag" || true
  if [[ "$have_tag" == "$TAG" ]]; then
    remote_sha="$(curl -fsSL "$base/$NAME.sha256" 2>/dev/null | awk '{ print $1 }' || true)"
    if [[ -z "$remote_sha" || "$remote_sha" == "${have_sha:-}" ]]; then
      echo "Engine $TAG already present"
      exit 0
    fi
    echo "Engine $TAG was replaced in its release; downloading it again"
  fi
fi

mkdir -p "$TARGET"
echo "Downloading $base/$NAME"
if ! curl -fL --progress-bar -o "$TARGET/$NAME.part" "$base/$NAME"; then
  rm -f "$TARGET/$NAME.part"
  echo "No engine release $TAG (yet). Start Actions > Chromium engine for this commit," >&2
  echo "or build it locally with scripts/build-chromium.sh." >&2
  exit 1
fi
mv "$TARGET/$NAME.part" "$TARGET/$NAME"
expected="$(curl -fsSL "$base/$NAME.sha256" | awk '{ print $1 }')"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "No SHA-256 for $NAME" >&2; exit 1; }
echo "$expected  $TARGET/$NAME" | shasum -a 256 -c -

rm -rf "$TARGET/Chromium.app"
ditto -x -k "$TARGET/$NAME" "$TARGET"
rm -f "$TARGET/$NAME"
[[ -d "$TARGET/Chromium.app/Contents/Frameworks/Chromium Framework.framework" ]] ||
  { echo "The archive has no Chromium.app with its framework" >&2; exit 1; }
echo "$TAG $expected" > "$TARGET/.tag"
echo "Engine $TAG ready in $TARGET/Chromium.app"
