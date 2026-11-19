#!/bin/bash
# libraw_decode_check.sh -- Settings' RAW decoder (2.4.2): the app's decode (Engine/RawExposure.swift) with LibRaw
# chosen, through the helper the app bundles (vendor/libraw/macos/spkraw-host), with tools/libraw_decode_check.swift, over
# a folder of RAW files: RAW_decode_tests (the repository's root, or $1) when that folder is here -- absent, it says
# SKIPPED. The bars are in the .swift.
#
#   tools/libraw_decode_check.sh [samples folder]
#   LIBRAW_CHECK_BREAK_ORIENTATION=1 tools/libraw_decode_check.sh   # LibRaw's picture turned over: every row must fail
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/libraw-decode-check"
mkdir -p "$out"
files=(Model/Format.swift Model/Localization.swift Model/FeatureFlags.swift Model/FilmParams.swift Model/FrameEdit.swift Model/LocalLayers.swift Model/Watermark.swift
       Model/Adjustments.swift Model/CurveMath.swift Model/Geometry.swift Model/FilmEdge.swift Model/LensEdge.swift Model/ExportRecipe.swift
       Model/SettingsClipboard.swift Model/Stock.swift Scheduler/DevicePolicy.swift Features/Develop/DevelopLayout.swift
       Engine/SceneLatitude.swift Engine/ScenePlacement.swift Model/HalfFramePair.swift Engine/PrintLayers.swift
       Engine/RawExposure.swift Engine/LibRawDecode.swift Engine/NeutralPick.swift
       Engine/DigitalDecode.swift Engine/LensProfile.swift Engine/LensProfileReader.swift Engine/LensCorrection.swift
       Engine/LCPReader.swift Services/LensDatabase.swift Engine/LensResolver.swift Engine/RawBlack.swift)
sources=()
for file in "${files[@]}"; do sources+=("$src/$file"); done
swiftc -O -parse-as-library "${sources[@]}" "$here/tools/libraw_decode_check.swift" -lsqlite3 -o "$out/libraw_decode_check" \
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
SPEKTRALAB_RAW_HOST="${SPEKTRALAB_RAW_HOST:-$here/../../vendor/libraw/macos/spkraw-host}" \
  "$out/libraw_decode_check" "$samples" | tee "$out/libraw-decode-check.md"
exit "${PIPESTATUS[0]}"
