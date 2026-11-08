//  MacLibraryModels.swift — what the Mac's library views read (MAC-LIBRARY-DATA.md).
//
//  The Mac's library is Capture One-*inspired*: sources (SpektraLab catalogs and sessions, Capture
//  One catalogs and sessions read one way, folders linked from Finder, and the window library's own
//  frames), a collection tree per source laid out as Capture One's Library tool is (the fixed rows,
//  Recent Imports, the user's collections, Folders), the images of a collection as dense-grid rows,
//  and filter facets with counts. These are value types only; `CatalogSourcesStore` fills them and the
//  `MacLibraryData` protocol is what a view binds to.

import Foundation

// MARK: - sources

/// A place the library reads: one row of the sources list.
struct MacSource: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// The window library's own frames on this Mac: copied in, and the window's linked folders. Since
        /// 2026-10-24 never listed on the Mac: the SpektraLab Library is the person's `.spkcatalog`s
        /// (`MacLibraryMove` moves these frames' files into one). Kept so an old sources list still reads.
        case appLibrary = "appLibrary"
        /// A SpektraLab catalog, `<Name>.spkcatalog`: a managed library, files referenced or copied in.
        case catalog = "catalog"
        /// A SpektraLab session: a folder (`Capture`, `Selects`, `Output`, `Trash`) and its `.spksession`.
        case session = "session"
        /// A Capture One catalog, `<Name>.cocatalog`, read one way through a snapshot.
        case captureOneCatalog = "captureOneCatalog"
        /// A Capture One session folder, read one way: its folders, never its `.cosessiondb` or `.cos` files.
        case captureOneSession = "captureOneSession"
        /// A Finder folder, referenced where it is and kept in step.
        case folder = "folder"
    }

    enum Status: Hashable, Sendable {
        case unknown
        case ready
        /// Its disk is away (a folder, a catalog's package): what was read is still listed.
        case offline
        /// Capture One is writing to its catalog; the next sync tries again.
        case busy
        /// Another SpektraLab has the session open.
        case inUse
        case failed(String)
    }

    let id: UUID
    var kind: Kind
    var name: String
    /// What the person picked: the `.spkcatalog`, the session folder, the `.cocatalog`, the Capture One
    /// session folder, the Finder folder. Nil for the app library.
    var path: String?
    /// The helper's library behind it (`spklib`): the same as `path` for a SpektraLab catalog or session;
    /// the mirror `Libraries/Linked/<document UUID>.spkcatalog` for a Capture One catalog (known once
    /// linked); a catalog of the app's own under `Libraries/Sources/` for a Capture One session or a folder.
    var libraryPath: String?
    var addedAt: Date
    var openedAt: Date?
    /// A SpektraLab catalog copied from a Capture One catalog (*Copy to SpektraLab Catalog…*, spklib
    /// 0.3.0): where from, and when it was last updated. Kept, and read again each time it opens.
    var copiedFrom: MacCopiedFrom?

    // Not kept: found again at each look.
    var status: Status = .unknown
    var imageCount: Int?
    var syncedAt: Date?
    /// "16.8.6.25 Pro Mac" for a Capture One catalog.
    var format: String?

    enum CodingKeys: String, CodingKey {
        case id = "id", kind = "kind", name = "name", path = "path", libraryPath = "libraryPath", addedAt = "addedAt",
            openedAt = "openedAt", copiedFrom = "copiedFrom"
    }

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    /// Capture One's own file is read one way: nothing is ever written to the `.cocatalog` or a session.
    /// What SpektraLab keeps about its pictures (ratings, labels, imports) is kept in the mirror, so on
    /// the person's side a Capture One catalog works as a SpektraLab one does (the owner, 2026-10-24).
    var isReadOnly: Bool { kind == .captureOneCatalog || kind == .captureOneSession }
    /// A referenced folder can be added and kept in step (Capture One's own library is Capture One's).
    var acceptsFolders: Bool { kind == .catalog || kind == .session }
    /// Files can be imported into it, by reference or by copy. A Capture One catalog's go into its mirror
    /// (SpektraLab's own rows, a Recent Imports album of SpektraLab's: spklib 0.2.1); Capture One's file is
    /// not touched.
    var acceptsImports: Bool { kind == .catalog || kind == .session || kind == .captureOneCatalog }
    /// What an import does unless told otherwise (Capture One's defaults): a catalog references the
    /// files where they are; a session copies them into its Capture folder.
    var defaultImport: MacImportMode { kind == .session ? .copy : .reference }
    var isHelperBacked: Bool { kind != .appLibrary }
    /// *Update from Capture One* applies: a SpektraLab catalog made by *Copy to SpektraLab Catalog…*.
    var isCopiedFromCaptureOne: Bool { kind == .catalog && copiedFrom != nil }
}

