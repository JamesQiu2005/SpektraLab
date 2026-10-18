//  ScrubSlider.swift — the one slider. Label | track with a pill knob | value.
//
//  Built once and used everywhere. Drag anywhere on the track, ⌥ for ×0.25
//  sensitivity, ⇧ snaps to `snap`, double-click resets to `zero`, and the
//  value column is an editable field. `onCommit` fires on release; continuous
//  updates go through the binding while dragging.
//
//  **V5 (2026-10-18) refined five things, and the drawing did not move:**
//
//  - **The drag is relative.** A press anywhere on the row moves nothing; the
//    value follows the pointer's *travel* from where it landed. It used to
//    jump to the click point first, so the first click of a double-click
//    reset moved the value before the reset put it back, and a click meant to
//    grab the knob nudged it.
//  - **The rest is drawn.** A mark at `zero` (the rest, or home, value) on
//    every slider, and a fill from that mark to the knob, so how far a value
//    has moved is read off the track rather than worked out from a number.
//  - **The value is read on the row, never in a bubble**, and a bare value
//    (no pill) is dim at rest (`Theme.Ink.value(atRest:)`). A value in a
//    pill keeps its ink — see the note at `valueField`.
//  - **Contact is acknowledged** by the knob growing while a drag holds it —
//    not under Reduce Motion.
//  - **VoiceOver** reads the label and the value, adjusts by one `snap` step
//    per swipe, and offers Reset.

import SwiftUI

/// The arithmetic of a scrub, apart from the view so a test can hold it.
enum ScrubDrag {
    /// The value a drag has reached: where the drag **began** plus the
    /// pointer's travel as a fraction of the track, never the point under
    /// the pointer. `travel` is the track less one knob.
    static func value(from start: Double, translation: CGFloat, travel: CGFloat,
                      range: ClosedRange<Double>, fine: Bool = false, snap: Double? = nil) -> Double {
        let span = range.upperBound - range.lowerBound
        var v = start + Double(translation / max(travel, 1)) * span * (fine ? 0.25 : 1)
        if let snap, snap > 0 { v = (v / snap).rounded() * snap }
        return v.clamped(to: range)
    }

    /// Where `value` sits along the track, 0…1.
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    /// The stretch of track between the rest mark and the knob, as fractions
    /// — nil when the two are within half a point of one another on a track
    /// `width` long, so a slider at rest draws no sliver of fill.
    static func fill(value: Double, rest: Double, range: ClosedRange<Double>,
                     width: CGFloat) -> ClosedRange<CGFloat>? {
        let a = fraction(value, in: range), b = fraction(rest, in: range)
        guard abs(a - b) * max(width, 1) > 0.5 else { return nil }
        return min(a, b)...max(a, b)
    }

    /// The step one VoiceOver swipe takes: the ⇧ snap, or a hundredth of the
    /// range for a slider that has none.
    static func accessibilityStep(snap: Double, range: ClosedRange<Double>) -> Double {
        snap > 0 ? snap : (range.upperBound - range.lowerBound) / 100
    }
}

/// The numbers a slider is drawn with. A default-constructed one is the
/// editor's rails, which is what every caller but the export page wants; the
/// export page's drawing has a narrower label column, a thinner track and a
/// shorter row. The knob is not here because both drawings agree on it.
private struct RailSliderMetricsKey: EnvironmentKey { static let defaultValue = SliderMetrics() }

extension EnvironmentValues {
    /// The slider grid of the rail a slider sits on. The Parameters rail sets
    /// `.parameters`; everything else keeps the default.
    var railSliderMetrics: SliderMetrics {
        get { self[RailSliderMetricsKey.self] }
        set { self[RailSliderMetricsKey.self] = newValue }
    }
}

struct SliderMetrics {
    /// The rails' default: an 84 pt label column at 10.5 pt.
    static let rail = SliderMetrics()
    /// **Camera's own.** v3 sets its labels at 9 pt in a 70 pt column — the
    /// section's rows are the densest in the interface and the drawing gives
    /// them less room than Film's, not the same room in a smaller face.
    static let camera = SliderMetrics(labelWidth: Theme.Metric.cameraLabelWidth,
                                      labelFont: Theme.Font.cameraLabel)
    /// **The Parameters rail's one grid** (v4). Every slider on the right rail
    /// — Camera's, Film Format's strengths, Scene Placement, the Tone Mask and
    /// the Post-Dev grade — shares this label column, so their tracks start
    /// on one line and their values end on another. v4's drawing had two
    /// (Camera at 9 pt in 70, Film Format at 10.5 pt pushed out by "Halation
    /// Strength"), which is what made the strength rows look off-grid.
    @MainActor static var parameters: SliderMetrics { SliderMetrics(labelWidth: Theme.Metric.parameterLabelWidth) }

