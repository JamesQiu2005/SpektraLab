//  SectionHeader.swift — disclosure triangle, glyph, title, "•••" — the row
//  every section in both panels starts with, and the well under it.

import SwiftUI

/// The four numbers a section row is drawn with. A default-constructed one is
/// the editor's panels, which is what every caller but the export page wants;
/// the export page's drawing has tighter rows and a heavier title, so it
/// passes its own (`Theme.Metric.Export` and `Theme.Font.Export`).
struct SectionMetrics {
    var headerHeight: CGFloat = Theme.Metric.headerHeight
    var headerToWell: CGFloat = Theme.Metric.headerToWell
    var wellToHeader: CGFloat = Theme.Metric.wellToHeader
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
            .padding(.leading, 6)
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
                .padding(.leading, 10)
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
            } else {
                EllipsisGlyph().frame(width: 15, height: 3).padding(8)
            }
        }
        .frame(height: metrics.headerHeight)
        .padding(.horizontal, Theme.Metric.wellInset)
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

/// The rounded well every section's content sits in.
struct Well<Content: View>: View {
    var padding: CGFloat = Theme.Metric.wellPadding
    var vertical: CGFloat = 10
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, padding)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Metric.wellRadius, style: .continuous))
            .padding(.horizontal, Theme.Metric.wellInset)
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
            if expanded {
                content().padding(.top, metrics.headerToWell)
            }
        }
        .padding(.bottom, metrics.wellToHeader)
    }
}
