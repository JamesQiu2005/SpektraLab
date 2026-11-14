#!/bin/bash
# lens_profile_selftest.sh -- compile the app's lens correction (Engine/LensProfile.swift, LensProfileReader.swift,
# LensCorrection.swift) with the two decodes that use it (RawExposure, DigitalDecode) and the model they read, with
# tools/lens_profile_selftest.swift and tools/lens_database_selftest.swift (Adobe's LCPs in the app's lens database,
# Engine/LCPReader.swift, Services/LensDatabase.swift), and run it: the synthetic cases always, the samples over RAW_decode_tests (the
# repository's root, or $1) when that folder is here -- absent, it says SKIPPED.
#
#   tools/lens_profile_selftest.sh [samples folder]
#   LENS_SELFTEST_DISABLE_STEP=1 tools/lens_profile_selftest.sh   # the app's step left out: the Sony cases must fail
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/lens-check"
mkdir -p "$out"
files=(Model/Format.swift Model/Localization.swift Model/FeatureFlags.swift Model/FilmParams.swift Model/FrameEdit.swift Model/LocalLayers.swift
       Model/Adjustments.swift Model/CurveMath.swift Model/Geometry.swift Model/FilmEdge.swift Model/LensEdge.swift Model/ExportRecipe.swift
       Model/SettingsClipboard.swift Model/Stock.swift Scheduler/DevicePolicy.swift Features/Develop/DevelopLayout.swift
       Engine/SceneLatitude.swift Engine/ScenePlacement.swift Model/HalfFramePair.swift Engine/PrintLayers.swift
       Engine/RawExposure.swift Engine/DigitalDecode.swift Engine/LensProfile.swift Engine/LensProfileReader.swift Engine/LensCorrection.swift
       Engine/LCPReader.swift Services/LensDatabase.swift Engine/LensResolver.swift Engine/RawBlack.swift)
sources=()
for file in "${files[@]}"; do sources+=("$src/$file"); done
swiftc -O -D DEBUG -parse-as-library "${sources[@]}" "$here/tools/lens_profile_selftest.swift" "$here/tools/lens_database_selftest.swift" "$here/tools/lens_resolution_selftest.swift" -lsqlite3 -o "$out/lens_profile_selftest"
# The samples sit at the repository's root, gitignored; a worktree reads its main checkout's.
samples="${1:-}"
if [ -z "$samples" ]; then
  common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  for c in "$here/../../RAW_decode_tests" "${common%/.git}/RAW_decode_tests"; do
    if [ -d "$c" ]; then samples="$c"; break; fi
  done
  samples="${samples:-$here/../../RAW_decode_tests}"
fi
"$out/lens_profile_selftest" "$samples"
