//  DevelopInspectorParts.swift — what the develop page's panels hold in the column.
//
//  "for mac and window".
//
//  - **Edit is Adjust.** No Adjust · EngineRouter · Crop pill: "no 暗房 and 裁切 at all". EngineRouter's
//    Latitude card, Enlarger and Effects tiles are gone from Edit, and nothing on these panels opens
//    the crop (the column's header has its own Crop). "The old enlarger and 效果 in 编辑 can retire
//    completely": a frame's print brightness, filter shifts and pre-flash keep rendering — the wire is
//    unchanged — and Develop's Reset takes them off.
//  - **The effects are Develop's**, laid flat on Format under Remove anti-halation layer since
//    2026-10-25 (the owner: "the whole effects part is moved to 格式 in 冲洗, so that it aligns with
//    the 移除防光晕 that's already in 冲洗 → 格式"; on Film & Paper under Decode before), in the owner's order:
//    颗粒 Grain, 光晕 Halation, 散射 Scatter, 眩光 Glare, 成色剂 Couplers (`EffectsPanel(flat:)`), the
//    rulers, ranges and bindings EngineRouter's Effects tile had. Format's own Grain and Halation rulers,
//    the same two values, are drawn nowhere. Grain's Sub-layers switch is on no panel: its value
//    keeps rendering, and Reset puts it back with the effects.
//  - **Develop's Reset** on Film & Paper (the ⋯ menu's on the Mac), titled 冲洗 Develop: Decode as
//    before and the retired Enlarger and Pre-flash, one step of Undo. The effects went with their
//    controls to Format (2026-10-25), whose ↺ is the format, the effects and the couplers; neither
//    takes off the film edge or the date, which have their own switches.
//  - **Film Edge and Date Back** are sections on Format under the film's sizes (`FilmEdgeColumn.swift`,
//    2026-10-25), in place of the rows into the flow; Film & Paper is the strips and Decode, which folds
//    and lays its three parts out in order. Format reads: sizes, 片边, 日期后背, 移除防光晕, the effects.
//  - **The status line is at the panel's foot** ("● 已冲洗 · Portra 400 · Portra Endura"): on Develop
//    in the panel, directly under Apply Film Emulation (on Format under the panel's last row), and
//    not drawn with the switch off; on Edit at the foot of the panel. The progress of a develop is
//    the canvas's bar, as before; the line keeps its dot and its words.
//  - **A histogram** heads the panel, under the Develop | Edit row, on both (`HistogramPanel.swift`).
//  - **The Film and Paper strips fold** (`StockPreviewPanel(foldable:)`), kept across launches; on the Mac a
//    wheel or a trackpad moves a strip sideways, wheel down to the right (`Sources/Mac/MacWheelRow.swift`).
//  - **Every section folds as Edit › Adjust's tools do** (the owner, 2026-11-11: "make Develop's left column
//    tighter: match Edit's collapse style, and shrink the toggles and pills to Edit's size"): the strips, Decode
//    (and its Enlarger and High Dynamic Range a step in), 片边, 日期后背 and Format's Effects each under the
//    column's 32 pt folding header (`ColumnSectionHeader` over `FoldHeader`) — the chevron at the left, the name,
//    a small switch or a shelf's small pill at the right; Apply Film Emulation and Remove anti-halation layer
//    are 32 pt rows with the small switch (`SpkToggle(size: .compact)`).

import SwiftUI

extension DevelopWorkspace {
    /// Edit shows Adjust, whatever tool the page was opened on: the band that chose EngineRouter or Crop is
    /// not drawn.
    func keepEditOnAdjust() {
        guard navigation.tool != .adjust else { return }
        session.pageNavigation.tool = .adjust
        session.pageNavigation.darkroom = nil
    }

    /// Whether the band under the status line is drawn: Develop's steps; Edit has none.
    var showsNavigationBand: Bool { navigation.surface == .develop }

    /// Develop › Format's effects, flat.
    var wideEffects: EffectsPanel {
        EffectsPanel(session: session, frame: frame, pro: true, page: .constant(.grain),
                     placementOpen: .constant(false), flat: true)
    }

