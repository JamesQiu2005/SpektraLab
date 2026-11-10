//  hdr_gainmap_selftest.swift — an export's gain map on this Mac (HDR port, 2026-11-06, PRD/HDR-PORT-PLAN-2026-11-06.md
//  D8, for the desktop's writer):
//
//  1. the export's map (`HDRGainMap.map(of:curve:)`, the canvas's grain-aware kernels at full size) is the plane's
//     codes, within one code, on a grained picture;
//  2. JPEG and HEIF written through the export's own writer (`ExportWriter.write(gainMap:layout:)`) in both layouts
//     and read back as a screen with headroom reads them (`kCGImageSourceDecodeToHDR`): the map is there at the
//     picture's size, HDR ÷ SDR in the middle of each patch is the curve's gain (ISO: within ±3 %; the camera's
//     layout: its Apple coding's fit, within ±3 % on average and ±4 % at the worst patch — RFC-046's 0.053 stop),
//     and the SDR decode is the picture within the codec;
//  3. the camera's layout (RFC-046): MakerApple's reading and its inverse, the ISO → Apple table, the recipe's rule
//     (every JPEG and HEIF, every colour space; never kept in a recipe), ISO's map and Apple's in an 8-bit
//     picture, one stored map read by each kind of reader, the HDR decode the ISO-only file's within 2 %;
//  4. **Adobe's hdrgm** (`HDRUltraHDR`, D8): the JPEG says it, field for field the ISO declaration ImageIO reads back
//     (not the writer's own idea of it), its directory's length the map's and the MPF's sizes the file's; the
//     scans are ImageIO's to the byte and every decode (plain, SDR, HDR) of the file is the ImageIO-only file's to
//     the bit; a HEIF has none; surprises are refused and leave nothing (a plain JPEG, a cut file, an MPF that
//     points elsewhere, hdrgm already there, a packet past 64 KB); and when the step fails inside the writer, the
//     file is ImageIO's with both maps, and `Written.hdr` says why;
//  5. PNG and TIFF take no map (refused with one, none made for them); a file with no map is today's — no map,
//     no MakerApple, no hdrgm;
//  6. a slide's ratio map (`HDRGain.ratioMap`) written into JPEG and HEIF, read back at full size;
//  7. **D3, the base**: a grained picture written with a map and without one — a JPEG's coded picture (tables,
//     frame, scan) the same to the byte, a HEIF's decode the same to the bit (`baseChecks`).
//
//      tools/hdr_gainmap_selftest.sh                  # the checks (in tools/selftest.sh)
//      tools/hdr_gainmap_selftest.sh --self-test      # each broken rule must fail a check
//      tools/hdr_gainmap_selftest.sh --measure W H jpeg|heic [--no-map]   # phys_footprint of one map + write
//
//  The curve is the engine's own for Portra 400 on Portra Endura (tools/engine_replies/hdr_curve_reply.json, this
//  Mac's engine). `--break nomap` writes no map; `headroom` encodes the codes against 2H under metadata that says H;
//  `apple` writes the ISO layout where the camera's is asked; `hdrgm` declares Gamma 1 in hdrgm over the camera's
//  codes; `fallback` keeps the hdrgm file when the step said it failed (the check of the writer's own rule). Each
//  must fail.

import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import SwiftUI

extension Color { init(hexString: String) { self = .gray } }

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

/// The patches: linear P3 luminance of a grey, or a colour (linear P3).
let patches: [SIMD3<Double>] = [0.02, 0.05, 0.1, 0.18, 0.3, 0.45, 0.6, 0.8, 1.0].map { SIMD3(repeating: $0) }
    + [SIMD3(0.75, 0.12, 0.06), SIMD3(0.2, 0.45, 0.85), SIMD3(0.7, 0.5, 0.38), SIMD3(0.95, 0.9, 0.3)]
let P = 160, columns = 5

/// The picture: RGBX, P3 encoded, `w × h`, the patches tiled; `noise` codes of a hash's grain on every channel.
func picture(_ w: Int, _ h: Int, noise: Int = 0) -> (CGImage, UnsafeMutableRawPointer) {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16384)
    let p = bytes.assumingMemoryBound(to: UInt8.self)
    let codes = patches.map { c in [c.x, c.y, c.z].map { Int((HDRMath.encode($0) * 255).rounded()) } }
    let rows = (patches.count + columns - 1) / columns
    for y in 0..<h {
        for x in 0..<w {
            let c = codes[(((y / P) % rows) * columns + (x / P) % columns) % codes.count]
            let o = 4 * (y * w + x)
            var hash = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663)
            hash = (hash ^ (hash >> 13)) &* 0x5bd1e995
            let g = noise == 0 ? 0 : Int(hash % UInt32(2 * noise + 1)) - noise
            for k in 0..<3 { p[o + k] = UInt8(max(0, min(255, c[k] + g))) }
            p[o + 3] = 255
        }
    }
    let provider = CGDataProvider(dataInfo: nil, data: bytes, size: w * h * 4, releaseData: { _, _, _ in })!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return (image, bytes)
}

/// Every decode of a file, as 8-bit P3 codes (plain, SDR) and float linear P3 (HDR), whole.
func decoded(_ url: URL, _ request: CFString?) -> [Float]? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, request.map { [kCGImageSourceDecodeRequest: $0] as CFDictionary }) else { return nil }
    return HDRGrainGain.floatsLinearP3(img)
}

