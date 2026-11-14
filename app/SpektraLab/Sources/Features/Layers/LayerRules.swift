//  LayerRules.swift — the 图层 (Layers) panel as rules, with no view in them (design/layers/LAYERS-SPEC.md §4, §5).
//
//  PRD-D §3.7 (the owner, 2026-11-11): one panel, 图层, in both 冲洗 and 编辑; 胶片 always on top, the pictures
//  under it — a pair's 左格 · 右格 (上格 · 下格 turned), a double exposure's 上层 · 下层; a picked row scopes the
//  column. What this file holds is everything of that which is not a drawing: which rows a piece has and in
//  which order, what each is called, what a picked row's page holds in each mode, the eye's three states, where
//  ↑ and ↓ land, and why a piece will not export. Foundation only, so `tools/layers_selftest.swift` compiles it
//  on a Mac with the model and holds it, and the panel, the page and the live check read the same rule.
//
//  **A single photograph's mask layers are rows too** (MASKS-SPEC §3, §4, §11; PRD-E): 胶片, then the edit's mask
//  layers newest first, each saying its stage in a word, its opacity when not 100 and its eye a real switch. M1 has
//  them on a single photograph only (`takesMasks`); a pair's and a double's rows are today's, and their foot says why
//  (`maskRefusal`). What a new layer is called, how many a stage holds and what each stage's page has are
//  `MaskRules.swift`'s.
//
//  **A double's sections are derived, not written twice.** `DoublePanelKind.of` (`DoubleRules.swift`) is the
//  rule for five tabs; a picture's page on the Mac is one scroll, so `sections` asks that rule
//  tab by tab and keeps what is the exposure's own. The self-test holds the two against each other.

import CoreGraphics
import Foundation

/// What the open page is of.
enum LayerPiece: Equatable, Sendable {
    case single
    case pair(HalfFramePair)
    case double(DoubleExposure)

    var isSingle: Bool { self == .single }
}

/// One row of the panel: the film (the whole), or one of its pictures.
enum LayerPick: Hashable, Sendable {
    case film
    /// A half-frame pair's frame.
    case frame(HalfFramePair.Side)
    /// A double exposure's exposure.
    case exposure(DoubleExposure.Position)
    /// A single photograph's mask layer, by its id (`LocalLayer.id`; MASKS-SPEC §11).
    case mask(UUID)

    /// A pair's frame or a double's exposure: a picture with a page of its own. A mask layer is not one.
    var isPicture: Bool {
        switch self {
        case .frame, .exposure: true
        case .film, .mask: false
        }
    }

    /// The mask layer it is, where it is one.
    var maskID: UUID? { if case .mask(let id) = self { id } else { nil } }

    /// The pair's own word for it (`OpenFrameSession.pick`).
    var pairLayer: HalfFramePair.Layer? {
        switch self {
        case .film: .film
        case .frame(let side): HalfFramePair.Layer(side)
        case .exposure, .mask: nil
        }
    }

    /// The double's own word for it (`OpenFrameSession.pickLayer`).
    var doubleLayer: DoubleExposure.Layer? {
        switch self {
        case .film: .film
        case .exposure(let position): DoubleExposure.Layer(position)
        case .frame, .mask: nil
        }
    }

    init(_ layer: HalfFramePair.Layer) { self = layer.side.map(LayerPick.frame) ?? .film }
    init(_ layer: DoubleExposure.Layer) { self = layer.position.map(LayerPick.exposure) ?? .film }

    /// The tail of its accessibility identifier (`layers.row.<key>`), and its name in the log. A mask row's own is
    /// numbered by its place (`LayerRow.key`: `mask.<n>`); the pick alone says `mask`.
    var key: String {
        switch self {
        case .film: "film"
        case .frame(let side): side.key
        case .exposure(let position): position == .top ? "top" : "bottom"
        case .mask: "mask"
        }
    }
}

