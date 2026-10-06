# Linux / Windows port -- running log (backend)

Read this first after a restart, then `git log --oneline -20`.
Brief: phases 0 (coverage) -> 1 (Linux build + `spektralab-host`) ->
2 (MinGW cross + wine) -> 3 (port refused features) -> 4 (docs).

## Build recipe (Linux)

```
engine/setup-deps.sh                      # LibRaw 0.22.2 + Vulkan-Headers into build/deps (verified pins)
cmake -S . -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_REQUIRE_VULKAN=ON
ninja -C build/linux && (cd build/linux && ctest)
```

## Scope (owner, 2026-10-06)

Phase 3 as first written (porting the five refused features to Vulkan) is
CANCELLED. Contrast mask, scene latitude mapping, Cineon DI, overscan/film
edge and date imprint stay refused, capabilities truthful; a human engineer
ports them. After Phase 2: 3a host completeness for the frontend
(PROTOCOL-REQUESTS incl. R1, hardening, a smoke test per method), 3b a
per-feature handoff for that engineer (kernels, host C++, Apple-only deps and
portable replacements, lavapipe test strategy, estimate, file:line), 3c wine
verification of whatever Phase 2 left unverified. Then Phase 4 docs.

## Done

- 2026-10-06: deps fetch verified; engine + tests build on Linux; CTest 12/14
  on lavapipe. `PORT_COVERAGE.md` written.
- Smoke test's FMA known-bit vectors accept the engine's reported unfused mode.

- `engine/host/` -> `spektralab-host`: framed stdio, reader + worker threads,
  every HOST-PROTOCOL method plus `write_image` (R1 part 2) and rgba16+display
  (R1 part 1); thumbnails oriented (R3). `engine/build-linux.sh` stages
  `build/host-linux-x64/` (static libstdc++, needs glibc + a Vulkan loader).
  `engine/tests/host_smoke.py` passes on lavapipe with a 12 MP NEF and a
  21 MP CR2 (from rawpy's test folder; raw.pixls.us is blocked by the proxy).
- Vulkan backend: dispatches past 65535 workgroups fold into 2D (every shader
  takes `spk_global_index()`; identical when it fits in one row). Without it
  any frame over 16.7 MP failed on lavapipe -- and on Intel, whose limit is
  the same 65535.
- Vulkan backend: on a CPU device only, a start-up probe proves SSBOs past
  lavapipe's advertised 128 MiB work, then lifts the limit; stated in
  math_mode. `SPEKTRAFILM_VULKAN_STRICT_LIMITS=1` turns it off.

## In progress / next

1. Phase 2: MinGW cross-build + wine.
2. Unfused-fma precision: `spk_iir_df_acc`, `spk_geometry_resample_df`,
   `spk_lut3d_trilinear`, `spk_di_normalise` use `fma` in `two_prod`. On
   lavapipe `fma` is mul+add, the error term is 0, and the IIR loses 0.4 %.
   Plan: exact Dekker split `two_prod` selected by a specialization constant
   (or unconditionally -- it is exact, so bit-identical where fma is fused).

## Decisions

- Lavapipe's precision failures are fixed in the kernels, not by loosening
  the gates (tried and reverted: errors grew with axis length / recursion).
