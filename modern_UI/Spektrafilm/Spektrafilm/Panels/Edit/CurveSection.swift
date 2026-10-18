//  CurveSection.swift — Post-Dev's Curve: a channel menu, Parametric | Point,
//  the curve over the histogram of the picture as graded, and a readout.
//
//  **Parametric** moves a tone region without placing a point: four amounts
//  (Highlights, Lights, Darks, Shadows) under three splits, whose handles sit
//  on the bar under the plot. **Point** is the curve 1.3 had. A channel is
//  both, applied in that order (`CurveSet.evaluate`), and the plot always
//  draws what the channel does — the composition — whichever view is open.
//
//  The point editor's rules are the model's (`Curve.grab`, `Curve.drag`):
//
//  - a press near a point takes it, elsewhere it adds one; the point is taken
//    **where it is** and moves by the drag's travel, so taking hold of it
//    never moves it (1.3 moved the point to the pointer, up to ten points
//    away);
//  - a point dragged a fifth of the plot outside it is removed, and that is
//    the end of the drag — dragging back in does not bring a new point (1.3
//    re-inserted one at the press on every move after a removal);
//  - right-click or control-click a point for a menu that deletes it; the two
//    ends grey the item out; a double-click resets the channel's point curve;
//  - with the plot focused, the arrows move the last point taken (⌥ a tenth,
//    ⇧ ten times) and Delete removes it. ⌥ while dragging moves it a quarter
//    as far.
//
//  The histogram behind the curve is the canvas's: of the picture with the
//  grade applied (`Renderer.publishHistogram`).

import AppKit
import SwiftUI

/// Which of the channel's two views the section shows. A view choice,
/// remembered across launches; it changes nothing in the picture.
enum CurveMode: String, CaseIterable, Identifiable {
    case parametric, point
    var id: String { rawValue }
    static let storageKey = Session.uiKey + "curveMode"
}

struct CurveSection: View {
    @Bindable var session: Session
    @AppStorage(CurveMode.storageKey) private var modeRaw = CurveMode.parametric.rawValue
    @State private var channel: CurveChannel = .rgb
    /// The region whose row is being dragged, shaded on the plot.
    @State private var activeRegion: ParametricCurve.Region?
    @Environment(\.railSliderMetrics) private var m

    private var mode: CurveMode { CurveMode(rawValue: modeRaw) ?? .parametric }

    var body: some View {
        PanelSection(L(.sectionCurve), key: "curve",
                     action: .reset(.curve, titled: L(.sectionCurve), in: session),
                     menu: { AnyView(Group {
            Button(L("Reset Channel", zh: "重置通道")) { session.changeGrade { $0.curves.reset(channel) } }
            Button(L(.helpResetChannels)) { session.changeGrade { $0.reset(.curve) } }
        }) }, metrics: .right) {
            RailRows {
                header
                CurvePlot(session: session, channel: channel, mode: mode, activeRegion: activeRegion)
                    .aspectRatio(1.05, contentMode: .fit)
                if mode == .parametric {
                    SplitBar(session: session, channel: channel)
                    ForEach(ParametricCurve.Region.allCases) { region in
                        EditSliderRow(title: region.label,
                                      value: session.grade({ $0.curves.parametric[channel][region] },
                                                           { $0.curves.parametric[channel][region] = $1 }),
                                      range: ParametricCurve.amountRange,
                                      begin: { activeRegion = region; session.beginLayer2Gesture() },
                                      end: { activeRegion = nil; session.endLayer2Gesture() })
                    }
                }
            }
        }
    }

    /// The channel menu and the two views. Titles are worked out here, on the
    /// main actor, because the controls take plain closures.
    private var header: some View {
        let channels = Dictionary(uniqueKeysWithValues: CurveChannel.allCases.map { ($0, $0.label) })
        let modes: [CurveMode: String] = [.parametric: L("Parametric", zh: "参数"), .point: L("Point", zh: "控制点")]
        let changed = Set(session.layerAdjustments.curves.changedChannels)
        return VStack(spacing: Theme.Metric.rowSpacing) {
            PillMenu(label: L("Channel", zh: "通道"), options: CurveChannel.allCases,
                     title: { channels[$0] ?? $0.title }, selection: $channel, labelWidth: m.labelWidth,
                     trailingBadge: { _ in false })
            SegmentedSwitch(options: CurveMode.allCases,
                            selection: Binding(get: { mode }, set: { modeRaw = $0.rawValue }),
                            title: { modes[$0] ?? $0.rawValue },
                            // The view that holds this channel's edit carries the dot.
                            marked: { m in
                                guard changed.contains(channel) else { return false }
                                let c = session.layerAdjustments.curves
                                return m == .parametric ? !c.parametric[channel].isNeutral : !c[channel].isIdentity
                            },
                            markHelp: L("This view changes the channel.", zh: "此视图改变了该通道。"))
        }
    }
}

