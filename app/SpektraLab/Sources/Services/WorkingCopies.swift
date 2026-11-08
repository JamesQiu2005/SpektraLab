//  WorkingCopies.swift — originals brought here while they are worked on, and no more of them than the limit.
//
//  design/flow, "Where the photos live": an original that stays where it is —
//  in Photos — is **copied here while it is needed**, and "the oldest are
//  cleared once a limit is reached (5 GB, a placeholder)". These are those
//  copies and their book: where each one is, how large, and when it was last
//  read.
//
//      WorkingCopies/<the frame's id>/<the original's own name>
//      WorkingCopies/.proxies/<the frame's id>-<what it is of>.spkraw
//      WorkingCopies/.proxies/<the frame's id>-<what it is of>.spkfull   (`FullRender`: their own limit, below)
//
//  **A RAW's proxy is kept here too** (`RawProxy`, 2026-10-20: "we maintain
//  the cache within the shared cache size"): its decode at preview size, made
//  once and read by every later job no larger than it. Proxies are in the same
//  book as the copies and under the same limit — one queue, the one read
//  longest ago going first, whichever kind it is — never one of a frame in
//  use, and *Clear Working Copies* takes them with the copies. A proxy is
//  written on the engine's queue and told to the book after (`noteProxy`).
//
//  - **Nothing here is the only copy of anything.** A working copy can always
//    be had again from where its original is ("They come back when a frame
//    needs them", F5), so the folder is left out of backups, and anything in
//    it may go.
//  - **The limit is held.** Whenever a copy arrives (`keep`) and whenever the
//    limit is lowered, the copies read longest ago go until what is left fits
//    (`trim`). The Storage page's *Clear Working Copies* takes them all
//    (`clear`).
//  - **A copy that is being read is never taken**: `inUse` says which frames
//    have a develop under way, a develop page open or an export running. So
//    the copies can stand over the limit by what is in use at that moment, and
//    by no more; the next arrival or the next trim brings them back under it.
//  - **When a copy was last read is the file's own modification date**, set
//    each time a job is handed the file (`touch`): the order survives the app
//    being ended with no index of its own to go stale.
//  - **A fetch is not a copy until it is whole.** It is written into a folder
//    of its own (`incoming`) and moved into place when it is complete (`keep`),
//    so a fetch the app was ended in the middle of leaves nothing that could
//    be developed as though it were the picture; what it leaves goes at the
//    next launch (`sweep`).
//
//  **The full-size renders have a limit of their own** (`fullLimit`, Settings' *Full-Size Renders*;
//  the owner, 2026-10-24: "a LRU should also be maintained that caches the full-size render of the
//  recently viewed images, a certain number depending on the cache size set by the user"). A
//  `.spkfull` is in the same folder and the same book as the proxies, but in a queue of its own
//  (`fulls`) and held to `fullLimit` by its bytes on disk — a 100 MP RAW's is ~1 GB, a 12 MP JPEG's
//  ~120 MB — the one used longest ago going first (`leavingFull`). A render is *used* when the
//  develop page shows it, an export reads it or the Light Table reads it (`noteFull`, `noteProxy`),
//  and that is its file's modification date, so the order survives a relaunch as the copies' does.
//  **Never one in use** (`fullInUse`: the render the develop page shows or is making, a job reading
//  or writing one, a prefetch under way). Until 2026-10-24 a render was kept one at a time: a new
//  one took the last, whosever it was.
//
//  Foundation only, and on the main actor: the book is small, and a decision
//  to take a copy and the taking of it are one step, so no job can be handed
//  a file between the two. `tools/storage_selftest.swift` holds it to the
//  rules above on this Mac.

import Foundation

@MainActor
final class WorkingCopies {
    /// One original, here.
    struct Copy: Equatable, Sendable {
        var url: URL
        var bytes: Int64
        /// When a develop, a page or an export was last handed it.
        var used: Date
    }

    /// Where the copies are. Nil keeps none: the drawings' own library, and
    /// wherever nothing is kept on disk.
    let folder: URL?
    /// The most the copies may take together (`StorageReport.workingCopiesLimit`).
    var limit: Int64 { didSet { if limit < oldValue { trim() } } }
    /// The frames whose originals are being read now. Asked at the moment a
    /// copy would be taken.
    var inUse: () -> Set<UUID> = { [] }
    /// The copies changed: what the Storage page says is measured again.
    var onChange: (() -> Void)?
    /// The clock. A test sets its own.
    var now: () -> Date = Date.init

