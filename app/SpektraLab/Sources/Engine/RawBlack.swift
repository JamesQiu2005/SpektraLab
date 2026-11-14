//  RawBlack.swift — a RAW whose deep shadows Apple's decoder leaves below zero is given back the black it lost: a
//  constant per channel, measured from the file, added in linear light at the decode, before the film — and, where the
//  decoder's clamp destroyed the shadows' colour, those shadows rendered neutral (`repair`).
//
//  **Why** (PRD/DIAG-2026-11-13-rw2-green-shadows-and-16gb-performance.md, Part 1): on a Panasonic DC-S1M2's RW2,
//  Core Image subtracts about 10 raw DN too much black in every CFA channel. White balance multiplies R and B by about
//  1.8–1.9, so the deficit is an uneven negative pedestal, and the deep shadows go green when anything lifts them.
//  The owner (2026-11-13): "when a RAW's deep shadows decode clearly below zero, the app adds back a per-channel
//  pedestal measured from that file, before the film; camera-independent; it changes nothing for files that decode
//  correctly." This is the decode's own correction (AGENTS.md: scene placement before the film, never the profile).
//
//  **The rule** (`read`), over one measurement of the file (`blocks`): the engine's recipe for the frame's white
//  balance and exposure (`RawExposure.recipe`, lens correction off, Core Image's draft decode), made 1,536 px on its
//  long edge, rendered in **linear Rec.2020** and cut into 8 × 8 blocks — each block the mean of ~400 sensor pixels on
//  a 24 MP file. A file is found when, in some channel, at least 2 % of its blocks average below zero by more than
//  twice a block's noise, and at least three quarters of those blocks are in the frame's darkest quarter.
//  - A correct decode's camera values are non-negative before its matrix, and Rec.2020 holds Pointer's gamut of real
//    surface colours, so a correct block averages ≥ 0 but for its noise; the noise is measured on the file (the two
//    halves of each dark block, `noise`), so a noisy file is held to its own noise, and no block is chosen by its own
//    darkness before it is counted (the share is over every block), so the darkest-blocks bias does not enter it.
//  - What a correct file can still put below zero — a light source beyond Rec.2020 (an LED, a laser), a hot pixel —
//    is bright, or one block: neither is 2 % of the frame's blocks sitting in its darkest quarter.
//  - Measured 2026-11-13 over `RAW_decode_tests` (`tools/raw_samples_check.sh`): 22 files, among them a Z7 II at
//    ISO 2,000 and two Leica Q3 frames whose median luminance is 0.002, have no block below zero in any channel but one
//    (a Q3's single green block, 1 of 24,384); the DC-S1M2's blue has 22 %.
//
//  **The pedestal**, where a file is found: per channel, the 0.1 % quantile of its blocks' means, less twice the block
//  noise, negated and never below 0 — so the darkest real blocks are lifted to zero and not past it. It is not the whole
//  deficit: Core Image clamps the over-subtracted values in camera space before its matrix (on the S1M2, 11 % of the
//  pixels come out exactly black, and a cluster at the camera's green primary), and no constant brings back what a
//  clamp took (`tools/raw_samples_check.sh`, the band table).
//
//  **The fade** (`repair`, 2.4.0's second form): the pedestal alone gave the clamped pixels its own colour — at ×8 the
//  blackest parts of the S1M2 went magenta and the rest stayed green, not a repair to ship. So past the pedestal, each
//  pixel's colour is faded toward the neutral axis as its luminance falls through a knee set by the pedestal (`kneeLow`,
//  `kneeHigh`), its luminance kept. What is lost: a deep shadow whose colour is real (on the S1M2, the dark red arch and
//  the red floor markings LibRaw shows) prints grey; the film path renders colour that deep as grey anyway at the app's
//  exposure (AGENTS.md trap 31) — at +4 EV of Film Exposure it is what shows. Only a found file is touched.
//
//  **Once per file, kept for the session** (as `LensResolver` keeps a lens): `resolve` measures a file when a page
//  opens it and before an export renders it, off the main actor; `found` is what a key and a decode ask, at any rate —
//  false until the file is resolved, so a frame never opened since launch is developed as it always was. A found
//  file's word joins its lens's (`LensResolution.word`: `|black=2`, the second form), so every key of its pixels and
//  the decode name one answer, and every other frame's keys are byte-identical. The pedestal of a found file is measured once for each
//  white balance and exposure treatment its decodes ask (the error is constant in camera space, so its vector after
//  white balance and the matrix depends on both), always at the same 1,536 px — the proxy, the live tier, the full
//  render and an export add the same numbers.

