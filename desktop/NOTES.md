# desktop/ — working notes (frontend worker)

Running log for whoever picks this up next (a restarted worker or a human).
Newest state first in each list. Read with `git log --oneline -20 -- desktop`.

## Startup state ordering (2026-10-11)

A user reported waiting for the engine in the negative-return release. Its
native launch did complete here, but deterministic tests exposed two startup
races: the snapshot request could precede async event registration, and a
late starting snapshot could overwrite a ready event. Tauri state reads now
wait for listener registration; session boot retains newer events and shows
IPC errors as a failure instead of leaving the initial waiting state.

Gate: all three new cases failed before the fix; typecheck, lint and 71 unit
tests pass (one optional real-host test skipped). Native release launch logs
are recorded separately from GUI visual acceptance; the Windows UI automation
runtime is currently unavailable due to sandbox setup failure. Three independent
real release launches subsequently opened the owned 4688x7028 Sony RAW and
returned full results to the frontend (app log evidence, no host override).
The original release also launched successfully here; the race reproduction
is deterministic test evidence, not a capture of the user's hung instance.

## Return from slide to negative (2026-10-11)

The positive-only restore rule left scanFilm enabled after picking a negative,
showing the orange negative instead of its print. Stock-list picks now use a
separate selectFilmStock action: positives scan, negatives print. Each pick
is one undo step. Paper/exposure settings are retained. Explicit no-paper
settings and sidecar restores still use their explicit state; re-picking a
negative repairs an old saved direct scan without rewriting other edits.

Gate: 68 unit tests, typecheck, lint and 8 mock-browser cases; five new cases
failed before the fix. Real Sony 4688x7028 RGBA16 returned to the same Ektar
print bytes as a direct negative render with stochastic effects disabled.
Release build passed. Native-window automation was unavailable this round
(runtime sandbox initialization failure); no new GUI acceptance is claimed.

## Windows resource paths and positive film regression (2026-10-06)

- Tauri's bundled resource directory can use a Windows `\\?\` prefix.
  Appending `/resource` then failed at the native open boundary. Both the
  mapped constants reader and shared stream path helper now normalize Windows
  separators while keeping Unicode and extended-length paths. The new CPU
  CTest covers real constants/profile/LUT reads, a shader-header stream, mixed
  separators, Chinese and >300-character paths, and malformed UTF-8 rejection.
- Film selection previously highlighted "No Print Profile" for positives but
  still sent `scan_film: false`. Session edits/restores and initial/restarted
  opens now enforce the Mac's positive-only direct-scan rule. Old sidecars and
  pasted/synced settings are repaired too; the paper choice and intentional
  negative direct scanning are retained. The catalog loads before host-ready
  notifications can open a frame, so polarity is known on the first request.
- The optional `realhost.test.ts` now recognizes `spektralab-host.exe` on
  Windows. Supplying both integration environment variables with a missing
  executable or RAW fails instead of silently skipping. The Rust sidecar-key
  test now uses explicit native path bytes on each platform, rather than a
  POSIX hash on Windows; the production key/storage convention is unchanged.
- Native Windows release app (Rust GNU, WebView2) verified with the rebuilt
  host beside the exe and no host-directory override: the actual child used
  `--resources \\?\...\host\engine` and displayed the full Sony RAW. Selecting
  Provia 100F, Velvia 100, Ektachrome 100 and Kodachrome 64 automatically
  produced normal full previews and latitude results; no manual paper click.
- Windows gates on RTX 5070 Ti: 16/16 CTests; typecheck and ESLint; 63 unit
  cases plus the separately enabled real-host crop/turn/grade/export case;
  7/7 Playwright cases (mock backend). Added regressions failed before the fix:
  21 native path checks, 11 session cases and the actual film-picker browser
  case. Full 4688x7028 Sony ARW/RGBA16 and TIFF16/TIFF8/PNG/JPEG host exports
  passed; the formerly failing mixed extended resource path also loaded and
  rendered all four positive stocks. Rust release tests: 5/5 on Windows GNU.
  Mac/Metal parity and installer behavior
  are separate gates, not inferred from these Windows results.

## Status (2026-10-06, finish-up pass)

What the finish-up pass added on top of the first pass below:
- Camera white balance at decode (R2): Temperature / Tint with As Shot boxes
  and presets, re-decoded through `redecode`. Verified in the packaged
  AppImage (extracted, Xvfb, real host, lavapipe) on a CR2: As Shot read
  6228 K / −2.3 from the camera, a click on the Temperature track →
  Custom 3205 K → `redecode` → a cooler full render (42 s), Ctrl+Z → As Shot
  again (sidecar `decode` checked each time). `docs/linux-white-balance-real-host.png`.
