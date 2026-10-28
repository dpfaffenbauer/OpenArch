#!/usr/bin/env bash
# Downloads the pinned CEF minimal binary distribution into Vendor/cef.
#
# The official CEF builds leave out H.264, AAC and HEVC, so OpenArch uses its
# own build of the same CEF version with the proprietary codecs, made by
# .github/workflows/cef-codecs.yml and published as the release
# cef-<version>-codecs. scripts/update-cef.sh moves the pin.
set -euo pipefail

CEF_VERSION="156.0.14+g4fa4ab5+chromium-156.0.8078.48"
CEF_PLATFORM="macosarm64"
CEF_SHA256="ac5dfc9a904defca4a7ecdeb2270d2a8e37daf0612a95076e73acec372561378"
CEF_REPO="dpfaffenbauer/OpenArch"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
ARCHIVE="$VENDOR/$NAME.tar.bz2"
TARGET="$VENDOR/cef"
# Tells this build apart from an official one of the same version.
MARK="$CEF_VERSION codecs"

if [[ -f "$TARGET/.version" && "$(cat "$TARGET/.version")" == "$MARK" ]]; then
  echo "CEF $CEF_VERSION (codecs) already present"
  exit 0
fi

mkdir -p "$VENDOR"
if [[ ! -f "$ARCHIVE" ]]; then
  url="https://github.com/$CEF_REPO/releases/download/cef-${CEF_VERSION%%+*}-codecs/$(printf '%s' "$NAME" | sed 's/+/%2B/g').tar.bz2"
  echo "Downloading $url"
  curl -fL --progress-bar -o "$ARCHIVE.part" "$url"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

echo "$CEF_SHA256  $ARCHIVE" | shasum -a 256 -c -

rm -rf "$TARGET" "$VENDOR/$NAME"
tar -xjf "$ARCHIVE" -C "$VENDOR"
mv "$VENDOR/$NAME" "$TARGET"
echo "$MARK" > "$TARGET/.version"
rm -f "$ARCHIVE"
echo "CEF $CEF_VERSION (codecs) ready in $TARGET"
