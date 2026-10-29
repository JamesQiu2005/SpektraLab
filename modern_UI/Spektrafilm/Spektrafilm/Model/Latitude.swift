//  Latitude.swift — what the Latitude section draws and what Scene Placement
//  commits, both read off one engine call (`spk_scene_latitude`, RFC-023).
//
//  The section is a measurement, never a setting: the medium's response is a
//  neutral ramp through the session's own film and paper, its boundaries are
//  the ISO 6846 range the Fit targets (RFC-023 §8.2), and the histogram is
//  the frame on the same stop axis. Nothing here is drawn by eye, which is
//  the point of it — a boundary that is not the model's would mislead exactly
//  the person the graph exists for.
//
//  **Scene Placement goes through the Fit, always.** A pull-back is UI state;
//  the curve the engine renders is what the Fit solved from it, and a pull-back
//  the Fit refuses (the extreme would still land past the print, the knees
//  would cross) is not committed.
//
//  **The sliders never ask for one, and do not ask the engine at all**
//  (1.3.2). The Fit accepts a window of pull-backs on each side, not
//  everything above zero, and a slider that offered the whole track and went
//  back on a refusal looked broken. Asking the engine per step was the other
//  half: the call queues behind the develop the previous step started, so the
//  knob's value arrived a render late. The solve is a few lines of arithmetic
//  on four numbers the last measurement already carries (`PlacementFit`,
//  pinned to the engine's own answers by `ScenePlacementTests`), so a slider
//  step is solved here, at once: its value is brought to the nearest
//  pull-back the Fit takes (`PlacementWindow`), the curve is committed in the
//  same call, and the row says why it stopped. The agent's `place` and a
//  pasted placement still go through the engine and get its refusal.

import Foundation

@MainActor
@Observable
final class LatitudeModel {
    /// The last probe, and the frame it was taken on. Kept while a newer one
    /// is on its way, so the graph does not blink on every edit.
    private(set) var reply: SceneLatitudeResponse?
    private(set) var frame: URL?
    /// Why the last placement was refused, if it was.
    private(set) var refusal: SceneLatitudeResponse.Fit.Issue?
    /// Why the frame on screen could not be measured, in words; nil when it
    /// was, or has not been tried. The section says this instead of going
    /// quietly blank.
    private(set) var failure: String?

    fileprivate var refreshTask: Task<Void, Never>?
    /// The Fit completing a pasted placement (RFC-027 §4.1), apart from the
    /// sliders' loop so a drag during it is not swallowed.
    fileprivate var pastedFitTask: Task<Void, Never>?

    fileprivate func take(_ reply: SceneLatitudeResponse, frame: URL) {
        self.reply = reply
        self.frame = frame
        failure = nil
    }

    fileprivate func fail(_ why: String, frame: URL) {
        reply = nil
        self.frame = frame
        failure = why
    }

    fileprivate func refuse(_ issue: SceneLatitudeResponse.Fit.Issue?) { refusal = issue }

    func clear() {
        refreshTask?.cancel()
        reply = nil; frame = nil; refusal = nil; failure = nil
    }

    /// The side a refusal is about, so each row shows only its own, in the
    /// interface's language (1.2.2). The engine's own sentence is English and
    /// speaks of "the medium"; the row says what to do and names the number
    /// the dimmed stretch of the slider already shows. A code this table does
    /// not know falls back to the engine's words rather than to nothing.
    func refusalMessage(for side: String) -> String? {
        guard let refusal, refusal.side == side || refusal.side == "both" else { return nil }
        return message(for: refusal, side: side)
    }

