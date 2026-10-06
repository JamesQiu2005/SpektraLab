# desktop/ — working notes (frontend worker)

Running log for whoever picks this up next (a restarted worker or a human).
Newest state first in each list. Read with `git log --oneline -20 -- desktop`.

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
node scripts/package.mjs win   # needs build/host-win-x64 + cargo-xwin
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
