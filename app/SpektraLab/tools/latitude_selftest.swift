//  latitude_selftest.swift — what the Latitude card draws from the engine's reply, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's and the capture model's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  Compiled with `SceneLatitude.swift` and `ScenePlacement.swift` (no engine, no view). The replies are the engine's
//  own, kept as files: `tools/engine_smoke.sh mac --latitude-json` prints them, and
//  `tools/engine_replies/scene_latitude_{reply,placed,refused}.json` are those three lines — a frame
//  as metered, the same with its highlights pulled back 1.5 stops, and a pull-back the engine
//  refuses. What is checked is what the app then makes of a reply: which bins reach the card
//  and where, how tall, which histogram, where the window and the knees are, what a fit does
//  to a frame's settings and what a request says. Whether the numbers are right for a picture
//  is the engine's (`engine/tests`).
//
//  **Scene Placement is solved in the app** (`Sources/Engine/ScenePlacement.swift`: the engine's
//  Fit in Swift, the window of pull-backs it takes, the ruler over that window), **and the engine
//  is the judge of it.** `tools/engine_smoke.sh mac --latitude-grid <photo> <out>` asks the Mac
//  engine for its own fits of a real frame — 280 pairs of pull-backs on both sides of every
//  refusal, at five settings of roll-off, lift bound and percentile (the desktop's own test's
//  grid), placed histograms, and its verdict on every hundredth of the rulers' 0…8 — and
//  `tools/engine_replies/scene_placement_*.jsonl` are those lines for four photographs: a Bayer DNG
//  the reference device shot through this app (the grid), an Apple ProRAW and two HEIFs (the sweeps).
//  Held to them here: the app's verdicts and reasons, in the engine's order; its knees, rooms,
//  landings and curves; its placed histograms; that the window it finds is the stretch the engine
//  takes, to the hundredth; that every stop a ruler offers is one the engine takes; and what a
//  ruler's step commits. The photographs are not in the repository; each file names its own.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks
//  against a rule broken on purpose, one at a time, and requires each run to fail.

import Foundation

/// The mapping from a reply to the card's reading, written a second time with its choices as
/// switches, so that each can be thrown the wrong way.
func reading(_ r: SceneLatitudeReply, placed: Bool = true, centre: Double = 0.5, root: Bool = true,
             tallestOnAxis: Bool = true, kneesOfRefusedFit: Bool = false, beyond: Int = 1) -> LatitudeReadout {
    let h = r.scene.histogram
    let shares = placed ? h.placedFractions ?? h.fractions : h.fractions
    let n = shares.count
    let width = (h.hiEV - h.loEV) / Double(n)
    func at(_ i: Int) -> Double { h.loEV + (Double(i) + centre) * width }
    func tall(_ v: Double) -> Double { root ? max(v, 0).squareRoot() : max(v, 0) }
    let on = (0..<n).filter { h.loEV + (Double($0) + 0.5) * width > -8 && h.loEV + (Double($0) + 0.5) * width < 8 }
    let first = max(0, on.first! - beyond), last = min(n - 1, on.last! + beyond)
    let top = (tallestOnAxis ? on : Array(0..<n)).map { tall(shares[$0]) }.max() ?? 0
    let ok = r.fit.valid || kneesOfRefusedFit
    return LatitudeReadout(bins: (first...last).map { top > 0 ? min(1, tall(shares[$0]) / top) : 0 },
                           binsFromEV: at(first), binsToEV: at(last),
                           shadowEV: r.medium.shadowEV, highlightEV: r.medium.highlightEV,
                           highlightPlaced: ok && r.fit.highlight.on ? PlacementSpan(line: r.fit.highlight.sceneExtremeEV, reach: r.fit.highlight.landingEV) : nil,
                           shadowPlaced: ok && r.fit.shadow.on ? PlacementSpan(line: r.fit.shadow.sceneExtremeEV, reach: r.fit.shadow.landingEV) : nil)
}

/// The Fit's solve, written a second time with its choices as switches, so that each can be
/// thrown the wrong way: the mistakes a port of `latitude_fit.cpp` can make and still compile.
struct Solve {
    /// The shadow pull-back is the bounded landing: the lift bound is inverted before the solve.
    var invertsLift = true
    /// The least room a side's curve may turn in.
    var minRoom = 0.5
    /// The shadow's minimum is checked on the bounded landing, before the solve.
    var checksShadowMinimum = true
    /// A pull-back at the lift bound is refused (`<`, not `<=`).
    var refusesAtLiftBound = true
    /// The two knees may not cross.
    var checksCrossing = true
    /// The roll-off is the frame's own, not the default 2.
    var readsRolloff = true
    /// A side's range is refused past 24 stops of room or knee.
    var checksRange = true

    func fit(_ at: PlacementFit.Measured, _ highlight: Double, _ shadow: Double, _ base: SceneLatitudeSettings) -> SceneLatitudeReply.Fit {
        typealias Fit = SceneLatitudeReply.Fit
        func issue(_ code: String, _ side: String) -> Fit.Issue { Fit.Issue(code: code, side: side, message: "") }
        func g(_ D: Double, _ H: Double, _ m: Double) -> Double {
            guard D > 0 else { return 0 }
            if m == 2 { let r = (H * H + D * D).squareRoot(); return -(D * D * D) / (r * (H + r)) }
            if m == 1 { return -(D * D) / (H + D) }
            return D * (H / pow(pow(H, m) + pow(D, m), 1 / m) - 1)
        }
        func knee(_ a: Double, _ C: Double, _ N: Double, _ m: Double) -> Double? {
            let t = a - N
            guard N > 0, t < C else { return nil }
            func landing(_ K: Double) -> Double { K + ((a - K) + g(a - K, C - K, m)) }
            var lo = t - max(0, (a - t) * (C - t)).squareRoot() - 64, hi = t
            guard landing(lo) < t else { return nil }
            var i = 0
            while i < 200, hi - lo > 1e-12 {
                let mid = 0.5 * (lo + hi)
                if landing(mid) > t { hi = mid } else { lo = mid }
                i += 1
            }
            return 0.5 * (lo + hi)
        }
        let m = readsRolloff ? base.rolloff : 2
        var issues: [Fit.Issue] = [], warnings: [Fit.Issue] = []
        var top = Fit.Side(on: false, pullBack: highlight, minimumPullBack: at.highlightExtreme - at.highlightBoundary,
                           sceneExtremeEV: at.highlightExtreme, mediumBoundaryEV: at.highlightBoundary, knee: nil, room: nil,
                           landingEV: 0, slopeAtExtreme: 0)
        var bottom = Fit.Side(on: false, pullBack: shadow, minimumPullBack: at.shadowBoundary - at.shadowExtreme,
                              sceneExtremeEV: at.shadowExtreme, mediumBoundaryEV: at.shadowBoundary, knee: nil, room: nil,
                              landingEV: 0, slopeAtExtreme: 0)
        if highlight > 0 {
            if let K = knee(at.highlightExtreme, at.highlightBoundary, highlight, m) {
                (top.on, top.knee, top.room) = (true, K, at.highlightBoundary - K)
            } else {
                issues.append(issue("pull_back_below_minimum", "highlight"))
            }
        }
        var lift: Double?
        if shadow > 0, checksShadowMinimum, !(shadow > bottom.minimumPullBack) {
            issues.append(issue("pull_back_below_minimum", "shadow"))
        } else if shadow > 0 {
            let L = base.maxLift
            if refusesAtLiftBound ? shadow < L : shadow <= L {
                lift = invertsLift ? shadow * L / (L * L - shadow * shadow).squareRoot() : shadow
            } else {
                issues.append(issue("pull_back_exceeds_max_lift", "shadow"))
            }
        }
        if let lift {
            if let K = knee(-at.shadowExtreme, -at.shadowBoundary, lift, m) {
                (bottom.on, bottom.knee, bottom.room) = (true, -K, -K - at.shadowBoundary)
            } else {
                issues.append(issue("pull_back_below_minimum", "shadow"))
            }
        }
        for (side, name) in [(top, "highlight"), (bottom, "shadow")] where side.on {
            if side.room! < minRoom { issues.append(issue("room_below_minimum", name)) }
            if checksRange, side.room! > 24 || abs(side.knee!) > 24 { issues.append(issue("out_of_range", name)) }
        }
        var core: Double?
        if top.on, bottom.on {
            core = top.knee! - bottom.knee!
            if checksCrossing, !(bottom.knee! < top.knee!) { issues.append(issue("knees_cross", "both")) }
        }
        if top.on, top.knee! < 0 { warnings.append(issue("knee_past_midgrey", "highlight")) }
        if bottom.on, bottom.knee! > 0 { warnings.append(issue("knee_past_midgrey", "shadow")) }
        var curve = base
        (curve.highlightRoom, curve.shadowRoom) = (0, 0)
        if top.on { (curve.highlightKnee, curve.highlightRoom) = (top.knee!, top.room!) }
        if bottom.on { (curve.shadowKnee, curve.shadowRoom) = (bottom.knee!, bottom.room!) }
        // The curve itself is the app's: the landing and the slope are read off it, and it is held to the
        // engine's through the placed histograms.
        (top.landingEV, top.slopeAtExtreme) = (PlacementFit.mapped(top.sceneExtremeEV, curve), PlacementFit.slope(top.sceneExtremeEV, curve))
        (bottom.landingEV, bottom.slopeAtExtreme) = (PlacementFit.mapped(bottom.sceneExtremeEV, curve), PlacementFit.slope(bottom.sceneExtremeEV, curve))
        let valid = issues.isEmpty
        return Fit(valid: valid, issues: issues, warnings: warnings, highlight: top, shadow: bottom, coreStops: core,
                   paramsDelta: valid ? Fit.ParamsDelta(active: top.on || bottom.on, norm: base.norm, highlightKnee: curve.highlightKnee,
                                                        highlightRoom: curve.highlightRoom, shadowKnee: curve.shadowKnee,
                                                        shadowRoom: curve.shadowRoom, rolloff: base.rolloff, maxLift: base.maxLift) : nil)
    }

