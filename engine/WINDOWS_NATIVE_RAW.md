# Native Windows RAW and TIFF host

`spk_raw_render.exe` decodes a RAW file with LibRaw, calls the existing engine
C API, and writes RGB16 TIFF with an embedded sRGB ICC profile. LibRaw and
the engine are statically linked into the host. Python/rawpy are test tools
only. File I/O remains outside the pixel-input/pixel-output engine API.

The default policy is `compatible16`. `headroom` is an explicit experimental
alternative; neither mode silently falls back to the other. Bundled LibRaw
does not support Nikon HE/HE* decoding.

## Build and run

Follow [WINDOWS.md](WINDOWS.md) for the MinGW/Vulkan toolchain and dependency
setup. From the repository root, using your own input RAW:

```powershell
& .\engine\build-windows.ps1 -Desktop:$false
New-Item -ItemType Directory -Path build/exports -Force | Out-Null
& .\build\windows\engine\spk_raw_render.exe `
    --input '..\samples\sample.ARW' `
    --output .\build\exports\sample.tif `
    --report .\build\exports\sample.json `
    --resources .\build\windows\engine\resources
```

Replace `../samples/sample.ARW` with a supported RAW you supply. Output parent
directories must exist. Output files, including reports, must not already
exist; use new names on later runs. Unicode input, parameter and output names
are supported. The engine resource directory's complete path currently must
contain ASCII characters only.

Optional arguments:

| Argument | Meaning |
|---|---|
| `--params file.json` | Flat C API parameter delta, for example `{"film_stock":"kodak_portra_400","print_exposure":1.2}` |
| `--decode-mode compatible16` | Explicitly select the default decode policy |
| `--decode-mode headroom` | Use the restricted expanded-range RGB conversion described below |
| `--decoded-output file.f32` | Save oriented, packed RGB float32 for testing; dimensions and colour contract are in the report |

Omitting a parameter file retains default grain, glare and automatic
exposure. A decoded dump adds I/O and should be omitted from ordinary timing.
The [Win32 viewer](WINDOWS_DESKTOP.md) uses the same decoder and TIFF writer.

## Dependency and deployment

