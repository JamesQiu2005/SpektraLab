# AGENTS.md — working notes for AI sessions on Filmify

The macOS desktop product built on the **spektrafilm** engine. Extracted from
the `spektrafilm` fork into its own repository on 2026-09-11; `README.md` says
what is here and what is deliberately not. This file records conventions and,
more importantly, the traps that cost real debugging time. Read the traps
section before touching the pipeline.

---

## What this repo is, in one screen

**One binary.** The macOS app under `modern_UI/` has a C++ render engine
(`engine/`) compiled into it and reached through a hand-written `extern "C"`
surface; it renders into an `MTLTexture` the canvas draws. There is no Python
in this repository — no `src/`, no `.venv`, no subprocess, at build time or at
run time. `ARCHITECTURE.md` §0 is the map and §8 is the engine. RFC-014 §8 is
the after-the-fact record: what parity measures, why each bar is where it is,
and the bugs already found.

**The Python reference is not here, and two things need it.** The upstream
fork's `src/` package is the oracle `engine/tests/parity_*.py` compare against,
and the only thing that can re-bake `engine/resources/`. Both take it as an
explicit `PYTHONPATH` — see README, "Parity harnesses" and "Rebaking the engine
resources". Nothing else in this repository does. `engine/resources/` is
tracked precisely so that building the app never needs it.

**There is no CPU fallback and no Python at run time.** If something is slow,
it is not "falling back" — there is nothing to fall back to. A 45 MP full
render is 0.87 s; a number near the old numba figures means something else is
wrong, and three such causes are already recorded (trap 18).

**The frontend/backend split is historical.** `CONTRACT-frontend-backend.md` §4
divided this work between two concurrent sessions — frontend on `modern_UI/**`,
backend on `src/**`, `tests/**`, `scripts/**`, `rfc/**`. The backend half of
that split belonged to the Python engine, which stayed behind in the fork. What
came across is one product with one owner, so §4 no longer routes anything.
The contract is still worth reading for **§1, the wire**, which has not changed.
`AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` and `CONTRACT-*` still belong to
nobody in particular — **say so before editing one.**

**`native/` is gone.** It was the stdio proxy host, from before the engine
existed and superseded by it (RFC-014 §6 step 6). It was deliberately not
carried across, and nothing references it.

**The whole method surface is ported** as of 2026-09-10. `export`,
`export_di` and `preview_stock_lut` were the last three refused by name; they
are now `spk_reprint` at the full tier, `spk_export_di` +
`spk_print_lut_table`, and `spk_preview_stock_lut`. **The engine gained no
file writer**: it returns pixels and the baked table, and `Exporter.swift`
writes the TIFF, the `.cube` and the print preview through ImageIO. See
`ARCHITECTURE.md` §8.8 for where the boundary falls and why.

**The engine's data comes from the app bundle**, not from a checkout above it.
See trap 14.

---

## Environment

**No virtualenv, and no Python, for anything this repository builds.** Xcode
26.6, macOS 15+, Apple silicon:

```bash
engine/build.sh bundle       # C++ engine + MSL kernels + sync baked resources
xcodebuild -project modern_UI/Spektrafilm/Spektrafilm.xcodeproj \
           -scheme Spektrafilm -derivedDataPath build/DerivedData build
```

A `python3` is used only by the `Tools/*.py` generators (`gen-project.py`,
`gen-catalog.py`), which are standard-library-only.

**The Python reference lives in the fork**, at
`~/Documents/Summer 2026/spektrafilm`. The parity harnesses and
`engine/tools/bake_resources.py` reach it through `PYTHONPATH=<fork>/src` and
that fork's `.venv` — see README. That fork's Environment notes (its venv, its
two checkouts, `-W ignore`) apply to work done *there*, not here.

**Trap 14 no longer bites here.** It was about a venv's editable install
pinning `spektrafilm` to whichever checkout created it, so that two checkouts
silently ran each other's code. There is no venv in this repository to be
confused; if you are chasing that class of bug you are in the reference
checkout, not this one.

---

## Fixed experimental setup

Do not change these without a reason; every recorded number assumes them.

| | |
|---|---|
| film profile | `kodak_portra_400` |
| print profile | `kodak_portra_endura` |
| smoke image | `tests/Test_image/_smoke_1mp.tif` (1 MP, for fast iteration) |
| 45 MP frame | `tests/Test_image/Nikon Z7ii/_DSC2439.NEF` (5504×8256) |
| device precision | float32 on macOS (see Traps) |
| grain sampler | `exact` (RFC-002); `--sampler scipy` for the old stream |
| working precision | `float32` (the default since RFC-006; `float64` is the validation baseline) |

> **`tests/baseline/` no longer exists.** The user deleted it and
> `HANDOFF-GPU-WIRING.md` §3.3 says **do not restore it**. Every command this
> section used to give — `make_baseline.py`, `run_reference.py`,
> `tests/baseline/compare.py`, and the 16 MP linear ProPhoto TIFF that most
> recorded numbers in this file and in `ARCHITECTURE.md` were measured against
> — is gone with it. Those numbers stay as history; you cannot reproduce them
> as written, and a number you cannot reproduce is not a baseline to compare
> against. The five `tests/test_regression_baselines.py` cases that need its
> `.npz` fixtures **skip**, with the regeneration command in the skip message.
>
> The smoke image survived at a new path, and the suite looks in both places
> (`tests/test_rfc012_engine_seam.py:24`). Use `tests/Test_image/_smoke_1mp.tif`
> for anything that needs a small frame, and the Nikon NEF above for anything
> that needs a real one.

Parity against the numba reference — this is the harness that replaced the
above, and the one RFC-011 held every ported node to at float32 storage
epsilon:

```bash
.venv/bin/python -W ignore scripts/gpu_native/parity.py \
    tests/Test_image/_smoke_1mp.tif                 # every implemented node
.venv/bin/python -W ignore scripts/gpu_native/parity.py \
    tests/Test_image/_smoke_1mp.tif --node filming.expose.upsample --end-to-end
```

Use the **1 MP** frame, not the 45 MP one: parity is a correctness question, a
run takes seconds, and a check you can afford on every change is worth more
than one you run at the end. The rest of `scripts/gpu_native/` —
`profile_render.py`, `tier_timings.py`, `grain_moments.py`,
`concurrency_check.py` — is the measurement kit that replaced the deleted
`run_reference.py`.

Whole-app timings, including the render, come from the frontend's own
instrument — see "The frontend and the service" above. It is usually the right
tool even for a backend change, because it measures what the user experiences
rather than what a script measures.

---

## Building and testing

### The engine

