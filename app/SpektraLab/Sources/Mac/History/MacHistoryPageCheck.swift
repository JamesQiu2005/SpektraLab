//  MacHistoryPageCheck.swift — a debug build's proof, in the running app, of the 编辑历史 page and of the paths that
//  record a step (PRD-F §4, §3.3, §7.6).
//
//      CFFIXED_USER_HOME=<same>/home SpektraLab --library real --history-check <dir3> --history-check-relaunch <dir1> \
//          --history-check-page [--capture-window <dir>] [--history-check-exit]
//
//  Run by `tools/history_check.sh` after the relaunch's walk (`MacHistoryCheck`), on the same scratch home: the
//  first run's frames, their histories as the relaunch left them (A's cursor on its third step, B's on its first
//  state with twenty ahead). Each step drives what a person's act drives — the page's own model (`MacHistoryPageModel`:
//  its Go and Clear are the buttons'), the router as the menus present, the crop page's Done, the Film Edge flow's
//  Next, the Presets sheet's row, the Edit menu's Paste — and reads back the store, the library and the session:
//
//  E. A closed Go holds the history to the library's edit first: an unrecorded change becomes a *Changed elsewhere*
//     step before the jump; E2: where that step replaced the step asked for, Go is refused and the page says so.
//  G. Go to This Step with B closed: its edit written, a develop asked, the cursor moved, the twenty kept ahead.
//  X. While B is being exported (in a batch of every photograph, so it lasts a capture): Go refused with its reason,
//     nothing moved; and once the export has stopped, allowed.
//  Z. The page's rows after a switch to 简体中文 (and back): the names, the base, the head line, the origin word.
//  C. Clear History with B closed: nothing but the base, which is B's edit.
//  O. With A open in Develop: Go to This Step (the canvas follows: a canvas job), the page following a step made on
//     the page behind it and an Undo, then Clear History through the session.
//  W. 260 steps on H with no page open: the page's 257 rows (*Earlier edits*) read inside PRD-F §5's 20 ms; then H
//     open, Go to a step far past the session's window (`OpenFrameSession.goTo`, read first).
//  P. Go to This Step on the pair and the double with no page open: piece, look, the member's decode, its own step.
//  K. One click chooses a row, two within half a second go to it (the row's handler, `MacHistoryPageModel.click`).
//  N. A picture with no history: the empty page. (The newer-version page is `MacHistoryCheck`'s third run.)
//  M. Edit › Edit History… found in AppKit's main menu after Redo, with no key, and performed as a click performs it.
//  R. One step each, with the right origin and name: Crop's Done as a cover and in the page, the Film Edge flow's
//     Develop with a page open and with none, a preset from the Presets sheet, ⌘V (Edit › Paste) on the grid.
//  U. Undo greyed while a page's history is read, and a ⌘Z pressed then made once it lands.
//  S. Settings › Storage's figure, before and after Clear All.
//
//  `--capture-window <dir>` writes the page as the window shows it, in English and in 简体中文
//  (`MacWindowCapture.capture(named:)`), for a person to look at.

#if DEBUG
import Foundation
import UIKit

@MainActor
enum MacHistoryPageCheck {
    typealias R = MacHistoryCheck.Report

    static func until(_ s: Double, every ms: Int = 50, _ done: () -> Bool) async -> Bool { await MacHistoryCheck.until(s, every: ms, done) }
    static func listing(_ m: AppServices, _ id: UUID) async -> HistoryListing? { await MacHistoryCheck.listing(m, id) }
    static func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// The page presented over whatever is on top, as the menus present it, and its model once it has read.
    static func page(_ m: AppServices, _ id: UUID) async -> MacHistoryPageModel? {
        if m.router.sheets.last != .history(id) { m.router.present(.history(id)) }
        _ = await until(10) {
            // A window behind others or on another Space is not laid out by the display link (MacWindowCapture):
            // laid out here, so the sheet's page appears whether or not the app is in front.
            layoutWindows()
            return MacHistoryPageModel.shown?.frameID == id && MacHistoryPageModel.shown?.phase != .loading
        }
        let p = MacHistoryPageModel.shown
        return p?.frameID == id ? p : nil
    }

