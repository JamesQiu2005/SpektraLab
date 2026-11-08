# SOP: complete minilab coverage for every film/paper combination

Owner request: one DeepSeek worker should be able to extend coverage to all pairs.
This SOP prepares that job; it does not claim that the outstanding tables have
been built. Source baseline is the promoted v2 engine, commit `unpublished-revision` on
`mac/engine-performance`. Work in another worktree; never modify or merge into
the owner's active checkout. See `DEEPSEEK-HANDOFF.md` for the copyable assignment.

## 1. Definition of complete coverage

Generate the full Cartesian inventory from the **merged engine resources**, not
only the app catalog or each film's `target_print`. Product profiles override
base resources; aliases inherit their base profile. The supplied snapshot has:

| Route | Pairs | Required disposition |
|---|---:|---|
| Colour negative × colour paper | 136 | Independently qualify all pairs in sRGB and ProPhoto: 272 production tables |
| B&W negative × silver paper | 4 | Verify the existing silver path and explicitly record it; no colour-hue LUT |
| Reversal film × paper choices | 36 | Verify paper bypass; these are not negative minilab jobs |
| Colour/silver model mismatch | 49 | Record incompatible; preserve the pairing rule |
| **Total: 25 films × 9 papers** | **225** | Every row accounted for |

Only Portra 400 / Portra Endura is currently catalogued in both calibration
spaces. That leaves **135 colour pairs / 270 production tables** to qualify.
Include CineStill 800T even though it is absent from the supplied Catalyst stock
catalog. Do not limit the job to the four films explored in the research scripts.

“All pairs covered” means every colour-negative/colour-paper job passes, all
special-path rows have evidence, and no blocked row is hidden. A colour minilab
for B&W or reversal is a different model-development task: do not remove their
runtime bypasses merely to turn the matrix green. Report these routes separately.
If the inventory changes during work, regenerate it and review the new rows.

```sh
python3 engine/tools/minilab_inventory.py \
  --catalog app/SpektraLab/Resources/StockCatalog.json \
  --output engine/minilab-coverage/inventory.json
```

This command exists now and only inventories. `catalogued_recheck` is not a new
quality certificate. Copy the inventory into a run ledger before updating job
states; keep the original inventory for reconciliation.

## 2. Freeze the model before automation

Every production table uses this recipe explicitly, never function defaults:

| Property | Required value |
|---|---|
| Input domain | Three recovered log10-positive channels, before DI matrix/clamp/Cineon |
| Output | Paper CMY density; existing paper scan/output follows |
| Grid / interpolation / storage | 65³ / current trilinear / float32 |
| Look retention | `rb=1.0` (`r_blend=1.0` in sidecar) |
| Tone and gamut mapping | `ymode='opt'`, `mode='hybrid'` |
| Production print EV | `ev=0.0` |
| Calibration spaces | Separate sRGB and ProPhoto RGB builds |
| DI reading used to construct targets | Per-film, per-space E1-C3 white-pinned refit |
| Film/DIR settings | Frozen shipped defaults; current research fits DIR amount 1.0 |

At r=1, the target keeps the optical chain's Oklab lightness/chroma and uses the
DI reading's hue, with the existing near-neutral fallback. Keep hybrid mapping,
range-limit sampling, seeds, solver tolerances and fallback policy unchanged.
Do not change measured profiles, reduce precision/grid size, choose r=0, tune
DIR to 0.5, add runtime fitting, or alter the public wire to make jobs pass.
The chart's `ev=0.032` tables are diagnostic artifacts and must never replace
production EV-0 tables. Their names must identify the chart-only exposure.

Other output spaces currently use the ProPhoto calibration before their own
output transform; still test all six runtime output spaces. Do not install an
sRGB calibration as ProPhoto just because its file shape is correct.
The E1-C3 refit here belongs to offline table construction. The promoted engine
has not applied it as a new DI-export model; keep DI-export behavior unchanged.

## 3. Environment and inputs

A DeepSeek agent can orchestrate this locally, but needs filesystem/shell access,
a Mac with working Metal/Xcode tools, and a Python scientific environment. A
chat-only model cannot bake and validate the native engine. No images or source
need to be uploaded to a model service as part of this SOP.

