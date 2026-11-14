//  DoubleRules.swift — the double exposure's darkroom as rules, with no view in them (RFC-050 §4, PRD 2 §4).
//
//  What each tab shows for the layer picked, Balance's track, the card's name, the words a panel says, and what a
//  visit moved: Foundation only, so `tools/double_darkroom_selftest.swift` compiles them on a Mac with the model
//  and holds them, and the pages (`DoublePanels.swift`, `DevelopScreen`) and the harness (`DoubleHarness`) read
//  the same rule rather than each its own copy.

import Foundation

/// What a tab of the darkroom holds for the layer picked (RFC-050 §4's table, PRD 2 §4): the drawn page's panels
/// and the harness's check of them (`DoubleHarness`, "each layer and its panels") read the same rule.
enum DoublePanelKind: String, Sendable {
    // `scenePerExposure` (the Mac, the UX review's R3): with the whole picked, Decode shows Film Exposure and a way
    // into each exposure's own white balance — not the bottom's alone under the whole.
    case filmWhole, filmExposure, frameWhole, picture, empty, printWhole, printExposure,
         scenePerExposure, sceneExposure, effectsWhole, effectsExposure

    /// `has`: whether the library still has a photograph — a layer whose photograph has gone is empty.
    static func of(_ tab: DevelopTab, _ layer: DoubleExposure.Layer, _ double: DoubleExposure, has: (UUID) -> Bool) -> DoublePanelKind {
        let position = layer.position
        let held = position.flatMap { double[$0] }.map { has($0.frame) } ?? false
        switch tab {
        case .film: return position != nil && held ? .filmExposure : .filmWhole
        case .frame: return position == nil ? .frameWhole : held ? .picture : .empty
        case .print: return position == nil ? .printWhole : .printExposure
        case .scene: return position == nil ? .scenePerExposure : held ? .sceneExposure : .empty
        case .effects: return position == nil ? .effectsWhole : .effectsExposure
        }
    }
}

/// **Balance's track** (K1, `gen_double_v1.balance_row`): 10 % at its start, 90 % at its end, whole percent, with a
/// detent at 50 % — the film shooter's rule, each at −1 EV — within a percent and a half of it.
enum BalanceTrack {
    static let range = DoubleExposure.balanceRange
    static let detent = 0.015

    /// The share at `x` along a track `width` long.
    static func share(at x: Double, width: Double) -> Double {
        guard width > 0 else { return 0.5 }
        let span = range.upperBound - range.lowerBound
        var s = range.lowerBound + min(max(x / width, 0), 1) * span
        s = (s * 100).rounded() / 100
        if abs(s - 0.5) <= detent { s = 0.5 }
        return s.clamped(to: range)
    }

    /// Where the thumb of `s` is along a track `width` long.
    static func position(of s: Double, width: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        return (s.clamped(to: range) - range.lowerBound) / span * width
    }

    /// VoiceOver's step: 5 %, onto the twentieths.
    static func stepped(_ s: Double, up: Bool) -> Double {
        (((s + (up ? 0.05 : -0.05)) * 20).rounded() / 20).clamped(to: range)
    }

    /// "Top 60 %": the value at the row's end, and what VoiceOver reads.
    static func valueText(_ s: Double) -> String {
        L("Top \(Int((s * 100).rounded())) %")
    }
}

/// The double's words on its panels.
enum DoubleWords {
    /// K2's line under the film cards on an exposure.
    static var filmIsWhole: String { L("One film for both exposures: a film chosen here is the whole's.") }
    /// K3's line under the film's sizes.
    static var frameIsBottoms: String { L("The frame's size and shape are the bottom exposure's.") }
    /// K5's line, in the enlarger's label.
    static var printTogether: String { L("One negative: both exposures print together.") }
    /// Effects on an exposure (not drawn: PRD 2 §4, "the same, with a line saying so").
    static var effectsWhole: String { L("Grain, halation and glare are the whole's: both exposures together.") }
    /// The Latitude card's name with the whole picked (README, "Mine" 11).
    static var bothExposures: String { L("Both exposures") }

    /// Whose scene the Latitude card reads, by name: the whole is both exposures' light — or, with one layer
    /// empty, the one exposure there is (K7: "Bottom"); an exposure picked, its name.
    static func latitudeName(_ double: DoubleExposure, picked: DoubleExposure.Layer) -> String {
        let held = DoubleExposure.Position.allCases.filter { double[$0] != nil }
        if held.count == 1, let only = held.first { return DoubleExposure.Layer(only).title }
        return picked == .film ? bothExposures : picked.title
    }

    /// **Why a double exposure cannot be exported**, or nil when it can (`ExportService`, `EngineRouter.exportSource`):
    /// both layers must hold a photograph the library has, as both holes of a pair must (`PairWords.exportRefusal`).
    /// The UX review's R10: a double with one layer emptied would export one stop dark (its remaining
    /// exposure at −1 EV); the darkroom's preview stays film-true, and only the export is refused.
    static func exportRefusal(_ double: DoubleExposure, has: (UUID) -> Bool) -> String? {
        let held = DoubleExposure.Position.allCases.filter { double[$0].map { has($0.frame) } ?? false }
        if held.isEmpty { return L("Its photographs are no longer in the library.") }
        return held.count < DoubleExposure.maxExposures ? L("Fill both exposures to export the double exposure.") : nil
    }
}

