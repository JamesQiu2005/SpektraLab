//  MacTransitionsCheck.swift — how soon the page shows the state a 2.4.0 act asks for (2.4.0 A2): `--masks-check`'s
//  **transitions** case, run in the walk after M1b's cost and alone with `MASKS_CHECK_ONLY=transitions`.
//
//  The owner, on a 160 Hz display: "the simple transition between the v2.4.0 features feels slow". What is timed is the
//  act to the first frame that shows its state — the row's highlight and the layer's page, the tool lit, the overlay,
//  the surface, the sheet, the variant chosen — not the develop that may follow it, which must start after that frame
//  and never hold it.
//
//  **How it is timed** (`TransitionClock`): two run-loop observers on the main run loop, one as it wakes (first of all
//  its observers) and one as it goes to sleep (last of all, so after SwiftUI's update and Core Animation's commit, which
//  are both observers of the same moment). An act is called as its control calls it, and the clock waits for the first
//  sleep at which the act's state reads as shown (`shown`, evaluated in that observer): that turn's commit is the first
//  to carry the state. The frame is the display link's next target after that commit (`frame`). Each awake span is kept,
//  so the case also reports the longest one in the half second after the act (a stall: a frame held after the first)
//  and how long the main thread stayed busy (`burst`: awake spans of 2 ms or more, chained by gaps under 16 ms).
//
//  **What drives what.** No real pointer or key reaches the Catalyst canvas from a check (posted pointer events do not
//  land on it; keys only in front, `MacMaskToolsCheck.keys`). Every act here is called as its control calls it: a row's
//  tap `pick(row:)`, the tool slot's `MaskTools.click`, M's and ⌥M's toggles, the mode row's `chooseSurface` (the shell
//  bar's), the + and − of the panel's head (`makeLayer`, `removeLayer`), the part list's + (`addPart`), the history
//  page as the menus present it and its row's `click`, New and Clone Variant's `perform` (F2 / F3 and the Image menu's),
//  a browser row's `open`. The press is `MaskTools.beginStroke`, as `MaskStage`'s press calls it.
//
//  Bars (2.4.0 A2): the first frame of the new state ≤ 50 ms median and ≤ 100 ms worst on a 45 MP RAW; for a variant's
//  New or Clone (a frame made by the library's helper, then its first develop) the selection and the page's chrome
//  within the same bar, the picture following.
//
//  **Another photograph or variant** (2.4.0 A2b): its selection, its chrome and its kept picture drawn on the canvas
//  (`pageShows`) ≤ 100 ms median and ≤ 150 ms worst (`switchBar`) — photograph → photograph both ways (A, the 45 MP NEF
//  with two mask layers; B, the second RAW), another variant from the browser, and New / Clone Variant's selection from
//  the helper's answer (its round trip reported apart) and its page after it. Each switch's time is split by the page's
//  marks (`TransitionMarks`, a `split` line) and the run loop's turns (a `turns` line). Then what goes from A's page to
//  B's and back is checked, not timed (`leaks`).

#if DEBUG && SPK_ENGINE
import CoreFoundation
import Foundation
import QuartzCore
import UIKit

/// The main run loop's awake spans, and the first commit at which a state reads as shown.
@MainActor
final class TransitionClock {
    static let shared = TransitionClock()

    struct Turn { var start: Double; var end: Double; var length: Double { end - start } }
    private(set) var turns: [Turn] = []
    private var awake = CACurrentMediaTime()
    private var installed = false
    private var waiting: (shown: () -> Bool, done: (Double) -> Void)?

    func install() {
        guard !installed else { return }
        installed = true
        let loop = CFRunLoopGetMain()
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated { TransitionClock.shared.awake = now }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated { TransitionClock.shared.slept(now) }
        }
        CFRunLoopAddObserver(loop, wake, .commonModes)
        CFRunLoopAddObserver(loop, sleep, .commonModes)
    }

    private func slept(_ now: Double) {
        turns.append(Turn(start: awake, end: now))
        if turns.count > 40_000 { turns.removeFirst(20_000) }
        awake = now
        if let w = waiting, w.shown() { waiting = nil; w.done(now) }
    }

    struct Sample {
        /// The act to the end of the commit that first carries its state, ms.
        var commit: Double
        /// The act to the display frame that commit is shown on (the display link's target after it), ms.
        var frame: Double
        /// The longest awake span in the half second after the act, ms (from the act where the span began before it).
        var stall: Double
        /// The act to the end of the main thread's busy stretch it began, ms.
        var burst: Double
    }

    private final class Box { var done = false }

    /// `act` called now; the first commit at which `shown` holds, and what the main thread did around it.
    func time(_ act: () -> Void, shown: @escaping () -> Bool = { true }, timeout: Double = 15) async -> Sample? {
        install()
        // Out of any turn the check itself made busy: the act starts a turn of its own.
        await Task.yield()
        let t0 = CACurrentMediaTime()
        act()
        let box = Box()
        let at: Double? = await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
            waiting = (shown, { t in guard !box.done else { return }; box.done = true; c.resume(returning: t) })
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !box.done else { return }
                box.done = true
                self.waiting = nil
                c.resume(returning: nil)
            }
        }
        guard let at else { return nil }
        let target = await Self.nextTarget()
        try? await Task.sleep(for: .milliseconds(600))
        let after = turns.filter { $0.end > t0 && $0.start < t0 + 0.5 }
        let stall = after.map { $0.end - max($0.start, t0) }.max() ?? 0
        var end = at
        for t in turns where t.end > at && t.length >= 0.002 {
            guard t.start - end < 0.016 else { break }
            end = t.end
        }
        return Sample(commit: (at - t0) * 1000, frame: (max(target, at) - t0) * 1000, stall: stall * 1000, burst: (end - t0) * 1000)
    }

    /// The display link's next target frame, as of its first callback from now.
    static func nextTarget() async -> Double {
        await withCheckedContinuation { (c: CheckedContinuation<Double, Never>) in Tick(c).start() }
    }

    private final class Tick: NSObject {
        private var c: CheckedContinuation<Double, Never>?
        private var link: CADisplayLink?
        private var me: Tick?
        init(_ c: CheckedContinuation<Double, Never>) { self.c = c }
        func start() {
            me = self
            let l = CADisplayLink(target: self, selector: #selector(fired(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc func fired(_ l: CADisplayLink) {
            let t = l.targetTimestamp
            link?.invalidate(); link = nil
            c?.resume(returning: t); c = nil
            me = nil
        }
    }
}

