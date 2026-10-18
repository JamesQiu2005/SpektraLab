//  EditControls.swift — what the Post-Dev sections (Light, Curve, Colour)
//  share: the slider row, the arrow keys, the names, and the door onto the
//  grade.
//
//  **Why a row of its own rather than `ScrubSlider`.** The rail's slider jumps
//  to the click on a fresh press (more than 3 % of the range away), so a click
//  meant to take hold of a value moves it, and a click on the far end of the
//  track moves it the whole way. The Post-Dev rows are **relative**: a press
//  anywhere on the label or the track takes hold of the value where it is,
//  and only the drag's travel moves it. The rest is what the rail's slider
//  already does and is kept the same way: ⌥ for a quarter of the travel, ⇧ to
//  the control's snap, a double-click back to rest, the value an editable
//  field. Kept local so the shared slider is not changed underneath every
//  other rail; it is a candidate for the shared control when that is
//  redrawn.
//
//  **The keyboard.** A row takes focus when it is pressed, and while it has
//  it the arrows step it: one `step`, a tenth with ⌥, ten with ⇧. The Frame
//  menu owns ←/→ and AppKit asks the menu first (AGENTS trap 32), so a row
//  with focus registers in `Layer2KeyFocus` and `TypingKeyGuard` hands it the
//  arrows before the menu sees them.
//
//  **The history.** A drag is one step (`Session.beginLayer2Gesture` …
//  `endLayer2Gesture`); a run of arrow presses is one step, closed half a
//  second after the last; a double-click and a typed value are a step each.

import AppKit
import SwiftUI

// MARK: - the arrows

/// A run of arrow presses as one gesture: it begins with the first press and
/// ends half a second after the last, or when focus goes.
@MainActor
final class KeyRun {
    private var closing: Task<Void, Never>?
    /// The end of the run that is open, called when it closes.
    private var ending: (() -> Void)?

    var open: Bool { ending != nil }

    func press(begin: () -> Void, end: @escaping () -> Void) {
        if ending == nil { begin() }
        ending = end
        closing?.cancel()
        closing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// Close the open run now (focus went, the view went).
    func finish(_ end: () -> Void) {
        guard ending != nil else { return }
        close()
    }

    private func close() {
        closing?.cancel(); closing = nil
        let end = ending
        ending = nil
        end?()
    }
}

// MARK: - the door onto the grade

extension Session {
    /// A Post-Dev control's value in the grade the rail is editing — the
    /// picked frame's on a half-frame pair, else the frame's own
    /// (`layerAdjustments`). Every Post-Dev section writes through this, so
    /// all three edit the same grade; 1.3's Curve and Color Balance wrote the
    /// film's grade while White Balance and Exposure wrote the picked frame's.
    func grade(_ get: @escaping (Adjustments) -> Double,
               _ set: @escaping (inout Adjustments, Double) -> Void) -> Binding<Double> {
        Binding(get: { get(self.layerAdjustments) },
                set: { v in var a = self.layerAdjustments; set(&a, v); self.layerAdjustments = a })
    }

    /// One control of the table, held to its range.
    func grade(_ control: Layer2Control) -> Binding<Double> {
        grade({ $0[control] }, { $0[control] = $1 })
    }

    /// Change the grade the rail is editing, as one write.
    func changeGrade(_ change: (inout Adjustments) -> Void) {
        var a = layerAdjustments
        change(&a)
        layerAdjustments = a
    }
}

// MARK: - names

//  The model's enums carry English names and stay free of the main actor
//  (`Strings.swift`, "enums whose own `title` is a display string"); the rail
//  asks for the localized one here.

extension Layer2Control {
    @MainActor var label: String {
        switch self {
        case .exposure: L("Exposure", zh: "曝光")
        case .contrast: L(.exposureContrast)
        case .brightness: L(.exposureBrightness)
        case .highlights: L(.exposureHighlights)
        case .shadows: L(.exposureShadows)
        case .whites: L("Whites", zh: "白色色阶")
        case .blacks: L("Blacks", zh: "黑色色阶")
        case .vignette: L("Vignette", zh: "暗角")
        case .vignetteMidpoint: L("Midpoint", zh: "中点")
        // The print's white balance, which is not Camera's (`design/
        // LOCALIZATION-zh-Hans.md`: two stages must not share a name).
        case .temperature: L("Temperature", zh: "色温偏移")
        case .tint: L("Tint", zh: "色调偏移")
        case .saturation: L(.exposureSaturation)
        }
    }
}

extension ParametricCurve.Region {
    @MainActor var label: String {
        switch self {
        case .highlights: L(.exposureHighlights)
        case .lights: L("Lights", zh: "亮调")
        case .darks: L("Darks", zh: "暗调")
        case .shadows: L(.exposureShadows)
        }
    }
}

extension ColorBalance.Zone {
    @MainActor var label: String {
        switch self {
        case .master: L("Master", zh: "整体")
        case .shadows: L(.exposureShadows)
        case .midtones: L("Midtones", zh: "中间调")
        case .highlights: L(.exposureHighlights)
        }
    }
}

extension CurveChannel {
    @MainActor var label: String { key.map { L($0) } ?? title }
}

/// Strings the three sections share.
enum EditText {
    @MainActor static var reset: String { L("Reset", zh: "还原") }
}

// MARK: - the slider row

/// Label | track | value, relative, keyboard-steppable. See the note at the
/// top of the file for why it is not `ScrubSlider`.
struct EditSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var rest: Double = 0
    /// Whether the track marks where the value rests (not for a midpoint).
    var centred = true
    var step: Double = 1
    var snap: Double = 1
    var format: (Double) -> String = { Layer2Control.signed($0, decimals: 0) }
    var trackGradient: [Color]? = nil
    /// The gesture's two ends, for the history.
    var begin: () -> Void = {}
    var end: () -> Void = {}

