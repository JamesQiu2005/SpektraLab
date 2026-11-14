//  LayersPanel.swift — the 图层 (Layers) panel: the card under the histogram, in 冲洗 and 编辑 alike
//  (design/layers/LAYERS-SPEC.md §2–§4, PRD-D §3.7).
//
//  One row per thing the page's controls can be about: 胶片 — the whole, always first — and under it a pair's
//  two frames or a double exposure's two exposures, the top over the bottom as they lie. A single frame has one
//  row and nothing to choose, so its panel is the head's one line. The pick is the session's
//  (`OpenFrameSession.layerPick`): what the column under the panel shows follows it (`LayerPage`), and it is
//  kept across 冲洗 and 编辑. A double's rows carry the eye (one exposure alone: the page's state, nothing
//  written) and its share, and Balance is the panel's own row under them — it is about both exposures, so it
//  is on neither's page. Which rows, their names, the eye's states and the card's height are `LayerRules`.

import SwiftUI

/// What of the 图层 panel is the page's and not the piece's: the picture being arranged, the exposure a double
/// was last about, the sheet that asks for a photograph. One for the window — there is one develop page.
@MainActor @Observable final class LayersStage {
    static let shared = LayersStage()

    struct Arranging: Equatable {
        var frame: LibraryFrame.ID
        var pick: LayerPick
    }
    /// 摆放 is open on this picture (`ArrangeStage`).
    var arranging: Arranging?
    /// The exposure a double's page was last about: what 裁剪 arranges with 胶片 picked (`LayerRules.arranges`).
    var lastExposure: [LibraryFrame.ID: DoubleExposure.Position] = [:]

    struct Asking: Identifiable, Equatable {
        var frame: LibraryFrame.ID
        var pick: LayerPick
        var id: String { "\(frame)-\(pick.key)" }
    }
    /// A photograph is being asked for, for this row (`LayerPhotoPicker`).
    var asking: Asking?
    /// Export was refused, and why: the alert over the page (`LayerRules.refusal`).
    var refused: Asking?
    /// The panel's foot line's height as drawn (it wraps): what the column lays the card by (`LayersPanel.height`).
    var footHeight: CGFloat = 26
    /// A mask layer asked to be renamed from the head's ⋯ (its row starts the field when it sees its id).
    var renaming: UUID?
    #if DEBUG
    /// The card drawn folded for `--masks-check`'s capture of the folded head, without writing the fold, which
    /// `DevelopPanelPrefs.shared` keeps in the app's own defaults domain (a check's suite does not reach it; trap 24).
    var foldedForCheck = false
    #endif

    func arranging(_ frame: LibraryFrame.ID) -> LayerPick? { arranging?.frame == frame ? arranging?.pick : nil }
}

extension OpenFrameSession {
    /// What this page is of, as the 图层 panel reads it.
    var layerPiece: LayerPiece {
        if let double { return .double(double) }
        if FeatureFlags.halfFramePair, let pair { return .pair(pair) }
        return .single
    }

    /// **The row picked**: the one pick the views read, whichever piece it is of (the pair's `layer`, the
    /// double's `doubleLayer`). 胶片 for a single frame.
    var layerPick: LayerPick {
        switch layerPiece {
        case .single: LayerRules.held(maskPick.map(LayerPick.mask) ?? .film, in: .single, layers: edit.layers)
        case .pair: LayerPick(layer)
        case .double: LayerPick(doubleLayer)
        }
    }

    /// Pick a row. Nothing is developed for it: a pick changes what the controls are about.
    func pick(row: LayerPick) {
        stageNotice = nil
        switch layerPiece {
        case .single: maskPick = row.maskID
        case .pair: if let l = row.pairLayer { pick(l) }
        case .double:
            if let l = row.doubleLayer { pickLayer(l) }
            if case .exposure(let p) = row { LayersStage.shared.lastExposure[frameID] = p }
        }
    }
}

