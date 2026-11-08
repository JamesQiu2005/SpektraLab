//  DevelopRegions.swift — where the develop page's parts go: the column (PAGES.md §2).
//
//  The picture side — its top bar, the picture, a pair's layer picker under the piece, the filmstrip at
//  the foot — and the column, the two joined by one 1 pt line. With the column put away (⌘B) the picture
//  side is the window. One layout, so the picture is **the same view** however the window is resized:
//  its zoom, its compare line, its decode and the original held are kept, and the page's session is never
//  touched.

import SwiftUI

/// Which part of the page a child is.
enum DevelopRegion: Int {
    case top, canvas, layers, filmstrip, rule, controls
    /// the crop made in the page (`InlineCrop`), over the whole page; it draws its own two
    /// parts where `CropPlacement` says.
    case crop
    /// the grip on the line between the column and the picture side (`DividerGrip`).
    case columnGrip
    /// the grip on the line over the filmstrip.
    case stripGrip
}

private struct DevelopRegionKey: LayoutValueKey {
    static let defaultValue = DevelopRegion.canvas
}

extension View {
    func padPart(_ part: DevelopRegion) -> some View { layoutValue(key: DevelopRegionKey.self, value: part) }
}

struct DevelopRegions: Layout {
    var top: CGFloat
    var layers: CGFloat = 0
    var filmstrip: CGFloat = BrowserFilmstrip.height
    /// How far the filmstrip sits into the window's bottom safe area, so it is lower on the screen
    /// (the owner, 2026-10-22); the picture ends where the strip starts.
    var filmstripReach: CGFloat = 0
    /// The column's width, as dragged (`PaneDividers`).
    var columnWidth: CGFloat = WindowLayout.columnWidth

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var parts: [DevelopRegion: LayoutSubview] = [:]
        for s in subviews where parts[s[DevelopRegionKey.self]] == nil { parts[s[DevelopRegionKey.self]] = s }
        func place(_ part: DevelopRegion, _ r: CGRect) {
            parts[part]?.place(at: r.origin, anchor: .topLeading,
                               proposal: ProposedViewSize(width: max(r.width, 0), height: max(r.height, 0)))
        }
        place(.crop, b)
        let wall = WindowLayout.column(width: b.width, hasColumn: parts[.controls] != nil, columnWidth: columnWidth)
        let left = wall.picture
        // the column
        // stands at the left, as Capture One's tools and the Mac library's sidebar do, and the picture
        // side at its right. Nothing in either moves; with the column put away (⌘B) the picture is
        // the window, as before.
        let mirrored = wall.columnWidth > 0 && wall.rule != nil
        let px = mirrored ? b.minX + wall.columnWidth + 1 : b.minX
        place(.top, CGRect(x: px, y: b.minY, width: left, height: top))
        var foot = b.maxY
        if parts[.filmstrip] != nil {
            foot -= filmstrip - filmstripReach
            place(.filmstrip, CGRect(x: px, y: foot, width: left, height: filmstrip))
        }
        let reach = DividerGrip.reach
        place(.stripGrip, parts[.filmstrip] != nil ? CGRect(x: px, y: foot + 0.5 - reach / 2, width: left, height: reach) : .zero)
        if parts[.layers] != nil {
            foot -= layers
            place(.layers, CGRect(x: px, y: foot, width: left, height: layers))
        }
        place(.canvas, CGRect(x: px, y: b.minY + top, width: left, height: foot - b.minY - top))
        if mirrored {
            place(.rule, CGRect(x: b.minX + wall.columnWidth, y: b.minY, width: 1, height: b.height))
            place(.controls, CGRect(x: b.minX, y: b.minY, width: wall.columnWidth, height: b.height))
        } else {
            place(.rule, wall.rule.map { CGRect(x: b.minX + $0, y: b.minY, width: 1, height: b.height) } ?? .zero)
            place(.controls, CGRect(x: b.minX + wall.columnX, y: b.minY, width: wall.columnWidth, height: b.height))
        }
        // The grip across the line, half on each side of it.
        let line: CGFloat? = mirrored ? wall.columnWidth : wall.rule
        place(.columnGrip, line.map { CGRect(x: b.minX + $0 + 0.5 - reach / 2, y: b.minY, width: reach, height: b.height) } ?? .zero)
    }
}
