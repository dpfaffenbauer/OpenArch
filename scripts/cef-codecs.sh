#!/usr/bin/env bash
# Builds the CEF minimal binary distribution for macOS arm64 from source, with
# the proprietary codecs (H.264, AAC, HEVC) the official builds leave out.
# Used by .github/workflows/cef-codecs.yml, where one build takes a chain of
# jobs. Each command is one stage of such a job:
#
#   prepare                 select Xcode, free disk space on the runner
#   fetch                   check out CEF and Chromium, patch, configure (job 1)
#   restore                 unpack the tree the previous job packed (jobs 2+)
#   build                   run ninja until the job's time is nearly up
#   distrib                 make cef_binary_<version>_macosarm64_minimal.tar.bz2
#   save                    pack the tree for the next job
#   publish                 upload the distribution to the release
#   drop-artifacts <prefix> delete this run's artifacts named <prefix>...
#
# Settings come from the environment, which the workflow sets: CEF_VERSION
# (required), CEF_BRANCH and CEF_COMMIT (read from CEF_VERSION when empty),
# GN_DEFINES_EXTRA, CEF_PGO, XCODE_VERSION, JOB_START, BUILD_UNTIL_MINUTE.
# Written for bash 3.2, the bash of the macOS runners.
set -euo pipefail

CEF_VERSION="${CEF_VERSION:?CEF_VERSION is required}"
SHORT_VERSION="${CEF_VERSION%%+*}"                 # 156.0.14
CHROMIUM_VERSION="${CEF_VERSION##*+chromium-}"     # 156.0.8078.48
# CEF names its release branches after Chromium's build number (8078) ...
CEF_BRANCH="${CEF_BRANCH:-$(echo "$CHROMIUM_VERSION" | cut -d. -f3)}"
# ... and its versions after the commit ("+g4fa4ab5+").
commit="${CEF_VERSION#*+g}"
CEF_COMMIT="${CEF_COMMIT:-${commit%%+*}}"

# The same path in every job: the build files refer to it.
WORK="$HOME/cef"
SRC="$WORK/chromium/src"
OUT="$SRC/out/Release_GN_arm64"
NINJA="$SRC/third_party/ninja/ninja"
XCODE_APP=/Applications/Xcode-cef.app
STATE_DIR="${RUNNER_TEMP:-/tmp}/cef-state"
DIST_DIR="${RUNNER_TEMP:-/tmp}/cef-distrib"
DIST_NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
RELEASE_TAG="cef-${SHORT_VERSION}-codecs"

# Test data CEF never builds; dropped after configuring to shrink the tree
# every job packs and unpacks (see prune).
PRUNE_DIRS="third_party/blink/web_tests chrome/test/data content/test/data"

export PATH="$WORK/depot_tools:$PATH"

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

# The GN args of the build. CEF adds what it requires itself (gn_args.py:
# is_component_build=false, enable_widevine and so on); these are on top.
gn_defines() {
  local defines="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome"
  defines="$defines symbol_level=0"
  # A newer macOS SDK than Chromium was tested with must not stop the build
  # on a deprecation warning.
  defines="$defines treat_warnings_as_errors=false"
  # Official builds use PGO profiles; without them they must be turned off.
  if [[ "${CEF_PGO:-true}" != true ]]; then defines="$defines chrome_pgo_phase=0"; fi
  # Later values win, so the workflow input can override any of the above.
  echo "$defines ${GN_DEFINES_EXTRA:-}"
}

prepare() {
  echo "Disk: $(disk)"
  # Spotlight would index the tens of GB the build writes.
  sudo mdutil -a -i off > /dev/null 2>&1 || true
  select_xcode
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
  local want="/Applications/Xcode_${XCODE_VERSION:-}.app" keep app
  if [[ -z "${XCODE_VERSION:-}" || ! -d "$want" ]]; then
    want="$(dirname "$(dirname "$(xcode-select -p)")")"
    echo "::warning::Xcode ${XCODE_VERSION:-} is not on this image, using $want."
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
  sudo mv "$keep" "$XCODE_APP"
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
  echo "CEF $CEF_VERSION: branch $CEF_BRANCH, commit $CEF_COMMIT"
  mkdir -p "$WORK"
  curl -fsSL -o "$WORK/automate-git.py" \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_BRANCH/tools/automate/automate-git.py"

  local pgo=""
  if [[ "${CEF_PGO:-true}" == true ]]; then pgo="--with-pgo-profiles"; fi
  # CEF's own checkout tool: depot_tools, CEF at the commit, the Chromium
  # version CEF names in CHROMIUM_BUILD_COMPATIBILITY.txt (without git
  # history, which saves tens of GB) and Chromium's hooks (clang, rust ...).
  # It would also build, but cannot stop and resume, so that is done below.
  python3 "$WORK/automate-git.py" --download-dir="$WORK" \
    --depot-tools-dir="$WORK/depot_tools" --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" --no-chromium-history $pgo \
    --arm64-build --no-debug-build --no-build --no-distrib
  # automate-git.py works on its own clone; src/cef is a copy of it.
  rm -rf "$WORK/cef"

  # The version is computed from git, as make_distrib.py will do; it names
  # the archive, so a mismatch is better found now than in two days.
  local actual
  actual="$(python3 "$SRC/cef/tools/cef_version.py" current)"
  [[ "$actual" == "$CEF_VERSION" ]] || fail "The checkout is CEF $actual, not $CEF_VERSION."

  # What automate-git.py does before it builds: translate CEF's API files,
  # apply CEF's patches to Chromium, write args.gn and run gn gen. Only the
  # Release arm64 configuration.
  (cd "$SRC/cef" && GN_DEFINES="$(gn_defines)" GN_OUT_CONFIGS=Release_GN_arm64 \
    CEF_ENABLE_ARM64=1 python3 tools/gclient_hook.py)
  cat "$OUT/args.gn"
  grep -qx 'proprietary_codecs=true' "$OUT/args.gn" || fail "args.gn lacks proprietary_codecs=true."

  prune
  echo "Disk: $(disk)"
}

