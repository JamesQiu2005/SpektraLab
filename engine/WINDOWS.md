# Windows headless port: incremental Vulkan gate

The Windows build keeps the existing C++ core and pipeline. The current Vulkan
backend creates a real compute device and runs 34 registered kernels, including
spectral upsampling, FIR and double-float IIR blur, film/print curves, and the fused spectral
integral. It creates an engine and opens a host-memory image through the
existing C API. Default grain, glare and automatic exposure now run on actual
decoded ARW inputs. The headless result has no drawable Vulkan texture.
The 2026-10-03 resumed migration also covers geometry, stock-LUT preview and
normalized-density DI delivery, and corrects a FIR boundary error.
The macOS `build.sh` and Xcode build are unchanged.

The current native host also opens RAW files and writes profiled RGB16 TIFF
without Python. See [WINDOWS_NATIVE_RAW.md](WINDOWS_NATIVE_RAW.md) for the
decode/export contract, supported paths, commands and remaining limitations.
This preserves the pixel-only C API and the current film/print pipeline.

## Build

Use a C++20 compiler, CMake 3.20+, and the Vulkan SDK (headers, loader import
library, and `glslangValidator`). CMake looks in `VULKAN_SDK` and accepts these
explicit paths when the tools live elsewhere:

The 2026-10-03 gate was verified with MinGW GCC 15.2, CMake/CTest 3.25.0,
Vulkan-Headers/glslang at the pinned SDK commits recorded in the workspace
baseline audit, and an NVIDIA GeForce RTX 5070 Ti. MSVC is not yet
verified.

For the current workspace, the repeatable MinGW build and test entry is:

```powershell
& .\engine\setup-libraw.ps1
& .\engine\build-windows.ps1 -Fresh
```

The default build directory is now `../build-windows-raw-headroom`, with native
RAW enabled. Use `-NativeRaw:$false` for the pixel-only build. LibRaw source can
be supplied with `-LibRawSourceDirectory`; CMake alone keeps this optional via
`SPEKTRALAB_BUILD_NATIVE_RAW` and `SPEKTRALAB_LIBRAW_SOURCE`.
The default decode policy remains `compatible16`; `--decode-mode headroom`
enables the separately tested float RGB conversion after uint16 demosaicing.
`../build-windows-native-raw` preserves the first native RAW/TIFF stage;
`../build-windows-migration` preserves the corrected FIR/geometry/LUT/DI stage.
`../build-windows-performance` preserves the completed performance stage;
`../build-windows-validation` preserves the pre-optimization baseline.
The script accepts explicit CMake, CTest, compiler, make, Vulkan and glslang
paths. It discovers the local pinned portable CMake package or an installed
CMake, requires the Vulkan target, copies the x64 MinGW runtime DLLs next to
the engine, and records source/resource/tool hashes in `toolchain.json`.
`-Fresh` needs CMake 3.24+. A failed run replaces the current manifest with a
failed status rather than leaving an old success report. Nothing is installed
globally. The core-only fallback remains available to ordinary CMake users;
`SPEKTRALAB_REQUIRE_VULKAN=ON` makes missing tools a configuration failure.

```powershell
cmake -S . -B build/windows -DSPEKTRALAB_VULKAN_INCLUDE_DIR="<SDK>/Include" -DSPEKTRALAB_VULKAN_LIBRARY="<SDK>/Lib/vulkan-1.lib" -DSPEKTRALAB_GLSLANG="<SDK>/Bin/glslangValidator.exe"
cmake --build build/windows --config Release
build/windows/engine/spk_vulkan_smoke.exe build/windows/engine/resources
```

Choose a generator and compiler appropriate to your installation. With MinGW,
the system `vulkan-1.dll` can serve as the linker input when no SDK import
library is installed. The shader compiler is still required. CMake copies the
tracked baked resources and compiles the GLSL files to SPIR-V in the
build directory; no generated binary is written into the source tree.

The smoke gate checks real GPU dispatches against small analytic cases: RGB
extraction, matrices, stride sampling, affine transforms, Hanatos coordinates
and LUT interpolation, both FIR edge modes and accumulation, curve
interpolation, DIR-coupler correction, spectral integration, and print
exposure, CAM16 compression, output transfer, and RGBA16 packing. It opens
two RGBA pixels through the C ABI and requires default grain/glare rendering
to succeed. The deterministic path renders a 2×2 RGBA16
image twice, checks that both outputs agree, and verifies that the result
remains readable after its session and engine are destroyed. The setup and
schema drivers remain available independently of Vulkan. The start-up math
probe tests a rounded multiply and explicit FMA on this device; it does not
establish full Vulkan-versus-Metal shader parity.

