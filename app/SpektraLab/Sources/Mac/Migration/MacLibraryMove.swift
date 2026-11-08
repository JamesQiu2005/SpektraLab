//  MacLibraryMove.swift — the SpektraLab Library becomes a catalog, once (2026-10-24).
//
//  The owner: "I thought the SpektraLab library is actually going to be fully managed by a
//.cocatalog-style .spkcatalog", placed where the person wants ("we do not limit where this
//.spkcatalog is stored"), and there may be several. Until now the Mac's "SpektraLab Library" source
//  was the window library's frames with a tree made in Swift, and no ratings, labels or facets of its own.
//
//  The move takes every frame of that library into a new `.spkcatalog`, by reference, read in place:
//  - each frame's file where it is: the app's copied-in `Originals/` (never moved), the window's linked
//    folders' files, the pictures the Mac library made frames of;
//  - each import (the frames that arrived in one minute, as the old tree grouped them) as a Recent
//    Import of its own, oldest first, named with its time (and timed with it, from spklib 0.3.0's
//    `recent_import_at`; a helper before ignores the key and the album is renamed here);
//  - the Favourites as an album, and the window's linked folders as the catalog's kept folders
//    (`folders.add`).
//  The frames themselves stay where they are, with their edits and kept develops: a catalog's row finds
//  its frame by its file's path, as for any catalog (MAC-LIBRARY-DATA §6.2).
//
//  What was moved is recorded (`MacLibrary/moved.json`): each move's catalog, its frames and those left
//  out with why; and every frame the Mac library has made since from a catalog's picture
//  (`noteInCatalog`), which is in a catalog already. A frame in neither is "of the old app library",
//  and only while there is one is the move offered: so it is offered once, and never again for those
//  frames. *Not now* puts it off until the next launch (Settings › Sources offers it meanwhile).

import Foundation
import Observation

@MainActor
@Observable
final class MacLibraryMove {
    enum Phase: Equatable {
        /// Nothing to move, or put off (*Not now*).
        case idle
        /// The page is up, asking.
        case offered
        case running
        case done(Outcome)
        case failed(String)
    }

    struct Outcome: Equatable {
        var catalog: URL
        var source: MacSource.ID
        /// Frames whose files are in the catalog now (added, or there already).
        var moved = 0
        /// Frames left out (no file, the file gone), with why.
        var left: [LibraryFrame.ID: String] = [:]
        var imports = 0
        var favourites = 0
        var folders = 0
        var seconds = 0.0
    }

    private(set) var phase: Phase = .idle
    /// The move's page is up (asking, moving, or saying how it went).
    var showsPage: Bool { phase != .idle }
    /// Files done of all of them, while running.
    private(set) var done = 0
    private(set) var total = 0
    /// The frames the move would take: of the old app library, in no catalog yet.
    private(set) var candidates: [LibraryFrame.ID] = []
    /// Where the catalog goes: `~/Pictures/SpektraLab Library.spkcatalog` by default (a name already
    /// taken becomes "… 2"), changed in a save panel.
    var destination: URL

    @ObservationIgnored private weak var store: CatalogSourcesStore?
    @ObservationIgnored private weak var model: AppServices?
    @ObservationIgnored private var putOff = false

    init(store: CatalogSourcesStore, model: AppServices?) {
        self.store = store
        self.model = model
        let pictures = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Pictures")
        destination = pictures.appending(path: MacImportSession.freeName("SpektraLab Library", in: pictures) + ".spkcatalog")
    }

    /// The files' batch: one `images.add` each (the import flow's chunk).
    nonisolated static let chunk = 200

    // MARK: - what is offered

    /// The record read and the frames counted again; the page offered if there are any (and the move has
    /// not been put off in this launch). Called at the store's start.
    func evaluate() {
        candidates = Self.candidates(model?.library.frames ?? [], record: Self.readRecord())
        if case .running = phase { return }
        phase = !candidates.isEmpty && !putOff ? .offered : .idle
    }

