//  CatalogSourcesStore.swift — the Mac's library data (MAC-LIBRARY-DATA.md), behind `MacLibraryData`.
//
//  Every source but the window library's own frames is a library of the helper (`spklib-host`,
//  `LibraryHost`/`LibraryClient`): a SpektraLab catalog or session is one itself; a Capture One
//  catalog is mirrored from a snapshot (`capture_one.link`); a Capture One session and a Finder
//  folder are each a catalog of the app's own under `Libraries/Sources/` that references the folder
//  and keeps it in step (`folders.add` / `folders.sync`). The helper never opens an image, so the
//  files a folder sync finds are described here, from their headers (`images.describe`).
//
//  The kept part is small: the list of sources (`MacLibrary/sources.json` under the app's root). The
//  rest — collections, rows, facets — is asked of the helper when a source or collection is selected.
//
//  Edits are not the helper's: a picture's look is its frame's in the app's library (`FrameCatalog`),
//  made the first time it is opened in Develop and found again by its file's path. That join is what
//  gives a row its film, paper and develop state.

import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class CatalogSourcesStore: MacLibraryData {
    // MARK: what a view reads

    private(set) var sources: [MacSource] = []
    private(set) var selectedSourceID: MacSource.ID?
    private(set) var tree: MacCollectionTree = .empty
    private(set) var selectedCollectionID: MacCollection.ID?
    private(set) var watchedFolders: [MacWatchedFolder] = []
    private(set) var query = MacImageQuery.remembered()
    private(set) var images: [MacImage] = []
    private(set) var total = 0
    private(set) var facets: MacFacets = .empty
    private(set) var activity = MacLibraryActivity()

    var selectedSource: MacSource? { sources.first { $0.id == selectedSourceID } }

    /// The once-only move of the app library's frames into a `.spkcatalog` (`Sources/Mac/Migration/`).
    @ObservationIgnored private(set) lazy var move = MacLibraryMove(store: self, model: model)

    /// Rows asked of the helper at a time. 1,000 full rows of the owner's catalog are ~20 ms in the helper.
    var pageSize = 1000

    // MARK: plumbing

    @ObservationIgnored private(set) weak var model: AppServices?
    @ObservationIgnored let host: LibraryHost
    @ObservationIgnored var client: LibraryClient { LibraryClient(host: host) }
    /// Open handles, by source, and the helper launch they belong to: a restarted helper knows none.
    @ObservationIgnored private var handles: [MacSource.ID: (handle: String, launch: Int)] = [:]
    /// Bumped by each new selection or query, so a slow answer to an old one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var metadataRevision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var describing: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastAutoSync: [MacSource.ID: Date] = [:]
    /// The one refresh a disk mounting or ejecting asks for (`disksChanged`).
    @ObservationIgnored private var diskSync: Task<Void, Never>?
    /// The session the last carry into Develop was kept as (`keepCarried`), and the task making it.
    @ObservationIgnored private var carried: (handle: String, folder: URL)?
    @ObservationIgnored private var carrying: Task<Void, Never>?
    /// Paths of the app library's frames → their ids, NFC, rebuilt when the frames change.
    @ObservationIgnored private var frameIndex: [String: LibraryFrame.ID] = [:]
    /// `key(path)` once per path (2026-11-05): the develop column is read again on every develop's state
    /// change (`refreshDevelopInfo`), and standardising and normalising every path of the library each
    /// time was most of the main thread while a paste's 500 previews were queued.
    @ObservationIgnored private var keys: [String: String] = [:]
    private func keyed(_ path: String) -> String {
        if let k = keys[path] { return k }
        let k = Self.key(path)
        keys[path] = k
        return k
    }
    @ObservationIgnored private var frameIndexCount = -1
    /// Pairs whose row is being added (`MacPairRows.swift`): one `images.add` each, however often kept.
    @ObservationIgnored var pairPlacing: Set<LibraryFrame.ID> = []
    /// The helper uuids of a source's pictures that have a frame, as of a frame count.
    @ObservationIgnored private var developedCache: [MacSource.ID: (frames: Int, images: [String])] = [:]

    /// `Application Support/<bundle id>/`: the sources list in `MacLibrary/`, the helper's store in `Libraries/`.
    nonisolated static var root: URL { ImportService.root }
    nonisolated static var registryURL: URL { root.appending(path: "MacLibrary/sources.json") }
    /// Where the app keeps the catalogs it makes for a Capture One session or a linked folder.
    nonisolated static var ownLibraries: URL { LibraryHost.defaultStore.appending(path: "Sources") }
    /// The id of the app library's source: fixed, so a selection of it is kept across launches.
    nonisolated static let appLibraryID = UUID(uuidString: "5B4C1A00-0000-4000-8000-000000000001")!

    init(model: AppServices?, host: LibraryHost = CaptureOneSource.host) {
        self.model = model
        self.host = host
    }

    // MARK: - start

    func start() async {
        guard !started else { return }
        started = true
        Self.clearCarried()
        load()
        // The SpektraLab Library is the person's catalogs (the owner, 2026-10-24: "fully managed by a
        // .cocatalog-style .spkcatalog"; "we do not limit where this .spkcatalog is stored"). The app
        // library's frames are no longer a source of their own: their files move once into a catalog
        // (`MacLibraryMove`), and their edits stay where they are, found again by path.
        if sources.contains(where: { $0.kind == .appLibrary }) {
            sources.removeAll { $0.kind == .appLibrary }
            if selectedSourceID == Self.appLibraryID { selectedSourceID = nil }
            save()
        }
        // On activation the selected source is looked at again (cheap when nothing changed).
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.autoSync() }
            }
        })
        // A disk mounted or ejected (a cable, Finder's Eject, a server): one look at the selected source.
        if let centre = Self.workspaceCentre {
            for name in ["NSWorkspaceDidMountNotification", "NSWorkspaceDidUnmountNotification"] {
                observers.append(centre.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.disksChanged() }
                })
            }
        } else {
            Log.warn(.library, "mac library: no NSWorkspace, so a disk coming back is seen only on activation")
        }
        // The last one opened is reopened (`readRegistry`, 2026-10-24); with none kept, the one opened last.
        let first = selectedSourceID.flatMap { id in sources.first { $0.id == id } }
            ?? sources.max { ($0.openedAt ?? $0.addedAt) < ($1.openedAt ?? $1.addedAt) }
        move.evaluate()
        if let first { await select(source: first.id) }
        // Half-frame pairs: each a row, pointing at its file in the app's own storage (`MacPairRows.swift`).
        await placePairs()
    }

    // MARK: - the kept list

    private struct Registry: Codable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case version = "version", sources = "sources", selected = "selected" }
        var version = 1
        var sources: [MacSource]
        var selected: UUID?
    }

    /// The kept list, read as `save` writes it: dates in ISO 8601. (Until 2026-10-24 it was read with
    /// the default decoder, which wants numbers, so every launch failed to read it, started from the app
    /// library alone and wrote that over the list: the owner's "instead of opening the app's own library
    /// by default, we open whatever the user opened last time".) A list that cannot be read is never
    /// written over: it is set aside beside itself (`sources.unreadable-<time>.json`) and the log says so.
    private func load() {
        guard let data = try? Data(contentsOf: Self.registryURL) else { return }
        do {
            (sources, selectedSourceID) = try Self.readRegistry(data)
        } catch {
            KeptFileAside.setAside(Self.registryURL, error: error)   // and the log says so
        }
    }

    /// The kept list as a launch reads it: the one reader, `load`'s and `--library-check`'s.
    nonisolated static func readRegistry(_ data: Data) throws -> (sources: [MacSource], selected: UUID?) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(Registry.self, from: data)
        return (r.sources, r.selected)
    }

    func save() {
        let r = Registry(sources: sources, selected: selectedSourceID)
        do {
            try FileManager.default.createDirectory(at: Self.registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(r).write(to: Self.registryURL, options: .atomic)
        } catch {
            Log.warn(.library, "mac library: sources not kept", ["error": error.localizedDescription])
        }
    }

    private func update(_ id: MacSource.ID, _ change: (inout MacSource) -> Void) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[i])
    }

    private func source(_ id: MacSource.ID?) throws -> MacSource {
        guard let s = sources.first(where: { $0.id == (id ?? selectedSourceID) }) else { throw MacLibraryError.noSource }
        return s
    }

    // MARK: - handles

    /// The helper's handle for a source, opening (or linking, or making) its library on first use and
    /// after the helper restarted.
    func handle(_ s: MacSource) async throws -> String {
        try await host.start()
        let launch = await host.launches
        if let h = handles[s.id], h.launch == launch { return h.handle }
        let c = client
        let handle: String
        switch s.kind {
        case .appLibrary:
            throw MacLibraryError.notSupported("The app library has no helper library.")
        case .catalog, .session:
            guard let path = s.libraryPath ?? s.path else { throw MacLibraryError.noSource }
            guard FileManager.default.fileExists(atPath: path) else { throw MacLibraryError.offline(s.name) }
            let h = try await c.open(URL(fileURLWithPath: path))
            handle = h.library
            let copied = Self.copiedFrom(h.info)
            let changed = sources.first { $0.id == s.id }?.copiedFrom != copied
            update(s.id) { $0.imageCount = h.info.counts.images; $0.copiedFrom = copied }
            if changed { save() }
        case .captureOneCatalog:
            guard let path = s.path else { throw MacLibraryError.noSource }
            guard FileManager.default.fileExists(atPath: path) else { throw MacLibraryError.offline(s.name) }
            // Opens the mirror and syncs it (a skip when Capture One has not written since). While Capture
            // One is writing, the mirror as last read is opened instead, and the source says it is busy.
            let link: LibraryLink
            do {
                link = try await c.linkCaptureOne(URL(fileURLWithPath: path))
            } catch let e as LibraryError where e.code == .sourceBusy {
                guard let mirror = s.libraryPath, FileManager.default.fileExists(atPath: mirror) else { throw e }
                let h = try await c.open(URL(fileURLWithPath: mirror))
                handles[s.id] = (h.library, launch)
                update(s.id) { $0.status = .busy }
                return h.library
            }
            handle = link.library
            update(s.id) {
                $0.libraryPath = link.info.path
                $0.imageCount = link.info.counts.images
                $0.format = link.info.origin.format
                $0.syncedAt = Self.utc(link.info.origin.syncedAt)
            }
            lastAutoSync[s.id] = Date()
            save()
        case .captureOneSession, .folder:
            guard let lib = s.libraryPath, let path = s.path else { throw MacLibraryError.noSource }
            if FileManager.default.fileExists(atPath: lib) {
                handle = try await c.open(URL(fileURLWithPath: lib)).library
            } else {
                // Made again (a removed store, a first open on another Mac): the folder is the truth.
                let made = try await c.create(at: URL(fileURLWithPath: lib), kind: .catalog, name: s.name)
                handle = made.library
                _ = try await c.addFolder(handle, URL(fileURLWithPath: path), skip: Self.skips(s.kind))
                update(s.id) { $0.libraryPath = made.info.path }
                save()
            }
        }
        handles[s.id] = (handle, launch)
        return handle
    }

    /// Folder names a kept folder never walks: a Capture One session's per-folder caches.
    private nonisolated static func skips(_ kind: MacSource.Kind) -> [String] {
        kind == .captureOneSession ? ["CaptureOne"] : []
    }

    // MARK: - selecting

    func select(source id: MacSource.ID) async {
        guard let s = sources.first(where: { $0.id == id }), s.kind != .appLibrary else { return }
        selectedSourceID = id
        update(id) { $0.openedAt = Date() }
        save()
        generation += 1
        tree = .empty
        images = []
        keys = [:]      // the last source's row paths (`keyed`); the frames' come back on the next index
        total = 0
        facets = .empty
        watchedFolders = []
        selectedCollectionID = nil
        activity.problem = nil
        await working("Opening \(s.name)…") {
            do {
                _ = try await self.handle(s)
                self.update(id) { $0.status = .ready }
            } catch {
                self.failed(s, error)
            }
        }
        guard selectedSource?.status == .ready else { return }
        await refreshTree()
        selectedCollectionID = tree.defaultSelection
        await reload()
        // A kept folder is looked at once it is on screen, then its new files are described.
        if s.kind != .captureOneCatalog { await synchronize(id) }
    }

    func select(collection id: MacCollection.ID?) async {
        selectedCollectionID = id
        await reload()
    }

    func apply(_ q: MacImageQuery) async {
        query = q
        q.remember()
        await reload()
    }

    // MARK: - the tree

    func refreshTree() async {
        guard let s = selectedSource, s.isHelperBacked else { return }
        do {
            let h = try await handle(s)
            let list = try await client.collections(h)
            guard s.id == selectedSourceID else { return }
            tree = Self.tree(from: list, captureOne: s.kind == .captureOneCatalog)
            if s.acceptsFolders || s.kind == .folder || s.kind == .captureOneSession {
                watchedFolders = try await client.watchedFolders(h).map {
                    MacWatchedFolder(id: $0.folder, url: URL(fileURLWithPath: $0.path), collectionID: $0.collection,
                                     isOnline: $0.online, imageCount: $0.imageCount, syncedAt: Self.utc($0.syncedAt))
                }
                if s.kind == .folder || s.kind == .captureOneSession {
                    let online = watchedFolders.allSatisfy(\.isOnline)
                    update(s.id) { $0.status = online ? .ready : .offline }
                }
            }
            update(s.id) { $0.imageCount = list.first { $0.kind == "all_images" }?.imageCount ?? $0.imageCount }
        } catch {
            failed(s, error)
        }
    }

    /// Capture One's Library tool from the helper's flat list: the root's fixed rows, then the user's
    /// collections, then the folders. Roles come from `kind`, never from names.
    ///
    /// **One shape for every catalog** (the owner, 2026-10-24: "they are all primary source of truth and
    /// should not involve any difference on the user side, based on the Capture One style UI"). A
    /// Capture One mirror and a SpektraLab catalog are laid out by the same two rules, whatever their
    /// rows' origin: two fixed rows of one kind are one row (a mirror's Recent Imports are Capture One's
    /// and SpektraLab's, `new_recent_import`), and every folder hangs under its volume as Capture One's do
    /// ("disk" › "pictures", "/" › "Users"): a folder whose volume has no row of its own gets one made
    /// (`volume:` ids, never sent to the helper; a row with no pictures of its own only opens and closes).
    nonisolated static func tree(from list: [LibraryCollection], captureOne: Bool) -> MacCollectionTree {
        var nodes: [String: MacCollection] = [:]
        var order: [String] = []
        for c in list where c.kind != "root" {
            nodes[c.uuid] = MacCollection(
                id: c.uuid, parentID: c.parent, kind: .init(helper: c.kind),
                title: c.title ?? c.name, imageCount: c.imageCount, createdAt: utc(c.createdAt),
                folder: c.folder.map { URL(fileURLWithPath: $0) }, isEditable: c.editable, isCaptureOne: c.isCaptureOne,
                isSupported: !(c.kind == "smart_album" && c.isCaptureOne))
            order.append(c.uuid)
        }
        let position = Dictionary(list.map { ($0.uuid, $0.position ?? .greatestFiniteMagnitude) }, uniquingKeysWith: { a, _ in a })
        var kids: [String: [String]] = [:]
        var tops: [String] = []
        for id in order {
            let n = nodes[id]!
            if let p = n.parentID, let parent = nodes[p], parentAccepts(parent.kind, child: n.kind) {
                kids[p, default: []].append(id)
            } else {
                tops.append(id)
            }
        }
        func sorted(_ ids: [String], under parent: MacCollection.Kind?) -> [String] {
            ids.sorted { a, b in
                let x = nodes[a]!, y = nodes[b]!
                // Recent imports and captures: newest first, whatever the positions say.
                if parent == .recentImports || parent == .recentCaptures, let s = x.createdAt, let t = y.createdAt {
                    // Made in one second (the move of the app library makes several): the later made is the newer.
                    if s != t { return s > t }
                    let pa = position[a] ?? 0, pb = position[b] ?? 0
                    if pa != pb { return pa > pb }
                }
                if x.kind == .folder && y.kind == .folder { return x.title.localizedStandardCompare(y.title) == .orderedAscending }
                let pa = position[a] ?? .greatestFiniteMagnitude, pb = position[b] ?? .greatestFiniteMagnitude
                return pa != pb ? pa < pb : x.title.localizedStandardCompare(y.title) == .orderedAscending
            }
        }
        func build(_ id: String) -> MacCollection {
            var n = nodes[id]!
            n.children = sorted(kids[id] ?? [], under: n.kind).map(build)
            return n
        }
        var out = MacCollectionTree()
        for id in sorted(tops, under: nil) {
            let n = build(id)
            if n.kind.isFixed { out.fixed.append(n) }
            else if n.kind == .folder { out.folders.append(n) }
            else { out.user.append(n) }
        }
        // Capture One's own order for its fixed rows is its positions; SpektraLab's are the same order.
        let rank: [MacCollection.Kind: Int] = [.allImages: 0, .recentImports: 1, .recentCaptures: 2, .inLibrary: 3, .trash: 4]
        out.fixed = mergedFixed(out.fixed) { kids in sorted(kids.map(\.id), under: .recentImports).compactMap { id in kids.first { $0.id == id } } }
        out.fixed.sort { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
        out.folders = underVolumes(out.folders)
        return out
    }

    /// Two fixed rows of one kind as one: the first one's id (Capture One's, where there is one, as the
    /// helper lists it first), the children of both, newest first, and the count of both.
    private nonisolated static func mergedFixed(_ rows: [MacCollection], newestFirst: ([MacCollection]) -> [MacCollection]) -> [MacCollection] {
        var out: [MacCollection] = []
        for r in rows {
            if let i = out.firstIndex(where: { $0.kind == r.kind }) {
                out[i].children = newestFirst(out[i].children + r.children)
                if let a = out[i].imageCount, let b = r.imageCount { out[i].imageCount = a + b }
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// The volume a folder is on, as Capture One names it: `/Volumes/disk` "disk", anything else "/".
    nonisolated static func volume(of path: String) -> (path: String, title: String) {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" { return ("/Volumes/\(parts[1])", String(parts[1])) }
        return ("/", "/")
    }

    /// The top folders, each under its volume's row: the folder row that is the volume, or one made.
    private nonisolated static func underVolumes(_ tops: [MacCollection]) -> [MacCollection] {
        var volumes: [MacCollection] = []
        var loose: [MacCollection] = []
        for f in tops {
            if let p = f.folder?.path, volume(of: p).path == (p as NSString).standardizingPath { volumes.append(f) } else { loose.append(f) }
        }
        for f in loose {
            let v = volume(of: f.folder?.path ?? "/")
            if let i = volumes.firstIndex(where: { ($0.folder?.path).map { ($0 as NSString).standardizingPath } == v.path }) {
                volumes[i].children.append(f)
            } else {
                volumes.append(MacCollection(id: "volume:\(v.path)", parentID: nil, kind: .folder, title: v.title, imageCount: 0,
                                             folder: URL(fileURLWithPath: v.path), isEditable: false, isCaptureOne: false,
                                             children: [f]))
            }
        }
        func byName(_ a: MacCollection, _ b: MacCollection) -> Bool { a.title.localizedStandardCompare(b.title) == .orderedAscending }
        for i in volumes.indices { volumes[i].children.sort(by: byName) }
        // The start-up disk first, as Capture One lists it, then the others by name.
        return volumes.sorted { a, b in
            let x = a.folder?.path == "/", y = b.folder?.path == "/"
            return x != y ? x : byName(a, b)
        }
    }

    /// Folders nest under folders; everything else under its parent unless that parent is a folder.
    private nonisolated static func parentAccepts(_ parent: MacCollection.Kind, child: MacCollection.Kind) -> Bool {
        child == .folder ? parent == .folder : parent != .folder
    }

    // MARK: - rows

    func reload(keepingRows: Bool = false) async {
        generation += 1
        let g = generation
        let revision = metadataRevision
        if !keepingRows { images = []; total = 0 }
        guard let s = selectedSource, s.isHelperBacked else { return }
        do {
            let h = try await handle(s)
            let q = try await libraryQuery(s, h)
            let page = try await client.images(h, q, offset: 0, limit: pageSize)
            guard g == generation else { return }
            // A header refresh may have read the page before an accepted metadata edit. Read again
            // instead of letting its older snapshot replace the rating/label the person just chose.
            guard revision == metadataRevision else { await reload(keepingRows: true); return }
            refreshFrameIndex()
            images = page.images.map { row($0, source: s) }
            total = page.total
            let f = try await client.facets(h, q)
            guard g == generation else { return }
            guard revision == metadataRevision else { await refreshFacets(); return }
            facets = await facetsFrom(f, source: s, handle: h, base: q)
        } catch {
            if g == generation { failed(s, error) }
        }
    }

    func loadMore() async {
        guard let s = selectedSource, s.kind != .appLibrary, images.count < total else { return }
        let g = generation
        let revision = metadataRevision
        do {
            let h = try await handle(s)
            let q = try await libraryQuery(s, h)
            let page = try await client.images(h, q, offset: images.count, limit: pageSize)
            guard g == generation else { return }
            guard revision == metadataRevision else { await reload(keepingRows: true); return }
            images += page.images.map { row($0, source: s) }
            total = page.total
        } catch {
            failed(s, error)
        }
    }

    func loadAll() async {
        var before = -1
        while images.count < total, images.count != before {
            before = images.count
            await loadMore()
        }
    }

    /// The UI's query as the helper's, scoped to the selected collection.
    private func libraryQuery(_ s: MacSource, _ h: String) async throws -> LibraryQuery {
        var q = LibraryQuery()
        let selected = tree.find(selectedCollectionID)
        q.collection = selected?.kind == .allImages ? nil : selectedCollectionID
        q.recursive = query.includeSubfolders
        q.sort = LibraryQuery.Sort(rawValue: query.sort.rawValue) ?? .captured
        q.descending = query.descending
        q.text = query.text
        q.ratings = query.ratings.sorted()
        q.minRating = query.minimumRating
        q.colorTags = query.colorLabels.sorted()
        q.kinds = query.kinds.map(\.rawValue).sorted()
        q.capturedFrom = query.capturedFrom
        q.capturedTo = query.capturedTo
        q.cameraModels = Array(query.cameras)
        q.lenses = Array(query.lenses)
        q.keywords = query.keywords.sorted()
        q.full = true
        q.checkFiles = true
        if query.developedOnly { q.images = try await developedImages(h) }
        return q
    }

    /// The helper's uuids of the pictures in this library SpektraLab has a frame of: its paths looked up.
    private func developedImages(_ h: String) async throws -> [String] {
        refreshFrameIndex()
        let sid = selectedSourceID ?? Self.appLibraryID
        if let c = developedCache[sid], c.frames == frameIndexCount { return c.images }
        let paths = frameIndex.keys.map { URL(fileURLWithPath: $0) }
        guard !paths.isEmpty else { return [] }
        var out: [String] = []
        for chunk in stride(from: 0, to: paths.count, by: 500) {
            let r = try await client.lookup(h, paths: Array(paths[chunk..<min(chunk + 500, paths.count)]))
            out += r.results.compactMap { $0.found ? $0.match?.image : nil }
        }
        developedCache[sid] = (frameIndexCount, out)
        return out
    }

    private func row(_ i: LibraryImage, source s: MacSource) -> MacImage {
        let url = i.url
        return MacImage(
            id: .init(source: s.id, image: i.uuid), url: url, fileName: i.fileName,
            kind: MacImage.FileKind(rawValue: i.kind) ?? .other, capturedLocal: i.capturedLocal,
            captureDate: Self.wallClock(i.capturedLocal), rating: i.variants.first?.rating ?? i.rating,
            colorLabel: (i.variants.first?.colorTag ?? i.colorTag).flatMap(MacColorLabel.init(rawValue:)),
            cameraMake: i.camera?.make, cameraModel: i.camera?.model, lens: i.camera?.lens,
            exposure: Self.exposureText(i.exposure),
            pixelSize: i.width.flatMap { w in i.height.map { PixelSize(width: w, height: $0) } },
            isOffline: i.exists == false, isTrashed: i.trashed, isRemoved: i.originState == "removed",
            fromCaptureOne: i.isCaptureOne, primaryVariant: i.variants.first?.uuid, variantCount: i.variants.count,
            develop: developInfo(path: url.path))
    }

    private func facetsFrom(_ f: LibraryFacets, source s: MacSource, handle h: String, base: LibraryQuery) async -> MacFacets {
        var out = MacFacets()
        out.total = f.total
        out.ratings = f.rating.compactMap { c in c.value.int.map { .init(value: $0, count: c.count) } }
        out.colorLabels = f.colorTag.compactMap { c in c.value.int.map { .init(value: $0, count: c.count) } }
        out.kinds = f.kind.compactMap { c in c.value.string.map { .init(value: $0, count: c.count) } }
        out.years = f.captured.years.compactMap { c in c.value.string.map { .init(value: $0, count: c.count) } }
        out.months = f.captured.months.compactMap { c in c.value.string.map { .init(value: $0, count: c.count) } }
        out.days = f.captured.days.compactMap { c in c.value.string.map { .init(value: $0, count: c.count) } }
        out.undated = f.captured.undated
        out.cameras = f.camera.map { .init(value: $0.value.string, count: $0.count) }
        for c in f.camera { if let m = c.value.string, let make = c.make { out.cameraMakes[m] = make } }
        out.lenses = f.lens.map { .init(value: $0.value.string, count: $0.count) }
        out.keywords = f.keyword.compactMap { c in c.value.string.map { .init(value: $0, count: c.count) } }
        out.undescribed = f.undescribed
        // "Developed" is the app's knowledge: its frames among this scope, counted by the helper.
        var dq = base
        dq.images = (try? await developedImages(h)) ?? []
        out.developed = dq.images?.isEmpty == false ? ((try? await client.facets(h, dq))?.total ?? 0) : 0
        return out
    }

    // MARK: - the join with the app's library

    private func refreshFrameIndex() {
        guard let frames = model?.library.frames else { return }
        guard frames.count != frameIndexCount else { return }
        var index: [String: LibraryFrame.ID] = [:]
        for f in frames {
            // A pair's row is its file in the app's storage (`MacPairRows.swift`); its picture is its guide.
            if f.isPair { index[keyed(Self.pairFile(f).path)] = f.id; continue }
            if let url = f.picture.fileURL { index[keyed(url.path)] = f.id }
        }
        frameIndex = index
        frameIndexCount = frames.count
    }

    private func developInfo(path: String) -> MacDevelopInfo? {
        guard let id = frameIndex[keyed(path)], let f = model?.library.frame(id) else { return nil }
        return Self.developInfo(f)
    }

    nonisolated static func developInfo(_ f: LibraryFrame) -> MacDevelopInfo {
        let catalog = StockCatalog.shared
        let state: MacDevelopInfo.State
        switch f.develop {
        case .failed: state = .failed
        case .queued, .developing, .waiting: state = .inQueue
        // A develop whose file is missing (`DevelopedPicture.isMissing`) reads not developed: it is made again.
        case .developed: state = f.shownDevelop != nil || f.isDemo ? .developed : .notDeveloped
        }
        return MacDevelopInfo(frameID: f.id,
                              film: f.edit.appliesFilm ? catalog.stock(f.edit.params.filmStock)?.name : nil,
                              // The Digital Intermediate takes the paper's place (2.2.1): it is what the frame is "on".
                              paper: !f.edit.appliesFilm ? nil
                                  : f.edit.params.digitalIntermediateActive(filmIsPositive: catalog.isSlide(f.edit.params.filmStock))
                                  ? L("Digital Intermediate") : catalog.stock(f.edit.params.printStock)?.name,
                              state: state)
    }

    /// Re-reads the develop column of the loaded rows: after a return from Develop, say.
    func refreshDevelopInfo() {
        frameIndexCount = -1
        refreshFrameIndex()
        // Only the rows that changed: writing an equal value still tells every view of `images` to draw again.
        for i in images.indices where selectedSource?.kind != .appLibrary {
            let info = developInfo(path: images[i].url.path)
            if images[i].develop != info { images[i].develop = info }
        }
    }

    nonisolated static func key(_ path: String) -> String {
        (path as NSString).standardizingPath.precomposedStringWithCanonicalMapping
    }

    // MARK: - adding sources

    func newCatalog(named name: String, in folder: URL) async throws -> MacSource {
        try await create(name: name, in: folder, kind: .catalog)
    }

    func newSession(named name: String, in folder: URL) async throws -> MacSource {
        try await create(name: name, in: folder, kind: .session)
    }

    private func create(name: String, in folder: URL, kind: LibraryKind) async throws -> MacSource {
        let target = folder.appending(path: name)
        let made = try await client.create(at: target, kind: kind, name: name)
        let s = MacSource(id: UUID(), kind: kind == .session ? .session : .catalog, name: name, path: made.info.path,
                          libraryPath: made.info.path, addedAt: Date())
        sources.append(s)
        handles[s.id] = (made.library, await host.launches)
        save()
        await select(source: s.id)
        return s
    }

    func open(_ picked: URL) async throws -> MacSource {
        let url = MacLibraryDocuments.sourceURL(picked)
        let path = url.standardizedFileURL.path
        if let known = sources.first(where: { $0.path.map(Self.key) == Self.key(path) }) {
            await select(source: known.id)
            return known
        }
        let fm = FileManager.default
        var s: MacSource
        let ext = url.pathExtension.lowercased()
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        if ext == "spkcatalog" || names.contains("Library.spkdb") {
            let h = try await client.open(url)
            s = MacSource(id: UUID(), kind: .catalog, name: h.info.name, path: h.info.path, libraryPath: h.info.path, addedAt: Date())
        } else if picked.pathExtension.lowercased() == "spksession" || names.contains(where: { $0.lowercased().hasSuffix(".spksession") }) {
            let h = try await client.open(url)
            s = MacSource(id: UUID(), kind: .session, name: h.info.name, path: h.info.path, libraryPath: h.info.path, addedAt: Date())
        } else if let c1 = CaptureOneSource.kind(of: url) {
            let folder = ext == "cosessiondb" ? url.deletingLastPathComponent() : url
            let name = CaptureOneSource.name(of: folder, c1)
            if c1 == .catalog {
                let probe = try await client.probeCaptureOne(folder)
                guard probe.supported else { throw LibraryError(.unsupported, probe.reason ?? "Made by a newer Capture One") }
                s = MacSource(id: UUID(), kind: .captureOneCatalog, name: name, path: folder.path, addedAt: Date())
                s.format = probe.format
            } else {
                s = try await ownLibrary(.captureOneSession, folder: folder, name: name)
            }
        } else {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw MacLibraryError.notSupported("Not a library or a folder: \(url.lastPathComponent)")
            }
            s = try await ownLibrary(.folder, folder: url, name: url.lastPathComponent)
        }
        sources.append(s)
        save()
        await select(source: s.id)
        return sources.first { $0.id == s.id } ?? s
    }

    /// A Capture One session or a Finder folder: a catalog of the app's own that references the folder.
    private func ownLibrary(_ kind: MacSource.Kind, folder: URL, name: String) async throws -> MacSource {
        let id = UUID()
        let lib = Self.ownLibraries.appending(path: id.uuidString + ".spkcatalog")
        try FileManager.default.createDirectory(at: Self.ownLibraries, withIntermediateDirectories: true)
        let made = try await client.create(at: lib, kind: .catalog, name: name)
        let added = try await working("Reading \(name)…") {
            try await self.client.addFolder(made.library, folder, skip: Self.skips(kind))
        }
        var s = MacSource(id: id, kind: kind, name: name, path: folder.path, libraryPath: made.info.path, addedAt: Date())
        s.imageCount = added.sync.added
        handles[id] = (made.library, await host.launches)
        return s
    }

    func addFolder(_ url: URL, to id: MacSource.ID?) async throws {
        let s = try source(id)
        guard s.acceptsFolders else { throw s.isReadOnly ? MacLibraryError.readOnly : MacLibraryError.notSupported("Folders are added to a SpektraLab catalog or session.") }
        let h = try await handle(s)
        let r = try await working("Adding \(url.lastPathComponent)…") {
            try await self.client.addFolder(h, url)
        }
        activity.lastSync = Self.say(r.sync)
        if s.id == selectedSourceID {
            await refreshTree()
            await reload()
            describeSoon(s)
        }
    }

    func stopWatching(_ folder: MacWatchedFolder.ID) async throws {
        let s = try source(nil)
        let h = try await handle(s)
        try await client.removeFolder(h, folder: folder)
        await refreshTree()
    }

    func importFiles(_ urls: [URL], into id: MacSource.ID?, mode: MacImportMode?) async throws -> Int {
        let s = try source(id)
        guard s.acceptsImports else { throw s.isReadOnly ? MacLibraryError.readOnly : MacLibraryError.notSupported("Import into a SpektraLab catalog or session.") }
        let h = try await handle(s)
        let mode = mode ?? s.defaultImport
        // The header is read here and passed in: the helper never opens a picture.
        let items = await Task.detached(priority: .userInitiated) {
            urls.map { url -> LibraryClient.AddItem in
                let d = MacHeaders.read(url)
                return LibraryClient.AddItem(url: url, capturedLocal: d.capturedLocal, width: d.width, height: d.height,
                                             cameraMake: d.cameraMake, cameraModel: d.cameraModel, lens: d.lens)
            }
        }.value
        let r = try await working("Importing \(urls.count) files…") {
            try await self.client.add(h, items, copy: mode == .copy)
        }
        if s.id == selectedSourceID {
            await refreshTree()
            await reload()
        }
        return r.added
    }

    func remove(source id: MacSource.ID) {
        guard id != Self.appLibraryID else { return }
        if let h = handles[id] { Task { [client] in try? await client.close(h.handle) } }
        handles[id] = nil
        sources.removeAll { $0.id == id }
        if selectedSourceID == id {
            selectedSourceID = nil
            tree = .empty
            images = []
            keys = [:]
            total = 0
            facets = .empty
        }
        save()
    }

    // MARK: - keeping in step

    func synchronize(_ id: MacSource.ID?) async {
        guard let s = try? source(id), s.kind != .appLibrary else { return }
        lastAutoSync[s.id] = Date()
        do {
            let h = try await handle(s)
            var changed = false
            switch s.kind {
            case .captureOneCatalog:
                let r = try await working("Reading \(s.name)…") { try await self.client.sync(h) }
                changed = r.changedAnything
                activity.lastSync = r.skipped == true ? "Capture One: unchanged" : "Capture One: \(r.images?.added ?? 0) added, \(r.images?.updated ?? 0) changed, \(r.images?.removed ?? 0) removed"
                update(s.id) { $0.syncedAt = Date(); $0.status = .ready }
            default:
                let r = try await working("Looking at \(s.name)…") { try await self.client.syncFolders(h) }
                changed = r.changedAnything
                let all = r.folders + (r.session.map { [$0] } ?? [])
                activity.lastSync = all.map(Self.say).joined(separator: "; ")
                let offline = all.contains { $0.offline == true }
                update(s.id) { $0.syncedAt = Date(); $0.status = offline ? .offline : .ready }
                describeSoon(s)
            }
            if changed, s.id == selectedSourceID {
                await refreshTree()
                await reload()
            }
        } catch {
            failed(s, error)
        }
    }

    /// On activation: the selected source, at most once a minute.
    private func autoSync() async {
        guard let s = selectedSource, s.isHelperBacked else { return }
        if let last = lastAutoSync[s.id], Date().timeIntervalSince(last) < 60 { refreshDevelopInfo(); return }
        await synchronize(s.id)
        refreshDevelopInfo()
    }

    /// A disk came or went: one refresh, a second after the burst settles (a disk with three volumes
    /// mounts three times). A source that never opened (its disk away at launch, so no tree) is opened
    /// again; an open one is synced and its tree and rows read again, so their offline marks follow
    /// the disk even when the sync itself changed nothing. The app library's linked folders are asked
    /// again too.
    private func disksChanged() {
        diskSync?.cancel()
        diskSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            Log.note(.library, "mac library: a disk came or went", ["source": self.selectedSource?.kind.rawValue ?? "none"])
            await self.model?.library.recheckFolders()
            guard let s = self.selectedSource else { return }
            if self.tree.all.isEmpty {
                await self.select(source: s.id)
            } else {
                await self.synchronize(s.id)
                await self.refreshTree()
                await self.reload()
            }
        }
    }

    /// AppKit's `NSWorkspace.shared.notificationCenter`, reached through the runtime (UIKit has no
    /// word for a disk mounting), as `MacScrollMonitor` reaches `NSEvent`. Nil if AppKit says no.
    private static var workspaceCentre: NotificationCenter? {
        let shared = NSSelectorFromString("sharedWorkspace")
        guard let cls: AnyClass = NSClassFromString("NSWorkspace"),
              let method = class_getClassMethod(cls, shared) else { return nil }
        typealias Get = @convention(c) (AnyClass, Selector) -> NSObject?
        let workspace = unsafeBitCast(method_getImplementation(method), to: Get.self)(cls, shared)
        return workspace?.value(forKey: "notificationCenter") as? NotificationCenter
    }

    /// The files a folder sync added are described from their headers, a hundred at a time, in the
    /// background; the rows and facets fill in as it goes.
    private func describeSoon(_ s: MacSource) {
        guard describing == nil else { return }
        describing = Task { [weak self] in
            defer { self?.describing = nil }
            guard let self else { return }
            var done = 0
            do {
                let h = try await self.handle(s)
                var q = LibraryQuery()
                q.described = false
                q.checkFiles = false
                q.sort = .added
                while !Task.isCancelled {
                    let page = try await self.client.images(h, q, offset: 0, limit: 100)
                    if page.images.isEmpty { break }
                    let items = await Task.detached(priority: .utility) {
                        page.images.map { i -> LibraryDescription in
                            var d = MacHeaders.read(i.url)
                            d.image = i.uuid
                            return d
                        }
                    }.value
                    let n = try await self.client.describe(h, items)
                    if n == 0 { break }
                    done += n
                }
            } catch {
                Log.warn(.library, "mac library: describe stopped", ["error": error.localizedDescription])
            }
            if done > 0 {
                Log.note(.library, "mac library: described", ["images": done])
                if s.id == self.selectedSourceID { await self.reload(keepingRows: true) }
            }
        }
    }

    // MARK: - one picture

    func detail(of id: MacImage.ID) async throws -> MacImageDetail {
        let s = try source(id.source)
        if s.kind == .appLibrary {
            guard let uuid = UUID(uuidString: id.image), let f = model?.library.frame(uuid) else { throw LibraryError(.notFound, "No such frame") }
            return MacImageDetail(image: Self.row(f, source: s.id), fileSize: nil, albums: [], variants: [])
        }
        let h = try await handle(s)
        let d = try await client.image(h, id.image)
        refreshFrameIndex()
        let image = MacImage(
            id: id, url: URL(fileURLWithPath: d.path), fileName: d.fileName, kind: MacImage.FileKind(rawValue: d.kind) ?? .other,
            capturedLocal: d.capturedLocal, captureDate: Self.wallClock(d.capturedLocal), rating: d.variants.first?.rating ?? 0,
            colorLabel: d.variants.first?.colorTag.flatMap(MacColorLabel.init(rawValue:)), cameraMake: d.camera?.make,
            cameraModel: d.camera?.model, lens: d.camera?.lens, exposure: Self.exposureText(d.exposure),
            pixelSize: d.width.flatMap { w in d.height.map { PixelSize(width: w, height: $0) } },
            isOffline: d.exists == false, isTrashed: false, isRemoved: false, fromCaptureOne: d.origin == "capture_one",
            primaryVariant: d.variants.first?.uuid, variantCount: d.variants.count, develop: developInfo(path: d.path))
        return MacImageDetail(
            image: image, fileSize: d.fileSize, albums: (d.albums ?? []).compactMap(\.name),
            variants: d.variants.map {
                .init(id: $0.uuid, position: $0.position, rating: $0.rating ?? 0,
                      colorLabel: $0.colorTag.flatMap(MacColorLabel.init(rawValue:)), captureOneRating: $0.captureOne?.rating,
                      captureOneColorLabel: $0.captureOne?.colorTag.flatMap(MacColorLabel.init(rawValue:)))
            })
    }

    func setRating(_ rating: Int?, for ids: [MacImage.ID]) async throws {
        try await setMeta(ids, patch: rating.map { r in { $0.rating = r } }) { c, h, variants in
            try await c.setMeta(h, variants: variants, rating: .some(rating))
        }
    }

    func setColorLabel(_ label: MacColorLabel?, for ids: [MacImage.ID]) async throws {
        try await setMeta(ids, patch: label == nil ? nil : { $0.colorLabel = label == .unlabelled ? nil : label }) { c, h, variants in
            try await c.setMeta(h, variants: variants, colorTag: .some(label?.rawValue))
        }
    }

    /// 从 SpektraLab 中移除, and 放回 (`trashed` false): the pictures into their source's 回收站 (`images.trash`)
    /// and out again. Nothing on disk moves. Capture One's sources are read one way, so they have no 回收站
    /// of SpektraLab's: there the removal is only of the frames (`MacLibraryActions.remove`).
    func setTrashed(_ trashed: Bool, for ids: [MacImage.ID]) async throws {
        guard let first = ids.first else { return }
        let s = try source(first.source)
        guard s.isHelperBacked, s.kind != .captureOneCatalog, s.kind != .captureOneSession else { return }
        try await client.trash(try await handle(s), images: ids.map(\.image), trashed: trashed)
        await reload()
        // The counts beside All Images and 回收站 are the tree's, which a reload of the rows does not read.
        await refreshTree()
    }

    /// 移到废纸篓, offered in 回收站 only: each file to the system's Trash (where Finder can put it back),
    /// then its row forgotten (`images.remove`, which the helper allows once the file is gone).
    func moveToSystemTrash(_ ids: [MacImage.ID]) async throws {
        guard let first = ids.first else { return }
        let s = try source(first.source)
        guard s.kind == .catalog || s.kind == .session || s.kind == .folder else { throw MacLibraryError.readOnly }
        let wanted = Set(ids)
        var gone: [String] = []
        var failure: Error?
        for image in images where wanted.contains(image.id) && image.isTrashed {
            do {
                if FileManager.default.fileExists(atPath: image.url.path) {
                    try FileManager.default.trashItem(at: image.url, resultingItemURL: nil)
                }
                gone.append(image.id.image)
            } catch { failure = error }
        }
        if !gone.isEmpty { _ = try await client.removeImages(try await handle(s), images: gone) }
        await reload()
        await refreshTree()
        if let failure { throw failure }
    }

    /// `meta.set` on the rows' first variants. On a Capture One catalog it writes SpektraLab's override in
    /// the mirror (`COALESCE(override, Capture One's)`; a sync never touches it), never Capture One's file;
    /// the app library has no ratings. With a `patch` the loaded rows are changed in place and only the
    /// facets are asked again, so a key held over the grid does not empty and refill it; without one (a
    /// value handed back to Capture One, which only the helper knows) the page is read again.
    private func setMeta(_ ids: [MacImage.ID], patch: ((inout MacImage) -> Void)?,
                         _ body: (LibraryClient, String, [String]) async throws -> Void) async throws {
        guard let first = ids.first else { return }
        let s = try source(first.source)
        guard s.isHelperBacked else { throw MacLibraryError.readOnly }
        let h = try await handle(s)
        let wanted = Set(ids)
        let loaded = images.filter { wanted.contains($0.id) }
        var variants = loaded.compactMap(\.primaryVariant)
        // A picture that is not among the loaded rows (an agent's call names any picture of the source,
        // `AgentExecutor`; the window's own keys only ever name loaded ones): its first variant is asked of
        // the helper, as Info's panel asks it.
        let unloaded = wanted.subtracting(loaded.map(\.id))
        for id in unloaded where id.source == s.id {
            if let v = try await detail(of: id).image.primaryVariant { variants.append(v) }
        }
        guard !variants.isEmpty else { return }
        try await body(client, h, variants)
        metadataRevision += 1
        guard let patch else { await reload(keepingRows: true); return }
        for i in images.indices where wanted.contains(images[i].id) { patch(&images[i]) }
        await refreshFacets()
    }

    /// The facets of the scope as it stands, the rows left as they are.
    private func refreshFacets() async {
        guard let s = selectedSource, s.kind != .appLibrary else { return }
        let g = generation
        do {
            let h = try await handle(s)
            let q = try await libraryQuery(s, h)
            let f = try await client.facets(h, q)
            guard g == generation else { return }
            facets = await facetsFrom(f, source: s, handle: h, base: q)
        } catch {
            Log.warn(.library, "mac library: facets not read", ["error": error.localizedDescription])
        }
    }

    // MARK: - into Develop

    /// The most pictures one carry takes into Develop: each becomes a frame, developed only when it is opened
    /// (2026-10-24: an arrival queues nothing on the Mac, `AppServices.develop`).
    nonisolated static let carryLimit = 500

    func openInDevelop(_ id: MacImage.ID) async throws {
        try await openInDevelop([id], focus: id)
    }

    /// Develop on `focus`, its filmstrip the pictures `ids` in that order (the grid's selection, a
    /// collection) instead of the whole app library (`MacDevelopCarry`, read by `DevelopWindowContent`). A
    /// picture without a frame is made one, all of them in one arrival; one that is offline is left out,
    /// unless it is `focus`. The set is also kept as a small session of the app's own (`keepCarried`).
    func openInDevelop(_ ids: [MacImage.ID], focus: MacImage.ID) async throws {
        guard let model else { return }
        do {
            try await openCarried(ids, focus: focus, model: model)
        } catch {
            // No page opened: the mode row's wish (编辑, say) is not left armed for the next one
            // (`MacDevelopWanted`, the owner, 2026-10-26).
            MacDevelopWanted.surface = nil
            throw error
        }
    }

    private func openCarried(_ ids: [MacImage.ID], focus: MacImage.ID, model: AppServices) async throws {
        var seen = Set<MacImage.ID>()
        let ids = (ids.contains(focus) ? ids : [focus] + ids).filter { seen.insert($0).inserted }
        let (frames, files) = try await frames(for: ids, focus: focus)
        guard let open = frames[focus] else { throw LibraryError(.notFound, "No such frame") }
        MacDevelopCarry.shared.frames = ids.compactMap { frames[$0] }
        keepCarried(files)
        model.router.toLibrary()
        model.router.open(.develop(open))
    }

    /// The frames of the pictures `ids` (of one source), made for those without, in one arrival — what
    /// Develop and Export take. One that is offline and has no frame is left out, unless it is `focus`,
    /// which throws. At most `carryLimit`. With each frame, the files that have one, in `ids`' order.
    /// The last frame-making's turn (`frames(for:)`): the next one waits for it.
    @ObservationIgnored private var framingTail: Task<Void, Never>?

    func frames(for ids: [MacImage.ID], focus: MacImage.ID? = nil) async throws -> (frames: [MacImage.ID: LibraryFrame.ID], files: [URL]) {
        guard let model, let first = focus ?? ids.first else { return ([:], []) }
        guard ids.count <= Self.carryLimit else { throw MacLibraryError.tooMany }
        let s = try source(first.source)
        var frames: [MacImage.ID: LibraryFrame.ID] = [:]
        if s.kind == .appLibrary {
            for id in ids { if let f = UUID(uuidString: id.image) { frames[id] = f } }
            return (frames, ids.compactMap { frames[$0].flatMap { model.library.frame($0)?.picture.fileURL } })
        }
        // One frame-making at a time, store-wide, in the order asked (2026-11-05): a paste making frames
        // for 200 RAWs and a Return into Develop on the same pictures each read the frame index, await
        // the probe, then make frames, so two at once made two LibraryFrames for one file. The second
        // waits here and then finds the first's frames in the refreshed index.
        let previous = framingTail
        let (held, release) = AsyncStream<Void>.makeStream()
        framingTail = Task { await previous?.value; for await _ in held {} }
        defer { release.finish() }
        await previous?.value
        let loaded = Dictionary(images.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [MacImage] = []
        for id in ids {
            if let row = loaded[id] { rows.append(row) } else if id == focus { rows.append(try await detail(of: id).image) }
        }
        refreshFrameIndex()
        var adopt: [MacImage] = []
        for r in rows {
            if let known = r.develop?.frameID ?? frameIndex[Self.key(r.url.path)] {
                frames[r.id] = known
            } else if FileManager.default.fileExists(atPath: r.url.path) {
                adopt.append(r)
            } else if r.id == focus {
                throw MacLibraryError.offline(r.fileName)
            }
        }
        if !adopt.isEmpty {
            // Info's "Original" row: the source, then the folder the file is in.
            let made = await ImportService(model: model).adoptLibraryFiles(adopt.map {
                ($0.url, s.name, $0.url.deletingLastPathComponent().lastPathComponent)
            })
            for r in adopt { if let f = made[r.url] { frames[r.id] = f } }
            // Made from a catalog's picture: in a catalog already, so never the move's to offer.
            move.noteInCatalog(Array(made.values))
            refreshDevelopInfo()
        }
        // Their develops are kept with this library from now on, as Capture One keeps a catalog's previews
        // in the catalog (`MacLibraryPreviews.swift`).
        model.housePreviews(Array(frames.values), from: s)
        if let focus, frames[focus] == nil { throw MacLibraryError.unreadable(rows.first { $0.id == focus }?.fileName ?? "") }
        return (frames, rows.filter { frames[$0.id] != nil }.map(\.url))
    }

    /// The most the Light Table holds (`LightTableModel`'s 99).
    nonisolated static let tableLimit = 99

    /// The Light Table from the library (its header's loupe, a picture's menu; the owner, 2026-10-24:
    /// "Where should we enter the Light Table? It should be in the library page somewhere"). Of the
    /// chosen pictures, the ones the table takes (`MacLightTableCarry.takes`: "only those with edit
    /// history in SpektraLab, and those that have film size records") are carried and laid on it when its
    /// page opens; the others are left where they are, and no frame is made for any of them. With
    /// nothing chosen the table opens as it was left; with nothing it takes, it does not open.
    func putOnLightTable(_ ids: [MacImage.ID]) async throws {
        guard let model else { return }
        if !ids.isEmpty {
            refreshFrameIndex()
            let loaded = Dictionary(images.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let frames = ids.compactMap { id -> LibraryFrame.ID? in
                if id.source == Self.appLibraryID { return UUID(uuidString: id.image) }
                guard let row = loaded[id] else { return nil }
                return row.develop?.frameID ?? frameIndex[Self.key(row.url.path)]
            }
            let taken = frames.filter { model.library.frame($0).map(MacLightTableCarry.takes) ?? false }
            guard !taken.isEmpty else { throw MacLibraryError.notForTable }
            guard taken.count <= Self.tableLimit else { throw MacLibraryError.tooManyForTable }
            MacLightTableCarry.shared.frames = taken
        }
        model.router.toLibrary()
        model.router.open(.lightTable)
    }

    /// Where the carried sets are kept: `Libraries/Carried/`, the last one only.
    nonisolated static var carriedRoot: URL { LibraryHost.defaultStore.appending(path: "Carried") }

    /// The carried set as a small SpektraLab session of the app's own, `Libraries/Carried/<time>/`, its
    /// pictures by reference (nothing is copied into its `Capture/`). The one before is closed and deleted.
    /// Develop does not wait for it; a session that cannot be made is said in the log and nothing else.
    private func keepCarried(_ files: [URL]) {
        let previous = carried
        carried = nil
        carrying?.cancel()
        carrying = Task { [weak self] in
            guard let self else { return }
            if let previous {
                try? await self.client.close(previous.handle)
                try? FileManager.default.removeItem(at: previous.folder)
            }
            MacDevelopCarry.shared.session = nil
            guard !files.isEmpty, !Task.isCancelled else { return }
            let name = Self.carriedStamp.string(from: Date())
            let folder = Self.carriedRoot.appending(path: name)
            do {
                try FileManager.default.createDirectory(at: Self.carriedRoot, withIntermediateDirectories: true)
                let made = try await self.client.create(at: folder, kind: .session, name: name)
                self.carried = (made.library, folder)
                _ = try await self.client.add(made.library, files.map { LibraryClient.AddItem(url: $0) }, copy: false)
                MacDevelopCarry.shared.session = URL(fileURLWithPath: made.info.path)
                Log.note(.library, "mac library: carried into Develop", ["images": files.count])
            } catch {
                Log.warn(.library, "mac library: carried session not made", ["error": error.localizedDescription])
            }
        }
    }

    /// The carried sessions a last launch left: deleted at start, before any is made.
    private nonisolated static func clearCarried() {
        try? FileManager.default.removeItem(at: carriedRoot)
    }

    private static let carriedStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    // MARK: - a frame as a row

    /// A frame of the app's library as a row (Develop's Export, `MacExportPage`): no catalog behind it.
    nonisolated static func row(_ f: LibraryFrame, source: MacSource.ID) -> MacImage {
        let local = wallClockString(f.captureDate)
        return MacImage(
            id: .init(source: source, image: f.id.uuidString), url: f.picture.fileURL ?? URL(fileURLWithPath: "/"),
            fileName: f.fileName, kind: f.isRAW ? .raw : .raster, capturedLocal: local, captureDate: f.captureDate,
            rating: 0, colorLabel: nil, cameraMake: nil, cameraModel: f.camera, lens: nil, exposure: f.exposure,
            pixelSize: f.originalSize, isOffline: !f.original.isAvailable, isTrashed: false, isRemoved: false,
            fromCaptureOne: false, primaryVariant: nil, variantCount: 1, develop: developInfo(f))
    }

    // MARK: - small things

    func working<T>(_ what: String, _ body: () async throws -> T) async rethrows -> T {
        activity.working = what
        defer { activity.working = nil }
        return try await body()
    }

    private func failed(_ s: MacSource, _ error: Error) {
        let status: MacSource.Status
        switch (error as? LibraryError)?.code {
        case .sourceBusy?: status = .busy
        case .inUse?: status = .inUse
        case .notFound?: status = .offline
        default:
            if case MacLibraryError.offline? = error as? MacLibraryError { status = .offline }
            else { status = .failed(error.localizedDescription) }
        }
        update(s.id) { $0.status = status }
        activity.problem = "\(s.name): \(error.localizedDescription)"
        Log.warn(.library, "mac library: source refused", ["kind": s.kind.rawValue, "error": error.localizedDescription])
    }

    nonisolated static func say(_ r: LibraryFolderSync) -> String {
        if r.offline == true { return "\((r.path as NSString?)?.lastPathComponent ?? "folder"): not connected" }
        return "\((r.path as NSString?)?.lastPathComponent ?? "folder"): \(r.added ?? 0) new, \(r.moved ?? 0) moved, \(r.removed ?? 0) gone"
    }

    nonisolated static func utc(_ s: String?) -> Date? {
        guard let s else { return nil }
        return try? Date(s, strategy: .iso8601)
    }

    /// "2024-01-08T23:39:04" (the camera's wall clock) as that wall clock in this Mac's time zone.
    nonisolated static func wallClock(_ s: String?) -> Date? {
        guard let s else { return nil }
        return wallClockFormatter.date(from: s)
    }

    nonisolated static func wallClockString(_ d: Date) -> String { wallClockFormatter.string(from: d) }

    /// One formatter for every row: making one per row was most of a 9,658-row listing's time.
    /// (DateFormatter is thread-safe since macOS 10.9 / the operating system 7.)
    nonisolated private static let wallClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    nonisolated static func exposureText(_ e: LibraryImage.Exposure?) -> String? {
        guard let e else { return nil }
        var parts: [String] = []
        if let t = e.shutter, t > 0 { parts.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%g s", (t * 10).rounded() / 10)) }
        if let f = e.aperture, f > 0 { parts.append(String(format: "f/%g", (f * 10).rounded() / 10)) }
        if let iso = e.iso, iso > 0 { parts.append("ISO \(Int(iso))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - the import flow (Sources/Mac/Import, 2026-10-24)

extension CatalogSourcesStore {
    /// Every file the library holds, its trash included (the helper's own check counts a trashed file as
    /// there), as paths and as names with sizes. Pages of 5,000 full rows: the owner's 9,658-image mirror
    /// lists in 175 ms (MAC-LIBRARY-DATA §5).
    func existingFiles(in id: MacSource.ID) async throws -> MacImportExisting {
        let s = try source(id)
        guard s.isHelperBacked else { throw MacLibraryError.notSupported("Import into a SpektraLab catalog or session.") }
        let h = try await handle(s)
        var q = LibraryQuery()
        q.full = true
        q.checkFiles = false
        q.includeTrashed = true
        q.sort = .added
        var out = MacImportExisting()
        var offset = 0
        while true {
            let page = try await client.images(h, q, offset: offset, limit: 5000)
            for i in page.images {
                out.paths.insert(Self.key(i.path))
                if let size = i.fileSize { out.namesAndSizes.insert(MacImportExisting.nameAndSize(i.fileName, size)) }
            }
            offset += page.images.count
            if page.images.isEmpty || offset >= page.total { break }
        }
        return out
    }

    /// One `images.add` of an import in chunks. The first chunk that adds anything makes the import's
    /// Recent Imports album; later chunks pass it as `collection` with `recent_import: false`, so one
    /// import is one album however many chunks it takes (the owner: "import in batches").
    func importChunk(_ files: [MacImportFile], into id: MacSource.ID, copyIntoLibrary: Bool,
                     album: String?) async throws -> MacImportChunk {
        let s = try source(id)
        guard s.acceptsImports else { throw s.isReadOnly ? MacLibraryError.readOnly : MacLibraryError.notSupported("Import into a SpektraLab catalog or session.") }
        let h = try await handle(s)
        let items = files.map { f -> LibraryClient.AddItem in
            let d = f.header
            return LibraryClient.AddItem(url: f.url, capturedLocal: d?.capturedLocal, width: d?.width, height: d?.height,
                                         cameraMake: d?.cameraMake, cameraModel: d?.cameraModel, lens: d?.lens,
                                         iso: d?.iso, aperture: d?.aperture, shutter: d?.shutter, focalLength: d?.focalLength)
        }
        let r = try await client.add(h, items, copy: copyIntoLibrary, collection: album, recentImport: album == nil)
        var out = MacImportChunk(added: r.added, album: album ?? r.recentImport)
        for item in r.results {
            let path = item.path ?? ""
            if let e = item.error { out.failed[path] = e }
            else if item.existing == true { out.existing += 1 }
            else if let image = item.image { out.images[path] = image }
        }
        return out
    }

    /// The library shows what arrived: the destination selected (its tree read again if it already was)
    /// and the import's Recent Imports album chosen in it.
    func showImport(in id: MacSource.ID, album: String?) async {
        if selectedSourceID != id { await select(source: id) } else { await refreshTree() }
        if let album, tree.find(album) != nil { await select(collection: album) } else { await reload() }
    }
}

// MARK: - the SpektraLab Library as catalogs (2026-10-24)

extension CatalogSourcesStore {
    /// `library.info`'s `copied_from` (spklib 0.3.0) as the source keeps it.
    nonisolated static func copiedFrom(_ info: LibraryInfo) -> MacCopiedFrom? {
        guard let c = info.copiedFrom else { return nil }
        return MacCopiedFrom(path: c.path, format: c.format, copiedAt: utc(c.copiedAt), updatedAt: utc(c.updatedAt))
    }

    /// `url` as a catalog's package: `.spkcatalog` added when the panel's name has none.
    nonisolated static func catalogURL(_ url: URL) -> URL {
        url.pathExtension.lowercased() == "spkcatalog" ? url : url.appendingPathExtension("spkcatalog")
    }

    /// A new, empty catalog at `url`, put on the list; selected unless `select` is false (the move selects
    /// its catalog only once it is full). With its handle, which the caller may use at once.
    func makeCatalog(at url: URL, select: Bool) async throws -> (source: MacSource, handle: String) {
        let url = Self.catalogURL(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made = try await client.create(at: url, kind: .catalog, name: url.deletingPathExtension().lastPathComponent)
        let s = MacSource(id: UUID(), kind: .catalog, name: made.info.name, path: made.info.path,
                          libraryPath: made.info.path, addedAt: Date())
        sources.append(s)
        handles[s.id] = (made.library, await host.launches)
        save()
        if select { await self.select(source: s.id) }
        return (s, made.library)
    }

    func newCatalog(at url: URL) async throws -> MacSource {
        try await makeCatalog(at: url, select: true).source
    }

    func copyCaptureOne(_ id: MacSource.ID, to url: URL) async throws -> MacCopyReport {
        let s = try source(id)
        guard s.kind == .captureOneCatalog, let from = s.url else {
            throw MacLibraryError.notSupported("Only a Capture One catalog is copied into a SpektraLab catalog.")
        }
        let target = Self.catalogURL(url)
        // The mirror first, synced, so the copy carries SpektraLab's ratings and labels as they stand.
        let mirror = try? await handle(s)
        let name = target.deletingPathExtension().lastPathComponent
        let made = try await working("Copying \(s.name) into \(name)…") {
            try await self.client.copyCaptureOne(from, to: target, name: name, mirror: mirror)
        }
        var copy = MacSource(id: UUID(), kind: .catalog, name: made.info.name, path: made.info.path,
                             libraryPath: made.info.path, addedAt: Date())
        copy.copiedFrom = Self.copiedFrom(made.info) ?? MacCopiedFrom(path: from.path, format: s.format, copiedAt: Date())
        copy.imageCount = made.info.counts.images
        sources.append(copy)
        handles[copy.id] = (made.library, await host.launches)
        save()
        let r = made.report
        activity.lastSync = "\(copy.name): \(r.images ?? 0) images, \(r.collections ?? 0) collections copied from \(s.name)"
        Log.note(.library, "mac library: Capture One catalog copied", ["images": r.images ?? -1, "collections": r.collections ?? -1,
                                                                        "ms": r.ms ?? -1, "warnings": r.warnings?.count ?? 0])
        await select(source: copy.id)
        return MacCopyReport(source: sources.first { $0.id == copy.id } ?? copy, images: r.images ?? 0, variants: r.variants ?? 0,
                             collections: r.collections ?? 0, folders: r.folders ?? 0, keywords: r.keywords ?? 0,
                             albumMembers: r.albumMembers ?? 0, warnings: r.warnings ?? [], ms: r.ms ?? 0)
    }

    func updateFromCaptureOne(_ id: MacSource.ID?) async throws -> MacUpdateReport {
        let s = try source(id)
        guard s.kind == .catalog else { throw MacLibraryError.notSupported("Only a catalog copied from Capture One is updated from it.") }
        let h = try await handle(s)
        // The Capture One catalog where the copy says it is; if it moved, the Capture One source's own path.
        var moved: URL?
        if let p = s.copiedFrom?.path, !FileManager.default.fileExists(atPath: p),
           let known = sources.first(where: { $0.kind == .captureOneCatalog && $0.copiedFromMatch(s) }), let u = known.url {
            moved = u
        }
        let r = try await working("Updating \(s.name) from Capture One…") {
            try await self.client.updateFromCaptureOne(h, source: moved)
        }
        var out = MacUpdateReport()
        out.skipped = r.skipped == true
        let i = r.images ?? LibraryCounts()
        out.added = i["added"]; out.updated = i["updated"]; out.unchanged = i["unchanged"]; out.gone = i["gone"]
        out.collections = (r.collections?.sum ?? 0) - (r.collections?["unchanged"] ?? 0)
        out.folders = (r.folders?.sum ?? 0) - (r.folders?["unchanged"] ?? 0)
        out.members = (r.members?.sum ?? 0) - (r.members?["unchanged"] ?? 0)
        out.conflictsKept = r.conflictsKept ?? 0
        out.warnings = r.warnings ?? []
        out.ms = r.ms ?? 0
        activity.lastSync = out.skipped ? "\(s.name): Capture One unchanged since the last update"
            : "\(s.name) from Capture One: \(out.added) added, \(out.updated) changed, \(out.gone) gone"
                + (out.conflictsKept > 0 ? ", \(out.conflictsKept) kept as SpektraLab's" : "")
        if let info = try? await client.info(h) {
            update(s.id) { $0.copiedFrom = Self.copiedFrom(info) ?? $0.copiedFrom; $0.imageCount = info.counts.images }
            save()
        }
        Log.note(.library, "mac library: updated from Capture One", ["skipped": out.skipped, "added": out.added,
                                                                      "updated": out.updated, "gone": out.gone, "ms": out.ms])
        if r.changedAnything, s.id == selectedSourceID {
            await refreshTree()
            await select(collection: selectedCollectionID ?? tree.defaultSelection)
        }
        return out
    }
}

private extension MacSource {
    /// A Capture One catalog source that is where a copy came from, by its path's name (a moved catalog
    /// keeps its name).
    func copiedFromMatch(_ copy: MacSource) -> Bool {
        guard let from = copy.copiedFrom?.path, let mine = path else { return false }
        return (from as NSString).lastPathComponent == (mine as NSString).lastPathComponent
    }
}

// MARK: - reading a header

/// What a file's header says, for `images.describe` and `images.add`: ImageIO's properties of its
/// first image, no pixel decoded. A RAW's own size is its decoder's (`ImportService.rawSize`, 35-70 ms a
/// file), so it is left out here; the frame reads it when the picture is opened in Develop.
enum MacHeaders {
    nonisolated static func read(_ url: URL) -> LibraryDescription {
        readIfReadable(url) ?? LibraryDescription(image: "")
    }

    /// The same, or nil when ImageIO cannot read the file at all: the import page's scan confirms a
    /// picture this way, at no cost beyond the header it reads anyway (2026-10-24).
    nonisolated static func readIfReadable(_ url: URL) -> LibraryDescription? {
        var d = LibraryDescription(image: "")
        var readable = false
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
            readable = true
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String, s.count >= 19 {
                // "2024:01:08 23:39:04" -> "2024-01-08T23:39:04": the wall clock, as Capture One keeps it.
                var c = Array(s.prefix(19))
                c[4] = "-"; c[7] = "-"; c[10] = "T"
                d.capturedLocal = String(c)
            }
            func clean(_ v: Any?) -> String? {
                let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return s?.isEmpty == false ? s : nil
            }
            d.cameraMake = clean(tiff[kCGImagePropertyTIFFMake])
            d.cameraModel = clean(tiff[kCGImagePropertyTIFFModel])
            d.lens = clean(exif[kCGImagePropertyExifLensModel]) ?? clean(aux[kCGImagePropertyExifAuxLensModel])
            d.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
            d.aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
            d.shutter = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
            d.focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
            let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) } ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .rawImage) != true,
               var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
               var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 {
                if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
                d.width = w
                d.height = h
            }
        }
        return readable ? d : nil
    }
}
/// The frames the Mac library hands the Light Table, laid on it once when its page opens
/// (`LightTablePane.layCarried`).
@MainActor
final class MacLightTableCarry {
    static let shared = MacLightTableCarry()
    var frames: [LibraryFrame.ID] = []

    /// What may lie on the table, the one filter (the owner, 2026-10-24): a frame of SpektraLab's whose
    /// film's size is known, so it lies at its true millimetres. Known means SpektraLab has developed it
    /// (the owner: "even without the overscan, if you have the grain ever calculated, then you should
    /// know the size of the image": every develop sends `film_format_mm`, the size its grain was made at),
    /// or it carries the size itself: a film edge on (its format) or a half-frame pair. A picture only
    /// listed, or a frame never developed, has none.
    static func takes(_ frame: LibraryFrame) -> Bool {
        frame.pair != nil || frame.edit.filmEdge.active || frame.developed != nil
    }

    func take() -> [LibraryFrame.ID] {
        defer { frames = [] }
        return frames
    }
}

/// What the Mac library last carried into Develop: the filmstrip's frames, in the grid's order, and the
/// session they were kept as. `DevelopWindowContent` takes it in place of the whole app library when the
/// frame it opens on is one of them; any other frame opens on the app library's strip, as before.
@MainActor
@Observable
final class MacDevelopCarry {
    static let shared = MacDevelopCarry()
    var frames: [LibraryFrame.ID] = []
    /// `Libraries/Carried/<time>/<time>.spksession`, once the helper has made it.
    var session: URL?

    /// The carried strip if `id` is on it.
    func strip(opening id: LibraryFrame.ID?) -> [LibraryFrame.ID]? {
        guard let id, frames.contains(id) else { return nil }
        return frames
    }
}
/// The order is the person's last choice, not 拍摄日期 ascending every launch (the owner, 2026-10-27).
extension MacImageQuery {
    private static let sortKey = "mac.library.sort", descendingKey = "mac.library.descending"

    static func remembered(_ defaults: UserDefaults = .standard) -> MacImageQuery {
        var q = MacImageQuery()
        if let raw = defaults.string(forKey: sortKey), let s = Sort(rawValue: raw) { q.sort = s }
        q.descending = defaults.bool(forKey: descendingKey)
        return q
    }

    func remember(_ defaults: UserDefaults = .standard) {
        defaults.set(sort.rawValue, forKey: Self.sortKey)
        defaults.set(descending, forKey: Self.descendingKey)
    }
}
