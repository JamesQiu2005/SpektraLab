#!/bin/bash
# watermark_base_level.sh -- where a 底片 mark's white must be laid in the scene to develop near paper white, measured
# through the engine on this Mac (tools/watermark_base_level.swift says what and how).
#
#   tools/watermark_base_level.sh mac
#
# Needs engine/build/libspektralab_engine.dylib (engine/build.sh dylib, then metallib) and the app's engine resources
# (tools/build_engine_mac.sh). A measurement, not a gate: its numbers are recorded beside WatermarkComposite.baseWhiteEV.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
where=${1:?mac}
out="$here/build/tools"
mkdir -p "$out"
bridge="$out/watermark_base_level_bridge.h"
echo '#include "spektralab/spk_engine.h"' > "$bridge"
eng="$root/engine"
res="$here/build/engine-macosx/EngineResources"
[[ "$where" == mac ]] || { echo "usage: tools/watermark_base_level.sh mac"; exit 2; }
[[ -f "$eng/build/libspektralab_engine.dylib" ]] || { echo "no $eng/build/libspektralab_engine.dylib -- run engine/build.sh dylib, then metallib"; exit 1; }
[[ -d "$res/profiles" ]] || { echo "no $res -- run tools/build_engine_mac.sh"; exit 1; }
swiftc -O -parse-as-library -import-objc-header "$bridge" -I "$root/engine/include" \
  -L "$eng/build" -lspektralab_engine -Xlinker -rpath -Xlinker "$eng/build" \
  "$here/tools/watermark_base_level.swift" "$here/Sources/Model/Format.swift" "$here/Sources/Model/Localization.swift" \
  "$here/Sources/Model/FilmParams.swift" "$here/Sources/Model/CurveMath.swift" \
  -o "$out/watermark_base_level" 2> "$out/watermark-base-level-build.log" \
  || { grep -E "error" -A 3 "$out/watermark-base-level-build.log" | head -40; exit 1; }
"$out/watermark_base_level" "$res" "$here/Resources/DIView-Cineon-to-ProPhoto.cube"
