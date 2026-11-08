# ENGINE-WIRING.md — the SpektraLab engine in the Mac app

How `app/SpektraLab` builds, creates and calls the engine (`engine/`), and what it holds to on each side of the C
ABI. Rewritten 2026-11-08 from the wiring notes of 2026-10-05…10-15 to say only what the code does today; where
a number was measured, the line says where. The ABI itself is `engine/include/spektralab/spk_engine.h`, the wire
`API-SPEC-callable-render-service.md` (a wire change edits its section in the same commit, `AGENTS.md`).

The rules the wiring keeps: **one door** (every render is a job on `RenderQueue`, never a call from a page);
**measure before claiming** (memory is `phys_footprint`, never RSS, which cannot see the Metal pool); **nothing is
removed silently** (a reduced render is never labelled full); **no CPU fallback** (there is no other path to fall
back to, trap 18).

---

## 1. The build: `tools/build_engine_mac.sh`

The app's only engine build. A Mac Catalyst app cannot link a plain macOS object, so the script compiles `engine/`
exactly as `engine/build.sh` does — the same sources, the same flags — for the Catalyst targets:

- **The library.** Every `engine/src/{core,gpu,pipeline}/*.cpp`, C++20 at `-O2 -Wall -Wextra`, compiled in parallel
  for `arm64-apple-ios18.0-macabi` and `x86_64-apple-ios18.0-macabi` (the macOS 15 floor, spelled as Catalyst spells
  it), each archived with `libtool -static` and joined with `lipo` into
  `build/engine-macosx/libspektralab_engine.a`. Both architectures, because a Release build of the app is
  universal. The source list is a glob: an engine `.cpp` added later is picked up by rerunning the script, and a
  stale library reads as a link error.
- **The kernels.** Every `engine/src/shaders/*.metal`, compiled with the macOS `metal` for `-mmacos-version-min=15.0`
  with `-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise -Werror`, linked into `spektralab.metallib`,
  then archived into `spektralab.metalar` by `engine/tools/build_metal_archive.sh`. **The kernels are never compiled
  by the Xcode target**, which builds with fast math, and no `.metal` file may be added to it (`gen_project.py`);
  `spk_engine_create` refuses a fast-math library (§2).
