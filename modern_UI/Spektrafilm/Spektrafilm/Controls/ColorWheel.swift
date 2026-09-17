//  ColorWheel.swift — Capture One's Color Balance: five tabs, a hue wheel with
//  a draggable point (angle = hue, radius = saturation), and **two arc sliders
//  per wheel** — saturation hugging the left of the circle, lightness the
//  right — drawn as arcs concentric with the wheel rather than as straight
//  sliders beside it.
//
//  The arrangement is the reference capture's (`PRD/capture_one_color_balance_
//  reference.png`): the **3-Way** tab is a triangle, midtone above and shadow
//  and highlight below it. That is not decoration — the right panel is 286 pt
//  wide (`Theme.Metric.rightPanelWidth`), and three wheels in one row would be
//  about 55 pt each, which is a control you cannot aim at. The reference puts
//  them in a triangle for the same reason.
//
//  The *colours and sizes* are ours: `Theme` tokens throughout, none of Capture
//  One's greys. This file adds no model and no uniforms — `ColorZone` already
//  carries `hue`, `saturation` and `luminance` per zone (`Model/Adjustments
//  .swift`), so all of this is arrangement and interaction over the state that
//  already exists.

import AppKit
import SwiftUI

struct ColorBalanceEditor: View {
    @Bindable var session: Session
    @State private var tab: Tab = .master
    /// The width the wheels are sized against: what the right panel gives a
    /// control inside a well (286 less the well's inset and padding on both
    /// sides — `ColorBalanceLayout.assumedWidth`, which a test pins).
    ///
    /// It was measured from the view for one iteration, and that was a mistake
    /// worth recording: the preference arrived as **zero** before the first
    /// layout and never came back, so every wheel was quietly sized to its
    /// floor — a capture showed a triangle at 64/44 pt where the arithmetic
    /// said 97/73, and nothing anywhere said "wrong", because a control sized
    /// to its minimum still looks like a control. A number the panel's own
    /// furniture decides belongs in one place with a name on it, where a test
    /// can check it, not in a preference that can be late, zero, or absent.
    /// The well's interior, which is what the wheels are sized against: the
    /// panel less the well's inset and padding on both sides
    /// (`ColorBalanceLayout.interior(panelWidth:)`).
    ///
    /// It is **given** rather than measured or assumed. Measured was tried for
    /// one iteration and was a mistake worth recording — the preference
    /// arrived as **zero** before the first layout and never came back, so every
    /// wheel was quietly sized to its floor, and a control sized to its minimum
    /// still looks like a control. Assumed was right while the panel had one
    /// width and is wrong the moment the panel is the user's: the editor now
    /// passes the width it actually has, and the fallback is the drawing's —
    /// which is what a caller with no width to give (a test, a page whose own
    /// drawing sets another one) gets.
    @Environment(\.colorBalanceWidth) private var width

