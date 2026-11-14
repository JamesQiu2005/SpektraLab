#!/bin/bash
# history_check.sh -- a frame's edit history in the running app, across a page's switch and across a relaunch
# (Sources/Mac/History/MacHistoryCheck.swift, PRD-F §7.1 and §7.5).
#
# The Debug app is launched ten times under one scratch home (CFFIXED_USER_HOME: its library, its previews and its
# EditHistory/history.sqlite are the scratch's, never the person's) and one UserDefaults suite of its own
# (`--defaults-suite`, deleted at the end: AGENTS.md trap 24). The fixtures are copied into the home first (a
# develop writes a sidecar). The first run edits and quits; the second relaunches and walks the history back.
#
#   tools/history_check.sh [--out DIR] [--app PATH] [--keep]
#
# Exit 0 when both runs pass. Both take about 6 s together on an M3 Max (measured 2026-11-13); every check is
# counted in each report.json, and a run that stops at "twelve photographs imported" never made its frames (read
# run1.log). `--keep` leaves the scratch home for a look.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/history-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
# A copy with a bundle identifier of this run's own: the build's preferences are never reachable (tools/check_app.sh).
source "$here/tools/check_app.sh"; check_app_isolate "$app"
home=$(mktemp -d "${TMPDIR:-/tmp}/history-check-home.XXXXXX")
suite="spk.history-check.$(basename "$home")"
rm -rf "$out"; mkdir -p "$out/run1" "$out/run2" "$home/in"
# Twelve photographs from three pictures of the tree's own: A, B (the switch), C, D (a pair), E, F (a double),
# G to K (a paste), L (the paste's source).
pics=("$here/SampleSources/scene_raw_srgb.jpg" "$here/SampleSources/overscan/plain_bund.jpg" "$here/SampleSources/overscan/plain_street.jpg")
n=0
for name in A B C D E F G H I J K L; do
  cp "${pics[$((n % 3))]}" "$home/in/$name-$(basename "${pics[$((n % 3))]}")"
  n=$((n + 1))
done
start=$(date +%s)
set +e
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --import "$home/in" \
  --history-check "$out/run1" --history-check-exit > "$out/run1.log" 2>&1
s1=$?
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" \
  --history-check "$out/run2" --history-check-relaunch "$out/run1" --history-check-exit > "$out/run2.log" 2>&1
s2=$?
# The 编辑历史 page and the paths that record a step (MacHistoryPageCheck.swift, PRD-F §4, §7.6), on what the relaunch
# left; the page captured from the window as it stands, in English and 简体中文, into $out/captures.
mkdir -p "$out/page" "$out/captures"
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --capture-window "$out/captures" \
  --history-check "$out/page" --history-check-relaunch "$out/run1" --history-check-page --history-check-exit > "$out/page.log" 2>&1
sp=$?
# Quits (MacHistoryCheck.quit): ⌘Q's terminate: with forty steps in flight, with nothing pending, and with the store
# stuck; each relaunched after. The time from terminate: to the process gone is the quit's own.
quitrun() {
  local kind=$1
  mkdir -p "$out/quit-$kind" "$out/after-$kind"
  CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" \
    --history-check "$out/quit-$kind" --history-check-relaunch "$out/run1" --history-check-quit "$kind" > "$out/quit-$kind.log" 2>&1
  local code=$?
  local gone; gone=$(python3 -c 'import time; print(time.time())')
  local took; took=$(python3 -c "import json; print(round(($gone - json.load(open('$out/quit-$kind/quit.json'))['terminate_at']) * 1000))" 2>/dev/null || echo "?")
  echo "history-check: Q: quit ($kind): exit $code, $took ms from terminate: to the process gone"
  CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" \
    --history-check "$out/after-$kind" --history-check-relaunch "$out/quit-$kind" --history-check-afterquit --history-check-exit > "$out/after-$kind.log" 2>&1
  local after=$?
  [[ $code -eq 0 && $after -eq 0 ]]
}
quitrun steps; sq1=$?
quitrun clean; sq2=$?
quitrun stuck; sq3=$?
# A newer build's store (PRD-F §3.5): its schema number past this build's, written by the system's sqlite3. The third
# run must open and undo in memory and leave the file as it is.
db="$home/Library/Application Support/$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)/EditHistory/history.sqlite"
sqlite3 "$db" "PRAGMA user_version = 99; PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null
mkdir -p "$out/run3"
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" \
  --history-check "$out/run3" --history-check-relaunch "$out/run1" --history-check-newer --history-check-exit > "$out/run3.log" 2>&1
s3=$?
set -e
echo "ran $(( $(date +%s) - start )) s, run 1 exit $s1, run 2 exit $s2, the page exit $sp, quits $sq1 $sq2 $sq3, run 3 (a newer store) exit $s3"
grep -h "^history-check:" "$out/run1.log" "$out/run2.log" "$out/page.log" "$out"/quit-*.log "$out"/after-*.log "$out/run3.log" || true
defaults delete "$suite" > /dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$suite.plist"
if [[ $keep -eq 1 ]]; then echo "home kept: $home"; else rm -rf "$home"; fi
[[ $s1 -eq 0 && $s2 -eq 0 && $sp -eq 0 && $sq1 -eq 0 && $sq2 -eq 0 && $sq3 -eq 0 && $s3 -eq 0 ]]
