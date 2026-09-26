//  RightPanel.swift — the grade rail. Its header reads **Edit** and carries
//  `sidebar.right` at the far end.
//
//  **v3 (2026-09-18) replaced the glyph with the word.** The row used to open
//  with an inert `slider.horizontal.3` — the rail's name written as a
//  picture, because the 2026-09-17 drawing wrote it as a picture. v3 writes
//  it as a word, which is the better answer to the same problem: the glyph
//  had to be an `Image` rather than a button so that it could not be clicked,
//  and a symbol that exists only to be unclickable is a symbol nobody can
//  read. `Edit` is a label, not a mode button; there is no other mode.
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
                        // The histogram is not here: it describes the finished
                        // picture and heads the canvas's badge stack instead.
                        [("whiteBalance", AnyView(WhiteBalanceSection(session: session))),
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
            // The rail's name. Alone on this end of the row — a label beside
            // a button reads as a button, which is half of why the glyph that
            // used to sit next to one was unreadable.
            Text(L(.railEdit))
                .font(Theme.Font.railTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.leading, Theme.Metric.panelHeaderLeading)
            Spacer(minLength: 0)
            SidebarToggle(edge: .trailing, collapsed: $session.rightCollapsed)
                .padding(.trailing, Theme.Metric.panelHeaderTrailing)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
        // The same drag surface the left rail's header is, for the same
        // reason: with the titlebar hidden this row is where one would be.
        .background(WindowDragHandle())
    }
}
