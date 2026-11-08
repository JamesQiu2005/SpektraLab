//  MacBrowserSplit.swift — the browser's line, and the pane it sizes (the owner, 2026-10-26).
//
//  Capture One's browser: one column at the window's right, as wide as the person drags it, the picture
//  (the library's viewer, the develop page's canvas) taking what is left. The library has drawn it since
//  2026-10-24 (`MacLibraryGrid.browserWall`); it is one view now so the develop page can stand its
//  canvas beside the same browser, and a drag in one mode means the same in the others.
//
//  The width is `MacLibraryBrowser.browserWidth` — the page's own state, kept with the window — and it is
//  written to the app's defaults when a drag ends, as `PaneDividers` writes the column's (Mac points).

import SwiftUI

/// `pane` at the browser's width, the line it is dragged by at its leading edge.
struct MacBrowserSplit<Pane: View>: View {
    let browser: MacLibraryBrowser
    /// The browser itself: a grid, or a header and a grid (the develop page's slim one).
    @ViewBuilder let pane: Pane

    @State private var drag: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            wall
            pane.frame(width: MacMetric.pt(browser.browserWidth))
        }
    }

    /// The line between the picture and the browser; dragged, the browser's width (a drag to the left
    /// makes it wider), 240 to 900 Mac points.
    private var wall: some View {
        Rectangle().fill(Theme.wall).frame(width: 1)
            .overlay {
                Color.clear.frame(width: MacMetric.pt(7)).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            let start = drag ?? browser.browserWidth
                            drag = start
                            let w = start - v.translation.width * MacMetric.scale
                            browser.browserWidth = min(max(w, MacMetric.browserRange.lowerBound), MacMetric.browserRange.upperBound)
                        }
                        .onEnded { _ in
                            drag = nil
                            browser.saveWidths()
                        })
                    .hoverEffect(.highlight)
            }
    }
}
