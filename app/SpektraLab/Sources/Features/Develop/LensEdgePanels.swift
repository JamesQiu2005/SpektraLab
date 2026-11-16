//  LensEdgePanels.swift — 冲洗 › 格式 › 效果's 漏光, and 编辑 › 镜头's controls (PRD-D §3.3–§3.4, 2026-11-11).
//
//  - **漏光 Light Leak**, under Format's effects: the kinds as chips — 关 · 自动 · 光带 · 漫光 · 光斑 (光斑 off 120 only on
//    an engine with `leak_seed`) — then **随机 Shuffle** (that engine only: a new seed of the leak's own each press, the
//    kind's and the edge burn's; its context menu, 相机默认, gives the camera's own back), then 强度 Strength,
//    `leak_amount` 0…4; then **边缘漏光 Edge Burn** beside the kind (API-SPEC §21.9, 2026-11-16; an engine with
//    `leak_edge`): its own switch and 强度, `leak_edge` 0…4, on with any kind or with the kind off. Light on the film,
//    with or without a film edge (the leak's wire sends the overscan seeds itself, `FrameEdit.leakWire`); every change
//    re-develops.
//  - **镜头 Lens**, a section of Edit's column (`AdjustTool.lens`): first 镜头校正 Lens Correction, Capture One's
//    (`LensCorrectionPart`, 2.4.0: 配置文件, 隐藏畸变区域, 畸变, 光衰减 and who corrects; a RAW photograph's own), then
//    the vignette, moved from its own tile unchanged (Layer 2, live), then 柔光镜 Soft Filter — 关 · 黑柔 · 白柔 · 闪柔 · 晕柔 and 强度 on its five detents 1/8 … 2 —
//    then, behind `FeatureFlags.lensCharacter` (phase 2), 像差 Character — 关 · 旋焦 · 佩兹伐 · 老镜 · 玩具镜 and 程度.
//    The filter and the character are on the negative and re-develop; the section says nothing about it, and the
//    canvas shows the develop's progress as a Decode change does.
//
//  Each part is shown only on an engine that has its fields (`EngineFeatures.offers`). Every write is one
//  `session.change`, so Undo walks it; a slider's drag is one step (`began`/`ended`). The sliders are the one slider,
//  `ValueSlider` (never a sliding scale).

import SwiftUI

extension OpenFrameSession {
    /// Whether an Edit tool's section holds nothing: Layer 2's part, and 镜头's settings on the negative — and a RAW
    /// photograph's 镜头校正 at its rest (`lensAtRest`).
    func adjustIsAtRest(_ tool: AdjustTool) -> Bool {
        tool.isAtRest(in: adjustments, lens: edit.lens) && (tool != .lens || edit.decode.lensFields == lensRest(edit.decode))
    }

    /// An Edit tool's ↺: Layer 2's part, and for 镜头 its settings on the negative and a RAW photograph's 镜头校正 with
    /// it — one step of Undo.
    func resetAdjust(_ tool: AdjustTool) {
        guard tool == .lens else { changeEdit { tool.reset(&$0) }; return }
        change { e in
            e = e.resetting(.lens)
            e.decode.lensFields = lensRest(e.decode)
        }
    }

    /// 镜头校正 at rest for this frame: a RAW photograph's as a new one arrives (on, automatic, 畸变 100, 光衰减 0, the
    /// distorted areas hidden — `ImportService`); any other frame's as it is (the part is not offered there, so its ↺
    /// leaves it alone).
    func lensRest(_ d: DecodeSettings) -> DecodeSettings.LensFields {
        guard let frame, frame.developsFromRAW, !frame.isComposite else { return d.lensFields }
        return .init(on: true, profile: nil, distortion: DecodeSettings.defaultLensDistortion,
                     lightFalloff: DecodeSettings.defaultLensLightFalloff, hideDistortedAreas: true)
    }
}

