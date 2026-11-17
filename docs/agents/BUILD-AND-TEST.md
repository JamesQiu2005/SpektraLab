# Build, test, measure — the detail

Moved out of `AGENTS.md` on 2026-10-29, word for word. `AGENTS.md` keeps the
commands and gates most tasks need; this is the rest: the environment, the fixed
experimental setup, the parity harnesses, the app's capture and timing tools, and
black and white. Where it says "trap N", see `TRAPS.md` beside it.

**Two eras in one file.** The engine sections (parity harnesses, fixed setup, black and white) hold
for SpektraLab 2 as written. "The 1.x app" below describes `modern_UI/Spektrafilm`, whose sources
are no longer in the tree: its `Tools/`, `Session`, `SpektrafilmTests` and canvas log are history,
kept because the traps cite them. The Mac app's build is in `AGENTS.md`, "Build and test"; its
self-tests are `app/SpektraLab/tools/*_selftest*`, and its gates "The Mac app's gates" below.

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

### The Mac app's gates (`tools/gate.py`, 2026-11-15)

`app/SpektraLab/tools/gate.py` chooses and runs the tests by **component** (the owner's schema, 2026-11-14): within a
component for most changes; across components only where shared code or a contract changed; everything before a merge to
`main` and at a release. `tools/gate_components.json` is the table: its contracts (the engine wire, `FrameEdit`, `FilmParams`, the
persisted formats, the agent table), its shared code (`Model/` core, `DesignSystem`, `Diagnostics`, `HostCut`,
`AppSettings`), and 12 components, each with its paths, its in-app checks and the components it depends on.
`tools/selftests.json` lists the 55 self-tests (`tools/selftest.sh` runs them all through `gate.py selftest`).

```bash
cd app/SpektraLab
python3 tools/gate.py change [--changed REF] [--plan] [--dependents]   # before a commit (REF defaults to main)
python3 tools/gate.py full     # before a merge to main, by hand on the Mac mini (the nightly is paused)
python3 tools/gate.py release  # at a GitHub release: full, every check's --self-test, then the timing rows
python3 tools/gate.py timing   # the cost and transition rows alone; graded only at load ≤ cores/4
python3 tools/gate.py self-test   # the gate's own rules; run after editing either table
python3 tools/gate.py sweep    # the empty defaults suites past self-test runs left in ~/Library/Preferences
```

- **`change`** runs the self-tests whose compile list reaches a changed file (what each one actually compiled, recorded
  by the `tools/gate/swiftc` shim, not a second list kept by hand), and the in-app checks of the components that own the
  changed files. A change to a contract or shared code runs every component's checks; `--dependents` also runs the
  components that depend on the touched ones (nearly all of them, which is why it is not the default). A changed file
  nothing owns and no self-test reads **falls up to the whole suite**, and says so. `--plan` prints what would run and
  why, and runs nothing.
- **A check's parts.** A check with `parts` in the table has each part left out (`--skip`) when the change reaches none
  of its paths: `masks_check.sh --function` skips the finding (`SubjectFinder`, `MaskFinding`, `FoundMaskKeeping`,
  the case itself) and the flat frame (the overlay's geometry: `MaskOverlay`, `MaskLive`, `MaskBaker`, `MaskFrame`). The
  report says `SKIPPED <part>`; a contract, shared code or the gate's own files skip nothing, and `full` runs every part.
  Measured on the Mac mini (2026-11-15, load ~2): the whole check **1,094 s**, `--function` **714–755 s**,
  `--function --skip find,flat` **453 s**; the `panel` and `find-join` mutants are caught in function mode (240 s). The
  45 MP develop and Vision on it are most of what is left, so the plan's 5 minutes is not met by the split alone.
- **Builds are cached** by the compiler's version, the arguments and the contents of every input
  (`build/gate-cache/`), built `-Onone` (`tools/gate/keep-O.txt` keeps `-O` where a run asserts time or decodes RAWs:
  `lens_profile_selftest` at `-Onone` ran 47 min), eight at once. Measured on the Mac mini (M6, 2026-11-15, load 3–9):
  `selftest.sh` cold **116 s** and warm **56 s** (54 of 55 builds from the cache), against **965 s** on `main`'s
  serial script.
- **Timing is its own gate.** The cost and transition rows run in `gate.py timing` and the release only: `--function`
  and `full` (`masks_check.sh --untimed`) leave them out, so another session's load cannot turn a function gate red.
  `timing` refuses to grade above load cores/4 and says so (exit 3, never a pass).
- **Exit 3 is "incomplete", never a pass**: `tools/gate/engine_check.sh` without the Python reference
  (`SPEKTRALAB_REFERENCE_ROOT`) reports it, and the summary says the tier is incomplete.
- **A silent check is killed** with its process group (the app, its watcher and the watcher's `tail -F`): 600 s by
  default, a check's own `quiet` in the table. Every check script makes `--out` absolute, and the app refuses a relative
  folder aloud (`MacCheckFolder`).
- **Read the summary line.** It prints the scope, what ran and why, and the time; a commit records it (trap 26: a short
  run where a long one was due is a skip, and is seen).

**What a run needs that no checkout has.** The fixtures are gitignored and found from the main checkout: the 45 MP set
`research/natural_shadow/dataset` (the masks, layers and finished-layers checks) and `RAW_decode_tests`
(`lens_profile_selftest`, `raw_samples_check`, `lens_check`), both skipped and said without them; and the Python
reference for `engine_check.sh` (`SPEKTRALAB_REFERENCE_ROOT`). The in-app checks run the Debug app at
`build/DerivedData` (build it first: a stale build tests stale code), in a logged-in GUI session.

**Before a merge to `main`: `gate.py full` by hand** on the Mac mini, in its main checkout or a worktree with the RAW sets
reachable (above), after building the engine and the Debug app, in a logged-in session; record its summary line in the
merge's message. This replaces the nightly while it is paused (the owner, 2026-11-15): merges are rare and made by hand,
so the whole suite runs before a change lands rather than the morning after.

**The nightly: paused** (`gh workflow disable Nightly`, 2026-11-15; `gh workflow enable Nightly` brings it back). Its one
run (43715853541) was killed in the Debug build by the runner's 6 GB cap and left the runner unable to restart (below).
Bring it back only with both fixed, or as a plain launchd job on the Mac mini outside the runner's supervisor. As written,
`.github/workflows/nightly.yml` runs `gate.py full` on the private repository's
self-hosted runner at 02:00 Shanghai time, never in the public repository or a fork (its `if:`: the release copies
this tree into the public one, which must never schedule work on a private runner). It links the RAW sets
in from `SPEKTRALAB_FIXTURES_ROOT` (a repository variable: the Mac mini's main checkout), builds the engine and the Debug app, and
uploads the gate's log and the checks' logs.

**What the runner needs before the nightly can pass** (found 2026-11-15 by running a check from a LaunchAgent with the
runner's own properties, through `~/runner-control/supervisor.py`'s `monitor()`; no workflow was run). A process started
by launchd answers to macOS's privacy rules as itself, not as a Terminal that was granted them:
- **Files on a removable volume.** The app blocked in `open()` writing its `report.json` to the worktree on
  an external volume (a `sample` of the main thread), waiting on a consent prompt nobody answered, and the check's
  silence watchdog killed it (exit 143): `edit_refresh_check` 137 s instead of 13. The runner's work folder
  is on an external volume too. The same with `SessionCreate` off and with the limits lifted.
- **Automation of System Events** (`front()`): from the agent, `osascript` timed out (-1712), a prompt again.
- **Posting events** (`post_keys`, `post_pointer`): `CGPreflightPostEventAccess` is false there (and in a Claude Code
  shell, where the keys landed in 3 of 4 runs all the same: one run's twelve were lost, a flake the case does not yet
  tell from a fault).
- **The supervisor's limits**: a job's whole tree is held to 4 cores by SIGSTOP and killed past 6 GB of RSS. **The RAM
  cap cannot hold the nightly**, measured on the 16 GB Mac mini: a clean Debug build peaks 6.43 GB at `-jobs 4` (the run
  was killed at 6.01 GB with xcodebuild's default of one job a core), 4.21 GB at `-jobs 2`, 3.39 GB at `-jobs 1`; a cold
  `selftest.sh` 9.1-9.6 GB at 8 or 4 at once; `raw_samples_check` alone 10.85 GB and `lens_profile_selftest` alone
  6.10 GB. The in-app checks are smaller (2.9 GB the whole masks check, the app counted as the check's child; 0.5 GB
  edit_refresh). The 4-core hold is why the nightly grades no timing row.
- **The supervisor is Xcode's Python** (`com.apple.python3`, what `/usr/bin/python3` hands off to), so a privacy grant to
  `/usr/bin/python3` (Full Disk Access since 2026-10-10) does not reach it. After the run's kill, every restart failed
  `runsvc.sh: Operation not permitted` on the external volume, probably because the simulation above raised that
  identity's removable-volume prompt and it was refused. The fix is at the screen: Full Disk Access for Xcode's
  `Python.app`. **Never run a privacy experiment as the runner's own identity**: a refused prompt is the runner's.

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
