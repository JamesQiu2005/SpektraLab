//  raw_open_probe.swift -- what a RAW's first open at a preview size costs, by how the proxy is made.
//
//  One arm per process (a fresh process is the only rest there is: Core Image keeps what it peaked at until its
//  context and filter go), the app's own recipe (`RawExposure.prepare`, compiled in) and the app's own context
//  options (`FrameDecoder.readied`). Prints one JSON line: the footprint before the decode, the highest the ledger
//  saw during it (`phys_footprint`, sampled every 2 ms, and the kernel's own peak), the time, and the proxy's
//  pixels written to `--out` for a pixel comparison (`--compare A B`).
//
//    raw_open_probe ARM FILE EDGE --out PIXELS.bin       ARM: whole | banded | scale
//    raw_open_probe --compare A.bin B.bin                 the two proxies' difference
//
//  `whole`  : today's proxy (`FrameDecoder.proxied`): Lanczos over the clamped decode, rendered in bands of 4 MP of
//             *output* -- one band at 1,920 px, so the whole decode is asked for at once.
//  `banded` : the same picture, rendered in bands of 4 MP of the *original* it is made from.
//  `scale`  : the RAW filter's own `scaleFactor` (never used by the app; the RAW 9 fault) to the same long edge.
import CoreImage
import Foundation
import Metal

func footprint() -> (now: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? (UInt64(info.phys_footprint), UInt64(info.ledger_phys_footprint_peak)) : (0, 0)
}

final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var high: UInt64 = 0
    private var running = true
    func start() {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                if !go { return }
                let f = footprint().now
                lock.lock(); high = max(high, f); lock.unlock()
                usleep(2000)
            }
        }
    }
    func stop() -> UInt64 { lock.lock(); running = false; let h = high; lock.unlock(); return h }
}

let mb = 1_048_576.0

func halfToFloat(_ h: UInt16) -> Float { Float(Float16(bitPattern: h)) }

