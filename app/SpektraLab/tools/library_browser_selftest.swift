import Foundation

@main enum LibraryBrowserSelftest {
    static func main() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var count = 0
        func hold(_ ok: Bool, _ what: String) {
            guard ok else { print("FAIL: \(what)"); exit(1) }
            count += 1
        }
        var browser = LibraryBrowser(selectedID: b)
        browser.start([a, b, c])
        hold(browser.selectedID == b, "one tap opens the chosen frame")
        browser.start([d, c])
        hold(browser.ids == [a, b, c] && browser.selectedID == b, "returning from Develop preserves browsing context")
        browser.select(c)
        hold(browser.selectedID == c, "swiping selects a neighbour")
        browser.select(d)
        hold(browser.selectedID == c, "a different collection cannot replace the selected frame")
        browser.reconcile([a, b, d])
        hold(browser.ids == [a, b] && browser.selectedID == b, "deleting the last frame selects the preceding neighbour")
        browser.reconcile([a, d])
        hold(browser.selectedID == a, "deleting again stays in the original collection")
        browser.reconcile([d])
        hold(browser.ids.isEmpty && browser.selectedID == nil, "an exhausted visit closes instead of opening an unrelated frame")
        var first = LibraryBrowser(selectedID: a)
        first.start([a, b, c]); first.reconcile([b, c])
        hold(first.selectedID == b, "deleting the first frame selects the next neighbour")
        var stale = LibraryBrowser(selectedID: d)
        stale.start([a, b]); hold(stale.selectedID == a, "a stale selection resolves inside the active collection")
        var batch = LibraryBrowser(selectedID: b)
        batch.start([a, b, c, d]); batch.reconcile([c, d])
        hold(batch.selectedID == c, "batch deletion chooses the next surviving neighbour in the original order")
        print("library browser: \(count) passed, 0 skipped")
    }
}
