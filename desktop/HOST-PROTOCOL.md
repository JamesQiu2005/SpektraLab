# SpektraLab host protocol (Linux / Windows desktop)

The Linux/Windows desktop app is two processes:

- **`spektralab-host`** (`engine/host/`, C++20): owns the engine (`spk_*` C ABI,
  Vulkan backend), RAW decode (LibRaw), raster decode, and file writing.
- **The TypeScript app** (`desktop/`, Tauri 2): the interface. The Tauri core
  (Rust) spawns the host as a sidecar and relays messages to the webview.

A process boundary instead of an in-process addon is deliberate: a GPU driver
fault takes down the host, not the window holding the user's edits; the host
cross-compiles with MinGW without any Rust/webview ABI; and the frontend can
restart a dead host and re-open the frame from its sidecar.

This file is the contract between `engine/host/` and `desktop/`. **Changes are
additive** (new methods, new optional fields). A breaking change bumps
`protocol` in `hello` and edits this file in the same commit.

---

## 1. Transport

`spektralab-host --resources <engine-resources-dir> [--device <index>] [--log-level info]`

stdin/stdout carry binary frames; stderr is a free-form log (one line per entry).

Every frame, in both directions:

```
u32 LE  header_len      (bytes of UTF-8 JSON that follow)
u32 LE  payload_len     (bytes of binary payload after the JSON; may be 0)
u8[header_len]  JSON header
u8[payload_len] binary payload
```

- Request:  `{"id": <u32>, "method": "<name>", "params": {...}}`
- Response: `{"id": <u32>, "ok": true, "result": {...}}` or
            `{"id": <u32>, "ok": false, "error": {"code": "<slug>", "message": "<text>"}}`
- Event (unsolicited, no id): `{"event": "<name>", ...}`

Requests are processed **in order on one worker thread**, except `cancel`,
`ping` and `shutdown`, which are handled immediately by the reader thread.
A response may carry a binary payload (pixels, encoded thumbnail).

Error codes: `bad_request`, `not_found`, `decode_failed`, `engine_error`,
`unsupported`, `cancelled`, `io_error`, `internal`.

## 2. Pixel payloads

A result that carries pixels has `result.image`:

```json
{"width": 1600, "height": 1067, "format": "rgba8", "color_space": "sRGB",
 "row_bytes": 6400}
```

- `rgba8`: 8-bit RGBA, display-encoded, top row first. Alpha = 255.
- `rgba16`: 16-bit LE RGBA, as the engine produced it; `color_space` names the
  engine's output space (read it, do not assume — AGENTS.md trap 28).
- `rgba16` **with** `display` (`"srgb"`, `"display-p3"` or `"prophoto"`): the
  output transform for that space, kept at 16 bits; `color_space` names it.

Legacy `render` display surfaces ask for `rgba8` with `display: "srgb"` (or `"display-p3"`); the
host performs the output transform so the renderer never does colour maths on
the frame. `rgba8` without `display` means `"srgb"`.

The output transform is the macOS canvas's (`Canvas/Shaders.metal`
`outputTransform`, RFC-018 §5.4) with every number from `spk_output_transform`:
the working space's curve off, the CAT02-adapted matrix, CAM16-UCS gamut
compression into the target, the target's curve on. When the target *is* the
working space the pixels pass through (the engine already compressed into it).

The current desktop uses `render_view` instead. Its ordinary SDR preview uses
the ProPhoto decode, adapted matrix and target transfer function, **without**
export CAM16 compression. Returned bytes are explicitly tagged sRGB or Display
P3 and the browser manages the monitor. It is not export gamut soft-proofing.

## 3. Methods

### Lifecycle
| method | params | result |
|---|---|---|
| `hello` | `{}` | `{protocol: 1, host_version, build_info, backend: {api: "vulkan", available, device_name, math_mode, render_core, error?}, capabilities: <spk_capabilities JSON> \| null, resources_dir, methods: [..]}` |
| `ping` | `{}` | `{}` |
| `shutdown` | `{}` | `{}` then exits 0 |
| `params_schema` | `{}` | `<spk_params_schema JSON>` |
| `print_lut_catalog` | `{}` | `<spk_print_lut_catalog JSON>` |
| `memory_report` | `{}` | `<spk_memory_report JSON>` |

The Windows/Linux engine also reports `suspended_bytes` for exact image-cache
bytes held in temporary disk storage. This is **not** resident GPU memory and
is excluded from `total_bytes`. Each `persistent.sessions` row includes
`residency_suspended` and `suspended_bytes`; its source/negative/view byte
counts describe only current GPU residency. The Vulkan staging allocations
are separately reported by optional transfer diagnostics, not the pool ledger.

