//  engine_smoke.swift — does the engine start and render on this Mac, and is the picture the same?
//
//  One executable over the C ABI alone, built by `tools/engine_smoke.sh mac` against `engine/build`
//  (`engine/build.sh dylib`, then `metallib`): a frame made from integers, opened the way the app
//  opens one (`spk_open_device` on the host's own device), developed at the canvas's size and at
//  full size, each render's sha256 printed, so two builds of the engine can be held against each
//  other to the bit.
//
//  **A smoke test, not a measurement** (AGENTS.md): its times and its footprint are this Mac's.
//  What it settles is whether the engine runs the kernels at all, and to the bit.
//
//  **Scene Placement's Fit, on a photograph** (`PlacementGrid`, below):
//
//      tools/engine_smoke.sh mac --latitude-grid <photo> [out.jsonl]     the grid, the sweeps, placed histograms
//      tools/engine_smoke.sh mac --latitude-sweeps <photo> [out.jsonl]   the sweeps and placed histograms only
//
//  The app solves a ruler step itself (`Sources/Engine/ScenePlacement.swift`), and the engine stays
//  the judge of that: these two print what the engine's own Fit says of a real frame, opened as the
//  develop page opens one, and `tools/latitude_selftest.swift` holds the app's solve against the
//  lines kept in `tools/engine_replies/scene_placement_*.jsonl`. The photographs are not in the
//  repository (AGENTS.md: fixtures live outside it); the files say which they were.

import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Metal

@main
enum EngineSmoke {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: engine_smoke <resources dir> [width height]"); exit(2) }
        let w = args.count >= 4 ? Int(args[2]) ?? 4032 : 4032, h = args.count >= 4 ? Int(args[3]) ?? 3024 : 3024
        guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
        print("device: \(device.name); max buffer \(device.maxBufferLength >> 20) MB")

        var t = now()
        guard let engine = spk_engine_create(args[1], Unmanaged.passUnretained(device as AnyObject).toOpaque()) else {
            fail("engine: " + String(cString: spk_last_error(nil)))
        }
        print(String(format: "engine: %@ (%.0f ms)", String(cString: spk_build_info()), since(t)))
        let caps = object(String(cString: spk_capabilities(engine)))
        let backend = caps["backend"] as? [String: Any] ?? [:]
        print("effects: \(backend["effect_versions"] ?? "?"); math \(backend["math_mode"] ?? "?")")

        // Scene Placement's Fit on a photograph, and nothing else of this file's run.
        for flag in ["--latitude-grid", "--latitude-sweeps"] {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { continue }
            let out = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : nil
            func named(_ name: String) -> String? {
                args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            }
            PlacementGrid.run(engine: engine, device: device, photo: args[i + 1], out: out, grid: flag == "--latitude-grid",
                              film: named("--film"), paper: named("--paper"),
                              lift: named("--max-lift").flatMap(Double.init), percentile: named("--shadow-percentile").flatMap(Double.init))
            spk_engine_destroy(engine)
            print("ok")
            return
        }

