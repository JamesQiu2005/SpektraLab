# IMPL — the decode pipeline: cancellation, single flight, cache, and the removal of Browse

**Companion to** `PRD/BUG-DIAGNOSIS-2026-09-14-export-and-decode.md` §1 and §7,
and `PRD/PRD-export-page-v2.md` §3.
**Depends on / feeds** `rfc/RFC-019-memory-management.md`.

**This document is implementation logic, not a patch.** It exists because the
change touches the most load-bearing file in the app (`Model/Session.swift`,
2494 lines) and a worker session that improvises here will break the canvas,
the before/after split, or the export harness — all three of which have already
been broken once by changes that looked local. Read §1 before writing anything.

---

## 1. Rules for whoever implements this

1. **Do not change what any render produces.** This work changes *when* work
   runs, *who owns* its output and *whether it can be cancelled*. Every pixel
   must be identical afterwards. If a change makes a picture different, it is
   the wrong change, even if it is faster.
2. **The comments in `Session.swift` and `ImageDecoder.swift` are paid-for
   knowledge.** Several document defects that cost days (the upside-down
   develop that survived a 27-case parity suite; the `MTLBuffer.contents()`
   autorelease trap; `.shaderWrite` being load-bearing; "do NOT
   `matchedToWorkingSpace` the RAW output"). When you move code, move the
   comment with it. When you delete code, prove the comment is obsolete before
   deleting the comment.
3. **Land it in the order in §2.** Step 1 alone fixes the freeze. Steps 2–5 are
   improvements on a working app. Do not start step 4 before step 1 is green.
4. **One commit per step**, each with its own verification from §8 run and
   recorded. A commit that changes two steps cannot be bisected.
5. **`AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` and `CONTRACT-*` belong to
   nobody in particular** — say so before editing one.
6. **Do not implement RFC-017.** Nothing here is apply-to-all or batch
   processing.
7. **If a test needs a fixture, copy it.** A develop writes a sidecar; opening a
   checkout frame in place mutates the repo and changes the exposure meter.

---

## 2. Order of work

| step | what | fixes | risk |
|------|------|-------|------|
| 1 | Single-flight, cancellable frame pipeline | the freeze | **high** — the core of the app |
| 2 | Delete or rebuild the prefetch | memory churn, pool pressure | low |
| 3 | Cheaper decode (drop the probe filter), budget the native original | ~1/3 of the decode transient | low |
| 4 | The decode cache (RAM residency + disk) | 4 GB re-decode on revisit | medium |
| 5 | Delete Browse; fix `ThumbnailCache` | the "import page"; unbounded cache | low |

---

## 3. Step 1 — one frame pipeline, and it can be cancelled

### 3.1 The defect, restated as a mechanism

`Session.select(_:)` (`Session.swift:1108`) ends with:

```swift
loadTask?.cancel()                 // :1111 — cancels the MainActor wrapper
…
loadTask = Task { await load(url) }   // :1161
prefetchNeighbours(of: url)           // :1162
```

`load(_:)` then does the real work inside detached tasks:

```swift
let decodedImage = await Task.detached(priority: .userInitiated) {   // :1289
    try? ImageDecoder.decode(url, settings: settings)
}.value
…
let preview = await Task.detached(priority: .userInitiated) {        // :1303
    TextureBox(ImageDecoder.makePreviewTexture(d, device: device, maxEdge: edge))
}.value
```

and `scheduleNativeOriginal` (`:1242`) and `prefetchNeighbours` (`:1710`) do the
same shape.

A detached task inherits **nothing** — not priority, not task-locals, and **not
cancellation**. `loadTask?.cancel()` makes the `await …value` return on the
*awaiting* side; the detached body runs to completion regardless. And the bodies
cannot notice anyway: neither `ImageDecoder.decode` nor
`ImageDecoder.makePreviewTexture` contains a single cancellation check, and
`makePreviewTexture` ends in a blocking `cb.waitUntilCompleted()`
(`ImageDecoder.swift:312`) that parks a cooperative-pool thread.

Five uncancellable, thread-parking jobs are committed per click. The pool is
bounded by core count and does not grow for blocked threads, so stale
`.utility`/`.background` work starves the `.userInitiated` decode the user is
waiting for. Observed: 25 clicks, zero completed decodes, 10.5 GB pinned for
eleven minutes.

### 3.2 The shape of the fix

One session-owned executor. One frame in flight. Superseding cancels.

```
FramePipeline (actor)
  ├─ submit(FrameJob) → replaces the queued job, cancels the running one
  ├─ exactly one job runs at a time
  └─ a job is a sequence of cancellable stages

FrameJob
  url, DecodeSettings, generation
  stage 1  decode        → DecodedImage       (cancellable between filters)
  stage 2  preview       → MTLTexture         (cancellable before submit)
  stage 3  native orig   → MTLTexture         (optional, budgeted, cancellable)
```

**Why an actor and not an `OperationQueue`:** the call sites are already
`async`, the results already cross back to `@MainActor`, and the generation
check the code already performs (`guard selection == url`) maps directly onto a
job generation. An `OperationQueue` would work and is easier to reason about for
cancellation; if the actor version fights the compiler, take the queue. **What
must not happen is a third `Task.detached` appearing anywhere in the load path.**

### 3.3 Cancellation must reach the work

Three changes, all in `Import/ImageDecoder.swift`:

1. `decode(_:settings:)` gains a `Task.checkCancellation()` before it constructs
   each `CIRAWFilter` and before it reads `outputImage` (which is where the
   demosaic actually happens). A cancelled decode then costs at most one filter.
2. `makePreviewTexture` gains a check before `context.render` and before
   `cb.commit()`.
3. `makePreviewTexture` stops parking a thread on `cb.waitUntilCompleted()`
   (`:312`). Either bridge `cb.addCompletedHandler` to a
   `withCheckedContinuation`, or keep the blocking wait but run the whole
   function off the cooperative pool (a dedicated `DispatchQueue` the pipeline
   owns). **Bridging is preferred**; the dedicated queue is the safe fallback if
   the continuation version misbehaves under cancellation.

Both functions become `throws` (they already can fail; they currently return
optional). Callers that do not care about the distinction keep `try?`.

### 3.4 What `select(_:)` becomes

Structurally unchanged — the same twenty-odd lines of state reset, in the same
order, for the same reasons. Only the tail changes:

```swift
// was: loadTask = Task { await load(url) }; prefetchNeighbours(of: url)
pipeline.submit(FrameJob(url: url, settings: sidecar.decode, generation: nextGeneration()))
```

**Everything above that line stays exactly as it is.** In particular do not
"tidy" any of these — each is load-bearing and several are commented as such:

- `renderer.store.print(for: url)` / `.source(for: url)` lookup before the load,
  which is what makes a frame switch instant (`:1147-1155`);
- `fullGeneration += 1` and `fullTask?.cancel()`;
- `refusal = nil` / `memoryWarning = nil` — RFC-016 §11.5, both belong to the
  frame going away;
- `sampleMemory("frame_switch")` — RFC-016 §3 boundary;
- the `decodeIsStale` flag rather than `decoded = nil`, which exists so the
  white-balance panel does not blank on every drag (`:700-704`).

### 3.5 What `ensureDeveloped` needs

`ensureDeveloped()` (`Session.swift:1380-1404`) currently loops on `loadTask`:

```swift
while decoded == nil || decodeIsStale, let load = loadTask {
    await load.value
    if loadTask == load { break }
}
```

That loop encodes a real requirement and its comment explains it: a Kelvin-slider
drag supersedes one load with another, and giving up after one wait made Solve,
Export and a slider release do nothing while the drag settled. **Preserve the
behaviour exactly**: the pipeline exposes `await pipeline.settled(for: url)`
which returns when no newer job for that url is queued or running. Port the
comment.

### 3.6 The generation check stays

`load`'s guards (`guard !Task.isCancelled, selection == url` at `:1293`, `:1307`,
`:1322`) stay. Cancellation reaching the work does not make them redundant — a
job that finishes a microsecond before the user clicks elsewhere must still be
dropped. Add one thing: when a result is dropped, **write a log record**
(`open` with `mode: "superseded"`). Today it is dropped silently, which is why
the log showed twenty frame switches and no decodes and gave no reason.

