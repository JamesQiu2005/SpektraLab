#!/bin/bash
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
mkdir -p "$here/build/tools"
swiftc -O -parse-as-library -o "$here/build/tools/v2_selftest" \
 "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" \
 "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
 "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/SettingsClipboard.swift" "$src/Model/Stock.swift" \
 "$src/Services/PresetStore.swift" "$here/tools/v2_selftest.swift"
"$here/build/tools/v2_selftest" "$@"
