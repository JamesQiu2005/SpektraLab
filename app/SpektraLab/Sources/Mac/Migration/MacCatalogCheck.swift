//  MacCatalogCheck.swift — a debug build's proof that the SpektraLab Library became catalogs (2026-10-24).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --catalog-check <dir> [--catalog-check-relaunch]
//          [--catalog-check-c1 "<…>.cocatalog"] [--library-check-exit]
//
//  Writes `<dir>/report.json` (or `relaunch.json`, `c1.json`). Run on a scratch home that holds a copy
//  of a real `library.json` (and its `Originals/`):
//
//  1. the move (`MacLibraryMove`): offered; into `~/Pictures/SpektraLab Library.spkcatalog`; every
//     frame's file in the catalog; one Recent Import per old import, named with its time; Favourites
//     as an album and a linked folder kept in step (both given to the scratch copy first, since the
//     owner's library has none); the frames found again by path (the develop column, film and paper);
//     no file moved, copied or deleted (every file's size, time and inode before and after); the catalog
//     selected and kept as the one a launch opens; 1–5 in the store, read back from the helper;
//  2. `--catalog-check-relaunch`: a second launch reopens the catalog and does not offer the move;
//  3. `--catalog-check-c1`: Copy to SpektraLab Catalog of a Capture One catalog (spklib 0.3.0): the
//     counts the mirror's, a former Capture One album renamed, a mirror rating carried over; Update
//     from Capture One right after is skipped. (The package's census is taken outside, before and after.)
//
//  Not in a release build.

#if DEBUG
import Foundation

