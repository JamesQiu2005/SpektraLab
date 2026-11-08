//  MacImportCheck.swift — a debug build's proof of the import flow, in the running app (2026-10-24).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --import-check <dir> \
//          [--import-check-z7 <folder>] [--import-check-disk <folder>] [--import-check-exit]
//
//  Drives `MacImportSession` — the import page's own model, so the same code the page's buttons call —
//  against the app's `CatalogSourcesStore`, and writes `<dir>/report.json`, every step timed:
//
//  1. **The scan** finds exactly the readable pictures, with and without subfolders, against an
//     independent count of the folder (by extension), and leaves out sidecars, movies and the rest: the
//     Z7ii test folder, the external disk's folder, and a folder made here with a `CaptureOne/` cache, a
//     hidden file, a "JPEG" ImageIO cannot read, a sidecar, a movie and a `.DAT`.
//  2. **A reference import** of the external disk's folder into a new scratch `.spkcatalog`, in chunks:
//     every picture added, one Recent Imports album holding them all, the library showing that album,
//     and the folder's census (name, size, mtime of every entry) the same after.
//  3. **The same folder again**: every picture a duplicate, nothing to import; forced (duplicates not
//     excluded), the helper adds nothing and makes no album.
//  4. **A copy import** of the Z7ii folder (Copy to Folder) into a scratch folder: each copy byte-identical
//     (size and SHA-256) at its path below the folder, the catalog referencing the copies, the source's
//     census (with hashes) unchanged; a second copy of two pictures into the same folder takes "_1" names
//     and leaves the first copies as they were.
//  5. **A selection**: three rows chosen with the page's own clicks (⌘-click) — only those are added.
//  6. **Copy into the catalog** (the helper's copy) lands in `Originals/yyyy/mm/dd`; a session's default
//     placement is its Capture folder; the default destination is the selected catalog.
//  7. **The page itself**, presented over the library with the Z7ii folder as picked (no Finder panel),
//     drawn to `<dir>/page-*.png` from inside the app, as `MacWindowCapture` does.
//  The drop (2026-11-05) has a check of its own, `--drop-check` (MacImportDropCheck.swift): it makes
//  catalogs and opens and closes the page many times, which this run's steps must not see.
//
//  The external disk is never written: only a reference import reads it. Copies go under `<dir>/work`.
//  `CFFIXED_USER_HOME` gives the run its own library, helper store and sources list. Not in a release build.

#if DEBUG
import CryptoKit
import Foundation
import UIKit

