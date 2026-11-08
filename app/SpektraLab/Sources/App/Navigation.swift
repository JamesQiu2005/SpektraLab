//  Navigation.swift — the pushed pages and where a page's ‹ goes.
//  Foundation only: `tools/navigation_selftest.swift`
//  holds these rules on a Mac; `AppRouter` is what the pages call.

import Foundation

/// A page pushed over the Library, which is the stack's root.
enum Route: Hashable, Sendable {
    /// Inspect a library frame before explicitly entering Develop.
    case photo(UUID)
    /// C1-C6: the develop page, on a frame (`LibraryFrame.ID`).
    case develop(UUID)
    /// RFC-045: the light table, from the Library's quiet loupe.
    case lightTable
}

/// Where a pushed page's ‹ goes, and the word it says: the page under it.
struct BackWay: Equatable, Sendable {
    /// The page under it; nil is the Library.
    var to: Route?

    /// The page under `route` in `path`, as the path stands when the page is
    /// opened. A route the path does not hold is taken as pushed on top of it.
    init(to route: Route, in path: [Route]) {
        let at = path.lastIndex(of: route) ?? path.count
        to = at > 0 ? path[at - 1] : nil
    }

    init(to: Route?) { self.to = to }

    static let library = BackWay(to: nil)

    /// What the ‹ says: the page's own name as the app gives it elsewhere.
    var title: String {
        switch to {
        case nil: L("Library")
        case .photo: L("Photo")
        case .develop: L("Develop")
        case .lightTable: L("Light Table")
        }
    }

    /// The path once the page on top has gone back: one page fewer. What the
    /// edge swipe does, which UIKit's own stack does.
    static func back(_ path: [Route]) -> [Route] { Array(path.dropLast()) }
}
