#!/usr/bin/env bash
# Measures the spike build (out/Spike/Chromium.app) the way the baseline was
# measured: first a short check that the embedder's tabs load and that only
# one is visible, then 20 tabs light and sites, 3 runs each, in the embedder
# (one AppKit window, --openarch-embedder) and in Chrome's own window of the
# same build. Run it in a normal terminal with the screen unlocked; a
# locked screen makes every tab hidden. Prints TSV and saves it to
# $CHROMIUM_DIR/measure-<date>.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${CHROMIUM_DIR:-$HOME/chromium}"
APP="$DIR/src/out/Spike/Chromium.app"
RUNS="${RUNS:-3}"
OUT="$DIR/measure-$(date +%Y%m%d-%H%M).txt"
UD="$(mktemp -d)"
trap 'rm -rf "$UD"' EXIT
EMBEDDER="--openarch-embedder --no-startup-window --no-first-run --no-default-browser-check --user-data-dir=$UD/embedder"

{
  echo "# check: 3 tabs in the embedder (want: visible 1, loaded 3)"
  BENCH_ARGS="$EMBEDDER" TABS=3 SETTLE=3 DUMP=1 "$ROOT/scripts/memory-bench.sh" "$APP" light 1 2>&1
  for mode in light sites; do
    echo "# embedder $mode"
    BENCH_ARGS="$EMBEDDER" "$ROOT/scripts/memory-bench.sh" "$APP" "$mode" "$RUNS"
    echo "# chrome window $mode"
    "$(dirname "$0")/chrome-bench.sh" "$APP" "$mode" "$RUNS"
  done
} 2>&1 | tee "$OUT"
echo "saved to $OUT"
