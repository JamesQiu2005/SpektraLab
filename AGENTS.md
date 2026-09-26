# AGENTS.md — working notes for AI sessions on SpektraLab

The macOS desktop product built on the **spektrafilm** engine. Extracted from
the `spektrafilm` fork into its own repository on 2026-09-11; current as of
1.1.1 + main, 2026-09-26. This file records conventions and, more importantly,
the traps that cost real debugging time.

**Read first:** `ARCHITECTURE.md` §0 (the map), §7 (the app, including §7.7
*surfaces that show the frame* and §7.8 *export*), then the traps below —
trap 26 before trusting any green run, trap 33 before trusting any green
surface.

---

## What this repo is, in one screen

> 不要为了修 rendering problem 去污染 material model。
>
> **Do not pollute the material model to fix a rendering problem.** A film or
> paper profile describes measured capability, not a control surface. Scene
> placement belongs before the film, output headroom belongs after the print,
> and the final look belongs in Layer 2. Fix the stage that owns the decision;
> never rewrite a measured response to hide a limitation in another stage.

**One binary.** The macOS app under `modern_UI/` has a C++ render engine
(`engine/`) compiled into it and reached through a hand-written `extern "C"`
surface; it renders into an `MTLTexture` the canvas draws. There is no Python
in this repository — no `src/`, no `.venv`, no subprocess, at build time or at
run time. `ARCHITECTURE.md` §0 is the map and §8 is the engine. RFC-014 §8 is
the after-the-fact record: what parity measures, why each bar is where it is,
and the bugs already found.

**Half of this product is an interface, and it now has a picture.**
`screenshots/` is the app as it renders — the editor window, the before/after
split, grain at 1:1 — captured from the *running app*, not from the snapshot
harness. Look at it before changing anything on the canvas or the rails.
`ARCHITECTURE.md` §7 says what each row of each rail costs (four different
things on the left rail alone), `modern_UI/Spektrafilm/README.md` is the
detail, and `modern_UI/reference_layout/Main/` is the drawing the layout is
measured against. A capture earns its place by settling arguments: this one is
what caught §7.3 still describing a tier ladder five days after the ladder was
deleted — a `full` badge at a 33 % fit is a thing a document cannot talk its
way out of.

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

The engine's parity harnesses are `engine/tests/parity_*.py`, driven against
the upstream Python oracle through `PYTHONPATH` (README, "Parity harnesses").
Use the **1 MP** frame for them: parity is a correctness question, and a check
you can afford on every change beats one you run at the end.

The Python-era measurement kit (`scripts/gpu_native/`, `compare.py`,
`tests/baseline/`) lives in the fork, not here, and `tests/baseline/` is gone
for good — **do not restore it**. Numbers in this file measured against it
stay as history; they cannot be reproduced as written.

Whole-app timings come from the app's own instrument (`Session.LoadClock`,
`SPEKTRAFILM_CANVAS_LOG=1`, "The app" below): it measures what the user
experiences rather than what a script measures.

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
SPEKTRAFILM_ENGINE_RESOURCES=/path/to/SpektraLab.app/Contents/Resources/Resources/engine \
    PYTHONPATH="$REF/src" "$REF/.venv/bin/python" engine/tests/parity_lut.py
```

### The app

```bash
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py        # REGENERATE after adding/removing any source file
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
    -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
    -configuration Debug -derivedDataPath build/DerivedData test   # full suite; ~430 tests, ~420 s with fixtures
```

**Test gates.** Do not run the full `SpektrafilmTests` target after every small
commit. Use the smallest gate that can catch the change, and widen only at a
real integration boundary:

- While implementing, build the affected target and run only the test classes
  or cases that cover the change (`-only-testing:SpektrafilmTests/...`). A new
  regression test should be shown red on the old or deliberately broken
  behavior before it is shown green.
- After a coherent group of commits, or before merging/pushing a branch, run
  the full `SpektrafilmTests` target once. A real run with fixtures is ~420 s (it was ~390 at 277 tests);
  anything under a minute means the fixture-dependent cases were skipped
  (trap 26), not that the suite became fast.
- Run the engine parity harnesses only when engine inputs, kernels, resources,
  or the render boundary changed. Do not pay for them on a UI-only commit.
- A commit records the narrow gate that ran. The full gate belongs to the
  integration boundary, not to every worker handoff.

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
  | grep -E "open path|full render"
session: open path (ms): decode 76 · preview-texture 195 · linear-tiff 51
         · service.open 1613 · solve 30 · reprint 44 · TOTAL 2011
         · core=native-metal
session: full render requested for DSC03710.ARW
session: full render <w>x<h> landed in <n> ms
```

**`core=native-metal` is the first thing to check**, and it is now the *only*
value it can take — if it says anything else the app is not running this
engine. `service.open` keeps its name for continuity; there is no service, and
what it measures is Core Image rendering the linear TIFF to a float bitmap plus
the upload. On a 24 MP RAW that read is most of it.

