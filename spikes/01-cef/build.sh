#!/usr/bin/env bash
# Builds build/OpenArchSpike.app: Swift app + CEF framework + helper apps.
set -euo pipefail

SPIKE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SPIKE/../.." && pwd)"
CEF="$ROOT/Vendor/cef"
CONFIG="${CONFIG:-debug}"
NAME="OpenArchSpike"
APP="$SPIKE/build/$NAME.app"
BUNDLE_ID="dev.openarch.spike"

"$ROOT/scripts/fetch-cef.sh"
if [[ ! -f "$CEF/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
  cmake -S "$CEF" -B "$CEF/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=OFF
  cmake --build "$CEF/build" --target libcef_dll_wrapper
fi

swift build --package-path "$SPIKE" -c "$CONFIG"
BIN="$(swift build --package-path "$SPIKE" -c "$CONFIG" --show-bin-path)"

# write_plist <path> <executable> <bundle id> <extra plist entries>
write_plist() {
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  $4
</dict>
</plist>
EOF
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
write_plist "$APP/Contents/Info.plist" "$NAME" "$BUNDLE_ID" \
  "<key>NSPrincipalClass</key><string>OACApplication</string>"
rsync -a --delete "$CEF/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/"
rsync -a --delete "$SPIKE/Resources/Extensions" "$APP/Contents/Resources/"

# Chromium looks up one helper app per process type by name.
for suffix in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
  helper="$NAME Helper$suffix"
  id_suffix="$(printf '%s' "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$APP/Contents/Frameworks/$helper.app/Contents/MacOS"
  cp "$BIN/${NAME}Helper" "$APP/Contents/Frameworks/$helper.app/Contents/MacOS/$helper"
  write_plist "$APP/Contents/Frameworks/$helper.app/Contents/Info.plist" "$helper" \
    "$BUNDLE_ID.helper${id_suffix:+.$id_suffix}" "<key>LSUIElement</key><true/>"
done

# Ad-hoc signatures, inside out.
codesign --force --sign - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
for helper in "$APP"/Contents/Frameworks/*Helper*.app; do
  codesign --force --sign - "$helper"
done
codesign --force --sign - "$APP"

echo "Built $APP"
