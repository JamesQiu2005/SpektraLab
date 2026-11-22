# spk-library -- the app's client of the library helper

The Windows/Linux app's side of SpektraLab's library: a Rust client of `spklib-host`, the helper
program that keeps libraries (SpektraLab catalogs and sessions, and Capture One catalogs read one way).
This README is the contract the Tauri app wires (PRD-W0 §5.3). The helper's protocol and method table
are `API-SPEC-library-helper.md` (repository root, §10 for Windows) and, authoritatively, spklib's own
`API-SPEC.md`; this crate adds no methods of its own.

Since phase 2 a member of the app's Cargo workspace (`desktop/src-tauri`: one `Cargo.lock`, one
`target/`); no `tauri` dependency, no async runtime. Dependencies: `serde`, `serde_json`. Licence GPL-3.0-or-later (the app's); the
helper it starts is MIT.

## Wiring it (phase 2)

```rust
use spk_library::{default_store, Launch, LibraryHost};
use std::sync::Arc;

// Once, at app setup. Nothing starts here: the first call starts the helper.
let exe = resource_dir.join("spklib-host.exe");                 // beside spektralab-host.exe
let store = default_store().expect("LOCALAPPDATA");             // %LOCALAPPDATA%\SpektraLab\Libraries
let mut launch = Launch::new(exe, store);
launch.log = Some(Arc::new(|line: &str| log::info!(target: "library", "{line}")));
let library = Arc::new(LibraryHost::new(launch));               // app.manage(library)

// tauri::command library_call(method, params) -> Result<Value, LibraryError>
let lib = library.clone();
tauri::async_runtime::spawn_blocking(move || lib.call(&method, params)).await?

// On exit (RunEvent::Exit): library.shutdown();  dropping the last Arc does the same.
```

Tauri surface (PRD-W0 §5.3), implemented by the app, not here:

| command | maps to |
|---|---|
| `library_call(method: String, params: Value) -> Value` | `LibraryHost::call` (any method of spklib's `API-SPEC.md`). Errors serialise as `{code, message, data}` |
| `library_state() -> {running, version, launches, store, executable}` | `is_running()`, `version()`, `launches()`, `launch().store`, `launch().executable` |

Every method blocks until the reply (or the timeout); call it from `spawn_blocking`, never on the UI
thread. `LibraryHost` is `Send + Sync`: share one per app in an `Arc`.

## The process

| | |
|---|---|
| Executable | `Launch::executable`: `spklib-host.exe` from `vendor/spklib/windows-x64/` (verify it against `spklib-host.exe.sha256` when bundling), `spklib-host` on macOS |
| Arguments | `--store <Launch::store>`; the store folder is created if missing. [`default_store()`]: Windows `%LOCALAPPDATA%\SpektraLab\Libraries` (local, not Roaming: rebuildable, large, WAL), macOS `~/Library/Application Support/SpektraLab/Libraries` (as the Mac app), Linux `$XDG_DATA_HOME/SpektraLab/Libraries` |
| Windows | `CREATE_NO_WINDOW`: the helper is a console program and gets no console window |
| Start | On the first call (or `start()`). Waits for the `{"event":"ready"}` line (`start_timeout`, 10 s), then `sdk.version`; any `abi` other than 1 is refused (`unavailable`) |
| Requests | One compact JSON line per request with an increasing `id`; replies are routed back by `id`. Calls from several threads are serialised onto the one stdin; the helper answers in order |
| Timeout | `call_timeout` (120 s) per call, or `call_with_timeout`. A timed-out call fails as `timeout`; the helper keeps running and its late reply is dropped |
| Crash | When the helper exits, every waiting call fails as `unavailable` and the next unscoped call starts a new one. `call_on_launch` checks an expected launch under the pipe-write lock and returns `stale_library` before sending if the helper has changed or stopped. Handles die with the helper. The desktop reopens the same catalogue by path and checks its UUID. A pipe failure or timeout can leave a write's result unknown, so the transport does not retry it. |
| Shutdown | `shutdown()` (and `Drop`): `host.shutdown`, stdin closed, a kill after 2 s, and the process is reaped -- none is left behind. A later call starts a new helper |
| stderr | Each line goes to `Launch::log` and the last 50 to `stderr_tail()` |

## Errors

`LibraryError { code: ErrorCode, message, data }`, serialised as the helper's own error object. Codes:
the helper's (`not_found`, `invalid_params`, `read_only`, `last_variant`, `conflict`, `source_busy`,
`unsupported`, `exists`, `in_use`, `ambiguous`, `cross_volume`, `io`, `internal`, `unknown_method`, and
any newer one as `Other(String)`), plus this client's `unavailable` (could not start, stopped, wrong
ABI, missing executable) and `timeout`. `conflict_revision()` reads `data.revision` of an `edit.put`
conflict: reload, then reapply or ask -- never retry blindly with it.

## Typed calls

Each returns a typed reply whose unnamed fields are kept in `extra` (so a newer helper's additions
reach the webview), or `serde_json::Value` where the reply is a report. Path arguments are `&Path` and
go through `paths::to_helper`.

