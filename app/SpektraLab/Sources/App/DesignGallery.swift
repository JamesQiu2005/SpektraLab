//  DesignGallery.swift — the drawn glyphs, laid out where the drawings' own board puts them.
//
//  Not a page of the app: a board for the snapshot harness. `DS3` is every
//  drawn glyph on one page, held against the same board drawn by the drawings'
//  own code. (`DS1` and `DS2` held the shared controls against the drawings
//  before any page was made of them; the pages do that now.)

import SwiftUI

/// Every drawn glyph on one page, where `tools/gen_icons.py --sheet` puts the
/// drawings' own: six to a row, each on a card disc.
struct DesignGalleryGlyphs: View {
    static let columns = 6
    static let top: CGFloat = 100, pitch: CGFloat = 62, disc: CGFloat = 17

    var body: some View {
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(Self.columns)
            ForEach(Array(DrawnIcon.allCases.enumerated()), id: \.offset) { i, icon in
                ZStack {
                    Circle().fill(Theme.card).frame(width: Self.disc * 2, height: Self.disc * 2)
                    DrawnGlyph(icon: icon)
                }
                .position(x: cell * (CGFloat(i % Self.columns) + 0.5),
                          y: Self.top + Self.pitch * CGFloat(i / Self.columns))
            }
        }
        .ignoresSafeArea()
        .background(Theme.background.ignoresSafeArea())
    }
}

enum DesignGallerySnapshots {
    @MainActor static var pages: [SnapshotPage] {
        [
            // Held against the drawings' own glyphs on one page (`tools/gen_icons.py --sheet`).
            SnapshotPage("DS3", "Glyphs") { _ in DesignGalleryGlyphs() },
        ]
    }
}
