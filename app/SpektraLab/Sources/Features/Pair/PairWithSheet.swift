//  PairWithSheet.swift — Pair: the sheet that asks for the second frame.
//
//  the page layout (`gen_pair_v2.page_with`), H2. A pair
//  begins with one frame — the Library's frame on top, the one frame picked in
//  Select, or a half frame from its Film Edge — and this asks for the other:
//  the library's frames as the library draws them, the first dimmed and said
//  so (and still there to be chosen: the same frame twice is allowed, as on
//  the desktop). One touch makes the pair, keeps it in the library after its
//  first frame, and opens its darkroom; nothing stands between.
//
//  **The first frame is not asked about.** The sheet's words name it and ask
//  for the second; nothing here replaces or removes it (the owner, 2026-10-09:
//  a pair that begins with one frame keeps that frame).
//
//  **One touch is one pair.** The sheet takes a moment to leave, and a second
//  touch in that moment — on a frame, or after the close button — makes
//  nothing (`taken`).

import SwiftUI

struct PairWithSheet: View {
    /// The frame the pair begins with.
    let first: LibraryFrame.ID
    /// From a half frame's Film Edge: the pair takes that frame's framing and its film edge.
    let keepFilmEdge: Bool

    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    /// The sheet has been answered, by a frame or by its close button, and is on its way out.
    @State private var taken = false

    var body: some View {
        PairFramePicker(title: L("Pair With"), subtitle: L("The second frame, on the same piece of film"), used: [first],
                        usedText: L("The first frame"), close: {
            taken = true
            router.dismissSheet()
        }) { second in
            guard !taken else { return }
            taken = true
            PairWay.make(first, with: second, keepFilmEdge: keepFilmEdge, model: model)
        }
    }
}
