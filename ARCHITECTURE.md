# ARCHITECTURE.md

How SpektraLab is put together: a SwiftUI app with a C++ Metal render engine
compiled into it. Written for someone about to change the pipeline, the app, or
the release.

**§0 is the map** and the section to read first. §1 is the physical model the
engine simulates, §2–§4 are the engine's runtime, §5 is how it is built and
released, §7 is the macOS frontend, and §8 is the engine in detail. Section
numbers are cited from other documents (RFC-003 cites §3), so they stay put.

---

## 0. The product, end to end

SpektraLab is **one application with a C++ render engine linked into it**. The
engine, the 28 film profiles and the LUTs baked from them are spektrafilm's, by
Andrea Volpato. The Python implementation they came from lives in the upstream
repository, not here. It never ships; it is the reference that the parity
harnesses (§8.6) measure this engine against.

```
  ┌─ modern_UI/Spektrafilm ─── SpektraLab.app, one binary, 32 MB ─────────┐
  │  SwiftUI + AppKit + Metal · arm64 · macOS 15+ · English / 简体中文      │
  │                                                                       │
  │  Import/    RAW + TIFF decode (Core Image) ─ linear ProPhoto float    │
  │  Session    all state, @Observable, @MainActor                        │
  │  Renderer   the Metal canvas: Layer 2, geometry, histogram            │
  │  Export/    recipes, soft proof, ImageIO writers                      │
  │  EngineClient ── actor, JSON in / MTLTexture out                      │
  │        │                                                              │
  │        │  spk_engine.h, a hand-written extern "C" surface             │
  │        ▼                                                              │
  │  ┌─ engine/ ── C++20, compiled into this target ──────────────────┐   │
  │  │  core/      the setup maths: colour, profiles, curves,         │   │
  │  │             couplers, CAM16, the Hanatos LUT, print LUTs       │   │
  │  │  gpu/       a five-verb interface + its Metal backend          │   │
  │  │  shaders/   the kernels, MSL → spektrafilm.metallib            │   │
  │  │  pipeline/  the node graph, the session, the C ABI             │   │
  │  └────────────────────────────────────────────────────────────────┘   │
  │  Resources/engine/  baked constants, 28 profiles, print LUTs, metallib│
  │  Resources/Licenses/  the four licence texts, shown in About          │
  └───────────────────────────────────────────────────────────────────────┘
```

**There is no pipe, no subprocess and no Python at run time.** The engine takes
pixels and returns an `MTLTexture` the canvas draws, with no copy (RFC-014
§2.2). It used to be two programs joined by JSON-RPC over stdio. RFC-014
removed the pipe on 2026-09-10, and the product moved into its own repository
on 2026-09-11.

**Parameters still cross as JSON.** `EngineClient.call(_:_:as:)` takes a
`Method` and Codable request/response types, and the engine reports
`transport_version` and `schema_version` (both 1). JSON stays because parameters
are small, the schema already exists, and a struct-per-parameter boundary would
break every time a slider is added. Renders are the one exception and go
through `EngineClient.render(_:_:)`, because a texture cannot travel through a
`Decodable`.

**The engine returns pixels, never files.** `export`, `export_di` and
`preview_stock_lut` are `spk_reprint` at the full tier, `spk_export_di` +
`spk_print_lut_table`, and `spk_preview_stock_lut` (§8.8). `Exporter.swift`
writes the TIFF, the `.cube` and the print preview through ImageIO.

### Who owns what

`CONTRACT-frontend-backend.md` §1 still governs **the wire**. Its §4 once split
the work between a frontend and a Python backend session; the backend stayed
upstream, so §4 no longer routes anything. A field name, a tier name, a file
layout or a version number is a wire change even when it looks like a refactor.

### Where to read more

| topic | file |
|---|---|
| **the native engine: what was built, what parity measures, what is left** | `rfc/RFC-014-native-cpp-engine.md` §8 |
| the wire, ownership, version negotiation | `CONTRACT-frontend-backend.md` |
| the method surface and semantics | `API-SPEC-callable-render-service.md` |
| the frontend in detail | `modern_UI/Spektrafilm/README.md` |
| the traps that have cost real debugging time | `AGENTS.md` |
| what it looks like, on real frames | `screenshots/` (§7) |
| the colour chain | `rfc/RFC-018-colour-management-and-soft-proof.md`, and §7.5 |
| the GPU render core the kernels came from | `rfc/RFC-011-gpu-native-render-core.md` |

---

## 1. The physical model