import CoreImage
import Foundation

enum RawBlack {
    /// The repair's word in a key, moved whenever what it measures or adds changes.
    static let version = "2"
    /// The repair on (the app); a check turns it off to show what it repairs (`tools/raw_samples_check.sh`).
    nonisolated(unsafe) static var enabled = true
    /// The repair's second step, the fade to neutral (`repair`); a check turns it off to show the pedestal alone, 2.4.0's
    /// first form, which gave the clamped shadows the pedestal's magenta (`tools/raw_samples_check.sh`).
    nonisolated(unsafe) static var fades = true

    /// What is added to every pixel, in linear Rec.2020 at the decode's own exposure.
    struct Pedestal: Equatable, Sendable {
        var r = 0.0, g = 0.0, b = 0.0
        static let zero = Pedestal()
        var isZero: Bool { r == 0 && g == 0 && b == 0 }
        var channels: [Double] { [r, g, b] }
        var text: String { String(format: "%.6f,%.6f,%.6f", r, g, b) }
    }

    /// One measurement and what the rule made of it.
    struct Reading: Sendable {
        /// Blocks that are not exactly black in every channel (a clamped block carries no measurement).
        var blocks = 0
        /// Per channel: the share of blocks below zero by more than `noiseSigmas` block noises.
        var negativeShare: [Double] = [0, 0, 0]
        /// Per channel: the share of blocks below zero at all, before and after the pedestal.
        var belowZero: [Double] = [0, 0, 0]
        var belowZeroAfter: [Double] = [0, 0, 0]
        /// Per channel: of the blocks counted by `negativeShare`, the share in the frame's darkest quarter.
        var darkShare: [Double] = [0, 0, 0]
        /// Per channel: one block mean's noise, from the two halves of the frame's darkest blocks.
        var noise: [Double] = [0, 0, 0]
        /// Per channel: the 0.1 % quantile of the block means.
        var floor: [Double] = [0, 0, 0]
        var found = false
        /// The rule's estimate, whether found or not: what a found file adds at another white balance (`pedestal(_:settings:)`).
        var estimate = Pedestal.zero
        /// What is added: the estimate where the file is found, else zero.
        var pedestal = Pedestal.zero
    }

    // MARK: the rule's numbers

    static let measureLongEdge = 1536
    static let block = 8
    static let tripShare = 0.02
    static let darkQuarterShare = 0.75
    static let noiseSigmas = 2.0
    static let floorQuantile = 0.001
    static let minimumBlocks = 1000
    /// Linear Rec.2020: where the rule reads and the pedestal is added.
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let luminance: (Double, Double, Double) = (0.2627, 0.6780, 0.0593)

    // MARK: the rule

