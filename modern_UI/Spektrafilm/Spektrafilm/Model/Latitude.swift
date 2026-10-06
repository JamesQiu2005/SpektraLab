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
//  **The sliders never ask for one** (1.3.2). The Fit accepts a window of
//  pull-backs on each side, not everything above zero: under the minimum the
//  extreme still lands past the edge, just over it the knee has no room to
//  turn, and at the top the shadow lift or the other side's knee stops it. A
//  slider that offered the whole track and returned to its last value on a
//  refusal looked broken, and on a frame with a narrow window it was — so a
//  slider's value is brought to the nearest pull-back the Fit takes
//  (`PlacementWindow`) before it is asked for, and the row says why it
//  stopped. The agent's `place` still gets the refusal itself.

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
    fileprivate var placementTask: Task<Void, Never>?
    fileprivate var pendingPlacement: (highlight: Double, shadow: Double, moving: PlacementSide)?
    /// The Fit completing a pasted placement (RFC-027 §4.1), apart from the
    /// sliders' loop so a drag during it is not swallowed.
    fileprivate var pastedFitTask: Task<Void, Never>?

    /// The pull-backs the Fit takes on each side, searched the first time a
    /// slider is touched and kept while what they were searched against holds.
    private(set) var windows: [PlacementSide: (key: PlacementWindow.Key, window: PlacementWindow)] = [:]

    fileprivate func keep(_ window: PlacementWindow, for key: PlacementWindow.Key) {
        windows[key.side] = (key, window)
    }

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
        windows = [:]
    }

    /// The side a refusal is about, so each row shows only its own, in the
    /// interface's language (1.2.2). The engine's own sentence is English and
    /// speaks of "the medium"; the row says what to do and names the number
    /// the dimmed stretch of the slider already shows. A code this table does
    /// not know falls back to the engine's words rather than to nothing.
    func refusalMessage(for side: String) -> String? {
        guard let refusal, refusal.side == side || refusal.side == "both" else { return nil }
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

    /// Everything a search depends on. A window is good for exactly as long
    /// as this is unchanged.
    struct Key: Equatable, Sendable {
        var side: PlacementSide
        var frame: URL
        var minimum: Double
        var boundary: Double
        var other: Double
        var request: SceneLatitudeRequest
    }

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

    /// The stretches of `range` a slider cannot rest on, for the track.
    func blocked(in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard let span else { return [range] }
        var out: [ClosedRange<Double>] = []
        if span.lowerBound - Self.grain > range.lowerBound { out.append(range.lowerBound...span.lowerBound) }
        if span.upperBound < range.upperBound { out.append(span.upperBound...range.upperBound) }
        return out
    }

    /// `v` on the sliders' grid, as the nearest double to that hundredth.
    private static func hundredth(_ v: Double, _ rule: FloatingPointRoundingRule) -> Double {
        (v / grain).rounded(rule) / (1 / grain).rounded()
    }

    /// What is known without asking: nothing under the minimum, and for the
    /// shadows nothing at or past the lift bound. Drawn until a search lands.
    static func known(side: PlacementSide, minimum: Double, maxLift: Double,
                      in range: ClosedRange<Double>) -> PlacementWindow {
        let low = hundredth(max(minimum, 0) + grain, .down)
        let high = side == .shadow ? min(range.upperBound, hundredth(maxLift - grain, .up))
                                   : range.upperBound
        guard low <= high else {
            return PlacementWindow(span: nil, below: Issue(code: noWindowCode, side: side.rawValue, message: ""))
        }
        return PlacementWindow(span: low...high,
                               below: Issue(code: "pull_back_below_minimum", side: side.rawValue, message: ""),
                               above: side == .shadow && high < range.upperBound
                                   ? Issue(code: "pull_back_exceeds_max_lift", side: side.rawValue, message: "") : nil)
    }

    /// Search `range` for the window. The accepted pull-backs are one
    /// interval (room grows with the pull-back; the lift bound and the
    /// crossing knees only stop it from above), so: walk up from the minimum
    /// to the first accepted value, then bisect each edge. About twenty
    /// probes; nil if one could not be made.
    @MainActor
    static func search(side: PlacementSide, minimum: Double, in range: ClosedRange<Double>,
                       step: Double = 0.125,
                       verdict: @MainActor (Double) async -> Verdict?) async -> PlacementWindow? {
        func own(_ i: Issue) -> Issue { Issue(code: i.code, side: side.rawValue, message: i.message) }
        var below = Issue(code: "pull_back_below_minimum", side: side.rawValue, message: "")
        var refusedAt = max(minimum, range.lowerBound, 0)
        var found: Double?
        var x = (refusedAt / step).rounded(.down) * step + step
        while x <= range.upperBound + 1e-9 {
            guard let v = await verdict(x) else { return nil }
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
            guard let v = await verdict(mid) else { return nil }
            if case .refused(let why) = v { below = own(why); bad = mid } else { good = mid }
        }
        let least = min(hundredth(good, .up), first)

        // The upper edge: the top of the track if the Fit takes it.
        var above: Issue?
        var most = range.upperBound
        guard let top = await verdict(range.upperBound) else { return nil }
        if case .refused(let why) = top {
            above = own(why)
            good = first; bad = range.upperBound
            while bad - good > grain / 2 {
                let mid = (bad + good) / 2
                guard let v = await verdict(mid) else { return nil }
                if case .refused(let why) = v { above = own(why); bad = mid } else { good = mid }
            }
            most = max(hundredth(good, .down), least)
        }
        return PlacementWindow(span: least...most, below: below, above: above)
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

    /// Scene Placement's two sliders. Latest wins: a drag queues its newest
    /// value while the previous Fit is still out, and the loop commits
    /// whatever is newest when it gets back.
    ///
    /// `moving` is the slider under the hand. Its value is brought inside the
    /// window the Fit accepts before it is asked for, so a drag across a
    /// refused stretch rides its edge instead of committing nothing and
    /// springing back on release; the row keeps the reason it stopped there.
    func placeScene(highlight: Double, shadow: Double, moving: PlacementSide) {
        latitude.pendingPlacement = (max(0, highlight), max(0, shadow), moving)
        guard latitude.placementTask == nil else { return }
        latitude.placementTask = Task { [weak self] in
            while let self, var want = self.latitude.pendingPlacement {
                self.latitude.pendingPlacement = nil
                let asked = want.moving == .shadow ? want.shadow : want.highlight
                var why: SceneLatitudeResponse.Fit.Issue?
                if asked > 0, let window = await self.placementWindow(
                    for: want.moving, other: want.moving == .shadow ? want.highlight : want.shadow) {
                    let landed = window.landing(asked)
                    why = landed.why
                    if want.moving == .shadow { want.shadow = landed.value } else { want.highlight = landed.value }
                }
                // Both sides off is the reset, which is not a Fit.
                if want.highlight == 0, want.shadow == 0 {
                    if self.params.sceneLatitude.active { self.resetScenePlacement() }
                    self.latitude.refuse(why)
                    continue
                }
                guard let reply = await self.probeLatitude(highlight: want.highlight, shadow: want.shadow)
                else { break }
                self.commitPlacement(reply)
                if reply.fit.valid { self.latitude.refuse(why) }
            }
            self?.latitude.placementTask = nil
        }
    }

    /// Run `body` once the sliders' loop has committed everything it was
    /// given — at once when it is idle. A slider lets go of the value under
    /// the pointer here, not on release: the Fit for a release is still out
    /// then, and showing the committed value in between is the knob jumping
    /// back and forward again.
    func whenPlacementSettles(_ body: @escaping @MainActor () -> Void) {
        guard let task = latitude.placementTask else { body(); return }
        Task { await task.value; body() }
    }

    /// The sliders' track, in stops of pull-back.
    nonisolated static let placementRange: ClosedRange<Double> = 0...8

    /// Where a slider's value will land, from what is known now: the searched
    /// window when it is current, else the minimum and the lift bound. For the
    /// knob while the pointer is down; `placeScene` decides what is committed.
    func placementWindowNow(for side: PlacementSide, other: Double) -> PlacementWindow? {
        guard let key = placementKey(for: side, other: other) else { return nil }
        if let kept = latitude.windows[side], kept.key == key { return kept.window }
        return .known(side: side, minimum: key.minimum, maxLift: params.sceneLatitude.maxLift,
                      in: Self.placementRange)
    }

    private func placementKey(for side: PlacementSide, other: Double) -> PlacementWindow.Key? {
        guard let url = selection, latitude.frame == url, let fit = latitude.reply?.fit else { return nil }
        let own = side == .shadow ? fit.shadow : fit.highlight
        var request = latitudeRequest(highlight: 0, shadow: 0)
        request.highlightPullBack = nil
        request.shadowPullBack = nil
        return PlacementWindow.Key(side: side, frame: url, minimum: own.minimumPullBack,
                                   boundary: own.mediumBoundaryEV, other: other, request: request)
    }

    /// The window for one side with the other held at `other`, searched if
    /// what is kept was searched against something else. Its probes are not
    /// taken as the section's measurement, so the graph does not move.
    func placementWindow(for side: PlacementSide, other: Double) async -> PlacementWindow? {
        guard serviceReady, serviceSessionIDForExport != nil,
              let key = placementKey(for: side, other: other) else { return nil }
        if let kept = latitude.windows[side], kept.key == key { return kept.window }
        let client = client
        let window = await PlacementWindow.search(side: side, minimum: key.minimum, in: Self.placementRange) { x in
            var request = key.request
            request.highlightPullBack = side == .highlight ? x : other
            request.shadowPullBack = side == .shadow ? x : other
            guard let fit = try? await client.sceneLatitude(request).fit else { return nil }
            if fit.valid { return .valid }
            return fit.issues.first.map { .refused($0) }
        }
        // Good only if nothing it was searched against moved meanwhile.
        guard let window, placementKey(for: side, other: other) == key else { return nil }
        latitude.keep(window, for: key)
        return window
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