The IIR gate adds 576 real GPU cases against an independent float64 state
recurrence with float32 forward-plane storage, plus constant-image analytic
checks. It covers both axes, short/long lines, inactive channels, accumulation,
and input/output aliasing. On the verified RTX device the maximum absolute
error was `1.49011612e-08`. Removing coefficient low parts in an isolated
negative control made the same gate fail; the production shaders were kept.

With `BUILD_TESTING` the Windows test DLL is built by default from the same
core and pipeline as the static engine. `spektrafilm_engine.dll` exports only
the 25 public C API functions in `windows_exports.def`. The additional CTest
`spk_windows_c_abi` calls that DLL through `spk_render_fixture`, verifies two
renders and result lifetimes, and writes a packed RGBA16 file and JSON report.

The default render now runs with grain/glare/auto-exposure enabled. The same
deterministic baseline used by `parity_render.py` (`grain_active=false`,
`glare_active=false`, `auto_exposure=false`) remains the exact repeated-render
and cached-negative reprint gate. This is **not** a parity pass: no matching
Python oracle or macOS Metal output was compared on Windows yet. Larger frames
exposed both IIR and mirror-bilinear tier-resample kernels that the earlier
2×2 checkpoint did not cover. See `WINDOWS_FEATURE_COVERAGE.md` for the exact
implemented, tested and incomplete paths.

The grain gate preserves Philox and the original exact Poisson model. It
checks integer vectors, density interpolation, seed/channel relationships and
mean/variance/skew, including rates either side of ten. A Gaussian replacement
fails the skew gate. The pointwise gate passes 130 analytic/float64 cases and
tail guards; the resample gate passes 60 cases including long-axis integer
coordinates (max abs error `3.14712524e-7`). Isolated incorrect arithmetic,
tail writes and rounded coordinates all fail their corresponding gates.

On Windows, `spk_result.rgba16` points to a separate, caller-owned CPU copy of
the result; `texture` is only its opaque ownership handle, not a `VkImage` or
a drawable resource. Call `spk_result_free` even after destroying the session
or engine. Readback uses a GPU copy to host-cached staging followed by a CPU
copy into this independently owned result. The engine does not expose staging
memory to the caller.

## Device-local transfer milestone (historical phase 1, 2026-10-03)

Compute buffers use unmapped device-local memory with storage and transfer
usage. `Gpu::copy/read` make device copies and host readbacks explicit; tier and
negative caches, reductions, scanner constants and existing strip assembly no
longer require CPU pointers into compute memory. Metal's default implementations
preserve shared-memory behavior. Dispatch and transfer completion remain
synchronous, with transfer/compute/host barriers. That phase changed no shaders,
color math, RGB packing, public C ABI, or node flush policy. The subsequent
FIR correctness fix described below intentionally changes some image values.

Separate reusable upload/readback staging allocations handle noncoherent memory
with atom-aligned flush/invalidate ranges. Readback prefers HOST_CACHED memory.
Staging holds its maximum capacity until engine destruction; these allocations
are reported separately by diagnostics, not included in the existing pool ledger.

The historical phase-1 RTX 5070 Ti benchmark used the same 4688x7028 decoded ARW
with default grain/glare/AE enabled, in three independent processes (one first
full, five warm full and five cached reprints per process):

| Complete C ABI call | Median | Range |
|---|---:|---:|
| First full | 837.78 ms | 835.86–854.76 ms |
| Warm full | 219.29 ms | 216.62–222.73 ms |
| Cached reprint | 64.61 ms | 63.12–67.98 ms |

These include negative caching and CPU RGBA16 delivery, but exclude RAW decoding,
engine creation, open and file export. They are 32.95 MP results on this GPU,
not a matched 45 MP Nikon/Metal comparison. Phase-1 full deterministic RGBA16
matched the archived Windows implementation byte for byte. That historical
equality does not apply to the current corrected FIR shader; external parity
remains unverified.

Official performance workers clear inherited node/transfer diagnostics. For a
separate instrumented run pass `--diagnostic --processes 1 --warm 1 --reprints 1`.
`SPEKTRAFILM_TRANSFER_TIMINGS=1` logs memory types and upload/copy/read/fill byte
counts, wall time and staging capacity to stderr. It is disabled by default.

Phase-1 CTest included `spk_vulkan_transfer` (8/8 total), checking byte-preserving
transfers, ranges, guards, rejected requests, compute dependencies and pool
lifetimes. An isolated source-offset fault fails this gate. The lifecycle driver
checks input ownership, retained results, multiple sessions/tier caches and stable
allocation ledgers. It recorded a pre-existing strip discrepancy:
129x193, strip_rows=17 differs from whole frame in 1174 channel values (max 1013
RGB16 counts), identically in old/new transfer backends. The following phase
diagnosed and corrected this discrepancy; it is no longer an unresolved gate.

