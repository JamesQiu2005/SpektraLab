# Colour film granularity: what the makers publish, what the engine renders

2026-10-07. Follows `rms-granularity.md` (what RMS granularity is) and
`black-and-white-tri-x.md` §4. Data, scripts and sources: `grain-all/`.
Nothing in the engine or the app was changed for this, and nothing reads the table yet.

Question: can each film be tied to one default `grain_amount`, with no engine change, so its grain
matches its datasheet?

## 1. Answer

Partly. For the thirteen films with a usable figure, published ÷ rendered gives an amount between
0.63 and 1.15 for every colour film and 2.35 for Tri-X 400 (1.70 on the single-layer path).
Six Kodak still negatives publish no RMS at all. And `grain_amount` is not a pure amplitude: it
also scales the grain node's blur of the picture (§5), so an amount far from 1 changes sharpness.

## 2. What is published

Every row was read in a fetched manufacturer document; sources, editions, pages and URLs are in
`grain-all/published_granularity.json`. Diffuse RMS granularity = 1000 × σ of density through a
48 µm aperture at density 1.0.

| Film | Kind | Value | Conditions | Document |
|---|---|---|---|---|
| Provia 100F | RMS | 8 | 1.0 over D-min | Fujifilm AF3-036E (2000) |
| Velvia 100 | RMS | 8 | gross visual density 1.0 | AF3-202E (2005) |
| Ektachrome E100 | RMS | 8 | gross visual density 1.0 | Kodak Alaris E-4000 (2018) |
| Kodachrome 64 | RMS | 10 | gross visual density 1.0, 12X | Kodak E-88 (2009); 12 in the 1998 edition |
| C200 | RMS | 4* | 1.0 over D-min | AF3-0249E (2017) |
| Superia X-TRA 400 | RMS | 4* | same | AF3-0217E (2006) |
| Pro 400H | RMS | 4* | same | AF3-176E (2005) |
| Vision3 50D | curves | R 4.6, G 4.4, B 8.3 | per record, read at D-min + 1.0 | H-1-5203t (2015) |
| Vision3 200T | curves | R 5.2, G 6.4, B 15.4 | same | H-1-5213t (2015) |
| Vision3 250D | curves | R 5.4, G 6.3, B 13.4 | same | H-1-5207t (2009) |
| Vision3 500T | curves | R 6.4, G 7.1, B 19.2 | same | H-1-5219t (2015) |
| Verita 200D | curves | R 7.4, G 6.7, B 18.2 | same | H-1-5206 (2026) |
| Portra 160 | PGI | 28 / 50 / 79 | 135 at 4×6, 8×10, 16×20 in | E-4051 (2016) |
| Portra 400 | PGI | 37 / 59 / 89 | same | E-4050 (2016) |
| Portra 800 | PGI | 48 / 70 / 99 | same | E-4040 (2016) |
| Ektar 100 | PGI | <25 / 38 / 66 | same | E-4046 (2016) |
| Gold 200 | PGI | 44 | 4×6 only | E-7022 (2016) |
| UltraMax 400 | PGI | 46 | 4×6 only | E-7023 (2016) |
| Portra 800 push 1 / 2 | none | — | | E-4040 |
| Tri-X 400 (reference) | RMS | 17 | net D 1.0, HC-110 B | F-4017 (2016) |

- \* Fujifilm's negative sheets footnote the figure: "Due to difference in measurement conditions,
  comparison with color reversal film is not possible." It is not on Kodak's scale either.
- The Vision3 and Verita values are a digitisation of the sheets' vector curves, ±10 %, per
  Status M record. The sheets give no single visual figure.
- Kodak's still negatives have carried Print Grain Index, not RMS, in every edition found back to
  December 1996. Kodak E-58 gives no conversion ("We will not describe the mathematical details")
  and the sheets say the scales cannot be compared. The one film that prints both (Portra 400BW:
  RMS 9, PGI <25 / 40 / 70) would place Portra 400 near 16, as grainy as Tri-X; that anchor is
  rejected and no conversion is offered.
- Verita 200D is an Eastman motion-picture negative (5206 / 7206), not a still film.
- Pro 400H, Provia 100F, Kodachrome 64 and Vision3 250D were fetched from a mirror (125px.com),
  not the maker's site.

## 3. What the engine renders

