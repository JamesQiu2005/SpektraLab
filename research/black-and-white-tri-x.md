# Black and white: Tri-X 400 in the existing engine

2026-10-06/07. Source: `f4017_TriX.pdf` (Kodak F-4017, Feb 2016). Follows `rms-granularity.md`.
Five research agents ran in parallel (profile + filters, base + print, grain, halation + sharpness,
engine integration); their scripts, data and renders are in `bw-tri-x/`.
Nothing in the engine or the app was changed. Two scratch engine builds (environment overrides only,
bit-identical to the shipped dylib when no override is set) were used to measure the engine-change
candidates; their patches are `bw-tri-x/grain/scratch_engine.patch` and
`bw-tri-x/halation/scratch_engine/params_patched.cpp`.

Tags: SHEET = digitised or quoted from F-4017. LIT = literature. MEASURED = rendered through the
built engine. ASSUMED = no data.

## 1. Answer

A Tri-X profile in the existing schema loads and renders today with **no engine change**:
one emulsion written identically into three channels, with a spectrally neutral `channel_density`.
Camera filters fall out of the spectral path and agree with the sheet's filter-factor table.
The Digital Intermediate gives an exactly neutral positive.

What no data file can do, and what it costs in the engine (about 60 to 90 lines in total, no shader):

| Gap | Why | Change |
|---|---|---|
| Grain at RMS 17 | The profile renders 7.2; grain constants are neither in the profile nor on the wire | Per-stock particle area + equal streams and scales for `bw`, ~11 lines |
| Sharpness | Default scatter is far softer than the sheet's MTF; scatter is not on the wire | Per-stock scatter and coupler gammas, ~12–15 lines |
| Halation strength and radius | Presets are fixed per tag | Same block as above |
| Camera filter at run time | An existing band-pass on the sensitivity is not on the wire | ~20 lines + ~8 so Film Edge reads the unfiltered sensitivity |
| A proper print | No B&W paper exists; colour paper tints | A paper profile (data), or a ~15-line monochrome node for colour paper |
| Filter-pack row for the film | A missing row silently prints orange | A data row, or ~12 lines to merge a product-owned file |

## 2. The profile (`bw-tri-x/profile/kodak_tri_x_400.json`)

- All curves on p7/p8 are vector paths; nothing was eyeballed. Axis residuals: 0.001 D, 0.001 log H,
  0.7 nm. SHEET.
- Three checks against the sheet's own text: D-76 small tank CI 0.56 at 6.78 min (table: 6¾);
  D-76 large tank 7.72 min (table: 7¾); T-MAX 6 min speed point gives EI 414 (rated 400).
- **Erratum on the sheet:** p7's legend has the two spectral curves the wrong way round. They sit
  1.1 dex apart, which is the log H distance between D 0.3 and D 1.0 on the characteristic curve.
- Curve: D-76, 135, interpolated to 7.72 min (CI 0.559). Base + fog 0.286. Mid-grey anchored on
  ISO 400; density over Dmin at mid-grey 0.574. SHEET.
- ASSUMED: everything above +2.04 log exposure (6.8 stops over mid-grey; no shoulder is plotted,
  the profile runs a straight line into a ceiling of gross D 3.0); the flat toe; the red tail above
  668 nm; spectrally flat silver and base; D55 reference; `antihalation: weak`.
- The `hanatos2025_adaptation_*` params are omitted on purpose: they are a fitted per-film band-pass
  and would distort the filter factors.
- `channel_model`, `midscale_neutral_density`, `densitometer` are parsed and never read. Upstream
  declares `bw` and consumes it nowhere.
- No citable spectral data was found for developed silver or for the grey base. It only matters on
  colour paper (§5).

## 3. Camera filters

Wratten transmittances: Kodak B-3 tables as transcribed by P. Repacholi (Usenet, 1992), hosted at
mat.uc.pt/~rps/photos. Third-hand, not checked against a printed B-3. LIT.

Computed filter factor against the sheet (daylight D55 / tungsten 3200 K):

