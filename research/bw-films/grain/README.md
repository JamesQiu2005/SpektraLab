# Grain for the black-and-white profiles (2026-10-09)

How much grain T-Max 100, Neopan 100 Acros II and HP5 Plus 400 should have, with Tri-X 400 re-measured
as the control. Same method as `../../grain-all/` (probe profile, `scan_film`, unsharp mask divided
out, 48 µm disc, flux-then-log). Rule kept: grain is matched by a per-film default `grain_amount`
(wire 0–2), not by an engine change.

Tags: SHEET maker's document · MEASURED engine render · MODEL analytic · LIT other source · ASSUMED.

Engine: the frozen dylib `spektrafilm-native 0.1.0 (Oct 9 2026 01:41:45, math=safe)`; profiles from
`engine/resources_product/profiles/` as of the same day.

## 1. Published

| Film | RMS | Conditions | Source | Tag |
|---|---|---|---|---|
| T-Max 100 | 8 | net diffuse density 1.00, 48 µm, 12×, D-76 68 °F | Kodak F-4016 (June 2018) p8, `../pdf/tmax.pdf` | SHEET, read from the PDF |
| Neopan 100 Acros II | 7 | 48 µm, density 1.0 above minimum, **Microfine** | Fujifilm AF3-0258E §11 (p3), `../pdf/acros.pdf` | SHEET, read from the PDF |
| HP5 Plus (still) | none | — | HARMAN, Nov 2018, `../pdf/hp5.pdf`: the word "granularity" does not occur | SHEET |
| HP5 Plus (motion picture) | 16 | D-96, 6 min, 75 °F; development aimed at gamma 0.65–0.70; **no aperture, no density stated** | Ilford fact sheet, PDF dated Oct 1997, `../pdf/hp5_motion_picture_fact_sheet.pdf` (also https://bioskoplab.wordpress.com/wp-content/uploads/2011/10/hp5mpic.pdf) | SHEET, for another product |
| Tri-X 400 (control) | 17 | net diffuse density 1.0, 48 µm, 12×, HC-110 B | Kodak F-4017 (Feb 2016) p6 | SHEET (carried from `rms-granularity.md`, not re-read) |

Context for the HP5 figure, none of it a number for the still film:

- Ilford's FP4 Plus motion picture sheet, same series and date, gives 10 (D-96, 5½ min, 75 °F), also
  without aperture or density. SHEET: https://bioskoplab.wordpress.com/wp-content/uploads/2011/10/fp4mpic.pdf
- Kodak Double-X 5222 (EI 250): 14, "read at a net diffuse visual density of 1.0, using a
  48-micrometer aperture", D-96 to control gamma 0.65–0.70. SHEET, H-1-5222 rev. 3-22:
  https://www.kodak.com/content/products-brochures/Film/DOUBLEX-Technical-Data-EN.pdf
- So 16 sits where the 48 µm / net D 1.0 convention would put a 400-speed cubic-grain film (Double-X
  14, Tri-X 17). That makes the convention likely. It is still not stated. ASSUMED.
- The motion picture sheet says to use the still film's development times in Ilford developers. It
  does not say the emulsion is the same. ASSUMED.
- The figure is for gamma 0.65–0.70 in D-96. The profile's curve is ILFOTEC HC 1+31, contrast index
  0.599. More development gives more granularity, so 16 is more likely high than low for the
  profile. No correction is applied: there is no number for it.
- A web search found no HP5 Plus still-film RMS figure from Ilford/HARMAN. Reviews repeat that Ilford
  does not publish one. Nothing from forums is used here.

The Acros figure has the same kind of gap, smaller: 7 is in Microfine (a fine-grain developer), the
profile's curve is D-76. In D-76 the film would read somewhat higher. No number exists for that.

## 2. Rendered at `grain_amount` 1 (MEASURED)

Net density 1.0 patch, RMS = 1000 × σ_D through 48 µm. Model in brackets.

| Film | on, 6 µm | off, 6 µm | on 4 / 12 µm | off 4 / 12 µm |
|---|---|---|---|---|
| Tri-X 400 | 7.22 (7.22) | 9.97 (10.01) | 7.52 / 6.31 | 10.37 / 8.68 |
| T-Max 100 | 6.96 (6.96) | 10.85 (10.90) | 7.21 / 6.08 | 11.32 / 9.44 |
| Acros II | 8.40 (8.41) | 10.98 (11.02) | 8.73 / 7.33 | 11.40 / 9.55 |
| HP5 Plus | 7.70 (7.70) | 10.76 (10.80) | 7.94 / 6.72 | 11.19 / 9.36 |

"on / off" = `grain_sublayers_active`. Control: the earlier study had Tri-X at 7.2 / 9.9–10.0.

- Cross-check: the three one-record probes combined at 1/3 each give the same numbers (7.22, 6.96,
  8.40, 7.70 on; 9.97, 10.85, 10.98, 10.76 off). Records are uncorrelated (|r| ≤ 0.0013).
- Grain does not move the mean density (≤ 0.0002 D at every patch).
- Pitch: 4 µm renders ×1.04, 12 µm ×0.87, for every film and both paths.

## 3. The table

Amount = published / rendered, at 6 µm. "Rendered at that amount" is a second render, not the ratio.

| Film | Published | Basis and caveats | Rendered on / off | Amount on / off | In wire range? | Rendered at that amount | Ceiling ±0.4 D → amount |
|---|---|---|---|---|---|---|---|
| T-Max 100 | 8 SHEET | same convention as the measurement; D-76 = the profile's developer | 6.96 / 10.85 | **1.15 / 0.74** | yes / yes | 8.00 / 8.03 | on 1.31…1.08, off 0.80…0.71 |
| Acros II | 7 SHEET | Microfine, curve is D-76: 7 is likely low for the profile | 8.40 / 10.98 | **0.83 / 0.64** | yes / yes | 6.98 / 7.03 | on 0.97…0.76, off 0.72…0.58 |
| HP5 Plus | 16 SHEET, other product | motion picture stock, D-96, gamma 0.65–0.70, aperture and density not stated | 7.70 / 10.76 | **2.08 / 1.49** | **no** / yes | 15.40 at the clamp 2.0 / 16.03 | on 2.21…2.04, off 1.67…1.39 |
| Tri-X 400 | 17 SHEET | same convention; HC-110 B, curve is D-76 | 7.22 / 9.97 | **2.36 / 1.70** | **no** / yes | 14.44 at the clamp 2.0 / 16.95 | on 2.40…2.27, off 1.87…1.65 |

At other pitches (off path): ×0.96 at 4 µm, ×1.15 at 12 µm — T-Max 0.71 / 0.85, Acros 0.61 / 0.73,
HP5 1.43 / 1.71, Tri-X 1.64 / 1.96. All still inside the range.

### Sensitivity to the ASSUMED ceiling (MEASURED, `dmax_sensitivity.py`)

Each profile rebuilt with the ceiling moved, layer split refitted as the builder does; the unmoved
rebuild reproduces the shipped curve and layers to rounding.

| Film | Gross ceiling | Curve max (net) | RMS on | RMS off |
|---|---|---|---|---|
| Tri-X | 2.6 / 3.0 / 3.4 | 2.26 / 2.52 / 2.64 | 7.09 / 7.22 / 7.50 | 9.08 / 9.97 / 10.33 |
| T-Max | 2.8 / 3.2 / 3.6 | 2.54 / 2.81 / 2.93 | 6.13 / 6.96 / 7.39 | 10.02 / 10.85 / 11.20 |
| Acros | 2.6 / 3.0 / 3.4 | 2.45 / 2.85 / 3.23 | 7.21 / 8.40 / 9.24 | 9.74 / 10.98 / 12.02 |
| HP5 | 2.6 / 3.0 / 3.4 | 2.41 / 2.78 / 3.04 | 7.25 / 7.70 / 7.86 | 9.61 / 10.76 / 11.51 |

- Off path: −8…−11 % and +3…+10 % for ∓0.4 D. On path: −2…−14 % and +2…+10 %, and part of that is the
  refitted split, not Dmax.
- The grain node's Dmax is the curve's largest value, which is its value at log exposure +4, not the
  ceiling. Three of the four curves have not reached their ceiling there: net 2.52 against 2.71
  (Tri-X), 2.81 against 2.99 (T-Max), 2.78 against 2.83 (HP5); Acros gets there (2.85). So the
  ASSUMED end slope and the length of the exposure axis are in the grain number too.

## 4. Recommendation

**Sub-layers off for black and white, and these defaults:**

| Film | `grain_sublayers_active` | `grain_amount` | Renders (MEASURED) | Confidence |
|---|---|---|---|---|
| T-Max 100 | false | **0.74** | 8.03 | good: sheet and measurement share a convention |
| Acros II | false | **0.64** | 7.03 | fair: Microfine figure on a D-76 curve; treat as a floor |
| HP5 Plus | false | **1.49** | 16.03 | weak: another product, another developer, convention not stated |
| Tri-X 400 | false | **1.70** | 16.95 | good (unchanged from the earlier study) |

Why off:

1. It is the only setting where all four are inside the wire range. With sub-layers on, HP5 (2.08)
   and Tri-X (2.36) clamp at 2.0 and render 15.4 and 14.4.
2. It costs less sharpness. `grain_amount` k also scales the node's 0.65 px blur of the picture, and
   the off path needs a smaller k for every film (table below).
3. The on path leans on the three-CDF layer split, which is ASSUMED for all four and decides the
   order: Acros renders grainiest (8.40) and T-Max finest (6.96) for no reason on any sheet.

If sub-layers must stay on (one product-wide default): T-Max 1.15 and Acros 0.83 work; HP5 and Tri-X
cannot reach their figures.

### What the amount costs in sharpness (MEASURED, `amounts.py`)

Contrast of stripes in the negative's density, relative to grain off. ±1 stop around the D 1.0
exposure, 6 µm pixels. Negative = the stripes come out reversed.

| Stripe period | k = 1 (any film) | T-Max 0.74 | Acros 0.64 | HP5 1.49 | Tri-X 1.70 | T-Max on 1.15 | Acros on 0.83 | clamp 2.0 |
|---|---|---|---|---|---|---|---|---|
| 2 px | 0.25 | 0.44 | 0.52 | −0.12 | −0.28 | 0.14 | 0.38 | −0.50 |
| 3 px | 0.42 | 0.57 | 0.63 | 0.14 | 0.01 | 0.33 | 0.52 | −0.16 |
| 4 px | 0.60 | 0.71 | 0.75 | 0.41 | 0.33 | 0.54 | 0.67 | 0.21 |
| 8 px | 0.88 | 0.91 | 0.92 | 0.82 | 0.79 | 0.86 | 0.90 | 0.76 |

- The two slow films come out sharper than the engine's own amount 1; the two fast ones lose most
  of the detail below 4 px. At Tri-X's 1.70, 3 px detail is gone and 2 px detail is inverted.
- The same on both grain paths (0.249 / 0.420 / 0.602 / 0.879 at k = 1).
- The user's slider: if the per-film default is the slider's starting value, HP5 has 34 % of
  headroom left to 2.0 and Tri-X 18 %. How the default and the slider combine is not decided here.

## 5. Things that were not expected

1. **At amount 1 the four films are the same film to the grain node.** 7.0–8.4 on, 10.0–11.0 off, and
   the order is wrong: Tri-X (sheet 17) renders the least grain on the off path, Acros (sheet 7) the
   most on both. There is no per-film grain data in the engine; what differs is Dmax and the split,
   both ASSUMED. The per-film amount is the whole of the difference between these films' grain.
2. **The on path's density dependence is the fit's, not the film's** (6 µm, net D 0.3 / 0.6 / 1.0 /
   1.5 / 2.0):
   - Tri-X 6.5 / 6.7 / 7.2 / 6.2 / 5.6
   - T-Max 7.7 / 7.4 / 7.0 / 7.0 / 6.8
   - Acros 7.1 / 7.1 / 8.4 / 8.0 / 6.9
   - HP5 8.0 / 8.2 / 7.7 / 7.3 / 6.4

   The off path has one shape for all four: about 7.2 / 9.3 / 10.9 / 11.3 / 10.4 (Tri-X lower: 6.7 /
   8.7 / 10.0 / 10.1 / 8.5).
