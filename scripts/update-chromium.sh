#!/usr/bin/env bash
# Moves engine/chromium/VERSION to the newest stable Chrome for Mac.
#
# OpenArch's engine is its own build of Chrome (docs/chromium-engine.md), so
# a new Chrome takes two steps. The first run that sees it starts
# .github/workflows/chromium-engine.yml for it (two to three days). A run after that build has published its release
# (scripts/fetch-chromium-engine.sh --tag) moves the pin.
#
# Prints the new version when it moved the pin. In GitHub Actions it also
# sets the outputs "updated", "version" and "previous". Needs gh signed in
# (GH_TOKEN in Actions). Fails when the engine build for the new version
# failed (often: a hook of engine/chromium/apply.sh no longer finds its place
# in Chrome's code), so that shows up instead of being retried every day.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/engine/chromium/VERSION"
current="$(cat "$PIN")"

version="$(curl -fsSL "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1" |
  python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["version"])')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Odd version: $version" >&2; exit 1; }

output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

# Only forward: Chrome's dashboard can list an older build for a while
# (a respin on another branch).
newer="$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)"
if [[ "$version" == "$current" || "$newer" != "$version" ]]; then
  output "updated=false"
  exit 0
fi

tag="$(CHROMIUM_VERSION="$version" "$ROOT/scripts/fetch-chromium-engine.sh" --tag)"
name="$(CHROMIUM_VERSION="$version" "$ROOT/scripts/fetch-chromium-engine.sh" --archive)"
if gh release view "$tag" --json assets --jq '.assets[].name' 2> /dev/null | grep -qxF "$name"; then
  echo "$version" > "$PIN"
  output "updated=true"
  output "version=$version"
  output "previous=$current"
  echo "$version"
  exit 0
fi

output "updated=false"
title="Chromium engine $version (main)"
state="$(gh run list --workflow chromium-engine.yml --limit 20 --json displayTitle,status,conclusion \
  --jq "[.[] | select(.displayTitle == \"$title\")][0] | if . == null then \"none\" elif .status != \"completed\" then \"running\" else .conclusion end")"
case "$state" in
  none)
    gh workflow run chromium-engine.yml --ref main -f chromium_version="$version"
    echo "Chrome $version is out; started its engine build" >&2 ;;
  running)
    echo "Chrome $version: engine build still running" >&2 ;;
  success)
    # Built and published under another key (main changed the layer since):
    # the next build for the current layer.
    gh workflow run chromium-engine.yml --ref main -f chromium_version="$version"
    echo "Chrome $version: no release $tag; started a build for the current layer" >&2 ;;
  *)
    echo "Chrome $version: engine build ended with \"$state\"; fix engine/chromium for it and re-run" >&2
    exit 1 ;;
esac