- **The resources.** `build/engine-macosx/EngineResources/`: `engine/resources/` verbatim but for its metallibs
  (engine/build.sh's `bundle_resources`), the product's own profiles from `engine/resources_product/profiles/` laid
  into `profiles/` with their notice as `PRODUCT_PROFILES_NOTICE.md`, `LICENSE-PROFILES.txt` (the CC BY-SA 4.0
  terms the profiles ship under), the metallib and its archive, and `ENGINE-COMMIT.txt` — the last commit that
  touched `engine/`, `%h %cs`.
- **Into the app.** Where `build/engine-macosx/libspektralab_engine.a` and the metallib both exist, `gen_project.py`
  links the archive with `-lc++` and the frameworks the engine calls (CoreText among them: the film edge sets its
  type through it), sets `SPK_ENGINE` (which compiles `Scheduler/SpkEngine.swift` and the engine host), puts
  `engine/include` on the header path for the bridging header, and adds a build phase that copies
  `EngineResources/` into the bundle. Without them, or with `--no-engine`, the target is the interface and the
  scheduler over `SimulatedEngine`, which keeps an engine's time and renders nothing. A build that did not rerun the
  script carries the previous resources, not none (trap 14).

The app calls the engine's own C ABI from Swift, with nothing in between.

## 2. Creating the engine

`EngineRouter.init(wantsEngine:)` (`Engine/EngineRouter.swift`):

1. `Bundle.main.resourceURL/EngineResources`, and `spektralab.metallib` in it, or the failure is "The engine's
   resources are not in this app.";
2. `MTLCreateSystemDefaultDevice()`, and an `EngineHost` on it;
3. `SpkEngine(resources:device:source:)` → `spk_engine_create(resources, device)`: **the engine is made on the
   host's own device**, so the buffers the host decodes into are the engine's to read (`spk_open_device`). A NULL
   engine throws with `spk_last_error`, which goes to the log only (it may name a profile), and the page's failure
   is "The engine did not start on this device." A build without `SPK_ENGINE` says "This app was built without the
   engine." The app never falls back to a simulation quietly: Settings › Diagnostics › This build says which engine
   runs.

At creation the engine runs its math probe and refuses kernels built with fast math (AGENTS.md "Do not"); that
refusal is the intended outcome of a wrong build, not a bug to work around.

- **Name and identity.** `SpkEngine.name` is `spk_build_info()`, `spektralab-engine 2.0.0 (<date> <time>, math=safe)`.
  `EngineRouter.identity` is `effectVersions | ENGINE-COMMIT.txt`, and it is in every develop's stamp
  (`DevelopedPicture`): two engines that render differently must not share a kept picture. **On this engine
  `effectVersions` is "?"**: `spk_capabilities` has no `backend.effect_versions`, so the identity is `?|<commit>`
  and only the commit tells two engines apart. Changing it re-keys every kept develop.
- **Warm-up.** Once the library is up, `EngineRouter.warmUp(film:paper:)` → `spk_warm_up` for the pair new frames
  develop with (`AppSettings.newFrameStocks`), so its setup is not built on the frame the person is waiting for.
- **The wire, at launch.** `AppServices.checkWire` holds the app's wire against `spk_params_schema`: a default frame
  with a film edge and a date on, every slide film of the bundle's catalogue (it must be sent scanned), every
  black-and-white film (on its paper, with its filter pack, grain as one layer), and a half-frame pair on its strip
  with a date in each frame. A name the engine does not know is reported, not sent quietly.

## 3. The seam: `DevelopEngine`, `SpkEngine`, `FrameSource`

`DevelopEngine` (`Scheduler/DevelopEngine.swift`) is what the scheduler asks of an engine: `run(job, mode,
progress)`, `cancel`, `trim`, `heldBytes`. `SpkEngine` (`Scheduler/SpkEngine.swift`) is that over the C ABI, and
its header lists what it holds to, each from a measurement. In short:

- **One serial queue for every call that renders** (`com.spektralab.engine`). The engine is not re-entrant per
  session, `spk_render` blocks for the whole render, and one GPU job at a time is the scheduler's rule anyway.
  `spk_last_error` is per thread: it is read on that queue, right after the call that failed.
- **One autorelease pool per job**; without one a run of four photos leaked 72 → 646 MB.
- **The frame is opened without a CPU copy.** The host decodes into a shared buffer of the engine's device and
  `spk_open_device` borrows it for the call; `spk_open` with a host pointer would copy the whole frame (744 MiB at
  48 MP) and leave the copy in the pool. The decode's buffer is released with the open's pool, before the render
  starts, so the decode's peak and the render's do not add up.
- **The page's frame keeps its session** (`Editing`): a print-side edit is a reprint from the cached negative.
  A job's other sessions are released before its result is delivered, so the host's side of the job (the output
  transform, the encoder) starts from what the render left. `closeEditing` gives the session back when the page
  closes or the frame is removed; `reclaim(keeping:)` gives it back when a job someone waits on cannot fit.
- **A parameter change is sent as its difference** (§4.1).
- **A cancel is never lost.** `spk_cancel` only sets a flag and is safe from any thread; the engine clears its flag
  when a render starts, so `SpkEngine` keeps its own and hands it over again every few milliseconds until the render
  ends. `spk_progress` is read after the render, never during it: it copies a string the render thread is
  assigning.
- **`trim()` returns 0.** The engine trims its own pool, at the next open once no session is left or the frame's
  size changes, and after an idle spell; there is no call for "now".

`FrameSource` is what the engine asks its host, on the engine's queue: `decode` (the frame's pixels at the job's
size), `params` (the whole wire), `deliver`, `sourceKey` (what the pixels are made of: a job whose key is not its
open session's is opened again), `printLayers`/`cut`/`wantsFilmGeometry` (a pair's frames that print as their own,
`PAIR-WIRING.md` §12), `cached` (an export whose full render is on disk, §6.3) and `digital` (Apply Film Emulation
off: Apple's decode, cut, with no session and no film). `EngineHost` (`Engine/EngineHost.swift`) is the app's:
**each job's answers are captured on the main actor when it is submitted** (`EngineRouter.prepare` → `Request`) and
kept until the job ends, because an edit moves under the pointer and a job that gives way runs again with the same
id.

### 3.1 Opening a frame: `FrameDecoder`

The engine takes scene-linear float32 in ProPhoto RGB, top row first, in a buffer of its own device.
`Engine/FrameDecoder.swift` makes that of any file, holding to:

- **A job below the full tier is decoded no larger than its canvas** (opened whole, a 48 MP photo's 2,400 px
  preview took 1.1 GB where 0.5 was priced).
- **A HEIF or a JPEG is reduced by ImageIO** (`CGImageSourceCreateThumbnail` at the size asked), where Core Image's
  own scale holds the original while it works; the picture's means are within 0.22 % of the full decode's develop.
- **A RAW is decoded with a linear look** (`RawExposure.prepare`): boost, shadow boost, gamut mapping, local tone
  mapping and extended range off; the camera's own noise reduction and sharpening as the file has them; lens
  correction only when the frame asks for it. **Made smaller by a scale after its decode, never by `scaleFactor`**,
  which under RAW 9 returned a quarter of a frame at twice the size and left a bright band at two edges.
- **The Core Image context's working space has sRGB's primaries** (extended, linear, half floats): RAW 9 decoded
  Bayer files in the wrong colour with any other.
- **Rendered in bands into the one buffer**, each band in its own autorelease pool, and the context's caches cleared
  when the decode ends (751 MB against 1,334 for a 48 MP ProRAW DNG at 2,400 px, on the Mac).
- **A film edge's framing, and an export's cut, are made here** (`HostCut`), after the scale (§4.3).
- **A half-frame pair's piece is composed here**, one picture at a time into its hole (`PAIR-WIRING.md` §2).

**A RAW's preview-size decode is kept** (`Engine/RawProxy.swift`, the owner, 2026-10-20): Core Image's own picture
of the RAW at the frame's preview size, uncut and unturned, named by the frame, the decode settings that change its
pixels, the size, the decoder and the system's version. Nothing developed is in it: the film, the paper and every
effect are the engine's, and an edit is recomputed as before. Until it, every open of a RAW's page decoded the file
again, and Develop's film and paper strips waited on that decode.

## 4. Parameters

### 4.1 The delta

`spk_open` is handed the frame's whole wire; after that `spk_set_params` is handed only what changed since the last
send, and `SpkEngine` keeps what it sent (`Editing.applied`). Two engine behaviours make that necessary:
`spk_set_params` drops the cached negative when the delta **names** a film-side field, whether or not its value
moved, and rebuilds the pipeline when it names a stock. So a print-side edit stays a reprint. When a film or a paper
changes, every field the frame no longer sends is dropped from what the client holds, so a field that is sometimes
sent (a silver pair's filter pack, §4.7) is sent again when it returns. `FilmParams.liveMutable` (`print_exposure`,
`m_filter_shift`, `y_filter_shift`, `preflash_exposure`, `filter_shift_scale`) are the rows that rebuild nothing.

### 4.2 `FilmParams.wire`

`Model/FilmParams.swift`, `wire`, in a stable order: the film and the paper, the exposure and its meter
(`auto_exposure_method` only when set, so a frame from before it meters as it always did), the film's format, grain,
halation and `antihalation_removed`, the enlarger (`print_exposure` = 2^−stops, the two filter shifts,
`filter_shift_scale`, pre-flash), glare, `scan_film`, `extended_dynamic_range`, the contrast mask (always off), the
resolved Scene Placement curve (§4.5), the Decode curve (`scene_curve`, "" for none), the effect strengths (clamped to
`EffectStrengths`' ranges), the Digital Intermediate, and a pair's second placement (`pairPlacementWire`). Fields
whose default is the engine's are sent always, so a frame's picture does not depend on whether it was saved before
the field existed (its stamp moves once).

- **The working space is never sent.** The session's output is ProPhoto RGB, encoded (`OutputTransformer.workingSpace`),
  and the host leaves it with the engine's own output transform (§6.1). The input and output colour-space fields are
  the contract, not a setting.
- **Never sent**: `lens_blur_um`, `halation_boost_ev`, `density_curve_gamma`, the scanner fields, `striped` and
  `strip_rows`. The engine renders every job of this app whole (§5).
- `dir_couplers_amount` is clamped short of where the coupler inverse's axis turns non-monotonic (trap 22).

### 4.3 Geometry

`Engine/EngineWire.swift` puts the rest of an edit beside `FilmParams.wire`, so the develop page, an import's develop
and an export hand the engine the same words:

- **the cut**: the engine's eight geometry fields (crop, straighten, quarter turns, flips) — normalised crop with a
  top-left origin, rotation positive clockwise. The engine applies them right after the frame is read and before the
  meter, so the picture it hands back is already cut and nothing may cut it again;
- **`product_defaults`**: a switch, not a schema field. It selects the product's defaults, which turn the enlarger's
  print-exposure compensation off so that Film Exposure moves the finished print (compare trap 30). It is in every
  open;
- **`preview_long_edge`**: the size of the engine's `live` tier, sent for a job below the full tier with the frame
  decoded no larger, so the engine renders the job's canvas and not a tier of its own.

**An export's cut is the host's** (`ExportPlan.swift`): the size a recipe names is made in the decode, at a long edge
both of whose sides are whole and even, and the cut is made by `HostCut` with the film's millimetres carried down
(`filmFormatMM`), so a cropped frame is developed with the same micrometres a pixel as the uncut one — not finer
grain and a tighter halation than the develop page showed.

### 4.4 Film Edge and the Date Back

`FilmWire` (`FilmEdgeSettings.wire`, `DateBackSettings.wire`) sends `overscan_*` and `date_imprint_*` in the model's own
words, the fields `tools/film_edge_parity.py` sends. **The engine draws the film**: the rebate, the holes, the edge
print and the date are exposure on the negative, and the picture it hands back is the film's canvas, larger than the
picture (API-SPEC §15, "the output grows").

- **With a film edge the host cuts the picture, not the engine** (`FrameEdit.hostCut`, made in `FrameDecoder`), and
  the wire's own cut is none. The engine takes the frame it is handed as the gate and sets the film's millimetres from
  its long edge *before* its own cut; cut by the engine, a square taken from a 4:3 photo was laid on the film as 42 mm
  of a 56 mm gate (asked 1952 × 1966, rendered 1978 × 2614, 2026-10-07).
- **A film turned half round is the host's doing too** (`FilmEdgeSettings.hostTurns`): the picture goes in turned
  back, in the same cut, and the canvas comes out to be turned forward by whole quarter turns (`Request.turnsAfter`):
  pixels moved, none resampled.
- A cut within a pixel of square is handed over square. A session whose pixels change is opened again
  (`FrameSource.sourceKey`).
- Before 2026-10-07 both were sent off and the page drew a film of its own round the developed picture — flat ink,
  white holes, no grain, no halation. The owner: "the film edge is never truly rendered."

`tools/film_edge_parity.py` holds the app's port of the engine's layout (`FilmLayout`, the guide drawn before a
develop) against the engine's render, case by case (`PAGES.md` §6).

### 4.5 Scene Latitude: the pull-backs are not wire fields

The wire carries the resolved curve only (`scene_latitude_*`: knees, rooms, roll-off, the lift's limit); the
pull-backs a person dragged stay in the sidecar. **The app solves a ruler's step itself** (`Engine/ScenePlacement.swift`,
`PlacementFit`): the engine's Fit (`engine/src/core/latitude_fit.cpp`) carried over expression for expression, on four
numbers the last measurement already carries, because the engine's call queues behind whatever develop is running (0.5 ms
a Fit, and 424 ms for one behind a develop). The engine's Fit is the reference, asked for a pasted placement, and
`tools/latitude_selftest.swift` holds the app's solve against the engine's own replies (`tools/engine_replies`). The Fit
takes a window of pull-backs on each side; on many frames the shadow side has none (six of ten real frames,
2026-10-07). Under the Digital Intermediate the placement is off: the DI keeps the film's whole range.

### 4.6 The other fields

- `filter_shift_scale` is sent always, at `FilmParams.filterShiftCC` = 40: what a unit of the two enlarger shifts is in
  the head's CC units (API-SPEC §17). The engine's own default is 1, the reference's, at which the two controls move
  nothing a person can see.
- `antihalation_removed` (RFC-044) is the film's backing layer, resolved by the engine's halation preset.
- `digital_intermediate_blue_compensation` is sent only while the DI is on, so the Settings switch cannot move any
  other frame's stamp.

### 4.7 Black and white: what a host sends (2026-10-09)

The engine has four black-and-white films and their silver paper (`engine/resources_product/`), and **the engine
enforces none of the following**; each is the 1.x app's rule (`Params.swift` there), and what the engine does without
it was measured on 2026-10-09 through an earlier build of the engine on this Mac (a 900 × 600 frame, grain and glare
off, in codes of 65,535):

| the rule | on the wire | without it |
|---|---|---|
| silver film on silver paper, colour on colour | `print_stock` = `ilford_multigrade_iv_rc` for a film whose profile says `channel_model: "bw"`, and for no other film | the engine refuses neither: `kodak_tri_x_400` on `kodak_supra_endura` prints orange (mean R 43,693, G 38,960, B 22,564; no filter pack exists for the pair), and `kodak_portra_400` on the silver paper develops too |
| Multigrade filter 2 on the enlarger | `c_filter_neutral` 0, `m_filter_neutral` 0, `y_filter_neutral` 68, for a silver pair only | the engine's table has no row for a silver paper. A session that comes from a colour pair keeps that pair's pack (M 50.7, Y 55.6 from Portra on Supra) and a fresh one takes the default (M 65, Y 55): the print's mean is 46,490 or 47,736 where the pack gives 36,308. Back on the colour pair the engine takes its own row again (the first picture, byte for byte), so nothing is sent then |
| no Extended Dynamic Range on the silver paper | `extended_dynamic_range` false | **refused**: "print profile 'ilford_multigrade_iv_rc' has no calibrated EDR tone map" — at the open, at an edit, and when a colour session with EDR on changes to the silver pair |
| grain as one layer | `grain_sublayers_active` false on a black-and-white film, whatever the setting | the three sub-layers are the colour films' model and nothing on a black-and-white sheet supports the split |
| each film's own grain | `grain_amount` = the slider × 1.70 (`kodak_tri_x_400`), 1.49 (`ilford_hp5_plus_400`), 0.74 (`kodak_tmax_100`), 0.64 (`fujifilm_neopan_acros_100_ii`), clamped to the wire's 0…2 | at the engine's own 1 the four render alike; at these they render the granularity each maker publishes |

A black-and-white negative scanned (`scan_film`) needs none of the paper's three, and comes out grey (the largest
channel spread 8 codes).