/// A row as the panel draws it.
struct LayerRow: Equatable, Identifiable, Sendable {
    /// What the row holds.
    enum Content: Equatable, Sendable {
        /// 胶片: the whole.
        case film
        /// A photograph of the library.
        case photograph(UUID)
        /// A photograph that has left the library: its row says so, and can only be replaced or removed.
        case missing(UUID)
        /// A hole or a layer with nothing in it: unexposed film.
        case empty
        /// A mask layer, and the stage it works on (its row's trailing word).
        case mask(stage: LayerStage)
    }

    /// The eye of a double exposure's row (LAYERS-SPEC §6.5): there is no state with nothing shown.
    enum Eye: Equatable, Sendable {
        /// No eye: 胶片, a pair's frame, a double with a layer empty.
        case none
        /// Both exposures are in the picture.
        case shown
        /// This exposure is shown alone.
        case alone
        /// The other exposure is shown alone.
        case out
        /// A mask layer in the picture (MASKS-SPEC §4.2: a real switch, written with the edit).
        case on
        /// A mask layer switched off: its thumbnail and name at 0.38.
        case off
    }

    var pick: LayerPick
    var name: String
    var content: Content
    /// A double exposure's exposure: its share of the frame's light, 0…1; nil unless both layers are filled.
    var share: Double? = nil
    var eye = Eye.none
    /// A mask layer's 不透明度, 0…1, where it is not 1 (the row says "60 %" before its stage); nil otherwise.
    var opacity: Double? = nil
    /// A mask layer whose photograph's geometry changed after its mask was made (MASKS-SPEC §6.5, the accent mark).
    var marked = false
    /// A mask row's place among the mask rows, 1 at the top: its identifier's `mask.<n>`.
    var maskNumber: Int? = nil

    var id: LayerPick { pick }
    /// The tail of its accessibility identifier: `layers.row.<key>`.
    var key: String { maskNumber.map { "mask.\($0)" } ?? pick.key }
    /// "60 %": a mask row's opacity as it says it, only when not 100.
    var opacityText: String? { opacity.flatMap(MaskRules.opacityText) }
    /// A mask row's stage.
    var stage: LayerStage? { if case .mask(let s) = content { s } else { nil } }
    var isEmpty: Bool { content == .empty }
    /// The library photograph in it, when it is there.
    var photograph: UUID? { if case .photograph(let id) = content { id } else { nil } }
    /// "60 %": the row's trailing value.
    /// "60 %". A bottom's is what the top's leaves of 100, so the two rows never read 63 % and 38 %.
    var shareText: String? {
        share.map { s in
            let percent = pick == .exposure(.bottom) ? 100 - Int(((1 - s) * 100).rounded()) : Int((s * 100).rounded())
            return "\(percent) %"
        }
    }
}

/// The mode the column is in.
enum LayerMode: Sendable { case develop, edit }

/// A section of a picture's own page, in the page's order.
enum LayerSection: String, CaseIterable, Sendable {
    /// 摆放: where the picture lies under its hole or on the frame; a double's flip.
    case arrange
    /// A pair's frame: its own stops, where they land, its meter.
    case exposure
    /// A double's exposure: its own stops and meter, folded by default (the review's R4).
    case advanced
    /// The picture's photograph's white balance.
    case whiteBalance
    /// A pair's frame: its own print.
    case enlarger
    /// A pair's frame: whether the back printed on this exposure.
    case dateBack
    /// The photograph itself: its name, Replace, Remove.
    case photograph
}

/// What the column shows under the panel for the picked row.
enum LayerPage: Equatable, Sendable {
    /// 胶片: the column as it is for a photograph, with the piece's own section in 格式.
    case film
    /// A picture: only what is that picture's own.
    case picture([LayerSection])
    /// An empty hole or layer: the way a photograph gets in.
    case empty
    /// Edit with a picture picked: Layer 2 is the piece's, so a picture has none of its own.
    case standsDown
    /// A mask layer: its own page, the same in 冲洗 and 编辑 (MASKS-SPEC §5): the switch, 蒙版, 调整 for its stage.
    case mask(LayerStage)
}