    /// The window the same way the app finds it, over this solve.
    func window(_ side: PlacementSide, _ other: Double, _ at: PlacementFit.Measured, _ base: SceneLatitudeSettings) -> PlacementWindow {
        PlacementWindow.search(side: side, minimum: at.minimum(side), in: ScenePlacement.range, step: PlacementRuler.step) { x in
            fit(at, side == .highlight ? x : other, side == .shadow ? x : other, base).issues.first.map { .refused($0) } ?? .valid
        }
    }
}

/// The rules under test, so a broken one can be put in their place.
struct Rules {
    var name = "the app's"
    var readout: (SceneLatitudeReply) -> LatitudeReadout = { LatitudeReadout($0) }
    var apply: (inout SceneLatitudeSettings, SceneLatitudeReply.Fit) -> Bool = { $0.apply($1) }
    var json: (SceneLatitudeRequest) -> String = { $0.json }
    var shadowLabel: (CGFloat) -> CGFloat = { LatitudeReadout.labelX(shadowEdge: $0) }
    var highlightLabel: (CGFloat, CGFloat) -> CGFloat = { LatitudeReadout.labelX(highlightEdge: $0, width: $1) }
    var note: (SceneLatitudeReply.Fit) -> PlacementNote? = { $0.note }
    /// What a curve tab draws behind its curve (RFC-035 §3.2, trap 16).
    var hills: (LatitudeReadout, CurveChannel) -> SceneHills = { $0.hills(for: $1) }

    // Scene Placement, solved in the app.
    var extremes: (SceneLatitudeReply, SceneLatitudeSettings) -> PlacementFit.Measured = { PlacementFit.Measured($0, for: $1) }
    var fit: (PlacementFit.Measured, Double, Double, SceneLatitudeSettings) -> SceneLatitudeReply.Fit = {
        PlacementFit.fit($0, highlight: $1, shadow: $2, base: $3)
    }
    var placed: (SceneLatitudeReply.Scene.Histogram, SceneLatitudeSettings) -> [Double] = { PlacementFit.placedHistogram($0, curve: $1) }
    var apart: (SceneLatitudeReply, SceneLatitudeSettings) -> String? = { $0.disagreement(with: $1) }
    var window: (PlacementSide, Double, PlacementFit.Measured, SceneLatitudeSettings) -> PlacementWindow = {
        ScenePlacement.window($0, other: $1, on: $2, base: $3)
    }
    var ruler: (ClosedRange<Double>?, Double) -> PlacementRuler = { PlacementRuler($0, holding: $1) }
    var place: (Double, PlacementSide, SceneLatitudeSettings, SceneLatitudeReply) -> SceneLatitudeSettings? = {
        ScenePlacement.place($0, moving: $1, in: $2, on: $3)
    }
    var panel: (SceneLatitudeSettings, SceneLatitudeReply, PlacementSide?) -> PlacementPanel = {
        ScenePlacement.panel($0, on: $1, moved: $2)
    }

    /// A wrong port of the solve: the window is then found over it, as the app finds its own.
    static func solving(_ name: String, _ solve: Solve) -> Rules {
        Rules(name: name, fit: { solve.fit($0, $1, $2, $3) }, window: { solve.window($0, $1, $2, $3) })
    }

    static let broken: [Rules] = [
        Rules(name: "the frame as metered, whatever was placed", readout: { reading($0, placed: false) }),
        Rules(name: "a bin drawn at its left edge", readout: { reading($0, centre: 0) }),
        Rules(name: "heights in proportion, not by the square root", readout: { reading($0, root: false) }),
        Rules(name: "the tallest bin of the whole histogram, on the axis or off it", readout: { reading($0, tallestOnAxis: false) }),
        Rules(name: "the knees of a fit the engine refused", readout: { reading($0, kneesOfRefusedFit: true) }),
        Rules(name: "the fill stopped at the axis's last bin", readout: { reading($0, beyond: 0) }),
        Rules(name: "a refused fit committed", apply: { s, fit in
            s.highlightPullBack = fit.highlight.pullBack; s.shadowPullBack = fit.shadow.pullBack
            s.active = true
            return true
        }),
        Rules(name: "a fit's curve taken without its pull-backs", apply: { s, fit in
            guard fit.valid, let d = fit.paramsDelta else { return false }
            (s.active, s.highlightKnee, s.highlightRoom, s.shadowKnee, s.shadowRoom) =
                (d.active, d.highlightKnee, d.highlightRoom, d.shadowKnee, d.shadowRoom)
            return true
        }),
        Rules(name: "an absent pull-back sent as 0", json: { r in
            var r = r
            r.highlightPullBack = r.highlightPullBack ?? 0; r.shadowPullBack = r.shadowPullBack ?? 0
            return r.json
        }),
        Rules(name: "a boundary's label always outside its line", shadowLabel: { $0 - 15 }, highlightLabel: { w, _ in w + 15 }),
        Rules(name: "the engine's own sentence on the panel", note: { fit in
            (fit.issues.first ?? fit.warnings.first).map { PlacementNote(text: $0.message, refused: !fit.valid) }
        }),
        Rules(name: "a warning read as a refusal", note: { fit in fit.note.map { PlacementNote(text: $0.text, refused: true) } }),
        // The fallback the plot had until 2026-10-26: the luminance drawn in a colour tab's place
        // when the reading carries no row for it (trap 16 — it looked exactly like the real thing).
        Rules(name: "the luminance drawn in a colour tab's place", hills: { r, c in
            let real = r.hills(for: c)
            return real == .none && c != .luma ? .luma(r.bins) : real
        }),
        Rules(name: "every refusal the same line", note: { fit in
            fit.valid ? fit.note : PlacementNote(text: "That placement cannot be solved on this frame.", refused: true)
        }),

        // Scene Placement, solved in the app. A wrong port of the engine's solve:
        .solving("the shadow pull-back taken as the lift itself, its bound not inverted", Solve(invertsLift: false)),
        .solving("a quarter stop of room called enough", Solve(minRoom: 0.25)),
        .solving("the shadow's minimum left to the solve", Solve(checksShadowMinimum: false)),
        .solving("a pull-back at the lift bound taken", Solve(refusesAtLiftBound: false)),
        .solving("the two curves allowed to cross", Solve(checksCrossing: false)),
        .solving("every frame solved at the default roll-off", Solve(readsRolloff: false)),
        .solving("a knee or a room past the curve's range taken", Solve(checksRange: false)),
        Rules(name: "the shadow fitted to P1 whatever the frame asks", extremes: { reply, settings in
            var s = settings
            s.shadowPercentile = 1
            return PlacementFit.Measured(reply, for: s)
        }),
        Rules(name: "the placed histogram without the lift bound", placed: { histogram, curve in
            var c = curve
            c.maxLift = 1000
            return PlacementFit.placedHistogram(histogram, curve: c)
        }),
        Rules(name: "the placed histogram at one sample a bin", placed: { histogram, curve in
            guard curve.highlightRoom > 0 || curve.shadowRoom > 0 else { return histogram.fractions }
            let n = histogram.fractions.count, width = (histogram.hiEV - histogram.loEV) / Double(n)
            var out = [Double](repeating: 0, count: n)
            for (b, share) in histogram.fractions.enumerated() {
                let e = histogram.loEV + (Double(b) + 0.5) * width
                out[min(max(Int(((PlacementFit.mapped(e, curve) - histogram.loEV) / width).rounded(.down)), 0), n - 1)] += share
            }
            return out
        }),
        // The engine's own fit, when it comes back with a measurement, not held against the app's:
        Rules(name: "the engine's fit in a reply never looked at", apart: { _, _ in nil }),
        Rules(name: "the engine's fit compared by its verdict alone", apart: { reply, settings in
            // A number that differs is said as "the engine's shadow knee is …"; a verdict, as "the engine refuses it".
            reply.disagreement(with: settings).flatMap { $0.contains("the engine's ") ? nil : $0 }
        }),
        // A wrong window:
        Rules(name: "the window's edges left where the walk's steps fall", window: { side, other, at, base in
            // The first accepted step and the last, with no bisection between a step and its neighbour.
            let takes = stride(from: 5, through: 800, by: 5).map { Double($0) / 100 }.filter { x in
                PlacementFit.fit(at, highlight: side == .highlight ? x : other, shadow: side == .shadow ? x : other, base: base).valid
            }
            let found = ScenePlacement.window(side, other: other, on: at, base: base)
            guard let least = takes.first, let most = takes.last else { return found }
            return PlacementWindow(span: least...most, below: found.below, above: found.above)
        }),
        Rules(name: "a window that keeps the engine's side for a crossing", window: { side, other, at, base in
            var w = ScenePlacement.window(side, other: other, on: at, base: base)
            if w.above?.code == "knees_cross" { w.above?.side = "both" }
            return w
        }),
        Rules(name: "a window with one reason for both its edges", window: { side, other, at, base in
            var w = ScenePlacement.window(side, other: other, on: at, base: base)
            if w.span != nil { w.above = w.above.map { _ in w.below } }
            return w
        }),
        // A wrong ruler:
        Rules(name: "a ruler starting at its own first step, whatever the Fit takes", ruler: { _, value in
            .plain(over: ScenePlacement.range, holding: value)
        }),
        Rules(name: "a ruler of one stop, the least the Fit takes", ruler: { span, value in
            PlacementRuler(span.map { $0.lowerBound...$0.lowerBound }, holding: value)
        }),
        Rules(name: "a side that is on, offered nothing, with no way to turn it off", ruler: { span, value in
            PlacementRuler(span, holding: span == nil ? 0 : value)
        }),
        // A wrong step:
        Rules(name: "a value asked outside the window solved as asked", place: { asked, side, settings, reply in
            var placed = settings
            placed[side] = max(0, asked)
            guard placed[side] > 0 else { return ScenePlacement.place(0, moving: side, in: settings, on: reply) }
            let fit = PlacementFit.fit(PlacementFit.Measured(reply, for: settings), highlight: placed.highlightPullBack,
                                       shadow: placed.shadowPullBack, base: settings)
            return placed.apply(fit) ? placed : nil
        }),
        Rules(name: "a side turned off by solving the other side again", place: { asked, side, settings, reply in
            guard asked <= 0 else { return ScenePlacement.place(asked, moving: side, in: settings, on: reply) }
            var placed = settings
            placed[side] = 0
            let fit = PlacementFit.fit(PlacementFit.Measured(reply, for: settings), highlight: placed.highlightPullBack,
                                       shadow: placed.shadowPullBack, base: settings)
            return placed.apply(fit) ? placed : settings
        }),
        Rules(name: "a step committed beside a side that no longer fits", place: { asked, side, settings, reply in
            if let placed = ScenePlacement.place(asked, moving: side, in: settings, on: reply) { return placed }
            var placed = settings
            placed[side] = asked
            return placed
        }),
        Rules(name: "a step that waits on something", place: { asked, side, settings, reply in
            usleep(5000)
            return ScenePlacement.place(asked, moving: side, in: settings, on: reply)
        }),
        // A wrong panel:
        Rules(name: "a ruler with nothing on it left live", panel: { settings, reply, moved in
            var p = ScenePlacement.panel(settings, on: reply, moved: moved)
            (p.highlight.enabled, p.shadow.enabled) = (true, true)
            return p
        }),
        Rules(name: "nothing said of a ruler that offers nothing", panel: { settings, reply, moved in
            var p = ScenePlacement.panel(settings, on: reply, moved: moved)
            if p.note?.refused == false, p.note != .flat { p.note = nil }
            return p
        }),
        Rules(name: "a ruler's end explained whichever ruler moved", panel: { settings, reply, _ in
            let both = PlacementSide.allCases.map { ScenePlacement.panel(settings, on: reply, moved: $0) }
            return both.first { $0.note?.refused == true } ?? both[0]
        }),
        Rules(name: "what a placement costs said over the ruler it has just dimmed", panel: { settings, reply, moved in
            var p = ScenePlacement.panel(settings, on: reply, moved: moved)
            let fit = PlacementFit.fit(PlacementFit.Measured(reply, for: settings), highlight: settings.highlightPullBack,
                                       shadow: settings.shadowPullBack, base: settings)
            if moved != nil, p.note?.text.contains("nothing fits beside") == true, fit.warnings.contains(where: { $0.code == "knee_past_midgrey" }) {
                p.note = .flat
            }
            return p
        }),
        Rules(name: "a ruler the frame leaves empty said again over what a placement costs", panel: { settings, reply, moved in
            var p = ScenePlacement.panel(settings, on: reply, moved: moved)
            if moved != nil, p.note == .flat { p.note = ScenePlacement.panel(settings, on: reply, moved: nil).note }
            return p
        }),
        Rules(name: "the line under the rulers as long as it likes", panel: { settings, reply, moved in
            var p = ScenePlacement.panel(settings, on: reply, moved: moved)
            p.note = p.note.map { PlacementNote(text: $0.text + " Pull it back a little further.", refused: $0.refused) }
            return p
        }),
        Rules(name: "a placement that no longer fits passed over in silence", panel: { settings, reply, moved in
            var p = ScenePlacement.panel(settings, on: reply, moved: moved)
            if p.note == .stale { p.note = nil }
            return p
        }),
    ]
}

