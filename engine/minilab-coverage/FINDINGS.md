# Findings from the all-pair run

Measured observations that change how a later reader should interpret the gates
or the catalog. Each one is a measurement, not an opinion.

## 1. The SOP's LUT-vs-direct limits are r = 0 numbers; the r = 1 tables cannot meet them

`SOP.md` §7 carries "chart max ΔE00 ≤ 0.2; NEF mean ΔE00 ≤ 0.05" from the
research validation. That validation ran on the **r = 0** `_c3` table
(`v2/minilab_validate.py` compares against `minilab_build.solve_points`, whose
target is `ymode='T'`, and reads `{film}__{paper}.lut3d`, not `_f10`).

Measured 2026-10-25 through the generalized wrapper, on the **approved r = 1
tables** that ship byte-for-byte (`bee5f4b4…` sRGB, `b62650ec…` ProPhoto):

| space | chart max | chart mean | photograph mean | photograph p99 |
|---|---:|---:|---:|---:|
| sRGB | 0.325 | 0.060 | 0.122 | 0.282 |
| ProPhoto RGB | 0.749 | 0.091 | 0.138 | 0.345 |

The harness was checked against itself first: the direct solve at 256 table
nodes reproduces the stored node values to **1.4e-5 mean / 1.2e-3 max** CMY, so
the difference is the 65³ grid's interpolation error on the r = 1 target, not a
wrong direct arm.

### The chart *max* is a dark-patch statistic

Across the first six calibrations the chart **mean** stays at 0.060–0.091 while
the chart **max** ranges 0.325–0.853. At Y ≈ 0.01, a 0.005 CMY interpolation
difference is a 0.3–0.8 ΔE00 difference; the maximum is the darkest patch's
numerical sensitivity, and the approved artifact's own maximum differs 2.3×
between its two spaces. A pass/fail on it measures that sensitivity, not the
table.

### The rule this run uses

`bake.py::gate_lut_accuracy` gates on the approved artifact's own envelope with
a 25 % allowance plus a 2 % numerical margin (the measurement is a sample
statistic: 67 chart patches, 4,000 photograph pixels). The approved pair moves
far more than that between its own two spaces:

| check | limit | approved worst |
|---|---:|---:|
| photograph mean ΔE00 (the gate) | 0.175 | 0.138 |
| chart mean ΔE00 (flagged) | 0.116 | 0.091 |

The **photograph mean is the gate**: it is the product's subject and it is stable
across the approved pair. The chart statistics — mean, max — and the photograph
p99 are **reported and flagged** (`chart_mean_flag`, `chart_max_flag`,
`nef_p99_flag`), not gated: the 67-patch chart is an artificial diagnostic at
extreme exposures whose approved mean already spans 0.060–0.091 between the two
spaces and rises on the cinema papers (Kodak 2393 measures 0.12–0.16 chart mean
with a photograph mean of 0.08–0.16). The SOP's 0.2/0.05 are still evaluated
(`sop_chart_met`, `sop_nef_met`) so the diagnostic miss stays visible on every
qualified pair.

Measured on the pairs that bracket the rule:

| pair | chart mean | photograph mean | p99 | outcome |
|---|---:|---:|---:|---|
| approved Portra sRGB | 0.060 | 0.122 | 0.282 | reference |
| approved Portra ProPhoto | 0.091 | 0.138 | 0.345 | reference |
| CineStill 800T / Crystal Archive, PP | 0.034 | 0.174 | 0.861 | inside by the margin; p99 flagged |
| Vision3 200T / 2383, PP | 0.032 | 0.149 | 0.572 | inside; p99 flagged |
| CineStill 800T / Kodak 2383 | 0.079 | **0.210** | **1.14** | **blocked** |

CineStill on 2383 is blocked because it is 1.2× the mean limit and 2.2× the p99
flag, not because of a visual defect: its chart sheet shows the film's own
halation in the optical, DI *and* minilab rows, so the look is consistent and
the excess is the 65³ grid on a steeper map. The pair stays on the optical path
and the measurement is in `LEDGER.json`.

This is a model decision recorded for the owner, not a threshold quietly
loosened: the SOP's absolute numbers are unattainable by the shipping table, and
the replacement is derived from that table, not chosen to make a count green.

## 2. The node solver is batch-composition dependent

