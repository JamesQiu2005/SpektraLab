//  HDRSessionCurve.swift — Enable HDR's curve, the session's own: what the app asks `spk_session_hdr_curve`
//  and what it keeps of the answer (HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D1, D5, D6).
//
//  A fixed curve per film and paper baked at product defaults (minilab off) would ignore the session's paper,
//  minilab and enlarger. The engine computes the curve of the session instead (API-SPEC §19.2): family A on the
//  medium `spk_scene_latitude` probes — the film, the paper, minilab, the enlarger — and the grain-aware tables
//  over it (Ks, ρ). So:
//
//  - **Asked at develop time, on the engine's queue** (`SpkEngine.render`, after the render, on the job's own
//    session: §19.2's "the same serial queue as its renders" — a cache miss runs the GPU probe, and two
//    sessions driven at once abort the process). The page's canvas asks with a develop where it draws that
//    develop's HDR (`EngineRouter.curveWithDevelop`, `EngineHost.Request.hdrCurve`); a call is the session's cache
//    (0.3 ms) unless the medium's probe key moved — and it holds Print Exposure and the filters, so a print-side
//    step re-probes (an Endura step 9.5–10.6 ms on a 23 ms live render: the 2026-11-06 review). Elsewhere the page
//    asks for it alone (`EngineRouter.hdrCurve`, `OpenFrameSession.askCurve`): once an edit settles, after the
//    `spk_scene_latitude` whose probe it shares, and when the switch is turned on — a print's Enable HDR changes
//    no develop (D3), so that ask is what gives it the curve of the edit as it stands.
//  - **Carried with the picture it is of** (`EngineHost.Delivery.hdrCurve`, before its `.canvas`, taken with it in
//    one turn) and kept by the page's session (`OpenFrameSession.hdr`): the canvas and the histogram read that,
//    never a live engine.
//  - **A refusal is an answer** (`Answer.refused`, the engine's words): a Digital Intermediate, the engine's
//    EDR stretch on a print, a medium family A cannot model. The switch is greyed for it (a control that
//    changes nothing would lie); the words go to the log.
//
//  **`clip_ev` is not sent this round** (plain family A; D2's clip-aware ease is measured
//  first). The hook is `request(clipEV:)`: its axis is `spk_scene_latitude`'s (stops over the metered mid-grey,
//  before Exp. Comp.), and a frame with Scene Placement or a Decode curve has to map its clip through them.
//
//  No UIKit, no engine: the reply is parsed from its JSON, so the macOS checks compile it.

import Foundation

struct HDRSessionCurve: Equatable, Sendable {
    /// The curve (`log2_gain`), named by the model and a digest of its tables: a curve that moved with the
    /// medium is another look (`HDRLook ==`).
    var curve: HDRGainCurve
    /// The kernels' tables (`ks`, `rho`, κ, ρmax), over the curve's domain.
    var tables: HDRGrainGain.Tables
    /// The engine's own words for what it modelled, for the log: the model's identity, the knee (on the
    /// request's axis and as the picture's log2 Y), the ramp's white, γ₀, the Exp. Comp. it was asked under,
    /// and whether the session scans.
    var version: String
    var kneeEV: Double
    var kneeLog2Y: Double
    var yWhite: Double
    var gamma0: Double
    var exposureEV: Double
    var scan: Bool

    /// What the engine said for a session: its curve, or why there is none.
    enum Answer: Equatable, Sendable {
        case curve(HDRSessionCurve)
        case refused(String)

        var curve: HDRSessionCurve? { if case .curve(let c) = self { c } else { nil } }
    }

    /// H the app asks for by default: two stops over SDR white, `A_H4` (the export's headroom). A frame's
    /// own is its HDR Peak Brightness (`FrameEdit.hdrHeadroom`, PRD-B 2026-11-09).
    static let headroom = 4.0

    /// The request for `edit`'s curve: its own H.
    static func request(for edit: FrameEdit) -> String { request(headroom: edit.hdrHeadroom) }

