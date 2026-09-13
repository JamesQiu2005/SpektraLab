# RFC-018 — A ProPhoto working space, one output transform, and an export that shows what it will write

| | |
|---|---|
| **Status** | Accepted 2026-09-13. Supersedes the proposal-only draft of the same number. §1 is code-traced; §2 is the decision; §3–§5 are the build. |
| **Date** | 2026-09-13 |
| **Depends on** | RFC-014 (the C++ engine is the renderer, C ABI to Swift, shared `MTLDevice`), RFC-003 (the tap graph this does not touch), `CONTRACT-frontend-backend.md` (**extended** by §5.1 — the wire has never named an output colour space) |
| **Scope — engine** | `core/params.hpp`, `pipeline/engine.cpp`, the new `spk_output_transform` entry point, `include/spektrafilm/spk_engine.h` |
| **Scope — app, pixels** | `Canvas/Shaders.metal`, `Canvas/Renderer.swift`, `Import/ImageDecoder.swift`, `Export/Exporter.swift`, new `Export/SoftProof.swift` / `Canvas/ColourManagement.swift`, `Model/Session.swift` (the status line) |
| **Scope — app, export page** | `Export/ExportSheet.swift` and its replacement, `Export/ExportRecipe.swift`, `Windows/` presentation |
| **Out of scope** | The canvas's spectral/densitometric interior (§1 step 3). Nothing in the tap graph moves. |
| **Handoff** | §8. |

---

## 0. The question this started from

> "What is the **displayed** version of the decoded image? Does it just
> default to ProPhoto RGB on the app side, or anything else? Without this
> declared rather than guessing the colour management would be a piece of
> shit."

The answer, as shipped, is **Display P3** — correct on screen, and derivable
only from a comment inside the C ABI. A chain that is right but underivable is
not managed, it is lucky.

The answer this RFC builds is different, and it is the user's: **the app edits
in ProPhoto RGB and converts once, at the end, per destination.** Capture One
grades in a wide proprietary space and converts on export; Lightroom grades in
ProPhoto primaries and converts on export. Filmify has been doing the reverse —
converting to the narrowest space in the chain first, then grading inside it.

---

## 1. The chain as built (before this RFC)

| # | stage | space | where |
|---|---|---|---|
| 1 | RAW decode | float32 **linear ProPhoto** (ROMM primaries, D50, linear TRC) | `ImageDecoder.swift:98` builds it by hand — CG ships ROMM only at γ1.8 |
| 2 | engine ingest | `io.input_color_space = "ProPhoto RGB"`, `input_cctf_decoding = false` | `params.hpp:209-210` |
| 3 | engine interior | **no RGB space** — spectral upsampling → film log exposure → CMY density → print density → scan | `ARCHITECTURE.md:162-172` |
| 4 | gamut compression | CAM16-UCS into `output_color_space` | `pipeline.cpp:339-370`, `shaders/gamut.metal` |
| 5 | engine output | **Display P3**, CCTF encoded | `engine.cpp:583-586`, hardcoded in `spk_open` |
| 6 | Layer 2 | **Display P3 encoded**, `saturate()` at the end | `Shaders.metal:229-349` |
| 7 | canvas | `layer.colorspace = displayP3` | `MetalCanvasView.swift:692` |
| 8 | export | the same texture, tagged P3, then **Core Graphics `redraw`** into the recipe's space | `Exporter.swift:350-360` |

Steps 5–7 agree, which is why the picture is right. The defects are all at the
joins.

### 1.1 What is wrong with it

- **The narrowest space comes first.** Step 4 throws away everything P3 cannot
  hold, and steps 6 and 8 then work inside what is left.
- **Every grading move is clipped, twice.** Layer 2 ends in `saturate()`
  (`Shaders.metal:349`). Push saturation or a colour wheel and the excess is
  cut off at the P3 cube face — a hard edge, in the space where it is most
  visible.
- **A wide-gamut export cannot be wide.** `"TIFF 16-bit — ProPhoto"`
  (`ExportRecipe.swift:339`) converts P3-limited pixels into a ProPhoto
  container. The picker reads as a choice of gamut; it is a choice of box.
