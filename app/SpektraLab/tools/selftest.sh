#!/bin/bash
# selftest.sh -- compile the scheduler's own sources with tools/scheduler_selftest.swift and run it;
# then the Latitude card's and Scene Placement's (tools/latitude_selftest.swift: what is drawn from the
# engine's reply, and the app's solve of a placement against the engine's own)
# the host's cut of a decode for a film edge (tools/host_cut_selftest.swift: every pixel of the cut
# against the model's place for it), an export's own arithmetic and its saved recipes
# (tools/export_selftest.swift: what is decoded for the size a recipe names, and the recipes' file),
# and the develop page's (tools/develop_selftest.swift: every panel's parts and every note's line, a slide film scanned and never printed over the bundle's own
# catalogue), a double exposure's keeping, guide and darkroom rules (tools/double_selftest.swift,
# tools/double_darkroom_selftest.swift), and a half-frame pair's picture under its hole (tools/piece_selftest.swift:
# every pixel of the hole, as the app's host places it, against the pair's own arithmetic for it),
# the Film Edge flow's steps (tools/film_edge_steps_selftest.swift: every step open from a fresh open, the
# film edge written alike by a jump and by Next, and the options a choice greys, the frame number's held
# against the app's port of the engine's layout),
# Develop's strips (tools/stock_previews_selftest.swift: which cards, a slide with no paper and silver on
# silver, what each card is rendered from and its key, the size it keeps),
# and what the app keeps on disk and lets go of (tools/storage_selftest.swift: the working copies'
# limit, which of them go and which never do, and the launch's tidy of the files no frame names),
# a frame's edit history (tools/history_selftest.swift: the list and its cursor at 256 steps; tools/history_store_selftest.swift:
# the store on disk and in memory, a kill between steps, a newer build's file, the reconciliation guard;
# tools/history_label_selftest.swift: every field of a revision named),
# a RAW's lens correction where Core Image has none (tools/lens_profile_selftest.sh: a Sony ARW's own parameters and a DNG's
# opcodes read and applied, against Adobe's measured profile and Core Image's own; SKIPPED without RAW_decode_tests),
# the film path's RAW decode over the owner's samples (tools/raw_samples_check.sh: every file decodes, the black repair finds
# the DC-S1M2 and nothing else, every other file bit for bit as before it, the DC-S1M2's repaired shadows neutral, the fade
# on a made-up ramp, the lens column; SKIPPED without RAW_decode_tests),
# Check for Updates' arithmetic (tools/update_selftest.swift: which release is newer, what a manifest must hold),
# Settings' Supporters (tools/supporters_selftest.swift: the shipped Resources/Supporters.json decodes, and the
# page lists every entry with its note, over the shipped file and a fixture of its own),
# the agents' command line and MCP server (tools/agent_selftest.swift: the tool table and a call held to it whole,
# the socket's path, the socket end to end over a stand-in app, the CLI's exit codes, MCP's framing),
# the app's own log (tools/log_selftest.swift: a line with no file's name in it, the session's file
# and its 7 days, how the session before ended, what is due to send, and the zip), which readings of
# the app's memory become records (tools/memory_selftest.swift),
# the app's language (tools/language_selftest.swift: which of the four the system's language list asks for, what a
# launch settles on and keeps, a sentence's arguments), and its words (tools/localization_check.py: every
# sentence in four languages, in the right script, looked up where it is shown), and Layer 2, Edit's Light,
# Curve and Colour (tools/layer2_selftest.swift: the desktop's maths and its tests, the parametric curve,
# the kernels on this Mac's GPU against a reference -- neutral to the bit, a preview's size against an
# export's -- an edit of schema 3 loading, the clipboard's three groups, the log's names for them).
# And the files a person's work is kept in (tools/persisted_check.swift: a 2.1.4 library's edit, pair,
# clipboard, presets, recipes and Light Table, tools/persisted_2.1.4, read by this tree's own types and
# written back the same, a retired word read as what it stands for, an unreadable file set aside), with
# tools/persisted_names.py: every key, raw value, defaults key and engine or spklib-host field 2.1.4 had
# is still spelled somewhere in Sources (tools/persisted_names_baseline.tsv).
#
# Every one of them is compiled with Model/Localization.swift, the lookup the pages' words go through:
# with no bundle and no language chosen it gives each sentence back in English, which is what these
# checks compare (LOCALIZATION.md).
#
#   tools/selftest.sh [--self-test]
#
# macOS, no Xcode project: the scheduler, its cost model and the simulated engine have no UIKit in them,
# the card's reading and a placement's solve are made from the
# engine's reply without the engine (three replies it made, and its fits of four real frames, are kept
# in tools/engine_replies), and the cut is Core Image's on this Mac. The develop page's checks are
# compiled with -D DEBUG.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
src="$here/Sources"
bash "$here/tools/quick_fixes_check.sh"
bash "$here/tools/exposure_selftest.sh"
bash "$here/tools/lens_profile_selftest.sh"
bash "$here/tools/raw_samples_check.sh"
swiftc -O -parse-as-library "$src/Services/LibraryBrowser.swift" "$here/tools/library_browser_selftest.swift" -o "$out/library_browser_selftest"
"$out/library_browser_selftest"
swiftc -O -parse-as-library -o "$out/scheduler_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FilmParams.swift" "$src/Model/CurveMath.swift" \
  "$src/Scheduler/SchedulerTypes.swift" "$src/Scheduler/DevicePolicy.swift" "$src/Scheduler/MemoryProbe.swift" \
  "$src/Scheduler/MemoryBudget.swift" "$src/Scheduler/CostModel.swift" "$src/Scheduler/Planner.swift" \
  "$src/Scheduler/DevelopEngine.swift" "$src/Scheduler/SimulatedEngine.swift" "$src/Scheduler/RenderQueue.swift" \
  "$src/Scheduler/PrefetchPolicy.swift" \
  "$here/tools/scheduler_selftest.swift" 2> "$out/selftest-build.log" || { grep -E "error" "$out/selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/latitude_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FilmParams.swift" "$src/Model/CurveMath.swift" "$src/Engine/SceneLatitude.swift" "$src/Engine/ScenePlacement.swift" \
  "$here/tools/latitude_selftest.swift" 2> "$out/latitude-selftest-build.log" || { grep -E "error" "$out/latitude-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/host_cut_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/Geometry.swift" "$src/Engine/HostCut.swift" \
  "$here/tools/host_cut_selftest.swift" 2> "$out/host-cut-selftest-build.log" || { grep -E "error" "$out/host-cut-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/crop_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Model/CropGuides.swift" \
  "$src/Model/CameraCrop.swift" "$src/Features/Frame/CropStage.swift" "$src/Engine/HostCut.swift" "$src/Engine/FinishedCut.swift" "$src/Engine/ExportPlan.swift" "$src/Model/ExportRecipe.swift" \
  "$src/Services/ExportRecipeStore.swift" "$src/Services/KeptFileAside.swift" "$src/Engine/ExportWriter.swift" "$src/Engine/HDRGainMap.swift" "$src/Engine/HDRContainer.swift" "$src/Engine/HDRUltraHDR.swift" \
  "$src/Model/MaskFrame.swift" "$src/Engine/MaskBaker.swift" "$src/Engine/MaskStore.swift" "$src/Engine/SceneLayerWire.swift" "$src/Engine/Layer2Kernel.swift" "$src/Engine/Layer2Local.swift" \
  "$here/tools/crop_selftest.swift" 2> "$out/crop-selftest-build.log" || { grep -E "error" "$out/crop-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/export_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/Geometry.swift" "$src/Model/ExportRecipe.swift" "$src/Services/ExportRecipeStore.swift" "$src/Services/KeptFileAside.swift" \
  "$src/Engine/HostCut.swift" "$src/Engine/ExportPlan.swift" "$src/Engine/ExportWriter.swift" "$src/Engine/HDRGainMap.swift" "$src/Engine/HDRContainer.swift" "$src/Engine/HDRUltraHDR.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/LocalLayers.swift" "$src/Model/MaskFrame.swift" "$src/Engine/MaskBaker.swift" "$src/Engine/MaskStore.swift" "$src/Engine/SceneLayerWire.swift" "$src/Engine/Layer2Kernel.swift" "$src/Engine/Layer2Local.swift" \
  "$here/tools/export_selftest.swift" 2> "$out/export-selftest-build.log" || { grep -E "error" "$out/export-selftest-build.log" | head -30; exit 1; }
swiftc -O -D DEBUG -parse-as-library -o "$out/develop_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/ExportRecipe.swift" "$src/Model/SettingsClipboard.swift" \
  "$src/Model/Stock.swift" "$src/Features/Develop/DevelopLayout.swift" \
  "$here/tools/develop_selftest.swift" 2> "$out/develop-selftest-build.log" || { grep -E "error" "$out/develop-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/pair_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" \
  "$src/Engine/PrintLayers.swift" \
  "$here/tools/pair_selftest.swift" 2> "$out/pair-selftest-build.log" || { grep -E "error" "$out/pair-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/persisted_check" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" \
  "$src/Model/SettingsClipboard.swift" "$src/Model/ExportRecipe.swift" "$src/Services/ExportRecipeStore.swift" "$src/Services/PresetStore.swift" "$src/Services/KeptFileAside.swift" \
  "$src/LightTable/LightTableModel.swift" "$src/LightTable/LightTableStore.swift" "$src/LightTable/LightTableSizing.swift" "$src/LightTable/LightTableTouch.swift" \
  "$src/LightTable/LightTableExportPlan.swift" "$src/FilmEdge/FilmGeometry.swift" "$here/tools/selftest_theme_shim.swift" "$here/tools/persisted_paths_shim.swift" \
  "$here/tools/persisted_check.swift" 2> "$out/persisted-check-build.log" || { grep -E "error" "$out/persisted-check-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/film_edge_steps_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$here/tools/selftest_theme_shim.swift" \
  "$src/FilmEdge/FilmEdgeStock.swift" "$src/FilmEdge/FilmGeometry.swift" "$src/FilmEdge/FilmLayout.swift" "$src/Features/FilmEdge/FilmEdgeJourney.swift" \
  "$here/tools/film_edge_steps_selftest.swift" 2> "$out/film-edge-steps-selftest-build.log" || { grep -E "error" "$out/film-edge-steps-selftest-build.log" | head -30; exit 1; }
# PRD-D's app side (2026-11-11, tools/lens_edge_selftest.swift): 片幅's filter, 135 全宽, the 120 keyholes, 漏光, 镜头,
# 孔间数据 and the date's LED base -- what the engine is sent on main's engine and on one with API-SPEC §21, the cards,
# the app's layout of the new film, a 2.3.2 edit opening, Copy Settings and the resets.
swiftc -O -parse-as-library -o "$out/lens_edge_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/SettingsClipboard.swift" "$here/tools/selftest_theme_shim.swift" \
  "$src/FilmEdge/FilmEdgeStock.swift" "$src/FilmEdge/FilmGeometry.swift" "$src/FilmEdge/FilmLayout.swift" \
  "$src/Engine/HostCut.swift" "$src/Engine/FinishedCut.swift" "$src/Engine/ExportPlan.swift" "$src/Model/ExportRecipe.swift" \
  "$src/Scheduler/SchedulerTypes.swift" "$src/Scheduler/DevicePolicy.swift" "$src/Scheduler/MemoryProbe.swift" "$src/Scheduler/DevelopEngine.swift" \
  "$here/tools/lens_edge_selftest.swift" 2> "$out/lens-edge-selftest-build.log" || { grep -E "error" "$out/lens-edge-selftest-build.log" | head -30; exit 1; }
# A double exposure (RFC-048): what it keeps and what it
# began with, the frame's size (RFC-048 §5), the whole's look; a photograph removed, the guide before develop
# (its gains, its window, its key, and its pixels added by Core Image), and the older-build guard (doubles.json).
swiftc -O -parse-as-library -o "$out/double_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$src/Model/DoubleExposure.swift" \
  "$src/Engine/HostCut.swift" "$src/Engine/PiecePlacer.swift" "$src/Services/LibraryShelf.swift" "$src/Services/DoubleGuideLight.swift" \
  "$here/tools/double_selftest.swift" 2> "$out/double-selftest-build.log" || { grep -E "error" "$out/double-selftest-build.log" | head -30; exit 1; }
# The double exposure's darkroom as rules (RFC-050 §4): what each tab shows for the layer picked, Balance's track,
# the Latitude card's name, the export refusal, and the Mac's R3 (white balance per exposure) and R10 (no export
# of an emptied layer).
swiftc -O -parse-as-library -o "$out/double_darkroom_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$src/Model/DoubleExposure.swift" \
  "$src/Features/Develop/DevelopLayout.swift" "$src/Features/Double/DoubleRules.swift" \
  "$here/tools/double_darkroom_selftest.swift" 2> "$out/double-darkroom-selftest-build.log" || { grep -E "error" "$out/double-darkroom-selftest-build.log" | head -30; exit 1; }
# The 图层 (Layers) panel as rules (design/layers/LAYERS-SPEC.md §4, §5): the rows of a single frame, a pair and a
# double, the pick across the modes, the eye, Balance's place, the card's heights, a picked row's page (a double's
# held against DoublePanelKind tab by tab), which picture Crop arranges, and the refusal.
swiftc -O -parse-as-library -o "$out/layers_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$src/Model/DoubleExposure.swift" \
  "$src/Features/Develop/DevelopLayout.swift" "$src/Features/Double/DoubleRules.swift" "$src/Features/Layers/LayerRules.swift" \
  "$src/Features/Layers/MaskRules.swift" \
  "$here/tools/layers_selftest.swift" 2> "$out/layers-selftest-build.log" || { grep -E "error" "$out/layers-selftest-build.log" | head -30; exit 1; }
# A photograph's mask layers in the panel (design/masks/MASKS-SPEC.md §12 step 1): the rows, the pick, the heights, the
# page per pick, the folded words, a pair's refusal, names and numbering, 8 a stage, each stage's controls, the stage
# switch's line, and MASKS-SPEC §10's strings measured against their rooms in en and zh-Hans (the catalog's). -D DEBUG
# as before; since M1c the mask layers are in every build (`FeatureFlags.maskLayers`), and layers_selftest above, built
# without it, holds the release build's panel with them.
swiftc -O -D DEBUG -parse-as-library -o "$out/masks_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$src/Model/DoubleExposure.swift" \
  "$src/Features/Develop/DevelopLayout.swift" "$src/Features/Double/DoubleRules.swift" "$src/Features/Layers/LayerRules.swift" \
  "$src/Features/Layers/MaskRules.swift" "$src/Features/Layers/MaskGeometry.swift" \
  "$here/tools/masks_selftest.swift" 2> "$out/masks-selftest-build.log" || { grep -E "error" "$out/masks-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/piece_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" \
  "$src/Engine/HostCut.swift" "$src/Engine/PiecePlacer.swift" "$src/Engine/PrintLayers.swift" \
  "$src/Engine/PieceAdder.swift" \
  "$here/tools/piece_selftest.swift" 2> "$out/piece-selftest-build.log" || { grep -E "error" "$out/piece-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/stock_previews_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Services/StockPreviewRules.swift" \
  "$here/tools/stock_previews_selftest.swift" 2> "$out/stock-previews-selftest-build.log" || { grep -E "error" "$out/stock-previews-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/storage_selftest" \
  "$src/Services/WorkingCopies.swift" "$src/Services/StorageTidy.swift" "$src/Services/LibraryPreviews.swift" \
  "$src/Engine/RawProxyName.swift" "$here/tools/storage_selftest.swift" 2> "$out/storage-selftest-build.log" || { grep -E "error" "$out/storage-selftest-build.log" | head -30; exit 1; }
# The sending is compiled only under SPK_LOG_UPLOAD (a debug build's, and a release build's given a server
# by logs.local): the checks of it are compiled so, and the log's keeping and its zip are compiled without
# it too, as a release build without a server compiles them -- with no LogShipping.swift in sight.
swiftc -O -D SPK_LOG_UPLOAD -parse-as-library -o "$out/log_selftest" \
  "$src/Diagnostics/LogStore.swift" "$src/Diagnostics/LogShipping.swift" "$src/Diagnostics/LogBundle.swift" \
  "$here/tools/log_selftest.swift" 2> "$out/log-selftest-build.log" || { grep -E "error" "$out/log-selftest-build.log" | head -30; exit 1; }
swiftc -typecheck -parse-as-library "$src/Diagnostics/LogStore.swift" "$src/Diagnostics/LogBundle.swift" \
  2> "$out/log-store-build.log" || { echo "the log does not stand without its sending (a release build without a server):"; grep -E "error" "$out/log-store-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/memory_selftest" \
  "$src/Diagnostics/MemoryTrace.swift" \
  "$here/tools/memory_selftest.swift" 2> "$out/memory-selftest-build.log" || { grep -E "error" "$out/memory-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -lsqlite3 -o "$out/layer2_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/SettingsClipboard.swift" "$src/Model/Stock.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Features/Develop/Edit/EditTool.swift" \
  "$src/Engine/Layer2Kernel.swift" "$src/Engine/Layer2Renderer.swift" "$src/Engine/NeutralPick.swift" "$src/Engine/RawExposure.swift" \
  "$src/Engine/LensProfile.swift" "$src/Engine/LensProfileReader.swift" "$src/Engine/LensCorrection.swift" \
  "$src/Engine/LensResolver.swift" "$src/Engine/RawBlack.swift" "$src/Engine/LCPReader.swift" "$src/Services/LensDatabase.swift" \
  "$src/Engine/HostCut.swift" "$src/Model/MaskFrame.swift" "$src/Engine/MaskBaker.swift" "$src/Engine/MaskStore.swift" "$src/Engine/SceneLayerWire.swift" "$src/Engine/Layer2Local.swift" \
  "$here/tools/layer2_selftest.swift" 2> "$out/layer2-selftest-build.log" || { grep -E "error" "$out/layer2-selftest-build.log" | head -30; exit 1; }
# Enable HDR on the Mac (2026-11-06, D3/D5/D6; tools/hdr_selftest.swift): the per-frame choice and its JSON, a print's
# wire untouched by the switch and a slide's stretched, the stretch's rest when it leaves the wire, the paste group,
# the engine's curve reply (tools/engine_replies/hdr_curve_reply.json), and the canvas's kernels on this Mac's GPU.
swiftc -O -parse-as-library -o "$out/hdr_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/SettingsClipboard.swift" \
  "$src/Model/Stock.swift" "$src/Engine/HDRMath.swift" "$src/Engine/HDRGrainGain.swift" "$src/Engine/HDRRendition.swift" "$src/Engine/HDRLook.swift" \
  "$src/Engine/HDRGainMap.swift" "$src/Engine/HDRSessionCurve.swift" "$src/Engine/HDRGain.swift" "$src/Model/ExportRecipe.swift" \
  "$here/tools/hdr_selftest.swift" 2> "$out/hdr-selftest-build.log" || { grep -E "error" "$out/hdr-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/navigation_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/App/Navigation.swift" \
  "$here/tools/navigation_selftest.swift" 2> "$out/navigation-selftest-build.log" || { grep -E "error" "$out/navigation-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/language_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" \
  "$here/tools/language_selftest.swift" 2> "$out/language-selftest-build.log" || { grep -E "error" "$out/language-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/feedback_selftest" \
  "$src/DesignSystem/InputFeedbackRules.swift" "$here/tools/feedback_selftest.swift"
# The slider's arithmetic: the knob under the pointer, the number box's drag and its keys (2026-11-11).
swiftc -O -parse-as-library -o "$out/slider_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/DesignSystem/SliderMapping.swift" "$here/tools/slider_selftest.swift" \
  2> "$out/slider-selftest-build.log" || { grep -E "error" "$out/slider-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/history_selftest" \
  "$src/Model/EditHistory.swift" "$here/tools/history_selftest.swift"
# The edit history's store (PRD-F, 2026-11-13; tools/history_store_selftest.swift): the same rules in SQLite and in
# memory, a writer killed between steps, a newer build's file left as it was, the reconciliation guard's three cases,
# and the store's budgets on this Mac.
swiftc -O -parse-as-library -lsqlite3 -o "$out/history_store_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$src/Model/DoubleExposure.swift" \
  "$src/Engine/HostCut.swift" "$src/Engine/PiecePlacer.swift" "$here/tools/selftest_theme_shim.swift" \
  "$src/Model/DevelopRevision.swift" "$src/Model/HistoryLabel.swift" "$src/Model/HistoryFields.swift" "$src/Model/EditHistory.swift" "$src/Services/EditHistoryStore.swift" "$src/Services/SQLiteEditHistoryStore.swift" \
  "$here/tools/history_store_selftest.swift" 2> "$out/history-store-selftest-build.log" || { grep -E "error" "$out/history-store-selftest-build.log" | head -30; exit 1; }
# A history step's name (PRD-F §3.4, part 2; tools/history_label_selftest.swift): every field of a photograph's, a
# pair's and a double's revision named by the table, an observation or unnamed; the UI's words in three languages;
# groups and "+N more"; the cost at record time.
swiftc -O -parse-as-library -o "$out/history_label_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" "$src/Model/HalfFramePair.swift" "$src/Model/DoubleExposure.swift" \
  "$src/Engine/HostCut.swift" "$src/Engine/PiecePlacer.swift" "$here/tools/selftest_theme_shim.swift" \
  "$src/Model/DevelopRevision.swift" "$src/Model/HistoryLabel.swift" "$src/Model/HistoryFields.swift" \
  "$here/tools/history_label_selftest.swift" 2> "$out/history-label-selftest-build.log" || { grep -E "error" "$out/history-label-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/strip_source_selftest" \
  "$src/Services/StripSource.swift" "$here/tools/strip_source_selftest.swift"
# 松手即导入: which drags the window answers, and that its note goes however a drag ends (2026-11-09).
swiftc -O -parse-as-library -o "$out/drop_selftest" \
  "$src/Mac/Import/MacDropOffer.swift" "$here/tools/drop_selftest.swift" 2> "$out/drop-selftest-build.log" || { grep -E "error" "$out/drop-selftest-build.log" | head -30; exit 1; }
# The window's layout and the column's split across it.
swiftc -O -parse-as-library -o "$out/window_selftest" \
  "$src/App/WindowLayoutRule.swift" "$here/tools/window_selftest.swift"
# Settings' Supporters: the shipped list decodes and the page lists every entry with its note.
swiftc -O -parse-as-library -o "$out/supporters_selftest" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/Supporters.swift" \
  "$here/tools/supporters_selftest.swift" 2> "$out/supporters-selftest-build.log" || { grep -E "error" "$out/supporters-selftest-build.log" | head -30; exit 1; }
# Check for Updates: which release is newer, and what a manifest must hold (no network).
swiftc -O -parse-as-library -o "$out/mask_frame_selftest" "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/Geometry.swift" \
  "$src/Engine/HostCut.swift" "$src/Model/MaskFrame.swift" "$here/tools/mask_frame_selftest.swift" 2> "$out/mask-frame-selftest-build.log" \
  || { grep -E "error" "$out/mask-frame-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/mask_bake_selftest" "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/LocalLayers.swift" \
  "$src/Engine/MaskBaker.swift" "$src/Engine/MaskStore.swift" "$here/tools/mask_bake_selftest.swift" 2> "$out/mask-bake-selftest-build.log" \
  || { grep -E "error" "$out/mask-bake-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/scene_layer_selftest" "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/Geometry.swift" \
  "$src/Engine/HostCut.swift" "$src/Model/MaskFrame.swift" "$src/Model/LocalLayers.swift" "$src/Engine/MaskBaker.swift" "$src/Engine/MaskStore.swift" \
  "$src/Engine/SceneLayerWire.swift" "$src/Engine/SceneLayerHost.swift" "$here/tools/scene_layer_selftest.swift" 2> "$out/scene-layer-selftest-build.log" \
  || { grep -E "error" "$out/scene-layer-selftest-build.log" | head -30; exit 1; }
# Edit's pass with 成片 layers (PRD-E, RFC-052 §7, 2026-11-13; tools/layer2_local_selftest.swift): a full mask of each
# control is the control moved, k = ½ is half of it, k = 0 is today's to the bit, the mask is the engine's sampling, and
# a preview's size against an export's through a film edge, the host's turn, a flip and Edit's crop.
swiftc -O -parse-as-library -o "$out/layer2_local_selftest" "$src/Model/Format.swift" "$src/Model/Localization.swift" \
  "$src/Model/LocalLayers.swift" "$src/Model/Geometry.swift" "$src/Engine/HostCut.swift" "$src/Model/MaskFrame.swift" "$src/Engine/MaskBaker.swift" \
  "$src/Engine/MaskStore.swift" "$src/Engine/SceneLayerWire.swift" "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" \
  "$src/Engine/Layer2Kernel.swift" "$src/Engine/Layer2Renderer.swift" "$src/Engine/Layer2Local.swift" "$here/tools/layer2_local_selftest.swift" \
  2> "$out/layer2-local-selftest-build.log" || { grep -E "error" "$out/layer2-local-selftest-build.log" | head -30; exit 1; }
swiftc -O -parse-as-library -o "$out/update_selftest" \
  "$src/Model/Localization.swift" "$src/Services/UpdateCheck.swift" \
  "$here/tools/update_selftest.swift" 2> "$out/update-selftest-build.log" || { grep -E "error" "$out/update-selftest-build.log" | head -30; exit 1; }
# The agents' command line and MCP server, without the app: the tool table and a call held to it, the
# socket's path, the socket end to end over a stand-in app, MCP's framing (ARCHITECTURE.md §7.16).
swiftc -O -parse-as-library -o "$out/agent_selftest" \
  "$src/Agent/JSONValue.swift" "$src/Agent/AgentTools.swift" "$src/Agent/AgentWire.swift" "$src/Agent/AgentClient.swift" \
  "$src/Agent/AgentServer.swift" "$here/tools/agent_selftest.swift" 2> "$out/agent-selftest-build.log" || { grep -E "error" "$out/agent-selftest-build.log" | head -30; exit 1; }
status=0
"$out/strip_source_selftest" || status=1
"$out/update_selftest" || status=1
"$out/window_selftest" || status=1
"$out/drop_selftest" || status=1
"$out/supporters_selftest" "$@" || status=1
"$out/agent_selftest" "$@" || status=1
"$out/history_selftest" || status=1
"$out/history_store_selftest" || status=1
"$out/history_label_selftest" "$here/Resources/Localizable.xcstrings" || status=1
"$out/feedback_selftest" || status=1
"$out/slider_selftest" || status=1
"$out/scheduler_selftest" "$@" || status=1
"$out/latitude_selftest" "$@" || status=1
"$out/host_cut_selftest" "$@" || status=1
"$out/export_selftest" "$@" || status=1
# The crop page's records, perspective, guides and Edit's crop of a file (2026-10-20).
"$out/crop_selftest" "$@" || status=1
"$out/develop_selftest" "$@" || status=1
"$out/pair_selftest" "$@" || status=1
# A 2.1.4 library's files, and every name 2.1.4 kept (2026-11-08).
"$out/persisted_check" "$here/tools/persisted_2.1.4" || status=1
python3 -B "$here/tools/persisted_names.py" "$src" --check "$here/tools/persisted_names_baseline.tsv" | tail -1 || status=1
# PRD-E's mask layers kept beside the edit (2026-11-13, tools/layers_keep_check.sh): a library written by this tree,
# read, changed and written back by 2.3.1's own FrameEdit coder, keeps every layer; the same layers inside the edit
# are dropped (the red case).
bash "$here/tools/layers_keep_check.sh" | tail -1 || status=1
# PRD-E's masks without the engine (2026-11-13): the one mapping of a surface to S against HostCut's own pixels and
# the guide's drawing, every term broken red (tools/mask_frame_selftest.swift); the baker on this Mac's GPU against
# RFC-052 §4 in double, the brush drawn onto its plane and from a checkpoint to the bit (tools/mask_bake_selftest.swift);
# the 场景 layers' C against the engine's recorded reply, w, the ask and its stamp, and the host kernel of 应用胶片模拟
# off against the expression (tools/scene_layer_selftest.swift).
"$out/mask_frame_selftest" || status=1
"$out/mask_bake_selftest" --self-test || status=1
"$out/scene_layer_selftest" "$here/tools/engine_replies/scene_layers_reply.json" --self-test || status=1
# PRD-E's found masks (M1c, 2026-11-13; tools/found_mask_selftest.sh): the files' round trip and immutability, the sweep
# keeping what an edit, a history state or layers.json names, Vision's 主体 and 背景 from one file summing to one, the
# bake from the file on the 场景 and 成片 paths, a late result dropped, the unavailable path, 2.3.2's own tidy leaving
# Masks/ whole; with --self-test, each rule broken in a mutant of the sources and caught.
bash "$here/tools/found_mask_selftest.sh" "$@" | grep -E "^(FAIL|ok    mutant|ok    2\.3\.2|[0-9]+ passed)" || status=1
"$out/double_selftest" "$@" || status=1
"$out/double_darkroom_selftest" "$@" || status=1
"$out/layers_selftest" "$@" || status=1
"$out/masks_selftest" "$here/Resources/Localizable.xcstrings" "$@" || status=1
"$out/piece_selftest" "$@" || status=1
"$out/film_edge_steps_selftest" "$@" || status=1
"$out/lens_edge_selftest" "$here/Resources/StockCatalog.json" "$@" || status=1
"$out/stock_previews_selftest" "$@" || status=1
"$out/storage_selftest" "$@" || status=1
"$out/log_selftest" "$@" || status=1
"$out/memory_selftest" "$@" || status=1
"$out/language_selftest" "$@" || status=1
"$out/navigation_selftest" || status=1
"$out/layer2_selftest" "$@" || status=1
"$out/layer2_local_selftest" "$@" || status=1
(cd "$here" && "$out/hdr_selftest") || status=1
# The HDR histogram (2026-11-06, D7; tools/hdr_histogram_selftest.swift): counts past SDR white against the
# rendition's own arithmetic, the GPU's picture binned against the Swift pass, half floats read with no Float16.
bash "$here/tools/hdr_histogram_selftest.sh" || status=1
# An export's gain map (2026-11-06, D8; tools/hdr_gainmap_selftest.swift): the map is the canvas's, JPEG and HEIF in
# the camera's layout read back as their gain, Adobe's hdrgm the ISO declaration's to the field and ImageIO's file to
# the bit, every surprise refused, and each of five broken rules caught.
bash "$here/tools/hdr_gainmap_selftest.sh" | tail -1 || status=1
bash "$here/tools/hdr_gainmap_selftest.sh" --self-test | tail -1 || status=1
python3 "$here/tools/localization_check.py" --self-test | tail -1 || status=1
python3 "$here/tools/localization_check.py" | tail -3 || status=1
bash "$here/tools/v2_selftest.sh" || status=1
# The light table's arithmetic and its Share pictures' (tools/lighttable_selftest.sh: the model, the
# table's sizes and its way up, the glide between them, what is kept, the exports' sizes).
bash "$here/tools/lighttable_selftest.sh" "$@" || status=1
exit $status