    /// The frames of the app library a move takes: with a file of their own (not a demo, not a half-frame
    /// pair, which is made of two frames and gets a row of its own, `MacPairRows.swift`), and in no catalog by the record.
    nonisolated static func candidates(_ frames: [LibraryFrame], record: Record) -> [LibraryFrame.ID] {
        let known = record.known
        return frames.filter { !$0.isDemo && !$0.isPair && $0.picture.fileURL != nil && !known.contains($0.id) }.map(\.id)
    }

    /// *Not now*: put off until the next launch.
    func notNow() {
        putOff = true
        phase = .idle
    }

    /// Asked for again (Settings › Sources), while there is anything to move.
    func offer() {
        putOff = false
        evaluate()
    }

    /// The page closed after a move or a failure.
    func dismiss() {
        if case .running = phase { return }
        phase = .idle
    }

    /// Back to asking after a failure, with a destination not taken (a failed move may have left its
    /// catalog behind, on the list, with what it took).
    func retry() {
        let folder = destination.deletingLastPathComponent()
        destination = folder.appending(path: MacImportSession.freeName(destination.deletingPathExtension().lastPathComponent, in: folder)
                                       + ".spkcatalog")
        phase = candidates.isEmpty ? .idle : .offered
    }

    /// Frames the Mac library just made from a catalog's pictures: in a catalog already.
    func noteInCatalog(_ ids: [LibraryFrame.ID]) {
        guard !ids.isEmpty else { return }
        var r = Self.readRecord()
        let before = r.inCatalog.count
        r.inCatalog.formUnion(ids)
        guard r.inCatalog.count != before else { return }
        Self.write(r)
        candidates.removeAll { ids.contains($0) }
    }

    // MARK: - the move

    /// Moves the candidates' files into a new catalog at `destination`, then selects it.
    func run() async {
        guard let store, let library = model?.library else { return }
        if case .running = phase { return }
        let began = ContinuousClock.now
        evaluate()
        let frames = candidates.compactMap { library.frame($0) }
        phase = .running
        done = 0
        total = frames.count
        var outcome: Outcome
        let client = store.client
        do {
            let target = CatalogSourcesStore.catalogURL(destination)
            let (catalog, h) = try await store.makeCatalog(at: target, select: false)
            outcome = Outcome(catalog: catalog.url ?? target, source: catalog.id)
            var imageOf: [LibraryFrame.ID: String] = [:]

            // The imports, oldest first, each a Recent Import of its own.
            let byMinute = Dictionary(grouping: frames) { Int($0.importedAt.timeIntervalSince1970 / 60) }
            for minute in byMinute.keys.sorted() {
                let group = byMinute[minute] ?? []
                let at = Date(timeIntervalSince1970: Double(minute) * 60)
                var album: String?
                for start in stride(from: 0, to: group.count, by: Self.chunk) {
                    let part = Array(group[start..<min(start + Self.chunk, group.count)])
                    let urls = part.compactMap(\.picture.fileURL)
                    // The headers, off the main thread: the helper never opens a picture.
                    let items = await Task.detached(priority: .userInitiated) {
                        urls.map { url -> LibraryClient.AddItem in
                            let d = MacHeaders.readIfReadable(url)
                            return LibraryClient.AddItem(url: url, capturedLocal: d?.capturedLocal, width: d?.width, height: d?.height,
                                                         cameraMake: d?.cameraMake, cameraModel: d?.cameraModel, lens: d?.lens,
                                                         iso: d?.iso, aperture: d?.aperture, shutter: d?.shutter, focalLength: d?.focalLength)
                        }
                    }.value
                    let r = try await client.add(h, items, copy: false, collection: album, recentImport: album == nil,
                                                 recentImportAt: at)
                    if album == nil, let made = r.recentImport {
                        album = made
                        outcome.imports += 1
                        // Named as the helper names an import, at its own time (0.3.0 does it itself).
                        try? await client.renameCollection(h, made, to: Self.importName(at))
                    }
                    var byPath: [String: [LibraryFrame.ID]] = [:]
                    for f in part { if let u = f.picture.fileURL { byPath[CatalogSourcesStore.key(u.path), default: []].append(f.id) } }
                    for item in r.results {
                        let ids = byPath[CatalogSourcesStore.key(item.path ?? "")] ?? []
                        for id in ids {
                            if let image = item.image { imageOf[id] = image } else { outcome.left[id] = item.error ?? "not added" }
                        }
                    }
                    done += part.count
                }
            }
            outcome.moved = imageOf.count

            // Favourites: an album.
            let favourites = frames.filter(\.isFavourite).compactMap { imageOf[$0.id] }
            if !favourites.isEmpty {
                let made = try await client.newAlbum(h, name: L("Favourites"))
                if let album = made.collection {
                    try await client.addToAlbum(h, album: album, images: favourites)
                    outcome.favourites = favourites.count
                }
            }

            // The window's linked folders: kept in step by the catalog from now on (their files are its already;
            // a file the window had not made a frame of arrives as the folder's first look).
            for folder in library.linkedFolders {
                guard let url = library.url(of: folder.id) else {
                    Log.warn(.library, "mac library move: a linked folder is not connected, not kept", ["folder": folder.title])
                    continue
                }
                do {
                    _ = try await client.addFolder(h, url)
                    outcome.folders += 1
                } catch {
                    Log.warn(.library, "mac library move: a linked folder not kept", ["folder": folder.title, "error": error.localizedDescription])
                }
            }

            // Recorded before the catalog is shown, so a crash after this never offers it again.
            var record = Self.readRecord()
            record.moves.append(Record.Move(catalog: outcome.catalog.path, source: catalog.id, at: Date(),
                                            frames: frames.map(\.id), left: Dictionary(uniqueKeysWithValues:
                                                outcome.left.map { ($0.key.uuidString, $0.value) }),
                                            imports: outcome.imports, favourites: outcome.favourites, folders: outcome.folders))
            Self.write(record)
            candidates = []
            outcome.seconds = (ContinuousClock.now - began) / .seconds(1)
            Log.note(.library, "mac library move: done", ["frames": frames.count, "moved": outcome.moved, "left": outcome.left.count,
                                                         "imports": outcome.imports, "folders": outcome.folders,
                                                         "s": (outcome.seconds * 100).rounded() / 100])
            await store.select(source: catalog.id)
            phase = .done(outcome)
        } catch {
            Log.warn(.library, "mac library move: stopped", ["error": error.localizedDescription, "done": done])
            phase = .failed(error.localizedDescription)
        }
    }

