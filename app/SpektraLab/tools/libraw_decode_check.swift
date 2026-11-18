// libraw_decode_check.swift — Settings' RAW decoder (2.4.2) through the app's own decode (`RawExposure.prepare`), over
// a folder of RAW files (the owner's `RAW_decode_tests/`, local, never in the repository), with the helper the app
// bundles (`vendor/libraw/macos/spkraw-host`, named by SPEKTRALAB_RAW_HOST).
//
// The bars, as checked numbers:
// - the keys: Apple's decode keys are 2.4.1's byte for byte (no decoder word); LibRaw's add `|decoder=libraw.1` to
//   `pixelsKey` and `exposureKey` (the develop stamp's), so one decoder's picture is never kept under the other's;
// - every file LibRaw reads is decoded by LibRaw (its facts say `libraw …`), at the size asked, with the frame's shape
//   and orientation: aspect within 2 % of Apple's, and the two decodes' log-luminance at 64 px correlated above
//   `correlationBar` (a picture upside down or turned correlates far below it);
// - LibRaw's exposure is Core Image's, roughly: its mean linear luminance within ±`exposureBar` (0.5 EV) of Apple's, the
//   file's baseline exposure applied by both (another decoder, not another exposure);
// - a custom white balance moves LibRaw's picture (warmer at 7500 K than at 3500 K: R/B rises), and the neutral pick
//   (`NeutralPick.decodeBalance`) returns a white balance in range, in one decode;
// - with no helper (SPEKTRALAB_RAW_HOST naming nothing), every file is Apple's decode, as if LibRaw were not chosen.
// A file neither decoder reads is a failure; a file only Apple reads is listed, not failed (LibRaw's camera table).
//
//   tools/libraw_decode_check.sh [samples folder]
//   LIBRAW_CHECK_BREAK_ORIENTATION=1 tools/libraw_decode_check.sh   # LibRaw's picture turned over: every row must fail

import CoreImage
import Foundation
import ImageIO
import Metal
import SwiftUI

extension Color { init(hexString: String) { self = .gray } }

