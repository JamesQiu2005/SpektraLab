// raw_samples_check.swift — one check over a folder of RAW files (the owner's `RAW_decode_tests/`, local, never in the
// repository) for the film path's decode (`RawExposure.prepare`) and its black repair (`RawBlack`), through the app's
// own functions. One row a file: camera, lens, ISO, Apple's decoder version, size, decoded or not; the share of
// 8 × 8 blocks below zero per channel in linear Rec.2020 (the engine's recipe, 1,536 px), before the repair and after
// it, the four darkest bands' R/G · B/G before and after, the pedestal the repair measured; and who corrects the lens
// (`LensResolver.resolve`, automatic, as the lens stages resolve it) and whether that correction changed the picture.
// The DC-S1M2's row also has its bands with the pedestal alone (2.4.0's first form, `RawBlack.fades` off).
//
// The bars, as checked numbers:
// - every file decodes;
// - after the repair, no channel has more than `negativeBar` (1 %) of its blocks below zero;
// - every file the repair does not find decodes bit for bit as it did before the repair (its decode with the repair
//   compiled in and the file resolved, against the same decode with the repair's answer taken out), and its key's
//   word is unchanged; the DC-S1M2 (`P2319446.RW2`) is found, and nothing else;
// - the DC-S1M2's repaired shadows are neutral: in the three darkest bands (Y 0.000125–0.008) R/G and B/G within
//   `neutralBar` (0.85–1.18; LibRaw's own decode of the file reads 0.92–1.15 there), and in none of the four is the
//   repaired colour further from neutral than Apple's — the pedestal alone fails the first (its clamped pixels are its
//   own magenta, 4.4 · 6.6 in the darkest band), the decode unrepaired fails it green;
// - the fade itself, on a made-up ramp (`fade`): luminance kept, colour gone below the knee and whole above it, the
//   share kept never falling as luminance rises;
// - the lens column is the resolution the lens stages established (`tools/lens_resolution_selftest.swift`): Core
//   Image for a NEF, CR3, RAF, RW2 and the Leica Q3's DNG; the file's own parameters for a Sony ARW; nobody for an
//   Apple ProRAW — and where someone corrects, the picture changed; where nobody does, it did not.
//
// The table is also written as Markdown under build/raw-samples-check/, with the DC-S1M2 lifted ×8 unrepaired, with the
// pedestal alone and repaired (JPEG, sRGB), and the three side by side (`P2319446-x8-side-by-side.jpg`). Absent samples: `SKIPPED: no samples at <path>` and a non-zero skipped count — a run
// of a few seconds skipped.
//
//   tools/raw_samples_check.sh [samples folder]
//   RAW_CHECK_DISABLE_REPAIR=1 tools/raw_samples_check.sh    # the repair off: the DC-S1M2's row must go red
//   RAW_CHECK_PEDESTAL_ONLY=1 tools/raw_samples_check.sh     # the pedestal alone (no fade): its shadows must go red

import CoreImage
import Foundation
import ImageIO
import Metal
import SwiftUI

extension Color { init(hexString: String) { self = .gray } }

@main
enum RawSamplesCheck {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var passes = 0
    static func expect(_ ok: Bool, _ label: String) { if ok { passes += 1 } else { failures.append(label); print("FAIL: \(label)") } }

    static let rawExtensions: Set<String> = ["arw", "nef", "cr3", "raf", "rw2", "dng", "orf"]
    /// After the repair, the most of a channel's blocks that may sit below zero: 1 %. The repair lifts the darkest real
    /// blocks to zero and not past (`RawBlack`), so blocks within a noise of zero stay below it — the DC-S1M2's green,
    /// 0.6 % of its blocks below zero before and after, has 0.06 % below twice its block noise (2026-11-13).
    static let negativeBar = 0.01
    /// The file the repair is for (PRD/DIAG-2026-11-13, Part 1).
    static let affected = "P2319446.RW2"
    /// The repaired DC-S1M2's R/G and B/G in its three darkest bands: neutral within this (2026-11-13: 1.00 · 1.00,
    /// 1.00 · 0.99, 0.98 · 0.94; LibRaw 0.97 · 1.15, 1.05 · 0.93, 1.07 · 0.92).
    static let neutralBar = (0.85, 1.18)
    /// The bands: Y (linear Rec.2020) 0.000125–0.0005, 0.0005–0.002, 0.002–0.008, 0.008–0.032.
    static let bandEdges = [0.000125, 0.0005, 0.002, 0.008, 0.032]
    static let edge = 1536

