//  PanelResize.swift — a side panel's width is the user's, between two bounds.
//
//  The seam between the two surfaces that have side panels: the editor
//  (`Windows/EditorWindow.swift`) and the export page (`Export/ExportPage.swift`).
//  Both got their widths from a single constant in `Theme.Metric`, so the
//  collapse tab sat at one of exactly two places — the drawn width, or folded
//  — and the user asked for it to be neither: "the collapse tab … should be
//  non-fixed, and there should be one narrowest and widest for both the
//  collapse tabs."
//
//  So a panel has a *range* now, and a width inside it. Three things live
//  here and nothing else does:
//
//  1. `PanelWidthRange` — the narrowest, the widest and the drawn width, as
//     one value, so a bound can never be read without the other two.
//  2. `PanelResizeHandle` — the grip on a panel's inner edge.
//  3. `PanelWidthStore` — the width, persisted under a namespaced key.
//
//  **What is deliberately not here: where the collapse tab goes.** The tab is
//  an overlay on the *canvas*, hung off the canvas's edge, so it already
//  follows the panel wherever the panel ends up (`Windows/CollapseTab.swift`'s
//  header says why the band belongs to the canvas). Nothing about the tab has
//  to change for it to stop being fixed; the panel edge moving is the whole
//  of it.
//
//  The top bar is **not** one of these. It is fixed, by the user's decision
//  and by `Theme.Metric.trafficLightCentreY` — the traffic lights are placed
//  in window coordinates against the bar's height, and a draggable bar would
//  drag the window buttons with it.

import SwiftUI

/// What a panel may be, in points.
///
/// `standard` is the drawing's own width and is what a fresh install gets;
/// the bounds are how far the user may take it. A range whose bounds do not
/// contain its standard is a programming error rather than a preference, so
/// it is clamped here rather than discovered later as a panel that snaps on
/// first launch.
struct PanelWidthRange: Equatable, Sendable {
    let narrowest: CGFloat
    let standard: CGFloat
    let widest: CGFloat

    init(narrowest: CGFloat, standard: CGFloat, widest: CGFloat) {
        self.narrowest = min(narrowest, widest)
        self.widest = max(narrowest, widest)
        self.standard = min(max(standard, self.narrowest), self.widest)
    }

    func clamp(_ w: CGFloat) -> CGFloat { min(max(w, narrowest), widest) }

    /// True when the width is at a bound — what a handle uses to stop drawing
    /// as if there were more room in that direction.
    func atNarrowest(_ w: CGFloat) -> Bool { w <= narrowest + 0.5 }
    func atWidest(_ w: CGFloat) -> Bool { w >= widest - 0.5 }
}

/// The grip on a panel's inner edge.
///
/// Deliberately not a `Divider` with a gesture bolted on: the drag target has
/// to be wider than the line the user sees, or the panel edge becomes a thing
/// you aim at and miss, and the two cannot be the same view without the line
/// growing to the target's width. So the strip is `hitWidth` wide, invisible,
/// and the line inside it is drawn only while the pointer is on it.
///
/// The gesture is measured from the width the drag *started* at rather than
/// from the live one. Accumulating `translation` onto a value the same drag is
/// changing compounds it — the panel accelerates away from the pointer — and
/// at a bound the two disagree permanently: the pointer keeps moving, the
/// clamped width does not, and the panel then lags the pointer by however far
/// past the bound it went.
struct PanelResizeHandle: View {
    /// Which side of the *panel* the handle is on. A leading panel's grip is
    /// on its trailing edge, and dragging right widens it; a trailing panel's
    /// is on its leading edge, and dragging right narrows it.
    enum Side { case trailingEdge, leadingEdge }

    let side: Side
    let range: PanelWidthRange
    @Binding var width: CGFloat

    /// How wide the pointer's target is. 6 pt is Finder's; below about 4 the
    /// edge is missable, and above about 8 it starts eating clicks meant for
    /// the control nearest the edge.
    static let hitWidth: CGFloat = 6

    @State private var hovering = false
    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Self.hitWidth)
            .overlay {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 1)
                    .opacity(hovering || widthAtDragStart != nil ? 0.8 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onContinuousHover { phase in
                // The cursor is pushed and popped rather than set, so leaving
                // the strip restores whatever the canvas had — the hand tool's
                // cursor is the one that notices.
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = start }
                        let delta = side == .trailingEdge ? value.translation.width
                                                          : -value.translation.width
                        width = range.clamp(start + delta)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            // A double-click on the edge returns the panel to the drawing's
            // width, which is the only way back to it once it has been moved
            // and the reason `standard` is carried rather than inferred.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.easeOut(duration: 0.16)) { width = range.standard }
                }
            )
            .accessibilityLabel("Resize panel")
    }
}

/// A panel width that survives a relaunch.
///
/// Keys are namespaced the way `Session`'s UI state is, and for the same
/// reason recorded there: an earlier build of this app shipped under the same
/// bundle identifier and left its own keys behind.
@MainActor
@Observable
final class PanelWidthStore {
    let range: PanelWidthRange
    private let key: String
    /// The suite this store reads **and writes**.
    ///
    /// Held rather than used once: the first version took `defaults` in the
    /// initialiser, read through it, and then wrote through
    /// `UserDefaults.standard` — so the injection was a read-side seam only,
    /// and a test that passed a suite to stay off the user's own preferences
    /// wrote to them anyway. Found by a test of 5f's that failed for the right
    /// reason; the point of the parameter is that both halves honour it.
    private let defaults: UserDefaults

    var width: CGFloat {
        didSet {
            let clamped = range.clamp(width)
            if clamped != width { width = clamped; return }
            defaults.set(Double(width), forKey: key)
        }
    }

    /// `name` is the panel, e.g. "editor.left". A stored value outside the
    /// range — because the range was tightened in a later build — is clamped
    /// on read rather than honoured, so a bound is always a bound.
    init(name: String, range: PanelWidthRange, defaults: UserDefaults = .standard) {
        self.range = range
        self.key = "ui.panelWidth." + name
        self.defaults = defaults
        let stored = defaults.object(forKey: key) as? Double
        self.width = range.clamp(stored.map { CGFloat($0) } ?? range.standard)
    }
}