Measured on the built engine at `grain_amount` 1, 6 µm pixels (36 mm across 6000 px), 48 µm
aperture. Method in `grain-all/galib.py`: probe profiles read each dye record's density field back
through `scan_film`. R / G / B are each record at net density 1.0 in that record. Visual is the
neutral patch at visual density 1.0 (illuminant A × V(λ), the ISO 5-3 product) through the film's
own dye spectra. Gross applies to positives.

| Stock | Sub-layers on: R / G / B | Visual net | Visual gross | Sub-layers off: R / G / B | Visual net | Visual gross |
|---|---|---|---|---|---|---|
| fujifilm_c200 | 8.0 / 8.6 / 17.1 | 5.7 | – | 10.3 / 12.3 / 22.1 | 7.9 | – |
| fujifilm_pro_400h | 6.4 / 5.8 / 12.5 | 3.6 | – | 9.4 / 9.4 / 18.4 | 5.7 | – |
| fujifilm_provia_100f | 11.3 / 12.2 / 14.9 | 8.3 | 7.9 | 15.2 / 15.0 / 18.0 | 11.9 | 11.6 |
| fujifilm_velvia_100 | 12.4 / 12.9 / 17.4 | 8.7 | 8.1 | 16.0 / 19.3 / 23.5 | 13.6 | 13.1 |
| fujifilm_xtra_400 | 9.5 / 9.4 / 19.2 | 6.4 | – | 13.0 / 13.5 / 23.5 | 8.9 | – |
| kodak_ektachrome_100 | 13.1 / 13.7 / 19.4 | 9.7 | 9.0 | 15.0 / 16.2 / 23.2 | 12.7 | 12.4 |
| kodak_ektar_100 | 7.8 / 6.6 / 12.9 | 3.4 | – | 11.6 / 10.7 / 19.5 | 5.8 | – |
| kodak_gold_200 | 7.3 / 6.2 / 10.6 | 3.4 | – | 9.8 / 8.7 / 14.5 | 4.5 | – |
| kodak_kodachrome_64 | 13.6 / 13.8 / 18.0 | 9.8 | 8.7 | 16.8 / 16.2 / 19.4 | 11.6 | 11.1 |
| kodak_portra_160 | 6.7 / 6.3 / 11.6 | 3.0 | – | 10.1 / 10.5 / 17.6 | 5.1 | – |
| kodak_portra_400 | 8.1 / 6.6 / 12.4 | 3.6 | – | 12.2 / 10.8 / 18.7 | 6.2 | – |
| kodak_portra_800 | 7.9 / 6.6 / 11.9 | 3.7 | – | 11.6 / 10.4 / 17.5 | 5.8 | – |
| kodak_portra_800_push1 | 9.4 / 7.7 / 13.5 | 4.5 | – | 13.9 / 11.8 / 19.4 | 7.0 | – |
| kodak_portra_800_push2 | 10.7 / 8.5 / 15.5 | 5.1 | – | 15.0 / 12.2 / 21.3 | 7.4 | – |
| kodak_ultramax_400 | 7.5 / 6.4 / 12.0 | 3.5 | – | 11.0 / 10.2 / 17.8 | 5.5 | – |
| kodak_verita_200d | 7.2 / 6.3 / 11.8 | 3.9 | – | 11.0 / 10.0 / 17.2 | 6.1 | – |
| kodak_vision3_200t | 7.0 / 6.3 / 11.1 | 4.1 | – | 10.1 / 9.6 / 16.0 | 6.0 | – |
| kodak_vision3_250d | 7.8 / 7.6 / 12.4 | 4.7 | – | 10.3 / 10.7 / 16.5 | 6.4 | – |
| kodak_vision3_500t | 8.0 / 7.0 / 12.6 | 4.7 | – | 10.6 / 9.7 / 16.7 | 6.3 | – |
| kodak_vision3_50d | 6.5 / 6.3 / 11.3 | 3.8 | – | 9.8 / 10.1 / 16.6 | 6.0 | – |
| kodak_tri_x_400 | 10.9 / 10.6 / 15.4 | 7.2 | – | 15.0 / 14.9 / 21.3 | 10.0 | – |

- The analytic model agrees with the renders to 0.7 % per channel and 1.3 % visual.
- Every negative renders 5.8–9.4 in green whatever its speed: 50D is as grainy as 500T, Portra 160 as
  Portra 800. The published curves differ by 1.6× in green between 50D and 500T.
- Slides are the grainiest colour films in the engine (visual 8–10) and on the sheets (8–10). They
  are the group that already agrees.
