#!/bin/bash
# watermark_base_selftest.sh -- builds and runs tools/watermark_base_selftest.swift (水印's 底片 pass), with 2.4.0's own
# develop stamp beside today's: `enum DevelopStamp` as the 2.4.0 release commit 8e5ce17b ("chore(release): 2.4.0"; there
# is no tag) wrote it in Engine/DevelopedPicture.swift, renamed DevelopStamp240, so the check holds every markless edit's
# stamp to the one a 2.4.0 library's kept develops are named by. Then the same checks with one rule broken at a time.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/tools/watermark-base"
rm -rf "$out"; mkdir -p "$out"
rev=8e5ce17b
extract() { awk '/^enum DevelopStamp/{f=1} f{print} f&&/^}/{exit}'; }
{ echo "import CryptoKit"; echo "import Foundation"
  git -C "$here" show "$rev:app/SpektraLab/Sources/Engine/DevelopedPicture.swift" | extract | sed 's/^enum DevelopStamp /enum DevelopStamp240 /'
} > "$out/DevelopStamp240.swift"
{ echo "import CryptoKit"; echo "import Foundation"; extract < "$src/Engine/DevelopedPicture.swift"; } > "$out/DevelopStamp.swift"
# The cut's word the stamp reads (`Geometry.cutKey`, Engine/EngineWire.swift's first extension), today's, for both.
{ echo "import CoreGraphics"; echo "import Foundation"; awk '/^extension Geometry \{/{f=1} f{print} f&&/^}/{exit}' < "$src/Engine/EngineWire.swift"; } > "$out/CutKey.swift"
grep -q "enum DevelopStamp240" "$out/DevelopStamp240.swift" && grep -q "enum DevelopStamp " "$out/DevelopStamp.swift" \
  || { echo "watermark_base_selftest: the two stamps could not be read"; exit 1; }
files=(Model/Format.swift Model/Localization.swift Model/FeatureFlags.swift Model/FilmParams.swift Model/FrameEdit.swift
       Model/LocalLayers.swift Model/Watermark.swift Model/Adjustments.swift Model/CurveMath.swift Model/Geometry.swift
       Model/FilmEdge.swift Model/LensEdge.swift Model/Stock.swift Services/WatermarkStore.swift Engine/HostCut.swift
       Engine/FinishedCut.swift Engine/PictureMemory.swift Engine/WatermarkComposite.swift Engine/WatermarkBase.swift
       Scheduler/SchedulerTypes.swift Scheduler/DevicePolicy.swift Scheduler/MemoryProbe.swift Scheduler/MemoryBudget.swift
       Scheduler/CostModel.swift Scheduler/Planner.swift Scheduler/DevelopEngine.swift)
sources=()
for f in "${files[@]}"; do sources+=("$src/$f"); done
swiftc -O -parse-as-library "${sources[@]}" "$here/tools/selftest_theme_shim.swift" "$out/DevelopStamp240.swift" "$out/DevelopStamp.swift" "$out/CutKey.swift" \
  "$here/tools/watermark_base_selftest.swift" -o "$out/watermark_base_selftest" 2> "$out/build.log" \
  || { grep -E "error" -A 3 "$out/build.log" | head -40; exit 1; }
"$out/watermark_base_selftest"
"$out/watermark_base_selftest" --self-test