| call | method |
|---|---|
| `sdk_version()`, `ping()` | `sdk.version`, `host.ping` |
| `probe_capture_one(path) -> CaptureOneProbe` | `capture_one.probe` (a `.cocatalog`, its `.cocatalogdb`, a session folder or `.cosessiondb`) |
| `link_capture_one(source) -> OpenedLibrary` | `capture_one.link` (a mirror in the store; a Capture One session is `unsupported`: probe only) |
| `copy_capture_one(source, to, name?, mirror?) -> OpenedLibrary`, `update_copy(library, source?, dry_run)` | `capture_one.copy`, `capture_one.update` |
| `create_library(path, kind, name?)`, `open_library(path)` -> `OpenedLibrary`; `close_library`, `library_info -> LibraryInfo`, `sync_library(library, force)` | `library.*` |
| `collections(library) -> Vec<Collection>` | `collections.list` (the sidebar; roles from `kind`, never from names) |
| `images(library, &ImageQuery) -> ImagePage`, `image(library, uuid)`, `facets(library, &ImageQuery) -> Facets`, `lookup(library, paths)` | `images.list`, `image.get`, `images.facets`, `images.lookup` |
| `add_images(library, items, copy, collection?)`, `describe(library, items)`, `set_meta`, `trash_images` | `images.add`, `images.describe`, `meta.set`, `images.trash` |
| `locations`, `relink`; `add_folder`, `watched_folders -> Vec<WatchedFolder>`, `sync_folders`, `remove_folder` | `locations.list`, `location.relink`, `folders.*` |
| `create_collection`, `add_to_collection` | `collection.create`, `collection.add` |
| `edit(library, variant) -> Edit`, `put_edit(library, variant, edit, base_revision) -> i64`, `new_variant`, `delete_variant` (0.4.0) | `edit.get`, `edit.put`, `variant.create`, `variant.delete` |
| `remove_images(library, images)` | `images.remove` (rows whose file is gone; never a file) |

Everything else (`session.*`, `collection.update/delete/remove`, `edit.delete`, ...)
goes through `call`. "Sources" -- the list of libraries a person has opened -- are the app's to keep
(the Mac's `CatalogSourcesStore`); the helper is told nothing about them but paths.

**Version.** The vendored Windows helper is spklib **0.4.0**, as the Mac's: `variant.delete`, and the
rating, colour-tag and keyword filter keys match any present variant (spklib `API-SPEC.md`, "Variants").
Key a variant by `uuid` and show its ordinal in `variants[]`, never `position` (positions are not
renumbered after a delete).

## Paths

The helper's paths are UTF-8; on Windows in its generic form, `C:/Users/me/x.NEF`, `//NAS/photos/x`
(ordinary Win32 paths accept `/`). `paths::to_helper` strips a `\\?\` / `\\?\UNC\`
prefix, turns `\` into `/`, upper-cases the drive letter and drops doubled and trailing separators, so
one folder is never stored twice. `paths::to_native` gives the backslash spelling for display. To ask
"is this file in the library", use `lookup` (`images.lookup`): the helper folds case, separators and
Unicode normalisation as NTFS does. On Windows the raw RPC bridge applies the same conversion to
the picker paths for library open/create, Capture One probe/link/copy, folder add and relink.

## Capture One is never written (R-B5)

The helper never opens a Capture One database: it copies it and reads the copy, and nothing is created
inside a catalog or session folder. This crate has no write-back call, and `call` refuses before
sending any create/write target (`library.create`, `capture_one.copy`/`.link` `path`, `folders.add`,
`location.relink`, `images.add` `destination`) inside a `.cocatalog`, `.cocatalogdb` or
`.cosessiondb`. The test suite holds a Capture One package's every byte, size, time and mode to be
unchanged after a session of probe, link, list, sync, copy and update.

## Tests

Unit tests cover paths, protocol errors, source guards and the platform's library store. Run
`cargo test --locked -p spk-library --lib` from `desktop/src-tauri`. The `tests/helper.rs`
integration suite uses macOS tools and a locally built helper.

```sh
SPKLIB_SRC=<SpektraLab_library clone, branch windows/cross-compile-2026-11-17-on-0.4.0> \
LLVM_MINGW=<llvm-mingw UCRT toolchain> desktop/crates/spk-library/gate.sh
```

`gate.sh` runs the SDK's own tests (T-B1), builds and inspects the Windows `.exe`s and checks the
vendored one is the rebuild of its commit (T-B2), runs this crate's tests against the Mac-built helper
with `SPKLIB_HOST` / `SPKLIB_FIXTURES` (T-B3, and the path rules, T-B4), and `cargo check`s the library
for `x86_64-pc-windows-gnu` with rustup's toolchain (T-B5). A missing variable or tool fails the gate.

The Windows packaging gate runs `sdk.version` against the installed helper. A real Capture One for
Windows catalog is still needed for compatibility testing (see spklib `docs/WINDOWS.md`).
