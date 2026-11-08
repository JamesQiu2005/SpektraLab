//  MacClipboardCheck.swift — a debug build's proof of Copy and Paste Settings, in the running app.
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --clipboard-check <dir> \
//          --clipboard-check-files <upright.jpg> <wide.jpg> <wide.jpg> <upright.jpg> \
//          [--clipboard-check-many <n>] [--library-check-exit]
//
//  The owner, 2026-11-05: ⌘C copies the settings, ⌘V pastes them onto every chosen picture, in 图库, 冲洗
//  and 编辑; a film edge copied from an upright picture must not come out upright on a wide one. Through
//  the window's own way in — the Edit menu's Copy and Paste, which ⌘C and ⌘V press (`MacEditCommands.edit`),
//  reaching the shell's registrations — and writes `<dir>/report.json`:
//
//  1. a scratch SpektraLab catalog of the four files (copied first: a develop writes a sidecar), none of
//     them ever opened;
//  2. the first (upright) given a frame and a 135 film edge lying down it, chosen, ⌘C: the clipboard holds
//     the groups last ticked on the sheet;
//  3. the second and third (wide, no frame) chosen, ⌘V: a frame is made for each, the film runs across;
//  4. the fourth (upright) opened in 冲洗, the second's settings copied in 图库 first: ⌘V reaches the open
//     page's session (Undo can take it back) and the film runs down it;
//  5. while a field is being edited Edit's Copy and Paste are not the settings';
//  6. two more wide pictures, never opened, pasted onto twice at once (⌘V again while the first paste
//     makes their frames): one frame each, not two (the review, 2026-11-05);
//  7. what a paste onto pictures not open says (`MacLibraryActions.notice`), that each one's preview is
//     developed again of the pasted edit with nothing opened, and none for the frame open in 冲洗 (2026-11-05),
//     and that ⌘C in 冲洗 copies the page's settings with the picture's shape;
//  8. selectable text (Info's rows, `.textSelection(.enabled)`): what Catalyst makes of it, and that with
//     it first and nothing selected ⌘C is still Copy Settings;
//  9. with `--clipboard-check-many <n>`: n more never-opened pictures (copies of the first wide one) all
//     chosen and pasted onto at once — above `CatalogSourcesStore.carryLimit` every one of them gets its frame,
//     every one's preview is queued, the main thread's lag is measured while they are fed to the queue and
//     while they develop, and Stop takes them all out.
//
//  Not in a release build.

#if DEBUG
import UIKit

