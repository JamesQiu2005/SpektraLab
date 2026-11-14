//  SliderMapping.swift — the slider's arithmetic: where the knob is for a value, and the value under the pointer.
//
//  `SliderTrack` draws a fixed track and a knob at the value. This is what it computes, with no view in it, so
//  `tools/slider_selftest.swift` can hold it (2026-11-11, "滑块有时不太准").

import CoreGraphics
import Foundation

struct SliderMapping: Equatable {
    var range: ClosedRange<Double>
    /// The track's width in points: the whole range across it.
    var width: CGFloat
    var rest: Double = 0
    var step: Double? = nil
    var detentAtRest = false

    /// A press this near the knob's middle takes the knob (it is 9 pt wide; a little to spare either side).
    static let grabHalfWidth: CGFloat = 8
    /// The knob's half width, as `SliderTrack` draws it.
    static let knobHalfWidth: CGFloat = 4.5

    var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }

    /// The knob's middle for `value`.
    func x(_ value: Double) -> CGFloat {
        CGFloat((value.clamped(to: range) - range.lowerBound) / span) * max(width, 1)
    }

    /// The value under `x`, before any snapping.
    func raw(_ x: CGFloat) -> Double {
        (range.lowerBound + Double(x / max(width, 1)) * span).clamped(to: range)
    }

    /// Held at rest within 1.2 % of the span (where the control has a detent), then on the step.
    func snapped(_ v: Double) -> Double {
        if detentAtRest, range.contains(rest), abs(v - rest) <= span * 0.012 { return rest }
        guard let step, step > 0 else { return v.clamped(to: range) }
        return ((v / step).rounded() * step).clamped(to: range)
    }

    /// A drag from the press: how far from the knob's middle the pointer took it.
    struct Drag: Equatable {
        /// Pointer minus knob, kept for the whole drag: the press's distance from the knob's middle where the
        /// press was on the knob, and 0 where it was on the track (the knob came to the pointer).
        var grab: CGFloat
    }

    /// A press at `x` with the knob at `value`. On the knob (within `grabHalfWidth` of its middle) the knob is
    /// taken where it was pressed and nothing moves; anywhere else on the track the knob comes to the pointer.
    func begin(at x: CGFloat, value: Double) -> Drag {
        let off = x - self.x(value)
        return Drag(grab: abs(off) <= Self.grabHalfWidth ? off : 0)
    }

    /// The value for the pointer at `x`: absolute, so the knob stays where the pointer has it (until 2026-11-11
    /// it was relative to the press — the value moved by the pointer's travel — and a press on the track left
    /// the knob that far from the pointer for the whole drag; the pointer past an end and back stayed apart too).
    func value(_ drag: Drag, at x: CGFloat) -> Double {
        snapped(raw(x - drag.grab))
    }
}

/// The number box's drag (Capture One's and Photoshop's scrubbing): a horizontal drag on the number moves the
/// value, the whole range in `pointsPerSpan`; ⇧ coarse, ⌥ fine; on the control's step and held at its ends.
struct SliderScrub: Equatable {
    /// The whole range across this many points at the normal rate.
    static let pointsPerSpan: Double = 300
    /// A press that moves less than this is a click (it opens the number for typing), not a drag.
    static let threshold: CGFloat = 3
    static func factor(shift: Bool, option: Bool) -> Double { shift ? 5 : option ? 0.1 : 1 }

    private(set) var anchorX: CGFloat
    private(set) var anchorValue: Double
    private(set) var factor: Double

    init(at x: CGFloat, value: Double, factor: Double = 1) {
        anchorX = x; anchorValue = value; self.factor = factor
    }

    /// The value for the pointer at `x` with this rate. A change of rate takes up from where the value is (no jump),
    /// and a value held at an end takes up from the end (the pointer coming back moves it at once).
    mutating func value(at x: CGFloat, factor f: Double, _ m: SliderMapping) -> Double {
        if f != factor {
            anchorValue = unsnapped(at: x, m)
            anchorX = x
            factor = f
        }
        let v = unsnapped(at: x, m)
        if v <= m.range.lowerBound || v >= m.range.upperBound {
            anchorValue = v.clamped(to: m.range); anchorX = x
        }
        guard let step = m.step, step > 0 else { return v.clamped(to: m.range) }
        return ((v / step).rounded() * step).clamped(to: m.range)
    }

    private func unsnapped(at x: CGFloat, _ m: SliderMapping) -> Double {
        (anchorValue + Double(x - anchorX) * m.span / Self.pointsPerSpan * factor).clamped(to: m.range)
    }

    /// ↑ / ↓ in the number box: one step (the control's own, or a 100th of the range rounded to 1, 2 or 5 of a
    /// power of ten — 1 on Brightness's ±50, 2 on ±100, 0.05 on ±3 EV), ⇧ ten, ⌥ a tenth — never less than the
    /// control's own step.
    static func keyStep(_ value: Double, up: Bool, shift: Bool, option: Bool, _ m: SliderMapping) -> Double {
        let base = m.step ?? nice(m.span / 100)
        var d = base * (shift ? 10 : option ? 0.1 : 1)
        if let step = m.step, step > 0 { d = max(step, (d / step).rounded() * step) }
        let next = (value + (up ? d : -d)).clamped(to: m.range)
        guard let step = m.step, step > 0 else { return next }
        return ((next / step).rounded() * step).clamped(to: m.range)
    }

    /// The nearest of 1, 2 and 5 times a power of ten.
    static func nice(_ x: Double) -> Double {
        guard x > 0, x.isFinite else { return 1 }
        let p = pow(10, (log10(x)).rounded(.down))
        return [1.0, 2, 5, 10].map { $0 * p }.min(by: { abs($0 - x) < abs($1 - x) }) ?? x
    }
}
