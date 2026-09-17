//  CurveEditor.swift — Capture One's curve tool: channel tabs, the histogram
//  behind the curve, draggable points, input/output readout, an eyedropper.
//
//  Interaction: click on the curve adds a point, drag moves it, drag a point
//  well outside the plot removes it, **right-click (or control-click) a point
//  opens a menu that deletes it**, double-click resets the channel. The plot is
//  a `Canvas`; hit-testing is done in the unit square so it is
//  resolution-independent, and both the drag and the menu ask the *same*
//  question — `Curve.index(near:in:)` — so a point you can grab is a point you
//  can right-click.

import AppKit
import SwiftUI

struct CurveEditor: View {
    @Bindable var session: Session
    @State private var channel: CurveChannel = .rgb
    @State private var dragging: Int? = nil
    @State private var hover: CGPoint? = nil

    private var curve: Curve {
        get { session.adjustments.curves[channel] }
    }
    private func setCurve(_ c: Curve) {
        var a = session.adjustments
        a.curves[channel] = c
        session.adjustments = a
    }

    var body: some View {
        VStack(spacing: 6) {
            tabs
            plot
                .aspectRatio(1.05, contentMode: .fit)
            readout
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(CurveChannel.allCases) { ch in
                let on = ch == channel
                Button { channel = ch } label: {
                    VStack(spacing: 4) {
                        Text(ch.title).font(Theme.Font.tab)
                            .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
                        // Only the active channel is underlined. The
                        // inactive ones drew a 0.5 pt rule each, which joined
                        // into a full-width line under the row — a separator
                        // between the channels and the plot they belong to,
                        // which are not two things. Same in `ColorWheel`.
                        Rectangle().fill(on ? Theme.accent : Color.clear).frame(height: 1.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var plot: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                HistogramPlot(bins: session.histogram, channels: [channel], showGrid: true, lineWidth: 1)
                Canvas { ctx, size in
                    // Diagonal reference.
                    var d = Path(); d.move(to: CGPoint(x: 0, y: size.height)); d.addLine(to: CGPoint(x: size.width, y: 0))
                    ctx.stroke(d, with: .color(Theme.dim.opacity(0.6)), lineWidth: 0.5)
                    // The curve.
                    var p = Path()
                    for i in 0...128 {
                        let x = CGFloat(i) / 128
                        let y = curve.evaluate(x)
                        let pt = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    ctx.stroke(p, with: .color(curveColor), lineWidth: 1.5)
                    // Points.
                    for (i, q) in curve.points.enumerated() {
                        let r: CGFloat = i == dragging ? 4.5 : 3.5
                        let rect = CGRect(x: q.x * size.width - r, y: (1 - q.y) * size.height - r, width: 2 * r, height: 2 * r)
                        ctx.fill(Path(rect), with: .color(Theme.plot))
                        ctx.stroke(Path(rect), with: .color(Theme.accent), lineWidth: 1.2)
                    }
                    // Hover input/output guide.
                    if let h = hover {
                        var g = Path()
                        g.move(to: CGPoint(x: h.x * size.width, y: 0)); g.addLine(to: CGPoint(x: h.x * size.width, y: size.height))
                        ctx.stroke(g, with: .color(Theme.text.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    }
                }
                // Above the canvas, and the only thing on the plot that takes a
                // right-click (see `PointContextMenu`).
                PointContextMenu(size: size, curve: curve) { i in
                    var c = curve
                    c.remove(i)
                    setCurve(c)
                }
                .frame(width: size.width, height: size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let u = unit(g.location, size)
                        if dragging == nil {
                            // One hit test for grabbing and for the menu —
                            // `Curve.index(near:in:)` — so the two cannot
                            // disagree about what is under the pointer.
                            if let i = curve.index(near: unitClamped(g.startLocation, size), in: size) { dragging = i }
                            else { var c = curve; dragging = c.insert(unitClamped(g.startLocation, size)); setCurve(c) }
                        }
                        if let i = dragging {
                            var c = curve
                            let outside = u.x < -0.2 || u.x > 1.2 || u.y < -0.2 || u.y > 1.2
                            if outside && i > 0 && i < c.points.count - 1 {
                                c.remove(i); dragging = nil
                            } else {
                                c.move(i, to: u)
                            }
                            setCurve(c)
                        }
                        hover = unitClamped(g.location, size)
                    }
                    .onEnded { _ in dragging = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { setCurve(.identity) })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = unitClamped(p, size)
                case .ended: hover = nil
                }
            }
        }
    }

    private var curveColor: Color {
        switch channel {
        case .rgb, .luma: Theme.text
        case .red: Theme.histR
        case .green: Theme.histG
        case .blue: Theme.histB
        }
    }

    private func unit(_ p: CGPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x / size.width, y: 1 - p.y / size.height) }
    private func unitClamped(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let u = unit(p, size); return CGPoint(x: u.x.clamped(to: 0...1), y: u.y.clamped(to: 0...1))
    }

    // MARK: - the second layer

    /// A right-click on a point, as something SwiftUI can host.
    ///
    /// SwiftUI has no right-click gesture, and both obvious workarounds are
    /// wrong here. A `.contextMenu` on the plot cannot be told *which* point
    /// was clicked, so it would have to guess from the hover position — and a
    /// menu that deletes the point next to the one you clicked is worse than no
    /// menu. An invisible per-point view with its own `.contextMenu` is
    /// hit-testable, so it would swallow the left-drag that moves the point:
    /// the gesture it is meant to sit beside.
    ///
    /// So this is an `NSView` that answers hit tests **only for a context
    /// click** — right button, or control-click, which is the same gesture on a
    /// trackpad — and lets every other event through to the SwiftUI view
    /// underneath. Its `rightMouseDown` pops up an ordinary `NSMenu` at the
    /// click, which is what "a second layer of UI" means on this platform, and
    /// greys the item out for the two points that cannot be deleted rather than
    /// accepting the click and doing nothing.
    private struct PointContextMenu: NSViewRepresentable {
        let size: CGSize
        let curve: Curve
        let delete: (Int) -> Void

        func makeNSView(context: Context) -> NSView {
            ClickView(size: size, curve: curve, delete: delete)
        }

        func updateNSView(_ view: NSView, context: Context) {
            guard let view = view as? ClickView else { return }
            view.size = size
            view.curve = curve
            view.delete = delete
        }

        final class ClickView: NSView {
            var size: CGSize
            var curve: Curve
            var delete: (Int) -> Void

            init(size: CGSize, curve: Curve, delete: @escaping (Int) -> Void) {
                self.size = size
                self.curve = curve
                self.delete = delete
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("not from a nib") }

            /// Flipped, so a point in this view's coordinates is a point in the
            /// `Canvas`'s: both count y downwards from the top.
            override var isFlipped: Bool { true }

            override func hitTest(_ point: NSPoint) -> NSView? {
                guard let event = NSApp.currentEvent else { return nil }
                let contextClick = event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
                return contextClick ? super.hitTest(point) : nil
            }

            override func rightMouseDown(with event: NSEvent) { showMenu(at: event) }

            override func mouseDown(with event: NSEvent) {
                guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
                showMenu(at: event)
            }

            private func showMenu(at event: NSEvent) {
                guard size.width > 1, size.height > 1 else { return }
                let local = convert(event.locationInWindow, from: nil)
                let unit = CGPoint(x: (local.x / size.width).clamped(to: 0...1),
                                   y: 1 - (local.y / size.height).clamped(to: 0...1))
                // No menu for empty plot: a right-click that lands on nothing is
                // not asking about a point.
                guard let i = curve.index(near: unit, in: size) else { return }

                let item = NSMenuItem(title: "Delete point", action: #selector(fire(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = i
                // The ends are the curve's domain; the menu says so by being
                // greyed rather than by doing nothing when clicked.
                item.isEnabled = curve.isDeletable(i)
                let menu = NSMenu()
                menu.addItem(item)
                menu.popUp(positioning: item, at: local, in: self)
            }

            @objc private func fire(_ sender: NSMenuItem) {
                guard let i = sender.representedObject as? Int else { return }
                delete(i)
            }
        }
    }

    private var readout: some View {
        HStack(spacing: 16) {
            let input: Double? = hover.map { Double($0.x) } ?? session.hoverValue.map { Double(0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z) }
            Text("Input: \(input.map { String(format: "%.0f", $0 * 255) } ?? "--")")
            Text("Output: \(input.map { String(format: "%.0f", curve.evaluate(CGFloat($0)) * 255) } ?? "--")")
            Spacer()
            Button { session.curvePickerActive.toggle() } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(session.curvePickerActive ? Theme.accent : Theme.text)
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .help("Pick a point from the image")
        }
        .font(Theme.Font.value)
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 6)
    }
}
