//  MacLensCheck.swift — a debug build's proof, in the running app, of 镜头校正's interface (2.4.0, the panel's stage):
//  编辑 › 镜头's part (`LensCorrectionPart`), its 配置文件 popup, Settings › Develop › Lens Profiles, and the race the
//  model stage reported.
//
//      CFFIXED_USER_HOME=<home> SpektraLab --library real --defaults-suite <suite> --import <in> --lens-check <dir> \
//          [--lens-check-lcp <folder>] [--lens-check-adobe <folder>] [--lens-check-hold <s>] [--capture-window <dir>]
//      … --lens-check <dir2> --lens-check-relaunch <dir>
//
//  Run by `tools/lens_check.sh` on copies of a Sony ARW (a-), the Canon EOS R6 Mark III's CR3 (b-), the Ricoh GR II's
//  DNG (c-), an Apple ProRAW (d-) and a JPEG (e-), under a scratch home whose lens database starts empty:
//
//  R. **The race**: a develop asked just as the frame's resolution settles to another corrector (settled here, the
//     moment the request is registered: `EngineHost.registered`) is decoded with the answer its key names
//     (`LensCorrection.applied` against the key's word), never the one that arrived after.
//  P. The part per file: what is enabled, the line's words, the popup's face; the panel captured in English and 简体中文.
//  D. 畸变 at 0, 50 and 100 on the ARW: each a gesture (`began(.shoot)` … `ended()`), each changes the canvas, each one
//     Undo step (three Undos walk them back).
//  I. Install from a small folder of copied `.lcp` files (`--lens-check-lcp`): the counts, the makers, the open GR II
//     resolved again to the database's exact match, the popup's recommendations.
//  C. On the Canon: a database lens chosen as the popup chooses it switches the corrector (Core Image off, the app's
//     step, 畸变 live) and changes the canvas; None turns it off.
//  M. The popup opened as a click opens it, in English and 简体中文 (the shell opens Canon's list by the keyboard and
//     captures it); how long the menu and a maker's list take to make (bars 100 ms and 200 ms).
//  S. Settings › Develop › Lens Profiles, captured in both languages; its rows seen.
//  A. With `--lens-check-adobe`: Adobe's whole folder installed, its time printed, Canon's list measured again with
//     2,000-odd lenses; then removed. Absent, it says SKIPPED.
//  K. Run 2, a relaunch on the same home: the ARW's 畸变 and the Canon's chosen lens kept, the database kept, the
//     Canon resolved to its chosen lens again.

#if DEBUG
import Foundation
import UIKit

