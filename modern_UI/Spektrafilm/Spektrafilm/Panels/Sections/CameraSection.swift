//  CameraSection.swift — how the photograph enters the film: AE Method, Film
//  Exposure, Temperature, Tint, Vignetting, Lens Correction.
//
//  The 2026-09-17 drawing's first section, and every row of it is a row of
//  the drawing. No well: controls sit directly on the rail, which is what
//  changed across the whole interface — a well now holds a *choice from a
//  set* (the film and print lists) and nothing else.
//
//  **AE Method** (`auto_exposure` + `auto_exposure_method`, and the pill is
//  wired to `Session.aeMethod`). The four intents are what the engine's meter
//  follows: overall correctness (`balanced`), a subject in the middle
//  (`center`), the brightest part kept (`protect highlights`), the darkest
//  kept (`protect shadows`). `Custom` is the meter **off** — the PRD's
//  "linearized baseline as the +0.0 baseline" — and it needed no new field,
//  because `camera.auto_exposure` has been in the schema all along.
//
//  **Film Exposure** (`exposure_compensation_ev`) sits directly under it, as
//  the PRD asks, because the two are one decision read in two lines: the
//  method chooses a baseline and the slider offsets it. It is **film
//  placement, not print brightness** — the print gain is taken from a mid-grey
//  exposed at this offset (`printing.cpp`), so the print re-normalises what
//  the slider moves: measured on the smoke frame, a 4 EV sweep moves the mean
//  print luminance by 2.4 %, downward, while the contrast rises. What it buys
//  is where the scene sits on the film curve: grain, latitude, saturation.
//
//  **Temperature and Tint** are unchanged, as the PRD says ("How Temperature
//  and Tint is wired remain unchanged") — decode-side white balance, with the
//  "As Shot" box each axis has always had (`WhiteBalanceRows`).
//
//  **Vignetting** is client-side (Layer 2's lens fall-off). The engine has no
//  vignette parameter; it sits here because that is where a photographer
//  looks for it.
//
//  **Lens Correction** is decode-side too, and the one row in this section
//  that can be non-selectable — see `Session.lensCorrectionEnabled`.

import SwiftUI

struct CameraSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection("Camera", key: "camera", menu: { AnyView(menu) }) {
            RailRows {
                PillMenu(label: "AE Method",
                         options: AEMethod.offered + (session.aeMethod == .legacy ? [.legacy] : []),
                         title: { $0.title },
                         selection: Binding(get: { session.aeMethod },
                                            set: { session.aeMethod = $0 }))
                ScrubSlider(label: "Film Exposure",
                            sublabelView: asShotLine,
                            value: Binding(get: { session.params.exposureCompensationEV },
                                           set: { var p = session.params; p.exposureCompensationEV = $0; session.params = p }),
                            range: -4...4, snap: 1 / 3, format: { String(format: "%+.1f", $0) })
                WhiteBalanceRows(session: session)
                ScrubSlider(label: "Vignetting",
                            value: Binding(get: { session.adjustments.vignette.amount },
                                           set: { var a = session.adjustments; a.vignette.amount = $0; session.adjustments = a }),
                            range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                ToggleRow(label: "Lens Correction",
                          isOn: Binding(get: { session.decode.lensCorrection },
                                        set: { session.setLensCorrection($0) }),
                          enabled: session.lensCorrectionEnabled,
                          reason: session.lensCorrectionReason)
            }
        }
    }

    /// "As Shot ☐" under Film Exposure — the line the drawing puts under the
    /// first three sliders. What it means and what clicking it does are
    /// `Session.filmExposureIsAsShot` and `setFilmExposureAsShot(_:)`; this is
    /// only the two views.
    private var asShotLine: AnyView {
        AnyView(AsShotLine(isOn: Binding(get: { session.filmExposureIsAsShot },
                                         set: { session.setFilmExposureAsShot($0) }),
                           enabled: true))
    }

    /// What the drawing has no room for and the section still needs: the
    /// white-balance presets and the neutral picker, which were a pill and an
    /// eyedropper on a row of their own. The drawing's Camera section is five
    /// rows and none of them is that row — so they are here, in the "•••" the
    /// drawing *does* give every section.
    private var menu: some View {
        Group {
            Button("Reset film exposure") {
                var p = session.params; p.exposureCompensationEV = 0; session.params = p
            }
            Divider()
            Button("Pick a neutral point on the image") { session.wbPickerActive.toggle() }
                .disabled(session.selection == nil)
            Menu("White balance preset") {
                ForEach(DecodeSettings.WhiteBalance.allCases.filter { $0 != .custom }, id: \.self) { wb in
                    Button {
                        session.setWhiteBalance(wb)
                    } label: {
                        if session.decode.whiteBalance == wb { Label(wb.rawValue, systemImage: "checkmark") }
                        else { Text(wb.rawValue) }
                    }
                }
            }
        }
    }
}

/// "As Shot" and its box, on the second line of a slider row.
///
/// The box's own padding is a hit area rather than layout (it is drawn 8 pt),
/// so the negative vertical padding keeps the line from growing to suit it.
struct AsShotLine: View {
    @Binding var isOn: Bool
    var enabled: Bool
    var body: some View {
        HStack(spacing: 3) {
            Text("As Shot").font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary)
            CheckBox(isOn: $isOn).padding(.vertical, -6)
            Spacer(minLength: 0)
        }
        .rowEnabled(enabled)
    }
}

/// The rows of a section, inset and spaced the way the drawing insets and
/// spaces them: 18 pt from both edges of the rail, 5 pt apart.
///
/// One container rather than a modifier on each row, because the inset is a
/// property of the *column* — a row that forgot it would not look wrong on
/// its own, only out of line with the four above it, which is exactly the
/// kind of drift a capture catches late.
struct RailRows<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.rowSpacing) {
            content()
        }
        .padding(.horizontal, Theme.Metric.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