- The derived film format no longer adds an undo step (`session.test.ts`).
- `scripts/package.mjs win` builds natively on Windows (MSVC; for CI).
- No personal address in `package.json`; the .deb Maintainer is
  "SpektraLab contributors".
- The staged hosts were current (built from 56f0efe, the latest engine
  commit; `hello.methods` lists `redecode`), so they were not rebuilt.
- Checks: vitest 51 + 1 env-gated skip, `cargo test` 5, Playwright 6/6.
  Packages rebuilt: .deb 14.5 MB, AppImage 92.3 MB, NSIS setup 10.2 MB
  (contains `spektralab-host.exe`, `host/engine/**` with 34 `.spv`,
  `host/licenses/**`, `WebView2Loader.dll`).
- CI notes: `cargo test` needs no `dist/` (a debug build does not embed the
  frontend; checked by a clean crate rebuild with `dist/` moved away).
  Playwright needs the Vite dev server it starts itself (`npm run dev:web`,
  which copies assets from `modern_UI/…/Resources`), so `modern_UI/` must be
  in the checkout; `/opt/pw-browsers` is optional (Playwright's own Chromium
  is used when it is absent).

## Status (2026-10-06, end of the first frontend pass)

**Done and verified with the real host** (`build/host-linux-x64`, lavapipe):
- Release/debug app under Xvfb (WebKitGTK, WebGL2 on llvmpipe): open a CR2
  from argv → live → full render (27–32 s at 5634×3752 on a CPU device),
  navigator, histogram, latitude; crop tool; Ctrl+Alt+] turn through the
  native menu accelerator; Ctrl+E → export → a 3752×5634 Display-P3 JPEG via
  `write_image`; killing the host → restart → frame re-opened from its
  sidecar; second launch → path handed to the first (needs a session D-Bus);
  no Vulkan driver → failure dialog with the host's words. Captures in `docs/`.
- `src/export/realhost.test.ts` (env-gated) exercises the export pixel path
  against the real host.
- Packages: `release/linux/SpektraLab_1.3.1_amd64.deb` (~14.5 MB),
  `…AppImage` (~92 MB), `release/windows/SpektraLab_1.3.1_x64-setup.exe`
  (~10 MB, mingw cross-build; contents listed with 7z, not executed — wine
  here is 64-bit only and has no WebView2).
- Unit (vitest, 38 + 1 env-gated), Rust (`cargo test`, 5), Playwright (6, in
  Chromium against the in-page mock).

**Not done / next** (also in PARITY.md):
- Lens correction at decode (declined by the host: LibRaw has no lens profiles)
  and the white-balance neutral picker.
- Rail width drag-resize, filmstrip reorder, straighten-by-line gesture,
  soft proof at file resolution, display-profile awareness.
- Windows: run the installer on a real Windows box (WebView2 bootstrapper is
  downloaded at install time — `downloadBootstrapper`; the embedded one
  could not be fetched here: go.microsoft.com is refused by egress policy).
  The MSVC path (`SPEKTRALAB_WIN_TOOLCHAIN=msvc`, cargo-xwin) is wired but
  could not run here (aka.ms refused).
- Code signing (none; the owner releases ad-hoc).
- Performance on real GPUs: the full render is re-requested 400 ms after
  each edit settles; on lavapipe that is tens of seconds. Consider a lower
  default preview edge on CPU devices (`backend.device_name` says llvmpipe).

## How to run

```bash
npm ci                         # node_modules
npm run dev:web                # vite alone, in-page mock host (http://127.0.0.1:5173/?open=)
SPEKTRALAB_MOCK_HOST=1 npm run dev                         # Tauri + stdio mock
SPEKTRALAB_HOST_DIR=../build/host-linux-x64 npm run dev    # Tauri + real host
npm run check                  # tsc + eslint + vitest
(cd src-tauri && cargo test)
node scripts/package.mjs linux # needs build/host-linux-x64
node scripts/package.mjs windows [--host-dir D]  # NSIS; cross-builds on macOS (docs/WINDOWS-INSTALLER.md)
```

Linux runtime notes: under Xvfb the app needs `WEBKIT_DISABLE_DMABUF_RENDERER=1`
(no DRI3); WebGL2 then runs on llvmpipe. Nothing in the app sets it — it is
an environment workaround, not a product default.

## Decisions (and why)

