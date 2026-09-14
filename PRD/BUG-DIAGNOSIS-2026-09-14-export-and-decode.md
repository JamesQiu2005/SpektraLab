# Bug diagnosis — 2026-09-14: the export page, the decode path, and the ghost dot

**Status:** diagnosis only. **No code was changed in this session.** Every
"fix" below is a direction for the worker session, not an applied patch.

**Read with:**
- `PRD/IMPL-decode-pipeline.md` — the implementation logic for §1, §5 and §7
- `PRD/PRD-export-page-v2.md` + `PRD/IMPL-export-page-v2.md` — for §2, §3, §4, §6, §8
- `rfc/RFC-019-memory-management.md` + `PRD/IMPL-RFC-019-memory.md` — ownership,
  the enforced memory cap, the managed residency for the decoded RAW, and where
  a finished print goes once caches are capped. **RFC-019 §2 is the estimated
  before/after** — live-edit latency, frame-switch latency and RAM — derived
  from the same log this document quotes.

**Reproduction the user ran:** open the folder
`/Users/xiaojinqiu/Documents/Summer 2026/spektrafilm/tests/Test_image/Nikon Z7ii`
(45 MP Nikon Z7 II NEFs) in the app, step through frames, open the export page.

**Primary evidence:** `~/Library/Logs/Filmify/filmify-2026-09-14T09-44-15-19555.jsonl`
(the 09:44–09:57 session). Quoted throughout. Machine: M3 Max, 38.7 GB RAM,
`preview_edge` 2678, `max_texture_dimension_2d` 16384.

---

## 0. Summary of findings, ranked

