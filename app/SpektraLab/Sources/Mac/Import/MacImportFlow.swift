//  MacImportFlow.swift — the Mac's import: a Finder panel, then the import page (2026-10-24).
//
//  The owner: "A separate import page comes after the Finder panel, and it is connected straight to the
//  multi-select we just built: the user can press 'Import All' when nothing is selected, or import the
//  selected pictures." Presented by `MacLibraryPage` (a full-screen cover while
//  `MacLibraryBrowser.importAsked`), from the Import icon of the sidebar's tab bar or its "+" menu, or by
//  pictures and folders dropped on the window (`MacImportDrop`: the page opens with them as picked).
//
//  Capture One's Import Images window is the reference, at the library's Mac metrics (MAC-LIBRARY-UI §4):
//  - **the left column**: *Import From* (what was picked, *Include Subfolders*, *Exclude Duplicates (n)*),
//    *Import To* (the catalog or session, or *New Catalog…*; *Add to Catalog* — the files stay where they
//    are — or *Copy to Folder…*, or the helper's copy into the catalog; the collection, Recent Imports),
//    *Filters* (format, the day taken);
//  - **the right**: the pictures found, in the library's own cells and with its selection (click,
//    ⌘-click, ⇧-click, a marquee from the space between, ⌘A, ⇧⌘A, the arrows), a duplicate greyed; the
//    viewer (⌥⌘V, a double click, `BrowserViewerSplit`) beside them;
//  - **the bottom bar**: *Select All*, *Cancel* (Escape), and *Import All (n)* or *Import n Selected*
//    (Return).
//  The page's state and the import itself are `MacImportSession`'s; the scan is `MacImportScan`'s.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One ask for the import page (`MacLibraryBrowser.importRequest`): the cover is presented by it and the
/// flow takes its id as its identity, so every Import or drop that finds no page up gets a page of its own.
struct MacImportRequest: Identifiable, Equatable {
    let id = UUID()
}

/// What UIKit has presented for the import page: the cover's last word, when SwiftUI's has not come.
/// Only the import page's own controller (`MacImportCoverProbe` notes it as the page appears), never
/// whatever else is presented over the window — an alert, a confirmation, another window's sheet.
@MainActor
enum MacImportCover {
    private static weak var page: UIViewController?
    private static var pageRequest: MacImportRequest.ID?

    static func note(_ controller: UIViewController, request: MacImportRequest.ID) {
        page = controller
        pageRequest = request
    }
    /// The page of `request` is presented and nothing is taking it away.
    static func stands(_ request: MacImportRequest.ID) -> Bool {
        guard pageRequest == request, let p = page else { return false }
        return p.presentingViewController != nil && !p.isBeingDismissed
    }
    /// The page of `request` is going away (its dismissal under way).
    static func going(_ request: MacImportRequest.ID) -> Bool {
        guard pageRequest == request, let p = page else { return false }
        return p.presentingViewController != nil && p.isBeingDismissed
    }
    /// Takes the page of `request` down, and nothing else.
    static func takeDown(_ request: MacImportRequest.ID) {
        guard stands(request), let p = page else { return }
        p.dismiss(animated: true)
    }
}

/// Drawn nowhere in the import page: finds the controller UIKit presented the page in (the one whose
/// presenter presents it) and notes it for `MacImportCover`.
private struct MacImportCoverProbe: UIViewControllerRepresentable {
    let request: MacImportRequest.ID
    func makeUIViewController(context: Context) -> Probe { Probe(request: request) }
    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        let request: MacImportRequest.ID
        init(request: MacImportRequest.ID) { self.request = request; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { nil }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            var v: UIViewController? = self
            while let here = v {
                if let presenter = here.presentingViewController, presenter.presentedViewController === here {
                    MacImportCover.note(here, request: request)
                    return
                }
                v = here.parent
            }
        }
    }
}

struct MacImportFlow: View {
    let store: any MacLibraryData
    /// The request this page is (`MacLibraryBrowser.importRequest`).
    let request: MacImportRequest.ID
    /// Closes the flow (Cancel, or after an import): its own request only (`MacLibraryBrowser.closeImport`).
    let done: () -> Void

