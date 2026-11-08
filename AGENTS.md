# AGENTS.md — working notes for AI sessions on SpektraLab

> **SpektraLab 2 is the Mac app in `app/SpektraLab`**: a Mac Catalyst app (SwiftUI and UIKit, with
> AppKit reached through the Objective-C runtime where Catalyst has no API of its own: the scroll
> wheel, the open and save panels) on this repository's engine, **the SpektraLab engine**
> (`engine/`). The 1.x app (`modern_UI/Spektrafilm`, SwiftUI + AppKit) is history: its sources
> are no longer in the tree, and `modern_UI/` keeps only the assets other platforms read
> (`modern_UI/README.md`). Where a document describes `modern_UI/Spektrafilm`,
> `Session`, `Tools/*.py` or `SpektrafilmTests` as the app, it describes 1.x.

The SpektraLab engine is a C++/Metal implementation derived from spektrafilm by Andrea Volpato
(GPL-3.0-or-later); the app is built around it. This file is the rules most tasks need; the detail
lives beside it:

- `docs/agents/TRAPS.md` — the 35 traps in full (indexed below by the numbers the code cites).
- `docs/agents/BUILD-AND-TEST.md` — environment, fixed experimental setup, parity harnesses,
  the 1.x app's capture/snapshot tools and open-path timing log, black and white.
- `app/SpektraLab/` — the app's own notes beside its sources (`ENGINE-WIRING.md`, `PAGES.md`,
  `PAIR-WIRING.md`, `MAC-LIBRARY-DATA.md`, `LOCALIZATION.md`) and its self-tests (`tools/*_selftest*`).
- `ARCHITECTURE.md` §0 (the map), §7 (the Mac app; §7.7 surfaces that show the frame, §7.8 export),
  §8 (the engine), Appendix A (the 1.x app, which `desktop/` cites as §7.x). Read trap 26 before trusting
  any green run, trap 33 before any green surface.

---

## What this repo is

> 不要为了修 rendering problem 去污染 material model。
>
> **Do not pollute the material model to fix a rendering problem.** A film or
> paper profile describes measured capability, not a control surface. Scene
> placement belongs before the film, output headroom belongs after the print,
> and the final look belongs in Layer 2. Fix the stage that owns the decision;
> never rewrite a measured response to hide a limitation in another stage.

- **One binary, no Python.** A C++/Metal engine (`engine/`) is compiled into the app behind a
  hand-written `extern "C"` surface. No CPU fallback exists: a slow render is never "falling back"
  (trap 18). A 45 MP full render is ~0.87 s.
- **The Python reference is not here.** The fork's `src/` is the oracle for `engine/tests/parity_*.py`
  and the only thing that can re-bake `engine/resources/` (tracked, so builds never need it).
  Both take an explicit `PYTHONPATH` — `docs/agents/BUILD-AND-TEST.md`.
- **The engine's data comes from the app bundle** (trap 14); `build_engine_mac.sh` lays it into
  `EngineResources/`, which the build copies into the app. A build that did not rerun it carries
  the previous resources, not none.
- **The wire contract is live.** `API-SPEC-callable-render-service.md` is cited by `params.cpp`,
  `engine.cpp`, `parity_schema.py`, `Params.swift` and the tests: **a wire change edits its section
  in the same commit.** `CONTRACT-frontend-backend.md` §1 (the wire) still holds; its §4 split is history.
- **Half the product is an interface.** `screenshots/` is the app as it renders, from the running app.
  Look at it before changing the canvas or the rails.

## Build and test

```bash
# the Mac app (what CI builds, .github/workflows/build.yml)
app/SpektraLab/tools/build_engine_mac.sh       # the engine for Mac Catalyst + its resources
cd app/SpektraLab && python3 gen_project.py    # the Xcode project, generated from the tree
xcodebuild -project SpektraLab.xcodeproj -scheme SpektraLab -configuration Debug \
    -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/DerivedData build

# the engine on its own (dylib for the parity harnesses, test drivers)
engine/build.sh all          # spektralab.metallib + static lib + libspektralab_engine.dylib + test drivers + bundle
engine/build.sh metallib     # just the kernels (after editing a .metal)
engine/build.sh bundle       # sync resources into modern_UI/…/Resources/engine (read by desktop/ scripts, engine/stage-host.sh)
```

`build_engine_mac.sh` compiles `engine/` exactly as `engine/build.sh` does (the same sources, `-O2`,
safe-math kernels for macOS 15) for the Mac Catalyst target, because a Catalyst app cannot link a
plain macOS object; it leaves `build/engine-macosx/{libspektralab_engine.a, EngineResources/}`, which
`gen_project.py` links and copies into the app. Build Release as well as Debug before calling a change
done: a release path that reaches code under `#if DEBUG` compiles in Debug and fails in Release.

