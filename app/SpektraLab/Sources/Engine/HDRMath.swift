//  HDRMath.swift — Enable HDR's shared arithmetic: the gain curve and the colour helpers every HDR file reads
//  (HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D1/D5/D6).
//
//  The Mac has no Light Table HDR this round (D6), so the pure part is here, apart from any table: `HDRGrainGain`,
//  `HDRRendition`, `HDRLook` and `HDRGain` read it. A later port of the table's HDR takes these from here, not
//  from a copy of its own.
//
//  **Where a curve comes from** (D1): no fixed per-pair curves are bundled; the engine computes the session's
//  own (`spk_session_hdr_curve`, API-SPEC §19.2) and the app keeps what it said (`HDRSessionCurve`). The curve's
//  shape and its reading are the research's file shape. No UIKit: the macOS checks compile it.

import Foundation

/// The colour helpers the HDR kernels' Swift references use.
enum HDRMath {
    /// Display P3's transfer (sRGB's), extended past 1 and mirrored below 0: encoded → linear.
    static func decode(_ v: Double) -> Double {
        let a = abs(v)
        let l = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -l : l
    }

    /// Linear → encoded, the same transfer.
    static func encode(_ l: Double) -> Double {
        let a = abs(l)
        let v = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return l < 0 ? -v : v
    }

    /// Display P3's luminance (Y of its RGB → XYZ, D65).
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2289746 * r + 0.6917385 * g + 0.0792869 * b }

    /// A half float's bits as a float (IEEE 754 binary16): the GPU's readback, with no `Float16` — which the
    /// x86_64 slice of a Release build does not have (the critic, 2026-11-06: Debug builds the active arch only,
    /// so only Release would fail).
    static func half(_ bits: UInt16) -> Float {
        let sign: Float = bits & 0x8000 != 0 ? -1 : 1
        let e = Int((bits >> 10) & 0x1F), m = Float(bits & 0x3FF)
        if e == 0 { return sign * m * 0x1p-24 }
        if e == 31 { return m == 0 ? sign * .infinity : .nan }
        return sign * (1 + m / 1024) * Float(sign: .plus, exponent: e - 15, significand: 1)
    }
}

/// A gain curve: a film and paper's gain by a pixel's own brightness (the research's
/// file shape, `rfc/audits/hdr-density-2026-11-03`).
///
/// - `log2Gain`: 256 values of log2 gain, evenly over log2 Y from `domainLog2Y[0]` to `[1]`, Y the SDR pixel's
///   Display P3 luminance in linear light (1 = SDR white). Below the domain the first value, above it the last.
/// - Each value in 0 … log2 H; anything else is refused, never mended.
/// - `name` is the curve's identity (two looks are the same look when their names and headrooms agree,
///   `HDRLook`): here the engine's model version and a digest of its tables (`HDRSessionCurve`), so a curve
///   that moved with the session's medium is another look.
struct HDRGainCurve: Codable, Equatable, Sendable {
    static let count = 256

    var name: String
    var domainLog2Y: [Double]
    /// H: the headroom the curve was written for; `log2Gain` ≤ log2 H. Its gain map's HDRCapacityMax is log2 H.
    var headroom: Double
    var log2Gain: [Double]
    var note: String?

    enum CodingKeys: String, CodingKey { case name, domainLog2Y = "domain_log2_y", headroom, log2Gain = "log2_gain", note }

    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let s) = self { "not a gain curve: \(s)" } else { "" } }
    }

    init(name: String, domainLog2Y: [Double] = [-12, 0], headroom: Double, log2Gain: [Double], note: String? = nil) {
        self.name = name; self.domainLog2Y = domainLog2Y; self.headroom = headroom; self.log2Gain = log2Gain; self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        domainLog2Y = try c.decodeIfPresent([Double].self, forKey: .domainLog2Y) ?? [-12, 0]
        headroom = try c.decode(Double.self, forKey: .headroom)
        log2Gain = try c.decode([Double].self, forKey: .log2Gain)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        try validate()
    }

    /// Refused, not mended: a curve that is not what it says is not drawn.
    func validate() throws {
        guard log2Gain.count == Self.count else { throw Failure.invalid("\(log2Gain.count) values, not \(Self.count)") }
        guard domainLog2Y.count == 2, domainLog2Y.allSatisfy(\.isFinite), domainLog2Y[0] < domainLog2Y[1]
        else { throw Failure.invalid("domain \(domainLog2Y)") }
        guard headroom.isFinite, headroom >= 1 else { throw Failure.invalid("headroom \(headroom)") }
        let top = log2(headroom) + 1e-9
        guard let bad = log2Gain.firstIndex(where: { !$0.isFinite || $0 < -1e-9 || $0 > top }) else { return }
        throw Failure.invalid("log2_gain[\(bad)] is \(log2Gain[bad]), not in 0 … log2 \(headroom)")
    }

    /// The curve's gain at a luminance, read as the GPU reads it: position on log2 Y, clamped, then the
    /// gain linear between samples (in Float's values, as the GPU holds them).
    func gain(y: Double) -> Double {
        let lo = domainLog2Y[0], hi = domainLog2Y[1]
        let x = min(1, max(0, (log2(max(y, 1e-30)) - lo) / (hi - lo))) * Double(Self.count - 1)
        let i0 = min(Int(x.rounded(.down)), Self.count - 2)
        let t = x - Double(i0)
        let a = Double(Float(exp2(log2Gain[i0]))), b = Double(Float(exp2(log2Gain[i0 + 1])))
        return a + (b - a) * t
    }
}