    var labelWidth: CGFloat = Theme.Metric.sliderLabelWidth
    var valueWidth: CGFloat = Theme.Metric.sliderValueWidth
    var rowHeight: CGFloat = Theme.Metric.rowHeight
    var trackHeight: CGFloat = Theme.Metric.trackHeight
    var labelFont: Font = Theme.Font.label
    var valueFont: Font = Theme.Font.value
    /// Whether the value is drawn **in a pill** (the 2026-09-17 drawing: a
    /// `.st13` rounded rectangle at `rx 8.5`, every slider) or as bare text
    /// (the export page's drawing, which has one slider and no pill).
    var valueInPill: Bool = true
}

struct ScrubSlider: View {
    let label: String
    var sublabel: String? = nil
    /// A second label line that is a *view* rather than text — the white
    /// balance rows put their "As Shot" checkbox there. Alternative to
    /// `sublabel`, and it wins when both are set.
    var sublabelView: AnyView? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var zero: Double = 0
    var snap: Double = 0.5
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var parse: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
    var trackGradient: [Color]? = nil
    /// The part of the range the value can rest on, when that is not all of
    /// it (Scene Placement's pull-backs the Fit takes). Drawn as a band around
    /// the track, so where the knob can go is visible before anyone drags:
    /// the band is the usable part, bare track is not. 1.3.1 drew the band
    /// on the refused part, and it read the other way round.
    var usable: [ClosedRange<Double>] = []
    var disabled = false
    /// See `SliderMetrics`. Nil takes the rail's (`\.railSliderMetrics`), which
    /// is how every slider on the Parameters rail lands on one grid without
    /// each call site having to say so.
    var metrics: SliderMetrics? = nil
    var onCommit: () -> Void = {}
    @Environment(\.railSliderMetrics) private var railMetrics
    private var m: SliderMetrics { metrics ?? railMetrics }

