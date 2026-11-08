# The half-frame pair: what the host hands the engine, and where the flow opens

First written 2026-10-09, with a frame's own print added 2026-10-10; rewritten 2026-11-08 to say what holds in
`app/SpektraLab` today. The model is `Sources/Model/HalfFramePair.swift`; the host's side is
`Sources/Engine/PairDevelop.swift`, `PieceComposer.swift`, `PiecePlacer.swift` and `PrintLayers.swift`; the
pages are `Sources/Features/Pair/`; on the Mac a pair is also a row of the library (`MAC-LIBRARY-DATA.md` §2i).
The pair was first built in the 1.x app (`modern_UI/Spektrafilm`, `HalfFramePair`, `PairComposer`,
`Session.pairLayered`, in this repository's history); where this says "1.x" it means that app's behaviour,
which the port holds to.

## 1. What a pair is to the engine

**One frame.** The host composes both pictures onto one piece of film and hands the engine that buffer; after
the decode the engine, the canvas, the kept develop and the export handle a pair as they handle a frame. The
engine has no notion of two files. It is told four things a frame is not:

- the piece's millimetres (`film_format_mm`, or on a film edge the gate and one advance);
- that the meter is off, because each picture's exposure is already in its pixels;
- on a film edge or with a date, that the frame carries two exposures (`overscan_pair`);
- where the second frame begins, for its own Scene Placement (`scene_latitude_split`).

## 2. The buffer

**Format.** What `FrameDecoder` makes of any file: scene-linear float32, ProPhoto RGB primaries at D50, RGBA,
16 bytes a pixel, top row first, in a shared `MTLBuffer` of the engine's own device, opened with
`spk_open_device` (`engine/include/spektralab/spk_engine.h`).

**Size and layout**, all from the model, in pixels with a top-left origin:

| what | from | value at 1.0 mm |
|---|---|---|
| the piece | `pair.pieceLayout(sizes:)`, `sizes[side]` the frame as framed: `hole.geometry.outputSize(for: decoded)` | `Layout.size` |
| a hole | `Layout.hole` | 18 × 24 mm, so `across × 18/24` by `across` |
| the first hole | `layout.rect(.left)` | at 0 along the long edge |
| the second | `layout.rect(.right)` | at `advance = round(along × (18 + spacing) / 18)` pixels |
| the piece in mm | `pair.pieceSizeMM` | 37 × 24, or 24 × 37 turned |

- Held level the long edge runs across and the first frame is on the left; turned, it runs down and the first
  frame is at the top (`engine/src/core/overscan.cpp`, "the first picture is at the start of the frame").
- The holes are as large as the smaller picture is across its hole, so neither is enlarged, and the piece is
  never longer than the longer picture: two half frames are one frame's worth of film (in 1.x a pair of 45 MP
  frames at their own size was an 83 MP piece before this cap). A hole's size does not move with the gap.
- For a job below the full tier, the same layout scaled so the piece's long edge is the job's.

**Each picture**, in this order (`PieceComposer`, `PiecePlacer`):