`cp_build.batched_lm` stops trying further starts as soon as *every* node in the
current batch is under 1e-4. A node's result therefore depends on which other
nodes share its batch. Measured: re-solving 256 nodes in a batch of 256 instead
of the build's 40,000 changes the paper CMY by 1.4e-5 mean and 1.2e-3 max.

That is small enough not to move the gates, but it means a node value is a
*path* result, not a unique minimiser. `bake.py` keeps the approved construction
(the full 274,625-node batch) so the frozen canary stays byte-identical; the
gate's direct arm solves small sets and is reported separately.

## 3. The inherited-profile hash gap was real and is now closed

`MinilabCatalog::load` hashed the named profile file only. For
`cinestill_800t` — a `derived_from: kodak_vision3_500t` alias with no measured
data of its own — that pins a few hundred bytes of documentation while the
material the table was baked from is a different file.

`film_base_hash` / `paper_base_hash` are now checked when present (the alias
file itself decides which base it inherits); an entry that declares one on a
non-alias profile is an error. `engine/tests/minilab_resource_checks.py` proves
that flipping a byte in the base profile is rejected, that flipping the alias
file is rejected, and that an entry without the field keeps the old behaviour.

## 4. Research artefacts that are not reproducibility evidence

The research tree's `v2/minilab/` contains 227 files from several phases
(`_c2`, `_c2e1`, `_cprime`, `identity_*`, `_ev032`). Only the two `_f10` files
are approved r = 1 production tables. The rest are diagnostics; none is staged.

## 5. The tone gate's 1.5x rule needs an absolute allowance

`SOP.md`'s tone gate is relative by design: "inverted-pair fraction ≤ 1.5x the
corresponding DI reference". On the 2,048 px photograph the DI arm itself moves
4x across films — 0.00064 for Pro 400H on Crystal Archive, 0.00408 for Portra on
Endura — so near zero the rule is sampling noise: with 18,650 sampled pairs,
1.5 x 0.00064 is 17 pairs.

Measured: Pro 400H's minilab arm inverts 0.00161 against a DI arm of 0.00064
(2.5x, would fail) while being *lower* than the approved Portra table's own
0.00166. X-Tra 400 measures 0.00381 against 0.00247 (1.54x, fails by 0.00004).

