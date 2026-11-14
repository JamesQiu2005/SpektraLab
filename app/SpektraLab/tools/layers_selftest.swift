// layers_selftest.swift — the 图层 (Layers) panel as rules (design/layers/LAYERS-SPEC.md §4, §5, §11).
//
// Compiled with the model, `Features/Double/DoubleRules.swift` and `Features/Layers/LayerRules.swift`
// (tools/selftest.sh): which rows a piece has, in which order and under which names; the pick held across a
// mode switch and across pieces; where ↑ and ↓ land; the eye's three states, and an emptied layer clearing it;
// Balance in the panel exactly when a double is filled; the card's heights; what a picked row's page holds in
// 冲洗 and 编辑, a double's held against `DoublePanelKind.of` tab by tab so the two rules cannot drift; which
// picture 裁剪 arranges; and the refusal's words exactly when a piece will not export.
//
//   --self-test  each rule broken on purpose, to see it caught.

import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

@main struct LayersSelftest {
    /// The rules broken one at a time by `--self-test`: each must be caught.
    static let rules = ["the film is not the first row", "a double lists its bottom before its top",
                        "a turned pair keeps the level names", "the pick is moved to the film when Edit opens",
                        "the arrows run past the ends", "the lit eye does not put both back",
                        "an emptied layer keeps its exposure alone", "a pair has Balance",
                        "a single frame's panel unfolds", "an exposure's page shows the whole's print",
                        "the whole's white balance leads nowhere", "an empty layer exports",
                        "Crop on the whole of a double depends on the pick",
                        "Combine lays its pictures in the grid's order", "the two shares need not add to 100"]

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for rule in rules { if checks(rule, quiet: true) > 0 { caught += 1 } else { print("  NOT CAUGHT: \(rule)") } }
            print("layers self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        exit(checks(nil, quiet: false) == 0 ? 0 : 1)
    }

