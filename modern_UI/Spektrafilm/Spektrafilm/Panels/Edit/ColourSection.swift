//  ColourSection.swift — Post-Dev's Colour: the print's balance and its
//  colour by tone.
//
//  Temperature, Tint and Saturation from the control table, then three
//  wheels — Shadows, Midtones, Highlights — and under them the **selected**
//  zone's Luminance, with its hue and saturation as rows behind a disclosure
//  for a value typed or stepped rather than aimed at.
//
//  A wheel is taken hold of where its point is: a press anywhere on it
//  selects the zone and moves nothing, and the point then follows the drag's
//  travel (`ColorBalanceLayout.Wheel.dragged`). 1.3's wheel jumped the point
//  to the pointer on contact, and read the angle against the gradient's
//  direction (see `ColorWheel.swift`).
//
//  The master zone is not drawn. A grade that has one — every 1.3 edit made
//  on the Master tab — keeps it, and while it is not neutral the section says
//  so in a line with a Reset of its own, rather than carrying a colour the
//  rail cannot show.

import AppKit
import SwiftUI

struct ColourSection: View {
    @Bindable var session: Session
    @Environment(\.colorBalanceWidth) private var colorBalanceWidth
    @State private var zone: ColorBalance.Zone = .shadows
    @State private var precise = false

    private var balance: ColorBalance { session.layerAdjustments.colorBalance }

    var body: some View {
        PanelSection(L("Colour", zh: "色彩"), key: "colour", menu: { AnyView(Button(EditText.reset) {
            session.changeGrade { $0.reset(.colour) } }) }, metrics: .right) {
            RailRows {
                EditSliderRow(.temperature, session: session,
                              trackGradient: [Color(hex: 0x005982), Color(hex: 0x8FA83C), Color(hex: 0xFFF100)])
                EditSliderRow(.tint, session: session,
                              trackGradient: [Color(hex: 0x00A93A), Color(hex: 0x8AA45E), Color(hex: 0xE4007F)])
                EditSliderRow(.saturation, session: session)
                Hairline().padding(.vertical, 2)
                wheels
                EditSliderRow(title: L("Luminance", zh: "明度"),
                              value: component(\.luminance, scale: 100), range: -100...100,
                              format: { Layer2Control.signed($0, decimals: 0) },
                              begin: session.beginLayer2Gesture, end: session.endLayer2Gesture)
                disclosure
                if precise {
                    EditSliderRow(title: L("Hue", zh: "色相"), value: component(\.hue), range: 0...360,
                                  centred: false, format: { String(format: "%.0f°", $0) },
                                  begin: session.beginLayer2Gesture, end: session.endLayer2Gesture)
                    EditSliderRow(title: L("Saturation", zh: "饱和度"), value: component(\.saturation, scale: 100),
                                  range: 0...100, centred: false, format: { String(format: "%.0f %%", $0) },
                                  begin: session.beginLayer2Gesture, end: session.endLayer2Gesture)
                }
                if !balance.master.isNeutral { master }
            }
        }
    }

    // MARK: the wheels

