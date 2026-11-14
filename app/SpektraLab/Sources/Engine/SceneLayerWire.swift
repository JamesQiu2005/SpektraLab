//  SceneLayerWire.swift — an edit's 场景 layers, as the engine takes them (RFC-052 §6, API-SPEC §23).
//
//  The 场景 stage is a local amount of Film Exposure, and of a filter on the light, before the film. The engine's node
//  (`scene_layers.metal`) reads, per layer, a 16-bit plane in S, a gain at full coverage and a coverage, and one
//  matrix from the handed frame to S; the wire names the set by a stamp. This is the host's side of that:
//
//  - **the gain** (`logGain`, RFC-052 §6.1): gᵢ = eᵢ·ln2·(1, 1, 1) + ln w(τᵢ, νᵢ), the natural log of a gain on the
//    cone responses of C = M_CAT16 · M_(ProPhoto → XYZ). An exposure alone is three *equal* floats, which keeps the
//    node on its scalar path — the same operation as Film Exposure, so a full-mask layer of e stops is Film Exposure
//    + e between two scalar gains (§10.1);
//  - **the white** w(τ, ν): the cone responses of the working white over those of a white moved along the Planckian
//    locus by −a·τ mired and across it by b·ν Duv, scaled so the working white's luminance is unchanged (positive τ
//    amber, positive ν magenta, as Edit's 色温 and 色调 read). `a` and `b` are fixed below, with how;
//  - **the planes**: baked by `MaskBaker` on the engine's own device, immutable shared buffers, never written after
//    they are handed (the engine retains them until the next call);
//  - **the matrix**: `MaskFrame.engineNode` — the host's own cut of the decode (a film edge's framing with its half
//    turn carried back, a perspective), the identity when the engine cuts for itself;
//  - **the stamp** (`stamp`): a hash of everything the node reads — each plane's key, each gain and coverage as the
//    floats the node is handed, the matrix — on the wire as `scene_layers`. The develop's own stamp is its whole
//    wire, so the kept picture, the full render and an export's cache turn over with the mask (§6.4).
//
//  **Captured at submit** (`Ask`, carried in `EngineHost.Request`): the layers' value, the source's size, the matrix
//  and the stamp are taken when the job is submitted, on the main actor, with the rest of its answers; the planes are
//  made from that value on the engine's queue (`planes`), so a develop can never run on the masks of the stroke
//  before — and if a plane and a wire ever disagreed, the engine refuses the render with both stamps named
//  (`SPK_ERR_USER`; `tools/scene_layers_drive.swift` reaches that refusal from here).
//
//  **No layer that can act — none, all off, opacity 0, every delta zero — is no ask**: the wire carries no
//  `scene_layers` field at all (its rest `""` is in `FilmParams.sometimesSent`, sent only to leave a set), so the
//  wire, its stamp and the develop are today's byte for byte (RFC-052 §10.2).
//
//  C is the engine's: its reply to `spk_set_scene_layers` gives `rgb_to_cone` (the session's input space, the app's
//  linear ProPhoto: `FrameDecoder.linearProPhoto`). The host keeps a copy (`rgbToCone`) because it needs w before any
//  session exists (at submit, and with 应用胶片模拟 off, where there is none, RFC-052 §6.5); the copy is held against
//  the engine's recorded reply (`tools/engine_replies/scene_layers_reply.json`) by `tools/scene_layer_selftest.swift`
//  and against every live reply by `SpkEngine` (a reply that differs is logged and the render refused).

import CoreGraphics
import Foundation
import Metal
import simd

enum SceneLayerWire {
    // MARK: a and b

