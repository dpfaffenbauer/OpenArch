#!/usr/bin/env bash
# Builds OpenArch's engine (docs/chromium-engine.md) on a GitHub-hosted Mac:
# Chrome's framework from the stable tag in engine/chromium/VERSION with
# OpenArch's layer, an official build (ThinLTO, PGO, H.264/AAC). Used by
# .github/workflows/chromium-engine.yml, where one build takes a chain of
# jobs. Each command is one stage:
#
#   check                   is the release for this version and layer there?
#   prepare                 select Xcode, free disk space, Metal Toolchain
#   fetch                   check out Chrome, apply the layer, configure (job 1)
#   restore                 unpack the tree the previous job packed (jobs 2+)
#   build                   run ninja until the job's time is nearly up
#   distrib                 zip Chromium.app, which App/build.sh takes apart
#   save                    pack the tree for the next job
#   publish                 upload the archive to the release
#   drop-artifacts <prefix> delete this run's artifacts named <prefix>...
#
# Settings come from the environment, which the workflow sets:
# CHROMIUM_VERSION (empty: engine/chromium/VERSION), GN_ARGS_EXTRA,
# XCODE_VERSION, JOB_START, BUILD_UNTIL_MINUTE.
# Written for bash 3.2, the bash of the macOS runners.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${CHROMIUM_VERSION:-}" ]]; then
  CHROMIUM_VERSION="$(cat "$ROOT/engine/chromium/VERSION")"
fi
export CHROMIUM_VERSION CHROMIUM_TAG="$CHROMIUM_VERSION"

# The same path in every job: the build files refer to it.
export CHROMIUM_DIR="$HOME/chromium"
SRC="$CHROMIUM_DIR/src"
OUT="$SRC/out/OpenArch"
NINJA="$SRC/third_party/ninja/ninja"
XCODE_APP=/Applications/Xcode-engine.app
STATE_DIR="${RUNNER_TEMP:-/tmp}/engine-state"
DIST_DIR="${RUNNER_TEMP:-/tmp}/engine-distrib"
RELEASE_TAG="$("$ROOT/scripts/fetch-chromium-engine.sh" --tag)"
DIST_NAME="$("$ROOT/scripts/fetch-chromium-engine.sh" --archive)"

# Test data the chrome target never reads; dropped after configuring to
# shrink the tree every job packs and unpacks (see prune).
PRUNE_DIRS="third_party/blink/web_tests chrome/test/data content/test/data"

if [[ -d "$XCODE_APP" ]]; then export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"; fi
export PATH="$CHROMIUM_DIR/depot_tools:$PATH"

output() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

fail() {
  echo "::error::$*" >&2
  exit 1
}

disk() {
  df -h "$HOME" | awk 'NR == 2 { print $4 " free of " $2 }'
}

# On top of build-chromium.sh's release args (OFFICIAL=1): ninja, not siso,
# because only ninja stops cleanly on SIGTERM and carries on in the next
# job; the workflow's input last, so it can override anything.
gn_args() {
  echo "use_siso=false ${GN_ARGS_EXTRA:-}"
}

check() {
  echo "Engine $RELEASE_TAG"
  output "tag=$RELEASE_TAG"
  if gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name' 2> /dev/null |
    grep -qxF "$DIST_NAME"; then
    echo "Already published"
    output "exists=true"
  else
    output "exists=false"
  fi
}

prepare() {
  echo "Disk: $(disk)"
  # Spotlight would index the tens of GB the build writes.
  sudo mdutil -a -i off > /dev/null 2>&1 || true
  select_xcode
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
  # ANGLE compiles Metal shaders; since Xcode 26 the compiler is a download.
  local try
  for try in 1 2 3; do
    if xcodebuild -downloadComponent MetalToolchain; then break; fi
    [[ $try == 3 ]] && fail "Could not download the Metal Toolchain."
    sleep 30
  done
  free_disk
  echo "Disk: $(disk)"
  local free_gb
  free_gb="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
  if (( free_gb < 80 )); then
    echo "::warning::Only $free_gb GB free; the build tree grows to roughly 60-70 GB."
  fi
}

