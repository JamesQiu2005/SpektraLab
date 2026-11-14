//  DecodeSection.swift — Develop › Film & Paper's Decode: what is done to the scene before the film.
//
//  The owner, 2026-10-24: "under the film and paper selection, there should be a unified 解码, that
//  handles: current film EV, the white balance, and a newly added curve, that works similarly as the
//  current curve in edit … but it applies straight to the linear tiff. This is going to replace scene
//  placements." So the three are one section under the two strips, a chip each, as Edit › EngineRouter's
//  Decode tile had White Balance and Scene Placement (that tile is gone with this):
//
//  - **Exposure**: Film Exposure, the slider the panel had (`exposure_compensation_ev`).
//  - **White Balance**: the Decode tile's rulers (`ScenePanel`, embedded), RAW files only, and on a
//    half-frame pair the focus frame's own, as they were; beside its ↺ the neutral-grey eyedropper
//    (`NeutralPick`, 2026-11-11), which sets them from a click on something grey.
//  - **Curve**: Edit's Curve tool on `FilmParams.sceneCurve` (`CurveTarget.decode`): its axes are
//    stops about the metered mid-grey, ±8, the Latitude card's — the engine applies it to the linear
//    scene as a gain, after the meter and before Film Exposure (`scene_curve`, API-SPEC §17).
//
//  The chips' ↺ puts back the part shown; the page's ↺ on Film & Paper puts back all three
//  (`DevelopWorkspace.decodeScopes`). With Apply Film Emulation off the exposure and the curve stand
//  down — no film is exposed — and the white balance stays: Apple's decode has it too.
//
//  "the 解码 part becomes
//  collapsible. Instead of a second layer, 曝光 / 白平衡 / 曲线 are all displayed in that sequence. The
//  reset still appears." So in a wide window (`stacked`) there are no chips: Decode's title line folds
//  it, as the strips fold (`ColumnSectionHeader`, kept in `DevelopPanelPrefs`), and under it the three
//  parts in that order, each under its own name with its own ↺. The host keeps the chips.
//
//  **高动态范围** (PRD-B, 2026-11-09): Decode's last part in a wide window, a row that folds on its own, holding the
//  print's EDR, the picture's Enable HDR and its HDR Peak Brightness (`HighDynamicRangeGroup`). The host's chips
//  have no such part (the Mac's column is the stacked one).
//
//  **放大机** (2026-11-10): the print's Brightness, Yellow, Magenta and Pre-flash (`EnlargerGroup`), a folding row
//  before 高动态范围.
//
//  Scene Placement has no control any more. A frame that has one keeps it on the wire, so its picture
//  does not change under it; the page's ↺ takes it off with the rest of the decode.

import SwiftUI

// `DecodeTool`, its three parts, is in Edit/EditTool.swift beside the page's navigation that keeps it:
// no SwiftUI there, so `tools/layer2_selftest.swift` compiles it.