    private var wheels: some View {
        // The rows' inset is wider than the plot inset the window measures
        // the wheels against (`ColorBalanceLayout.interior`).
        let width = colorBalanceWidth - 2 * (Theme.Metric.rowInset - Theme.Metric.plotInset)
        let row = ColorBalanceLayout.row(width: width)
        return HStack(spacing: row.gap) {
            ForEach(ColorBalance.Zone.drawn) { z in
                VStack(spacing: 4) {
                    // At most the row's size, and smaller if the rail is: a
                    // wheel sized only from the window's width would hold the
                    // rail open past its narrowest (`PanelResizeWiringTests`).
                    GeometryReader { geo in
                        ZoneWheelControl(zone: z, selected: z == zone, size: min(geo.size.width, geo.size.height),
                                         session: session) { zone = z }
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: row.wheel)
                    Text(z.label)
                        .font(Theme.Font.sublabel)
                        .foregroundStyle(z == zone ? Theme.Ink.primary : Theme.Ink.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    /// A component of the selected zone, onto the grade. `scale` puts the
    /// model's 0…1 or −1…1 on the row's 0…100 or −100…100.
    private func component(_ path: WritableKeyPath<ColorZone, Double>, scale: Double = 1) -> Binding<Double> {
        let z = zone
        return session.grade({ $0.colorBalance[z][keyPath: path] * scale },
                             { $0.colorBalance[z][keyPath: path] = $1 / scale })
    }

    private var disclosure: some View {
        Button { precise.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: precise ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                Text(L("Hue and Saturation", zh: "色相与饱和度"))
                    .font(Theme.Font.sublabel)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Ink.tertiary)
            .frame(height: Theme.Metric.subRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Hue and Saturation", zh: "色相与饱和度"))
        .accessibilityValue(precise ? L("Shown", zh: "已显示") : L("Hidden", zh: "已隐藏"))
    }

    /// A master colour from an earlier edit: said, and resettable.
    private var master: some View {
        let m = balance.master
        let line = String(format: "%.0f° · %.0f %%", m.hue, m.saturation * 100)
            + (m.luminance != 0 ? " · " + Layer2Control.signed(m.luminance * 100, decimals: 0) : "")
        return HStack(spacing: 6) {
            Text(ColorBalance.Zone.master.label).font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.secondary)
            Text(line).font(Theme.Font.value).foregroundStyle(Theme.Ink.tertiary)
            Spacer(minLength: 0)
            Button(EditText.reset) { session.changeGrade { $0.colorBalance.master = ColorZone() } }
                .buttonStyle(.plain)
                .font(Theme.Font.sublabel)
                .foregroundStyle(Theme.accent)
        }
        .frame(height: Theme.Metric.subRowHeight)
        .help(L("A master colour from an earlier edit. Reset removes it.",
                zh: "来自早先编辑的整体色彩。还原会将其移除。"))
    }
}

// MARK: - one wheel

/// One zone's wheel: hue round it, saturation out from the centre.
struct ZoneWheelControl: View {
    let zone: ColorBalance.Zone
    let selected: Bool
    let size: CGFloat
    @Bindable var session: Session
    let select: () -> Void

    @State private var start: CGPoint?
    @State private var travelled = CGSize.zero
    @State private var travel = CGSize.zero
    @State private var id = UUID()
    @State private var run = KeyRun()
    @FocusState private var focused: Bool

    /// The point stops this far inside the rim, so it is never half off.
    private var radius: CGFloat { size / 2 - 5 }
    private var value: ColorZone { session.layerAdjustments.colorBalance[zone] }

    var body: some View {
        ZStack {
            Circle().fill(ColorBalanceLayout.Wheel.gradient)
            Circle().fill(RadialGradient(colors: [Theme.card, Theme.card.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
            Circle().stroke(selected || focused ? Theme.accent : Theme.dim.opacity(0.6),
                            lineWidth: selected || focused ? 1.5 : 0.5)
            let p = ColorBalanceLayout.Wheel.point(hue: value.hue, saturation: value.saturation, radius: radius)
            Circle().fill(Theme.text).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Theme.card, lineWidth: 1))
                .offset(x: p.x, y: p.y)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in
            if now {
                select()
                Layer2KeyFocus.shared.claim(id) { arrow, mods in press(arrow, mods) }
            } else {
                Layer2KeyFocus.shared.release(id)
                run.finish(session.endLayer2Gesture)
            }
        }
        .onDisappear {
            Layer2KeyFocus.shared.release(id)
            run.finish(session.endLayer2Gesture)
            if start != nil { start = nil; session.endLayer2Gesture() }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            if start == nil {
                // Taken hold of where the point is, not where the pointer is.
                start = ColorBalanceLayout.Wheel.point(hue: value.hue, saturation: value.saturation, radius: radius)
                travelled = .zero; travel = .zero
                select(); focused = true
                session.beginLayer2Gesture()
            }
            // ⌥ moves the point a quarter of the pointer's travel, from here on.
            let rate: CGFloat = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1
            travel.width += (g.translation.width - travelled.width) * rate
            travel.height += (g.translation.height - travelled.height) * rate
            travelled = g.translation
            guard travel != .zero, let start else { return }
            let next = ColorBalanceLayout.Wheel.dragged(from: start, by: travel, radius: radius)
            session.changeGrade {
                $0.colorBalance[zone].hue = next.hue
                $0.colorBalance[zone].saturation = next.saturation
            }
        }.onEnded { _ in
            start = nil
            session.endLayer2Gesture()
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { resetColour() })
        .help(zone.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(zone.label)
        .accessibilityValue(String(format: "%.0f°, %.0f %%", value.hue, value.saturation * 100))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAdjustableAction { direction in
            let s = direction == .increment ? 0.05 : -0.05
            session.changeGrade { $0.colorBalance[zone].saturation = ($0.colorBalance[zone].saturation + s).clamped(to: 0...1) }
        }
        .accessibilityAction(named: EditText.reset) { resetColour() }
        .accessibilityAction { select() }
    }

    /// ←/→ turn the hue a degree, ↑/↓ move the saturation a point.
    private func press(_ arrow: Layer2KeyFocus.Arrow, _ mods: NSEvent.ModifierFlags) {
        run.press(begin: session.beginLayer2Gesture, end: session.endLayer2Gesture)
        session.changeGrade { a in
            var z = a.colorBalance[zone]
            switch arrow {
            case .left, .right:
                // Clockwise on screen is up the hue, as the wheel is drawn.
                z.hue = (z.hue + arrow.sign * Layer2KeyFocus.stride(1, mods)).truncatingRemainder(dividingBy: 360)
                if z.hue < 0 { z.hue += 360 }
            case .up, .down:
                z.saturation = (z.saturation + arrow.sign * Layer2KeyFocus.stride(0.01, mods)).clamped(to: 0...1)
            }
            a.colorBalance[zone] = z
        }
    }

    /// The zone's colour back to none; its luminance is a row of its own.
    private func resetColour() {
        session.changeGrade {
            $0.colorBalance[zone].hue = 0
            $0.colorBalance[zone].saturation = 0
        }
    }
}
