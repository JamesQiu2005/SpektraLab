//  ScrubSlider.swift — the one slider. Label | track with a pill knob | value.
//
//  Built once and used everywhere. Drag anywhere on the track, ⌥ for ×0.25
//  sensitivity, ⇧ snaps to `snap`, double-click resets to `zero`, and the
//  value column is an editable field. `onCommit` fires on release; continuous
//  updates go through the binding while dragging.

import SwiftUI

/// The numbers a slider is drawn with. A default-constructed one is the
/// editor's rails, which is what every caller but the export page wants; the
/// export page's drawing has a narrower label column, a thinner track and a
/// shorter row. The knob is not here because both drawings agree on it.
struct SliderMetrics {
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
    var disabled = false
    /// See `SliderMetrics` — the editor's panels unless a page says otherwise.
    var metrics = SliderMetrics()
    var onCommit: () -> Void = {}

    @State private var dragStart: Double?
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var hasSecondLine: Bool { sublabelView != nil || sublabel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(label)
                    .font(metrics.labelFont)
                    .foregroundStyle(Theme.Ink.secondary)
                    .frame(width: metrics.labelWidth, alignment: .leading)
                    .lineLimit(1)
                track
                    .padding(.trailing, Theme.Metric.sliderValueGap)
                valueField
                    .frame(width: metrics.valueWidth)
            }
            .frame(height: metrics.rowHeight)
            // The second line is the drawing's own: "As Shot" and its box sit
            // **under the label**, not beside the value, so they line up with
            // the label column rather than floating in the middle of the row.
            if let sublabelView {
                sublabelView.frame(height: Theme.Metric.subRowHeight, alignment: .leading)
            } else if let sublabel {
                Text(sublabel).font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1)
                    .frame(height: Theme.Metric.subRowHeight, alignment: .leading)
            }
        }
        .rowEnabled(!disabled)
    }

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }
    private var zeroFraction: CGFloat {
        CGFloat((zero - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobW = Theme.Metric.knobSize.width
            let x = fraction * (w - knobW) + knobW / 2
            ZStack(alignment: .leading) {
                Group {
                    if let g = trackGradient {
                        Capsule().fill(LinearGradient(colors: g, startPoint: .leading, endPoint: .trailing))
                    } else {
                        // `.st13`, the ground — not a dim grey of its own, so
                        // the track carries no colour the rail does not
                        // already use. What separates it from a divider is
                        // that a divider is 1 pt and `rule`-coloured while
                        // this is 3 pt and darker; at the 1.5 pt it used to
                        // be, it was *thinner* than the hairlines around it.
                        Capsule().fill(Theme.ground)
                    }
                }
                .frame(height: metrics.trackHeight)
                .padding(.horizontal, knobW / 2)
                // Zero tick, only when zero is not at an end.
                if zeroFraction > 0.001 && zeroFraction < 0.999 && abs(fraction - zeroFraction) > 0.02 {
                    Rectangle().fill(Theme.text.opacity(0.55)).frame(width: 1, height: 6)
                        .offset(x: zeroFraction * (w - knobW) + knobW / 2 - 0.5)
                }
                RoundedRectangle(cornerRadius: Theme.Metric.knobRadius, style: .continuous)
                    .fill(Theme.knob)
                    .frame(width: knobW, height: Theme.Metric.knobSize.height)
                    .offset(x: x - knobW / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let mods = NSEvent.modifierFlags
                        let span = range.upperBound - range.lowerBound
                        if dragStart == nil {
                            dragStart = value
                            // Jump to the click point on a fresh press.
                            let f = ((g.startLocation.x - knobW / 2) / max(w - knobW, 1)).clamped(to: 0...1)
                            let target = range.lowerBound + Double(f) * span
                            if abs(target - value) > span * 0.03 { dragStart = target }
                        }
                        let sens: Double = mods.contains(.option) ? 0.25 : 1
                        var v = (dragStart ?? value) + Double(g.translation.width / max(w - knobW, 1)) * span * sens
                        if mods.contains(.shift) { v = (v / snap).rounded() * snap }
                        value = v.clamped(to: range)
                    }
                    .onEnded { _ in dragStart = nil; onCommit() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = zero; onCommit() })
        }
        .frame(height: metrics.rowHeight)
    }

    private var valueField: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(metrics.valueFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { commitText() }
                    .onChange(of: focused) { _, f in if !f { commitText() } }
            } else {
                Text(format(value))
                    .font(metrics.valueFont)
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                    .onTapGesture { text = format(value); editing = true; focused = true }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .frame(height: metrics.valueInPill ? Theme.Metric.controlHeight : nil)
        .background {
            if metrics.valueInPill {
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

/// The checkbox, as the 2026-09-17 drawing draws it: a small square with a
/// 1 pt `#faf8f4` border, filled with the accent when it is on.
///
/// The drawing's is 5 pt across, which is below what the eye resolves as a
/// shape on a dark rail; `Theme.Metric.checkbox` is 8, and the hit area is
/// padded well past it either way — a 5 pt target is not a target.
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
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Text(label).font(Theme.Font.label).foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !sublabel.isEmpty {
                    Text(sublabel).font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            CheckBox(isOn: $isOn).padding(.trailing, -6)
        }
        // A row with a sublabel is two lines and sizes itself; one without is
        // the drawing's fixed row, unchanged.
        .frame(height: sublabel.isEmpty ? Theme.Metric.toggleRowHeight : nil)
        .frame(minHeight: sublabel.isEmpty ? nil : Theme.Metric.toggleRowHeight)
        .rowEnabled(enabled, because: reason)
        .help(help)
    }
}
