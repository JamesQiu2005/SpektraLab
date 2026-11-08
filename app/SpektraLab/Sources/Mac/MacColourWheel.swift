//  MacColourWheel.swift — 色轮 on the Mac: Capture One's colour balance wheel in place of the pad.
//
//  "The colour wheel style is not a 2-D
//  pad but a C1 style, but the relative layout stays unchanged." So `ColourWheelsTool` keeps its column
//  of three zones at the left, the picked zone's large control at the right and 明度 under them; on the
//  Mac each zone's tile is a small wheel and the large control is the wheel below. The window keeps
//  `ColourPads.swift`'s pads. A new way to set the same numbers: `ColorZone`'s hue,
//  saturation and luminance, applied by the Layer 2 kernel as they always were.
//
//  The large control, as Capture One draws it (the owner's two reference images):
//  - **The hue ring**, a thin circle in every hue, on the panel's ground: red at the right, yellow and
//    orange up to its right, green at the top, cyan at the left, blue and magenta below. The model's
//    hue is the shader's circle (0° red, 120° green, 240° blue, evenly spaced), which drawn as it is
//    would put green at ten o'clock; the ring is that circle warped — 0…120° onto 0…90°, 120…180° onto
//    90…180°, the rest as it is — piecewise linear, so a hue and its place on the ring are one-to-one
//    and the colour under the puck is always the colour it pushes.
//  - **The puck** inside it: its angle the hue, its distance out the strength, the ring's radius the
//    full amount. Out is the square root of `saturation`, as the pad counts its rings
//    (`ColourPad.position`), so a zone set on a window's pad sits as far out here, and the inner part of
//    the disc is the fine part. At the centre, a target (a dot in a circle): no change. The puck is an
//    open circle in the accent colour, and a tick on the ring marks its hue.
//  - **The left arc**, outside the ring: the strength alone, white at its foot to the hue at its head
//    (at rest the hue is 0°, so red to white, as Capture One draws it), a tick at the puck's reach.
//  - **The right arc**: the zone's luminance, white at its head to dark grey at its foot, a tick at the
//    value 明度's slider below shows; both stay, in step, since both are the model's one number.
//
//  The mouse: a press on the disc puts the puck there and a drag moves it; a press on an arc puts its
//  tick there and a drag runs along it; ⌥ held moves a quarter as far, from where the value is (a press
//  with ⌥ does not jump). A double click resets what it is on: the disc the hue and strength, an arc
//  its value. One drag is one step of Undo (`beganEdit` / `changeEdit` / `endedEdit`, as the pad's).
//  The pointer is a crosshair over the disc and an up-down arrow over an arc.

import SwiftUI
import UIKit

/// The wheel's arithmetic, free of views. Angles are in degrees, counterclockwise from the right, y up.
enum MacColourWheel {
    // MARK: Hue ↔ the ring

    /// Where on the ring a hue is: green (120°) at the top, cyan (180°) at the left (see the header).
    static func angle(hue: Double) -> Double {
        let h = wrap(hue)
        if h <= 120 { return h * 0.75 }
        if h <= 180 { return 90 + (h - 120) * 1.5 }
        return h
    }

    /// The hue at a place on the ring: `angle(hue:)` undone.
    static func hue(angle: Double) -> Double {
        let a = wrap(angle)
        if a <= 90 { return a / 0.75 }
        if a <= 180 { return 120 + (a - 90) / 1.5 }
        return a
    }

    /// The colour a hue pushes, as the ring and the arcs draw it (the shader's circle is HSB's).
    static func colour(hue: Double, saturation: Double = 0.82, brightness: Double = 0.96) -> Color {
        Color(hue: wrap(hue) / 360, saturation: saturation, brightness: brightness)
    }

    // MARK: Strength ↔ the disc and the left arc

    /// The puck's distance out, 0…1 of the ring's radius: the pad's square root.
    static func reach(_ saturation: Double) -> Double { min(max(saturation, 0), 1).squareRoot() }
    static func saturation(reach: Double) -> Double { let r = min(max(reach, 0), 1); return r * r }

    /// The arcs reach this far either side of the horizontal.
    static let arcHalfSpan = 50.0

    /// The left arc: reach 0 at its foot (230°), 1 at its head (130°). Unclamped either way, for a drag.
    static func strengthAngle(reach: Double) -> Double { 180 + arcHalfSpan - 2 * arcHalfSpan * reach }
    static func reach(strengthAngle a: Double) -> Double { (180 + arcHalfSpan - wrap(a)) / (2 * arcHalfSpan) }

