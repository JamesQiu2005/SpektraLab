#!/bin/bash
# tour.sh -- walk every presentation in a real window and capture each step.
#
#   tools/tour.sh [--out DIR] [--derived DIR]
#
# Builds the app and runs it with `--tour`: it opens for about half a minute, drives the
# router through the flow map's sheets, covers and pushed pages (App/Tour.swift), writes
# build/tour/NN-name.png and quits. The lines it prints say what was on top at each step.
#
# The build is Mac Catalyst, where a sheet is a window of its own: that checks the plumbing,
# not the look.

set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=""
derived=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --derived) derived="$2"; shift 2 ;;
    *) echo "unknown argument $1"; exit 2 ;;
  esac
done
out="${out:-$here/build/tour}"
python3 "$here/gen_project.py" > /dev/null
derived="${derived:-$here/build/DerivedData}"
destination='platform=macOS,variant=Mac Catalyst'
mkdir -p "$derived" "$out"
out=$(cd "$out" && pwd)
log="$derived/tour-build.log"
if ! xcodebuild -project "$here/SpektraLab.xcodeproj" -scheme SpektraLab -configuration Debug \
     -destination "$destination" -derivedDataPath "$derived" build > "$log" 2>&1; then
  grep -E "\.swift:[0-9]+:[0-9]+: error|error:" "$log" | sort -u | head -40
  echo "BUILD FAILED (full log: $log)"
  exit 1
fi
rm -f "$out"/*.png
app="$derived/Build/Products/Debug-maccatalyst/SpektraLab.app/Contents/MacOS/SpektraLab"
"$app" --tour "$out" 2>&1 | grep -E "^tour" &
pid=$!
( sleep 180; kill $pid 2>/dev/null ) & watchdog=$!
wait $pid 2>/dev/null || true
kill $watchdog 2>/dev/null || true
echo "-> $out"
