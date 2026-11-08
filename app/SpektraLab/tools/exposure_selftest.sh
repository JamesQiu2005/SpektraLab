#!/bin/bash
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/exposure-check"
mkdir -p "$out"
files=(Model/Format.swift Model/Localization.swift Model/FeatureFlags.swift Model/FilmParams.swift Model/FrameEdit.swift
       Model/Adjustments.swift Model/CurveMath.swift Model/Geometry.swift Model/FilmEdge.swift Model/ExportRecipe.swift
       Model/SettingsClipboard.swift Model/Stock.swift Scheduler/DevicePolicy.swift Features/Develop/DevelopLayout.swift
       Engine/SceneLatitude.swift Engine/ScenePlacement.swift Model/HalfFramePair.swift Engine/PrintLayers.swift)
sources=()
for file in "${files[@]}"; do sources+=("$src/$file"); done
swiftc -O -D DEBUG -parse-as-library "${sources[@]}" "$here/tools/exposure_selftest.swift" -o "$out/exposure_selftest"
"$out/exposure_selftest"
