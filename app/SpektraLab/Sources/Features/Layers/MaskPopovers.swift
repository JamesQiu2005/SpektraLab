//  MaskPopovers.swift — the tool's pill at the tool row's leading end and the brush's popover (design/masks/MASKS-SPEC.md
//  §2, §6.2, §7; drawings 04, 08, 09, 10; gap G5), 人's menu, 组合蒙版's popover and 完善蒙版….
//
//  **G5, tried:** the popover is SwiftUI's own `.popover` on the pill, inside the pinned 图层 card. Seen in the running
//  window (`--masks-check`'s capture of drawing 04, 2026-11-13): Catalyst presents it as the Mac's popover — its own
//  window over the column and the picture, an arrow at the pill, not clipped by the card — so the fallback the spec names
//  (the app's own floating panel, as the loupe's) was not needed. Asked for under the pill (`arrowEdge: .bottom`, drawing
//  04), it opened above it in the check's 1,100-point window: the system's own placement. Not yet seen by a person: Esc
//  and a click outside closing it, and where it opens in a taller window (the hand-check list).

import SwiftUI

/// "画笔 · 大小 120", "减去 · 画笔 · 大小 120": 24 high, a capsule on `Theme.card`, shown while a tool with settings or a
/// join other than its own is lit. A click opens the brush's settings.
struct MaskToolPill: View {
    let session: OpenFrameSession
    let longEdge: Int
    private var tools: MaskTools { .shared }