- **Scope (owner, via coordinator, 2026-10-06):** the engine keeps refusing
  contrast mask, scene latitude mapping, Cineon DI, film edge/overscan, date
  back and the half-frame pair in this version. Those sections get cheap UI
  only — structure and controls present, disabled with a tooltip driven by
  `capabilities.backend.unsupported_features` — so enabling them later is
  wiring, not design. Time goes to the core editor, export and packaging.
- **Pixels never go through JSON.** `host_request` returns a
  `tauri::ipc::Response` whose body is the protocol's own framing
  (header JSON + payload); `src/shared/framing.ts` splits it in the webview.
  Uploads (`write_image`, PROTOCOL-REQUESTS R1) use `host_request_upload` with
  a raw body framed the same way.
- **The wire never asks the host for an unported feature.** `params.wire()`
  takes a `FeatureGate` built from `unsupported_features` and omits those rows
  entirely; the settings stay in the sidecar (so a Mac sidecar with a film edge
  opens here and is not damaged).
- **Menus are built in TypeScript** (`@tauri-apps/api/menu`), so labels follow
  the language switch and actions call the store directly. **Single-key
  shortcuts (V/H/C, ←/→, `,` `.`, Y) are not menu accelerators**: a GTK/Win32
  accelerator would fire while a text field has focus (AGENTS.md trap 32).
  They are handled by the webview's key handler behind the typing-key guard;
  the menu shows them as text only.
- **Settings, About and Export are in-window pages/dialogs, not separate Tauri
  windows**: the macOS windows share one in-process `Session`; one webview with
  one store is the faithful equivalent, and avoids cross-window state sync.
- **Native window decorations on Windows and Linux** (`theme: Dark`). A
  custom title bar (`decorations: false`) loses Windows 11 Snap Layouts on the
  maximise button, the system's resize borders/DPI handling and accessibility,
  for a look the macOS app gets from its hidden title bar. The top bar keeps
  the macOS layout; the title bar above it is the OS's.
- **Sidecar keys:** the sha256 is of the standardized absolute path (`.`/`..`
  resolved, symlinks not followed) as UTF-8, like `URL.standardizedFileURL`.
  On Windows the fingerprint has no inode, so a moved file is not recognised
  there (Linux: inode + device + size).
- **Mock host** runs with Node's built-in type stripping (`node main.ts`,
  Node ≥ 22.18), so it needs no build step; it is only for development
  (`SPEKTRALAB_MOCK_HOST=1`) and never ships.

## Gotchas found

- Root `.gitignore` ignores `lib/`, `build/`, `target/`, `dist/`, `*.log`:
  never name a desktop source directory `lib`.
- `vitest --root /` scans the whole filesystem; run vitest from `desktop/`.


## Windows feedback and export investigation — 2026-10-12

Based on tester workbook test20261011.xlsx (Sheet1 rows 2, 9, 16–18,
32, 44, 48–60). Built on f23a5f0; local changes, not yet committed.

- Folder import includes nested folders; skips hidden entries, symlinks and
  Windows reparse points to avoid cycles. Recursive Rust fixture passes.
- Windows WebView2 handles menu keyboard chords; Win32 menu entries display
  shortcut hints without also registering accelerators. Linux keeps native
  accelerators. Text-field Ctrl+A/Z/etc. stays with the field; batches reject
  editor shortcuts. Bypass now uses the undo/persisted adjustment edit door.
- Reset capture setup restores all FilmParams and camera DecodeSettings in
  one undo step; retains geometry and Post-Dev. Layout reset restores scale,
  tab, visibility, widths and section expansion; saved widths reach CSS.
- Built-in export recipes are reusable presets. Editing one creates a selected
  custom copy; legacy overwritten presets are recovered as custom copies.
  Actual format, depth and space are shown together. Restore selects preset 1.
- Clipboard buttons wrap as whole buttons; filmstrip reserves filename and
  scrollbar room at 100/115/130 percent scale.
- Neutral native-size exports copy RGB16 directly, with independent storage
  and opaque alpha. Cropped/resized/graded exports retain the existing path.
  Export logging now separates render/receive, pixels, send/encode/write, total.

Validation: typecheck/lint, 77 frontend cases; optional real-host export was
run separately and passed (crop + turn + exposure). Six Rust release tests
passed. Thirteen browser/mock UI cases passed (12 initial, layout-reset locator
corrected and rerun). These are distinct from the native release window:
full Sony RAW rendered correctly using bundled host/resources and an isolated
WebView profile; Ctrl+B, Ctrl+Shift+F and Ctrl+= were visibly confirmed. Further
native key injection stopped after user activity was detected. Intel was not
available locally. Mac/Metal render parity remains unverified.

