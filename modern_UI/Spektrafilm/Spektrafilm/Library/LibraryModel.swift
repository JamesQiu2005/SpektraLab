//  LibraryModel.swift — the Library's state: one open library, its
//  tree, the current result, and the handoff to the editor.
//
//  **Beside `Session`, not inside it.** `Session` is the editor's document —
//  one frame on the canvas, the filmstrip around it — and it stays that. A
//  library is a catalog of thousands; holding its rows, its tree and its
//  helper process in `Session` would put a 10,000-photo catalog's state into
//  the object every view of the editor observes. Here they live in their own
//  model, and `Session` receives exactly what it already understood: a list
//  of files and where their settings are (`Session.open(library:…)`).
//
//  **Nothing starts until it is used.** No helper process, no store, no rows
//  until the person opens or creates a library. The 1.x path — Open…, a drop,
//  Finder's Open With — never touches this file.
//
//  The browser never develops (the design's rule 2): the grid draws each
//  photo's embedded preview through `ThumbnailCache`, the same cache and the
//  same arena budget as the filmstrip, and the engine runs only after Develop.

import AppKit
import Foundation
import ImageIO
import Observation

@MainActor
@Observable
final class LibraryModel {
    /// The source well's state line (the design's L4, A1–A5).
    enum SourceState: Equatable {
        case none
        /// A Capture One catalog or a library being read, with a word for what.
        case reading(String)
        /// A1: read and current.
        case ready
        /// A4: the library, or the Capture One catalog it mirrors, is not there.
        case notFound(String)
        /// A5: a catalog this build cannot read; the reason lists what is missing.
        case tooNew(String)
        /// Capture One is writing; read again on the next activation.
        case busy
        /// Another SpektraLab has this session open.
        case inUse(String)
        case failed(String)
    }