/// Where a copied catalog came from (`library.info`'s `copied_from`, spklib 0.3.0).
struct MacCopiedFrom: Codable, Hashable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case path = "path", format = "format", copiedAt = "copiedAt", updatedAt = "updatedAt"
    }
    /// The `.cocatalog` it was copied from.
    var path: String?
    var format: String?
    var copiedAt: Date?
    var updatedAt: Date?

    /// The last time it took Capture One's changes: the update, else the copy.
    var lastTaken: Date? { updatedAt ?? copiedAt }
}

/// What *Copy to SpektraLab Catalog…* made.
struct MacCopyReport: Sendable, Equatable {
    var source: MacSource
    var images = 0
    var variants = 0
    var collections = 0
    var folders = 0
    var keywords = 0
    var albumMembers = 0
    var warnings: [String] = []
    var ms = 0.0
}

/// What *Update from Capture One* took in.
struct MacUpdateReport: Sendable, Equatable {
    var skipped = false
    var added = 0
    var updated = 0
    var unchanged = 0
    var gone = 0
    var collections = 0
    var folders = 0
    var members = 0
    /// Where both changed and SpektraLab's was kept (the owner: on an update SpektraLab wins).
    var conflictsKept = 0
    var warnings: [String] = []
    var ms = 0.0
}

enum MacImportMode: String, Codable, Sendable {
    /// Where they are: nothing is copied (Capture One's "Current Location").
    case reference
    /// Into the library: a catalog's `Originals/yyyy/mm/dd`, a session's `Capture` ("Inside Catalog").
    case copy
}

// MARK: - collections

struct MacCollection: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case allImages, recentImports, recentCaptures, trash, inLibrary
        case project, group, album, smartAlbum, folder
        case other(String)

        init(helper kind: String) {
            switch kind {
            case "all_images": self = .allImages
            case "recent_imports": self = .recentImports
            case "recent_captures": self = .recentCaptures
            case "trash": self = .trash
            case "in_library": self = .inLibrary
            case "project": self = .project
            case "group": self = .group
            case "album", "variant_album": self = .album
            case "smart_album": self = .smartAlbum
            case "folder": self = .folder
            default: self = .other(kind)
            }
        }

        /// A row of the Library tool's top: All Images, Recent Imports, Recent Captures, Trash, In Catalog.
        var isFixed: Bool {
            switch self {
            case .allImages, .recentImports, .recentCaptures, .trash, .inLibrary: true
            default: false
            }
        }
    }

    /// The helper's collection uuid (Capture One's own for a mirror), or the app library's own id.
    let id: String
    var parentID: String?
    var kind: Kind
    /// What to show. A fixed row's is an English placeholder ("All Images"; Capture One's are in its UI
    /// language, "全部图像"): a view names fixed rows by `kind`, in the app's own words.
    var title: String
    /// Images not in the trash; nil where it cannot be counted (Capture One's smart albums).
    var imageCount: Int?
    /// When it was made: a Recent Imports album's import time.
    var createdAt: Date?
    var folder: URL?
    /// SpektraLab's own album, group, project or smart album: renamed, deleted, dropped on.
    var isEditable: Bool
    var isCaptureOne: Bool
    /// False for a Capture One smart album: its criteria are kept, not evaluated.
    var isSupported = true
    var children: [MacCollection] = []
}

