//  PairParts.swift — the pair's parts on pages that are not its own.
//
//  the page layout and
//  the page layout The pages a pair is reached
//  from, or shown on, belong to other folders — the Library and its Select,
//  the Film Edge flow's Film step, the develop page's Frame tab — and each
//  takes one of these behind `FeatureFlags.halfFramePair`:
//  `LibraryScreen.actions`, and where PAIR-WIRING.md §8 says for the first
//  drawings' three, `SelectModeView.titleBar`, `FilmStepPanel` and `FramePanel`.
//
//  **Three ways in, one sheet** (design/pair v2). The Library's *Pair* on the
//  frame on top, Select's *Pair* with one frame picked, and a half frame's
//  Film Edge all begin a pair with one frame and present *Pair With*
//  (`PairWithSheet`, H2), where one touch makes the pair and opens its
//  darkroom. Select with two picked needs no sheet. What each does to the
//  router is in `PairWay`, which the tour walks as the pages do.

import SwiftUI

/// The Library's **Pair**: the fourth of the seven actions for the frame on
/// top, between Copy Settings and Develop (`gen_pair_v2.page_library`: r = 22,
/// `ic_pair`). On a photograph it asks for the second frame. On a pair it
/// opens that pair's darkroom: a pair is a piece of film, and fills no hole
/// of another. It is dimmed with its row, when the library shows no frame.
struct PairActionButton: View {
    /// The frame on top.
    let frame: LibraryFrame?
    var diameter: CGFloat = Theme.Metric.roundButton

    @Environment(AppRouter.self) private var router

    var body: some View {
        RoundButton(.pair, diameter: diameter, label: L("Pair")) {
            guard let frame else { return }
            if frame.isPair { router.open(.develop(frame.id)) } else { PairWay.ask(for: frame.id, on: router) }
        }
        .accessibilityHint(frame?.isPair == true ? L("Opens this pair's darkroom")
                                                 : L("Asks for a second frame, to put both on one piece of film"))
    }
}

/// Select's **Pair**: beside All and Cancel, in their own capsule
/// (`gen_pair.page_select`: 56 × 28). Two picked frames fill a new pair's
/// holes in the library's order, and its darkroom opens; one picked frame
/// begins a pair, and *Pair With* asks for the other. The desktop's New
/// Half-Frame Pair (⌘J) takes the first two of however many are picked and
/// makes an empty pair of none; here the chip stands down unless one or two
/// are, since an empty pair has no frame to sit after.
struct PairSelectChip: View {
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model

    /// The picked frames, in the grid's own order.
    private var picks: [LibraryFrame.ID] {
        library.grid().flatMap(\.frames).map(\.id).filter(library.picked.contains)
    }

    var body: some View {
        let picks = picks
        // One or two photographs: a pair is not a frame of another pair.
        let can = (1...2).contains(picks.count) && !picks.contains { library.frame($0)?.isPair == true }
        Chip(title: L("Pair"), height: 28, size: 13.5, padding: 14, dim: !can) {
            library.endSelecting()
            if picks.count > 1 {
                // Two picked: the pair is made of them, and its darkroom opens.
                PairWay.make(picks[0], with: picks[1], keepFilmEdge: false, beginsWithFirst: false, model: model)
            } else if let first = picks.first {
                // One: the sheet asks for the second (design/pair v2, H2).
                PairWay.ask(for: first, on: router)
            }
        }
        .allowsHitTesting(can)
        .accessibilityLabel(L("New half-frame pair"))
        .accessibilityHint(can ? L("The picked frames fill its two holes") : L("Pick one or two frames"))
    }
}

/// What each way into a pair does to the router and the library. One place,
/// so that the pages and a check that drives the router take the same steps.
@MainActor
enum PairWay {
    /// *Pair With* (H2) over the page on top, for a pair that begins with
    /// `first`: the Library's *Pair*, and Select's with one frame picked.
    /// Asked for twice before it is up, it is still one sheet.
    static func ask(for first: LibraryFrame.ID, on router: AppRouter) {
        guard !isAsking(router) else { return }
        router.present(.pairWith(first, keepFilmEdge: false))
    }

    private static func isAsking(_ router: AppRouter) -> Bool {
        router.sheets.contains { if case .pairWith = $0 { true } else { false } }
    }

    /// The frame whose *Pair With* is owed once its Film Edge flow has left
    /// the screen. Left here as the flow's cover is told to go, and taken
    /// once (`SettingsRequest` is the same arrangement the other way round).
    private static var owed: LibraryFrame.ID?

    /// From a half frame's Film Edge, the Format line on Half: **the flow's
    /// cover goes first, and the sheet is asked for when it has gone**
    /// (`filmEdgeLeft`, from the flow's own disappearance). Asked for in the
    /// same turn it is wanted by two hosts at once — the cover's own, which is
    /// leaving and would take the sheet with it, and the page's under it,
    /// which presents nothing while a cover is up (`SheetHost`) — and which
    /// of the two SwiftUI serves is not this app's to say.
    static func leaveFilmEdge(of first: LibraryFrame.ID, on router: AppRouter) {
        owed = first
        router.dismissCover()
    }

    /// A Film Edge flow has come onto the screen: nothing is owed from before it.
    static func filmEdgeEntered() { owed = nil }

    /// The Film Edge flow of `frame` has left the screen. If it left for a
    /// pair the sheet is asked for now, a turn later, so the page under the
    /// cover is the one that presents — and only if nothing else has been
    /// shown over that page in the meantime.
    static func filmEdgeLeft(of frame: LibraryFrame.ID, on router: AppRouter) {
        guard owed == frame else { return }
        owed = nil
        Task { @MainActor in
            guard router.cover == nil, router.sheets.isEmpty else { return }
            router.present(.pairWith(frame, keepFilmEdge: true))
        }
    }

