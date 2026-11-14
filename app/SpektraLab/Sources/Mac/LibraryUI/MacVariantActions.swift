//  MacVariantActions.swift — New Variant, Clone Variant and Delete Variant (PRD-G §3, part 2): what a person does,
//  over the store's calls (`CatalogSourcesStore.newVariant(of:clone:)`, `deleteVariant(_:)`, part 1).
//
//  One place for the three acts, as `MacLibraryActions` is for Remove and Pair: the grid's and Develop browser's
//  context menu (`MacVariantItems`), the menu bar's Image menu (`MacImageMenu`) and F2 / F3 (`MacShortcut.newVariant`,
//  `.cloneVariant`, Capture One's own keys on the Mac) all ask `refusal` and call `perform`, so an item is greyed
//  for the same reason everywhere and does the same thing however it is reached.
//
//  - **What it acts on** (`targets`): the chosen cells, one per image — the focused cell where the image's focused
//    variant is among them, else its first chosen one (PRD-G §3: "one new variant each, of the focused variant of each
//    image"). Delete acts on every chosen cell.
//  - **After New or Clone** the new cells are chosen (the focused image's new cell focused and scrolled to), and in
//    冲洗/编辑 the focused one's is opened on the page (`MacDevelopBar.open`, what a browser row asks for there).
//  - **Delete** asks first (`confirmingDelete`: the edit and the history cannot be had back; the file stays). A
//    variant open in 冲洗/编辑 is left for its neighbour first, as Capture One moves to the next variant: the one now
//    at its place in the image, else the one before it.
//  - **Refused, with the reason** (`refusal`): a pair or a double (§7.5: the items greyed, the reason under them, not
//    hidden), a picture with no library behind it, Delete on an image's last variant, Delete of every variant of an
//    image at once, Delete of a frame an export batch holds (trap 34: the batch reads that frame's edit when its turn
//    comes; New and Clone make frames no batch holds, and the page they open is not what an export reads here). One
//    of Capture One's own variants in a mirror is refused by the helper (`read_only`), and said in its own words.

import SwiftUI

@MainActor @Observable
final class MacVariantActions {
    static let shared = MacVariantActions()

    enum Act: String, CaseIterable, Sendable {
        case new, clone, delete
        var title: String {
            switch self {
            case .new: L("New Variant")
            case .clone: L("Clone Variant")
            case .delete: L("Delete Variant")
            }
        }
        var symbol: String {
            switch self {
            case .new: "plus.square.on.square"
            case .clone: "square.on.square.dashed"
            case .delete: "minus.square"
            }
        }
    }

    /// Delete Variant, asked first: the cells it is about to take.
    private(set) var deleting: [MacImage] = []
    var confirmingDelete = false
    /// An act under way: a second press waits for it (two New Variants at once would each make one, as asked, but a
    /// key held down repeating would make many).
    private(set) var busy = false

    // MARK: what it acts on

    /// The cells the context menu's items act on: the chosen ones when `image` is one of several chosen, else `image`.
    static func chosen(_ image: MacImage, rows: [MacImage]) -> [MacImage] {
        let browser = MacLibraryBrowser.shared
        let many = browser.selection.contains(image.id) && browser.selection.count > 1
        return many ? rows.filter { browser.selection.contains($0.id) } : [image]
    }

    /// The cells the Image menu and F2 / F3 act on: in 冲洗/编辑 the open frame's cell, or the chosen cells where the
    /// person has chosen others beside it; in 图库 the chosen cells.
    static func menuCells(_ model: AppServices) -> [MacImage] {
        let rows = MacLibraryUI.store(model).images
        let selection = MacLibraryBrowser.shared.selection
        let chosen = rows.filter { selection.contains($0.id) }
        if MacShellPath.develop(model.router.path) != nil, let open = MacShellBar.shared.develop?.frameID {
            guard let cell = rows.first(where: { $0.develop?.frameID == open }) else { return [] }
            return chosen.count > 1 && chosen.contains(where: { $0.id == cell.id }) ? chosen : [cell]
        }
        return chosen
    }