    @State private var session: MacImportSession?

    #if DEBUG
    /// A check's way past the Finder panel: taken as picked when the page appears.
    static var debugPicks: [URL]?
    /// The session the page shows, for a check to drive.
    static weak var debugSession: MacImportSession?
    #endif

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let session {
                MacImportPage(session: session) { [done] in Self.finish(session, done: done) }
            }
        }
        .background(MacImportCoverProbe(request: request).frame(width: 0, height: 0).accessibilityHidden(true))
        .onAppear {
            // On screen: a request asked for meanwhile waits until this page has gone (`importPresented`).
            MacLibraryBrowser.shared.importShown = request
            guard session == nil else { return }
            let s = MacImportSession(store: store)
            session = s
            MacImportDrop.open = s
            #if DEBUG
            Self.debugSession = s
            // The page's Cancel, holding the session weakly and no view (a closure of `self` kept the
            // @State box, and the session with it, alive after the page had gone).
            s.debugCancel = { [weak s, done] in Self.finish(s, done: done) }
            #endif
        }
        .onDisappear {
            session?.close()
            if MacImportDrop.open === session { MacImportDrop.open = nil }
            // Off the screen: the next request's page may be presented now.
            let browser = MacLibraryBrowser.shared
            if browser.importShown == request { browser.importShown = nil }
        }
    }

    /// Cancel, and the close after an import: the session closed, a drop not taken yet let go (its
    /// temporary copies removed: the next Import asks Finder again), then the flow's request closed.
    private static func finish(_ session: MacImportSession?, done: () -> Void) {
        session?.close()
        MacImportDrop.letGo()
        done()
    }
}

// MARK: - the page

/// What a Finder panel is asked for.
private enum MacImportPicker: Hashable {
    /// Folders and pictures, several (the flow's first step).
    case sources
    /// The folder copies go to.
    case copyFolder
    /// The folder a new catalog is made in.
    case catalogFolder

    var types: [UTType] {
        switch self {
        case .sources: [.folder, .rawImage, .image]
        case .copyFolder, .catalogFolder: [.folder]
        }
    }
}

