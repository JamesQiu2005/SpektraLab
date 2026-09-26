//  EnlargerSection.swift — the print: brightness and the two filter axes.
//
//  Zero is the auto-solve. Brightness is in stops, brighter positive (the
//  engine's `print_exposure` inverts: less exposure prints brighter, and the
//  user should not have to hold that in their head). The filter head has two
//  axes — yellow and magenta — because that is what a dichroic head has; the
//  design's "Cyan" is the same axis seen from the other end and was renamed
//  so the label matches `y_filter_shift`.
//
//  **v4 puts it back in the left rail**, last, and gives it the enlarger's
//  other control: **pre-flash**, a uniform exposure of the paper through the
//  film's clear base before the image (`preflash_exposure`). Its wire value
//  is not in stops and its useful range is 0…0.03 (measured on `_DSC2663`,
//  0.01 is ~9 % of the mid-grey exposure), so the row shows it ×100.

import SwiftUI

struct EnlargerSection: View {
    @Bindable var session: Session

    var body: some View {
        // Collapsed by default, as v4 draws it.
        PanelSection(L(.sectionEnlarger), key: "enlarger", initiallyExpanded: false,
                     action: SectionAction(help: L(.helpResetEnlarger)) { reset() },
                     menu: { AnyView(menu) }) {
            RailRows {
                ScrubSlider(label: "Brightness", sublabel: "stops",
                            value: Binding(get: { session.params.printBrightnessStops },
                                           set: { var p = session.params; p.printBrightnessStops = $0; session.params = p }),
                            range: -3...3, snap: 0.25, format: { String(format: "%+.2f", $0) })
                ScrubSlider(label: "Yellow", sublabel: "← blue",
                            value: Binding(get: { session.params.yFilterShift },
                                           set: { var p = session.params; p.yFilterShift = $0; session.params = p }),
                            range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) },
                            trackGradient: [Color(hex: 0x6F7FB0), Color(hex: 0x8A8A8A), Color(hex: 0xB8A860)])
                ScrubSlider(label: "Magenta", sublabel: "← green",
                            value: Binding(get: { session.params.mFilterShift },
                                           set: { var p = session.params; p.mFilterShift = $0; session.params = p }),
                            range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) },
                            trackGradient: [Color(hex: 0x7CA87C), Color(hex: 0x8A8A8A), Color(hex: 0xB07CAE)])
                ScrubSlider(label: L(.enlargerPreflash), sublabel: "×100",
                            value: Binding(get: { session.params.preflashExposure * 100 },
                                           set: { var p = session.params; p.preflashExposure = ($0 / 100).clamped(to: 0...0.03); session.params = p }),
                            range: 0...3, snap: 0.25, format: { String(format: "%.2f", $0) },
                            disabled: !session.params.printEffects)
                    .help(session.params.printEffects ? "" : L(.reasonPrintEffectsOff))
            }
        }
    }

    private func reset() {
        var p = session.params
        p.printBrightnessStops = 0; p.yFilterShift = 0; p.mFilterShift = 0; p.preflashExposure = 0
        session.params = p
    }

    private var menu: some View {
        Group {
            Button(L(.helpResetEnlarger)) { reset() }
        }
    }
}
