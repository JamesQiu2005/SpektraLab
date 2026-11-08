//  PairEntrySnapshots.swift — the ways into a half-frame pair, for the snapshot harness.
//
//  design/pair v2 (`design/src/gen_pair_v2.py`): H1, the Library with Pair
//  among the actions for the frame on top; H2, the sheet that asks for the
//  second frame. And the two ways in that v1 drew and v2 keeps: G1, Select
//  with Pair beside All and Cancel; G2, the Film Edge flow's Format line on
//  Half. All four are other folders' pages with one part of the pair's on each
//  (`PairParts.swift`, `PairWithSheet.swift`).
//
//  **The library is the drawings' own day.** The street frame is of today, 30
//  September, as the Library's drawings have it (the Film Edge drawings date
//  it 1 October, for the date their back prints: `FilmEdgeSnapshots.street`),
//  so the grid has the drawings' two days and its rows are where they draw them.
//
//  Where a page still differs from its drawing, and why:
//  - the day under Today reads *Monday 28 Sep*, which 28 September 2026 was;
//    the drawings say Sunday;
//  - **G1's pair** is the snow frame and the lights, as drawn, but the app
//    makes it as it makes any pair: after its own first frame (the drawing
//    sets it after the Bund), and turned, since both are landscape pictures
//    (the drawing cuts each to an upright hole).
//
//  After the drawn pages come states the design does not draw. They are held
//  against nothing (``) and exist to be looked at.

import SwiftUI

@MainActor
enum PairEntrySnapshots {
    static var pages: [SnapshotPage] {
        [
            SnapshotPage("H1", "Library · Pair among the actions") { model in
                library(model)
            },
            SnapshotPage("H2", "Pair With · the second frame") { model in
                let under = library(model)
                let first = model.library.selectedID ?? UUID()
                return SheetStage(top: PairLayout.pickerTop) {
                    under
                } sheet: {
                    PairWithSheet(first: first, keepFilmEdge: false)
                }
            },
            SnapshotPage("G1", "Select · Pair") { model in
                let library = model.library
                settle(model)
                let picks = [PairSnapshots.street(model), PairSnapshots.bund(model)]
                today(model, picks[0], at: (10, 20))
                // A pair made before, in the grid after its first frame.
                let made = PairSnapshots.started(model, [PairSnapshots.sample(model, "t6.jpg"), PairSnapshots.sample(model, "t7.jpg")])
                model.keepPair(made.pair, look: made.look)
                library.picked = Set(picks)
                library.isSelecting = true
                return LibraryScreen()
            },
            SnapshotPage("G2", "Film Edge · Film, on Half") { model in
                var draft = FilmEdgeSnapshots.draft(model)
                draft.filmEdge.format = .half
                draft.filmEdge.turn = 0
                return FilmEdgeFlow(frameID: PairSnapshots.street(model), entry: .film, snapshot: .init(draft: draft))
            },

            // --- not drawn by the design
            SnapshotPage("H1-pair", "Library · a pair on top") { model in
                library(model, pairOnTop: true)
            },
            SnapshotPage("H1-first", "Library · Pair, with one photograph and no pair") { model in
                settle(model)
                let street = PairSnapshots.street(model)
                today(model, street, at: (17, 20))
                model.library.remove(Set(model.library.frames.map(\.id).filter { $0 != street }))
                return LibraryScreen()
            },
            SnapshotPage("H2-alone", "Pair With · the only photograph") { model in
                settle(model)
                let street = PairSnapshots.street(model)
                today(model, street, at: (17, 20))
                model.library.remove(Set(model.library.frames.map(\.id).filter { $0 != street }))
                return SheetStage(top: PairLayout.pickerTop) {
                    LibraryScreen()
                } sheet: {
                    PairWithSheet(first: street, keepFilmEdge: false)
                }
            },
            SnapshotPage("H2-film-edge", "Pair With · from a half frame's Film Edge, over its develop page") { model in
                settle(model)
                // The Bund on Half, as the flow's Format line writes it before it leaves for a pair.
                let first = PairSnapshots.bund(model)
                model.library.update(first) { f in
                    f.edit.filmEdge.active = true
                    f.edit.filmEdge.format = .half
                    f.edit.filmEdge.cameraSeed = 19
                    f.edit.filmEdge.turn = FilmEdgeFormat.half.defaultTurn(pictureAspect: f.originalSize.aspect)
                }
                return SheetStage(top: PairLayout.pickerTop) {
                    DevelopPane(frameID: first)
                } sheet: {
                    PairWithSheet(first: first, keepFilmEdge: true)
                }
            },
            SnapshotPage("H2-filtered", "Pair With · over the Library on Favourites") { model in
                let under = library(model)
                let first = model.library.selectedID ?? UUID()
                model.library.update(first) { $0.isFavourite = true }
                model.library.filter = .favourites
                return SheetStage(top: PairLayout.pickerTop) {
                    under
                } sheet: {
                    PairWithSheet(first: first, keepFilmEdge: false)
                }
            },
        ]
    }

    /// The Library as H1 draws it: the street frame on top, taken today at
    /// 17:20, and the drawings' pair kept after it — or, with `pairOnTop`,
    /// that pair on top.
    private static func library(_ model: AppServices, pairOnTop: Bool = false) -> some View {
        settle(model)
        let pair = PairSnapshots.kept(model)
        let street = PairSnapshots.street(model)
        // A pair is of its first frame's day: it sits after that frame.
        for id in [street, pair] { today(model, id, at: (17, 20)) }
        model.library.selectedID = pairOnTop ? pair : street
        return LibraryScreen()
    }

    /// Every frame developed, and nothing said over the grid: the drawings' still library.
    private static func settle(_ model: AppServices) {
        let library = model.library
        for frame in library.frames { library.update(frame.id) { $0.develop = .developed } }
        library.importBanner = nil
        library.clipboard = nil
    }

    /// A frame taken on the drawings' own day, 30 September 2026.
    private static func today(_ model: AppServices, _ id: LibraryFrame.ID, at time: (hour: Int, minute: Int)) {
        model.library.update(id) { $0.captureDate = DemoLibrary.date(2026, 9, 30, time.hour, time.minute) }
    }
}
