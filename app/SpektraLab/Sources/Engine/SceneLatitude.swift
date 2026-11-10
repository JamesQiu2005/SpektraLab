//  SceneLatitude.swift — the engine's Scene Latitude call, in the app's types.
//
//  `spk_scene_latitude` (RFC-023, API-SPEC §12) measures and solves, and never
//  renders. One reply carries both things the develop page wants of it:
//
//  - **the measurement** the Latitude card draws: the two boundaries this film
//    and paper hold between (a neutral ramp through the session's own chain,
//    read as ISO 6846 reads a paper), and the frame's histogram on the same
//    stop axis — stops about the metered mid-grey;
//  - **the fit** Scene Placement commits: the pull-backs solved into a curve,
//    or refused with a reason. The pull-backs are what the user dragged; the
//    curve is the only thing the engine renders (`SceneLatitudeSettings`).
//
//  The desktop draws a good deal more from the same reply — the share of the
//  frame below, within and above the window, the chain's separation band, the
//  window to two decimals. The host's card is the drawing's: the scene, the
//  window, how many stops it holds.
//
//  Nothing here touches the engine or a view: `tools/selftest.sh` holds the
//  mapping against replies the engine made (`tools/engine_replies`).

import Foundation

// MARK: - the request

/// What to solve. Every field is optional on the wire: an absent pull-back
/// asks for the engine's suggestion, an absent curve setting uses the
/// session's.
struct SceneLatitudeRequest: Encodable, Equatable, Sendable {
    var highlightPullBack: Double?
    var shadowPullBack: Double?
    var rolloff: Double?
    var maxLift: Double?
    var norm: String?
    var margin: Double?
    /// 0.1 or 1.
    var shadowPercentile: Double?
    /// 99.9 or 99.
    var highlightPercentile: Double?
    /// One frame of a half-frame pair, measured and fitted by itself: x0, y0,
    /// x1, y1, normalised to the frame the engine was handed — the piece —
    /// with a top-left origin (`HalfFramePair.fitRegion`; `engine.cpp`,
    /// `scene_latitude.cpp`). Absent, the whole frame is the scene.
    var region: [Double]?

    enum CodingKeys: String, CodingKey {
        case rolloff = "rolloff", norm = "norm", margin = "margin", region = "region"
        case highlightPullBack = "highlight_pull_back", shadowPullBack = "shadow_pull_back"
        case maxLift = "max_lift", shadowPercentile = "shadow_percentile"
        case highlightPercentile = "highlight_percentile"
    }

