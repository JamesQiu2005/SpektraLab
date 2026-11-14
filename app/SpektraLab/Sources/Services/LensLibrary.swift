//  LensLibrary.swift — the app's lens database as the pages see it (2.4.0, the panel's stage): what 编辑 › 镜头's
//  配置文件 popup lists and Settings › Develop › Lens Profiles counts, installs, adds and removes.
//
//  - **One per app, on the main actor**, over the database the resolver reads (`LensResolver.database`; none in a
//    test or a snapshot library, where every list is empty and every write does nothing).
//  - **The makers are kept** (`makers`), read once off the main thread and again after every write: the popup's
//    top menu is built from them synchronously, and a maker's lenses are read only when its row is opened
//    (`lenses(maker:)`, the popup's deferred element). The database's own index is warmed with them (`warm`), so the
//    first maker opened does not pay for it (measured in `MacLensCheck`).
//  - **A write is followed by the same three things wherever it was made** (`changed`): the kept list read again,
//    `LensResolver.forgetAll()`, and every open photograph resolved again (`AppServices.lensDatabaseChanged`), so a
//    lens installed while a Canon is open corrects it.
//  - **Install never blocks the window**: Adobe's 3,602 files are parsed on the cooperative pool by the database's
//    actor, `progress` follows on the main actor, and `cancelInstall()` stops it between batches (what is written
//    stays: a second install takes up where it stopped). It ends with what was installed and what was skipped
//    (`lastInstall`).
//
//  No profile ships with the app (they are Adobe's): these are read from the folders Adobe's software installed on
//  this Mac, when the person chooses (`LensDatabase.adobeFolders`).

import Foundation
import Observation

@MainActor
@Observable
final class LensLibrary {
    static let shared = LensLibrary()

    /// Every maker with a lens, by name, as last read.
    private(set) var makers: [String] = []
    /// Lenses (and files) of each source, as last read.
    private(set) var counts: [LensDatabase.Source: LensDatabase.Counts] = [:]
    /// Whether the kept figures have been read once.
    private(set) var read = false
    /// Adobe's `.lcp` files found on this Mac (`LensDatabase.adobeFolders`), counted once a launch (and after an install).
    private(set) var adobeFiles: Int?
    private(set) var adobeFolders: [URL] = []
    /// An install running: its progress (files done of all, skipped so far).
    private(set) var progress: LensDatabase.Progress?
    /// What the last install, add or remove did, in English (the page looks it up as it shows it).
    private(set) var lastResult: Result?
    /// Bumped after every write: what a popup's menu and the panel's own answers are rebuilt by.
    private(set) var revision = 0

    /// What a write did, for Settings' caption.
    enum Result: Equatable {
        case installed(added: Int, replaced: Int, unchanged: Int, skipped: Int, cancelled: Bool)
        case added(name: String?)
        case addFailed(reason: String)
        case removed(LensDatabase.Source)
        case failed(String)
    }

    /// Told after every write, once the list has been read again: `AppServices` forgets every resolution and resolves
    /// the open photographs again.
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private var installing: Task<Void, Never>?

    var database: LensDatabase? { LensResolver.database }
    var isEmpty: Bool { read && makers.isEmpty }
    func lenses(of source: LensDatabase.Source) -> Int { counts[source]?.lenses ?? 0 }
    var lensCount: Int { counts.values.reduce(0) { $0 + $1.lenses } }

    // MARK: reading

    /// The kept makers and figures read again (off the main thread, on the database's actor), and Adobe's files counted
    /// where they have not been.
    func refresh() async {
        guard let database else { makers = []; counts = [:]; read = true; return }
        let made = (try? await database.makers()) ?? []
        var c: [LensDatabase.Source: LensDatabase.Counts] = [:]
        for s in LensDatabase.Source.allCases { c[s] = (try? await database.counts(source: s)) ?? .init() }
        makers = made
        counts = c
        read = true
        if adobeFiles == nil { await countAdobe() }
    }

    /// `refresh` once a launch: what the panel and Settings ask as they appear.
    func warm() {
        guard !read, warming == nil else { return }
        warming = Task { await refresh(); warming = nil }
    }
    @ObservationIgnored private var warming: Task<Void, Never>?

