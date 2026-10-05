# Windows build and validation

The Windows port uses the existing C++20 film/print pipeline with a Vulkan
compute backend. It includes a native RAW-to-TIFF command-line host and a
minimal Win32 viewer, plus a Qt Quick editor. These executables do not require Python at runtime. The
macOS `build.sh`, Metal implementation and Xcode frontend retain their own
build paths.

The port began at `8a3187434ced21253940f84c746b94128860a2f8` and is integrated
with the author's `Windows_Port` starting point, `61bfc49a38e92b9d7915754982de3af13245403f`.
Capabilities that have not been explicitly ported remain unsupported. Passing the local
tests does not establish whole-image equivalence with Metal or the external
Python film-model reference.

- [Native RAW and TIFF contracts](WINDOWS_NATIVE_RAW.md)
- [Minimal Win32 viewer](WINDOWS_DESKTOP.md)
- [Qt Quick editor and its separate build](../windows_UI/README.md)
- [Implemented and tested feature coverage](WINDOWS_FEATURE_COVERAGE.md)

## Requirements and build

The validated toolchain is 64-bit MinGW GCC 15.2 and CMake/CTest 3.25.0 on
Windows, with an NVIDIA GeForce RTX 5070 Ti. MSVC and other GPU vendors have
not completed the same acceptance tests.

Install a C++20 MinGW compiler, CMake/CTest and Vulkan development tools. Put
the compiler and CMake tools on `PATH`; the build wrapper can find
`mingw32-make.exe` beside the compiler. Vulkan needs headers, a shader compiler
(`glslangValidator`) and an installed GPU driver. An installed Vulkan SDK can
be selected through `VULKAN_SDK`; every tool path can also be supplied
explicitly. With MinGW, the Windows Vulkan loader DLL can be used as linker
input when no SDK import library is supplied.

Run commands from the repository root:

```powershell
$build = Join-Path (Get-Location) 'build/windows'
$deps = Join-Path (Split-Path (Get-Location) -Parent) 'deps'
& .\engine\setup-libraw.ps1 -DependencyDirectory $deps
& .\engine\build-windows.ps1 `
    -BuildDirectory $build `
    -LibRawSourceDirectory (Join-Path $deps 'LibRaw-0.22.2')
```

`setup-libraw.ps1` downloads and verifies a fixed official source archive; it
does not install a system-wide library. CMake itself does not download it.
The wrapper builds, deploys adjacent MinGW runtime DLLs, runs CTest, and writes
`toolchain.json` containing source, shader, dependency and executable hashes.
A failed run records failure instead of leaving an old success manifest.

The wrapper defaults to this checkout's `build/windows` directory. Use a
different `-BuildDirectory` when preserving an earlier baseline or building
another checkout. Do not reuse a CMake directory configured for another
source tree. `-Fresh` requires CMake 3.24 or newer; the project itself requires
CMake 3.20 or newer.

Useful options:

| Option | Effect |
|---|---|
| `-Desktop:$false` | Build the native RAW CLI and engine without the Win32 viewer |
| `-NativeRaw:$false` | Build the pixel-input engine and its tests; also disables the viewer |
| `-Compiler`, `-MakeExecutable` | Select the MinGW compiler and make program |
| `-CMakeExecutable`, `-CTestExecutable` | Select the configure/build and test tools |
| `-VulkanIncludeDirectory`, `-VulkanLibrary`, `-GlslangExecutable` | Select Vulkan development tools explicitly |
| `-LibRawSourceDirectory` | Use an already extracted, verified LibRaw 0.22.2 tree |

Direct CMake configuration supports `SPEKTRALAB_BUILD_NATIVE_RAW`,
`SPEKTRALAB_BUILD_DESKTOP` and `SPEKTRALAB_LIBRAW_SOURCE`.
`SPEKTRALAB_REQUIRE_VULKAN=ON` makes missing Vulkan tools a configuration
failure; without it, CMake can build only the portable core. The wrapper
always requires Vulkan. Generated SPIR-V and binaries stay in the build
directory; tracked baked resources do not need regeneration.

## Runtime and result ownership

Build outputs are in `build/windows/engine`. The native CLI is
`spk_raw_render.exe`, the minimal viewer is `SpektraLab.exe`, and regression
tools use `spektrafilm_engine.dll`. Keep each executable's adjacent runtime
DLLs, complete `resources` directory and licence notices when moving it.
The native hosts statically link the engine and LibRaw; the shared engine DLL
is still needed by tools that explicitly load it. Vulkan comes from the GPU
driver.

