# `engine/resources_product/` — the product's own data

These files are SpektraLab's, not spektrafilm's. `engine/resources/` is spektrafilm's baked output
(28 profiles, CC BY-SA 4.0, unmodified) and stays that way; nothing here is copied or derived from
an array in it. Keeping the two directories apart is what keeps that statement true.

| File | What it is | Built from |
|---|---|---|
| `profiles/kodak_tri_x_400.json` | Kodak Tri-X 400 (400TX), 135, D-76 to contrast index 0.56. One panchromatic emulsion written identically into the schema's three channels, neutral silver (`channel_model: "bw"`). | Kodak publication F-4017 (Feb 2016): spectral sensitivity and characteristic curves digitised from the PDF's vector paths. |
| `profiles/kodak_tmax_100.json` | Kodak T-Max 100 (100TMX), D-76 small tank to contrast index 0.56 (6.2 min). Same construction as Tri-X. | Kodak publication F-4016 (June 2018): spectral sensitivity and characteristic curves digitised from the PDF's vector paths. |
| `profiles/fujifilm_neopan_acros_100_ii.json` | Fujifilm Neopan 100 Acros II, 135, D-76 at the sheet's own 7¼ min (contrast index 0.57). Same construction. | FUJIFILM data sheet AF3-0258E: the charts are 300 dpi images in the PDF, traced at 600 dpi. The "spectrogram to daylight (5400K)" has a 5400 K black body divided out. |
| `profiles/ilford_hp5_plus_400.json` | Ilford HP5 Plus 400, ILFOTEC HC 1+31 for 6½ min (the one curve the sheet plots; contrast index 0.60). Same construction. The sheet's exposure axis is relative: the film is taken to have exactly its rated speed. | HARMAN technology Ltd, "HP5 PLUS Technical Information" (Nov 2018): raster charts, traced at 600 dpi. The "wedge spectrogram to tungsten light (2850K)" is taken as drawn, the reading that reproduces the daylight filter factors Ilford publishes for HP5 Plus (its motion-picture fact sheet). |
| `profiles/ilford_multigrade_iv_rc.json` | Ilford Multigrade IV RC, a variable-contrast silver paper: three emulsions, one per channel. A feasibility fit. | HARMAN technology Ltd, "MULTIGRADE RC PAPERS Technical Information" (June 2019): curve family traced from raster charts, ISO R / P tables. |
| `paper_grades.json` | Multigrade filter 00–5 → `m_filter_neutral`, `y_filter_neutral`, `print_exposure`. The pack is the paper's; it was fitted on Tri-X and prints the other three films' mid-grey at the same density (`bw_checks.py`). | Fitted and then measured on engine renders. |
| `neutral_print_filters.json` | The filter-2 pack for (Multigrade IV RC, TH-KG3) and each of the four films, in the shape of `engine/resources/neutral_print_filters.json`. | The same fit. |

What is taken from the sheets and what is assumed is tagged inside each profile's `metadata` and
written up in `research/black-and-white-tri-x.md` and `research/black-and-white-three-more-films.md`.
"Kodak", "Tri-X", "T-Max", "Fujifilm", "Neopan", "Acros", "Ilford", "HP5" and "Multigrade" are
their owners' trademarks; the names say which published data a profile was built from.

**In the macOS app's Debug builds only** (2026-10-09). The engine loads a profile from
`<resources>/profiles/<stock>.json`, so `engine/build.sh bundle` copies these profiles and this
notice into the app's `Resources/engine/`; the app lists them only where
`FeatureFlags.blackAndWhite` is on. `engine/tests/bw_checks.py` renders them from a scratch
resources directory that overlays this one on `engine/resources/`. The engine does not read `paper_grades.json` or this
directory's `neutral_print_filters.json`; a caller sends the pack on the wire.
