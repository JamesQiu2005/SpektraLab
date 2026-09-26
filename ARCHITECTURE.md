# ARCHITECTURE.md

How SpektraLab is put together: a SwiftUI app with a C++ Metal render engine
compiled into it. Written for someone about to change the pipeline, the app or
the release. Current as of **1.1.1 + main, 2026-09-26**.

§0 is the map. §1 is the physical model, §2–§4 the engine's runtime, §5 build
and release, §6 cost, §7 the macOS app, §8 the engine in detail, §9 how the app
is verified. Other documents cite these numbers (§3, §7.3, §7.5, §8.2–§8.8), so
they stay put; new material goes in new subsections.

---

## 0. The product, end to end

```
  ┌─ SpektraLab.app ── one arm64 binary, 32 MB, macOS 15+ ────────────────┐
  │  SwiftUI + AppKit + Metal · English / 简体中文                         │
  │                                                                       │
  │  Import/      RAW + TIFF decode (Core Image) → linear ProPhoto float  │
  │  Session      all state · @Observable · @MainActor                    │
  │  Renderer     the canvas: Layer 2, geometry, histogram                │
  │  Export/      recipes · soft proof · batch · ImageIO writers          │
  │  Agent/       CLI + MCP front doors onto the same Session (RFC-026)   │
  │  Diagnostics/ log · memory arena · SQLite-indexed disk cache          │
  │  EngineClient ── actor · JSON params in · MTLTexture out              │
  │        │  spk_engine.h, a hand-written extern "C" surface             │
  │        ▼                                                              │
  │  ┌─ engine/ ── C++20, compiled into this target ──────────────────┐   │
  │  │  core/      setup maths: colour, profiles, curves, couplers,   │   │
  │  │             CAM16, the Hanatos LUT, print LUTs                  │   │
  │  │  gpu/       a five-verb interface + its Metal backend           │   │
  │  │  shaders/   MSL → spektrafilm.metallib (built by build.sh)      │   │
  │  │  pipeline/  the node sequence, the session, the C ABI           │   │
  │  └─────────────────────────────────────────────────────────────────┘   │
  │  Resources/engine/    baked constants, 28 profiles, 8 print LUTs      │
  │  Resources/Licenses/  four licence texts, shown in About              │
  └───────────────────────────────────────────────────────────────────────┘
```

- **One process.** No pipe, no subprocess, no Python at run time. The engine
  takes pixels and returns an `MTLTexture` the canvas draws, zero-copy
  (RFC-014). The Python implementation it was ported from lives upstream and
  is only the oracle for the parity harnesses (§8.6).
- **Parameters cross as JSON; pixels do not.** `EngineClient.call` takes a
  `Method` and Codable types (`transport_version` and `schema_version` are
  both 1). Renders go through `EngineClient.render`, because a texture cannot
  travel through a `Decodable`.
- **The engine returns pixels, never files.** `Exporter.swift` writes every
  file through ImageIO (§8.8).
- **Three front doors, one implementation.** The window, `SpektraLab cli`
  and `SpektraLab mcp` drive the same `Session` and save to the same sidecar
  (§7.9).

**Who owns what.** `CONTRACT-frontend-backend.md` §1 governs the wire: a field
name, tier name, file layout or version number is a wire change even when it
looks like a refactor.

| topic | read |
|---|---|
| the engine: what was built, what parity measures | `rfc/RFC-014-native-cpp-engine.md` §8 |
| the wire and version negotiation | `CONTRACT-frontend-backend.md`, `API-SPEC-callable-render-service.md` |
| the colour chain | §7.5, `rfc/RFC-018` |
| memory | §4, `rfc/RFC-019`, `rfc/RFC-020` |
| scene latitude · contrast mask · effect strengths | `rfc/RFC-023`, `RFC-024`, `RFC-025` |
| agents | §7.9, `rfc/RFC-026` |
| traps that cost real debugging time | `AGENTS.md` |

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
            · expose.boost · expose.lens_blur · expose.halation · expose.log
            · develop.curves · develop.dir_couplers · develop.grain
printing    expose.enlarger_spectral · expose.contrast_mask (RFC-024)
            · expose.print_exposure (incl. pre-flash) · develop.print_curves