The simulation walks a photograph through four physical stages:

```
scene light → [camera+film] → latent image → [development] → negative dye densities
            → [enlarger+paper] → latent print → [development] → print dye densities
            → [scanner/viewing] → output RGB
```

One rule governs changes to this model:

> 不要为了修 rendering problem 去污染 material model。
>
> **Do not pollute the material model to fix a rendering problem.** Film and
> paper profiles describe what the materials can do; they are not places to
> store scene placement, output-headroom, or grading decisions. If the scene is
> wider than the selected film and paper can separate, map the scene before it
> reaches them. If the completed print needs more output headroom, use the
> output-side EDR stage. If the photograph needs a final look, use Layer 2.
> Fix the stage that owns the decision rather than changing a measured material
> response to compensate for another stage.

Colour is modelled **spectrally**, not as RGB matrices. The spectral axis is
380–780 nm in 5 nm steps, **81 wavelengths**. Density curves are sampled on
256 points of log exposure from −3 to 4. Both come from the baked constants.

Three transforms carry the colour:

**(a) RGB → film exposure** — Hanatos 2025 spectral upsampling
(`core/hanatos.cpp`). Input RGB becomes XYZ under CAT16 adaptation to the
film's reference illuminant, splits into brightness `b = X+Y+Z` and
chromaticity `xy`, and a triangle-to-square warp maps `xy` into a unit square.
A 192×192×81 table of irradiance spectra is indexed by that coordinate and
collapsed **at setup time** against the film's spectral sensitivity into a
192×192×3 `tc_lut`. Per pixel it is a bicubic 2D lookup times `b`; the
81-wavelength axis never touches the image here.

**(b) Exposure → density** — interpolation against 256-sample characteristic
curves, then DIR couplers (a 3×3 donor→receiver inhibition matrix applied to
silver density, spatially diffused, subtracted from log exposure and
re-interpolated against back-solved pre-coupler curves), then grain.

**(c) Density → light → response** — the spectral integral:

$$\text{out}_m = \sum_{\lambda} I(\lambda)\,S_m(\lambda)\;10^{-\left(\sum_k c_k D_k(\lambda) + D_{\text{base}}(\lambda)\right)}$$

It runs twice: in printing (S = paper sensitivity, I = enlarger illuminant) and
in scanning (S = CIE 1931 CMFs, I = viewing illuminant). The kernel keeps the
81-wavelength axis in registers, 3 values in and 3 out per pixel, and never
materialises a per-pixel spectrum. The reference once did, at 1.4 kB per pixel.

---

## 2. Runtime structure

`engine/src/pipeline/pipeline.cpp` runs the render as a **sequence of named
nodes**, one per physically distinct effect (the granularity RFC-003 chose). The
node order, the labels and the identity-pruning conditions are the reference's,
because the labels are what per-node timings and a regression bisection report
in. A node whose parameters make it the identity is skipped, not paid for.

The reference is a general graph over named taps. The engine keeps only the
three entry/exit pairs that are used: RGB in → film densities for the negative
(`run_film`), film densities → RGB out for a reprint (`run_print`), and both in
a row for a full render.

By stage, not in execution order:

```
preprocess  decode_input · input_cast · geometry · crop_rescale · auto_exposure
filming     expose.upsample · expose.exposure · expose.boost · expose.lens_blur
            · expose.halation · expose.log · develop.curves
            · develop.dir_couplers · develop.grain
printing    expose.enlarger_spectral · expose.print_exposure
            · develop.print_curves
scanning    scan_spectral · xyz_to_rgb · gamut_compress · cctf · edr · glare
            · scanner_blur · unsharp · bw_correction
```

Twenty-six labels in all. `preprocess.decode_input` is dormant in the app,
because Core Image decodes before the engine sees the frame (§7.5). A slide
film has no print stage: `scan_film` takes the scanning branch straight from
the film's densities.

A **session** holds one opened frame and its last negative. A `print`-layer
edit reprints from the cached negative; a `shoot`-layer edit rebuilds it (§8.5).
Renders come in three **tiers**: `live` at the preview long edge the user picks,
`preview`, and `full` at the frame's own pixels. The tier names are part of the
wire (contract §1.2.3).

---

## 3. Stage classification

The partition that matters for any port or any tiling:

| class | stages | shape |
|---|---|---|
| **pointwise** | spectral upsampling, boost, curves, both spectral integrals, gamut compression, XYZ→RGB, CCTF | fused elementwise; parallelises with no halo; LUT-able in principle |
| **spatial** | lens blur, halation, DIR coupler diffusion, scanner blur, unsharp | separable convolutions; tiling needs halos |
| **stochastic** | grain, **glare** | needs counter-based RNG for reproducibility and tiling |

