//  MacEditRefreshCheck.swift — a debug build's proof, in the running app, that the develop canvas draws the edit as it
//  stands after each change, in HDR, with nothing rebuilding the view (issue #123, 2026-11-14).
//
//      CFFIXED_USER_HOME=<scratch> SpektraLab --library real --import <folder> --hdr-headroom 16 \
//          --edit-refresh-check <dir> [--edit-refresh-check-break address|sizes]
//
//  `tools/edit_refresh_check.sh` runs it, on a copy of a picture, and brings the app to the front when it says FRONT
//  (the screen's headroom is read only for the scene in front, `HDRScreen.read`). Writes `<dir>/report.json` and
//  exits 0 when every check passes.
//
//  The report on 2.4.0: "多操作几次后，edit 很多选项都无法立即生效，必须要点一下 compare 之类的才能够刷新" (after a few
//  operations many Edit options do not take effect until Compare is clicked). Compare only swaps the branch
//  `DevelopCanvas.printCropped` draws, so the canvas's `Layer2Picture` and its `HDRImage` are built anew. A check that
//  toggled Compare between edits would hide the defect, so this one holds the canvas **without** any rebuild:
//
//  "Current" means both of these hold:
//  - Layer 2's picture is of the edit as it stands (`Layer2Live.shownAdjustments` == the session's);
//  - the canvas's HDR picture draws that picture's own rendition (`HDRImageProbe`: the rendition's source `===` the
//    picture given). The HDR path must be live, or the check refuses: on an SDR screen the defect cannot show.
//
//  The steps:
//  D. **Drags**: twelve slider drags (Brightness, Exposure, Contrast), each twenty steps at the display's rate and a
//     release. Then ten taps (`changeEdit`) 30 ms apart. Each must be current within 3 s.
//  C. **The finished crop** opened and closed (`router.show(.printCrop)`, the inline crop over the canvas), then a
//     drag: current.
//  S. **Compare** on and off twenty times (the bar's own `compare`), then a drag: current.
//
//  `--edit-refresh-check-break address` puts back 2.4.0's match by address (`HDRLatchRules`), and `sizes` its one
//  shared display size (`Layer2DisplaySizes.sharedOnly`). The check must be red on each.
//  Not in a release build.

#if DEBUG
import Foundation
import UIKit