# Moves PRUNE_DIRS out of the tree unless gn read files from them, then lets
# ninja check (dry run) that the build needs nothing that went with them.
# If it does, everything is put back.
prune() {
  local trash="$WORK/pruned" dir
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
  if "$NINJA" -C "$OUT" -n cefclient > /dev/null; then
    rm -rf "$trash"
    return
  fi
  echo "::warning::The build needs files from $PRUNE_DIRS; keeping them."
  for dir in $PRUNE_DIRS; do
    if [[ -d "$trash/$dir" ]]; then mv "$trash/$dir" "$SRC/$dir"; fi
  done
  rm -rf "$trash"
}

# Builds cefclient, which make_distrib.py takes the framework from, until
# BUILD_UNTIL_MINUTE minutes after JOB_START. Sets the step output "status"
# to "finished", or to "running" when the next job has to carry on.
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
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$(sysctl -n hw.ncpu)" cefclient &
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

# Makes the minimal distribution, the same kind scripts/fetch-cef.sh fetches
# from the Spotify CDN, and puts it with its SHA-256 into DIST_DIR.
distrib() {
  export DEPOT_TOOLS_UPDATE=0
  local out="$WORK/distrib"
  rm -rf "$out" "$DIST_DIR"
  mkdir -p "$out" "$DIST_DIR"
  (cd "$SRC/cef/tools" && CEF_ARCHIVE_FORMAT=tar.bz2 python3 make_distrib.py \
    --output-dir="$out" --ninja-build --arm64-build --minimal --no-symbols --no-docs)
  [[ -f "$out/$DIST_NAME.tar.bz2" ]] || fail "Expected $DIST_NAME.tar.bz2, got: $(ls "$out")"
  mv "$out/$DIST_NAME.tar.bz2" "$DIST_DIR/"
  (cd "$DIST_DIR" && shasum -a 256 "$DIST_NAME.tar.bz2" > "$DIST_NAME.tar.bz2.sha256")
  cat "$DIST_DIR/$DIST_NAME.tar.bz2.sha256"
  ls -lh "$DIST_DIR"
}

# Packs WORK into 1 GB parts in STATE_DIR. Each file is deleted as soon as it
# is packed, so the tree and its archive never need the disk at once.
save() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  gtar -C "$(dirname "$WORK")" --remove-files -cf - "$(basename "$WORK")" |
    zstd -q -T0 -10 --long=27 |
    split -b 1024m - "$STATE_DIR/cef.tar.zst.part-"
  (cd "$STATE_DIR" && shasum -a 256 cef.tar.zst.part-* > SHA256SUMS)
  du -sh "$STATE_DIR"
}

# Unpacks what save packed. Each part is deleted once it has been read.
restore() {
  local part
  (cd "$STATE_DIR" && shasum -a 256 -c SHA256SUMS)
  for part in "$STATE_DIR"/cef.tar.zst.part-*; do
    cat "$part"
    rm "$part"
  done | zstd -d -q --long=27 | gtar -C "$(dirname "$WORK")" -xf -
  [[ -d "$OUT" ]] || fail "The unpacked tree has no $OUT."
  echo "Disk: $(disk)"
}

# Creates the release (or replaces its files) with the archive and its
# SHA-256, under the file name fetch-cef.sh builds from CEF_VERSION.
publish() {
  local file="$DIST_DIR/$DIST_NAME.tar.bz2" notes
  (cd "$DIST_DIR" && shasum -a 256 -c "$DIST_NAME.tar.bz2.sha256")
  notes="CEF $CEF_VERSION, minimal distribution for macOS arm64, built from source with the proprietary codecs (H.264, AAC, HEVC) that the official builds leave out.

GN_DEFINES: $(gn_defines)

Built by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  if gh release view "$RELEASE_TAG" > /dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" "$file" "$file.sha256" --clobber
  else
    # Not "latest": releases/latest/download/OpenArch.zip must keep pointing
    # to the newest OpenArch release.
    gh release create "$RELEASE_TAG" "$file" "$file.sha256" --target "$GITHUB_SHA" \
      --latest=false --title "CEF $SHORT_VERSION with proprietary codecs" --notes "$notes"
  fi
  # GitHub renames some characters in asset names; "+" must survive.
  gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name' |
    grep -qxF "$DIST_NAME.tar.bz2" || fail "The release has no asset named $DIST_NAME.tar.bz2."
  echo "Published $RELEASE_TAG"
}

# Deletes this workflow run's artifacts whose name starts with $1.
drop_artifacts() {
  local prefix="${1:?usage: cef-codecs.sh drop-artifacts <name prefix>}" id
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" \
    --jq ".artifacts[] | select(.name | startswith(\"$prefix\")) | .id" |
    while read -r id; do
      gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id"
      echo "Deleted artifact $id"
    done
}

case "${1:-}" in
  prepare) prepare ;;
  fetch) fetch ;;
  restore) restore ;;
  build) build ;;
  distrib) distrib ;;
  save) save ;;
  publish) publish ;;
  drop-artifacts) drop_artifacts "${2:-}" ;;
  *)
    echo "usage: $0 prepare|fetch|restore|build|distrib|save|publish|drop-artifacts <prefix>" >&2
    exit 2
    ;;
esac
