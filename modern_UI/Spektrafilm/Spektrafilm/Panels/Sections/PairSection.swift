//  PairSection.swift — the Half-Frame Pair's tool, under the Navigator.
//
//  The pair is worked on the canvas: a click picks a frame, the + on an empty
//  hole adds one, a right click replaces or crops it. This section is what the
//  canvas cannot say — which way the camera was held, how far apart the frames
//  are — and the picked frame's numbers: its exposure and its crop under the
//  hole. Built from the rail's own parts.

import SwiftUI

struct PairSection: View {
    @Bindable var session: Session
    static let key = "pair"

    private var pair: HalfFramePair { session.pair ?? HalfFramePair(folder: "") }

    var body: some View {
        PanelSection(L("Half-Frame Pair", zh: "半格拼接"), key: Self.key, initiallyExpanded: true) {
            RailRows {
                VStack(spacing: 2) {
                    ForEach(PairLayer.allCases, id: \.self) { layerRow($0) }
                }
                switch session.pairLayer {
                case .film: filmRows
                case .left: holeRows(.left)
                case .right: holeRows(.right)
                }
            }
        }
    }

    // MARK: the layer list

    private func layerRow(_ layer: PairLayer) -> some View {
        let on = session.pairLayer == layer
        return HStack(spacing: 8) {
            Group {
                if let side = layer.side, let hole = pair[side] {
                    CropMaskedThumbnail(url: hole.url, geometry: .default, maxPixel: 96) { image in
                        if let image {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else { Theme.well }
                    }
                } else {
                    Theme.well.overlay(Image(systemName: layer == .film ? "film" : "plus")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.Ink.tertiary))
                }
            }
            .frame(width: pair.turned ? 24 : 18, height: pair.turned ? 18 : 24)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(layer)).font(Theme.Font.label).foregroundStyle(Theme.text)
                Text(subtitle(layer)).font(Theme.Font.meta).foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background {
            if on { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.text.opacity(0.1)) }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.pairLayer = layer }
    }

    private func title(_ layer: PairLayer) -> String {
        switch layer {
        case .film: L("Film", zh: "胶片")
        case .left: pair.turned ? L("Top frame", zh: "上格") : L("Left frame", zh: "左格")
        case .right: pair.turned ? L("Bottom frame", zh: "下格") : L("Right frame", zh: "右格")
        }
    }

    private func subtitle(_ layer: PairLayer) -> String {
        guard let side = layer.side else {
            return String(format: L("135 half · %.1f mm apart", zh: "135 半格 · 间距 %.1f mm"), pair.effectiveSpacingMM)
        }
        guard let hole = pair[side] else { return L("Empty", zh: "空") }
        return hole.exists ? hole.url.lastPathComponent
            : L("Missing: ", zh: "找不到：") + hole.url.lastPathComponent
    }

    // MARK: the Film layer

    @ViewBuilder private var filmRows: some View {
        PillSwitchRow(label: L("Camera", zh: "相机"), options: PairHold.allCases,
                      selection: Binding(get: { pair.turned ? .turned : .level },
                                         set: { session.setPairTurned($0 == .turned) }),
                      title: { $0 == .turned ? L("Turned", zh: "竖持") : L("Level", zh: "横持") })
        ScrubSlider(label: L("Spacing", zh: "间距"), sublabel: "mm",
                    value: Binding(get: { pair.effectiveSpacingMM }, set: { session.setPairSpacing($0) }),
                    range: HalfFramePair.spacingRange, zero: 1.0, snap: 0.1,
                    format: { String(format: "%.1f", $0) }, disabled: pair.onStrip)
            .help(pair.onStrip ? L("With Film Edge on, the camera's advance sets the gap.",
                                   zh: "开启片边后，间距由相机过片决定。") : "")
        HStack(spacing: 8) {
            pill(L("Swap the Two Frames", zh: "两格对调"), enabled: pair.left != nil || pair.right != nil) {
                session.swapHoles()
            }
            Spacer(minLength: 0)
        }
        note(L("Click a frame on the canvas to pick it; right-click it to replace or crop it.",
               zh: "在画布上点击一格即可选中；右键可替换或裁剪。"))
    }

    // MARK: a frame in its hole

    @ViewBuilder private func holeRows(_ side: HalfFramePair.Side) -> some View {
        if let hole = pair[side] {
            RailSubhead(L("Crop under the hole", zh: "格内裁剪"))
            HStack(spacing: 8) {
                pill(session.pairPlacing ? L("Done", zh: "完成") : L("Crop on the Canvas", zh: "在画布上裁剪"),
                     enabled: hole.exists) { session.togglePairPlacing() }
                pill(L("Turn", zh: "旋转")) {
                    session.setPlacement(side) { $0.quarterTurns = ($0.quarterTurns + 1) % 4 }
                }
                Spacer(minLength: 0)
            }
            ScrubSlider(label: L("Scale", zh: "缩放"), sublabel: "×",
                        value: Binding(get: { session.shownPlacement(side)?.scale ?? hole.placement.scale },
                                       set: { v in session.previewPlacement(side) { $0.scale = v } }),
                        range: HalfFramePair.Placement.scaleRange, zero: 1, snap: 0.05,
                        format: { String(format: "%.2f", $0) })
            ScrubSlider(label: L("Across", zh: "横向"),
                        value: Binding(get: { session.shownPlacement(side)?.x ?? hole.placement.x },
                                       set: { v in session.previewPlacement(side) { $0.x = v } }),
                        range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) })
            ScrubSlider(label: L("Up / down", zh: "纵向"),
                        value: Binding(get: { session.shownPlacement(side)?.y ?? hole.placement.y },
                                       set: { v in session.previewPlacement(side) { $0.y = v } }),
                        range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) })
            HStack(spacing: 8) {
                pill(L("Replace…", zh: "替换…")) { session.pairPicker = side }
                pill(L("Remove", zh: "移除")) { session.setHole(side, to: nil) }
                Spacer(minLength: 0)
            }
            note(L("Its metering, exposure and white balance are in Input / Camera on the right; its print in Enlarger.",
                   zh: "这一格的测光、曝光与白平衡在右侧“输入 / 相机”中；印放在“放大机”中。"))
        } else {
            HStack(spacing: 8) {
                pill(L("Add Frame…", zh: "添加照片…")) { session.pairPicker = side }
                Spacer(minLength: 0)
            }
            note(L("An empty hole is unexposed film. Fill both to export the pair.",
                   zh: "空格是未曝光的胶片。两格都放入照片后才能导出。"))
        }
    }

    // MARK: parts

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Navigator's *Fit* pill, the rail's one button shape.
    private func pill(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.value)
                .foregroundStyle(Theme.text)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12)
                .frame(height: Theme.Metric.controlHeight)
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
    }
}