@main
struct HDRGainMapSelfTest {
    static func value(_ flag: String) -> String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    static func main() {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let replyURL = root.appendingPathComponent("tools/engine_replies/hdr_curve_reply.json")
        guard let reply = try? String(contentsOf: replyURL, encoding: .utf8), var curve = try? HDRSessionCurve.parse(reply) else {
            print("FAILED: the engine's reply \(replyURL.path)"); exit(2)
        }
        let breakMode = value("--break")
        // The clamped base taken away (R alone, the ring back) or squeezed to nothing (1:1, the grain's cutoffs):
        // the two break modes.
        if breakMode == "tau" { curve.tables.tau = .infinity }
        if breakMode == "tau0" { curve.tables.tau = 0 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-gainmap-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if let i = args.firstIndex(of: "--measure"), i + 3 < args.count, let w = Int(args[i + 1]), let h = Int(args[i + 2]) {
            measure(w, h, args[i + 3], curve, dir)
            return
        }
        print("HDR gain map (the export's): curve \(curve.curve.name) (\(curve.version)), H \(curve.curve.headroom)")
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ what: String) {
            if ok { passed += 1; print("  ok: \(what)") } else { failed += 1; print("  FAILED: \(what)") }
        }
        let w = P * columns, h = P * ((patches.count + columns - 1) / columns)

        // 1. the map's codes are the plane's, on a grained picture
        do {
            let (grained, gbytes) = picture(w, h, noise: 12)
            defer { gbytes.deallocate() }
            if let map = try? HDRGainMap.map(of: grained, curve: curve),
               let plane = try? HDRRendition.plane(of: grained, tables: curve.tables) {
                let want = HDRGainMap.map(from: HDRGainMap.Plane(width: w, height: h, subsample: 1, log2Gain: plane), headroom: curve.curve.headroom).codes
                let most = zip(map.codes, want).map { abs(Int($0) - Int($1)) }.max() ?? 255
                expect(map.width == w && map.height == h && map.subsample == 1 && most <= 1,
                       "1. the export's map is full size (\(map.width) × \(map.height)) and the plane's codes: worst \(most); \(Set(map.codes).count) codes in use")
            } else { expect(false, "1. the export's map made") }
            let none = [ExportRecipe.Format.png, .tiff].allSatisfy { ((try? HDRGainMap.exportAttachment(for: grained, format: $0, curve: curve)) ?? nil) == nil }
                && ((try? HDRGainMap.exportAttachment(for: grained, format: .jpeg, curve: nil)) ?? nil) == nil
                && ((try? HDRGainMap.exportAttachment(for: grained, format: .heif, curve: curve)) ?? nil) != nil
            expect(none, "   JPEG and HEIF take a map; PNG and TIFF take none, and with no curve there is none")
        }

        let (image, bytes) = picture(w, h)
        defer { bytes.deallocate() }
        let made: HDRGainMap.Attachment?
        switch breakMode {
        case "nomap": made = nil
        case "headroom":
            made = (try? HDRRendition.plane(of: image, tables: curve.tables)).map {
                .init(map: HDRGainMap.map(from: .init(width: w, height: h, subsample: 1, log2Gain: $0), headroom: 2 * curve.curve.headroom), headroom: curve.curve.headroom)
            }
        default: made = try? HDRGainMap.exportAttachment(for: image, format: .jpeg, curve: curve)
        }
        guard let attachment = made ?? (breakMode == "nomap" ? HDRGainMap.Attachment(map: .init(width: 0, height: 0, subsample: 1, codes: Data()), headroom: 1) : nil) else {
            expect(false, "2. a map to write"); finish(passed, failed, breakMode)
        }
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])
        let lin = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func at(_ img: CGImage, _ x: Int, _ y: Int) -> SIMD3<Double> {
            var f = [Float](repeating: 0, count: 4)
            ctx.render(CIImage(cgImage: img), toBitmap: &f, rowBytes: 16, bounds: CGRect(x: x, y: img.height - 1 - y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: lin)
            return SIMD3(Double(f[0]), Double(f[1]), Double(f[2]))
        }

        // 2. written and read back, both layouts, both containers
        for layout in [ExportRecipe.HDRLayout.iso, .appleCamera] {
            for format in [ExportRecipe.Format.jpeg, .heif] {
                let what = "\(format.rawValue), \(layout.rawValue)"
                let url = dir.appendingPathComponent("picture-\(layout.rawValue).\(format.fileExtension)")
                let written: ExportWriter.Written
                do {
                    written = try ExportWriter.write(image, format: format, quality: 92, to: url,
                                                     gainMap: breakMode == "nomap" ? nil : attachment, layout: layout)
                } catch { expect(false, "2. \(what) written: \(error)"); continue }
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let sdr = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let hdr = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
                else { expect(false, "2. \(what) read back"); continue }
                let size = HDRGainMap.size(in: src)
                expect(HDRGainMap.present(in: src) && size?.width == w && size?.height == h,
                       "2. \(what): \(written.bytes >> 10) KB, said \"\(written.hdr ?? "no map")\"; its map is \(size.map { "\($0.width) × \($0.height)" } ?? "absent"), the picture's")
                var worst = 0.0, sum = 0.0, worstCodes = 0, lines: [String] = []
                for (i, c) in patches.enumerated() {
                    let x = (i % columns) * P + P / 2, y = (i / columns) * P + P / 2
                    let s = at(sdr, x, y), e = at(hdr, x, y)
                    let y0 = HDRMath.luminance(s.x, s.y, s.z), y1 = HDRMath.luminance(e.x, e.y, e.z)
                    let codes = [c.x, c.y, c.z].map { (HDRMath.encode($0) * 255).rounded() / 255 }
                    let patchY = HDRMath.luminance(HDRMath.decode(codes[0]), HDRMath.decode(codes[1]), HDRMath.decode(codes[2]))
                    // On a flat patch the grain-aware gain is the smoothed curve's at the patch's own tone.
                    let want = exp2(HDRGrainGain.log2Gain(l2y: HDRGrainGain.l2y(patchY), local: HDRGrainGain.l2y(patchY), tables: curve.tables))
                    let ratio = y1 / max(y0, 1e-6), err = abs(ratio / want - 1)
                    worst = max(worst, err); sum += err
                    for (j, v) in [s.x, s.y, s.z].enumerated() {
                        worstCodes = max(worstCodes, abs(Int((HDRMath.encode(v) * 255).rounded()) - Int((codes[j] * 255).rounded())))
                    }
                    lines.append(String(format: "%.3f: %.3f/%.3f", y0, ratio, want))
                }
                let mean = sum / Double(patches.count)
                print("    HDR ÷ SDR by patch (Y: got/want): " + lines.joined(separator: "; "))
                let ok = layout == .iso ? worst <= 0.03 : mean <= 0.03 && worst <= 0.04
                expect(ok, String(format: "   HDR ÷ SDR is the curve's gain: mean %.2f %%, worst %.2f %% (%@)", 100 * mean, 100 * worst,
                                  layout == .iso ? "≤ 3 %" : "≤ 3 % mean, 4 % worst"))
                expect(worstCodes <= 9, "   the SDR picture is the export's within the codec: worst \(worstCodes) codes (10-22: ≤ 9)")
            }
        }

        // 3. the camera's layout (RFC-046)
        typealias Apple = AppleHDRGainMapDeclaration
        let camera = Apple.stops(maker33: 1.01, maker48: 0.5359375)
        let inverse = stride(from: 0.0, through: 3.0, by: 0.05).map { abs(Apple.stops(maker33: Apple.maker33, maker48: Apple.maker48(stops: $0)) - $0) }.max() ?? 1
        expect(abs(camera - 2.140625) < 2e-4 && inverse < 1e-9,
               String(format: "3. MakerApple: the camera's 33 = 1.01, 48 = 0.5359 read as %.4f stops; written and read back over 0…3 stops, worst %.1e", camera, inverse))
        let table = Apple.table(isoHeadroom: curve.curve.headroom, appleHeadroom: Apple.headroom(curve.curve.headroom))
        expect(table.first == 0 && table.last == 255 && zip(table, table.dropFirst()).allSatisfy { $0 <= $1 }, "   the ISO → Apple table runs 0 … 255 and never falls")
        func rule(_ f: ExportRecipe.Format, _ c: ExportRecipe.Colour) -> ExportRecipe.HDRLayout { ExportRecipe(format: f, colour: c).hdrLayoutInEffect }
        let cameraRule = ExportRecipe.Colour.allCases.allSatisfy { rule(.jpeg, $0) == .appleCamera && rule(.heif, $0) == .appleCamera && rule(.png, $0) == .iso && rule(.tiff, $0) == .iso }
        let encoded = (try? JSONEncoder().encode(ExportRecipe(format: .heif))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(cameraRule && !encoded.lowercased().contains("hdr"), "   the camera's layout in every JPEG and HEIF, every colour space; not kept in a recipe")
        let isoGamma = Apple.isoGamma(headroom: Apple.headroom(curve.curve.headroom))
        expect(abs(isoGamma - 0.6771) < 5e-4, String(format: "   the ISO Gamma fitted to Apple's coding at H 4: %.4f (RFC-046: 0.6771)", isoGamma))
        let layout: ExportRecipe.HDRLayout = breakMode == "apple" ? .iso : .appleCamera
        var cameraFiles: [ExportRecipe.Format: URL] = [:]
        for format in [ExportRecipe.Format.heif, .jpeg] where breakMode != "nomap" {
            let both = dir.appendingPathComponent("camera.\(format.fileExtension)"), iso = dir.appendingPathComponent("iso-only.\(format.fileExtension)")
            do {
                _ = try ExportWriter.write(image, format: format, quality: 92, to: both, gainMap: attachment, layout: layout)
                _ = try ExportWriter.write(image, format: format, quality: 92, to: iso, gainMap: attachment, layout: .iso)
            } catch { expect(false, "3. \(format.rawValue) written: \(error)"); continue }
            cameraFiles[format] = both
            guard let src = CGImageSourceCreateWithURL(both as CFURL, nil), let isoSrc = CGImageSourceCreateWithURL(iso as CFURL, nil) else {
                expect(false, "3. read back"); continue
            }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            expect(HDRGainMap.present(in: src) && Apple().isPresent(in: src) && (props[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8,
                   "3. \(format.rawValue), the camera's layout: the ISO map, Apple's map and MakerApple 33/48 in an 8-bit picture")
            guard let apple = Apple.read(src) else { expect(false, "   Apple's map read back"); continue }
            let wantH = Apple.headroom(attachment.headroom)
            expect(abs(apple.headroom - wantH) < 1e-3 && apple.width == w && apple.height == h,
                   String(format: "   Apple's map: %d × %d, headroom %.4f by MakerApple (the curve's %.4f)", apple.width, apple.height, apple.headroom, wantH))
            let data = (try? Data(contentsOf: both)) ?? Data()
            func count(_ s: String) -> Int { var n = 0, f = data.startIndex; while let r = data.range(of: Data(s.utf8), in: f..<data.endIndex) { n += 1; f = r.upperBound }; return n }
            expect(count("urn:com:apple:photo:2020:aux:hdrgainmap") == 1, "   one stored map: Apple's aux URN once")
            var sa = 0.0, wa = 0.0
            let top = HDRGainMap.top(attachment.headroom)
            for k in 0..<apple.codes.count {
                let meant = min(Double(attachment.map.codes[k]) / 255 * top, log2(apple.headroom))
                let e = abs(log2(Apple.gain(code: apple.codes[k], headroom: apple.headroom)) - meant)
                sa += e; wa = max(wa, e)
            }
            let n = Double(max(apple.codes.count, 1))
            expect(sa / n <= 0.01 && wa <= 0.05, String(format: "   read as Apple's map it is the export's gain: mean |Δ| %.4f stop, worst %.4f", sa / n, wa))
            if let h1 = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
               let h0 = CGImageSourceCreateImageAtIndex(isoSrc, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary) {
                func mean(_ img: CGImage) -> Double {
                    var f = [Float](repeating: 0, count: 4)
                    ctx.render(CIImage(cgImage: img).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: img.width, height: img.height))]),
                               toBitmap: &f, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: lin)
                    return Double(f[0] + f[1] + f[2]) / 3
                }
                let m1 = mean(h1), m0 = mean(h0)
                expect(abs(m1 / max(m0, 1e-9) - 1) < 0.02, String(format: "   decoded to HDR it is the ISO-only file's within 2 %%: mean %.4f against %.4f", m1, m0))
            } else { expect(false, "   decoded to HDR") }
        }

        // 4. Adobe's hdrgm (D8)
        hdrgmChecks(expect, image: image, attachment: attachment, cameraFiles: cameraFiles, dir: dir, breakMode: breakMode)

        // 5. no map where none is carried
        if let a = try? HDRGainMap.exportAttachment(for: image, format: .jpeg, curve: curve) {
            let refused = [ExportRecipe.Format.png].allSatisfy { (try? ExportWriter.write(image, format: $0, quality: 92, to: dir.appendingPathComponent("p.\($0.fileExtension)"), gainMap: a)) == nil }
            expect(refused, "5. a PNG with a map is refused, not written without it")
        }
        for format in [ExportRecipe.Format.jpeg, .heif] {
            let plain = dir.appendingPathComponent("plain.\(format.fileExtension)")
            let w = try? ExportWriter.write(image, format: format, quality: 92, to: plain)
            let src = CGImageSourceCreateWithURL(plain as CFURL, nil)
            let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
            expect(w != nil && w?.hdr == nil && src.map { !HDRGainMap.present(in: $0) && !Apple().isPresent(in: $0) } == true
                   && props[kCGImagePropertyMakerAppleDictionary] == nil && (format == .heif || (try? HDRUltraHDR.read(plain)) == nil),
                   "   \(format.rawValue) without a map is today's file: no map, no MakerApple, no hdrgm")
        }

        // 6. a slide's ratio map
        slideChecks(expect, dir: dir)
        // 7. D3: the picture of a file with a map is the file without one, to the bit
        if breakMode != "nomap" { baseChecks(expect, curve: curve, dir: dir) }
        // 8. the clamped base (2026-11-09)
        clampedBaseChecks(expect, curve: curve)
        // 9. the display pass (PRD-B)
        displayPassChecks(expect, curve: curve, breakMode: breakMode)
        finish(passed, failed, breakMode)
    }

    /// 9. The display pass (PRD-B, 2026-11-09) is the page's picture it replaced: `HDRRendition.show` over a
    /// `prepare`d gain gives, at every share, the bytes `make(display: true)` gives in one pass (the blur, the gain
    /// and the PQ at once), and the peak it is marked with is H^w. A surface that would drift from the canvas's own
    /// rendition — and so from the file's map, which is the same kernel — fails here (trap 33's shape).
    static func displayPassChecks(_ expect: (Bool, String) -> Void, curve: HDRSessionCurve, breakMode: String?) {
        let (image, bytes) = picture(P * columns, P * ((patches.count + columns - 1) / columns), noise: 12)
        defer { bytes.deallocate() }
        let look = HDRLook(curve)
        guard let prepared = try? HDRRendition.prepare(image, look: look) else { expect(false, "9. the display pass: prepared"); return }
        for w in [1.0, 0.5, 0.0] {
            guard let one = try? HDRRendition.make(image, look: look, weight: w, display: true),
                  var two = try? HDRRendition.show(prepared, weight: w),
                  let a = one.dataProvider?.data as Data?, var b = two.dataProvider?.data as Data? else {
                expect(false, "9. the display pass at w \(w)"); continue
            }
            if breakMode == "show", w == 0.5, let wrong = try? HDRRendition.show(prepared, weight: 0.45),
               let d = wrong.dataProvider?.data as Data? { two = wrong; b = d }
            let n = min(a.count, b.count) / 2
            var worst = 0
            a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
                let ua = pa.bindMemory(to: UInt16.self), ub = pb.bindMemory(to: UInt16.self)
                for i in 0..<n where i % 4 != 3 { worst = max(worst, abs(Int(ua[i]) - Int(ub[i]))) }
            } }
            var peaks = (0.0, 0.0)
            if #available(macOS 15.0, *) { peaks = (Double(one.contentHeadroom), Double(two.contentHeadroom)) }
            let want = pow(curve.curve.headroom, w)
            expect(a.count == b.count && worst <= 2 && abs(peaks.1 - want) < 1e-3 && abs(peaks.0 - peaks.1) < 1e-3,
                   String(format: "9. the display pass at w %.1f is the one-pass rendition: worst %d of 65535 PQ codes, peak %.3f (H^w %.3f)",
                          w, worst, peaks.1, want))
        }
    }

    /// 8. The clamped base (τ, the owner's "C looks right", 2026-11-08; added
    /// 2026-11-09). The Mac ships no curves, so they are held over
    /// the engine's own session curve (the reply: Portra 400 on Portra Endura), on the Swift reference (which
    /// check 1 holds the GPU to), and once through the GPU itself:
    ///  - **no ring**: a dark branch and trunk across a flat sky dim no sky pixel's gain by more than ⅛ stop;
    ///  - **no inversion along tone**: with the same surroundings a brighter pixel always comes out brighter;
    ///  - **no step**: the output's slope against the pixel's own tone is bounded;
    ///  - **surroundings move a gain only so far**: |gain(own, any L) − gain(own, own)| is bounded;
    ///  - **the grain stays R's**, not 1:1's, at the curve's steepest tone.
    static func clampedBaseChecks(_ expect: (Bool, String) -> Void, curve: HDRSessionCurve) {
        let t = curve.tables
        var r = t; r.tau = .infinity                         // R alone, for the comparison printed
        var ring = 0.0, ringWhere = "", ringR = 0.0
        let w = 256, h = 48
        for sky in [-0.8, -0.3, 0.0] where sky > t.lo && sky <= t.hi {
            let dark = max(t.lo, -6.0)
            var plane = [Float](repeating: Float(sky), count: w * h)
            for y in 0..<h { for x in 100..<106 { plane[y * w + x] = Float(dark) }; plane[y * w + 180] = Float(dark) }
            let flat = HDRGrainGain.log2Gain(l2y: sky, local: sky, tables: t)
            for sigma in [2.0, 8.0] {
                let g = HDRGrainGain.log2Gains(l2y: plane, width: w, height: h, tables: t, sigma: sigma)
                let gr = HDRGrainGain.log2Gains(l2y: plane, width: w, height: h, tables: r, sigma: sigma)
                for i in 0..<(w * h) where plane[i] == Float(sky) {
                    if flat - Double(g[i]) > ring { ring = flat - Double(g[i]); ringWhere = "sky \(sky), σ \(Int(sigma))" }
                    ringR = max(ringR, flat - Double(gr[i]))
                }
            }
        }
        var worstFall = 0.0, steepest = 0.0, reach = 0.0, reachTypical = [Double]()
        let step = 0.005
        for k in 0...32 {
            let L = t.lo + (t.hi - t.lo) * Double(k) / 32
            var prevOut = -Double.infinity, own = t.lo
            while own <= t.hi {
                let out = own + HDRGrainGain.log2Gain(l2y: own, local: L, tables: t)
                if prevOut > -.infinity { worstFall = max(worstFall, prevOut - out); steepest = max(steepest, (out - prevOut) / step) }
                prevOut = out
                let moved = abs(HDRGrainGain.log2Gain(l2y: own, local: L, tables: t) - HDRGrainGain.log2Gain(l2y: own, local: own, tables: t))
                reach = max(reach, moved)
                if abs(own - L) > 0.5 { reachTypical.append(moved) }
                own += step
            }
        }
        reachTypical.sort()
        let p95 = reachTypical.isEmpty ? 0 : reachTypical[Int(Double(reachTypical.count - 1) * 0.95)]
        expect(t.tau > 0 && t.tau.isFinite && ring <= 0.125,
               String(format: "8. the clamped base (τ %.2f): no ring — a dark trunk and branch across a flat sky dim the sky's gain by %.3f stop at most (R alone: %.2f) [%@]",
                      t.tau, ring, ringR, ringWhere))
        expect(worstFall <= 1e-9, String(format: "   no inversion along tone (worst fall %.1e stop)", worstFall))
        expect(steepest <= 1 + t.rhoMax + 4.0, String(format: "   no step: the output's slope against the pixel's own tone is %.2f at most", steepest))
        expect(reach <= 0.36 && p95 <= 0.10,
               String(format: "   surroundings move a gain %.3f stop at most, %.3f for 95 %% of pixels across an edge", reach, p95))
        // Grain stays R's: at the curve's steepest tone a grain of 0.03 stop std (inside τ) keeps the capped slope's
        // contrast, 1 + κ·min(ρ, ρmax), not the raw slope's (1:1's).
        if let i = t.slope.indices.max(by: { t.slope[$0] < t.slope[$1] }) {
            let tone = t.lo + (t.hi - t.lo) * Double(i) / Double(t.ks.count - 1)
            let n = 128
            var rng: UInt64 = 0x9E3779B97F4A7C15
            func gauss() -> Double {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407; let u1 = max(Double(rng >> 11) / Double(1 << 53), 1e-12)
                rng = rng &* 6364136223846793005 &+ 1442695040888963407; let u2 = Double(rng >> 11) / Double(1 << 53)
                return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
            }
            let plane = (0..<(n * n)).map { _ in Float(tone + 0.03 * gauss()) }
            let g = HDRGrainGain.log2Gains(l2y: plane, width: n, height: n, tables: t, sigma: 2)
            func sd(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(v.count); return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)) }
            let inner = (0..<(n * n)).filter { let x = $0 % n, y = $0 / n; return x >= 8 && x < n - 8 && y >= 8 && y < n - 8 }
            let ratio = sd(inner.map { Double(plane[$0]) + Double(g[$0]) }) / sd(inner.map { Double(plane[$0]) })
            let want = 1 + t.kappa * min(Double(t.slope[i]), t.rhoMax), raw = 1 + Double(t.slope[i])
            expect(abs(ratio / want - 1) < 0.15,
                   String(format: "   the grain stays R's at the steepest tone (slope %.2f): HDR ÷ SDR log contrast %.2f, R's %.2f, 1:1's %.2f",
                          Double(t.slope[i]), ratio, want, raw))
        } else { expect(false, "   the steepest tone") }
        // Through the GPU: the trunk across a near-white sky, as the export's kernel draws it.
        let gw = 256, gh = 64
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: gw * gh * 4, alignment: 16384)
        defer { bytes.deallocate() }
        let q = bytes.assumingMemoryBound(to: UInt8.self)
        let skyCode = UInt8((HDRMath.encode(exp2(-0.3)) * 255).rounded()), darkCode = UInt8(12)
        for i in 0..<(gw * gh) {
            let x = i % gw, v = (x >= 100 && x < 106) || x == 180 ? darkCode : skyCode
            q[4 * i] = v; q[4 * i + 1] = v; q[4 * i + 2] = v; q[4 * i + 3] = 255
        }
        let provider = CGDataProvider(dataInfo: nil, data: bytes, size: gw * gh * 4, releaseData: { _, _, _ in })!
        let image = CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        if let g = try? HDRRendition.plane(of: image, tables: t, sigma: 8) {
            let skyGain = (0..<(gw * gh)).filter { $0 % gw < 40 }.map { Double(g[$0]) }.max() ?? 0
            let dip = (0..<(gw * gh)).filter { q[4 * $0] == skyCode }.map { skyGain - Double(g[$0]) }.max() ?? 1
            expect(dip <= 0.125, String(format: "   on the GPU (the export's kernel, σ 8): the sky beside the trunk loses %.3f stop at most", dip))
        } else { expect(false, "   on the GPU: the trunk's plane") }
    }

    static func finish(_ passed: Int, _ failed: Int, _ breakMode: String?) -> Never {
        print("HDR gain map checks: \(passed) passed, \(failed) failed\(breakMode.map { " (broken: \($0))" } ?? "")")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: 4. hdrgm

    static func hdrgmChecks(_ expect: (Bool, String) -> Void, image: CGImage, attachment: HDRGainMap.Attachment,
                            cameraFiles: [ExportRecipe.Format: URL], dir: URL, breakMode: String?) {
        guard let jpeg = cameraFiles[.jpeg], let heif = cameraFiles[.heif] else { expect(false, "4. the camera layout's files"); return }
        // What ImageIO reads of the ISO declaration: the reference for hdrgm (never the writer's own idea of it).
        guard let src = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
              let md = info[kCGImageAuxiliaryDataInfoMetadata] else { expect(false, "4. the ISO declaration read back"); return }
        let m = md as! CGImageMetadata
        func v(_ t: CGImageMetadataTag?) -> Double? { t.flatMap { CGImageMetadataTagCopyValue($0) as? String }.flatMap(Double.init) }
        var iso: [String: Double] = ["AlternateHeadroom": v(CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:AlternateHeadroom" as CFString)) ?? .nan,
                                     "BaseHeadroom": v(CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:BaseHeadroom" as CFString)) ?? .nan]
        if let arr = CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:ChannelMetadata" as CFString).flatMap({ CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }),
           let f = arr.first.flatMap({ CGImageMetadataTagCopyValue($0) as? [String: CGImageMetadataTag] }) {
            for k in ["GainMapMin", "GainMapMax", "Gamma", "BaseOffset", "AlternateOffset"] { iso[k] = v(f[k]) ?? .nan }
        }
        func agrees(_ r: HDRUltraHDR.Read) -> Bool {
            let f = r.mapFields.compactMapValues(Double.init)
            func same(_ a: Double?, _ b: Double?) -> Bool { a != nil && b != nil && abs(a! - b!) < 1e-6 }
            return same(f["GainMapMin"], iso["GainMapMin"]) && same(f["GainMapMax"], iso["GainMapMax"]) && same(f["Gamma"], iso["Gamma"])
                && same(f["OffsetSDR"], iso["BaseOffset"]) && same(f["OffsetHDR"], iso["AlternateOffset"])
                && same(f["HDRCapacityMin"], iso["BaseHeadroom"]) && same(f["HDRCapacityMax"], iso["AlternateHeadroom"])
                && r.mapFields.count == 7 && r.baseRenditionIsHDR == "False" && r.primaryVersion == "1.0" && r.mapVersion == "1.0"
        }
        // The ImageIO-only file the writer started from, made as it makes it, and hdrgm written over it here.
        let profile = HDRProfile.of(.appleCamera), stored = profile.stored(attachment)
        let raw = dir.appendingPathComponent("imageio-only.jpg"), adobe = dir.appendingPathComponent("hdrgm.jpg")
        guard let d = CGImageDestinationCreateWithURL(raw as CFURL, "public.jpeg" as CFString, 1, nil) else { expect(false, "4. ImageIO's JPEG"); return }
        var props: [CFString: Any] = [kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.92]
        for decl in profile.declarations { props.merge(decl.imageProperties(for: stored)) { _, n in n } }
        CGImageDestinationAddImage(d, image, props as CFDictionary)
        for decl in profile.declarations { try? decl.attach(stored, to: d) }
        guard CGImageDestinationFinalize(d) else { expect(false, "4. ImageIO's JPEG finished"); return }
        var declaration = HDRUltraHDR.Declaration.of(stored)
        if breakMode == "hdrgm" { declaration.gamma = "1.000000" }
        do { try HDRUltraHDR.write(from: raw, to: adobe, declaration: declaration) } catch { expect(false, "4. hdrgm written: \(error)"); return }
        guard let mine = try? HDRUltraHDR.read(adobe), let writers = try? HDRUltraHDR.read(jpeg) else { expect(false, "4. hdrgm read back"); return }
        let rawBytes = (try? Data(contentsOf: raw)) ?? Data()
        expect(agrees(mine) && agrees(writers) && mine.consistent && writers.consistent,
               "4. the JPEG says hdrgm, field for field the ISO declaration ImageIO reads (Gamma \(writers.mapFields["Gamma"] ?? "?"), GainMapMax \(writers.mapFields["GainMapMax"] ?? "?")); directory \(writers.directory), GainMap \(writers.mapLengthSaid ?? -1) B = MPF \(writers.mpfMapSize) B")
        expect(writers.mapLengthSaid == writers.mpfMapSize && writers.mpfPrimarySize == writers.mpfMapStart && writers.mpfMapStart + writers.mpfMapSize == writers.fileBytes,
               "   its MPF is patched: primary \(writers.mpfPrimarySize) B, map \(writers.mpfMapSize) B at \(writers.mpfMapStart), file \(writers.fileBytes) B")
        // The scans to the byte, every decode to the bit.
        let adobeBytes = (try? Data(contentsOf: adobe)) ?? Data()
        if let r0 = try? HDRUltraHDR.read(raw) {
            expect(adobeBytes[mine.primaryScan] == rawBytes[r0.primaryScan] && adobeBytes[mine.mapScan] == rawBytes[r0.mapScan],
                   "   both scans are ImageIO's to the byte (primary \(mine.primaryScan.count) B, map \(mine.mapScan.count) B; \(adobeBytes.count - rawBytes.count) B of XMP added)")
        } else { expect(false, "   ImageIO's own file read") }
        let same = [nil, kCGImageSourceDecodeToSDR, kCGImageSourceDecodeToHDR].allSatisfy { req in
            guard let a = decoded(raw, req), let b = decoded(adobe, req) else { return false }
            return a == b
        }
        expect(same, "   its plain, SDR and HDR decodes are the ImageIO-only file's to the bit")
        expect((try? HDRUltraHDR.read(heif)).map { $0.mapFields.isEmpty } ?? true, "   a HEIF has no hdrgm")

        // Surprises are refused and leave nothing.
        func refused(_ name: String, _ make: (URL) -> Void) -> Bool {
            let input = dir.appendingPathComponent("surprise-\(name).jpg"), output = dir.appendingPathComponent("surprise-\(name)-out.jpg")
            make(input)
            let threw = (try? HDRUltraHDR.write(from: input, to: output, declaration: HDRUltraHDR.Declaration.of(stored))) == nil
            return threw && !FileManager.default.fileExists(atPath: output.path)
        }
        let plain = refused("plain") { u in _ = try? ExportWriter.write(image, format: .jpeg, quality: 92, to: u) }
        let cut = refused("cut") { u in try? rawBytes.prefix(rawBytes.count / 2).write(to: u) }
        let elsewhere = refused("mpf") { u in
            // The map's offset moved by one byte: it no longer meets the primary's end.
            var b = rawBytes
            if let r = try? HDRUltraHDR.read(raw), let i = b.range(of: Data("MPF\0".utf8))?.lowerBound {
                let tiff = i + 4, big = b[tiff] == 0x4D
                let base = b.startIndex
                // find the second entry's offset field by its value
                let want = UInt32(r.mpfMapStart - (tiff - base))
                let pattern: [UInt8] = big ? [UInt8(want >> 24), UInt8(want >> 16 & 0xFF), UInt8(want >> 8 & 0xFF), UInt8(want & 0xFF)]
                                           : [UInt8(want & 0xFF), UInt8(want >> 8 & 0xFF), UInt8(want >> 16 & 0xFF), UInt8(want >> 24)]
                if let at = b.range(of: Data(pattern), in: tiff..<(tiff + 200))?.lowerBound { b[at + (big ? 3 : 0)] &+= 1 }
            }
            try? b.write(to: u)
        }
        let twice = refused("twice") { u in try? adobeBytes.write(to: u) }
        let big = (try? HDRUltraHDR.app1([UInt8](repeating: 0x20, count: 70_000))) == nil
        expect(plain && cut && elsewhere && twice && big,
               "   refused, nothing left behind: a plain JPEG \(plain), a cut file \(cut), an MPF that points elsewhere \(elsewhere), hdrgm already there \(twice), a packet past 64 KB \(big)")

        // The step failing inside the writer: ImageIO's file, both maps, and why.
        HDRUltraHDR.refuseForCheck = "a check's refusal"
        let fallback = dir.appendingPathComponent("fallback.jpg")
        let written = try? ExportWriter.write(image, format: .jpeg, quality: 92, to: fallback, gainMap: attachment, layout: .appleCamera)
        HDRUltraHDR.refuseForCheck = nil
        let fsrc = CGImageSourceCreateWithURL(fallback as CFURL, nil)
        var kept = written != nil && fsrc.map { HDRGainMap.present(in: $0) && AppleHDRGainMapDeclaration().isPresent(in: $0) } == true
            && (try? HDRUltraHDR.read(fallback)).map { $0.mapFields.isEmpty } == true
            && (written?.hdr?.contains("no hdrgm") ?? false)
        if breakMode == "fallback" { kept = (try? HDRUltraHDR.read(fallback)).map { !$0.mapFields.isEmpty } == true }
        expect(kept, "   when the step fails the file is ImageIO's, its ISO and Apple maps in it, and it says \"\(written?.hdr ?? "nothing")\"")
    }

    // MARK: 6. a slide's ratio map

    static func romm(_ v: Double) -> UInt16 {
        let e = v < 1.0 / 512.0 ? v * 16 : pow(min(max(v, 0), 1), 1 / 1.8)
        return UInt16((min(max(e, 0), 1) * 65535).rounded())
    }

    static func slideChecks(_ expect: (Bool, String) -> Void, dir: URL) {
        let w = 320, h = 200, stride = 336, s = 0.25
        var a = [UInt16](repeating: 0, count: stride * h * 4), b = a
        func sdrValue(_ x: Int) -> Double { 0.002 * pow(500, Double(x) / Double(w - 1)) }
        func gainAt(_ v: Double) -> Double { v <= 0.3 ? 1 : min(3, 1 + 2 * (v - 0.3) / 0.7) }
        for y in 0..<h { for x in 0..<w {
            let v = sdrValue(x), o = 4 * (y * stride + x)
            for c in 0..<3 { a[o + c] = romm(v); b[o + c] = romm(v * gainAt(v) * s) }
            a[o + 3] = 65535; b[o + 3] = 65535
        } }
        var slide = FrameEdit(); slide.params.filmStock = "fujifilm_velvia_100"
        let rendition = HDRGain.rendition(for: slide, headroom: 4)
        let made: HDRGainMap.Attachment? = a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            (try? HDRGain.ratioMap(sdr: .init(rgba16: pa.baseAddress!, width: w, height: h, stride: stride),
                                   hdr: .init(rgba16: pb.baseAddress!, width: w, height: h, stride: stride), rendition: rendition)) ?? nil
        } }
        guard let made else { expect(false, "6. a slide's ratio map"); return }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let e = UInt8((HDRMath.encode(min(1, sdrValue(x))) * 255).rounded())
            for c in 0..<3 { px[y * ctx.bytesPerRow + 4 * x + c] = e }
            px[y * ctx.bytesPerRow + 4 * x + 3] = 255
        } }
        let image = ctx.makeImage()!
        for format in [ExportRecipe.Format.jpeg, .heif] {
            let url = dir.appendingPathComponent("slide.\(format.fileExtension)")
            let written = try? ExportWriter.write(image, format: format, quality: 92, to: url, gainMap: made, layout: .appleCamera)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let size = source.flatMap { HDRGainMap.size(in: $0) }
            expect(written != nil && source.map(HDRGainMap.present) == true && size?.width == w && size?.height == h,
                   String(format: "6. %@ written with a slide's ratio map (top %.2f), read back full size, \"%@\"", format.rawValue, made.headroom, written?.hdr ?? "none"))
        }
    }

    // MARK: 7. the base, to the bit (D3)

    /// The 8-bit P3 codes a reader decodes the primary picture to (no HDR request), whole.
    static func codes(_ url: URL) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none; ctx.setBlendMode(.copy)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? out : nil
    }

    /// D3 (2026-11-06 review: "turning Enable HDR on changes the exported file's SDR picture"): with a map attached
    /// ImageIO encodes a JPEG's primary with another encoder (one DHT, no restart interval, Apple's `AROT`) than
    /// without one — 78 % of this grained picture's samples moved, up to 11 codes (the review's frame: 34 %, up to
    /// 39). So the writer gives the primary the no-map encode's coding (`HDRUltraHDR.write(base:)`), and here:
    /// - a JPEG's coded picture (tables, frame, restart interval, scan) is the file without a map's **to the byte**,
    ///   and so is every decode of it by one decoder (libjpeg's `djpeg` gives both files the same pixels, measured);
    /// - ImageIO itself decodes a JPEG that carries a map with another decoder than a plain one — the JFIF `AMPF`
    ///   extension, the MPF index or ISO's APP2, any one of them alone, switches it (measured on these files): the
    ///   same coded picture reads back within 2 codes (its IDCT and upsampling), held to that;
    /// - a HEIF's decode is the file without a map's to the bit (ImageIO encodes and decodes it one way).
    static func baseChecks(_ expect: (Bool, String) -> Void, curve: HDRSessionCurve, dir: URL) {
        let w = 1200, h = 800
        let (image, bytes) = picture(w, h, noise: 12)
        defer { bytes.deallocate() }
        guard let attachment = try? HDRGainMap.exportAttachment(for: image, format: .jpeg, curve: curve) else { expect(false, "7. a map to write"); return }
        for format in [ExportRecipe.Format.jpeg, .heif] {
            let plain = dir.appendingPathComponent("d3-plain.\(format.fileExtension)")
            guard (try? ExportWriter.write(image, format: format, quality: 92, to: plain)) != nil, let want = codes(plain) else {
                expect(false, "7. \(format.rawValue) without a map written"); continue
            }
            for layout in [ExportRecipe.HDRLayout.appleCamera, .iso] {
                let mapped = dir.appendingPathComponent("d3-\(layout.rawValue).\(format.fileExtension)")
                guard let written = try? ExportWriter.write(image, format: format, quality: 92, to: mapped, gainMap: attachment, layout: layout),
                      let got = codes(mapped), got.count == want.count else { expect(false, "7. \(format.rawValue), \(layout.rawValue) written"); continue }
                var moved = 0, worst = 0
                for k in 0..<got.count where k % 4 != 3 && got[k] != want[k] { moved += 1; worst = max(worst, abs(Int(got[k]) - Int(want[k]))) }
                let said = "7. D3: \(format.rawValue), \(layout.rawValue) (\"\(written.hdr ?? "no map")\")"
                let decode = String(format: "ImageIO's decode moved %d of %d samples (%.2f %%), worst %d codes", moved, got.count / 4 * 3,
                                    100 * Double(moved) / Double(got.count / 4 * 3), worst)
                if format == .jpeg {
                    let a = (try? Data(contentsOf: mapped)) ?? Data(), b = (try? Data(contentsOf: plain)) ?? Data()
                    let r = try? HDRUltraHDR.read(mapped)
                    let same = r != nil && HDRUltraHDR.codedPicture(a, end: r!.primaryScan.upperBound) != nil && HDRUltraHDR.codedPicture(a, end: r!.primaryScan.upperBound) == HDRUltraHDR.codedPicture(b)
                    expect(same && worst <= 2, "\(said): its coded picture is the file without a map's to the byte (\(same)); \(decode) (≤ 2: ImageIO's other decoder)")
                } else {
                    expect(moved == 0, "\(said): its picture is the file without a map's to the bit; \(decode)")
                }
            }
        }
    }

    // MARK: --measure

    /// One map and one write of a W × H picture, its own process: phys_footprint before, at its peak, after.
    static func measure(_ w: Int, _ h: Int, _ fmt: String, _ curve: HDRSessionCurve, _ dir: URL) {
        let start = footprint()
        let (image, bytes) = picture(w, h, noise: 6)
        defer { bytes.deallocate() }
        let held = footprint()
        var peak = held
        var sampling = true
        let sampler = Thread { while sampling { peak = max(peak, footprint()); usleep(2000) } }
        sampler.start()
        let t0 = Date()
        let noMap = CommandLine.arguments.contains("--no-map")
        var map: HDRGainMap.Attachment?
        if !noMap {
            do { map = try HDRGainMap.exportAttachment(for: image, format: .jpeg, curve: curve) } catch { print("FAILED: \(error)"); exit(1) }
        }
        let mapPeak = peak, t1 = Date()
        if !noMap { print("  the map's strips: \(HDRRendition.lastTimes)") }
        let format: ExportRecipe.Format = fmt == "heic" ? .heif : .jpeg
        let url = dir.appendingPathComponent("m.\(format.fileExtension)")
        var said = "", ok = false
        do {
            let written = try ExportWriter.write(image, format: format, quality: 92, to: url, gainMap: map, layout: .appleCamera)
            said = written.hdr ?? "no map"; ok = true
        } catch { print("FAILED: \(error)") }
        let t2 = Date()
        sampling = false
        usleep(10_000)
        let mb = { (v: UInt64) in Double(v) / 1_048_576 }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print(String(format: "measure %d x %d %@ (%.1f MP) %@: written %@ (%@, %.1f MB); footprint start %.0f MB, with the picture %.0f MB; "
                     + "peak making the map %.0f MB (+%.0f); peak overall %.0f MB (+%.0f over the held picture, %.1f B a pixel); map %.2f s, write %.2f s",
                     w, h, fmt, Double(w * h) / 1e6, noMap ? "NO MAP" : "map", ok ? "yes" : "NO", said, Double(size) / 1_048_576, mb(start), mb(held),
                     mb(mapPeak), mb(mapPeak) - mb(held), mb(peak), mb(peak) - mb(held), Double(peak - held) / Double(w * h),
                     t1.timeIntervalSince(t0), t2.timeIntervalSince(t1)))
        exit(ok ? 0 : 1)
    }
}