Glare being stochastic is easy to miss and is the source of the pipeline's
default nondeterminism (see `AGENTS.md`). Halation has unbounded support, which
is what stops the full-resolution render from being tiled.

**Gamut compression is a look, not a free speedup.** `gamut_compress` is a
CAM16-UCS roll-off: a one-sided Reinhard shoulder on lightness (identity below
70, asymptotic at 100) and a chroma knee against the destination's `C_max`,
preserving hue. On ordinary frames almost nothing is out of gamut, so the chroma
half is insurance, while the lightness half touches a real share of the
highlights. Changing the algorithm changes the picture.

---

## 4. Memory model

**GPU buffers are pooled, and a buffer is reused only when it is both free and
idle**: its last handle is dropped, *and* the command buffer that last named it
has completed. §8.3 has the defect that taught this. The pipeline flushes at
node boundaries, which is where the reference evaluates too.

**One full-resolution render is alive at a time.** The interactive render is at
the preview long edge. The frame's own resolution is rendered once, after edits
settle (§7.3). At 45 MP that full render is about 360 MB; at 151 MP, 1.2 GB.

**Large resident allocations share one policy.** `Diagnostics/MemoryArena.swift`
accounts for the app's big holdings, including decoded frames and thumbnails, and
gives each an evict closure; the arena never owns the objects. A dropped engine
client once leaked about 458 MB; that is fixed.

**Export never enlarges a frame.** `OutputSize.pixels(for:)` returns no resample
when the requested long edge is at or above the frame's own. There is no
super-resolution path, and an upsample would only add memory with the square of
the scale.

---

## 5. Build and release

```
engine/build.sh bundle     compile the kernels, rsync engine/resources into the app
Tools/gen-project.py       generate the Xcode project; version, targets, flags
xcodebuild …               the app, with the engine's C++ compiled into it
Tools/package.sh           archive → export → verify → floor → DMG → notarise → spctl
```

- **The kernels are compiled by `engine/build.sh`, not by Xcode**, with safe math
  and `-mmacos-version-min=15.0`. Xcode's fast math must not reach them (§8.4).
  The build refuses a metallib stamped for any other macOS, because one built for
  the host (macOS 27) shipped once in 0.3.
- **`engine/resources/` is tracked**, 15 MB of baked output. Regenerating it
  needs the Python reference and is done upstream (`engine/tools/bake_resources.py`).
  The metallib inside it is the one untracked file; it is rebuilt every time.
- **The app's floor is checked on the finished artefact.** `package.sh` asserts
  `LSMinimumSystemVersion` 15.0, every Mach-O `arm64` with `minos` ≤ 15, and
  every metallib stamped ≤ 15.
- **Versions are derived.** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
  `Tools/gen-project.py` are the one place; `Info.plist` references them.
- **Signing.** The hardened runtime is on and the entitlements are empty. Without
  a Developer ID the build is ad-hoc signed and not notarised, and `package.sh`
  says so and exits 1. Builds go out as GitHub prereleases.
- **Licences.** `license/` holds the GPL-3.0 text (the app and the engine) and
  spektrafilm's CC BY-SA 4.0 text (the profiles and LUTs); metal-cpp's Apache-2.0
  text stays with the vendored code. `Tools/bundle-licenses.sh` copies all of them
  into the bundle, and `LicensingTests` and the pre-build phase check they are
  there.

---

## 6. Where the time goes

The engine's measured numbers are in §8.7: at 45 MP a live reprint is about
0.01 s and a full-resolution render 0.87 s on an M3 Max. The largest cost on the
open path is not the engine; it is Core Image rendering the RAW to a float
bitmap.

The model's cost is **spatial-dominated**. In the reference's 45 MP profile,
halation (unbounded support) and the DIR coupler diffusion were the two largest
nodes, and neither fuses the way the pointwise stages do. That profile took
12.9 s; the gap is why RFC-014 exists. Per-node engine timings need
`SPEKTRAFILM_NODE_TIMINGS=1` (§8.9).

---

## 7. The frontend (`modern_UI/Spektrafilm`)

A native macOS app: SwiftUI for the panels, AppKit for the window, Metal for
the canvas. `modern_UI/Spektrafilm/README.md` is the detailed document; this is
what someone modifying the *pipeline* needs to know about the thing consuming
it. `screenshots/spektralab-main_new.png` is that window on a real frame.