/// Named moments of a switch to another photograph (2.4.0 A2b): where its time goes between the act and its first frame.
/// The page marks them (`TransitionMarks.mark`, DEBUG only) while the case has them on; nothing is kept otherwise.
@MainActor
enum TransitionMarks {
    private(set) static var on = false
    private(set) static var marks: [(name: String, at: Double)] = []
    /// The frame the canvas was last made for.
    static var canvasFrame: LibraryFrame.ID?
    /// The last picture the canvas's `FramePicture` drew with pixels in it (not its ground while it decodes).
    static var drew: PictureRef?
    static func drew(_ p: PictureRef) { if on, drew != p { drew = p; mark("drew") } }

    static func mark(_ name: String) { if on { marks.append((name, CACurrentMediaTime())) } }
    static func canvas(_ id: LibraryFrame.ID) { if on { canvasFrame = id } }
    static func begin() {
        marks = []; canvasFrame = nil; drew = nil; on = true
        if ProcessInfo.processInfo.environment["MASKS_TRANSITIONS_VSYNC"] != nil { Vsync.shared.start() }
    }
    static func end() -> [(name: String, at: Double)] { on = false; Vsync.shared.stop(); return marks }

    /// MASKS_TRANSITIONS_VSYNC=1: a mark at each display-link callback the main thread gets to, to see the frames.
    private final class Vsync: NSObject {
        static let shared = Vsync()
        private var link: CADisplayLink?
        func start() {
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        func stop() { link?.invalidate(); link = nil }
        @objc func tick(_ l: CADisplayLink) { MainActor.assumeIsolated { TransitionMarks.mark("v") } }
    }
}

@MainActor
enum MacTransitionsCheck {
    typealias R = MacMasksCheck.Report
    static var tools: MaskTools { .shared }

    /// 2.4.0 A2's bars: the first frame of the new state.
    static let medianBar = 50.0, worstBar = 100.0
    /// 2.4.0 A2b's, for a change of photograph or variant: the page's state with the next frame's.
    static let switchBar = (median: 100.0, worst: 150.0)
    static func bars(_ name: String) -> (median: Double, worst: Double) {
        ["photograph →", "another variant", "New Variant", "Clone Variant"].contains { name.hasPrefix($0) } ? switchBar : (medianBar, worstBar)
    }

    struct Row { var name: String; var samples: [TransitionClock.Sample]; var gated = true; var load = 0.0 }

    static func load() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }

    static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

    /// MASKS_TRANSITIONS_SAMPLE=<name>: that transition repeated for 4 s after a `SAMPLE <pid> <name>` line, for the
    /// shell's `sample <pid>` (tools/masks_check.sh).
    static var sampling: String? { ProcessInfo.processInfo.environment["MASKS_TRANSITIONS_SAMPLE"] }