    enum Tab: String, CaseIterable, Identifiable {
        case master, threeWay, shadows, midtones, highlights
        var id: String { rawValue }
        var title: String {
            // **Left in English.** The spec's right-rail table lists a plural
            // `Midtones` among the Exposure section's sliders, which is not
            // this tab — this one is the singular `Midtone`, and no row
            // matches it. Translating it would be a copy change (Midtone →
            // Midtones) rather than a lookup, so it stays; the spec's last
            // section records that the main editor's tables are not a whole
            // language pack.
            switch self {
            case .master: "Master"
            case .threeWay: "3-Way"
            case .shadows: "Shadow"
            case .midtones: "Midtone"
            case .highlights: "Highlight"
            }
        }
        /// The zone this tab edits, or nil for the three at once.
        var keyPath: WritableKeyPath<ColorBalance, ColorZone>? {
            switch self {
            case .master: \.master
            case .threeWay: nil
            case .shadows: \.shadows
            case .midtones: \.midtones
            case .highlights: \.highlights
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            tabs
            if let keyPath = tab.keyPath {
                ZoneWheel(zone: zone(keyPath), wheel: ColorBalanceLayout.single(width: width))
            } else {
                threeWay
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The tab row: five zones, the active one underlined in the accent — the
    /// arrangement the reference leads with, and the part our two-tab version
    /// was missing. The row is `CurveEditor`'s idiom, at five tabs and spread
    /// evenly, because at this width five labels do not fit side by side at
    /// their natural widths.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                let on = t == tab
                Button { tab = t } label: {
                    VStack(spacing: 4) {
                        Text(t.title).font(Theme.Font.tab).lineLimit(1)
                            // Five labels split the well evenly, and "Highlight"
                            // is the one that runs out first: at the drawing's
                            // width it fits by about two points, and a panel
                            // narrower than that ellipsized it to "Highli…".
                            // Scaling rather than truncating is what lets the
                            // right panel have a narrow end at all, and it costs
                            // the drawing nothing — at 286 the label is already
                            // inside its box, so it is drawn at full size and the
                            // snapshot is unchanged.
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
                        // Only the **active** tab is underlined. The
                        // inactive ones used to draw a 0.5 pt rule of their
                        // own, which joined up into a full-width line under
                        // the row — a separator between the tabs and their
                        // own content, which are not two things.
                        Rectangle().fill(on ? Theme.accent : Color.clear)
                            .frame(height: 1.5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var threeWay: some View {
        let layout = ColorBalanceLayout.threeWay(width: width)
        return VStack(spacing: 6) {
            ZoneWheel(zone: zone(\.midtones), wheel: layout.midtone, label: "Midtone")
            HStack(spacing: layout.gap) {
                // The two lower labels sit *above* their wheels: the row below
                // the midtone wheel is where its own label is, and a label under
                // a lower wheel would be the last thing in the panel, under the
                // wheel the user is dragging.
                ZoneWheel(zone: zone(\.shadows), wheel: layout.side, label: "Shadow", labelFirst: true)
                ZoneWheel(zone: zone(\.highlights), wheel: layout.side, label: "Highlight", labelFirst: true)
            }
        }
    }

    private func zone(_ kp: WritableKeyPath<ColorBalance, ColorZone>) -> Binding<ColorZone> {
        Binding(get: { session.adjustments.colorBalance[keyPath: kp] },
                set: { var a = session.adjustments; a.colorBalance[keyPath: kp] = $0; session.adjustments = a })
    }

}

// MARK: - one zone

/// A wheel with its two arcs. `hue` is the point's angle and `saturation` its
/// radius; the arcs carry saturation again (as a position along an arc rather
/// than a radius, which is what makes it grabbable) and luminance.
struct ZoneWheel: View {
    @Binding var zone: ColorZone
    let wheel: CGFloat
    var label: String? = nil
    /// The three-way layout's lower wheels label above rather than below.
    var labelFirst = false

    var body: some View {
        VStack(spacing: 4) {
            if labelFirst { labelText }
            // Concentric, not side by side: the arcs hug the rim, so their ends
            // curve back over the wheel's own square. Laid out in an HStack
            // they were clipped to their strip, and the parts beyond it — most
            // of each arc — were cut off. They overlap here and are drawn
            // *outside* the rim, so the only thing the overlap costs is that
            // their hit regions must be the arc itself rather than their
            // frame (see `ArcSlider.ArcHit`), or they would swallow the drag
            // that moves the wheel's point.
            ZStack {
                ArcSlider(value: $zone.saturation, range: 0...1, side: .left, wheel: wheel,
                          track: [Theme.dim, hueColour], neutral: 0)
                ArcSlider(value: $zone.luminance, range: -1...1, side: .right, wheel: wheel,
                          track: [Color.black.opacity(0.6), Theme.dim, Theme.text.opacity(0.9)], neutral: 0)
                disc.frame(width: wheel, height: wheel)
            }
            .frame(width: ColorBalanceLayout.band(wheel), height: ColorBalanceLayout.band(wheel))
            if !labelFirst { labelText }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var labelText: some View {
        if let label {
            Text(label).font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary).lineLimit(1)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    /// The zone's own colour, for the saturation arc's far end: Capture One
    /// tints that arc with the colour being added, and it is what makes the
    /// arc read as "this much of *this* colour" rather than as a grey scale.
    private var hueColour: Color {
        Color(hue: zone.hue / 360, saturation: 0.85, brightness: 0.95)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [
                Color(hue: 0, saturation: 0.6, brightness: 0.9), Color(hue: 1/6, saturation: 0.6, brightness: 0.9),
                Color(hue: 2/6, saturation: 0.6, brightness: 0.85), Color(hue: 3/6, saturation: 0.6, brightness: 0.9),
                Color(hue: 4/6, saturation: 0.6, brightness: 0.95), Color(hue: 5/6, saturation: 0.6, brightness: 0.9),
                Color(hue: 0, saturation: 0.6, brightness: 0.9)], center: .center,
                startAngle: .degrees(0), endAngle: .degrees(360)))
            Circle().fill(RadialGradient(colors: [Theme.card, Theme.card.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: wheel / 2))
            Circle().stroke(Theme.dim.opacity(0.6), lineWidth: 0.5)
            let r = CGFloat(zone.saturation) * (wheel / 2 - 5)
            let a = zone.hue * .pi / 180
            Circle().fill(Theme.text).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Theme.card, lineWidth: 1))
                .offset(x: cos(a) * r, y: -sin(a) * r)
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let c = CGPoint(x: wheel / 2, y: wheel / 2)
            let dx = g.location.x - c.x, dy = c.y - g.location.y
            let rr = min(hypot(dx, dy) / (wheel / 2 - 5), 1)
            var deg = atan2(dy, dx) * 180 / .pi
            if deg < 0 { deg += 360 }
            zone.hue = Double(deg)
            zone.saturation = Double(rr)
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { zone = ColorZone() })
    }
}

// MARK: - the arc

/// One arc slider: a track that hugs the wheel's rim and a thumb that rides it.
///
/// Both arcs put **the top of the arc at the top of the range**, and both read
/// left-to-right the same way up their own side: bottom = minimum, top =
/// maximum. The track's gradient says which is which — grey at the bottom for
/// a saturation of zero, the zone's own hue at the top; black through grey to
/// white for lightness.
struct ArcSlider: View {
    typealias Side = ColorBalanceLayout.Side

    @Binding var value: Double
    let range: ClosedRange<Double>
    let side: Side
    /// The wheel this arc hugs, so the two agree without either knowing the
    /// other's frame.
    let wheel: CGFloat
    /// The track's gradient, from the minimum end to the maximum end.
    let track: [Color]
    /// What a double-click puts back.
    let neutral: Double

    private var gap: CGFloat { ColorBalanceLayout.arcGap(wheel) }
    private static let weight = ColorBalanceLayout.arcWeight
    private var thumbLength: CGFloat { ColorBalanceLayout.thumb(wheel) }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = wheel / 2 + gap
            // The track, drawn in segments: a gradient that follows the arc.
            // One `stroke` with a linear shading would run straight across the
            // curve, which reads as wrong the moment the arc is anything but
            // vertical.
            let segments = 24
            for i in 0..<segments {
                let t = Double(i + 1) / Double(segments)
                var segment = Path()
                segment.move(to: point(c, r, fraction: Double(i) / Double(segments)))
                segment.addLine(to: point(c, r, fraction: t))
                ctx.stroke(segment, with: .color(colour(at: t)),
                           style: StrokeStyle(lineWidth: Self.weight, lineCap: .round))
            }
            // The thumb: a tick across the track, dark under light so it reads
            // on both ends of the gradient.
            var tick = Path()
            tick.move(to: point(c, r - thumbLength, fraction: fraction))
            tick.addLine(to: point(c, r + thumbLength, fraction: fraction))
            ctx.stroke(tick, with: .color(Theme.card),
                       style: StrokeStyle(lineWidth: Self.weight + 1.6, lineCap: .round))
            ctx.stroke(tick, with: .color(Theme.knob),
                       style: StrokeStyle(lineWidth: Self.weight - 0.4, lineCap: .round))
        }
        // The arc itself is the hit region, not the square it is drawn in: the
        // square overlaps the wheel (the arcs curve back over it), and a frame
        // that took every click inside it would take the drag meant for the
        // wheel's point.
        .contentShape(ArcHit(wheel: wheel, side: side))
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            // The angle about the *wheel*, not the touch's radius: the arc is
            // thin, and a drag that wanders off it radially should still track.
            value = value(at: g.location, centre: CGPoint(x: bandWidth / 2, y: bandWidth / 2))
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = neutral })
    }

    private var bandWidth: CGFloat { ColorBalanceLayout.band(wheel) }

    /// The track as a shape: the arc, stroked to something a hand can find.
    /// `contentShape` wants a `Shape`, and this is the one region of the
    /// slider's square that belongs to the slider — the track itself, not the
    /// strip around it, because the square overlaps the wheel.
    struct ArcHit: Shape {
        let wheel: CGFloat
        let side: Side
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = wheel / 2 + ColorBalanceLayout.arcGap(wheel)
            var arc = Path()
            let steps = 48
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let theta = ColorBalanceLayout.Arc.theta(fraction: t, on: side) * .pi / 180
                let p = CGPoint(x: c.x + r * cos(theta), y: c.y - r * sin(theta))
                if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
            }
            return arc.strokedPath(StrokeStyle(lineWidth: ColorBalanceLayout.hitWidth(wheel),
                                               lineCap: .round))
        }
    }