/// The column's line of chips, wrapped at its width, as the Gate panel's are.
private struct ChoiceChips<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let selected: Option
    let title: (Option) -> String
    var enabled: (Option) -> Bool = { _ in true }
    let id: (Option) -> String
    let pick: (Option) -> Void

    var body: some View {
        ChipFlow(spacing: 6, lineSpacing: 6) {
            ForEach(options) { o in
                Chip(title: title(o), on: o == selected, height: 26, size: 12, padding: 12, dim: !enabled(o)) { pick(o) }
                    .rowEnabled(enabled(o))
                    .accessibilityIdentifier(id(o))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A part's small heading inside a section: its name and, at the right, what it is set to.
private struct PartHeading: View {
    let title: String
    var value: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.Font.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Text(value).font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

// MARK: - 漏光

struct LeakSection: View {
    let session: OpenFrameSession

    private var edit: FrameEdit { session.edit }
    private var camera: FilmEdgeFormat { edit.leakCamera }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule)
            PartHeading(title: L("Light Leak"), value: note)
            ChoiceChips(options: LeakKind.allCases, selected: edit.leak.kind, title: \.label,
                        enabled: { $0.isMade(on: camera) }, id: { "v5.develop.leak." + $0.rawValue }) { kind in
                guard kind != edit.leak.kind else { return }
                session.change { $0.leak.kind = kind }
            }
            if EngineFeatures.offers(.leakSeed) { shuffle }
            ValueSlider(title: L("Strength", as: "a light leak"),
                        value: Binding(get: { edit.leak.amount }, set: { v in session.change { $0.leak.amount = v } }),
                        range: LeakSettings.amountRange, rest: 1, text: { String(format: "%.2f", $0) },
                        detentAtRest: true, onEditingChanged: session.editing(.shoot))
                .rowEnabled(edit.leak.kind != .off)
                .accessibilityIdentifier("v5.develop.leak.amount")
            if EngineFeatures.offers(.leakEdge) { edgeBurn }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .rowEnabled(edit.appliesFilm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v5.develop.leak")
    }

    /// **边缘漏光 Edge Burn** (API-SPEC §21.9, 2026-11-16): not a kind but its own layer of the leak, so it is a switch
    /// and a strength of its own beside the chips — a band and the burn together, each at its strength, or the burn
    /// with the kind off. The switch brings it on at `edgeRest` (1) and takes it to 0; its slider to 0 is off too. One
    /// step of Undo each, a slider's drag one step.
    private var edgeBurn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("Edge Burn", as: "a light leak")).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                SpkToggle(isOn: Binding(get: { edit.leak.edgeOn }, set: { on in
                    let v = on ? LeakSettings.edgeRest : 0
                    guard v != edit.leak.edge else { return }
                    session.change { $0.leak.edge = v }
                }), size: .compact)
                .accessibilityLabel(L("Edge Burn", as: "a light leak"))
                .accessibilityIdentifier("v5.develop.leak.edge")
            }
            .frame(minHeight: 26)
            ValueSlider(title: L("Strength", as: "a light leak"),
                        value: Binding(get: { edit.leak.edge }, set: { v in session.change { $0.leak.edge = v } }),
                        range: LeakSettings.edgeRange, rest: LeakSettings.edgeRest, text: { String(format: "%.2f", $0) },
                        detentAtRest: true, onEditingChanged: session.editing(.shoot))
                .rowEnabled(edit.leak.edgeOn)
                .accessibilityIdentifier("v5.develop.leak.edgeAmount")
        }
    }

    /// What the heading says at its right: why the chosen kind is not drawn, else nothing.
    private var note: String { edit.leak.kind.reason(on: camera) ?? "" }

    /// 随机 (API-SPEC §21.8): one button with Apple's `dice`, in the pill the Film Edge's dice wear
    /// (`DicePill`, private to FilmEdgeSteps.swift, draws its own glyph; its look is matched here). Each press draws a
    /// new non-zero seed — another place, edge and shape for this kind, and another edge burn — and develops again; one
    /// step of Undo. Greyed while 关 with the edge burn off too (the whole section greys with the film off). Its context menu: 相机默认, the camera's own leak (seed 0)
    /// again — the Mac's long-press.
    private var shuffle: some View {
        let on = edit.leak.isOn
        return HStack(spacing: 8) {
            Button {
                guard edit.leak.isOn else { return }
                let next = LeakSettings.drawSeed(other: edit.leak.seed)
                session.change { $0.leak.seed = next }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dice").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 16, height: 16)
                    Text(L("Shuffle", as: "a light leak")).font(Theme.Font.ui(12.5)).foregroundStyle(Theme.secondaryText)
                        .lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Theme.card))
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .contextMenu {
                Button {
                    guard edit.leak.seed != 0 else { return }
                    session.change { $0.leak.seed = 0 }
                } label: { Label(L("Camera's Own", as: "a light leak"), systemImage: "camera") }
                    .disabled(edit.leak.seed == 0)
                    .accessibilityIdentifier("v5.develop.leak.cameraOwn")
            }
            .accessibilityIdentifier("v5.develop.leak.shuffle")
            Spacer(minLength: 0)
        }
        .rowEnabled(on)
        .disabled(!on)
    }
}

