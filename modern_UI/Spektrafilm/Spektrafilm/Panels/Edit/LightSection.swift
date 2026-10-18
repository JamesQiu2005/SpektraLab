//  LightSection.swift — Post-Dev's Light: the tone of the finished print.
//
//  Exposure, Contrast, Brightness; Highlights, Shadows, Whites, Blacks; the
//  vignette and its midpoint — the control table's Light rows
//  (`Layer2Control.light`), in its order, with its ranges. Hairlines part the
//  three groups the way 1.3's Exposure section parted the global controls
//  from the regional ones.
//
//  Whites and Blacks are the black and white points, both ways from zero
//  (`Adjustments.blacks`): Blacks to the right lifts the black, to the left
//  crushes it, and every row in the section is lighter to the right.
//  Saturation moved to Colour, where the rest of the colour is.

import SwiftUI

struct LightSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection(L("Light", zh: "光"), key: "light", menu: { AnyView(Button(EditText.reset) {
            session.changeGrade { $0.reset(.light) } }) }, metrics: .right) {
            RailRows {
                rows([.exposure, .contrast, .brightness])
                Hairline().padding(.vertical, 2)
                rows([.highlights, .shadows, .whites, .blacks])
                Hairline().padding(.vertical, 2)
                rows([.vignette, .vignetteMidpoint])
            }
        }
    }

    @ViewBuilder private func rows(_ controls: [Layer2Control]) -> some View {
        ForEach(controls) { control in
            EditSliderRow(control, session: session)
        }
    }
}
