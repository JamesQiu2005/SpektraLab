//  MacSettingsWatermarks.swift — Settings › Watermarks (水印): the person's marks, managed (PRD-8 §4.1; the owner,
//  2026-11-15: "In settings we should have a place for managing the watermarks").
//
//  One group in the Settings window's language, its marks as
//  a grid of tiles on the mid-grey checkerboard (N8), each with its name and its pixel size; newest first (W4: no
//  reorder). **Add…** is the Mac's open panel filtered to PNG (`MacOpenPanel.choosePNGs`, the bridge *Add .lcp…*
//  uses), several at once; PNG files dropped onto the grid are added the same way. Every file meets the library's check
//  in RFC-067 §2's order (`WatermarkStore.validate`); a refusal is an alert with its reason, one file at a time. The
//  same bytes added again select the mark that has them and say so (a second copy is never kept). A tile's menu (a secondary
//  click) renames it — one field — and deletes it, which first says how many photographs use the
//  mark and that there is no Undo (N7). A photograph that places a deleted mark keeps its placement and draws nothing;
//  its row in 图层 says the mark is missing.

import SwiftUI
import UniformTypeIdentifiers

struct MacSettingsWatermarks: View {
    @Environment(AppServices.self) private var model
    private var store: WatermarkStore { model.watermarks }

    @State private var picked: UUID?
    @State private var refused: (name: String, refusal: WatermarkRefusal)?
    @State private var note: String?
    @State private var renaming: WatermarkMark?
    @State private var draft = ""
    @State private var deleting: WatermarkMark?
    @State private var adding = false
    @State private var dropping = false

    private let tile = MacMetric.pt(112)

