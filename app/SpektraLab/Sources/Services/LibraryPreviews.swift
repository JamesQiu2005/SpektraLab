//  LibraryPreviews.swift — a frame's kept develop, kept with the library its picture was opened from.
//
//  The owner, 2026-11-05: "Preview film renders would be managed by the catalog / session in Capture
//  One style, instead of the current way of keeping them in the internal cache part." Capture One keeps
//  a catalog's previews in the catalog (`X.cocatalog/Cache/Previews`) and a session's in the session
//  (`CaptureOne/Cache/Previews`): they travel with a moved or copied library and go with a deleted one.
//  SpektraLab's preview is a frame's **kept develop** (`DevelopedPicture`, `dev-<frame>-<stamp>`, at
//  Settings › Develop › Preview size), and it is now kept the same way:
//
//      X.spkcatalog/Cache/Previews/dev-<frame>-<stamp>.heic           a SpektraLab catalog (its package)
//      X/.SpektraLab/Cache/Previews/dev-<frame>-<stamp>.heic          a SpektraLab session (its folder)
//      <store>/Linked/<document uuid>.spkcatalog/Cache/Previews/…     a Capture One catalog: the mirror's, never
//                                                                     inside the .cocatalog (API-SPEC-library-helper §6)
//      <store>/Sources/<id>.spkcatalog/Cache/Previews/…               a Capture One session, a Finder folder
//      <app>/Previews/dev-…                                           a frame in no library, as before
//
//  Derived from the library's own path and kind (`library.info`), so the helper is not changed:
//  - **a session's is hidden** (`.SpektraLab`): the helper's `session.scan` and the session's own folder
//    sync walk the whole session folder and would add every `.heic` as a picture; both skip a name
//    beginning with ".". A catalog's package is never walked (`folders.add` refuses inside it).
//  - **a session's is at its root**, not in each image folder as Capture One's is: `session.move` moves
//    pictures between Capture, Selects, Output and Trash, and a cache beside each would have to follow.
//
//  **Which library**: the one the frame was last carried from (`house`, from the Mac library's
//  `frames(for:)`, which Develop, Export and the carried filmstrip all pass through); else the one its
//  develop already lies in (`remember`, from the frames' paths at launch); else the app's `Previews`. A
//  frame is the app's, one per file, so a file two catalogs reference has one develop: a new one is
//  written where the frame was last carried from and replaces the old wherever that was
//  (`ImportService.discard`, which takes a library's preview file too).
//
//  **Only into a library that is there** (`PreviewHome.isThere`: a catalog's `Library.spkdb`, a session's
//  `.spksession`): a disk away, or a catalog moved since, is never written to — `createDirectory` would
//  make a ghost `X.spkcatalog/Cache` where a catalog used to be — and the develop goes to the app's
//  `Previews`, to be moved in the next time the frame is carried from the library (`move`).
//
//  **Nothing sweeps a library's previews** by "no frame names it": a catalog on a shared disk holds
//  another Mac's frames' previews too. Only a replaced develop goes, and Settings' *Delete Previews*
//  (`clear`).
//
//  **A develop whose file is not where its frame says** (`locate`, asked as a frame is carried and at the
//  Mac library's start; review, 2026-11-05): a catalog moved or copied in Finder takes its previews with
//  it, but its frames still name the old place. Found under the same name in the library they were
//  carried from, the frame is pointed there, and that is what makes "the previews travel with the
//  catalog" true. On a disk that is not mounted it is away, not gone, and is left as it is. Gone from a
//  disk that is here (a folder deleted, *Delete Previews* on another Mac) it is *missing*
//  (`DevelopedPicture.markedMissing`): what was known of it stays, and it is developed again when next
//  asked for.
//
//  Foundation only, any thread (the engine's queue writes): `tools/storage_selftest.swift` holds it to
//  these rules on this Mac.

import Foundation

