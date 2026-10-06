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

Display surfaces ask for `rgba8` with `display: "srgb"` (or `"display-p3"`); the
host performs the output transform so the renderer never does colour maths on
the frame. `rgba8` without `display` means `"srgb"`.

The output transform is the macOS canvas's (`Canvas/Shaders.metal`
`outputTransform`, RFC-018 §5.4) with every number from `spk_output_transform`:
the working space's curve off, the CAT02-adapted matrix, CAM16-UCS gamut
compression into the target, the target's curve on. When the target *is* the
working space the pixels pass through (the engine already compressed into it).

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

### Files
| method | params | result |
|---|---|---|
| `probe` | `{path}` | `{kind: "raw"\|"tiff"\|"jpeg"\|"png", width, height, metadata}` (no full decode) |
| `thumbnail` | `{path, long_edge}` | `{image, source: "embedded"\|"half-size decode"\|"decode", orientation_applied: true}` + rgba8 sRGB payload, **already turned to the camera's orientation** (embedded RAW preview when present, else a fast decode) |

`metadata`: `{make?, model?, lens?, iso?, shutter_s?, aperture?, focal_mm?, datetime_original?, orientation, as_shot?: {temperature_k, tint}}` — feeds the date back and the info readouts. `datetime_original` is ISO-8601 local time without a zone (`2026-09-14T17:03:22`), from EXIF `DateTimeOriginal`. `orientation` is the EXIF value (1–8) of the file as stored; `probe`'s `width`/`height` are **as displayed** (orientation applied), and so is every frame the host hands the engine.

White balance at decode (R2): `temperature_k` 2000–50000 and `tint` −150…150
in the Adobe DNG SDK's definition (Robertson isotherms; tint = −3000 × the
distance from the Planckian locus in CIE 1960 uv, positive is magenta) — the
scale Lightroom/ACR use. The camera side is LibRaw's XYZ→camera matrix, so
`as_shot` → `custom` with the same numbers reproduces As Shot (measured: mean
difference 0.01/255). RAW and `compatible16` only; on a raster or in
`headroom` mode it is `unsupported`. `lens_correction: true` is `unsupported`
(LibRaw carries no lens profiles).

What a file is decoded *to* (the engine develops linear ProPhoto RGB, top row first; AGENTS.md traps 11–12): RAW through LibRaw; TIFF/JPEG/PNG through their embedded matrix/TRC ICC profile (D50 colorants to XYZ to ProPhoto, as ColorSync does); without a profile, 8-bit files are sRGB and 16-bit/float TIFFs are linear ProPhoto (the macOS decoder's rule for an untagged deep TIFF). TIFF: 8/16-bit integer and 32-bit float, RGB or grey, uncompressed/LZW/deflate/PackBits, strips or tiles; not BigTIFF, CMYK or LUT-based ICC profiles (those fall back to sRGB with a log line).

### Sessions (one per open frame)
| method | params | result |
|---|---|---|
| `open` | `{path, decode?: {raw_mode?: "compatible16"\|"headroom", white_balance?: {mode: "as_shot"\|"custom", temperature_k?, tint?}, lens_correction?: false}, params?: <full or partial params JSON>}` | `{session: "<sid>", width, height, kind, metadata, params, detected_input, output_color_space, timings_ms: {decode, open}}` — any other `decode` key is `unsupported` |
| `redecode` | `{session, decode}` | as `open` (same `session` id, params kept): decode the session's file again with other decode settings. The engine session is replaced; on failure the old one is untouched (R2) |
| `close` | `{session}` | `{}` |
| `set_params` | `{session, delta: {...}}` | `{params}` (the delta is applied transactionally: on error the session is unchanged) |
| `get_params` | `{session}` | `{params}` |
| `solve` | `{session, target}` | `<spk_solve JSON>` |
| `render` | `{session, tier: "live"\|"preview"\|"full", reprint?: bool, format: "rgba8"\|"rgba16", display?: "srgb"\|"display-p3"\|"prophoto", progress_id?}` | `{image, tier, reprinted: bool, negative_was_cached: bool, engine_progress_id, timings_ms: {engine, render, transform}}` + pixels |
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
| `write_image` | `{path, format, quality?, color_space, width, height, overwrite?: false}` + rgba16 LE payload (top row first, encoded in `color_space`) | `{path, width, height, bytes, color_space, exif_copied: false}` (R1) |
| `export_cube` | `{print_stock, path, overwrite?}` | `{path, size}` — the baked print LUT (`spk_print_lut_table`), domain 0..1 of normalised negative density |
| `export_di` | `{session, print_stock?, path, overwrite?}` | `{path, width, height, bytes, di: <spk_export_di JSON>}` — 16-bit TIFF of normalised negative density, no ICC (it is not a colour space) |

Files: every writer embeds an ICC profile for its `color_space` (the bundled
`io/sRGB.icc`; generated v2 matrix/TRC profiles for Display P3 and ProPhoto),
writes a hidden `.<name>.partial-<pid>-<n>` beside the destination and renames
it into place, and refuses an existing destination unless `overwrite` (§7.8
"files land whole"). PNG is 8-bit. TIFF is uncompressed, little-endian.
`long_edge` downsamples in linear light (area average) after the output
transform's matrix and gamut step, before the curve.

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