    /// The right arc: luminance −1 at its foot (−50°), +1 at its head (+50°).
    static func lightnessAngle(_ luminance: Double) -> Double { arcHalfSpan * luminance }
    static func luminance(lightnessAngle a: Double) -> Double { signed(a) / arcHalfSpan }

    // MARK: The zone ↔ the puck

    /// The puck in ring radii from the centre (x right, y up).
    static func puck(_ zone: ColorZone) -> CGPoint {
        guard zone.saturation > 0 else { return .zero }
        let r = reach(zone.saturation), a = angle(hue: zone.hue) * .pi / 180
        return CGPoint(x: r * cos(a), y: r * sin(a))
    }

    /// The zone with its puck at `p` (ring radii, held to the ring): a puck within `centre` of the
    /// middle is no change, its hue kept so the left arc keeps its colour.
    static func zone(_ zone: ColorZone, puck p: CGPoint, centre: Double = 0.05) -> ColorZone {
        var z = zone
        let r = min(hypot(Double(p.x), Double(p.y)), 1)
        guard r > centre else { z.saturation = 0; return z }
        z.hue = (hue(angle: atan2(Double(p.y), Double(p.x)) * 180 / .pi) * 10).rounded() / 10
        z.saturation = (saturation(reach: r) * 10_000).rounded() / 10_000
        return z
    }

    static func wrap(_ a: Double) -> Double { let m = a.truncatingRemainder(dividingBy: 360); return m < 0 ? m + 360 : m }
    /// −180…180.
    static func signed(_ a: Double) -> Double { let w = wrap(a); return w > 180 ? w - 360 : w }

    // MARK: The drawing's places

    /// The parts of a large wheel of `size`: the ring, and the two arcs on a circle just outside it.
    struct Layout {
        enum Part: Equatable { case disc, strength, lightness }
        let centre: CGPoint
        let ring: CGFloat
        let arc: CGFloat

        init(_ size: CGSize) {
            centre = CGPoint(x: size.width / 2, y: size.height / 2)
            arc = max(min(size.width, size.height) / 2 - 10, 20)
            ring = arc - 16
        }

        /// A point at `angle` (counterclockwise from the right) `radius` out.
        func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
            let a = angle * .pi / 180
            return CGPoint(x: centre.x + radius * cos(a), y: centre.y - radius * sin(a))
        }

        /// A view point's distance out and angle.
        func polar(_ p: CGPoint) -> (r: CGFloat, angle: Double) {
            let dx = p.x - centre.x, dy = centre.y - p.y
            return (hypot(dx, dy), MacColourWheel.wrap(atan2(Double(dy), Double(dx)) * 180 / .pi))
        }

        /// What a press at `p` takes: the disc (with a little slack past the ring), an arc (its span and
        /// a little more, from the ring out), or nothing.
        func part(at p: CGPoint) -> Part? {
            let (r, a) = polar(p)
            if r <= ring + 7 { return .disc }
            guard r <= arc + 18 else { return nil }
            let slack = MacColourWheel.arcHalfSpan + 12
            if abs(a - 180) <= slack { return .strength }
            if abs(MacColourWheel.signed(a)) <= slack { return .lightness }
            return nil
        }
    }
}

/// The large wheel: the picked zone under the mouse.
struct MacColourWheelControl: View {
    let session: OpenFrameSession
    let zone: ColorBalance.Zone
    typealias Part = MacColourWheel.Layout.Part

    /// A press under way: what it is on, where the pointer and the value were when the value was last
    /// taken as the anchor (the press, or ⌥ pressed or let go), and whether it has moved.
    private struct Press {
        var part: Part
        var start: CGPoint
        var anchor: CGPoint
        var anchorPuck: CGPoint
        var anchorValue: Double
        var fine: Bool
        var moved = false
        /// The second click of a double click: the reset is done, the rest of the press does nothing.
        var spent = false
    }
    @State private var press: Press?
    /// The last click that did not move: a second within the interval, on the same part, is a double click.
    @State private var lastClick: (at: Date, point: CGPoint, part: Part)?
    @State private var hover: Part?
    /// AppKit's default double-click interval; UIKit does not say the user's.
    private static let doubleClick: TimeInterval = 0.5