# Keeps one Xcode, always at $XCODE_APP: compile commands contain the SDK
# path, and a different path in a later job would make ninja rebuild all.
select_xcode() {
  local want="" keep app
  if [[ -n "${XCODE_VERSION:-}" ]]; then want="/Applications/Xcode_${XCODE_VERSION}.app"; fi
  if [[ -z "$want" || ! -d "$want" ]]; then
    [[ -z "$want" ]] || echo "::warning::Xcode $XCODE_VERSION is not on this image, using the default."
    want="$(dirname "$(dirname "$(xcode-select -p)")")"
  fi
  keep="$(cd "$want" && pwd -P)"
  for app in /Applications/Xcode*.app; do
    if [[ -L "$app" ]]; then
      sudo rm -f "$app"
    elif [[ "$app" != "$keep" ]]; then
      echo "Deleting $app"
      sudo rm -rf "$app"
    fi
  done
  if [[ "$keep" != "$XCODE_APP" ]]; then sudo mv "$keep" "$XCODE_APP"; fi
  sudo xcode-select --switch "$XCODE_APP"
  xcodebuild -version
}

# Simulators, the Android and .NET SDKs and other tool caches: tens of GB
# Chromium does not need. Best effort; a failure here only costs space.
free_disk() {
  local tool
  xcrun simctl delete all > /dev/null 2>&1 || true
  sudo xcrun simctl runtime delete all > /dev/null 2>&1 || true
  sudo rm -rf "${ANDROID_HOME:-$HOME/Library/Android/sdk}" "$HOME/.dotnet"
  # Keeps Python, which actions/setup-python installs there.
  for tool in "${RUNNER_TOOL_CACHE:-$HOME/hostedtoolcache}"/*; do
    if [[ "$(basename "$tool")" != Python ]]; then sudo rm -rf "$tool"; fi
  done
}

fetch() {
  echo "Chrome $CHROMIUM_VERSION, release $RELEASE_TAG"
  # The tag, one commit deep, its deps and the PGO profiles; the layer;
  # args.gn and gn gen.
  OFFICIAL=1 JOBS=8 "$ROOT/scripts/build-chromium.sh" sync
  "$ROOT/scripts/build-chromium.sh" apply
  OFFICIAL=1 GN_ARGS_EXTRA="$(gn_args)" "$ROOT/scripts/build-chromium.sh" gen
  cat "$OUT/args.gn"
  grep -q 'is_official_build = true' "$OUT/args.gn" || fail "args.gn is not an official build."
  [[ -f "$OUT/build.ninja" ]] || fail "gn wrote no build.ninja (siso instead of ninja?)."
  prune
  echo "Disk: $(disk)"
}

# Moves PRUNE_DIRS out of the tree unless gn read files from them, then lets
# ninja check (dry run) that the build needs nothing that went with them.
# If it does, everything is put back.
prune() {
  local trash="$CHROMIUM_DIR/pruned" dir
  mkdir -p "$trash"
  for dir in $PRUNE_DIRS; do
    [[ -d "$SRC/$dir" ]] || continue
    if grep -qF " ../../$dir/" "$OUT/build.ninja.d"; then
      echo "Keeping $dir: gn reads files from it"
      continue
    fi
    mkdir -p "$trash/$(dirname "$dir")"
    mv "$SRC/$dir" "$trash/$dir"
  done
  if "$NINJA" -C "$OUT" -n chrome > /dev/null; then
    rm -rf "$trash"
    return
  fi
  echo "::warning::The build needs files from $PRUNE_DIRS; keeping them."
  for dir in $PRUNE_DIRS; do
    if [[ -d "$trash/$dir" ]]; then mv "$trash/$dir" "$SRC/$dir"; fi
  done
  rm -rf "$trash"
}

# Builds chrome (Chromium.app) until BUILD_UNTIL_MINUTE minutes after
# JOB_START. Sets the step output "status" to "finished", or to "running"
# when the next job has to carry on.
build() {
  export DEPOT_TOOLS_UPDATE=0
  local stop budget stopped="${RUNNER_TEMP:-/tmp}/ninja-stopped" ninja_pid watchdog rc=0
  stop=$(( ${JOB_START:?JOB_START is required} + ${BUILD_UNTIL_MINUTE:-300} * 60 ))
  budget=$(( stop - $(date +%s) ))
  rm -f "$stopped"
  if (( budget < 600 )); then
    echo "Less than 10 minutes left, leaving the build to the next job"
    output status=running
    return
  fi
  echo "Building for at most $(( budget / 60 )) minutes. Disk: $(disk)"

  # Ninja is resumable by design: on SIGTERM it stops the compilers, deletes
  # their half-written outputs and exits, and the next job's ninja redoes
  # only those steps. A watchdog sends that signal when the time is up.
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$(sysctl -n hw.ncpu)" chrome &
  ninja_pid=$!
  (
    sleep "$budget"
    kill -0 "$ninja_pid" || exit 0
    touch "$stopped"
    kill -TERM "$ninja_pid"
    # Ninja exits within seconds; this is only the backstop.
    sleep 600
    kill -KILL "$ninja_pid"
  ) 2> /dev/null &
  watchdog=$!
  wait "$ninja_pid" || rc=$?
  kill "$watchdog" 2> /dev/null || true
  wait "$watchdog" 2> /dev/null || true

  echo "Disk: $(disk)"
  if [[ -f "$stopped" ]]; then
    output status=running
  elif (( rc == 0 )); then
    output status=finished
  else
    fail "ninja failed with exit code $rc."
  fi
}

# Zips Chromium.app (the framework with its helpers, the .lproj folders
# App/build.sh copies) into DIST_DIR, with its SHA-256.
distrib() {
  local app="$OUT/Chromium.app"
  [[ -d "$app/Contents/Frameworks/Chromium Framework.framework" ]] || fail "No $app with its framework."
  # The layer's entry point must be exported, or OpenArch.app cannot start.
  nm -gU "$app/Contents/Frameworks/Chromium Framework.framework/Chromium Framework" |
    grep -q ' _OpenArchEngineMain$' || fail "The framework does not export OpenArchEngineMain."
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"
  ditto -c -k --keepParent "$app" "$DIST_DIR/$DIST_NAME"
  (cd "$DIST_DIR" && shasum -a 256 "$DIST_NAME" > "$DIST_NAME.sha256")
  cat "$DIST_DIR/$DIST_NAME.sha256"
  ls -lh "$DIST_DIR"
}

# Packs the checkout into 1 GB parts in STATE_DIR. Each file is deleted as
# soon as it is packed, so the tree and its archive never need the disk at
# once.
save() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  gtar -C "$(dirname "$CHROMIUM_DIR")" --remove-files -cf - "$(basename "$CHROMIUM_DIR")" |
    zstd -q -T0 -10 --long=27 |
    split -b 1024m - "$STATE_DIR/engine.tar.zst.part-"
  (cd "$STATE_DIR" && shasum -a 256 engine.tar.zst.part-* > SHA256SUMS)
  du -sh "$STATE_DIR"
}

# Unpacks what save packed. Each part is deleted once it has been read.
restore() {
  local part
  (cd "$STATE_DIR" && shasum -a 256 -c SHA256SUMS)
  for part in "$STATE_DIR"/engine.tar.zst.part-*; do
    cat "$part"
    rm "$part"
  done | zstd -d -q --long=27 | gtar -C "$(dirname "$CHROMIUM_DIR")" -xf -
  [[ -f "$OUT/build.ninja" ]] || fail "The unpacked tree has no $OUT."
  echo "Disk: $(disk)"
}

# Creates the release (or replaces its files) with the archive and its
# SHA-256, under the tag and name fetch-chromium-engine.sh looks for.
publish() {
  local file="$DIST_DIR/$DIST_NAME" notes
  (cd "$DIST_DIR" && shasum -a 256 -c "$DIST_NAME.sha256")
  notes="OpenArch's engine: Chrome $CHROMIUM_VERSION's framework with OpenArch's layer (docs/chromium-engine.md), macOS arm64, official build with H.264/AAC. Taken by scripts/fetch-chromium-engine.sh.

Built from $GITHUB_SHA by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  if gh release view "$RELEASE_TAG" > /dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" "$file" "$file.sha256" --clobber
  else
    # Not "latest" (releases/latest/download/OpenArch.zip) and a
    # pre-release: no one should take it for an OpenArch release.
    gh release create "$RELEASE_TAG" "$file" "$file.sha256" --target "$GITHUB_SHA" \
      --latest=false --prerelease --title "Engine: Chrome $CHROMIUM_VERSION ($RELEASE_TAG)" --notes "$notes"
  fi
  gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name' |
    grep -qxF "$DIST_NAME" || fail "The release has no asset named $DIST_NAME."
  echo "Published $RELEASE_TAG"
}

# Deletes this workflow run's artifacts whose name starts with $1.
drop_artifacts() {
  local prefix="${1:?usage: chromium-engine-ci.sh drop-artifacts <name prefix>}" id
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" \
    --jq ".artifacts[] | select(.name | startswith(\"$prefix\")) | .id" |
    while read -r id; do
      gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id"
      echo "Deleted artifact $id"
    done
}

case "${1:-}" in
  check) check ;;
  prepare) prepare ;;
  fetch) fetch ;;
  restore) restore ;;
  build) build ;;
  distrib) distrib ;;
  save) save ;;
  publish) publish ;;
  drop-artifacts) drop_artifacts "${2:-}" ;;
  *)
    echo "usage: $0 check|prepare|fetch|restore|build|distrib|save|publish|drop-artifacts <prefix>" >&2
    exit 2
    ;;
esac
