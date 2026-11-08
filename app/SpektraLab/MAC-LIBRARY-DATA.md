# The Mac's library data

First written 2026-10-23, with dated additions to 2026-11-05. The data layer and the API the library views
read (the views are `Sources/Mac/LibraryUI/`, `design/MAC-LIBRARY-UI.md`). Code: `Sources/Mac/Library/`, on the library helper
`spklib-host` 0.2.0 (`vendor/spklib/macos/`, `API-SPEC-library-helper.md`; the SDK's own
`API-SPEC.md` is authoritative).

| File | What it holds |
|---|---|
| `MacLibraryModels.swift` | The value types a view reads, and the `MacLibraryData` protocol |
| `CatalogSourcesStore.swift` | `CatalogSourcesStore`, the one `@Observable @MainActor` implementation; `MacHeaders` (header reading) |
| `LibraryAPI.swift`, `LibraryHost.swift`, `HelperProcess.swift` | The helper's methods, typed, and the process (0.2.0 additions marked) |
| `MacLibraryCheck.swift` | Debug only: `--library-check <dir>` drives the store in the running app and writes a report |

The store is `AppServices.macLibrary`. It is lazy and inert: no helper process starts and no file is read
until a view calls `start()`.

## 1. The model

The library is modelled on Capture One's, with these parts:

- **Sources**, one row each:
  - `appLibrary`: the app library's own frames (`FrameCatalog`).
  - `catalog`: a SpektraLab catalog.
  - `session`: a SpektraLab session.
  - `captureOneCatalog` and `captureOneSession`: Capture One's, read one way.
  - `folder`: a folder linked from Finder.
- **A collection tree per source**, laid out like Capture One's Library tool:
  - `fixed`: All Images, Recent Imports (each import a child, newest first), Recent Captures, In Catalog and Trash.
  - `user`: projects, groups, albums and smart albums, nested.
  - `folders`: the folder tree, each folder under its volume ("/", "disk") as Capture One lays it out, for
    every catalog alike (§2c).
- **Rows** of the selected collection for a dense grid (`MacImage`), loaded a page at a time.
- **Facets** (`MacFacets`): counts per rating, colour label, kind, capture year, month and day,
  camera, lens and keyword, plus "developed" and "undescribed". Each facet is counted with every other
  tick applied but its own, so ticking 3★ still shows how many have 4★.
- **Develop**: `openInDevelop` opens the picture in the existing Develop page.

### How each source is backed

