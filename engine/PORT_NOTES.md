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

## Done

- 2026-10-06: deps fetch verified; engine + tests build on Linux; CTest 12/14
  on lavapipe. `PORT_COVERAGE.md` written.
- Smoke test's FMA known-bit vectors accept the engine's reported unfused mode.

## In progress / next

1. `engine/host/` -> `spektralab-host` (HOST-PROTOCOL.md). TOP PRIORITY.
2. Unfused-fma precision: `spk_iir_df_acc`, `spk_geometry_resample_df`,
   `spk_lut3d_trilinear`, `spk_di_normalise` use `fma` in `two_prod`. On
   lavapipe `fma` is mul+add, the error term is 0, and the IIR loses 0.4 %.
   Plan: exact Dekker split `two_prod` selected by a specialization constant
   (or unconditionally -- it is exact, so bit-identical where fma is fused).

## Decisions

- Lavapipe's precision failures are fixed in the kernels, not by loosening
  the gates (tried and reverted: errors grew with axis length / recursion).
