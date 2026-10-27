#!/usr/bin/env bash
# Downloads the pinned CEF minimal binary distribution into Vendor/cef.
set -euo pipefail

CEF_VERSION="156.0.14+g4fa4ab5+chromium-156.0.8078.48"
CEF_PLATFORM="macosarm64"
CEF_SHA1="7359a9d293dd5c480bec3f18b762731b483b0e13"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
ARCHIVE="$VENDOR/$NAME.tar.bz2"
TARGET="$VENDOR/cef"

if [[ -f "$TARGET/.version" && "$(cat "$TARGET/.version")" == "$CEF_VERSION" ]]; then
  echo "CEF $CEF_VERSION already present"
  exit 0
fi

mkdir -p "$VENDOR"
if [[ ! -f "$ARCHIVE" ]]; then
  url="https://cef-builds.spotifycdn.com/$(printf '%s' "$NAME" | sed 's/+/%2B/g').tar.bz2"
  echo "Downloading $url"
  curl -fL --progress-bar -o "$ARCHIVE.part" "$url"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

echo "$CEF_SHA1  $ARCHIVE" | shasum -a 1 -c -

rm -rf "$TARGET" "$VENDOR/$NAME"
tar -xjf "$ARCHIVE" -C "$VENDOR"
mv "$VENDOR/$NAME" "$TARGET"
echo "$CEF_VERSION" > "$TARGET/.version"
rm -f "$ARCHIVE"
echo "CEF $CEF_VERSION ready in $TARGET"
