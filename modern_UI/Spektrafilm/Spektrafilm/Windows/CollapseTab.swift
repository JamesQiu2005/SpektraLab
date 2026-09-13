//  CollapseTab.swift — the small pill with a chevron that sits on each edge
//  of the canvas and folds the neighbouring card away.
//
//  It is not on screen until the pointer comes near it (PRD §2). The pill
//  fades in while the mouse is inside a band along the canvas edge and fades
//  out when it leaves; the band is the hover target, not the pill. A 14 pt
//  pill is something you have to hunt for, and the point of hiding these was
//  to stop them competing with the picture — not to make a folded panel
//  harder to get back. Because the band belongs to the *canvas*, it is there
//  in both states: after the panel has folded, the canvas edge has moved and
//  the band moved with it, which is the case that is easy to get wrong.
//
//  Why the band is a view of its own and not SwiftUI's `onContinuousHover`:
//  the pill is drawn *inside* the band, and with SwiftUI's hover the pill
//  would take over the moment the pointer reached it — the hover would end,
//  the pill would fade out from under the pointer, the band would report
//  hover again, and the two would blink at each other. A tracking area is
//  pure geometry, so the band keeps hearing the pointer wherever it is.
//
//  Who takes the click, and where: the band, and only inside the pill's own
//  rectangle. The band cannot simply be click-through (`hitTest` → `nil`),
//  which is what the first version did: an overlay that answers `nil` takes
//  its whole subtree with it, and the pill inside it stopped toggling
//  anything. It cannot take every click in the band either — the band is
//  28 pt deep along the whole canvas edge, and that is a strip of the canvas
//  where panning and the wheel have to keep working. So it answers `nil`
//  everywhere except the pill itself, which is the same 14 × 41.5 rectangle
//  the pill is drawn in, from the same two tokens. That is why the pill is
//  drawn `allowsHitTesting(false)`: the band is what handles the click, and
//  a second copy of the gesture would toggle twice.

import AppKit
import SwiftUI

struct CollapseTab: View {
    enum Edge { case leading, trailing, top, bottom }
    let edge: Edge
    @Binding var collapsed: Bool

    private var horizontal: Bool { edge == .top || edge == .bottom }
    private var glyph: String {
        switch (edge, collapsed) {
        case (.leading, false): "chevron.left"
        case (.leading, true): "chevron.right"
        case (.trailing, false): "chevron.right"
        case (.trailing, true): "chevron.left"
        case (.top, false): "chevron.up"
        case (.top, true): "chevron.down"
        case (.bottom, false): "chevron.down"
        case (.bottom, true): "chevron.up"
        }
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() } } label: {
            Image(systemName: glyph)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: horizontal ? Theme.Metric.tabLength : Theme.Metric.tabThickness,
                       height: horizontal ? Theme.Metric.tabThickness : Theme.Metric.tabLength)
                .background(Theme.card, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A collapse tab that is only there when the pointer is: an invisible band
/// along the canvas edge, and the pill fading in and out inside it.
///
/// The pill keeps the position it had when it was always visible — flush with
/// the canvas edge, which is where the drawing puts it — so the band is the
/// only thing that is new. Leading, trailing and bottom only: the top bar is
/// not a card that folds (PRD §1), so there is no top band.
struct HoverEdgeTab: View {
    let edge: CollapseTab.Edge
    @Binding var collapsed: Bool
    @State private var revealed = false

    /// Depth of the band, across the edge. Twice the pill's own thickness:
    /// the pill has to be comfortably inside it however the pointer arrives,
    /// and the pointer has to be able to be *near* the seam without being on
    /// it, which is what the whole behaviour is for.
    static let band: CGFloat = 28

    private var vertical: Bool { edge == .leading || edge == .trailing }

    /// Where the pill sits inside the band: against the same edge, so its
    /// position is what it was before the band existed.
    private var pillAlignment: Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .bottom: .bottom
        case .top: .top
        }
    }

    /// Clearance the bottom pill keeps from the canvas edge, which is what it
    /// had as a plain overlay (`.padding(.bottom, 4)`). Read by the band as
    /// well: it is what decides where the click lands.
    static let bottomInset: CGFloat = 4

    /// How far the band is pushed **outward**, past the canvas edge, so that
    /// its centre lands on the pill's.
    ///
    /// The band and the pill are hung off the same edge but by different
    /// rules — the band is `band` deep against the edge, the pill is
    /// `tabThickness` deep and inset by `bottomInset` on the bottom edge — so
    /// their centres do not coincide, and the *whole* of the band's slack
    /// falls on one side of the control it reveals. Measured on a 1920×1080
    /// window before this was here:
    ///
    ///     leading   band x 343…371   pill x 343…357    centres 357 vs 350
    ///     trailing  band x 1591…1619 pill x 1605…1619  centres 1605 vs 1612
    ///     bottom    band y 914…942   pill y 918…932    centres 928 vs 925
    ///
    /// Reaching for the tab from the *panel* side therefore missed the band
    /// entirely on both vertical edges, and from below on the bottom one —
    /// which is exactly the direction a person comes from.
    ///
    /// The band is allowed to leave the canvas by this much, because it takes
    /// clicks only on the pill: the 7 pt it spends over the neighbouring card
    /// costs nothing and is what makes the control reachable from that side.
    private var bandShift: CGFloat {
        Self.band / 2 - (edge == .bottom ? Self.bottomInset + Theme.Metric.tabThickness / 2
                                         : Theme.Metric.tabThickness / 2)
    }

    var body: some View {
        ZStack(alignment: pillAlignment) {
            // The **band** moves outward; the pill does not. The pill's place
            // is part of the interface (flush with the canvas edge, where the
            // drawing puts it) and the band's is not — it is a region, and the
            // only thing anyone can tell about it is whether reaching for the
            // control finds it.
            HoverBand(revealed: revealed, pill: pillSize, alignment: pillAlignment, shift: bandShift,
                      onHover: { revealed = $0 }, onTap: toggle)
                .offset(x: edge == .leading ? -bandShift : (edge == .trailing ? bandShift : 0),
                        y: edge == .bottom ? bandShift : 0)
            CollapseTab(edge: edge, collapsed: $collapsed)
                .opacity(revealed ? 1 : 0)
                // The band takes the click (see the note at the top). A live
                // button here would be a second copy of the same gesture.
                .allowsHitTesting(false)
                .padding(.bottom, edge == .bottom ? Self.bottomInset : 0)
        }
        .frame(width: vertical ? Self.band : nil, height: vertical ? nil : Self.band)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .animation(.easeOut(duration: 0.18), value: revealed)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() }
    }

    /// The pill's own size, from the tokens the pill is drawn with.
    private var pillSize: CGSize {
        vertical ? CGSize(width: Theme.Metric.tabThickness, height: Theme.Metric.tabLength)
                 : CGSize(width: Theme.Metric.tabLength, height: Theme.Metric.tabThickness)
    }
}

