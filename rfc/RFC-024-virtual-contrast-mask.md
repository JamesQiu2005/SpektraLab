# RFC-024 — Virtual Contrast Mask: fitting the negative onto unchanged paper

| | |
|---|---|
| **Status** | **Engine implemented 2026-09-23, off by default, no UI yet.** It is a regional gain map (§12.1). Every control is left to the user and no recommended values are calibrated (§12.5). §12 records what was built and what was measured. |
| **Decision** | RFC-023 and RFC-024 are two separate photographic operations. RFC-023 controls the scene's exposure ratios before making a negative. RFC-024 controls printing exposure after the negative exists, before paper development. Neither changes measured material profiles. |
| **Scope** | A neutral virtual contrast-reduction mask in the enlarger path; separate print-highlight and print-shadow control; its interaction with existing pre-flash, print exposure, cache, and striped execution. |
| **Not in scope** | Implementing ACR/C1, changing input decoding, moving RFC-023 into the print path, replacing EDR, altering film/paper curves, or shipping UI before the experiment supports it. |
| **Related** | RFC-023; RFC-020; `handoff/HANDOFF-SCENE-LATITUDE.md`; `handoff/HANDOFF-EDR-PRINT-PROFILES.md`. |

## 0. Product decision

> RFC-023：在曝光时控制光比，让场景进入胶片的有效响应范围。
>
> RFC-024：负片已经形成，在印相时控制光比，让负片已有的层次进入相纸的有效响应范围。

These operations answer different questions. They can be used separately or
together; neither silently enables or retunes the other.

The proposed path is:

```text
decoded input
  → [RFC-023: scene exposure placement]
  → film exposure / development / couplers / grain
  → cached negative
  → enlarger spectral projection
  → [RFC-024: virtual contrast mask]
  → existing paper pre-flash / print exposure conventions
  → unchanged paper characteristic curves
  → scan / existing EDR / output encoding / Layer 2
```

This is an exposure operation, not a synthetic wide-latitude paper. Its goal
is **more visible separation from information already in the negative**, not
an increase in the negative's recorded range or the paper's physical range.
Nothing after negative development can recover information already lost there.

## 1. Why a mask, rather than another output curve

The negative and paper have different useful exposure ranges. A negative can
retain density differences which a straight print sends into the paper's toe
or shoulder. Stretching the completed scan cannot recreate differences that
paper development has flattened to the same density.

A contrast-reduction mask changes the light reaching the paper before that
loss. A low-contrast reverse image attenuates the parts of the projection that
would otherwise expose the paper most strongly. Combined with a longer overall
printing exposure, it reduces the projected exposure range from both ends.

An unsharp mask can reduce broad tonal variation while retaining finer density
variation. This is the photographic motivation; it does **not** mean that a
large Gaussian blur is automatically the best digital implementation.

Kodak E-81N explicitly discusses contrast-reduction masking for overly
contrasty color negatives and long subject-brightness ranges. Its context is
dye-transfer printing, so it establishes the photographic precedent, not
performance evidence for this engine's chromogenic paper simulation. [S1]

## 2. What has and has not been established

| Evidence | What it supports | What it does not establish |
|---|---|---|
| Current `print_spectral` source | There is a distinct enlarger-to-paper boundary | A mask at that boundary improves photographs |
| RFC-023 curve probe, rerun 2026-09-22 | Global compression reduces small exposure differences; its dual-ended curve is a useful comparator | Those parameters or its scene-EV window transfer directly to paper exposure |
| RFC-023 §15–16, prior single-frame results | Pre-negative shadow placement can improve the resulting picture | The negative alone caused every observed color loss; those measurements include paper and scan |
| Base/detail literature | Compressing a base while retaining its residual is a viable contrast-management structure | Halo-free, noise-free, hue-invariant behavior in this pipeline |
| Existing physical pre-flash code | Additive paper exposure already exists independently of EDR | Its interaction with a new spatial mask has been tested |