    /// The request as the engine reads it: only the keys that are set, so
    /// "absent" means what the engine says it means and never arrives as null.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - the reply

/// The medium, the scene, a suggestion and a solved fit: measurements and a
/// proposal, never a render.
struct SceneLatitudeReply: Decodable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case medium = "medium", scene = "scene", suggested = "suggested", fit = "fit" }
    /// The session's film and paper, measured by a neutral ramp (RFC-023 §8.1).
    struct Medium: Decodable, Equatable, Sendable {
        var shadowEV: Double
        var highlightEV: Double
        var latitudeStops: Double
        var yBlack: Double
        var yWhite: Double
        /// 128 points of the print's relative luminance against scene stops.
        var rampEV: [Double]
        var rampY: [Double]
        enum CodingKeys: String, CodingKey {
            case shadowEV = "shadow_ev", highlightEV = "highlight_ev", latitudeStops = "latitude_stops"
            case yBlack = "y_black", yWhite = "y_white", rampEV = "ramp_ev", rampY = "ramp_y"
        }
    }

    /// The frame on the curve's own axis: stops from the metered mid-grey.
    struct Scene: Decodable, Equatable, Sendable {
        struct Histogram: Decodable, Equatable, Sendable {
            var loEV: Double
            var hiEV: Double
            /// The share of the frame in each bin: 128 quarter stops across −16…+16.
            var fractions: [Double]
            /// The same bins after the requested pull-backs' curve. Absent when
            /// the fit was refused; equal to `fractions` with both sides off.
            var placedFractions: [Double]?
            /// RFC-035 §5.2: R, G and B by themselves, each the share of that
            /// channel's own samples, on the same bins as `fractions` (stops of
            /// the channel about the same metered mid-grey). Before Scene
            /// Placement: there is no placed form. Absent from an engine older
            /// than 2026-10-25.
            var fractionsR: [Double]?
            var fractionsG: [Double]?
            var fractionsB: [Double]?
            /// RFC-035 §5.3: Film Exposure, `exposure_compensation_ev`. Every
            /// stop in the reply -- these bins, the percentiles, the medium's
            /// window, the fit -- is on the axis before it; add this to put one
            /// on the film's axis, the Decode curve's. There the window is the
            /// film and paper's own and does not move with Film Exposure or the
            /// curve. Absent (read as 0) from an engine older than 2026-10-25.
            var exposureEV: Double?
            /// RFC-051: the frame after the scene transform the render applies before
            /// the film -- the committed Scene Placement, then the Decode curve --
            /// through the render's own nodes, on the same bins and axis (before Film
            /// Exposure). Absent with neither, and from an engine older than 2026-11-09.
            var curvedFractions: [Double]?
            var curvedFractionsR: [Double]?
            var curvedFractionsG: [Double]?
            var curvedFractionsB: [Double]?
            enum CodingKeys: String, CodingKey {
                case loEV = "lo_ev", hiEV = "hi_ev", fractions = "fractions", placedFractions = "placed_fractions"
                case fractionsR = "fractions_r", fractionsG = "fractions_g", fractionsB = "fractions_b"
                case exposureEV = "exposure_ev"
                case curvedFractions = "curved_fractions", curvedFractionsR = "curved_fractions_r"
                case curvedFractionsG = "curved_fractions_g", curvedFractionsB = "curved_fractions_b"
            }
        }
        var norm: String
        var samples: Double
        var p0_1: Double
        var p1: Double
        var p50: Double
        var p99: Double
        var p99_9: Double
        var histogram: Histogram
        enum CodingKeys: String, CodingKey {
            case norm = "norm", samples = "samples", p1 = "p1", p50 = "p50", p99 = "p99", histogram = "histogram"
            case p0_1 = "p0_1", p99_9 = "p99_9"
        }
    }

    /// RFC-023 §9.3's default policy, and only a suggestion: each robust
    /// extreme landed `margin` stops inside the medium, a side the scene
    /// already fits left off.
    struct Suggested: Decodable, Equatable, Sendable {
        var highlightPullBack: Double
        var shadowPullBack: Double
        var marginUsed: Double
        var valid: Bool
        enum CodingKeys: String, CodingKey {
            case valid = "valid"
            case highlightPullBack = "highlight_pull_back", shadowPullBack = "shadow_pull_back"
            case marginUsed = "margin_used"
        }
    }

    struct Fit: Decodable, Equatable, Sendable {
        /// A refusal (`issues`) or something legal and worth saying (`warnings`).
        struct Issue: Decodable, Equatable, Sendable {
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case code = "code", side = "side", message = "message" }
            /// `pull_back_below_minimum`, `pull_back_exceeds_max_lift`,
            /// `knees_cross`, `room_below_minimum`, `out_of_range`; of the
            /// warnings, `knee_past_midgrey`.
            var code: String
            /// `highlight`, `shadow` or `both`.
            var side: String
            /// The engine's own sentence: for the log, never for a page.
            var message: String
        }
        /// One side's readouts. `knee` and `room` only when the side is on.
        struct Side: Decodable, Equatable, Sendable {
            var on: Bool
            var pullBack: Double
            /// Below this the extreme still lands past the medium's boundary.
            var minimumPullBack: Double
            var sceneExtremeEV: Double
            var mediumBoundaryEV: Double
            var knee: Double?
            var room: Double?
            /// Where the render really puts the extreme, and the curve's slope there.
            var landingEV: Double
            var slopeAtExtreme: Double
            enum CodingKeys: String, CodingKey {
                case on = "on", knee = "knee", room = "room"
                case pullBack = "pull_back", minimumPullBack = "minimum_pull_back"
                case sceneExtremeEV = "scene_extreme_ev", mediumBoundaryEV = "medium_boundary_ev"
                case landingEV = "landing_ev", slopeAtExtreme = "slope_at_extreme"
            }
        }
        /// The wire delta that commits this fit.
        struct ParamsDelta: Decodable, Equatable, Sendable {
            var active: Bool
            var norm: String
            var highlightKnee: Double
            var highlightRoom: Double
            var shadowKnee: Double
            var shadowRoom: Double
            var rolloff: Double
            var maxLift: Double
            enum CodingKeys: String, CodingKey {
                case active = "scene_latitude_active", norm = "scene_latitude_norm"
                case highlightKnee = "scene_latitude_highlight_knee"
                case highlightRoom = "scene_latitude_highlight_room"
                case shadowKnee = "scene_latitude_shadow_knee"
                case shadowRoom = "scene_latitude_shadow_room"
                case rolloff = "scene_latitude_rolloff", maxLift = "scene_latitude_max_lift"
            }
        }
        var valid: Bool
        var issues: [Issue]
        var warnings: [Issue]
        var highlight: Side
        var shadow: Side
        /// The untouched stops between the two knees, when both sides are on.
        var coreStops: Double?
        /// Present only for a valid fit, so a refused one cannot be committed.
        var paramsDelta: ParamsDelta?
        enum CodingKeys: String, CodingKey {
            case valid = "valid", issues = "issues", warnings = "warnings", highlight = "highlight", shadow = "shadow"
            case coreStops = "core_stops", paramsDelta = "params_delta"
        }
    }

    var medium: Medium
    var scene: Scene
    var suggested: Suggested
    var fit: Fit

    static func decode(_ json: String) -> SceneLatitudeReply? {
        try? JSONDecoder().decode(SceneLatitudeReply.self, from: Data(json.utf8))
    }
}

