# Black and white: T-Max 100, Neopan 100 Acros II, HP5 Plus 400

2026-10-09. Follows `black-and-white-tri-x.md`; the same construction, three more films.
Sources (local, `B&W_Research/film/`): Kodak F-4016 (June 2018), FUJIFILM AF3-0258E, HARMAN
"HP5 PLUS Technical Information" (Nov 2018), and the owner's four strips. One more was fetched:
Ilford's HP5 Plus motion-picture fact sheet (`bw-films/pdf/hp5_motion_picture_fact_sheet.pdf`).
Scripts, CSVs and renders: `bw-films/`.

Tags: SHEET = digitised or quoted from the maker's document. MEASURED = rendered through the built
engine. ASSUMED = no data.

## 1. What landed

- Three profiles in `engine/resources_product/profiles/`: `kodak_tmax_100`,
  `fujifilm_neopan_acros_100_ii`, `ilford_hp5_plus_400`. Not installed, like Tri-X.
- A `kEdgeLooks` row each, and a 135 layout of its own for Ilford (`Edge135::Ilford`).
- `engine/tests/bw_checks.py` runs every check on all four films, and reads HP5's DX code back.
- Grain is measured and not applied: there is no per-film default in the app yet (§5).

## 2. The profiles

One emulsion written into three channels, neutral `channel_density`, three-CDF layer split ASSUMED,
flat toe ASSUMED, straight line into an ASSUMED ceiling above the sheet's last point.

| | T-Max 100 | Acros II | HP5 Plus |
|---|---|---|---|
| Charts in the PDF | vector | 300 dpi raster | raster |
| Axis residual, worst | 0.0002 D, 0.016 nm | 0.003 log H, 0.002 D | 0.006 log E, 0.009 D, 0.34 nm |
| Curve | D-76 small tank, 6.18 min | D-76, 7.25 min | ILFOTEC HC 1+31, 6.5 min |
| Why that curve | contrast index 0.56, as Tri-X | the sheet's own D-76 time | the only one plotted |
| Contrast index (Kodak's arcs) | 0.560 | 0.572 | 0.599 |
| Base + fog | 0.209 | 0.144 | 0.175 |
| Exposure axis | absolute, ISO 100 | absolute, ISO 100 | **relative** |
| Own speed point | EI 85 | EI 134 | anchored to 400 (ASSUMED) |
| D over base at mid-grey | 0.618 | 0.686 | 0.665 |
| Sheet covers, log exposure | −2.04 … +1.74 | −2.10 … +1.56 | −2.03 … +2.03 |
| Ceiling, gross D (ASSUMED) | 3.2 (highest plotted) | 3.0 | 3.0 |
| Sensitivity, sheet range | 400–700 nm | 401–662 nm | 380–654 nm |

- **HP5's exposure axis is relative.** The curve's own D = base + 0.1 point is put where ISO 400
  says it is, so the film has exactly its rated speed by construction.
- **Acros's "spectrogram to daylight (5400K)"** has a 5400 K black body divided out (ASSUMED
  source spectrum). It changes little: that source is nearly flat.
- **HP5's "wedge spectrogram to tungsten light (2850K)" is taken as drawn**, in log units, with
  the source *not* divided out. This is a choice made on evidence, not on the caption: Ilford's own
  daylight factors for HP5 Plus (motion-picture sheet) are W8 1.7, W12 2.0, W15 2.0, W21 2.6,
  W25 4.0. As drawn the profile gives 1.63 / 1.88 / 2.02 / 2.68 / 5.98; with a 2850 K source
  divided out, 2.9 / – / 4.2 / – / 16. Reading the 0–1 axis as linear gives 1.70 / – / 2.17 / – / 6.3.
- Below the first sheet point the sensitivity is held; above the last it runs out log-linearly.

## 3. Filter factors against each maker's table (`bw-films/csv/filter_factors.csv`)

Daylight (D55), error in stops, computed − sheet:

| Filter | T-Max 100 | Acros II | HP5 Plus |
|---|---|---|---|
| 8 | 2.19 vs 1.5, +0.55 | 1.58 vs 2, −0.34 | 1.63 vs 1.7, −0.06 |
| 11 | 4.54 vs 3, +0.60 | | |
| 12 | 2.58 vs 2, +0.37 | | 1.88 vs 2, −0.09 |
| 15 | 2.80 vs 2, +0.48 | | 2.02 vs 2, +0.02 |
| 21 | | 2.37 vs 4, −0.76 | 2.68 vs 2.6, +0.05 |
| 25 | 8.84 vs 8, +0.14 | 4.85 vs 8, −0.72 | 5.98 vs 4, +0.58 |
| 47 | 6.56 vs 8, −0.29 | | |
| 58 | 8.95 vs 6, +0.58 | | |

- T-Max: the plotted curve is more blue-sensitive than its own table implies (yellow filters
  +0.4 to +0.6 stop; tungsten W47 −1.2). The curve was not adjusted.