### Files
| method | params | result |
|---|---|---|
| `probe` | `{path}` | `{kind: "raw"\|"tiff"\|"jpeg"\|"png", width, height, metadata}` (no full decode) |
| `thumbnail` | `{path, long_edge, embedded_only?: boolean}` | `{image, source: "embedded"\|"half-size decode"\|"decode", orientation_applied: true}` + rgba8 sRGB payload, **already turned to the camera's orientation** (embedded RAW preview when present, else a fast decode) |

Hosts advertising `hello.thumbnail_options: ["embedded-only"]` accept
`embedded_only: true` for background RAW preview preparation. It returns the
camera's embedded preview or `decode_failed` when no usable preview exists;
it never starts the fallback RAW demosaic. Raster files and half-frame pairs
return `unsupported`, and a non-boolean option returns `bad_request`.
Omitting the option or passing `false` preserves the existing fallback. A
camera preview carries its own sRGB appearance, not the current film edits.

`metadata`: `{make?, model?, lens?, iso?, shutter_s?, aperture?, focal_mm?, exposure_program?, exposure_bias_ev?, focal_35mm?, datetime_original?, orientation, as_shot?: {temperature_k, tint}}` — feeds the date back and the info readouts. `datetime_original` is ISO-8601 local time without a zone (`2026-09-14T17:03:22`), from EXIF `DateTimeOriginal`. `orientation` is the EXIF value (1–8) of the file as stored; `probe`'s `width`/`height` are **as displayed** (orientation applied), and so is every frame the host hands the engine.

White balance at decode (R2): `temperature_k` 2000–50000 and `tint` −150…150
in the Adobe DNG SDK's definition (Robertson isotherms; tint = −3000 × the
distance from the Planckian locus in CIE 1960 uv, positive is magenta) — the
scale Lightroom/ACR use. The camera side is LibRaw's XYZ→camera matrix, so
`as_shot` → `custom` with the same numbers reproduces As Shot (measured: mean
difference 0.01/255). Both `compatible16` and `headroom` accept custom RAW white balance; raster inputs reject decode white balance. `lens_correction: true` uses the pinned Lensfun profile when the camera/lens match is unique; missing or ambiguous profiles and non-RAW inputs are explicitly `unsupported`
(LibRaw supplies the sensor decode; bundled Lensfun supplies calibration).