1. decode the frame's own file with **the hole's** decode settings (`hole.decode`: the shot stays the frame's);
2. the frame as its owner framed it: `HostCut.image(image, by: hole.geometry)`;
3. turn it `hole.placement.quarterTurns` clockwise as seen;
4. cut `HalfFramePair.sourceRect(for: placement, source: turnedSize, aspect: pair.holeAspect)` (y down), scale
   that to the hole, put it at `layout.rect(side)`;
5. multiply it by `2^stops` (§4).

**Everything else is zero.** The gap, the film round the holes and an empty hole are no light at all: unexposed
film, which the engine develops to the stock's own base. It is never painted. The engine's own check of such a
buffer is `engine/tests/overscan_checks.py` (two pictures, the second one advance along, zeros between; turned;
a bare pair; a bare pair's dates).

## 3. The wire

The pair's look is a `FrameEdit` like a frame's (`HalfFramePair.look(from:)`), sent through
`FrameEdit.engineWire` (`Engine/EngineWire.swift`). What differs:

| field | value | why |
|---|---|---|
| `auto_exposure` | `false` | each picture carries its own exposure |
| `exposure_compensation_ev` | `0` | the same |
| `film_format_mm` | `pair.filmFormatMM()` = `(36 + spacing) × frameLong / 24`: 37 at 1.0 mm, 38 at 2.0 | the engine is handed the whole piece, so its long edge is the piece's |
| the cut (`Geometry.default.wire`) | none | the piece is whole; each picture was cut by the host |
| `overscan_format` | `135_half` | whenever `overscan_pair` is sent; refused otherwise |
| `overscan_pair` | `true`, **only** with a film edge, or with a date and no film edge | "the input carries both pictures, the second one advance along" |
| `date_imprint_text_b` | the second frame's date | each frame was its own exposure; empty prints the first only |
| `scene_latitude_split` | `pair.split`: the middle of the gap along the long edge, 0.5 | where the second frame's curve takes over |
| `scene_latitude_b_active`, `_b_highlight_knee`, `_b_highlight_room`, `_b_shadow_knee`, `_b_shadow_room` | the second frame's own placement | one curve a frame (§6.3) |

- **A bare pair** (no film edge, no date) sends neither `overscan_pair` nor `overscan_format`: it is a
  37 × 24 mm frame and nothing more.
- **On a film edge the engine does not read `film_format_mm`**: the piece's long edge is the gate and one
  advance, 18 + 19 = 37 mm, and the frame's shape has to be that within 5 % or the open is refused. So on a
  strip the spacing is the camera's 1.0 mm, which `HalfFramePair.effectiveSpacingMM` holds (`onStrip`).
- `FilmEdgeSettings.wire` returns after `overscan_active` when the film edge is not effective, so
  `overscan_pair` for a dated bare pair cannot ride in it: it goes with the date's rows, as in 1.x.
- The split and the `_b_` rows are sent only while `pairSplit > 0` (`FilmParams.pairPlacementWire`), so a
  photograph's wire, and its stamp, are as they were.
- **A frame's own date switch** (`Hole.dated`): a frame switched off is handed to the engine with no text, as an
  empty hole is (`EngineRouter.wire`), so `date_imprint_text` or `date_imprint_text_b` is empty and the other prints
  alone. **One `date_imprint_style` a wire, and `date_imprint_data_text` is the first frame's alone**: a face a
  frame is not something this wire can say.

Every name above is in the engine's schema; `AppServices.checkWire` holds the app's wire against
`spk_params_schema` at launch.

## 4. Exposure

The strip develops with the meter off. Each hole is exposed as the meter would expose it alone:

1. **Meter one hole.** Open a small session on that hole's picture alone, as placed, 1,024 px at most, with the
   pair's look changed so: `auto_exposure` on, its intent the hole's own or the pair's,
   `exposure_compensation_ev` 0, film edge off, date off, `film_format_mm` 24. Ask
   `spk_solve(session, "exposure")` and read `solved_params.exposure_compensation_ev` (`SpkEngine.swift`).
2. **Keep the reading in the pair**: `hole.meteredEV`, and `hole.meteredFor =
   HalfFramePair.meterKey(hole:method:)`. The key is the frame, its decode, its own crop and the intent. **Not the
   placement**: a picture moved under its hole is not metered again, so it does not pump while it is dragged.
3. **The gain**: `pair.stops(side)` is the reading plus `hole.exposureEV`; with the hole's meter off,
   `exposureEV` alone; nil while the reading is still to come. Multiply the hole's pixels by
   `HalfFramePair.gain(stops:)` = 2^stops. 1.x measured the engine's own meter to be exactly this gain on the
   frame it is handed.
4. **+ Film** (`hole.exposureScope == .film`): the film's print brightness has already moved by the same stops
   when the control moved (`HalfFramePair.exposure(_:of:look:)`), so nothing more is done at develop time.

A frame is metered when its own switch and the look's are both on (`HalfFramePair.piece`). An exposure change of
one hole changes the buffer, not the wire: it is a new source for the session.

## 5. How a pair is kept, and identified

- **A pair is a library item**: one `LibraryFrame` whose `edit` is the pair's look and which carries the
  `HalfFramePair` (`LibraryFrame.pair`, `isPair`). The develop page, the queue, the kept develop, Favourite,
  Remove and Export reach it by its id with nothing new. It is kept when it is made (`AppServices.makePair`), and
  every edit of the piece is one call, `AppServices.changePair(id) { piece, look in … }`
  (`Services/PairKeeping.swift`); a page never writes the library's pair itself.
- **A hole names its frame by the library's own id** (`Hole.frame`) and `Hole.path` holds the original's file
  name for a reader. A pair written by 1.x has no `frame`: it is found by `path == LibraryFrame.fileName`.
- **On the Mac it is also a row of the library it was made in**: its recipe `Pairs/<name>.spektrapair` beside
  `library.json`, added by reference with the kind `pair` (spklib 0.3.1), so the grid draws the piece and
  Develop opens its page (`Mac/Library/MacPairRows.swift`, `MAC-LIBRARY-DATA.md` §2i).
- **Order**: after its left frame. **A frame may be in several pairs**, and a pair never owns a frame: removing a
  frame leaves its hole *Missing* and the export refused (`PairWords.exportRefusal`).
- **The shot stays the frame's**: every time a pair is opened or developed, each hole's `decode` and `geometry`
  are read again from its frame (`HalfFramePair.mirror`). A frame's white balance and lens are set from the
  darkroom through `AppServices.changeDecode` and, when the drag ends, `keepDecode`; the piece reads them from the
  frame.

## 6. What each job needs

### 6.1 A develop

- **The job**: a `RenderJob` of the pair's id, as `AppServices.develop` and `OpenFrameSession.submit` submit one.
- **The canvas**: the piece at the job's size; with a film edge, the film round it. The frame's own estimate is
  wrong for a piece (§10, trap 1).
- **The request**: `EngineHost.Request` carries both pictures, each with its file, decode, cut, turns, window,
  hole and gain; the composing happens in the host's decode, on the engine's queue.
- **What the pixels are made of**: `Request.sourceKey` and `DevelopStamp.of` cover both files, both decodes and
  cuts, both placements, the two gains, the spacing and `turned`, or a moved picture would show the picture from
  before.
- **The picture back**: one image of the piece (or the strip), kept under the pair's id like any frame's.

### 6.2 A Latitude reading

`spk_scene_latitude` takes the frame of a pair to measure in its **request JSON**: `"region": [x0, y0, x1, y1]`,
normalised to the frame the engine was handed, top-left origin; the value is `pair.fitRegion(side)`
(`SceneLatitudeRequest.region`). The reading asks the region of the frame the page is about — the picked one, or
with the film picked the one picked last (`OpenFrameSession.placementSide`) — and the card names it.

- **Without a region the two pictures are read as one scene.** The gap itself is not counted: a pixel of no light
  is left out of the statistic (`engine/src/core/scene_latitude.cpp`). What does get in is the row of blended
  pixels at each hole's edge, on the meter's small frame.
- The scene is read at EV 0, because `auto_exposure` is off: the gains are already in the pixels, so the card
  shows each frame as it is exposed.

### 6.3 Scene Placement

**A placement a frame**, as in 1.x. The look keeps two (`FilmParams.sceneLatitude`, the one the page shows, and
`sceneLatitudeOther`) with `placementIsRight` saying which frame the shown one is of, and `pairSplit` from the
piece (`HalfFramePair.hold`). Picking a frame trades the two and moves nothing on the wire
(`HalfFramePair.show`, `OpenFrameSession.pick`). The Fit runs on the picked frame's region (§6.2) and commits to
that frame's curve: the first frame's is `scene_latitude_*`, the second's `scene_latitude_b_*` from
`scene_latitude_split`. A swap takes each placement with its frame; a hole filled anew starts with none
(`HalfFramePair.swap`, `fill`).

What must never happen: a curve fitted on one frame's scene and applied to both. The other frame is then placed by
a scene that is not its own, and a card that names one frame is true of half the picture.

### 6.4 An export

- **One file, the whole piece**, under the pair's own name.
- **Refused with an empty hole or a missing frame**: `PairWords.exportRefusal(_:exists:)` has the two sentences.
- **Size**: the piece at its own size (§2), which is at most one frame's worth of pixels.
- **The file's metadata** is the first filled hole's frame's (1.x took the left's EXIF, else the right's).

## 7. RAM

A pair is **two decodes and one piece**. The scheduler prices a job from `RenderJob.canvas` and
`RenderJob.original` (`Scheduler/CostModel.swift`); `original` is the one place the scheduler is told what the
job decodes.

- Decoded one after the other, each rendered straight into its hole of the piece's buffer and released before the
  next, the peak is one decode and the piece; composited by one Core Image render, both decodes may be held at
  once. Until the host's own peak is measured, price by the sum of the two files' pixels.
- The piece itself is the frame the engine is handed, so it is in `canvas` already (16 B a pixel: 60 MB at
  2,400 px long, about 670 MB for a piece from two 48 MP frames).
- **The meter** (§4) is a third, small open (1,024 px). It has no job kind of its own; inside the pair's develop
  job, before the piece is opened, it is covered by that job's price.
- 1.x kept each hole's rendered bitmap between edits (`PairComposer.rendered`). This app does not: RAM first.

## 8. The ways in

- **The library's grid** (`MacLibraryGrid`, `MacLibraryPage.makePair`): a picture's menu, **组成半格组 Make
  Half-Frame Pair**, with one or two photographs chosen (a pair is never a hole of another). The frames are made
  as Develop makes them, then `AppServices.makePair`. Two: the pair lands as a row of this library, chosen, the
  library still in front. One: *Pair With* (`PairWay.ask`, `PairWithSheet` over `PairFramePicker`) asks for the
  second, then opens the pair's darkroom. **The frame the sheet was asked for is the pair's first hole, and stays
  in the pair** (`AppServices.makePair(…, beginsWithFirst:)`, `HalfFramePair.origin`).
- **The Film Edge flow, on Half**: the Format line becomes the way into a pair (`PairFormatLink`).
- **One place says what each way does to the router: `PairWay`** (`Features/Pair/PairParts.swift`). Two things a
  presentation must not do, both found by the tour on 2026-10-10: *ask for a sheet in the turn a cover is told to
  go* (the sheet is then wanted by two hosts; from the Film Edge flow it is asked for once the flow has left the
  screen, `PairWay.leaveFilmEdge`), and *set one pushed page in another's place* (the stack keeps the page that
  was there and hands it the new id; `PairWay.make` sends the frame's page away first, without its animation).
- **The pair's darkroom is the develop page** on the pair: one layer picked (`OpenFrameSession.layer`, `pick`), by
  the switch or by a click on the piece, wearing the white frame. Film & Paper, the enlarger and Effects are the
  develop page's own panels read for the layer; the frame's panels are the pair's own
  (`Features/Develop/PairPanels.swift`). **The page a picture is placed on** is a cover over the darkroom
  (`PairPlaceFlow`, `CoverRoute.pairPlace`), as Crop is for a photograph.
- A debug build opens the darkroom on a layer and a tab and makes an edit through `changePair` from launch
  arguments (`Features/Pair/PairDebug.swift`).

## 9. What the model is held to

`tools/pair_selftest.swift` (run by `tools/selftest.sh`; `--self-test` breaks each rule once) holds three things
the model could get wrong quietly, with no engine and no page needed to show it:

- **the piece** — two 18 × 24 holes and the gap on 37 mm of film, a picture under its hole as a rectangle cut from
  it, a drag, a zoom, a crop entered as a placement, the piece's size, where the second frame begins, the film's
  size the engine is told — each check against the numbers of 1.x's own tests (`HalfFramePairTests.swift`, 1.3.1),
  which it names;
- **the file** — a pair this app writes reads back the same; one 1.x wrote opens, keeps every key 1.x reads again
  from the file and writes them back; a file from before a field existed opens;
- **the film** — a pair made of a slide film is scanned and never printed, whatever its first frame's edit said.

And what each frame has for itself: its own print (§12), its own date switch, its own Scene Placement.

## 10. Traps

1. **The film edge's arithmetic is for one gate.** `FilmEdgeFormat.runsDown(frame:)` and
   `FilmEdgeSettings.canvasEstimate(picture:)` take the frame's long edge to be the gate's 24 mm. A piece's long
   edge is 37 mm: `runsDown` says a level piece runs down, and the estimate's millimetres a pixel are
   24/37 of the truth. For a pair the film runs down exactly when the pair is `turned`, and a pixel is
   `pieceLongMM / long edge`.
2. **No half turn.** `FilmEdgeSettings.hostTurns(cut:)` turns one frame's film half round by handing the picture
   over turned. A piece turned half round has its second picture first. A pair's film edge has the engine's own
   two directions only: across when level, down when turned.
3. **The pages draw a film edge before it develops from `FilmLayout`**, which has no pair. Where a strip's gates
   are is the engine's to say, after a render (§12.4).
4. **A region is of the frame handed over**, not of the canvas: on a strip `pair.fitRegion` still holds, and would
   not if the host ever turned the piece.
5. **`overscan_pair` on any format but `135_half` fails the open**, and so does a piece whose shape is not 37 : 24
   within 5 %.
6. **A slide film is scanned, never printed.** The pair's look is loaded through the catalogue
   (`HalfFramePair.look`, `load(film:into:)`); the self-test holds every slide of the bundle's catalogue to it.
7. **The edge print's words** (`overscan_edge_text`) and the pair's film's name come from the catalogue
   (`Stock.edgeText`, `StockCatalog.pairText`), never from a profile id.

## 11. Not verified

- Drag, trackpad pinch and the clicks on the piece were not driven by hand: the arithmetic under them is checked
  (`tools/pair_selftest.swift`), the gestures themselves are not.
- §12.7 has the list for a frame's own print.

## 12. A frame's own print, and where a strip's frames are (2026-10-10)

**The picture of a pair is printed once for the film, and once more for each frame whose print is its own, and the
prints are cut together along the holes.** A change of the print alone leaves the developed negative as it is, so
each further print is `spk_set_params` with that frame's rows and `spk_reprint` of the same negative, and the
film's rows are put back afterwards. It is the engine's own print of the same negative, never a gain the host
paints on (1.x: `Session.pairLayered`, `EngineClient.renderLayers`, `Renderer.compositePair`).

### 12.1 What is asked

`HalfFramePair.printLayers(look:catalog:)` (`Engine/PrintLayers.swift`) answers with one `PrintLayer` a frame, the
first frame's first:

- **which frames**: a hole with a print of its own (`Hole.print`) that is not the film's (`PrintTrim(look)`) **and
  comes out another print on the wire**. `isLayered` says a frame's print is its own; `printLayers` says what the
  engine is asked for it.
- **the rows**: the enlarger's four in wire names, `print_exposure`, `y_filter_shift`, `m_filter_shift`,
  `preflash_exposure`, made by `PrintTrim.applied(to: look)` and `FilmParams.wire`, so the clamps and the gates
  are the model's (brightness as `2^-stops`; no pre-flash while Print Effects is off). All four are the engine's
  live rows (`FilmParams.liveMutable`): set on an open session they rebuild nothing and leave its negative.
- **where**: `pair.holeRects[side]`, normalised to the piece with a top-left origin. On a strip the frame is where
  the engine put its gate (§12.4), and this rectangle is not used.
- **none for a film that is scanned and not printed** — a slide, a negative scanned, a digital intermediate: the
  engine leaves the enlarger out of those, and a frame's rows would print the same picture again.

`EngineRouter.prepare(_:pair:…)` and `prepareExport` put them on `EngineHost.Request.layers`, for the frames whose
picture is on the piece: a hole whose frame has gone from the library is bare film, and bare film prints as the
film does.

### 12.2 The engine's side

`SpkEngine.render` (`Scheduler/SpkEngine.swift`), after the job's own render and before the picture is delivered,
for each layer (`printLayers(_:_:_:into:…)`):

1. `spk_set_params(session, the film's four rows with the layer's over them)`;
2. `spk_reprint(session, tier)`: the tier's negative printed again. **A render made in bands keeps no negative**,
   so there the reprint develops the film again, with the tier's same film seed: the grain under the frame is the
   grain round it. The engine renders every job of this app whole (`ENGINE-WIRING.md` §5), so on the Mac the
   reprint is of the kept negative; the banded path stays for an engine that cuts bands;
3. `FrameSource.cut(job, layer:, _, into:)`: the host cuts that print into the result (§12.3), and the layer's
   texture is released before the next is made — one more result alive at a time, 8 bytes a pixel;
4. after the last, and however the job ends (a cancel, a failure): the film's four rows are put back. Should that
   fail, the page's session forgets what it was sent of those rows, so the next edit sends them again.

A frame's print is not an edit of the look: the page's session and its record of what the engine was sent are
otherwise as they were. `FrameSource`'s `printLayers`, `cut` and `wantsFilmGeometry` each have a default (none,
nothing, no), so a host with no pair implements none of them.

### 12.3 The cut

`PrintCut.cut` (`Engine/PrintLayers.swift`) is 1.x's `pairCoverage` kernel on the result's own 16-bit memory:

- a pixel is its centre; `d` is how far inside the frame's nearest edge that is, in pixels; the pixel takes
  `clamp(d / 1.5 + 0.5, 0, 1)` of the frame's print — half at the edge, all of it from 0.75 px inside, none from
  0.75 px outside;
- inside, the frame's print is copied as it is; at the edge the two are mixed; **everywhere else the film's print
  is not written at all**, so the film between the frames stays the engine's to the last code;
- the host turns nothing after a pair's render (`Request.turnsAfter` is 0), and `EngineHost.cut` refuses a canvas
  it would turn: a frame's rectangle is of the canvas as the engine made it.

**The texture is the memory that was written.** `spk_result.rgba16` is the result buffer, and on the Mac the
result's texture is a linear texture over that buffer, so a write to the one is a write to the other (seen
2026-10-10 through `SpkEngine`'s own path: `texture.buffer` at its offset, and the texture blitted back from the
GPU word for word the memory with the frame's print in it). `EngineHost.carry` still asks the texture: where its
buffer is the memory that was written, nothing is done; where it is not (a Metal that cannot make a linear texture
over a shared buffer, `engine/src/gpu/metal_gpu.cpp`, `texture`), the rectangle the cut wrote (`PrintCut.Written`)
is blitted into it. Asked at run time, because the question is whether the texture is that memory, and the texture
answers it.

### 12.4 Where a strip's frames are

With a film edge the canvas is the film and not the piece, and only the engine knows where it put the two gates.

- **Asked** after the render: `spk_overscan_geometry(session)` (`SpkEngine.filmGeometry`), when the host wants it
  (`FrameSource.wantsFilmGeometry`): a pair on its strip, for the page's canvas, and for any job with a frame's own
  print to cut in.
- **Read** by `FilmGates.rects`: each gate's four corners become the rectangle that bounds them, and a pair's two
  come **in the film's order whichever way the reply lists them** — sorted along the axis their centres lie apart.
  Nothing where the reply is not valid, or a gate does not parse: a gate is never guessed at.
- **The engine's reply as it came** (the piece 2,400 px long; kept in `tools/pair_selftest.swift`), as x, y,
  width, height of the canvas:

  | the pair | canvas | first gate | second gate |
  |---|---|---|---|
  | turned (the film runs down) | 2269 × 2453 | 0.1564, 0.0088, 0.6864, 0.4765 | 0.1571, 0.5110, 0.6864, 0.4765 |
  | level (the film runs across) | 2453 × 2269 | 0.0088, 0.1572, 0.4765, 0.6864 | 0.5110, 0.1566, 0.4765, 0.6864 |

  A gate is a half frame in the canvas's pixels (24 : 18 turned, 18 : 24 level, to 0.002), and a little out of
  true: its corners lie 1.3 px off square at this size, which the bounding rectangle takes in.
- **To the page**: `EngineHost.Delivery.gates(frame:rects:)`, sent before the canvas it is of; `EngineRouter.onGates`;
  `AppServices` hands them to the open page's `OpenFrameSession.located(_:)`, and `OpenFrameSession.frameRects` then
  answers with them.

### 12.5 The stamp and the price

- **The stamp** (`DevelopStamp.of(…, prints:)`) holds each layer's `key` — the frame and its four rows — so a
  frame's own print is another picture to keep. With none it is the stamp it was. **The piece's own key
  (`PieceAsk.key`) does not hold a print**: the pixels handed over are the same, so the session and its negative
  are kept, and a frame's own print is a `canvasReprint`.
- **The price**: `RenderJob.printLayers`, the count, from `EngineRouter.printLayers(frame, edit:)` in
  `AppServices.develop`, `ExportService` and `OpenFrameSession.submit`. `CostModel.seed` adds 8 bytes a pixel of the
  canvas once (the second result), and a print pass a layer — a develop again where the job is planned in bands.
  **Arithmetic, not a measurement**: on 2026-10-10 a 14.1 MP export with one layer was planned in bands at 680 MB of
  the 902 MB the scheduler was told, and ran in 1.1 s.

### 12.6 What was checked

**The self-tests**, `tools/selftest.sh` and `tools/selftest.sh --self-test`: which frames are asked for and with
which rows, none of a scan, the stamp (`pair_selftest.swift`); every channel of every pixel of a cut against 1.x's
kernel as written, each row's padding, and what a cut says it wrote (`piece_selftest.swift`); the engine's two
replies above, read; the job's price (`scheduler_selftest.swift`).

**On the engine, through the app's own path** (`--pair-check`, `Sources/App/PairHarness.swift`, 2026-10-10): every
change made through `AppServices.changePair` and the page's own session, and read off the picture the page shows —
the mean of each frame and of the film between them, 0…255, where the page says the frames are. Two HEIC
photographs, Porta 400 on Supera Endura:

| the piece, turned (1556 × 2399) | first | film | second |
|---|---|---|---|
| as it began | 124.7 | 12.5 | 128.6 |
| the second frame's own print +1.5, on Frame | 124.7 | 12.5 | **162.2** |
| the first frame's print +1.0, on + Film | **165.1** | **16.7** | 162.2 |
| the film's print half a stop down | **146.4** | **13.5** | **150.8** |
| the second frame's own Yellow +0.6 (blue over red) | +0.0 | −0.0 | **+16.8** |
| the first frame's own print a stop down, on Frame: three prints | **100.7** | 13.5 | 149.6 |
| the second frame's print reset | 100.7 | 13.5 | **128.6** |
| the film's print reset: one print again | 124.7 | 12.5 | 128.6 |

- The same seven on its strip, turned and level, the frames at the engine's gates, and on the bare piece level: in
  each the part that should not move is the same to the tenth of a code (on the strip: first 124.9 → 124.9, film
  12.5 → 12.5, second 129.2 → 162.8; then first → 165.4, film → 16.7, second 162.8 → 162.8). Each picture's job
  says what it printed (`RunMeasurement.layerSeconds`): the film's print and one more, or two more where both
  frames print as their own, 0.03 to 0.04 s each at this size. One print again is stamped as the piece was before.
- **One hole empty**, and the frame that is left — the second — printed +1.5 as its own beside bare film: the empty
  hole 12.5 → 12.5, the film 12.5 → 12.5, the frame 128.6 → 162.2. On its strip the engine still says two gates,
  and the print is cut in along the second (129.2 → 162.8).
- **A frame's own print under a drag**: twelve steps of it, each asked for at once and faster than a print is
  made. The scheduler gives a running print a reprint's time before it gives it up, so of the jobs the steps
  started one was given up half made in some runs and none in others (two to four were made); what landed is the
  last step's (124.7, 12.5, 162.2), the film's print round the frame still the film's, and one print again the
  picture it began as.
- **A job given up on purpose in the middle of its layer's print** — the frame's rows on the session then, in place
  of the film's — six times, through `SpkEngine`'s own path on a Mac build of the engine: the film's print
  asked for next, a reprint for which nothing is sent that the session is thought to have, had the film's mean each
  time (25460.2 of 65535 both). The rows a print borrows are put back however it ends. That probe is not in the
  repository.
- **Whether the back printed on a frame**, as cells of the picture more than 6 codes from the same picture with
  the back off: both frames 285 and 187; the second switched off, 285 and 0; the first off and the second on,
  0 and 187; the last switched off, the back off, 0 and 0; the first switched on while the back is off, 285 and 0.
  The same on the strip, turned (247, 157) and level (284, 136).
- **A Scene Placement of one frame's own**: the second frame's highlights pulled back 2.55 stops moved its
  brightest twentieth 11.0 codes and its mean 6.3, and the first frame not at all; picking the first frame then ran
  no job, landed no picture and left the stamp.
- **Out of the page**, the second frame at +1.5 and Yellow +0.4 (the page: 124.7, 12.5, 161.3): the queue's own
  develop 124.7, 12.7, 161.4; the 12 MP file 125.3, 12.9, 161.4; the full-size file (3024 × 4662) 125.3, 12.9,
  161.2; **and the full-size file developed in bands** (792 rows × 6, on an engine build that cut bands itself):
  125.3, 12.9, 161.2, its layer's print 0.37 s, the film developed again. On the strip the same, the full size
  4410 × 4766 in bands of 1,224 rows × 4.

### 12.7 Not verified

- **The price** is arithmetic: no layered job's peak was measured.
- A full-size export of a pair of two 48 MP frames with a frame's own print was not run: the largest exported in
  this work was 14.1 MP bare and 21.1 MP on its strip.
- On pixels, of the four rows: brightness and the yellow filter. The magenta filter and a frame's own pre-flash are
  held as rows by the self-tests and were not looked at in a picture.
- A black-and-white film, and a pair with a frame missing from the library, were not run with a frame's own print.
- Whether a print draws anything afresh that a reprint of the same negative should not repeat (the paper's glare)
  was not looked into: the parts a print should leave came back the same to the tenth of a code.
