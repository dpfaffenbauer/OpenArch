#!/usr/bin/env bash
# The memory bench of scripts/memory-bench.sh, for a plain Chromium/Chrome
# (no CEF): all tabs in one window. Same pages, same order, each tab shown
# once 1.5 s after the one before, then the first in front, SETTLE seconds,
# footprint summed per kind of process.
#
#   spikes/02-chromium/chrome-bench.sh <Chrome.app> [light|sites] [runs]
#
# DUMP=1 prints each tab's visibility and URL.
set -euo pipefail

ROOT="${OPENARCH_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
APP="$(cd "$1" && pwd)"
MODE="${2:-light}"
RUNS="${3:-3}"
SETTLE="${SETTLE:-30}"
TABS="${TABS:-20}"
WIN="${WIN:-992,784}"
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

tree() { echo "$1"; for c in $(pgrep -P "$1" || true); do tree "$c"; done; }
mb() { echo $(( $1 / 1048576 )); }

printf "run\tbrowser\tgpu\trenderers\tother\ttotal\tvisible\tloaded\tprocs\twindows\n"
for run in $(seq 1 "$RUNS"); do
  DEVTOOLS=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  rm -rf "$WORK/profile"
  # All URLs on the command line: Chrome opens them as tabs of one window
  # (tabs made with /json/new open in new windows when Chrome is not active).
  # shellcheck disable=SC2046
  "$BIN" --user-data-dir="$WORK/profile" --no-first-run --no-default-browser-check \
    --window-size="$WIN" --window-position=40,40 \
    --remote-debugging-port="$DEVTOOLS" ${EXTRA_ARGS:-} $(cat "$WORK/urls.txt") > "$WORK/log" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 120); do curl -sf "http://127.0.0.1:$DEVTOOLS/json/version" >/dev/null && break; sleep 0.5; done
  # Each tab selected once, in order, 1.5 s apart, then the first in front.
  ids=""
  for _ in $(seq 1 60); do
    ids=$(curl -s "http://127.0.0.1:$DEVTOOLS/json/list" | python3 -I -c '
import json, sys
urls = open(sys.argv[1]).read().split()
pages = [t for t in json.load(sys.stdin) if t["type"] == "page"]
by_url = {}
for t in pages:
    by_url.setdefault(t["url"], t["id"])
ids = [by_url.get(u) for u in urls]
print(" ".join(ids) if all(ids) else "")' "$WORK/urls.txt" 2>/dev/null || true)
    [[ -z "$ids" ]] || break
    sleep 0.5
  done
  if [[ -z "$ids" ]]; then
    # Sites redirect, so their URL may differ from the list: take the
    # tabs in the order Chrome lists them.
    ids=$(curl -s "http://127.0.0.1:$DEVTOOLS/json/list" | python3 -I -c 'import json,sys; print(" ".join(t["id"] for t in reversed(json.load(sys.stdin)) if t["type"]=="page"))')
  fi
  for id in $ids; do
    curl -s "http://127.0.0.1:$DEVTOOLS/json/activate/$id" >/dev/null
    sleep 1.5
  done
  curl -s "http://127.0.0.1:$DEVTOOLS/json/activate/${ids%% *}" >/dev/null
  sleep "$SETTLE"

  browser=0 gpu=0 renderers=0 other=0 procs=0
  for pid in $(tree "$APP_PID"); do
    bytes=$(footprint -f bytes --noCategories -p "$pid" 2>/dev/null | sed -nE 's/.*Footprint: ([0-9]+) B.*/\1/p' | head -1 || true)
    [[ -n "$bytes" ]] || continue
    procs=$((procs + 1))
    command=$(ps -o command= -p "$pid" || true)
    case "$command" in
      *--type=renderer*) renderers=$((renderers + bytes))
        [[ -z "${DUMP:-}" ]] || echo "renderer $(mb $bytes) MB $(grep -oE -- '--(extension-process|renderer-client-id=[0-9]+)' <<< "$command" | tr '\n' ' ')" >&2 ;;
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
  browser_ws=$(curl -s "http://127.0.0.1:$DEVTOOLS/json/version" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["webSocketDebuggerUrl"])')
  windows=$(for id in $ids; do python3 -I "$ROOT/scripts/cdp.py" "$browser_ws" Browser.getWindowForTarget "{\"targetId\":\"$id\"}" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["windowId"])' 2>/dev/null; done | sort -u | wc -l | tr -d ' ')
  printf "%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%d\t%s\n" "$run" "$(mb $browser)" "$(mb $gpu)" "$(mb $renderers)" "$(mb $other)" "$(mb $total)" "$visible" "$loaded" "$procs" "$windows"
  [[ -z "${KEEP:-}" ]] || { echo "kept running, pid $APP_PID port $DEVTOOLS"; wait "$APP_PID"; }

  kill "$APP_PID" 2>/dev/null || true
  for _ in $(seq 1 40); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
  kill -9 "$APP_PID" 2>/dev/null || true
  sleep 3
done
