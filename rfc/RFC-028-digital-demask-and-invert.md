# RFC-028 — Digital de-mask and invert (去色罩): a scanner-style positive from the computed negative

| | |
|---|---|
| **Status** | **Implemented 2026-09-29 (§13)** as the print-list choice *Digital Intermediate / 数字中间片*, Cineon log, with an optional blue compensation (off by default). §1–§12 are the research, measured on the dylib at `cd62b78`; §7.3's cause was corrected after it (§7.4). The display tone curve is RFC-029's (research only). |
| **Author** | Overnight research session, at the user's request (§0). |
| **Branch** | `rfc-028-digital-scan`, worktree `filmify-rfc028`. |
| **Companion** | `rfc/probes/rfc028-demask-probe.py` reproduces every number in §4–§8. `rfc/figures/rfc028/` holds the frames in §8. |
| **Scope** | Where the orange mask lives in the model, whether it can be removed exactly, and what a deterministic "remove the mask, then reverse" output looks like. The film half — spectral sensitivity, halation, curves, DIR couplers, grain — stays exactly the product's. |
| **Out of scope** | Any change to the film model, the enlarger/paper path or the profiles. The display tone rendering the output needs (§6.3) is named as an open decision, not designed here. |

---

## 中文摘要

- **色罩在哪里。** 在这个模型里，色罩已经被拆成了两半，而且两半都是已知数据。
  - **随影像变化的那一半**（成色剂被消耗、抵消染料的副吸收）在建 profile 时已经折进了每个染料的“净”光谱里。这就是 README 说的“负吸收”：每个净染料的副吸收只剩峰值的 0–7 %（§4.2）。
  - **不随影像变化的那一半**就是 `base_density`，也就是橙色本身。
  - 所以“去色罩”在这里是**精确的、逐波长的**：去掉一项就够，不需要像 NLP 那样从画面里反推。
- **“跨层纠缠、去不掉”的担心，方向正好相反。** 色罩随影像变化的部分，恰恰是让各通道互不串扰的东西。去掉常数底色之后，窄带扫描下每个通道几乎只读到自己那一层（Status M 下 Portra/Ektar 串扰 ≤ 2 %，Vision3 ≤ 9 %，§5.1），逐通道反转是成立的。
- **反转必须用胶片自己的中性曲线。** 这条曲线在模型里是确定的。
  - 用它做反转，灰阶误差**恰好为 0**。
  - NLP/Cineon 式的“逐通道 gamma”在 ±4 档内有 0.08–0.43 档的偏色（§6.2）。negadoctor 专门有“阴影/高光偏色校正”滑块，原因就在这里。
- **保留下来的胶片特性：** 光谱感光、光晕、颗粒、DIR 成色剂。这个“数字扫描”的饱和度，大部分来自 DIR 成色剂：关掉以后色度从 ×1.06 掉到 ×0.58（§7.2）。
- **丢掉的是相纸：** 反差、相纸染料的色相签名，还有那一抹“Portra 味”的暖和天空偏青。结果是一张平、宽容度大的“扫描底片”（§8）。
- **必须补上的是显示端的影调**，这也是 NLP“tone profile”在做的事（§6.3）。还有一个待修的问题：高饱和的蓝会偏紫约 14°（§7.3）。

---

## 0. The question

> Now we need to digest how we can actually run the 去色罩 step by mimic the
> digital process. I'm still quite confused on where the orange mask gets
> involved and whether we can really remove it in the negative development
> calculation to get an output that if you simply reverse it you get a very
> digital, scanner like presentation of "film look", while keeping the
> halation, the film color tendency, the grain and other effects contact. The
> only problem is that it is involved in the different layer so it actually
> cannot be removed simply. My take is we might take some inspiration from NLP,
> yet in Negative Lab Pro, the information about white balance, and the film
> orange dye profile is reverse engineered from the scanned scene itself, yet in
> here everything's certain.

Three sub-questions, answered in order:

1. **Where does the mask enter?** §2 covers the physics and §4 the model.
2. **Can it be removed exactly, given it spans layers?** §2.3 and §5.
3. **What does "simply reverse" need, and what does it look like?** §6–§8.

---

## 1. Answer in short

1. **The mask is already separated in the model.**
   - Physically, a colour negative's masking couplers do two things. They add a constant orange density. They also cancel the unwanted absorptions of the image dyes, and that part varies with the image.
   - spektrafilm's profiles carry the second part *inside* the net dye spectra (`channel_density`, with the small negative lobes the README describes). The first part is `base_density`.
   - Removing `base_density` wavelength by wavelength is the exact de-mask. It takes no estimation.
2. **Crossing layers is not an obstacle; it is the reason a per-channel reversal works.**
   - With the constant part removed, a narrow-band scanner reads each channel almost entirely from its own layer: off-diagonals ≤ 2 % on Status M for Portra and Ektar, ≤ 9 % for Vision3.
   - A white-light camera scan reads 56–69 % of its red channel from the *magenta* dye (§5.1). The mask never promised to fix that; scanner choice does.