/// A library's previews: the library, and where in it its previews are.
struct PreviewHome: Hashable, Sendable {
    enum Kind: String, Sendable {
        /// A `.spkcatalog` package: SpektraLab's own catalog, a Capture One mirror, the app's own for a folder.
        case catalog
        /// A SpektraLab session's folder.
        case session
    }

    /// The `.spkcatalog`, or the session's folder.
    let root: URL
    let kind: Kind

    /// The helper's catalog database, inside the package (`kCatalogDb`, the SDK's `library.cpp`).
    static let catalogDatabase = "Library.spkdb"
    static let sessionFolderName = ".SpektraLab"

    /// Nil for anything that is not a SpektraLab library's: a catalog that is not a `.spkcatalog`, and
    /// anything inside or beside a Capture One catalog or session, which are never written.
    init?(root: URL, kind: Kind) {
        let root = root.standardizedFileURL
        guard root.path != "/", !root.pathComponents.contains(where: { $0.lowercased().hasSuffix(".cocatalog") }) else { return nil }
        if kind == .catalog, root.pathExtension.lowercased() != "spkcatalog" { return nil }
        self.root = root
        self.kind = kind
    }

    /// `Cache/Previews` in a catalog's package; `.SpektraLab/Cache/Previews` in a session's folder.
    var folder: URL {
        let base = kind == .catalog ? root : root.appendingPathComponent(Self.sessionFolderName, isDirectory: true)
        return base.appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("Previews", isDirectory: true)
    }

    /// The library is there to write to: its database is (a disk away, a catalog moved since, a
    /// Capture One session where a session was, are not).
    var isThere: Bool {
        let fm = FileManager.default
        switch kind {
        case .catalog:
            return fm.fileExists(atPath: root.appendingPathComponent(Self.catalogDatabase).path)
        case .session:
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return false }
            return names.contains { $0.hasSuffix(".spksession") } && !names.contains { $0.lowercased().hasSuffix(".cosessiondb") }
        }
    }

    /// The library whose previews folder `folder` is, from its path alone (no disk is asked).
    static func of(previewsFolder folder: URL) -> PreviewHome? {
        let f = folder.standardizedFileURL
        guard f.lastPathComponent == "Previews" else { return nil }
        let cache = f.deletingLastPathComponent()
        guard cache.lastPathComponent == "Cache" else { return nil }
        let above = cache.deletingLastPathComponent()
        if above.pathExtension.lowercased() == "spkcatalog" { return PreviewHome(root: above, kind: .catalog) }
        if above.lastPathComponent == sessionFolderName { return PreviewHome(root: above.deletingLastPathComponent(), kind: .session) }
        return nil
    }
}

enum LibraryPreviews {
    /// Which library each frame's develop goes to: one book for the process, read on the engine's queue.
    private final class Book: @unchecked Sendable {
        let lock = NSLock()
        var homes: [UUID: PreviewHome] = [:]
    }
    private static let book = Book()

    /// The frames were carried from this library: their develops are kept in it from now on.
    static func house(_ ids: some Sequence<UUID>, in home: PreviewHome) {
        book.lock.lock(); defer { book.lock.unlock() }
        for id in ids { book.homes[id] = home }
    }

    /// At launch: each frame whose develop already lies in a library's previews is of that library,
    /// unless it has been carried from one since. `developed` is each frame's develop file.
    static func remember(_ developed: [(frame: UUID, file: URL)]) {
        book.lock.lock(); defer { book.lock.unlock() }
        for (id, file) in developed where book.homes[id] == nil {
            if let home = PreviewHome.of(previewsFolder: file.deletingLastPathComponent()) { book.homes[id] = home }
        }
    }

    /// The frames have left the app's library.
    static func forget(_ ids: some Sequence<UUID>) {
        book.lock.lock(); defer { book.lock.unlock() }
        for id in ids { book.homes[id] = nil }
    }

    static func home(of id: UUID) -> PreviewHome? {
        book.lock.lock(); defer { book.lock.unlock() }
        return book.homes[id]
    }

