#!/bin/bash
# variant_check.sh -- PRD-G part 1 in the running app: a variant is a frame of its own, joined to the library by
# (file, variant), and a grid cell is a variant (Sources/Mac/Library/MacVariantCheck.swift; PRD-G §6.1, 6.4, 6.5,
# 6.6, 6.7 and the frame-side New/Clone/Delete).
#
# The Debug app is launched twice under one scratch home (CFFIXED_USER_HOME: its library, its previews, its edit
# history and the helper's store are the scratch's, never the person's) and one UserDefaults suite of its own
# (`--defaults-suite`, deleted at the end: AGENTS.md trap 24). Every picture is a copy (a develop writes beside it).
# The first run makes the variants and their frames and writes what it made; the second relaunches and finds every
# variant's frame, edit and history again (§6.7).
#
#   tools/variant_check.sh [--out DIR] [--app PATH] [--raw FILE] [--sdk DIR] [--keep] [--keys]
#
# --keys: run 3 also presses F2 and F3 for real: tools/post_keys.swift posts the key events to the app's process
#   (`CGEvent.postToPid`) when the check says READY. The posting process (the terminal) needs the Mac's
#   Accessibility permission for the events to arrive; without it the K checks fail and say so.
# --context-menu: run 3 opens a variant cell's and a pair's context menu (UIKit's own presentation) and
#   tools/capture_windows.swift captures the app's windows while each is open, menu windows included, into
#   run3/captures/context-menu-*. Only the check's process's windows are captured.
#
# --raw: a RAW for §6.6 (two frames of one RAW, one proxy; another white balance, two). Default: the first ARW of
#   the main checkout's research/natural_shadow/dataset, copied; none found, §6.6 is skipped and said.
# --sdk: SpektraLab_library's checkout, for its Capture One 16.8 schema (tests/fixtures/capture_one_16_8_schema.sql),
#   which tools/variant_c1_fixture.py builds a three-picture catalog on (§6.4: one image with two variants). Read only.
#
# Run 3 is part 2's (Sources/Mac/Library/MacVariantActsCheck.swift): New, Clone and Delete Variant through the Image
# menu and the cells' menus, the greyed items, export names, paging, the Light Table, the shared RAW proxy, and the
# window captured in English and 简体中文 (run3/captures).
#
# Exit 0 when the three runs pass; each writes report.json under --out.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/variant-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0
raw=""; sdk="${SPKLIB_SOURCE:-$here/../../../SpektraLab_library}"; keys=0; menus=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --raw) raw=$2; shift 2 ;;
    --sdk) sdk=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --keys) keys=1; shift ;;
    --context-menu) menus=1; shift ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