    @State private var dragStart: Double?
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var hasSecondLine: Bool { sublabelView != nil || sublabel != nil }
    /// The value says what the rest says (see `Theme.Ink.value(atRest:)`).
    private var atRest: Bool { format(value) == format(zero.clamped(to: range)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(label)
                    .font(m.labelFont)
                    .foregroundStyle(Theme.Ink.secondary)
                    // A column, not a cage (2026-09-28): the label is at least
                    // the column wide and grows past it rather than truncate.
                    .fixedSize()
                    .padding(.trailing, 6)
                    .frame(minWidth: m.labelWidth, alignment: .leading)
                    // The track carries the label for VoiceOver, with the
                    // value and the adjustment; read twice it is noise.
                    .accessibilityHidden(true)
                track
                    .padding(.trailing, Theme.Metric.sliderValueGap)
                valueField
                    .frame(width: m.valueWidth)
            }
            .frame(height: m.rowHeight)
            // The second line is the drawing's own: "As Shot" and its box sit
            // **under the label**, not beside the value, so they line up with
            // the label column rather than floating in the middle of the row.
            if let sublabelView {
                sublabelView.frame(height: Theme.Metric.subRowHeight, alignment: .leading)
            } else if let sublabel {
                // Wraps, never widens the row (1.2.2). This line carries
                // messages as well as units — Scene Placement's refusal is a
                // sentence — and a `.fixedSize()` sentence made the whole
                // Parameters rail wider than the window, pushing every value
                // off its right edge (reported from Xiaohongshu, 2026-09-30).
                Text(sublabel).font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.subRowHeight, alignment: .leading)
            }
        }
        .rowEnabled(!disabled)
    }

    private var fraction: CGFloat { ScrubDrag.fraction(value, in: range) }
    private var zeroFraction: CGFloat { ScrubDrag.fraction(zero, in: range) }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobW = Theme.Metric.knobSize.width
            let travel = w - knobW
            let x = fraction * travel + knobW / 2
            ZStack(alignment: .leading) {
                Group {
                    if let g = trackGradient {
                        Capsule().fill(LinearGradient(colors: g, startPoint: .leading, endPoint: .trailing))
                    } else {
                        // `surface.control` — the same grey every pill and
                        // field is, so the track carries no colour the rail
                        // does not already use.
                        //
                        // **1.36 pt, v3's measurement**, where the
                        // 2026-09-17 pass drew 3. The objection then was
                        // that a hairline-thin track "in the *same grey as
                        // the ground*" was fainter than the dividers beside
                        // it — and it was, because `well` was `ground` and
                        // the track sat on a well of its own colour. v3
                        // separates rail from control, so the thin track now
                        // has contrast of its own. What it does *not* have
                        // is a hit target, and it does not need one: the
                        // drag is on the full row-height `contentShape`
                        // below, not on the ink.
                        Capsule().fill(Theme.ground)
                    }
                }
                .frame(height: m.trackHeight)
                .padding(.horizontal, knobW / 2)
                ForEach(Array(usable.enumerated()), id: \.offset) { _, usable in
                    let span = range.upperBound - range.lowerBound
                    let lo = CGFloat((max(usable.lowerBound, range.lowerBound) - range.lowerBound) / span)
                    let hi = CGFloat((min(usable.upperBound, range.upperBound) - range.lowerBound) / span)
                    Capsule().fill(Theme.Ink.tertiary.opacity(0.35))
                        .frame(width: max((hi - lo) * (w - knobW), 3), height: 5)
                        .offset(x: lo * (w - knobW) + knobW / 2)
                        .allowsHitTesting(false)
                }
                // **The fill (V5):** rest to knob, in the rail's secondary
                // ink, the track's own height. Not on a gradient track — the
                // colour under the knob is already the reading there.
                if trackGradient == nil,
                   let fill = ScrubDrag.fill(value: value, rest: zero, range: range, width: travel) {
                    Capsule().fill(Theme.sliderFill)
                        .frame(width: (fill.upperBound - fill.lowerBound) * travel, height: m.trackHeight)
                        .offset(x: fill.lowerBound * travel + knobW / 2)
                        .allowsHitTesting(false)
                }
                // **The rest mark (V5):** always drawn, ends included — the
                // knob covers it when it sits there. It used to be drawn only
                // away from the ends and away from the knob, so a slider at
                // rest showed no rest at all.
                Rectangle().fill(Theme.restMark).frame(width: 1, height: 7)
                    .offset(x: zeroFraction * travel + knobW / 2 - 0.5)
                    .allowsHitTesting(false)
                // v3's knob is a 6.13 × 5.07 dot rather than a 10 pt
                // handle. Ink only — it is never dragged by itself; the
                // gesture belongs to the track. It grows while held, the
                // contact acknowledgement (not under Reduce Motion).
                RoundedRectangle(cornerRadius: Theme.Metric.knobRadius, style: .continuous)
                    .fill(Theme.knob)
                    .frame(width: knobW, height: Theme.Metric.knobSize.height)
                    .scaleEffect(dragStart != nil ? Theme.Motion.contactScale : 1)
                    .offset(x: x - knobW / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let mods = NSEvent.modifierFlags
                        // **Relative** (V5): the drag starts from the value,
                        // not from the point pressed, so contact moves nothing.
                        if dragStart == nil { dragStart = value }
                        value = ScrubDrag.value(from: dragStart ?? value, translation: g.translation.width,
                                                travel: travel, range: range,
                                                fine: mods.contains(.option),
                                                snap: mods.contains(.shift) ? snap : nil)
                    }
                    .onEnded { _ in dragStart = nil; onCommit() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        }
        .frame(height: m.rowHeight)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            guard !disabled else { return }
            let step = ScrubDrag.accessibilityStep(snap: snap, range: range)
            switch direction {
            case .increment: value = (value + step).clamped(to: range)
            case .decrement: value = (value - step).clamped(to: range)
            @unknown default: return
            }
            onCommit()
        }
        .accessibilityAction(named: Text(L(.helpReset))) { if !disabled { reset() } }
    }

    /// Back to the rest value — silent when it is already there, so a
    /// double-click on a slider at rest asks for no render.
    private func reset() {
        let rest = zero.clamped(to: range)
        guard value != rest else { return }
        value = rest
        onCommit()
    }

    private var valueField: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(m.valueFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { commitText() }
                    .onChange(of: focused) { _, f in if !f { commitText() } }
            } else {
                // V5 dims a value at rest. **Not inside a pill**: there the
                // value sits on `pill` (#5F5F5F), and `tertiary` on that is
                // the look of a greyed field (`rowEnabled(false)`) — a rail of
                // values at rest read as a rail of disabled controls
                // (measured on the 2026-10-18 capture). The fill and the rest
                // mark carry "moved" there; a bare value follows V5.
                Text(format(value))
                    .font(m.valueFont)
                    .foregroundStyle(m.valueInPill ? Theme.text : Theme.Ink.value(atRest: atRest))
                    .contentShape(Rectangle())
                    .onTapGesture { text = format(value); editing = true; focused = true }
                    // The track reads the value already; this is the field
                    // that takes a typed number, and says so.
                    .accessibilityLabel(L("Type a value", zh: "输入数值"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .frame(height: m.valueInPill ? Theme.Metric.controlHeight : nil)
        .background {
            if m.valueInPill {
                RoundedRectangle(cornerRadius: Theme.Metric.fieldRadius, style: .continuous)
                    .fill(Theme.pill)
            }
        }
    }

    private func commitText() {
        if let v = parse(text) { value = v.clamped(to: range); onCommit() }
        editing = false
    }
}

/// The checkbox: a small square with a 1 pt border, filled with the accent
/// when it is on.
///
/// The reference drawing's 5 pt square inside a 16 pt target was not readable
/// or reliably clickable on a laptop. Both values now come from product
/// accessibility tokens: 10 pt of visible state inside a 28 pt target.
struct CheckBox: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                // Off, this is an empty box; drawn in `text` it was a bright
                // white square and the loudest mark in its row, which put
                // more emphasis on an unchecked option than on the label
                // naming it. The accent still carries "on" — the empty state
                // is metadata and is inked like it.
                RoundedRectangle(cornerRadius: 1)
                    .stroke(isOn ? Theme.accent : Theme.Ink.tertiary, lineWidth: 1)
                if isOn { RoundedRectangle(cornerRadius: 0.5).fill(Theme.accent).padding(1.6) }
            }
            .frame(width: Theme.Metric.checkbox, height: Theme.Metric.checkbox)
            .frame(width: Theme.Metric.controlHitTarget, height: Theme.Metric.controlHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? L("On", zh: "开") : L("Off", zh: "关"))
    }
}

