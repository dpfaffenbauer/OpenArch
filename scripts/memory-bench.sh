#!/usr/bin/env bash
# Measures OpenArch's memory with 20 open tabs, per kind of process.
#
#   scripts/memory-bench.sh [app] [light|sites] [runs]
#
# light: 20 small local pages (what each tab costs the engine itself).
# sites: the 20 sites in scripts/memory-bench-sites.txt (everyday use).
# Each run starts OpenArch with the self-test's own data folder (it runs
# next to an OpenArch in use), waits until every tab has loaded and settled,
# then sums the physical footprint of the app and all its helpers. Prints
# one line per run as TSV: browser, gpu, renderers, other, total (MB).
# BENCH_ARGS: more arguments for the app, e.g. for the Chromium spike
# (spikes/02-chromium): "--openarch-embedder --no-startup-window
# --no-first-run --user-data-dir=<dir>".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(cd "${1:-$ROOT/App/build/OpenArch.app}" && pwd)"
MODE="${2:-light}"
RUNS="${3:-3}"
SETTLE="${SETTLE:-30}"
TABS="${TABS:-20}"
BIN="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"

WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

if [[ "$MODE" == light ]]; then
  mkdir "$WORK/pages"
  for i in $(seq 1 "$TABS"); do
    {
      echo "<!doctype html><title>Page $i</title><h1>Page $i</h1>"
      for p in $(seq 1 40); do echo "<p>Paragraph $p of page $i. Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>"; done
      echo "<script>const show = () => document.title = 'Page $i ' + document.visibilityState; show(); document.addEventListener('visibilitychange', show)</script>"
    } > "$WORK/pages/$i.html"
  done
  PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/pages" >/dev/null 2>&1 &
  for i in $(seq 1 "$TABS"); do echo "http://127.0.0.1:$PORT/$i.html"; done > "$WORK/urls.txt"
else
  grep -v '^#' "$ROOT/scripts/memory-bench-sites.txt" | grep . > "$WORK/urls.txt"
fi

# All processes below |pid|, itself included.
tree() {
  echo "$1"
  for child in $(pgrep -P "$1" || true); do tree "$child"; done
}

mb() { echo $(( $1 / 1048576 )); }

printf "run\tbrowser\tgpu\trenderers\tother\ttotal\tvisible\tloaded\n"
for run in $(seq 1 "$RUNS"); do
  DEVTOOLS=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  # OpenArch reads "--remote-debugging-port <port>", Chromium only
  # "--remote-debugging-port=<port>".
  if [[ -n "${BENCH_ARGS:-}" ]]; then port_args=("--remote-debugging-port=$DEVTOOLS"); else port_args=(--remote-debugging-port "$DEVTOOLS"); fi
  "$BIN" --selftest --memory-bench "$WORK/urls.txt" "${port_args[@]}" ${BENCH_ARGS:-} > "$WORK/log" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 240); do
    grep -q "STEP bench ready" "$WORK/log" && break
    sleep 0.5
  done
  grep -q "STEP bench ready" "$WORK/log" || { echo "OpenArch did not get ready" >&2; tail -20 "$WORK/log" >&2; exit 1; }
  sleep "$SETTLE"

  browser=0 gpu=0 renderers=0 other=0
  for pid in $(tree "$APP_PID"); do
    bytes=$(footprint -f bytes --noCategories -p "$pid" 2>/dev/null | sed -nE 's/.*Footprint: ([0-9]+) B.*/\1/p' | head -1 || true)
    [[ -n "$bytes" ]] || continue
    command=$(ps -o command= -p "$pid" || true)
    case "$command" in
      *--type=renderer*) renderers=$((renderers + bytes)) ;;
      *--type=gpu-process*) gpu=$((gpu + bytes)) ;;
      *--type=*) other=$((other + bytes)) ;;
      *) browser=$((browser + bytes)) ;;
    esac
  done
  total=$((browser + gpu + renderers + other))
  # Asks each tab itself: how many Chromium treats as visible, and how many
  # have loaded their page (not still about:blank). Titles in /json/list are
  # empty in Chromium 156; the spike's tabs are listed as "other".
  visible=0 loaded=0
  for ws in $(curl -s "http://127.0.0.1:$DEVTOOLS/json/list" | python3 -I -c 'import json,sys; [print(t["webSocketDebuggerUrl"]) for t in json.load(sys.stdin) if t["type"] in ("page","other") and t["url"].startswith("http")]'); do
    state=$(python3 -I "$ROOT/scripts/cdp.py" "$ws" Runtime.evaluate '{"expression":"document.visibilityState+\" \"+location.href","returnByValue":true}' 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["result"]["value"])' 2>/dev/null || true)
    [[ -z "${DUMP:-}" ]] || echo "$state" >&2
    [[ "$state" != visible* ]] || visible=$((visible + 1))
    [[ "$state" != *" http"* ]] || loaded=$((loaded + 1))
  done
  printf "%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n" "$run" "$(mb $browser)" "$(mb $gpu)" "$(mb $renderers)" "$(mb $other)" "$(mb $total)" "$visible" "$loaded"

  kill "$APP_PID" 2>/dev/null || true
  for _ in $(seq 1 40); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
  kill -9 "$APP_PID" 2>/dev/null || true
  pkill -9 -f "OpenArch SelfTest" 2>/dev/null || true
  sleep 3
done
