//  BlackAndWhiteSnapshots.swift — black and white off the develop page, for the snapshot harness.
//
//  None of it is drawn (2026-10-09). Every place a pair or a kind is set in type
//  over the library, with the longest pair black and white brings —
//  `HB5 Plus 400 · Multigrada IV RC` — to see that it fits where
//  `Porta 400 · Supera Enduro` was drawn: the library's line and tile, Info, the
//  import banner, the Import sheet and First run.
//
//  The develop page's own black-and-white states are `DarkroomSnapshots`'
//  (`-bw`). The demo's pictures stay the colour ones the drawings have.

import SwiftUI

enum BlackAndWhiteSnapshots {
    static let hb5 = "ilford_hp5_plus_400"

    @MainActor static var pages: [SnapshotPage] {
        [
            // The longest pair, wherever a pair is set in type.
            SnapshotPage("B2-bw", "Library · a black-and-white frame") { model in
                _ = longest(model)
                return LibraryScreen()
            },
            SnapshotPage("B5-bw", "Info · a black-and-white frame") { model in
                let id = longest(model)
                SheetStage(top: SheetRoute.info(id).top) { LibraryScreen() } sheet: { InfoSheet(frameID: id) }
            },
            SnapshotPage("B3-bw", "Importing · onto a black-and-white film", scenario: .importing) { model in
                for frame in model.library.frames { model.library.update(frame.id) { $0.edit.params.load(film: hb5) } }
                return LibraryScreen()
            },
            SnapshotPage("A4-bw", "Import · develops with a black-and-white film") { model in
                model.settings.newFrameFilm = hb5
                return SheetStage(top: SheetRoute.importSources.top) { LibraryScreen() } sheet: { ImportSheet() }
            },
            SnapshotPage("B1-bw", "First run · a black-and-white film", scenario: .empty) { model in
                model.settings.newFrameFilm = hb5
                return LibraryScreen()
            },
        ]
    }

    /// The library's selected frame on the longest pair there is.
    @MainActor private static func longest(_ model: AppServices) -> LibraryFrame.ID {
        let id = model.library.selectedID ?? model.library.frames.first?.id ?? UUID()
        model.library.update(id) { $0.edit.params.load(film: hb5) }
        return id
    }
}
