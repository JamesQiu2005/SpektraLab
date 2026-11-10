// hdr_conformance.swift — how an HDR photo carries its gain map, and whether its readers agree (RFC-046).
//
//   tools/hdr_conformance.sh FILE... [--expect iso|appleCamera] [--hdrgm]
//
// For each file: the base (container, bits, colour), the ISO 21496-1 map (its headroom and Gamma), Apple's own
// map (MakerApple 33/48, XMP HDRGainMapVersion and Headroom), how many map images the file stores, and the
// layout that makes: `iso` (SpektraLab's exports before RFC-046), `appleCamera` (one map declared both ways: Apple's
// camera's own, and every 8-bit JPEG and HEIF SpektraLab writes of an HDR frame), `two-maps` (separate ISO and Apple maps; not seen yet), `apple-only`,
// or `none`. Where both declarations are there, it
// reads the gain each kind of reader makes of each pixel and says how far apart they are. With `--expect` it
// fails a file whose layout is another, or whose readers disagree past the RFC's bounds. Standalone: no app
// sources, so it reads any file — another app's export, the camera's own (rfc/audits/hdr-social-compat-2026-11-05).
//
// **The Mac's** (HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D8): a JPEG's Adobe hdrgm (Ultra HDR 1.0)
// is read from the file's own bytes — the primary's `hdrgm:Version` and GContainer directory, the MPF index, the
// map image's fields — by a walk of its own (not the app's `HDRUltraHDR`), and held to the ISO declaration:
// GainMapMin/Max, Gamma, OffsetSDR/HDR = Base/AlternateOffset, HDRCapacityMin/Max = Base/AlternateHeadroom, each
// within 1e-6, and the directory's GainMap length the MPF's. A file whose hdrgm disagrees fails, `--expect` or
// not (two readers would show two pictures); `--hdrgm` fails a JPEG with none.

import CoreGraphics
import Foundation
import ImageIO