The recommendation is to prototype and compare. **“Virtual Contrast Mask is
better” remains a hypothesis**, with a specific target: more final-print
texture separation at comparable subject lightness and print endpoints.

Do not reuse “8.5 stops”, “5.66 stops”, or a scene-derived color window as a
universal paper capacity. These depend on the measurement criterion and chain.
The fit here operates in **paper exposure**, not the scene coordinate of
RFC-023. Color and neutral-tone retention must be evaluated separately.

## 3. Current code boundary and a significant existing feature

As inspected on 2026-09-22:

- `Pipeline::print_spectral` calls `node_enlarger_spectral`,
  `node_print_exposure`, then `node_print_curves` before scanning.
- `node_enlarger_spectral` already returns **log10 paper-layer exposure**.
  Its three channels are paper-sensitive exposure channels, **not display RGB**.
- `spk_spectral_epilogue` computes the wavelength integral, applies a
  per-channel setup gain and additive offset, then takes the logarithm.
- `core/printing.cpp::print_constants` already derives a physical pre-flash
  offset from an illuminant, film base transmission, and paper sensitivities.
- `preflash_exposure` is already a native print-layer wire parameter, default
  zero. This observation does not claim that the current UI exposes it.
- `spk_print_exposure` multiplies the reconstructed exposure by the existing
  print-exposure gain before returning to log10.
- EDR runs on the completed linear scan, immediately before output encoding.

Consequently, inserting a common gain blindly between the existing enlarger
and print-exposure nodes would also modulate an already-added pre-flash.
That is not a uniform paper flash and is not the proposed physical model.

## 4. Exposure model and physical interpretation

Let `A_c(p)` be the projected image exposure at pixel `p`, including the
existing enlarger/filter/normalization setup gain, **excluding pre-flash**.
Let `F_c` be the existing pre-flash offset, and `P_c` the existing subsequent
print-exposure multiplier. Ignoring numerical epsilons, today's path is:

```text
E_c(p) = P_c · [A_c(p) + F_c]
```

The proposed mask path is:

```text
E'_c(p) = P_c · [2^δ(p) · A_c(p) + F_c]
```

This preserves the existing convention for `P_c` and `F_c`. It does not
redesign flash timing or the print-exposure slider as part of this RFC.

The same positive scalar acts on all three **image-exposure** channels.
It is equivalent to wavelength-neutral attenuation with an exposure
compensation, before paper response. It leaves the image exposure ratios
unchanged; it does **not** guarantee unchanged final hue or saturation.
Different paper-layer curves, pre-flash addition, and downstream processing
can change those.

### 4.1 A mask cannot emit light

For bounded desired gain `δ(p)` in stops, choose a constant
`C ≥ max(0, max_p δ(p))` and define:

```text
mask density D_mask(p) = [C − δ(p)] · log10(2) ≥ 0
mask transmittance T(p) = 10^(−D_mask(p)) ≤ 1
image exposure compensation = 2^C
2^C · T(p) = 2^δ(p)
```

Thus a signed digital gain has an interpretation as an attenuating mask plus
an increase in image exposure. Flash remains separate. This is an ideal
neutral-mask analogy, not a simulation of a particular masking emulsion,
registration error, or wavelength-dependent mask stock.

## 5. Candidate spatial construction

The first prototype should make the structure explicit and leave filter
selection open. Define positive reference exposures `A_ref,c` using a fixed
neutral reference through the same enlarger setup. One initial scalar is:

```text
x(p) = Σ_c w_c · log2[A_c(p) / A_ref,c],   w_c ≥ 0, Σ_c w_c = 1
b(p) = B[x](p)
d(p) = x(p) − b(p)
δ(p) = f(b(p)) − b(p)
x'(p) = f(b(p)) + d(p)
```

`B` is a documented spatial base extractor. Equal weights are an initial
experimental choice, not a calibrated luminance observer. There is no CIE Y
row for these paper-exposure channels. Compare this choice against a
normalized positive exposure norm on neutral and saturated patches before
freezing it. Floors used for numerical logs must not become meaningful image
signal; invalid or effectively zero image exposure requires a defined safe
policy and bounded gain, not division by a tiny number.