    /// The point at `fraction` along the arc, 0 at the minimum end and 1 at the
    /// maximum. Angles are the usual mathematical ones (0° = right, 90° = up)
    /// with y flipped, so this reads the same way as the wheel's own hue
    /// arithmetic.
    private func point(_ c: CGPoint, _ r: CGFloat, fraction: Double) -> CGPoint {
        let theta = ColorBalanceLayout.Arc.theta(fraction: fraction, on: side) * .pi / 180
        return CGPoint(x: c.x + r * cos(theta), y: c.y - r * sin(theta))
    }

    private var fraction: Double { ColorBalanceLayout.Arc.fraction(value, in: range) }

    private func value(at p: CGPoint, centre c: CGPoint) -> Double {
        ColorBalanceLayout.Arc.value(atAngle: ColorBalanceLayout.Arc.angle(of: p, about: c),
                                     on: side, in: range)
    }

    /// The track's colour at `fraction`: the gradient's stops, interpolated in
    /// the same parameter the geometry uses.
    private func colour(at fraction: Double) -> Color {
        guard track.count > 1 else { return track.first ?? Theme.dim }
        let x = fraction.clamped(to: 0...1) * Double(track.count - 1)
        let i = min(Int(x), track.count - 2)
        return track[i].interpolate(to: track[i + 1], amount: x - Double(i))
    }
}