Required source locations (set these for the current checkout; research data is external):

- Product worktree: the current checkout.
- Read-only research: `research/Metamerism/` in the external research tree.
- Historical handoff: `research/HANDOFF-v2-engine-2026-10-24.md` in the main repo.
- Research Python: `research/Metamerism/.venv/bin/python`; numpy, scipy,
  colour-science, Pillow, rawpy, tifffile and any imports actually used by the
  copied harness. Capture Python/package versions; do not install into the app.
- Reflectance datasets: `research/Metamerism/data/` (Munsell/Japan, etc.).
- Large arrays/images moved to
  `<research volume>/SpektraLab_research/2026-10-24_metamerism_v2/`.
  This includes `inputs/apple_2048.npy`, `inputs/apple_full.npy`, study outputs,
  and image/ROI artifacts noted by `MOVED.md` files.
- Capture One source/reference files:
  `research/color_accuracy/C1_prostandard_ref/` in the main repo.

Copy the research code into an isolated working directory. Resolve paths there
using explicit configuration or local symlinks to read-only datasets. Do not
write through a symlink into the original research output/cache directories.
Keep large outputs outside Git and retain their paths plus SHA-256 in the ledger.
Missing data is `blocked_input`, never an excuse to invent a substitute and
reuse the old thresholds. The product must continue building without Python,
the research tree, external disks, or `/private/tmp` engine copies.

Before fitting, record engine commit/binary/resource hashes, every transitive
profile dependency, algorithm-source hashes, dataset/decode hashes, all fit and
render settings, matrix values, seeds and package versions. Use a stable digest
of this manifest for cache directories; Python's salted `hash()` is not suitable.
`research-sources.json` pins the 24 research/handoff sources inspected for this
SOP, including the historical patch sequence. Verify these hashes before copying;
reconcile drift explicitly. It is a source snapshot, not a substitute for each
job's complete dataset and dependency manifest.

## 4. Mandatory preparation: generalize the research harness

There is **no finished all-pair baker** in the repository today. Implement and
qualify a parameterized offline wrapper before starting the sweep. Reuse the
existing scientific functions; avoid reimplementing their math from prose.

| Existing source | Reuse | Trap that must be removed in the copied harness |
|---|---|---|
| `v2/c3_build_f.py` | Exact approved r=1 call | Portra/default-paper only; reads Portra's `e1_fits.json`; no film/paper CLI |
| `v2/c3_lib.py` | `targets3`, `map_hybrid`, `RangeLimit`, `build` | Defaults are r=0/T/knee; sampling includes Portra-only C1 negatives |
| `v2/e1x.py` | `Data(film,paper,space,...)`, `fit3`, `held_out` | Input/cache helpers still have historical paths and prerequisites |
| `v2/e1_fit.py` | White-pinned fitting objective | `Data`/`main` use fixed Portra globals |
| `v2/e1_films.py` | Example held-out fit report | Four films, default papers and sRGB only |
| `v2/c2_lib.py` | Log-positive inversion/range/identity | Portra-only C1 inclusion; bound derivation must use this film's negatives |
| `v2/minilab_io.py`, `negs.py`, `fitlib.py` | Data generation/cache | Import-time file reads; film-only cache keys; missing per-film exposure anchors |
| `study/filmlib.py` | Material/spectral replica | Hardcoded `/private/tmp/spektralab-metamerism-study/engine/resources`; handle aliases/overlays correctly |
| `v2/eng2.py`, `eng2_worker.py` | Fresh-process native calls | Hardcoded engine root and Python; resolve explicitly before any module import |
| `v2/build_v2.sh` | Ordered reference patch recipe | Pins main HEAD and fixed temp paths; cannot run unchanged on the promoted engine |
| `v2/minilab_validate.py`, `c3_eval.py`, `c3_tone.py`, `c3_phaseD.py` | Quality measurements | Generalize film/paper/space/table paths and report IDs; no Portra thresholds silently called universal |

