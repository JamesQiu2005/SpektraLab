//  RightPanel.swift — the Parameters rail (v4, 2026-09-26).
//
//  Its header reads **Parameters** and carries two tabs, **Pre-Dev** and
//  **Post-Dev** — before and after the print is developed:
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
//  the name and the tabs as drawn.

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    let sections: [(String, AnyView)] = tab == .preDev
                        ? [("latitude", AnyView(LatitudeSection(session: session))),
                           ("camera", AnyView(CameraSection(session: session))),
                           ("filmFormat", AnyView(FilmFormatSection(session: session))),
                           ("scenePlacement", AnyView(ScenePlacementSection(session: session))),
                           ("toneMask", AnyView(ToneMaskSection(session: session)))]
                        : [("wb2", AnyView(WhiteBalanceSection(session: session))),
                           ("exposure2", AnyView(ExposureSection(session: session))),
                           ("curve", AnyView(CurveSection(session: session))),
                           ("colorbalance", AnyView(ColorBalanceSection(session: session)))]
                           // Withdrawn while the mask system is redesigned;
                           // the section itself is intact (`FeatureFlags.masks`).
                           + (FeatureFlags.masks
                              ? [("masks", AnyView(MasksSection(session: session)))] : [])
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

    private var header: some View {
        HStack(spacing: Theme.Metric.tabGap) {
            Text(L(.railParameters))
                .font(Theme.Font.railTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                // The name is never the thing that gives way: the tabs shrink
                // first, down to their words.
                .fixedSize()
                .layoutPriority(1)
                .padding(.trailing, Theme.Metric.tabLeadingGap - Theme.Metric.tabGap)
            ForEach(ParametersTab.allCases) { t in
                Button { tabRaw = t.rawValue } label: {
                    Text(t.title)
                        .font(Theme.Font.railTitle)
                        .foregroundStyle(t == tab ? Theme.accent : Theme.Ink.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: Theme.Metric.tabSize.width)
                        .frame(height: Theme.Metric.tabSize.height)
                        .overlay(Capsule().stroke(t == tab ? Theme.accent : Theme.Ink.tertiary.opacity(0.6),
                                                  lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Metric.rowInset)
        .padding(.trailing, Theme.Metric.panelHeaderTrailing)
        .frame(height: Theme.Metric.panelHeaderHeight)
        // The same drag surface the left rail's header is: with the titlebar
        // hidden this row is where one would be.
        .background(WindowDragHandle())
    }
}
