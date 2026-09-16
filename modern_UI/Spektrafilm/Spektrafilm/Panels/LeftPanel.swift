//  LeftPanel.swift — the darkroom rail: a header row, then the sections in
//  the drawing's order, each one closed by a hairline. To add a section:
//  write a view in Panels/Sections and add one line to the stack.
//
//  The header carries what the 2026-09-17 drawing puts there — import,
//  export, and `sidebar.left` at the far end — and it is also the row the
//  three window buttons are placed on, so it opens with their clearance
//  rather than with the drawing's 10 pt (`Theme.Metric.trafficLightClearance`;
//  the drawing has no window buttons in it at all).
//
//  Import and export are back here after a spell on the top bar. The bar is
//  a *canvas* control now — it floats over the picture and is as wide as the
//  picture is — and opening a file is not a thing you do to the picture.

import SwiftUI

struct LeftPanel: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    CameraSection(session: session)
                    Hairline()
                    FilmSection(session: session)
                    Hairline()
                    PrintProfileSection(session: session)
                    Hairline()
                    CropSection(session: session)
                    Hairline()
                    // Not in the drawing, and kept anyway: the enlarger is
                    // the only access to `print_exposure` and the two filter
                    // axes, and the PRD does not ask for them to go. Last, so
                    // the four sections that *are* drawn are the four you see
                    // without scrolling.
                    EnlargerSection(session: session)
                    Hairline()
                    if FeatureFlags.masks { MasksSection(session: session); Hairline() }
                }
            }
        }
        .railCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            // The three window buttons live here (Windows/TrafficLights.swift).
            // They are *placed* in window coordinates, so this is a reservation
            // and not a container — which is why folding the rail does not move
            // them: the bar takes over the same reservation.
            Spacer().frame(width: Theme.Metric.trafficLightClearance)
            PanelIconButton(systemImage: "tray.and.arrow.down", help: "Open a folder or image (⌘O)") {
                session.openPanel()
            }
            PanelIconButton(systemImage: "square.and.arrow.up", help: "Export (⌘E)",
                            enabled: session.selection != nil) {
                session.showExport = true
            }
            Spacer(minLength: 0)
            SidebarToggle(edge: .leading, collapsed: $session.leftCollapsed)
                .padding(.trailing, Theme.Metric.panelHeaderTrailing)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
        // The header row is the window's drag surface, as a sidebar header is
        // in Xcode. It is a background so that the glyphs above it still take
        // their own clicks.
        .background(WindowDragHandle())
    }
}

/// `sidebar.left` / `sidebar.right` — the two buttons that fold a rail.
///
/// The PRD's requirement is that they are on screen *at every moment*, which
/// is why this is one view used in three places rather than a button drawn in
/// each: a rail's header holds its own while the rail is open, and the bar
/// holds it while the rail is folded. The glyph never changes — `sidebar.left`
/// always means "the left rail", open or shut — and the accent says which
/// state it is in, the same way a selected tool on the bar does.
struct SidebarToggle: View {
    enum Edge { case leading, trailing }
    let edge: Edge
    @Binding var collapsed: Bool

    private var symbol: String { edge == .leading ? "sidebar.left" : "sidebar.right" }
    private var help: String {
        switch (edge, collapsed) {
        case (.leading, false): "Hide the darkroom rail"
        case (.leading, true): "Show the darkroom rail"
        case (.trailing, false): "Hide the adjustments rail"
        case (.trailing, true): "Show the adjustments rail"
        }
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() } } label: {
            Image(systemName: symbol)
                .font(.system(size: Theme.Metric.sidebarIcon, weight: .regular))
                .foregroundStyle(collapsed ? Theme.accent : Theme.text)
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
    /// A rounded card. The **export page's** shape — its drawing still has
    /// four of them — and the Browse grid's.
    func panelCard() -> some View {
        self.background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
    }

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
