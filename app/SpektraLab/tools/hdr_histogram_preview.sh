#!/bin/bash
# hdr_histogram_preview.sh [out.png] -- renders the app's own HistogramPlot on a synthetic picture, at the Mac
# panel's size, in both styles, with Enable HDR on and without a look. Built for Mac Catalyst (the app's Theme is
# UIKit's). HDR port, 2026-11-06, D7. Not part of tools/selftest.sh: a picture to look at.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
src="$here/Sources"
sdk=$(xcrun --show-sdk-path --sdk macosx)
support="$sdk/System/iOSSupport"
swiftc -O -parse-as-library -target "$(uname -m)-apple-ios18.0-macabi" -sdk "$sdk" \
  -Fsystem "$support/System/Library/Frameworks" -I "$support/usr/lib/swift" -L "$support/usr/lib/swift" \
  -o "$out/hdr_histogram_preview" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/SettingsClipboard.swift" \
  "$src/Model/Stock.swift" "$src/Engine/HDRMath.swift" "$src/Engine/HDRGrainGain.swift" "$src/Engine/HDRRendition.swift" "$src/Engine/HDRLook.swift" \
  "$src/Engine/HDRGainMap.swift" "$src/Engine/HDRSessionCurve.swift" "$src/Engine/HDRGain.swift" "$src/Model/ExportRecipe.swift" \
  "$src/DesignSystem/Theme.swift" "$src/DesignSystem/AppBackground.swift" "$src/Mac/RealStockNames.swift" \
  "$src/Features/Develop/HDRHistogram.swift" "$src/Features/Develop/HistogramPlot.swift" "$here/tools/hdr_histogram_preview.swift" \
  2> "$out/hdr-histogram-preview-build.log" \
  || { grep -E "error" "$out/hdr-histogram-preview-build.log" | head -30; exit 1; }
"$out/hdr_histogram_preview" "${1:-$out/hdr_histogram_preview.png}"
