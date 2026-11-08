//  ScenePlacement.swift — Scene Placement, solved in the app.
//
//  The engine's Fit (`spk_scene_latitude`, RFC-023 §9) turns two pull-backs into
//  the curve it renders, or refuses them. **It takes a window of pull-backs on
//  each side, not everything above zero**: under the least the scene's end still
//  lands outside what the film and paper hold, or the curve has no room to turn;
//  over the most the shadows cannot be lifted further, the curve leaves its
//  range, or the two sides' curves would cross. On many of the frames a host
//  shoots the shadow side has no window at all: the darkest thousandth of a
//  Bayer RAW or a HEIF sits further under the window than the shadows can be
//  lifted (measured on ten real frames, 2026-10-07: six with none).
//
//  Until then each step of a ruler asked the engine for its Fit, the ruler
//  offered every value, and a refusal left it where the finger put it with
//  nothing committed. That is the desktop's failure of 1.3.1, which its `main`
//  mended in three commits (`unpublished-revision`, `unpublished-revision`, `unpublished-revision`, all the
//  maintainer's, `Model/Latitude.swift` there), and this file is that fix on the
//  host:
//
//  - **`PlacementFit` is the engine's Fit, here.** The call queues behind
//    whatever develop is running — the one the step before it started — so a
//    step's answer came a render late (seen in the simulator: 0.5 ms a Fit, and
//    424 ms for the one behind a develop). The solve is arithmetic on four
//    numbers the last measurement already carries, so a step is solved at once,
//    and the Latitude card follows the finger. **The engine's is the reference**:
//    this is `engine/src/core/latitude_fit.cpp`, expression for expression, and
//    `tools/latitude_selftest.swift` holds it to the engine's verdicts, reasons,
//    knees, rooms and placed histograms on real frames (`tools/engine_replies`).
//    Change one, change both.
//  - **`PlacementWindow` is what the Fit takes on a side**, found by asking the
//    solve (the desktop's search), to the hundredth.
//  - **A ruler offers what the Fit takes, and nothing else** (`PlacementRuler`).
//    The desktop draws its window as a band on a track and lands a value
//    dragged outside it on the band's nearer edge. A host's ruler is a scale
//    under a fixed mark, moved by how far the finger travels, so the stretch the
//    Fit refuses is simply not on it: its first stop is off, the next is the
//    least the Fit takes, its last the most. A side the Fit takes nothing of has
//    a ruler with nothing on it, dimmed, and the line under the rulers says why
//    without being touched.
//
//  A pasted placement, and one kept by a build with no engine, are still solved
//  by the engine itself when their frame's page opens (`OpenFrameSession`).
//
//  Nothing here touches the engine or a view.

import Foundation

/// One end of the scene.
enum PlacementSide: String, CaseIterable, Sendable {
    case highlight, shadow

    var other: PlacementSide { self == .highlight ? .shadow : .highlight }
    /// As the page names its ruler.
    var name: String { self == .highlight ? "Highlight" : "Shadow" }
}

extension SceneLatitudeSettings {
    /// A side's pull-back.
    subscript(side: PlacementSide) -> Double {
        get { side == .highlight ? highlightPullBack : shadowPullBack }
        set { if side == .highlight { highlightPullBack = newValue } else { shadowPullBack = newValue } }
    }

    /// These settings with the placement taken out — pull-backs and curve — and
    /// everything a measurement is asked with kept.
    var withoutPlacement: SceneLatitudeSettings {
        var s = SceneLatitudeSettings()
        s.norm = norm
        s.rolloff = rolloff
        s.maxLift = maxLift
        s.shadowPercentile = shadowPercentile
        s.highlightPercentile = highlightPercentile
        return s
    }
}

// MARK: - the Fit

/// The engine's Fit (RFC-023 §9.2, §9.3, §15.5): `latitude_fit.cpp`, in Swift.
/// Every function here has the engine's name and the engine's order of
/// operations, so the two can be read side by side.
enum PlacementFit {
    typealias Fit = SceneLatitudeReply.Fit
    typealias Issue = SceneLatitudeReply.Fit.Issue

