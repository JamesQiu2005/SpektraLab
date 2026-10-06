# desktop/ — working notes (frontend worker)

Running log for whoever picks this up next (a restarted worker or a human).
Newest state first in each list. Read with `git log --oneline -20 -- desktop`.

## Status

**Done**
- Tauri 2 skeleton: `src-tauri/` (Rust core) builds; `cargo test` green.
  - `host.rs`: spawns `spektralab-host` (or the mock), says `hello`, request-id
    map, events → `host-event`, state → `host-state`, restart with backoff
    (3 in 120 s, then `failed` with the stderr tail for the dialog).
  - `files.rs`: folder listing, sidecar store (`<app data>/Sidecars/<file>-<sha256(path)[:16]>.spektra.json`,
    fingerprint for moved files, neighbour migration), atomic writes.
  - `lib.rs`: commands, plugins (single-instance, dialog, opener, log with
    rotation, window-state), argv/open-with paths.
- Mock host `mock-host/` (`core.ts` pure + `main.ts` stdio); schema rows
  extracted from `engine/src/core/params.cpp` into `schema-fields.json`.
- Shared pure modules with tests: `params.ts` (wire + delta + feature gate),
  `geometry.ts` (+ shader-map agreement test), `adjustments.ts` (Layer 2 CPU
  reference + curves), `sidecar.ts` (Mac shape, unknown keys preserved).

**In progress**
- Webview app (React + zustand), host client, WebGL2 canvas.

**Next**
- Shell, menus, library, rails, canvas, export, packaging (see brief).

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