@MainActor
enum MacClipboardCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--clipboard-check"), i + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let files = arguments.firstIndex(of: "--clipboard-check-files").map { arguments[($0 + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) } } ?? []
        let exits = arguments.contains("--library-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let r = Report()
            await run(model, r, out: out, files: files)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let report: [String: Any] = ["steps": r.steps, "failures": r.failures, "passed": r.failures.isEmpty, "home": NSHomeDirectory()]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("clipboard-check: wrote \(out.appending(path: "report.json").path), \(r.failures.count) failures")
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
            print("clipboard-check: \(name) \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); print("clipboard-check: FAIL \(what)") }
        }
    }

    /// Edit's Copy or Paste, as its menu item does it (and ⌘C, ⌘V, which press it).
    private static func send(_ action: Selector) -> Bool { MacEditCommands.edit(action) }

    /// Each responder from the first, and what it says to `action`: where an Edit action goes, or stops.
    private static func chain(_ action: Selector) -> [String] {
        var out: [String] = []
        var r = UIResponder.spkFirstResponder
        while let x = r, out.count < 40 {
            out.append("\(String(reflecting: type(of: x)).prefix(90)) can=\(x.canPerformAction(action, withSender: nil)) target=\(x.target(forAction: action, withSender: nil).map { "\(type(of: $0))" } ?? "nil")")
            r = x.next
        }
        if let d = UIApplication.shared.delegate { out.append("delegate \(String(reflecting: type(of: d))) ours=\(d is AppDelegate) can=\((d as? UIResponder)?.canPerformAction(action, withSender: nil) ?? false)") }
        return out
    }

    private static func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
        return done()
    }

    private static func arguments(after flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// Views that may hold selectable text: text views and fields, and anything with a text interaction.
    private static func selectable(in view: UIView, into out: inout [UIView]) {
        let name = String(describing: type(of: view))
        let texty = view.interactions.contains { i in
            let n = String(describing: type(of: i))
            return n.contains("TextInteraction") || n.contains("TextSelection") || n.contains("EditMenu")
        }
        if view is UITextView || view is UITextField || texty || (name.contains("Text") && !(view is UILabel) && view.canBecomeFirstResponder) {
            out.append(view)
        }
        for v in view.subviews { selectable(in: v, into: &out) }
    }

    private static func describe(_ v: UIView) -> String {
        "\(String(reflecting: type(of: v)).prefix(80)) first=\(v.canBecomeFirstResponder) copy=\(v.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil)) "
            + "interactions=\(v.interactions.map { String(describing: type(of: $0)) }) text=\(((v as? UITextView)?.text ?? "").prefix(30))"
    }

    private static func choose(_ rows: [MacImage]) {
        let browser = MacLibraryBrowser.shared
        browser.selection = Set(rows.map(\.id))
        browser.focus = rows.first?.id
    }

    private static func run(_ model: AppServices, _ r: Report, out: URL, files: [URL]) async {
        let store = model.macLibrary
        let library = model.library
        let fm = FileManager.default
        guard files.count == 4 else { r.check(false, "four files: upright, wide, wide, upright (\(files.count))"); return }
        await store.start()
        do {
            // 1. A catalog of four pictures nobody has opened.
            let work = out.appending(path: "work")
            try? fm.removeItem(at: work)
            let card = work.appending(path: "Card")
            try fm.createDirectory(at: card, withIntermediateDirectories: true)
            let names = files.enumerated().map { "\($0.offset + 1)-\($0.element.lastPathComponent)" }
            for (u, n) in zip(files, names) { try fm.copyItem(at: u, to: card.appending(path: n)) }
            // Two more wide ones for the overlapping pastes (6.), and the many (9.), in a folder of their own.
            let extra = ["5-\(files[1].lastPathComponent)", "6-\(files[1].lastPathComponent)"]
            for n in extra { try fm.copyItem(at: files[1], to: card.appending(path: n)) }
            let many = arguments(after: "--clipboard-check-many").flatMap(Int.init) ?? 0
            let manyNames = (0..<many).map { String(format: "m%04d-%@", $0, files[1].lastPathComponent) }
            for n in manyNames { try fm.copyItem(at: files[1], to: card.appending(path: n)) }
            let cat = try await store.newCatalog(named: "Clipboard", in: work)
            try await store.addFolder(card, to: cat.id)
            let all = 6 + many
            _ = await wait(60 + Double(many) / 10) { store.images.count == all }
            await store.select(collection: store.tree.defaultSelection)
            _ = await wait(30) { store.images.count == all }
            let rows = names.compactMap { n in store.images.first { $0.fileName == n } }
            r.note("catalog", ["rows": rows.map(\.fileName), "framed": rows.filter { $0.develop != nil }.count, "listed": store.images.count])
            r.check(rows.count == 4 && rows.allSatisfy { $0.develop == nil }, "four pictures, none with a frame")
            guard rows.count == 4 else { return }
            let (upright, wide, wide2, upright2) = (rows[0], rows[1], rows[2], rows[3])

            // 2. The upright one: a 135 film edge lying down it, then ⌘C.
            ClipboardGroup.remember([.filmEdgeAndDateBack, .filmAndPaper])
            let made = try await store.frames(for: [upright.id], focus: upright.id).frames
            guard let source = made[upright.id], let frame = library.frame(source) else { r.check(false, "the upright picture has a frame"); return }
            library.update(source) { f in
                f.edit.filmEdge.active = true
                f.edit.filmEdge.format = .f135
                f.edit.filmEdge.turn = FilmEdgeFormat.f135.defaultTurn(pictureAspect: f.originalSize.aspect)
                f.edit.filmEdge.cameraSeed = 5
            }
            library.clipboard = nil
            choose([store.images.first { $0.id == upright.id } ?? upright])
            await settle()
            let responder = UIResponder.spkFirstResponder.map { String(describing: type(of: $0)) } ?? "none"
            let copied = send(#selector(UIResponder.copy(_:)))
            r.note("⌘C on the upright picture", ["first_responder": responder, "sent": copied, "size": "\(frame.originalSize.width)x\(frame.originalSize.height)",
                                                "turn": library.frame(source)?.edit.filmEdge.turn ?? -1,
                                                "clip_groups": library.clipboard.map { $0.groups.map(\.rawValue).sorted() } ?? []])
            r.check(copied && library.clipboard?.groups == [.filmEdgeAndDateBack, .filmAndPaper], "⌘C copies with the groups last ticked, no sheet")
            r.check(model.router.sheets.isEmpty, "⌘C opens no sheet")
            r.check(library.clipboard?.settings.filmEdge.turn == 1, "the copied film lies down the upright picture")
            r.check(abs((library.clipboard?.sourceAspect ?? 0) - frame.originalSize.aspect) < 1e-9,
                    "the clip keeps the upright picture's shape (\(library.clipboard?.sourceAspect ?? -1))")

            // 3. Two wide pictures that have never been opened: ⌘V.
            choose([wide, wide2])
            await settle()
            let pasted = send(#selector(UIResponder.paste(_:)))
            _ = await wait(15) { store.images.filter { [wide.id, wide2.id].contains($0.id) }.allSatisfy { $0.develop != nil } }
            await settle()
            let targets = try await store.frames(for: [wide.id, wide2.id], focus: nil).frames
            let edges = [wide, wide2].compactMap { targets[$0.id].flatMap { library.frame($0)?.edit.filmEdge } }
            r.note("⌘V on two wide pictures with no frame", ["sent": pasted, "frames": targets.count,
                                                             "turns": edges.map(\.turn), "active": edges.map(\.active),
                                                             "seeds": edges.map(\.cameraSeed),
                                                             "sizes": [wide, wide2].compactMap { targets[$0.id].flatMap { library.frame($0)?.originalSize }.map { "\($0.width)x\($0.height)" } }])
            r.check(pasted && targets.count == 2, "a frame is made for each picture never opened")
            r.check(edges.count == 2 && edges.allSatisfy { $0.active && $0.format == .f135 && $0.turn == 0 },
                    "the pasted film runs across the wide pictures (turns \(edges.map(\.turn)))")
            r.check(library.frame(source)?.edit.filmEdge.turn == 1, "the source keeps its own")
            // 7. What it says, and what it does (2026-11-05, the owner: a paste that left the old preview until
            // a picture was opened "would make user wonder what is actually happening"): two frames pasted
            // outside any page, each with its preview developed again, of the pasted edit.
            let notice = MacLibraryActions.shared.notice
            r.note("the notice after the paste", ["said": notice?.said ?? "-", "more": notice?.more ?? "-"])
            r.check(notice?.said == L("Settings pasted onto \(2) pictures."), "the paste says how many it reached (\(notice?.said ?? "nothing"))")
            r.check(notice?.more == L("Their previews are developing."), "and that their previews are developing (\(notice?.more ?? "nothing"))")
            let pastedFrames = Array(targets.values)
            let fresh = await wait(60) { pastedFrames.allSatisfy { id in library.frame(id).map { !$0.develop.isBusy && !model.darkroom.needsDevelop($0) } ?? false } }
            r.note("the pasted frames' previews", ["fresh": fresh,
                                                  "states": pastedFrames.map { library.frame($0).map { "\($0.develop)" } ?? "-" },
                                                  "kept": pastedFrames.map { library.frame($0)?.developed?.stamp.prefix(12).description ?? "none" }])
            r.check(fresh, "each pasted frame's preview is developed again, of the pasted edit, with nothing opened")
            library.flush()
            let saved = (try? Data(contentsOf: LibraryPersistence().url))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            r.check(targets.values.allSatisfy { saved.contains($0.uuidString) }, "the pasted frames are in the saved library")

            // 4. 冲洗 on the second upright one, the wide one's settings copied first in 图库.
            choose([store.images.first { $0.id == wide.id } ?? wide])
            await settle()
            _ = send(#selector(UIResponder.copy(_:)))
            r.check(library.clipboard?.settings.filmEdge.turn == 0, "copied from the wide picture: across")
            try await store.openInDevelop([upright2.id], focus: upright2.id)
            let opened = await wait(20) { MacShellBar.shared.develop.flatMap { model.openSession($0.frameID) } != nil }
            guard opened, let bar = MacShellBar.shared.develop, let session = model.openSession(bar.frameID) else {
                r.check(false, "the second upright picture opens in 冲洗"); return
            }
            await settle(1.5)
            let undoBefore = session.canUndo
            r.note("the chain for paste: in 冲洗", ["chain": chain(#selector(UIResponder.paste(_:))),
                                                   "registry": MacShortcutRegistry.shared.canPerformStandard(#selector(UIResponder.paste(_:)))])
            // Edit's paste: down the chain alone, as the system's item sent it before (2026-11-05): no one.
            let chainAlone = UIApplication.shared.sendAction(#selector(UIResponder.paste(_:)), to: nil, from: nil, for: nil)
            let paged = send(#selector(UIResponder.paste(_:)))
            await settle()
            r.note("⌘V in 冲洗 on the open upright picture", ["sent": paged, "chain_alone_reached": chainAlone, "first_responder": UIResponder.spkFirstResponder.map { String(describing: type(of: $0)) } ?? "none",
                                                             "selection": MacLibraryBrowser.shared.selection.count,
                                                             "turn": session.edit.filmEdge.turn, "active": session.edit.filmEdge.active,
                                                             "undo_before": undoBefore, "undo_after": session.canUndo])
            r.check(paged && session.edit.filmEdge.active && session.edit.filmEdge.turn == 1,
                    "through the page's session the film lies down the upright picture (turn \(session.edit.filmEdge.turn))")
            r.check(session.canUndo, "and Undo can take the paste back")
            r.check(model.scheduler.snapshot(frameID: session.frameID, where: { $0.kind == .importDevelop && $0.tier != .full }) == nil,
                    "the open frame gets no preview develop of the library's: its page develops it")
            // ⌘C on the open page: its settings, with the picture's shape (the session's copy).
            let pageCopied = send(#selector(UIResponder.copy(_:)))
            let upright2Size = session.frame?.originalSize ?? PixelSize(width: 0, height: 0)
            r.note("⌘C in 冲洗", ["sent": pageCopied, "copier": MacEditCommands.copier.map { String(describing: type(of: $0)) } ?? "none",
                                  "turn": library.clipboard?.settings.filmEdge.turn ?? -1, "aspect": library.clipboard?.sourceAspect ?? -1])
            r.check(pageCopied && abs((library.clipboard?.sourceAspect ?? 0) - upright2Size.aspect) < 1e-9,
                    "⌘C in 冲洗 copies the page's settings with its picture's shape")
            session.undo()
            await settle()
            r.check(!session.edit.filmEdge.active, "Undo takes it back")
            // 冲洗's Presets (the bar's menu, as `--mac-drive presets` presses it): its sheet opens, with the
            // app's objects (2026-11-05: it ended the app, "No Observable object of type AppServices found").
            NotificationCenter.default.post(name: .spkDebugPresets, object: nil)
            let presetsUp = await wait(5) { MacImportDropCheck.covers().contains { $0.hasPrefix("PresentationHostingController") } }
            r.note("冲洗's Presets", ["presented": MacImportDropCheck.covers()])
            r.check(presetsUp, "冲洗's Presets opens its sheet")
            for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                w.rootViewController?.presentedViewController?.dismiss(animated: false)
            }
            _ = await wait(5) { MacImportDropCheck.covers().isEmpty }

            // 5. A field being edited keeps Edit's Copy and Paste.
            library.clipboard = nil
            MacLibraryBrowser.shared.typing = true
            await settle()
            let refused = !send(#selector(UIResponder.copy(_:))) && library.clipboard == nil
            MacLibraryBrowser.shared.typing = false
            r.note("⌘C while a field is edited", ["copied_settings": library.clipboard != nil])
            r.check(refused, "while a field is edited ⌘C is not Copy Settings")
            model.router.toLibrary()
            await settle(1.5)

            // 6. Two pastes at once onto two pictures that have no frame: one frame each.
            library.clipboard = SettingsClip(groups: [.light], settings: { var s = FrameEdit.default; s.adjustments.exposure = 0.7; return s }(),
                                             sourceName: "check", sourceAspect: 1.5)
            let pair = extra.compactMap { n in store.images.first { $0.fileName == n } }
            r.check(pair.count == 2 && pair.allSatisfy { $0.develop == nil }, "two more pictures, no frame")
            MacLibraryActions.shared.pasteSettings(onto: pair, store: store, model: model)
            MacLibraryActions.shared.pasteSettings(onto: pair, store: store, model: model)
            _ = await wait(20) { store.images.filter { extra.contains($0.fileName) }.allSatisfy { $0.develop != nil } }
            await MacLibraryActions.shared.pastesLanded()
            await settle(1)
            let framesPerFile = pair.map { row in library.frames.filter { $0.picture.fileURL.map { FolderReach.same($0, row.url) } ?? false }.count }
            let exposures = pair.compactMap { row in library.frames.first { $0.picture.fileURL.map { FolderReach.same($0, row.url) } ?? false }?.edit.adjustments.exposure }
            r.note("two pastes at once onto two pictures with no frame", ["frames_per_file": framesPerFile, "exposure": exposures,
                                                                          "notice": MacLibraryActions.shared.notice?.said ?? "-"])
            r.check(framesPerFile == [1, 1], "two pastes at once make one frame per file (\(framesPerFile))")
            r.check(exposures == [0.7, 0.7], "and both were pasted onto")

            // 8. Selectable text: Info's rows on the first picture.
            choose([store.images.first { $0.id == upright.id } ?? upright])
            MacLibraryBrowser.shared.navigator = .info
            await settle(1.5)
            var found: [UIView] = []
            if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                selectable(in: window, into: &found)
            }
            let probe = found.prefix(12).map(describe)
            r.note("selectable text in Info", ["views": probe, "count": found.count, "copier": MacEditCommands.copier.map { String(describing: type(of: $0)) } ?? "none",
                                               "appkit": MacAppKitEdit.keyWindowFacts])
            r.check(MacEditCommands.copier == nil, "with nothing selected no responder copies, so ⌘C is Copy Settings")
            // SwiftUI's selectable text on Catalyst (measured 2026-11-05): a `TextSelectionInteractionView`
            // with UIKit's text interactions, a UITextInput that can be first responder and that says it can
            // copy with nothing selected. Its document reads empty from here (the text is SwiftUI's until a
            // person's drag selects in it), so a selection cannot be made by a check: made first with
            // nothing selected, ⌘C must still be Copy Settings. A drag's selection is copied as the chain's
            // (`MacEditCommands.copier`); that needs a person's drag in an active window.
            if let view = found.first(where: { $0 is UITextInput }) {
                let became = view.becomeFirstResponder()
                await settle(0.3)
                let emptyCopier = MacEditCommands.copier
                let canCopy = view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil)
                let copied = send(#selector(UIResponder.copy(_:)))
                r.note("selectable text first, nothing selected", ["became_first": became,
                                                                   "first": UIResponder.spkFirstResponder.map { String(describing: type(of: $0)) } ?? "none",
                                                                   "can_copy": canCopy, "copier": emptyCopier.map { String(describing: type(of: $0)) } ?? "none",
                                                                   "settings_copied_from": library.clipboard?.sourceName ?? "-"])
                r.check(became && canCopy, "Info's selectable text can be first and says it can copy")
                r.check(emptyCopier == nil && copied && library.clipboard?.sourceName != "check",
                        "with it first and nothing selected ⌘C is still Copy Settings")
                MacKeyFocus.shared.takeKeys()
                await settle()
            } else {
                r.check(false, "Info shows selectable text")
            }
            MacLibraryBrowser.shared.navigator = .library

            // 9. Many never-opened pictures at once: past a carry's limit, every one.
            if many > 0 {
                let rowsMany = store.images.filter { manyNames.contains($0.fileName) }
                r.check(rowsMany.count == many, "\(many) pictures listed (\(rowsMany.count))")
                func previewJobs() -> Int { model.scheduler.snapshots.filter { $0.job.kind == .importDevelop && $0.job.tier != .full }.count }
                func manyFrames() -> [LibraryFrame] {
                    store.images.filter { manyNames.contains($0.fileName) }.compactMap { $0.develop.flatMap { library.frame($0.frameID) } }
                }
                // 9a. Stop pressed while the paste is still making their frames (500 at a time): nothing of
                // it is developed after, not even the batch that lands after the Stop (the review, 2026-11-05).
                let t0 = Date()
                MacLibraryActions.shared.refusal = nil
                MacLibraryActions.shared.pasteSettings(onto: rowsMany, store: store, model: model)
                MacLibraryActions.shared.stopPreviews(model: model)
                _ = await wait(240) { MacLibraryActions.shared.refusal != nil
                    || store.images.filter { manyNames.contains($0.fileName) }.allSatisfy { $0.develop != nil } }
                let framedAt = Date().timeIntervalSince(t0)
                await MacLibraryActions.shared.pastesLanded()
                try? await Task.sleep(for: .milliseconds(300))
                let framed = store.images.filter { manyNames.contains($0.fileName) && $0.develop != nil }.count
                r.note("paste onto \(many) never-opened pictures, Stop at once", ["framed": framed, "framed_after_s": framedAt,
                                                                               "preview_jobs": previewJobs(), "developing": library.developingCount,
                                                                               "refusal": MacLibraryActions.shared.refusal ?? "-"])
                r.check(framed == many && MacLibraryActions.shared.refusal == nil, "every one of \(many) pictures got its frame and the paste (\(framed))")
                r.check(previewJobs() == 0 && library.developingCount == 0, "a Stop before the frames were made leaves nothing queued (\(previewJobs()) jobs, \(library.developingCount) busy)")

                // 9b. Develop Previews over all of them: fed to the queue a few at a time, the main thread's
                // lag measured meanwhile (a hop asked every 20 ms, and how late each came).
                var lags: [Double] = []
                var probing = true
                let probe = Task { @MainActor in
                    while probing {
                        let asked = Date()
                        try? await Task.sleep(for: .milliseconds(20))
                        lags.append(max(0, Date().timeIntervalSince(asked) - 0.020))
                    }
                }
                let t1 = Date()
                let asked = MacLibraryActions.shared.developPreviews(of: manyFrames().map(\.id), model: model)
                await MacLibraryActions.shared.pastesLanded()
                probing = false
                await probe.value
                let queued = manyFrames().filter { $0.develop.isBusy || !model.darkroom.needsDevelop($0) }.count
                let sorted = lags.sorted()
                r.note("Develop Previews over \(many)", ["asked": asked, "fed_after_s": Date().timeIntervalSince(t1), "queued_or_fresh": queued,
                                                        "main_lag_worst_ms": (sorted.last ?? 0) * 1000,
                                                        "main_lag_p95_ms": (sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]) * 1000,
                                                        "lag_samples": lags.count])
                r.check(asked == many && queued == many, "Develop Previews queues every one owed (\(asked) asked, \(queued) queued or made)")

                // 9c. While they develop: the main thread's lag over 5 s of it.
                var steady: [Double] = []
                let doneBefore = manyFrames().filter { !$0.develop.isBusy && !model.darkroom.needsDevelop($0) }.count
                let s0 = Date()
                while Date().timeIntervalSince(s0) < 5 {
                    let hop = Date()
                    try? await Task.sleep(for: .milliseconds(20))
                    steady.append(max(0, Date().timeIntervalSince(hop) - 0.020))
                }
                let doneAfter = manyFrames().filter { !$0.develop.isBusy && !model.darkroom.needsDevelop($0) }.count
                let st = steady.sorted()
                r.note("while the previews develop", ["samples": st.count, "main_lag_p95_ms": (st.isEmpty ? 0 : st[min(st.count - 1, st.count * 95 / 100)]) * 1000,
                                                     "main_lag_worst_ms": (st.last ?? 0) * 1000, "developed_in_5s": doneAfter - doneBefore])

                // 9d. Pasted again while its develop runs: its newer develop waits at the back of the queue,
                // and the frame must read waiting, not done, when the first ends (the review, 2026-11-05).
                if let running = model.scheduler.snapshots.first(where: { if case .running = $0.state { $0.job.kind == .importDevelop && $0.job.tier != .full } else { false } }),
                   let row = store.images.first(where: { $0.develop?.frameID == running.job.frameID }) {
                    let id = running.job.frameID
                    // Another colour negative, free, still: a film-side change, so its develop is owed again.
                    let now = library.frame(id)?.edit.params.filmStock
                    let other = StockCatalog.shared.films.first { $0.id != now && $0.type == "negative" && $0.use == "still" && $0.monochrome != true }
                    library.clipboard = SettingsClip(groups: [.filmAndPaper],
                                                     settings: { var e = library.frame(id)?.edit ?? .default; e.params.filmStock = other?.id ?? e.params.filmStock; return e }(),
                                                     sourceName: "check", sourceAspect: 1.5)
                    MacLibraryActions.shared.pasteSettings(onto: [row], store: store, model: model)
                    await MacLibraryActions.shared.pastesLanded()
                    _ = await wait(30) { !model.scheduler.snapshots.contains { $0.id == running.id } }
                    let state = library.frame(id).map { "\($0.develop)" } ?? "-"
                    let held = model.scheduler.snapshot(frameID: id, where: { $0.kind == .importDevelop && $0.tier != .full }) != nil
                    r.note("pasted again while developing", ["state": state, "newer_held": held, "film": other?.id ?? "-"])
                    r.check(held && library.frame(id)?.develop.isBusy == true, "a frame pasted again while it develops reads waiting until its newer develop runs (\(state))")
                } else {
                    r.check(false, "a preview develop is running to paste over")
                }

                // 9e. Stop takes every one out, the re-pasted one too.
                MacLibraryActions.shared.stopPreviews(model: model)
                let stopped = await wait(10) { library.developingCount == 0 && previewJobs() == 0 }
                r.check(stopped, "Stop takes every queued preview out (\(library.developingCount) busy, \(previewJobs()) jobs left)")
                r.check(MacLibraryActions.shared.notice?.more != L("Their previews are developing."), "and the notice no longer says they are developing")
            }
        } catch {
            r.check(false, "the check ran (\(error.localizedDescription))")
        }
    }
}
#endif