/// One source's collections, as Capture One's Library tool lays them out.
struct MacCollectionTree: Equatable, Sendable {
    /// All Images, Recent Imports (each import a child, newest first), Recent Captures, Trash, In Catalog.
    var fixed: [MacCollection] = []
    /// Projects, groups, albums and smart albums, nested.
    var user: [MacCollection] = []
    /// The folder tree, nested by path.
    var folders: [MacCollection] = []

    static let empty = MacCollectionTree()

    var all: [MacCollection] {
        func flat(_ c: [MacCollection]) -> [MacCollection] { c.flatMap { [$0] + flat($0.children) } }
        return flat(fixed) + flat(user) + flat(folders)
    }

    func find(_ id: MacCollection.ID?) -> MacCollection? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The row a source opens on: All Images.
    var defaultSelection: MacCollection.ID? { fixed.first { $0.kind == .allImages }?.id ?? all.first?.id }
}

// MARK: - images

/// Capture One's seven colour tags, by its index (`ZCOLOR_TAG_INDEX`) — the order its menu lists them.
/// Not checked against a tagged image: the owner's catalog has none.
enum MacColorLabel: Int, CaseIterable, Codable, Hashable, Sendable {
    /// An explicit No Label override. nil hands a Capture One row back to its source value.
    case unlabelled = 0
    case red = 1, orange = 2, yellow = 3, green = 4, blue = 5, pink = 6, purple = 7
}

struct MacImage: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let source: MacSource.ID
        /// The helper's image uuid (Capture One's for a mirror), or a frame's id in the app library.
        let image: String
    }

    /// `pair`: a half-frame pair's file in the app's storage (spklib 0.3.1, `MacPairRows.swift`).
    enum FileKind: String, Sendable {
        case raw = "raw", raster = "raster", movie = "movie", pair = "pair", other = "other"
    }

    let id: ID
    let url: URL
    let fileName: String
    let kind: FileKind
    /// The camera's wall clock, no zone (`2024-01-08T23:39:04`), as stored.
    let capturedLocal: String?
    /// The same wall clock as a `Date` in this Mac's time zone, for formatting and sorting only.
    let captureDate: Date?
    var rating: Int
    var colorLabel: MacColorLabel?
    let cameraMake: String?
    let cameraModel: String?
    let lens: String?
    /// "1/250 s · f/5.6 · ISO 100".
    let exposure: String?
    let pixelSize: PixelSize?
    /// Its file is not where the library says (a disk away, moved, deleted).
    let isOffline: Bool
    let isTrashed: Bool
    /// Gone from a kept folder (listed only when asked).
    let isRemoved: Bool
    let fromCaptureOne: Bool
    /// The variant the grid shows, and how many the image has.
    let primaryVariant: String?
    let variantCount: Int
    /// What SpektraLab has made of it, once it has been opened in Develop.
    var develop: MacDevelopInfo?
}

/// SpektraLab's side of a picture: its frame in the app's library (where its edit is kept) and what
/// that frame's develop is.
struct MacDevelopInfo: Hashable, Sendable {
    enum State: Hashable, Sendable { case developed, inQueue, failed, notDeveloped }
    let frameID: LibraryFrame.ID
    /// The film and the paper the frame is set to (their names), nil with film emulation off.
    let film: String?
    let paper: String?
    let state: State
}

/// `image.get`, for an Info panel.
struct MacImageDetail: Sendable, Equatable {
    var image: MacImage
    var fileSize: Int?
    var albums: [String]
    var variants: [Variant]
    struct Variant: Sendable, Equatable, Identifiable {
        let id: String
        let position: Int
        let rating: Int
        let colorLabel: MacColorLabel?
        /// Capture One's own values beside SpektraLab's (a mirror only).
        let captureOneRating: Int?
        let captureOneColorLabel: MacColorLabel?
    }
}

