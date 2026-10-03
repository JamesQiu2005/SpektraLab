# Handoff: Film Edge on desktop — the fixes, what the owner saw, what is next (2026-10-03)

**Start here.** Film Edge (RFC-032) and Date Back (RFC-031) are on desktop `main`, with a day of fixes
behind them. This file is the state at the end of 2026-10-03. The previous handoff,
`HANDOFF-2026-10-02-half-frame-pair-and-panoramic.md`, still holds the design, the answer sheet and the
owner's settled decisions; read that one for *why*, this one for *where things stand*.

## 1. Read first

1. `PRD/QUESTIONS-2026-10-02-half-frame-film-edge-panoramic.md` — the owner's answers. Blank = ask.
2. `PRD/HANDOFF-2026-10-02-half-frame-pair-and-panoramic.md` §3 (settled decisions) and §6 (the sync).
3. `API-SPEC-callable-render-service.md` §13 — the wire, the refusals, and the "We assumed it wrong" note.
4. `AGENTS.md` traps, `README.md`, as always.

## 2. What landed today, in order

| commit | what |
|---|---|
| `7ce3334` | the engine sync from `SpektraLab_mobile` `371ad16`, by hunks |
| `7be561b` | engine: the latitude probe switches overscan and the date off |
| `68d249a` | the app: model, session, canvas, the Film Edge and Date Back sections, en + zh-Hans |
| `17f48ed` | **engine: a film canvas reprints.** The live tier after the full one, after a print-layer rebuild, and the DI export all failed with "the negative does not match this pipeline's overscan layout". Each tier keeps the frame its negative was laid out for; `Pipeline::set_overscan_frame` before a print run |
| `7a45fae` | the date alone follows the crop, the turn and the flip: the frame is cut before the engine (`FilmParams.cutsFrame`); pitch kept, the date scaled to the picture |
| `0545ffa` | the data face needs a film edge, and the section says so |
| `544606a` | the canvas decodes the print it shows (by its stamp), not the one the settings ask for |
| `705aa7a` | engine: edge text cut to its slot; the date kept inside the frame; a frame that is not the gate's shape refused (±5 %) |
| `c2120e5` | a crop fitted at the tolerance is snapped onto the frame |
| `c9d2db9` | a film edge loaded from a sidecar holds its crop at the gate before it develops |
| `a919411` | "We assumed it wrong": every Fujifilm stock's film edge carries Kodak's marks (§5) |

Full suite at the end: 509 tests, 1 skipped, 0 failures, ~348 s with fixtures. `overscan_checks.py`: 49/49.
Parity (`parity_schema`, `parity_render`, `parity_session`) green; 18 renders with Film Edge off are
byte-identical to the engine before the sync.

**Three engine fixes were written on desktop and must cross to mobile at the next sync:** `7be561b`,
`17f48ed`, `705aa7a`. The desktop copies of `overscan_checks.py` and `parity_session.py` now send frames
of the gate's shape; the mobile copies must follow, and the mobile UI must be checked for sending an
uncropped picture (it would be refused).

## 3. The owner's observation: the app felt extremely slow

**Reported by the owner on 2026-10-03, with the app running on a 16 GB MacBook, not measured by anyone
yet:** "with some actual running log the app felt extremely slow". The owner's assumption is **RAM**.
Nothing in this session measured it; treat it as the first thing to measure, not as a conclusion.

What is known that points the same way:

- Every capture of the 8,256 × 5,504 frame with Film Edge on showed the **`low memory headroom`** badge
  (`Session.memoryWarning`). The film canvas is larger than the picture — up to ~1.5× its pixels — and the
  full render of it is a second copy at that size (6,298 × 5,788 for a 6,000 × 4,000 picture; the
  Debug-build caption read 69.8 MP for the 8,256 × 5,504 frame).
- With Film Edge on (and now with the date under a crop, `7a45fae`), the decode is **cut by Core Image
  before the engine** (`Session.engineImage`), which is a further linear copy while the frame is handed
  over.
- The engine's arena estimate is still `Session.engineArenaEstimateBytes = 1.2 GB` per open; the memory
  forecast for a film edge is `Session.developForecastPixels`, and the refusal `FilmEdgeTooLarge` is on
  an estimate of the canvas, not a measurement.
- Memory notes to read before measuring: `full-tier-peak-is-unflushed-buffers`, `rfc020-measurement-traps`
  (RSS cannot see a Metal pool; reclaimed pages arrive late), `rfc020-outcome-confirmed` (the app's own
  boundary samples under-report by ~1 GB), `kept-pool-is-erratic-on-the-live-tier`.

How to measure it (the instruments exist):

1. `Diagnostics` (RFC-016) — start logging, open the slow frame with Film Edge on, do the slow thing, stop;
   the log carries the `MemorySampler` boundary samples and the engine's `spk_memory_report`.
2. `engine/tests/memory_report.py` and `frame_switch_footprint.py` for the engine alone, with
   `overscan_active = true` on a frame of the owner's size (the probes were written before overscan; add
   the fields).
3. Compare against the same frame with Film Edge off: the difference is the feature's cost. The
   `low memory headroom` threshold and what triggers it are in `Session.memoryWarning`.