    /// **a**: mired a unit of 色温, and **b**: Duv a unit of 色调 — each fixed so that a full-mask layer at ±100 is the
    /// decoder's own control moved by ±100: the decoder's Temperature ruler moved by 100 mired from the file's own
    /// balance (its warm half from a daylight balance is about that: 5500 → 10,000 K is −82 mired), its Tint ruler by
    /// 100 of its units (±150). How (gate 1b, `tools/scene_layers_drive.sh tint-fit`): on four RAWs (two Z7 II NEFs,
    /// an A7 III ARW, a Ricoh DNG), the decoder moved by ±50 and ±100 against the layer on the as-shot decode, both in
    /// linear ProPhoto, ΔE2000 over an 8 × 6 grid of each photograph's own patches; `a` and `b` scanned for the least
    /// mean. Fits: a 1.12, 1.12, 1.02, 0.98; b 0.00032, 0.00035, 0.00038, 0.00029. Shipped: their means. The figure
    /// that remains (mean ΔE2000 about 1.5–2 at ±50, 3–7 at ±100, against the decoder's own move of 8–15) is what the
    /// product promises, no more: the decoder balances the camera's channels, this filters the light.
    static let miredPerUnit = 1.06
    static let duvPerUnit = 0.000_34

    // MARK: C

    /// C = M_CAT16 · M_(ProPhoto → XYZ), row-major: the engine's own reply (`rgb_to_cone`), copied.
    static let rgbToCone: [Double] = [0.50735726159999994, 0.5171122963, -0.029824847200000001,
                                      0.14723244840000002, 0.82358609300000007, 0.030112017599999995,
                                      0.0124397577, 0.034567847999999998, 0.78617428479999996]
    /// CAT16 (Li et al. 2017), the engine's `colour/cat/CAT16`.
    static let cat16: [Double] = [0.401288, 0.650173, -0.051461, -0.250268, 1.204414, 0.045854, -0.002079, 0.048952, 0.953127]

    static func m(_ a: [Double]) -> simd_double3x3 {
        simd_double3x3(rows: [SIMD3(a[0], a[1], a[2]), SIMD3(a[3], a[4], a[5]), SIMD3(a[6], a[7], a[8])])
    }
    static func rows(_ s: simd_double3x3) -> [Double] { MaskMatrix.simd(s).m }
    static var coneToRGB: [Double] { rows(m(rgbToCone).inverse) }
    /// M_(ProPhoto → XYZ), as the engine has it: M_CAT16⁻¹ · C.
    static var rgbToXYZ: simd_double3x3 { m(cat16).inverse * m(rgbToCone) }

    // MARK: the Planckian locus (CIE 1960 uv)

    /// The Planckian locus at T kelvin in CIE 1960 (u, v): Krystek's rational approximation (1985), within
    /// 1e-5 of the CIE's integration over 1000…15000 K.
    static func planck(_ t: Double) -> SIMD2<Double> {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        return SIMD2(u, v)
    }

    /// The unit normal to the locus at T, pointing to positive Duv (above it: toward green).
    static func normal(_ t: Double) -> SIMD2<Double> {
        let d = planck(t * 1.0001) - planck(t * 0.9999)
        var n = SIMD2(-d.y, d.x)
        n /= (n * n).sum().squareRoot()
        return n.y > 0 ? n : -n
    }

    static func uv(_ xyz: SIMD3<Double>) -> SIMD2<Double> {
        let d = xyz.x + 15 * xyz.y + 3 * xyz.z
        return SIMD2(4 * xyz.x / d, 6 * xyz.y / d)
    }

    static func xyz(uv: SIMD2<Double>, y: Double = 1) -> SIMD3<Double> {
        let d = 2 * uv.x - 8 * uv.y + 4
        let x = 3 * uv.x / d, yy = 2 * uv.y / d
        return SIMD3(x / yy * y, y, (1 - x - yy) / yy * y)
    }

