#!/bin/bash
# stock_grid_check.sh -- the desktop's Film and Paper grids on the develop page (2.4.1, 2026-11-16;
# Sources/Mac/MacStockGridCheck.swift): the grids' columns and cards and the three heights of the column's Film & Paper
# against the rules they are laid by (Services/StockPreviewGrid.swift), at rest, at a wider column, with a strip dragged
# taller than the room and shorter than a row, on Favourites, at two interface scales; nothing written at rest or at a
# step of a drag; a person's pointer and wheel (Sources/Mac/MacStockGridHandCheck.swift: the grip dragged at three
# interface scales, the maker's name over a row, where a scroll goes), each event posted into the app's own queue
# (Sources/Mac/MacHIDPost.swift; round 4, 2026-11-16: a drag handed to the process from outside never reached a view).
# The app runs in the background: never activated, the real cursor never moved.
# The window is captured at each state into --out/captures.
#
#   tools/stock_grid_check.sh RAW [--out DIR] [--app PATH] [--keep]
#
# SPK_CHECK_ARGS: more of the app's arguments (`--hand-quick` for the watermark check: 100 % alone).
# SPK_SHOW_SCROLL_BARS: Always | WhenScrolling | Automatic — "Show scroll bars" in the copy's own defaults domain
# (`AppleShowScrollBars`), for the check that no native scroll bar is drawn inside a strip under either style.
# The app is a copy with a bundle id of the run's own (tools/check_app.sh) under a scratch home: the owner's library,
# stars and preferences are never read or written. A run that prints nothing new for 300 s is killed and red.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
raw=""; out="$here/build/stock-grid-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    -*) echo "unknown: $1"; exit 2 ;;
    *) raw=$1; shift ;;
  esac
done
[[ -f "$raw" ]] || { echo "usage: tools/stock_grid_check.sh RAW [--out DIR] [--app PATH] [--keep]"; exit 2; }
mkdir -p "$out"; out=$(CDPATH= cd -- "$out" && pwd)
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
source "$here/tools/check_app.sh"; check_app_isolate "$app"
[[ -n "${SPK_SHOW_SCROLL_BARS:-}" ]] && defaults write "$check_bundle_id" AppleShowScrollBars -string "$SPK_SHOW_SCROLL_BARS"
home=$(mktemp -d "${TMPDIR:-/tmp}/stock-grid-home.XXXXXX")
suite="spk.stock-grid.$(basename "$home")"
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
  --library real --defaults-suite "$suite" --stock-grid-check "$out" \
  --export-check-pictures "$raw" --capture-window "$out/captures" --export-check-exit ${SPK_CHECK_ARGS:-} \
  || { echo "stock-grid-check: FAIL the app did not start"; exit 1; }
size=0; quiet=0
while kill -0 "$pid" 2> /dev/null; do
  sleep 1
  now=$(wc -c < "$log")
  if [[ $now -ne $size ]]; then size=$now; quiet=0; else quiet=$((quiet + 1)); fi
  if [[ $quiet -ge 300 ]]; then echo "stock-grid-check: FAIL silent for 300 s: killed"; kill "$pid" 2> /dev/null || true; fi
done
pid=""
code=1; grep -q "^stock-grid-check: PASS" "$log" && code=0
grep "^stock-grid-check:" "$log" || true
grep "^pointer:" "$log" | sort | uniq -c || true
echo "stock-grid-check: ran $(( $(date +%s) - start )) s, exit $code"
exit $code