**Where the app holds it**, in the three places the slide rule is held, so that no caller walks past it:

- **the pick** (`FilmParams.load(film:)`, `print(on:)`): a film loaded over a paper that cannot print it takes its own
  paper — the one case in which a film card changes the paper — and a paper of the other kind is refused;
- **every edit that enters** (`heldToItsFilm`): a paste, a library read from disk, a session's change;
- **the wire** (`StockCatalog.wire(for:)` → `silver(_:into:)`): the four rows of the table that an edit does not hold,
  each conditional on a stock the catalogue marks `monochrome`, so that **no colour frame's wire moves** (held field
  for field over every colour pair by `tools/develop_selftest.swift`).

The catalogue (`tools/gen_catalog.py` → `Resources/StockCatalog.json`) carries what the rules read: `monochrome` from
the profile's `channel_model`, a film's `grain`, and a paper's `neutralPack`, read from
`engine/resources_product/paper_grades.json`, grade 2. **The enlarger's two shifts are sent as the frame has them**: on
the silver paper they are its grade and not a colour — with filter 2 as the pack and a `filter_shift_scale` of 40,
Yellow +1 is a softer and darker print and Magenta +1 a harder and lighter one, neutral throughout (`Stock.swift` has
the figures). The pages show the rule and never hold it (`PAGES.md` §4, rule 9).

