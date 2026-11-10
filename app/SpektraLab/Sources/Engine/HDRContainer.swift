//  HDRContainer.swift — how a file carries its HDR: one description, several layouts (RFC-046, 2026-11-05).
//
//  What the HDR *is* — a gain map's 8-bit codes and the headroom H they are encoded against
//  (`HDRGainMap.Attachment`, made by `HDRGainMap` / `HDRGain` exactly as before) — is kept apart from *how a
//  file carries it*. A `HDRProfile` names the layout: how the stored map's codes hold the gain
//  (`StoredMap`), and the declarations that describe that map to each kind of reader (`GainMapDeclaration`).
//  `ExportWriter` asks the profile and does nothing HDR-specific itself, so the next platform that reads HDR
//  its own way is a new declaration and a new entry in `HDRProfile.of`.
//
//  **One map image a file** (measured 2026-11-05, rfc/audits/hdr-social-compat-2026-11-05): given an ISO map
//  and Apple's own, in either order and at any size, ImageIO keeps the ISO map's data and puts Apple's aux URN
//  on that same item — Apple's data is dropped. **Apple's own camera files are the same**: one map, read back
//  as the same codes under both types, its ISO declaration fitted to Apple's coding (GainMapMin −0.444, Gamma
//  0.982; `tools/hdr_conformance.sh`). So a layout chooses one coding for the one map, and every declaration
//  describes that map:
//
//  - **`.iso`**: the codes are log2 gain over log2 H (Gamma 1), declared as ISO 21496-1 only — every
//    export's since 11-03, what Apple Photos reads. Unchanged, byte for byte.
//  - **`.appleCamera`**: the codes are **Apple's own coding** — gain = 1 + (H − 1) · EOTF(code), sRGB's EOTF
//    — so a reader of Apple's map (Xiaohongshu, apps that read only Apple's map) reads it exactly; declared as Apple's map
//    (aux URN, XMP HDRGainMap, MakerApple 33/48) **and** as ISO 21496-1 with the Gamma that brings ISO's
//    reading closest to Apple's: within 0.053 stop at H 4 (mean 0.033), 0.11 at H 8. The camera's own ISO
//    declaration reads its map 0.033 stop (worst 0.042) from Apple's reading. A negative GainMapMin, as the
//    camera's, fits closer but lowers every code-0 pixel for an ISO reader, and code 0 — no gain — is most
//    of a film's map: not taken.
//    The coding was measured on a picture from Apple's camera: MakerApple 33/48 read by Apple's documented formula
//    (`stops(maker33:maker48:)`) gave 2.1406 stops, its ISO GainMapMax; its one map read as Apple's with sRGB's
//    EOTF and as ISO's by its own metadata agree to 0.033 stop on average (gamma 2.2: 0.030; linear: 0.65 off).
//    Apple's map cannot lower a pixel (gain ≥ 1); neither does ours (GainMapMin 0), so nothing is lost. Its
//    headroom is said in MakerApple only up to 3 stops with tag 33 ≥ 1: a map past that is held at 3.
//
//  JPEG is the same (measured 2026-11-05, `auxboth_fmt.swift`): both types given, ImageIO stores one MPF map
//  with the ISO data and Apple's URN on it. So `.appleCamera` is every 8-bit JPEG's and HEIF's
//  (`ExportRecipe.hdrLayoutInEffect`).
//
//  **On the Mac** (HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D8):
//  - **A JPEG says the same map a third way, as Adobe's `hdrgm`** (Ultra HDR 1.0: Lightroom, ACR, Android, the
//    web), written after ImageIO has finished the file (`HDRUltraHDR`: ImageIO writes no hdrgm). It describes
//    the stored codes exactly as the ISO declaration does — Gamma the fitted one, GainMapMin 0, GainMapMax and
//    HDRCapacityMax log2 H, both offsets 0 — so every reader reads one gain. D8 measured the layout (C) HDR in
//    ImageIO's DecodeToHDR and in Adobe Camera Raw 18.6 at H 4, every gain bin within 0.05 stop; both
//    readers follow ISO where ISO and hdrgm disagree, which is why they never may. `HDRProfile.ultraHDR`.
//  - **No 10-bit HEIF** (the desktop's HEIF is 8-bit): `.iso` is not reached by a desktop file this round.
//
//  Future declarations, none built: AVIF and JPEG XL gain maps.

