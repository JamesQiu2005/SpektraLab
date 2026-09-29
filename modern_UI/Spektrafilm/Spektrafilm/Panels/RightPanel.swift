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
    /// The header's content width, measured; drives `headerShape`.
    @State private var headerWidth: CGFloat = 0

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
                           ("scenePlacement", AnyView(ScenePlacementSection(session: session)))]
                           // Withdrawn for the next version (`FeatureFlags.toneMask`).
                           + (FeatureFlags.toneMask
                              ? [("toneMask", AnyView(ToneMaskSection(session: session)))] : [])
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

    /// The rail's name and its two tabs, laid out by arithmetic on the rail's
    /// real width (2026-09-28). Neither the tabs nor the name may shrink or
    /// truncate, so the header takes the first of three shapes that fits:
    /// one row; the name beside the two tabs stacked; the name over the tabs
    /// stacked. `ViewThatFits` was tried and misjudged the second by a few
    /// points, falling through to the third on a rail where the second fits.
    private var header: some View {
        Group {
            switch headerShape {
            case .row:
                HStack(spacing: Theme.Metric.tabGap) {
                    title.padding(.trailing, Theme.Metric.tabLeadingGap - Theme.Metric.tabGap)
                    tabs
                    Spacer(minLength: 0)
                }
                .frame(height: Theme.Metric.panelHeaderHeight)
            case .beside:
                HStack(spacing: Self.besideGap) {
                    title
                    VStack(alignment: .leading, spacing: 4) { tabs }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
            case .stacked:
                VStack(alignment: .leading, spacing: 4) {
                    title.frame(height: Theme.Metric.panelHeaderHeight - 8, alignment: .bottom)
                    tabs
                }
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { headerWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in headerWidth = w }
        })
        .padding(.leading, Theme.Metric.rowInset)
        .padding(.trailing, Theme.Metric.panelHeaderTrailing)
        // The same drag surface the left rail's header is: with the titlebar
        // hidden this row is where one would be.
        .background(WindowDragHandle())
    }

    enum HeaderShape { case row, beside, stacked }
    static let besideGap: CGFloat = 6
    static let tabPadding: CGFloat = 5

    /// Which shape fits `headerWidth`, from the strings' own widths.
    private var headerShape: HeaderShape {
        let titleWidth = Theme.textWidth(L(.railParameters), size: 12)
        let tabWidth = ParametersTab.allCases
            .map { max(Theme.textWidth($0.title, size: 12) + 2 * Self.tabPadding, Theme.Metric.tabSize.width) }
            .max() ?? 0
        // Before the first measurement, assume the rail's standard width.
        let available = headerWidth > 0 ? headerWidth
            : Theme.Metric.rightPanelWidth - Theme.Metric.rowInset - Theme.Metric.panelHeaderTrailing
        if titleWidth + Theme.Metric.tabLeadingGap + 2 * tabWidth + Theme.Metric.tabGap <= available { return .row }
        if titleWidth + Self.besideGap + tabWidth <= available { return .beside }
        return .stacked
    }

    private var title: some View {
        Text(L(.railParameters))
            .font(Theme.Font.railTitle)
            .foregroundStyle(Theme.text)
            .fixedSize()
    }

    @ViewBuilder private var tabs: some View {
        ForEach(ParametersTab.allCases) { t in
            Button { tabRaw = t.rawValue } label: {
                Text(t.title)
                    .font(Theme.Font.railTitle)
                    .foregroundStyle(t == tab ? Theme.accent : Theme.Ink.tertiary)
                    .fixedSize()
                    .padding(.horizontal, Self.tabPadding)
                    .frame(minWidth: Theme.Metric.tabSize.width)
                    .frame(height: max(Theme.Metric.tabSize.height, Theme.lineHeight(size: 12) + 2))
                    .overlay(Capsule().stroke(t == tab ? Theme.accent : Theme.Ink.tertiary.opacity(0.6),
                                              lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
