# PRD — Export page v2, the decode cache, and the removal of Browse

**Date:** 2026-09-14 · **Author:** session notes from the user's bug report
**Companion:** `PRD/BUG-DIAGNOSIS-2026-09-14-export-and-decode.md` — read it
first; every requirement here cites a finding there.

**Implementation logic lives elsewhere, and the worker session must read it
before writing code:**
- `PRD/IMPL-export-page-v2.md` — §2, §4, §5, §6 of this document, in detail
- `PRD/IMPL-decode-pipeline.md` — §3 of this document, in detail
- `rfc/RFC-019-memory-management.md` + `PRD/IMPL-RFC-019-memory.md` — the
  ownership and cap work that §3.3's cache is one part of

**Standing constraints**
- RFC-017 (batch processing / apply-to-all) stays **unimplemented**. The export
  run already walks a set of frames; that is not RFC-017 and must not grow into it.
- `AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` and `CONTRACT-*` belong to nobody
  in particular — say so before editing one.
- The engine keeps the spektrafilm name; the Xcode target stays `Spektrafilm`.

---

## 1. What is being fixed, in the user's order

| Req | User's words | Finding |
|-----|--------------|---------|
| R1 | Only ⌘-clicked images enter the export page | §2 |
| R2 | Fix the RAW decode stall; cache decodes; delete the import page | §1, §7 |
| R3.1 | The export viewer needs the pointer/hand tools the main app has | §8 |
| R3.2 | An unmodified image must export as decode + adjustments, no film develop | §3 |
| R3.3 | The bottom-right white dot must be gone from every path | §6 |

Ordering for the worker: **R2 first** (nothing else is testable while the app
stalls), then R1 and R3.2 (they share the export run), then R3.1 and R3.3.

---

## 2. R1 — the export page is the picked set

### 2.1 Behaviour

- The export page's **Viewer strip** and **Grid** show **only** `session.selectedFrames`.
  A frame that is not picked does not appear on the export page at all.
- The count pill shows the batch size — "3 images", not "27 images". Its tooltip
  may still name the session ("3 of 27 in this folder").
- The viewer stays on the frame the user was previously on. **This already works
  and the user singled it out for praise — do not regress it.** Concretely:
  `session.selection` must not move when the batch changes, and `run()` must
  restore `home` afterwards.
- Clicking a cell **inside** the export page moves the canvas to that frame
  (plain click) or toggles membership (⌘-click), as today — but a plain click
  inside the export page must **not** collapse the batch to one frame. This is
  the one place `Session.click`'s "plain click resets the set" rule is wrong,
  because the set *is* the page's content: collapsing it would make the other
  cells vanish under the pointer.
  → Give `Session` an explicit third gesture (e.g. `open(_:)`, which moves
  `selection` and leaves `picked` alone) rather than adding a boolean to `click`.
- Removing the last picked frame is allowed. The page then shows an **empty
  state**: "Nothing is selected. ⌘-click images in the filmstrip to add them."
  Export is disabled.

### 2.2 What must not happen

- `adoptSessionSelection` (`ExportPage.swift:176`) must not silently pick the
  canvas frame to avoid an empty page. Opening the export page with nothing
  picked shows the empty state. (If the user opens the export page with a frame
  on the canvas, that frame is picked by construction — `Session.click` keeps it
  so — so the empty case only arises when nothing is open at all.)
- The picked set must stay owned by `Session`. The filmstrip, the export strip
  and the export grid read one property. Do not reintroduce a page-local `Set<URL>`.

### 2.3 Tests

- The export strip renders exactly `selectedFrames.count` cells (extend
  `SelectionModelTests` / `ExportPanelTests`).
- A plain click on an export cell changes `selection` and leaves `picked` unchanged.
- ⌘-click on the open frame is still a no-op (existing rule, `Session.togglePick`).

---

## 3. R2 — the decode pipeline

This is the substance of the release. Four pieces.

### 3.1 One bounded, genuinely cancellable decode pipeline

**The rule:** at most **one** frame decode and **one** frame-sized render are in
flight at any moment, and superseding a frame *stops the work*, not just the wait.

- Replace the scattered `Task.detached` calls (`Session.swift:1243, 1289, 1303, 1710`)
  with a single session-owned executor: an `actor` holding a depth-1 replaceable
  slot, or an `OperationQueue` with `maxConcurrentOperationCount = 1`. Submitting
  a new frame cancels whatever is queued and asks the running job to stop.
- `ImageDecoder.decode` and `ImageDecoder.makePreviewTexture` take a cancellation
  check between stages, and `makePreviewTexture` must not block a cooperative
  thread on `cb.waitUntilCompleted()` — use `addCompletedHandler` bridged to a
  continuation, or run it off the cooperative pool entirely.
