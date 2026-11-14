// masks_selftest.swift — a photograph's mask layers in the 图层 panel, as rules (design/masks/MASKS-SPEC.md §2–§5,
// §10, §11, §12 step 1).
//
// Compiled with the model, `Features/Layers/LayerRules.swift` and `Features/Layers/MaskRules.swift`
// (tools/selftest.sh): the rows (胶片, then the edit's mask layers newest first) and what each row says (its stage
// as a word, its opacity only when not 100, the eye a switch, the geometry mark); the pick held only while its
// layer is there; ↑ ↓ over mask rows; the card's heights (32 folded, 140 with no mask layer, 224.5 + 30 n to four,
// the cap at 344.5 with the list scrolling inside 150); the page a mask row scopes, the same in both modes; the
// folded head's words ("蒙版 3 · 渐变 1"); a pair and a double take no mask layer and say why; names and numbering
// per kind; 8 a stage; each stage's controls; when a stage switch says its line.
//
// And **every string of MASKS-SPEC §10 this stage shows, measured against its room** in English and 简体中文: the
// widths are AppKit's for the system font at the size and weight the panel and the page draw it in, in units (one
// unit is one point of the develop page's scene: the column is 393), and the zh-Hans words are read from
// `Resources/Localizable.xcstrings` (the path is the first argument). A string the catalog lacks in zh-Hans fails.
//
//   masks_selftest CATALOG [--self-test]   --self-test: each rule broken on purpose, to see it caught.

import AppKit
import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

@main struct MasksSelftest {
    static let rules = ["the newest layer is not under 胶片", "a mask row's stage is not said", "opacity 100 is said",
                        "an off layer's eye is on", "the pick outlives its layer", "the arrows skip the mask rows",
                        "a single photograph's panel is one line", "the card grows past five rows",
                        "a mask row's page is 胶片 in Edit", "the folded head leaves out the count",
                        "a pair takes mask layers", "a new layer reuses a taken name", "a ninth layer of a stage is made",
                        "a 成片 layer's page has the 场景 controls", "a switch from zero says its line",
                        "a label is cut", "a 成片 Blacks is the field's sense",
                        // M1b: the tools on the picture (MASKS-SPEC §6.2, §6.3, §8).
                        "] is not a tenth larger", "⇧] is not ten harder", "an end's turn misses 15°",
                        "an end turns about itself", "⌥ moves one radius", "the feather handle runs the wrong way",
                        "a line wins over a handle", "the pill says 加", "橡皮 joins as 加", "metric is per axis of S"]

    static var catalog: [String: Any] = [:]

