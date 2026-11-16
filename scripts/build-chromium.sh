#!/usr/bin/env bash
# OpenArch's engine: Chrome's own framework with OpenArch's layer
# (docs/chromium-engine.md), from the Chrome stable tag in
# engine/chromium/VERSION.
#
#   scripts/build-chromium.sh [sync|apply|gen|build|all]
#
#   sync   the tag, one commit deep, with its deps, then Chromium's hooks
#          (~1 h and ~35 GB the first time; a new tag fetches only itself)
#   apply  OpenArch's layer and hooks (engine/chromium/apply.sh)
#   gen    out/OpenArch/args.gn: release with H.264/AAC; OFFICIAL=1 for an
#          official build (ThinLTO, PGO; hours longer); GN_ARGS_EXTRA
#          (newline- or space-separated) is added last and wins
#   build  Chromium.app, whose framework OpenArch.app uses
#
# CHROMIUM_DIR (default ~/chromium) holds depot_tools and src. Xcode's
# Metal Toolchain must be installed (xcodebuild -downloadComponent
# MetalToolchain). Never edit this file while it runs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${CHROMIUM_DIR:-$HOME/chromium}"
TAG="${CHROMIUM_TAG:-$(cat "$REPO/engine/chromium/VERSION")}"
OUT="out/OpenArch"
export PATH="$DIR/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

sync() {
  mkdir -p "$DIR"
  if [[ ! -d "$DIR/depot_tools" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DIR/depot_tools"
    "$DIR/depot_tools/ensure_bootstrap"
  fi
  local pgo=False
  [[ -z "${OFFICIAL:-}" ]] || pgo=True
  cat > "$DIR/.gclient" <<EOF
solutions = [{
  "name": "src",
  "url": "https://chromium.googlesource.com/chromium/src.git@refs/tags/$TAG",
  "managed": False,
  "custom_deps": {},
  "custom_vars": { "checkout_pgo_profiles": $pgo },
}]
target_os = ["mac"]
EOF
  if [[ -d "$DIR/src/.git" ]]; then
    # Only the new tag, one commit deep: gclient's --with_tags fetches every
    # Chromium tag into a shallow checkout and never finishes (Cra saw the
    # same, 13 Nov 2026). OpenArch's changes in the tree go first.
    git -C "$DIR/src" checkout -q -- . && git -C "$DIR/src" clean -fdq chrome openarch 2>/dev/null || true
    git -C "$DIR/src" fetch --depth=1 --no-tags origin "+refs/tags/$TAG:refs/tags/$TAG"
    git -C "$DIR/src" -c advice.detachedHead=false checkout -q "$TAG"
    (cd "$DIR" && gclient sync --no-history --nohooks -D -j "${JOBS:-4}" -r "src@$(git -C "$DIR/src" rev-parse HEAD)")
  else
    (cd "$DIR" && gclient sync --no-history --nohooks -j "${JOBS:-4}" -r "src@refs/tags/$TAG")
  fi
  (cd "$DIR" && gclient runhooks)
  echo "$TAG" > "$DIR/.openarch-tag"
}

apply() {
  "$REPO/engine/chromium/apply.sh" "$DIR/src"
}

gen() {
  mkdir -p "$DIR/src/$OUT"
  {
    echo "# Written by OpenArch's scripts/build-chromium.sh."
    echo 'target_cpu = "arm64"'
    echo 'is_debug = false'
    echo 'is_component_build = false'
    echo 'symbol_level = 0'
    echo 'blink_symbol_level = 0'
    echo 'v8_symbol_level = 0'
    echo 'enable_dsyms = false'
    echo 'proprietary_codecs = true'
    echo 'ffmpeg_branding = "Chrome"'
    echo 'disable_fieldtrial_testing_config = true'
    echo 'treat_warnings_as_errors = false'
    if [[ -n "${OFFICIAL:-}" ]]; then
      echo 'is_official_build = true'
    else
      echo 'dcheck_always_on = false'
    fi
    if [[ -n "${GN_ARGS_EXTRA:-}" ]]; then
      echo "${GN_ARGS_EXTRA}"
    fi
  } > "$DIR/src/$OUT/args.gn"
  (cd "$DIR/src" && gn gen "$OUT")
}

build() {
  (cd "$DIR/src" && autoninja -C "$OUT" chrome)
}

case "${1:-all}" in
  sync) sync ;;
  apply) apply ;;
  gen) gen ;;
  build) build ;;
  all) sync; apply; gen; build ;;
  *) echo "usage: $0 [sync|apply|gen|build|all]" >&2; exit 2 ;;
esac