    private(set) var copies: [UUID: Copy] = [:]
    /// The RAWs' proxies, by file name (`RawProxy.fileName`: the frame's id first).
    private(set) var proxies: [String: Copy] = [:]
    /// The full-size renders (`FullRender.fileName`: the frame's id first), under `fullLimit`.
    private(set) var fulls: [String: Copy] = [:]
    /// The most the full-size renders may take together (`AppSettings.fullRenderCacheLimit`). Lowered,
    /// the renders are held to it at once.
    var fullLimit: Int64 { didSet { if fullLimit < oldValue { trimFull() } } }
    /// The full renders that are being shown, read or made now, by file name: never taken.
    var fullInUse: () -> Set<String> = { [] }
    private let files = FileManager.default

    init(folder: URL?, limit: Int64, fullLimit: Int64 = 8 << 30) {
        self.folder = folder
        self.limit = limit
        self.fullLimit = fullLimit
        guard let folder else { return }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        var dir = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        read()
    }

    /// What the copies, the proxies and the full renders take together.
    var bytes: Int64 { copies.values.reduce(0) { $0 + $1.bytes } + proxies.values.reduce(0) { $0 + $1.bytes } + fullBytes }
    /// What the full renders take.
    var fullBytes: Int64 { fulls.values.reduce(0) { $0 + $1.bytes } }

    // MARK: a RAW's proxy

    static let proxyFolderName = ".proxies"
    /// A full render's file (`FullRender.suffix`; spelt here so the self-test needs only this file).
    nonisolated static let fullSuffix = ".spkfull"
    /// Where the proxies are; nil where nothing is kept.
    var proxyFolder: URL? { folder?.appendingPathComponent(Self.proxyFolderName, isDirectory: true) }

    /// The frame a proxy is of, from its name.
    nonisolated static func proxyFrame(_ name: String) -> UUID? { UUID(uuidString: String(name.prefix(36))) }

    /// A proxy was written or read: it is the most recently read, and the
    /// copies and proxies are held to the limit. One written for a frame that
    /// is no longer in the book's folder — the folder is not kept — is ignored.
    func noteProxy(_ url: URL, bytes: Int64) {
        // A full render read (the page's `FullView.take`, an export's `EngineHost.cached`): its own queue.
        if url.lastPathComponent.hasSuffix(Self.fullSuffix) { return noteFull(url, bytes: bytes) }
        guard let proxyFolder, url.deletingLastPathComponent().standardizedFileURL == proxyFolder.standardizedFileURL,
              files.fileExists(atPath: url.path) else { return }
        let at = now()
        try? files.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        let name = url.lastPathComponent
        let arrived = proxies[name] == nil
        proxies[name] = Copy(url: url, bytes: bytes, used: at)
        trim(keeping: Self.proxyFrame(name).map { [$0] } ?? [])
        if arrived { onChange?() }
    }

    /// A full render was written, shown, or read by an export or the Light Table: it is the one used
    /// most recently, and the renders are held to `fullLimit` — never this one, nor one in use.
    func noteFull(_ url: URL, bytes: Int64) {
        guard let proxyFolder, url.deletingLastPathComponent().standardizedFileURL == proxyFolder.standardizedFileURL,
              files.fileExists(atPath: url.path) else { return }
        let at = now()
        try? files.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        let name = url.lastPathComponent
        let arrived = fulls[name] == nil
        fulls[name] = Copy(url: url, bytes: bytes, used: at)
        trimFull(keeping: [name])
        if arrived { onChange?() }
    }

    /// Whether the full render at `url` is here to read. One the book has and the disk has not is struck.
    func hasFull(_ url: URL) -> Bool {
        if files.fileExists(atPath: url.path) { return true }
        if fulls.removeValue(forKey: url.lastPathComponent) != nil { onChange?() }
        return false
    }

