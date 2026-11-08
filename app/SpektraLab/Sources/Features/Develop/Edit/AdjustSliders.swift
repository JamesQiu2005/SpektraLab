//  AdjustSliders.swift — Adjust's slider tiles (亮度 对比度 色调 鲜艳度 饱和度 色温, Vignette), and the slider.
//
//  Litti's flow, in the shape the owner asked for on 2026-10-26: a tile's
//  controls sit at the foot of the panel, over its bar, **one a row** — the
//  name, a track the knob moves along, and the number in a box that takes
//  typing. Two controls used to share a row; a fixed track and an editable
//  number need the page's width. The slider is the shared `ValueSlider`; where
//  the colour of the track says what the control does (temperature, tint,
//  saturation, a colour of HSL) the track is drawn in it.

import SwiftUI

/// Tone's two pages, under its bar's menu.
enum TonePage: String, CaseIterable, Identifiable, Sendable {
    case highlightsShadows, whitesBlacks
    var id: String { rawValue }
    var title: String { self == .highlightsShadows ? L("Highlights & Shadows") : L("Whites & Blacks") }
    var controls: [Layer2Control] { self == .highlightsShadows ? [.highlights, .shadows] : [.whites, .blacks] }
}

struct AdjustSliders: View {
    let session: OpenFrameSession
    let tool: AdjustTool
    var tone: TonePage = .highlightsShadows

    private var controls: [Layer2Control] { tool == .tone ? tone.controls : tool.controls }

    var body: some View {
        // One control a row, as Capture One sets them: a name, a track and a
        // number each needs the page's width (the owner, 2026-10-26).
        VStack(spacing: 2) {
            ForEach(controls) { control in
                EditSlider(title: control.title(in: tool), value: Binding(
                    get: { session.adjustments[control] },
                    set: { v in session.changeEdit { $0[control] = v } }),
                    range: control.range, rest: control.rest,
                    text: { control.text($0) + (control == .exposure ? " EV" : "") },
                    track: control.track, detentAtRest: true,
                    editing: { $0 ? session.beganEdit() : session.endedEdit() })
                .accessibilityIdentifier("adjust.slider.\(control.rawValue)")
            }
        }
        .onDisappear { session.endedEdit() }
    }
}

extension Layer2Control {
    /// Its name on a tile's slider: Litti's 着色 for the tint beside 色温, which
    /// elsewhere in the app (the RAW's white balance) is 色调.
    func title(in tool: AdjustTool) -> String {
        self == .tint && tool == .temperature ? L("Tint", as: "the colour shift") : title
    }

    /// The colours its track is drawn in, left to right; nil is the plain track.
    var track: [Color]? {
        switch self {
        case .temperature: [Color(hex: 0x4A63D8), Theme.dim, Color(hex: 0xE2B04A)]
        case .tint: [Color(hex: 0x58B26A), Theme.dim, Color(hex: 0xC85BB8)]
        case .saturation, .vibrance: [Theme.dim, Color(hex: 0xD9584B), Color(hex: 0xE2C14A), Color(hex: 0x5DBB6A),
                                      Color(hex: 0x4AA8D8), Color(hex: 0x6A5BD8), Color(hex: 0xC85BB8)]
        case .brightness, .exposure, .whites, .blacks, .highlights, .shadows, .contrast:
            [Color(hex: 0x2A2A29), Color(hex: 0xBDBBB7)]
        case .vignette: [Color(hex: 0x101010), Theme.dim, Color(hex: 0xE6E4E0)]
        case .vignetteMidpoint: nil
        }
    }
}

/// One value on the page's fixed track: Adjust's controls, HSL's, the curve's
/// parametric amounts, and Decode's Film Exposure. It is the shared
/// `ValueSlider` — the name, a track the knob moves along, and a number that
/// takes typing (the owner's Capture One reference, 2026-10-26).
struct EditSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var rest: Double = 0
    var text: (Double) -> String = { Fmt.signed($0, decimals: 0) }
    var track: [Color]? = nil
    var detentAtRest = false
    var editing: (Bool) -> Void = { _ in }

    var body: some View {
        ValueSlider(title: title, value: $value, range: range, rest: rest,
                    text: text, track: track, detentAtRest: detentAtRest,
                    onEditingChanged: editing)
    }
}
