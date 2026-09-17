# IMPL — Export page v2: the picked set, the straight route, the viewer, the badge

**Companion to** `PRD/PRD-export-page-v2.md` (the requirements) and
`PRD/BUG-DIAGNOSIS-2026-09-14-export-and-decode.md` §2, §3, §4, §6, §8.
**Depends on** `PRD/IMPL-decode-pipeline.md` step 1 — the export run is the
decode path N times over, and none of this is testable while the app stalls.

**This document is implementation logic, not a patch.**

---

## 1. Rules for whoever implements this

1. **The proof must stay the file.** RFC-018 §7.6's claim — the picture on the
   page is rendered by the *same code* that writes the file — is the reason
   `Exporter.filePixels` exists as one function that both callers use
   (`Exporter.swift:311-320`). Every change below preserves that. If you find
   yourself writing a second chain "just for the preview", stop.
2. **`reference_layout/Export_Page/notes.md` is the authority on behaviour** and
   `export_page.svg` on layout. Where the code disagrees with either, the code
   is wrong; where this document disagrees with either, this document is the
   user's newer instruction and wins — but say so in the commit.
3. **Do not regress "the viewed image stays as the one the user is previously
   on".** The user called this out as the one thing that is currently right.
   It is `notes.md`'s rule and `ExportPage.batch`'s reason for existing.
4. **Do not implement RFC-017.** The export run walking a set of frames is not
   apply-to-all.
5. One commit per section. Each with its verification run and recorded.

---

## 2. R1 — the worklist is the picked set

### 2.1 What is actually wrong

The selection *model* is correct and does not change. `ExportPage.batch` is
`session.selectedFrames` (`ExportPage.swift:217`) → `frames.filter(picked.contains)`
(`Session.swift:61`) → `picked` moved only by `Session.click` (`:1084-1090`).

The *presentation* is what carries the whole folder:

| site | code | effect |
|------|------|--------|
| `ExportPage.swift:1118` | `stripPanel`: `ForEach(session.frames)` | every frame in the folder is a cell |
| `ExportPage.swift:1089` | `gridCard`: `ForEach(session.frames)` | same |
| `ExportPage.swift:447` | `countPill`: `session.frames.count` | "27 images" when 3 are picked |

Each of those cells also fires a 1024 px thumbnail request
(`ExportPage.swift:1376`, `:1470`) into an unbounded cache — so the wrong
worklist is also a memory cost.

### 2.2 The change

- `stripPanel` and `gridCard` iterate a new `private var worklist: [Frame]` =
  `session.frames.filter { session.isPicked($0.id) }`. Order stays the strip's,
  which is what makes a run reproducible.
- `countPill` shows `batch.count`. Its tooltip may still say "3 of 27 in this
  folder".
- `summaryLines` (`ExportPage.swift:1189`) keeps "Images  3 of 27" — the summary
  is where the session context belongs.

### 2.3 The gesture problem, and the new `Session.open(_:)`

A plain click inside the export page currently goes through
`ExportPage.tap(_:)` (`:198`) → `Session.click(_:command:)`, whose documented
rule is "a plain click picks exactly this frame, collapsing whatever set there
was". With a picked-only worklist that means **clicking a cell makes every other
cell vanish under the pointer.**

`Session.click`'s rule is right for the filmstrip and must not change there. Add
a third gesture instead:

```swift
/// Put a frame on the canvas without touching the picked set.
///
/// Not `click`: a plain click collapses the set, which is right in the
/// filmstrip (the set is invisible there) and wrong on the export page,
/// where the set *is* the page's content. Not `select` either: `select` is
/// the internal load, and the export run calls it deliberately for that
/// reason. This is the person's gesture on a page whose list is the batch.
func open(_ url: URL) { guard picked.contains(url) else { return }; select(url) }
```

Note the name collides with `open(urls:)`; pick `reveal(_:)` or `show(_:)` if
the overload reads badly. `ExportPage.tap` becomes: ⌘ → `togglePick`, plain →
the new gesture.

The guard matters: the export page can only put a *picked* frame on the canvas,
because the proof is of a frame in the batch.

### 2.4 The empty state

`adoptSessionSelection` (`ExportPage.swift:176`) exists so a page opened onto an
empty set is not blank. Delete it. In its place:

- Worklist empty → both panes show "Nothing is selected. ⌘-click images in the
  filmstrip to add them.", the Export button is disabled, and the proof is not
  rendered.
- In practice this is rare: `Session.click` keeps the open frame in the set by
  construction, so an empty set means nothing is open at all.