enum LayerRules {
    // MARK: the rows

    /// The panel's rows, top to bottom: 胶片 first, always; a pair's frames in the picture's order, a double's
    /// top before its bottom (the words say so, though the model's list is bottom first); a single photograph's mask
    /// layers newest first (`maskRows`). `lensCorrection`: the edit's, for the geometry mark; nil marks nothing.
    /// `lensWord`: whose correction it is (`OpenFrameSession.lensWord`).
    static func rows(_ piece: LayerPiece, layers: LocalLayers? = nil, lensCorrection: Bool? = nil, lensWord: String = "",
                     alone: DoubleExposure.Position? = nil, has: (UUID) -> Bool) -> [LayerRow] {
        var out = [LayerRow(pick: .film, name: L("Film"), content: .film)]
        switch piece {
        case .single:
            if takesMasks(piece) { out += maskRows(layers, lensCorrection: lensCorrection, lensWord: lensWord) }
        case .pair(let pair):
            for side in HalfFramePair.Side.allCases {
                out.append(LayerRow(pick: .frame(side), name: pair.title(HalfFramePair.Layer(side)),
                                    content: content(pair[side]?.frame, held: pair[side] != nil, has: has)))
            }
        case .double(let double):
            let shown = self.alone(alone, in: double, has: has)
            let balanced = double.isFilled
            for position in [DoubleExposure.Position.top, .bottom] {
                let c = content(double[position]?.frame, held: double[position] != nil, has: has)
                let share = double.balance.map { position == .top ? $0 : 1 - $0 }
                let eye: LayerRow.Eye = !eyes(double, has: has) ? .none : shown == nil ? .shown : shown == position ? .alone : .out
                out.append(LayerRow(pick: .exposure(position), name: DoubleExposure.Layer(position).title, content: c,
                                    share: balanced ? share : nil, eye: eye))
            }
        }
        return out
    }

    /// A photograph's mask layers as rows: **the newest directly under 胶片** (the model keeps them newest last), each
    /// with its stage, its eye, its opacity where it is not 100 and the geometry mark (MASKS-SPEC §4.1, §4.2).
    static func maskRows(_ layers: LocalLayers?, lensCorrection: Bool? = nil, lensWord: String = "") -> [LayerRow] {
        let items = (layers?.items ?? []).filter { $0.stage != .enlarger }
        return items.reversed().enumerated().map { i, l in
            LayerRow(pick: .mask(l.id), name: l.name, content: .mask(stage: l.stage), eye: l.on ? .on : .off,
                     opacity: MaskRules.opacityText(l.opacity) == nil ? nil : l.opacity,
                     marked: isMarked(l, lensCorrection: lensCorrection, lensWord: lensWord), maskNumber: i + 1)
        }
    }

    /// The geometry mark: the photograph's lens correction is no longer what the mask was made on, and there is a mask
    /// to have moved (MASKS-SPEC §6.5). Drawn by the stage after this one; the row carries it already.
    /// `lensWord` is whose correction the photograph's is (`LensCorrection.word`): a Sony mask made with it on before
    /// the app corrected Sony's lenses was made on another picture.
    static func isMarked(_ layer: LocalLayer, lensCorrection: Bool?, lensWord: String = "") -> Bool {
        guard let lensCorrection, !layer.parts.isEmpty else { return false }
        return !layer.madeOn.matches(lensCorrection: lensCorrection, lensWord: lensWord)
    }

    private static func content(_ photograph: UUID?, held: Bool, has: (UUID) -> Bool) -> LayerRow.Content {
        guard held else { return .empty }
        // A pair's hole made before frames had ids names its file only: it is there.
        guard let photograph else { return .photograph(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) }
        return has(photograph) ? .photograph(photograph) : .missing(photograph)
    }

