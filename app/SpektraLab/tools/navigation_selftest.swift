// navigation_selftest.swift — where a pushed page's ‹ goes.
//
//   swiftc -O -parse-as-library Sources/Model/Format.swift Sources/Model/Localization.swift \
//     Sources/App/Navigation.swift tools/navigation_selftest.swift && ./navigation_selftest
//
// The tester's line 4e of 2026-10-15, as the owner took it: back from the develop page goes to the page it
// came from, and says which. A frame opened from the photo being inspected is the path [Photo, Develop]: its
// ‹ is "Photo" and leaves [Photo]. From the Library it is [Develop]: "Library", and []. The edge swipe pops
// one page, which is what ‹ now does.
//
// Each check was seen to fail on the old behaviour (‹ home whatever was under the page) before it held.

import Foundation

@main
struct NavigationSelfTest {
    static var failures = 0
    static var checks = 0

    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1; print("FAILED  \(what)") }
    }

    static func main() {
        let frame = UUID()
        // MARK: 4e, ‹ from the develop page
        let fromLibrary: [Route] = [.develop(frame)]
        let libraryWay = BackWay(to: .develop(frame), in: fromLibrary)
        check(libraryWay.to == nil && libraryWay.title == "Library", "the develop page opened from the Library goes back to it, and says Library")
        check(BackWay.back(fromLibrary) == [], "and ‹ leaves the Library in front")
        let fromViewer: [Route] = [.photo(frame), .develop(frame)]
        check(BackWay(to: .develop(frame), in: fromViewer).to == .photo(frame), "Develop returns to the photo being inspected")
        check(BackWay(to: .develop(frame), in: fromViewer).title == "Photo", "the back action names the inspection page")
        check(BackWay.back(fromViewer) == [.photo(frame)], "back retains the photo route and grid context")
        check(BackWay(to: .photo(frame), in: [.photo(frame)]).to == nil, "photo inspection returns to the grid")
        let fromTable: [Route] = [.lightTable, .develop(frame)]
        check(BackWay(to: .develop(frame), in: fromTable).to == .lightTable, "the develop page opened from the light table goes back to it")
        check(BackWay(to: .develop(frame), in: fromTable).title == "Light Table", "and its ‹ says Light Table")
        check(BackWay.back(fromTable) == [.lightTable], "and ‹ leaves the light table in front, not the Library")
        check(BackWay(to: .lightTable, in: [.lightTable]).to == nil, "the light table's own ‹ goes to the Library")
        // The page is read as it is pushed: a route not yet in the path is on top of it.
        check(BackWay(to: .develop(frame), in: [.lightTable]).to == .lightTable, "a page about to be pushed over the light table goes back to it")
        check(BackWay.back([]) == [], "‹ with nothing pushed leaves the Library")

        print("navigation selftest: \(checks - failures) of \(checks) hold")
        if failures > 0 { exit(1) }
    }
}