    /// `kMinRoom`: the least room a side's curve may turn in, in stops.
    static let minRoom = 0.5
    /// `kDomainStops`: the curve's domain, and the wire's range for a knee and a room.
    static let domainStops = 24.0

    /// What a solve reads off a measurement: each side's robust extreme of the
    /// scene and the boundary the film and paper hold to, in stops about the
    /// metered mid-grey. Neither moves with the placement: the engine probes
    /// the medium with the curve off and reads the scene before it.
    struct Measured: Equatable, Sendable {
        var highlightExtreme: Double
        var highlightBoundary: Double
        var shadowExtreme: Double
        var shadowBoundary: Double

        init(highlightExtreme: Double, highlightBoundary: Double, shadowExtreme: Double, shadowBoundary: Double) {
            self.highlightExtreme = highlightExtreme
            self.highlightBoundary = highlightBoundary
            self.shadowExtreme = shadowExtreme
            self.shadowBoundary = shadowBoundary
        }

        /// From any reply of the frame's, with the engine's own choice of
        /// extreme (`Extremes`): P99.9 or P99 at the top, P0.1 or P1 at the bottom.
        init(_ reply: SceneLatitudeReply, for settings: SceneLatitudeSettings) {
            self.init(highlightExtreme: settings.highlightPercentile == 99 ? reply.scene.p99 : reply.scene.p99_9,
                      highlightBoundary: reply.medium.highlightEV,
                      shadowExtreme: settings.shadowPercentile == 1 ? reply.scene.p1 : reply.scene.p0_1,
                      shadowBoundary: reply.medium.shadowEV)
        }

        /// At or under this a side's extreme still lands past its boundary.
        func minimum(_ side: PlacementSide) -> Double {
            side == .highlight ? highlightExtreme - highlightBoundary : shadowBoundary - shadowExtreme
        }
    }

    /// `g_m(D) - D`: a branch's departure from the identity, in the forms that
    /// do not cancel near the knee. Negative for every D > 0.
    static func departure(_ D: Double, _ H: Double, _ m: Double) -> Double {
        guard D > 0 else { return 0 }
        if m == 2 {
            let r = (H * H + D * D).squareRoot()
            return -(D * D * D) / (r * (H + r))
        }
        if m == 1 { return -(D * D) / (H + D) }
        return D * (H / pow(pow(H, m) + pow(D, m), 1 / m) - 1)
    }

    /// The lift bound: the same smooth-min at m = 2.
    static func boundLift(_ d: Double, _ L: Double) -> Double {
        d > 0 ? d * L / (L * L + d * d).squareRoot() : d
    }

    /// `f(E) - E` in stops, under a curve — the knees, rooms, roll-off and lift
    /// bound of `p`. Exactly 0 in the core and on a side that is off.
    static func delta(_ E: Double, _ p: SceneLatitudeSettings) -> Double {
        let Ep = min(max(E, -domainStops), domainStops)
        var d = 0.0
        if p.highlightRoom > 0, Ep > p.highlightKnee {
            d = departure(Ep - p.highlightKnee, p.highlightRoom, p.rolloff)
        } else if p.shadowRoom > 0, Ep < p.shadowKnee {
            d = -departure(p.shadowKnee - Ep, p.shadowRoom, p.rolloff)
        }
        return boundLift(d, p.maxLift)
    }

    static func mapped(_ E: Double, _ p: SceneLatitudeSettings) -> Double { E + delta(E, p) }

    /// The curve's slope, by central difference: a readout.
    static func slope(_ E: Double, _ p: SceneLatitudeSettings) -> Double {
        let h = 1e-4
        return (mapped(E + h, p) - mapped(E - h, p)) / (2 * h)
    }

    /// The knee that lands the extreme `a` at `a - N` under the boundary `C`, in
    /// the highlight's orientation; the shadow side is the same call on negated
    /// arguments. Nil when that landing is not strictly inside `C`.
    static func solveKnee(_ a: Double, _ C: Double, _ N: Double, _ m: Double) -> Double? {
        let t = a - N
        guard N > 0, t < C else { return nil }
        func landing(_ K: Double) -> Double { K + ((a - K) + departure(a - K, C - K, m)) }
        let seed = t - max(0, (a - t) * (C - t)).squareRoot()
        var lo = seed - 64, hi = t
        guard landing(lo) < t else { return nil }
        var i = 0
        while i < 200, hi - lo > 1e-12 {
            let mid = 0.5 * (lo + hi)
            if landing(mid) > t { hi = mid } else { lo = mid }
            i += 1
        }
        return 0.5 * (lo + hi)
    }

