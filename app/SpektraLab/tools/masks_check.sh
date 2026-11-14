#!/bin/bash
# masks_check.sh -- a photograph's mask layers in the running Debug app (Sources/Mac/Layers/MacMasksCheck.swift;
# design/masks/MASKS-SPEC.md §12's table, the cases M1a holds; traps 26, 33, 34).
#
# The app runs under a scratch home (CFFIXED_USER_HOME: its library, layers.json, its history are the scratch's) and a
# UserDefaults suite of its own (`--defaults-suite`, deleted at the end: AGENTS.md trap 24), on copies of a RAW and two
# of the tree's pictures (a develop writes a sidecar). Run 1 walks the cases and captures the window for drawings 01,
# 02, 03, 11, 12, 13 and 18 in English and 简体中文: the app's own drawing of it (<out>/captures/<name>.png) and, where
# the terminal may record the screen, the window server's (`screencapture -l`, <out>/captures/<name>-screen-*.png),
# which also sees the canvas and a menu. Run 2 relaunches on the same home: the layers kept, an Undo after it.
#
#   tools/masks_check.sh [RAW] [--raw24 RAW] [--out DIR] [--app PATH] [--keep] [--self-test]
#
# RAW: default the first NEF of the main checkout's research/natural_shadow/dataset (45 MP); --raw24 a second, for the
# tools' cost on a 24 MP frame (default its first ILCE-7M3 ARW, 6000 × 4000). --self-test runs run 1 once per
# broken mapping (`--masks-check-break`: neutral, identity, meter, panel, stage, digital, and M1b's geometry-crop,
# -printcrop, -straighten, -turn, -flip, -film, which run the tools' geometry case alone; M1c's geometry-halftexel, the
# flat frame's case alone with the overlay half a canvas pixel off; find-join, -invert, -keep, -adopt, -unavailable, the
# finding's cases alone with one rule of MaskFinding broken) and passes when every one is red.
#
# M1c (Sources/Mac/Layers/MacMaskFindCheck.swift, MacMaskFlatCheck.swift): 主体 · 背景 · 人 with Apple's Vision on this Mac,
# 组合蒙版, 完善蒙版…, the geometry mark, the found masks' files, Clone Variant from the Image menu, a flat grey frame
# (tools/flat_frame.py, e-flat.png in the import) for the overlay's edge; captures for drawings 08, 09, 10, 14, 16. Exit 0 when run 1 and run 2 pass. Run 1 on a 45 MP RAW takes minutes; under one means nothing developed.
#
# M1b (Sources/Mac/Layers/MacMaskToolsCheck.swift): run 1 prints "KEYS READY <pid>" and this presses B ] [ ⇧] ⇧[ E Esc
# M M ⌥M ⌥M ⌫ for real (tools/post_keys.swift, to the check's process only, brought to the front by its process id);
# and "POINTER READY <pid> x1 y1 x2 y2 w h", and this posts a mouse drag there (tools/post_pointer.swift). It captures
# the window for drawings 04-07 too.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/masks-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0; selftest=0; raw=""; raw24=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --raw24) raw24=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --self-test) selftest=1; shift ;;
    -*) echo "unknown: $1"; exit 2 ;;
    *) raw=$1; shift ;;
  esac
done
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
# A copy with a bundle identifier of this run's own: the build's preferences are never reachable (tools/check_app.sh).
source "$here/tools/check_app.sh"; check_app_isolate "$app"
if [[ -z "$raw" ]]; then
  raw=$(ls "$here/../../../../research/natural_shadow/dataset/"*NEF 2>/dev/null | head -1 || true)
  # In a worktree the dataset is the main checkout's (git's common directory is its .git).
  [[ -n "$raw" ]] || raw=$(ls "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../research/natural_shadow/dataset/"*NEF 2>/dev/null | head -1 || true)
