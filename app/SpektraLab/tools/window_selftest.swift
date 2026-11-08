// window_selftest.swift — the window's layout and the column's split across it.
//
//   swiftc -O -parse-as-library Sources/App/WindowLayoutRule.swift tools/window_selftest.swift && ./window_selftest
//
// Every Mac window is the column (WindowLayoutRule.swift): the picture side, a 1 pt rule and the column,
// 393 pt at its narrowest; with the column put away the picture side takes the page.

import CoreGraphics

@main
struct WindowSelfTest {
    static var failures = 0
    static var checks = 0

    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1; print("FAILED  \(what)") }
    }

    static func main() {
        // The column is the page as built: the picture side, a 1 pt rule, 393 pt.
        for w in [951, 1133, 1376] as [CGFloat] {
            let c = WindowLayout.column(width: w)
            check(c == WindowLayout.Column(picture: w - 394, rule: w - 394, columnX: w - 393, columnWidth: 393),
                  "column \(Int(w)): as built")
        }
        // A column dragged wider: the picture side gives it the room, the rule between them.
        let wide = WindowLayout.column(width: 1440, columnWidth: 480)
        check(wide == WindowLayout.Column(picture: 959, rule: 959, columnX: 960, columnWidth: 480), "column dragged to 480: the picture side gives the room")
        let away = WindowLayout.column(width: 951, hasColumn: false)
        check(away.picture == 951 && away.rule == nil && away.columnWidth == 0, "column put away: the picture takes the page")

        print("window_selftest: \(checks) checks, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}

#if canImport(Darwin)
import Darwin
#endif