func compare(_ a: String, _ b: String) {
    func load(_ p: String) -> (Int, Int, [UInt16]) {
        let d = try! Data(contentsOf: URL(fileURLWithPath: p))
        let w = Int(d.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        let h = Int(d.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        let px = d.subdata(in: 8..<d.count).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        return (w, h, px)
    }
    let (wa, ha, pa) = load(a), (wb, hb, pb) = load(b)
    guard wa == wb, ha == hb else { print("{\"sizes\":\"\(wa)x\(ha) vs \(wb)x\(hb)\"}"); return }
    var maxAbs: Float = 0, sumAbs = 0.0, sumA = 0.0, identical = 0, code1 = 0, maxCode = 0, n = 0
    func srgb8(_ v: Float) -> Int {
        let x = min(max(v, 0), 1)
        let e = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return Int((e * 255).rounded())
    }
    for i in stride(from: 0, to: pa.count, by: 4) {
        for c in 0..<3 {
            let x = halfToFloat(pa[i + c]), y = halfToFloat(pb[i + c])
            let d = abs(x - y)
            if pa[i + c] == pb[i + c] { identical += 1 }
            maxAbs = max(maxAbs, d); sumAbs += Double(d); sumA += Double(abs(x)); n += 1
            let dc = abs(srgb8(x) - srgb8(y))
            if dc >= 1 { code1 += 1 }
            maxCode = max(maxCode, dc)
        }
    }
    print(String(format: "{\"size\":\"%dx%d\",\"identical_share\":%.6f,\"max_abs\":%.6g,\"mean_abs\":%.6g,\"mean_abs_rel_to_mean\":%.6g,\"srgb8_share_ge1\":%.6f,\"srgb8_max\":%d}",
                 wa, ha, Double(identical) / Double(n), maxAbs, sumAbs / Double(n), sumAbs / max(sumA, 1e-12), Double(code1) / Double(n), maxCode))
}

@main
struct Probe {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "--compare" { compare(args[2], args[3]); return }
        guard args.count >= 6, args[4] == "--out" else {
            print("usage: raw_open_probe whole|banded|scale FILE EDGE --out PIXELS.bin"); exit(2)
        }
        let arm = args[1], url = URL(fileURLWithPath: args[2]), edge = Int(args[3])!, out = args[5]
        let device = MTLCreateSystemDefaultDevice()!
        // `FrameDecoder.readied`, word for word.
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .highQualityDownsample: true])
        var settings = DecodeSettings()
        // The app's default for a new RAW frame is lens correction on (`AppSettings.lensCorrection`).
        settings.lensCorrection = ProcessInfo.processInfo.environment["LENS"] != "0"
        let before = footprint().now
        let sampler = Sampler(); sampler.start()
        let t0 = Date()
        var image: CIImage
        var how = ""
        var sourcePixels = 0.0
        var decoder = ""
        if arm == "scale" {
            // The recipe, then the filter's own scale to the long edge.
            let filter = CIRAWFilter(imageURL: url)!
            let native = filter.nativeSize
            sourcePixels = Double(native.width * native.height)
            decoder = filter.decoderVersion.rawValue
            // Same settings as `prepare`, on a filter of our own so its scale can be set.
            let f = CIRAWFilter(imageURL: url)!
            let baseline = f.baselineExposure
            f.baselineExposure = baseline
            f.exposure = Float(settings.rawExposureTreatment.sourceOffsetEV)
            f.shadowBias = 0
            f.boostAmount = 0; f.boostShadowAmount = 0; f.isGamutMappingEnabled = false
            f.localToneMapAmount = 0; f.extendedDynamicRangeAmount = 0; f.isLensCorrectionEnabled = settings.lensCorrection
            let long = max(native.width, native.height)
            f.scaleFactor = Float(Double(edge) / Double(long))
            let o = f.outputImage!
            let e = o.extent
            image = o.cropped(to: CGRect(x: e.minX.rounded(.up), y: e.minY.rounded(.up),
                                         width: (e.width).rounded(.down), height: (e.height).rounded(.down)))
            how = "scaleFactor \(f.scaleFactor), extent \(e)"
        } else {
            let filter = CIRAWFilter(imageURL: url)!
            let native = filter.nativeSize
            sourcePixels = Double(native.width * native.height)
            decoder = filter.decoderVersion.rawValue
            image = RawExposure.prepare(url, settings: settings, longEdge: edge)!.image
            how = "lanczos"
        }
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        let placed = image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        let rowBytes = w * 8
        var pixels = Data(count: rowBytes * h)
        let outBands = max(1, Int((Double(w) * Double(h) / 4_000_000).rounded(.up)))
        let bandSource = Double(ProcessInfo.processInfo.environment["BAND_MP"] ?? "4")! * 1_000_000
        let bands = arm == "banded" ? max(outBands, Int((sourcePixels / bandSource).rounded(.up))) : outBands
        pixels.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for b in 0..<bands {
                autoreleasepool {
                    let r0 = h * b / bands, r1 = h * (b + 1) / bands
                    context.render(placed, toBitmap: base + r0 * rowBytes, rowBytes: rowBytes,
                                   bounds: CGRect(x: 0, y: h - r1, width: w, height: r1 - r0),
                                   format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
                }
            }
        }
        let seconds = Date().timeIntervalSince(t0)
        let sampled = sampler.stop()
        let kernelPeak = footprint().peak
        context.clearCaches()
        var file = Data()
        withUnsafeBytes(of: UInt32(w)) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(h)) { file.append(contentsOf: $0) }
        file.append(pixels)
        try! file.write(to: URL(fileURLWithPath: out))
        print(String(format: "{\"arm\":\"%@\",\"file\":\"%@\",\"decoder\":\"%@\",\"source_mp\":%.1f,\"out\":\"%dx%d\",\"bands\":%d,\"before_mb\":%.0f,\"sampled_peak_mb\":%.0f,\"kernel_peak_mb\":%.0f,\"added_sampled_mb\":%.0f,\"added_kernel_mb\":%.0f,\"seconds\":%.3f,\"how\":\"%@\"}",
                     arm, url.lastPathComponent, decoder, sourcePixels / 1e6, w, h, bands, Double(before) / mb, Double(sampled) / mb,
                     Double(kernelPeak) / mb, Double(sampled.subtractingOrZeroProbe(before)) / mb,
                     Double(kernelPeak.subtractingOrZeroProbe(before)) / mb, seconds, how))
    }
}

extension UInt64 { func subtractingOrZeroProbe(_ o: UInt64) -> UInt64 { self > o ? self - o : 0 } }
