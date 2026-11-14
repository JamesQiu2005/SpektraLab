#!/bin/bash
# hdr_gainmap_selftest.sh -- an export's gain map on this Mac (Sources/Engine/HDRGainMap.swift, HDRContainer.swift,
# HDRUltraHDR.swift; PRD/HDR-PORT-PLAN-2026-11-06.md D8): made on this Mac's GPU from the engine's own curve
# (tools/engine_replies/hdr_curve_reply.json), written by the export's own writer as JPEG and HEIF in both layouts
# with Adobe's hdrgm in the JPEG, and read back as ImageIO's DecodeToHDR reads it. No curve store, no ¼ / ½ maps,
# no 10-bit HEIF and no engine-linked slide checks.
#
#   tools/hdr_gainmap_selftest.sh                                   # the checks
#   tools/hdr_gainmap_selftest.sh --self-test                       # each broken rule must fail a check
#   tools/hdr_gainmap_selftest.sh --measure W H jpeg|heic [--no-map]   # phys_footprint of one map + write
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
src="$here/Sources"
swiftc -O -D DEBUG -parse-as-library -o "$out/hdr_gainmap_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/SettingsClipboard.swift" \
  "$src/Model/Stock.swift" "$src/Model/ExportRecipe.swift" "$src/Engine/HDRMath.swift" "$src/Engine/HDRGrainGain.swift" "$src/Engine/HDRRendition.swift" \
  "$src/Engine/HDRLook.swift" "$src/Engine/HDRGainMap.swift" "$src/Engine/HDRSessionCurve.swift" "$src/Engine/HDRGain.swift" \
  "$src/Engine/HDRContainer.swift" "$src/Engine/HDRUltraHDR.swift" "$src/Engine/ExportWriter.swift" \
  "$src/Engine/HostCut.swift" "$src/Model/MaskFrame.swift" "$src/Engine/MaskBaker.swift" "$src/Engine/MaskStore.swift" "$src/Engine/SceneLayerWire.swift" "$src/Engine/Layer2Kernel.swift" "$src/Engine/Layer2Local.swift" \
  "$here/tools/hdr_gainmap_selftest.swift" 2> "$out/hdr-gainmap-selftest-build.log" \
  || { grep -E "error" "$out/hdr-gainmap-selftest-build.log" | head -30; exit 1; }
if [[ "${1:-}" == "--self-test" ]]; then
  caught=0
  for b in nomap headroom apple hdrgm fallback tau tau0 show; do
    if "$out/hdr_gainmap_selftest" --break "$b" > "$out/hdr-gainmap-break-$b.log"; then
      echo "  NOT CAUGHT: --break $b"
    else
      caught=$((caught + 1)); grep -E "FAILED" "$out/hdr-gainmap-break-$b.log" | head -2
    fi
  done
  echo "HDR gain map self-test: $caught of 8 broken rules caught"
  [[ $caught -eq 8 ]]
else
  "$out/hdr_gainmap_selftest" "$@"
fi
