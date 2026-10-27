#!/usr/bin/env bash
# Patches the CEF binary in Vendor/cef once per CEF version: extension popups
# open 2 s late otherwise (see patch-cef.swift). Building CEF from source
# would replace this.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF="$ROOT/Vendor/cef"
FW="$CEF/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
MARKER="$CEF/.patched-new-browser-info-timeout"

[[ -f "$MARKER" ]] && exit 0
TOOL="$(mktemp -d)/patch-cef"
swiftc -O -o "$TOOL" "$ROOT/scripts/patch-cef.swift"
"$TOOL" "$FW"
rm -rf "$(dirname "$TOOL")"
touch "$MARKER"
