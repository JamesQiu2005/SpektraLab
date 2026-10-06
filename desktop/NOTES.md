# desktop/ — working notes (frontend worker)

Running log for whoever picks this up next (a restarted worker or a human).
Newest state first in each list. Read with `git log --oneline -20 -- desktop`.

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
- Camera white balance / lens correction at decode (PROTOCOL-REQUESTS R2 open).
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