- **An sRGB export does not match the canvas.** `redraw` is a Core Graphics
  matrix conversion: it *clips*. The canvas was perceptually rolled into P3 by
  CAM16; the sRGB file is hard-cut. The earlier "export matches the canvas"
  result measured *tier* drift on the P3 path (`export-canvas-drift-is-downscaling`)
  and never covered output-space conversion.
- **Nothing declares any of it.** `params.hpp:211` still declares the default
  output as `"sRGB"`. `CONTRACT-frontend-backend.md` names no output space at
  all. The only colour label in the UI (`Session.swift:1388`) shows the
  *input* space, so the status bar reads "ProPhoto RGB" under a Display P3
  picture.

---

## 2. The decision

**One working space, one output transform, one conversion per destination.**

### 2.1 The working space is ProPhoto RGB

ROMM primaries, D50, the ROMM transfer function (γ1.8 with its linear toe) —
the space `CGColorSpace.rommrgb` names and the one the user asked for.

It is chosen over the alternatives for reasons that are all mechanical:

- **The engine already emits it.** `"ProPhoto RGB"` is a baked colourspace
  (it is the *input* default) and has a known CCTF (`colour.cpp:58`,
  `Cctf::ProPhoto`); `cctf_mode` gives it mode 1 (`pipeline.cpp:169`). Nothing
  in the colour core has to be added for the engine to output it.
- **It is a real, system-recognised space.** ColorSync resolves it, ImageIO
  tags with it, and a 16-bit file in it opens correctly in every other editor.
  A house space with ProPhoto primaries and an sRGB curve (Lightroom's
  approach) would grade identically and be unnameable on disk.
- **It holds the print.** Effectively every colour a print scan produces fits
  inside ProPhoto's unit cube, so `rgba16Unorm` storage stays exact and the
  `saturate()` at the end of Layer 2 stops being a gamut clip and becomes what
  it reads as: a guard against imaginary colour.

16 bits is not negotiable at γ1.8 over that gamut. The texture format is
already `rgba16Unorm` (`Renderer.swift:313`); it stays.

### 2.2 The engine's gamut compression aims at the working space

`output_gamut_compress` stays `cam16ucs`, retargeted from Display P3 to
ProPhoto RGB. It is close to a no-op — that is the point. It is kept rather
than switched off so that the one thing it still catches, a scan value outside
even ProPhoto, is rolled off rather than clipped into the unorm container.

### 2.3 Layer 2 moves into the working space, unchanged

The arithmetic in `layer2Tone` is not retuned. Only the numbers it is handed
change meaning, and one constant is introduced so that they do not:

> **Decision D1 — the tone pivot follows the encoding.** `layer2Tone` pivots
> contrast, the highlight/shadow weights and the colour-balance zone weights on
> the literal `0.5`. In Display P3's sRGB-like curve, mid-grey (0.18 linear)
> encodes to **0.4614**; in ROMM γ1.8 it encodes to **0.3857**. Left alone,
> every tone slider would silently pivot three-quarters of a stop higher after
> the move. A `midGrey` field is added to `Layer2Uniforms` and the pivots use
> it. Consequence: sliders pivot on actual mid-grey in *both* spaces, which is
> a small change against today even before the space moves. This is
> deliberate, it is the one behavioural change in this RFC, and it is the one
> line to revert if the user dislikes it.

### 2.4 A single output transform, at the end, per destination

A new Metal compute pass, **the output transform**, is the only place a
rendering space is left:

```
working (ProPhoto, encoded)
  → decode ROMM TRC            (engine's curve, ported)
  → 3×3 linear, chromatically adapted   (engine's matrix, over the ABI)
  → CAM16-UCS gamut compression into the TARGET   (engine's kernel, ported)
  → encode the target's TRC    (engine's curve, ported)
  → target (encoded), tagged with the system CGColorSpace
```

Every number in it comes from the engine's own colour data over a new ABI
(§5.2). Nothing is a second colour library in Swift.

The canvas runs it with target = Display P3, which is why the picture on
screen is expected to be *very close* to today's: CAM16 into P3 either way.
Export runs it with target = the recipe's space. The soft proof runs it with
the same target the export will, which is what makes the proof a proof.