- **Acceptance:** clicking through 30 frames as fast as possible leaves at most
  one decode running; footprint returns to within 500 MB of the single-frame
  baseline within 5 s of the last click; every settled frame produces an `open`
  record in the log. Today: 25 clicks, zero `open` records, 10.5 GB pinned.

### 3.2 Prefetch, rewritten or removed

`prefetchNeighbours` (`Session.swift:1701`) as written is net-negative — see §1.3.
Either:
- delete it, and re-measure the frame-switch cost with the new cache in place; or
- rebuild it on the same executor at strictly lower priority, with entries
  removed on completion, cancelled on frame change and on `open(urls:)`, and the
  `prefetch[f.id] == nil` guard replaced by a check against the cache so an
  evicted neighbour can be refetched.

Default to **delete**, and only bring it back if the measurement says it helps.

### 3.3 The decode cache (the user's "小数据库 + 对象存储")

The access pattern to serve is **A/B comparison**: the user goes back and forth
between a handful of frames and expects the previous one to be instant.

**Superseded in detail by `rfc/RFC-019-memory-management.md` §7-§8 and
`PRD/IMPL-RFC-019-memory.md` §6-§7** — that is where the schema, the key
derivation and the eviction policy live. The user's later instruction also
changes the emphasis: *"好像不需要高速缓存，反正都在 ssd 里"* — the in-memory
tier is deliberately small (2 frames), and the SSD is the cache. Summary:

**Object store** — on disk, under `~/Library/Caches/com.hanze.filmify/decode/`:
- One entry per (file identity, decode settings) pair, holding the **display**
  decode rendered to a bounded long edge (the current `previewLongEdge`, 2678 on
  this machine) as a compact GPU-loadable blob. This is the picture the canvas
  shows before a develop and the left half of the before/after split.
- Key = content-addressed: SHA-256 of (file inode + size + mtime + a hash of the
  `DecodeSettings`). Changing white balance is a different entry, not an
  invalidation.
- Size-capped (default 4 GB, user-adjustable in Settings alongside the existing
  memory reserve), LRU-evicted, purged on version bump.

**Index** — a small SQLite database beside it (`index.sqlite`), one row per
entry: key, source path, pixel size, decode settings blob, bytes, created,
last-used. SQLite rather than a plist: it survives a crash mid-write, and it is
the thing that makes eviction and "how big is this cache" cheap to answer.

**In-memory tier** — keep `TextureStore`'s existing LRU-8 of GPU textures in
front of it; the disk cache is what turns a *miss* from 4 GB and 500 ms into a
file read.