The left rail is four sections — **Input / Camera · Film · Print · Crop** — and
the right rail five. The interface is English or Simplified Chinese
(`Localization/`, switchable in Settings); enum display names stay English
because tests pin them.

**The left rail is not "the engine rail".** §7.2's two layers are the
load-bearing split, and the right rail is exactly Layer 2 — but the left rail
carries four different costs, and a row filed under the wrong one is a row
whose latency nobody can predict:

| left rail | runs in | what one change costs |
|---|---|---|
| Temperature · Tint · As Shot · Lens Correction | **the decode** — `CIRAWFilter`, Core Image | a re-decode of the frame, then a render |
| Metering · Film Exposure · the film list · Film Format/Side/Side Length · Grain · Halation · Glare · the paper list · EDR · **Solve** | **the engine**, Layer 1 | a `params_delta` and a render |
| Vignetting | **Layer 2**, the app's kernel | one draw |
| **Original** | **neither** — shows the decode instead of the print; a toggle, and ⎵ while held | one draw |
| Crop · Straighten · turns · flips | **neither** — geometry, upstream of both | one draw; `Exporter` applies it first, after the print comes back |

Crop is on the left because the frame's shape is a camera-side decision, not
because it reaches an engine parameter — it reaches none (`CropSection.swift`).
The one wire it can pull is `Session.recalculateEffectsAfterCrop`, off by
default: cropping a negative does not make its grain coarser unless the person
says the crop is a different negative.

