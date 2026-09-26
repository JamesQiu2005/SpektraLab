//  ParameterSections.swift — the Pre-Dev tab's three sections after Latitude
//  and Camera: Film Format, Scene Placement and the Tone Mask (v4).
//
//  All three sit on the Parameters rail's one grid (`SliderMetrics.parameters`
//  through `\.railSliderMetrics`, `Theme.Metric.parameterLabelWidth` for the
//  pills and toggles), so a strength, a pull-back and a mask amount start
//  their tracks on the same line as Film Exposure.

import SwiftUI

// MARK: - Film Format

/// The physical frame and the effects that scale with it. It was the lower
/// half of the Film section; v4 moves it to Pre-Dev beside Camera, and keeps
/// the decoupled strengths here (RFC-025).
///
/// **The frame, and why it is three controls.** The engine takes one number,
/// `film_format_mm`, the frame's long edge. One number cannot tell 645 from
/// 6×6, so the user says a type, a side and a length, and
/// `Session.filmFormatMM(side:sideLengthMM:aspect:)` derives the long edge.
/// Side Length is greyed unless the type is Custom.
struct FilmFormatSection: View {
    @Bindable var session: Session
    @AppStorage(Session.uiKey + "sideUnit") private var unitRaw = SideUnit.mm.rawValue
    @AppStorage(Session.decoupleEffectsKey) private var decoupleEffects = false

    private var unit: Binding<SideUnit> {
        Binding(get: { SideUnit(rawValue: unitRaw) ?? .mm }, set: { unitRaw = $0.rawValue })
    }
    private var isCustom: Bool { session.params.filmFrame == FilmFrame.custom.id }
    private var width: CGFloat { Theme.Metric.parameterLabelWidth }

    var body: some View {
        PanelSection(L(.filmFormat), key: "filmFormat",
                     action: SectionAction(help: L(.helpResetFilmFormat)) { reset() },
                     menu: { AnyView(menu) }) {
            RailRows {
                PillMenu(label: L(.filmFormatSize), options: FilmFrame.all, title: { $0.id },
                         selection: Binding(get: { session.filmFrame }, set: { session.setFilmFrame($0) }),
                         labelWidth: width, fill: false, trailingBadge: { $0.isCine })
                PillMenu(label: L(.filmFormatSide), options: FilmSide.allCases, title: { L($0.key) },
                         selection: Binding(get: { session.filmSide }, set: { session.setFilmSide($0) }),
                         labelWidth: width, fill: false)
                UnitField(label: L(.filmFormatSideLength),
                          value: Binding(get: { session.params.sideLengthMM },
                                         set: { session.setSideLengthMM($0) }),
                          unit: unit, enabled: isCustom, reason: L(.reasonNonCustomSideLength),
                          labelWidth: width)
                if decoupleEffects { decoupled } else { coupled }
            }
        }
    }

    @ViewBuilder private var coupled: some View {
        ToggleRow(label: L(.filmGrain), isOn: param(\.grainActive))
        ToggleRow(label: L(.filmHalation), isOn: param(\.halationActive))
        ToggleRow(label: L(.filmGlare), isOn: param(\.glareActive),
                  enabled: session.params.printEffects, reason: L(.reasonPrintEffectsOff))
    }

    /// RFC-025's rows, named as v4 draws them. A strength greys, rather than
    /// hides, while its effect is off: the value is still the frame's.
    @ViewBuilder private var decoupled: some View {
        let p = session.params
        ToggleRow(label: L(.filmGrain), isOn: param(\.grainActive))
        strength(L(.filmGrainStrength), \.grain, EffectStrengths.grainRange, enabled: p.grainActive)
        ToggleRow(label: L(.filmHalation), isOn: param(\.halationActive))
        strength(L(.filmHalationStrength), \.halation, EffectStrengths.halationRange, enabled: p.halationActive)
        strength(L(.filmScatterStrength), \.scatter, EffectStrengths.scatterRange, enabled: p.halationActive)
        ToggleRow(label: L(.filmCouplers), isOn: effect(\.couplersActive))
        strength(L(.filmCouplersStrength), \.couplers, EffectStrengths.couplersRange,
                 enabled: p.effects.couplersActive)
        ToggleRow(label: L(.filmGlare), isOn: param(\.glareActive),
                  enabled: p.printEffects, reason: L(.reasonPrintEffectsOff))
        strength(L(.filmGlareStrength), \.glare, EffectStrengths.glareRange,
                 enabled: p.glareActive && p.printEffects)
    }

    /// A multiple of what the film does, so its neutral is 1: the zero tick
    /// sits there and a double-click returns to it.
    private func strength(_ label: String, _ kp: WritableKeyPath<EffectStrengths, Double>,
                          _ range: ClosedRange<Double>, enabled: Bool) -> some View {
        ScrubSlider(label: label, value: effect(kp), range: range, zero: 1, snap: 0.25,
                    format: { String(format: "%.2f", $0) }, disabled: !enabled)
    }