import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// The one map a file stores, as its codes hold the gain.
struct StoredMap: Sendable {
    var width: Int
    var height: Int
    var codes: Data
    /// The headroom the codes are encoded against.
    var headroom: Double
    /// The Gamma the ISO declaration reads the codes with (1: log2 gain linear in the code).
    var isoGamma: Double
}

/// One description of the stored map, for one kind of reader: what it adds to the picture's own properties,
/// what it adds beside the picture, and how a written file is seen to hold it.
protocol GainMapDeclaration: Sendable {
    /// For the log and a failure's words.
    var name: String { get }
    /// The containers it can be written into.
    var formats: Set<ExportRecipe.Format> { get }
    /// What it adds to the picture's properties, before the picture is added (MakerApple's tags).
    func imageProperties(for map: StoredMap) -> [CFString: Any]
    /// Its part beside the picture.
    func attach(_ map: StoredMap, to destination: CGImageDestination) throws
    /// Whether a written file holds it.
    func isPresent(in source: CGImageSource) -> Bool
}

/// ISO 21496-1 (`HDRGainMap.attach`): the map, and HDRToneMap metadata with the stored map's Gamma.
struct ISO21496Declaration: GainMapDeclaration {
    var name: String { "ISO 21496-1 gain map" }
    var formats: Set<ExportRecipe.Format> { [.jpeg, .heif] }
    func imageProperties(for map: StoredMap) -> [CFString: Any] { [:] }
    func attach(_ map: StoredMap, to destination: CGImageDestination) throws {
        let a = HDRGainMap.Attachment(map: .init(width: map.width, height: map.height, subsample: 1, codes: map.codes), headroom: map.headroom)
        try HDRGainMap.attach(a, to: destination, gamma: map.isoGamma)
    }
    func isPresent(in source: CGImageSource) -> Bool { HDRGainMap.present(in: source) }
}

/// Apple's own map (`kCGImageAuxiliaryDataTypeHDRGainMap`), its XMP and its MakerApple headroom, as Apple's
/// camera writes them. With the ISO declaration before it, ImageIO puts it on the ISO map's own item.
struct AppleHDRGainMapDeclaration: GainMapDeclaration {
    var name: String { "Apple HDR gain map" }
    var formats: Set<ExportRecipe.Format> { [.jpeg, .heif] }

    /// `HDRGainMap:HDRGainMapVersion` as Apple's current camera writes it.
    static let version = 131072
    /// MakerApple's tag 33 as the camera writes it: ≥ 1 picks the formula's upper pair of lines.
    static let maker33 = 1.01
    /// The most headroom MakerApple says with tag 33 ≥ 1: 3 stops (tag 48 at 0).
    static let maxStops = 3.0

    /// Stops of headroom from MakerApple 33 and 48: Apple's documented reading ("Applying Apple HDR effect
    /// to your photos"). The camera's 1.01 and 0.5359375 give 2.1406.
    static func stops(maker33 m33: Double, maker48 m48: Double) -> Double {
        let s = m33 < 1 ? (m48 <= 0.01 ? -20 * m48 + 1.8 : -0.101 * m48 + 1.601)
                        : (m48 <= 0.01 ? -70 * m48 + 3.0 : -0.303 * m48 + 2.303)
        return max(s, 0)
    }

    /// Tag 48 for `stops` with tag 33 at `maker33`: the reading's inverse, the stops held to 0 … 3.
    static func maker48(stops: Double) -> Double {
        let s = min(max(stops, 0), maxStops)
        // At 48 = 0.01 both of the formula's lines give 2.3 stops (2.303 − 0.00303 and 3 − 0.7).
        return s > 2.3 ? (3.0 - s) / 70 : (2.303 - s) / 0.303
    }