    static func run(_ m: AppServices, _ r: R, a: LibraryFrame, b: LibraryFrame? = nil) async {
        guard let s = await MacMasksCheck.develop(m, a.id) else { return r.check(false, "transitions: A opens") }
        TransitionClock.shared.install()
        var rows: [Row] = []
        let clock = TransitionClock.shared
        // MASKS_TRANSITIONS_QUICK=1: three of each and no variants, while a fix is worked on (not a gate).
        let quick = ProcessInfo.processInfo.environment["MASKS_TRANSITIONS_QUICK"] != nil
        let n = quick ? 3 : 7
        func record(_ name: String, gated: Bool = true, _ sample: TransitionClock.Sample?) {
            if let i = rows.firstIndex(where: { $0.name == name }) {
                if let sample { rows[i].samples.append(sample) }
            } else {
                rows.append(Row(name: name, samples: sample.map { [$0] } ?? [], gated: gated, load: load()))
            }
        }
        func timed(_ name: String, gated: Bool = true, shown: @escaping () -> Bool = { true }, timeout: Double = 15, _ act: () -> Void) async {
            let sample = await clock.time(act, shown: shown, timeout: timeout)
            record(name, gated: gated, sample)
            if sample == nil { r.unreached("transitions: \(name): its state never read as shown") }
        }

        // Two mask layers, each with a part, so a layer's page has its parts, its adjustments and its notice to draw.
        s.show(.develop)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        tools.putDown(); tools.held = false; tools.alone = false
        tools.setSettings(.brush, BrushSettings(radius: 0.03, hardness: 0.8, flow: 1))
        MacMaskToolsCheck.stroke(s, a.id, [MaskPoint(0.3, 0.4), MaskPoint(0.4, 0.45), MaskPoint(0.5, 0.42)])
        guard let one = s.layerPick.maskID else { return r.check(false, "transitions: a brush layer") }
        s.changeLayer(one) { $0.scene?.exposure = 0.7 }
        s.pick(row: .film)
        MacMaskToolsCheck.gradient(s, a.id, .linear, from: MaskPoint(0.5, 0.1), to: MaskPoint(0.5, 0.5))
        guard let two = s.layerPick.maskID, two != one else { return r.check(false, "transitions: a gradient layer") }
        s.changeLayer(two) { $0.scene?.exposure = -0.5 }
        tools.putDown()
        await MacMasksCheck.settle(m)

        if let words = sampling, words != "browser" {
            for only in words.split(separator: " ").map(String.init) {
                print("masks-check: SAMPLE \(ProcessInfo.processInfo.processIdentifier) \(only)"); fflush(stdout)
                await MacMasksCheck.pause(0.5)
                let end = Date().addingTimeInterval(5)
                var k = 0
                while Date() < end {
                    switch only {
                    case "row":
                        let to: LayerPick = k % 3 == 0 ? .mask(one) : k % 3 == 1 ? .mask(two) : .film
                        _ = await clock.time({ s.pick(row: to) })
                    case "tool":
                        _ = await clock.time({ tools.click(.brush) })
                    case "held":
                        s.pick(row: .mask(one))
                        _ = await clock.time({ tools.alone = false; tools.held.toggle() })
                    case "surface":
                        _ = await clock.time({ MacShellBar.shared.develop?.chooseSurface(k % 2 == 0 ? .edit : .develop) })
                    case "layer":
                        if let id = s.makeLayer() { await MacMasksCheck.pause(0.05); s.removeLayer(id) }
                    case "history":
                        m.router.present(.history(a.id)); await MacMasksCheck.pause(0.3); m.router.dismissSheet()
                    case "photo":
                        if let b, let dev = MacShellBar.shared.develop {
                            dev.open(dev.frameID == a.id ? b.id : a.id)
                            try? await Task.sleep(for: .milliseconds(370))
                        }
                    case "press":
                        tools.light(.brush)
                        _ = await clock.time({ _ = tools.beginStroke(s, at: MaskPoint(0.2 + 0.01 * Double(k % 40), 0.7), frame: a.id, straight: false) })
                        tools.endDrag(s, frame: a.id)
                        if k % 10 == 9 { _ = s.undo() }
                    default: break
                    }
                    k += 1
                    try? await Task.sleep(for: .milliseconds(30))
                }
                tools.putDown()
                s.pick(row: .film)
                await MacMasksCheck.pause(1)
            }
            print("masks-check: SAMPLE DONE"); fflush(stdout)
            return
        }

        // 1. The 图层 panel's rows, in 冲洗 and in 编辑: 胶片 → a mask layer → the other → 胶片.
        for surface in [WorkspaceMode.develop, .edit] {
            MacShellBar.shared.develop?.chooseSurface(surface)
            _ = await MacMasksCheck.until(5) { s.surface == (surface == .edit ? .edit : .develop) }
            await MacMasksCheck.settle(m)
            let word = surface == .edit ? "编辑" : "冲洗"
            for _ in 0..<n {
                await timed("row 胶片 → mask (\(word))", shown: { s.layerPick == .mask(one) }) { s.pick(row: .mask(one)) }
                await MacMasksCheck.pause(0.15)
                await timed("row mask → mask (\(word))", shown: { s.layerPick == .mask(two) }) { s.pick(row: .mask(two)) }
                await MacMasksCheck.pause(0.15)
                await timed("row mask → 胶片 (\(word))", shown: { s.layerPick == .film }) { s.pick(row: .film) }
                await MacMasksCheck.pause(0.15)
            }
        }
        MacShellBar.shared.develop?.chooseSurface(.develop)
        await MacMasksCheck.settle(m)

        // 2. The tools, with a layer picked: lit and put down by their slot's click; M and ⌥M.
        s.pick(row: .mask(one))
        await MacMasksCheck.pause(0.3)
        for _ in 0..<n {
            for tool in [MaskTool.brush, .eraser, .linear, .radial] {
                await timed("tool \(tool.rawValue) lit", shown: { tools.lit == tool }) { tools.click(tool) }
                await MacMasksCheck.pause(0.12)
                await timed("tool \(tool.rawValue) put down", shown: { tools.lit == nil }) { tools.click(tool) }
                await MacMasksCheck.pause(0.12)
            }
            await timed("overlay on (M)", shown: { MaskOverlay.shared.made?.mode == .overlay }) { tools.alone = false; tools.held.toggle() }
            await MacMasksCheck.pause(0.2)
            await timed("overlay off (M)", shown: { !tools.held }) { tools.alone = false; tools.held.toggle() }
            await MacMasksCheck.pause(0.2)
            await timed("mask alone on (⌥M)", shown: { MaskOverlay.shared.made?.mode == .alone }) { tools.alone.toggle() }
            await MacMasksCheck.pause(0.2)
            await timed("mask alone off (⌥M)", shown: { !tools.alone }) { tools.alone.toggle() }
            await MacMasksCheck.pause(0.2)
        }

        // 3. The press that starts a stroke (its first frame: the stroke's first dab drawn live), the brush lit.
        for _ in 0..<n {
            tools.light(.brush); tools.held = false
            await MacMasksCheck.pause(0.2)
            let presents = MaskLive.shared.presents
            await timed("press (a stroke's start)", shown: { MaskLive.shared.presents > presents }) {
                _ = tools.beginStroke(s, at: MaskPoint(0.25, 0.75), frame: a.id, straight: false)
            }
            tools.endDrag(s, frame: a.id)
            await MacMasksCheck.pause(0.2)
            _ = s.undo()
            await MacMasksCheck.pause(0.3)
        }
        tools.putDown()
        await MacMasksCheck.settle(m)

        // 5. 冲洗 ↔ 编辑 with the mask layers, one picked.
        for _ in 0..<n {
            await timed("冲洗 → 编辑", shown: { MacShellBar.shared.develop?.surface == .edit }) { MacShellBar.shared.develop?.chooseSurface(.edit) }
            await MacMasksCheck.pause(0.4)
            await timed("编辑 → 冲洗", shown: { MacShellBar.shared.develop?.surface == .develop }) { MacShellBar.shared.develop?.chooseSurface(.develop) }
            await MacMasksCheck.pause(0.4)
        }
        // 编辑历史: opened as the menus present it, a row clicked, closed.
        await m.history.drained()
        for _ in 0..<n {
            // The sheet is AppKit's: its open and close animate in a run loop of AppKit's own (`NSMoveHelper`, ~0.35 s, the
            // main thread held throughout; `sample`), which the clock's observers do not see. Gated: the act to the page's
            // first drawing (its model attached as the sheet's content first appears, `MacHistoryPageModel.attachedAt`),
            // a display frame added; the whole animation reported beside it.
            var opened = 0.0
            await timed("编辑历史 opens (AppKit's sheet animation done)", gated: false, shown: { MacHistoryPageModel.shown?.frameID == a.id }) {
                opened = CACurrentMediaTime(); m.router.present(.history(a.id))
            }
            if MacHistoryPageModel.shown?.frameID == a.id, MacHistoryPageModel.attachedAt > opened {
                let drawn = (MacHistoryPageModel.attachedAt - opened) * 1000
                record("编辑历史 opens (its page drawn)", TransitionClock.Sample(commit: drawn, frame: drawn + MaskLive.shared.frameSeconds * 1000, stall: 0, burst: drawn))
            }
            await timed("编辑历史 opens (its rows read)", gated: false, shown: { MacHistoryPageModel.shown?.frameID == a.id && MacHistoryPageModel.shown?.phase != .loading }) {}
            await MacMasksCheck.pause(0.3)
            if let p = MacHistoryPageModel.shown, let row = p.listing?.steps.dropLast().last?.seq {
                await timed("编辑历史 row clicked", shown: { p.selected == row }) { p.click(row) }
                await MacMasksCheck.pause(0.6)
            }
            // Closed: the commit that starts AppKit's closing animation, a display frame added (gated); the animation beside it.
            let closing = await clock.time({ m.router.dismissSheet() }, shown: { m.router.sheets.isEmpty })
            if let closing {
                record("编辑历史 closes (its animation begun)", TransitionClock.Sample(commit: closing.commit, frame: closing.commit + MaskLive.shared.frameSeconds * 1000, stall: closing.stall, burst: closing.burst))
                record("编辑历史 closes (AppKit's sheet animation done)", gated: false, closing)
            }
            await MacMasksCheck.pause(0.5)
        }

        // 6. + (a layer), the part list's + (an empty part on the picked layer's mask), − (the layer).
        for _ in 0..<n {
            var made: UUID?
            await timed("+ a mask layer", shown: { s.layerPick.maskID != nil && s.layerPick.maskID != one && s.layerPick.maskID != two }) { made = s.makeLayer() }
            await MacMasksCheck.pause(0.3)
            if let made {
                let parts = s.edit.layers?[made]?.parts.count ?? 0
                await timed("+ a part", shown: { (s.edit.layers?[made]?.parts.count ?? 0) > parts }) {
                    _ = s.addPart(MaskPart.linear(MaskLinear(a: MaskPoint(0.5, 0.6), b: MaskPoint(0.5, 0.9))), to: made)
                }
                await MacMasksCheck.pause(0.3)
                await timed("− the layer", shown: { s.edit.layers?[made] == nil }) { s.removeLayer(made) }
                await MacMasksCheck.pause(0.4)
            }
        }
        await MacMasksCheck.settle(m)

        // 7. Another photograph from the browser (2.4.0 A2b): A (45 MP, two mask layers) ↔ B (the second RAW), each developed
        // once before, so the kept picture is there to show; its row's open, as a click on its row in 冲洗/编辑 asks.
        if let b { await photographs(m, r, a: a, b: b, n: n, timed: { name, gated, shown, timeout, act in await timed(name, gated: gated, shown: shown, timeout: timeout, act) }) }
        // 8. What of A's page goes to B, and back (2.4.0 A2b's state list): checked, not timed.
        if let b { await leaks(m, r, a: a, b: b, one: one) }

        // 5. New Variant (F2), Clone Variant (F3) and another variant of the same photograph from the browser, on a
        // catalog's copy of A (variants are a catalog's: the app's own library keeps none).
        if !quick || sampling == "browser" {
            await variants(m, r, a: a, timed: { name, gated, shown, timeout, act in await timed(name, gated: gated, shown: shown, timeout: timeout, act) },
                           record: { name, gated, sample in
                               record(name, gated: gated, sample)
                               if sample == nil { r.unreached("transitions: \(name): never measured") }
                           })
        }

        // The table, and the bars.
        let word = String(format: "load %.2f at the start", rows.first?.load ?? load())
        print("masks-check: TRANSITIONS (\(a.originalSize.width)x\(a.originalSize.height), \(word); ms from the act; frame = the display frame the first commit of its state is shown on)")
        print(String(format: "masks-check:   %-34@ %8@ %8@ %8@ %8@ %8@ %4@ %6@", "transition" as NSString, "median" as NSString, "worst" as NSString,
                     "commit" as NSString, "stall" as NSString, "busy" as NSString, "n" as NSString, "load" as NSString))
        for row in rows {
            let f = row.samples.map(\.frame)
            print(String(format: "masks-check:   %-34@ %8.1f %8.1f %8.1f %8.1f %8.1f %4d %6.2f%@", row.name as NSString, median(f), f.max() ?? .nan,
                         median(row.samples.map(\.commit)), row.samples.map(\.stall).max() ?? .nan, median(row.samples.map(\.burst)),
                         row.samples.count, row.load, row.gated ? "" : "  (not gated)"))
            guard row.gated else { continue }
            let bar = bars(row.name)
            r.check(!f.isEmpty && median(f) <= bar.median && (f.max() ?? .infinity) <= bar.worst,
                    "transitions: \(row.name): the first frame of its state (median ≤ \(Int(bar.median)) ms, worst ≤ \(Int(bar.worst)) ms)",
                    String(format: "median %.1f, worst %.1f ms over %d (the commit %.1f ms; the longest awake span after it %.1f ms; load %.2f)",
                           median(f), f.max() ?? .nan, f.count, median(row.samples.map(\.commit)), row.samples.map(\.stall).max() ?? .nan, row.load))
        }
        fflush(stdout)
        s.change { $0.layers = nil }
        tools.putDown(); tools.held = false; tools.alone = false
        await MacMasksCheck.settle(m)
    }

