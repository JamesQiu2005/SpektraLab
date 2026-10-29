# The engine on Linux and Windows: build, cross-compile, test, run the host

The macOS app builds the engine with `engine/build.sh` and Xcode and reads
nothing here. Off Apple the engine is the same C++ (`src/core`,
`src/pipeline`) with a Vulkan backend (`src/gpu/vulkan_gpu.cpp`, kernels in
`src/shaders/vulkan/*.comp`), LibRaw for RAW decode, and **`spektralab-host`**
(`engine/host/`), the process the Tauri desktop app (`desktop/`) talks to over
`desktop/HOST-PROTOCOL.md`.

Related documents:

- `engine/PORT_COVERAGE.md` -- what of the API spec runs on Vulkan, what is
  refused, what was verified and how.
- `engine/PORT_PLAN.md` -- the handoff for the five refused features.
- `engine/PORT_NOTES.md` -- the running log of this port.
- `engine/WINDOWS.md`, `WINDOWS_DESKTOP.md`, `WINDOWS_NATIVE_RAW.md`,
  `WINDOWS_FEATURE_COVERAGE.md` -- the original Windows port (native MSVC/MinGW
  builds with `build-windows.ps1`, the Win32 viewer, its acceptance on an RTX
  5070 Ti). Still valid for a native Windows build; the cross-build below is
  the path the desktop app packages.

## 1. Dependencies

All pinned and verified, fetched into the gitignored `build/deps` by
`engine/setup-deps.sh` (nothing is downloaded by CMake):

| | version | licence | how it is used |
|---|---|---|---|
| LibRaw | 0.22.2 (zip SHA-256 or git commit + tree id) | LGPL-2.1 (of LGPL/CDDL) | built from source, linked statically |
| Vulkan-Headers | vulkan-sdk-1.4.341.0 | Apache-2.0 OR MIT | compile time only |
| volk | vendored, `third_party/volk` | MIT | loads `libvulkan.so.1` / `vulkan-1.dll` at run time -- no SDK import library, and a machine without a driver gets an error message, not a loader failure |
| stb_image / stb_image_write / stb_truetype | vendored, `third_party/stb` | public domain / MIT | JPEG/PNG decode, PNG/JPEG encode, deflate |
| libheif / libde265 | 1.23.6 / 1.1.3 | LGPL-3.0 | static SDR HEVC photograph decoder |
| OpenEXR / Imath | 3.5.2 / 3.2.3 | BSD-3-Clause | static flat RGB/Y floating-point input |
| LittleCMS | 2.19.1 | MIT | RGB LUT ICC input conversion |
| Lensfun / GLib | pinned `43f9e001` / 2.86.5 | LGPL-3.0 / LGPL-2.1-or-later | optional per-photo RAW lens correction; bundled calibration database CC BY-SA 3.0 |

Tools: CMake >= 3.20, Ninja, a C++20 compiler (gcc 13 tested),
`glslangValidator`, Python 3.12+ (setup scripts and tests only, standard library).
Lens dependencies additionally require Meson 1.9.2 and Ninja 1.13 (build tools,
not runtime dependencies). Their archive and git pins live in
`engine/cmake/lens-codecs-pins.json`; mutable Meson wraps cannot fetch during build.
Ubuntu 24.04: `apt install build-essential cmake ninja-build glslang-tools
libvulkan1 mesa-vulkan-drivers` (the last two give the lavapipe CPU device).
Cross-compiling adds `g++-mingw-w64-x86-64-posix` and, to test, `wine` and
`xvfb`.

Input codecs use `engine/setup-input-codecs.py`; exact source URLs and SHA-256
values are in `engine/cmake/input-codecs-pins.json`. The script verifies both
archives and reused source files, then builds static libraries in an isolated
directory. `build-linux.sh` and `build-windows-cross.sh` invoke it with separate
installation prefixes. A native MinGW build can prepare them as follows (put
the matching compiler tools on `PATH`):

