//  LibraryPersistence.swift — the library on disk.
//
//  On a host the library is real (the owner, 2026-10-04: "wire everything but
//  the actual engine"): what the app keeps of each frame — its name, dates,
//  size, source, where its picture is, its edit — is written to
//  `Application Support/SpektraLab/library.json` after a change and read at
//  the next launch, so a shot is still there tomorrow. The originals and the
//  preview copies are the files already under the same folder.
//
//  - A picture under the app's own folder is kept as a path relative to it:
//    the folder's absolute path changes with every install of the app.
//  - A frame's develop *state* is not kept (a ring is the queue's, not the
//    library's), but its develop is: the picture's file and the stamp of what
//    it was made from (`DevelopedPicture`). At launch a frame whose kept
//    develop is missing or stale is queued again (`AppServices.developStale`).
//  - A frame of the demo library (`.sample`) is never written.
//  - Files under `Originals` that no frame names — shots taken by a build
//    before this one — are adopted at load (`ImportService.adoptOrphans`).
//  - A linked folder is kept with its security-scoped bookmark (2026-10-05):
//    at the next launch it is resolved and opened again, and the folder is
//    connected only when it answers; its frames are marked away otherwise.
//
//  The simulator, the snapshot harness and `--demo` keep the demo library in
//  memory, as before; `--first-run` is an empty library that writes nothing.

import Foundation

/// A frame as it is written.
struct StoredFrame: Codable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case id = "id", fileName = "fileName", captureDate = "captureDate", camera = "camera", exposure = "exposure",
            originalSize = "originalSize", previewSize = "previewSize", isRAW = "isRAW", source = "source",
            original = "original", assetIdentifier = "assetIdentifier", picture = "picture",
            originalPicture = "originalPicture", developed = "developed", isFavourite = "isFavourite", edit = "edit",
            importedAt = "importedAt", pair = "pair", double = "double", shotHere = "shotHere", cameraCropRead = "cameraCropRead",
            variant = "variant"
    }
    enum Picture: Codable {
        /// The keys as they are written: a case's name and its labels are keys, and must not move with a rename.
        enum CodingKeys: String, CodingKey { case relative = "relative", absolute = "absolute", sample = "sample" }
        enum RelativeCodingKeys: String, CodingKey { case _0 = "_0" }
        enum AbsoluteCodingKeys: String, CodingKey { case _0 = "_0" }
        enum SampleCodingKeys: String, CodingKey { case _0 = "_0" }
        /// Under `ImportService.root`.
        case relative(String)
        case absolute(URL)
        case sample(String)
    }

    var id: UUID
    var fileName: String
    var captureDate: Date
    var camera: String?
    var exposure: String?
    var originalSize: PixelSize
    var previewSize: PixelSize
    var isRAW: Bool
    var source: FrameOrigin
    var original: OriginalState
    /// Absent in a library written before 2026-10-05.
    var assetIdentifier: String? = nil
    var picture: Picture
    var originalPicture: Picture?
    /// The frame's kept develop. Absent in a library written before the engine was linked.
    var developed: Developed? = nil
    var isFavourite: Bool
    var edit: FrameEdit
    var importedAt: Date
    /// A half-frame pair's piece. Absent for a photograph, and in a library
    /// written before 2026-10-09.
    var pair: HalfFramePair? = nil
    /// A double exposure's piece (RFC-047 §2). Absent for a photograph or a pair, and in a library written
    /// before 2026-11-11: additive, a library from before reads with none.
    ///
    /// **Written only to `doubles.json`, never to `library.json`** (`LibraryShelf`, the older-build guard):
    /// 2.3.x reads `library.json` with no `double` key and would show the item as a photograph whose picture
    /// is the guide. It is read from either, so a library a development build put one in still opens.
    var double: DoubleExposure? = nil
    /// Shot by this app's camera. Absent for anything brought in, and in a library written
    /// before 2026-10-20.
    var shotHere: Bool? = nil
    /// The camera's crop has been read for it (`LibraryFrame.cameraCropRead`). Absent in a library
    /// written before 2026-11-05, and for a frame whose file has not been read since.
    var cameraCropRead: Bool? = nil
    /// The helper's variant uuid of the image this frame is a variant's edit of (`LibraryFrame.variant`, PRD-G). Absent
    /// for an image's primary variant — every frame a library written before 2026-11-13 has, so it reads unchanged —
    /// and never written then (an Optional is encoded only when present). A build before it reads the key as nothing:
    /// it would show such a frame as a second frame of the file, and join the file's row to whichever it indexed last.
    var variant: String? = nil

    struct Developed: Codable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case picture = "picture", size = "size", stamp = "stamp" }
        var picture: Picture
        var size: PixelSize
        var stamp: String
    }

    static func picture(_ ref: PictureRef) -> Picture {
        switch ref {
        case .sample(let name): return .sample(name)
        // A develop in memory is a page's, never a frame's: nothing to write.
        case .rendered: return .sample("")
        case .file(let url):
            let root = ImportService.root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path.hasPrefix(root + "/") { return .relative(String(path.dropFirst(root.count + 1))) }
            return .absolute(url)
        }
    }

    static func ref(_ picture: Picture) -> PictureRef {
        switch picture {
        case .sample(let name): .sample(name)
        case .absolute(let url): .file(url)
        case .relative(let path): .file(ImportService.root.appendingPathComponent(path))
        }
    }

    init(_ f: LibraryFrame) {
        id = f.id; fileName = f.fileName; captureDate = f.captureDate; camera = f.camera; exposure = f.exposure
        originalSize = f.originalSize; previewSize = f.previewSize; isRAW = f.isRAW; source = f.source
        original = f.original; assetIdentifier = f.assetIdentifier
        picture = Self.picture(f.picture); originalPicture = f.originalPicture.map(Self.picture)
        developed = f.developed.map { Developed(picture: Self.picture($0.picture), size: $0.size, stamp: $0.stamp) }
        isFavourite = f.isFavourite; edit = f.edit; importedAt = f.importedAt
        pair = f.pair; double = f.double; shotHere = f.shotHere; cameraCropRead = f.cameraCropRead
        variant = f.variant
    }

    var frame: LibraryFrame {
        var f = LibraryFrame(id: id, fileName: fileName, captureDate: captureDate, camera: camera, exposure: exposure,
                     originalSize: originalSize, previewSize: previewSize, isRAW: isRAW, source: source,
                     original: original, assetIdentifier: assetIdentifier, picture: Self.ref(picture),
                     originalPicture: originalPicture.map(Self.ref),
                     developed: developed.map { DevelopedPicture(picture: Self.ref($0.picture), size: $0.size, stamp: $0.stamp) },
                     develop: .developed, isFavourite: isFavourite,
                     edit: edit, importedAt: importedAt, pair: pair, double: double, shotHere: shotHere, cameraCropRead: cameraCropRead)
        f.variant = variant
        return f
    }
}

