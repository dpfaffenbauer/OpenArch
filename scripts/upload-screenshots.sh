#!/usr/bin/env bash
# Uploads the iOS app's App Store screenshots (made with scripts/app-preview.py
# shots, see docs/app-store.md) to the version being prepared in App Store
# Connect, in place of what is there. Submits nothing.
#
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/upload-screenshots.sh
#
# Needs an App Store Connect API key with at least the App Manager role. The
# key is read from ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8, or from
# ASC_KEY_PATH. The version is MARKETING_VERSION unless APP_VERSION is set.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
: "${ASC_KEY_ID:?set ASC_KEY_ID to the ID of the API key}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the issuer ID shown above the team keys}"
key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
version="${APP_VERSION:-$(grep -m1 -oE 'MARKETING_VERSION = [^;]+' "$root/iOS/OpenArch.xcodeproj/project.pbxproj" | cut -d' ' -f3)}"
shots="$root/build/app-store/screenshots"
[ -f "$key" ] || { echo "No API key at $key" >&2; exit 1; }

# The slots App Store Connect asks for, by folder: iPhone 6.3" (1206x2622) and iPad 13" (2064x2752).
devices=(iphone-6.3 ipad)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/screenshots/de-DE"
# One folder per language; deliver tells the devices apart by size and keeps the order of the names.
for device in "${devices[@]}"; do
  ls "$shots/$device"/*.png > /dev/null
  for file in "$shots/$device"/*.png; do
    cp "$file" "$work/screenshots/de-DE/$device-$(basename "$file")"
  done
done

# deliver's key file has to carry the key itself, so it exists only in the temporary folder.
python3 -I - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$key" "$work/api_key.json" <<'PY'
import json, os, sys
key_id, issuer_id, path, out = sys.argv[1:]
with open(path) as file:
    key = file.read()
with os.fdopen(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
    json.dump({"key_id": key_id, "issuer_id": issuer_id, "key": key}, file)
PY

echo "Uploading $(ls "$work/screenshots/de-DE" | wc -l | tr -d ' ') screenshots to version $version"
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 fastlane deliver \
  --api_key_path "$work/api_key.json" \
  --app_identifier at.pfaffenbauer.openarch --platform ios --app_version "$version" \
  --screenshots_path "$work/screenshots" --overwrite_screenshots true \
  --skip_binary_upload true --skip_metadata true --skip_app_version_update true \
  --submit_for_review false --run_precheck_before_submit false --force true