**Two white balances, and they are different stages.** Camera's Temperature and
Tint are the decode's, in kelvin, with an "As Shot" box per axis; White Balance
in the right rail is Layer 2's, on the scan; and neither is the enlarger's
filter pack, which **Solve** (the Print section's left capsule) solves. They are kept apart by the rule that two
stages must not share a name — which is why the right rail's section writes
"Print — an adjustment on the scan" under its own sliders.

**The right rail is Layer 2 in the drawing's order**: Histogram · White Balance
· Exposure · Curve · Color Balance, with masks withdrawn behind
`FeatureFlags.masks` (§7.4). The histogram is the one that reads rather than
writes — 256 bins × (R, G, B, luma), read back on the Layer 2 pass's completion
and published on the main actor, so it describes the **adjusted** image and not
the print the engine returned. Under it sit the frame's ISO, shutter and
aperture.

### 7.1 Structure

```
Model/        Session (all state, @Observable, @MainActor) · Params (Layer 1,
              the wire's fields) · Adjustments (Layer 2, never leaves the app)
              · Geometry (crop, straighten, turns, flips) · Sidecar (per-frame
              settings on disk) · StockCatalog · FeatureFlags · DecodeResidency
Import/       Library, ImageDecoder (Core Image), FramePipeline, ThumbnailCache
Canvas/       Renderer (Metal state; the Layer 2 pass and the draw) ·
              Shaders.metal (layer2 · geometryResample · histogram ·
              canvasFragment) · ColourManagement · crop/compare/mask overlays
Service/      EngineClient (the C++ engine, in this process, §8) · Methods ·
              RenderScheduler (sent-vs-wanted coalescing of slider deltas) ·
              EngineMessage (engine errors in words a user can act on)
Export/       ExportPage · ExportRecipe (formats, colour space, long edge) ·
              Exporter (ImageIO writers) · SoftProof
Panels/ Controls/ Windows/ Theme/   the interface, drawn to the v3 layout
Localization/ English and 简体中文
Diagnostics/  the log, job log, memory arena and sampler, disk cache
```

### 7.2 The two layers, which is the load-bearing distinction

| | Layer 1 | Layer 2 |
|---|---|---|
| what | film, paper, camera, enlarger | exposure, contrast, curves, colour balance |
| where | the **engine** | a **Metal compute kernel in the app** |
| cost | an engine call: ~14 ms at the default preview size, ~0.12 s at native | one draw, sub-millisecond |
| panel | left — but not every left row is Layer 1, see the table above | right |

A Layer 1 edit sends a `params_delta` and waits for pixels. A Layer 2 edit
never leaves the app. Putting a control on the wrong side is not a cosmetic
mistake — it is the difference between a slider that tracks the mouse and one
that does not. The gap is narrower than it was (a live reprint is 13.7 ms at the
2560 default, not 190) but it is still a gap, and it still runs on a debounce.

`FilmParams.wire` is the single place the Layer 1 field names live, each tagged
`shoot` or `print`, and `ParamsTests.testWireNamesMatchTheServiceSchema` pins
the set against the reference's wire schema, and `parity_schema.py` holds the
engine to the same names. **A rename fails a test rather than silently
rejecting every delta at runtime.**

### 7.3 Resolution: two states, not a ladder

**The preview resolution** is what every interactive edit renders at: one of
four settable long edges (3840, 2560, 1920, 1080; **2560** by default). It is
the engine's `live` tier — the wire's three tier names are load-bearing,
contract §1.2.3 — with the size chosen by the user (`io.preview_long_edge`).

**The original image** is a render at the frame's own resolution, started
400 ms after the edit stops moving and shown when it lands. Exactly one is
alive at a time, which is the memory argument that used to shape the
escalation: 360 MB at 45 MP, 1.2 GB at 151 MP.

**Zoom selects neither** — the product decision of 2026-09-12. `wantedTier`
used to escalate live → preview → full as the zoom passed each tier's native
scale, and that ladder is gone; one working resolution plus the finished
picture is Capture One's model (预览图像) and what the user asked for. The zoom
readout still means native pixels and the viewport is still expressed against
the **native** frame rather than against whatever is on the canvas. The canvas
is simply soft above the preview resolution until the original lands, which
`previewSoft` reports as a `preview` badge — and the `full` badge is the other
half of the same statement: the frame is on the canvas at its own size, at
**any** zoom, including the 28 % fit in `screenshots/spektralab-main_new.png`.

Measured on the 45 MP Nikon Z7 II frame (8256×5504, grain and glare off), a
live reprint costs 6.2 ms at 1600, **13.7 ms at the 2560 default** and 121.7 ms
at 8192 native. So the interactive render is 7 ms a frame dearer than the 1600
it replaced, and the native render is 0.12 s run once per settled edit instead
of on every zoom step.

### 7.4 What the frontend does *not* do

- No colour management of its own on the canvas. The engine returns **ProPhoto
  RGB** encoded values — the working space — the `CAMetalLayer` is tagged
  ProPhoto RGB, and **ColorSync** does the conversion to whatever display is in
  front of the person. The app performs no display transform and must not add
  one. See §7.5.
- No bundling of a Python runtime, and no checkout beside the `.app`. That was
  true before RFC-014 and has not been since: the engine is compiled into the
  binary. (This bullet used to say the opposite.)
- No masks, currently. The system is built and withdrawn behind
  `FeatureFlags.masks = false` pending a design the user is writing. The flag
  also stops masks being packed for the kernel, so a sidecar that already has
  them renders as though it did not.


---

### 7.5 The colour chain, end to end

RFC-018. One working space, and exactly one conversion per destination.

| # | stage | space |
|---|---|---|
| 1 | RAW decode (Core Image) | linear ProPhoto float32 |
| 2 | engine ingest | `io.input_color_space = "ProPhoto RGB"`, no decode |
| 3 | engine interior | **no RGB space** — spectral upsampling → film log exposure → CMY density → print density → scan |
| 4 | engine gamut compression | CAM16-UCS into ProPhoto RGB |
| 5 | engine output | **ProPhoto RGB, CCTF encoded** — the working space |
| 6 | Layer 2, masks, curves, geometry | ProPhoto RGB encoded |
| 7a | canvas | layer tagged ProPhoto RGB; **ColorSync** converts to the display |
| 7b | export | one output transform: CAM16 into the recipe's gamut, then that space's TRC; tagged, written, **no Core Graphics conversion** |
| 7c | soft proof | the same transform, at the file's own resolution |

Three things about this are load-bearing and easy to undo by accident:

- **There is no RGB working space inside the engine.** Step 3 upsamples to
  spectra immediately, so the ingest space needs only to be a faithful
  colorimetric container, not a grading space. "ProPhoto vs ACEScc" is a
  category error here; ProPhoto is the *ingest* and the *output* colorimetry,
  not an intermediate.
- **Whatever goes in, ProPhoto comes out.** A Display P3 JPEG and a RAW leave
  step 5 in the same space. So every other colour space is a *compression* of
  the pipeline's output rather than a different rendering of it, which is why
  an sRGB recipe writes an sRGB file and why the gamut mapping belongs to the
  export rather than to the display.
- **The frontend reads the session's resolved output space** out of the `open`
  reply (`Session.workingSpaceName`) rather than assuming it. Three parity
  harnesses and two UI captions once held their own copies of that convention;
  see AGENTS trap 28.

The one trade this makes is stated rather than hidden: because ColorSync does
the display conversion with a matrix profile, out-of-display colour on the
**canvas** is clipped rather than rolled off. Measured in RFC-018 §7.2 at
0.0012 % of a neutral frame and 0.10 % with saturation at the top. Only the
export is gamut-mapped, so only the export is pinned — two people on two
screens see two slightly different pictures, and the file is the thing that
does not move.

## 8. The native engine

RFC-014, implemented 2026-09-10. Read `rfc/RFC-014-native-cpp-engine.md` §8
first if you are about to change any of this; it records what parity measures,
why each bar is where it is, and the bugs already found.

### 8.1 Layout

```
engine/include/spektrafilm/spk_engine.h   the whole C ABI
engine/src/core/        setup maths — no GPU, no pixels, testable on its own
      blob, json, colour, spectral, profile, params, curves, cam16,
      hanatos, numeric, printing, print_lut, setup_cache
engine/src/gpu/         gpu.hpp (the interface) + metal_gpu.cpp, metal_impl.cpp
engine/src/shaders/     the kernels; built by build.sh, not by Xcode
engine/src/pipeline/    image, blur, pipeline (the node sequence, §2), engine (the C ABI)
engine/tools/           bake_resources.py
engine/tests/           seven parity harnesses, three C++ drivers, the math guard
engine/build.sh         lib | dylib | metallib | tests | bundle | all
```

The engine compiles **into the app target** (`Tools/gen-project.py` lists the
translation units; C++20, metal-cpp on the header path, a hand-written bridging
header). One target, not two: a separate static-library target would only add a
second place for the include paths to drift.

### 8.2 The C ABI

Three rules, and they are the ones to keep:

1. **Nothing throws.** Every entry point is `noexcept`; failure is a negative
   `spk_status` plus `spk_last_error`. A C++ exception unwinding into Swift is
   undefined behaviour.
2. **Ownership never crosses** — with exactly one documented exception. The
   caller owns the device and the input pixels; the engine owns what it
   allocates. The exception is `spk_result.texture`, returned **+1**, because
   the frontend caches the last eight frames' textures and a texture whose
   pixels the engine reused on the next render would silently become a
   different photograph. Swift takes it with `takeRetainedValue()`; C calls
   `spk_result_free`.
3. **Parameters are JSON.**

The one place rule 3 does not reach is `spk_print_lut_table`, which hands out
a pointer to 431 kB of float32 rather than a number: the `.cube` writer needs
the table itself, and 107,811 values as JSON text would be a megabyte of
string to parse back into the array it started as. The pointer is engine-owned
and valid for the engine's lifetime, which keeps rule 2 — nothing crosses that
the caller then has to free.

A C ABI rather than Swift's C++ interop (which Xcode 26.6 supports and which
works): it is ABI-stable across toolchains, it keeps the boundary narrow, and
it is callable from `ctypes` — which is what lets the parity harnesses drive
the **shipping binary** rather than a reimplementation of it.