With a common multiplicative gain and zero flash, the chosen log scalar shifts
by exactly `δ` in exact arithmetic. `d` is retained in this decomposition.
It includes noise and any edges left out of the base, not just useful texture.

### 5.1 Two ends, named for the final print

For ordinary negative-to-paper printing the direction is inverted:

| Print control | Projected paper exposure | Desired change |
|---|---|---|
| Preserve print highlights | Low: dense negative transmits little light | Raise low-base exposure toward a useful paper response |
| Preserve print shadows | High: thin negative transmits much light | Lower high-base exposure away from paper Dmax saturation |

Do not copy RFC-023's scene-side highlight/shadow labels onto these branches.
An independent branch should be able to be disabled exactly. Separate controls
do not promise complete spatial independence or a fixed final-print midtone.

As one baseline candidate, use an identity core with independently controlled
lower and upper branches:

```text
g(Δ,H) = ΔH / sqrt(H² + Δ²)
f(b) = K_low  − g(K_low − b, H_low)    b < K_low
       b                              K_low ≤ b ≤ K_high
       K_high + g(b − K_high, H_high) b > K_high
```

This borrows an algebraic component from RFC-023, not its stage, fitted values,
or product meaning. Retain it as a candidate alongside the simpler traditional
base reduction `f(b)=m+(1−k)(b−m)`. Require non-crossing knees and bounded
positive and negative `δ`; the numerical limits remain experimental.

### 5.2 Detail needs room

A bounded `f(b)` does not bound `f(b)+d`. The fit must reserve room for
meaningful residual variation and inspect the recombined per-channel paper
exposures. Fitting only base percentiles and clipping the recombination would
defeat the feature's purpose.

Prototype a margin derived from robust residual statistics; report the
remaining overflow fraction. Do not promise every specular or noisy pixel will
fit. A final gentle guard is a separate candidate with a measured detail cost,
not a hidden repair to claim perfect retention.

Fixed-base residual preservation is an intermediate-domain fact. Paper slope,
scan, noise, and quantization determine whether those differences survive in
the output. A spatial operator also need not preserve brightness ordering
between pixels in different neighborhoods, even when `f` is monotone.

### 5.3 Spatial method is not selected yet

Compare a broad Gaussian mask as the traditional unsharp baseline with an
edge-aware base. Inspect bright/dark boundaries, small bright objects, broad
gradients and dense fine texture. Edge-aware filtering is a candidate defense
against halos, not permission to skip visual inspection.

Use image-relative scale, not an unexplained fixed pixel radius. No sharpening
or detail amplification belongs in the first prototype. Large-scale contrast
loss can still produce a flat print even when small-scale residuals survive.

## 6. Pre-flash and EDR remain separate

Physical pre-flash adds exposure before paper response. In a scalar example:

```text
x_flash = log2(2^x + F)
dx_flash/dx = 2^x / (2^x + F)
```

It compresses relative differences most at low paper exposures, while moving
those exposures into a potentially more responsive part of the paper toe.
Whether output separation improves depends on the composed paper response.
Excess flash may sacrifice clean whites or alter color. It is not a solution
to paper-shadow saturation at high exposure.

The virtual mask handles spatial image-exposure ratios; the existing flash
handles additive exposure; EDR remaps the finished scan. These are three
different operations. **Do not rename EDR “pre-flash”.**

First compare mask variants with flash and EDR off. Then test mask × existing
pre-flash, followed by EDR on/off. This isolates their contributions before
judging a combined look.

## 7. Proposed engine integration contract

1. **Default bypass is exact.** Disabled and zero-strength paths retain the
   existing spectral epilogue and downstream operations, including epsilons.
   Do not route old edits through a log/exp round trip merely to apply unity.
2. **Mask analysis uses image-only projection.** For enabled operation, expose
   `A_c` before the fused flash addition. Prefer deriving it directly; do not
   recover it by subtracting flash from a rounded/floored total exposure.
