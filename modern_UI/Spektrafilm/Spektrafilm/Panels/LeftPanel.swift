//  LeftPanel.swift — the material rail (v4, 2026-09-26): **Film and Print**.
//
//  v4 made this rail the choices of *material* and nothing else: the
//  navigator at the top, then the film, the paper, the crop and the enlarger.
//  Everything that is a *parameter* of those choices — Camera, Film Format,
//  Scene Placement, the Tone Mask — moved to the Parameters rail.
//
//  The header is the rail's name after the window buttons' clearance. Import,
//  export and `sidebar.left` moved to the top bar, which is on screen whether
//  or not this rail is, so the PRD's "on screen at any given time" holds
//  without the bar having to take them over when the rail folds.
//
//  Sections are separated by `SectionDivider`: drag one to give the section
//  above it more or less of the rail. To add a section, write a view in
//  Panels/Sections and add one line to the list.

import SwiftUI

struct LeftPanel: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    let sections: [(String, AnyView)] =
                        [("navigator", AnyView(NavigatorSection(session: session))),
                         ("film", AnyView(FilmSection(session: session))),
                         ("print", AnyView(PrintProfileSection(session: session))),
                         ("crop", AnyView(CropSection(session: session))),
                         ("enlarger", AnyView(EnlargerSection(session: session)))]
                    // A divider **between** sections, never after the last:
                    // a rule under the final section is a bottom border
                    // against empty rail, not a separator.
                    ForEach(Array(sections.enumerated()), id: \.element.0) { index, entry in
                        if index > 0 { SectionDivider(above: sections[index - 1].0) }
                        entry.1
                    }
                }
            }
        }
        .railCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            // The three window buttons live here (Windows/TrafficLights.swift).
            // They are *placed* in window coordinates, so this is a reservation
            // and not a container.
            Spacer().frame(width: Theme.Metric.trafficLightClearance)
            Text(L(.railFilmAndPrint))
                .font(Theme.Font.railTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
        // The header row is the window's drag surface, as a sidebar header is
        // in Xcode.
        .background(WindowDragHandle())
    }
}

/// `sidebar.left` / `sidebar.right` — the two buttons that fold a rail.
///
/// The PRD's requirement is that they are on screen *at every moment*, which
/// is why this is one view used in three places rather than a button drawn in
/// each: a rail's header holds its own while the rail is open, and the bar
/// holds it while the rail is folded. The glyph never changes — `sidebar.left`
/// always means "the left rail", open or shut.
///
/// **It does not tint.** It used to go `Theme.accent` while its rail was
/// folded, on the reasoning that a selected control tints its glyph. That was
/// the wrong category: this is not a mode you are in, it is a door you push,
/// and the state it would be reporting — whether a whole rail is on screen —
/// is not something you need a 6 pt orange glyph to tell you. The accent is
/// the one colour in the palette that means "look here", and spending it on
/// a fact already filling half the window devalues it everywhere else.
struct SidebarToggle: View {
    enum Edge { case leading, trailing }
    let edge: Edge
    @Binding var collapsed: Bool

    private var symbol: String { edge == .leading ? "sidebar.left" : "sidebar.right" }
    private var help: String {
        switch (edge, collapsed) {
        case (.leading, false): L(.helpDevelopRailHide)
        case (.leading, true): L(.helpDevelopRailShow)
        case (.trailing, false): L(.helpEditRailHide)
        case (.trailing, true): L(.helpEditRailShow)
        }
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() } } label: {
            Image(systemName: symbol)
                .font(.system(size: Theme.Metric.sidebarIcon, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PanelIconButton: View {
    let systemImage: String
    var help: String = ""
    var active = false
    /// A glyph that cannot be used is greyed, like every other non-selectable
    /// control in the app (PRD; `View.rowEnabled(_:)`).
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.Metric.panelIcon, weight: .regular))
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
        .help(help)
    }
}

struct VerticalEllipsis: View {
    var body: some View {
        VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.text).frame(width: 3, height: 3) } }
    }
}

extension View {
    // `panelCard()` — a rounded card on a visible ground — used to live here
    // for the export page and the Browse grid. Both are gone: the grid was
    // removed with the import page, and the export page is three flush rails
    // like the editor. Nothing in the app is a floating card now, so the
    // modifier is not kept "just in case" — a second surface treatment that
    // nothing uses is how the two pages drifted apart in the first place.

    /// A rail, or the filmstrip: flush with the window and square, because
    /// the 2026-09-17 drawing separates regions with a hairline rather than
    /// with a gap and a radius.
    func railCard() -> some View {
        self.background(Theme.card)
    }

    /// The one thing that still floats: the tool bar's pill.
    func barCard() -> some View {
        self.background(Theme.card,
                        in: RoundedRectangle(cornerRadius: Theme.Metric.barRadius, style: .continuous))
    }
}