/// Label at the left, checkbox at the right — Grain, Halation, Glare and Lens
/// Correction.
///
/// `enabled` is the PRD's "if one option is non-selectable, both the text and
/// the input pill is greyed across the app", and it is one modifier on the
/// row rather than a colour each half has to remember (`View.rowEnabled(_:)`).
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    /// Which of the two v3 densities this row is in: Film's 10.5 (the
    /// default, and the EDR row's) or Camera's 9.
    var labelFont: Font = Theme.Font.label
    var enabled = true
    var reason: String = ""
    /// One line under the label, in the metadata ink, for a switch whose
    /// **scope** is not guessable from where it sits.
    ///
    /// A checkbox on a panel implies "this changes what the panel is about",
    /// and most of them do. The ones that do not — a switch that changes the
    /// render everywhere rather than only the thing above it — read as
    /// view settings and get used as if they were. Saying so costs a 9.5 pt
    /// line and is the difference between a control and a guess.
    var sublabel: String = ""
    /// What it does, for the hover. Distinct from `reason`, which is why it
    /// cannot be used right now.
    var help: String = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(labelFont).foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !sublabel.isEmpty {
                    Text(sublabel).font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            // The box's target is wider than its ink, so it is pulled back
            // to put the *square* on the row's trailing inset rather than
            // the padding around it.
            CheckBox(isOn: $isOn)
                .padding(.trailing, -(Theme.Metric.controlHitTarget - Theme.Metric.checkbox) / 2)
        }
        // A row with a sublabel is two lines and sizes itself; one without is
        // the drawing's fixed row, unchanged.
        .frame(height: sublabel.isEmpty ? Theme.Metric.toggleRowHeight : nil)
        .frame(minHeight: sublabel.isEmpty ? nil : Theme.Metric.toggleRowHeight)
        // One VoiceOver element for the row: the label is the box's name.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? L("On", zh: "开") : L("Off", zh: "关"))
        .accessibilityHint(sublabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { isOn.toggle() } }
        .rowEnabled(enabled, because: reason)
        .help(help)
    }
}
