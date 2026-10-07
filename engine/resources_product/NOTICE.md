# `engine/resources_product/` — the product's own data

These files are SpektraLab's, not spektrafilm's. `engine/resources/` is spektrafilm's baked output
(28 profiles, CC BY-SA 4.0, unmodified) and stays that way; nothing here is copied or derived from
an array in it. Keeping the two directories apart is what keeps that statement true.

| File | What it is | Built from |
|---|---|---|
| `profiles/kodak_tri_x_400.json` | Kodak Tri-X 400 (400TX), 135, D-76 to contrast index 0.56. One panchromatic emulsion written identically into the schema's three channels, neutral silver (`channel_model: "bw"`). | Kodak publication F-4017 (Feb 2016): spectral sensitivity and characteristic curves digitised from the PDF's vector paths. |
| `profiles/ilford_multigrade_iv_rc.json` | Ilford Multigrade IV RC, a variable-contrast silver paper: three emulsions, one per channel. A feasibility fit. | HARMAN technology Ltd, "MULTIGRADE RC PAPERS Technical Information" (June 2019): curve family traced from raster charts, ISO R / P tables. |
| `paper_grades.json` | Multigrade filter 00–5 → `m_filter_neutral`, `y_filter_neutral`, `print_exposure`. | Fitted and then measured on engine renders. |
| `neutral_print_filters.json` | The filter-2 pack for (Multigrade IV RC, TH-KG3, Tri-X 400), in the shape of `engine/resources/neutral_print_filters.json`. | The same fit. |

What is taken from the sheets and what is assumed is tagged inside each profile's `metadata` and
written up in `research/black-and-white-tri-x.md`. "Kodak", "Tri-X", "Ilford" and "Multigrade" are
their owners' trademarks; the names say which published data a profile was built from.

**Not wired.** The engine loads a profile from `<resources>/profiles/<stock>.json`, and nothing
copies these there: they are not in the app bundle, not in the stock catalogue, and no control in
the app reaches them. `engine/tests/bw_checks.py` renders them from a scratch resources directory
that overlays this one on `engine/resources/`. The engine does not read `paper_grades.json` or this
directory's `neutral_print_filters.json`; a caller sends the pack on the wire.
