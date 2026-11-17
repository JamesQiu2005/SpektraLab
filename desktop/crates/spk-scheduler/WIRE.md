# spk-scheduler — the wire between the webview and the scheduler

This is the contract the Tauri layer (W2) binds to the scheduler crate. It is the prose of
`src/wire.rs`; the two change in the same commit, and `tests/wire.rs` holds every example below to the
code (each JSON block marked `wire-example` there is parsed and re-serialised).

All JSON is camelCase. Where the Mac app has a `Codable` type the Swift names are kept (`jobID`,
`appAvailable`, `predictedPeakBytes`), so a job log reads the same on every platform. **Job ids are
upper-case UUID strings** (Swift's `UUID` encoding); they are accepted in either case. Bytes are
integers; seconds are floats.

## Commands (expected Tauri surface)

| command | argument | reply | crate call |
|---|---|---|---|
| `scheduler_submit` | `JobSpec` | `jobId` (string) | `Scheduler::submit` |
| `scheduler_cancel` | `jobId` | `null` | `Scheduler::cancel` |
| `scheduler_cancel_frame` | `{frameId, kinds?: JobKind[]}` | `null` | `Scheduler::cancel_frame` |
| `scheduler_outcome` | `jobId` | `OutcomeWire` header + binary payload (the protocol's own framing: `u32 header_len · u32 payload_len · JSON · bytes`, as `host_request` replies) | `Scheduler::outcome` |
| `scheduler_snapshot` | `frameId?` | `JobSnapshotWire[]` | `Scheduler::snapshot` |
| `scheduler_budget` | — | `BudgetReadingWire` | `Scheduler::budget` |
| `scheduler_frontend_state` | `FrontendStateMsg` | `null` | `Scheduler::set_frontend_state` |
| `scheduler_memory_pressure` | `"warning"` \| `"critical"` | `null` | `Scheduler::memory_pressure` |
| event `scheduler://job` | — | `JobSnapshotWire`, whenever a job changes | `Scheduler::subscribe` |

`submit` returns at once; the job may already be running. `outcome` resolves when the job ends and may be
called before or after that. **Pixels are delivered once**: the first `outcome` call after a job finished
carries its binary payload (`result.payloadBytes` > 0); a later call for the same job returns the same
header with `payloadBytes: 0`. The scheduler keeps the outcomes of the last 100 jobs, and the payloads of
finished jobs not yet collected up to 1 GiB in all (oldest dropped first); an id it no longer knows reads
as `cancelled`, as on the Mac.

## JobSpec — what the webview submits

```json wire-example JobSpec
{"frameId": "lib:7F1C", "kind": "canvasReprint", "tier": "live",
 "canvas": {"width": 2560, "height": 1707}, "layers": ["print"], "what": "Print Exp. +0.3",
 "opens": {"width": 6000, "height": 4000},
 "request": {"source": {"path": "D:/photos/DSC03710.ARW", "decode": {"raw_mode": "compatible16"},
                        "params": {"film_stock": "kodak_portra_400"}},
             "method": "render_view",
             "params": {"tier": "live", "display": "srgb", "format": "rgba8", "long_edge": 2560,
                        "generation": 41, "adjustments": {}, "geometry": {},
                        "params": {"film_stock": "kodak_portra_400", "print_exposure": 1.1}}}}
```

| field | default | meaning (the Swift `RenderJob`'s) |
|---|---|---|
| `frameId` | required | any string the webview names the frame by, used consistently (coalescing, `cancel_frame`, sessions) |
| `kind` | required | `canvasReprint`, `canvasDevelop`, `shot`, `importDevelop`, `export`, `fullView`, `thumbnail`, `stockPreview` — the priority (1 canvas, 2 shot, 3 export/fullView, 4 stockPreview, 5 importDevelop, 6 thumbnail) |
| `tier` | required | `live`, `preview`, `full` |
| `canvas` | required | `{width, height}` the engine will render |
| `layers` | `[]` | `"shoot"`/`"print"`: what the edit touched; empty is a first develop |
| `what` | `""` | the status line's words |
| `decodesOriginal` | `false` | the job decodes the original (an export, an import) |
| `bandable` | `true` | false for a frame with a crop, turn or flip |
| `original` | — | the original's size, when the decode is priced by it |
| `printLayers` | `0` | more prints of the negative cut into the result |
| `opens` | — | the frame the engine opens, when larger than the canvas |
| `slot` | — | a strip card's slot: a newer `stockPreview` of the same frame and slot replaces it |
| `gainMap`, `gainMaps` | `false`, `1` | an export with a gain map |
| `hdrRendition` | `false` | a slide's second (HDR) rendition |
| `composition` | — | `{decodes: [{width,height}…], scratchBytes, raw}`: a double exposure's open |
| `rawDecode` | `false` | below Full, the open decodes a RAW (no proxy) |
| `scenePlanes`, `scenePlaneBytes`, `watermarkBytes` | `0` | what those passes hold beside the render |
| `request` | — | the host calls (below). Required by the real engine; a job without one fails with `failed: the job has no host request` |

**Pricing a job for the v1 host.** The v1 host's `open` decodes the whole file whatever tier is later
rendered, so a job below the full tier that opens a session should send `opens` = the decoded size
(`probe`'s `width`/`height`) and `decodesOriginal: true` + `original` for its first open of a frame. A
job priced at its canvas alone is under-priced, and its record will say `openedInstead`.

### JobRequest — the host calls

```json wire-example JobRequest
{"source": {"path": "D:/photos/DSC03710.ARW"},
 "setParams": {"print_exposure": 1.1},
 "method": "render", "params": {"tier": "live", "reprint": true, "format": "rgba8", "display": "srgb"}}
```

- `method` is one of HOST-PROTOCOL.md §3's: `render_view`, `render`, `export_frame`, `export_cineon`,
  `render_proof`, `export_image`, `preview_stock_lut`, `render_source`, `thumbnail`. `params` are its
  params **without** `session` and `progress_id`: the engine adds both (a `session` the webview sends is
  replaced).
- `source` is `open {path, decode?, params?}`, or `open_pair {path, pair, params}` when `pair` is set.
- `setParams` is sent as `set_params {session, delta}` before the call.

**Sessions** — the engine owns them (the Mac's `SpkEngine` rules):

- **A canvas job** (`canvasReprint`, `canvasDevelop`) runs on the frame's **editing session**, kept open
  between canvas jobs so a print-side edit reprints from the cached negative. One editing session at a
  time: a canvas job of another frame closes the old one first. The same frame from another `decode`
  is `redecode`d in place; another `path` or `pair` is opened again.
- **Every other job is one-shot**: it opens its own session and closes it when it ends, however it ends.
  `export_frame`, `export_cineon` and `render_proof` run without one: the engine sends `source_path`
  (from `source.path` unless given) and the host opens a private session. `thumbnail` needs none.
- `preview_stock_lut` and `render_source` borrow the editing session when it is the same frame from the
  same source (they do not change its parameters); otherwise they are one-shot.
- The editing session closes when `FrontendStateMsg.openFrame` moves to another frame, and when a job
  someone waits on cannot fit (the scheduler's reclaim; a canvas job of the same frame keeps it).
- If the host dies, every session is forgotten; the job in flight fails with
  `host_exited: …` and the queue goes on. A session the host no longer knows (`not_found`) is opened
  again once.

**Cancel** sends `cancel {session, progress_id}` for the call in flight (`session: ""` for a private
export); a call that takes no `progress_id` (`thumbnail`, `preview_stock_lut`, `open`) finishes and its
result is discarded. Either way the job ends `cancelled`.

**Bands.** The v1 host renders whole frames. A job the planner put in bands is run whole and recorded as
such (`ran: "whole"`), exactly as the Mac desktop's engine does.

## JobSnapshotWire — `scheduler_snapshot` and the `scheduler://job` event

```json wire-example JobSnapshotWire
{"jobId": "6F1D2C3B-8E2A-4A35-9C8B-2D7E5B1A0C11", "frameId": "lib:7F1C", "kind": "export", "tier": "full",
 "canvas": {"width": 8256, "height": 5504}, "what": "Export JPEG", "verb": "Developing",
 "state": "waiting", "reason": "memory", "text": "Waiting for memory", "mode": "wait(memory)"}
```

`state` is one of:

| state | extra fields |
|---|---|
| `queued` | — |
| `waiting` | `reason`: `memory` \| `camera` \| `capture` \| `background` \| `queued`; `text`: the page's words |
| `running` | `stage`: `Decode` \| `Film` \| `Print` \| `Scan` \| `Save`; `fraction` 0…1 across the job; `band`, `bandCount` |
| `done`, `cancelled` | — |
| `failed` | `message` |

`mode` is the plan's: `"whole"`, `"bands(1008)"`, `"wait(memory)"`, or `null` before it is planned.
`scheduler_snapshot(frameId)` returns the job a frame's page should show (the running one, else the first
waiting) as a one-element array, or `[]`; without a frame, every job not finished. The event fires on
every change, including the last (`done`, `cancelled`, `failed`).

```json wire-example JobSnapshotWire
{"jobId": "6F1D2C3B-8E2A-4A35-9C8B-2D7E5B1A0C12", "frameId": "lib:7F1C", "kind": "canvasDevelop", "tier": "live",
 "canvas": {"width": 2560, "height": 1707}, "what": "Film Exp. +0.3", "verb": "Developing",
 "state": "running", "stage": "Film", "fraction": 0.35, "band": 0, "bandCount": 1, "mode": "whole"}
```

## OutcomeWire — `scheduler_outcome`

```json wire-example OutcomeWire
{"jobId": "6F1D2C3B-8E2A-4A35-9C8B-2D7E5B1A0C12", "outcome": "finished",
 "result": {"seconds": 0.21, "reprint": false, "size": {"width": 2560, "height": 1707},
            "method": "render_view",
            "hostResult": {"image": {"width": 2560, "height": 1707, "format": "rgba8", "color_space": "sRGB",
                                     "row_bytes": 10240}, "generation": 41, "print_cached": false},
            "payloadBytes": 17479680}}
```

```json wire-example OutcomeWire
{"jobId": "6F1D2C3B-8E2A-4A35-9C8B-2D7E5B1A0C13", "outcome": "failed", "message": "engine_error: out of device memory"}
```

`outcome`: `finished` \| `cancelled` \| `failed` (`message`). `hostResult` is the host reply's `result`
verbatim (`image`, `timings_ms`, an export's `path`/`bytes` …); the binary payload is the reply's.

## BudgetReadingWire — `scheduler_budget`

```json wire-example BudgetReadingWire
{"budget": {"bytes": 1190000000, "appSide": 5980000000, "phoneSide": 1400000000, "appBytes": 5083000000,
            "phoneBytes": 1190000000, "cameraReserve": 0, "binding": "phone"},
 "asked": {"bytes": 1700000000, "appSide": 5980000000, "phoneSide": 1850000000, "appBytes": 5501600000,
           "phoneBytes": 1702000000, "cameraReserve": 0, "binding": "phone"},
 "reading": {"appAvailable": 6133000000, "free": 2000000000, "inactive": 0, "purgeable": 0, "wired": 0,
             "compressed": 0, "footprint": 512000000},
 "frontend": "camera off; active",
 "engine": {"name": "spektralab-host 0.1.0", "makesPictures": true, "effectVersions": "build=…"},
 "policy": {"device": "desktopPc", "developCapMegapixels": 120.0, "previewLongEdge": 1920,
            "previewEdges": [1600, 1920, 2400, 2560, 3200, 3840], "timeRatio": 1.0,
            "unmeasured": ["timeRatio", "allowance share of installed RAM", "GPU reserve"]},
 "jobs": 1}
```

`binding` is `allowance` (the app's allowance), `phone` (the host's headroom; the Swift name) or `gpu`
(a PC's GPU memory, only when the reading has `gpuAvailable`). `reading` is `MemoryReading`, with the
Swift keys; on a PC it may carry `gpuAvailable`. `policy.unmeasured` lists every number that was not
measured on this kind of machine: **every Windows-specific number is unmeasured**.

## FrontendStateMsg — `scheduler_frontend_state`

```json wire-example FrontendStateMsg
{"visiblePage": "develop", "openFrame": "lib:7F1C", "foreground": true, "scene": "active",
 "interaction": {"dragging": "print"}, "thermal": "nominal", "lowPower": false}
```

- `scene` is the gate: anything but `active` holds every job (`waiting`/`background`). A desktop keeps
  rendering behind other windows, so the Tauri layer sends `active` unless it means to pause.
  `foreground` is recorded only.
- `openFrame` moving to another frame closes the old frame's editing session.
- `interaction` while a pointer is on a slider; `null`/absent when idle. `thermal`: `nominal`, `fair`,
  `serious` (reprints at most 8 a second), `critical` (4).
- `cameraPhotoMegapixels`, `capturesInFlight`: the phone's camera rules; a desktop never sends them.

## JobRecord — the job log (`Scheduler::set_job_log`, `JobLogFile`)

One JSON object a line, keys sorted, dates ISO-8601 to the second — the Mac's `scheduler-log.jsonl` line:

```json wire-example JobRecord
{"appSideBytes":6133000000,"at":"2026-11-17T10:19:00Z","binding":"phone","budgetBytes":1190000000,
 "cameraReserveBytes":0,"frontend":"camera off; active","jobID":"6F1D2C3B-8E2A-4A35-9C8B-2D7E5B1A0C11",
 "kind":"export","tier":"full","measuredSeconds":2.4,"megapixels":45.44,"mode":"bands(1008)","outcome":"done",
 "phoneSideBytes":1400000000,"predictedPeakBytes":1491000000,"predictedPhoneBytes":2036000000,
 "predictedSeconds":2.86,"ran":"whole","reading":{"appAvailable":6133000000,"compressed":0,"footprint":0,
 "free":2000000000,"inactive":0,"purgeable":0,"wired":0},"waits":["memory"]}
```

`outcome` is `done`, `cancelled`, `cancelled: superseded`, `cancelled: gave way, runs again`,
`cancelled: pressure, runs again smaller` or `failed: <message>`. `measurement` (`RunMeasurement`, Swift
keys), `renderedInstead` and `openedInstead` appear when there is something to say.
