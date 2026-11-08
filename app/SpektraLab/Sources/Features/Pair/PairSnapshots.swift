//  PairSnapshots.swift — the half-frame pair's darkroom, for the snapshot harness.
//
//  design/pair v2 (`design/src/gen_pair_v2.py`). One `SnapshotPage` a drawn
//  page and state, as `FilmEdgeSnapshots` has them; registered in
//  `SnapshotHarness.pages`. Lane H: H3 the film · H4 a frame's exposure · H5
//  the piece · H6 a frame's picture and date · H7 a frame's print · H8 placing
//  a picture · H9 an empty hole · H10 turned. (H1 and H2, the way in, are
//  `PairEntrySnapshots`.)
//
//  The drawings' pair is the street frame beside the Bund, on the street
//  frame's Gold 200 (`FilmEdgeSnapshots.street`), the Bund moved 0.3 of its
//  slack to the right under its hole; turned, the Bund above the sea frame.
//  Nothing is developed in the harness: the piece in the picture's room is the
//  pair's guide.
//
//  After the drawn pages come states the design does not draw and this build
//  makes by interpretation. They are held against nothing (``) and
//  exist to be looked at.

import SwiftUI

@MainActor
enum PairSnapshots {
    static var pages: [SnapshotPage] {
        [
            SnapshotPage("H3", "Pair · the film") { model in
                DevelopPane(frameID: kept(model), opening: .pair(.film, tab: .film))
            },
            SnapshotPage("H4", "Pair · a frame's exposure") { model in
                DevelopPane(frameID: kept(model), opening: .pair(.right, tab: .film))
            },
            SnapshotPage("H5", "Pair · the piece") { model in
                let id = kept(model)
                model.library.update(id) { $0.edit.dateBack.active = true }
                return DevelopPane(frameID: id, opening: .pair(.film, tab: .frame))
            },
            SnapshotPage("H6", "Pair · a frame's picture and date") { model in
                let id = kept(model)
                model.library.update(id) { $0.edit.dateBack.active = true }
                return DevelopPane(frameID: id, opening: .pair(.right, tab: .frame))
            },
            SnapshotPage("H7", "Pair · a frame's print") { model in
                let id = kept(model)
                model.library.update(id) { f in
                    f.pair?.pinPrints(to: .init(f.edit.params))
                    f.pair?.right?.print?.yFilterShift = 0.10
                    f.pair?.right?.print?.mFilterShift = 0.05
                }
                return DevelopPane(frameID: id, opening: .pair(.right, tab: .print))
            },
            SnapshotPage("H8", "Pair · placing a picture") { model in
                var pair = drawn(model, layer: .right).pair
                pair.right?.placement.scale = 1.35
                pair.right?.placement.y = -0.2
                return PairPlaceFlow(pairID: UUID(), side: .right, snapshot: pair)
            },
            SnapshotPage("H9", "Pair · an empty hole") { model in
                let made = started(model, [street(model)])
                let id = model.keepPair(made.pair, look: made.look) ?? UUID()
                model.library.update(id) { $0.develop = .developed }
                return DevelopPane(frameID: id, opening: .pair(.right, tab: .frame))
            },
            SnapshotPage("H10", "Pair · turned") { model in
                let made = turned(model, layer: .film)
                let id = model.keepPair(made.pair, look: made.look) ?? UUID()
                model.library.update(id) { $0.develop = .developed; $0.edit.dateBack.active = true }
                return DevelopPane(frameID: id, opening: .pair(.film, tab: .frame))
            },

            // --- not drawn by the design
            // H10's two landscape frames switched to Level (2026-10-20): each turned a quarter to stand in its hole.
            SnapshotPage("H10-level", "Pair · two wide frames held level") { model in
                var made = turned(model, layer: .film)
                made.pair.turned = true                 // as H10: two landscape frames start one above the other
                let pictures = Dictionary(uniqueKeysWithValues: HalfFramePair.Side.allCases.compactMap { side -> (HalfFramePair.Side, CGSize)? in
                    guard let hole = made.pair[side], let f = model.library.frame(hole.frame) else { return nil }
                    let shown = f.displaySizeUnder(hole.geometry)
                    return (side, CGSize(width: shown.width, height: shown.height))
                })
                made.pair.holdCamera(turned: false, pictures: pictures)
                let id = model.keepPair(made.pair, look: made.look) ?? UUID()
                model.library.update(id) { $0.develop = .developed }
                return DevelopPane(frameID: id, opening: .pair(.film, tab: .frame))
            },
            SnapshotPage("H5-strip", "The piece · on its strip, the data face") { model in
                let id = kept(model)
                model.library.update(id) { $0.pair?.onStrip = true; $0.edit.dateBack.active = true; $0.edit.dateBack.style = .data }
                return DevelopPane(frameID: id, opening: .pair(.film, tab: .frame))
            },
            SnapshotPage("H6-undated", "A frame · the back off for it") { model in
                let id = kept(model)
                model.library.update(id) { $0.edit.dateBack.active = true; $0.pair?.right?.dated = false }
                return DevelopPane(frameID: id, opening: .pair(.right, tab: .frame))
            },
            SnapshotPage("H6-held", "The frame the pair began with") { model in
                // As the Library's *Pair* makes it of the frame on top, a second frame then added (`AppServices.makePair`).
                var made = started(model, [street(model), bund(model)])
                made.pair.origin = street(model)
                let id = model.keepPair(made.pair, look: made.look) ?? UUID()
                model.library.update(id) { $0.develop = .developed }
                return DevelopPane(frameID: id, opening: .pair(.left, tab: .frame))
            },
            SnapshotPage("H6-missing", "A frame that has left the library") { model in
                let id = kept(model)
                model.library.update(id) { $0.pair?.right?.frame = UUID() }
                return DevelopPane(frameID: id, opening: .pair(.right, tab: .frame))
            },
            SnapshotPage("H7-film", "The film's print, with a frame's own beside it") { model in
                let id = kept(model)
                model.library.update(id) { f in
                    f.pair?.pinPrints(to: .init(f.edit.params))
                    f.pair?.right?.print?.yFilterShift = 0.10
                }
                return DevelopPane(frameID: id, opening: .pair(.film, tab: .print))
            },
            SnapshotPage("H4-pro", "A frame's exposure · pro-control") { model in
                model.settings.proControl = true
                return DevelopPane(frameID: kept(model), opening: .pair(.left, tab: .film))
            },
            SnapshotPage("H4-source", "A frame's source exposure · pro-control") { model in
                model.settings.proControl = true
                let id = kept(model)
                model.library.update(id) { $0.pair?.left?.autoExposure = false }
                return DevelopPane(frameID: id, opening: .pair(.left, tab: .film))
            },
            SnapshotPage("H11", "A frame · Scene Placement") { model in
                var opening = DevelopOpening.pair(.right, tab: .effects)
                opening.placementOpen = true
                return DevelopPane(frameID: kept(model), opening: opening)
            },
            SnapshotPage("H7-pro", "A frame's print · pro-control") { model in
                model.settings.proControl = true
                let id = kept(model)
                model.library.update(id) { f in
                    f.pair?.pinPrints(to: .init(f.edit.params))
                    f.pair?.right?.print?.yFilterShift = 0.10
                    f.pair?.right?.printScope = .film
                }
                return DevelopPane(frameID: id, opening: .pair(.right, tab: .print))
            },
            SnapshotPage("H12", "A frame · its own white balance (pro-control)") { model in
                model.settings.proControl = true
                return DevelopPane(frameID: kept(model), opening: .pair(.right, tab: .scene))
            },
            SnapshotPage("H13", "A frame · Effects, and whose Scene Placement") { model in
                let id = kept(model)
                // The right frame's own: the look shows the left's until a frame is picked (`HalfFramePair.show`).
                model.library.update(id) { $0.edit.params.sceneLatitudeOther.highlightPullBack = 0.75 }
                return DevelopPane(frameID: id, opening: .pair(.right, tab: .effects))
            },
            SnapshotPage("H8-turned", "Placing · turned") { model in
                PairPlaceFlow(pairID: UUID(), side: .left, snapshot: turned(model, layer: .left).pair)
            },
            SnapshotPage("G9", "A pair's tile") { model in
                tiles(model)
            },
        ]
    }