| Source | Behind it | Copy or reference |
|---|---|---|
| `catalog` (`<Name>.spkcatalog`, anywhere the user picks) | a helper library, itself | **reference by default** (Capture One's "Current Location"); `.copy` puts files in `<catalog>/Originals/yyyy/mm/dd` |
| `session` (a folder with `Capture/ Selects/ Output/ Trash/` and `<Name>.spksession`) | a helper library, itself; its own folder is kept in step | **copy by default** into `Capture/` (Capture One's session default) |
| `captureOneCatalog` (`<Name>.cocatalog`) | the helper's mirror `Libraries/Linked/<document UUID>.spkcatalog`, made from a snapshot copy | Capture One's file is never written; Capture One's pictures are read where they are. Since 2026-10-24 SpektraLab's own ratings, labels and imports are kept in the mirror (§2c) |
| `captureOneSession` (a folder with `<Name>.cosessiondb`) | a catalog of the app's own, `Libraries/Sources/<id>.spkcatalog`, referencing the session folder, its `CaptureOne/` caches never walked | reference; the `.cosessiondb` and `.cos` files are never read |
| `folder` (any Finder folder) | a catalog of the app's own, `Libraries/Sources/<id>.spkcatalog`, referencing the folder | reference, kept in step |
| `appLibrary` | `FrameCatalog` (the app library: copied-in files, folders linked as frames by an earlier build) | copy (`Originals/`) |

**Referenced folders kept in step.** A SpektraLab catalog or session can take any number of folders
(`addFolder`). A linked `folder` source and a Capture One session are one such folder. Each sync
(`synchronize`, and on its own when a source is selected or the app becomes active, at most once a
minute) walks the folder and compares it with the library:

- A **new** file is added by reference.
- A file that **moved** keeps its row, and so keeps its rating, label, albums and frame. A move is a
  new file whose name and size match exactly one file that went.
- A file that **went** is hidden. Its row is kept and comes back if the file does.
- A folder that is **not there** (a disk away) is marked offline, and nothing in it changes.

The helper never opens an image, so the store reads each new file's header (`MacHeaders`, ImageIO, no
pixels) in the background and sends the result with `images.describe`. The date, camera and lens
facets fill in as it goes, and `facets.undescribed` counts what is left.

## 2. The API (`MacLibraryData`)

State a view reads. Every property is observable.

| | |
|---|---|
| `sources: [MacSource]` | Every source, the app library first. `status` is ready, offline, busy (Capture One writing), inUse (a session open elsewhere) or failed. Also on each source: `imageCount`, `format`, `isReadOnly`, `acceptsFolders`, `acceptsImports`, `defaultImport` |
| `selectedSourceID`, `selectedSource` | |
| `tree: MacCollectionTree` | `fixed`, `user`, `folders`; `find(id)`, `all`, `defaultSelection` (All Images) |
| `selectedCollectionID` | |
| `watchedFolders: [MacWatchedFolder]` | A catalog's or session's kept folders: `url`, `isOnline`, `imageCount`, `syncedAt`, `collectionID` |
| `query: MacImageQuery` | `sort` (`captureDate`, `fileName`, `rating`, `importDate`, `addedDate`), `descending`, `text`, `ratings`, `minimumRating`, `colorLabels`, `kinds`, `capturedFrom`/`capturedTo`, `cameras`, `lenses`, `keywords`, `developedOnly`, `includeSubfolders`; `isFiltered`, `cleared` |
| `images: [MacImage]`, `total` | The rows loaded so far (`pageSize`, 1,000) out of `total` |
| `facets: MacFacets` | `ratings`, `colorLabels`, `kinds`, `years`, `months`, `days`, `undated`, `cameras` (+`cameraMakes`), `lenses`, `keywords`, `developed`, `undescribed`, `total` |
| `activity: MacLibraryActivity` | `working` ("Reading Capture One Catalog…"), `problem`, `lastSync` ("Card: 1 new, 1 moved, 1 gone") |

A row (`MacImage`) carries:

- the file: `id` (source and image), `url`, `fileName` and `kind` (raw, raster, movie, other);
- the capture time: `capturedLocal` is the camera's wall clock as stored; `captureDate` is the same
  wall clock as a `Date` in this Mac's zone, for display;
- `rating`, `colorLabel`, `cameraMake`, `cameraModel`, `lens`, `exposure` ("1/250 s · f/5.6 · ISO 100")
  and `pixelSize`;
- its state: `isOffline`, `isTrashed`, `isRemoved` and `fromCaptureOne`, plus `primaryVariant` and
  `variantCount`;
- `develop: MacDevelopInfo?`, which holds the frame's id, its `film` and `paper` (display names) and
  its `state` (developed, in the queue, failed, or not developed). It is nil until the picture has been
  opened in Develop.

Calls:

| | |
|---|---|
| `start()` | Read the kept sources and select the last one |
| `select(source:)`, `select(collection:)`, `apply(_ query:)` | Each reloads the first page and the facets |
| `loadMore()`, `loadAll()` | Further pages |
| `newCatalog(named:in:)`, `newSession(named:in:)` | Create and select |
| `open(_ url:)` | Accepts a `.spkcatalog`, a SpektraLab session folder, a `.cocatalog` (probed first: "16.8.6.25 Pro Mac"), a Capture One session folder, or any other folder, which becomes a `folder` source. A source already on the list is just selected |
| `addFolder(_:to:)`, `stopWatching(_:)` | Kept folders of a SpektraLab catalog or session. Stopping keeps the images |
| `importFiles(_:into:mode:)` | Into a SpektraLab catalog or session. A nil `mode` uses the source's default. Headers are read here and passed in |
| `synchronize(_:)` | A Capture One catalog is read again if it changed; any other source's folders are walked |
| `remove(source:)` | Takes it off the list. Nothing on disk is deleted |
| `detail(of:)` | Variants (with Capture One's own rating and label beside SpektraLab's), albums, file size |
| `setRating`, `setColorLabel` | Every helper source. On a Capture One catalog the value is SpektraLab's override in the mirror (`meta.set`; Capture One's file is never written, and a sync never touches an override). The app library has none (`readOnly`). The loaded rows are changed in place and only the facets are read again. A picture not among the loaded rows (an agent names any, ARCHITECTURE.md §7.16) has its first variant asked of the helper (2026-11-09) |
| `openInDevelop(_:)` | Develop, on the picture's frame |
| `putOnLightTable(_:)` | The Light Table, with the chosen pictures it takes laid on it (`MacLightTableCarry.takes`: a frame of SpektraLab's with a film size recorded, a film edge on or a pair); no frame is made; none it takes is refused (`notForTable`); nothing chosen opens it as it is (§2c) |
| `openInDevelop(_:focus:)` | Develop on `focus`, its filmstrip the given pictures in that order (`MacDevelopCarry`) instead of the whole app library; at most `carryLimit` (500). Frames are made for the ones without, in one arrival; offline ones are left out. The set is also kept as a session of the app's own, by reference, in `Libraries/Carried/<time>/` (the last carry only; cleared at start) |
| `refreshDevelopInfo()` | Re-read the develop column, for example after coming back from Develop |

**Opening in Develop.** Edits are not the helper's. A picture's look is kept by its frame in the
app's library (`FrameCatalog`, as a `FrameEdit`). The first `openInDevelop` makes
that frame with `ImportService.adoptLibraryFile`, a Mac-only addition:

- the picture is read where it is, not copied;
- Info's *Original* row reads "*source* › *folder*";
- nothing is queued for it: the Develop page develops it (2026-10-24).

Later opens find the same frame by the file's path. That path join is what gives a row its film, paper
and state, and what the "developed" facet and the `developedOnly` filter count.

### Binding a view

```swift
struct MacLibrarySidebar: View {
    @Environment(AppServices.self) private var model     // or however the view reaches it
    var body: some View {
        let store = model.macLibrary                  // any MacLibraryData
        List(store.sources) { s in Text(s.name) }
            .task { await store.start() }
    }
}
```

A row's thumbnail is the UI's to make (`ThumbnailStore` / the camera's embedded preview, keyed by
`url`). The data layer never reads Capture One's `Cache/`.

## 2a. Import (2026-10-24, `Sources/Mac/Import/`)

The sidebar's Import icon, or "+" › Import…, opens a Finder panel (folders and pictures, several),
then the import page, modelled on Capture One's Import Images window. The page's state and the import
itself are `MacImportSession`; `--import-check <dir>` drives that same model.

- **Scan** (`MacImportScan`, off the main thread, in two passes):
  1. A listing: a picture is a type conforming to `.rawImage` or `.image` that ImageIO reads.
     Hidden files and packages are skipped, and `CaptureOne/` folders are never walked. Sidecars
     (`.xmp`, `.spektra.json`, `.cos`…), movies and anything else are counted and left out.
  2. The headers, four at a time (`MacHeaders.readIfReadable`). A file ImageIO cannot open is
     dropped here.

  Include Subfolders is on by default. 629 pictures on a USB disk: listed in 0.05 s, headers in
  0.6–0.7 s (a loaded machine, headers probably cached).
- **Import To**: a SpektraLab catalog or session. The default is the selected one, else the most
  recently opened, else **New Catalog…** ("SpektraLab Catalog" in `~/Pictures`, made only when the
  import starts; a name already taken becomes "… 2"). The placements:
  - *Add to Catalog* (reference): the default for a catalog.
  - *Copy to Folder…*: the app copies each file under the chosen folder, at its path below the
    picked folder, never overwriting (`_1`, `_2`), then adds the copies by reference.
  - *Copy into the Catalog*: the helper's `copy` (`Originals/yyyy/mm/dd`, or a session's `Capture`);
    the default for a session.
- **Exclude Duplicates (n)**: a file whose path, or whose name and size, the destination already
  holds (`existingFiles`: one listing, its trash included) is greyed and not imported.
- **Selection**: the page's grid takes the library grid's selection (click, ⌘, ⇧, the marquee; the
  arithmetic is shared, `MacGridLayout` / `MacMarquee`). The button reads *Import All (n)* with nothing
  chosen, *Import n Selected* with a selection. Escape is Cancel, as in Capture One's window.
- **In chunks** of 200 per `images.add` (`importChunk`). The first chunk that adds anything makes
  the import's one Recent Imports album; later chunks pass it as `collection` with
  `recent_import: false`.
- **After**: `showImport` selects the destination and that album, and the flow closes. An import is
  not a watched folder (`folders.add` is not used).
