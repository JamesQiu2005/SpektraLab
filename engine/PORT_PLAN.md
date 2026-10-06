# Porting the five refused features to Vulkan -- a handoff

**Status (owner's decision, 2026-10-06):** contrast mask, scene latitude
mapping, Cineon Digital Intermediate, overscan/film edge and the date back
stay **refused** off Apple. `capabilities.backend.unsupported_features` lists
them, a request that turns one on fails with `SPK_ERR_USER` before the session
changes, and the default render is unaffected. This file is for the engineer
who ports them: what each feature touches, what is Apple-only, the portable
replacement, how to test it on lavapipe, and an estimate.

Line numbers are as of commit 880cffa (branch
`claude/spektralab-windows-linux-port-mi7r55`). Read `AGENTS.md` traps 19
(free is not idle), 20 (matrix orientation), 21 (`kMidgrayProbeColourSpace`)
and 28 (ask the open reply, do not assume) first, and **"do not pollute the
material model to fix a rendering problem"**.

## 0. Mechanics common to every feature

Porting one kernel is the same five edits each time:

1. `src/shaders/vulkan/<kernel>.comp` -- GLSL 450 compute, `local_size_x = 256`,
   one `std430` storage buffer per Metal `[[buffer(n)]]`, **in the same
   binding order**; the 1D index is `spk_global_index()` (copy the helper from
   any existing `.comp`; dispatches past 65535 workgroups fold into 2D,
   `vulkan_gpu.cpp` `dispatch`). Mark arithmetic that must not be contracted
   `precise` (Metal builds with `-fmetal-math-mode=safe`, AGENTS.md "Do not").
   If the kernel uses double-float pairs, declare
   `layout(constant_id = 0) const bool SPK_FUSED_FMA = true;` and copy
   `two_prod` from `spk_iir_df_acc.comp` (exact on lavapipe too).
2. `src/gpu/vulkan_gpu.cpp:56-91` `kKernels[]` -- `{name, bindings, kWorkgroup}`.
3. `CMakeLists.txt` `SPEKTRALAB_VULKAN_KERNELS` -- the name, so glslang builds it.
4. A numeric gate `tests/gpu_vulkan_<feature>.cpp` in the style of
   `tests/gpu_vulkan_pointwise.cpp`: the Metal kernel transcribed into C++
   **double** as the reference, random and edge-case inputs (0, negatives,
   NaN where the Metal comments promise behaviour, 1-pixel and odd sizes, a
   >16.7 M-thread case to cross the dispatch fold), a bound stated in the test
   (pointwise kernels: ~4 float ulp relative; anything with `pow`/`exp`: 1e-6
   relative). Register it in the `foreach(probe ...)` list in `CMakeLists.txt`.
5. Remove the feature from the refusal: `src/pipeline/windows_unported.hpp`
   (both overloads), the `unsupported_features` list at
   `src/pipeline/engine.cpp:321-324`, and flip the corresponding assertion in
   `tests/windows_feature_boundaries.cpp` from "refused" to "renders". Update
   `engine/PORT_COVERAGE.md`.

**Whole-feature acceptance.** There is no Metal device on Linux, so the
whole-image reference has to come from a Mac: run the shipping dylib there on
a small fixture (`tests/fixtures/windows/abi_probe.f32` is 3x2; make a 64x48
gradient + colour-checker frame) with the feature on, dump `rgba16` and the
params JSON, commit both under `tests/fixtures/windows/`, and add a
`spk_render_fixture`-style CTest that renders the same on Vulkan and compares
at the render-parity bar (3e-5 of full scale, `ARCHITECTURE.md` §8.6). Disable
grain and glare (`debug.deactivate_stochastic_effects`, AGENTS.md trap 1).
Then the host smoke (`engine/tests/host_smoke.py`) gets a case that turns the
feature on through `set_params` and renders.

## 1. Cineon Digital Intermediate -- smallest, do it first

| | |
|---|---|
| Metal | `src/shaders/nodes.metal:376` `spk_di_encode` (4 buffers: `y`, `p[42]`, `n`, `out`) -- pointwise: 10^density, base subtraction, 3x3, optional Oklab hue window, Cineon log encode |
| Host C++ | `src/pipeline/pipeline.cpp:1579-1620` `node_digital_intermediate` -- already portable, already compiled off Apple; `:282` `di_active_`; `:1936` the node in the chain |
| Refusals | `src/pipeline/engine.cpp:1625-1629` (`spk_render_digital_intermediate` returns early off Apple); `windows_unported.hpp` `di` flag via `io.digital_intermediate` |
| Apple-only deps | none |
| Test | kernel gate vs a double transcription (the `p[]` layout is documented above the Metal kernel, `nodes.metal:362-375`); then `spk_render_digital_intermediate` on the fixture vs a Mac dump; a slide film must still return `SPK_ERR_USER` |
| Estimate | **1-1.5 days** |

Host side: add `render_di {session}` (rgba16, `color_space` = the reply's
`primaries`, Cineon-encoded -- not display) and a DI option on `export_image`.

## 2. Scene latitude mapping (RFC-023)

| | |
|---|---|
| Metal | `src/shaders/scene_latitude.metal:43` `spk_scene_latitude` (4 buffers: `rgb`, `p`, `n`, `out`); helper roll-off functions above it (`:1-42`) |
| Host C++ | `src/pipeline/scene_latitude.cpp` (121 lines) -- portable and already compiled everywhere; `:36` `node_scene_latitude`, `:65` the dispatch; `src/pipeline/pipeline.cpp:136` setup, `:442` node count, `:1838` the node; the half-frame pair's second placement (`pipeline.cpp` `pb_`, commits abc55d5, 079ec29) |
| Refusals | `windows_unported.hpp` `latitude` (`camera.scene_latitude.active` / `scene_latitude_active`). The *analysis* `spk_scene_latitude` already works off Apple. |
| Apple-only deps | none |
| Test | kernel gate over all three `norm` modes (`p[6]` = 0/1/2) and both roll-off shapes (`m == 1` and general `m`), with `v` = 0, negative, huge, NaN; then commit the analysis's `params_delta` on the fixture and compare to a Mac dump; strip executor: a full render with a small strip budget must equal the whole-frame render (see `tests/strip_executor.py` for the existing pattern) |
| Estimate | **1.5-2 days** |

## 3. Contrast mask (RFC-024)

| | |
|---|---|
| Metal | `src/shaders/contrast_mask.metal:80` `spk_mask_reduce` (downsample the print-side CMY to the analysis grid), `:109` `spk_mask_epilogue` (apply the per-cell delta during the print) |
| Host C++ | `src/pipeline/contrast_mask.cpp` (341 lines, Apple-only today because of one call): `:37` `#include <dispatch/dispatch.h>`, `:101-106` `for_each_line` uses `dispatch_apply_f`; the Gaussian/box blurs on the grid (`:60-140`) are plain C++ in **double**; `:164` `prepare_contrast_mask`, `:210` reduce dispatch, `:301` `contrast_mask_field`, `:320-335` epilogue node. Off Apple `windows_unported.cpp:46-73` stands in for all of it. Pipeline hooks: `pipeline.cpp:459`, `:1942`, `:2339-2366` |
| Apple-only deps | GCD `dispatch_apply_f` only |
| Portable replacement | `for_each_line(lines, fn)` over `std::thread` (hardware_concurrency workers, static or atomic-counter line assignment). The function's own comment (`:95-100`) is the contract: each line is written by one thread and accumulated in the same order, so the result stays **bit-identical** to the serial loop and to GCD. Keep `dispatch_apply_f` under `#ifdef __APPLE__`; then compile `contrast_mask.cpp` everywhere and drop its half of `windows_unported.cpp` |
| Test | the two kernels against double transcriptions; `for_each_line` threaded vs serial must be `==` on the grid; `spk_contrast_mask_field` on the fixture vs a Mac dump of the same field (it is host-side double arithmetic, so it should match to ~1e-12); then the masked render vs a Mac dump; `tests/band_purity.py` pins that the mask does not re-develop the negative (`negative_was_cached` stays 1 on the reprint after a mask edit, API-SPEC §11) |
| Estimate | **2-3 days** |

## 4. Overscan / Film Edge (RFC-031/032) -- the large one

| | |
|---|---|
| Metal | `src/shaders/overscan.metal` (394 lines): `:144` `spk_overscan_canvas` (the film canvas around the frame: rebate, carrier, holes), `:208` `spk_overscan_add_mask` (add the rasterised edge print / date as exposure), `:305` `spk_overscan_film_present` (the film's presence in density), `:331` `spk_overscan_light` (the scan's view of the holes) |
| Host C++ | `src/pipeline/overscan.cpp` (2,155 lines): layout `:454-760` (`overscan_layout`, gates, formats, pair), `:765` params block, rasteriser `:819-962`, text measure `:1337-1350`, every maker's edge print `:960-1800` (Kodak/Fujifilm faces, the dot-matrix fonts at `:967-995` and `:1267`), date back `:1358`, `:1809`, nodes `:1972-2155` (dispatches at `:2035`, `:2110`, `:2131`, `:2149`). Off Apple `windows_unported.cpp:12-40` stands in |
| Apple-only deps | (a) **CoreText** -- `CTFontCreateWithName`, attributed strings with kerning, `CTLineDraw`, `CTLineGetTypographicBounds` (`:831-840`, `:918-931`, `:1340-1346`), fonts **HelveticaNeue, -Bold, -Medium** (`:216`, `:1491-1518`, `:1753`). (b) **CoreGraphics** -- an 8-bit grey `CGBitmapContext` with a full CTM, antialiased polygon fill and ellipses (`:882-933`). (c) **vImage** -- `vImageConvolve_PlanarF` separable Gaussian with `kvImageEdgeExtend` (`:938-958`) |
| Portable replacement | (c) a separable float convolution with clamp-to-edge indexing, threaded over rows -- the comment at `:938-942` is why it must not be a scalar loop in Debug; bit-identity with vImage is not expected (summation order), ~1e-7. (b)+(a) **stb_truetype** (already vendored, `third_party/stb/stb_truetype.h`): `stbtt_GetCodepointBitmap`-family for glyphs with the CTM applied to the glyph outline (`stbtt_GetCodepointShape` + transform + `stbtt_Rasterize`), kerning from `stbtt_GetCodepointKernAdvance`; polygons and ellipses through the same `stbtt_Rasterize` (it takes arbitrary `stbtt_vertex` lists), which gives one antialiasing model for everything. Alternative: FreeType + a small scanline filler -- more faithful hinting-free outlines, a heavier dependency (FTL/GPL-2 dual: GPL-compatible). Keep CoreText/CG/vImage under `#ifdef __APPLE__` behind a small `EdgeRaster` interface so macOS output is unchanged. |
| Font | Helvetica Neue cannot be redistributed. Closest permissively licensed metric-and-shape match: **TeX Gyre Heros** (GUST Font License, free to bundle and modify; a Helvetica clone with Regular/Bold, no Medium -- use Bold for `-Medium` and record it). Ship it under `engine/resources/fonts/` with its licence in `licenses/`. Expect glyph-shape differences at the 0.1 mm scale of an edge print; the layout (positions, sizes, tracking) stays the engine's own numbers. |
| Test | the four kernels against double transcriptions (canvas/holes are analytic geometry: test hole corners, the `penumbra_mm` softness, both orientations, every `overscan_format`); `spk_overscan_geometry` on Vulkan must equal a Mac dump exactly (pure host math); the rasterised mask: compare to a Mac dump of the coverage plane with a stated tolerance (mean abs, and max over a dilated edge band -- glyph rasterisers will not agree pixel-for-pixel); the convolution vs a double reference; `tests/overscan_checks.py`, `tests/band_purity.py` and `tests/strip_executor.py` already pin the stage (commit 3fe47b5) and should run against the Vulkan dylib unchanged |
| Estimate | **6-10 days** (2-3 kernels+layout, 3-5 the raster/text layer and font substitution, 1-2 acceptance against Mac dumps) |

## 5. Date back (RFC-031 §8)

| | |
|---|---|
| Where | inside overscan.cpp: `:1358` (`DateImprintParams`), `:1809` (one mechanism: light behind the film), validation `:2003-2014`, the pair's second date `:2066-2095`; styles `lcd`, `dots` (the 5x7 dot face, `:967-995`, portable) and `data` (Helvetica text via CoreText) |
| Depends on | §4's raster layer and `spk_overscan_add_mask`; it can be enabled without film edge (`date_imprint_active` alone runs `node_overscan`, `pipeline.cpp:447`) |
| Apple-only deps | as §4 (CoreText for the `data` style and the LCD segments' text path) |
| Test | each style x corner x placement on the fixture vs Mac dumps (coverage tolerance as §4); the date on 120 and on a pair (`text_b`) |
| Estimate | **1-2 days after §4** |

## Order and total

DI (1-1.5) -> scene latitude (1.5-2) -> contrast mask (2-3) -> overscan
(6-10) -> date back (1-2): **about 12-18 engineer-days**, plus a Mac for the
reference dumps. Each step lands independently: its refusal is removed only in
the commit whose tests pass, and `capabilities` stays truthful in between.

The host needs no change for any of them beyond what is noted in §1: the
fields are ordinary `set_params` deltas, `overscan_geometry` and
`scene_latitude` are already forwarded, and the error a refused feature
returns today (`bad_request`, message "... is not implemented by the Windows
Vulkan backend yet") simply stops happening.