/// A linked folder as it is written: its bookmark is the way back.
struct StoredFolder: Codable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case id = "id", volume = "volume", path = "path", kind = "kind", frameCount = "frameCount",
            stillInCloud = "stillInCloud", keepsLocalCopy = "keepsLocalCopy", bookmark = "bookmark",
            location = "location"
    }
    var id: UUID
    var volume: String
    var path: String
    var kind: LinkedFolder.Kind
    var frameCount: Int
    var stillInCloud: Int
    var keepsLocalCopy: Bool
    var bookmark: Data?
    /// Where it was last seen (`LinkedFolder.location`). Absent in a library written before 2026-10-21.
    var location: [String]? = nil

    init(_ f: LinkedFolder) {
        id = f.id; volume = f.volume; path = f.path; kind = f.kind; frameCount = f.frameCount
        stillInCloud = f.stillInCloud; keepsLocalCopy = f.keepsLocalCopy; bookmark = f.bookmark
        location = f.location
    }

    /// The folder, not yet reached: connected only once its bookmark answers.
    var folder: LinkedFolder {
        LinkedFolder(id: id, volume: volume, path: path, kind: kind, frameCount: frameCount, isConnected: false,
                     stillInCloud: stillInCloud, keepsLocalCopy: keepsLocalCopy, bookmark: bookmark, location: location)
    }
}

struct StoredLibrary: Codable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion", frames = "frames", selectedID = "selectedID", folders = "folders"
    }
    var schemaVersion = 1
    var frames: [StoredFrame]
    var selectedID: UUID?
    /// Absent in a library written before 2026-10-05.
    var folders: [StoredFolder]? = nil
}

