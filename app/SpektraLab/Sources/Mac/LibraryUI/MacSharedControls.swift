//  MacSharedControls.swift — the window's one control group (the owner, 2026-10-26).
//
//  "The library's existing control group … stays, and becomes the shared bar of the unified window in
//  all three modes." Lifted out of `MacLibraryGrid`'s header, unchanged in what it draws: the LEFT
//  COLUMN's toggle, the viewer | grid split (⌥⌘V — the browser's own wall drags the same width), the
//  loupe (the chosen pictures on the Light Table), the sort and its direction.
//
//  It is the same view in 图库 and in 冲洗/编辑: in the library it stands at the leading edge of the
//  browser's header, where it has stood since 2026-10-23; in the develop page it stands at the leading
//  edge of the picture bar. Only two things differ, and both are the page's to say: which pane the
//  column toggle folds away, and what the loupe hands on.

import SwiftUI

struct MacSharedControls: View {
    let store: any MacLibraryData
    let browser: MacLibraryBrowser
    /// The LEFT COLUMN's toggle: the library's sidebar in 图库, the tools column in 冲洗/编辑. One
    /// control, one meaning — the window's left pane is there or it is not.
    let columnShown: Bool
    let toggleColumn: () -> Void
    /// The loupe: these pictures on the Light Table (the chosen ones; the page decides how).
    let lightTable: ([MacImage]) -> Void
    /// The grid takes the window (`MacLibraryBrowser.fullGrid`): the viewer stands aside and the browser —
    /// its cells, the size slider, the count — has everything right of the column (the owner, 2026-10-26).
    let fullGrid: () -> Void
    /// 裁剪 faces the mode's own crop (the owner, 2026-10-26: it is persistent — "one can also crop
    /// while he's browsing the pictures"): the pre-film crop (`FrameEdit.geometry`, what the engine cuts
    /// before the film sees it) in 图库 and 冲洗, the finished picture's own (`printCrop`) in 编辑. Nil
    /// where the page has no crop to offer (a pair's whole piece, a picture with no frame).
    var crop: (() -> Void)? = nil
    var cropping = false
    var cropEnabled = true

    var body: some View {
        HStack(spacing: MacMetric.pt(8)) {
            Button(action: toggleColumn) {
                Image(systemName: "sidebar.left").font(MacMetric.font(14)).foregroundStyle(Theme.secondaryText)
                    .frame(width: MacMetric.pt(26), height: MacMetric.pt(22)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Sidebar"))
            .accessibilityLabel(L("Sidebar"))
            .accessibilityIdentifier("mac.bar.column")
            // The library's viewer and the develop page's browser are the same split: on, the picture has
            // a browser beside it; off, the picture has the window.
            Button { browser.viewerShown.toggle() } label: { MacViewerGlyph(on: browser.viewerShown) }
            .buttonStyle(.plain)
            .help(L("Viewer"))
            .accessibilityLabel(L("Viewer"))
            .accessibilityAddTraits(browser.viewerShown ? .isSelected : [])
            .accessibilityIdentifier("mac.library.viewer")
            // The grid, whole (G): the viewer steps aside and the browser has the window — 图库's third
            // layout, beside the viewer-with-browser and the browser alone. Lit while it is on.
            Button(action: fullGrid) {
                Image(systemName: "square.grid.2x2").font(MacMetric.font(14))
                    .foregroundStyle(browser.fullGrid ? Theme.accent : Theme.secondaryText)
                    .frame(width: MacMetric.pt(26), height: MacMetric.pt(22)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Grid"))
            .accessibilityLabel(L("Grid"))
            .accessibilityAddTraits(browser.fullGrid ? .isSelected : [])
            .accessibilityIdentifier("mac.bar.fullgrid")
            // The third way to look at the chosen pictures, after the grid and the viewer: on the table, at
            // their printed size (2026-10-24). The Library's own loupe, as the window's Library draws it.
            Button { lightTable(store.images.filter { browser.selection.contains($0.id) }) } label: {
                DrawnGlyph(icon: .standLoupe, size: MacMetric.pt(15), color: Theme.secondaryText)
                    .frame(width: MacMetric.pt(26), height: MacMetric.pt(22)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Light Table"))
            .accessibilityLabel(L("Light Table"))
            .accessibilityIdentifier("mac.library.lighttable")
            if let crop {
                // White while the crop is open, as the column's Crop has drawn since 2026-10-24.
                Button(action: crop) {
                    HStack(spacing: MacMetric.pt(5)) {
                        Image(systemName: "crop").font(MacMetric.font(12, .medium))
                        Text(L("Crop")).font(MacMetric.font(12, .medium)).fixedSize()
                    }
                    .foregroundStyle(cropping ? Theme.onSelection : Theme.text)
                    .padding(.horizontal, MacMetric.pt(8))
                    .frame(height: MacMetric.pt(22))
                    .background(Capsule().fill(cropping ? Theme.selection : Theme.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!cropEnabled)
                .opacity(cropEnabled ? 1 : 0.4)
                .help(L("Crop"))
                .accessibilityLabel(L("Crop"))
                .accessibilityAddTraits(cropping ? .isSelected : [])
                .accessibilityIdentifier("mac.bar.crop")
            }
            MacSortControls(store: store)
        }
    }

}

/// The order and its direction: the bar's and the browser panel's header draw this one view over the
/// store's query, so the two can never disagree (the owner, 2026-10-27).
struct MacSortControls: View {
    let store: any MacLibraryData

    var body: some View {
        HStack(spacing: MacMetric.pt(4)) {
            Menu {
                Picker(L("Sort"), selection: Binding(get: { store.query.sort }, set: { s in change { $0.sort = s } })) {
                    ForEach(MacImageQuery.Sort.allCases, id: \.self) { Text(MacWords.sort($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: MacMetric.pt(4)) {
                    Text(MacWords.sort(store.query.sort)).font(MacMetric.font(12, .medium)).fixedSize()
                    Image(systemName: "chevron.up.chevron.down").font(MacMetric.font(9, .semibold))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, MacMetric.pt(8))
                .frame(height: MacMetric.pt(22))
                .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("Sort"))
            Button { change { $0.descending.toggle() } } label: {
                Image(systemName: store.query.descending ? "arrow.down" : "arrow.up")
                    .font(MacMetric.font(12, .semibold)).foregroundStyle(Theme.secondaryText)
                    .frame(width: MacMetric.pt(22), height: MacMetric.pt(22)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.query.descending ? L("Descending") : L("Ascending"))
            .accessibilityLabel(store.query.descending ? L("Descending") : L("Ascending"))
        }
    }

    /// The store's query, changed and applied — one row of the order, in either mode.
    private func change(_ edit: (inout MacImageQuery) -> Void) {
        var q = store.query
        edit(&q)
        Task { await store.apply(q) }
    }
}