Export investigation: upstream main 01d32a2 (2026-10-11) has the same
modern_UI/Spektrafilm/Spektrafilm/Export/Exporter.swift reviewed here. Mac uses
full reprint -> GPU Layer 2 -> geometry/resize -> GPU output transform -> CPU
CGImage -> ImageIO encoding. Windows uses host render/CPU output transform ->
RGBA16 payload -> JS geometry/grade -> RGBA16 upload -> native encoders. At
4688x7028 this sends about 503 MiB in image payloads across both directions.
The current JS grade order also differs from Mac; a future GPU export port
must validate grade/geometry/colour order, not just move code for speed.

RTX 5070 Ti, 4688x7028 Sony ARW, default effects, no crop/Post-Dev/resize,
quality 100: one native-host + production filePixels measurement per format
(open/decode excluded; no Tauri/WebView IPC in this harness):

| Format / space | Before | After |
| --- | ---: | ---: |
| JPEG / Display P3 | 10.80 s | 5.29 s |
| TIFF16 / ProPhoto | 6.80 s | 1.74 s |
| PNG8 / sRGB | 12.91 s | 7.47 s |

These are single observations, not a whole-app benchmark or a Mac comparison.
Three interleaved old/new pixel passes on the SAME full RAW result were all
byte-identical: old 4.272–5.229 s (median 4.302 s), new 40.5–43.3 ms (median
42.5 ms). The first end-to-end samples include first-render vs warm-cache
variation; only the same-buffer comparison isolates the change.

Remaining work: CPU CAM16 output conversion (~2.6–2.8 s in the P3/sRGB samples),
binary copies/IPC, PNG compression (send/encode/write ~4.2 s). Port output
transform and edited export processing to a validated GPU/host path, keep
pixels out of JS, then profile the encoders. Do not equate the historical
780–870 ms film-render figure with end-to-end export. Full-size/default
quality and colour transforms were not disabled to reach these numbers.

Local evidence: D:/SpektraLab-win/validation/feedback-20261012 (red/green logs,
RAW phase timings, interleaved exact-byte comparison, browser captures and
release build logs). User workbook/photos are not distributed in the package.

### Import scope follow-up — 2026-10-12

Opening one file previously scanned its parent folder. Recursive folder
import therefore also swept up nested, previously imported rolls. Startup
does not restore `lastFolder`; the apparent restore was a fresh parent scan.
`openPaths` now replaces the library with exactly the expanded explicit
inputs. Only supplied folders expand recursively; choosing files already in
the library also replaces it with that selection. Folder import remains
recursive, and batch/empty-input guards remain in place.

Two regression cases failed before the fix (parent scan and retained old
roll). After the fix, typecheck/lint and 81 unit tests passed, plus two browser
cases covering the editor and folder -> restart -> single-file filmstrip.
The optional real-host export test was skipped; this change does not touch
the image pipeline. Existing portable archives are preserved; the import-fix
test package contains the rebuilt frontend and unchanged f23a5f0 backend.

### ProPhoto views and direct export — 2026-10-12

The new `render_view` path retains the film print on the GPU, applies post
adjustments in encoded ProPhoto, then geometry/size/display conversion. The
preview toolbar independently saves Auto/sRGB/Display P3; actual canvas and
screen capabilities control fallback. Browser post/crop is skipped for baked
frames, stale results are dropped, Fit uses bounded pixels and 100% requests
native pixels within the WebGL limit. Thumbnails retain their uncropped input
contract and all preview surfaces carry color-space tags.

`export_frame` freezes edits, performs the complete pipeline in the host and
returns file metadata only. Batch export does not select/develop every frame
in the editor. A pending decode change gets a private session; unchanged full
snapshots preserve grain/cache. Unsupported hosts cannot silently export an
incomplete frame. RAW defaults to up to 8 OpenMP workers. PNG and JPEG<=95
use the new static codecs; JPEG96–100 retains the previous float DCT because
the substitute failed the quality gate. TIFF encoding is unchanged.

Builds, performance boundaries, test evidence, the JPEG exception and the
decision to retain serial batch export are recorded in
[Windows wide-gamut validation](../engine/WINDOWS_WIDE_GAMUT.md). This iteration
initially created a local validation build only. The user subsequently requested
Git submission and a portable archive. The release uses the same validated
app/host/shader binaries, adds matching source archives and dependency notices,
and excludes personal photos, sidecars, logs and WebView profiles. Its manifest
records the source commit and SHA256 of every distributed file.