```bash
engine/build.sh all          # metallib + static lib + dylib + test drivers + bundle
engine/build.sh metallib     # just the kernels (after editing a .metal)
engine/build.sh bundle       # sync resources into the app's Resources/engine
engine/build.sh dylib        # what the ctypes parity harnesses load
```

`engine/resources/` is **tracked here** (15 MB of baked output), so a fresh
clone can build without baking anything. Re-baking needs the Python reference
tree and is rare — see README, "Rebaking the engine resources".

**Run the parity harnesses before believing any engine change.** They take
under a minute together and each one catches a different class of mistake.

⚠️ **The `parity_*.py` commands below run from a checkout that has the Python
reference** — the fork, not this repository — with `REF` set to that checkout's
root. They drive this repository's dylib through ctypes, so they must also be
pointed at *this* `engine/`; the simplest form is to run them from here with
`PYTHONPATH` naming the fork's `src`. The two that are pure C++ run here.

```bash
export REF=~/Documents/Summer\ 2026/spektrafilm          # the Python reference
export PYTHONPATH="$REF/src:engine/tests"
"$REF/.venv/bin/python" engine/tests/parity_setup.py     # constants
"$REF/.venv/bin/python" engine/tests/parity_schema.py    # the wire
"$REF/.venv/bin/python" engine/tests/parity_render.py    # the picture
"$REF/.venv/bin/python" engine/tests/parity_session.py   # every field, live
"$REF/.venv/bin/python" engine/tests/parity_grain.py     # distributions
"$REF/.venv/bin/python" engine/tests/parity_lut.py       # the print tables, bit-exact
# and these two need nothing but this repository:
engine/build/gpu_smoke engine/resources/spektrafilm.metallib   # the boundary
engine/tests/check_math_guard.sh                               # that the guard fires
```

`parity_render.py --size 180` uses a small synthetic frame and runs in
seconds; with no `--size` it uses the 1 MP frame RFC-014 §3 prescribes.
`ARCHITECTURE.md` §8.6 says what each holds and why the bars are where they
are. There are **six** now; `parity_lut.py` is the newest and holds the print
tables bit-exact, plus the LUT apply and the DI normalisation at
`parity_render`'s bars.

To run a harness against the resources **inside a built `.app`** rather than
the checkout's — the only way to check that what shipped is what was tested,
since `engine/build.sh bundle` is an rsync that leaves a *stale* bundle rather
than an empty one when it does not run:

```bash
SPEKTRAFILM_ENGINE_RESOURCES=/path/to/Filmify.app/Contents/Resources/Resources/engine \
    PYTHONPATH="$REF/src" "$REF/.venv/bin/python" engine/tests/parity_lut.py
```

### The app

```bash
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py        # REGENERATE after adding/removing any source file
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
    -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
    -configuration Debug -derivedDataPath build/DerivedData test   # 117 tests, ~7 s
```

Two more scripts the app target depends on, both idempotent:

```bash
Tools/bundle-licenses.sh          # the GPL / CC BY-SA / Apache texts into Resources/Licenses
Tools/check-bundle-resources.sh   # the app's own pre-build phase, runnable alone
Tools/package.sh [--dry-run]      # archive -> export -> DMG -> notarise -> spctl
```

`check-bundle-resources.sh` fails the build when either the engine's baked
resources or the licence texts are missing. The licences are **not optional
decoration**: the bundle carries CC BY-SA profiles and GPL binaries, and
`LicensingTests` asserts the texts are present *and readable through the same
accessor the About panel uses*.

`project.pbxproj` is **generated from the filesystem** by `Tools/gen-project.py`
(ids are sha1s of the file's path *relative to the project*, so two checkouts
of the same tree generate the same bytes). The "relative" is load-bearing and
was not always true: the ids used to hash the absolute path, so a git worktree
and the main checkout produced files identical in every byte except all 1,400
ids, and any merge between them conflicted over a change neither side had
made. It also lists the engine's C++
translation units, so **a new `engine/src/**/*.cpp` needs the generator too** —
without it the file simply is not compiled, and the failure is a link error
about a missing symbol rather than anything pointing at the file. A new
`.swift` that is not in the project fails with `cannot find X in scope`, which
reads like a missing import.

The test target is standalone (no TEST_HOST) and compiles the app's sources
plus the engine's. `EngineClientTests` covers the C ABI boundary from Swift;
`ParamsTests.testWireNamesMatchTheServiceSchema` still pins the field names
against `service/schema.py`, which is what catches a rename before it becomes
a runtime rejection.

**A stale test binary reports a stale result.** `xcodebuild test` piped
straight into `grep` can report a failure from the previous build; if a
failure looks impossible, run it once more before investigating it.

Capturing the interface:

```bash
Tools/snapshot.sh [image.NEF]        # offscreen, three window sizes
Tools/capture-live.sh [image.NEF]    # the REAL window, via the window server
SPEKTRAFILM_CANVAS_LOG=1 …           # one line per draw, plus the open-path timings
```

`snapshot.sh` renders through `cacheDisplay`, which **cannot see a
`CAMetalLayer`** and substitutes an offscreen render of the canvas. That blind
spot hid a drawable pixel format `CAMetalLayer` rejects (the app crashed on
launch) and a redraw that never reached the view (blank canvas, correct
numbers). `capture-live.sh` is the only capture that proves the canvas draws,
and it needs a live GUI session — if `CGWindowListCopyWindowInfo` reports
almost no on-screen windows, the failure is environmental, not a regression.

**An in-process test is a third harness with a third blind spot: it cannot see
a stall.** Measured 2026-09-12 — a collapse animation that takes 113 ms of dead
time in the real window finishes in 174–181 ms inside the test process, because
there is no display link and therefore nothing to starve. Pass counts, layout
passes, travel and CPU time are what an in-process harness measures honestly;
"does it stutter for the user" is not, and needs the real window. The reverse
also holds and is easier to forget: a starved main thread shows up in the *log*
as a gap in the draw lines, so `SPEKTRAFILM_CANVAS_LOG=1` through a real
gesture is the cheap way to tell "the layout pass is expensive" from "the
layout pass asked the canvas to do more" — a burst with no draws in it is the
first, a burst with draws still ticking is the second.

The app's own timing instrument, which you should not delete:

```
$ SPEKTRAFILM_CANVAS_LOG=1 …/Spektrafilm --snapshot 1600x900 /tmp/o.png \
      --open "tests/Test_image/A7m3/DSC03710.ARW" --wait 90 2>&1 >/dev/null \
  | grep -E "open path|detail"
session: open path (ms): decode 76 · preview-texture 195 · linear-tiff 51
         · service.open 1613 · solve 30 · reprint 44 · TOTAL 2011
         · core=native-metal
session: detail preview 3400x2266 landed in 191 ms
```

