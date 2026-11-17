#!/usr/bin/env bash
# Checks out Chromium at the version under CEF 156.0.15, adds //openarch
# and its two hooks, configures and builds. Each step can be run alone:
#
#   spikes/02-chromium/setup.sh [fetch|hook|gen|build|all]
#
# CHROMIUM_DIR (default ~/chromium): where the checkout goes (~50 GB, plus
# ~30 GB for out/Spike). Without history: the spike needs one version only.
set -euo pipefail

SPIKE="$(cd "$(dirname "$0")" && pwd)"
DIR="${CHROMIUM_DIR:-$HOME/chromium}"
VERSION="${CHROMIUM_VERSION:-156.0.8078.80}"
OUT="out/Spike"
export PATH="$DIR/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fetch() {
  mkdir -p "$DIR"
  cd "$DIR"
  [[ -d depot_tools ]] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
  if [[ ! -d src ]]; then
    cat > .gclient <<EOF
solutions = [{
  "name": "src",
  "url": "https://chromium.googlesource.com/chromium/src.git@refs/tags/$VERSION",
  "managed": False,
  "custom_deps": {},
  "custom_vars": { "checkout_pgo_profiles": False },
}]
EOF
  fi
  gclient sync --no-history --shallow --with_tags --nohooks -r "src@refs/tags/$VERSION" -j 12
  gclient runhooks
}

# Edits Chrome's sources at fixed places and fails if a place is not found,
# so a new Chromium version shows at once what has moved. Running it twice
# changes nothing.
hook() {
  cd "$DIR/src"
  ln -sfn "$SPIKE/openarch" openarch
  python3 -I - <<'EOF'
import pathlib, sys

def edit(path, anchor, insert, after=True):
    p = pathlib.Path(path)
    text = p.read_text()
    if insert in text:
        return
    if text.count(anchor) != 1:
        sys.exit(f"{path}: anchor found {text.count(anchor)} times: {anchor!r}")
    p.write_text(text.replace(anchor, anchor + insert if after else insert + anchor))
    print(f"patched {path}")

# 1. The library inside Chrome's framework (mac chrome_dll) links //openarch.
edit("chrome/BUILD.gn",
     '    ldflags = [ "-ObjC" ]\n\n    configs += [\n      ":chrome_dll_symbol_order",',
     '    deps += [ "//openarch" ]  # OpenArch spike\n\n',
     after=False)

# 2. ChromeBrowserMainParts::Create adds the embedder's main parts, last.
edit("chrome/browser/chrome_browser_main.cc",
     "// static\nstd::unique_ptr<content::BrowserMainParts> ChromeBrowserMainParts::Create(",
     "namespace openarch {  // OpenArch spike\n"
     "std::unique_ptr<ChromeBrowserMainExtraParts> CreateEmbedderParts();\n}\n\n",
     after=False)
edit("chrome/browser/chrome_browser_main.cc",
     "      std::make_unique<ChromeBrowserMainExtraPartsSegmentationPlatform>());\n",
     "  if (auto parts = openarch::CreateEmbedderParts()) {  // OpenArch spike\n"
     "    main_parts->AddParts(std::move(parts));\n  }\n")

# 3. The embedder may attach Chrome's tab helpers, like Chrome's own tabs.
edit("chrome/browser/ui/tab_helpers.h",
     " private:\n",
     "  friend class openarch::Pane;  // OpenArch spike\n")
edit("chrome/browser/ui/tab_helpers.h",
     "class TabHelpers {",
     "namespace openarch {\nclass Pane;\n}\n\n",
     after=False)
EOF
  git -C "$DIR/src" diff --stat
}

gen() {
  cd "$DIR/src"
  # Release, not official: no ThinLTO and PGO, hours shorter. The bench
  # compares this build with itself (Chrome's own window vs the embedder),
  # and with Chrome for Testing (official) to see what official adds.
  gn gen "$OUT" --args='
    is_debug=false
    is_component_build=false
    dcheck_always_on=false
    symbol_level=0
    blink_symbol_level=0
    v8_symbol_level=0
    proprietary_codecs=true
    ffmpeg_branding="Chrome"
    treat_warnings_as_errors=false
    target_cpu="arm64"
  '
}

build() {
  cd "$DIR/src"
  autoninja -C "$OUT" chrome
}

case "${1:-all}" in
  fetch) fetch ;;
  hook) hook ;;
  gen) gen ;;
  build) build ;;
  all) fetch; hook; gen; build ;;
  *) echo "usage: $0 [fetch|hook|gen|build|all]" >&2; exit 2 ;;
esac