    /// Whether a double's rows wear their eyes: both exposures there, each with its photograph in the library.
    static func eyes(_ double: DoubleExposure, has: (UUID) -> Bool) -> Bool {
        DoubleExposure.Position.allCases.allSatisfy { double[$0].map { has($0.frame) } ?? false }
    }

    // MARK: the pick

    /// The pick as the panel holds it: a row the piece does not have is 胶片 (another frame opened on the page, a
    /// mask layer removed or undone away).
    static func held(_ pick: LayerPick, in piece: LayerPiece, layers: LocalLayers? = nil) -> LayerPick {
        switch (pick, piece) {
        case (.frame, .pair), (.exposure, .double), (.film, _): pick
        case (.mask(let id), .single): layers?[id] != nil ? pick : .film
        default: .film
        }
    }

    /// ↑ (−1) and ↓ (+1): the row before or after, stopping at the ends. `among` narrows the rows that can be
    /// landed on (摆放: the two exposures only).
    static func step(_ pick: LayerPick, by delta: Int, in rows: [LayerRow], among allowed: (LayerRow) -> Bool = { _ in true }) -> LayerPick {
        let open = rows.filter(allowed).map(\.pick)
        guard let i = open.firstIndex(of: pick) else { return open.first ?? pick }
        return open[min(max(i + delta, 0), open.count - 1)]
    }

    /// What the folded head says at its trailing edge: the picked row's name, after the count of mask layers where
    /// there are any ("蒙版 3 · 渐变 1", MASKS-SPEC §3).
    static func summary(_ pick: LayerPick, in rows: [LayerRow]) -> String {
        let name = rows.first { $0.pick == pick }?.name ?? L("Film")
        let masks = rows.filter { $0.pick.maskID != nil }.count
        return masks == 0 ? name : L("\(masks) masks") + Fmt.dot + name
    }

    // MARK: the eye (LAYERS-SPEC §6.5)

    /// A click on `position`'s eye: that exposure alone; on the lit eye, both again; on the other's struck
    /// eye, straight to that one.
    static func eyeTapped(_ position: DoubleExposure.Position, alone: DoubleExposure.Position?) -> DoubleExposure.Position? {
        alone == position ? nil : position
    }

    /// The exposure shown alone as the piece can still show it: none once a layer is empty or its photograph
    /// has gone (there is nothing to set it against).
    static func alone(_ alone: DoubleExposure.Position?, in double: DoubleExposure, has: (UUID) -> Bool) -> DoubleExposure.Position? {
        eyes(double, has: has) ? alone : nil
    }

    // MARK: what the panel holds

    /// No panel is its head alone on the Mac (MASKS-SPEC §3): a single photograph's unfolds, for its mask layers and
    /// the two rows that make them. (LAYERS-SPEC §4.1's one line was the single frame's before M1.)
    /// While `FeatureFlags.maskLayers` is off (a release build until the mask tools land) a single frame's is, as it was.
    static func isOneLine(_ piece: LayerPiece) -> Bool { FeatureFlags.maskLayers ? false : piece.isSingle }

    /// Whether the piece takes mask layers: a single photograph, in M1 (PRD-E §3, MASKS-SPEC §4.4) — and only where the
    /// panel shows them (`FeatureFlags.maskLayers`). A layer kept in an edit applies whatever this says.
    static func takesMasks(_ piece: LayerPiece) -> Bool { FeatureFlags.maskLayers && piece.isSingle }

    /// Why a pair or a double shows no mask layer, said at the panel's foot (MASKS-SPEC §4.4); nil for a photograph.
    static func maskRefusal(_ piece: LayerPiece) -> String? {
        takesMasks(piece) ? nil : L("Mask layers are for single photographs for now")
    }