    static func layoutWindows() {
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            w.setNeedsLayout()
            w.layoutIfNeeded()
        }
    }

    static func closePage(_ m: AppServices) async {
        m.router.dismissAllSheets()
        _ = await until(5) { m.router.sheets.isEmpty }
        await pause(0.5)
    }

    /// The page's listing once it has read the store after every write so far.
    static func settled(_ m: AppServices, _ p: MacHistoryPageModel) async -> HistoryListing? {
        await m.history.drained()
        await p.load()
        return p.listing
    }

    static func develop(_ m: AppServices, _ id: UUID) async -> OpenFrameSession? {
        m.router.toDevelop(id)
        _ = await until(30) { m.openSession(id) != nil }
        guard let s = m.openSession(id) else { return nil }
        _ = await until(5, every: 5) { !s.historyLoading }
        return s
    }

    static func library(_ m: AppServices) async {
        m.router.toLibrary()
        _ = await until(10) { MacShellPath.develop(m.router.path) == nil && m.router.cover == nil }
        await pause(0.8)
    }

    /// The window as it stands, for a person to look at: the app's own drawing (`--capture-window`), and with
    /// `--history-check-hold <s>` a line `history-check: CAPTURE <name>` and a pause of that long, for a capture by the
    /// window server (`screencapture -l`), which sees the sheet the app's own drawing does not.
    static func capture(_ name: String) async {
        await pause(0.8)
        MacWindowCapture.capture(named: name)
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--history-check-hold"), i + 1 < a.count, let s = Double(a[i + 1]) {
            print("history-check: CAPTURE \(name)")
            await pause(s)
        }
    }

    static func run(_ model: AppServices, _ r: R, kept: MacHistoryCheck.Recorded) async {
        let photos = await MacHistoryCheck.photographs(model, atLeast: 12)
        guard let a = kept.photo, let b = kept.long, kept.longEdits.count == 21, kept.photoEdits.count == 4, kept.pasted.count == 5 else {
            r.check(false, "page: the first run's frames are recorded"); return
        }
        // The library's one-time offer to become a catalog covers the window from the third launch: Not Now, as a
        // person would answer it, so the sheets below are the window's.
        _ = await until(5) { model.macLibrary.move.showsPage }
        if model.macLibrary.move.showsPage { model.macLibrary.move.notNow(); await pause(1) }
        let h = kept.pasted[1], j = kept.pasted[2], k = kept.pasted[3], m5 = kept.pasted[4]
        r.note("page: frames", ["a": photos.first { $0.id == a }?.fileName ?? "?", "b": photos.first { $0.id == b }?.fileName ?? "?"])
        // The names the table gave, in the running app.
        let la = await listing(model, a)
        r.check(la?.steps.map(\.label.text) == ["Film Exposure +0.3", "Film Exposure +0.7", "Film Exposure +1.1"],
                "page: A's steps are named by the control and its value (\(la?.steps.map(\.label.text) ?? []))")

        // E. A closed Go holds the history to the library's edit first: a change made where no step was kept (here, the
        // library's edit set directly, as an older build or a restored backup leaves it) is still in the history after.
        await library(model)
        if let pm = await page(model, m5), let lm = pm.listing {
            let base = lm.base.seq
            model.library.update(m5) { $0.edit.params.printBrightnessStops = 1.9 }
            let changed = model.historyRevision(m5)!
            pm.selected = base
            pm.go(to: base)
            _ = await until(10, every: 5) { !pm.going }
            let le = await settled(model, pm)
            var kept = false
            for s in le?.steps ?? [] { if let st = await MacHistoryCheck.state(model, m5, s.seq), st.isSameEdit(as: changed) { kept = true } }
            r.check(kept && le?.steps.last?.origin == .elsewhere && le?.cursorSeq == base,
                    "E: closed, an unrecorded change is kept as a step (Changed elsewhere) before Go puts the base back (\(le?.steps.map { "\($0.origin)" } ?? []), cursor \(le?.cursorSeq ?? -1))")
            let baseState = await MacHistoryCheck.state(model, m5, base)
            r.check(baseState.map { model.historyRevision(m5)?.isSameEdit(as: $0) == true } == true, "E: and the library's edit is the base's")
            await closePage(model)
        } else { r.check(false, "E: M's page opens") }

        // G. Go to This Step with B closed.
        await library(model)
        guard let pb = await page(model, b), let lb = pb.listing else {
            r.note("G: the page", ["sheets": "\(model.router.sheets)", "shown": MacHistoryPageModel.shown?.frameID?.uuidString ?? "none",
                                   "phase": "\(String(describing: MacHistoryPageModel.shown?.phase))", "covers": MacImportDropCheck.covers()])
            MacWindowCapture.capture(named: "debug-no-page")
            r.check(false, "G: B's history page opens and reads"); return
        }
        let rows = MacHistoryPageModel.rows(lb)
        r.note("G: B's page", ["rows": rows.count, "head": MacHistoryPageModel.headLine(lb), "top": rows.first?.title ?? "", "ms": pb.lastLoadMillis])
        r.check(rows.count == 21 && rows.last?.isBase == true && rows.last?.isCurrent == true && rows.last?.title == "Original"
                && rows.dropLast().allSatisfy(\.isAhead) && rows.first?.seq == 20,
                "G: B's page: twenty steps newest first, all ahead of the cursor on Original, dimmed")
        r.check(MacHistoryPageModel.headLine(lb).hasPrefix("20 steps  ·  "), "G: the head line counts them (\(MacHistoryPageModel.headLine(lb)))")
        await capture("page-en-closed")
        let stampBefore = model.library.frame(b)?.developed?.stamp
        pb.selected = 10
        pb.go(to: 10)
        var asked = false
        _ = await until(10, every: 5) {
            if model.library.frame(b)?.develop.isBusy == true || model.scheduler.snapshot(frameID: b) != nil { asked = true }
            return !pb.going
        }
        _ = await until(5, every: 10) {
            if model.library.frame(b)?.develop.isBusy == true || model.scheduler.snapshot(frameID: b) != nil { asked = true }
            return asked
        }
        let edited = model.library.frame(b).map { OpenFrameSession.revision(of: $0, darkroom: nil) }
        let want = DevelopRevision(edit: kept.longEdits[10], pair: nil, sourceDecodes: [:])
        r.check(edited?.isSameEdit(as: want) == true, "G: closed, Go to step 10 writes its edit (brightness \(edited?.edit.params.printBrightnessStops ?? -9), want 0.25)")
        let lb2 = await settled(model, pb)
        r.check(lb2?.cursorSeq == 10 && lb2?.steps.count == 20, "G: the cursor is on 10 and the redo tail is kept (\(lb2?.cursorSeq ?? -1), \(lb2?.steps.count ?? -1))")
        r.check(asked || model.library.frame(b)?.developed?.stamp != stampBefore, "G: and its preview's develop is asked")
        let rows2 = lb2.map { MacHistoryPageModel.rows($0) } ?? []
        r.check(rows2.first { $0.isCurrent }?.seq == 10 && rows2.filter(\.isAhead).count == 10, "G: the page shows the dot on 10, ten dimmed above it")
        await capture("page-en-after-go")

        // X. The refusal while B is being exported: B in a batch of every photograph ten times over, so the batch is
        // under way for the seconds a capture takes (it is stopped after).
        let others = photos.map(\.id).filter { $0 != b }
        model.exporter.start([b] + Array(repeating: others, count: 10).flatMap { $0 }, recipe: ExportRecipe.builtIn[0])
        let exporting = model.exporter.isExporting
        let reason = pb.refusal
        r.check(exporting && reason != nil && lb2.map { !pb.canGo($0) } == true, "X: while B is exported, Go is refused with its reason (\(reason ?? "none"))")
        pb.selected = 3
        pb.go(to: 3)
        let direct = await model.goToStep(b, 3)
        let lbx = await settled(model, pb)
        r.check(!direct && lbx?.cursorSeq == 10 && model.library.frame(b).map { OpenFrameSession.revision(of: $0, darkroom: nil).isSameEdit(as: want) } == true,
                "X: and nothing moved: the cursor on 10, the edit step 10's")
        r.note("X: the batch at its capture", ["exporting": model.exporter.isExporting])
        await capture("page-en-refused")
        r.check(model.exporter.isExporting && pb.refusal != nil, "X: the batch is still under way at the capture (the refusal is on the page)")
        model.exporter.stop()
        _ = await until(20) { !model.exporter.isExporting }
        model.exporter.clear()
        r.check(pb.refusal == nil, "X: once the export has stopped, Go is offered again")

        // E2. An unrecorded change with steps ahead of the cursor: the guard's step takes their place, so step 15 is gone —
        // Go refuses rather than guess, the change kept as the newest step and still the library's edit, and the page says so.
        model.library.update(b) { $0.edit.params.printBrightnessStops = -1.3 }
        pb.selected = 15
        pb.go(to: 15)
        _ = await until(10, every: 5) { !pb.going }
        let le2 = await settled(model, pb)
        r.check(pb.goneStep && le2?.steps.count == 11 && le2?.steps.last?.origin == .elsewhere
                && model.library.frame(b)?.edit.params.printBrightnessStops == -1.3,
                "E2: Go to a step the guard's step replaced is refused and said; the change kept (\(le2?.steps.count ?? -1) steps, gone \(pb.goneStep))")
        await capture("page-en-gone")

        // Z. 简体中文: the rows relabel as they are drawn.
        Language.shared.choose(.simplified)
        await pause(0.4)
        let zh = lbx.map { MacHistoryPageModel.rows($0) } ?? []
        let zhHead = lbx.map(MacHistoryPageModel.headLine) ?? ""
        r.note("Z: the rows in 简体中文", ["top": zh.first?.title ?? "", "base": zh.last?.title ?? "", "origin": zh.first?.origin ?? "", "head": zhHead])
        r.check(zh.first?.title.hasPrefix("亮度") == true && zh.last?.title == "原始" && zh.first?.origin == "冲洗" && zhHead.hasPrefix("20 步"),
                "Z: after a switch to 简体中文 the names, the base, the origin and the head line are Chinese")
        await capture("page-zh-Hans-closed")
        Language.shared.choose(.english)
        await pause(0.3)
        r.check(MacHistoryPageModel.rows(lbx!).first?.title.hasPrefix("Brightness") == true, "Z: and English again after a switch back")

        // C. Clear History with B closed.
        pb.clear()
        let lbc = await settled(model, pb)
        let bNow = model.historyRevision(b)
        let base = await MacHistoryCheck.state(model, b, lbc?.base.seq ?? -1)
        r.check(lbc?.steps.isEmpty == true && lbc?.cursorSeq == lbc?.base.seq && base.map { bNow?.isSameEdit(as: $0) == true } == true,
                "C: closed, Clear History leaves the base alone, B's edit as it stands")
        await closePage(model)

        // O. A open in Develop.
        guard let sa = await develop(model, a) else { r.check(false, "O: A opens in Develop"); return }
        guard let pa = await page(model, a) else { r.check(false, "O: A's page opens over Develop"); return }
        await capture("page-en-open")
        let canvasBefore = model.scheduler.records.count
        pa.selected = 1
        pa.go(to: 1)
        var canvas = false
        _ = await until(10, every: 5) {
            if model.scheduler.snapshot(frameID: a, where: { $0.kind.isCanvas }) != nil { canvas = true }
            return !pa.going && sa.edit == kept.photoEdits[1]
        }
        _ = await until(5, every: 5) {
            if model.scheduler.snapshot(frameID: a, where: { $0.kind.isCanvas }) != nil { canvas = true }
            return canvas || model.scheduler.records.count > canvasBefore
        }
        r.check(sa.edit == kept.photoEdits[1], "O: open, Go to step 1 is the page's edit (EV \(sa.edit.params.exposureCompensationEV), want 0.3)")
        r.check(canvas || model.scheduler.records.count > canvasBefore, "O: and the canvas follows: a canvas job for A")
        let la2 = await settled(model, pa)
        r.check(la2?.cursorSeq == 1 && la2?.steps.count == 3 && sa.canRedo, "O: the cursor on 1, the two after it kept for ⇧⌘Z")
        // The page follows the history behind it: a step made on the develop page, then an Undo.
        MacHistoryCheck.gesture(sa) { $0.params.exposureCompensationEV = 0.9 }
        let followed = await until(5) { pa.listing?.steps.count == 2 && pa.listing?.cursorSeq == 2 }
        r.check(followed && pa.listing?.steps.last?.label.text == "Film Exposure +0.9",
                "O: a step made on the page behind it shows at once, the old redo tail gone (\(pa.listing?.steps.map(\.label.text) ?? []))")
        sa.undo()
        let undone = await until(5) { pa.listing?.cursorSeq == 1 }
        r.check(undone && MacHistoryPageModel.rows(pa.listing!).first?.isAhead == true, "O: and an Undo moves the dot down, the step it undid dimmed")
        pa.clear()
        let la3 = await settled(model, pa)
        r.check(la3?.steps.isEmpty == true && !sa.canUndo && sa.edit == kept.photoEdits[1], "O: Clear History through the page's session: no steps, no Undo, the edit kept")
        await closePage(model)

        // W. 260 steps with no page open, a page of 257 rows, and a Go past the session's window.
        await library(model)
        for i in 1...260 {
            guard let was = model.historyRevision(h) else { break }
            model.library.update(h) { $0.edit.adjustments.exposure = Double(i) / 100 }
            model.recordStep(h, before: was, origin: .develop, label: nil)
        }
        await model.history.drained()
        guard let ph = await page(model, h) else { r.check(false, "W: H's page opens"); return }
        var loads: [Double] = []
        for _ in 0..<5 { await ph.load(); loads.append(ph.lastLoadMillis) }
        loads.sort()
        let t0 = ContinuousClock.now
        let hRows = ph.listing.map { MacHistoryPageModel.rows($0) } ?? []
        let d = ContinuousClock.now - t0
        let rowMs = Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
        r.note("budget: the page on 256 steps", ["rows": hRows.count, "listing_median_ms": loads[2], "rows_ms": rowMs, "top": hRows.first?.title ?? ""])
        r.check(hRows.count == 257 && hRows.last?.title == "Earlier edits" && hRows.first?.title == "Exposure +2.60 EV",
                "W: 257 rows, the base *Earlier edits*, the newest named for its value (\(hRows.first?.title ?? ""))")
        r.check(loads[2] <= 20, "budget: the page's 256 rows read in \(loads[2]) ms (≤ 20)")
        await capture("page-en-256")
        await closePage(model)
        guard let sh = await develop(model, h) else { r.check(false, "W: H opens in Develop"); return }
        guard let ph2 = await page(model, h), let lh = ph2.listing else { r.check(false, "W: H's page over Develop"); return }
        let far = lh.base.seq + 6          // 260 − 8 is the session's window's start; this is far below it
        ph2.go(to: far)
        // H's first step is its paste; step s after it is exposure (s − 1) / 100.
        let reached = await until(10, every: 5) { !ph2.going && !sh.historyReading && abs(sh.edit.adjustments.exposure - Double(far - 1) / 100) < 1e-9 }
        r.check(reached, "W: Go to step \(far), past the session's window, reads it and puts it back (exposure \(sh.edit.adjustments.exposure))")
        let lh2 = await settled(model, ph2)
        r.check(lh2?.cursorSeq == far && lh2?.steps.count == 256 && sh.canRedo, "W: the cursor there, the 256 kept")
        await closePage(model)

        // P. Go to This Step on a pair and a double with no page open: piece, look and the members' decodes together, a
        // composite step on the member whose decode it moved.
        await composites(model, r, kept: kept)

        // K. A double-click on a row goes to it; one click chooses it. The row's own handler (`MacHistoryPageModel.click`),
        // called as its tap recogniser calls it: the harness makes no pointer events.
        await library(model)
        if let pc = await page(model, h), let lc = pc.listing, let top = lc.steps.last?.seq {
            let base = lc.base.seq
            let t = Date()
            pc.click(base, at: t)
            let chose = pc.selected == base && !pc.going
            pc.click(top, at: t.addingTimeInterval(0.2))          // another row: chosen, not gone to
            pc.click(top, at: t.addingTimeInterval(1.0))          // the same row after the double-click time: chosen
            let stayed = await settled(model, pc)
            pc.click(base, at: Date())
            pc.click(base, at: Date().addingTimeInterval(0.2))    // a double-click
            _ = await until(10, every: 5) { !pc.going }
            let went = await settled(model, pc)
            r.check(chose && stayed?.cursorSeq == lc.cursorSeq && went?.cursorSeq == base,
                    "K: one click chooses a row, two within half a second go to it (cursor \(lc.cursorSeq) → \(went?.cursorSeq ?? -1))")
            await closePage(model)
        } else { r.check(false, "K: H's page opens, with steps") }

        // N. A picture with no history: the empty page.
        var bare: UUID?
        for p in photos where model.library.frame(p.id) != nil { if await listing(model, p.id) == nil { bare = p.id; break } }
        if let last = bare, let pe = await page(model, last) {
            r.check(pe.phase == .none, "N: a picture with no history shows the empty page (\(pe.phase))")
            await capture("page-en-empty")
            await closePage(model)
        } else { r.check(false, "N: a picture with no history is there, and its page opens") }

        // M. Edit › Edit History… through the window's own menu bar: AppKit's main menu, its Edit menu, the item after
        // Redo, performed as a click on it performs it (`NSMenu performActionForItemAtIndex:`), over A's develop page.
        await editMenu(model, r, a: a)

        // R. The paths that record a step, each once.
        await recorded(model, r, j: j, k: k, m5: m5, source: photos.last!)

        // U. Undo greyed while the history is read.
        await library(model)
        model.history.send("check: a slow store") { _ in try await Task.sleep(for: .seconds(1.2)) }
        model.router.toDevelop(k)
        _ = await until(30, every: 5) { model.openSession(k) != nil }
        if let sk = model.openSession(k) {
            let loading = sk.historyLoading, grey = !sk.canUndo
            let before = sk.edit
            sk.undo()                      // ⌘Z pressed while it is read: made once it lands
            _ = await until(5, every: 5) { !sk.historyLoading }
            let landed = await until(3) { sk.edit != before }
            r.check(loading && grey, "U: while the page's history is read, Undo is greyed (loading \(loading), canUndo \(!grey))")
            r.check(landed, "U: and the ⌘Z pressed meanwhile is made once it lands")
        } else { r.check(false, "U: K opens in Develop") }
        await library(model)

        // S. Settings' figure, and Clear All.
        let before = await MacSettingsStorage.historyBytes(model) ?? -1
        let after = await MacSettingsStorage.clearAllHistory(model) ?? -1
        r.note("S: Settings' Edit history", ["before": before, "after": after])
        r.check(before > 0 && after >= 0 && after < before && after < 64 * 1024,
                "S: Clear All brings Settings' figure down (\(Fmt.fileSize(before)) → \(Fmt.fileSize(after)))")
        let none = await listing(model, a)
        r.check(none == nil, "S: and every frame's history is gone")
    }

    /// P: closed Go on the pair and the double the first run made.
    static func composites(_ model: AppServices, _ r: R, kept: MacHistoryCheck.Recorded) async {
        await library(model)
        for (name, id, member, states) in [("pair", kept.pair, kept.pairMember, kept.pairStates), ("double", kept.double, kept.doubleMember, kept.doubleStates)] {
            guard let id, let member, states.count == 4, let p = await page(model, id), let l = p.listing else {
                r.check(false, "P: the \(name)'s page opens"); continue
            }
            let memberSteps = await listing(model, member)?.steps.count ?? 0
            p.go(to: l.base.seq + 1)
            _ = await until(10, every: 5) { !p.going }
            await model.history.drained()
            let now = model.historyRevision(id)
            let memberNow = await listing(model, member)
            let after = await listing(model, id)
            r.note("P: the \(name) after Go to \(l.base.seq + 1)", ["gone": p.goneStep, "cursor_before": l.cursorSeq, "cursor": after?.cursorSeq ?? -1,
                                                                   "steps": after?.steps.map { "\($0.origin)" } ?? [],
                                                                   "same_as_1": now?.isSameEdit(as: states[1]) ?? false])
            r.check(now?.isSameEdit(as: states[1]) == true && model.library.frame(member)?.edit.decode == states[1].sourceDecodes[member],
                    "P: closed, Go to the \(name)'s step 1 puts its piece, look and the member's decode back (temperature \(model.library.frame(member)?.edit.decode.temperature ?? -1))")
            r.check(memberNow?.steps.count == memberSteps + 1 && memberNow?.steps.last?.origin == .composite,
                    "P: and the member gets its own composite step (\(memberSteps) → \(memberNow?.steps.count ?? -1))")
            p.go(to: l.base.seq + 3)
            _ = await until(10, every: 5) { !p.going }
            await model.history.drained()
            r.check(model.historyRevision(id)?.isSameEdit(as: states[3]) == true && model.library.frame(member)?.edit.decode == states[3].sourceDecodes[member],
                    "P: and Go to step 3 puts the later state back, the member's decode with it")
            if name == "pair" { await capture("page-en-pair") }
            await closePage(model)
        }
    }

    /// M: Edit › Edit History… from the main menu.
    static func editMenu(_ model: AppServices, _ r: R, a: UUID) async {
        guard await develop(model, a) != nil else { r.check(false, "M: A opens in Develop"); return }
        await pause(1)
        let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject
        // The menu bar is built as the app comes to the front; a check's launch may never have been in front.
        app?.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true)
        UIMenuSystem.main.setNeedsRebuild()
        await pause(1)
        let mm = app?.value(forKey: "mainMenu") as? NSObject
        r.note("M: the main menu", ["menu": String(describing: mm).prefix(200), "count": (mm?.value(forKey: "numberOfItems") as? Int) ?? -1])
        guard let main = app?.value(forKey: "mainMenu") as? NSObject, let items = main.value(forKey: "itemArray") as? [NSObject] else {
            r.check(false, "M: the main menu is there"); return
        }
        r.note("M: the menu bar", ["titles": items.map { ($0.value(forKey: "title") as? String) ?? "?" }])
        // The system's menus are titled in the Mac's own language (here 编辑): the Edit menu is the one holding Undo.
        func titlesOf(_ menu: NSObject?) -> [String] { (menu?.value(forKey: "itemArray") as? [NSObject] ?? []).map { ($0.value(forKey: "title") as? String) ?? "" } }
        let edit = items.compactMap { $0.value(forKey: "submenu") as? NSObject }.first { titlesOf($0).contains("Undo") }
        let titles = (edit?.value(forKey: "itemArray") as? [NSObject] ?? []).map { ($0.value(forKey: "title") as? String) ?? "" }
        r.note("M: the Edit menu", ["items": titles])
        guard let edit, let i = titles.firstIndex(of: "Edit History…") else { r.check(false, "M: Edit has Edit History…"); return }
        let item = (edit.value(forKey: "itemArray") as? [NSObject])?[i]
        let key = (item?.value(forKey: "keyEquivalent") as? String) ?? "?"
        r.check(i > 0 && titles[i - 1] == "Redo" && key.isEmpty, "M: Edit History… comes right after Redo, with no key (\(titles[max(0, i - 1)]), key \"\(key)\")")
        let sel = NSSelectorFromString("performActionForItemAtIndex:")
        typealias Perform = @convention(c) (AnyObject, Selector, Int) -> Void
        let imp = unsafeBitCast(edit.method(for: sel), to: Perform.self)
        imp(edit, sel, i)
        let shown = await until(5) { model.router.sheets.last == .history(a) }
        r.check(shown, "M: performed, it opens the page of the picture on the develop page")
        await capture("page-en-from-edit-menu")
        await closePage(model)
        await library(model)
    }

    /// The Film Edge flow from its first step to its Develop, as a person goes through it: Next to Edge (the film edge
    /// put on the frame), the Edge fog ruler dragged twice, Next on to Date, Develop.
    static func flowThrough(_ model: AppServices) async {
        for _ in 0..<2 { NotificationCenter.default.post(name: MacDriver.flowNext, object: nil); await pause(0.8) }
        for fog in [0.4, 0.8] { NotificationCenter.default.post(name: MacDriver.flowFog, object: fog); await pause(0.6) }
        for _ in 0..<4 where model.router.cover != nil {
            NotificationCenter.default.post(name: MacDriver.flowNext, object: nil)
            await pause(0.8)
        }
    }

    /// R: Crop's Done (cover and in the page), the Film Edge flow's Develop (page open and none), a preset from the
    /// Presets sheet, ⌘V on the grid: one step each, of its origin, with its name.
    static func recorded(_ model: AppServices, _ r: R, j: UUID, k: UUID, m5: UUID, source: LibraryFrame) async {
        func one(_ id: UUID, after n: Int, _ origin: HistoryOrigin, _ label: HistoryLabel, _ what: String) async {
            let l = await listing(model, id)
            let new = (l?.steps ?? []).suffix(max(0, (l?.steps.count ?? 0) - n))
            r.check(new.count == 1 && new.first?.origin == origin && new.first?.label == label,
                    "R: \(what): one step, \(origin), \(label.text) (\(new.map { "\($0.origin) \($0.label.text)" }))")
        }
        func count(_ id: UUID) async -> Int { await listing(model, id)?.steps.count ?? 0 }

        // Crop's Done on the cover, no page open.
        await library(model)
        var n = await count(j)
        model.router.show(.crop(j))
        _ = await until(10) { model.router.cover == .crop(j) }
        await pause(1.5)
        NotificationCenter.default.post(name: MacDriver.cropRotate, object: nil)
        await pause(0.6)
        NotificationCenter.default.post(name: MacDriver.cropDone, object: nil)
        _ = await until(5) { model.router.cover == nil }
        await model.history.drained()
        await one(j, after: n, .flow, .crop, "Crop's Done with no page open")
        // The Film Edge flow, no page open: Next to its Develop.
        n = await count(j)
        model.router.show(.filmEdge(j, .film))
        _ = await until(10) { model.router.cover != nil }
        await pause(1.5)
        await flowThrough(model)
        _ = await until(5) { model.router.cover == nil && model.openSession(j) == nil }
        await model.history.drained()
        await one(j, after: n, .flow, .filmEdge, "the Film Edge flow's Develop with no page open")

        // In the page: Crop's Done, the flow, a preset.
        guard let sk = await develop(model, k) else { r.check(false, "R: K opens in Develop"); return }
        n = await count(k)
        model.router.show(.crop(k))
        _ = await until(10) { model.router.inlineCrop != nil }
        await pause(1.5)
        NotificationCenter.default.post(name: MacDriver.cropRotate, object: nil)
        await pause(0.6)
        model.router.inlineCrop?.finishes += 1
        _ = await until(5) { model.router.inlineCrop == nil }
        await model.history.drained()
        await one(k, after: n, .flow, .crop, "Crop's Done in the page")
        n = await count(k)
        model.router.show(.filmEdge(k, .film))
        _ = await until(10) { model.router.cover != nil }
        await pause(1.5)
        await flowThrough(model)
        _ = await until(5) { model.router.cover == nil }
        await model.history.drained()
        await one(k, after: n, .flow, .filmEdge, "the Film Edge flow's Develop over the page")
        r.check(sk.canUndo, "R: and the page can take the flow's step back")
        // A preset, from the Presets sheet.
        var look = sk.edit
        look.params.exposureCompensationEV = 1.7
        _ = model.presets.save(name: "Night", clip: SettingsClip(groups: [.filmExposure], settings: look, sourceName: ""))
        n = await count(k)
        NotificationCenter.default.post(name: .spkDebugPresets, object: nil)
        let up = await until(5) { MacImportDropCheck.covers().contains { $0.hasPrefix("PresentationHostingController") } }
        await pause(0.6)
        NotificationCenter.default.post(name: MacDriver.presetApply, object: "Night")
        _ = await until(5) { sk.edit.params.exposureCompensationEV == 1.7 }
        await model.history.drained()
        r.check(up, "R: the Presets sheet opens")
        await one(k, after: n, .preset, .preset("Night"), "a preset from the Presets sheet")
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            w.rootViewController?.presentedViewController?.dismiss(animated: false)
        }
        await library(model)

        // ⌘V (Edit › Paste) on the grid, two chosen: two pictures of a scratch catalog (the app library's own frames
        // are no catalog's once its move was put off), never opened, as `MacClipboardCheck` lays them out.
        var settings = source.edit
        settings.params.exposureCompensationEV = -0.7
        let store = model.macLibrary
        await store.start()
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "history-paste")
        let card = work.appending(path: "Card")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        guard let file = source.developSource ?? source.picture.fileURL else { r.check(false, "R: the paste's fixture file"); return }
        for n in ["P1.jpg", "P2.jpg"] { try? fm.copyItem(at: file, to: card.appending(path: n)) }
        do {
            let cat = try await store.newCatalog(named: "History", in: work)
            try await store.addFolder(card, to: cat.id)
        } catch { r.check(false, "R: a scratch catalog for ⌘V (\(error))"); return }
        _ = await until(30) { store.images.count == 2 }
        await store.select(collection: store.tree.defaultSelection)
        _ = await until(30) { store.images.count == 2 }
        let rows = store.images
        r.note("R: the grid", ["images": rows.count, "chosen": rows.map(\.fileName)])
        model.library.clipboard = SettingsClip(groups: [.filmExposure], settings: settings, sourceName: source.fileName)
        MacLibraryBrowser.shared.selection = Set(rows.map(\.id))
        MacLibraryBrowser.shared.focus = rows.first?.id
        await pause(0.6)
        let sent = MacEditCommands.edit(#selector(UIResponder.paste(_:)))
        _ = await until(20) {
            let ids = store.images.compactMap { $0.develop?.frameID }
            return ids.count == 2 && ids.allSatisfy { model.library.frame($0)?.edit.params.exposureCompensationEV == -0.7 }
        }
        await model.history.drained()
        let made = store.images.compactMap { $0.develop?.frameID }
        r.check(sent && rows.count == 2 && made.count == 2, "R: ⌘V reaches the grid's two chosen pictures (sent \(sent), \(rows.count) rows, \(made.count) frames)")
        for (i, id) in made.enumerated() { await one(id, after: 0, .paste, .paste(from: source.fileName), "⌘V on the grid (\(i + 1))") }
        MacLibraryBrowser.shared.selection = []
    }
}
#endif
