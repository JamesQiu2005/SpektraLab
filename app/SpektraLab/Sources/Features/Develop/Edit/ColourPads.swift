//  ColourPads.swift — 色轮: the colour balance's three zones as pads of dots.
//
//  The owner (2026-10-19): the wheel "is not really working, so everything in
//  the colour wheel would be turned into a pad style that has actual snappable
//  dots and visual and haptic feedback", each a rounded square. A pad is
//  `ColourPad`'s 11 × 11 dots: the centre no change, a direction a hue, the
//  ring out the strength. The knob is a white dot that snaps to the dot under
//  the finger, the row and column through it lit.
//
//  How the three stack: Highlights, Midtones and Shadows are a column of small
//  pads, top to bottom as a print runs from light to dark, each drawn with its
//  knob where it is; the one picked is the large pad beside them, under the
//  finger. Three pads of a third of the width each would put a dot every
//  9 points, under a fingertip's width; one large pad puts one every 20 and
//  keeps all three in sight. The picked zone's luminance is the slider below.
//  The model's Master zone is not a pad: an older edit's master shows as a
//  line with a way to clear it, and is applied as it always was.
//
//  on the Mac the pads are Capture One's wheels,
//  "not a 2-D pad but a C1 style, but the relative layout stays unchanged" — the same column of zones,
//  each tile a small wheel, the picked zone's wheel beside it, 明度 below (`Sources/Mac/MacColourWheel.swift`).

import SwiftUI

struct ColourWheelsTool: View {
    let session: OpenFrameSession
    let height: CGFloat
    @Binding var zone: ColorBalance.Zone
    /// The pads, top to bottom: light to dark.
    static let zones: [ColorBalance.Zone] = [.highlights, .midtones, .shadows]
    /// The selectors' column: a small pad and its name and reading beside it.
    static let column: CGFloat = 136

    var body: some View {
        let balance = session.adjustments.colorBalance
        let masterH: CGFloat = balance.master.isNeutral ? 0 : 34
        GeometryReader { geo in
            let side = min(height - 52 - masterH - 20, geo.size.width - 12 - Self.column)
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 12) {
                    VStack(spacing: 6) {
                        ForEach(Self.zones) { z in selector(z, balance[z], height: (side - 12) / 3) }
                    }
                    .frame(width: Self.column, height: side)
                    large.frame(width: side, height: side)
                }
                .frame(maxWidth: .infinity)
                EditSlider(title: L("Luminance"), value: Binding(
                    get: { session.adjustments.colorBalance[zone].luminance * 100 },
                    set: { v in session.changeEdit { $0.colorBalance[zone].luminance = v / 100 } }),
                    range: -100...100, track: [Color(hex: 0x2A2A29), Color(hex: 0xBDBBB7)], detentAtRest: true,
                    editing: { $0 ? session.beganEdit() : session.endedEdit() })
                    .accessibilityIdentifier("adjust.wheels.luminance")
                if !balance.master.isNeutral { masterLine(balance.master) }
            }
        }
        .frame(height: height - 20)
        .onDisappear { session.endedEdit() }
        #if DEBUG
        // `MacDriver`'s `wheels.<zone>`: the zone picked, as its tile's click picks it.
        .onReceive(NotificationCenter.default.publisher(for: MacDriver.wheelZone)) { note in
            if let z = (note.object as? String).flatMap(ColorBalance.Zone.init(rawValue:)) { zone = z }
        }
        #endif
    }

    /// The picked zone's control: the pad, or on the Mac Capture One's wheel (Mac change, PAGES.md,
    /// the owner, 2026-10-24).
    @ViewBuilder private var large: some View {
        MacColourWheelControl(session: session, zone: zone)
    }

    /// A zone's tile's picture: its pad, or on the Mac its small wheel (Mac change, as `large`).
    @ViewBuilder private func face(_ value: ColorZone, picked: Bool) -> some View {
        MacColourWheelFace(zone: value, small: true, picked: picked)
    }

    private func selector(_ z: ColorBalance.Zone, _ value: ColorZone, height: CGFloat) -> some View {
        let picked = z == zone
        return Button {
            guard !picked else { return }
            zone = z
        } label: {
            HStack(spacing: 8) {
                face(value, picked: picked)
                    .frame(width: min(height, 48), height: min(height, 48))
                VStack(alignment: .leading, spacing: 2) {
                    Text(z.padTitle).font(Theme.Font.ui(12.5, picked ? .semibold : .medium))
                        .foregroundStyle(picked ? Theme.text : Theme.secondaryText)
                    Text(value.padText).font(Theme.Font.ui(11)).monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(z.padTitle)
        .accessibilityValue(value.padText)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("adjust.wheels.\(z.rawValue)")
    }

    private func masterLine(_ master: ColorZone) -> some View {
        HStack {
            Text(L("Master")).font(Theme.Font.ui(12.5, .medium))
            Text(master.padText).font(Theme.Font.ui(11)).monospacedDigit().foregroundStyle(Theme.dim)
            Spacer()
            Button(L("Reset")) { session.changeEdit { $0.colorBalance.master = ColorZone() } }
                .font(Theme.Font.ui(12.5, .semibold))
                .frame(minWidth: 44, minHeight: 34)
                .accessibilityLabel(L("Reset") + " " + L("Master"))
        }
        .frame(height: 34)
    }
}

extension ColorBalance.Zone {
    /// The pad's word: the owner's 高光 · 中性 · 阴影.
    var padTitle: String { self == .midtones ? L("Midtones", as: "the colour pad") : title }
}

extension ColorZone {
    /// "None", or the direction and the strength: "200° · 30%".
    var padText: String {
        guard saturation > 0 else { return L("None") }
        return String(format: "%.0f° · %.0f%%", hue, saturation * 100)
    }
}