**`core=native-metal` is the first thing to check**, and it is now the *only*
value it can take — if it says anything else the app is not running this
engine. `service.open` keeps its name for continuity; there is no service, and
what it measures is Core Image rendering the linear TIFF to a float bitmap plus
the upload. On a 24 MP RAW that read is most of it.

The `detail … landed` line is the one that says a higher-resolution render
actually reached the canvas. `scheduleDetail` drops a result whose generation
changed, so when a full render was slow the line never appeared and the app
looked like it never showed full resolution — which is what a 13.6 s render
did before trap 18 was fixed.

Snapshot flags for canvas features a test cannot see: `--zoom`, `--geometry`,
`--mask`, `--compare`.

---

## Traps

### 1. The pipeline is nondeterministic by default

`model/glare.py` draws an **unseeded** lognormal field on every call, and
`print_render.glare` / `film_render.glare` are both active by default. Two
renders with identical config and the same backend differ by up to **0.042** —
larger than most differences you will be trying to measure.

**Glare is the only unseeded stage.** Grain looks stochastic but is not: with
`fixed_seed=None` the model takes `seed = [0, 1, 2]` (note the inverted-looking
branch) and `grain_sampler='exact'` derives every chunk's stream from a fixed
`SeedSequence`, so grain reproduces run to run and across worker counts.

**Any per-pixel comparison must still disable both.** Set
`print_render.glare.active = False` and `film_render.grain.active = False` — or
`debug.deactivate_stochastic_effects = True`, which does both. With both off
the pipeline is bit-exact (`np.array_equal` True) run to run.
`scripts/gpu_native/parity.py` disables them by default and only enables them
under `--allow-stochastic`, where it reports timing and no dE. (The old
`run_reference.py --no-glare` flag is gone with `tests/baseline/`.)

This cost an hour of chasing a phantom port bug. Before concluding a change
broke something, run the same config twice and check it reproduces.

### 2. Measured profiles contain NaN

Portra 400 has 22 NaN in `channel_density` and 20 in `base_density`; Portra
Endura has 22 in `channel_density`. They mark wavelengths with no measurement
data, mostly at the UV and IR ends.

The reference path lets them propagate to NaN transmittance, then zeroes them
in `density_to_light`. Any replacement must reproduce that. See
`prepare_spectral_constants` in `utils/fused_spectral.py`, which neutralises
them at build time by zeroing the affected `illum_x_sens` rows.

### 3. `fastmath=True` deletes NaN checks

Numba's `fastmath` asserts no-NaN, so an `if np.isnan(x)` guard inside a
`fastmath` kernel is not reliably preserved. Handle NaN by sanitising
constants outside the loop, never with an in-loop branch.

### 4. Chunks must outnumber workers

For `parallel_pointwise`: one chunk per worker puts every chunk in flight
simultaneously, so concurrency re-multiplies exactly what chunking divided.
12 chunks / 12 workers → 6.86 GB. 64 chunks / 12 workers → 1.64 GB, same wall
time. Also: write into a preallocated output; `np.concatenate` at the end
holds a full-size copy and discards the win.

### 5. MLX is lazily evaluated

An unevaluated graph retains every intermediate — precisely the failure this
port exists to fix. Place explicit `mx.eval()` barriers at node boundaries.
Treat as a correctness requirement, not tuning.

Also: expressing a stage in stock MLX ops allocates an array per operation.
`compress_rgb` in stock MLX would be ~3.8 GB of intermediates at 16 MP. Only a
**fused** kernel gets memory to input+output. Putting something on the GPU
fixes speed; only fusion fixes memory.

### 6. float16 is not free

fp16's smallest subnormal is ≈5.96e-8, so the `1e-10` epsilon in
`np.log10(np.fmax(raw, 0.0) + 1e-10)` underflows to exactly 0 and `log10(0)`
gives `-inf`. Measured fp16 storage error on the spectral kernel is 2.7e-3
relative. fp16 is also **not faster** here (6.9 ms vs 6.8 ms) — the kernels
are compute-bound, not bandwidth-bound. Use float32 on macOS.

### 7. colour-science silently promotes to float64

`colour.RGB_to_RGB`, `RGB_to_XYZ` etc. return float64 regardless of input
dtype. The RAW loader's docstring claims float32 output; it returns float64
once a colourspace conversion runs.

Also: `colour.RGB_to_RGB(x, 'sRGB', 'sRGB', apply_cctf_encoding=True)` runs a
full colourspace conversion with an identity matrix just to apply a transfer
function. `colour.cctf_encoding` is 2.5× faster — but gives a 3.0e-4
difference, so verify which curve variant is wanted before swapping.

**This used to defeat float32 entirely** — casting at the door did nothing,
because the first colourspace conversion upcast straight back (measured 5.61
vs 5.57 GB at 16 MP). **Fixed in RFC-006**: the kernels are dtype-preserving
now and `working_precision` is enforced on node *inputs* as well as outputs.
The two colour-science call sites in `scanning.py` are the pattern to copy —
`_scan_xyz_to_rgb` became a matmul against the identity-trick matrix (exact
to 1.3e-15), and `_scan_cctf` keeps `colour.RGB_to_RGB` verbatim but runs it
through `parallel_pointwise(..., out_dtype=...)` so the float64 it insists on
returning exists one chunk at a time. Do not swap `RGB_to_RGB` for the bare
`cctf_encoding`: for a same-space call the former also applies a
near-identity CAT02 round-trip matrix, and dropping it moves output by 3.8e-4.

### 8. Approximating a distribution can preserve RMS and still change the look

`fast_stats` reproduces grain RMS granularity to within 0.14% and flattens
**skewness to zero at every density**. Skewness is `1/sqrt(mu)` and `mu` rises
with density, so it encodes film's shadow-vs-highlight grain character
(+0.165 in shadows, +0.022 in highlights). Matching the second moment is not
evidence that a noise model is equivalent — check the third.

Use `grain_sampler='exact'` (default): Poisson-thinned, exact, 27× faster than
scipy. `use_fast_stats` is preview-only. See RFC-002 §3.4.

### 9. Grain draws are i.i.d. — chunking them creates no seam

The per-pixel draws have no spatial correlation, so partitioning them produces
a different realisation and no boundary artefact. Seams come only from the
blurs (`grain_blur`, micro-structure), which need ~4 px halos if you ever tile
them. Do not avoid chunking the draws out of seam fear; do not chunk the blurs
without halos.

### 10. `skimage.transform.rescale` is a hidden 7 s at 45 MP

