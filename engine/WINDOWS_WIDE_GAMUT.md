# Windows wide-gamut preview and I/O, 2026-10-12

This change keeps the film/paper model, float32 shader math, default effects,
and public engine C ABI. It changes the desktop post-processing path and the
implementation of RAW decoding and file encoding. Existing sidecar adjustments
are retained and interpreted in the new ProPhoto post-processing space; there
is no legacy grading mode. Non-neutral old edits can therefore look different.

## Implemented path

`LibRaw -> linear ProPhoto input -> unchanged film/paper -> device RGBA16
ProPhoto print -> encoded-domain ProPhoto post -> crop/rotation -> resize ->
display or export conversion`.

- RAW keeps LibRaw 0.22.2, AHD, white balance, and compatible16/headroom modes.
  `SPEKTRALAB_LIBRAW_OPENMP=ON` requires OpenMP and propagates consistent LibRaw
  definitions to consumers. Windows GNU also defines `LIBRAW_FORCE_OPENMP`.
  `LIBRAW_NOTHREADS` is removed. A worker scope defaults to
  `min(8, hardware_concurrency)` and restores its OpenMP settings afterwards.
  `SPEKTRALAB_RAW_THREADS` is a diagnostic override. Only one RAW decodes at once.
- The internal `spk::view` boundary retains packed 16-bit film/print pixels on
  the GPU per session and tier. Existing public C results still own independent
  CPU memory. Film changes invalidate the print; post, geometry and gamut
  changes reuse it. Identical export snapshots are filtered before engine
  parameter updates so they do not regenerate grain.
- Post adjustments use encoded ProPhoto and middle grey 0.3857, not the same
  formulas applied to linear RGB. Float32 shader work preserves the Mac-side
  intermediate clipping and 16-bit quantization points. Ordinary display uses
  matrix/transfer conversion; export retains CAM16 gamut mapping.
- `render_view` returns explicitly tagged sRGB/P3 pixels plus a request
  generation and baked geometry. The browser skips its old grade/crop. Fit
  requests bounded display pixels (at least 2560, or the actual canvas size),
  with the existing 400ms full-source update. 100% requests native pixels,
  limited explicitly by the WebGL texture limit. Stale responses and failures
  cannot replace the current edit. Crop mode requests the uncut graded frame.
- The toolbar independently saves Auto/sRGB/Display P3. Auto requires both a
  successful P3 canvas set/read and the browser's P3 screen report. Focus,
  media-query changes, resize, window move and scale changes re-evaluate it.
  Camera originals remain sRGB sources. Main view, navigator, histogram and
  thumbnails carry their display encoding. This is SDR preview, not output
  gamut soft-proofing, HDR, a 10-bit guarantee, or a ProPhoto browser canvas.
- `export_frame` takes an immutable film/decode/post/geometry/recipe snapshot
  and returns metadata only. RGB8 or RGB16 is packed on the GPU and read once
  for encoding; there is no full image roundtrip through JavaScript. A changed
  decode snapshot gets a private source session, preserving the editor. Batch
  export runs snapshots in order without selecting/developing every frame in
  the editor. Closing/cancelling releases private sessions and temporary files.

The legacy host methods remain available. A new frontend connected to a host
without `export_frame` reports incompatibility instead of dropping edits.
See [the protocol](../desktop/HOST-PROTOCOL.md) for fields and timing boundaries.

## Encoding and build

Pinned sources and SHA256 values live in `setup-codecs.ps1` and
`setup-codecs.sh`; CMake does not download dependencies:

- libjpeg-turbo 3.2.0, static, required SIMD, accurate integer DCT for Q1–95.
- libpng 1.6.59 + zlib-ng 2.3.3 in zlib-compatible mode, static, lossless RGB8
  at compression level 3.
- TIFF keeps the existing uncompressed RGB8/RGB16 representation.

**Quality exception:** the new integer JPEG DCT at Q98/Q100 failed the fixed
source PSNR regression gate (roughly 0.23–0.35dB below the old encoder).
Q96–100 therefore retain the old float encoder, with buffered file streaming.
The old decoded pixels are exact in that range. No quality threshold was
loosened for speed. Sampling is still 4:2:0 at Q<=90 and 4:4:4 above 90.
ICC, EXIF, UTF-8 paths and atomic no-overwrite writes remain supported.

