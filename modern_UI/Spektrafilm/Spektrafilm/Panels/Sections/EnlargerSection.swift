//  EnlargerSection.swift — the print: brightness and the two filter axes.
//
//  Zero is the auto-solve. Brightness is in stops, brighter positive (the
//  engine's `print_exposure` inverts: less exposure prints brighter, and the
//  user should not have to hold that in their head). The filter head has two
//  axes — yellow and magenta — because that is what a dichroic head has; the
//  design's "Cyan" is the same axis seen from the other end and was renamed
//  so the label matches `y_filter_shift`.

import SwiftUI

struct EnlargerSection: View {
    @Bindable var session: Session

    var body: some View {
        // Not in the 2026-09-17 drawing, and kept: it is the only access to
        // `print_exposure` and the two filter axes, and the PRD does not ask
        // for them to go. Collapsed by default, so the four sections that
        // *are* drawn are the four you see.
        PanelSection("Enlarger", key: "enlarger", initiallyExpanded: false, menu: { AnyView(menu) }) {
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
            }
        }
    }

    private var menu: some View {
        Group {
            Button("Reset to solve") { var p = session.params; p.printBrightnessStops = 0; p.yFilterShift = 0; p.mFilterShift = 0; session.params = p }
        }
    }
}