    /// The two pull-backs solved against a measurement: the fit the engine
    /// would reply with — its verdict, every reason in the engine's order, each
    /// side's knee and room, where the extremes land, and the curve to commit —
    /// except the engine's sentences, which are for a log and never for a page.
    /// A pull-back of 0 or less turns its side off. `base` carries the roll-off
    /// and the lift bound, and the knee of a side that stays off.
    static func fit(_ at: Measured, highlight: Double, shadow: Double, base: SceneLatitudeSettings) -> Fit {
        func issue(_ code: String, _ side: String) -> Issue { Issue(code: code, side: side, message: "") }
        let m = base.rolloff
        var issues: [Issue] = [], warnings: [Issue] = []
        var curve = base
        curve.active = true
        curve.highlightRoom = 0
        curve.shadowRoom = 0

        var top = Fit.Side(on: false, pullBack: highlight, minimumPullBack: at.highlightExtreme - at.highlightBoundary,
                           sceneExtremeEV: at.highlightExtreme, mediumBoundaryEV: at.highlightBoundary,
                           knee: nil, room: nil, landingEV: 0, slopeAtExtreme: 0)
        if highlight > 0 {
            if let K = solveKnee(at.highlightExtreme, at.highlightBoundary, highlight, m) {
                top.on = true
                top.knee = K
                top.room = at.highlightBoundary - K
            } else {
                issues.append(issue("pull_back_below_minimum", "highlight"))
            }
        }

        var bottom = Fit.Side(on: false, pullBack: shadow, minimumPullBack: at.shadowBoundary - at.shadowExtreme,
                              sceneExtremeEV: at.shadowExtreme, mediumBoundaryEV: at.shadowBoundary,
                              knee: nil, room: nil, landingEV: 0, slopeAtExtreme: 0)
        // The lift is bounded after the curve, so the landing asked for is the
        // bounded one: the bound is inverted first, and the curve solved for
        // the lift the bound then brings back to it. The minimum is checked
        // here, on the bounded landing: the solve sees only the inverted lift.
        var lift: Double?
        if shadow > 0, !(shadow > bottom.minimumPullBack) {
            issues.append(issue("pull_back_below_minimum", "shadow"))
        } else if shadow > 0 {
            let L = base.maxLift
            if shadow < L {
                lift = shadow * L / (L * L - shadow * shadow).squareRoot()
            } else {
                issues.append(issue("pull_back_exceeds_max_lift", "shadow"))
            }
        }
        if let lift {
            if let K = solveKnee(-at.shadowExtreme, -at.shadowBoundary, lift, m) {
                bottom.on = true
                bottom.knee = -K
                bottom.room = -K - at.shadowBoundary
            } else {
                issues.append(issue("pull_back_below_minimum", "shadow"))
            }
        }

        for (side, name) in [(top, "highlight"), (bottom, "shadow")] {
            guard side.on, let knee = side.knee, let room = side.room else { continue }
            if room < minRoom { issues.append(issue("room_below_minimum", name)) }
            if room > domainStops || abs(knee) > domainStops { issues.append(issue("out_of_range", name)) }
        }
        var core: Double?
        if top.on, bottom.on, let high = top.knee, let low = bottom.knee {
            core = high - low
            if !(low < high) { issues.append(issue("knees_cross", "both")) }
        }

        // A knee past the metered mid-grey moves the subject: legal, and said.
        if top.on, let knee = top.knee, knee < 0 { warnings.append(issue("knee_past_midgrey", "highlight")) }
        if bottom.on, let knee = bottom.knee, knee > 0 { warnings.append(issue("knee_past_midgrey", "shadow")) }

        if top.on, let knee = top.knee, let room = top.room { curve.highlightKnee = knee; curve.highlightRoom = room }
        if bottom.on, let knee = bottom.knee, let room = bottom.room { curve.shadowKnee = knee; curve.shadowRoom = room }
        top.landingEV = mapped(top.sceneExtremeEV, curve)
        top.slopeAtExtreme = slope(top.sceneExtremeEV, curve)
        bottom.landingEV = mapped(bottom.sceneExtremeEV, curve)
        bottom.slopeAtExtreme = slope(bottom.sceneExtremeEV, curve)

        let valid = issues.isEmpty
        return Fit(valid: valid, issues: issues, warnings: warnings, highlight: top, shadow: bottom, coreStops: core,
                   paramsDelta: valid ? Fit.ParamsDelta(active: top.on || bottom.on, norm: base.norm,
                                                        highlightKnee: curve.highlightKnee, highlightRoom: curve.highlightRoom,
                                                        shadowKnee: curve.shadowKnee, shadowRoom: curve.shadowRoom,
                                                        rolloff: base.rolloff, maxLift: base.maxLift) : nil)
    }

