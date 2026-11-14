//  MaskRows.swift — a single photograph's mask layers in the 图层 panel (design/masks/MASKS-SPEC.md §2–§4, §7, §9;
//  drawings 01, 12, 13, 15, 16, 18): the head's + − ⋯, the selection row (主体 · 背景 · 人) and the tool row (画笔,
//  线性渐变, 径向渐变, 橡皮), a mask layer's row, 不透明度 where a double's Balance sits, and 组合蒙版 · 完善蒙版….
//
//  A tool's slot lights it (`MaskTools`), the pill at the row's leading end says the lit tool and opens its settings
//  (`MaskPopovers.swift`), and the picture takes the strokes and the drags (`MaskStage.swift`). 主体 · 背景 · 人 ask
//  `SubjectFinder` through `MaskFinding` (正在查找 at the button's own width while it looks; 人's menu); 组合蒙版 and
//  完善蒙版… open their popovers (`MaskCombinePopover`, `MaskRefinePopover`).
//  The rows, the eye, 不透明度, + and − and the layer's menu are real: they act on the edit (`OpenFrameSession`'s
//  layer acts), and every one is one step of Undo.

import Metal
import SwiftUI
import UIKit

// MARK: - a mask's thumbnail

/// The rows' thumbnails: each layer's mask white on black, baked small by the same baker the develop's planes are
/// (`MaskBaker`, at a 60 px long edge — 2x the 30 × 20 slot) and kept by what it is made of (`MaskBaker.planeKey`), so a
/// rename, an opacity or a delta draws no new one. A mask that cannot be baked (a found part whose picture is not
/// here: M1c's) is drawn black, as an empty one is.
@MainActor @Observable
final class MaskThumbnails {
    static let shared = MaskThumbnails()
    static let longEdge = 60