The `full render … landed` line is the one that says the frame reached the
canvas at its **own** resolution. It used to read `detail preview 3400x2266
landed`, from the tier ladder deleted on 2026-09-12 (`ARCHITECTURE.md` §7.3);
grepping for `detail` finds nothing now. `renderFullRender` drops a result
whose generation, selection or *session* has moved, so when the render is slow
the line never appears and the app looks like it never showed full resolution
— which is what a 13.6 s render did before trap 18 was fixed. The `full` badge
in the canvas's top-right corner is the same fact, on screen
(`Session.canvasBadges`).

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

### 30. `exposure_compensation_ev` moves the negative and not the print

Measured 2026-09-21 through the shipping dylib on a neutral ramp:

| | Y(0) via `exposure_compensation_ev` | Y(0) via the same gain on the input |
|---|---:|---:|
| −2 EV | 0.17332 | 0.01862 |
| 0 EV | 0.17563 | 0.17563 |
| +2 EV | 0.17309 | 0.58430 |

On the **negative** (`io.scan_film: true`) the two paths are `np.array_equal`.
The cancellation is on the print side, and it is deliberate:
`core/printing.cpp:168` computes the enlarger gain from
`kMidgray * 2^exposure_compensation_ev`, with `print_exposure_compensation` and
`normalize_print_exposure` both hard-coded `true` in `params.hpp:151-152`,
neither on the wire, both cleared only under `debug.lut_mode`. The enlarger
re-times the print for the film exposure, the way a darkroom printer does.

So **Exp. Comp. changes where the scene sits on the film's characteristic
curve — contrast, toe and shoulder engagement — and not the print's
brightness.** At ±6 EV the mid holds near 0.175 while the contrast collapses;
that is the signature. `enlarger.print_exposure` is the control that moves print
brightness (0.5 → Y(0) 0.535, 2.0 → 0.025).

**The consequence for any experiment:** a session that uses Exp. Comp. as a
brightness control to compare against is measuring nothing. Pre-multiply the
input instead — bit-identical on the negative, and it behaves as expected on the
print. RFC-023 §15.4 lost a control run to this.

### 31. Colour dies in the toe long before tone does

Measured 2026-09-21, `kodak_portra_400` + `kodak_portra_endura` at defaults: the
same chromaticity placed at different scene exposures and rendered, C\*ab of the
print.

| scene EV | −5.0 | −4.0 | −3.0 | −2.0 | −1.0 | −0.5 | 0.0 | +1.0 | +2.0 | +3.0 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| skin | 1.6 | 1.1 | 3.9 | 14.1 | 22.3 | **24.5** | 23.7 | 21.2 | 14.2 | 5.3 |
| foliage | 1.5 | 0.9 | 1.9 | 12.1 | 29.1 | 38.5 | 47.0 | **56.1** | 51.8 | 35.7 |

**Below about −3.5 EV everything renders at C\*ab ≈ 1.7 — as a grey, not as a
dark colour.** Taking 50 % of peak as the boundary, the **colour window is about
4.2–4.4 stops** while the ISO-6846 *tonal* window on the same pair is **5.66
stops**. A medium's colour latitude is narrower than its tonal latitude.

Two things follow. Any work that asks "how many stops does this medium hold"
must say **of what** — and the answer for tone is not the answer for colour.
And a shadow-recovery feature that lands content between the colour boundary and
the tonal boundary produces a region that is lighter and still grey; the
emulsion did not record the colour and nothing downstream can return it.

The measurement is cheap and reusable: `rfc/probes/rfc023-slm-probe.py`
(`probe_medium`, plus the Lab helpers in RFC-023 §16).

### 32. AppKit offers a key to the menu before the focused text field

Measured 2026-09-26 with a bare `NSMenu` and an `NSTextField`: a menu item
whose key equivalent is a modifier-free **←** fires while the field has focus,
and the caret never moves. The app's Capture One shortcuts are exactly that —
←/→ step frames — so renaming a recipe and pressing ← switched photographs. A
plain letter happened to reach the field in the same experiment; nothing
promises it, and SwiftUI builds its own menu items.

`Windows/TypingKeyGuard.swift` is the fix: a local key monitor that hands
typing keys (characters, arrows, delete) straight to a focused editable
`NSTextView` before the menu is asked, and leaves ⌘/⌃ combinations and
Return/Enter/Esc/Tab to the menu. **Adding a single-key shortcut needs no
extra work**; removing the monitor brings the bug back, and
`TypingKeyGuardTests` has a control that shows it.

The canvas's own `keyDown` (`MetalCanvasView`) was already guarded; the menu
was not. Two key paths, one checked — the same shape as trap 16.

### 33. A green unit is not a correct surface