`auto_exposure` builds a 256px preview with `rescale(..., order=0)`; for a
45 MP frame that full-resolution pass measured **7.1 s** — it was the single
biggest line in the decoupled profile (more than the actual multiply, 0.02 s,
or the meter, 0.003 s). The preview only needs a sparse sample of the frame,
so `small_preview` now uses a nearest stride-slice (`image[::step, ::step]`),
which is O(1) and collapses auto_exposure to ~0.1 s. GPU wouldn't have fixed
this — it was a CPU downscale, not a pointwise multiply. Profile before
concluding a stage is GPU-bound: isolate the sub-steps.

### 11. Colour bugs are silent, and a uniformly-biased suite reports full confidence

Three colour bugs were live simultaneously on 2026-08-26 with **750 tests
passing**: `input_cctf_decoding=True` raised on the fused path, the service
hardcoded it to False, and `auto_exposure` multiplied its gain into
gamma-encoded data (effective gain `g ** 1.8`). None crashed; two produced
*plausible photographs*.

They survived because **every test and baseline in this repo feeds linear
input**. Encoded integer files — what Capture One, Lightroom and Photoshop
actually export — were never exercised. The suite was not weak, it was
uniformly biased, which is worse: it reported confidence at the moment it knew
nothing.

Before trusting a colour result, ask what the *inputs* to the tests have in
common. See `rfc/RFC-010-color-science-testing.md`; the short version is test
**invariances** (same meaning, different representation → identical render),
not reference pictures.

### 12. The input contract is where the product actually breaks

`spektrafilm` is a camera: it needs scene-linear radiance. Everything hard
about external files is at that boundary, not in the physics.

- **`decode_input` runs at the door** (`preprocess.decode_input`). Everything
  downstream of `preprocess` is linear. Do not move the transfer function back
  into `upsample` — that is what caused the `g ** 1.8` exposure bug.
- **An exposure edit in an external RAW developer is not a gain** if a tone
  curve sits after it. Measured on Capture One: `+1 EV` exported as a ×1.57
  median ratio with a 1.8–2.1× spread across tones. With C1's curve set to
  **Linear Response** it becomes ×2.09 with 1.17× spread, and auto-exposure
  absorbs it (dE 13.7 → 0.94).
- **External decodes are not invertible.** A camera profile (C1's ProStandard,
  Adobe's, dcraw's matrix) cannot be recovered from the exported TIFF. Two
  developers give two different scene estimates and therefore two different
  film looks. Fix the decode as part of the product contract; do not attempt
  an adaptation layer.

### 13. Spectral upsampling has a structural blind spot in purple

`RGB -> spectrum -> XYZ -> RGB` round-trips at **1.7-3.8 dE at every hue**,
worst in the purple/violet band (mean 3.07, rotating ~6° **toward blue**).
Reconstructing a spectrum from three numbers is underdetermined and the
smooth-spectrum prior under-represents the bimodal spectra that non-spectral
colours require. This is structural, not a defect, and it is why a profiled
camera LUT can beat spectral reconstruction on those hues — it never builds a
spectrum. Pinned by `tests/test_spectral_roundtrip_hue.py`; do not raise those
bounds without looking at colours.

### 14. The engine that renders is whichever *data* the app resolved

The old form of this trap was about `PYTHONPATH` and editable installs, and it
is gone with the service: the engine is compiled into the binary, so the *code*
that renders is now unambiguous. The same failure mode moved one level down, to
the data.

`EngineClient.defaultResources()` looks in the **app bundle** first
(`Resources/engine`), then honours `SPEKTRAFILM_ENGINE_RESOURCES`, then walks
up to a checkout's `engine/resources`. That last fallback is for a build run
out of the tree and it is the one that can lie: a build whose resources were
never synced will happily render from whatever checkout is above it.

- `engine/build.sh bundle` is what syncs them. The app target has a pre-build
  phase (`Tools/check-bundle-resources.sh`) that fails the build if they are
  missing, so the silent case is *stale*, not absent.
- `EngineResourceOriginTests` asserts the resources resolve inside the bundle.
  It replaced `ServiceLaunchEnvironmentTests`, which guarded the `PYTHONPATH`
  version of exactly this.
- The two-worktree half of the old trap still applies to **Python**: an
  editable install pins a `.pth` to one `src`, so a worktree A/B under `pytest`
  can execute the same code in both arms. Set `PYTHONPATH=<worktree>/src` and
  check `spektrafilm.__file__` before believing any A/B. The parity harnesses
  take `PYTHONPATH=src:engine/tests` for this reason.

The original version of this bug cost a whole session — the GPU core lived on a
branch the app's checkout did not have, every render ran on numba, and the only
symptom was that things felt slow.

### 15. A refactor that only moves code can still move the wire

The wire is assembled from *both* halves: the Python `capabilities` dict and
the Swift `Capabilities` type that decodes it. A change entirely inside
`src/` can therefore break the contract while its commit message truthfully
says "no wire change" — this happened on 2026-09-10, when an engine/service
split dropped `transport_version` and `schema_version` from `capabilities`.
Neither field is optional on the Swift side, so the result would have been a
refusal to start (contract §2), not a warning.

Before landing anything that touches `_m_capabilities` or a response shape,
print the block and diff it against what the Swift type requires. The full key
set is pinned by a test on each side.

### 16. A check that exists on paper, in a configuration where it can never fire

Three instances of the same failure landed within one day, which is why it is
its own trap rather than three footnotes:

- `deactivate_spatial_effects` never zeroed `grain.micro_structure[0]`, a
  Gaussian blur radius. Invisible because the only test exercising the flag
  went through `lut_mode`, which *also* switches grain off — so the one test
  covering the check ran it where the bug could not be reached.
- `Session.warmUp` called `capabilities` with `try?`. Contract §2's "refuse an
  unknown transport with a visible error" was written down and never built, and
  a block the client could not decode was indistinguishable from a service that
  had not started.
- `test_a_reprint_does_not_touch_colour_science` asserted `not pandas` above an
  `xfail` for `colour` — but pandas-loaded is *entailed by* colour-loaded
  wherever pandas is installed. It passed only on a venv without pandas, i.e.
  not the one the product uses.

The shape to look for: a guard whose only exercise is in a configuration that
disables the thing it guards. Ask what the *inputs* to a passing test have in
common — the same question trap 11 asks about colour.

### 17. This machine is not a benchmark

Timings here are contaminated routinely and by large factors. On 2026-09-10 a
warm `service.open` read 1.86–2.81 s against 922 ms measured hours earlier;
the cause was **Civilization VI holding the GPU at 125 % CPU**, load average
6.2. The same unchanged commit has measured 23.3 s and 18.9 s hours apart.