    var body: some View {
        let tool = tools.lit
        let lines = tool.map { MaskRules.pillLines($0, join: tools.join ?? $0.join,
                                                   sizePixels: $0.isBrush ? tools.settings($0).sizePixels(longEdge: longEdge) : nil) } ?? []
        if let tool, let words = lines.first {
            Button { if tool.isBrush { tools.popover.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
                    // The longest line that fits the row; a part left off whole where it does not.
                    ViewThatFits(in: .horizontal) {
                        ForEach(lines, id: \.self) { line in
                            Text(line).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                        }
                    }
                    if tool.isBrush {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 10).frame(height: 24)
                .background(Theme.card, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .popover(isPresented: Binding(get: { tools.popover && tool.isBrush }, set: { tools.popover = $0 }), arrowEdge: .bottom) {
                MaskBrushPopover(tool: tool, longEdge: longEdge)
            }
            // "画笔，大小 120" (MASKS-SPEC §9): the pill's words, said as a list.
            .accessibilityLabel(words.replacingOccurrences(of: " · ", with: L(", ")))
            .accessibilityHint(tool.isBrush ? L("Opens its settings") : "")
            .accessibilityIdentifier("layers.tool.pill")
        }
    }
}

/// 大小, 硬度, 流量: each a `ValueSlider` (its label, its track, a 56 box). 大小 is the brush's diameter in the
/// photograph's own pixels (a share of its long edge, so the same brush at every zoom); 硬度 where the edge begins to
/// fall, 流量 what one pass leaves (RFC-052 §4.1), both 0–100.
struct MaskBrushPopover: View {
    let tool: MaskTool
    let longEdge: Int
    private var tools: MaskTools { .shared }

    var body: some View {
        let s = tools.settings(tool)
        let maxPixels = Double(BrushSettings(radius: BrushSettings.radiusRange.upperBound).sizePixels(longEdge: longEdge))
        VStack(alignment: .leading, spacing: 4) {
            ValueSlider(title: L("Size", as: "a brush's"),
                        value: Binding(get: { Double(s.sizePixels(longEdge: longEdge)) },
                                       set: { px in var n = tools.settings(tool); n.radius = BrushSettings.radius(pixels: px, longEdge: longEdge); tools.setSettings(tool, n) }),
                        range: 1...max(maxPixels, 2), rest: Double(BrushSettings().sizePixels(longEdge: longEdge)), step: 1,
                        text: { "\(Int($0.rounded()))" }, showsRest: false, labelWidth: 72, fieldWidth: 56)
                .accessibilityIdentifier("mask.brush.size")
            ValueSlider(title: L("Hardness"),
                        value: Binding(get: { (s.hardness * 100).rounded() },
                                       set: { v in var n = tools.settings(tool); n.hardness = v / 100; tools.setSettings(tool, n) }),
                        range: 0...100, rest: 50, step: 1, text: { "\(Int($0.rounded()))" }, showsRest: false, labelWidth: 72, fieldWidth: 56)
                .accessibilityIdentifier("mask.brush.hardness")
            ValueSlider(title: L("Flow"),
                        value: Binding(get: { (s.flow * 100).rounded() },
                                       set: { v in var n = tools.settings(tool); n.flow = v / 100; tools.setSettings(tool, n) }),
                        range: 1...100, rest: 100, step: 1, text: { "\(Int($0.rounded()))" }, showsRest: false, labelWidth: 72, fieldWidth: 56)
                .accessibilityIdentifier("mask.brush.flow")
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.panel)
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - 人's menu (MASKS-SPEC §6.4, drawing 10)

/// 全部人物 with the count, a rule, then a row a person, 40 high with a 28 square of them; the row under the pointer
/// lights that person in the overlay on the picture (`MaskFinding.hovered`, `MaskStage`). Nobody: one grey row,
/// 未找到人物. A click makes the layer (or, from 组合蒙版, joins the picked one with `join`).
struct MaskPeopleMenu: View {
    let session: OpenFrameSession
    var join: MaskPart.Join? = nil
    var close: () -> Void = {}
    private var finding: MaskFinding { .shared }

    var body: some View {
        VStack(spacing: 0) {
            if let people = finding.people, people.all != nil || !people.people.isEmpty {
                row(0, title: L("All People"), trailing: "\(people.count)") {
                    Image(systemName: "person.3.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        .frame(width: 28, height: 28)
                }
                Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 2)
                ForEach(people.people, id: \.number) { p in
                    row(p.number, title: L("Person \(p.number)"), trailing: nil) {
                        Group {
                            if let t = finding.thumbnails[p.number] {
                                Image(uiImage: t).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                            } else {
                                Theme.card
                            }
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            } else {
                Text(L("No people found")).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 12)
                    .accessibilityIdentifier("layers.people.none")
            }
        }
        .padding(6)
        .frame(width: 240)
        .onDisappear { finding.hovered = nil }
        .accessibilityIdentifier("layers.people.menu")
    }

    private func row<Glyph: View>(_ n: Int, title: String, trailing: String?, @ViewBuilder glyph: () -> Glyph) -> some View {
        let lit = finding.hovered == n
        return Button {
            close()
            finding.choosePerson(n, session: session, join: join)
        } label: {
            HStack(spacing: 10) {
                glyph()
                Text(title).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(Theme.Font.ui(12.5, .medium).monospacedDigit()).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 40)
            .background(lit ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { finding.hovered = n } else if finding.hovered == n { finding.hovered = nil }
        }
        .accessibilityLabel(trailing.map { "\(title), \($0)" } ?? title)
        .accessibilityIdentifier("layers.people.\(n)")
    }
}

// MARK: - 组合蒙版 (MASKS-SPEC §7, drawing 08)

/// The join first, then a tool: two clicks. 加 · 减去 · 相交 (加 at first); 主体, 背景, 人 ›, a rule, 画笔, 线性渐变,
/// 径向渐变. A found mask applies with the join at once and closes; a drawn tool lights with the join (its pill says
/// it) until it is put down. M2's entries are not listed: what is not built is not shown.
struct MaskCombinePopover: View {
    let session: OpenFrameSession
    let close: () -> Void
    @State private var join: MaskPart.Join = .add
    @State private var people = false
    private var finding: MaskFinding { .shared }
    private var tools: MaskTools { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SegmentedSwitch(options: [MaskPart.Join.add, .subtract, .intersect], selection: $join, title: MaskRules.word,
                            segmentWidth: 76, track: Theme.card)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Combine Masks"))
                .accessibilityValue(MaskRules.word(join))
                .accessibilityAdjustableAction { d in
                    let all: [MaskPart.Join] = [.add, .subtract, .intersect]
                    let i = all.firstIndex(of: join) ?? 0
                    join = all[(i + (d == .increment ? 1 : 2)) % 3]
                }
                .accessibilityIdentifier("layers.combine.join")
                .padding(.bottom, 8)
            if people {
                item(L("People"), symbol: "chevron.left", id: "layers.combine.back") { people = false }
                if finding.finding == .people {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Finding")).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.secondaryText)
                    }
                    .frame(height: 34).padding(.horizontal, 8)
                } else {
                    MaskPeopleMenu(session: session, join: join, close: close).padding(-6)
                }
            } else {
                found(.subject, L("Subject"), "person.crop.rectangle")
                found(.background, L("Background"), "photo")
                item(L("People"), symbol: "person.fill", chevron: true, id: "layers.combine.people",
                     enabled: finding.unavailable[.people] == nil) {
                    people = true
                    if finding.people == nil { finding.openPeople(session, opensMenu: false) }
                }
                Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.vertical, 5).padding(.horizontal, 6)
                drawn(.brush)
                drawn(.linear)
                drawn(.radial)
            }
        }
        .padding(10)
        .frame(width: 260)
        .background(Theme.panel)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("layers.combine.popover")
    }

    private func found(_ what: MaskFinding.What, _ word: String, _ symbol: String) -> some View {
        item(word, symbol: symbol, id: "layers.combine.\(what.rawValue)", enabled: finding.unavailable[what.request] == nil) {
            close()
            finding.find(what, session: session, join: join)
        }
    }

    private func drawn(_ tool: MaskTool) -> some View {
        item(tool.title, glyph: tool.symbol, id: "layers.combine.\(tool.rawValue)") {
            tools.light(tool)
            tools.join = join
            close()
        }
    }

    private func item(_ word: String, symbol: String? = nil, glyph: String? = nil, chevron: Bool = false, id: String,
                      enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let glyph { MaskGlyph(symbol: glyph, size: 13, color: Theme.text).frame(width: 18) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).frame(width: 18) }
                Text(word).font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim) }
            }
            .padding(.horizontal, 8).frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(MaskMenuItemStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.disabledOpacity)
        .help(enabled ? word : L("not available on this Mac"))
        .accessibilityLabel(word)
        .accessibilityIdentifier(id)
    }
}

/// A menu row's hover and press: `Theme.card` behind it (drawing 08's lit row).
struct MaskMenuItemStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((configuration.isPressed || hovering) ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: - 完善蒙版… (MASKS-SPEC §7, drawing 09)

/// 完善蒙版 with ↺, and M1's one slider, 羽化 — σ as a share of the photograph's long edge (RFC-052 §4.2: a Gaussian of
/// the folded plane, metric), shown in thousandths (`MaskRules.featherText`), 0–50. While it is open the picture shows
/// the mask alone; it returns to what it was as it closes (`MaskTools.refining`). A drag is one step of Undo; a 场景
/// layer develops when the pointer rests (`OpenFrameSession.moveLayer`). M2's 扩张 / 收缩 and 边缘半径 are not shown.
struct MaskRefinePopover: View {
    let session: OpenFrameSession
    private var layer: LocalLayer? { session.pickedMaskLayer }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Refine Mask")).font(Theme.Font.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { if let id = layer?.id { session.changeLayer(id) { $0.feather = 0 } } } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 22, height: 22).background(Theme.card, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .opacity((layer?.feather ?? 0) == 0 ? Theme.disabledOpacity : 1)
                .disabled((layer?.feather ?? 0) == 0)
                .help(L("Reset"))
                .accessibilityLabel(L("Reset"))
                .accessibilityIdentifier("layers.refine.reset")
            }
            ValueSlider(title: L("Feather"),
                        value: Binding(get: { (session.pickedMaskLayer?.feather ?? 0) * 1000 },
                                       set: { v in if let id = layer?.id { session.moveLayer(id) { $0.feather = (v / 1000).clamped(to: 0...MaskRules.maxFeather) } } }),
                        range: 0...(MaskRules.maxFeather * 1000), rest: 0, step: 1, text: { "\(Int($0.rounded()))" }, showsRest: false,
                        labelWidth: 56, fieldWidth: 56,
                        onEditingChanged: { $0 ? session.beganLayer() : session.endedLayer() })
                .accessibilityIdentifier("layers.refine.feather.slider")
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.panel)
        .presentationCompactAdaptation(.popover)
        .onAppear { MaskTools.shared.beginRefining() }
        .onDisappear { session.endedLayer(); MaskTools.shared.endRefining() }
        .accessibilityIdentifier("layers.refine.popover")
    }
}