/// The band itself: reports the pointer in and out, and is never the mouse's
/// target. See the note at the top of the file for why it is not SwiftUI's
/// own hover machinery.
/// Internal rather than file-private so that `CanvasViewTests` can find these
/// in a hosted `EditorWindow` and check the one invariant that matters about
/// them: that the pill is centred in the band it is hovered through.
struct HoverBand: NSViewRepresentable {
    let revealed: Bool
    let pill: CGSize
    let alignment: Alignment
    /// How far this view was offset outward, so that the pill — which was
    /// *not* offset — can be found inside it. See `HoverEdgeTab.bandShift`.
    let shift: CGFloat
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = Band()
        configure(v)
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let v = view as? Band else { return }
        configure(v)
    }

    private func configure(_ v: Band) {
        v.revealed = revealed
        v.pill = pill
        v.alignment = alignment
        v.shift = shift
        v.onHover = onHover
        v.onTap = onTap
    }

    final class Band: NSView {
        var onTap: (() -> Void)?
        var revealed = false
        var pill = CGSize.zero
        var alignment: Alignment = .center
        var shift: CGFloat = 0
        var onHover: ((Bool) -> Void)?
        private var area: NSTrackingArea?

        /// Where the pill is inside the band, in the band's own coordinates.
        ///
        /// The pill is drawn by `HoverEdgeTab` against the canvas edge, and
        /// this view was then offset `shift` outward — so the pill sits
        /// `shift` in from the band's **outer** edge on every edge, and
        /// centred along it. That is the same statement as "the band is
        /// centred on the pill", arrived at from the other side, and it is why
        /// the band's two halves are equal: `shift` is exactly what puts the
        /// canvas edge at the band's middle.
        ///
        /// If this and the pill ever disagree, the click lands beside the
        /// control rather than on it, which is a defect you can see.
        var pillRect: CGRect {
            let t = HoverEdgeTab.bottomInset
            switch alignment {
            case .leading:  return CGRect(x: shift, y: bounds.midY - pill.height / 2,
                                          width: pill.width, height: pill.height)
            case .trailing: return CGRect(x: bounds.width - shift - pill.width,
                                          y: bounds.midY - pill.height / 2,
                                          width: pill.width, height: pill.height)
            case .bottom:   return CGRect(x: bounds.midX - pill.width / 2,
                                          y: bounds.height - shift - t - pill.height,
                                          width: pill.width, height: pill.height)
            default:        return .zero
            }
        }

        /// Only the pill, and only while the pill is on screen. Everything
        /// else in the band — which is 28 pt deep along the whole canvas edge
        /// — falls through to the canvas: the hand tool pans from wherever the
        /// pointer is, the wheel zooms there, and the crop grips are grabbed
        /// there. Tracking areas are geometry and do not consult this, so the
        /// band still hears the pointer with `nil` returned all round.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard revealed else { return nil }
            let p = convert(point, from: superview)
            return pillRect.contains(p) ? self : nil
        }

        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            // A press that wandered off the pill before release is not a click
            // on it, which is what every other button on the machine does.
            if pillRect.contains(p) { onTap?() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            // `.activeAlways`, not `.activeInKeyWindow`: this is a hint about
            // what is under the pointer, and the window that has to show it
            // is not always the key one — `Tools/capture-live.sh` photographs
            // a non-key window, and a tab that only exists in the key window
            // cannot be photographed at all.
            let a = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self)
            addTrackingArea(a)
            area = a
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