// MARK: - the plot

struct CurvePlot: View {
    @Bindable var session: Session
    let channel: CurveChannel
    let mode: CurveMode
    var activeRegion: ParametricCurve.Region?

    /// The point a drag holds: where it started, and how far it has gone.
    private struct Hold {
        var index: Int?
        var start: CGPoint
        var travelled: CGSize = .zero
        var travel: CGPoint = .zero
    }
    @State private var hold: Hold?
    /// The last point taken: what the arrows move and Delete removes.
    @State private var selected: Int?
    @State private var hover: CGPoint?
    @State private var id = UUID()
    @State private var run = KeyRun()
    @FocusState private var focused: Bool

    private var curves: CurveSet { session.layerAdjustments.curves }
    private var curve: Curve { curves[channel] }

    private func setCurve(_ c: Curve) {
        session.changeGrade { $0.curves[channel] = c }
    }

    var body: some View {
        VStack(spacing: 6) {
            accessible(keyed(plotArea))
            readout
        }
    }

    private var plotArea: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                HistogramPlot(bins: session.histogram, channels: [channel], showGrid: true, lineWidth: 1)
                Canvas { ctx, size in draw(&ctx, size) }
                if mode == .point {
                    PointContextMenu(size: size, curve: curve) { i in deletePoint(i) }
                        .frame(width: size.width, height: size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(mode == .point ? pointDrag(size) : nil)
            .simultaneousGesture(TapGesture(count: 2).onEnded { resetPoints() })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = unitClamped(p, size)
                case .ended: hover = nil
                }
            }
        }
    }

    /// Focus, the arrows and Delete.
    private func keyed(_ content: some View) -> some View {
        content
            .focusable(mode == .point)
            .focused($focused)
            .focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(focused ? Theme.text.opacity(0.5) : .clear, lineWidth: 1))
            .onChange(of: focused) { _, now in focusChanged(now) }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard mode == .point, let i = selected, curve.isDeletable(i) else { return .ignored }
                deletePoint(i)
                return .handled
            }
            .onChange(of: channel) { _, _ in selected = nil; hold = nil }
            .onDisappear { disappeared() }
    }

    /// What VoiceOver reads and does: the channel, the point taken, and the
    /// point actions a pointer would otherwise need.
    private func accessible(_ content: some View) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L(.sectionCurve) + ", " + channel.label)
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in nudge(direction == .increment ? .up : .down, []) }
            .accessibilityAction(named: L("Next point", zh: "下一个控制点")) { cycle(1) }
            .accessibilityAction(named: L("Previous point", zh: "上一个控制点")) { cycle(-1) }
            .accessibilityAction(named: L("Add point", zh: "添加控制点")) { addMiddlePoint() }
            .accessibilityAction(named: L("Delete point", zh: "删除控制点")) { deleteSelected() }
    }

    private func focusChanged(_ now: Bool) {
        if now {
            Layer2KeyFocus.shared.claim(id) { arrow, mods in nudge(arrow, mods) }
        } else {
            Layer2KeyFocus.shared.release(id)
            run.finish(session.endLayer2Gesture)
        }
    }

    private func disappeared() {
        Layer2KeyFocus.shared.release(id)
        run.finish(session.endLayer2Gesture)
        if hold != nil { hold = nil; session.endLayer2Gesture() }
    }

    private func deletePoint(_ i: Int) {
        var c = curve
        c.remove(i)
        setCurve(c)
        selected = nil
    }

    private func deleteSelected() {
        if let i = selected, curve.isDeletable(i) { deletePoint(i) }
    }

    /// A double-click: the channel's point curve back to straight, in Point.
    private func resetPoints() {
        guard mode == .point else { return }
        setCurve(.identity)
        selected = nil
    }

    // MARK: drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        // The region a parametric row is moving, and the three splits.
        if mode == .parametric {
            let p = curves.parametric[channel]
            if let region = activeRegion {
                let span = region.span(in: p)
                let r = CGRect(x: span.lowerBound * size.width, y: 0,
                               width: (span.upperBound - span.lowerBound) * size.width, height: size.height)
                ctx.fill(Path(r), with: .color(Theme.text.opacity(0.07)))
            }
            let held = p.heldSplits
            for s in [held.shadow, held.midtone, held.highlight] {
                var line = Path()
                line.move(to: CGPoint(x: s * size.width, y: 0)); line.addLine(to: CGPoint(x: s * size.width, y: size.height))
                ctx.stroke(line, with: .color(Theme.dim.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
        }
        // Diagonal reference.
        var d = Path(); d.move(to: CGPoint(x: 0, y: size.height)); d.addLine(to: CGPoint(x: size.width, y: 0))
        ctx.stroke(d, with: .color(Theme.dim.opacity(0.6)), lineWidth: 0.5)
        // The channel as applied: parametric, then point.
        var path = Path()
        for i in 0...128 {
            let x = CGFloat(i) / 128
            let pt = CGPoint(x: x * size.width, y: (1 - curves.evaluate(channel, x)) * size.height)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        ctx.stroke(path, with: .color(curveColour), lineWidth: 1.5)
        if mode == .point {
            for (i, q) in curve.points.enumerated() {
                let held = hold?.index == i
                let r: CGFloat = held ? 4.5 : 3.5
                let rect = CGRect(x: q.x * size.width - r, y: (1 - q.y) * size.height - r, width: 2 * r, height: 2 * r)
                // A point is a white ring; the selected one is filled —
                // selection is white, never accent.
                ctx.fill(Path(ellipseIn: rect), with: .color(i == selected ? Theme.selection : Theme.plot))
                ctx.stroke(Path(ellipseIn: rect), with: .color(Theme.text), lineWidth: 1.2)
            }
        }
        if let h = hover {
            var g = Path()
            g.move(to: CGPoint(x: h.x * size.width, y: 0)); g.addLine(to: CGPoint(x: h.x * size.width, y: size.height))
            ctx.stroke(g, with: .color(Theme.text.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
        }
    }

    private var curveColour: Color {
        switch channel {
        case .rgb, .luma: Theme.text
        case .red: Theme.histR
        case .green: Theme.histG
        case .blue: Theme.histB
        }
    }

    // MARK: the point gesture

    private func pointDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if hold == nil {
                    var c = curve
                    let before = c
                    let i = c.grab(at: unitClamped(g.startLocation, size), in: size)
                    hold = Hold(index: i, start: c.points[i])
                    selected = i
                    focused = true
                    session.beginLayer2Gesture()
                    if c != before { setCurve(c) }
                }
                guard var h = hold, let i = h.index else { return }
                // Travel in the unit square, a quarter of it under ⌥.
                let rate: CGFloat = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1
                let dx = g.translation.width - h.travelled.width, dy = g.translation.height - h.travelled.height
                h.travelled = g.translation
                h.travel.x += dx / max(size.width, 1) * rate
                h.travel.y -= dy / max(size.height, 1) * rate
                var c = curve
                h.index = c.drag(i, to: CGPoint(x: h.start.x + h.travel.x, y: h.start.y + h.travel.y))
                if h.index == nil { selected = nil }
                hold = h
                setCurve(c)
                hover = unitClamped(g.location, size)
            }
            .onEnded { _ in
                hold = nil
                session.endLayer2Gesture()
            }
    }

    /// ←/→ move the selected point's input, ↑/↓ its output, a 255th a press.
    private func nudge(_ arrow: Layer2KeyFocus.Arrow, _ mods: NSEvent.ModifierFlags) {
        guard mode == .point else { return }
        let i = selected ?? (curve.points.count > 2 ? 1 : curve.points.count - 1)
        guard curve.points.indices.contains(i) else { return }
        selected = i
        run.press(begin: session.beginLayer2Gesture, end: session.endLayer2Gesture)
        let d = CGFloat(Layer2KeyFocus.stride(1, mods) / 255) * CGFloat(arrow.sign)
        var c = curve
        var q = c.points[i]
        switch arrow {
        case .left, .right: q.x += d
        case .up, .down: q.y += d
        }
        c.move(i, to: q)
        setCurve(c)
    }

    private func cycle(_ by: Int) {
        let n = curve.points.count
        guard n > 0 else { return }
        selected = ((selected ?? 0) + by + n) % n
    }

    private func addMiddlePoint() {
        var c = curve
        selected = c.insert(CGPoint(x: 0.5, y: c.evaluate(0.5)))
        setCurve(c)
    }

    private var accessibilityValue: String {
        guard mode == .point, let i = selected, curve.points.indices.contains(i) else {
            return curves.isIdentity(channel) ? L("Straight", zh: "直线") : L("Shaped", zh: "已调整")
        }
        let q = curve.points[i]
        return "\(i + 1) / \(curve.points.count): " + line(Double(q.x), Double(q.y))
    }

    // MARK: the readout

    /// What the channel does at the pointer — over the plot, or over the
    /// picture's luma on the canvas — or at the point last taken, as
    /// "Input 64 → Output 80", on 0…255.
    private var readout: some View {
        let input: Double? = hover.map { Double($0.x) }
            ?? session.hoverValue.map { Double(0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z) }
        let text: String
        if let input {
            text = line(input, Double(curves.evaluate(channel, CGFloat(input.clamped(to: 0...1)))))
        } else if mode == .point, let i = selected, curve.points.indices.contains(i) {
            text = line(Double(curve.points[i].x), Double(curve.points[i].y))
        } else {
            // Nothing to read: the line keeps its height and says nothing,
            // rather than a row of placeholder dashes.
            text = ""
        }
        return HStack(spacing: 8) {
            Text(text)
                .frame(minHeight: 18)
            Spacer()
            if mode == .point {
                Button { session.curvePickerActive.toggle() } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.curvePickerActive ? Theme.accent : Theme.text)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help(L("Pick a point from the image", zh: "从图像中取点"))
            }
        }
        .font(Theme.Font.value)
        .foregroundStyle(Theme.secondaryText)
    }

    private func line(_ input: Double, _ output: Double) -> String {
        "\(L(.curveInput)) \(String(format: "%.0f", input * 255))  →  \(L(.curveOutput)) \(String(format: "%.0f", output * 255))"
    }

    private func unit(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x / max(size.width, 1), y: 1 - p.y / max(size.height, 1))
    }
    private func unitClamped(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let u = unit(p, size); return CGPoint(x: u.x.clamped(to: 0...1), y: u.y.clamped(to: 0...1))
    }
}

