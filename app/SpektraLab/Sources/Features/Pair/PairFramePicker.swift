//  PairFramePicker.swift — the library's frames in a sheet, for a hole of a pair.
//
//  the page layout (`gen_pair_v2.page_with`: *Pair With*,
//  the pair's second frame) and the page layout
//  (`gen_pair.page_picker`: *Add Frame*, over the pair). The desktop's Add
//  Frame picker (`PairFramePicker` in its `PairSection.swift`): the frames
//  drawn as the library draws them, one this pair already holds dimmed and
//  said so — and still there to be chosen, because the same frame twice is
//  allowed. The desktop filters by name; a host's library is browsed by
//  picture and its files have no names anyone chose, so there is no filter.
//
//  **Every photograph, in the Library's order** (`FrameCatalog.photographs`):
//  the page's own sort, and none of its filters — under *Developing* the
//  Library may be showing one frame, and the sheet still offers them all.
//
//  It hands its choice back to whoever shows it and knows nothing of what
//  the choice is for: the router's *Pair With* (`PairWithSheet`) makes a pair
//  of it, a page that presents it itself (`spkSheet`) fills a hole.

import SwiftUI

struct PairFramePicker: View {
    /// "Pair With"; "Add Frame", or "Replace Frame" over a hole that holds one.
    let title: String
    /// What is asked for, or the hole it fills: "Right frame".
    let subtitle: String
    /// The frames this pair already holds.
    let used: Set<LibraryFrame.ID>
    /// What a frame the pair already holds says over its tile.
    var usedText = L("In this pair")
    let close: () -> Void
    let choose: (LibraryFrame.ID) -> Void

    @Environment(FrameCatalog.self) private var library
    /// The Library's own sort (its `···` menu).
    @AppStorage(FrameCatalog.oldestFirstKey) private var oldestFirst = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle, onClose: close)
            ScrollView {
                // The library's own grid without the days: three columns, 2 pt apart, lazy.
                LazyVGrid(columns: LibraryScreen.columns, spacing: Theme.Metric.gridGap) {
                    ForEach(library.photographs(oldestFirst: oldestFirst)) { frame in
                        let isUsed = used.contains(frame.id)
                        LibraryTile(frame: frame)
                            .overlay {
                                if isUsed {
                                    // `tile(dim=True)`: 0.6 black over the tile, its words on the tile's middle.
                                    ZStack {
                                        Color.black.opacity(0.6)
                                        DrawnText(usedText, 12, .semibold, Theme.secondaryText)
                                    }
                                    .allowsHitTesting(false)
                                }
                            }
                            .onTapGesture { choose(frame.id) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(frame.fileName + (isUsed ? ", " + usedText.lowercased() : ""))
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .padding(.top, PairLayout.pickerGrid - SheetHeader.height(subtitle: true))
        }
    }
}
