//  SectionLayout.swift — the rails' sections are the user's height, not only
//  their width.
//
//  The hairline between two sections is a handle: dragging it sets the height
//  of the section **above** it, the way a split view's divider does. A section
//  that has never been dragged keeps its intrinsic height, so a fresh install
//  is the drawing. Double-click a divider to give that one section back its
//  own height; Settings ▸ Interface ▸ Reset All Layout does it for everything
//  at once, panel widths and open/closed states included.
//
//  **Content is top-aligned in a sized section.** Made taller, a list grows
//  to show more rows (`StockList` fills what it is offered) and anything else
//  keeps its shape with air under it; made shorter than its content, the
//  section scrolls inside itself rather than clipping a control in half.

import SwiftUI

@MainActor
@Observable
final class SectionLayoutStore {
    static let shared = SectionLayoutStore()

    static let keyPrefix = Session.uiKey + "layout.height."
    /// A dragged section keeps at least its header and one row under it.
    static let minContent: CGFloat = 24
    static let maxHeight: CGFloat = 2000

    /// User heights, whole section including its header. Absent = intrinsic.
    private(set) var heights: [String: CGFloat] = [:]
    /// What each section measured last time it was laid out, which is where a
    /// drag on a section that has never been sized starts from.
    @ObservationIgnored var measured: [String: CGFloat] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix(Self.keyPrefix) {
            if let d = v as? Double { heights[String(k.dropFirst(Self.keyPrefix.count))] = CGFloat(d) }
        }
    }

    func height(_ key: String) -> CGFloat? { heights[key] }

    func set(_ height: CGFloat?, for key: String) {
        if let height {
            let h = min(max(height, Theme.Metric.headerHeight + Self.minContent), Self.maxHeight)
            heights[key] = h
            defaults.set(Double(h), forKey: Self.keyPrefix + key)
        } else {
            heights[key] = nil
            defaults.removeObject(forKey: Self.keyPrefix + key)
        }
    }

    /// Settings ▸ Reset All Layout: every section's height and open state,
    /// and both editor panels' widths, back to the drawing.
    static func resetAllLayout(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(keyPrefix) || key.hasPrefix(Session.uiKey + "section.")
            || key.hasPrefix(PanelWidthStore.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
        shared.heights = [:]
        NotificationCenter.default.post(name: .layoutReset, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `SectionLayoutStore.resetAllLayout()`; live stores that cache
    /// a layout value (`PanelWidthStore`) return to their defaults on it.
    static let layoutReset = Notification.Name("SpektraLab.layoutReset")
}

/// The hairline between two sections, and the handle that sizes the upper one.
///
/// The ink stays the 1 pt hairline; the target is a 7 pt strip centred on it,
/// which is the same split `PanelResizeHandle` makes for the vertical edges.
/// It overlaps the rows either side by 3 pt, which is inside every row's own
/// padding, so it never takes a click meant for a control.
struct SectionDivider: View {
    /// The section above, whose height a drag sets.
    let above: String
    @State private var hovering = false
    @State private var start: CGFloat?

    static let hitHeight: CGFloat = 7

    var body: some View {
        Hairline()
            .overlay {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 1)
                    .opacity(hovering || start != nil ? 0.8 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .allowsHitTesting(false)
            }
            .overlay {
                Rectangle().fill(.clear)
                    .frame(height: Self.hitHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: NSCursor.resizeUpDown.set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let store = SectionLayoutStore.shared
                                let from = start ?? store.height(above) ?? store.measured[above] ?? 0
                                if start == nil { start = from }
                                store.set(from + g.translation.height, for: above)
                            }
                            .onEnded { _ in start = nil }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            withAnimation(.easeOut(duration: 0.16)) {
                                SectionLayoutStore.shared.set(nil, for: above)
                            }
                        }
                    )
                    .help("Drag to resize the section above. Double-click to return it to its own height.")
            }
            .zIndex(1)
    }
}

/// Whether the content is inside a section the user has sized, and so may
/// grow (a list) or has to scroll (anything too tall).
private struct SectionSizedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var sectionSized: Bool {
        get { self[SectionSizedKey.self] }
        set { self[SectionSizedKey.self] = newValue }
    }
}

extension View {
    /// Rows of a section, sized by the store when the user has dragged it and
    /// intrinsic otherwise. Used by `PanelSection` for its content.
    func sectionSized(_ key: String, header: CGFloat, measuredTotal: @escaping (CGFloat) -> Void) -> some View {
        modifier(SectionSizing(key: key, header: header, measuredTotal: measuredTotal))
    }
}

private struct SectionSizing: ViewModifier {
    let key: String
    let header: CGFloat
    let measuredTotal: (CGFloat) -> Void
    @State private var store = SectionLayoutStore.shared

    func body(content: Content) -> some View {
        if let total = store.height(key) {
            let h = max(total - header, 0)
            // First the content at its own size, top-aligned in the height it
            // was given; if that does not fit, the same content in a scroll
            // view. A list that can grow never needs the second.
            ViewThatFits(in: .vertical) {
                content.frame(maxHeight: .infinity, alignment: .top)
                ScrollView(.vertical, showsIndicators: false) { content }
            }
            .frame(height: h, alignment: .top)
            .clipped()
            .environment(\.sectionSized, true)
        } else {
            content
                .background(GeometryReader { g in
                    Color.clear.onAppear { measuredTotal(g.size.height + header) }
                        .onChange(of: g.size.height) { _, v in measuredTotal(v + header) }
                })
        }
    }
}