Not built: **a lens filter** (`camera_filter`, API-SPEC) and **the paper's grade** as a control
(`paper_grades.json`: filters 00–5, each a pack and a print exposure).

## 5. Jobs, tiers and memory

- **Every render is a job on `RenderQueue`** (`JobKind`: `canvasReprint`, `canvasDevelop`, `importDevelop`,
  `export`, `fullView`, …). Canvas jobs are coalesced — at most one queued per frame, the latest wins, and a running
  one is cancelled once the newer one has waited a reprint's time. A job that cannot fit waits and says why
  (`WaitReason`); it does not gamble. One GPU job runs at a time.
- **The budget is read before every job**, never cached (`MemoryBudget`, `MemoryProbe`). On the Mac there is no
  per-app allowance: `MemoryProbe.appAvailable` answers the machine's physical memory, and the machine's headroom
  (free + inactive + purgeable pages, `host_statistics64`) is what binds. The app's own footprint is
  `phys_footprint`. Settings › Diagnostics › This build shows the budget a job would be given now and which of the two
  binds.
- **The engine renders every job whole.** The scheduler still plans a mode — whole, bands, smaller bands — from its
  cost model (`CostModel`), and `.bands(rows)` is reported as the progress it planned, but nothing is handed to the
  engine for it (`SpkEngine.render`); the engine's own striped executor is not asked for (§4.2).