    /// One cell per image for New and Clone: the image's focused variant where it is chosen, else its first chosen one.
    static func targets(_ cells: [MacImage]) -> [MacImage] {
        let focus = MacLibraryBrowser.shared.focus
        var seen: [String: Int] = [:]
        var out: [MacImage] = []
        for c in cells {
            let key = c.id.source.uuidString + "/" + c.id.image
            if let i = seen[key] {
                if c.id == focus { out[i] = c }
            } else {
                seen[key] = out.count
                out.append(c)
            }
        }
        return out
    }

    // MARK: whether, and why not

    /// Why `act` cannot be done on `cells` now, in the words a greyed item shows under it; nil where it can.
    static func refusal(_ act: Act, _ cells: [MacImage], model: AppServices) -> String? {
        guard !cells.isEmpty else { return L("Choose a picture first.") }
        let store = model.macLibrary
        let library = model.library
        if cells.contains(where: { c in
            c.kind == .pair || c.develop.flatMap { library.frame($0.frameID)?.isComposite } == true
        }) {
            return L("Pairs and double exposures do not have variants yet.")
        }
        if cells.contains(where: { c in store.sources.first { $0.id == c.id.source }.map { !$0.isHelperBacked || $0.kind == .appLibrary } ?? true }) {
            return L("This library does not keep variants.")
        }
        guard act == .delete else { return nil }
        if cells.contains(where: { $0.variantCount < 2 }) {
            return cells.count == 1 ? L("This is the picture's only variant.") : L("One of these is its picture's only variant.")
        }
        // Every present variant of one image chosen: one must stay (Move to Trash deals with the picture).
        var perImage: [String: Int] = [:]
        for c in cells { perImage[c.id.source.uuidString + "/" + c.id.image, default: 0] += 1 }
        if cells.contains(where: { perImage[$0.id.source.uuidString + "/" + $0.id.image] ?? 0 >= $0.variantCount }) {
            return L("Every variant of a picture is chosen. One must stay: Move to Trash removes the picture.")
        }
        let frames = Set(cells.compactMap { $0.develop?.frameID })
        if model.exporter.isExporting, model.exporter.batch?.items.contains(where: { frames.contains($0.id) }) == true {
            return L("This variant is being exported. Delete it when the export is done.")
        }
        return nil
    }

    // MARK: doing it

    /// New or Clone of `cells` (one per image, `targets`), or Delete Variant asked of `cells`.
    func perform(_ act: Act, _ cells: [MacImage], model: AppServices) {
        let actions = MacLibraryActions.shared
        if let why = Self.refusal(act, cells, model: model) {
            actions.refusalTitle = act.title
            actions.refusal = why
            return
        }
        switch act {
        case .new, .clone: make(clone: act == .clone, Self.targets(cells), model: model)
        case .delete:
            deleting = cells
            confirmingDelete = true
        }
    }

    private func make(clone: Bool, _ cells: [MacImage], model: AppServices) {
        guard !busy else { return }
        busy = true
        let store = model.macLibrary
        let browser = MacLibraryBrowser.shared
        let focus = browser.focus
        Task {
            defer { busy = false }
            var made: [CatalogSourcesStore.MadeVariant] = []
            var focused: CatalogSourcesStore.MadeVariant?
            for c in cells {
                do {
                    #if DEBUG && SPK_ENGINE
                    TransitionMarks.mark("helper>")
                    defer { TransitionMarks.mark("helper<") }
                    #endif
                    let m = try await store.newVariant(of: c.id, clone: clone)
                    made.append(m)
                    if c.id == focus || focused == nil { focused = m }
                } catch {
                    MacLibraryActions.shared.refusalTitle = clone ? Act.clone.title : Act.new.title
                    MacLibraryActions.shared.refusal = Self.said(error, c)
                    break
                }
            }
            guard let focused else { return }
            // The new cells chosen, the focused image's in focus: what a person looks at next.
            browser.selection = Set(made.map(\.cell))
            browser.focus = focused.cell
            browser.anchor = focused.cell
            browser.scrollTarget = focused.cell
            // In 冲洗/编辑 the new variant is opened on the page, as Capture One shows the variant it made — once the
            // selection is on the screen: in the same turn the page's change of frame held the new cell's selection
            // back with it (2.4.0 A2b: ~250–370 ms from the helper's answer, Debug, the transitions case).
            if MacShellPath.develop(model.router.path) != nil {
                AfterFrame.run(after: 2) { MacShellBar.shared.develop?.open(focused.frame) }
            }
        }
    }

