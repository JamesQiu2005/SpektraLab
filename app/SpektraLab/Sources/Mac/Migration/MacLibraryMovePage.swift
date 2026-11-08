//  MacLibraryMovePage.swift — the page that says the SpektraLab Library is becoming a catalog, and
//  moves it (`MacLibraryMove`). Over the whole library page, as the import page is: a title bar, what
//  will move at the left, where it goes at the right, and *Not Now* · *Move* at the foot.
//  Escape is *Not Now*, Return *Move*.

import SwiftUI

struct MacLibraryMovePage: View {
    let move: MacLibraryMove
    @Environment(FrameCatalog.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            Text(L("The SpektraLab Library Becomes a Catalog")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: MacMetric.pt(MacMetric.gridHeader))
                .background(Theme.panel)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Theme.wall).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
                    Text(L("From now on your library is a SpektraLab catalog, a .spkcatalog you place where you like, as a Capture One catalog is. You can have several, and the one you used last opens."))
                        .font(MacMetric.font(13)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    what
                    place
                    Text(L("No picture is moved, copied or deleted: the catalog reads each one where it is. Your edits and developed pictures stay as they are."))
                        .font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(MacMetric.pt(24))
                .frame(maxWidth: MacMetric.pt(620), alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Rectangle().fill(Theme.wall).frame(height: 1)
            bottomBar
        }
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: what moves

    private var frames: [LibraryFrame] { move.candidates.compactMap { library.frame($0) } }

    private var what: some View {
        let f = frames
        let imports = Set(f.map { Int($0.importedAt.timeIntervalSince1970 / 60) }).count
        let copied = f.filter { $0.source == .copiedIn }.count
        let favourites = f.filter(\.isFavourite).count
        let folders = library.linkedFolders.count
        var rows: [(String, String)] = [(L("Pictures"), f.count.formatted())]
        rows.append((L("Imports"), L("\(imports.formatted()) Recent Imports, each with its own time")))
        if favourites > 0 { rows.append((L("Favourites"), L("an album of \(favourites.formatted())"))) }
        if copied > 0 { rows.append((L("Copied in"), L("\(copied.formatted()) read where the app keeps them"))) }
        if folders > 0 { rows.append((L("Linked folders"), L("\(folders.formatted()) kept in step by the catalog"))) }
        return VStack(alignment: .leading, spacing: MacMetric.pt(6)) {
            Text(L("What goes into it")).font(MacMetric.font(11, .semibold)).foregroundStyle(Theme.dim)
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(10)) {
                    Text(row.0).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                        .frame(width: MacMetric.pt(110), alignment: .trailing)
                    Text(row.1).font(MacMetric.font(13)).monospacedDigit().foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var place: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(6)) {
            Text(L("Where it is kept")).font(MacMetric.font(11, .semibold)).foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(10)) {
                Image(systemName: MacWords.symbol(.catalog)).font(MacMetric.font(13)).foregroundStyle(Theme.secondaryText)
                Text((move.destination.path as NSString).abbreviatingWithTildeInPath)
                    .font(MacMetric.font(13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Change…")) { change() }
                    .buttonStyle(MacImportButtonStyle(kind: .small))
                    .disabled(running)
                    .accessibilityIdentifier("mac.move.change")
            }
        }
    }

    private func change() {
        let d = move.destination
        Task {
            if let url = await MacSavePanel.catalogPlace(name: d.deletingPathExtension().lastPathComponent,
                                                         in: d.deletingLastPathComponent(),
                                                         message: L("Where the SpektraLab Library's catalog is kept")) {
                move.destination = url
            }
        }
    }

    // MARK: the foot

    private var running: Bool { move.phase == .running }

    private var bottomBar: some View {
        HStack(spacing: MacMetric.pt(10)) {
            status.frame(maxWidth: .infinity, alignment: .leading).frame(minWidth: 1)
            switch move.phase {
            case .done:
                Button(L("Show the Catalog")) { move.dismiss() }
                    .buttonStyle(MacImportButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button(L("Not Now")) { move.notNow() }
                    .buttonStyle(MacImportButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                Button(L("Try Again")) { move.retry() }
                    .buttonStyle(MacImportButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            default:
                Button(L("Not Now")) { move.notNow() }
                    .buttonStyle(MacImportButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button(L("Move into the Catalog")) { Task { await move.run() } }
                    .buttonStyle(MacImportButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || move.candidates.isEmpty)
                    .accessibilityIdentifier("mac.move.go")
            }
        }
        .padding(.horizontal, MacMetric.pt(14))
        .frame(maxWidth: .infinity)
        .frame(height: MacMetric.pt(44))
        .background(Theme.panel)
        .background {
            switch move.phase {
            case .done:
                Color.clear.macPageActions(confirmTitle: L("Show the Catalog"), confirm: { move.dismiss() }, cancel: { move.dismiss() })
            case .failed:
                Color.clear.macPageActions(confirmTitle: L("Try Again"), confirm: { move.retry() }, cancel: { move.notNow() })
            default:
                Color.clear.macPageActions(confirmTitle: L("Move into the Catalog"), confirmEnabled: !running && !move.candidates.isEmpty,
                                           cancelEnabled: !running, confirm: { Task { await move.run() } }, cancel: { move.notNow() })
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch move.phase {
        case .running:
            HStack(spacing: MacMetric.pt(8)) {
                ProgressView(value: Double(move.done), total: Double(max(move.total, 1)))
                    .frame(width: MacMetric.pt(140)).tint(Theme.accent)
                Text(L("\(move.done.formatted()) of \(move.total.formatted()) pictures")).font(MacMetric.font(12))
                    .monospacedDigit().foregroundStyle(Theme.secondaryText)
            }
        case .done(let o):
            Text(o.left.isEmpty ? L("\(o.moved.formatted()) pictures are in the catalog.")
                                : L("\(o.moved.formatted()) pictures are in the catalog; \(o.left.count.formatted()) could not be found."))
                .font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let why):
            Text(L(shown: why)).font(MacMetric.font(12)).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}
