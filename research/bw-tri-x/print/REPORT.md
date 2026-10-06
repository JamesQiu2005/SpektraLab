# B&W positive: base colour, silver image, and how the negative becomes a picture

Tags: SHEET (F-4017 / Ilford sheet), LIT, MEASURED (shipping dylib, scratch resources, this session), ASSUMED.
All profiles used are **stand-ins** from `build_profiles.py`; none is Tri-X or Ilford data.

## Findings

**1. Spectra.** No citable spectral-density curve for developed Tri-X silver or its grey base was found
(web searches). Everything spectral is ASSUMED: silver ∝ (550/λ)^n with n = 0.3
(blue/red density 1.12), plausible range n = 0…0.6 (1.00…1.25). Base: flat grey 0.24 + fog 0.06·silver for
135, 0.14 + 0.06 for 120 — only the totals 0.30 / 0.20 are SHEET. Candidates on the 81-point grid are in
`out/trix_candidate_spectra.json`. Schema: `channel_density[:,c] = silver/3` on all three channels with three
identical `density_curves`. `midscale_neutral_density` =
`base + D_mid·silver`; the engine parses it and never reads it (grep: `profile.cpp:82` only).
The uncertainty matters only on colour paper (3a).

**2. The three chains.** Print: film spectral density → enlarger lamp × C/M/Y dichroics → paper sensitivities
(`printing.cpp`) → paper curves (from `density_curves_model`, not `density_curves`) → paper dye spectra under
the viewing illuminant → XYZ → RGB. Scan (`scan_film`): the film's own spectra under its viewing illuminant;
a negative is **not inverted** by the engine. DI: base-free printing density through the `target_print`
paper's sensitivities, each channel reversed on its own neutral wedge → neutral by construction.
`neutral_print_filters.json` is keyed paper → illuminant → film; a missing row **silently** keeps
C0/M65/Y55 (`params.cpp:562`). The file is copied verbatim from the
upstream package (`bake_resources.py:226`); its solver is not in the REF tree. `print_luts.json` is keyed by paper only (8 papers),
used only by `spk_preview_stock_lut` / `spk_export_di`, never by a render; unknown paper → a named error,
film mismatch → a warning string.
Per-channel grain and halation cannot colour a B&W negative: three identical spectra sum to one neutral
density (std(R−G) is 3 % of grain std) — but the three independent grain streams average, which the grain
owner must account for.

**3. Options, cheapest first.**
(a) *Colour paper.* With no database row the print is orange (b* +34 at mid-grey). Hand-solving M/Y on the
mid-grey patch fixes mid-grey, and leaves a crossover that scales with the assumed silver slope: none beyond
the colour reference at n = 0, warm shadows / cool highlights of b* +2.6 / −2.1 at n = 0.3, +4.5 / −3.7 at
n = 0.6. The look rests on an unmeasured number.
(b) *DI.* Works today with zero changes, exactly neutral (C* = 0.00 on the photo, grain and halation on).
The scan path is the negative itself, tinted by base and silver; inversion would be host code.
One untested risk: the DI's colour-matrix fit has a singular normal matrix when the three sensitivities are
identical; it rendered correctly here, but I did not inspect the matrix.
(c) *Silver paper profile.* A variable-contrast paper fits the existing 3-channel paper schema with **no
engine change**: three emulsions = three channels, equal blue speed, staggered green speed, each forming
neutral silver. The stand-in prints neutral (C* ≤ 0.06) whatever the film's silver colour, and the existing
M/Y pack becomes a grade control: scene range 7.6 stops at Y170 to 2.4 stops at M170, mid-grey density
holding within 0.19. Ilford's sheet gives what a real one needs: ISO R per filter (180…40), speed per
filter, a sensitivity plot (to ~550 nm, no density levels marked on this copy), curve families per filter,
image/base tone names. Per-emulsion curves and sensitivities are not published and must be fitted
to that family.
(d) *Desaturate at the end.* Removes exactly the crossover of (a) (C* mean 2.0, p95 2.9); L* unchanged.
A post-print edit: paper, filters and image tone stop meaning anything.

