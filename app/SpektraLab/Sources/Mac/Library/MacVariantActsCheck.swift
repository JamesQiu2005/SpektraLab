//  MacVariantActsCheck.swift — a debug build's proof of PRD-G part 2 in the running app: New Variant, Clone Variant
//  and Delete Variant as a person reaches them, and what they see. `tools/variant_check.sh` runs it as its third run.
//
//      CFFIXED_USER_HOME=<scratch> SpektraLab --library real --defaults-suite <suite> --variant-acts-check <dir> \
//          --variant-check-files <a.jpg> <b.jpg> [--variant-check-raw <x.ARW>] [--variant-check-c1 <X.cocatalog>] \
//          [--library-check-exit]
//
//  The ways in: the menu bar's **Image menu**, found in AppKit's main menu and its items performed as a click performs
//  them (`NSMenu performActionForItemAtIndex:`), and read for greyed or not (`isEnabled`, after `update`); the
//  **context menu**'s items run as their buttons run them (`MacVariantActions.chosen` → `perform`: SwiftUI's menu
//  cannot be clicked from here, so its button is the one thing not pressed); Delete's question answered as its
//  button answers it (`MacVariantActions.delete`). Writes `<dir>/report.json`, and window captures under
//  `<dir>/captures/` (the window server's, `screencapture -l`), in English and 简体中文.
//
//  N. (§6.2) New Variant from a cell's menu: a new cell after the image's others, chosen and in focus, with the edit a
//     fresh open gets and no history; the count of images unchanged.
//  C. (§6.2) Clone Variant from the Image menu: an equal edit, no history, its preview asked at once.
//  G. (§7.5) A half-frame pair and a double exposure: the Image menu's New and Clone greyed, the reason under them,
//     the act refused with it; Delete greyed on a picture with one variant, with its reason.
//  X. Export of an image's three variants: `P1.jpg`, `P1-2.jpg`, `P1-3.jpg`; the third alone is still `P1-3.jpg`.
//  E. (trap 34) Delete while an export batch holds the variant: refused with its reason, greyed in the Image menu,
//     nothing removed; offered again when the batch has ended.
//  P. Paste Settings onto one variant leaves its siblings; a rating on one is that cell's.
//  D. In Develop: New Variant from the Image menu opens the new variant on the page; Delete Variant of the variant open
//     moves the page to its neighbour, and takes the frame, its develops, previews, full renders and history (no file
//     of the app's names the frame after), never the file; the last variant and one of Capture One's are refused with
//     their reasons.
//  R. (§5, §6.6, with `--variant-check-raw`) two variants of one RAW with one decode: one proxy file, and the second's
//     first open is a proxy read (`RenderJob.rawDecode` false), not a RAW decode.
//  L. Paging (`hasMore`) at two images a page with multi-variant images; the Light Table from two variant cells.
//  K. (with `--variant-acts-keys <s>`) F2 and F3 as key events posted to the process by the script.
//
//  Not in a release build.

#if DEBUG
import Foundation
import SwiftUI
import UIKit

