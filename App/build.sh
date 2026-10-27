#!/usr/bin/env bash
# Builds build/OpenArch.app: Swift app + CEF framework + helper apps.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
CEF="$ROOT/Vendor/cef"
CONFIG="${CONFIG:-debug}"
NAME="OpenArch"
APP="$APP_DIR/build/$NAME.app"
BUNDLE_ID="dev.openarch.browser"
VERSION="${OPENARCH_VERSION:-0.1.0}"
# CI sets these; local builds are build 0 and never update themselves.
BUILD="${OPENARCH_BUILD:-0}"
COMMIT="${OPENARCH_COMMIT:-$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo dev)}"

"$ROOT/scripts/fetch-cef.sh"
"$ROOT/scripts/patch-cef.sh"
if [[ ! -f "$CEF/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
  cmake -S "$CEF" -B "$CEF/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=OFF
  cmake --build "$CEF/build" --target libcef_dll_wrapper
fi

swift build --package-path "$APP_DIR" -c "$CONFIG"
BIN="$(swift build --package-path "$APP_DIR" -c "$CONFIG" --show-bin-path)"

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
  <key>OpenArchCommit</key><string>$COMMIT</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Web site URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
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
  </dict></array>
  <key>NSCameraUsageDescription</key><string>Websites can ask to use your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites can ask to use your microphone.</string>
  <key>NSLocationUsageDescription</key><string>Websites can ask for your location.</string>"
rsync -a --delete "$CEF/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/"
rsync -a --delete "$APP_DIR/Resources/" "$APP/Contents/Resources/"

# Chromium looks up one helper app per process type by name.
for suffix in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
  helper="$NAME Helper$suffix"
  id_suffix="$(printf '%s' "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$APP/Contents/Frameworks/$helper.app/Contents/MacOS"
  install_file "$BIN/${NAME}Helper" "$APP/Contents/Frameworks/$helper.app/Contents/MacOS/$helper"
  write_plist "$APP/Contents/Frameworks/$helper.app/Contents/Info.plist" "$helper" \
    "$BUNDLE_ID.helper${id_suffix:+.$id_suffix}" "$helper" "<key>LSUIElement</key><true/>"
done

# Ad-hoc signatures, inside out.
codesign --force --sign - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
for helper in "$APP"/Contents/Frameworks/*Helper*.app; do
  codesign --force --sign - "$helper"
done
codesign --force --sign - "$APP"

# Let LaunchServices (and the Dock) pick up the rebuilt bundle and its icon.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP"

echo "Built $APP"