    /// One refusal in the interface's words, for the row it is about.
    func message(for refusal: SceneLatitudeResponse.Fit.Issue, side: String) -> String? {
        let top = side != "shadow"
        switch refusal.code {
        case "pull_back_below_minimum":
            let minimum = top ? reply?.fit.highlight.minimumPullBack : reply?.fit.shadow.minimumPullBack
            if let minimum, minimum > 0 {
                let n = String(format: "%.2f", minimum)
                return top
                    ? L("Pull back more than \(n) stops: any less still puts the scene's brightest part past the latitude's edge.",
                        zh: "回拉需大于 \(n) 档，否则场景最亮处仍在宽容度边界之外。")
                    : L("Pull back more than \(n) stops: any less still puts the scene's darkest part past the latitude's edge.",
                        zh: "回拉需大于 \(n) 档，否则场景最暗处仍在宽容度边界之外。")
            }
            return top
                ? L("Pull back further: the scene's brightest part is still past the latitude's edge.",
                    zh: "回拉不足，场景最亮处仍在宽容度边界之外。")
                : L("Pull back further: the scene's darkest part is still past the latitude's edge.",
                    zh: "回拉不足，场景最暗处仍在宽容度边界之外。")
        case "room_below_minimum":
            return top
                ? L("Pull back a little more: this close to the latitude's edge the highlights would turn too sharply.",
                    zh: "回拉再多一些：离宽容度边界太近，高光的过渡会过于生硬。")
                : L("Pull back a little more: this close to the latitude's edge the shadows would turn too sharply.",
                    zh: "回拉再多一些：离宽容度边界太近，阴影的过渡会过于生硬。")
        case PlacementWindow.noWindowCode:
            return top
                ? L("This frame's highlights cannot be pulled inside the latitude: no pull-back works here.",
                    zh: "这张照片的高光无法拉回宽容度之内，没有可用的回拉量。")
                : L("This frame's shadows are too far under the latitude's edge to be lifted inside it.",
                    zh: "这张照片的阴影低于宽容度边界太多，无法提升到宽容度之内。")
        case "out_of_range":
            return L("Pull back less: this is further than the curve can reach.",
                     zh: "回拉过多，已超出曲线可达的范围。")
        case "pull_back_exceeds_max_lift":
            return L("Pull back less: this is past the most the shadows can be lifted.",
                     zh: "回拉过多，已超出阴影可提升的上限。")
        case "knees_cross":
            return L("The highlight and shadow curves would cross: pull back less on one side.",
                     zh: "高光与阴影的曲线会交叉，请减少其中一侧的回拉。")
        default:
            return refusal.message
        }
    }
}

enum PlacementSide: String, Sendable { case highlight, shadow }

/// The pull-backs the Fit accepts on one side, with the other side held:
/// `least...most`, or nothing. Zero — the side off — is always accepted and
/// is not part of it.
///
/// Found by asking the Fit, not derived: the lower edge is the minimum plus
/// whatever the knee needs to turn (`room_below_minimum`), the upper one is
/// the lift bound or the other side's knee, and only the engine knows where
/// those fall on a given frame.
struct PlacementWindow: Equatable, Sendable {
    typealias Issue = SceneLatitudeResponse.Fit.Issue
    static let noWindowCode = "no_window"
    /// The sliders show two decimals, so the edges are whole hundredths: a
    /// value the row can show is a value the Fit takes.
    static let grain = 0.01

    /// Nil when no pull-back on this side is accepted.
    var span: ClosedRange<Double>?
    /// Why a value under `span` is refused, and one over it.
    var below: Issue
    var above: Issue?

    /// What the Fit said about one pull-back.
    enum Verdict: Equatable, Sendable { case valid, refused(Issue) }

    /// Where a slider's value lands: itself inside the window, the nearer edge
    /// outside it, and off when there is no window — with the reason it moved.
    func landing(_ asked: Double) -> (value: Double, why: Issue?) {
        guard asked > 0 else { return (0, nil) }
        guard let span else { return (0, below) }
        if asked < span.lowerBound { return (span.lowerBound, below) }
        if asked > span.upperBound { return (span.upperBound, above) }
        return (asked, nil)
    }

    /// `v` on the sliders' grid, as the nearest double to that hundredth.
    private static func hundredth(_ v: Double, _ rule: FloatingPointRoundingRule) -> Double {
        (v / grain).rounded(rule) / (1 / grain).rounded()
    }

