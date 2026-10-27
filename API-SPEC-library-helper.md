# API Spec — the library helper (`spklib-host`)

| | |
|---|---|
| **Status** | The binary is in the repository. The app does not launch it yet: this document is the contract the 2.0 library work builds against. |
| **Binary** | `vendor/spklib/macos/spklib-host`, `spklib 0.1.0+f4de46cf119a (abi 1, schema 1)`. Its SHA-256 is in `spklib-host.sha256` beside it. |
| **Platform** | Universal (arm64 + x86_64), macOS 13.0 or later (the app needs 15.0). Stripped, ad-hoc signed. |
| **Source** | [JamesQiu2005/SpektraLab_library](https://github.com/JamesQiu2005/SpektraLab_library). Built there by `./build.sh release`, at the commit named in its version. |
| **Licence** | MIT (the SDK repository's `LICENSE`). It is a separate program that SpektraLab starts and talks to over pipes; this repository carries the built binary, not its source. |
| **Date** | 2026-10-18 |

SpektraLab 2.0 manages libraries the way Capture One does: catalogs, sessions, albums, folders,
variants, ratings and colour tags. It can also open an existing Capture One catalog. All of that lives
in one helper program. The app starts it, sends it one JSON request per line, and gets one JSON reply
per line. The helper tells the app **where the images are** and keeps **the data around them**. The
app still decodes, renders, caches and exports exactly as it does in 1.x.

## 1. The boundary

| The helper | The app |
|---|---|
| Libraries: SpektraLab catalogs (`<Name>.spkcatalog`) and sessions (`<Name>/<Name>.spksession`) | Decoding, the engine, previews, thumbnails, the display cache, export |
| Images, variants, albums, folders, smart albums, ratings, colour tags, trash flags | Reading EXIF from files; it passes what `ImageDecoder` read to `images.add` |
| SpektraLab's edits: the `Sidecar` JSON, stored per variant, verbatim, with a revision | What the JSON means (`Sidecar.swift` stays the schema's owner) |
| Reading a Capture One catalog, one way, through a snapshot | Anything Capture One renders: its previews, adjustments, styles |
| Moving files between a SpektraLab session's folders, never overwriting | Deleting files: it moves them to the macOS Trash itself |

**Capture One is read-only, always.** The helper never opens a Capture One database. It copies the
file to a temporary place, checks that the copy is a complete database, and reads only the copy. It
refuses while Capture One is mid-write. Nothing is written or created inside a `.cocatalog`. There is
no write-back in 2.0. A rating or album the user changes in SpektraLab is SpektraLab's, kept beside
Capture One's value. The worst outcome is "this catalog cannot be read".

## 2. Bundling and launching

**In the bundle.** Copy the binary to `SpektraLab.app/Contents/Helpers/spklib-host` with a Copy Files
build phase:

- Destination: Wrapper, subpath `Contents/Helpers`.
- **Code Sign On Copy** turned on, so the helper carries the app's Developer ID signature and hardened
  runtime. The ad-hoc signature it arrives with is replaced.

The helper needs no entitlements, and the app does not need any to start it: the app is not
sandboxed, and the entitlements file stays empty. `package.sh` already runs
`codesign --verify --deep --strict`, which then covers the helper. Notarising the DMG covers it as
well.

The app's pre-build check (`Tools/check-bundle-resources.sh`) should also verify the binary against
`spklib-host.sha256`, so a stale or edited binary fails the build instead of shipping.

**At run time.** Start the helper the first time anything touches a library, with `Process` and three
pipes:

```
Contents/Helpers/spklib-host --store ~/Library/Application\ Support/SpektraLab/Libraries
```

- **Startup.** The first line it writes is `{"event":"ready","version":"spklib 0.1.0+…","protocol":1}`.
  Then call `sdk.version` and refuse to continue unless `abi == 1`.
- **One helper per app.** Requests are answered in order. Calls that take seconds (`capture_one.link`,
  the first `library.sync`) belong on a background task, not the main actor.
- **Liveness.** `host.ping` is answered at any time between requests.
- **Quitting.** Send `host.shutdown` from `applicationWillTerminate`, and close stdin if it does not
  exit.
- **A crash loses nothing.** Every write is committed before its reply is sent. Restart the helper,
  reopen the library by path to get a new handle, and carry on.
- **stderr** is a log. Forward it to the RFC-016 diagnostics log.

## 3. Protocol

```
→ {"id": 7, "method": "images.list", "params": {"library": "L1", "limit": 200}}
← {"id": 7, "result": {"total": 9657, "offset": 0, "images": [ … ]}}
← {"id": 8, "error": {"code": "read_only", "message": "Capture One's albums are read-only", "data": null}}
```

- Requests and replies are compact JSON, UTF-8, one per line. `id` is echoed back.
- `library.create`, `library.open` and `capture_one.link` return a handle (`"L1"`). Every library
  method takes it as `library`. Opening an open library returns the same handle.
- **Times.** `captured_local` is the camera's wall clock with no zone, `2024-01-08T23:39:04`. Capture
  One stores it that way, and showing it as UTC would be wrong by the shooting place's offset. Every
  other time is UTC (`…Z`).
- **UUIDs** are stable for the life of a library. For rows that came from Capture One they are Capture
  One's own UUIDs.
- **Error codes** the app should handle by name:

| Code | Meaning |
|---|---|
| `not_found` | Missing image, variant, collection, library or folder |
| `invalid_params` | The request is wrong; a bug in the app |
| `read_only` | The target is Capture One's; offer to do it in a SpektraLab album instead |
| `conflict` | `edit.put` was based on an old revision (`data.revision` is the current one), or a different catalog now sits at the linked path |
| `source_busy` | Capture One is writing; try again shortly |
| `unsupported` | A catalog schema the helper cannot read (the message lists what is missing), a Capture One session (probe only in 2.0), or Capture One smart-album criteria |
| `exists` | A library is already at that path |
| `in_use` | Another SpektraLab has this session open |
| `ambiguous` | More than one `.spksession` in a folder |
| `cross_volume` | A session move across disks |
| `io` | SQLite or file-system failure (`data.sqlite`) |
| `internal` | Report it |
| `unknown_method` | The method does not exist |

## 4. Methods

The SDK's own [`API-SPEC.md`](https://github.com/JamesQiu2005/SpektraLab_library/blob/main/API-SPEC.md)
is the authoritative spec. Where this table and that file differ, that file wins and this table is
stale. `sdk.methods` lists the table from the binary itself. *L* means the method takes `library`.

| Method | L | Params | Result |
|---|---|---|---|
| `sdk.version` | | — | `version`, `abi`, `schema`, `capture_one {write_back: false, previews: false}` |
| `capture_one.probe` | | `path` (`.cocatalog`, its `.cocatalogdb`, a session folder or `.cosessiondb`) | `document`, `document_uuid`, `format` (e.g. `16.8.6.25 Pro Mac`), `counts`, `supported`, `reason` |
| `capture_one.link` | | `source`, `path`? | handle, `info`, and a `sync` report. The mirror lives at `<store>/Linked/<document UUID>.spkcatalog`, so a moved catalog finds its library again |
| `library.create` | | `path`, `kind` (`catalog` or `session`), `name`?, `folders`? | handle, `info`. A session gets `Capture/ Selects/ Output/ Trash/` |
| `library.open` / `library.close` | / L | `path` | handle and `info` / `closed` |
| `library.info` | L | — | `uuid`, `kind`, `name`, `path`, `origin {kind, path, document_uuid, format, synced_at, write_back: false}`, `counts` |
| `library.sync` | L | `force`?, `source`? | `{added, updated, unchanged, removed}` per table, or `{skipped: true}` when Capture One has not changed |
| `collections.list` | L | — | `collections[]`: `uuid`, `parent`, `kind`, `name`, `position`, `origin`, `editable`, `image_count`, `folder`. Kinds: `root`, `all_images`, `recent_imports`, `recent_captures`, `trash`, `in_library`, `project`, `group`, `album`, `smart_album`, `folder` |
| `images.list` | L | `collection`?, `recursive`?, `filter`?, `sort` (`captured`, `imported`, `name`, `rating`, `added`), `descending`?, `offset`, `limit`, `check_files`?, `full`?, `include_trashed`? | `total`, `images[]`: `uuid`, `path`, `file_name`, `kind`, `rating`, `color_tag`, `trashed`, `captured_local`, `variants[] {uuid, position, rating, color_tag, edit_revision}`, `exists` |
| `image.get` | L | `image` | the full image, with each variant's SpektraLab and Capture One values (`capture_one.metadata`, `capture_one.geometry` raw), and `albums[]` |
| `images.lookup` | L | `paths[]` | for each path, `{found, match {image, variant}}`, compared in either Unicode normalisation |
| `locations.list` / `location.relink` | L | — / `location`, `path` or `null` | folders with `online` / "locate this folder". The moved prefix is applied to every folder under it |
| `edit.get` | L | `variant` | `revision` (0 = none), `edit` |
| `edit.put` | L | `variant`, `edit` (the Sidecar JSON object), `base_revision` | the new `revision`, or `conflict` |
| `edit.delete` | L | `variant` | `deleted` |
| `meta.set` | L | `variants[]` or `images[]`, `rating` 0–5 or null, `color_tag` 0–7 or null | `updated`. null hands the value back to Capture One |
| `images.trash` | L | `images[]`, `trashed` true, false or null | `updated`. A flag only; no file moves |
| `variant.create` | L | `image`, `from_variant`? | `variant`, `position`, `edit_copied`: a second print from one negative |
| `images.add` | L | `items[]` (a path, or `{path, metadata}`), `mode` (`reference` or `copy`), `collection`? | `results[] {image, variant, existing, stored_at?, error?}`. Never overwrites |
| `collection.create` / `update` / `delete` / `add` / `remove` | L | `kind`, `name`, `parent`, `criteria` (smart albums use the `images.list` filter), `images[]` | SpektraLab collections only. Capture One's answer `read_only` |
| `session.folders` | L | — | `folders[] {path, relative_path, role, outside_session, exists, image_count}` |
| `session.scan` | L | — | `{seen, added, missing}`: files that appeared in the session folder |
| `session.move` / `session.restore` | L | `images[]`, `to` (`capture`, `selects`, `output`, `trash` or a relative folder), `on_conflict` (`fail` or `suffix`) | `moved[] {image, from, to}`, `conflicts[]`. Crash-safe, never overwrites |
| `session.trash.plan` / `.commit` | L | — / `removed_paths[]` | the files in the session's Trash / `dropped`, `refused[]` |

Filter keys: `min_rating`, `max_rating`, `color_tags[]`, `kinds[]` (`raw`, `raster`, `movie`,
`other`), `text`, `captured_from`, `captured_to` (`YYYY-MM-DD[THH:MM:SS]`), `camera_model`,
`has_edit`.

## 5. How the app runs its library on it

The 1.x model, "the folder is the session" (`Import/Library.swift`), with one sidecar per frame in
`Application Support/SpektraLab/Sidecars`, stays as **Open Folder** for frames outside any library.
Everything below is the 2.0 Library.

**Opening a library.**

- *Capture One catalog.* The user picks a `.cocatalog`. Call `capture_one.probe` and show the verdict
  ("16.8 catalog, 10,149 images, supported"), then `capture_one.link`.
- *Own catalog or session.* `library.create` / `library.open`.
- The app remembers the library's path, not the handle.
- On app activation, and when the window comes forward, call `library.sync`. It costs nothing when
  Capture One has not changed. Report `source_busy` quietly and try again on the next activation.

**The library sidebar.** `collections.list` builds the tree. The roles come from `kind`, never from
names (Capture One's are in the UI language: "全部图像", "最近导入"). `editable: false` marks Capture
One's: no rename, no drop target. "New Album" creates a SpektraLab album, which can hold Capture One's
images.

**The browser.**

- `images.list` for the selected collection, paged, sorted by `captured`.
- Thumbnails come from the app's own `ThumbnailCache`, keyed by `path`. Capture One's `Cache/` is
  never read.
- `exists: false` (from `check_files`) and `locations.list` drive the offline badge and **Locate
  Folder…**, which calls `location.relink`.
- Ratings and colour tags are `meta.set`. Delete is `images.trash`.
- Filters are the `filter` object; a saved filter is a smart album.

**Opening a frame for editing.**

1. The frame's `path` goes into the existing pipeline unchanged (`FramePipeline`, `ImageDecoder`).
2. `edit.get {variant}`: a `revision > 0` decodes as `Sidecar`.
3. `revision == 0` means this variant has never been edited in the library. Adopt the 1.x sidecar once:
   `Sidecar.load(for: url)` → `edit.put {base_revision: 0}`. The 1.x file stays where it is.
4. Neither means a new frame, as today.

**Saving.** Where 1.x calls `sidecar.save(for:)` (the debounced `scheduleSave()`), the library calls
`edit.put {variant, edit, base_revision}` with the revision it last read, and keeps the returned one.
`conflict` means another window or the CLI saved first. Reload, then reapply or ask. Never retry with
the server's revision blindly; that is the lost update the revision exists to stop.

**Variants.** "New Variant" is `variant.create {image, from_variant}`, the way to keep two prints of
one negative. Each variant has its own edit, rating and tag.

**Adding images.**

- Drag-in or Import calls `images.add`, `reference` by default and `copy` on request. A catalog copies
  into `Originals/yyyy/mm/dd`, a session into `Capture/`.
- Pass the metadata `ImageDecoder` already read (`captured_local`, `width`, `height`, camera, lens,
  exposure). The helper never opens an image.

**Sessions.**

- *Shooting.* While shooting, a folder watcher on `Capture/` triggers `session.scan`.
- *Culling.* **Move to Selects** and **Move to Trash** are `session.move`; **Put Back** is
  `session.restore`.
- *Empty Trash.* `session.trash.plan`, then `FileManager.trashItem` for each path, then
  `session.trash.commit` with the paths that actually moved.
- *Exports* go to `Output/` by default.
- *One writer.* A session open in another SpektraLab answers `in_use`. Say who has it; do not retry
  in a loop.

**Exporting** is unchanged: the export page reads the edit as today. A library only supplies the
frames and their edits.

## 6. What the app must not do

- **Capture One's folder.** Never pass a path inside a `.cocatalog` or a Capture One session to
  anything that writes. The helper refuses, but the app should not ask.
- **Deleting.** Never delete an image file except through the Trash hand-off in §5.
- **Edit JSON.** Never put anything into `edit` but the `Sidecar` JSON. The helper stores it blindly,
  so a second schema in the same column would be undetectable.
- **Capture One's adjustments.** Never treat `capture_one.geometry` as a SpektraLab crop. Its format
  is unverified, and mapping it is a separate feature.

## 7. Updating the binary

In [`SpektraLab_library`](https://github.com/JamesQiu2005/SpektraLab_library):

1. Run `./build.sh test` with `SPKLIB_C1_CATALOG` set to a real catalog. It ends by proving the
   catalog package is unchanged.
2. Run `./build.sh release`. It refuses if the sources have uncommitted changes.
3. Copy `build/release/spklib-host` and `spklib-host.sha256` here.
4. Commit with the version line in the message.

A change to the protocol or schema bumps `abi` or `schema` in `sdk.version`. Libraries are migrated
forward on open; an older helper refuses a newer library rather than misreading it.

## 8. What was verified, and what was not

**Verified 2026-10-18:**

- 199 checks against synthetic catalogs built from Capture One 16.8's real schema.
- A full pass over a real 16.8 catalog:
  - 10,149 images and 10,152 variants matched an independent reading of the same database, for path,
    existence, capture time, rating and colour tag.
  - 29 albums and folders had the right counts.
  - A forced resync reported 0 changes.
  - A stat-and-hash census of all 41,342 entries in the package was identical before and after.
- A link of 10k images takes about 0.3 s.
- `tests/host_smoke.swift` drives this binary from Swift exactly as §2 describes: link, page, edit,
  conflict, ping and shutdown.

**Not verified:**

- The x86_64 half of the binary has not been run, because this Mac has no Rosetta.
- The Copy Files phase, Code Sign On Copy and a notarised build carrying the helper have not been done
  yet.
- Capture One sessions are probe-only until their `.cosessiondb` and `.cos` formats have been checked
  against a real session.
