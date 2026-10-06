# RMS granularity: what the number is, and how it maps to the engine

2026-10-06. Answers `research.md`. Source: `f4017_TriX.pdf` (Kodak F-4017, Feb 2016), p. 6, "Image Structure".
Probe: `rfc/probes/rfc030-model-rms.py` (plain python3, reads the profile JSONs, no engine needed).
Nothing in the engine was changed.

## 1. What the sheet says

> Diffuse rms granularity: TRI-X 400 — 17 (fine). Read at a net diffuse density of 1.0, using a
> 48-micrometre aperture, 12x magnification. Development in HC-110 (Dilution B), 68°F.

- A uniformly exposed, developed patch is scanned with a microdensitometer whose aperture is a
  48 µm circle. The **standard deviation of the density readings**, times 1000, is the number.
  So 17 means **σ_D = 0.017** at that aperture.
- "Net density 1.0" is 1.0 above base + fog. It is one point on the curve, well above mid-grey on a
  negative.
- "Diffuse" means the reading is expressed as diffuse density (Callier-corrected).
- "12x" is the viewing magnification the 48 µm aperture stands for. It does not enter the maths.
- The value belongs to that developer. Push processing or another developer moves it.

## 2. The one law that makes it usable

Grain is spatially uncorrelated above the grain's own size, so averaging over an area A divides the
variance by A (Selwyn):

    σ_D² · A = constant

48 µm circle: A = π·24² = **1810 µm²**. Tri-X: σ_D²·A = 0.017² × 1810 = **0.523 µm²**.

So the sheet number converts to any pixel size. It is a film-plane quantity and does not depend on
format; format only enters through `pixel_size_um`, which the engine already computes.

| Pixel on film | σ_D per pixel (before any blur) |
|---|---|
| 48 µm aperture | 0.017 |
| 12 µm (36 mm / 3000 px) | 0.060 |
| 6 µm (36 mm / 6000 px) | 0.121 |
| 4 µm (36 mm / 9000 px) | 0.181 |

Sanity check with Nutting's formula for silver, σ_D² = 0.434·D·a/A: a = 1.2 µm², a grain about
1.2 µm across. That is a believable 400-speed cubic grain.

## 3. What the engine's model does with it

`layer_draw` (`engine/src/shaders/spk_common.h:184`) and `grain_realise`
(`engine/src/pipeline/pipeline.cpp:1251`), per channel and sub-layer:

    X ~ Poisson(n·p / sat),  value = X · (dmax/n) · sat,  p = d/dmax,  sat = 1 − u·p
    n = px² · fraction / area,  area = particle_area_um2 · particle_scale[ch] · particle_scale_layers[sl]

Mean is d. Variance per pixel (checked by Monte Carlo in the probe, 0.03826 vs 0.03825):

    σ² = d · (dmax/n) · (1 − u·d/dmax)

`dmax/n` carries 1/px², so the model **already obeys Selwyn's law**. Through an aperture A:

    σ_D²·A = Σ_sublayers  d_sl · (Dmax_total · area_sl) · (1 − u·d_sl/dmax_sl)

Consequences:
- RMS granularity ∝ **√particle_area_um2**. One scalar per film sets it.
- RMS also ∝ √Dmax. A film with a higher Dmax is grainier in the model with no other change.
  This is why the push profiles and the slides come out grainier below.
- The density dependence, D·(1 − u·D/Dmax), is the model's own. The sheet gives one point and
  cannot confirm that shape.
- The 0.65 px grain blur and the dye-cloud blur are far smaller than 48 µm at export sizes, so
  they change the look of the grain, not this number.

## 4. What the current globals imply (probe output)

RMS ×1000 at net D = 1.0 in each channel, 48 µm aperture, `particle_area_um2 = 0.2`:

| Film | R | G | B |
|---|---|---|---|
| Vision3 50D / 200T / 250D / 500T | 7.2–9.0 | 7.1–8.5 | 12.4–14.0 |
| Portra 160 / 400 / 800 | 7.5–9.0 | 7.0–7.4 | 13.0–13.8 |
| Portra 800 push 1 / push 2 | 10.6 / 12.0 | 8.6 / 9.5 | 15.1 / 17.4 |
| Ektar 100, Gold 200, UltraMax 400, Verita 200D | 8.1–8.8 | 6.9–7.4 | 11.9–14.4 |
| C200, X-Tra 400, Pro 400H | 7.2–10.7 | 6.5–10.5 | 13.9–21.5 |
| Provia 100F, Velvia 100, Ektachrome 100, Kodachrome 64 | 12.5–15.3 | 13.5–15.5 | 16.7–22.0 |

Read: every negative sits at about 7–10 in green whatever its speed (50D = 500T), and the slides
are the grainiest films in the app, purely because their Dmax is highest. Real slide films are
among the finest-grained.

## 5. Translating a sheet value

For a single-channel (B&W) film with one layer, u = uniformity, target RMS R at net density D:

    particle area (effective) = (R/1000)² · 1810 / ( D · Dmax · (1 − u·D/Dmax) )

Tri-X, R = 17, D = 1.0: area = 0.523 / (Dmax·(1 − u/Dmax)).
Dmax must come from the Tri-X characteristic curve used for the profile (HC-110 B for consistency
with the granularity figure). **Illustration only**, with Dmax = 2.5 and u = 0.97: 0.34 µm².

For an existing colour profile, no formula is needed:

    particle_area_um2(film) = 0.2 × (R_sheet / R_model)²

with R_model from the probe. Tri-X at 17 against Portra 400's modelled green 7.3 is 2.3× the RMS,
5.4× the particle area.

`grain.amount` (RFC-025) would also scale RMS (linearly), but it is the user's strength control
and mixes the blur too. The per-film quantity belongs in the particle area, as RFC-030 §4 says.

## 6. What one number cannot tell

- **Which channel.** A colour film's sheet value is a visual-density reading, a weighted mix of
  the three dye layers. Matching green is the simplest choice; it is a choice.
- **Grain size and texture.** Two films with the same RMS can look different (the Wiener spectrum).
  In the model that is the blur and dye-cloud terms, which RMS does not constrain.
- **Other densities.** Only D = 1.0 is pinned.
- **The print.** The number is on the negative. The paper's gamma multiplies it, which the engine
  already does physically.

## 7. Can every film get one? Not from RMS alone

To be confirmed sheet by sheet (RFC-030 §4: nothing invented). From recollection, not checked here:
- B&W films (Tri-X, T-Max, Ilford partly) and slide films publish diffuse RMS granularity.
- Fujifilm sheets publish an RMS value for negatives too.
- Kodak's current still colour negatives (Portra, Ektar, Gold, UltraMax) publish **Print Grain
  Index** instead. PGI is a perceptual scale for a given print size and is not convertible to RMS.
- Kodak's motion-picture sheets (Vision3) print RMS granularity **curves** per colour against
  exposure, which is richer than a single value and would also test the model's density shape.

So a per-film table is feasible for the B&W path, the slides, the Fuji stocks and probably Vision3,
and has a real gap at the Kodak still negatives.