    /// Search `range` for the window. The accepted pull-backs are one
    /// interval (room grows with the pull-back; the lift bound and the
    /// crossing knees only stop it from above), so: walk up from the minimum
    /// to the first accepted value, then bisect each edge. About twenty
    /// solves.
    static func search(side: PlacementSide, minimum: Double, in range: ClosedRange<Double>,
                       step: Double = 0.125,
                       verdict: (Double) -> Verdict) -> PlacementWindow {
        func own(_ i: Issue) -> Issue { Issue(code: i.code, side: side.rawValue, message: i.message) }
        var below = Issue(code: "pull_back_below_minimum", side: side.rawValue, message: "")
        var refusedAt = max(minimum, range.lowerBound, 0)
        var found: Double?
        var x = (refusedAt / step).rounded(.down) * step + step
        while x <= range.upperBound + 1e-9 {
            let v = verdict(x)
            if case .refused(let why) = v { below = own(why); refusedAt = x } else { found = x; break }
            x += step
        }
        guard let first = found else {
            return PlacementWindow(span: nil, below: Issue(code: noWindowCode, side: side.rawValue,
                                                           message: below.message))
        }

        // The lower edge, between the last refusal and the first acceptance.
        var bad = refusedAt, good = first
        while good - bad > grain / 2 {
            let mid = (bad + good) / 2
            let v = verdict(mid)
            if case .refused(let why) = v { below = own(why); bad = mid } else { good = mid }
        }
        let least = min(hundredth(good, .up), first)

        // The upper edge: the top of the track if the Fit takes it.
        var above: Issue?
        var most = range.upperBound
        let top = verdict(range.upperBound)
        if case .refused(let why) = top {
            above = own(why)
            good = first; bad = range.upperBound
            while bad - good > grain / 2 {
                let mid = (bad + good) / 2
                let v = verdict(mid)
                if case .refused(let why) = v { above = own(why); bad = mid } else { good = mid }
            }
            most = max(hundredth(good, .down), least)
        }
        return PlacementWindow(span: least...most, below: below, above: above)
    }
}

/// The Fit's solve (RFC-023 §9.2, §9.3, §15.5), here: `latitude_fit.cpp`'s
/// `fit()` on the four numbers a measurement carries, so a slider step does
/// not wait for the engine. **The engine's is the reference** — this is the
/// same arithmetic in the same order, and `ScenePlacementTests` holds it to
/// the engine's knees, rooms and refusals on a real frame. Change one, change
/// both.
enum PlacementFit {
    typealias Issue = SceneLatitudeResponse.Fit.Issue
    /// `kMinRoom` and `kDomainStops`.
    static let minRoom = 0.5, domainStops = 24.0

    /// What the solve reads off a measurement: each side's robust extreme and
    /// the medium's boundary, in stops from the metered mid-grey.
    struct Measured: Equatable, Sendable {
        var highlightExtreme: Double, highlightBoundary: Double
        var shadowExtreme: Double, shadowBoundary: Double

        init(_ fit: SceneLatitudeResponse.Fit) {
            highlightExtreme = fit.highlight.sceneExtremeEV; highlightBoundary = fit.highlight.mediumBoundaryEV
            shadowExtreme = fit.shadow.sceneExtremeEV; shadowBoundary = fit.shadow.mediumBoundaryEV
        }

        func minimum(_ side: PlacementSide) -> Double {
            side == .highlight ? highlightExtreme - highlightBoundary : shadowBoundary - shadowExtreme
        }
    }

    enum Outcome: Equatable, Sendable {
        case solved(SceneLatitudeSettings)
        case refused(Issue)
    }

    /// `g_m(D) - D`, in the forms that do not cancel near the knee.
    static func departure(_ D: Double, _ H: Double, _ m: Double) -> Double {
        guard D > 0 else { return 0 }
        if m == 2 {
            let r = (H * H + D * D).squareRoot()
            return -(D * D * D) / (r * (H + r))
        }
        if m == 1 { return -(D * D) / (H + D) }
        return D * (H / pow(pow(H, m) + pow(D, m), 1 / m) - 1)
    }

    /// The knee that lands the extreme `a` at `a - N` under the boundary `C`.
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