// MARK: - 镜头

/// Edit's 镜头 section: 镜头校正, the vignette, the soft filter, and (phase 2) the lens's character.
struct LensControls: View {
    let session: OpenFrameSession

    private var lens: LensSettings { session.edit.lens }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LensCorrectionPart(session: session)
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.top, 2)
            PartHeading(title: L("Vignette"))
            AdjustSliders(session: session, tool: .lens)
            if EngineFeatures.offers(.softFilter) { softFilter }
            if EngineFeatures.offers(.lensCharacter) { character }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adjust.lens")
    }

    // 柔光镜: Off and the four families, then the grade on its five detents.
    private var softFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.top, 2)
            PartHeading(title: L("Soft Filter"))
            ChoiceChips(options: [Choice<SoftFilter>.off] + SoftFilter.allCases.map(Choice.on), selected: Choice(lens.filter),
                        title: { $0.value?.label ?? L("Off") }, id: { "adjust.lens.filter." + ($0.value?.rawValue ?? "off") }) { c in
                guard c.value != lens.filter else { return }
                session.change { $0.lens.filter = c.value }
            }
            // The detents are powers of two, so the track is laid in stops of the grade: a step is one detent.
            ValueSlider(title: L("Strength", as: "a soft filter"),
                        value: Binding(get: { log2(max(lens.strength, 0.125)) },
                                       set: { x in session.change { $0.lens.strength = pow(2, x.rounded().clamped(to: -3...1)) } }),
                        range: -3...1, rest: log2(SoftFilter.defaultStrength), step: 1,
                        text: { SoftFilter.strengthText(pow(2, $0.rounded())) }, detentAtRest: true,
                        onEditingChanged: session.editing(.shoot))
                .rowEnabled(lens.filter != nil)
                .accessibilityIdentifier("adjust.lens.strength")
        }
    }

    // 像差 (phase 2): Off and the four named lenses, then how much of the lens.
    private var character: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.top, 2)
            PartHeading(title: L("Character", as: "a lens"))
            ChoiceChips(options: [Choice<LensCharacter>.off] + LensCharacter.allCases.map(Choice.on), selected: Choice(lens.character),
                        title: { $0.value?.label ?? L("Off") }, id: { "adjust.lens.character." + ($0.value?.rawValue ?? "off") }) { c in
                guard c.value != lens.character else { return }
                session.change { $0.lens.character = c.value }
            }
            ValueSlider(title: L("Amount", as: "a lens"),
                        value: Binding(get: { lens.amount * 100 }, set: { v in session.change { $0.lens.amount = (v / 100).clamped(to: 0...1) } }),
                        range: 0...100, rest: 100, text: { String(format: "%.0f %%", $0) }, detentAtRest: true,
                        onEditingChanged: session.editing(.shoot))
                .rowEnabled(lens.character != nil)
                .accessibilityIdentifier("adjust.lens.amount")
        }
    }
}

/// An optional choice as one of a row's chips: Off, or a value.
private struct Choice<Value: Hashable>: Hashable, Identifiable {
    let value: Value?
    init(_ value: Value?) { self.value = value }
    static var off: Choice { Choice(nil) }
    static func on(_ v: Value) -> Choice { Choice(v) }
    var id: Self { self }
}
