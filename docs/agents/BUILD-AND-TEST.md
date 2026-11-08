# Build, test, measure — the detail

Moved out of `AGENTS.md` on 2026-10-29, word for word. `AGENTS.md` keeps the
commands and gates most tasks need; this is the rest: the environment, the fixed
experimental setup, the parity harnesses, the app's capture and timing tools, and
black and white. Where it says "trap N", see `TRAPS.md` beside it.

**Two eras in one file.** The engine sections (parity harnesses, fixed setup, black and white) hold
for SpektraLab 2 as written. "The 1.x app" below describes `modern_UI/Spektrafilm`, whose sources
are no longer in the tree: its `Tools/`, `Session`, `SpektrafilmTests` and canvas log are history,
kept because the traps cite them. The Mac app's build is in `AGENTS.md`, "Build and test"; its
self-tests are `app/SpektraLab/tools/*_selftest*`.

## Environment

**No virtualenv, and no Python, for anything this repository builds.** Xcode
26 with its Metal toolchain, macOS 15+, Apple silicon. The Mac app's three
commands are in `AGENTS.md`, "Build and test".

A `python3` is used only by the generators (`app/SpektraLab/gen_project.py`,
`tools/gen_catalog.py` beside it; `Tools/gen-project.py` and `gen-catalog.py`
in 1.x), which are standard-library-only.

**The Python reference lives in a checkout of spektrafilm** (the upstream
project, https://github.com/andreavolpato/spektrafilm, or a fork of it), outside
this repository. The parity harnesses and
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
export REF=/path/to/spektrafilm                          # the Python reference
export PYTHONPATH="$REF/src:engine/tests"
"$REF/.venv/bin/python" engine/tests/parity_setup.py     # constants
"$REF/.venv/bin/python" engine/tests/parity_schema.py    # the wire
"$REF/.venv/bin/python" engine/tests/parity_render.py    # the picture
"$REF/.venv/bin/python" engine/tests/parity_session.py   # every field, live
"$REF/.venv/bin/python" engine/tests/parity_grain.py     # distributions
"$REF/.venv/bin/python" engine/tests/parity_lut.py       # the print tables, bit-exact
# and these two need nothing but this repository:
engine/build/gpu_smoke engine/resources/spektralab.metallib    # the boundary
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
SPEKTRALAB_ENGINE_RESOURCES=/path/to/SpektraLab.app/Contents/Resources/EngineResources \
    PYTHONPATH="$REF/src" "$REF/.venv/bin/python" engine/tests/parity_lut.py
```

### The 1.x app (history)

What follows is the 1.x app's (`modern_UI/Spektrafilm`). The commands no longer
run here; the lessons (test gates, generated projects, the capture harnesses'
blind spots, the open-path log) are why SpektraLab 2's tooling looks the way it
does.

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

### Black and white (2026-10-09; in every build since 1.3.3)

`engine/resources_product/` holds the product's own data: four film profiles (Tri-X 400, and since
2026-10-09 T-Max 100, Neopan 100 Acros II and HP5 Plus 400), an Ilford Multigrade IV RC paper profile, the paper's grade table and its filter-pack row (`NOTICE.md` there
says what each is built from). `engine/build.sh bundle` lays its profiles into the app's
`Resources/engine/profiles/` beside spektrafilm's, `Tools/gen-catalog.py` lists them with
`monochrome`, and the app offers them only where `FeatureFlags.blackAndWhite` is on -- **every build
since 1.3.3** (Debug only before that). There: a third film group, the film and the silver paper as a pair
(`StockCatalog.canPrint`), `grain_sublayers_active` false on a B&W film, Multigrade filter 2 sent
as the wire's neutral pack, no EDR. No lens-filter or grade control yet, and no per-film grain
amount. `engine/tests/bw_checks.py` still overlays the directory on `engine/resources/` in a
scratch folder; it needs only `build.sh dylib` and no Python reference:

```sh
python3 engine/tests/bw_checks.py
```

The one engine change for black and white is the wire field `camera_filter` (API-SPEC §15), which
shapes the picture and not the film's edge. Grain, sharpness and halation for Tri-X are still the
colour defaults (it renders RMS ~7 against the sheet's 17). The research, with what is measured and
what is assumed: `research/black-and-white-tri-x.md`, `research/black-and-white-three-more-films.md`,
`research/colour-film-granularity.md` (`/research` is ignored; these were added by hand).
Each of the four has its `kEdgeLooks` row; HP5 Plus has a 135 layout of its own (`Edge135::Ilford`).
