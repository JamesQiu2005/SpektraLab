// lens_profile_selftest.swift — the app's own lens correction (LensProfile, LensProfileReader, LensCorrection):
// synthetic cases that always run, and the samples over RAW_decode_tests when that folder is here.
//
// The synthetic cases: the radial curve through its knots; Sony's tags and a DNG's opcodes read from bytes made here;
// the kernel's mapping read back pixel by pixel from a picture of its own coordinates (each pixel's source, to
// 0.02 px); the gain on a flat field; "hide distorted areas" leaving no empty pixel at the same extent; the keys.
//
// The samples (`RAW_decode_tests/`, local and never in the repository; absent, the run says SKIPPED loudly, AGENTS.md
// trap 26): a table per file of camera, lens, focal length, who corrects, and
//
// - a Sony ARW: the radial residual of Core Image's uncorrected decode and of the app's corrected decode against
//   (a) the camera's own preview JPEG and (b) the same decode corrected by Adobe's measured profile of the lens (Camera
//   Raw's LCP, where this Mac has one), a similarity (scale and shift, fitted robustly) removed. The bar: corrected
//   ≤ 0.1 % of the half-diagonal at every patch where uncorrected is larger. A JPEG that registers to the uncorrected
//   decode was made with the camera's distortion compensation off, and is said to be, not counted as a pass.
// - a DNG Core Image corrects (Leica Q3): the app's reading of its OpcodeList3, applied to Core Image's uncorrected
//   decode, against Core Image's own corrected decode — the kernel and the parser on a real file.
// - a Nikon and a Canon frame: the engine's decode and Apple's stock decode, with Lens Correction on, made through
//   today's `RawExposure.prepare` / `DigitalDecode.image`, bit for bit against the way they were made before 2.4.0.
//
//   tools/lens_profile_selftest.sh            (LENS_SELFTEST_DISABLE_STEP=1: the app's step left out — must fail)

import CoreImage
import Foundation
import ImageIO
import SwiftUI

extension Color { init(hexString: String) { self = .gray } }