### 8.3 The GPU layer

Five verbs — alloc/upload, dispatch, flush, read, texture — and nothing above
`gpu.hpp` names Metal. This is the abstraction the MSL-only decision was taken
*with*: a Vulkan backend would implement `Gpu` and supply its own SPIR-V for
the same kernel names.

**Buffer lifetime is the part to understand before changing anything here.**
Buffers are reference-counted into a pool (`gpu::BufferRef`), and two
conditions must both hold before one is handed out again:

- **free** — its last handle dropped, so no *future* dispatch names it;
- **idle** — the command buffer that last named it has completed.

Only the first was true in the first version, and a later kernel overwrote a
buffer an earlier one had not read: 25 of 27 render-parity cases wrong, no
crash and no error. A freed buffer waits on a pending list and becomes
reusable at `flush`. The pipeline therefore flushes at node boundaries, which
is also where the reference evaluates (`mx.eval`; AGENTS trap 5), and
`Blur::mixture` flushes between components because a four-component halation
scatter is where one node holds the most memory at once.

Reclaiming only at the end of a frame instead cost **6.4 s and 3.2 GB at 24 MP
against 0.4 s** — a number that looks exactly like a CPU fallback and is not
one.

### 8.4 The kernels

MSL, compiled by `engine/build.sh` into `spektrafilm.metallib` and shipped as
a resource — **not** compiled by Xcode. The app target sets
`MTL_FAST_MATH = YES` for its own canvas shader, and letting the engine's
kernels inherit that is RFC-014 §5.1 trap 1: `exp` and fma contraction drift by
up to 1.1e-5, past the float32 bar, silently.