```powershell
python engine/setup-input-codecs.py --sources build/deps/input-codecs `
  --build build/input-codecs --install build/deps/input-codecs/install `
  --generator "MinGW Makefiles" --jobs 8
```

Pass `-DSPEKTRALAB_INPUT_CODEC_PREFIX=<absolute installation path>` when
configuring the host. The installation carries dependency notices and the
owned HEIC regression fixture; `stage-host.sh` includes all notices. MinGW
validation still checks the final executable imports only system DLLs.
OpenEXR includes pinned libdeflate, OpenJPH and zstd from its source archive;
no unpinned subproject download runs during its build. Source distributions
must include the pinned archives and build instructions for the static LGPL
libraries as well as the application's corresponding source.

Prepare lens dependencies with the same compiler on PATH:

```powershell
python engine/setup-lens-codecs.py --sources build/deps/lens-codecs `
  --build build/lens-codecs --install build/deps/lens-codecs/install `
  --generator "MinGW Makefiles" --jobs 8
```

Set `SPEKTRALAB_LENS_PREFIX` to that installation. Calibration data is staged
beside engine resources and never taken from an uncontrolled system/user
database. Linux and MinGW cross scripts prepare separate installations;
these new cross paths are source-reviewed but still require Linux CI execution.

## 2. Linux

```bash
engine/build-linux.sh            # deps, configure, build, stage build/host-linux-x64/
engine/build-linux.sh --test     # + ctest + host smoke against the staged host
```

By hand:

```bash
engine/setup-deps.sh
python3 engine/setup-input-codecs.py --sources build/deps/input-codecs \
      --build build/linux/input-codecs --install build/deps/input-codecs/install-linux --generator Ninja
python3 engine/setup-lens-codecs.py --sources build/deps/lens-codecs \
      --build build/linux/lens-codecs --install build/deps/lens-codecs/install-linux --generator Ninja
cmake -S . -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DSPEKTRALAB_INPUT_CODEC_PREFIX="$PWD/build/deps/input-codecs/install-linux" \
      -DSPEKTRALAB_LENS_PREFIX="$PWD/build/deps/lens-codecs/install-linux" \
      -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON \
      -DSPEKTRALAB_REQUIRE_VULKAN=ON -DSPEKTRALAB_STATIC_RUNTIME=ON
ninja -C build/linux
(cd build/linux && ctest --output-on-failure)
```

The staged directory (`HOST-PROTOCOL.md` §4):

```
build/host-linux-x64/
  spektralab-host        # needs glibc and a Vulkan loader; libstdc++/libgcc are static
  engine/                # baked resources + vulkan/*.spv + io/sRGB.icc
  licenses/              # GPL-3.0, CC BY-SA profiles, LibRaw, stb, volk, Vulkan-Headers
```

## 3. Windows x64, cross-compiled from Linux or macOS

```bash
engine/build-windows-cross.sh          # stages build/host-win-x64/spektralab-host.exe
engine/build-windows-cross.sh --test   # + the host smoke under wine (xvfb-run when headless)
```

`engine/cmake/toolchain-mingw-w64.cmake` selects the **posix**-thread MinGW-w64
compilers (the host and engine use `std::thread`). libstdc++, libgcc and
winpthread are linked statically; the script fails if the exe imports any DLL
but the system's (today: KERNEL32, SHELL32, WS2_32, msvcrt). SPIR-V is compiled
by the build machine's glslang and is platform-neutral.

**From macOS** (verified 2026-10-29 on an Apple M6, macOS 27, Homebrew
mingw-w64 14.0.0 / GCC 15, posix threads):

```bash
brew install cmake ninja nasm pkg-config mingw-w64 glslang
python3 -m venv build/venv-tools && build/venv-tools/bin/pip install meson==1.9.2
PATH="$PWD/build/venv-tools/bin:$PATH" engine/build-windows-cross.sh
```

