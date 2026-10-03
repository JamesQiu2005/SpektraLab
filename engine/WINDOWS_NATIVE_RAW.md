# Native Windows RAW host (2026-10-03)

The opt-in `--decode-mode headroom` policy is now implemented alongside the
unchanged default `compatible16`. Its scope and verification are described
below. Nikon HE/HE* NEF remains unsupported by bundled LibRaw and receives an
explicit diagnostic before unpacking.

`spk_raw_render.exe` opens a RAW file with LibRaw, calls the existing engine C
API, and writes a 16-bit RGB TIFF with an embedded sRGB ICC profile. The host
statically links LibRaw and the engine. Python/rawpy are test tools only.
The engine itself still accepts pixels and returns pixels; its public API,
film/paper data, shaders and colour mathematics were not changed in this step.

## Build and run

```powershell
& .\engine\setup-libraw.ps1
& .\engine\build-windows.ps1 -NativeRaw
& ..\build-windows-desktop\engine\spk_raw_render.exe `
    --input ..\test-raw.ARW `
    --output ..\rendered.tif `
    --report ..\rendered.json `
    --resources ..\build-windows-desktop\engine\resources
```

Output parent directories must exist. Existing files are refused, including
reports; select a new name for another run. RAW, params and output filenames
support Unicode (tested with Chinese, spaces and a non-BMP emoji). The engine
resource directory still requires an ASCII path; the host explicitly rejects
unsupported resource paths. The minimal Windows GUI is now available; see
[WINDOWS_DESKTOP.md](WINDOWS_DESKTOP.md). Visible-window and monitor colour
validation remain separate from RAW/TIFF correctness.

Optional `--params file.json` accepts the same flat parameter delta as the C
API, such as `{"film_stock":"kodak_portra_400","print_exposure":1.2}`.
Omitting it retains default grain, glare and automatic exposure. Optional
`--decoded-output file.f32` saves packed, top-down RGB float32 pixels after RAW
orientation, for testing; dimensions and colour contract are in the report.
This dump increases I/O and is excluded from ordinary end-to-end benchmarks.

The pinned dependency is official LibRaw **0.22.2**:
https://github.com/LibRaw/LibRaw/releases/tag/0.22.2

Archive: https://codeload.github.com/LibRaw/LibRaw/zip/refs/tags/0.22.2

SHA-256: `02275a04cf0d1477ab9fd7ee231ddea59e7b14497458da6e3ba957517d6655c7`.
`setup-libraw.ps1` checks the archive before extraction; CMake does not download
dependencies. Source/tool/runtime hashes are recorded in `toolchain.json`.
The static build uses LibRaw's LGPL-2.1 license option; its LICENSE.LGPL and
COPYRIGHT are deployed in `engine/third-party/LibRaw`. Retain these notices and
the corresponding source/build instructions when distributing binaries.
Optional RawSpeed/DNG SDK/JPEG/LCMS decoder extensions are not enabled. The
provided Sony ARW has received full decode/render/export tests. The supplied
Nikon Z8 HE* NEF has received metadata and rejection tests only; it cannot be
used to claim successful Nikon rendering or timing.

Runtime deployment needs the executable, the three adjacent MinGW runtime
DLLs, the complete resources directory and third-party notices. Vulkan is
provided by the installed GPU driver. The engine DLL is used by regression
tools, but the native executable does not import it. No Python, LibRaw DLL,
compiler or source checkout is needed to execute the native host.

## Default compatibility decode and export contracts

This first implementation intentionally matches the existing reference bridge:

- Full-size decode; requested AHD (`user_qual=3`), camera/as-shot white balance,
  default orientation, ProPhoto output (`output_color=4`), identity gamma.
- `output_bps=16`, `highlight=0`, `bright=1`, automatic brightness disabled,
  automatic maximum adjustment disabled, automatic scaling enabled. Scaling
  must remain enabled: `no_auto_scale=1` also skips white balance.
- No user black/white overrides, exposure shift, ICC conversion or resize.
- Convert the final oriented uint16 channels with `float(double(value)/65535)`.
  Other sensor patterns may cause LibRaw to choose a different demosaic method;
  the requested algorithm alone is not proof of AHD on every camera.

**This is a clipped 16-bit compatibility path, not a floating-point RAW
pipeline.** Negative RGB and RGB above one have already been lost before the
engine sees float32 pixels. The report explicitly marks both as not preserved.
Missing/invalid camera WB and corrupt decode data are rejected, not silently
replaced with an automatic WB result.

Metadata distinguishes RAW black/white levels, per-channel WB, orientation and
normalised post-scale WB multipliers. `source_as_shot_wb_applied` describes a
LibRaw source-data flag, not completion of this render's WB: ordinary Bayer
RAW can legitimately report false and still use non-unity camera WB. The black
level report keeps common+channel values and a separate repeated spatial
pattern; rawpy sometimes folds that pattern into four values.

The host enforces linear ProPhoto input and encoded sRGB output, with EDR off.
Conflicting parameter files are rejected before decode. The TIFF writer does
not transform pixels: it strips opaque alpha, preserves RGB16 values, and
embeds the fixed `resources/io/sRGB.icc` bytes. It uses classic little-endian
TIFF, no compression, top-left orientation and strips of at most 64 rows.
File sizes outside classic TIFF's 32-bit limits are refused. DI export,
Display P3/ProPhoto TIFF, HDR metadata and EXIF copying are not implemented.