@MainActor
enum MacCatalogCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--catalog-check"), i + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let relaunch = arguments.contains("--catalog-check-relaunch")
        let c1 = arguments.firstIndex(of: "--catalog-check-c1").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let exits = arguments.contains("--library-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let r = Report()
            if let c1 { await copyStep(model, r, URL(fileURLWithPath: c1), out: out) }
            else if relaunch { await relaunchStep(model, r) }
            else { await moveStep(model, r, out: out) }
            let name = c1 != nil ? "c1.json" : relaunch ? "relaunch.json" : "report.json"
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let report: [String: Any] = ["steps": r.steps, "failures": r.failures, "passed": r.failures.isEmpty, "home": NSHomeDirectory()]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: name))
            }
            print("catalog-check: wrote \(out.appending(path: name).path), \(r.failures.count) failures")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        func note(_ name: String, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            steps.append(s)
            NSLog("catalog-check: %@ %@", name, "\(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); NSLog("catalog-check: FAIL %@", what) }
        }
    }

    /// Every file's size, modification time and inode: what a move, a copy or a delete would change.
    nonisolated static func census(_ files: [URL]) -> [String: String] {
        var out: [String: String] = [:]
        for u in files {
            let a = try? FileManager.default.attributesOfItem(atPath: u.path)
            let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
            let time = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let inode = (a?[.systemFileNumber] as? NSNumber)?.int64Value ?? -1
            out[u.path] = "\(size) \(time) \(inode)"
        }
        return out
    }

    /// Every file under `folder`, packages and all.
    nonisolated static func files(under folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    // MARK: 1. the move

    private static func moveStep(_ model: AppServices, _ r: Report, out: URL) async {
        let store = model.macLibrary
        let library = model.library
        let fm = FileManager.default
        await store.start()
        let move = store.move
        r.note("start", ["frames": library.frames.count, "sources": store.sources.map(\.kind.rawValue),
                         "phase": "\(move.phase)", "candidates": move.candidates.count])
        r.check(move.phase == .offered, "the move is offered at the first launch with app-library frames")
        r.check(!store.sources.contains { $0.kind == .appLibrary }, "the app library is not a source")
        let expected = NSHomeDirectory() + "/Pictures/SpektraLab Library.spkcatalog"
        r.check(move.destination.path == expected, "the default place is ~/Pictures/SpektraLab Library.spkcatalog (\(move.destination.path))")

        // What the owner's library has none of: two favourites, and a linked folder of two pictures.
        let eligible = library.frames.filter { !$0.isDemo && !$0.isPair && $0.picture.fileURL != nil }
        let favourites = eligible.filter { $0.picture.fileURL.map { fm.fileExists(atPath: $0.path) } ?? false }.prefix(2).map(\.id)
        for id in favourites { library.update(id) { $0.isFavourite = true } }
        let linked = out.appending(path: "work/Linked folder")
        try? fm.removeItem(at: out.appending(path: "work"))
        try? fm.createDirectory(at: linked, withIntermediateDirectories: true)
        for f in eligible.prefix(2) {
            if let u = f.picture.fileURL { try? fm.copyItem(at: u, to: linked.appending(path: "linked-" + u.lastPathComponent)) }
        }
        let folder = LinkedFolder(id: UUID(), volume: "Scratch", path: "Linked folder", kind: .disk, frameCount: 0, isConnected: true)
        library.addFolder(folder, at: linked)

        // The census before: every Originals file, and every file a frame names.
        let originals = CatalogSourcesStore.root.appending(path: "Originals")
        let named = eligible.compactMap(\.picture.fileURL)
        let watched = files(under: originals) + named
        let before = census(watched)
        r.note("census before", ["files": before.count, "originals": files(under: originals).count])

        move.evaluate()
        let candidates = move.candidates
        let byMinute = Dictionary(grouping: candidates.compactMap { library.frame($0) }) { Int($0.importedAt.timeIntervalSince1970 / 60) }
        let t0 = ContinuousClock.now
        await move.run()
        let seconds = (ContinuousClock.now - t0) / .seconds(1)
        guard case .done(let o) = move.phase else {
            r.check(false, "the move finishes (\(move.phase))")
            return
        }
        r.note("move", ["candidates": candidates.count, "moved": o.moved, "left": o.left.mapValues { $0 }.map { "\($0.key): \($0.value)" },
                        "imports": o.imports, "favourites": o.favourites, "folders": o.folders, "seconds": (seconds * 100).rounded() / 100,
                        "catalog": o.catalog.path])
        r.check(o.catalog.path == expected, "the catalog is where the page said")

        // Every frame's file in the catalog, asked of the helper by path.
        guard let source = store.sources.first(where: { $0.id == o.source }), let h = try? await store.handle(source) else {
            r.check(false, "the catalog is a source")
            return
        }
        let paths = candidates.compactMap { library.frame($0)?.picture.fileURL }
        let present = paths.filter { fm.fileExists(atPath: $0.path) }.count
        let uniquePaths = Array(Set(paths.map { CatalogSourcesStore.key($0.path) })).map { URL(fileURLWithPath: $0) }
        var found = 0
        for start in stride(from: 0, to: uniquePaths.count, by: 500) {
            let part = Array(uniquePaths[start..<min(start + 500, uniquePaths.count)])
            found += ((try? await store.client.lookup(h, paths: part))?.results.filter(\.found).count) ?? 0
        }
        r.note("every frame's file", ["frames": paths.count, "frames_with_file_there": present, "distinct_files": uniquePaths.count,
                                      "in_catalog": found])
        r.check(found == uniquePaths.count && present == o.moved, "every frame whose file is there is in the catalog (\(found) of \(uniquePaths.count) files)")
        r.check(o.left.count == paths.count - present, "only frames whose file is gone are left out")

        // Selected, and kept as the one a launch opens.
        r.check(store.selectedSourceID == o.source, "the new catalog is selected")
        let kept = try? CatalogSourcesStore.readRegistry(Data(contentsOf: CatalogSourcesStore.registryURL))
        r.check(kept?.selected == o.source, "the sources list opens the catalog at the next launch")
        r.check(kept?.sources.contains { $0.kind == .appLibrary } == false, "the sources list holds no app library")
        let record = MacLibraryMove.readRecord()
        r.check(record.moves.count == 1 && Set(record.moves[0].frames) == Set(candidates), "the move is recorded with its frames")
        r.check(MacLibraryMove.candidates(library.frames, record: record).isEmpty && move.phase != .offered,
                "nothing is left to offer")

        // The Recent Imports: one per old import, named with its time, holding its frames' files (a file
        // two frames share, or one an older import already brought, is in the first album only, as in
        // any import). The linked folder's first look is an import of its own, of the files no frame had.
        await settle(store)
        let imports = store.tree.fixed.first { $0.kind == .recentImports }?.children ?? []
        var seen = Set<String>()
        var wanted: [[String: Any]] = []
        for m in byMinute.keys.sorted() {
            let name = MacLibraryMove.importName(Date(timeIntervalSince1970: Double(m) * 60))
            let files = Set(byMinute[m]!.compactMap { $0.picture.fileURL?.path }.filter { fm.fileExists(atPath: $0) }.map(CatalogSourcesStore.key))
            let new = files.subtracting(seen)
            seen.formUnion(files)
            let album = imports.first { $0.title == name }
            wanted.insert(["name": name, "files": new.count, "frames": byMinute[m]!.count, "album": album?.imageCount ?? -1,
                           "created_at": album?.createdAt.map { "\($0)" } ?? "-"], at: 0)
        }
        let names = Set(wanted.map { $0["name"] as! String })
        let extra = imports.filter { !names.contains($0.title) }
        r.note("recent imports", ["albums": imports.map { "\($0.title) · \($0.imageCount ?? -1)" }, "wanted": wanted,
                                  "linked_folder_import": extra.map { "\($0.title) · \($0.imageCount ?? -1)" }])
        r.check(imports.count - extra.count == min(byMinute.count, 20), "one Recent Import per old import (\(imports.count - extra.count) of \(byMinute.count))")
        r.check(wanted.allSatisfy { ($0["files"] as? Int) == ($0["album"] as? Int) }, "each import's album holds its frames' files")
        r.check(imports.filter { names.contains($0.title) }.map(\.title) == wanted.map { $0["name"] as! String },
                "newest first, named with the import's time")
        r.check(extra.count == 1 && extra.first?.imageCount == 2, "the linked folder's two new files are its first look's import")

        // Favourites and the linked folder.
        let favAlbum = store.tree.user.first { $0.kind == .album && $0.title == L("Favourites") }
        r.note("favourites and linked folder", ["favourites_album": favAlbum?.imageCount ?? -1, "watched": store.watchedFolders.map(\.url.path)])
        r.check(favAlbum?.imageCount == favourites.count, "Favourites is an album of the favourites")
        r.check(store.watchedFolders.contains { CatalogSourcesStore.key($0.url.path) == CatalogSourcesStore.key(linked.path) },
                "the linked folder is kept in step by the catalog")

        // Found again by path: the develop column, film and paper.
        await store.select(collection: store.tree.defaultSelection)
        await settle(store)
        await store.loadAll()
        let rows = store.images
        let joined = rows.filter { $0.develop != nil }
        let sample = joined.prefix(3).map { "\($0.fileName): \($0.develop?.film ?? "-") · \($0.develop?.paper ?? "-") · \($0.develop.map { "\($0.state)" } ?? "-")" }
        var matches = 0
        for row in joined {
            guard let id = row.develop?.frameID, let f = library.frame(id) else { continue }
            if f.picture.fileURL.map({ CatalogSourcesStore.key($0.path) }) == CatalogSourcesStore.key(row.url.path),
               row.develop == CatalogSourcesStore.developInfo(f) { matches += 1 }
        }
        let developed = joined.filter { $0.develop?.state == .developed }.count
        let unique = Set(paths.filter { fm.fileExists(atPath: $0.path) }.map { CatalogSourcesStore.key($0.path) }).count
        r.note("found again by path", ["rows": rows.count, "with_frame": joined.count, "same_frame_film_paper": matches,
                                       "developed": developed, "sample": sample])
        r.check(joined.count == unique, "every moved picture finds its frame (\(joined.count) of \(unique) files)")
        r.check(matches == joined.count, "each row's film, paper and state are its frame's")
        r.check(store.facets.developed == joined.count, "the Opened in Develop facet counts them (\(store.facets.developed))")

        // Nothing moved, copied or deleted.
        let after = census(watched)
        let differing = before.filter { after[$0.key] != $0.value }.map(\.key)
        let newOriginals = files(under: originals).count
        r.note("census after", ["files": after.count, "differing": differing, "originals": newOriginals])
        r.check(differing.isEmpty && newOriginals == files(under: originals).count && before.count == after.count,
                "no file moved, copied or deleted")
        r.check(!fm.fileExists(atPath: o.catalog.appending(path: "Originals").path)
                    || files(under: o.catalog.appending(path: "Originals")).isEmpty, "nothing was copied into the catalog")

        // 1–5 in the store, read back from the helper.
        let rate = Array(rows.prefix(3))
        guard rate.count == 3 else { r.check(false, "three pictures to rate (\(rows.count) listed)"); return }
        do {
            try await store.setRating(4, for: rate.map(\.id))
            try await store.setColorLabel(.green, for: [rate[0].id])
            var q = LibraryQuery()
            q.ratings = [4]
            q.checkFiles = false
            let back = try await store.client.images(h, q, offset: 0, limit: 100)
            let ids = Set(back.images.map(\.uuid))
            r.note("rating", ["rated": rate.map(\.fileName), "read_back_4": back.total, "facet_4": store.facets.ratings.first { $0.value == 4 }?.count ?? -1])
            r.check(rate.allSatisfy { ids.contains($0.id.image) } && back.total == rate.count, "4 stars kept in the catalog")
            r.check(store.images.first { $0.id == rate[0].id }?.colorLabel == .green, "a colour label kept")
            r.check(store.facets.ratings.first { $0.value == 4 }?.count == rate.count, "the rating facet counts them")
        } catch {
            r.check(false, "rating in the catalog: \(error.localizedDescription)")
        }
    }

    /// Until the store is still: no work under way, every header described, the rows read.
    private static func settle(_ store: CatalogSourcesStore, seconds: Double = 20) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(300))
            if store.activity.working == nil, store.facets.undescribed == 0, store.total > 0, store.images.count > 0 { break }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    // MARK: 2. a relaunch

    private static func relaunchStep(_ model: AppServices, _ r: Report) async {
        let store = model.macLibrary
        await store.start()
        let record = MacLibraryMove.readRecord()
        let catalog = record.moves.last
        r.note("relaunch", ["selected": store.selectedSource?.path ?? "-", "phase": "\(store.move.phase)",
                            "candidates": store.move.candidates.count, "sources": store.sources.map(\.name),
                            "total": store.total, "rated_4": store.facets.ratings.first { $0.value == 4 }?.count ?? -1])
        r.check(catalog != nil && store.selectedSourceID == catalog?.source, "the moved catalog is reopened")
        r.check(store.move.phase == .idle && store.move.candidates.isEmpty, "the move is not offered again")
        r.check(store.total > 0, "the catalog's pictures are listed")
        r.check(!store.sources.contains { $0.kind == .appLibrary }, "the app library is not a source")
    }

    // MARK: 3. Copy to SpektraLab Catalog, and Update from Capture One (spklib 0.3.0)

    private static func copyStep(_ model: AppServices, _ r: Report, _ c1: URL, out: URL) async {
        let store = model.macLibrary
        await store.start()
        do {
            let s = try await store.open(c1)
            let mirrorTotal = store.total
            let mirrorTree = store.tree
            let mirrorAlbums = mirrorTree.all.filter { $0.kind == .album && $0.isCaptureOne }
            await store.loadAll()
            guard let picked = store.images.first(where: { !$0.isOffline }) else { r.check(false, "a picture to rate"); return }
            try await store.setRating(5, for: [picked.id])
            try await store.setColorLabel(.blue, for: [picked.id])
            let mirrorHandle = try await store.handle(s)
            let mirrorInfo = try await store.client.info(mirrorHandle)
            r.note("mirror", ["images": mirrorInfo.counts.images, "visible": mirrorTotal, "albums": mirrorAlbums.count,
                              "rated": picked.fileName])

            let target = out.appending(path: "work/\(s.name).spkcatalog")
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let t0 = ContinuousClock.now
            let copy = try await store.copyCaptureOne(s.id, to: target)
            let seconds = (ContinuousClock.now - t0) / .seconds(1)
            r.note("copy", ["images": copy.images, "variants": copy.variants, "collections": copy.collections, "folders": copy.folders,
                            "keywords": copy.keywords, "album_members": copy.albumMembers, "warnings": copy.warnings,
                            "seconds": (seconds * 100).rounded() / 100, "path": copy.source.path ?? "-",
                            "copied_from": copy.source.copiedFrom?.path ?? "-"])
            r.check(copy.images == mirrorInfo.counts.images, "the copy holds the mirror's images (\(copy.images) of \(mirrorInfo.counts.images))")
            r.check(store.selectedSourceID == copy.source.id && store.total == mirrorTotal, "the copy opens, listing what the mirror lists")
            r.check(store.sources.contains { $0.id == s.id }, "the Capture One source stays on the list")
            r.check(copy.source.isCopiedFromCaptureOne, "the copy knows where it came from")
            let copyAlbums = store.tree.all.filter { $0.kind == .album }
            r.check(copyAlbums.count >= mirrorAlbums.count, "every Capture One album is an album of the copy")

            // The mirror's rating and label came with it.
            let h = try await store.handle(copy.source)
            let found = try await store.client.lookup(h, paths: [picked.url])
            if let image = found.results.first?.match?.image {
                let d = try await store.client.image(h, image)
                r.check(d.variants.first?.rating == 5 && d.variants.first?.colorTag == MacColorLabel.blue.rawValue,
                        "the mirror's rating and label are the copy's")
            } else {
                r.check(false, "the rated picture is in the copy")
            }

            // A former Capture One album is SpektraLab's now: renamed.
            if let album = copyAlbums.first {
                try await store.client.renameCollection(h, album.id, to: album.title + " (renamed)")
                let list = try await store.client.collections(h)
                let renamed = list.first { $0.uuid == album.id }
                r.note("rename", ["was": album.title, "now": renamed?.name ?? "-", "editable": renamed?.editable ?? false])
                r.check(renamed?.name == album.title + " (renamed)", "an album of the copy is renamed")
            }

            // Update right after: nothing new in Capture One.
            let u = try await store.updateFromCaptureOne(copy.source.id)
            r.note("update", ["skipped": u.skipped, "added": u.added, "updated": u.updated, "gone": u.gone,
                              "conflicts_kept": u.conflictsKept, "said": store.activity.lastSync ?? "-"])
            r.check(u.skipped, "Update from Capture One right after the copy is skipped")
        } catch {
            r.check(false, "copy and update: \(error.localizedDescription)")
        }
    }
}
#endif