    /// The pull-backs solved into `base`'s curve, or the first thing the
    /// engine would refuse them for, in its order.
    static func fit(_ at: Measured, highlight: Double, shadow: Double,
                    base: SceneLatitudeSettings) -> Outcome {
        func issue(_ code: String, _ side: String) -> Issue { Issue(code: code, side: side, message: "") }
        let m = base.rolloff
        var issues: [Issue] = []
        var out = base
        out.active = true
        out.highlightPullBack = highlight
        out.shadowPullBack = shadow
        out.highlightRoom = 0
        out.shadowRoom = 0

        var top: (knee: Double, room: Double)?
        if highlight > 0 {
            if let K = solveKnee(at.highlightExtreme, at.highlightBoundary, highlight, m) {
                top = (K, at.highlightBoundary - K)
            } else {
                issues.append(issue("pull_back_below_minimum", "highlight"))
            }
        }

        // The shadow pull-back is the bounded landing: invert the lift bound,
        // then solve for the lift the bound brings back to it.
        var bottom: (knee: Double, room: Double)?
        var lift: Double?
        if shadow > 0, !(shadow > at.minimum(.shadow)) {
            issues.append(issue("pull_back_below_minimum", "shadow"))
        } else if shadow > 0 {
            let L = base.maxLift
            if shadow < L { lift = shadow * L / (L * L - shadow * shadow).squareRoot() }
            else { issues.append(issue("pull_back_exceeds_max_lift", "shadow")) }
        }
        if let lift {
            if let K = solveKnee(-at.shadowExtreme, -at.shadowBoundary, lift, m) {
                bottom = (-K, -K - at.shadowBoundary)
            } else {
                issues.append(issue("pull_back_below_minimum", "shadow"))
            }
        }

        for (side, name) in [(top, "highlight"), (bottom, "shadow")] {
            guard let side else { continue }
            if side.room < minRoom { issues.append(issue("room_below_minimum", name)) }
            if side.room > domainStops || abs(side.knee) > domainStops { issues.append(issue("out_of_range", name)) }
        }
        if let top, let bottom, !(bottom.knee < top.knee) { issues.append(issue("knees_cross", "both")) }
        if let first = issues.first { return .refused(first) }

        // Both sides off is the identity, and the engine's delta says so.
        out.active = top != nil || bottom != nil
        if let top { out.highlightKnee = top.knee; out.highlightRoom = top.room }
        if let bottom { out.shadowKnee = bottom.knee; out.shadowRoom = bottom.room }
        return .solved(out)
    }
}

/// The numbers the graph is drawn from, derived once per reply.
struct LatitudeReadout: Equatable {
    /// Bin centres and fractions on the stop axis; the placed histogram when
    /// the engine sent one.
    let centres: [Double]
    let fractions: [Double]
    let binWidth: Double
    let shadowEV: Double, highlightEV: Double
    let below: Double, within: Double, above: Double
    /// Lightness change per stop of the film + paper chain, over its peak:
    /// `(stop, 0…1)`. The separation band's opacity.
    let separation: [(ev: Double, strength: Double)]
    /// Where separation is at least half its peak — "full separation".
    let core: ClosedRange<Double>?

    static func == (a: LatitudeReadout, b: LatitudeReadout) -> Bool {
        a.fractions == b.fractions && a.shadowEV == b.shadowEV && a.highlightEV == b.highlightEV
    }

    init(_ r: SceneLatitudeResponse) {
        let h = r.scene.histogram
        let f = h.placedFractions ?? h.fractions
        let n = max(f.count, 1)
        binWidth = (h.hiEV - h.loEV) / Double(n)
        centres = (0..<f.count).map { h.loEV + (Double($0) + 0.5) * (h.hiEV - h.loEV) / Double(n) }
        fractions = f
        shadowEV = r.medium.shadowEV
        highlightEV = r.medium.highlightEV
        var b = 0.0, a = 0.0, total = 0.0
        for (c, v) in zip(centres, f) {
            total += v
            if c < shadowEV { b += v } else if c > highlightEV { a += v }
        }
        below = b; above = a; within = max(0, total - a - b)

        // CIE L* of the print against its own white, per ramp step.
        let white = max(r.medium.yWhite, 1e-9)
        func lstar(_ y: Double) -> Double {
            let t = max(y, 0) / white
            return t > 0.008856 ? 116 * pow(t, 1.0 / 3) - 16 : 903.3 * t
        }
        let ev = r.medium.rampEV, y = r.medium.rampY.map(lstar)
        var slopes: [(Double, Double)] = []
        for i in 0..<max(ev.count - 1, 0) where ev[i + 1] > ev[i] {
            slopes.append(((ev[i] + ev[i + 1]) / 2, max(0, (y[i + 1] - y[i]) / (ev[i + 1] - ev[i]))))
        }
        let peak = slopes.map(\.1).max() ?? 0
        separation = peak > 0 ? slopes.map { ($0.0, $0.1 / peak) } : []
        let full = separation.filter { $0.strength >= 0.5 }.map(\.ev)
        core = full.isEmpty ? nil : full.min()!...full.max()!
    }
}