    /// A white's correlated colour temperature and Duv: the nearest point of the locus, by golden section in mired.
    static func cctDuv(_ p: SIMD2<Double>) -> (kelvin: Double, duv: Double) {
        func dist(_ mired: Double) -> Double { let q = planck(1e6 / mired) - p; return (q * q).sum() }
        var lo = 1e6 / 25000, hi = 1e6 / 1000
        let g = (5.0.squareRoot() - 1) / 2
        var a = hi - g * (hi - lo), b = lo + g * (hi - lo)
        for _ in 0..<100 {
            if dist(a) < dist(b) { hi = b } else { lo = a }
            a = hi - g * (hi - lo); b = lo + g * (hi - lo)
        }
        let t = 1e6 / ((lo + hi) / 2)
        return (t, ((p - planck(t)) * normal(t)).sum())
    }

    /// The working white (ProPhoto's D50), its CCT and Duv.
    static var workingWhite: (xyz: SIMD3<Double>, kelvin: Double, duv: Double) {
        let w = rgbToXYZ * SIMD3<Double>(1, 1, 1)
        let (t, duv) = cctDuv(uv(w))
        return (w, t, duv)
    }

    /// w(τ, ν): the gain on the three cone responses at full coverage. (1, 1, 1) exactly at τ = ν = 0.
    static func whiteGain(temperature tau: Double, tint nu: Double, a: Double = miredPerUnit, b: Double = duvPerUnit) -> SIMD3<Double> {
        guard tau != 0 || nu != 0 else { return SIMD3(1, 1, 1) }
        let white = workingWhite
        let mired = min(max(1e6 / white.kelvin - a * tau, 1e6 / 25000), 1e6 / 1000)
        let t1 = 1e6 / mired
        let uv1 = planck(t1) + (white.duv + b * nu) * normal(t1)
        let m16 = m(cat16)
        let cone0 = m16 * white.xyz, cone1 = m16 * xyz(uv: uv1, y: white.xyz.y)
        var w = cone0 / cone1
        // The working white's luminance unchanged: a neutral keeps its exposure.
        let y = (m16.inverse * (w * cone0)).y
        w *= white.xyz.y / y
        return w
    }

    /// g of RFC-052 §6.1 for a layer's 场景 deltas.
    static func logGain(_ d: SceneDeltas, a: Double = miredPerUnit, b: Double = duvPerUnit) -> SIMD3<Double> {
        let e = d.exposure * M_LN2
        guard d.isColour else { return SIMD3(e, e, e) }
        let w = whiteGain(temperature: d.temperature, tint: d.tint, a: a, b: b)
        return SIMD3(e + log(w.x), e + log(w.y), e + log(w.z))
    }

    // MARK: the ask

    /// One layer as the node reads it.
    struct Layer: Sendable, Equatable {
        var layer: LocalLayer
        /// The plane's key (`MaskBaker.planeKey`).
        var planeKey: String
        /// g, narrowed to the floats the node is handed.
        var logGain: SIMD3<Float>
        var coverage: Float
    }

    /// **What a job's 场景 layers cost the host** (RFC-052 §8.5, `RenderJob.scenePlanes`): how many act, and their
    /// planes' bytes — 2 a texel of the canonical plane (`MaskBaker.planeSize`: 22 MB at most).
    static func priced(_ layers: LocalLayers?, source: PixelSize) -> (planes: Int, bytes: UInt64) {
        let n = min(layers?.active(.scene).count ?? 0, LocalLayers.perStage)
        guard n > 0 else { return (0, 0) }
        let plane = MaskBaker.planeSize(source: source)
        return (n, UInt64(n) * UInt64(plane.width * plane.height * 2))
    }

    /// What a develop's 场景 layers are, captured at submit: everything `spk_set_scene_layers` will be handed but the
    /// planes, which are made from `layers` on the engine's queue (`planes`).
    struct Ask: Sendable, Equatable {
        var layers: [Layer]
        /// The source's size: the planes' shape and L_c.
        var source: PixelSize
        var frameToSource: MaskMatrix
        var stamp: String
        /// Gate 10's family; the products everywhere else.
        var family: JoinFamily = .products
        /// Found parts' pictures handed by asset (a driver's, a check's). Empty in the app: the baker reads a found
        /// part's picture from its file (`MaskStore.foundPicture`, `FoundMaskFiles`), and a part with no file fails
        /// the bake naming its layer (`MaskBaker.Failure.missingFound`), so the develop fails, never baked without it.
        var found: [String: FoundPicture] = [:]

