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
//    half-frame pair the focus frame's own, as they were.
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

    @ViewBuilder var body: some View {
        if stacked { stackedBody } else { chipsBody }
    }

    /// Each part under its name and its ↺, in the chips' order; folded, the title line alone.
    private var stackedBody: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
            ColumnSectionHeader(title: L("Decode"), folded: prefs.decodeCollapsed, id: "decode",
                                toggleFold: { prefs.decodeCollapsed.toggle() })
            if !prefs.decodeCollapsed {
                ForEach(DecodeTool.allCases) { t in
                    HStack(spacing: 8) {
                        Text(t.title).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        Spacer(minLength: 0)
                        RoundButton(diameter: 28, label: L("Reset") + " " + t.title, action: { reset(t.scope) }) {
                            Icon(.reset, size: 16)
                        }
                        .rowEnabled(enabled(t) && moved(t.scope))
                        .accessibilityIdentifier("v5.decode.reset." + t.rawValue)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .rowEnabled(enabled(t))
                    part(t).rowEnabled(enabled(t))
                }
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