3. **Apply the mask before addition of flash and paper development.** The
   spectral accumulation may be shared, but the enabled epilogue must preserve
   the distinction between image exposure and additive flash.
4. **Reference corrections remain material references.** Do not derive the
   scanner black/white correction from each masked photograph, or silently
   auto-normalize the mask away. Audit the existing reference calculation and
   show the actual final result with normal corrections enabled.
5. **Direct negative scan bypasses this feature.** It does not print onto a
   paper. Unsupported positive/reversal print modes must be explicit; V1
   research covers ordinary negative-to-paper printing only.
6. **Film Exposure keeps its current contract.** Its existing enlarger
   compensation is not removed or absorbed into this feature. RFC-023 §15.4
   supersedes the earlier architecture audit's suggestion to zero it.

Likely implementation touchpoints, not changes made by this RFC:

| Area | Responsibility |
|---|---|
| `engine/src/core/params.*` | Print-classified mask parameters and validation |
| `engine/src/core/printing.*` | Image-only reference exposures; preserve existing flash and balance conventions |
| `engine/src/pipeline/pipeline.*` | Analysis lifecycle and enabled print execution |
| `engine/src/shaders/nodes.metal` | Common gain before flash, correct log10/stops conversion |
| Engine session/cache code | Versioned mask-analysis cache and negative reuse |
| Swift params/sidecars/print controls | Explicit opt-in state with backwards-compatible defaults |
| Engine tests | Bypass, unchanged negative, exposure invariants and striped determinism |

The engine stores log10 exposures; conceptual controls here use log2 stops.
For zero flash, a `δ`-stop gain adds `δ·log10(2)` to each log10 exposure.
For nonzero flash, adding that delta to the total is the wrong operation.

## 8. State, caching, and memory

All mask edits are **print-side** and must reuse an unchanged cached negative.
RFC-023 edits remain shoot-side and regenerate it. Changing the mask must not
change the negative hash, film grain realization, or film exposure parameters.

Tentative persisted controls: enabled, print-highlight amount, print-shadow
amount, spatial scale, and an algorithm version. Curve constants, analysis
semantics and fit policy must be versioned if they affect old renders. Exact
field names and slider units are deferred until the experiment settles them.

Mask analysis depends on negative identity, enlarger setup, geometry and the
defined spatial coordinate system. Application additionally depends on mask
controls, print exposure and flash. Paper-dependent automatic fitting must be
an explicit action; changing paper does not silently overwrite saved mask
strengths. Necessary re-analysis for the selected printing setup is distinct
from an automatic refit of user intent.

Unlike RFC-023's pointwise node, analysis here has neighborhood dependencies.
It must not be slipped into a striped pointwise stage as if it were band-pure.
The application of a prepared gain field can be pointwise.

Investigate a canonical reduced-resolution analysis of the **same cached
negative**, with a reproducible image-coordinate gain field and edge-aware
upsampling. Do not regenerate a different low-resolution negative just to
analyze it: grain/coupler/halation differences would confound the result.
Full-resolution base or detail planes are not an architectural assumption.
Reduced-resolution analysis is an approximation requiring measurement.

One canonical field must serve preview and export; it must not depend on
viewport zoom or independently fitted per-tier histograms. Strip evaluation
must read the same field using global coordinates. A crop policy and boundary
extension rule must be frozen and tested, rather than drifting with tile size.

No speed or memory improvement is claimed here. Measure peak footprint and
analysis/application time once a candidate exists; no large-image benchmark is
required merely to approve this research direction.

## 9. Minimum research experiment

Use Portra 400 + Portra Endura first. Keep the negative identical across print
arms. Disable stochastic effects for numerical comparisons; separately inspect
the default look. Existing RFC-023 single-frame results are not RFC-024 tests.

### 9.1 Small synthetic gate

Use textured low/high exposure patches, a neutral ramp, saturated patches, a
hard bright/dark boundary and a small bright feature. Compare:

- straight print;
- pointwise paper-exposure compression;
- Gaussian-base contrast mask;
- edge-aware-base contrast mask;
- existing pre-flash alone, followed by the selected mask plus flash.

