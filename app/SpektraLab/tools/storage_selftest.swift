//  storage_selftest.swift — what the app keeps on disk and lets go of, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  Two things that go wrong quietly, with no engine, no Photos and no page needed to show it:
//
//  - **the working copies** (`Services/WorkingCopies.swift`): originals that stay in Photos, copied
//    here while they are worked on. Their limit is held — the copy read longest ago goes first, one
//    that is being read never goes, the one that has just arrived is not taken by its own arrival —
//    *Clear Working Copies* takes all but those in use, a frame that leaves takes its copy, the order
//    survives the app being ended (it is the files' own dates), and at launch whatever in the folder
//    is not a copy of a frame of the library goes: a removed frame's, a fetch ended in the middle.
//    A limit that is not held is a host filling up; a copy taken from under a develop is a develop
//    that fails.
//  - **the launch's tidy of `Previews`** (`Services/StorageTidy.swift`): a kept develop, a preview
//    copy or a pair's guide that no frame names goes — and nothing else does: not a file a frame
//    names, not one written in the last hour, not a file that is not the app's make. A sweep that
//    took too much would blank the library's tiles.
//  - **the full-size renders** (`.spkfull`, `WorkingCopies.fullLimit`, 2026-10-24): an LRU of their own,
//    by bytes — the one used longest ago goes first, as many as it takes and no more, never one in use (the
//    develop page's, a job's) — a read is a use and is the file's own date, so a launch finds the same
//    order; a lowered limit trims at once; they are not counted in the copies' limit; *Clear* takes them,
//    a frame that leaves takes its own. Until that day they were kept one at a time.
//  - **Develop's cards** (`Previews/Stocks`, `StorageTidy.sweepCards`, `holdCards`, `dropCards`): a
//    frame's go with it, those read from another source go, all of them are held to a limit with the
//    card shown longest ago first and never one of the frame on the page, and nothing else is touched.
//  - **a library's previews** (`Services/LibraryPreviews.swift`, 2026-11-05): a frame's kept develop is
//    kept with the catalog or session it was carried from (`X.spkcatalog/Cache/Previews`, a session's
//    hidden `.SpektraLab/Cache/Previews`), never in a Capture One catalog, never in a library that is not
//    there (and nothing is made where it was); at launch a develop's folder names its library unless the
//    frame was carried from another since; a replaced develop goes wherever it was and nothing else of a
//    library ever does; *Delete Previews* takes the develops but the open page's; a 2.1.3 develop moves
//    in under its own name, never over a file and never into a library that is not there. Review fixes
//    (2026-11-05): the write itself (`LibraryPreviews.write`, which `EngineHost.write` calls) makes a
//    library's folder only where the library is, and falls back to the app's `Previews`; a catalog moved
//    in Finder has its frames' develops found in it again (`locate`), one gone is gone and one on a disk
//    that is not mounted is away; a twin already in the library is adopted; the app's own libraries'
//    previews are counted for Settings › Storage (`measureOwn`).
//
//  Compiled with those three sources alone, in a folder of its own under the temporary files.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks against a
//  rule broken on purpose, one at a time, and requires each run to fail.

import Foundation

/// The rules under test, so a broken one can be put in their place.
@MainActor
struct Rules {
    var name = "the app's"
    /// Which copies go for what is left to fit a limit.
    var leaving: ([UUID: WorkingCopies.Copy], Int64, Set<UUID>) -> [UUID] = { WorkingCopies.leaving($0, limit: $1, held: $2) }
    /// A fetched file becomes a frame's copy.
    var arrive: (WorkingCopies, URL, UUID, String) -> URL? = { $0.keep($1, for: $2, name: $3) }
    var setLimit: (WorkingCopies, Int64) -> Void = { $0.limit = $1 }
    var clear: (WorkingCopies) -> Int64 = { $0.clear() }
    var touch: (WorkingCopies, UUID) -> Void = { $0.touch($1) }
    var remove: (WorkingCopies, [UUID]) -> Void = { $0.remove($1) }
    var sweep: (WorkingCopies, Set<UUID>) -> Int = { $0.sweep(known: $1) }
    var has: (WorkingCopies, UUID, String) -> Bool = { $0.has($1, named: $2) }
    /// A RAW's proxy written or read (`RawProxy`), in the copies' book and under their limit.
    var noteProxy: (WorkingCopies, URL, Int64) -> Void = { $0.noteProxy($1, bytes: $2) }
    /// A full render written, shown or read: the most recently used, and the renders held to their limit.
    var noteFull: (WorkingCopies, URL, Int64) -> Void = { $0.noteFull($1, bytes: $2) }
    /// Which full renders go for what is left to fit their limit.
    var leavingFull: ([String: WorkingCopies.Copy], Int64, Set<String>) -> [String] = { WorkingCopies.leavingFull($0, limit: $1, held: $2) }
    var setFullLimit: (WorkingCopies, Int64) -> Void = { $0.fullLimit = $1 }
    /// The launch's sweep, with the library's frames: a proxy is of any RAW, not only one from Photos.
    var sweepLibrary: (WorkingCopies, Set<UUID>, Set<UUID>) -> Int = { $0.sweep(known: $1, library: $2) }
    var tidy: (URL, Set<String>, Date) -> (files: Int, bytes: Int64) = { StorageTidy.sweep($0, keeping: $1, now: $2) }
    var word: (URL, URL) -> String = { StorageTidy.stampWord($0, under: $1) }
    /// Develop's cards (`Previews/Stocks`): the launch's sweep, the limit, a frame's cards of another source.
    var sweepCards: (URL, Set<UUID>) -> (files: Int, bytes: Int64) = { StorageTidy.sweepCards($0, keepingFrames: $1) }
    var holdCards: (URL, Int64, UUID?) -> (files: Int, bytes: Int64) = { StorageTidy.holdCards($0, to: $1, sparing: $2) }
    var dropCards: (UUID, String, URL) -> Int = { StorageTidy.dropCards(of: $0, otherThan: $1, in: $2) }
    /// The space the cards share with the renders under `Previews` (the owner, 2026-10-17).
    var holdShared: (URL, Int64, UUID?) -> (files: Int, bytes: Int64) = { StorageTidy.holdCards(sharing: $0, limit: $1, sparing: $2) }
    /// A library's previews (`LibraryPreviews`, 2026-11-05): where a frame's develop is written, in order.
    var previewFolders: (UUID, URL) -> [URL] = { LibraryPreviews.folders(for: $0, fallback: $1) }
    var previewHome: (URL, PreviewHome.Kind) -> PreviewHome? = { PreviewHome(root: $0, kind: $1) }
    var previewFolder: (PreviewHome) -> URL = { $0.folder }
    var rememberPreviews: ([(frame: UUID, file: URL)]) -> Void = { LibraryPreviews.remember($0) }
    var discardable: (URL, URL) -> Bool = { LibraryPreviews.isDiscardable($0, appPreviews: $1) }
    var clearPreviews: (PreviewHome, Set<UUID>) -> (files: Int, bytes: Int64) = { LibraryPreviews.clear($0, sparing: $1) }
    var movePreview: (URL, PreviewHome) -> URL? = { LibraryPreviews.move($0, into: $1) }
    /// A develop written (`EngineHost.write` calls it): the folder chosen and made, the write handed each.
    var writeDevelop: (UUID, URL, (URL) -> URL?) -> URL? = { LibraryPreviews.write(for: $0, fallback: $1, $2) }
    /// Where a carried frame's develop is (review, 2026-11-05): there, moved with its library, away, gone.
    var locate: (URL, PreviewHome?, String) -> LibraryPreviews.Found = { LibraryPreviews.locate($0, carriedFrom: $1, volumes: $2) }
    /// The previews in SpektraLab's own libraries for folders and Capture One, for Settings › Storage.
    var measureOwn: (URL) -> (files: Int, bytes: Int64) = { LibraryPreviews.measureOwn(store: $0) }