- The one caller that relied on the auto-pick is the snapshot harness
  (`SpektrafilmApp.swift:357-360`), which already calls `session.click(first.id)`
  explicitly and with a comment saying why. It keeps working; do not remove it.

### 2.5 Tests

- The export strip renders exactly `selectedFrames.count` cells.
- A plain click on an export cell moves `selection` and leaves `picked`
  unchanged. (Break it on purpose and watch the test go red.)
- ⌘-click on the open frame is still a no-op (`Session.togglePick`, existing
  rule, existing test).
- Extend `ExportPanelTests` / `SelectionModelTests`; do not write a third
  selection test file.

---

## 3. R3.2 — the straight route

### 3.1 What is wrong today, precisely

`ExportPage.run()` (`:1273-1281`) does, per frame:

```swift
if session.selection != url { session.select(url) }
guard let sid = await session.ensureDeveloped() else { … }
let out = try await Exporter.export(session:recipe:context:sessionID:)
```

`ensureDeveloped` always runs the full film develop: engine open with a 727 MB
frame buffer, solve, full-tier reprint.

And for a frame that was never touched, `Session.select` does
`sidecar = Sidecar.load(for: url) ?? Sidecar()` (`:1125`). `Sidecar()` is
`FilmParams.default`, which is `filmStock: "kodak_portra_400"`,
`printStock: "kodak_supra_endura"` (`Params.swift:105-106`).

So an untouched frame **does not fail** — it exports with Portra 400 on Supra
Endura, silently. The user's guess ("导出渲染的时候默认就是所有图片都有对应的
sidecar 还有 film edit profile") is right about the cause and the consequence is
worse than a failure: it is wrong output at maximum cost.

### 3.2 The model change

A frame needs to be able to say "no film profile", the way it can already say
"no print profile" — `FilmParams.scanFilm` (`Params.swift:147`) exists for
exactly that and is the precedent to follow.

**Proposal:** `Sidecar.filmProfileChosen: Bool`, persisted, schema 3 → 4.

- New sidecar (no file on disk): `false`.
- Set `true` the first time the user picks a film stock in
  `Panels/Sections/FilmSection.swift` (was `FilmProfileSection.swift`), or
  presses Process (was Solve), or otherwise asks for a develop.
- **Migration:** a sidecar decoding at `schemaVersion <= 3` sets it **`true`**.
  Every frame with a sidecar on disk today was developed with a film profile;
  defaulting those to `false` would change what re-exporting an existing edit
  produces, which is the one thing this change must not do. Write this rule in
  `Sidecar.init(from:)` beside the existing schema-2 crop migration
  (`Sidecar.swift:129-144`), which is the pattern.