    /// The frame's histogram after a curve: each bin's share carried to where
    /// the curve lands it, in eight sub-steps a bin so a compressed range does
    /// not turn into a comb. With both sides off, the histogram as it is.
    static func placedHistogram(_ histogram: SceneLatitudeReply.Scene.Histogram, curve p: SceneLatitudeSettings) -> [Double] {
        let shares = histogram.fractions
        guard p.highlightRoom > 0 || p.shadowRoom > 0, !shares.isEmpty else { return shares }
        let sub = 8, bins = shares.count
        let width = (histogram.hiEV - histogram.loEV) / Double(bins)
        var out = [Double](repeating: 0, count: bins)
        for b in 0..<bins where shares[b] != 0 {
            for k in 0..<sub {
                let e = histogram.loEV + (Double(b) + (Double(k) + 0.5) / Double(sub)) * width
                let to = min(max(Int(((mapped(e, p) - histogram.loEV) / width).rounded(.down)), 0), bins - 1)
                out[to] += shares[b] / Double(sub)
            }
        }
        return out
    }
}

extension SceneLatitudeReply {
    /// This measurement with a placement solved on it here: the reply the
    /// engine would give for those pull-backs — its fit, and the frame's
    /// histogram after its curve where the fit is taken — without asking it.
    func placed(_ settings: SceneLatitudeSettings) -> SceneLatitudeReply {
        var out = self
        let fit = PlacementFit.fit(PlacementFit.Measured(self, for: settings), highlight: settings.highlightPullBack,
                                   shadow: settings.shadowPullBack, base: settings)
        out.fit = fit
        var curve = settings
        out.scene.histogram.placedFractions = curve.apply(fit) ? PlacementFit.placedHistogram(scene.histogram, curve: curve) : nil
        return out
    }

    /// Where the solve made here parts from the engine's, on this reply: its
    /// own fit — the engine's, of the pull-backs it was asked with — against
    /// the app's solve of the same pull-backs on the same reply's measurement.
    /// Nil where the two agree: the verdict, the reasons in their order, and
    /// each side's knee and room to a millionth of a stop. A line for the log
    /// where they do not. The self-test holds the solve to the engine on the
    /// frames in `tools/engine_replies`; this asks the same of whatever frame
    /// is on the page, every time the engine measures it.
    func disagreement(with settings: SceneLatitudeSettings) -> String? {
        let mine = PlacementFit.fit(PlacementFit.Measured(self, for: settings), highlight: fit.highlight.pullBack,
                                    shadow: fit.shadow.pullBack, base: settings)
        func said(_ f: Fit) -> String { f.valid ? "takes it" : "refuses it (" + f.issues.map { $0.code + ", " + $0.side }.joined(separator: "; ") + ")" }
        let asked = String(format: "highlight %.2f and shadow %.2f", fit.highlight.pullBack, fit.shadow.pullBack)
        guard said(mine) == said(fit) else { return "\(asked): the engine \(said(fit)), the app \(said(mine))" }
        for (name, ours, theirs) in [("highlight knee", mine.highlight.knee, fit.highlight.knee), ("highlight room", mine.highlight.room, fit.highlight.room),
                                     ("shadow knee", mine.shadow.knee, fit.shadow.knee), ("shadow room", mine.shadow.room, fit.shadow.room)] {
            switch (ours, theirs) {
            case (nil, nil): continue
            case (let a?, let b?) where abs(a - b) <= 1e-6: continue
            default:
                func text(_ v: Double?) -> String { v.map { String(format: "%.9f", $0) } ?? "none" }
                return "\(asked): the engine's \(name) is \(text(theirs)), the app's \(text(ours))"
            }
        }
        return nil
    }
}