    /// A library opened before, remembered by path (§5: the path, never the
    /// handle, which dies with the helper).
    struct Recent: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case catalog, session, captureOne }
        var path: String
        var name: String
        var kind: Kind
        var id: String { path }
    }

    /// A Capture One session: probed, and refused by the 2.0 helper
    /// (`unsupported`, probe-only until its formats are checked against a
    /// real session). Its Capture folder can still be opened as a folder.
    struct CaptureOneSession: Equatable {
        var folder: URL
        var probe: CaptureOneProbe
    }

    let session: Session
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launch: LibraryHost.Launch
    @ObservationIgnored private var host: LibraryHost?

    private(set) var sourceState: SourceState = .none
    private(set) var info: LibraryInfo?
    @ObservationIgnored private(set) var connection: LibraryConnection?
    @ObservationIgnored private(set) var store: LibrarySettingsStore?
    private(set) var captureOneSession: CaptureOneSession?

    private(set) var collections: [LibraryCollection] = []
    private(set) var sessionFolders: [SessionFolder] = []
    private(set) var locations: [LibraryLocation] = []
    /// The collection the grid shows; nil is All Images.
    private(set) var scope: String?
    var query = LibraryQuery() { didSet { if query != oldValue { reloadImages() } } }
    private(set) var rows: [LibraryImage] = []
    private(set) var total = 0
    private(set) var loading = false
    /// The photo the Info rail is about; Develop opens it.
    var selection: String? { didSet { if selection != oldValue { loadDetail() } } }
    private(set) var detail: LibraryImageDetail?
    /// The variant each image develops as, when not its first.
    private(set) var chosenVariant: [String: String] = [:]
    private(set) var toast: String?
    private(set) var recents: [Recent]

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var activation: Any?
    @ObservationIgnored private var generation = 0

    static let recentsKey = Session.uiKey + "library.recents"

    init(session: Session, defaults: UserDefaults = .standard,
         launch: LibraryHost.Launch = .init(executable: LibraryHost.bundledExecutable(), store: LibraryHost.defaultStore)) {
        self.session = session
        self.defaults = defaults
        self.launch = launch
        recents = (defaults.data(forKey: Self.recentsKey))
            .flatMap { try? JSONDecoder().decode([Recent].self, from: $0) } ?? []
    }

    // MARK: - what is open

    var isOpen: Bool { info != nil }
    var isCaptureOne: Bool { info?.origin.isCaptureOne == true }
    var isSession: Bool { info?.kind == .session && !isCaptureOne }
    /// A Capture One catalog: nothing is written to it or beside its
    /// originals, and its ratings and tags are its own (the design's rule 3).
    var readOnly: Bool { isCaptureOne }
    var kindLabel: String {
        isCaptureOne ? L("Capture One Catalog", zh: "Capture One 目录")
            : isSession ? L("SpektraLab Session", zh: "SpektraLab 会话")
            : L("SpektraLab Catalog", zh: "SpektraLab 目录")
    }
    var selectedRow: LibraryImage? { selection.flatMap { s in rows.first { $0.uuid == s } } }
    var scopeName: String {
        guard let scope, let c = collections.first(where: { $0.uuid == scope }) else {
            return L("All Images", zh: "全部图像")
        }
        return c.name
    }

    private func client() -> LibraryClient {
        if let host { return LibraryClient(host: host) }
        let h = LibraryHost(launch: launch)
        host = h
        return LibraryClient(host: h)
    }

    // MARK: - opening, creating, linking

    /// `library.create`, then open it. A catalog is a `.spkcatalog` package;
    /// a session is a folder with `Capture/ Selects/ Output/ Trash/` in it.
    func create(_ kind: LibraryKind, at url: URL) async {
        var path = url
        if kind == .catalog, path.pathExtension != "spkcatalog" { path = path.appendingPathExtension("spkcatalog") }
        let name = path.deletingPathExtension().lastPathComponent
        await perform(L("Creating", zh: "正在创建")) { c in
            let h = try await c.create(at: path, kind: kind, name: name)
            await self.install(h.library, info: h.info, path: URL(fileURLWithPath: h.info.path),
                               recent: Recent(path: h.info.path, name: h.info.name, kind: kind == .session ? .session : .catalog))
        }
    }

    /// `library.open` on a `.spkcatalog`, a session folder, or the
    /// `.spksession` file inside one.
    func open(at url: URL) async {
        let path = url.pathExtension == "spksession" ? url.deletingLastPathComponent() : url
        await perform(L("Opening", zh: "正在打开")) { c in
            let h = try await c.open(path)
            await self.install(h.library, info: h.info, path: URL(fileURLWithPath: h.info.path),
                               recent: Recent(path: h.info.path, name: h.info.name,
                                              kind: h.info.kind == .session ? .session : .catalog))
        }
    }

    /// A Capture One catalog, read one way: `capture_one.probe` for the
    /// verdict, then `capture_one.link`, which mirrors it into a SpektraLab
    /// catalog in the store and reads only a snapshot copy of the original.
    /// A Capture One *session* is probed and stops there (`CaptureOneSession`).
    func openCaptureOne(at url: URL) async {
        captureOneSession = nil
        await perform(L("Reading Capture One", zh: "正在读取 Capture One")) { c in
            let probe = try await c.probeCaptureOne(url)
            if probe.isSession {
                let folder = url.pathExtension == "cosessiondb" ? url.deletingLastPathComponent() : url
                self.showCaptureOneSession(folder: folder, probe: probe)
                return
            }
            guard probe.supported else {
                throw LibraryError(.unsupported, probe.reason ?? L("Made by a newer Capture One", zh: "由较新版本的 Capture One 创建"))
            }
            let link = try await c.linkCaptureOne(url)
            await self.install(link.library, info: link.info, path: URL(fileURLWithPath: link.info.path),
                               recent: Recent(path: url.path, name: url.deletingPathExtension().lastPathComponent,
                                              kind: .captureOne))
        }
    }

    func open(_ recent: Recent) async {
        switch recent.kind {
        case .captureOne: await openCaptureOne(at: URL(fileURLWithPath: recent.path))
        case .catalog, .session: await open(at: URL(fileURLWithPath: recent.path))
        }
    }

    private func showCaptureOneSession(folder: URL, probe: CaptureOneProbe) {
        detach()
        captureOneSession = CaptureOneSession(folder: folder, probe: probe)
        sourceState = .tooNew(L("Capture One sessions are read in a later version",
                                zh: "Capture One 会话将在后续版本中读取"))
    }

    /// A Capture One session's Capture folder, as a plain folder (1.x).
    func openCaptureOneSessionFolder() {
        guard let s = captureOneSession else { return }
        let capture = s.folder.appending(path: "Capture")
        let target = FileManager.default.fileExists(atPath: capture.path) ? capture : s.folder
        session.open(urls: [target])
    }

    private func install(_ handle: String, info: LibraryInfo, path: URL, recent: Recent) async {
        let launches = await host?.launches ?? 0
        if let old = store, old.hasPendingWrites { await old.flush() }
        detach()
        let conn = LibraryConnection(client: client(), path: path, handle: handle, launch: launches)
        connection = conn
        store = LibrarySettingsStore(connection: conn, refs: [:], revisions: [:])
        self.info = info
        captureOneSession = nil
        sourceState = .ready
        remember(recent)
        observeActivation()
        await reload()
    }

    /// Forget the open library (the editor keeps the frames it was handed
    /// until something else is opened; their store finishes its writes).
    private func detach() {
        loadTask?.cancel()
        detailTask?.cancel()
        info = nil
        connection = nil
        store = nil
        collections = []
        sessionFolders = []
        locations = []
        rows = []
        total = 0
        scope = nil
        selection = nil
        detail = nil
        chosenVariant = [:]
        query = LibraryQuery()
    }

    /// The handle stays open while the editor still has this library's
    /// frames: their edits are saved through it.
    func close() async {
        if let s = store { await s.flush() }
        let editorUsesIt = store.map { session.settingsStore === $0 } ?? false
        if !editorUsesIt, let c = connection, let h = try? await c.handle() { try? await c.client.close(h) }
        detach()
        sourceState = .none
    }

    private func remember(_ r: Recent) {
        recents.removeAll { $0.path == r.path }
        recents.insert(r, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        defaults.set(try? JSONEncoder().encode(recents), forKey: Self.recentsKey)
    }

    func forget(_ r: Recent) {
        recents.removeAll { $0.path == r.path }
        defaults.set(try? JSONEncoder().encode(recents), forKey: Self.recentsKey)
    }

    // MARK: - reading

    func reload() async {
        guard let connection else { return }
        do {
            let h = try await connection.handle()
            let c = connection.client
            collections = try await c.collections(h)
            locations = (try? await c.locations(h)) ?? []
            sessionFolders = isSession ? ((try? await c.sessionFolders(h))?.folders ?? []) : []
            if let i = try? await c.info(h) { info = i }
        } catch {
            fail(error)
        }
        reloadImages()
    }

    func show(collection uuid: String?) {
        guard scope != uuid else { return }
        scope = uuid
        var q = query
        q.collection = uuid
        query = q
    }

    /// The whole result, page by page, into `rows`: the grid fills as pages
    /// arrive and never blocks the window. A page is a few hundred kilobytes
    /// of JSON; the rows kept are small (no EXIF unless asked), so 10,000 of
    /// them are a couple of megabytes.
    func reloadImages() {
        loadTask?.cancel()
        generation += 1
        let gen = generation
        guard let connection else { rows = []; total = 0; return }
        let query = self.query
        loading = true
        loadTask = Task { [weak self] in
            var offset = 0
            var collected: [LibraryImage] = []
            var limit = 300
            do {
                let h = try await connection.handle()
                while true {
                    let page = try await connection.client.images(h, query, offset: offset, limit: limit)
                    guard let self, !Task.isCancelled, self.generation == gen else { return }
                    collected += page.images
                    offset += page.images.count
                    self.total = page.total
                    self.rows = collected
                    if self.selection.map({ s in !collected.contains { $0.uuid == s } }) ?? false, offset >= page.total {
                        self.selection = nil
                    }
                    if page.images.isEmpty || offset >= page.total { break }
                    limit = 1000
                }
            } catch {
                guard let self, self.generation == gen else { return }
                self.fail(error)
            }
            guard let self, self.generation == gen else { return }
            self.loading = false
        }
    }

    private func loadDetail() {
        detailTask?.cancel()
        detail = nil
        guard let connection, let id = selection else { return }
        detailTask = Task { [weak self] in
            guard let h = try? await connection.handle(),
                  let d = try? await connection.client.image(h, id) else { return }
            guard let self, !Task.isCancelled, self.selection == id else { return }
            self.detail = d
        }
    }

    /// On activation: a linked Capture One catalog is synced (free when it
    /// has not changed), a session's folder is scanned for new captures.
    func refresh(force: Bool = false) async {
        guard let connection, isOpen else { return }
        do {
            let h = try await connection.handle()
            if isCaptureOne {
                sourceState = .reading(L("Reading Capture One", zh: "正在读取 Capture One"))
                let r = try await connection.client.sync(h, force: force)
                sourceState = .ready
                if r.changedAnything || force { await reload() }
            } else if isSession {
                let s = try await connection.client.sessionScan(h)
                if s.added > 0 || s.missing > 0 { await reload() }
            }
        } catch {
            fail(error)
        }
    }

    private func observeActivation() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    // MARK: - developing

    /// The variant `image` develops as: the one chosen in the Info rail, or
    /// its first.
    func variant(of row: LibraryImage) -> LibraryVariant? {
        if let v = chosenVariant[row.uuid], let hit = row.variants.first(where: { $0.uuid == v }) { return hit }
        return row.variants.min { $0.position < $1.position }
    }

    func choose(variant: String, for image: String) {
        chosenVariant[image] = variant
    }

    /// Whether a photo can go to the editor: its original is reachable and is
    /// a file the app opens.
    func canDevelop(_ row: LibraryImage) -> Bool {
        !row.isOffline && ImageDecoder.openable.contains(row.url.pathExtension.lowercased())
    }

    /// Hand the editor the current result, in the library's order, with
    /// `uuid` on the canvas (⏎ or a double-click). Offline originals and files
    /// the app does not open stay in the Library: the strip is what can be
    /// developed.
    @discardableResult
    func develop(_ uuid: String? = nil) async -> Bool {
        guard let store, let info, let id = uuid ?? selection,
              let target = rows.first(where: { $0.uuid == id }) else { return false }
        guard canDevelop(target) else {
            showToast(target.isOffline ? L("Original offline", zh: "原片离线")
                                       : L("SpektraLab does not open this file", zh: "SpektraLab 无法打开此文件"))
            return false
        }
        await loadTask?.value
        var refs: [URL: LibrarySettingsStore.Ref] = [:]
        var revisions: [String: Int] = [:]
        var frames: [URL] = []
        var seen = Set<String>()
        for row in rows where canDevelop(row) {
            guard let v = variant(of: row), seen.insert(row.url.standardizedFileURL.path).inserted else { continue }
            refs[row.url] = .init(image: row.uuid, variant: v.uuid)
            revisions[v.uuid] = v.editRevision ?? 0
            frames.append(row.url)
        }
        store.update(refs: refs, revisions: revisions)
        let source = LibrarySourceSummary(name: isCaptureOne ? kindLabel : info.name, collection: scopeName,
                                          readOnly: readOnly)
        session.open(library: frames, store: store, source: source, selecting: target.url)
        return true
    }

    // MARK: - SpektraLab's own data

    /// A rating key (0–5). A Capture One catalog's ratings are its own: the
    /// key says so rather than being eaten silently (the design's C3).
    func setRating(_ n: Int?) async {
        guard let row = selectedRow, let v = variant(of: row) else { return }
        guard !readOnly else { return showToast(L("Ratings are set in Capture One", zh: "评级需在 Capture One 中设置")) }
        await mutate { c, h in try await c.setMeta(h, variants: [v.uuid], rating: .some(n)) }
    }

    func setColorTag(_ n: Int?) async {
        guard let row = selectedRow, let v = variant(of: row) else { return }
        guard !readOnly else { return showToast(L("Colour tags are set in Capture One", zh: "色标需在 Capture One 中设置")) }
        await mutate { c, h in try await c.setMeta(h, variants: [v.uuid], colorTag: .some(n)) }
    }

    /// A second print from one negative: a new variant with a copy of the
    /// current one's edit, developed from now on.
    func newVariant() async {
        guard let row = selectedRow, let from = variant(of: row) else { return }
        await mutate { c, h in
            let made = try await c.newVariant(h, image: row.uuid, from: from.uuid)
            await MainActor.run { self.chosenVariant[row.uuid] = made.variant }
        }
    }

    /// Files and folders into a SpektraLab catalog or session, by reference
    /// (where they are) or by copy (into `Originals/yyyy/mm/dd` or `Capture/`).
    /// The metadata is read here, off the main actor, from each file's header
    /// — the helper never opens an image.
    func add(_ urls: [URL], copy: Bool) async {
        guard !readOnly else { return showToast(L("A Capture One catalog is read-only", zh: "Capture One 目录为只读")) }
        let files = Library.frames(from: urls).map(\.url)
        guard !files.isEmpty else { return showToast(L("Nothing to add", zh: "没有可添加的照片")) }
        let items = await Task.detached(priority: .userInitiated) { files.map(LibraryMetadata.read) }.value
        await mutate { c, h in
            let r = try await c.add(h, items, copy: copy)
            let failed = r.results.filter { $0.error != nil }.count
            await MainActor.run {
                self.showToast(failed == 0 ? "\(r.added) " + L("added", zh: "张已添加")
                               : "\(r.added) " + L("added", zh: "张已添加") + " · \(failed) " + L("failed", zh: "张失败"))
            }
        }
    }

    func newAlbum(named name: String) async {
        guard !readOnly else { return showToast(L("A Capture One catalog is read-only", zh: "Capture One 目录为只读")) }
        await mutate { c, h in _ = try await c.newAlbum(h, name: name) }
    }

    func addSelection(toAlbum album: String) async {
        guard let id = selection else { return }
        await mutate { c, h in try await c.addToAlbum(h, album: album, images: [id]) }
    }

    // MARK: - sessions

    /// Move to Selects / Trash / Capture (`session.move`), never overwriting.
    func move(toRole role: String) async {
        guard isSession, let id = selection else { return }
        await mutate { c, h in _ = try await c.sessionMove(h, images: [id], to: role) }
    }

    func putBack() async {
        guard isSession, let id = selection else { return }
        await mutate { c, h in _ = try await c.sessionRestore(h, images: [id]) }
    }

    /// Empty the session's Trash: each file goes to the macOS Trash (the app
    /// deletes nothing itself), and the session forgets only the ones that
    /// really moved.
    func emptyTrash() async {
        guard isSession else { return }
        await mutate { c, h in
            let plan = try await c.sessionTrashPlan(h)
            var removed: [String] = []
            for f in plan.files {
                if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil)) != nil {
                    removed.append(f.path)
                }
            }
            if !removed.isEmpty { try await c.sessionTrashCommit(h, removed: removed) }
        }
    }

    /// "Locate Folder…" for an offline location: the moved prefix applies to
    /// every folder under it (`location.relink`).
    func relink(_ location: String, to folder: URL) async {
        await mutate { c, h in try await c.relink(h, location: location, to: folder) }
    }

    // MARK: - plumbing

    private func perform(_ reading: String, _ body: @escaping (LibraryClient) async throws -> Void) async {
        sourceState = .reading(reading)
        do {
            try await body(client())
        } catch {
            fail(error)
        }
    }

    /// An action on what is open. Its failure is about the action, so it is
    /// said in the tool bar; the source's state line is for the library.
    private func mutate(_ body: @escaping (LibraryClient, String) async throws -> Void) async {
        guard let connection else { return }
        do {
            let h = try await connection.handle()
            try await body(connection.client, h)
            await reload()
            loadDetail()
        } catch {
            showToast(error.localizedDescription)
            Log.shared.warn(.library, "library action failed", [.init("error", error.localizedDescription)])
        }
    }

    private func fail(_ error: Error) {
        guard let e = error as? LibraryError else {
            sourceState = .failed(error.localizedDescription)
            return
        }
        switch e.code {
        case .sourceBusy:
            sourceState = .busy
        case .notFound:
            sourceState = .notFound(e.message)
        case .unsupported:
            sourceState = .tooNew(e.message)
        case .inUse:
            sourceState = .inUse(e.message)
        case .readOnly:
            showToast(e.message)
            if isOpen { sourceState = .ready }
        default:
            sourceState = .failed(e.message)
        }
        Log.shared.warn(.library, "library call failed", [.init("code", e.code.rawValue), .init("message", e.message)])
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Before quitting: the editor's open frame written, every edit the store
    /// was handed delivered, then `host.shutdown` (§2 "Quitting").
    func prepareToQuit() async {
        await session.flushSettings()
        if let store { await store.flush() }
        await host?.shutdown()
    }

    /// Whether quitting has anything to wait for: a helper to shut down, or
    /// the editor holding a library's frame.
    var needsQuitHandshake: Bool { host != nil || session.frameSource.isLibrary }
}

/// What `ImageDecoder` would know of a file before decoding it, read from the
/// header alone, for `images.add`.
enum LibraryMetadata {
    nonisolated static func read(_ url: URL) -> LibraryClient.AddItem {
        var item = LibraryClient.AddItem(url: url)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return item }
        item.width = props[kCGImagePropertyPixelWidth] as? Int
        item.height = props[kCGImagePropertyPixelHeight] as? Int
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        item.cameraMake = tiff?[kCGImagePropertyTIFFMake] as? String
        item.cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        item.lens = exif?[kCGImagePropertyExifLensModel] as? String
        // EXIF's "2024:01:08 23:39:04" → the helper's wall-clock form,
        // "2024-01-08T23:39:04", with no zone, as Capture One keeps it.
        if let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String, raw.count >= 19 {
            let chars = Array(raw)
            var out = chars
            out[4] = "-"; out[7] = "-"; out[10] = "T"
            item.capturedLocal = String(out.prefix(19))
        }
        return item
    }
}