func eotf(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
func appleStops(_ m33: Double, _ m48: Double) -> Double {
    max(m33 < 1 ? (m48 <= 0.01 ? -20 * m48 + 1.8 : -0.101 * m48 + 1.601) : (m48 <= 0.01 ? -70 * m48 + 3.0 : -0.303 * m48 + 2.303), 0)
}
func count(_ data: Data, _ s: String) -> Int {
    var n = 0, from = data.startIndex
    while let r = data.range(of: Data(s.utf8), in: from..<data.endIndex) { n += 1; from = r.upperBound }
    return n
}
struct Plane { var width: Int; var height: Int; var codes: [UInt8] }
func plane(_ info: [CFString: Any]) -> Plane? {
    guard let d = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any], let w = d[kCGImagePropertyWidth] as? Int,
          let h = d[kCGImagePropertyHeight] as? Int, let row = d[kCGImagePropertyBytesPerRow] as? Int,
          let data = info[kCGImageAuxiliaryDataInfoData] as? Data else { return nil }
    var out = [UInt8](repeating: 0, count: w * h)
    data.withUnsafeBytes { b in for y in 0..<h { for x in 0..<w { out[y * w + x] = b[y * row + x] } } }
    return Plane(width: w, height: h, codes: out)
}
/// The ISO reading's parameters (one channel): min, max, Gamma, AlternateHeadroom, offsets.
struct ISO { var min = 0.0, max = 0.0, gamma = 1.0, alternate = 0.0, base = 0.0, alt = 0.0 }
func iso(_ info: [CFString: Any]) -> ISO? {
    guard let md = info[kCGImageAuxiliaryDataInfoMetadata] else { return nil }
    let m = md as! CGImageMetadata
    func value(_ t: CGImageMetadataTag?) -> Double? { t.flatMap { CGImageMetadataTagCopyValue($0) as? String }.flatMap(Double.init) }
    var r = ISO()
    r.alternate = value(CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:AlternateHeadroom" as CFString)) ?? 0
    if let arr = CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:ChannelMetadata" as CFString).flatMap({ CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }),
       let f = arr.first.flatMap({ CGImageMetadataTagCopyValue($0) as? [String: CGImageMetadataTag] }) {
        r.min = value(f["GainMapMin"]) ?? 0; r.max = value(f["GainMapMax"]) ?? 0; r.gamma = value(f["Gamma"]) ?? 1
        r.base = value(f["BaseOffset"]) ?? 0; r.alt = value(f["AlternateOffset"]) ?? 0
    }
    return r
}

/// A JPEG's hdrgm, read from its bytes: the primary's version and its directory's GainMap length, the MPF's
/// map size, and the map image's fields. Nil for a file that is not a JPEG with an MPF map.
struct HDRGM { var primaryVersion: String?; var mapLength: Int?; var mpfMapSize: Int; var mpfConsistent: Bool; var fields: [String: String] }
func hdrgm(_ b: [UInt8]) -> HDRGM? {
    func seg(_ start: Int) -> [(m: UInt8, at: Int, n: Int)]? {
        guard start + 4 < b.count, b[start] == 0xFF, b[start + 1] == 0xD8 else { return nil }
        var i = start + 2, out: [(UInt8, Int, Int)] = []
        while i + 4 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {
            let n = Int(b[i + 2]) << 8 | Int(b[i + 3]); out.append((b[i + 1], i, 2 + n)); i += 2 + n
        }
        return out
    }
    func has(_ at: Int, _ s: String) -> Bool { let id = Array(s.utf8); return at + id.count <= b.count && Array(b[at..<(at + id.count)]) == id }
    func xmp(_ ss: [(m: UInt8, at: Int, n: Int)]) -> String {
        ss.filter { $0.m == 0xE1 && has($0.at + 4, "http://ns.adobe.com/xap/1.0/\0") }
            .map { String(decoding: b[($0.at + 33)..<($0.at + $0.n)], as: UTF8.self) }.joined()
    }
    guard let p = seg(0), let mpf = p.first(where: { $0.m == 0xE2 && has($0.at + 4, "MPF\0") }) else { return nil }
    let t = mpf.at + 8, big = b[t] == 0x4D
    func u(_ o: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(b[o + (big ? $1 : n - 1 - $1)]) } }
    let ifd = t + u(t + 4, 4)
    var list = -1
    for k in 0..<u(ifd, 2) where u(ifd + 2 + 12 * k, 2) == 0xB002 { list = t + u(ifd + 2 + 12 * k + 8, 4) }
    guard list > 0 else { return nil }
    let primarySize = u(list + 4, 4), mapSize = u(list + 20, 4), mapStart = t + u(list + 24, 4)
    guard let m = seg(mapStart) else { return nil }
    func value(_ x: String, _ name: String) -> String? {
        guard let r = x.range(of: name + "=\""), let e = x[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(x[r.upperBound..<e])
    }
    let px = xmp(p), mx = xmp(m)
    var fields: [String: String] = [:]
    for k in ["Version", "GainMapMin", "GainMapMax", "Gamma", "OffsetSDR", "OffsetHDR", "HDRCapacityMin", "HDRCapacityMax", "BaseRenditionIsHDR"] {
        if let v = value(mx, "hdrgm:" + k) { fields[k] = v }
    }
    var length: Int?
    if let g = px.range(of: "Item:Semantic=\"GainMap\"") {
        let tail = String(px[g.lowerBound...].prefix(400))
        length = value(tail, "Item:Length").flatMap { Int($0) }
    }
    return HDRGM(primaryVersion: value(px, "hdrgm:Version"), mapLength: length, mpfMapSize: mapSize,
                 mpfConsistent: primarySize == mapStart && mapStart + mapSize == b.count, fields: fields)
}

var files: [String] = [], expect: String?, needHDRGM = false
var i = 1
let args = CommandLine.arguments
while i < args.count {
    if args[i] == "--expect", i + 1 < args.count { expect = args[i + 1]; i += 2 }
    else if args[i] == "--hdrgm" { needHDRGM = true; i += 1 }
    else { files.append(args[i]); i += 1 }
}
guard !files.isEmpty else { print("usage: hdr_conformance.sh FILE... [--expect iso|appleCamera]"); exit(2) }
var failures = 0
for path in files {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let bytes = try? Data(contentsOf: url) else {
        print("\(path): cannot be read"); failures += 1; continue
    }
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    let kind = CGImageSourceGetType(src) as String? ?? "?"
    let depth = (p[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0
    let profile = p[kCGImagePropertyProfileName] as? String ?? "?"
    let isoInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any]
    let appleInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [CFString: Any]
    let maker = p[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
    let m33 = (maker?["33"] as? NSNumber)?.doubleValue, m48 = (maker?["48"] as? NSNumber)?.doubleValue
    let urns = count(bytes, "urn:com:apple:photo:2020:aux:hdrgainmap"), tmaps = count(bytes, "tmap")
    let isoP = isoInfo.flatMap(iso), isoPlane = isoInfo.flatMap(plane), applePlane = appleInfo.flatMap(plane)
    // One stored map declared both ways reads back the same codes under both types.
    let shared = isoPlane != nil && applePlane != nil && isoPlane!.codes == applePlane!.codes
    let layout: String = switch (isoInfo != nil, appleInfo != nil && m33 != nil && m48 != nil) {
    case (true, false): "iso"
    case (true, true): shared ? "appleCamera" : "two-maps"
    case (false, true): "apple-only"
    case (false, false): "none"
    }
    print("\(url.lastPathComponent): \(kind), \(depth)-bit, \(profile); layout \(layout)")
    if let isoP { print(String(format: "  ISO 21496-1: headroom %.4f stops, GainMapMin %.4f, Max %.4f, Gamma %.4f", isoP.alternate, isoP.min, isoP.max, isoP.gamma)) }
    else { print("  ISO 21496-1: absent") }
    if let m33, let m48, appleInfo != nil {
        print(String(format: "  Apple: MakerApple 33 %.4f, 48 %.6f -> %.4f stops; Apple aux URN ×%d, ISO tmap ×%d; %@", m33, m48, appleStops(m33, m48), urns, tmaps,
                     shared ? "one stored map" : "two stored maps"))
    } else { print("  Apple: \(appleInfo == nil ? "no aux map" : "aux map without MakerApple 33/48")") }
    var agree = true
    if let isoP, let a = applePlane, let s = isoPlane, let m33, let m48, a.width == s.width, a.height == s.height {
        let H = pow(2, appleStops(m33, m48))
        var sum = 0.0, worst = 0.0, n = 0
        for k in stride(from: 0, to: a.codes.count, by: 3) {
            let appleLog = log2(1 + (H - 1) * eotf(Double(a.codes[k]) / 255))
            let c = pow(Double(s.codes[k]) / 255, 1 / isoP.gamma)
            let isoLog = max(log2(pow(2, isoP.min + (isoP.max - isoP.min) * c) * (1 + isoP.base) - isoP.alt), 0)
            let e = abs(appleLog - isoLog); sum += e; worst = max(worst, e); n += 1
        }
        let mean = sum / Double(max(n, 1))
        print(String(format: "  the two readings: mean |Δ| %.4f stop, worst %.4f", mean, worst))
        agree = mean <= 0.04 && worst <= 0.1
    }
    // Adobe's hdrgm (a JPEG's): every field, and each the ISO declaration's.
    var adobeOK = true
    if kind == "public.jpeg" {
        if let g = hdrgm([UInt8](bytes)), !g.fields.isEmpty {
            let f = g.fields.compactMapValues(Double.init)
            func same(_ a: Double?, _ b: Double?) -> Bool { a != nil && b != nil && abs(a! - b!) < 1e-6 }
            let equal = isoP.map { p in same(f["GainMapMin"], p.min) && same(f["GainMapMax"], p.max) && same(f["Gamma"], p.gamma)
                && same(f["OffsetSDR"], p.base) && same(f["OffsetHDR"], p.alt) && same(f["HDRCapacityMin"], 0)
                && same(f["HDRCapacityMax"], p.alternate) } ?? false
            let index = g.primaryVersion == "1.0" && g.fields["Version"] == "1.0" && g.mapLength == g.mpfMapSize && g.mpfConsistent
                && g.fields["BaseRenditionIsHDR"] == "False"
            print("  hdrgm: \(g.fields.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); directory GainMap \(g.mapLength.map(String.init) ?? "absent") B (MPF \(g.mpfMapSize)); \(equal ? "the ISO declaration's" : "NOT the ISO declaration's")\(index ? "" : "; its index is not consistent")")
            adobeOK = equal && index
        } else {
            print("  hdrgm: absent")
            adobeOK = !needHDRGM
        }
        if !adobeOK { print("  hdrgm: FAILED"); failures += expect == nil ? 1 : 0 }
    }
    if let expect {
        let ok = layout == expect && (expect != "appleCamera" || (depth == 8 && agree)) && adobeOK
        print("  expected \(expect): \(ok ? "ok" : "FAILED")")
        if !ok { failures += 1 }
    }
}
exit(failures == 0 ? 0 : 1)