    /// Where a develop of the frame is written, in the order to try: its library's folder while the
    /// library is there, then `fallback` (the app's `Previews`).
    static func folders(for id: UUID, fallback: URL) -> [URL] {
        guard let home = home(of: id), home.isThere else { return [fallback] }
        return [home.folder, fallback]
    }

    /// A develop of the frame written (`EngineHost.write`): `body` is handed each of `folders` in turn,
    /// made first and left out of backups, and the first folder it writes into is the one. A library's
    /// folder is made only in a library that is there, a step at a time below its root (`prepare`), so a
    /// catalog moved or a disk gone in the middle of a develop leaves no ghost `X.spkcatalog/Cache` where
    /// the library was; the app's `Previews` is made whole, as it always was.
    static func write<T>(for id: UUID, fallback: URL, _ body: (URL) -> T?) -> T? {
        let home = home(of: id)
        for folder in folders(for: id, fallback: fallback) {
            let ready: Bool
            if let home, folder == home.folder { ready = prepare(home) } else { ready = makeFolder(folder) }
            guard ready, let made = body(folder) else { continue }
            return made
        }
        return nil
    }

    // MARK: the files

    /// The frame a kept develop's file is of: `dev-<frame>-<stamp>.<ext>`.
    static func frame(ofDevelop name: String) -> UUID? {
        guard name.hasPrefix("dev-") else { return nil }
        return UUID(uuidString: String(name.dropFirst(4).prefix(36)))
    }

    /// A kept develop in a library's previews folder: the only files there `discard` and `clear` take.
    static func isLibraryPreview(_ url: URL) -> Bool {
        frame(ofDevelop: url.lastPathComponent) != nil && PreviewHome.of(previewsFolder: url.deletingLastPathComponent()) != nil
    }

    /// Whether a replaced develop at `url` is the app's to delete (`ImportService.discard`): a file under
    /// the app's own `previews`, or a kept develop in a library's previews folder. Never anything else —
    /// not a library's database, not a picture in a session's Capture folder, not a file of the person's.
    static func isDiscardable(_ url: URL, appPreviews: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(appPreviews.standardizedFileURL.path + "/") || isLibraryPreview(url)
    }

    /// What a library's previews take: its kept develops, by count and bytes. Sizes only.
    static func measure(_ home: PreviewHome) -> (files: Int, bytes: Int64) {
        let all = develops(in: home)
        return (all.count, all.reduce(Int64(0)) { $0 + $1.1 })
    }

    /// *Delete Previews*: every kept develop in the library's folder goes but those of `sparing` (the
    /// frame an open develop page shows). Nothing else in the folder is touched. What went.
    @discardableResult
    static func clear(_ home: PreviewHome, sparing: Set<UUID>) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for (url, size) in develops(in: home) {
            guard let frame = frame(ofDevelop: url.lastPathComponent), !sparing.contains(frame),
                  (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            files += 1
            bytes += size
        }
        return (files, bytes)
    }