// MARK: - the splits

/// The bar under the plot: the three splits of the channel's parametric
/// curve, each a handle taken where it is and moved by the drag's travel.
struct SplitBar: View {
    @Bindable var session: Session
    let channel: CurveChannel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.plot).frame(height: 3)
                ForEach(ParametricCurve.Split.allCases, id: \.self) { split in
                    SplitHandle(session: session, channel: channel, split: split, width: w)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 14)
    }
}

private struct SplitHandle: View {
    @Bindable var session: Session
    let channel: CurveChannel
    let split: ParametricCurve.Split
    let width: CGFloat

    @State private var start: Double?
    @State private var travelled: CGFloat = 0
    @State private var id = UUID()
    @State private var run = KeyRun()
    @FocusState private var focused: Bool

    private var value: Double { session.layerAdjustments.curves.parametric[channel][split] }

    private var name: String {
        switch split {
        case .shadow: L("Shadows | Darks", zh: "阴影 | 暗调")
        case .midtone: L("Darks | Lights", zh: "暗调 | 亮调")
        case .highlight: L("Lights | Highlights", zh: "亮调 | 高光")
        }
    }

    private func set(_ v: Double) {
        session.changeGrade { $0.curves.parametric[channel].setSplit(split, to: v) }
    }

    var body: some View {
        Triangle()
            .fill(Theme.knob)
            .frame(width: 9, height: 6)
            .scaleEffect(focused ? Theme.Motion.contactScale : 1)
            .rotationEffect(.degrees(180))
            .frame(width: 16, height: 14)
            .contentShape(Rectangle())
            .offset(x: value * width - 8)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: focused) { _, now in
                if now { Layer2KeyFocus.shared.claim(id) { arrow, mods in
                    run.press(begin: session.beginLayer2Gesture, end: session.endLayer2Gesture)
                    set(value + arrow.sign * Layer2KeyFocus.stride(0.01, mods))
                } } else { Layer2KeyFocus.shared.release(id); run.finish(session.endLayer2Gesture) }
            }
            .onDisappear {
                Layer2KeyFocus.shared.release(id)
                run.finish(session.endLayer2Gesture)
                if start != nil { start = nil; session.endLayer2Gesture() }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if start == nil { start = value; travelled = 0; focused = true; session.beginLayer2Gesture() }
                let rate = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1
                start = (start ?? value) + Double((g.translation.width - travelled) / max(width, 1)) * rate
                travelled = g.translation.width
                set(start ?? value)
            }.onEnded { _ in start = nil; session.endLayer2Gesture() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { set(split.rest) })
            .help(name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(String(format: "%.0f", value * 100))
            .accessibilityAdjustableAction { direction in set(value + (direction == .increment ? 0.01 : -0.01)) }
            .accessibilityAction(named: EditText.reset) { set(split.rest) }
    }
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
/// click, and greys the item out for the two points that cannot be deleted
/// rather than accepting the click and doing nothing. Both it and the drag
/// ask `Curve.index(near:in:)`, so a point you can grab is a point you can
/// right-click.
struct PointContextMenu: NSViewRepresentable {
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

            let item = NSMenuItem(title: L("Delete point", zh: "删除控制点"), action: #selector(fire(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = i
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
