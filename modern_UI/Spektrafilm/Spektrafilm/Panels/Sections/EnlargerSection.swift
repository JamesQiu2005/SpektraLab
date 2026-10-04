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
                // On a frame of a pair: whose print this is, and whether the
                // film around the frame moves with it (answers B1–B3).
                if session.pickedHole != nil {
                    PillSwitchRow(label: L("Applies to", zh: "作用于"), options: HalfFramePair.Scope.allCases,
                                  selection: Binding(get: { session.enlargerScope }, set: { session.enlargerScope = $0 }),
                                  title: { $0 == .frame ? L("Frame", zh: "仅画面") : L("+ Film", zh: "含片基") })
                }
                ScrubSlider(label: L("Brightness", zh: "亮度"), sublabel: L("stops", zh: "档"),
                            value: Binding(get: { session.enlargerValue(.brightness) },
                                           set: { session.setEnlarger(.brightness, $0) }),
                            range: -3...3, snap: 0.25, format: { String(format: "%+.2f", $0) })
                // The filters are the head's, and a negative prints the
                // other way: more yellow filtration is a bluer print, more
                // magenta a greener one (measured through the engine). The
                // track shows the print, so its colour is where the slider
                // takes the picture.
                ScrubSlider(label: L("Yellow", zh: "黄"), sublabel: L("→ blue", zh: "→ 蓝"),
                            value: Binding(get: { session.enlargerValue(.yellow) },
                                           set: { session.setEnlarger(.yellow, $0) }),
                            range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) },
                            trackGradient: [Color(hex: 0xB8A860), Color(hex: 0x8A8A8A), Color(hex: 0x6F7FB0)])
                ScrubSlider(label: L("Magenta", zh: "品红"), sublabel: L("→ green", zh: "→ 绿"),
                            value: Binding(get: { session.enlargerValue(.magenta) },
                                           set: { session.setEnlarger(.magenta, $0) }),
                            range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) },
                            trackGradient: [Color(hex: 0xB07CAE), Color(hex: 0x8A8A8A), Color(hex: 0x7CA87C)])
                ScrubSlider(label: L(.enlargerPreflash), sublabel: "×100",
                            value: Binding(get: { session.enlargerValue(.preflash) * 100 },
                                           set: { session.setEnlarger(.preflash, ($0 / 100).clamped(to: 0...0.03)) }),
                            range: 0...3, snap: 0.25, format: { String(format: "%.2f", $0) },
                            disabled: !session.params.printEffects)
                    .help(session.params.printEffects ? "" : L(.reasonPrintEffectsOff))
            }
        }
    }

    private func reset() { session.resetEnlarger() }

    private var menu: some View {
        Group {
            Button(L(.helpResetEnlarger)) { reset() }
        }
    }
}