Every body transferred verbatim from the reference's `backends/metal/*.py` (upstream). What was added is
what MLX supplied for free: `take_rgb`, `affine3`, `mul`, `transpose3`, a max
reduction, a strided sample for the meter, the rgba16 conversion, the two
transfer-function kernels, and `spk_math_probe`.

`spk_math_probe` computes `a*b - a*b`, which is exactly `0.0` under fast math
and the fma error term under safe math. `spk_engine_create` refuses to start if
it comes back zero, and `engine/tests/check_math_guard.sh` builds a deliberately
fast-math library to prove the guard can fire.

### 8.5 Caches, and why a slider is fast

Three caches exist on the Python side and all three had to be ported; missing
them made every non-live slider cost 160–250 ms:

| what | why it is expensive | keyed on |
|---|---|---|
| the CAM16 C_max table | 64 × 720 cells × 18 bisections ≈ 830,000 CAM16 inversions | output colourspace |
| the Hanatos tc_lut | a 192×192×81 contraction plus a 192×192 ray-polygon remap | film stock **+ the sensitivity array itself** |
| the session's negative | the whole film side | invalidated by a shoot-layer edit only |

`core/setup_cache.hpp` holds the first two on the *engine*, shared by every
pipeline it builds. The tc_lut's key folds in the sensitivity rather than the
stock name because that is where the camera's UV/IR cut lands.

The negative cache is why the wire schema's `shoot` / `print` layer table is a
correctness concern rather than metadata: a `print`-layer edit reuses the
cached negative and a `shoot`-layer edit must not.

### 8.6 Parity: what is actually measured

Python stays the oracle, and it lives upstream. All seven drive the shipping
binary through `spk_ctypes.py`.

| harness | holds | result |
|---|---|---|
| `parity_setup.py` | 227 setup quantities vs colour-science/scipy/numpy | 0 failed, 86 bit-exact |
| `parity_schema.py` | the wire schema and digested params, 6 stock pairs | identical |
| `parity_render.py` | the picture, 27 configurations, 1 MP frame, vs numba | 0 failed, max 2.3e-5 |
| `parity_session.py` | all 39 wire fields applied to a *live* session | 0 failed |
| `parity_grain.py` | grain's mean/std/skew at 9 densities | 0 failed |
| `parity_exposure.py` | the auto-exposure meter's four modes, each engine written from the contract's text (RFC-015 §6) | the other harnesses run with the meter off |
| `parity_lut.py` | the 8 print tables, the LUT apply, the DI normalisation | 0 failed, tables bit-exact, max 8.0e-6 |

Plus `gpu_smoke` (the boundary) and `check_math_guard.sh` (that the guard
fires).

The render bar is **measured, not asserted**: 3e-5 absolute, because the
already-validated Python Metal core reaches 1.9e-5 against the same numba
reference on the same frame and this engine reaches 2.3e-5. Do not tighten it
to float32 epsilon — no GPU path over the whole node chain meets that — and do not loosen
it without saying what you measured. It is paired with a count-level bar so a
systematic shift cannot hide under the absolute one.

`parity_session.py` exists because the render suite opens a *fresh* session per
case and so never took the path a user takes: open once, then move sliders.
That gap hid a bug that broke twelve print-layer fields outright.

`parity_lut.py` holds three bars, because three different things can go wrong
in the LUT path. The **tables** are bit-exact against the shipped `.npz`,
because nothing between the asset and the pointer the C ABI hands out is
arithmetic — a table that arrived transposed would still make a plausible
photograph, which is RFC-012 §4.1's named failure mode. The **apply** and the
**DI normalisation** carry `parity_render`'s bars, because both sides read
their own negative, so what is measured is the film side's accumulated
float32 error plus one trilinear sample rather than the kernel's own (which
agreed with scipy at 2.4e-7 when both read the *same* negative). And the
**film-mismatch warning** is asserted present when the films differ and
absent when they do not: a warning that always fires trains the user to
ignore the one that matters.

### 8.7 Speed and size, measured

45 MP, warm, on an M3 Max:

| tier | first | reprint | LUT flip |
|---|---|---|---|
| live 1600 px | 0.13 s | 0.01 s | 2.0 ms |
| preview 3400 px | 0.25 s | 0.04 s | 9.5 ms |
| full 7800×5800 | 0.87 s | 0.17 s | 47 ms |