Outputs are staged beside their destination and published without replacement.
Open file handles allow cleanup of this run's outputs after ordinary failures,
including a rename race with an existing destination. This is not a transaction
across a system crash/power loss. The input file and existing outputs are never
opened for writing.

## Opt-in headroom policy

Add `--decode-mode headroom` to the native command to enable expanded RGB
conversion. `--decode-mode compatible16` explicitly selects the default mode.
Unknown or repeated mode arguments are refused; neither mode silently falls
back to the other. The new build lives in `../build-windows-raw-headroom`; the
previous native RAW build and archive remain available for regression.

The experimental mode is limited to conventional three-colour, 2x2 Bayer
input with square pixels, without pre-applied WB or special Fuji rotation.
sRAW, X-Trans, Foveon, floating-point RAW and unsupported layouts are refused.
The existing ARW is the real-camera positive fixture; broader camera coverage
is still pending.

LibRaw runs `highlight=1` with WB normalised by its largest component, keeping
the WB scale at or below one during uint16 demosaicing. At its RGB conversion
boundary the host uses the actual LibRaw camera-to-ProPhoto matrix, then
restores the compatibility exposure convention by `1 / min(applied WB)`
(including the second green component). It preserves the resulting fractional,
negative and above-one RGB values rather than applying LibRaw's uint16 output
clipping. All eight orientation encodings are handled on the float output.

This is **uint16 demosaicing followed by float RGB conversion**, not an
all-float RAW pipeline. Black subtraction and demosaicing still quantise/clip;
sensor saturation and below-black sensor samples are not reconstructed. AHD
can make different decisions when its input scale changes, so even unsaturated
pixels need not equal `compatible16` byte for byte. This is an explicit input
policy change, not a shader or material-model change. Final TIFF remains SDR
encoded sRGB RGB16; expanded scene values are processed by the film pipeline,
not directly stored as HDR TIFF values.

Reports include `decode.mode`, the actual matrix, WB restoration factor,
`preservation_scope`, and explicit `float_demosaic=false` /
`sensor_saturation_reconstructed=false` flags. The full-size independent gate
`tools/windows_raw_headroom.py` obtains oriented camera RGB16 with rawpy,
computes a NumPy float64 matrix reference, then independently decodes ProPhoto
RGB16 to check the reported transform. The mathematical CTest separately uses
fixed colour/grey/negative/highlight examples and explicit eight-way grids.

## Nikon HE/HE* limitation

The user's `test-raw.NEF` identifies as Nikon Z8, with a 5408 x 3608 stored RAW
plane (19,512,064 samples), 14 bits and Nikon compression code 14 (HE*).
Its RAW payload starts with `ff 10 ff 50`. TIFF compression 34713 alone is not
enough to classify HE because ordinary Nikon compression shares that tag.

LibRaw 0.22.2 selects `nikon_he_load_raw()` and its implementation refuses
this format. The [official supported-camera list](https://www.libraw.org/supported-cameras)
explicitly excludes Z8 HE/HE*. This is not a missing build switch: the bundled
source decoder is a stub. No embedded JPEG is used as a substitute. Testing
this camera's full RAW path needs a lossless-compressed NEF, a separately
validated RAW DNG conversion, or a future supported decoder integration.
`tools/windows_raw_unsupported.py` verifies the metadata, source hash and
clean rejection across modes and Unicode paths. No rendering speed is reported
for this file.

## Evidence and timing

`../validation/native-raw-phase3/` retains the previous source/DLL/resources,
native comparison reports, default end-to-end measurements and exported TIFFs.
The full 4688 x 7028 ARW decoded float data is byte-identical to the existing
rawpy 0.22.1 fixture despite the native decoder using LibRaw 0.22.2. That result
applies to this sample, not every camera/version combination.

`tools/windows_native_raw.py` independently reads the TIFF tags and full uint16
pixel data, compares it to the C ABI deterministic result, checks ICC equality,
and runs the executable from a copied directory with a system-only PATH.
Chinese/emoji filenames and 23 rejection cases are covered, including corrupt
ICC cleanup and rollback after two outputs have already been published. CTest additionally
covers TIFF partial-write cleanup and five RAW decoder error paths.

`tools/windows_native_raw_benchmark.py` measures three independent processes,
default effects retained. RAW open/unpack/process/float conversion, engine
creation, input open/upload, complete render with CPU readback, TIFF writing,
and whole-process wall time are kept separate. `engine_render` is the engine's
complete call timing, not a sum of GPU nodes. `total_before_publish` omits final
publication/teardown and must not be used as whole-process time. Driver and OS
file caches are not cleared. There is no decoded float dump in these timings.

The remaining RAW work is broader headroom-policy and camera-format validation,
HE/HE* decoder integration, and Core Image comparison. LibRaw's usual
postprocessing/demosaic operates on uint16 planes, so a float camera-to-ProPhoto
matrix alone would not make the pipeline fully floating point. Any future
extension must state where clipping/quantisation remain and keep this compatible
mode as a regression option. External Metal/Python film-model parity also
remains outstanding.