| Filter | Sheet | Computed | Error (stops) |
|---|---|---|---|
| 8 yellow | 2 / 1.5 | 2.22 / 1.58 | +0.15 / +0.08 |
| 11 | 4 / 3 | 4.63 / 3.88 | +0.21 / +0.37 |
| 12 | 2.5 / — | 2.58 / 1.74 | +0.04 |
| 15 | 2.5 / 1.5 | 2.77 / 1.83 | +0.15 / +0.28 |
| 25 red | 8 / 5 | 8.67 / 4.76 | +0.12 / −0.07 |
| 47 blue | 6 / 12 | 6.07 / 10.04 | +0.02 / −0.26 |
| 58 green | 6 / 6 | 9.55 / 8.37 | +0.67 / +0.48 |

Six of seven daylight factors are within 0.21 stop. This validates the digitised sensitivity and the
spectral path together. W58 is the outlier.

Three ways to apply a filter:

1. **Profile variant per filter** (done, `profile/profiles/*_w<n>.json`): T(λ) baked into
   `log_sensitivity`, renormalised to mid-grey (the filter factor being given). No engine change.
   Wrong for Film Edge: the edge print and date read the same sensitivity and would pass the filter.
2. **Expose the existing band-pass** (`camera.filter_uv/ir`, `spectral.cpp:104`, already under
   `parity_setup`): 6 schema rows + 6 slots in `params.cpp`, plus an unfiltered sensitivity for
   overscan. Smallest correct change. Sharp-cut yellow/orange/red fit an erf edge; W58/W47 are
   approximations. Not rendered (needs a rebuild).
3. **A filter enum with real tables**: ~55 lines; most faithful; no oracle.

Notes: auto-exposure meters the input and never sees the filter. White balance still matters under
a filter (grey 116.7 → 130.0 warm, → 105.8 cool, on a red-cut stand-in). On colour stocks the
per-channel renormalisation cancels the cast, so the filter is mechanically there and invisible.

## 4. Grain

- The analytic model in `rms-granularity.md` is confirmed on renders to under 1 % (Portra 400 at
  D 1.0: 8.07 / 6.57 / 12.40 measured, 8.09 / 6.57 / 12.37 model).
- **Correction to `rms-granularity.md` §3:** the 0.65 px grain blur does change the number. It is in
  pixels, so the 48 µm RMS depends on pitch: 17.8 (4 µm), 17.0 (6 µm), 14.9 (12 µm), 10.5 (24 µm),
  against 19.1 unblurred. A calibration has to name a pitch.
- The three channels' draws are independent (r = 0.000). With neutral columns the negative is still
  not coloured, but three fields are averaged: the result is 0.67 × one channel's RMS.
- The profile as built renders **7.2** (sub-layers on, the default) or 9.9 (single layer). Sheet: 17.
- Without an engine change: `grain_sublayers_active=false` + `grain_amount=1.71` measured 17.00.
  It spends the user's slider.