/// How the camera was held for a pair: level (frames side by side) or turned
/// (one above the other).
enum PairHold: String, CaseIterable, Identifiable, Sendable {
    case level, turned
    var id: String { rawValue }
}

/// Add Frame: the open folder's frames, drawn as the filmstrip draws them,
/// with a name filter. A frame already in this pair is dimmed and marked; it
/// can still be chosen (the same frame twice is allowed).
struct PairFramePicker: View {
    let frames: [Frame]
    let used: Set<String>
    let choose: (URL) -> Void
    @State private var filter = ""

    private var shown: [Frame] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? frames : frames.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Filter by name", zh: "按文件名筛选"), text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.Font.label)
                .padding(.horizontal, 8).frame(height: 24)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 8), count: 4), spacing: 8) {
                    ForEach(shown) { frame in
                        let isUsed = used.contains(frame.id.standardizedFileURL.path)
                        VStack(spacing: 3) {
                            CropMaskedThumbnail(url: frame.id, geometry: .default, maxPixel: 192) { image in
                                if let image {
                                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                } else { Theme.well }
                            }
                            .frame(width: 96, height: 72)
                            .opacity(isUsed ? 0.45 : 1)
                            Text(isUsed ? L("In this pair", zh: "已在此拼接中") : frame.name)
                                .font(Theme.Font.meta).foregroundStyle(Theme.Ink.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 96)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { choose(frame.id) }
                        .help(frame.name)
                    }
                }
            }
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: 4 * 96 + 3 * 8 + 24)
        .background(Theme.card)
    }
}
