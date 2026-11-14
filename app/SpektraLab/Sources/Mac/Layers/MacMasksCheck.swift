//  MacMasksCheck.swift — a photograph's mask layers in the running app (design/masks/MASKS-SPEC.md §12's table, the
//  cases M1a can hold; PRD-E §7; traps 26, 33, 34).
//
//      CFFIXED_USER_HOME=<scratch> SpektraLab --library real --defaults-suite <name> --import DIR \
//          --masks-check OUT [--masks-check-relaunch RUN1] [--masks-check-hold S] [--capture-window DIR]
//                                                                                   (tools/masks_check.sh)
//
//  Run 1, on a RAW (A) and two pictures (B, C) of the scratch library, each step through what a control calls —
//  the + button's `makeLayer`, −'s `removeLayer`, the eye's `setLayerOn`, the field's `renameLayer`, the switch's
//  `switchStage`, a slider's `beganLayer` / `moveLayer` / `endedLayer`, ⌘Z's `undo`:
//
//    - **panel**: the rows (`LayerRules.rows` over the edit, as the panel reads them) are the model after each of add,
//      remove, eye, rename, stage switch, undo, redo; each act one step, named ("New Layer", "Delete Layer", …);
//    - **stage switch**: the mask's plane the same bytes across it, the other stage's adjustments zero, the notice up,
//      one Undo restoring stage, values and plane;
//    - **neutral**: a layer with nothing to do — empty, inverted at zero, at opacity 0, switched off: the page's develop
//      the same stamp and the same bytes as before it, and Edit's pass the same picture;
//    - **identity**: a full-frame 场景 layer at 曝光 +1 against 胶片曝光 moved by +1 (the develops' block means); each of
//      Edit's eleven scalar controls as a full-frame 成片 layer against Edit's own at the same value (the passes');
//    - **the meter**: a +2 场景 layer over half the frame leaves the solved exposure and the Latitude card's reading;
//    - **应用胶片模拟 off**: a full-frame 场景 layer at +1 develops a brighter picture than none, and a drag of a 成片
//      layer develops nothing;
//    - **a pair**: no mask rows, + and − refused, the foot's line;
//    - **Clone Variant's frame** (`ImportService.cloneFrame`) carries the layers with the edit;
//    - the window captured for drawings 01, 02, 03, 11, 12 (and its folded head), 13 and 18 in English and 简体中文.
//
//  It writes `kept.json` (each frame's rows as written). Run 2 (`--masks-check-relaunch RUN1`) relaunches on the same
//  home: **kept** — the rows, names, opacity and stage read back equal, the clone's too, and an Undo of the last layer
//  act after the relaunch puts the state before it back.
//
//  `report.json` lists every check; exit 0 when all pass. `--self-test` is the shell's (tools/masks_check.sh): it runs
//  run 1 with `--masks-check-break <case>`, which breaks one mapping each, and expects red. Not in a release build.

#if DEBUG && SPK_ENGINE
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UIKit