struct DecodeSection: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    /// The camera's own white balance, kept from when the page opened under As Shot.
    let cameraWhiteBalance: (temperature: Double, tint: Double)?
    @Binding var tool: DecodeTool
    /// Whether a part holds anything its ↺ would put back, and the putting back: the page's own
    /// (`changesAnything`, `AppServices.resetPage`), which know a pair's frame from its piece.
    let moved: (PageResetScope) -> Bool
    let reset: (PageResetScope) -> Void
    /// A wide window's: the three parts one after another under a title line that folds them.
    var stacked = false
    @State private var channel = CurveChannel.rgb
    private var prefs: DevelopPanelPrefs { .shared }

    /// The section's title line, and its chips' row.
    static let header: CGFloat = 30
    /// A wide window's Decode folded: its hairline and its header (`stackedBody`, `ColumnSectionHeader`'s 32.5 pt).
    static var foldedHeight: CGFloat { ColumnSectionHeader<EmptyView>.height }
    /// A wide window's part's name line, with its ↺ (and White Balance's eyedropper) at 22 pt, Edit's.
    static let partHeader: CGFloat = 28
    /// A wide window's Decode open, as the column reserves it: its header and its shortest part (Exposure); the
    /// rest scrolls.
    static var stackedHeight: CGFloat { foldedHeight + partHeader + exposureHeight }
    static let chips: CGFloat = 44
    /// Each part's own height under the chips.
    static let exposureHeight: CGFloat = 52
    /// The host's; a wide window's stacked part is `CurveTool.wideHeight`.
    static let curveHeight: CGFloat = 248
    /// The white balance's first ruler's label, from the top of its band.
    static let firstBaseline: CGFloat = 22

    static func height(_ tool: DecodeTool) -> CGFloat {
        header + chips + {
            switch tool {
            case .exposure: exposureHeight
            case .whiteBalance: ScenePanel.embeddedHeight
            case .curve: curveHeight
            }
        }()
    }

    private var appliesFilm: Bool { session.edit.appliesFilm }
    private func enabled(_ tool: DecodeTool) -> Bool { appliesFilm || !tool.isFilms }

    var body: some View {
        Group {
            if stacked { stackedBody } else { chipsBody }
        }
        // Another frame on the kept page (2.4.0 A2b): the curve's channel back to RGB, as a page made for it opened.
        .onChange(of: frame.id) { _, _ in channel = .rgb }
    }

    /// Each part under its name and its ↺, in the chips' order; folded, the title line alone.
    private var stackedBody: some View {
        VStack(spacing: 0) {
            ColumnSectionHeader(title: L("Decode"), folded: prefs.decodeCollapsed, id: "decode",
                                toggleFold: { prefs.decodeCollapsed.toggle() })
            if !prefs.decodeCollapsed {
                ForEach(DecodeTool.allCases) { t in
                    // On a pair or a double the white balance is each picture's (R3): the whole has none, and
                    // says where it is (`LayerWhiteBalanceLinks`).
                    if t == .whiteBalance, !session.layerPiece.isSingle {
                        HStack(spacing: 6) {
                            Text(t.title).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16)
                        .frame(height: Self.partHeader)
                        LayerWhiteBalanceLinks(session: session)
                    } else {
                    // Each part's name under Decode's own (`FoldHeader.titleInset`), its controls Edit's 22 pt.
                    HStack(spacing: 6) {
                        Text(t.title).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        Spacer(minLength: 0)
                        // White Balance's neutral-grey eyedropper (2026-11-11, `NeutralPick`): the RAW's own.
                        if t == .whiteBalance { NeutralPickButton(session: session, target: .decode, diameter: 22) }
                        RoundButton(diameter: 22, label: L("Reset") + " " + t.title, action: { reset(t.scope) }) {
                            Icon(.reset, size: 13)
                        }
                        .rowEnabled(enabled(t) && moved(t.scope))
                        .accessibilityIdentifier("v5.decode.reset." + t.rawValue)
                    }
                    .padding(.leading, FoldHeader<EmptyView, EmptyView>.titleInset).padding(.trailing, 16)
                    .frame(height: Self.partHeader)
                    .rowEnabled(enabled(t))
                    part(t).rowEnabled(enabled(t))
                    }
                }
                EnlargerGroup(session: session)
                HighDynamicRangeGroup(session: session)
            }
        }
    }

    private var chipsBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Decode")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.header, alignment: .bottom)
            HStack(spacing: 8) {
                ChipRow(options: DecodeTool.allCases, selection: $tool, title: \.title, height: 28, size: 12.5, padding: 12)
                Spacer(minLength: 0)
                if tool == .whiteBalance { NeutralPickButton(session: session, target: .decode, diameter: 32) }
                RoundButton(diameter: 32, label: L("Reset") + " " + tool.title, action: { reset(tool.scope) }) {
                    Icon(.reset, size: 18)
                }
                .rowEnabled(enabled(tool) && moved(tool.scope))
                .accessibilityIdentifier("v5.decode.reset")
            }
            .padding(.horizontal, 16)
            .frame(height: Self.chips)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("v5.decode.tools")
            part(tool).rowEnabled(enabled(tool))
        }
    }

    @ViewBuilder private func part(_ tool: DecodeTool) -> some View {
        switch tool {
        case .exposure:
            EditSlider(title: L("Film Exposure"), value: session.binding(\.params.exposureCompensationEV),
                       range: -8...8, text: { Fmt.signed($0) + " EV" }, detentAtRest: true, editing: session.editing(.shoot))
                .padding(.horizontal, 16)
                .frame(height: Self.exposureHeight, alignment: .top)
        case .whiteBalance:
            ScenePanel(session: session, frame: frame, tool: .constant(.whiteBalance),
                       cameraWhiteBalance: cameraWhiteBalance, embedded: true)
        case .curve:
            // A wide window's is Capture One's (RFC-035 §3.9): a plot about square, 300 pt at most.
            CurveTool(session: session, height: stacked ? CurveTool.wideHeight : Self.curveHeight, channel: $channel, target: .decode)
                .padding(.horizontal, 8)
                .frame(height: stacked ? CurveTool.wideHeight : Self.curveHeight)
        }
    }
}
