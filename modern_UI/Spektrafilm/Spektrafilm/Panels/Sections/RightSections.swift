//  RightSections.swift — the grade rail: White Balance, Exposure, Curve,
//  Color Balance, in the 2026-09-17 drawing's order and with its names. All
//  Layer 2. The histogram that used to head this rail is on the canvas now
//  (`EditorWindow`'s badge stack). Each is its own view; the rail lists them
//  and puts a hairline between.
//
//  **v3 (2026-09-18): this rail's section titles are 10.5 pt**, a step under
//  the left rail's 12, which is why every `PanelSection` here passes
//  `metrics: .right`. It is the drawing's own division and not a compromise:
//  this rail is 288 pt wide and carries the longer names, and the smaller
//  title is what fits `White Balance` and `Color Balance` on one line.
//
//  **No wells.** The drawing keeps exactly two in the whole interface, both on
//  the left rail, and both hold a choice from a set. Everything here sits
//  directly on the rail — which is also what makes the sliders legible, since
//  a track is the ground colour and a ground-coloured track on a
//  ground-coloured well is not a track at all.

import SwiftUI

struct WhiteBalanceSection: View {
    @Bindable var session: Session
    var body: some View {
        // "White Balance", which is the drawing's name for this section. The
        // other white balance in this window is the **decode** pair in Camera,
        // and they are told apart by where they are and by the caption below
        // rather than by a longer title: the handoff's rule is that two stages
        // must not share a name, and these two do not — Camera's rows are
        // Temperature and Tint, this one's are Temp. and Tint on the print.
        PanelSection(L(.sectionWhiteBalance), key: "wb2", initiallyExpanded: false, menu: { AnyView(Button(L(.helpReset)) {
            var a = session.adjustments; a.temperature = 0; a.tint = 0; session.adjustments = a }) }, metrics: .right) {
            RailRows {
                // **Temp. and Tint stay English, and are not the Camera
                // pair.** `design/LOCALIZATION-zh-Hans.md` lists 色温 once, for
                // the decode block in Camera, and its prose is explicit that
                // two stages must not share a name — which is the rule the
                // comment above already follows for them. Wiring these to
                // `cameraTemperature`/`cameraTint` would give the print stage
                // the decode stage's name in Chinese. This is a known boundary
                // of the spec's scope, not an oversight: its last section says
                // the main editor's tables are not a whole language pack, and
                // keys for these are a copy decision rather than a lookup.
                ScrubSlider(label: "Temp.", value: adj(\.temperature), range: -100...100, snap: 5,
                            format: { String(format: "%+.0f", $0) },
                            trackGradient: [Color(hex: 0x005982), Color(hex: 0x8FA83C), Color(hex: 0xFFF100)])
                ScrubSlider(label: "Tint", value: adj(\.tint), range: -100...100, snap: 5,
                            format: { String(format: "%+.0f", $0) },
                            trackGradient: [Color(hex: 0x00A93A), Color(hex: 0x8AA45E), Color(hex: 0xE4007F)])
                // The other white balance in this window is the decode block
                // in Camera. This one is Layer 2, on the print (HANDOFF §6).
                Text(L(.statusRightRailWBScope))
                    .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func adj(_ kp: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(get: { session.adjustments[keyPath: kp] }, set: { var a = session.adjustments; a[keyPath: kp] = $0; session.adjustments = a })
    }
}

struct ExposureSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection(L(.sectionExposure), key: "exposure2", initiallyExpanded: false, menu: { AnyView(Button(L(.helpReset)) {
            var a = session.adjustments
            a.exposure = 0; a.contrast = 0; a.brightness = 0; a.saturation = 0
            a.highlights = 0; a.shadows = 0; a.blackPoint = 0; a.whitePoint = 0
            session.adjustments = a }) }, metrics: .right) {
            RailRows {
                // The slider is `Exposure`, which the spec does not list — it
                // gives the *section* that name (曝光). Same boundary as Temp.
                // and Tint above: it would need its own key, because the spec
                // forbids collapsing two strings that share a spelling.
                ScrubSlider(label: "Exposure", value: adj(\.exposure), range: -3...3, snap: 0.25, format: { String(format: "%+.2f", $0) })
                ScrubSlider(label: L(.exposureContrast), value: adj(\.contrast), range: -50...50, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: L(.exposureBrightness), value: adj(\.brightness), range: -50...50, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: L(.exposureSaturation), value: adj(\.saturation), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                // A hairline, like the ones between sections — the same wall,
                // one storey down. It separates the four global controls from
                // the four that reach into a tonal range.
                Hairline().padding(.vertical, 2)
                ScrubSlider(label: L(.exposureHighlights), value: adj(\.highlights), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: L(.exposureShadows), value: adj(\.shadows), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: L(.exposureBlackPoint), value: adj(\.blackPoint), range: 0...50, snap: 1, format: { String(format: "%.0f", $0) })
                ScrubSlider(label: L(.exposureWhitePoint), value: adj(\.whitePoint), range: 0...50, snap: 1, format: { String(format: "%.0f", $0) })
            }
        }
    }
    private func adj(_ kp: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(get: { session.adjustments[keyPath: kp] }, set: { var a = session.adjustments; a[keyPath: kp] = $0; session.adjustments = a })
    }
}

struct CurveSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection(L(.sectionCurve), key: "curve", menu: { AnyView(Button(L(.helpResetChannels)) {
            var a = session.adjustments; a.curves = CurveSet(); session.adjustments = a }) }, metrics: .right) {
            CurveEditor(session: session)
                .padding(.horizontal, Theme.Metric.plotInset)
        }
    }
}

struct ColorBalanceSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection(L(.sectionColorBalance), key: "colorbalance", initiallyExpanded: false, menu: { AnyView(Button(L(.helpReset)) {
            var a = session.adjustments; a.colorBalance = ColorBalance(); session.adjustments = a }) }, metrics: .right) {
            // In a well, like Exposure and Print White Balance beside it. The
            // triangle is fitted to the width the **panel** has, which
            // `EditorWindow` passes down as `\.colorBalanceWidth` — the wheels
            // cannot measure it themselves (a preference arrives as zero before
            // the first layout, and a wheel sized to its floor still looks like
            // a wheel; see `ColorBalanceEditor`), and they cannot assume it
            // either now that the panel is the user's.
            ColorBalanceEditor(session: session)
                .padding(.horizontal, Theme.Metric.plotInset)
        }
    }
}
