//  CameraSection.swift — how the photograph enters the film: Metering, Film
//  Exposure, Temperature, Tint, Vignetting, Lens Correction.
//
//  **v3 (2026-09-18) renamed three things and added one.** The section is
//  **Input / Camera**; `AE Method` is **Metering**. Both are visual renames
//  only — `session.aeMethod` keeps its name, its offered values and its
//  legacy restoration, which handoff §7 requires. The addition is a **reset
//  arrow on the header**, beside the "•••". Its scope is left open by §8.3,
//  so it is wired to the one reset this section already had a name for —
//  film exposure — and the tooltip says exactly that rather than implying it
//  resets the section.
//
//  **v4 moved it to the Parameters rail** (Pre-Dev), and its rows onto that
//  rail's one grid: the 9 pt labels in a 70 pt column that v3 gave Camera
//  alone are gone, so Film Exposure's track starts where every other
//  slider's on the rail does (`SliderMetrics.parameters`).
//
//  The 2026-09-17 drawing's first section, and every row of it is a row of
//  the drawing. No well: controls sit directly on the rail, which is what
//  changed across the whole interface — a well now holds a *choice from a
//  set* (the film and print lists) and nothing else.
//
//  **Metering** (`auto_exposure` + `auto_exposure_method`, and the pill is
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
        PanelSection(L(.sectionCamera), key: "camera",
                     action: SectionAction(help: L(.helpResetFilmExposure)) {
                         var p = session.params; p.exposureCompensationEV = 0; session.params = p
                     },
                     menu: { AnyView(menu) }) {
            RailRows {
                PillMenu(label: L(.cameraMetering),
                         options: AEMethod.offered + (session.aeMethod == .legacy ? [.legacy] : []),
                         title: { L($0.key) },
                         selection: Binding(get: { session.aeMethod },
                                            set: { session.aeMethod = $0 }),
                         labelWidth: Theme.Metric.parameterLabelWidth)
                ScrubSlider(label: L(.cameraFilmExposure),
                            sublabelView: asShotLine,
                            value: Binding(get: { session.params.exposureCompensationEV },
                                           set: { var p = session.params; p.exposureCompensationEV = $0; session.params = p }),
                            range: -4...4, snap: 1 / 3, format: { String(format: "%+.1f", $0) })
                WhiteBalanceRows(session: session)
                ScrubSlider(label: L(.cameraVignetting),
                            value: Binding(get: { session.adjustments.vignette.amount },
                                           set: { var a = session.adjustments; a.vignette.amount = $0; session.adjustments = a }),
                            range: -100...100, snap: 5, format: { String(format: "%+.0f", $0) })
                ToggleRow(label: L(.cameraLensCorrection),
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
            Button(L(.helpResetFilmExposure)) {
                var p = session.params; p.exposureCompensationEV = 0; session.params = p
            }
            Divider()
            Button(L(.helpPickNeutral)) { session.wbPickerActive.toggle() }
                .disabled(session.selection == nil)
            // The presets are not in the spec's tables, and their names are
            // closest to profile names — which stay as they are. They are the
            // only rows in this section left in English.
            Menu(L(.helpWhiteBalancePreset)) {
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
///
/// **One view, three rows.** It draws the line under Film Exposure here and
/// under Temperature and Tint in `WhiteBalanceRows`, so its label is one
/// string in all three places: the two white-balance rows cannot say "As
/// Shot" while this one says 拍摄时设置 without a `label:` parameter, which
/// would be a shape change this pass was told not to make. The spec lists
/// "As Shot" once, next to Film Exposure.
struct AsShotLine: View {
    @Binding var isOn: Bool
    var enabled: Bool
    var body: some View {
        HStack(spacing: 3) {
            Text(L(.cameraFilmExposureAsShot)).font(Theme.Font.sublabel).foregroundStyle(Theme.Ink.tertiary)
            CheckBox(isOn: $isOn)
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
