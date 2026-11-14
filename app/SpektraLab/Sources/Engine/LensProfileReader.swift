//  LensProfileReader.swift — a RAW's own lens parameters, read from its TIFF structure, into a `LensProfile`.
//
//  A minimal TIFF walk of our own (IFD0, its chain, SubIFDs, the EXIF IFD): no dependency, and no code read or
//  ported from a GPL program (the owner's rule, 2026-11-13). Tag numbers and layouts are the public TIFF/DNG
//  specifications' and ExifTool's tag tables'; the *meaning* of Sony's numbers was established by measurement
//  (`tools/lens_profile_selftest.swift`, which registers a decode against the camera's own JPEG), and is written
//  down at `sony` with what verified it.
//
//  - **Sony ARW**: the raw SubIFD carries 0x7032 VignettingCorrParams, 0x7035 ChromaticAberrationCorrParams and
//    0x7037 DistortionCorrParams, int16 arrays whose first value is the count of knots that follow (for CA, red's
//    knots then blue's). They are written whatever the camera's own correction settings were (0x7031, 0x7034,
//    0x7036 say what the camera did to its JPEG, not what the lens is).
//  - **DNG**: OpcodeList3's WarpRectilinear and FixVignetteRadial (DNG 1.4 §6, the opcode lists are big-endian
//    whatever the file's order). Measured on this Mac (2026-11-13): Core Image applies OpcodeList1's
//    FixVignetteRadial itself on any DNG (a Ricoh GR II's, its corners doubled with it, halved without), and a
//    DNG's `isLensCorrectionSupported` is OpcodeList3's WarpRectilinear (a Leica Q3's goes false with the tag
//    renamed). So only OpcodeList3 is read, and only for a file Core Image says it cannot correct.

import Foundation

enum LensProfileReader {
    // MARK: the TIFF walk

    /// One IFD's entries: tag → (type, count, the value's bytes' offset in the file).
    struct Entry { var type: Int; var count: Int; var offset: Int }
    struct IFD { var entries: [Int: Entry]; var path: String }

    struct TIFF {
        let data: Data
        let little: Bool
        var ifds: [IFD] = []

        init?(data: Data) {
            guard data.count >= 8 else { return nil }
            self.data = data
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            guard (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) else { return nil }
            little = b0 == 0x49
            // A TIFF's magic is 42; Olympus's ORF and Panasonic's RW2 write their own, and are walked alike.
            var seen = Set<Int>()
            walk(Int(u32(4)), path: "IFD0", chain: true, depth: 0, seen: &seen)
        }

        func u8(_ o: Int) -> UInt8 { o >= 0 && o < data.count ? data[data.startIndex + o] : 0 }
        func u16(_ o: Int) -> UInt16 {
            let a = UInt16(u8(o)), b = UInt16(u8(o + 1))
            return little ? a | b << 8 : a << 8 | b
        }
        func u32(_ o: Int) -> UInt32 {
            let a = UInt32(u16(o)), b = UInt32(u16(o + 2))
            return little ? a | b << 16 : a << 16 | b
        }
        static let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]

        private mutating func walk(_ start: Int, path: String, chain: Bool, depth: Int, seen: inout Set<Int>) {
            var off = start, index = 0
            while off > 0, off + 2 <= data.count, !seen.contains(off), depth < 4, index < 16 {
                seen.insert(off)
                let n = Int(u16(off))
                guard n > 0, n < 4096, off + 2 + 12 * n + 4 <= data.count else { return }
                var entries: [Int: Entry] = [:]
                for i in 0..<n {
                    let o = off + 2 + 12 * i
                    let type = Int(u16(o + 2)), count = Int(u32(o + 4))
                    let size = (Self.sizes[type] ?? 1) * count
                    entries[Int(u16(o))] = Entry(type: type, count: count, offset: size <= 4 ? o + 8 : Int(u32(o + 8)))
                }
                let name = index == 0 ? path : "\(path)+\(index)"
                ifds.append(IFD(entries: entries, path: name))
                for (tag, label) in [(0x14A, "sub"), (0x8769, "exif")] {
                    guard let e = entries[tag] else { continue }
                    for k in 0..<min(e.count, 8) {
                        walk(Int(u32(e.offset + 4 * k)), path: "\(name).\(label)\(k)", chain: false, depth: depth + 1, seen: &seen)
                    }
                }
                guard chain else { return }
                off = Int(u32(off + 2 + 12 * n))
                index += 1
            }
        }

