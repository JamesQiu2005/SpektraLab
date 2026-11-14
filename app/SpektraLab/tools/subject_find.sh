#!/bin/bash
# subject_find.sh -- SubjectFinder (PRD-E, RFC-052 §9, M1c) on real photographs: tools/subject_find.swift's header.
#
#   tools/subject_find.sh [--sizes] [files…]
#
# With no files: the tree's SampleSources/scene_raw_srgb.jpg and seven RAWs of research/natural_shadow/dataset (the
# main checkout's; each is copied into build/masks-check/fixtures before it is read). macOS, no Xcode project, no app.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/masks-check"
mkdir -p "$out"
files=(Model/Format.swift Model/Localization.swift Model/FeatureFlags.swift Model/FilmParams.swift Model/FrameEdit.swift Model/LocalLayers.swift
       Model/Adjustments.swift Model/CurveMath.swift Model/Geometry.swift Model/FilmEdge.swift Model/LensEdge.swift
       Engine/RawExposure.swift Engine/RawProxy.swift Engine/RawProxyName.swift Engine/MaskBaker.swift Engine/MaskStore.swift Engine/SubjectFinder.swift
       Engine/LensProfile.swift Engine/LensProfileReader.swift Engine/LensCorrection.swift Engine/LensResolver.swift Engine/RawBlack.swift Engine/LCPReader.swift Services/LensDatabase.swift)
sources=()
for f in "${files[@]}"; do sources+=("$src/$f"); done
swiftc -O -parse-as-library -lsqlite3 "${sources[@]}" "$here/tools/subject_find.swift" -o "$out/subject_find" 2> "$out/subject-find-build.log" \
  || { grep -E "error" "$out/subject-find-build.log" | head -30; exit 1; }
args=("$@")
if [ ${#args[@]} -eq 0 ] || { [ ${#args[@]} -eq 1 ] && [ "${args[0]}" = "--sizes" ]; }; then
  data="$(git -C "$here" worktree list --porcelain | awk '/^worktree /{print $2; exit}')/research/natural_shadow/dataset"
  args+=("$here/SampleSources/scene_raw_srgb.jpg" "$data/049_ILCE-7RM5_normal_DSC00501.ARW" "$data/031_LEICA_Q3_hiDR_L1026319.DNG"
         "$data/097_NIKON_Z_7_2_night__DSC9819.NEF" "$data/044_ILCE-7M3_normal__DSC3278.ARW" "$data/104_NIKON_D700_9157DCD6-D07C-49AF-BAD1-0DFB89A84E2B.dng"
         "$data/032_GFX100RF_hiDR_DSCF1220.RAF" "$data/00_extreme-EV__DSC6506.NEF")
fi
"$out/subject_find" "${args[@]}"
