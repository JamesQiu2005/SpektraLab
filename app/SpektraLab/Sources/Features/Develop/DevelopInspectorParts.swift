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
//  - **The Film and Paper strips fold**, each under its own pill with a bare chevron at the right of
//    that line (`StockPreviewPanel(foldable:)`), kept across launches; on the Mac a wheel or a
//    trackpad moves a strip sideways, wheel down to the right (`Sources/Mac/MacWheelRow.swift`).

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

    /// What Film & Paper's Reset puts back: Decode (`decodeScopes`), and the retired Enlarger and
    /// Pre-flash with it, which nothing else can take off.
    var filmAndPaperResetScopes: [PageResetScope] { Self.decodeScopes + [.enlarger, .preflash] }

    /// Format's ↺: the format, and the effects laid there (`wideEffects`) — Grain and Halation are the
    /// format's already; Scatter, Glare, the couplers and Grain's sub-layers with them.
    var resettingWideFormat: Bool { navigation.surface == .develop && navigation.step == .format && pair == nil }
    static let wideFormatScopes: [PageResetScope] = [.format, .effects, .couplers]

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
    private static let styleKey = "develop.wide.histogram.style"
    private static let histogramFoldKey = "develop.wide.histogram.collapsed"
    private static let filmFoldKey = "develop.wide.filmRow.collapsed"
    private static let paperFoldKey = "develop.wide.paperRow.collapsed"
    private static let decodeFoldKey = "develop.wide.decode.collapsed"
    private static let filmEdgeFoldKey = "develop.wide.filmEdge.collapsed"
    private static let dateBackFoldKey = "develop.wide.dateBack.collapsed"

    var histogramStyle: HistogramStyle { didSet { defaults.set(histogramStyle.rawValue, forKey: Self.styleKey) } }
    var histogramCollapsed: Bool { didSet { defaults.set(histogramCollapsed, forKey: Self.histogramFoldKey) } }
    var filmRowCollapsed: Bool { didSet { defaults.set(filmRowCollapsed, forKey: Self.filmFoldKey) } }
    var paperRowCollapsed: Bool { didSet { defaults.set(paperRowCollapsed, forKey: Self.paperFoldKey) } }
    /// Decode, 片边 Film Edge and 日期后背
    /// Date Back fold on Film & Paper as the strips do (`ColumnSectionHeader`).
    var decodeCollapsed: Bool { didSet { defaults.set(decodeCollapsed, forKey: Self.decodeFoldKey) } }
    var filmEdgeCollapsed: Bool { didSet { defaults.set(filmEdgeCollapsed, forKey: Self.filmEdgeFoldKey) } }
    var dateBackCollapsed: Bool { didSet { defaults.set(dateBackCollapsed, forKey: Self.dateBackFoldKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        histogramStyle = defaults.string(forKey: Self.styleKey).flatMap(HistogramStyle.init(rawValue:)) ?? .captureOne
        histogramCollapsed = defaults.bool(forKey: Self.histogramFoldKey)
        filmRowCollapsed = defaults.bool(forKey: Self.filmFoldKey)
        paperRowCollapsed = defaults.bool(forKey: Self.paperFoldKey)
        decodeCollapsed = defaults.bool(forKey: Self.decodeFoldKey)
        filmEdgeCollapsed = defaults.bool(forKey: Self.filmEdgeFoldKey)
        dateBackCollapsed = defaults.bool(forKey: Self.dateBackFoldKey)
    }
}