    /// The rule over block means and the differences of their halves (rows 0–3 against 4–7), three per block.
    static func read(means: [Float], halves: [Float]) -> Reading {
        let n = means.count / 3
        var idx: [Int] = []
        idx.reserveCapacity(n)
        for i in 0..<n where !(means[i * 3] == 0 && means[i * 3 + 1] == 0 && means[i * 3 + 2] == 0) { idx.append(i) }
        var r = Reading()
        r.blocks = idx.count
        guard idx.count >= minimumBlocks else { return r }
        func y(_ i: Int) -> Double {
            luminance.0 * Double(means[i * 3]) + luminance.1 * Double(means[i * 3 + 1]) + luminance.2 * Double(means[i * 3 + 2])
        }
        let ys = idx.map(y)
        let sortedY = ys.sorted()
        let quarter = sortedY[sortedY.count / 4], tenth = sortedY[sortedY.count / 10]
        let dark = zip(idx, ys).filter { $0.1 <= tenth }.map(\.0)
        let count = Double(idx.count)
        for c in 0..<3 {
            // The block noise: a robust spread of the halves' difference over the darkest tenth, halved (the mean of
            // two halves has half the spread of their difference).
            let d = dark.map { Double(halves[$0 * 3 + c]) }
            let med = median(d)
            r.noise[c] = 1.4826 * median(d.map { abs($0 - med) }) / 2
            let bar = -noiseSigmas * r.noise[c]
            var below = 0, under = 0, inDark = 0
            for (k, i) in idx.enumerated() {
                let v = Double(means[i * 3 + c])
                if v < 0 { under += 1 }
                if v < bar { below += 1; if ys[k] <= quarter { inDark += 1 } }
            }
            r.negativeShare[c] = Double(below) / count
            r.belowZero[c] = Double(under) / count
            r.darkShare[c] = below > 0 ? Double(inDark) / Double(below) : 0
            let sorted = idx.map { Double(means[$0 * 3 + c]) }.sorted()
            r.floor[c] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * floorQuantile))]
        }
        r.found = (0..<3).contains { r.negativeShare[$0] >= tripShare && r.darkShare[$0] >= darkQuarterShare }
        let e = (0..<3).map { max(0, -r.floor[$0] - noiseSigmas * r.noise[$0]) }
        r.estimate = Pedestal(r: e[0], g: e[1], b: e[2])
        if r.found { r.pedestal = r.estimate }
        let p = r.pedestal.channels
        for c in 0..<3 {
            r.belowZeroAfter[c] = Double(idx.filter { Double(means[$0 * 3 + c]) + p[c] < 0 }.count) / count
        }
        return r
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    // MARK: the measurement

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false, .highQualityDownsample: true])

    /// The file's measurement for `settings`' white balance and exposure: block means and half differences in linear
    /// Rec.2020, with the picture's size. Nil where the file cannot be decoded. Heavy (0.1–0.8 s): never on the main thread.
    static func blocks(_ url: URL, settings: DecodeSettings) -> (means: [Float], halves: [Float], width: Int, height: Int)? {
        guard let filter = CIRAWFilter(imageURL: url), filter.baselineExposure.isFinite else { return nil }
        RawExposure.recipe(filter, settings: settings)
        filter.isLensCorrectionEnabled = false
        RawExposure.whiteBalance(filter, settings: settings)
        filter.isDraftModeEnabled = true
        let native = filter.nativeSize
        let long = max(native.width, native.height)
        if long > 0 { filter.scaleFactor = Float(min(1, Double(measureLongEdge) * 2 / Double(long))) }
        guard let decoded = filter.outputImage else { return nil }
        let e = decoded.extent.integral
        guard e.width > 0, e.height > 0 else { return nil }
        let image = RawExposure.scaled(decoded.transformed(by: .init(translationX: -e.origin.x, y: -e.origin.y)), toLongEdge: measureLongEdge)
        let box = image.extent.integral
        let w = Int(box.width), h = Int(box.height)
        guard w >= block, h >= block else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        autoreleasepool {
            context.render(image, toBitmap: &px, rowBytes: w * 16, bounds: box, format: .RGBAf, colorSpace: space)
        }
        context.clearCaches()
        let bw = w / block, bh = h / block, half = block / 2
        var means = [Float](repeating: 0, count: bw * bh * 3), halves = means
        let area = Float(block * block), halfArea = Float(block * half)
        for by in 0..<bh {
            for bx in 0..<bw {
                for c in 0..<3 {
                    var top: Float = 0, bottom: Float = 0
                    for y in 0..<block {
                        var s: Float = 0
                        let row = ((by * block + y) * w + bx * block) * 4 + c
                        for x in 0..<block { s += px[row + x * 4] }
                        if y < half { top += s } else { bottom += s }
                    }
                    means[(by * bw + bx) * 3 + c] = (top + bottom) / area
                    halves[(by * bw + bx) * 3 + c] = (top - bottom) / halfArea
                }
            }
        }
        return (means, halves, w, h)
    }

    /// The rule over the file's measurement for `settings`. Nil where the file cannot be decoded.
    static func measure(_ url: URL, settings: DecodeSettings) -> Reading? {
        guard let b = blocks(url, settings: settings) else { return nil }
        return read(means: b.means, halves: b.halves)
    }

    // MARK: kept for the session

    /// Found or not, by file (`resolve`).
    private static let verdicts = Locked<[String: Bool]>([:])
    /// A found file's pedestal, by file and the decode's white balance and exposure (`settingsWord`).
    private static let pedestals = Locked<[String: Pedestal]>([:])

    /// What a pedestal is measured for: white balance and the exposure treatment — not the lens (measured without it).
    static func settingsWord(_ settings: DecodeSettings) -> String {
        var d = settings
        d.lensFields = DecodeSettings().lensFields
        return d.pixelsKey
    }

    static func forgetAll() {
        verdicts.withLock { $0.removeAll() }
        pedestals.withLock { $0.removeAll() }
    }

    /// Whether `url` was resolved and found — what a key and a decode ask, on any thread, at any rate. False until
    /// `resolve` (a frame never opened since launch is developed as it always was), and with the repair off.
    static func found(_ url: URL?) -> Bool {
        guard enabled, let url else { return false }
        return verdicts.withLock { $0[url.standardizedFileURL.path] } ?? false
    }

    /// Whether `url` has been measured this session (found or not).
    static func resolved(_ url: URL) -> Bool { verdicts.withLock { $0[url.standardizedFileURL.path] } != nil }

    /// Measures `url` once (for `decode`'s white balance and exposure) and keeps whether it is found, and its pedestal
    /// for that decode. Heavy the first time a file is seen; kept after. Off the main actor.
    @discardableResult
    static func resolve(_ url: URL, decode: DecodeSettings) -> Bool {
        let path = url.standardizedFileURL.path
        if let kept = verdicts.withLock({ $0[path] }) { return enabled && kept }
        guard let reading = measure(url, settings: decode) else { return false }
        if reading.found { pedestals.withLock { $0[path + "|" + settingsWord(decode)] = reading.pedestal } }
        verdicts.withLock { $0[path] = reading.found }
        return enabled && reading.found
    }

    /// The pedestal a decode of a found `url` with `settings` adds: kept, or measured now (the first decode of a white
    /// balance the file was not resolved with). Zero for a file that is not found.
    static func pedestal(_ url: URL, settings: DecodeSettings) -> Pedestal {
        guard found(url) else { return .zero }
        let key = url.standardizedFileURL.path + "|" + settingsWord(settings)
        if let kept = pedestals.withLock({ $0[key] }) { return kept }
        // A found file: its pedestal for these settings, the rule's estimate (where no block is below zero any more at
        // this white balance, it is zero).
        guard let reading = measure(url, settings: settings) else { return .zero }
        let p = reading.estimate
        pedestals.withLock { $0[key] = p }
        return p
    }

    // MARK: the repair

    /// Where the shadow's colour is faded to the neutral axis, in multiples of the pedestal's largest channel (luminance,
    /// linear Rec.2020): wholly neutral below `kneeLow`, untouched above `kneeHigh`, a smoothstep in log luminance between.
    /// - **Why so wide.** The pedestal is the least the file lost, not what it lost: on the DC-S1M2, Apple's decode against
    ///   LibRaw's over 16 × 16 blocks (Y 0.003–0.05, lens off) has intercepts R −0.0030, G −0.0009, B −0.0031 — 6.3 ×, —,
    ///   4.4 × the pedestal (R 0.00047, G 0, B 0.00072) — because the clamp lifts the very blocks the floor is read from.
    ///   So the colour is wrong up to where the true deficit is a few percent of the signal: 64 pedestals is ~15 deficits.
    /// - Measured 2026-11-13 (R/G · B/G of 32-px blocks, Y 0.000125–0.0005 · 0.0005–0.002 · 0.002–0.008 · 0.008–0.032):
    ///   unrepaired 0.12·−0.07, 0.26·−0.02, 0.72·0.47, 1.02·0.64; the pedestal alone 4.36·6.59 (the clamped pixels take its
    ///   magenta), 0.59·0.50, 0.81·0.60, 1.05·0.69; knee 2–32 0.99·1.00, 0.97·0.95, 0.93·0.82, 1.05·0.73 (the floor still
    ///   teal when the film is printed +4 EV); this, 4–64, 1.00·1.00, 1.00·0.99, 0.98·0.94, 1.04·0.81; LibRaw 0.97·1.15,
    ///   1.05·0.93, 1.07·0.92, 1.13·0.84.
    static let kneeLow = 4.0
    static let kneeHigh = 64.0
    /// Samples of the fade's curve over 0…`kneeHigh` pedestals (a 1-D table, linearly interpolated: one sample is
    /// 1/64 of a pedestal, 1/256 of the knee's foot).
    static let fadeSamples = 4096

    /// The share of a pixel's colour kept at luminance `y` (linear Rec.2020, the pedestal added), for a file whose
    /// pedestal's largest channel is `top`: 0 at and below `kneeLow · top`, 1 at and above `kneeHigh · top`, a smoothstep in
    /// log₂ luminance between — smooth, monotonic, no step for the eye to find.
    static func kept(_ y: Double, top: Double) -> Double {
        guard top > 0 else { return 1 }
        let lo = log2(kneeLow * top), hi = log2(kneeHigh * top)
        let t = y > 0 ? min(1, max(0, (log2(y) - lo) / (hi - lo))) : 0
        return t * t * (3 - 2 * t)
    }

    /// `image` (Core Image's working space, linear) repaired with `p`, in linear Rec.2020: the pedestal added, then the
    /// colour of every pixel faded toward the neutral axis as its luminance falls through the knee (`kept`) — luminance
    /// itself is kept (the neutral axis has the pixel's own Y), so the tones are the pedestal's and only the colour moves.
    /// Where Apple's decode clamped a camera channel the colour is gone (black, or the camera's green primary); the
    /// pedestal alone gives those pixels its own magenta; neutral is what a correct decode's film prints there anyway
    /// (AGENTS.md trap 31). A per-pixel function of the decoded value and the file's constants, applied before the scale:
    /// the proxy, the live tier, the full render and an export make the same numbers. `image` itself where `p` is zero.
    static func repair(_ p: Pedestal, to image: CIImage) -> CIImage {
        let top = max(p.r, p.g, p.b)
        guard top >= minimumPedestal, let into = image.matchedFromWorkingSpace(to: space) else { return image }
        func v(_ x: Double, _ y: Double, _ z: Double) -> CIVector { CIVector(x: CGFloat(x), y: CGFloat(y), z: CGFloat(z), w: 0) }
        func matrix(_ im: CIImage, _ r: CIVector, _ g: CIVector, _ b: CIVector, bias: CIVector? = nil) -> CIImage {
            var parameters: [String: Any] = ["inputRVector": r, "inputGVector": g, "inputBVector": b]
            if let bias { parameters["inputBiasVector"] = bias }
            return im.applyingFilter("CIColorMatrix", parameters: parameters)
        }
        // Core Image drops a colour matrix's bias whose every term is below about 2.6e-4 (measured 2026-11-13: 2.5e-4 is
        // not added, 3e-4 is) — a pedestal's luminance is often that small. So the work is done `scale` times larger, where
        // every term is far above it, and brought back at the end (a power of two: exact).
        let k = scale
        let lifted = matrix(into, v(k, 0, 0), v(0, k, 0), v(0, 0, k), bias: v(k * p.r, k * p.g, k * p.b))
        func back(_ im: CIImage) -> CIImage {
            matrix(im, v(1 / k, 0, 0), v(0, 1 / k, 0), v(0, 0, 1 / k)).cropped(to: image.extent).matchedToWorkingSpace(from: space) ?? image
        }
        guard fades else { return back(lifted) }
        let (wr, wg, wb) = luminance
        // The lifted pixel's Y, as a grey (Y, Y, Y); its colour, the pixel less that grey.
        let grey = matrix(lifted, v(wr, wg, wb), v(wr, wg, wb), v(wr, wg, wb))
        let colour = matrix(lifted, v(1 - wr, -wg, -wb), v(-wr, 1 - wg, -wb), v(-wr, -wg, 1 - wb))
        // The share kept, of the grey: a 1-D table over 0…kneeHigh pedestals (a grey is a grey in every linear space with
        // one white, so the table's own colour space does not move it); below it 0, beyond it 1.
        let high = kneeHigh * top
        var table = [Float](repeating: 0, count: fadeSamples * 3)
        for i in 0..<fadeSamples {
            let kept = Float(kept(high * Double(i) / Double(fadeSamples - 1), top: top))
            table[i * 3] = kept; table[i * 3 + 1] = kept; table[i * 3 + 2] = kept
        }
        let share = grey.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table.withUnsafeBufferPointer { Data(buffer: $0) },
            "inputCurvesDomain": CIVector(x: 0, y: CGFloat(k * high)),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        // The compositing filters, not the blend modes (which clamp to 0…1); an addition's alpha is the two alphas' sum,
        // set back to one.
        let faded = colour.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: share])
        let repaired = faded.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: grey])
        return back(repaired.settingAlphaOne(in: repaired.extent))
    }
    /// How much larger the repair works (`repair`), and the least pedestal it acts on (below it, a measurement's noise).
    static let scale = 64.0
    static let minimumPedestal = 1e-5
}
