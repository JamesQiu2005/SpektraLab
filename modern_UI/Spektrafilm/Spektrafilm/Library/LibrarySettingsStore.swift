//  LibrarySettingsStore.swift — a library's edits as the editor's settings
//  store (`FrameSettingsStore`), for frames handed over by the Library.
//
//  `API-SPEC-library-helper.md` §5 is the procedure this implements:
//
//  * **Opening a frame**: `edit.get {variant}`. Revision 0 means the library
//    has never stored one, and a 1.x sidecar for the same file is adopted
//    once — read *without writing anything* (`Sidecar.load(for:writes:)`),
//    stored with `edit.put {base_revision: 0}`, and left where it was.
//  * **Saving**: `edit.put` with the revision last read, keeping the one it
//    returns. `conflict` means someone else saved first; the store stops
//    writing that variant and asks (`onConflict`). It never retries with the
//    server's revision on its own — that is the lost update the revision
//    exists to stop.
//
//  Three things keep it honest about memory and about the 1.x behaviour:
//
//  * **Bounded.** The editor's filmstrip can be a 10,000-photo result. Edits
//    are cached as their encoded bytes, a few kilobytes each, at most
//    `capacity` of them; an evicted one is fetched again when it is next
//    opened. What the strip needs of every frame — its state, its crop, whether
//    its print is a film canvas — goes to `Session` as a `Summary` and is not
//    kept here.
//  * **Nothing for a photo merely looked at.** Opening a RAW fills in its
//    as-shot white balance, so the settings `Session` saves on leaving it
//    differ from a new `Sidecar()` even though nobody touched it. A library
//    would then call every photo opened "edited", and its "developed" filter
//    and the grid's Print mark would mean "opened". `Sidecar.isUntouched`
//    says which differences are the app's own; such a frame gets no edit.
//  * **Anything it does not map goes to the sidecar files**, exactly as a
//    folder's would: a half-frame pair, or a file dropped onto the strip.

import Foundation

/// One library, reachable across helper restarts. A handle (`"L1"`) belongs
/// to the helper process that issued it; this reopens the library by path
/// when the process has changed, so every caller asks here rather than
/// keeping a handle of its own.
@MainActor
final class LibraryConnection {
    let client: LibraryClient
    /// The library's own path: a `.spkcatalog`, a session folder, or a linked
    /// Capture One catalog's mirror (which `library.open` reopens like any
    /// catalog, and which remembers where its Capture One catalog is).
    let path: URL
    private var current: (handle: String, launch: Int)?

    init(client: LibraryClient, path: URL, handle: String? = nil, launch: Int = 0) {
        self.client = client
        self.path = path
        if let handle { current = (handle, launch) }
    }

    func handle() async throws -> String {
        let host = client.host
        if let c = current, await host.isRunning, await host.launches == c.launch { return c.handle }
        let h = try await client.open(path)
        let launch = await host.launches
        current = (h.library, launch)
        return h.library
    }
}

@MainActor
final class LibrarySettingsStore: FrameSettingsStore {
    /// A file in the library, and the variant the editor develops for it.
    /// One variant per file at a time: two prints of one negative share a
    /// path, and the editor's frames are keyed by path.
    struct Ref: Equatable, Sendable {
        var image: String
        var variant: String
    }

    /// What the filmstrip shows of a frame without opening it.
    struct Summary: Equatable, Sendable {
        var state: FrameState
        var geometry: Geometry
        var cutsFrame: Bool

        init(_ s: Sidecar?) {
            state = s?.state ?? .unprocessed
            geometry = s?.geometry ?? .default
            cutsFrame = s?.params.cutsFrame ?? false
        }
    }

    private enum Entry: Equatable {
        case none
        case edit(Data)
    }

    enum StoreError: Error, LocalizedError {
        case notFetched(String)
        var errorDescription: String? {
            switch self { case .notFetched(let f): "\(f)'s settings were never read from the library; not saving over them." }
        }
    }

    let connection: LibraryConnection
    let capacity: Int
    /// Whether a variant with no edit adopts the file's 1.x sidecar.
    let adoptsSidecars: Bool
    private let fallback: FrameSettingsStore