        func int16s(_ e: Entry) -> [Int] {
            guard e.type == 8 || e.type == 3 else { return [] }
            return (0..<min(e.count, 256)).map { e.type == 8 ? Int(Int16(bitPattern: u16(e.offset + 2 * $0))) : Int(u16(e.offset + 2 * $0)) }
        }
        func uint(_ e: Entry) -> Int? {
            switch e.type { case 3: Int(u16(e.offset)); case 4, 13: Int(u32(e.offset)); default: nil }
        }
        func bytes(_ e: Entry) -> Data? {
            let size = (Self.sizes[e.type] ?? 1) * e.count
            guard e.offset >= 0, e.offset + size <= data.count else { return nil }
            return data.subdata(in: data.startIndex + e.offset ..< data.startIndex + e.offset + size)
        }
        func string(_ e: Entry) -> String? {
            bytes(e).flatMap { String(data: $0, encoding: .ascii) }?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
        }
        func first(_ tag: Int) -> (IFD, Entry)? {
            for ifd in ifds { if let e = ifd.entries[tag] { return (ifd, e) } }
            return nil
        }
        var make: String? { first(0x10F).flatMap { string($0.1) } }

        /// The largest JPEG picture the file carries (JPEGInterchangeFormat 0x201/0x202, or a strip of compression 6/7
        /// that is not the raw data itself — a compressed ARW's and a DNG's raw are lossless JPEG, photometric CFA or
        /// linear raw): its bytes' range. A Sony ARW's camera preview, which the self-test registers against.
        var largestJPEG: Range<Int>? {
            var best: Range<Int>?
            func take(_ start: Int, _ length: Int) {
                guard length > 1024, start > 0, start + length <= data.count, u8(start) == 0xFF, u8(start + 1) == 0xD8 else { return }
                if best == nil || length > best!.count { best = start ..< start + length }
            }
            for ifd in ifds {
                if let s = ifd.entries[0x201].flatMap(uint), let l = ifd.entries[0x202].flatMap(uint) { take(s, l) }
                let photometric = ifd.entries[0x106].flatMap(uint) ?? 0
                if let c = ifd.entries[0x103].flatMap(uint), c == 6 || c == 7, photometric != 32803, photometric != 34892,
                   let s = ifd.entries[0x111].flatMap(uint), let l = ifd.entries[0x117].flatMap(uint) { take(s, l) }
            }
            return best
        }
    }

    static func tiff(_ url: URL) -> TIFF? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return TIFF(data: data)
    }

    // MARK: what a file says

    /// The profile `url` carries that the app can apply, or nil: a Sony ARW's parameters, else a DNG's OpcodeList3.
    /// Whether Core Image corrects the file itself is not asked here (`LensCorrection` asks it).
    static func profile(_ url: URL) -> LensProfile? {
        guard let tiff = tiff(url) else { return nil }
        return sony(tiff) ?? dngOpcodes(tiff)
    }

    // MARK: Sony

    /// A Sony ARW's knots as written: each array without its leading count.
    struct SonyKnots: Equatable, Sendable {
        var distortion: [Int]?
        var vignetting: [Int]?
        var red: [Int]?
        var blue: [Int]?
        /// What the camera did to its own JPEG (0x7031, 0x7034, 0x7036), for the self-test's table.
        var vignettingSetting: Int?, caSetting: Int?, distortionSetting: Int?
    }

    static func sonyKnots(_ tiff: TIFF) -> SonyKnots? {
        guard tiff.make?.uppercased().hasPrefix("SONY") == true else { return nil }
        guard let ifd = tiff.ifds.first(where: { $0.entries[0x7037] != nil || $0.entries[0x7032] != nil || $0.entries[0x7035] != nil })
        else { return nil }
        func knots(_ tag: Int) -> [Int]? {
            guard let e = ifd.entries[tag] else { return nil }
            let v = tiff.int16s(e)
            guard let n = v.first, n >= 2, v.count >= n + 1 else { return nil }
            return Array(v[1...n])
        }
        var k = SonyKnots(distortion: knots(0x7037), vignetting: knots(0x7032))
        if let ca = knots(0x7035), ca.count % 2 == 0, ca.count >= 4 {
            k.red = Array(ca[0..<(ca.count / 2)]); k.blue = Array(ca[(ca.count / 2)...])
        }
        k.vignettingSetting = ifd.entries[0x7031].flatMap(tiff.uint)
        k.caSetting = ifd.entries[0x7034].flatMap(tiff.uint)
        k.distortionSetting = ifd.entries[0x7036].flatMap(tiff.uint)
        return k
    }

    /// Sony's knots as a profile. **The model, and what it rests on** (2026-11-13, `tools/lens_profile_selftest.swift`):
    ///
    /// - **distortion** `D = 1 + v·2⁻¹⁴`, the source radius over the corrected one, knot `i` of `n` at radius
    ///   `i / (n − 1)` of the half-diagonal. *Not* verifiable against the camera's JPEG on the samples: every one
    ///   was shot with distortion compensation off (0x7036 = 0), and its JPEG registers to Core Image's uncorrected
    ///   decode within 0.01–0.09 % of the half-diagonal (0.4–0.8 px), the corrected one further off. Verified instead
    ///   against Adobe's own measured profile of the same lens (Camera Raw's LCP), by registering the app's corrected
    ///   decode to the decode corrected by Adobe's model, a scale and shift removed: FE 24-70mm F2.8 GM II at 51 mm,
    ///   0.045 % of the half-diagonal at worst (uncorrected 0.54 %), FE 35mm F1.8 0.021–0.023 % (uncorrected 0.05 %).
    ///   As curves: the opposite sign is 1.3–2.2 % off Adobe's; knots at `(i + ½) / (n − 1)` are also inside 0.1 %,
    ///   but `i / (n − 1)` fits the knots as an even polynomial of the radius (a lens's distortion is one) better on
    ///   both lenses, and puts the first knot (≈ 0) at the centre. The Sigma 85mm F1.4 Art has no Adobe profile here.
    /// - **chromatic aberration** (0x7035): *not applied*. Core Image's decode of these files shows no red–green or
    ///   blue–green shift (0.00 px median over ~130 patches a ring, A7 III with FE 35mm F1.8 and A7 V with GM II),
    ///   where Sony's knots read as `1 + v·2⁻²¹` predict up to 1.2 px; applying them made a 1.25 px fringe that was
    ///   not there (`includeCA` keeps the reading for the self-test).
    /// - **vignetting** (0x7032): *not applied*. Core Image ignores Sony's tags (a copy with them zeroed decodes to the
    ///   same bits), and the camera's own preview JPEG measures within ±0.1 stop of that uncorrected decode at every
    ///   radius although 0x7031 says Auto: no oracle here verifies the law to a few percent (`sonyVignettingVerified`).
    ///
    /// `radius` overrides where knot `i` of `n` sits, for the self-test's comparison of hypotheses.
    static func sonyProfile(_ k: SonyKnots, radius: ((Int, Int) -> Double)? = nil, includeCA: Bool = false,
                            vignettingStops: Double = 0.5, includeVignetting: Bool = sonyVignettingVerified) -> LensProfile? {
        let at = radius ?? { i, n in Double(i) / Double(n - 1) }
        func radial(_ v: [Int]?, _ f: (Int) -> Double) -> LensProfile.Radial? {
            guard let v, v.count >= 2, v.contains(where: { $0 != 0 }) else { return nil }
            return .init(radii: v.indices.map { at($0, v.count) }, values: v.map(f))
        }
        var p = LensProfile(source: .sonyEmbedded)
        p.distortion = radial(k.distortion) { 1 + Double($0) / 16384 }
        if includeCA {
            p.redScale = radial(k.red) { 1 + Double($0) / 2_097_152 }
            p.blueScale = radial(k.blue) { 1 + Double($0) / 2_097_152 }
        }
        if includeVignetting { p.vignetting = radial(k.vignetting) { pow(2, vignettingStops * Double($0) / 8192) } }
        return p.corrects ? p : nil
    }

    /// Whether Sony's vignetting law was verified to a few percent. Until it is, the gain is left off: a wrong gain is
    /// worse than none.
    static let sonyVignettingVerified = false

    static func sony(_ tiff: TIFF) -> LensProfile? { sonyKnots(tiff).flatMap { sonyProfile($0) } }

    // MARK: DNG opcodes

    struct WarpRectilinear: Equatable, Sendable {
        /// Per plane (one for all, or red, green, blue): kr0…kr3, kt0, kt1.
        var planes: [[Double]]
        var cx: Double, cy: Double
    }
    struct FixVignetteRadial: Equatable, Sendable {
        var k: [Double]   // k0…k4
        var cx: Double, cy: Double
    }

    /// An opcode list's two radial opcodes (DNG 1.4 §6.2: WarpRectilinear is 1, FixVignetteRadial 3), big-endian.
    static func opcodes(_ list: Data) -> (warp: WarpRectilinear?, vignette: FixVignetteRadial?) {
        let b = [UInt8](list)
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : 0 }
        func f64(_ o: Int) -> Double {
            guard o + 8 <= b.count else { return .nan }
            var bits: UInt64 = 0
            for i in 0..<8 { bits = bits << 8 | UInt64(b[o + i]) }
            return Double(bitPattern: bits)
        }
        var warp: WarpRectilinear?, vignette: FixVignetteRadial?
        let count = u32(0)
        var o = 4
        for _ in 0..<min(count, 64) {
            let id = u32(o), size = u32(o + 12), p = o + 16
            guard p + size <= b.count else { break }
            if id == 1, size >= 4 {
                let n = u32(p)
                if (n == 1 || n == 3), size >= 4 + 48 * n + 16 {
                    let planes = (0..<n).map { i in (0..<6).map { f64(p + 4 + 48 * i + 8 * $0) } }
                    warp = WarpRectilinear(planes: planes, cx: f64(p + 4 + 48 * n), cy: f64(p + 12 + 48 * n))
                }
            } else if id == 3, size >= 56 {
                vignette = FixVignetteRadial(k: (0..<5).map { f64(p + 8 * $0) }, cx: f64(p + 40), cy: f64(p + 48))
            }
            o = p + size
        }
        return (warp, vignette)
    }

    /// The opcodes as a profile. WarpRectilinear: source radius over corrected radius
    /// `kr0 + kr1 r² + kr2 r⁴ + kr3 r⁶` (tangential terms are not part of a radial model and are dropped; none of
    /// the samples has any), green's plane the distortion and red's and blue's over it the aberration.
    /// FixVignetteRadial: gain `1 + k0 r² + k1 r⁴ + k2 r⁶ + k3 r⁸ + k4 r¹⁰`. Both centred at (cx, cy) of the image,
    /// r over the distance from it to the farthest corner, as `LensProfile` measures.
    static func profile(warp: WarpRectilinear?, vignette: FixVignetteRadial?) -> LensProfile? {
        var p = LensProfile(source: .dngOpcodes)
        func poly(_ k: [Double]) -> (Double) -> Double { { r in let r2 = r * r; return k[0] + r2 * (k[1] + r2 * (k[2] + r2 * k[3])) } }
        if let warp, warp.planes.allSatisfy({ $0.count == 6 && $0.allSatisfy(\.isFinite) }), warp.cx.isFinite, warp.cy.isFinite {
            let green = warp.planes.count == 3 ? warp.planes[1] : warp.planes[0]
            p.distortion = .sampled(poly(green))
            if warp.planes.count == 3 {
                let g = poly(green), r = poly(warp.planes[0]), b = poly(warp.planes[2])
                let red = LensProfile.Radial.sampled { r($0) / g($0) }, blue = LensProfile.Radial.sampled { b($0) / g($0) }
                if red.values.contains(where: { abs($0 - 1) > 1e-7 }) { p.redScale = red }
                if blue.values.contains(where: { abs($0 - 1) > 1e-7 }) { p.blueScale = blue }
            }
            p.centre = CGPoint(x: warp.cx, y: warp.cy)
        }
        if let vignette, vignette.k.allSatisfy(\.isFinite), vignette.cx.isFinite, vignette.cy.isFinite {
            let k = vignette.k
            p.vignetting = .sampled { r in let r2 = r * r; return 1 + r2 * (k[0] + r2 * (k[1] + r2 * (k[2] + r2 * (k[3] + r2 * k[4])))) }
            if p.distortion == nil { p.centre = CGPoint(x: vignette.cx, y: vignette.cy) }
        }
        return p.corrects ? p : nil
    }

    static func dngOpcodes(_ tiff: TIFF) -> LensProfile? {
        guard tiff.ifds.first?.entries[0xC612] != nil else { return nil }   // DNGVersion
        // The raw IFD's (NewSubfileType 0, or IFD0 where it is the raw one); OpcodeList3 only (see the head).
        let raw = tiff.ifds.first { ($0.entries[0xFE].flatMap(tiff.uint) ?? 0) == 0 && $0.entries[0xC74E] != nil }
        guard let e = raw?.entries[0xC74E], let list = tiff.bytes(e) else { return nil }
        let o = opcodes(list)
        return profile(warp: o.warp, vignette: o.vignette)
    }
}
