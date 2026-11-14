//  MaskPage.swift — a mask layer's own page: the column under the 图层 panel while a mask layer is picked, the same in
//  冲洗 and 编辑 (design/masks/MASKS-SPEC.md §5; drawings 02, 03, 11, 18). No band.
//
//  Three parts and a foot. **作用于**: 场景 | 成片 with one line of what the stage means; a switch acts at once (the mask,
//  the name, the opacity and the eye stay, the other stage's adjustments start from zero), and where the old ones
//  were not zero a line says so with 撤销, gone with the next change (`OpenFrameSession.stageNotice`). **蒙版**: the
//  parts in order, each with its join, its eye and ×; the empty mask's line; 反相; 羽化's value in its pill, which opens
//  完善蒙版… (its one slider). Its first line, where the row wears the mark: the geometry changed under the mask
//  (镜头校正, MASKS-SPEC §6.5, drawing 14) with 重新查找 (a found mask) and 保持现状, or a found mask's file missing. **调整**: 场景's 曝光, 色温, 色调; or
//  成片's six of Edit's tools, each its own folding section as `AdjustColumn` draws them (gap G4), in the order the
//  user set on 胶片's page and open as there, bound to the layer's values. The foot row leads back to 胶片.
//
//  A slider here does not commit per tick (`OpenFrameSession.moveLayer`): a 成片 layer follows the pointer in Edit's
//  pass with nothing developed, a 场景 layer develops at the live tier when the pointer rests.

import SwiftUI

/// What of the page is the page's: which of its two sections are open (not kept: a page opens with both).
@MainActor @Observable
final class MaskPageState {
    static let shared = MaskPageState()
    var maskOpen = true
    var adjustOpen = true
    var tone: TonePage = .highlightsShadows
    #if DEBUG
    /// The stage note's size as laid out (its room's width, its lines' height): `--masks-check` holds it to one line.
    @ObservationIgnored var noteSize: CGSize = .zero
    #endif
}