// MARK: - the engine's own fits of real frames

/// One line of `tools/engine_replies/scene_placement_*.jsonl`, whichever kind it is.
private struct Line: Decodable {
    struct Frame: Decodable { var file: String; var decoded: String; var film: String; var paper: String }
    struct Settings: Decodable {
        var rolloff: Double
        var max_lift: Double
        var norm: String
        var shadow_percentile: Double
        var highlight_percentile: Double
    }
    struct Placed: Decodable { var fit: SceneLatitudeReply.Fit; var placed_fractions: [Double] }
    struct Run: Decodable { var from: Int; var to: Int; var code: String; var side: String }
    var frame: Frame?
    var measured: SceneLatitudeReply?
    var settings: Settings?
    var fit: SceneLatitudeReply.Fit?
    var placed: Placed?
    var sweep: String?
    var other: Double?
    var runs: [Run]?
    var config: Int?
}

/// What the Mac engine said of one photograph (`tools/engine_smoke.sh mac --latitude-grid`, `--latitude-sweeps`).
struct PlacementFixture {
    /// The engine's verdict on every hundredth of one ruler, the other side held.
    struct Sweep {
        var side: PlacementSide
        var other: Double
        var config: Int
        var runs: [(from: Int, to: Int, code: String, side: String)]
        /// The stretches the engine takes, in hundredths of a stop.
        var taken: [ClosedRange<Int>] { runs.filter { $0.code.isEmpty }.map { $0.from...$0.to } }
        /// The engine's reason at a hundredth; empty where it takes the value.
        func code(at hundredth: Int) -> String? { runs.first { $0.from <= hundredth && hundredth <= $0.to }?.code }
        func takes(_ value: Double) -> Bool { code(at: Int((value * 100).rounded())) == "" }
    }

    var photo = ""
    /// The frame with both sides off, and the settings it was asked with, by setting.
    var measured: [Int: (reply: SceneLatitudeReply, base: SceneLatitudeSettings)] = [:]
    var fits: [(config: Int, fit: SceneLatitudeReply.Fit)] = []
    var placed: [(config: Int, fit: SceneLatitudeReply.Fit, fractions: [Double])] = []
    var sweeps: [Sweep] = []

    static func load(_ name: String) -> PlacementFixture? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("engine_replies/scene_placement_\(name).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out = PlacementFixture()
        let decoder = JSONDecoder()
        for raw in text.split(separator: "\n") {
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)) else { return nil }
            if let frame = line.frame { out.photo = frame.file }
            if let reply = line.measured, let s = line.settings, let config = line.config {
                var base = SceneLatitudeSettings()
                (base.rolloff, base.maxLift, base.norm) = (s.rolloff, s.max_lift, s.norm)
                (base.shadowPercentile, base.highlightPercentile) = (s.shadow_percentile, s.highlight_percentile)
                out.measured[config] = (reply, base)
            }
            if let fit = line.fit, let config = line.config { out.fits.append((config, fit)) }
            if let placed = line.placed, let config = line.config { out.placed.append((config, placed.fit, placed.placed_fractions)) }
            if let side = line.sweep.flatMap(PlacementSide.init(rawValue:)), let other = line.other, let runs = line.runs, let config = line.config {
                out.sweeps.append(Sweep(side: side, other: other, config: config, runs: runs.map { ($0.from, $0.to, $0.code, $0.side) }))
            }
        }
        return out.measured.isEmpty ? nil : out
    }
}

/// A Fit that takes the open interval `(low, high)` and refuses the rest the way the engine does,
/// counting what it was asked: the desktop's own test's (`ScenePlacementTests`).
private final class FakeFit {
    let low: Double, high: Double
    var asked = 0
    init(_ low: Double, _ high: Double) { self.low = low; self.high = high }
    func verdict(_ x: Double) -> PlacementWindow.Verdict {
        asked += 1
        if x <= low { return .refused(.init(code: "room_below_minimum", side: "highlight", message: "")) }
        if x >= high { return .refused(.init(code: "knees_cross", side: "both", message: "")) }
        return .valid
    }
}