// MARK: - the settings' two halves

extension SceneLatitudeSettings {
    /// The request that solves these pull-backs again, against the session's
    /// medium and scene as they are now.
    var request: SceneLatitudeRequest {
        SceneLatitudeRequest(highlightPullBack: highlightPullBack, shadowPullBack: shadowPullBack,
                             rolloff: rolloff, maxLift: maxLift, norm: norm,
                             shadowPercentile: shadowPercentile, highlightPercentile: highlightPercentile)
    }

    /// Take a fit: the pull-backs it was solved for become the UI state and
    /// its curve becomes the render state. False — and nothing changed — for a
    /// fit the engine refused, which carries no `params_delta`.
    @discardableResult
    mutating func apply(_ fit: SceneLatitudeReply.Fit) -> Bool {
        guard fit.valid, let d = fit.paramsDelta else { return false }
        highlightPullBack = fit.highlight.pullBack
        shadowPullBack = fit.shadow.pullBack
        active = d.active
        norm = d.norm
        highlightKnee = d.highlightKnee
        highlightRoom = d.highlightRoom
        shadowKnee = d.shadowKnee
        shadowRoom = d.shadowRoom
        rolloff = d.rolloff
        maxLift = d.maxLift
        return true
    }
}

// MARK: - what Scene Placement says

/// The line under Scene Placement's two rulers when there is something to say
/// of the placement, or of what a ruler offers (`ScenePlacement.panel`).
struct PlacementNote: Equatable, Sendable {
    var text: String
    /// Something asked for was not taken as asked — a ruler stopped at the end
    /// of what the Fit takes, the engine refused a pasted placement, the frame's
    /// placement no longer fits: the line is set in the accent. False is said
    /// quietly: what a placement that was taken costs, why a ruler offers nothing.
    var refused: Bool

    /// The longest line the panel holds on one row at 11 pt: under the rulers
    /// there is room for one. The self-test holds every line to it.
    static let longestLine = 64

    /// A placement whose knee has passed the metered mid-grey, where the subject
    /// sits: legal, and where the picture starts to go flat (RFC-023 §15.6).
    static var flat: PlacementNote { PlacementNote(text: L("This much reaches the mid-tones: the picture starts to go flat."), refused: false) }
    /// The frame's placement was solved on another film, paper or exposure, and
    /// does not solve on what the frame has now. Nothing is solved again behind
    /// the user's back (RFC-023 §8.3): a ruler has to move.
    static var stale: PlacementNote { PlacementNote(text: L("This placement no longer fits: move a ruler to place it again."), refused: true) }
}

extension SceneLatitudeReply.Fit {
    /// What the page says of a fit **the engine made** — a pasted placement's:
    /// why the engine refused it, or what an accepted one costs; nil when
    /// there is nothing to say. (A ruler's own steps are never refused; what
    /// the panel says of them is `ScenePlacement.panel`'s.)
    /// **The page's own words.** The engine's sentences speak of "the medium"
    /// and go to the log; a code this does not know gets a plain line, never
    /// the engine's.
    var note: PlacementNote? {
        if let issue = issues.first {
            return PlacementNote(text: Self.refusal(issue, highlight: highlight, shadow: shadow), refused: true)
        }
        guard valid else { return PlacementNote(text: L("That placement cannot be solved on this frame."), refused: true) }
        if warnings.contains(where: { $0.code == "knee_past_midgrey" }) { return .flat }
        return nil
    }

