# AGENTS.md — working notes for AI sessions on SpektraLab

The macOS product SpektraLab, built on the **spektrafilm** engine. **Current as of
1.3.5 (20), `main` 02d82b56, 2026-11-02.** This file holds conventions and the
traps that cost real debugging time. `README.md` is the map; `ARCHITECTURE.md`
§0 (the map), §7 (the app: §7.7 surfaces, §7.8 export) and §8 (the engine) are
the detail. Read trap 26 before trusting any green run, trap 33 before trusting
any green surface.

Trap **numbers are cited across the code** (`engine/`, `desktop/`, tests,
`ARCHITECTURE.md`). Never renumber them; add new ones at the end.

---

## What this repo is

> 不要为了修 rendering problem 去污染 material model。
>
> **Do not pollute the material model to fix a rendering problem.** A film or
> paper profile describes measured capability, not a control surface. Scene
> placement belongs before the film, output headroom after the print, the final
> look in Layer 2. Fix the stage that owns the decision.

- **One binary.** `modern_UI/Spektrafilm/` is a SwiftUI/AppKit app with the C++20
  engine (`engine/`) compiled in, reached through a hand-written `extern "C"`
  surface, rendering into an `MTLTexture` the canvas draws. **No Python** in the
  build or at run time, and **no CPU fallback** — a slow render is a bug, not a
  fallback (trap 18). A 45 MP full render is under a second.
- **The engine's data comes from the app bundle** (`Resources/engine`), synced by
  `engine/build.sh bundle` from the tracked `engine/resources/` (15 MB of baked
  output; re-baking needs the Python reference — README). Trap 14.
- **The product's own data** is `engine/resources_product/`: four B&W films
  (Tri-X 400, T-Max 100, Acros II, HP5 Plus) and Multigrade IV RC, laid in by
  `build.sh bundle`. B&W is on in every build since 1.3.3; no lens-filter or grade
  control yet. `python3 engine/tests/bw_checks.py` checks it (needs only
  `build.sh dylib`).
- **This is v1, in maintenance.** Fixes and small features land here; no major
  UI redesign (v2 work happens outside this repository — ask before porting it
  back). `main` is the product; experiments go in a worktree, not the main
  checkout.
- **Not the macOS product, and owned by others:** `desktop/` (Tauri),
  `windows_UI/` (Qt), `engine/host/`, `engine/src/{io,desktop}`, the Vulkan
  backend. They share the engine and cite these traps; don't change them as a
  side effect of a macOS change.