    typealias Timed = (String, Bool, @escaping () -> Bool, Double, () -> Void) async -> Void

    /// The page shows `id`: the bar's half is its (the chrome), and the canvas drew it with its kept picture there.
    static func pageShows(_ m: AppServices, _ id: LibraryFrame.ID) -> Bool {
        guard MacShellBar.shared.develop?.frameID == id else { TransitionMarks.mark("?bar"); return false }
        guard TransitionMarks.canvasFrame == id else { TransitionMarks.mark("?canvas"); return false }
        // Its kept picture drawn: the frame's develop as the canvas draws it (the page's own, else the kept one).
        let want = (m.openSession(id)?.developed ?? m.library.frame(id)?.shownDevelop)?.picture
        if want == nil || TransitionMarks.drew == want { return true }
        TransitionMarks.mark("?picture")
        return false
    }

    /// Where the time of each switch went: the page's marks (`TransitionMarks`) from the act, ms, the first of each.
    static func split(_ name: String, _ marks: [(name: String, at: Double)], t0: Double) {
        var seen: [String: (Double, Int)] = [:]
        var order: [String] = []
        for m in marks {
            if let s = seen[m.name] { seen[m.name] = (s.0, s.1 + 1) } else { seen[m.name] = ((m.at - t0) * 1000, 1); order.append(m.name) }
        }
        // The main run loop's turns from the act: when each ended and how long it was awake (the first ends at its commit).
        let turns = TransitionClock.shared.turns.filter { $0.end > t0 && $0.end < t0 + 0.4 && $0.length > 0.001 }.prefix(8)
            .map { String(format: "%.0f–%.0f", (max($0.start, t0) - t0) * 1000, ($0.end - t0) * 1000) }.joined(separator: " ")
        _ = TransitionClock.shared.turns.filter { $0.end > t0 && $0.end < t0 + 0.4 && $0.length > 0.001 }.prefix(6)
            .map { String(format: "%.0f(%.0f)", ($0.end - t0) * 1000, $0.length * 1000) }.joined(separator: " ")
        print("masks-check:   turns \(name): \(turns)")
        let line = order.map { n in String(format: "%@ %.1f%@", n, seen[n]!.0, seen[n]!.1 > 1 ? "×\(seen[n]!.1)" : "") }.joined(separator: " · ")
        print("masks-check:   split \(name): \(line)")
    }