    /// A change to the copies with nobody's copy able to go meanwhile: how a
    /// rule that holds no limit is made of one that does.
    static func holdingEverything<T>(_ copies: WorkingCopies, _ change: () -> T) -> T {
        let held = copies.inUse
        copies.inUse = { Set(copies.copies.keys) }
        defer { copies.inUse = held }
        return change()
    }

    /// A change to the copies with nobody said to be reading any.
    static func holdingNothing<T>(_ copies: WorkingCopies, _ change: () -> T) -> T {
        let held = copies.inUse
        copies.inUse = { [] }
        defer { copies.inUse = held }
        return change()
    }

    static var broken: [Rules] {
        var all: [Rules] = []
        func rule(_ name: String, _ change: (inout Rules) -> Void) {
            var r = Rules()
            r.name = name
            change(&r)
            all.append(r)
        }
        rule("past the limit, nothing goes") { $0.leaving = { _, _, _ in [] } }
        rule("the copy read last goes first") { r in
            r.leaving = { copies, limit, held in
                var bytes = copies.values.reduce(Int64(0)) { $0 + $1.bytes }
                var going: [UUID] = []
                for (id, copy) in copies.sorted(by: { $0.value.used > $1.value.used }) where !held.contains(id) {
                    guard bytes > limit else { break }
                    going.append(id)
                    bytes -= copy.bytes
                }
                return going
            }
        }
        rule("a copy that is being read can go") { $0.leaving = { copies, limit, _ in WorkingCopies.leaving(copies, limit: limit, held: []) } }
        rule("past the limit, every copy goes") { r in
            r.leaving = { copies, limit, held in
                copies.values.reduce(Int64(0)) { $0 + $1.bytes } > limit ? copies.keys.filter { !held.contains($0) } : []
            }
        }
        rule("an arrival does not hold the limit") { r in
            r.arrive = { c, file, id, name in holdingEverything(c) { c.keep(file, for: id, name: name) } }
        }
        rule("a lowered limit takes nothing") { r in
            r.setLimit = { c, limit in holdingEverything(c) { c.limit = limit } }
        }
        rule("a lowered limit takes a copy that is being read") { r in
            r.setLimit = { c, limit in holdingNothing(c) { c.limit = limit } }
        }
        rule("Clear takes a copy that is being read") { r in
            r.clear = { c in holdingNothing(c) { c.clear() } }
        }
        rule("Clear leaves copies nobody is reading") { $0.clear = { _ in 0 } }
        rule("a read is noted in the book and not on the file") { r in
            r.touch = { c, id in
                guard let url = c.copies[id]?.url else { return }
                let was = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                c.touch(id)
                if let was { try? FileManager.default.setAttributes([.modificationDate: was], ofItemAtPath: url.path) }
            }
        }
        rule("a read is not noted at all") { $0.touch = { _, _ in } }
        rule("a frame that leaves keeps its copy while it is being read") { r in
            r.remove = { c, ids in
                let held = c.inUse()
                c.remove(ids.filter { !held.contains($0) })
            }
        }
        rule("the launch's sweep leaves a removed frame's copy") { r in
            r.sweep = { c, known in c.sweep(known: known.union(c.copies.keys)) }
        }
        rule("a proxy is not under the copies' limit") { r in
            r.noteProxy = { c, url, bytes in
                let held = c.inUse
                c.inUse = { Set(c.copies.keys).union(c.proxies.keys.compactMap(WorkingCopies.proxyFrame)) }
                defer { c.inUse = held }
                c.noteProxy(url, bytes: bytes)
            }
        }
        rule("a written full render does not hold the renders' limit") { r in
            r.noteFull = { c, url, bytes in
                let held = c.fullInUse
                c.fullInUse = { Set(c.fulls.keys) }
                defer { c.fullInUse = held }
                c.noteFull(url, bytes: bytes)
            }
        }
        rule("one full render at a time (the rule until 2026-10-24)") { r in
            r.noteFull = { c, url, bytes in
                c.noteFull(url, bytes: bytes)
                let held = c.fullInUse
                c.fullInUse = { [url.lastPathComponent] }
                let limit = c.fullLimit
                c.fullLimit = 0
                c.fullInUse = held
                c.fullLimit = limit
            }
        }
        rule("the full render used last goes first") { r in
            r.leavingFull = { fulls, limit, held in
                var bytes = fulls.values.reduce(Int64(0)) { $0 + $1.bytes }
                var going: [String] = []
                for (name, f) in fulls.sorted(by: { $0.value.used > $1.value.used }) where !held.contains(name) {
                    guard bytes > limit else { break }
                    going.append(name); bytes -= f.bytes
                }
                return going
            }
        }
        rule("full renders counted, not weighed: two kept") { r in
            r.leavingFull = { fulls, _, held in
                Array(fulls.sorted { $0.value.used < $1.value.used }.map(\.key).filter { !held.contains($0) }.dropLast(2))
            }
        }
        rule("a full render in use can go") { $0.leavingFull = { fulls, limit, _ in WorkingCopies.leavingFull(fulls, limit: limit, held: []) } }
        rule("a lowered renders' limit takes nothing") { r in
            r.setFullLimit = { c, limit in
                let held = c.fullInUse
                c.fullInUse = { Set(c.fulls.keys) }
                defer { c.fullInUse = held }
                c.fullLimit = limit
            }
        }
        rule("a full render read is not a use") { r in
            r.noteFull = { c, url, bytes in if c.fulls[url.lastPathComponent] == nil { c.noteFull(url, bytes: bytes) } }
        }
        rule("the launch's sweep takes a copied-in RAW's proxy") { r in
            r.sweepLibrary = { c, known, _ in c.sweep(known: known) }
        }
        rule("the launch's sweep leaves a removed frame's proxy") { r in
            r.sweepLibrary = { c, known, library in c.sweep(known: known, library: library.union(c.proxies.keys.compactMap(WorkingCopies.proxyFrame))) }
        }
        rule("the launch's sweep leaves what a fetch ended in the middle left") { r in
            r.sweep = { c, known in
                let unknown = c.copies.keys.filter { !known.contains($0) }
                c.remove(unknown)
                return unknown.count
            }
        }
        rule("a copy is here under any name") { r in
            r.has = { c, id, _ in c.copies[id] != nil }
        }
        rule("the tidy takes a file a frame names") { $0.tidy = { folder, _, now in StorageTidy.sweep(folder, keeping: [], now: now) } }
        rule("the tidy takes a file just written") { $0.tidy = { folder, keeping, now in StorageTidy.sweep(folder, keeping: keeping, now: now, age: 0) } }
        rule("the tidy takes a file that is not the app's make") { r in
            r.tidy = { folder, keeping, now in
                var files = 0
                for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where !keeping.contains(file.lastPathComponent) {
                    let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date ?? now
                    if now.timeIntervalSince(written) >= 3600, (try? FileManager.default.removeItem(at: file)) != nil { files += 1 }
                }
                return (files, 0)
            }
        }
        rule("the tidy leaves what no frame names") { $0.tidy = { _, _, _ in (0, 0) } }
        rule("a stamp's word for a file is its whole path") { $0.word = { url, _ in url.standardizedFileURL.path } }
        rule("the launch's sweep leaves a removed frame's cards") { $0.sweepCards = { _, _ in (0, 0) } }
        rule("the launch's sweep takes the cards of a frame the library has") { $0.sweepCards = { folder, _ in StorageTidy.sweepCards(folder, keepingFrames: []) } }
        rule("the cards' limit is not held") { $0.holdCards = { _, _, _ in (0, 0) } }
        rule("the cards' limit takes the frame on the page") { $0.holdCards = { folder, limit, _ in StorageTidy.holdCards(folder, to: limit, sparing: nil) } }
        rule("the cards' limit takes the card shown last first") { r in
            r.holdCards = { folder, limit, sparing in
                var all: [(URL, Int64, Date, String)] = []
                for frame in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    for card in (try? FileManager.default.contentsOfDirectory(at: frame, includingPropertiesForKeys: nil)) ?? []
                    where StorageTidy.isCard(card.lastPathComponent) {
                        let a = try? FileManager.default.attributesOfItem(atPath: card.path)
                        all.append((card, (a?[.size] as? NSNumber)?.int64Value ?? 0, a?[.modificationDate] as? Date ?? .distantPast, frame.lastPathComponent))
                    }
                }
                var total = all.reduce(Int64(0)) { $0 + $1.1 }
                var files = 0
                for card in all.sorted(by: { $0.2 > $1.2 }) where card.3 != sparing?.uuidString {
                    guard total > limit else { break }
                    try? FileManager.default.removeItem(at: card.0)
                    total -= card.1
                    files += 1
                }
                return (files, 0)
            }
        }
        rule("a frame's cards of another source stay") { $0.dropCards = { _, _, _ in 0 } }
        // v0.2's rule: the cards on a cap of their own (32 MB there, 2,000 bytes at this check's scale),
        // whatever room the shared space has.
        rule("the cards keep a cap of their own") { $0.holdShared = { previews, _, sparing in
            StorageTidy.holdCards(StorageTidy.cardsFolder(in: previews), to: 2000, sparing: sparing) } }
        rule("the shared space leaves the renders out") { $0.holdShared = { previews, limit, sparing in
            StorageTidy.holdCards(StorageTidy.cardsFolder(in: previews), to: limit, sparing: sparing) } }
        rule("a render goes for a card") { r in
            r.holdShared = { previews, limit, sparing in
                for file in (try? FileManager.default.contentsOfDirectory(at: previews, includingPropertiesForKeys: nil)) ?? []
                where StorageTidy.isAppMade(file.lastPathComponent) && StorageTidy.renderBytes(in: previews) > limit {
                    try? FileManager.default.removeItem(at: file)
                }
                return StorageTidy.holdCards(sharing: previews, limit: limit, sparing: sparing)
            }
        }
        rule("the shared space takes the frame on the page") { $0.holdShared = { previews, limit, _ in
            StorageTidy.holdCards(sharing: previews, limit: limit, sparing: nil) } }
        // A library's previews (2026-11-05).
        rule("every develop goes to the app's Previews (2.1.3)") { $0.previewFolders = { _, fallback in [fallback] } }
        rule("a library that is not there is written to") { r in
            r.previewFolders = { id, fallback in LibraryPreviews.home(of: id).map { [$0.folder, fallback] } ?? [fallback] }
        }
        rule("a session's previews are where its scan walks") { r in
            r.previewFolder = { h in h.kind == .catalog ? h.folder
                : h.root.appendingPathComponent("SpektraLab/Cache/Previews", isDirectory: true) }
        }
        rule("a Capture One catalog is a library to write previews in") { r in
            r.previewHome = { root, kind in PreviewHome(root: root, kind: kind) ?? PreviewHome(root: URL(fileURLWithPath: "/nowhere/x.spkcatalog"), kind: .catalog) }
        }
        rule("the launch overrides the library a frame was carried from") { r in
            r.rememberPreviews = { all in
                for (id, file) in all { if let h = PreviewHome.of(previewsFolder: file.deletingLastPathComponent()) { LibraryPreviews.house([id], in: h) } }
            }
        }
        rule("a replaced develop in a library is left behind") { $0.discardable = { url, app in url.standardizedFileURL.path.hasPrefix(app.standardizedFileURL.path + "/") } }
        rule("a replaced develop's rule takes any file of a library") { r in
            r.discardable = { url, app in LibraryPreviews.isDiscardable(url, appPreviews: app) || url.path.contains(".spkcatalog/") || url.path.contains("/Capture/") }
        }
        rule("Delete Previews takes the open page's") { $0.clearPreviews = { h, _ in LibraryPreviews.clear(h, sparing: []) } }
        rule("Delete Previews takes what is not a develop") { r in
            r.clearPreviews = { h, sparing in
                let went = LibraryPreviews.clear(h, sparing: sparing)
                for f in (try? FileManager.default.contentsOfDirectory(at: h.folder, includingPropertiesForKeys: nil)) ?? []
                where LibraryPreviews.frame(ofDevelop: f.lastPathComponent) == nil { try? FileManager.default.removeItem(at: f) }
                return went
            }
        }
        rule("a migration overwrites a file in the library") { r in
            r.movePreview = { file, h in
                let target = h.folder.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                return LibraryPreviews.move(file, into: h)
            }
        }
        rule("a migration moves into a library that is not there") { r in
            r.movePreview = { file, h in
                let target = h.folder.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.createDirectory(at: h.folder, withIntermediateDirectories: true)
                return (try? FileManager.default.moveItem(at: file, to: target)) != nil ? target : nil
            }
        }
        // The review's fixes (2026-11-05).
        rule("a migration leaves the app's twin of a library's develop behind (round 1)") { r in
            r.movePreview = { file, h in
                FileManager.default.fileExists(atPath: h.folder.appendingPathComponent(file.lastPathComponent).path) ? nil : LibraryPreviews.move(file, into: h)
            }
        }
        rule("a develop's folder is made wherever its library was (EngineHost.write, round 1)") { r in
            r.writeDevelop = { id, fallback, body in
                for folder in LibraryPreviews.home(of: id).map({ [$0.folder, fallback] }) ?? [fallback] {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if let made = body(folder) { return made }
                }
                return nil
            }
        }
        rule("a develop that fails in its library is not written to the app's Previews") { r in
            r.writeDevelop = { id, fallback, body in
                LibraryPreviews.write(for: id, fallback: fallback) { folder in folder == fallback && LibraryPreviews.home(of: id) != nil ? nil : body(folder) }
            }
        }
        rule("a develop not where its frame says is left as it is (round 1)") { $0.locate = { _, _, _ in .there } }
        rule("a develop on a disk that is away is taken for gone") { r in
            r.locate = { f, h, v in let found = LibraryPreviews.locate(f, carriedFrom: h, volumes: v); return found == .away ? .gone : found }
        }
        rule("a develop gone from a disk that is here is taken for away") { r in
            r.locate = { f, h, v in let found = LibraryPreviews.locate(f, carriedFrom: h, volumes: v); return found == .gone ? .away : found }
        }
        rule("a moved library's develop is not looked for in it") { r in
            r.locate = { f, _, v in LibraryPreviews.locate(f, carriedFrom: nil, volumes: v) }
        }
        rule("the previews of the app's own libraries are not counted (round 1)") { $0.measureOwn = { _ in (0, 0) } }
        rule("the app's own libraries are counted whole") { r in
            r.measureOwn = { store in
                var files = 0
                var bytes: Int64 = 0
                guard let all = FileManager.default.enumerator(at: store, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
                for case let f as URL in all {
                    guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                    files += 1
                    bytes += Int64(v.fileSize ?? 0)
                }
                return (files, bytes)
            }
        }
        return all
    }
}