- **`full` is never a reduced size.** A job below the full tier is decoded no larger than its canvas; a full-tier job
  decodes the original at its own size.

## 6. Results

### 6.1 Leaving the working space

`spk_result` hands over a texture and its `rgba16` buffer; the texture is the host's to keep, and on the Mac it is a
linear texture over that buffer (`texture.buffer`), so the two are one memory. **One conversion out of the working
space a destination** (`Engine/OutputTransform.swift`): the engine's own numbers (`spk_output_transform`, RFC-018
§5.2) — the working space's curve off, a 3 × 3 chromatically adapted, CAM16-UCS gamut compression into the target, the
target's curve on. The kernel is the 1.x app's `outputTransform`, carried over statement for statement, compiled at
run time from source with safe math (no `.metal` in the target), writing a buffer a `CGImage` is made over without a
copy. Display P3 at 16 bits for a page; for a file, its recipe's space (`sRGB`, `Display P3`, `Adobe RGB (1998)`,
`ProPhoto RGB`) at its own depth, 8 bits written by the kernel itself for JPEG, HEIF and PNG and 16 for TIFF. The
lightness stage of the compression is left off: the engine has already run it before it encoded the working space,
and a second pass compressed an export's highlights.

### 6.2 What is kept

- **A frame's develop** (`Engine/DevelopedPicture.swift`): written as a picture in Display P3, and what the library
  and the browser draw; nothing is developed again to draw a tile. **The stamp is what it was made from** — the whole
  wire, the decode settings, the decoder, the cut and turns, the size and `EngineRouter.identity` — and is in the file's
  name, because the picture cache keys by path. A frame whose stamp is not the one its edit would make today is stale:
  shown as it is, and developed again in the queue. Since 2026-11-05 a catalog's develops live in that catalog's
  `Cache/Previews` (`MAC-LIBRARY-DATA.md` §2j).
