#!/bin/bash
# engine_smoke.sh -- build tools/engine_smoke.swift and run it on this Mac against the engine
# `engine/build.sh dylib` and `metallib` leave in engine/build.
#
#   tools/engine_smoke.sh mac [WIDTH HEIGHT]
#
# Each render's sha256 is printed, so two builds of the engine can be held against each other to
# the bit. A smoke test: its times and footprints are this Mac's, not a benchmark.
#
#   tools/engine_smoke.sh mac --latitude-grid PHOTO [OUT.jsonl] [--film ID] [--paper ID]
#   tools/engine_smoke.sh mac --latitude-sweeps PHOTO [OUT.jsonl] [--film ID] [--paper ID]
#
# Scene Placement's Fit on a photograph, as the engine says it: what tools/latitude_selftest.swift
# holds the app's own solve against (tools/engine_replies/scene_placement_*.jsonl). Without OUT it
# prints what it found and writes nothing.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
where=${1:?mac}; shift
out="$here/build/tools"
mkdir -p "$out"
bridge="$out/engine_smoke_bridge.h"
echo '#include "spektralab/spk_engine.h"' > "$bridge"
# The app's own wire for a new frame (`FilmParams.default`): the placement lines open a photograph with it.
sources=("$here/tools/engine_smoke.swift" "$here/Sources/Model/Format.swift" "$here/Sources/Model/Localization.swift" "$here/Sources/Model/FilmParams.swift" "$here/Sources/Model/CurveMath.swift")
case "$where" in
  mac)
    eng="$root/engine"
    [[ -f "$eng/build/libspektralab_engine.dylib" ]] || { echo "no $eng/build/libspektralab_engine.dylib -- run engine/build.sh dylib, then metallib"; exit 1; }
    swiftc -O -parse-as-library -import-objc-header "$bridge" -I "$root/engine/include" \
      -L "$eng/build" -lspektralab_engine -Xlinker -rpath -Xlinker "$eng/build" \
      "${sources[@]}" -o "$out/engine_smoke_mac" 2> "$out/engine-smoke-build.log" \
      || { grep -E "error" -A 3 "$out/engine-smoke-build.log" | head -40; exit 1; }
    "$out/engine_smoke_mac" "$eng/resources" "$@"
    ;;
  *) echo "usage: tools/engine_smoke.sh mac [WIDTH HEIGHT]"; exit 2 ;;
esac