// MARK: - the query and the facets

/// What the grid shows of the selected collection: its order and the facets' ticks.
struct MacImageQuery: Equatable, Sendable {
    enum Sort: String, CaseIterable, Sendable {
        case captureDate = "captured", fileName = "name", rating = "rating", importDate = "imported",
            addedDate = "added"
    }

    var sort: Sort = .captureDate
    var descending = false
    /// File or display name contains.
    var text = ""
    /// Any of these star counts (0 is "no stars").
    var ratings: Set<Int> = []
    var minimumRating: Int?
    /// Any of these labels; 0 is "no label".
    var colorLabels: Set<Int> = []
    var kinds: Set<MacImage.FileKind> = []
    /// `YYYY-MM-DD`, the camera's wall clock; `capturedTo` is exclusive.
    var capturedFrom: String?
    var capturedTo: String?
    /// Camera models; `nil` is "not known".
    var cameras: Set<String?> = []
    var lenses: Set<String?> = []
    var keywords: Set<String> = []
    /// Only pictures SpektraLab has made a frame of (opened in Develop).
    var developedOnly = false
    /// A folder's images and its subfolders' (Capture One shows a folder's own).
    var includeSubfolders = false

    var isFiltered: Bool {
        !text.isEmpty || !ratings.isEmpty || minimumRating != nil || !colorLabels.isEmpty || !kinds.isEmpty
            || capturedFrom != nil || capturedTo != nil || !cameras.isEmpty || !lenses.isEmpty || !keywords.isEmpty
            || developedOnly
    }

    /// Every tick off, the order kept.
    var cleared: MacImageQuery { MacImageQuery(sort: sort, descending: descending, includeSubfolders: includeSubfolders) }
}

/// The Filters tool: counts over the selected collection, each facet counted with every other tick
/// applied but its own (so ticking 3 stars still shows how many have 4).
struct MacFacets: Equatable, Sendable {
    struct Value<V: Hashable & Sendable>: Hashable, Sendable {
        let value: V
        let count: Int
    }

    var total = 0
    /// 5 … 0.
    var ratings: [Value<Int>] = []
    /// 0 (none) … 7.
    var colorLabels: [Value<Int>] = []
    var kinds: [Value<String>] = []
    /// "2026", "2026-10", "2026-10-03".
    var years: [Value<String>] = []
    var months: [Value<String>] = []
    var days: [Value<String>] = []
    var undated = 0
    /// Model, with its maker; nil model is "not known".
    var cameras: [Value<String?>] = []
    var cameraMakes: [String: String] = [:]
    var lenses: [Value<String?>] = []
    var keywords: [Value<String>] = []
    /// Pictures SpektraLab has made a frame of, in this collection.
    var developed = 0
    /// Files a folder sync found whose headers are still being read: their date, camera and lens fill in.
    var undescribed = 0

    static let empty = MacFacets()
}

// MARK: - what the store is doing

struct MacLibraryActivity: Equatable, Sendable {
    /// "Reading Capture One Catalog…", "Synchronizing Scans…"; nil when idle.
    var working: String?
    /// The last thing that went wrong, for a quiet line under the sidebar.
    var problem: String?
    /// The last sync of the selected source: what it found.
    var lastSync: String?
}

/// A referenced folder a catalog or session keeps in step.
struct MacWatchedFolder: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let collectionID: String?
    let isOnline: Bool
    let imageCount: Int
    let syncedAt: Date?
}

enum MacLibraryError: Error, LocalizedError, Equatable {
    case noSource
    case readOnly
    case offline(String)
    case unreadable(String)
    case notSupported(String)
    /// More pictures than one carry into Develop takes (`CatalogSourcesStore.carryLimit`).
    case tooMany
    /// More pictures than the Light Table holds (`LightTableModel`: 99).
    case tooManyForTable
    /// None of the chosen pictures may lie on the Light Table (`MacLightTableCarry.takes`).
    case notForTable