- The engine's blue record is 1.6–2.1× its green; the sheets' blue is 1.9–2.7× green on Vision3.
- Visual grain of a negative is far below any one record's (Portra 400: 3.7 against G 6.6),
  because the three records' grain is independent and each carries about 0.4 of the visual density.
- Pixel pitch: relative to 6 µm, every stock reads ×1.03–1.04 at 4 µm and ×0.87–0.88 at 12 µm
  (the grain blur is in pixels). `grain-all/engine_rms_pitch.csv`.

## 4. The amount each film would need

Amount = published ÷ rendered at 1. RMS is linear in `grain_amount` to 0.3 % (measured, 0–2).

| Film | Published | Basis | Amount, sub-layers on (app default) | Amount, sub-layers off |
|---|---|---|---|---|
| Tri-X 400 | 17 | visual, net D 1.0 | **2.35 (above the wire's 2)** | 1.70 |
| Kodachrome 64 | 10 | visual, gross D 1.0 | 1.15 | 0.90 |
| Provia 100F | 8 | visual, 1.0 over D-min | 0.96 | 0.67 |
| Velvia 100 | 8 | visual, gross D 1.0 | 0.99 | 0.61 |
| Ektachrome E100 | 8 | visual, gross D 1.0 | 0.88 | 0.65 |
| Pro 400H | 4* | visual, 1.0 over D-min | 1.10 | 0.71 |
| C200 | 4* | same | 0.70 | 0.51 |
| Superia X-TRA 400 | 4* | same | 0.63 | 0.45 |
| Vision3 500T | R 6.4 G 7.1 B 19.2 | per record, curves | 1.01 (green; R 0.80, B 1.53) | 0.73 |
| Vision3 200T | R 5.2 G 6.4 B 15.4 | per record, curves | 1.01 (R 0.74, B 1.38) | 0.66 |
| Vision3 250D | R 5.4 G 6.3 B 13.4 | per record, curves | 0.83 (R 0.70, B 1.08) | 0.59 |
| Vision3 50D | R 4.6 G 4.4 B 8.3 | per record, curves | 0.69 (R 0.71, B 0.74) | 0.44 |
| Verita 200D | R 7.4 G 6.7 B 18.2 | per record, curves | 1.06 (R 1.02, B 1.54) | 0.67 |
| Portra 160 / 400 / 800, Ektar 100, Gold 200, UltraMax 400 | none | Print Grain Index only | — | — |
| Portra 800 push 1 / push 2 | none | nothing published | — | — |


The Vision3 and Verita rows use the green record; one amount cannot fit three records.

## 5. What limits a per-film amount

1. **It changes sharpness.** The node computes `in + k·(grained − in)` and `grained` carries the
   0.65 px blur of the picture, so k scales that blur. Contrast of stripes against grain off,
   Portra 400 green, measured:

   | Stripe period | k 0.5 | k 1 | k 1.71 | k 2 |
   |---|---|---|---|---|
   | 8 px | 0.93 | 0.87 | 0.78 | 0.74 |
   | 4 px | 0.80 | 0.59 | 0.31 | 0.19 |
   | 3 px | 0.71 | 0.42 | 0.00 | −0.17 |
   | 2 px | 0.62 | 0.25 | −0.29 | −0.51 |

   At 0.63–1.15 (every colour film) the change is small. At Tri-X's 1.70 it is not.
2. **Tri-X needs the single-layer path.** With sub-layers on, 17 is 2.26 / 2.35 / 2.70 at
   4 / 6 / 12 µm, above the wire's 2.
3. **No figure for six Kodak still negatives** and none for the push profiles.
4. **Fujifilm's negative figure is on its own scale.**
5. **One amount per film is exact at one pixel pitch.**
6. **Slides:** whether a sheet means net or gross density moves the engine's number 5–11 %.

## 6. Reading

- For colour, a per-film amount moves little: the films with trustworthy figures (slides, Vision3
  green) land at 0.69–1.15, and the largest corrections rest on the weakest figures (Fuji's 4).
- What the engine lacks is not level but spread: its negatives are all alike in grain (RFC-030 §4
  said so; this measures it). That lives in `particle_area_um2` per film, which is engine data.
- Tri-X is the one film far from 1.

## 7. Files

`grain-all/published_granularity.{json,csv}`, `engine_rms.{json,csv}`, `engine_rms_pitch.csv`,
`per_film_grain_amount.json`, `linearity.json`; `measure_all.py`, `linearity.py`,
`default_amount.py`, `galib.py`; `sheets/_digitise/` (the curve reader). The fetched PDFs are local.
