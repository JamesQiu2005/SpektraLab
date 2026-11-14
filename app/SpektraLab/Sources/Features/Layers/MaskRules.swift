//  MaskRules.swift — a photograph's mask layers as rules, with no view in them (design/masks/MASKS-SPEC.md §4, §5,
//  §11; PRD-E §4, §9).
//
//  What the panel's mask rows, the layer's page and the session's layer acts share and that is not a drawing: what
//  a new layer is called and how it is numbered within its kind, how many a stage may hold and why one more is
//  refused, which controls each stage's page has and their travel, when a stage switch says its line, and the
//  words for a part ("加 · 主体"). Foundation only, so `tools/masks_selftest.swift` compiles it with the model and
//  holds it, and the panel, the page, the session and `--masks-check` read the same rule.
//
//  **Names are numbered within their kind by the smallest number not in use** (主体 1, 主体 2; a layer renamed or
//  removed frees its number). MASKS-SPEC §4.1 names the kinds; it is silent on reuse, and Capture One's Layers tool
//  reuses a freed number, so this does.

import Foundation

enum MaskRules {
    // MARK: names

    /// How a layer was made, for its name (MASKS-SPEC §4.1): + makes 图层 1 with an empty mask.
    enum Made: String, CaseIterable, Sendable {
        case empty, subject, background, person, allPeople, gradient, brush

        /// "主体 3": the kind's word and its number, as the catalogue spells it. 全部人物 is its own name, numbered only
        /// from its second (MASKS-SPEC §4.1 names 人物 n; the brief: "全部人物 for all").
        func name(_ n: Int) -> String {
            switch self {
            case .allPeople: n == 1 ? L("All People") : L("All People") + " \(n)"
            case .empty: L("Layer \(n)")
            case .subject: L("Subject \(n)")
            case .background: L("Background \(n)")
            case .person: L("Person \(n)")
            case .gradient: L("Gradient \(n)")
            case .brush: L("Brush \(n)")
            }
        }
    }

    /// A new layer's name: its kind's word with the smallest number no layer of the photograph is called by.
    static func name(_ made: Made, among layers: LocalLayers?) -> String {
        let taken = Set((layers?.items ?? []).map(\.name))
        var n = 1
        while taken.contains(made.name(n)) { n += 1 }
        return made.name(n)
    }

    /// A person's layer from 人's menu: 人物 n as the menu numbers them (drawing 10: "点一行即成图层「人物 2」"), or the
    /// smallest number free where that one is taken.
    static func personName(_ number: Int, among layers: LocalLayers?) -> String {
        let taken = Set((layers?.items ?? []).map(\.name))
        let wanted = Made.person.name(number)
        return taken.contains(wanted) ? name(.person, among: layers) : wanted
    }

    /// A duplicate's name: the original's, numbered on (主体 1 → 主体 2), or "… copy" where it ends in no number.
    static func duplicateName(of name: String, among layers: LocalLayers?) -> String {
        let taken = Set((layers?.items ?? []).map(\.name))
        let words = name.split(separator: " ")
        let stem: String, from: Int
        if words.count > 1, let n = Int(words.last!) { stem = words.dropLast().joined(separator: " "); from = n + 1 }
        else { stem = name; from = 2 }
        var n = from
        while taken.contains("\(stem) \(n)") { n += 1 }
        return "\(stem) \(n)"
    }

    // MARK: how many

    /// PRD-E §9 decision 8: 8 a stage (`LocalLayers.perStage`, which the engine's node takes).
    static var perStage: Int { LocalLayers.perStage }

    /// Why one more layer of `stage` cannot be made, or nil when it can.
    static func refusal(adding stage: LayerStage, to layers: LocalLayers?) -> String? {
        (layers ?? LocalLayers()).canAdd(stage) ? nil : stage == .finished
            ? L("A photograph holds at most 8 Finished layers.") : L("A photograph holds at most 8 Scene layers.")
    }