    var errorDescription: String? {
        switch self {
        case .noSource: "No library is selected."
        case .readOnly: "Capture One's library is read here, never changed."
        case .offline(let name): "\(name) is not reachable."
        case .unreadable(let name): "\(name) could not be read."
        case .notSupported(let why): why
        case .tooMany: "Choose 500 pictures or fewer to open in Develop."
        case .tooManyForTable: "Choose 99 pictures or fewer for the Light Table."
        case .notForTable: "Only pictures developed in SpektraLab go on the Light Table."
        }
    }
}

// MARK: - the import flow (2026-10-24)

/// One picture an import adds: its file, and what its header said (read once, by the import page's scan,
/// and passed to the helper, which never opens a picture).
struct MacImportFile: Sendable {
    let url: URL
    var header: LibraryDescription?
}

/// What a destination already holds, for *Exclude Duplicates*: each file's path (`CatalogSourcesStore.key`),
/// and its name with its size, which finds a copy of a file as well as the file itself.
struct MacImportExisting: Sendable, Equatable {
    var paths: Set<String> = []
    var namesAndSizes: Set<String> = []

    static func nameAndSize(_ name: String, _ size: Int) -> String { "\(name.precomposedStringWithCanonicalMapping)\u{0}\(size)" }

    func holds(path: String, name: String, size: Int?) -> Bool {
        if paths.contains(CatalogSourcesStore.key(path)) { return true }
        guard let size else { return false }
        return namesAndSizes.contains(Self.nameAndSize(name, size))
    }
}

/// What one chunk of an import did.
struct MacImportChunk: Sendable, Equatable {
    var added = 0
    /// Already in the library (the helper's own path check).
    var existing = 0
    /// The files the helper refused, with why.
    var failed: [String: String] = [:]
    /// The import's Recent Imports album: made by the first chunk that added anything.
    var album: String?
    /// The new images' helper uuids, by the path they were given as.
    var images: [String: String] = [:]
}

// MARK: - the protocol a view binds to

/// What the Mac's library views read and call. `CatalogSourcesStore` is the one implementation; a view
/// holds `any MacLibraryData` (or the store itself) and is redrawn by Observation as it changes.
@MainActor
protocol MacLibraryData: AnyObject, Observable {
    var sources: [MacSource] { get }
    var selectedSourceID: MacSource.ID? { get }
    var selectedSource: MacSource? { get }
    var tree: MacCollectionTree { get }
    var selectedCollectionID: MacCollection.ID? { get }
    var watchedFolders: [MacWatchedFolder] { get }
    var query: MacImageQuery { get }
    /// The loaded rows of the selected collection, in the query's order; `total` is how many there are.
    var images: [MacImage] { get }
    var total: Int { get }
    var facets: MacFacets { get }
    var activity: MacLibraryActivity { get }

    /// Reads the kept sources and opens the last one. Starts nothing until called.
    func start() async
    func select(source: MacSource.ID) async
    func select(collection: MacCollection.ID?) async
    func apply(_ query: MacImageQuery) async
    /// The next page of rows (`pageSize`), until `images.count == total`.
    func loadMore() async
    func loadAll() async

    func newCatalog(named name: String, in folder: URL) async throws -> MacSource
    func newSession(named name: String, in folder: URL) async throws -> MacSource
    /// A `.spkcatalog`, a SpektraLab session folder, a `.cocatalog`, a Capture One session folder, or
    /// any other folder (linked, kept in step).
    func open(_ url: URL) async throws -> MacSource
    /// A referenced folder into a SpektraLab catalog or session (nil: the selected one), kept in step.
    func addFolder(_ url: URL, to source: MacSource.ID?) async throws
    func stopWatching(_ folder: MacWatchedFolder.ID) async throws
    /// Files into a SpektraLab catalog or session; `mode` nil is the source's default. How many arrived.
    func importFiles(_ urls: [URL], into source: MacSource.ID?, mode: MacImportMode?) async throws -> Int
    /// Capture One's catalog read again if it changed; a folder's or session's files looked at again.
    func synchronize(_ source: MacSource.ID?) async
    /// Off the list; nothing on disk is deleted (an app-made mirror stays, to be found again).
    func remove(source: MacSource.ID)

