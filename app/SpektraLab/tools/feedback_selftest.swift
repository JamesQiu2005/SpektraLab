import Foundation

@main struct Check {
    static func main() {
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        var vertical = DragOwnership()
        check(!vertical.update(x: 2, y: 10), "vertical panel scroll does not edit")
        check(!vertical.update(x: 40, y: 12), "vertical ownership remains latched")
        var horizontal = DragOwnership()
        check(!horizontal.update(x: 1, y: 1), "contact alone does not edit")
        check(horizontal.update(x: 10, y: 2), "horizontal intent claims ruler")
        check(horizontal.update(x: 11, y: 30), "horizontal ownership remains latched")
        print("Input feedback: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
