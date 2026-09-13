//  ColourManagement.swift — the working space, and the one conversion out of it.
//
//  RFC-018 §5.4. Filmify grades in **one** space (ProPhoto RGB, the session's
//  resolved `io.output_color_space`) and converts once, at the end, per
//  destination. This file is the app's side of that: it asks the engine for the
//  numbers (`spk_output_transform`), caches the answer per (source, target)
//  pair, and packs them into the uniform block `outputTransform` reads.
//
//  What is deliberately absent: a colour library. Every number below arrives
//  from the engine's own baked colour data — the adapted 3×3, the CAM16
//  viewing-condition constants, the C_max table — because a second
//  implementation of a transfer function or a gamut map is a second chance to
//  disagree, and the disagreement would look like a grading decision.
//
//  ColorSync keeps the two jobs it is actually the authority for (RFC-018
//  §2.4 D2): it says *what a space is* — every target is a `CGColorSpace`,
//  every file is tagged by ImageIO, and the profile catalogue is still read
//  from the system — while the conversion itself is ours, because a matrix
//  profile has no perceptual table and ColorSync's only honest answer for an
//  out-of-gamut colour is to clip it.

import CoreGraphics
import Foundation
import Metal

// Fixed-size float blocks. Swift has no fixed-size array in a struct, so the
// shader's `float matrix[9]` is a homogeneous tuple here. The layout is
// contiguous in declaration order on both sides; `ColourManagementTests` pins
// the total and the offsets, because a mismatch is not a crash — it is a
// picture converted with somebody else's numbers.
typealias Mat9f = (Float, Float, Float, Float, Float, Float, Float, Float, Float)
typealias K22f = (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float,
                  Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)

/// Must match `OutputTransformUniforms` in Shaders.metal field for field and
/// in order.
struct OutputTransformUniforms: Sendable {
    /// Source linear RGB → target linear RGB, **row-major**:
    /// `out[i] = Σ_j m[3i + j] · x[j]`.
    var matrix: Mat9f = (1, 0, 0, 0, 1, 0, 0, 0, 1)
    /// The target's RGB↔XYZ pair with adaptation, and the 22 scalars the
    /// CAM16 body reads. See `shaders/gamut.metal`'s `k` for what each is.
    var cam16M2X: Mat9f = (1, 0, 0, 0, 1, 0, 0, 0, 1)
    var cam16M2R: Mat9f = (1, 0, 0, 0, 1, 0, 0, 0, 1)
    var cam16K: K22f = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var sourceCctfMode: UInt32 = 0
    var targetCctfMode: UInt32 = 0
    /// 0 skips the compression step entirely — `algorithm: "off"`, in which
    /// case `stats[0]` stays 0.
    var cam16Active: UInt32 = 0
    /// The lightness compression's own gate, which is not the same switch:
    /// `k[15..17]` are neutralised when it is off, but with the gate *on* and
    /// those values they would not be an identity.
    var cam16Lightness: UInt32 = 0
    var cmaxNL: UInt32 = 0
    var cmaxNH: UInt32 = 0
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
}

/// One destination the app can convert to: the engine's numbers, packed, plus
/// the table that has to live on the device.
///
/// `@unchecked Sendable` because it carries an `MTLBuffer` and a buffer is the
/// whole point — the same compromise `RenderOutcome` and `EngineFrame` make.
/// It is written once, on the main actor, before it is installed anywhere.
struct OutputTransformSetup: @unchecked Sendable {
    /// The colour space the pixels are *in* — the session's resolved output
    /// space, read from the open reply and never assumed (RFC-018 §5.1).
    let sourceName: String
    /// What to call the destination in front of a person. A `CGColorSpace`'s
    /// identifier is not a name anybody recognises ("kCGColorSpaceDisplayP3").
    let targetName: String
    let target: CGColorSpace
    let uniforms: OutputTransformUniforms
    /// The target's C_max(J', h') table — `cmaxRows * cmaxCols` floats.
    let cmax: MTLBuffer
    /// False when the engine returned `algorithm: "off"`, so the compression
    /// step is not in the chain and `stats[0]` will be zero by construction
    /// rather than by measurement.
    let compresses: Bool
}