- **The wire contract is `API-SPEC-callable-render-service.md`**, cited by
  `params.cpp`, `engine.cpp`, `parity_schema.py`, `Params.swift` and the tests.
  **A wire change edits its section in the same commit.** `AGENTS.md`,
  `ARCHITECTURE.md`, `API-SPEC-*` and `CONTRACT-*` are owned by whoever changes
  what they describe (owner's decision, 2026-10-03). `CONTRACT-frontend-backend.md`
  §4's frontend/backend split is historical; its §1 (the wire) still holds.
- **The engine has no file writer.** It returns pixels and baked tables;
  `Exporter.swift` writes TIFF/JPEG/PNG, the DI, the `.cube` and the preview page
  through ImageIO (`ARCHITECTURE.md` §8.8).
- **Sidecars are not beside the photograph** (trap 35), and since 1.3.5 the
  window adopts sidecar writes made outside it (CLI, another window).
- **CLI and MCP** ride on the same binary (RFC-026); `Agent/AgentTools` is the one
  table; access is off by default in Settings.

---

## Build and test

Xcode 26.6, macOS 15+, Apple silicon (`ARCHS = arm64`).

```bash
engine/build.sh bundle          # engine + MSL kernels + baked resources into the app
engine/build.sh all             # + static lib, dylib, test drivers
engine/build.sh metallib        # kernels only, after editing a .metal
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py    # after adding/removing ANY .swift or engine .cpp
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
    -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
    -configuration Debug -derivedDataPath build/DerivedData test
```

- The bundle step is not optional: the pre-build phase
  (`Tools/check-bundle-resources.sh`) fails without the engine resources and the
  licence texts (`Tools/bundle-licenses.sh`). The licences are an obligation
  (CC BY-SA profiles, GPL binaries), pinned by `LicensingTests`.
- `project.pbxproj` is **generated**; ids hash the path relative to the project,
  so checkouts and worktrees generate identical bytes. A Swift file missing from
  it reads as `cannot find X in scope`; a missing `.cpp` as a link error.
- The test target is standalone (no TEST_HOST) and compiles the app's and the
  engine's sources. At 1.3.5: **573 tests, 2 skipped, 0 failures**, several
  minutes. Under a minute means the fixtures are missing (trap 26).
- "Xcode cannot spawn metal": clean the build folder; never symlink the cryptex.
- A stale test binary reports a stale result; if a failure looks impossible, run
  it once more before investigating.

### Test gates

- While working: build, then `-only-testing:SpektrafilmTests/<Class>` for what
  covers the change. Show a new regression test **red** on the old behaviour
  before green.
- Before a push or at an integration boundary: the full `SpektrafilmTests` once.
- Engine parity harnesses only when engine inputs, kernels, resources or the
  render boundary changed.
- The commit message records the gate that ran.

### Engine parity harnesses

They need the Python reference in the `spektrafilm` fork
(`~/Documents/Summer 2026/spektrafilm`) and drive this repo's dylib through
ctypes. `build.sh dylib` does **not** rebuild `dump_json`/`dump_setup`/`gpu_smoke`
— run `build.sh all` first or three harnesses grade a stale engine green.

```bash
export REF=~/Documents/Summer\ 2026/spektrafilm
export SPEKTRAFILM_REFERENCE_ROOT="$REF"         # parity_lut needs this, not REF
export PYTHONPATH="$REF/src:engine/tests"
for h in setup schema render session grain lut; do
  "$REF/.venv/bin/python" engine/tests/parity_$h.py; done
engine/build/gpu_smoke engine/resources/spektrafilm.metallib   # pure C++
engine/tests/check_math_guard.sh                               # the guard fires
```

`parity_render.py --size 180` runs in seconds; default is the 1 MP frame.
`ARCHITECTURE.md` §8.6 says what each holds and why the bars are where they are.
To test what shipped, point `SPEKTRAFILM_ENGINE_RESOURCES` at a built `.app`'s
`Contents/Resources/Resources/engine` (`bundle` is an rsync and can leave a
stale bundle).

### Fixed experimental setup

| | |
|---|---|
| film / print | `kodak_portra_400` / `kodak_portra_endura` |
| smoke image | `tests/Test_image/_smoke_1mp.tif` |
| 45 MP frame | `tests/Test_image/Nikon Z7ii/_DSC2439.NEF` |
| 24 MP RAW | `tests/Test_image/A7m3/DSC03710.ARW` |
| precision | float32; grain sampler `exact` |

---

## Seeing and timing the app

```bash
Tools/snapshot.sh [image]            # offscreen; cannot see a CAMetalLayer
Tools/capture-live.sh [image]        # the real window; force-quits running SpektraLab
SPEKTRAFILM_CANVAS_LOG=1 …           # one line per draw + open-path timings
```

`Session.LoadClock` prints the open path
(`decode · preview-texture · linear-tiff · service.open · solve · reprint · TOTAL
· core=native-metal`) and `full render <w>x<h> landed in <n> ms`. **Check
`core=native-metal` first**; do not delete the instrument. A missing `landed`
line means the result was dropped (generation, selection or session moved).

Three harnesses, three blind spots: `--snapshot` cannot see the Metal layer
(it hid a launch crash and a blank canvas); an in-process test cannot see a
stall (no display link — a 113 ms dead animation measured 175 ms in-process);
only `capture-live.sh` in a live GUI session shows what the user sees. A starved
main thread shows in the canvas log as a gap in the draw lines.

`screenshots/` is the app as it renders, captured from the running app. The
README captures (`Screenshot_English.png`, `Screenshot_ZH_HANS.png`) are the
owner's — ask before replacing them; never resample the 1:1 grain capture.

---

## Releasing

Releases are **Developer ID–signed, notarised DMGs** built by `Tools/package.sh`
(the 0.3.1–1.3.2 ad-hoc zips are history), run from `modern_UI/Spektrafilm` with
`SPEKTRAFILM_SIGN_IDENTITY`, `SPEKTRAFILM_TEAM_ID` and
`SPEKTRAFILM_NOTARY_PROFILE` set (the owner's identity and keychain profile; do
not inspect the keychain).

- `package.sh` writes the identity into the pbxproj: re-run `gen-project.py` with
  no env afterwards so the committed project stays ad-hoc.
- The version lives only in `Tools/gen-project.py`. The bump is its own last
  commit, `chore(release): X.Y.Z (N)`; a fix that is not a release does not bump.
- **Tested tree == tagged tree**: record `git write-tree` before the suite and
  compare with `HEAD^{tree}` after. Download the published asset and hash it.
- Tags are `spektralab-vX.Y.Z`. `git tag --list | tail -1` returns upstream's
  `v0.3.3`; `gh release` needs `--repo JamesQiu2005/SpektraLab`.
- Leave the `windows-prerelease` markers in the release body alone (a CI job
  fills them).
- Publish only on the owner's go.

---

## Traps

Traps 1–13 come from the Python/MLX engine that stayed upstream. Their commands
do not run here; the C++ port still carries each lesson, and code cites them.

1. **Glare is unseeded; grain is seeded.** Any per-pixel comparison disables both
   (`debug.deactivate_stochastic_effects`). Run the same config twice before
   concluding a change broke something.
2. **Measured profiles contain NaN** (no-data wavelengths). The reference zeroes
   them in `density_to_light`; any replacement must too, by sanitising constants.
3. **Fast math deletes NaN checks.** Sanitise outside the kernel, never with an
   in-loop `isnan` branch. (Hence `-fmetal-math-mode=safe`, below.)
4. **Chunks must outnumber workers**, or concurrency re-multiplies the memory
   chunking divided (12/12 → 6.86 GB, 64/12 → 1.64 GB).
5. **Evaluate at node boundaries.** A lazy graph retains every intermediate; the
   C++ pipeline flushes per node for the same reason (and trap 19).
6. **float16 is not free**: the `1e-10` log epsilon underflows to 0, and it was
   not faster. float32.
7. **colour-science promotes to float64**, and a same-space `RGB_to_RGB` also
   applies a near-identity CAT02 (3.8e-4). Do not swap it for `cctf_encoding`.
8. **Matching RMS is not matching a distribution.** Check skewness (the third
   moment) before calling a noise model equivalent.
9. **Grain draws are i.i.d.**: chunking them makes no seam. Only the blurs need
   halos.
10. **A hidden full-resolution downscale cost 7.1 s at 45 MP.** Profile sub-steps
    before calling a stage GPU-bound.
11. **A uniformly biased suite reports full confidence.** Three colour bugs lived
    under 750 green tests because every input was linear. Ask what a test's
    inputs have in common; test invariances (RFC-010).
12. **The input contract is where the product breaks.** Decode at the door;
    an external developer's exposure is not a gain under a tone curve; external
    decodes are not invertible.
13. **Spectral upsampling has a purple blind spot** (1.7–3.8 dE round trip, worst
    in violet). Structural; do not loosen its bounds without looking at colours.
14. **The engine renders whichever *data* the app resolved.** Bundle first, then
    `SPEKTRAFILM_ENGINE_RESOURCES`, then a checkout above the build — the last one
    can lie. The silent case is *stale*, not absent. `EngineResourceOriginTests`.
15. **A refactor that only moves code can move the wire.** Print the capabilities
    block and diff it against what the Swift type requires; both sides pin the
    key set.
16. **A guard that can never fire.** Its only exercise is in a configuration that
    disables what it guards. Verify a check can fail before trusting it green.
17. **This machine is not a benchmark.** Check `uptime` and
    `ps -Ao %cpu,comm -r | head`, measure interleaved (A/B/A), say so with the
    number. Memory is `footprint -p <pid>`, not RSS (RSS cannot see the Metal pool).
18. **A slow render is not a fallback.** Three measured causes: an arena that did
    not reuse within a render (`gpu::BufferRef` now), unported setup caches
    (`core/setup_cache.hpp`), full-frame copies on the open path. Check
    `core=native-metal`, time the tiers, watch the pool across repeated renders.
19. **Free is not idle.** A freed buffer is reusable only at `flush`; reusing it
    inside an open command buffer made 25 of 27 parity cases wrong, silently.
20. **The kernels disagree about matrix orientation.** `spk_tc_b` and
    `spk_cam16ucs_compress` take row-major M; `spk_matmul3` and
    `spk_cctf_encode_matrix` take it transposed. Use `row_major()`/`transposed()`.
21. **The print balance evaluates its grey in sRGB**, whatever the input space —
    reproduced on purpose as `kMidgrayProbeColourSpace`.
22. **Two wire parameters do not mean what the schema says.** `lens_blur_um` does
    nothing on the Python engine (the C++ port diverges on purpose;
    `parity_render.py` fails if they agree). `dir_couplers_amount` above ≈1.736 is
    non-monotonic, though the wire allows 4.0.
23. **A green parity suite is not a correct picture.** A vertical flip and an
    arena-owned result texture passed every harness. Look at a capture.
24. **A test does not own `UserDefaults.standard`.** Values leak between classes
    and from `defaults write`, and the failure names the wrong file. Inject a
    throwaway suite (`Session.previewEdge(in:)`, `PanelWidthStore`); don't read
    the shared store.
25. **An `@Observable` `didSet` that assigns itself recurses** (SIGSEGV in xctest).
    Safe only at a fixed point; otherwise a computed property over a private
    stored one. `Renderer.comparePosition` is safe only because `Renderer` is not
    `@Observable`.
26. **A skipping suite and a full suite both report `0 failures`.** Fixtures come
    through an ignored `tests` symlink: the main checkout → `../spektrafilm/tests`,
    a worktree → the main checkout's `tests`. Without it ~25 cases skip in ~20 s.
    **Read the duration and the skip count, not the failure count.** Never commit
    the link.
27. **Every UI literal painted into the drawable is in the working space**
    (ProPhoto γ1.8 since RFC-018), not sRGB. The window margin and the canvas
    letterbox must read the same grey in a live capture (95 / 95.03).
28. **A harness that keeps its own copy of a convention goes red for no reason.**
    Ask the open reply (`params.io`) for the output space. `parity_schema` carries
    a named `KNOWN` divergence for the oracle's sRGB default.
29. **`kCGImageDestinationEmbedThumbnail` does nothing for TIFF.** The preview is a
    second page, read by index (`CGImageSourceCreateImageAtIndex(src, 1, nil)`);
    the thumbnail API returns a downscale of page 0 instead.
30. **Exp. Comp. moves the negative, not the print.** The enlarger re-times the
    print, so mid-grey holds and contrast changes. `enlarger.print_exposure` moves
    brightness; pre-multiply the input for a brightness control in an experiment.
31. **Colour dies in the toe before tone does**: below ≈ −3.5 EV everything prints
    as grey. Colour window ≈ 4.3 stops against 5.66 of tone on Portra/Endura.
32. **AppKit offers a key to the menu before the focused text field**, so a
    modifier-free ← in a rename switched photographs. `Windows/TypingKeyGuard.swift`
    fixes it; `TypingKeyGuardTests` has the control.
33. **A green unit is not a correct surface.** Every surface that shows the frame
    must show the canvas's frame: test it with a crop *and* a quarter turn in
    `SurfaceAgreementTests`. The histogram still counts the uncropped print
    (pinned with `XCTExpectFailure(strict: true)`).
34. **The exporter writes whatever frame is open.** `Session.batchExporting` holds
    the selection during a batch; anything new that changes the open frame on a
    person's behalf must check it (`select` itself must not).
35. **Sidecars are not beside the photograph.** They live in
    `~/Library/Application Support/SpektraLab/Sidecars/<file>-<sha256(path)[:16]>.spektra.json`
    with a fingerprint for moved files; `<image>.spektra.json` is the old home,
    migrated on first read. **A develop writes a sidecar**, so a test copies its
    fixture before opening it.

---

## Conventions

- **Match the file you are in.** Comments explain *why* and record what was
  measured. Swift: `@Observable` + `@MainActor` for model state, actors for
  shared state (`EngineClient`, `DiskCacheStore`, `PrintWriteback`). C++20,
  `noexcept` at the ABI.
- **Anything that shows the frame** gets a `SurfaceAgreementTests` case (33);
  anything that changes the open frame checks `batchExporting` (34).
- **A test owns its inputs**: injected `UserDefaults` (24), copied fixtures (35).
- **Measure, then claim**: a speed or memory claim comes with its measurement,
  interleaved, in the same message (17). "Wired" is not "visible": a NotEqual
  test proves wiring; measure the top of a slider's range.
- **UI text never truncates** — no "…", no overflow; never `.fixedSize()` a
  message. Enum display titles stay English (pinned by tests); localise through
  the `key` mapping.
- **`screenshots/` must match the interface**; say so in the commit when it moves.

## Do not

- Commit, push, tag or publish unless asked.
- Restore `tests/baseline/` (Python-era, gone for good).
- Delete `Session.LoadClock` or the `core=native-metal` line.
- Remove the per-node `flush` in `SPK_NODE` or the one between `Blur::mixture`
  components (trap 19).
- Drop `-fmetal-math-mode=safe` / `-fmetal-math-fp32-functions=precise` from
  `engine/build.sh`, or move the kernels into the Xcode target (which compiles
  with fast math). `spk_math_probe` refusing to start is the intended outcome.
- "Fix" `kMidgrayProbeColourSpace` without reading trap 21.
- Tighten the render-parity bar to float32 epsilon; it is 3e-5 for a reason
  (`ARCHITECTURE.md` §8.6).
- Change the spectral shape (81 × 5 nm), the profile data or the log-exposure
  axis.
- Add GPL-incompatible dependencies. Code is GPL-3.0-or-later; profiles under
  `engine/resources/profiles/` are CC BY-SA 4.0.
- Rename the engine, profiles or LUTs away from spektrafilm (the licence requires
  the split), or the Xcode target/scheme `Spektrafilm`.
- Remove the histogram case's `XCTExpectFailure(strict: true)` except in the
  commit that fixes the histogram (trap 33).