- Acros: orange and red come out 0.7 stop low. Fujifilm's table is "a guide" in round numbers
  (2 / 4 / 8) and the spectrogram is the only spectral data; not adjusted.
- Tri-X was within 0.21 stop on six of seven. These three are looser.

## 4. Film edges

| | 135 | 120 | From |
|---|---|---|---|
| T-Max 100 | Kodak's layout, bold, no DX bars | Kodak's | both strips; matches |
| Acros II | Fujifilm slides' layout (dots, no bars) | Fujifilm's | 135 strip; 120 unverified |
| HP5 Plus | **its own** | Kodak's, borrowed | 135 strip; 120 unverified |

**Ilford 135, measured on the strip (29.7 px/mm):**
- It is Kodak's two bands turned half a turn. Picture upright: DX code and frame numbers along
  the top band, the name upside down along the bottom one.
- The bars are a real DX code: 13.06 mm, 31 modules of 0.421 mm, clock track of 3 + 23 + 5 as it
  lies (5 + 23 + 3 as read), one every 19 mm, starting 1.89 mm past a perforation's centre.
- DX number 109/9 = 1753, from the cartridge code 017534 (web; LIT). The strip is cropped
  through the data track, so the number was not read off the film.
- Name: square 5 × 7 matrix, caps 1.50 mm, a character every 1.26 mm, baseline 1.85 mm from the
  edge; "ILFORD HP5 PLUS" is 18.9 mm long and sits over the frame's middle.
- Beside the name a batch number ("5847-1…") in a smaller, heavier face. Not drawn: one strip
  gives no rule for it.
- **ASSUMED: the frame numbers.** The crop leaves only their tops (1.95 mm from the edge, in the
  gaps between the codes). Their face, "N"/"NA", the arrow if any, and which gap holds which are
  not measured; they are drawn in the name's face, in Kodak's order turned.
- The holes on that strip measure 2.83 mm along the film against the standard 1.98; pitch and
  the DX length agree with each other, so the scale was taken from the pitch.

**Acros II against its strip:** the layout is the slides', as the owner asked. Not matched: the
strip's name is larger (about 1.5 mm caps against the slides' 1.04), and its name band shows no
frame number where the slides print one. "II" is drawn as the strip's one-cell numeral.

**Kodak 135 half number** still reads "6A" before 7 where the strips have "7A" after 7
(inherited from the colour layout; open since Tri-X).

Renders: `bw-films/edge/render_*.png`.

## 5. Grain (subagent; `bw-films/grain/`, README there has every table)

Published: T-Max 100 **8** (SHEET, D-76, 48 µm, net D 1.0). Acros II **7** (SHEET, Microfine —
the curve is D-76, so 7 is a floor). HP5 Plus still film: **nothing published**. Ilford's HP5 Plus
motion-picture sheet says **16** (D-96, gamma 0.65–0.70; no aperture or density stated).

MEASURED at 6 µm pixels, net D 1.0, 48 µm disc:

| Film | Published | Renders at amount 1, sub-layers on / off | Amount needed, on / off | Ceiling ±0.4 D moves the off amount |
|---|---|---|---|---|
| T-Max 100 | 8 | 6.96 / 10.85 | 1.15 / 0.74 | 0.80 … 0.71 |
| Acros II | 7 | 8.40 / 10.98 | 0.83 / 0.64 | 0.72 … 0.58 |
| HP5 Plus | 16 | 7.70 / 10.76 | 2.08 / 1.49 | 1.67 … 1.39 |
| Tri-X 400 (control) | 17 | 7.22 / 9.97 | 2.36 / 1.70 | 1.87 … 1.65 |

- At amount 1 the four films are one film to the grain node, and in the wrong order. The
  per-film amount is the whole grain difference.
- Only with `grain_sublayers_active` off are all four inside the wire range (0–2). With it on the
  films' order comes from the ASSUMED layer split.
- Recommended defaults, sub-layers off: T-Max 0.74, Acros 0.64, HP5 1.49, Tri-X 1.70.
- Cost: `grain_amount` scales the node's picture blur. Contrast of a 3 px stripe against grain
  off: 0.42 at amount 1; 0.57 (T-Max), 0.63 (Acros), 0.14 (HP5), 0.01 (Tri-X). At 2 px the two
  fast films invert.
- HP5's 16 is the weakest number here: another product's sheet, another developer, convention
  not stated. Kodak Double-X gives 14 on the stated convention in the same developer, so 16 is
  plausible, and more likely high than low.
- Pitch: ×1.04 at 4 µm, ×0.87 at 12 µm.

## 6. Open

- Per-film default `grain_amount` and sub-layers off for B&W: an app-side decision, not made.
- Ilford's frame numbers (a strip that shows the whole band), HP5 and Acros on 120.
- An Acros layout of its own, if the slides' is not close enough.
- T-Max and Acros filter factors against their tables (§3).
- Dmax and shoulder for all three: ASSUMED, and in the grain number.
- Nothing was run in the app; the app tests were not run (the change is the overscan table and data).