/// What one run of the transform did, beyond the pixels.
///
/// The numbers RFC-018 §5.3 asks the kernel to count, read back off the
/// device. They are the export page's warning and §7's measurement; the canvas
/// path does not read them (it would stall a draw on a readback for something
/// nothing on screen uses).
struct OutputTransformStats: Sendable {
    /// Pixels the knee acted on, 0…1 — §5.3's `d > threshold`.
    ///
    /// **Degenerate at the session's default knee, and reported rather than
    /// quietly redefined.** `GamutCompressSpec::output_default` is
    /// `(threshold 0, limit 1, power 6)`, which the reference's own docstring
    /// calls "a gentle, always-on roll-off": with threshold 0, every pixel
    /// with any chroma at all takes the branch, so this reads ~1.0 on any
    /// photograph — measured at 1.0 on a frame of pure mid-grey. For "how much
    /// of this picture is the destination going to change", use
    /// `outsideFraction`.
    let movedFraction: Double
    /// Pixels still at or past the container's limits after encoding, 0…1.
    /// These are the ones that lost detail rather than saturation.
    let clippedFraction: Double
    /// Pixels the destination **could not hold** — chroma past what its cube
    /// reaches at that lightness and hue, measured before the knee, 0…1.
    ///
    /// This is the number RFC-018 §6's warning is about ("when the recipe
    /// cannot hold the picture"), and the one `movedFraction` was meant to be.
    /// Zero on a frame the target has room for, whatever the knee settings.
    let outsideFraction: Double
}

@MainActor
enum ColourManagement {
    /// The engine's own name for a space, or nil when it has none.
    ///
    /// Five of the catalogue's built-ins map to a *baked* colour space: those
    /// are the ones the transform can be built for. Everything else — every
    /// installed ICC profile, and any built-in not listed here — has no
    /// engine name, and the caller reports that rather than substituting one
    /// (RFC-018 §5.4: a target the engine does not know is reported to the UI,
    /// not silently replaced).
    static func engineName(for space: CGColorSpace) -> String? {
        switch space {
        case _ where space.name == CGColorSpace.displayP3: return "Display P3"
        case _ where space.name == CGColorSpace.sRGB: return "sRGB"
        case _ where space.name == CGColorSpace.adobeRGB1998: return "Adobe RGB (1998)"
        case _ where space.name == CGColorSpace.rommrgb: return "ProPhoto RGB"
        case _ where space.name == CGColorSpace.itur_2020: return "ITU-R BT.2020"
        default: return nil
        }
    }

    /// What a catalogue entry resolves to, or nil when the engine cannot
    /// convert to it. The conversation is about *identity*, not pixels: an ICC
    /// profile file is a name and a path, and no baked colour space answers to
    /// it even when the two describe the same primaries.
    static func engineName(for space: ExportColorSpace) -> String? {
        guard let cg = space.cgColorSpace else { return nil }
        return engineName(for: cg)
    }

    // MARK: - fetch and cache

    /// The setup for one conversion, fetched from the engine once and kept.
    ///
    /// Keyed by the pair and by nothing else: the engine's answer is a pure
    /// function of the two names, so a hit is not a guess about staleness.
    private static var cache: [String: OutputTransformSetup] = [:]

    /// The setup for `source` → `target`, or `nil` when the engine cannot
    /// build one — with `problem` saying which space it did not know.
    ///
    /// Returns rather than throws because both callers have a *reported*
    /// failure mode and neither has a useful error to propagate: the canvas
    /// draws unconverted and says so, and the export falls back to Display P3
    /// the way it already does for an unresolvable profile.
    static func setup(client: EngineClient, source: String, target: CGColorSpace,
                      device: MTLDevice,
                      gamutCompress: String? = nil) async -> (setup: OutputTransformSetup?, problem: String?) {
        guard let targetName = engineName(for: target) else {
            return (nil, "the engine has no colour space for “\(DisplayName.of(target))”")
        }
        // The compression spec is part of the key and not a footnote: a setup
        // built with a different knee or with the lightness compression off is
        // a different kernel with a different C_max interpretation, and a cache
        // that ignored it would hand back the wrong one.
        let key = "\(source)→\(targetName)→\(gamutCompress ?? "")"
        if let hit = cache[key] { return (hit, nil) }
        do {
            let fetched = try await client.outputTransform(src: source, dst: targetName,
                                                           gamutCompress: gamutCompress)
            guard let setup = make(fetched, source: source, target: target, targetName: targetName,
                                   device: device) else {
                return (nil, "the engine's reply for \(source) → \(targetName) did not parse")
            }
            cache[key] = setup
            return (setup, nil)
        } catch {
            return (nil, EngineMessage.technical(error))
        }
    }