On Windows, `spk_result.rgba16` points to an independently owned CPU RGBA16
result. `texture` is its opaque ownership handle, **not a drawable Vulkan
image**. Respect `row_stride_px` and release with `spk_result_free`. Previously
returned results remain valid after further renders and after their session
or engine is destroyed. Existing public C API signatures are unchanged; the
three additional upstream entry points are exported, bringing the total to 28.

Compute planes and caches use device-local GPU memory. Explicit upload,
device-copy and readback operations use staging buffers; readback prefers
host-cached memory. Transfers and dispatches remain synchronous with explicit
dependencies. The original per-node flush policy remains in place. Staging
capacity is tracked separately from the engine's pool ledger; neither ledger
is a measurement of physical peak VRAM.

## Reproduce the local gates

The integrated Win32 build passed **16 CTest tests**. The backend-only build
has 11, and the native RAW build without desktop has 15. These cover schema,
setup, GPU math and transfers, geometry, LUT/DI, C ABI ownership, TIFF, RAW
error handling, headroom math, metadata-only LibRaw linkage and desktop
conversion/viewport boundaries. The default desktop CTest does not open a
visible window or require a private RAW fixture.

```powershell
ctest --test-dir build/windows --output-on-failure
```

Python 3.11 or newer is optional test tooling. With NumPy and Pillow available, run the
portable tool tests and a generated deterministic engine fixture:

```powershell
python -m unittest discover -s engine/tests -p 'test_*.py'
python engine/tools/windows_fixture.py generate `
    --output-dir build/validation/fixture --size 180
python engine/tools/windows_fixture.py run `
    --driver build/windows/engine/spk_render_fixture.exe `
    --resources build/windows/engine/resources `
    --fixture-dir build/validation/fixture `
    --output-dir build/validation/fixture-run
python engine/tools/windows_features.py `
    --library build/windows/engine/spektrafilm_engine.dll `
    --resources build/windows/engine/resources `
    --output build/validation/features
```

The recorded Python tool gate passed 47 tests. Test outputs must use fresh
paths: the fixture and integration tools intentionally refuse overwrites.
Generated manifests bind inputs, resolved parameters, binaries, resources and
outputs by hash. Their reports explicitly distinguish local execution from
external parity.

For camera-input tests, supply your own supported RAW and follow
[WINDOWS_NATIVE_RAW.md](WINDOWS_NATIVE_RAW.md). Private RAWs and full-size
developer render outputs are not distributed with this repository.

## Correctness and performance boundaries

The Vulkan port contains 34 registered kernels, including two diagnostic
probes. The independent IIR, resample, geometry and LUT/DI tests compare with
analytic or float64 references. Grain tests check exact Philox integers and
distribution moments; they do not establish equality of every seeded Metal
Poisson draw. Exact repeated-image comparisons disable stochastic effects.
Default-effect rendering is exercised separately with grain, glare and
automatic exposure enabled.

A FIR boundary repair avoids GLSL signed remainder on negative coordinates.
The old implementation produced incorrect edge values in both whole frames
and stripes. Its output is deliberately **not** the current pixel baseline.
The corrected shader passes 144 exact boundary cases, 35 deterministic
whole/stripe/reprint combinations and a full-size ARW stripe comparison.
Material data and baked LUTs were unchanged. Stochastic stripe combinations
and external whole-image parity still need broader validation.

Recorded developer measurements on 2026-10-03 used a 4688×7028 (32.95 MP)
decoded ARW and default effects, across three processes with one first full
render, five warm full renders and five cached reprints each:

| Complete render call | Median | Range |
|---|---:|---:|
| First full | 871.41 ms | 864.83–873.88 ms |
| Warm full | 229.30 ms | 227.10–232.89 ms |
| Cached reprint | 66.72 ms | 65.33–73.46 ms |

These calls include negative-cache handling and owned CPU RGBA16 delivery.
They exclude RAW decoding, engine creation, input upload and file export.
They are historical measurements for that input and GPU, not a portable
performance guarantee or a matched 45 MP Nikon/Mac comparison. Use
`tools/windows_performance.py --help` to repeat the protocol on your own
decoded fixture. Native RAW timing is covered separately in the RAW guide.
Do not replace complete-call timing with a sum of GPU node measurements.

Formal timing disables verbose diagnostics. For a separate diagnostic run,
`SPEKTRAFILM_TRANSFER_TIMINGS=1` logs memory types, transfer byte counts,
elapsed time and staging capacity. It is disabled by default.

The existing parity entry points accept `--resources`; ctypes-based entry
points also accept `--library` (`--dylib` is an alias). Environment overrides
are `SPEKTRAFILM_ENGINE_LIBRARY` and `SPEKTRAFILM_ENGINE_RESOURCES`. External
Metal/Python film-model parity requires a matching reference checkout or
independently produced outputs; the local gates do not provide that oracle.
