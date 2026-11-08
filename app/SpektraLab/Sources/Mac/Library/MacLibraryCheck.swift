//  MacLibraryCheck.swift — a debug build's proof of the Mac's library data, in the running app.
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --library-check <dir> \
//          [--library-check-c1 "<…>.cocatalog"] [--library-check-exit]
//
//  Drives `CatalogSourcesStore` (the model the library views bind to) through what the owner asked for and
//  writes `<dir>/report.json`, every step timed:
//
//  1. a Capture One catalog, read one way: its tree (Recent Imports with their times and counts),
//     every image listed, a recent import opened, facets, filters, one picture opened in Develop and
//     found again as developed;
//  2. a scratch SpektraLab catalog with a referenced folder of real files (copied from the catalog's,
//     which are only read) kept in step: described, then a file moved, one deleted, one added;
//  3. a SpektraLab session with files imported (copied into Capture);
//  4. a Finder folder linked as a source, and a folder shaped as a Capture One session whose
//     `CaptureOne` caches are never walked;
//  5. the kept list of sources, read back.
//
//  `CFFIXED_USER_HOME` gives the run a home of its own: the app's library, the helper's store and
//  the sources list are then the scratch home's, not the owner's. Not in a release build.

#if DEBUG
import Foundation

@MainActor
enum MacLibraryCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        // `--catalog-check` (Sources/Mac/Migration, 2026-10-24) starts from the same hook in RootView.
        MacCatalogCheck.startIfAsked(model: model, arguments: arguments)
        // `--clipboard-check` (Sources/Mac/LibraryUI, 2026-11-05): Copy and Paste Settings, from the same hook.
        MacClipboardCheck.startIfAsked(model: model, arguments: arguments)
        guard let i = arguments.firstIndex(of: "--library-check"), i + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let c1 = arguments.firstIndex(of: "--library-check-c1").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let exits = arguments.contains("--library-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(1))
            let report = await run(model, out: out, c1: c1)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("library-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        func note(_ name: String, _ ms: Double, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            s["ms"] = (ms * 10).rounded() / 10
            steps.append(s)
            print("library-check: \(name) \(Int(ms)) ms \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); print("library-check: FAIL \(what)") }
        }
    }

    private static func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let t0 = ContinuousClock.now
        let v = try await body()
        let d = ContinuousClock.now - t0
        return (v, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    private static func waitDescribed(_ store: CatalogSourcesStore, seconds: Double = 30) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(300))
            if store.facets.undescribed == 0, store.activity.working == nil { return }
        }
    }

    /// A top folder row that is a volume ("/", "disk"): the shape every catalog's Folders take.
    private static func isVolume(_ f: MacCollection) -> Bool {
        guard let p = f.folder?.path else { return false }
        return CatalogSourcesStore.volume(of: p).path == (p as NSString).standardizingPath
    }

    static func run(_ model: AppServices, out: URL, c1: String?) async -> [String: Any] {
        let r = Report()
        let store = model.macLibrary
        let fm = FileManager.default
        try? fm.removeItem(at: out.appending(path: "work"))
        let work = out.appending(path: "work")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        var picked: [URL] = []

        let (_, startMS) = await timed { await store.start() }
        r.note("start", startMS, ["sources": store.sources.map(\.kind.rawValue), "home": NSHomeDirectory()])

        do {
            // 1. Capture One, read one way.
            if let c1 {
                let (s, openMS) = try await timed { try await store.open(URL(fileURLWithPath: c1)) }
                let fixed = store.tree.fixed.map { ["kind": "\($0.kind)", "title": $0.title, "count": $0.imageCount ?? -1] as [String: Any] }
                let imports = store.tree.fixed.first { $0.kind == .recentImports }?.children ?? []
                r.note("capture one: open (probe, link, tree, first page, facets)", openMS, [
                    "format": store.selectedSource?.format ?? "?", "total": store.total, "first_page": store.images.count,
                    "fixed": fixed, "folders_top": store.tree.folders.map(\.title), "user_collections": store.tree.user.count,
                    "recent_imports": imports.prefix(5).map { "\($0.title) · \($0.imageCount ?? -1) (\($0.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-"))" },
                ])
                r.check(s.kind == .captureOneCatalog, "the catalog opens as a Capture One catalog")
                r.check(store.total > 9000, "every visible image is counted (\(store.total))")
                r.check(store.selectedSource?.isReadOnly == true, "a Capture One source is read-only")

                let (_, allMS) = await timed { await store.loadAll() }
                r.note("capture one: every image as grid rows", allMS, ["rows": store.images.count, "total": store.total,
                                                                         "offline": store.images.filter(\.isOffline).count,
                                                                         "with_camera": store.images.filter { $0.cameraModel != nil }.count])
                r.check(store.images.count == store.total, "loadAll lists every image")
                store.pageSize = 20_000
                let (_, oneMS) = await timed { await store.select(collection: store.tree.defaultSelection) }
                r.note("capture one: every image in one page (rows + facets)", oneMS, ["rows": store.images.count])
                store.pageSize = 1000
                picked = store.images.filter { !$0.isOffline && $0.kind == .raw }.prefix(5).map(\.url)
                    + store.images.filter { !$0.isOffline && $0.kind == .raster }.prefix(1).map(\.url)

                let f = store.facets
                r.note("capture one: facets", 0, [
                    "ratings": f.ratings.map { "\($0.value)★ \($0.count)" }, "cameras": f.cameras.prefix(4).map { "\($0.value ?? "?") \($0.count)" },
                    "lenses": f.lenses.count, "years": f.years.map { "\($0.value) \($0.count)" }, "keywords": f.keywords.count,
                ])

                if let wanted = imports.first(where: { $0.title.contains("10月3日") }) ?? imports.first {
                    let (_, ms) = await timed { await store.select(collection: wanted.id) }
                    r.note("capture one: open a recent import", ms, ["title": wanted.title, "listed": store.total, "count": wanted.imageCount ?? -1])
                    r.check(store.total == wanted.imageCount, "a recent import lists what its count says")
                }
                if let biggest = store.tree.all.filter({ $0.kind == .folder }).max(by: { ($0.imageCount ?? 0) < ($1.imageCount ?? 0) }) {
                    let (_, ms) = await timed { await store.select(collection: biggest.id) }
                    r.note("capture one: open the largest folder", ms, ["title": biggest.title, "listed": store.total, "count": biggest.imageCount ?? -1])
                    r.check(store.total == biggest.imageCount, "a folder lists what its count says")
                }
                await store.select(collection: store.tree.defaultSelection)
                var q = MacImageQuery()
                q.ratings = [4]
                let (_, fq) = await timed { await store.apply(q) }
                let fourStars = f.ratings.first { $0.value == 4 }?.count ?? -1
                r.note("capture one: filter 4 stars", fq, ["listed": store.total, "facet_said": fourStars,
                                                           "rating_facet_kept": store.facets.ratings.count])
                r.check(store.total == fourStars, "the 4-star filter lists what the facet counted")
                q = MacImageQuery()
                q.cameras = ["NIKON Z 8"]
                q.sort = .fileName
                await store.apply(q)
                r.note("capture one: filter one camera, by name", 0, ["listed": store.total, "first": store.images.first?.fileName ?? "-"])
                await store.apply(MacImageQuery())
                // A rating on Capture One's picture is SpektraLab's override in the mirror (the owner,
                // 2026-10-24); cleared again, Capture One's own shows. The census proves the catalog untouched.
                do {
                    let picked = store.images[0]
                    try await store.setRating(5, for: [picked.id])
                    r.check(store.images.first { $0.id == picked.id }?.rating == 5, "a rating on Capture One's image is kept in the mirror")
                    try await store.setRating(nil, for: [picked.id])
                    r.check(store.images.first { $0.id == picked.id }?.rating == picked.rating, "a cleared rating hands back Capture One's")
                } catch {
                    r.check(false, "a rating on Capture One's image is kept in the mirror: \(error.localizedDescription)")
                }

                // One picture into Develop, then seen as SpektraLab's.
                if let first = store.images.first(where: { !$0.isOffline && $0.kind == .raw }) {
                    let (_, ms) = try await timed { try await store.openInDevelop(first.id) }
                    var onDevelop = false
                    if case .develop(let id)? = model.router.path.last { onDevelop = model.library.frame(id)?.picture.fileURL?.path == first.url.path }
                    r.note("capture one: open in Develop", ms, ["file": first.fileName, "route": "\(model.router.path.last.map { "\($0)" } ?? "-")",
                                                                "frames_in_app_library": model.library.frames.count])
                    r.check(onDevelop, "Develop is open on that picture's frame")
                    model.router.toLibrary()
                    store.refreshDevelopInfo()
                    let again = store.images.first { $0.id == first.id }
                    r.check(again?.develop != nil, "the row now carries its frame")
                    r.note("capture one: the row after Develop", 0, ["film": again?.develop?.film ?? "-", "paper": again?.develop?.paper ?? "-",
                                                                     "state": "\(again?.develop?.state as Any)"])
                    var d = MacImageQuery()
                    d.developedOnly = true
                    await store.apply(d)
                    r.check(store.total == 1, "the Developed filter finds it (\(store.total))")
                    r.check(store.facets.developed == 1, "the Developed facet counts it (\(store.facets.developed))")
                    await store.apply(MacImageQuery())
                    // Opened again: the same frame, not a second one.
                    let before = model.library.frames.count
                    try await store.openInDevelop(first.id)
                    model.router.toLibrary()
                    r.check(model.library.frames.count == before, "a second open finds the same frame")
                }

                // One shape for every catalog (the owner, 2026-10-24): what a SpektraLab catalog does, this
                // one does, through its mirror; Capture One's file is never written (the census says so).
                r.check(MacWords.symbol(.captureOneCatalog) == MacWords.symbol(.catalog), "a Capture One catalog is drawn as a catalog")
                r.check(store.tree.folders.allSatisfy(isVolume), "every top folder of the Capture One catalog is a volume")
                let into = work.appending(path: "Into Capture One")
                try fm.createDirectory(at: into, withIntermediateDirectories: true)
                var files: [MacImportFile] = []
                for u in picked.prefix(2) {
                    let d = into.appending(path: "c1-\(u.lastPathComponent)")
                    try? fm.copyItem(at: u, to: d)
                    files.append(MacImportFile(url: d, header: MacHeaders.readIfReadable(d)))
                }
                let (chunk, impMS) = try await timed { try await store.importChunk(files, into: s.id, copyIntoLibrary: false, album: nil) }
                await store.showImport(in: s.id, album: chunk.album)
                let rows = store.tree.fixed.filter { $0.kind == .recentImports }
                r.note("capture one: an import into it (its mirror)", impMS, [
                    "added": chunk.added, "album": chunk.album ?? "-", "recent_imports_rows": rows.count,
                    "recent_imports": rows.first?.children.prefix(3).map(\.title) ?? [], "listed": store.total,
                    "volumes": store.tree.folders.map(\.title)])
                r.check(s.acceptsImports, "a Capture One catalog takes imports")
                r.check(!files.isEmpty && chunk.added == files.count && chunk.album != nil, "an import into it adds its files as one Recent Import")
                r.check(rows.count == 1 && rows[0].children.contains { $0.id == chunk.album }, "one Recent Imports row holds Capture One's imports and SpektraLab's")
                r.check(store.selectedCollectionID == chunk.album && store.total == files.count, "the import is shown")
                r.check(store.tree.folders.allSatisfy(isVolume), "the import's folder sits under its volume, as Capture One's do")

                // The Light Table, from the library, by the one filter (the owner, 2026-10-24): a picture
                // with no frame, or a frame SpektraLab never developed and with no film edge, is refused; with a film
                // edge on (its size known), it lies there.
                let unframed = store.images.map(\.id)
                var refusedUnframed = false
                do { try await store.putOnLightTable(unframed) } catch { refusedUnframed = (error as? MacLibraryError) == .notForTable }
                var d = MacImageQuery()
                d.developedOnly = true
                await store.select(collection: store.tree.defaultSelection)
                await store.apply(d)
                let framed = store.images.first
                var refusedPlain = false
                if let f = framed?.develop?.frameID { model.library.update(f) { $0.edit.filmEdge.active = false; $0.developed = nil } }
                if let framed { do { try await store.putOnLightTable([framed.id]) } catch { refusedPlain = (error as? MacLibraryError) == .notForTable } }
                if let f = framed?.develop?.frameID { model.library.update(f) { $0.edit.filmEdge.active = true } }
                var opened = false
                if let framed {
                    try await store.putOnLightTable([framed.id])
                    opened = model.router.path.last == .lightTable
                }
                try? await Task.sleep(for: .seconds(2.5))
                let saved = (try? String(contentsOf: LightTableStore.beside, encoding: .utf8)) ?? ""
                let laid = (framed?.develop?.frameID).map { saved.contains($0.uuidString) } ?? false
                r.note("light table: the one filter", 0, ["unframed_chosen": unframed.count, "unframed_refused": refusedUnframed,
                                                          "plain_frame_refused": refusedPlain, "film_edge_frame_on_table": laid,
                                                          "left_to_lay": MacLightTableCarry.shared.frames.count])
                r.check(!unframed.isEmpty && refusedUnframed, "pictures with no edit history in SpektraLab do not go on the Light Table")
                r.check(framed != nil && refusedPlain, "a frame never developed, with no film edge, does not go on the Light Table")
                r.check(opened && laid, "a frame with its film edge on lies on the Light Table")
                r.check(MacLightTableCarry.shared.frames.isEmpty, "the table took it once")
                if let f = framed?.develop?.frameID { model.library.update(f) { $0.edit.filmEdge.active = false } }
                await store.apply(MacImageQuery())
                model.router.toLibrary()
            }

            // 2. A SpektraLab catalog with a referenced folder kept in step.
            let photos = work.appending(path: "Card/DCIM/100")
            try fm.createDirectory(at: photos, withIntermediateDirectories: true)
            if picked.isEmpty {
                // No catalog to borrow from: the app's sample pictures.
                picked = (try? fm.contentsOfDirectory(at: Bundle.main.resourceURL!, includingPropertiesForKeys: nil))?
                    .filter { ["jpg", "jpeg", "heic", "dng"].contains($0.pathExtension.lowercased()) }.prefix(6).map { $0 } ?? []
            }
            for u in picked { try? fm.copyItem(at: u, to: photos.appending(path: u.lastPathComponent)) }
            let names = (try? fm.contentsOfDirectory(atPath: photos.path))?.sorted() ?? []
            let (cat, catMS) = try await timed { try await store.newCatalog(named: "Scratch", in: work) }
            r.note("catalog: create", catMS, ["path": cat.path ?? "-", "fixed": store.tree.fixed.map(\.title)])
            let (_, addMS) = try await timed { try await store.addFolder(work.appending(path: "Card"), to: cat.id) }
            r.note("catalog: add a folder (kept in step)", addMS, ["files": names.count, "listed": store.total,
                                                                   "watched": store.watchedFolders.map { $0.url.lastPathComponent },
                                                                   "recent_imports": store.tree.fixed.first { $0.kind == .recentImports }?.children.count ?? 0])
            r.check(store.total == names.count, "every picture of the folder is listed")
            r.check(store.tree.folders.map(\.title) == ["/"] && store.tree.folders.allSatisfy(isVolume),
                    "a SpektraLab catalog's folders sit under their volume, as Capture One's do")
            let (_, dMS) = await timed { await waitDescribed(store) }
            await store.select(collection: store.tree.defaultSelection)
            r.note("catalog: headers described", dMS, ["undescribed": store.facets.undescribed,
                                                       "cameras": store.facets.cameras.map { "\($0.value ?? "?") \($0.count)" },
                                                       "dated": store.facets.total - store.facets.undated])
            r.check(store.facets.undescribed == 0, "every new file is described")
            r.check(store.facets.cameras.contains { $0.value != nil }, "the camera facet fills in from the headers")
            // Finder: one moved into a subfolder, one deleted, one added.
            let rated = store.images.first { $0.fileName == names.first }
            if let rated { try await store.setRating(3, for: [rated.id]) }
            if names.count >= 3 {
                try fm.createDirectory(at: work.appending(path: "Card/DCIM/101"), withIntermediateDirectories: true)
                try fm.moveItem(at: photos.appending(path: names[0]), to: work.appending(path: "Card/DCIM/101/\(names[0])"))
                try fm.removeItem(at: photos.appending(path: names[1]))
                if let extra = picked.last { try fm.copyItem(at: extra, to: work.appending(path: "Card/DCIM/101/copy-\(extra.lastPathComponent)")) }
                let (_, sMS) = await timed { await store.synchronize(cat.id) }
                await store.select(collection: store.tree.defaultSelection)
                let moved = store.images.first { $0.id == rated?.id }
                r.note("catalog: synchronize after Finder changes", sMS, ["said": store.activity.lastSync ?? "-", "listed": store.total,
                                                                          "moved_row_path": moved?.url.path ?? "-", "moved_row_rating": moved?.rating ?? -1])
                r.check(store.total == names.count, "moved kept, deleted gone, new added (\(store.total))")
                r.check(moved?.url.path.hasSuffix("101/\(names[0])") == true && moved?.rating == 3, "the moved file kept its row and rating")
                r.check(store.tree.folders.first?.children.isEmpty == false || store.tree.all.contains { $0.title == "101" }, "the new subfolder is a folder row")
            }
            // A copy import: into the catalog's Originals.
            if let one = picked.first {
                let (n, iMS) = try await timed { try await store.importFiles([one], into: cat.id, mode: .copy) }
                let originals = (cat.path.map { URL(fileURLWithPath: $0).appending(path: "Originals") })
                let stored = originals.flatMap { fm.enumerator(atPath: $0.path)?.allObjects.compactMap { $0 as? String }.filter { $0.hasSuffix(one.lastPathComponent) } } ?? []
                r.note("catalog: import by copy", iMS, ["added": n, "stored": stored])
                r.check(n == 1 && !stored.isEmpty, "a copied import lands in the catalog's Originals")
            }

            // 3. A SpektraLab session: an import copies into Capture.
            let (session, sesMS) = try await timed { try await store.newSession(named: "Shoot", in: work) }
            let (n, impMS) = try await timed { try await store.importFiles(Array(picked.prefix(2)), into: session.id, mode: nil) }
            let capture = work.appending(path: "Shoot/Capture")
            r.note("session: create, then import (default: copy into Capture)", sesMS + impMS, [
                "added": n, "in_capture": (try? fm.contentsOfDirectory(atPath: capture.path)) ?? [], "listed": store.total,
                "fixed": store.tree.fixed.map(\.title)])
            r.check(n == min(2, picked.count) && store.total == n, "a session's import is copied into Capture and listed")
            if let extra = picked.dropFirst(2).first {
                try? fm.copyItem(at: extra, to: capture.appending(path: "tether-\(extra.lastPathComponent)"))
                await store.synchronize(session.id)
                // The new file's header is read in the background, and its reload empties the rows a moment
                // before it fills them: counted before that settles, the session read as 0 (2026-10-24).
                await waitDescribed(store)
                r.note("session: a file dropped into Capture, synchronized", 0, ["said": store.activity.lastSync ?? "-", "listed": store.total])
                r.check(store.total == n + 1, "the session notices a file put into its folder")
            }

            // 4. A Finder folder as a source; a Capture One session's caches never walked.
            let linked = work.appending(path: "Scans")
            try fm.createDirectory(at: linked, withIntermediateDirectories: true)
            for u in picked.prefix(3) { try? fm.copyItem(at: u, to: linked.appending(path: u.lastPathComponent)) }
            let (folderSource, fMS) = try await timed { try await store.open(linked) }
            r.note("folder: link and list", fMS, ["kind": folderSource.kind.rawValue, "listed": store.total])
            r.check(folderSource.kind == .folder && store.total == min(3, picked.count), "a linked folder lists its pictures")

            let c1s = work.appending(path: "Wedding")
            try fm.createDirectory(at: c1s.appending(path: "Capture/CaptureOne/Cache/Proxies"), withIntermediateDirectories: true)
            fm.createFile(atPath: c1s.appending(path: "Wedding.cosessiondb").path, contents: Data("not read".utf8))
            for u in picked.prefix(2) { try? fm.copyItem(at: u, to: c1s.appending(path: "Capture/\(u.lastPathComponent)")) }
            if let u = picked.first { try? fm.copyItem(at: u, to: c1s.appending(path: "Capture/CaptureOne/Cache/Proxies/\(u.lastPathComponent)")) }
            let (sessSource, cMS) = try await timed { try await store.open(c1s) }
            r.note("capture one session: open (folders only)", cMS, ["kind": sessSource.kind.rawValue, "listed": store.total,
                                                                     "read_only": sessSource.isReadOnly])
            r.check(sessSource.kind == .captureOneSession && store.total == min(2, picked.count), "a Capture One session lists its pictures, not its caches")

            // 5. The kept list, read back by the reader a launch uses (`readRegistry`). Until 2026-10-24 this
            // step read the file with JSONSerialization, a reader of its own, and so passed while every launch
            // failed to read the list and started over from the app library alone.
            var readBack: (sources: [MacSource], selected: UUID?)?
            var readError = ""
            do { readBack = try CatalogSourcesStore.readRegistry(try Data(contentsOf: CatalogSourcesStore.registryURL)) } catch { readError = "\(error)" }
            r.note("sources kept", 0, ["file": CatalogSourcesStore.registryURL.path, "kinds": readBack?.sources.map(\.kind.rawValue) ?? [],
                                       "selected": readBack?.selected?.uuidString ?? "-", "error": readError])
            r.check(readBack?.sources.map(\.id) == store.sources.map(\.id), "the sources list reads back as a launch reads it")
            r.check(readBack?.selected == store.selectedSourceID, "the last source chosen is the one a launch opens")
        } catch {
            r.check(false, "threw: \(error.localizedDescription)")
        }
        return ["steps": r.steps, "failures": r.failures, "passed": r.failures.isEmpty]
    }
}
#endif