- **The full render** (`Engine/FullRender.swift`, the owner, 2026-10-20): the engine's own result at full size, in its
  working space, 16 bits, before the output transform and Edit's layer, on disk in 256 × 256 tiles at the full size and
  half of it (8 bytes a pixel and a quarter more: 48 MP is 480 MB). Made by its own job (`fullView`), planned and priced
  as an export at Full, when the develop page is zoomed past its preview (`FullDetail`), or by the Light Table or the
  Mac's prefetch (`FullRenderJobs`: made once, whoever asks). Kept under a limit of its own (Settings' cache size),
  the one used longest ago going first, never the one shown or being made.
- **The zoom reads the screen's pixels, not the picture's** (`Engine/FullDetail.swift`): the part on screen is read by
  the tiles it touches, from the half size when shown at half or less, and made the screen's size in one GPU pass
  through the same output transform and Edit's Layer 2 (25–50 MB for a moment, 12 MB kept while shown). Any edit the
  render is of lets it go at once; a change of Edit's layer or Edit's crop does not.

### 6.3 Export

`ExportService` (batched by `MacExportRun` on the Mac page, `MAC-LIBRARY-DATA.md` §2b) prices and submits one job a
picture, at the size its recipe names (§4.3). An export whose engine side is a kept full render's — the same file,
decode, cut, wire and engine — is delivered from that render in any colour space and container, and the engine is not
run (`FrameSource.cached`). A frame with Edit's Light, Curve or Colour goes through the same output transform with
Layer 2's pass inside it (`Layer2Export`), in one kernel. `ExportWriter` writes the file.

