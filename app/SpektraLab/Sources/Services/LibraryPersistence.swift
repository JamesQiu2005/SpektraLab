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
            importedAt = "importedAt", pair = "pair", shotHere = "shotHere", cameraCropRead = "cameraCropRead"
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
    /// Shot by this app's camera. Absent for anything brought in, and in a library written
    /// before 2026-10-20.
    var shotHere: Bool? = nil
    /// The camera's crop has been read for it (`LibraryFrame.cameraCropRead`). Absent in a library
    /// written before 2026-11-05, and for a frame whose file has not been read since.
    var cameraCropRead: Bool? = nil

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
        pair = f.pair; shotHere = f.shotHere; cameraCropRead = f.cameraCropRead
    }

    var frame: LibraryFrame {
        LibraryFrame(id: id, fileName: fileName, captureDate: captureDate, camera: camera, exposure: exposure,
                     originalSize: originalSize, previewSize: previewSize, isRAW: isRAW, source: source,
                     original: original, assetIdentifier: assetIdentifier, picture: Self.ref(picture),
                     originalPicture: originalPicture.map(Self.ref),
                     developed: developed.map { DevelopedPicture(picture: Self.ref($0.picture), size: $0.size, stamp: $0.stamp) },
                     develop: .developed, isFavourite: isFavourite,
                     edit: edit, importedAt: importedAt, pair: pair, shotHere: shotHere, cameraCropRead: cameraCropRead)
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
@MainActor
final class LibraryPersistence {
    static let fileName = "library.json"
    let url: URL
    private var pending: Task<Void, Never>?

    init(url: URL = ImportService.root.appendingPathComponent(fileName)) {
        self.url = url
    }

    /// The library as it was kept; nil when there is none, or none this build can read. A file that
    /// does not decode is copied aside first (`KeptFileAside`): the empty library the next change
    /// writes then goes over the file, never over the only copy of the person's edits.
    func load() -> StoredLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.read(data)
        } catch {
            KeptFileAside.setAside(url, error: error)
            return nil
        }
    }

    /// `library.json` as `load` reads it: dates in ISO 8601.
    nonisolated static func read(_ data: Data) throws -> StoredLibrary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredLibrary.self, from: data)
    }

    /// Writes what is given, a second after the last call. A folder with no
    /// bookmark (the demo's) is not a folder of this host's and is left out.
    func save(_ frames: [LibraryFrame], folders: [LinkedFolder] = [], selectedID: UUID?) {
        let stored = StoredLibrary(frames: frames.filter { !$0.isDemo }.map(StoredFrame.init), selectedID: selectedID,
                                   folders: folders.filter { $0.bookmark != nil }.map(StoredFolder.init))
        let url = self.url
        pending?.cancel()
        pending = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            Self.write(stored, to: url)
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
        Self.write(StoredLibrary(frames: frames.filter { !$0.isDemo }.map(StoredFrame.init), selectedID: selectedID,
                                 folders: folders.filter { $0.bookmark != nil }.map(StoredFolder.init)), to: url)
    }

    nonisolated private static func write(_ stored: StoredLibrary, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