/// "~/Pictures/Imports", "/Volumes/PhotoCard": where a folder is, whole (never cut short).
private func placeWords(_ url: URL) -> String {
    (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
}

private struct MacImportPage: View {
    @Bindable var session: MacImportSession
    let done: () -> Void

    /// The Finder panel is up, and what it was asked for (kept apart: the panel's binding clears as it
    /// closes, before its result arrives).
    @State private var panelShown = false
    @State private var choosingSources = false
    @State private var asking: MacImportPicker = .sources
    /// The first Finder panel has been shown: cancelling it closes the flow.
    @State private var askedFirst = false
    @FocusState private var naming: Bool
    /// A drag from Finder is over the page (`MacImportDrop`): its picks grow by what is dropped.
    @State private var dropping = false
    @Environment(AppRouter.self) private var router

    private var browser: MacLibraryBrowser { session.browser }
    private var library: MacLibraryBrowser { MacLibraryBrowser.shared }
    private static let columnWidth: CGFloat = 290

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Theme.wall).frame(height: 1)
            HStack(spacing: 0) {
                MacImportColumn(session: session, choose: ask, naming: $naming)
                    .frame(width: MacMetric.pt(Self.columnWidth))
                    .background(Theme.panel)
                Rectangle().fill(Theme.wall).frame(width: 1)
                MacImportBrowser(session: session)
            }
            Rectangle().fill(Theme.wall).frame(height: 1)
            bottomBar
        }
        .background(Theme.background.ignoresSafeArea())
        .background { keys }
        .macPageActions(confirmTitle: session.importTitle, confirmEnabled: session.canImport && !choosingSources && !panelShown,
                        cancelEnabled: session.progress == nil && !choosingSources && !panelShown,
                        confirm: { Task { if await session.run() != nil { done() } } }, cancel: cancel)
        .onChange(of: naming) { _, on in browser.typing = on }
        .onChange(of: panelShown) { _, up in session.finderUp = up || choosingSources }
        // A drop on the page, or on the window while the page is up: what was dropped joins the picks.
        .onDrop(of: MacImportDrop.types, delegate: MacImportDropTarget(router: router, dropping: $dropping))
        .overlay { if dropping || library.dropReading != nil { MacImportDropNote(reading: library.dropReading) } }
        .onChange(of: library.droppedPicks) { _, picks in
            // A page going away (closed: Cancel, an import) leaves a drop to the page asked next.
            guard askedFirst, !session.closed, let picks else { return }
            library.droppedPicks = nil
            Task { _ = await session.receivePicks(picks.urls, adding: true, copies: picks.copies) }
        }
        .onAppear {
            guard !askedFirst else { return }
            askedFirst = true
            // Dropped on the window (`MacImportDrop`): those are the picks, and Finder is not asked.
            if let picks = library.droppedPicks {
                library.droppedPicks = nil
                Task { if await session.receivePicks(picks.urls, copies: picks.copies) { done() } }
                return
            }
            #if DEBUG
            if let picks = MacImportFlow.debugPicks {
                Task { if await session.receivePicks(picks) { done() } }
                return
            }
            #endif
            ask(.sources)
        }
        .fileImporter(isPresented: $panelShown, allowedContentTypes: asking.types,
                      allowsMultipleSelection: asking == .sources) { result in
            switch result {
            case .success(let urls):
                guard let first = urls.first else { cancelled(); return }
                switch asking {
                case .sources: Task { if await session.receivePicks(urls) { done() } }
                case .copyFolder: session.copyFolder = first; session.placement = .copyToFolder
                case .catalogFolder: session.newCatalogFolder = first
                }
            case .failure(let error):
                Log.warn(.library, "mac import: the Finder panel failed", ["error": error.localizedDescription])
                cancelled()
            }
        } onCancellation: {
            cancelled()
        }
    }

    private func ask(_ what: MacImportPicker) {
        asking = what
        if what == .sources {
            guard !choosingSources else { return }
            choosingSources = true
            // A drop while Finder is asked is refused (`MacImportDrop.accepts`): the panel's answer
            // replaces the picks, and would wipe it.
            session.finderUp = true
            Task {
                defer { choosingSources = false; session.finderUp = panelShown }
                guard let urls = await MacOpenPanel.choose(multiple: true), !urls.isEmpty else { cancelled(); return }
                if await session.receivePicks(urls) { done() }
            }
            return
        }
        panelShown = true
    }

    /// Cancel and Escape. **The Finder panel goes first.** The page asks for it as it opens, and on the Mac it
    /// is a window of its own that can sit behind the app's; while it is presented the cover cannot go, so
    /// Cancel on the page waited on a panel the owner could not see (2026-10-24: "cancel in this page won't
    /// work fast"; a sample of the app showed its main thread idle and the panel's ViewBridge up). Taken
    /// down here, its own cancellation (`cancelled`) closes nothing twice: `done` is idempotent.
    private func cancel() {
        if panelShown { panelShown = false }
        done()
    }

    /// The flow's first panel, cancelled with nothing picked, closes the flow (Capture One's Import is one
    /// window: no folder, no window). A later panel cancelled changes nothing.
    private func cancelled() {
        if asking == .sources, session.picked.isEmpty { done() }
    }

    // MARK: the bars

    private var titleBar: some View {
        Text(L("Import Images")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: MacMetric.pt(MacMetric.gridHeader))
            .background(Theme.panel)
            .accessibilityAddTraits(.isHeader)
    }

    private var bottomBar: some View {
        HStack(spacing: MacMetric.pt(10)) {
            Button(L("Select All")) { browser.selectAll(session.rows) }
                .buttonStyle(MacImportButtonStyle(kind: .plain))
                .disabled(session.rows.isEmpty || session.progress != nil)
            if !browser.selection.isEmpty {
                Button(L("Select None")) { browser.selectNone() }
                    .buttonStyle(MacImportButtonStyle(kind: .plain))
                    .disabled(session.progress != nil)
            }
            status
                .frame(maxWidth: .infinity)
                .frame(minWidth: 1)   // the bar is the page's width even with no status to say
            if session.progress != nil {
                Button(L("Stop")) { session.stopAsked = true }
                    .buttonStyle(MacImportButtonStyle(kind: .plain))
                    .disabled(session.stopAsked)
            } else {
                Button(L("Cancel"), action: cancel)
                    .buttonStyle(MacImportButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
            }
            Button(session.importTitle) {
                Task { if await session.run() != nil { done() } }
            }
            .buttonStyle(MacImportButtonStyle(kind: .primary))
            .disabled(!session.canImport)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mac.import.go")
        }
        .padding(.horizontal, MacMetric.pt(14))
        .frame(maxWidth: .infinity)
        .frame(height: MacMetric.pt(44))
        .background(Theme.panel)
    }

    /// The run's progress, the scan's, or why the import cannot start.
    @ViewBuilder private var status: some View {
        if let p = session.progress {
            HStack(spacing: MacMetric.pt(8)) {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: MacMetric.pt(140))
                    .tint(Theme.accent)
                Text(Self.words(p)).font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let problem = session.problem {
            Text(L(shown: problem)).font(MacMetric.font(12)).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        } else if session.scanning || session.readingHeaders {
            HStack(spacing: MacMetric.pt(6)) {
                ProgressView().controlSize(.small)
                Text(session.scanning ? L("Looking for pictures… \(session.files.count.formatted())")
                                      : L("Reading \(session.files.count.formatted()) pictures…"))
                    .font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let why = session.notReady {
            Text(why).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func words(_ p: MacImportSession.Progress) -> String {
        switch p.phase {
        case .creating: L("Making the catalog…")
        case .copying: L("Copying \(p.done.formatted()) of \(p.total.formatted())…")
        case .adding: L("Importing \(p.done.formatted()) of \(p.total.formatted())…")
        case .finishing: L("Opening the import…")
        }
    }

    /// The selection's keys, as the library's (MAC-LIBRARY-UI §5); they stand down while a field types.
    /// Escape is Cancel (Capture One's window), so ⇧⌘A clears the selection.
    private var keys: some View {
        let rows = session.rows
        let typing = browser.typing || session.progress != nil
        let step = max(browser.columns, 1)
        return Group {
            HiddenKeyEquivalent(title: L("Previous"), key: .leftArrow, enabled: !typing) { browser.move(-1, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Next"), key: .rightArrow, enabled: !typing) { browser.move(1, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Up"), key: .upArrow, enabled: !typing) { browser.move(-step, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Down"), key: .downArrow, enabled: !typing) { browser.move(step, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Previous"), key: .leftArrow, modifiers: .shift, enabled: !typing) { browser.move(-1, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Next"), key: .rightArrow, modifiers: .shift, enabled: !typing) { browser.move(1, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Up"), key: .upArrow, modifiers: .shift, enabled: !typing) { browser.move(-step, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Down"), key: .downArrow, modifiers: .shift, enabled: !typing) { browser.move(step, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Select All"), key: "a", modifiers: .command, enabled: !typing) { browser.selectAll(rows) }
            HiddenKeyEquivalent(title: L("Select None"), key: "a", modifiers: [.command, .shift], enabled: !typing) { browser.selectNone() }
            HiddenKeyEquivalent(title: L("Viewer"), key: "v", modifiers: [.command, .option], enabled: !typing) { browser.viewerShown.toggle() }
            HiddenKeyEquivalent(title: L("Larger Thumbnails"), key: "=", modifiers: .command) { browser.resize(by: 1.25) }
            HiddenKeyEquivalent(title: L("Larger Thumbnails"), key: "+", modifiers: .command) { browser.resize(by: 1.25) }
            HiddenKeyEquivalent(title: L("Smaller Thumbnails"), key: "-", modifiers: .command) { browser.resize(by: 1 / 1.25) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - the drop's highlight

/// Over the window or the import page while a Finder drag is over it: where it goes, in one line; then,
/// while the drop's items are read (`MacLibraryBrowser.dropReading`), how many, so a large drop is seen
/// to have been taken before the page opens.
struct MacImportDropNote: View {
    var reading: Int? = nil

    var body: some View {
        VStack(spacing: MacMetric.pt(6)) {
            if let reading {
                ProgressView().controlSize(.regular)
                Text(L("Reading \(reading.formatted()) dropped items…")).font(MacMetric.font(14, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "square.and.arrow.down").font(MacMetric.font(22, .medium)).foregroundStyle(Theme.accent)
                Text(L("Drop to Import")).font(MacMetric.font(14, .semibold)).foregroundStyle(Theme.text)
            }
        }
        .padding(.horizontal, MacMetric.pt(28)).padding(.vertical, MacMetric.pt(18))
        .background(Theme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: MacMetric.pt(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MacMetric.pt(12), style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
        .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 2))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - the left column

private struct MacImportColumn: View {
    @Bindable var session: MacImportSession
    let choose: (MacImportPicker) -> Void
    var naming: FocusState<Bool>.Binding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacMetric.pt(4)) {
                importFrom
                importTo
                if !session.files.isEmpty { filters }
            }
            .padding(.bottom, MacMetric.pt(16))
        }
        .scrollIndicators(.automatic)
    }

    // Import From

    private var importFrom: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(2)) {
            MacImportHeading(title: L("Import From"))
            HStack(spacing: MacMetric.pt(8)) {
                Image(systemName: "folder").font(MacMetric.font(13)).foregroundStyle(Theme.secondaryText).frame(width: MacMetric.pt(16))
                VStack(alignment: .leading, spacing: MacMetric.pt(1)) {
                    Text(session.picked.isEmpty ? L("Nothing chosen") : session.pickedTitle)
                        .font(MacMetric.font(13)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if session.picked.count == 1, let one = session.picked.first {
                        Text(placeWords(one.deletingLastPathComponent())).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Choose…")) { choose(.sources) }
                    .buttonStyle(MacImportButtonStyle(kind: .small))
            }
            .padding(.horizontal, MacMetric.pt(12))
            .padding(.vertical, MacMetric.pt(4))
            MacImportCheckRow(title: L("Include Subfolders"), on: $session.includeSubfolders)
            MacImportCheckRow(title: L("Exclude Duplicates"), detail: duplicateDetail, on: $session.excludeDuplicates)
            Text(foundLine).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MacMetric.pt(12)).padding(.top, MacMetric.pt(2))
        }
        .disabled(session.progress != nil)
    }

    private var duplicateDetail: String? {
        if session.loadingExisting { return "…" }
        guard session.existing != nil else { return nil }
        return "(\(session.duplicateCount.formatted()))"
    }

    /// "629 pictures found · 8 other files left out".
    private var foundLine: String {
        let t = session.tally
        var out = L("\(session.files.count.formatted()) pictures found")
        let left = t.movies + t.sidecars + t.other + t.unreadable
        if left > 0 { out += " · " + L("\(left.formatted()) other files left out") }
        return out
    }

    // Import To

    private var importTo: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(2)) {
            MacImportHeading(title: L("Import To"))
            destinationMenu
                .padding(.horizontal, MacMetric.pt(12))
                .padding(.vertical, MacMetric.pt(3))
            if session.destination == .newCatalog { newCatalog }
            MacImportRadioRow(title: session.destinationSource?.kind == .session ? L("Add to Session") : L("Add to Catalog"), detail: L("Your files stay where they are."),
                              on: session.placement == .inPlace) { session.placement = .inPlace }
            MacImportRadioRow(title: L("Copy to Folder…"),
                              detail: session.copyFolder.map(placeWords) ?? L("Copies go to a folder you choose; the originals are only read."),
                              on: session.placement == .copyToFolder) {
                if session.copyFolder == nil { choose(.copyFolder) } else { session.placement = .copyToFolder }
            }
            if session.placement == .copyToFolder, session.copyFolder != nil {
                HStack {
                    Spacer(minLength: 0)
                    Button(L("Choose Folder…")) { choose(.copyFolder) }.buttonStyle(MacImportButtonStyle(kind: .small))
                }
                .padding(.horizontal, MacMetric.pt(12))
            }
            MacImportRadioRow(title: session.intoLibraryTitle,
                              detail: session.destinationSource?.kind == .session ? nil : L("Into its Originals folder, by date."),
                              on: session.placement == .intoLibrary) { session.placement = .intoLibrary }
            HStack(spacing: MacMetric.pt(8)) {
                Text(L("Collection")).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
                Text(L("Recent Imports")).font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, MacMetric.pt(12)).padding(.top, MacMetric.pt(6))
        }
        .disabled(session.progress != nil)
    }

    private var destinationMenu: some View {
        Menu {
            ForEach(session.destinations) { s in
                Button { session.destination = .source(s.id) } label: {
                    Label(s.name, systemImage: MacWords.symbol(s.kind))
                }
            }
            if !session.destinations.isEmpty { Divider() }
            Button { session.destination = .newCatalog } label: { Label(L("New Catalog…"), systemImage: "plus") }
        } label: {
            HStack(spacing: MacMetric.pt(6)) {
                Image(systemName: MacWords.symbol(session.destinationSource?.kind ?? .catalog))
                    .font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
                Text(session.destinationSource?.name ?? L("New Catalog"))
                    .font(MacMetric.font(12, .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(MacMetric.font(9, .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, MacMetric.pt(8))
            .frame(minHeight: MacMetric.pt(24))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(L("Import To"))
    }

    /// The new catalog's name and folder: made when the import starts, so a cancelled flow leaves none.
    private var newCatalog: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(4)) {
            HStack(spacing: MacMetric.pt(8)) {
                Text(L("Name")).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                    .frame(width: MacMetric.pt(48), alignment: .trailing)
                TextField(L("SpektraLab Catalog"), text: $session.newCatalogName)
                    .font(MacMetric.font(12)).textFieldStyle(.plain)
                    .focused(naming)
                    .onSubmit { naming.wrappedValue = false }
                    .padding(.horizontal, MacMetric.pt(6))
                    .frame(height: MacMetric.pt(22))
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
            }
            HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(8)) {
                Text(L("Where")).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                    .frame(width: MacMetric.pt(48), alignment: .trailing)
                Text(placeWords(session.newCatalogFolder))
                    .font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Choose…")) { choose(.catalogFolder) }.buttonStyle(MacImportButtonStyle(kind: .small))
            }
        }
        .padding(.horizontal, MacMetric.pt(12))
        .padding(.vertical, MacMetric.pt(4))
    }

    // Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(2)) {
            MacImportHeading(title: L("Filters"))
            Text(L("Format")).font(MacMetric.font(11, .semibold)).foregroundStyle(Theme.dim)
                .padding(.horizontal, MacMetric.pt(12)).padding(.top, MacMetric.pt(2))
            ForEach(session.formatCounts, id: \.format) { f in
                MacImportCheckRow(title: f.format, count: f.count, on: Binding(
                    get: { session.formats.contains(f.format) },
                    set: { on in if on { session.formats.insert(f.format) } else { session.formats.remove(f.format) } }))
            }
            let days = session.dayCounts
            if !days.isEmpty {
                Text(L("Date Taken")).font(MacMetric.font(11, .semibold)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, MacMetric.pt(12)).padding(.top, MacMetric.pt(6))
                ForEach(days, id: \.day) { d in
                    MacImportCheckRow(title: Self.dayTitle(d.day), count: d.count, on: Binding(
                        get: { session.days.contains(d.day) },
                        set: { on in if on { session.days.insert(d.day) } else { session.days.remove(d.day) } }))
                }
            }
        }
        .disabled(session.progress != nil)
    }

    /// "3 Oct 2026" in the app's language; "" is "No Date" (a header not read yet, or none).
    static func dayTitle(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return L("No Date") }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Language.shared.current.locale))
    }
}

// MARK: - the right: the grid of what was found

private struct MacImportBrowser: View {
    @Bindable var session: MacImportSession
    @State private var marquee: MacMarquee?
    @State private var lastClick: (id: MacImage.ID, at: Date)?

    private var browser: MacLibraryBrowser { session.browser }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.wall).frame(height: 1)
            if browser.viewerShown {
                HStack(spacing: 0) {
                    BrowserViewerSplit(image: browser.primary(session.rows), open: { _ in })
                    Rectangle().fill(Theme.wall).frame(width: 1)
                    content.frame(width: MacMetric.pt(browser.browserWidth))
                }
            } else {
                content
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        @Bindable var browser = browser
        let rows = session.rows
        let picked = browser.selection.count
        return HStack(spacing: MacMetric.pt(8)) {
            Button { browser.viewerShown.toggle() } label: { MacViewerGlyph(on: browser.viewerShown) }
            .buttonStyle(.plain)
            .help(L("Viewer"))
            .accessibilityLabel(L("Viewer"))
            .accessibilityAddTraits(browser.viewerShown ? .isSelected : [])
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: MacMetric.pt(6)) {
                Text(rows.count == session.files.count ? L("\(rows.count.formatted()) images")
                                                       : L("\(rows.count.formatted()) of \(session.files.count.formatted()) images"))
                    .font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                if picked > 0 {
                    Text(L("\(picked.formatted()) selected")).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                }
            }
            .fixedSize()
            .layoutPriority(1)
            HStack(spacing: MacMetric.pt(5)) {
                Image(systemName: "photo").font(MacMetric.font(9)).foregroundStyle(Theme.dim)
                Slider(value: $browser.cell, in: MacMetric.cellRange)
                    .frame(width: MacMetric.pt(100))
                    .controlSize(.mini)
                    .accessibilityLabel(L("Thumbnail Size"))
                Image(systemName: "photo").font(MacMetric.font(13)).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, MacMetric.pt(10))
        .frame(height: MacMetric.pt(MacMetric.gridHeader))
        .background(Theme.panel)
    }

    @ViewBuilder private var content: some View {
        if session.rows.isEmpty {
            VStack(spacing: MacMetric.pt(8)) {
                if session.scanning {
                    ProgressView().controlSize(.small)
                    Text(L("Looking for pictures…")).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                } else if session.picked.isEmpty {
                    Text(L("Choose a folder or pictures to import.")).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                } else {
                    Text(L("No pictures were found.")).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                    Text(L("RAW, JPEG, HEIF, TIFF, PNG and DNG files are imported; sidecars and movies are left out."))
                        .font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MacMetric.pt(24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let rows = session.rows
            let layout = MacGridLayout(width: geo.size.width, cell: browser.cell, count: rows.count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: layout.items, alignment: .leading, spacing: layout.gap) {
                        ForEach(rows) { image in
                            let excluded = session.isExcluded(image.id)
                            MacGridCell(image: image, side: layout.side, selected: browser.selection.contains(image.id),
                                        focused: browser.focus == image.id && browser.selection.count > 1)
                                .opacity(excluded ? 0.35 : 1)
                                .overlay(alignment: .topLeading) {
                                    if excluded {
                                        Text(L("Already Imported")).font(MacMetric.font(9, .semibold)).foregroundStyle(Theme.text)
                                            .padding(.horizontal, MacMetric.pt(4)).frame(height: MacMetric.pt(14))
                                            .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(3), style: .continuous))
                                            .padding(MacMetric.pt(8))
                                            .allowsHitTesting(false)
                                    }
                                }
                                .id(image.id)
                                .modifier(MacClick { flags in click(image, flags, rows) })
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(excluded ? image.fileName + ", " + L("Already Imported") : image.fileName)
                                .accessibilityAddTraits(browser.selection.contains(image.id) ? [.isButton, .isSelected] : .isButton)
                                .accessibilityIdentifier("mac.import.cell")
                        }
                    }
                    .padding(layout.gap)
                    // The space under the last row is the grid's too: a marquee starts there, as in Finder.
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(MacMarqueeRecognizer { state, point, flags in
                        _ = MacMarquee.drive(&marquee, state, point, flags, layout: layout, rows: rows, browser: browser)
                    })
                    // A click on the empty space chooses nothing, as the library's grid (2026-10-25).
                    .modifier(MacEmptyClick(layout: layout) { browser.selectNone() })
                    .overlay(alignment: .topLeading) { MacMarquee.drawn(marquee) }
                    .padding(.bottom, MacMetric.pt(24))
                }
                .scrollIndicators(.automatic)
                .background(Theme.background)
                .onChange(of: browser.scrollTarget) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                    browser.scrollTarget = nil
                }
                .onAppear { browser.columns = layout.columns }
                .onChange(of: layout.columns) { _, n in browser.columns = n }
            }
        }
    }

    /// The library grid's click: alone, ⌘ toggles, ⇧ the run; a double click shows the picture in the viewer.
    private func click(_ image: MacImage, _ flags: UIKeyModifierFlags, _ rows: [MacImage]) {
        let command = flags.contains(.command), shift = flags.contains(.shift)
        let now = Date()
        if !command, !shift, let last = lastClick, last.id == image.id, now.timeIntervalSince(last.at) < 0.5 {
            lastClick = nil
            browser.selection = [image.id]
            browser.focus = image.id
            browser.viewerShown = true
            return
        }
        lastClick = (image.id, now)
        browser.click(image.id, command: command, shift: shift, in: rows)
    }
}

// MARK: - small parts

/// A section's heading: small capitals in `dim`, as the sidebar's.
private struct MacImportHeading: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(MacMetric.font(11, .semibold)).tracking(0.4).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MacMetric.pt(12))
            .padding(.top, MacMetric.pt(12))
            .frame(minHeight: MacMetric.pt(24), alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Capture One's check box: a square ticked, the words, a count.
private struct MacImportCheckRow: View {
    let title: String
    var detail: String? = nil
    var count: Int? = nil
    @Binding var on: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: MacMetric.pt(7)) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(MacMetric.font(13)).foregroundStyle(on ? Theme.accent : Theme.dim)
                    .frame(width: MacMetric.pt(16))
                Text(title).font(MacMetric.font(13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(MacMetric.font(12)).monospacedDigit().foregroundStyle(Theme.dim) }
                Spacer(minLength: 0)
                if let count { Text(count.formatted()).font(MacMetric.font(12)).monospacedDigit().foregroundStyle(Theme.dim) }
            }
            .padding(.horizontal, MacMetric.pt(12))
            .frame(minHeight: MacMetric.pt(MacMetric.row))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : Theme.disabledOpacity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One of the placements: a radio button, the words and what they mean under them.
private struct MacImportRadioRow: View {
    let title: String
    var detail: String?
    let on: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(7)) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(MacMetric.font(13)).foregroundStyle(on ? Theme.accent : Theme.dim)
                    .frame(width: MacMetric.pt(16))
                VStack(alignment: .leading, spacing: MacMetric.pt(1)) {
                    Text(title).font(MacMetric.font(13)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MacMetric.pt(12))
            .padding(.vertical, MacMetric.pt(3))
            .frame(minHeight: MacMetric.pt(MacMetric.row))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : Theme.disabledOpacity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The page's buttons at macOS's sizes: the primary one in the accent, the others on `Theme.card`.
struct MacImportButtonStyle: ButtonStyle {
    enum Kind { case primary, plain, small }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let small = kind == .small
        configuration.label
            .font(MacMetric.font(small ? 11 : 13, kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Theme.onSelection : Theme.text)
            .padding(.horizontal, MacMetric.pt(small ? 8 : 14))
            .frame(height: MacMetric.pt(small ? 20 : 28))
            .background(kind == .primary ? Theme.accent : Theme.card,
                        in: RoundedRectangle(cornerRadius: MacMetric.pt(6), style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : Theme.disabledOpacity)
            .fixedSize()
            .contentShape(Rectangle())
    }
}
