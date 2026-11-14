// double_darkroom_selftest.swift — the double exposure's darkroom as rules (RFC-050 §4, PRD 2 §4; phase 2, lane D).
//
// Compiled with the model and `Features/Double/DoubleRules.swift` (tools/selftest.sh): what each tab shows for
// the layer picked, Balance's track (10–90 %, whole percent, the 50 % detent, VoiceOver's 5 % steps), the
// Latitude card's name (K1 "Both exposures", K7 "Bottom"), the export refusal, and what a visit moved — a swap
// is a swap and not a photograph replaced, a reading arriving is no move. Balance through the model's own
// `setBalance` at 70 % lands on RFC-047 §4's EVs.
//
//   --self-test  each rule broken on purpose, to see it caught.

import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

@main struct DoubleDarkroomSelftest {
    /// The rules broken one at a time by `--self-test`: each must be caught.
    static let rules = ["the top's Frame tab shows the whole's", "the track starts at 0 %", "the card names the picked layer",
                        "a swap read as a photograph replaced", "an empty layer's Decode falls back to the bottom",
                        "the whole's ↺ leaves Balance", "the whole's white balance is the bottom's (R3)",
                        "a double with an empty layer exports (R10)"]

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for rule in rules { if checks(rule, quiet: true) > 0 { caught += 1 } else { print("  NOT CAUGHT: \(rule)") } }
            print("double darkroom self-test: \(caught) of \(rules.count) broken rules caught")
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

        let a = UUID(), b = UUID()
        var made = DoubleExposure(bottom: DoubleExposure.Exposure(frame: a), top: DoubleExposure.Exposure(frame: b), origin: a)
        let all: (UUID) -> Bool = { _ in true }

        // What each tab shows (PRD 2 §4's table).
        func kind(_ tab: DevelopTab, _ layer: DoubleExposure.Layer, _ d: DoubleExposure = made, has: (UUID) -> Bool = all) -> DoublePanelKind {
            broken == rules[0] && tab == .frame && layer == .top ? .frameWhole : DoublePanelKind.of(tab, layer, d, has: has)
        }
        expect(kind(.film, .film) == .filmWhole, "Film, the whole: the film, Film Exposure, Balance (K1)")
        expect(kind(.film, .top) == .filmExposure, "Film, an exposure: its own exposure and meter (K2)")
        expect(kind(.frame, .film) == .frameWhole, "Frame, the whole: sizes, Film Edge, Date Back, Swap (K3)")
        expect(kind(.frame, .bottom) == .picture, "Frame, the bottom: Place, Replace, Remove (K4)")
        expect(kind(.frame, .top) == .picture, "Frame, the top: its picture")
        expect(kind(.print, .top) == .printExposure, "Print, an exposure: the whole's print with its line (K5)")
        expect(kind(.print, .film) == .printWhole, "Print, the whole: as a photograph")
        expect(kind(.scene, .film) == .scenePerExposure, "Scene, the whole: Film Exposure and each exposure's own white balance (R3)")
        expect(kind(.scene, .bottom) == .sceneExposure, "Scene, an exposure: its own white balance")
        expect(kind(.effects, .top) == .effectsExposure, "Effects, an exposure: the whole's, with its line")
        var emptied = made; emptied[.top] = nil
        expect(kind(.frame, .top, emptied) == .empty, "Frame, an emptied layer: Add Exposure (K7)")
        expect(kind(.film, .top, emptied) == .filmWhole, "Film, an emptied layer: nothing of its own, the whole's")
        expect(kind(.frame, .top, has: { $0 != b }) == .empty, "a photograph gone from the library: its layer is empty")

