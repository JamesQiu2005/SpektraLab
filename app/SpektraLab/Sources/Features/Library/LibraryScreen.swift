//  LibraryScreen.swift — the window's library mode: the Mac library page (`MacLibraryPage`), and what
//  the page asks of the app — a removal confirmed, Settings opened on a page, an import's banner and its
//  *Change*.

import SwiftUI

struct LibraryScreen: View {
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.isSnapshot) private var isSnapshot

    /// Frames waiting for the user to confirm their removal.
    @State private var removing: Set<LibraryFrame.ID> = []
    @State private var confirmingRemoval = false
    /// The import banner's `Change`: the pair the import developed with.
    @State private var changingImport = false
    /// The library's sort, kept on the device (`FrameCatalog.oldestFirstKey`).
    @AppStorage(FrameCatalog.oldestFirstKey) private var oldestFirst = false

    /// The columns of a grid of the library's tiles (the light table's Add page, Pair With's picker).
    static let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Metric.gridGap),
                               count: Theme.Metric.gridColumns)

    var body: some View {
        ZStack {
            MacLibraryPage(confirmRemoval: confirmRemoval, openSettings: openSettings, importBanner: AnyView(bottom))
        }
        .background(Theme.background.ignoresSafeArea())
        // The page at the interface scale Settings › Appearance chose (InterfaceScale.swift), in Mac points.
        .interfaceScaled(.macPoints)
        .confirmationDialog(removalTitle, isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(L("Remove from Library"), role: .destructive) { remove(removing) }
            Button(L("Cancel"), role: .cancel) { removing = [] }
        } message: {
            Text(removalMessage)
        }
        .sheet(isPresented: $changingImport) {
            StockPairPicker(mode: .importBanner) { film, paper in redevelopImport(film: film, paper: paper) }
                .appEnvironment(model)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(Theme.Metric.sheetRadius)
                .presentationBackground(Theme.sheet)
                .appColorScheme()
        }
        .onChange(of: library.importBanner?.done ?? false) { _, done in
            // A finished import has said what it did; it leaves after a moment.
            guard done, !isSnapshot else { return }
            let shown = library.importBanner
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if library.importBanner == shown { withAnimation(.easeOut(duration: 0.25)) { library.importBanner = nil } }
            }
        }
        .onChange(of: library.filter) { _, _ in
            // The frame on top is one the grid shows.
            if let s = library.selectedID, !library.visible.contains(where: { $0.id == s }),
               let first = library.grid(oldestFirst: oldestFirst).first?.frames.first {
                library.selectedID = first.id
            }
        }
    }

    /// The import's banner, and the fade that lets the grid run out under it.
    private var bottom: some View {
        VStack(spacing: 23) {
            if let banner = library.importBanner {
                ImportBanner(banner: banner, pair: importPair(banner), progress: importProgress(banner)) {
                    changingImport = true
                }
                .padding(.horizontal, 12)
                .transition(.opacity)
            }
        }
        .padding(.bottom, 3)
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(0.85), location: 0.45),
                                   .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 76)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func openSettings(_ page: SettingsPage?) {
        SettingsRequest.next = page
        router.show(.settings)
    }

    // MARK: removal

    private func confirmRemoval(_ ids: Set<LibraryFrame.ID>) {
        guard !ids.isEmpty else { return }
        removing = ids
        confirmingRemoval = true
    }

    /// The words are `RemovalWords`' (2026-10-26): the develop page's browser asks the same question in
    /// the same words.
    private var removalTitle: String { RemovalWords.title(removing, library: library) }

    /// What goes with the frame, said before it goes: an original that was
    /// copied in is the only copy; one in Photos or a folder stays there.
    private var removalMessage: String { RemovalWords.message(removing, library: library) }

    private func remove(_ ids: Set<LibraryFrame.ID>) {
        model.remove(ids)
        removing = []
        if library.isEmpty { library.endSelecting() }
    }

    // MARK: the import banner

    private func importPair(_ banner: FrameCatalog.ImportBanner) -> String {
        guard let first = banner.frameIDs.lazy.compactMap({ library.frame($0) }).first else {
            let s = settings.newFrameStocks
            return StockCatalog.shared.pairText(film: s.film, paper: s.paper)
        }
        return StockCatalog.shared.pairText(first.edit.params)
    }

    /// The frames developed, and the share of the one under way.
    private func importProgress(_ banner: FrameCatalog.ImportBanner) -> Double {
        guard banner.imported > 0 else { return 0 }
        var done = 0.0
        for id in banner.frameIDs {
            switch library.frame(id)?.develop {
            case .developed?: done += 1
            case .developing(let p)?: done += p
            default: break
            }
        }
        return done / Double(banner.imported)
    }

    /// `Change`: the import's frames take the new pair and develop again.
    private func redevelopImport(film: String, paper: String) {
        guard var banner = library.importBanner else { return }
        for id in banner.frameIDs {
            library.update(id) { f in
                f.edit.params.printStock = paper
                f.edit.params.load(film: film)
            }
            model.scheduler.cancelAll(frameID: id) { !$0.kind.isCanvas }
            model.develop(id)
        }
        banner.developed = 0
        library.importBanner = banner
    }
}

// MARK: - the parts only this page draws

/// B3: what an import did, and what it developed with.
private struct ImportBanner: View {
    let banner: FrameCatalog.ImportBanner
    let pair: String
    let progress: Double
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ProgressRing(progress: progress, diameter: 18, lineWidth: 2, track: .clear)
                .padding(.leading, 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("\(banner.imported) imported, \(banner.developed) developed"))
                    .font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text(L("\(pair), at preview size")).font(Theme.Font.ui(11.5)).foregroundStyle(Theme.dim)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .padding(.leading, 9)
            Spacer(minLength: 8)
            TextButton(title: L("Change"), color: Theme.accent, font: Theme.Font.ui(13, .semibold), action: onChange)
                .padding(.trailing, 16)
        }
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
    }
}
