//  WatermarkPage.swift — a watermark layer's own page: the column under the 图层 panel while a watermark's row is
//  picked, the same in 冲洗 and 编辑 (PRD-8 §4.2).
//
//  From the top: **the mark** — the library's marks on the checkerboard, the placement's own lit; a click puts another
//  mark in this placement (its place, size, turn and opacity kept), and 管理水印… opens Settings › Watermarks. A mark the
//  library no longer has says so here. **不透明度** 0–100 % (a drag is one step). **叠加于** 成片 · 底片, two cards:
//  底片 lays the mark into the source before the film (`WatermarkBase.swift`), its numbers converted so it keeps its place
//  on screen (`OpenFrameSession.switchWatermarkStage`); with Apply Film Emulation off a 底片 mark is drawn as 成片 (N9),
//  and the page says that. **Size** (of the short side, %) and
//  **Rotation** (°), typed. **删除**. **填充** under 不透明度: 原样 or one colour (`WatermarkFill`). Every change is one step of Undo, named by the history.

import SwiftUI
import UIKit

struct WatermarkPage: View {
    let session: OpenFrameSession
    let placement: WatermarkPlacement
    @Environment(AppServices.self) private var model
    @State private var dragging = false

    private var store: WatermarkStore { model.watermarks }
    private var gone: Bool { store.mark(placement.mark) == nil }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                marks
                FoldRule()
                opacity
                FoldRule()
                fill
                FoldRule()
                stage
                FoldRule()
                numbers
                FoldRule()
                CapsuleButton(title: L("Delete Watermark"), primary: false, height: 30) { session.removeWatermark(placement.id) }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .accessibilityIdentifier("layers.page.watermark.delete")
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("layers.page")
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.Font.ui(11.5, .regular)).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: the mark

    private var marks: some View {
        VStack(alignment: .leading, spacing: 8) {
            title(L("Watermark"))
            if gone { note(L("This watermark’s PNG is no longer in Settings › Watermarks: nothing is drawn for it.")) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(store.marks) { mark in
                    let on = mark.id == placement.mark
                    Button {
                        session.changeWatermark(placement.id) { $0.mark = mark.id }
                    } label: {
                        WatermarkThumbnail(mark: mark.id, cell: 4)
                            .frame(height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(on ? Theme.accent : Theme.rule, lineWidth: on ? 2 : 0.5))
                    }
                    .buttonStyle(PressStyle())
                    .help(mark.name)
                    .accessibilityLabel(mark.name)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
                Button { WatermarkAddDisc.openSettings(model) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        Text(L("Manage…")).font(Theme.Font.ui(10.5, .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L("Manage Watermarks…"))
                .accessibilityHint(L("Opens Settings › Watermarks"))
                .accessibilityIdentifier("layers.page.watermark.manage")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: 不透明度

    private var opacity: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(L("Opacity")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                .frame(width: 64, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { session.changeWatermark(placement.id) { $0.opacity = 1 } }
            SliderTrack(value: Binding(get: { placement.opacity }, set: { v in session.moveWatermark(placement.id) { $0.opacity = v } }),
                        range: 0...1, rest: 1, step: 0.01, detentAtRest: false, showsRest: false,
                        onEditingChanged: { down in
                            guard down != dragging else { return }
                            dragging = down
                            down ? session.beganWatermark() : session.endedWatermark()
                        })
                .frame(height: 28)
            SliderField(shown: "\(Int((placement.opacity * 100).rounded())) %", width: 62,
                        parse: { SliderField.number(from: $0.replacingOccurrences(of: "%", with: "")).map { $0 / 100 } },
                        commit: { v in session.changeWatermark(placement.id) { $0.opacity = v.clamped(to: 0...1) } })
        }
        .padding(.horizontal, 16).frame(height: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Opacity"))
        .accessibilityValue("\(Int((placement.opacity * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            let v = (placement.opacity + (direction == .increment ? 0.05 : -0.05)).clamped(to: 0...1)
            session.changeWatermark(placement.id) { $0.opacity = v }
        }
        .accessibilityIdentifier("layers.page.watermark.opacity")
    }

    // MARK: 填充

    /// **填充** (the owner, 2026-11-16: "native style or new filled color"): 原样 draws the PNG's own colours; a swatch or
    /// the picker fills the mark's alpha with one colour (`WatermarkFill`). A click is one step; the picker's drag is one
    /// step from its first colour to a rest of `pickerRest` (a gesture, as a drag on the canvas is: a 底片 mark is drawn
    /// live meanwhile and developed in the colour at the rest).
    private var fill: some View {
        VStack(alignment: .leading, spacing: 8) {
            title(L("Fill", as: "a watermark's colour"))
            HStack(spacing: 6) {
                Button { session.changeWatermark(placement.id) { $0.fill = nil } } label: {
                    Text(L("Native", as: "a watermark's own colours")).font(Theme.Font.ui(12.5, placement.fill == nil ? .semibold : .medium))
                        .foregroundStyle(placement.fill == nil ? Theme.onSelection : Theme.text)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(placement.fill == nil ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L("Native", as: "a watermark's own colours"))
                .accessibilityAddTraits(placement.fill == nil ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("layers.page.watermark.fill.native")
                ForEach(WatermarkFill.swatches, id: \.self) { word in
                    let on = placement.fill == word
                    Button { session.changeWatermark(placement.id) { $0.fill = word } } label: {
                        Circle().fill(Self.colour(word))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 0.5))
                            .padding(2)
                            .overlay(Circle().strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(PressStyle())
                    .help(word)
                    .accessibilityLabel(L("Fill colour \(word)"))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
                ColorPicker(L("Fill colour"), selection: Binding(get: { Self.colour(placement.fill ?? "#FFFFFF") },
                                                                set: { pick($0) }), supportsOpacity: false)
                    .labelsHidden()
                    .help(L("Another colour…"))
                    .accessibilityIdentifier("layers.page.watermark.fill.picker")
            }
            note(placement.fill == nil ? L("Native: the PNG’s own colours.")
                                       : L("Filled: the watermark’s shape in one colour, its own transparency kept."))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// A fill's word as a colour to draw (sRGB).
    static func colour(_ word: String) -> Color {
        guard let (r, g, b) = WatermarkFill.rgb(word) else { return .white }
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// How long the picker rests before its colour is one step.
    static let pickerRest: Duration = .milliseconds(600)

    /// The picker moved: the mark drawn live in the colour, one step at its rest.
    private func pick(_ colour: Color) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(colour).resolvedColor(with: UITraitCollection.current).getRed(&r, green: &g, blue: &b, alpha: &a)
        // `getRed` answers in extended sRGB: held to sRGB's own range, as the word is.
        let word = WatermarkFill.word(r: Double(r), g: Double(g), b: Double(b))
        guard word != placement.fill else { return }
        if session.movingMarks == nil { session.beganWatermark() }
        session.moveWatermark(placement.id) { $0.fill = word }
        WatermarkPickerRest.shared.restart(after: Self.pickerRest) { [session] in session.endedWatermark() }
    }

    // MARK: 叠加于

    private var stage: some View {
        VStack(alignment: .leading, spacing: 8) {
            title(L("Over", as: "a watermark laid over"))
            HStack(spacing: 8) {
                card(.full, enabled: true)
                card(.base, enabled: true)
            }
            note(placement.stage == .full ? L("Full image: over the finished picture, untouched by the film.")
                                          : L("Base: under the film; grain, halation and colour go over it."))
            if placement.stage == .base, !session.edit.appliesFilm {
                note(L("Apply Film Emulation is off: Base works as Full image."))
            }
            // A film edge (the owner, 2026-11-16: "printed on film edges, not limited to the image only"): 成片's canvas is
            // the whole film, rebate and edge print included; 底片 is laid into the picture the engine is handed, inside it.
            if placement.stage == .base, session.edit.appliesFilm, session.edit.filmEdge.effective {
                note(L("Base stays on the picture, inside the film edge. To put the watermark on the film edge, choose Full image."))
            } else if placement.stage == .full, session.edit.filmEdge.effective {
                note(L("Full image covers the whole film: the watermark can sit on the film edge."))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func card(_ s: WatermarkStage, enabled: Bool) -> some View {
        let on = placement.stage == s
        return Button { session.switchWatermarkStage(placement.id, to: s) } label: {
            Text(s.label).font(Theme.Font.ui(12.5, on ? .semibold : .medium))
                .foregroundStyle(on ? Theme.onSelection : Theme.text)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(on ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.disabledOpacity)
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("layers.page.watermark.stage.\(s.rawValue)")
    }

    // MARK: size and turn

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Size")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text).frame(width: 64, alignment: .leading)
                SliderField(shown: String(format: "%.1f %%", placement.size * 100), width: 72,
                            parse: { SliderField.number(from: $0.replacingOccurrences(of: "%", with: "")).map { $0 / 100 } },
                            commit: { v in setSize(v) })
                    .accessibilityLabel(L("Size"))
                Spacer(minLength: 8)
                Text(L("Rotation")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                SliderField(shown: String(format: "%.1f°", WatermarkGeometry.degrees(placement.rotation)), width: 64,
                            parse: { SliderField.number(from: $0.replacingOccurrences(of: "°", with: "")) },
                            commit: { v in setTurn(v) })
                    .accessibilityLabel(L("Rotation"))
            }
            note(L("Size is a share of the picture’s short side. Drag the watermark on the picture, its corners to size it, the dot above it to turn it."))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The canvas the placement is measured on (the 底片 one for a 底片 mark, the film on).
    private var canvas: CGSize { session.markCanvas(placement) }
    private var aspect: Double {
        guard let i = store.info(placement.mark), i.w > 0, i.h > 0 else { return 1 }
        return Double(i.w) / Double(i.h)
    }

    private func setSize(_ v: Double) {
        let canvas = canvas, aspect = aspect
        session.changeWatermark(placement.id) { p in
            p.size = min(max(v, WatermarkGeometry.minSize), WatermarkGeometry.maxSize(canvas: canvas, aspect: aspect))
            p = WatermarkGeometry.settled(p, canvas: canvas, aspect: aspect)
        }
    }

    private func setTurn(_ degrees: Double) {
        let canvas = canvas, aspect = aspect
        session.changeWatermark(placement.id) { p in
            p.rotation = WatermarkGeometry.normalised(degrees * .pi / 180)
            p = WatermarkGeometry.settled(p, canvas: canvas, aspect: aspect)
        }
    }
}

/// The colour picker's rest: one timer for the page, restarted at each colour (`WatermarkPage.pick`).
@MainActor
final class WatermarkPickerRest {
    static let shared = WatermarkPickerRest()
    private var task: Task<Void, Never>?
    func restart(after rest: Duration, _ done: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: rest)
            guard !Task.isCancelled else { return }
            done()
        }
    }
}