@MainActor
enum MacImportCheck {
    static let defaultZ7 = ProcessInfo.processInfo.environment["SPK_TEST_IMAGES"].map { $0 + "/Nikon Z7ii" } ?? ""
    static let defaultDisk = ProcessInfo.processInfo.environment["SPK_TEST_DISK"] ?? ""

    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--import-check"), i + 1 < arguments.count else { return }
        func arg(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let z7Path = arg("--import-check-z7") ?? defaultZ7
        let diskPath = arg("--import-check-disk") ?? defaultDisk
        guard !z7Path.isEmpty, !diskPath.isEmpty else {
            print("import-check: supply --import-check-z7 and --import-check-disk, or SPK_TEST_IMAGES and SPK_TEST_DISK; no fixtures were run")
            if arguments.contains("--import-check-exit") { exit(2) }
            return
        }
        let z7 = URL(fileURLWithPath: z7Path)
        let disk = URL(fileURLWithPath: diskPath)
        let exits = arguments.contains("--import-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let report = await run(model, out: out, z7: z7, disk: disk)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("import-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    // MARK: - the report

    private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var notRun: [String] = []
        func record(_ name: String, _ ms: Double, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            s["ms"] = (ms * 10).rounded() / 10
            steps.append(s)
            print("import-check: \(name) \(Int(ms)) ms \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); print("import-check: FAIL \(what)") }
        }
    }

    private static func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let t0 = ContinuousClock.now
        let v = try await body()
        let d = ContinuousClock.now - t0
        return (v, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    // MARK: - independent counts

    /// The extensions a camera or an editor writes as pictures ImageIO reads: the count the scan is held to.
    static let pictureExtensions: Set<String> = ["nef", "nrw", "arw", "srf", "sr2", "cr2", "cr3", "crw", "raf", "orf", "rw2",
                                                 "pef", "dng", "srw", "3fr", "fff", "iiq", "x3f", "erf", "mos", "rwl",
                                                 "jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "png", "webp", "avif"]

    /// Every regular file under `folder` not hidden and not below a `CaptureOne` folder, by lower-case
    /// extension ("" for none), with or without subfolders: what `find` sees.
    static func census(_ folder: URL, subfolders: Bool) -> [String: Int] {
        var out: [String: Int] = [:]
        let fm = FileManager.default
        func walk(_ dir: URL, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let url = dir.appending(path: name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if subfolders, name != "CaptureOne" { walk(url, depth: depth + 1) }
                } else {
                    out[url.pathExtension.lowercased(), default: 0] += 1
                }
            }
        }
        walk(folder, depth: 0)
        return out
    }

    static func expectedPictures(_ census: [String: Int]) -> Int {
        census.filter { pictureExtensions.contains($0.key) }.values.reduce(0, +)
    }

    /// Every entry under `folder`: its path, size and modification time, and with `hashes` each file's SHA-256.
    static func snapshot(_ folder: URL, hashes: Bool) async -> [String: String] {
        await Task.detached(priority: .userInitiated) { snapshotNow(folder, hashes: hashes) }.value
    }

    nonisolated static func snapshotNow(_ folder: URL, hashes: Bool) -> [String: String] {
        var out: [String: String] = [:]
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return out }
        for case let url as URL in walk {
            let v = try? url.resourceValues(forKeys: keys)
            var line = "\(v?.isDirectory == true ? "d" : "f") \(v?.fileSize ?? -1) \(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if hashes, v?.isDirectory != true { line += " " + (sha256(url) ?? "?") }
            out[String(url.path.dropFirst(folder.path.count))] = line
        }
        return out
    }

    nonisolated static func sha256(_ url: URL) -> String? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A scan of `picked`, finished, with the subfolders as asked.
    private static func scanned(_ store: any MacLibraryData, _ picked: [URL], subfolders: Bool = true) async -> MacImportSession {
        let s = MacImportSession(store: store)
        s.includeSubfolders = subfolders
        s.pick(picked)
        await s.scanFinished()
        await s.existingRead()
        return s
    }

    // MARK: - the run

    static func run(_ model: AppServices, out: URL, z7: URL, disk: URL) async -> [String: Any] {
        let r = Report()
        let store = model.macLibrary
        let fm = FileManager.default
        let work = out.appending(path: "work")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        await store.start()
        r.record("start", 0, ["home": NSHomeDirectory(), "sources": store.sources.map(\.kind.rawValue)])
        let haveZ7 = fm.fileExists(atPath: z7.path)
        let haveDisk = fm.fileExists(atPath: disk.path)
        if !haveZ7 { r.notRun.append("Z7ii folder not found: \(z7.path)") }
        if !haveDisk { r.notRun.append("external disk folder not mounted: \(disk.path)") }

        // 1. The scan.
        let made = makeSynthetic(in: work.appending(path: "synthetic"))
        for (name, folder) in [("synthetic", made), ("z7ii", haveZ7 ? z7 : nil), ("disk", haveDisk ? disk : nil)] {
            guard let folder else { continue }
            for subfolders in [true, false] {
                let census = census(folder, subfolders: subfolders)
                let expected = name == "synthetic" ? (subfolders ? 2 : 1) : expectedPictures(census)
                let (s, ms) = await timed { await scanned(store, [folder], subfolders: subfolders) }
                let formats = Dictionary(s.formatCounts.map { ($0.format, $0.count) }, uniquingKeysWith: +)
                r.record("scan \(name)\(subfolders ? " with subfolders" : " without subfolders")", ms, [
                    "found": s.files.count, "expected": expected, "census_by_extension": census, "formats": formats,
                    "tally": s.tally.dictionary, "listed_s": s.listedIn ?? -1, "headers_s": s.scannedIn ?? -1,
                    "with_date": s.files.filter { $0.header?.capturedLocal != nil }.count,
                    "with_camera": s.files.filter { $0.header?.cameraModel != nil }.count,
                ])
                r.check(s.files.count == expected, "\(name) scan (subfolders \(subfolders)) finds \(expected) pictures, found \(s.files.count)")
                r.check(s.files.allSatisfy(\.headerRead), "\(name): every header was read")
                if name == "synthetic" {
                    let names = Set(s.files.map(\.name))
                    r.check(!names.contains("c.jpg"), "a CaptureOne/ cache is never walked")
                    r.check(!names.contains("broken.jpg"), "a file ImageIO cannot open is left out")
                    r.check(s.tally.movies == 1 && s.tally.sidecars == 2 && s.tally.other >= 1,
                            "a movie, two sidecars and a .DAT are counted and left out (\(s.tally.dictionary))")
                    r.check(s.tally.skippedFolders == (subfolders ? 1 : 0), "the CaptureOne folder is counted as skipped")
                }
                if name == "z7ii", subfolders {
                    r.check(s.tally.sidecars == 2, "Z7ii: the .xmp and the .spektra.json are sidecars (\(s.tally.sidecars))")
                    r.check(s.files.contains { $0.relative.hasPrefix("_prints/") }, "Z7ii: a picture in _prints/ is found")
                }
                if name == "disk", subfolders {
                    r.check(s.tally.movies == census["mov", default: 0], "disk: every MOV is a movie, left out")
                }
                s.close()
            }
        }

        do {
            // 2. A reference import of the external disk's folder, into a new catalog, in chunks.
            if haveDisk {
                let before = await snapshot(disk, hashes: false)
                let s = await scanned(store, [disk])
                s.destination = .newCatalog
                s.newCatalogName = "Disk Import"
                s.newCatalogFolder = work.appending(path: "Catalogs")
                s.placement = .inPlace
                r.check(s.importTitle == L("Import All (\(s.files.count.formatted()))"), "with nothing chosen the button reads Import All (n): \(s.importTitle)")
                let (res, ms) = await timed { await s.run() }
                guard let res else { throw MacLibraryError.notSupported(s.problem ?? "the import did not run") }
                let after = await snapshot(disk, hashes: false)
                let recent = store.tree.fixed.first { $0.kind == .recentImports }?.children ?? []
                let album = store.tree.find(res.album)
                r.record("reference import of the disk folder", ms, [
                    "found": s.files.count, "added": res.added, "existing": res.existing, "failed": res.failed.count,
                    "chunks": res.chunks, "album": album?.title ?? "-", "album_count": album?.imageCount ?? -1,
                    "recent_imports": recent.count, "listed_in_library": store.total, "seconds": res.seconds,
                    "catalog": store.selectedSource?.path ?? "-", "census_entries": before.count,
                ])
                r.check(res.added == s.files.count, "every picture found is added (\(res.added) of \(s.files.count))")
                r.check(res.chunks == (s.files.count + MacImportSession.chunkSize - 1) / MacImportSession.chunkSize, "added in chunks of \(MacImportSession.chunkSize)")
                r.check(recent.count == 1 && album?.imageCount == res.added, "one Recent Imports album holds them all")
                r.check(store.selectedSourceID == res.destination && store.selectedCollectionID == res.album, "the library shows the new catalog's import")
                r.check(store.total == res.added, "the album lists every picture (\(store.total))")
                r.check(store.sources.first { $0.id == res.destination }?.path?.hasSuffix("Disk Import.spkcatalog") == true, "a .spkcatalog was made where asked")
                r.check(before == after, "the disk folder is untouched (\(before.count) entries, name, size and mtime)")
                await store.loadAll()
                r.check(store.images.allSatisfy { $0.url.path.hasPrefix(disk.path) }, "the catalog references the files where they are")
                r.check(store.images.filter { $0.captureDate != nil }.count == res.added, "every row has its capture date from the header")
                s.close()

                // 3. The same folder again: all duplicates.
                let again = await scanned(store, [disk])
                r.check(again.destination == .source(res.destination), "the default destination is the selected catalog")
                let dupes = again.duplicateCount
                r.record("the same folder again", 0, ["found": again.files.count, "duplicates": dupes, "to_import": again.toImport.count,
                                                     "button": again.importTitle])
                r.check(dupes == again.files.count, "every picture is a duplicate (\(dupes))")
                r.check(again.toImport.isEmpty && !again.canImport, "nothing is left to import")
                again.excludeDuplicates = false
                let (forced, fMS) = await timed { await again.run() }
                let recentAfter = store.tree.fixed.first { $0.kind == .recentImports }?.children ?? []
                r.record("the same folder, duplicates not excluded", fMS, ["added": forced?.added ?? -1, "existing": forced?.existing ?? -1,
                                                                          "album": forced?.album ?? "-", "recent_imports": recentAfter.count])
                r.check(forced?.added == 0 && forced?.existing == again.files.count, "the helper adds nothing a second time")
                r.check(forced?.album == nil && recentAfter.count == 1, "and makes no second album")
                again.close()
            }

            // 4. A copy import of the Z7ii folder into a scratch folder.
            if haveZ7 {
                let before = await snapshot(z7, hashes: true)
                let copied = work.appending(path: "Copied")
                let s = await scanned(store, [z7])
                s.destination = .newCatalog
                s.newCatalogName = "Copies"
                s.newCatalogFolder = work.appending(path: "Catalogs")
                s.placement = .copyToFolder
                s.copyFolder = copied
                let (res, ms) = await timed { await s.run() }
                guard let res else { throw MacLibraryError.notSupported(s.problem ?? "the copy import did not run") }
                var identical = 0
                for f in s.files {
                    let target = copied.appending(path: f.relative)
                    let a = try? fm.attributesOfItem(atPath: f.url.path)[.size] as? Int
                    let b = try? fm.attributesOfItem(atPath: target.path)[.size] as? Int
                    if a != nil, a == b, sha256(f.url) == sha256(target) { identical += 1 }
                }
                await store.loadAll()
                let paths = Set(store.images.map { CatalogSourcesStore.key($0.url.path) })
                let want = Set(s.files.map { CatalogSourcesStore.key(copied.appending(path: $0.relative).path) })
                let after = await snapshot(z7, hashes: true)
                r.record("copy import of the Z7ii folder", ms, ["found": s.files.count, "copied": res.copied, "added": res.added,
                                                              "identical": identical, "listed": store.total, "seconds": res.seconds,
                                                              "copied_to": copied.path])
                r.check(res.copied == s.files.count && res.added == s.files.count, "every picture copied and added")
                r.check(identical == s.files.count, "every copy is byte-identical (size and SHA-256), at its path below the folder")
                r.check(paths == want, "the catalog references the copies, not the originals")
                r.check(before == after, "the Z7ii folder is unchanged (\(before.count) entries, with hashes)")
                let firstCopies = await snapshot(copied, hashes: true)
                s.close()

                // A second copy of two pictures into the same folder: "_1", never over the first.
                let twice = await scanned(store, [z7])
                twice.destination = .newCatalog
                twice.newCatalogName = "Copies"          // taken: "Copies 2"
                twice.newCatalogFolder = work.appending(path: "Catalogs")
                twice.placement = .copyToFolder
                twice.copyFolder = copied
                let two = Array(twice.rows.filter { !$0.fileName.hasPrefix(".") }.prefix(2))
                let res2 = await twice.run(two)
                let stillFirst = await snapshot(copied, hashes: true)
                let underscored = (res2?.files ?? []).filter { $0.deletingPathExtension().lastPathComponent.hasSuffix("_1") }.count
                r.record("copy two again into the same folder", 0, ["added": res2?.added ?? -1, "files": (res2?.files ?? []).map(\.lastPathComponent),
                                                                   "catalog": store.selectedSource?.name ?? "-"])
                r.check(underscored == 2, "a name already taken gets _1")
                r.check(firstCopies.allSatisfy { stillFirst[$0.key] == $0.value }, "the first copies are not overwritten")
                r.check(store.selectedSource?.name == "Copies 2", "a new catalog's name that is taken becomes \"Copies 2\"")
                twice.close()

                // 5. A selection: three rows chosen with the page's own clicks.
                let sel = await scanned(store, [z7])
                sel.destination = .newCatalog
                sel.newCatalogName = "Selection"
                sel.newCatalogFolder = work.appending(path: "Catalogs")
                let rows = sel.rows
                if rows.count >= 5 {
                    sel.browser.click(rows[0].id, command: false, shift: false, in: rows)
                    sel.browser.click(rows[2].id, command: true, shift: false, in: rows)
                    sel.browser.click(rows[4].id, command: true, shift: false, in: rows)
                }
                let chosen = Set(sel.browser.selection.map { CatalogSourcesStore.key($0.image) })
                let title = sel.importTitle
                let res3 = await sel.run()
                await store.loadAll()
                let landed = Set(store.images.map { CatalogSourcesStore.key($0.url.path) })
                r.record("an import of a selection", 0, ["chosen": chosen.count, "button": title, "added": res3?.added ?? -1,
                                                       "listed": store.total])
                r.check(title == L("Import \(3.formatted()) Selected"), "with three chosen the button reads Import 3 Selected (\(title))")
                r.check(res3?.added == 3 && landed == chosen, "only the chosen three are added")
                sel.close()
            }

            // 6. Copy into the catalog, a session's default, the default destination.
            let s = await scanned(store, [made])
            s.destination = .newCatalog
            s.newCatalogName = "Inside"
            s.newCatalogFolder = work.appending(path: "Catalogs")
            s.placement = .intoLibrary
            let res4 = await s.run()
            await store.loadAll()
            let day = { () -> String in
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy/MM/dd"; return f.string(from: Date())
            }()
            let inside = store.images.filter { $0.url.path.contains("/Inside.spkcatalog/Originals/\(day)/") }.count
            r.record("copy into the catalog", 0, ["added": res4?.added ?? -1, "inside": inside, "paths": store.images.map(\.url.path)])
            r.check(res4?.added == 2 && inside == 2, "the helper's copy lands in Originals/\(day)")
            let catalogID = store.selectedSourceID
            let next = MacImportSession(store: store)
            r.check(catalogID.map { next.destination == .source($0) } ?? false, "the default destination is the selected catalog")
            next.close()
            s.close()
            let session = try await store.newSession(named: "Shoot", in: work.appending(path: "Catalogs"))
            let onSession = MacImportSession(store: store)
            r.check(onSession.destination == .source(session.id) && onSession.placement == .intoLibrary,
                    "a session's default is a copy into its Capture folder")
            r.check(onSession.intoLibraryTitle == L("Copy into the Session's Capture Folder"), "and says so")
            onSession.close()
        } catch {
            r.check(false, "the run stopped: \(error.localizedDescription)")
        }

        // 7. The page itself, over the library, with the Z7ii folder picked (no Finder panel).
        if haveZ7 { await drawPage(r, out: out, folder: z7) }

        print("import-check: \(r.failures.isEmpty ? "passed" : "\(r.failures.count) failure(s)")")
        return ["steps": r.steps, "failures": r.failures, "not_run": r.notRun, "passed": r.failures.isEmpty]
    }

    /// The import page presented as the library presents it, drawn from inside the app: as it opens, with
    /// three pictures chosen, and with the viewer.
    private static func drawPage(_ r: Report, out: URL, folder: URL) async {
        MacImportFlow.debugPicks = [folder]
        defer { MacImportFlow.debugPicks = nil }
        let library = MacLibraryBrowser.shared
        library.importAsked = true
        var session: MacImportSession?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            session = MacImportFlow.debugSession
            if session != nil { break }
        }
        guard let session else { r.check(false, "the import page was presented"); library.importAsked = false; return }
        await session.scanFinished()
        await session.existingRead()
        try? await Task.sleep(for: .seconds(2))
        var drawn: [String] = []
        drawn.append(draw(out, "page-1-opened"))
        let rows = session.rows
        if rows.count >= 4 {
            session.browser.click(rows[1].id, command: false, shift: false, in: rows)
            session.browser.click(rows[3].id, command: false, shift: true, in: rows)
        }
        try? await Task.sleep(for: .seconds(1))
        drawn.append(draw(out, "page-2-three-selected"))
        session.browser.viewerShown = true
        try? await Task.sleep(for: .seconds(2))
        drawn.append(draw(out, "page-3-viewer"))
        r.record("the page, presented and drawn", 0, ["files": drawn, "rows": rows.count, "button": session.importTitle,
                                                     "destination": session.destinationSource?.name ?? "new catalog"])
        r.check(session.importTitle == L("Import \(3.formatted()) Selected") || rows.count < 4, "the page's button follows the selection")
        library.importAsked = false
        try? await Task.sleep(for: .seconds(1))
    }

    /// The key window, drawn by the app (no Screen Recording permission), to `<out>/<name>.png`.
    private static func draw(_ out: URL, _ name: String) -> String {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.bounds.width > 0 }
        guard let w = windows.first(where: \.isKeyWindow) ?? windows.first else { return "no window" }
        w.setNeedsLayout()
        w.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
        }
        let url = out.appending(path: name + ".png")
        try? image.pngData()?.write(to: url)
        return url.path
    }

    /// A folder with one of each thing a scan must tell apart: two pictures (one in a subfolder), a
    /// Capture One cache, a hidden picture, a "JPEG" that is text, two sidecars, a movie, a `.DAT`.
    private static func makeSynthetic(in folder: URL) -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        for dir in ["sub", "CaptureOne/Cache"] { try? fm.createDirectory(at: folder.appending(path: dir), withIntermediateDirectories: true) }
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let jpeg = picture.jpegData(compressionQuality: 0.9) ?? Data()
        try? jpeg.write(to: folder.appending(path: "a.jpg"))
        try? picture.pngData()?.write(to: folder.appending(path: "sub/b.png"))
        try? jpeg.write(to: folder.appending(path: "CaptureOne/Cache/c.jpg"))
        try? jpeg.write(to: folder.appending(path: ".hidden.jpg"))
        try? Data("not a picture".utf8).write(to: folder.appending(path: "broken.jpg"))
        try? Data("<x:xmpmeta/>".utf8).write(to: folder.appending(path: "a.xmp"))
        try? Data("{}".utf8).write(to: folder.appending(path: "a.jpg.spektra.json"))
        try? Data(count: 1024).write(to: folder.appending(path: "clip.mov"))
        try? Data(count: 64).write(to: folder.appending(path: "x.DAT"))
        return folder
    }
}
#endif