    /// Forget every fetched setup. Only for tests: the tables are ~184 kB each
    /// and the engine's own copy is cached for its lifetime, so re-fetching is
    /// cheap but pointless.
    static func forgetCached() { cache.removeAll() }

    // MARK: - packing

    private static func make(_ fetched: OutputTransformFetch,
                             source: String, target: CGColorSpace, targetName: String,
                             device: MTLDevice) -> OutputTransformSetup? {
        let reply = fetched.reply
        let compress = reply.gamutCompress
        let active = compress.algorithm != "off"
        guard reply.matrix.count == 9, compress.mToXYZ.count == 9,
              compress.mToRGB.count == 9, compress.consts.count == 22,
              compress.cmaxRows > 0, compress.cmaxCols > 0,
              compress.cmaxRows * compress.cmaxCols == fetched.cmax.count,
              let cmax = device.makeBuffer(bytes: fetched.cmax,
                                           length: fetched.cmax.count * MemoryLayout<Float>.size,
                                           options: .storageModeShared)
        else { return nil }

        var u = OutputTransformUniforms()
        u.matrix = mat9(reply.matrix)
        u.cam16M2X = mat9(compress.mToXYZ)
        u.cam16M2R = mat9(compress.mToRGB)
        u.cam16K = k22(compress.consts)
        u.sourceCctfMode = UInt32(reply.sourceCctfMode)
        u.targetCctfMode = UInt32(reply.targetCctfMode)
        u.cam16Active = active ? 1 : 0
        u.cam16Lightness = compress.lightnessCompressionActive ? 1 : 0
        u.cmaxNL = UInt32(compress.cmaxRows)
        u.cmaxNH = UInt32(compress.cmaxCols)

        return OutputTransformSetup(sourceName: source, targetName: targetName, target: target,
                                    uniforms: u, cmax: cmax, compresses: active)
    }

    private static func mat9(_ d: [Double]) -> Mat9f {
        (Float(d[0]), Float(d[1]), Float(d[2]),
         Float(d[3]), Float(d[4]), Float(d[5]),
         Float(d[6]), Float(d[7]), Float(d[8]))
    }

    private static func k22(_ d: [Double]) -> K22f {
        (Float(d[0]), Float(d[1]), Float(d[2]), Float(d[3]), Float(d[4]), Float(d[5]),
         Float(d[6]), Float(d[7]), Float(d[8]), Float(d[9]), Float(d[10]),
         Float(d[11]), Float(d[12]), Float(d[13]), Float(d[14]), Float(d[15]), Float(d[16]),
         Float(d[17]), Float(d[18]), Float(d[19]), Float(d[20]), Float(d[21]))
    }
}

enum DisplayName {
    /// A person-readable name for a colour space, for a status line or a
    /// warning. The catalogue's own name is preferred — that is the string the
    /// user picked — and this is the fallback for a space that did not come
    /// from the catalogue (the canvas's own target, a profile the engine
    /// named).
    static func of(_ space: CGColorSpace) -> String {
        // Through the catalogue, by identity rather than by name: that is the
        // string the user picked, and it is the one a warning should repeat
        // back at them.
        if let entry = ColorSpaceCatalog.all.first(where: { $0.space.cgColorSpace == space }) {
            return entry.name
        }
        // `CGColorSpace.name` is ColorSync's own identifier and reads as
        // "kCGColorSpaceDisplayP3" — ugly, but it names the space, which is
        // the job. `nil` is a space with no name at all.
        return (space.name as String?) ?? "an unnamed profile"
    }
}