    private static func refusal(_ issue: Issue, highlight: Side, shadow: Side) -> String {
        let top = issue.side != "shadow"
        let name = top ? L("Highlight") : L("Shadow")
        switch issue.code {
        case "pull_back_below_minimum":
            // Below the minimum the scene's end still lands past the window's edge.
            let minimum = top ? highlight.minimumPullBack : shadow.minimumPullBack
            let part = top ? L("brightest") : L("darkest")
            return minimum > 0 ? String(format: L("%@: more than %.2f stops brings the %@ part inside."), name, minimum, part)
                               : L("\(name): a little more brings the \(part) part inside.")
        case "room_below_minimum":
            return L("\(name): a little more — this close to the edge the curve turns too sharply.")
        case "pull_back_exceeds_max_lift":
            return L("Shadow: less — this is past the most the shadows can be lifted.")
        case "knees_cross":
            return L("Highlight and Shadow would cross: pull back less on one side.")
        default:
            return L("That placement cannot be solved on this frame.")
        }
    }
}

// MARK: - what the meter draws

/// Scene Placement's mark on one side of the card: a dashed line, and the
/// stops from it to `reach`, shaded.
///
/// **On a measured frame the line is where that end of the scene was** — its
/// brightest part, or its darkest, as the frame was shot (`scene_extreme_ev`)
/// — and the shade runs to where the placement lands it (`landing_ev`). The
/// histogram on the card is the frame after the placement, so its own end is
/// at `reach`, and the shade is as many stops wide as the ruler says: pull the
/// highlights back 2.35 and 2.35 stops are shaded, from where they were.
///
/// Until 2026-10-08 the line was drawn at the curve's *knee* and the shade
/// ran from there to the window's edge. The knee is a number of the solve, not
/// of the picture, and it moves the wrong way to be read: the further an end
/// has to be brought, the further back the curve starts, so a shadow lifted
/// 2.7 stops on a host's HEIF put its line 6.5 stops up, in the highlights,
/// and a first step of the Highlight ruler shaded most of the window. The
/// owner, from the host: "the virtual line for scene placement on latitude
/// is still making no sense to me". (The desktop's graph draws neither: its
/// histogram alone shows a placement.)
struct PlacementSpan: Equatable, Sendable {
    /// The stop the dashed line stands at.
    var line: Double
    /// The stop the shade runs to.
    var reach: Double
}

/// What the meter draws: the scene on a stop axis, and the held window.
struct LatitudeReadout: Equatable, Sendable {
    /// The axis: stops about the metered mid-grey. Fixed, so two frames or
    /// two papers compare at a glance.
    var loEV = -8.0
    var hiEV = 8.0
    /// The scene's histogram, each sample 0…1 of the tallest.
    var bins: [Double]
    /// Where the first and the last of `bins` sit on the axis; the rest are
    /// evenly between them.
    var binsFromEV = -8.0
    var binsToEV = 8.0
    /// The window the film and paper hold between.
    var shadowEV: Double
    var highlightEV: Double
    /// RFC-035 §5.2: the scene's R, G and B histograms on `bins`' samples
    /// (same count, same `binsFromEV`…`binsToEV`), each 0…1 of the tallest of
    /// all four. `nil` where the engine sent none (an older engine, or a
    /// reading not from the engine): a drawing must then say it fell back to
    /// `bins`, not pass the luminance off as a channel (trap 16). Unlike
    /// `bins` these are never after Scene Placement.
    var binsR: [Double]? = nil
    var binsG: [Double]? = nil
    var binsB: [Double]? = nil
    /// `bins` is 0…1 of its own tallest; times this it is on the channels'
    /// scale, so a fill and three lines can be drawn together. 1 without them.
    var channelScale = 1.0
    /// RFC-035 §5.3: Film Exposure in stops. Every stop here (the axis of
    /// `bins`, `shadowEV`, `highlightEV`, the placed spans) is before it, as
    /// the Latitude card draws them; the Decode curve's axis is after it, so
    /// it adds this to each. 0 for a reading not from the engine.
    var exposureEV = 0.0
    /// Scene Placement, on the side where it is on: how far that end of the
    /// scene was moved (`PlacementSpan`).
    var highlightPlaced: PlacementSpan? = nil
    var shadowPlaced: PlacementSpan? = nil
    /// RFC-051: the Decode curve's **input** drawn as `bins` is, where `bins` is
    /// the frame after the curve (`curved_fractions`). Nil where the two are the
    /// same reading -- no curve, an older engine, the demo.
    var inputBins: [Double]? = nil
    /// RFC-051: the reply's own shares, not the drawing's heights: what the Decode
    /// curve's output strip is made from. `input` is the curve's input (after a
    /// placement, before the curve); `curved` the engine's after-transform rows,
    /// nil without a transform. Rows are luma, then r, g, b where the reply has
    /// them; all on `shares.from…to` (the reply's axis, before Film Exposure).
    var shares: SceneShares? = nil
    /// RFC-051: the curve and Film Exposure this reading was measured on, where the
    /// page knows it (`OpenFrameSession`): `shares.curved` is exact for that curve
    /// only. Nil is "not known", never "the identity".
    var measuredOn: DecodeStamp? = nil