- API additions: `existingFiles(in:)`, `importChunk(_:into:copyIntoLibrary:album:)`,
  `showImport(in:album:)`. In `LibraryClient.add`: `recentImport:` and `destination:`;
  `LibraryAdd.recentImport`; the error per file is read as `{code, message}` (it was read as a string,
  so one refused file would have made a whole chunk's reply unreadable).
- Proved 2026-10-24 (`--import-check`, 0 failures): 629 of 629 by reference from the external disk
  in 4 chunks into one album (0.32 s), the disk unchanged by name, size and modification time; a
  second pass finds 629 duplicates and adds nothing; Copy to Folder made 8 byte-identical copies
  (SHA-256) and the catalog references the copies; a selection of 3 adds 3. Copy to Folder was timed
  on the same volume only (0.07 s, probably clones); a copy across disks is not timed.

## 2b. Export (2026-10-24, `Sources/Mac/Export/`)

One Export page for both ways in: the library's Export icon brings the chosen pictures in grid order
(frames are made for those without, read in place, through `frames(for:focus:)`); Develop's Export
(`SheetRoute.export`) brings its frame. Controls at the left (the sheet's recipes, Format, Size, Colour,
Quality, Save to, a Folder row, the progress and Export/Stop), the library's viewer and cells at the
right; Esc closes, Return exports, ← → step through the pictures.

- A batch is `ExportService`'s batch, one picture at a time, each developed again from its
  original.
- `MacExportRun` puts each file into the folder chosen once (Finder's panel, kept as a bookmark,
  `mac.export.folder`) as its picture finishes: under a hidden `.spkpart` name, renamed exclusively, a
  taken name becoming "-2". It keeps running if the page is closed.
- Stop leaves the finished files whole. A picture with no frame (file gone, disk away) or an
  unreadable original is said on its line and the rest go on.
- Share hands the batch's files to the system sheet at the end.
- Proof: `--export-check <dir>` (report.json). Measured 2026-10-24: 3 of 5 saved with 2 reported, at
  most 1 job at once (sampled every 10 ms), Stop leaving 1 whole TIFF, Develop's file byte-identical
  to the old path's (0 of 47,985,504 values differ). A build broken on purpose (overwrite, a Stop that
  does nothing) gave 5 failures.
- Not clicked by a person: the Finder folder panel, Share, Show in Finder. Develop's
  own shortcuts may still fire under the cover. The order is the grid's, not the clicks'.

## 2c. One shape for every catalog, and the Light Table (2026-10-24)

The owner: "Unify the UI in the library when opening .cocatalog and .spkcatalog as they are all
primary source of truth and should not involve any difference on the user side, based on the Capture
One style UI." What the person sees no longer depends on whose file a catalog is:

- **The same icon and words**: a source is drawn by what it is (`MacWords.symbol`: a catalog, a
  session), in the sidebar's picker and in Import To; a Capture One catalog is a catalog.
- **The same tree** (`CatalogSourcesStore.tree(from:)`, one builder for both):
  - every folder hangs under its volume, as Capture One's Library tool shows it ("/" › "Users", "disk" ›
    "pictures"). A SpektraLab catalog's top folders used to be loose ("115NZ7_2" alone); a folder whose
    volume has no row gets one made (`volume:<path>` ids, never sent to the helper);
  - a folder that holds only folders (a volume, "Users") opens and closes when clicked, in every
    catalog, instead of showing an empty grid;
  - two fixed rows of one kind are one row (a mirror's Recent Imports: Capture One's and SpektraLab's).
- **The same imports**: a Capture One catalog takes imports (`acceptsImports`), into its mirror. The
  files are SpektraLab's rows there, and each import is a Recent Import under a Recent Imports row of
  SpektraLab's beside Capture One's (spklib 0.2.1, `new_recent_import`), shown as one row. A sync
  writes only Capture One's rows, so these outlive every sync. *Copy into the Catalog* copies into the
  mirror's own package.
- **Still different, because of what the files are**: a Capture One smart album is listed but not
  evaluated (greyed); Capture One's own albums cannot be renamed or added to; a folder cannot be
  *kept in step* in a mirror (`folders.add` is refused there); a Capture One catalog can be `busy`
  while Capture One writes.

**The Light Table** is entered from the grid's header (the Library's loupe, after the sidebar and the
viewer switches: the grid, the viewer, the table), or a picture's menu (*Put on Light Table*), or ⇧⌘L,
for every source alike. It used to be a sidebar row for the app library only. The owner's rule for what
goes on it: "only those with edit history in SpektraLab, and those that have film size records". So
of the chosen pictures, a frame of SpektraLab's whose film is recorded (a film edge on, its format; or
a half-frame pair) is laid on the table (`MacLightTableCarry`, `LightTablePane.layCarried`). A
picture with no frame, or a plain frame (whose 36 mm is the default, not a record), is left out and no
frame is made for it. Nothing chosen opens the table as it was.

