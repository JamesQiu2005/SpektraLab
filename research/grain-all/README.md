# Granularity for every shipped film, and the grain amount each would need

2026-10-07, branch `bw-tri-x`. Owner's decision: no engine change for grain; each film is tied to one
default `grain_amount`. This folder is the data for that table. Nothing in the app reads it yet.

- `published_granularity.{json,csv}` — what each maker publishes, with document, edition, page, URL.
  The fetched PDFs (`sheets/*.pdf`) are local only.
- `engine_rms.{json,csv}`, `engine_rms_pitch.csv` — what the engine renders at `grain_amount` 1,
  measured on the built engine (per dye record and as visual density, sub-layers on and off, 4/6/12 µm).
- `per_film_grain_amount.json` — published ÷ rendered, at 6 µm pixels.
- `default_amount.py`, `measure_all.py`, `linearity.py`, `galib.py` — re-run (see each file's header).

## The table (6 µm pixels; amount = published ÷ engine at 1)

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

\* Fujifilm's negative sheets say the figure cannot be compared with reversal film's. It is not on
Kodak's scale either.

## What limits this

1. **`grain_amount` is not amplitude only.** The node mixes `in + k·(grained − in)` and `grained`
   carries the 0.65 px blur of the picture, so k scales that blur too. Stripe contrast against
   grain off, Portra 400: 4 px period 0.59 at k = 1, 0.31 at 1.71, 0.19 at 2; 2 px period 0.25, −0.29,
   −0.51. Above 1 the picture softens and the finest detail inverts; below 1 it sharpens. MEASURED.
2. **Six Kodak still negatives have no RMS**, in any edition back to 1996, and Kodak publishes no
   PGI-to-RMS conversion (E-58: "cannot be compared"). The one film printing both (Portra 400BW:
   RMS 9, PGI <25/40/70) would put Portra 400 near 16, as grainy as Tri-X; rejected.
3. **The Vision3 and Verita values are per-record curve readings**, ±10 %, and one amount cannot
   match three records: blue wants 1.1–1.5 where green wants 0.7–1.1. The table uses green.
4. **Pixel pitch.** Exact at 6 µm; every amount ×0.96 at 4 µm and ×1.15 at 12 µm.
5. **Tri-X needs the single-layer path.** With sub-layers on, 17 is out of the wire's range at every
   pitch (2.26 / 2.35 / 2.70 at 4 / 6 / 12 µm).
6. Slides: a sheet's basis (net or gross density) moves the engine's number 5–11 %.

Only Tri-X is far from 1. The colour stocks with data sit between 0.63 and 1.15 with sub-layers on.
