//  ValueSlider.swift — the one slider: a fixed track, a knob at the value, and
//  a number you can type.
//
//  The owner's reference (2026-10-26, Capture One's 曝光 group) is a row: the
//  name at the left, a track that never moves, the knob where the value is, and
//  the number in a box at the right that takes typing. The complaint that
//  brought it here, from a friend using the app: "它是拖动底下的条，那个值永远在
//  正中间 … 想判断一下大概改了什么，还要看旁边的数字". `TickRuler` slid its scale
//  under a fixed mark, so a panel could not be read at a glance.
//
//  The track maps the whole range across its width. `rest` is the value the
//  knob is held at when a drag lands within 1.2 % of it (zero, one stop,
//  1.00×), and is marked with a hairline. Dragging is relative, so a finger
//  landing anywhere in the row does not jump the value; a click on the Mac puts
//  the knob where it was clicked and commits it as a release does.
//
//  The number is a text field in both states: it shows the formatted value, and
//  a person can select it and type another (a unit after the number is ignored,
//  as `SliderField.number` explains).

import SwiftUI

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// The value a drag is held at nearby, and the hairline's value.
    var rest: Double = 0
    /// The step a drag lands on; nil is continuous (typed values are never snapped).
    var step: Double? = nil
    var text: (Double) -> String = { Fmt.signed($0, decimals: 0) }
    /// A quiet word under the label ("stops", "As Shot", the film's name).
    var sub: String? = nil
    /// The track drawn in a colour per position (temperature, tint): 0 at its
    /// leading end, 1 at its trailing one.
    var tint: ((Double) -> Color)? = nil
    /// Or in a gradient of these, left to right (saturation, the HSL bands).
    var track: [Color]? = nil
    var detentAtRest = false
    /// False where `rest` means nothing on this scale (a 0…0.03 pre-flash).
    var showsRest = true
    var labelWidth: CGFloat = 92
    var fieldWidth: CGFloat = 78
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(title)
                    .font(Theme.Font.ui(13.5, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let sub {
                    Text(sub)
                        .font(Theme.Font.ui(10.5))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: labelWidth, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { commit(rest) }
            .accessibilityHidden(true)

            SliderTrack(value: $value, range: range, rest: rest, step: step,
                        tint: tint, colours: track, detentAtRest: detentAtRest,
                        showsRest: showsRest, onEditingChanged: onEditingChanged)
                .frame(height: 28)

            SliderField(shown: text(value), width: fieldWidth,
                        parse: SliderField.number(from:), commit: commit)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func commit(_ v: Double) {
        let landed = v.clamped(to: range)
        onEditingChanged(true)
        value = landed
        onEditingChanged(false)
    }
}

/// The track alone: a click or a drag, no label and no number. For a panel that
/// draws its own row around it (`FilmPanel`'s exposure).
struct SliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var rest: Double = 0
    var step: Double? = nil
    var tint: ((Double) -> Color)? = nil
    var colours: [Color]? = nil
    var detentAtRest = false
    var showsRest = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var origin: Double?
    @State private var ownership = DragOwnership()
    @State private var width: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var calm

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }

    private var fill: AnyShapeStyle {
        if let colours {
            return AnyShapeStyle(LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing))
        }
        if let tint {
            let stops = stride(from: 0.0, through: 1.0, by: 0.1).map {
                Gradient.Stop(color: tint($0), location: $0)
            }
            return AnyShapeStyle(LinearGradient(gradient: Gradient(stops: stops),
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(Theme.rule)
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let knobX = CGFloat((value.clamped(to: range) - range.lowerBound) / span) * w
            let restX = CGFloat((rest.clamped(to: range) - range.lowerBound) / span) * w
            ZStack(alignment: .leading) {
                // The bar: the same grey as Capture One's, or the control's own colours.
                Rectangle().fill(fill).frame(height: 3)
                if showsRest, range.contains(rest) {
                    Rectangle().fill(Theme.secondaryText.opacity(0.55))
                        .frame(width: 1, height: 11)
                        .offset(x: restX)
                        .allowsHitTesting(false)
                }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.selection)
                    .frame(width: 9, height: 19)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .scaleEffect(origin != nil && !calm ? 1.12 : 1)
                    .offset(x: knobX - 4.5)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            // Mac: a click puts the knob there (one edit, committed as a release is).
            .onTapGesture(coordinateSpace: .local) { at in
                let v = (range.lowerBound + Double(at.x / w) * span).clamped(to: range)
                onEditingChanged(true)
                value = snapped(v)
                onEditingChanged(false)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        }
        .frame(height: 28)
        .dragBesideScroll(onChanged: { g in
            guard ownership.update(x: g.translation.width, y: g.translation.height) else { return }
            if origin == nil {
                origin = value
                onEditingChanged(true)
            }
            // A fixed track: the knob follows the finger, so right is up.
            let travel = max(width, 1)
            let next = (origin ?? value) + Double(g.translation.width / travel) * span
            value = snapped(next.clamped(to: range))
        }, onEnded: {
            if origin != nil { onEditingChanged(false) }
            origin = nil; ownership = DragOwnership()
        })
        .onDisappear {
            if origin != nil { onEditingChanged(false) }
            origin = nil; ownership = DragOwnership()
        }
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let s = step ?? span / 100
            let next = value + (direction == .increment ? s : -s)
            commit(next)
        }
    }

    private func commit(_ v: Double) {
        onEditingChanged(true)
        value = v.clamped(to: range)
        onEditingChanged(false)
    }

    private func snapped(_ v: Double) -> Double {
        if detentAtRest, range.contains(rest), abs(v - rest) <= span * 0.012 { return rest }
        guard let step, step > 0 else { return v }
        return ((v / step).rounded() * step).clamped(to: range)
    }
}

/// The value's box: the number as it is written, and a place to type another.
/// A unit after the number (" K", " EV", "×", "%", "°") is kept for reading and
/// ignored when parsing, and a true minus (−) is accepted as a sign.
struct SliderField: View {
    let shown: String
    var width: CGFloat = 78
    let parse: (String) -> Double?
    let commit: (Double) -> Void
    @State private var draft: String = ""
    /// The text the value last showed, so Return followed by the focus leaving
    /// commits once and not the stale string twice.
    @State private var settled: String = ""
    @FocusState private var focused: Bool
    @State private var commitOwner = UUID()

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.Font.ui(12.5, .semibold))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 7)
            .frame(width: width, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
            .focused($focused)
            .onAppear { draft = shown; settled = shown }
            .onChange(of: shown) { _, s in
                guard !focused else { return }
                draft = s
                settled = s
            }
            .onChange(of: focused) { _, f in
                if f { draft = shown; settled = shown } else { apply() }
                if f {
                    MacKeyFocus.commitEditing = .init(owner: commitOwner, finish: { apply(); focused = false })
                } else if MacKeyFocus.commitEditing?.owner == commitOwner { MacKeyFocus.commitEditing = nil }
            }
            .onDisappear {
                if MacKeyFocus.commitEditing?.owner == commitOwner { MacKeyFocus.commitEditing = nil }
            }
            .onSubmit { apply(); focused = false }
            .accessibilityLabel(shown)
    }

    private func apply() {
        guard draft != settled else { return }
        if let v = parse(draft) {
            commit(v)
            settled = draft
        } else {
            draft = shown
            settled = shown
        }
    }

    /// "−1.25", "+2 EV", "5444 K", "1.00×", "100%": the first number in it.
    static func number(from s: String) -> Double? {
        let t = s.replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: "")
        let keep = t.filter { "0123456789+-.".contains($0) }
        guard keep.contains(where: \.isNumber) else { return nil }
        return Double(keep)
    }
}