    /// Develop › Format under 片边 and 日期后背 (2026-11-11): Remove anti-halation layer as a 32 pt row with the
    /// small switch, then the effects under their own folding header, the fold kept (`DevelopPanelPrefs`).
    var wideFormatTail: some View {
        let prefs = DevelopPanelPrefs.shared
        return VStack(spacing: 0) {
            FoldRule()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Remove anti-halation layer")).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Experimental simulation for all stocks")).font(Theme.Font.ui(10.5)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SpkToggle(isOn: session.binding(\.params.antihalationRemoved), size: .compact)
                    .accessibilityLabel(L("Remove anti-halation layer"))
                    .accessibilityIdentifier("v5.develop.antihalation")
            }
            .padding(.horizontal, 16).padding(.vertical, 5)
            .frame(minHeight: FoldHeader<EmptyView, EmptyView>.height)
            ColumnSectionHeader(title: L("Effects"), folded: prefs.effectsCollapsed, id: "effects",
                                toggleFold: { prefs.effectsCollapsed.toggle() })
            if !prefs.effectsCollapsed {
                wideEffects
                // 漏光 (PRD-D §3.3): light on the film, beside its other effects; a single frame's, on an engine that has it.
                if pair == nil, frame.pair == nil, EngineFeatures.offers(.leaks) { LeakSection(session: session) }
            }
        }
    }

    /// What Film & Paper's Reset puts back: Decode (`decodeScopes`), and the retired Enlarger and
    /// Pre-flash with it, which nothing else can take off.
    var filmAndPaperResetScopes: [PageResetScope] { Self.decodeScopes + [.enlarger, .preflash] }

    /// Format's ↺: the format, and the effects laid there (`wideEffects`) — Grain and Halation are the
    /// format's already; Scatter, Glare, the couplers and Grain's sub-layers with them.
    var resettingWideFormat: Bool { navigation.surface == .develop && navigation.step == .format && pair == nil }
    static let wideFormatScopes: [PageResetScope] = [.format, .effects, .couplers, .leak]

    /// Format's 片边 and 日期后背 sections, on a single frame (a pair keeps its own lines).
    var filmEdgeColumn: FilmEdgeColumn? {
        guard pair == nil, frame.pair == nil else { return nil }
        return FilmEdgeColumn(session: session, frame: frame)
    }

    /// The picture's histogram at the top of the panel, on Develop and Edit alike (`HistogramPanel`).
    var histogramPanel: HistogramPanel { HistogramPanel(session: session, exposure: frame.exposure) }

    /// The status line at the foot of a Develop panel: none with Apply Film Emulation off.
    var developStatusFoot: DevelopStatus? { session.edit.appliesFilm ? status : nil }
}

/// The page's status line as the column's panels end with it (`StatusLine`, a row of its own).
struct StatusFoot: View {
    let status: DevelopStatus
    static let height: CGFloat = 36

    var body: some View {
        HStack {
            StatusLine(text: status.text, busy: status.busy).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Self.height)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("v5.status")
    }
}

/// What a wide window's develop panels keep across launches: the histogram's style and fold, and the
/// Film and Paper strips' folds. One for the app (`shared`, the standard defaults); a check makes its
/// own over a throwaway suite (AGENTS.md trap 24).
@MainActor @Observable
final class DevelopPanelPrefs {
    static let shared = DevelopPanelPrefs()

    @ObservationIgnored private let defaults: UserDefaults
    private static let histogramFoldKey = "develop.wide.histogram.collapsed"
    private static let filmFoldKey = "develop.wide.filmRow.collapsed"
    private static let paperFoldKey = "develop.wide.paperRow.collapsed"
    private static let decodeFoldKey = "develop.wide.decode.collapsed"
    private static let filmEdgeFoldKey = "develop.wide.filmEdge.collapsed"
    private static let dateBackFoldKey = "develop.wide.dateBack.collapsed"
    private static let hdrFoldKey = "develop.wide.hdr.collapsed"
    private static let enlargerFoldKey = "develop.wide.enlarger.collapsed"
    private static let effectsFoldKey = "develop.wide.effects.collapsed"
    private static let filmSizeFoldKey = "develop.wide.filmSize.collapsed"
    private static let layersFoldKey = "develop.wide.layers.collapsed"
    private static let sideUnitKey = "develop.wide.filmSize.sideUnit"
    static let filmEdgeFilterKey = "develop.filmEdge.formatFilter"

