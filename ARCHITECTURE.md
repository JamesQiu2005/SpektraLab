# ARCHITECTURE.md

How SpektraLab 2 is put together: a Mac Catalyst app with the SpektraLab engine, a C++/Metal render
engine, linked into it, and a library helper, `spklib-host`, running beside it. Written for someone
about to change the pipeline, the app or the release. Current as of **2.2.1, 2026-11-09**.

The SpektraLab engine is a C++/Metal implementation derived from spektrafilm by Andrea Volpato
(GPL-3.0-or-later). The engine's sections (§1–§4, §6, §8) carry over from 1.x except where they
named the app. The app's sections (§0, §5, §7, §9) describe `app/SpektraLab`. The 1.x app
(`modern_UI/Spektrafilm`, whose sources are no longer in the tree) is Appendix A. The Windows and
Linux port (`desktop/`) was written against it and cites its numbers as §7.x; §A keeps them as
§A.1–§A.13, in the same order.

§0 is the map. §1 is the physical model, §2–§4 the engine's runtime, §5 build and release, §6 cost,
§7 the Mac app, §8 the engine in detail, §9 how it is verified. Other documents and the code cite
these numbers (§3, §6.1, §6.2, §7.x, §8.2–§8.8), so they stay put; new material goes in new
subsections.

---

## 0. The product, end to end

```
  ┌─ SpektraLab.app ── Mac Catalyst, universal, macOS 15+, 68 MB ─────────┐
  │  SwiftUI + UIKit, AppKit through the runtime · en · 简 · 繁 · 日本語    │
  │                                                                       │
  │  App/  Mac/   AppServices (the one model) · the window: Library ·     │
  │               Develop · Edit, Light Table, Import, Export, Settings   │
  │  Features/    the develop, edit, crop, film-edge and pair pages       │
  │  Model/       FrameEdit · FilmParams (the wire) · StockCatalog ·      │
  │               Geometry · FilmEdge · HalfFramePair                     │
  │  Services/    OpenFrameSession · FrameCatalog · import · previews     │
  │  Scheduler/   RenderQueue · MemoryBudget · CostModel · SpkEngine      │
  │  Engine/      EngineRouter · EngineHost · FrameDecoder (Core Image) · │
  │               OutputTransform · Layer 2 · FullRender · ExportWriter   │
  │  Diagnostics/ the log, kept on this Mac                               │
  │        │  spk_engine.h, a hand-written extern "C" surface             │
  │        ▼                                                              │
  │  libspektralab_engine.a ── engine/, C++20, linked into the app        │
  │     core/ setup maths · gpu/ five verbs and Metal · pipeline/ the     │
  │     nodes, the session, the C ABI                                     │
  │  EngineResources/  constants, profiles, minilab tables, the metallib  │
  │                    and its archive, licences                          │
  │                                                                       │
  │  Helpers/spklib-host ── its own process, JSON lines on pipes ─────────┼──▶ .spkcatalog, sessions,
  │                         (MIT, JamesQiu2005/SpektraLab_library)        │    Capture One read one way
  └───────────────────────────────────────────────────────────────────────┘
```

- **Two processes, one engine.** The engine runs in the app's process and returns an `MTLTexture`
  over its own buffer, zero-copy (RFC-014). The library is `spklib-host`, a child process: a crash in
  it cannot take a render down, the main actor never waits on SQLite, and an MIT program beside a
  GPL app is aggregation, not linking. No Python runs at any time; the Python implementation the
  engine was ported from lives upstream and is only the oracle for the parity harnesses (§8.6).
- **Parameters cross as JSON; pixels do not.** `FilmParams.wire` opens a session and then travels
  as deltas (`spk_set_params`); the frame's pixels are a buffer of the engine's own device, borrowed
  by `spk_open_device` without a copy (`app/SpektraLab/ENGINE-WIRING.md` §3, §4).
- **Every render is a job** on `RenderQueue`. A page never calls the engine and never loops a render
  (§4, §7.3).
- **The engine returns pixels, never files.** `ExportWriter` writes every file through ImageIO
  (§7.8, §8.8).
- **Edits live in the app's library and catalogs**, never beside the photograph, and a Capture One
  catalog is never written (§7.6, §7.13).

**Who owns what.** `CONTRACT-frontend-backend.md` §1 governs the wire: a field name, tier name, file
layout or version number is a wire change even when it looks like a refactor.

| topic | read |
|---|---|
| the engine: what was built, what parity measures | `rfc/RFC-014-native-cpp-engine.md` §8, §8 here |
| the wire and version negotiation | `CONTRACT-frontend-backend.md`, `API-SPEC-callable-render-service.md` |
| how the app builds, creates and calls the engine | `app/SpektraLab/ENGINE-WIRING.md` |
| the library, catalogs, Capture One | `app/SpektraLab/MAC-LIBRARY-DATA.md`, `API-SPEC-library-helper.md` |
| pages, the window's layout | `app/SpektraLab/PAGES.md`, `app/SpektraLab/design/MAC-LIBRARY-UI.md` |
| the half-frame pair | `app/SpektraLab/PAIR-WIRING.md` |
| languages | `app/SpektraLab/LOCALIZATION.md` |
| the colour chain | §7.5, `rfc/RFC-018` |
| memory | §4, `rfc/RFC-019`, `rfc/RFC-020` |
| scene latitude · contrast mask · effect strengths | `rfc/RFC-023`, `RFC-024`, `RFC-025` |
| traps that cost real debugging time | `AGENTS.md`, `docs/agents/TRAPS.md` |
---

## 1. The physical model

```
scene light → [camera+film] → latent image → [development] → negative dye densities
            → [enlarger+paper] → latent print → [development] → print dye densities
            → [scanner/viewing] → output RGB
```

One rule governs changes to this model:

> 不要为了修 rendering problem 去污染 material model。
>
> **Do not pollute the material model to fix a rendering problem.** Profiles
> describe what film and paper can do; they are not where scene placement,
> output headroom or grading live. A scene wider than the materials can
> separate is mapped before it reaches them (RFC-023); a print that needs
> headroom uses the output-side EDR stage; a final look is Layer 2. Fix the
> stage that owns the decision.

Colour is **spectral**: 380–780 nm in 5 nm steps, 81 wavelengths. Density
curves are 256 samples of log exposure from −3 to 4. Three transforms carry it:

**(a) RGB → film exposure.** Hanatos 2025 spectral upsampling
(`core/hanatos.cpp`). RGB → XYZ (CAT16 to the film's illuminant) → brightness
`b = X+Y+Z` and chromaticity `xy` → a triangle-to-square warp into a unit
square. A 192×192×81 table of spectra is collapsed **at setup** against the
film's sensitivity into a 192×192×3 `tc_lut`; per pixel it is a bicubic lookup
times `b`. The 81-wavelength axis never touches the image here.

**(b) Exposure → density.** Characteristic curves, then DIR couplers (a 3×3
donor→receiver inhibition matrix on silver density, spatially diffused,
subtracted from log exposure, re-interpolated against back-solved curves),
then grain.

**(c) Density → light → response.**

$$\text{out}_m = \sum_{\lambda} I(\lambda)\,S_m(\lambda)\;10^{-\left(\sum_k c_k D_k(\lambda) + D_{\text{base}}(\lambda)\right)}$$

Run twice: printing (S = paper sensitivity, I = enlarger) and scanning
(S = CIE 1931 CMFs, I = viewing illuminant). The kernel keeps the spectral
axis in registers — 3 values in, 3 out — and never materialises a per-pixel
spectrum.

---

## 2. Runtime structure

`engine/src/pipeline/pipeline.cpp` runs a **sequence of named nodes**, one per
physically distinct effect (RFC-003). The labels are the reference's, because
they are what timings and bisections report. A node whose parameters make it
the identity is skipped.

```
preprocess  decode_input · input_cast · geometry · crop_rescale · auto_exposure
filming     expose.scene_latitude (RFC-023) · expose.upsample · expose.exposure
            · expose.boost · expose.lens_blur · expose.overscan (RFC-032)
            · expose.halation · expose.log
            · develop.curves · develop.dir_couplers · develop.grain
printing    expose.enlarger_spectral · expose.contrast_mask (RFC-024)
            · expose.print_exposure (incl. pre-flash) · develop.print_curves
            · overscan.film_present
scanning    scan_spectral · xyz_to_rgb · gamut_compress · cctf · edr · glare
            · scanner_blur · unsharp · bw_correction · overscan.light
```

- **The film edge is three nodes** (§8.10): the exposure of the film outside
  the gate (edge print, fog, leaks, the date) before halation, so it blooms and
  develops with the picture; the film's presence in the print; and the scan's
  own light through the holes and past the film, last of all, after the
  scanner's blur and unsharp mask.

- Three entry/exit pairs are used: RGB → densities (`run_film`), densities →
  RGB (`run_print`), and both for a full render.
- `preprocess.decode_input` is dormant: Core Image decodes first (§7.5).
- A slide film (`scan_film`) has no print stage.
- **Print Effects** (`FilmParams.printEffects`) is a wire gate over every
  print-side effect except the colour transform: glare, pre-flash, the
  contrast mask.

A **session** holds one opened frame and its last negative. A `print`-layer
edit reprints from the cached negative; a `shoot`-layer edit rebuilds it
(§8.5). Tiers are `live` (the user's preview long edge), `preview` and `full`
(the frame's own pixels); the names are wire (contract §1.2.3).
- **Tiers on the Mac.** A job below the full tier sends `preview_long_edge` with the frame decoded no
  larger, so the engine's `live` tier is the job's own canvas; a full-tier job decodes the original at
  its own size (`ENGINE-WIRING.md` §4.3, §5).

---

## 3. Stage classification

| class | stages | shape |
|---|---|---|
| **pointwise** | upsampling, scene latitude, boost, curves, both spectral integrals, gamut compression, XYZ→RGB, CCTF | fused elementwise; no halo; LUT-able |
| **spatial** | lens blur, halation, DIR diffusion, contrast mask, scanner blur, unsharp | separable convolutions; tiling needs halos |
| **stochastic** | grain, **glare** | counter-based RNG for reproducibility |

Glare being stochastic is the source of the default nondeterminism
(`AGENTS.md` trap 1). Halation's unbounded support is what stops the full
render from being tiled.

**Gamut compression is a look.** `gamut_compress` is a CAM16-UCS roll-off — a
Reinhard shoulder on lightness (identity below 70) and a chroma knee against
the destination's `C_max`, hue preserved. The lightness half touches real
highlights; changing it changes the picture.

---

## 4. Memory model

- **Buffers are reused only when free *and* idle**: last handle dropped, and
  the command buffer that last named it completed (§8.3). The pipeline flushes
  at node boundaries.
- **Dead buffers are disposed, not just pooled** (RFC-020). Buffer classes
  P/F/R are released as the graph passes them; a 102 MP Hasselblad frame
  peaks at 13.7 GB in 1.0.3, from 23 GB. The render is the peak, not Core
  Image.
- **One GPU job at a time, priced first.** Every render is a job on `RenderQueue`
  (`app/SpektraLab/Sources/Scheduler`). The budget is read before every job, never cached
  (`MemoryBudget`, `MemoryProbe`): on the Mac the machine's headroom (free, inactive and purgeable
  pages) binds, against the app's own `phys_footprint`. A job that cannot fit waits and says why
  (`WaitReason`); it does not gamble. Canvas jobs coalesce: one queued per frame, the latest wins.
- **The decode is no larger than its canvas** below the full tier, and is opened without a CPU copy;
  its buffer is released before the render starts, so the decode's peak and the render's do not add
  up (`ENGINE-WIRING.md` §3, §3.1).
- **What is kept on disk, and what that costs.** A frame's develop (a Display P3 picture, named by the
  stamp of everything it was made from, in its catalog's `Cache/Previews`); a RAW's preview-size
  decode (`RawProxy`); and full renders, as 256 × 256 tiles at the full size and half of it (8 bytes
  a pixel and a quarter more: 48 MP is 480 MB), under Settings' cache limit, the one used longest ago
  going first, never the one shown or being made (`ENGINE-WIRING.md` §6.2). Deleting any of them costs
  time, never work.
- **Export never enlarges.** A recipe's size is made in the decode, and no frame is made larger than
  its original (`ExportPlan`).

RSS cannot see the Metal pool. Measure with `footprint -p <pid>`: on a live 1.x
session ~75 % of the app's footprint is `IOAccelerator` — pixels on the GPU —
and the code is ~8 MB of it.

---

## 5. Build and release

**SpektraLab 2 (the Mac app, `app/SpektraLab`).**

```
app/SpektraLab/tools/build_engine_mac.sh   the engine for Mac Catalyst, and EngineResources/
app/SpektraLab/gen_project.py              the Xcode project, generated from the tree
xcodebuild … build                         Debug, -destination 'platform=macOS,variant=Mac Catalyst'
xcodebuild … archive                       a release: Release, ARCHS='arm64 x86_64', unsigned
```

- **Xcode 27 or later.** Xcode 26.6 cannot type-check parts of the app: GitHub's `macos-26`
  image stopped twice on 2026-11-08 (the Develop strips' card chain in `StockPreviewPanel`, the
  parametric curve in `CurveMath`). Both were rewritten, but Xcode 27 is the floor the app is
  written against, as the README says. CI (`.github/workflows/build.yml`) runs on GitHub's
  `xcode-27` image (`macos-26` has Xcode 26 only), selects its newest released Xcode 27 and fails
  with that message when there is none.
- **The engine is built for Catalyst by `build_engine_mac.sh`**, from the same sources and with
  the same safe-math kernels as `engine/build.sh` (§8.4), because a Catalyst app cannot link a
  plain macOS object. It writes `build/engine-macosx/`, which the project links and copies.
- **Versions** live in `gen_project.py`: the default is the current release (2.2.2); a release
  passes `--version`, `--build <yyyyMMddHHmm>` and `--bundle-id com.spektralab.mac`, and the
  generated project is committed with it. A build without `--version` shows the default in
  Settings › General › About.
- **The library helper** is `vendor/spklib/macos/spklib-host`, a prebuilt MIT binary built by
  `./build.sh release` from a public tag of
  [SpektraLab_library](https://github.com/JamesQiu2005/SpektraLab_library) (2.2.x ships v0.3.1),
  its sha256 beside it; `API-SPEC-library-helper.md` §7 is how to update it. The app copies it to
  `Contents/Helpers` and runs it as a separate process.
- **Signing and notarisation.** The archive is unsigned. The helper is signed first
  (`codesign -i spklib-host`), then the app, with the Developer ID Application identity,
  hardened runtime and no entitlements; the DMG (the app, an Applications link, `Licenses/`) is
  signed, notarised with `notarytool` and stapled, then checked with `spctl`. Releases are
  GitHub releases carrying the DMG (`SpektraLab-<version>-universal.dmg`). The DMG is universal; the
  x86_64 slice has not been run on an Intel Mac.
- **Licences.** GPL-3.0 (`license/LICENSE`), the spektrafilm profiles' CC BY-SA 4.0
  (`license/SPEKTRAFILM_LICENSE.txt`), metal-cpp's Apache-2.0 and spklib's MIT go into
  `EngineResources/Licenses` and the DMG's `Licenses/`, with `license/NOTICE.md`. For 2.2.0 they
  were copied by hand after the archive; no script in the tree does it yet.

**1.x (`modern_UI/Spektrafilm`), history:**

```
engine/build.sh bundle     compile the kernels, rsync engine/resources into the app
Tools/gen-project.py       generate the Xcode project (run after adding any file)
xcodebuild …               the app, with the engine's C++ compiled into it
Tools/package.sh           archive → export → verify → floor → DMG → notarise → spctl
```

- **Kernels are compiled by `engine/build.sh`, not Xcode**, with safe math and
  `-mmacos-version-min=15.0` (§8.4). A metallib stamped for any other macOS is
  refused; one built for the host shipped once in 0.3.
- **`engine/resources/` is tracked** (15 MB of baked output). Regenerating it
  needs the Python reference upstream. The metallib is the one untracked file.
- **The floor is checked on the artefact**: `LSMinimumSystemVersion` 15.0,
  every Mach-O arm64 with `minos` ≤ 15, every metallib ≤ 15.
- **Versions** live once, in `Tools/gen-project.py` (`MARKETING_VERSION`,
  `BUILD_NUMBER`).
- **Signing.** Hardened runtime, empty entitlements, ad-hoc signed. Releases
  are GitHub prereleases as zips; the notes carry the `xattr` quarantine
  command. `package.sh` exits 1 without a Developer ID, by design.
- **Updates.** Settings ▸ General checks GitHub's latest release on request
  (RFC-021). The app contacts nothing else, ever.
- **Licences.** `Tools/bundle-licenses.sh` copies GPL-3.0, CC BY-SA 4.0 and
  Apache-2.0 into the bundle; `LicensingTests` and the pre-build phase check
  they are readable where About reads them.

---

## 6. Where the time goes

At 45 MP on an M3 Max a live reprint is ~0.01 s and a full render ~0.87 s
(§8.7). The largest cost on the open path is Core Image rendering the RAW to a
float bitmap, not the engine.

The model is **spatial-dominated**: halation and DIR diffusion were the two
largest nodes in the reference's 12.9 s 45 MP profile, and neither fuses.
Per-node engine timings need `SPEKTRALAB_NODE_TIMINGS=1` (§8.9).

On the Mac the RAW is decoded by Core Image once at the frame's preview size and kept (`RawProxy`), so
reopening a frame, and Develop's film and paper strips, do not pay for that decode again
(`ENGINE-WIRING.md` §3.1).

### 6.1 An execution plan changes how, never which

The scheduler plans each job: the memory it reserves, a whole render or bands, the size it is decoded
at, and when it runs (`CostModel`, `Planner`, `DevicePolicy`). A plan changes **how** a picture is made
and never **which** picture: the same edit at the same tier is the same pixels whatever the plan. The
engine renders every job of the Mac app whole; `.bands(rows)` is reported as planned progress, and
nothing is handed to the engine for it (`ENGINE-WIRING.md` §5). `DevicePolicy` holds the plan's
device-side numbers, and each says whether it was measured and where.

### 6.2 A reduced picture is never labelled full

Where a picture is less than the develop it stands for — a camera's own preview before the engine has
reached the frame, a picture decoded smaller than the original, an effect left out — the page says so
(`TagPill`, Info's *This render*, the status line). Nothing reduced is passed off as the real thing,
and an omitted effect is named (`PAGES.md` §4, rules 3 and 5).

---

## 7. The Mac app (`app/SpektraLab`)

A Mac Catalyst app: SwiftUI and UIKit, Metal in the engine, the Edit layer and the Light Table, and
AppKit reached through the Objective-C runtime where Catalyst has no API of its own (the scroll wheel,
the open and save panels). It is drawn at Catalyst's scaled idiom, so a scene point is 0.77 of a Mac
point; the library, Settings, Import and Export are written in Mac points and the develop, crop and
film-edge pages in scene points (`PAGES.md` §1). Its notes live beside its sources:
`ENGINE-WIRING.md`, `PAGES.md`, `PAIR-WIRING.md`, `MAC-LIBRARY-DATA.md`, `LOCALIZATION.md`, and
`design/MAC-LIBRARY-UI.md` for the window.

```
App/          AppServices (the one @Observable model) · RootView · routes · launch arguments
Agent/        the command line and the MCP server, and the app's socket they reach it by (§7.16)
Mac/          the window and its pages: Library (LibraryUI/, Library/), Import/, Export/,
              Settings/, LightTable/, Render/ (what is kept), MacShortcuts, the drive harnesses
Features/     Develop (and Edit), Frame (crop), FilmEdge, Pair, Import, Export, Library, Settings
Model/        FrameEdit · FilmParams (Layer 1, the wire) · StockCatalog · Geometry · FilmEdge ·
              HalfFramePair · Localization · CurveMath
Services/     OpenFrameSession · FrameCatalog (the app library) · import · library previews
Scheduler/    RenderQueue · MemoryBudget · MemoryProbe · CostModel · Planner · SpkEngine
Engine/       EngineRouter · EngineHost · FrameDecoder · RawProxy · OutputTransform ·
              Layer2Renderer · FullRender · FullDetail · ExportPlan · ExportWriter
FilmEdge/     the film's layout, ported from the engine (FilmLayout), and its canvas
LightTable/   the light table (RFC-045)
DesignSystem/ Theme, the shared parts, the interface scale, the app's own icons
Diagnostics/  the log and the memory records
```

### 7.1 The window

Capture One's arrangement in SpektraLab's language (`design/MAC-LIBRARY-UI.md` §8): one window, a
left column whose mode row reads **Library · Develop · Edit**, the picture at the centre, and a browser
of the current collection shared by every mode. The Light Table, Import, Export and Settings are
full-window pages. Which part of the column a control is in says what moving it costs:

| change | costs |
|---|---|
| Develop: film, paper (or the Digital Intermediate), Film Exposure, effects, film edge, date back, the Decode curve | the engine: a reprint from the session's negative if the field is `print`-side, a develop if `shoot`-side (§8.5); a film-side drag develops when it rests or ends |
| Develop: white balance, lens correction | a re-decode (Core Image), then a develop |
| Develop's crop, straighten, turns, flips | the engine's cut: geometry is applied when the frame is read, before the meter (`ENGINE-WIRING.md` §4.3); under a film edge the host cuts instead (§7.11) |
| Edit: Brightness, Contrast, Tone, HSL, Channels, Colour Wheels, Vibrance, Saturation, Temperature, Curve, Vignette (the clipboard's Light, Curve and Colour groups) | Layer 2: one GPU pass over the developed picture, no job (§7.2) |
| Edit's crop | a crop of the finished picture, after the print (`FrameEdit.printCrop`) |
| *Apply Film Emulation* off | Apple's own decode, cut by the crop, with Edit on top: no film, no paper, no session |

- **The enlarger and Scene Placement have no controls on the Mac**: the Decode curve took Scene
  Placement's place, and a frame keeps the values it already had (Reset clears them).
- **There is no live render.** A control's number follows the pointer; a render is a scheduled job
  (RFC-036 §4, `Services/OpenFrameSession.swift`). Print-side edits are coalesced reprints; film-side
  edits develop when the drag rests or ends.
- **Film Format is not metadata.** Format, side and length become the frame's long edge in mm, and the
  engine divides its µm quantities by it.
- **Two crops.** Develop's crop is the negative's (the engine's cut, before the film); Edit's is the
  finished picture's. They are different questions and are kept apart.

### 7.2 The two layers

| | Layer 1 | Layer 2 |
|---|---|---|
| what | film, paper, camera decode, enlarger, placement, effects, the film edge | Edit's Light, Curve and Colour |
| where | the **engine**, a job on `RenderQueue` | a pointwise **Metal pass in the app** (`Engine/Layer2Renderer.swift`, `Layer2Kernel.swift`) |
| cost | a reprint or a develop | follows the pointer |

A Layer 1 edit sends a `params_delta` and waits for pixels; a Layer 2 edit never leaves the app. The
page's picture, a tile's copy, an export and the zoom run the same Layer 2 functions, and
`tools/layer2_selftest.swift` runs the kernels on the Mac's GPU against a reference. Layer 2 follows
the print and never reaches back into the film or the paper (`AGENTS.md`, "Do not pollute the
material model").

`FilmParams.wire` (`Model/FilmParams.swift`) is the one place Layer 1 field names live, in a stable
order; `AppServices.checkWire` holds them against the engine's `spk_params_schema` at every launch,
so a name the engine does not know is reported rather than sent (`ENGINE-WIRING.md` §2, §4.2).

### 7.3 Resolution: the preview size, and full when it is asked for

- **Preview.** Every frame is developed at the preview size Settings › Develop sets, for the library,
  the browser and the develop page. The develop is kept, named by its stamp (§4, §7.6).
- **Full.** A render at the frame's own pixels is a job of its own (`fullView`), made when the develop
  page is zoomed past the preview (`FullDetail`), by the Light Table, or by an export at Full, and
  kept as tiles (§4). The zoom reads only the tiles the screen touches, from the half size at half or
  less, through the same output transform and Layer 2.
- **`full` is never a reduced size.** A full-tier job decodes the original at its own size; a job
  below it says what size it is (§6.2).

### 7.4 What the app does not do

- **No live render** (§7.1), and no picture that claims to be more than it is (§6.2).
- **No grade after the print beyond Layer 2.** The product edits the physical process; retouching
  belongs to other software.
- **No writes beside the photograph.** The person's folders are written only where Export is told to
  write (§7.6).
- **No write to Capture One.** A Capture One catalog is read through a snapshot and never written; no
  rating, label, album, trash flag or file goes back (§7.13).
- **No masks.** The 1.x masks (§A.4) are not in the Mac app. Its CLI and MCP front doors (§A.9) came
  back in another shape: clients of the running app, over the library (§7.16).

### 7.5 The colour chain, end to end

RFC-018. One working space, exactly one conversion out of it per destination.

| # | stage | space |
|---|---|---|
| 1 | decode (`FrameDecoder`, Core Image; a RAW with a linear look) | scene-linear float32, ProPhoto RGB, in a buffer of the engine's device |
| 2 | engine ingest | `spk_open_device`, no decode in the engine |
| 3 | engine interior | **no RGB space**: spectra → log exposure → density → print density → scan |
| 4 | gamut compression | CAM16-UCS into ProPhoto RGB |
| 5 | engine output | **ProPhoto RGB, CCTF encoded**: the working space, never sent as a setting |
| 6a | a page | `OutputTransform` to Display P3, 16 bits, with Layer 2 inside the same pass |
| 6b | a file | `OutputTransform` to the recipe's space (sRGB, Display P3, Adobe RGB, ProPhoto RGB) at its own depth: 8 bits written by the kernel for JPEG, HEIF and PNG, 16 for TIFF |

- **One conversion a destination** (`Engine/OutputTransform.swift`): the engine's own numbers
  (`spk_output_transform`): the working space's curve off, a chromatically adapted 3 × 3, CAM16-UCS
  gamut compression into the target, the target's curve on. The kernel is compiled at run time from
  source with safe math, since no `.metal` file may be in the app's target. Its lightness stage is left
  off: the engine ran it before encoding the working space, and a second pass compressed an export's
  highlights (`ENGINE-WIRING.md` §6.1).
- **The decode's Core Image working space has sRGB's primaries** (extended, linear, half floats): RAW 9
  decoded Bayer files in the wrong colour with any other (`ENGINE-WIRING.md` §3.1).
- **Whatever goes in, ProPhoto comes out**, so every other space is a compression of the output, which
  is why the gamut mapping belongs to the output transform.
- **The Digital Intermediate** (2.2.1): with `digital_intermediate` on, the engine writes Cineon log
  (ProPhoto primaries) in the paper's place. `CineonView` reads it through 1.x's DI view
  (`Resources/DIView-Cineon-to-ProPhoto.cube`, 65³, trilinear in float32) in `SpkEngine`, before
  delivery, so everything downstream sees the working space. The Paper strip's last card chooses it
  and keeps the paper underneath (`StockPreviewCard.digitalIntermediate`).
- **Canvas Colour Space** (2.2.1, Develop's "···" menu, `CanvasGamut`): the page's Display P3 picture
  shown as an sRGB or Adobe RGB file holds it: the engine's own transform from Display P3 into that
  space, run by the output transform's kernel (`GamutProof`), at the size the page draws. ProPhoto RGB
  and Display P3 are the picture as made. The Export page's preview uses the recipe's space the same way.

### 7.6 State: what lives where

| what | where | survives |
|---|---|---|
| the sources, the app library, the catalogs the app makes | `~/Library/Application Support/<bundle id>/` (`MAC-LIBRARY-DATA.md` §3); the debug build's bundle id is `com.spektralab.mac.local` | everything |
| a frame's edit (`FrameEdit`: the wire's settings, the decode, both crops, Edit's layer, the film edge, a pair's look) | its library: the app library (`library.json`) or the catalog it belongs to, through `spklib-host` | everything; on-disk and wire names are pinned (`tools/persisted_names.py`), and a 2.1.4 library is read and written back the same (`tools/persisted_check.swift`) |
| a half-frame pair | `Pairs/<name>.spektrapair`, and a row of kind `pair` in its library (§7.12) | everything |
| a SpektraLab catalog or session the person made | where the person put it (`<Name>.spkcatalog`, `<Name>/<Name>.spksession`) | everything |
| a frame's develop, a RAW's preview decode, full renders | the caches (§4); a catalog's develops in its `Cache/Previews` | until evicted; deleting them costs time, never work |
| settings | `UserDefaults` of the bundle id | everything |
| the log | `~/Library/Application Support/<bundle id>/Logs`, 7 days, on this Mac; it leaves only when the person exports it | its 7 days |

- **Nothing is written beside the photograph** (trap 35). A test opens a **copy** of a fixture: a
  develop writes the frame's edit and changes the exposure meter's input.
- **What a picture claims.** A page shows what is kept; a picture that is not the print wears a label
  (`TagPill`), and no reduced picture passes for the real one (§6.2).

### 7.7 Surfaces that show the frame

Every surface that shows a frame shows the develop's picture as the page shows it.

| surface | shows | from |
|---|---|---|
| the develop page's picture | the develop, with Edit's layer | the kept develop at the preview size; `FullDetail`'s tiles when zoomed past it |
| the browser, the library grid | the kept develop | `DevelopedPicture`, drawn at the size it is shown; never developed again to draw a tile |
| histogram | the picture as shown: R, G, B and luma, 256 bins | Layer 2's own histogram pass (`spkLayer2Histogram`) |
| Light Table | the films at their true size | the kept develops, and full renders for a 1:1 read |
| an exported file | the recipe's size and space | the same output transform and Layer 2 (§7.8) |
| the Export page's preview | the develop in the recipe's colour space | the kept develop, proofed (`GamutProof`, §7.5) |

The 1.x app's `SurfaceAgreementTests` (trap 33, §A.7) have no counterpart in the Mac app yet: a
surface that shows the frame is checked by the drive harnesses and by looking at the running window
(§9).

### 7.8 Export

- **A recipe** is format, depth, colour space, size, naming and folder; saved recipes are kept and
  edited in Settings (`MacSettingsRecipes`). The size a recipe names is made in the decode, at a long edge whose sides are both
  whole and even, and the cut is the host's, with the film's millimetres carried down, so a cropped
  frame keeps the grain and halation scale the develop page showed (`ENGINE-WIRING.md` §4.3).
- **One job a picture** (`ExportService`, batched by `MacExportRun` on the Export page): priced,
  queued and run like any other job; one full render's peak, not N.
- **A kept full render is reused.** An export whose engine side is a kept full render's (same file,
  decode, cut, wire and engine) is delivered from it in any space and container, and the engine is not
  run (`FrameSource.cached`).
- **Files land whole.** `ExportWriter` writes to a hidden `.<name>.partial-*` beside the destination,
  reads it back, and moves it into place, so a crash never leaves a truncated file.

### 7.9 Sizes: the largest frame, and the size a picture says

There is no cap on what is offered: every export size is offered (the owner, 2026-10-20). A frame
larger than a job's memory allows is not refused; it is decoded smaller and labelled with the size it
was developed at (`DevicePolicy`, §6.2). Settings › Diagnostics › This build shows the budget a job
would be given now, and which of the machine's headroom and the app's own allowance binds.

### 7.10 Keys

- **Capture One's default keys** (`Mac/MacShortcuts.swift`), with the approved Mac conflicts
  resolved. The binding list owns keys; pages own actions (`MacShortcutButton(.crop) { … }`). The
  responder chain and the menu read the same registrations, and a registration belongs to a view, so
  an outgoing page cannot unregister its replacement's key.
- **Catalyst drops a plain key** given to `keyboardShortcut` without a modifier, and a tapped text
  field never resigns. A plain key is therefore the window's own command (`MacKeyAnchor`), and a
  focused field keeps its typing keys.

### 7.11 Film Edge and Date Back (RFC-032, RFC-031)

- **The engine draws the film.** The rebate, the holes, the edge print and the date are exposure on the
  negative, and the picture the engine hands back is the film's canvas, larger than the picture
  (API-SPEC §15). `FilmWire` sends `overscan_*` and `date_imprint_*` in the model's own words.
- **With a film edge the host cuts the picture, not the engine** (`FrameEdit.hostCut`, made in
  `FrameDecoder`), and the wire's own cut is none: the engine sets the film's millimetres from the frame
  it is handed. A film turned half round is the host's doing too, by whole quarter turns, with no
  resampling (`ENGINE-WIRING.md` §4.4).
- **A page never decides where anything on a film is.** It asks for the film's geometry
  (`AppServices.filmEdge(for:edit:)`) and draws it with `FilmCanvasView`, as a guide over the
  undeveloped picture or where the develop belongs. `tools/film_edge_parity.py` holds the app's port of
  the engine's layout (`FilmLayout`) against the engine's render, case by case (`PAGES.md` §6).
- **Formats** are the engine's table (`overscan.cpp` `kFormats`, §8.10); a format a stock was never made
  in, or a date face a camera never printed, is shown and cannot be chosen, and the page says why. The
  edge's words are `Stock.edgeText`, never a marketing name.

### 7.12 The half-frame pair

- **To the engine a pair is one frame.** The host composes both pictures onto one piece of film and
  hands the engine that buffer. The engine is told four things a frame is not: the piece's millimetres,
  that its meter is off (each picture's exposure is already in its pixels), that a film edge carries
  two exposures (`overscan_pair`), and where the second frame begins (`scene_latitude_split`)
  (`PAIR-WIRING.md` §1).
- **A pair is a library item and a row.** One `LibraryFrame` whose edit is the pair's look and which
  carries the `HalfFramePair`; on the Mac also a row of kind `pair` in the library it was made in,
  pointing at `Pairs/<name>.spektrapair` (spklib 0.3.1, `MAC-LIBRARY-DATA.md` §2i). A pair never owns
  a frame: removing a frame leaves its hole *Missing* and the export refused.
- **The shot stays the frame's.** Each hole's decode and geometry are read again from its frame every
  time the pair is opened or developed (`HalfFramePair.mirror`).
- **A frame's own print** (`PAIR-WIRING.md` §12): one negative printed up to three times and cut
  together, while a frame prints or grades for itself.

### 7.13 The library

- **Sources, one row each** (`MAC-LIBRARY-DATA.md` §1): the app library, SpektraLab catalogs and
  sessions, Capture One catalogs and sessions read one way, and folders linked from Finder. Each has a
  collection tree laid out like Capture One's Library tool, and rows loaded a page at a time.
- **The helper owns the database.** `CatalogSourcesStore` (`Mac/Library/`) is the one
  `@Observable @MainActor` store over `spklib-host`; it starts no process and reads no file until a view
  calls `start()`. The helper's methods and their guarantees are `API-SPEC-library-helper.md` and the
  SDK's own `API-SPEC.md`.
- **Capture One, one way.** The helper copies `<Name>.cocatalogdb` to a temporary place, checks the
  copy, and reads only the copy; it refuses while Capture One holds a hot journal. What SpektraLab keeps
  about those pictures is kept in a mirror, `Libraries/Linked/<document UUID>.spkcatalog`.
- **A linked folder's files are never moved, renamed or deleted;** `folders.sync` writes rows only.
- **Previews are the library's** (`MAC-LIBRARY-DATA.md` §2j): a catalog's develops live in its own
  `Cache/Previews`, so a catalog carries its previews with it.

### 7.14 The Light Table

RFC-045: the website's light table (`spektralab.app/lighttable`) ported to the app, an A4 light pad
seen straight down, measured in millimetres, with the library's frames lying on it at their true size.
`LightTableModel.swift` is the website's arithmetic ported statement for statement, so a film put down
in the app lies where the website would put it. Its full-size reads are full renders, shared with the
develop page (`FullRenderJobs`: made once, whoever asks).

### 7.15 Languages

English, 简体中文, 繁體中文 and 日本語 (`LOCALIZATION.md`). Every sentence a page shows goes through
`L("…")`; Settings › General › Language is the one setting, with no "follow the system", and the
first launch takes the system's preferred languages once. `tools/localization_check.py` holds every
sentence in four languages, in the right script, looked up where it is shown. A film's or a paper's
name is the catalogue's (`Stock.name`), never a profile id.

### 7.16 Agents: the command line and MCP

```
SpektraLab                        the app
SpektraLab cli <tool> '{json}'    one tool call, one JSON object out; exit 0 done, 1 failed, 2 refused
SpektraLab cli tools | help       the table, with each tool's JSON input schema
SpektraLab mcp                    a Model Context Protocol server, newline-delimited JSON-RPC 2.0 on stdio
```

- **Through the running app.** The executable's entry (`SpektraLabMain`) sends `cli` and `mcp` to
  `AgentClient` before UIKit is touched; both are clients. The app listens on a Unix domain socket
  from launch (`AgentServer`) and runs each call on its main actor against its own state
  (`AgentExecutor`: `macLibrary`, `AppServices.change`, `MacExportRun`), one call at a time, app-wide.
  A catalog's database is held by the app's own `spklib-host`, so no second process ever opens one.
  When nothing answers, the client opens the app hidden (`open -g -j`, by `posix_spawn`) and waits up
  to 30 s for its socket.
- **The socket** is `NSTemporaryDirectory()/spektralab-<bundle id>.sock` (a test's `CFFIXED_USER_HOME`
  adds a hash of that home, and the launch passes the home on with `open --env`), mode 0600 in the
  user's own temporary folder, so a Debug build and a release never answer each other's agents. A stale
  file is removed at start unless something answers on it. Newline-delimited JSON both ways:
  `{"id", "tool", "arguments"}` in, `{"id", "ok": true, "result"}` or `{"id", "ok": false, "refused",
  "error"}` out.
- **Access is off by default** (`AppSettings.agentAccess`, Settings › General › Agents) and read at
  every call: off, every tool is refused, the listings included. While an export batch runs, the tools
  that change a frame or make files from one are refused (`AgentTool.touchesFrames`).
- **`AgentTools` is the one table**: a name, a one-line summary, a JSON Schema; a call is held to it
  whole in the client and again in the app, and what needs the library (the pictures, the film and the
  paper) is checked before the first change. `list_sources`, `open_source`, `create_catalog`,
  `create_session`, `list_collections`, `list_images`, `import_images`, `trash_images`,
  `restore_images`, `set_rating`, `set_color_label`, `list_recipes`, `export_images`, `list_stocks`,
  `get_develop`, `set_develop`. A picture is `"<source id>/<image id>"`. A listing selects what it
  lists in the window. A film is loaded and a paper printed on as the strips do (`PAGES.md` §4 rules
  8–9). No Light Table tools.
- **Deletion is the catalog's Trash only.** `trash_images` and `restore_images` are `setTrashed`: no
  file moves. No tool moves a file to the system's Trash, empties a Trash, or removes a file or a
  source; a Capture One source takes ratings and labels only (§7.13).
- `tools/agent_selftest.swift` holds the table, the socket end to end over a stand-in app, and MCP's
  framing, without the app.

### 7.17 Updates

- **One manifest, at an address the build sets.** `UpdateCheck` reads a small JSON file (version,
  build, download url, notes, sha256) from `Info.plist`'s `SPKUpdateFeedURL`, which `gen_project.py
  --update-feed` writes (https://spektralab.app/updates/mac.json by default, published with the
  website). Moving the manifest or the DMG to another host or CDN never needs a code change.
- **Newer** is the version compared number by number, or the same version with a later build.
- **The app never downloads or installs**: it says a newer version is out and opens the manifest's link.
- **At launch**, once, five seconds after a plain launch, while Settings › General › Updates' *Check
  for updates automatically* is on (the default). A plain GET; nothing about the person is sent.
- `tools/update_selftest.swift` holds the comparison and the manifest's rules.

---

## 8. The native engine: the SpektraLab engine

The SpektraLab engine is a C++/Metal implementation derived from spektrafilm by Andrea Volpato
(GPL-3.0-or-later). RFC-014, implemented 2026-09-10. Read `rfc/RFC-014-native-cpp-engine.md` §8
before changing any of this.

### 8.1 Layout

```
engine/include/spektralab/spk_engine.h    the whole C ABI
engine/src/core/        setup maths — no GPU, no pixels, testable alone
engine/src/gpu/         gpu.hpp (the interface) + the Metal backend
engine/src/shaders/     the kernels; built by build.sh, not Xcode
engine/src/pipeline/    pipeline · scene_latitude · contrast_mask · blur · engine (the C ABI)
engine/tools/           bake_resources.py
engine/tests/           seven parity harnesses, three C++ drivers, the math guard
engine/build.sh         lib | dylib | metallib | tests | bundle | all
```

The Mac app links the engine as a static library: `app/SpektraLab/tools/build_engine_mac.sh` compiles
every `engine/src/{core,gpu,pipeline}/*.cpp` for both Catalyst architectures into
`libspektralab_engine.a`, so a new file there is picked up by running it again, and a stale library
is a link error (`ENGINE-WIRING.md` §1).

### 8.2 The C ABI

1. **Nothing throws.** Every entry point is `noexcept`; failure is a negative
   `spk_status` plus `spk_last_error`.
2. **Ownership never crosses**, with one exception: `spk_result.texture` is
   returned **+1**, because the app caches textures and a texture the engine
   reused would silently become a different photograph. Swift takes it with
   `takeRetainedValue()`.
3. **Parameters are JSON** — except `spk_print_lut_table`, which hands out an
   engine-owned pointer to 431 kB of float32 for the `.cube` writer.

A C ABI rather than Swift's C++ interop: ABI-stable, narrow, and callable from
`ctypes`, which is what lets the parity harnesses drive the **shipping binary**.

### 8.3 The GPU layer

Five verbs — alloc/upload, dispatch, flush, read, texture — and nothing above
`gpu.hpp` names Metal.

**Buffer lifetime is the part to understand first.** A pooled buffer
(`gpu::BufferRef`) is handed out again only when **free** (last handle dropped)
and **idle** (its last command buffer completed). The first version checked
only the first: 25 of 27 render-parity cases wrong, no crash, no error.
Reclaiming only at frame end instead cost 6.4 s and 3.2 GB at 24 MP against
0.4 s — which looks exactly like a CPU fallback and is not one.

### 8.4 The kernels

MSL, compiled by `engine/build.sh` into `spektralab.metallib`, **not** by
Xcode: the app sets `MTL_FAST_MATH = YES` for its canvas, and inheriting it
drifts `exp` and fma contraction past the float32 bar, silently.
`spk_math_probe` computes `a*b - a*b` — exactly 0 under fast math — and
`spk_engine_create` refuses to start if it is; `check_math_guard.sh` proves the
guard can fire.

The Mac build also bakes `spektralab.metalar`, native pipeline code for the
build host, beside the portable `.metallib`. Each pipeline first requests an
exact archive hit; missing, corrupt, incompatible or stale entries fall back to
normal Metal compilation. There is no runtime archive writer or growing disk
cache. The archive and the finite pipeline map belong to the engine and are
released with it. Metal command objects have explicit ownership and local
autorelease pools; a scheduler thread need not provide a Cocoa run loop for
cleanup. The engine releases its retained reference to a caller-supplied
`MTLDevice` as well as a device it created. Safe math is checked on both paths.
This improves shader-cache
misses; it is not a promise of a large gain with Metal's driver cache already warm.

DIR subtraction and curve interpolation share one kernel on Metal. XYZ-to-RGB
and CAM16 compression share another, retaining the intermediate float32
operations (the matrices are not composed). The shared CAM16 shader body keeps
the standalone and fused entry points consistent. Vulkan keeps its existing
kernels. Completion barriers remain at stage boundaries.

### 8.5 Caches, and why a slider is fast

| what | why it is expensive | keyed on |
|---|---|---|
| CAM16 `C_max` table | ~830,000 CAM16 inversions | output colourspace |
| Hanatos `tc_lut` | 192×192×81 contraction + a ray-polygon remap | stock **and the sensitivity array** |
| the session's negative | the whole film side | invalidated by a `shoot`-layer edit only |

Cold CAM16 setup first reads a tracked `resources/cam16/` float64 artifact for
one of six output spaces. Its exact setup metadata, algorithm revision, file
length, checksum and finite bounds must match. A miss computes the same table,
with loop-invariant work hoisted and at most four joined workers on independent
rows. `engine/build.sh cam16` explicitly regenerates these artifacts; ordinary
builds need no Python or table bake. The immutable DI curve channels are also
prepared once per `FilmHost`, avoiding allocations for every interpolation.

The `shoot`/`print` tag on every wire field is therefore a correctness
concern: a `print` edit reuses the negative, a `shoot` edit must not. The Decode
`scene_curve` remains a `shoot` field (API-SPEC §17); these optimizations add no
wire fields. Qualification and timings are in `engine/performance/2026-10-24/README.md`.

The Mac v2 print path uses pair-qualified log-positive → paper-CMY minilab
calibration. As shipped in 2.1.1 the catalog holds exactly one pair: Kodak
Portra 400 → Kodak Professional Portra Endura. A new frame starts on that pair
(`AppSettings.lastPaper` is `kodak_portra_endura`; `FilmParams.init()`'s
`kodak_supra_endura` is only the seed a `FrameEdit` carries before the
new-frame pair is applied), so the default rendering is the calibrated one.
Every other film, and every other paper under Portra 400, keeps optical
printing. The 2.1.0 test build carried 97
of 136 colour pairs from the 2026-10-25 campaign; the owner withdrew 96 of them
on 2026-10-26 after looking at the build, so the catalog is now the first pair
the campaign promoted and the rest are archived outside the repository —
`engine/minilab-coverage/WITHDRAWN-2026-10-26.md` records the decision, and
`COVERAGE.md` is the campaign's ledger rather than a description of what ships.
Its spectral recovery, curve reversal and trilinear lookup are fused without
changing float32 arithmetic. One immutable table is retained per pipeline;
missing or changed qualified resources are errors. Other pairs keep optical
printing. API-SPEC §18 records the control semantics and the separate factory
exposure model.

The pre-grain disk checkpoint is one anonymous process-wide file, capped at
1 GiB, written without filesystem caching after the first grain edit only.
Measured write/read cost gates reuse. It holds float32 CMY plus frame/AE state;
source session identity, all upstream wire values, tier and dimensions pin its
meaning. Every non-grain edit invalidates conservatively. A failed read/write
reruns the prefix; session destruction closes its slot. No checkpoint GPU plane
survives a render. Factory exposure and the DIR log-exposure plane are released
after their last consumers. The existing scheduler still serializes images.

### 8.6 Parity: what is measured

All seven harnesses drive the shipping binary through `spk_ctypes.py` against
the upstream Python oracle.

| harness | holds | result |
|---|---|---|
| `parity_setup.py` | 227 setup quantities | 0 failed, 86 bit-exact |
| `parity_schema.py` | wire schema + digested params, 6 stock pairs | identical (one recorded `KNOWN`) |
| `parity_render.py` | 27 configurations, 1 MP | 0 failed, max 2.3e-5 |
| `parity_session.py` | every wire field on a *live* session | 0 failed |
| `parity_grain.py` | grain mean/std/skew at 9 densities | 0 failed |
| `parity_exposure.py` | the meter's four modes | — |
| `parity_lut.py` | 8 print tables, LUT apply, DI normalisation | tables bit-exact, max 8.0e-6 |

The render bar is **measured**: 3e-5 absolute, because the validated Python
Metal core itself reaches 1.9e-5 on the same frame. Do not tighten it to
float32 epsilon; do not loosen it without saying what you measured.
`parity_session.py` exists because a fresh session per case never took the
user's path — open once, move sliders — and that gap hid a bug that broke
twelve print-layer fields. `build.sh dylib` does not rebuild the C++ drivers:
rebuild them, or three harnesses grade a stale engine green.

### 8.7 Speed and size, measured

45 MP, warm, M3 Max:

| tier | first | reprint | LUT flip |
|---|---|---|---|
| live 1600 px | 0.13 s | 0.01 s | 2.0 ms |
| preview 3400 px | 0.25 s | 0.04 s | 9.5 ms |
| full 7800×5800 | 0.87 s | 0.17 s | 47 ms |

Opening a 24 MP RAW is ~2.0 s, ~1.6 s of it Core Image.

**The 2.2.0 app is 68 MB** (measured on the released DMG's app): the executable 27.8 MB (app and
engine, arm64 and x86_64), `EngineResources/` 24.8 MB (6.1 MB of profiles, 6.3 MB of minilab tables,
the 0.2 MB metallib and its 0.9 MB archive, and the baked constants), `Assets.car` 12.0 MB (the Icon
Composer icon's layers), and `spklib-host` 2.0 MB. Everything else is a system framework.

### 8.8 Export methods

| method | the engine does | the Mac app does |
|---|---|---|
| a render (`spk_render`, `spk_reprint`) at the job's tier | the print, in the working space | the output transform, Layer 2 and the file (ImageIO, §7.8) |
| `preview_stock_lut` | the negative through the trilinear kernel | not called by the Mac app |
| `export_di` | the negative normalised by the LUT's axes, and the table | not called by the Mac app (1.x's Digital Intermediate export, §A.8) |

**No file writer in the engine**, by design: ImageIO already writes the formats and owns the colour
tagging. The DI TIFF the engine can make is **device RGB, not a colour**: its channels are film
densities the `.cube` indexes, and it carries no profile.

### 8.9 Node timings measure encode time unless you ask

Dispatches batch into one command buffer, so a timer around a node measures
*encoding*. `progress.node_times` is empty unless `SPEKTRALAB_NODE_TIMINGS=1`,
which flushes per node. An empty field is honest; a plausible wrong number is
not.

### 8.10 The film edge, and what a unit of the filters is

- **`overscan.cpp` + `shaders/overscan.metal`** hold the formats, the layout
  (`OverscanLayout`), the CPU raster of the edge print and the kernel's
  parameter block (`P_*`, mirrored in both files). `spk_overscan_geometry`
  returns where the gates are, normalised, so the app never guesses. A hole's
  edge has the softness a scan shows (σ 17 µm plus the pixel).
- **Native-only wire fields** go immediately before `preview_long_edge`, in
  `params.cpp` **and** `tests/parity_schema.py` in the same order, and their
  API-SPEC section is edited in the same commit (§13 the film edge and date,
  §14 the filters).
- **`filter_shift_scale`.** The oracle's `y_filter_shift` / `m_filter_shift`
  are −1…1, added to a pack in CC units (neutral ≈ 55 / 65): one CC end to
  end, 0.014 stop, invisible. The scale says what a unit is; default 1 is the
  reference, the app sends 40. A control that is wired is not thereby visible:
  its *end* is measured against the neutral (`EnlargerFilterTests`).

---

## 9. Verification

```
app/SpektraLab/tools/selftest.sh   the app's self-tests, no Xcode project: the scheduler, the Latitude card and
                                    the placement solve, the host's cut, an export's arithmetic and recipes,
                                    the develop page's panels, a pair's arithmetic and cut, the film-edge flow,
                                    Develop's strips, storage, Supporters, the log, the language and every
                                    sentence, Layer 2's kernels on this Mac's GPU, the persisted 2.1.4 formats
                                    (~320 s on this Mac)
app/SpektraLab/tools/film_edge_parity.py --engine engine   the app's film layout against the engine's render
the drive harnesses                 --library-check, --import-check, --export-check, --render-check,
                                    --settings-check, --lighttable-check, --catalog-check, --clipboard-check,
                                    --drop-check, --mac-drive: the real window driven from a launch argument,
                                    writing a report
app/SpektraLab/tools/snapshot.sh    every page drawn offscreen, in any of the four languages
engine/tests/                       the parity harnesses (§8.6), gpu_smoke, check_math_guard.sh
CI (.github/workflows/build.yml)    a clean checkout builds: Debug, Mac Catalyst, Xcode 27
```

- **Read the duration, not the failure count.** A full self-test run takes minutes; a run that skipped
  its fixture cases also reports 0 failures (trap 26).
- **Build Release as well as Debug** before calling a change done: a release path that reaches code
  under `#if DEBUG` compiles in Debug and fails in Release.
- **A guard must be seen to fire.** New regression tests are shown red on the old behaviour first;
  harness-level checks carry a control that reproduces the bug without the fix
  (`film_edge_parity.py --self-test`: 9 broken layouts, 9 caught; `check_math_guard.sh`).
- **An offscreen snapshot is not the window.** It cannot see a Metal layer, a stall or the window's own
  chrome; the drive harnesses and `--capture-window` capture the real window. A report with 0 failures
  that a person has not clicked through is said to be so.
- **A green unit is not a correct surface** (trap 33). The Mac app has no surface-agreement suite yet
  (§7.7); look at the running app.
- **Engine parity** runs only when engine inputs, kernels, resources or the render boundary changed
  (`docs/agents/BUILD-AND-TEST.md`).

---

## Appendix A. The 1.x app (`modern_UI/Spektrafilm`), history

The 1.x app was SwiftUI and AppKit with a Metal canvas, one arm64 binary of 32 MB. Its sources are no
longer in this tree (they are on the branch `main_v1` of the public repository). It is kept here
because the Windows and Linux port (`desktop/`) and some engine comments were written against it and
cite its sections as §7.1–§7.13: read them as §A.1–§A.13. The rules it established (one colour chain,
every surface shows the canvas's frame, export develops again from the original, files land whole)
carry over to the Mac app (§7).

SwiftUI for panels, AppKit for windows and keys, Metal for the canvas.

```
Model/        Session · Params (Layer 1, the wire) · Adjustments (Layer 2) ·
              Geometry · Sidecar · StockCatalog · Latitude · ToneMask
Import/       Library · ImageDecoder (Core Image) · FramePipeline · ThumbnailCache
Canvas/       Renderer · Shaders.metal (layer2 · geometryResample · histogram ·
              canvasFragment) · ColourManagement · overlays
Service/      EngineClient (§8) · RenderScheduler (sent-vs-wanted coalescing) ·
              EngineMessage (engine errors in words a user can act on)
Export/       ExportPage · ExportRecipe · Exporter · SoftProof
Agent/        AgentTools (the one tool table) · AgentWorkspace · AgentCLI · MCPServer
Panels/ Controls/ Windows/ Theme/   the interface, drawn to the v4 layout
Localization/ English · 简体中文 (enum display names stay English; tests pin them)
Diagnostics/  Log · JobLog · MemoryArena · MemorySampler · DiskCacheStore
```

### A.1 The window (v4, 2026-09-26)

Three regions and a filmstrip. Which rail a control is on says what moving it
costs.

| region | sections | runs in |
|---|---|---|
| **Film and Print** (left) | Navigator · Half-Frame Pair (on a pair) · Settings Clipboard · Film · Film Edge · Date Back · Print · Crop · Enlarger | the engine; Crop is geometry (below) — except under a film edge, where it is the negative (§A.11) |
| **Parameters ▸ Pre-Dev** (right) | Latitude · Input / Camera · Film Format · Scene Placement | the engine, except Camera's white balance and lens correction, which are the **decode**. On a pair these are the picked frame's (§A.12) |
| **Parameters ▸ Post-Dev** (right) | White Balance · Exposure · Curve · Color Balance | **Layer 2**, one draw |
| canvas, top right | histogram · tier badges | reads, never writes |
| filmstrip | one cell per frame | — |

Costs, precisely:

| change | costs |
|---|---|
| Camera Temperature · Tint · Lens Correction | a re-decode (`CIRAWFilter`), then a render |
| anything else on Film and Print or Pre-Dev | a `params_delta` and a render |
| Post-Dev | one draw |
| Crop · Straighten · turns · flips | one draw — geometry sits **after** the engine; `Exporter` applies it to the returned print |
| Original (⎵ held) | one draw — shows the decode instead of the print |

- **Film Format is not metadata.** Format, side and length become one number
  — the frame's long edge in mm — and the engine divides its µm quantities by
  it. Call the same photograph 35 mm and its grain is coarser, correctly.
  Cropping does not change it unless `recalculateEffectsAfterCrop` is on.
- **Three white balances, three stages.** Camera's is the decode's (kelvin);
  Post-Dev's is Layer 2's, on the scan; the enlarger's filter pack is what
  **Solve** solves. Two stages never share a name.
- **Latitude** reads the scene histogram *after* Scene Placement's curve
  (`spk_scene_latitude`'s `placed_fractions`) and says why when it cannot
  measure, rather than going blank.
- **The interface scales** (`ui2.interfaceScale`); label columns scale with
  the type.

### A.2 The two layers

| | Layer 1 | Layer 2 |
|---|---|---|
| what | film, paper, camera, enlarger, placement, mask | exposure, curves, colour balance, WB on the scan |
| where | the **engine** | a **Metal kernel in the app** |
| cost | ~14 ms at the 2560 default, ~0.12 s native | sub-millisecond |

A Layer 1 edit sends a `params_delta` and waits for pixels; a Layer 2 edit
never leaves the app. Putting a control on the wrong side is the difference
between a slider that tracks the mouse and one that does not.

`FilmParams.wire` is the one place Layer 1 field names live, each tagged
`shoot` or `print`. `ParamsTests.testWireNamesMatchTheServiceSchema` and
`parity_schema.py` pin them: **a rename fails a test instead of silently
rejecting every delta.**

### A.3 Resolution: two states, not a ladder

- **Preview:** every interactive edit renders at the preview long edge — 3840,
  2560 (default), 1920 or 1080 — the engine's `live` tier.
- **Original:** a render at the frame's own pixels, started 400 ms after the
  edit stops and shown when it lands. One alive at a time.
- **Zoom selects neither** (2026-09-12). The canvas is soft above the preview
  edge until the original lands — the `preview` badge — and `full` means the
  frame is on the canvas at its own size, at any zoom.

45 MP, grain and glare off: a live reprint is 6.2 ms at 1600, 13.7 ms at 2560,
121.7 ms at 8192.

### A.4 What the app does not do

- **No display transform.** The canvas layer is tagged ProPhoto RGB and
  ColorSync converts for the display (§A.5).
- **No post-print editing beyond Layer 2.** The product edits the physical
  process; retouching belongs to other software.
- **No masks, for now.** Built, withdrawn behind `FeatureFlags.masks = false`
  pending a redesign; the flag also stops sidecar masks reaching the kernel.

### A.5 The colour chain, end to end

RFC-018. One working space, exactly one conversion per destination.

| # | stage | space |
|---|---|---|
| 1 | RAW decode (Core Image) | linear ProPhoto float32 |
| 2 | engine ingest | `io.input_color_space = "ProPhoto RGB"`, no decode |
| 3 | engine interior | **no RGB space** — spectra → log exposure → density → print density → scan |
| 4 | gamut compression | CAM16-UCS into ProPhoto RGB |
| 5 | engine output | **ProPhoto RGB, CCTF encoded** — the working space |
| 6 | Layer 2, curves, geometry | ProPhoto RGB encoded |
| 7a | canvas | layer tagged ProPhoto RGB; **ColorSync** converts to the display |
| 7b | export | one output transform: CAM16 into the recipe's gamut, then its TRC; tagged, written, **no Core Graphics conversion** |
| 7c | soft proof | the same transform, at the file's own resolution |

- **No RGB working space inside the engine.** ProPhoto is the ingest and output
  colorimetry, not an intermediate.
- **Whatever goes in, ProPhoto comes out**, so every other space is a
  compression of the output — which is why the gamut mapping belongs to the
  export, not the display.
- **The app reads the resolved output space** from the `open` reply
  (`Session.workingSpaceName`) and never assumes it (`AGENTS.md` trap 28).
- **The one trade:** the canvas clips out-of-display colour (ColorSync, matrix
  profile) where the export rolls it off — 0.0012 % of a neutral frame. The
  file is the thing that does not move.
- **The TIFF default is Display P3**, which costs ~11 % chroma irreversibly
  before grading starts. Choose ProPhoto in the recipe for a file you will
  grade further.

### A.6 State: what lives where

| what | where | survives |
|---|---|---|
| a frame's edits (params, adjustments, geometry, state) | one sidecar per frame in `~/Library/Application Support/SpektraLab/Sidecars/`, named `<file>-<sha256(path)[:16]>.spektra.json`; a moved or renamed file is recognised by a stored fingerprint. Old sidecars beside the image are migrated there on first read | everything |
| app settings, layout, interface scale | `UserDefaults` (`ui2.*`, `diag.*`) | everything |
| decodes and finished prints | the disk cache (§4) | until evicted; deleting it costs speed, never work |
| the session log | `~/Library/Logs/SpektraLab/` (RFC-016), settable | its retention settings |
| an export's job log | `<file>.joblog.jsonl` beside it — **opt-in** since 2026-09-26 (Settings ▸ Diagnostics) | — |

Nothing is written into the photo's folder except exports. A develop writes
the sidecar and changes the exposure meter's input, so a test opens a **copy**
of a fixture, never the fixture.

### A.7 Surfaces that show the frame

Every surface that shows a frame shows the canvas's frame. This is the rule
the navigator broke while every suite was green (§A.14).

| surface | shows | from |
|---|---|---|
| canvas | the output: geometry applied at draw | `Renderer` |
| navigator | the cropped, turned frame only — it is a map of the canvas | the thumbnail through `Geometry.outputToSourceTransform` |
| filmstrip, export strip, export grid | the **whole** photograph, the outside of the crop under an 82 % mask, turned and flipped (Capture One's behaviour) | `CropMaskedThumbnail`, with `Session.thumbnailGeometry(for:)`: the live geometry for the open frame, the saved one for the rest |
| histogram | **known defect:** counts the uncropped print — `encodeHistogram` reads the Layer 2 texture before geometry | pinned by `SurfaceAgreementTests` |
| exported file, agent preview | the output, via `Exporter.filePixels` | pinned by `SurfaceAgreementTests` |

`ThumbnailCache` holds the **uncropped** print thumbnail on purpose; each
surface applies the geometry itself.

### A.8 Export

- **A recipe** is format, depth, colour space, long edge, naming and folder
  (`ExportRecipe`). The export page proves the file at its own resolution
  before it is written (soft proof, §A.5 row 7c) — measured identical to the
  file, pixel for pixel.
- **Batch is a loop, one frame at a time** (`ExportPage.run`): select →
  `ensureDeveloped` → `Exporter.export` → next. No queue, no parallelism, no
  database: one full render's peak, not N.
- **The batch holds the frame.** The exporter writes *whatever frame is open*,
  so while `Session.batchExporting` is set every person's way of changing the
  open frame or the picked set is a no-op, the editor takes no hits, and agent
  tools that touch a frame are refused. `select` itself is the run's own door.
- **Stop** cancels between frames; a frame being written is finished whole.
- **Files land whole.** `Exporter.write` finalises to a hidden
  `.<name>.partial-*` and moves it into place, so a crash never leaves a
  truncated file that a `.skip` recipe would keep as "already exists".
- **The source EXIF rides through** as a side channel; ImageIO rewrites the
  pixel dimensions to the file's own. Only typed shooting values ever make
  pixels — the date back's text and the gate's f-number (`ShootingData`,
  RFC-033, answer E10); the dictionary itself never reaches the engine.

### A.9 Agents (RFC-026)

```
SpektraLab             the window
SpektraLab cli <cmd>   one tool call, JSON out   (installed as `spektralab`)
SpektraLab mcp         a Model Context Protocol server on stdio
```

- **Parity by construction.** All three run `Session` in the same binary:
  open is `Session.open`, process is `solveNow`, export is `Exporter.export`,
  edits land in the same sidecar. There is no second implementation to drift.
- **`AgentTools` is the one table** of tools, arguments and commands; the CLI
  and MCP are two encodings of it.
- **Off by default.** Every tool is refused until Settings ▸ Agents turns
  access on, and while a batch export runs.
- A patch is validated whole before anything is applied; ranges are the
  interface's ranges.

### A.10 Keys

Capture One's single-key shortcuts (V/H/C tools, ←/→ frames, `,`/`.` zoom,
Y compare) are menu items, and AppKit offers a key to the menu **before** the
focused text field — measured: a modifier-free ← fired "next frame" from
inside a field. `TypingKeyGuard` is a local key monitor that sends typing keys
(characters, arrows, delete) straight to a focused editable text view.
⌘/⌃ combinations and Return, Enter, Esc, Tab still reach the menu.

### A.11 Film Edge and Date Back (RFC-032, RFC-031)

- **The film is the canvas.** With a film edge on, the engine is handed the
  decode **cut by the crop** and returns the whole film canvas — gate, rebate,
  holes. The crop is therefore in the negative: `FilmParams.cutsFrame`
  is the one question ("is the engine's frame cut?"), `Session.canvasGeometry`
  is the identity while the film shows, and the crop tool frames the decode
  over the film print (`filmEdgeFraming`). The date alone, under a crop, a turn
  or a flip, cuts the frame the same way.
- **Formats** are the engine's table (`overscan.cpp` `kFormats`): 135, 135
  half, XPan, 645, 6×6, 6×7, 6×8, 6×9, 6×12, 6×17. The gate's shape, the edge
  print and the frame number are per stock, measured on the owner's strips;
  the edge text is the film's own words (`Session.edgeText`), never its
  marketing name, and the engine prints no maker's name of its own.
- **A re-decode holds the film.** A white balance change, or a pair's frame
  moved, re-decodes the frame; the bare decode is another shape with no film,
  so it is not put over a film canvas a develop is about to replace
  (`Session.holdsFilmCanvas`). Without a film edge the new decode is shown at
  once, as before.
- **The print stamp carries the framing** (`Session.printStamp`), because the
  same parameters with another framing is another picture.

### A.12 The half-frame pair

- **A pair is a file**, `.spektrapair` JSON under `Sidecars/Pairs`, and its URL
  is a filmstrip `Frame`. It references two frames; it does not own them.
  Its look is an ordinary sidecar for that URL.
- **Its decode is composed** (`PairComposer.decode`): each frame decoded with
  its own white balance, framed by its own geometry, placed under its hole
  (`Hole.placement`: scale, x, y, quarter turns) on one piece — the gap black
  — no longer than one frame. Each hole is rendered once and kept, keyed on
  everything its pixels depend on; the display side is the files' embedded
  previews. One decode and one engine session, as for any frame.
- **One meter reading per hole.** The engine's meter would read both pictures
  and the gap as one scene, so each hole is metered alone and its gain applied
  to the piece (`PairComposer.exposed`; the engine's auto exposure is exactly
  a gain of 2^EV), with the engine's own meter off.
- **Per-frame print.** One negative is printed up to three times in one actor
  call (`EngineClient.renderLayers`), graded, and cut together by a Metal
  kernel (`Renderer.compositePair`). While no frame prints or grades for
  itself (`pairIsLayered`), the piece is one print and none of this runs.
  A native render is kept under a stamp that carries the frames' own prints.
- **The rails act on the picked frame** (`focusSide`): meter, Film Exposure,
  white balance and lens correction (written to the frame's own sidecar —
  the shot is the frame's in every pair and alone), Scene Placement
  (`scene_latitude_split` and the `_b_` fields), the Enlarger and Post-Dev,
  with a *Frame / + Film* scope. With the film picked, the Enlarger moves
  every frame's own print with it. A section never vanishes on a pair.
- **A crop gesture is one write.** A drag, a scroll, a pinch or a slider shows
  the frame's framed preview under the hole at once (`PairDrag`), is written
  when it rests — one undo step, one save, one develop — and stays up until
  that develop lands. The zoom holds the point under the pointer; the piece's
  size does not depend on a placement's scale.

### A.13 The library: order, selection, sync

- **Order is the folder's.** A thumbnail dragged over another takes its place
  (`Session.moveFrame`); the order is one small file per folder under
  `Sidecars/Order` (`FrameOrder`), laid over the listing on open. Frames it
  does not name stay after their neighbour.
- **One door for dropped files** (`Session.dropped(files:)`): files from
  outside are opened (one file is "edit this"); the strip's own thumbnail is
  ignored; a file of the open folder goes on the canvas with the folder still
  around it.
- **Select all and Sync** (⌘A, Settings Clipboard ▸ Sync to N) write the ticked
  groups from the current frame to the picked set through the clipboard's own
  rules; there is no batch undo.

### A.14 Verification (1.x)

```
SpektrafilmTests      the full suite — ~550 tests, ~350 s with fixtures
SpektrafilmFrontend   everything but the real-negative class — ~7 s
engine/tests/         parity harnesses (§8.6), gpu_smoke, check_math_guard.sh
```

- **Read the duration, not the failure count.** Without the camera fixtures
  (`tests/` symlink, gitignored — the right target differs per checkout) the
  suite skips 25 cases and still reports `0 failures`, in ~18 s.
- **A green unit is not a correct surface.** Each unit of the navigator was
  right and it showed the wrong picture. `SurfaceAgreementTests` puts a crop
  and a quarter turn on the frame, reads a surface, and compares it with the
  canvas; a new surface that shows the frame belongs there. Known defects are
  pinned with `XCTExpectFailure(strict: true)`, so the marker cannot outlive
  the bug.
- **A guard must be seen to fire.** New regression tests are shown red on the
  old behaviour first; harness-level tests carry a control that reproduces the
  bug without the fix (`TypingKeyGuardTests`, `check_math_guard.sh`).
- **A change is judged while it happens.** A canvas that is correct before and
  after an edit can still show the wrong thing in between (the bare decode
  over a film canvas; a zoom with no picture until its develop). Those tests
  sample the canvas *during* the change
  (`testTheFilmCanvasStaysUpWhileItsFrameIsDecodedAgain`).
- **A snapshot is of its own window.** `--snapshot` draws the canvas through an
  offscreen stand-in; the scene's window has one too and must not draw
  (`snapshotCapture`), or the capture is a blank canvas at another zoom.
  `--pair-layer` and `--pair-zoom f s` put a pair in a given state.
- **In-process tests cannot see the window.** `Tools/snapshot.sh` cannot see a
  `CAMetalLayer`; `Tools/capture-live.sh` photographs the real window and is
  the only capture that proves the canvas draws. Neither sees a stall; the
  canvas log (`SPEKTRAFILM_CANVAS_LOG=1`) does.

### A.15 Memory (1.x)

What §4 said of the 1.x app:

- **One full-resolution render at a time.** Interactive renders are at the
  preview edge; the native render runs once after edits settle (§A.3).
- **Exports run one frame at a time** (§A.8) for the same reason: two full
  renders at 100 MP do not fit.
- **The arena accounts, it does not own** (RFC-019). `Diagnostics/MemoryArena`
  registers every large holding with an evict closure against two settings:
  a reserve left for the machine and a working-set cap for the app.
- **A disk cache below RAM** (RFC-019 §8). `DiskCacheStore` keeps decodes and
  finished prints under `~/Library/Caches/com.hanze.spektralab/store/`: payload
  files in hashed folders, one SQLite index (`index.sqlite`, system
  `libsqlite3`) ranking entries GDSF-style by recompute cost, hits and age.
  The file is complete before its row is written; a row without a file is
  garbage, a file without a row is swept at launch. Default cap **8 GB**,
  settable. Finished prints reach it through `PrintWriteback`, a bounded
  FIFO that drops the oldest past ~500 MB — a dropped entry only costs a
  re-render.
- **Export never enlarges.** `OutputSize.pixels(for:)` returns no resample at
  or above the frame's own long edge.