3. **"Simply reverse" is exact only with the film's own neutral curve.**
   - The model knows that curve, so the reversal is neutral to 0.000 stops.
   - NLP, Cineon and negadoctor have to reverse with a per-channel gamma or a single one. On the same negatives that leaves 0.08–0.70 stops of grey error inside ±4 stops (§6.2).
4. **The result keeps the negative's character and loses the paper's.** The kept tone is nearly straight across ±6 stops (§6.2), so the image is flat and wide like a real flat scan. A display tone rendering is therefore mandatory, and it becomes the main look decision (§6.3).

---

## 2. Where the mask lives

### 2.1 In film (Hunt, *The Reproduction of Colour*, ch. 15)

The image dyes of a colour negative are imperfect:
- magenta absorbs some blue;
- cyan absorbs some green and blue.

The *couplers* in the magenta and cyan layers are made coloured: yellow for magenta, reddish for cyan. Where dye forms, coupler is consumed, and the coupler's colour disappears exactly where the dye's unwanted absorption appears. With the right coupler density, the two cancel. The layer's net absorption outside its own band then stays constant whatever the exposure.

What is left:
- **a constant**: the orange of unexposed film (support + fog + unconsumed coloured coupler);
- **a per-layer net dye** that behaves as if the dye had no unwanted absorption.

The constant is removed by filtration: the enlarger's filter pack in analogue printing, or a per-channel gain in a scanner. The image-dependent part is *meant to stay*. It is a colour correction, and removing it would desaturate the picture.

### 2.2 In spektrafilm's profiles

The film is modelled as

$$D(\lambda) = \underbrace{D_{\text{base}}(\lambda)}_{\texttt{base\_density}} + \sum_{k\in\{C,M,Y\}} c_k\,\varepsilon_k(\lambda)$$

- `c` is the developed layer density (the `CMY_FILM` tap, Dmin-subtracted).
- `ε_k` is `channel_density`.
- The upstream README says: *"The presence of masking couplers is simulated with a negative absorption contribution in the isolated dye absorption spectra."* Its Portra 400 figures show the datasheet dyes (cyan ~0.25 in the blue) beside the profile's (cyan ≈ 0).

So the image-dependent half of the mask is folded into `ε_k` when the profile is built, and the constant half is `base_density`. Measured on the shipped files (§4.2), the net unwanted absorption is **0–7 % of each dye's peak**. The most negative lobe is −0.03 to −0.12, which is the over-compensation the README describes.

### 2.3 So what "cannot be removed simply" actually refers to

| part | physically | in the model | remove it? |
|---|---|---|---|
| constant orange (support + fog + unconsumed coupler) | the "mask" everyone sees | `base_density(λ)` | **yes — exactly, per wavelength** |
| image-dependent coupler consumption | cancels the dyes' unwanted absorption | folded into `channel_density` | **no** — it *is* the colour correction; removing it would un-mask the dyes |

The cross-layer entanglement exists in film chemistry. Profile construction has already resolved it into two terms that the pipeline carries separately.

The one thing a physical scanner cannot do, and this model can, is remove the constant **spectrally** rather than per channel. §5.2 measures when that matters.

---

## 3. How the digital world removes the mask, and what each method has to guess

| method | what it reads | how the mask goes | what it must estimate |
|---|---|---|---|
| **Cineon** (Kodak, 1990s) | printing density, 10-bit log | the base is code 95; log→linear divides by one negative gamma (0.6) | the base (measured on the film edge); one gamma for all three channels |
| **ACES ADX** (SMPTE ST 2065-3) | Academy Printing Density, 10/16-bit | density is encoded relative to the base | the unbuild to scene values, per stock |
| **darktable negadoctor** | the camera or scanner raw | picked Dmin colour, then log density per channel | Dmin, D max, the black offset, and **separate shadow and highlight colour-cast corrections** |
| **Negative Lab Pro** | a camera scan | base and levels from the frame or its border | everything, from the picture itself |
| **this model** | the computed negative | `base_density`, removed per wavelength | **nothing**: base, per-channel curves and mid grey are all known |

negadoctor's separate shadow and highlight cast sliders are what you need when the per-channel reversal is a power law and the three film curves are not scaled copies of each other. §6.2 measures exactly that error. The model removes it by construction.

---

## 4. Measurement: the mask in the shipped data

`rfc028-demask-probe.py mask`. The scan integral is validated against the engine's own `scan_film` render: max |Δ| **6.8e-4** on Portra 400 (1.3e-3 on Ektar). That agrees with RFC-022's 6.7e-4. It holds only when wavelengths with an undefined value are *dropped* the way `prepare_spectral_constants` drops them, not read as zero (§9).

### 4.1 The orange, as each scanner reads it (density)

