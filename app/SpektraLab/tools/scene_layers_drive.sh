#!/bin/bash
# scene_layers_drive.sh -- RFC-052 M0's gates through the app's own path (tools/scene_layers_drive.swift): the
# real engine client (Scheduler/SpkEngine.swift) over this Mac's engine (engine/build: `engine/build.sh dylib`,
# `metallib`), SceneLayerWire, MaskBaker and MaskFrame as the app compiles them.
#
#   tools/scene_layers_drive.sh gate1|gate2|gate4|refusal|stroke|chart
#   tools/scene_layers_drive.sh cost gradient|brush200|found|fold3
#   tools/scene_layers_drive.sh gate10 PHOTO OUTDIR | edge OUTDIR | tint-fit RAW
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
eng="$root/engine"
[[ -f "$eng/build/libspektralab_engine.dylib" ]] || { echo "no $eng/build/libspektralab_engine.dylib -- run engine/build.sh dylib, then metallib"; exit 1; }
bridge="$out/scene_layers_drive_bridge.h"
echo '#include "spektralab/spk_engine.h"' > "$bridge"
src="$here/Sources"
bin="$out/scene_layers_drive"
files=("$src/Scheduler/CostModel.swift" "$src/Scheduler/DevelopEngine.swift" "$src/Scheduler/DevicePolicy.swift" "$src/Scheduler/JobLogFile.swift"
  "$src/Scheduler/MemoryBudget.swift" "$src/Scheduler/MemoryProbe.swift" "$src/Scheduler/Planner.swift" "$src/Scheduler/PrefetchPolicy.swift"
  "$src/Scheduler/RenderQueue.swift" "$src/Scheduler/SchedulerTypes.swift" "$src/Scheduler/SimulatedEngine.swift" "$src/Scheduler/SpkEngine.swift"
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift"
  "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift"
  "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/ExportRecipe.swift" "$src/Model/MaskFrame.swift"
  "$src/Engine/HDRSessionCurve.swift" "$src/Engine/HDRGain.swift" "$src/Engine/HDRGrainGain.swift" "$src/Engine/HDRMath.swift" "$src/Engine/HDRGainMap.swift"
  "$src/Engine/HDRRendition.swift" "$src/Engine/HDRLook.swift" "$src/Engine/CineonView.swift" "$src/Engine/HostCut.swift"
  "$src/Engine/MaskBaker.swift" "$src/Engine/MaskStore.swift" "$src/Engine/SceneLayerWire.swift" "$src/Engine/SceneLayerHost.swift"
  "$here/tools/selftest_theme_shim.swift" "$here/tools/scene_layers_drive.swift")
newer=0
for f in "${files[@]}" "$eng/build/libspektralab_engine.dylib"; do [[ "$f" -nt "$bin" ]] && newer=1; done
if [[ ! -x "$bin" || $newer == 1 ]]; then
  swiftc -O -parse-as-library -D SPK_ENGINE -import-objc-header "$bridge" -I "$eng/include" -L "$eng/build" -lspektralab_engine \
    -Xlinker -rpath -Xlinker "$eng/build" "${files[@]}" -o "$bin" 2> "$out/scene-layers-drive-build.log" \
    || { grep -E "error" -A 3 "$out/scene-layers-drive-build.log" | head -40; exit 1; }
fi
"$bin" "$eng/resources" "$@"