    private func param(_ kp: WritableKeyPath<FilmParams, Bool>) -> Binding<Bool> {
        Binding(get: { session.params[keyPath: kp] },
                set: { var p = session.params; p[keyPath: kp] = $0; session.params = p })
    }

    private func effect<V>(_ kp: WritableKeyPath<EffectStrengths, V>) -> Binding<V> {
        Binding(get: { session.params.effects[keyPath: kp] },
                set: { var p = session.params; p.effects[keyPath: kp] = $0; session.params = p })
    }

    private func reset() {
        session.setFilmFrame(FilmFrame.all.first { $0.id == "135" } ?? session.filmFrame)
        session.setFilmSide(.short)
        var p = session.params
        p.grainActive = true; p.halationActive = true; p.glareActive = true
        p.effects = .default
        session.params = p
    }

    private var menu: some View {
        Group {
            Button(L(.helpAllEffectsOn)) {
                var p = session.params
                p.grainActive = true; p.halationActive = true; p.glareActive = true
                session.params = p
            }
            Button(L(.helpAllEffectsOff)) {
                var p = session.params
                p.grainActive = false; p.halationActive = false; p.glareActive = false
                session.params = p
            }
            // Offered whenever a frame carries strengths, shown or not: with
            // the sliders hidden this is the only way to see there is
            // something to reset, and the only way to reset it.
            if decoupleEffects || !session.params.effects.isDefault {
                Button(L(.helpResetEffectStrengths)) {
                    var p = session.params; p.effects = .default; session.params = p
                }
                .disabled(session.params.effects.isDefault)
            }
            if decoupleEffects {
                Divider()
                // A model choice, not a strength, so it is a menu check rather
                // than a row: the sub-layer model against the single-layer one.
                Toggle(L(.helpSubLayerGrain), isOn: effect(\.grainLayered))
                    .disabled(!session.params.grainActive)
            }
        }
    }
}

// MARK: - Scene Placement

/// RFC-023's pull-backs: how many stops the scene's top and bottom are drawn
/// in toward the medium before the film sees them. The Latitude graph above
/// shows where they land.
///
/// **Every value goes through the Fit.** Below the Fit's minimum the extreme
/// would still land past the print, and the engine refuses it; that span is
/// drawn dimmed on the track, and a value dragged into it is not committed —
/// the row says why, in the engine's words, and the slider returns to the last
/// accepted value on release.
struct ScenePlacementSection: View {
    @Bindable var session: Session
    /// The value under the pointer while a drag is in progress. Nil at rest,
    /// when the slider shows what is committed.
    @State private var dragging: (highlight: Double?, shadow: Double?) = (nil, nil)

    static let range: ClosedRange<Double> = 0...8

    private var developed: Bool { session.latitude.reply != nil && session.latitude.frame == session.selection }

    var body: some View {
        PanelSection(L(.sectionScenePlacement), key: "scenePlacement",
                     action: SectionAction(help: L(.helpResetPlacement),
                                           enabled: session.params.sceneLatitude.active) {
                         dragging = (nil, nil); session.resetScenePlacement()
                     }) {
            RailRows {
                row(L(.placementHighlight), side: "highlight",
                    committed: session.params.sceneLatitude.highlightPullBack,
                    minimum: session.latitude.reply?.fit.highlight.minimumPullBack,
                    shown: dragging.highlight) { v in
                    dragging.highlight = v
                    session.placeScene(highlight: v, shadow: dragging.shadow ?? session.params.sceneLatitude.shadowPullBack)
                } end: { dragging.highlight = nil }
                row(L(.placementShadow), side: "shadow",
                    committed: session.params.sceneLatitude.shadowPullBack,
                    minimum: session.latitude.reply?.fit.shadow.minimumPullBack,
                    shown: dragging.shadow) { v in
                    dragging.shadow = v
                    session.placeScene(highlight: dragging.highlight ?? session.params.sceneLatitude.highlightPullBack, shadow: v)
                } end: { dragging.shadow = nil }
            }
            .rowEnabled(developed, because: L(.reasonNotDeveloped))
        }
    }

    private func row(_ label: String, side: String, committed: Double, minimum: Double?, shown: Double?,
                     set: @escaping (Double) -> Void, end: @escaping () -> Void) -> some View {
        let blocked: ClosedRange<Double>? = (minimum ?? 0) > 0 ? 0...(minimum ?? 0) : nil
        return ScrubSlider(label: label,
                           sublabel: session.latitude.refusalMessage(for: side),
                           value: Binding(get: { shown ?? committed }, set: set),
                           range: Self.range, zero: 0, snap: 0.25,
                           format: { String(format: "%.2f", $0) },
                           blocked: blocked, onCommit: end)
    }
}

// MARK: - Tone Mask