extension Session {
    /// Re-measure after the canvas has a new print. Debounced: a scrub lands
    /// a render per step, and the probe only has to follow the one that
    /// settles. The medium and the scene are cached engine-side on the
    /// fields they read, so a probe after a Layer 2 or crop edit is cheap.
    func scheduleLatitudeRefresh() {
        latitude.refreshTask?.cancel()
        latitude.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.probeLatitude(highlight: self.params.sceneLatitude.highlightPullBack,
                                     shadow: self.params.sceneLatitude.shadowPullBack)
        }
    }

    /// The sliders' track, in stops of pull-back.
    nonisolated static let placementRange: ClosedRange<Double> = 0...8

    /// What a slider step is solved against: the last measurement of the
    /// frame on screen. Nil until it has been measured.
    var placementMeasure: PlacementFit.Measured? {
        guard let url = selection, latitude.frame == url, let fit = latitude.reply?.fit else { return nil }
        return PlacementFit.Measured(fit)
    }

    /// The pull-backs the Fit takes on one side with the other held at
    /// `other` — the band on that slider's track. Solved here each time it is
    /// asked (tens of microseconds), so it is never out of date.
    func placementWindow(for side: PlacementSide, other: Double) -> PlacementWindow? {
        guard let at = placementMeasure else { return nil }
        let base = params.sceneLatitude
        return PlacementWindow.search(side: side, minimum: at.minimum(side), in: Self.placementRange) { x in
            switch PlacementFit.fit(at, highlight: side == .highlight ? x : other,
                                    shadow: side == .shadow ? x : other, base: base) {
            case .solved: return .valid
            case .refused(let why): return .refused(why)
            }
        }
    }

    /// Scene Placement's two sliders: one step, solved and committed before
    /// this returns, like any other slider.
    ///
    /// `moving` is the slider under the hand. Its value is brought inside the
    /// window the Fit accepts, so a drag across a refused stretch rides its
    /// edge instead of committing nothing and springing back on release; the
    /// row keeps the reason it stopped there.
    func placeScene(highlight: Double, shadow: Double, moving: PlacementSide) {
        var h = max(0, highlight), s = max(0, shadow)
        guard let at = placementMeasure else { return }
        var why: SceneLatitudeResponse.Fit.Issue?
        if let window = placementWindow(for: moving, other: moving == .shadow ? h : s) {
            let landed = window.landing(moving == .shadow ? s : h)
            why = landed.why
            if moving == .shadow { s = landed.value } else { h = landed.value }
        }
        // Both sides off is the reset, which is not a Fit.
        if h == 0, s == 0 {
            if params.sceneLatitude.active { resetScenePlacement() }
            latitude.refuse(why)
            return
        }
        switch PlacementFit.fit(at, highlight: h, shadow: s, base: params.sceneLatitude) {
        case .solved(let placed):
            sidecar.placementNeedsFit = false
            var p = params
            p.sceneLatitude = placed
            params = p
            latitude.refuse(why)
        case .refused(let issue):
            // The side that is not moving no longer fits (the film changed
            // under it): nothing is committed, and the row says so.
            latitude.refuse(issue)
        }
    }

    /// Commit a fit, or keep its refusal. The one place a placement lands.
    private func commitPlacement(_ reply: SceneLatitudeResponse) {
        if reply.fit.valid {
            // The user has placed the scene themselves; a pasted placement
            // still waiting for its Fit is superseded.
            sidecar.placementNeedsFit = false
            var p = params
            p.sceneLatitude.apply(reply.fit)
            params = p
            latitude.refuse(nil)
        } else {
            latitude.refuse(reply.fit.issues.first)
        }
    }

    /// The agent layer's `latitude` (RFC-026): the same probe the section
    /// draws, at the frame's current placement, awaited. Nil when the frame
    /// cannot be measured; `latitude.failure` says why.
    func measureLatitude() async -> SceneLatitudeResponse? {
        await probeLatitude(highlight: params.sceneLatitude.highlightPullBack,
                            shadow: params.sceneLatitude.shadowPullBack)
    }

    /// The agent layer's `place`: one placement through the Fit, awaited, and
    /// committed exactly as a slider release commits it. Both at 0 is the
    /// reset, which is not a Fit and cannot be refused.
    func placeSceneNow(highlight: Double, shadow: Double) async -> SceneLatitudeResponse? {
        guard highlight > 0 || shadow > 0 else { resetScenePlacement(); return await measureLatitude() }
        guard let reply = await probeLatitude(highlight: max(0, highlight), shadow: max(0, shadow))
        else { return nil }
        commitPlacement(reply)
        return reply
    }

    /// Both sides off: the identity curve. Not a Fit — there is nothing to
    /// solve — so it cannot be refused.
    func resetScenePlacement() {
        sidecar.placementNeedsFit = false
        var p = params
        p.sceneLatitude = SceneLatitudeSettings()
        params = p
        latitude.refuse(nil)
    }

    /// Fit a pasted Scene Placement on *this* frame (RFC-027 §4.1).
    ///
    /// A paste carries the pull-back, never the source's curve, so the frame
    /// renders the identity until this lands. It runs from `applyRender` and
    /// right after a live paste, and only once the engine has every pasted
    /// field (`!scheduler.pending`) — the Fit reads the medium and the scene
    /// the session holds, and fitting against the old film would be the
    /// defect this replaces. A refusal leaves the placement off, with the
    /// reason where the section already shows one.
    func resolvePendingPlacement() {
        guard sidecar.placementNeedsFit, serviceReady, serviceSessionIDForExport != nil,
              !scheduler.pending, latitude.pastedFitTask == nil, let url = selection else { return }
        let want = params.sceneLatitude
        latitude.pastedFitTask = Task { [weak self] in
            guard let self else { return }
            defer { self.latitude.pastedFitTask = nil }
            let reply = await self.probeLatitude(highlight: want.highlightPullBack,
                                                 shadow: want.shadowPullBack)
            // Superseded: another frame, or the user placed it meanwhile.
            guard self.selection == url, self.sidecar.placementNeedsFit,
                  self.params.sceneLatitude == want else { return }
            var placed = want
            if let reply, placed.apply(reply.fit) {
                self.latitude.refuse(nil)
            } else {
                if let reply { self.latitude.refuse(reply.fit.issues.first) }
                placed.highlightPullBack = 0
                placed.shadowPullBack = 0
            }
            self.finishPastedPlacement(placed)
        }
    }

    /// The Fit's request for these pull-backs on the frame the section is
    /// about.
    private func latitudeRequest(highlight: Double, shadow: Double) -> SceneLatitudeRequest {
        var request = params.sceneLatitude.request
        request.region = pairFitRegion
        request.highlightPullBack = highlight
        request.shadowPullBack = shadow
        return request
    }

    @discardableResult
    private func probeLatitude(highlight: Double, shadow: Double) async -> SceneLatitudeResponse? {
        guard serviceReady, let url = selection, serviceSessionIDForExport != nil else { return nil }
        let request = latitudeRequest(highlight: highlight, shadow: shadow)
        do {
            let reply = try await client.sceneLatitude(request)
            guard selection == url else { return nil }
            latitude.take(reply, frame: url)
            return reply
        } catch {
            // Say why, rather than going blank. The engine's two expected
            // refusals get plain words; anything else is passed on as it is.
            // Not cached engine-side, so the probe tries again after the next
            // render — cheap (~6 ms measured), and right once the pair changes.
            guard selection == url else { return nil }
            let text = "\(error)"
            let why = text.contains("boundaries do not lie inside") ? L(.latitudeUnmeasurable)
                    : text.contains("no positive pixels") ? L(.latitudeNoLight)
                    : text
            latitude.fail(why, frame: url)
            return nil
        }
    }
}