Build an independent research reference from the exact old source revision and
ordered patches recorded in `engine/performance/2026-10-24/provenance.json`.
Use `git archive` of that revision into fresh scratch directories, rather than
copying a dirty/current tree. Patch only disposable copies. Keep an untouched
optical reference alongside it. The current production engine does not implement
the research dump/passthrough environment hooks; setting those variables there
would not generate the required data. Verify actual module paths, dylib/resource
paths, emitted taps and positive controls before accepting an oracle result.

The wrapper must accept explicit film, paper, calibration space, output/cache
root, engine/resource paths and recipe version; reject non-colour-negative
jobs. It must run one job per child process, write a complete sidecar and nodes
artifact, atomically mark successful stages, and resume only on matching input
hashes. Failure of one pair must not delete or overwrite successful artifacts.

Preserve the original Portra sampling recipe as a frozen canary. For new films,
render their own negatives for the common source photographs and datasets; never
reuse Portra negatives or matrices. Document any difference in sampling policy.
The original range limits depend on photographs as well as profiles—“profiles
only” is not a sufficient cache key for the final hybrid r=1 recipe.

## 5. Pilot before the all-pair queue

1. Reproduce Portra/Endura in both spaces using the frozen original inputs and
   recipe. The current source entry point, **in the isolated research copy**, is:

   ```sh
   .venv/bin/python v2/c3_build_f.py 1 srgb ev0 65
   .venv/bin/python v2/c3_build_f.py 1 pp ev0 65
   ```

   This is only a Portra canary, not an all-stock command. Configure dependencies
   first. It writes the copy's `v2/minilab/`; never execute it over approved inputs.
   Compare rebuilt payloads/hashes and image outputs with the two committed
   tables. If bytes differ, investigate numeric/environment/input drift; keep
   approved tables untouched and do not claim reproducibility from a sidecar.
2. Qualify the generalized wrapper against that canary. It must reproduce the
   same configuration and target function. A changed dataset/range is a new
   calibration, not an execution optimization.
3. Run one genuinely different film and one non-default paper pairing through
   the complete pipeline. Include both spaces. This catches hidden default-paper
   and fixed-matrix assumptions before multiplying them over 135 pairs.
4. Measure seconds, physical peak memory, transient disk and result sizes for
   the pilots, then estimate the remaining queue. Stop only the failing jobs;
   resolve a shared-harness failure before continuing the whole queue.

## 6. Per-pair procedure

Process explicit `(film,paper)` identities, with sRGB then ProPhoto jobs. Do not
let `paper=None` select a default. The scientific call pattern **after the path,
input/cache and alias fixes above** is:

```python
import e1x
import c3_lib

fit = e1x.Data(film, paper, space, dir_amount=1.0)
held_out = fit.held_out()       # Munsell -> Japan and Japan -> Munsell
matrix = fit.fit3()            # final white-pinned fit on all 1,628 reflectances
sidecar = c3_lib.build(
    film=film, paper=paper, N=65, ev=0.0, space=space, M3=matrix,
    ymode='opt', mode='hybrid', suffix='_f10',
    tag='_pp' if space == 'ProPhoto RGB' else '', rb=1.0)
```

This is an interface recipe, not a claim the unmodified helper chain already
supports every stock. Persist the matrix and held-out results independently of
the build's sidecar. A matrix may be reused across papers only after proving
that all its inputs are paper-independent; otherwise fit per pair. Never reuse
matrices across films or spaces by name similarity. CineStill's alias is a
separate identity with its own effective parameters, not permission to relabel
Vision3 results.

For each calibration:

1. Resolve profiles/alias bases and effective defaults from the staged resource
   overlay. Prove the host replica and the native negative/log-positive taps
   agree on chart and grey-ramp data. Generate missing per-film anchor/exposure
   inputs through the existing spectral procedure, not guessed constants.
2. Fit E1-C3, record conditioning, finite coefficients, white constraint residual,
   train/test statistics and matrix orientation. Match the reference objective
   and its numeric tolerance; never silently use a pseudoinverse or another model
   to hide a singular fit. Matrix serialization for the historical native override
   uses the existing transpose convention; the Python builder takes the matrix
   with output-channel rows directly.
3. Generate chart, ramp, reflectance and photographic negatives under this
   film's fixed settings. Key them by the complete generation manifest. Determine
   log-positive bounds with the existing occupied-span padding and physical clamp.