scanning    scan_spectral · xyz_to_rgb · gamut_compress · cctf · edr · glare
            · scanner_blur · unsharp · bw_correction
```

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
- **One full-resolution render at a time.** Interactive renders are at the
  preview edge; the native render runs once after edits settle (§7.3).
- **Exports run one frame at a time** (§7.8) for the same reason: two full
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

RSS cannot see the Metal pool. Measure with `footprint -p <pid>`: on a live
session ~75 % of the app's footprint is `IOAccelerator` — pixels on the GPU —
and the code is ~8 MB of it.

---

## 5. Build and release

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
Per-node engine timings need `SPEKTRAFILM_NODE_TIMINGS=1` (§8.9).

---

## 7. The app (`modern_UI/Spektrafilm`)

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

### 7.1 The window (v4, 2026-09-26)

Three regions and a filmstrip. Which rail a control is on says what moving it
costs.

| region | sections | runs in |
|---|---|---|
| **Film and Print** (left) | Navigator · Film · Print · Crop · Enlarger | the engine; Crop is geometry (below) |
| **Parameters ▸ Pre-Dev** (right) | Latitude · Camera · Film Format · Scene Placement · Tone Mask | the engine, except Camera's white balance and lens correction, which are the **decode** |
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

### 7.2 The two layers

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

### 7.3 Resolution: two states, not a ladder

- **Preview:** every interactive edit renders at the preview long edge — 3840,
  2560 (default), 1920 or 1080 — the engine's `live` tier.
- **Original:** a render at the frame's own pixels, started 400 ms after the
  edit stops and shown when it lands. One alive at a time.
- **Zoom selects neither** (2026-09-12). The canvas is soft above the preview
  edge until the original lands — the `preview` badge — and `full` means the
  frame is on the canvas at its own size, at any zoom.

45 MP, grain and glare off: a live reprint is 6.2 ms at 1600, 13.7 ms at 2560,
121.7 ms at 8192.

### 7.4 What the app does not do

- **No display transform.** The canvas layer is tagged ProPhoto RGB and
  ColorSync converts for the display (§7.5).
- **No post-print editing beyond Layer 2.** The product edits the physical
  process; retouching belongs to other software.
- **No masks, for now.** Built, withdrawn behind `FeatureFlags.masks = false`
  pending a redesign; the flag also stops sidecar masks reaching the kernel.

### 7.5 The colour chain, end to end

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

### 7.6 State: what lives where

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

### 7.7 Surfaces that show the frame

Every surface that shows a frame shows the canvas's frame. This is the rule
the navigator broke while every suite was green (§9).

| surface | shows | from |
|---|---|---|
| canvas | the output: geometry applied at draw | `Renderer` |
| navigator | the cropped, turned frame only — it is a map of the canvas | the thumbnail through `Geometry.outputToSourceTransform` |
| filmstrip, export strip, export grid | the **whole** photograph, the outside of the crop under an 82 % mask, turned and flipped (Capture One's behaviour) | `CropMaskedThumbnail`, with `Session.thumbnailGeometry(for:)`: the live geometry for the open frame, the saved one for the rest |
| histogram | **known defect:** counts the uncropped print — `encodeHistogram` reads the Layer 2 texture before geometry | pinned by `SurfaceAgreementTests` |
| exported file, agent preview | the output, via `Exporter.filePixels` | pinned by `SurfaceAgreementTests` |

`ThumbnailCache` holds the **uncropped** print thumbnail on purpose; each
surface applies the geometry itself.

### 7.8 Export

- **A recipe** is format, depth, colour space, long edge, naming and folder
  (`ExportRecipe`). The export page proves the file at its own resolution
  before it is written (soft proof, §7.5 row 7c) — measured identical to the
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
  pixel dimensions to the file's own.

### 7.9 Agents (RFC-026)

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

### 7.10 Keys

Capture One's single-key shortcuts (V/H/C tools, ←/→ frames, `,`/`.` zoom,
Y compare) are menu items, and AppKit offers a key to the menu **before** the
focused text field — measured: a modifier-free ← fired "next frame" from
inside a field. `TypingKeyGuard` is a local key monitor that sends typing keys
(characters, arrows, delete) straight to a focused editable text view.
⌘/⌃ combinations and Return, Enter, Esc, Tab still reach the menu.

---

## 8. The native engine

RFC-014, implemented 2026-09-10. Read `rfc/RFC-014-native-cpp-engine.md` §8
before changing any of this.

### 8.1 Layout

```
engine/include/spektrafilm/spk_engine.h   the whole C ABI
engine/src/core/        setup maths — no GPU, no pixels, testable alone
engine/src/gpu/         gpu.hpp (the interface) + the Metal backend
engine/src/shaders/     the kernels; built by build.sh, not Xcode
engine/src/pipeline/    pipeline · scene_latitude · contrast_mask · blur · engine (the C ABI)
engine/tools/           bake_resources.py
engine/tests/           seven parity harnesses, three C++ drivers, the math guard
engine/build.sh         lib | dylib | metallib | tests | bundle | all
```

The engine compiles **into the app target**; `Tools/gen-project.py` lists its
translation units, so a new `.cpp` needs the generator or it is silently not
compiled (a link error, not a missing-file error).

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

MSL, compiled by `engine/build.sh` into `spektrafilm.metallib`, **not** by
Xcode: the app sets `MTL_FAST_MATH = YES` for its canvas, and inheriting it
drifts `exp` and fma contraction past the float32 bar, silently.
`spk_math_probe` computes `a*b - a*b` — exactly 0 under fast math — and
`spk_engine_create` refuses to start if it is; `check_math_guard.sh` proves the
guard can fire.

### 8.5 Caches, and why a slider is fast

| what | why it is expensive | keyed on |
|---|---|---|
| CAM16 `C_max` table | ~830,000 CAM16 inversions | output colourspace |
| Hanatos `tc_lut` | 192×192×81 contraction + a ray-polygon remap | stock **and the sensitivity array** |
| the session's negative | the whole film side | invalidated by a `shoot`-layer edit only |

The `shoot`/`print` tag on every wire field is therefore a correctness
concern: a `print` edit reuses the negative, a `shoot` edit must not.

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

**The bundle is 32 MB, and ~3 MB of it is code.** 15 MB is engine data
(constants — mostly the float16 Hanatos spectra and the 3.45 MB of print
LUTs — plus 5.8 MB of profiles), 13 MB is `Assets.car` (the Icon Composer
icon's SVG layers, which `actool` keeps so the system can compose light, dark
and tinted renderings), 3.3 MB the executable (app + engine), 148 kB the
canvas metallib. Everything else is a system framework: Metal, SwiftUI, Core
Image, ImageIO, CryptoKit, `libsqlite3`.

### 8.8 Export methods

| method | the engine does | Swift does |
|---|---|---|
| `export` | `spk_reprint` at the full tier | Layer 2, geometry, the file (ImageIO) |
| `preview_stock_lut` | the negative through the trilinear kernel | draws or writes it |
| `export_di` | the negative normalised by the LUT's axes, and the table | the 16-bit TIFF and the `.cube`, one folder |

**No file writer in the engine**, by design: ImageIO already writes the formats
and owns the colour tagging. The DI TIFF is **device RGB, not a colour** — its
channels are film densities the `.cube` indexes — and `PrintLUTTests` asserts
it carries no profile. The package is one folder of exactly two files.

### 8.9 Node timings measure encode time unless you ask

Dispatches batch into one command buffer, so a timer around a node measures
*encoding*. `progress.node_times` is empty unless `SPEKTRAFILM_NODE_TIMINGS=1`,
which flushes per node. An empty field is honest; a plausible wrong number is
not.

---

## 9. Verification

```
SpektrafilmTests      the full suite — ~430 tests, ~420 s with fixtures
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
- **In-process tests cannot see the window.** `Tools/snapshot.sh` cannot see a
  `CAMetalLayer`; `Tools/capture-live.sh` photographs the real window and is
  the only capture that proves the canvas draws. Neither sees a stall; the
  canvas log (`SPEKTRAFILM_CANVAS_LOG=1`) does.