Proved 2026-10-24 (`--library-check` on the owner's catalog, scratch home, 23 steps, 0 failures; the
`.cocatalog`'s census of 41,346 entries identical before and after):
- the Capture One catalog's top folders are all volumes ("/", "disk", "NIKON Z 8"), and so are the
  scratch SpektraLab catalog's ("/");
- an import of 2 files into the Capture One source added 2 as one Recent Import, listed in the one
  Recent Imports row among Capture One's ("2026-10-24 15:17", "2026年10月19日 17:45", …), and shown;
- the Light Table refused 2 pictures with no frame and a frame with no film size, and laid a frame with
  its film edge on (found in `lighttable.json`).

The SDK's own tests for 0.2.1: the new case fails on 0.2.0 and passes; 265 synthetic, and the
real-catalog pass on the backed-up catalog (293, census unchanged).

## 2d. Settings (2026-10-24, `Sources/Mac/Settings/`)

The owner: "bring the v1.3.3 type of information density back ... a full redo on the settings, most
ideally a separate page just like import / export." The Mac's Settings is a page over the whole window,
as Import and Export are; every way to `CoverRoute.settings` shows it on the Mac (⌘,, the library's "+" ›
Settings and › Sources, Develop's actions menu, a disk banner).

Seven sections in a column at the left; every setting of one section on one page, at macOS sizes:
- **General**: language, about and licences.
- **Appearance** (2026-10-24, `Features/Settings/AppearancePage.swift`): the mode
  (System, Light, Dark), the background per mode, the interface scale (80–150 %).
- **Develop**: new frames' film and paper, preview size, Lens Correction, the film edge's body.
- **Export**: the recipes, edited in place.
- **Sources**: the Mac library's sources, through `MacLibraryData` (open, show in Library, read again,
  show in Finder, remove from list). Folders linked as frames by an earlier build are listed only while any exist; a
  new folder is never linked as frames on the Mac.
- **Storage**: copied-in originals, working copies, preview copies, full-size renders, thumbnails and
  cache, each with its usage. The three budgets go through `setWorkingCopiesLimit`,
  `setPreviewCopiesLimit` and `setFullRenderCacheLimit`; the full renders' usage is counted from the
  `.spkfull` files.
- **Diagnostics**: the log, Export Log Zip into Finder's panel, what the log holds, this build.

What the page leaves out of the shared Settings sources (`Sources/Features/Settings/*.swift`), and why, is
`MacSettingsCoverage.table`. `--settings-check <dir>` (debug, `CFFIXED_USER_HOME` required):
- reads those sources and fails on an item the table does not name, or a shown item not
  drawn on its section;
- drives each budget's setter and puts it back;
- lists a scratch folder source;
- draws every section in English and Simplified Chinese at 847 × 539 and 1,440 × 900.

2026-10-24: 0 failures over 85 items. Not clicked by a person yet.

## 2e. What renders, and what is kept (2026-10-24, `Sources/Mac/Render/`)

The owner: "adding into the .spkcatalog or .spksession does not mean automatic calculation, it's
triggered on user behaviour"; full-size renders in an LRU sized by the person; and the Scheduler itself
left as it is ("what gets changed is the external cache system around it, and what is being put into the
scheduler"). `Sources/Scheduler/**` is untouched, but for one condition the owner approved on 2026-11-05:
the same-frame `importDevelop` dedup matches the tier too (`RenderQueue.submit`), so Develop's full-size
prefetch of a frame no longer cancels the preview develop a paste asked of it.

- **A paste develops the previews it changes** (2026-11-05, the owner: a tile that kept the old picture until
  it was opened "would make user wonder what the fuck is actually happening"). A paste is a person's act on
  each frame it reaches (`DevelopCause.asked`), so every frame pasted outside an open page whose develop the
  paste changes — or that has none and whose edit it changed — gets one `importDevelop` at the preview tier,
  priority 5, fed to the queue 16 at a time in the order pasted (`MacLibraryActions.feed`; preparing one
  costs ~2.4 ms of the main thread). The cell shows the empty ring while it waits (no dimming, so a grid of
  300 does not go dark; the ring has its own dark disc so it shows on a bright picture), the dimmed ring
  while it develops; the sidebar says "Developing N pictures" with **Stop**; the notice says "Their
  previews are developing." Pairs are developed too (`prepare` makes the piece).
  - Opening one cancels its queued develop (`OpenFrameSession.open`); one opened and closed while still owed
    is skipped by the feed when its page left a picture of the edit.
  - A second paste replaces the queued ones; one pasted again while its develop runs keeps the ring
    (`AppServices`'s `onUpdate`: an ended preview develop with a newer one held reads queued, not done).
  - **Stop** cancels from the scheduler's own list and the frames still waiting for their originals
    (`AppServices.stopPreviewDevelops`, `awaiting`),
    not from the tiles' states, and a paste still making its frames feeds nothing after a Stop (`stops`).
  - A preview of an edit the frame no longer has (stopped, the app quit first — a develop's state is not
    kept across a launch — or its original away when pasted) is marked in the cell's badge line and its
    line reads "Preview out of date" (`MacPreviewStaleness`, memo keyed by everything the stamp reads,
    the body seed included); the cell's menu has **Develop Previews**, fed the same way.
  - Export, the Light Table and the paste share one test (`EngineRouter.needsDevelop`, which does not ask
    whether the original is reachable now). The Mac's full-size prefetch no longer moves a tile's state
    (`FrameCatalog.apply`).
  - Measured (`--clipboard-check-many 501`, 2026-11-05): 501 never-opened pictures framed in 0.56 s; all 501
    fed to the queue in 1.85 s (Develop Previews) with the main thread's lag p95 ~58 ms / worst ~61 ms, 2.3 s
    after a paste with p95 ~67 ms / worst ~148 ms; p95 ~23 ms / worst ~28 ms while they develop. Two lookups made that possible: `FrameCatalog.frame(_:)` was a walk of
    every frame (the grid looks every row's up on each render), and `refreshDevelopInfo` normalised every
    path and rewrote every row on each develop's state change; at 500 queued the window lagged ~0.6 s.

- **Only a person's act on a frame develops it** (`AppServices.develop`, `DevelopCause`: on the Mac only
  `asked` queues).
  - What used to develop in bulk and now queues nothing on the Mac: a frame the Mac makes (export,
    carry, Light Table), the launch's catch-up, and a setting held over the library.
  - Such a frame shows its file's own preview until it is opened in Develop (whose page leaves its
    picture behind as the frame's develop) or exported.
  - Proved: 5 exports with 0 `importDevelop`; 200 frames by reference with 0 jobs; a relaunch with 201
    undeveloped frames queues nothing.
- **Full-size renders are an LRU of their own** (`WorkingCopies.fullLimit`, Settings'
  `fullRenderCacheLimit`, default 8 GB).
  - Evicted by bytes, the one used longest ago first. A use is the page showing it, an export reading
    it, or the Light Table reading it.
  - Never evicted: the current Develop frame's render, any job in flight, the exporting frame's renders.
  - The order survives a relaunch (file mtimes). *Clear Working Copies* clears them.
  - Until now there was one at a time.
- **Develop's neighbours are made ahead** while the person inspects at full size:
  - one at a time, +1, −1, +2, −2 in the direction of travel, after the current frame's own render;
  - submitted as `importDevelop` at the full tier, below the page's own 3;
  - skipped where it would not fit the limit;
  - moving on cancels one that has not started.

  One door for full-render jobs (`Engine/FullRenderJobs.swift`): the page, the table and the prefetch,
  so no render is made twice.
- **The Light Table** reads, in order:
  1. the kept develop, if large enough;
  2. else the kept `.spkfull`, banded, at the size needed (`LightTableFullRead`);
  3. else exactly one `fullView` job, with the develop ring.

  A contact sheet waits for the renders it needs. The ceiling is `LightTableSizing.sourceCeiling`, derived
  from the code's constants: the largest film any format makes × 5,000 px / A6's 105 mm = 8,224 px, a
  6×17 strip on A6 at the densest export. Every format is read 1:1 there.
- **A memory warning** (`scheduler.onTrimCaches` → `AppServices.releaseFullSize`) drops off-screen Light
  Table textures and the full-render detail of develop pages no page holds; what is on screen stays.
- Proof: `--render-check <dir>` (60 checks) and `--render-check-relaunch <dir>` (5), report.json.
- Known, not fixed:
  - a 6×17 strip's render came out at 5,610 px from an 8,256 px NEF (the 6×9's are 8,572), so a 6×17
    is read at its render's own size, below 1:1 at 5,000 px A6;
  - after a lens-correction change or a camera-crop catch-up (sweeps), a tile keeps its old develop until
    the frame is opened or exported; it is marked out of date (§2e, 2026-11-05).

## 2f. The Light Table on the Mac (2026-10-24, `Sources/Mac/LightTable/`)

The owner wanted, after the website (`spektralab.app/lighttable`):
- the bottom controls "to the top right of the window", with the website's 拖动/点击 difference;
- a 1:1 read as Xcode reads the display;
- "that library-like rail on the right; it should be collapsible";
- right-click to rotate or take off (no format change, no delete);
- the Add page "similar to the import page".

What landed:
- **The bar** (`MacLightTableBar`): ‹ back, *Light Table*, the status line (quiet, the longest form that
  fits), Undo; then [Drag | Click] (D, C), Loupe (L, the lens on the pointer), [− Fit +] (−, 0, =),
  1:1 (1), [A4 ▾ | ⟲], ···, Share, the rail (⌥⌘0).
  - *Drag* is the table's own gestures.
  - *Click* is the website's: a click picks a film up, a click puts it down, Esc puts it back, a drag
    just outside a corner turns it (⇧ for 15° steps), a trackpad's turn turns the film under it.
  - R/⇧R rotate right/left (R was Turn 90° left before), ⌫ takes off, the arrows move 1 mm (⇧ 10),
    Return opens Develop.
- **1:1** (`MacDisplay`, `MacActualSize`): the window's own display (`NSWindow.screen` →
  `NSScreenNumber`), its millimetres (`CGDisplayScreenSize`) and its mode's points; scene points/mm =
  (mode points ÷ mm) ÷ the window's measured Mac points per scene point (0.770). There is no 1:1 on a
  display that doesn't know its size. Proved: one cm of table is 64.179 screen pixels against the
  display's 64.173 (LG HDR 5K, 163 ppi), from a window-server capture.
- **The rail** (`MacLightTableRail`): Add Photos, then every film on the table in the order first laid
  down, each drawn as it lies (turned). Tiles come from the source the table's own rule picks at the
  tile's size, and never start a job (0 seen). Spread Out (铺开) is Tidy Up; Clear (清空) is Take All Off;
  both offer Undo.
- **The right click** (`MacLightTableMenu`): on a film only, Rotate Right (R), Rotate Left (⇧R), Take
  Off (⌫).
- **Add to Light Table** (`MacLightTableAddPage`): an overlay of the page, not a sheet.
  - A column (On the Table and its room, Shown, Date Taken), then the frames `MacLightTableCarry.takes`
    accepts, in `MacGridCell`s with the library's selection. Frames already on the table are marked and
    can't be chosen; the 99 limit holds. Cancel (Esc), Lay Down n (Return).
  - It opens in 15 ms and closes in 11 ms. The old sheet took 793 ms to close: UIKit's animated
    page-sheet dismissal, ~0.78 s on Catalyst, plus a ~280 ms main-thread stall of its own.
- Proof: `--lighttable-check <dir>` (56 checks, report.json, window-server PNGs in English and
  Simplified Chinese at 847 × 539 and 1,440 × 900).
- Only compiled, not driven by a real pointer or keyboard: the click, hover, corner-drag and
  trackpad-turn recognizers; a physical right click; keys pressed by hand.

## 2g. Three faults the owner found in the running app (2026-10-24, evening)

- **The sources list was never read back.**
  - `CatalogSourcesStore.load` decoded `sources.json` with a plain `JSONDecoder` (dates as numbers) while
    `save` writes ISO 8601. Every launch therefore failed to read the list, started from the app library
    alone, and wrote that over it.
  - This was the owner's first report of the day ("instead of opening the app's own library by default,
    we open whatever the user opened last time"), wrongly answered then as already working: a file was
    read, but no relaunch was tried.
  - Now one reader, `CatalogSourcesStore.readRegistry`, serves the launch and `--library-check`. Step 5 of the
    check read the file with `JSONSerialization` before, so it could not see the fault. Shown red on the
    old decoder (2 failures) and green on the new.
  - A list that cannot be read is set aside (`sources.unreadable-<time>.json`), never written over.
  - Proved by relaunching a scratch home: the selected `.spkcatalog` is the one reopened.
- **Frames carried from a catalog read *Not connected* while on a connected disk.**
  - A frame the Mac library makes (`adoptLibraryFiles`) has a linked-folder source and no linked
    folder. The launch marked every such frame away, and nothing brought it back, disk or no disk.
  - On the Mac, `FrameCatalog.recheckLooseFiles` asks the file itself: there → available; gone from a
    mounted disk → missing; its disk not mounted → away. It runs at launch and with every folder check:
    activation, *Check Again*, a disk mounting or ejecting.
  - On a copy of the owner's library: 103 of 106 were *offline* before one launch; all 106 available
    after.
  - On a scratch disk image ejected and attached under the running app: available → offline →
    available.
- **"Thumbnails and cache" was every app's caches.** On the Mac (not sandboxed) the user domain's
  Caches folder is `~/Library/Caches`, so Storage counted 6.4 GB of other apps'.
  `LibraryPersistence.cacheFolders` is the app's own: `~/Library/Caches/<bundle id>` and the system's
  per-app cache (Metal's and Core Image's compiled shaders, ~20 MB here). Thumbnails are held in memory
  only, within `ThumbnailStore`'s bytes. Settings' full-render count no longer walks every app's
  caches every 5 s.
- **1–5 do work in a catalog or session** (posted to a scratch copy's process: ⌘A then 4 rated all 8
  pictures of a `.spkcatalog`, read back from its database). The SpektraLab Library itself has no
  ratings: its frames have no such field. Whether it becomes a `.spkcatalog` of its own is the
  owner's to decide.
- **The Light Table's filter** (`MacLightTableCarry.takes`) now also takes any frame SpektraLab has
  developed. The owner: "even without the overscan, if you have the grain ever calculated, then you
  should know the size of the image": every develop sends `film_format_mm`.

## 2h. The SpektraLab Library is catalogs (2026-10-24, `Sources/Mac/Migration/`)

> **This supersedes** §1's `appLibrary` source and row, §2's "the app library first", §6.8 ("the list
> starts with the app library") and §7's first bullet: on the Mac there is no app-library source any more.

The owner: "fully managed by a .cocatalog-style .spkcatalog"; "we do not limit where this .spkcatalog is
stored", and several are allowed; "copy .cocatalog to .spkcatalog … and in the future we can still do
updates"; on an update SpektraLab wins.

- **No app-library source on the Mac.** `appLibrary` is dropped from `sources.json` at start (still
  decodable), and the last source opened is reopened. With none, the library says "No catalog yet" with
  *New Catalog…*. Edits stay in `FrameCatalog`, joined by path (§6.2).
- **The move, once** (`MacLibraryMove`, page `MacLibraryMovePage`). It is offered while a frame with a
  file is in no catalog, by `MacLibrary/moved.json`. That record holds each move's catalog, frames and
  those left out, plus `inCatalog`, the frames `frames(for:)` has made from catalogs since.
  - Default place `~/Pictures/SpektraLab Library.spkcatalog`, changed in a save panel. *Not now* lasts
    until the next launch; Settings › Sources offers *Move into a Catalog…* meanwhile.
  - Each frame's file goes in by reference, read in place: copied-in `Originals/` (never moved), linked
    folders' files, and frames the Mac library made.
  - Each old import (one minute) becomes a Recent Import named with its time (`recent_import_at`, 0.3.0;
    on 0.2.1 renamed instead). Favourites become an album; linked folders become kept folders
    (`folders.add`).
  - **Removing a frame never deletes a copied-in original on the Mac** (`ImportService.discard`): it is a
    catalog's picture now, and may be the only copy.
  - Proved on a copy of the owner's `library.json` (107 frames):
    - 107 frames and 106 files in 0.56 s; 5 imports; the develop column on 106;
    - the census of `Originals/` unchanged;
    - a relaunch reopens it and doesn't offer the move again;
    - ⌘A then 5 through the real keys rated 108, read from `Library.spkdb`.
- **New Catalog…**: an AppKit save panel (`MacSavePanel`, through the runtime). The helper refuses a place
  a library is in, so the panel's *Replace* deletes nothing. Its *Create* has not been clicked by a person
  (a remote view the process can't press).
- **Copy to SpektraLab Catalog…** (a Capture One source: the picker, "+", Settings › Sources):
  `capture_one.copy {source, path, name, mirror}` (0.3.0) into a new `.spkcatalog`, which opens. The
  Capture One source stays.
- **Update from Capture One** (a copy: "+", and Settings › Sources' "Copied from <path> · updated
  <date>" with *Update Now*): `capture_one.update`, its counts in the activity line, tree and rows read
  again. `MacSource.copiedFrom` is kept from `library.info.copied_from`.
- Debug: `--catalog-check <dir>` (`--catalog-check-relaunch`, `--catalog-check-c1 <cocatalog>`); driver
  steps `catalog.new`, `catalog.copy`, `catalog.update`, `panel.cancel` (with `--notify-tag`).

## 2i. A half-frame pair is a row (2026-10-25, `Sources/Mac/Library/MacPairRows.swift`)

The owner: "database side this is treated as a separate image, but it must point to the storage place
within the app"; and, the same day, "cache system can be deleted, so the library edit must just point to
the file on how the pair is formed and the storage of edit, instead of the could-be-deleted cached file,
and let the scheduler and cache system do the re-render job."

- **The row's file is the pair's recipe**, `Pairs/<the pair's name>.spektrapair` beside `library.json`
  (§3), never under `Previews/` or a render cache, and never in the person's folders. It is
  `HalfFramePair`'s own JSON with the desktop's keys (each hole's `path` the frame's file, as the desktop
  means it, and `frame` its id; placement, exposure, prints, spacing, `onStrip`), and under `spektralab`
  the pair's id, its two frames (id, file, name) and where its look is kept (`library.json`, by that id).
  The look itself is not copied into it. Written on every `keepPair` and every `changePair` that moves the
  piece (`pairKept`).
- **The row** is added by reference (`images.add`, never copied, even into a session; no Recent Import)
  with the pair's capture time, size and camera. Its kind is `pair` (spklib 0.3.1; the File Type facet
  says "Half-Frame Pair"). The helper makes a `Pairs` folder row for it, as for any referenced folder.
- **Which library**: the one that holds the pair's first frame (by `images.lookup` of that frame's file),
  trying the shown library first, then every SpektraLab catalog and session and, only if it is the one
  shown, a Capture One catalog (linking another would take a snapshot); with none, the shown library if
  it takes imports. A pair with nowhere to go is tried at the next start and the next change. Where each
  went is `MacLibrary/pairs.json` (pair id → source, image, path).
- **The join**: `refreshFrameIndex` maps a pair's recipe path to the pair (not its guide), so the row's
  develop column, its grid picture (`FrameView` of the pair: its develop, or its guide until then) and
  Develop open the pair's own page; no frame is made of the file.
- **Pictures are the caches'**: at the store's start `AppServices.repairPairPictures` draws a pair's guide
  again from its frames' files where the guide is gone, and asks the queue to develop it where its
  develop file is gone.
- **Removing the pair** (`AppServices.remove`) deletes the recipe, then `images.remove` (0.3.1, which refuses
  while the file is there and never touches one) forgets the row. A recorded row whose pair has gone is
  cleaned up at start.
- **Pairs made before** (in the film-edge flow, or before this) get their recipe and row
  at the store's start (`placePairs`). `MacLibraryMove` still leaves pairs out of the move: they have no
  file of the person's; this pass places them.
- **Making one on the Mac**: a picture's menu, **组成半格组 Make Half-Frame Pair**, with one or two
  photographs chosen (a pair is never a hole of another). The frames are made as Develop makes them, then
  `AppServices.makePair`. Two: the pair lands as a row of this library, chosen, the
  library still in front. One: *Pair With* (`PairWay.ask`) asks for the second, then opens the pair's
  darkroom.
- Debug drive steps `pair.make` and `remove.chosen` (`MacLibraryDriver`).
- Proved live (scratch home, a catalog of two copied ARWs referenced in `~/Pictures/Roll`): the pair made
  from the grid, its row with its picture, Develop on the pair's page (Top frame / Film / Bottom frame);
  after a relaunch with `Previews/` and `WorkingCopies/` deleted, the row there, its guide and develop
  made again, the pair's page opening; with the row taken out and `pairs.json` deleted, the start put the
  recipe and a new row back; removal took the recipe and the row away. `Roll/` held only the two ARWs
  throughout.

## 2j. Previews are the library's (2026-11-05, `Services/LibraryPreviews.swift`, `Mac/Library/MacLibraryPreviews.swift`)

The owner: "Preview film renders would be managed by the catalog / session in Capture One style, instead
of the current way of keeping them in the internal cache part." A frame's kept develop (`DevelopedPicture`,
at Settings › Develop › Preview size) is SpektraLab's preview, and it is kept in the library its picture
was opened from, as Capture One keeps a catalog's `Cache/Previews` in the `.cocatalog`:

| Library | Its previews |
|---|---|
| SpektraLab catalog | `<Name>.spkcatalog/Cache/Previews/dev-<frame>-<stamp>.heic` |
| SpektraLab session | `<Name>/.SpektraLab/Cache/Previews/…` — hidden, because `session.scan` and the session's own sync walk the session folder and skip only names beginning with "." |
| Capture One catalog | its mirror's `Libraries/Linked/<uuid>.spkcatalog/Cache/Previews/…`; the `.cocatalog` is never written |
| Capture One session, Finder folder | the app's own `Libraries/Sources/<id>.spkcatalog/Cache/Previews/…` |
| no library | `Previews/` as before |

- **Which library**: the one `frames(for:)` last carried the frame from (Develop, Export, the filmstrip),
  else the one its develop already lies in (read from the paths at launch), else the app's `Previews`. A
  frame is one per file, so a file two catalogs reference has one develop; a new one replaces the old
  wherever it was.
- **Only into a library that is there** (its `Library.spkdb` / `.spksession`): a disk away or a catalog
  moved meanwhile is never written to (no ghost `X.spkcatalog/Cache`), and the develop goes to `Previews`.
- **Migration**: lazy. A develop in `Previews` (2.1.3) moves in, under its own name (the stamp is
  unchanged), when its frame is next carried from a library.
- **Moved, copied, deleted** (review fixes, 2026-11-05; `LibraryPreviews.locate`): the previews go with
  the library. Every carry looks for each carried frame's develop, off the main thread and only while the
  library is there. A develop found under its own name in the library it was carried from (the catalog
  moved or copied in Finder) is the frame's again, and the frame is pointed there. One on a disk that is
  not mounted (`/Volumes/<disk>` absent) is away and left as it is. One gone from a disk that is here
  (its `Cache` deleted, *Delete Previews* on another Mac) is **missing**: `DevelopedPicture.markedMissing`
  keeps its size and marks its stamp. No edit's stamp equals a marked one, so the develop page's close,
  Export's `want` and the Light Table's `tableWants` develop it again. `FrameView` and the Light Table's
  `source` draw the camera's preview meanwhile. A pair's develop at the library's start
  (`repairPairPictures`) follows the same rule, so an away disk's pair is not developed again into
  `Previews`. A develop already in the library under the name a 2.1.3 develop would move to is adopted,
  and the app's copy goes.
- **Nothing sweeps a library's previews** ("no frame names it" would take another Mac's). Only two things
  remove one: a replaced develop goes, and so does Settings › Storage › Previews › *Delete Previews*. That
  takes the selected library's previews, and asks first, because it removes them for every Mac that opens
  the library. The frame on an open develop page is spared. The other frames keep `developed`, marked
  missing, so the Light Table still takes them (`MacLightTableCarry.takes`) and a film edge's canvas keeps
  its shape (`MacShownFrame.aspect`). They read as not developed.