extension DoubleExposure {
    /// What a darkroom visit left changed of a double exposure's piece, by name, for the log (the `develop` `visit` record's `double_moved`):
    /// "swap", "photograph" (replaced, removed or added), "balance", "exposure" (an exposure's own stops moved,
    /// Balance held), "place", "flip", "meter". Readings are observations, not moves (`developed`).
    static func moves(from was: DoubleExposure, to now: DoubleExposure) -> Set<String> {
        let a = was.developed, b = now.developed
        let order = Position.allCases
        if order.map({ a[$0]?.frame }) != order.map({ b[$0]?.frame }) {
            let same = Set(order.compactMap { a[$0]?.frame }) == Set(order.compactMap { b[$0]?.frame })
            return [same && a.isFilled && b.isFilled ? "swap" : "photograph"]
        }
        var moved: Set<String> = []
        if let s0 = a.balance, let s1 = b.balance, abs(s0 - s1) > 1e-9 { moved.insert("balance") }
        else if order.contains(where: { a[$0]?.exposureEV != b[$0]?.exposureEV }) { moved.insert("exposure") }
        for p in order {
            if a[p]?.placement.base != b[p]?.placement.base { moved.insert("place") }
            if a[p]?.placement.flipped != b[p]?.placement.flipped { moved.insert("flip") }
            if a[p]?.autoExposure != b[p]?.autoExposure || a[p]?.meterMethod != b[p]?.meterMethod { moved.insert("meter") }
        }
        return moved
    }
}

// MARK: - what the page's ↺, paste and Info act on (the phase-2 review)

extension DoubleExposure {
    /// **Whose photograph Decode's white balance is** on this layer — what the Scene panel shows, and so what its
    /// ↺, its moved dot and a pasted white balance act on: with an exposure picked, that exposure's alone (nil
    /// for an empty layer: nothing to reset or paste onto, as the panel shows nothing). **With the whole picked,
    /// none** (the UX review's R3: the bottom's would make warming "the whole" warm half the
    /// picture and edit a library photograph unasked). White balance belongs to each exposure.
    func decodePosition(on layer: Layer) -> Position? {
        guard let position = layer.position else { return nil }
        return self[position] != nil ? position : nil
    }

    /// **↺ of Film Exposure** on the V5 page (`AppModel.resetPage`, PRD 2 §4.2), as a rule. With the whole picked:
    /// the look's Film Exposure, Balance back to 50 % and both exposures' own stops and meters as made (each
    /// −1 EV, metered alone with its photograph's intent — `madeMeter`), the whole's meter on: `resetDouble`'s
    /// part of the piece (the film is Decode's other scopes'). With an exposure picked: that exposure's own
    /// stops and meter. Never the placements, the flips or the order (the pair's rule).
    func filmExposureReset(look: FrameEdit, picked: Position?, madeMeter: (UUID) -> String) -> (DoubleExposure, FrameEdit) {
        var piece = self, look = look
        let reset: [Position] = picked.map { [$0] } ?? Position.allCases
        for position in reset {
            guard let e = piece[position] else { continue }
            piece[position]?.exposureEV = Self.madeEV
            piece[position]?.autoExposure = true
            piece[position]?.meterMethod = madeMeter(e.frame)
        }
        if picked == nil {
            look = look.resetting(.filmExposure)
            look.params.autoExposure = Position.allCases.contains { piece[$0]?.autoExposure == true }
        }
        return (piece, look)
    }

    /// **What Info's Changed row names of the piece** (K8: "Changed · Balance"): Balance
    /// moved from 50 %, an exposure's own stops moved with Balance held, the layers swapped (the photograph it
    /// began with on top), an exposure placed or flipped. Before the look's own changes (`FrameEdit.changedText`).
    var changedWords: [String] {
        var said: [String] = []
        if let s = balance, abs(s - 0.5) > 1e-9 { said.append(L("Balance")) }
        else if Position.allCases.contains(where: { self[$0].map { $0.exposureEV != Self.madeEV } ?? false }) {
            said.append(L("Exposure"))
        }
        if let origin, position(of: origin) == .top { said.append(L("Swapped", as: "a double exposure's layers")) }
        if Position.allCases.contains(where: { self[$0].map { $0.placement.held != Placement().held } ?? false }) {
            said.append(L("Place"))
        }
        return said
    }

    /// Info's Changed row for a double exposure: the piece's words, then the look's.
    func changedText(look: FrameEdit) -> String {
        let own = look.changedText
        let words = changedWords + (own == L("Nothing yet") ? [] : [own])
        return words.isEmpty ? L("Nothing yet") : words.joined(separator: " · ")
    }
}