// MARK: - what the Fit takes

/// The pull-backs the Fit accepts on one side, with the other side held:
/// `least...most`, or nothing. Zero — the side off — is always accepted and is
/// not part of it.
///
/// Found by asking the solve, not derived: the lower edge is the minimum plus
/// whatever the knee needs to turn, the upper one is the lift bound, the
/// curve's range or the other side's knee, and only the Fit knows where those
/// fall on a given frame.
struct PlacementWindow: Equatable, Sendable {
    typealias Issue = SceneLatitudeReply.Fit.Issue
    static let noWindowCode = "no_window"
    /// A pull-back is shown to two decimals, so the edges are whole hundredths:
    /// a value a row can show is a value the Fit takes.
    static let grain = 0.01

    /// Nil when no pull-back on this side is accepted.
    var span: ClosedRange<Double>?
    /// Why a value under `span` is refused, and one over it.
    var below: Issue
    var above: Issue?

    /// What the Fit said about one pull-back.
    enum Verdict: Equatable, Sendable { case valid, refused(Issue) }

    /// Where a value lands: itself inside the window, the nearer edge outside
    /// it, and off when there is no window — with the reason it moved.
    func landing(_ asked: Double) -> (value: Double, why: Issue?) {
        guard asked > 0 else { return (0, nil) }
        guard let span else { return (0, below) }
        if asked < span.lowerBound { return (span.lowerBound, below) }
        if asked > span.upperBound { return (span.upperBound, above) }
        return (asked, nil)
    }

    /// Search `range` for the window. The accepted pull-backs are one interval
    /// (room grows with the pull-back; the lift bound, the curve's range and
    /// the crossing knees only stop it from above), so: walk up from the
    /// minimum to the first accepted value, then bisect each edge. `step` is
    /// the walk's: a window narrower than it can be walked over, so a ruler
    /// hands in its own. Some thirty solves.
    ///
    /// **The edges are exact**: the least is the smallest hundredth the Fit
    /// takes and the most the largest, and each edge's reason is the Fit's for
    /// the hundredth just past it. (The desktop's search stops within a
    /// hundredth of each; here the engine's verdict on every hundredth of a
    /// real frame's rulers is on file, and the window is held to it.)
    static func search(side: PlacementSide, minimum: Double, in range: ClosedRange<Double>,
                       step: Double = 0.125, verdict: (Double) -> Verdict) -> PlacementWindow {
        func own(_ i: Issue) -> Issue { Issue(code: i.code, side: side.rawValue, message: i.message) }
        func refused(_ x: Double) -> Issue? {
            if case .refused(let why) = verdict(x) { return own(why) }
            return nil
        }
        /// Hundredths to a stop, and the double nearest to a number of them.
        let per = (1 / grain).rounded()
        func stops(_ hundredths: Double) -> Double { hundredths / per }

        var below = Issue(code: "pull_back_below_minimum", side: side.rawValue, message: "")
        var refusedAt = max(minimum, range.lowerBound, 0)
        var found: Double?
        var x = (refusedAt / step).rounded(.down) * step + step
        while x <= range.upperBound + 1e-9 {
            if let why = refused(x) { below = why; refusedAt = x } else { found = x; break }
            x += step
        }
        guard let first = found else {
            return PlacementWindow(span: nil, below: Issue(code: noWindowCode, side: side.rawValue, message: below.message))
        }

        // The lower edge, between the last refusal and the first acceptance: bisected until
        // less than a hundredth lies between the two. The least is then the first hundredth
        // over the refusal, or the one after it.
        var bad = refusedAt, good = first
        while good - bad > grain / 2 {
            let mid = (bad + good) / 2
            if let why = refused(mid) { below = why; bad = mid } else { good = mid }
        }
        var least = (bad * per).rounded(.down) + 1
        if stops(least) <= good, let why = refused(stops(least)) { below = why; least += 1 }
        least = min(least, (first * per).rounded())
        if least > 1, let why = refused(stops(least - 1)) { below = why }

        // The upper edge: the top of the track if the Fit takes it.
        var above: Issue?
        var most = (range.upperBound * per).rounded()
        if let why = refused(range.upperBound) {
            above = why
            good = first
            bad = range.upperBound
            while bad - good > grain / 2 {
                let mid = (bad + good) / 2
                if let why = refused(mid) { above = why; bad = mid } else { good = mid }
            }
            most = (bad * per).rounded(.up) - 1
            if stops(most) > good, let why = refused(stops(most)) { above = why; most -= 1 }
            most = max(most, least)
            if let why = refused(stops(most + 1)) { above = why }
        }
        return PlacementWindow(span: stops(least)...stops(most), below: below, above: above)
    }
}