/// Reads the library once, and writes it after changes — a moment after the
/// last of a burst, on a background queue, atomically.
///
/// **Two files** since 2026-11-11 (`LibraryShelf`): `library.json`, every
/// photograph and pair, which every build reads; and `doubles.json` beside it, the double exposures,
/// which a build before them never opens — so 2.3.x shows the library without them rather than each as
/// a broken photograph, and never writes over them. **Three** since 2026-11-13 (PRD-G): `variants.json`, the frames
/// of an image's other variants (`LibraryFrame.variant`), kept from 2.3.x the same way (`LibraryShelf`): 2.3.2 would
/// drop their `variant` at its next save and the picture would show another variant's edit.
@MainActor
final class LibraryPersistence {
    static let fileName = "library.json"
    let url: URL
    /// The double exposures' own file (`LibraryShelf.doublesURL`).
    let doublesURL: URL
    /// The mask layers' own record (`LayerShelf.url`, PRD-E): every frame's layers, which `library.json` never holds.
    let layersURL: URL
    /// The variants' frames' own file (`LibraryShelf.variantsURL`).
    let variantsURL: URL
    private var pending: Task<Void, Never>?
    /// The items of `doubles.json` this build did not read (a later build's), written back as they were
    /// (`LibraryShelf.read`); and whether the file was there and did not read at all, so that it is not
    /// written over (`LibraryShelf.writes`). Both as `load` found them, for the rest of the launch.
    private var unreadDoubles: [ShelfJSON] = []
    private var doublesUnreadable = false
    /// `layers.json`'s entries this build did not read, and whether the file did not read at all (`LayerShelf`).
    private var unreadLayers: [UUID: ShelfJSON] = [:]
    private var layersUnreadable = false
    /// The same for `variants.json`.
    private var unreadVariants: [ShelfJSON] = []
    private var variantsUnreadable = false

    init(url: URL = ImportService.root.appendingPathComponent(fileName)) {
        self.url = url
        doublesURL = LibraryShelf.doublesURL(beside: url)
        layersURL = LayerShelf.url(beside: url)
        variantsURL = LibraryShelf.variantsURL(beside: url)
    }

    /// The library as it was kept; nil when there is none, or none this build can read. A file that
    /// does not decode is copied aside first (`KeptFileAside`): the empty library the next change
    /// writes then goes over the file, never over the only copy of the person's edits.
    ///
    /// The double exposures of `doubles.json` follow `library.json`'s frames, **each read by itself**
    /// (`LibraryShelf.read`): one this build cannot read is not shown and is written back as it was. A
    /// `doubles.json` that does not read at all shows none, is copied aside and is not written over.
    func load() -> StoredLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var stored: StoredLibrary
        do {
            stored = try Self.read(data)
        } catch {
            KeptFileAside.setAside(url, error: error)
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shelf = LibraryShelf.read(try? Data(contentsOf: doublesURL), as: StoredFrame.self, with: decoder)
        unreadDoubles = shelf.unread
        doublesUnreadable = shelf.unreadable
        if shelf.unreadable {
            let aside = LibraryShelf.setAside(doublesURL)
            Log.warn(.library, "doubles.json does not read: kept as it is, not written over",
                     ["aside": aside?.lastPathComponent ?? "nowhere"])
        }
        if !shelf.unread.isEmpty {
            Log.warn(.library, "doubles.json: double exposures this build does not read, kept", ["count": shelf.unread.count])
        }
        stored.frames = LibraryShelf.joined(stored.frames, shelf.frames.filter { $0.double != nil }, id: \.id)
        // The variants' frames, the same way. A library that kept them inside `library.json` (this branch's, before the
        // shelf) is read from there, once: `library.json` comes first in the join, and the next write moves them.
        let variants = LibraryShelf.read(try? Data(contentsOf: variantsURL), as: StoredFrame.self, with: decoder)
        unreadVariants = variants.unread
        variantsUnreadable = variants.unreadable
        if variants.unreadable {
            let aside = LibraryShelf.setAside(variantsURL)
            Log.warn(.library, "variants.json does not read: kept as it is, not written over",
                     ["aside": aside?.lastPathComponent ?? "nowhere"])
        }
        if !variants.unread.isEmpty {
            Log.warn(.library, "variants.json: variants' frames this build does not read, kept", ["count": variants.unread.count])
        }
        stored.frames = LibraryShelf.joined(stored.frames, variants.frames.filter { $0.variant != nil }, id: \.id)
        // The mask layers, from their own record (`LayerShelf`): put into each frame's edit by its id.
        let layers = LayerShelf.read(try? Data(contentsOf: layersURL))
        unreadLayers = layers.unread
        layersUnreadable = layers.unreadable
        if layers.unreadable {
            let aside = LayerShelf.setAside(layersURL)
            Log.warn(.library, "layers.json does not read: kept as it is, not written over", ["aside": aside?.lastPathComponent ?? "nowhere"])
        }
        if !layers.unread.isEmpty {
            Log.warn(.library, "layers.json: layers this build does not read, kept", ["count": layers.unread.count])
        }
        stored.frames = LayerShelf.joined(stored.frames, layers, id: \.id, edit: \.edit)
        return stored
    }