### 3.7 Verification for step 1

- **The 30-click test.** Open the Nikon Z7 II folder, click through 30 frames as
  fast as the machine allows, stop. Then:
  - within 5 s, `phys_footprint` is within 500 MB of the single-frame baseline;
  - the last frame produces an `open` record with a real `decode_ms`;
  - every other click produces either an `open` record or a `superseded` one —
    no click is unaccounted for.
  Today: no `open` records at all, 10.5 GB pinned for eleven minutes.
- **A unit test that cancellation reaches the decoder.** Submit a job, cancel
  it, assert the decoder's stage counter stopped advancing. Then break the
  cancellation check on purpose and watch the test go red — the repeat defect
  in this repo is a guard that cannot fire.
- The existing `OpenPathTests`, `DecodeSeparationTests`, `EngineClientTests`
  stay green, unmodified.

---

## 4. Step 2 — the prefetch

`prefetchNeighbours(of:)`, `Session.swift:1701-1719`, eighteen lines with three
defects:

```swift
guard prefetch[f.id] == nil, renderer.store.source(for: f.id) == nil else { continue }
…
prefetch[f.id] = Task.detached(priority: .background) { … }
```

1. Entries are **never removed and never cancelled** — not on frame change, not
   on `open(urls:)`, not on completion. A 200-frame folder accumulates 200
   retained tasks and up to 200 queued full decodes.