# A copy with a bundle identifier of this run's own: the build's preferences are never reachable (tools/check_app.sh).
source "$here/tools/check_app.sh"; check_app_isolate "$app"
if [[ -z "$raw" ]]; then
  main=$(cd "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
  raw=$(ls "$main/research/natural_shadow/dataset/"*.ARW 2>/dev/null | head -1 || true)
fi
home=$(mktemp -d "${TMPDIR:-/tmp}/variant-check-home.XXXXXX")
suite="spk.variant-check.$(basename "$home")"
rm -rf "$out"; mkdir -p "$out/run1" "$out/run2" "$home/in"
cp "$here/SampleSources/scene_raw_srgb.jpg" "$home/in/a.jpg"
args=(--variant-check-files "$home/in/a.jpg")
if [[ -n "$raw" && -f "$raw" ]]; then
  cp "$raw" "$home/in/r.${raw##*.}"
  args+=(--variant-check-raw "$home/in/r.${raw##*.}")
else
  echo "variant-check: no RAW: §6.6 is skipped"
fi
schema="$sdk/tests/fixtures/capture_one_16_8_schema.sql"
if [[ -f "$schema" ]]; then
  c1=$(python3 -I "$here/tools/variant_c1_fixture.py" "$schema" "$home/c1" "$here/SampleSources/scene_raw_srgb.jpg" "$here/SampleSources/overscan/plain_bund.jpg")
  args+=(--variant-check-c1 "$c1")
else
  echo "variant-check: no SDK schema at $schema: §6.4 is skipped"
fi
start=$(date +%s)
set +e
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --variant-check "$out/run1" "${args[@]}" \
  --library-check-exit > "$out/run1.log" 2>&1
s1=$?
# Between the runs, 2.3.2 (its own library coder: tools/variant_keep_old.sh) reads the scratch library, changes every
# frame's edit and writes it back, as it does at its next save. Run 2 then finds every variant as run 1 left it.
old=()
if [[ $s1 -eq 0 ]] && "$here/tools/variant_keep_old.sh" > "$out/old-build.log" 2>&1; then
  lib=$(find "$home/Library/Application Support" -name library.json -path "*com.spektralab*" | head -1)
  if [[ -n "$lib" ]]; then
    cp "$lib" "$out/library-before-2.3.2.json"
    [[ -f "$(dirname "$lib")/variants.json" ]] && cp "$(dirname "$lib")/variants.json" "$out/variants-before-2.3.2.json"
    "$here/build/tools/variant_keep_old" "$lib" 0.123 | tee -a "$out/old-build.log"
    old=(--variant-check-old-build 0.123)
  else
    echo "variant-check: no library.json in the scratch home: 2.3.2's pass skipped"
  fi
else
  echo "variant-check: 2.3.2's coder not built or run 1 failed: its pass skipped (see $out/old-build.log)"
fi
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --variant-check "$out/run2" \
  --variant-check-relaunch "$out/run1" ${old[@]+"${old[@]}"} --library-check-exit > "$out/run2.log" 2>&1
s2=$?
# Run 2b: a library as this branch wrote it before variants.json (variant frames inside library.json) is read whole
# once, and the next write moves them to variants.json. The shelf is folded back into library.json, run 2 again.
s2b=0
lib=$(find "$home/Library/Application Support" -name library.json -path "*com.spektralab*" | head -1)
if [[ $s2 -eq 0 && -n "$lib" && -f "$(dirname "$lib")/variants.json" ]]; then
  python3 -I - "$(dirname "$lib")" <<'PY'
import json, os, sys
d = sys.argv[1]
lib, shelf = json.load(open(d + "/library.json")), json.load(open(d + "/variants.json"))
lib["frames"] += shelf["frames"]
json.dump(lib, open(d + "/library.json", "w"), sort_keys=True)
os.remove(d + "/variants.json")
print(f"variant-check: 2b folded {len(shelf['frames'])} variant frames into library.json")
PY
  CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --variant-check "$out/run2b" \
    --variant-check-relaunch "$out/run1" ${old[@]+"${old[@]}"} --library-check-exit > "$out/run2b.log" 2>&1
  s2b=$?
  moved=$(python3 -I -c 'import json,sys,os; d=sys.argv[1]; l=json.load(open(d+"/library.json")); v=os.path.exists(d+"/variants.json") and json.load(open(d+"/variants.json"))["frames"] or []; print(sum("variant" in f for f in l["frames"]), sum("variant" in f for f in v))' "$(dirname "$lib")")
  echo "variant-check: 2b after a relaunch: variant frames in library.json, in variants.json: $moved"
  [[ "${moved%% *}" == "0" && "${moved##* }" != "0" ]] || s2b=1
fi
# Run 3 (part 2, MacVariantActsCheck): the acts through the Image menu and the cells' menus, what they show, in a home
# and a defaults suite of its own; the window captured into $out/run3/captures.
home3=$(mktemp -d "${TMPDIR:-/tmp}/variant-check-home.XXXXXX")
suite3="spk.variant-check.$(basename "$home3")"
mkdir -p "$out/run3" "$home3/in"
cp "$here/SampleSources/overscan/plain_street.jpg" "$home3/in/a.jpg"
cp "$here/SampleSources/overscan/plain_bund.jpg" "$home3/in/b.jpg"
args3=(--variant-check-files "$home3/in/a.jpg" "$home3/in/b.jpg")
if [[ -n "$raw" && -f "$raw" ]]; then cp "$raw" "$home3/in/r.${raw##*.}"; args3+=(--variant-check-raw "$home3/in/r.${raw##*.}"); fi
if [[ -f "$schema" ]]; then
  c13=$(python3 -I "$here/tools/variant_c1_fixture.py" "$schema" "$home3/c1" "$here/SampleSources/scene_raw_srgb.jpg" "$here/SampleSources/overscan/plain_bund.jpg")
  args3+=(--variant-check-c1 "$c13")
fi
if [[ $menus -eq 1 ]]; then
  args3+=(--variant-acts-context-menu)
  swiftc -O "$here/tools/capture_windows.swift" -o "$here/build/tools/capture_windows" 2> "$out/capture-windows-build.log" || { cat "$out/capture-windows-build.log"; exit 1; }
fi
if [[ $keys -eq 1 ]]; then
  args3+=(--variant-acts-keys 20)
  swiftc -O "$here/tools/post_keys.swift" -o "$here/build/tools/post_keys" 2> "$out/post-keys-build.log" || { cat "$out/post-keys-build.log"; exit 1; }
fi
CFFIXED_USER_HOME="$home3" "$bin" --library real --defaults-suite "$suite3" --variant-acts-check "$out/run3" "${args3[@]}" \
  --library-check-exit > "$out/run3.log" 2>&1 &
app3=$!
if [[ $keys -eq 1 ]]; then
  for _ in $(seq 1 600); do
    pid=$(sed -n 's/^variant-acts-check: KEYS READY \([0-9]*\).*/\1/p' "$out/run3.log" | head -1)
    [[ -n "$pid" ]] && break
    kill -0 $app3 2> /dev/null || break
    sleep 0.2
  done
  # F2 (key code 120), then F3 (99), to the check's own process only.
  # Key events go to the key window, and a background app has none: the check's copy is brought to the front first, by
  # its process id (never by name: the owner's own SpektraLab may be running), then F2 and F3.
  if [[ -n "$pid" && "$pid" == "$app3" ]]; then
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" || true
    sleep 1.5
    "$here/build/tools/post_keys" "$pid" 120 99
  else
    echo "variant-check: no READY from run 3"
  fi
fi
if [[ $menus -eq 1 ]]; then
  mkdir -p "$out/run3/captures"
  seen=""
  while kill -0 $app3 2> /dev/null; do
    for line in $(sed -n 's/^variant-acts-check: MENU OPEN \([0-9]*\) \(.*\)$/\1:\2/p' "$out/run3.log"); do
      case " $seen " in *" $line "*) continue ;; esac
      seen="$seen $line"
      [[ "${line%%:*}" == "$app3" ]] && "$here/build/tools/capture_windows" "$app3" "$out/run3/captures/${line#*:}"
    done
    sleep 0.3
  done
fi
wait $app3
s3=$?
set -e
echo "ran $(( $(date +%s) - start )) s, run 1 exit $s1, run 2 exit $s2, run 2b exit $s2b, run 3 exit $s3"
grep -h "^2.3.2:" "$out/old-build.log" || true
grep -h "^variant-check:\|^variant-acts-check:" "$out/run1.log" "$out/run2.log" "$out/run3.log" || true
for s in "$suite" "$suite3"; do
  defaults delete "$s" > /dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$s.plist"
done
if [[ $keep -eq 1 ]]; then echo "homes kept: $home $home3"; else rm -rf "$home" "$home3"; fi
[[ $s1 -eq 0 && $s2 -eq 0 && $s2b -eq 0 && $s3 -eq 0 ]]
