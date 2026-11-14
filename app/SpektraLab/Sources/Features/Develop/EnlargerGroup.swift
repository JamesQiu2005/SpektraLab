//  EnlargerGroup.swift — 解码 › 放大机 (Enlarger): the print's Brightness, Yellow, Magenta and Pre-flash.
//
//  The owner, 2026-11-10: "add back the enlarger effects, place them under 解码, and include the old brightness,
//  Yellow, Magenta, and Preflash". The four are 1.x's enlarger and the compact layout's Print tab (`PrintPanel`,
//  `EnlargerTool`), which the Mac's column never showed. Here they are one folding group in Decode, beside
//  高动态范围, each a `ValueSlider` (the one slider, memory `sliders-capture-one-row`), at the ranges `PrintPanel`'s rulers
//  measured:
//  - **Brightness**, −3…+3 stops: the enlarger's exposure, a reprint of the same negative.
//  - **Yellow** and **Magenta**, −1…+1: the head's filtration. A negative prints the other way round, so each
//    slider says where it takes the picture (`EnlargerScales`: → blue, → green; on the silver paper → softer,
//    → harder, and the tracks are plain).
//  - **Pre-flash**, 0…0.2 of the wire's 0…1 (`FilmParams.preflashMax`; 1.x's was 0…0.03), shown as 0…1.
//
//  All four are the print's: they stand down, with the reason, where nothing is printed — film emulation off, a
//  slide, a scanned film (No Print Profile), a Digital Intermediate. On a half-frame pair they are the picked
//  layer's, through the piece (`PrintPanel.enlarger`'s rule). Undo is the page's. Copy Settings already carries
//  them: 暗房 (Darkroom) is `.enlarger`, `.couplers` and `.preflash` (`PresetSheet`).

import SwiftUI

struct EnlargerGroup: View {
    let session: OpenFrameSession
    @Environment(AppServices.self) private var model
    private var prefs: DevelopPanelPrefs { .shared }

    private var edit: FrameEdit { session.edit }
    private var params: FilmParams { edit.params }

    private var pair: HalfFramePair? { FeatureFlags.halfFramePair ? session.pair : nil }
    private var trim: HalfFramePair.PrintTrim { pair?.trim(on: session.layer, look: params) ?? HalfFramePair.PrintTrim(params) }

    /// `PrintPanel`'s scale tints (`PrintPanel.yellowScale`, `magentaScale`): where each slider takes the picture.
    private static let yellowScale = (0xE3C25A as UInt32, 0x5F86C9 as UInt32)
    private static let magentaScale = (0xC86FB5 as UInt32, 0x6FBF73 as UInt32)

    /// Why the enlarger stands down, or nil where a print is made.
    private var reason: String? {
        let catalog = StockCatalog.shared
        if !edit.appliesFilm { return L("Off with film emulation off") }
        if params.digitalIntermediate { return L("A Digital Intermediate is not printed") }
        if catalog.isScanned(params) { return L("A scanned film is not printed") }
        return nil
    }

    /// Any of the four off its rest.
    private var moved: Bool {
        let t = trim
        return t.brightnessStops != 0 || t.yFilterShift != 0 || t.mFilterShift != 0 || t.preflashExposure != 0
    }

    var body: some View {
        let scales = EnlargerScales.of(params)
        VStack(spacing: 0) {
            title
            if !prefs.enlargerCollapsed {
                if let reason {
                    Text(reason).font(Theme.Font.ui(11)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 4)
                }
                Group {
                    row(L("Brightness"), field: .brightness, path: \.params.printBrightnessStops, range: -3...3, step: 0.1,
                        sub: L("stops"), text: { Fmt.signed($0, decimals: 1) }, id: "brightness")
                    row(L("Yellow"), field: .yellow, path: \.params.yFilterShift, range: -1...1, step: 0.01,
                        sub: scales.yellow, text: { Fmt.signed($0, decimals: 2) }, id: "yellow",
                        tint: scales.tinted ? { Color.lerp(Self.yellowScale.0, Self.yellowScale.1, $0) } : nil)
                    row(L("Magenta"), field: .magenta, path: \.params.mFilterShift, range: -1...1, step: 0.01,
                        sub: scales.magenta, text: { Fmt.signed($0, decimals: 2) }, id: "magenta",
                        tint: scales.tinted ? { Color.lerp(Self.magentaScale.0, Self.magentaScale.1, $0) } : nil)
                    // Shown 0…1: the wire's 0…preflashMax, scaled at the binding (the stored value is the wire's).
                    row(L("Pre-flash"), field: .preflash, path: \.params.preflashExposure, range: 0...1, step: 0.01,
                        sub: nil, text: { String(format: "%.2f", $0) }, id: "preflash", scale: FilmParams.preflashMax)
                }
                .rowEnabled(reason == nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v5.develop.enlarger-group")
    }

    private func row(_ name: String, field: PrintField, path: WritableKeyPath<FrameEdit, Double>, range: ClosedRange<Double>,
                     step: Double, sub: String?, text: @escaping (Double) -> String, id: String,
                     tint: ((Double) -> Color)? = nil, scale: Double = 1) -> some View {
        let stored = binding(field, path)
        let shown = scale == 1 ? stored : Binding(get: { stored.wrappedValue / scale }, set: { stored.wrappedValue = $0 * scale })
        return ValueSlider(title: name, value: shown, range: range, rest: 0, step: step, text: text, sub: sub,
                    tint: tint, detentAtRest: true, labelWidth: HighDynamicRangeGroup.labelWidth(name),
                    onEditingChanged: session.editing(.print))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .accessibilityIdentifier("v5.develop.enlarger." + id)
    }

    /// A photograph's own value, or on a pair the picked layer's, through the piece (`PrintPanel.enlarger`).
    private func binding(_ field: PrintField, _ path: WritableKeyPath<FrameEdit, Double>) -> Binding<Double> {
        guard pair != nil else { return session.binding(path) }
        let id = session.frameID
        return Binding(get: { session.pair?.trim(on: session.layer, look: session.edit.params)[field] ?? session.edit[keyPath: path] },
                       set: { v in model.changePair(id) { piece, look in piece.print(field, v, on: session.layer, look: &look.params) } })
    }

    /// The group's fold and its ↺: Decode's folding header, a step in (its chevron under Decode's name), as
    /// 高动态范围's.
    private var title: some View {
        ColumnSectionHeader(title: L("Enlarger"), folded: prefs.enlargerCollapsed, id: "enlarger",
                            rule: false, indent: HighDynamicRangeGroup.indent,
                            toggleFold: { prefs.enlargerCollapsed.toggle() }) {
            RoundButton(diameter: 22, label: L("Reset") + " " + L("Enlarger"), action: {
                model.resetPage(.enlarger, in: session)
                model.resetPage(.preflash, in: session)
            }) {
                Icon(.reset, size: 13)
            }
            .rowEnabled(reason == nil && moved)
            .accessibilityIdentifier("v5.develop.enlarger.reset")
        }
    }
}