@main
enum LensProfileSelftest {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var passes = 0
    static func expect(_ ok: Bool, _ label: String) { if ok { passes += 1 } else { failures.append(label); print("FAIL: \(label)") } }
    static let disableStep = ProcessInfo.processInfo.environment["LENS_SELFTEST_DISABLE_STEP"] != nil

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let started = Date()
        synthetic()
        lcpCases()
        databaseCases()
        let adobe = adobeCases()
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                       : FileManager.default.currentDirectoryPath + "/RAW_decode_tests")
        modelCases()
        reportCase(adobe)
        if FileManager.default.fileExists(atPath: root.path) { samples(root, adobe: adobe); resolutionSamples(root, adobe: adobe) } else {
            print("SKIPPED: no samples at \(root.path) — the sample cases did not run")
        }
        try? FileManager.default.removeItem(at: scratch)
        print(String(format: "lens_profile_selftest: %d checks, %d failures, %.1f s", passes + failures.count, failures.count,
                     Date().timeIntervalSince(started)))
        if !failures.isEmpty { failures.forEach { print("  - \($0)") }; exit(1) }
    }

    // MARK: - synthetic

    static func synthetic() {
        // The curve passes through its knots, and between them stays within them where they are monotone.
        let c = LensProfile.Radial(radii: [0, 0.25, 0.5, 0.75, 1], values: [1, 1.001, 1.004, 1.009, 1.02])
        expect(zip(c.radii, c.values).allSatisfy { abs(c.at($0) - $1) < 1e-12 }, "the radial curve passes through its knots")
        expect(stride(from: 0.0, to: 1, by: 0.01).allSatisfy { c.at($0) <= c.at($0 + 0.01) + 1e-12 }, "a monotone curve stays monotone")

        // Sony's tags from a little-endian TIFF made here.
        let dist = [-2, 0, -2, -3, -6, -10, -15, -20, -23, -22, -18, -5, 14, 45, 86, 140]
        let vig = (0..<16).map { $0 * 800 }
        let ca = Array(repeating: 128, count: 16) + Array(repeating: -256, count: 16)
        let tiff = sonyTIFF(distortion: dist, vignetting: vig, ca: ca)
        guard let t = LensProfileReader.TIFF(data: tiff), let k = LensProfileReader.sonyKnots(t) else {
            expect(false, "a made Sony TIFF reads"); return
        }
        expect(k.distortion == dist && k.vignetting == vig && k.red == Array(ca[0..<16]) && k.blue == Array(ca[16...]),
               "Sony's knots read as written (count first, CA red then blue)")
        expect(k.distortionSetting == 0 && k.vignettingSetting == 257 && k.caSetting == 1, "Sony's settings read")
        let p = LensProfileReader.sonyProfile(k)
        expect(p?.source == .sonyEmbedded, "a Sony profile says where it came from")
        expect(p?.vignetting == nil && p?.redScale == nil && p?.blueScale == nil, "Sony's vignetting and CA are left off")
        expect(dist.indices.allSatisfy { abs((p?.distortion?.at(Double($0) / 15) ?? 0) - (1 + Double(dist[$0]) / 16384)) < 1e-12 },
               "Sony's distortion: knot i of n at i/(n−1), D = 1 + v·2⁻¹⁴")
        let withAll = LensProfileReader.sonyProfile(k, includeCA: true, includeVignetting: true)
        expect(abs((withAll?.redScale?.at(0) ?? 0) - (1 + 128.0 / 2_097_152)) < 1e-15, "Sony's CA reading, when asked: 1 + v·2⁻²¹")
        expect(LensProfileReader.sonyKnots(LensProfileReader.TIFF(data: sonyTIFF(distortion: dist, vignetting: vig, ca: ca, make: "NIKON"))!) == nil,
               "another maker's file carries no Sony knots")

        // A DNG's opcodes from big-endian bytes made here.
        let planes: [[Double]] = [[0.9997, -0.0569, -0.0799, 0.0444, 0, 0], [0.9993, -0.0558, -0.0809, 0.0447, 0, 0],
                                  [0.9991, -0.0547, -0.0814, 0.0443, 0, 0]]
        let list = opcodeList(warp: planes, vignette: [-0.3, 0.05, 0, 0, 0], cx: 0.5, cy: 0.5)
        let o = LensProfileReader.opcodes(list)
        expect(o.warp?.planes == planes && o.warp?.cx == 0.5 && o.vignette?.k == [-0.3, 0.05, 0, 0, 0],
               "WarpRectilinear and FixVignetteRadial read as written")
        if let dp = LensProfileReader.profile(warp: o.warp, vignette: o.vignette) {
            let r = 0.8, r2 = r * r
            let g = planes[1], red = planes[0]
            let want = g[0] + g[1] * r2 + g[2] * r2 * r2 + g[3] * r2 * r2 * r2
            let wantRed = (red[0] + red[1] * r2 + red[2] * r2 * r2 + red[3] * r2 * r2 * r2) / want
            expect(abs((dp.distortion?.at(r) ?? 0) - want) < 2e-6, "the warp's green plane is the distortion (\(dp.distortion?.at(r) ?? 0) vs \(want))")
            expect(abs((dp.redScale?.at(r) ?? 0) - wantRed) < 2e-6, "red's plane over green's is red's scale")
            expect(abs((dp.vignetting?.at(r) ?? 0) - (1 - 0.3 * r2 + 0.05 * r2 * r2)) < 2e-6, "the vignette's gain is 1 + k0 r² + k1 r⁴…")
        } else { expect(false, "the opcodes make a profile") }
        expect(LensProfileReader.opcodes(Data([0, 0, 0, 1, 0, 0, 0, 1])).warp == nil, "a truncated opcode list reads as nothing")

        kernelCases()
        keyCases()
    }

    /// The kernel read back: a picture whose pixels are their own coordinates, corrected, holds at each pixel the
    /// point it was taken from.
    static func kernelCases() {
        guard LensProfile.kernel != nil else { expect(false, "the lens kernel compiles"); return }
        expect(true, "the lens kernel compiles")
        let w = 600, h = 400
        var coords = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            // Core Image's y up: the bitmap's first row is the picture's top.
            let i = (y * w + x) * 4
            coords[i] = Float(x) + 0.5; coords[i + 1] = Float(h - 1 - y) + 0.5; coords[i + 2] = 0
        } }
        let data = coords.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
        var profile = LensProfile(source: .file)
        profile.distortion = .sampled { 1 - 0.03 * $0 * $0 + 0.01 * $0 * $0 * $0 * $0 }   // barrel: no empty area
        func read(_ img: CIImage) -> [Float] {
            var out = [Float](repeating: 0, count: w * h * 4)
            ctx.render(img, toBitmap: &out, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
            return out
        }
        let out = profile.apply(to: image, hideDistortedAreas: false)
        expect(out.extent == image.extent, "the corrected picture has its input's extent")
        let px = read(out)
        let map = LensProfile.Mapping(profile: profile, width: Double(w), height: Double(h), zoom: 1)
        var worst = 0.0
        for y in stride(from: 20, to: h - 20, by: 7) { for x in stride(from: 20, to: w - 20, by: 7) {
            let p = CGPoint(x: Double(x) + 0.5, y: Double(h - 1 - y) + 0.5)
            let s = map.sources(of: p)[0]
            let i = (y * w + x) * 4
            worst = max(worst, hypot(Double(px[i]) - s.x, Double(px[i + 1]) - s.y))
        } }
        expect(worst < 0.02, String(format: "each pixel is taken from the profile's point (worst %.4f px)", worst))

        // Distortion at half: halfway in radius.
        let half = read(profile.apply(to: image, distortion: 0.5, hideDistortedAreas: false))
        let i = ((h / 2 - 150) * w + (w / 2 + 250)) * 4
        let p = CGPoint(x: Double(w / 2 + 250) + 0.5, y: Double(h - 1 - (h / 2 - 150)) + 0.5)
        let s = LensProfile.Mapping(profile: profile, width: Double(w), height: Double(h), zoom: 1, distortion: 0.5).sources(of: p)[0]
        expect(hypot(Double(half[i]) - s.x, Double(half[i + 1]) - s.y) < 0.02, "a distortion amount of 50 % moves half as far")

        // Pincushion with hide on: zoomed, no empty pixel, same extent; hide off: the corners are empty.
        var pin = LensProfile(source: .file)
        pin.distortion = .sampled { 1 + 0.03 * $0 * $0 }
        let zoom = pin.hideZoom(width: Double(w), height: Double(h))
        expect(zoom > 1.02 && zoom < 1.04, String(format: "hide's zoom covers the corners (%.4f, D(1) = 1.03)", zoom))
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let hidden = read(pin.apply(to: flat))
        expect(stride(from: 0, to: hidden.count, by: 4).allSatisfy { hidden[$0] > 0.49 }, "hide distorted areas: no empty pixel")
        let shown = read(pin.apply(to: flat, hideDistortedAreas: false))
        expect(shown[0] == 0 && shown[(w * h - 1) * 4] == 0, "hide off: the corners outside the source are black")

        // The gain on a flat field, looked up at the source radius.
        var v = LensProfile(source: .file)
        v.vignetting = .sampled { 1 + 0.8 * $0 * $0 }
        let g = read(v.apply(to: flat))
        let corner = Double(g[(1 * w + 1) * 4]), centre = Double(g[((h / 2) * w + w / 2) * 4])
        let rCorner = hypot(Double(w) / 2 - 1.5, Double(h) / 2 - 1.5) / hypot(Double(w) / 2, Double(h) / 2)
        expect(abs(centre - 0.5) < 2e-3 && abs(corner - 0.5 * (1 + 0.8 * rCorner * rCorner)) < 3e-3,
               String(format: "the gain multiplies in linear light (centre %.4f, corner %.4f)", centre, corner))
        let quarter = read(v.apply(to: flat, vignetting: 0.5))
        expect(abs(Double(quarter[(1 * w + 1) * 4]) - 0.5 * (1 + 0.8 * rCorner * rCorner).squareRoot()) < 3e-3,
               "a light-falloff amount of 50 % is half the stops")
    }

    static func keyCases() {
        var on = DecodeSettings(); on.lensCorrection = true
        let off = DecodeSettings()
        let arw = URL(fileURLWithPath: "/nowhere/DSC0001.ARW"), nef = URL(fileURLWithPath: "/nowhere/DSC0001.NEF")
        expect(LensCorrection.word(source: arw, decode: on) == "|lens=sony-embedded.1", "a Sony frame with lens correction on has a word")
        expect(LensCorrection.word(source: arw, decode: off).isEmpty, "a Sony frame with it off has none")
        expect(LensCorrection.word(source: nil, fileName: "a.arw", decode: on) == "|lens=sony-embedded.1", "an away Sony original keeps its word")
        expect(LensCorrection.word(source: nef, decode: on).isEmpty, "a Nikon frame has none: Core Image corrects it")
        expect(LensCorrection.word(source: arw, decode: on, isRAW: false).isEmpty, "a picture that is not a RAW has none")
        expect(on.pixelsKey(source: nef) == on.pixelsKey, "a Nikon frame's pixels key is what it was")
        expect(on.pixelsKey(source: arw) != on.pixelsKey, "a Sony frame's pixels key moves: no kept picture of it is reused")
        expect(off.pixelsKey(source: arw) == off.pixelsKey, "with it off, a Sony frame's key is what it was")
        let made = MaskMadeOn(lensCorrection: true, lensWord: "|lens=sony-embedded.1")
        expect(made.matches(lensCorrection: true, lensWord: "|lens=sony-embedded.1"), "a Sony mask made today sits on today's decode")
        expect(!MaskMadeOn(lensCorrection: true).matches(lensCorrection: true, lensWord: "|lens=sony-embedded.1"),
               "a Sony mask made with lens correction on before 2.4.0 is marked")
        expect(MaskMadeOn(lensCorrection: true).matches(lensCorrection: true, lensWord: ""), "a Nikon mask is not")
        let old = try? JSONDecoder().decode(MaskMadeOn.self, from: Data(#"{"lensCorrection":true}"#.utf8))
        expect(old == MaskMadeOn(lensCorrection: true) && (try? JSONEncoder().encode(old!)).map { String(decoding: $0, as: UTF8.self) } == #"{"lensCorrection":true}"#,
               "a record without the field reads, and writes back as it was")
    }

    // MARK: - bytes made here

    static func sonyTIFF(distortion: [Int], vignetting: [Int], ca: [Int], make: String = "SONY") -> Data {
        var b = [UInt8]()
        func u16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        b += Array("II".utf8); u16(42); u32(8)
        // IFD0: Make (0x10F), SubIFDs (0x14A); 2 entries.
        let ifd0 = 8, sub = ifd0 + 2 + 2 * 12 + 4
        let subCount = 6, data = sub + 2 + subCount * 12 + 4
        let makeBytes = Array(make.utf8) + [0]
        var heap = [UInt8]()
        func place(_ bytes: [UInt8]) -> Int { let o = data + heap.count; heap += bytes; if heap.count % 2 == 1 { heap.append(0) }; return o }
        let makeAt = place(makeBytes)
        func int16s(_ v: [Int]) -> [UInt8] { ([v.count] + v).flatMap { [UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF)] } }
        let vAt = place(int16s(vignetting)), cAt = place(int16s(ca)), dAt = place(int16s(distortion))
        u16(2)
        u16(0x10F); u16(2); u32(makeBytes.count); u32(makeAt)
        u16(0x14A); u16(4); u32(1); u32(sub)
        u32(0)
        u16(subCount)
        u16(0x7031); u16(3); u32(1); u16(257); u16(0)
        u16(0x7032); u16(8); u32(vignetting.count + 1); u32(vAt)
        u16(0x7034); u16(3); u32(1); u16(1); u16(0)
        u16(0x7035); u16(8); u32(ca.count + 1); u32(cAt)
        u16(0x7036); u16(3); u32(1); u16(0); u16(0)
        u16(0x7037); u16(8); u32(distortion.count + 1); u32(dAt)
        u32(0)
        return Data(b + heap)
    }

    static func opcodeList(warp: [[Double]], vignette: [Double], cx: Double, cy: Double) -> Data {
        var b = [UInt8]()
        func u32(_ v: Int) { b += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func f64(_ v: Double) { let bits = v.bitPattern; for i in (0..<8).reversed() { b.append(UInt8((bits >> (8 * UInt64(i))) & 0xFF)) } }
        u32(2)
        u32(1); u32(0x01030000); u32(0); u32(4 + 48 * warp.count + 16); u32(warp.count)
        for p in warp { p.forEach(f64) }
        f64(cx); f64(cy)
        u32(3); u32(0x01030000); u32(0); u32(56)
        vignette.forEach(f64); f64(cx); f64(cy)
        return Data(b)
    }

    // MARK: - the samples

    static let rawExtensions: Set<String> = ["arw", "nef", "cr3", "raf", "rw2", "dng", "orf"]

    static func samples(_ root: URL, adobe: LensDatabase?) {
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { rawExtensions.contains($0.pathExtension.lowercased()) && !$0.path.contains("/_") }
            .sorted { $0.path < $1.path }
        print("\n\(files.count) RAW samples under \(root.path)\(disableStep ? "  [LENS_SELFTEST_DISABLE_STEP: the app's step is left out]" : "")")
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
        print(pad("file", 16) + pad("camera", 22) + pad("lens", 36) + "focal  who corrects")
        var nikon: URL?, canon: URL?, leica: URL?, sony: [URL] = []
        for url in files {
            let facts = Facts(url)
            print(pad(url.lastPathComponent, 16) + pad(facts.camera, 22) + pad(facts.lens, 36)
                  + pad(String(format: "%3.0f mm", facts.focal), 7) + facts.corrector.rawValue)
            let ext = url.pathExtension.lowercased()
            if ext == "nef", nikon == nil { nikon = url }
            if ext == "cr3", canon == nil { canon = url }
            if ext == "dng", facts.supported, leica == nil { leica = url }
            if facts.corrector == .app, ext == "arw" { sony.append(url) }
            // Who corrects is what was measured on this Mac (2026-11-13): Core Image for these, the app for Sony.
            if ["nef", "cr3", "raf", "rw2"].contains(ext) { expect(facts.corrector == .coreImage, "\(url.lastPathComponent): Core Image corrects it") }
            if ext == "arw" { expect(facts.corrector == .app, "\(url.lastPathComponent): the app corrects a Sony ARW") }
            if ext == "orf" { expect(facts.corrector == .nobody, "\(url.lastPathComponent): nobody corrects an E-300") }
        }
        for url in sony { sonyCase(url) }
        if let first = sony.first { pathCase(first) }
        if let leica { opcodeCase(leica) } else { print("SKIPPED: no DNG Core Image corrects among the samples") }
        for url in [nikon, canon].compactMap({ $0 }) { identityCase(url) }
        if nikon == nil || canon == nil { print("SKIPPED: no Nikon or no Canon sample for the bit-identity check") }
        if let adobe { databaseSamples(files, adobe) } else { print("SKIPPED: no Adobe lens profiles installed — the database's sample cases did not run") }
    }

    struct Facts {
        var camera = "", lens = "", focal = 0.0, supported = false, corrector = LensCorrection.Corrector.nobody
        init(_ url: URL) {
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)
            let p = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let aux = p[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
            camera = ((p[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            lens = ((exif[kCGImagePropertyExifLensModel as String] ?? aux[kCGImagePropertyExifAuxLensModel as String]) as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            focal = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? 0
            guard let f = CIRAWFilter(imageURL: url) else { return }
            supported = f.isLensCorrectionSupported
            var on = DecodeSettings(); on.lensCorrection = true
            corrector = LensCorrection.prepare(f, url: url, decode: on, coreImageAlways: true)
        }
    }

    // MARK: Sony against its JPEG and Adobe's profile

    static func sonyCase(_ url: URL) {
        guard let t = LensProfileReader.tiff(url), let k = LensProfileReader.sonyKnots(t),
              let profile = LensProfileReader.sonyProfile(k) else { expect(false, "\(url.lastPathComponent): Sony's knots read"); return }
        let facts = Facts(url)
        print("\n\(url.lastPathComponent) — \(facts.camera), \(facts.lens), \(Int(facts.focal)) mm; in camera: distortion \(k.distortionSetting ?? -1), shading \(k.vignettingSetting ?? -1), CA \(k.caSetting ?? -1)")
        let applied: LensProfile? = disableStep ? nil : profile

        // (a) the camera's JPEG.
        if let (jpeg, w, h) = Oracle.jpeg(t) {
            let un = Oracle.render(Oracle.decode(url, profile: nil), width: w, space: Oracle.srgb).luma
            let co = Oracle.render(Oracle.decode(url, profile: applied, hide: false), width: w, space: Oracle.srgb).luma
            let R = hypot(Double(w), Double(h)) / 2
            let ru = Oracle.residuals(jpeg.luma, un), rc = Oracle.residuals(jpeg.luma, co)
            let mu = ru.map { abs($0.1) }.max() ?? .nan, mc = rc.map { abs($0.1) }.max() ?? .nan
            print(String(format: "  vs its JPEG (%dx%d, %d patches): uncorrected max %.2f px (%.3f %%), corrected max %.2f px (%.3f %%)",
                         w, h, ru.count, mu, 100 * mu / R, mc, 100 * mc / R))
            if mu / R <= 0.001 {
                print("  → the JPEG was not distortion-corrected in camera (0x7036 = \(k.distortionSetting ?? -1)): no verdict from it")
            } else {
                let bad = zip(ru, rc).filter { abs($0.0.1) / R > 0.001 && abs($0.1.1) / R > 0.001 }
                expect(bad.isEmpty, "\(url.lastPathComponent): corrected ≤ 0.1 % of the half-diagonal against the camera's JPEG")
            }
        } else { print("  no JPEG in the file") }

        // (b) Adobe's measured profile of the same lens, at the frame's focal length.
        guard let lcp = Oracle.lcpDistortion(lens: facts.lens, focal: facts.focal) else {
            print("  no Adobe profile of \(facts.lens) on this Mac: distortion not verified for this lens"); return
        }
        let w = 3000
        let reference = Oracle.decode(url, profile: lcp.profile, hide: false)
        let ref = Oracle.render(reference, width: w, space: Oracle.srgb).luma
        let un = Oracle.render(Oracle.decode(url, profile: nil), width: w, space: Oracle.srgb).luma
        let co = Oracle.render(Oracle.decode(url, profile: applied, hide: false), width: w, space: Oracle.srgb).luma
        let R = hypot(Double(ref.w), Double(ref.h)) / 2
        let ru = Oracle.residuals(ref, un), rc = Oracle.residuals(ref, co)
        print("  vs Adobe's \(lcp.name) (\(lcp.note)), \(ref.w)x\(ref.h), a scale and shift removed:")
        print("     r     uncorrected          corrected")
        for (a, b) in zip(Oracle.binned(ru), Oracle.binned(rc)) {
            print(String(format: "    %.2f  %+6.2f px %6.3f %%   %+6.2f px %6.3f %%  (%d)", a.0, a.1, 100 * abs(a.1) / R, b.1, 100 * abs(b.1) / R, b.2))
        }
        let mu = ru.map { abs($0.1) }.max() ?? .nan, mc = rc.map { abs($0.1) }.max() ?? .nan
        print(String(format: "     max  %6.2f px %6.3f %%   %6.2f px %6.3f %%  (%d patches)", mu, 100 * mu / R, mc, 100 * mc / R, rc.count))
        let bad = zip(ru, rc).filter { abs($0.0.1) / R > 0.001 && abs($0.1.1) / R > 0.001 }
        expect(rc.count >= 20 && bad.isEmpty,
               "\(url.lastPathComponent): corrected ≤ 0.1 % of the half-diagonal against Adobe's profile wherever uncorrected is larger (\(bad.count) patches over)")
    }

    // MARK: both decodes carry the step

    /// The shipped decodes of a Sony frame with Lens Correction on are the step's (the engine's linear decode and
    /// Apple's stock one, made by hand here with `LensProfileFilter` as the RAW filter's linear-space step, hide on), and
    /// differ from the frame with it off.
    static func pathCase(_ url: URL) {
        var on = DecodeSettings(); on.lensCorrection = true
        let off = DecodeSettings()
        guard let profile = LensCorrection.profile(url), let engineOn = RawExposure.prepare(url, settings: on, longEdge: 1600)?.image,
              let engineOff = RawExposure.prepare(url, settings: off, longEdge: 1600)?.image,
              let stockOn = DigitalDecode.image(url, isRAW: true, decode: on), let stockOff = DigitalDecode.image(url, isRAW: true, decode: off)
        else { expect(false, "\(url.lastPathComponent): both decodes made"); return }
        func step() -> LensProfileFilter { let s = LensProfileFilter(); s.profile = profile; return s }
        let f = CIRAWFilter(imageURL: url)!
        let b0 = f.baselineExposure
        f.baselineExposure = b0; f.exposure = Float(on.rawExposureTreatment.sourceOffsetEV); f.shadowBias = 0
        f.boostAmount = 0; f.boostShadowAmount = 0; f.isGamutMappingEnabled = false; f.localToneMapAmount = 0; f.extendedDynamicRangeAmount = 0
        f.linearSpaceFilter = step()
        let g = CIRAWFilter(imageURL: url)!
        g.linearSpaceFilter = step()
        let a = Oracle.bytes(engineOn), b = Oracle.bytes(RawExposure.scaled(f.outputImage!, toLongEdge: 1600)), c = Oracle.bytes(engineOff)
        let sa = Oracle.bytes(RawExposure.scaled(stockOn, toLongEdge: 1600)), sb = Oracle.bytes(RawExposure.scaled(g.outputImage!, toLongEdge: 1600))
        let sc = Oracle.bytes(RawExposure.scaled(stockOff, toLongEdge: 1600))
        print("\n\(url.lastPathComponent): the engine's decode with Lens Correction on \(a == b ? "is" : "is NOT") the app's step\(a == c ? ", and the SAME as off" : ", and moved from off"); Apple's stock decode \(sa == sb ? "is" : "is NOT") the step's\(sa == sc ? ", and the SAME as off" : ", and moved from off")")
        expect(!a.isEmpty && a == b && a != c, "\(url.lastPathComponent): RawExposure.prepare applies the app's step")
        expect(!sa.isEmpty && sa == sb && sa != sc, "\(url.lastPathComponent): DigitalDecode.image applies the app's step")
    }

    // MARK: a DNG's opcodes against Core Image's own

    static func opcodeCase(_ url: URL) {
        guard let t = LensProfileReader.tiff(url),
              let raw = t.ifds.first(where: { $0.entries[0xC74E] != nil }), let bytes = raw.entries[0xC74E].flatMap(t.bytes) else {
            expect(false, "\(url.lastPathComponent): OpcodeList3 reads"); return
        }
        let o = LensProfileReader.opcodes(bytes)
        guard let p = LensProfileReader.profile(warp: o.warp, vignette: nil) else { expect(false, "\(url.lastPathComponent): a warp profile"); return }
        let w = 3000
        let ci = Oracle.render(Oracle.decode(url, profile: nil, apple: true), width: w, space: Oracle.srgb).luma
        let app = Oracle.render(Oracle.decode(url, profile: disableStep ? nil : p, hide: false), width: w, space: Oracle.srgb).luma
        let un = Oracle.render(Oracle.decode(url, profile: nil), width: w, space: Oracle.srgb).luma
        let R = hypot(Double(ci.w), Double(ci.h)) / 2
        // No fit: the absolute geometry, Core Image's against the app's.
        let ra = Oracle.residuals(ci, app, fit: false), ru = Oracle.residuals(ci, un, fit: false)
        let ma = ra.map { abs($0.1) }.max() ?? .nan, mu = ru.map { abs($0.1) }.max() ?? .nan
        print(String(format: "\n%@ — its OpcodeList3 applied by the app vs Core Image's own correction: uncorrected max %.2f px (%.3f %%), the app's max %.2f px (%.3f %%), %d patches",
                     url.lastPathComponent, mu, 100 * mu / R, ma, 100 * ma / R, ra.count))
        expect(ra.count >= 20 && ma / R <= 0.001, "\(url.lastPathComponent): the app's WarpRectilinear is Core Image's to 0.1 % of the half-diagonal")
    }

    // MARK: Core Image's frames do not move

    static func identityCase(_ url: URL) {
        var d = DecodeSettings(); d.lensCorrection = true
        guard let now = RawExposure.prepare(url, settings: d, longEdge: 1600)?.image,
              let stockNow = DigitalDecode.image(url, isRAW: true, decode: d) else { expect(false, "\(url.lastPathComponent) decodes"); return }
        // Before 2.4.0: the flag set, nothing else (RawExposure set it always, DigitalDecode where supported).
        let f = CIRAWFilter(imageURL: url)!
        let b0 = f.baselineExposure
        f.baselineExposure = b0; f.exposure = Float(d.rawExposureTreatment.sourceOffsetEV); f.shadowBias = 0
        f.boostAmount = 0; f.boostShadowAmount = 0; f.isGamutMappingEnabled = false; f.localToneMapAmount = 0; f.extendedDynamicRangeAmount = 0
        f.isLensCorrectionEnabled = true
        let then = RawExposure.scaled(f.outputImage!, toLongEdge: 1600)
        let g = CIRAWFilter(imageURL: url)!
        if g.isLensCorrectionSupported { g.isLensCorrectionEnabled = true }
        let stockThen = g.outputImage!
        let a = Oracle.bytes(now), b = Oracle.bytes(then)
        let sa = Oracle.bytes(RawExposure.scaled(stockNow, toLongEdge: 1600)), sb = Oracle.bytes(RawExposure.scaled(stockThen, toLongEdge: 1600))
        print("\n\(url.lastPathComponent): the engine's decode \(a == b ? "bit-identical" : "DIFFERS") to before 2.4.0; Apple's stock decode \(sa == sb ? "bit-identical" : "DIFFERS") (\(a.count / 8) px each)")
        expect(!a.isEmpty && a == b, "\(url.lastPathComponent): the engine's decode is bit-identical to before")
        expect(!sa.isEmpty && sa == sb, "\(url.lastPathComponent): Apple's stock decode is bit-identical to before")
    }
}

// MARK: - the oracle's tools

enum Oracle {
    struct Plane {
        var w: Int, h: Int, v: [Float]
        subscript(x: Int, y: Int) -> Float { v[y * w + x] }
        func down(_ f: Int) -> Plane {
            let W = w / f, H = h / f
            var o = [Float](repeating: 0, count: W * H)
            for y in 0..<H { for x in 0..<W {
                var s: Float = 0
                for j in 0..<f { for i in 0..<f { s += v[(y * f + j) * w + x * f + i] } }
                o[y * W + x] = s / Float(f * f)
            } }
            return Plane(w: W, h: H, v: o)
        }
    }
    struct RGB {
        var r: Plane, g: Plane, b: Plane
        var luma: Plane { Plane(w: g.w, h: g.h, v: (0..<g.v.count).map { 0.25 * r.v[$0] + 0.6 * g.v[$0] + 0.15 * b.v[$0] }) }
        init(rgba a: [Float], w: Int, h: Int) {
            var r = [Float](repeating: 0, count: w * h), g = r, b = r
            for i in 0..<(w * h) { r[i] = a[i * 4]; g[i] = a[i * 4 + 1]; b[i] = a[i * 4 + 2] }
            self.r = Plane(w: w, h: h, v: r); self.g = Plane(w: w, h: h, v: g); self.b = Plane(w: w, h: h, v: b)
        }
    }

    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    /// The engine's linear decode's settings (as `RawExposure`), in the sensor's orientation (as the camera's JPEG is),
    /// with the app's profile as the RAW filter's linear-space step, or Core Image's own correction (`apple`).
    static func decode(_ url: URL, profile: LensProfile?, hide: Bool = false, apple: Bool = false) -> CIImage {
        let f = CIRAWFilter(imageURL: url)!
        let b = f.baselineExposure
        f.baselineExposure = b; f.exposure = 0; f.shadowBias = 0
        f.boostAmount = 0; f.boostShadowAmount = 0; f.isGamutMappingEnabled = false; f.localToneMapAmount = 0
        f.extendedDynamicRangeAmount = 0
        f.orientation = .up
        if f.isLensCorrectionSupported { f.isLensCorrectionEnabled = apple }
        if let profile {
            let step = LensProfileFilter()
            step.profile = profile
            step.hideDistortedAreas = hide
            f.linearSpaceFilter = step
        }
        return f.outputImage!
    }

    static func render(_ img: CIImage, width: Int, space: CGColorSpace) -> RGB {
        let e = img.extent.integral
        var im = img.transformed(by: .init(translationX: -e.origin.x, y: -e.origin.y))
        let k = CGFloat(width) / e.width
        if abs(k - 1) > 1e-9, let s = CIFilter(name: "CILanczosScaleTransform") {
            s.setValue(im.clampedToExtent(), forKey: kCIInputImageKey); s.setValue(k, forKey: kCIInputScaleKey)
            s.setValue(1.0, forKey: kCIInputAspectRatioKey)
            im = s.outputImage!
        }
        let h = Int((e.height * k).rounded())
        var buf = [Float](repeating: 0, count: width * h * 4)
        context.render(im, toBitmap: &buf, rowBytes: width * 16, bounds: CGRect(x: 0, y: e.height * k - CGFloat(h), width: CGFloat(width), height: CGFloat(h)),
                       format: .RGBAf, colorSpace: space)
        return RGB(rgba: buf, w: width, h: h)
    }

    static func bytes(_ img: CIImage) -> [UInt16] {
        let e = img.extent.integral
        let w = Int(e.width), h = Int(e.height)
        var buf = [UInt16](repeating: 0, count: w * h * 4)
        let ctx = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        ctx.render(img, toBitmap: &buf, rowBytes: w * 8, bounds: e, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!)
        return buf
    }

    static func jpeg(_ t: LensProfileReader.TIFF) -> (RGB, Int, Int)? {
        guard let range = t.largestJPEG, let src = CGImageSourceCreateWithData(t.data.subdata(in: range) as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cg.colorSpace ?? srgb,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (RGB(rgba: px.map { Float($0) / 255 }, w: w, h: h), w, h)
    }

    /// Normalised cross-correlation of `b` against `a`'s patch at (x, y): b's point matching a's (x, y) is (x+dx, y+dy).
    static func match(_ a: Plane, _ b: Plane, x: Int, y: Int, half p: Int, search s: Int, guess: (Double, Double) = (0, 0)) -> (Double, Double, Double)? {
        let gx = Int(guess.0.rounded()), gy = Int(guess.1.rounded())
        guard x - p >= 0, y - p >= 0, x + p < a.w, y + p < a.h else { return nil }
        let n = Float((2 * p + 1) * (2 * p + 1))
        var am: Float = 0
        for j in -p...p { for i in -p...p { am += a[x + i, y + j] } }
        am /= n
        var av: Float = 0
        for j in -p...p { for i in -p...p { let d = a[x + i, y + j] - am; av += d * d } }
        guard av / n > 1e-6 else { return nil }
        var best = -2.0, bx = 0, by = 0
        var scores = [[Double]](repeating: [Double](repeating: -2, count: 2 * s + 1), count: 2 * s + 1)
        for dy in -s...s { for dx in -s...s {
            let cx = x + gx + dx, cy = y + gy + dy
            guard cx - p >= 0, cy - p >= 0, cx + p < b.w, cy + p < b.h else { continue }
            var bm: Float = 0
            for j in -p...p { for i in -p...p { bm += b[cx + i, cy + j] } }
            bm /= n
            var num: Float = 0, bv: Float = 0
            for j in -p...p { for i in -p...p { let da = a[x + i, y + j] - am, db = b[cx + i, cy + j] - bm; num += da * db; bv += db * db } }
            let sc = Double(num / (sqrt(av * bv) + 1e-12))
            scores[dy + s][dx + s] = sc
            if sc > best { best = sc; bx = dx; by = dy }
        } }
        func para(_ m: Double, _ c: Double, _ p: Double) -> Double { let d = m - 2 * c + p; return abs(d) < 1e-12 ? 0 : 0.5 * (m - p) / d }
        guard bx > -s, bx < s, by > -s, by < s else { return nil }   // a peak on the window's edge is no peak
        let fx = Double(bx) + para(scores[by + s][bx + s - 1], best, scores[by + s][bx + s + 1])
        let fy = Double(by) + para(scores[by + s - 1][bx + s], best, scores[by + s + 1][bx + s])
        return (Double(gx) + fx, Double(gy) + fy, best)
    }

    struct Patch { var x: Int, y: Int, r: Double, ux: Double, uy: Double }

    /// Patches along both diagonals and both midlines, every 0.04 of the half-diagonal.
    static func patches(w: Int, h: Int, margin: Int) -> [Patch] {
        let cx = Double(w) / 2, cy = Double(h) / 2, R = hypot(cx, cy)
        let dirs = [(cx, cy), (-cx, cy), (cx, -cy), (-cx, -cy), (1, 0), (-1, 0), (0, 1), (0, -1)].map { ($0.0 / hypot($0.0, $0.1), $0.1 / hypot($0.0, $0.1)) }
        var out: [Patch] = []
        for d in dirs { for k in stride(from: 0.06, through: 0.98, by: 0.04) {
            let x = cx + d.0 * k * R, y = cy + d.1 * k * R
            guard x >= Double(margin), y >= Double(margin), x < Double(w - margin), y < Double(h - margin) else { continue }
            out.append(Patch(x: Int(x), y: Int(y), r: k, ux: d.0, uy: d.1))
        } }
        return out
    }

    /// `b`'s displacement against `a` at each textured patch (coarse ÷4, then fine), a similarity (scale, shift)
    /// fitted to all of them and refitted without outliers, removed (`fit`); the radial residual in pixels.
    static func residuals(_ a: Plane, _ b: Plane, fit: Bool = true, half: Int = 32) -> [(Patch, Double)] {
        let R = hypot(Double(a.w), Double(a.h)) / 2
        let coarse = max(6, Int(0.035 * R / 4))
        let a4 = a.down(4), b4 = b.down(4)
        let ps = patches(w: a.w, h: a.h, margin: half + 4 * coarse + 12)
        var m: [(Patch, Double, Double)] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: ps.count) { i in
            let p = ps[i]
            guard let c = match(a4, b4, x: p.x / 4, y: p.y / 4, half: max(8, half / 4), search: coarse), c.2 > 0.6,
                  let f = match(a, b, x: p.x, y: p.y, half: half, search: 4, guess: (c.0 * 4, c.1 * 4)), f.2 > 0.85 else { return }
            lock.lock(); m.append((p, f.0, f.1)); lock.unlock()
        }
        let cx = Double(a.w) / 2, cy = Double(a.h) / 2
        var sol = [0.0, 0, 0]
        var keep = m
        if fit {
            for _ in 0..<4 {
                var A = [[Double]](repeating: [0, 0, 0], count: 3), B = [0.0, 0, 0]
                for (p, dx, dy) in keep {
                    let px = Double(p.x) - cx, py = Double(p.y) - cy
                    for (row, val) in [([px, 1.0, 0.0], dx), ([py, 0.0, 1.0], dy)] {
                        for i in 0..<3 { for j in 0..<3 { A[i][j] += row[i] * row[j] }; B[i] += row[i] * val }
                    }
                }
                sol = solve3(A, B)
                let res = m.map { (p, dx, dy) -> Double in
                    hypot(dx - (sol[0] * (Double(p.x) - cx) + sol[1]), dy - (sol[0] * (Double(p.y) - cy) + sol[2])) }
                let sorted = res.sorted(), mad = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                keep = zip(m, res).filter { $0.1 <= max(4 * mad, 0.5) }.map(\.0)
            }
        }
        // The outliers a fit drops (a repeated texture's wrong peak) are dropped from the residuals as well.
        let used = fit ? keep : m
        return used.map { (p, dx, dy) in
            let ex = dx - (sol[0] * (Double(p.x) - cx) + sol[1]), ey = dy - (sol[0] * (Double(p.y) - cy) + sol[2])
            return (p, ex * p.ux + ey * p.uy)
        }.sorted { $0.0.r < $1.0.r }
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double] {
        var m = a, v = b
        for i in 0..<3 {
            let p = m[i][i]
            guard abs(p) > 1e-12 else { return [0, 0, 0] }
            for j in 0..<3 where j != i { let f = m[j][i] / p; for k in 0..<3 { m[j][k] -= f * m[i][k] }; v[j] -= f * v[i] }
        }
        return (0..<3).map { v[$0] / m[$0][$0] }
    }

    /// Median radial residual per 0.1 of radius.
    static func binned(_ r: [(Patch, Double)]) -> [(Double, Double, Int)] {
        stride(from: 0.0, to: 1.0, by: 0.1).compactMap { k in
            let v = r.filter { $0.0.r >= k && $0.0.r < k + 0.1 }.map(\.1).sorted()
            return v.isEmpty ? nil : (k + 0.05, v[v.count / 2], v.count)
        }
    }

    // MARK: Adobe's profile, as the oracle reads it

    /// Adobe's measured distortion of `lens` (Camera Raw's LCP on this Mac), at `focal`, as a `LensProfile`: the
    /// profiles either side of the focal length, interpolated in it. Adobe's model: the source point is the ideal one
    /// scaled by `1 + k1 ρ² + k2 ρ⁴ + k3 ρ⁶`, ρ the distance from the centre over the focal length, in a full-frame
    /// sensor's units (`ρ = r · 21.633 mm / f` at the corner of a 3:2 frame — the normalisation inferred from where
    /// Adobe's piecewise vignette ends, 0.618 at 35 mm). For the oracle only: the reader of LCP files a person loads is
    /// a later stage's.
    static func lcpDistortion(lens: String, focal: Double) -> (profile: LensProfile, name: String, note: String)? {
        let folder = URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0")
        guard !lens.isEmpty, let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in all where url.pathExtension == "lcp" {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("stCamera:Lens=\"\(lens)\"") else { continue }
            var byFocal: [Double: (Double, Double, Double)] = [:]
            var sensor = 1.0
            for block in text.components(separatedBy: "<rdf:li>").dropFirst() {
                func attr(_ name: String) -> Double? {
                    guard let r = block.range(of: "stCamera:\(name)=\"") else { return nil }
                    return Double(block[r.upperBound...].prefix { $0 != "\"" })
                }
                guard let f = attr("FocalLength"), let k1 = attr("RadialDistortParam1") else { continue }
                byFocal[f] = (k1, attr("RadialDistortParam2") ?? 0, attr("RadialDistortParam3") ?? 0)
                sensor = attr("SensorFormatFactor") ?? sensor
            }
            let focals = byFocal.keys.sorted()
            guard let lo = focals.last(where: { $0 <= focal }) ?? focals.first, let hi = focals.first(where: { $0 >= focal }) ?? focals.last else { return nil }
            let t = hi == lo ? 0 : (focal - lo) / (hi - lo)
            let half = 21.633 / sensor
            func d(_ f: Double, _ r: Double) -> Double {
                let k = byFocal[f]!, rho = r * half / f, q = rho * rho
                return 1 + k.0 * q + k.1 * q * q + k.2 * q * q * q
            }
            var p = LensProfile(source: .file)
            p.distortion = .sampled { r in (1 - t) * d(lo, r) + t * d(hi, r) }
            let note = lo == hi ? "its \(Int(lo)) mm profile" : "its \(Int(lo)) and \(Int(hi)) mm profiles at \(Int(focal)) mm"
            return (p, url.deletingPathExtension().lastPathComponent, note)
        }
        return nil
    }
}
