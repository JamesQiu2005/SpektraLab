//  WindowLayoutRule.swift — the window's layout, and the column's split across it: no UIKit, so
//  `tools/window_selftest.swift` holds it on this Mac. The why is in WindowLayout.swift's header.

import CoreGraphics

enum WindowLayout: String, Equatable, Sendable {
    /// The picture and its filmstrip at one side, one column of controls at the other. Every Mac
    /// window is the column, however tall; `MacWindow.minimumSize` keeps it wide enough.
    case column

    /// The column's narrowest width (PAGES.md §1, "Why 393").
    static let columnWidth: CGFloat = 393
    /// The Library's sidebar (PAGES.md §3).
    static let sidebarWidth: CGFloat = 320

    /// The column layout across a page.
    struct Column: Equatable {
        /// The picture side, from the page's leading edge: its bar, the picture, the filmstrip.
        var picture: CGFloat
        /// The 1 pt line where the picture side meets the column; nil with the column put away.
        var rule: CGFloat?
        /// The column's leading edge and width; 0 wide with the column put away.
        var columnX: CGFloat
        var columnWidth: CGFloat
    }

    /// The column layout of a page `width` wide: the picture side, a 1 pt rule, the column `columnWidth`
    /// wide. `hasColumn` false with the column put away (⌘B), when the picture side takes the page.
    static func column(width: CGFloat, hasColumn: Bool = true, columnWidth: CGFloat = WindowLayout.columnWidth) -> Column {
        guard hasColumn else { return Column(picture: width, rule: nil, columnX: width, columnWidth: 0) }
        let picture = max(width - columnWidth - 1, 0)
        return Column(picture: picture, rule: picture, columnX: picture + 1, columnWidth: columnWidth)
    }
}
