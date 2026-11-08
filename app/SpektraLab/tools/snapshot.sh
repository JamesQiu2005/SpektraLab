#!/bin/bash
# snapshot.sh -- draw the app's pages to PNGs, without a hand on the app.
#
#   tools/snapshot.sh [--only A4,B2] [--size 1440x900] [--scale 3] [--no-chrome] [--out DIR] [--derived DIR]
#                     [--insets TOP,LEFT,BOTTOM,RIGHT] [--release]
#                     [--language zh-Hans|zh-Hant|ja] [--switch-to zh-Hans|zh-Hant|ja]
#
# Builds the app and runs it with `--snapshot`: every page in `SnapshotHarness.pages`
# is hosted in a window that is never shown and written to build/snapshots/<id>.png,
# with an index.json naming each page and state.
#
# Every page is drawn in the Mac's column layout; a wide `--size` (1440x900) is the Mac's window.
# `--insets` names the safe area outright.
#
# The build is Mac Catalyst, the app as it runs on this Mac.
#
# The pages are drawn in English, whatever this Mac is set to: the drawings are
# English; `tools/same_snapshots.sh` compares captures from two runs.
# `--language zh-Hans` (or `zh-Hant`, or `ja`) draws them in Chinese (or Japanese) instead, into
# build/snapshots-zh-Hans (LOCALIZATION.md). `--switch-to zh-Hans`
# puts each page up in English, changes the language as Settings does, and draws the page as it then
# stands, into build/snapshots-switched-zh-Hans: `tools/same_snapshots.sh build/snapshots-zh-Hans
# build/snapshots-switched-zh-Hans` is the check that a change of language reaches every page at once.
#
# `--release` draws the release build instead: the Release configuration, which has no log sending
# compiled where the checkout has no logs.local: Settings › Diagnostics as the public sees it.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=""
derived=""
config=Debug
release=0
args=()
language=""
switched=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --derived) derived="$2"; shift 2 ;;
    --release) config=Release; release=1; shift ;;
    --language) language="$2"; args+=("$1" "$2"); shift 2 ;;
    --switch-to) switched="$2"; args+=("$1" "$2"); shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
for code in "$language" "$switched"; do
  [[ -z "$code" || "$code" == en || "$code" == zh-Hans || "$code" == zh-Hant || "$code" == ja ]] || { echo "no such language: $code (en, zh-Hans, zh-Hant, ja)"; exit 2; }
done
# A folder of its own for a language that is not the drawings': the English pages are never drawn over.
if [[ -z "$out" ]]; then
  out="$here/build/snapshots"
  [[ -n "$language" && "$language" != en ]] && out="$out-$language"
  [[ -n "$switched" ]] && out="$here/build/snapshots-switched-$switched"
fi
python3 "$here/gen_project.py" > /dev/null
derived="${derived:-$here/build/DerivedData}"
destination='platform=macOS,variant=Mac Catalyst'
log="$derived/snapshot-build.log"
mkdir -p "$derived" "$out"
out=$(cd "$out" && pwd)
# A release build is of every architecture unless told otherwise: this Mac's only, as a debug build is.
if ! xcodebuild -project "$here/SpektraLab.xcodeproj" -scheme SpektraLab -configuration "$config" \
     -destination "$destination" -derivedDataPath "$derived" ONLY_ACTIVE_ARCH=YES build > "$log" 2>&1; then
  grep -E "\.swift:[0-9]+:[0-9]+: error|error:" "$log" | sort -u | head -40
  echo "BUILD FAILED (full log: $log)"
  exit 1
fi
grep -E "\.swift:[0-9]+:[0-9]+: warning" "$log" | sort -u | head -20 || true
app="$derived/Build/Products/$config-maccatalyst/SpektraLab.app/Contents/MacOS/SpektraLab"
"$app" --snapshot "$out" ${args[@]+"${args[@]}"} 2>&1 | grep -E "^snapshot" &
pid=$!
# The harness exits by itself; the timeout is for a page that hangs.
( sleep 240; kill $pid 2>/dev/null ) & watchdog=$!
wait $pid 2>/dev/null || true
kill $watchdog 2>/dev/null || true
echo "-> $out"