    /// The headroom a map of `headroom` is written against in Apple's coding: held to what MakerApple says.
    static func headroom(_ headroom: Double) -> Double { pow(2, min(HDRGainMap.top(headroom), maxStops)) }

    /// sRGB's encoding and decoding: the coding the camera's map was measured with.
    static func oetf(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    static func eotf(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    /// A gain of Apple's map, as its reader makes it: 1 + (H − 1) · EOTF(code).
    static func gain(code: UInt8, headroom: Double) -> Double { 1 + (headroom - 1) * eotf(Double(code) / 255) }

    /// The ISO code → Apple code table, for a map encoded against `isoHeadroom` written against `appleHeadroom`.
    static func table(isoHeadroom: Double, appleHeadroom: Double) -> [UInt8] {
        let top = HDRGainMap.top(isoHeadroom), h = max(appleHeadroom, 1.0001)
        return (0...255).map { c in
            let gain = min(pow(2, Double(c) / 255 * top), h)
            return UInt8((oetf(min(max((gain - 1) / (h - 1), 0), 1)) * 255).rounded())
        }
    }

    /// The ISO Gamma whose reading of Apple's codes — log2 gain = log2 H · code^(1/Gamma) — is nearest
    /// Apple's own over every code (the worst code's error, least): 0.6771 at H 4.
    static func isoGamma(headroom: Double) -> Double {
        let top = HDRGainMap.top(headroom), h = max(headroom, 1.0001)
        let truth = (0...255).map { log2(gain(code: UInt8($0), headroom: h)) }
        func worst(_ inv: Double) -> Double {
            (0...255).reduce(0) { max($0, abs(top * pow(Double($1) / 255, inv) - truth[$1])) }
        }
        var lo = 0.5, hi = 3.0
        for _ in 0..<100 {
            let a = lo + (hi - lo) / 3, b = hi - (hi - lo) / 3
            if worst(a) < worst(b) { hi = b } else { lo = a }
        }
        return 1 / ((lo + hi) / 2)
    }

    func imageProperties(for map: StoredMap) -> [CFString: Any] {
        [kCGImagePropertyMakerAppleDictionary: ["33": Self.maker33, "48": Self.maker48(stops: HDRGainMap.top(map.headroom))] as [String: Any]]
    }

    func attach(_ map: StoredMap, to destination: CGImageDestination) throws {
        guard map.codes.count == map.width * map.height else {
            throw HDRGainMap.Failure.write("\(map.codes.count) codes for a \(map.width) × \(map.height) map")
        }
        let meta = CGImageMetadataCreateMutable()
        let ns = "http://ns.apple.com/HDRGainMap/1.0/" as CFString
        var error: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(meta, ns, "HDRGainMap" as CFString, &error) else {
            throw HDRGainMap.Failure.write("Apple's gain map namespace was refused")
        }
        CGImageMetadataSetValueWithPath(meta, nil, "HDRGainMap:HDRGainMapVersion" as CFString, "\(Self.version)" as CFString)
        CGImageMetadataSetValueWithPath(meta, nil, "HDRGainMap:HDRGainMapHeadroom" as CFString, String(format: "%.6f", map.headroom) as CFString)
        let description: [CFString: Any] = [kCGImagePropertyWidth: map.width, kCGImagePropertyHeight: map.height,
                                            kCGImagePropertyBytesPerRow: map.width,
                                            kCGImagePropertyPixelFormat: kCVPixelFormatType_OneComponent8]
        let info: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: map.codes as CFData,
                                     kCGImageAuxiliaryDataInfoDataDescription: description,
                                     kCGImageAuxiliaryDataInfoMetadata: meta]
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeHDRGainMap, info as CFDictionary)
    }

    func isPresent(in source: CGImageSource) -> Bool {
        guard CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = p[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return false }
        return maker["33"] != nil && maker["48"] != nil
    }