    /// Balance is in the panel exactly when there are two exposures to balance.
    static func showsBalance(_ piece: LayerPiece) -> Bool {
        if case .double(let double) = piece { double.balance != nil } else { false }
    }

    /// **Why the piece will not export**, said at the panel's foot before it is asked (LAYERS-SPEC §6.8); nil
    /// when it will. The same sentences `ExportService` gives a refused item.
    static func refusal(_ piece: LayerPiece, has: (UUID) -> Bool) -> String? {
        switch piece {
        case .single: nil
        case .pair(let pair):
            if !pair.isFilled { L("Fill both frames to export the pair.") }
            else if HalfFramePair.Side.allCases.contains(where: { pair[$0]?.frame.map { !has($0) } ?? false }) {
                L("A frame of this pair is no longer in the library.")
            } else { nil }
        case .double(let double): DoubleWords.exportRefusal(double, has: has)
        }
    }

    enum Metric {
        static let head: CGFloat = 32
        static let row: CGFloat = 30
        static let underRows: CGFloat = 6
        /// The rule, `ValueSlider`'s 40 and the 4 under it.
        static let balance: CGFloat = 44.5
        /// The selection row (主体 · 背景 · 人) and the tool row (MASKS-SPEC §2).
        static let selectionRow: CGFloat = 36
        static let toolRow: CGFloat = 36
        /// 不透明度: where a double's Balance sits, the same 44.5.
        static let opacity: CGFloat = 44.5
        /// 组合蒙版 · 完善蒙版…: 2, the buttons' 28, 10.
        static let buttons: CGFloat = 40
        /// Past five rows (胶片 and four layers) the list scrolls within this (MASKS-SPEC §2, decision 7).
        static let listCap: CGFloat = 150
    }

    /// The rows' list: 30 a row, scrolling inside 150 past five rows.
    static func listHeight(masks n: Int) -> CGFloat { min(Metric.row * CGFloat(n + 1), Metric.listCap) }

    /// The card's height without its foot note (which wraps, and is measured where it is drawn): 32 folded; a single
    /// photograph 140 with no mask layer and 224.5 + 30 n with n (the card stopping at 344.5); 128 a pair, 172.5 a
    /// double — today's, the two rows not shown there in M1 (MASKS-SPEC §2, §4.4).
    static func height(_ piece: LayerPiece, masks n: Int = 0, folded: Bool) -> CGFloat {
        guard !folded, !isOneLine(piece) else { return Metric.head }
        guard takesMasks(piece) else {
            return Metric.head + Metric.row * 3 + Metric.underRows + (showsBalance(piece) ? Metric.balance : 0)
        }
        let tools = Metric.selectionRow + Metric.toolRow
        let list = listHeight(masks: n) + Metric.underRows
        return Metric.head + tools + list + (n > 0 ? Metric.opacity + Metric.buttons : 0)
    }

    // MARK: what a picked row scopes (LAYERS-SPEC §5)

    /// The column under the panel for `pick`. A mask layer's page is its own in both modes (MASKS-SPEC §5).
    static func page(_ pick: LayerPick, piece: LayerPiece, mode: LayerMode, has: (UUID) -> Bool,
                     layers: LocalLayers? = nil) -> LayerPage {
        let pick = held(pick, in: piece, layers: layers)
        if let id = pick.maskID, let layer = layers?[id] { return .mask(layer.stage) }
        guard pick.isPicture else { return .film }
        // Edit's tools are Layer 2, kept once for the piece: a picture has none of its own.
        if mode == .edit { return .standsDown }
        switch (pick, piece) {
        case (.frame(let side), .pair(let pair)):
            guard let hole = pair[side] else { return .empty }
            // A frame that has left the library is nobody's to place or expose: it is replaced or removed.
            if let id = hole.frame, !has(id) { return .picture([.photograph]) }
            var sections: [LayerSection] = [.arrange, .exposure, .whiteBalance, .enlarger]
            if FeatureFlags.dateBack { sections.append(.dateBack) }
            return .picture(sections + [.photograph])
        case (.exposure(let position), .double(let double)):
            return page(of: position, in: double, has: has)
        default:
            return .film
        }
    }