4. Construct the paper boundary, r=1 target, hybrid mapping and range limits
   from the explicit pair. Solve paper CMY; retain the nodes' convergence,
   physical, mapped, fallback, lift, residual and occupancy masks.
5. Write `.lut3d`, `.json`, `_nodes.npz`, fit/metric reports, image comparisons,
   provenance and stdout/stderr into this job's own directory. On success move
   from `baking` to `baked`, not directly to `qualified`.
6. Run every applicable gate below. Record a failed gate without loosening it;
   keep the existing optical path for that pair until it qualifies.

## 7. Qualification gates and what each proves

| Gate | Requirement / interpretation |
|---|---|
| Artifact contract | 3,295,528 bytes exactly: u32 side=65, three float32 lows, three highs, then contiguous `(65,65,65,3)` float32 CMY; finite payload, finite ordered bounds; correct IDs, space, EV=0, r=1, recipe hashes |
| Paper solve | `n_fallback_final_unsolved == 0`; maximum final solve residual ≤ existing `TOL=0.002`; report fallback nodes and whether validation pixels touch them |
| Domain validity | Report all inversion failures/physical mask and occupied-cell coverage. The approved cube has unreachable corners: do not demand every grid node be physical or conceal failures by deleting hard samples |
| Identity control | Build an optical-identity LUT in the same log-positive domain. Frozen Portra control must retain mean ≤24 and max ≤216 codes on its original NEF; treat these as inherited provisional gates for new pairs and flag failures, not as an already proven all-stock guarantee |
| LUT versus direct solve | Existing reference limits: chart max ΔE00 ≤0.2; NEF mean ΔE00 ≤0.05, evaluated in the same colour space/adaptation/encoding. Add held-out photographic data; do not compare encoded RGB as linear XYZ |
| Runtime execution | Same candidate table and settings through research reference and promoted fused engine: RGBA16 bit-exact. Grain/glare off for deterministic colour tests; exact seeded grain tested separately. Do not compare a new minilab look to old optical pixels and demand equality |
| Tone/order | Test grey ramps and published coat/fold ROIs; inverted-pair fraction ≤1.5× the corresponding DI reference. Report Spearman and the known historical near-miss rather than silently dropping it. No new contouring, reversed folds or crushed colour islands |
| Colour/look | Record hue, chroma ratio, lightness, ΔE and r=1 look fingerprint by ROI, with neutral hue handling. Compare target/direct/table separately. Portra's historical numbers are a canary, not universal “accuracy” limits. Preserve film/paper character; no hue-only score used to excuse lost detail |
| Visual inspection | Reference / optical / direct r=1 / LUT r=1 crops and full frames in identical display transforms: blue-purple fabrics, skin, neutrals, saturated flowers, foliage/sky holes, highlights and deep folds. Inspect every pair's sheet; use independent photographs, not only the training chart |
| Inputs and runtime controls | Linear versus encoded representations; six output spaces; empty/identity/changed `scene_curve`; exposure ±2 EV; DIR off/default/high; halation zero/default; exact grain/sublayers toggles; edges/date and reprint/export consistency. These do not authorize changing runtime defaults |
| Cache/ownership | Forced-full versus checkpoint exact after relevant edits; validate real cache hits, failure fallback, close/reopen, stock switching and no retained session buffers. Test-force admission is allowed for correctness only, never timing |
| Resource failure | Missing/corrupt table or mismatched dependency must fail explicitly for a catalogued pair. Unlisted pairs remain optical; do not substitute another stock's table |

The analytical table need not be bit-identical to a float64 direct nonlinear
solve; that is what the interpolation-error limits measure. Bit-exactness is
required when both native paths consume the **same table**. Reproducing the
existing Portra bytes is a separate frozen-canary requirement.

Inspect low-error pictures too. A plausible image, zero NaNs, or matching grain
RMS alone is not a quality pass. Do not claim “more accurate” from this procedure.
If visual tools or references are unavailable, mark `needs_visual_review` with
numeric results retained. A failed threshold requires investigation or an
explicitly documented model decision, not an automatic exception.

## 8. Queue, memory and storage policy

