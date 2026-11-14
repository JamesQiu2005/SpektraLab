#!/bin/bash
# lens_check.sh -- 镜头校正's interface in the running Debug app (Sources/Mac/Lens/MacLensCheck.swift): 编辑 › 镜头's part on
# five kinds of file, 畸变 and its Undo, its 配置文件 popup, Settings › Develop › Lens Profiles, the race of a develop asked
# as a resolution settles; and run 2, a relaunch, what was kept.
#
# The app runs under a scratch home (CFFIXED_USER_HOME: its library, its lens database and its history are the
# scratch's, never the person's) and a UserDefaults suite of its own (`--defaults-suite`, deleted at the end: trap 24),
# on copies of the samples (a develop writes a sidecar): a Sony ARW, the Canon EOS R6 Mark III's CR3, the Ricoh GR II's
# DNG, an Apple ProRAW and a JPEG of the tree's. The install's case reads a small folder of Adobe's .lcp files copied
# from this Mac (the samples' lenses, never all 3,602); with --adobe, Adobe's whole folder is installed too, timed, and
# removed (skipped loudly when it is not on this Mac).
#
#   tools/lens_check.sh [--samples DIR] [--adobe] [--only race] [--out DIR] [--app PATH] [--keep]
#
# Captures (the app's own drawing, <out>/captures/<name>.png; the window server's, <name>-screen-*.png, where the
# terminal may record the screen, which also sees the canvas and the open popup): the panel per file, the open popup
# with Canon's list (opened by the keyboard: Down to its row, Right), the Settings row, each in English and 简体中文.
# Exit 0 when both runs pass. A run under a minute developed nothing (trap 26): read run1.log.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/lens-check-app"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"
keep=0; samples=""; adobe=0; only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --samples) samples=$2; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --adobe) adobe=1; shift ;;
    --keep) keep=1; shift ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
if [[ -z "$samples" ]]; then
  common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  for c in "$here/../../RAW_decode_tests" "${common%/.git}/RAW_decode_tests"; do [[ -d "$c" ]] && { samples="$c"; break; }; done
fi
[[ -d "$samples" ]] || { echo "lens-check: SKIPPED: no RAW_decode_tests folder (give --samples)"; exit 2; }
adobe_root="/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0"
source "$here/tools/check_app.sh"; check_app_isolate "$app"
mkdir -p "$here/build/tools"
swiftc -O "$here/tools/capture_windows.swift" -o "$here/build/tools/capture_windows" 2> /dev/null || true
swiftc -O "$here/tools/post_keys.swift" -o "$here/build/tools/post_keys" 2> /dev/null || true

home=$(mktemp -d "${TMPDIR:-/tmp}/lens-check-home.XXXXXX")
suite="spk.lens-check.$(basename "$home")"
mkdir -p "$home/in" "$home/lcp/Canon" "$home/lcp/Ricoh" "$home/lcp/Sony"
cp "$samples/A7m3/DSC03710.ARW" "$home/in/a-DSC03710.ARW"
cp "$samples/EOS R6iii/8153398483.cr3" "$home/in/b-8153398483.cr3"
cp "$samples/DNG RAW/R0030139.DNG" "$home/in/c-R0030139.DNG"
cp "$samples/DNG RAW/IMG_9826.DNG" "$home/in/d-IMG_9826.DNG"
cp "$here/SampleSources/overscan/plain_bund.jpg" "$home/in/e-plain_bund.jpg"
# The samples' lenses and one more Canon, copied as Adobe lays them out (the maker is the folder).
lcp_found=0
for f in "Canon/Canon (Canon RF 28-70mm F2 L USM) - RAW.lcp" "Canon/Canon (Canon RF 28-70mm F2.8 IS STM) - RAW.lcp" \
         "Ricoh/GR II (Ricoh GR II 18.3 mm f2.8) - RAW.lcp" "Sony/SONY (Sony FE 35mm F1.8) - RAW.lcp"; do
  if [[ -f "$adobe_root/$f" ]]; then cp "$adobe_root/$f" "$home/lcp/$f"; lcp_found=$((lcp_found + 1)); fi
done
[[ $lcp_found -eq 4 ]] || echo "lens-check: only $lcp_found of 4 .lcp files found under $adobe_root: the install's case will fail"
cleanup() {
  defaults delete "$suite" > /dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
  if [[ $keep -eq 1 ]]; then echo "home kept: $home"; else rm -rf "$home"; fi
  check_app_cleanup
}
trap cleanup EXIT

front() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" > /dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    [[ "$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2> /dev/null)" == "$1" ]] && break
    sleep 0.2
  done
  sleep 0.5
}

launch() {
  local log=$1; shift
  CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" "$@" > "$log" 2>&1 &
  local pid=$!
  ( tail -n +1 -F "$log" 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        "lens-check: CAPTURE "*) "$here/build/tools/capture_windows" "$pid" "$out/captures/${line#lens-check: CAPTURE }-screen" > /dev/null 2>&1 || true ;;
        "lens-check: MENU OPEN "*)
          # MENU OPEN <pid> <name> downs=<n>: the popup is open; walk to Canon's row, open it, capture every window.
          read -r _ _ _ _ name downs <<< "$line"
          n=${downs#downs=}
          front "$pid"
          keys=(); for _ in $(seq 1 "$n"); do keys+=(k:125); done; keys+=(k:124)
          "$here/build/tools/post_keys" "$pid" "${keys[@]}" >> "$out/keys.log" 2>&1 || true
          sleep 1
          "$here/build/tools/capture_windows" "$pid" "$out/captures/$name-screen" > /dev/null 2>&1 || true
          "$here/build/tools/post_keys" "$pid" k:53 k:53 >> "$out/keys.log" 2>&1 || true ;;
      esac
    done ) &
  local watcher=$!
  local code=0
  wait "$pid" || code=$?
  pkill -P "$watcher" 2> /dev/null || true; kill "$watcher" 2> /dev/null || true
  wait "$watcher" 2> /dev/null || true
  return $code
}

rm -rf "$out"; mkdir -p "$out/run1" "$out/run2" "$out/captures"
start=$(date +%s)
extra=()
[[ $adobe -eq 1 ]] && extra+=(--lens-check-adobe "$adobe_root")
[[ -n "$only" ]] && extra+=(--lens-check-only "$only")
set +e
s1=0; launch "$out/run1.log" --import "$home/in" --lens-check "$out/run1" --lens-check-lcp "$home/lcp" --lens-check-hold 2 \
  --capture-window "$out/captures" ${extra[@]+"${extra[@]}"} || s1=$?
s2=0
if [[ -z "$only" ]]; then
  launch "$out/run2.log" --lens-check "$out/run2" --lens-check-relaunch "$out/run1" --lens-check-hold 2 --capture-window "$out/captures" || s2=$?
fi
set -e
echo "ran $(( $(date +%s) - start )) s, run 1 exit $s1, run 2 exit $s2"
grep -h "^lens-check:" "$out/run1.log" "$out/run2.log" 2> /dev/null || true
[[ $s1 -eq 0 && $s2 -eq 0 ]]
