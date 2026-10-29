<!-- Historical milestone record; the 2026-10-29 PR23 integration supersedes pending CineStill and DI bypass descriptions. See desktop/docs/PR23-INTEGRATION-20261029.md. -->
# Windows film migration: audited implementation plan

Date: 2026-10-28. This document records the source audit, implementation progress and bounded validation evidence. **noFilm is implemented, with the Windows GUI/export/restart checks listed below completed on RTX 5070 Ti. Remaining GUI cases, other GPUs, Mac visual comparison and a complete release are not accepted. CineStill 800T is still proposed work.**

## Baselines and scope

- Windows checkout: `evanfan005-bit/SpektraLab-Windows`, `Windows_Linux`, baseline `aed5fd9a286bdcbdedde6aaa162a49a92f6c096d` plus the current uncommitted frontend, Agent and native noFilm changes. The baseline hash is not an implementation commit.
- macOS reference retained in this checkout: `main`, `fd891c6bc5eb350387602deb5c1ef9b6dcdab948`.
- Input checklist: `MACOS-MAIN-ALIGNMENT-CHECKLIST-20261028.md` in the previous checkout's `desktop/` directory. Its Windows baseline `751ca6b` predates this personal fork; assess each item against the current code.
- Scope here: the checklist's P1 **Don't Apply Film Simulation** and **CineStill 800T** items. They are two independent end-to-end milestones after parameter preservation and numeric-input correctness.
- Both features are absent from the clean Windows baseline. The current worktree now implements milestone A across the view/export/proof boundary; milestone B remains unimplemented.

The architecture differs: macOS grades textures inside its app; Windows grades, frames and converts output in the native host through `spk::view::render`, then presents its result in the webview. Port the behavior through that existing boundary.

## Milestone A: Don't Apply Film Simulation

### Source and behavior

