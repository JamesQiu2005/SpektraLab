//  PairSection.swift — the Half-Frame Pair, at the top of the left rail.
//
//  The piece's three layers as the design lists them (proposal §2–§3): Film,
//  Left hole, Right hole. One is picked at a time and the rows under the list
//  are that layer's. Film holds what the piece shares; a hole holds its frame
//  and where the picture sits under it. Built from the rail's own parts.

import SwiftUI

struct PairSection: View {
    @Bindable var session: Session
    static let key = "pair"
    @State private var adding: HalfFramePair.Side?

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
            .frame(width: 18, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
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
        case .left: L("Left hole", zh: "左格")
        case .right: L("Right hole", zh: "右格")
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
        ScrubSlider(label: L("Spacing", zh: "间距"), sublabel: "mm",
                    value: Binding(get: { pair.effectiveSpacingMM }, set: { session.setPairSpacing($0) }),
                    range: HalfFramePair.spacingRange, zero: 1.0, snap: 0.1,
                    format: { String(format: "%.1f", $0) }, disabled: pair.onStrip)
            .help(pair.onStrip ? L("With Film Edge on, the camera's advance sets the gap.",
                                   zh: "开启片边后，间距由相机过片决定。") : "")
        HStack(spacing: 8) {
            pill(L("Swap Left and Right", zh: "左右对调"), enabled: pair.left != nil || pair.right != nil) {
                session.swapHoles()
            }
            Spacer(minLength: 0)
        }
        note(L("Stock, paper, enlarger and Film Edge are the piece's: one film, one print. Each hole keeps its own frame, placement and exposure.",
               zh: "胶片、相纸、放大机与片边属于整条胶片：一条胶片，一次印放。每一格保留各自的照片、位置与曝光。"))
    }

    // MARK: a hole

    @ViewBuilder private func holeRows(_ side: HalfFramePair.Side) -> some View {
        if let hole = pair[side] {
            ScrubSlider(label: L("Exposure", zh: "曝光"), sublabel: L("stops", zh: "档"),
                        value: Binding(get: { hole.exposureEV }, set: { session.setHoleExposure(side, $0) }),
                        range: -3...3, snap: 0.25, format: { String(format: "%+.2f", $0) })
            RailSubhead(L("Placement under the hole", zh: "画面在格内的位置"))
            ScrubSlider(label: L("Scale", zh: "缩放"), sublabel: "×",
                        value: Binding(get: { hole.placement.scale },
                                       set: { v in session.setPlacement(side) { $0.scale = v } }),
                        range: HalfFramePair.Placement.scaleRange, zero: 1, snap: 0.05,
                        format: { String(format: "%.2f", $0) })
            ScrubSlider(label: L("Across", zh: "横向"),
                        value: Binding(get: { hole.placement.x },
                                       set: { v in session.setPlacement(side) { $0.x = v } }),
                        range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) })
            ScrubSlider(label: L("Up / down", zh: "纵向"),
                        value: Binding(get: { hole.placement.y },
                                       set: { v in session.setPlacement(side) { $0.y = v } }),
                        range: -1...1, snap: 0.05, format: { String(format: "%+.2f", $0) })
            HStack(spacing: 8) {
                pill(L("Turn", zh: "旋转")) {
                    session.setPlacement(side) { $0.quarterTurns = ($0.quarterTurns + 1) % 4 }
                }
                pill(L("Reset", zh: "复位"), enabled: hole.placement != HalfFramePair.Placement()) {
                    session.setPlacement(side) { $0 = HalfFramePair.Placement() }
                }
                Spacer(minLength: 0)
            }
            RailSubhead(L("Frame", zh: "照片"))
            HStack(spacing: 8) {
                pill(L("Replace…", zh: "替换…")) { adding = side }
                    .popover(isPresented: picking(side), arrowEdge: .trailing) { picker(side) }
                pill(L("Remove", zh: "移除")) { session.setHole(side, to: nil) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                pill(L("Open Frame Alone", zh: "单独打开照片"), enabled: hole.exists) { session.click(hole.url) }
                Spacer(minLength: 0)
            }
            note(L("White balance and lens correction are the frame's own: open it alone to change them.",
                   zh: "白平衡与镜头校正跟随照片本身：单独打开照片即可修改。"))
        } else {
            HStack(spacing: 8) {
                pill(L("Add Frame…", zh: "添加照片…")) { adding = side }
                    .popover(isPresented: picking(side), arrowEdge: .trailing) { picker(side) }
                Spacer(minLength: 0)
            }
            note(L("An empty hole is unexposed film. Fill both holes to export the pair.",
                   zh: "空格是未曝光的胶片。两格都放入照片后才能导出。"))
        }
    }

    private func picking(_ side: HalfFramePair.Side) -> Binding<Bool> {
        Binding(get: { adding == side }, set: { if !$0 { adding = nil } })
    }

    private func picker(_ side: HalfFramePair.Side) -> some View {
        PairFramePicker(frames: session.pairCandidates,
                        used: Set([pair.left?.path, pair.right?.path].compactMap { $0 })) { url in
            adding = nil
            session.setHole(side, to: url)
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
                .padding(.horizontal, 12)
                .frame(height: Theme.Metric.controlHeight)
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
    }
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
