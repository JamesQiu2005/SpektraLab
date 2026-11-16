#!/bin/bash
# watermark_canvas_check.sh -- 水印 on the develop page's canvas (the owner's hand test of 2.4.1, 2026-11-16;
# Sources/Mac/Layers/MacWatermarkCanvasCheck.swift): a 底片 mark picked and at rest, dragged (no mark left at its old place
# on the page's picture while it moves), lifted; a fill colour on the page and in the develop; a 成片 mark on a film edge's
# rebate; a person's mouse on the canvas (Sources/Mac/Layers/MacWatermarkHandCheck.swift: the turn by the dot and from
# outside a corner, a move, a size, at three interface scales and zoomed), each event posted into the app's own queue
# (Sources/Mac/MacHIDPost.swift). The app runs in the background: never activated, the real cursor never moved. The window is captured at each state into --out/captures.
#
#   tools/watermark_canvas_check.sh RAW [--out DIR] [--app PATH] [--keep]
#
# SPK_CHECK_ARGS: more of the app's arguments (`--hand-quick` for the watermark check: 100 % alone).
# The app is a copy with a bundle id of the run's own (tools/check_app.sh) under a scratch home: the owner's library,
# marks and preferences are never read or written. A run that prints nothing new for 300 s is killed and red.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
raw=""; out="$here/build/watermark-canvas-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    -*) echo "unknown: $1"; exit 2 ;;
    *) raw=$1; shift ;;
  esac
done
[[ -f "$raw" ]] || { echo "usage: tools/watermark_canvas_check.sh RAW [--out DIR] [--app PATH] [--keep]"; exit 2; }
mkdir -p "$out"; out=$(CDPATH= cd -- "$out" && pwd)
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
source "$here/tools/check_app.sh"; check_app_isolate "$app"
home=$(mktemp -d "${TMPDIR:-/tmp}/watermark-canvas-home.XXXXXX")
suite="spk.watermark-canvas.$(basename "$home")"
pid=""
cleanup() {
  [[ -n "$pid" ]] && kill "$pid" 2> /dev/null || true
  defaults delete "$suite" > /dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$suite.plist"
  if [[ $keep -eq 1 ]]; then echo "home kept: $home"; else rm -rf "$home"; fi
  check_app_cleanup
}
trap cleanup EXIT INT TERM
log="$out/run.log"
rm -rf "$out/captures"
start=$(date +%s)
# In the background (check_app.sh): never activated, the real cursor never moved — the pointer and the wheel are
# posted inside the app (Sources/Mac/MacHIDPost.swift).
check_app_open_background "$log" "CFFIXED_USER_HOME=$home" -- \
  --library real --defaults-suite "$suite" --watermark-canvas-check "$out" \
  --export-check-pictures "$raw" --capture-window "$out/captures" --export-check-exit ${SPK_CHECK_ARGS:-} \
  || { echo "watermark-canvas-check: FAIL the app did not start"; exit 1; }
size=0; quiet=0
while kill -0 "$pid" 2> /dev/null; do
  sleep 1
  now=$(wc -c < "$log")
  if [[ $now -ne $size ]]; then size=$now; quiet=0; else quiet=$((quiet + 1)); fi
  if [[ $quiet -ge 300 ]]; then echo "watermark-canvas-check: FAIL silent for 300 s: killed"; kill "$pid" 2> /dev/null || true; fi
done
pid=""
code=1; grep -q "^watermark-canvas-check: PASS" "$log" && code=0
grep "^watermark-canvas-check:" "$log" || true
grep "^pointer:" "$log" | sort | uniq -c || true
echo "watermark-canvas-check: ran $(( $(date +%s) - start )) s, exit $code"
exit $code