// MARK: - the arithmetic

/// Where the wheels go, as arithmetic rather than as literals in a body.
///
/// The three-way triangle has one hard constraint — it must fit the width the
/// panel gives it — and "does it fit" is a question a test can answer without a
/// window, which is why the sizes are a function of the width and not constants
/// buried in a `frame(width:)`. (The same trick `Session.wantsFullRender` uses
/// for the native render, and `Diagnostics.projection` for the memory forecast.)
enum ColorBalanceLayout {
    /// The track's distance outside the wheel's rim, its weight, and the
    /// thumb's half-length. (The arc's own sweep lives with the arithmetic, in
    /// `ColorBalanceLayout.Arc`.)
    // MARK: the ring, which is a proportion of its wheel
    //
    // These were four constants — `arcGap` 3.5, `thumb` 4.5, `hitWidth` 14 —
    // and two things were wrong with that.
    //
    // **The arcs sat on the wheel.** A 14 pt hit band centred 3.5 pt outside
    // the rim covers the outer 3.5 pt of the wheel itself, so a drag begun
    // near the rim moved a slider instead of the colour. Capture One leaves a
    // clear ring of background between a wheel and its dial, and that gap is
    // what lets the two be aimed at separately.
    //
    // **A constant gap cannot be right at both sizes.** The three-way tab
    // draws wheels of 44 pt at the rail's narrow end and the single-zone tabs
    // draw one of 150; a ring that reads well around the large one swallows
    // the small one's column, and simply widening the constant overflowed the
    // narrow rail. So the ring is a proportion of its own wheel, with floors
    // that keep it aimable and ceilings that stop it becoming a target in its
    // own right.

    /// The track's distance outside the rim.
    static func arcGap(_ wheel: CGFloat) -> CGFloat { (wheel * 0.09).clamped(to: 4.5...10) }
    /// The thumb's half-length, across the track.
    static func thumb(_ wheel: CGFloat) -> CGFloat { (wheel * 0.05).clamped(to: 3...5) }
    static let arcWeight: CGFloat = 3

    /// How wide a touch has to be to count as a touch on an arc.
    ///
    /// Bounded by the gap, and that is the invariant rather than the number:
    /// the band is centred on the track, so it reaches `hitWidth / 2` inward,
    /// and staying under `arcGap` is what keeps it off the wheel.
    /// `testTheArcsDoNotReachIntoTheWheel` asserts it at every size.
    static func hitWidth(_ wheel: CGFloat) -> CGFloat { min(16, 2 * arcGap(wheel) - 1.5) }

