#!/bin/bash
# raw_samples_check.sh -- compile the film path's decode (Engine/RawExposure.swift), its black repair (Engine/RawBlack.swift)
# and the lens stages it carries (LensCorrection, LensResolver, the lens database), with tools/raw_samples_check.swift, and
# run it over a folder of RAW files: the rule on made-up blocks always, a row per sample over RAW_decode_tests (the
# repository's root, or $1) when that folder is here -- absent, it says SKIPPED and counts it. The table is written to
# build/raw-samples-check/raw-samples-check.md, beside the DC-S1M2 lifted x8 unrepaired, with the pedestal alone and
# repaired, and the three side by side (P2319446-x8-side-by-side.jpg).
#
#   tools/raw_samples_check.sh [samples folder]
#   RAW_CHECK_DISABLE_REPAIR=1 tools/raw_samples_check.sh   # the repair off: the DC-S1M2's row must fail
#   RAW_CHECK_PEDESTAL_ONLY=1 tools/raw_samples_check.sh    # the pedestal alone, without the fade: the DC-S1M2's shadows must fail
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/raw-samples-check"
mkdir -p "$out"
files=(Model/Format.swift Model/Localization.swift Model/FeatureFlags.swift Model/FilmParams.swift Model/FrameEdit.swift Model/LocalLayers.swift
       Model/Adjustments.swift Model/CurveMath.swift Model/Geometry.swift Model/FilmEdge.swift Model/LensEdge.swift Model/ExportRecipe.swift
       Model/SettingsClipboard.swift Model/Stock.swift Scheduler/DevicePolicy.swift Features/Develop/DevelopLayout.swift
       Engine/SceneLatitude.swift Engine/ScenePlacement.swift Model/HalfFramePair.swift Engine/PrintLayers.swift
       Engine/RawExposure.swift Engine/DigitalDecode.swift Engine/LensProfile.swift Engine/LensProfileReader.swift Engine/LensCorrection.swift
       Engine/LCPReader.swift Services/LensDatabase.swift Engine/LensResolver.swift Engine/RawBlack.swift)
sources=()
for file in "${files[@]}"; do sources+=("$src/$file"); done
swiftc -O -parse-as-library "${sources[@]}" "$here/tools/raw_samples_check.swift" -lsqlite3 -o "$out/raw_samples_check" \
  2> "$out/build.log" || { grep -E "error" "$out/build.log" | head -30; exit 1; }
# The samples sit at the repository's root, gitignored; a worktree reads its main checkout's.
samples="${1:-}"
if [ -z "$samples" ]; then
  common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  for c in "$here/../../RAW_decode_tests" "${common%/.git}/RAW_decode_tests"; do
    if [ -d "$c" ]; then samples="$c"; break; fi
  done
  samples="${samples:-$here/../../RAW_decode_tests}"
fi
"$out/raw_samples_check" "$samples" "$out"
