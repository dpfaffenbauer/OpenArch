#!/usr/bin/env bash
# Patches the pinned CEF binary in Vendor/cef (idempotent).
#
# CEF waits up to 2 s for "new browser info" for every frame that does not
# belong to a CEF browser. Extension popups are such frames, so every
# extension popup (1Password, uBlock, ...) opened 2 s late. The wait is the
# constant kNewBrowserInfoResponseTimeoutMs in
# libcef/browser/browser_info_manager.cc. This lowers it to 150 ms, which
# still covers real CEF popups whose browser info arrives a moment late.
#
# The offsets are only valid for the CEF version below; anything else is
# refused. Building CEF from source would replace this patch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF="$ROOT/Vendor/cef"
FW="$CEF/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
EXPECTED_VERSION="156.0.14+g4fa4ab5+chromium-156.0.8078.48"
MARKER="$CEF/.patched-new-browser-info-timeout"

[[ -f "$MARKER" ]] && exit 0
if [[ "$(cat "$CEF/.version" 2>/dev/null)" != "$EXPECTED_VERSION" ]]; then
  echo "patch-cef: CEF is not $EXPECTED_VERSION; update the patch offsets" >&2
  exit 1
fi

# CefBrowserInfoManager::OnGetNewBrowserInfo, the PostDelayedTask delay in
# microseconds (arm64): mov w3, #0x8480; movk w3, #0x1e, lsl #16 = 2000000.
OFFSET=$((0x37e644))
ORIGINAL="03909052c303a072"
# mov w3, #0x49f0; movk w3, #0x2, lsl #16 = 150000
PATCHED="033e895243 00a072"
PATCHED="${PATCHED// /}"

current="$(xxd -p -s "$OFFSET" -l 8 "$FW")"
if [[ "$current" == "$PATCHED" ]]; then
  touch "$MARKER"
  exit 0
fi
if [[ "$current" != "$ORIGINAL" ]]; then
  echo "patch-cef: unexpected bytes at $OFFSET ($current); not patching" >&2
  exit 1
fi
printf '%s' "$PATCHED" | xxd -r -p | dd of="$FW" bs=1 seek="$OFFSET" conv=notrunc status=none
touch "$MARKER"
echo "patch-cef: extension popup delay 2000 ms -> 150 ms"