    /// The full renders used longest ago go until what is left is within `fullLimit`: never one in
    /// use, nor one of `keeping` (the one just written or read). The bytes freed.
    @discardableResult
    func trimFull(keeping: Set<String> = []) -> Int64 {
        let going = Self.leavingFull(fulls, limit: fullLimit, held: fullInUse().union(keeping))
        var freed: Int64 = 0
        for name in going {
            guard let full = fulls[name] else { continue }
            freed += full.bytes
            takeFull(name, full)
        }
        if !going.isEmpty { onChange?() }
        return freed
    }

    /// Which full renders go, in the order they go, for what is left to be within `limit`: the one
    /// used longest ago first (of two used at one moment, the larger), never one of `held`, and no more
    /// of them than it takes. By bytes: one 100 MP render may weigh as much as eight of 12 MP.
    nonisolated static func leavingFull(_ fulls: [String: Copy], limit: Int64, held: Set<String>) -> [String] {
        var bytes = fulls.values.reduce(Int64(0)) { $0 + $1.bytes }
        var going: [String] = []
        let order = fulls.sorted { a, b in
            if a.value.used != b.value.used { return a.value.used < b.value.used }
            if a.value.bytes != b.value.bytes { return a.value.bytes > b.value.bytes }
            return a.key < b.key
        }
        for (name, full) in order where !held.contains(name) {
            guard bytes > limit else { break }
            going.append(name)
            bytes -= full.bytes
        }
        return going
    }

    /// Whether the proxy at `url` is here to read. One the book has and the disk has not is struck.
    func hasProxy(_ url: URL) -> Bool {
        if files.fileExists(atPath: url.path) { return true }
        if proxies.removeValue(forKey: url.lastPathComponent) != nil { onChange?() }
        return false
    }

    // MARK: where a copy is

    /// `<folder>/<frame>/<name>`: the same place every time, so a frame's
    /// develop is asked of one path whether its copy is here yet or not.
    nonisolated static func url(in folder: URL, for id: UUID, name: String) -> URL {
        folder.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(fileName(name))
    }

    /// The original's own name, as one file's name: nothing that would name
    /// another folder.
    nonisolated static func fileName(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty || safe == "." || safe == ".." ? "original" : safe
    }

    /// Whether the frame's copy is here to read, under the name it is asked
    /// for by (`url(in:for:name:)`). A copy the book has and the disk has not
    /// is struck from the book.
    func has(_ id: UUID, named name: String) -> Bool {
        guard let copy = copies[id], copy.url.lastPathComponent == Self.fileName(name) else { return false }
        if files.fileExists(atPath: copy.url.path) { return true }
        copies[id] = nil
        return false
    }

    // MARK: a copy arrives

    /// A folder of its own for a fetch under way: the file is written there
    /// and is no copy until `keep` moves it into place.
    func incoming() -> URL? {
        guard let folder else { return nil }
        let place = folder.appendingPathComponent(Self.incomingPrefix + UUID().uuidString, isDirectory: true)
        guard (try? files.createDirectory(at: place, withIntermediateDirectories: true)) != nil else { return nil }
        return place
    }

    /// A fetched file, whole, becomes the frame's copy: moved to its place,
    /// entered in the book, and the copies trimmed to the limit. `file` is
    /// inside a folder made by `incoming`, which goes. Returns where the copy
    /// is, or nil if it could not be put there.
    @discardableResult
    func keep(_ file: URL, for id: UUID, name: String) -> URL? {
        defer { discard(incoming: file.deletingLastPathComponent()) }
        guard let folder else { return nil }
        let place = Self.url(in: folder, for: id, name: name)
        let own = place.deletingLastPathComponent()
        // Whatever stood there: another fetch of the same frame, or an older name of it.
        try? files.removeItem(at: own)
        do {
            try files.createDirectory(at: own, withIntermediateDirectories: true)
            try files.moveItem(at: file, to: place)
        } catch {
            try? files.removeItem(at: own)
            copies[id] = nil
            return nil
        }
        let at = now()
        try? files.setAttributes([.modificationDate: at], ofItemAtPath: place.path)
        copies[id] = Copy(url: place, bytes: Self.size(of: place), used: at)
        trim(keeping: [id])
        onChange?()
        return place
    }

    /// A fetch that came to nothing: its folder goes.
    func discard(incoming place: URL) {
        guard place.lastPathComponent.hasPrefix(Self.incomingPrefix) else { return }
        try? files.removeItem(at: place)
    }

