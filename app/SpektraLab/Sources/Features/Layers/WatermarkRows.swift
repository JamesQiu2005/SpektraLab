//  WatermarkRows.swift — a watermark in the 图层 panel (PRD-8; the owner, 2026-11-15: a watermark
//  is treated as a layer): its row, its menu, and the head's disc that places one.
//
//  - **The row** is a mask row's (MASKS-SPEC §4.2, `MaskLayerRowView`): the eye a real switch, written with the edit
//    (`WatermarkPlacement.on`, written only when off), the mark's thumbnail on the mid-grey checkerboard, its library
//    name — no rename: the name is the library's, renamed in Settings — and at its end its opacity when not 100 and its
//    stage as a word (成片 · 底片). A mark the library no longer has: its name says so, its thumbnail a question mark.
//  - **The menu** (a secondary click, and the head's ⋯ with the row picked): Show / Hide, Bring Forward / Send Backward
//    among the watermark rows (z-order, one step each), Delete.
//  - **The head's disc** (a signature, beside + and −): the library's marks, a click places one centred on the picture;
//    the last item 管理水印… opens Settings › Watermarks; with an empty library it says so and offers only that item. At
//    four the marks are disabled with the reason (W2); on a pair or a double the disc is disabled with its own
//    sentence (W5, `WatermarkRules.refusal`). + itself still makes a mask layer at a click, as the masks' checks and a
//    mask layer's habit expect: the watermark's way in is its own disc, not a menu on +.

import SwiftUI
import UIKit

struct WatermarkLayerRowView: View {
    let row: LayerRow
    let placement: WatermarkPlacement
    let picked: Bool
    let session: OpenFrameSession
    @State private var hovering = false

    private var off: Bool { !placement.on }
    private var ink: Color { picked ? Theme.onSelection : Theme.text }

    var body: some View {
        HStack(spacing: 0) {
            eye.frame(width: 20, height: 28)
            WatermarkThumbnail(mark: placement.mark, cell: 3)
                .frame(width: 30, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(picked ? Theme.onSelection.opacity(0.35) : Theme.rule, lineWidth: 0.5))
                .opacity(off && !picked ? Theme.disabledOpacity : 1)
                .padding(.leading, 6)
            Text(row.name)
                .font(Theme.Font.ui(13, picked ? .semibold : .medium))
                .foregroundStyle(ink)
                .opacity(off && !picked ? Theme.disabledOpacity : 1)
                .lineLimit(1)
                .padding(.leading, 10)
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
        .onTapGesture { session.pick(row: row.pick); session.watermarkSelected = true }
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .frame(height: LayerRules.Metric.row)
        .contextMenu { WatermarkLayerMenu(session: session, placement: placement) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(value)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { session.pick(row: row.pick) }
        .accessibilityAction(named: L("Bring Forward")) { session.reorderWatermark(placement.id, by: 1) }
        .accessibilityAction(named: L("Send Backward")) { session.reorderWatermark(placement.id, by: -1) }
        .accessibilityAction(named: L("Delete Watermark")) { session.removeWatermark(placement.id) }
        .accessibilityIdentifier("layers.row." + row.key)
    }

    /// "成片，不透明度 60 %，已启用", as a mask row says its own.
    private var value: String {
        let percent = "\(Int((min(max(placement.opacity, 0), 1) * 100).rounded())) %"
        return L("\(placement.stage.word), opacity \(percent), \(placement.on ? L("on") : L("off"))")
    }

    private var eye: some View {
        Button { session.changeWatermark(placement.id) { $0.on.toggle() } } label: {
            Image(systemName: off ? "eye.slash" : "eye").font(.system(size: 11, weight: .medium))
                .foregroundStyle(picked ? Theme.onSelection.opacity(off ? 0.45 : 0.8) : Theme.secondaryText.opacity(off ? 0.6 : 0.75))
                .frame(width: 20, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Show Layer"))
        .accessibilityLabel(L("Show Layer"))
        .accessibilityValue(placement.on ? L("on") : L("off"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("layers.eye." + row.key)
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            if case .watermark(_, true) = row.content {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            if let opacity = row.opacityText {
                Text(opacity).font(Theme.Font.ui(12, .medium).monospacedDigit())
                    .foregroundStyle(picked ? Theme.onSelection.opacity(0.75) : Theme.secondaryText).lineLimit(1)
            }
            Text(placement.stage.word).font(Theme.Font.ui(12, .medium))
                .foregroundStyle(picked ? Theme.onSelection.opacity(0.75) : Theme.dim).lineLimit(1)
        }
        .opacity(off && !picked ? Theme.disabledOpacity : 1)
    }
}

/// A watermark row's menu: the secondary click's and the head's ⋯ with the row picked.
struct WatermarkLayerMenu: View {
    let session: OpenFrameSession
    let placement: WatermarkPlacement

    var body: some View {
        let list = session.edit.watermarks
        let i = list.firstIndex { $0.id == placement.id } ?? 0
        Button { session.changeWatermark(placement.id) { $0.on.toggle() } } label: {
            Label(placement.on ? L("Hide Watermark") : L("Show Watermark"), systemImage: placement.on ? "eye.slash" : "eye")
        }
        Divider()
        Button { session.reorderWatermark(placement.id, by: 1) } label: { Label(L("Bring Forward"), systemImage: "square.2.layers.3d.top.filled") }
            .disabled(i >= list.count - 1)
        Button { session.reorderWatermark(placement.id, by: -1) } label: { Label(L("Send Backward"), systemImage: "square.2.layers.3d.bottom.filled") }
            .disabled(i == 0)
        Divider()
        Button(role: .destructive) { session.removeWatermark(placement.id) } label: { Label(L("Delete Watermark"), systemImage: "trash") }
    }
}

/// The head's disc that places a watermark: the library's marks, and 管理水印….
struct WatermarkAddDisc: View {
    let session: OpenFrameSession
    @Environment(AppServices.self) private var model

    var body: some View {
        let store = model.watermarks
        let refusal = WatermarkRules.refusal(isComposite: !session.takesWatermarks)
        let full = !WatermarkGeometry.canAdd(to: session.edit.watermarks)
        Menu {
            if store.marks.isEmpty {
                Text(L("No watermarks yet"))
            } else {
                if full { Text(L("A photo holds at most 4 watermarks.")) }
                ForEach(store.marks) { mark in
                    Button { session.addWatermark(mark) } label: { Text(mark.name) }
                        .disabled(full)
                }
            }
            Divider()
            Button(L("Manage Watermarks…")) { Self.openSettings(model) }
        } label: {
            Image(systemName: "signature").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 22, height: 22).background(Theme.card, in: Circle()).contentShape(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .opacity(refusal == nil ? 1 : Theme.disabledOpacity)
        .disabled(refusal != nil)
        .help(refusal ?? L("Add Watermark"))
        .accessibilityLabel(L("Add Watermark"))
        .accessibilityHint(refusal ?? "")
        .accessibilityIdentifier("layers.watermark.add")
    }

    /// Settings › Watermarks, over the window (as the menu's Settings… opens Settings).
    static func openSettings(_ model: AppServices) {
        model.router.dismissAllSheets()
        SettingsRequest.next = .watermarks
        model.router.show(.settings)
    }
}