What a file is decoded *to* (the engine develops linear ProPhoto RGB, top row first; AGENTS.md traps 11–12): RAW through LibRaw; TIFF/JPEG/PNG through their embedded matrix/TRC ICC profile (D50 colorants to XYZ to ProPhoto, as ColorSync does); without a profile, 8-bit files are sRGB and 16-bit/float TIFFs are linear ProPhoto (the macOS decoder's rule for an untagged deep TIFF). TIFF: 8/16-bit integer and 32-bit float, RGB or grey, uncompressed/LZW/deflate/PackBits, strips or tiles; not BigTIFF or CMYK. RGB LUT ICC profiles use LittleCMS; malformed profiles are rejected explicitly. HEIC/HEIF/HIF supports SDR HEVC through libheif/libde265 with ICC or NCLX; PQ/HLG is explicitly unsupported. EXR supports flat first-part RGB/Y float32 data with embedded primaries or default Rec.709; deep EXR is unsupported.

### Sessions (one per open frame)
| method | params | result |
|---|---|---|
| `open` | `{path, decode?: {raw_mode?: "compatible16"\|"headroom", white_balance?: {mode: "as_shot"\|"custom", temperature_k?, tint?}, lens_correction?: boolean}, params?: <full or partial params JSON>}` | `{session: "<sid>", width, height, kind, metadata, params, detected_input, output_color_space, timings_ms: {decode, open}}` — any other `decode` key is `unsupported` |
| `redecode` | `{session, decode}` | as `open` (same `session` id, params kept): decode the session's file again with other decode settings. The engine session is replaced; on failure the old one is untouched (R2) |
| `close` | `{session}` | `{}` |
| `render_source` | `{session,display:"srgb"\|"display-p3",long_edge?,generation?}` | `{image,generation,source:"decoded"}` + RGBA8 of the current decoded source; film/grade edits do not affect it |
| `pick_neutral` | `{session,x,y,side?:"left"\|"right"}` | `{temperature_k,tint}` from calibrated RAW source, normalized whole-source coordinates and 5×5 patch. Pair requires `side`, rejects gap/edge/other-hole samples, removes that hole's exposure gain, and retains calibration on cache hits. Non-RAW is unsupported. |
| `set_params` | `{session, delta: {...}}` | `{params}` (the delta is applied transactionally: on error the session is unchanged) |
| `get_params` | `{session}` | `{params}` |
| `solve` | `{session, target}` | `<spk_solve JSON>` |
| `render` | `{session, tier: "live"\|"preview"\|"full", reprint?: bool, format: "rgba8"\|"rgba16", display?: "srgb"\|"display-p3"\|"prophoto", progress_id?}` | `{image, tier, reprinted: bool, negative_was_cached: bool, engine_progress_id, timings_ms: {engine, render, transform}}` + pixels |
| `render_view` | `{session, tier, adjustments, geometry, display: "srgb"\|"display-p3", format?: "rgba8"\|"rgba16", long_edge?: 0, generation, progress_id?}` | `{image, tier, print_cached, generation, timings_ms: {print, post, readback, total}}` + requested display pixels |
| `scene_latitude` | `{session, request: {...}}` | `<spk_scene_latitude JSON>` |
| `overscan_geometry` | `{session}` | `<spk_overscan_geometry JSON>` |
| `preview_stock_lut` | `{session, print_stock, tier?: "preview", format, display?}` | `{image, lut: <spk_preview_stock_lut JSON>}` + pixels; the LUT's own output space (catalog `output_color_space`) is the source of the transform |
| `cancel` | `{session, progress_id}` | `{was_running}` — handled on the reader thread: the request carrying that `progress_id` is cancelled if running (`spk_cancel`) or refused with `cancelled` when it reaches the worker |
| `progress` | `{session, engine_progress_id?}` | `<spk_progress JSON>` of the session's last render (queued behind the worker, so it reports a finished render, not one in flight; live progress is the `progress` event) |

`reprint: true` uses `spk_reprint` (print-side edits only; API-SPEC §2); the host
falls back to `spk_render` and reports `reprinted: false` when the engine refuses.

### Export
| method | params | result |
|---|---|---|
| `export_image` | `{session, path, format: "tiff16"\|"tiff8"\|"jpeg"\|"png", quality?: 92, color_space?: "sRGB"\|"display-p3"\|"prophoto", long_edge?, overwrite?: false, progress_id?}` | `{path, width, height, bytes, color_space}` |
| `write_image` | `{path, format, quality?, color_space, width, height, source_path?, overwrite?: false}` + rgba16 LE payload (top row first, encoded in `color_space`) | `{path, width, height, bytes, color_space, exif_copied}` (R1) |
| `export_cube` | `{print_stock, path, overwrite?}` | `{path, size}` — the baked print LUT (`spk_print_lut_table`), domain 0..1 of normalised negative density |
| `export_di` | `{session, print_stock?, path, overwrite?}` | `{path, width, height, bytes, di: <spk_export_di JSON>}` — 16-bit TIFF of normalised negative density, no ICC (it is not a colour space) |

Files carry EXIF (TIFF Exif IFD, JPEG APP1, PNG eXIf): Make, Model,
LensModel, DateTimeOriginal, ExposureTime, FNumber, ISO, FocalLength, the
written PixelX/YDimension, Orientation 1 (the pixels are upright) and
Software. `export_image` takes them from the session's file, `write_image`
from `source_path` (rebuilt from the parsed fields, not a byte copy of the
source's EXIF; maker notes are not carried). Standard self-contained EXIF
shooting values additionally retain their original type, count and rational
bytes, including exposure program/bias, 35 mm focal length, metering/flash,
original/digitized timestamps and subsecond/timezone fields, lens specifications
and camera/lens serials. Retention is limited to 16 KiB per tag and 32 KiB total;
unknown tags, MakerNote, GPS, source pointers and stale pixel dimensions are
excluded. The host rewrites output dimensions and upright orientation. An
exposure bias of zero remains present.

Files: every writer embeds an ICC profile for its `color_space` (the bundled
`io/sRGB.icc`; generated v2 matrix/TRC profiles for Display P3 and ProPhoto),
writes a hidden `.<name>.partial-<pid>-<n>` beside the destination and renames
it into place, and refuses an existing destination unless `overwrite` (§7.8
"files land whole"). PNG is 8-bit. TIFF is uncompressed, little-endian.
Legacy `export_image`'s `long_edge` downsamples in linear light (area average) after the output
transform's matrix and gamut step, before the curve.

### Complete frame export and resident views (additive, protocol 1)

#### Per-frame film bypass (`no_film`, 2026-10-28)

`hello.frame_options` includes `"no-film"` for export/proof.
`hello.view_options` includes `"no_film"` when this host implements the source
choice. A client must check that capability before promising bypass behavior;
older hosts do not implement it. `render_view`, `export_frame` and
`render_proof` accept optional `no_film: boolean`, default `false`. An explicit
non-boolean value, including null, is a `bad_request`. This is a request option,
not an engine parameter or a replacement film stock.

For ordinary output, `true` selects the current decoded **linear ProPhoto**
source instead of the film print. It encodes that source as float working RGB
and runs the same Post-Dev, output geometry, colour conversion and proof chain.
Highlights remain unclipped until the normal Layer 2 output boundary, so a
negative Post-Dev exposure can recover source values above 1. The source's own
native dimensions are reported as `image.source_width/source_height`; crop and
rotation in `geometry` still determine the output. `source_geometry` is ignored
for these requests, leaving the dormant film/date crop untouched. Film edge,
date exposure, scene-placement fit and the film's DI-view LUT are not applied.
Other supplied `params` are still validated/applied as the frozen film settings.

Bypass never populates or replaces the film-print cache and reports
`print_cached: false`. Turning it off can reuse the existing random film result.
A half-frame pair rejects ordinary bypass at both host and native-view
boundaries, including private/background exports. `export_cineon` and
`render_proof` with `format: "di"` **reject** `no_film: true` with `bad_request`: they
retain the negative, source-geometry and ungraded Cineon behavior below.

`render_view` and `export_frame` are independently advertised by `hello.methods`.
The new desktop requires `export_frame` to save an edited frame; it must show an
incompatibility message rather than silently use an incomplete legacy export.
The old `render`, `export_image` and `write_image` contracts remain available.

`hello.view_formats:["rgba8","rgba16"]` advertises the additive high-precision
view transport. `render_view.format` defaults to `rgba8` for older clients;
`rgba16` is little-endian display-encoded RGBA UNORM16, eight bytes per pixel,
and its `image.row_bytes` is `width * 8`. The desktop requests 16 bits only
when advertised, keeps exact codes in a WebGL2 RGBA16UI texture and performs
interpolation in float. Where `drawingBufferStorage` and
`EXT_color_buffer_float` actually accept RGBA16F, the SDR drawing buffer is
float16; otherwise it falls back to RGBA8 without prematurely rounding the
source texture. This is not HDR, nor a claim that a monitor outputs 10 bits.
Navigation/histogram/thumbnail targets remain small RGBA8 images; source and
export-proof transports currently remain RGBA8. The print/export computations
and exported bit depth are unaffected by the display buffer choice.

`hello.export_spaces` advertises the supported recipe wire names: `sRGB`,
`display-p3`, `prophoto`, `adobe-rgb`, `rec2020`. The latter two are Adobe RGB
(1998) and ITU-R BT.2020 with their own transfer functions and generated ICCs
from the baked colour-space primaries, not merely different profile labels.

`export_frame` accepts JSON only (nonempty binary payloads are rejected):

```json
{"session":"s1", "source_path":"D:/photos/example.ARW",
 "params":{"output_color_space":"ProPhoto RGB","output_cctf_encoding":true},
 "decode":{"raw_mode":"compatible16"},
 "adjustments":{}, "geometry":{},
 "path":"D:/exports/example.jpg", "format":"jpeg", "quality":92,
 "color_space":"display-p3", "long_edge":0, "overwrite":false,
 "progress_id":"unique-export-job"}
```

`params` is a complete engine parameter snapshot in the existing flat wire
format, including the enabled feature gate. `adjustments` and `geometry` use
the desktop sidecar schema (camelCase); omitted fields receive neutral defaults.
`format` is `jpeg`, `png`, `tiff8` or `tiff16`. A session can be omitted if
`source_path` is supplied; the host decodes and opens one private session,
exports without a preview, and releases it on success, cancellation or error.
When a supplied session has different effective decode options from the
snapshot, the host privately reopens its source so a pending white-balance edit
cannot be omitted. The editor session is preserved. A matching session reuses
its full print or negative cache.

Processing order for both new methods is: encoded ProPhoto RGBA16 print on GPU
-> float32 ProPhoto encoded-domain post adjustments (middle grey 0.3857)
-> geometry and 16-bit quantization -> resize and 16-bit quantization
-> output conversion -> one CPU readback. `export_frame` retains CAM16 output
gamut compression with **lightness compression disabled** because the print
already applied its lightness shoulder. As on Mac, the target chroma knee
also runs on same-space ProPhoto exports. This corrects the former Windows
double-shoulder / same-space bypass; legacy methods retain their old processing.
`render_view` uses ordinary display conversion. `long_edge`
limits the final cropped result; zero keeps its native dimensions. The print
cache depends on session, source size and film/print parameters. Grade,
geometry, size and display changes reuse it and do not generate new grain.

An optional `scene_placement` carries target-independent copied placement
intent (highlight/shadow pullback, rolloff, maximum lift, norm and percentiles).
After applying the source/decode/film snapshot, the host obtains that target's
`scene_latitude` fit and applies its complete `params_delta` before rendering.
An invalid or incomplete fit rejects the job; it never silently drops the edit.

### Export soft proof (`render_proof`, additive, protocol 1)

Advertised independently in `hello.methods`. Accepts the same immutable source,
params/decode, adjustments/geometry, format, color_space and long_edge snapshot
as `export_frame`, plus `proof_long_edge` (integer 1–4096), `display` (`srgb` or
`display-p3`), `generation`, and `progress_id`. It accepts no image payload and
does not require or write a target path. `format:"di"` uses the dedicated
Cineon contract below and requires `export_cineon` capability as well.

The shared export chain runs at **the recipe's actual file dimensions**, then
quantises to its chosen 8/16-bit codes. Only then does the GPU downsample for
the proof and convert from the file's encoding to the requested display.
The host returns bounded RGBA8 pixels tagged with their actual display space:
`{image,generation,file_width,file_height,color_space,bit_depth,print_cached,
compression_simulated:false,stats,timings_ms}`. `stats` contains `pixels`,
`moved_fraction` (CAM16 knee acted), `outside_fraction` (pre-knee chroma exceeds
the target), and `clipped_fraction` (any encoded channel at/past 0 or 1).
These count **file pixels before proof downsampling**, matching the Mac counter
definitions. `color_space` names the file; `image.color_space` names the display.

The depth quantisation follows the actual Windows file. Mac's proof currently
keeps its UNORM16 texture until ImageIO's eventual depth conversion; this Windows
proof deliberately includes the selected file-depth quantisation. JPEG proof
is **before lossy compression**, as on Mac: it does not simulate JPEG artifacts.
Only bounded display pixels cross IPC. Full-tier film cache, private-session
lifetimes, snapshot semantics and cancellation follow `export_frame`.
Clients debounce recipe edits, cancel obsolete jobs, verify `generation`, and
hide the old image while a new proof is pending. Missing capability is an explicit
message; the editor canvas is never substituted as an export proof.

### Cineon Digital Intermediate (`export_cineon`, additive, protocol 1)

This independently advertised method accepts the same frozen session/source,
decode, film parameters, scene placement intent, geometry, path, overwrite and
progress ID as `export_frame`. The host keeps the current editor pipeline and
finished print intact, reuses its negative when valid, and runs a separate DI
print pipeline. It always writes native-size 16-bit Cineon in ProPhoto primaries;
the recipe's ordinary colour-space, resize, format and Post-Dev fields do not
change these log codes. Committed crop/rotation remains part of the photograph.

The main TIFF page has **no ICC**, and EXIF ColorSpace is Uncalibrated (65535).
An sRGB-tagged reduced second page shows the codes through the shipped DI view
LUT. Both exact bundled `.cube` files (to ProPhoto RGB and to Rec.709) are copied
beside the TIFF once per directory, without replacing existing different files.
The response adds `encoding:"cineon"`, `primaries:"ProPhoto RGB"`,
`color_space:"untagged Cineon"`, and `view_luts:[paths]`; binary payload is empty.
Legacy `export_di` still means normalized density and is **not** this method.

`render_proof` with `format:"di"` runs the same file-size Cineon/geometry path on
the GPU, then the bundled view LUT before display conversion/downsampling. It
returns `encoding:"cineon"`; ordinary output-gamut statistics are inapplicable
and are not shown. Only the bounded proof image is read back. The ordinary DI
editor and regular image exports likewise apply the shipped LUT **before**
ProPhoto Post-Dev, at float precision with Mac's binary16 LUT storage and
UNORM16 stage boundaries. A missing/malformed table is an explicit error.

`render_view`, `export_frame`, `render_proof`, and `scene_latitude` accept
an optional `source_geometry` with the same geometry shape. Its complete
crop/angle/quarter-turn/flip state is applied atomically with `params` before
metering and film exposure; `{}` resets all source geometry fields. Film
Edge/date use this held crop, with identity post geometry. The float source
resampler retains RAW headroom, and crop size becomes the physical film gate.
`render_source` and neutral sampling always use the unchanged decoded original.
Omitting `source_geometry` preserves the current state for legacy clients.

`render_view.image` also reports `source_width`, `source_height`, `processed:true`
and the applied `geometry`. Source dimensions are the full-resolution film
canvas (including Film Edge), independent of preview tier or display scaling. The client must skip its old post-processing and
must not crop the result a second time. `generation` is echoed for stale-result
rejection. Fit previews can use a full-source print with a bounded output size;
100% views request native output, subject to the canvas texture-size limit.

`export_frame` returns `{path,width,height,bytes,color_space,print_cached,
exif_copied,timings_ms}` and **zero binary payload bytes**. `timings_ms` contains
`print`, `post`, `readback`, `encode_write`, and whole-call `total`; private opens
also include `source:{decode,open,raw?}`. Open/redecode's optional `raw` diagnostics
contain `open`, `unpack`, `process`, `convert`, `total` (milliseconds),
`openmp_enabled`, and `workers`. Engine upload is included in `open`, separate
from decode. UI logs separately measure request and first-display latency.

Batch clients freeze snapshots before starting and submit them in order; they
do not select each frame in the editor. `cancel` can use an empty `session` plus
a unique `progress_id` for a private export. Queued work is refused; active RAW
decode/encode checks cancellation at the next safe boundary. A cancelled encode
does not rename its temporary file into place. Current execution is serial;
no second RAW decode or GPU render is started concurrently.

JPEG uses accurate integer-DCT libjpeg-turbo with SIMD for Q1–95. Q96–100 retain
the previous floating-DCT encoder because integer-DCT substitution failed the
high-quality fidelity gate; sampling remains 4:2:0 at Q<=90 and 4:4:4 above 90.
PNG uses libpng plus zlib-ng at compression level 3, RGB8 lossless. Both stream
rows to the atomic temporary file and preserve ICC/EXIF. TIFF retains its
existing bit depth and uncompressed default; the complete-frame path
writes it in bounded chunks without constructing a second full-file buffer.

Before a private batch source is decoded, the host may suspend existing editor
image caches to an owned temporary file. The exact source, negative and print
bytes, aliases and pipeline state are preserved; no random effects are
regenerated. The editor restores lazily before its next source-touching call.
Closing it removes the snapshot without restoring it. A temporary-file failure
returns `io_error` and retains either the original GPU data or a recoverable
disk snapshot. Cancellation and failed private exports retain the editor.
Temporary files use delete-on-close lifetime on Windows. This lowers peak
residency at the cost of disk I/O and one restoration when returning to editing;
it does not add concurrent RAW decoding, GPU rendering or CPU encoding.

Events: `{"event": "progress", "session", "progress_id", "fraction", "stage"}`
(stages `render`, `transform`/`encode`, `done`; emitted only for requests that
carry a `progress_id`).

Errors: `decode_failed` (unreadable/unsupported file), `not_found` (no such
file or session), `bad_request` (a malformed parameter, or the engine's
`SPK_ERR_USER`/`INVALID_ARG` — including the refused features in
`capabilities.backend.unsupported_features`), `unsupported` (an unknown method
or decode key), `engine_error`, `cancelled`, `io_error`, `internal`.

If the engine cannot start (no Vulkan driver), the host still answers `hello`
with `backend.available: false` and `backend.error`, and every engine method
fails with `engine_error`; `probe` and `thumbnail` still work.

Lavapipe (Mesa's CPU Vulkan) works as a fallback device: the engine accepts its
unfused `fma` and, after a probe at start-up, storage buffers past its
advertised 128 MiB range; both are stated in `backend.math_mode`.

## 4. Packaging layout

The host build stages a self-contained directory per platform:

```
build/host-linux-x64/            build/host-win-x64/
  spektralab-host                  spektralab-host.exe   (static libstdc++/winpthread)
  engine/                          engine/
    <baked resources>                <baked resources>
    vulkan/*.spv                     vulkan/*.spv
    io/sRGB.icc                      io/sRGB.icc
  licenses/                        licenses/
```

`desktop/` packaging copies the matching directory into the app's
`resources/host/` (renamed to Tauri's sidecar names by the frontend's
packaging). The Tauri core (Rust) launches
`resources/host/spektralab-host[.exe] --resources resources/host/engine`.
In development, `SPEKTRALAB_HOST_DIR` overrides the directory.


### TIFF lossless compression and embedded preview (F16)

`hello.tiff_options` advertises `lzw` and `preview-page`. `export_frame` accepts
`tiff_compression: "none" | "lzw"` (default `none`) and `embed_preview: boolean`
(default `false`) for TIFF only. Invalid values and non-default TIFF options on
JPEG/PNG fail explicitly. The frontend checks these capabilities before writing;
old recipes retain their uncompressed/no-preview behavior. The legacy writers
keep their previous defaults.

LZW is TIFF early-change, MSB-first, independently restarted per strip, using a
bounded dictionary/output slab. It never builds a full compressed image in RAM.
A preview is IFD1 with NewSubfileType=1, long edge at most 2048, 8-bit RGB and the
same ICC as the actual file: bilinear resampling/quantization of those exact file
codes, not a second film render. Requested previews exist even for small files.
Both pages use the selected compression. Directory and strip offsets are patched
in the temporary seekable file before the existing atomic commit.

`export_cineon` accepts the same compression option but always embeds its
2048-edge sRGB view preview; its primary remains untagged 16-bit Cineon codes.
Neither TIFF option changes the file-resolution soft proof's pixel processing.

### Desktop settings, diagnostics and optional agents (F17/F18)

The Memory settings page reads the existing `memory_report` ledger serially,
at most once per two seconds while visible. It reports engine GPU allocations,
decoded sources, negative/print caches, reusable buffers, and separately the
bytes suspended to temporary files. These are not process RSS, total driver
VRAM or an operating-system memory limit. No duplicate sampler is presented as
the engine's ledger. Windows currently uses serial GPU/RAW work, bounded transfer
buffers and idle reclamation; Mac's unified-memory reserve/working-set override
is not exposed as a fictitious Windows cap.

The Tauri `frame_cache_status`, `frame_cache_configure({capBytes})` and
`frame_cache_clear` commands control only checked display-cache entries. The UI
allows 0–64 GiB (0 disables caching), shows actual usage/path and refreshes after
configuration or clearing. The store's 64 MiB per-entry limit and source/engine
fingerprints remain enforced by Rust. Original images, sidecars and exports are
not cache entries. Browser-only development explicitly reports these native
controls as unavailable.

Diagnostic copying and ZIP saving are user initiated. The default report includes
app/engine versions, GPU/API, negotiated methods/formats and the engine memory
ledger. The ZIP also carries settings, previous-session clean-exit status and
the newest five owned logs (at most the last 4 MiB per file). By default, paths,
arguments and the host stderr tail are omitted from the summary; entire log
records containing paths or image filenames are omitted conservatively. An
explicit opt-in includes them. No image pixels are included and nothing is
uploaded. ZIP entries use CRC32, UTF-8 names and store-only compression. The
destination must be a new `.zip`; a synced temporary is atomically published
without overwriting an existing file. An unwritable destination reports failure.

Native commands `diagnostics_get`, `diagnostics_set({settings})`,
`diagnostics_clear_logs` and `diagnostics_save_bundle({path,summary,includePaths})`
back these controls. Settings are `{level:"error"|"info"|"debug",per_node,
export_job_log,days,megabytes,files,directory}`. Retention defaults to 7 days,
100 MB and 20 files; supported ranges are 1–365 days, 10–10000 MB and 1–500
files. The oldest owned files are removed at startup, after changes and every
60 seconds while the host is idle. The exact active log is preserved; older
rotations can be removed. Only regular owned files are candidates; foreign
names, symlinks and reparse entries are excluded, and a linked log-directory
root is rejected. Cleanup failures remain visible. Changing the directory
applies on the next app launch; existing logs are not moved or deleted.

Core log level applies immediately; host verbosity and per-node instrumentation
apply at the next engine restart. The visible warning explains the synchronization
and diagnostic overhead. With instrumentation enabled, `render_view` and
export/proof log the actual `spk_progress` node timings; normal operation does
not pay for those timings. Optional per-export job logs (off by default) save
the frozen request, completed result and complete host-call duration beside the
output, without image data. Job-log write failure does not turn a successfully
saved photograph into a failed export. Windows keeps its existing bounded
allocation/idle strategy and does not claim a Mac process-footprint sampler or
an operating-system hard memory cap.

The update button makes an anonymous, no-cookie/no-cache, five-second request
to the official GitHub releases endpoint, only after a click. It examines the
latest 30 public stable releases and requires an uploaded, nonempty Windows x64
asset (explicit Windows/win64 and x64/amd64 naming, supported archive/installer
extension) and official repository release/download URLs. Mac-only, ARM,
source/debug, draft and prerelease assets do not qualify. Comparable release
tags are `spektralab-vX.Y.Z`, `vX.Y.Z`, or their `-windows[-x64]` variants.
No match is **not** "up to date"; network/HTTP/version failures are shown as
failures. Available updates only open the release page; no download, install,
or restart occurs automatically. CSP permits only the GitHub API in addition
to existing local connections.

Agents settings uses `agent_access_get` and `agent_access_set({enabled})` to
display and change explicit local access (off by default). The response is
`{enabled,runtime_available,executable,command,mcp_config}`. Missing bundled
runtime is shown as unavailable. `agent_cli_install` returns the exact managed
wrapper path; `agent_cli_uninstall` only removes the owned wrapper. The UI does
not modify PATH. MCP configuration is copied only on request. Moving the app
requires reinstalling the wrapper so its absolute target remains valid.

## Half-frame pair source and immutable export

`open_pair {path,pair,params}` and `update_pair {session,pair,params}` use the
stored HalfFramePair schema. An update preserves the session ID and leaves the
negative cache intact when only per-hole print/Post-Dev settings change. Source
changes compose sequentially decoded, bounded binary16 hole caches into one
linear ProPhoto strip with an unexposed gap. Fresh and cached hole samples use
the same quantisation. Automatic exposure is measured per hole; the composite
is not metered globally. Pair `solve both` solves the paper without measuring
the gap as scene content.

Open/probe replies and every `render_view` carry `pair_info`: left/right source
dimensions, availability/error, metadata and optional metered EV, plus two
normalised gate rectangles for the current display canvas. Partial sources can
be previewed, but direct export and proof require both holes to be readable.
Export/proof requests include the frozen pair recipe; a source snapshot that
differs from the editor is composed privately and does not discard its cached
negative. Per-hole print trims and Post-Dev run in the engine on the same
negative, preserving grain; Cineon exports intentionally bypass print layers.
Automatic per-hole readings include `metered_for`, an opaque token of the real
file stamp, decode, source geometry and metering intent. The pair recipe saves
it as `meteredFor` with `meteredEV`; matching finite readings survive reopening
and private export after placement changes. Invalid/stale tokens are measured
again. Computed reading adoption does not invalidate the existing negative;
a genuinely different validated reading does change its source signature.

A pending `scene_placement` on a pair includes its selected source-hole
`region:[x0,y0,x1,y1]`. For the right hole, `scene_placement_side:"right"` maps
the fit's active/knee/room fields to the B curve while retaining shared norm,
rolloff and max-lift. An invalid fit fails instead of silently exporting an
unfitted or wrong-hole edit.

## User CLI and MCP

RAW filename recognition is shared with the desktop importer, including ARI,
BAY, K25 and GPR. Recognition only selects LibRaw; support for a particular
camera and compression variant still depends on the bundled decoder. Unsupported
variants return a decode error rather than being treated as a supported format.

The bundled agent layer is a distinct user protocol, documented in
`AGENTS-CLI.md`. It exposes the pinned Mac's twelve strict tools and edit schema,
reuses TypeScript snapshot/wire/export helpers, and uses this native host for
all image operations. A persistent MCP workspace retains one host/session.
The app's `--agent-files` mode reuses the native SidecarStore and serves only
status, access-checked begin/end, sidecar load/save, saved recipe reads, and
the two pixel-affecting app rendering preferences. Each tool freezes the latter
once; only a missing preference file permits the shared defaults.
An OS lease excludes simultaneous GUI batches/agent operations and dies with
the owner process. A UI timeout ends only its wait: the native operation keeps
the lease until its reply or confirmed child exit. Restart kills and reaps the
old host before starting a replacement; late replies are isolated by generation.
Cancel, ping and shutdown remain available while that lease is held.
The GUI receives `{revision,paths,all}` change journals
(last 64 unique paths; `all` persists after overflow), checks on focus/timer and
protects unsaved snapshots from overwriting external sidecar edits.

Full exported images never pass through the agent's JSON transport. MCP image
content is limited to requested small JPEG previews, whose temporary files are
removed after reading. Source photographs and occupied explicit preview paths
are protected. Access is off initially, rechecked on every tool, and revoking
it affects the next call without restarting MCP.
