//  SectionHeader.swift — disclosure triangle, title, "•••" — the row every
//  section in both rails starts with, and the well a list sits in.
//
//  The 2026-09-17 drawing changed three things here. The header is 30 pt (its
//  two collapsed sections, White Balance and Exposure, measure 29.05 and
//  31.05 between hairlines). It carries **no icon**: the drawing's headers are
//  a triangle, a title and a menu, and the glyph that used to sit between the
//  first two is gone. And a section is closed by a `Hairline` drawn by the
//  rail rather than by air, so the only vertical space a section owns is the
//  12 pt under its content — and a *collapsed* section owns none at all,
//  which is what makes two shut sections 30 pt apart.

import SwiftUI

/// The four numbers a section row is drawn with. A default-constructed one is
/// the editor's rails; the export page's drawing has tighter rows and a
/// heavier title, so it passes its own (`Theme.Metric.Export` and
/// `Theme.Font.Export`).
struct SectionMetrics {
    var headerHeight: CGFloat = Theme.Metric.headerHeight
    /// Air between the header and the content under it. **Zero on the
    /// editor's rails**: `headerHeight` was measured from one hairline to the
    /// content below it, so the gap is already inside it.
    var headerToWell: CGFloat = 0
    /// Air under the content, before the next hairline.
    var wellToHeader: CGFloat = Theme.Metric.sectionBottom
    var titleFont: Font = Theme.Font.sectionTitle
}

struct SectionHeader: View {
    let title: String
    var systemImage: String? = nil
    @Binding var expanded: Bool
    var menu: (() -> AnyView)? = nil
    var metrics = SectionMetrics()

    var body: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                Triangle()
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    .frame(width: Theme.Metric.disclosure.width, height: Theme.Metric.disclosure.height)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, Theme.Metric.headerLeading)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.text)
                    .frame(width: Theme.Metric.sectionIcon + 4, height: Theme.Metric.sectionIcon)
                    .padding(.leading, 8)
            }
            Text(title)
                .font(metrics.titleFont)
                .foregroundStyle(Theme.text)
                .padding(.leading, Theme.Metric.headerTitleGap)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let menu {
                Menu { menu() } label: {
                    EllipsisGlyph().frame(width: 15, height: 3).padding(8).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, Theme.Metric.headerTrailing - 8)
            } else {
                EllipsisGlyph().frame(width: 15, height: 3)
                    .padding(8)
                    .padding(.trailing, Theme.Metric.headerTrailing - 8)
            }
        }
        .frame(height: metrics.headerHeight)
        .contentShape(Rectangle())
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct EllipsisGlyph: View {
    var body: some View {
        HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.text).frame(width: 3, height: 3) } }
    }
}

/// The rounded well a list sits in.
///
/// On the editor's rails there are exactly two of these — the film list and
/// the print list — and everything else sits directly on the rail. That is
/// the drawing: a well is now what holds a *choice from a set*, not what
/// holds a group of controls.
///
/// `inset` is how far the well is held off the rail's own edges, and it is a
/// parameter rather than a constant because the two drawings disagree: the
/// editor's wells are 4 pt in and the export page's are its own
/// `Export.wellInset`. It used to be `Theme.Metric.wellInset` for both, which
/// meant the export page silently followed the editor's number.
struct Well<Content: View>: View {
    var padding: CGFloat = Theme.Metric.wellPadding
    var vertical: CGFloat = 10
    var inset: CGFloat = Theme.Metric.wellInset
    var radius: CGFloat = Theme.Metric.wellRadius
    /// Whether the plate is drawn at all.
    ///
    /// A well means "these rows are a *list*, and the plate is its edge" — a
    /// film catalogue, a recipe list. It does not mean "these rows belong to
    /// the same section", which is what the hairline above them already says.
    /// The export page had a plate under every group, so Location, Naming,
    /// Format and Summary each read as a grey block rather than as rows, and
    /// four blocks in a column read as one. Its drawing puts a plate under
    /// the recipe list and nothing else; `fill: false` is the rest.
    var fill: Bool = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, padding)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if fill {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.well)
                }
            }
            .padding(.horizontal, inset)
    }
}

/// A section: header + collapsible well. `expanded` persists per key.
struct PanelSection<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    let key: String
    var initiallyExpanded = true
    var menu: (() -> AnyView)? = nil
    /// See `SectionMetrics` — the editor's panels unless a page says otherwise.
    var metrics = SectionMetrics()
    @ViewBuilder var content: () -> Content
    @AppStorage private var expanded: Bool

    init(_ title: String, systemImage: String? = nil, key: String, initiallyExpanded: Bool = true,
         menu: (() -> AnyView)? = nil, metrics: SectionMetrics = SectionMetrics(),
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.systemImage = systemImage; self.key = key
        self.initiallyExpanded = initiallyExpanded; self.menu = menu; self.metrics = metrics
        self.content = content
        _expanded = AppStorage(wrappedValue: initiallyExpanded, Session.uiKey + "section.\(key)")
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: title, systemImage: systemImage, expanded: $expanded, menu: menu,
                          metrics: metrics)
            // A **collapsed** section is its header and nothing else. The
            // drawing's two shut sections are 30 pt apart, which is the
            // header, so bottom padding here would put air under a row that
            // has nothing under it.
            if expanded {
                content()
                    .padding(.top, metrics.headerToWell)
                    .padding(.bottom, metrics.wellToHeader)
            }
        }
    }
}
