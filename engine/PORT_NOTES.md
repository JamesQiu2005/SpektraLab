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

## Vulkan FMA gate (2026-10-11)

Some Vulkan drivers do not return a single-rounded residual from GLSL.std.450
Fma. The startup gate now tries the existing Dekker product on any device if
that residual is not exact, rather than accepting only CPU devices with all
zero residuals. Both words must match a binary64 oracle without tolerance.
The probe shares its split arithmetic with the IIR and geometry kernels.
Failure is cached as failure; lazy dispatch cannot bypass a rejected gate.

SPEKTRAFILM_VULKAN_FORCE_SPLIT=1 selects the measured split path for A/B tests.
SPEKTRAFILM_VULKAN_STRICT_FMA=1 requires an exact FMA and takes precedence.
These are diagnostic options, not required for normal user startup. Deploy
the new spk_split_probe.spv together with the host and all compiled shaders.
Do not mix the new host with an older shader folder.

Validation on NVIDIA RTX 5070 Ti and AMD Radeon integrated graphics: 22/22
CTest cases per device in default mode, 8/8 Vulkan/C-ABI cases per device in
forced split mode. Six injected gate cases all failed against the old gate
and pass after the fix (unfused/mixed residuals, broken/missing split probe,
strict precedence and forced split). The IIR 576-case oracle retains its
original limits and measures max abs error 1.49011612e-08 on both paths/cards.
Full Sony RAW (4688x7028), Ektar print and Provia scan, with grain/glare
disabled only for deterministic comparison: new NVIDIA default and forced
split RGBA16 outputs match the previous host byte-for-byte; AMD default and
forced split match each other byte-for-byte. Cross-vendor bit identity is
not claimed. Product default effects are unchanged.
No Intel device is available locally. This is not Intel acceptance or proof
of whole-image parity with Metal/Python. Upstream math requirements remain.

The current Tauri release app also returned a full default-effects RAW frame
through the new bundled host with forced split (native app logs; no visual
GUI acceptance claim). The supplied DeepSeek patch informed this change;
its early acceptance state, duplicate probe code and broad precision claims
were not carried over unchanged.

Spec: https://docs.vulkan.org/spec/latest/appendices/spirvenv.html
The ordinary Fma instruction inherits precision from OpFMul plus OpFAdd;
NoContraction is not a general guarantee of correctly rounded fused FMA.

## 2026-10-29: 1.3.4 on Vulkan, graded against Metal on a Mac

- `spk_highlight_headroom.comp`: CineStill 800T no longer refused.
- `SPEKTRALAB_VULKAN_ON_APPLE`: the Vulkan backend builds on macOS through
  MoltenVK so `parity_metal_vulkan.py` can grade it against the 1.3.4 Metal
  engine. All deterministic cases within 0.38 code (most 0.00).
- Fixed from that: BT.709 decode breakpoint pinned to Metal's; portable mark
  raster is exact-area. Fonts: Menlo-Bold -> DejaVu Sans Mono Bold,
  ArialNarrow -> Liberation Sans x0.82.
- `build-windows-cross.sh` works from macOS (Homebrew mingw-w64): LibRaw
  without OpenMP there, UCRT, import allowlist. Host smoke (384 checks, ARW +
  NEF) and 38 host CTests pass on a native MoltenVK host.
- GitHub #12 (dark red to purple) is a Mac screenshot; the dark-red patches
  in the parity input agree Metal/Vulkan to 0.00 code, so it is the shared
  film model's (the owner's comment: spectral upsampling), not a Vulkan bug.

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

- Phase 2: `engine/build-windows-cross.sh [--test]` (toolchain
  `engine/cmake/toolchain-mingw-w64.cmake`, posix-thread MinGW) stages
  `build/host-win-x64/spektralab-host.exe`; imports only KERNEL32, SHELL32,
  WS2_32, msvcrt. Under wine 9 + Xvfb, winevulkan forwards to lavapipe and the
  WHOLE host smoke passes (incl. the 12 MP NEF, a non-ASCII folder/file, and
  an install dir with a non-ASCII name). Without a display wine has no Vulkan
  driver (vkCreateInstance -3): use xvfb-run.
- UTF-8 paths on Windows: host argv via GetCommandLineW, exe dir via
  GetModuleFileNameW, files via fs::path(u8string); engine's four ifstream
  sites go through `core/file_path.hpp` (identity on POSIX/Apple).

- Unfused fma (lavapipe): the two double-float kernels (`spk_iir_df_acc`,
  `spk_geometry_resample_df`) take an exact Veltkamp/Dekker `two_prod` when
  the device does not fuse (specialization constant 0, set from the math
  probe); fused GPUs keep `fma`, unchanged. CTest 14/14 on lavapipe at the
  ORIGINAL tolerances: IIR max 1.49e-8 (the Windows RTX figure), geometry
  5.0e-7, resample 2.8e-7.

## In progress / next

1. Phase 3a: PROTOCOL-REQUESTS (R2 open), EXIF copy for write_image, more
   smoke cases (cancel, scene_latitude, preview_stock_lut, export_di, solve).

## Decisions

- Lavapipe's precision failures are fixed in the kernels, not by loosening
  the gates (tried and reverted: errors grew with axis length / recursion).