/// Scene Placement as the app solves it, against the engine's own fits of four real frames.
func placementChecks(_ rules: Rules, quiet: Bool, expect: (Bool, String) -> Void) {
    typealias Fit = SceneLatitudeReply.Fit
    guard let bayer = PlacementFixture.load("bayer"), let proraw = PlacementFixture.load("proraw"),
          let heif = PlacementFixture.load("heif"), let narrow = PlacementFixture.load("heif2"),
          let onBayer = bayer.measured[0], let onProraw = proraw.measured[0], let onHeif = heif.measured[0] else {
        expect(false, "the engine's fits in tools/engine_replies/scene_placement_*.jsonl did not decode")
        return
    }
    let all = [bayer, proraw, heif, narrow]
    func close(_ a: Double?, _ b: Double?, _ eps: Double) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): abs(a - b) <= eps
        default: false
        }
    }
    func hundredths(_ v: Double) -> Int { Int((v * 100).rounded()) }
    func words(_ issues: [Fit.Issue]) -> [String] { issues.map { $0.code + "/" + $0.side } }

    // What the files hold: enough, on both sides of every line the engine draws.
    let refusals = Set(bayer.fits.compactMap { $0.fit.issues.first?.code })
    expect(bayer.fits.count == 280 && bayer.measured.count == 5 && bayer.fits.filter { $0.fit.valid }.count > 20,
           "the grid is 280 of the engine's fits at five settings, more than twenty of them taken")
    expect(refusals == ["knees_cross", "out_of_range", "pull_back_below_minimum", "pull_back_exceeds_max_lift", "room_below_minimum"],
           "the grid crosses every refusal the engine makes (\(refusals.sorted()))")
    expect(Set(bayer.fits.flatMap { words($0.fit.warnings) }) == ["knee_past_midgrey/highlight", "knee_past_midgrey/shadow"],
           "and both of its warnings")
    expect(all.map(\.sweeps.count).reduce(0, +) == 15 && all.allSatisfy { $0.sweeps.allSatisfy { $0.runs.first?.from == 1 && $0.runs.last?.to == 800 } },
           "fifteen sweeps of the engine's verdict over every hundredth of a ruler's 0…8")

    // 1. The solve is the engine's.
    var compared = 0, verdicts = 0, reasons = 0, numbers = 0, curves = 0, copies = 0
    var first = ""
    for fixture in all {
        let asked = fixture.fits + fixture.placed.map { ($0.config, $0.fit) } + fixture.measured.map { ($0.key, $0.value.reply.fit) }
        for (config, engine) in asked {
            guard let m = fixture.measured[config] else { continue }
            let at = rules.extremes(m.reply, m.base)
            let mine = rules.fit(at, engine.highlight.pullBack, engine.shadow.pullBack, m.base)
            let what = " — \(fixture.photo), roll-off \(m.base.rolloff), lift \(m.base.maxLift), P\(m.base.shadowPercentile), highlight \(engine.highlight.pullBack), shadow \(engine.shadow.pullBack)"
            compared += 1
            if mine.valid != engine.valid { verdicts += 1; if first.isEmpty { first = what } }
            if words(mine.issues) != words(engine.issues) || words(mine.warnings) != words(engine.warnings) {
                reasons += 1
                if first.isEmpty { first = what + ": \(words(mine.issues)) for the engine's \(words(engine.issues))" }
            }
            func same(_ a: Fit.Side, _ b: Fit.Side) -> Bool {
                a.on == b.on && a.pullBack == b.pullBack && close(a.minimumPullBack, b.minimumPullBack, 1e-12)
                    && a.sceneExtremeEV == b.sceneExtremeEV && a.mediumBoundaryEV == b.mediumBoundaryEV
                    && close(a.knee, b.knee, 1e-9) && close(a.room, b.room, 1e-9)
                    && close(a.landingEV, b.landingEV, 1e-9) && close(a.slopeAtExtreme, b.slopeAtExtreme, 1e-6)
            }
            if !same(mine.highlight, engine.highlight) || !same(mine.shadow, engine.shadow) || !close(mine.coreStops, engine.coreStops, 1e-9) {
                numbers += 1
                if first.isEmpty { first = what }
            }
            var a = m.base, b = m.base
            let tookMine = a.apply(mine), tookEngine = b.apply(engine)
            if tookMine != tookEngine || a.active != b.active || a.norm != b.norm || a.rolloff != b.rolloff || a.maxLift != b.maxLift
                || a.highlightPullBack != b.highlightPullBack || a.shadowPullBack != b.shadowPullBack
                || !close(a.highlightKnee, b.highlightKnee, 1e-9) || !close(a.highlightRoom, b.highlightRoom, 1e-9)
                || !close(a.shadowKnee, b.shadowKnee, 1e-9) || !close(a.shadowRoom, b.shadowRoom, 1e-9) {
                curves += 1
                if first.isEmpty { first = what }
            }
            if mine != Solve().fit(at, engine.highlight.pullBack, engine.shadow.pullBack, m.base) { copies += 1 }
        }
    }
    expect(compared >= 300 && verdicts == 0, "the app's solve takes what the engine takes and refuses what it refuses: \(compared) fits, \(verdicts) apart\(verdicts > 0 ? first : "")")
    expect(reasons == 0, "with the engine's reasons and warnings, each side's, in the engine's order: \(reasons) apart\(reasons > 0 ? first : "")")
    expect(numbers == 0, "and the engine's minimum, knee, room, landing and slope on each side: \(numbers) apart\(numbers > 0 ? first : "")")
    expect(curves == 0, "what it commits is the curve the engine's fit commits: \(curves) apart\(curves > 0 ? first : "")")
    expect(copies == 0, "these checks' own copy of the solve is the app's (\(copies) apart)")

    // The same question as the page asks it, each time the engine measures the frame on it: the
    // engine's own fit in a reply against the solve made here on that reply (`disagreement`).
    var replies = 0, apart = 0
    var sample: (reply: SceneLatitudeReply, base: SceneLatitudeSettings)?
    for fixture in all {
        for (config, engine) in fixture.fits {
            guard let m = fixture.measured[config] else { continue }
            var theirs = m.reply
            theirs.fit = engine
            replies += 1
            if rules.apart(theirs, m.base) != nil { apart += 1 }
            if sample == nil, engine.valid, engine.highlight.on, engine.shadow.on { sample = (theirs, m.base) }
        }
    }
    expect(replies >= 280 && apart == 0, "asked on the page, the solve and the engine's fit in a reply agree: \(replies) replies, \(apart) apart")
    if let sample {
        var nudged = sample.reply
        nudged.fit.shadow.knee = nudged.fit.shadow.knee.map { $0 + 1e-3 }
        expect(rules.apart(nudged, sample.base)?.contains("shadow knee") == true, "a knee a thousandth of a stop off is said, by name")
        var flipped = sample.reply
        flipped.fit.valid = false
        flipped.fit.issues = [Fit.Issue(code: "knees_cross", side: "both", message: "")]
        expect(rules.apart(flipped, sample.base)?.contains("knees_cross") == true, "and so is a verdict that differs, with the engine's reason")
        var hair = sample.reply
        hair.fit.highlight.room = hair.fit.highlight.room.map { $0 + 1e-8 }
        expect(rules.apart(hair, sample.base) == nil, "a hundred-millionth of a stop is the same curve")
    } else {
        expect(false, "the grid holds a fit the engine takes with both sides on")
    }

    // 2. The frame after the curve: the app's placed histogram is the engine's, and so is the card drawn from it.
    var histograms = 0, bins = 0, cards = 0, composed = 0
    for fixture in all {
        for (config, engine, fractions) in fixture.placed {
            guard let m = fixture.measured[config] else { continue }
            var curve = m.base
            guard curve.apply(engine) else { continue }
            histograms += 1
            let mine = rules.placed(m.reply.scene.histogram, curve)
            if mine.count != fractions.count || zip(mine, fractions).contains(where: { abs($0 - $1) > 1e-12 }) { bins += 1 }
            // The reply as the engine gave it, and as the app makes it without asking.
            var theirs = m.reply
            theirs.fit = engine
            theirs.scene.histogram.placedFractions = fractions
            var ours = m.reply
            ours.fit = rules.fit(rules.extremes(m.reply, m.base), engine.highlight.pullBack, engine.shadow.pullBack, m.base)
            ours.scene.histogram.placedFractions = mine
            let a = rules.readout(ours), b = rules.readout(theirs)
            if a.bins.count != b.bins.count || zip(a.bins, b.bins).contains(where: { abs($0 - $1) > 1e-9 })
                || !close(a.highlightPlaced?.line, b.highlightPlaced?.line, 1e-9) || !close(a.highlightPlaced?.reach, b.highlightPlaced?.reach, 1e-6)
                || !close(a.shadowPlaced?.line, b.shadowPlaced?.line, 1e-9) || !close(a.shadowPlaced?.reach, b.shadowPlaced?.reach, 1e-6) { cards += 1 }
            var asked = m.base
            (asked.highlightPullBack, asked.shadowPullBack) = (engine.highlight.pullBack, engine.shadow.pullBack)
            if m.reply.placed(asked) != ours { composed += 1 }
        }
    }
    expect(histograms >= 16 && bins == 0, "the frame's histogram after the curve is the engine's, bin for bin: \(histograms) placements, \(bins) apart")
    expect(cards == 0, "so the card drawn while a ruler moves is the card the engine's reply draws (\(cards) apart)")
    expect(composed == 0, "and the reply the app makes without asking is that fit and that histogram (\(composed) apart)")
    var refusedAsk = onBayer.base
    refusedAsk.shadowPullBack = 1
    let refusedReply = onBayer.reply.placed(refusedAsk)
    expect(!refusedReply.fit.valid && refusedReply.scene.histogram.placedFractions == nil && rules.readout(refusedReply).shadowPlaced == nil,
           "a placement that does not solve has no placed histogram and draws no mark")
    expect(onBayer.reply.placed(onBayer.base).scene.histogram.placedFractions == onBayer.reply.scene.histogram.fractions,
           "with both sides off the frame is as metered")

    // 2b. What each tab draws behind its curve (RFC-035 §3.2). The engine's replies kept in
    // `engine_replies` were taken before the per-channel rows existed, so they are the old-engine case:
    // a colour tab gets no hills, and the luminance is never drawn in its place (trap 16). The same
    // reply with rows added is the live case.
    let noRows = rules.readout(onBayer.reply)
    expect(rules.hills(noRows, .rgb) == .none && rules.hills(noRows, .red) == .none
           && rules.hills(noRows, .green) == .none && rules.hills(noRows, .blue) == .none,
           "a reading without channel rows draws no hills on a colour tab")
    expect(rules.hills(noRows, .luma) != .none, "…and still draws the luminance tab, which claims no channel")
    var rowed = noRows
    let rowCount = rowed.bins.count
    rowed.binsR = rowed.bins.map { min(1, $0 * 0.9) }
    rowed.binsG = rowed.bins.map { min(1, $0 * 0.8) }
    rowed.binsB = rowed.bins.map { min(1, $0 * 0.7) }
    if case .channel(let red) = rules.hills(rowed, .red) {
        expect(red == rowed.binsR ?? [] && rowCount == red.count, "a colour tab draws its own channel's hill")
    } else {
        expect(false, "a colour tab draws its own channel's hill")
    }
    if case .rgb(let luma, let r, let g, let b) = rules.hills(rowed, .rgb) {
        expect(r == rowed.binsR ?? [] && g == rowed.binsG ?? [] && b == rowed.binsB ?? []
               && luma.count == rowCount && !luma.isEmpty && (luma.max() ?? 0) <= 1,
               "the RGB tab draws the three channels' lines over the luminance's fill")
    } else {
        expect(false, "the RGB tab draws the three channels' lines over the luminance's fill")
    }
    // A row of the wrong length is not a row: half a histogram is not drawn as one.
    var short = rowed
    short.binsG = Array((rowed.binsG ?? []).dropLast())
    expect(short.hills(for: .green) == .none && short.hills(for: .rgb) == .none,
           "a channel row that is not the luminance's length is no row at all")
    // The demo the snapshot harness and the tour draw: it must carry rows, or every colour tab there
    // shows the no-hills state and reads as a broken engine.
    expect(LatitudeReadout.developDemo.hills(for: .rgb) != .none
           && LatitudeReadout.developDemo.hills(for: .red) != .none,
           "the demo reading carries channel rows, so no drawing can pass its luminance off as one")

    // 3. The window is the stretch the engine takes, to the hundredth.
    var sweeps = 0, split = 0, spans = 0, grid = 0, edges = 0, strays = 0, moved = 0, sided = 0
    var firstWindow = ""
    for fixture in all {
        for sweep in fixture.sweeps {
            guard let m = fixture.measured[sweep.config] else { continue }
            sweeps += 1
            let w = rules.window(sweep.side, sweep.other, rules.extremes(m.reply, m.base), m.base)
            let taken = sweep.taken
            if taken.count > 1 { split += 1 }
            let theirs = taken.first, ours = w.span.map { hundredths($0.lowerBound)...hundredths($0.upperBound) }
            let what = " — \(fixture.photo), \(sweep.side.rawValue) beside \(sweep.other): \(ours.map { "\($0)" } ?? "nothing") for the engine's \(theirs.map { "\($0)" } ?? "nothing")"
            if ours != theirs { spans += 1; if firstWindow.isEmpty { firstWindow = what } }
            if let s = w.span, s.lowerBound != Double(hundredths(s.lowerBound)) / 100 || s.upperBound != Double(hundredths(s.upperBound)) / 100 { grid += 1 }
            if let theirs {
                if theirs.lowerBound > 1, w.below.code != sweep.code(at: theirs.lowerBound - 1) { edges += 1; if firstWindow.isEmpty { firstWindow = what + ", under it \(w.below.code)" } }
                if theirs.upperBound < 800 ? w.above?.code != sweep.code(at: theirs.upperBound + 1) : w.above != nil {
                    edges += 1
                    if firstWindow.isEmpty { firstWindow = what + ", over it \(w.above?.code ?? "nothing")" }
                }
            } else if w.below.code != PlacementWindow.noWindowCode {
                edges += 1
            }
            if w.below.side != sweep.side.rawValue || (w.above.map { $0.side != sweep.side.rawValue } ?? false) { sided += 1 }
            for x in 1...800 {
                let asked = Double(x) / 100, landed = w.landing(asked).value
                if landed != 0, !sweep.takes(landed) { strays += 1 }
                if sweep.takes(asked), landed != asked { moved += 1 }
            }
        }
    }
    expect(split == 0, "what the engine takes on a side is one stretch, on every sweep")
    expect(sweeps == 15 && spans == 0, "the window the app finds is that stretch, to the hundredth: \(sweeps) sweeps, \(spans) apart\(firstWindow)")
    expect(grid == 0, "its edges are whole hundredths, as a row shows them")
    expect(edges == 0, "the reason kept for each edge is the engine's just past it (\(edges) apart\(firstWindow))")
    expect(sided == 0, "and is said of the ruler it stops, whichever side the engine names")
    expect(strays == 0, "whatever is asked of a side lands on a pull-back the engine takes, or on off (\(strays) strays)")
    expect(moved == 0, "and a pull-back the engine takes is left where it was asked (\(moved) moved)")

    // The search itself, on a Fit of known edges (the desktop's own four).
    let fake = FakeFit(1.37, 3.42)
    let known = PlacementWindow.search(side: .highlight, minimum: 0.9, in: 0...8) { fake.verdict($0) }
    expect(known.span.map { fake.verdict($0.lowerBound) == .valid && fake.verdict($0.upperBound) == .valid
                               && $0.lowerBound - 1.37 < 0.02 && 3.42 - $0.upperBound < 0.02 } == true
           && known.below.code == "room_below_minimum" && known.above?.code == "knees_cross" && known.above?.side == "highlight" && fake.asked < 40,
           "the search finds both edges to the hundredth, each with its reason, in a few dozen solves")
    expect(known.landing(0).value == 0 && known.landing(0).why == nil && known.landing(0.5).value == known.span?.lowerBound
           && known.landing(0.5).why?.code == "room_below_minimum" && known.landing(2).value == 2 && known.landing(2).why == nil
           && known.landing(7).value == known.span?.upperBound && known.landing(7).why?.code == "knees_cross",
           "a value outside the window lands on its nearer edge, with the reason; off is off")
    let open = PlacementWindow.search(side: .highlight, minimum: -1, in: 0...8) { FakeFit(0, 99).verdict($0) }
    expect(open.span?.upperBound == 8 && open.above == nil && (open.span?.lowerBound ?? 1) <= 0.011, "the top of the track is the most when the Fit takes it")
    let none = PlacementWindow.search(side: .shadow, minimum: 3.74, in: 0...8) { _ in
        .refused(.init(code: "pull_back_exceeds_max_lift", side: "shadow", message: ""))
    }
    expect(none.span == nil && none.landing(5).value == 0 && none.landing(5).why?.code == PlacementWindow.noWindowCode,
           "no window turns the side off and says so")

    // 4. A ruler offers what the engine takes, and nothing else.
    var rulers = 0, offered = 0, trips = 0, ends = 0, twentieths = 0
    for fixture in all {
        for sweep in fixture.sweeps {
            guard let m = fixture.measured[sweep.config] else { continue }
            let w = ScenePlacement.window(sweep.side, other: sweep.other, on: PlacementFit.Measured(m.reply, for: m.base), base: m.base)
            let ruler = rules.ruler(w.span, 0)
            rulers += 1
            let last = hundredths(ruler.range.upperBound) / 5
            if ruler.pullBack(at: 0) != 0 || ruler.range.lowerBound != 0 { trips += 1 }
            guard let theirs = sweep.taken.first else {
                if last != 0 || ruler.first != nil { ends += 1 }
                continue
            }
            // The least rounded up to the ruler's own twentieth and the most rounded down; the least alone where none lies between.
            var from = (theirs.lowerBound + 4) / 5 * 5, to = theirs.upperBound / 5 * 5
            if from > to { (from, to) = (theirs.lowerBound, theirs.lowerBound) }
            if ruler.first != Double(from) / 100 || ruler.last != Double(to) / 100 || last != 1 + (to - from) / 5 { ends += 1 }
            guard last >= 1 else { continue }
            var before = 0.0
            for k in 1...last {
                let position = Double(k * 5) / 100, value = ruler.pullBack(at: position)
                if !sweep.takes(value) { offered += 1 }
                if ruler.position(of: value) != position || value <= before { trips += 1 }
                if from != to, hundredths(value) % 5 != 0 { twentieths += 1 }
                before = value
            }
        }
    }
    expect(rulers == 15 && offered == 0, "every stop a ruler offers is a pull-back the engine takes (\(offered) it refuses)")
    expect(ends == 0, "its first stop is off, the next the least the Fit takes on the ruler's twentieths, its last the most (\(ends) apart)")
    expect(trips == 0 && twentieths == 0, "a stop stands for one pull-back, a twentieth of a stop, and a pull-back for one stop")
    let empty = rules.ruler(nil, 0), kept = rules.ruler(nil, 1.2), strayed = rules.ruler(2.31...8, 1.0)
    expect(empty.range == 0...0 && empty.position(of: 0) == 0 && empty.pullBack(at: 0) == 0, "a side the Fit takes nothing of has a ruler with nothing on it")
    expect(kept.range == 0...PlacementRuler.step && kept.position(of: 1.2) == PlacementRuler.step && kept.pullBack(at: PlacementRuler.step) == 1.2
           && kept.pullBack(at: 0) == 0, "a side that is on where the Fit takes nothing keeps its pull-back, and can be turned off")
    expect(strayed.position(of: 1.0) == PlacementRuler.step && strayed.pullBack(at: 2 * PlacementRuler.step) == 2.4 && strayed.pullBack(at: 0) == 0,
           "a pull-back solved on another film sits at the ruler's nearer end, and a step from there is on the ruler")
    let plain = PlacementRuler.plain(over: ScenePlacement.range, holding: 1.5)
    expect(plain.range == 0...8 && plain.position(of: 1.5) == 1.5 && plain.pullBack(at: 0.05) == 0.05 && plain.pullBack(at: 8) == 8,
           "a frame nothing measures has rulers that are numbers, over the whole track")

    // 5. A step of a ruler, on the ProRAW frame: both sides have something, and something together.
    let reply = onProraw.reply, base = onProraw.base
    let at = PlacementFit.Measured(reply, for: base)
    guard let top = ScenePlacement.window(.highlight, other: 0, on: at, base: base).span,
          let bottom = ScenePlacement.window(.shadow, other: 0, on: at, base: base).span,
          let beside = proraw.sweeps.first(where: { $0.side == .highlight && $0.other > 0 }), let together = beside.taken.first else {
        expect(false, "the ProRAW frame takes pull-backs on both sides, and on the two together")
        return
    }
    let landed = rules.place(0.05, .highlight, base, reply)
    expect(landed?.highlightPullBack == top.lowerBound && landed?.active == true && (landed?.highlightRoom ?? 0) >= PlacementFit.minRoom
           && landed?.shadowPullBack == 0 && landed?.shadowRoom == 0,
           "a step into the stretch the Fit refuses lands on the least it takes, solved and committed at once (\(landed?.highlightPullBack ?? -1) for \(top.lowerBound))")
    expect(rules.place(3, .highlight, base, reply)?.highlightPullBack == 3, "a pull-back the Fit takes is committed as asked")
    let five = rules.place(5, .shadow, base, reply)
    expect(five?.shadowPullBack == bottom.upperBound, "one past the most lands on the most")
    expect(five.flatMap { rules.place(0.5, .shadow, $0, reply) }?.shadowPullBack == 0.5, "5 and then 0.5 does not leave 5")
    let off = landed.flatMap { rules.place(0, .highlight, $0, reply) }
    expect(off?.highlightPullBack == 0 && off?.highlightRoom == 0 && off?.active == false, "0 is off: the curve goes")
    let lifted = rules.place(beside.other, .shadow, base, reply)
    let crossed = lifted.flatMap { rules.place(8, .highlight, $0, reply) }
    expect(crossed?.highlightPullBack == Double(together.upperBound) / 100 && crossed?.shadowPullBack == beside.other
           && (crossed.map { $0.shadowKnee < $0.highlightKnee } ?? false),
           "beside the other side a ruler stops where the two curves would cross (\(crossed?.highlightPullBack ?? -1) for \(Double(together.upperBound) / 100))")
    // A drag: out through the refused stretch, across the window, past its top, and back.
    let out = Array(stride(from: 0.2, through: 9, by: 0.2))
    var dragged = base, held = true, steps = 0
    let started = Date()
    for v in out + out.reversed() {
        guard let next = rules.place(v, .highlight, dragged, reply) else { held = false; break }
        dragged = next
        steps += 1
        if abs(dragged.highlightPullBack - min(max(v, top.lowerBound), top.upperBound)) > 1e-9 || !dragged.active { held = false }
    }
    let perStep = Date().timeIntervalSince(started) / Double(max(steps, 1))
    expect(held && steps == 2 * out.count, "each step of a drag is committed where it lands, out and back")
    expect(perStep < 0.004, String(format: "a step is arithmetic: %.3f ms each over %d steps", perStep * 1000, steps))
    if !quiet { print(String(format: "  a ruler's step, solved and committed: %.3f ms (this Mac)", perStep * 1000)) }
    // A side solved on another film: here a shadow pull-back under the least this frame takes.
    var stale = base
    (stale.shadowPullBack, stale.shadowKnee, stale.shadowRoom, stale.active) = (0.05, -3, 1, true)
    expect(rules.place(3, .highlight, stale, reply) == nil, "beside a side that no longer fits, nothing is committed")
    var both = stale
    (both.highlightPullBack, both.highlightKnee, both.highlightRoom) = (3, 1, 1.2)
    let dropped = rules.place(0, .highlight, both, reply)
    expect(dropped?.highlightRoom == 0 && dropped?.shadowKnee == -3 && dropped?.shadowRoom == 1 && dropped?.shadowPullBack == 0.05 && dropped?.active == true,
           "turning one side off is not a Fit: the other side's curve stays as it is")
    let again = rules.place(0.05, .shadow, stale, reply)
    expect(again?.shadowPullBack == bottom.lowerBound && again?.shadowRoom != 1, "and the side that no longer fits lands on what the Fit takes when it moves")
    expect(rules.place(1, .shadow, onBayer.base, onBayer.reply) == nil, "a step on a side the Fit takes nothing of commits nothing")

    // 6. What the panel shows, and says.
    var said: [PlacementNote] = []
    func panel(_ settings: SceneLatitudeSettings, _ reply: SceneLatitudeReply, _ moved: PlacementSide? = nil) -> PlacementPanel {
        let p = rules.panel(settings, reply, moved)
        if let note = p.note { said.append(note) }
        return p
    }
    // The Bayer frame: the darkest thousandth is 4.01 stops under, the shadows lift 4 at most.
    let closed = panel(onBayer.base, onBayer.reply)
    expect(!closed.shadow.enabled && closed.shadow.ruler.range == 0...0, "a side the Fit takes nothing of is dimmed, its ruler empty")
    expect(closed.highlight.enabled && closed.highlight.ruler.first == 4.65 && closed.highlight.ruler.last == 8,
           "the other ruler starts at the least the Fit takes: \(closed.highlight.ruler.first ?? -1)")
    expect(closed.note == PlacementNote(text: "Shadow: the darkest part is too far under to lift inside.", refused: false),
           "and the line says why without the ruler being touched: \(closed.note?.text ?? "nil")")
    let firstStop = ScenePlacement.place(closed.highlight.ruler.pullBack(at: PlacementRuler.step), moving: .highlight, in: onBayer.base, on: onBayer.reply)
    let started2 = firstStop.map { panel($0, onBayer.reply, .highlight) }
    expect(firstStop?.highlightPullBack == 4.65 && started2?.note == PlacementNote(text: "Highlight starts at 4.65: less leaves the brightest part out.", refused: true),
           "the ruler's first step is the least, and the line says why it starts there: \(started2?.note?.text ?? "nil")")
    expect(firstStop.map { panel($0, onBayer.reply, .shadow) }?.note?.text.hasPrefix("Highlight starts") == false,
           "a ruler's end is explained when that ruler moved, not the other")
    // The ProRAW frame: its darkest part is inside already, its brightest 2.30 stops out.
    let rest = panel(base, reply)
    expect(rest.note == nil && rest.highlight.enabled && rest.shadow.enabled && rest.shadow.ruler.first == 0.15 && rest.shadow.ruler.last == 3.45,
           "a frame both rulers work on has nothing to say at rest")
    let low = ScenePlacement.place(0.15, moving: .shadow, in: base, on: reply), high = ScenePlacement.place(3.45, moving: .shadow, in: base, on: reply)
    expect(low.map { panel($0, reply, .shadow) }?.note == PlacementNote(text: "Shadow starts at 0.15: less turns too sharply at the edge.", refused: true),
           "where the scene's end is inside already, the least is the curve's own room")
    let reach = high.map { panel($0, reply, .shadow) }?.note
    expect(reach == PlacementNote(text: "Shadow ends at 3.45: more is further than the curve reaches.", refused: true), "a ruler's last stop says why: \(reach?.text ?? "nil")")
    let middle = ScenePlacement.place(1, moving: .shadow, in: base, on: reply)
    expect(middle.map { panel($0, reply, .shadow) }?.note == nil, "between its ends a ruler has nothing to explain")
    let crossing = lifted.flatMap { ScenePlacement.place(8, moving: .highlight, in: $0, on: reply) }.map { panel($0, reply, .highlight) }
    expect(crossing?.note == PlacementNote(text: String(format: "Highlight ends at %.2f: more would cross the Shadow's curve.", Double(together.upperBound / 5 * 5) / 100), refused: true)
           || crossing?.note?.text.contains("would cross the Shadow's curve") == true,
           "beside the other side, the end is where the curves would cross: \(crossing?.note?.text ?? "nil")")
    var bound = base
    bound.maxLift = 0.5
    let capped = ScenePlacement.place(8, moving: .shadow, in: bound, on: reply).map { panel($0, reply, .shadow) }
    expect(capped?.note?.text.hasSuffix("the most the shadows can be lifted.") == true && capped?.note?.refused == true,
           "at the lift bound, the end is the most the shadows lift: \(capped?.note?.text ?? "nil")")
    // Far enough in, the knee passes the subject: legal, and said quietly.
    let deep = ScenePlacement.place(3, moving: .highlight, in: base, on: reply)
    expect(deep.map { panel($0, reply, .highlight) }?.note == .flat && deep.map { panel($0, reply) }?.note == .flat,
           "a placement that reaches the mid-tones says so, and is not a refusal")
    // One side far enough that nothing fits beside it: the other ruler is dimmed by that move, and
    // the line says so — at rest, and while the ruler that did it is still the one under the finger,
    // where it comes before what the placement costs.
    let far = ScenePlacement.place(2.5, moving: .shadow, in: base, on: reply)
    let crowded = PlacementNote(text: "Highlight: nothing fits beside this much Shadow.", refused: false)
    expect(far.map { panel($0, reply) }?.highlight.enabled == false && far.map { panel($0, reply) }?.note == crowded,
           "a ruler with nothing beside the other side says which is in its way: \(far.map { panel($0, reply) }?.note?.text ?? "nil")")
    expect(far.map { panel($0, reply, .shadow) }?.note == crowded,
           "and says it while the ruler that dimmed it is the one moving, before what the placement costs")
    let deeper = ScenePlacement.place(6, moving: .highlight, in: base, on: reply)
    expect(deeper.map { panel($0, reply) }?.note == PlacementNote(text: "Shadow: nothing fits beside this much Highlight.", refused: false)
           && deeper.map { panel($0, reply, .highlight) }?.note == PlacementNote(text: "Shadow: nothing fits beside this much Highlight.", refused: false),
           "the same of the Shadow")
    // A side this frame takes nothing of was said before anything moved: once a ruler has, what its
    // placement costs comes first.
    let pulled = ScenePlacement.place(6, moving: .highlight, in: onBayer.base, on: onBayer.reply)
    expect(pulled.map { panel($0, onBayer.reply, .highlight) }?.note == .flat && pulled.map { panel($0, onBayer.reply) }?.note == closed.note,
           "beside a ruler the frame leaves empty, the one under the finger is told what its placement costs")
    // A frame whose brightest part is out of reach too.
    var blown = onBayer.reply
    blown.scene.p99_9 = blown.medium.highlightEV + 9
    let neither = panel(onBayer.base, blown)
    expect(!neither.highlight.enabled && !neither.shadow.enabled && neither.note == PlacementNote(text: "Neither end can be brought inside: both are too far outside.", refused: false),
           "with nothing on either ruler, one line for both: \(neither.note?.text ?? "nil")")
    var bright = onProraw.reply
    bright.scene.p99_9 = bright.medium.highlightEV + 9
    expect(panel(base, bright).note == PlacementNote(text: "Highlight: the brightest part is too far over to pull inside.", refused: false),
           "the highlight's own line where its ruler is the empty one")
    // A placement solved on another film or paper.
    let old = panel(stale, reply)
    expect(old.note == .stale && old.shadow.enabled && old.shadow.ruler.position(of: stale.shadowPullBack) == PlacementRuler.step,
           "a placement that no longer fits says so, and its ruler still moves")
    expect(said.count >= 12 && said.allSatisfy { $0.text.count <= PlacementNote.longestLine },
           "every line fits the panel's one row: the longest is \(said.map(\.text.count).max() ?? 0) characters of \(PlacementNote.longestLine)")
    expect(said.allSatisfy { !$0.text.contains("medium") && !$0.text.contains("_") && !$0.text.lowercased().contains("kodak") },
           "in the page's own words: no engine's code, no profile's name")
    // The HEIF the host shot: its shadows have a window, 2.68 stops in.
    let phone = panel(onHeif.base, onHeif.reply)
    expect(phone.shadow.enabled && phone.shadow.ruler.first == 2.7 && phone.shadow.ruler.pullBack(at: PlacementRuler.step) == 2.7,
           "on the phone's own HEIF the Shadow ruler's first step is 2.70, not two and a half stops of nothing")
    // Before a frame is measured, and where nothing measures it.
    let waiting = PlacementPanel.waiting(base), drawn = PlacementPanel.numbers(stale)
    expect(!waiting.highlight.enabled && !waiting.shadow.enabled && waiting.note == nil, "an unmeasured frame's rulers wait")
    expect(drawn.highlight.enabled && drawn.shadow.ruler.position(of: 0.05) == 0.05 && drawn.shadow.ruler.range == ScenePlacement.range && drawn.note == nil,
           "the drawings' own frames keep rulers that are numbers")
    var settings = SceneLatitudeSettings()
    (settings.highlightPullBack, settings.shadowPullBack, settings.active, settings.highlightRoom, settings.rolloff, settings.shadowPercentile) = (2, 1, true, 3, 3, 1)
    let bare = settings.withoutPlacement
    expect(bare.highlightPullBack == 0 && bare.shadowPullBack == 0 && !bare.active && bare.highlightRoom == 0 && bare.rolloff == 3 && bare.shadowPercentile == 1,
           "a frame without its placement keeps what a measurement is asked with")
}

