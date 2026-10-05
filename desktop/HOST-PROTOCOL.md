# SpektraLab host protocol (Linux / Windows desktop)

The Linux/Windows desktop app is two processes:

- **`spektralab-host`** (`engine/host/`, C++20): owns the engine (`spk_*` C ABI,
  Vulkan backend), RAW decode (LibRaw), raster decode, and file writing.
- **The TypeScript app** (`desktop/`, Electron): the interface. The Electron main
  process spawns the host and relays messages to the renderer.

A process boundary instead of an in-process addon is deliberate: a GPU driver
fault takes down the host, not the window holding the user's edits; the host
cross-compiles with MinGW without any Node/Electron ABI; and the frontend can
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

Display surfaces ask for `rgba8` with `display: "srgb"` (or `"display-p3"`); the
host performs the output transform so the renderer never does colour maths on
the frame.

## 3. Methods

### Lifecycle
| method | params | result |
|---|---|---|
| `hello` | `{}` | `{protocol: 1, host_version, build_info, backend: {api: "vulkan", device_name, driver, vram_mb?}, capabilities: <spk_capabilities JSON>, resources_dir}` |
| `ping` | `{}` | `{}` |
| `shutdown` | `{}` | `{}` then exits 0 |
| `params_schema` | `{}` | `<spk_params_schema JSON>` |
| `print_lut_catalog` | `{}` | `<spk_print_lut_catalog JSON>` |
| `memory_report` | `{}` | `<spk_memory_report JSON>` |

### Files
| method | params | result |
|---|---|---|
| `probe` | `{path}` | `{kind: "raw"\|"tiff"\|"jpeg"\|"png", width, height, metadata}` (no full decode) |
| `thumbnail` | `{path, long_edge}` | `{image}` + rgba8 payload (embedded RAW preview when present, else a fast decode) |

`metadata`: `{make?, model?, lens?, iso?, shutter_s?, aperture?, focal_mm?, datetime_original?, orientation?}` — feeds the date back and the info readouts.

### Sessions (one per open frame)
| method | params | result |
|---|---|---|
| `open` | `{path, decode?: {raw_mode?: "compatible16"\|"headroom"}, params?: <full or partial params JSON>}` | `{session: "<sid>", width, height, metadata, params: <spk_get_params>, timings_ms: {decode, open}}` |
| `close` | `{session}` | `{}` |
| `set_params` | `{session, delta: {...}}` | `{params}` (the delta is applied transactionally: on error the session is unchanged) |
| `get_params` | `{session}` | `{params}` |
| `solve` | `{session, target}` | `<spk_solve JSON>` |
| `render` | `{session, tier: "live"\|"preview"\|"full", reprint?: bool, format: "rgba8"\|"rgba16", display?: "srgb"\|"display-p3", progress_id?}` | `{image, tier, reprinted: bool, timings_ms}` + pixels |
| `scene_latitude` | `{session, request: {...}}` | `<spk_scene_latitude JSON>` |
| `overscan_geometry` | `{session}` | `<spk_overscan_geometry JSON>` |
| `preview_stock_lut` | `{session, print_stock, format, display?}` | `{image}` + pixels |
| `cancel` | `{session, progress_id}` | `{}` |
| `progress` | `{session, progress_id}` | `<spk_progress JSON>` |

`reprint: true` uses `spk_reprint` (print-side edits only; API-SPEC §2); the host
falls back to `spk_render` and reports `reprinted: false` when the engine refuses.

### Export
| method | params | result |
|---|---|---|
| `export_image` | `{session, path, format: "tiff16"\|"tiff8"\|"jpeg"\|"png", quality?, color_space?: "sRGB"\|"display-p3"\|"prophoto", long_edge?, overwrite?: bool}` | `{path, width, height, bytes}` |
| `export_cube` | `{print_stock, path, size?}` | `{path}` |
| `export_di` | `{session, print_stock, path}` | `{path}` |

Events: `{"event": "progress", "session", "progress_id", "fraction", "stage"}`,
`{"event": "log", "level", "message"}`.

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
`resources/host/`. The Electron main process launches
`resources/host/spektralab-host[.exe] --resources resources/host/engine`.
In development, `SPEKTRALAB_HOST_DIR` overrides the directory.