        // Balance's track.
        let w = 200.0
        func share(_ x: Double) -> Double { broken == rules[1] && x == 0 ? 0 : BalanceTrack.share(at: x, width: w) }
        expect(share(0) == 0.10, "the track starts at 10 %")
        expect(share(w) == 0.90, "and ends at 90 %")
        expect(share(-50) == 0.10 && share(w + 50) == 0.90, "a finger past either end holds there")
        expect(share(w / 2) == 0.5, "its middle is 50 %")
        expect(share(w / 2 + 2) == 0.5, "a percent off the middle falls into the detent")
        expect(abs(share(w * 0.75) - 0.70) < 1e-12, "three quarters along is 70 %, whole percent")
        expect(abs(BalanceTrack.position(of: 0.5, width: w) - w / 2) < 1e-9, "50 % draws the thumb at the middle mark")
        expect(BalanceTrack.stepped(0.5, up: true) == 0.55 && BalanceTrack.stepped(0.9, up: true) == 0.9,
               "VoiceOver's step is 5 %, held at 90 %")
        expect(BalanceTrack.stepped(0.12, up: false) == 0.10, "and onto the twentieths, held at 10 %")
        expect(BalanceTrack.valueText(0.6) == "Top 60 %", "the value reads \"Top 60 %\"")

        // Balance 50 → 70 % through the model's own call: RFC-047 §4's EVs, the frame's light held.
        var balanced = made
        let total = balanced.totalGain ?? 0
        balanced.setBalance(share(w * 0.75))
        let top = balanced[.top]?.exposureEV ?? 0, bottom = balanced[.bottom]?.exposureEV ?? 0
        expect(abs(top - log2(0.7)) < 1e-12 && abs(bottom - log2(0.3)) < 1e-12, "70 % is log2 0.7 and log2 0.3 from a new double")
        expect(abs((balanced.totalGain ?? 0) - total) < 1e-12, "the frame's light is held")

        // The Latitude card's name.
        expect(DoubleWords.latitudeName(made, picked: .film) == "Both exposures", "the whole picked: Both exposures (K1)")
        expect(DoubleWords.latitudeName(made, picked: .top) == "Top", "an exposure picked: its name (K2)")
        // Broken: the picked layer's name, whatever is left.
        let k7 = broken == rules[2] ? DoubleExposure.Layer.top.title : DoubleWords.latitudeName(emptied, picked: .top)
        expect(k7 == "Bottom", "one exposure left: the card reads it, by its name (K7: Bottom)")

        // The export refusal.
        expect(DoubleWords.exportRefusal(made, has: all) == nil, "a double with its photographs exports")
        expect(DoubleWords.exportRefusal(made, has: { _ in false }) != nil, "one with none of them says why")
        // R10: an emptied layer is not exported one stop dark; the pair's rule.
        var oneLeft = made; oneLeft[.top] = nil
        let r10 = broken == rules[7] ? nil : DoubleWords.exportRefusal(oneLeft, has: all)
        expect(r10 == "Fill both exposures to export the double exposure.", "one exposure left: refused, and why (R10)")

        // What a visit moved.
        var swapped = made; swapped.swap()
        // Broken: the order compared alone, as a replacement would be.
        let swapMoves: Set<String> = broken == rules[3] ? ["photograph"] : DoubleExposure.moves(from: made, to: swapped)
        expect(swapMoves == ["swap"], "a swap is a swap, not a photograph replaced")
        var replaced = made; replaced[.top] = DoubleExposure.Exposure(frame: UUID())
        expect(DoubleExposure.moves(from: made, to: replaced) == ["photograph"], "another photograph is a photograph")
        expect(DoubleExposure.moves(from: made, to: balanced) == ["balance"], "Balance moved is balance")
        var own = made; own.exposure(-0.5, of: .top); own.exposure(-1.5, of: .bottom)
        own.setBalance(0.5)
        expect(DoubleExposure.moves(from: made, to: own) == ["exposure"], "both moved with Balance held at 50 % is exposure, not balance")
        var read = made
        if let e = read[.top] { read.keep(reading: 1.3, of: .top, for: DoubleExposure.meterKey(e)) }
        expect(DoubleExposure.moves(from: made, to: read).isEmpty, "a reading arriving is no move")
        var placed = made; placed[.top]?.placement.base.scale = 1.3; placed[.top]?.placement.flipped = true
        expect(DoubleExposure.moves(from: made, to: placed) == ["place", "flip"], "a placement and a flip")
        // Whose photograph Decode acts on (the phase-2 review): the layer picked, never the bottom for an empty one.
        // R3 (the Mac): white balance is each exposure's; the whole picked writes no photograph.
        let wholeDecode = broken == rules[6] ? .bottom : made.decodePosition(on: .film)
        expect(made.decodePosition(on: .top) == .top && wholeDecode == nil,
               "Decode: the exposure picked; with the whole, no photograph's (R3)")
        let emptyDecode = broken == rules[4] ? .bottom : emptied.decodePosition(on: .top)
        expect(emptyDecode == nil, "an empty layer picked: no photograph to reset or paste onto")
        var bottomless = made; bottomless[.bottom] = nil
        expect(bottomless.decodePosition(on: .film) == nil && bottomless.decodePosition(on: .top) == .top,
               "the whole with the bottom empty: still none; the top picked: the top's (R3)")

