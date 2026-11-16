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
//  8. **The way in and out, timed** (2026-11-16; alone with `--import-check-only open`): Import, the real
//     Finder panel cancelled; the panel answered Cancel (no cover ever, under 100 ms to idle); a pick, the
//     page, its Cancel 0–800 ms after it appeared (one dismissal, never the watchdog); one ask at a time.
//  9. **Checks and the divider** (2.4.1 E1, E3; alone with `--import-check-only picks`, no fixture needed: a folder
//     of twelve pictures made here): checks win over the selection, survive a filter and a rescan; on the page,
//     by a hand's events in the app's own queue (`MacHIDPost`, the app in the background): → and Space check the
//     picture shown, Space over several chosen checks them all and again unchecks them, a click on a cell's box
//     checks it without touching the selection; the divider dragged to the left widens the browser, its columns
//     grow, the width is kept; Space in the new catalog's name types a space; Return imports the checked ones only.
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
        // Capture One is never an import destination (2026-11-16): a check of its own, with its own fixtures.
        MacImportC1Check.startIfAsked(model: model, arguments: arguments)
        guard let i = arguments.firstIndex(of: "--import-check"), i + 1 < arguments.count else { return }
        func arg(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let z7Path = arg("--import-check-z7") ?? defaultZ7
        let diskPath = arg("--import-check-disk") ?? defaultDisk
        guard (!z7Path.isEmpty && !diskPath.isEmpty) || arg("--import-check-only") == "picks" else {
            print("import-check: supply --import-check-z7 and --import-check-disk, or SPK_TEST_IMAGES and SPK_TEST_DISK; no fixtures were run")
            if arguments.contains("--import-check-exit") { exit(2) }
            return
        }
        let z7 = URL(fileURLWithPath: z7Path)
        let disk = URL(fileURLWithPath: diskPath)
        let exits = arguments.contains("--import-check-exit")
        // `--import-check-only open`: step 8 alone (the way in and out, timed), without the imports.
        let onlyOpen = arg("--import-check-only") == "open"
        let onlyPicks = arg("--import-check-only") == "picks"
        let repeats = arg("--import-check-repeats").flatMap(Int.init) ?? 20
        realPanel = arguments.contains("--import-check-real-panel")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let report = onlyPicks ? await runPicks(model, out: out)
                : onlyOpen ? await runOpen(model, folder: z7, repeats: repeats) : await run(model, out: out, z7: z7, disk: disk)
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

        // 8. The way in and out, timed.
        if haveZ7 { await openAndLeave(r, store: store, router: model.router, folder: z7, repeats: 20) }

        // 9. Checks and the divider.
        await checksAndDivider(r, store: store, out: out)

        print("import-check: \(r.failures.isEmpty ? "passed" : "\(r.failures.count) failure(s)")")
        return ["steps": r.steps, "failures": r.failures, "not_run": r.notRun, "passed": r.failures.isEmpty]
    }

    /// Step 8 alone (`--import-check-only open`).
    static func runOpen(_ model: AppServices, folder: URL, repeats: Int) async -> [String: Any] {
        let r = Report()
        await model.macLibrary.start()
        await openAndLeave(r, store: model.macLibrary, router: model.router, folder: folder, repeats: repeats)
        print("import-check: \(r.failures.isEmpty ? "passed" : "\(r.failures.count) failure(s)")")
        return ["steps": r.steps, "failures": r.failures, "not_run": r.notRun, "passed": r.failures.isEmpty]
    }

    /// Step 9 alone (`--import-check-only picks`).
    static func runPicks(_ model: AppServices, out: URL) async -> [String: Any] {
        let r = Report()
        await model.macLibrary.start()
        await checksAndDivider(r, store: model.macLibrary, out: out)
        print("import-check: \(r.failures.isEmpty ? "passed" : "\(r.failures.count) failure(s)")")
        return ["steps": r.steps, "failures": r.failures, "not_run": r.notRun, "passed": r.failures.isEmpty]
    }

    // MARK: - 9. checks and the divider

    /// Twelve pictures, ten JPEGs and two PNGs (so a format filter hides some), each its own colour, and one in a
    /// subfolder (so Include Subfolders rescans to a different set).
    private static func makeTwelve(in folder: URL) -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        for i in 0..<12 {
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).image { ctx in
                UIColor(hue: CGFloat(i) / 12, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            }
            let name = String(format: "p%02d", i)
            if i >= 10 { try? picture.pngData()?.write(to: folder.appending(path: "\(name).png")) }
            else if i == 9 { try? picture.jpegData(compressionQuality: 0.9)?.write(to: folder.appending(path: "sub/\(name).jpg")) }
            else { try? picture.jpegData(compressionQuality: 0.9)?.write(to: folder.appending(path: "\(name).jpg")) }
        }
        return folder
    }

    private static func checksAndDivider(_ r: Report, store: any MacLibraryData, out: URL) async {
        let work = out.appending(path: "work")
        let folder = makeTwelve(in: work.appending(path: "twelve"))
        let paths = { (rows: [MacImage]) in Set(rows.map { CatalogSourcesStore.key($0.url.path) }) }

        // 9a. The rule, on the session alone.
        let s = await scanned(store, [folder])
        let rows = s.rows
        guard rows.count == 12 else { r.check(false, "9a: twelve pictures found (\(rows.count))"); s.close(); return }
        s.toggleCheck(rows[1].id)
        s.toggleCheck(rows[3].id)
        s.browser.click(rows[5].id, command: false, shift: false, in: rows)
        let title = s.importTitle
        r.check(Set(s.toImport.map(\.id)) == [rows[1].id, rows[3].id], "9a: checks win over the selection (\(s.toImport.map(\.fileName)))")
        r.check(title == L("Import \(2.formatted()) Checked"), "9a: the button reads Import 2 Checked (\(title))")
        let png = s.formatCounts.first { $0.count == 2 }?.format ?? "PNG"
        s.formats = [png]
        let filtered = (s.checkedRows.count, s.importTitle)
        r.check(filtered.0 == 0 && s.importTitle == L("Import All (\(2.formatted()))"), "9a: a filter hiding the checked falls back to the rows shown (\(filtered))")
        s.formats = []
        r.check(s.checkedRows.count == 2, "9a: the filter taken off, the checks are back (\(s.checkedRows.count))")
        if let sub = rows.first(where: { $0.fileName == "p09.jpg" }) { s.toggleCheck(sub.id) }   // in sub/: gone without subfolders
        s.includeSubfolders = false
        await s.scanFinished()
        r.check(s.checkedRows.count == 2 && s.rows.count == 11, "9a: a rescan keeps the checks of the pictures still there (\(s.checkedRows.count) of \(s.rows.count))")
        s.includeSubfolders = true
        await s.scanFinished()
        r.check(s.checkedRows.count == 2, "9a: a check of a picture a rescan did not find is let go (\(s.checkedRows.count))")
        s.uncheckAll()
        r.check(s.importTitle == L("Import \(1.formatted()) Selected") || s.importTitle == L("Import All (\(s.rows.count.formatted()))"),
                "9a: unchecked, the button is the selection's again (\(s.importTitle))")
        r.record("9a checks against the selection", 0, ["title_checked": title, "filtered": "\(filtered)", "after_uncheck": s.importTitle])
        s.close()

        #if targetEnvironment(macCatalyst)
        await pageChecks(r, store: store, out: out, folder: folder, paths: paths)
        #else
        r.notRun.append("9b the page by a hand's events: Mac only")
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// 9b–9f, on the page presented over the library, by events posted into the app's own queue.
    private static func pageChecks(_ r: Report, store: any MacLibraryData, out: URL, folder: URL,
                                   paths: ([MacImage]) -> Set<String>) async {
        let library = MacLibraryBrowser.shared
        MacImportFlow.debugPicks = [folder]
        MacImportFlow.debugCells = true
        defer { MacImportFlow.debugPicks = nil; MacImportFlow.debugCells = false }
        UserDefaults.standard.removeObject(forKey: MacImportSession.browserWidthKey)
        let old = MacImportFlow.debugSession
        library.importAsked = true
        _ = await until(10) { MacImportFlow.debugSession.map { $0 !== old } ?? false }
        guard let s = MacImportFlow.debugSession, s !== old else { r.check(false, "9b: the import page was presented"); library.importAsked = false; return }
        await s.scanFinished()
        await s.existingRead()
        s.destination = .newCatalog
        s.newCatalogName = "Checked"
        s.newCatalogFolder = out.appending(path: "work/Catalogs")
        s.placement = .inPlace
        s.browser.viewerShown = true
        try? await Task.sleep(for: .seconds(1.5))
        let rows = s.rows
        r.check(rows.count == 12, "9b: the page shows the twelve (\(rows.count))")
        guard rows.count == 12 else { library.importAsked = false; return }
        var drawn: [String] = [draw(out, "page-9-opened")]

        // 9b. → and Space: the shown picture checked; → → Space: the third.
        let k = MacHIDPost.self
        _ = await k.key(keyCode: 124)
        let firstShown = s.browser.primary(rows)?.id
        _ = await k.key(keyCode: 49)
        _ = await k.key(keyCode: 124)
        _ = await k.key(keyCode: 124)
        _ = await k.key(keyCode: 49)
        let byKey = Set(s.checkedRows.map(\.id))
        r.record("9b → and Space", 0, ["first_shown": firstShown?.image ?? "-", "checked": s.checkedRows.map(\.fileName),
                                       "shown": s.browser.primary(rows)?.fileName ?? "-"])
        r.check(firstShown == rows[0].id, "9b: → shows the first picture (\(firstShown?.image ?? "none"))")
        r.check(byKey == [rows[0].id, rows[2].id], "9b: Space checks the picture shown, each time (\(s.checkedRows.map(\.fileName)))")
        r.check(s.importTitle == L("Import \(2.formatted()) Checked"), "9b: the button reads Import 2 Checked (\(s.importTitle))")

        // 9c. Several chosen: Space checks them all; again, unchecks them all.
        s.browser.click(rows[4].id, command: false, shift: false, in: rows)
        s.browser.click(rows[6].id, command: false, shift: true, in: rows)
        _ = await k.key(keyCode: 49)
        let several = Set(s.checkedRows.map(\.id))
        _ = await k.key(keyCode: 49)
        let again = Set(s.checkedRows.map(\.id))
        r.check(several == [rows[0].id, rows[2].id, rows[4].id, rows[5].id, rows[6].id], "9c: Space over three chosen checks the three (\(several.count))")
        r.check(again == [rows[0].id, rows[2].id], "9c: and again unchecks them (\(again.count))")
        drawn.append(draw(out, "page-9-checked-by-key"))

        // 9d. A click on a cell's box: checked, the selection untouched; on the picture: chosen, not checked.
        s.browser.click(rows[1].id, command: false, shift: false, in: rows)
        try? await Task.sleep(for: .milliseconds(600))     // not a double click with what follows
        let layout = MacImportFlow.debugLayout
        /// Where the cell is in the window now, scrolled into view first.
        func cellFrame(_ i: Int) async -> CGRect? {
            s.browser.scrollTarget = rows[i].id
            try? await Task.sleep(for: .milliseconds(500))
            return MacImportFlow.debugFrames["cell:" + rows[i].fileName]
        }
        var clicked: [String: Any] = ["columns": layout.columns, "side": layout.side]
        if let c = await cellFrame(7) {
            let box = CGPoint(x: c.maxX - MacMetric.pt(11), y: c.minY + MacMetric.pt(11))
            _ = await k.drag(box, box, steps: 1)
            clicked["box_at"] = MacHIDPost.f(box)
        }
        let boxChecked = s.isChecked(rows[7].id), selectionKept = s.browser.selection == [rows[1].id]
        try? await Task.sleep(for: .milliseconds(600))
        if let c = await cellFrame(8) {
            let middle = CGPoint(x: c.midX, y: c.midY)
            _ = await k.drag(middle, middle, steps: 1)
        }
        let middleChose = s.browser.selection == [rows[8].id], middleUnchecked = !s.isChecked(rows[8].id)
        clicked["selection_after_middle"] = s.browser.selection.map(\.image)
        r.record("9d a click on the box", 0, clicked)
        r.check(boxChecked, "9d: a click on a cell's box checks it")
        r.check(selectionKept, "9d: and leaves the selection as it was")
        r.check(middleChose && middleUnchecked, "9d: a click on the picture chooses it and does not check it")

        // 9e. The divider dragged 250 points to the right (narrower), then 300 to the left: the browser wider, more
        // columns, the width kept. (A check's window is small — the viewer keeps its least, so the browser has some
        // 130 points to grow by — and the cells are made small, so that is columns.)
        s.browser.cell = 80
        try? await Task.sleep(for: .milliseconds(400))
        if let d = MacImportFlow.debugFrames["divider"] {
            let from = CGPoint(x: d.midX, y: d.midY)
            _ = await k.drag(from, CGPoint(x: from.x + 250, y: from.y), steps: 25)
            try? await Task.sleep(for: .milliseconds(700))
        }
        let narrowed = s.browser.browserWidth
        let libraryKept = UserDefaults.standard.double(forKey: MacLibraryBrowser.browserWidthKey)
        let before = (width: s.browser.browserWidth, columns: MacImportFlow.debugLayout.columns, grid: MacImportFlow.debugLayout.width)
        drawn.append(draw(out, "page-9-divider-before"))
        var dragged = false
        if let d = MacImportFlow.debugFrames["divider"] {
            let from = CGPoint(x: d.midX, y: d.midY)
            dragged = await k.drag(from, CGPoint(x: from.x - 300, y: from.y), steps: 30)
        }
        try? await Task.sleep(for: .milliseconds(700))
        let after = (width: s.browser.browserWidth, columns: MacImportFlow.debugLayout.columns, grid: MacImportFlow.debugLayout.width)
        let kept = UserDefaults.standard.double(forKey: MacImportSession.browserWidthKey)
        drawn.append(draw(out, "page-9-divider-after"))
        r.record("9e the divider dragged", 0, ["posted": dragged, "divider": MacImportFlow.debugFrames["divider"].map { "\($0)" } ?? "-",
                                              "width_before": before.width, "narrowed_from": narrowed, "width_after": after.width, "columns_before": before.columns,
                                              "columns_after": after.columns, "grid_before": before.grid, "grid_after": after.grid, "kept": kept])
        r.check(after.grid - before.grid > 100, "9e: the divider dragged left widens the browser (\(before.grid) → \(after.grid) points)")
        r.check(after.columns > before.columns, "9e: and its columns grow (\(before.columns) → \(after.columns))")
        r.check(abs(kept - Double(after.width)) < 1, "9e: the width is kept for the import page (\(kept))")
        r.check(UserDefaults.standard.double(forKey: MacLibraryBrowser.browserWidthKey) == libraryKept, "9e: and the library's own is left as it was")

        // 9f. Space in the new catalog's name types a space; the checks stay.
        let checksBefore = Set(s.checkedRows.map(\.id))
        if let f = MacImportFlow.debugFrames["name"] {
            let p = CGPoint(x: f.maxX - 6, y: f.midY)
            _ = await k.drag(p, p, steps: 1)
        }
        _ = await until(1.5) { MacKeyFocus.editingField != nil }
        let editing = MacKeyFocus.editingField != nil
        // While the field has the keys no command offers Space (trap 32: the menu would take it first), so it is the field's.
        let offered = MacShortcutRegistry.shared.keyCommands.contains { $0.input == " " && $0.modifierFlags.isEmpty }
        let performs = MacShortcutRegistry.shared.canPerform(UIKeyCommand(input: " ", modifierFlags: [], action: #selector(MacKeyAnchor.spkShortcut(_:))))
        _ = await k.key(keyCode: 49)
        _ = await k.key(keyCode: 7)
        let typed = s.newCatalogName
        r.record("9f Space in the name field", 0, ["editing": editing, "name": typed, "checked": s.checkedRows.count,
                                                   "space_offered": offered, "space_performs": performs])
        r.check(editing, "9f: a click on the name field gives it the keys")
        r.check(!offered && !performs, "9f: while it has them, no command takes Space (offered \(offered), performs \(performs))")
        r.check(Set(s.checkedRows.map(\.id)) == checksBefore, "9f: and Space checks nothing")
        // The text itself: a posted key reaches a field's text only through the input context of the active app,
        // which a background run never is (measured: neither " " nor "x" arrived). Said, and left to the hand check.
        if typed == "Checked x" { r.record("9f the field typed the space", 0, ["name": typed]) }
        else { r.notRun.append("9f the space typed into the name: a key's text needs the app in front (hand check); \"\(typed)\"") }
        MacKeyFocus.endEditing()
        try? await Task.sleep(for: .milliseconds(400))
        s.newCatalogName = "Checked"

        // 9g. Return: the checked ones imported, and only they.
        let want = paths(s.toImport)
        let wantTitle = s.importTitle
        let stillEditing = await until(2) { MacKeyFocus.editingField == nil } < 0
        // A field that still has the keys takes the first Return (its submit), as under a hand; the next is the page's.
        var returns = 0
        for _ in 0..<2 where s.result == nil && s.problem == nil {
            _ = await k.key(keyCode: 36)
            returns += 1
            _ = await until(returns == 1 ? 3 : 10) { s.result != nil || s.problem != nil }
        }
        let landed = Set((s.result?.files ?? []).map { CatalogSourcesStore.key($0.path) })
        r.record("9g Return imports the checked", 0, ["button": wantTitle, "want": want.count, "returns": returns, "field_kept_keys": stillEditing, "added": s.result?.added ?? -1,
                                                     "problem": s.problem ?? "-", "drawn": drawn])
        r.check(wantTitle == L("Import \(3.formatted()) Checked"), "9g: the button reads Import 3 Checked (\(wantTitle))")
        r.check(s.result?.added == 3 && landed == want, "9g: Return imports the three checked, and only they (\(s.result?.added ?? -1))")
        _ = await until(4) { idle }
        if !idle { library.importAsked = false; _ = await until(4) { idle } }
    }
    #endif

    // MARK: - 8. the way in and out

    /// `--import-check-real-panel`: 8a, the real Finder panel. Only with the app in front: in the background
    /// the panel is never drawn and holds the main thread for a minute before it answers Cancel by itself
    /// (measured 2026-11-16, three times out of three), so nothing it times there is the owner's.
    static var realPanel = false

    /// Polls `ok` every 5 ms for `seconds`; the ms it took, or -1. `meanwhile` is called on every look.
    private static func until(_ seconds: Double, from t0: ContinuousClock.Instant = .now, meanwhile: () -> Void = {},
                              _ ok: () -> Bool) async -> Int {
        func ms() -> Int { let d = ContinuousClock.now - t0; return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        while ms() < Int(seconds * 1000) {
            meanwhile()
            if ok() { return ms() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ok() ? ms() : -1
    }

    /// Nothing of the import is left: no cover, no request, no page, no Finder panel.
    private static var idle: Bool {
        let b = MacLibraryBrowser.shared
        return MacImportDropCheck.covers().isEmpty && b.importRequest == nil && b.importShown == nil && MacImportDropCheck.openPanel() == nil
    }

    private static func marks() -> [String: Int] {
        Dictionary(MacImportClock.marks.map { ($0.step, $0.ms) }, uniquingKeysWith: { a, _ in a })
    }

    /// Import, and leaving without importing (the owner, 2026-11-16: "why entering the import page, without
    /// import and cancel still takes this long?"), each step timed from the ask (`MacImportClock`). Import is
    /// `askImport`, the sidebar's button's own call: Finder first, the page only for picks.
    /// - **8a** (`realPanel` only) the real Finder panel, three times (the first of a run is the slow one):
    ///   when it is on screen, then its `cancel:` (in the process): no cover ever presented, Cancel to idle.
    /// - **8b** the panel answered Cancel by the check (`MacOpenPanel.debugAnswer`), `repeats` times: no cover
    ///   ever presented, the answer to idle under 100 ms.
    /// - **8c** the panel answered with a pick, the page, then the page's Cancel, `repeats` times, at 0–800 ms
    ///   after the page appeared: every page gone in one dismissal, never by the watchdog.
    /// - **8d** a drop while Import's panel is up is refused; a second Import then does nothing.
    private static func openAndLeave(_ r: Report, store: any MacLibraryData, router: AppRouter, folder: URL, repeats: Int) async {
        let library = MacLibraryBrowser.shared
        func ms(since t0: ContinuousClock.Instant) -> Int {
            let d = ContinuousClock.now - t0
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        func coverWatch(_ seen: inout Bool) { if !MacImportDropCheck.covers().isEmpty { seen = true } }
        _ = await until(4) { idle }

        // 8a. The real Finder panel, cancelled (with the app in front only).
        var rowsA: [[String: Any]] = []
        if !realPanel { r.notRun.append("8a the real Finder panel: run with --import-check-real-panel, the app in front") }
        for i in 0..<(realPanel ? 3 : 0) {
            var coverSeen = false
            let t0 = ContinuousClock.now
            library.askImport(store)
            let visible = await until(3, from: t0, meanwhile: { coverWatch(&coverSeen) }) { MacImportDropCheck.openPanel() != nil }
            let begun = await until(1, from: t0) { MacImportDropCheck.openPanel(visible: false) != nil }
            try? await Task.sleep(for: .milliseconds(300))
            let tc = ContinuousClock.now
            (MacImportDropCheck.openPanel() ?? MacImportDropCheck.openPanel(visible: false))?.perform(NSSelectorFromString("cancel:"), with: nil)
            let off = await until(5, from: tc, meanwhile: { coverWatch(&coverSeen) }) { idle && !library.importFinding }
            let m = marks()
            rowsA.append(["run": i, "panel_visible_ms": visible, "panel_begun_ms": begun, "cover_shown": coverSeen,
                          "cancel_to_idle_ms": off, "watchdog": m["watchdog"] != nil, "marks": m, "total_ms": ms(since: t0)])
            print("import-check: 8a #\(i) panel visible \(visible) ms (begun \(begun)), cancel to idle \(off) ms, cover \(coverSeen), marks \(m)")
            if off < 0 { _ = await until(70) { idle && !library.importFinding } }
            try? await Task.sleep(for: .milliseconds(400))
        }
        if realPanel { r.record("8a Import, the real Finder panel cancelled", 0, ["runs": rowsA]) }
        r.check(rowsA.allSatisfy { ($0["cancel_to_idle_ms"] as? Int ?? -1) >= 0 }, "8a: Cancel in Finder leaves nothing on screen")
        r.check(rowsA.allSatisfy { ($0["cover_shown"] as? Bool) == false }, "8a: and no cover is ever presented")

        // 8b. The panel answered Cancel.
        var rowsB: [[String: Any]] = []
        MacOpenPanel.debugAnswerAfter = .milliseconds(200)
        for i in 0..<max(repeats, 1) {
            var coverSeen = false
            MacOpenPanel.debugAnswer = .some(nil)
            library.askImport(store)
            _ = await until(2) { MacImportClock.at("panel answered") != nil }
            let ta = ContinuousClock.now
            let off = await until(3, from: ta, meanwhile: { coverWatch(&coverSeen) }) { idle && !library.importFinding }
            let m = marks()
            rowsB.append(["run": i, "answer_to_idle_ms": off, "cover_shown": coverSeen, "marks": m])
            if off < 0 { _ = await until(4) { idle } }
        }
        let worstB = rowsB.compactMap { $0["answer_to_idle_ms"] as? Int }.max() ?? -1
        r.record("8b Import, the panel answered Cancel", 0, ["runs": rowsB.count, "worst_answer_to_idle_ms": worstB,
                                                            "covers_shown": rowsB.filter { ($0["cover_shown"] as? Bool) == true }.count])
        print("import-check: 8b worst answer to idle \(worstB) ms")
        r.check(rowsB.allSatisfy { ($0["cover_shown"] as? Bool) == false }, "8b: Cancel in Finder shows no cover")
        r.check(worstB >= 0 && worstB < 100, "8b: Cancel in Finder to idle under 100 ms (worst \(worstB) ms)")

        // 8c. A pick, the page, the page's Cancel.
        var rowsC: [[String: Any]] = []
        let delays = [0, 30, 80, 150, 200, 400, 800]
        MacOpenPanel.debugAnswerAfter = .milliseconds(100)
        for i in 0..<max(repeats, 1) {
            let delay = delays[i % delays.count]
            let old = MacImportFlow.debugSession
            MacOpenPanel.debugAnswer = .some([folder])
            let t0 = ContinuousClock.now
            library.askImport(store)
            let appeared = await until(6, from: t0) { MacImportFlow.debugSession.map { $0 !== old } ?? false && MacImportClock.at("page appeared") != nil }
            guard appeared >= 0, let s = MacImportFlow.debugSession else {
                rowsC.append(["run": i, "failed": "no page"]); library.importAsked = false; _ = await until(4) { idle }; continue
            }
            try? await Task.sleep(for: .milliseconds(delay))
            let state = library.importShown.map(MacImportCover.state) ?? "none"
            let tc = ContinuousClock.now
            s.debugCancel?()
            let off = await until(5, from: tc) { idle }
            let m = marks()
            let picked = s.picked == [folder]
            rowsC.append(["run": i, "cancel_after_appear_ms": delay, "cover_at_cancel": state, "page_appeared_ms": appeared,
                          "cancel_to_idle_ms": off, "watchdog": m["watchdog"] != nil, "by_uikit": m["taken down by UIKit"] != nil,
                          "picks_taken": picked, "marks": m])
            print("import-check: 8c #\(i) cancel \(delay) ms after appearing (\(state)): to idle \(off) ms, watchdog \(m["watchdog"] != nil), marks \(m)")
            if off < 0 { library.importAsked = false; _ = await until(4) { idle } }
            try? await Task.sleep(for: .milliseconds(300))
        }
        MacOpenPanel.debugAnswerAfter = .zero
        let worstC = rowsC.compactMap { $0["cancel_to_idle_ms"] as? Int }.max() ?? -1
        r.record("8c a pick, the page, its Cancel", 0, ["runs": rowsC, "worst_cancel_to_idle_ms": worstC])
        r.check(rowsC.allSatisfy { ($0["picks_taken"] as? Bool) == true }, "8c: the page opens with Finder's picks")
        r.check(rowsC.allSatisfy { ($0["cancel_to_idle_ms"] as? Int ?? -1) >= 0 }, "8c: every Cancel on the page takes it away")
        r.check(rowsC.allSatisfy { ($0["watchdog"] as? Bool) == false }, "8c: never by the watchdog (\(rowsC.filter { ($0["watchdog"] as? Bool) == true }.count) of \(rowsC.count))")

        // 8d. One ask at a time while the panel is up.
        MacOpenPanel.debugAnswer = .some(nil)
        MacOpenPanel.debugAnswerAfter = .milliseconds(600)
        library.askImport(store)
        try? await Task.sleep(for: .milliseconds(50))
        let finding = library.importFinding
        let refused = !MacImportDrop.accepts(router)
        MacOpenPanel.debugAnswer = .some([folder])     // a second Import now must not take this answer
        library.askImport(store)
        let secondTook = MacOpenPanel.debugAnswer == nil
        _ = await until(3) { idle && !library.importFinding }
        MacOpenPanel.debugAnswer = nil
        MacOpenPanel.debugAnswerAfter = .zero
        r.record("8d one ask at a time", 0, ["finding": finding, "drop_refused": refused, "second_import_asked_finder": secondTook,
                                           "covers": MacImportDropCheck.covers()])
        r.check(finding && refused, "8d: a drop while Import's Finder panel is up is refused")
        r.check(!secondTook && idle, "8d: a second Import while it is up does nothing")
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