## Resumed migration and corrected FIR boundaries (current phase 2, 2026-10-03)

`build-windows-migration` is the preserved 34-kernel phase-2 build and passes CTest 10/10.
The current headroom build also tests TIFF, both decode-error paths, metadata-only
LibRaw linkage and headroom mathematics (CTest 14/14).
Its new geometry gate covers 192 cases against independent float64 spatial
mapping and exact integer rotations/flips (maximum absolute error
`8.16198319e-7`). The LUT/DI gate covers 96 cases (maximum absolute error
`6.96505159e-7`), including interpolation and normalized negative density.
These are local mathematical references, not recorded Metal output comparisons.

The FIR mirror/reflect coordinate mapping previously used signed `%` on negative
coordinates in GLSL. It did not preserve the intended wrapped boundary mapping.
The corrected shader avoids that negative-remainder path; 144 exact boundary
cases fail with the archived shader and pass with the corrected shader. No
material profiles or baked LUTs were changed.

The correction affects whole-frame images as well as stripes. Against the
preserved deterministic 32.95 MP RGBA16 frame, 2,763,447 pixels / 6,073,521 RGB
channel values change, with a maximum absolute difference of 45,058 counts;
alpha is unchanged. This is a correctness change, not numerical noise.
The new DLL loaded with the archived shaders reproduces the preserved full
frame byte for byte, isolating the change to the FIR shader fix. Current outputs
must therefore be compared with the new baseline, not required to equal the
old incorrect output. Full external Metal/Python parity is still pending.

Corrected whole/striped/reprint outputs agree byte for byte across 35 tested
deterministic parameter/strip-size combinations. The full 4688x7028 ARW also
passes with 509-row strips and cached reprint. These exact comparisons disable
grain, glare and AE; they do not validate every stochastic stripe combination.

`tools/windows_features.py` checks geometry cache invalidation and retained
result ownership through the C ABI. Full RAW quarter-turn and horizontal-flip
results equal explicitly transformed inputs; arbitrary crop/rotation passes
dimension/cache checks, with numerical correctness covered by the direct
geometry gate. All eight shipped stock tables are byte-identical to the baked
blob, and their synthetic LUT-preview/DI calls pass. Full RAW Portra Endura
preview and DI pass, including retained results after engine destruction.
Preview files use the catalog's encoded Display P3 contract; DI files represent
normalized negative density, not display RGB. These are raw RGBA16 buffers,
not completed TIFF/image export support.

The current three-process benchmark again includes one first full, five warm
full and five cached reprints per process (33 complete C ABI calls):

| Complete C ABI call | Median | Range |
|---|---:|---:|
| First full | 871.41 ms | 864.83–873.88 ms |
| Warm full | 229.30 ms | 227.10–232.89 ms |
| Cached reprint | 66.72 ms | 65.33–73.46 ms |

The 4688x7028 input, default grain/glare/AE, and inclusion of negative caching
and owned CPU RGBA16 delivery are unchanged. RAW decoding, engine creation,
open and file writing remain separate. All phase-1 speed targets remain met.
Evidence is under `../validation/migration-phase2`: `benchmark/report.json`,
`full-frame-checks.json`, `stripe-after.json`, `lifecycle.json`,
`features-synthetic/report.json` and `features-raw-full/report.json`.

```powershell
python engine/tools/windows_performance.py --library ../build-windows-migration/engine/spektrafilm_engine.dll --resources ../build-windows-migration/engine/resources --input ../validation-fixtures/raw-arw-full/input.f32 --input-metadata ../validation-fixtures/raw-arw-full/input.f32.json --width 4688 --height 7028 --output ../validation/new-performance-run
python engine/tools/windows_lifecycle.py --library ../build-windows-migration/engine/spektrafilm_engine.dll --resources ../build-windows-migration/engine/resources --reference-library ../build-windows-validation/engine/spektrafilm_engine.dll --reference-resources ../build-windows-validation/engine/resources --require-stripe-parity --output ../validation/new-lifecycle.json
python engine/tools/windows_features.py --library ../build-windows-migration/engine/spektrafilm_engine.dll --resources ../build-windows-migration/engine/resources --output ../validation/new-features
```

The lifecycle driver's `--require-stripe-parity` is essential for the corrected
build: it requires new whole/stripe equality while recording old-output
differences, rather than requiring the old erroneous shader output.

## Fixed inputs and external comparisons

`engine/tools/windows_fixture.py` needs NumPy only. It uses the same synthetic
generator as `parity_render.py`, writes little-endian tightly packed RGB
float32 input, explicit deterministic parameters and a hashed manifest, and
runs the DLL-linked driver:

```powershell
python engine/tools/windows_fixture.py generate --output-dir ../validation-fixtures/example --size 900
python engine/tools/windows_fixture.py run --driver ../build-windows-migration/engine/spk_render_fixture.exe --resources ../build-windows-migration/engine/resources --fixture-dir ../validation-fixtures/example --output-dir ../validation/example
```

`generate` refuses to replace an existing fixture; `run` refuses to replace
existing outputs. `run.json` records the actual binary, resource, input,
parameter and output hashes and always leaves external parity unverified.
`compare` accepts a separate encoded float RGB `.npy` reference or packed
RGBA16 `.rgba16`, and a provenance JSON file. Its metadata must bind the input,
parameters, output colour/transfer contract, common baked resources, artifact
hash and nonempty producer/version/backend. Backend shaders are excluded from
the common baked fingerprint so Metal and Vulkan can use the same material
data. See `compare_fixture` for the exact metadata keys. The tool checks the
declared contract; the external origin must still be established independently.

The comparison preserves `parity_render.py`'s `3e-5` absolute threshold and
the `1e-5` fraction of RGB values differing by more than one 16-bit count.
Constructed comparator tests are not evidence that a real frame passed parity.

Existing parity scripts now accept `--resources`; the ctypes-based scripts
also accept `--library` (`--dylib` remains an alias). The environment overrides
are `SPEKTRAFILM_ENGINE_LIBRARY` and `SPEKTRAFILM_ENGINE_RESOURCES`. A selected
Windows DLL discovers its adjacent `resources` directory. Python/Metal parity
still needs the matching external reference checkout or outputs.

## Actual RAW execution gate

After default synthetic rendering passed, the existing `test-raw.ARW` was
decoded with rawpy 0.27.1 / LibRaw 0.22.1 in the workspace-only dependency
directory. `tools/rawpy_to_f32.py` pins AHD, camera WB, linear ProPhoto, 16-bit
output, RAW orientation, disabled auto-bright and disabled data-dependent
maximum adjustment. Black/white scaling stays enabled. The original RAW hash
is unchanged. The script refuses overwrites and writes a SHA-bound sidecar.
This is a Python fixture bridge, not native C++ RAW support. Its integer output
clips/quantises to [0, 1]; negative RGB and highlight headroom are not retained.

`tools/windows_render_matrix.py` validates that sidecar, actual resolved
parameters and every returned full image's dimensions before reading pixels.
It writes tight encoded-sRGB RGBA16, sRGB-tagged 8-bit previews and provenance
JSON. The actual 1172×1757 ARW input passed six cases: baseline, default,
simple grain, boost, black/white correction and EDR. Full 4688×7028 input
passed baseline/default, repeats and deterministic cached-negative reprints.
The pre-optimization default first/repeat wall time was 48.08/45.75 seconds.
See the current phase-2 milestone above for current measurements. These
executions do not establish external colour parity.

Example after decoding a fresh input (requires NumPy and Pillow):

```powershell
python engine/tools/windows_render_matrix.py --input ../validation-fixtures/raw-arw-full/input.f32 --width 4688 --height 7028 --input-metadata ../validation-fixtures/raw-arw-full/input.f32.json --library ../build-windows-migration/engine/spektrafilm_engine.dll --resources ../build-windows-migration/engine/resources --output ../validation/new-full-run --cases baseline default --repeat --reprint --preview
```

The current results are in `../validation/migration-phase2/raw-arw-full/report.json`
and `../validation/migration-phase2/raw-arw-4/report.json`; previous results
remain at their original paths. Previews are at most 1280 pixels per
edge; use RGBA16 for pixel/grain evidence. The separate C++ fixture driver
remains the result-lifetime gate.

## Next implementation work

1. Compare a representative deterministic frame with Metal and the Python
   oracle, including node outputs where the first discrepancy occurs. The
   current analytic tests include a float64 CAM16 comparison but are not a
   substitute for full parity. Decide on one shared shader source before
   maintaining two complete shader suites.
2. Extend validation of remaining untested parameter and stock combinations;
   geometry, stock-LUT preview and DI now have direct numerical and C ABI gates.
3. Keep whole/stripe parity and the new FIR boundary tests as regression gates.
   Defer command batching and kernel optimization until a new measured
   requirement justifies them; preserve the free-and-idle rule.
4. Implement a native Vulkan result image only when a Windows display layer
   needs one. The current backend uses device-local compute buffers and ordinary
   persistent storage; it does not implement Metal's file-backed optimization.
5. Replace the external RAW fixture bridge with a native C++ LibRaw reader,
   including a deliberate policy for negative RGB and highlight headroom.
   Keep decoder differences separate from physical-pipeline parity.