    var body: some View {
        MacSettingsGroup(title: L("Your watermarks"),
                         footer: L("Only a PNG with a transparent background: a signature, a logo, a handwritten name. "
                                   + "Place one on a photograph from the Layers panel’s ＋ › Watermark.")) {
            VStack(alignment: .leading, spacing: MacMetric.pt(10)) {
                HStack(spacing: MacMetric.pt(8)) {
                    Text(store.marks.isEmpty ? L("No watermarks yet") : L("\(store.marks.count) watermarks"))
                        .font(MacMetric.font(13)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    Button(L("Add…")) { Task { @MainActor in await choose() } }
                        .buttonStyle(MacSettingsButtonStyle(kind: store.marks.isEmpty ? .primary : .plain))
                        .disabled(adding)
                        .accessibilityLabel(L("Add Watermark"))
                        .accessibilityIdentifier("mac.settings.watermarks.add")
                }
                if let note {
                    MacSettingsCaption(note, color: Theme.secondaryText)
                        .accessibilityIdentifier("mac.settings.watermarks.note")
                }
                grid
            }
            .padding(.horizontal, MacMetric.pt(MacSettingsMetric.inset))
            .padding(.vertical, MacMetric.pt(10))
        }
        .macSettingsItem("Watermarks")
        .alert(L("Can't Add"), isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } })) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(refused.map { "“\($0.name)”\n" + $0.refusal.message } ?? "")
        }
        .alert(L("Rename Watermark"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $draft)
            Button(L("Rename")) {
                if let m = renaming { store.rename(m.id, to: draft) }
                renaming = nil
            }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.map { L("Delete “\($0.name)”") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) {
                if let m = deleting {
                    store.delete(m.id)
                    if picked == m.id { picked = nil }
                    note = L("Watermark deleted")
                }
                deleting = nil
            }
            Button(L("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { Self.deleteMessage(uses: store.usage(of: $0.id)) } ?? "")
        }
    }

    /// "3 photos use it. Deleting it removes the watermark from them. There is no Undo."
    static func deleteMessage(uses n: Int) -> String {
        let uses: String
        switch n {
        case 0: uses = L("No photo uses it.")
        case 1: uses = L("1 photo uses it.\nDeleting it removes the watermark from it.")
        default: uses = L("\(n) photos use it.\nDeleting it removes the watermark from them.")
        }
        return uses + "\n" + L("There is no Undo.")
    }

    // MARK: the grid

    @ViewBuilder private var grid: some View {
        let columns = [GridItem(.adaptive(minimum: tile, maximum: tile), spacing: MacMetric.pt(12), alignment: .top)]
        Group {
            if store.marks.isEmpty {
                VStack(spacing: MacMetric.pt(6)) {
                    Image(systemName: "signature").font(MacMetric.font(22)).foregroundStyle(Theme.dim)
                    Text(L("Drop PNG files here, or choose Add…")).font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: MacMetric.pt(120))
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: MacMetric.pt(14)) {
                    ForEach(store.marks) { mark in tileView(mark) }
                }
                .padding(.vertical, MacMetric.pt(4))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: MacMetric.pt(8), style: .continuous)
                .strokeBorder(dropping ? Theme.accent : Theme.rule, style: StrokeStyle(lineWidth: dropping ? 2 : 0.5, dash: store.marks.isEmpty ? [4, 3] : []))
        }
        .onDrop(of: [UTType.fileURL, UTType.png], isTargeted: $dropping) { providers in
            Task { @MainActor in await drop(providers) }
            return true
        }
        .accessibilityIdentifier("mac.settings.watermarks.grid")
    }

    private func tileView(_ mark: WatermarkMark) -> some View {
        let on = picked == mark.id
        return VStack(alignment: .leading, spacing: MacMetric.pt(4)) {
            WatermarkThumbnail(mark: mark.id, cell: MacMetric.pt(8))
                .frame(width: tile, height: tile * 0.72)
                .clipShape(RoundedRectangle(cornerRadius: MacMetric.pt(6), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MacMetric.pt(6), style: .continuous)
                        .strokeBorder(on ? Theme.accent : Theme.rule, lineWidth: on ? 2 : 0.5)
                }
            Text(mark.name).font(MacMetric.font(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Text("\(mark.w) × \(mark.h) px").font(MacMetric.font(11).monospacedDigit()).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .frame(width: tile, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { draft = mark.name; renaming = mark }
        .onTapGesture { picked = mark.id }
        .contextMenu {
            Button { draft = mark.name; renaming = mark } label: { Label(L("Rename…"), systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { deleting = mark } label: { Label(L("Delete…"), systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mark.name)
        .accessibilityValue("\(mark.w) × \(mark.h) px")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: L("Rename…")) { draft = mark.name; renaming = mark }
        .accessibilityAction(named: L("Delete…")) { deleting = mark }
        .accessibilityIdentifier("mac.settings.watermarks.tile.\(mark.id.uuidString)")
    }

    // MARK: adding

    private func choose() async {
        guard let urls = await MacOpenPanel.choosePNGs(), !urls.isEmpty else { return }
        await add(urls)
    }

    private func drop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await Self.fileURL(from: p) { urls.append(url) }
        }
        await add(urls)
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (k: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in k.resume(returning: url) }
        }
    }

    /// Each file in turn: kept, or the same bytes found (selected, said), or refused (the alert names it, and the next
    /// file waits for nothing: the alert says the first refusal, the line the count of the rest).
    private func add(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        adding = true
        defer { adding = false }
        var firstRefusal: (String, WatermarkRefusal)?
        var refusedCount = 0, addedCount = 0
        var already: WatermarkMark?
        for url in urls {
            switch await store.add(fileAt: url) {
            case .success(.new(let m)): picked = m.id; addedCount += 1
            case .success(.existing(let m)): picked = m.id; already = m
            case .failure(let r):
                refusedCount += 1
                if firstRefusal == nil { firstRefusal = (url.lastPathComponent, r) }
            }
        }
        if let already, addedCount == 0 {
            note = L("“\(already.name)” is already in your watermarks.")
        } else if refusedCount > 1 {
            note = L("\(refusedCount) files were not added.")
        } else {
            note = nil
        }
        if let firstRefusal { refused = (firstRefusal.0, firstRefusal.1) }
    }
}
