//  MacVariantCheck.swift — a debug build's proof of PRD-G part 1 (a variant is a frame of its own, joined to the
//  library by (file, variant); a grid cell is a variant), in the running app. `tools/variant_check.sh` runs it twice.
//
//      CFFIXED_USER_HOME=<scratch> SpektraLab --library real --defaults-suite <suite> --variant-check <dir> \
//          --variant-check-files <a.jpg> [--variant-check-raw <x.ARW>] [--variant-check-c1 <X.cocatalog>] \
//          [--variant-check-relaunch <run 1's dir>] [--library-check-exit]
//
//  Run 1 writes `<dir>/report.json` and `<dir>/made.json` (what the relaunch must find):
//
//  A. (§6.1) a scratch SpektraLab catalog of two copies of the picture, the first given a second variant by the
//     helper: the grid shows two cells of its file, numbered 1 and 2 of 2, the count stays two images; the join
//     makes each its own frame (the first's with no variant, the second's with its uuid), each with its own edit, and
//     Develop opens each on its own; one frame per (file, variant).
//  B. (§6.5) the second variant rated 4: the first keeps 0, the 4-star filter finds the image, counted once, and
//     shows that variant's cell only (Capture One filters variants).
//  C. the frame-side calls part 2 wires (PRD-G §3): New Variant's frame has the edit a fresh open gets and no
//     history; Clone Variant's has an equal edit, no history, and its preview asked; Delete Variant takes the frame,
//     its develop and its history and leaves the file; the last variant is refused, by the store and by the helper.
//  F. two catalogs on one file: deleting the file's primary variant in one keeps the frame (the file's own, joined by
//     path) with its edit and history, and the other catalog's row still joins it; a file no other catalog lists
//     loses its primary's frame as before; and where the image's next variant has no frame of its own, it is given one
//     (its variant, a fresh edit) instead of joining the kept frame.
//  D. (§6.4, with `--variant-check-c1`) a Capture One mirror's two-variant image: two cells, each opening a frame of
//     its own, Capture One's ratings each on its own cell; one of Capture One's variants cannot be deleted.
//  E. (§6.6, with `--variant-check-raw`) two frames of one RAW with one decode name one proxy file; with another
//     white balance, two (`EngineRouter.proxyNames`).
//
//  With `--variant-check-relaunch` (§6.7): every frame run 1 made is there, with its variant, its edit and its
//  history, and the catalog's cells join to the same frames, the first cell to the primary's. With
//  `--variant-check-old-build <exposure>` 2.3.2's own coder went over `library.json` in between (`variant_check.sh`):
//  the primaries carry its change, every variant's frame is as run 1 left it (`variants.json`).
//
//  Not in a release build.

#if DEBUG
import Foundation