func fixture(_ name: String) -> SceneLatitudeReply? {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("engine_replies/scene_latitude_\(name).json")
    return (try? String(contentsOf: url, encoding: .utf8)).flatMap(SceneLatitudeReply.decode)
}

/// A reply with a histogram of its own: shares by bin index, 128 quarter stops across −16…+16.
func reply(_ shares: [Int: Double], placed: [Int: Double]? = nil, from base: SceneLatitudeReply) -> SceneLatitudeReply {
    var r = base
    func bins(_ d: [Int: Double]) -> [Double] { (0..<128).map { d[$0] ?? 0 } }
    r.scene.histogram.fractions = bins(shares)
    r.scene.histogram.placedFractions = placed.map(bins)
    return r
}

func run(_ rules: Rules, quiet: Bool) -> (passed: Int, failed: [String]) {
    var passed = 0
    var failed: [String] = []
    func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if !quiet { print("  FAILED  \(what)") } }
    }
    func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= eps } ?? false }

    guard let metered = fixture("reply"), let placed = fixture("placed"), let refused = fixture("refused") else {
        return (0, ["the engine's replies in tools/engine_replies did not decode"])
    }

    // The engine's reply, as it came.
    expect(metered.scene.histogram.fractions.count == 128 && metered.scene.histogram.loEV == -16 && metered.scene.histogram.hiEV == 16,
           "the histogram is 128 quarter stops across -16...+16")
    expect(near(metered.medium.latitudeStops, metered.medium.highlightEV - metered.medium.shadowEV, 1e-9), "the stops held are the window's width")
    expect(metered.fit.valid && metered.fit.paramsDelta?.active == false && !metered.fit.highlight.on && metered.fit.highlight.knee == nil,
           "with both pull-backs at 0 the fit is valid, off, and has no knee")
    expect(metered.scene.histogram.placedFractions == metered.scene.histogram.fractions, "with both sides off the placed histogram is the metered one")
    expect(placed.fit.valid && placed.fit.highlight.on && placed.fit.highlight.knee != nil && placed.fit.paramsDelta?.active == true,
           "a placement the engine accepts carries its knee and its delta")
    expect(placed.fit.warnings.first?.code == "knee_past_midgrey", "a warning is read, and is not a refusal")
    expect(!refused.fit.valid && refused.fit.paramsDelta == nil && refused.scene.histogram.placedFractions == nil
           && refused.fit.issues.first?.code == "pull_back_below_minimum" && refused.fit.issues.first?.side == "highlight",
           "a refused fit has its reason, no delta and no placed histogram")

    // The card's reading of it.
    let r = rules.readout(metered)
    expect(r.loEV == -8 && r.hiEV == 8, "the axis is -8...+8, whatever the frame")
    expect(r.bins.count == 66 && near(r.binsFromEV, -8.125) && near(r.binsToEV, 8.125),
           "the 64 bins on the axis and one beyond each end: 66 samples from -8.125 to +8.125")
    expect(r.shadowEV == metered.medium.shadowEV && r.highlightEV == metered.medium.highlightEV, "the window is the medium's two boundaries")
    expect(r.highlightPlaced == nil && r.shadowPlaced == nil, "no mark with Scene Placement off")
    expect(r.heldText == "7.3 stops held", "the card's line: \(r.heldText)")
    let tallest = metered.scene.histogram.fractions.enumerated().max { $0.element < $1.element }!.offset
    let centreOfTallest = -16 + (Double(tallest) + 0.5) * 0.25
    expect(r.bins.max() == 1 && near(r.bins.firstIndex(of: 1).map(r.binEV), centreOfTallest),
           "the tallest bin is 1, and sits at its own centre (\(centreOfTallest))")
    expect(r == reading(metered), "these checks' own copy of the mapping is the app's")

    // One spike, half a stop over mid-grey: bin 66 covers +0.5...+0.75.
    let spike = rules.readout(reply([66: 0.5], from: metered))
    expect(near(spike.bins.firstIndex(of: 1).map(spike.binEV), 0.625), "a bin is drawn at its centre, not at its edge")
    // 16 % of the frame and 1 %: the square root makes them 1 and 0.25.
    let two = rules.readout(reply([60: 0.16, 70: 0.01], from: metered))
    expect(near(two.bins[60 - 31], 1) && near(two.bins[70 - 31], 0.25), "heights are the square root of the share, over the tallest")
    // Most of the frame is 13 stops under mid-grey, off the axis: what is on it still fills the plot.
    let dark = rules.readout(reply([10: 0.9, 64: 0.01], from: metered))
    expect(near(dark.bins[64 - 31], 1), "a spike off the axis does not flatten what is on it")
    // The bins just past the axis's ends are kept, and never taller than the plot.
    let ends = rules.readout(reply([31: 0.04, 64: 0.01, 96: 0.0025], from: metered))
    expect(ends.bins.count == 66 && near(ends.bins.first, 1) && near(ends.bins.last, 0.5),
           "one bin beyond each end of the axis is drawn, held to the plot's height")
    // Placed: the top of the scene moved from +4.125 to +2.125.
    let moved = rules.readout(reply([64: 0.1, 80: 0.4], placed: [64: 0.1, 72: 0.4], from: placed))
    expect(near(moved.bins.firstIndex(of: 1).map(moved.binEV), 2.125), "the histogram is the frame after Scene Placement, where there is one")

    // Scene Placement's mark: of a valid fit, on the side that is on — from where that end of
    // the scene was to where it lands, which is as many stops as it was pulled back.
    let p = rules.readout(placed)
    expect(near(p.highlightPlaced?.line, placed.fit.highlight.sceneExtremeEV) && near(p.highlightPlaced?.reach, placed.fit.highlight.landingEV)
           && p.shadowPlaced == nil, "the highlight's mark of an accepted placement runs from the scene's own end to where it lands; none on the side that is off")
    expect(p.highlightPlaced.map { abs(($0.line - $0.reach) - placed.fit.highlight.pullBack) < 1e-3 } ?? false,
           "and it is as wide as the ruler says: \(p.highlightPlaced.map { $0.line - $0.reach } ?? .nan) stops for a pull-back of \(placed.fit.highlight.pullBack)")
    expect(p.highlightPlaced.map { $0.reach < placed.medium.highlightEV && $0.line > placed.medium.highlightEV } ?? false,
           "from outside what the film and paper hold to inside it")
    expect(p.highlightPlaced?.line != placed.fit.highlight.knee, "not at the curve's knee, which is no place in the picture")
    var claimed = refused
    claimed.fit.highlight.on = true
    claimed.fit.highlight.knee = 1
    expect(rules.readout(claimed).highlightPlaced == nil, "a refused fit draws no mark")
    expect(rules.readout(refused).bins == rules.readout(metered).bins, "a refused fit draws the frame as metered")

    // Committing a fit.
    var s = SceneLatitudeSettings()
    expect(rules.apply(&s, placed.fit) && s.active && s.highlightPullBack == 1.5 && s.shadowPullBack == 0
           && near(s.highlightKnee, placed.fit.highlight.knee ?? .nan) && near(s.highlightRoom, placed.fit.highlight.room ?? .nan)
           && s.shadowRoom == 0, "an accepted fit becomes the frame's curve, with the pull-backs it was solved for")
    let before = s
    expect(!rules.apply(&s, refused.fit) && s == before, "a refused fit changes nothing")
    var off = s
    expect(rules.apply(&off, metered.fit) && !off.active && off.highlightPullBack == 0 && off.highlightRoom == 0, "both sides off is a fit too: the curve goes")
    let wire = Dictionary(uniqueKeysWithValues: FilmParams.default.wire.map { ($0.name, $0.value) })
    expect(wire["scene_latitude_active"] == .bool(false) && wire["scene_latitude_highlight_pull_back"] == nil,
           "the pull-backs are not wire fields; the curve is")

    // The request.
    expect(rules.json(SceneLatitudeRequest(highlightPullBack: 1.5)) == #"{"highlight_pull_back":1.5}"#, "a request says only what is set")
    expect(rules.json(SceneLatitudeRequest()) == "{}", "an empty request asks for the engine's suggestion")
    let asked = rules.json(SceneLatitudeSettings().request)
    expect(asked.contains(#""highlight_pull_back":0"#) && asked.contains(#""shadow_percentile":0.1"#) && asked.contains(#""highlight_percentile":99.9"#)
           && asked.contains(#""norm":"power""#) && !asked.contains("margin") && !asked.contains("null"),
           "a frame's own request: its pull-backs, its percentiles, its curve's settings — \(asked)")

    // The labels: outside the window, unless there is no room there.
    expect(rules.shadowLabel(100) == 85 && rules.highlightLabel(250, 346) == 265, "a boundary's label sits 15 pt outside its line")
    expect(rules.shadowLabel(5) == 20 && rules.highlightLabel(343, 346) == 328, "a boundary at the plot's end is named inside it")
    expect(rules.shadowLabel(-40) == 15 && rules.highlightLabel(400, 346) == 331, "a boundary past the axis is named at the plot's end")

    // What the panel says of a placement: its own words, with the number the ruler needs.
    expect(rules.note(metered.fit) == nil, "nothing to say of a frame with no placement")
    let cost = rules.note(placed.fit)
    expect(cost?.refused == false && cost?.text.contains("mid-tones") == true, "an accepted placement that reaches the subject says so, and is not a refusal")
    let why = rules.note(refused.fit)
    expect(why?.refused == true && why?.text == "Highlight: more than 0.70 stops brings the brightest part inside.",
           "a pull-back under the minimum names the minimum: \(why?.text ?? "nil")")
    func refusal(_ code: String, _ side: String, minimum: Double = 1.25) -> SceneLatitudeReply.Fit {
        var fit = refused.fit
        fit.issues = [.init(code: code, side: side, message: "the \(side) pull-back and the medium's boundary, kodak_portra_400")]
        fit.highlight.minimumPullBack = minimum
        fit.shadow.minimumPullBack = minimum
        return fit
    }
    expect(rules.note(refusal("pull_back_below_minimum", "shadow"))?.text == "Shadow: more than 1.25 stops brings the darkest part inside.",
           "the shadow side's refusal is the shadow's")
    expect(rules.note(refusal("pull_back_below_minimum", "highlight", minimum: -0.2))?.text == "Highlight: a little more brings the brightest part inside.",
           "a refusal with no minimum to name names none")
    var lines = Set<String>()
    for (code, side) in [("pull_back_below_minimum", "highlight"), ("room_below_minimum", "highlight"), ("room_below_minimum", "shadow"),
                         ("pull_back_exceeds_max_lift", "shadow"), ("knees_cross", "both"), ("out_of_range", "highlight"), ("a code from a later engine", "both")] {
        let n = rules.note(refusal(code, side))
        lines.insert(n?.text ?? "")
        expect(n?.refused == true && !(n?.text ?? "").isEmpty && !(n?.text ?? "medium").contains("medium") && !(n?.text ?? "kodak").contains("kodak"),
               "\(code) on \(side): refused, in the panel's own words — \(n?.text ?? "nil")")
    }
    expect(lines.count == 6, "each refusal the engine can make has its own line, and an unknown one a plain line (\(lines.count) lines)")

    // What the card says without a reading.
    expect(LatitudeReading.waiting.note == "Measuring" && LatitudeReading.measured(r).note == nil, "the card's line while it waits")
    for sentence in ["scene latitude: the medium's boundaries do not lie inside the probe's range",
                     "scene latitude: the frame has no positive pixels", "anything else the engine says about kodak_portra_400"] {
        let note = LatitudeReading.refusal(sentence).note ?? ""
        expect(!note.isEmpty && !note.contains("medium") && !note.contains("kodak") && !note.contains("_"),
               "the engine's sentence never reaches the card: \(note)")
    }

    // Scene Placement, solved in the app, against the engine's own fits of real frames.
    placementChecks(rules, quiet: quiet, expect: expect)
    return (passed, failed)
}

@main
enum LatitudeSelfTest {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for broken in Rules.broken {
                let r = run(broken, quiet: true)
                if r.failed.isEmpty {
                    print("  NOT CAUGHT  \(broken.name)")
                } else {
                    caught += 1
                    print("  caught  \(broken.name) (\(r.failed.count) checks failed)")
                }
            }
            print("latitude checks' own check: \(caught) of \(Rules.broken.count) broken rules caught")
            exit(caught == Rules.broken.count ? 0 : 1)
        }
        let r = run(Rules(), quiet: false)
        print("latitude checks: \(r.passed) passed, \(r.failed.count) failed")
        exit(r.failed.isEmpty ? 0 : 1)
    }
}