2. `prefetch[f.id] == nil` means a frame prefetched once is **never prefetched
   again**, even after `TextureStore`'s LRU (capacity 8) evicted its texture. The
   cache it exists to fill goes cold and stays cold.
3. `.background` + blocking `waitUntilCompleted` is the worst case for the pool.

**Default action: delete it.** Then measure a frame switch again with step 1 in
place and, after step 4, with the decode cache in place. A prefetch is only
worth having if the measurement says the cache misses matter, and this one has
never been measured.

If it comes back: same pipeline, strictly lower priority than the foreground
job, entries removed on completion, cancelled on frame change and on
`open(urls:)`, and the `prefetch[f.id] == nil` guard replaced by a cache lookup.

---

## 5. Step 3 — a cheaper decode, and a budgeted native original

### 5.1 Drop the third RAW filter

`decodeRAW` (`ImageDecoder.swift:176-190`) builds **three** `CIRAWFilter`s:

```swift
guard let probe = CIRAWFilter(imageURL: url) else { … }          // :178
let asShotT = Double(probe.neutralTemperature), asShotTint = …    // :179
guard let linear = try rawFilter(url, look: .linear, …).outputImage,
      let display = try rawFilter(url, look: .display, …).outputImage
```

The `probe` exists for two `Float` reads. `rawFilter` only overrides
`neutralTemperature`/`neutralTint` in the `default:` branch of the white-balance
switch (`:167-172`), so in the `.asShot` case the `.display` filter still holds
the camera's own values and can be read directly. In the override case the
as-shot values are needed *before* the override — so read them off a filter
constructed inside `rawFilter` before the switch, and return them alongside.

**Do not** assume the two filters agree on as-shot without checking: assert it
once in a test against a real NEF (there are fixtures in the spektrafilm test
tree; copy, do not open in place).

### 5.2 Budget the native original

`scheduleNativeOriginal` (`Session.swift:1219-1265`) renders the display decode
at `min(frame long edge, maxTextureEdge)` — 8256 × 5504 rgba16 = **363 MB**,
every frame switch, uncancellable, blocking.

It is not decoration: it is the "original" the before/after split and Space
compare against, and D4 expresses the viewport against the *native* frame, so a
1600 px preview stretched into it claimed the frame's size while showing a
smaller picture. **Keep the behaviour.** Change three things:

1. It becomes stage 3 of the frame job, so it is cancelled when the frame changes.
2. It is **deferred**: run it when `session.comparing` becomes true, when the
   canvas is zoomed past the preview tier, or after an idle delay — not
   unconditionally on every switch. Which trigger to use is a measurement, not a
   guess; instrument all three and read the log.
3. It asks the arena (RFC-019 §6) before allocating, and skips with a log record
   rather than allocating into a swap storm.

Keep the `maxTextureEdge` clamp exactly as it is. Metal publishes no texture
limit and probing it with `newTexture` aborts the process; the clamp comes from
the engine's `max_texture_dimension_2d` and removing it crashes the app on large
frames.

---

## 6. Step 4 — the decode cache

Specified in `rfc/RFC-019-memory-management.md` §7, and implemented as part of the
one on-disk store described in `PRD/IMPL-RFC-019-memory.md` §6 — the same store
also holds finished prints (RFC-019 §8), which is what answers "where did the
processed picture go" once caches are capped. Implementation notes:

### 6.1 In RAM: `DecodeResidency`, capacity 2

Replaces `Session.decoded: DecodedImage?` (`Session.swift`, the bare var).

- Keyed `(URL, DecodeSettings)`. A white-balance change is a different entry —
  which is already how `decodeIsStale` reasons, so the existing logic maps over.
- Slot A = the frame on the canvas (pinned). Slot B = the previous frame
  (evictable). That is what an A/B comparison needs and nothing more.
- **`Session.decoded` stays as a computed property** returning slot A's image,
  because `setWhiteBalance` and `pickNeutral` read it and the panel's behaviour
  depends on it not blanking mid-drag. Do not make those call sites go through
  the residency.

### 6.2 On disk

`Session.cacheRoot` already exists (`Session.swift:732`,
`~/Library/Caches/com.hanze.filmify`). Add `decode/` under it.

**Read `Session.swift:1680-1700` before writing a line of this.** There was a
4 GB on-disk LRU of linear TIFFs; RFC-014 retired it and
`removeLegacyLinearCache()` deletes what it left. That cache existed to hand a
*file* to an out-of-process engine. This one caches the **display decode at
`previewLongEdge`** — 38 MB an entry, not 363 MB — to avoid a 4 GB decode
transient. Different thing, different reason. Do not resurrect the old one, and
leave `removeLegacyLinearCache()` in place.

- Entry: raw rgba16 at the preview edge, plus a small header (pixel size,
  settings hash, format version).
- Key: SHA-256 of `(volume id + inode + size + mtime, DecodeSettings encoded)`.
  Not the path — a rename must not invalidate; not identity without mtime — an
  edit in another application must.
- Index: `index.sqlite` beside it. One row per entry. SQLite because eviction
  and "how big is this" must be cheap and must survive a crash mid-write.
- Cap: 8 GB default, LRU, own Settings row with a size readout and Clear.
- Version the format. On a bump, delete the directory rather than migrate.

### 6.3 The read path

```
displayPicture(url, settings)
  → residency        hit: instant
  → disk             hit: file read + texture upload (~10 ms)
  → decode           miss: ~200 ms, ~4 GB transient, then populate both
```

Only stage 3 goes through the pipeline's decode stage. The first two are cheap
enough to run inline.

**Acceptance:** revisiting a frame constructs no `CIRAWFilter`. Assert with a
counter in the `open` record, not with a stopwatch.

---

## 7. Step 5 — Browse, and the thumbnail cache

### 7.1 Delete the Browse page

What the user calls 导入页面 is `BrowseView`, swapped in for the whole editor at
`Windows/EditorWindow.swift:34`:

```swift
if session.browsing && !session.frames.isEmpty { BrowseView(session: session) }
```

- Delete `Windows/BrowseView.swift`, the branch at `:34`, the animation at
  `:43`, and `Session.browsing` with its four assignments (`:993`, `:1001`,
  `:1045`, `:1112`).