Match subject/midscale print lightness and comparable endpoints before judging
detail. Match compression strength, not arbitrary slider values. Include a
control with deliberate excessive blur/strength so the halo metric and visual
inspection demonstrate they can detect failure.

Report final-print texture modulation at specified frequencies and patch
exposures, edge overshoot/undershoot, neutral balance, color difference, useful
paper exposure occupancy and residual overflow. Region-wide standard deviation
alone is insufficient: it mixes detail, broad gradients and noise.

### 9.2 Three photographs

Use a shadow-heavy portrait, a daylight high-contrast scene, and a scene with
strong specular/saturated highlights. Inspect full images and matched crops.
Determine whether the lost detail is present in the cached negative before
claiming recovery by printing. Keep subject exposure decisions fixed.

First test RFC-024 alone. Then one explicit RFC-023 × RFC-024 comparison checks
that scene placement and printing adaptation compose without hiding the
contribution of either operation. Input TIFF gamma/RAW comparisons are not
required for this print-stage experiment.

### 9.3 Acceptance before implementation is recommended

- More useful final-print texture separation than the pointwise comparator,
  without an unacceptable color, noise or halo cost at matched appearance.
- Exact bypass and unchanged negative; direct scan is unaffected.
- Common gain preserves image-exposure ratios before flash, within float32
  tolerance; no promise of exact final-color identity.
- Finite bounded behavior at black, extreme density, and saturated channels.
- Flash remains spatially uniform; test nonzero flash explicitly.
- Fixed-resolution strip/unstriped results are identical, or a precisely
  justified tolerance is agreed before implementation; no strip seams.
- Preview/export scale consistency is checked separately from bit identity.

Choose numerical visual-quality tolerances before judging candidate results.
Record failures and tradeoffs; do not select a threshold after seeing which
one makes the preferred algorithm pass. If only isolated patches improve,
report that limitation rather than concluding the approach is generally better.

## 10. ACR and Capture One: references, not the implementation

ACR's Highlights/Shadows versus Whites/Blacks, and Capture One's separate HDR
controls, are useful references for user expectations: regional recovery is
different from endpoint placement. Their behavior may be an external visual
comparison, but their processing order, private algorithms and slider values
do not define this RFC. [S4–S5]

The design here is derived from **negative projection, neutral masking, paper
exposure, and the unchanged paper response**. We are not implementing ACR or
C1 inside SpektraLab, nor treating their finished RGB output as the exposure
signal from which a mask must be constructed.

Durand–Dorsey and Local Laplacian research are mathematical references for
spatial contrast handling and edge behavior, not mandatory dependencies or
claims about current proprietary application implementations. [S2–S3]

## 11. Decisions to carry into the next session

**Fixed:** independent print-stage feature; negative untouched; material
profiles untouched; common neutral image-exposure gain; flash separate; EDR
separate; default off; research before product integration.

**Open:** exposure norm, base extractor, spatial scale, dual-branch curve,
gain limits, detail margins, fit objective, reference-correction interaction,
canonical analysis resolution, UI units, and algorithm-version persistence.

Next action: build only the small research harness needed to compare the
printing arms in §9. Do not begin with catalog changes, material rebaking,
production UI, or a replacement of RFC-023.

## Sources and local evidence

