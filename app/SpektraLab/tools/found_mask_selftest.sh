#!/bin/bash
# found_mask_selftest.sh -- the found masks of M1c (tools/found_mask_selftest.swift's header): the files, their sweep,
# the bake from them on every path, the finder's tag and its unavailable path, on this Mac's GPU and Vision.
#
#   tools/found_mask_selftest.sh [--self-test]
#
# --self-test: the same checks compiled against mutants of the sources, each breaking one rule (the finder's tag, the
# sweep's names, the history's names, the age guard, immutability, the damaged-file check, the baker's read of the
# files); each mutant must go red, or the check that should have caught it cannot fail.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
out="$here/build/tools"
mkdir -p "$out"
files=(Model/Format.swift Model/Localization.swift Model/FeatureFlags.swift Model/FilmParams.swift Model/FrameEdit.swift Model/LocalLayers.swift
       Model/Adjustments.swift Model/CurveMath.swift Model/Geometry.swift Model/FilmEdge.swift Model/LensEdge.swift Model/Stock.swift
       Model/HalfFramePair.swift Model/DoubleExposure.swift Engine/HostCut.swift Engine/PiecePlacer.swift
       Model/DevelopRevision.swift Model/HistoryLabel.swift Model/HistoryFields.swift Model/EditHistory.swift Services/EditHistoryStore.swift
       Model/MaskFrame.swift Engine/MaskBaker.swift Engine/MaskStore.swift Engine/SceneLayerWire.swift Engine/Layer2Kernel.swift Engine/Layer2Local.swift
       Engine/RawExposure.swift Engine/RawProxy.swift Engine/RawProxyName.swift Engine/SubjectFinder.swift Services/FoundMaskKeeping.swift
       Engine/LensProfile.swift Engine/LensProfileReader.swift Engine/LensCorrection.swift Engine/LensResolver.swift Engine/RawBlack.swift Engine/LCPReader.swift Services/LensDatabase.swift
       Services/WorkingCopies.swift Services/StorageTidy.swift)
photo="$here/SampleSources/overscan/plain_bund.jpg"
build() {  # build <source root> <binary>
  local root=$1 bin=$2 sources=()
  for f in "${files[@]}"; do sources+=("$root/$f"); done
  swiftc -O -parse-as-library -lsqlite3 "${sources[@]}" "$here/tools/selftest_theme_shim.swift" "$here/tools/found_mask_selftest.swift" -o "$bin" \
    2> "$bin.build.log" || { grep -E "error" "$bin.build.log" | head -30; return 1; }
}
build "$src" "$out/found_mask_selftest"
status=0
"$out/found_mask_selftest" "$photo" || status=1
# 2.3.2's own tidy over a library with found masks (tools/found_masks_old_tidy.swift).
old="$out/found-masks-2.3.2"
rm -rf "$old"; mkdir -p "$old"
for f in WorkingCopies StorageTidy; do git -C "$here" show "88685135:app/SpektraLab/Sources/Services/$f.swift" > "$old/$f.swift"; done
swiftc -O -parse-as-library "$old/WorkingCopies.swift" "$old/StorageTidy.swift" "$here/tools/found_masks_old_tidy.swift" -o "$old/old_tidy" \
  2> "$old/build.log" || { grep -E "error" "$old/build.log" | head -20; exit 1; }
"$old/old_tidy" || status=1
if [ "${1:-}" = "--self-test" ]; then
  # Each mutant: <file> <python expression of the text replaced> -- the rule it breaks.
  mutants=(
    "Engine/SubjectFinder.swift|if let focused, focused != tag { throw Failure.dropped }|_ = focused|a late result is taken"
    "Engine/MaskStore.swift|guard Self.isAsset(asset), !keeping.contains(asset),|guard Self.isAsset(asset),|the sweep ignores the names"
    "Services/FoundMaskKeeping.swift|named.formUnion(h)|_ = h|the history's names are not counted"
    "Services/FoundMaskKeeping.swift|if let layersFile, let data = try? Data(contentsOf: layersFile) { named.formUnion(assets(inJSON: data)) }||layers.json's text is not read"
    "Engine/MaskStore.swift|now.timeIntervalSince(d) >= age, (try? files.removeItem(at: file)) != nil else { continue }|(try? files.removeItem(at: file)) != nil else { continue }|no age guard"
    "Engine/MaskStore.swift|if let kept = try? Data(contentsOf: target), Self.decode(kept)?.asset == asset { return asset }||a second write rewrites the file"
    "Engine/MaskStore.swift|guard asset(picture, header.mask) == header.asset else { return nil }||a damaged file is read"
    "Engine/MaskBaker.swift|if handed == nil { handed = await store.foundPicture(hash) }||the baker does not read the files"
    "Engine/MaskStore.swift|if let heir = others.filter(|if let heir = [UUID: Set<String>]().filter(|a frame removed hands nothing on"
  )
  for m in "${mutants[@]}"; do
    IFS='|' read -r file from to why <<< "$m"
    tree="$out/found-mutant"
    rm -rf "$tree"; mkdir -p "$tree"; cp -R "$src/." "$tree/"
    python3 - "$tree/$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
assert a in s, "mutant text not found: " + a
open(p, "w").write(s.replace(a, b, 1))
PY
    if build "$tree" "$out/found_mask_mutant" && "$out/found_mask_mutant" "$photo" > "$out/found-mutant.log" 2>&1; then
      echo "FAIL  mutant not caught: $why"; status=1
    else
      echo "ok    mutant caught: $why ($(grep -c '^FAIL' "$out/found-mutant.log" || true) red)"
    fi
  done
  rm -rf "$out/found-mutant"
fi
exit $status