    // MARK: a copy is read

    /// A job is handed the frame's copy: it is the most recently read.
    func touch(_ id: UUID) {
        guard var copy = copies[id] else { return }
        copy.used = now()
        copies[id] = copy
        try? files.setAttributes([.modificationDate: copy.used], ofItemAtPath: copy.url.path)
    }

    // MARK: copies go

    /// The copies read longest ago go until what is left is within the limit.
    /// Never one in use, and never one of `keeping` — the copy that has just
    /// arrived, which is about to be read.
    func trim(keeping: Set<UUID> = []) {
        let going = Self.leaving(copies: copies, proxies: proxies, limit: limit, held: inUse().union(keeping))
        for item in going {
            switch item {
            case .copy(let id): if let copy = copies[id] { take(id, copy) }
            case .proxy(let name): if let proxy = proxies[name] { takeProxy(name, proxy) }
            }
        }
        if !going.isEmpty { onChange?() }
    }

    /// One thing in the book: a frame's working copy, or a proxy by its name.
    enum Item: Hashable, Sendable {
        case copy(UUID)
        case proxy(String)
    }

    /// Which copies and proxies go, in the order they go, for what is left to
    /// be within `limit`: one queue of both, the one read longest ago first,
    /// never one of a frame in `held`, and no more of them than it takes.
    nonisolated static func leaving(copies: [UUID: Copy], proxies: [String: Copy], limit: Int64, held: Set<UUID>) -> [Item] {
        var all: [(item: Item, frame: UUID?, copy: Copy)] = copies.map { (.copy($0.key), $0.key, $0.value) }
        all += proxies.map { (.proxy($0.key), proxyFrame($0.key), $0.value) }
        all.sort { a, b in
            if a.copy.used != b.copy.used { return a.copy.used < b.copy.used }
            if a.copy.bytes != b.copy.bytes { return a.copy.bytes > b.copy.bytes }
            return "\(a.item)" < "\(b.item)"
        }
        var bytes = all.reduce(Int64(0)) { $0 + $1.copy.bytes }
        var going: [Item] = []
        for entry in all where !(entry.frame.map(held.contains) ?? false) {
            guard bytes > limit else { break }
            going.append(entry.item)
            bytes -= entry.copy.bytes
        }
        return going
    }

    /// Which copies go, in the order they go, for what is left to be within
    /// `limit`: the one read longest ago first, never one of `held`, and no
    /// more of them than it takes.
    nonisolated static func leaving(_ copies: [UUID: Copy], limit: Int64, held: Set<UUID>) -> [UUID] {
        var bytes = copies.values.reduce(Int64(0)) { $0 + $1.bytes }
        var going: [UUID] = []
        for (id, copy) in copies.sorted(by: oldestFirst) where !held.contains(id) {
            guard bytes > limit else { break }
            going.append(id)
            bytes -= copy.bytes
        }
        return going
    }

    /// *Clear Working Copies*: every copy but those in use, and every full render but those in use.
    /// Returns the bytes freed.
    @discardableResult
    func clear() -> Int64 {
        let held = inUse()
        var freed: Int64 = 0
        for (id, copy) in copies where !held.contains(id) {
            freed += copy.bytes
            take(id, copy)
        }
        for (name, proxy) in proxies where !(Self.proxyFrame(name).map(held.contains) ?? false) {
            freed += proxy.bytes
            takeProxy(name, proxy)
        }
        let shown = fullInUse()
        for (name, full) in fulls where !shown.contains(name) {
            freed += full.bytes
            takeFull(name, full)
        }
        if freed > 0 { onChange?() }
        return freed
    }

    /// The frames have left the library: their copies go with them, in use or not.
    func remove(_ ids: some Sequence<UUID>) {
        var gone = false
        let ids = Set(ids)
        for id in ids {
            guard let copy = copies[id] else { continue }
            take(id, copy)
            gone = true
        }
        for (name, proxy) in proxies where Self.proxyFrame(name).map(ids.contains) ?? false {
            takeProxy(name, proxy)
            gone = true
        }
        for (name, full) in fulls where Self.proxyFrame(name).map(ids.contains) ?? false {
            takeFull(name, full)
            gone = true
        }
        if gone { onChange?() }
    }

