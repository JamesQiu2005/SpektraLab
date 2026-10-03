//  RightPanel.swift — the Parameters rail (v4, 2026-09-26).
//
//  Its header reads **Parameters** and carries two tabs, **Pre-Dev** and
//  **Post-Dev** (显影前 / 显影后) — before and after the print is developed:
//
//  - Pre-Dev is everything that decides the negative and how it is printed:
//    Latitude (the measurement), Input / Camera, Film Format, Scene Placement
//    and the Tone Mask.
//  - Post-Dev is the grade on the finished scan: White Balance, Exposure,
//    Curve and Color Balance — the rail's contents before v4.
//
//  The tab is a view choice, remembered across launches; neither tab's
//  sections stop existing while the other is shown, so an edit is never lost
//  by switching. Every slider on the rail shares one grid
//  (`SliderMetrics.parameters`), set once here through the environment.
//
//  The sections are separated by `SectionDivider`, so the user can give any
//  of them more or less of the rail; Settings ▸ Reset All Layout undoes it.
//  `sidebar.right` moved to the top bar with v4, which leaves this header to
//  the name and, under it, the switch between the two tabs (1.2.2).

import SwiftUI

enum ParametersTab: String, CaseIterable, Identifiable {
    case preDev, postDev
    var id: String { rawValue }
    @MainActor var title: String { self == .preDev ? L(.tabPreDev) : L(.tabPostDev) }
}

struct RightPanel: View {
    @Bindable var session: Session
    @AppStorage(Session.uiKey + "parametersTab") private var tabRaw = ParametersTab.preDev.rawValue
    private var tab: ParametersTab { ParametersTab(rawValue: tabRaw) ?? .preDev }

    /// The tab's sections, in order. Built a statement at a time: as one
    /// expression it was more than the type checker would finish on the CI
    /// runner (2026-10-03).
    private var sections: [(String, AnyView)] {
        var s: [(String, AnyView)] = []
        if tab == .preDev {
            s.append(("latitude", AnyView(LatitudeSection(session: session))))
            // A pair is metered and white-balanced per frame, and its format
            // is the piece's: Input / Camera and Film Format have nothing to
            // say about it.
            if session.pair == nil {
                s.append(("camera", AnyView(CameraSection(session: session))))
                s.append(("filmFormat", AnyView(FilmFormatSection(session: session))))
            }
            s.append(("scenePlacement", AnyView(ScenePlacementSection(session: session))))
            // Withdrawn for the next version (`FeatureFlags.toneMask`).
            if FeatureFlags.toneMask { s.append(("toneMask", AnyView(ToneMaskSection(session: session)))) }
        } else {
            s.append(("wb2", AnyView(WhiteBalanceSection(session: session))))
            s.append(("exposure2", AnyView(ExposureSection(session: session))))
            s.append(("curve", AnyView(CurveSection(session: session))))
            s.append(("colorbalance", AnyView(ColorBalanceSection(session: session))))
            // Withdrawn while the mask system is redesigned; the section
            // itself is intact (`FeatureFlags.masks`).
            if FeatureFlags.masks { s.append(("masks", AnyView(MasksSection(session: session)))) }
        }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    let sections = sections
                    // Between sections, never after the last, and each one a
                    // handle on the section above it.
                    ForEach(Array(sections.enumerated()), id: \.element.0) { index, entry in
                        if index > 0 { SectionDivider(above: sections[index - 1].0) }
                        entry.1
                    }
                }
            }
        }
        .environment(\.railSliderMetrics, .parameters)
        .railCard()
    }

    /// The rail's name, and under it the Pre-Dev / Post-Dev switch (1.2.2).
    ///
    /// The user chose this place — the row under the name, which the header
    /// used to fall back to only when the rail was too narrow for one row —
    /// and option A for the drawing: one segmented switch across the rail
    /// (`SegmentedSwitch`). The name and the switch are one header block, so
    /// no rule runs between them; the one below closes the header. There is
    /// no width arithmetic any more: two equal halves of the rail hold either
    /// language's titles at any interface scale.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(.railParameters))
                .font(Theme.Font.railTitle)
                .foregroundStyle(Theme.text)
                .fixedSize()
                .frame(height: Theme.Metric.panelHeaderHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The same drag surface the left rail's header is: with the
                // titlebar hidden this row is where one would be.
                .background(WindowDragHandle())
            SegmentedSwitch(options: ParametersTab.allCases,
                            selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }),
                            title: { $0.title },
                            marked: { $0 == .postDev && postDevEdited },
                            markHelp: L("The grade is not neutral.", zh: "调色不是中性的。"))
                .padding(.bottom, 8)
        }
        .padding(.leading, Theme.Metric.rowInset)
        .padding(.trailing, Theme.Metric.panelHeaderTrailing)
    }

    /// Post-Dev is out of sight most of the time, and it changes every file;
    /// the switch says when it is not the identity.
    private var postDevEdited: Bool {
        session.adjustments.enabled && !session.adjustments.isNeutral
    }
}
