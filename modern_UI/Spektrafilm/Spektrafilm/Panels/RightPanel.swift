//  RightPanel.swift — the grade rail. Its header carries the adjustments
//  glyph, the bypass switch (the dotted circle shows the pure simulation
//  while it is active) and `sidebar.right` at the far end, which is what the
//  2026-09-17 drawing puts there.
//
//  Its sections are separated by the same hairline the left rail uses, and
//  there is no menu on the header row: the drawing has none, and each section
//  already carries its own "•••".

import SwiftUI

struct RightPanel: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    HistogramSection(session: session)
                    Hairline()
                    WhiteBalanceSection(session: session)
                    Hairline()
                    ExposureSection(session: session)
                    Hairline()
                    CurveSection(session: session)
                    Hairline()
                    ColorBalanceSection(session: session)
                    Hairline()
                    // Withdrawn while the mask system is redesigned; the
                    // section itself is intact (`FeatureFlags.masks`).
                    if FeatureFlags.masks { MasksSection(session: session); Hairline() }
                }
            }
        }
        .railCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: Theme.Metric.panelIcon, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .padding(.leading, Theme.Metric.panelHeaderLeading)
            PanelIconButton(systemImage: session.adjustments.enabled ? "circle.dotted.circle" : "circle.dotted",
                            help: session.adjustments.enabled ? "Bypass adjustments (show the pure print)" : "Adjustments bypassed — click to enable",
                            active: !session.adjustments.enabled) {
                var a = session.adjustments; a.enabled.toggle(); session.adjustments = a
            }
            .padding(.leading, 8)
            Spacer(minLength: 0)
            SidebarToggle(edge: .trailing, collapsed: $session.rightCollapsed)
                .padding(.trailing, Theme.Metric.panelHeaderTrailing)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
    }
}