    // MARK: what goes to the next photograph (2.4.0 A2b)

    /// The page kept across a change of photograph must carry nothing of A's to B but what is decided to go (the
    /// commit's list): each item set on A, B chosen, then A again. Kept where nothing is held — the picked row, the lit
    /// tool, mask alone, a zoom and a pan, Undo, a develop of A's in flight — and made again where something is — a
    /// field being typed in, the crop open, a control held; 编辑历史 closes.
    static func leaks(_ m: AppServices, _ r: R, a: LibraryFrame, b: LibraryFrame, one: UUID) async {
        let tools = MaskTools.shared
        func made() -> Int { DevelopController.front?.made ?? -1 }
        func on(_ f: LibraryFrame) async -> OpenFrameSession? {
            MacShellBar.shared.develop?.open(f.id)
            _ = await MacMasksCheck.until(10) { MacShellBar.shared.develop?.frameID == f.id && m.openSession(f.id) != nil }
            await MacMasksCheck.pause(0.5)
            return MacShellBar.shared.develop?.frameID == f.id ? m.openSession(f.id) : nil
        }
        func fitted(_ f: LibraryFrame) -> Bool {
            guard let p = DevelopCanvas.probe else { return false }
            return p.frame == f.id && abs(p.zoom - 1) < 0.001 && p.offset == .zero
        }
        guard MacShellBar.shared.develop?.frameID == a.id, let sa = m.openSession(a.id) else { return r.unreached("leaks: A is not open") }
        await MacMasksCheck.settle(m)

        // 1. Nothing held: the page is kept. A mask layer picked, the brush lit, mask alone on, zoomed to 100 % and panned.
        let kept = made()
        sa.pick(row: .mask(one))
        tools.light(.brush); tools.held = false; tools.alone = true
        NotificationCenter.default.post(name: MacDriver.zoomHundred, object: true)
        await MacMasksCheck.pause(0.4)
        NotificationCenter.default.post(name: DevelopCanvas.checkPan, object: CGSize(width: 60, height: -40))
        await MacMasksCheck.pause(0.3)
        let zoomedA = DevelopCanvas.probe
        _ = await MacMasksCheck.until(5) { MaskOverlay.shared.made?.mode == .alone && MaskOverlay.shared.made?.layer == one }
        r.check(zoomedA?.frame == a.id && (zoomedA?.zoom ?? 1) > 1.01 && zoomedA?.offset != .zero && tools.aloneShown(sa),
                "leaks: on A a layer picked, the brush lit, mask alone shown, zoomed and panned (the case's own setup)",
                "zoom \(zoomedA?.zoom ?? 0), pan \(zoomedA?.offset ?? .zero), alone \(tools.aloneShown(sa))")
        guard let sb = await on(b) else { return r.unreached("leaks: B does not open") }
        r.check(made() == kept, "leaks: nothing held — the page is kept for B, not made again", "made \(kept) → \(made())")
        r.check(fitted(b), "leaks: B's zoom and pan are its own (reset: fitted), not A's 100 % and pan",
                "\(DevelopCanvas.probe.map { "\($0.zoom) \($0.offset)" } ?? "none")")
        r.check(sb.layerPick == .film && !tools.aloneShown(sb), "leaks: B's row is its own (胶片), so A's mask alone is not shown on it")
        r.check(MaskOverlay.shared.made.map { made in sb.maskLayers?[made.layer] != nil } ?? true,
                "leaks: no overlay of A's layer is drawn on B")
        r.check(tools.lit == .brush, "leaks: the lit tool is carried to B (the tools are the page's, as before 2.4.0 A2b)")
        r.check(UndoRedoRecipient.session === sb, "leaks: ⌘Z is B's (the menu bar's recipient is B's session)")
        // Undo walks B's history, never A's.
        let aKept = m.library.frame(a.id)?.edit
        let before = sb.edit.params.exposureCompensationEV
        sb.change { $0.params.exposureCompensationEV = before + 0.5 }
        await m.history.drained()
        await MacMasksCheck.pause(0.3)
        let changed = sb.edit.params.exposureCompensationEV == before + 0.5
        MacShellBar.shared.develop?.undo()
        await m.history.drained()
        await MacMasksCheck.pause(0.3)
        r.check(changed && sb.edit.params.exposureCompensationEV == before && m.library.frame(a.id)?.edit == aKept,
                "leaks: Undo on B after the switch takes B's step back and leaves A's edit as it was",
                "B \(sb.edit.params.exposureCompensationEV) (was \(before)), A unchanged \(m.library.frame(a.id)?.edit == aKept)")
        await MacMasksCheck.settle(m)
        guard let sa2 = await on(a) else { return r.unreached("leaks: A does not open again") }
        r.check(made() == kept && fitted(a) && sa2.layerPick == .film && !tools.aloneShown(sa2),
                "leaks: back on A: the page kept, fitted, its row 胶片 and so no mask alone (A's page starts as a page made for it did)",
                "made \(made()), fitted \(fitted(a)), row \(sa2.layerPick)")
        tools.putDown(); tools.alone = false
        await MacMasksCheck.settle(m)

        // 2. A develop of A's in flight when B is chosen never paints on B.
        TransitionMarks.begin()
        let aEV = sa2.edit.params.exposureCompensationEV
        sa2.change { $0.params.exposureCompensationEV = aEV + 0.7 }
        let aStamp = m.library.frame(a.id).flatMap { f in m.darkroom.stamp(f, edit: sa2.edit, longEdge: f.previewDevelopLongEdge(sa2.edit)) }
        guard let sb2 = await on(b) else { TransitionMarks.end(); return r.unreached("leaks: B does not open (2)") }
        var painted: [String] = []
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if let p = DevelopCanvas.probe, p.frame == b.id, let s = p.stamp, s == aStamp || s != sb2.developed?.stamp { painted.append(s) }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let want = (sb2.developed ?? m.library.frame(b.id)?.shownDevelop)?.picture
        r.check(painted.isEmpty && DevelopCanvas.probe?.frame == b.id && TransitionMarks.drew == want,
                "leaks: a develop of A's under way as B is chosen never reaches B's canvas (4 s watched)",
                "foreign stamps \(painted.count), drawn \(TransitionMarks.drew == want)")
        _ = TransitionMarks.end()
        await MacMasksCheck.settle(m)
        guard let sa3 = await on(a) else { return r.unreached("leaks: A does not open again (2)") }
        sa3.change { $0.params.exposureCompensationEV = aEV }
        await MacMasksCheck.settle(m)

        // 3. A number being typed: taken on A, as a click outside it takes it; the page made again for B.
        sa3.pick(row: .mask(one))
        await MacMasksCheck.pause(0.6)
        let layerEV = sa3.edit.layers?[one]?.scene?.exposure ?? 0
        let field = numberField(showing: layerEV)
        if let field, field.becomeFirstResponder() {
            await MacMasksCheck.pause(0.4)
            if let input = field as? UITextInput, let all = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) {
                input.replace(all, withText: "0.35")
            }
            await MacMasksCheck.pause(0.3)
            let typing = MacKeyFocus.commitEditing != nil
            let made3 = made()
            let bKept = m.library.frame(b.id)?.edit
            guard let sb3 = await on(b) else { return r.unreached("leaks: B does not open (3)") }
            await MacMasksCheck.pause(0.3)
            r.check(typing && made() == made3 + 1, "leaks: a field being typed in: the page is made again for B", "typing \(typing), made \(made3) → \(made())")
            r.check(abs((m.library.frame(a.id)?.edit.layers?[one]?.scene?.exposure ?? 0) - 0.35) < 0.001,
                    "leaks: what was typed is A's (taken as Return takes it, before the switch)",
                    "A's layer exposure \(m.library.frame(a.id)?.edit.layers?[one]?.scene?.exposure ?? .nan)")
            r.check(sb3.edit == bKept && m.library.frame(b.id)?.edit == bKept && MacKeyFocus.commitEditing == nil,
                    "leaks: nothing typed on A reaches B, and no field has the keys on B")
            guard let sa4 = await on(a) else { return r.unreached("leaks: A does not open again (3)") }
            sa4.changeLayer(one) { $0.scene?.exposure = layerEV }
            await MacMasksCheck.settle(m)
        } else {
            r.unreached("leaks: no number field showing \(layerEV) on A's layer page to type in")
        }