struct MaskPage: View {
    let session: OpenFrameSession
    let layer: LocalLayer
    private var state: MaskPageState { .shared }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                stageRow
                FoldRule()
                maskSection
                FoldRule()
                adjustSection
                FoldRule()
                foot
                FoldRule()
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("layers.page")
    }

    // MARK: 作用于

    private var stageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Works on")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                SegmentedSwitch(options: [LayerStage.scene, .finished],
                                selection: Binding(get: { layer.stage }, set: { session.switchStage(layer.id, to: $0) }),
                                title: MaskRules.word, segmentWidth: 76, track: Theme.card)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Works on"))
                    .accessibilityValue(MaskRules.word(layer.stage))
                    .accessibilityHint(MaskRules.note(layer.stage))
                    .accessibilityAdjustableAction { _ in session.switchStage(layer.id, to: layer.stage == .scene ? .finished : .scene) }
                    .accessibilityIdentifier("layers.page.stage")
            }
            .frame(height: 44)
            // 11.5 regular, the smallest new line (MASKS-SPEC §2; the generator's weight 400): one line of the column in
            // either language. Drawn at `Theme.Font.ui`'s default (medium) the English took two in the running window
            // (M1a's capture); `--masks-check` measures the line where it is drawn.
            Text(MaskRules.note(layer.stage)).font(Theme.Font.ui(11.5, .regular)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if DEBUG
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { MaskPageState.shared.noteSize = $0 }
                #endif
            if session.stageNotice == layer.id { notice }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    /// "这一层的调整已从零开始。" with 撤销 (drawing 11).
    private var notice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(L("Its adjustments start again from zero.")).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { session.undo() } label: {
                Text(L("Undo")).font(Theme.Font.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: 26).background(Theme.card, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .accessibilityIdentifier("layers.page.undo")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
    }

    // MARK: 蒙版

    private var maskSection: some View {
        VStack(spacing: 0) {
            FoldHeader(open: state.maskOpen, toggle: { withAnimation(.easeOut(duration: 0.18)) { state.maskOpen.toggle() } }) {
                FoldTitle(L("Mask"), open: state.maskOpen)
            } accessory: {
                if !state.maskOpen, !layer.parts.isEmpty {
                    Text(MaskRules.summary(layer)).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                // The overlay's eye (`M`, the same switch): lit on the accent while the overlay is on the picture.
                let tools = MaskTools.shared
                let lit = tools.overlayShown(session) || tools.held
                Button { tools.alone = false; tools.held.toggle() } label: {
                    Image(systemName: "eye").font(.system(size: 10, weight: .semibold)).foregroundStyle(lit ? Theme.onSelection : Theme.text)
                        .frame(width: 22, height: 22).background(lit ? Theme.accent : Theme.card, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help(L("Show Mask"))
                .accessibilityLabel(L("Show Mask"))
                .accessibilityValue(tools.held ? L("on") : L("off"))
                .accessibilityIdentifier("mask.overlay")
            }
            .accessibilityIdentifier("layers.page.mask")
            if state.maskOpen {
                VStack(spacing: 0) {
                    markNotice
                    if layer.parts.isEmpty {
                        Text(L("The mask is empty. Choose a tool and draw it.")).font(Theme.Font.ui(12)).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    ForEach(Array(layer.parts.enumerated()), id: \.element.id) { i, part in partRow(part, number: i + 1) }
                    row(L("Invert")) {
                        SpkToggle(isOn: Binding(get: { layer.invert }, set: { session.setLayerInverted(layer.id, $0) }), size: .compact)
                            .accessibilityLabel(L("Invert"))
                            .accessibilityIdentifier("layers.page.invert")
                    }
                    row(L("Feather")) {
                        // 羽化's one slider is 完善蒙版…'s; the pill says its value and opens the same popover.
                        Button { MaskTools.shared.refineOpen = MaskTools.shared.refineOpen == nil ? .page : nil } label: {
                            HStack(spacing: 4) {
                                Text(MaskRules.featherText(layer.feather)).font(Theme.Font.ui(12.5, .medium).monospacedDigit())
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(Theme.text).padding(.horizontal, 10).frame(height: 24)
                            .background(Theme.card, in: Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .popover(isPresented: Binding(get: { MaskTools.shared.refineOpen == .page },
                                                      set: { if !$0 { MaskTools.shared.refineOpen = nil } }), arrowEdge: .bottom) {
                            MaskRefinePopover(session: session)
                        }
                        .accessibilityLabel(L("Feather"))
                        .accessibilityValue(MaskRules.featherText(layer.feather))
                        .accessibilityHint(L("Refine Mask…"))
                        .accessibilityIdentifier("layers.refine.feather")
                    }
                }
                .padding(.leading, 16 + 12 + 6).padding(.trailing, 16).padding(.bottom, 8)
            }
        }
    }

    /// The 蒙版 section's first line where the row wears the mark (MASKS-SPEC §6.5, drawing 14): a found mask whose file
    /// is missing (the develop of this layer fails rather than drawing the picture without it, so it is said here), or
    /// 镜头校正 switched since the mask was made. 重新查找 for a found mask; 保持现状 for any (the geometry's only).
    /// Either clears the mark; nothing moves silently.
    @ViewBuilder private var markNotice: some View {
        let finding = MaskFinding.shared
        let missing = finding.missing[layer.id] != nil
        let moved = LayerRules.isMarked(layer, lensCorrection: session.edit.decode.lensCorrection, lensWord: session.lensWord)
        let hasFound = layer.parts.contains { $0.kind == .found }
        if missing || moved {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(missing ? L("This mask’s picture is missing.") : L("Lens correction changed: the mask may have moved."))
                        .font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("layers.page.mark")
                HStack(spacing: 8) {
                    if hasFound {
                        noticeButton(finding.finding != nil ? L("Finding") : L("Find Again"), symbol: "arrow.clockwise",
                                     id: "layers.page.find-again", busy: finding.finding != nil) {
                            finding.findAgain(layer.id, session: session)
                        }
                    }
                    if moved, !missing {
                        noticeButton(L("Keep As It Is"), symbol: nil, id: "layers.page.keep") { finding.keepAsIs(layer.id, session: session) }
                    }
                }
                .padding(.leading, 17)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func noticeButton(_ word: String, symbol: String?, id: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(word).font(Theme.Font.ui(12.5, .semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.text).padding(.horizontal, 12).frame(height: 26)
            .background(Theme.card, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(busy)
        .accessibilityLabel(word)
        .accessibilityIdentifier(id)
    }

    private func row<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 8)
            accessory()
        }
        .frame(height: 32)
    }

    /// "加 · 主体": the join's disc, the part's glyph, the words, its eye, ×. A click makes it the part the picture's
    /// handles are for (§5): a gradient's lights its tool, so its lines appear; the chosen part on `Theme.card`.
    private func partRow(_ part: MaskPart, number: Int) -> some View {
        let tools = MaskTools.shared
        let chosen = tools.chosenPart == part.id
        return HStack(spacing: 8) {
            Image(systemName: MaskRules.symbol(part.join)).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 18, height: 18).background(Theme.card, in: Circle())
            MaskGlyph(symbol: MaskRules.symbol(part), size: 12)
                .frame(width: 18)
            Text(MaskRules.title(part)).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 8)
            Button { session.changePart(layer.id, part: part.id) { $0.on.toggle() } } label: {
                Image(systemName: part.on ? "eye" : "eye.slash").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(part.on ? L("Hide") : L("Show"))
            .accessibilityIdentifier("layers.part.\(number).eye")
            Button { session.removePart(layer.id, part: part.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.dim).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Remove"))
            .accessibilityIdentifier("layers.part.\(number).remove")
        }
        .opacity(part.on ? 1 : Theme.disabledOpacity)
        .frame(height: 30)
        .padding(.horizontal, 6)
        .background { if chosen { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card) } }
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture {
            tools.chosenPart = chosen ? nil : part.id
            if !chosen, part.kind == .linear { tools.light(.linear) } else if !chosen, part.kind == .radial { tools.light(.radial) }
        }
        // "加，主体", on or off; a button, its actions 移除 and 显示 / 隐藏 (MASKS-SPEC §9).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(MaskRules.word(part.join)), \(MaskRules.word(part))"))
        .accessibilityValue(part.on ? L("on") : L("off"))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) {
            tools.chosenPart = chosen ? nil : part.id
            if !chosen, part.kind == .linear { tools.light(.linear) } else if !chosen, part.kind == .radial { tools.light(.radial) }
        }
        .accessibilityAction(named: L("Remove")) { session.removePart(layer.id, part: part.id) }
        .accessibilityAction(named: part.on ? L("Hide") : L("Show")) { session.changePart(layer.id, part: part.id) { $0.on.toggle() } }
        .accessibilityIdentifier("layers.part.\(number)")
    }

    // MARK: 调整

    private var adjustSection: some View {
        VStack(spacing: 0) {
            FoldHeader(open: state.adjustOpen, toggle: { withAnimation(.easeOut(duration: 0.18)) { state.adjustOpen.toggle() } }) {
                FoldTitle(L("Adjust"), open: state.adjustOpen)
            } accessory: {
                let zero = layer.stage == .scene ? (layer.scene?.isZero ?? true) : (layer.finished?.isZero ?? true)
                Button { session.resetLayerAdjustments(layer.id) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 22, height: 22).background(Theme.card, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .opacity(zero ? Theme.disabledOpacity : 1)
                .disabled(zero)
                .help(L("Reset"))
                .accessibilityLabel(L("Reset"))
                .accessibilityIdentifier("layers.page.adjust.reset")
            }
            .accessibilityIdentifier("layers.page.adjust")
            if state.adjustOpen {
                if layer.stage == .finished { finishedTools } else { sceneSliders }
            }
        }
    }

    /// 场景: 曝光 (−4…+4 EV, the grey track), 色温, 色调 (the tinted tracks).
    private var sceneSliders: some View {
        VStack(spacing: 2) {
            ForEach(MaskRules.SceneControl.allCases) { c in
                let track: Layer2Control = c == .exposure ? .exposure : c == .temperature ? .temperature : .tint
                ValueSlider(title: c.title, value: Binding(
                                get: { layer.scene?[keyPath: c.keyPath] ?? 0 },
                                set: { v in session.moveLayer(layer.id) { l in
                                    var d = l.scene ?? SceneDeltas(); d[keyPath: c.keyPath] = v; l.scene = d } }),
                            range: c.range, rest: 0, text: c.text, track: track.track, detentAtRest: true,
                            onEditingChanged: { $0 ? session.beganLayer() : session.endedLayer() })
                    .accessibilityIdentifier("layers.page.scene.\(c.rawValue)")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .onDisappear { session.endedLayer() }
    }

    /// 成片: Edit's six scalar tools as `AdjustColumn`'s own sections (no grip: the order is set on 胶片's page).
    private var finishedTools: some View {
        let layout = AdjustLayout.shared
        let tools = layout.order.filter { MaskRules.finishedTools.contains($0.rawValue) }
        return VStack(spacing: 0) {
            ForEach(tools) { t in
                let open = layout.isOpen(t)
                FoldRule()
                FoldHeader(open: open, symbol: t.symbol, toggle: { withAnimation(.easeOut(duration: 0.18)) { layout.toggle(t) } }) {
                    if t == .tone, open {
                        Menu {
                            Picker(L("Tone"), selection: Binding(get: { state.tone }, set: { state.tone = $0 })) {
                                ForEach(TonePage.allCases) { Text($0.title).tag($0) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(t.title + " · " + state.tone.title).font(Theme.Font.ui(12.5, .semibold)).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(Theme.text).contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    } else {
                        FoldTitle(t.title, open: open)
                    }
                    if !isAtRest(t) { Circle().fill(Theme.accent).frame(width: 5, height: 5).accessibilityHidden(true) }
                }
                .accessibilityIdentifier("layers.page.finished.\(t.rawValue)")
                if open {
                    VStack(spacing: 2) {
                        ForEach(t == .tone ? state.tone.controls : t.controls) { control in finishedSlider(control, tool: t) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
        }
        .onDisappear { session.endedLayer() }
    }

    private func isAtRest(_ t: AdjustTool) -> Bool {
        let d = layer.finished ?? FinishedDeltas()
        return t.controls.allSatisfy { c in (MaskRules.finished(c, in: d) ?? 0) == 0 }
    }

    @ViewBuilder private func finishedSlider(_ control: Layer2Control, tool: AdjustTool) -> some View {
        if MaskRules.finishedKeyPath(control) != nil {
            EditSlider(title: control.title(in: tool), value: Binding(
                get: { layer.finished.flatMap { MaskRules.finished(control, in: $0) } ?? 0 },
                set: { v in session.moveLayer(layer.id) { l in var d = l.finished ?? FinishedDeltas(); MaskRules.setFinished(control, v, in: &d); l.finished = d } }),
                range: control.range, rest: control.rest,
                text: { control.text($0) + (control == .exposure ? " EV" : "") },
                track: control.track, detentAtRest: true,
                editing: { $0 ? session.beganLayer() : session.endedLayer() })
            .accessibilityIdentifier("layers.page.finished.slider.\(control.rawValue)")
        }
    }

    // MARK: the foot

    private var foot: some View {
        Button { session.pick(row: .film) } label: {
            HStack(spacing: 10) {
                Image(systemName: "film").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText).frame(width: 22)
                Text(MaskRules.foot(layer.stage)).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 16).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("layers.page.film-link")
    }
}
