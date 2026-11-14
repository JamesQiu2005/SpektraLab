# Folder import and preview reuse

The folder picker, Open Recent and drag/drop offer **Import RAW files only**.
The choice is remembered in the application's General settings and can be
changed for each import. OS startup paths use the remembered choice without
opening an extra modal. The filter includes nested folders and recognizes the
same RAW extension list used by the decoder and pickers, case-insensitively.
It filters the imported list only; no source file is moved or removed.

An explicitly selected file is always retained, including a JPEG selected
alongside a folder. RAW-only folder import does not discover saved half-frame
recipes, which can contain other file types. Explicitly selected pair recipes
remain supported. An empty RAW-only result produces an empty library and an
informative status rather than attempting to select a nonexistent first frame.

Every folder open enumerates the files again. Unchanged RAW camera previews
are reused from the persistent display cache; new RAW files are queued for
embedded-preview extraction. The native cache key includes the actual file
path, identity, size, modification/creation timestamps, engine identity and
image configuration. Changed files do not normally reuse the old key. The
cache is capacity-limited and optional, so a miss or disabled/unwritable cache
causes a preview to be regenerated. Bottom filmstrip thumbnails also have a
separate in-memory cache; not all thumbnail work persists between sessions.

There is currently no folder file-system watcher. Adding a photo while the
folder is already open does not immediately add it to the filmstrip: reopen
the folder to rescan it. Existing source edits and sidecars are not rewritten
just because a new photo is present.

Folder scans use a request generation, and library replacement commits are
serialized. A late older scan cannot replace a newer import; late sidecar
geometry cannot publish into another library. This closes the previous race
where old crop-mask loads had no library identity check. Background camera
preview work already checks cancellation and reads the native file-identity
cache before extracting another preview.
