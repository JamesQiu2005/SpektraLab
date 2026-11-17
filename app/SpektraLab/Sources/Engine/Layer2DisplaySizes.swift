//  Layer2DisplaySizes.swift — the sizes Edit's live picture is drawn at, one for each picture that draws it
//  (issue #123, 2026-11-14).
//
//  `Layer2Live` makes its picture at the size the canvas draws it (`display(maxPixel:)`). Two pictures can draw it at
//  once: the develop canvas, and the crop screen's finished picture (`CropScreen`, `.finished`), which lies over a canvas
//  that is only hidden (opacity 0), never removed. A view swapped for another (Compare, Original, a crop's identity)
//  is a new picture too. Each used to write one shared value, so the last to say wins:
//  - the crop screen closing said "nil", and the canvas still on screen never said its size again, so passes ran for
//    the histogram only and the canvas kept its last picture;
//  - a new view's `onAppear` run before the old one's `onDisappear` (SwiftUI does not promise the order) left nil too.
//
//  Now each picture holds its own size, and the pass is made at the largest one held. It stops only when none is held.
//  Pure, so `tools/hdr_latch_selftest.swift` holds it.

struct Layer2DisplaySizes: Equatable {
    private var sizes: [String: Int] = [:]
    /// A size pinned by an in-app check (`Layer2Live.display(maxPixel:)`), which then waits for a pass at exactly that
    /// width: it wins over the pictures' while it is set, as the one shared value let a check's word win before.
    private var pinned: Int?

    /// The long edge the pass makes its picture at: a pinned size, else the largest any holder draws; nil when none.
    var maxPixel: Int? { pinned ?? sizes.values.max() }

    /// A check's own size (nil lets it go).
    mutating func pin(_ maxPixel: Int?) { pinned = maxPixel }

    /// `holder` draws the picture at `maxPixel`, or no longer draws it (nil).
    mutating func set(_ holder: String, maxPixel: Int?) {
        #if DEBUG
        // `--edit-refresh-check-break sizes`: 2.4.0's one shared value, the last to say wins.
        if Self.sharedOnly { sizes = maxPixel.map { ["shared": $0] } ?? [:]; return }
        #endif
        sizes[holder] = maxPixel
    }

    #if DEBUG
    nonisolated(unsafe) static var sharedOnly = false
    #endif

    /// Nothing draws it (the page has closed).
    mutating func removeAll() { sizes = [:]; pinned = nil }
}
