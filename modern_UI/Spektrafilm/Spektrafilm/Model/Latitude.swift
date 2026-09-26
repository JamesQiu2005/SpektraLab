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
//  would cross) is not committed. The refusal is kept and shown on the row,
//  in the engine's words, instead of the slider silently snapping.

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
    fileprivate var pendingPlacement: (highlight: Double, shadow: Double)?

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

    /// The side a refusal is about, so each row shows only its own.
    func refusalMessage(for side: String) -> String? {
        guard let refusal, refusal.side == side || refusal.side == "both" else { return nil }
        return refusal.message
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
    func placeScene(highlight: Double, shadow: Double) {
        latitude.pendingPlacement = (max(0, highlight), max(0, shadow))
        guard latitude.placementTask == nil else { return }
        latitude.placementTask = Task { [weak self] in
            while let self, let want = self.latitude.pendingPlacement {
                self.latitude.pendingPlacement = nil
                guard let reply = await self.probeLatitude(highlight: want.highlight, shadow: want.shadow)
                else { break }
                self.commitPlacement(reply)
            }
            self?.latitude.placementTask = nil
        }
    }

    /// Commit a fit, or keep its refusal. The one place a placement lands.
    private func commitPlacement(_ reply: SceneLatitudeResponse) {
        if reply.fit.valid {
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
        var p = params
        p.sceneLatitude = SceneLatitudeSettings()
        params = p
        latitude.refuse(nil)
    }

    @discardableResult
    private func probeLatitude(highlight: Double, shadow: Double) async -> SceneLatitudeResponse? {
        guard serviceReady, let url = selection, serviceSessionIDForExport != nil else { return nil }
        var request = params.sceneLatitude.request
        request.highlightPullBack = highlight
        request.shadowPullBack = shadow
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