The **LUT flip** column is `spk_preview_stock_lut`: the cached negative
through one trilinear sample instead of the print chain. Re-measured
2026-09-10 on a synthetic 45 MP frame, which reproduced the reprint column to
0.009 / 0.034 / 0.167 s in the same run — that agreement is what makes the
new column comparable to the two beside it. **About 4× a reprint, not the
190× first estimated**: that figure was this kernel against *scipy
on the CPU*, which is the wrong comparison for a user who would otherwise
have got a real reprint on the GPU. `spk_export_di` is 51 ms at the full
tier, nearly all of it the rgba16 conversion.

A non-live slider is 0.2–3.4 ms of `set_params` plus a reprint. Opening a
24 MP RAW through the app is ~2.0 s, of which ~1.6 s is Core Image rendering
the linear TIFF to a float bitmap — now the largest single cost on that path.

Bundle **32 MB Release**, of which 15 MB is engine resources: 9.45 MB of
constants (5.97 MB of it the Hanatos irradiance spectra, kept float16 as the
reference stores them, plus the 3.45 MB of print-preview LUTs the LUT port
added), 5.8 MB of profiles for all 28 stocks, 196 kB of film cover art and
80 kB of licence texts. All data, all trimmable, none of it code. The DMG is
24 MB.

It was 17 MB and a 10 MB DMG until the app icon arrived. The other 13 MB is
`Assets.car`, and almost all of that is the Icon Composer document's own SVG
layers, which `actool` keeps rather than flattening: the system composes the
light, dark and tinted renderings from them at display time. It buys an icon
that follows the desktop's appearance, and it costs more than the entire
render engine's constants do — worth knowing before anything else is added to
the catalogue.

### 8.8 The three methods that used to be refused

`export`, `export_di` and `preview_stock_lut` were refused **by name** until
2026-09-10, when they were ported. They are now the whole of the method
surface, and the split between C++ and Swift is worth stating because it is
not the obvious one:

| method | the engine does | Swift does |
|---|---|---|
| `export` | `spk_reprint` at the full tier | Layer 2, the geometry, and the file (ImageIO) |
| `preview_stock_lut` | `spk_preview_stock_lut` — the negative through the trilinear kernel, into a texture | draws it, or writes it |
| `export_di` | `spk_export_di` — the negative normalised by the LUT's axes; `spk_print_lut_table` — the table | the 16-bit TIFF and the `.cube`, in one folder |

**No file writer was added to the engine**, and that is the design rather than
a shortcut. ImageIO is already how the finished formats are written and it is
where the colour tagging lives; `Exporter.writeCube` is thirty lines of text
formatting. What the engine owns is the part only it can do — the pixels and
the baked table. The reference put both halves in Python because Python had
both; here the boundary falls where the platform's own libraries already are.

Two consequences worth knowing:

- **The print-preview LUTs are bundled now**, 3.45 MB inside
  `spektrafilm_constants.bin` as `print_lut/<stock>` and
  `print_lut_axes/<stock>`, with `print_luts.json` as the metadata index.
  They are CC BY-SA 4.0 derivatives of the profiles, which is why the bundle
  carries licence texts (§5).
- **The DI TIFF is tagged device RGB, not a rendering space.** Its channels are
  film densities, and the `.cube` beside it indexes exactly those numbers — a
  host that treats them as a colour and converts on open silently moves the
  cube's domain out from under it. `PrintLUTTests` asserts the file carries no
  profile. The package is **one folder holding exactly two files**, the density
  TIFF and the `.cube`; the job log anchors one level up, because written
  "beside the output" it landed inside the package and made it three.

Still open: per-node timings are off unless `SPEKTRAFILM_NODE_TIMINGS=1` (§8.9); Xcode's
Debug configuration compiles the engine at `-O0`, which is ~1.7× on the setup
maths and nothing on the kernels. And baking a *ninth* print LUT is still
Python's job — `engine/src/core/print_lut.cpp` reads tables and does not make
them, because making one needs the whole print+scan chain over a 33³ grid.

### 8.9 Node timings measure encode time unless you ask

Dispatches batch into one command buffer, so a wall-clock timer around a node
body measures how long it took to *encode* — 0.003 ms for a full-frame matmul,
three orders of magnitude below the truth. `progress.node_times` is therefore
**empty** unless `SPEKTRAFILM_NODE_TIMINGS=1`, which flushes per node and gives
up the batching for the run. An empty field is honest; a plausible wrong number
in front of someone bisecting a slow frame is not.