The scanners:
- **Status M** and **LED** are stylised Gaussians: Status M at 645/530/445 nm, 30 nm FWHM; LED at 630/525/450, 22 nm.
- **Camera** is the Nikon D5100 (NPL) sensitivities under D50. This is the white-light DSLR-scan workflow NLP is built around.
- **Printing** is Portra Endura's own sensitivity under its enlarger lamp: the analogue of Academy Printing Density.

| film | Status M R/G/B | camera R/G/B | printing R/G/B |
|---|---|---|---|
| Portra 400 | 0.19/0.67/0.80 | 0.28/0.60/0.76 | 0.18/0.64/0.76 |
| Ektar 100 | 0.22/0.64/0.84 | 0.32/0.61/0.76 | 0.13/0.63/0.75 |
| Gold 200 | 0.25/0.64/0.95 | 0.34/0.62/0.80 | 0.22/0.65/0.83 |
| Pro 400H | 0.20/0.75/1.01 | 0.32/0.69/0.90 | 0.22/0.73/0.92 |
| Vision3 250D | 0.21/0.58/0.86 | 0.31/0.57/0.77 | 0.25/0.57/0.80 |

The Status M reading of Portra 400, 0.19/0.67/0.80, sits close to the datasheet's own Dmin (≈0.22/0.65/0.87).

### 4.2 The image-dependent half is already inside the dyes

Net unwanted absorption, as a fraction of each dye's own peak:

| film | C in blue | M in blue | M in red | Y in green | most negative |
|---|---|---|---|---|---|
| Portra 400 | 0.015 | 0.028 | 0.022 | 0.005 | −0.039 |
| Ektar 100 | 0.015 | 0.020 | 0.015 | 0.008 | −0.054 |
| Pro 400H | 0.008 | 0.009 | 0.044 | 0.008 | −0.052 |
| Vision3 250D | −0.010 | 0.018 | 0.071 | 0.006 | −0.068 |
| Vision3 500T | −0.025 | 0.027 | 0.065 | 0.038 | −0.119 |

---

## 5. Measurement: is a per-channel reversal enough?

### 5.1 Crosstalk after the base is removed

This is channel density per unit layer density, row-normalised. The off-diagonals are what a per-channel reversal cannot undo (`crosstalk`).

| Portra 400 | R ← M | G ← Y | B ← M | worst off-diagonal |
|---|---|---|---|---|
| Status M | +0.019 | −0.002 | −0.009 | 0.019 |
| LED RGB | +0.073 | −0.002 | −0.018 | 0.073 |
| printing | +0.179 | +0.066 | +0.056 | 0.179 |
| **camera, white light** | **+0.561** | **+0.179** | **+0.260** | **0.561** |

Ektar and Vision3 250D follow the same pattern: camera 0.60–0.69, Status M ≤ 0.09.

This is the scanning-practice folklore, measured: a white-light camera scan is where colour gets muddy, and the mask cannot prevent it. The mask fixes the *dyes*; the sensor's band overlap is a separate crosstalk that only narrow bands avoid. §7.1 shows what it costs: chroma ×0.72–0.79 against ×1.06–1.19 for printing density.

### 5.2 Removing the base per channel vs per wavelength

A physical scanner can only divide each channel by the base's reading. This model can remove the base wavelength by wavelength. Measured over the densities a real negative reaches (wedge −6…+6 stops plus the ColorChecker, `extras`):

| max \|Δ density\| R/G/B | Status M | LED | camera | printing |
|---|---|---|---|---|
| Portra 400 | .002/.012/.008 | .001/.013/.001 | .052/.114/.055 | **.138**/.038/.013 |
| Ektar 100 | .004/.008/.008 | .001/.008/.001 | .070/.110/.086 | **.139**/.036/.017 |
| Pro 400H | .001/.011/.006 | .001/.008/.002 | .069/.105/.092 | **.162**/.061/.012 |

- **Narrow bands:** the two are the same to within 0.015 D.
- **Broad bands:** they differ by up to 0.16 D. At a gamma of 0.55 that is 0.3 log exposure, about 1 stop, in the red of a dense patch.

This is the one place where "everything is certain" buys something no scanner can buy.

---

## 6. Measurement: reversing a grey wedge

### 6.1 The negative's own neutral curves

The wedge is 0.25-stop steps, taken through the engine with `export_di` (`wedge`).

| film | scanner | gamma R/G/B | D at grey R/G/B | responds |
|---|---|---|---|---|
| Portra 400 | Status M | 0.515/0.583/0.609 | 0.70/0.85/0.90 | −5.75 … > +8 |
| Portra 400 | printing | **0.545/0.568/0.577** | **0.78/0.84/0.86** | −5.75 … > +8 |
| Pro 400H | printing | 0.549/0.559/0.591 | 0.85/0.85/0.86 | −6.25 … > +8 |
| Vision3 250D | printing | 0.495/0.538/0.519 | 0.80/0.89/0.82 | −7.25 … > +8 |

