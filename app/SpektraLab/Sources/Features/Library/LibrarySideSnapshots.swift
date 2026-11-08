//  LibrarySideSnapshots.swift — the library side's pages, for the snapshot harness.
//  Lanes A (bring pictures in), B (library) and F (where the photos live), each over
//  the window's library mode (`LibraryScreen`, the Mac library page).
//
//  Each page in the state its drawing shows, over the demo library the drawing
//  is drawn with. A sheet is drawn over its page with `SheetStage`, as the
//  drawing draws it; in the app the router presents it. Where a drawing shows
//  a moment the demo seed does not hold (frames picked in Select), the page's
//  model is put in that moment here, and nowhere else.

import SwiftUI

enum LibrarySideSnapshots {
    @MainActor static var pages: [SnapshotPage] {
        [
            SnapshotPage("A4", "Import") { _ in
                SheetStage(top: SheetRoute.importSources.top) { LibraryScreen() } sheet: { ImportSheet() }
            },
            SnapshotPage("B1", "First run", scenario: .empty) { _ in LibraryScreen() },
            SnapshotPage("B2", "Library") { _ in LibraryScreen() },
            SnapshotPage("B3", "Importing", scenario: .importing) { _ in
                LibraryScreen()
            },
            SnapshotPage("B4", "Select", scenario: .importing) { model in
                selecting(model)
            },
            SnapshotPage("B5", "Info") { model in
                let id = model.library.selectedID ?? UUID()
                SheetStage(top: SheetRoute.info(id).top) { LibraryScreen() } sheet: { InfoSheet(frameID: id) }
            },
            SnapshotPage("F2", "Disk unplugged", scenario: .offline) { _ in
                LibraryScreen()
            },
            SnapshotPage("F3", "Original missing", scenario: .offline) { model in
                let id = model.library.frames.first { $0.original == .missing }?.id ?? UUID()
                SheetStage(top: SheetRoute.locate(id).top) { LibraryScreen() } sheet: { LocateSheet(frameID: id) }
            },
        ]
    }

    /// B4: the import has finished developing, three of today's frames are
    /// picked, and the clipboard holds two groups copied from `_DSC0061`.
    @MainActor private static func selecting(_ model: AppServices) -> some View {
        let library = model.library
        for frame in library.frames { library.update(frame.id) { $0.develop = .developed } }
        library.importBanner = nil
        let today = library.days.first?.frames ?? []
        library.picked = Set([0, 1, 3].compactMap { today.indices.contains($0) ? today[$0].id : nil })
        library.isSelecting = true
        if let source = library.frames.first {
            library.clipboard = SettingsClip(groups: [.filmAndPaper, .exposure], settings: source.edit,
                                             sourceName: source.fileName)
        }
        return LibraryScreen()
    }
}