    var body: some View {
        let value = session.adjustments.colorBalance[zone]
        GeometryReader { geo in
            let layout = MacColourWheel.Layout(geo.size)
            MacColourWheelFace(zone: value, active: press?.part ?? hover)
                .overlay {
                    Color.clear.contentShape(Rectangle())
                        .gesture(MacWheelPress { state, p, flags in handle(state, p, flags, layout) })
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let part = layout.part(at: p)
                        if part != hover { hover = part }
                        switch part {
                        case .disc: MacCursor.crosshair()
                        case .strength, .lightness: MacCursor.resize(sideways: false)
                        case nil: MacCursor.arrow()
                        }
                    case .ended:
                        hover = nil
                        MacCursor.arrow()
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Colour Wheels") + ", " + zone.padTitle)
        .accessibilityValue(value.padText)
        .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
        .accessibilityAction(named: L("Reset")) { reset(.disc) }
        .accessibilityIdentifier("adjust.wheels.pad")
        .onDisappear { if press.map({ !$0.spent }) == true { session.endedEdit() }; press = nil }
    }

    private func handle(_ state: UIGestureRecognizer.State, _ p: CGPoint, _ flags: UIKeyModifierFlags,
                        _ layout: MacColourWheel.Layout) {
        let fine = flags.contains(.alternate)
        switch state {
        case .began:
            guard let part = layout.part(at: p) else { press = nil; return }
            if let c = lastClick, Date().timeIntervalSince(c.at) < Self.doubleClick, c.part == part,
               hypot(p.x - c.point.x, p.y - c.point.y) < 6 {
                lastClick = nil
                reset(part)
                press = Press(part: part, start: p, anchor: p, anchorPuck: .zero, anchorValue: 0, fine: fine, spent: true)
                return
            }
            session.beganEdit()
            // A press puts the value under the pointer; with ⌥ it stays where it is, for a fine drag.
            if !fine { set(part, absolute: p, layout) }
            press = anchored(Press(part: part, start: p, anchor: p, anchorPuck: .zero, anchorValue: 0, fine: fine), at: p)
        case .changed:
            guard var pr = press, !pr.spent else { return }
            if hypot(p.x - pr.start.x, p.y - pr.start.y) > 3 { pr.moved = true }
            if fine != pr.fine { pr.fine = fine; pr = anchored(pr, at: p) }
            move(pr, to: p, layout)
            press = pr
        case .ended, .cancelled, .failed:
            guard let pr = press else { return }
            if !pr.spent { session.endedEdit() }
            lastClick = pr.moved || pr.spent || state != .ended ? nil : (Date(), p, pr.part)
            press = nil
        default: break
        }
    }

    /// The press with its anchor at the pointer and the value as it now is.
    private func anchored(_ pr: Press, at p: CGPoint) -> Press {
        var pr = pr
        let z = session.adjustments.colorBalance[zone]
        pr.anchor = p
        pr.anchorPuck = MacColourWheel.puck(z)
        pr.anchorValue = pr.part == .lightness ? z.luminance : MacColourWheel.reach(z.saturation)
        return pr
    }

    /// The pointer at `p` without ⌥: the value is where the pointer is.
    private func set(_ part: Part, absolute p: CGPoint, _ layout: MacColourWheel.Layout) {
        let (r, a) = layout.polar(p)
        switch part {
        case .disc:
            let u = Double(r / layout.ring), rad = a * .pi / 180
            apply(.disc, puck: CGPoint(x: u * cos(rad), y: u * sin(rad)))
        case .strength: apply(.strength, value: MacColourWheel.reach(strengthAngle: a))
        case .lightness: apply(.lightness, value: MacColourWheel.luminance(lightnessAngle: a))
        }
    }

    /// A drag: from the anchor, as far as the pointer went (a quarter as far with ⌥).
    private func move(_ pr: Press, to p: CGPoint, _ layout: MacColourWheel.Layout) {
        let k: Double = pr.fine ? 0.25 : 1
        switch pr.part {
        case .disc:
            let dx = Double(p.x - pr.anchor.x) / Double(layout.ring), dy = Double(pr.anchor.y - p.y) / Double(layout.ring)
            apply(.disc, puck: CGPoint(x: Double(pr.anchorPuck.x) + k * dx, y: Double(pr.anchorPuck.y) + k * dy))
        case .strength:
            let d = MacColourWheel.reach(strengthAngle: layout.polar(p).angle) - MacColourWheel.reach(strengthAngle: layout.polar(pr.anchor).angle)
            apply(.strength, value: pr.anchorValue + k * d)
        case .lightness:
            let d = MacColourWheel.luminance(lightnessAngle: layout.polar(p).angle) - MacColourWheel.luminance(lightnessAngle: layout.polar(pr.anchor).angle)
            apply(.lightness, value: pr.anchorValue + k * d)
        }
    }

    private func apply(_ part: Part, puck: CGPoint = .zero, value: Double = 0) {
        let now = session.adjustments.colorBalance[zone]
        var next = now
        switch part {
        case .disc: next = MacColourWheel.zone(now, puck: puck)
        case .strength: next.saturation = (MacColourWheel.saturation(reach: value) * 10_000).rounded() / 10_000
        case .lightness: next.luminance = (min(max(value, -1), 1) * 100).rounded() / 100
        }
        if next != now { session.changeEdit { $0.colorBalance[zone] = next } }
    }

    /// A double click: the disc's hue and strength, or an arc's value, back to rest. One step of Undo.
    private func reset(_ part: Part) {
        var z = session.adjustments.colorBalance[zone]
        switch part {
        case .disc: z.hue = 0; z.saturation = 0
        case .strength: z.saturation = 0
        case .lightness: z.luminance = 0
        }
        guard z != session.adjustments.colorBalance[zone] else { return }
        session.changeEdit { $0.colorBalance[zone] = z }
    }

    /// VoiceOver's swipe: a tenth of the way out or in along the puck's hue.
    private func step(_ by: Double) {
        let z = session.adjustments.colorBalance[zone]
        var next = z
        next.saturation = MacColourWheel.saturation(reach: (MacColourWheel.reach(z.saturation) + by * 0.1).clamped(to: 0...1))
        next.saturation = (next.saturation * 10_000).rounded() / 10_000
        if next != z { session.changeEdit { $0.colorBalance[zone] = next } }
    }
}

/// A wheel as drawn. Large: the ring, the puck and the centre's target, the hue's tick and the two arcs
/// with theirs. Small (a zone's tile): the ring and the puck only, with a frame round it when picked.
///
/// Drawn in shapes, not a `Canvas`: measured 2026-10-24 in the real window, a `Canvas` of the large
/// wheel's size ran its drawing again on every change (logged) and the window went on showing its
/// first frame, while the 48-point tiles' canvases updated.
struct MacColourWheelFace: View {
    let zone: ColorZone
    var small = false
    var picked = false
    /// The part under the pointer or the press, drawn a little stronger.
    var active: MacColourWheel.Layout.Part? = nil

    var body: some View {
        GeometryReader { geo in
            if small { smallFace(geo.size) } else { largeFace(geo.size) }
        }
    }

    @ViewBuilder private func largeFace(_ size: CGSize) -> some View {
        let l = MacColourWheel.Layout(size)
        let half = MacColourWheel.arcHalfSpan
        let reach = MacColourWheel.reach(zone.saturation)
        let neutral = zone.saturation <= 0
        let target = neutral ? Theme.accent : Theme.dim
        ZStack {
            ring(l, width: active == .disc ? 3.5 : 2.5)
            // The left arc, the strength: white at its foot to the hue at its head. Each arc is outlined
            // in the ground's rule first, so its white shows on Light Mode's ground.
            band(l, from: 180 + half, to: 180 - half, width: active == .strength ? 7 : 6,
                 colours: [.white, MacColourWheel.colour(hue: zone.hue)])
            // The right arc, the luminance: dark grey at its foot to white at its head.
            band(l, from: -half, to: half, width: active == .lightness ? 7 : 6,
                 colours: [Color(white: 0.22), .white])
            tick(l, angle: MacColourWheel.strengthAngle(reach: reach), at: l.arc, length: 8)
            tick(l, angle: MacColourWheel.lightnessAngle(min(max(zone.luminance, -1), 1)), at: l.arc, length: 8)
            // The centre's target: no change. While the zone has no colour, it is the puck.
            circle(l.centre, 5.5).stroke(target, lineWidth: neutral ? 2 : 1)
            circle(l.centre, 1.6).fill(target)
            if !neutral {
                tick(l, angle: MacColourWheel.angle(hue: zone.hue), at: l.ring, length: 7)
                let p = MacColourWheel.puck(zone)
                let k = CGPoint(x: l.centre.x + p.x * l.ring, y: l.centre.y - p.y * l.ring)
                let r: CGFloat = active == .disc ? 7.5 : 6.5
                // A halo of the ground under the accent keeps the puck readable over either ground.
                circle(k, r).stroke(Theme.background.opacity(0.7), lineWidth: 4)
                circle(k, r).stroke(Theme.accent, lineWidth: 2)
            }
        }
    }

    @ViewBuilder private func smallFace(_ size: CGSize) -> some View {
        let side = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let l = MacColourWheel.Layout(centre: c, ring: side / 2 - 4)
        ZStack {
            if picked { circle(c, side / 2 - 0.75).stroke(Theme.selectionFrame, lineWidth: 1.5) }
            ring(l, width: 2)
            if zone.saturation > 0 {
                let p = MacColourWheel.puck(zone)
                let k = CGPoint(x: c.x + p.x * l.ring, y: c.y - p.y * l.ring)
                circle(k, 3.2).fill(Theme.background.opacity(0.7))
                circle(k, 2.4).fill(Theme.accent)
            } else {
                circle(c, 3).stroke(Theme.dim, lineWidth: 1)
            }
        }
    }

    /// The hue ring: one conic gradient, its stops placed by `MacColourWheel.angle(hue:)`.
    private func ring(_ l: MacColourWheel.Layout, width: CGFloat) -> some View {
        circle(l.centre, l.ring).stroke(
            AngularGradient(stops: Self.ringStops, center: UnitPoint(x: 0.5, y: 0.5)), lineWidth: width)
            .frame(width: 2 * l.centre.x, height: 2 * l.centre.y)
    }

    /// A conic gradient turns clockwise on screen from the right; the ring's angles turn counterclockwise.
    /// A stop every 10° of hue, red at both ends.
    private static let ringStops: [Gradient.Stop] = {
        var stops = stride(from: 0.0, through: 350.0, by: 10).map { h in
            Gradient.Stop(color: MacColourWheel.colour(hue: h), location: (360 - MacColourWheel.angle(hue: h)).truncatingRemainder(dividingBy: 360) / 360)
        }
        stops.append(Gradient.Stop(color: MacColourWheel.colour(hue: 0), location: 1))
        return stops.sorted { $0.location < $1.location }
    }()

    /// An arc on the arcs' circle from `from` to `to` (degrees, counterclockwise), shaded from
    /// `colours[0]` at `from` to `colours[1]` at `to`.
    private func band(_ l: MacColourWheel.Layout, from: Double, to: Double, width: CGFloat, colours: [Color]) -> some View {
        let arc = Path { p in
            let n = 48
            p.move(to: l.point(from, l.arc))
            for i in 1...n { p.addLine(to: l.point(from + (to - from) * Double(i) / Double(n), l.arc)) }
        }
        // On screen (y down) an angle turns the other way: the gradient runs clockwise from the arc's
        // screen start to its end, whichever of the two is first clockwise.
        let s0 = -from, s1 = -to
        var lo = min(s0, s1), hi = max(s0, s1)
        if hi <= 0 { lo += 360; hi += 360 }
        let shade = AngularGradient(colors: s0 <= s1 ? colours : colours.reversed(), center: .center,
                                    startAngle: .degrees(lo), endAngle: .degrees(hi))
        return ZStack {
            arc.stroke(Theme.rule, style: StrokeStyle(lineWidth: width + 2, lineCap: .round, lineJoin: .round))
            arc.stroke(shade, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    /// A short line across a circle of `radius` at `angle`, with a halo of the ground under it.
    private func tick(_ l: MacColourWheel.Layout, angle: Double, at radius: CGFloat, length: CGFloat) -> some View {
        let line = Path { p in
            p.move(to: l.point(angle, radius - length))
            p.addLine(to: l.point(angle, radius + length))
        }
        return ZStack {
            line.stroke(Theme.background.opacity(0.6), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            line.stroke(Theme.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}

extension MacColourWheel.Layout {
    /// A small wheel's: the ring alone, no arcs.
    init(centre: CGPoint, ring: CGFloat) {
        self.centre = centre
        self.ring = ring
        self.arc = ring
    }
}

/// A mouse press held and moved, from its first moment: where it is, in the view's own space, and the
/// modifier keys (the event's own, the operating system 18 and later, as `MacMarqueeRecognizer` reads them).
private struct MacWheelPress: UIGestureRecognizerRepresentable {
    let action: (UIGestureRecognizer.State, CGPoint, UIKeyModifierFlags) -> Void
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        return press
    }
    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        action(recognizer.state, context.converter.localLocation, recognizer.modifierFlags)
    }
}