    /// The stage a new layer is made in: the mode in front's (冲洗 → 场景, 编辑 → 成片; MASKS-SPEC §4.3).
    static func stage(for mode: LayerMode) -> LayerStage { mode == .edit ? .finished : .scene }

    // MARK: a stage's controls

    /// 场景's three (RFC-052 §6.1, MASKS-SPEC §5): 曝光 in stops, 色温 and 色调 on the slider's −100…100.
    enum SceneControl: String, CaseIterable, Identifiable, Sendable {
        case exposure, temperature, tint
        var id: String { rawValue }

        var title: String {
            switch self {
            case .exposure: L("Exposure")
            case .temperature: L("Temperature")
            // The decoder's 色调 (MASKS-SPEC §10's note): the light's tint, not Edit's 着色.
            case .tint: L("Tint")
            }
        }

        /// −4…+4 EV (MASKS-SPEC §5); the colours on the slider's own −100…100 (`SceneLayerWire`'s units).
        var range: ClosedRange<Double> { self == .exposure ? -4...4 : -100...100 }

        func text(_ v: Double) -> String {
            self == .exposure ? Fmt.signed(v, decimals: 1) + " EV" : Fmt.signed(v, decimals: 0)
        }

        var keyPath: WritableKeyPath<SceneDeltas, Double> {
            switch self {
            case .exposure: \.exposure
            case .temperature: \.temperature
            case .tint: \.tint
            }
        }
    }

    /// 成片's: Edit's six scalar tools (MASKS-SPEC §5, gap G4), by `AdjustTool`'s raw words — the page shows them in
    /// the order the user set on 胶片's page (`AdjustLayout.order`), filtered to these.
    static let finishedTools = ["brightness", "contrast", "tone", "vibrance", "saturation", "temperature"]

    /// The 成片 deltas' field for one of Edit's scalar controls (`Layer2Control`): nil for one a layer has not (the
    /// vignette, which is the lens's and the frame's).
    static func finishedKeyPath(_ control: Layer2Control) -> WritableKeyPath<FinishedDeltas, Double>? {
        switch control {
        case .exposure: \.exposure
        case .contrast: \.contrast
        case .brightness: \.brightness
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .whites: \.whitePoint
        case .blacks: \.blackPoint
        case .saturation: \.saturation
        case .vibrance: \.vibrance
        case .temperature: \.temperature
        case .tint: \.tint
        case .vignette, .vignetteMidpoint: nil
        }
    }

    /// A 成片 layer's value of `control` as its slider shows it: the field's, but **Blacks is −blackPoint**, as Edit's
    /// own slider reads it (`Adjustments.blacks`; the field keeps `Adjustments.blackPoint`'s sense, RFC-052 §7). Found by
    /// `--masks-check`'s identity: the slider written straight into the field was Edit's Blacks the wrong way round.
    static func finished(_ control: Layer2Control, in d: FinishedDeltas) -> Double? {
        finishedKeyPath(control).map { control == .blacks ? -d[keyPath: $0] : d[keyPath: $0] }
    }

    /// The slider's value written into the layer's field (`finished(_:in:)`'s inverse).
    static func setFinished(_ control: Layer2Control, _ v: Double, in d: inout FinishedDeltas) {
        guard let kp = finishedKeyPath(control) else { return }
        d[keyPath: kp] = control == .blacks ? -v : v
    }

    // MARK: the stage switch (MASKS-SPEC §5, drawing 11)

    /// Whether switching `layer` to the other stage says "这一层的调整已从零开始。" with 撤销: its own stage's
    /// adjustments were not zero, so something was let go of.
    static func restarts(_ layer: LocalLayer) -> Bool {
        switch layer.stage {
        case .scene: !(layer.scene?.isZero ?? true)
        case .finished: !(layer.finished?.isZero ?? true)
        case .enlarger: false
        }
    }

    /// The stage's word, as a row's trailing word and the switch's segment say it.
    static func word(_ stage: LayerStage) -> String {
        switch stage {
        case .scene: L("Scene")
        case .finished: L("Finished")
        case .enlarger: L("Enlarger")
        }
    }