@MainActor
enum MacMasksCheck {
    final class Report {
        struct Check: Encodable { var name: String; var ok: Bool; var detail: String }
        var checks: [Check] = []
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            checks.append(Check(name: name, ok: ok, detail: detail))
            print("masks-check: \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " -- " + detail)")
            fflush(stdout)
        }
        /// What a check could not reach, said and not counted (a person checks it by hand).
        func unreached(_ text: String) {
            print("masks-check: note \(text)")
            fflush(stdout)
        }
        func write(_ out: URL) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(checks).write(to: out.appendingPathComponent("report.json"))
            print("masks-check: wrote \(out.path)/report.json, \(checks.count) checks, \(checks.filter { !$0.ok }.count) failures")
        }
    }

    /// One frame's rows as kept: what run 2 reads back.
    struct KeptRow: Codable, Equatable { var name: String; var stage: String; var opacity: Double; var on: Bool }
    struct Kept: Codable {
        var frame: UUID; var rows: [KeptRow]; var clone: UUID?; var cloneRows: [KeptRow]; var beforeLast: [KeptRow]
        /// M1b: a frame whose last two steps are strokes, and how many its brush part holds.
        var strokesFrame: UUID? = nil; var strokes: Int? = nil
    }

    static func run(_ model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--masks-check"), i + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let relaunch = arguments.firstIndex(of: "--masks-check-relaunch").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        let broken = arguments.firstIndex(of: "--masks-check-break").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        Task {
            let r = Report()
            if let relaunch { await kept(model, r, run1: relaunch) } else { await walk(model, r, out: out, broken: broken) }
            r.write(out)
            exit(r.checks.allSatisfy(\.ok) && !r.checks.isEmpty ? 0 : 1)
        }
    }

    // MARK: helpers

    static func until(_ s: Double, every ms: Int = 50, _ done: () -> Bool) async -> Bool { await MacHistoryCheck.until(s, every: ms, done) }
    static func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    static func develop(_ m: AppServices, _ id: UUID) async -> OpenFrameSession? {
        m.router.toDevelop(id)
        _ = await until(30) { m.openSession(id) != nil }
        guard let s = m.openSession(id) else { return nil }
        _ = await until(10, every: 5) { !s.historyLoading }
        _ = await until(90, every: 100) { s.developed != nil && s.developedCGImage != nil && !s.isCatchingUp }
        await settle(m)
        return s
    }

    /// Nothing queued or running, the page's picture of the edit as it stands.
    static func settle(_ m: AppServices) async {
        await pause(0.3)
        _ = await until(90, every: 100) { m.scheduler.snapshots.isEmpty }
        await pause(0.3)
    }

    /// The page's develop after an act that asks one (a new stamp), or as it stands after a pause.
    static func developed(_ s: OpenFrameSession, _ m: AppServices, from stamp: String?) async -> CGImage? {
        _ = await until(60, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp }
        await settle(m)
        return s.developedCGImage
    }

    /// Edit's pass on the page at the develop's size, once it is of `expected` (nil: no layer).
    static func shown(_ s: OpenFrameSession, layers expected: String?) async -> CGImage? {
        let live = s.layer2
        guard let base = s.developedCGImage else { return nil }
        live.display(maxPixel: max(base.width, base.height))
        _ = await until(20, every: 100) { live.layers?.key == expected && live.shown?.width == base.width }
        await pause(0.8)
        return live.shown
    }

    /// The window as it stands, for a person: the app's own drawing (`--capture-window`), and with `--masks-check-hold`
    /// a line `masks-check: CAPTURE <name>` and a pause, for the shell's `screencapture -l` of the real window.
    static func capture(_ name: String) async {
        MacHistoryPageCheck.layoutWindows()
        await pause(1.0)
        MacWindowCapture.capture(named: name)
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--masks-check-hold"), i + 1 < a.count, let s = Double(a[i + 1]) {
            print("masks-check: CAPTURE \(name)")
            fflush(stdout)
            await pause(s)
        }
    }

    /// Both languages of one state.
    static func captured(_ name: String) async {
        await capture(name + ".en")
        Language.shared.choose(.simplified)
        await capture(name + ".zh-Hans")
        Language.shared.choose(.english)
        await pause(0.3)
    }

    static func rows(_ s: OpenFrameSession) -> [LayerRow] {
        LayerRules.rows(s.layerPiece, layers: s.shownMaskLayers, lensCorrection: s.edit.decode.lensCorrection, lensWord: s.lensWord,
                        has: { _ in true })
    }

    /// The rows are the model: 胶片, then the layers newest first, each its name, stage, eye and opacity.
    static func rowsAreModel(_ s: OpenFrameSession) -> Bool {
        let r = rows(s)
        let items = (s.maskLayers?.items ?? []).reversed()
        guard r.first?.pick == .film, r.count == items.count + 1 else { return false }
        return zip(r.dropFirst(), items).allSatisfy { row, l in
            row.pick == .mask(l.id) && row.name == l.name && row.stage == l.stage && row.eye == (l.on ? .on : .off)
                && row.opacityText == MaskRules.opacityText(l.opacity)
        }
    }

    static func keptRows(_ layers: LocalLayers?) -> [KeptRow] {
        (layers?.items ?? []).reversed().map { KeptRow(name: $0.name, stage: $0.stage.rawValue, opacity: $0.opacity, on: $0.on) }
    }

    static func lastLabel(_ m: AppServices, _ id: UUID) async -> String {
        await m.history.drained()
        return await MacHistoryCheck.listing(m, id)?.steps.last?.label.text ?? "?"
    }

    /// A full-frame mask: no part, 反相 (how identity is driven before the tools exist).
    static func wholeFrame(_ l: inout LocalLayer) { l.parts = []; l.invert = true }

    // MARK: run 1

    static func walk(_ m: AppServices, _ r: Report, out: URL, broken: String?) async {
        // As many as the shell copied in (three, and a second RAW where it found one): the import lands one by one.
        let given = CommandLine.arguments.firstIndex(of: "--import").flatMap { i in
            i + 1 < CommandLine.arguments.count ? (try? FileManager.default.contentsOfDirectory(atPath: CommandLine.arguments[i + 1]))?.count : nil
        } ?? 3
        let photos = await MacHistoryCheck.photographs(m, atLeast: max(3, given))
        // A: the largest RAW (45 MP); the second RAW, where the shell gave one, is the cost's 24 MP frame.
        let raws = photos.filter(\.isRAW).sorted { $0.originalSize.width * $0.originalSize.height > $1.originalSize.width * $1.originalSize.height }
        guard photos.count >= 3, let a = raws.first ?? photos.first else {
            return r.check(false, "three photographs imported", "\(photos.count)")
        }
        let b24 = raws.dropFirst().first
        // The flat grey frame (M1c step 0b), where the shell gave one: its own case, and none of the others'.
        let flat = photos.first { $0.fileName.contains("flat") }
        let others = photos.filter { $0.id != a.id && $0.id != b24?.id && $0.id != flat?.id }
        let (b, c) = (others[0], others[1])
        // The library's one-time offer to become a catalog would cover the window: Not Now, as a person answers it.
        _ = await until(5) { m.macLibrary.move.showsPage }
        if m.macLibrary.move.showsPage { m.macLibrary.move.notNow(); await pause(1) }
        r.check(true, "photographs", "\(a.fileName) (A), \(b.fileName), \(c.fileName)")
        // A self-test of the tools' geometry runs that case alone (M1b: `MacMaskToolsCheck`).
        // The flat frame's own break first: M1b's geometry case would take any `geometry-` word (and pass on this one).
        if broken == "geometry-halftexel" {
            guard let flat else { return r.check(false, "the flat frame was imported") }
            return await MacMaskFlatCheck.run(m, r, flat: flat, broken: broken)
        }
        if broken?.hasPrefix("geometry-") == true { return await MacMaskToolsCheck.run(m, r, a: a, b24: nil, out: out, broken: broken) }
        // A run of one part alone, while it is being worked on (`MASKS_CHECK_ONLY=find|flat`): not a gate.
        switch ProcessInfo.processInfo.environment["MASKS_CHECK_ONLY"] {
        case "find": return await MacMaskFindCheck.run(m, r, a: a, b: [b, c].first { $0.fileName.contains("bund") } ?? b, out: out, broken: nil)
        // The finding's cases, then M1a's kept: run 2 is M1a's kept case after them (the M1c review's item 1).
        case "findkept":
            await MacMaskFindCheck.run(m, r, a: a, b: [b, c].first { $0.fileName.contains("bund") } ?? b, out: out, broken: nil)
            return await keptRun1(m, r, a: a, c: c, clone: nil, cloneRows: [], out: out)
        case "flat": if let flat { return await MacMaskFlatCheck.run(m, r, flat: flat, broken: nil) }
        case "cost":
            if let b24 { await MacMaskToolsCheck.cost(m, r, a: a, b: b24) }
            return await MacMaskToolsCheck.liveMatches(m, r, a: a)
        case "live": return await MacMaskToolsCheck.liveMatches(m, r, a: a)
        case "transitions": return await MacTransitionsCheck.run(m, r, a: a, b: b24)
        case "keys": if let s = await develop(m, a.id) { return await MacMaskToolsCheck.keys(m, r, s, a: a) }
        case "tools": return await MacMaskToolsCheck.run(m, r, a: a, b24: nil, out: out, broken: nil)
        case "drawkeys":
            await drawings(m, r, a: a.id, c: c.id, out: out)
            if let s = await develop(m, a.id) { return await MacMaskToolsCheck.keys(m, r, s, a: a) }
        default: break
        }
        // And of the finding's rules (M1c: `MacMaskFindCheck`).
        if broken?.hasPrefix("find-") == true { return await MacMaskFindCheck.run(m, r, a: a, b: [b, c].first { $0.fileName.contains("bund") } ?? b, out: out, broken: broken) }
        guard let s = await develop(m, a.id) else { return r.check(false, "A opens in Develop") }
        func act(_ f: () -> Void) async { f(); await pause(0.25) }
        // M1b's keys, pressed for real, first: after M1a's drawings they do not land (`MacMaskToolsCheck.keys`' note).
        if broken == nil { await MacMaskToolsCheck.keys(m, r, s, a: a) }

        // ---- neutral: the page's develop and Edit's pass as without the feature ----
        let base = s.developed?.stamp, basePicture = s.developedCGImage, baseBytes = s.developedCGImage.flatMap(bytes)
        // Edit's pass on a frame with no edit and no acting layer draws nothing (`Layer2Live.shown` is nil while it is
        // neutral): the canvas is the develop itself, as before the feature. A layer that acts would make one.
        _ = await shown(s, layers: nil)
        r.check(baseBytes != nil && !s.layer2.isActive && s.layer2.shown == nil, "neutral: with no layer the pass is idle and the canvas is the develop")
        r.check(LayersPanel.height(s.layerPiece, session: s) == 140 + LayersPanel.margin,
                "the panel with no mask layer is 140 high (\(LayersPanel.height(s.layerPiece, session: s) - LayersPanel.margin))")
        await act { s.makeLayer() }                                                       // +
        let id = s.layerPick.maskID
        var neutral: [(String, Bool)] = []
        func same(_ what: String) async {
            await settle(m)
            let d = s.developed?.stamp == base && s.developedCGImage.flatMap(bytes) == baseBytes && baseBytes != nil
            _ = await shown(s, layers: nil)
            let p = !s.layer2.isActive && s.layer2.shown == nil
            neutral.append((what, d && p))
            r.check(d && p, "neutral: \(what): the develop byte-same, Edit's pass idle", "develop \(d), pass idle \(p)")
        }
        guard let id else { return r.check(false, "+ makes a layer and picks it") }
        await same("an empty layer")
        await act { s.setLayerInverted(id, true) }
        await same("a full mask with its adjustments at zero")
        await act { s.changeLayer(id) { $0.scene?.exposure = 1; $0.opacity = broken == "neutral" ? 0.3 : 0 } }
        await same("曝光 +1 at opacity 0")
        await act { s.changeLayer(id) { $0.opacity = 1; $0.on = false } }
        await same("曝光 +1 switched off")
        await act { s.switchStage(id, to: .finished); s.changeLayer(id) { $0.on = false; $0.finished?.exposure = 1 } }
        await same("a 成片 layer switched off")
        await act { s.removeLayer(id) }

        // ---- identity: 场景 曝光 e against 胶片曝光 + e; each 成片 control against Edit's own ----
        let e = 1.0
        var stamp = s.developed?.stamp
        await act { s.makeLayer(stage: .scene) }
        guard let sid = s.layerPick.maskID else { return r.check(false, "a 场景 layer for identity") }
        await act { s.changeLayer(sid) { wholeFrame(&$0); $0.scene?.exposure = broken == "identity" ? e * 0.5 : e } }
        let layered = await developed(s, m, from: stamp)
        stamp = s.developed?.stamp
        await act { s.removeLayer(sid); s.change { $0.params.exposureCompensationEV += e } }
        let moved = await developed(s, m, from: stamp)
        if let layered, let moved, let plain = basePicture {
            let d = difference(layered, moved), lift = difference(layered, plain)
            r.check(d.mean <= 1.5 && lift.mean > 5,
                    "identity: a full-frame 场景 layer at 曝光 +1 is 胶片曝光 +1 on the canvas",
                    String(format: "mean %.2f, worst %.2f sRGB codes (bar 1.5); the layer moves the picture %.2f from the plain develop", d.mean, d.worst, lift.mean))
            write(layered, out.appendingPathComponent("identity-scene-layer.png")); write(moved, out.appendingPathComponent("identity-film-exposure.png"))
        } else {
            r.check(false, "identity: the two develops landed")
        }
        stamp = s.developed?.stamp
        await act { s.change { $0.params.exposureCompensationEV -= e } }
        _ = await developed(s, m, from: stamp)
        // 成片: each scalar control.
        let values: [Layer2Control: Double] = [.exposure: 0.6, .contrast: 30, .brightness: 25, .highlights: -60, .shadows: 60,
                                               .whites: 30, .blacks: -30, .saturation: -60, .vibrance: 60, .temperature: 50, .tint: 40]
        await act { s.makeLayer(stage: .finished) }
        guard let fid = s.layerPick.maskID else { return r.check(false, "a 成片 layer for identity") }
        for control in Layer2Control.allCases {
            guard let v = values[control], MaskRules.finishedKeyPath(control) != nil else { continue }
            let stampBefore = s.developed?.stamp
            await act { s.changeLayer(fid) { l in wholeFrame(&l); var d = FinishedDeltas(); MaskRules.setFinished(control, broken == "identity" ? v / 2 : v, in: &d); l.finished = d } }
            let key = m.finishedLayers(s.frame!, edit: s.edit)?.key
            let viaLayer = await shown(s, layers: key)
            await act { s.changeLayer(fid) { $0.finished = FinishedDeltas() }; s.changeEdit { $0[control] = v } }
            let viaEdit = await shown(s, layers: nil)
            await act { s.changeEdit { $0[control] = control.rest } }
            // With Edit at rest the pass draws nothing: the canvas is the develop.
            let plain = s.developedCGImage
            if let viaLayer, let viaEdit, let plain {
                let d = difference(viaLayer, viaEdit), lift = difference(viaEdit, plain)
                r.check(d.mean <= 1 && lift.mean > 2 * d.mean + 0.3 && s.developed?.stamp == stampBefore,
                        "identity: 成片 \(control.rawValue) \(v) as a full-frame layer is Edit's own, and develops nothing",
                        String(format: "mean %.2f, worst %.2f (bar 1); the control moves the pass %.2f", d.mean, d.worst, lift.mean))
            } else {
                r.check(false, "identity: 成片 \(control.rawValue): the passes landed")
            }
        }
        await act { s.removeLayer(fid) }

        // ---- the meter: a +2 场景 layer over half the frame ----
        // The meter on (Film Exposure's pill), so there is a solved exposure to hold.
        stamp = s.developed?.stamp
        await act { s.change { $0.params.autoExposure = true } }
        _ = await developed(s, m, from: stamp)
        await settle(m)
        _ = await until(5) { s.latitude != .waiting }
        // The meter's solve is the engine's, reported with each develop (`RunMeasurement.autoExposureEV`): the last
        // canvas develop's. (`FrameEdit.solvedEV` is never written in 2.x.)
        func meter() -> Double? { m.scheduler.records.last { $0.kind == JobKind.canvasDevelop.rawValue && $0.measurement?.autoExposureEV != nil }?.measurement?.autoExposureEV }
        let ev = meter(), reading = s.latitude
        stamp = s.developed?.stamp
        await act {
            s.makeLayer(.gradient, parts: [.linear(MaskLinear(a: MaskPoint(0.49, 0.5), b: MaskPoint(0.51, 0.5)))], stage: .scene)
            if let g = s.layerPick.maskID { s.changeLayer(g) { $0.scene?.exposure = 2 } }
            // The self-test's break: the scene itself moved, which the meter and the card must see.
            if broken == "meter" { s.change { $0.decode.whiteBalance = .custom; $0.decode.temperature = 3000 } }
        }
        _ = await developed(s, m, from: stamp)
        await pause(OpenFrameSession.latitudePause + 1.5)
        _ = await until(10) { s.latitude != .waiting }
        let developsAfter = m.scheduler.records.count
        let meterSame = ev != nil && meter() == ev && s.latitude == reading
        r.check(meterSame, "the meter: a +2 场景 layer over half the frame moves neither the solved exposure nor the Latitude card",
                "the meter \(ev.map { String(format: "%+.3f EV", $0) } ?? "nil") → \(meter().map { String(format: "%+.3f EV", $0) } ?? "nil") (\(developsAfter) jobs), the card's reading the same \(s.latitude == reading)")
        if let g = s.layerPick.maskID { await act { s.removeLayer(g) } }

        // ---- the panel: the rows are the model after each act; each act one step, named ----
        await act { s.makeLayer() }
        guard let p1 = s.layerPick.maskID else { return r.check(false, "panel: + makes a layer") }
        r.check(rowsAreModel(s) && rows(s).count == 2 && s.edit.layers?[p1]?.stage == .scene,
                "panel: + — one row under 胶片, picked, 场景 in 冲洗, named \(s.edit.layers?[p1]?.name ?? "?")")
        r.check(await lastLabel(m, a.id) == "New Layer", "panel: + is one step named New Layer (\(await lastLabel(m, a.id)))")
        s.show(.edit); await pause(0.4)
        await act { s.makeLayer() }
        let p2 = s.layerPick.maskID
        r.check(rowsAreModel(s) && p2.flatMap { s.edit.layers?[$0]?.stage } == .finished && rows(s)[1].pick == p2.map(LayerPick.mask),
                "panel: + in 编辑 — 成片, the newest directly under 胶片")
        s.show(.develop); await pause(0.4)
        r.check(s.layerPick.maskID == p2, "panel: the pick is kept across 冲洗 and 编辑 (G2)")
        await act { s.setLayerOn(p1, false) }
        r.check(rowsAreModel(s) && rows(s)[2].eye == .off, "panel: the eye — the row says off, the edit holds it")
        await act { s.renameLayer(p1, "Sky") }
        r.check(rowsAreModel(s) && rows(s)[2].name == "Sky", "panel: rename in place")
        r.check(await lastLabel(m, a.id) == "Rename Sky", "panel: a rename is one step, named (\(await lastLabel(m, a.id)))")
        await act { s.switchStage(p1, to: .finished) }
        r.check(rowsAreModel(s) && rows(s)[2].stage == .finished, "panel: the stage switch — the row's word follows")
        await act { s.removeLayer(p2!) }
        r.check(rowsAreModel(s) && rows(s).count == 2 && s.layerPick == .mask(p1), "panel: − removes it, asks nothing; the pick moves to the row in its place")
        r.check(await lastLabel(m, a.id) == "Delete Layer", "panel: − is one step named Delete Layer")
        await act { if broken != "panel" { _ = s.undo() } }
        r.check(rowsAreModel(s) && rows(s).count == 3, "panel: Undo brings the layer back")
        await act { _ = s.redo() }
        r.check(rowsAreModel(s) && rows(s).count == 2, "panel: Redo takes it away again")
        let dup = s.duplicateLayer(p1)
        await pause(0.25)
        r.check(rowsAreModel(s) && dup.flatMap { s.edit.layers?[$0]?.name } == "Sky 2", "panel: 复制图层 — a copy, picked, numbered on")
        if let dup { await act { s.removeLayer(dup) } }
        // 8 a stage.
        for _ in 0..<9 { s.makeLayer(stage: .scene) }
        await pause(0.3)
        let scenes = s.edit.layers?.of(.scene).count ?? 0
        r.check(scenes == 8 && s.maskNote == MaskRules.refusal(adding: .scene, to: s.edit.layers), "panel: a ninth 场景 layer is refused with its reason (\(scenes); \(s.maskNote ?? "no note"))")
        await act { s.change { $0.layers = nil } }

        // ---- the stage switch: the plane the same, the adjustments zero, one Undo restores both ----
        await act { s.makeLayer(.gradient, parts: [.linear(MaskLinear(a: MaskPoint(0.5, 0.2), b: MaskPoint(0.5, 0.8)))], stage: .scene) }
        guard let w = s.layerPick.maskID else { return r.check(false, "stage switch: a layer") }
        await act { s.changeLayer(w) { $0.scene?.exposure = 0.7; $0.opacity = 0.6 } }
        let src = a.originalSize
        let before = s.edit.layers![w]!
        let planeBefore = await plane(before, src)
        await act {
            // The self-test's break: the stage written by hand, its old adjustments carried over.
            if broken == "stage" { s.changeLayer(w) { $0.stage = .finished; $0.finished = FinishedDeltas() } }
            else { s.switchStage(w, to: .finished) }
        }
        let after = s.edit.layers![w]!
        let planeAfter = await plane(after, src)
        r.check(planeBefore != nil && planeBefore == planeAfter && after.finished == FinishedDeltas() && after.scene == nil
                && after.name == before.name && after.opacity == 0.6 && after.on && s.stageNotice == w,
                "stage switch: the mask's plane byte-same, the 成片 adjustments zero, name/opacity/eye kept, the notice up")
        await act { _ = s.undo() }
        let undone = s.edit.layers?[w]
        r.check(undone?.stage == .scene && undone?.scene?.exposure == 0.7 && s.stageNotice == nil,
                "stage switch: one Undo brings 场景 and 曝光 +0.7 back, and the notice goes")
        await act { s.change { $0.layers = nil } }

        // ---- the drag path: a 成片 layer's slider develops nothing and commits at the lift ----
        await act { s.makeLayer(stage: .finished) }
        if let d = s.layerPick.maskID {
            await act { s.changeLayer(d) { wholeFrame(&$0) } }
            await settle(m)
            let st = s.developed?.stamp, steps = await MacHistoryCheck.listing(m, a.id)?.steps.count ?? 0
            s.beganLayer()
            for i in 1...20 { s.moveLayer(d) { $0.finished?.brightness = Double(i) } ; try? await Task.sleep(for: .milliseconds(16)) }
            let mid = s.edit.layers?[d]?.finished?.brightness
            s.endedLayer()
            await settle(m)
            let after = await MacHistoryCheck.listing(m, a.id)?.steps.count ?? 0
            r.check(mid == 0 && s.edit.layers?[d]?.finished?.brightness == 20 && s.developed?.stamp == st && after == steps + 1,
                    "drag: a 成片 slider's 20 moves commit nothing until the lift, develop nothing, and are one step (\(after - steps))")
            await act { s.change { $0.layers = nil } }
        }
        // ... and a 场景 layer's develops when the pointer rests.
        await act { s.makeLayer(stage: .scene) }
        if let d = s.layerPick.maskID {
            await act { s.changeLayer(d) { wholeFrame(&$0) } }
            await settle(m)
            let st = s.developed?.stamp
            s.beganLayer()
            s.moveLayer(d) { $0.scene?.exposure = 0.5 }
            let during = s.edit.layers?[d]?.scene?.exposure
            await pause(1.5)
            let rested = s.edit.layers?[d]?.scene?.exposure
            _ = await until(20, every: 100) { s.developed?.stamp != st }
            s.endedLayer()
            r.check(during == 0 && rested == 0.5 && s.developed?.stamp != st, "drag: a 场景 slider commits when the pointer rests, and develops")
            await act { s.change { $0.layers = nil } }
        }
        _ = await developed(s, m, from: nil)

        // ---- Clone Variant's frame carries the layers ----
        await act {
            s.makeLayer(.brush, stage: .scene)
            if let x = s.layerPick.maskID { s.changeLayer(x) { $0.opacity = 0.6 } }
            s.makeLayer(.gradient, stage: .finished)
        }
        let clone = ImportService(model: m).cloneFrame(of: a.id, variant: "masks-check")
        await pause(0.5)
        let cloneRows = keptRows(clone.flatMap { m.library.frame($0)?.edit.layers })
        r.check(clone != nil && cloneRows == keptRows(s.edit.layers) && !cloneRows.isEmpty,
                "Clone Variant's frame carries the layers with the edit (\(cloneRows.map(\.name)))")

        // ---- 应用胶片模拟 off with a 场景 layer ----
        await pause(0.3)
        if let cs = await develop(m, c.id) {
            stamp = cs.developed?.stamp
            await act { cs.change { $0.setAppliesFilm(false) } }
            let off = await developed(cs, m, from: stamp)
            stamp = cs.developed?.stamp
            await act { cs.makeLayer(stage: .scene); if let x = cs.layerPick.maskID { cs.changeLayer(x) { wholeFrame(&$0); $0.scene?.exposure = broken == "digital" ? 0 : 1 } } }
            let lit = await developed(cs, m, from: stamp)
            if let off, let lit {
                let l0 = luma(off), l1 = luma(lit)
                r.check(cs.developed?.stamp != stamp && l1 > l0 + 8, "film off: a full-frame 场景 layer at +1 develops a brighter picture on Apple's decode",
                        String(format: "mean luma %.1f → %.1f", l0, l1))
                write(off, out.appendingPathComponent("film-off-plain.png")); write(lit, out.appendingPathComponent("film-off-layer.png"))
            } else {
                r.check(false, "film off: the develops landed")
            }
            await act { cs.change { $0.layers = nil; $0.setAppliesFilm(true) } }
        }

        // ---- a pair: no mask rows, + and − refused, the foot says why ----
        if let pair = m.makePair(b.id, c.id), let ps = await develop(m, pair) {
            let refusal = LayersPanel.foot(ps.layerPiece, session: ps)
            ps.makeLayer()
            r.check(!LayerRules.takesMasks(ps.layerPiece) && rows(ps).allSatisfy { $0.pick.maskID == nil } && ps.edit.layers == nil
                    && refusal == "Mask layers are for single photographs for now",
                    "a pair: no mask rows, + takes nothing, the foot's line (\(refusal ?? "none"))")
            await captured("13-pair-stands-down")
        } else {
            r.check(false, "a pair made of B and C opens in Develop")
        }

        // ---- the drawings, in the window (not in a self-test's broken run: it is red already) ----
        if broken == nil { await drawings(m, r, a: a.id, c: c.id, out: out) }

        // ---- M1b: the tools on the picture (MASKS-SPEC §12's rows 5, 6, 7; the keys; the cost; drawings 04–07) ----
        if broken == nil { await MacMaskToolsCheck.run(m, r, a: a, b24: b24, out: out, broken: nil) }
        // ---- 2.4.0 A2: how soon each act's state is on the screen (`MacTransitionsCheck`) ----
        if broken == nil { await MacTransitionsCheck.run(m, r, a: a, b: b24) }

        // ---- M1c step 0b: the overlay's edge on the effect's, on a flat frame ----
        if broken == nil, let flat { await MacMaskFlatCheck.run(m, r, flat: flat, broken: nil) }

        // ---- M1c: 主体 · 背景 · 人, 组合蒙版, 完善蒙版…, the geometry mark, the files; drawings 08, 09, 10, 14, 16 ----
        if broken == nil { await MacMaskFindCheck.run(m, r, a: a, b: [b, c].first { $0.fileName.contains("bund") } ?? b, out: out, broken: nil) }

        // ---- kept: what run 2 reads back ----
        await keptRun1(m, r, a: a, c: c, clone: clone, cloneRows: cloneRows, out: out)
    }

    /// What run 2 reads back: two layers on A, the last act a rename; two strokes on C.
    static func keptRun1(_ m: AppServices, _ r: Report, a: LibraryFrame, c: LibraryFrame, clone: UUID?, cloneRows: [KeptRow], out: URL) async {
        func act(_ f: () -> Void) async { f(); await pause(0.25) }
        if let s = await develop(m, a.id) {
            await act { s.change { $0.layers = nil } }
            s.makeLayer(.brush, stage: .scene)
            if let x = s.layerPick.maskID { s.changeLayer(x) { $0.opacity = 0.6; $0.scene?.exposure = 0.4 } }
            s.makeLayer(.gradient, stage: .finished)
            if let x = s.layerPick.maskID { s.setLayerOn(x, false) }
            let beforeLast = keptRows(s.edit.layers)
            if let x = s.layerPick.maskID { s.renameLayer(x, "Sky") }
            await settle(m)
            await m.history.drained()
            var k = Kept(frame: a.id, rows: keptRows(s.edit.layers), clone: clone, cloneRows: cloneRows, beforeLast: beforeLast)
            // M1b: two strokes on C, its last two steps, for run 2's Undo after the relaunch.
            if let cs = await develop(m, c.id) {
                cs.change { $0.layers = nil }
                cs.pick(row: .film)
                MacMaskToolsCheck.stroke(cs, c.id, [MaskPoint(0.3, 0.3), MaskPoint(0.4, 0.35)])
                MacMaskToolsCheck.stroke(cs, c.id, [MaskPoint(0.5, 0.6), MaskPoint(0.6, 0.62)])
                MaskTools.shared.putDown()
                await settle(m)
                await m.history.drained()
                k.strokesFrame = c.id
                k.strokes = cs.edit.layers?.items.first?.parts.first?.brush?.strokes.count
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(k).write(to: out.appendingPathComponent("kept.json"))
            r.check(true, "kept: written", k.rows.map(\.name).joined(separator: ", "))
            m.router.toLibrary()
            await pause(1.5)        // the library and layers.json written as the page leaves
        }
    }

    /// Drawings 01, 02, 03, 11, 12 (and the folded head), 18, in the window, in both languages, on C.
    static func drawings(_ m: AppServices, _ r: Report, a: UUID, c: UUID, out: URL) async {
        guard let s = await develop(m, c) else { return r.check(false, "drawings: C opens in Develop") }
        s.change { $0.layers = nil }
        s.pick(row: .film)
        await settle(m)
        await captured("01-panel-no-masks")
        // 02: after 主体 (a stand-in radial part: found masks are M1c's), 场景, 曝光 +0.7.
        s.makeLayer(.subject, parts: [.radial(MaskRadial(centre: MaskPoint(0.5, 0.45), rx: 0.22, ry: 0.3, feather: 0.4))], stage: .scene)
        if let x = s.layerPick.maskID { s.changeLayer(x) { $0.scene?.exposure = 0.7 } }
        await settle(m)
        MaskPageState.shared.maskOpen = true; MaskPageState.shared.adjustOpen = true
        await captured("02-subject-scene-page")
        await noteIsOneLine(r, .scene)
        r.check(LayersPanel.height(s.layerPiece, session: s) == 254.5 + LayersPanel.margin, "drawing 02: the card is 254.5 with one layer")
        // 11: the stage switched with adjustments that were not zero.
        if let x = s.layerPick.maskID { s.switchStage(x, to: .finished) }
        // (Edit's tools are folded and ordered as the person left them: `AdjustLayout` keeps the app's own defaults
        // domain, which a check must not write. The check's earlier build did, once: see the report.)
        MaskPageState.shared.maskOpen = false
        await settle(m)
        await captured("11-stage-switch")
        // 03: 编辑, a 成片 layer, its six tools.
        s.change { $0.layers = nil }
        s.show(.edit)
        s.makeLayer(.background, parts: [.radial(MaskRadial(centre: MaskPoint(0.5, 0.45), rx: 0.22, ry: 0.3, feather: 0.4))])
        if let x = s.layerPick.maskID { s.changeLayer(x) { $0.finished?.brightness = -18; $0.finished?.exposure = -0.4 } }
        await settle(m)
        await captured("03-finished-layer-edit")
        await noteIsOneLine(r, .finished)
        s.show(.develop)
        // 12: three layers, one off, one at 60 %, the middle picked; then the folded head.
        s.change { $0.layers = nil }
        s.makeLayer(.subject, parts: [.radial(MaskRadial(centre: MaskPoint(0.5, 0.45), rx: 0.22, ry: 0.3, feather: 0.4))], stage: .finished)
        if let x = s.layerPick.maskID { s.setLayerOn(x, false) }
        s.makeLayer(.gradient, parts: [.linear(MaskLinear(a: MaskPoint(0.5, 0.0), b: MaskPoint(0.5, 0.6)))], stage: .scene)
        let mid = s.layerPick.maskID
        if let x = mid { s.changeLayer(x) { $0.opacity = 0.6; $0.scene?.exposure = -1.2 } }
        s.makeLayer(.brush, parts: [.linear(MaskLinear(a: MaskPoint(0.2, 0.8), b: MaskPoint(0.4, 0.6)))], stage: .scene)
        if let x = mid { s.pick(row: .mask(x)) }
        MaskPageState.shared.maskOpen = false
        await settle(m)
        await captured("12-several-layers")
        r.check(LayersPanel.height(s.layerPiece, session: s) == 314.5 + LayersPanel.margin, "drawing 12: the card is 314.5 with three layers")
        LayersStage.shared.foldedForCheck = true
        await captured("12-several-layers-folded")
        r.check(LayerRules.summary(s.layerPick, in: rows(s)) == "3 masks" + Fmt.dot + "Gradient 1", "drawing 12: the folded head says the count and the pick")
        LayersStage.shared.foldedForCheck = false
        // 18: a layer's menu open on its row, three parts on its page.
        s.change { $0.layers = nil }
        s.makeLayer(.brush, parts: [.linear(MaskLinear(a: MaskPoint(0.2, 0.8), b: MaskPoint(0.4, 0.6)))], stage: .scene)
        s.makeLayer(.subject, parts: [
            .radial(MaskRadial(centre: MaskPoint(0.5, 0.45), rx: 0.22, ry: 0.3, feather: 0.4)),
            .linear(MaskLinear(a: MaskPoint(0.5, 1.0), b: MaskPoint(0.5, 0.7)), join: .subtract),
            .radial(MaskRadial(centre: MaskPoint(0.3, 0.3), rx: 0.1, ry: 0.1, feather: 0.6)),
        ], stage: .scene)
        if let x = s.layerPick.maskID {
            s.changeLayer(x) { $0.scene?.exposure = 0.7; $0.parts[1].on = false }
            MaskPageState.shared.maskOpen = true
            await settle(m)
            await menu(on: x, named: "18-layer-menu")
        }
        s.change { $0.layers = nil }
        s.show(.develop)
    }

    /// The stage's note under the switch is one line at the column's real width (MASKS-SPEC §2, §5): measured where it
    /// is laid out, in the running window, with the room and UIKit's own width of both sentences in the detail.
    static func noteIsOneLine(_ r: Report, _ stage: LayerStage) async {
        for lang in [AppLanguage.english, .simplified] {
            Language.shared.choose(lang)
            await pause(0.6)
            let size = MaskPageState.shared.noteSize
            let font = UIFont.systemFont(ofSize: 11.5, weight: .regular)
            let widths = [LayerStage.scene, .finished].map { Int((MaskRules.note($0) as NSString).size(withAttributes: [.font: font]).width.rounded(.up)) }
            r.check(size.height > 0 && size.height < font.lineHeight * 1.5,
                    "the \(stage.rawValue) note is one line in \(lang.rawValue)",
                    String(format: "room %.1f, height %.1f (a line %.1f); UIKit's widths at 11.5 regular: scene %d, finished %d",
                           size.width, size.height, font.lineHeight, widths[0], widths[1]))
        }
        Language.shared.choose(.english)
        await pause(0.3)
    }

    /// A row's menu presented as a secondary click presents it (`_presentMenuAtLocation:`, as `MacVariantActsCheck`),
    /// captured by the shell while it is open, in both languages.
    static func menu(on layer: UUID, named name: String) async {
        for lang in [AppLanguage.english, .simplified] {
            Language.shared.choose(lang)
            MacHistoryPageCheck.layoutWindows()
            await pause(1.0)
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
                  let row = MaskRowFrames.frames[layer] else { print("masks-check: no row for the menu"); continue }
            let point = CGPoint(x: row.midX, y: row.midY)
            func holders(_ v: UIView) -> [UIView] {
                (v.interactions.contains { $0 is UIContextMenuInteraction } ? [v] : []) + v.subviews.flatMap(holders)
            }
            let host = holders(window).filter { $0.convert($0.bounds, to: window).contains(point) }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            guard let host, let interaction = host.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first else {
                print("masks-check: no menu interaction at the row"); continue
            }
            let sel = NSSelectorFromString("_presentMenuAtLocation:")
            guard interaction.responds(to: sel) else { print("masks-check: no _presentMenuAtLocation:"); continue }
            typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let present = unsafeBitCast(interaction.method(for: sel), to: Present.self)
            let tag = name + (lang == .english ? ".en" : ".zh-Hans")
            Task { @MainActor in
                await pause(1.5)
                MacWindowCapture.capture(named: tag)
                print("masks-check: MENU OPEN \(ProcessInfo.processInfo.processIdentifier) \(tag)")
                fflush(stdout)
                await pause(4)
                interaction.dismissMenu()
            }
            present(interaction, sel, host.convert(point, from: window))
            await pause(6.5)
        }
        Language.shared.choose(.english)
    }

    // MARK: run 2

    static func kept(_ m: AppServices, _ r: Report, run1: URL) async {
        // A run of the finding's cases alone (`MASKS_CHECK_ONLY=find`) keeps only theirs.
        if ProcessInfo.processInfo.environment["MASKS_CHECK_ONLY"] == "find" {
            _ = await MacHistoryCheck.photographs(m, atLeast: 3)
            return await MacMaskFindCheck.kept(m, r, run1: run1)
        }
        guard let data = try? Data(contentsOf: run1.appendingPathComponent("kept.json")),
              let k = try? JSONDecoder().decode(Kept.self, from: data) else { return r.check(false, "kept: run 1's kept.json") }
        _ = await MacHistoryCheck.photographs(m, atLeast: 3)
        _ = await until(5) { m.macLibrary.move.showsPage }
        if m.macLibrary.move.showsPage { m.macLibrary.move.notNow(); await pause(1) }
        let read = keptRows(m.library.frame(k.frame)?.edit.layers)
        r.check(read == k.rows && !read.isEmpty, "kept: after a relaunch the rows, names, opacity, stage and eye read back equal (\(read.map(\.name)))")
        if let clone = k.clone {
            let cr = keptRows(m.library.frame(clone)?.edit.layers)
            r.check(cr == k.cloneRows && !cr.isEmpty, "kept: the cloned variant's frame's layers too (\(cr.map(\.name)))")
        }
        guard let s = await develop(m, k.frame) else { return r.check(false, "kept: A opens in Develop") }
        r.check(rowsAreModel(s) && rows(s).count == k.rows.count + 1, "kept: the panel's rows are the kept layers")
        _ = s.undo()
        await pause(0.5)
        r.check(keptRows(s.edit.layers) == k.beforeLast, "kept: an Undo after the relaunch puts the rename back (\(keptRows(s.edit.layers).map(\.name)))")
        _ = s.redo()
        await pause(0.3)
        r.check(keptRows(s.edit.layers) == k.rows, "kept: and Redo takes it again")
        if let f = k.strokesFrame, let n = k.strokes { await MacMaskToolsCheck.kept(m, r, frame: f, strokes: n) }
        else { r.check(false, "kept: run 1 wrote the strokes' frame") }
        await MacMaskFindCheck.kept(m, r, run1: run1)
        m.router.toLibrary()
        await pause(1)
    }

    // MARK: pictures

    static func plane(_ layer: LocalLayer, _ source: PixelSize) async -> [UInt16]? {
        guard let device = MTLCreateSystemDefaultDevice(), let baker = try? SceneLayerWire.baker(for: device),
              let p = try? await baker.bake(layer, source: source) else { return nil }
        return p.values
    }

    static func bytes(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }

    static func luma(_ image: CGImage) -> Double {
        guard let b = blocks(image) else { return 0 }
        return b.reduce(0, +) / Double(b.count)
    }

    static func difference(_ a: CGImage, _ b: CGImage) -> (mean: Double, worst: Double) {
        guard let x = blocks(a), let y = blocks(b) else { return (255, 255) }
        var sum = 0.0, worst = 0.0
        for i in 0..<(x.count / 3) {
            let d = (abs(x[3 * i] - y[3 * i]) + abs(x[3 * i + 1] - y[3 * i + 1]) + abs(x[3 * i + 2] - y[3 * i + 2])) / 3
            sum += d; worst = max(worst, d)
        }
        return (sum / Double(x.count / 3), worst)
    }

    static func blocks(_ image: CGImage, side: Int = 16) -> [Double]? {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var out: [Double] = []
        for i in 0..<(side * side) { out.append(Double(px[4 * i])); out.append(Double(px[4 * i + 1])); out.append(Double(px[4 * i + 2])) }
        return out
    }

    static func write(_ image: CGImage, _ url: URL) { try? UIImage(cgImage: image).pngData()?.write(to: url) }
}
#endif
