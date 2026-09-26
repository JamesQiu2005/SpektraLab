//  WhiteBalanceRows.swift — decode white balance: Temperature and Tint, each
//  with its own "As Shot" line.
//
//  "How Temperature and Tint is wired remain unchanged" (PRD), and it is: the
//  values, the boxes and their rules are exactly what they were. What changed
//  is the two controls that used to sit above them — a preset pill and an
//  eyedropper on a row of their own. The 2026-09-17 drawing's Camera section
//  has five rows and neither of those is one of them, so they moved into the
//  section's "•••" (`CameraSection.menu`), which the drawing does give every
//  section. Nothing was removed.
//
//  What the boxes mean, and the rules that make them behave, live in
//  `WhiteBalanceBoxes` (`Model/Sidecar.swift`), where they can be tested
//  without a decode, a window or an engine. The short version: a ticked box
//  means "this axis is the camera's", which is `.asShot` *and* a `.custom`
//  setting that happens to hold the camera's value — the same picture, so the
//  same state.
//
//  Only RAW input can be re-balanced: a flat file has no camera white balance
//  to re-apply. Both rows grey and stop taking hits for one, through the same
//  `rowEnabled` every non-selectable control in the app uses, and say why in a
//  tooltip rather than a caption — the drawing has no caption, and the
//  explanation is only wanted by the user who wonders why the rows are dim.

import SwiftUI

struct WhiteBalanceRows: View {
    @Bindable var session: Session

    private var isRAW: Bool {
        session.decoded?.isRAW ?? (session.selection.map {
            ImageDecoder.rawExtensions.contains($0.pathExtension.lowercased())
        } ?? false)
    }
    /// Nothing to re-balance, and nothing to explain yet: no frame is open.
    private var enabled: Bool { session.selection == nil || isRAW }
    /// Ticking a box pins an axis to the camera's value, so with no decode
    /// there is nothing to pin to and the boxes are disabled.
    private var asShot: WhiteBalanceBoxes.AsShot? { session.asShotWhiteBalance }
    private var boxes: WhiteBalanceBoxes { session.whiteBalanceBoxes }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.rowSpacing) {
            ScrubSlider(label: L(.cameraTemperature),
                        sublabelView: asShotLine(Binding(get: { boxes.temp },
                                                         set: { session.setTempAsShot($0) })),
                        value: Binding(get: { session.decode.temperature },
                                       set: { session.setTemperature($0) }),
                        range: 2000...12000, zero: asShot?.temperature ?? 5500, snap: 100,
                        format: { "\(Int($0))" },
                        trackGradient: [Color(hex: 0x005982), Color(hex: 0x8FA83C), Color(hex: 0xFFF100)])

            ScrubSlider(label: L(.cameraTint),
                        sublabelView: asShotLine(Binding(get: { boxes.tint },
                                                         set: { session.setTintAsShot($0) })),
                        value: Binding(get: { session.decode.tint },
                                       set: { session.setTint($0) }),
                        range: -150...150, zero: asShot?.tint ?? 0, snap: 5,
                        format: { String(format: "%+.1f", $0) },
                        trackGradient: [Color(hex: 0x00A93A), Color(hex: 0x8AA45E), Color(hex: 0xE4007F)])
        }
        // v3 draws **one** As Shot line under the pair rather than one per
        // axis. Handoff §8.4 is explicit that the two axes stay independent
        // — the app tracks them separately and a single control would need a
        // defined mixed state — so the two lines stay, and the deviation
        // from the drawing is recorded here rather than closed by coupling
        // temperature to tint.
        .rowEnabled(enabled, because: L(.reasonDecodeWBDisabled))
    }

    /// "As Shot ☐" — the second label line, as the drawing has it.
    private func asShotLine(_ isOn: Binding<Bool>) -> AnyView {
        AnyView(AsShotLine(isOn: isOn, enabled: asShot != nil))
    }
}
