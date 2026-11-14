#!/bin/bash
# exit_render_check.sh -- quit while the engine renders, N times (tools/exit_render_check.swift: why).
#
#   tools/exit_render_check.sh [RUNS] [THREADS]
#
# Against the engine `engine/build.sh dylib` leaves in engine/build (run it first: the same sources as the app's
# Catalyst library, tools/build_engine_mac.sh). Each run exits after a delay that steps through 20..400 ms, so the
# exit lands in every part of a render; a run that does not exit 0 is a crash, and its signal is said. Exit 0 when
# every run exited 0.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
runs=${1:-60}; threads=${2:-1}
eng="$root/engine"
out="$here/build/tools"
mkdir -p "$out"
[[ -f "$eng/build/libspektralab_engine.dylib" ]] || { echo "no $eng/build/libspektralab_engine.dylib -- run engine/build.sh dylib"; exit 1; }
bridge="$out/exit_render_check_bridge.h"
echo '#include "spektralab/spk_engine.h"' > "$bridge"
swiftc -O -parse-as-library -import-objc-header "$bridge" -I "$root/engine/include" \
  -L "$eng/build" -lspektralab_engine -Xlinker -rpath -Xlinker "$eng/build" \
  "$here/tools/exit_render_check.swift" -o "$out/exit_render_check" 2> "$out/exit-render-check-build.log" \
  || { grep -E "error" -A 3 "$out/exit-render-check-build.log" | head -40; exit 1; }
crashes=0; start=$(date +%s)
for ((i = 0; i < runs; i++)); do
  delay=$(( 20 + (i * 397) % 381 ))
  set +e
  "$out/exit_render_check" "$eng/resources" "$delay" "$threads" > "$out/exit-render-check.last" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    crashes=$((crashes + 1))
    sig=""; [[ $rc -gt 128 ]] && sig=" (signal $((rc - 128)))"
    echo "run $i: exit $rc$sig after $delay ms: $(head -1 "$out/exit-render-check.last")"
  fi
done
echo "exit-render-check: $runs runs, $threads threads each, $crashes crashed, $(( $(date +%s) - start )) s"
[[ $crashes -eq 0 ]]