    /// The frame's copy has been moved out — it is the frame's own original
    /// now (`Originals.keepInApp`) — and leaves the book. Its folder goes
    /// where nothing is left in it; a file still there is never deleted here.
    func forget(_ id: UUID) {
        guard let copy = copies.removeValue(forKey: id) else { return }
        let own = copy.url.deletingLastPathComponent()
        if (try? files.contentsOfDirectory(atPath: own.path))?.isEmpty == true { try? files.removeItem(at: own) }
        onChange?()
    }

    /// At launch: whatever in the folder is not a copy of one of `known` — a
    /// frame removed while the app was not looking, a fetch the app was ended
    /// in the middle of, a file nobody put there — goes. Returns how many
    /// things went. A proxy is of any RAW, not only one read from Photos: it
    /// stays while its frame is one of `library` (nil: of `known`).
    @discardableResult
    func sweep(known: Set<UUID>, library: Set<UUID>? = nil) -> Int {
        guard let folder else { return 0 }
        var gone = 0
        for (id, copy) in copies where !known.contains(id) {
            take(id, copy)
            gone += 1
        }
        let frames = library ?? known
        for (name, proxy) in proxies where !(Self.proxyFrame(name).map(frames.contains) ?? false) {
            takeProxy(name, proxy)
            gone += 1
        }
        for (name, full) in fulls where !(Self.proxyFrame(name).map(frames.contains) ?? false) {
            takeFull(name, full)
            gone += 1
        }
        for item in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            if let id = UUID(uuidString: item.lastPathComponent), copies[id] != nil { continue }
            if item.lastPathComponent == Self.proxyFolderName { continue }
            try? files.removeItem(at: item)
            gone += 1
        }
        // In the proxies' folder: a proxy the app was ended in the middle of writing, or one the book does not have.
        if let proxyFolder {
            for item in (try? files.contentsOfDirectory(at: proxyFolder, includingPropertiesForKeys: nil)) ?? []
            where proxies[item.lastPathComponent] == nil && fulls[item.lastPathComponent] == nil {
                try? files.removeItem(at: item)
                gone += 1
            }
        }
        if gone > 0 { onChange?() }
        return gone
    }

    // MARK: the book

    private static let incomingPrefix = ".incoming-"

    /// Longest unread first; of two read at one moment, the larger.
    nonisolated private static func oldestFirst(_ a: (key: UUID, value: Copy), _ b: (key: UUID, value: Copy)) -> Bool {
        if a.value.used != b.value.used { return a.value.used < b.value.used }
        if a.value.bytes != b.value.bytes { return a.value.bytes > b.value.bytes }
        return a.key.uuidString < b.key.uuidString
    }

    private func take(_ id: UUID, _ copy: Copy) {
        try? files.removeItem(at: copy.url.deletingLastPathComponent())
        copies[id] = nil
    }

    private func takeProxy(_ name: String, _ proxy: Copy) {
        try? files.removeItem(at: proxy.url)
        proxies[name] = nil
    }

    private func takeFull(_ name: String, _ full: Copy) {
        try? files.removeItem(at: full.url)
        fulls[name] = nil
    }

    /// The copies as the disk has them: a folder named as a frame's id, with
    /// one file in it.
    private func read() {
        guard let folder else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for own in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: own.lastPathComponent),
                  let inside = try? files.contentsOfDirectory(at: own, includingPropertiesForKeys: keys),
                  let file = inside.first(where: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }),
                  let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            copies[id] = Copy(url: file, bytes: Int64(values.fileSize ?? 0), used: values.contentModificationDate ?? .distantPast)
        }
        guard let proxyFolder else { return }
        for file in (try? files.contentsOfDirectory(at: proxyFolder, includingPropertiesForKeys: keys)) ?? [] {
            let name = file.lastPathComponent
            guard Self.proxyFrame(name) != nil, name.hasSuffix(".spkraw") || name.hasSuffix(Self.fullSuffix),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let copy = Copy(url: file, bytes: Int64(values.fileSize ?? 0), used: values.contentModificationDate ?? .distantPast)
            if name.hasSuffix(Self.fullSuffix) { fulls[name] = copy } else { proxies[name] = copy }
        }
    }

    private static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