3. **The calibration point is not mid-grey.** Net D 1.0 is +2.2 stops (T-Max), +1.6 (Acros), +1.7
   (HP5), +2.3 (Tri-X) above the 0.184 grey. Mid-grey sits at net D 0.62 / 0.69 / 0.66 / 0.57, as
   `../csv/profile_summary.txt` says. On the off path the grain there is about 15 % below the D 1.0
   figure at amount 1.
4. **Nothing found that says a profile is wrong.** Mid-grey densities match the builder's summary to
   three decimals, Dmax is what the curve says, the layers sum to the curve, the model agrees with the
   renders to under 1 % at every patch. The product's Tri-X profile differs from the research copy only in
   `target_print`.
5. The 2 px stripe at k = 1 keeps 0.25 of its contrast, not the 0.12 a continuous 0.65 px Gaussian
   predicts (3 px: 0.42 against 0.40). Read the measured column, not `1 − k(1 − G)`, at the finest
   periods.

## 6. Not verified

- Nothing was checked in the app or on a print: all numbers are the negative's density through
  `scan_film`.
- The stripe test is on the negative. What the paper stage does to it afterwards was not measured.
- Net D 2.0 on Tri-X is +8.6 stops over mid-grey; the top two rows of the density series are in the
  ASSUMED part of every curve.