// MARK: - a ruler over what the Fit takes

/// A ruler whose stops are the pull-backs the Fit takes: its first is off, the
/// next the least the Fit takes, its last the most. The ruler's own number is a
/// *position* — how far along the scale its mark is, in stops of travel — and
/// this is the two-way reading between a position and the pull-back it stands
/// for. Every position the ruler can rest on is a pull-back the Fit takes; the
/// stretch it refuses is not on the ruler.
///
/// The stops are the ruler's own twentieths of a stop: the least rounded up to
/// one and the most rounded down, so the number beside the ruler reads 2.35,
/// 2.40, 2.45 — and a window that holds none of them is one stop, its least.
struct PlacementRuler: Equatable, Sendable {
    /// Where a finger may leave the ruler, in stops.
    static let step = 0.05
    /// The same, in hundredths.
    private static let unit = 5

    /// The least and the most the ruler offers, in hundredths of a stop; nil
    /// where the Fit takes nothing.
    private var stops: ClosedRange<Int>?
    /// The side's pull-back when the ruler was made, in hundredths: what its
    /// mark stands for where the ruler offers nothing else.
    private var held: Int

    /// A ruler over `span` — what the Fit takes on a side, nil for nothing —
    /// for a side whose pull-back is `value` now.
    init(_ span: ClosedRange<Double>?, holding value: Double) {
        held = max(0, Self.hundredths(value))
        guard let span else { stops = nil; return }
        let least = Self.hundredths(span.lowerBound), most = Self.hundredths(span.upperBound)
        let first = (least + Self.unit - 1) / Self.unit * Self.unit, last = most / Self.unit * Self.unit
        stops = first <= last ? first...last : least...least
    }

    /// The ruler of a frame nothing has measured: every stop of the track, as a number.
    static func plain(over range: ClosedRange<Double>, holding value: Double) -> PlacementRuler {
        PlacementRuler(max(range.lowerBound, step)...range.upperBound, holding: value)
    }

    private static func hundredths(_ v: Double) -> Int { Int((v * 100).rounded()) }

    /// The least and the most pull-back on the ruler; nil where it offers none.
    var first: Double? { stops.map { Double($0.lowerBound) / 100 } }
    var last: Double? { stops.map { Double($0.upperBound) / 100 } }

    /// The ruler's positions: 0, which is off, and one step for the least. A
    /// side that is on where the Fit takes nothing can still be turned off.
    var range: ClosedRange<Double> {
        guard let stops else { return 0...(held > 0 ? Self.step : 0) }
        return 0...Double(Self.unit + stops.upperBound - stops.lowerBound) / 100
    }

    /// Where the mark sits for a pull-back. One the ruler does not offer — a
    /// placement solved on another film or paper — sits at the nearer end.
    func position(of pullBack: Double) -> Double {
        let value = Self.hundredths(pullBack)
        guard value > 0 else { return 0 }
        guard let stops else { return Self.step }
        return Double(Self.unit + min(max(value, stops.lowerBound), stops.upperBound) - stops.lowerBound) / 100
    }

    /// The pull-back a position stands for.
    func pullBack(at position: Double) -> Double {
        let at = Self.hundredths(position)
        guard at > Self.unit / 2 else { return 0 }
        guard let stops else { return Double(held) / 100 }
        return Double(min(stops.lowerBound + max(at, Self.unit) - Self.unit, stops.upperBound)) / 100
    }
}