The same script, the same pins, the same `build/host-win-x64/` layout. Two
differences from the Ubuntu build, both visible in its log: Homebrew's MinGW
has no `libgomp.a`, so LibRaw is built **without OpenMP** (serial decode, the
same pixels; the script says so), and it links the **Universal CRT**
(`api-ms-win-crt-*.dll`, part of Windows 10 and later) where Ubuntu's MinGW
links `msvcrt.dll`. The import check is an allowlist (system DLLs and the
UCRT forwarders; `vulkan-1.dll` is never imported, volk opens it) and fails
the build when `x86_64-w64-mingw32-objdump` is missing rather than skipping.
macOS has no wine, so `--test` refuses there; the host smoke runs against a
native MoltenVK host instead (§7). Imports of the macOS-built exe:
ADVAPI32, KERNEL32, ole32, SHELL32, USER32, WS2_32 and the UCRT forwarders.

**Testing under wine.** winevulkan loads only through wine's X11 driver, so a
headless machine needs a display: `xvfb-run -a`. wine then forwards Vulkan to
the Linux loader, i.e. to lavapipe on CI. Without a display the host still
starts and answers `hello` with `backend.available: false` and
`vkCreateInstance failed (VkResult -3)`.

Unicode: paths on the wire are UTF-8; the host reads its own command line
with `GetCommandLineW`, finds its directory with `GetModuleFileNameW`, opens
every file through a wide path, and the engine opens its resources the same
way (`src/core/file_path.hpp`). The smoke test covers a non-ASCII folder and
file, and the staged directory copied under a non-ASCII name.

## 4. Tests

| | what | where |
|---|---|---|
| `spk_core_schema`, `spk_core_setup` | the portable core: schema and setup constants | ctest |
| `spk_vulkan_smoke`, `_grain`, `_pointwise`, `_resample`, `_transfer`, `_geometry`, `_lut_di` | every Vulkan kernel against float64 or exact references | ctest |
| `spk_windows_feature_boundaries` | the refused features are refused and leave the session usable | ctest |
| `spk_windows_c_abi` | a render through the shared library's C ABI | ctest |
| `spk_raw_decoder_errors`, `spk_raw_metadata_link`, `spk_raw_headroom` | LibRaw integration | ctest |
| `engine/tests/host_smoke.py` | every host method end to end, error paths, cancel, white balance, EXIF, Unicode paths; RAW files given on the command line | `python3 engine/tests/host_smoke.py --host <exe> [--resources <dir>] [--wrapper wine] [RAW...]` |

Camera files are never committed (`tests/Test_image/` is the fork's; trap
26). The smoke test writes its own PNG and TIFF; pass real RAWs to exercise
LibRaw. On lavapipe a 12 MP NEF renders its preview tier in ~8-10 s; this is
a CPU device, not a benchmark (AGENTS.md trap 17).

**lavapipe as a device.** It is accepted, and stated in
`capabilities.backend.math_mode`, with two differences from a GPU, both
handled: its `fma` is not fused (the double-float kernels then use an exact
Dekker product, so results match a fused GPU to the test bounds), and it
advertises a 128 MiB storage-buffer range (a start-up probe proves larger
buffers work on this CPU device before the engine uses them;
`SPEKTRAFILM_VULKAN_STRICT_LIMITS=1` disables that).

## 5. Running the host

```
spektralab-host [--resources <engine-dir>] [--device <index>] [--log-level error|info|debug]
```

- `--resources` defaults to `engine/` beside the executable.
- `--device` picks a Vulkan physical device by index (otherwise a discrete GPU
  wins); it sets `SPEKTRAFILM_VULKAN_DEVICE`.
- stdin/stdout carry the framed protocol; stderr is the log. EOF on stdin or a
  `shutdown` request exits 0.

A minimal client is `engine/tests/host_smoke.py` (`class Host`): write
`u32 header_len, u32 payload_len, JSON, payload`, read the same back.

## 6. Current migration boundary (2026-10-18)

