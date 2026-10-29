# PR #23 integration — 2026-10-29

## Provenance and scope

- Upstream: https://github.com/JamesQiu2005/SpektraLab/pull/23, head `7ed0580`; merged via upstream merge commit `1e727cd6cbd25e0292013e3b4dbb6ac237c0231f` (same tree).
- Local memory milestone: `bbf536dbe775c0db9d2222b6a5d726c73e2b2088`.
- All pre-existing uncommitted source, tests and notes were saved first in `ec59666` (`Preserve local no-film implementation and frontend alignment before PR23 integration`).
- Integration branch: `integrate/pr23-20261029`. This is a real merge preserving upstream ancestry, rather than a collection of cherry-picks. No push or release was performed.

## Integrated behavior

The upstream CineStill 800T profile, halation/highlight-headroom implementation, Vulkan shader, film-edge typography/font resources, catalog, controls, translations, desktop packaging changes and macOS source/tests are included. The upstream no-film public interfaces and reset/menu behavior are integrated with the existing native no-film implementation.

Local move ownership, GPU release/flush boundaries, display/cache behavior and large-image memory optimizations remain in place. The new headroom node uses the local ownership-aware pipeline advancement. The local sidecar unknown-parameter preservation, Unicode-minus input handling, frame/pair fixes and native RAW processing remain intact.

Intentional integration choices:

1. Keep one native no-film render/export path. Preserve the local floating-point source path and RAW highlight headroom rather than adopting the upstream RGBA16 source-clipping path. `view_options` remains supported and `frame_options` is advertised for upstream compatibility. The callable-service specification documents this fork distinction.
2. Match upstream rejection of no-film Cineon/DI exports in the UI, exporter, mock and native host. Enable film before exporting DI. Regular positive exports continue to support no-film.
3. Preserve explicit `frameOptions` on exports, with the existing local no-film gate as the compatibility fallback.
4. Keep both local and upstream no-film regression suites. The upstream resident-editor isolation test initially failed: no-film export applied dormant film parameters to the resident editor. Skipping that parameter mutation for bypass exports fixes the failure; both suites now pass.
5. Adapt one upstream session assertion to compare user parameters semantically, excluding derived film-edge metadata. The native path resolves that metadata without changing the user's selected film/settings.

Historical alignment/migration notes are retained and marked as superseded where this integration completes or changes their recommendations.

## Validation on this Windows machine

Logs below are local ignored build artifacts, not files committed into the repository.

| Gate | Result | Local log |
| --- | --- | --- |
| TypeScript, ESLint, Vitest (`npm run check`) | 404 passed, 1 optional test skipped; 59 suites passed, 1 skipped | `desktop/build/pr23-check.log` |
| Production web build | Passed | `desktop/build/pr23-web-build.log` |
| Native Release build and CTest | 43/43 passed, including both no-film suites and Vulkan regressions | `build/pr23-native-build.log`, `build/pr23-ctest.log` |
| Browser E2E (Edge Chromium) | 53/53 passed | `desktop/build/pr23-e2e-final.log` |
| CineStill checks against the built Vulkan engine | 8 passed, 0 failed | `build/pr23-cinestill.log` |
| Overscan/film-edge checks | 0 failures, including CineStill 135/120 typography and geometry | `build/pr23-overscan.log` |
| RAW no-film integration | Both decode modes, custom WB, exact restoration, frozen private export/proof, editor isolation passed | `build/pr23-raw.log` |
| Native host quick smoke | 0 failures | `build/pr23-host-smoke.log` |
| Rust desktop-shell library tests | 23 passed, 1 intentionally ignored child-process fixture | `build/pr23-rust-execution.log` |
| Xcode project generator `--check` | Current | Console output |

### Toolchain notes

CTest needs the Qt MinGW runtime directory first on `PATH`: `D:\SpektraLab-win\deps\qt-6.11.3\Tools\mingw1310_64\bin`. An earlier run with a different runtime failed before affected tests started; the final 43-test run uses the correct runtime.

Rust used the cached offline toolchain under `D:\SpektraLab-win\deps\rust-gnu`. The old external binutils produced an invalid import; the final build selected the toolchain's bundled `dlltool.exe` and `self-contained/x86_64-w64-mingw32-gcc.exe` through `RUSTFLAGS`. The GNU library test executable also needs a manifest requesting `Microsoft.Windows.Common-Controls` version `6.0.0.0` for `TaskDialogIndirect`, and the matching `WebView2Loader.dll` beside it. These are test-build/runtime requirements, not changes to application behavior.

The final test was built with `cargo rustc --offline --manifest-path desktop/src-tauri/Cargo.toml --lib --profile test -- -C link-arg=D:/SpektraLab-win/SpektraLab-personal/build/pr23-test-manifest.o` after compiling the test manifest resource with `windres`; then the resulting test executable ran with `--test-threads=1`. See `build/pr23-rust-manifest.log` and `build/pr23-rust-execution.log`. The unadjusted `cargo test` startup failure is not counted as a passing run.

### 102 MP memory and output regression

The existing 11662 × 8746 fixture was opened, previewed, exported at full resolution, restored, edited and closed through the native host. Peak process private memory was **6.238746643 GiB**. This is a regression measurement for this fixture, not a general upper bound or a claimed performance improvement.

The decoded full-film RGB16 pixel payload (611,975,112 bytes) is identical to the pre-merge `milestone-isolated-102mp/full-film.tif` result. Both have SHA-256:

`5a3dde9cd729e7145900defb7effe83118dfe3ae1c7b22cb1fd679892de1b8a4`

Evidence: `build/pr23-102mp.log`, `build/pr23-memory-compare.log`; fixture/output directory: `D:\SpektraLab-win\validation\fuji-102mp-20261028\pr23-102mp`.

## Validation boundaries

This validates the Windows native engine, browser frontend and Rust shell library. A packaged desktop GUI/installer run, macOS tests, Linux builds, and Metal-versus-Vulkan image parity were not run. Browser E2E is not a claim of full native desktop visual parity. Installer and macOS changes are included as upstream source, without claiming their runtime validation on this Windows machine.