The alternative — making `filmStock` optional — is cleaner in the abstract and
worse in practice: it is a wire field (`Params.swift:173`'s pair list), it is
read in a dozen places including `NamingRule.Context`, and every one of them
would need a nil branch. Do not take it without asking.

### 3.3 The two routes

| frame | route | chain |
|-------|-------|-------|
| `filmProfileChosen == true` | **develop** (today's) | engine full-tier render → Layer 2 → geometry → size → output transform |
| `filmProfileChosen == false` | **straight** (new) | display decode at full size → Layer 2 → geometry → size → output transform |

The straight route is **supported and not advertised**: no toggle, no mode
picker, no marketing copy. It is what happens when there is nothing to develop.

### 3.4 Where the branch goes

**In `Exporter.filePixels`, and nowhere else.** `Exporter.swift:335-338`:

```swift
static func filePixels(session:recipe:sessionID:) async throws -> Rendered {
    let (target, _, _, _) = resolveTarget(recipe)
    let outcome = try await session.client.render(.export, RenderRequest(sessionID: sessionID, tier: "full"))
    guard let full = outcome.texture else { throw ExportError.noPixels }
    …
```

Only the **source** changes:

```swift
let source: MTLTexture = session.sidecar.filmProfileChosen
    ? try await engineFullTier(session, sessionID)
    : try straightSource(session)          // display decode → full-size rgba16 texture
```

Everything after — `applyLayer2`, `applyGeometry`, `applyResize`,
`applyOutputTransform`, `makeCGImage` — is **untouched, shared, literally the
same lines**. That identity is RFC-018 §7.6 and is what makes the page's central
claim true. It must survive this change, and a test should assert both routes go
through one function.

`straightSource` renders `DecodedImage.display` into a working-space rgba16
texture at the frame's own size — which is exactly what
`ImageDecoder.makePreviewTexture(_:device:maxEdge:)` already does
(`ImageDecoder.swift:288`) with `maxEdge` set to the frame's long edge. Reuse
it. Do not write a second Core Image render.

### 3.5 `sessionID` becomes optional

`filePixels`, `exportPrint` (`:384`) and `Exporter.export` (`:111`) all take
`sessionID: String`. On the straight route there is no engine session. Make it
`String?` and let the develop route be the one that requires it. Then
`ExportPage.run()`:

```swift
if session.selection != url { session.select(url) }
let sid: String?
if session.sidecar.filmProfileChosen {
    guard let s = await session.ensureDeveloped() else { problems.append(…); continue }
    sid = s
} else {
    await session.ensureDecoded()      // the pipeline's settle, no engine
    sid = nil
}
```

`Session.ensureDecoded()` is new and is the pipeline's `settled(for:)` from
`IMPL-decode-pipeline.md` §3.5 — it must **not** open an engine session.

### 3.6 The soft proof takes the same branch

`Session.softProof` (`SoftProof.swift:94-100`) currently opens the engine before
anything else:

```swift
if serviceSessionIDForExport == nil { _ = await ensureDeveloped() }
guard let sessionID = serviceSessionIDForExport else { return nil }
```

Guard that on `filmProfileChosen`. On the straight route the proof renders with
no engine session at all — which also means the export page stops being a reason
to develop a frame the user never asked to develop.

### 3.7 The page says which route

One line in the summary card (`ExportPage.summaryLines`, `:1189`):

- develop route: nothing new (the film and paper are already named elsewhere).
- straight route: `"Source  decode (no film profile)"`.

No warning colour, no badge. It is a statement of fact, not a problem.

### 3.8 The batch run's memory

After each frame in `run()`'s loop: drop the full-render slot
(`renderer.dropFullRender()`), release the decode unless the residency wants it,
and `sampleMemory("export_frame_\(i)")`. A 20-frame export must have a **flat**
memory profile. Today it is the §1 freeze at N× the size — every entry pays
select → decode (~4 GB) → engine open (727 MB) → solve → full render (363 MB),
serially, on a session already pinned at 10 GB.

### 3.9 Tests

- Exporting a frame with no sidecar opens **no** engine session (assert on the
  log's absence of an `engine open` record, or on a client call counter).
- Both routes go through one `filePixels` tail — assert structurally, e.g. the
  develop route and the straight route produce byte-identical output for a
  frame whose film profile is a no-op, or at minimum that neither has its own
  copy of the transform.
- A sidecar written by the current build (schema 3) decodes with
  `filmProfileChosen == true` and re-exports byte-identically to before the
  change. **This is the migration test and it is the one that protects the
  user's existing edits.**

---

## 4. R3.1 — the viewer pane

### 4.1 Downsample the proof first — this is a prerequisite

`ExportPage` holds the proof as a **45 MP `CGImage`** (`@State var proof`,
`@State var filePreview`; `Renderer.makeCGImage` copies into a 363 MB `Data`,
`Renderer.swift:899-911`). Then `viewerPane` (`:955-963`) does:

```swift
Image(decorative: shown, scale: 1).resizable().interpolation(.high)
    .frame(width: fitted.width * zoom, height: fitted.height * zoom)
```

SwiftUI resamples 45 MP down to a ~1200 pt pane with high-quality interpolation
**on the main thread, every draw** — every scroll, every zoom step, every
resize. Adding pan tools to this without fixing it makes the page worse, not
better.

The fix keeps the claim intact:

- `SoftProof` keeps its statistics (`compressedFraction`, `clippedFraction`,
  `movedFraction`) from the **full-size** render. Those are measurements of the
  file and must not be sampled from a downscale.
- `SoftProof` gains a `displayImage: CGImage` — the same pixels downsampled once
  to roughly 2× the pane's longest side, produced on the GPU in the same pass
  chain (`Renderer.applyResize` already exists and is the same resampler).
- The pane shows `displayImage`. The full-size `CGImage` is **not retained** by
  the page at all — `filePixels` returns it to `exportPrint`, which writes it;
  the proof path keeps only the downscale and the numbers.
- `captionHelp` still reports the file's real pixel size, from the statistics,
  not from the image it is showing.

Note the existing comment at `ExportPage.swift:264-272` — "the proof is asked
for at the file's own size", the user insisting on it, and two previously
removed clamps. **That requirement is not being reversed.** The render is still
full size; only what the page *holds and draws* shrinks. Say so in the comment
you replace, or someone will re-add the clamps.

### 4.2 The tools

The editor's two, same glyphs, same shortcuts
(`Windows/TopBar.swift:41-42`): `cursorarrow` → select, `hand.point.up.left` →
pan, V and H. Plus zoom in / zoom out / Fit at the editor's placement.

- The export page's `zoom` is page-local `@State` (`:57`). Keep it local — the
  export viewer's zoom is not the canvas's and must not move it.
- The tool state may be local too; if the user expects V/H to mean the same
  thing everywhere, reuse `session.tool` but **do not** let the export page
  write `.crop` into it.
- Hand drags the picture inside the existing `ScrollView` by moving its content
  offset. Scroll-wheel panning keeps working; it stops being the only way.

### 4.3 Fix the zoom semantics

`ExportPage.fitted` (`:1002-1013`) fits the image into the pane, then `zoom`
multiplies **that**. So the pill reads "100 %" when the picture is fitted, and
"Fit" in its menu sets `zoom = 1` (`:428`). In the editor, 100 % means 1:1 with
the file's pixels (`TopBar.zoomPill`, `Session.zoomPercent`).

Two pages, one label, two meanings. Make the export page match the editor:
100 % is 1:1 with the *file's* pixels, Fit is its own state shown as
"Fit · N %". `Session.zoomPercent`/`isFit` are the model to copy, not to share —
the export pane is not the canvas.

---

## 5. R3.3 — the white dot, everywhere

### 5.1 Why it keeps coming back

The earlier instruction was "No bottom right white dot for selected image at the
bottom opened-image tab". It was implemented as *hide it on the open frame* —
`FrameFraming.suppressesBadge = (self == .open)`
(`Model/FrameFraming.swift:50`), whose comment actively defends keeping the
badge on picked cells. Then the same badge was written three more times
elsewhere. It is not one dot that returns; it is four dots, three of which were
never in scope of the fix.

| file:line | cell | suppressed when |
|---|---|---|
| `Panels/Filmstrip.swift:136-137` | filmstrip | only the open frame |
| `Windows/BrowseView.swift:166-167` | Browse grid | never |
| `Export/ExportPage.swift:1391-1392` | export grid cell | `chosen` |
| `Export/ExportPage.swift:1483-1484` | export strip cell | `chosen` |

### 5.2 The change

Delete all four `badge` bodies and their call sites (the `.overlay(alignment:
.bottomTrailing)` / `badge.padding(…)` lines above each). Delete
`FrameFraming.suppressesBadge`, which becomes dead. The hollow `.stale` ring is
the same construct at the same anchor and goes with them.

Selection is the white frame and nothing else — which is what was asked the
first time.

`FrameState` stays: it is a real model concept, it is persisted in the sidecar
(`Sidecar.state`), and `Session.markStale` / `refreshState` use it. Only the
view affordance goes.

### 5.3 The guard

Add a test that fails if a state pip is reintroduced. The honest version is not
"grep the source" — it is a snapshot or a view-inspection assertion that a
thumbnail cell for a `.processed` frame draws nothing in its bottom-trailing
corner. **Then put the badge back on purpose and watch the test go red.** A
guard that cannot fire is this repo's repeat defect shape; an untested deletion
is how this dot survived three previous removals.

---

## 6. Verification

| # | claim | method |
|---|-------|--------|
| 1 | The export page lists only picked frames | `ExportPanelTests`; open a 27-frame folder, ⌘-click 3, count cells |
| 2 | A plain click in the export page does not collapse the batch | test, verified by breaking it |
| 3 | An untouched frame exports with no engine session | log has no `engine open` for it |
| 4 | An untouched frame's file is the decode, not Portra 400 | compare against a Core Image render of the same NEF |
| 5 | An existing sidecar re-exports byte-identically | migration test, §3.9 |
| 6 | The page holds no 45 MP CGImage | memory record on the export page; arena breakdown once RFC-019 lands |
| 7 | The proof still is the file | `ExportPreviewChainTests`, `SoftProofParityTests` green and unmodified |
| 8 | 100 % means 1:1 on both pages | test `zoomPercent` against a known frame size |
| 9 | No state pip anywhere | §5.3, verified by breaking it |
| 10 | The fixture link exists before believing any green run | no `tests` link means 25 tests skip silently and the run still reports 0 failures |

---

## 7. Order and rollback

1. §5 badge removal — smallest, independent, ship first for morale.
2. §2 worklist + the new gesture — self-contained, revertible.
3. §4.1 proof downsampling — prerequisite for §4.2, and fixes the page's own
   hang on its own.
4. §4.2/§4.3 tools and zoom semantics.
5. §3 the straight route — largest, touches the sidecar schema, lands last and
   behind the migration test.

§3 is the only one with a data-format consequence. Its rollback is not a revert:
a schema-4 sidecar must still decode on a build that expects 3. The synthesized
`decodeIfPresent` pattern already used throughout `Sidecar.init(from:)` gives
that for free — keep it, and do not remove any `CodingKeys` case.