/// RFC-024's virtual contrast mask, as the engine computes it: **global**.
/// One Gaussian base over the whole frame's paper exposure (Radius, a fraction
/// of the long edge), then one curve from that base to a change in exposure —
/// Highlights lifts the regions the paper would print light, Shadows holds
/// back the dark ones, and Core is the span about mid-grey left alone. The
/// curve under the sliders is that curve (`ToneMaskCurve`), so what it shows is
/// the mask itself; the picture only decides where each region sits on it.
///
/// A print edit: it reprints the cached negative. Greyed with the reason while
/// Print Effects is off, because the wire does not carry it then.
struct ToneMaskSection: View {
    @Bindable var session: Session

    private var mask: ContrastMaskSettings { session.params.contrastMask }
    private var allowed: Bool { session.params.printEffects }

    var body: some View {
        PanelSection(L(.sectionToneMask), key: "toneMask",
                     action: SectionAction(help: L(.helpResetToneMask),
                                           enabled: mask != ContrastMaskSettings()) {
                         var p = session.params; p.contrastMask = ContrastMaskSettings(); session.params = p
                     }) {
            RailRows {
                ToggleRow(label: L(.maskEnable), isOn: bind(\.active),
                          enabled: allowed, reason: L(.reasonPrintEffectsOff))
                Group {
                    ScrubSlider(label: L(.maskHighlights), value: bind(\.highlights), range: 0...3, snap: 0.25,
                                format: { String(format: "%.2f", $0) })
                    ScrubSlider(label: L(.maskShadows), value: bind(\.shadows), range: 0...3, snap: 0.25,
                                format: { String(format: "%.2f", $0) })
                    ScrubSlider(label: L(.maskCore), value: bind(\.core), range: 0...3, zero: 1, snap: 0.25,
                                format: { String(format: "%.2f", $0) })
                    // The wire's scale is a fraction of the long edge; a
                    // percentage of it is the same number a person can picture.
                    ScrubSlider(label: L(.maskRadius),
                                value: Binding(get: { mask.scale * 100 },
                                               set: { v in var p = session.params
                                                   p.contrastMask.scale = (v / 100).clamped(to: ContrastMaskSettings.scaleRange)
                                                   session.params = p }),
                                range: ContrastMaskSettings.scaleRange.lowerBound * 100...ContrastMaskSettings.scaleRange.upperBound * 100,
                                zero: 3, snap: 0.5, format: { String(format: "%.1f %%", $0) })
                    ToneMaskPlot(mask: mask)
                        .frame(height: Theme.Metric.maskPlotHeight)
                        .padding(.top, 2)
                    Text(L(.maskCurveCaption))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .rowEnabled(allowed && mask.active,
                            because: allowed ? "" : L(.reasonPrintEffectsOff))
            }
        }
    }

    private func bind<V>(_ kp: WritableKeyPath<ContrastMaskSettings, V>) -> Binding<V> {
        Binding(get: { session.params.contrastMask[keyPath: kp] },
                set: { var p = session.params; p.contrastMask[keyPath: kp] = $0; session.params = p })
    }
}

/// The mask's curve: x the blurred negative's exposure on the paper, stops
/// from mid-grey; y the change the mask makes there. The core is shaded.
struct ToneMaskPlot: View {
    let mask: ContrastMaskSettings
    static let x: ClosedRange<Double> = -6...6
    static let y: ClosedRange<Double> = -3...3

    var body: some View {
        Canvas { ctx, size in
            func px(_ v: Double) -> CGFloat { CGFloat((v - Self.x.lowerBound) / (Self.x.upperBound - Self.x.lowerBound)) * size.width }
            func py(_ v: Double) -> CGFloat { CGFloat((Self.y.upperBound - v) / (Self.y.upperBound - Self.y.lowerBound)) * size.height }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(Theme.plot))
            let core = CGRect(x: px(-mask.core), y: 0, width: px(mask.core) - px(-mask.core), height: size.height)
            ctx.fill(Path(core), with: .color(Theme.plotGrid.opacity(0.6)))
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: py(0))); zero.addLine(to: CGPoint(x: size.width, y: py(0)))
            ctx.stroke(zero, with: .color(Theme.plotMidGrey), lineWidth: 0.5)
            var mid = Path(); mid.move(to: CGPoint(x: px(0), y: 0)); mid.addLine(to: CGPoint(x: px(0), y: size.height))
            ctx.stroke(mid, with: .color(Theme.plotMidGrey), lineWidth: 0.5)
            var curve = Path()
            let n = 120
            for i in 0...n {
                let b = Self.x.lowerBound + (Self.x.upperBound - Self.x.lowerBound) * Double(i) / Double(n)
                let p = CGPoint(x: px(b), y: py(ToneMaskCurve.delta(atBase: b, mask).clamped(to: Self.y)))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(Theme.text), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}