        // 4. The crop open: it goes, unwritten, and the page is made again.
        guard let sa5 = m.openSession(a.id) else { return r.unreached("leaks: A's session (4)") }
        sa5.pick(row: .film)
        await MacMasksCheck.pause(0.3)
        let geometry = sa5.edit.geometry
        MacShellBar.shared.develop?.crop()
        _ = await MacMasksCheck.until(5) { m.router.inlineCrop?.frameID == a.id }
        let cropped = m.router.inlineCrop?.frameID == a.id
        let made5 = made()
        guard await on(b) != nil else { return r.unreached("leaks: B does not open (4)") }
        r.check(cropped && m.router.inlineCrop == nil && made() == made5 + 1 && m.library.frame(a.id)?.edit.geometry == geometry,
                "leaks: A's crop open: closed unwritten on the switch, the page made again for B",
                "open \(cropped), crop now \(m.router.inlineCrop.map { "\($0.frameID)" } ?? "none"), made \(made5) → \(made())")
        guard await on(a) != nil else { return r.unreached("leaks: A does not open again (4)") }
        r.check(m.router.inlineCrop == nil, "leaks: back on A the crop is not open")

        // 5. 编辑历史 open: A's history, closed as B is chosen.
        m.router.present(.history(a.id))
        _ = await MacMasksCheck.until(5) { MacHistoryPageModel.shown?.frameID == a.id }
        let shownA = MacHistoryPageModel.shown?.frameID == a.id
        guard await on(b) != nil else { return r.unreached("leaks: B does not open (5)") }
        _ = await MacMasksCheck.until(3) { m.router.sheets.isEmpty }
        r.check(shownA && m.router.sheets.isEmpty, "leaks: A's 编辑历史 closes as B is chosen (never shown over B)")
        await MacMasksCheck.pause(0.6)
        guard await on(a) != nil else { return r.unreached("leaks: A does not open again (5)") }
        r.check(m.router.sheets.isEmpty, "leaks: back on A 编辑历史 is not open")