    private var refs: [String: Ref]
    /// The revision each variant was last known to be at. Seeded from the
    /// list the frames came from, corrected by every read and write.
    private var revisions: [String: Int]
    private var cache: [String: Entry] = [:]
    private var recency: [String] = []
    private var fetching: [String: Task<Void, Never>] = [:]
    private var pending: [String: Data] = [:]
    private var writing: Set<String> = []
    private(set) var conflicted: Set<String> = []
    private var pinned: String?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var warming: Task<Void, Never>?

    var onSummary: ((URL, Summary) -> Void)?
    var onConflict: ((URL) -> Void)?
    var onFailure: ((URL, String) -> Void)?

    init(connection: LibraryConnection, refs: [URL: Ref], revisions: [String: Int],
         capacity: Int = 256, adoptsSidecars: Bool = true,
         fallback: FrameSettingsStore = SidecarFileStore.shared) {
        self.connection = connection
        self.capacity = max(8, capacity)
        self.adoptsSidecars = adoptsSidecars
        self.fallback = fallback
        self.refs = Dictionary(refs.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.revisions = revisions
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Canonical bytes: compact, keys sorted, so the same settings are the
    /// same bytes and an unchanged frame is never written.
    static func encode(_ s: Sidecar) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(s)) ?? Data()
    }

    func ref(for url: URL) -> Ref? { refs[Self.key(url)] }
    var mappedCount: Int { refs.count }
    var cachedCount: Int { cache.count }
    var hasPendingWrites: Bool { !pending.isEmpty || !writing.isEmpty }

    // MARK: - FrameSettingsStore

    func isReady(_ url: URL) -> Bool {
        guard let r = ref(for: url) else { return true }
        return cache[r.variant] != nil || pending[r.variant] != nil
    }

    func fetch(_ urls: [URL]) async {
        for url in urls {
            guard let r = ref(for: url), !isReady(url) else { continue }
            await fetchOne(url, r)
        }
    }

    func load(for url: URL) -> Sidecar? {
        guard let r = ref(for: url) else { return fallback.load(for: url) }
        touch(r.variant)
        if let p = pending[r.variant] { return Self.decode(p) }
        switch cache[r.variant] {
        case .edit(let d): return Self.decode(d)
        case .none?: return nil
        case nil:
            Log.shared.warn(.library, "settings read before they were fetched", [.init("file", url.lastPathComponent)])
            return nil
        }
    }

    func save(_ sidecar: Sidecar, for url: URL) throws {
        guard let r = ref(for: url) else { return try fallback.save(sidecar, for: url) }
        let v = r.variant
        // Never a save over settings this store does not hold: the open frame
        // is pinned, so it is always held, and anything else is read first
        // (`Session.whenSettingsReady`).
        guard isReady(url) else { throw StoreError.notFetched(url.lastPathComponent) }
        let current: Entry? = pending[v].map { .edit($0) } ?? cache[v]
        let data = Self.encode(sidecar)
        if current == .edit(data) { return }
        // A frame opened and looked at, with nothing stored yet, stays with
        // nothing stored (see the file comment).
        if current == Entry.none || (current == nil && (revisions[v] ?? 0) == 0), sidecar.isUntouched { return }
        cache[v] = .edit(data)
        touch(v)
        pending[v] = data
        onSummary?(url, Summary(sidecar))
        startWriting(v, url: url)
    }

    func remove(for url: URL) {
        guard ref(for: url) != nil else { return fallback.remove(for: url) }
        // Held — the open frame always is — the reset is in the cache before
        // this returns, and the write follows. Read first otherwise.
        if isReady(url) { clear(url); return }
        Task { [weak self] in
            guard let self else { return }
            await self.fetch([url])
            guard self.isReady(url) else { return }
            self.clear(url)
        }
    }

    /// An edit of no settings, in place of the variant's edit. Not "no edit":
    /// the helper keeps a revision, and an explicit empty edit is what tells a
    /// 1.x sidecar beside the photograph not to be adopted again.
    private func clear(_ url: URL) {
        guard load(for: url) != nil else { return }
        try? save(Sidecar(), for: url)
        onSummary?(url, Summary(nil))
    }

    func pictureScope(for url: URL) -> String? {
        ref(for: url).map { "variant:" + $0.variant }
    }

    func pin(_ url: URL?) {
        pinned = url.flatMap { ref(for: $0)?.variant }
    }