    /// Every check, with `broken` (one of `rules`) broken; the number that failed.
    static func checks(_ broken: String?, quiet: Bool) -> Int {
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failed += 1; if !quiet { print("FAIL: \(name)") } }
        }
        func on(_ i: Int) -> Bool { broken == rules[i] }

        let a = UUID(), b = UUID(), c = UUID()
        let all: (UUID) -> Bool = { _ in true }
        var pair = HalfFramePair()
        pair.left = HalfFramePair.Hole(path: "a.dng", frame: a)
        pair.right = HalfFramePair.Hole(path: "b.dng", frame: b)
        let double = DoubleExposure(bottom: DoubleExposure.Exposure(frame: a), top: DoubleExposure.Exposure(frame: b), origin: a)

        // The rules under test, each with its one way of being wrong.
        func rows(_ piece: LayerPiece, alone: DoubleExposure.Position? = nil, has: (UUID) -> Bool = all) -> [LayerRow] {
            var r = LayerRules.rows(piece, alone: alone, has: has)
            if on(0), r.count > 1 { r.swapAt(0, 1) }
            if on(1), case .double = piece { r.swapAt(1, 2) }
            if on(2), case .pair(let p) = piece, p.turned {
                var level = p; level.turned = false
                r = LayerRules.rows(.pair(level), has: has)
            }
            return r
        }
        func page(_ pick: LayerPick, _ piece: LayerPiece, _ mode: LayerMode, has: (UUID) -> Bool = all) -> LayerPage {
            if on(9), mode == .develop, case .picture(let s) = LayerRules.page(pick, piece: piece, mode: mode, has: has), case .double = piece {
                return .picture(s + [.enlarger])
            }
            return LayerRules.page(pick, piece: piece, mode: mode, has: has)
        }

        // The rows: 胶片 first, the pictures under it, under the catalog's names.
        expect(rows(.single).map(\.pick) == [.film], "a single frame: 胶片 alone")
        expect(rows(.pair(pair)).map(\.pick) == [.film, .frame(.left), .frame(.right)], "a pair: 胶片 · 左格 · 右格")
        expect(rows(.pair(pair)).map(\.name) == ["Film", "Left frame", "Right frame"], "a level pair's names")
        var turned = pair; turned.turned = true
        expect(rows(.pair(turned)).map(\.name) == ["Film", "Top frame", "Bottom frame"], "a turned pair: 胶片 · 上格 · 下格")
        expect(rows(.double(double)).map(\.pick) == [.film, .exposure(.top), .exposure(.bottom)], "a double: 胶片 · 上层 · 下层, top first")
        expect(rows(.double(double)).map(\.name) == ["Film", "Top", "Bottom"], "a double's names")
        for piece in [LayerPiece.single, .pair(pair), .pair(turned), .double(double)] {
            expect(rows(piece).first?.pick == .film && rows(piece).first?.content == .film, "胶片 is always the first row")
        }
        expect(rows(.pair(pair)).allSatisfy { $0.eye == .none && $0.share == nil }, "a pair's rows: no eye, no share")

        // A double's shares are Balance's, and move with it.
        var uneven = double; uneven.setBalance(0.6)
        let shares = rows(.double(uneven)).compactMap(\.shareText)
        expect(shares == ["60 %", "40 %"], "the rows' shares are Balance's: 60 % and 40 %")
        expect(rows(.double(double)).compactMap(\.share) == [0.5, 0.5], "a new double: each 50 %")
        var odd = double; odd.setBalance(0.625)
        let oddShares = on(14) ? rows(.double(odd)).compactMap(\.share).map { "\(Int(($0 * 100).rounded())) %" } : rows(.double(odd)).compactMap(\.shareText)
        expect(oddShares == ["63 %", "37 %"] || oddShares == ["62 %", "38 %"], "the two shares add to 100 at 62.5 %")

        // Empty and missing.
        var holed = pair; holed.right = nil
        expect(rows(.pair(holed))[2].content == .empty && rows(.pair(holed))[1].photograph == a, "an empty hole is an empty row")
        var one = double; one[.top] = nil
        expect(rows(.double(one))[1].isEmpty && rows(.double(one)).allSatisfy { $0.share == nil && $0.eye == .none },
               "a double with a layer empty: an empty row, no shares, no eyes")
        expect(rows(.double(double), has: { $0 != b })[1].content == .missing(b), "a photograph gone from the library: a row that says so")

        // The pick: held across the modes, and given back to 胶片 only where the piece has no such row.
        func entering(_ pick: LayerPick, _ mode: LayerMode) -> LayerPick { on(3) && mode == .edit ? .film : pick }
        expect(entering(LayerRules.held(.exposure(.top), in: .double(double)), .edit) == .exposure(.top), "the pick survives the switch to Edit")
        expect(entering(LayerRules.held(.frame(.right), in: .pair(pair)), .edit) == .frame(.right), "a pair's pick survives it too")
        expect(LayerRules.held(.frame(.left), in: .double(double)) == .film && LayerRules.held(.exposure(.top), in: .single) == .film,
               "a row the piece does not have is 胶片")

        // ↑ and ↓.
        func step(_ pick: LayerPick, _ d: Int, _ r: [LayerRow]) -> LayerPick {
            if on(4) { let p = r.map(\.pick); return p[((p.firstIndex(of: pick) ?? 0) + d + p.count) % p.count] }
            return LayerRules.step(pick, by: d, in: r)
        }
        let dr = rows(.double(double))
        expect(step(.film, 1, dr) == .exposure(.top) && step(.exposure(.top), 1, dr) == .exposure(.bottom), "↓ walks down the rows")
        expect(step(.exposure(.bottom), 1, dr) == .exposure(.bottom) && step(.film, -1, dr) == .film, "the arrows stop at the ends")
        expect(LayerRules.step(.exposure(.top), by: -1, in: dr, among: LayerRules.arrangeable) == .exposure(.top),
               "in 摆放 the arrows move between the two exposures only")
        expect(LayerRules.summary(.exposure(.top), in: dr) == "Top" && LayerRules.summary(.film, in: dr) == "Film", "the folded head names the picked row")

        // The eye: both, top alone, bottom alone.
        func tapped(_ p: DoubleExposure.Position, _ alone: DoubleExposure.Position?) -> DoubleExposure.Position? {
            on(5) && alone == p ? p : LayerRules.eyeTapped(p, alone: alone)
        }
        expect(tapped(.top, nil) == .top, "a click on an eye: that exposure alone")
        expect(tapped(.top, .top) == nil, "a click on the lit eye: both again")
        expect(tapped(.bottom, .top) == .bottom, "a click on the other's struck eye: straight to that one")
        expect(rows(.double(double), alone: .top).map(\.eye) == [.none, .alone, .out], "alone: the lit eye, the other struck, 胶片 without one")
        expect(rows(.double(double)).map(\.eye) == [.none, .shown, .shown], "both: two open eyes")
        func kept(_ alone: DoubleExposure.Position?, _ d: DoubleExposure) -> DoubleExposure.Position? {
            on(6) ? alone : LayerRules.alone(alone, in: d, has: all)
        }
        expect(kept(.bottom, one) == nil && kept(.top, double) == .top, "an emptied layer clears the eye")

        // What the panel holds.
        func balance(_ piece: LayerPiece) -> Bool { if on(7), case .pair = piece { return true }; return LayerRules.showsBalance(piece) }
        expect(balance(.double(double)) && !balance(.double(one)) && !balance(.pair(pair)) && !balance(.single),
               "Balance: a filled double, and nothing else")
        // Since M1c the mask layers are in every build (`FeatureFlags.maskLayers`): a single photograph's panel unfolds
        // (MASKS-SPEC §3), 140 with no mask layer; before, it was one line, 32.
        func oneLine(_ piece: LayerPiece) -> Bool { on(8) ? true : LayerRules.isOneLine(piece) }
        expect(!oneLine(.single) && !oneLine(.pair(pair)) && !oneLine(.double(double)), "no panel is one line: a single frame's unfolds")
        expect(LayerRules.height(.single, folded: false) == 140 && LayerRules.height(.double(double), folded: true) == 32, "32 folded; a single frame's 140 with no mask layer")
        expect(LayerRules.height(.pair(pair), folded: false) == 128, "a pair: 128")
        expect(LayerRules.height(.double(double), folded: false) == 172.5, "a double: 172.5")
        expect(LayerRules.height(.double(one), folded: false) == 128, "a double with a layer empty: no Balance")

        // What a picked row scopes.
        for piece in [LayerPiece.single, .pair(pair), .double(double)] {
            expect(page(.film, piece, .develop) == .film && page(.film, piece, .edit) == .film, "胶片 is the column as it is, in both modes")
        }
        expect(page(.frame(.left), .pair(pair), .develop) == .picture([.arrange, .exposure, .whiteBalance, .enlarger, .dateBack, .photograph]),
               "a pair's frame: its picture, exposure, white balance, print, date and itself")
        expect(page(.frame(.right), .pair(holed), .develop) == .empty, "an empty hole: the way a frame gets in")
        expect(page(.frame(.right), .pair(pair), .develop, has: { $0 != b }) == .picture([.photograph]), "a frame gone from the library: replace or remove")
        expect(page(.exposure(.top), .double(double), .develop) == .picture([.arrange, .advanced, .whiteBalance, .photograph]),
               "a double's exposure: its picture, its own stops under Advanced, its white balance and itself")
        expect(page(.exposure(.top), .double(one), .develop) == .empty, "an empty layer: Add Exposure")
        expect(page(.exposure(.top), .double(double), .edit) == .standsDown && page(.frame(.left), .pair(pair), .edit) == .standsDown,
               "Edit with a picture picked: nothing of its own, and the pick is kept")
        // The Mac's sections against the tab rule, tab by tab.
        for position in DoubleExposure.Position.allCases {
            for d in [double, one, uneven] {
                let layer = DoubleExposure.Layer(position)
                let kinds = Dictionary(uniqueKeysWithValues: DevelopTab.allCases.map { ($0, DoublePanelKind.of($0, layer, d, has: all)) })
                guard case .picture(let sections) = page(.exposure(position), .double(d), .develop) else {
                    expect(kinds[.frame] == .empty, "no page of its own only where the rule's Frame tab is empty")
                    continue
                }
                expect(sections.contains(.arrange) == (kinds[.frame] == .picture), "摆放 exactly where the rule's Frame tab is the picture's")
                expect(sections.contains(.advanced) == (kinds[.film] == .filmExposure), "its own stops exactly where the rule's Film tab is the exposure's")
                expect(sections.contains(.whiteBalance) == (kinds[.scene] == .sceneExposure), "its white balance exactly where the rule's Scene tab is")
                expect(!sections.contains(.enlarger) && kinds[.print] == .printExposure, "the print is the whole's: never on an exposure's page")
                expect(!sections.contains(.dateBack) && !sections.contains(.exposure), "no pair's section on a double's exposure")
            }
        }

        // R3: the whole's white balance leads to each picture.
        func wbRows(_ r: [LayerRow]) -> [LayerPick] { on(10) ? [] : LayerRules.whiteBalanceRows(r).map(\.pick) }
        expect(wbRows(rows(.double(double))) == [.exposure(.top), .exposure(.bottom)], "the whole's white balance: one way into each exposure's")
        expect(wbRows(rows(.pair(holed))) == [.frame(.left)], "and only to a picture that is there")

        // The refusal.
        func refusal(_ piece: LayerPiece, has: (UUID) -> Bool = all) -> String? {
            if on(11), case .double(let d) = piece, !d.isFilled { return nil }
            return LayerRules.refusal(piece, has: has)
        }
        expect(refusal(.single) == nil && refusal(.pair(pair)) == nil && refusal(.double(double)) == nil, "a whole piece exports")
        expect(refusal(.double(one)) == "Fill both exposures to export the double exposure.", "an empty layer: the double's refusal")
        expect(refusal(.pair(holed)) == "Fill both frames to export the pair.", "an empty hole: the pair's refusal")
        expect(refusal(.double(double), has: { $0 != c && $0 != a }) != nil, "a photograph gone: it will not export either")

        // 裁剪 in 冲洗.
        func arranges(_ pick: LayerPick, _ piece: LayerPiece, last: DoubleExposure.Position? = nil) -> LayerPick? {
            if on(12), pick == .film, case .double = piece { return nil }
            return LayerRules.arranges(pick, piece: piece, last: last, has: all)
        }
        expect(arranges(.film, .single) == nil && arranges(.film, .pair(pair)) == nil, "a photograph's crop is its own; a pair's whole has none")
        expect(arranges(.frame(.right), .pair(pair)) == .frame(.right) && arranges(.frame(.right), .pair(holed)) == nil, "a pair's frame is arranged; an empty hole is not")
        expect(arranges(.exposure(.bottom), .double(double)) == .exposure(.bottom), "a double's exposure is arranged")
        expect(arranges(.film, .double(double)) == .exposure(.top) && arranges(.film, .double(double), last: .bottom) == .exposure(.bottom),
               "胶片 picked on a double: the exposure picked last, the top at first")
        expect(arranges(.film, .double(one)) == .exposure(.bottom), "and the one there is, with a layer empty")

        // 合成 keeps the order the pictures were picked in (R6).
        func picked(_ clicks: [Set<Int>], grid: [Int]) -> [Int] {
            var order = PickOrder<Int>()
            for selection in clicks { order.follow(selection) }
            return on(13) ? grid.filter { clicks.last?.contains($0) ?? false } : order.ordered(grid)
        }
        expect(picked([[7], [7, 2]], grid: [1, 2, 3, 7]) == [7, 2], "the later row picked first is first")
        expect(picked([[2], [2, 7]], grid: [1, 2, 3, 7]) == [2, 7], "and the earlier picked first is first")
        expect(picked([[7], [7, 2], [2], [2, 7]], grid: [1, 2, 3, 7]) == [2, 7], "a picture let go and picked again goes to the end")
        expect(picked([[3], [1, 2, 3]], grid: [1, 2, 3, 7]) == [3, 1, 2], "rows that join together keep the grid's order among themselves")
        expect(picked([[3], []], grid: [1, 2, 3]).isEmpty, "nothing chosen, nothing ordered")

        if !quiet { print("Layers panel: \(passed) passed, \(failed) failed") }
        return failed
    }
}