    static func main() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        guard let path = args.first, let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            print("usage: masks_selftest Resources/Localizable.xcstrings [--self-test]"); exit(2)
        }
        catalog = strings
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for rule in rules { if checks(rule, quiet: true) > 0 { caught += 1 } else { print("  NOT CAUGHT: \(rule)") } }
            print("masks self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        let failed = checks(nil, quiet: false)
        exit(failed == 0 ? 0 : 1)
    }

    /// The catalog's zh-Hans for an English key (the key as `L` spells it: `%@` for an argument).
    static func zh(_ key: String) -> String? {
        guard let entry = catalog[key] as? [String: Any], let locs = entry["localizations"] as? [String: Any],
              let zh = locs["zh-Hans"] as? [String: Any], let unit = zh["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    /// The width of `text` in the system font, as the panel draws it (`Theme.Font.ui`: `.system(size:weight:)`), **as the
    /// running window lays it out**: AppKit's width times `uikit`. Under Catalyst the window's text is UIKit's, whose
    /// line is wider than AppKit's for the same font and size — measured in the window by `--masks-check` (the stage
    /// note's room 361.2, and UIKit's own widths of the two notes, 2026-11-13): 368 for AppKit's 350.7, 376 for 359.0.
    /// M1a measured AppKit's alone, and the English note took two lines in the window though this passed it.
    static let uikit: CGFloat = 376.0 / 359.0
    static func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width * uikit)
    }

    static func checks(_ broken: String?, quiet: Bool) -> Int {
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failed += 1; if !quiet { print("FAIL: \(name)") } }
        }
        func on(_ rule: String) -> Bool { broken == rule }

        // Three layers, made oldest first: 画笔 1 (场景), 渐变 1 (场景, 60 %), 主体 1 (成片, off).
        var brush = LocalLayer(name: "Brush 1", stage: .scene)
        brush.scene = SceneDeltas(exposure: 0.5)
        var gradient = LocalLayer(name: "Gradient 1", stage: .scene)
        gradient.opacity = 0.6
        var subject = LocalLayer(name: "Subject 1", stage: .finished)
        subject.on = false
        let layers = LocalLayers(items: [brush, gradient, subject])
        let all: (UUID) -> Bool = { _ in true }
        var pair = HalfFramePair()
        pair.left = HalfFramePair.Hole(path: "a.dng", frame: UUID())
        pair.right = HalfFramePair.Hole(path: "b.dng", frame: UUID())
        let double = DoubleExposure(bottom: DoubleExposure.Exposure(frame: UUID()), top: DoubleExposure.Exposure(frame: UUID()), origin: UUID())

        func rows(_ piece: LayerPiece, _ l: LocalLayers?, lens: Bool? = nil) -> [LayerRow] {
            var r = LayerRules.rows(piece, layers: l, lensCorrection: lens, has: all)
            if on("the newest layer is not under 胶片"), r.count > 2 { r = [r[0]] + r.dropFirst().reversed() }
            if on("a mask row's stage is not said") { for i in r.indices { if case .mask = r[i].content { r[i].content = .film } } }
            if on("opacity 100 is said") { for i in r.indices where r[i].opacity == nil && r[i].pick.maskID != nil { r[i].opacity = 1 } }
            if on("an off layer's eye is on") { for i in r.indices where r[i].eye == .off { r[i].eye = .on } }
            if on("a pair takes mask layers"), !piece.isSingle, let l {
                r += l.items.reversed().map { LayerRow(pick: .mask($0.id), name: $0.name, content: .mask(stage: $0.stage)) }
            }
            return r
        }

        // The rows: 胶片, then the newest layer directly under it, the oldest last.
        let r = rows(.single, layers)
        expect(r.map(\.pick) == [.film, .mask(subject.id), .mask(gradient.id), .mask(brush.id)], "胶片, then the mask layers newest first")
        expect(r.map(\.name) == ["Film", "Subject 1", "Gradient 1", "Brush 1"], "each row is its layer's name")
        expect(r.dropFirst().map(\.content) == [.mask(stage: .finished), .mask(stage: .scene), .mask(stage: .scene)],
               "a mask row says its stage")
        expect(r.dropFirst().map(\.opacity) == [nil, 0.6, nil], "a row's opacity only when not 100")
        expect(r[2].opacityText == "60 %" && r[1].opacityText == nil, "\"60 %\" before the stage")
        expect(r.dropFirst().map(\.eye) == [.off, .on, .on] && r[0].eye == .none, "a mask row's eye is a switch: on or off; 胶片 has none")
        expect(r.dropFirst().map(\.key) == ["mask.1", "mask.2", "mask.3"], "the rows' identifiers: layers.row.mask.<n>, top to bottom")
        expect(rows(.single, nil).map(\.pick) == [.film], "no layers: 胶片 alone")
        var moved = brush; moved.madeOn.lensCorrection = true
        moved.parts = [.linear(MaskLinear(a: MaskPoint(0, 0), b: MaskPoint(1, 1)))]
        let marked = rows(.single, LocalLayers(items: [moved]), lens: false)
        expect(marked[1].marked && !rows(.single, LocalLayers(items: [moved]), lens: true)[1].marked && !rows(.single, layers, lens: nil)[1].marked,
               "the geometry mark: lens correction no longer what the mask was made on")

        // The pick.
        func held(_ p: LayerPick, _ piece: LayerPiece, _ l: LocalLayers?) -> LayerPick {
            on("the pick outlives its layer") ? p : LayerRules.held(p, in: piece, layers: l)
        }
        expect(held(.mask(gradient.id), .single, layers) == .mask(gradient.id), "a mask layer's pick is held while the layer is there")
        expect(held(.mask(UUID()), .single, layers) == .film, "a pick whose layer has gone is 胶片")
        expect(held(.mask(gradient.id), .pair(pair), layers) == .film, "a pair has no mask rows to pick")

        // ↑ ↓ walk the mask rows like any row.
        func step(_ p: LayerPick, _ d: Int, _ rs: [LayerRow]) -> LayerPick {
            if on("the arrows skip the mask rows") { return LayerRules.step(p, by: d, in: rs, among: { $0.pick.maskID == nil }) }
            return LayerRules.step(p, by: d, in: rs)
        }
        expect(step(.film, 1, r) == .mask(subject.id) && step(.mask(subject.id), 1, r) == .mask(gradient.id)
               && step(.mask(brush.id), 1, r) == .mask(brush.id) && step(.mask(subject.id), -1, r) == .film, "↑ ↓ over the mask rows, stopping at the ends")

        // The panel and its heights (MASKS-SPEC §2).
        func oneLine(_ piece: LayerPiece) -> Bool { on("a single photograph's panel is one line") ? piece.isSingle : LayerRules.isOneLine(piece) }
        expect(!oneLine(.single) && !oneLine(.pair(pair)) && !oneLine(.double(double)), "nothing is one line on the Mac: a single photograph's panel unfolds")
        func height(_ piece: LayerPiece, _ n: Int, folded: Bool = false) -> CGFloat {
            if on("the card grows past five rows"), n > 4 { return 224.5 + 30 * CGFloat(n) }
            return LayerRules.height(piece, masks: n, folded: folded)
        }
        expect(height(.single, 0) == 140, "a single photograph, no mask layer: 140 (32 + 36 + 36 + 30 + 6)")
        expect(height(.single, 1) == 254.5 && height(.single, 2) == 284.5 && height(.single, 4) == 344.5, "224.5 + 30 n: 254.5, 284.5, 344.5")
        expect(height(.single, 5) == 344.5 && height(.single, 16) == 344.5, "past five rows the card stops at 344.5")
        expect(LayerRules.listHeight(masks: 4) == 150 && LayerRules.listHeight(masks: 9) == 150 && LayerRules.listHeight(masks: 1) == 60,
               "the list scrolls inside 150")
        expect(height(.single, 3, folded: true) == 32, "folded: 32")
        expect(height(.pair(pair), 0) == 128 && height(.double(double), 0) == 172.5, "a pair's and a double's heights are today's")

        // The page a pick scopes.
        func page(_ p: LayerPick, _ mode: LayerMode) -> LayerPage {
            if on("a mask row's page is 胶片 in Edit"), mode == .edit, p.maskID != nil { return .film }
            return LayerRules.page(p, piece: .single, mode: mode, has: all, layers: layers)
        }
        expect(page(.mask(gradient.id), .develop) == .mask(.scene) && page(.mask(gradient.id), .edit) == .mask(.scene),
               "a 场景 layer's page, the same in both modes")
        expect(page(.mask(subject.id), .develop) == .mask(.finished) && page(.mask(subject.id), .edit) == .mask(.finished),
               "a 成片 layer's page, the same in both modes")
        expect(page(.film, .develop) == .film && page(.film, .edit) == .film, "胶片 picked: the column is today's")
        expect(LayerRules.page(.mask(UUID()), piece: .single, mode: .develop, has: all, layers: layers) == .film, "a gone layer's pick: 胶片")
        expect(!LayerPick.mask(subject.id).isPicture, "a mask layer is not a picture (a pair's or a double's page)")

        // The folded head.
        func summary(_ p: LayerPick, _ rs: [LayerRow]) -> String {
            on("the folded head leaves out the count") ? (rs.first { $0.pick == p }?.name ?? "") : LayerRules.summary(p, in: rs)
        }
        expect(summary(.mask(gradient.id), r) == "3 masks" + Fmt.dot + "Gradient 1", "folded: \"蒙版 3 · 渐变 1\"")
        expect(summary(.film, rows(.single, nil)) == "Film", "no mask layer: the picked row's name alone")

        // A pair and a double.
        func takes(_ piece: LayerPiece) -> Bool { on("a pair takes mask layers") ? true : LayerRules.takesMasks(piece) }
        expect(takes(.single) && !takes(.pair(pair)) && !takes(.double(double)), "mask layers: a single photograph's only (M1)")
        expect(rows(.pair(pair), layers).count == 3 && rows(.double(double), layers).count == 3, "a pair's and a double's rows are today's")
        expect(LayerRules.maskRefusal(.pair(pair)) == "Mask layers are for single photographs for now"
               && LayerRules.maskRefusal(.double(double)) != nil && LayerRules.maskRefusal(.single) == nil, "and the foot line says why")

        // Names, numbered within their kind.
        func name(_ made: MaskRules.Made, _ l: LocalLayers?) -> String {
            on("a new layer reuses a taken name") ? made.name(1) : MaskRules.name(made, among: l)
        }
        expect(name(.empty, nil) == "Layer 1" && name(.subject, nil) == "Subject 1" && name(.gradient, nil) == "Gradient 1"
               && name(.brush, nil) == "Brush 1" && name(.background, nil) == "Background 1" && name(.person, nil) == "Person 1",
               "the first of each kind: 图层 1, 主体 1, 渐变 1, 画笔 1, 背景 1, 人物 1")
        expect(name(.gradient, layers) == "Gradient 2" && name(.subject, layers) == "Subject 2" && name(.empty, layers) == "Layer 1",
               "numbered within the kind: 渐变 2 after 渐变 1")
        expect(MaskRules.duplicateName(of: "Gradient 1", among: layers) == "Gradient 2" && MaskRules.duplicateName(of: "Sky", among: nil) == "Sky 2",
               "a duplicate is numbered on")

        // 8 a stage.
        var full = LocalLayers()
        for i in 0..<8 { full.items.append(LocalLayer(name: "Layer \(i + 1)", stage: .scene)) }
        func refused(_ stage: LayerStage, _ l: LocalLayers) -> String? {
            on("a ninth layer of a stage is made") ? nil : MaskRules.refusal(adding: stage, to: l)
        }
        expect(refused(.scene, full) != nil && refused(.finished, full) == nil && refused(.scene, layers) == nil,
               "8 a stage: a ninth 场景 layer is refused, a 成片 one is not")
        expect(MaskRules.stage(for: .develop) == .scene && MaskRules.stage(for: .edit) == .finished, "+ makes the mode in front's stage")

        // Each stage's controls.
        func tools(_ stage: LayerStage) -> [String] {
            if on("a 成片 layer's page has the 场景 controls") { return MaskRules.SceneControl.allCases.map(\.rawValue) }
            return stage == .finished ? MaskRules.finishedTools : MaskRules.SceneControl.allCases.map(\.rawValue)
        }
        expect(tools(.scene) == ["exposure", "temperature", "tint"], "场景: 曝光, 色温, 色调")
        expect(tools(.finished) == ["brightness", "contrast", "tone", "vibrance", "saturation", "temperature"], "成片: Edit's six scalar tools")
        expect(MaskRules.SceneControl.exposure.range == -4...4, "场景's 曝光: −4…+4 EV")
        expect(Layer2Control.allCases.filter { MaskRules.finishedKeyPath($0) != nil }.count == 11
               && MaskRules.finishedKeyPath(.vignette) == nil, "成片's controls: every scalar field of `FinishedDeltas`, the vignette none")
        var fd = FinishedDeltas()
        MaskRules.setFinished(.whites, 7, in: &fd)
        MaskRules.setFinished(.blacks, 9, in: &fd)
        var edit = Adjustments(); edit[.blacks] = 9
        func blacksSign() -> Bool { on("a 成片 Blacks is the field's sense") ? fd.blackPoint == 9 : fd.blackPoint == edit.blackPoint }
        expect(fd.whitePoint == 7 && blacksSign() && MaskRules.finished(.blacks, in: fd) == 9,
               "Whites is the layer's white point; Blacks is −blackPoint, as Edit's own slider (`Adjustments.blacks`)")

        // The stage switch's line.
        func restarts(_ l: LocalLayer) -> Bool { on("a switch from zero says its line") ? true : MaskRules.restarts(l) }
        expect(restarts(brush) && !restarts(gradient), "the line says the adjustments start again only when they were not zero")
        let switched = brush.moved(to: .finished)
        expect(switched.scene == nil && switched.finished == FinishedDeltas() && switched.name == brush.name && switched.opacity == brush.opacity
               && switched.parts == brush.parts && switched.on == brush.on, "a switch keeps the mask, the name, the opacity and the eye; the other stage from zero")

        // ---- M1b: the tools on the picture ----
        // S ↔ metric: a share of the long edge, so a circle is a circle on any aspect (RFC-052 §3).
        let mm = MaskMetric(width: 6000, height: 4000)
        let wide = on("metric is per axis of S") ? CGPoint(x: 0.3, y: 0.6) : mm.metric(MaskPoint(0.3, 0.6))
        expect(abs(wide.x - 0.3) < 1e-12 && abs(wide.y - 0.4) < 1e-12 && abs(mm.source(wide).y - 0.6) < 1e-12,
               "S ↔ metric: (0.3, 0.6) of a 6000 × 4000 picture is (0.3, 0.4) of its long edge, and back")
        // The brush's keys (§6.2): [ ] by a tenth, ⇧[ ⇧] by ten; within their ranges.
        let b0 = BrushSettings(radius: 0.01, hardness: 0.5, flow: 1)
        let larger = on("] is not a tenth larger") ? BrushSettings(radius: 0.012, hardness: 0.5, flow: 1) : b0.larger()
        expect(abs(larger.radius - 0.011) < 1e-12 && abs(b0.smaller().radius - 0.01 / 1.1) < 1e-12, "] and [: larger and smaller by a tenth")
        let harder = on("⇧] is not ten harder") ? BrushSettings(radius: 0.01, hardness: 0.55, flow: 1) : b0.harder()
        expect(abs(harder.hardness - 0.6) < 1e-12 && abs(b0.softer().hardness - 0.4) < 1e-12, "⇧] and ⇧[: harder and softer by ten")
        expect(BrushSettings(radius: 0.25, hardness: 1, flow: 1).larger().radius == 0.25 && BrushSettings(radius: 0.25, hardness: 1, flow: 1).harder().hardness == 1
               && BrushSettings(radius: 0.0005, hardness: 0, flow: 1).smaller().radius == 0.0005 && BrushSettings(radius: 0.0005, hardness: 0, flow: 1).softer().hardness == 0,
               "the keys stop at the ends of their ranges")
        expect(b0.sizePixels(longEdge: 6000) == 120 && abs(BrushSettings.radius(pixels: 120, longEdge: 6000) - 0.01) < 1e-12,
               "大小 is the diameter in the photograph's pixels: 0.01 of a 6000 px edge is 120")
        // The pill (§2, §7): the tool and its size; a join only when it is not the tool's own; none for a plain gradient.
        let pill = on("the pill says 加") ? "Add · Brush · Size 120" : MaskRules.pill(.brush, join: .add, sizePixels: 120)
        expect(pill == "Brush · Size 120" && MaskRules.pill(.brush, join: .subtract, sizePixels: 120) == "Subtract · Brush · Size 120"
               && MaskRules.pill(.eraser, join: .subtract, sizePixels: 80) == "Eraser · Size 80"
               && MaskRules.pill(.linear, join: .add, sizePixels: nil) == nil && MaskRules.pill(.radial, join: .intersect, sizePixels: nil) == "Intersect · Radial Gradient",
               "the pill: the tool and its size, a join only when not its own, none for a plain gradient")
        let eraserJoin = on("橡皮 joins as 加") ? MaskPart.Join.add : MaskTool.eraser.join
        expect(eraserJoin == .subtract && MaskTool.brush.join == .add && MaskTool.brush.other == .eraser && MaskTool.eraser.other == .brush
               && MaskTool.linear.other == .linear, "橡皮 is 画笔 with 减去; ⌥ is the other of the two")
        // 线性渐变 (§6.3): an end turns and stretches about the other, ⇧ in 15° steps; the middle moves both.
        let square = MaskMetric(width: 1000, height: 1000)
        let lin = MaskLinear(a: MaskPoint(0.5, 0.5), b: MaskPoint(0.7, 0.5))
        var turned = MaskHandles.drag(lin, .linearZero, from: CGPoint(x: 0.7, y: 0.5), to: CGPoint(x: 0.7, y: 0.56), steps: true, metric: square)
        if on("an end's turn misses 15°") { turned.b = MaskPoint(0.7, 0.56) }
        if on("an end turns about itself") { turned.a = MaskPoint(0.51, 0.5) }
        let ang = atan2(turned.b.y - 0.5, turned.b.x - 0.5) * 180 / .pi
        expect(turned.a == lin.a && abs(ang - 15) < 1e-9 && abs(hypot(turned.b.x - 0.5, turned.b.y - 0.5) - hypot(0.2, 0.06)) < 1e-9,
               "a linear end turns about the other end, ⇧ to 15° (\(String(format: "%.2f", ang))°), its length the pointer's")
        let movedLin = MaskHandles.drag(lin, .linearMiddle, from: CGPoint(x: 0.6, y: 0.5), to: CGPoint(x: 0.6, y: 0.6), steps: false, metric: square)
        expect(abs(movedLin.a.y - 0.6) < 1e-12 && abs(movedLin.b.y - 0.6) < 1e-12 && movedLin.a.x == 0.5, "the middle's handle moves the gradient whole")
        // 径向渐变: an axis handle sets its radius (⌥ both, in proportion), the turn ring turns, the accent sets the fall.
        let rad = MaskRadial(centre: MaskPoint(0.5, 0.5), rx: 0.2, ry: 0.1, angle: 0, feather: 0.5)
        let one = MaskHandles.drag(rad, .radialAxis(0), from: CGPoint(x: 0.7, y: 0.5), to: CGPoint(x: 0.8, y: 0.5), both: false, steps: false, metric: square)
        var both = MaskHandles.drag(rad, .radialAxis(0), from: CGPoint(x: 0.7, y: 0.5), to: CGPoint(x: 0.8, y: 0.5), both: true, steps: false, metric: square)
        if on("⌥ moves one radius") { both.ry = rad.ry }
        expect(abs(one.rx - 0.3) < 1e-12 && one.ry == 0.1 && abs(both.rx - 0.3) < 1e-12 && abs(both.ry - 0.15) < 1e-12,
               "a radius handle sets its axis; ⌥ both, in proportion")
        let turn = MaskHandles.drag(rad, .radialTurn(0), from: CGPoint(x: 0.75, y: 0.5), to: CGPoint(x: 0.5, y: 0.75), both: false, steps: true, metric: square)
        expect(abs(turn.angle - 90) < 1e-9 && turn.rx == rad.rx, "a drag from just outside a handle turns the ellipse (90°), its radii kept")
        var fall = MaskHandles.drag(rad, .radialFeather, from: .zero, to: CGPoint(x: 0.5 + 0.2 * 0.3, y: 0.5), both: false, steps: false, metric: square)
        if on("the feather handle runs the wrong way") { fall.feather = 0.3 }
        expect(abs(fall.feather - 0.7) < 1e-9, "the accent handle on the dashed ring: at 0.3 of the radius the fall is 0.7 wide")
        let circle = MaskHandles.radial(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.6, y: 0.55), circle: true)
        expect(abs(circle.rx - 0.1) < 1e-12 && abs(circle.ry - 0.1) < 1e-12, "⇧ drags a circle out from its centre")
        // Hit targets (§6.3): 22 round a handle, 8 either side of a line; a handle wins over the line it sits on.
        let hs: [(GradientGrip, CGPoint)] = [(.linearMiddle, CGPoint(x: 100, y: 100)), (.linearFull, CGPoint(x: 60, y: 100))]
        let ls: [(GradientGrip, [CGPoint])] = [(.linearFull, [CGPoint(x: 60, y: 0), CGPoint(x: 60, y: 300)]),
                                               (.linearMiddle, [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 300)])]
        let onHandle = on("a line wins over a handle") ? MaskHandles.grip(at: CGPoint(x: 90, y: 100), handles: [], lines: ls)
            : MaskHandles.grip(at: CGPoint(x: 90, y: 100), handles: hs, lines: ls)
        expect(MaskHandles.grip(at: CGPoint(x: 108, y: 105), handles: hs, lines: ls) == .linearMiddle && onHandle == .linearMiddle
               && MaskHandles.grip(at: CGPoint(x: 67, y: 200), handles: hs, lines: ls) == .linearFull
               && MaskHandles.grip(at: CGPoint(x: 70, y: 200), handles: hs, lines: ls) == nil,
               "a handle within 11, a line within 8 (drags as its handle), nothing past them")

        // MASKS-SPEC §10's strings this stage shows, against their rooms (units), in en and zh-Hans.
        // (key, size, weight, room): the room is what its place leaves it, from §2's numbers.
        let cardInner: CGFloat = 369 - 28           // the card less its 14 each side
        let selection: CGFloat = 108.3 - 11 - 6     // a selection button less its glyph and gap (it has no insets of its own)
        let column: CGFloat = 393 - 32              // the page's rows, 16 each side
        let half: CGFloat = (cardInner - 8) / 2 - 20 // one of the two buttons, less its insets
        var measured: [(String, CGFloat, NSFont.Weight, CGFloat)] = [
            ("Subject", 12.5, .medium, selection), ("Background", 12.5, .medium, selection),
            ("Scene", 12.5, .semibold, 76 - 8), ("Finished", 12.5, .semibold, 76 - 8),
            ("Changes the light reaching the film. The film develops again.", 11.5, .regular, column),
            ("Changes the finished picture. The film and print stay as made.", 11.5, .regular, column),
            ("Adjust", 12.5, .semibold, column - 60),
            ("Undo", 12.5, .semibold, 60),
            ("Film, paper and effects belong to Film", 12.5, .medium, column - 22 - 10 - 20),
            ("Curve, wheels, HSL, channels and lens are Film’s", 12.5, .medium, column - 22 - 10 - 20),
            ("Mask layers are for single photographs for now", 12, .regular, cardInner),
            ("A photograph holds at most 8 Scene layers.", 12, .regular, cardInner),
            ("A photograph holds at most 8 Finished layers.", 12, .regular, cardInner),
            ("Exposure", 13.5, .semibold, 92), ("Temperature", 13.5, .semibold, 92), ("Tint", 13.5, .semibold, 92),
            ("%@ masks", 12, .medium, cardInner - 20 - 60 - 8 - 90),
            // The panel's (MASKS-SPEC §12 step 2) and the page's (step 3).
            ("People", 12.5, .medium, selection - 19),
            ("Opacity", 13.5, .semibold, 64), ("Combine Masks", 12.5, .medium, half - 14), ("Refine Mask…", 12.5, .medium, half),
            ("Works on", 13, .semibold, column - 152 - 8),
            ("Mask", 12.5, .semibold, column - 60), ("Invert", 13, .medium, column - 60), ("Feather", 13, .medium, column - 80),
            ("The mask is empty. Choose a tool and draw it.", 12, .regular, column - 20),
            ("Its adjustments start again from zero.", 12.5, .medium, column - 24 - 16 - 70),
            // The panel's foot wraps (it is measured where it is drawn); one line is what it is drawn for.
            ("This picture is being exported. Its layers wait until the export is done.", 12, .regular, 2 * cardInner),
        ]
        // M1b's: the tool's pill at the tool row's leading end (the four slots, the divider and 8 left to it, less the pill's
        // own insets, glyph and chevron), the popover's labels (64), the picture's tag and the end tags (no room but their
        // own: they are drawn on the picture), the menu's and the keys' titles (a menu's own width).
        let pillWords = cardInner - 4 * 30 - 12.5 - 8 - (20 + 10 + 5 + 8 + 5)
        // The longest pills, composed in each language from the catalog's words: the whole line where it fits, and
        // where it does not (English), the line the pill falls back to (`pillLines`: the tool's name left off).
        for (words, tool) in [(["Subtract", "Brush", "Size {a brush's}"], 1), (["Eraser", "Size {a brush's}"], 0), (["Intersect", "Radial Gradient"], 1)] {
            for zhs in [false, true] {
                var parts = words.map { zhs ? (zh($0) ?? "?") : $0.replacingOccurrences(of: " {a brush's}", with: "") }
                let sized = words.last == "Size {a brush's}"
                if sized { parts[parts.count - 1] += " 1200" }
                let line = parts.joined(separator: " · ")
                var less = parts; less.remove(at: tool)
                let short = less.joined(separator: " · ")
                let fits = width(line, 12, .medium) <= pillWords || (!zhs && width(short, 12, .medium) <= pillWords)
                expect(!line.contains("?") && fits, "the pill \"\(line)\" fits \(Int(pillWords)) at 12, or its short line \"\(short)\" does (\(Int(width(line, 12, .medium))), \(Int(width(short, 12, .medium))))")
            }
        }
        let lines = MaskRules.pillLines(.brush, join: .subtract, sizePixels: 1200)
        expect(lines == ["Subtract · Brush · Size 1200", "Subtract · Size 1200"] && MaskRules.pillLines(.eraser, join: .subtract, sizePixels: 80) == ["Eraser · Size 80", "Size 80"],
               "the pill's lines: whole, then without the tool's name (\(lines))")
        measured += [
            ("Hardness", 13.5, .semibold, 72), ("Flow", 13.5, .semibold, 72),
            ("Mask · %@", 12, .medium, 240), ("100 % line", 11.5, .medium, 120), ("0 % line", 11.5, .medium, 120),
            ("Show Mask", 13, .regular, 220), ("Show Mask Alone", 13, .regular, 220), ("Put the Tool Down", 13, .regular, 220),
            ("Larger Brush", 13, .regular, 220), ("Smaller Brush", 13, .regular, 220), ("Harder Brush", 13, .regular, 220),
            ("Softer Brush", 13, .regular, 220),
        ]
        // A row's name at 13 semibold: what's left of the capsule past the eye, the thumbnail, "60 %" and the stage.
        let rowName: CGFloat = 357 - 72 - 10 - 40 - 10 - 40 - 10
        for key in ["Layer %@", "Subject %@", "Background %@", "Person %@", "Gradient %@", "Brush %@"] {
            measured.append((key, 13, .semibold, rowName))
        }
        if on("a label is cut") { measured.append(("Changes the light reaching the film. The film develops again.", 14, .bold, 200)) }
        for (key, size, weight, room) in measured {
            let en = key.replacingOccurrences(of: "%@", with: "8")
            expect(width(en, size, weight) <= room, "en \"\(en)\" fits \(Int(room)) at \(size) (is \(Int(width(en, size, weight))))")
            guard let z = zh(key) else { expect(false, "zh-Hans has \"\(key)\""); continue }
            let filled = z.replacingOccurrences(of: "%@", with: "8")
            expect(width(filled, size, weight) <= room, "zh \"\(filled)\" fits \(Int(room)) at \(size) (is \(Int(width(filled, size, weight))))")
        }

        if !quiet { print("masks selftest: \(passed) passed, \(failed) failed") }
        return failed
    }
}