    var histogramCollapsed: Bool { didSet { defaults.set(histogramCollapsed, forKey: Self.histogramFoldKey) } }
    /// 图层, the card under the histogram, folds to its head (LAYERS-SPEC §3): open until folded.
    var layersCollapsed: Bool { didSet { defaults.set(layersCollapsed, forKey: Self.layersFoldKey) } }
    var filmRowCollapsed: Bool { didSet { defaults.set(filmRowCollapsed, forKey: Self.filmFoldKey) } }
    var paperRowCollapsed: Bool { didSet { defaults.set(paperRowCollapsed, forKey: Self.paperFoldKey) } }
    /// Decode, 片边 Film Edge and 日期后背
    /// Date Back fold on Film & Paper as the strips do (`ColumnSectionHeader`).
    var decodeCollapsed: Bool { didSet { defaults.set(decodeCollapsed, forKey: Self.decodeFoldKey) } }
    var filmEdgeCollapsed: Bool { didSet { defaults.set(filmEdgeCollapsed, forKey: Self.filmEdgeFoldKey) } }
    var dateBackCollapsed: Bool { didSet { defaults.set(dateBackCollapsed, forKey: Self.dateBackFoldKey) } }
    /// 解码 › 高动态范围 folds on its own (PRD-B, 2026-11-09): open until folded.
    var hdrCollapsed: Bool { didSet { defaults.set(hdrCollapsed, forKey: Self.hdrFoldKey) } }
    /// 解码 › 放大机 folds on its own (2026-11-10): open until folded.
    var enlargerCollapsed: Bool { didSet { defaults.set(enlargerCollapsed, forKey: Self.enlargerFoldKey) } }
    /// Format's 效果 Effects folds as the others (2026-11-11): open until folded.
    var effectsCollapsed: Bool { didSet { defaults.set(effectsCollapsed, forKey: Self.effectsFoldKey) } }
    /// 格式 › 尺寸 Size folds as the others (2026-11-11): open until folded.
    var filmSizeCollapsed: Bool { didSet { defaults.set(filmSizeCollapsed, forKey: Self.filmSizeFoldKey) } }
    /// The unit Custom's Side Length is typed and read in: a reading, not the frame's (the wire is
    /// millimetres), so the app's. Millimetres until the user picks inches.
    var sideUnit: SideUnit { didSet { defaults.set(sideUnit.rawValue, forKey: Self.sideUnitKey) } }
    /// 片边's 片幅 filter over the format cards (PRD-D §3.1): All until chosen, the flow's and the column's alike.
    var filmEdgeFilter: FilmEdgeFormat.Filter { didSet { defaults.set(filmEdgeFilter.rawValue, forKey: Self.filmEdgeFilterKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        histogramCollapsed = defaults.bool(forKey: Self.histogramFoldKey)
        filmRowCollapsed = defaults.bool(forKey: Self.filmFoldKey)
        paperRowCollapsed = defaults.bool(forKey: Self.paperFoldKey)
        decodeCollapsed = defaults.bool(forKey: Self.decodeFoldKey)
        filmEdgeCollapsed = defaults.bool(forKey: Self.filmEdgeFoldKey)
        dateBackCollapsed = defaults.bool(forKey: Self.dateBackFoldKey)
        hdrCollapsed = defaults.bool(forKey: Self.hdrFoldKey)
        enlargerCollapsed = defaults.bool(forKey: Self.enlargerFoldKey)
        effectsCollapsed = defaults.bool(forKey: Self.effectsFoldKey)
        filmSizeCollapsed = defaults.bool(forKey: Self.filmSizeFoldKey)
        layersCollapsed = defaults.bool(forKey: Self.layersFoldKey)
        sideUnit = defaults.string(forKey: Self.sideUnitKey).flatMap(SideUnit.init(rawValue:)) ?? .mm
        filmEdgeFilter = defaults.string(forKey: Self.filmEdgeFilterKey).flatMap(FilmEdgeFormat.Filter.init(rawValue:)) ?? .all
    }
}