| # | Finding | Severity | Evidence |
|---|---------|----------|----------|
| A | Detached decode/render tasks are **never cancelled**; `loadTask?.cancel()` cancels only the MainActor wrapper | **Blocker** | log: 25+ `frame_switch`, zero `open` records after the 2nd frame |
| B | Footprint plateaus at **10.5–10.9 GB**, peak **14.8 GB**, and never returns | **Blocker** | log seq 6–51 |
| C | No decode cache: `decoded` is a single slot; going back to a frame re-runs a ~4 GB decode | **High** | log seq 2→3: 274 MB → 4364 MB for one decode |
| D | The soft proof renders and holds a **full 45 MP CGImage** (~1.8 GB of transient textures) and SwiftUI resamples it every draw | **High** | `Exporter.filePixels`, `ExportPage.viewerPane` |
| E | Export page's worklist lists the **whole folder**, not the picked set | **High** (user-reported #1) | `ExportPage.swift:1089,1118`, `:447` |
| F | Export of an untouched frame forces a full film develop; there is no "decode + adjustments only" route | **High** (user-reported #3.2) | `ExportPage.run()` → `session.ensureDeveloped()` |
| G | The bottom-right white dot lives in **four** cells, suppressed in only one place | **Medium** (user-reported #3.3) | four `Circle().fill(Theme.text)` sites |
| H | `ThumbnailCache` key ignores `maxPixel` and never evicts | **Medium** | `ThumbnailCache.swift:9,12,13` |
| I | The "import page" (Browse) is an unwanted interstitial | **Medium** (user-reported #2) | `EditorWindow.swift:34` |
| J | Export viewer pane has no pointer/hand tool and its "100 %" is not 1:1 | **Medium** (user-reported #3.1) | `ExportPage.viewerPane`, `zoomPill` |

---

## 1. The freeze (user report #2) — this is the one that matters

### 1.1 What the log actually says

```
09:44:15.386  memory launch          182 MB
09:44:26.015  memory frame_switch    274 MB
09:44:26.617  memory decode         4364 MB   ← one 45 MP NEF decode: +4.1 GB
09:44:26.617  open   decode          decode_ms 208.9  preview_texture_ms 276.3   _DSC0897.NEF
09:44:30.870  memory engine.open    4530 MB   (+727 MB engine frame)
09:44:31.349  memory first_print    5725 MB
09:45:00 … 09:46:22  ~15 full-tier reprints, 8256×5504, 90–800 ms each
09:46:24.998  memory frame_switch  10680 MB   ← doubled with NO decode in between
09:46:25.536  memory decode        14765 MB   ← session peak, free 13.6 GB
09:46:25.536  open   decode          _DSC2715.NEF                  ← THE LAST `open` RECORD
09:46:25.551  memory frame_switch  14623 MB
09:46:25.876  memory frame_switch  14652 MB
09:46:26.355  memory frame_switch  14663 MB
09:49:49 … 09:50:06  13 more frame_switch, 10.5–10.9 GB
09:57:50 … 09:57:53  3 more frame_switch, 10.5–10.9 GB
```

Two facts kill every other hypothesis:

1. **After 09:46:25 there is not a single `open` record and not a single
   `render` record** — for eleven and a half minutes, across ~20 more frame
   switches. The app is still accepting clicks (each `select()` samples
   `frame_switch`), but no decode ever lands and nothing is ever rendered. That
   is not "slow", that is a stalled pipeline.
2. **Footprint never falls below 10.5 GB** after the second frame, even minutes
   later with nothing on screen. Live memory would fall; this does not.

(The `seq` gap 28→48 is not lost data — `MemorySampler` writes the live readout
tick at `debug`, which at Normal level reaches the ring buffer and not the file.
`MemorySampler.swift:73-76`.)

### 1.2 Root cause A — cancellation does not reach the work

`Session.select(_:)` cancels the load (`Session.swift:1111`, `loadTask?.cancel()`),
and `scheduleNativeOriginal` cancels its own wrapper (`Session.swift:1232`). But
every expensive operation in the open path runs inside a **`Task.detached`**,
and a detached task inherits nothing — not priority, not a task-local, and **not
cancellation**:

- `Session.swift:1289` — the RAW decode: `await Task.detached(priority: .userInitiated) { try? ImageDecoder.decode(url, settings: settings) }.value`
- `Session.swift:1303` — the preview texture, same shape
- `Session.swift:1243` — the **native-resolution** original, inside `nativeOriginalTask`
- `Session.swift:1710` — the two neighbour prefetches, `priority: .background`

Cancelling the wrapper makes the `await …value` throw/return on the *awaiting*
side. The detached body keeps running to completion. And the body cannot notice
either: `ImageDecoder.decode` and `ImageDecoder.makePreviewTexture`
(`ImageDecoder.swift:288`) contain **no `Task.checkCancellation()` and no
`Task.isCancelled` check anywhere**, and `makePreviewTexture` ends in a blocking
`cb.waitUntilCompleted()` (`ImageDecoder.swift:312`).

So each frame switch permanently commits, at minimum:

| work | cost | cancellable? |
|------|------|--------------|
| 1 × full RAW decode (3 `CIRAWFilter`s: probe, linear, display) | ~4 GB transient, 160–210 ms | no |
| 1 × preview texture render at 2678 px | ~38 MB, 276–337 ms | no |
| 1 × **native** original render at up to 8256 × 5504 rgba16 | **363 MB**, blocking `waitUntilCompleted` | no |
| 2 × neighbour prefetch (full decode + full preview render each) | ~8 GB transient | no |

Five uncancellable, thread-blocking jobs per click. Twenty-five clicks in the
logged session ≈ 125 queued jobs. The Swift cooperative pool is bounded by core
count and **does not grow for threads blocked in `waitUntilCompleted`**, so the
pool saturates with stale work at `.utility`/`.background` priority while the
one job the user is waiting for — the current frame's `.userInitiated` decode —
sits behind it. Classic priority inversion by way of blocking calls in the
cooperative pool.

That is exactly the observed signature: clicks are accepted, memory stays pinned
at the high-water mark of the in-flight set, and **no decode ever lands** —
because when a stale one finally does, `guard … selection == url` (`Session.swift:1293`)
drops it silently without writing an `open` record.

**Direction for the worker:** the decode/render path needs a *bounded serial
executor* the session owns (one actor with a depth-1 replaceable slot, or an
`OperationQueue` with `maxConcurrentOperationCount = 1` and real
`cancelAllOperations`), and `ImageDecoder` needs cancellation checks between
stages. Superseding a frame must *cancel the work*, not just stop waiting for
it. The user's guess ("core image 调用链路没有做好…一股脑全丢过去了") is correct.

### 1.3 Root cause B — the prefetch is fire-and-forget and never cleaned

`Session.prefetchNeighbours(of:)`, `Session.swift:1701-1719`:

```swift
guard prefetch[f.id] == nil, renderer.store.source(for: f.id) == nil else { continue }
…
prefetch[f.id] = Task.detached(priority: .background) { … }
```

Three defects in eighteen lines:

1. The dictionary entry is **never removed and never cancelled** — not on frame
   change, not on `open(urls:)`, not on completion. Walking a 200-frame folder
   accumulates 200 retained `Task`s and, worse, up to 200 queued full decodes.
2. The `prefetch[f.id] == nil` guard means once a frame has been prefetched it
   is **never prefetched again**, even after `TextureStore`'s LRU (capacity 8,
   `TextureStore.swift:52`) has evicted its texture. So the cache the prefetch
   exists to fill goes cold and stays cold.
3. `.background` priority + blocking `waitUntilCompleted` is the worst possible
   combination for the cooperative pool (see 1.2).

### 1.4 Root cause C — no decode cache at all (the user's diagnosis, confirmed)

`Session.decoded` is a **single** `DecodedImage?`. Returning to a frame you
looked at ten seconds ago re-runs the whole decode. From the log that is
**+4.1 GB and ~500 ms** every time — and the user explicitly wants to A/B
frames, which is the access pattern this punishes hardest.

What *is* cached today:
- `TextureStore` — GPU textures only: 8 source previews + 8 preview-res prints,
  one full render slot (`TextureStore.swift:44-53`). Nothing on disk.
- `ThumbnailCache` — in-memory `[URL: CGImage]`, see §5.

The user proposes "a small database + object store". That is the right shape and
is specified in the PRD (§4 of `PRD-export-page-v2.md`): an on-disk,
size-capped, content-addressed cache of the *display* decode at a bounded edge,
plus a small index. Note the decode is cheap-ish (~200 ms); the **4 GB
transient** is the thing to avoid, and a cached preview avoids re-entering
`CIRAWFilter` entirely.

### 1.5 Where the 4 GB per decode comes from

`ImageDecoder.decodeRAW` (`ImageDecoder.swift:176-190`) constructs **three**
`CIRAWFilter`s per call — a `probe` for as-shot values, one for `.linear`, one
for `.display`. Each opens and demosaics the 45 MP file. The `probe` is used for
exactly two `Float` reads (`neutralTemperature`, `neutralTint`) and is otherwise
pure waste; those two values are also obtainable from either real filter before
the white balance is overridden, or from EXIF.

The shared `CIContext` sets `.cacheIntermediates: false` (`ImageDecoder.swift:135`),
which is correct and already rules out the obvious alternative explanation.

### 1.6 Secondary: the native original render is unbudgeted

`scheduleNativeOriginal` (`Session.swift:1219-1265`) renders the display decode
at `min(frame long edge, maxTextureEdge)` — for these files 8256 × 5504 rgba16 =
**363 MB**, every frame switch, uncancellable, blocking. It exists so the
before/after split is sharp. It should be (a) cancellable, (b) budgeted against
free memory, (c) deferred until the user actually asks for a comparison.

---

## 2. The export page carries the whole folder (user report #1)

**The batch is correct; the worklist is not.** `ExportPage.batch` is
`session.selectedFrames` (`ExportPage.swift:217`), which is `picked`-filtered
(`Session.swift:61`), and `picked` is only ever moved by `click` — the
selection model is sound and well-tested.

What the user sees is the **presentation**:

- `ExportPage.stripPanel` iterates `ForEach(session.frames)` — the whole folder —
  and merely marks the picked ones (`ExportPage.swift:1118`).
- `ExportPage.gridCard` does the same (`ExportPage.swift:1089`).
- `ExportPage.countPill` reads `session.frames.count`, so the pill says
  "27 images" when 3 are picked (`ExportPage.swift:447`). Only the *tooltip*
  says "3 of 27".

So every frame in the folder appears in the export page, each one spawning a
1024 px thumbnail request (§5), and the header agrees with that reading.

The user's rule is unambiguous: **only the ⌘-clicked set enters the export
page.** They also explicitly praised the current behaviour of the viewer
staying on the previously-viewed image — that must not change.

One consequence to design for: `ExportPage.adoptSessionSelection`
(`ExportPage.swift:176`) exists to cover "page opened from Browse with an empty
set". If the worklist becomes picked-only, an empty set means an empty page —
the page needs an explicit empty state, not a silent auto-pick. See the PRD.

---

## 3. Exporting an untouched frame (user report #3.2)

`ExportPage.run()` (`ExportPage.swift:1273-1281`) does, per frame:

```swift
if session.selection != url { session.select(url) }
guard let sid = await session.ensureDeveloped() else { … }
let out = try await Exporter.export(session:recipe:context:sessionID:)
```

`ensureDeveloped` always runs the **full film develop**: engine open with a
727 MB frame buffer, solve, full-tier reprint. There is no branch for "this
frame has no sidecar and the user never touched it".

The user's guess — "导出渲染的时候默认就是所有图片都有对应的sidecar还有film edit
profile" — is nearly right, with an important correction: a missing sidecar does
**not** fail. `Sidecar.load(for:) ?? Sidecar()` (`Session.swift:1125`) hands back
defaults, so an untouched frame is silently exported **with a default film stock
and print stock applied**. That is worse than failing: it is wrong output, at
maximum cost.

The two things wanted:

1. **A straight route.** A frame with no film profile should export the Core
   Image decode plus Layer 2 adjustments, geometry and the output transform —
   never touching the engine's film side. Supported, not advertised.
2. **The cost.** Today each batch entry pays select → decode (~4 GB) → engine
   open (727 MB) → solve → full render (363 MB), serially, on a session already
   pinned at 10 GB. This is why the export "完全卡死" — it is finding #1
   again, at N× the size.

Note `Exporter.filePixels` (`Exporter.swift:335-372`) allocates, per frame, at
45 MP: `full` → `adjusted` → `framed` → `sized` → `converted` → `CGImage`. That
is roughly **1.8 GB of live textures** for one export, before any of it is freed.

---

## 4. The export page's own hangs (proof rendering)

`ExportPage` renders a soft proof on `.task(id: proofKey)` (`:164`), which calls
`Session.softProof` (`SoftProof.swift:94`) → `Exporter.filePixels` → **a
full-tier 45 MP engine render**, and holds the result as a 45 MP `CGImage` in
`@State private var proof`. `filePreview` can hold a second one.

Then `viewerPane` (`ExportPage.swift:955-963`) does:

```swift
Image(decorative: shown, scale: 1).resizable().interpolation(.high)
    .frame(width: fitted.width * zoom, height: fitted.height * zoom)
```

SwiftUI resamples a 45 MP CGImage down to a ~1200 pt pane, with high-quality
interpolation, **on the main thread, every draw** — every scroll, every zoom
step, every window resize. This alone will beachball the page.

`proofKey` correctly excludes pane size, and `.task(id:)` coalescing is the
right mechanism — the problem is not re-render frequency, it is that the object
being displayed is 45 MP. The proof's *claim* ("these are the file's own
pixels") only needs the full-size render for its **statistics**; the picture on
screen needs a downsampled copy.

---

## 5. The thumbnail cache (contributing, and a correctness bug)

`ThumbnailCache` (`Import/ThumbnailCache.swift`):

```swift
private var cache: [URL: CGImage] = [:]                       // :9
func thumbnail(for url: URL, maxPixel: Int = 320) async -> CGImage? {
    if let c = cache[url] { return c }                        // :13
```

- **The key ignores `maxPixel`.** Four call sites ask for three different sizes:
  filmstrip 320 (`Filmstrip.swift:125`), Browse 512 (`BrowseView.swift:152`),
  export grid *and* export strip 1024 (`ExportPage.swift:1376,1470`). Whichever
  lands first wins for all of them. Open the export page first and every
  filmstrip cell holds a 1024 px CGImage (~10× the memory); open the filmstrip
  first and the export grid shows 320 px mush at 1024 pt.
- **Nothing is ever evicted.** No cap, no LRU, no purge on `open(urls:)`. A
  300-frame folder browsed at 1024 px is on the order of a gigabyte that is
  never released.
- `store(_:for:)` (`:33`) overwrites an entry with a rendered print at whatever
  size the renderer produced, which then answers a 320 px request.

---

## 6. The ghost white dot (user report #3.3)

The dot is the `.processed` state badge: `Circle().fill(Theme.text)`, bottom-
trailing. It exists in **four** places:

| file:line | cell | suppressed when |
|---|---|---|
| `Panels/Filmstrip.swift:136` | filmstrip | `framing.suppressesBadge` — i.e. **only the open frame** |
| `Windows/BrowseView.swift:166` | Browse grid | **never** |
| `Export/ExportPage.swift:1391` | export grid cell | `chosen` |
| `Export/ExportPage.swift:1483` | export strip cell | `chosen` |

`FrameFraming.suppressesBadge` (`Model/FrameFraming.swift:50`) is
`self == .open`, with a comment deliberately defending keeping the badge on
*picked* cells.

So the earlier instruction ("No bottom right white dot for selected image at the
bottom opened-image tab") was implemented as **"hide it on the open frame"**,
and then the same badge was written three more times elsewhere. That is exactly
why it reads as 阴魂不散: it is not one dot that comes back, it is four dots,
three of which were never in scope of the original fix.

The user's instruction now is total: *every* path that can draw it must go. The
`.stale` hollow ring is the same construct at the same anchor and should be
treated as part of the same decision (the PRD proposes removing both and letting
the white frame carry selection, since that is what the user asked for the first
time).

---

## 7. The Browse "import page" (user report #2, second half)

There is no separate import window. What the user is calling 导入页面 is the
**Browse grid**: `EditorWindow.swift:34` swaps the whole editor for
`BrowseView` whenever `session.browsing` is true, and `Session.open(urls:)`
(`Session.swift:989-994`) sets `browsing = true` for any multi-file or folder
open.

Its stated purpose (`BrowseView.swift:3-8`) was to stop the app committing to a
7 s render of the alphabetically-first frame on folder open. That protection is
still wanted — but it is a *behaviour* ("render nothing until a frame is
chosen"), not a *screen*, and the filmstrip already shows the folder.

Note this is also a freeze surface: the Browse grid is a `LazyVGrid` of
`BrowseCell`s, each requesting a 512 px thumbnail through the cache described in
§5.

---

## 8. The export viewer's navigation (user report #3.1)

The editor's top bar has the two tools from the user's screenshot:
`cursorarrow` → `.select` and `hand.point.up.left` → `.hand`
(`Windows/TopBar.swift:41-42`), plus zoom in/out, a zoom pill and Fit.

The export page has **none of it**. `viewerPane` (`ExportPage.swift:939-978`) is
a bare SwiftUI `ScrollView([.horizontal, .vertical])` — the only way to move the
picture is a trackpad/scroll-wheel drag, which is the user's complaint.

There is also a semantic mismatch: the export page's `zoom` is a multiplier on
the **fitted** size (`ExportPage.swift:1002-1013`), so its pill reads "100 %"
when the image is fitted to the pane. In the editor "100 %" means 1:1 pixels.
Two pages, same label, different meaning.

---

## 9. What this diagnosis does *not* cover

- RFC-017 batch processing stays unimplemented, per standing instruction.
- The `modern_UI/reference_layout/Export_Page/export_page.ai` working-tree
  modification was not touched or inspected.
- No profiling instrument (Instruments/`leaks`) was run — findings A–D are from
  code reading plus the log's memory and timing records. The worker session
  should confirm A with a Time Profiler trace showing blocked cooperative-pool
  threads before committing to the executor design.
