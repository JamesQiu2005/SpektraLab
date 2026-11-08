import Foundation

enum CanvasZoom {
    static func scale(base: CGFloat, magnification: CGFloat, limit: CGFloat) -> CGFloat {
        guard magnification.isFinite, magnification > 0 else { return min(max(base, 0.6), limit) }
        var z = base * magnification
        if z < 1 { z = 1 - (1 - z) * 0.5 }
        // Finger replacement / tiny initial separation can yield a very
        // large scale. A rubber band must stay bounded while fingers remain
        // down, rather than relying on onEnded to repair an enormous frame.
        if z > limit { z = min(limit + (z - limit) * 0.35, limit * 1.15) }
        return max(z, 0.6)
    }

    /// Where `scale`'s rubber band stops moving: below it a pinch or a scroll changes nothing more.
    static let bandLow: CGFloat = 0.2            // 1 − (1 − z)·0.5 reaches 0.6 at z = 0.2
    static func bandHigh(limit: CGFloat) -> CGFloat { limit / 0.7 }   // limit + (z − limit)·0.35 reaches 1.15·limit

    /// A scroll session's travel, less what it has spent past the band's stops (2026-11-05): a wheel
    /// spun on past the largest zoom kept adding travel, and a turn back did nothing until it had all
    /// been paid back — 189 clicks in a measured case. The travel past a stop is dropped as it comes,
    /// so the first click the other way answers. `origin` is the session's dropped travel so far
    /// (0 at its start); `perPoint` the travel's exponent (`exp(travel · perPoint)` is the magnification).
    static func heldTravel(_ travel: CGFloat, origin: CGFloat, base: CGFloat, limit: CGFloat,
                           perPoint: CGFloat = 0.006) -> (travel: CGFloat, origin: CGFloat) {
        guard base > 0, base.isFinite, travel.isFinite, origin.isFinite else { return (travel - origin, origin) }
        let t = travel - origin
        let raw = base * exp(t * perPoint)
        if raw > bandHigh(limit: limit) {
            let kept = log(bandHigh(limit: limit) / base) / perPoint
            return (kept, travel - kept)
        }
        if raw < bandLow {
            let kept = log(bandLow / base) / perPoint
            return (kept, travel - kept)
        }
        return (t, origin)
    }
}