@MainActor
func run(_ rules: Rules, quiet: Bool) -> (passed: Int, failed: [String]) {
    var passed = 0
    var failed: [String] = []
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failed.append(what()); if !quiet { print("  FAIL  \(what())") } }
    }
    let files = FileManager.default
    let ground = files.temporaryDirectory.appendingPathComponent("storage-selftest-" + UUID().uuidString, isDirectory: true)
    defer { try? files.removeItem(at: ground) }
    func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path) }
    func age(_ url: URL, to date: Date) { try? files.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    func write(_ bytes: Int, to url: URL) {
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: url.path, contents: Data(count: bytes))
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: which copies go

    let p = UUID(), q = UUID(), r = UUID()
    func copy(_ bytes: Int64, _ seconds: TimeInterval) -> WorkingCopies.Copy {
        WorkingCopies.Copy(url: URL(fileURLWithPath: "/nowhere"), bytes: bytes, used: at(seconds))
    }
    let three = [p: copy(400, 10), q: copy(400, 20), r: copy(400, 30)]
    expect(rules.leaving(three, 1200, []) == [], "within the limit, nothing goes")
    expect(rules.leaving(three, 1000, []) == [p], "past the limit, the copy read longest ago goes, and only it")
    expect(rules.leaving(three, 500, []) == [p, q], "and as many as it takes, oldest first")
    expect(rules.leaving(three, 1000, [p]) == [q], "a copy that is being read is passed over for the next oldest")
    expect(rules.leaving(three, 0, [p, q, r]) == [], "and where every copy is being read, none goes")
    expect(rules.leaving([p: copy(100, 10), q: copy(900, 10)], 950, []) == [q], "of two read at one moment, the larger goes")

    // MARK: the working copies

    var clock = t0
    /// A fetch that came whole, kept as the frame's copy at `seconds` after the start.
    @discardableResult
    func arrive(_ copies: WorkingCopies, _ id: UUID, _ name: String, _ bytes: Int, at seconds: TimeInterval) -> URL? {
        clock = at(seconds)
        guard let place = copies.incoming() else { return nil }
        let file = place.appendingPathComponent(name)
        write(bytes, to: file)
        return rules.arrive(copies, file, id, name)
    }

    let folder = ground.appendingPathComponent("WorkingCopies", isDirectory: true)
    let copies = WorkingCopies(folder: folder, limit: 1000)
    copies.now = { clock }
    var changes = 0
    copies.onChange = { changes += 1 }
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    // A copy is one file in a folder of its frame's, under the original's own name.
    expect(WorkingCopies.fileName("IMG_4120.DNG") == "IMG_4120.DNG", "an original's name is its copy's name")
    expect(WorkingCopies.fileName("a/b:c.DNG") == "a_b_c.DNG", "a name that would name another folder does not")
    expect(WorkingCopies.fileName("") == "original" && WorkingCopies.fileName("..") == "original", "a name that is no name is given one")
    let placeA = arrive(copies, a, "IMG_0001.HEIC", 400, at: 10)
    expect(placeA == WorkingCopies.url(in: folder, for: a, name: "IMG_0001.HEIC") && placeA.map(exists) == true,
           "a fetch that came whole is the frame's copy, at the one place it is asked for")
    expect(((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).allSatisfy { !$0.hasPrefix(".incoming-") },
           "and the folder it was fetched into is gone")
    expect(rules.has(copies, a, "IMG_0001.HEIC") && copies.bytes == 400, "the book has it, at its size")
    expect(!rules.has(copies, a, "IMG_0001.DNG"), "a copy under another name is not the copy asked for")
    expect(changes == 1, "and whoever shows what the app keeps is told (\(changes) times)")

    // The limit is held as a copy arrives.
    arrive(copies, b, "IMG_0002.HEIC", 400, at: 20)
    expect(copies.bytes == 800 && rules.has(copies, a, "IMG_0001.HEIC"), "two copies within the limit both stay")
    arrive(copies, c, "IMG_0003.HEIC", 400, at: 30)
    expect(!rules.has(copies, a, "IMG_0001.HEIC") && rules.has(copies, b, "IMG_0002.HEIC") && rules.has(copies, c, "IMG_0003.HEIC"),
           "an arrival past the limit takes the copy read longest ago, and the others stay")
    expect(copies.bytes <= copies.limit, "what is left is within the limit (\(copies.bytes) of \(copies.limit))")
    expect(!exists(folder.appendingPathComponent(a.uuidString)), "and the copy that went is gone from the disk, folder and all")

    // A read makes a copy the newest.
    clock = at(40)
    rules.touch(copies, b)
    arrive(copies, d, "IMG_0004.HEIC", 400, at: 50)
    expect(rules.has(copies, b, "IMG_0002.HEIC") && !rules.has(copies, c, "IMG_0003.HEIC") && rules.has(copies, d, "IMG_0004.HEIC"),
           "a copy that was read since is kept over one that was not")

    // The order is the files' own: it is the same after the app has been ended.
    let again = WorkingCopies(folder: folder, limit: 1000)
    expect(Set(again.copies.keys) == [b, d] && again.bytes == 800, "the book read again from the disk is the same book")
    expect(again.copies[b]?.used == at(40) && again.copies[d]?.used == at(50), "with each copy's last read as it was")
    clock = at(60)
    rules.touch(copies, d)
    clock = at(61)
    rules.touch(copies, b)
    let third = WorkingCopies(folder: folder, limit: 1000)
    expect(third.copies[b]?.used == at(61) && third.copies[d]?.used == at(60),
           "a read is kept with the file: the order survives the app being ended")

    // A lowered limit is held at once; a copy being read is never taken, and the limit is over only by that.
    copies.inUse = { [d] }
    rules.setLimit(copies, 300)
    expect(rules.has(copies, d, "IMG_0004.HEIC"), "a copy that is being read is not taken, limit or no limit")
    expect(!rules.has(copies, b, "IMG_0002.HEIC") && copies.bytes == 400, "and a lowered limit takes every other, at once")
    // The copy that has just arrived is about to be read: its own arrival does not take it.
    let placeE = arrive(copies, e, "IMG_0005.DNG", 500, at: 70)
    expect(placeE.map(exists) == true && rules.has(copies, e, "IMG_0005.DNG"), "a copy is not taken by its own arrival")
    copies.inUse = { [] }
    rules.setLimit(copies, 600)
    copies.trim()
    expect(!rules.has(copies, d, "IMG_0004.HEIC") && rules.has(copies, e, "IMG_0005.DNG") && copies.bytes == 500,
           "once nothing is being read, the copies are back within the limit, oldest first")

    // A copy the disk no longer has is struck from the book.
    if let gone = copies.copies[e]?.url { try? files.removeItem(at: gone) }
    expect(!rules.has(copies, e, "IMG_0005.DNG") && copies.bytes == 0, "a copy the disk no longer has is not in the book")

    // Clear Working Copies: all but those in use.
    rules.setLimit(copies, 10_000)
    let x = UUID(), y = UUID(), z = UUID()
    arrive(copies, x, "X.HEIC", 100, at: 80)
    arrive(copies, y, "Y.HEIC", 200, at: 81)
    arrive(copies, z, "Z.HEIC", 300, at: 82)
    copies.inUse = { [y] }
    let freed = rules.clear(copies)
    expect(!rules.has(copies, x, "X.HEIC") && !rules.has(copies, z, "Z.HEIC"), "Clear takes every copy nobody is reading")
    expect(rules.has(copies, y, "Y.HEIC") && copies.bytes == 200, "and leaves the one that is being read")
    expect(freed == 400, "and says what it freed (\(freed) bytes)")

    // A frame that leaves the library takes its copy, in use or not.
    rules.remove(copies, [y])
    expect(!rules.has(copies, y, "Y.HEIC") && copies.bytes == 0 && !exists(folder.appendingPathComponent(y.uuidString)),
           "a frame that leaves the library takes its copy with it")
    copies.inUse = { [] }

    // At launch: what is not a copy of a frame of the library goes.
    let kept = UUID(), removed = UUID(), empty = UUID()
    arrive(copies, kept, "KEPT.DNG", 100, at: 90)
    arrive(copies, removed, "REMOVED.DNG", 100, at: 91)
    write(50, to: folder.appendingPathComponent(".incoming-" + UUID().uuidString).appendingPathComponent("HALF.DNG"))
    write(10, to: folder.appendingPathComponent("stray.txt"))
    try? files.createDirectory(at: folder.appendingPathComponent(empty.uuidString), withIntermediateDirectories: true)
    let launched = WorkingCopies(folder: folder, limit: 10_000)
    let went = rules.sweep(launched, [kept])
    let left = Set((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
    expect(left == [kept.uuidString], "at launch only the copies of frames the library has are left (\(left.sorted()))")
    expect(went >= 4, "and the sweep says how much went (\(went))")
    expect(rules.has(launched, kept, "KEPT.DNG") && launched.bytes == 100, "the copy of a frame the library has is untouched")

    // Nowhere to keep copies: none are kept, and nothing is asked of the disk.
    let none = WorkingCopies(folder: nil, limit: 1000)
    expect(none.incoming() == nil && none.bytes == 0 && none.clear() == 0 && none.sweep(known: []) == 0,
           "a library that keeps nothing on disk keeps no copies")

    // MARK: a RAW's proxy, in the copies' book

    do {
        let pfolder = ground.appendingPathComponent("WorkingCopiesProxies", isDirectory: true)
        let book = WorkingCopies(folder: pfolder, limit: 1000)
        book.now = { clock }
        let photo = UUID(), b1 = UUID(), b2 = UUID(), b3 = UUID(), b4 = UUID(), gone = UUID()
        /// A proxy of `frame` written at `seconds`, and told to the book.
        @discardableResult
        func proxy(_ frame: UUID, _ bytes: Int, at seconds: TimeInterval) -> URL {
            clock = at(seconds)
            let url = book.proxyFolder!.appendingPathComponent(frame.uuidString + "-0123456789abcdef.spkraw")
            write(bytes, to: url)
            rules.noteProxy(book, url, Int64(bytes))
            return url
        }
        expect(book.proxyFolder == pfolder.appendingPathComponent(".proxies", isDirectory: true), "the proxies are kept inside the copies' folder")
        let photoCopy = arrive(book, photo, "IMG_0002.DNG", 400, at: 10)
        let p1 = proxy(b1, 400, at: 20)
        expect(exists(p1) && book.bytes == 800, "a proxy is in the book beside the copies (\(book.bytes) bytes)")
        let p2 = proxy(b2, 400, at: 30)
        expect(photoCopy.map(exists) == false && exists(p1) && exists(p2) && book.bytes == 800,
               "copies and proxies share one limit: past it, the oldest of either kind goes (here the copy)")
        let p3 = proxy(b3, 400, at: 40)
        expect(!exists(p1) && exists(p2) && exists(p3), "and the proxy read longest ago goes as readily as a copy")
        book.inUse = { [b2] }
        let p4 = proxy(b4, 400, at: 50)
        expect(exists(p2) && !exists(p3) && exists(p4), "a proxy of a frame being read is never taken: the next oldest goes")
        book.inUse = { [] }
        let again = WorkingCopies(folder: pfolder, limit: 1000)
        expect(again.proxies.count == 2 && again.bytes == 800, "a launch finds the proxies in the folder (\(again.proxies.count), \(again.bytes) bytes)")
        // The launch's sweep: no frame of this library is read from Photos; b2 and b4 are copied-in RAWs.
        let stray = book.proxyFolder!.appendingPathComponent(gone.uuidString + "-0123456789abcdef.spkraw")
        write(100, to: stray)
        let partial = book.proxyFolder!.appendingPathComponent(".partial-" + UUID().uuidString)
        write(100, to: partial)
        let late = WorkingCopies(folder: pfolder, limit: 1000)
        _ = rules.sweepLibrary(late, [], [b2, b4])
        expect(exists(p2) && exists(p4), "the launch's sweep keeps the proxy of every frame in the library, from Photos or not")
        expect(!exists(stray), "and takes the proxy of a frame no longer in it")
        expect(!exists(partial), "and what a proxy the app was ended in the middle of writing left")
        late.inUse = { [b4] }
        late.clear()
        expect(!exists(p2) && exists(p4), "Clear Working Copies takes the proxies too, never one of a frame being read")
        late.inUse = { [] }
        late.remove([b4])
        expect(!exists(p4) && late.bytes == 0, "a frame that leaves the library takes its proxy with it")

        // The full-size renders (`FullRender`): in the same book, under a limit of their own, an LRU by bytes.
        expect(rules.leavingFull([:], 0, []) == [], "no renders, none go")
        let f = UUID(), g = UUID(), h = UUID()
        func full(_ frame: UUID, _ bytes: Int64, _ seconds: TimeInterval) -> (String, WorkingCopies.Copy) {
            (frame.uuidString + "-0123456789abcdef.spkfull", WorkingCopies.Copy(url: URL(fileURLWithPath: "/nowhere"), bytes: bytes, used: at(seconds)))
        }
        let three3 = Dictionary(uniqueKeysWithValues: [full(f, 900, 10), full(g, 100, 20), full(h, 300, 30)])
        let nf = full(f, 0, 0).0, ng = full(g, 0, 0).0, nh = full(h, 0, 0).0
        expect(rules.leavingFull(three3, 1300, []) == [], "renders within their limit: all kept")
        expect(rules.leavingFull(three3, 1200, []) == [nf], "past it, the one used longest ago goes, and only it, however large")
        expect(rules.leavingFull(three3, 350, []) == [nf, ng], "as many as it takes, oldest first, by bytes")
        expect(rules.leavingFull(three3, 350, [nf]) == [ng, nh], "one in use is passed over")
        expect(rules.leavingFull(three3, 0, [nf, ng, nh]) == [], "and where every one is in use, none goes")

        let fullsAt = ground.appendingPathComponent("fulls", isDirectory: true)
        let fb = WorkingCopies(folder: fullsAt, limit: 1000, fullLimit: 1000)
        fb.now = { clock }
        fb.inUse = { [] }
        var shown: Set<String> = []
        fb.fullInUse = { shown }
        let r1 = UUID(), r2 = UUID(), r3 = UUID(), r4 = UUID(), r5 = UUID()
        func render(_ frame: UUID, _ bytes: Int, at seconds: TimeInterval) -> URL {
            clock = at(seconds)
            let url = fb.proxyFolder!.appendingPathComponent(frame.uuidString + "-fedcba9876543210.spkfull")
            write(bytes, to: url)
            rules.noteFull(fb, url, Int64(bytes))
            return url
        }
        let u1 = render(r1, 300, at: 60), u2 = render(r2, 500, at: 70), u3 = render(r3, 200, at: 80)
        expect(exists(u1) && exists(u2) && exists(u3) && fb.fullBytes == 1000, "renders up to their limit are all kept, not one at a time (\(fb.fullBytes) bytes)")
        let u4 = render(r4, 400, at: 90)
        expect(!exists(u1) && !exists(u2) && exists(u3) && exists(u4) && fb.fullBytes == 600,
               "past it the oldest go, by bytes, until under: two went for one (\(fb.fullBytes) bytes)")
        clock = at(100); rules.noteFull(fb, u3, 200)                       // the page shows it again, or an export reads it
        expect(fb.fulls[u3.lastPathComponent]?.used == at(100)
               && (try? files.attributesOfItem(atPath: u3.path))?[.modificationDate] as? Date == at(100),
               "a render read is the one used most recently, on its file's own date")
        shown = [u4.lastPathComponent]                                      // the page's, used before u3
        let u5 = render(r5, 600, at: 110)
        expect(exists(u4) && !exists(u3) && exists(u5), "the render in use stays though it is the oldest; the next oldest goes")
        // A launch: the same renders, in the same order, from the files' dates.
        let relaunched = WorkingCopies(folder: fullsAt, limit: 1000, fullLimit: 1000)
        let orderBefore = fb.fulls.sorted { $0.value.used < $1.value.used }.map(\.key)
        let orderAfter = relaunched.fulls.sorted { $0.value.used < $1.value.used }.map(\.key)
        expect(orderAfter == orderBefore && relaunched.fullBytes == fb.fullBytes, "a launch finds the renders in the order they were used")
        expect(relaunched.proxies.isEmpty, "and not among the proxies")
        // Their limit, not the copies': a proxy of 900 bytes under the copies' 1,000 stays beside 1,000 of renders.
        clock = at(115)
        let px = fb.proxyFolder!.appendingPathComponent(r5.uuidString + "-0123456789abcdef.spkraw")
        write(900, to: px)
        rules.noteProxy(fb, px, 900)
        expect(exists(px) && exists(u4) && exists(u5), "the renders are not counted in the copies' limit, nor the copies in theirs")
        rules.setFullLimit(fb, 500)
        expect(exists(u4) && !exists(u5) && fb.fullBytes == 400, "a lowered limit is held at once, the render in use kept (\(fb.fullBytes) bytes)")
        rules.setFullLimit(fb, 1)
        expect(exists(u4), "under a limit smaller than any render, the one in use stays")
        shown = []
        rules.setFullLimit(fb, 1000)
        let u6 = render(r1, 300, at: 120)
        shown = [u6.lastPathComponent]
        _ = rules.clear(fb)
        expect(!exists(u4) && exists(u6), "Clear takes the renders, never one in use")
        shown = []
        rules.remove(fb, [r1])
        expect(!exists(u6) && fb.fullBytes == 0, "a frame that leaves the library takes its render")
        let u7 = render(r2, 100, at: 130)
        _ = rules.sweepLibrary(fb, [], [r3])
        expect(!exists(u7), "the launch's sweep takes the render of a frame no longer in the library")
    }

    // MARK: the launch's tidy of Previews

    let previews = ground.appendingPathComponent("Previews", isDirectory: true)
    let now = at(100_000)
    let old = now.addingTimeInterval(-7200), fresh = now.addingTimeInterval(-60)
    let frame = UUID().uuidString
    func plant(_ name: String, _ bytes: Int, _ date: Date) -> URL {
        let url = previews.appendingPathComponent(name)
        write(bytes, to: url)
        age(url, to: date)
        return url
    }
    let named = plant("dev-\(frame)-0011223344556677.heic", 1000, old)
    let orphanDevelop = plant("dev-\(UUID().uuidString)-8899aabbccddeeff.heic", 700, old)
    let justWritten = plant("dev-\(UUID().uuidString)-0102030405060708.heic", 600, fresh)
    let orphanPreview = plant(UUID().uuidString + ".jpg", 500, old)
    let namedPreview = plant(UUID().uuidString + ".jpg", 450, old)
    let orphanGuide = plant("pair-\(UUID().uuidString)-1a2b3c4d.jpg", 300, old)
    let foreign = plant("IMG_0001.jpg", 200, old)
    let folderOfIts = previews.appendingPathComponent("dev-a-folder", isDirectory: true)
    try? files.createDirectory(at: folderOfIts, withIntermediateDirectories: true)
    age(folderOfIts, to: old)

    expect(StorageTidy.isAppMade(named.lastPathComponent) && StorageTidy.isAppMade(orphanPreview.lastPathComponent)
           && StorageTidy.isAppMade(orphanGuide.lastPathComponent), "a kept develop, a preview copy and a pair's guide are the app's make")
    expect(!StorageTidy.isAppMade("IMG_0001.jpg") && !StorageTidy.isAppMade("notes.txt") && !StorageTidy.isAppMade(UUID().uuidString + ".heic"),
           "and a file under any other name is not")
    let tidied = rules.tidy(previews, [named.lastPathComponent, namedPreview.lastPathComponent], now)
    expect(!exists(orphanDevelop) && !exists(orphanPreview) && !exists(orphanGuide),
           "a kept develop, a preview copy and a guide that no frame names go")
    expect(exists(named) && exists(namedPreview), "a file a frame names stays")
    expect(exists(justWritten), "a file written within the hour stays: the library may not have been told of it yet")
    expect(exists(foreign) && exists(folderOfIts), "what is not the app's make, and what is not a file, stays")
    expect(tidied.files == 3 && tidied.bytes == 1500, "and the tidy says what went (\(tidied.files) files, \(tidied.bytes) bytes)")

    // A stamp's word for a file does not move with the app's folder.
    let before = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/AAAA/Library/Application Support/SpektraLab")
    let after = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/BBBB/Library/Application Support/SpektraLab")
    let inside = "Originals/\(frame)/SPK_0001.DNG"
    expect(rules.word(before.appendingPathComponent(inside), before) == inside, "a file under the app's folder is named from there")
    expect(rules.word(before.appendingPathComponent(inside), before) == rules.word(after.appendingPathComponent(inside), after),
           "so its word is the same after the app's folder has moved")
    let outside = URL(fileURLWithPath: "/Volumes/SANDISK SSD/DCIM/100RICOH/R0001.DNG")
    expect(rules.word(outside, before) == outside.standardizedFileURL.path, "a file anywhere else is named by its whole path")

    // MARK: Develop's cards, under Previews/Stocks

    let stocks = StorageTidy.cardsFolder(in: previews)
    let onPage = UUID(), keptFrame = UUID(), removedFrame = UUID()
    func card(_ frame: UUID, _ source: String, _ key: String, _ bytes: Int, _ date: Date) -> URL {
        let url = StorageTidy.cardFile(frame: frame, source: source, key: key, in: stocks)
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(bytes, to: url)
        age(url, to: date)
        return url
    }
    let oldest = card(onPage, "0a0b0c0d", "00112233445566ff", 1000, at(10))
    let older = card(keptFrame,"1a1b1c1d", "0011223344556677", 1000, at(20))
    let newer = card(keptFrame,"1a1b1c1d", "8899aabbccddeeff", 1000, at(30))
    let gone = card(removedFrame, "2a2b2c2d", "0123456789abcdef", 700, at(5))
    let foreignCard = stocks.appendingPathComponent(keptFrame.uuidString).appendingPathComponent("notes.txt")
    write(50, to: foreignCard)
    let foreignFolder = stocks.appendingPathComponent("not-a-frame", isDirectory: true)
    try? files.createDirectory(at: foreignFolder, withIntermediateDirectories: true)
    write(50, to: foreignFolder.appendingPathComponent("0a0b0c0d-00112233445566ff.jpg"))
    expect(StorageTidy.isCard(oldest.lastPathComponent) && !StorageTidy.isCard("notes.txt")
           && !StorageTidy.isCard("0a0b0c0d-00112233445566ff.heic") && !StorageTidy.isCard("0A0B0C0D-00112233445566FF.jpg")
           && !StorageTidy.isCard("0a0b0c0d00112233445566ff.jpg"), "a card's name is eight hex, a dash, sixteen hex, .jpg; nothing else is")
    let swept = rules.sweepCards(stocks, [onPage, keptFrame])
    expect(!exists(gone) && !exists(gone.deletingLastPathComponent()), "at launch the cards of a frame the library no longer has go, with their folder")
    expect(exists(oldest) && exists(older) && exists(newer), "and the cards of a frame it has stay")
    expect(exists(foreignCard) && exists(foreignFolder), "what is not a card, or not in a frame's folder, stays")
    expect(swept.files == 1 && swept.bytes == 700, "and the sweep says what went (\(swept.files) files, \(swept.bytes) bytes)")
    // 3,000 bytes against a limit of 2,000: the card shown longest ago goes -- not the frame on the page's,
    // older still -- and no more than that.
    let held = rules.holdCards(stocks, 2000, onPage)
    expect(!exists(older), "past the cards' limit the one shown longest ago goes first")
    expect(exists(newer), "and only as many as bring them under it")
    expect(exists(oldest), "a card of the frame on the page never goes for the limit")
    expect(exists(foreignCard), "the limit takes nothing that is not a card")
    expect(held.files == 1 && held.bytes == 1000, "and the limit says what went (\(held.files) files, \(held.bytes) bytes)")
    let other = card(keptFrame,"3a3b3c3d", "fedcba9876543210", 900, at(40))
    let dropped = rules.dropCards(keptFrame, "3a3b3c3d", stocks)
    expect(!exists(newer) && exists(other), "a frame's cards read from another source go when one of its new source is written")
    expect(exists(oldest) && exists(foreignCard) && dropped == 1, "and no other frame's, and nothing that is not a card (\(dropped))")

    // The space shared with the renders: Previews' own files (named 1000, justWritten 600, namedPreview 450,
    // foreign 200 -- 2,250 bytes) and the cards (oldest 1000 on the page, other 900, and two more).
    let first = card(keptFrame, "3a3b3c3d", "aaaaaaaaaaaaaaaa", 1000, at(50))
    let second = card(keptFrame, "3a3b3c3d", "bbbbbbbbbbbbbbbb", 1000, at(60))
    let renders = [named, justWritten, namedPreview, foreign]
    expect(StorageTidy.renderBytes(in: previews) == 2250, "the renders are what lies in Previews itself (\(StorageTidy.renderBytes(in: previews)) bytes)")
    let roomy = rules.holdShared(previews, 10_000, onPage)
    expect(exists(oldest) && exists(other) && exists(first) && exists(second) && roomy.files == 0,
           "while the shared space has room every card stays: 3,900 bytes of cards, no cap of their own (\(roomy.files) went)")
    let tight = rules.holdShared(previews, 2250 + 3900 - 1, onPage)
    expect(!exists(other) && exists(first) && exists(second) && tight.files == 1,
           "one byte over the shared limit, the card shown longest ago goes, and only it (\(tight.files) went)")
    expect(exists(oldest), "and the frame on the page keeps its cards, older still")
    let starved = rules.holdShared(previews, 1000, onPage)
    expect(!exists(first) && !exists(second) && starved.files == 2, "where the renders take the whole space every other card goes (\(starved.files))")
    expect(renders.allSatisfy(exists), "and not one render goes for a card: the renders come first")
    expect(exists(oldest), "the frame on the page keeps its cards even then")

    // MARK: a library's previews (`LibraryPreviews`, 2026-11-05)

    // A catalog's package with its database, a session's folder with its own and its four folders, and the
    // app's Previews; nothing here is a real library, only the shapes the helper makes (`library.cpp`).
    let libraries = ground.appendingPathComponent("Libraries", isDirectory: true)
    let appPreviews = ground.appendingPathComponent("App/Previews", isDirectory: true)
    let catalogRoot = libraries.appendingPathComponent("Trip.spkcatalog", isDirectory: true)
    let database = catalogRoot.appendingPathComponent(PreviewHome.catalogDatabase)
    write(64, to: database)
    let sessionRoot = libraries.appendingPathComponent("Shoot", isDirectory: true)
    write(64, to: sessionRoot.appendingPathComponent("Shoot.spksession"))
    let shot = sessionRoot.appendingPathComponent("Capture/IMG_0001.JPG")
    write(500, to: shot)
    let movedRoot = libraries.appendingPathComponent("Moved.spkcatalog", isDirectory: true)
    guard let catalog = rules.previewHome(catalogRoot, .catalog), let session = rules.previewHome(sessionRoot, .session),
          let gone = rules.previewHome(movedRoot, .catalog) else {
        expect(false, "a SpektraLab catalog and session are libraries to keep previews in")
        return (passed, failed)
    }
    func bytes(_ url: URL) -> Int64 { ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1 }
    func dev(_ frame: UUID, _ stamp: String) -> String { "dev-\(frame.uuidString)-\(stamp).heic" }

    // The layout.
    let catalogFolder = rules.previewFolder(catalog), sessionFolder = rules.previewFolder(session)
    expect(catalogFolder.path == catalogRoot.path + "/Cache/Previews", "a catalog's previews are in its package, Cache/Previews (\(catalogFolder.path))")
    let inSession = String(sessionFolder.path.dropFirst(sessionRoot.path.count + 1))
    expect(sessionFolder.path.hasPrefix(sessionRoot.path + "/") && inSession.hasPrefix("."),
           "a session's previews are in its folder, under a hidden name its scan and sync do not walk (\(inSession))")
    expect(PreviewHome.of(previewsFolder: catalogFolder) == catalog && PreviewHome.of(previewsFolder: sessionFolder) == session,
           "a previews folder names its library back, from its path alone")
    let c1 = libraries.appendingPathComponent("Studio.cocatalog", isDirectory: true)
    expect(rules.previewHome(c1, .catalog) == nil, "a Capture One catalog is never a library to write previews in")
    expect(rules.previewHome(c1.appendingPathComponent("Inside.spkcatalog"), .catalog) == nil, "nor a catalog inside one")
    expect(rules.previewHome(libraries.appendingPathComponent("Plain"), .catalog) == nil, "a catalog is a .spkcatalog")

    // Where a develop is written.
    let carried = UUID(), loose = UUID(), away = UUID()
    LibraryPreviews.house([carried], in: catalog)
    LibraryPreviews.house([away], in: gone)
    expect(rules.previewFolders(carried, appPreviews) == [catalogFolder, appPreviews],
           "a frame carried from a catalog keeps its develop there, the app's Previews if that write fails")
    expect(rules.previewFolders(loose, appPreviews) == [appPreviews], "a frame of no library keeps its develop in the app's Previews, as before")
    expect(rules.previewFolders(away, appPreviews) == [appPreviews], "a library that is not there (moved, its disk away) is not written to")
    // The write itself, as `EngineHost.write` makes it: the folder chosen and made, the picture handed each.
    func writing(_ id: UUID, failingIn bad: URL? = nil) -> URL? {
        rules.writeDevelop(id, appPreviews) { folder in
            guard folder != bad else { return nil }
            let url = folder.appendingPathComponent(dev(id, "0123456789abcdef"))
            return files.createFile(atPath: url.path, contents: Data(count: 10)) ? url : nil
        }
    }
    let wrote = writing(carried)
    expect(wrote?.deletingLastPathComponent() == catalogFolder && wrote.map(exists) == true,
           "a develop of a frame carried from a catalog is written into its previews, the folder made (\(wrote?.path ?? "none"))")
    let wroteAway = writing(away)
    expect(wroteAway?.deletingLastPathComponent() == appPreviews && wroteAway.map(exists) == true,
           "a develop of a frame whose library is not there is written to the app's Previews (\(wroteAway?.path ?? "none"))")
    expect(!exists(movedRoot), "and nothing is made where that library was")
    let failing = UUID()
    LibraryPreviews.house([failing], in: catalog)
    let wroteBack = writing(failing, failingIn: catalogFolder)
    expect(wroteBack?.deletingLastPathComponent() == appPreviews, "a write that fails in the library (a disk gone in the middle) lands in the app's Previews")
    let inSessionWrite = UUID()
    LibraryPreviews.house([inSessionWrite], in: session)
    let wroteSession = writing(inSessionWrite)
    expect(wroteSession?.deletingLastPathComponent() == sessionFolder, "a session's develop is written into its hidden previews, the folders made")
    [wrote, wroteAway, wroteBack, wroteSession].compactMap { $0 }.forEach { try? files.removeItem(at: $0) }

    // At launch: the library a develop already lies in, unless the frame was carried from another since.
    let atLaunch = UUID(), carriedElsewhere = UUID(), inApp = UUID()
    LibraryPreviews.house([carriedElsewhere], in: catalog)
    rules.rememberPreviews([(atLaunch, sessionFolder.appendingPathComponent(dev(atLaunch, "0011223344556677"))),
                            (carriedElsewhere, sessionFolder.appendingPathComponent(dev(carriedElsewhere, "0011223344556677"))),
                            (inApp, appPreviews.appendingPathComponent(dev(inApp, "0011223344556677")))])
    expect(rules.previewFolders(atLaunch, appPreviews).first == sessionFolder,
           "at launch a frame whose develop lies in a session's previews is that session's")
    expect(rules.previewFolders(carriedElsewhere, appPreviews).first == catalogFolder, "unless it was carried from another library since")
    expect(rules.previewFolders(inApp, appPreviews) == [appPreviews], "a develop in the app's Previews names no library")

    // A replaced develop goes wherever it was; nothing else of a library ever does.
    let devName = dev(UUID(), "0011223344556677")
    expect(rules.discardable(appPreviews.appendingPathComponent(devName), appPreviews), "a replaced develop in the app's Previews goes")
    expect(rules.discardable(catalogFolder.appendingPathComponent(devName), appPreviews), "and one in a catalog's previews")
    expect(rules.discardable(sessionFolder.appendingPathComponent(devName), appPreviews), "and one in a session's")
    expect(!rules.discardable(database, appPreviews), "never the catalog's database")
    expect(!rules.discardable(shot, appPreviews), "never a picture in the session's Capture folder")
    expect(!rules.discardable(catalogFolder.appendingPathComponent("notes.txt"), appPreviews), "never a file in a previews folder that is not a develop")
    expect(!rules.discardable(sessionRoot.appendingPathComponent("Capture/" + devName), appPreviews), "never a develop's name outside a previews folder")

    // Delete Previews: the library's develops, but the open page's; nothing else, nothing of another library.
    let open = UUID(), other1 = UUID(), other2 = UUID()
    let keptOpen = catalogFolder.appendingPathComponent(dev(open, "aaaaaaaaaaaaaaaa"))
    let kept1 = catalogFolder.appendingPathComponent(dev(other1, "aaaaaaaaaaaaaaaa"))
    let kept2 = catalogFolder.appendingPathComponent(dev(other2, "bbbbbbbbbbbbbbbb"))
    let note = catalogFolder.appendingPathComponent("notes.txt")
    let sessionKept = sessionFolder.appendingPathComponent(dev(other1, "cccccccccccccccc"))
    write(300, to: keptOpen); write(200, to: kept1); write(100, to: kept2); write(10, to: note); write(50, to: sessionKept)
    let counted = LibraryPreviews.measure(catalog)
    expect(counted.files == 3 && counted.bytes == 600, "a library's previews are counted: its develops only (\(counted.files) files, \(counted.bytes) bytes)")
    let cleared = rules.clearPreviews(catalog, [open])
    expect(!exists(kept1) && !exists(kept2) && cleared.files == 2 && cleared.bytes == 300,
           "Delete Previews takes the library's develops (\(cleared.files) files, \(cleared.bytes) bytes)")
    expect(exists(keptOpen), "but the one of the frame an open develop page shows")
    expect(exists(note) && exists(database), "and nothing that is not a develop")
    expect(exists(sessionKept), "and nothing of another library")

    // The migration: a 2.1.3 develop in the app's Previews moves into the library it is carried from.
    let legacy = appPreviews.appendingPathComponent(dev(UUID(), "dddddddddddddddd"))
    write(400, to: legacy)
    let moved = rules.movePreview(legacy, session)
    expect(moved == sessionFolder.appendingPathComponent(legacy.lastPathComponent) && moved.map(exists) == true && !exists(legacy),
           "a develop in the app's Previews moves into the library it is carried from, under its own name")
    let twin = appPreviews.appendingPathComponent(keptOpen.lastPathComponent)
    write(77, to: twin)
    let adopted = rules.movePreview(twin, catalog)
    expect(bytes(keptOpen) == 300, "never over a file already there")
    expect(adopted == keptOpen && !exists(twin),
           "where the library already has the develop's name (the same frame, the same stamp), that one is the frame's and the app's copy goes")
    let stray = appPreviews.appendingPathComponent(dev(UUID(), "eeeeeeeeeeeeeeee"))
    write(40, to: stray)
    expect(rules.movePreview(stray, gone) == nil && exists(stray), "never into a library that is not there; the develop stays where it was")
    expect(!exists(movedRoot), "and nothing is made where that library was")

    // A catalog moved in Finder (review, 2026-11-05): its previews travel in the package, and a frame carried
    // from it where it is now finds its develop there under its own name; one gone from a disk that is here is
    // gone (made again); one on a disk that is not mounted is away (left as it is).
    let roamRoot = libraries.appendingPathComponent("Roam.spkcatalog", isDirectory: true)
    write(64, to: roamRoot.appendingPathComponent(PreviewHome.catalogDatabase))
    let roamFrame = UUID()
    let roamWas = roamRoot.appendingPathComponent("Cache/Previews/" + dev(roamFrame, "1212121212121212"))
    write(120, to: roamWas)
    let volumes = ground.appendingPathComponent("Volumes", isDirectory: true)
    try? files.createDirectory(at: volumes, withIntermediateDirectories: true)
    expect(rules.locate(roamWas, PreviewHome(root: roamRoot, kind: .catalog), volumes.path) == .there, "a develop where its frame says is there")
    let elsewhere = libraries.appendingPathComponent("Elsewhere/Roam.spkcatalog", isDirectory: true)
    try? files.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? files.moveItem(at: roamRoot, to: elsewhere)
    let roamed = PreviewHome(root: elsewhere, kind: .catalog)
    let roamNow = elsewhere.appendingPathComponent("Cache/Previews/" + roamWas.lastPathComponent)
    expect(exists(roamNow) && !exists(roamWas), "(the package moved, its previews in it)")
    expect(rules.locate(roamWas, roamed, volumes.path) == .at(roamNow),
           "a catalog moved in Finder: a frame carried from it finds its develop in the moved package, under its own name")
    expect(rules.locate(roamWas, PreviewHome(root: catalogRoot, kind: .catalog), volumes.path) == .gone,
           "but not in another library: carried from one that does not have it, it is gone")
    try? files.removeItem(at: elsewhere.appendingPathComponent("Cache"))
    expect(rules.locate(roamWas, roamed, volumes.path) == .gone, "its Cache deleted, the develop is gone from a disk that is here: made again")
    let onDisk = volumes.appendingPathComponent("Far/Trip.spkcatalog/Cache/Previews/" + dev(UUID(), "3434343434343434"))
    expect(rules.locate(onDisk, nil, volumes.path) == .away, "one on a disk that is not mounted is away, not gone")
    try? files.createDirectory(at: volumes.appendingPathComponent("Far"), withIntermediateDirectories: true)
    expect(rules.locate(onDisk, nil, volumes.path) == .gone, "and gone once that disk is here without it")

    // Settings › Storage: the previews of SpektraLab's own libraries for folders and Capture One, inside the
    // app's folder, are counted (their develops only), listed in Sources or not.
    let store = ground.appendingPathComponent("Store", isDirectory: true)
    let ownFolder = store.appendingPathComponent("Sources/\(UUID().uuidString).spkcatalog", isDirectory: true)
    let mirror = store.appendingPathComponent("Linked/\(UUID().uuidString).spkcatalog", isDirectory: true)
    write(64, to: ownFolder.appendingPathComponent(PreviewHome.catalogDatabase))
    write(100, to: ownFolder.appendingPathComponent("Cache/Previews/" + dev(UUID(), "5656565656565656")))
    write(9, to: ownFolder.appendingPathComponent("Cache/Previews/notes.txt"))
    write(50, to: mirror.appendingPathComponent("Cache/Previews/" + dev(UUID(), "7878787878787878")))
    write(70, to: store.appendingPathComponent("Carried/last.json"))
    let own = rules.measureOwn(store)
    expect(own.files == 2 && own.bytes == 150,
           "the previews of the app's own libraries are counted, a folder's and a Capture One catalog's mirror's, their develops only (\(own.files) files, \(own.bytes) bytes)")

    return (passed, failed)
}

@main
enum StorageSelfTest {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let all = Rules.broken
            for broken in all {
                let r = run(broken, quiet: true)
                if r.failed.isEmpty {
                    print("  NOT CAUGHT  \(broken.name)")
                } else {
                    caught += 1
                    print("  caught  \(broken.name) (\(r.failed.count) checks failed)")
                }
            }
            print("storage checks' own check: \(caught) of \(all.count) broken rules caught")
            exit(caught == all.count ? 0 : 1)
        }
        let r = run(Rules(), quiet: false)
        print("storage checks: \(r.passed) passed, \(r.failed.count) failed")
        exit(r.failed.isEmpty ? 0 : 1)
    }
}