    func flush() async {
        while hasPendingWrites, !writersStalled {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// Every unsent edit belongs to a variant that is waiting on the person
    /// (a conflict) rather than on the pipe: `flush` would wait for ever.
    private var writersStalled: Bool {
        writing.isEmpty && Set(pending.keys).isSubset(of: conflicted)
    }

    /// A new result from the same library: the files it maps now, and the
    /// revisions its list reported. One store per open library, so there is
    /// one writer per variant however many times the person develops from
    /// the Library. A revision only grows: one the list reports above what
    /// this store last saw means someone else saved since, and the cached
    /// copy is dropped so the next open reads theirs.
    ///
    /// `revisions` is the base the next `edit.put` is sent on, so it must
    /// always describe the bytes held here. It is raised only where nothing
    /// is held any more; for the open frame, or one with a write in flight,
    /// it stays, and that frame's next save meets `conflict` and asks.
    func update(refs new: [URL: Ref], revisions listed: [String: Int]) {
        refs = Dictionary(new.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        for (v, r) in listed where r > (revisions[v] ?? 0) {
            guard v != pinned, pending[v] == nil, !writing.contains(v), fetching[v] == nil else { continue }
            cache[v] = nil
            revisions[v] = r
        }
    }

    // MARK: - variants and conflicts

    /// Develop another variant of a file from now on.
    func setVariant(_ variant: String, revision: Int?, for url: URL) {
        guard var r = ref(for: url) else { return }
        r.variant = variant
        refs[Self.key(url)] = r
        if let revision { revisions[variant] = revision }
    }

    /// The person chose: keep the version on screen, over the one someone
    /// else saved. Written on top of the library's current revision, which
    /// is a decision and not a blind retry.
    func resolveKeepingMine(_ url: URL) async {
        guard let r = ref(for: url) else { return }
        let v = r.variant
        do {
            let handle = try await connection.handle()
            let theirs = try await connection.client.edit(handle, variant: v)
            revisions[v] = theirs.revision
            conflicted.remove(v)
            if pending[v] == nil, case .edit(let d)? = cache[v] { pending[v] = d }
            startWriting(v, url: url)
        } catch {
            onFailure?(url, error.localizedDescription)
        }
    }

    /// The person chose the library's version: what is on screen is dropped.
    func resolveTakingTheirs(_ url: URL) async {
        guard let r = ref(for: url) else { return }
        let v = r.variant
        conflicted.remove(v)
        pending[v] = nil
        cache[v] = nil
        await fetchOne(url, r)
        wakeIfIdle()
    }

    // MARK: - background

    /// Read, in the background and in order, the frames whose summaries the
    /// strip cannot know without their edits: those the library says have
    /// one, and those with a 1.x sidecar to adopt. Everything else has none,
    /// and costs nothing. Replaces any warm-up still running.
    func warm(_ urls: [URL]) {
        warming?.cancel()
        let candidates = urls.filter { url in
            guard let r = ref(for: url) else { return false }
            if (revisions[r.variant] ?? 0) > 0 { return true }
            return adoptsSidecars && Self.hasLegacySidecar(url)
        }
        guard !candidates.isEmpty else { return }
        warming = Task { [weak self] in
            for url in candidates {
                guard !Task.isCancelled, let self else { return }
                await self.fetch([url])
            }
        }
    }

    func cancelWarming() { warming?.cancel(); warming = nil }

    /// A stat or two, never a read: whether `Sidecar.load` could find
    /// anything for this file by its path. (A sidecar re-keyed for a moved
    /// file is found when the frame is opened; the warm-up does not look.)
    static func hasLegacySidecar(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Sidecar.url(for: url).path)
            || fm.fileExists(atPath: Sidecar.neighbourURL(for: url).path)
            || fm.fileExists(atPath: Sidecar.legacyURL(for: url).path)
    }

    // MARK: - reading

    private func fetchOne(_ url: URL, _ r: Ref) async {
        let v = r.variant
        if let running = fetching[v] { return await running.value }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.read(url, variant: v)
        }
        fetching[v] = task
        await task.value
        fetching[v] = nil
    }

    private func read(_ url: URL, variant v: String) async {
        do {
            let handle = try await connection.handle()
            if adoptsSidecars, (revisions[v] ?? 0) == 0,
               let legacy = Sidecar.load(for: url, writes: false), !legacy.isUntouched {
                let data = Self.encode(legacy)
                do {
                    let r = try await connection.client.putEdit(handle, variant: v, edit: data, baseRevision: 0)
                    revisions[v] = r
                    store(v, .edit(data), url: url, sidecar: legacy)
                    Log.shared.info(.library, "adopted a 1.x sidecar", [.init("file", url.lastPathComponent)])
                    return
                } catch let e as LibraryError where e.code == .conflict {
                    // Someone stored one since the list was read: theirs wins,
                    // read below.
                }
            }
            let got = try await connection.client.edit(handle, variant: v)
            revisions[v] = got.revision
            if pending[v] != nil { return }
            if let s = got.edit, got.revision > 0 {
                store(v, .edit(Self.encode(s)), url: url, sidecar: s)
            } else {
                store(v, .none, url: url, sidecar: nil)
            }
        } catch {
            Log.shared.warn(.library, "an edit could not be read", [.init("file", url.lastPathComponent),
                                                                   .init("error", error.localizedDescription)])
            onFailure?(url, error.localizedDescription)
        }
    }

    private func store(_ v: String, _ entry: Entry, url: URL, sidecar: Sidecar?) {
        cache[v] = entry
        touch(v)
        onSummary?(url, Summary(sidecar))
        evict()
    }

    private func touch(_ v: String) {
        if let i = recency.lastIndex(of: v) { recency.remove(at: i) }
        recency.append(v)
    }

    private func evict() {
        var i = 0
        while cache.count > capacity, i < recency.count {
            let v = recency[i]
            if v == pinned || pending[v] != nil || writing.contains(v) || fetching[v] != nil {
                i += 1
                continue
            }
            cache[v] = nil
            recency.remove(at: i)
        }
    }

    private static func decode(_ d: Data) -> Sidecar? { try? JSONDecoder().decode(Sidecar.self, from: d) }

    // MARK: - writing

    private func startWriting(_ v: String, url: URL) {
        guard !writing.contains(v), !conflicted.contains(v) else { return }
        writing.insert(v)
        Task { [weak self] in await self?.drain(v, url: url) }
    }

    /// One writer per variant: the latest settings, each sent on top of the
    /// revision the previous write returned. A burst of saves while one is in
    /// flight becomes one more write, not a queue.
    private func drain(_ v: String, url: URL) async {
        defer {
            writing.remove(v)
            evict()
            wakeIfIdle()
        }
        var attempts = 0
        while let data = pending[v] {
            do {
                let handle = try await connection.handle()
                let r = try await connection.client.putEdit(handle, variant: v, edit: data,
                                                            baseRevision: revisions[v] ?? 0)
                revisions[v] = r
                if pending[v] == data { pending[v] = nil }
                attempts = 0
            } catch let e as LibraryError where e.code == .conflict {
                conflicted.insert(v)
                Log.shared.warn(.library, "an edit was saved elsewhere first", [.init("file", url.lastPathComponent),
                                                                              .init("revision", e.revision ?? -1)])
                onConflict?(url)
                return
            } catch let e as LibraryError where e.code == .unavailable && attempts < 3 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(250 * attempts))
            } catch {
                Log.shared.error(.library, "an edit could not be saved", [.init("file", url.lastPathComponent),
                                                                         .init("error", error.localizedDescription)])
                onFailure?(url, error.localizedDescription)
                return
            }
        }
    }

    private func wakeIfIdle() {
        guard !hasPendingWrites || writersStalled else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

extension Sidecar {
    /// Whether these settings differ from a new `Sidecar()` only by what the
    /// app fills in by itself when a frame is opened and looked at: the
    /// as-shot white balance's numbers (ignored outright under `.asShot`),
    /// and the file identity `save(for:)` stamps. A frame that was developed
    /// is never untouched (`state`), nor is one with any setting changed.
    var isUntouched: Bool {
        guard state == .unprocessed else { return false }
        var a = self
        let fresh = Sidecar()
        a.source = nil
        if a.decode.whiteBalance == .asShot {
            a.decode.temperature = fresh.decode.temperature
            a.decode.tint = fresh.decode.tint
        }
        return a == fresh
    }
}