    /// How far one arc slider reaches outside the wheel: the gap to the rim
    /// plus the thumb that rides the track.
    static func arcBand(_ wheel: CGFloat) -> CGFloat { arcGap(wheel) + thumb(wheel) + 1 }

    /// The square one wheel and its two arcs occupy — the arcs curve back over
    /// the wheel, so they are concentric with it rather than laid out beside
    /// it, and this is the whole of what they need.
    static func band(_ wheel: CGFloat) -> CGFloat { wheel + 2 * arcBand(wheel) }

    /// What a control inside a well gets from a panel of `panelWidth`: the
    /// panel less the well's inset and padding on both sides.
    ///
    /// One function rather than the arithmetic twice, because the editor passes
    /// its live panel width through here and the drawing's fixed width comes
    /// through the same door — so a well that changes its padding cannot change
    /// it for one caller and not the other.
    /// The room the wheels are sized against: the rail less the inset its
    /// section is padded by.
    ///
    /// It was `wellInset + wellPadding` while the triangle sat in a well. The
    /// 2026-09-17 drawing keeps two wells in the whole interface and neither
    /// is this one, so the number that has to be mirrored here is the one the
    /// section actually pads with — `plotInset`. Two spellings of one inset is
    /// exactly how the wheels came to be sized against a well the editor did
    /// not draw.
    static func interior(panelWidth: CGFloat) -> CGFloat {
        panelWidth - 2 * Theme.Metric.plotInset
    }

    /// The drawing's own interior, and the fallback for a caller with no width
    /// to give. It is the width a fresh install has, so it is also the width a
    /// test can check the triangle against.
    static let assumedWidth: CGFloat = interior(panelWidth: Theme.Metric.rightPanelWidth)

    /// Room for one zone label and the gap above or below it.
    static let labelHeight: CGFloat = 15

    struct ThreeWay: Equatable {
        var midtone: CGFloat
        var side: CGFloat
        /// The gap between the two lower wheels.
        var gap: CGFloat
        /// Total height, labels included.
        var height: CGFloat
        /// Whether the two lower wheels fit side by side in the width asked
        /// about. False is a real answer — the panel has a floor — and the view
        /// is expected to be given more room rather than to overlap.
        var fits: Bool
    }

    /// The triangle: one wheel centred above two, as the reference draws it.
    ///
    /// The proportions are the reference's (the midtone wheel is about 0.40 of
    /// the panel's inner width and the lower two about 0.30), with floors so
    /// the controls stay aimable and ceilings so they do not grow absurd on a
    /// wide window.
    static func threeWay(width: CGFloat) -> ThreeWay {
        let width = max(width, 1)
        let midtone = (width * 0.40).clamped(to: 64...120)
        let side = (width * 0.30).clamped(to: 44...96)
        let gap = max(6, width * 0.03)
        // A wheel's column is the square its arcs need, not the wheel alone.
        let fits = 2 * band(side) + gap <= width
        let height = band(midtone) + labelHeight + 6 + labelHeight + band(side)
        return ThreeWay(midtone: midtone, side: side, gap: gap, height: height, fits: fits)
    }

    /// One large wheel for the single-zone tabs.
    static func single(width: CGFloat) -> CGFloat {
        // `arcBand` depends on the wheel, so solve for it: take the wheel the
        // width suggests, then shrink it by the band that wheel would want.
        // One pass is enough — the band is at most 16 and the clamp catches
        // the rest.
        let raw = (max(width, 1) * 0.55).clamped(to: 64...150)
        return (raw - 2 * arcBand(raw)).clamped(to: 64...150)
    }

    enum Side: Equatable { case left, right }