Configure the host with `SPEKTRALAB_BUILD_HOST=ON`,
`SPEKTRALAB_BUILD_NATIVE_RAW=ON`, `SPEKTRALAB_LIBRAW_OPENMP=ON`,
`SPEKTRALAB_STATIC_RUNTIME=ON`, and the local `SPEKTRALAB_CODECS_DIR`.
The checked Windows build uses Qt's MinGW 13.1, CMake 3.25 and NASM 2.16.03.
Static OpenMP is resolved explicitly; the release host imports only Windows
system DLLs. Codecs' licenses are staged under `engine/host/third-party/codecs`.

## Validation records

Workspace records are under `D:/SpektraLab-win/validation/widegamut-20261012`;
RAW equivalence is under `validation/raw-openmp-20261012`; fixed-source codec
tests are under `build-codecs-20261012`. The local app is
`validation/widegamut-20261012/app/spektralab.exe`. Validation initially produced
no archive or Git submission. A subsequent user request authorizes a portable
release and submission to `Windows_Linux`; that release reuses these checked
binaries and records its exact commit and file hashes in `BUILD-MANIFEST.json`.

Verified before final performance runs:

- Old serial, new serial and new 1/2/4/8-thread full Sony RAW are byte-exact in
  compatible16, headroom and custom-WB modes, including orientation/metadata.
  Invalid inputs and Nikon HE's existing unsupported-compression error remain
  errors. Full Chinese-path RAW open succeeds.
- All 25 native CTests and 127 frontend unit tests pass (one opt-in legacy host
  integration test skipped). New host-smoke and complete binary-host RAW tests
  cover view generations, cached snapshots, metadata-only export, ICC/EXIF,
  private decode, unknown parameters, cancellation and existing-file protection.
- GPU reference checks cover all 65536 neutral codes, grade/curves, matrix and
  transfer, crop/rotation/resize, malformed geometry, cache and legacy C API.
  Neutral codes and quarter turns are exact; nontrivial float math uses the
  test's explicit code-value tolerance (up to 3/65535). Tight RGB8/RGB16 packing
  is byte-exact against the corresponding RGBA16 reference, including odd tails.
- Fixed-source PNG roundtrips are exact. JPEG checks quantization, sampling,
  PSNR/SSIM and metadata; Q96–100 reproduce legacy decoded pixels. Browser
  tests exercise actual WebGL grade/geometry suppression, original/P3 conversion,
  controls, persistence and stale response scheduling.
- 20 private full-RAW export cycles keep the GPU allocation ledger constant;
  the last 10 cycles' private process memory varies by less than 1MiB. Closing
  the editor session returns source, negative and cached-view persistent bytes
  to zero. The GPU pool's retained capacity is accounted separately.
- The staged release app was opened with an isolated WebView profile and a copy
  of the full Sony RAW. Auto selected sRGB on this screen; explicit Display P3,
  full-resolution 100% view, geometry editing/commit/undo, navigator and actual
  JPEG export succeeded. Repeating export created a numbered file and preserved
  the previous output. The log confirms the bundled host/resource path.

Mac/Metal runtime parity, Intel iGPU and physical wide-gamut/multiple-monitor
behavior remain external acceptance items. Browser emulation of capabilities
and this RTX 5070 Ti cannot replace them. Metal additions were source-reviewed
for platform guards; no Mac runtime claim is made.

## Performance and batch policy

Formal scripts record three independent processes, first plus five hot calls,
with old/new order alternated. Default-effect export timing is separate from
deterministic image comparison. Detailed node timing is off. Decode, upload,
post/readback, encode/write, complete call and memory reports are separate;
node sums are never used as complete UI time. PNG/JPEG file closure and atomic
rename are included; OS cache flushing to physical media is not forced.

Batch execution remains serial until measured overlap satisfies the agreed
gate: >=10% median improvement, stable memory, cancellation/error tests, only
one GPU task and one CPU encoder, at most one waiting image and an extra budget
of `min(1GiB, 25% current available memory)`. No next-RAW predecode is introduced.
An estimated ceiling alone does not enable concurrency.

Measured on the RTX 5070 Ti with the 4688x7028 Sony ARW (32,947,264 pixels):

