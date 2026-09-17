//  RightSections.swift — the grade rail: Histogram, White Balance, Exposure,
//  Curve, Color Balance, in the 2026-09-17 drawing's order and with its names.
//  All Layer 2 except the histogram, which reads the adjusted image. Each is
//  its own view; the rail lists them and puts a hairline between.
//
//  **No wells.** The drawing keeps exactly two in the whole interface, both on
//  the left rail, and both hold a choice from a set. Everything here sits
//  directly on the rail — which is also what makes the sliders legible, since
//  a track is the ground colour and a ground-coloured track on a
//  ground-coloured well is not a track at all.

import SwiftUI

struct HistogramSection: View {
    @Bindable var session: Session
    var body: some View {
        // No menu — it used to pass an empty one, which drew a live "..."
        // over a popup with nothing in it. `SectionHeader` draws no glyph
        // for a section with nothing to offer, which is the honest version
        // of the same statement.
        PanelSection("Histogram", key: "histogram") {
            VStack(spacing: 3) {
                // The drawing's plot is 255.5 × 45 pt inside a 288 rail, with
                // the exposure triple read underneath it.
                HistogramPlot(bins: session.histogram, channels: [.rgb])
                    .frame(height: 45)
                HStack {
                    Text(session.exif?.iso ?? "")
                    Spacer()
                    Text(session.exif?.shutter ?? "")
                    Spacer()
                    Text(session.exif?.aperture ?? "")
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, Theme.Metric.plotInset)
        }
    }
}

struct WhiteBalanceSection: View {
    @Bindable var session: Session
    var body: some View {
        // "White Balance", which is the drawing's name for this section. The
        // other white balance in this window is the **decode** pair in Camera,
        // and they are told apart by where they are and by the caption below
        // rather than by a longer title: the handoff's rule is that two stages
        // must not share a name, and these two do not — Camera's rows are
        // Temperature and Tint, this one's are Temp. and Tint on the print.
        PanelSection("White Balance", key: "wb2", initiallyExpanded: false, menu: { AnyView(Button("Reset") {
            var a = session.adjustments; a.temperature = 0; a.tint = 0; session.adjustments = a }) }) {
            RailRows {
                ScrubSlider(label: "Temp.", value: adj(\.temperature), range: -100...100, snap: 5,
                            format: { String(format: "%+.0f", $0) },
                            trackGradient: [Color(hex: 0x005982), Color(hex: 0x8FA83C), Color(hex: 0xFFF100)])
                ScrubSlider(label: "Tint", value: adj(\.tint), range: -100...100, snap: 5,
                            format: { String(format: "%+.0f", $0) },
                            trackGradient: [Color(hex: 0x00A93A), Color(hex: 0x8AA45E), Color(hex: 0xE4007F)])
                // The other white balance in this window is the decode block
                // in Camera. This one is Layer 2, on the print (HANDOFF §6).
                Text("Print — an adjustment on the scan.")
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
        PanelSection("Exposure", key: "exposure2", initiallyExpanded: false, menu: { AnyView(Button("Reset") {
            var a = session.adjustments
            a.exposure = 0; a.contrast = 0; a.brightness = 0; a.saturation = 0
            a.highlights = 0; a.shadows = 0; a.blackPoint = 0; a.whitePoint = 0
            session.adjustments = a }) }) {
            RailRows {
                ScrubSlider(label: "Exposure", value: adj(\.exposure), range: -3...3, snap: 0.25, format: { String(format: "%+.2f", $0) })
                ScrubSlider(label: "Contrast", value: adj(\.contrast), range: -50...50, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: "Brightness", value: adj(\.brightness), range: -50...50, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: "Saturation", value: adj(\.saturation), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                // A hairline, like the ones between sections — the same wall,
                // one storey down. It separates the four global controls from
                // the four that reach into a tonal range.
                Hairline().padding(.vertical, 2)
                ScrubSlider(label: "Highlights", value: adj(\.highlights), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: "Shadows", value: adj(\.shadows), range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                ScrubSlider(label: "Black Point", value: adj(\.blackPoint), range: 0...50, snap: 1, format: { String(format: "%.0f", $0) })
                ScrubSlider(label: "White Point", value: adj(\.whitePoint), range: 0...50, snap: 1, format: { String(format: "%.0f", $0) })
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
        PanelSection("Curve", key: "curve", menu: { AnyView(Button("Reset all channels") {
            var a = session.adjustments; a.curves = CurveSet(); session.adjustments = a }) }) {
            CurveEditor(session: session)
                .padding(.horizontal, Theme.Metric.plotInset)
        }
    }
}

struct ColorBalanceSection: View {
    @Bindable var session: Session
    var body: some View {
        PanelSection("Color Balance", key: "colorbalance", initiallyExpanded: false, menu: { AnyView(Button("Reset") {
            var a = session.adjustments; a.colorBalance = ColorBalance(); session.adjustments = a }) }) {
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