**Recommendation.** First version: (b) DI as the B&W positive — zero engine change, neutral, no unmeasured
spectrum in the picture; but it has no paper and no grade. Proper target: (c), one silver paper profile.
Image tone lives in that paper profile's `channel_density` slope and `base_density` tint (warm stand-in:
a* +1.7, b* +7.1 at mid-grey); toning would be a variant profile.

**4. Physical edits only.** On colour paper the M/Y sliders only tint a B&W negative (±1 at scale 40 moves
mid-grey 35–45 in a*/b*). On a VC silver paper the same two sliders are the grade: M60/Y60 pack,
`filter_shift_scale` 60, m = −y from −1 to +1 spans 6.7 → 2.45 stops. A single "Grade" control is app-side only. The stand-in's stagger (1.2 log) reaches R≈129, not Ilford's R180, and mid pack is too hard —
calibration, not structure.

## Numbers

| Quantity | Value | Tag |
|---|---|---|
| Tri-X base+fog, 135 / 120 | 0.30 / 0.20 | SHEET |
| Silver slope n, D ∝ (550/λ)^n | 0.3 (0…0.6); blue/red 1.12 (1.00…1.25) | ASSUMED |
| Fallback pack for a missing pair | C0 M65 Y55 | MEASURED |
| BW n=0.3 on Portra Endura, fallback: mid-grey a*, b* | +7.6, +33.5 | MEASURED |
| Hand-solved pack, Endura, n=0 / 0.3 / 0.6 | M79.7 Y98.1 / M72.4 Y85.3 / M65.8 Y72.6 | MEASURED |
| Crossover after solve, b* range (8<L*<92), n=0 / 0.3 / 0.6 | 1.5 / 4.7 / 8.2 | MEASURED |
| Same, Portra 400 colour reference | 1.9 | MEASURED |
| n=0.3 solved on Crystal Archive / 2393: max C* | 3.8 / 4.8 | MEASURED |
| Photo, Endura solved: C* mean / p95 | 2.00 / 2.85 | MEASURED |
| Photo, DI live and Cineon export: C* max | 0.0 | MEASURED |
| Photo, scan_film: a*, b* mean (negative, uninverted) | +0.8, +3.2 | MEASURED |
| VC stand-in, scene range Y170 / M40Y40 / M170 | 7.63 / 3.35 / 2.41 stops | MEASURED |
| VC stand-in, mid-grey density across packs | 0.75…0.94 | MEASURED |
| VC stand-in, max C* (any film slope) | 0.06 | MEASURED |
| Grain, flat field, BW scan: std(R−G) / std(G) | 0.00001 / 0.00029 | MEASURED |
| Ilford MG IV RC ISO R, filters 00…5 | 180 160 130 110 90 60 40 | SHEET |
| Ilford MG IV RC ISO P, 00–3 / 4–5 / none | 200 / 100 / 500 | SHEET |
| MG RC Dmax (read off the curve plot) | ≈2.1–2.2 | SHEET (eyeballed) |

## Files (scratch dir `print/`)

- `common.py` helpers; `build_profiles.py` stand-in film (`standin_bw_n00/n03/n06`) and paper
  (`standin_vc_paper`, `_warm`) profiles into `res/` (a copy of `engine/resources`, big files symlinked).
- `exp_colour_paper.py` → `out/colour_paper.json`, `out/ramp_bw_on_endura_{fallback,solved}.png`
- `exp_scan_di.py` → `out/scan_di.json`, `out/ramp_{scan_film,di}_bw.png`
- `exp_vc_paper.py` → `out/vc_paper.json`
- `exp_smoke.py` → `out/smoke_*.png`, `out/smoke.json`; `out/contact_sheet.png` (ten renders side by side)
- `exp_grain_channels.py` (grain/halation channel agreement, prints only)
- `make_candidates.py` → `out/trix_candidate_spectra.json`; also checks the database row and LUT lookups
- `out/ilford_multigrade_rc_2019.pdf` (Harman, Jun 2019, from ilfordphoto.com)

Re-run: `cd print && "$REF/.venv/bin/python" build_profiles.py && "$REF/.venv/bin/python" exp_<name>.py`
(`common.py` adds `engine/tests` and `$REF/src` to the path itself).