| Measurement | Old median | New median | New range |
| --- | ---: | ---: | ---: |
| RAW+source open, new process | 3.019 s | 1.980 s | 1.979–2.051 s |
| RAW+source open, hot | 2.493 s | 1.389 s | See RAW summary |
| RAW decode only, hot | 2.392 s | 1.329 s | See RAW summary |
| JPEG Q92/P3, first export | 5.492 s | 1.839 s | See export summary |
| JPEG Q92/P3, hot export | 4.067 s | 0.158 s | 0.156–0.171 s |
| JPEG Q100/P3, first export | 5.811 s | 3.303 s | See export summary |
| JPEG Q100/P3, hot export | 4.776 s | 1.612 s | See export summary |
| PNG/sRGB, first export | 8.215 s | 3.529 s | See export summary |
| PNG/sRGB, hot export | 7.295 s | 1.852 s | See export summary |
| TIFF16/ProPhoto, first export | 2.224 s | 1.323 s | See export summary |
| TIFF16/ProPhoto, hot export | 1.439 s | 0.227 s | See export summary |

Each export format has 3 first and 15 hot samples; 144 default-effect exports
completed. This is a complete Node/stdio call through file closure/rename,
including the baseline's actual archived frontend pixel work and two full
RGBA16 transfers. It excludes real Tauri/WebView2 IPC and is **not a measured
whole-window time**. The new path transfers zero image bytes across that
boundary; old input and output each transferred 263,578,112 bytes. New hot
exports reuse the unchanged stochastic film print; old renders regenerate it.
RAW open is separate from export time. The old serial processing-stage sample
was measured separately (old 1719.8ms, new 611.1ms); it is not part of a single
old-host breakdown. Pure hot RAW decode improved 44.4%.

The final 2560-pixel preview benchmark has 3 fresh processes, each with 5 cached
gamut and 5 cached post updates. Gamut median/P95 is 8.590/9.688ms; post is
8.554/10.146ms. These complete stdio calls include the RGBA8 response, not
WebView drawing. The initial full-source view median is 1087.4ms. The first P3
switch previously spent about 0.59s preparing a CAM16 table that ordinary
preview does not use. Preview now builds only its matrix/transfer parameters;
the GPU test confirms byte-identical preview pixels and no CAM16 setup increase.
The legacy public output-transform API and export mapping are unchanged.
See `preview-benchmark-final/summary.json` for all samples and ranges.

Native-window measurements are a separate smoke run, **not** the formal
3-process old/new UI benchmark: first import to drawing submission was 3342.6ms
(RAW 1362.8ms, upload/open 657.6ms, overlapping camera thumbnail 728.9ms);
cached P3 full-source/bounded-display response landed in 124ms. Actual JPEG Q92
export took 749ms first and 181ms hot through the frontend's export call and
file closure/rename. 100% received 4688x7028 pixels in 910ms. Drawing submission
is not an instrumented monitor presentation time. Interface time additionally
includes image transport, WebGL upload and scheduling beyond the approximately
10ms view call; those costs need separate profiling before further tuning.
Native logs are copied to `native-window.log` in the validation directory.

Full statistics/ranges, immutable parameter snapshots, stage timings, hashes
and memory snapshots are in `export-benchmark/summary.json`, `raw-benchmark/summary.json`,
`EXPORT-BENCHMARK-RESULTS.txt` and `RAW-BENCHMARK-RESULTS.txt` under the workspace
validation directory. Formal timing keeps default effects; a separate
deterministic old/new pair disables random stages only for pixel comparison.
That pair has exact TIFF16 RGB pixels. PNG has 5,421 of 98,841,792 RGB samples
different by one 8-bit code and none by more; this is the CPU/GPU output-math
rounding difference, not a lossy PNG codec. Fixed-source PNG codec roundtrips
remain exact. TIFF ICC differences are only its generated creation timestamp;
all colorant, transfer and whitepoint fields agree.

A separate 6-frame serial/overlap prototype, 3 paired processes per format,
keeps only one engine/GPU owner and one CPU encoder. PNG improves from 26.224s
to 18.489s (median paired improvement 30.02%, range 28.61–32.73%); JPEG Q92 only
improves 5.50% (3.40–6.46%). PNG peak working set rises by 93.70MiB. Two fixed
PNG pairs are byte-exact. **Production stays serial:** the prototype has not
passed dynamic budget admission, cancellation/error injection, retained-editor
memory and mixed-size testing; JPEG does not meet the speed gate at all.
The prototype is validation-only and is not linked into the application.