- With one (measured on the scratch build): equal streams for `bw` (`pipeline.cpp:258`, `:1356`),
  equal `particle_scale` and `uniformity`, per-stock `particle_area_um2` in `apply_film_specifics`.
  Channels become bit-identical. Area for 17 at 6 µm pixels, single layer, scale 1:

  | Net Dmax | Area (µm²) |
  |---|---|
  | 2.5 (the profile's 3.0 gross) | 0.42 |
  | 3.0 | 0.32 |
  | 3.5 | 0.25 |

- The sub-layer split was designed for colour; nothing on the sheet supports it for Tri-X. It moves
  the granularity peak down to D 0.7–1.0 and needs about twice the area.
- What one number cannot fix: the engine's grain is white noise through a 0.65 px blur, so texture
  scales with the pixel, not the film. `blur_dye_clouds_um` only acts below ~3 µm pixels. The
  density shape d·(1 − u·d/Dmax) is pinned by one sheet point only.

## 5. The positive

All on stand-in profiles (MEASURED):

| Route | Result | |
|---|---|---|
| Digital Intermediate | chroma 0.0, grain and halation on | First version. Flat: no paper, no grade |
| Variable-contrast silver paper in the paper schema | chroma ≤ 0.06 | The proper target; data only |
| Colour paper, default pack | orange, b* +33.5 | A missing row falls back silently |
| Colour paper, solved pack | warm shadows, cool highlights, b* range 1.5–8.2 with the assumed silver slope | Needs a row per (paper, film) |
| `scan_film` | the uninverted negative | |
| Desaturate at the end | removes the cast | A post-print edit |

- On the VC stand-in the existing M/Y pack is a **grade control**: scene range 7.6 stops (Y170) to
  2.4 stops (M170), mid-grey holding. One "Grade" control would be app-side. The stand-in is
  uncalibrated (too hard, prints dark) and is not Ilford data. Ilford's Multigrade sheet gives ISO R
  per filter and curve families, not per-emulsion data; those would be fitted.
- Open: the DI's colour-matrix fit has a singular normal matrix with three identical sensitivities.
  It rendered correctly every time; the matrix was not inspected.
- Trap: switching stock in a session keeps the previous film's pack when the new film has no row.

## 6. Halation, sharpness, couplers

- With neutral columns the halo is exactly neutral even under the red-weighted presets; the three
  halos average (`weak` behaves like a little under 0.033 equalised). MEASURED.
- Strength: no citable number. Recommended 0.05–0.08 equalised. ASSUMED.
- Radius: base geometry gives a ring near 238 µm (135, 5-mil grey acetate per the 2004 edition of
  F-4017; 120 is 3.9-mil grey acetate too). The engine's 65 µm kernel peaks near 72 µm.
- Sheet MTF (vector): 114 % at 11 c/mm, 96 % at 34, 67 % at 47, 24 % at 72. Engine default:
  71 / 46 / 28 % at 10 / 20 / 50 c/mm. MEASURED.
- Fit: scatter core 3.91 µm, no tail, plus the DIR node as a development edge effect (k = 0.187):
  rms 4.4 points. The coupler number depends on the stand-in's gamma and must be re-derived on the
  Tri-X curve.
- Couplers are on by default and at default strength are far too strong on three identical
  channels (MTF plateau 178 %). `dir_couplers_amount ≈ 0.4` is on the wire; scatter is not.
- Print glare is neutral on a neutral print. Nothing to change.

## 7. Renders (`bw-tri-x/renders/`)

Five local images: `_smoke_1mp.tif` and four RAWs (R0030139, _DSC2439, _DSC2704, _DSC2715) decoded
with rawpy to linear ProPhoto at ~1.5 MP. That is not the app's Core Image intake.

- `sheet_default_*.png`: shipped engine, DI. Portra 400 colour print, then Tri-X with no filter,
  W8, W21, W25, W58, W47. Channel spread 0 on every Tri-X frame.
- `sheet_cal_*.png`: the same on the scratch build with grain calibrated to 17 (area 0.42, equal
  streams, single layer) and `dir_couplers_amount=0.4`.
- `sheet_vcsoft_*.png`: on the stand-in VC paper, Y110. Illustrative only.
- `grain_compare.png`: a 6 µm-pitch crop, shipped grain (left) against calibrated (right). The right
  side is also softer because the couplers are turned down while the scatter stays at default.

## 8. Plan

**Stage 0, no engine change.** The profile, filter variants, `dir_couplers_amount`, DI as the
positive. Grain at 17 only by spending `grain_amount`. Soft.

**Stage 1, engine, keyed on `channel_model == "bw"` or the stock:**
1. `apply_film_specifics` / `apply_halation_preset` (`params.cpp`): particle area, equal scales and
   uniformity, scatter, halation, coupler gammas.
2. `pipeline.cpp:258`, `:1356`: equal grain streams.
3. `params.cpp`: the filter band-pass on the wire; overscan reads the unfiltered sensitivity.
4. Optional: monochrome node after `node_scan_spectral` for colour paper; a product-owned
   `neutral_print_filters` overlay.
5. Parity: new fields go in `NATIVE_ONLY` (as `filter_shift_scale`); `parity_setup` is untouched
   while the filter amplitude defaults to 0; colour-stock harnesses are unaffected.

**Stage 2.** A B&W paper profile with grade on the M/Y pack; filter picker; real Wratten tables.

**Around the engine.** The stock list is generated (`Tools/gen-catalog.py`); no test pins the count
of 28, but prose does (README, ARCHITECTURE, CLAUDE.md, `Tools/bundle-licenses.sh`, which says
"UNMODIFIED"). The Tri-X profile is the product's own data: keep it outside spektrafilm's profile
directory with its own notice citing F-4017, and copy no arrays from the CC BY-SA profiles.

## 9. Open

- Dmax and the shoulder (sets the grain area and the highlights).
- Halation strength; silver and base spectra.
- The Wratten source; W58's 0.67 stop.
- The DI matrix with identical sensitivities.
- Which developer the look is: the curve is D-76, the granularity figure is HC-110 B.

## 10. Addendum, 2026-10-07: Ilford paper, the filter in the engine, the film edge

**Ilford MULTIGRADE IV RC** (`bw-tri-x/paper/`, from `MULTIGRADE-IV-RC-Papers-060619.pdf`). Data only,
no engine change. Three emulsions in the three channels, fitted to the sheet's curve family.
- The sheet's charts are JPEGs: a raster trace (0.011 per pixel), not vectors. SHEET (raster).
- Grade table through existing wire fields (C 0; M, Y, `print_exposure`), rendered R against the
  sheet's table: 00 171/180, 0 147/160, 1 124/130, 2 105/110, 3 89/90, 4 66/60, 5 58/40. rms
  0.011–0.031 D. Filter 5 is too soft; 00 has a step near D 1.6. MEASURED.
- Filter 2 = M0 Y68, `print_exposure` 1: Tri-X mid-grey prints at D 0.736 with no per-image tuning;
  scene range 7.0 stops (3: 5.1, 4: 3.7, 5: 3.2). Max chroma 0.055 (the output stage's). MEASURED.
- A `neutral_print_filters` row `[0, 0, 68]` carries filter 2. Without it the print is neutral but
  0.36 D too light and about grade 3½–4.
- Grade must be an app-side control setting M, Y and `print_exposure` together; the two shift
  sliders alone drift mid-grey 0.30–0.97.
- Breaks: no print-preview LUT for the paper (named error); white/black correction miscalibrated
  for it (off by default); EDR refuses; preflash uncalibrated.
- ASSUMED: per-emulsion sensitivities, flat silver, flat 0.06 base, TH-KG3 lamp. No half grades.

**Camera filter** (branch `bw-tri-x`, 89c203aa + 88a4ca03, pushed; API-SPEC §15). Wire field
`camera_filter`, table in `engine/src/core/camera_filters.hpp`, applied in `film_sensitivity`;
overscan reads the unfiltered `film_sensitivity_edge_`. Agrees with the baked variants to 2/255;
rebates move ≤ 1/255 under W25; `parity_schema`, `parity_setup`, `overscan_checks` pass.
Colour stocks: one render only (Portra + W8 goes yellow and much brighter; not investigated).

**Film edge.** One `kEdgeLooks` row (Kodak layout, neutral printer light, regular weight). No DX
bars (no `dx_extract_for` row). Rebate neutral 164/164/164. Against the owner's strips
(`reference_film/135/Kodak/TX400 135.png`, `120/Kodak/TX400 645.png`): layout matches; the ink
renders darker than the strip's; the half number reads "14A" before 15 where the strip has "15A"
after 15 (inherited from the Kodak colour layout). The host passes "KODAK 400TX".

**End to end** (`bw-tri-x/engine-test/end_to_end.py`, worktree engine): Tri-X + wire filter + MGIV
filter 2 on four RAWs (`e2e_*.png`), and a print with the 135 edge (`e2e_edge_135_print.png`).
Grain is still the engine default (RMS ~7, not 17) in these.