Scene latitude, Cineon DI, film edge/date back, BW product stocks and per-photo
Lensfun correction are implemented and have targeted RTX 5070 Ti tests.
`WINDOWS_FULL_MIGRATION_PLAN.md` tracks broader migration and release validation.
Contrast/tone masks and HDR output remain disabled upstream as well. HEIC is
SDR HEVC input, EXR is flat RGB/Y input; unsupported variants fail explicitly.
Windows Lensfun calibration is an equivalent feature, not a claim of numerical
identity with Apple's camera-specific correction. Actual Mac/Metal, Intel/AMD,
Linux hardware and wide-gamut monitor validation remain separate gates.

## 7. Parity against Metal, on a Mac (MoltenVK)

A Mac is the only machine with both engines, so it is where Vulkan is graded
against the macOS product's Metal engine on identical input. The Vulkan
backend builds natively on macOS with `-DSPEKTRALAB_VULKAN_ON_APPLE=ON`
(every Metal/CoreText `#ifdef` then takes the portable path through
`SPK_VULKAN_BACKEND`; off by default, and nothing changes off Apple):

```bash
brew install cmake ninja glslang molten-vk vulkan-loader vulkan-headers
# the Vulkan engine, its CTests (MoltenVK)
cmake -S . -B build/mac-vulkan -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DSPEKTRALAB_VULKAN_ON_APPLE=ON -DSPEKTRALAB_REQUIRE_VULKAN=ON \
      -DSPEKTRALAB_VULKAN_HEADERS=/opt/homebrew/include
ninja -C build/mac-vulkan
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib   # volk dlopens libvulkan.1.dylib
(cd build/mac-vulkan && ctest)
# the Metal baseline: the 1.3.4 tag's own engine, untouched
mkdir -p build/metal-1.3.4 && git archive spektralab-v1.3.4 engine | tar -x -C build/metal-1.3.4
build/metal-1.3.4/engine/build.sh dylib
cp -R build/metal-1.3.4/engine/resources build/parity/res-metal
cp build/metal-1.3.4/engine/resources_product/profiles/*.json build/parity/res-metal/profiles/
# render the catalogue with each, then grade
python3 engine/tests/parity_metal_vulkan.py render \
    --library build/metal-1.3.4/engine/build/libspektrafilm_engine.dylib \
    --resources build/parity/res-metal --out build/parity/metal
python3 engine/tests/parity_metal_vulkan.py render \
    --library build/mac-vulkan/engine/spektrafilm_engine.dylib \
    --resources build/mac-vulkan/engine/resources --out build/parity/vulkan
python3 engine/tests/parity_metal_vulkan.py compare build/parity/metal build/parity/vulkan
```

The engine sets `MVK_CONFIG_FAST_MATH_ENABLED=0` on Apple before creating its
instance (RFC-014 trap 1), and asks for the portability extensions MoltenVK
needs only where the loader/driver offers them.

The native host builds the same way with `-DSPEKTRALAB_BUILD_NATIVE_RAW=ON
-DSPEKTRALAB_BUILD_HOST=ON -DSPEKTRALAB_LIBRAW_OPENMP=OFF` (Apple clang has no
OpenMP) and codec prefixes from `setup-input-codecs.py` / `setup-lens-codecs.py`
run natively; `engine/tests/host_smoke.py` and the host CTests then run against
it. This is a test configuration, not a product: the macOS product remains
`build.sh` + Xcode + Metal.

**Result, 2026-10-29** (Apple M6, MoltenVK from Homebrew, the 1.3.4 metallib):
every deterministic case -- 21 colour films incl. CineStill 800T, 8 papers,
the 4 B&W films on Multigrade IV RC, scan/DI/no-halation/no-coupler stage
taps, CineStill headroom 0/4/8 and amount 4, camera filters, exposure,
filters, auto exposure, P3 output, geometry, scene latitude, EDR, the Cineon
DI, the date back in frame -- agrees to max <= 0.38 of an 8-bit code (all but
EDR <= 0.01). Film edge canvases agree inside the picture's frame to <= 0.01
code; the edge print itself differs by typeface (declared, API-SPEC §16).
Grain and glare match statistically (in fact nearly pixel for pixel). The
negative controls the bar is set against (+0.02 EV, 2 % print exposure, +30 %
grain, a halved CineStill headroom kernel) all fail it.