        // ↺ of Film Exposure on the V5 page (PRD 2 §4.2): the whole puts Balance back to 50 % and both exposures as made.
        var look = FrameEdit(); look.params.exposureCompensationEV = 0.7
        var moved = balanced; moved[.top]?.autoExposure = false; moved[.bottom]?.meterMethod = "highlights"
        let meters: (UUID) -> String = { _ in "legacy" }
        // Broken: the look's Film Exposure alone, as V5's ↺ had done.
        let (whole, wholeLook) = broken == rules[5] ? (moved, look.resetting(.filmExposure))
                                                    : moved.filmExposureReset(look: look, picked: nil, madeMeter: meters)
        expect(whole.balance.map { abs($0 - 0.5) < 1e-12 } ?? false, "↺ on the whole: Balance 50 %")
        expect(DoubleExposure.Position.allCases.allSatisfy { whole[$0]?.exposureEV == DoubleExposure.madeEV && whole[$0]?.autoExposure == true
                                                              && whole[$0]?.meterMethod == "legacy" },
               "↺ on the whole: both exposures at −1 EV, metered as made")
        expect(wholeLook.params.exposureCompensationEV == 0 && wholeLook.params.autoExposure, "↺ on the whole: Film Exposure 0, the meter on")
        expect(whole[.top]?.placement == moved[.top]?.placement && whole[.top]?.frame == moved[.top]?.frame,
               "↺ keeps the placements and the order")
        let (one, oneLook) = moved.filmExposureReset(look: look, picked: .top, madeMeter: meters)
        expect(one[.top]?.exposureEV == DoubleExposure.madeEV && one[.bottom] == moved[.bottom] && oneLook == look,
               "↺ on an exposure: its own stops and meter, nothing else")
        let (same, sameLook) = made.filmExposureReset(look: FrameEdit(), picked: nil, madeMeter: meters)
        expect(same == made && sameLook.params.exposureCompensationEV == 0, "a new double: ↺ has nothing to do")

        // Info's Changed row (K8: "Changed · Balance").
        expect(made.changedWords.isEmpty && made.changedText(look: FrameEdit()) == "Nothing yet", "a new double: Nothing yet")
        expect(balanced.changedWords == ["Balance"], "Balance moved names Balance")
        expect(own.changedWords == ["Exposure"], "both exposures moved at 50 %: Exposure")
        expect(placed.changedWords == ["Place"], "an exposure placed: Place")
        var turned = made; turned.swap()
        expect(turned.changedWords.contains("Swapped"), "the photograph it began with on top: Swapped")
        expect(balanced.changedText(look: look).hasPrefix("Balance · "), "the piece's words before the look's")

        _ = made.fill(.bottom, with: nil)
        expect(made[.bottom] != nil, "the photograph it began with is not removed (the model refuses)")

        if !quiet { print("Double exposure darkroom: \(passed) passed, \(failed) failed") }
        return failed
    }
}
