#!/bin/bash
# layers_keep_check.sh -- PRD-E's keeping against a 2.3.x build (RFC-052 §8.1): this tree writes a library whose
# frames have mask layers (tools/layers_keep_check.swift: library.json without them, layers.json beside it, and a
# copy with the layers left inside the edit); 2.3.1's own FrameEdit coder, compiled apart from `git show
# spektralab-v2.3.1` (tools/layers_keep_old.swift), reads both, changes every frame and writes them back; this tree
# reads the library again and must find every layer, and the inside copy must have lost them (the red case).
#
#   tools/layers_keep_check.sh
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/layers-keep"
rm -rf "$out"; mkdir -p "$out/old" "$out/library"
src="$here/Sources"
tag=spektralab-v2.3.1
for f in Model/Format Model/Localization Model/FeatureFlags Model/FilmParams Model/FrameEdit Model/Adjustments Model/CurveMath \
         Model/Geometry Model/FilmEdge Model/Stock; do
  git -C "$here" show "$tag:app/SpektraLab/Sources/$f.swift" > "$out/old/$(basename $f).swift"
done
git -C "$here" show "$tag:app/SpektraLab/tools/selftest_theme_shim.swift" > "$out/old/shim.swift"
swiftc -O -parse-as-library "$out"/old/*.swift "$here/tools/layers_keep_old.swift" -o "$out/layers_keep_old" 2> "$out/old-build.log" \
  || { grep -E "error" "$out/old-build.log" | head -20; exit 1; }
swiftc -O -parse-as-library -o "$out/layers_keep_check" \
  "$src/Model/Format.swift" "$src/Model/Localization.swift" "$src/Model/FeatureFlags.swift" "$src/Model/FilmParams.swift" "$src/Model/FrameEdit.swift" "$src/Model/LocalLayers.swift" \
  "$src/Model/Adjustments.swift" "$src/Model/CurveMath.swift" "$src/Model/Geometry.swift" "$src/Model/FilmEdge.swift" "$src/Model/LensEdge.swift" "$src/Model/Stock.swift" \
  "$src/Services/LibraryShelf.swift" "$src/Services/LayerShelf.swift" "$here/tools/selftest_theme_shim.swift" \
  "$here/tools/layers_keep_check.swift" 2> "$out/new-build.log" || { grep -E "error" "$out/new-build.log" | head -20; exit 1; }
# An edit with no layer is the bytes the tree before layers wrote for it (ba05fe00, the masks branch's base: its
# FrameEdit coder, compiled apart as 2.3.1's is): a new frame's, and 2.1.4's fixtures (every field set; the default).
base=ba05fe00
mkdir -p "$out/base"
for f in Model/Format Model/Localization Model/FeatureFlags Model/FilmParams Model/FrameEdit Model/Adjustments Model/CurveMath \
         Model/Geometry Model/FilmEdge Model/LensEdge Model/Stock; do
  git -C "$here" show "$base:app/SpektraLab/Sources/$f.swift" > "$out/base/$(basename $f).swift"
done
git -C "$here" show "$base:app/SpektraLab/tools/selftest_theme_shim.swift" > "$out/base/shim.swift"
swiftc -O -parse-as-library "$out"/base/*.swift "$here/tools/layers_keep_old.swift" -o "$out/layers_keep_base" 2> "$out/base-build.log" \
  || { grep -E "error" "$out/base-build.log" | head -20; exit 1; }
for e in - "$here/tools/persisted_2.1.4/frame-edit.json" "$here/tools/persisted_2.1.4/frame-edit-default.json"; do
  "$out/layers_keep_base" --bytes "$e" "$out/before.json"
  "$out/layers_keep_check" --bytes "$e" "$out/now.json"
  if cmp -s "$out/before.json" "$out/now.json"; then echo "ok    no layers: $(basename -- "$e") is written as $base wrote it, byte for byte ($(wc -c < "$out/now.json" | tr -d ' ') bytes)"
  else echo "FAIL  no layers: $(basename -- "$e") is written differently from $base"; cmp "$out/before.json" "$out/now.json" || true; exit 1; fi
done
"$out/layers_keep_check" write "$out/library"
"$out/layers_keep_old" "$out/library/library.json"
"$out/layers_keep_old" "$out/library/library-inline.json"
"$out/layers_keep_check" verify "$out/library"