### 6.4 Edit (Layer 2)

Not a job and not the engine: a pointwise pass on the GPU over a picture that is already developed
(`Engine/Layer2Renderer.swift`, `Layer2Kernel.swift`), which is why it follows the pointer. The page's picture, a tile's
copy, an export and the zoom all run the same functions. `tools/layer2_selftest.swift` runs the kernels on the Mac's
GPU against a reference.

## 7. Analysis calls

- **`spk_scene_latitude`** (`SpkEngine.sceneLatitude`, `Engine/SceneLatitude.swift`): on the session the canvas keeps
  open, on the engine's queue, so it never runs beside a render. It measures and solves and never renders: the medium's
  two boundaries, the frame's histogram on the stop axis, a suggestion, and the fit of the pull-backs asked for. The
  medium is cached in the session on the fields it reads and the scene on the meter's (0.2 ms a call once both are, on
  the Mac); a first call, or one after a stock, filter or exposure change, probes a 1,024-sample ramp through the film
  and the print (48 ms on the Mac). It throws `cancelled` when no session is open on that frame. A pair's reading names
  its frame by `region` (`PAIR-WIRING.md` §6.2).
- **`spk_solve(session, "exposure")`**: the engine's own meter on one picture alone, for a half-frame pair's holes
  (`PAIR-WIRING.md` §4).
- **`spk_overscan_geometry`**: where the engine put the film's gates on the canvas it just made, for a pair on its
  strip (`PAIR-WIRING.md` §12.4).
- **`spk_memory_report`**: what the engine holds (`heldBytes`), for the job's record.

## 8. The checks

| check | what it holds |
|---|---|
| `AppServices.checkWire`, at launch | the app's wire against `spk_params_schema` (§2) |
| `tools/selftest.sh` | the scheduler on `SimulatedEngine`, the Latitude card and the app's placement solve against the engine's replies, the host's cut, an export's arithmetic, the develop page's panels, a pair's arithmetic and cut, Layer 2's kernels, the log, the language (no Xcode project, no engine) |
| `tools/film_edge_parity.py --engine engine` | the app's film layout against the engine's render (`engine/build.sh dylib` first) |
| `tools/engine_smoke.sh mac [W H]` | the engine on this Mac through `spk_engine_create`, each render's sha256, so two builds can be held against each other to the bit; `--latitude-grid` / `--latitude-sweeps` write the replies `latitude_selftest` reads |
| the engine's parity harnesses | the engine itself, against the Python oracle (`docs/agents/BUILD-AND-TEST.md`) — only when engine inputs, kernels, resources or the render boundary changed |

`tools/engine_replies/*.jsonl` are the engine's own replies, kept so the self-tests need no engine. They carry the
engine's build stamp; when the engine's output can have moved, record them again with `engine_smoke.sh`.