    /// The curve's input for the hills: the frame before the Decode curve.
    var curveInput: [Double] { inputBins ?? bins }

    var heldStops: Double { highlightEV - shadowEV }

    /// "6.4 stops held".
    var heldText: String { String(format: L("%.1f stops held"), heldStops) }

    static func stopText(_ ev: Double) -> String {
        // A true minus, as the drawings set it.
        (ev < 0 ? "−" : "+") + String(format: "%.1f", abs(ev))
    }

    /// The stop a sample sits at.
    func binEV(_ i: Int) -> Double {
        bins.count > 1 ? binsFromEV + (binsToEV - binsFromEV) * Double(i) / Double(bins.count - 1) : binsFromEV
    }

    /// The develop page's since its v2 (`gen_edit_v2.latitude_card`): the
    /// pair's own numbers, Porta 400 on Porta Enduro, −4.6 to +2.4; and the
    /// same curve drawn in a box 1 / 0.7 as tall, so the scene fills a card
    /// that is 16 pt shorter.
    static let developDemo = drawn(shadowEV: -4.6, highlightEV: 2.4, fill: 1 / 0.7)

    /// gen.py's `histogram_path`, which peaks at two thirds of its box;
    /// `fill` is how much taller than the plot the drawing makes that box.
    ///
    /// The R, G and B rows are drawn too (RFC-035 §3.2, the owner 2026-10-26: each tab shows its own
    /// channel): a demo reading without them would put every colour tab into the no-hills state and read
    /// as a broken engine in the snapshot harness and the tour, where the demo is the only reading there
    /// is. They are the luminance's shape, shifted a bin or two and scaled, so the three lines are
    /// distinct — a drawing, not a measurement.
    private static func drawn(shadowEV: Double, highlightEV: Double, fill: Double = 1) -> LatitudeReadout {
        let n = 90
        let bins = (0...n).map { i -> Double in
            let u = Double(i) / Double(n)
            let v = 0.55 * exp(-pow((u - 0.52) / 0.13, 2)) + 0.35 * exp(-pow((u - 0.74) / 0.07, 2))
                + 0.18 * exp(-pow((u - 0.25) / 0.12, 2)) + 0.05
                + 0.04 * sin(u * 47) + 0.03 * sin(u * 83 + 1.3)
            return min(min(max(v, 0.02), 1) * fill, 1)
        }
        func shifted(_ by: Int, _ scale: Double) -> [Double] {
            bins.indices.map { i in min(1, bins[min(max(i - by, 0), bins.count - 1)] * scale) }
        }
        var out = LatitudeReadout(bins: bins, shadowEV: shadowEV, highlightEV: highlightEV)
        (out.binsR, out.binsG, out.binsB) = (shifted(-2, 1.15), bins, shifted(2, 0.85))
        return out
    }
}

extension LatitudeReadout {
    /// The engine's reading. The histogram is the frame **after** Scene
    /// Placement where the fit gave one (`placed_fractions`), drawn at the
    /// square root of each bin's share over the tallest — the desktop's
    /// height, so one bright area cannot flatten the rest. A sample sits at
    /// its bin's centre; one bin beyond each end of the axis is kept, so the
    /// fill runs to the plot's edges.
    ///
    /// The placed histogram is of the fit of the pull-backs **as asked now**.
    /// After a paper change that is not quite the curve the frame carries (a
    /// paper change does not refit, RFC-023 §8.3); the desktop draws the same.
    init(_ reply: SceneLatitudeReply) {
        let fit = reply.fit
        func span(_ side: SceneLatitudeReply.Fit.Side) -> PlacementSpan? {
            fit.valid && side.on ? PlacementSpan(line: side.sceneExtremeEV, reach: side.landingEV) : nil
        }
        let h = reply.scene.histogram
        let input = h.placedFractions ?? h.fractions
        // RFC-051: the card is the frame after the transform the render applies --
        // the Decode curve as well as a placement -- against the window. With no
        // transform the engine sends no curved rows and the card is as it was.
        let curved = h.curvedFractions.flatMap { $0.count == input.count ? $0 : nil }
        self.init(shares: curved ?? input, from: h.loEV, to: h.hiEV,
                  shadowEV: reply.medium.shadowEV, highlightEV: reply.medium.highlightEV,
                  highlightPlaced: span(fit.highlight), shadowPlaced: span(fit.shadow))
        if curved != nil {
            inputBins = LatitudeReadout(shares: input, from: h.loEV, to: h.hiEV, shadowEV: shadowEV,
                                        highlightEV: highlightEV).bins
        }
        exposureEV = h.exposureEV ?? 0
        if let r = h.fractionsR, let g = h.fractionsG, let b = h.fractionsB {
            setChannels([r, g, b], from: h.loEV, to: h.hiEV, luma: input)
        }
        func rows(_ luma: [Double], _ r: [Double]?, _ g: [Double]?, _ b: [Double]?) -> [[Double]] {
            guard let r, let g, let b, [r, g, b].allSatisfy({ $0.count == luma.count }) else { return [luma] }
            return [luma, r, g, b]
        }
        shares = SceneShares(from: h.loEV, to: h.hiEV,
                             input: rows(input, h.fractionsR, h.fractionsG, h.fractionsB),
                             curved: curved.map { rows($0, h.curvedFractionsR, h.curvedFractionsG, h.curvedFractionsB) })
    }