fi
[[ -f "$raw" ]] || { echo "no RAW to check on (give one)"; exit 2; }
if [[ -z "$raw24" ]]; then
  raw24=$(ls "$(dirname "$raw")"/*ILCE-7M3*.ARW 2>/dev/null | head -1 || true)
fi
mkdir -p "$here/build/tools"
swiftc -O "$here/tools/capture_windows.swift" -o "$here/build/tools/capture_windows" 2> /dev/null || true
swiftc -O "$here/tools/post_keys.swift" -o "$here/build/tools/post_keys" 2> /dev/null || true
swiftc -O "$here/tools/post_pointer.swift" -o "$here/build/tools/post_pointer" 2> /dev/null || true

fresh_home() {
  home=$(mktemp -d "${TMPDIR:-/tmp}/masks-check-home.XXXXXX")
  suite="spk.masks-check.$(basename "$home")"
  mkdir -p "$home/in"
  cp "$raw" "$home/in/a-$(basename "$raw")"
  [[ -n "$raw24" && -f "$raw24" ]] && cp "$raw24" "$home/in/d-$(basename "$raw24")"
  cp "$here/SampleSources/overscan/plain_bund.jpg" "$home/in/b-plain_bund.jpg"
  cp "$here/SampleSources/overscan/plain_street.jpg" "$home/in/c-plain_street.jpg"
  # A flat grey frame: the overlay's edge against the developed effect's with nothing to weigh them (M1c step 0b).
  python3 -I "$here/tools/flat_frame.py" "$home/in/e-flat.png"
}
cleanup() {
  defaults delete "$suite" > /dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
  if [[ $keep -eq 1 ]]; then echo "home kept: $home"; else rm -rf "$home"; fi
}

# The check's own process brought to the front by its id (never by name: the owner's SpektraLab may be running), and
# waited for until it is the front one: a key posted before that is lost (found: the first seven of twelve were).
front() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" > /dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    [[ "$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2> /dev/null)" == "$1" ]] && break
    sleep 0.2
  done
  sleep 1
}

# A run of the app; its CAPTURE and MENU OPEN lines answered by the window server's capture of its windows.
launch() {
  local log=$1; shift
  CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" "$@" > "$log" 2>&1 &
  local pid=$!
  ( tail -n +1 -F "$log" 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        "masks-check: CAPTURE "*) "$here/build/tools/capture_windows" "$pid" "$out/captures/${line#masks-check: CAPTURE }-screen" > /dev/null 2>&1 || true ;;
        "masks-check: MENU OPEN "*) name=${line##* }; "$here/build/tools/capture_windows" "$pid" "$out/captures/$name-screen" > /dev/null 2>&1 || true ;;
        # Key events go to the key window, and a background app has none: brought to the front by its process id (never
        # by name: the owner's own SpektraLab may be running), then the keys, to this process only.
        "masks-check: KEYS READY "*)
          front "$pid"
          # B until it lands (the app says KEYS GO), then the rest.
          for _ in $(seq 1 25); do
            grep -q "^masks-check: KEYS GO" "$log" && break
            "$here/build/tools/post_keys" "$pid" k:11 >> "$out/keys.log" 2>&1 || true
          done
          "$here/build/tools/post_keys" "$pid" k:30 k:33 s:30 s:33 k:14 k:53 k:46 k:46 a:46 a:46 k:51 >> "$out/keys.log" 2>&1 || true ;;
        # The cost's strokes with the app in front, as a person paints (a window behind another is composited late).
        "masks-check: FRONT "*) front "$pid"; touch "$out/front.$pid" ;;
        # MASKS_COST_SAMPLE / MASKS_TRANSITIONS_SAMPLE: the main thread sampled while the app repeats what it names.
        "masks-check: SAMPLE "[0-9]*)
          read -r _ _ p name <<< "$line"
          ( sample "$p" 4 -mayDie -file "$out/sample-${name:-cost}.txt" > /dev/null 2>&1 || true ) & ;;
        "masks-check: POINTER READY "*)
          read -r _ _ _ p x1 y1 x2 y2 ww wh <<< "$line"
          front "$pid"
          "$here/build/tools/post_pointer" "$pid" "$x1" "$y1" "$x2" "$y2" "$ww" "$wh" >> "$out/pointer.log" 2>&1 || true ;;
      esac
    done ) &
  local watcher=$!
  local code=0
  wait "$pid" || code=$?
  pkill -P "$watcher" 2> /dev/null || true; kill "$watcher" 2> /dev/null || true
  wait "$watcher" 2> /dev/null || true
  return $code
}

if [[ $selftest -eq 1 ]]; then
  caught=0; total=0
  # MASKS_SELFTEST_ONLY="geometry-crop geometry-turn" runs those alone.
  for broken in ${MASKS_SELFTEST_ONLY:-neutral identity meter panel stage digital geometry-crop geometry-printcrop geometry-straighten geometry-turn geometry-flip geometry-film geometry-halftexel find-join find-invert find-keep find-adopt find-unavailable}; do
    total=$((total + 1))
    fresh_home
    mkdir -p "$out/self-test/$broken"
    code=0; launch "$out/self-test/$broken.log" --import "$home/in" --masks-check "$out/self-test/$broken" --masks-check-break "$broken" || code=$?
    if [[ $code -ne 0 ]]; then caught=$((caught + 1)); echo "  caught  $broken:"; grep '^masks-check: FAIL' "$out/self-test/$broken.log" | sed 's/^/      /' || echo '      ?' 
    else echo "  NOT CAUGHT  $broken"; fi
    cleanup
  done
  echo "masks-check self-test: $caught of $total broken mappings caught"
  [[ $caught -eq $total ]]; exit $?
fi

fresh_home
rm -rf "$out/run1" "$out/run2" "$out/captures" "$out/keys.log" "$out/pointer.log"; mkdir -p "$out/run1" "$out/run2" "$out/captures"
start=$(date +%s)
set +e
s1=0; launch "$out/run1.log" --import "$home/in" --masks-check "$out/run1" --masks-check-hold 2 --capture-window "$out/captures" || s1=$?
s2=0; launch "$out/run2.log" --masks-check "$out/run2" --masks-check-relaunch "$out/run1" || s2=$?
set -e
echo "ran $(( $(date +%s) - start )) s, run 1 exit $s1, run 2 exit $s2"
grep -h "^masks-check:" "$out/run1.log" "$out/run2.log" || true
[[ -f "$out/keys.log" ]] && grep -c "posted" "$out/keys.log" | sed 's/^/keys posted: /'
[[ -f "$out/pointer.log" ]] && cat "$out/pointer.log"
cleanup
[[ $s1 -eq 0 && $s2 -eq 0 ]]