- Check `ps -Ao %cpu,comm -r | head` and `uptime` before trusting a number,
  and say so in any message that quotes one.
- Measure **interleaved**, never sequentially: alternate arms within one
  session using `_FORCE_REFERENCE_*` or stash/pop.
- Prefer CPU time over wall clock when the question is about imports or
  allocation rather than the GPU.
- `core=metal` and correctness results are not timing-dependent; report those
  separately from speed, which is what makes a contaminated session still
  useful.

---

### 18. A slow render is not a fallback — three causes, all measured

A 45 MP full render taking ~13 s matched the numba number exactly, and read as
"Metal was never enabled". **There is no CPU path in the engine to fall back
to.** Three separate causes, and any of them can come back:

1. **The frame arena did not reuse within a render.** Buffers were reclaimed
   only at the end of a frame, so the footprint became the sum of every
   intermediate instead of the two or three live at once: ~11 buffers of
   288 MB at 24 MP, one command buffer making all 3.2 GB resident, **6.4 s
   instead of 0.4**. Buffers are reference-counted now (`gpu::BufferRef`).
2. **The setup caches were not ported.** Python has three
   (`_SETUP_CACHE`, `_OUTPUT_CMAX_CACHE`, `filming_tc_lut_memory`) and the port
   had none, so every parameter outside `LIVE_MUTABLE` re-derived the
   46,080-cell C_max table and the 192×192×81 tc_lut: 160–250 ms per slider.
   `core/setup_cache.hpp`.
3. **Full-frame copies on the open path.** The alpha strip ran per pixel in
   Swift at `-Onone`; the source was kept on the host *and* uploaded per tier.
   5.9 s to open a 24 MP RAW, now 2.0 s.

Before theorising: check `core=native-metal`, then time the tiers
(`live`/`preview`/`full` separately), then watch peak RSS across *repeated*
renders — a pool that grows is the tell.

### 19. Free is not idle

When a buffer's last handle drops, no *future* dispatch names it. That says
nothing about dispatches already encoded into an open command buffer. Handing
it to the next `alloc` there let a later kernel overwrite a buffer an earlier
one had not read: **25 of 27 render-parity cases wrong, no crash, no error
message.**

A freed buffer becomes reusable at `flush`, which is why the pipeline flushes
at node boundaries — the same place the reference evaluates (trap 5). If you
find yourself removing those flushes for speed, this is what you are removing.

### 20. The transferred kernels disagree about matrix orientation

`spk_tc_b` and `spk_cam16ucs_compress` want plain row-major M
(`out[i] = Σ m[3i+j]·x[j]`). `spk_matmul3` and `spk_cctf_encode_matrix` want M
**transposed**. Both are correct for the Python call site each came from —
`tc_b_matrix` already returns `RGB_to_XYZ(eye).T`, while `XYZ_to_RGB(eye)` is
handed through raw.

Getting it wrong shifted the red channel's mean by +0.14 and blue's by −0.08,
which looks like a grading decision rather than a bug. `pipeline.cpp` has
`row_major()` and `transposed()` helpers named for exactly this; use them.

### 21. The print balance evaluates its grey in sRGB

`FilmingStage._simple_rgb_to_density_spectral` calls `_rgb_to_film_raw(rgb)`
with no `color_space`, so it takes that method's **default — `"sRGB"`**, not
`io.input_color_space`. Every print's exposure is normalised against an sRGB
grey whatever the frame is encoded in.

That reads like an oversight and may be one, but it is what sets the balance.
It is reproduced deliberately as `core/printing.hpp::kMidgrayProbeColourSpace`;
using the input space instead moved every rendered print by 2 counts over 93 %
of the frame. If you "fix" it, expect the parity suite to go red and think
hard about which side is wrong.

### 22. Two wire parameters do not mean what the schema says

- **`camera.lens_blur_um` does nothing on the Python engine.**
  `_build_topology` derives its sigma from `pixel_size_um`, which is `None`
  until the first render, so the node is pruned unconditionally. Measured:
  `max |out(0) − out(50 µm)| == 0.0` exactly. The C++ engine computes blur
  sigmas per run, so the parameter works there — a deliberate divergence, and
  `parity_render.py` fails if the two ever *agree*.
- **`dir_couplers_amount` above ≈1.736** (bisected on kodak_portra_400) makes
  the coupler inverse's own exposure axis non-monotonic, and `np.interp`
  requires an increasing `xp`. Past that the reference's output is a product of
  numpy's internal search rather than of the model. **The wire allows up to
  4.0**, so the schema's range is wider than the maths supports.

### 23. A green parity suite is not a correct picture

Two of the six real bugs in the port were outside every harness's reach,
because the harnesses hand the engine a numpy array and never go through the
app's own file reader:

- a **vertical flip** in `readLinearRGB` produced a correctly developed,
  upside-down photograph with 27 of 27 cases green;
- the result **texture was arena-owned** and freed before the caller could draw
  it.

`testTheFrameIsReadTopRowFirst` and `testEachTierRendersAtItsOwnResolution` pin
both. **Look at a snapshot.** `--snapshot` is cheap and it is the only check
that sees the thing the user sees.

### 24. A test does not own `UserDefaults.standard`, and the class before it does

The app's persisted settings are one object for the whole test process, so a
value one test class writes is the value the next class reads. Measured
2026-09-12: `DiagnosticsTests.testADevelopEmitsTheExpectedRecords` asserts
"exactly one render record" for the 1 MP smoke frame, which holds only while
the preview resolution is above that frame's 1200 px long edge. Run the class
alone — green. Run the whole suite behind a class that had set the edge lower
— two render records, and the second one is a *correct* native render of a
frame that is now larger than the preview. The test was never wrong about the
code; it was wrong about its inputs.

`Session.previewEdgeKey` (`ui2.previewLongEdge`) is the instance that bit,
because it is read at session start and changes what the app renders. Anything
under `Session.uiKey` or `diag.*` behaves the same way.

The rule is therefore: **a test that depends on a persisted setting sets it and
restores it**, with the previous value captured before the write and put back
in a teardown block — `DiagnosticsTests.configure()` is the pattern. Do not
assume the default, and do not "fix" the other class by restoring harder.

A second instance, found within the hour of the first and worse in kind: a
collapse-animation test read `ui2.leftCollapsed` out of `UserDefaults`, which
someone's own `defaults write` experiments had left set. The panel was already
folded, so the collapse was a no-op — and the test **measured zero of
everything and reported success**. A wrong count fails loudly; a test whose
subject did not happen passes quietly, and it is the same family as trap 16.
Handlers that write `Session.uiKey` keys outside the app (a `defaults write`, a
capture tool, another test) are enough to do it.

