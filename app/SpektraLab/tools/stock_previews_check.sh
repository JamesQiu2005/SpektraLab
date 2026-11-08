#!/bin/bash
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/tools"
mkdir -p "$out"
swiftc -O -parse-as-library -o "$out/stock_previews_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/Stock.swift" "$src/Services/StockPreviewRules.swift" \
  "$here/tools/stock_previews_selftest.swift"
"$out/stock_previews_selftest" "$@"
