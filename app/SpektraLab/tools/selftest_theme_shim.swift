//  selftest_theme_shim.swift — what the film layout's macOS checks need of `Sources/DesignSystem/Theme.swift`.
//
//  `Model/Stock.swift` (every check that loads the stock catalogue) reads a stock's swatch as a SwiftUI
//  `Color` through `Color(hexString:)`, which is Theme.swift's. Theme.swift imports UIKit since unpublished-revision
//  (2026-10-24: its tones resolve by the traits they are drawn with), and a plain macOS `swiftc` has no
//  UIKit: from that commit on, `film_edge_steps_selftest` and both light-table checks failed to compile
//  ("no such module 'UIKit'"), and `tools/selftest.sh` stopped after its first four checks, before any
//  check below them ran (found 2026-11-05).
//
//  This file stands in for Theme.swift in those compiles and nowhere else. It is the swatch's parse and
//  nothing more: no check reads a colour, so it keeps no copy of a convention a check could go red on
//  (trap 28) — a swatch it cannot parse is grey, where the app's is `Theme.card`.

import SwiftUI

extension Color {
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .gray; return }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}