    /// The drawings' pair, kept in the library as the pair's page keeps one.
    static func kept(_ model: AppServices) -> LibraryFrame.ID {
        let made = drawn(model, layer: .film)
        let id = model.keepPair(made.pair, look: made.look) ?? UUID()
        model.library.update(id) { $0.develop = .developed }
        return id
    }

    /// The street frame, as the Film Edge drawings have it: upright, on Gold 200.
    static func street(_ model: AppServices) -> LibraryFrame.ID { FilmEdgeSnapshots.street(model) }

    /// A demo frame by its picture, developed.
    static func sample(_ model: AppServices, _ name: String) -> LibraryFrame.ID {
        let id = model.library.frames.first { $0.picture == .sample(name) }?.id ?? UUID()
        model.library.update(id) { $0.develop = .developed }
        return id
    }

    static func bund(_ model: AppServices) -> LibraryFrame.ID { sample(model, "bund.jpg") }

    /// A pair as the app makes one of these frames: the page's own start.
    static func started(_ model: AppServices, _ frames: [LibraryFrame.ID]) -> PairStart {
        PairStart.make(.new(first: frames.first, second: frames.count > 1 ? frames[1] : nil), library: model.library)
    }

    /// The drawings' pair: the street frame and the Bund, held level.
    static func drawn(_ model: AppServices, layer: HalfFramePair.Layer) -> PairStart {
        var s = started(model, [street(model), bund(model)])
        s.layer = layer
        // `gen_pair.BUND`: 0.3 of its slack to the right; +0.5 EV over a meter that read +0.4.
        s.pair.right?.placement.x = 0.3
        s.pair.right?.exposureEV = 0.5
        s.pair.right?.meteredEV = 0.4
        s.pair.left?.meteredEV = 0.1
        return s
    }

    /// The camera turned: two landscape frames, one above the other — in the
    /// library's own order, which is how a pair fills its holes (`PairStart.make`),
    /// so the hall is the top frame and the Bund the bottom one, as H10 draws
    /// them. Made on the street frame's film so the film's line reads as the drawing's.
    static func turned(_ model: AppServices, layer: HalfFramePair.Layer) -> PairStart {
        var s = started(model, [bund(model), sample(model, "t5.jpg")])
        s.layer = layer
        if let first = model.library.frame(street(model)) { s.look = HalfFramePair.look(from: first.edit) }
        return s
    }

    /// A pair as the grid shows it, at a tile's size and at the top frame's:
    /// full, with an empty hole, and turned.
    private static func tiles(_ model: AppServices) -> some View {
        let full = drawn(model, layer: .film).pair
        var half = full
        half.right = nil
        let stacked = turned(model, layer: .film).pair
        let frame: (HalfFramePair.Hole) -> LibraryFrame? = { model.library.frame($0.frame) }
        return VStack(spacing: 24) {
            HStack(spacing: Theme.Metric.gridGap) {
                PairTilePicture(pair: full, side: 129.67, frame: frame)
                PairTilePicture(pair: half, side: 129.67, frame: frame)
                PairTilePicture(pair: stacked, side: 129.67, frame: frame)
            }
            PairTilePicture(pair: full, side: 262, frame: frame)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