    @Environment(\.railSliderMetrics) private var m
    @State private var anchor: Double?
    @State private var travelled: CGFloat = 0
    @State private var trackWidth: CGFloat = 1
    @State private var editing = false
    @State private var text = ""
    @State private var id = UUID()
    @State private var run = KeyRun()
    @FocusState private var fieldFocused: Bool
    @FocusState private var focused: Bool

    private var span: Double { range.upperBound - range.lowerBound }

    var body: some View {
        HStack(spacing: 0) {
            grip
                .padding(.trailing, Theme.Metric.sliderValueGap)
            valueField
                .frame(width: m.valueWidth)
        }
        .frame(height: m.rowHeight)
    }

    /// The label and the track: the part of the row a press takes hold of.
    private var grip: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(m.labelFont)
                .foregroundStyle(focused ? Theme.accent : Theme.Ink.secondary)
                .fixedSize()
                .padding(.trailing, 6)
                .frame(minWidth: m.labelWidth, alignment: .leading)
            track
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in
            if now {
                Layer2KeyFocus.shared.claim(id) { arrow, mods in press(arrow, mods) }
            } else {
                Layer2KeyFocus.shared.release(id)
                run.finish(end)
            }
        }
        .onDisappear {
            Layer2KeyFocus.shared.release(id)
            run.finish(end)
            if anchor != nil { anchor = nil; end() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if anchor == nil {
                        anchor = value; travelled = 0
                        focused = true
                        begin()
                    }
                    let mods = NSEvent.modifierFlags
                    // Accumulated a move at a time, so ⌥ pressed or let go
                    // mid-drag changes the rate from there on rather than
                    // re-reading the whole travel at the new rate (a jump).
                    let dx = g.translation.width - travelled
                    travelled = g.translation.width
                    let rate = mods.contains(.option) ? 0.25 : 1
                    anchor = (anchor ?? value) + Double(dx / max(trackWidth, 1)) * span * rate
                    var v = anchor ?? value
                    if mods.contains(.shift), snap > 0 { v = (v / snap).rounded() * snap }
                    value = v.clamped(to: range)
                }
                .onEnded { _ in
                    anchor = nil
                    end()
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = rest })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = (value + step).clamped(to: range)
            case .decrement: value = (value - step).clamped(to: range)
            @unknown default: break
            }
        }
        .accessibilityAction(named: EditText.reset) { value = rest }
    }

    private func press(_ arrow: Layer2KeyFocus.Arrow, _ mods: NSEvent.ModifierFlags) {
        run.press(begin: begin, end: end)
        value = (value + arrow.sign * Layer2KeyFocus.stride(step, mods)).clamped(to: range)
    }

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / span).clamped(to: 0...1)
    }
    private var restFraction: CGFloat {
        CGFloat((rest - range.lowerBound) / span).clamped(to: 0...1)
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobW = Theme.Metric.knobSize.width
            let usable = max(w - knobW, 1)
            ZStack(alignment: .leading) {
                Group {
                    if let g = trackGradient {
                        Capsule().fill(LinearGradient(colors: g, startPoint: .leading, endPoint: .trailing))
                    } else {
                        Capsule().fill(Theme.ground)
                    }
                }
                .frame(height: m.trackHeight)
                .padding(.horizontal, knobW / 2)
                if centred, restFraction > 0.001, restFraction < 0.999, abs(fraction - restFraction) > 0.02 {
                    Rectangle().fill(Theme.text.opacity(0.55)).frame(width: 1, height: 6)
                        .offset(x: restFraction * usable + knobW / 2 - 0.5)
                }
                RoundedRectangle(cornerRadius: Theme.Metric.knobRadius, style: .continuous)
                    .fill(focused ? Theme.accent : Theme.knob)
                    .frame(width: knobW, height: Theme.Metric.knobSize.height)
                    .offset(x: fraction * usable)
            }
            .frame(height: geo.size.height)
            .onAppear { trackWidth = usable }
            .onChange(of: usable) { _, now in trackWidth = now }
        }
        .frame(height: m.rowHeight)
    }

    private var valueField: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(m.valueFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .focused($fieldFocused)
                    .onSubmit { commitText() }
                    .onChange(of: fieldFocused) { _, f in if !f { commitText() } }
                    .onExitCommand { editing = false }
            } else {
                Text(format(value))
                    .font(m.valueFont)
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                    .onTapGesture { text = format(value); editing = true; fieldFocused = true }
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))
                    .accessibilityHint(L("Click to type a value.", zh: "点按以输入数值。"))
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
        guard editing else { return }
        editing = false
        if let v = Layer2Control.parse(text) { value = v.clamped(to: range) }
    }
}

extension EditSliderRow {
    /// A row of the control table, onto the grade the rail is editing.
    @MainActor
    init(_ control: Layer2Control, session: Session, trackGradient: [Color]? = nil) {
        self.init(title: control.label, value: session.grade(control), range: control.range,
                  rest: control.rest, centred: control.isCentred, step: control.step, snap: control.snap,
                  format: { control.text($0) }, trackGradient: trackGradient,
                  begin: { session.beginLayer2Gesture() }, end: { session.endLayer2Gesture() })
    }
}
