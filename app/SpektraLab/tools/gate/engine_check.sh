#!/bin/bash
# engine_check.sh -- the engine's gate, for `tools/gate.py area` when a change touches engine/ (AGENTS.md: "Engine parity
# harnesses only when engine inputs, kernels, resources or the render boundary changed").
#
# `engine/build.sh all`, never `dylib` alone: `dylib` leaves dump_json, dump_setup and gpu_smoke as they were, and three
# harnesses then grade a days-old engine green. Then the six parity harnesses (docs/agents/BUILD-AND-TEST.md), the
# boundary (gpu_smoke) and the math guard. The harnesses need the Python reference: SPEKTRALAB_REFERENCE_ROOT (or REF)
# names its checkout. Without one this exits 3, which `gate.py` reports as an incomplete tier, never as a pass.
set -uo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
ref=${SPEKTRALAB_REFERENCE_ROOT:-${REF:-}}
if [[ -z "$ref" || ! -x "$ref/.venv/bin/python" ]]; then
  echo "engine_check: NOT RUN: no Python reference (set SPEKTRALAB_REFERENCE_ROOT to the spektrafilm checkout with its .venv)"
  exit 3
fi
cd "$repo"
start=$(date +%s)
engine/build.sh all > "$here/build/engine-check-build.log" 2>&1 || { tail -20 "$here/build/engine-check-build.log"; echo "engine_check: FAIL engine/build.sh all"; exit 1; }
status=0
for h in parity_setup parity_schema parity_render parity_session parity_grain parity_lut; do
  t0=$(date +%s)
  if SPEKTRALAB_REFERENCE_ROOT="$ref" PYTHONPATH="$ref/src:engine/tests" "$ref/.venv/bin/python" "engine/tests/$h.py" > "$here/build/engine-check-$h.log" 2>&1; then
    echo "engine_check: ok    $h ($(( $(date +%s) - t0 )) s)"
  else
    echo "engine_check: FAIL  $h ($(( $(date +%s) - t0 )) s): $(tail -1 "$here/build/engine-check-$h.log")"; status=1
  fi
done
# The product's own colour negatives (engine/resources_product: Portra 160NC/VC, 400NC/VC): the engine's packs for
# them, the print stage's hue on all 32 pairs, their film edge. Needs only numpy and the dylib built above.
t0=$(date +%s)
if "$ref/.venv/bin/python" engine/tests/portra_nc_vc_checks.py --dylib engine/build/libspektralab_engine.dylib \
     > "$here/build/engine-check-portra_nc_vc.log" 2>&1; then
  echo "engine_check: ok    portra_nc_vc_checks ($(( $(date +%s) - t0 )) s)"
else
  echo "engine_check: FAIL  portra_nc_vc_checks ($(( $(date +%s) - t0 )) s): $(tail -1 "$here/build/engine-check-portra_nc_vc.log")"; status=1
fi
engine/build/gpu_smoke engine/resources/spektralab.metallib > "$here/build/engine-check-gpu_smoke.log" 2>&1 \
  && echo "engine_check: ok    gpu_smoke" || { echo "engine_check: FAIL  gpu_smoke"; status=1; }
engine/tests/check_math_guard.sh > "$here/build/engine-check-math_guard.log" 2>&1 \
  && echo "engine_check: ok    check_math_guard" || { echo "engine_check: FAIL  check_math_guard"; status=1; }
echo "engine_check: $(( $(date +%s) - start )) s, $([[ $status -eq 0 ]] && echo passed || echo FAILED)"
exit $status