    /// The three channels on `bins`' samples, drawn as `bins` is (the square
    /// root of each share), all four against the tallest of the four. Left
    /// `nil` unless each row has the luminance's bin count.
    mutating func setChannels(_ rows: [[Double]], from: Double, to: Double, luma: [Double]) {
        let n = luma.count
        guard n > 1, to > from, rows.count == 3, rows.allSatisfy({ $0.count == n }) else { return }
        let width = (to - from) / Double(n)
        func centre(_ i: Int) -> Double { from + (Double(i) + 0.5) * width }
        let inside = (0..<n).filter { centre($0) > loEV && centre($0) < hiEV }
        guard let lowest = inside.first, let highest = inside.last else { return }
        let first = max(0, lowest - 1), last = min(n - 1, highest + 1)
        func tallest(_ row: [Double]) -> Double { inside.map { max(row[$0], 0).squareRoot() }.max() ?? 0 }
        let ownTallest = tallest(luma)
        let all = max(ownTallest, rows.map(tallest).max() ?? 0)
        guard all > 0 else { return }
        let drawn = rows.map { row in (first...last).map { min(1, max(row[$0], 0).squareRoot() / all) } }
        binsR = drawn[0]; binsG = drawn[1]; binsB = drawn[2]
        channelScale = ownTallest / all
    }

    /// What a curve tab draws behind its curve, from this reading (RFC-035 §3.2; `SceneHills`).
    ///
    /// The luminance's fill needs only `bins`; a colour tab needs that channel's own row, and gets
    /// `none` — never the luminance — where the reading carries none. That is the one place the
    /// choice is made, so a drawing cannot quietly substitute one for the other (trap 16).
    func hills(for channel: CurveChannel) -> SceneHills {
        let n = bins.count
        func channelRow(_ which: CurveChannel) -> [Double]? {
            let row = which == .red ? binsR : (which == .green ? binsG : binsB)
            guard let row, row.count == n else { return nil }
            return row
        }
        // The curve's input, never the frame after it (RFC-051): the hills are what the curve reads.
        let luma = curveInput
        switch channel {
        case .luma:
            return n > 1 ? .luma(luma) : .none
        case .rgb:
            guard n > 1, let r = channelRow(.red), let g = channelRow(.green), let b = channelRow(.blue) else { return .none }
            return .rgb(luma: luma.map { min($0 * channelScale, 1) }, red: r, green: g, blue: b)
        case .red, .green, .blue:
            guard n > 1, let own = channelRow(channel) else { return .none }
            return .channel(own)
        }
    }

    /// A histogram on a stop axis — each bin's share of the frame, the first
    /// bin beginning at `from` and the last ending at `to` — against a window.
    /// The engine's reply is drawn through this.
    init(shares: [Double], from: Double, to: Double, shadowEV: Double, highlightEV: Double,
         highlightPlaced: PlacementSpan? = nil, shadowPlaced: PlacementSpan? = nil) {
        self.init(bins: [], shadowEV: shadowEV, highlightEV: highlightEV,
                  highlightPlaced: highlightPlaced, shadowPlaced: shadowPlaced)
        let n = shares.count
        guard n > 1, to > from else { return }
        let width = (to - from) / Double(n)
        func centre(_ i: Int) -> Double { from + (Double(i) + 0.5) * width }
        // The bins that lie on the axis, and one more at each end.
        let inside = (0..<n).filter { centre($0) > loEV && centre($0) < hiEV }
        guard let lowest = inside.first, let highest = inside.last else { return }
        let first = max(0, lowest - 1), last = min(n - 1, highest + 1)
        let tallest = inside.map { max(shares[$0], 0).squareRoot() }.max() ?? 0
        bins = (first...last).map { tallest > 0 ? min(1, max(shares[$0], 0).squareRoot() / tallest) : 0 }
        binsFromEV = centre(first)
        binsToEV = centre(last)
    }
}