    static let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false, .highQualityDownsample: true])

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let started = Date()
        let disabled = ProcessInfo.processInfo.environment["RAW_CHECK_DISABLE_REPAIR"] == "1"
        RawBlack.enabled = !disabled
        let pedestalOnly = ProcessInfo.processInfo.environment["RAW_CHECK_PEDESTAL_ONLY"] == "1"
        RawBlack.fades = !pedestalOnly
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath + "/RAW_decode_tests")
        let out = URL(fileURLWithPath: args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath + "/build/raw-samples-check")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        synthetic()
        fade()
        var skipped = 0
        if FileManager.default.fileExists(atPath: root.path) {
            samples(root, out: out, disabled: disabled)
        } else {
            skipped += 1
            print("SKIPPED: no samples at \(root.path) — the sample rows did not run")
        }
        print(String(format: "raw_samples_check: %d checks, %d failures, %d skipped%@, %.1f s", passes + failures.count, failures.count,
                     skipped, disabled ? ", the repair OFF" : pedestalOnly ? ", the pedestal ALONE" : "", Date().timeIntervalSince(started)))
        if !failures.isEmpty { failures.forEach { print("  - \($0)") }; exit(1) }
    }

    // MARK: - the rule on blocks made here

    /// The rule on made-up blocks: inert on a dark, noisy, correct frame (and on one whose darkest blocks are chosen by
    /// their own noise), found on the same frame with a pedestal taken off, and the pedestal it gives back no larger
    /// than the one taken.
    static func synthetic() {
        var rng = SystemRandomNumberGenerator()
        func gauss() -> Double {
            let u = Double.random(in: 1e-12..<1, using: &rng), v = Double.random(in: 0..<1, using: &rng)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        let n = 20_000
        var means = [Float](repeating: 0, count: n * 3), halves = means
        var signal = [Double](repeating: 0, count: n * 3)
        for i in 0..<n {
            // Half the frame near black (a correct decode's: ≥ 0), half in the midtones; block noise 2e-4.
            let level = i < n / 2 ? Double.random(in: 0...0.002, using: &rng) : Double.random(in: 0.01...0.3, using: &rng)
            for c in 0..<3 {
                let s = level * [0.9, 1.0, 0.8][c]
                signal[i * 3 + c] = s
                let a = s + 2e-4 * gauss() * 1.4142, b = s + 2e-4 * gauss() * 1.4142
                means[i * 3 + c] = Float((a + b) / 2); halves[i * 3 + c] = Float(a - b)
            }
        }
        let correct = RawBlack.read(means: means, halves: halves)
        expect(!correct.found && correct.pedestal.isZero, "a correct, noisy frame is not found (blocks below −2σ: "
               + correct.negativeShare.map { String(format: "%.4f", $0) }.joined(separator: " ") + ")")
        let taken = [0.0006, 0.0003, 0.0012]
        var low = means
        for i in 0..<n { for c in 0..<3 { low[i * 3 + c] -= Float(taken[c]) } }
        let wrong = RawBlack.read(means: low, halves: halves)
        expect(wrong.found, "the same frame with a pedestal taken off is found")
        let p = wrong.pedestal.channels
        expect((0..<3).allSatisfy { p[$0] <= taken[$0] + 1e-6 }, "the pedestal is no larger than what was taken: "
               + p.map { String(format: "%.5f", $0) }.joined(separator: " "))
        expect(p[2] > taken[2] * 0.5, "… and gives back most of the channel that was lost most")
    }

    /// The fade on a made-up ramp (`RawBlack.repair`): 2,048 pixels from Y 1e-5 to 0.2 in log steps, each a grey with a
    /// green colour of a fifth of its luminance, under the DC-S1M2's pedestal. Luminance is the input's plus the pedestal's;
    /// below the knee's foot the colour is gone, above its top it is the pedestal-lifted input's; between, the share of
    /// colour kept never falls as luminance rises, and moves by no more than a sliver from one pixel to the next.
    static func fade() {
        let p = RawBlack.Pedestal(r: 0.000467, g: 0, b: 0.000716)
        let n = 2048, (wr, wg, wb) = RawBlack.luminance
        let pY = wr * p.r + wg * p.g + wb * p.b, top = max(p.r, p.g, p.b)
        var px = [Float](repeating: 1, count: n * 4)
        var ys = [Double](repeating: 0, count: n)
        // A colour with no luminance: green up, red and blue down.
        let green = (-0.2 * (wg / (wr + wb)), 0.2, -0.2 * (wg / (wr + wb)))
        for i in 0..<n {
            let y = 1e-5 * pow(0.2 / 1e-5, Double(i) / Double(n - 1))
            ys[i] = y
            px[i * 4] = Float(y * (1 + green.0)); px[i * 4 + 1] = Float(y * (1 + green.1)); px[i * 4 + 2] = Float(y * (1 + green.2))
        }
        let ramp = CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: n * 16,
                           size: CGSize(width: n, height: 1), format: .RGBAf, colorSpace: rec2020)
        let out = render(RawBlack.repair(p, to: ramp)).px
        var worstY = 0.0, worstStep = 0.0, falls = 0, below = 0.0, above = 0.0, last = -1.0
        for i in 0..<n {
            let lifted = (ys[i] * (1 + green.0) + p.r, ys[i] * (1 + green.1) + p.g, ys[i] * (1 + green.2) + p.b)
            let yIn = ys[i] + pY
            let r = Double(out[i * 4]), g = Double(out[i * 4 + 1]), b = Double(out[i * 4 + 2])
            let yOut = wr * r + wg * g + wb * b
            worstY = max(worstY, abs(yOut - yIn) / yIn)
            // The share of colour kept: the output's green less its luminance, over the lifted input's.
            let want = lifted.1 - yIn
            let kept = abs(want) > 1e-9 ? (g - yOut) / want : 1
            if yIn <= RawBlack.kneeLow * top { below = max(below, abs(g - yOut) / yIn) }
            if yIn >= RawBlack.kneeHigh * top { above = max(above, abs(kept - 1)) }
            if last >= 0 {
                if kept < last - 0.01 { falls += 1 }
                worstStep = max(worstStep, abs(kept - last))
            }
            last = kept
        }
        expect(worstY < 0.003, String(format: "the fade keeps luminance (worst %.4f %% of Y)", worstY * 100))
        expect(below < 0.003, String(format: "the fade leaves no colour below the knee's foot (worst %.4f of Y)", below))
        expect(above < 0.01, String(format: "the fade keeps the colour whole above the knee's top (worst %.4f)", above))
        expect(falls == 0 && worstStep < 0.02, String(format: "the share of colour kept never falls as luminance rises, and steps by at most %.4f a pixel (%d falls)", worstStep, falls))
    }

    // MARK: - the samples

    struct Row {
        var file = "", camera = "", lens = "", iso = "", decoder = "", size = ""
        var decoded = false
        var before = RawBlack.Reading()
        var afterBelow: [Double] = [0, 0, 0]
        var bandsBefore: [String] = [], bandsAfter: [String] = [], bandsPedestal: [String] = []
        var ratiosBefore: [(Double, Double)?] = [], ratiosAfter: [(Double, Double)?] = []
        var pedestal = RawBlack.Pedestal.zero
        var identical: Bool? = nil
        var wordBefore = "", wordAfter = ""
        var corrector = "", changed = ""
        var measureMs = 0.0
    }

    static func samples(_ root: URL, out: URL, disabled: Bool) {
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            // A folder whose name starts with "_" holds what was made from the samples (`DNG RAW/_prints`); a file's own
            // name may (a Nikon's `_DSC2663.NEF`).
            .filter { rawExtensions.contains($0.pathExtension.lowercased())
                && !$0.deletingLastPathComponent().pathComponents.contains { $0.hasPrefix("_") } }
            .sorted { $0.path < $1.path }
        let verdicts = FileManager.default.temporaryDirectory.appendingPathComponent("raw-samples-check-\(getpid()).json")
        LensResolver.configure(database: nil, verdicts: verdicts)
        defer { try? FileManager.default.removeItem(at: verdicts) }
        RawBlack.forgetAll()
        var rows: [Row] = []
        for url in files {
            var row = Row(file: url.lastPathComponent)
            let f = LensResolver.facts(url)
            row.camera = f.model
            row.lens = f.lens.isEmpty ? "(none)" : f.lens
            if let filter = CIRAWFilter(imageURL: url) {
                let exif = filter.properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                row.iso = ((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first).map { "\($0)" } ?? "?"
                row.decoder = filter.decoderVersion.rawValue
                row.size = "\(Int(filter.nativeSize.width))×\(Int(filter.nativeSize.height))"
            }
            let plain = DecodeSettings()
            // The word before the file is resolved: what every key was made with until now.
            row.wordBefore = LensCorrection.word(source: url, decode: plain)
            // The measurement, and the file resolved as a page's open resolves it.
            let t = Date()
            if let b = RawBlack.blocks(url, settings: plain) {
                row.before = RawBlack.read(means: b.means, halves: b.halves)
            }
            row.measureMs = Date().timeIntervalSince(t) * 1000
            RawBlack.resolve(url, decode: plain)
            row.wordAfter = LensCorrection.word(source: url, decode: plain)
            row.pedestal = RawBlack.pedestal(url, settings: plain)
            // The decode with the repair compiled in, as the app makes it now, and with the repair's answer taken out.
            var now = LensResolver.current(url, decode: plain)
            let repaired = RawExposure.prepare(url, settings: plain, longEdge: edge, lens: now)
            now.rawBlack = false
            let without = RawExposure.prepare(url, settings: plain, longEdge: edge, lens: now)
            row.decoded = repaired != nil
            if let repaired, let without {
                let a = render(repaired.image), b = render(without.image)
                row.identical = a.px == b.px
                let blocks = blockMeans(a.px, w: a.w, h: a.h), before = blockMeans(b.px, w: b.w, h: b.h)
                row.bandsAfter = bands(blocks)
                row.ratiosAfter = ratios(blocks)
                // The bands of the decode as the app made it before (the same 8 × 8 blocks as after, so the two compare).
                row.bandsBefore = bands(before)
                row.ratiosBefore = ratios(before)
                row.afterBelow = belowZero(blocks)
                if url.lastPathComponent == affected {
                    // The pedestal alone: 2.4.0's first form, for the table and the pictures.
                    let fades = RawBlack.fades
                    RawBlack.fades = false
                    now.rawBlack = true
                    let pedestal = RawExposure.prepare(url, settings: plain, longEdge: edge, lens: now)
                    RawBlack.fades = fades
                    if let pedestal {
                        let c = render(pedestal.image)
                        row.bandsPedestal = bands(blockMeans(c.px, w: c.w, h: c.h))
                    }
                    // The pictures from the run as the app makes it only, so a red run never writes over them.
                    let lifts = disabled || !RawBlack.fades ? []
                        : [("unrepaired", without.image), ("pedestal", pedestal?.image), ("repaired", repaired.image)]
                    var made: [CIImage] = []
                    for (name, image) in lifts {
                        guard let image, let l = lift(image, to: out.appendingPathComponent("P2319446-\(name)-x8.jpg")) else { continue }
                        made.append(l)
                    }
                    if !made.isEmpty { sideBySide(made, to: out.appendingPathComponent("P2319446-x8-side-by-side.jpg")) }
                }
            }
            // The lens: automatic, resolved as the lens stages resolve it, and whether its correction moved the picture.
            var on = plain; on.lensCorrection = true
            let r = waitFor { await LensResolver.resolve(url, decode: on) }
            row.corrector = r.corrector.rawValue
            if r.corrector == .coreImage {
                let d = CoreImageVerdicts.lookup(f)?.difference ?? 0
                row.changed = d > CoreImageVerdicts.bar ? String(format: "yes (%.3f)", d) : String(format: "no (%.3f)", d)
            } else if let a = RawExposure.prepare(url, settings: on, longEdge: 768, lens: r)?.image,
                      let b = RawExposure.prepare(url, settings: plain, longEdge: 768)?.image {
                row.changed = render(a).px == render(b).px ? "no" : "yes"
            }
            rows.append(row)
            print(line(row))
            if row.before.found || row.file == affected { print("    " + detail(row.before)) }
            judge(row)
        }
        expect(rows.contains { $0.file == affected } || disabled, "the DC-S1M2 sample (\(affected)) is among the samples")
        let md = markdown(rows, root: root, disabled: disabled)
        let name = disabled ? "raw-samples-check-repair-off.md" : RawBlack.fades ? "raw-samples-check.md" : "raw-samples-check-pedestal-only.md"
        try? md.write(to: out.appendingPathComponent(name), atomically: true, encoding: .utf8)
        print("written: \(out.appendingPathComponent(name).path)")
    }

    static func judge(_ r: Row) {
        expect(r.decoded, "\(r.file): decodes")
        let worst = r.afterBelow.max() ?? 0
        expect(worst <= negativeBar, "\(r.file): after the repair no channel has more than \(negativeBar * 100) % of its blocks below zero ("
               + r.afterBelow.map { String(format: "%.2f %%", $0 * 100) }.joined(separator: " ") + ")")
        if r.file == affected {
            expect(r.before.found && !r.pedestal.isZero, "\(r.file): the repair finds it and measures a pedestal")
            expect(r.identical == false, "\(r.file): its decode is repaired")
            expect(r.wordAfter == r.wordBefore + "|black=" + RawBlack.version, "\(r.file): its keys name the repair once it is found (\(r.wordAfter))")
            // Its shadows: neutral where Apple's decode destroyed their colour, and nowhere further from neutral than it.
            let (lo, hi) = neutralBar
            let deep = r.ratiosAfter.prefix(3)
            expect(deep.count == 3 && deep.allSatisfy { $0.map { lo...hi ~= $0.0 && lo...hi ~= $0.1 } ?? false },
                   "\(r.file): its three darkest bands are neutral after the repair, R/G and B/G within \(lo)–\(hi) (\(r.bandsAfter.prefix(3).joined(separator: "; ")))")
            func off(_ v: (Double, Double)?) -> Double { v.map { max(abs(log($0.0)), abs(log(max($0.1, 1e-3)))) } ?? 0 }
            let worse = zip(r.ratiosBefore, r.ratiosAfter).filter { off($0.1) > off($0.0) + 0.02 }.count
            expect(worse == 0, "\(r.file): no band's colour is further from neutral after the repair than before (\(r.bandsBefore.joined(separator: "; ")) → \(r.bandsAfter.joined(separator: "; ")))")
        } else {
            expect(!r.before.found && r.pedestal.isZero, "\(r.file): the repair does not find it")
            expect(r.identical == true, "\(r.file): decoded bit for bit as before the repair")
            expect(r.wordAfter == r.wordBefore, "\(r.file): its key's word is unchanged (\(r.wordAfter))")
        }
        let ext = (r.file as NSString).pathExtension.lowercased()
        var expected: String? = nil
        if ["nef", "cr3", "raf", "rw2"].contains(ext) || r.camera.contains("Q3") { expected = "core-image" }
        if ext == "arw" { expected = "embedded" }
        if r.camera.lowercased().hasPrefix("iphone") || r.lens.lowercased().contains("iphone") { expected = "nobody" }
        if let expected { expect(r.corrector == expected, "\(r.file): the lens is corrected by \(expected) (\(r.corrector))") }
        expect((r.corrector == "nobody") == !r.changed.hasPrefix("yes"),
               "\(r.file): the lens correction changes the picture where someone corrects it, and only there (\(r.corrector), \(r.changed))")
    }

    // MARK: - pictures and blocks

    static let rec2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    static func render(_ image: CIImage) -> (px: [Float], w: Int, h: Int) {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        autoreleasepool {
            context.render(image.transformed(by: .init(translationX: -e.origin.x, y: -e.origin.y)), toBitmap: &px, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: rec2020)
        }
        context.clearCaches()
        return (px, w, h)
    }

    static func blockMeans(_ px: [Float], w: Int, h: Int) -> [Float] {
        let bw = w / 8, bh = h / 8
        var m = [Float](repeating: 0, count: bw * bh * 3)
        for by in 0..<bh { for bx in 0..<bw { for c in 0..<3 {
            var s: Float = 0
            for y in 0..<8 { for x in 0..<8 { s += px[((by * 8 + y) * w + bx * 8 + x) * 4 + c] } }
            m[(by * bw + bx) * 3 + c] = s / 64
        } } }
        return m
    }

    /// The share of blocks below zero per channel (blocks exactly black in every channel left out, as the rule does).
    static func belowZero(_ m: [Float]) -> [Double] {
        var n = 0, below = [0, 0, 0]
        for i in 0..<(m.count / 3) where !(m[i * 3] == 0 && m[i * 3 + 1] == 0 && m[i * 3 + 2] == 0) {
            n += 1
            for c in 0..<3 where m[i * 3 + c] < 0 { below[c] += 1 }
        }
        return below.map { Double($0) / Double(max(n, 1)) }
    }

    /// R/G and B/G of the blocks' sums in the four luminance bands (`bandEdges`, Rec.2020's Y); nil where a band has
    /// fewer than 20 blocks.
    static func ratios(_ m: [Float]) -> [(Double, Double)?] {
        zip(bandEdges.dropLast(), bandEdges.dropFirst()).map { lo, hi in
            var s = [0.0, 0.0, 0.0], n = 0
            for i in 0..<(m.count / 3) {
                let y = 0.2627 * Double(m[i * 3]) + 0.6780 * Double(m[i * 3 + 1]) + 0.0593 * Double(m[i * 3 + 2])
                guard y >= lo, y < hi else { continue }
                n += 1
                for c in 0..<3 { s[c] += Double(m[i * 3 + c]) }
            }
            return n < 20 || s[1] <= 0 ? nil : (s[0] / s[1], s[2] / s[1])
        }
    }

    static func bands(_ m: [Float]) -> [String] {
        ratios(m).map { $0.map { String(format: "%.2f · %.2f", $0.0, $0.1) } ?? "—" }
    }

    /// `image` ×8, sRGB, as a JPEG: the diagnosis's ×8 lift (PRD/diag-2026-11-13-rw2-and-16gb/). Returns the lift.
    @discardableResult
    static func lift(_ image: CIImage, to url: URL) -> CIImage? {
        let e = image.extent.integral
        let lifted = image.transformed(by: .init(translationX: -e.origin.x, y: -e.origin.y)).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 8, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 8, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 8, w: 0)])
        try? context.writeJPEGRepresentation(of: lifted, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
        return lifted
    }

    /// Lifts left to right with a white gap, as one JPEG.
    static func sideBySide(_ images: [CIImage], to url: URL) {
        guard let first = images.first else { return }
        let gap: CGFloat = 16, w = first.extent.width, h = images.map(\.extent.height).max() ?? first.extent.height
        var canvas = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: (w + gap) * CGFloat(images.count) - gap, height: h))
        for (i, im) in images.enumerated() {
            canvas = im.transformed(by: .init(translationX: CGFloat(i) * (w + gap), y: 0)).composited(over: canvas)
        }
        try? context.writeJPEGRepresentation(of: canvas, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
    }

    // MARK: - the table

    static func pct(_ v: [Double]) -> String { v.map { String(format: "%.1f", $0 * 100) }.joined(separator: " · ") }

    static func line(_ r: Row) -> String {
        "\(r.file) | \(r.camera) | \(r.lens) | ISO \(r.iso) | RAW \(r.decoder) | \(r.size) | \(r.decoded ? "decoded" : "NOT DECODED") | below 0 %: "
            + pct(r.before.belowZero) + " → " + pct(r.afterBelow) + " | bands " + r.bandsBefore.joined(separator: ", ") + " → "
            + r.bandsAfter.joined(separator: ", ") + " | pedestal " + r.pedestal.text + " | "
            + (r.identical == true ? "identical" : r.identical == false ? "repaired" : "?") + " | lens \(r.corrector), changed \(r.changed)"
            + String(format: " | measured in %.0f ms", r.measureMs)
    }

    /// The rule's reading of a file: per channel R · G · B.
    static func detail(_ r: RawBlack.Reading) -> String {
        func f(_ v: [Double], _ fmt: String) -> String { v.map { String(format: fmt, $0) }.joined(separator: " · ") }
        return "the rule: \(r.blocks) blocks; below −2σ " + f(r.negativeShare.map { $0 * 100 }, "%.2f %%") + "; of those in the darkest quarter "
            + f(r.darkShare.map { $0 * 100 }, "%.0f %%") + "; block noise σ " + f(r.noise, "%.6f") + "; 0.1 % quantile " + f(r.floor, "%+.6f")
            + "; found \(r.found)"
    }

    static func markdown(_ rows: [Row], root: URL, disabled: Bool) -> String {
        var s = "# RAW samples check\n\n"
        s += "`tools/raw_samples_check.sh` over `\(root.path)`, \(Date())\(disabled ? ", **the repair off**" : ""). "
        s += "Blocks: 8 × 8 of the engine's recipe at \(edge) px, linear Rec.2020. Bands: R/G · B/G in Y 0.000125–0.0005, 0.0005–0.002, 0.002–0.008, 0.008–0.032. "
        s += "Pedestal: linear Rec.2020, at the decode's exposure (`RawBlack`).\n\n"
        s += "| file | camera | lens | ISO | RAW | size | decoded | blocks < 0, R · G · B % (before → after) | bands before | bands after | pedestal R,G,B | vs. before the repair | lens corrected by | changed | measure ms |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for r in rows {
            s += "| \(r.file) | \(r.camera) | \(r.lens) | \(r.iso) | \(r.decoder) | \(r.size) | \(r.decoded ? "yes" : "**no**") | "
            s += pct(r.before.belowZero) + " → " + pct(r.afterBelow) + " | " + r.bandsBefore.joined(separator: "; ") + " | "
            s += r.bandsAfter.joined(separator: "; ") + " | " + (r.pedestal.isZero ? "0" : r.pedestal.text) + " | "
            s += (r.identical == true ? "bit-identical" : r.identical == false ? "repaired" : "?") + " | \(r.corrector) | \(r.changed) | "
            s += String(format: "%.0f |\n", r.measureMs)
        }
        for r in rows where r.before.found || r.file == affected {
            s += "\n\(r.file) — " + detail(r.before) + "\n"
            s += "\n\(r.file) — bands, unrepaired: " + r.bandsBefore.joined(separator: "; ") + "; the pedestal alone: "
                + r.bandsPedestal.joined(separator: "; ") + "; repaired: " + r.bandsAfter.joined(separator: "; ") + "\n"
        }
        s += "\n\(failures.isEmpty ? "All bars met." : "**Failures:**\n\n" + failures.map { "- \($0)" }.joined(separator: "\n"))\n"
        return s
    }

    static func waitFor<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Locked<T?>(nil)
        Task.detached { let v = await body(); box.withLock { $0 = v }; done.signal() }
        done.wait()
        return box.withLock { $0! }
    }
}