        static func == (a: Ask, b: Ask) -> Bool { a.stamp == b.stamp }
    }

    /// An edit's ask, or nil where no 场景 layer can act (no field on the wire then). `hostCut` is the host's cut of
    /// the decode (`FrameEdit.hostCut(source:)`), `decode` the decode's size before it.
    static func ask(_ layers: LocalLayers?, source: PixelSize, hostCut: Geometry?, decode: PixelSize,
                    family: JoinFamily = .products, found: [String: FoundPicture] = [:]) -> Ask? {
        let acting = Array((layers?.active(.scene) ?? []).prefix(LocalLayers.perStage))
        guard !acting.isEmpty else { return nil }
        let f2s = MaskFrame.engineNode(hostCut: hostCut, decode: CGSize(width: decode.width, height: decode.height))
        let made = acting.map { l -> Layer in
            let g = logGain(l.scene ?? SceneDeltas())
            return Layer(layer: l, planeKey: MaskBaker.planeKey(l, source: source, family: family),
                         logGain: SIMD3(Float(g.x), Float(g.y), Float(g.z)), coverage: Float(l.coverage))
        }
        return Ask(layers: made, source: source, frameToSource: f2s, stamp: stamp(made, frameToSource: f2s), family: family, found: found)
    }

    /// The set's name: a hash of the planes' keys, the gains and coverages as the node's floats (their bits), and the
    /// matrix as the node's floats. "sl1." and 32 hex digits.
    static func stamp(_ layers: [Layer], frameToSource: MaskMatrix) -> String {
        var words = "scene_layers v1|"
        for l in layers {
            let bits = [l.logGain.x, l.logGain.y, l.logGain.z, l.coverage].map { String($0.bitPattern, radix: 16) }
            words += l.planeKey + ":" + bits.joined(separator: ",") + "|"
        }
        words += frameToSource.floats.map { String($0.bitPattern, radix: 16) }.joined(separator: ",")
        return "sl1." + StampHash.hex(words)
    }

    // MARK: the planes, on the engine's queue

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bakers: [ObjectIdentifier: MaskBaker] = [:]

    /// The baker of a device: one, made the first time it is asked for, its store shared by every bake on it.
    static func baker(for device: MTLDevice) throws -> MaskBaker {
        lock.lock(); defer { lock.unlock() }
        if let b = bakers[ObjectIdentifier(device)] { return b }
        let b = try MaskBaker(device: device)
        bakers[ObjectIdentifier(device)] = b
        return b
    }

    /// The ask's planes, on `device`, in its layers' order: from the store where they are (a stamp's planes are
    /// usually baked when its stroke ended), baked otherwise. Blocks the calling thread — the engine's queue, never
    /// the main actor — until they are made.
    static func planes(for ask: Ask, device: MTLDevice) throws -> [MaskPlane] {
        let baker = try baker(for: device)
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                var out: [MaskPlane] = []
                for l in ask.layers {
                    out.append(try await baker.bake(l.layer, source: ask.source, found: ask.found, family: ask.family))
                }
                box.set(.success(out))
            } catch { box.set(.failure(error)) }
            done.signal()
        }
        done.wait()
        return try box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[MaskPlane], Error> = .success([])
        func set(_ r: Result<[MaskPlane], Error>) { lock.lock(); result = r; lock.unlock() }
        func get() throws -> [MaskPlane] { lock.lock(); defer { lock.unlock() }; return try result.get() }
    }

    /// Whether the engine's C is the host's copy (each entry within 1e-9): `SpkEngine` holds every reply to it.
    static func agrees(rgbToCone reply: [Double]) -> Bool {
        reply.count == 9 && zip(reply, rgbToCone).allSatisfy { abs($0 - $1) <= 1e-9 }
    }
}