> **Decision D2 — the transform is ours, not ColorSync's.** ColorSync is the
> authority for *what a space is*: every target is a `CGColorSpace`, every
> file is tagged by ImageIO, and the profile catalogue is still read from the
> system (`ExportRecipe.swift:installedRGBProfiles`). But the conversion
> itself is a matrix profile conversion, and a matrix profile has no
> perceptual table — ColorSync's only honest answer for an out-of-gamut colour
> is to clip it. That is defect §1.1 four. We do the transform on the GPU
> because we have a gamut-mapping step to insert into it that ColorSync cannot
> be given.

### 2.5 What this makes true

- A ProPhoto export contains ProPhoto gamut, because the compression aimed
  there.
- An sRGB export is perceptually compressed into sRGB, not clipped into it —
  and the canvas is no longer a promise the file cannot keep.
- Colour wheels, saturation, curves and masks act on ProPhoto values, so a
  push that exceeds the display rolls off at the display instead of being
  amputated before the user ever sees it.
- The export preview becomes load-bearing: the canvas is a P3 proof, and a
  recipe in another space is now genuinely a different picture. **This is why
  the export page is rewritten in the same change** (§6).

---

## 3. The chain as built (after this RFC)

| # | stage | space | owner |
|---|---|---|---|
| 1 | RAW decode | linear ProPhoto float32 | unchanged |
| 2 | engine ingest | `input_color_space = "ProPhoto RGB"`, no decode | unchanged |
| 3 | engine interior | spectral / densitometric | unchanged |
| 4 | engine gamut compression | CAM16-UCS **into ProPhoto RGB** | A |
| 5 | engine output | **ProPhoto RGB, CCTF encoded** — the working space | A |
| 6 | Layer 2, masks, curves, geometry | **ProPhoto RGB encoded** | A |
| 7 | **output transform** | working → target, with CAM16 into the target | A |
| 8a | canvas | target = Display P3; `layer.colorspace = displayP3` | A |
| 8b | export | target = the recipe's space; tagged, **no CG conversion** | A |
| 8c | soft proof | target = the recipe's space, same kernel, same uniforms | A renders, B shows |

The before/after texture (`Renderer.original`, from
`ImageDecoder.makePreviewTexture`, today rendered into Display P3 at
`ImageDecoder.swift:290`) moves to ProPhoto too, or the split-compare is two
different colour spaces either side of the line.

The histogram moves from the working texture to the **output-transformed**
texture. A histogram is a statement about clipping, and clipping is a property
of the destination, not of the working space.

---

## 4. Defects this closes

| | defect | closed by |
|---|---|---|
| 4.1 | The status line names the input space under a picture in another one (`Session.swift:1388`) | §5.4 — it names the working space and the display space |
| 4.2 | The display space is a hardcode in no contract (`engine.cpp:584`) | §5.1 — the contract states it; `params.hpp` agrees with it |
| 4.3 | Wide-gamut presets deliver a container, not a gamut | §2.4 — the compression aims at the recipe's space |
| 4.4 | sRGB export clips where the canvas rolled off | §2.4 — one perceptual transform, no `redraw` |
| 4.5 | Layer 2 clips every grading move at the P3 cube | §2.3 — it works in ProPhoto |
| 4.6 | The export sheet never shows the image | §6 — the soft proof is the centre of the new page |

§4.3 and §4.4 were predictions in the previous draft. They are no longer load-
bearing as predictions: the architecture removes the mechanism that caused
them either way. §7.2 still measures them, now as a before/after.

---

## 5. The build

### 5.1 The contract — `CONTRACT-frontend-backend.md`

**`CONTRACT-frontend-backend.md` belongs to nobody in particular, and this RFC
edits it.** Stated here as `CLAUDE.md` requires.

A new session invariant, in the field tables and the changelog:

> **Output colour space.** A session opened by `spk_open` renders to
> **ProPhoto RGB, CCTF encoded** — the working space. `io.output_color_space`
> in an open delta may override it; a caller that overrides it owns the
> consequences, because the frontend's output transform reads the session's
> *resolved* space and not a constant. The resolved space is echoed in the
> `open` reply's `params.io` and MUST be read from there.

`params.hpp:211`'s declared default changes to `"ProPhoto RGB"` so the header
and the behaviour stop disagreeing. `spk_open`'s convention block keeps its
comment and loses its surprise.

### 5.2 The new ABI — `spk_output_transform`

Everything the app's transform needs, from the engine's own colour data:

```c
/* The data an out-of-engine output transform needs to go from `src_cs` to
 * `dst_cs`: the chromatically adapted linear matrix, the two transfer-function
 * modes as `shaders/nodes.metal` numbers them, and the CAM16-UCS setup for
 * `dst_cs` — the same one `Pipeline::build` bakes, from the same cache.
 *
 * `out_json` is caller-freed with `spk_string_free`. `out_cmax` points into
 * the engine's own setup cache and is valid for the engine's lifetime; it is
 * not freed by the caller, exactly as `spk_print_lut_table`'s table is not. */
spk_status spk_output_transform(spk_engine* engine,
                                const char* src_cs, const char* dst_cs,
                                const char* gamut_compress_json,
                                char** out_json,
                                const float** out_cmax, uint32_t* out_cmax_count);
```

`out_json`:

```json
{
  "source_color_space": "ProPhoto RGB",
  "target_color_space": "Display P3",
  "source_cctf_mode": 1,
  "target_cctf_mode": 0,
  "matrix": [9 doubles, row-major, source linear RGB → target linear RGB],
  "gamut_compress": {
    "algorithm": "cam16ucs",
    "m_to_xyz": [9], "m_to_rgb": [9],
    "k": [22],
    "cmax_rows": 0, "cmax_cols": 0
  }
}
```

Construction, all from existing code, none of it new colour science:

- `matrix` — `Colour::matrix_RGB_to_RGB(src, dst, cat)` with the same `cat`
  the pipeline uses.
- `gamut_compress` — `SetupCache::cam16(colour, dst_cs, …)`, then exactly the
  `m2x` / `m2r` / `consts[22]` marshalling `pipeline.cpp:349-369` already does,
  with the same `GamutCompressSpec` parsing so `knee` and
  `lightness_compression` come from the session rather than from a constant.
  `algorithm: "off"` is legal and means the app skips the compression step.
- `cmax_rows`/`cmax_cols` are `l_grid.size()` and `h_grid.size()`, and
  `out_cmax_count` is their product.

A `dst_cs` the blob does not know fails with `SPK_ERR_USER` and a message
naming it. It does not fall back: falling back is how a picture ends up in a
space nobody asked for.

### 5.3 The kernel — `outputTransform` in `Shaders.metal`

```metal
kernel void outputTransform(texture2d<float, access::read>  src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant OutputTransformUniforms &u [[buffer(0)]],
                            device const float *cmax [[buffer(1)]],
                            device atomic_uint *stats [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]);
```

- The two transfer functions are **ported from `engine/src/shaders/nodes.metal`**,
  same four modes, same constants. Not rewritten from a spec: a second
  implementation of ROMM's linear toe is a second chance to get the
  breakpoint wrong, and nothing would say so.
- The CAM16 body is **ported from `engine/src/shaders/gamut.metal`**, buffer
  reads becoming texture reads and the three deliberate traps in its header
  comment carried over verbatim. That file's comment is part of the port.
- `stats[0]` counts pixels the compression actually moved (`d > threshold`)
  and `stats[1]` counts pixels that still hit 0 or 1 after encoding. Those two
  numbers are §6's warning and §7's measurement, and they cost one atomic on a
  branch most pixels do not take.
- When `algorithm == "off"`, the compression is skipped and `stats[0]` stays 0.

### 5.4 The app plumbing

- `Canvas/ColourManagement.swift` (new) — fetches and caches an
  `OutputTransformSetup` per (source, target) pair, uploads `cmax` once per
  target, and maps an `ExportColorSpace` to an engine colour-space name. A
  target the engine does not know is reported to the UI, not silently
  replaced.
- `Renderer.swift` — a `display` texture beside `adjusted`; the transform runs
  when Layer 2 is dirty or the target changed; `canvasFragment` samples the
  transformed texture; `renderOffscreen` and the histogram follow it.
- `Exporter.swift` — `render → applyLayer2 → applyGeometry → applyOutputTransform(target) → makeCGImage(space: target) → write`, and `write`'s
  `redraw` is reached **only** for a bit-depth change, never for a colour one.
- `Session.swift:1388` — the status line names the working space and the
  display space, and stops presenting the input space as either.

### 5.5 The seam between the two work streams

`Export/SoftProof.swift` is committed to the base branch *before* either
worktree starts, holding today's behaviour behind tomorrow's API:

```swift
struct SoftProof: Sendable {
    let image: CGImage            // already in the target space, tagged
    let target: CGColorSpace
    let targetName: String
    let compressedFraction: Double   // pixels the gamut map moved, 0…1
    let clippedFraction: Double      // pixels at the container's limits, 0…1
    let isPlaceholder: Bool          // true until the real transform lands
}

extension Session {
    func softProof(recipe: ExportRecipe, maxPixels: Int) async -> SoftProof?
}
```

The export page is built against this from the first line. The pixels stream
replaces the body; the UI stream never sees the change.

---

## 6. The export page

The current sheet (`ExportSheet.swift`) states in its own header comment that
it deliberately omits the image, "because the canvas behind this sheet is
already showing the frame at the grade being exported". §2.5 retires that
reasoning: with a per-destination transform the canvas is a P3 proof and
nothing more, and the recipes most likely to differ from it are exactly the
ones a user cannot check.

So the sheet becomes a page, and the page shows the picture.

**The UI is designed by the user (Hanze) and is not specified here.** The
reference layout is `modern_UI/reference_layout/Export_Page/` — its
`Reference_Screenshot.jpg` and the constraints in its `notes.md` are the
specification of the *layout*; this section is only what the page must be able
to *say*.

- The image, as the chosen recipe will write it — the soft proof of §5.5,
  honestly labelled as one, and visibly different from the canvas when it is.
- Which space the proof is in, and that the canvas is in another one.
- When the recipe cannot hold the picture: `compressedFraction` and
  `clippedFraction`, proportionately. A saturated frame into sRGB is worth a
  word; a frame that fits is worth silence.
- Grid and Viewer modes, multi-select, the naming tokens, the destination and
  the format — per `notes.md`, which is the authority on all of it.

---

## 7. Verification

1. **Regression, canvas.** The canvas before and after this RFC, same frame,
   same params, converted to a common space: report max ΔE2000 and the
   fraction over ΔE 2. Expected small and structural (CAM16 into P3 both
   ways, Layer 2 now upstream of it), **not** zero. A large number on a
   desaturated frame means the working-space move is wrong, not that it is
   visible.
2. **§4.3.** Export one saturated frame as ProPhoto TIFF, before and after.
   Measure the gamut volume of the file's contents. Before: does not exceed
   P3. After: does.
3. **§4.4.** Export the same frame as sRGB, before and after, and compare each
   against the canvas render converted to sRGB. Before: hard-clipped, a
   population of pixels pinned to the cube face. After: rolled off, no
   population at the face.
4. **§4.5.** Push saturation to the top on a saturated frame. Before: a flat
   clipped region. After: `stats[0]` non-zero, no flat region.
5. **Tier parity.** The numbers in `export-canvas-drift-is-downscaling` must
   be unchanged: this RFC does not touch the tier path, and if that moves,
   something else did too.
6. **The seam.** A soft proof and the file it proves, compared pixel for
   pixel at the same size, must be identical. If they can differ, the proof is
   decoration.
7. **The engine.** The existing parity harnesses (`engine/tests/`) must pass
   unchanged — §5.1 and §5.2 add a surface and retarget a parameter; they
   change no node.

---

## 8. Handoff

Three streams, one seam (§5.5), and the seam lands first.

| stream | owns | §§ |
|---|---|---|
| **A — pixels** | `engine/`, `Canvas/`, `Import/ImageDecoder.swift`, `Export/Exporter.swift`, `Export/SoftProof.swift`'s body, `Model/Session.swift`'s status line, `CONTRACT-frontend-backend.md` | 2, 3, 5.1–5.4, 7.1–7.5, 7.7 |
| **B — the export page** | `Export/ExportSheet.swift` and its replacement, `Export/ExportRecipe.swift`, `Windows/` presentation | 6, 7.6 |
| **integration** | the RFC, the worktrees, the build, the merge | — |

A must not edit the export page's view code; B must not edit the render path.
`Export/ExportRecipe.swift` is B's — anything A needs from a recipe goes
through `ColourManagement.swift`, which is A's.

**Do not "fix" what §1 got right.** The ingest space is a parameter and is
correct. `kMidgrayProbeColourSpace` stays sRGB (`AGENTS.md:868`). The tap
graph does not move. The engine keeps the spektrafilm name.
