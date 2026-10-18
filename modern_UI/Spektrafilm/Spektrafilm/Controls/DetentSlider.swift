//  DetentSlider.swift — a slider whose thumb stops.
//
//  Written for the export page's grid-size control, where the value is a
//  **count of columns** and there is no such thing as four and a half of them.
//  The user asked for exactly that: "instead of smooth resize, the slide need
//  to stop at some point controlling the amount of columns, not 无极" — so the
//  thumb has one position per stop, a drag lands on one rather than resting
//  between two, and the stops are drawn so the discrete feel is visible rather
//  than something you discover by fighting it.
//
//  **Its own control, not `ScrubSlider` with `snap` set.** `ScrubSlider` is the
//  editor's — eleven parameters' worth of scrub, snap-on-shift, a zero tick and
//  an editable value field — and every one of those is wrong here: snapping
//  only while ⇧ is held is the *opposite* of always landing on a stop, and a
//  field you can type 4.5 into would route around the whole point. Bending the
//  shared one would also mean the editor's panels inherit a control whose drag
//  arithmetic now rounds, which is a change to eleven sliders nobody asked
//  for. Two sliders is the smaller cost, and this one is thirty lines.

import SwiftUI

struct DetentSlider: View {
    /// The stop, not a fraction of the way between two of them.
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// The track's own width, so a caller can put it where a row of other
    /// controls sits and have both states occupy the same span.
    var width: CGFloat
    /// The knob and the track, from the same tokens the editor's slider uses,
    /// so the two read as the same family on a page that draws both.
    var metrics = SliderMetrics()
    var help: String?
    /// **V5:** the stop the control rests on — drawn as the rest mark, the
    /// fill runs from it to the thumb, and a double-click returns to it. Nil
    /// draws neither and resets nothing.
    var rest: Int? = nil
    /// The VoiceOver name; the value is the stop.
    var accessibilityName: String = ""

    /// The stop the drag began on. **Relative (V5):** a press moves nothing;
    /// the thumb steps one stop per pitch of travel from where it was.
    @State private var dragStart: Int?

    /// The thumb is this wide, so the travel is the track less one thumb —
    /// the same rule `ScrubSlider` measures its own x by.
    private var knobWidth: CGFloat { Theme.Metric.knobSize.width }

    /// The stop a drag has reached: `start` plus whole pitches of travel.
    /// `internal static` for the same reason as `nearest(to:)`.
    static func stepped(from start: Int, translation: CGFloat, width: CGFloat, range: ClosedRange<Int>,
                        knobWidth: CGFloat = Theme.Metric.knobSize.width) -> Int {
        let count = range.upperBound - range.lowerBound
        guard count > 0 else { return range.lowerBound }
        let pitch = max(width - knobWidth, 1) / CGFloat(count)
        return (start + Int((translation / pitch).rounded())).clamped(to: range)
    }

    private var stops: [Int] { Array(range) }

    private func position(_ v: Int) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let f = CGFloat(v - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
        return f * (width - knobWidth) + knobWidth / 2
    }

    /// The nearest stop to a point on the track — the rule for an *absolute*
    /// position. The drag is relative since V5 (`stepped(from:…)`), so a
    /// press no longer jumps the thumb here; this stays the arithmetic of
    /// where each stop is, and the binding is still never between two stops.
    ///
    /// `internal` rather than private, and static, so a test can reach it —
    /// "a drag lands on a stop" is the one promise this control makes and it
    /// is arithmetic, not a view. `HoverBand` is internal for the same reason.
    static func nearest(to x: CGFloat, width: CGFloat, range: ClosedRange<Int>,
                        knobWidth: CGFloat = Theme.Metric.knobSize.width) -> Int {
        let travel = max(width - knobWidth, 1)
        let f = Double(((x - knobWidth / 2) / travel).clamped(to: 0...1))
        let raw = Double(range.lowerBound) + f * Double(range.upperBound - range.lowerBound)
        return Int(raw.rounded()).clamped(to: range)
    }

    private func nearest(to x: CGFloat) -> Int {
        Self.nearest(to: x, width: width, range: range, knobWidth: knobWidth)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Theme.dim)
                .frame(height: metrics.trackHeight)
                .padding(.horizontal, knobWidth / 2)

            // The fill from the rest stop to the thumb (V5).
            if let rest, rest != value {
                let a = position(min(rest, value)), b = position(max(rest, value))
                Capsule().fill(Theme.sliderFill)
                    .frame(width: b - a, height: metrics.trackHeight)
                    .offset(x: a)
            }

            // The stops themselves. Without them a control that refuses to
            // sit where you put it reads as a fault; with them the positions
            // are the ones it can reach, and the count is legible at a glance.
            // The rest stop is the taller, `restMark` one.
            ForEach(stops, id: \.self) { stop in
                Capsule()
                    .fill(stop == rest ? Theme.restMark : Theme.text.opacity(stop == value ? 0 : 0.25))
                    .frame(width: 1, height: metrics.trackHeight + (stop == rest ? 6 : 4))
                    .offset(x: position(stop) - 0.5)
            }

            RoundedRectangle(cornerRadius: Theme.Metric.knobRadius, style: .continuous)
                .fill(Theme.knob)
                .frame(width: knobWidth, height: Theme.Metric.knobSize.height)
                .scaleEffect(dragStart != nil ? Theme.Motion.contactScale : 1)
                .offset(x: position(value) - knobWidth / 2)
        }
        .frame(width: width, height: metrics.rowHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    let next = Self.stepped(from: dragStart ?? value, translation: g.translation.width,
                                            width: width, range: range, knobWidth: knobWidth)
                    if next != value { value = next }
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { if let rest { value = rest } })
        .help(help ?? "")
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = (value + 1).clamped(to: range)
            case .decrement: value = (value - 1).clamped(to: range)
            @unknown default: break
            }
        }
    }
}