extension LatitudeReadout {
    /// Where a boundary's label is centred, along the plot. It sits 15 pt
    /// outside its line, as drawn. The card has 14 pt beside the plot and a
    /// label is some 22 pt wide: where the line is nearer the plot's end than
    /// that — a wide film's boundary can sit at the axis's end, or past it —
    /// the label goes inside the line, and never off the plot.
    private static let labelOffset: CGFloat = 15, labelRoom: CGFloat = 12

    static func labelX(shadowEdge w0: CGFloat) -> CGFloat {
        w0 >= labelRoom ? w0 - labelOffset : max(w0, 0) + labelOffset
    }

    static func labelX(highlightEdge w1: CGFloat, width: CGFloat) -> CGFloat {
        w1 <= width - labelRoom ? w1 + labelOffset : min(w1, width) - labelOffset
    }
}

/// What the Latitude card has to draw, on a page.
enum LatitudeReading: Equatable, Sendable {
    /// The page's develop has not landed: there is nothing to measure yet.
    case waiting
    case measured(LatitudeReadout)
    /// It was not measured, and why, in the page's words.
    case unavailable(String)

    var readout: LatitudeReadout? {
        if case .measured(let r) = self { r } else { nil }
    }

    /// The card's line where there is no reading: "Measuring", or the reason.
    var note: String? {
        switch self {
        case .waiting: L("Measuring")
        case .measured: nil
        case .unavailable(let why): why
        }
    }

    /// The engine's own two refusals, in the page's words. Its sentences name
    /// "the medium" and may name a profile: they go to the log.
    static func refusal(_ engineMessage: String) -> LatitudeReading {
        if engineMessage.contains("boundaries do not lie inside") {
            return .unavailable(L("This film and paper print no rising tone scale"))
        }
        if engineMessage.contains("no positive pixels") {
            return .unavailable(L("No light in the frame to measure"))
        }
        return .unavailable(L("Not measured"))
    }
}

// MARK: - RFC-051: what the Decode curve does to the scene

/// The curve and Film Exposure a reading was measured on: what the engine's after-curve rows
/// (`SceneShares.curved`) are exact for.
struct DecodeStamp: Equatable, Sendable {
    var curve: CurveSet
    var exposureEV: Double
}

/// The reply's histograms as shares of the frame, on its own 128 bins (`from…to`, before Film
/// Exposure): row 0 the norm's, then R, G, B where the reply has them.
struct SceneShares: Equatable, Sendable {
    var from: Double
    var to: Double
    var input: [[Double]]
    var curved: [[Double]]?

    var count: Int { input.first?.count ?? 0 }
    /// The stop a bin's centre is at, on the reply's axis.
    func centre(_ i: Int) -> Double { from + (Double(i) + 0.5) * (to - from) / Double(max(count, 1)) }
    /// The row a tab reads: the norm's on RGB and 亮度, a colour its own; nil where there is none.
    static func row(_ rows: [[Double]], for channel: CurveChannel) -> [Double]? {
        switch channel {
        case .rgb, .luma: rows.first
        case .red: rows.count == 4 ? rows[1] : nil
        case .green: rows.count == 4 ? rows[2] : nil
        case .blue: rows.count == 4 ? rows[3] : nil
        }
    }
}

/// The Decode curve as the engine applies it, on one tab's path, in film stops (the curve's own axis,
/// ±`FilmParams.sceneCurveStops` about mid-grey on the film): RGB and 亮度 read the luma row, then the
/// rgb row; a colour reads both and then its own (`spk_scene_curve`: luma first, as one gain on Y; then
/// rgb on each channel; then each channel's own). Each row is the wire's 129-sample table, read as the
/// kernel reads it, and past ±8 stops its end's gain holds (slope 1).
///
/// **Exact for a neutral pixel only.** The luma row is a gain on Y, and on a colourful pixel Y's stop is
/// not the channel's, so what this says of a colourful frame is an estimate. That is why the engine
/// measures the frame after the curve itself (`curved_fractions`), and why the drawing uses this only
/// while a point is moving or until that measurement of the curve as it stands has landed.
struct DecodeTransfer: Sendable {
    private let rows: [[Double]]
    static let stops = FilmParams.sceneCurveStops