This is worse than an ordinary flake, and it is why it is a trap rather than a
footnote: it cannot fail in isolation, so it never shows up while you are
working on the thing it is about. It lands later, on someone else's change,
looking exactly like a regression in the code under test — the same shape as
trap 16 (a check that runs in a configuration where it cannot fire) and trap 11
(every input shares a property nobody named).

**Two more instances, 2026-09-14, and both named the wrong file.** A test that
set `UserDefaults.argumentDomain` to prove the launch argument reaches the
session could not clear it again — `removeVolatileDomain(forName:)` does not
take — so `ui2.previewLongEdge` stayed at 8192 for the rest of the process and
`testTheZoomLabelIsMeasuredAgainstTheNativeFrame` failed three classes later
with "the canvas is holding the frame itself". And
`FrontendPolicyTests.testThePreviewResolutionDefaultsAndClamps` asserted
`Session().previewLongEdge == Session.defaultPreviewEdge`, which is an
assertion about *the machine*: it failed on 1200, a value no code in the suite
computes, left in the store by another class's run that was killed mid-flight.

So the rule above has a stronger form: **a test that depends on a persisted
setting should not read the shared store at all.** Take a `UserDefaults` and
inject a throwaway suite — `Session.previewEdge(in:)` and `PanelWidthStore`
both do. Set-and-restore works until a run is interrupted; injection cannot be
interrupted into leaking, because there is nothing shared to leak.

The reason this keeps costing hours rather than minutes is the diagnostic: the
failure names the wrong file. Nothing in the failing test's name, body or class
mentions the setting that broke it.

### 25. An `@Observable` `didSet` that writes to itself recurses

Measured 2026-09-12 in `Diagnostics`, and it cost the test process rather than
an assertion. The clamp below is the obvious way to write a bounded setting:

```swift
var days: Int {
    didSet {
        days = days.clamped(to: 0...365)      // ← unbounded recursion
        defaults.set(days, forKey: key)
    }
}
```

Under `@Observable` the macro rewrites a stored property into a computed one,
and the compiler's rule that assigning inside a property's own observer does
not re-enter it does not survive that rewriting. The result is
`setter → didSet → setter → …` until the stack ends: xctest dies with SIGSEGV
and "Could not determine thread index for stack guard region", and the stack in
the crash report is the same three frames repeated. In the app the same
property would have taken the Settings page down on the first edit.

A self-assigning observer is safe **only if it reaches a fixed point**:
`Session.comparePosition` writes to itself and is fine, because the second pass
finds the value already in range and stops. If you are about to write one, ask
what makes the second pass a no-op — if the answer is "nothing", write it as a
computed property over a private stored one instead, with the clamp in the
setter, which is what `Diagnostics`' four numbers do now.

**One near miss is already in the tree.** `Canvas/Renderer.swift` has the same
unconditional self-assignment for `comparePosition`, and it is *safe* — but
only because `Renderer` is a plain `NSObject` subclass rather than
`@Observable`, so the compiler's stored-property rule still applies. If anyone
ever makes `Renderer` observable (it is a candidate: it is the one model the
views currently read through hand-written mirrors), that line takes the process
down. Change it to a computed property in the same commit.

