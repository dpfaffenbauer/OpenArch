#!/usr/bin/env bash
# Builds build/OpenArch.app: the Swift app on Chrome's own framework with
# OpenArch's layer (docs/chromium-engine.md).
#
# The engine is OPENARCH_ENGINE_APP if set, else a local
# scripts/build-chromium.sh build (~/chromium/src/out/OpenArch/Chromium.app),
# else the release CI built for this Chrome version and layer
# (scripts/fetch-chromium-engine.sh, into Vendor/engine).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
CONFIG="${CONFIG:-debug}"
NAME="OpenArch"
APP="$APP_DIR/build/$NAME.app"
SWIFT_ARGS=(--package-path "$APP_DIR" -c "$CONFIG")
ENGINE_APP="${OPENARCH_ENGINE_APP:-$HOME/chromium/src/out/OpenArch/Chromium.app}"
if [[ -z "${OPENARCH_ENGINE_APP:-}" && ! -d "$ENGINE_APP" ]]; then
  "$ROOT/scripts/fetch-chromium-engine.sh"
  ENGINE_APP="$ROOT/Vendor/engine/Chromium.app"
fi
export OPENARCH_ENGINE_FRAMEWORKS="$ENGINE_APP/Contents/Frameworks"  # read by Package.swift
[[ -d "$OPENARCH_ENGINE_FRAMEWORKS/Chromium Framework.framework" ]] ||
  { echo "No engine in $OPENARCH_ENGINE_FRAMEWORKS" >&2; exit 1; }
BUNDLE_ID="dev.openarch.browser"
VERSION="${OPENARCH_VERSION:-0.1.0}"
# CI sets these; local builds are build 0 and never update themselves.
BUILD="${OPENARCH_BUILD:-0}"
# The update channel the build starts on: "stable" for version tags.
CHANNEL="${OPENARCH_CHANNEL:-nightly}"
COMMIT="${OPENARCH_COMMIT:-$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo dev)}"

swift build "${SWIFT_ARGS[@]}"
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

# write_plist <path> <executable> <bundle id> <display name> <extra plist entries>
# Written next to the target and moved into place, so that LaunchServices
# never reads a half-written Info.plist of a running OpenArch (the Dock then
# shows a blank icon).
write_plist() {
  cat > "$1.new" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$4</string>
  <key>CFBundleDisplayName</key><string>$4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string><string>fr</string><string>es</string><string>it</string></array>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  $5
</dict>
</plist>
PLIST
  mv -f "$1.new" "$1"
}

# Replaces a file by rename, so a running OpenArch keeps its old binary
# instead of being killed for a changed code signature.
install_file() {
  cp "$1" "$2.new" && mv -f "$2.new" "$2"
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
install_file "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
write_plist "$APP/Contents/Info.plist" "$NAME" "$BUNDLE_ID" "$NAME" "
  <key>NSPrincipalClass</key><string>OACApplication</string>
  <key>NSDockTilePlugIn</key><string>OpenArchDockTile.docktileplugin</string>
  <key>OpenArchCommit</key><string>$COMMIT</string>
  <key>OpenArchChannel</key><string>$CHANNEL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Web site URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict><dict>
    <key>CFBundleURLName</key><string>OpenArch share link</string>
    <key>CFBundleURLSchemes</key><array><string>openarch</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>HTML document</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array>
    <key>LSHandlerRank</key><string>Default</string>
  </dict></array>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>dev.openarch.tab</string>
    <key>UTTypeDescription</key><string>OpenArch tab</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict><dict>
    <key>UTTypeIdentifier</key><string>dev.openarch.space</string>
    <key>UTTypeDescription</key><string>OpenArch space</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  <key>NSCameraUsageDescription</key><string>Websites can ask to use your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites can ask to use your microphone.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Websites can ask to use your Bluetooth devices.</string>
  <key>NSLocationUsageDescription</key><string>Websites can ask for your location.</string>
  <key>NSAppleEventsUsageDescription</key><string>The player in the sidebar can pause Spotify and skip its songs.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>OpenArch shows your next meeting in the sidebar, with a button to join the call.</string>
  <key>NSCalendarsUsageDescription</key><string>OpenArch shows your next meeting in the sidebar, with a button to join the call.</string>"
# Chrome's framework, with its helper apps inside (Versions/<v>/Helpers).
# What a CEF build of OpenArch left in an older build folder goes.
rm -rf "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/$NAME Helper"*.app
rsync -a --delete "$OPENARCH_ENGINE_FRAMEWORKS/Chromium Framework.framework" "$APP/Contents/Frameworks/"
FRAMEWORK="$APP/Contents/Frameworks/Chromium Framework.framework"
rsync -a --delete "$APP_DIR/Resources/" "$APP/Contents/Resources/"
# Chrome takes its language from the app's localizations (macOS's preferred
# one among them): the same, empty ones Chromium.app has, beside OpenArch's.
for lproj in "$ENGINE_APP"/Contents/Resources/*.lproj; do
  mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
done

# The Dock's plug-in, which shows the chosen app icon while OpenArch is
# closed (Sources/OpenArchDockTile).
PLUGIN="$APP/Contents/PlugIns/OpenArchDockTile.docktileplugin"
mkdir -p "$PLUGIN/Contents/MacOS"
clang -bundle -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=15.0 -framework AppKit \
  -o "$PLUGIN/Contents/MacOS/OpenArchDockTile" "$APP_DIR/Sources/OpenArchDockTile/OpenArchDockTile.m"
write_plist "$PLUGIN/Contents/Info.plist" "OpenArchDockTile" "$BUNDLE_ID.docktile" "OpenArchDockTile" \
  "<key>NSPrincipalClass</key><string>OpenArchDockTile</string>"
sed -i '' 's|<key>CFBundlePackageType</key><string>APPL</string>|<key>CFBundlePackageType</key><string>BNDL</string>|' "$PLUGIN/Contents/Info.plist"

# Signatures, inside out. SIGN_IDENTITY (a Developer ID, set by CI) signs
# with the hardened runtime for notarization; without it, ad hoc.
SIGNING="$APP_DIR/Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
else
  sign() { codesign --force --sign - "$@"; }
fi
# Chrome's helper apps and tools inside the framework, before the
# framework; the helpers with Chrome's entitlements (JIT for V8 and
# SwiftShader). Chrome looks them up by name per process type.
for item in "$FRAMEWORK"/Versions/Current/Helpers/*; do
  case "$item" in
    *"Plugin).app") sign --entitlements "$SIGNING/HelperPlugin.entitlements" "$item" ;;
    *"Alerts).app") sign "$item" ;;
    # The plain helper runs the utility processes, Widevine's among them.
    *"/Chromium Helper.app" | *"(Aperitif).app") sign --entitlements "$SIGNING/HelperUtility.entitlements" "$item" ;;
    *.app) sign --entitlements "$SIGNING/Helper.entitlements" "$item" ;;
    *) sign "$item" ;;
  esac
done
for library in "$FRAMEWORK"/Libraries/*.dylib; do
  if [[ -f "$library" ]]; then sign "$library"; fi
done
sign "$FRAMEWORK"
sign "$PLUGIN"
sign --entitlements "$SIGNING/OpenArch.entitlements" "$APP"

# Let LaunchServices (and the Dock) pick up the rebuilt bundle and its icon.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP"

echo "Built $APP"