    /// Adobe's folders on this Mac and their `.lcp` files, counted off the main thread.
    func countAdobe() async {
        let (folders, n) = await Task.detached(priority: .utility) { () -> ([URL], Int) in
            let folders = LensDatabase.adobeFolders()
            var n = 0
            for f in folders {
                for case let url as URL in FileManager.default.enumerator(at: f, includingPropertiesForKeys: nil) ?? .init()
                where url.pathExtension.lowercased() == "lcp" { n += 1 }
            }
            return (folders, n)
        }.value
        adobeFolders = folders
        adobeFiles = n
    }

    /// A maker's lenses, by name (the popup's maker row, when it is opened).
    func lenses(maker: String) async -> [LensDatabase.Lens] {
        (try? await database?.lenses(maker: maker)) ?? []
    }

    // MARK: writing

    var isInstalling: Bool { installing != nil }

    /// Every `.lcp` of `folders` (Adobe's, by default) into the database, as `adobe-installed`, off the main thread.
    func install(from folders: [URL]? = nil) {
        guard installing == nil, let database else { return }
        let from = folders ?? adobeFolders
        guard !from.isEmpty else { return }
        progress = .init(done: 0, total: 0, skipped: 0)
        lastResult = nil
        installing = Task {
            var total = LensDatabase.Report()
            var failure: String?
            for folder in from {
                if Task.isCancelled { total.cancelled = true; break }
                do {
                    let r = try await database.install(folder: folder) { p in
                        Task { @MainActor in if LensLibrary.shared.installing != nil { LensLibrary.shared.progress = p } }
                    }
                    total.added += r.added; total.replaced += r.replaced; total.unchanged += r.unchanged
                    total.skipped += r.skipped
                    if r.cancelled { total.cancelled = true; break }
                } catch { failure = "\(error)"; break }
            }
            lastResult = failure.map(Result.failed) ?? .installed(added: total.added, replaced: total.replaced, unchanged: total.unchanged,
                                                                  skipped: total.skipped.count, cancelled: total.cancelled)
            lastSkipped = total.skipped
            installing = nil
            progress = nil
            await wrote()
        }
    }

    /// The files the last install skipped, and why (Settings lists the first few).
    private(set) var lastSkipped: [LensDatabase.Skip] = []

    func cancelInstall() { installing?.cancel() }

    /// The install running, waited for (a check's).
    func installed() async { await installing?.value }

    /// One `.lcp` the person chose, as `user`; the lens it holds, as the database lists it (the popup selects it).
    @discardableResult
    func add(file: URL) async -> LensDatabase.Lens? {
        guard let database else { return nil }
        lastResult = nil
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let names = Self.names(in: file)
        do {
            let r = try await database.add(file: file)
            if let skip = r.skipped.first {
                lastResult = .addFailed(reason: skip.reason)
                return nil
            }
        } catch {
            lastResult = .addFailed(reason: "\(error)")
            return nil
        }
        await wrote()
        var found: LensDatabase.Lens?
        for maker in makers where found == nil {
            found = (await lenses(maker: maker)).first { names.contains($0.name) }
        }
        lastResult = .added(name: found?.name)
        return found
    }

    /// Everything of `source` gone.
    func remove(_ source: LensDatabase.Source) async {
        guard let database else { return }
        do { try await database.removeAll(source: source) } catch { lastResult = .failed("\(error)"); return }
        lastResult = .removed(source)
        await wrote()
    }

    private func wrote() async {
        await refresh()
        revision += 1
        changed()
    }

    /// The lens names a file holds, as the database names its lenses (`LensDatabase.write`).
    private nonisolated static func names(in file: URL) -> Set<String> {
        guard let variants = try? LCP.read(file) else { return [] }
        return Set(variants.compactMap { v -> String? in
            let c = v.camera
            let name = c.lensPretty.isEmpty ? (c.lens.isEmpty ? c.profileName : c.lens) : c.lensPretty
            return name.isEmpty ? nil : name
        })
    }
}