        // The frame: integers only, so it is the same bytes wherever it is made.
        guard let frame = device.makeBuffer(length: w * h * 16, options: .storageModeShared) else { fail("no buffer for the frame") }
        let p = frame.contents().bindMemory(to: Float.self, capacity: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var s = UInt32(truncatingIfNeeded: y &* 73_856_093 ^ x &* 19_349_663)
                s ^= s >> 13; s = s &* 1_274_126_177; s ^= s >> 16
                let u = Float(x) / Float(w), v = Float(y) / Float(h)
                let grain = 1 + Float(s & 0xFF) / 2048
                let lamp: Float = (x - w / 3) * (x - w / 3) + (y - h / 3) * (y - h / 3) < (h / 24) * (h / 24) ? 6 : 0
                let i = (y * w + x) * 4
                p[i] = (0.02 + 1.6 * u * u + lamp) * grain
                p[i + 1] = (0.02 + 1.2 * u * v + 0.3 * v + lamp) * grain
                p[i + 2] = (0.02 + 1.4 * v * v + 0.1 * u + lamp * 0.8) * grain
                p[i + 3] = 1
            }
        }

        func open(_ json: String) -> OpaquePointer {
            var image = spk_device_image(buffer: Unmanaged.passUnretained(frame as AnyObject).toOpaque(),
                                         width: UInt32(w), height: UInt32(h), channels: 4)
            var reply: UnsafeMutablePointer<CChar>?
            guard let s = spk_open_device(engine, &image, json, &reply) else { fail("open: " + String(cString: spk_last_error(engine))) }
            if let reply { spk_string_free(reply) }
            return s
        }
        func render(_ session: OpaquePointer, _ tier: String, _ label: String) {
            var out = spk_result()
            let before = footprint()
            let started = now()
            let rc = spk_reprint(session, tier, &out)
            let ms = since(started)
            guard rc == SPK_OK, let pixels = out.rgba16, let texture = out.texture else {
                fail("\(label): " + String(cString: spk_last_error(engine)))
            }
            var hash = SHA256()
            for row in 0..<Int(out.height) {
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: pixels + row * Int(out.row_stride_px) * 4,
                                                                  count: Int(out.width) * 8))
            }
            let sha = hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
            var bands = ""
            var reply: UnsafeMutablePointer<CChar>?
            if spk_progress(session, nil, &reply) == SPK_OK, let reply {
                if let b = object(String(cString: reply))["bands"] as? [String: Any] {
                    bands = " bands \(b["rows"] ?? "?") x \(b["count"] ?? "?")"
                }
                spk_string_free(reply)
            }
            print(String(format: "%@: %d x %d, %.0f ms, sha %@%@, footprint +%.0f MB", label, Int(out.width), Int(out.height), ms,
                         String(sha), bands, Double(max(footprint(), before) - before) / 1_048_576))
            Unmanaged<AnyObject>.fromOpaque(texture).release()
        }

        // The host's cut against the engine's own, and nothing else of this file's run.
        if args.contains("--cut-check") {
            CutCheck.run(engine: engine, device: device, frame: frame, w: w, h: h)
            spk_engine_destroy(engine)
            print("ok")
            return
        }

        // The canvas, as the develop page opens it: the engine's live tier at the app's preview size.
        t = now()
        var s = open(#"{"product_defaults": true, "preview_long_edge": 2400, "grain_active": false, "glare_active": false}"#)
        print(String(format: "open: %d x %d (%.0f ms)", w, h, since(t)))
        render(s, "live", "live, first develop")
        var reply: UnsafeMutablePointer<CChar>?
        _ = spk_set_params(s, #"{"print_exposure": 1.2}"#, &reply)
        if let reply { spk_string_free(reply) }
        render(s, "live", "live, a reprint")

        // Scene Latitude on the open canvas, as the develop page's card asks for it: the first call
        // probes the medium and samples the scene, the second reads both back from the session's
        // cache; then the engine's own suggestion, a placement it accepts and one it refuses.
        // `--latitude-json` prints three of the replies whole.
        func latitude(_ session: OpaquePointer, _ request: String?, _ label: String) -> String {
            var json: UnsafeMutablePointer<CChar>?
            let started = now()
            let rc = spk_scene_latitude(session, request, &json)
            let ms = since(started)
            guard rc == SPK_OK, let json else { fail("\(label): " + String(cString: spk_last_error(engine))) }
            defer { spk_string_free(json) }
            let text = String(cString: json)
            let r = object(text)
            let medium = r["medium"] as? [String: Any] ?? [:], scene = r["scene"] as? [String: Any] ?? [:]
            let suggested = r["suggested"] as? [String: Any] ?? [:], fit = r["fit"] as? [String: Any] ?? [:]
            let histogram = scene["histogram"] as? [String: Any] ?? [:]
            func n(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? .nan }
            let codes = (fit["issues"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
            let sha = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            print(String(format: "%@: held %.3f to %.3f (%.3f stops); scene p0.1 %.3f, p50 %.3f, p99.9 %.3f; suggested %.3f / %.3f; fit %@%@; %d bins%@; %.1f ms, sha %@",
                         label, n(medium, "shadow_ev"), n(medium, "highlight_ev"), n(medium, "latitude_stops"),
                         n(scene, "p0_1"), n(scene, "p50"), n(scene, "p99_9"),
                         n(suggested, "highlight_pull_back"), n(suggested, "shadow_pull_back"),
                         (fit["valid"] as? Bool) == true ? "valid" : "refused", codes.isEmpty ? "" : " (" + codes.joined(separator: ", ") + ")",
                         (histogram["fractions"] as? [Any])?.count ?? 0, histogram["placed_fractions"] != nil ? ", placed" : "",
                         ms, String(sha)))
            return text
        }
        let measured = latitude(s, #"{"highlight_pull_back": 0, "shadow_pull_back": 0}"#, "latitude, first")
        _ = latitude(s, #"{"highlight_pull_back": 0, "shadow_pull_back": 0}"#, "latitude, again")
        _ = latitude(s, nil, "latitude, the suggestion")
        let placed = latitude(s, #"{"highlight_pull_back": 1.5, "shadow_pull_back": 0}"#, "latitude, highlights pulled back 1.5")
        let refused = latitude(s, #"{"highlight_pull_back": 0.25, "shadow_pull_back": 0}"#, "latitude, pulled back too little")
        if args.contains("--latitude-json") {
            // `tools/engine_replies/scene_latitude_*.json`, which the app's own checks read, are these three lines.
            print("json reply: " + measured)
            print("json placed: " + placed)
            print("json refused: " + refused)
        }
        spk_session_release(s)

        // Full size, whole: the engine renders a frame whole. Grain and glare off: they are
        // stochastic (AGENTS.md trap 5).
        s = open(#"{"product_defaults": true, "grain_active": false, "glare_active": false}"#)
        render(s, "full", "full, whole")
        spk_session_release(s)

        let report = object(String(cString: spk_memory_report(engine)))
        print("the engine holds after release: \(((report["total_bytes"] as? NSNumber)?.doubleValue ?? -1) / 1_048_576) MB")
        spk_engine_destroy(engine)
        print("ok")
    }

    static func fail(_ why: String) -> Never { print("FAIL " + why); exit(1) }
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func since(_ t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

/// Scene Placement's Fit on a real frame, as the engine says it.
///
/// The frame is decoded the way the app decodes one for its canvas (`FrameDecoder.swift`, in
/// short: a RAW with a linear look and scaled after its decode, anything else reduced by ImageIO;
/// 2,400 px, linear ProPhoto) and opened with the wire the develop page opens a new frame with
/// (`FilmParams.default`, compiled in from the app's own sources). Then one JSON object a line:
///
/// - `frame`: which photograph, how it was decoded, the stocks, the engine's build;
/// - `measured`, one per setting: the engine's whole reply with both sides off — what a solve in
///   the app starts from — and the `settings` it was asked with. The five are the desktop's own
///   test's (`ScenePlacementTests`): roll-off 2, 1 and 3, a lift bound of 4, 8 and 12, the shadow
///   fitted to P0.1 and to P1;
/// - `fit`, the grid: the engine's fit of one pair of pull-backs, as it came, under setting
///   `config`. The pairs sit on both sides of every refusal: off, half the minimum, a hair over
///   it, 0.3 and 1.5 stops over it, just under and at the lift bound, 7.9 and 12 stops;
/// - `placed`: an accepted fit with the frame's histogram after its curve (`placed_fractions`);
/// - `sweep`: the engine's verdict on every hundredth of the rulers' 0…8 on one side, the other
///   side held at `other`, as runs of hundredths — `code` empty where the Fit takes the value.
///   What a ruler may land on, and why not elsewhere.
enum PlacementGrid {
    /// The rulers' track, in hundredths of a stop.
    static let track = 800

    /// `lift` and `percentile` are for the sweeps alone: what the rulers would be offered under another lift
    /// bound, or with the shadow side fitted to P1 — a question, not what the app sends (4 and P0.1).
    static func run(engine: OpaquePointer, device: MTLDevice, photo: String, out: String?, grid: Bool,
                    film: String?, paper: String?, lift: Double? = nil, percentile: Double? = nil) {
        let url = URL(fileURLWithPath: photo)
        let frame = decode(url, device: device, longEdge: 2400)
        print("frame: \(url.lastPathComponent) by \(frame.how), \(frame.w) x \(frame.h)")

        // A new frame's wire, as `FrameEdit.engineWire` makes it for the canvas (its geometry is the engine's default).
        var wire = FilmParams.default.fullDelta
        wire["product_defaults"] = .bool(true)
        wire["preview_long_edge"] = .double(2400)
        wire["overscan_active"] = .bool(false)
        wire["date_imprint_active"] = .bool(false)
        if let film { wire["film_stock"] = .string(film) }
        if let paper { wire["print_stock"] = .string(paper) }
        guard let opening = try? JSONEncoder().encode(wire), let openingText = String(data: opening, encoding: .utf8) else {
            EngineSmoke.fail("the wire did not encode")
        }
        var image = spk_device_image(buffer: Unmanaged.passUnretained(frame.buffer as AnyObject).toOpaque(),
                                     width: UInt32(frame.w), height: UInt32(frame.h), channels: 4)
        var opened: UnsafeMutablePointer<CChar>?
        guard let session = spk_open_device(engine, &image, openingText, &opened) else {
            EngineSmoke.fail("open: " + String(cString: spk_last_error(engine)))
        }
        if let opened { spk_string_free(opened) }
        defer { spk_session_release(session) }
        // The page's first develop: the Fit is asked of a session that has rendered, as in the app.
        var result = spk_result()
        guard spk_reprint(session, "live", &result) == SPK_OK, let texture = result.texture else {
            EngineSmoke.fail("develop: " + String(cString: spk_last_error(engine)))
        }
        Unmanaged<AnyObject>.fromOpaque(texture).release()

        func ask(_ request: [String: Any]) -> [String: Any] {
            var text: UnsafeMutablePointer<CChar>?
            guard spk_scene_latitude(session, line(request), &text) == SPK_OK, let text else {
                EngineSmoke.fail("scene latitude: " + String(cString: spk_last_error(engine)))
            }
            defer { spk_string_free(text) }
            return EngineSmoke.object(String(cString: text))
        }
        func number(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? .nan }
        func part(_ d: [String: Any], _ k: String) -> [String: Any] { d[k] as? [String: Any] ?? [:] }
        func valid(_ reply: [String: Any]) -> Bool { (part(reply, "fit")["valid"] as? Bool) == true }
        func refusal(_ reply: [String: Any]) -> (code: String, side: String) {
            let first = (part(reply, "fit")["issues"] as? [[String: Any]])?.first
            return (first?["code"] as? String ?? "", first?["side"] as? String ?? "")
        }

        var lines = [line(["frame": ["file": url.lastPathComponent, "decoded": frame.how, "width": frame.w, "height": frame.h,
                                     "film": wire["film_stock"]?.stringValue ?? "", "paper": wire["print_stock"]?.stringValue ?? "",
                                     "engine": String(cString: spk_build_info()),
                                     "made_by": "tools/engine_smoke.sh mac " + (grid ? "--latitude-grid" : "--latitude-sweeps")]])]

        let settings: [(rolloff: Double, lift: Double, percentile: Double)] =
            grid ? [(2, 4, 0.1), (2, 8, 0.1), (2, 4, 1.0), (1, 8, 1.0), (3, 12, 0.1)] : [(2, lift ?? 4, percentile ?? 0.1)]
        var fits = 0, taken = 0, placedLines = 0
        var codes = Set<String>()
        for (k, setting) in settings.enumerated() {
            let base: [String: Any] = ["rolloff": setting.rolloff, "max_lift": setting.lift, "norm": "power",
                                       "shadow_percentile": setting.percentile, "highlight_percentile": 99.9]
            func fit(_ h: Double, _ s: Double) -> [String: Any] {
                ask(base.merging(["highlight_pull_back": h, "shadow_pull_back": s]) { _, new in new })
            }
            let measured = fit(0, 0)
            lines.append(line(["measured": measured, "settings": base, "config": k]))
            let top = part(part(measured, "fit"), "highlight"), bottom = part(part(measured, "fit"), "shadow")
            let minH = number(top, "minimum_pull_back"), minS = number(bottom, "minimum_pull_back")
            if k == 0 {
                let medium = part(measured, "medium"), scene = part(measured, "scene")
                print(String(format: "latitude: held %.2f to %.2f; the scene %.2f to %.2f; the least pull-back: highlight %.2f, shadow %.2f",
                             number(medium, "shadow_ev"), number(medium, "highlight_ev"), number(scene, "p0_1"), number(scene, "p99_9"), minH, minS))
            }

            if grid {
                let hs = [0, minH * 0.5, minH + 0.004, minH + 0.3, minH + 1.5, 7.9, 12].map { max($0, 0) }
                let ss = [0, minS * 0.5, minS + 0.004, minS + 0.3, minS + 1.5, setting.lift - 0.01, setting.lift, 7.9].map { max($0, 0) }
                for h in hs {
                    for s in ss {
                        let reply = fit(h, s)
                        lines.append(line(["fit": part(reply, "fit"), "config": k]))
                        fits += 1
                        if valid(reply) { taken += 1 } else { codes.insert(refusal(reply).code) }
                    }
                }
            }

            // Accepted placements with their placed histogram: each side alone, and the two together.
            let over = max(minH, 0) + 1.5, lifted = max(minS, 0) + 0.6
            for (h, s) in [(over, 0), (0, lifted), (over, lifted)] {
                let reply = fit(h, s)
                guard valid(reply) else { continue }
                let histogram = part(part(reply, "scene"), "histogram")
                lines.append(line(["placed": ["fit": part(reply, "fit"), "placed_fractions": histogram["placed_fractions"] ?? []], "config": k]))
                placedLines += 1
            }

            // The rulers, under the app's own settings: every hundredth of each side, alone and beside the other.
            guard k == 0 else { continue }
            func sweep(_ side: String, other: Double) -> (line: [String: Any], takes: ClosedRange<Int>?) {
                var runs: [(from: Int, to: Int, code: String, side: String)] = []
                for x in 1...track {
                    let v = Double(x) / 100
                    let reply = side == "highlight" ? fit(v, other) : fit(other, v)
                    let why = valid(reply) ? (code: "", side: "") : refusal(reply)
                    if let last = runs.last, last.code == why.code, last.side == why.side {
                        runs[runs.count - 1].to = x
                    } else {
                        runs.append((x, x, why.code, why.side))
                    }
                }
                let takes = runs.filter { $0.code.isEmpty }
                let said = takes.isEmpty ? "nothing" : takes.map { String(format: "%.2f to %.2f", Double($0.from) / 100, Double($0.to) / 100) }.joined(separator: ", ")
                let around = runs.filter { !$0.code.isEmpty }.map { String(format: "%.2f-%.2f %@", Double($0.from) / 100, Double($0.to) / 100, $0.code) }
                print("the Fit takes, \(side) with the other side at \(String(format: "%.2f", other)): \(said)  [refused: \(around.joined(separator: "; "))]")
                return (["sweep": side, "other": other, "config": k,
                         "runs": runs.map { ["from": $0.from, "to": $0.to, "code": $0.code, "side": $0.side] as [String: Any] }],
                        takes.first.map { $0.from...$0.to })
            }
            let alone = (highlight: sweep("highlight", other: 0), shadow: sweep("shadow", other: 0))
            lines.append(line(alone.highlight.line))
            lines.append(line(alone.shadow.line))
            // Beside the other side a quarter stop into what the Fit takes of it, where it takes anything: far
            // enough in to be a placement, near enough to its edge that the two curves need not cross.
            if let run = alone.shadow.takes { lines.append(line(sweep("highlight", other: Double(min(run.lowerBound + 25, run.upperBound)) / 100).line)) }
            if let run = alone.highlight.takes { lines.append(line(sweep("shadow", other: Double(min(run.lowerBound + 25, run.upperBound)) / 100).line)) }
        }
        if grid { print("grid: \(fits) fits, \(taken) taken; refused for \(codes.sorted().joined(separator: ", "))") }
        print("placed histograms: \(placedLines)")
        if let out {
            do {
                try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
                print("wrote \(lines.count) lines to \(out)")
            } catch {
                EngineSmoke.fail("could not write \(out): \(error)")
            }
        }
    }

    /// One JSON object on one line, its keys in order.
    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { EngineSmoke.fail("a line did not encode") }
        return text
    }

    /// `FrameDecoder.decode`, in short: the same decoder settings, the same scale, the same space.
    static func decode(_ url: URL, device: MTLDevice, longEdge: Int) -> (buffer: MTLBuffer, w: Int, h: Int, how: String) {
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .highQualityDownsample: true])
        let d50: [CGFloat] = [0.9642, 1.0, 0.8249], black: [CGFloat] = [0, 0, 0], gamma: [CGFloat] = [1, 1, 1]
        let m: [CGFloat] = [0.7976749, 0.2880402, 0.0, 0.1351917, 0.7118741, 0.0, 0.0313534, 0.0000857, 0.8252100]
        let linearProPhoto = CGColorSpace(calibratedRGBWhitePoint: d50, blackPoint: black, gamma: gamma, matrix: m)!
        var image: CIImage?
        var how = ""
        let raws: Set<String> = ["dng", "arw", "cr2", "cr3", "nef", "raf", "rw2", "orf"]
        if raws.contains(url.pathExtension.lowercased()), let filter = CIRAWFilter(imageURL: url) {
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            filter.isGamutMappingEnabled = false
            filter.localToneMapAmount = 0
            filter.extendedDynamicRangeAmount = 0
            filter.isLensCorrectionEnabled = false
            how = "RAW " + filter.decoderVersion.rawValue
            image = filter.outputImage.map { scaled($0, toLongEdge: longEdge) }
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: longEdge,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true]
            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                image = CIImage(cgImage: small)
                how = "ImageIO"
            }
        }
        guard let image else { EngineSmoke.fail("could not decode \(url.path)") }
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0, let buffer = device.makeBuffer(length: w * h * 16, options: .storageModeShared) else {
            EngineSmoke.fail("no buffer for \(url.lastPathComponent)")
        }
        // The bitmap's first row is the picture's top.
        context.render(image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y)),
                       toBitmap: buffer.contents(), rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBAf, colorSpace: linearProPhoto)
        return (buffer, w, h, how)
    }

    private static func scaled(_ image: CIImage, toLongEdge longEdge: Int) -> CIImage {
        let whole = image.extent.integral
        let long = max(whole.width, whole.height)
        guard long > CGFloat(longEdge), let scale = CIFilter(name: "CILanczosScaleTransform") else { return image }
        let k = CGFloat(longEdge) / long
        scale.setValue(image.transformed(by: .init(translationX: -whole.origin.x, y: -whole.origin.y)).clampedToExtent(),
                       forKey: kCIInputImageKey)
        scale.setValue(k, forKey: kCIInputScaleKey)
        scale.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let out = scale.outputImage else { return image }
        return out.cropped(to: CGRect(x: 0, y: 0, width: (whole.width * k).rounded(), height: (whole.height * k).rounded()))
    }
}

// MARK: - the host's cut against the engine's own

/// **An export is cut by the host** (`Sources/Engine/ExportPlan.swift`): the frame handed over is
/// already cropped and turned, the wire's own cut is none, and `film_format_mm` goes down with the
/// cut so the film keeps its micrometres a pixel. That is only right if the engine then makes the
/// picture it makes when it cuts for itself. This renders both at full size from the same frame —
/// the whole frame with the cut on the wire, and the cut copied out by hand with no cut on the wire
/// — with the grain off (its draws are keyed on a pixel's index in the frame, so two frames of
/// different size never draw alike), and says how far apart the two pictures are. A third render,
/// the cut handed over with the film's size left alone, shows what the correction is worth.
///
///     tools/engine_smoke.sh mac 2016 1512 --cut-check
enum CutCheck {
    struct Picture { var w = 0, h = 0; var px: [UInt16] = [] }

    static func run(engine: OpaquePointer, device: MTLDevice, frame: MTLBuffer, w: Int, h: Int) {
        // Cuts in whole pixels, so the two cuts are of the same samples.
        let cases: [(name: String, x: Int, y: Int, cw: Int, ch: Int, turns: Int)] = [
            ("the middle half", w / 4, h / 4, w / 2, h / 2, 0),
            ("an upright third from the left", w / 8, 0, w / 3, h, 0),
            ("a corner, turned a quarter", w / 2, h / 2, w / 2 - 16, h / 2 - 16, 1),
            ("the whole frame, turned three quarters", 0, 0, w, h, 3),
        ]
        let base = #""product_defaults": true, "grain_active": false, "glare_active": false"#
        let source = frame.contents().bindMemory(to: Float.self, capacity: w * h * 4)
        var worst = 0.0
        for c in cases {
            let whole = "{\(base), \"geometry_crop_x\": \(Double(c.x) / Double(w)), \"geometry_crop_y\": \(Double(c.y) / Double(h)), "
                + "\"geometry_crop_w\": \(Double(c.cw) / Double(w)), \"geometry_crop_h\": \(Double(c.ch) / Double(h)), "
                + "\"geometry_quarter_turns\": \(c.turns)}"
            let byEngine = render(engine, device: device, buffer: frame, w: w, h: h, wire: whole)

            // The same cut by hand: the crop, then its quarter turns clockwise.
            let (cw, ch) = c.turns % 2 == 0 ? (c.cw, c.ch) : (c.ch, c.cw)
            guard let cut = device.makeBuffer(length: cw * ch * 16, options: .storageModeShared) else { EngineSmoke.fail("no buffer for the cut") }
            let out = cut.contents().bindMemory(to: Float.self, capacity: cw * ch * 4)
            for y in 0..<ch {
                for x in 0..<cw {
                    // Where this pixel of the turned cut sits in the crop.
                    let (sx, sy): (Int, Int)
                    switch c.turns % 4 {
                    case 1: (sx, sy) = (y, c.ch - 1 - x)
                    case 2: (sx, sy) = (c.cw - 1 - x, c.ch - 1 - y)
                    case 3: (sx, sy) = (c.cw - 1 - y, x)
                    default: (sx, sy) = (x, y)
                    }
                    let from = ((c.y + sy) * w + c.x + sx) * 4, to = (y * cw + x) * 4
                    for k in 0..<4 { out[to + k] = source[from + k] }
                }
            }
            let mm = 35.0 * Double(max(cw, ch)) / Double(max(w, h))
            let byHost = render(engine, device: device, buffer: cut, w: cw, h: ch, wire: "{\(base), \"film_format_mm\": \(mm)}")
            let unscaled = render(engine, device: device, buffer: cut, w: cw, h: ch, wire: "{\(base)}")
            let a = apart(byEngine, byHost), b = apart(byEngine, unscaled)
            worst = max(worst, a.mean)
            print(String(format: "%@: %d x %d by the engine, %d x %d by the host; apart by a mean of %.3f and at most %.0f of 65,535 (film %.2f mm); with the film's size left at 35 mm, %.3f and %.0f",
                         c.name, byEngine.w, byEngine.h, byHost.w, byHost.h, a.mean, a.most, mm, b.mean, b.most))
        }
        print(String(format: "the host's cut is the engine's to a mean of %.3f of 65,535 at worst", worst))
    }

    static func render(_ engine: OpaquePointer, device: MTLDevice, buffer: MTLBuffer, w: Int, h: Int, wire: String) -> Picture {
        var image = spk_device_image(buffer: Unmanaged.passUnretained(buffer as AnyObject).toOpaque(),
                                     width: UInt32(w), height: UInt32(h), channels: 4)
        var reply: UnsafeMutablePointer<CChar>?
        guard let session = spk_open_device(engine, &image, wire, &reply) else { EngineSmoke.fail("open: " + String(cString: spk_last_error(engine))) }
        if let reply { spk_string_free(reply) }
        defer { spk_session_release(session) }
        var out = spk_result()
        guard spk_reprint(session, "full", &out) == SPK_OK, let pixels = out.rgba16, let texture = out.texture else {
            EngineSmoke.fail("render: " + String(cString: spk_last_error(engine)))
        }
        defer { Unmanaged<AnyObject>.fromOpaque(texture).release() }
        var p = Picture(w: Int(out.width), h: Int(out.height))
        p.px.reserveCapacity(p.w * p.h * 3)
        for row in 0..<p.h {
            let line = pixels + row * Int(out.row_stride_px) * 4
            for x in 0..<p.w { p.px.append(line[x * 4]); p.px.append(line[x * 4 + 1]); p.px.append(line[x * 4 + 2]) }
        }
        return p
    }

    static func apart(_ a: Picture, _ b: Picture) -> (mean: Double, most: Double) {
        guard a.w == b.w, a.h == b.h, !a.px.isEmpty else { return (.infinity, .infinity) }
        var sum = 0.0, most = 0.0
        for i in 0..<a.px.count {
            let d = abs(Double(a.px[i]) - Double(b.px[i]))
            sum += d
            most = max(most, d)
        }
        return (sum / Double(a.px.count), most)
    }
}