@main
struct LibRawDecodeCheck {
    static let correlationBar = 0.80
    /// LibRaw's mean linear luminance against Core Image's, in EV: the same exposure, give or take the decoders' own.
    static let exposureBar = 0.5
    static let edge = 64
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                             .cacheIntermediates: false])

    /// `image` as `edge`-long-edge linear ProPhoto luminance, top row first.
    static func luminance(_ image: CIImage) -> (w: Int, h: Int, y: [Double])? {
        let small = RawExposure.scaled(image, toLongEdge: edge)
        let e = small.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: LibRawDecode.linearProPhoto)
        var y = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) { y[i] = 0.2880 * Double(px[4 * i]) + 0.7119 * Double(px[4 * i + 1]) + 0.0001 * Double(px[4 * i + 2]) }
        return (w, h, y)
    }

    static func rgbMean(_ image: CIImage) -> SIMD3<Double> {
        let small = RawExposure.scaled(image, toLongEdge: edge)
        let e = small.extent.integral
        let w = Int(e.width), h = Int(e.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: LibRawDecode.linearProPhoto)
        var s = SIMD3<Double>(0, 0, 0)
        for i in 0..<(w * h) { s += SIMD3(Double(px[4 * i]), Double(px[4 * i + 1]), Double(px[4 * i + 2])) }
        return s / Double(w * h)
    }

    /// Pearson correlation of log luminance, `b` resampled to `a`'s grid by nearest neighbour.
    static func correlation(_ a: (w: Int, h: Int, y: [Double]), _ b: (w: Int, h: Int, y: [Double])) -> Double {
        var xs = [Double](), ys = [Double]()
        for r in 0..<a.h { for c in 0..<a.w {
            let br = min(b.h - 1, r * b.h / a.h), bc = min(b.w - 1, c * b.w / a.w)
            xs.append(log(max(a.y[r * a.w + c], 1e-5))); ys.append(log(max(b.y[br * b.w + bc], 1e-5)))
        } }
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<xs.count { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx); syy += (ys[i] - my) * (ys[i] - my) }
        return sxy / max(sqrt(sxx * syy), 1e-12)
    }

    /// This process's footprint (what jetsam counts), in GB.
    static func footprintGB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e9 : -1
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = CommandLine.arguments
        let samples = URL(fileURLWithPath: args.count > 1 ? args[1] : "RAW_decode_tests")
        let breakOrientation = ProcessInfo.processInfo.environment["LIBRAW_CHECK_BREAK_ORIENTATION"] == "1"
        var failures = 0
        func fail(_ s: String) { failures += 1; print("FAIL " + s) }

        // The keys.
        var decode = DecodeSettings()
        RawDecoderChoice.current = .system
        let appleKey = decode.pixelsKey
        if appleKey.contains("decoder=") { fail("Apple's pixelsKey carries a decoder word: \(appleKey)") }
        // The develop stamp adds `exposureKey` for a RAW (`DevelopStamp.of`): the word there moves it.
        if decode.exposureKey != "|raw=source-reference.2" { fail("Apple's exposureKey is \(decode.exposureKey), not 2.4.1's") }
        RawDecoderChoice.current = .libraw
        if decode.pixelsKey != appleKey + "|decoder=libraw.1" { fail("LibRaw's pixelsKey is \(decode.pixelsKey)") }
        if !decode.exposureKey.hasSuffix("|decoder=libraw.1") { fail("LibRaw's exposureKey (the stamp's) is \(decode.exposureKey)") }
        RawDecoderChoice.current = .system
        print("keys: Apple \(appleKey) · LibRaw \(appleKey)|decoder=libraw.1")

        guard LibRawDecode.isAvailable, let version = LibRawDecode.version else {
            print("FAIL no helper at \(LibRawDecode.executable.path)"); exit(1)
        }
        print("helper: \(LibRawDecode.executable.path), LibRaw \(version)")

        let fm = FileManager.default
        let raws = (fm.enumerator(at: samples, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { ["arw", "cr3", "cr2", "nef", "raf", "rw2", "orf", "dng"].contains($0.pathExtension.lowercased()) }
            .filter { !$0.path.contains("/_prints/") }
            .sorted { $0.path < $1.path }
        guard !raws.isEmpty else { print("SKIPPED: no samples at \(samples.path)"); exit(failures == 0 ? 0 : 1) }

        decode = DecodeSettings()
        let lens = LensResolution.off(decode, isRAW: true)
        print("| file | LibRaw | size | aspect Δ | corr | ΔEV vs Apple | WB R/B 3500→7500 K | pick | ms |")
        print("|---|---|---|---:|---:|---:|---|---|---:|")
        var decoded = 0
        for url in raws { autoreleasepool {
            let name = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            RawDecoderChoice.current = .system
            let apple = RawExposure.prepare(url, settings: decode, longEdge: 1024, lens: lens)
            RawDecoderChoice.current = .libraw
            let start = Date()
            let lib = RawExposure.prepare(url, settings: decode, longEdge: 1024, lens: lens)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            RawDecoderChoice.current = .system
            guard let lib else { if apple == nil { fail("\(name): neither decoder reads it") }; return }
            guard lib.facts.decoderVersion.hasPrefix("libraw") else {
                print("| \(name) | Apple's (LibRaw cannot read it) | | | | | | | |")
                if apple == nil { fail("\(name): neither decoder reads it") }
                return
            }
            decoded += 1
            var image = lib.image
            if breakOrientation { image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)).transformed(by: .init(translationX: 0, y: image.extent.height)) }
            let e = image.extent.integral
            if max(e.width, e.height) != 1024 { fail("\(name): LibRaw's picture is \(Int(e.width))×\(Int(e.height)), not 1024 long") }
            guard let apple else { print("| \(name) | \(lib.facts.decoderVersion) | \(Int(e.width))×\(Int(e.height)) | (Apple cannot read it) | | | | | \(ms) |"); return }
            let ae = apple.image.extent.integral
            let aspect = abs(Double(e.width / e.height) / Double(ae.width / ae.height) - 1)
            if aspect > 0.02 { fail("\(name): aspect \(e.width)×\(e.height) against Apple's \(ae.width)×\(ae.height)") }
            // The whole frame is Core Image's to the pixel: the size every export and crop was planned with.
            if let size = LibRawDecode.appleSize(url), lib.sourcePixels != Double(size.width * size.height) {
                fail("\(name): LibRaw's frame has \(Int(lib.sourcePixels)) pixels, Core Image's \(size.width)×\(size.height)")
            }
            guard let la = luminance(apple.image), let lb = luminance(image) else { fail("\(name): no luminance"); return }
            let corr = correlation(la, lb)
            if corr < correlationBar { fail("\(name): correlation \(String(format: "%.3f", corr)) with Apple's decode") }
            let ev = log2(lb.y.reduce(0, +) / max(la.y.reduce(0, +), 1e-12))
            if abs(ev) > exposureBar { fail("\(name): LibRaw's exposure is \(String(format: "%+.2f", ev)) EV from Apple's") }
            // White balance: 3500 K and 7500 K custom.
            var warm = decode, cool = decode
            cool.setCustom(temperature: 3500, tint: 0); warm.setCustom(temperature: 7500, tint: 0)
            RawDecoderChoice.current = .libraw
            let c = RawExposure.prepare(url, settings: cool, longEdge: 256, lens: lens).map { rgbMean($0.image) }
            let w = RawExposure.prepare(url, settings: warm, longEdge: 256, lens: lens).map { rgbMean($0.image) }
            let pick = NeutralPick.decodeBalance(url: url, settings: decode, at: CGPoint(x: 0.5, y: 0.5), start: (5500, 0))
            RawDecoderChoice.current = .system
            var wbText = "-"
            if let c, let w {
                let rc = c.x / max(c.z, 1e-9), rw = w.x / max(w.z, 1e-9)
                wbText = String(format: "%.2f→%.2f", rc, rw)
                if !(rw > rc * 1.1) { fail("\(name): 7500 K is not warmer than 3500 K (R/B \(wbText))") }
            } else { fail("\(name): a custom white balance did not decode") }
            let pickText = pick.map { String(format: "%.0f K %+.0f", $0.temperature, $0.tint) } ?? "none (dark or clipped centre)"
            if let pick, !(NeutralPick.temperatureRange.contains(pick.temperature) && NeutralPick.tintRange.contains(pick.tint)) {
                fail("\(name): the pick is out of range")
            }
            print("| \(name) | \(lib.facts.decoderVersion) | \(Int(e.width))×\(Int(e.height)) | \(String(format: "%.2f%%", aspect * 100)) | \(String(format: "%.3f", corr)) | \(String(format: "%+.2f", ev)) | \(wbText) | \(pickText) | \(ms) |")
            FileHandle.standardError.write(Data(String(format: "footprint after %@: %.2f GB\n", name, footprintGB()).utf8))
        } }
        if decoded == 0 { fail("LibRaw decoded none of \(raws.count) files") }

        // No helper: Apple's decode, as if LibRaw were not chosen.
        setenv("SPEKTRALAB_RAW_HOST", "/nonexistent/spkraw-host", 1)
        RawDecoderChoice.current = .libraw
        if let first = raws.first, let p = RawExposure.prepare(first, settings: decode, longEdge: 256, lens: lens),
           p.facts.decoderVersion.hasPrefix("libraw") {
            fail("with no helper the decode still says \(p.facts.decoderVersion)")
        }
        RawDecoderChoice.current = .system
        print("no helper: Apple's decode")

        print(failures == 0 ? "PASS libraw_decode_check (\(decoded) of \(raws.count) files decoded by LibRaw)"
                            : "FAIL libraw_decode_check: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