- **Counted**: previews in the app's own libraries (`Libraries/Sources`, `Libraries/Linked`, listed or
  not) are a part of Settings › Storage › *On this Mac*, "Previews of folders and Capture One"
  (`LibraryPreviews.measureOwn`). They have no budget: a budget sweeps by age. *Every library* lists each
  source's previews, measured every 30 s.
- **The full-size renders (`.spkfull`) stay the app's**, under *Full-size renders*: a working cache of up to
  ~1 GB a picture, one LRU for the Mac, not what a library keeps.
- The helper is unchanged (the folder is derived from `library.info.path` and `kind`). Wanted later, not
  needed: `skip[]` for `session.scan` and the session's own sync, so the session cache could be a visible
  `SpektraLab/` folder as Capture One's `CaptureOne/` is.
- Proved: `tools/storage_selftest.swift` covers the rules and catches 60 broken rules, among them the
  write (`LibraryPreviews.write`, which `EngineHost.write` calls), `locate`, the twin and `measureOwn`.
  `--settings-check` F, G and H run a folder source, a SpektraLab catalog and session, and a catalog
  moved in Finder, then its `Cache` deleted, all in the running app. They cover where the develop lands,
  the session scan adding nothing for it (against a visible control that it adds), *Delete Previews*
  leaving the develop marked missing, the migration, re-rooting after the move, and missing after the
  `Cache` goes.