    /// `library.json` as `load` reads it: dates in ISO 8601.
    nonisolated static func read(_ data: Data) throws -> StoredLibrary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredLibrary.self, from: data)
    }

    /// Writes what is given, a second after the last call. A folder with no
    /// bookmark (the demo's) is not a folder of this host's and is left out.
    ///
    /// The frames are mapped to their stored form when the second is up, not at each call (2026-11-11): a slider
    /// dragged on a develop page changes the frame at every write, and mapping every frame of the library each
    /// time was main-thread work for a file written once a second later — 4 % of the main thread in a sampled
    /// Brightness drag on a library of two frames, growing with the library.
    func save(_ frames: [LibraryFrame], folders: [LinkedFolder] = [], selectedID: UUID?) {
        let url = self.url, doublesURL = self.doublesURL, variantsURL = self.variantsURL, layersURL = self.layersURL
        pending?.cancel()
        // Unsaved for that second: a quit then writes it first (`AppServices.settleForQuit`, on entering the
        // background, which a Catalyst quit passes through: `flush`, `saveNow`).
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let stored = self.stored(frames, folders: folders, selectedID: selectedID)
            await Task.detached(priority: .utility) {
                Self.write(stored, to: url, doublesTo: doublesURL, variantsTo: variantsURL, layersTo: layersURL)
            }.value
        }
    }

    /// Writes what is given now, before returning: for a change whose files
    /// are about to go — frames removed — so that the library on disk never
    /// names a file that is no longer there. Written a second later, an app
    /// ended in that second came back with the removed frames and none of
    /// their pictures.
    func saveNow(_ frames: [LibraryFrame], folders: [LinkedFolder] = [], selectedID: UUID?) {
        pending?.cancel()
        pending = nil
        Self.write(stored(frames, folders: folders, selectedID: selectedID), to: url, doublesTo: doublesURL, variantsTo: variantsURL,
                   layersTo: layersURL)
    }

    /// What is written, split by file (`LibraryShelf.split`): the photographs, pairs and every image's primary variant
    /// for `library.json`; the double exposures for `doubles.json`; the other variants' frames for `variants.json` — in
    /// each shelf the ones this build reads, then the ones it kept unread.
    ///
    /// The mask layers are taken out of every edit first — a variant's and a double's too — and kept in their own
    /// record (`LayerShelf`): none of the three files ever carries them, so no older build's coder can drop them.
    private func stored(_ frames: [LibraryFrame], folders: [LinkedFolder], selectedID: UUID?) -> StoredFiles {
        let (bare, record, madeLayers) = LayerShelf.split(frames.filter { !$0.isDemo }.map(StoredFrame.init), unread: unreadLayers,
                                                          id: \.id, edit: \.edit)
        let (rest, doubles) = LibraryShelf.split(bare, isDouble: { $0.double != nil })
        let (kept, variants) = LibraryShelf.split(rest, isDouble: { $0.variant != nil })
        return StoredFiles(library: StoredLibrary(frames: kept, selectedID: selectedID,
                                                  folders: folders.filter { $0.bookmark != nil }.map(StoredFolder.init)),
                           doubles: .init(items: doubles.map { ShelfItem.read($0) } + unreadDoubles.map { .unread($0) },
                                          made: doubles.count, unreadable: doublesUnreadable),
                           variants: .init(items: variants.map { ShelfItem.read($0) } + unreadVariants.map { .unread($0) },
                                           made: variants.count, unreadable: variantsUnreadable),
                           layers: record, madeLayers: madeLayers, layersUnreadable: layersUnreadable)
    }

    /// One shelf file's contents, and what decides whether it is written (`LibraryShelf.writes`).
    private struct Shelf {
        var items: [ShelfItem<StoredFrame>]
        var made: Int
        var unreadable: Bool
    }

    /// The four files' contents: the library, its two shelves, and the layers' record with what decides whether it is
    /// written (`LayerShelf.writes`).
    private struct StoredFiles {
        var library: StoredLibrary
        var doubles: Shelf
        var variants: Shelf
        var layers: LayerShelf.Record
        var madeLayers: Int
        var layersUnreadable: Bool
    }

    /// `doubles.json` first, then `library.json`, each atomically (`LibraryShelf`: what an app ended between
    /// the two leaves). A library with no double exposure and no `doubles.json` makes none: the library on
    /// disk of someone who never made one is the one file it was.
    nonisolated private static func write(_ stored: StoredFiles, to url: URL, doublesTo doublesURL: URL, variantsTo variantsURL: URL,
                                          layersTo layersURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The layers' record first (`LayerShelf`): an app ended before `library.json` leaves layers a step ahead of
        // their edit, never an edit whose layers are gone.
        if LayerShelf.writes(entries: stored.layers.frames.count, made: stored.madeLayers,
                             fileExists: FileManager.default.fileExists(atPath: layersURL.path), unreadable: stored.layersUnreadable),
           let data = LayerShelf.encode(stored.layers) {
            try? data.write(to: layersURL, options: .atomic)
        }
        // The shelves next, then `library.json`: an app ended between them leaves a shelf one change newer, never a
        // variant's frame on no file at all (it would be read from neither).
        for (shelf, file) in [(stored.doubles, doublesURL), (stored.variants, variantsURL)] {
            if LibraryShelf.writes(doubles: shelf.made, unread: shelf.items.count - shelf.made,
                                   fileExists: FileManager.default.fileExists(atPath: file.path), unreadable: shelf.unreadable),
               let data = try? encoder.encode(StoredDoubles(frames: shelf.items)) {
                try? data.write(to: file, options: .atomic)
            }
        }
        guard let data = try? encoder.encode(stored.library) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // A kept folder is asked for again through its bookmark by `FolderReach.check` (2026-10-21; it was
    // `reach` here), at launch and at every check since (`FrameCatalog.recheckFolders`).

    /// What the app keeps on the device, measured: the copied-in originals,
    /// the working copies of originals that stay in Photos (`WorkingCopies`),
    /// what is under `Previews` — a preview copy, each frame's kept develop, a
    /// pair's guide — and the caches.
    nonisolated static func storageReport(previous: StorageReport) -> StorageReport {
        var report = previous
        report.copiedInOriginals = size(of: ImportService.originals)
        report.copiedInFrames = 0
        report.workingCopies = size(of: ImportService.workingCopies)
        report.previewCopies = size(of: ImportService.previews)
        report.cache = cacheFolders.reduce(Int64(0)) { $0 + size(of: $1) }
        return report
    }

    /// The app's own caches, as the Storage page counts them. On the window and reference device the user domain's
    /// Caches folder is the app's own (the sandbox's). Mac change (PAGES.md,
    /// 2026-10-24): the Mac app is not sandboxed, so that folder is `~/Library/Caches`, every app's, and
    /// Storage said 6.4 GB of other apps' caches were SpektraLab's "Thumbnails and cache" (the owner:
    /// "they should be resting within those places and respect the set upper limit"). On the Mac they
    /// are the folders named for this app: `~/Library/Caches/<bundle id>` and the system's per-app cache
    /// (`DARWIN_USER_CACHE_DIR/<bundle id>`: Metal's and Core Image's compiled shaders, which macOS keeps
    /// and rebuilds). Thumbnails themselves are held in memory only (`ThumbnailStore`), within its bytes.
    nonisolated static var cacheFolders: [URL] {
        let fm = FileManager.default
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        var folders = fm.urls(for: .cachesDirectory, in: .userDomainMask).first.map { [$0.appending(path: id)] } ?? []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            folders.append(URL(fileURLWithPath: String(cString: buffer)).appending(path: id))
        }
        return folders
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