// MARK: - the panel

/// Scene Placement as the Scene tab shows it: what each ruler offers on this
/// frame, and the line under the two.
struct PlacementPanel: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var ruler: PlacementRuler
        /// False where nothing on the ruler can be chosen: the row is dimmed.
        var enabled: Bool
    }

    var highlight: Row
    var shadow: Row
    /// The line under the rulers; nil is the tab's own.
    var note: PlacementNote?

    subscript(side: PlacementSide) -> Row { side == .highlight ? highlight : shadow }

    /// A frame no engine measures (the drawings' own library): the rulers are numbers.
    static func numbers(_ settings: SceneLatitudeSettings, over range: ClosedRange<Double> = ScenePlacement.range) -> PlacementPanel {
        PlacementPanel(highlight: Row(ruler: .plain(over: range, holding: settings.highlightPullBack), enabled: true),
                       shadow: Row(ruler: .plain(over: range, holding: settings.shadowPullBack), enabled: true), note: nil)
    }

    /// A frame the engine has not measured as it stands — its page's develop
    /// has not landed, or a pasted placement waits for its Fit: the rulers wait.
    static func waiting(_ settings: SceneLatitudeSettings, note: PlacementNote? = nil,
                        over range: ClosedRange<Double> = ScenePlacement.range) -> PlacementPanel {
        var panel = numbers(settings, over: range)
        panel.highlight.enabled = false
        panel.shadow.enabled = false
        panel.note = note
        return panel
    }
}

enum ScenePlacement {
    /// The rulers' track, in stops of pull-back: the desktop's sliders'.
    static let range: ClosedRange<Double> = 0...8

    /// The pull-backs the Fit takes on one side of a measured frame, the other
    /// side held at `other`. Solved each time it is asked — some twenty solves,
    /// tens of microseconds — so it is never out of date.
    static func window(_ side: PlacementSide, other: Double, on at: PlacementFit.Measured, base: SceneLatitudeSettings,
                       in range: ClosedRange<Double> = range) -> PlacementWindow {
        PlacementWindow.search(side: side, minimum: at.minimum(side), in: range, step: PlacementRuler.step) { x in
            let fit = PlacementFit.fit(at, highlight: side == .highlight ? x : other, shadow: side == .shadow ? x : other, base: base)
            return fit.issues.first.map { .refused($0) } ?? .valid
        }
    }

    /// One step of a ruler, solved: the frame's settings with `side` at the
    /// pull-back the Fit takes nearest to `asked`, and the curve of the two
    /// together. Off — 0 — is not a Fit: that side's curve goes and the other's
    /// stays as it is. Nil when nothing can be committed: the Fit takes nothing
    /// on that side as things stand — of this frame, or beside the other side,
    /// which then has to move first.
    static func place(_ asked: Double, moving side: PlacementSide, in settings: SceneLatitudeSettings,
                      on reply: SceneLatitudeReply, range: ClosedRange<Double> = range) -> SceneLatitudeSettings? {
        let at = PlacementFit.Measured(reply, for: settings)
        var value = max(0, asked)
        if value > 0 {
            value = window(side, other: settings[side.other], on: at, base: settings, in: range).landing(value).value
            guard value > 0 else { return nil }
        }
        var placed = settings
        placed[side] = value
        guard value > 0 else {
            if side == .highlight { placed.highlightRoom = 0 } else { placed.shadowRoom = 0 }
            if placed[side.other] <= 0 {
                placed.highlightRoom = 0
                placed.shadowRoom = 0
            }
            placed.active = placed.highlightRoom > 0 || placed.shadowRoom > 0
            return placed
        }
        let fit = PlacementFit.fit(at, highlight: placed.highlightPullBack, shadow: placed.shadowPullBack, base: settings)
        return placed.apply(fit) ? placed : nil
    }