Explicitly **not** cached: the linear/engine decode and the 727 MB engine frame.
Those are transient by design (`ImageDecoder.EngineFrame`'s own doc comment) and
caching them is the memory regression that comment exists to prevent.

**Acceptance:** returning to a frame visited earlier in the session shows its
picture with no `CIRAWFilter` construction (assert via a decode counter in the
log) and no memory spike above 500 MB.

### 3.4 Cheaper decode, and a budget

- Drop the third `CIRAWFilter` in `decodeRAW` (`ImageDecoder.swift:177`): the
  `probe` exists for two `Float` reads that either real filter can supply before
  the white balance is overridden.
- `scheduleNativeOriginal` (`Session.swift:1219`) renders a 363 MB texture per
  frame switch. Make it cancellable (§3.1), budget it against
  `MemorySampler`'s free-bytes reading, and defer it until the user asks for a
  comparison (`session.comparing`) or the canvas is zoomed past the preview tier.
- `ThumbnailCache`: key on `(url, maxPixel)`, cap it (count and bytes), evict
  LRU, and clear it in `Session.open(urls:)`. See §5 of the diagnosis.

### 3.5 Delete the Browse page

- Remove `BrowseView` and the `session.browsing` branch in `EditorWindow.swift:34`.
  Opening a folder lands in the editor with the filmstrip populated.
- **Keep the behaviour Browse was protecting:** nothing is decoded or developed
  until the user picks a frame. `Session.open(urls:)` keeps its "render nothing
  on a multi-file open" rule; the editor simply shows an empty canvas with
  "Pick a frame from the strip" instead of a grid.
- The Grid mode *inside the export page* stays — that one is in the reference
  drawing and the user has not asked for its removal.
- Anything Browse owned that is worth keeping (the Name / Capture-date sort)
  moves to the filmstrip or is dropped; do not preserve it by keeping the page.

---

## 4. R3.2 — exporting a frame that was never edited

### 4.1 Two routes, chosen by the frame, not by the user

| frame | route | what the file contains |
|-------|-------|------------------------|
| has a sidecar with a film profile | **develop route** (today's) | engine film + print, Layer 2, geometry, output transform |
| no sidecar, or a sidecar with no film profile | **straight route** (new) | Core Image display decode + Layer 2 adjustments + geometry + output transform. The engine's film side is never entered. |

The straight route is **supported and not advertised**: no toggle, no marketing
copy, no mode picker. It is what happens when there is nothing to develop.

### 4.2 Why this is a correctness fix, not just a speed one

Today a frame with no sidecar gets `Sidecar()` defaults (`Session.swift:1125`),
so it is exported **with a default film stock and print stock applied** — output
the user never asked for, at maximum cost. Failing would be better; doing the
right thing is better still.

### 4.3 Requirements

- `Sidecar` gains an explicit, persisted answer to "does this frame have a film
  profile?" — not inferred from equality against defaults.
- `Exporter.filePixels` grows a second source: instead of
  `client.render(.export, tier: "full")`, take the display decode at full size
  through the same **grade → frame → size → convert** chain. The chain after the
  source must be *literally the same code* — that identity is what RFC-018 §7.6
  rests on and it must survive this change.
- The export page's summary names the route in one word when it is the straight
  one (e.g. "Source  decode (no film profile)"), so a person reading the summary
  is never surprised by the file.
- The soft proof uses the same branch, so the proof still is the file.
- Cost: the straight route must not open an engine session at all.

### 4.4 The batch run's cost

`ExportPage.run()` must not leave every exported frame's state resident. After
each frame: drop the full render slot, release the decode unless the cache wants
it, and sample memory with a `reason` naming the frame index. A 20-frame export
must have a flat memory profile, not a rising one.

**Acceptance:** exporting 10 untouched 45 MP NEFs completes without the app
becoming unresponsive, and the log shows no `engine open` records for them.

---

## 5. R3.1 — the export viewer's navigation

- Add the editor's two tools to the export page's top bar, same glyphs, same
  semantics: `cursorarrow` (`.select`) and `hand.point.up.left` (`.hand`), matching
  `Windows/TopBar.swift:41-42`. Same keyboard shortcuts (V / H).
- Hand tool drags the picture. Select tool is the default and does not pan.
- Zoom in / zoom out buttons and a Fit control, matching the editor's placement.
- **Fix the zoom semantics.** The export page's `zoom` currently multiplies the
  *fitted* size, so its pill reads "100 %" when the image is fitted
  (`ExportPage.swift:1002`). Make it mean what it means in the editor: 100 % is
  1:1 with the file's pixels, and Fit is its own state labelled "Fit · N %".
  Two pages must not use one label for two things.
- Scroll-wheel panning keeps working; it stops being the *only* way.
- The proof shown in the pane must be a **downsampled** copy, not the 45 MP
  CGImage (diagnosis §4). Keep the full-size render for the statistics and the
  written file; give the pane something the size of the pane. This is a
  prerequisite for the tools feeling responsive at all.

---

## 6. R3.3 — the white dot, everywhere

**Requirement: no state pip is drawn on any thumbnail, in any surface.** Selection
is the white frame and nothing else — which is what was asked the first time.

Delete all four:
- `Panels/Filmstrip.swift:136-137`
- `Windows/BrowseView.swift:166-167` (goes with the page, §3.5)
- `Export/ExportPage.swift:1391-1392`
- `Export/ExportPage.swift:1483-1484`

and the machinery that fed them: `FrameFraming.suppressesBadge`
(`Model/FrameFraming.swift:50`) becomes dead and should go with them.

The hollow `.stale` ring is the same construct at the same anchor and is removed
too. If "which of these has a print behind it" turns out to be information worth
keeping, it comes back as something that is **not** a dot in the bottom-right
corner of a thumbnail, and only after the user asks for it.

**Guard against the fourth recurrence:** `FrameState` is still a real model
concept. Add a test that asserts no view draws a `Circle` overlay for a
`FrameState`, or — better — remove the view-layer affordance entirely so there
is nothing to re-add by copy-paste. Note the repeat-defect shape recorded in
this repo's memory: a check that cannot fail is worse than no check. Make sure
the test fails if a badge is put back.

---

## 7. Delivery

Suggested order, each independently shippable and testable:

1. **Decode pipeline** (§3.1, §3.2, §3.4) — the executor, cancellation, the
   prefetch decision. Acceptance is the 30-click memory test.
2. **Decode cache** (§3.3) — store, index, Settings row for the cap.
3. **Browse removal** (§3.5).
4. **Export worklist** (§2) and **the straight route** (§4) — one change to how
   the export page decides what it is about.
5. **Viewer tools and proof downsampling** (§5).
6. **Badge removal** (§6) — small, do it whenever, but land the test with it.

Each step lands with a log record that makes its claim checkable: RFC-016's
`memory` and `open` records already carry the right fields, and the diagnosis
above is written against them so a before/after is a diff of two log files.