    /// A develop kept in the app's `Previews` (2.1.3 and before) moves into the library the frame was
    /// carried from, under the same name: its stamp is what it was made from, so it is no less current
    /// there. Only into a library that is there, never over a file: where the library already has a file
    /// of that name (the same frame and the same stamp, so the same picture, made there before the
    /// library was away or moved), that one is the frame's and the app's copy goes. Where it is now, or
    /// nil (left as it was).
    static func move(_ file: URL, into home: PreviewHome) -> URL? {
        guard home.isThere, frame(ofDevelop: file.lastPathComponent) != nil else { return nil }
        let fm = FileManager.default
        let target = home.folder.appendingPathComponent(file.lastPathComponent)
        guard target.standardizedFileURL != file.standardizedFileURL, fm.fileExists(atPath: file.path) else { return nil }
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: file)
            return target
        }
        guard prepare(home) else { return nil }
        do { try fm.moveItem(at: file, to: target) } catch { return nil }
        return target
    }

    /// The library's previews folder, made where the library is there: each folder below the library's
    /// root made on its own, never the root or anything above it. Left out of backups, as the app's
    /// `Previews` is (rebuildable from the original). Whether it is there to write into.
    @discardableResult
    static func prepare(_ home: PreviewHome) -> Bool {
        guard home.isThere else { return false }
        let fm = FileManager.default
        var dir = home.root
        let below = (home.kind == .session ? [PreviewHome.sessionFolderName] : []) + ["Cache", "Previews"]
        for name in below {
            dir = dir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                guard isDir.boolValue else { return false }
                continue
            }
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: false)) != nil else { return false }
        }
        excludeFromBackup(dir)
        return true
    }

    /// The app's own folder for develops, made whole.
    private static func makeFolder(_ folder: URL) -> Bool {
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        excludeFromBackup(folder)
        return true
    }

    private static func excludeFromBackup(_ folder: URL) {
        var dir = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true       // rebuildable from the original
        try? dir.setResourceValues(values)
    }

    // MARK: a develop not where its frame says

    /// Where a frame's develop file is, asked as the frame is carried from `home` (`housePreviews`) and at
    /// the Mac library's start (`repairPairPictures`).
    enum Found: Equatable, Sendable {
        /// Where the frame says.
        case there
        /// Not there, but in the previews of the library the frame was carried from, under its own name:
        /// the library was moved or copied, its previews with it. The frame is pointed here.
        case at(URL)
        /// On a disk that is not mounted: offline, not gone, and left as it is, as a frame whose original
        /// is on that disk is kept, and as the library itself is when the disk is back.
        case away
        /// Gone from a disk that is here: deleted (*Delete Previews* on another Mac, the folder by hand),
        /// or its library moved without it. The frame's develop is missing and is made again.
        case gone
    }

    /// `volumes` is where disks are mounted (a check's own folder in `storage_selftest`).
    static func locate(_ file: URL, carriedFrom home: PreviewHome?, volumes: String = "/Volumes") -> Found {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { return .there }
        if let home, home.isThere, frame(ofDevelop: file.lastPathComponent) != nil {
            let here = home.folder.appendingPathComponent(file.lastPathComponent)
            if here.standardizedFileURL != file.standardizedFileURL, fm.fileExists(atPath: here.path) { return .at(here) }
        }
        return isOnAwayDisk(file, volumes: volumes) ? .away : .gone
    }

    /// The file is on a disk that is not mounted: `/Volumes/<disk>/…` with no `/Volumes/<disk>`, the way
    /// `FrameCatalog.recheckLooseFiles` tells an original that is away from one that is gone.
    static func isOnAwayDisk(_ file: URL, volumes: String = "/Volumes") -> Bool {
        let root = URL(fileURLWithPath: volumes, isDirectory: true).standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root), let disk = path.dropFirst(root.count).split(separator: "/").first else { return false }
        return !FileManager.default.fileExists(atPath: root + disk)
    }

    /// The previews in SpektraLab's own libraries on this Mac: a Finder folder's and a Capture One
    /// session's catalog (`<store>/Sources/*.spkcatalog`), a Capture One catalog's mirror
    /// (`<store>/Linked/*.spkcatalog`), listed in Sources or not. They are inside the app's folder, so
    /// Settings › Storage counts them as a part of their own. Kept develops only, sizes only.
    static func measureOwn(store: URL) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for group in ["Sources", "Linked"] {
            let folder = store.appendingPathComponent(group, isDirectory: true)
            for root in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where root.pathExtension.lowercased() == "spkcatalog" {
                guard let home = PreviewHome(root: root, kind: .catalog) else { continue }
                let m = measure(home)
                files += m.files
                bytes += m.bytes
            }
        }
        return (files, bytes)
    }

    /// The kept develops in a library's folder, with their sizes.
    private static func develops(in home: PreviewHome) -> [(URL, Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: home.folder, includingPropertiesForKeys: keys)) ?? []
        return all.compactMap { url in
            guard frame(ofDevelop: url.lastPathComponent) != nil,
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, Int64(v.fileSize ?? 0))
        }
    }
}
