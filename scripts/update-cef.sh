#!/usr/bin/env bash
# Moves scripts/fetch-cef.sh to the newest stable CEF build for macOS arm64.
#
# OpenArch uses its own CEF build with the proprietary codecs, so a new CEF
# version takes two steps. The first run that sees it starts
# .github/workflows/cef-codecs.yml for it (about ten hours). A run after that
# build has published the release cef-<version>-codecs moves the pin.
#
# Prints the new version when it moved the pin. In GitHub Actions it also
# sets the outputs "updated", "version" and "previous". Needs gh signed in
# (GH_TOKEN in Actions). Fails when the codecs build for the new version
# failed, so the failure shows up instead of being retried every day.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FETCH="$ROOT/scripts/fetch-cef.sh"
current="$(sed -n 's/^CEF_VERSION="\(.*\)"$/\1/p' "$FETCH")"

version="$(curl -fsSL https://cef-builds.spotifycdn.com/index.json | python3 -c '
import json, sys
platform = json.load(sys.stdin)["macosarm64"]
for build in platform["versions"]:
    if build.get("channel") == "stable" and any(f["type"] == "minimal" for f in build["files"]):
        print(build["cef_version"])
        sys.exit(0)
sys.exit("no stable minimal build found")
')"

output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

if [[ "$version" == "$current" ]]; then
  output "updated=false"
  exit 0
fi

tag="cef-${version%%+*}-codecs"
name="cef_binary_${version}_macosarm64_minimal.tar.bz2"
if sha256="$(gh release download "$tag" --pattern "$name.sha256" --output - 2>/dev/null | awk '{ print $1 }')" \
   && [[ "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  sed -i '' \
    -e "s/^CEF_VERSION=\".*\"$/CEF_VERSION=\"$version\"/" \
    -e "s/^CEF_SHA256=\".*\"$/CEF_SHA256=\"$sha256\"/" "$FETCH"
  output "updated=true"
  output "version=$version"
  output "previous=$current"
  echo "$version"
  exit 0
fi

output "updated=false"
title="CEF $version with codecs"
state="$(gh run list --workflow cef-codecs.yml --limit 20 --json displayTitle,status,conclusion \
  --jq "[.[] | select(.displayTitle == \"$title\")][0] | if . == null then \"none\" elif .status != \"completed\" then \"running\" else .conclusion end")"
case "$state" in
  none)
    gh workflow run cef-codecs.yml -f cef_version="$version"
    echo "CEF $version is out; started its codecs build" >&2 ;;
  running)
    echo "CEF $version: codecs build still running" >&2 ;;
  success)
    echo "CEF $version: codecs build finished but $tag has no $name.sha256" >&2
    exit 1 ;;
  *)
    echo "CEF $version: codecs build ended with \"$state\"; re-run it in Actions" >&2
    exit 1 ;;
esac