    /// Delete, confirmed.
    func delete(model: AppServices) {
        let cells = deleting
        deleting = []
        guard !cells.isEmpty, !busy else { return }
        if let why = Self.refusal(.delete, cells, model: model) {
            MacLibraryActions.shared.refusalTitle = Act.delete.title
            MacLibraryActions.shared.refusal = why
            return
        }
        busy = true
        let store = model.macLibrary
        let browser = MacLibraryBrowser.shared
        Task {
            defer { busy = false }
            // A variant open on the page is left for its neighbour first (Capture One moves to the next variant): the
            // page never shows a frame that is going.
            let open = MacShellPath.develop(model.router.path) != nil ? MacShellBar.shared.develop : nil
            let leaving = cells.first { $0.develop?.frameID != nil && $0.develop?.frameID == open?.frameID }
            var neighbour: MacImage?
            if let leaving {
                let siblings = store.images.filter { $0.id.source == leaving.id.source && $0.id.image == leaving.id.image }
                let staying = siblings.filter { s in !cells.contains { $0.id == s.id } }
                let at = siblings.firstIndex { $0.id == leaving.id } ?? 0
                neighbour = staying.first { s in (siblings.firstIndex { $0.id == s.id } ?? 0) > at } ?? staying.last
            }
            if let neighbour, let open {
                if let frame = neighbour.develop?.frameID {
                    open.open(frame)
                } else if let made = try? await store.frames(for: [neighbour.id]), let frame = made.frames[neighbour.id] {
                    open.open(frame)
                }
                // The page lets go of the frame before it goes.
                for _ in 0..<50 where MacShellBar.shared.develop?.frameID == leaving?.develop?.frameID {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            var gone = 0
            for c in cells {
                do {
                    try await store.deleteVariant(c.id)
                    gone += 1
                } catch {
                    MacLibraryActions.shared.refusalTitle = Act.delete.title
                    MacLibraryActions.shared.refusal = Self.said(error, c)
                    break
                }
            }
            if gone > 0 {
                // The image's cells were numbered again; the neighbour (or the image's first) is chosen.
                let pick = neighbour.flatMap { n in store.images.first { $0.develop?.frameID != nil && $0.develop?.frameID == n.develop?.frameID } }
                    ?? store.images.first { c in cells.contains { $0.id.source == c.id.source && $0.id.image == c.id.image } }
                if let pick {
                    browser.selection = [pick.id]
                    browser.focus = pick.id
                    browser.anchor = pick.id
                }
            }
        }
    }

    func cancelDelete() { deleting = [] }

    /// A refusal from the store or the helper, as the person reads it.
    static func said(_ error: Error, _ cell: MacImage) -> String {
        switch error as? MacLibraryError {
        case .readOnly? where cell.fromCaptureOne:
            L("This variant is Capture One's own. Delete it in Capture One: SpektraLab never changes a Capture One catalog.")
        case .lastVariant?: L("This is the picture's only variant.")
        case .notForVariants?: L("Pairs and double exposures do not have variants yet.")
        default: L(shown: error.localizedDescription)
        }
    }

    /// The confirmation's words: "Delete variant 2 of 3 of IMG_0001.jpg?" / "Delete 3 variants?".
    var deleteTitle: String {
        guard deleting.count == 1, let c = deleting.first else { return L("Delete \(deleting.count) variants?") }
        return L("Delete variant \(c.variantNumber) of \(c.variantCount) of \(c.fileName)?")
    }
    var deleteMessage: String {
        deleting.count == 1 ? L("Its edit, previews and edit history are deleted and cannot be had back. The file stays.")
                            : L("Their edits, previews and edit histories are deleted and cannot be had back. The files stay.")
    }
}

/// The three items in a picture's menu (the grid's and Develop browser's): New Variant, Clone Variant, then Delete
/// Variant where the image has more than one (PRD-G §3). Refused, they are greyed and the reason is said under them.
struct MacVariantItems: View {
    let chosen: [MacImage]
    @Environment(AppServices.self) private var model

    var body: some View {
        let acts = MacVariantActions.shared
        let make = MacVariantActions.refusal(.new, chosen, model: model)
        let offerDelete = chosen.contains { $0.variantCount > 1 }
        let delete = offerDelete ? MacVariantActions.refusal(.delete, chosen, model: model) : nil
        Button { acts.perform(.new, chosen, model: model) } label: {
            Label(MacVariantActions.Act.new.title, systemImage: MacVariantActions.Act.new.symbol)
        }
        .disabled(make != nil)
        .accessibilityIdentifier("library.menu.newVariant")
        Button { acts.perform(.clone, chosen, model: model) } label: {
            Label(MacVariantActions.Act.clone.title, systemImage: MacVariantActions.Act.clone.symbol)
        }
        .disabled(make != nil)
        .accessibilityIdentifier("library.menu.cloneVariant")
        if let make { Text(make) }
        if offerDelete {
            Button(role: .destructive) { acts.perform(.delete, chosen, model: model) } label: {
                Label(MacVariantActions.Act.delete.title, systemImage: MacVariantActions.Act.delete.symbol)
            }
            .disabled(delete != nil)
            .accessibilityIdentifier("library.menu.deleteVariant")
            if let delete, delete != make { Text(delete) }
        }
    }
}

/// The menu bar's Image menu (Capture One's): the same three, on the open frame in 冲洗/编辑, else on the chosen
/// pictures. The keys are the registry's (F2, F3: `MacShortcut`), listed under Keyboard Shortcuts with the others.
struct MacImageMenu: Commands {
    let model: AppServices

    var body: some Commands {
        CommandMenu(L("Image")) {
            let cells = MacVariantActions.menuCells(model)
            let acts = MacVariantActions.shared
            let make = MacVariantActions.refusal(.new, cells, model: model)
            let delete = MacVariantActions.refusal(.delete, cells, model: model)
            Button(MacVariantActions.Act.new.title) { acts.perform(.new, MacVariantActions.menuCells(model), model: model) }
                .disabled(make != nil)
            Button(MacVariantActions.Act.clone.title) { acts.perform(.clone, MacVariantActions.menuCells(model), model: model) }
                .disabled(make != nil)
            // The reason under the greyed items (PRD-G §7.5), but not "choose a picture": a greyed menu says that.
            if let make, !cells.isEmpty { Text(make) }
            Divider()
            Button(MacVariantActions.Act.delete.title) { acts.perform(.delete, MacVariantActions.menuCells(model), model: model) }
                .disabled(delete != nil)
            if let delete, !cells.isEmpty, delete != make { Text(delete) }
        }
    }
}

/// Delete Variant's question, drawn with the library's own (`macLibraryDialogs`).
struct MacVariantDialogs: ViewModifier {
    @Environment(AppServices.self) private var model

    func body(content: Content) -> some View {
        let acts = MacVariantActions.shared
        content
            .confirmationDialog(acts.deleteTitle,
                                isPresented: Binding(get: { acts.confirmingDelete }, set: { acts.confirmingDelete = $0 }),
                                titleVisibility: .visible) {
                Button(L("Delete Variant"), role: .destructive) { acts.delete(model: model) }
                Button(L("Cancel"), role: .cancel) { acts.cancelDelete() }
            } message: {
                Text(acts.deleteMessage)
            }
    }
}