    /// The panel for a frame's settings on its measurement. `moved` is the
    /// ruler last under a finger: the line speaks of its end before anything else.
    static func panel(_ settings: SceneLatitudeSettings, on reply: SceneLatitudeReply, moved: PlacementSide? = nil,
                      in range: ClosedRange<Double> = range) -> PlacementPanel {
        let at = PlacementFit.Measured(reply, for: settings)
        func found(_ side: PlacementSide) -> (window: PlacementWindow, row: PlacementPanel.Row) {
            let w = window(side, other: settings[side.other], on: at, base: settings, in: range)
            return (w, PlacementPanel.Row(ruler: PlacementRuler(w.span, holding: settings[side]),
                                          enabled: w.span != nil || settings[side] > 0))
        }
        let top = found(.highlight), bottom = found(.shadow)
        func of(_ side: PlacementSide) -> (window: PlacementWindow, row: PlacementPanel.Row) { side == .highlight ? top : bottom }

        let on = settings.highlightPullBack > 0 || settings.shadowPullBack > 0
        let fit = on ? PlacementFit.fit(at, highlight: settings.highlightPullBack, shadow: settings.shadowPullBack, base: settings) : nil
        var note: PlacementNote?
        if let fit, !fit.valid {
            // The frame carries a placement solved on another film, paper or exposure.
            note = .stale
        } else {
            let flat: PlacementNote? = fit?.warnings.contains { $0.code == "knee_past_midgrey" } == true ? .flat : nil
            let closed = PlacementSide.allCases.filter { settings[$0] <= 0 && of($0).window.span == nil }
            // A side with nothing beside the other may have plenty without it.
            let blocked = closed.filter { settings[$0.other] > 0 && window($0, other: 0, on: at, base: settings, in: range).span != nil }
            // One line, and what is news comes first. Of the ruler just moved: why it
            // stops where it does. Then what that move did to the other ruler: a dimmed
            // ruler is not left unexplained. Then what the placement costs. Why a ruler
            // offers nothing on this frame at all is said first on a page nothing has
            // been moved on, and after those once something has.
            if let moved {
                note = end(moved, settings[moved], of(moved).window, of(moved).row.ruler, minimum: at.minimum(moved), range: range)
            }
            if note == nil, let side = blocked.first {
                note = PlacementNote(text: L("\(L(shown: side.name)): nothing fits beside this much \(L(shown: side.other.name))."), refused: false)
            }
            if note == nil, moved != nil { note = flat }
            if note == nil, closed.count == 2 {
                note = PlacementNote(text: L("Neither end can be brought inside: both are too far outside."), refused: false)
            } else if note == nil, let side = closed.first {
                note = PlacementNote(text: side == .highlight ? L("Highlight: the brightest part is too far over to pull inside.")
                                                              : L("Shadow: the darkest part is too far under to lift inside."), refused: false)
            }
            note = note ?? flat
        }
        return PlacementPanel(highlight: top.row, shadow: bottom.row, note: note)
    }

    /// What the line says of a ruler resting on its first stop or its last: why
    /// the scale starts, or ends, there. Nil in between, and where the scale
    /// starts at its own first step or ends at the track's.
    private static func end(_ side: PlacementSide, _ value: Double, _ window: PlacementWindow, _ ruler: PlacementRuler,
                            minimum: Double, range: ClosedRange<Double>) -> PlacementNote? {
        guard value > 0, let first = ruler.first, let last = ruler.last else { return nil }
        let part = side == .highlight ? L("brightest") : L("darkest")
        if value <= first, first > PlacementRuler.step + 1e-9 {
            // Under the least, the scene's end is still outside — or, where it was
            // never outside, the curve would have no room to turn.
            return PlacementNote(text: String(format: L("%@ starts at %.2f: "), L(shown: side.name), first)
                                     + (minimum > 0 ? L("less leaves the \(part) part out.") : L("less turns too sharply at the edge.")),
                                 refused: true)
        }
        if value >= last, last < (range.upperBound / PlacementRuler.step).rounded(.down) * PlacementRuler.step - 1e-9 {
            let why: String
            switch window.above?.code {
            case "knees_cross": why = L("more would cross the \(L(shown: side.other.name))'s curve.")
            case "pull_back_exceeds_max_lift": why = L("the most the shadows can be lifted.")
            default: why = L("more is further than the curve reaches.")
            }
            return PlacementNote(text: String(format: L("%@ ends at %.2f: "), L(shown: side.name), last) + why, refused: true)
        }
        return nil
    }
}