## 3. Storage, under `~/Library/Application Support/<bundle id>/`

The debug build's bundle id is `com.spektralab.mac.local`.

| Path | What |
|---|---|
| `MacLibrary/sources.json` | The sources list: `id`, `kind`, `name`, `path`, `libraryPath`, `addedAt`, `openedAt`, and the selected one. The only file the store writes itself |
| `Libraries/Linked/<document UUID>.spkcatalog` | A Capture One catalog's mirror, keyed by Capture One's document UUID so that a moved catalog finds it again (the helper's) |
| `Libraries/Sources/<source id>.spkcatalog` | The catalogs the app makes for a Capture One session or a linked folder |
| `Pairs/<name>.spektrapair`, `MacLibrary/pairs.json` | Each half-frame pair's recipe, the file its row points at, and which library each row went into (§2i) |
| `library.json`, `Originals/`, `Previews/`, … | The app library (`FrameCatalog`). Frames made by `openInDevelop` live here; their develops are in their library's `Cache/Previews` since 2026-11-05 (§2j) |

A SpektraLab catalog or session the user creates lives where the user puts it; `~/Pictures` is the
sensible default for a save panel. A catalog is `<Name>.spkcatalog/Library.spkdb`, with `Originals/`
for copies. A session is `<Name>/<Name>.spksession` plus its four folders. The helper migrates a
library to schema 2 the first time 0.2.0 opens it. A 0.1.0 helper refuses it afterwards.

## 4. What is read-only

- **A Capture One catalog is never written.** (What SpektraLab keeps about its pictures is kept in the
  mirror, §2c; the census below and in §2c proves the `.cocatalog` untouched.)
  - The helper copies `<Name>.cocatalogdb` to a temporary place, checks the copy, and reads only the
    copy. It refuses while Capture One has a hot journal; the store then shows the mirror as last read
    and sets the source to `busy`.
  - No rating, label, album, trash flag or file goes back.
  - The proof is in §5.
- **A Capture One session is never read as a database.** Only its picture files are listed, and
  `CaptureOne/` folders are never walked.
- **A linked folder's files, and a catalog's referenced files, are never moved, renamed or deleted.**
  `folders.sync` writes rows only.
- **A SpektraLab session does move files**, but only through `session.move` / `session.restore`, which
  this layer does not expose yet. Its Trash empties only by the hand-off described in
  `API-SPEC-library-helper.md` §5.

## 5. Measured, and proved (2026-10-23)

The test catalog was the owner's `~/Pictures/Capture One Catalog.cocatalog`: Capture One
16.8.6.25, 10,150 images, of which 9,658 are not in its trash, and 41,346 entries. Capture One was
running throughout.

**In the running app** (`--library-check`, with `CFFIXED_USER_HOME` set to a scratch home so that
nothing of the owner's library or store was touched). The report has 0 failures.

| Step | Time |
|---|---|
| Open the catalog: probe, link and sync, tree, first page of 1,000 rows, facets | 0.69–0.88 s |
| Every image as grid rows, 9,658 in pages of 1,000 | 0.89 s (1.6 s before the date formatter was cached) |
| The same in one page, with the facets | 0.94 s |
| Open a Recent Import ("2026年10月3日 16:53", 193 images) | 21–35 ms |
| Open the largest folder ("Nikon Z8", 4,380 images) | 130–195 ms |
| Filter to 4★ (189, the number the facet gave) | 86 ms |
| Open a picture in Develop (frame made, Develop page shown) | 0.27 s |

Also checked in that run:

- The ten Recent Imports albums show Capture One's time (`created_at` from ZDATECREATED) and its
  counts.
- 83 of the 9,658 files are offline.
- A rating on Capture One's image was refused. (Since 2026-10-24 it is kept as SpektraLab's override in the mirror, §6.9; the check now asserts that.)
- The row carried its frame after Develop: Koda Porta 400 · Koda Pro Porta Enduro, in the queue.
- The Developed filter and facet found exactly that one picture, and a second open found the same
  frame.
- A scratch catalog with a referenced folder of 6 real files: all 6 were described (camera facet
  "ILCE-7M3 5"). After Finder moved one file, deleted one and added one, sync reported "1 new, 1
  moved, 1 gone". The moved file kept its row and its 3★.
- A copy import landed in `Originals/2026/10/23/`.
- A session's import was copied into `Capture/`, and a file dropped into `Capture/` was picked up by
  sync.
- A linked folder listed its 3 pictures. A folder shaped as a Capture One session listed 2 and
  skipped `CaptureOne/Cache`.
- `sources.json` held all six kinds.

**The SDK's own tests** (`SpektraLab_library`, branch `mac-catalog-session`):

- 255 synthetic checks.
- The move and facet checks were also run against two deliberately broken builds: one with move
  detection off, and one where facets kept their own filter. They failed (6 failures) for exactly
  those reasons.
- The real-catalog pass, 283 checks:
  - the facets match an independent count of the same database;
  - `images.list` of all 9,658 visible images took 88 ms, or 175 ms with full rows;
  - `images.facets` took 49 ms.

**Census.** The census records every entry in the package: its size, mtime and mode, and a hash of
each file under 256 MB. It was identical before and after each of the four runs:

- 41,347 entries for the two SDK passes;
- 41,346 entries for the two app runs.

Capture One itself removed one entry between the runs, while nothing of ours ran.

To run it again:

```bash
CFFIXED_USER_HOME=<scratch>/home build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app/Contents/MacOS/SpektraLab \
  --library-check <scratch>/check --library-check-c1 "$HOME/Pictures/Capture One Catalog.cocatalog" --library-check-exit
```

## 6. Decisions for the owner

1. **Copy or reference.** These follow Capture One's defaults:
   - a SpektraLab catalog imports by reference, and copies into `Originals/yyyy/mm/dd` only when
     asked;
   - a session copies into `Capture/`;
   - a linked folder, a Capture One session and any folder added to a catalog or session are always
     referenced and kept in step.
2. **Edits live in the app's library, not in the catalog.** A picture's look is its `LibraryFrame`'s
   `FrameEdit`, joined to the catalog by the file's path. The helper's `edit` table is reserved for the
   desktop `Sidecar` JSON (`API-SPEC-library-helper.md` §6), so a catalog doesn't carry its edits to
   another Mac yet. Storing the `FrameEdit` in the catalog would need a decision on that column.
3. **A frame is made on first open in Develop, not at import.** Before this change, linking the 9,658
   images of a Capture One catalog as a folder of frames (`ImportService.link(folder:)`) made 9,658 frames
   and queued 9,658 develops. With the store, a picture costs nothing until it's opened: a folder opened
   on the Mac is a `folder` source (`model.macLibrary.open(url)`), never a folder of frames (§2d).
4. **A file that went is hidden, not deleted.** Its row and frame survive, and it returns if the file
   does. An offline folder marks nothing.
5. **A move is the same name and size, with exactly one candidate.** Two identical candidates are
   treated as one removal and one addition.
6. **Recent Imports keep the 20 newest.** Each import into a SpektraLab catalog or session is an album
   named with local time "2026-10-23 20:41", and `createdAt` lets the UI spell it Capture One's way.
   Later syncs of a folder are not imports.
7. **A folder shows its own images** (`includeSubfolders` false by default), which matches its count.
   This follows Capture One's folders and is not checked against Capture One's behaviour.
8. **No default catalog is created.** The list starts with the app library; *New Catalog…* and
   *Open…* add the rest.
9. **Capture One's ratings and labels are read, never written back.** The owner, 2026-10-24: the
   app keeps its own copy (the mirror), so a rating set on a Capture One picture is SpektraLab's
   override there (`COALESCE(override, Capture One's)`), and Capture One's catalog is untouched.
   (Until then a rating on a Capture One picture was refused.)
10. **`abi` stays 1** for spklib 0.2.0, because every change is an addition; the schema goes to 2.

## 7. Not done, not verified

- The `appLibrary` source's facets and filters are computed in Swift and are simpler than the helper's:
  no colour labels, keywords or ratings, since its frames have none.
- **Capture One sessions:** their ratings, labels and albums (in the `.cosessiondb`/`.cos`) are not
  read, because no real session was at hand. The SDK's `docs/SESSION-DESIGN.md` §6 is still to be run.
- **Capture One keywords** are split from ZCONTENT_KEYWORDS on `,` `;` and line breaks. The owner's
  catalog has none, so this is unverified. Colour labels map by Capture One's menu order (1 red … 7
  purple), also unverified: the owner's catalog has no tagged image.
- **There is no file-system watcher.** Sync runs on selection, on activation (at most once a minute),
  on `synchronize`, and once when a disk mounts or ejects (AppKit's `NSWorkspace` notifications,
  reached through the runtime; 2026-10-24). FSEvents could replace the minute.
- **The row mapping runs on the main actor.** All 9,658 rows cost about 0.7 s there beyond the helper's
  0.18 s. Pages of 1,000 (about 90 ms each) are how a view should load. `loadAll` is for measurement.
- **Session culling** (`session.move` to Selects/Trash, Empty Trash) and **albums** (`collection.*`)
  are in the client but not in `MacLibraryData` yet.
- **The x86_64 half of the helper** has not been run (no Rosetta on this Mac).
- **The SDK branch `mac-catalog-session` is not pushed.** The vendored binary names its commit
  (`0.2.0+9731c5a428e2`).