    /// The one line under the switch.
    static func note(_ stage: LayerStage) -> String {
        // Shortened from MASKS-SPEC §10's English, which takes two lines at 11.5 in the running window: UIKit's width of
        // a line under Catalyst is ~4.9 % past AppKit's (368 and 376 against 351 and 359, measured in the window
        // 2026-11-13), and the room is 361 (`--masks-check`). These are 346 and 355 there.
        stage == .finished ? L("Changes the finished picture. The film and print stay as made.")
            : L("Changes the light reaching the film. The film develops again.")
    }

    /// The page's foot row, leading back to 胶片.
    static func foot(_ stage: LayerStage) -> String {
        stage == .finished ? L("Curve, wheels, HSL, channels and lens are Film’s") : L("Film, paper and effects belong to Film")
    }

    /// The menu's switch: "改为作用于成片" with "调整从零开始" under it.
    static func switchTitle(to stage: LayerStage) -> String { stage == .finished ? L("Work on Finished") : L("Work on Scene") }

    // MARK: parts (MASKS-SPEC §5)

    static func word(_ join: MaskPart.Join) -> String {
        switch join {
        case .add: L("Add", as: "a mask's join")
        case .subtract: L("Subtract")
        case .intersect: L("Intersect")
        }
    }

    /// The join's glyph in its 18 disc.
    static func symbol(_ join: MaskPart.Join) -> String {
        switch join {
        case .add: "plus"
        case .subtract: "minus"
        case .intersect: "circle.lefthalf.filled"
        }
    }

    /// The part's own word: 主体, 背景, 人物 n, 全部人物, 线性渐变, 径向渐变, 画笔.
    static func word(_ part: MaskPart) -> String {
        switch part.kind {
        case .linear: return L("Linear Gradient")
        case .radial: return L("Radial Gradient")
        case .brush: return L("Brush")
        case .found:
            guard let f = part.found else { return L("Subject") }
            if f.invert { return L("Background") }
            switch f.what {
            case .subject: return L("Subject")
            case .person: return L("Person \(f.instance + 1)")
            case .people: return L("All People")
            }
        }
    }

    /// The part's glyph (MASKS-SPEC §2's stand-ins; the two gradients are drawn by `MaskGlyph`).
    static func symbol(_ part: MaskPart) -> String {
        switch part.kind {
        case .linear: "linear"
        case .radial: "radial"
        case .brush: "paintbrush.pointed"
        case .found: part.found?.invert == true ? "photo" : part.found?.what == .subject ? "person.crop.rectangle" : "person.fill"
        }
    }

    /// "加 · 主体".
    static func title(_ part: MaskPart) -> String { word(part.join) + " · " + word(part) }

    /// The 蒙版 section's folded head: what its parts are, in order ("主体", "线性渐变 · 画笔").
    static func summary(_ layer: LocalLayer) -> String {
        layer.parts.isEmpty ? "" : layer.parts.map(word).joined(separator: " · ")
    }

    /// 羽化's largest σ, as a share of the long edge: 0.05 (shown 50). MASKS-SPEC and RFC-052 name the unit and not the
    /// travel; Capture One's feather runs to a few hundred pixels, which 5 % of a 24–45 MP frame's long edge is
    /// (300–410 px), and a larger σ over a 4096 plane is a blur of most of the frame.
    static let maxFeather = 0.05

    /// 羽化's value as its pill shows it: the metric σ as a share of the long edge, in hundredths (0 … 100).
    static func featherText(_ feather: Double) -> String { String(Int((feather * 1000).rounded())) }

    /// A row's opacity, said only when not 100 (MASKS-SPEC §2).
    static func opacityText(_ opacity: Double) -> String? {
        let p = Int((min(max(opacity, 0), 1) * 100).rounded())
        return p == 100 ? nil : "\(p) %"
    }
}
