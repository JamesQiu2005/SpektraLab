#!/bin/bash
# hdr_histogram_selftest.sh -- the histogram's HDR span (Sources/Features/Develop/HDRHistogram.swift) on a synthetic
# picture with known highlights: the count past SDR white against the rendition's own arithmetic, and the GPU's
# picture binned against the Swift pass (on this Mac's GPU). Run from anywhere; also run by tools/selftest.sh.
# HDR port, 2026-11-06, D7: the Mac's HDR files, no Light Table HDR, no curve store.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
src="$here/Sources"
swiftc -O -parse-as-library -o "$out/hdr_histogram_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/SettingsClipboard.swift" \
  "$src/Model/Stock.swift" "$src/Engine/HDRMath.swift" "$src/Engine/HDRGrainGain.swift" "$src/Engine/HDRRendition.swift" "$src/Engine/HDRLook.swift" \
  "$src/Engine/HDRGainMap.swift" "$src/Engine/HDRSessionCurve.swift" "$src/Engine/HDRGain.swift" "$src/Model/ExportRecipe.swift" \
  "$src/Features/Develop/HDRHistogram.swift" "$here/tools/hdr_histogram_selftest.swift" \
  2> "$out/hdr-histogram-selftest-build.log" \
  || { grep -E "error" "$out/hdr-histogram-selftest-build.log" | head -30; exit 1; }
cd "$here" && "$out/hdr_histogram_selftest"