    /// A double's exposure, from the tab rule, tab by tab (`DoublePanelKind.of`): what is the exposure's
    /// own is a section; what is the whole's with a line saying so (Print, Effects) is not shown at all.
    private static func page(of position: DoubleExposure.Position, in double: DoubleExposure, has: (UUID) -> Bool) -> LayerPage {
        let layer = DoubleExposure.Layer(position)
        func kind(_ tab: DevelopTab) -> DoublePanelKind { DoublePanelKind.of(tab, layer, double, has: has) }
        if kind(.frame) == .empty {
            // An exposure whose photograph has gone still has a row to replace or remove it from.
            return double[position] == nil ? .empty : .picture([.photograph])
        }
        var sections: [LayerSection] = []
        if kind(.frame) == .picture { sections.append(.arrange) }
        if kind(.film) == .filmExposure { sections.append(.advanced) }
        if kind(.scene) == .sceneExposure { sections.append(.whiteBalance) }
        if kind(.frame) == .picture { sections.append(.photograph) }
        return .picture(sections)
    }

    /// The rows the white balance's line leads to with 胶片 picked (the review's R3): each picture that is there.
    static func whiteBalanceRows(_ rows: [LayerRow]) -> [LayerRow] {
        rows.filter { $0.photograph != nil }
    }

    /// **Which picture 冲洗's 裁剪 arranges** (LAYERS-SPEC §5.3), or nil where it is the photograph's own crop
    /// (a single frame) or stands down (a pair's whole, an empty row). On a double the way in never depends on
    /// the pick: with 胶片 picked it is the exposure picked last, the top at first.
    static func arranges(_ pick: LayerPick, piece: LayerPiece, last: DoubleExposure.Position?, has: (UUID) -> Bool) -> LayerPick? {
        switch (held(pick, in: piece), piece) {
        case (.frame(let side), .pair(let pair)):
            return pair[side] != nil ? .frame(side) : nil
        case (.exposure(let position), .double(let double)):
            return double[position].map { has($0.frame) } == true ? .exposure(position) : nil
        case (.film, .double(let double)):
            let order = [last ?? .top, (last ?? .top).other]
            return order.first { double[$0].map { has($0.frame) } == true }.map(LayerPick.exposure)
        default:
            return nil
        }
    }

    /// 摆放 lands on a picture's row only: 胶片 stands down while it is open.
    static func arrangeable(_ row: LayerRow) -> Bool { row.photograph != nil }
}

// MARK: - the order pictures were picked in (合成, the UX review's R6; gap G1)

/// **The order a selection was made in.** A set of chosen rows says which, never in which order, and 合成 lays
/// its two pictures by the order they were picked: the first is a double's bottom and a pair's left. Each
/// change of the selection is followed (`follow`): what left it is forgotten, what joined it joins the end —
/// and rows that join together (a ⇧ run, Select All) keep the grid's order among themselves, since no one of
/// them was picked before another.
struct PickOrder<ID: Hashable> {
    private var stamps: [ID: Int] = [:]
    private var next = 0

    init() {}

    mutating func follow(_ selection: Set<ID>) {
        stamps = stamps.filter { selection.contains($0.key) }
        let joined = selection.filter { stamps[$0] == nil }
        guard !joined.isEmpty else { return }
        for id in joined { stamps[id] = next }
        next += 1
    }

    /// The chosen of `rows`, in the order they were picked; `rows` is the grid's order.
    func ordered(_ rows: [ID]) -> [ID] {
        rows.enumerated().filter { stamps[$0.element] != nil }
            .sorted { (stamps[$0.element] ?? 0, $0.offset) < (stamps[$1.element] ?? 0, $1.offset) }
            .map(\.element)
    }
}