    /// "2026-10-24 15:27": as the helper names an import, in this Mac's time.
    nonisolated static func importName(_ d: Date) -> String { importFormatter.string(from: d) }

    private nonisolated static let importFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - the record

    /// `MacLibrary/moved.json`.
    struct Record: Codable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case version = "version", moves = "moves", inCatalog = "inCatalog" }
        struct Move: Codable, Equatable {
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey {
                case catalog = "catalog", source = "source", at = "at", frames = "frames", left = "left",
                    imports = "imports", favourites = "favourites", folders = "folders"
            }
            /// The catalog the frames' files went into, and its source's id.
            var catalog: String
            var source: UUID
            var at: Date
            /// Every frame the move took (moved or left out).
            var frames: [UUID]
            /// Frames left out (by id), with why.
            var left: [String: String]
            var imports: Int
            var favourites: Int
            var folders: Int
        }
        var version = 1
        var moves: [Move] = []
        /// Frames the Mac library made from a catalog's picture: in that catalog already.
        var inCatalog: Set<UUID> = []

        var known: Set<UUID> { inCatalog.union(moves.flatMap(\.frames)) }
    }

    nonisolated static var recordURL: URL { CatalogSourcesStore.root.appending(path: "MacLibrary/moved.json") }

    /// The record; an empty one for none, or for one this build cannot read, which is copied aside
    /// first (`KeptFileAside`) so the record written next does not go over it.
    nonisolated static func readRecord() -> Record {
        guard let data = try? Data(contentsOf: recordURL) else { return Record() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode(Record.self, from: data)
        } catch {
            KeptFileAside.setAside(recordURL, error: error)
            return Record()
        }
    }

    nonisolated static func write(_ r: Record) {
        do {
            try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(r).write(to: recordURL, options: .atomic)
        } catch {
            Log.warn(.library, "mac library move: record not kept", ["error": error.localizedDescription])
        }
    }
}
