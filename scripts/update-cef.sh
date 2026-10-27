#!/usr/bin/env bash
# Moves scripts/fetch-cef.sh to the newest stable CEF build for macOS arm64.
# Prints the new version, or nothing when the pinned one is current. In
# GitHub Actions it also sets the outputs "updated" and "version".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FETCH="$ROOT/scripts/fetch-cef.sh"
current="$(sed -n 's/^CEF_VERSION="\(.*\)"$/\1/p' "$FETCH")"

read -r version sha1 < <(curl -fsSL https://cef-builds.spotifycdn.com/index.json | python3 -c '
import json, sys
platform = json.load(sys.stdin)["macosarm64"]
for build in platform["versions"]:
    if build.get("channel") != "stable":
        continue
    for file in build["files"]:
        if file["type"] == "minimal":
            print(build["cef_version"], file["sha1"])
            sys.exit(0)
sys.exit("no stable minimal build found")
')

output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

if [[ "$version" == "$current" ]]; then
  output "updated=false"
  exit 0
fi

sed -i '' \
  -e "s/^CEF_VERSION=\".*\"$/CEF_VERSION=\"$version\"/" \
  -e "s/^CEF_SHA1=\".*\"$/CEF_SHA1=\"$sha1\"/" "$FETCH"
output "updated=true"
output "version=$version"
output "previous=$current"
echo "$version"