- F-4017 (Tri-X) was not re-read here.

## 7. Files and re-running

| File | What |
|---|---|
| `galib.py` | `grain-all/galib.py` with paths fixed, the product overlay, and a neutral probe (`make_bw_probe`) |
| `measure_bw.py` → `engine_rms_bw.json`, `.csv` | §2 and the density series |
| `dmax_sensitivity.py` → `dmax_sensitivity.json`, `.csv` | §3 sensitivity |
| `amounts.py` → `bw_grain_amount.json`, `.csv` | §3 amounts, the read-back renders, the stripe test |

```
PY="/Volumes/Hanze_Qiu/Documents/Summer 2026/spektrafilm/.venv/bin/python"
cd research/bw-films/grain
"$PY" measure_bw.py && "$PY" dmax_sensitivity.py && "$PY" amounts.py      # about a minute in all
```

By default the scripts use the frozen dylib and a scratch resources folder under the session's
scratchpad, which will not outlive it. Against a current build:

```
GRAIN_DYLIB=../../../engine/build/libspektrafilm_engine.dylib GRAIN_RES=/some/scratch/res "$PY" measure_bw.py
```

`GRAIN_RES` is created if missing (symlinks of `engine/resources/*`, the shipped and product profiles,
plus the probe and variant profiles the scripts write). Nothing under `engine/` is written.
