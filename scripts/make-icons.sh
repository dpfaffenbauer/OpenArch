#!/usr/bin/env bash
# Draws OpenArch's standard icon (Tunnel, from AppIcons.swift) into the app
# bundle's AppIcon.icns and the website's icon.png. Run it after changing the
# icon's drawing; it builds the app first if needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/App/build/OpenArch.app/Contents/MacOS/OpenArch"
[ -x "$APP" ] || "$ROOT/App/build.sh"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$APP" --export-icons "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$ROOT/App/Resources/AppIcon.icns"
cp "$OUT/icon.png" "$ROOT/website/assets/icon.png"
echo "Wrote App/Resources/AppIcon.icns and website/assets/icon.png; rebuild the app to use the icon."