    /// The request `spk_session_hdr_curve` takes. `clipEV` is the D2 hook (the header): nil sends none, the
    /// plain curve; never given this round.
    static func request(headroom: Double = headroom, clipEV: Double? = nil) -> String {
        var fields = [String(format: "\"headroom\":%.6f", headroom)]
        if let clipEV, clipEV.isFinite { fields.append(String(format: "\"clip_ev\":%.6f", clipEV)) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    enum Failure: Error, CustomStringConvertible {
        case reply(String)
        var description: String { if case .reply(let s) = self { "the HDR curve's reply: \(s)" } else { "" } }
    }

    /// The engine's reply (§19.2), held to what it says of itself: 256 samples each, the domain [-12, 0],
    /// `top` = log2 H = the last sample. Refused, not mended, as every curve is.
    static func parse(_ json: String) throws -> HDRSessionCurve {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw Failure.reply("not JSON")
        }
        func number(_ k: String) throws -> Double {
            guard let v = (o[k] as? NSNumber)?.doubleValue, v.isFinite else { throw Failure.reply("no \(k)") }
            return v
        }
        func samples(_ k: String) throws -> [Double] {
            guard let a = o[k] as? [NSNumber], a.count == HDRGainCurve.count else { throw Failure.reply("\(k) is not \(HDRGainCurve.count) numbers") }
            let v = a.map(\.doubleValue)
            guard v.allSatisfy(\.isFinite) else { throw Failure.reply("\(k) is not finite") }
            return v
        }
        let headroom = try number("headroom"), top = try number("top")
        let gain = try samples("log2_gain"), ks = try samples("ks"), rho = try samples("rho")
        guard let domain = (o["domain_log2_y"] as? [NSNumber])?.map(\.doubleValue), domain.count == 2 else {
            throw Failure.reply("no domain_log2_y")
        }
        guard abs(top - log2(headroom)) < 1e-9, abs((gain.last ?? 0) - top) < 1e-9 else {
            throw Failure.reply("top \(top) is not log2 \(headroom) and the last sample")
        }
        let version = (o["version"] as? String) ?? "?"
        var curve = HDRGainCurve(name: "", domainLog2Y: domain, headroom: headroom, log2Gain: gain)
        try curve.validate()
        // The digest names the look; the model's long identity is `version`, said in the log beside it.
        curve.name = "session " + digest(gain, ks, rho)
        let tables = HDRGrainGain.Tables(ks: ks.map(Float.init), slope: rho.map(Float.init), lo: domain[0], hi: domain[1],
                                         top: top, kappa: try number("kappa"), rhoMax: try number("rho_max"),
                                         tau: try number("detail_clamp"))
        return HDRSessionCurve(curve: curve, tables: tables, version: version,
                               kneeEV: (o["knee_ev"] as? NSNumber)?.doubleValue ?? .nan,
                               kneeLog2Y: (o["knee_log2_y"] as? NSNumber)?.doubleValue ?? .nan,
                               yWhite: (o["y_white"] as? NSNumber)?.doubleValue ?? .nan,
                               gamma0: (o["gamma0"] as? NSNumber)?.doubleValue ?? .nan,
                               exposureEV: (o["exposure_ev"] as? NSNumber)?.doubleValue ?? 0,
                               scan: (o["scan"] as? Bool) ?? false)
    }

    /// A short, stable word for the tables (FNV-1a over the samples' bits): the same curve has the same name in
    /// every run, so a log line can be compared across launches.
    static func digest(_ arrays: [Double]...) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for a in arrays { for v in a { var b = v.bitPattern; for _ in 0..<8 { h = (h ^ (b & 0xff)) &* 0x100000001b3; b >>= 8 } } }
        return String(h, radix: 16)
    }

    /// The log's line for it: where the knee is, the white, the curve's own name.
    var said: [String: Any] {
        ["curve": curve.name, "model": version, "knee_ev": (kneeEV * 1000).rounded() / 1000, "knee_log2_y": (kneeLog2Y * 1000).rounded() / 1000,
         "y_white": (yWhite * 10000).rounded() / 10000, "gamma0": (gamma0 * 1000).rounded() / 1000,
         "exposure_ev": exposureEV, "scan": scan, "headroom": curve.headroom]
    }
}

extension FrameEdit {
    /// Whether Enable HDR can do anything for this frame on this page: the film applied, a system that writes
    /// gain maps, and a curve the engine gave for its session (`answer`, the page's `OpenFrameSession.hdr`). The
    /// switch is greyed where not.
    func hdrAvailable(_ answer: HDRSessionCurve.Answer?) -> Bool {
        appliesFilm && HDRGainMap.supported && answer?.curve != nil
    }
}