@MainActor
enum MacLensCheck {
    final class R {
        struct Check: Encodable { var name: String; var ok: Bool; var detail: String }
        var checks: [Check] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            checks.append(Check(name: name, ok: ok, detail: detail))
            print("lens-check: \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " -- " + detail)")
            fflush(stdout)
        }
        /// A fact the run reports, not counted.
        func note(_ text: String) { print("lens-check: note \(text)"); fflush(stdout) }
        /// What a check could not reach, said and not counted (a person checks it by hand).
        func unreached(_ text: String) { print("lens-check: UNREACHED \(text)"); fflush(stdout) }
        func write(_ out: URL) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(checks).write(to: out.appendingPathComponent("report.json"))
            print("lens-check: wrote \(out.path)/report.json, \(checks.count) checks, \(checks.filter { !$0.ok }.count) failures")
        }
    }

    struct Kept: Codable { var arw: UUID; var canon: UUID; var distortion: Double; var lens: String; var lenses: Int }

    static func run(_ model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--lens-check"), i + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        let relaunch = value("--lens-check-relaunch").map { URL(fileURLWithPath: $0) }
        Task {
            let r = R()
            let started = Date()
            if let relaunch { await kept(model, r, run1: relaunch) } else {
                await walk(model, r, out: out, lcp: value("--lens-check-lcp").map { URL(fileURLWithPath: $0) },
                           adobe: value("--lens-check-adobe").map { URL(fileURLWithPath: $0) }, only: value("--lens-check-only"))
            }
            print(String(format: "lens-check: ran %.1f s", Date().timeIntervalSince(started)))
            r.write(out)
            exit(r.checks.allSatisfy(\.ok) && !r.checks.isEmpty ? 0 : 1)
        }
    }

    // MARK: helpers

    static func until(_ s: Double, every ms: Int = 50, _ done: () -> Bool) async -> Bool { await MacHistoryCheck.until(s, every: ms, done) }
    static func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// The frame on the Edit surface with 镜头 the one section open, its develop landed and its lens resolved.
    static func open(_ m: AppServices, _ id: UUID) async -> OpenFrameSession? {
        for t in AdjustTool.allCases where t != .lens && AdjustLayout.shared.isOpen(t) { AdjustLayout.shared.toggle(t) }
        AdjustLayout.shared.show(.lens)
        guard let s = await MacMasksCheck.develop(m, id) else { return nil }
        s.pageNavigation.surface = .edit
        s.pageNavigation.tool = .adjust
        await resolved(s, m)
        return s
    }

    /// The resolution settled (or none to make), and the develop it asked for landed.
    static func resolved(_ s: OpenFrameSession, _ m: AppServices) async {
        _ = await until(30, every: 50) { s.lensResolution == nil || s.lensResolution?.settled == true }
        await pause(0.3)
        _ = await until(90, every: 100) { !s.isCatchingUp }
        await MacMasksCheck.settle(m)
    }

    static func capture(_ name: String) async {
        MacHistoryPageCheck.layoutWindows()
        await pause(0.5)
        // The column at 镜头校正 (its popup near the top), or Settings' page at its foot, where Lens Profiles is.
        if name.hasPrefix("settings") { scrollToBottom() } else { scrollToPopup() }
        await pause(0.6)
        MacWindowCapture.capture(named: name)
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--lens-check-hold"), i + 1 < a.count, let s = Double(a[i + 1]) {
            print("lens-check: CAPTURE \(name)")
            fflush(stdout)
            await pause(s)
        }
    }

    static func captured(_ name: String) async {
        await capture(name + ".en")
        Language.shared.choose(.simplified)
        await capture(name + ".zh-Hans")
        Language.shared.choose(.english)
        await pause(0.3)
    }

    /// The canvas, 64 × 64, for telling two develops apart.
    static func thumb(_ image: CGImage?) -> [UInt8]? {
        guard let image else { return nil }
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return px
    }

    /// Mean |a − b| over 0–255.
    static func difference(_ a: [UInt8]?, _ b: [UInt8]?) -> Double {
        guard let a, let b, a.count == b.count else { return -1 }
        var d = 0
        for i in 0..<a.count where i % 4 != 3 { d += abs(Int(a[i]) - Int(b[i])) }
        return Double(d) / Double(a.count / 4 * 3)
    }

    /// The page's develop after an act that asks one.
    static func landed(_ s: OpenFrameSession, _ m: AppServices, from stamp: String?) async -> CGImage? {
        _ = await until(90, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp }
        await MacMasksCheck.settle(m)
        return s.developedCGImage
    }

    /// What the part shows, as a person reads it.
    struct Shown: CustomStringConvertible {
        var face: String, line: String, distortion: Bool, hide: Bool, falloff: Bool, corrector: String
        var description: String { "\(corrector): face \"\(face)\", line \"\(line)\", 畸变 \(distortion), 隐藏 \(hide), 光衰减 \(falloff)" }
    }
    static func shown(_ s: OpenFrameSession) -> Shown? {
        guard let r = s.lensResolution else { return nil }
        return Shown(face: LensWords.face(r, pick: s.edit.decode.lensProfile), line: LensWords.line(r), distortion: r.adjustsDistortion,
                     hide: r.adjustsHideDistortedAreas, falloff: r.adjustsLightFalloff, corrector: r.corrector.rawValue)
    }

    // MARK: run 1

    static func walk(_ m: AppServices, _ r: R, out: URL, lcp: URL?, adobe: URL?, only: String?) async {
        let photos = await MacHistoryCheck.photographs(m, atLeast: 5)
        func named(_ prefix: String) -> LibraryFrame? { photos.first { $0.fileName.hasPrefix(prefix) } }
        guard let arw = named("a-"), let canon = named("b-"), let gr = named("c-"), let proraw = named("d-"), let jpeg = named("e-") else {
            return r.check(false, "five photographs imported", photos.map(\.fileName).joined(separator: ", "))
        }
        _ = await until(5) { m.macLibrary.move.showsPage }
        if m.macLibrary.move.showsPage { m.macLibrary.move.notNow(); await pause(1) }
        r.check(LensResolver.database != nil, "the scratch library has a lens database")
        LensLibrary.shared.warm()
        _ = await until(10) { LensLibrary.shared.read }
        r.check(LensLibrary.shared.lensCount == 0, "the lens database starts empty", "\(LensLibrary.shared.lensCount) lenses")

        await race(m, r, arw)
        if only == "race" { return }
        await panels(m, r, [arw, canon, gr, proraw, jpeg])
        await distortion(m, r, arw)
        await install(m, r, gr: gr, canon: canon, lcp: lcp)
        let chosen = await choose(m, r, canon)
        await menu(m, r, canon)
        await settings(m, r)
        await adobeFolder(m, r, adobe, canon: canon, lcp: lcp)
        // What run 2 holds: the ARW at 畸变 50, the Canon on its chosen lens.
        if let s = await open(m, arw.id) {
            MacHistoryCheck.gesture(s) { $0.decode.lensDistortion = 50 }
            await resolved(s, m)
        }
        if let chosen, let s = await open(m, canon.id) {
            s.change { $0.decode.lensCorrection = true; $0.decode.lensProfile = .init(key: chosen.key, name: chosen.name) }
            await resolved(s, m)
        }
        await m.history.drained()
        m.router.toLibrary()
        await pause(1.5)
        let kept = Kept(arw: arw.id, canon: canon.id, distortion: 50, lens: chosen?.key ?? "", lenses: LensLibrary.shared.lensCount)
        try? JSONEncoder().encode(kept).write(to: out.appendingPathComponent("kept.json"))
    }

    // MARK: R. the race

    static func race(_ m: AppServices, _ r: R, _ arw: LibraryFrame) async {
        guard let s = await open(m, arw.id), let url = s.frame?.developSource else { return r.check(false, "R: the ARW opened") }
        let before = s.lensResolution
        r.check(before?.settled == true && before?.corrector == .embedded, "R: the ARW resolves to its own parameters", "\(before.map { "\($0.corrector) \($0.word)" } ?? "none")")
        let path = url.standardizedFileURL.path
        // The moment the develop's request is registered — its key made, its decode not begun — the frame's answer settles
        // to another corrector (nobody: the word ""), as a resolution measured for the first time can.
        var keyed: String?
        let other = LensResolution.Base(corrector: .nobody, why: .noProfile, settled: true)
        EngineHost.registered = { request in
            guard request.frameID == arw.id, keyed == nil else { return }
            keyed = LensCorrection.word(source: request.source, decode: request.decode)
            LensResolver.keep(other, for: request.source, pick: request.decode.lensProfile)
        }
        LensCorrection.applied.withLock { $0[path] = nil }
        let stamp = s.developed?.stamp
        // A change of the decode (its white balance): no picture of it is kept, so the RAW is decoded (an exposure would
        // be made from the kept proxy, which never reads the RAW).
        MacHistoryCheck.gesture(s) { $0.decode.whiteBalance = .daylight; $0.decode.temperature = 5500 }
        _ = await landed(s, m, from: stamp)
        EngineHost.registered = nil
        let applied = LensCorrection.applied.withLock { $0[path] }
        r.check(keyed != nil && applied != nil && keyed == applied,
                "R: a develop asked as the resolution settles is decoded with the corrector its key names",
                "key's word \"\(keyed ?? "?")\", decoded with \"\(applied ?? "?")\"")
        // Put back: the true answer, and the exposure.
        LensResolver.forgetAll()
        s.resolveLens()
        s.undo()
        await resolved(s, m)
        r.check(s.lensResolution?.corrector == .embedded, "R: resolved again, the ARW is its own parameters'")
    }

    // MARK: P. the part per file

    static func panels(_ m: AppServices, _ r: R, _ frames: [LibraryFrame]) async {
        for f in frames {
            guard let s = await open(m, f.id) else { r.check(false, "P: \(f.fileName) opened"); continue }
            let seen = shown(s)
            r.note("P: \(f.fileName): \(seen.map(\.description) ?? "stood down")")
            switch f.fileName.prefix(2) {
            case "a-":
                r.check(seen?.corrector == "embedded" && seen?.distortion == true && seen?.hide == true && seen?.falloff == false
                        && seen?.line == "Corrected from the lens parameters in the file." && seen?.face == "Manufacturer Profile",
                        "P: the Sony ARW: the file's own parameters, 畸变 and 隐藏畸变区域 live, 光衰减 greyed", seen?.description ?? "none")
            case "b-":
                r.check(seen?.corrector == "core-image" && seen?.distortion == false && seen?.falloff == false
                        && seen?.line == "Corrected by macOS's profile of this lens." && seen?.face == "Manufacturer Profile",
                        "P: the Canon CR3: macOS's profile, the amounts greyed (Core Image is all or nothing)", seen?.description ?? "none")
            case "c-":
                r.check(seen != nil && seen?.distortion == (seen?.corrector == "embedded" || seen?.corrector == "database"),
                        "P: the GR II DNG with an empty database: an answer, and the amounts live only where the app corrects", seen?.description ?? "none")
            case "d-":
                r.check(seen?.corrector == "nobody" && seen?.distortion == false && s.recommendedLenses.isEmpty
                        && seen?.line == "Not corrected: this file's lens is corrected already.",
                        "P: the ProRAW: already corrected, nothing live, nothing recommended", seen?.description ?? "none")
            default:
                r.check(seen == nil && s.lensResolution == nil, "P: the JPEG: the part stands down (Lens correction is for RAW files)")
            }
            // Never `why.text` raw: in Chinese the line is not the English.
            if let res = s.lensResolution {
                Language.shared.choose(.simplified)
                let zh = LensWords.line(res)
                Language.shared.choose(.english)
                r.check(zh != res.why.text && zh != LensWords.line(res), "P: \(f.fileName)'s line is looked up, not printed raw", zh)
            }
            await captured("panel-" + String(f.fileName.prefix(1)))
        }
    }

    // MARK: D. 畸变

    static func distortion(_ m: AppServices, _ r: R, _ arw: LibraryFrame) async {
        guard let s = await open(m, arw.id) else { return r.check(false, "D: the ARW opened") }
        var pictures: [Double: [UInt8]] = [100: thumb(s.developedCGImage) ?? []]
        await m.history.drained()
        let steps0 = await MacHistoryCheck.listing(m, arw.id)?.cursorSeq ?? -1
        for amount in [0.0, 50, 100] {
            let stamp = s.developed?.stamp
            // A drag, as the slider makes one: the finger lands, the value passes through, it lifts.
            s.began(.shoot)
            for v in stride(from: s.edit.decode.lensDistortion, through: amount, by: amount < s.edit.decode.lensDistortion ? -10 : 10) {
                s.setLensDistortion(v)
            }
            s.setLensDistortion(amount)
            s.ended()
            pictures[amount + 1000] = thumb(await landed(s, m, from: stamp))
        }
        await m.history.drained()
        let steps1 = await MacHistoryCheck.listing(m, arw.id)?.cursorSeq ?? -1
        let d0 = difference(pictures[100], pictures[1000]), d50 = difference(pictures[1000], pictures[1050])
        let d100 = difference(pictures[1050], pictures[1100]), back = difference(pictures[100], pictures[1100])
        r.check(d0 > 0.3 && d50 > 0.3 && d100 > 0.3 && back < 0.3, "D: 畸变 0, 50, 100 each change the canvas; 100 is where it began",
                String(format: "100→0 %.2f, 0→50 %.2f, 50→100 %.2f, first and last %.2f (of 255)", d0, d50, d100, back))
        r.check(steps1 - steps0 == 3, "D: three drags, three steps of the history", "cursor \(steps0) → \(steps1)")
        var walked: [Double] = []
        for _ in 0..<3 {
            s.undo()
            _ = await until(5) { !s.isDragging }
            walked.append(s.edit.decode.lensDistortion)
        }
        r.check(walked == [50, 0, 100], "D: Undo walks them back one at a time", "\(walked)")
        await resolved(s, m)
        await captured("distortion-at-100")
    }

    // MARK: I. install

    static func install(_ m: AppServices, _ r: R, gr: LibraryFrame, canon: LibraryFrame, lcp: URL?) async {
        guard let lcp else { return r.check(false, "I: a folder of .lcp files was given (--lens-check-lcp)") }
        guard let s = await open(m, gr.id) else { return r.check(false, "I: the GR II opened") }
        let before = s.lensResolution
        let started = Date()
        LensLibrary.shared.install(from: [lcp])
        r.check(LensLibrary.shared.isInstalling, "I: the install runs off the window (Install returns at once)")
        await LensLibrary.shared.installed()
        let took = Date().timeIntervalSince(started)
        let lib = LensLibrary.shared
        r.check(lib.lenses(of: .adobeInstalled) >= 4 && lib.makers.contains("Canon") && lib.makers.contains("Ricoh"),
                "I: the folder's lenses installed, listed by maker", String(format: "%d lenses, makers %@, %.2f s; %@", lib.lenses(of: .adobeInstalled),
                                                                       lib.makers.joined(separator: ", "), took, "\(lib.lastResult.map { "\($0)" } ?? "")"))
        // The open photograph resolved again: the GR II's lens is the database's exact EXIF match now.
        _ = await until(30) { s.lensResolution?.settled == true && s.lensResolution?.corrector == .database }
        await resolved(s, m)
        r.check(s.lensResolution?.corrector == .database && s.lensResolution?.why == .exif,
                "I: the open GR II is resolved again, to the database's exact match",
                "\(before.map { "\($0.corrector)" } ?? "none") → \(s.lensResolution.map { "\($0.corrector) \($0.lens?.name ?? "")" } ?? "none")")
        r.check(s.recommendedLenses.first?.match == .exif, "I: the popup recommends it first", s.recommendedLenses.map(\.lens.name).joined(separator: ", "))
        await captured("panel-c-installed")
    }

    // MARK: C. a database lens on the Canon, and None

    static func choose(_ m: AppServices, _ r: R, _ canon: LibraryFrame) async -> LensDatabase.Lens? {
        guard let s = await open(m, canon.id) else { r.check(false, "C: the Canon opened"); return nil }
        guard let lens = s.recommendedLenses.first?.lens else { r.check(false, "C: a lens is recommended for the Canon"); return nil }
        let plain = thumb(s.developedCGImage)
        var stamp = s.developed?.stamp
        // As the popup's row does (`LensCorrectionPart.act(.lens)`): one change.
        s.change { $0.decode.lensCorrection = true; $0.decode.lensProfile = .init(key: lens.key, name: lens.name) }
        let chose = thumb(await landed(s, m, from: stamp))
        await resolved(s, m)
        let seen = shown(s)
        r.check(seen?.corrector == "database" && seen?.distortion == true && seen?.face == lens.name && seen?.line == "Corrected with \(lens.name).",
                "C: choosing \(lens.name) on the Canon switches the corrector to the app's step, 畸变 live", seen?.description ?? "none")
        r.check(difference(plain, chose) > 0.3, "C: and changes the canvas", String(format: "%.2f of 255", difference(plain, chose)))
        await captured("panel-b-chosen")
        stamp = s.developed?.stamp
        s.setLensCorrection(false)
        let off = thumb(await landed(s, m, from: stamp))
        await resolved(s, m)
        r.check(shown(s)?.corrector == "nobody" && shown(s)?.face == "None" && shown(s)?.line == "Lens correction is off."
                && difference(chose, off) > 0.3, "C: None turns it off", shown(s)?.description ?? "none")
        // Back to automatic: the ↺ of the section (at rest: on, automatic).
        s.resetAdjust(.lens)
        await resolved(s, m)
        r.check(s.adjustIsAtRest(.lens) && s.edit.decode.lensCorrection && s.edit.decode.lensProfile == nil, "C: the section's ↺ puts 镜头校正 at rest")
        return lens
    }

    // MARK: M. the popup

    static func menu(_ m: AppServices, _ r: R, _ canon: LibraryFrame) async {
        guard let s = await open(m, canon.id) else { return r.check(false, "M: the Canon opened") }
        _ = s
        await pause(1)
        guard let coordinator = LensProfilePopUp.lastCoordinator else { return r.check(false, "M: the popup is on the page") }
        // The menu as it opens, made five times; a maker's list as its row makes it.
        var made: [Double] = []
        for _ in 0..<5 {
            let t = DispatchTime.now().uptimeNanoseconds
            _ = coordinator.menu()
            made.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        let canonList = await makerList("Canon")
        r.check((made.max() ?? 999) < 100 && canonList.ms < 200,
                "M: the popup is made within 100 ms, Canon's list within 200 ms",
                String(format: "menu %.2f–%.2f ms; Canon's %d lenses %.1f ms", made.min() ?? -1, made.max() ?? -1, canonList.count, canonList.ms))
        let makers = LensLibrary.shared.makers
        let top = coordinator.menu()
        let titles = top.compactMap { ($0 as? UIMenu)?.children }.map { $0.map(\.title) }
        r.check(titles.count == 4 && titles[0] == ["Manufacturer Profile"] && titles[2] == makers && titles[3] == ["Add .lcp File…", "None"],
                "M: Manufacturer Profile, the recommended, a row per maker, Add .lcp File… and None, between rules", "\(titles)")
        // Opened as a click opens it, both languages: the shell walks to Canon's row with the keyboard and captures it.
        // Down once is the first row (Manufacturer Profile), then each recommended (or its one line), then the makers.
        let downs = 2 + max(1, s.recommendedLenses.count) + (makers.firstIndex(of: "Canon") ?? 0)
        for lang in [AppLanguage.english, .simplified] {
            Language.shared.choose(lang)
            MacHistoryPageCheck.layoutWindows()
            await pause(0.5)
            scrollToPopup()
            await pause(0.8)
            guard let button = LensProfilePopUp.shownButton, let interaction = button.contextMenuInteraction else {
                r.check(false, "M: the popup's button and its menu interaction"); break
            }
            let sel = NSSelectorFromString("_presentMenuAtLocation:")
            guard interaction.responds(to: sel) else { r.unreached("M: no _presentMenuAtLocation: on this system: the open popup is not captured"); break }
            typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let present = unsafeBitCast(interaction.method(for: sel), to: Present.self)
            let tag = "popup." + (lang == .english ? "en" : "zh-Hans")
            Task { @MainActor in
                await pause(1.0)
                print("lens-check: MENU OPEN \(ProcessInfo.processInfo.processIdentifier) \(tag) downs=\(downs)")
                fflush(stdout)
                await pause(7)
                interaction.dismissMenu()
            }
            let t = DispatchTime.now().uptimeNanoseconds
            present(interaction, sel, CGPoint(x: button.bounds.midX, y: button.bounds.midY))
            r.note(String(format: "M: presenting the menu (%@) returned in %.1f ms", tag, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6))
            await pause(9)
        }
        Language.shared.choose(.english)
        if let shown = LensMenuTimes.last["maker Canon"] {
            r.check(shown < 200, "M: Canon's list as the open popup made it", String(format: "%.1f ms", shown))
        } else {
            r.unreached("M: Canon's row was not opened by the keyboard (no time from the open popup; the in-app time above stands)")
        }
    }

    /// A maker's list made as its row makes it: the lenses read and an action made for each.
    static func makerList(_ maker: String) async -> (count: Int, ms: Double) {
        let t = DispatchTime.now().uptimeNanoseconds
        let lenses = await LensLibrary.shared.lenses(maker: maker)
        let items = lenses.map { UIAction(title: $0.name) { _ in } }
        return (items.count, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
    }

    // MARK: S. Settings

    static func settings(_ m: AppServices, _ r: R) async {
        m.router.toLibrary()
        await pause(1)
        SettingsRequest.next = .previewSize
        m.router.show(.settings)
        _ = await until(10) { m.router.cover == .settings }
        await pause(1.5)
        scrollToBottom()
        r.check(["Lens Profiles", "Installed from Adobe", "Added by hand", "Install to SpektraLab"].allSatisfy(MacSettingsCheck.seen.contains)
                && !MacSettingsCheck.seen.contains("Lens Correction"),
                "S: Settings › Develop shows Lens Profiles, and no Lens Correction row",
                "\(LensLibrary.shared.lenses(of: .adobeInstalled)) installed, \(LensLibrary.shared.lenses(of: .user)) by hand, Adobe's on this Mac \(LensLibrary.shared.adobeFiles ?? -1)")
        await captured("settings")
        m.router.dismissCover()
        await pause(1)
    }

    /// The column scrolled so the part's heading stands near its top (the popup at about 160 points down).
    static func scrollToPopup() {
        guard let button = LensProfilePopUp.shownButton else { return }
        var v: UIView? = button.superview
        while let x = v, !(x is UIScrollView) { v = x.superview }
        guard let sv = v as? UIScrollView else { return }
        let y = button.convert(button.bounds, to: sv).minY
        let top = -sv.adjustedContentInset.top, bottom = max(top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: min(max(y - 160, top), bottom)), animated: false)
    }

    /// The Settings page scrolled to its foot, where Lens Profiles is.
    static func scrollToBottom() {
        func scrolls(_ v: UIView) -> [UIScrollView] { (v as? UIScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrolls) }
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            for sv in scrolls(w) where sv.contentSize.height > sv.bounds.height + 20 && sv.bounds.width > 300 {
                sv.setContentOffset(CGPoint(x: 0, y: sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom), animated: false)
            }
        }
    }

    // MARK: A. Adobe's whole folder

    static func adobeFolder(_ m: AppServices, _ r: R, _ adobe: URL?, canon: LibraryFrame, lcp: URL?) async {
        guard let adobe, FileManager.default.fileExists(atPath: adobe.path) else {
            print("lens-check: SKIPPED A: Adobe's lens profiles are not on this Mac (or --lens-check-adobe was not given)")
            return
        }
        let started = Date()
        LensLibrary.shared.install(from: [adobe])
        await LensLibrary.shared.installed()
        let took = Date().timeIntervalSince(started)
        let lib = LensLibrary.shared
        print(String(format: "lens-check: A: Adobe's folder installed in %.1f s: %d lenses, %@", took, lib.lenses(of: .adobeInstalled), "\(lib.lastResult.map { "\($0)" } ?? "")"))
        r.check(lib.lenses(of: .adobeInstalled) > 2000, "A: Adobe's whole folder installed", String(format: "%d lenses in %.1f s", lib.lenses(of: .adobeInstalled), took))
        guard let s = await open(m, canon.id), let coordinator = LensProfilePopUp.lastCoordinator else { return r.check(false, "A: the Canon opened") }
        _ = s
        var made: [Double] = []
        for _ in 0..<5 {
            let t = DispatchTime.now().uptimeNanoseconds
            _ = coordinator.menu()
            made.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        var lists: [String] = []
        var worst = 0.0
        for maker in ["Canon", "Nikon", "Sony", "Sigma"] {
            let l = await makerList(maker)
            worst = max(worst, l.ms)
            lists.append(String(format: "%@ %d in %.1f ms", maker, l.count, l.ms))
        }
        r.check((made.max() ?? 999) < 100 && worst < 200, "A: with Adobe's whole folder the popup is made within 100 ms, a maker's list within 200 ms",
                String(format: "menu %.2f–%.2f ms (%d makers); %@", made.min() ?? -1, made.max() ?? -1, lib.makers.count, lists.joined(separator: ", ")))
        await captured("settings-adobe-installed-panel")
        await lib.remove(.adobeInstalled)
        r.check(lib.lenses(of: .adobeInstalled) == 0, "A: Remove takes Adobe's out again")
        // The small folder again, for run 2 (Remove took its four with Adobe's: one source).
        if let lcp { lib.install(from: [lcp]); await lib.installed() }
    }

    // MARK: K. run 2

    static func kept(_ m: AppServices, _ r: R, run1: URL) async {
        guard let data = try? Data(contentsOf: run1.appendingPathComponent("kept.json")),
              let k = try? JSONDecoder().decode(Kept.self, from: data) else { return r.check(false, "K: run 1's kept.json") }
        _ = await MacHistoryCheck.photographs(m, atLeast: 5)
        _ = await until(5) { m.macLibrary.move.showsPage }
        if m.macLibrary.move.showsPage { m.macLibrary.move.notNow(); await pause(1) }
        LensLibrary.shared.warm()
        _ = await until(10) { LensLibrary.shared.read }
        r.check(LensLibrary.shared.lensCount > 0, "K: the lens database is kept", "\(LensLibrary.shared.lensCount) lenses (run 1 left \(k.lenses))")
        r.check(m.library.frame(k.arw)?.edit.decode.lensDistortion == k.distortion, "K: the ARW's 畸变 is kept",
                "\(m.library.frame(k.arw)?.edit.decode.lensDistortion ?? -1)")
        r.check(m.library.frame(k.canon)?.edit.decode.lensProfile?.key == k.lens && !k.lens.isEmpty, "K: the Canon's chosen lens is kept", k.lens)
        guard let s = await open(m, k.canon) else { return r.check(false, "K: the Canon opened") }
        r.check(s.lensResolution?.corrector == .database && s.lensResolution?.lens?.key == k.lens, "K: and resolves to it after the relaunch",
                shown(s)?.description ?? "none")
        await captured("panel-b-relaunch")
    }
}
#endif