The dependency is official [LibRaw 0.22.2](https://github.com/LibRaw/LibRaw/releases/tag/0.22.2),
using the [fixed source archive](https://codeload.github.com/LibRaw/LibRaw/zip/refs/tags/0.22.2)
with SHA-256 `02275a04cf0d1477ab9fd7ee231ddea59e7b14497458da6e3ba957517d6655c7`.
`setup-libraw.ps1` verifies it before extraction. CMake does not fetch mutable
dependencies. Build manifests record source and runtime hashes.

The build selects LibRaw's LGPL-2.1 licence option and deploys `LICENSE.LGPL`
and `COPYRIGHT` under the output's `third-party/LibRaw` directory. Preserve
licence notices and corresponding source/build instructions when distributing
binaries. Optional RawSpeed, DNG SDK, JPEG and LCMS decoder extensions are
not enabled.

Deployment needs the executable, its adjacent MinGW runtime DLLs, complete
resources and licence notices. Vulkan is supplied by the GPU driver. The
native CLI does not require Python, a LibRaw DLL, the compiler or the source
checkout at runtime. The shared engine DLL is used by regression tools that
explicitly load it.

## Default decode contract

`compatible16` matches the test bridge in `tools/rawpy_to_f32.py`:

- Full-size decode, requested AHD (`user_qual=3`), valid camera/as-shot WB,
  default RAW orientation, ProPhoto output (`output_color=4`), identity gamma.
- Sixteen-bit output, `highlight=0`, `bright=1`; automatic brightness and
  data-dependent maximum adjustment are disabled.
- Automatic scaling remains enabled: disabling it also skips white balance.
  No user black/white overrides, exposure shift, ICC transform or resize.
- Oriented uint16 samples become `float(double(value)/65535)`.

LibRaw may choose a sensor-specific demosaic instead of AHD for other sensor
patterns. The requested algorithm does not prove AHD was used for every
camera. Invalid camera WB and reported corrupt data are rejected.

This compatibility path clips and quantises before producing float storage.
It does not preserve negative RGB or values above one and is not an all-float
RAW pipeline. Reports distinguish source black/white levels, WB, orientation,
post-scale multipliers and repeated black patterns. The source
`as_shot_wb_applied` flag is separate from the WB applied during this decode;
ordinary Bayer data can report false and still use camera WB.

## Opt-in headroom

The experimental policy accepts conventional three-colour 2×2 Bayer data with
square pixels, without pre-applied WB or special Fuji rotation. It rejects
sRAW, X-Trans, Foveon, floating-point RAW and other unsupported layouts.

LibRaw uses `highlight=1`, normalising WB by its largest component before
uint16 demosaicing. The host captures LibRaw's actual camera-to-ProPhoto
matrix and evaluates it without the uint16 output clipping step. It restores
the compatibility exposure convention with `1 / min(applied WB)`, including
the second green component, and retains fractional, negative and above-one
RGB values. All eight orientation encodings are handled on the float output.

Black subtraction and demosaicing still quantise or clip. Sensor saturation
and below-black samples are not reconstructed. AHD decisions can change with
input scaling, so unsaturated pixels need not match `compatible16` byte for
byte. This is a change to the input policy, not to the film model or shaders.
Final TIFF output remains SDR sRGB after the film pipeline.

Reports include the mode, actual matrix, exposure restoration and preservation
scope, with explicit `float_demosaic=false` and
`sensor_saturation_reconstructed=false` flags. The positive full-camera gate
currently uses a Sony ARW; wider camera acceptance is pending.

## Export and file safety

The host enforces linear ProPhoto input, encoded sRGB output and EDR disabled.
Conflicting parameter files are rejected before decode. The writer preserves
RGB16 samples, removes opaque alpha, and embeds the pinned
`resources/io/sRGB.icc`. TIFF is classic little-endian, uncompressed,
top-left-oriented, with strips of at most 64 rows. Files outside classic
TIFF's 32-bit offset limits are refused.

RAW and existing output files are never opened for writing. New outputs are
staged beside their destinations and published without replacement; ordinary
failures and publication races clean up this run's owned files. This does not
provide a multi-file transaction across power loss or a system crash.

Display P3/ProPhoto TIFF, HDR metadata, EXIF copying and DI file packaging are
not implemented by this host. Receiving DI pixels through the engine API does
not imply a corresponding file export is available.

## Nikon HE/HE* limitation

A tested Nikon Z8 HE* sample has a 5408×3608 stored plane, 14-bit data,
compression code 14 and payload prefix `ff 10 ff 50`. LibRaw 0.22.2 selects
`nikon_he_load_raw()`, whose bundled implementation rejects the format.
TIFF compression tag 34713 alone does not distinguish HE from ordinary NEF.

This sample has metadata and rejection coverage only: no successful Nikon
decode, render or speed result is claimed. An embedded JPEG is never used as
a replacement. Nikon positive testing needs a supported lossless-compressed
NEF, a separately validated RAW DNG conversion, or a future decoder integration.

## Reproduce validation and timing

The native CTests cover TIFF tags/pixels/ICC and cleanup, errors in both decode
modes, metadata-only linkage, and headroom colour/scale/orientation math.
Full-frame tools use Python 3.11+, NumPy, Pillow and rawpy only as independent test drivers.
Supply your own camera files; the original developer RAWs and full renders
are not included in this repository.

Create a full-size compatibility fixture, then verify native decoding and TIFF
against it. The fixture's `.json` sidecar binds its original RAW and settings:

```powershell
New-Item -ItemType Directory -Path build/validation -Force | Out-Null
python engine/tools/rawpy_to_f32.py `
    '../samples/sample.ARW' build/validation/input.f32 --downsample 1
python engine/tools/windows_native_raw.py `
    --driver build/windows/engine/spk_raw_render.exe `
    --library build/windows/engine/spektrafilm_engine.dll `
    --resources build/windows/engine/resources `
    --input '../samples/sample.ARW' `
    --fixture build/validation/input.f32 `
    --fixture-metadata build/validation/input.f32.json `
    --output build/validation/native-raw
```

Compatibility equality is strict, not silently loosened for differing decoder
versions. A recorded full 4688×7028 Sony ARW matched rawpy 0.27.1 / LibRaw
0.22.1 byte for byte against native LibRaw 0.22.2. This does not establish
equality for other samples or versions. The test also independently reads the
TIFF and compares it with deterministic engine output, checks Unicode names,
standalone deployment and error/rollback cases.

`tools/windows_raw_headroom.py` provides a separate full-frame oracle: oriented
camera RGB16 from rawpy, a NumPy float64 matrix reference and an independent
ProPhoto16 decode. On the recorded Sony sample its maximum float error was
`2.31e-7`, with at most one ProPhoto16 count of quantisation difference.
Use `--help` for inputs and `--rawpy-path` when rawpy is installed in a separate
test directory. No tolerance against an external Metal film render is implied.

Measure the complete native flow in fresh processes without decoded dumps:

```powershell
python engine/tools/windows_native_raw_benchmark.py `
    --driver build/windows/engine/spk_raw_render.exe `
    --resources build/windows/engine/resources `
    --input '../samples/sample.ARW' `
    --output build/validation/raw-benchmark --processes 3
```

The report separates RAW open/unpack/process/conversion, engine creation,
input upload, complete render/readback, TIFF writing and process wall time.
`total_before_publish` excludes final publication/teardown and is not total
process time. Driver and filesystem caches are not cleared. Cross-camera
coverage, Core Image decode comparison and external Metal/Python film-model
parity remain incomplete.
