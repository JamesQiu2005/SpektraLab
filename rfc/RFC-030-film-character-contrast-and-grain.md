# RFC-030: Film character: per-stock contrast in the DI, and per-film grain

**Status:** §2 implemented 2026-09-29 for 1.2.1 (see §2.1). §3 is the option A handoff. §4 is gated on real data and not implemented.
**Follows:** RFC-028 (the Digital Intermediate) and `handoff/HANDOFF-DI-SCAN-TIFF.md` (option A, local-only).

## 1. Why: "every Vision3 DI looks the same"

The user's report, after 1.2.0: the Kodak Vision3 series looks identical through the DI, grain included. We checked whether the DI was too successful, or whether a profile was being mixed.

**Probe:** a ColorChecker, a grey ramp from −6 to +6 stops, and flat grey. Each of 8 films was rendered as a DI and as a 2383 print, all at the same exposure with no metering.

**Nothing is shared by mistake.** A session opened on 50D and switched to 500T is bit-identical to a fresh 500T session. The DI rebuilds its constants for each film.

**Colour differences between films** (Oklab ×100, neutral-5 levelled; about 2 is just noticeable):

| Films | DI | on 2383 |
|---|---|---|
| Vision3, among themselves | mean 2.0, worst 8.4 | mean 1.3, worst 3.7 |
| Stills | mean 2.2 | mean 2.3 |

The Vision3 family is near-identical in its data, and the paper makes the films *more* alike than the DI does.

**Two things are real:**
- **Contrast is removed by design.** The DI's reversal divides each film's printing density by that film's own γ_green (`digital_intermediate.cpp`, the table loop). So every film's tone is the scene's from −3 to +5 stops, and the films differ only in the toe. See §2.
- **Grain has no per-film data at all.** See §4.

## 2. Per-stock contrast in the DI (proposed, next step)

**Where the DI leans.** The DI is correct for what it claims: greys are neutral to < 0.01 stop and the colour step is fitted, not guessed. But compared with a real scanner's Cineon, it leans toward the scene in three ways:
1. **Contrast is normalised to 1.0.** A real Cineon scan keeps the film's printing-density gamma, and a standard decode, which assumes 0.6, returns a contrast of γ/0.6. This RFC restores it.
2. **Per-channel gammas are equalised** (every channel is mapped onto green's curve). A real scan keeps R/G/B gamma differences as colour crossovers. We keep the equalisation: exact neutrality is what a DI is for.
3. **The 3×3 undoes the film's spectral eye toward the scene.** A real Cineon file carries printing-density primaries, and its look comes from the print emulation. We keep the matrix; without it, ProPhoto values would mean nothing.

**Measured printing-density gammas.** These come from the neutral wedge through the engine, read with each film's target paper and lamp (the DI's own read), fitted over ±2 stops. Source: `rfc/probes/rfc028-demask-probe.py` Inversion.

| Film | Paper | γ R / G / B | G / 0.6 |
|---|---|---|---|
| Vision3 50D | 2383 | 0.530 / 0.537 / 0.539 | 0.90 |
| Vision3 250D | 2383 | 0.519 / 0.528 / 0.536 | 0.88 |
| Vision3 200T | 2383 | 0.512 / 0.521 / 0.525 | 0.87 |
| Vision3 500T | 2383 | 0.516 / 0.525 / 0.538 | 0.88 |
| Portra 160 | Portra Endura | 0.534 / 0.562 / 0.566 | 0.94 |
| Portra 400 | Portra Endura | 0.545 / 0.568 / 0.577 | 0.95 |
| Portra 800 | Portra Endura | 0.518 / 0.547 / 0.549 | 0.91 |
| Ektar 100 | Portra Endura | 0.560 / 0.594 / 0.598 | 0.99 |
| Gold 200 | Portra Endura | 0.550 / 0.574 / 0.590 | 0.96 |
| UltraMax 400 | Portra Endura | 0.531 / 0.553 / 0.556 | 0.92 |
| Fujifilm C200 | Crystal Archive II | 0.617 / 0.629 / 0.652 | 1.05 |
| Fujifilm Pro 400H | Crystal Archive II | 0.543 / 0.562 / 0.569 | 0.94 |
| Fujifilm X-Tra 400 | Crystal Archive II | 0.651 / 0.672 / 0.697 | 1.12 |

**Proposal.** Reverse on Cineon's own negative gamma instead of the film's:

`y = log10(0.18) + (D_green − D_green,mid) / 0.6`  (today: `/ γ_green`)

- Nothing new is invented. 0.6 is the constant Cineon's 300 codes per decade already encodes, so the file becomes printing density at exactly 0.002 D per code, as a scanner writes it.
- Grey stays anchored at 0.18, as a scanner operator balancing to LAD would. Neutrality stays exact, and the toe and shoulder are unchanged.
- There is no new parameter, so nothing new is copyable.

