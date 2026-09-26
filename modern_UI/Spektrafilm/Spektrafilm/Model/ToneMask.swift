//  ToneMask.swift — RFC-024's gain curve, for the Tone Mask section's plot.
//
//  The engine's mask is **global**: one Gaussian base over the whole frame's
//  paper exposure (`scale` of the long edge), and then this one curve from
//  that base to a change in exposure. So the curve is the whole of what the
//  controls decide — the picture only decides where on it each region sits —
//  and drawing it is drawing the mask, not an impression of one.
//
//  A transcription of `contrast_mask.cpp` (`room_for`, `delta_at`), not a
//  second model: `ToneMaskTests` pins the calibration the engine documents
//  (an amount of N stops moves a base `reach` stops past the core by N), so a
//  change to the engine's constants has to be made here too.

import Foundation

enum ToneMaskCurve {
    /// `kReach`: where each branch's amount is read off, stops past its knee.
    static let reach = 4.0
    /// `kGainLimit`: the smooth bound on the change, stops.
    static let gainLimit = 6.0

    /// The branch's room such that, after the bound, a base `reach` past the
    /// knee moves by exactly `amount`.
    static func room(for amount: Double) -> Double {
        let L = gainLimit, R = reach
        let delta = amount * L / (L * L - amount * amount).squareRoot()
        let t = max(R - delta, 1e-3)
        return R * t / (R * R - t * t).squareRoot()
    }

    /// The change in paper exposure, stops, at a base `base` stops from the
    /// negative's mid-grey. Positive raises exposure (the print's highlights,
    /// which sit at low exposure, gain density); negative lowers it.
    static func delta(atBase base: Double, _ m: ContrastMaskSettings) -> Double {
        let kLo = -m.core, kHi = m.core
        var d = 0.0
        if m.highlights > 0, base < kLo {
            let D = kLo - base, H = room(for: m.highlights)
            d = D - D * H / (H * H + D * D).squareRoot()
        } else if m.shadows > 0, base > kHi {
            let D = base - kHi, S = room(for: m.shadows)
            d = D * S / (S * S + D * D).squareRoot() - D
        }
        return d * gainLimit / (gainLimit * gainLimit + d * d).squareRoot()
    }
}