    /// What an arc's position *means*: which end of it is the minimum, which is
    /// the maximum, and what a drag at a given angle sets.
    ///
    /// It is here rather than in the view because "drag up gives more
    /// saturation" is exactly the sort of thing that inverts silently in a body
    /// and then reads as a broken control rather than as a bug — and because
    /// the view and the test can then ask the same function instead of one
    /// asserting what the other happens to draw.
    ///
    /// Angles are the mathematical ones (0° = right, 90° = up), with y flipped
    /// where a view's coordinates are involved. **The top of the arc is the top
    /// of the range, on both sides.** The two sides differ in which way round
    /// the circle they run: the left arc's angles *decrease* as the value
    /// rises (245° at the bottom to 115° at the top) and the right arc's
    /// *increase* (−65° to 65°).
    enum Arc {
        /// Degrees each side spans, centred on its own side of the wheel. 130
        /// leaves a deliberate gap at the top and the bottom, which is what
        /// keeps the left arc from reading as a continuation of the right one.
        static let sweep: Double = 130

        static func bottomTheta(_ side: Side) -> Double { side == .left ? 245 : -65 }
        static func topTheta(_ side: Side) -> Double { side == .left ? 245 - sweep : -65 + sweep }

        /// The angle at `fraction` along the arc: 0 at the minimum end, 1 at
        /// the maximum.
        static func theta(fraction: Double, on side: Side) -> Double {
            let f = fraction.clamped(to: 0...1)
            return bottomTheta(side) + (topTheta(side) - bottomTheta(side)) * f
        }

        /// The angle of `p` about `c`, in the same orientation, normalised to
        /// (−180, 180].
        static func angle(of p: CGPoint, about c: CGPoint) -> Double {
            let theta = atan2(c.y - p.y, p.x - c.x) * 180 / .pi
            return theta > 180 ? theta - 360 : theta
        }

        /// Where a touch at `theta` lands in `range`. A touch past either end
        /// clamps to that end — the arc is thin, and a drag that wanders off it
        /// should track rather than jump.
        ///
        /// **`theta` is brought onto this arc's own turn first**, and that is
        /// not a nicety. `angle(of:about:)` normalises to (−180, 180], while
        /// the left arc runs 115°…245° — so every point on its lower half came
        /// back negative (the bottom of the arc, 245°, arrives as −115°), fell
        /// outside the span, and clamped to **1**. Dragging the lower half of
        /// the saturation arc did not move it down; it slammed it to maximum.
        ///
        /// The right arc spans −65°…65°, never crosses the seam, and was
        /// always fine — which is why this looked like a wheel bug rather than
        /// an arithmetic one.
        ///
        /// The unit tests did not catch it because they call this function
        /// with the arc's *own* angles (`bottomTheta(.left)` is 245) and the
        /// view calls it with what `angle(of:about:)` returns. Two domains,
        /// one function, and the seam between them is where the defect lived.
        static func value(atAngle theta: Double, on side: Side, in range: ClosedRange<Double>) -> Double {
            let bottom = bottomTheta(side), top = topTheta(side)
            let mid = (bottom + top) / 2
            var t = theta
            while t - mid > 180 { t -= 360 }
            while t - mid < -180 { t += 360 }
            let f = ((t - bottom) / (top - bottom)).clamped(to: 0...1)
            return range.lowerBound + f * (range.upperBound - range.lowerBound)
        }

        /// The arc position a value sits at: 0 at the minimum, 1 at the maximum.
        static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
            ((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9)).clamped(to: 0...1)
        }
    }
}

private extension Color {
    /// A straight interpolation in sRGB. Two stops per arc is all any of these
    /// use, and a perceptual interpolation would be a lie about what the slider
    /// does: the value is linear in the arc's parameter, so the colour should
    /// be too.
    func interpolate(to other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        let t = CGFloat(amount.clamped(to: 0...1))
        return Color(.sRGB,
                     red: a.redComponent + (b.redComponent - a.redComponent) * t,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                     opacity: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }
}

// MARK: - how wide to draw

/// How wide the colour balance controls should draw themselves.
///
/// An environment value because the width belongs to the *panel* and is used
/// three views down — inside a section, inside a well — so threading it as a
/// parameter would put it on every section's signature to be used by one of
/// them. The default is the drawing's own interior, so a caller that never sets
/// it behaves exactly as it did before the editor's panels became resizable.
private struct ColorBalanceWidthKey: EnvironmentKey {
    static let defaultValue = ColorBalanceLayout.assumedWidth
}

extension EnvironmentValues {
    var colorBalanceWidth: CGFloat {
        get { self[ColorBalanceWidthKey.self] }
        set { self[ColorBalanceWidthKey.self] = newValue }
    }
}