**What it does:**
- Vision3 renders 12–13 % flatter than the scene, Portra about 5 %, Ektar at scene contrast, C200 +5 % and X-Tra +12 %.
- **It will not make the Vision3 stocks distinct from each other.** Their gammas sit within 3 % (0.521–0.537). That is the data, and it is why they intercut.
- The Cineon ceiling (+6.2 decoded stops) holds 6.2 × 0.6/γ scene stops: about +7.0 for Vision3 and +5.5 for X-Tra.
- The blue compensation re-fits on the chain unchanged. The view LUT's knee is in decoded stops and is unchanged.

**Tests.** Keep the neutral wedge and the mid-grey anchor. Add one test: the DI ramp's slope over ±2 stops equals γ_green/0.6 for two films with different gammas (Vision3 and X-Tra). Show that it fails on today's code.

### 2.1 Implemented (2026-09-29, for 1.2.1)

The change is one divisor:
- `digital_intermediate.cpp`, the table loop, now divides by `kDiCineonNegativeGamma` (= 0.002 × 300 = 0.6, defined beside the other Cineon constants in `digital_intermediate.hpp`);
- `gamma_green` is still measured, for the "no usable contrast" guard.

**Measured DI tone slope** (decoded green, log2, fitted over −2…+2 stops; base subtraction steepens the −2 patch slightly):

| Film | before (own γ) | now (Cineon 0.6) |
|---|---|---|
| Vision3 50D | ≈ 1.04 | 0.94 |
| Vision3 250D / 200T / 500T | ≈ 1.0 | 0.92 / 0.91 / 0.92 |
| Portra 400 | ≈ 1.07 | 1.01 |
| Ektar 100 | not measured | 1.07 |
| Fujifilm C200 | not measured | 1.12 |
| X-Tra 400 | ≈ 1.10 | 1.20 |

**Colour spread between films** (the §1 probe): Vision3 2.03 → 1.89, stills 2.24 → 2.48. As §2 predicted, the change separates film *families* by contrast. It does not separate the Vision3 stocks from each other: their data is within 3 %.

**Test.** `DigitalIntermediateTests.testTheDIKeepsEachFilmsContrast` requires 50D < 0.98, X-Tra > 1.1 and a gap > 0.15. On the old divisor it fails all three (1.04, 1.096, 0.056); it passes on the new one. The neutral wedge test (Portra) is unchanged and green.

## 3. Option A: the DI as float inside the app

`handoff/HANDOFF-DI-SCAN-TIFF.md`. It is independent of §2, and §2 carries over unchanged: the slope lives in the reversal table, not the encoding.

## 4. Per-film grain (gated on real data; nothing may be invented)

**State.** No film profile carries grain, ISO or granularity data. The grain model's parameters are global:
- `particle_area_um2 = 0.2`, `particle_scale = {1.6, 1.6, 3.2}`, `uniformity = {0.97, 0.99, 0.97}`;
- in the engine at `engine/src/core/params.hpp:35–39`;
- in the Python reference at `spektrafilm/runtime/params_schema.py:103`.
Every film therefore has the same grain on every path, prints included.

Measured std of log2 Y on flat grey, grain on:

| Path | Across 8 films |
|---|---|
| DI | 0.0145–0.0177 stops |
| 2383 | 0.020–0.028 stops |

50D (0.0145) and 500T (0.0159) are indistinguishable.

**What is needed:**
- **Each stock's published RMS diffuse granularity**, from the manufacturer's datasheet. Kodak and Fujifilm quote it ×1000 at a net diffuse density of 1.0 through a 48 µm aperture; confirm the convention on each sheet.
- Where a sheet gives per-layer or per-density values, record them as given.
- Record the source (sheet id, revision, page) beside each value, in the profile or a sidecar table.
- **No value is estimated from ISO or interpolated between stocks.** A stock without a sheet keeps today's global default, and the UI or notes say so.

**How it would map.** Calibrate `particle_area_um2`, and possibly `particle_scale`, per film so that the model's own RMS granularity matches the sheet. Measure the model with a 48 µm aperture on a flat patch at D = 1.0 above base, at the film's physical format.
- This is a model change for **every** render, not only the DI.
- It needs a parity story: the Python reference has the same global defaults, so either the reference gains the same per-film table, or the harness gets a documented divergence.
- The calibration measurement itself belongs in `engine/tests/`.

**Open questions for the user:**
- Which sheets to collect first (the Vision3 four and Portra 400 are the obvious start).
- Whether a stock without data should be marked in the Film list.

## 5. Reproduce

Both need `engine/build.sh dylib` first, because `bundle` leaves the ctypes dylib stale. Run them with `../spektrafilm/.venv/bin/python`.

- `rfc/probes/rfc030-film-spread.py`: colour spread, grey ramp, grain, and the stale-constants check (§1, §4).
- `rfc/probes/rfc030-printing-gamma.py`: the printing-density gamma table (§2), through the RFC-028 probe's `Inversion`.