        // 6. A control held (a slider's press, as `SliderTrack` begins one): the page made again; B never takes the drag.
        guard let sa6 = m.openSession(a.id) else { return r.unreached("leaks: A's session (6)") }
        sa6.began(.shoot)
        let made6 = made()
        let bEdit = m.library.frame(b.id)?.edit
        guard let sb6 = await on(b) else { return r.unreached("leaks: B does not open (6)") }
        r.check(made() == made6 + 1 && !sb6.controlHeld && sb6.edit == bEdit,
                "leaks: a control held on A: the page made again for B, which holds nothing and is unchanged",
                "made \(made6) → \(made()), B held \(sb6.controlHeld)")
        guard await on(a) != nil else { return r.unreached("leaks: A does not open again (6)") }
        await MacMasksCheck.settle(m)
    }

    /// The layer page's number box showing `value` (a slider's `SliderField`), found in the window as UIKit has it.
    static func numberField(showing value: Double) -> UIView? {
        var found: [UIView] = []
        func walk(_ v: UIView) {
            if let t = v as? UITextInput, let all = t.textRange(from: t.beginningOfDocument, to: t.endOfDocument),
               let text = t.text(in: all), let n = SliderField.number(from: text), abs(n - value) < 0.006 { found.append(v) }
            for s in v.subviews { walk(s) }
        }
        for w in UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }) { walk(w) }
        return found.first
    }

    static func photographs(_ m: AppServices, _ r: R, a: LibraryFrame, b: LibraryFrame, n: Int, timed: Timed) async {
        guard let dev = MacShellBar.shared.develop, dev.frameID == a.id else { return r.unreached("transitions: photographs: A is not open") }
        // B developed once (its kept picture made), then A again, each let settle.
        dev.open(b.id)
        _ = await MacMasksCheck.until(60, every: 100) { m.openSession(b.id)?.developed != nil }
        await MacMasksCheck.settle(m)
        MacShellBar.shared.develop?.open(a.id)
        _ = await MacMasksCheck.until(60, every: 100) { m.openSession(a.id)?.developed != nil }
        await MacMasksCheck.settle(m)
        for _ in 0..<n {
            for (from, to) in [(a, b), (b, a)] {
                guard MacShellBar.shared.develop?.frameID == from.id else { return r.unreached("transitions: photographs: \(from.fileName) is not open") }
                let name = from.id == a.id ? "photograph → photograph (A → B)" : "photograph → photograph (B → A)"
                TransitionMarks.begin()
                var t0 = 0.0
                await timed(name, true, { pageShows(m, to.id) }, 20) {
                    t0 = CACurrentMediaTime()
                    MacShellBar.shared.develop?.open(to.id)
                }
                let want = (m.openSession(to.id)?.developed ?? m.library.frame(to.id)?.shownDevelop)?.picture
                print("masks-check:   drew \(name): \(TransitionMarks.drew.map { "\($0)" } ?? "nothing") want \(want.map { "\($0)" } ?? "nothing")")
                split(name, TransitionMarks.end(), t0: t0)
                // Its develop let land before the next, so one switch's develop is never the next one's load.
                _ = await MacMasksCheck.until(60, every: 100) { m.openSession(to.id)?.developed != nil }
                await MacMasksCheck.settle(m)
            }
        }
    }

    static func variants(_ m: AppServices, _ r: R, a: LibraryFrame, timed: Timed,
                         record: (String, Bool, TransitionClock.Sample?) -> Void) async {
        let store = m.macLibrary, fm = FileManager.default
        guard let picture = a.developSource else { return r.unreached("transitions: variants: A has no file") }
        await store.start()
        let work = fm.temporaryDirectory.appending(path: "transitions-catalog-\(UUID().uuidString.prefix(8))")
        let card = work.appending(path: "Card")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.copyItem(at: picture, to: card.appending(path: "T1." + picture.pathExtension))
        defer { try? fm.removeItem(at: work) }
        do {
            let cat = try await store.newCatalog(named: "Transitions", in: work)
            try await store.addFolder(card, to: cat.id)
        } catch { return r.unreached("transitions: variants: no catalog (\(error))") }
        _ = await MacMasksCheck.until(30) { store.images.contains { $0.fileName.hasPrefix("T1.") } }
        await store.select(collection: store.tree.defaultSelection)
        _ = await MacMasksCheck.until(20) { store.images.contains { $0.fileName.hasPrefix("T1.") } }
        guard let cell = store.images.first(where: { $0.fileName.hasPrefix("T1.") }),
              let made = try? await store.frames(for: [cell.id], focus: nil).frames, let frame = made[cell.id] else {
            return r.unreached("transitions: variants: the catalog's picture has no frame")
        }
        guard let s = await MacMasksCheck.develop(m, frame) else { return r.unreached("transitions: variants: the catalog's frame does not open") }
        // A mask layer on it, so a clone carries one.
        s.makeLayer(.gradient, parts: [.linear(MaskLinear(a: MaskPoint(0.5, 0.2), b: MaskPoint(0.5, 0.6)))], stage: .scene)
        if let id = s.layerPick.maskID { s.changeLayer(id) { $0.scene?.exposure = 0.5 } }
        await MacMasksCheck.settle(m)
        let browser = MacLibraryBrowser.shared
        var frames: [LibraryFrame.ID] = [frame]
        for act in [MacVariantActions.Act.new, .clone, .new, .clone] {
            await m.history.drained()
            let before = browser.selection
            let open = MacShellBar.shared.develop?.frameID
            let cells = MacVariantActions.menuCells(m)
            // The selection moved to the new cell, and the page's bar is of its frame: the chrome, before its develop.
            // The new cell is the helper's to make (`CatalogSourcesStore.newVariant`): its round trip is reported apart, and
            // what is gated is the selection from its answer — the selection at once, the page with it (2.4.0 A2b).
            let title = act == .new ? "New Variant (F2)" : "Clone Variant (F3)"
            TransitionMarks.begin()
            var t0 = 0.0
            let chosen = await TransitionClock.shared.time({ t0 = CACurrentMediaTime(); MacVariantActions.shared.perform(act, cells, model: m) },
                                                           shown: { browser.selection != before && !browser.selection.isEmpty }, timeout: 20)
            let answered = TransitionMarks.marks.first { $0.name == "helper<" }.map { ($0.at - t0) * 1000 }
            record("\(title): the helper's round trip", false, answered.map { TransitionClock.Sample(commit: $0, frame: $0, stall: 0, burst: $0) })
            record("\(title): chosen, from the act", false, chosen)
            record("\(title): chosen, from the helper's answer", true, chosen.flatMap { c in
                answered.map { TransitionClock.Sample(commit: c.commit - $0, frame: c.frame - $0, stall: c.stall, burst: c.burst - $0) }
            })
            await timed("\(title): its page", true, {
                (MacShellBar.shared.develop?.frameID).map { $0 != open && pageShows(m, $0) } ?? false
            }, 20) {}
            split(act == .new ? "New Variant" : "Clone Variant", TransitionMarks.end(), t0: t0)
            if let id = MacShellBar.shared.develop?.frameID, id != open { frames.append(id) }
            _ = await MacMasksCheck.until(90, every: 100) { !MacVariantActions.shared.busy && (m.openSession(MacShellBar.shared.develop?.frameID ?? frame)?.developed != nil) }
            await MacMasksCheck.settle(m)
        }
        if sampling == "browser", frames.count > 1 {
            print("masks-check: SAMPLE \(ProcessInfo.processInfo.processIdentifier) browser"); fflush(stdout)
            await MacMasksCheck.pause(0.5)
            let end = Date().addingTimeInterval(5)
            var k = 0
            while Date() < end {
                MacShellBar.shared.develop?.open(frames[k % frames.count]); k += 1
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        // Another variant of the same photograph, from the browser: its row's open.
        for k in 0..<6 where frames.count > 1 {
            let to = frames[k % frames.count] == MacShellBar.shared.develop?.frameID ? frames[(k + 1) % frames.count] : frames[k % frames.count]
            TransitionMarks.begin()
            var t0 = 0.0
            await timed("another variant from the browser", true, { pageShows(m, to) }, 20) {
                t0 = CACurrentMediaTime()
                MacShellBar.shared.develop?.open(to)
            }
            split("another variant", TransitionMarks.end(), t0: t0)
            _ = await MacMasksCheck.until(60, every: 100) { m.openSession(to)?.developed != nil }
            await MacMasksCheck.settle(m)
        }
        m.router.toLibrary()
        await MacMasksCheck.pause(1)
        m.remove(Set(frames.dropFirst()))
        await MacMasksCheck.pause(1)
    }
}
#endif