- **S1. Kodak E-81N**, *Using KODAK Pan Matrix Film*; “Masking for Reduced
  Contrast”, dye-transfer context.
  [Archived Kodak publication](https://daviddoubley.com/Documents/MakingDyesFromNegatives/E-81NDyePrintsFromNegatives.pdf).
- **S2. Durand & Dorsey, 2002**, *Fast Bilateral Filtering for the Display of
  High-Dynamic-Range Images*. Base/detail separation and the author's note on
  substituting a contrast-reduction curve for base scaling.
  [Author project and implementation notes](https://people.csail.mit.edu/fredo/PUBLI/Siggraph2002/).
- **S3. Paris, Hasinoff & Kautz, 2011**, *Local Laplacian Filters: Edge-aware
  Image Processing with a Laplacian Pyramid*.
  [Author project](https://people.csail.mit.edu/sparis/publi/2011/siggraph/).
- **S4. Adobe**, *Make color and tonal adjustments in Camera Raw*.
  [Official documentation](https://helpx.adobe.com/camera-raw/desktop/using/make-color-tonal-adjustments-camera.html).
- **S5. Capture One**, *The High Dynamic Range tool overview*.
  [Official documentation](https://support.captureone.com/hc/en-us/articles/360002610558-The-High-Dynamic-Range-tool-overview).
- **Local:** `engine/src/core/printing.cpp`, `printing.hpp`, `params.cpp`,
  `params.hpp`; `engine/src/pipeline/pipeline.cpp`;
  `engine/src/shaders/nodes.metal`; RFC-023 §15–16 and its handoff.

Documentation validation only in this session: source inspection and
`git diff --check`. No new engine, app, photographic or performance test result
is claimed by this RFC.

## 12. Engine implementation (2026-09-23)

### 12.1 What it is: a regional gain map

The feature is a **regional gain map**. Each region of the print gets one
common exposure gain, and the differences between pixels inside a region reach
the paper unchanged. It is not HDR. It cannot give every pixel an independent
brightness, and it must not try to.

A per-pixel gain is excluded by construction. If a pixel's gain depends only on
its own exposure, `x' = f(x)`, the result is a global tone curve on paper
exposure. That compresses texture by the same slope as the tones, which
measured as "greys everything" (§12.4). A tone curve applied after the print
is post-processing, and under the 2026-09-23 product positioning that belongs
to post-processing software, not to SpektraLab. Every SpektraLab edit is a
physical darkroom response. The per-pixel arm exists only as a research comparator
(`SPEKTRAFILM_MASK_POINTWISE`) and is not a user option.

### 12.2 What was built

The contract in §7 was followed. The existing print path gained only a branch,
and no existing kernel was edited.

- **Kernels.** `engine/src/shaders/contrast_mask.metal` holds two new kernels.
  `spk_mask_reduce` reduces the negative's **image-only** paper exposure to a
  grid of mean `x`. `spk_mask_epilogue` copies the spectral integral and
  applies `max(2^δ·A + F, 0)`, so the gain lands before the pre-flash
  (§4, §7.2–7.3).
- **Analysis.** `engine/src/pipeline/contrast_mask.cpp` runs once per print
  run, on the whole negative, after `print_prefix`.
  - **The grid follows the blur:** 4 cells per σ on the long edge, never
    fewer than 512 cells and never more than the frame's own pixels. A local
    blur therefore gets a fine grid. Grid and σ are fixed in normalised frame
    coordinates, so tiers agree, except where a small tier caps the grid at
    its own resolution.
  - **Base extractor:** a Gaussian on the grid (`a = 0`), or a self-guided
    filter whose `(a, b)` coefficients are applied to each pixel's own `x`.
  - **Edges:** a truncated, renormalised window at the frame edge.
  - **Curve:** §5.1's identity core plus `g₂` branches. `|δ|` is bounded
    by a smooth-min at 6 stops.
- **Pipeline.** `pipeline.cpp` got four small edits:
  - `print_spectral` picks the masked epilogue while a mask is prepared;
  - `run_print` and `run_print_striped` prepare and release the mask;
  - `run_stages_striped` records each band's first row;
  - the node count gains one.
- **Wire.** Six print-layer, non-live fields (API-SPEC §11). A mask edit
  reprints the cached negative and never re-develops it.
- **Bypasses.** Direct scan, a positive print material and `lut_mode` all
  bypass the mask (§7.5).

### 12.3 Gates

Measured with `rfc/probes/rfc024-vcm-probe.py` on `_DSC0897.NEF` (Z7 II,
Lower Manhattan at dusk), decoded as in RFC-023 §15 at 2400×1600, grain off.

| gate | result |
|---|---|
| mask off vs a build of `main` before this change | **byte-identical** |
| `active` with both amounts 0 | **byte-identical** |
| mask edit reuses the negative | `negative_was_cached = 1` |
| striped (97-row strips) vs un-striped, mask on | **byte-identical** |
| `parity_schema` / `parity_render` (27 cases) / `parity_setup` (227) / `strip_executor` / `gpu_smoke` | all 0 failures |
| numpy Gaussian on the dumped grid vs the engine's base | max diff 6e-8 |

### 12.4 What was seen

These are app defaults: Portra 400 + **Supra Endura**, `balanced` metering.
Every arm uses core 0 and both amounts 3. Texture is the mean
|L\* − blur₁.₅(L\*)|.

| arm | grid | shadows L\* / texture | highlights L\* / texture | midtones L\* |
|---|---|---|---|---|
| straight | – | 12.0 / 5.60 | 85.9 / 5.75 | 53.3 |
| Gaussian σ 0.03 | 512 | 11.1 / 5.51 | 83.2 / 7.34 | 51.0 |
| Gaussian σ 0.008 | 512 | 13.6 / 5.84 | 80.2 / 8.71 | 51.1 |
| Gaussian σ 0.004 | 1000 | 16.5 / 6.18 | 77.9 / 9.36 | 51.1 |
| Gaussian σ 0.002 | 2000 | 20.1 / 6.50 | 75.7 / 9.90 | 51.1 |
| per-pixel (comparator) | 2000 | 28.9 / 2.61 | 70.1 / 3.12 | 51.2 |

By eye (`output/rfc024_vcm_test/v3_local/` in the worktree that built this):

- **σ 0.03 (the wide, traditional mask):** it spills visibly. It darkens the
  sky around the skyline as a soft cloud. That is the look of the darkroom
  workaround, and it is kept for anyone who wants it.
- **σ 0.008 → 0.002:** the blown facades get their window grid back and the
  shadows open. The smaller the blur, the cleaner the edge. At 1:1 the smallest
  scale starts to read as crisp, and the texture number cannot separate
  recovered detail from edge enhancement.
- **Per-pixel:** washed flat everywhere.
- **Guided base:** at its fixed threshold, (0.5 stop)², it counted building
  texture as edge and behaved like the per-pixel arm.

The user's verdict: every scheme and scale has strengths and weaknesses, and
the right choice changes with the kind of photograph. That is a visual
judgement, not a number.

Retracted from the first draft of this section: "no halo is visible". The
near-edge ring metric looked 6 px from sharp edges and could not see a halo
the size of the blur. A sign-based spill metric did not see it either (1–3 %
at every scale). Judge halos by eye at the blur's own scale.

### 12.5 Decisions

- **Every control is the user's.** The scheme, the blur scale, the core, and
  each end's amount are adjusted directly. The engine does not choose among
  them per photograph.
- **No calibrated defaults.** The schema's defaults are placeholders: off,
  amounts 0, core 1, σ 0.03, Gaussian. With the amounts at 0 they do nothing.
  Recommending values needs a real calibration across photograph types, and
  that is deferred.
- **Done 2026-09-24, by the user's decisions:**
  - `edge_aware` became the `contrast_mask_scheme` enum, with `gaussian` as
    its only product value; the guided base is research-only.
  - The scale range narrowed to 0.002–0.12, measured in API-SPEC §11.
  - `spk_contrast_mask_field` hands the δ grid to the canvas.
- **Measured, in answer to §8's open question:** a mask edit on a 2560 px
  preview costs 24–25 ms against 18 ms without the mask (scale 0.008–0.12),
  and 61 ms at 0.002. The feature is not `live` on the wire, but it is fast
  enough to drag.
- **Not done:**
  - the Swift side and UI
  - §5.2's detail margin and overflow report
  - a versioned algorithm field
- **Probe display trap:** the engine's output is ProPhoto RGB. RFC-023's
  `result_to_rgb8` writes those codes into an untagged PNG, which every viewer
  reads as sRGB and shows with the wrong tone and colour. The RFC-024 probe
  converts to sRGB before writing.
