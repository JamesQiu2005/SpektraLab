#!/bin/bash
# watermark_export_check.sh -- 水印's 成片 composite in the files the app's own export writes (PRD-8 §8, RFC-067 §6;
# Sources/Mac/Layers/MacWatermarkCheck.swift): one frame of a RAW with a mark placed (bottom right, turned 37°, Edit's
# crop on), Enable HDR on, exported as JPEG and HEIF (each with its gain map), 16-bit TIFF, PNG and an SDR-only HEIF
# (Enable HDR off); the files held to the placement and to each other, and the maps to gain 1.0 under the mark.
# Then 底片 (stage 2): a base mark beside it, developed on the page and
# exported — where its placement says, developed, under the film's grain — and a move developed from the kept decode.
#
#   tools/watermark_export_check.sh RAW [--out DIR] [--app PATH] [--keep] [--memory]
#
# --memory: a 4,096 px mark on 底片 at full size, the export's peak against the same export without it, interleaved
# (plain, marked, plain, marked): the job's own phys_footprint record and `footprint -p` sampled from here, in
# --out/memory.txt.
#
# The app is a copy with a bundle id of the run's own (tools/check_app.sh) under a scratch home: the owner's library,
# marks and preferences are never read or written. A run that prints nothing new for 300 s is killed and red. Then the
# page: the frame in Develop with its watermark's row picked and at rest, the window captured into --out/captures.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
raw=""; out="$here/build/watermark-export-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0; memory=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --memory) memory=(--watermark-memory); shift ;;
    -*) echo "unknown: $1"; exit 2 ;;
    *) raw=$1; shift ;;
  esac
done
[[ -f "$raw" ]] || { echo "usage: tools/watermark_export_check.sh RAW [--out DIR] [--app PATH] [--keep]"; exit 2; }
mkdir -p "$out"; out=$(CDPATH= cd -- "$out" && pwd)
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
source "$here/tools/check_app.sh"; check_app_isolate "$app"
# A real pointer and real keys (the check's POINTER READY / KEYS READY lines): posted to the check's process only.
mkdir -p "$here/build/tools"
swiftc -O "$here/tools/post_keys.swift" -o "$here/build/tools/post_keys" 2> /dev/null || true
swiftc -O "$here/tools/post_pointer.swift" -o "$here/build/tools/post_pointer" 2> /dev/null || true
# Key events go to the key window: the check's process brought to the front by its process id (never by name: the owner's
# own SpektraLab may be running).
front() {
  local end=$(( $(date +%s) + 8 ))
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" > /dev/null 2>&1 || true
  while kill -0 "$1" 2> /dev/null && [[ $(date +%s) -lt $end ]]; do
    [[ "$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2> /dev/null)" == "$1" ]] && break
    sleep 0.2
  done
  sleep 0.5
}
home=$(mktemp -d "${TMPDIR:-/tmp}/watermark-check-home.XXXXXX")
suite="spk.watermark-check.$(basename "$home")"
pid=""
watcher=""
cleanup() {
  [[ -n "$watcher" ]] && { pkill -P "$watcher" 2> /dev/null; kill "$watcher" 2> /dev/null; } || true
  [[ -n "$pid" ]] && kill "$pid" 2> /dev/null || true
  defaults delete "$suite" > /dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$suite.plist"
  if [[ $keep -eq 1 ]]; then echo "home kept: $home"; else rm -rf "$home"; fi
  check_app_cleanup
}
trap cleanup EXIT INT TERM
log="$out/run.log"
: > "$out/pointer.log"; : > "$out/keys.log"
start=$(date +%s)
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --watermark-export-check "$out" \
  --export-check-pictures "$raw" --capture-window "$out/captures" --export-check-exit ${memory[@]+"${memory[@]}"} > "$log" 2>&1 &
pid=$!
( tail -n +1 -F "$log" 2> /dev/null | while IFS= read -r line; do
    case "$line" in
      "watermark-export-check: POINTER READY "*)
        read -r _ _ _ p x1 y1 x2 y2 ww wh <<< "$line"
        front "$p"
        "$here/build/tools/post_pointer" "$p" "$x1" "$y1" "$x2" "$y2" "$ww" "$wh" >> "$out/pointer.log" 2>&1 || true ;;
      "watermark-export-check: KEYS READY "*)
        read -r _ _ _ p keys <<< "$line"
        front "$p"
        "$here/build/tools/post_keys" "$p" $keys >> "$out/keys.log" 2>&1 || true ;;
    esac
  done ) &
watcher=$!
samples="$out/footprint.txt"; : > "$samples"
if [[ ${#memory[@]} -gt 0 ]]; then
  ( while kill -0 "$pid" 2> /dev/null; do
      b=$(footprint -p "$pid" --noCategories -f bytes 2> /dev/null | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p' | head -1)
      [[ -n "$b" ]] && echo "$(python3 -c 'import time; print(time.time())') $b" >> "$samples"
      sleep 0.2
    done ) &
fi
size=0; quiet=0
while kill -0 "$pid" 2> /dev/null; do
  sleep 1
  now=$(wc -c < "$log")
  if [[ $now -ne $size ]]; then size=$now; quiet=0; else quiet=$((quiet + 1)); fi
  if [[ $quiet -ge 300 ]]; then echo "watermark-export-check: FAIL silent for 300 s: killed"; kill "$pid" 2> /dev/null || true; fi
done
code=0; wait "$pid" || code=$?
pid=""
grep "^watermark-export-check:" "$log" || true
[[ -s "$out/pointer.log" ]] && { echo "posted pointer:"; cat "$out/pointer.log"; }
if [[ ${#memory[@]} -gt 0 ]]; then
  # Each export's highest `footprint -p` sample, between its start and its end (the check's MEMORY lines).
  python3 -I - "$log" "$samples" > "$out/memory.txt" <<'PY'
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
samples = [tuple(map(float, l.split())) for l in open(sys.argv[2]) if len(l.split()) == 2]
starts = {}
for l in lines:
    p = l.split()
    if len(p) >= 6 and p[1] == "MEMORY" and p[2] in ("start", "end"):
        key = (p[3], p[4])
        if p[2] == "start": starts[key] = float(p[5])
        else:
            a, b = starts.get(key, 0), float(p[5])
            got = [s for t, s in samples if a <= t <= b]
            before = [s for t, s in samples if a - 2 <= t <= a]
            print(f"footprint -p, {key[0]} export {key[1]}: before {min(before) / 2**20 if before else float('nan'):.0f} MB, "
                  f"highest {max(got) / 2**20 if got else float('nan'):.0f} MB over {len(got)} samples")
PY
  cat "$out/memory.txt"
fi
echo "watermark-export-check: ran $(( $(date +%s) - start )) s, exit $code"
exit $code
