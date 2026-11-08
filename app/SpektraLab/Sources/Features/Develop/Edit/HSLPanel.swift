//  HSLPanel.swift — Adjust's HSL and 通道 (the channel mixer).
//
//  Litti's HSL flow: a row of the eight colours as rings, the picked one
//  filled; under it the picked colour's Hue, Saturation and Luminance, each
//  track drawn in what it does to that colour. 通道 is the same shape for the
//  channel mixer: the three output channels as rings, and under the picked one
//  how much of red, green and blue it takes. Both are live Layer 2 (the
//  kernel's steps 5c and 5d); a ring with a dot under it is a colour or a
//  channel that is moved.

import SwiftUI

extension HSLHue {
    /// The colour its ring is drawn in.
    var swatch: Color { Color(hue: centre / 360, saturation: 0.72, brightness: 0.9) }

    /// What its slider's track shows: the hue turned either way, the colour from
    /// grey to full, from dark to light.
    func track(_ component: HSLBand.Component) -> [Color] {
        switch component {
        case .hue:
            let reach = HSLSet.hueReach
            return [-reach, 0, reach].map { d in
                var h = (centre + d) / 360
                if h < 0 { h += 1 }
                return Color(hue: h, saturation: 0.72, brightness: 0.9)
            }
        case .saturation: return [Color(hue: centre / 360, saturation: 0, brightness: 0.62), swatch]
        case .luminance: return [Color(hue: centre / 360, saturation: 0.72, brightness: 0.35),
                                 Color(hue: centre / 360, saturation: 0.45, brightness: 1)]
        }
    }
}

extension ChannelMixer.Channel {
    var swatch: Color {
        switch self {
        case .red: Color(hex: 0xD9584B)
        case .green: Color(hex: 0x5DBB6A)
        case .blue: Color(hex: 0x4A73D8)
        }
    }
}

/// A row of colour rings, one picked: HSL's colours, the mixer's channels, the curve's channels.
struct ColourRings<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let colour: (Option) -> Color
    let title: (Option) -> String
    var moved: (Option) -> Bool = { _ in false }
    var diameter: CGFloat = 26

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let on = option == selection
                Button {
                    guard !on else { return }
                    selection = option
                } label: {
                    ZStack {
                        Circle().strokeBorder(colour(option), lineWidth: 3)
                        if on { Circle().fill(colour(option)).padding(1) }
                    }
                    .frame(width: diameter, height: diameter)
                    .overlay(alignment: .bottom) {
                        Circle().fill(Theme.secondaryText).frame(width: 4, height: 4)
                            .offset(y: 8).opacity(moved(option) ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .accessibilityLabel(title(option))
                .accessibilityValue(moved(option) ? L("Edited") : "")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct HSLTool: View {
    let session: OpenFrameSession
    @Binding var hue: HSLHue

    var body: some View {
        VStack(spacing: 6) {
            ColourRings(options: HSLHue.allCases, selection: $hue, colour: \.swatch, title: \.title,
                        moved: { !session.adjustments.hsl[$0].isNeutral })
                .accessibilityIdentifier("adjust.hsl.rings")
            ForEach(HSLBand.Component.allCases) { component in
                EditSlider(title: component.title, value: Binding(
                    get: { session.adjustments.hsl[hue][component] },
                    set: { v in session.changeEdit { $0.hsl[hue][component] = v } }),
                    range: HSLSet.range, track: hue.track(component), detentAtRest: true,
                    editing: { $0 ? session.beganEdit() : session.endedEdit() })
                .accessibilityIdentifier("adjust.hsl.\(component.rawValue)")
            }
        }
        .onDisappear { session.endedEdit() }
    }
}

struct ChannelMixerTool: View {
    let session: OpenFrameSession
    @Binding var output: ChannelMixer.Channel

    var body: some View {
        VStack(spacing: 6) {
            Text(L("Output") + " · " + output.title)
                .font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.dim)
            ColourRings(options: ChannelMixer.Channel.allCases, selection: $output, colour: \.swatch, title: \.title,
                        moved: { !session.adjustments.channelMixer[$0].isNeutral }, diameter: 30)
                .padding(.horizontal, 48)
                .accessibilityIdentifier("adjust.channel.rings")
            ForEach(ChannelMixer.Channel.allCases) { input in
                EditSlider(title: input.title, value: Binding(
                    get: { session.adjustments.channelMixer[output][input] + (input == output ? 100 : 0) },
                    set: { v in session.changeEdit { $0.channelMixer[output][input] = v - (input == output ? 100 : 0) } }),
                    range: input == output ? 0...200 : ChannelMixer.range, rest: input == output ? 100 : 0,
                    text: { String(format: "%.0f%%", $0) }, track: [Color(hex: 0x101010), input.swatch], detentAtRest: true,
                    editing: { $0 ? session.beganEdit() : session.endedEdit() })
                .accessibilityIdentifier("adjust.channel.\(input.rawValue)")
            }
        }
        .onDisappear { session.endedEdit() }
    }
}
