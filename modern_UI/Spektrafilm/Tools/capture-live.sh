#!/bin/sh
#  Tools/capture-live.sh — capture the REAL window, through the window server.
#
#      Tools/capture-live.sh [image.NEF] [out.png]
#
#  Why this exists, and why it is not the same thing as `snapshot.sh`:
#  `snapshot.sh` renders the interface through `cacheDisplay`, which cannot
#  see a `CAMetalLayer` at all — so it substitutes an offscreen render of the
#  canvas. That blind spot hid two real defects at once: a drawable pixel
#  format `CAMetalLayer` rejects (the app crashed on launch), and a redraw
#  that never reached the view (the canvas stayed blank while every number
#  behind it was right). This script launches the app for real, opens a frame,
#  waits for the print, and asks the window server for the pixels. It is the
#  only capture that proves the canvas draws.
#
#  Needs Screen Recording permission for the terminal. Set
#  SPEKTRAFILM_CANVAS_LOG=1 in the environment to also get a per-draw log.
set -e
cd "$(dirname "$0")/.."
APP="build/DerivedData/Build/Products/Debug/Filmify.app"
IMG="$1"
OUT="${2:-$(cd .. && pwd)/design/snapshots/live-window.png}"
[ -x "$APP/Contents/MacOS/Filmify" ] || xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
    -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD"
BIN=/tmp/spektrafilm-live-window
[ -x "$BIN" ] || xcrun swiftc -O Tools/live-window.swift -o "$BIN"

# One instance, launched with the file in the same command. Launching with
# `open -n` and then sending the file with a second `open -a` starts a
# *second* copy of the app, and the capture then photographs whichever window
# the window server lists first — which is how a window showing the empty-strip
# placeholder was captured while another instance held the frame.
pkill -9 -f "MacOS/Filmify" 2>/dev/null || true
sleep 1
if [ -n "$IMG" ]; then open -n "$APP" --args "$IMG"; else open -n "$APP"; fi

# Wait for a window, then for the render to settle.
#
# The first window the app puts up is the **boot window**, 360×222, and it is
# gone by the time the render has settled — so an id taken here, before the
# wait, is an id that photographs nothing and reports "could not create image
# from window". Measured: that is exactly what happened. `$BIN` sorts by area,
# so the editor is always first once it exists; a floor on the width is what
# tells the two apart while the boot window is all there is.
EDITOR_MIN_WIDTH=800
editor_id() {
  "$BIN" 2>/dev/null | awk -v w="$EDITOR_MIN_WIDTH" '{split($2,a,"x"); if (a[1] >= w) {print $1; exit}}'
}
ID=""
for _ in $(seq 1 60); do
  ID=$(editor_id)
  if [ -n "$ID" ]; then break; fi
  sleep 1
done
[ -n "$ID" ] || { echo "capture-live: no editor window appeared"; exit 1; }
[ -n "$IMG" ] && sleep 25 || sleep 2

# …and again, because the editor window can be replaced by a second one after
# a boot handover, and the wait above is long enough for that to happen.
ID=$(editor_id)
[ -n "$ID" ] || { echo "capture-live: the editor window went away before the capture"; exit 1; }
screencapture -x -o -l"$ID" "$OUT"
pkill -9 -f "MacOS/Filmify" 2>/dev/null || true
echo "live window $ID → $OUT"
