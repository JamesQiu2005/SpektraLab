//  ColorWheel.swift — the colour-balance wheels' arithmetic: where they go,
//  and what a point on one means.
//
//  The wheels themselves are drawn by Post-Dev's Colour section
//  (`Panels/Edit/ColourSection.swift`): three in a row — Shadows, Midtones,
//  Highlights — with the selected zone's Luminance under them. This file is
//  the part of them a test can hold without a window.
//
//  **A wheel's hue runs clockwise on screen**, because that is the way
//  SwiftUI's `AngularGradient` paints the colours under the point: from red at
//  3 o'clock through yellow (60°) at about 5 o'clock to green (120°) at about
//  7 o'clock. 1.3's wheel measured the point's angle the mathematical way —
//  counter-clockwise, y up — so the point said one hue and the picture got
//  its mirror: a point dragged onto the blue of the wheel tinted the print
//  green. Measured on the 1.3 gradient: the drawn colour at 120°
//  counter-clockwise is hue 237. Only red and cyan, on the axis, agreed.
//  `Wheel` below is the one place the angle is read, in the gradient's
//  orientation, and `ColorBalanceTests` holds it to the gradient.
//
//  The 3-way triangle and the arc sliders 1.3 drew (`threeWay`, `single`,
//  `Arc`) are kept below as arithmetic: the window still sizes the rail's
//  wheels through `interior(panelWidth:)`, and their tests still describe a
//  layout the rail may come back to. No view draws them now.

import SwiftUI

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

// MARK: - three in a row, and what a point means

extension ColorBalanceLayout {
    /// The Colour section's row: three wheels side by side, each with its
    /// label under it.
    ///
    /// The triangle above was for wheels that carried two arcs each; without
    /// the arcs three wheels fit across the rail at a size a pointer can aim
    /// at — about 80 pt at the drawing's width, against 72 for the triangle's
    /// lower pair.
    struct Row: Equatable {
        var wheel: CGFloat
        var gap: CGFloat
        /// Whether the three fit the width asked about.
        var fits: Bool
    }

    static func row(width: CGFloat) -> Row {
        let width = max(width, 1)
        let gap = max(8, width * 0.04)
        let wheel = ((width - 2 * gap) / 3).clamped(to: 44...96)
        return Row(wheel: wheel, gap: gap, fits: 3 * wheel + 2 * gap <= width + 0.5)
    }

    /// The point on a wheel and the zone it stands for. Coordinates are the
    /// view's — origin at the wheel's centre, x right, **y down** — and the
    /// radius is the distance a saturation of 1 sits from the centre.
    enum Wheel {
        /// The colours round the wheel, red at 3 o'clock, clockwise on
        /// screen. The view fills its disc with this and a test samples it,
        /// so the two are one gradient.
        static let gradient = AngularGradient(colors: [
            Color(hue: 0, saturation: 0.6, brightness: 0.9), Color(hue: 1/6, saturation: 0.6, brightness: 0.9),
            Color(hue: 2/6, saturation: 0.6, brightness: 0.85), Color(hue: 3/6, saturation: 0.6, brightness: 0.9),
            Color(hue: 4/6, saturation: 0.6, brightness: 0.95), Color(hue: 5/6, saturation: 0.6, brightness: 0.9),
            Color(hue: 0, saturation: 0.6, brightness: 0.9)], center: .center,
            startAngle: .degrees(0), endAngle: .degrees(360))

        /// Where a zone's point is drawn.
        static func point(hue: Double, saturation: Double, radius: CGFloat) -> CGPoint {
            let a = hue * .pi / 180
            let r = CGFloat(saturation.clamped(to: 0...1)) * radius
            return CGPoint(x: cos(a) * r, y: sin(a) * r)
        }

        /// The hue and saturation of a point: its angle clockwise from 3
        /// o'clock, and its distance from the centre as a fraction of the
        /// radius, held to 1.
        static func zone(at p: CGPoint, radius: CGFloat) -> (hue: Double, saturation: Double) {
            guard radius > 0 else { return (0, 0) }
            var hue = atan2(Double(p.y), Double(p.x)) * 180 / .pi
            if hue < 0 { hue += 360 }
            let s = (Double(hypot(p.x, p.y)) / Double(radius)).clamped(to: 0...1)
            return (s == 0 ? 0 : hue, s)
        }

        /// A drag that began at `start` (the point where the zone's point was,
        /// not where the pointer went down) and has travelled `travel`: the
        /// point moves by the travel, so taking hold of it never moves it.
        static func dragged(from start: CGPoint, by travel: CGSize, radius: CGFloat) -> (hue: Double, saturation: Double) {
            zone(at: CGPoint(x: start.x + travel.width, y: start.y + travel.height), radius: radius)
        }
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