Two things follow. A settings property that is only ever exercised at its
default is not exercised at all — the crash above was found by a test that
assigned an out-of-range value, which no earlier test did. And a stack overflow
is a *crash*, not a failure: it restarts the test run ("Restarting after
unexpected exit, crash, or test timeout"), so a suite that reports it must be
read as "a test did not finish", not as "a test failed".

### 26. A skipping suite and a full suite both report `0 failures`

The camera fixtures are not in this repository — they are in the `spektrafilm`
fork, and `tests/Test_image/` is gitignored here with a rule that says why.
Each checkout reaches them through a `tests` symlink **whose correct target is
different in each checkout**: a git worktree points at the main checkout, the
main checkout points at `../spektrafilm`. A checkout without one skips the
fixture-dependent cases and says so in a line nobody reads.

Measured 2026-09-14: **18 s with 25 skipped against 375 s with 0**, and *both*
report `0 failures`. The 25 included the cases carrying RFC-018 §7.2 and §7.6 —
the two measurements the whole colour round rested on — so "landed as a test"
was hollow for a round without anyone noticing.

**Read the duration, not the failure count.** A real run of `SpektrafilmTests`
on this machine is ~390 s. Anything under a minute means the fixtures are not
there. `git check-ignore -v tests` should print `.gitignore:/tests`, and
`ls tests/Test_image/A7m3` should list the ARWs.

The symlink is ignored rather than merely untracked, and that is the point: a
file with three different correct contents cannot be committed carefully, only
not committed. It *was* committed once, by a `git add -A` that could not tell a
local convenience from a change; in the main checkout it then resolved to this
repository and `tests` became a link to itself.

Same family as trap 16 and the second half of trap 24: a check that reports
success while measuring nothing.

### 27. Every UI literal that reaches the drawable is in the working space

The canvas texture holds the *picture's* colour space, and the app paints its
own chrome into it — the letterbox around the frame, the mask overlay's red.
Those were written as sRGB code values and were correct for as long as the
texture was Display P3, whose transfer function is sRGB's.

RFC-018 moved the canvas to ProPhoto RGB (γ1.8), and the same numbers then
meant different colours. Measured: the ground `0x5F/255` is linear 0.11444,
which re-encodes to **0.29990** in ROMM — left alone the surround would have
carried **1.478× the light** and the whole interface would have shifted around
the photograph.

**The check that needs no "before" image**: the window's outer margin is an
sRGB `CGColor` that AppKit colour-manages itself, and the canvas letterbox is
the shader's value through the tagged layer. They are two routes to the same
grey and must land on the same pixel — live capture reads **95 and 95.03**. As
the raw literal it read ~113.

Note also that `--snapshot` cannot referee this: `cacheDisplay` applies a
window-level conversion that follows the layer's tag, so an offscreen A/B
compares two conversions rather than two renderings and *everything* differs,
including regions nothing touched.

### 28. A harness that keeps its own copy of a convention goes red for a change no node made

`spk_open` establishes the session's output colour space. Three parity
harnesses had that convention written into them as a constant rather than read
from the open reply, so when RFC-018 changed the engine's output from Display
P3 to ProPhoto RGB they went red — 23 of `parity_render`'s 27 cases, all 9 of
`parity_grain`'s levels, the whole of `parity_exposure`'s c3 — for a change
that moved no node and altered no arithmetic.

They read `params.io` out of the open reply now, which is the field RFC-018
§5.1 added for exactly this. **A harness asserts about the engine; anything it
believes about the engine's configuration it must ask for.**

One harness in the same family is worth knowing about separately:
`parity_schema` compares `params.hpp`'s declared default against the Python
oracle, and the oracle still declares sRGB. That one *cannot* be made green
here — the oracle is the comparison — so it carries a recorded `KNOWN`
divergence in the shape `parity_render.py` uses for `lens_blur_um`: named, with
its reason, and **failing if the two ever agree again**.

### 29. `kCGImageDestinationEmbedThumbnail` does nothing for TIFF

Measured 2026-09-14: a TIFF written with and without that option is
**byte-identical** (2,883,534 bytes either way, `CGImageSourceGetCount` = 1).
The mechanism TIFF actually has is a second page — a second
`CGImageDestinationAddImage`.

The reading half is the part that bites, because it fails *plausibly*:
`CGImageSourceCreateThumbnailAtIndex` does **not** find the second page. It
returns a 2048 px downscale of page 0 instead, at the same cost as if no
preview existed — so a thumbnail call appears to work while showing the wrong
picture, and a size assertion cannot tell the two apart because they are the
same size. The preview must be read by index:
`CGImageSourceCreateImageAtIndex(src, 1, nil)`.

`ExportPreviewTests` writes a two-page TIFF whose pages are deliberately
*different colours*, because that is the only way a test can tell a real page 1
from a downscale of page 0. `ExportPreviewChainTests` drives the real export,
where both pages necessarily carry the same picture — so there the long edge is
what discriminates, and neither test is sufficient alone. Both say so.

## Conventions

- Match surrounding style: the codebase uses NumPy-style docstrings, explicit
  named parameters, and numba `@njit(parallel=True, cache=True)` for hot loops.
- New backends go behind a `settings.*_backend` string. The spectral backend
  default is now `'mlx'` (MLX-first, RFC-001); if MLX is unavailable the
  render raises loudly rather than silently using the CPU path. Never change
  a default that alters output without saying so.
- The GUI (`spektrafilm_gui.params_mapper`) forces `spectral_backend='mlx'`
  so persisted states cannot revert to a CPU path. MLX launches require real
  Metal access, so GPU work (and the GUI itself) must run outside the sandbox.
- RFC-003 pipeline decoupling has landed: `runtime/pipeline.py` builds ~24
  effect-level `Node`s (e.g. `filming.expose.upsample` ... `scanning.cctf`)
  instead of the six monoliths, with the monolith methods kept as thin
  wrappers over the same effect methods. It is a pure refactor (output is
  bit-identical; `tests/test_rfc003_split.py` guards the structure). The split
  itself does **not** cut peak memory at float64 (measured 12.38 GB / 275 B/px
  at 45 MP vs 12.58 GB / 280 B/px pre-split): the biggest temporaries are
  float64 *inside* the kernels (spectral upsampling colour conversion,
  halation blurs, grain sublayers, CAM16 gamut compression). Real memory
  reduction needs kernel-level float32 / per-node precision, which is deferred
  (measured ΔE max 2.42 / MS-SSIM 0.9955 on the GUI config — fails the strict
  bar). Effect labels above are also the timing keys `get_timings()` returns.
- RFC-004 GPU port has landed its P0–P2 kernels: `backends/mlx_ops.py` has the
  device wrapper/residency primitive plus float32 pointwise kernels
  (`gpu_scale`/`gpu_log10`/`gpu_boost`/`gpu_cctf_srgb`) and a separable Gaussian
  Metal kernel (`gpu_separable_gaussian`). They are wired into the pipeline
  behind `settings.gpu_backend='mlx'` (default `''` = CPU reference, unchanged).
  Validation (deterministic, ProPhoto→Display P3): GPU vs CPU float64 gives ΔE
  max 6.1e-5, PSNR 150 dB, MS-SSIM 1.0 — visually identical. The `Node` GPU body
  is `run_mlx` (single-read/write); per-node GPU runs upload+download, so the
  P0 residency *grouping* (a device-resident run) is still to be added, and only
  exposure/boost/log/lens_blur/scanner_blur/cctf are ported (the dominant
  `upsample`, `halation`, `grain`, `gamut_compress` are P3/P4/P5). Keep grain +
  glare OFF for any CPU-vs-GPU ΔE comparison (RFC-001 6.0/6.1): the stochastic
  grain realisation differs once upstream floats to float32.
- RFC-004 P1 pointwise color stages added: `gpu_xyz_to_rgb` (3x3 matmul; the
  matrix is `colour.XYZ_to_RGB(np.eye(3), cs, illuminant=...)`, and the node
  result is `xyz @ matrix`) and `gpu_curve_interp` (a small Metal LUT kernel
  matching `fast_interp`: endpoint clamp, binary search, right-biased exact
  match). Curves and XYZ→RGB are now GPU-wired. At 45 MP (deterministic,
  ProPhoto→Display P3) the GPU path is ΔE max 0.000086 / MS-SSIM 1.0, time
  ~22.6 s vs ~25.4 s CPU, peak 12.2 GB. The precision map (float64 CPU color
  reference vs float32 GPU) is the deliberate RFC-004 policy: `upsample` and
  `gamut_compress` (CAM16) stay float64 for color accuracy; grain/glare stay
  exact (off in A/B).
  **Trap:** the curve `x_axis` must be `(K, 3)` — the scalar density-curve
  gamma must be expanded to 3 channels (`np.repeat(gamma, 3)`), otherwise the
  axis is `(K, 1)` and the kernel reads 3 columns of garbage (measured 2.05
  error). Mirror `interpolate_exposure_to_density`'s `gamma_factor` expansion.
- RFC-005 (dispatch + kernel quality) landed. Four things to know:
  **(1) A GPU tag was silently a precision decision.** A node with
  `backend=('mlx',)` returned float32, which propagated into every downstream
  CPU stage — so removing a tag changed *numerics*, not just placement.
  `Node.precision` is now honoured by the dispatcher and the float32 taps are
  declared explicitly. Never add or remove a `backend` tag without checking
  what it does to the tap dtype.
  **(2) `prune_identity_nodes` aliases taps.** Dead-node elimination must
  rewrite downstream `reads` through the dropped node's read tap, or the
  successor can never fire. Four nodes are pruned at default params (both
  blurs, diffusion filter, unsharp).
  **(3) `to_device` passes `mx.array` through.** Calling it on a device array
  used to round-trip via host (37.5 ms at 45 MP); a single blur did four.
  **(4) Bare-Metal/metal-cpp was measured and rejected**: a Python →
  `mx.fast.metal_kernel` launch is 157 µs, ~0.07% of the render.
  `mx.fast.metal_kernel` already compiles hand-written MSL — those kernels
  *are* bare Metal.
- RFC-007 A (CPU fusion) landed: `utils/fused_gamut_cam16.py` and
  `utils/fused_tc_b.py`. 45 MP interleaved A/B: **18.93 s → 12.93 s (-31.7%)**,
  dE2000 max 0.000041, 0 of 16.0 M pixels above dE 0.1. `upsample` 3.97 → 0.59 s,
  `gamut_compress` 4.32 → 1.38 s. The pattern: **colour-science stays at setup
  time** (matrices via the identity trick, viewing-condition constants, the
  C_max table), and only per-pixel math is fused. Use `_FORCE_REFERENCE_CAM16` /
  `_FORCE_REFERENCE_TC_B` to A/B the two paths in one process.
  **Traps, all of which produced plausible-looking wrong output:**
  the CIECAM02 inverse (a,b) solve carries 460/1403, 220/1403, 27/1403 and
  6300/1403 factors (omitting them: dE 33); colour uses a *sign-preserving*
  power for J, so negative achromatic response gives negative J, not 0;
  the GUI default sets `lightness_compression`, so a kernel that skips it
  falls back to the reference and becomes **dead code on every real render**
  while unit tests pass — the A/B is what caught it; the reference accepts any
  `(..., 3)` shape, not just `(H, W, 3)`.
  **Never call a `parallel=True` numba kernel from inside `parallel_pointwise`**
  — numba's `workqueue` layer is not threadsafe and aborts the process.
  `_scan_gamut_compress` bypasses the thread pool for the fused path.
- **RFC-006 landed: `working_precision='float32'` is the default.** The
  invariant is in `utils/precision.py`: full-resolution buffers follow their
  input's dtype, per-pixel arithmetic still runs in float64 registers (a
  float32 load times a float64 constant promotes inside the numba kernel, so
  CAM16 / Hanatos / the spectral integral do the same arithmetic they always
  did — only the *stored* result narrows). Measured at 45 MP, grain on
  (`exact`), glare off: **18.34 s / 12.55 GB at float64 vs 14.25 s / 7.15 GB
  at float32**, dE2000 max 0.00024, MS-SSIM 1.000000, grain PSD correlation
  0.999993. Held across five film/print stock pairs.
  **Trap:** `working_precision='float64'` used to be spelled `precision=None`
  in `run_topology` — "leave every dtype alone". That was only equivalent to
  float64 because every kernel promoted internally. Once the kernels stopped
  promoting, the taps RFC-005 declared `precision='float32'` leaked downstream
  into `grain`, where a rounded input flips Poisson draws and gives a
  *different realisation* — dE max 37.9 against the baseline, which looks like
  a catastrophic colour bug and is actually one node's worth of noise.
  `run_topology` now widens node inputs to the working precision as well as
  narrowing outputs. Side effect: the float64 path is now genuinely float64
  (it previously carried accidental float32 rounding in exposure/boost/
  halation), which moved the float64 baseline by dE max 0.000188 / PSNR 151 dB.