@MainActor
enum MacEditRefreshCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--edit-refresh-check") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        // A relative folder is refused aloud: an app given one used to sit idle for ever (the 2.4.0 round lost 33 minutes).
        guard i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else {
            print("edit-refresh-check: FAIL --edit-refresh-check takes an absolute folder; got \(i + 1 < arguments.count ? arguments[i + 1] : "nothing")")
            exit(2)
        }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let broken = arguments.firstIndex(of: "--edit-refresh-check-break").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        switch broken {
        case "address": HDRLatchRules.broken = "address"
        case "sizes": Layer2DisplaySizes.sharedOnly = true
        case nil: break
        default: print("edit-refresh-check: FAIL unknown --edit-refresh-check-break \(broken!)"); exit(2)
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let r = MacHistoryCheck.Report()
            r.prefix = "edit-refresh-check"
            if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty {
                if let broken { r.note("broken", ["rule": broken]) }
                await run(model, r)
            } else {
                r.check(false, "CFFIXED_USER_HOME is set (the debug build keeps its library where the person's is): refused to run")
            }
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let report: [String: Any] = ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": r.failures.isEmpty,
                                         "broken": broken ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("edit-refresh-check: wrote \(out.appending(path: "report.json").path), \(r.checks) checks, \(r.failures.count) failures")
            model.library.flush()
            await model.macLibrary.host.shutdown()
            exit(r.failures.isEmpty ? 0 : 1)
        }
    }

    // MARK: - what "current" is

    /// The canvas's HDR picture of Edit's layer: the probe's entry given Layer 2's picture.
    private static func canvasEntry(_ live: Layer2Live) -> HDRImageProbe.Drawn? {
        guard let shown = live.shown else { return nil }
        return HDRImageProbe.drawn.values.filter { $0.given === shown }.max { $0.at < $1.at }
    }

    /// The canvas draws the edit as it stands, in HDR.
    private static func current(_ page: OpenFrameSession) -> Bool {
        let live = page.layer2
        guard live.shownAdjustments == page.shownAdjustments, let e = canvasEntry(live) else { return false }
        return e.hdr && e.renditionOf === e.given
    }

    /// What the canvas draws, for a failure's line.
    private static func state(_ page: OpenFrameSession) -> String {
        let live = page.layer2
        let l2 = live.shownAdjustments == page.shownAdjustments ? "Layer 2 current" : (live.shown == nil ? "Layer 2 has no picture" : "Layer 2 behind")
        guard let e = canvasEntry(live) else { return "\(l2); no HDR picture on screen draws it (\(HDRImageProbe.drawn.count) drawn)" }
        let hdr = !e.hdr ? "SDR drawn (look \(e.look), weight \(e.weight))" : (e.renditionOf === e.given ? "its rendition drawn" : "an older picture's rendition drawn")
        return "\(l2); \(hdr)"
    }

    /// Waits for the canvas to be current; the time it took in ms, or nil.
    private static func settled(_ page: OpenFrameSession, within seconds: Double = 3) async -> Int? {
        let t0 = Date()
        let ok = await MacHistoryCheck.until(seconds, every: 10) { current(page) }
        return ok ? Int(Date().timeIntervalSince(t0) * 1000) : nil
    }

    /// One slider drag as `ValueSlider` makes it: began, steps at the display's rate, the lift.
    private static func drag(_ page: OpenFrameSession, _ k: Int) async {
        let tools: [WritableKeyPath<Adjustments, Double>] = [\.brightness, \.exposure, \.contrast]
        let key = tools[k % tools.count]
        let top: Double = key == \Adjustments.exposure ? 1.5 : 30
        let sign: Double = k % 2 == 0 ? 1 : -1
        page.beganEdit()
        for s in 1...20 {
            page.moveEdit { $0[keyPath: key] = sign * top * Double(s) / 20 * (0.5 + Double(k % 5) / 10) }
            try? await Task.sleep(for: .milliseconds(8))
        }
        page.endedEdit()
    }

    // MARK: - the run

    private static func run(_ model: AppServices, _ r: MacHistoryCheck.Report) async {
        let photos = await MacHistoryCheck.photographs(model, atLeast: 1)
        guard let a = photos.first?.id else { r.check(false, "a photograph imported"); return }
        MacDevelopCarry.shared.frames = [a]
        model.router.toLibrary()
        model.router.open(.develop(a))
        guard await MacHistoryCheck.until(30, { model.openSession(a) != nil }), let page = model.openSession(a) else {
            r.check(false, "Develop opens on \(photos[0].fileName)"); return
        }
        r.check(await MacHistoryCheck.until(120, every: 100) { page.developed != nil }, "the photograph develops")
        if !page.edit.hdr { page.switchHDR(true) }
        r.check(await MacHistoryCheck.until(120, every: 100) { page.hdr != nil }, "the session's HDR curve is there (Enable HDR on)")
        // Edit's layer on, so the canvas draws `Layer2Picture`.
        await drag(page, 0)
        print("edit-refresh-check: FRONT \(ProcessInfo.processInfo.processIdentifier)")
        let live = await MacHistoryCheck.until(30, every: 50) { canvasEntry(page.layer2)?.hdr == true }
        r.check(live, "the HDR path is drawn: the canvas shows Edit's picture's rendition (headroom \(HDRScreen.shared.shown); \(state(page)))")
        guard live else { return }

        // D. drags, then taps.
        var times: [Int] = [], behind: [String] = []
        for k in 0..<12 {
            await drag(page, k)
            if let ms = await settled(page) { times.append(ms) } else { behind.append("drag \(k + 1): \(state(page))") }
        }
        for k in 0..<10 {
            page.changeEdit { $0.saturation = Double(k * 7 - 30) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if let ms = await settled(page) { times.append(ms) } else { behind.append("taps: \(state(page))") }
        r.note("D: settled", ["ms": times, "median_ms": times.sorted().dropFirst(times.count / 2).first ?? -1])
        r.check(behind.isEmpty, "D: each of 12 drags and a run of 10 taps is drawn as it stands within 3 s" + (behind.isEmpty ? "" : " — " + behind.joined(separator: "; ")))

        // C. the finished crop over the canvas, opened and closed, then a drag.
        model.router.show(.printCrop(a))
        let inline = await MacHistoryCheck.until(5) { model.router.inlineCrop != nil || model.router.cover != nil }
        r.note("C: the crop", ["inline": model.router.inlineCrop != nil, "cover": model.router.cover != nil])
        r.check(inline, "C: the finished crop opens")
        try? await Task.sleep(for: .seconds(1))
        if model.router.inlineCrop != nil { model.router.inlineCrop = nil } else { model.router.dismissCover() }
        try? await Task.sleep(for: .seconds(1))
        await drag(page, 3)
        let afterCrop = await settled(page)
        r.check(afterCrop != nil, "C: after the crop closes, a drag is drawn as it stands" + (afterCrop == nil ? " — \(state(page))" : ""))

        // S. Compare on and off, the bar's own, then a drag.
        if let bar = MacShellBar.shared.develop, bar.compareEnabled {
            for _ in 0..<20 {
                MacShellBar.shared.develop?.compare()
                try? await Task.sleep(for: .milliseconds(120))
            }
            if MacShellBar.shared.develop?.compareOn == true { MacShellBar.shared.develop?.compare() }
            try? await Task.sleep(for: .milliseconds(500))
            await drag(page, 4)
            let afterCompare = await settled(page)
            r.check(afterCompare != nil, "S: after Compare on and off ×20, a drag is drawn as it stands" + (afterCompare == nil ? " — \(state(page))" : ""))
        } else {
            r.check(false, "S: Compare is enabled on the page (the original is there to compare with)")
        }
    }
}
#endif