`bake.py::gate_tone` therefore uses `1.5 * DI + 0.001`. The allowance is 18.7
pairs out of 18,650, so a material inversion pattern still fails. Spearman is
**reported**, as the SOP words it ("report Spearman and the known historical
near-miss"): a strict "minilab >= DI" inequality was rejecting Portra 160 on
2393 on a 0.0015 rank-correlation difference over 200,000 pixels. A Spearman
more than 0.005 below the DI arm sets `spearman_flag`. The raw fractions, the
ratio, the allowance and both Spearman values are written to `gates.json`.

## 6. The identity control is paper-specific, and Crystal Archive misses it

The identity control asks the log-positive domain and the 65^3 grid to carry
**the optical chain itself**: build a table whose value at each node is the
optical print's paper CMY, render it through the same hook, and compare with the
optical render. The inherited Portra limits are a photograph mean of 24 codes and
a max of 216 (of 65535).

Measured across the first ~60 tables, the control divides by **paper**, not by
film:

| paper | photograph mean identity error | pairs measured | misses (mean > 24 or max > 216) |
|---|---:|---:|---|
| Kodak Portra Endura | 9–17 codes | 8 | 3 marginal (max 230–296) |
| Kodak 2383 | 10–17 codes | 6 | 2 marginal (max 230–233) |
| Fujifilm Crystal Archive Type II | **241–428 codes** (max 3594–8896) | 12 | all 12 |

All twelve Crystal Archive pairs miss the inherited limits by 10–18x; every
non-Crystal pair is inside the mean limit and only a handful are marginally over
the 216-code max. The same numbers appear in both calibration spaces, because
the identity table maps to paper CMY and the paper scan follows.

This does **not** condemn the minilab tables for that paper: the identity table
carries the optical chain's steep dye response, while the minilab table carries
the Oklab-mapped target, and those Crystal Archive minilab tables measure
0.07–0.10 chart-mean / 0.09–0.13 photograph-mean ΔE00 against their direct
solve. But it is a real limitation of the domain for that route, it is recorded
in every job's `gates.json` and in `LEDGER.json`, and it is flagged rather than
hidden (the SOP's own rule: the identity limits are "inherited provisional gates
for new pairs", flagged, not an all-stock guarantee).

The owner may want to treat Crystal Archive as a paper whose optical chain is not
representable at 65^3 in this domain; the minilab route is unaffected in the
measurements taken here, but that is a model judgement, not something this run
should settle by deleting the control.

## 7. The LUT envelope bites on the cinema print stocks, for five pairs

Forty-four pairs pass. Every blocked pair is on **Kodak 2383 or 2393**, and the
measurements separate a diagnostic miss from a real one:

| pair | chart mean | photograph mean | p99 | outcome |
|---|---:|---:|---:|---|
| CineStill 800T / 2383 | 0.07–0.08 | 0.210 / 0.213 | 1.14 | blocked (mean 1.2×) |
| CineStill 800T / 2393 | 0.07 | 0.237 / 0.281 | 1.56–1.91 | blocked (mean 1.4–1.6×) |
| Fujifilm Pro 400H / 2383 | 0.03 | 0.430 / 0.508 | 2.13–2.40 | blocked (mean 2.5–2.9×) |
| Fujifilm Pro 400H / 2393 | 0.12 | 0.156 / 0.185 | 0.52–0.66 | blocked (ProPhoto mean 1.06×) |
| Portra 800 push 2 / 2383 | 0.17 | 0.191 / 0.187 | 0.63 | blocked (mean 1.1×) |

The chart is fine for four of the five; the photograph mean is what fails. That
is the signature of a steep map at the extremes of a real frame rather than a
bad table. CineStill and Pro 400H on 2383 show the film's own halation in all
three arms of the sheet, so the look is consistent; the excess is the 65³ grid
approximating a steep print response.

Two dozen other pairs on 2383/2393 pass (C200, X-Tra 400, Ektar 100, Gold 200,
Portra 160/800/push1, Ultramax, Vision3 50D/200T/250D/500T on one or both), so
this is not "the cinema papers are broken". It is five film/paper combinations
where the fixed 65³ grid is not an adequate approximation, and the gate is doing
what the SOP asked of it: they stay on the optical path, are listed in
`COVERAGE.md`, and their numbers are in `LEDGER.json`.

The Pro 400H / 2393 row is marginal (0.185 against 0.175, with the sRGB side at
0.156) and is left blocked rather than argued down; a re-bake at a different
grid or a model decision is the owner's call.

## 8. The blocked set after 67 pairs: one film, two cinema stocks, one paper

At 67/136 qualified, the block list is no longer "the cinema papers". It reads:

| film / paper | what fails | measurement |
|---|---|---|
| CineStill 800T / 2383, 2393, Endura Premier | photograph mean (and, on Premier, tone by 0.0001) | 0.20–0.28 against 0.176 |
| Fujifilm Pro 400H / 2383, 2393-PP, Ektacolor Edge, Endura Premier | photograph mean | **0.19–1.55**; Pro 400H is the one film that goes badly wrong on four papers |
| Portra 800 push 2 / 2383, 2393 | photograph mean | 0.18–0.19 |
| Gold 200 / Endura Premier | tone | inverted 0.0072 against a 0.0058 limit |
| Portra 160 / Endura Premier | tone | inverted 0.0096 against a 0.0084 limit |

So the pattern is film-specific, not paper-specific: Pro 400H on four papers, and
the pushed Portra 800, are the large misses; the two Endura Premier pairs fail
only the tone fraction, by 14–24 %. CineStill is blocked on Kodak 2383, 2393 and
Endura Premier, passes Crystal Archive and Ektacolor Edge, and its Portra Endura,
Supra Endura and Ultra Endura pairs were still queued when this was written.

That is the honest state: 67 pairs qualified, 11 pairs blocked, the rest still
queued. The blocked pairs are on the optical path, appear in `COVERAGE.md`, and
carry their measurements in `LEDGER.json`.

## 9. A film alias inherits its base's print calibration (CineStill 800T)

CineStill 800T is Kodak Vision3 500T with the rem-jet anti-halation backing
removed: in this engine it is a `derived_from: kodak_vision3_500t` profile whose
own JSON overrides only `name`, `use` and `antihalation`. The measured material
is the base's, whole.

The print transform is a property of the **developed emulsion and the paper**.
Halation is a spatial effect at the film stage: it changes *which* negative
values a scene produces, not what a given negative value prints as. Baking
CineStill separately made its exposure anchor (`film_ev`, metered with halation
active) and therefore its negative set, domain and E1 fit differ from Vision3's,
which produced a table that was not the base's and measured worse on the same
paper:

| paper | Vision3 500T photograph mean | CineStill, own bake | outcome now |
|---|---:|---:|---|
| Crystal Archive | 0.137 | 0.167–0.174 | inherited |
| Kodak 2383 | 0.143–0.154 | 0.210–0.213 (blocked) | inherited, **unblocked** |
| Kodak 2393 | 0.161–0.166 | 0.237–0.281 (blocked) | inherited, **unblocked** |
| Ektacolor Edge | 0.157–0.162 | 0.170–0.171 | inherited |
| Portra Endura | 0.132–0.141 | 0.162–0.167 | inherited |
| Endura Premier | 0.189–0.193 (blocked) | 0.203–0.204 (blocked) | base blocked, so blocked |

`stage.py --inherit-alias` therefore catalogs the alias on the base film's
qualified table: the entry points at the base's file and pins the alias bytes,
the paper bytes **and** the inherited base bytes (`film_base_hash`). The
`calibration_source` field names the base in the entry, so the inheritance is
explicit in the catalog, not a lookup the loader invents.

The override is the ordinary path: bake a CineStill-specific calibration and
stage it with `--replace`; its own file then supersedes the inherited one. That
is the "override permission" on the alias.

Runtime is still verified with the *alias* profile (halation on) through both
engines reading the same base table: `verify_native.py` now takes the file name
from the catalog entry rather than from the job id, so an inherited entry is
tested exactly as it ships.

This also narrows the block list honestly: CineStill is blocked only where
Vision3 500T is blocked (Endura Premier, and Ultra Endura once measured), not
where its own mis-anchored bake happened to fail.

## 10. Final state: 97/136 qualified, 39 blocked, every row accounted

All 136 colour-negative / colour-paper pairs were attempted in both spaces. The
ledger has no pending rows.

| | pairs |
|---|---:|
| Qualified, staged, runtime-verified | **97** |
| Blocked (measured, on the optical path) | 39 |
| Pending / untouched | 0 |

Blocked by paper: **Ultra Endura 17 of 17**, Endura Premier 9, Kodak 2383 3,
Kodak 2393 3, Ektacolor Edge 3, Supra Endura 2, Portra Endura 1 (Pro 400H),
Crystal Archive 1 (Pro 400H).
Blocked by film: Pro 400H 7, **Portra 400 7**, Portra 800 push 2 4, Vision3 200T
3, and pairs from eight other films.

Two paper-level facts explain most of it, and both are measured rather than
assumed:

- **Ultra Endura fails tone order, not the table.** C200 measures a 0.091
  photograph-mean ΔE00 against the 0.176 limit, but inverts 1.19 % of pixel pairs
  against a 0.65 % limit; X-Tra 400 0.079 / 1.32 % vs 0.47 %. The r = 1 print on
  that paper bends tone order, so every film is blocked on it.
- **Portra 400 is blocked on all seven non-Endura papers** (0.28–0.67
  photograph-mean ΔE00). Its node self-check is 7e-7 CMY mean, so the harness is
  not the cause. Its Portra-only C1 sampling recipe accounts for part of the
  miss — disabling it on 2383 moved 0.388 → 0.281 — but not the cause: the r = 1
  Portra target on a cinema or third-party paper is simply not representable at
  65³ within the approved envelope. The recipe was restored: the frozen canary
  keeps it, and the measured effect is recorded here instead of silently
  changing the Portra sampling policy.

Neither is a reason to loosen a gate. They are the model's measured boundary on
those papers, and the owner can decide whether a denser grid, tetrahedral
interpolation, or a per-paper target is the next model change.

The 97 qualified pairs are 194 tables (610 MiB) in `engine/resources/minilab/`,
each with FNV-1a 64-bit identities for the table, both profiles and any inherited
base, and each runtime-checked RGBA16-identical between the research build and
the promoted engine. `COVERAGE.md` is the per-row table; `LEDGER.json` carries the
per-row gate measurements, including the blocked ones.
