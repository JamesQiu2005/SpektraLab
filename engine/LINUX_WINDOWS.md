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

Tools: CMake >= 3.20, Ninja, a C++20 compiler (gcc 13 tested),
`glslangValidator`, Python 3 (setup scripts and tests only, standard library).
Ubuntu 24.04: `apt install build-essential cmake ninja-build glslang-tools
libvulkan1 mesa-vulkan-drivers` (the last two give the lavapipe CPU device).
Cross-compiling adds `g++-mingw-w64-x86-64-posix` and, to test, `wine` and
`xvfb`.

## 2. Linux

```bash
engine/build-linux.sh            # deps, configure, build, stage build/host-linux-x64/
engine/build-linux.sh --test     # + ctest + host smoke against the staged host
```

By hand:

```bash
engine/setup-deps.sh
cmake -S . -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release \
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

## 3. Windows x64, cross-compiled from Linux

```bash
engine/build-windows-cross.sh          # stages build/host-win-x64/spektralab-host.exe
engine/build-windows-cross.sh --test   # + the host smoke under wine (xvfb-run when headless)
```

`engine/cmake/toolchain-mingw-w64.cmake` selects the **posix**-thread MinGW-w64
compilers (the host and engine use `std::thread`). libstdc++, libgcc and
winpthread are linked statically; the script fails if the exe imports any DLL
but the system's (today: KERNEL32, SHELL32, WS2_32, msvcrt). SPIR-V is compiled
by the build machine's glslang and is platform-neutral.

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

## 6. What is not there

- The five refused features (contrast mask, scene latitude mapping, Cineon
  DI, overscan/film edge, date back): `PORT_PLAN.md`.
- Lens correction at decode (LibRaw has no lens profiles).
- Verified real-GPU runs on Linux, and runs on real Windows: only lavapipe
  and wine here. The original Windows port's RTX acceptance predates main's
  later commits and this branch's backend changes (`PORT_COVERAGE.md` §5).