    /// A touch on a frame of *Pair With*, or Select's *Pair* with two picked:
    /// the pair is made of the two and kept (`AppServices.makePair`), any sheet
    /// goes, and the pair's darkroom is the one page over the Library — from a
    /// frame's own develop page too, so that the way back is to the Library.
    /// Returns the pair's id; nil where no pair could be made, and then the
    /// page under the sheet is left as it was.
    ///
    /// **Over a frame's develop page the darkroom is pushed from the Library,
    /// not set in that page's place.** A path whose one page is changed for
    /// another keeps the page that was there: the navigation stack hands the
    /// same `DevelopPane` the new id, and it goes on showing the session it
    /// holds — the first frame's (the tour, 2026-10-10: the path named the
    /// pair, the page was still the frame's). So that page leaves first,
    /// without its animation and with the sheet still over it; a few frames
    /// on — not a turn on, since two changes in one turn reach the stack as
    /// the one it gets wrong — the sheet goes and the darkroom is pushed
    /// together, as they are over the Library.
    /// `beginsWithFirst`: the pair began with `first` and was then asked for its second frame (the sheet):
    /// `first` is its first hole and stays in it (`AppServices.makePair`). Two picked together begin it together.
    @discardableResult
    static func make(_ first: LibraryFrame.ID, with second: LibraryFrame.ID, keepFilmEdge: Bool, beginsWithFirst: Bool = true,
                     model: AppServices) -> LibraryFrame.ID? {
        let router = model.router
        // Two photographs the library still has: a pair of the second frame alone is not what was asked for.
        guard [first, second].allSatisfy({ model.library.frame($0).map { !$0.isPair } ?? false }),
              let id = model.makePair(first, second, keepFilmEdge: keepFilmEdge, beginsWithFirst: beginsWithFirst) else {
            router.dismissAllSheets()
            return nil
        }
        if router.path.isEmpty {
            router.dismissAllSheets()
            router.path = [.develop(id)]
        } else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { router.home() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: pushAfter)
                router.dismissAllSheets()
                // Unless something else has been opened in the meantime.
                if router.path.isEmpty { router.path = [.develop(id)] }
            }
        }
        return id
    }

    /// From the frame's page leaving to the pair's being pushed: four frames at 60 a second.
    private static let pushAfter: UInt64 = 66_000_000
}

/// The Film Edge flow's Format line while it reads Half: the way into a pair
/// (`gen_pair.page_film_edge`), where the stock's gauges are said for any other
/// format. An action, so in the accent. `enter` writes the flow's film edge to
/// the frame first, as *Next* would; then the flow leaves, and *Pair With*
/// asks for the second frame over the page it was on (`PairWay.leaveFilmEdge`).
struct PairFormatLink: View {
    let enter: () -> Void

    var body: some View {
        Button(action: enter) {
            HStack(spacing: 4) {
                DrawnText(L("Half-Frame Pair"), 13, .semibold, Theme.accent)
                Chevron(color: Theme.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityHint(L("This frame becomes the first of two on one piece of film"))
    }
}

/// What the develop page says of a pair (`gen_pair.page_develop`).
enum PairWords {
    /// The Frame tab's note under the size cards, which stand down as they do
    /// under a film edge: the film's size is the pair's.
    static var filmSize: String { L("The film's size is the pair's: two half frames, 18 × 24 mm each.") }

    /// "Level  ·  1.0 mm apart": the Frame tab's Half-Frame Pair row, where
    /// Crop is for a frame. An empty hole is said first: it is what keeps the
    /// pair from exporting.
    static func rowValue(_ pair: HalfFramePair) -> String {
        if !pair.isFilled { return pair.left == nil && pair.right == nil ? L("Empty") : L("1 of 2 frames") }
        return (pair.turned ? L("Turned", as: "a pair") : L("Level", as: "a pair")) + Fmt.dot + String(format: L("%.1f mm apart"), pair.effectiveSpacingMM)
    }

    /// Why a pair cannot be exported, or nil when it can (answer B9).
    static func exportRefusal(_ pair: HalfFramePair, exists: (HalfFramePair.Hole) -> Bool) -> String? {
        if !pair.isFilled { return L("Fill both frames to export the pair.") }
        return pair.isComplete(exists) ? nil : L("A frame of this pair is no longer in the library.")
    }

    /// Under the picture's chips, for the frame a pair's page was entered with:
    /// why Replace and Remove stand down on it (`HalfFramePair.mayChange`).
    static var begunWith: String { L("The pair began with this frame: it stays. Swap changes its hole.") }

    // Select's *Remove from Library*, where a pair is among what goes. A pair names
    // its frames and never owns them, so the words a frame is removed with — "its
    // original goes with it" — are not a pair's: what goes is the pair.

    /// The question, when everything picked is a pair; nil otherwise (a frame's own).
    static func removalTitle(pairs: Int, of all: Int) -> String? {
        guard pairs > 0, pairs == all else { return nil }
        return pairs == 1 ? L("Remove this pair?") : L("Remove \(pairs) pairs?")
    }

    /// What is said of the pairs that go.
    static func removalNote(pairs: Int) -> String {
        pairs == 1 ? L("The pair goes; its two frames stay in the library.") : L("The pairs go; their frames stay in the library.")
    }

    /// What is said when a frame that goes is in a pair that stays.
    static func removalLeavesHole(frames: Int) -> String {
        frames == 1 ? L("A half-frame pair it is in will have an empty hole.") : L("A half-frame pair they are in will have an empty hole.")
    }
}
