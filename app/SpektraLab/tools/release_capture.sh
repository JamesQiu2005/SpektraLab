#!/bin/bash
# release_capture.sh -- the Release build's mask panel and a layer's page, captured (M1c review item 4).
#
#   tools/release_capture.sh     (after a Release build; writes build/masks-check/captures/release-*.png)
#
# The Release build's 图层 panel and a mask layer's page, en and zh-Hans, from a copy under its own bundle id
# (tools/check_app.sh) and a scratch home. Launch 1 imports a picture and quits. The scratch home is then seeded:
# MacLibrary/moved.json names the frame as in a catalog already (so the library's one-time "becomes a catalog" offer has
# been answered), and layers.json gives it one 径向渐变 layer (the app's own model types encode it). Launches 2 and 3, by
# the app's own `--language`, open it in 冲洗 (`--frame --develop`), capture the panel, press ↓ (Next Layer, a key
# command) to pick the layer, and capture its page.
set -uo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
mkdir -p "$here/build/tools"
# The seeder: the app's own model types encode the layer (tools/release_capture_seed.swift).
swiftc -O -parse-as-library -o "$here/build/tools/release_capture_seed" "$src/Model/Format.swift" "$src/Model/Localization.swift" \
  "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" \
  "$src/Model/CurveMath.swift" "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" \
  "$src/Model/HalfFramePair.swift" "$src/Model/DoubleExposure.swift" "$here/tools/selftest_theme_shim.swift" "$here/tools/release_capture_seed.swift" \
  2> "$here/build/tools/release-capture-seed-build.log" || { cat "$here/build/tools/release-capture-seed-build.log"; exit 2; }
swiftc -O "$here/tools/capture_windows.swift" -o "$here/build/tools/capture_windows" 2> /dev/null || true
swiftc -O "$here/tools/post_keys.swift" -o "$here/build/tools/post_keys" 2> /dev/null || true
out="$here/build/masks-check/captures"
mkdir -p "$out"; rm -f "$out"/release-*
source "$here/tools/check_app.sh"
check_app_isolate "$here/build/DerivedData/Build/Products/Release-maccatalyst/SpektraLab.app" || exit 2
home=$(mktemp -d "${TMPDIR:-/tmp}/release-capture.XXXXXX")
suite="spk.release-capture.$(basename "$home")"
mkdir -p "$home/in"
cp "$here/SampleSources/overscan/plain_bund.jpg" "$home/in/b-plain_bund.jpg"
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --import "$home/in" > "$out/release-import.log" 2>&1 &
pid=$!; sleep 20; kill "$pid"; wait "$pid" 2> /dev/null; sleep 2
lib=$(find "$home" -name library.json -not -path "*/Caches/*" | head -1)
[[ -f "$lib" ]] || { echo "no library.json"; exit 1; }
root=$(dirname "$lib")
id=$(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print([i for i in d['frames'] if 'plain_bund' in json.dumps(i)][0]['id'])" "$lib")
echo "frame $id under $root"
mkdir -p "$root/MacLibrary"
python3 -I -c "import json,sys; json.dump({'version':1,'moves':[],'inCatalog':[sys.argv[2]]}, open(sys.argv[1],'w'))" "$root/MacLibrary/moved.json" "$id"
"$here/build/tools/release_capture_seed" "$id" > "$root/layers.json"
for lang in en zh-Hans; do
  CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --frame b-plain --develop --language "$lang" > "$out/release-$lang.log" 2>&1 &
  pid=$!
  sleep 25
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" > /dev/null 2>&1
  sleep 2
  "$here/build/tools/capture_windows" "$pid" "$out/release-panel.$lang" > /dev/null 2>&1
  "$here/build/tools/post_keys" "$pid" k:125 >> "$out/release-keys.log" 2>&1
  sleep 10
  "$here/build/tools/capture_windows" "$pid" "$out/release-page.$lang" > /dev/null 2>&1
  kill "$pid"; wait "$pid" 2> /dev/null; sleep 2
done
defaults delete "$suite" > /dev/null 2>&1; rm -f "$HOME/Library/Preferences/$suite.plist"
rm -rf "$home"
check_app_cleanup
ls "$out"/release-*.png