    func detail(of image: MacImage.ID) async throws -> MacImageDetail
    /// Every helper source. On a Capture One catalog the value is SpektraLab's override in the mirror
    /// (the SDK's `meta.set`); Capture One's own file is never written. The app library has none.
    func setRating(_ rating: Int?, for images: [MacImage.ID]) async throws
    func setColorLabel(_ label: MacColorLabel?, for images: [MacImage.ID]) async throws
    /// 从 SpektraLab 中移除 into the source's 回收站, or 放回 out of it; nothing on disk moves.
    func setTrashed(_ trashed: Bool, for images: [MacImage.ID]) async throws
    /// From 回收站 only: the files to the system's Trash and their rows forgotten.
    func moveToSystemTrash(_ images: [MacImage.ID]) async throws
    /// The picture in the existing Develop page: its frame in the app's library, made the first time.
    func openInDevelop(_ image: MacImage.ID) async throws
    /// Develop on `focus`, its filmstrip `images` in that order instead of the whole app library.
    func openInDevelop(_ images: [MacImage.ID], focus: MacImage.ID) async throws
    /// The Light Table, with those of `images` it takes laid on it (`MacLightTableCarry.takes`: no frame
    /// is made for it); with none chosen, as it is.
    func putOnLightTable(_ images: [MacImage.ID]) async throws
    /// The pictures' frames in the app's library, made for those without (Develop's and Export's way in).
    func frames(for images: [MacImage.ID], focus: MacImage.ID?) async throws -> (frames: [MacImage.ID: LibraryFrame.ID], files: [URL])

    // The import flow (`Sources/Mac/Import/`, 2026-10-24).
    /// Every file a SpektraLab catalog or session holds, trashed ones included, for *Exclude Duplicates*.
    func existingFiles(in source: MacSource.ID) async throws -> MacImportExisting
    /// One chunk of an import into a SpektraLab catalog or session: by reference, or with `copyIntoLibrary`
    /// copied by the helper (a catalog's `Originals/yyyy/mm/dd`, a session's `Capture`). `album` nil makes
    /// the import's Recent Imports album (if anything is new); given, the chunk goes into it and makes none.
    func importChunk(_ files: [MacImportFile], into source: MacSource.ID, copyIntoLibrary: Bool,
                     album: String?) async throws -> MacImportChunk
    /// After an import: the destination selected, its tree read again, and the import's album shown.
    func showImport(in source: MacSource.ID, album: String?) async

    // The SpektraLab Library as catalogs (2026-10-24, the owner: "fully managed by a .cocatalog-style
    // .spkcatalog").
    /// The once-only move of the app library's frames into a `.spkcatalog` (`Sources/Mac/Migration/`).
    var move: MacLibraryMove { get }
    /// A new, empty SpektraLab catalog at `url` (a save panel's choice; `.spkcatalog` added if missing), selected.
    func newCatalog(at url: URL) async throws -> MacSource
    /// *Copy to SpektraLab Catalog…*: a Capture One catalog source copied (spklib 0.3.0
    /// `capture_one.copy`, its mirror's SpektraLab ratings and labels with it) into a new `.spkcatalog` at
    /// `url`, listed and selected. The Capture One source stays on the list.
    func copyCaptureOne(_ source: MacSource.ID, to url: URL) async throws -> MacCopyReport
    /// *Update from Capture One* on a copied catalog (nil: the selected one): `capture_one.update`,
    /// SpektraLab's changes winning; its counts said in the activity line; the tree and rows read again.
    func updateFromCaptureOne(_ source: MacSource.ID?) async throws -> MacUpdateReport
}