- **Regenerate the project after adding or removing a Swift file**, and rerun `build_engine_mac.sh`
  after adding an engine `.cpp` (it globs `engine/src/{core,gpu,pipeline}`). A missing Swift file
  reads as `cannot find X in scope`; a stale engine library as a link error.
- **Test gates.** While working: build the affected target and run only the covering tests; show a new
  regression test red before green. Before a push or at an integration boundary: the full suite once.
  Engine parity harnesses only when engine inputs, kernels, resources or the render boundary changed.
  A commit records the gate that ran.
- **Read the duration, not the failure count.** A full run with fixtures takes minutes; under a minute
  means the fixture cases skipped (trap 26). A stale test binary can report a stale result — rerun
  once before investigating an impossible failure.
- **Look at the running app.** A green parity suite is not a correct picture (trap 23), a green unit not
  a correct surface (trap 33), and offscreen snapshots cannot see a `CAMetalLayer`.

## Trap index

Full text in `docs/agents/TRAPS.md`. 1–13 are the upstream Python/MLX engine's (history).

1. The pipeline is nondeterministic by default — glare is unseeded; disable it and grain to compare.
2. Measured profiles contain NaN — neutralise at build time, as the reference does.
3. `fastmath=True` deletes NaN checks — sanitise constants outside the loop.
4. Chunks must outnumber workers.
5. MLX is lazily evaluated — `mx.eval()` barriers at node boundaries.
6. float16 is not free — epsilon underflow, no speed gain; use float32.
7. colour-science silently promotes to float64.
8. Matching RMS can still change the look — check skewness.
9. Grain draws are i.i.d. — chunking them makes no seam; blurs need halos.
10. `skimage.transform.rescale` was a hidden 7 s at 45 MP — profile sub-steps.
11. Colour bugs are silent; a uniformly biased suite reports full confidence.
12. The input contract is where the product breaks — scene-linear in, decode at the door.
13. Spectral upsampling has a structural blind spot in purple.
14. The engine renders whichever *data* the app resolved — bundle first; stale, not absent.
15. A refactor that only moves code can still move the wire.
16. A check that exists on paper, in a configuration where it can never fire.
17. This machine is not a benchmark — check load, measure interleaved.
18. A slow render is not a fallback — arena reuse, setup caches, open-path copies.
19. Free is not idle — a freed buffer is reusable only after `flush`.
20. The transferred kernels disagree about matrix orientation — `row_major()` / `transposed()`.
21. The print balance evaluates its grey in sRGB — deliberate (`kMidgrayProbeColourSpace`).
22. Two wire parameters do not mean what the schema says (`lens_blur_um`, `dir_couplers_amount`).
23. A green parity suite is not a correct picture.
24. A test does not own `UserDefaults.standard` — inject a suite.
25. An `@Observable` `didSet` that writes to itself recurses.
26. A skipping suite and a full suite both report `0 failures`.
27. Every UI literal that reaches the drawable is in the working space.
28. A harness that keeps its own copy of a convention goes red for a change no node made.
29. `kCGImageDestinationEmbedThumbnail` does nothing for TIFF — read page 1 by index.
30. `exposure_compensation_ev` moves the negative and not the print.
31. Colour dies in the toe long before tone does.
32. AppKit offers a key to the menu before the focused text field.
33. A green unit is not a correct surface — `SurfaceAgreementTests`.
34. The exporter writes whatever frame is open — check `batchExporting`.
35. Sidecars are not beside the photograph.

---

## Conventions

- **Match the file you are in.** Comments here explain *why* and record what
  was measured; keep that density. Swift is `@Observable` + `@MainActor` for
  model state, actors for anything shared across threads (`EngineClient`,
  `DiskCacheStore`, `PrintWriteback`). C++ is C++20, `noexcept` at the ABI.
- **Run `python3 gen_project.py` (in `app/SpektraLab`) after adding or removing a Swift file**, and
  `tools/build_engine_mac.sh` after adding an engine `.cpp`. A missing Swift file reads as
  `cannot find X in scope`; a stale engine library as a link error. (In 1.x both were
  `Tools/gen-project.py`.)
- **Test gates** (see "Build and test" above): the narrowest self-tests while working, the full set
  before a push. Record the gate in the commit message. Show a new regression test red before green.
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
  (`Screenshot_v2.png`, the 2.2.0 Develop page, shown by both READMEs) —
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
- Do not restore `tests/baseline/`. See "Fixed experimental setup" in `docs/agents/BUILD-AND-TEST.md`.
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