struct LayersPanel: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    var prefs = DevelopPanelPrefs.shared
    var stage = LayersStage.shared
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library

    /// The card's margin in the column: none above (the histogram's is over it), the histogram's below.
    static let margin = HistogramPanel.margin

    /// The panel's height as the column lays it: the card (`LayerRules.height`, by the mask layers it lists), its foot
    /// line where it has one (measured where it is drawn, `LayersStage.footHeight`), and the margin.
    @MainActor static func height(_ piece: LayerPiece, session: OpenFrameSession, prefs: DevelopPanelPrefs = .shared) -> CGFloat {
        let masks = LayerRules.takesMasks(piece) ? LayerRules.maskRows(session.maskLayers).count : 0
        let folded = folded(piece, prefs: prefs)
        let foot = folded || foot(piece, session: session) == nil ? 0 : LayersStage.shared.footHeight
        return LayerRules.height(piece, masks: masks, folded: folded) + foot + margin
    }

    /// The line at the panel's foot: why a pair or a double has no mask layer (MASKS-SPEC §4.4), or why the last layer
    /// act was refused (8 a stage, an export reading the frame). Nil: no foot. Shown only with the mask panel.
    @MainActor static func foot(_ piece: LayerPiece, session: OpenFrameSession) -> String? {
        guard FeatureFlags.maskLayers else { return nil }
        return session.maskNote ?? LayerRules.maskRefusal(piece)
    }

    private var piece: LayerPiece { session.layerPiece }
    private var folded: Bool { Self.folded(piece, prefs: prefs) }

    @MainActor static func folded(_ piece: LayerPiece, prefs: DevelopPanelPrefs = .shared) -> Bool {
        #if DEBUG
        if LayersStage.shared.foldedForCheck { return true }
        #endif
        return prefs.layersCollapsed || LayerRules.isOneLine(piece)
    }
    private var has: (UUID) -> Bool { { library.frame($0) != nil } }
    private var rows: [LayerRow] {
        LayerRules.rows(piece, layers: session.chromeMaskLayers, lensCorrection: session.edit.decode.lensCorrection,
                        lensWord: session.lensWord,
                        alone: session.alone, has: has)
    }
    private var maskCount: Int { rows.filter { $0.pick.maskID != nil }.count }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            head(rows)
            if !folded {
                // 主体 · 背景 · 人 and the tools: a single photograph's (MASKS-SPEC §4.4: not shown on a pair or a double).
                if LayerRules.takesMasks(piece) {
                    MaskSelectionRow(session: session)
                    MaskToolRow(session: session, longEdge: frame.originalSize.longEdge)
                }
                list(rows)
                    .padding(.bottom, LayerRules.Metric.underRows)
                if LayerRules.takesMasks(piece), maskCount > 0 {
                    MaskOpacityRow(session: session)
                    MaskButtonsRow(session: session)
                }
                if LayerRules.showsBalance(piece), case .double(let double) = piece {
                    LayerBalance(frameID: frame.id, double: double)
                }
                if let foot = Self.foot(piece, session: session) {
                    Text(foot).font(Theme.Font.ui(12)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 10)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { stage.footHeight = $0 }
                        .accessibilityIdentifier("layers.foot")
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.plot))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, Self.margin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layers.panel")
        // An exposure that has gone takes its eye with it.
        .onChange(of: piece) { _, now in
            if case .double(let d) = now, LayerRules.alone(session.alone, in: d, has: has) != session.alone { session.alone = nil }
        }
    }

    /// The rows: 胶片, a pair's frames or a double's exposures, a photograph's mask layers. Past five rows they scroll
    /// inside 150 and the card stops growing (MASKS-SPEC §2).
    @ViewBuilder private func list(_ rows: [LayerRow]) -> some View {
        let content = VStack(spacing: 0) {
            ForEach(rows) { row in
                if let id = row.pick.maskID, let layer = session.chromeMaskLayers?[id] {
                    MaskLayerRowView(row: row, layer: layer, picked: row.pick == session.layerPick, source: frame.originalSize,
                                     session: session)
                } else {
                    pictureRow(row)
                }
            }
        }
        if LayerRules.takesMasks(piece), rows.count > 5 {
            ScrollView(.vertical) { content }
                .scrollIndicators(.automatic)
                .frame(height: LayerRules.listHeight(masks: maskCount))
        } else {
            content
        }
    }

    private func pictureRow(_ row: LayerRow) -> some View {
        // 摆放 open: a picture's row moves 摆放 to that picture; 胶片 stands down until it closes.
        let arranging = stage.arranging(frame.id) != nil
        return LayerRowView(row: row, picked: row.pick == session.layerPick, picture: picture(row),
                            pick: {
                                guard arranging else { session.pick(row: row.pick); return }
                                guard LayerRules.arrangeable(row) else { return }
                                session.pick(row: row.pick)
                                stage.arranging = .init(frame: frame.id, pick: row.pick)
                            },
                            eye: { eye(row) }, add: { stage.asking = .init(frame: frame.id, pick: row.pick) })
            .opacity(arranging && !LayerRules.arrangeable(row) ? 0.4 : 1)
            .contextMenu { if !arranging { LayerMenu(session: session, frame: frame, row: row.pick) } }
    }

    private func head(_ rows: [LayerRow]) -> some View {
        let single = LayerRules.isOneLine(piece)
        let summary = LayerRules.summary(session.layerPick, in: rows)
        return HStack(spacing: 0) {
            Button {
                guard !single else { return }
                withAnimation(.easeOut(duration: 0.2)) { prefs.layersCollapsed.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Icon(.chevronDown, size: 13, color: Theme.secondaryText)
                        .rotationEffect(.degrees(folded ? -90 : 0))
                        .opacity(single ? 0 : 1)
                    Text(L("Layers")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    if folded {
                        Text(summary).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: LayerRules.Metric.head, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Layers"))
            // "3 个图层，选中渐变 1" (MASKS-SPEC §9): every row (胶片 is a layer) and the picked one's name; a pair's and a
            // double's as before.
            .accessibilityValue(LayerRules.takesMasks(piece)
                                ? L("\(rows.count) layers, \(rows.first { $0.pick == session.layerPick }?.name ?? "") picked") : summary)
            .accessibilityHint(single ? "" : folded ? L("Shows the layers") : L("Folds the layers away"))
            .accessibilityIdentifier("layers.fold")
            if FeatureFlags.maskLayers, !folded {
                // + − ⋯ (MASKS-SPEC §2): ⋯ is the picked mask layer's menu on a photograph, today's on a pair or a double.
                // Folded, the head is its title and its words alone (drawing 12's inset): nothing to act on is shown.
                MaskHeadButtons(takesMasks: LayerRules.takesMasks(piece), picked: session.layerPick.maskID,
                                add: { session.makeLayer() },
                                remove: { if let id = session.layerPick.maskID { session.removeLayer(id) } },
                                menu: { headMenu },
                                menuEnabled: !piece.isSingle || session.chromeMaskLayer != nil)
                    .padding(.leading, 8)
            } else if !single {
                Menu { LayerMenu(session: session, frame: frame, row: session.layerPick) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.leading, 6)
                .accessibilityLabel(L("Layer actions"))
                .accessibilityIdentifier("layers.menu")
            }
        }
        .padding(.leading, 14).padding(.trailing, FeatureFlags.maskLayers ? (folded ? 14 : 10) : single ? 14 : 8)
        .frame(height: LayerRules.Metric.head)
    }

    @ViewBuilder private var headMenu: some View {
        if let layer = session.chromeMaskLayer {
            MaskLayerMenu(session: session, layer: layer, rename: { LayersStage.shared.renaming = layer.id })
        } else {
            LayerMenu(session: session, frame: frame, row: session.layerPick)
        }
    }

    private func picture(_ row: LayerRow) -> PictureRef? {
        row.photograph.flatMap { library.frame($0)?.picture }
    }

    private func eye(_ row: LayerRow) {
        guard case .exposure(let position) = row.pick else { return }
        model.showAlone(frame.id, LayerRules.eyeTapped(position, alone: session.alone))
    }
}

/// One row of the panel: the eye's slot, the thumbnail, the name, and what trails it.
struct LayerRowView: View {
    let row: LayerRow
    let picked: Bool
    let picture: PictureRef?
    let pick: () -> Void
    let eye: () -> Void
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            eyeSlot.frame(width: 20, height: 28)
            thumbnail.frame(width: 30, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(.leading, 6)
            Text(row.name)
                .font(Theme.Font.ui(13, picked ? .semibold : .medium))
                .foregroundStyle(picked ? Theme.onSelection : row.isEmpty ? Theme.secondaryText : Theme.text)
                .lineLimit(1)
                .padding(.leading, 10)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 6).padding(.trailing, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(picked ? Theme.selection : hovering ? Theme.card : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .frame(height: LayerRules.Metric.row)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(value)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, pick)
        .accessibilityIdentifier("layers.row." + row.pick.key)
    }

    /// What VoiceOver says after the name: empty, gone, its share, alone.
    private var value: String {
        var parts: [String] = []
        switch row.content {
        case .empty: parts.append(L("Empty"))
        case .missing: parts.append(L("Not in the library"))
        default: break
        }
        if let share = row.shareText { parts.append(share) }
        if row.eye == .alone { parts.append(L("shown alone")) }
        if row.eye == .out { parts.append(L("not shown")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var eyeSlot: some View {
        if row.eye != .none, case .exposure(let position) = row.pick {
            Button(action: eye) {
                Image(systemName: row.eye == .out ? "eye.slash" : "eye")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(row.eye == .alone ? Theme.accent : picked ? Theme.onSelection.opacity(row.eye == .out ? 0.45 : 0.8)
                                     : row.eye == .out ? Theme.dim : Theme.secondaryText)
                    .frame(width: 20, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.eye == .alone ? L("Show Both Exposures") : L("Show Alone"))
            .accessibilityLabel(row.eye == .alone ? L("Show Both Exposures") : L("Show Alone"))
            .accessibilityIdentifier("layers.eye." + (position == .top ? "top" : "bottom"))
        }
    }

    @ViewBuilder private var thumbnail: some View {
        switch row.content {
        case .film:
            ZStack {
                (picked ? Theme.onSelection.opacity(0.12) : Theme.card)
                Image(systemName: "film").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(picked ? Theme.onSelection : Theme.secondaryText)
            }
        case .photograph:
            if let picture { FramePicture(picture: picture, pointSize: 30) } else { Theme.card }
        case .missing:
            ZStack {
                Theme.card
                Image(systemName: "questionmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
            }
        case .empty:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(picked ? Theme.onSelection.opacity(0.5) : Theme.dim, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))        case .mask:
            // A mask layer's row is `MaskLayerRowView`'s, never this one's.
            Color.black
        }
    }

    @ViewBuilder private var trailing: some View {
        if row.isEmpty {
            Button(action: add) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(picked ? Theme.onSelection : Theme.accent)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Add a photograph"))
            .accessibilityLabel(L("Add a photograph"))
            .accessibilityIdentifier("layers.add." + row.pick.key)
        } else if case .missing = row.content {
            Text(L("Not in the library")).font(Theme.Font.ui(12, .medium))
                .foregroundStyle(picked ? Theme.onSelection.opacity(0.7) : Theme.dim).lineLimit(1)
        } else if let share = row.shareText {
            Text(share).font(Theme.Font.ui(12, .medium).monospacedDigit())
                .foregroundStyle(picked ? Theme.onSelection.opacity(0.75) : Theme.secondaryText).lineLimit(1)
        }
    }
}

/// Balance, the panel's own row: the top's share of the frame's light, developed while it is dragged (R2).
struct LayerBalance: View {
    let frameID: LibraryFrame.ID
    let double: DoubleExposure
    @Environment(AppServices.self) private var model
    @State private var dragging = false

    private var share: Double { double.balance ?? 0.5 }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 0.5)
            // The one slider's parts (`ValueSlider`): its field reads and takes a percentage, which the whole
            // slider's field cannot (it parses a bare number as the value), and "Top 50 %" does not fit 62 units.
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(L("Balance")).font(Theme.Font.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    // Whose share the number is: the top's.
                    Text(L("Top’s share")).font(Theme.Font.ui(10.5)).foregroundStyle(Theme.dim)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                    .frame(width: 64, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.setDoubleBalance(frameID, 0.5) }
                    .accessibilityHidden(true)
                SliderTrack(value: Binding(get: { share },
                                           set: { s in
                                               if dragging { model.balanceDrag(frameID, .changed, to: s) } else { model.setDoubleBalance(frameID, s) }
                                           }),
                            range: BalanceTrack.range, rest: 0.5, step: 0.01, detentAtRest: true,
                            onEditingChanged: { down in
                                guard down != dragging else { return }
                                dragging = down
                                model.balanceDrag(frameID, down ? .began : .ended)
                            })
                    .frame(height: 28)
                SliderField(shown: "\(Int((share * 100).rounded())) %", width: 62,
                            parse: { SliderField.number(from: $0.replacingOccurrences(of: "%", with: "")).map { $0 / 100 } },
                            commit: { model.setDoubleBalance(frameID, $0.clamped(to: BalanceTrack.range)) })
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .padding(.bottom, 4)
        }
        .help(L("Top’s share"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Balance"))
        .accessibilityValue(BalanceTrack.valueText(share))
        .accessibilityIdentifier("layers.balance")
    }
}

/// What a row can be asked to do: the head's menu, and the row's own on a secondary click.
struct LayerMenu: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let row: LayerPick
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    private var stage: LayersStage { .shared }
    private var has: (UUID) -> Bool { { library.frame($0) != nil } }

    var body: some View {
        switch session.layerPiece {
        case .single: EmptyView()
        case .pair(let pair): pairItems(pair)
        case .double(let double): doubleItems(double)
        }
    }

    @ViewBuilder private func arrange(_ piece: LayerPiece) -> some View {
        let target = LayerRules.arranges(row, piece: piece, last: stage.lastExposure[frame.id], has: has)
        Button {
            guard let target else { return }
            session.pick(row: target)
            stage.arranging = .init(frame: frame.id, pick: target)
        } label: { Label(L("Arrange") + "…", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
        .disabled(target == nil)
    }

    @ViewBuilder private func pairItems(_ pair: HalfFramePair) -> some View {
        arrange(.pair(pair))
        Button {
            model.changePair(frame.id) { piece, look in piece.swap(look: &look.params) }
        } label: { Label(L("Swap the Two Frames"), systemImage: "arrow.left.arrow.right") }
        .disabled(!pair.isFilled)
        if case .frame(let side) = row {
            Divider()
            Button { stage.asking = .init(frame: frame.id, pick: row) } label: {
                Label(pair[side] == nil ? L("Add Frame") + "…" : L("Replace Photograph…"), systemImage: "photo.on.rectangle")
            }
            Button(role: .destructive) {
                model.changePair(frame.id) { piece, look in piece.fill(side, with: nil, look: &look.params) }
            } label: { Label(L("Remove Photograph"), systemImage: "minus.circle") }
            .disabled(pair[side] == nil || !pair.mayChange(side) || pair[side.other] == nil)
        }
    }

    @ViewBuilder private func doubleItems(_ double: DoubleExposure) -> some View {
        arrange(.double(double))
        if case .exposure(let position) = row, double[position] != nil {
            Button { model.flipDouble(frame.id, position) } label: {
                Label(L("Flip Horizontally"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            if LayerRules.eyes(double, has: has) {
                Button { model.showAlone(frame.id, LayerRules.eyeTapped(position, alone: session.alone)) } label: {
                    Label(session.alone == position ? L("Show Both Exposures") : L("Show Alone"), systemImage: "eye")
                }
            }
        }
        Button { model.swapDouble(frame.id) } label: {
            Label(L("Swap Top and Bottom"), systemImage: "arrow.up.arrow.down")
        }
        .disabled(!double.isFilled)
        if case .exposure(let position) = row {
            Divider()
            Button { stage.asking = .init(frame: frame.id, pick: row) } label: {
                Label(double[position] == nil ? L("Add Exposure") + "…" : L("Replace Photograph…"), systemImage: "photo.on.rectangle")
            }
            .disabled(double[position] != nil && !double.mayChange(position) && library.frame(double[position]?.frame) != nil)
            Button(role: .destructive) { model.removeDouble(frame.id, position) } label: {
                Label(L("Remove Photograph"), systemImage: "minus.circle")
            }
            .disabled(double[position] == nil || double[position.other] == nil || !double.mayChange(position))
        }
    }
}