    private var pictures: [String: UIImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    /// Each layer's last picture: what its row shows while a tool's drag is under way (M1c step 0c: a thumbnail asked at
    /// every move was a bake on the same baker as the overlay's, and a picture for the main actor to hand the row, at
    /// every pointer event). The row catches up at the lift.
    @ObservationIgnored private var lastOf: [UUID: UIImage] = [:]

    func picture(_ layer: LocalLayer, source: PixelSize) -> UIImage? {
        let key = MaskBaker.planeKey(layer, source: source, maxLongEdge: Self.longEdge)
        if let p = pictures[key] { lastOf[layer.id] = p; return p }
        if MaskTools.shared.dragging, let held = lastOf[layer.id] { return held }
        guard !asked.contains(key), source.width > 0, source.height > 0, let device = MTLCreateSystemDefaultDevice() else { return nil }
        asked.insert(key)
        if asked.count > 256 { asked.removeAll(); pictures.removeAll() }
        Task { [weak self] in
            guard let baker = try? SceneLayerWire.baker(for: device),
                  let plane = try? await baker.bake(layer, source: source, maxLongEdge: Self.longEdge),
                  let image = Self.image(plane) else { return }
            self?.pictures[key] = image
        }
        return nil
    }

    /// A plane's 16 bits as an 8-bit grey picture.
    nonisolated static func image(_ plane: MaskPlane) -> UIImage? {
        let bytes = plane.values.map { UInt8(min(255, (Double($0) / 65535 * 255).rounded())) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: plane.width, height: plane.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: plane.width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The two gradients' glyphs, which no symbol says (MASKS-SPEC §2): a rounded rectangle fading left to right, a
/// circle fading from its centre. Every other part's glyph is Apple's symbol (`MaskRules.symbol`).
struct MaskGlyph: View {
    let symbol: String
    var size: CGFloat = 13
    var color: Color = Theme.secondaryText

    var body: some View {
        switch symbol {
        case "linear":
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(color.opacity(0.7), lineWidth: 0.8))
                .frame(width: size * 15 / 13, height: size * 12 / 13)
        case "radial":
            Circle()
                .fill(RadialGradient(colors: [color, color.opacity(0.12)], center: .center, startRadius: 0, endRadius: size * 0.54))
                .overlay(Circle().strokeBorder(color.opacity(0.7), lineWidth: 0.8))
                .frame(width: size * 14 / 13, height: size * 14 / 13)
        default:
            Image(systemName: symbol).font(.system(size: size, weight: .medium)).foregroundStyle(color)
        }
    }
}

// MARK: - the head's buttons

/// + − ⋯: three 22 discs, 6 apart, ⋯ 10 from the card's right (MASKS-SPEC §2). − at 0.38 unless a mask layer is
/// picked; on a pair or a double + and − are at 0.38 and take no click (§4.4).
struct MaskHeadButtons<Menu: View>: View {
    let takesMasks: Bool
    let picked: UUID?
    let add: () -> Void
    let remove: () -> Void
    @ViewBuilder let menu: () -> Menu
    let menuEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            disc("plus", label: L("New Layer"), id: "layers.add", enabled: takesMasks, action: add)
            disc("minus", label: L("Delete Layer"), id: "layers.remove", enabled: takesMasks && picked != nil, action: remove)
            SwiftUI.Menu(content: menu) {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 22, height: 22).background(Theme.card, in: Circle()).contentShape(Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(menuEnabled ? 1 : Theme.disabledOpacity)
            .disabled(!menuEnabled)
            .accessibilityLabel(L("Layer actions"))
            .accessibilityIdentifier("layers.menu")
        }
    }

    private func disc(_ symbol: String, label: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 22, height: 22).background(Theme.card, in: Circle()).contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .opacity(enabled ? 1 : Theme.disabledOpacity)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

// MARK: - the two rows

/// 主体 · 背景 · 人: three equal buttons 28 high, radius 7, 8 apart, 14 from the card's sides; 人 with its chevron. While
/// one looks it reads 正在查找 with a spinner in place of its glyph, at the width it had (the three are equal shares of
/// the row, so no word moves another); the other two wait. A request this Mac's Vision cannot run stands its buttons
/// down at 0.38, "not available on this Mac" their reason (drawing 16's 退下).
struct MaskSelectionRow: View {
    let session: OpenFrameSession
    private var finding: MaskFinding { .shared }

    var body: some View {
        HStack(spacing: 8) {
            button(.subject, L("Subject"), "person.crop.rectangle")
            button(.background, L("Background"), "photo")
            button(.people, L("People"), "person.fill", menu: true)
                .popover(isPresented: Binding(get: { finding.peopleOpen }, set: { finding.peopleOpen = $0 }), arrowEdge: .bottom) {
                    MaskPeopleMenu(session: session, close: { finding.peopleOpen = false })
                        .background(Theme.panel)
                        .presentationCompactAdaptation(.popover)
                }
        }
        .padding(.horizontal, 14)
        .frame(height: LayerRules.Metric.selectionRow)
    }

    private func button(_ what: MaskFinding.What, _ word: String, _ symbol: String, menu: Bool = false) -> some View {
        let looking = finding.finding == what
        let why = finding.unavailable[what.request]
        let waits = finding.finding != nil && !looking
        return Button { finding.find(what, session: session) } label: {
            HStack(spacing: 6) {
                if looking {
                    ProgressView().controlSize(.mini).frame(width: 13, height: 11)
                } else {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                }
                Text(looking ? L("Finding") : word).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if menu, !looking {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                        .padding(.trailing, 11)
                }
            }
            .frame(height: 28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .disabled(why != nil || waits)
        .opacity(why != nil ? Theme.disabledOpacity : 1)
        .help(why != nil ? L("not available on this Mac") : word)
        .accessibilityLabel(word)
        .accessibilityValue(looking ? L("Finding") : "")
        .accessibilityHint(why != nil ? L("not available on this Mac") : menu ? L("Opens a menu") : "")
        .accessibilityIdentifier("layers.select.\(what.rawValue)")
    }
}

/// 画笔, 线性渐变, 径向渐变 | 橡皮: slots 30 × 28 laid from the card's right inset, a 0.5 × 20 divider with 6 each side;
/// a lit slot a 28 × 24 accent ground, radius 6, its glyph `onSelection`. The tool's pill at the row's leading end
/// (`MaskToolPill`). A click lights a tool, a second click (or Esc) puts it down (MASKS-SPEC §4.3).
struct MaskToolRow: View {
    let session: OpenFrameSession
    let longEdge: Int
    private var tools: MaskTools { .shared }

    var body: some View {
        HStack(spacing: 0) {
            MaskToolPill(session: session, longEdge: longEdge)
            Spacer(minLength: 8)
            slot(.brush)
            slot(.linear)
            slot(.radial)
            Rectangle().fill(Theme.rule).frame(width: 0.5, height: 20).padding(.horizontal, 6)
            slot(.eraser)
        }
        .padding(.horizontal, 14)
        .frame(height: LayerRules.Metric.toolRow)
    }

    private func slot(_ tool: MaskTool) -> some View {
        let lit = tools.lit == tool
        return Button { tools.click(tool) } label: {
            MaskGlyph(symbol: tool.symbol, size: 13, color: lit ? Theme.onSelection : Theme.secondaryText)
                .frame(width: 28, height: 24)
                .background { if lit { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent) } }
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityValue(lit ? L("on") : "")
        .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("layers.tool.\(tool.rawValue)")
    }
}

// MARK: - a mask layer's row

/// A mask layer's row (MASKS-SPEC §2, §4.2): the eye a real switch, the mask white on black, the name (renamed in
/// place by a double-click), and at its end [the geometry mark] [opacity, when not 100] its stage as a word.
struct MaskLayerRowView: View {
    let row: LayerRow
    let layer: LocalLayer
    let picked: Bool
    let source: PixelSize
    let session: OpenFrameSession
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool
    private var thumbnails: MaskThumbnails { .shared }

    private var off: Bool { row.eye == .off }
    private var ink: Color { picked ? Theme.onSelection : Theme.text }

    var body: some View {
        HStack(spacing: 0) {
            eye.frame(width: 20, height: 28)
            thumbnail
                .frame(width: 30, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(picked ? Theme.onSelection.opacity(0.35) : Theme.rule, lineWidth: 0.5))
                .opacity(off && !picked ? Theme.disabledOpacity : 1)
                .padding(.leading, 6)
            name.padding(.leading, 10)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 6).padding(.trailing, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(picked ? Theme.selection : hovering ? Theme.card.opacity(0.5) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRenaming() }
        .onTapGesture { session.pick(row: row.pick) }
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .frame(height: LayerRules.Metric.row)
        .contextMenu { MaskLayerMenu(session: session, layer: layer, rename: startRenaming) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(value)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { session.pick(row: row.pick) }
        .accessibilityAction(named: L("Rename")) { startRenaming() }
        .accessibilityAction(named: L("Duplicate Layer")) { session.duplicateLayer(layer.id) }
        .accessibilityAction(named: L("Invert")) { session.setLayerInverted(layer.id, !layer.invert) }
        .accessibilityAction(named: MaskRules.switchTitle(to: layer.stage == .scene ? .finished : .scene)) {
            session.switchStage(layer.id, to: layer.stage == .scene ? .finished : .scene)
        }
        .accessibilityAction(named: L("Delete Layer")) { session.removeLayer(layer.id) }
        .accessibilityIdentifier("layers.row." + row.key)
        .onChange(of: nameFocused) { _, focused in if !focused, renaming { finishRenaming() } }
        #if DEBUG
        // Where the row is in the window, for `--masks-check` to open its menu as a secondary click does.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { MaskRowFrames.frames[layer.id] = $0 }
        #endif
        // 重命名 from the head's ⋯, which is not this row's own menu.
        .onChange(of: LayersStage.shared.renaming, initial: true) { _, id in
            guard id == layer.id else { return }
            LayersStage.shared.renaming = nil
            startRenaming()
        }
    }

    /// "场景，不透明度 60 %，已启用" (MASKS-SPEC §9); and what the mark says, where the row wears it.
    private var value: String {
        let percent = "\(Int((min(max(layer.opacity, 0), 1) * 100).rounded())) %"
        let base = L("\(MaskRules.word(layer.stage)), opacity \(percent), \(layer.on ? L("on") : L("off"))")
        if MaskFinding.shared.missing[layer.id] != nil { return base + ", " + L("This mask’s picture is missing.") }
        if row.marked { return base + ", " + L("Lens correction changed: the mask may have moved.") }
        return base
    }

    private var eye: some View {
        Button { session.setLayerOn(layer.id, !layer.on) } label: {
            Image(systemName: off ? "eye.slash" : "eye").font(.system(size: 11, weight: .medium))
                .foregroundStyle(picked ? Theme.onSelection.opacity(off ? 0.45 : 0.8) : Theme.secondaryText.opacity(off ? 0.6 : 0.75))
                .frame(width: 20, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Show Layer"))
        .accessibilityLabel(L("Show Layer"))
        .accessibilityValue(layer.on ? L("on") : L("off"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("layers.eye." + row.key)
    }

    @ViewBuilder private var thumbnail: some View {
        if let picture = thumbnails.picture(layer, source: source) {
            Image(uiImage: picture).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
        } else {
            // An empty mask, and one still being baked: all black (MASKS-SPEC §4.2).
            Color.black
        }
    }

    @ViewBuilder private var name: some View {
        if renaming {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.Font.ui(13, .semibold))
                .foregroundStyle(ink)
                .focused($nameFocused)
                .onSubmit { finishRenaming() }
                .onKeyPress(.escape) { renaming = false; MacLibraryBrowser.shared.typing = false; return .handled }
                .accessibilityIdentifier("layers.rename")
        } else {
            Text(row.name)
                .font(Theme.Font.ui(13, picked ? .semibold : .medium))
                .foregroundStyle(ink)
                .opacity(off && !picked ? Theme.disabledOpacity : 1)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            if row.marked || MaskFinding.shared.missing[layer.id] != nil {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            if let opacity = row.opacityText {
                Text(opacity).font(Theme.Font.ui(12, .medium).monospacedDigit())
                    .foregroundStyle(picked ? Theme.onSelection.opacity(0.75) : Theme.secondaryText).lineLimit(1)
            }
            Text(MaskRules.word(layer.stage)).font(Theme.Font.ui(12, .medium))
                .foregroundStyle(picked ? Theme.onSelection.opacity(0.75) : Theme.dim).lineLimit(1)
        }
        .opacity(off && !picked ? Theme.disabledOpacity : 1)
    }

    private func startRenaming() {
        draft = layer.name
        renaming = true
        // A field has the keys: ↑ ↓ and ⌫ are the field's while it is (trap 32).
        MacLibraryBrowser.shared.typing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming() {
        guard renaming else { return }
        renaming = false
        MacLibraryBrowser.shared.typing = false
        session.renameLayer(layer.id, draft)
    }
}

/// A layer's menu (drawing 18; ⋯ and the secondary click are one list): 重命名, 复制图层, 显示蒙版 `M`, 仅显示蒙版 `⌥M`,
/// 反相, 改为作用于… with 调整从零开始 under it, 删除图层. The two views act on the picked layer (they are the page's), so
/// a row's menu picks its row first.
struct MaskLayerMenu: View {
    let session: OpenFrameSession
    let layer: LocalLayer
    let rename: () -> Void

    var body: some View {
        let other: LayerStage = layer.stage == .scene ? .finished : .scene
        Button(action: rename) { Label(L("Rename"), systemImage: "pencil") }
        Button { session.duplicateLayer(layer.id) } label: { Label(L("Duplicate Layer"), systemImage: "plus.square.on.square") }
        Divider()
        let tools = MaskTools.shared
        Button { session.pick(row: .mask(layer.id)); tools.alone = false; tools.held.toggle() } label: {
            Label(L("Show Mask"), systemImage: tools.held && session.maskPick == layer.id ? "checkmark" : "eye")
        }
        Button { session.pick(row: .mask(layer.id)); tools.alone.toggle() } label: {
            Label(L("Show Mask Alone"), systemImage: tools.alone && session.maskPick == layer.id ? "checkmark" : "circle.lefthalf.filled")
        }
        Divider()
        Button { session.setLayerInverted(layer.id, !layer.invert) } label: {
            Label(L("Invert"), systemImage: layer.invert ? "checkmark" : "circle.righthalf.filled")
        }
        Divider()
        Button { session.switchStage(layer.id, to: other) } label: {
            Label(MaskRules.switchTitle(to: other), systemImage: "arrow.left.arrow.right")
            Text(L("its adjustments start again"))
        }
        Divider()
        Button(role: .destructive) { session.removeLayer(layer.id) } label: { Label(L("Delete Layer"), systemImage: "trash") }
    }
}

#if DEBUG
/// Each mask row's frame in the window, by layer: `MacMasksCheck` opens a row's menu at it.
@MainActor enum MaskRowFrames { static var frames: [UUID: CGRect] = [:] }
#endif

// MARK: - under the rows

/// 不透明度: the picked layer's, where a double's Balance sits — a half-point rule, `ValueSlider`'s parts at 40 and its
/// number's box 62, 4 under (MASKS-SPEC §2). 0–100 %, no rest mark; with 胶片 picked it is there at 0.38 and takes
/// nothing (drawing 15's note).
struct MaskOpacityRow: View {
    let session: OpenFrameSession
    @State private var dragging = false

    private var layer: LocalLayer? { session.chromeMaskLayer }
    private var value: Double { layer?.opacity ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.horizontal, 14)
            HStack(alignment: .center, spacing: 8) {
                Text(L("Opacity")).font(Theme.Font.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).frame(width: 64, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { set(1) }
                    .accessibilityHidden(true)
                SliderTrack(value: Binding(get: { value }, set: { v in move(v) }),
                            range: 0...1, rest: 1, step: 0.01, detentAtRest: false, showsRest: false,
                            onEditingChanged: { down in
                                guard down != dragging else { return }
                                dragging = down
                                down ? session.beganLayer() : session.endedLayer()
                            })
                    .frame(height: 28)
                SliderField(shown: "\(Int((value * 100).rounded())) %", width: 62,
                            parse: { SliderField.number(from: $0.replacingOccurrences(of: "%", with: "")).map { $0 / 100 } },
                            commit: { set($0.clamped(to: 0...1)) })
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .padding(.bottom, 4)
        }
        .opacity(layer == nil ? Theme.disabledOpacity : 1)
        .allowsHitTesting(layer != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Opacity"))
        .accessibilityValue("\(Int((value * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            set((value + step).clamped(to: 0...1))
        }
        .accessibilityIdentifier("layers.opacity")
    }

    private func move(_ v: Double) {
        guard let id = layer?.id else { return }
        session.moveLayer(id) { $0.opacity = v }
    }

    private func set(_ v: Double) {
        guard let id = layer?.id else { return }
        session.changeLayer(id) { $0.opacity = v }
    }
}

/// 组合蒙版 · 完善蒙版…: two equal buttons 28 high, radius 7, 8 apart; 2 above, 10 under (MASKS-SPEC §2). Each opens its
/// popover under it (`MaskCombinePopover`, `MaskRefinePopover`), SwiftUI's own, as the pill's (G5).
struct MaskButtonsRow: View {
    let session: OpenFrameSession
    private var tools: MaskTools { .shared }

    var body: some View {
        HStack(spacing: 8) {
            button(L("Combine Masks"), chevron: true, id: "layers.combine") { tools.combineOpen.toggle() }
                .popover(isPresented: Binding(get: { tools.combineOpen }, set: { tools.combineOpen = $0 }), arrowEdge: .bottom) {
                    MaskCombinePopover(session: session, close: { tools.combineOpen = false })
                }
            button(L("Refine Mask…"), chevron: false, id: "layers.refine") { tools.refineOpen = tools.refineOpen == nil ? .panel : nil }
                .popover(isPresented: Binding(get: { tools.refineOpen == .panel }, set: { if !$0 { tools.refineOpen = nil } }), arrowEdge: .bottom) {
                    MaskRefinePopover(session: session)
                }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2).padding(.bottom, 10)
        .frame(height: LayerRules.Metric.buttons)
        .opacity(session.chromeMaskLayer == nil ? Theme.disabledOpacity : 1)
        .allowsHitTesting(session.chromeMaskLayer != nil)
    }

    private func button(_ word: String, chevron: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(word).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim) }
            }
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(word)
        .accessibilityHint(chevron ? L("Opens a menu") : "")
        .accessibilityIdentifier(id)
    }
}