    /// What a written file's Apple map says, read as its readers read it: the headroom from MakerApple and
    /// the map's codes, row padding removed. Nil without one. For the checks.
    static func read(_ source: CGImageSource) -> (headroom: Double, width: Int, height: Int, codes: Data)? {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [CFString: Any],
              let d = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let w = d[kCGImagePropertyWidth] as? Int, let h = d[kCGImagePropertyHeight] as? Int,
              let row = d[kCGImagePropertyBytesPerRow] as? Int, let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = p[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
              let m33 = (maker["33"] as? NSNumber)?.doubleValue, let m48 = (maker["48"] as? NSNumber)?.doubleValue else { return nil }
        var codes = Data(capacity: w * h)
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for y in 0..<h { codes.append(contentsOf: b[(y * row)..<(y * row + w)]) }
        }
        return (pow(2, stops(maker33: m33, maker48: m48)), w, h, codes)
    }
}

/// A layout: how the stored map's codes hold the gain, and the declarations of it, with the base it needs.
struct HDRProfile: Sendable {
    let layout: ExportRecipe.HDRLayout
    /// In the order they are written.
    let declarations: [any GainMapDeclaration]
    /// The base's depth the layout needs (the camera's 8 bits); nil: any.
    let depth: Int?

    /// Whether a file of `format` in this layout also says its map as Adobe's `hdrgm` (`HDRUltraHDR`, D8): every
    /// JPEG's. Written after ImageIO's file is finished, of the same stored codes; never in a HEIF (Ultra HDR is
    /// a JPEG container: XMP and MPF).
    func ultraHDR(_ format: ExportRecipe.Format) -> Bool { format == .jpeg }

    /// The containers every one of its declarations can be written into.
    var formats: Set<ExportRecipe.Format> {
        declarations.reduce(Set(ExportRecipe.Format.allCases)) { $0.intersection($1.formats) }
    }

    /// The map the file stores for `a`.
    func stored(_ a: HDRGainMap.Attachment) -> StoredMap {
        switch layout {
        case .iso:
            return StoredMap(width: a.map.width, height: a.map.height, codes: a.map.codes, headroom: a.headroom, isoGamma: 1)
        case .appleCamera:
            typealias Apple = AppleHDRGainMapDeclaration
            let h = Apple.headroom(a.headroom)
            let table = Apple.table(isoHeadroom: a.headroom, appleHeadroom: h)
            // vImage's table lookup, not a Swift loop over the bytes: the loop was 3.7 s of a 45 MP export in a
            // debug build (0.16 s optimised; measured 2026-11-06, the Mac's first HDR exports), and the same bytes.
            var codes = Data(count: a.map.codes.count)
            codes.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                a.map.codes.withUnsafeBytes { (i: UnsafeRawBufferPointer) in
                    guard i.count > 0 else { return }
                    var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i.baseAddress!), height: 1,
                                            width: vImagePixelCount(i.count), rowBytes: i.count)
                    var dst = vImage_Buffer(data: o.baseAddress!, height: 1, width: vImagePixelCount(i.count), rowBytes: i.count)
                    let done = table.withUnsafeBufferPointer {
                        vImageTableLookUp_Planar8(&src, &dst, $0.baseAddress!, vImage_Flags(kvImageNoFlags))
                    }
                    if done != kvImageNoError { for k in 0..<i.count { o[k] = table[Int(i[k])] } }
                }
            }
            return StoredMap(width: a.map.width, height: a.map.height, codes: codes, headroom: h, isoGamma: Apple.isoGamma(headroom: h))
        }
    }

    static func of(_ layout: ExportRecipe.HDRLayout) -> HDRProfile {
        switch layout {
        case .iso: HDRProfile(layout: .iso, declarations: [ISO21496Declaration()], depth: nil)
        // The ISO declaration first: ImageIO keeps its data, and puts Apple's URN on that same item.
        case .appleCamera: HDRProfile(layout: .appleCamera, declarations: [ISO21496Declaration(), AppleHDRGainMapDeclaration()], depth: 8)
        }
    }
}