@MainActor
enum MacVariantCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--variant-check"), i + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        func path(_ flag: String) -> URL? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        }
        let files = arguments.firstIndex(of: "--variant-check-files").map { arguments[($0 + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) } } ?? []
        let c1 = path("--variant-check-c1"), raw = path("--variant-check-raw"), previous = path("--variant-check-relaunch")
        let exits = arguments.contains("--library-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let r = Report()
            let t0 = Date()
            if let previous {
                await relaunch(model, r, previous: previous)
            } else {
                await run(model, r, out: out, files: files, c1: c1, raw: raw)
            }
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let report: [String: Any] = ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": r.failures.isEmpty,
                                         "home": NSHomeDirectory(), "seconds": Date().timeIntervalSince(t0)]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("variant-check: wrote \(out.appending(path: "report.json").path), \(r.checks) checks, \(r.failures.count) failures")
            if exits {
                await model.history.drained()
                model.library.flush()
                await model.macLibrary.host.shutdown()
                exit(r.failures.isEmpty ? 0 : 1)
            }
        }
    }

    final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var checks = 0
        func note(_ name: String, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            steps.append(s)
            print("variant-check: \(name) \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            print("variant-check: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
    }

    /// What run 1 made, for the relaunch (§6.7).
    struct Made: Codable {
        struct Frame: Codable { var id: UUID; var variant: String?; var exposure: Double; var steps: Int; var file: String }
        var catalog: UUID
        var fileName: String
        var frames: [Frame]
    }

    private static func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
        return done()
    }

    /// The steps a frame's history holds (0: none), after every call sent before.
    private static func steps(_ model: AppServices, _ id: UUID) async -> Int {
        let listing = try? await model.history.ask("variant check") { try await $0.listing(id) }
        return listing?.steps.count ?? 0
    }

    /// An exposure pasted onto frames of no page, one step of history each (`pasteOntoLibrary`).
    private static func paste(_ model: AppServices, exposure: Double, onto ids: Set<LibraryFrame.ID>) {
        var settings = FrameEdit.default
        settings.adjustments.exposure = exposure
        _ = model.pasteOntoLibrary(SettingsClip(groups: [.light], settings: settings, sourceName: "variant check", sourceAspect: 1.5), onto: ids)
    }

    private static func cellsOf(_ store: CatalogSourcesStore, _ name: String) -> [MacImage] { store.images.filter { $0.fileName == name } }

    private static func readsFile(_ f: LibraryFrame, _ url: URL) -> Bool { f.picture.fileURL.map { FolderReach.same($0, url) } ?? false }

    /// A frame's edit with its seed set aside: New Variant's frame is a fresh open's, whose seed is its own.
    private static func unseeded(_ e: FrameEdit) -> FrameEdit { var e = e; e.frameSeed = 0; return e }

    // MARK: - run 1

    private static func run(_ model: AppServices, _ r: Report, out: URL, files: [URL], c1: URL?, raw: URL?) async {
        let store = model.macLibrary
        let library = model.library
        let fm = FileManager.default
        guard let picture = files.first else { r.check(false, "a picture to make variants of (--variant-check-files)"); return }
        await store.start()
        r.check(NSHomeDirectory().contains("variant-check-home") || ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil,
                "the run's home is a scratch one (\(NSHomeDirectory()))")
        r.check(model.defaults !== UserDefaults.standard, "the model's settings are a defaults suite of the check's")
        var made = Made(catalog: UUID(), fileName: "", frames: [])
        do {
            // A. §6.1: two variants of one file.
            let work = out.appending(path: "work")
            try? fm.removeItem(at: work)
            let card = work.appending(path: "Card")
            try fm.createDirectory(at: card, withIntermediateDirectories: true)
            let name = "1-\(picture.lastPathComponent)", single = "2-\(picture.lastPathComponent)"
            try fm.copyItem(at: picture, to: card.appending(path: name))
            try fm.copyItem(at: picture, to: card.appending(path: single))
            let cat = try await store.newCatalog(named: "Variants", in: work)
            made.catalog = cat.id
            made.fileName = name
            try await store.addFolder(card, to: cat.id)
            _ = await wait(30) { store.total == 2 }
            await store.select(collection: store.tree.defaultSelection)
            _ = await wait(30) { store.total == 2 }
            guard let first = cellsOf(store, name).first, let catSource = store.sources.first(where: { $0.id == cat.id }) else {
                r.check(false, "the pictures are listed"); return
            }
            let fileURL = first.url
            let h = try await store.handle(catSource)
            let second = try await store.client.newVariant(h, image: first.id.image, from: nil)
            await store.reload()
            var cells = cellsOf(store, name)
            r.note("A. a second variant of one file", ["variant": second.variant, "position": second.position, "cells": cells.count,
                                                      "ids": cells.map { $0.id.variant ?? "nil" }, "numbers": cells.map(\.variantNumber),
                                                      "total": store.total, "all_cells": store.images.count])
            r.check(cells.count == 2, "6.1 the grid shows both variants of the file (\(cells.count) cells)")
            r.check(cells.map(\.variantNumber) == [1, 2] && cells.allSatisfy { $0.variantCount == 2 }, "6.1 numbered 1 and 2 of 2, by their order")
            r.check(cells.map(\.id.variant) == [cells.first?.primaryVariant, second.variant] && cells.allSatisfy { $0.id.variant != nil },
                    "6.1 each cell's id names its variant")
            r.check(store.total == 2 && store.images.count == 3, "6.1 the count stays per image: 2 images in 3 cells")
            guard cells.count == 2 else { return }
            let fresh0 = try await store.frames(for: cells.map(\.id), focus: nil).frames
            guard let f1 = fresh0[cells[0].id], let f2 = fresh0[cells[1].id], f1 != f2 else {
                r.check(false, "6.1 each variant has a frame of its own (\(Set(fresh0.values).count))"); return
            }
            r.check(library.frame(f1)?.variant == nil && library.frame(f2)?.variant == second.variant,
                    "6.1 the primary's frame has no variant (the file's own); the second's has its uuid")
            let freshEdit = library.frame(f1).map { unseeded($0.edit) }
            paste(model, exposure: 0.3, onto: [f1])
            paste(model, exposure: -0.4, onto: [f2])
            store.refreshDevelopInfo()
            cells = cellsOf(store, name)
            let joined = try await store.frames(for: cells.map(\.id), focus: nil).frames
            let exposures = cells.compactMap { joined[$0.id].flatMap { library.frame($0)?.edit.adjustments.exposure } }
            r.note("A. the join", ["frames": cells.map { joined[$0.id]?.uuidString ?? "-" }, "exposures": exposures,
                                   "develop": cells.map { $0.develop?.frameID.uuidString ?? "-" }])
            r.check(joined[cells[0].id] == f1 && joined[cells[1].id] == f2 && cells.map(\.develop?.frameID) == [f1, f2],
                    "6.1 the join finds each variant's own frame again")
            r.check(exposures == [0.3, -0.4], "6.1 each variant has its own edit (\(exposures))")
            let perVariant = cells.map { c in library.frames.filter { readsFile($0, fileURL) && $0.variant == (c.isPrimaryVariant ? nil : c.variant) }.count }
            r.check(perVariant == [1, 1], "6.1 one frame per (file, variant) (\(perVariant))")
            // Develop opens each on its own.
            for (cell, want, ev) in [(cells[1], f2, -0.4), (cells[0], f1, 0.3)] {
                try await store.openInDevelop([cell.id], focus: cell.id)
                let opened = await wait(20) { MacShellBar.shared.develop?.frameID == want && model.openSession(want) != nil }
                let shown = model.openSession(want)?.edit.adjustments.exposure
                r.check(opened && shown == ev, "6.1 Develop opens variant \(cell.variantNumber) on its own frame and edit (\(shown ?? .nan))")
                model.router.toLibrary()
                try? await Task.sleep(for: .seconds(1))
            }
            await store.select(collection: store.tree.defaultSelection)
            cells = cellsOf(store, name)

            // B. §6.5: the second variant rated.
            try await store.setRating(4, for: [cells[1].id])
            let d = try await store.detail(of: cells[1].id)
            let ratings = d.variants.map(\.rating)
            r.note("B. the second variant rated 4", ["ratings": ratings, "cells": cellsOf(store, name).map(\.rating),
                                                     "detail_cell": [d.image.variantNumber, d.image.rating]])
            r.check(ratings == [0, 4], "6.5 the second variant has the rating and the first is untouched (\(ratings))")
            r.check(cellsOf(store, name).map(\.rating) == [0, 4] && d.image.rating == 4 && d.image.variantNumber == 2,
                    "6.5 each cell shows its own variant's rating")
            var q = store.query.cleared
            q.minimumRating = 4
            await store.apply(q)
            let four = store.facets.ratings.first { $0.value == 4 }?.count
            r.note("B. filter 4 stars", ["total": store.total, "cells": store.images.map { "\($0.fileName) \($0.variantNumber)" },
                                         "facet_4": four ?? -1, "facets_total": store.facets.total])
            r.check(store.total == 1 && store.facets.total == 1, "6.5 the rating filter finds the image, counted once (\(store.total))")
            r.check(store.images.map(\.id) == [cells[1].id], "6.5 and shows the variant that has the rating, not the image's other")
            await store.apply(store.query.cleared)
            r.check(store.total == 2, "6.5 the count of the source does not jump: 2 images (\(store.total))")

            // C. The frame-side calls (part 2 wires them to menus).
            cells = cellsOf(store, name)
            let new = try await store.newVariant(of: cells[0].id, clone: false)
            let clone = try await store.newVariant(of: cells[0].id, clone: true)
            cells = cellsOf(store, name)
            let newFrame = library.frame(new.frame), cloneFrame = library.frame(clone.frame)
            let newSteps = await steps(model, new.frame), cloneSteps = await steps(model, clone.frame)
            r.note("C. New Variant and Clone Variant", ["cells": cells.map { "\($0.variantNumber)/\($0.variantCount)" },
                                                       "new": [new.variant, newFrame?.edit.adjustments.exposure ?? .nan],
                                                       "clone": [clone.variant, cloneFrame?.edit.adjustments.exposure ?? .nan],
                                                       "history": [newSteps, cloneSteps], "total": store.total])
            r.check(cells.count == 4 && cells.map(\.variantNumber) == [1, 2, 3, 4] && cells.last?.id == clone.cell,
                    "6.2 the new cells come after the image's others, numbered 3 and 4 of 4")
            r.check(newFrame?.variant == new.variant && newFrame.map { unseeded($0.edit) } == freshEdit,
                    "6.2 New Variant's frame has the edit a fresh open gets, not the source's")
            r.check(cloneFrame?.variant == clone.variant && cloneFrame?.edit == library.frame(f1)?.edit,
                    "6.2 Clone Variant's frame has an equal edit (\(cloneFrame?.edit.adjustments.exposure ?? .nan))")
            r.check(newSteps == 0 && cloneSteps == 0, "6.2 both have an empty history (\(newSteps), \(cloneSteps))")
            let asked = await wait(30) { library.frame(clone.frame).map { $0.develop.isBusy || $0.shownDevelop != nil } ?? false }
            r.check(asked, "6.2 the clone's preview is asked at once")
            r.check(store.total == 2, "6.2 the count stays per image (\(store.total))")
            _ = await wait(60) { library.frame(clone.frame).map { !$0.develop.isBusy && $0.developed != nil } ?? true }
            // Delete Variant: the clone, whose preview was developed, after a step of history of its own.
            paste(model, exposure: 0.9, onto: [clone.frame])
            await model.history.drained()
            let cloneDevelop = library.frame(clone.frame)?.developed?.picture.fileURL
            let cloneHad = await steps(model, clone.frame)
            r.check(cloneDevelop.map { fm.fileExists(atPath: $0.path) } == true && cloneHad == 1,
                    "6.3 the clone has a develop on disk and a step of history to lose (\(cloneDevelop?.lastPathComponent ?? "none"), \(cloneHad))")
            try await store.deleteVariant(clone.cell)
            cells = cellsOf(store, name)
            await model.history.drained()
            let goneSteps = await steps(model, clone.frame)
            r.note("C. Delete Variant", ["cells": cells.map { "\($0.variantNumber)/\($0.variantCount)" }, "frame_left": library.frame(clone.frame) != nil,
                                         "file": fm.fileExists(atPath: fileURL.path), "develop_file": cloneDevelop?.lastPathComponent ?? "none"])
            r.check(library.frame(clone.frame) == nil && goneSteps == 0, "6.3 the variant's frame and history go")
            r.check(cloneDevelop.map { !fm.fileExists(atPath: $0.path) } == true, "6.3 and its develop's file")
            r.check(fm.fileExists(atPath: fileURL.path), "6.3 the file stays")
            r.check(cells.count == 3 && cells.map(\.variantNumber) == [1, 2, 3] && !cells.contains { $0.id == clone.cell },
                    "6.3 the image's other cells stay, numbered again 1 to 3")
            r.check(library.frame(f1) != nil && library.frame(f2) != nil && library.frame(new.frame) != nil, "6.3 the other variants' frames stay")
            if let only = cellsOf(store, single).first {
                do {
                    try await store.deleteVariant(only.id)
                    r.check(false, "6.3 the last variant is refused")
                } catch {
                    r.check(error as? MacLibraryError == .lastVariant, "6.3 the last variant is refused (\(error.localizedDescription))")
                }
                if let v = only.variant {
                    do {
                        _ = try await store.client.deleteVariant(h, variant: v)
                        r.check(false, "6.3 the helper refuses the last variant too")
                    } catch {
                        r.check((error as? LibraryError)?.code == .lastVariant, "6.3 the helper refuses the last variant too (last_variant)")
                    }
                }
            }
            await model.history.drained()
            for c in cells {
                guard let id = c.develop?.frameID, let f = library.frame(id) else { continue }
                made.frames.append(.init(id: id, variant: f.variant, exposure: f.edit.adjustments.exposure,
                                         steps: await steps(model, id), file: name))
            }
            r.check(made.frames.count == 3, "three frames of the file to find again after a relaunch (\(made.frames.count))")

            // F. Deleting a primary variant whose frame is the file's own (no variant: joined by path) must not take
            // another catalog's edit of that file; where no other catalog lists the file, the frame goes as before.
            try await sharedPrimary(model, r, work: work, picture: picture, first: cat, fresh: freshEdit)
            await store.select(source: cat.id)
            await store.select(collection: store.tree.defaultSelection)

            // D. §6.4: a Capture One mirror's two-variant image.
            if let c1 {
                let s = try await store.open(c1)
                await store.select(collection: store.tree.defaultSelection)
                _ = await wait(30) { store.total == 3 }
                let a = cellsOf(store, "A.jpg")
                r.note("D. Capture One's two variants", ["source": s.kind.rawValue, "total": store.total, "cells": store.images.count,
                                                        "a": a.map { [$0.id.variant ?? "nil", "\($0.variantNumber)/\($0.variantCount)", "\($0.rating)"] }])
                r.check(s.kind == .captureOneCatalog && store.total == 3 && store.images.count == 4, "6.4 three images in four cells")
                r.check(a.count == 2 && a.map(\.id.variant) == ["VAR-A1", "VAR-A2"] && a.map(\.rating) == [0, 4],
                        "6.4 the mirror's two-variant image shows two cells, each with its own Capture One rating")
                let af = try await store.frames(for: a.map(\.id), focus: nil).frames
                let frames = a.compactMap { af[$0.id] }
                r.check(frames.count == 2 && Set(frames).count == 2, "6.4 each opens a frame of its own (\(Set(frames).count))")
                r.check(frames.count == 2 && library.frame(frames[0])?.variant == nil && library.frame(frames[1])?.variant == "VAR-A2",
                        "6.4 the second's frame is Capture One's variant's")
                r.check(frames.compactMap { library.frame($0).map { unseeded($0.edit) } }.allSatisfy { $0 == freshEdit },
                        "6.4 each starts from SpektraLab's default edit, as a Capture One picture does")
                if frames.count == 2 {
                    paste(model, exposure: 0.6, onto: [frames[1]])
                    try await store.openInDevelop([a[1].id], focus: a[1].id)
                    let opened = await wait(20) { MacShellBar.shared.develop?.frameID == frames[1] }
                    r.check(opened && model.openSession(frames[1])?.edit.adjustments.exposure == 0.6
                            && library.frame(frames[0])?.edit.adjustments.exposure != 0.6,
                            "6.4 Develop opens Capture One's second variant on its own edit")
                    model.router.toLibrary()
                    try? await Task.sleep(for: .seconds(1))
                    await store.select(collection: store.tree.defaultSelection)
                    for f in frames {
                        if let fr = library.frame(f) {
                            made.frames.append(.init(id: f, variant: fr.variant, exposure: fr.edit.adjustments.exposure,
                                                     steps: await steps(model, f), file: "A.jpg"))
                        }
                    }
                }
                if let second = cellsOf(store, "A.jpg").last {
                    do {
                        try await store.deleteVariant(second.id)
                        r.check(false, "6.4 one of Capture One's variants cannot be deleted in a mirror")
                    } catch {
                        r.check(error as? MacLibraryError == .readOnly, "6.4 one of Capture One's variants cannot be deleted in a mirror (\(error.localizedDescription))")
                    }
                }
            } else {
                r.note("D. skipped: no Capture One catalog given")
            }

            // E. §6.6: two frames of one RAW, one proxy; another white balance, two.
            if let raw {
                let rawCard = work.appending(path: "Raw")
                try fm.createDirectory(at: rawCard, withIntermediateDirectories: true)
                let rawName = "r-\(raw.lastPathComponent)"
                try fm.copyItem(at: raw, to: rawCard.appending(path: rawName))
                await store.select(source: cat.id)
                try await store.addFolder(rawCard, to: cat.id)
                await store.select(collection: store.tree.defaultSelection)
                _ = await wait(30) { !cellsOf(store, rawName).isEmpty }
                if let rr = cellsOf(store, rawName).first {
                    _ = try await store.client.newVariant(h, image: rr.id.image, from: nil)
                    await store.reload()
                    let rc = cellsOf(store, rawName)
                    let rf = try await store.frames(for: rc.map(\.id), focus: nil).frames
                    let frames = rc.compactMap { rf[$0.id].flatMap { library.frame($0) } }
                    let one = model.darkroom.proxyNames(of: frames)
                    if let second = frames.last {
                        library.update(second.id) { $0.edit.decode.whiteBalance = .tungsten }
                    }
                    let two = model.darkroom.proxyNames(of: rc.compactMap { rf[$0.id].flatMap { library.frame($0) } })
                    r.note("E. two frames of one RAW", ["cells": rc.count, "frames": frames.count, "raw": frames.map(\.isRAW),
                                                       "same_decode": one.sorted(), "other_white_balance": two.sorted()])
                    r.check(frames.count == 2 && frames.allSatisfy(\.developsFromRAW), "6.6 two frames of one RAW")
                    r.check(one.count == 1, "6.6 one decode setting: one proxy file named (\(one.count))")
                    r.check(two.count == 2, "6.6 another white balance: two (\(two.count))")
                } else {
                    r.check(false, "6.6 the RAW is listed")
                }
            } else {
                r.note("E. skipped: no RAW given")
            }
            await model.history.drained()
            library.flush()
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try JSONEncoder().encode(made).write(to: out.appending(path: "made.json"))
        } catch {
            r.check(false, "ran without an error: \(error.localizedDescription)")
        }
    }

    /// F: two catalogs on one file (`Shared/s.jpg` in both), and a file in the first only (`Solo/o.jpg`). Each given a
    /// second variant in the first catalog, its primary's frame pasted onto, then that primary deleted there.
    private static func sharedPrimary(_ model: AppServices, _ r: Report, work: URL, picture: URL, first cat: MacSource, fresh: FrameEdit?) async throws {
        let store = model.macLibrary
        let library = model.library
        let fm = FileManager.default
        let shared = work.appending(path: "Shared"), solo = work.appending(path: "Solo")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try fm.createDirectory(at: solo, withIntermediateDirectories: true)
        try fm.copyItem(at: picture, to: shared.appending(path: "s.jpg"))
        try fm.copyItem(at: picture, to: shared.appending(path: "t.jpg"))
        try fm.copyItem(at: picture, to: solo.appending(path: "o.jpg"))
        let other = try await store.newCatalog(named: "Other", in: work)
        try await store.addFolder(shared, to: other.id)
        _ = await wait(30) { store.total == 2 }
        await store.select(source: cat.id)
        try await store.addFolder(shared, to: cat.id)
        try await store.addFolder(solo, to: cat.id)
        _ = await wait(30) { store.total == 5 }
        await store.select(collection: store.tree.defaultSelection)
        let listed = await wait(30) { !cellsOf(store, "s.jpg").isEmpty && !cellsOf(store, "o.jpg").isEmpty && !cellsOf(store, "t.jpg").isEmpty }
        r.check(listed, "F. the first catalog lists the shared file and its own (\(store.total) images)")
        let h = try await store.handle(cat)
        var primaries: [String: LibraryFrame.ID] = [:]
        for name in ["s.jpg", "o.jpg"] {
            guard let c = cellsOf(store, name).first else { r.check(false, "F. \(name) is listed"); return }
            _ = try await store.client.newVariant(h, image: c.id.image, from: nil)
            await store.reload()
            _ = await wait(20) { cellsOf(store, name).count == 2 }
            let cells = cellsOf(store, name)
            let fr = try await store.frames(for: cells.map(\.id), focus: nil).frames
            guard cells.count == 2, let p = fr[cells[0].id], fr[cells[1].id] != nil else {
                r.check(false, "F. \(name): two cells, two frames (\(cells.map { $0.id.variant ?? "nil" }), \(fr.count) frames, source \(store.selectedSourceID?.uuidString ?? "-"), all \(store.images.map(\.fileName)))")
                return
            }
            paste(model, exposure: 0.55, onto: [p])
            primaries[name] = p
        }
        // t.jpg, listed by both catalogs: a second variant made by the helper and never opened (as one of Capture One's
        // is), the primary's frame opened and pasted onto.
        guard let t = cellsOf(store, "t.jpg").first else { r.check(false, "F. t.jpg is listed"); return }
        _ = try await store.client.newVariant(h, image: t.id.image, from: nil)
        await store.reload()
        _ = await wait(20) { cellsOf(store, "t.jpg").count == 2 }
        let tCells = cellsOf(store, "t.jpg")
        guard tCells.count == 2, let tPrimary = try await store.frames(for: [tCells[0].id], focus: nil).frames[tCells[0].id],
              let tNext = tCells[1].variant else { r.check(false, "F. t.jpg: two cells, the primary's frame"); return }
        paste(model, exposure: 0.55, onto: [tPrimary])
        await model.history.drained()
        let sharedFrame = primaries["s.jpg"]!, soloFrame = primaries["o.jpg"]!
        let sharedSteps = await steps(model, sharedFrame)
        r.check(library.frame(sharedFrame)?.variant == nil && sharedSteps == 1, "F. the shared file's primary has the file's own frame, with a step of history")
        for name in ["s.jpg", "o.jpg", "t.jpg"] {
            store.refreshDevelopInfo()
            guard let c = cellsOf(store, name).first else { continue }
            try await store.deleteVariant(c.id)
        }
        await model.history.drained()
        let sharedKept = library.frame(sharedFrame), soloGone = library.frame(soloFrame) == nil
        let keptSteps = await steps(model, sharedFrame)
        // t.jpg's remaining variant is its primary now; with no frame of its own it would join the kept frame by the path.
        store.refreshDevelopInfo()
        let tLeft = cellsOf(store, "t.jpg")
        let tJoined = tLeft.count == 1 ? try await store.frames(for: [tLeft[0].id], focus: nil).frames[tLeft[0].id] : nil
        let tFrame = tJoined.flatMap { library.frame($0) }
        r.note("F. the new primary of a file another catalog lists", ["cells": tLeft.count, "joins_kept_frame": tJoined == tPrimary,
                                                                   "variant": tFrame?.variant ?? "none", "exposure": tFrame?.edit.adjustments.exposure ?? .nan])
        r.check(tLeft.count == 1 && tJoined != nil && tJoined != tPrimary && tFrame?.variant == tNext && tFrame.map { unseeded($0.edit) } == fresh,
                "F. the image's next variant, its primary now and never opened, gets a frame of its own (its variant, a fresh edit), not the other catalog's")
        r.check(library.frame(tPrimary)?.edit.adjustments.exposure == 0.55, "F. and the kept frame is still the other catalog's, with its edit")
        // The other catalog's row of the shared file still joins its frame, with its edit.
        await store.select(source: other.id)
        await store.select(collection: store.tree.defaultSelection)
        _ = await wait(30) { !cellsOf(store, "s.jpg").isEmpty }
        store.refreshDevelopInfo()
        let otherCell = cellsOf(store, "s.jpg").first
        r.note("F. a primary deleted where another catalog lists the file", [
            "shared_frame_kept": sharedKept != nil, "shared_exposure": sharedKept?.edit.adjustments.exposure ?? .nan, "shared_steps": keptSteps,
            "other_catalog_joins": otherCell?.develop?.frameID == sharedFrame, "solo_frame_gone": soloGone])
        r.check(sharedKept?.edit.adjustments.exposure == 0.55 && keptSteps == 1,
                "F. deleting the primary in one catalog keeps the file's frame, edit and history another catalog lists")
        r.check(otherCell?.develop?.frameID == sharedFrame, "F. the other catalog's row still joins that frame")
        r.check(soloGone, "F. where no other catalog lists the file, the primary's frame goes as before")
    }

    // MARK: - run 2, a relaunch (§6.7)

    private static func relaunch(_ model: AppServices, _ r: Report, previous: URL) async {
        let store = model.macLibrary
        let library = model.library
        guard let data = try? Data(contentsOf: previous.appending(path: "made.json")),
              let made = try? JSONDecoder().decode(Made.self, from: data) else { r.check(false, "7 run 1's record"); return }
        await store.start()
        // With `--variant-check-old-build <exposure>`, 2.3.2's own coder went over the library between the runs
        // (tools/variant_keep_old.swift): every frame it read had its exposure set to <exposure> and the file written back.
        // It reads `library.json` only: the primaries take its change; a variant's frame, kept in `variants.json`, must be
        // as run 1 left it, its variant uuid and all.
        let old = CommandLine.arguments.firstIndex(of: "--variant-check-old-build").flatMap {
            $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil
        }
        for want in made.frames {
            let f = library.frame(want.id)
            let steps = await steps(model, want.id)
            let exposure = want.variant == nil ? (old ?? want.exposure) : want.exposure
            r.check(f != nil && f?.variant == want.variant && f?.edit.adjustments.exposure == exposure && steps == want.steps,
                    "6.7 \(want.file) variant \(want.variant ?? "primary"): its frame, variant (\(f.map { $0.variant ?? "none" } ?? "gone")), "
                    + "edit (\(f?.edit.adjustments.exposure ?? .nan) of \(exposure)\(old != nil && want.variant == nil ? ", 2.3.2's" : "")) and history (\(steps) of \(want.steps)) are kept")
        }
        await store.select(source: made.catalog)
        await store.select(collection: store.tree.defaultSelection)
        _ = await wait(30) { !cellsOf(store, made.fileName).isEmpty }
        let cells = cellsOf(store, made.fileName)
        let joined = (try? await store.frames(for: cells.map(\.id), focus: nil).frames) ?? [:]
        let mine = Set(made.frames.filter { $0.file == made.fileName }.map(\.id))
        r.note("relaunch: the catalog's cells", ["cells": cells.map { "\($0.variantNumber)/\($0.variantCount)" },
                                                 "frames": cells.map { joined[$0.id]?.uuidString ?? "-" }])
        r.check(cells.count == mine.count && Set(cells.compactMap { joined[$0.id] }) == mine && cells.allSatisfy { $0.develop != nil },
                "6.7 after a relaunch the catalog's cells join to the same frames, one each")
        // The primary is still the primary: the image's first cell joins the frame run 1 made for it (no variant), not a
        // former variant's that lost its uuid.
        let primary = made.frames.first { $0.file == made.fileName && $0.variant == nil }?.id
        r.check(primary != nil && cells.first.flatMap { joined[$0.id] } == primary && cells.first.flatMap { joined[$0.id] }.flatMap { library.frame($0)?.variant } == nil,
                "6.7 the image's first cell still joins its primary's frame (\(cells.first.flatMap { joined[$0.id] }?.uuidString ?? "none"))")
    }
}
#endif