- `Session.enterBrowse()` (`:1000-1023`) is **not** just the Browse page — it is
  the teardown for "no frame is open" and it cancels the develop, drops the full
  render, invalidates the scheduler and clears the service session. Keep the
  function, keep every line of the teardown, rename it (`clearOpenFrame()`), and
  drop only the `browsing = true`.
- **Keep the behaviour Browse protected.** `Session.open(urls:)` (`:972-998`)
  renders nothing on a multi-file open — that rule exists because the first
  build committed to a 7 s render and a 363 MB TIFF for a frame nobody had
  chosen (`HANDOFF-FRONTEND-POLISH` §2). The editor now shows an empty canvas
  with "Pick a frame from the strip", and the filmstrip is the folder.
- The Grid mode *inside the export page* stays — it is in the reference drawing
  and was not part of this request.
- Browse's Name / Capture-date sort either moves to the filmstrip or is dropped.
  Do not keep the page in order to keep the sort.

### 7.2 `ThumbnailCache`

`Import/ThumbnailCache.swift`, 34 lines, two defects:

```swift
private var cache: [URL: CGImage] = [:]                    // :9  — no eviction
func thumbnail(for url: URL, maxPixel: Int = 320) async -> CGImage? {
    if let c = cache[url] { return c }                     // :13 — key ignores maxPixel
```

Four call sites ask for three sizes: filmstrip 320 (`Filmstrip.swift:125`),
Browse 512 (`BrowseView.swift:152`, going away), export grid and export strip
1024 (`ExportPage.swift:1376`, `:1470`). Whichever lands first wins for all of
them.

- Key on `(url, maxPixel)`.
- Cap by bytes, LRU, registered with the arena as evictable.
- Clear in `Session.open(urls:)` — a new folder is a new set, the same reason
  `picked` is cleared there.
- `store(_:for:)` (`:33`) must store at a stated size, not "whatever the
  renderer produced".

### 7.3 `updateThumbnail`

`Session.updateThumbnail` (`:1664-1677`) runs on **every landed print**, in a
detached task, and starts with `box.texture?.makeCGImage()` — a full CPU copy of
the texture (`Renderer.swift:899-911` copies into a `Data`). At the preview tier
that is 38 MB per render; during a slider drag it is 38 MB per render tick, with
no throttle and no cancellation.

Downsample on the GPU into a small texture first and copy *that*, or throttle to
the last render of a settled edit. Not urgent, but it belongs to this step
because it is the fourth uncancelled detached task in the file.

---

## 8. Verification, end to end

| # | claim | method | today |
|---|-------|--------|-------|
| 1 | 30 rapid switches settle to baseline + 500 MB in 5 s | `memory` records | pinned 10.5 GB, 11 min |
| 2 | Every click yields an `open` or a `superseded` record | log | zero records after frame 2 |
| 3 | At most one decode runs at a time | pipeline counter in the log | up to 5 per click, unbounded |
| 4 | Cancelling a frame stops the decoder | unit test, verified by breaking it | no check exists |
| 5 | Revisiting a frame builds no `CIRAWFilter` | decode counter in `open` | full re-decode, ~4 GB |
| 6 | Pixels unchanged | `RendererTests`, `SoftProofParityTests`, `ColourManagementTests`, `ExportPreviewChainTests`, `DecodeSeparationTests` green and unmodified | — |
| 7 | No `tests` symlink means 25 tests skip silently | check the link exists before believing a green run | — |

Item 7 is not optional. A worktree without the fixture link reports 0 failures
and runs 25 fewer tests, and this repo has been fooled by that before.

---

## 9. Rollback

Steps 2–5 are independent and each reverts cleanly. Step 1 does not: once
`select` submits to the pipeline, the old detached path is gone. Land step 1
behind a `FeatureFlags` entry (`Model/FeatureFlags.swift` already exists and is
how masks were withdrawn) for one release, defaulting **on**, so a bad
interaction with the export harness can be turned off by a user without a build.
Remove the flag once the 30-click test has survived a week of real use.
