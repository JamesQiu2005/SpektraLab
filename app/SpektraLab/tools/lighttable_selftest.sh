#!/bin/bash
# lighttable_selftest.sh -- the light table's arithmetic (RFC-045), compiled with the film layout and run on this Mac.
#
#   tools/lighttable_selftest.sh [--self-test]
#
# The model (Sources/LightTable/LightTableModel.swift), the sizing, and the store's file, with the film
# layout's own sources -- the list tools/film_edge_parity.py compiles -- and the pair's model. No UIKit,
# no GPU: the renderer, the textures and the page are the simulator's (rfc/audits/lighttable-port-2026-10-17).
# `--self-test` runs every check against a rule broken on purpose and requires each to be caught.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
src="$here/Sources"
swiftc -O -parse-as-library -o "$out/lighttable_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FilmParams.swift" "$src/Model/Geometry.swift" \
  "$src/Model/FeatureFlags.swift" "$src/Model/FilmEdge.swift" "$src/Model/FrameEdit.swift" "$src/Model/Adjustments.swift" \
  "$src/Model/CurveMath.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$here/tools/selftest_theme_shim.swift" \
  "$src/FilmEdge/FilmEdgeStock.swift" "$src/FilmEdge/FilmGeometry.swift" "$src/FilmEdge/FilmLayout.swift" \
  "$src/LightTable/LightTableModel.swift" "$src/LightTable/LightTableTouch.swift" "$src/LightTable/LightTableSizing.swift" "$src/LightTable/LightTableStore.swift" "$src/Services/KeptFileAside.swift" \
  "$src/LightTable/LightTableExportPlan.swift" "$src/LightTable/LightTableMacMath.swift" \
  "$here/tools/lighttable_selftest.swift" 2> "$out/lighttable-selftest-build.log" \
  || { grep -E "error" "$out/lighttable-selftest-build.log" | head -30; exit 1; }
"$out/lighttable_selftest" "$@"
# The Share pictures' sizes, tiles and films (Sources/LightTable/LightTableExportPlan.swift), after the table's own.
swiftc -O -parse-as-library -o "$out/lighttable_export_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FilmParams.swift" "$src/Model/Geometry.swift" \
  "$src/Model/FeatureFlags.swift" "$src/Model/FilmEdge.swift" "$src/Model/FrameEdit.swift" "$src/Model/Adjustments.swift" \
  "$src/Model/CurveMath.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$here/tools/selftest_theme_shim.swift" \
  "$src/FilmEdge/FilmEdgeStock.swift" "$src/FilmEdge/FilmGeometry.swift" "$src/FilmEdge/FilmLayout.swift" \
  "$src/LightTable/LightTableModel.swift" "$src/LightTable/LightTableTouch.swift" "$src/LightTable/LightTableExportPlan.swift" \
  "$src/LightTable/LightTableSizing.swift" \
  "$here/tools/lighttable_export_selftest.swift" 2> "$out/lighttable-export-selftest-build.log" \
  || { grep -E "error" "$out/lighttable-export-selftest-build.log" | head -30; exit 1; }
"$out/lighttable_export_selftest" "$@"