Source commit: [`fd891c6`](https://github.com/JamesQiu2005/SpektraLab/commit/fd891c6bc5eb350387602deb5c1ef9b6dcdab948), `feat(film): "Don't Apply Film Simulation" in the Film section's menu`.

Reference files under `modern_UI/Spektrafilm/`:

| File | Relevant responsibility |
| --- | --- |
| `Spektrafilm/Model/Sidecar.swift` | Per-frame `noFilm`, default false, encode only when true |
| `Spektrafilm/Model/Session.swift` | Toggle, undo/save, source selection and thumbnail refresh |
| `Spektrafilm/Model/Session+FilmEdge.swift` | Photo-sized canvas and normal geometry when simulation is bypassed |
| `Spektrafilm/Model/SettingsClipboard.swift` | Exclude this per-frame choice from copied settings |
| `Spektrafilm/Canvas/Renderer.swift` | Grade the original decode instead of the film print |
| `Spektrafilm/Export/Exporter.swift` | Native-resolution decoded pixels, then normal post-develop/output processing |
| `Spektrafilm/Panels/Sections/FilmSection.swift` | Menu toggle; disabled for a half-frame pair; selecting a film restores simulation |
| `SpektrafilmTests/FilmEdgeSessionTests.swift` | Saved flag and film-edge geometry regression cases |

Acceptance behavior: retain film/paper settings while bypassed; preserve post-develop adjustments and crop; ignore film edge/date appearance while showing the photo at its own size; restore simulation when a film is selected. Half-frame pairs cannot enable this mode. Dedicated Digital Intermediate (DI/Cineon) exports retain their existing negative semantics.

### Windows implementation boundary — implemented in this worktree

| Windows file/module | Current implementation |
| --- | --- |
| `desktop/src/shared/sidecar.ts` | Model/decode/encode `noFilm`; preserve it through read/write and external updates |
| `desktop/src/state/session.ts` | Toggle, undo/redo, save/reopen, selection and request generations, cache descriptors, displayed dimensions and thumbnails |
| `desktop/src/panels/LeftRail.tsx` | Film menu, half-frame restriction and film-selection behavior |
| `desktop/src/shared/filmEdge.ts`, `desktop/src/canvas/Canvas.tsx` | Use the photo's crop/rotation and native logical size under bypass, including when film/date parameters remain enabled |
| `desktop/src/shared/clipboard.ts` and consumers | The per-frame choice remains outside copied parameter groups; regression coverage verifies this boundary |
| `desktop/src/host/client.ts`, `desktop/src/shared/protocol.ts` | Carry `no_film: true` in immutable view/export/proof requests; `hello.view_options` advertises support. Ordinary saved bypass is refused when capability is absent |
| `desktop/src/export/exporter.ts`, `desktop/src/export/ExportPage.tsx` | Freeze selected/background bypass plus separate ordinary and DI geometries; preserve negative semantics for Cineon and its proof, even on a host without bypass support |
| `desktop/agent/workspace.ts` | Read saved mode in develop/preview/export, enforce capability/pair restrictions, keep it for unrelated edits and clear it when selecting a film; DI prepares the film view independently |
| `engine/host/main.cpp`, `engine/src/pipeline/view.hpp` | Validate and carry the request; enforce pair restriction at the host boundary as well as in the UI |
| `engine/src/pipeline/engine.cpp`, `engine/src/pipeline/view_process.cpp` | Select decoded source for non-Cineon rendering, then reuse Layer 2, geometry, target colour conversion and proof processing |

The existing `render_source` remains an unadjusted 8-bit sRGB/P3 comparison preview. The new native branch starts with the resident linear ProPhoto source, encodes working RGB as float32, and enters the shared Layer 2, geometry, target conversion and proof chain. It does not pack the source into UNORM16 before Post-Dev exposure, preserving decoded highlight headroom until the normal grade/output boundary. Bypass pixels do not overwrite the film-print cache.

The request carries photo geometry once under bypass and retains film-side geometry separately for DI. Enabled edge/date settings and their held-crop constraints are retained, matching the reference's storage policy; their appearance is omitted from ordinary bypass. Native tests cover the float/UNORM16 boundary and highlights above 1, but do not establish a visual match to macOS.

### Acceptance gates

1. Sidecar compatibility: absent/false/true round trips; unknown fields survive; reopening and external edits restore the correct choice. Clipboard application does not copy it to another frame.
2. Session behavior: toggle and undo/redo are coherent; selecting a film restores simulation; existing film/paper settings survive; pairs reject bypass in both UI and host.
3. Frame geometry: use a non-square source with crop, quarter turn, flip, film edge and date parameters. Bypass shows the photo frame and applies geometry exactly once; restoring simulation restores its previous film canvas.
4. Surface agreement: canvas, navigator, filmstrip/export thumbnails, soft proof and exported file use the intended source and geometry. Respect the deliberate masked whole-photo thumbnail convention.
5. Request/cache isolation: toggle during a slow render, switch photographs rapidly, reopen a cached frame and change display settings. Old film or bypass results must not overwrite the current selection/mode.
6. Native export: verify full dimensions, adjustments, geometry and output colour conversion for ordinary exports, selected and background batch frames, and proof. DI behavior is unchanged, including when a frame has `noFilm` saved.
7. Real Windows app: exercise actual menu/focus/undo behavior and inspect rendered surfaces. Record this independently of unit/native test results. Compare with macOS at the pinned reference when a Mac is available.

## Milestone B: CineStill 800T

Status: not implemented in this worktree. The dependency and acceptance plan below remains open; preserving `highlightHeadroom` as an unknown saved field does not implement its rendering behavior.

### Source commits

Use the following commits as provenance and inspect their final state at `main/fd891c6`. Later commits refine earlier physics and UI; applying only the first feature commit is incomplete.

| Upstream commit | Responsibility |
| --- | --- |
| `089e335` | Alias profiles: Vision3 500T data with CineStill-specific information, no copied arrays |
| `389ecc0` | Back-reflection halo model and highlight headroom |
| `94e064d` | CineStill's own 135 and 120 edge layouts |
| `bdef67d` | Headroom before film-edge exposure and CineStill catalog entry |
| `342c974` | Per-colour halo and pressure-plate contribution |
| `7473478` | Fixed-off anti-halation-layer display and highlight-headroom slider |

### Windows dependencies

| Files | Required work and invariant |
| --- | --- |
| `engine/resources_product/profiles/cinestill_800t.json`, `engine/resources_product/NOTICE.md` | Add product alias and attribution. Do not alter Vision3's measured resource arrays. |
| `engine/src/core/profile.hpp`, `profile.cpp` | `derived_from` loading, info overlay and `base_stock`; validate stock names and reject nested aliases as the reference does. |
| `engine/src/core/params.hpp`, `params.cpp` | Add `halation_headroom_ev` wire field (SHOOT, default 4, range 0–8); use base-stock neutral printing filters for aliases; keep legacy manually removed-layer behavior. |
| `engine/src/core/halation_psf.hpp` | Bring in the final per-colour back-reflection kernel constants/model. |
| `engine/src/pipeline/pipeline.hpp`, `pipeline.cpp` | Headroom whole-frame maximum and gated exposure lift before overscan/date; back-reflection blur mixture. |
| `engine/src/shaders/nodes.metal` | Retain the corresponding reference kernel for the shared engine source. This alone does not implement Windows support. |
| New `engine/src/shaders/vulkan/spk_highlight_headroom.comp` | Translate the final kernel with correct RGB indexing, parameters, workgroup folding and numerical conventions. |
| `engine/src/gpu/vulkan_gpu.cpp`, `engine/CMakeLists.txt` | Register the kernel layout and compile/package its SPIR-V resource. |
| `engine/src/pipeline/overscan.cpp` | Apply only CineStill's stock/layout increments, preserving Windows font and geometry support. |
| `modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json`, `modern_UI/Spektrafilm/Tools/gen-catalog.py` | Keep generated/shared catalog provenance coherent; CineStill is a still negative, target print `kodak_2383`, formats 135/120, `noAntihalationLayer: true`. |
| `desktop/src/shared/stocks.ts`, `params.ts`, `filmEdge.ts` | Read the stock capability, model/serialize headroom, use correct film-edge words, and send the new wire field. |
| `desktop/src/panels/RightRail.tsx` and translations | Show anti-halation layer fixed off with reason; show headroom for the appropriate stock only, reset 4 EV, 0–8 range, 0.5 step, disabled when halation is disabled. |
| `API-SPEC-callable-render-service.md`, `engine/tests/parity_schema.py` | Document the new wire field and its intentional native-only difference from the older Python reference. |

The new back-reflection model is selected by the stock's own `antihalation == "no"` metadata. Turning off the anti-halation layer on an existing stock must retain the previous Gaussian preset, so old edits do not change. Headroom lifts the negative's exposure and affects its shoulder as well as its halo; it is not a final-image brightness control.

### Preserve Windows-specific fixes

Do **not** replace whole engine files with their `main` versions. Inspection of the baseline-to-main diff found unrelated reverse changes:

- `pipeline.cpp` / `pipeline.hpp`: main lacks Windows `set_source_shape` and `full_output_size`; replacing these files would remove crop/date/film-edge size handling.
- `pipeline.cpp`: the diff removes the update of `source_long_edge_` after geometry when overscan or date imprint is active. That is not part of the CineStill feature.
- `engine.cpp`: Windows has its own native view, proof, export, residency and source-processing integration; retain these paths while adding a new source choice.
- `overscan.cpp`: main's AppKit/CoreText path differs from the non-Apple `imprint_raster` path, and its math constants differ. Preserve conditional native-font code and Windows-compatible constants.
- Build files and Vulkan sources exist for the port and must not be rolled back by copying macOS build definitions.

### Acceptance gates

1. Profile/schema tests: resolve the alias from staged resources; verify base data and alias identity, neutral filter inheritance, schema defaults/range and failure cases. Existing films keep their identities and output.
2. Shader test: exercise the real Vulkan headroom dispatch, including zero headroom, floor gating, clip-relative gating, a single-channel clipped highlight and a dispatch exceeding one workgroup row where feasible. Compare to an independent CPU calculation/reference.
3. Native synthetic-image tests: distinguish CineStill from manually disabling Vision3's layer; measure the ring/PSF shape, per-colour falloff and 0/4/8 EV response. A bright non-lamp region below the frame's clipped maximum must not receive the lamp's lift.
4. Legacy stability: render representative ordinary stocks and manually removed-layer presets before/after with deterministic stochastic settings. Changes must be confined to the intended new stock behavior.
5. Film edge/date: test both CineStill 135 and 120 edge layouts, frame number/text, crop/rotation and dates. Ensure overscan and date exposures are not included in the source headroom lift.
6. Bundled resources: a newly built Windows host must load the staged alias, final PSF code and new SPIR-V kernel from its own bundle. Successful execution against checkout resources does not prove packaging.
7. Real app and visual comparison: stock selection, fixed-off control, reset/step/range, save/reopen, preview/export and representative light sources. Record the source frame, params, window/display configuration and macOS reference commit.

`main:engine/tests/cinestill_checks.py` supplies useful synthetic alias, ring, gating and headroom checks. Its documented interface is `--dylib`; its resource overlay uses symlinks. Adapt it to the actual Windows DLL/library and staged-resource arguments before using it as Windows evidence. Also inspect `main:engine/tests/overscan_checks.py` CineStill cases and `modern_UI/.../SpektrafilmTests/CineStillTests.swift` / `EngineClientTests.swift` for intended invariants. Do not call skipped or unexecuted Mac cases Windows acceptance.

## Evidence status after noFilm implementation

| Evidence | Status |
| --- | --- |
| Local branch/source comparison at the baselines above | Completed; implementation source is the baseline plus uncommitted worktree changes |
| Source provenance and Windows dependency mapping | Completed; recorded here |
| noFilm implementation | Frontend, Agent, host and Vulkan view/export/proof path implemented; acceptance item remains unchecked because the limited real-app checks below do not cover all GUI cases, other GPUs or Mac comparison |
| Frontend/Agent automated gate | Node/Web/Agent TypeScript and ESLint passed; **387 unit tests passed, 1 realhost test skipped**. [Full check log](../build/check-nofilm-20261028.log) |
| Browser automated gate | **50 Playwright tests passed** using Chromium and the in-page mock host; includes bypass edits/reopen/proof, old-host refusal and pair restriction. [E2E log](../build/e2e-nofilm-20261028.log). This is not native-engine acceptance |
| New native noFilm tests | **2/2 passed**: `spk_vulkan_no_film` and `spk_host_no_film_workflow`. [Log](../../../build-personal-nofilm-20261028/test-nofilm.log) |
| Existing native regression selection | **8/8 passed**: Vulkan view/overscan/pair and host source/proof/Cineon/film-edge/pair workflows. [Log](../../../build-personal-nofilm-20261028/test-regression.log). This is a targeted selection, not the entire engine suite |
| RAW native evidence | ARW passed in both tested decode modes: custom WB changes, exact As Shot restore, frozen private export/proof decode and editor isolation. [Log](../../../build-personal-nofilm-20261028/test-nofilm-arw.log). The available Z8 HE/HE* NEF was refused by existing LibRaw at open, so NEF bypass was not validated |
| Existing film output stability | Seven controlled film/grade/geometry/P3 export/proof/edge-date/Cineon payloads were byte-identical between old and new hosts; proof statistics matched. [Result](../../../build-personal-nofilm-20261028/film-baseline-outputs/result.json). This bounded sample is not all-stock or Mac parity |
| Native build identity | New host from `aed5fd9` plus this worktree, at `D:/SpektraLab-win/build-personal-nofilm-20261028/engine/host/spektralab-host.exe`, SHA-256 `f8c492c9083311a971e16f3cd25e447127cdfd29b272de06d4a834bc1284c98a`; tests use that build's resources |
| New isolated desktop package | Vite/Tauri build completed at `build/windows-nofilm-20261028`; app SHA-256 `84ccf738a2fddf5b947dba49145ead52c57a7e8ef43cf1e0f49f140c4047ee96`. App, new host and all 152 engine resources match the manifest hashes. [Build log](../../build/windows-nofilm-20261028/tauri-build.log), [manifest](../../build/windows-nofilm-20261028/development-build.json). GUI-only development build, no CLI, not a release; actual bundled GUI results are recorded separately below |
| New-build real application | RTX 5070 Ti, 4688×7028 RAW copy: Film More menu bypass changes canvas/navigator/filmstrip; Unicode `−1.25` Post-Dev exposure commits and visibly darkens; selecting the current Portra 400 restores film and preserves exposure; Ctrl+Z restores bypass and preserves exposure. A 90° turn and dragged crop are reflected in JPEG/P3 and PNG/sRGB proofs. [Evidence](../../build/windows-nofilm-20261028/native-ui-evidence.json), [first-run log](../../build/windows-nofilm-20261028/native-ui-first-run.log) |
| Actual GUI export | PNG/sRGB completed 1/1 at 5903×4047, 29,302,987 bytes, SHA-256 `854fc9f0086fe77014bb49ecd211adbd9655713c959162c4bb533083aeda31b0`. See the real-app evidence for the file path. This does not establish every export format, colour space or monitor's accuracy |
| Exit/reopen persistence | After completely exiting and reopening the same RAW copy, the menu remains checked, exposure is `−1.25`, and crop/rotation visually match. [Reopen log](../../build/windows-nofilm-20261028/native-ui-reopen.log), [saved sidecar](../../build/windows-nofilm-20261028/native-ui-sidecar.json): `noFilm=true`, `exposure=-1.25`, `quarterTurns=1`. Both test-app runs are closed and the desktop has been returned |
| GUI limits | Redo, half-frame pairs, film edge/date and DI were not exercised in this GUI pass; their relevant evidence is automated/native only. Other GPUs, Mac visual comparison and a complete release/CLI bundle remain unvalidated |
| Earlier real-app evidence | `build/windows-dev-20261028` covered numeric input, format locks, labels and proof refresh using a 2026-10-22 host. It remains separate first-phase evidence in the checklist, not noFilm evidence |
| CineStill implementation/tests | Not implemented or run; milestone B remains open |
| macOS runtime or two-platform image comparison | Not run |

The new native tests exercise actual Vulkan calculations against independent ProPhoto encoding/exposure checks, highlight values above 1, crop/rotation, film-cache restoration and dormant edge/date/DI isolation. Host coverage includes strict boolean/capability handling, five output spaces with TIFF8/16 export and proof, exported file versus proof codes, statistics from the full output, private frame isolation, and pair/Cineon behavior. These establish the stated test cases, not GUI behavior or arbitrary RAW-camera support.

The old comparison host is SHA-256 `61cc496ff6d2d091c0138e5400ef2d7c00f49acec62e0303938a26564c416b52`, from the earlier checkout at `751ca6b`; the native test owner verified its engine source matches this branch's clean baseline, with build-script differences. The noFilm build and its acceptance must be tracked separately from that binary.

After the build manifest and successful ARW run, two output filenames in `engine/tests/host_no_film.py` gained the input filename to prevent collisions when testing multiple RAW files. All runtime source hashes still match; this test-only naming change was not rerun. The original manifest remains unchanged; see the [test-source addendum](../../build/windows-nofilm-20261028/test-source-addendum.md) for the exact hashes and times.

Before computer use, notify the user so they can stop work and hand over the desktop. Keep automated, native, real-app and cross-platform visual results separate when updating the migration checklist.