@MainActor
enum MacVariantActsCheck {
    typealias Report = MacVariantCheck.Report

    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--variant-acts-check"), i + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        func path(_ flag: String) -> URL? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        }
        let files = arguments.firstIndex(of: "--variant-check-files").map { arguments[($0 + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) } } ?? []
        let c1 = path("--variant-check-c1"), raw = path("--variant-check-raw")
        let exits = arguments.contains("--library-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let r = Report()
            let t0 = Date()
            await run(model, r, out: out, files: files, c1: c1, raw: raw)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let report: [String: Any] = ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": r.failures.isEmpty,
                                         "home": NSHomeDirectory(), "seconds": Date().timeIntervalSince(t0)]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("variant-acts-check: wrote \(out.appending(path: "report.json").path), \(r.checks) checks, \(r.failures.count) failures")
            if exits {
                await model.history.drained()
                model.library.flush()
                await model.macLibrary.host.shutdown()
                exit(r.failures.isEmpty ? 0 : 1)
            }
        }
    }

    // MARK: - small things

    static func until(_ s: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(s)
        while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return done()
    }
    static func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    static func cells(_ store: CatalogSourcesStore, _ name: String) -> [MacImage] { store.images.filter { $0.fileName == name } }

    static func choose(_ cells: [MacImage]) {
        let b = MacLibraryBrowser.shared
        b.selection = Set(cells.map(\.id))
        b.focus = cells.first?.id
        b.anchor = cells.first?.id
    }

    static func steps(_ model: AppServices, _ id: UUID) async -> Int {
        (try? await model.history.ask("variant acts check") { try await $0.listing(id) })?.steps.count ?? 0
    }

    static func unseeded(_ e: FrameEdit) -> FrameEdit { var e = e; e.frameSeed = 0; return e }

    /// Every file under the scratch home's app support (and the caches) whose name holds the frame's id: what the
    /// app kept of it — develops, previews, full renders, its Layer 2 copies.
    static var filesRoot: URL?

    static func filesNaming(_ frame: UUID) -> [String] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        // A catalog keeps its pictures' previews and develops in its own package (`Cache/Previews`, MAC-LIBRARY-DATA §2j).
        let roots = [home.appending(path: "Library/Application Support"), home.appending(path: "Library/Caches"), filesRoot ?? home]
        let keys = [frame.uuidString, frame.uuidString.lowercased()]
        var out: [String] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where keys.contains(where: { url.lastPathComponent.contains($0) }) { out.append(url.path) }
        }
        return out
    }

    // MARK: - the menu bar

    static var app: NSObject? { (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject }

    /// The Image menu as AppKit has it now: its items' titles and whether each is enabled.
    static func imageMenu() async -> NSObject? {
        UIMenuSystem.main.setNeedsRebuild()
        await pause(0.6)
        guard let main = app?.value(forKey: "mainMenu") as? NSObject, let items = main.value(forKey: "itemArray") as? [NSObject] else { return nil }
        let menu = items.first { ($0.value(forKey: "title") as? String) == L("Image") }?.value(forKey: "submenu") as? NSObject
        _ = menu?.perform(NSSelectorFromString("update"))
        return menu
    }

    struct Item { let title: String; let enabled: Bool }
    static func items(_ menu: NSObject?) -> [Item] {
        (menu?.value(forKey: "itemArray") as? [NSObject] ?? []).map {
            Item(title: ($0.value(forKey: "title") as? String) ?? "", enabled: ($0.value(forKey: "isEnabled") as? Bool) ?? false)
        }
    }

    /// The Image menu's item titled `title`, performed as a click on it performs it. False where it is not there.
    @discardableResult
    static func press(_ title: String) async -> Bool {
        guard let menu = await imageMenu() else { return false }
        let titles = items(menu).map(\.title)
        guard let i = titles.firstIndex(of: title) else { return false }
        let sel = NSSelectorFromString("performActionForItemAtIndex:")
        typealias Perform = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(menu.method(for: sel), to: Perform.self)(menu, sel, i)
        return true
    }

    // MARK: - captures

    /// The window as the display shows it, by the window server, to `<dir>/captures/<name>.png`.
    @discardableResult
    static func capture(_ name: String, out: URL) async -> String? {
        await pause(1.2)
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
              let facts = MacDisplay.windowFacts(for: window) else { return nil }
        let dir = out.appending(path: "captures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(name).png")
        guard spawn("/usr/sbin/screencapture", ["-x", "-o", "-l\(facts.number)", file.path]) == 0,
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        print("variant-acts-check: CAPTURE \(file.path)")
        return file.path
    }

    static func spawn(_ path: String, _ args: [String]) -> Int32 {
        var pid: pid_t = 0
        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { for a in argv { free(a) } }
        guard posix_spawn(&pid, path, nil, nil, argv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0xff
    }

    // MARK: - the run

    static func run(_ model: AppServices, _ r: Report, out: URL, files: [URL], c1: URL?, raw: URL?) async {
        let store = model.macLibrary
        let library = model.library
        let acts = MacVariantActions.shared
        let actions = MacLibraryActions.shared
        let fm = FileManager.default
        guard let a = files.first, let b = files.dropFirst().first else { r.check(false, "two pictures (--variant-check-files)"); return }
        await store.start()
        r.check(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil && model.defaults !== UserDefaults.standard,
                "the run's home and settings are the check's own")
        app?.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
        do {
            let work = out.appending(path: "work")
            try? fm.removeItem(at: work)
            filesRoot = work
            let card = work.appending(path: "Card")
            try fm.createDirectory(at: card, withIntermediateDirectories: true)
            for (name, from) in [("P1.jpg", a), ("P2.jpg", b), ("Q1.jpg", a), ("Q2.jpg", b), ("D1.jpg", a), ("D2.jpg", b)] {
                try fm.copyItem(at: from, to: card.appending(path: name))
            }
            let cat = try await store.newCatalog(named: "Acts", in: work)
            try await store.addFolder(card, to: cat.id)
            _ = await until(30) { store.total == 6 }
            await store.select(collection: store.tree.defaultSelection)
            _ = await until(30) { store.images.count == 6 }
            guard let p1 = cells(store, "P1.jpg").first, let p2 = cells(store, "P2.jpg").first else { r.check(false, "the pictures are listed"); return }
            // P2 opened fresh: the edit a fresh open gets. P1 given a frame and an edit with one step of history.
            let made = try await store.frames(for: [p1.id, p2.id], focus: nil).frames
            guard let f1 = made[p1.id], let f2 = made[p2.id] else { r.check(false, "frames made"); return }
            let fresh = library.frame(f2).map { unseeded($0.edit) }
            var clip = FrameEdit.default
            clip.adjustments.exposure = 0.35
            _ = model.pasteOntoLibrary(SettingsClip(groups: [.light], settings: clip, sourceName: "acts", sourceAspect: 1.5), onto: [f1])
            await model.history.drained()
            store.refreshDevelopInfo()

            // N. New Variant from the cell's menu.
            choose([p1])
            acts.perform(.new, MacVariantActions.chosen(cells(store, "P1.jpg")[0], rows: store.images), model: model)
            _ = await until(20) { cells(store, "P1.jpg").count == 2 && !acts.busy }
            var p = cells(store, "P1.jpg")
            let newCell = p.last
            let newFrame = newCell?.develop?.frameID
            let browser = MacLibraryBrowser.shared
            r.note("N. New Variant from the cell's menu", ["cells": p.map { "\($0.variantNumber)/\($0.variantCount)" },
                                                          "selection": browser.selection.count, "focus_is_new": browser.focus == newCell?.id])
            r.check(p.count == 2 && p.map(\.variantNumber) == [1, 2] && store.total == 6, "N: a new cell after the image's other, 2 / 2; still 6 images")
            r.check(browser.selection == Set([newCell?.id].compactMap { $0 }) && browser.focus == newCell?.id, "N: the new cell is chosen and in focus")
            if let newFrame {
                let n = await steps(model, newFrame)
                r.check(library.frame(newFrame).map { unseeded($0.edit) } == fresh && n == 0,
                        "N: its edit is the one a fresh open gets, not P1's (\(library.frame(newFrame)?.edit.adjustments.exposure ?? .nan)), and its history is empty (\(n))")
            } else { r.check(false, "N: the new cell has a frame") }

            // C. Clone Variant from the Image menu, on P1's first cell.
            choose([p[0]])
            let menuOK = await press(L("Clone Variant"))
            _ = await until(20) { cells(store, "P1.jpg").count == 3 && !acts.busy }
            p = cells(store, "P1.jpg")
            let cloneFrame = p.last?.develop?.frameID
            r.check(menuOK, "C: the Image menu holds Clone Variant (\(items(await imageMenu()).map(\.title)))")
            r.check(p.count == 3 && browser.focus == p.last?.id, "C: a third cell, chosen (\(p.count))")
            if let cloneFrame {
                let n = await steps(model, cloneFrame)
                r.check(library.frame(cloneFrame)?.edit == library.frame(f1)?.edit && n == 0,
                        "C: an equal edit (\(library.frame(cloneFrame)?.edit.adjustments.exposure ?? .nan)), and an empty history (\(n))")
                let asked = await until(30) { library.frame(cloneFrame).map { $0.develop.isBusy || $0.shownDevelop != nil } ?? false }
                r.check(asked, "C: its preview is asked at once")
            } else { r.check(false, "C: the clone has a frame") }

            // G. Greyed, with the reason.
            choose([cells(store, "P2.jpg")[0]])
            let single = items(await imageMenu())
            r.note("G. the Image menu on a picture with one variant", ["items": single.map { "\($0.title) \($0.enabled ? "on" : "greyed")" }])
            r.check(single.first { $0.title == L("New Variant") }?.enabled == true && single.first { $0.title == L("Delete Variant") }?.enabled == false
                    && single.contains { $0.title == L("This is the picture's only variant.") },
                    "G: one variant: New on, Delete greyed with its reason under it")
            actions.refusal = nil
            acts.perform(.delete, [cells(store, "P2.jpg")[0]], model: model)
            r.check(actions.refusal == L("This is the picture's only variant.") && !acts.confirmingDelete, "D: the last variant is refused, with the reason (\(actions.refusal ?? "-"))")
            actions.refusal = nil
            // A pair and a double, made as the Combine menu makes them.
            actions.makePair([cells(store, "Q1.jpg")[0], cells(store, "Q2.jpg")[0]], store: store, model: model)
            _ = await until(20) { store.images.contains { $0.kind == .pair } }
            await store.select(collection: store.tree.defaultSelection)
            _ = await until(20) { store.images.contains { $0.kind == .pair } }
            actions.makeDouble([cells(store, "D1.jpg")[0], cells(store, "D2.jpg")[0]], store: store, model: model)
            _ = await until(20) { store.images.contains { $0.develop.flatMap { library.frame($0.frameID)?.isDouble } == true } }
            await store.select(collection: store.tree.defaultSelection)
            _ = await until(20) { store.images.contains { $0.develop.flatMap { library.frame($0.frameID)?.isDouble } == true } }
            let why = L("Pairs and double exposures do not have variants yet.")
            for (what, row) in [("pair", store.images.first { $0.kind == .pair }),
                                ("double", store.images.first { $0.develop.flatMap { library.frame($0.frameID)?.isDouble } == true })] {
                guard let row else { r.check(false, "G: a \(what) is listed"); continue }
                choose([row])
                let shown = items(await imageMenu())
                r.note("G. the Image menu on a \(what)", ["items": shown.map { "\($0.title) \($0.enabled ? "on" : "greyed")" }])
                r.check(shown.first { $0.title == L("New Variant") }?.enabled == false && shown.first { $0.title == L("Clone Variant") }?.enabled == false
                        && shown.contains { $0.title == why }, "G: a \(what): New and Clone greyed, the reason under them, not hidden")
                let before = store.images.count
                acts.perform(.new, MacVariantActions.chosen(row, rows: store.images), model: model)
                await pause(0.5)
                r.check(actions.refusal == why && store.images.count == before, "G: a \(what): its menu's New is refused with the reason, nothing made")
                actions.refusal = nil
                if what == "pair" { await capture("greyed-pair-window-en", out: out) }
            }

            // K. With `--variant-acts-keys <s>`: F2 and F3 pressed for real — `tools/variant_check.sh --keys` posts the two
            // key events to this process (`CGEvent.postToPid`) when it reads READY — on a picture with one variant.
            if let i = CommandLine.arguments.firstIndex(of: "--variant-acts-keys"), i + 1 < CommandLine.arguments.count,
               let hold = Double(CommandLine.arguments[i + 1]) {
                model.router.toLibrary()
                await store.select(collection: store.tree.defaultSelection)
                _ = await until(10) { !cells(store, "P2.jpg").isEmpty }
                choose([cells(store, "P2.jpg")[0]])
                MacKeyFocus.shared.takeKeys()
                app?.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
                await pause(1)
                print("variant-acts-check: KEYS READY \(ProcessInfo.processInfo.processIdentifier)")
                fflush(stdout)   // the script reads this line from the log: printed late, the keys come after the hold
                let got = await until(hold) { cells(store, "P2.jpg").count >= 3 && !acts.busy }
                let active = (app?.value(forKey: "isActive") as? Bool) ?? false
                // A key that arrives late (the window made key after the hold) must not act on what the steps below choose.
                let k = cells(store, "P2.jpg")
                let cloned = k.count == 3 ? k.last?.develop.flatMap { library.frame($0.frameID)?.edit } : nil
                r.note("K. F2 and F3 pressed", ["cells": k.count, "focus_is_last": MacLibraryBrowser.shared.focus == k.last?.id, "app_active": active,
                                                  "refusal": actions.refusal ?? "-", "selection": MacLibraryBrowser.shared.selection.count,
                                                  "menu_cells": MacVariantActions.menuCells(model).map(\.fileName), "path": "\(model.router.path)"])
                r.check(got && k.count == 3, "K: F2 then F3, as keys, made a new and a cloned variant of P2 (\(k.count) cells)")
                r.check(cloned != nil, "K: the third is F3's clone of the second, with a frame")
            }

            // X. Export: an image's three variants, by their numbers.
            p = cells(store, "P1.jpg")
            let recipe = ExportRecipe(format: .jpeg, size: .longEdge(600), colour: .sRGB, destination: .files)
            let folderAll = work.appending(path: "ExportAll"), folderThird = work.appending(path: "ExportThird")
            let run = MacExportRun.shared
            let frames3 = p.compactMap { $0.develop?.frameID }
            r.check(run.start(frames3, recipe: recipe, folder: folderAll, exporter: model.exporter), "X: the batch begins")
            _ = await until(120) { !run.isRunning }
            r.check(run.start([frames3[2]], recipe: recipe, folder: folderThird, exporter: model.exporter), "X: the third alone begins")
            _ = await until(120) { !run.isRunning }
            let names = ((try? fm.contentsOfDirectory(atPath: folderAll.path)) ?? []).sorted()
            let third = (try? fm.contentsOfDirectory(atPath: folderThird.path)) ?? []
            r.note("X. export", ["all": names, "third_alone": third])
            r.check(names == ["P1-2.jpg", "P1-3.jpg", "P1.jpg"], "X: P1's variants export as P1.jpg, P1-2.jpg, P1-3.jpg (\(names))")
            r.check(third == ["P1-3.jpg"], "X: the third alone is still P1-3.jpg, by its number, not by a clash (\(third))")

            // E. Delete while an export batch holds the variant (trap 34): refused with its reason, greyed in the Image menu,
            // nothing removed; offered again once the batch has ended. The batch is every photograph's frame at full size
            // in TIFF, the variant last, so that it is still under way while the acts are tried.
            if let held = p.last, let heldFrame = held.develop?.frameID {
                let others = store.images.compactMap { $0.develop?.frameID }.filter { $0 != heldFrame && library.frame($0)?.isComposite == false }
                let long = ExportRecipe(format: .tiff, size: .full, colour: .proPhoto, destination: .files)
                choose([held])
                let begun = run.start(others + others + [heldFrame], recipe: long, folder: work.appending(path: "ExportHeld"), exporter: model.exporter)
                actions.refusal = nil
                acts.perform(.delete, [held], model: model)
                let refusedWhile = actions.refusal, askedWhile = acts.confirmingDelete
                let menuWhile = items(await imageMenu())
                let stillRunning = model.exporter.isExporting
                actions.refusal = nil
                let why = L("This variant is being exported. Delete it when the export is done.")
                r.note("E. Delete while a batch holds the variant", ["begun": begun, "refusal": refusedWhile ?? "-", "asked": askedWhile,
                                                                    "menu": menuWhile.map { "\($0.title) \($0.enabled ? "on" : "greyed")" },
                                                                    "still_exporting_at_menu": stillRunning])
                r.check(begun && refusedWhile == why && !askedWhile && library.frame(heldFrame) != nil && cells(store, "P1.jpg").count == 3,
                        "E: while a batch holds the variant, Delete is refused with its reason and nothing is removed (\(refusedWhile ?? "-"))")
                r.check(!stillRunning || (menuWhile.first { $0.title == L("Delete Variant") }?.enabled == false && menuWhile.contains { $0.title == why }),
                        "E: the Image menu's Delete is greyed with the reason while the batch runs (\(stillRunning ? "read under way" : "the batch had ended"))")
                _ = await until(300) { !run.isRunning && !model.exporter.isExporting }
                let menuAfter = items(await imageMenu())
                acts.perform(.delete, [held], model: model)
                let askedAfter = await until(5) { acts.confirmingDelete }
                acts.confirmingDelete = false
                acts.cancelDelete()
                r.check(askedAfter && menuAfter.first { $0.title == L("Delete Variant") }?.enabled == true && library.frame(heldFrame) != nil,
                        "E: once the batch has ended, Delete is offered again (asked, not done: cancelled here)")
            } else { r.check(false, "E: P1's third variant has a frame") }

            // P. Paste onto one variant; a rating on one.
            clip.adjustments.exposure = 0.8
            library.clipboard = SettingsClip(groups: [.light], settings: clip, sourceName: "acts", sourceAspect: 1.5)
            actions.pasteSettings(onto: [p[1]], store: store, model: model)
            await actions.pastesLanded()
            let exposures = cells(store, "P1.jpg").map { $0.develop.flatMap { library.frame($0.frameID)?.edit.adjustments.exposure } ?? .nan }
            r.check(exposures == [0.35, 0.8, 0.35], "P: Paste Settings onto variant 2 leaves 1 and 3 alone (\(exposures))")
            try await store.setRating(3, for: [cells(store, "P1.jpg")[2].id])
            let ratings = cells(store, "P1.jpg").map(\.rating)
            r.check(ratings == [0, 0, 3], "P: a rating on variant 3 is that cell's (\(ratings))")

            // Captures: the grid with a three-variant image (default cell, and the smallest), Info's line.
            choose([cells(store, "P1.jpg")[1]])
            browser.navigator = .info
            browser.fullGrid = true
            for lang in [AppLanguage.english, .simplified] {
                Language.shared.choose(lang)
                let tag = lang == .english ? "en" : "zh-Hans"
                browser.cell = MacMetric.cellDefault
                await capture("grid-variants-\(tag)", out: out)
                browser.cell = MacMetric.cellRange.lowerBound
                await capture("grid-variants-smallest-\(tag)", out: out)
            }
            Language.shared.choose(.english)
            browser.cell = MacMetric.cellDefault
            browser.fullGrid = false
            // The cell's own menu, presented as a right click presents it, for the script to capture (`--context-menu`).
            if CommandLine.arguments.contains("--variant-acts-context-menu") {
                for lang in [AppLanguage.english, .simplified] {
                    Language.shared.choose(lang)
                    await contextMenu(on: cells(store, "P1.jpg")[1], named: "context-menu-variant-\(lang == .english ? "en" : "zh-Hans")", r)
                    if let pair = store.images.first(where: { $0.kind == .pair }) {
                        await contextMenu(on: pair, named: "context-menu-pair-\(lang == .english ? "en" : "zh-Hans")", r)
                    }
                }
                Language.shared.choose(.english)
            }

            // D. In Develop: New from the Image menu opens it; Delete of the open variant moves to its neighbour.
            p = cells(store, "P1.jpg")
            MacLibraryGo.open(p[0], model: model)
            let opened = await until(20) { MacShellBar.shared.develop?.frameID == f1 && model.openSession(f1) != nil }
            r.check(opened, "D: P1's first variant opens in Develop")
            await pause(1)
            choose([cells(store, "P1.jpg")[0]])
            let pressed = await press(L("New Variant"))
            _ = await until(20) { cells(store, "P1.jpg").count == 4 && !acts.busy }
            p = cells(store, "P1.jpg")
            let fourth = p.last?.develop?.frameID
            let onPage = await until(20) { fourth != nil && MacShellBar.shared.develop?.frameID == fourth }
            r.check(pressed && p.count == 4 && onPage, "D: New Variant from the Image menu in Develop opens the new variant on the page")
            for lang in [AppLanguage.english, .simplified] {
                Language.shared.choose(lang)
                await capture("develop-browser-variants-\(lang == .english ? "en" : "zh-Hans")", out: out)
            }
            Language.shared.choose(.english)
            if let fourth {
                paste(model, 0.2, fourth)
                await model.history.drained()
                // A kept develop to lose, as a clone's or a paste's preview is made (the page's canvas keeps none).
                model.develop(fourth)
                _ = await until(60) { library.frame(fourth).map { !$0.develop.isBusy && $0.developed != nil } ?? false }
                let developFile = library.frame(fourth)?.developed?.picture.fileURL
                let developHad = developFile.map { fm.fileExists(atPath: $0.path) } ?? false
                let before = filesNaming(fourth)
                let had = await steps(model, fourth)
                let pressedDelete = await press(L("Delete Variant"))
                let asked = await until(5) { acts.confirmingDelete }
                r.check(pressedDelete && asked && acts.deleteTitle == L("Delete variant \(4) of \(4) of \("P1.jpg")?"),
                        "D: Delete Variant asks first (\(acts.deleteTitle))")
                await capture("delete-question-en", out: out)
                acts.confirmingDelete = false
                acts.delete(model: model)
                _ = await until(20) { library.frame(fourth) == nil && !acts.busy }
                await model.history.drained()
                await pause(1)
                let after = filesNaming(fourth)
                let left = await steps(model, fourth)
                p = cells(store, "P1.jpg")
                r.note("D. Delete Variant of the variant open", ["files_before": before.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") },
                                                                  "files_after": after, "history_before": had, "cells": p.count,
                                                                  "page": MacShellBar.shared.develop?.frameID.uuidString ?? "-"])
                r.check(developHad && before.contains { $0.hasSuffix(developFile?.lastPathComponent ?? "-") } && after.isEmpty
                        && developFile.map { !fm.fileExists(atPath: $0.path) } == true,
                        "D: before, its develop (\(developFile?.path ?? "none")) and \(before.count) files of the app's named the frame; after, none")
                r.check(library.frame(fourth) == nil && had >= 1 && left == 0, "D: the frame and its history (\(had) steps) are gone")
                r.check(fm.fileExists(atPath: card.appending(path: "P1.jpg").path), "D: the file stays")
                r.check(p.count == 3 && MacShellBar.shared.develop?.frameID == p.last?.develop?.frameID && p.last?.develop?.frameID != nil,
                        "D: the page moved to the neighbouring variant, the third (\(p.count) cells)")
            }
            model.router.toLibrary()
            _ = await until(10) { MacShellPath.develop(model.router.path) == nil }

            // R. Two variants of one RAW: one proxy, the second's first open a proxy read.
            if let raw { await rawProxy(model, r, raw: raw, work: work, cat: cat) }

            // L. Paging with multi-variant images, and the Light Table.
            await store.select(source: cat.id)
            await store.select(collection: store.tree.defaultSelection)
            _ = await until(20) { !store.hasMore && !store.images.isEmpty }
            let all = store.images.map(\.id)
            store.pageSize = 2
            await store.reload()
            let first = (store.images.count, store.loadedImageCount, store.hasMore)
            var pages = 1
            var trail: [String] = ["\(store.loadedImageCount): " + store.images.map(\.fileName).joined(separator: ",")]
            while store.hasMore, pages < 20 {
                await store.loadMore(); pages += 1
                trail.append("\(store.loadedImageCount): " + store.images.map(\.fileName).joined(separator: ","))
            }
            let paged = store.images.map(\.id)
            store.pageSize = 1000
            let adjacent = Dictionary(grouping: store.images.indices, by: { store.images[$0].id.image }).values.allSatisfy { i in
                i.max()! - i.min()! == i.count - 1 && i.map { store.images[$0].variantNumber } == Array(1...i.count)
            }
            r.note("L. paging at two images a page", ["first_page": [first.0, first.1], "pages": pages, "cells": paged.count, "images": store.total,
                                                      "all_cells": all.count, "same_set": Set(paged) == Set(all), "adjacent": adjacent,
                                                      "has_more": store.hasMore, "loaded_images": store.loadedImageCount, "trail": trail,
                                                      "all": all.map { "\($0.image.prefix(6))/\($0.variant?.prefix(4) ?? "-")" },
                                                      "order": store.images.map { "\($0.fileName) \($0.variantNumber)/\($0.variantCount)" }])
            r.check(first.1 == 2 && first.2 && Set(paged) == Set(all) && paged.count == all.count && !store.hasMore && adjacent,
                    "L: two images a page, every cell once, an image's cells together and numbered (\(pages) pages, \(paged.count) cells)")
            p = cells(store, "P1.jpg")
            for c in p.prefix(2) { if let f = c.develop?.frameID { library.update(f) { $0.edit.filmEdge.active = true } } }
            try await store.putOnLightTable(p.prefix(2).map(\.id))
            let carried = MacLightTableCarry.shared.frames
            r.check(Set(carried) == Set(p.prefix(2).compactMap { $0.develop?.frameID }) && Set(carried).count == 2 && model.router.path.last == .lightTable,
                    "L: two variant cells lay their own two frames on the Light Table (\(carried.count))")
            await pause(1.5)
            model.router.toLibrary()
            await pause(1)

            // D. One of Capture One's variants: refused, with the reason.
            if let c1 { await captureOne(model, r, c1: c1) }
        } catch {
            r.check(false, "ran without an error: \(error.localizedDescription)")
        }
    }

    /// The context menu of `cell` (its grid cell's `UIContextMenuInteraction`, presented at the cell's middle through
    /// UIKit's own `_presentMenuAtLocation:`, as a right click does), held while the script captures the screen's windows
    /// of this process (`MENU OPEN`), then dismissed.
    static func contextMenu(on cell: MacImage, named name: String, _ r: Report) async {
        choose([cell])
        MacLibraryBrowser.shared.scrollTarget = cell.id
        await pause(1)
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first else { return }
        // The cell's frame in the window, as the grid laid it out (`MacCellFrameProbe`, recorded under this check's flag).
        let found = MacCellFrameProbe.frames[cell.id].map { [$0] } ?? []
        let ordered = found
        let index = 0
        // The grid's cells' menus are the hosting view's one interaction, at the point pressed.
        func holder(_ v: UIView) -> UIView? {
            if v.interactions.contains(where: { $0 is UIContextMenuInteraction }), v.bounds.width >= window.bounds.width * 0.9 { return v }
            for s in v.subviews { if let h = holder(s) { return h } }
            return nil
        }
        let host = holder(window)
        guard let host, let menu = host.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first,
              ordered.indices.contains(index) else {
            r.note("context menu: no cell or no interaction", ["cells": found.count]); return
        }
        let view = host
        let at = host.convert(CGPoint(x: ordered[index].midX, y: ordered[index].midY), from: window)
        let sel = NSSelectorFromString("_presentMenuAtLocation:")
        guard menu.responds(to: sel) else { r.note("context menu: UIKit has no _presentMenuAtLocation:"); return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let present = unsafeBitCast(menu.method(for: sel), to: Present.self)
        Task { @MainActor in
            await pause(1.5)
            print("variant-acts-check: MENU OPEN \(ProcessInfo.processInfo.processIdentifier) \(name)")
            fflush(stdout)
            await pause(4)
            menu.dismissMenu()
        }
        present(menu, sel, at)
        await pause(6.5)
        r.note("context menu: \(name)", ["presented_on": String(describing: type(of: view)), "at": "\(at)", "cells_found": found.count])
    }

    static func paste(_ model: AppServices, _ exposure: Double, _ id: UUID) {
        var s = FrameEdit.default
        s.adjustments.exposure = exposure
        _ = model.pasteOntoLibrary(SettingsClip(groups: [.light], settings: s, sourceName: "acts", sourceAspect: 1.5), onto: [id])
    }

    static func rawProxy(_ model: AppServices, _ r: Report, raw: URL, work: URL, cat: MacSource) async {
        let store = model.macLibrary
        let library = model.library
        let fm = FileManager.default
        do {
            let card = work.appending(path: "Raw")
            try fm.createDirectory(at: card, withIntermediateDirectories: true)
            let name = "R." + raw.pathExtension
            try fm.copyItem(at: raw, to: card.appending(path: name))
            await store.select(source: cat.id)
            try await store.addFolder(card, to: cat.id)
            await store.select(collection: store.tree.defaultSelection)
            _ = await until(30) { !cells(store, name).isEmpty }
            guard let one = cells(store, name).first else { r.check(false, "R: the RAW is listed"); return }
            choose([one])
            MacVariantActions.shared.perform(.new, [one], model: model)
            _ = await until(30) { cells(store, name).count == 2 && !MacVariantActions.shared.busy }
            let two = cells(store, name)
            let frames = try await store.frames(for: two.map(\.id), focus: nil).frames
            guard two.count == 2, let v1 = frames[two[0].id], let v2 = frames[two[1].id] else { r.check(false, "R: two variants of the RAW"); return }
            guard let folder = model.originals.copies.proxyFolder else { r.check(false, "R: a proxy folder"); return }
            func proxies() -> [String] { ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".spkraw") } }
            let before = proxies()
            // The first variant opened: its first open decodes the RAW and keeps the proxy.
            MacLibraryGo.open(cells(store, name)[0], model: model)
            _ = await until(60) { MacShellBar.shared.develop?.frameID == v1 && (model.openSession(v1)?.developedCGImage != nil) }
            _ = await until(30) { proxies().count > before.count }
            await pause(2)
            let afterFirst = proxies()
            let decodes2 = library.frame(v2).map { model.darkroom.decodesRAW($0, edit: $0.edit) }
            // The second opened on the page: its first develop's job, as the scheduler has it.
            var seen: Bool?
            MacShellBar.shared.develop?.open(v2)
            let end = Date().addingTimeInterval(30)
            while Date() < end {
                if let j = model.scheduler.snapshots.first(where: { $0.job.frameID == v2 && $0.job.decodesOriginal })?.job { seen = j.rawDecode; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            _ = await until(60) { model.openSession(v2)?.developedCGImage != nil }
            await pause(1)
            let afterSecond = proxies()
            r.note("R. two variants of one RAW", ["proxies_before": before.count, "after_first_open": afterFirst, "after_second_open": afterSecond,
                                                  "second_decodes_raw_predicted": decodes2 ?? true, "second_job_rawDecode": seen.map { "\($0)" } ?? "no job seen"])
            r.check(afterFirst.count == before.count + 1, "R: the first variant's open keeps one proxy (\(afterFirst.count - before.count))")
            r.check(afterSecond == afterFirst, "R: the second's open makes none: one proxy file for both (\(afterSecond.count))")
            r.check(decodes2 == false && seen == false, "R: the second's first open is a proxy read, not a RAW decode (rawDecode \(seen.map { "\($0)" } ?? "unseen"))")
            model.router.toLibrary()
            _ = await until(10) { MacShellPath.develop(model.router.path) == nil }
        } catch {
            r.check(false, "R: \(error.localizedDescription)")
        }
    }

    static func captureOne(_ model: AppServices, _ r: Report, c1: URL) async {
        let store = model.macLibrary
        let acts = MacVariantActions.shared
        let actions = MacLibraryActions.shared
        do {
            _ = try await store.open(c1)
            await store.select(collection: store.tree.defaultSelection)
            _ = await until(30) { cells(store, "A.jpg").count == 2 }
            guard let theirs = cells(store, "A.jpg").last else { r.check(false, "D: Capture One's two-variant image is listed"); return }
            choose([theirs])
            acts.perform(.delete, [theirs], model: model)
            let asked = await until(5) { acts.confirmingDelete }
            acts.confirmingDelete = false
            actions.refusal = nil
            acts.delete(model: model)
            _ = await until(10) { actions.refusal != nil && !acts.busy }
            let want = L("This variant is Capture One's own. Delete it in Capture One: SpektraLab never changes a Capture One catalog.")
            r.check(asked && actions.refusal == want && cells(store, "A.jpg").count == 2,
                    "D: one of Capture One's variants is refused with the reason (\(actions.refusal ?? "-"))")
            actions.refusal = nil
        } catch {
            r.check(false, "D: Capture One: \(error.localizedDescription)")
        }
    }
}
/// Each grid cell's frame in the window, recorded only in a run of this check with `--variant-acts-context-menu`: where a
/// right click on the cell lands, for presenting its menu.
struct MacCellFrameProbe: ViewModifier {
    let id: MacImage.ID
    static let recording = CommandLine.arguments.contains("--variant-acts-context-menu")
    @MainActor static var frames: [MacImage.ID: CGRect] = [:]

    func body(content: Content) -> some View {
        if Self.recording {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { f in Self.frames[id] = f }
        } else {
            content
        }
    }
}
#endif