- The 45 MP profile after RFC-007 A is **spatial-dominated**: halation 3.30 s
  (26%), dir_couplers 2.40 s (19%), scan_spectral 1.58 s (12%). Neither of the
  top two fuses the way the pointwise stages did (halation is `support=inf`).
  Estimates written against the old pointwise-heavy profile are stale.
- **Measure interleaved, never sequentially.** This machine drifts: the same
  unchanged commit measured 23.3 s and 18.9 s hours apart. Stash/pop or use the
  `_FORCE_REFERENCE_*` switches and alternate arms within one session.
- **RFC-011 landed: the render core is Metal.** `settings.gpu_backend='metal'`
  runs the whole topology on `backends/metal/` (45 MP, 14.15 s → 1.03 s), held
  to float32 storage epsilon against numba. **numba is the reference and stays
  forever** — it stopped being the runtime, not the truth. Every ported node
  has a `scripts/gpu_native/parity.py` row. 20 of the 21 default nodes are on
  Metal; `preprocess.crop_rescale` has no Metal body (ARCHITECTURE §8.2).
- **RFC-012 landed steps 1, 3 and 4.** The engine is split from the wire
  (`service/engine.py` vs `service/service.py`, "the engine returns pixels, the
  service turns pixels into paths", guarded by an AST check in
  `tests/test_rfc012_engine_seam.py`); the colour constants are baked
  (`model/colour_baked.py`, 21.9 KiB for ~148 MB of dependencies); and a C++
  gate proved MLX kernels are byte-identical from `libmlx.dylib`. **Step 5, the
  native host, is unstarted.** Do not put rendering logic in an RPC handler —
  that seam is what makes option D a deletion rather than a rewrite.
- Anything claiming a speed or memory win must come with a measurement in the
  same message. `tracemalloc` for allocation, `resource.getrusage` for RSS.
- Quality claims need a ΔE number from `compare.py`, not an eyeball.

## Do not

- Do not commit or push unless asked.
- Do not edit `AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` or `CONTRACT-*`
  without telling the other session — contract §4 makes them shared, and a
  unilateral edit makes the other side's context wrong.
- Do not restore `tests/baseline/`. See "Fixed experimental setup".
- Do not delete `Session.LoadClock` (the open-path instrument) or the
  `core=native-metal` line it prints.
- Do not remove the per-node `flush` in the pipeline's `SPK_NODE` macro, or the
  one between `Blur::mixture` components, as a batching optimisation — trap 19.
  They are what makes a freed buffer safe to reuse.
- Do not drop `-fmetal-math-mode=safe` / `-fmetal-math-fp32-functions=precise`
  from `engine/build.sh`, and do not move the kernels into the Xcode target
  (which compiles `MTL_FAST_MATH = YES`). `spk_math_probe` will refuse to start
  the engine, which is the intended outcome, not a bug to work around.
- Do not "fix" `kMidgrayProbeColourSpace` to use the input colour space without
  reading trap 21 first.
- Do not tighten the render-parity bar to float32 epsilon. It is 3e-5 because
  that is what the *validated* Metal core measures on the same frame; no GPU
  path over 21 nodes meets epsilon (`ARCHITECTURE.md` §8.6).
- Do not add GPL-incompatible dependencies. The code is GPL-3.0-or-later; the
  profiles under `data/profiles/` are CC BY-SA 4.0 with separate attribution
  obligations.
- Do not change `SPECTRAL_SHAPE`, the profile data, or `LOG_EXPOSURE` — every
  baseline assumes them.
