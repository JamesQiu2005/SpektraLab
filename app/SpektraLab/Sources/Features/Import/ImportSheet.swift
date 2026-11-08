//  ImportSheet.swift — A4 Import; A5-A8 are the system's own pickers.
//  the page layout (`import_sheet` in gen_flow.py)
//
//  Two ways in, one sheet: a folder linked where it is, or files copied in. Under them, the pair new frames develop with —
//  which can be changed here, before, or from the library's banner, after.
//
//  A8 is Apple's: the document picker, for files or for a folder. The drawings
//  show it plainly as system UI; the app presents the real one.

import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.isSnapshot) private var isSnapshot

    private enum Files { case copy, link }
    @State private var files: Files = .copy
    @State private var pickingFiles = false
    @State private var choosingStocks = false
    /// Files on their way in: said on the row that brought them.
    @State private var working: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("Import")) { router.dismissSheet() }
            GroupBox(radius: 14) {
                SourceRow(icon: .folderLink, title: L("Link a folder"), sub: L("Cards, disks, iCloud Drive, in place"),
                          trailing: working == "link" ? L("Reading") : nil) { chooseFiles(.link) }
                    .hairlineBelow(leading: 64)
                SourceRow(icon: .copyIn, title: L("Copy files in"), sub: L("SpektraLab keeps its own copy"),
                          trailing: working == "copy" ? L("Copying") : nil) { chooseFiles(.copy) }
            }
            .rowEnabled(working == nil)
            .padding(.horizontal, Theme.Metric.margin)
            .padding(.top, 11)
            if failed {
                Note(L("Nothing could be read from what was picked: RAW, DNG, JPEG and HEIC files come in."), color: Theme.danger)
                    .padding(.horizontal, 20)
                    .padding(.top, 10.9)
            }
            SectionLabel(L("Develops with"))
                .padding(.horizontal, 20)
                .padding(.top, 14)
            developsWith
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.top, 7.2)
            Spacer(minLength: 0)
        }
        // Linking takes a picture as well as a folder (the owner, 2026-10-20: a RAW in On My
        // reference device stood greyed in a folders-only picker, and read as one the app did not know).
        // Open on a folder links it; a picture tapped there comes in as Copy files in does.
        .fileImporter(isPresented: $pickingFiles,
                      allowedContentTypes: files == .link ? UTType.linkable + [.rawImage, .image] : [.rawImage, .image],
                      allowsMultipleSelection: files == .copy) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            switch files {
            case .copy: bring("copy") { await ImportService(model: model).copyIn(urls) }
            case .link:
                if (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    bring("link") { await ImportService(model: model).link(folder: urls[0]) }
                } else {
                    bring("link") { await ImportService(model: model).copyIn(urls) }
                }
            }
        }
        .sheet(isPresented: $choosingStocks) {
            StockPairPicker(mode: .newFrames)
                .appEnvironment(model)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(Theme.Metric.sheetRadius)
                .presentationBackground(Theme.sheet)
                .appColorScheme()
        }
    }

    /// The pair new frames develop with, and whether it follows the last used.
    private var developsWith: some View {
        let s = settings.newFrameStocks
        return Button { choosingStocks = true } label: {
            HStack(spacing: 0) {
                StockDot(color: StockCatalog.shared.stock(s.film)?.color ?? Theme.card, diameter: 10)
                    .padding(.leading, 15)
                Text(StockCatalog.shared.pairText(film: s.film, paper: s.paper))
                    .font(Theme.Font.ui(15, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.leading, 9)
                Spacer(minLength: 8)
                if settings.newFrameFilm == nil {
                    // On the pair's baseline, a point under the row's centre.
                    Text(L("Last used")).font(Theme.Font.ui(13)).foregroundStyle(Theme.dim).lineLimit(1).offset(y: 1)
                }
                Chevron().padding(.leading, 6).padding(.trailing, 19)
            }
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
    }

    // MARK: the ways in

    private func chooseFiles(_ how: Files) {
        guard !isSnapshot else { return }
        failed = false
        files = how
        pickingFiles = true
    }

    /// Bring files in, then go back to the library, where they develop.
    private func bring(_ row: String, _ work: @escaping () async -> Int) {
        working = row
        Task {
            let count = await work()
            working = nil
            if count > 0 { router.dismissSheet() } else { failed = true }
        }
    }
}

/// One way in: its glyph on a dark tile, what it is, and what it does.
private struct SourceRow: View {
    let icon: SpkIcon
    let title: String
    let sub: String
    var trailing: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Icon(icon, size: 22)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.plot))
                    .padding(.leading, 12)
                VStack(alignment: .leading, spacing: 3.1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(Theme.Font.ui(15.5, .semibold)).foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                        if let trailing {
                            Text(trailing).font(Theme.Font.ui(12)).foregroundStyle(Theme.dim)
                        }
                    }
                    Text(sub).font(Theme.Font.ui(12)).foregroundStyle(Theme.dim)
                }
                .lineLimit(1)
                .padding(.leading, 14)
                Chevron().padding(.leading, 10).padding(.trailing, 19)
            }
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
    }
}