    init(_ curves: CurveSet, channel: CurveChannel) {
        let n = FilmParams.sceneCurveSamples
        func row(_ c: CurveChannel) -> [Double]? {
            curves.isIdentity(c) ? nil : curves.table(c, size: n).map(Double.init)
        }
        var path: [CurveChannel] = [.luma, .rgb]
        if channel.isColourRow { path.append(channel) }
        rows = path.compactMap(row)
    }

    var isIdentity: Bool { rows.isEmpty }

    /// One row at a film stop: the table read linearly, the end's gain held past the ends.
    private static func read(_ t: [Double], _ e: Double) -> Double {
        let n = t.count
        let lo = -stops, hi = stops
        func value(_ i: Int) -> Double { t[i] * 2 * stops - stops }
        if e <= lo { return e + (value(0) - lo) }
        if e >= hi { return e + (value(n - 1) - hi) }
        let u = (e - lo) / (2 * stops) * Double(n - 1)
        let i = min(Int(u), n - 2), f = u - Double(i)
        return value(i) + (value(i + 1) - value(i)) * f
    }

    /// Where a film stop lands on the film.
    func callAsFunction(_ e: Double) -> Double { rows.reduce(e) { Self.read($1, $0) } }

    /// The input stops the film holds: every `e` in −8…+8 with `f(e)` inside `shadow…highlight`
    /// (film stops), as intervals, each end found to a hundredth of a stop. A curve that folds back
    /// may hold more than one. With the identity, `shadow…highlight` clipped to the axis.
    func held(shadow: Double, highlight: Double) -> [ClosedRange<Double>] {
        guard highlight > shadow else { return [] }
        let step = 1.0 / 32
        let count = Int((2 * Self.stops / step).rounded())
        func inside(_ e: Double) -> Bool { let y = self(e); return y >= shadow && y <= highlight }
        func edge(_ a: Double, _ b: Double) -> Double {
            var (lo, hi) = (a, b)
            let start = inside(a)
            for _ in 0..<12 { let m = (lo + hi) / 2; if inside(m) == start { lo = m } else { hi = m } }
            return (lo + hi) / 2
        }
        var out: [ClosedRange<Double>] = []
        var open: Double? = inside(-Self.stops) ? -Self.stops : nil
        var prev = -Self.stops
        for k in 1...count {
            let e = -Self.stops + Double(k) * step
            let now = inside(e)
            if now, open == nil { open = edge(prev, e) }
            if !now, let start = open { out.append(start...edge(prev, e)); open = nil }
            prev = e
        }
        if let start = open { out.append(start...Self.stops) }
        return out
    }

    /// A row of shares carried through the curve, as `placed_histogram` carries one through a
    /// placement: eight sub-steps a bin, each to the bin its stop lands in. `shift` puts the reply's
    /// axis on the film's (Film Exposure) and back. The estimate the output strip shows while the
    /// engine's own measurement of this curve is not in.
    func carried(_ row: [Double], from: Double, to: Double, shift: Double) -> [Double] {
        let n = row.count
        guard n > 1, to > from else { return row }
        guard !isIdentity else { return row }
        let width = (to - from) / Double(n), sub = 8
        var out = [Double](repeating: 0, count: n)
        for (b, share) in row.enumerated() where share != 0 {
            for k in 0..<sub {
                let e = from + (Double(b) + (Double(k) + 0.5) / Double(sub)) * width
                let landed = self(e + shift) - shift
                let to = Swift.min(Swift.max(Int(((landed - from) / width).rounded(.down)), 0), n - 1)
                out[to] += share / Double(sub)
            }
        }
        return out
    }
}

private extension CurveChannel {
    var isColourRow: Bool { self == .red || self == .green || self == .blue }
}

extension LatitudeReadout {
    /// RFC-051: the frame after the Decode curve as the tab reads it, as shares on the reply's bins,
    /// and whether it is the engine's measurement of exactly this curve (`exact`) or the app's
    /// estimate (the input carried through `transfer`). Nil without shares, or where the tab has no row.
    func output(for channel: CurveChannel, curve: CurveSet, exposureEV now: Double,
                transfer: DecodeTransfer) -> (row: [Double], exact: Bool)? {
        guard let shares else { return nil }
        let stamp = DecodeStamp(curve: curve, exposureEV: now)
        if measuredOn == stamp, let curved = shares.curved, let row = SceneShares.row(curved, for: channel) {
            return (row, true)
        }
        // With the identity and no placement the input is the output, exactly.
        if transfer.isIdentity, shares.curved == nil, let row = SceneShares.row(shares.input, for: channel) {
            return (row, true)
        }
        guard let row = SceneShares.row(shares.input, for: channel) else { return nil }
        return (transfer.carried(row, from: shares.from, to: shares.to, shift: exposureEV), false)
    }
}
