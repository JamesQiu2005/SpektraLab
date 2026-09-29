//  CineonLUT.swift — the one transform between the Digital Intermediate and
//  everything else in the app (RFC-028 §13, 2026-09-29).
//
//  The engine writes a DI as **Cineon log** with ProPhoto RGB primaries: the
//  file a colourist gets. Inside the app the picture lives in ProPhoto RGB
//  like every other frame, so the canvas reads the DI through a
//  Cineon → ProPhoto RGB table — the same decode any Cineon-aware tool runs,
//  which is the point: the app looks at its own DI the way the world will.
//
//  The decode is Kodak's, as the standard implementations apply it
//  (colour-science `log_decoding_Cineon`, Nuke's Log2Lin): reference white
//  685 → 1.0, reference black 95 → 0 (the film base), 300 codes per decade
//  (0.002 density per code over a negative gamma of 0.6), black offset
//  removed. `engine/src/core/digital_intermediate.hpp` encodes with the same
//  four constants; `DigitalIntermediateTests` holds the two to each other.
//
//  Two `.cube` files are written beside a DI export so it can be opened
//  elsewhere without guessing: Cineon → ProPhoto RGB (what the canvas shows)
//  and Cineon → Rec.709 (γ2.4, for video monitors and most LUT hosts). Both
//  are 3D, because Photoshop's Color Lookup reads no 1D `.cube`; both are
//  technical transforms with no tone curve, so everything above 1.0 clips —
//  RFC-029's curve is where a shoulder belongs.

import Foundation
import Metal
import simd

enum CineonLUT {
    static let referenceWhite = 685.0
    static let referenceBlack = 95.0
    static let codesPerDecade = 300.0
    static let maxCode = 1023.0
    static let blackOffset = pow(10.0, (referenceBlack - referenceWhite) / codesPerDecade)

    /// Code value 0…1 → linear, 1.0 at reference white, 0 at the film base.
    static func decode(_ code: Double) -> Double {
        (pow(10.0, (code * maxCode - referenceWhite) / codesPerDecade) - blackOffset) / (1 - blackOffset)
    }

    /// ProPhoto (ROMM) RGB's transfer function: linear below 1/512, then 1/1.8.
    static func rommEncode(_ l: Double) -> Double {
        let x = min(max(l, 0), 1)
        return x < 1.0 / 512 ? 16 * x : pow(x, 1 / 1.8)
    }

    /// The canvas table: code → ROMM-encoded ProPhoto, sampled at `size`
    /// evenly spaced codes over 0…1 and interpolated linearly by the sampler.
    /// 4096 entries put the largest interpolation error below a 16-bit step.
    static func proPhotoTable(size: Int = 4096) -> [Float] {
        (0..<size).map { Float(rommEncode(decode(Double($0) / Double(size - 1)))) }
    }

    /// The table as a 1D texture the Layer 2 pass samples.
    static func makeTexture(device: MTLDevice) -> MTLTexture? {
        let table = proPhotoTable()
        let d = MTLTextureDescriptor()
        d.textureType = .type1D
        d.pixelFormat = .r32Float
        d.width = table.count
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        table.withUnsafeBytes {
            t.replace(region: MTLRegionMake1D(0, table.count), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: table.count * 4)
        }
        return t
    }

    // MARK: - the two files beside a DI export

    enum Target: CaseIterable {
        case proPhoto, rec709

        var fileName: String {
            switch self {
            case .proPhoto: "SpektraLab Cineon to ProPhoto RGB.cube"
            case .rec709: "SpektraLab Cineon to Rec709.cube"
            }
        }
        var title: String {
            switch self {
            case .proPhoto: "SpektraLab DI: Cineon log (ProPhoto primaries) to ProPhoto RGB"
            case .rec709: "SpektraLab DI: Cineon log (ProPhoto primaries) to Rec.709 gamma 2.4"
            }
        }
    }

    /// ProPhoto RGB (D50) → ITU-R BT.709 (D65), Bradford. From colour-science
    /// 0.4.7 `matrix_RGB_to_RGB(..., chromatic_adaptation_transform="Bradford")`,
    /// each row then divided by its sum: the published whitepoints leave the
    /// rows 2e-4 off 1, and a grey must come out of a technical LUT grey.
    static let proPhotoToRec709: simd_double3x3 = {
        let rows = [SIMD3(2.0342930024, -0.7276819247, -0.3068105500),
                    SIMD3(-0.2289038910, 1.2318483428, -0.0028576467),
                    SIMD3(-0.0085464902, -0.1532801862, 1.1615322465)]
        return simd_double3x3(rows: rows.map { $0 / ($0.x + $0.y + $0.z) })
    }()

    /// One output triple for a Cineon code triple.
    static func map(_ code: SIMD3<Double>, to target: Target) -> SIMD3<Double> {
        let lin = SIMD3(decode(code.x), decode(code.y), decode(code.z))
        switch target {
        case .proPhoto:
            return SIMD3(rommEncode(lin.x), rommEncode(lin.y), rommEncode(lin.z))
        case .rec709:
            let r = simd_clamp(proPhotoToRec709 * lin, SIMD3(repeating: 0), SIMD3(repeating: 1))
            return SIMD3(pow(r.x, 1 / 2.4), pow(r.y, 1 / 2.4), pow(r.z, 1 / 2.4))
        }
    }

    /// A 3D `.cube` (Adobe/Resolve format: red fastest, domain 0…1).
    static func cube(_ target: Target, size: Int = 65) -> String {
        var out = "TITLE \"\(target.title)\"\n"
        out += "# Decode: Kodak Cineon, white 685, black 95, 0.002 D/code, negative gamma 0.6.\n"
        out += "LUT_3D_SIZE \(size)\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        let n = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = map(SIMD3(Double(r) / n, Double(g) / n, Double(b) / n), to: target)
                    out += String(format: "%.6f %.6f %.6f\n", v.x, v.y, v.z)
                }
            }
        }
        return out
    }

    /// Write both files into `directory` unless they are already there, so a
    /// batch of DIs into one folder carries one pair.
    @discardableResult
    static func writeBeside(directory: URL) throws -> [URL] {
        var written: [URL] = []
        for target in Target.allCases {
            let url = directory.appending(path: target.fileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try cube(target).write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }
        return written
    }
}