Use one worker and one bake/render process at a time. Limit BLAS/OpenMP threads
explicitly and record the setting; do not launch all 272 solves in parallel.
Release each child's large arrays at exit. Resume by `(film,paper,space,manifest
hash,recipe version)`; stale negatives/matrices/ranges invalidate downstream work.

The raw production payload for all colour pairs is **896,383,616 bytes
(~855 MiB)** for two spaces, before packaging. Validation arrays and imagery cost
additional disk. The observed Portra r=1 builds were ~271–300 seconds per table
on the research host: 272 jobs could require roughly 20–23 hours of bake time
alone, plus fits and validation. Use pilots for the real estimate, not this as
a deadline. No need to keep all tables resident or upload them at app startup.
Retain the engine's one-table-per-pipeline behavior and bounded checkpoint slot.

Suggested ledger states:
`pending -> preflight_ok -> fitted -> baked -> numeric_pass -> visual_pass ->
qualified -> staged -> integrated_verified`.
Terminal failures retain the stage and reason (`blocked_input`, `fit_failed`,
`gate_failed`, `needs_visual_review`). Each state transition records input/output
hashes, command, exit code, elapsed time, peak footprint, evidence paths and last
error. Write the ledger atomically after each stage. Do not overwrite the run
ledger by regenerating the inventory. Continue independent pairs after a local
failure; a global recipe or oracle mismatch blocks the sweep until fixed.

## 9. Staging and integration

First render from an isolated **staged resources directory** containing the full
base/product overlay plus candidate minilab artifacts and index. Use explicit
`resources=` / dylib paths. A non-Portra job must prove it selected its own table,
for example by removing/corrupting that candidate in the staged directory and
observing the required error. The current generic performance/check scripts have
Portra-specific cases: parameterize them before reporting all-pair validation.

Only after a pair passes both spaces, copy its production LUTs into the separate
coverage worktree's `engine/resources/minilab/` and add its explicit
`film|paper` entries. Keep known-good entries untouched until a controlled
replacement passes. Each entry follows the existing `index.json` schema:
`file`, `side`, payload `hash`, raw `film_hash`, raw `paper_hash`,
`look_retention: 1`, and `calibration_space`.

Runtime hashes are **FNV-1a 64-bit**, offset 14695981039346656037, prime
1099511628211, modulo 2^64, rendered as 16 lowercase hex digits. SHA-256 in the
ledger is additional provenance, not a replacement for runtime FNV fields.
Validate file length and the exact raw profile bytes from the bundled overlay.

**Alias dependency gap:** the current loader checks the named profile file, not
its `derived_from` base. Before qualifying CineStill entries, extend loader and
catalog dependency validation narrowly to include the inherited base bytes, and
prove modifying the base invalidates the table. A hash of the tiny alias JSON
alone cannot pin its material data. Maintain backward compatibility for existing
non-alias entries. Do not clone a base profile into a new measured material.

Update resource provenance/coverage docs, bundle through the existing builders,
and verify the built app's resource identities. Run regression gates including
existing Portra images, DI, B&W, positive bypass, bad resources, table replacement,
new `scene_curve`, checkpoints and engine teardown. Measure cold open/first render,
reprint and peak footprint against the same candidate model with optimizations
controlled, under interleaved runs. Do not attribute colour changes to performance.
Runtime loading must remain lazy and bounded despite the ~855 MiB bundle.

Commit successful coherent batches in the coverage branch; leave failed pairs
optical and visibly pending. No merge, push, installation or release is implied
by this handoff. The original engine-performance branch and the owner's active
checkout must remain unchanged during the worker's run.

## 10. Completion report

Deliver the regenerated inventory and reconciled run ledger, exact recipe and
input manifest, per-film/space fits, per-pair/space artifacts and gate reports,
contact sheets with inspection notes, bundle-size/startup/RAM measurements,
regression results, commits and remaining failures.

Report these counts separately: colour pairs qualified **out of 136**, individual
production calibrations **out of 272**, special-path rows verified, incompatible
rows accounted for, and pending/blocked rows. “272 files exist” is never the
completion criterion. A completed sweep may honestly have blocked pairs; it is
not full qualified coverage until the eligible denominator is satisfied.