4. If it is swap (a 16 GB machine at 13.7 GB peak on a 102 MP frame was already measured in
   `rfc020-outcome-confirmed`), the levers are: the full render of the film canvas (drop or defer it on low
   headroom), the cut copy (cut on the GPU rather than through Core Image), and the live tier's canvas size.

**Do not** tune anything before the log says where the time goes: "felt slow" could as well be the
re-develop every film-edge edit costs (every field is shoot layer, so each is a full develop, ~1 s at
45 MP), which is not memory at all. The log distinguishes them.

## 4. Still open from the bug hunt

- **Metering under a cut.** With the date on over a cropped picture the engine meters the crop, so auto
  exposure can shift when the date goes on. Needs a meter input the engine does not have. Not measured.
- **Compare, Space-original and the white-balance picker are off** while the canvas shows a cut print
  (film edge, or the date under a crop/turn/flip): the engine cannot yet say where the picture sits
  (`spk_overscan_geometry`). The histogram counts the rebate.
- **Slide films:** the film edge draws the marks as exposure through the reversal curves (black rebate,
  light marks), and the app always scans a positive. Unverified against a real E-6 strip: the edge
  print's colour (olive-yellow in the render) and the date's (dim yellow-grey; a real one is orange-red).

## 5. We assumed it wrong — every Fujifilm stock's film edge (done 2026-10-03, `4fbbe96`, `653fe52`)

The owner, 2026-10-03: the Fujifilm stocks' film edges were copied straight from Kodak. The owner then
supplied 16 scans in `reference_film/` (135: RVP50, RDPIII, X-Tra 400, C200, Portra 160/800, UltraMax,
Gold 200, 5207; 120: RVP50 6x6, Pro 400H 6x7, RDPIII 645, E100/Portra 400/Ektar 6x6, Gold/Portra 160 6x7;
**untracked**, the owner's to commit or not). Measured as RFC-032 §29.2 measured Kodak (px/mm from the
4.75 mm perforation pitch, or the 61 mm film), and the edge is now the stock's own (`kEdgeLooks`,
`overscan.cpp`):

| stock | layout now | reference |
|---|---|---|
| Provia 100F | Fujifilm slide: no DX bars, 5x7 face, bold numbers (caps 1.64) on both edges, name 16 mm on, "36 ▷12A"; 120: Fujifilm 120 | RDPIII 135 + 645 |
| Velvia 100 | the same; host text "RVP100" | **RVP50** only (borrowed) |
| X-Tra 400 | Fujifilm negative: 14.1 mm DX (628), condensed numbers on both edges, "S-400" | X-Tra 400 135 |
| Pro 400H | 120: one edge, "FUJI"/roll no., "13 ◀", "PRO400H", "EFCDCD"; **135 borrows X-Tra's** | 120 6x7 only |
| C200 | Kodak's layout (it is Kodak-made: DX part 1 = Gold's), regular weight, "FUJI 200", DX 1550 | C200 135 |
| Vision3 | one "EASTMAN 52xx" line + dashes, no numbers/bars; the line's period is ≥41.5 mm, 76 assumed | 5207 135 (others borrow) |
| Kodak negatives | fixed: DX 12.7 mm (was 13), sizes/positions, wide numerals, tan colour (was olive), DX numbers read off the strips (Gold 1548, Portra 160 1534) | 4 × 135, 5 × 120 |
| E100 | white marks (was olive); 135 layout still Kodak's, **unverified** | E100 120 only |

Also: the 135 gate is 36.25 × 24.3 mm (measured mean; it sat 0.70 mm from the perforations, real ones
0.47–0.67), and a 120 gate is centred ±0.45 mm (was ±0.1). Not reproduced, on purpose: the red/green lines
on the X-Tra strip (its camera's), the X-Tra "H74" batch code, Kodak's "KO.DAK" dot, emulsion suffixes
("-7"), and real roll numbers. Colours match the references' hue, not their level (scan-dependent).
Comparison sheets (reference | before | after): the session scratchpad `edge/cmp_*.png`.

**Must cross to mobile at the next sync:** `4fbbe96` (by hunks) and the matching `overscan_checks.py`
hunks. Mobile's host text is display names, so it does not take `653fe52`. API-SPEC §13 needs the edit
listed in that commit's report (36 → 36.25 gate, per-stock edges, the DX numbers); not edited here.

## 6. Waiting on the mobile-first engine work (answer A3)

`spk_overscan_geometry`; `overscan_turn`; holes as a print-layer field; the carrier enum; the data face's
two colours (E12); the panoramic formats and the canvas-trim fix (C2); perforations in a Digital
Intermediate; the Frame / + Overscan scope (B4); then the half-frame pair's E1/E2. The `SpektraLab_mobile`
tree was mid-merge all day (`UU engine/src/pipeline/pipeline.cpp`); nothing here touched it.

## 7. Open with the owner

B17 (turned pairs); E3's "No"; the clipboard group for Film Edge and Date Back (F10); whether cine stocks
belong in the 135 formats (allowed now); the UI placeholder note for Fujifilm edges (§5).

## 8. Next, in the owner's order

Measure the slowness first (§3). The Fujifilm edge layouts are done (§5). Then the
half-frame pair without Film Edge (HFP P1–P4, Swift only), which needs none of §6.