The navigator shipped (1.1.0) showing the **uncropped** photograph after a
crop, with every suite green. Nothing was wrong with any unit: the thumbnail
was a correct thumbnail, the geometry correct geometry. The surface read its
picture from a different source than the canvas does, and no component test
can see that.

The audit that followed found a second one immediately: the canvas
**histogram** counts the uncropped print, because `Renderer.encodeHistogram`
reads the Layer 2 texture and geometry is applied only when the canvas
samples. It is pinned, not fixed (`XCTExpectFailure(strict: true)` — the test
goes red the day it is fixed, so remove the marker then).

The rule: **every surface that shows the frame must show the canvas's frame**,
and it is tested by giving the frame a crop *and* a quarter turn, reading the
surface, and comparing with the canvas — `SpektrafilmTests/
SurfaceAgreementTests.swift`. A new panel, readout, file or agent tool that
shows the frame gets a case there. `ARCHITECTURE.md` §7.7 is the table of
which surface shows what, and why the filmstrip deliberately differs from the
navigator.

### 34. The exporter writes whatever frame is open

`Exporter.export` reads `session.selection`; a batch opens each frame in turn
with `select`. Until 2026-09-26 nothing stopped a click, an arrow key or an
agent call from moving the open frame between the run's `select` and its
write, which put one frame's render under another's file name. Now
`Session.batchExporting` holds it: `click`, `open(_:)`, `togglePick`,
`open(urls:)` and undo are no-ops, the editor takes no hits, agent tools that
touch a frame are refused. **Anything new that changes the open frame on a
person's behalf must check `batchExporting`**; `select` itself must not, since
it is the run's own door.

### 35. Sidecars are not beside the photograph

Easy to assume, and wrong since 06847ab (2026-09-13): a frame's edits live in
`~/Library/Application Support/SpektraLab/Sidecars/<file>-<sha256(path)[:16]>.spektra.json`,
with a fingerprint so a moved file is recognised. `<image>.spektra.json` beside
the photo is the *old* home, migrated (moved) on first read. So "the app
writes nothing into the user's folder but exports" is true, and a
`find … -name '*.spektra.json'` in a photo folder finds only leftovers. The
per-frame geometry the thumbnails need is read from these at `open(urls:)`
into `Session.savedGeometry` — one read per frame, shared with `frameStates`.

---

## Conventions

- **Match the file you are in.** Comments here explain *why* and record what
  was measured; keep that density. Swift is `@Observable` + `@MainActor` for
  model state, actors for anything shared across threads (`EngineClient`,
  `DiskCacheStore`, `PrintWriteback`). C++ is C++20, `noexcept` at the ABI.
- **Run `Tools/gen-project.py` after adding or removing any file**, Swift or
  engine `.cpp`. A missing Swift file reads as `cannot find X in scope`; a
  missing `.cpp` as a link error.
- **Test gates** (see "The app"): the narrowest classes while working, the full
  `SpektrafilmTests` (~430 tests, ~420 s) before a push. Record the gate in the
  commit message. Show a new regression test red before green.
- **Anything that shows the frame gets a `SurfaceAgreementTests` case** (trap
  33). Anything that changes the open frame checks `batchExporting` (trap 34).
- **A test owns its inputs**: inject a `UserDefaults` suite (trap 24), copy
  fixtures before opening them (a develop writes a sidecar), never read the
  shared store for a persisted setting.
- **Measure, then claim.** A speed or memory claim comes with its measurement
  in the same message; memory is `footprint -p <pid>`, not RSS, which cannot
  see the Metal pool (`rfc020-measurement-traps`). This machine drifts —
  measure interleaved, never sequentially.
- **Releases are ad-hoc zips** by the user's decision (no Developer ID; do not
  re-propose). A fix that is not a release does not bump `MARKETING_VERSION`.
- **`screenshots/` must match the interface**; when it moves, say so in the
  commit. Captures are of the running app, not the snapshot harness; never
  resample the 1:1 grain capture. The main captures are the user's own
  (`Screenshot_English.png`, `Screenshot_ZH_HANS.png`, one per README) —
  ask before replacing them.
  `Tools/capture-live.sh` force-quits every running SpektraLab — if the user
  has one open, launch a second copy by hand instead.
- **Do not delete the history, but do not follow it.** RFC-001…RFC-012 and
  traps 1–13 describe the Python/MLX engine that stayed upstream. They are why
  the port looks the way it does; their commands do not run here.

## Do not

- Do not commit or push unless asked.
- Do not edit `AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` or `CONTRACT-*`
  without saying so first — they belong to nobody in particular, and a peer
  session may be reading them.
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
  profiles under `engine/resources/profiles/` are CC BY-SA 4.0 with separate attribution
  obligations.
- Do not change the spectral shape (81 × 5 nm), the profile data, or the
  log-exposure axis — every parity bar assumes them.
- Do not remove the `XCTExpectFailure(strict: true)` marker on the histogram
  case except in the commit that fixes the histogram (trap 33).
