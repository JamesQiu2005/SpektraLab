//  RightPanel.swift — the grade rail. Its header carries the adjustments
//  glyph and `sidebar.right` at the far end, which is exactly what the
//  2026-09-17 drawing puts there and nothing else.
//
//  It used to carry a third thing: a dotted-circle button that bypassed the
//  whole adjustment layer. It is gone. It was not in the drawing, it never
//  said what it was, and an unlabelled glyph whose entire job is to change
//  the picture in a way you cannot attribute to it is worse than no control —
//  the user's verdict was "I still have no idea what it can do and why it
//  exists". The capability is untouched and lives where a mode belongs, on
//  the menu with its own words and a shortcut: **View ▸ Bypass Adjustments
//  (⇧⌘B)**.
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
                // Between sections, never after the last — the left rail's
                // rule, applied here too. This stack still ended with a
                // `Hairline()` under Color Balance, which drew a rule across
                // empty rail below the colour wheel.
                VStack(spacing: 0) {
                    let sections: [(String, AnyView)] =
                        [("histogram", AnyView(HistogramSection(session: session))),
                         ("whiteBalance", AnyView(WhiteBalanceSection(session: session))),
                         ("exposure", AnyView(ExposureSection(session: session))),
                         ("curve", AnyView(CurveSection(session: session))),
                         ("colorBalance", AnyView(ColorBalanceSection(session: session)))]
                        // Withdrawn while the mask system is redesigned; the
                        // section itself is intact (`FeatureFlags.masks`).
                        + (FeatureFlags.masks
                           ? [("masks", AnyView(MasksSection(session: session)))] : [])
                    ForEach(Array(sections.enumerated()), id: \.element.0) { index, entry in
                        if index > 0 { Hairline() }
                        entry.1
                    }
                }
            }
        }
        .railCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            // Inert on purpose: the rail's name, written as a glyph because
            // the drawing writes it as a glyph. It is an `Image` and not a
            // `PanelIconButton` so that it cannot take a click, and it is
            // alone on this end of the row — a label beside a button reads as
            // a button, which is half of why the one that used to sit next to
            // it was unreadable.
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: Theme.Metric.panelIcon, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .padding(.leading, Theme.Metric.panelHeaderLeading)
            Spacer(minLength: 0)
            SidebarToggle(edge: .trailing, collapsed: $session.rightCollapsed)
                .padding(.trailing, Theme.Metric.panelHeaderTrailing)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
    }
}