In **printing density** the three gammas are nearly equal, and a grey sits at nearly equal density once the base is removed. That is what a negative is designed for: parallel curves *as the paper sees them*. The model reproduces the design intent, which is independent evidence that its masking is right.

### 6.2 Four reversals

Every method maps mid grey to 0.184. "Grey error" is the worst |log₂ R/G| or |log₂ B/G| in stops.

| Status M | grey error, film's full range | grey error, ±4 stops | tone at −6 / −3 / +3 / +6 |
|---|---|---|---|
| **cineon** (one gamma) | 0.81–1.45 | 0.46–0.70 | −4.93 / −3.18 / +3.20 / +6.32 |
| **per-channel gamma** (NLP-like) | 0.31–0.70 | 0.08–0.43 | −4.81 / −3.10 / +3.13 / +6.17 |
| **curve kept** (each channel onto green's curve) | **0.000** | **0.000** | −4.81 / −3.10 / +3.13 / +6.17 |
| **film terms** (each channel's curve inverted) | **0.000** | **0.000** | −6.00 / −3.00 / +3.00 / +6.00 |

The tone column is Portra 400. The grey-error ranges cover the five films in the probe.

- **Curve kept** is the answer to "simply reverse". Each channel's density is carried onto the green channel's neutral curve, then reversed with green's gamma. It is exactly neutral, and it keeps the film's own tone: a soft toe (−6 → −4.8) and no shoulder within +6 on Portra.
- **Film terms** is Kodak Photo CD's idea (Giorgianni & Madden): undo the curve completely. It is the most "digital" of the four.
- The two differ only in tone, and only in the toe. **The negative's curve is almost straight**, so a de-masked, reversed negative is a flat, wide image. Much of what reads as "film tone" in a print is the paper's.

### 6.3 What "simply reverse" still needs

The curve-kept positive is scene-referred and about 14 stops wide. On a display it needs a tone rendering: a toe, a shoulder, and a white point. That is NLP's "tone profile" and negadoctor's "paper grade / gloss". Once the paper is gone, this rendering is **the main look decision**. It should be designed with the user, not assumed.

The frames in §8 use a placeholder, for honesty: identity to +1.5 stops, then RFC-023's m=2 smooth-min on max(RGB).

---

## 7. Measurement: colour

**The colour step.** The reversed channels are the film's own white-balanced "RGB". A 3×3 matrix maps them to XYZ. It is fitted by least squares over the engine's own Hanatos upsampling spectra inside Pointer's gamut, with grey pinned. It is **not fitted to the chart it is judged on**.

**The chart.** ColorChecker, BabelColor average under D50, grey anchored to the chart's L\*. Differences are measured against the colorimetric chart (`colour`).

### 7.1 Summary (Portra 400; Gold 200 and Pro 400H agree, and Ektar's printing-density scan lands 0.9 ΔE further from the chart than its print)

| path | ΔE00 mean / max | chroma | \|Δh\| mean |
|---|---|---|---|
| print (Portra Endura), today | 6.53 / 12.56 | ×1.13 | 8.8° |
| scan, **printing density**, curve kept | 6.43 / 15.30 | ×1.06 | 7.4° |
| scan, Status M, curve kept | 8.29 / 19.75 | ×1.47 | 12.6° |
| scan, camera white light, curve kept | 7.28 / 19.83 | ×0.72 | 7.9° |

The printing-density scan sits as close to the chart as the print does, with slightly less chroma. Status M over-saturates, because no band overlap damps the DIR couplers' interlayer boost. Camera white light desaturates (§5.1).

**Printing density is the recommended scanner.** It is what the negative was balanced for (§6.1), and it is the logic ADX is built on.

### 7.2 Where the "film colour tendency" comes from

This is the mean chroma ratio on the 18 chromatic patches (`extras`). Grey is not re-anchored here, so the print reads ×1.12 where §7.1 reads ×1.13.

| | DIR on | DIR off |
|---|---|---|
| Portra 400 scan | ×1.06 | **×0.58** |
| Portra 400 print | ×1.12 | ×0.73 |
| Ektar 100 scan | ×1.20 | **×0.60** |

The DIR couplers make up about half the saturation of the digital scan. They live in the film half, so the scan keeps them.

### 7.3 Hue, patch by patch (Portra 400)

| patch | scan Δh / C | print Δh / C |
|---|---|---|
| dark skin | +7.8° / ×1.03 | +1.9° / ×1.70 |
| light skin | +4.4° / ×1.06 | +5.8° / ×1.06 |
| blue sky | +13.5° / ×1.24 | −8.9° / ×1.38 |
| foliage | +2.1° / ×0.82 | −18.8° / ×1.27 |
| blue | **+14.3°** / ×1.73 | −8.4° / ×1.14 |
| red | +10.6° / ×0.75 | +9.1° / ×1.04 |
| yellow | −11.3° / ×0.75 | −8.5° / ×0.98 |

The print's familiar signature (sky toward cyan, foliage toward yellow, rich dark skin) is the **paper's**; the scan does not have it.

The scan has one defect: **blue moves toward violet** (+14°). It is visible on the street sign in `frames_DSC2663.jpg`. The first explanation written here, "Portra's blue layer peaks at 400 nm and a 3×3 cannot put that back", was only partly right; §7.4 measures where it comes from.

Whether that is "film colour tendency" or a matrix artefact depends on the matrix. The matrix is a design choice, not physics. The range of options:
- an exact inverse through the upsampler, which returns the camera's own colour and so un-does the film's spectral response;
- the 3×3, which keeps the non-Luther residual;
- the paper.

This is the second decision for the user (§10).

### 7.4 Where the violet actually comes from (measured after §7.3)

The user suspected the spectral reconstruction of the input. That is part of it, and it is the smaller part:

- **The reconstruction does push energy into the violet.** For the ColorChecker's blue patch, the Hanatos metamer puts **44 %** of its energy below 430 nm; the real paint puts 11 %. Portra's blue layer peaks at 400 nm.
- **Upstream already compensates at the input.** Every profile carries a spectral window that cuts the film's sensitivity below about 433 nm (×0.14 at 400 nm on Portra). The engine applies it by default (`apply_hanatos2025_adaptation_window`).
- **At the exposure stage, the metamer accounts for about 4°.** Blue patch, Portra 400, film exposures through the 3×3: real reflectance +1.2°, Hanatos metamer +5.3°, even without the window.
- **The rest appears downstream:** DIR couplers, the film curves and the scanner's crosstalk take it to +13° and chroma ×2.06. The paper path takes the same input to −8°.

So it is an artefact of this path, not a film trait. The user's decision (2026-09-29): leave the window alone, since re-tuning it only swaps one mapping for another, and compensate after the film, optionally, off by default (§13.3).

The reconstruction also *smooths away* real film quirks, in the other direction: a real red paint shifts +29.6° on Portra at the exposure stage, and its metamer +9.9°. A RAW never recorded the spectrum, so that part of "film colour" is out of reach anyway.

---

## 8. What it looks like

Each strip in `rfc/figures/rfc028/` shows, left to right:
1. the camera frame through the same placeholder display;
2. the negative scanned as the product does it today (`scan_film`, orange);
3. the negative with `base_density` removed (still not neutral to the eye, see below);
4. the digital scan, curve kept;
5. the digital scan, film terms;
6. today's print on Portra Endura.

All are Portra 400 with grain, halation and DIR couplers on, auto exposure the engine's.

- **Panel 3 is not grey, and that is correct.** The base is gone, but the negative's dyes were designed for the paper's eyes, not ours. The cyan dye peaks at 695 nm, where the eye barely sees, so a de-masked grey looks pink-beige on a light table. That is why the reversal happens in the *scanner's* channels, never in the eye's.
- **Grain and halation survive.** `detail_DSC00185_camera_scan_print.jpg` shows grain in the white stripes and the red halation fringe around the neon in both the scan and the print. Both come from the same `CMY_FILM`.
- **The scans are flat.** That is the §6.2 finding, visible: no paper contrast.
- **Saturated highlights dim in the scans.** That comes from the placeholder display compressing on max(RGB), not from the method.

---

## 9. Side finding: the film base is undefined above 700 nm, and the enlarger integral drops it

This is not part of the question, but it came out of validating §4.

Portra 400's `base_density` is NaN at 380–395 nm and **705–780 nm**. `prepare_spectral_constants` zeroes the *whole* wavelength wherever any input is NaN. That is correct for the scan, but it also removes those wavelengths from the **enlarger integral** (`printing.cpp:103`), and the paper's red sensitivity peaks at 705 nm.

Share of the paper's red-channel enlarger weight that is dropped:

| film | R | G | B |
|---|---|---|---|
| Portra 400 | **26.9 %** | 0.6 % | 1.1 % |
| Ektar 100 | **51.1 %** | 0.7 % | 1.8 % |
| Pro 400H | 6.4 % | 0.6 % | 1.1 % |
| Vision3 250D | 0.1 % | 0.7 % | 1.8 % |

The Python reference does the same, so parity holds, and the neutral print filters are calibrated under the same truncation, so greys are unaffected. How much it moves the print's reds has not been measured. It belongs in `engine-open-items`, not this RFC. It is recorded here because it will look like a bug to whoever implements §10 with the printing-density scanner.

---

## 10. Proposed shape, if the user wants it built

**A "Digital scan" output mode**, alongside the paper list and today's "no paper (negative)". It replaces the three `printing.*` nodes. The film segment is untouched.

1. **`scan.digital_density`** (pointwise): the existing `spk_spectral_epilogue` with a zero base buffer and the printing-density `ixs`, `log_out` on. That gives three channel densities with the mask removed per wavelength. It is the kernel the enlarger already runs, so no new kernel is needed.
2. **`scan.reverse`** (pointwise): a per-channel 1-D table from density to linear positive, the "curve kept" map of §6.2.
   - It is baked at build time from a neutral wedge through the film curves. It depends on the film, the scanner and the DIR setting, not on the image.
   - Mid grey is anchored by the metered exposure, as today.
3. **`scan.film_to_xyz`**: the 3×3 of §7, baked per film. Then the working-space conversion and output, as today.
4. **Display tone rendering**: undecided (§6.3).

**Cost.** One spectral integral instead of two, plus a table lookup. It is cheaper than printing, and the film cache is reused unchanged, so it switches like a paper change.

**Controls.**
- *Print exposure* becomes the digital exposure.
- The *Y/M filter shifts* become per-channel density offsets: the scanner's white balance.
- *Pre-flash* and print glare do not apply.
- The **contrast mask** (RFC-024) acts on enlarger log exposure today; it would move onto the scanner densities, where it means the same thing.
- **DI export** needs a decision, because its LUT is paper-specific.

**Decisions that belong to the user before any code:**
1. **The display tone rendering (§6.3).** It is now the main look lever.
2. **The colour step (§7.3).** The 3×3 (keeps the film's spectral character, blue goes violet), a better-fitted 3×3 or root-polynomial, or the exact inverse (camera colour back).
3. **Whether the scanner is a user choice.** Printing density is recommended; Status M ("punchy lab scan") and white-light camera ("muddy DSLR scan") are real, physically meaningful variants the probe already models.

---

## 11. Reproduce

```
cd filmify-rfc028
engine/build.sh dylib
PY=../spektrafilm/.venv/bin/python           # numpy, colour-science, rawpy, OpenImageIO
$PY rfc/probes/rfc028-demask-probe.py mask
$PY rfc/probes/rfc028-demask-probe.py crosstalk
$PY rfc/probes/rfc028-demask-probe.py validate   # must stay below ~1e-3
$PY rfc/probes/rfc028-demask-probe.py wedge
$PY rfc/probes/rfc028-demask-probe.py colour
$PY rfc/probes/rfc028-demask-probe.py extras
$PY rfc/probes/rfc028-demask-probe.py images OUT FRAME_lin.npy ...
```

The frames were decoded with rawpy (`half_size`, linear, camera WB, ProPhoto) from `spektrafilm/tests/Test_image/`. The probe box-averages them to ≤ 1800 px.

**Guard that fired while writing this.** `validate` first read 2.0e-3 on Portra and 6.7e-3 on Ektar, with a structured per-channel residual. The cause: NaN wavelengths were read as density 0 instead of being dropped. The fix brought it to 6.8e-4. That residual is also what surfaced §9.

## 12. Sources

- R. W. G. Hunt, *The Reproduction of Colour*, 6th ed., ch. 15 (colour negative masking).
- E. J. Giorgianni, T. E. Madden, *Digital Color Management*, 2nd ed. (printing density, film terms, Photo CD).
- Upstream spektrafilm README, "masking couplers … simulated with a negative absorption contribution".
- Cineon: [Cineon (Wikipedia)](https://en.wikipedia.org/wiki/Cineon); [Kodak, *Conversion of 10-bit Log Film Data to 8-bit Linear*](https://www.dotcsw.com/doc/cineon1.pdf). Base at code 95, reference white 685, negative gamma 0.6.
- [SMPTE ST 2065-3, ADX](https://ieeexplore.ieee.org/document/9286953); [ACES ADX documentation](https://docs.acescentral.com/encodings/adx/).
- [darktable negadoctor manual](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/negadoctor/).
- Prior in-tree attempt, which this RFC supersedes in method: `spektrafilm/scripts/scan_negative_demasked.py` (von Kries on the base white, no reversal) and PRD-callable-render-api Appendix A.

---

## 13. What was built (2026-09-29)

The user accepted §10 as "the DI we actually want" and chose **Cineon log** for the canvas and the export until RFC-029's tone curve exists.

### 13.1 Engine

- **`core/digital_intermediate.{hpp,cpp}`**, built per film at pipeline build (about 10 ms):
  - **Printing density.** The film's `target_print` paper sensitivity under that paper's lamp. It is loaded as `Params::di_paper` whatever paper the session shows, so the DI does not depend on a hidden choice.
  - **The neutral wedge.** −14 to +14 stops in 0.05-stop steps, run on the host through exactly what a flat field meets: the pipeline's own `tc_b` and tc_lut, the curves and the DIR couplers.
  - **The "curve kept" reversal (§6.2)**, as one table per channel with the same output column, so a grey is neutral at every exposure.
  - **The 3×3 of §7.** It is fitted through the same film eye the tc_lut uses, including the window.
  - **The blue fit** (§13.3).
- **Per pixel, three kernels.** The existing `spk_spectral_epilogue` with a zero base, the existing `spk_curves`, and the new `spk_di_encode`, which does the matrix, the optional compensation and `code = (685 + 300·log10 x) / 1023`. Everything after the paper is skipped: glare, the scan, gamut compression, EDR and the transfer function.
- **Wire.** `digital_intermediate` and `digital_intermediate_blue_compensation`, both print layer and native-only (`parity_schema.py`). `scan_film` wins, and a positive film ignores the DI.
- **Live print controls.** Print brightness is one true stop per stop. Y/M are matched to the print's measured mid-grey response: +1 gives +0.05 stop of blue, and +0.03 stop of green.
- **Scene Latitude** decodes the codes, so its readout is the DI's own range.

### 13.2 Verified

| | |
|---|---|
| neutral wedge −8 … +8, four films, through the dylib | ≤ 0.0022 stop |
| mid grey | code 0.4540 (Cineon for 0.184), exact |
| striped vs whole frame | bit-identical |
| `parity_render` (the print path is untouched) | 27 cases, 0 failed |
| `parity_schema`, `parity_setup` (the tc_lut weight refactor) | 0 failures, 227 quantities |
| app suite | 473 tests; the one failure was the pinned wire-name list, updated |
| the neutrality test fires | per-channel reversal mutated in: 0.03–0.28 stop errors, failed |

The latitude readout on `_DSC2663`: 11.32 stops held (−5.49 … +5.84), 99.1 % of the frame inside.

### 13.3 The blue compensation (optional; Settings ▸ Rendering; off by default)

It is camera-independent by design: cameras cannot be calibrated one by one, but this chain can.

At build, synthetic blues are generated in Oklab around the blue–violet sector and run through the host film and the DI at 0 EV. The engine then fits one hue rotation and one chroma scale per film, weighted on the output. In the kernel it acts only inside a raised-cosine window (hue 280° ± 55° Oklab) above a chroma floor, so greys and every other hue are exact.

| ColorChecker, through the dylib | DI | DI + compensation | print |
|---|---|---|---|
| Portra 400: blue Δh / chroma | +13.0° / ×2.06 | **+1.5° / ×1.16** | −8.4° / ×1.14 |
| Portra 400: ΔE00 mean | 6.14 | **5.08** | 6.60 |
| Pro 400H: ΔE00 mean | 4.52 | **3.84** | 6.95 |
| Ektar 100: blue Δh | +17.8° | +5.7° | −7.5° |

Skin, foliage and red are unchanged to 0.1°.

### 13.4 Known limits

- **The Cineon ceiling clips highlights.** 10-bit Cineon holds −5.1 … +6.2 stops around grey, and Portra reaches +7.3 at scene +8 (found by the RFC-029 session, confirmed: +7 and +9 both encode to 1.0). A wider log would hold it and lose the standard Cineon decode. That is the user's call.
- **The canvas shows the log codes as ProPhoto values**, as the rest of the app shows its working space. ProPhoto's blue primary is deep violet, so a saturated blue reads more purple on the canvas than it is (with the compensation on, blue-violet). The export writes the same codes unchanged, tagged ProPhoto, so file = canvas and a Cineon decode returns the scene. RFC-029 recommends the canvas show the tone-mapped DI instead.
- **Post-Dev (Layer 2) and local masks do not apply to a DI**, on the canvas or in the file. It is a master for grading elsewhere.
- **The Tone Mask (RFC-024) does not apply.** It is defined on the enlarger's log exposure.
- **The old "Digital Intermediate Package" export format** (negative + paper `.cube`) is untouched and now shares a name with this. Rename or retire it: a decision for the user.

### 13.5 Revision, the same day: a true Cineon master, and a ProPhoto canvas

The user's model, adopted:
- **Inside the app everything is ProPhoto RGB.** The canvas, the Navigator and the thumbnails read the DI through one Cineon → ProPhoto table.
- **The export is the DI, in Cineon log.** Any Cineon-aware LUT then works on it.

**Encoding, now exactly Kodak's**, as colour-science `log_encoding_Cineon` implements it (formula difference 0.0):

`code = (685 + 300·log10(L(1−b) + b)) / 1023`, with `b = 10^((95−685)/300)`

`L` is the positive with the film base subtracted, so:

| | before (§13.1) | now |
|---|---|---|
| clear film base | code 22 (−4.9 st, "lifted") | **code 95.00, Cineon black** |
| mid grey | code 464 | 464.6–467.9 (colour-science puts 0.18 at 467.8) |
| decoded mid grey | 0.184 | 0.175–0.180 (0.184 less the base's positive) |
| standard Cineon decoder | shadows below its black: crushed | returns `L`; neutral to 0.0002 st |
| top of range | +6.2 st | ~+6.2 st (unchanged: the 10-bit ceiling) |

**What changed in the picture.** Making the base black is what every Cineon decoder assumes, and it darkens the deep toe. On Portra 400, scene −3 st now decodes to −3.55 st. The codes still hold the separation.

**The canvas.** The Layer 2 pass reads a DI through a 4096-entry Cineon → ROMM table (`Canvas/CineonLUT.swift`, interpolated by hand), with no grade and no mask. The purple of §13.4 is gone: it came from showing log codes as ProPhoto values. The view is scene-linear with no tone curve, so highlights above reference white clip on screen; that is RFC-029's job.

**The export.**
- The file is the engine's codes, 16-bit, **untagged**. The EXIF `ColorSpace` is set to Uncalibrated, because a camera's `sRGB` tag otherwise makes ImageIO name an sRGB profile. The new export test caught this.
- **Two `.cube` files are written beside it once per folder:** Cineon → ProPhoto RGB, and Cineon → Rec.709 γ2.4.
  - Both are 3D 65³, because Photoshop reads no 1D `.cube`.
  - Against the exact curve: mean error 0.04 of an 8-bit step; worst 2.1 steps, at the clip corner (code 685).
  - The Rec.709 matrix is ProPhoto → BT.709 (Bradford), rows normalised so grey stays grey.

**Scene Latitude** reads the codes on their own log scale, without the black offset (with it, the base's 0 leaves no boundary). The frame reads 10.97 stops held.

**Verified:** app suite 476 tests, 0 failures, including `DigitalIntermediateExportTests`, which exports a real ARW as a DI and checks the untagged 16-bit file, the base at ≥ 94, a mid-range median and both LUTs.


### 13.6 Second revision: one DI path, a view that keeps the highlights, nothing new to copy

Three decisions by the user (2026-09-29):
1. Delete the old DI path and keep the one true Digital Intermediate (option B).
2. The highlights matter: the dynamic range is kept, but the plain Cineon → ProPhoto decode clipped it on screen.
3. The DI path introduces no new copyable parameter. Only the grey paper effect and Scene Placement go, and the Tone Mask goes too, for this release.

**Option B: the export.**
- The *Digital Intermediate* export format is `spk_render_digital_intermediate`: a Cineon 16-bit TIFF (`<stem>_DI.tif`) plus the two view `.cube` files.
- It works for any negative frame, whatever paper is chosen.
- It renders its own full-tier pipeline from the session's negative. It is bit-identical to a DI print, and the session's paper render is untouched (0 difference with glare off).
- Slide films are refused.
- JPEG, TIFF and PNG export what the canvas shows, DI frames included, through the ordinary Layer 2 route.
- Removed: the old "Digital Intermediate Package" writer (`exportDI` / `writeCube` in the app). Its recipe names are read as legacy aliases.
- `spk_export_di` stays in the C ABI as a research tap, for `parity_lut.py`, the RFC-022 solver and this RFC's probe.

**The DI view: RFC-029's findings, placed in the LUT instead of the engine.** The view `Canvas/CineonLUT.swift` runs four steps:
1. Decode the Cineon.
2. Apply a tone scale on luminance (ProPhoto Y), as `x·T(Y)/Y`.
   - It is identity up to a *solved* knee, then RFC-023's m = 2 smooth-min shoulder.
   - The knee is the softest one that lands the file's top code (+6.2 st) 1/16 stop under white: **0.9203 st over grey 0.18**.
   - Contrast is 1.0, so grey and everything below the knee are unchanged.
3. Take a path to white at constant Oklab L and hue.
4. Encode ROMM, or Rec.709 γ2.4.

The shipped files are baked, not written at export time:
- `Resources/DI/SpektraLab DI view, Cineon to {ProPhoto RGB, Rec709}.cube`, 65³, 7.4 MB each.
- The canvas samples the ProPhoto file as a 3D texture in the Layer 2 pass (texture 4, `inputDecode`).
- `testTheShippedViewLUTsAreCurrent` fails if the code and the files drift apart. Regenerate them with `TEST_RUNNER_SPK_REGEN_DI_LUTS=1`.

What RFC-029 proposed and was **not** taken:
- the engine node;
- the Contrast control (default 1.3);
- any wire field.
The view has no parameters, so the canvas and the shipped LUT cannot disagree.

**Post-Dev applies to a DI.** Layer 2 runs on the decoded view, like any other frame. The navigator and the thumbnails use the view alone.

**Gated on a DI frame:**
- **Scene Placement** is greyed with a reason, and `scene_latitude_active` is false on the wire. It moves the print's placement, and a DI has no print.
- **Print Effects** and **EDR** remain greyed as before.

**The Tone Mask is withdrawn** behind `FeatureFlags.toneMask = false`:
- its section is hidden;
- `contrast_mask_active` is off the wire whatever a sidecar says;
- the clipboard offers no mask group while no mask flag is on.
The engine node and its tests remain.

**Verified:**
- app suite 473 tests, 0 failures (plus one pinned expected failure);
- `parity_schema` 0 failures;
- a live snapshot of a Portra 400 DI frame shows the sky whole, Latitude reading 10.97 stops held, and Scene Placement greyed.

**Open:**
- The file's ceiling is still +6.2 st: Cineon's 10-bit range.
- The DI's constants (~11.6 ms) are rebuilt, not cached, when the film changes.
- The app bundle grows by 15 MB for the two `.cube` files.
