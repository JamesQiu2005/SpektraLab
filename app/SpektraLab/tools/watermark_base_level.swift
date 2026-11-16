//  watermark_base_level.swift — where a 底片 mark's white has to be laid in the scene for it to develop near paper
//  white (PRD-8 §4.3, RFC-067 §4.2, W7), measured through the engine itself on this Mac. Built and run by
//  `tools/watermark_base_level.sh mac`, against `engine/build` (`engine/build.sh dylib`, then `metallib`) and the app's
//  own engine resources (`build/engine-macosx/EngineResources`, `tools/build_engine_mac.sh`).
//
//  A white laid at +2.5 EV over the frame's middle grey develops to about 0.82, not 1.0. This asks the engine's
//  chain why, pair by pair: a frame of the engine's middle grey (0.184, neutral,
//  linear ProPhoto: what `FrameDecoder` hands over) with a row of neutral squares at +0 … +8 EV over it, opened with the
//  develop page's wire for a new frame (`FilmParams.default` and the product's defaults, grain and glare off so a square
//  reads as its level), developed at the live tier, and each square's centre read back. A value is the engine's result
//  (ProPhoto, ROMM-encoded) taken to what a page shows of a neutral: the sRGB/Display P3 curve over its luminance. Paper
//  white is the brightest the pair prints (the +8 EV square's), and "near" is within 3 % of it.
//
//  Then the rule's two other halves, measured the same way:
//  - **exposure**: with Film Exposure at −2 … +2 and the scene under it at 2^−E (a photograph corrected), the mark laid by
//    `WatermarkComposite.baseWhite` develops to the same value;
//  - **the meter**: with the engine's meter on, what it reads of the frame with and without a mark that covers a tenth
//    of it — the engine's own meter sees the source it is handed.
//
//  Prints a table; exits 1 only where the engine cannot be opened. Its numbers are recorded beside the constant
//  (`WatermarkComposite.baseWhiteEV`) and in that commit's message.

import Foundation
import Metal
import SwiftUI

extension Color { init(hexString: String) { self = .gray } }

@main
enum WatermarkBaseLevel {
    static let midGrey: Float = 0.184
    static let w = 1800, h = 600
    static let steps: [Double] = [0, 1, 2, 2.5, 3, 3.25, 3.5, 3.75, 4, 4.5, 5, 6, 8]

    struct Pair { var name: String; var film: String; var paper: String; var extra: [String: ParamValue] }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2, let device = MTLCreateSystemDefaultDevice() else { fail("usage: watermark_base_level <resources> [cube]") }
        guard let engine = spk_engine_create(args[1], Unmanaged.passUnretained(device as AnyObject).toOpaque()) else {
            fail("engine: " + String(cString: spk_last_error(nil)))
        }
        defer { spk_engine_destroy(engine) }
        let cube = args.count >= 3 ? Cube(path: args[2]) : nil
        print("engine: \(String(cString: spk_build_info()))")

        let silver: [String: ParamValue] = ["extended_dynamic_range": .bool(false), "grain_sublayers_active": .bool(false),
                                            "c_filter_neutral": .double(0), "m_filter_neutral": .double(0), "y_filter_neutral": .double(68)]
        let pairs = [
            Pair(name: "Portra 400 / Portra Endura (the default pair)", film: "kodak_portra_400", paper: "kodak_portra_endura", extra: [:]),
            Pair(name: "Portra 400 / Supra Endura (FilmParams.default)", film: "kodak_portra_400", paper: "kodak_supra_endura", extra: [:]),
            Pair(name: "Ektachrome 100, a slide (scanned)", film: "kodak_ektachrome_100", paper: "kodak_portra_endura", extra: ["scan_film": .bool(true)]),
            Pair(name: "Tri-X 400 / Multigrade IV RC (black and white)", film: "kodak_tri_x_400", paper: "ilford_multigrade_iv_rc", extra: silver),
            Pair(name: "Portra 400, the Digital Intermediate", film: "kodak_portra_400", paper: "kodak_portra_endura",
                 extra: ["digital_intermediate": .bool(true)]),
        ]

        // The frame: middle grey, and a square at each step, laid out across it.
        let side = 110, gap = (w - steps.count * side) / (steps.count + 1)
        func squareX(_ i: Int) -> Int { gap + i * (side + gap) }
        let y0 = (h - side) / 2

        for pair in pairs {
            var wire = FilmParams.default.fullDelta
            wire["product_defaults"] = .bool(true)
            wire["preview_long_edge"] = .double(Double(w))
            wire["overscan_active"] = .bool(false)
            wire["date_imprint_active"] = .bool(false)
            wire["grain_active"] = .bool(false)
            wire["glare_active"] = .bool(false)
            wire["film_stock"] = .string(pair.film)
            wire["print_stock"] = .string(pair.paper)
            for (k, v) in pair.extra { wire[k] = v }
            let isDI = pair.extra["digital_intermediate"] == .bool(true)
            guard !isDI || cube != nil else { print("\(pair.name): no DI view (.cube) given, skipped"); continue }

            let frame = makeFrame(device) { x, y in
                for (i, ev) in steps.enumerated() where x >= squareX(i) && x < squareX(i) + side && y >= y0 && y < y0 + side {
                    return midGrey * Float(pow(2, ev))
                }
                return midGrey
            }
            guard let values = develop(engine, frame, wire: wire, read: steps.indices.map { (squareX($0) + side / 2, y0 + side / 2) },
                                       view: isDI ? cube : nil) else { continue }
            let grey = develop(engine, makeFrame(device) { _, _ in midGrey }, wire: wire, read: [(w / 2, h / 2)], view: isDI ? cube : nil)?.first ?? .nan
            let white = values.last!
            print("\n\(pair.name)\n  middle grey develops to \(f(grey)); paper white (+8 EV) \(f(white))")
            var reached: Double?
            for (ev, v) in zip(steps, values) {
                let share = v / white
                if reached == nil, share >= 0.97 { reached = ev }
                print(String(format: "  +%.2f EV  %@   %5.1f %% of paper white", ev, f(v), share * 100))
            }
            print("  the least step within 3 % of paper white: " + (reached.map { String(format: "+%.2f EV", $0) } ?? "none"))
        }

        // The exposure: a photograph under- or over-exposed and corrected by Film Exposure, the mark laid by the rule.
        print("\nFilm Exposure under the mark (Portra 400 / Portra Endura; the scene at 2^-E, the mark at baseWhite(E)):")
        var wire = FilmParams.default.fullDelta
        wire["product_defaults"] = .bool(true)
        wire["preview_long_edge"] = .double(Double(w))
        wire["overscan_active"] = .bool(false); wire["date_imprint_active"] = .bool(false)
        wire["grain_active"] = .bool(false); wire["glare_active"] = .bool(false)
        wire["print_stock"] = .string("kodak_portra_endura")
        let probe = [3.0, 3.5, 4.0]
        for e in [-2.0, -1, 0, 1, 2] {
            var asked = wire
            asked["exposure_compensation_ev"] = .double(e)
            let k = Float(pow(2, -e))
            let frame = makeFrame(device) { x, y in
                for (i, ev) in probe.enumerated() where x >= squareX(i) && x < squareX(i) + side && y >= y0 && y < y0 + side {
                    return midGrey * Float(pow(2, ev)) * k
                }
                return midGrey * k
            }
            let reads = develop(engine, frame, wire: asked, read: probe.indices.map { (squareX($0) + side / 2, y0 + side / 2) } + [(w - 20, 20)], view: nil) ?? []
            print(String(format: "  E %+.0f: grey %@, mark at +3 %@, +3.5 %@, +4 %@", e, f(reads.last ?? .nan), f(reads[0]), f(reads[1]), f(reads[2])))
        }

        // The meter: what the engine reads of a frame with and without a bright mark over a tenth of it.
        print("\nThe engine's meter (auto_exposure on, balanced), on a frame with and without a mark over a tenth of it:")
        var metered = wire
        metered["auto_exposure"] = .bool(true)
        metered["auto_exposure_method"] = .string("balanced")
        for level in [2.5, 3.5] {
            let plain = makeFrame(device) { x, y in midGrey * Float(0.6 + 0.8 * Double(x) / Double(w)) }
            let marked = makeFrame(device) { x, y in
                let inMark = x > w * 6 / 10 && x < w * 9 / 10 && y > h * 3 / 10 && y < h * 6 / 10   // 0.3 × 0.3 = 9 %
                return inMark ? midGrey * Float(pow(2, level)) : midGrey * Float(0.6 + 0.8 * Double(x) / Double(w))
            }
            let a = meter(engine, plain, wire: metered), b = meter(engine, marked, wire: metered)
            print(String(format: "  a mark at +%.1f EV: the meter reads %+.3f EV without it, %+.3f EV with it (%+.3f)", level, a, b, b - a))
        }
    }

    // MARK: the engine

    static func makeFrame(_ device: MTLDevice, _ value: (Int, Int) -> Float) -> MTLBuffer {
        guard let b = device.makeBuffer(length: w * h * 16, options: .storageModeShared) else { fail("no buffer") }
        let p = b.contents().bindMemory(to: Float.self, capacity: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = value(x, y), i = (y * w + x) * 4
                p[i] = v; p[i + 1] = v; p[i + 2] = v; p[i + 3] = 1
            }
        }
        return b
    }

    static func open(_ engine: OpaquePointer, _ frame: MTLBuffer, wire: [String: ParamValue]) -> OpaquePointer? {
        guard let data = try? JSONEncoder().encode(wire), let json = String(data: data, encoding: .utf8) else { return nil }
        var image = spk_device_image(buffer: Unmanaged.passUnretained(frame as AnyObject).toOpaque(),
                                     width: UInt32(w), height: UInt32(h), channels: 4)
        var reply: UnsafeMutablePointer<CChar>?
        let s = spk_open_device(engine, &image, json, &reply)
        if let reply { spk_string_free(reply) }
        if s == nil { print("open refused: " + String(cString: spk_last_error(engine))) }
        return s
    }

    /// The developed value (a page's encoded neutral, 0…1) at each point: an 11 × 11 mean.
    static func develop(_ engine: OpaquePointer, _ frame: MTLBuffer, wire: [String: ParamValue], read: [(Int, Int)],
                        view: Cube?) -> [Double]? {
        guard let s = open(engine, frame, wire: wire) else { return nil }
        defer { spk_session_release(s) }
        var out = spk_result()
        guard spk_render(s, "live", &out) == SPK_OK, let px = out.rgba16, let texture = out.texture else {
            print("render refused: " + String(cString: spk_last_error(engine))); return nil
        }
        defer { Unmanaged<AnyObject>.fromOpaque(texture).release() }
        let ow = Int(out.width), oh = Int(out.height), stride = Int(out.row_stride_px)
        let sx = Double(ow) / Double(w), sy = Double(oh) / Double(h)
        return read.map { point in
            var sum = SIMD3<Double>(0, 0, 0), n = 0.0
            let cx = Int(Double(point.0) * sx), cy = Int(Double(point.1) * sy)
            for y in max(0, cy - 5)...min(oh - 1, cy + 5) {
                for x in max(0, cx - 5)...min(ow - 1, cx + 5) {
                    let p = px + y * stride * 4 + x * 4
                    sum += SIMD3(Double(p[0]), Double(p[1]), Double(p[2])) / 65535
                    n += 1
                }
            }
            var rgb = sum / n
            if let view { rgb = view.sample(rgb) }
            return shown(rgb)
        }
    }

    static func meter(_ engine: OpaquePointer, _ frame: MTLBuffer, wire: [String: ParamValue]) -> Double {
        guard let s = open(engine, frame, wire: wire) else { return .nan }
        defer { spk_session_release(s) }
        var reply: UnsafeMutablePointer<CChar>?
        guard spk_solve(s, "exposure", &reply) == SPK_OK, let reply else { return .nan }
        defer { spk_string_free(reply) }
        let o = (try? JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8))) as? [String: Any]
        return ((o?["solved_params"] as? [String: Any])?["exposure_compensation_ev"] as? NSNumber)?.doubleValue ?? .nan
    }

    // MARK: the numbers

    /// ROMM-encoded ProPhoto → what a page shows of it: the luminance (ProPhoto's Y row), through the sRGB curve (the
    /// Display P3 curve is the same). A neutral is neutral in either space.
    static func shown(_ v: SIMD3<Double>) -> Double {
        func lin(_ c: Double) -> Double { c < 16.0 / 512 ? c / 16 : pow(c, 1.8) }
        let y = 0.2880402 * lin(v.x) + 0.7118741 * lin(v.y) + 0.0000857 * lin(v.z)
        let e = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
        return min(max(e, 0), 1.2)
    }

    static func f(_ v: Double) -> String { String(format: "%.3f", v) }

    static func fail(_ why: String) -> Never { print("FAIL " + why); exit(1) }

    /// The DI view (`Resources/DIView-Cineon-to-ProPhoto.cube`), trilinear: Cineon log in, ROMM-encoded ProPhoto out.
    struct Cube {
        let n: Int
        let table: [SIMD3<Double>]
        init?(path: String) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            var n = 0, rows: [SIMD3<Double>] = []
            for line in text.split(separator: "\n") {
                if line.hasPrefix("LUT_3D_SIZE") { n = Int(line.split(separator: " ").last!) ?? 0; continue }
                let parts = line.split(separator: " ").compactMap { Double($0) }
                if parts.count == 3, !line.hasPrefix("DOMAIN") { rows.append(SIMD3(parts[0], parts[1], parts[2])) }
            }
            guard n > 1, rows.count == n * n * n else { return nil }
            self.n = n; table = rows
        }
        func sample(_ c: SIMD3<Double>) -> SIMD3<Double> {
            func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> { table[(b * n + g) * n + r] }
            let s = (c * Double(n - 1)).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: Double(n - 1)))
            let i = SIMD3<Int>(Int(s.x), Int(s.y), Int(s.z)).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: n - 2))
            let t = s - SIMD3(Double(i.x), Double(i.y), Double(i.z))
            var out = SIMD3<Double>(0, 0, 0)
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let wgt = (dx == 1 ? t.x : 1 - t.x) * (dy == 1 ? t.y : 1 - t.y) * (dz == 1 ? t.z : 1 - t.z)
                out += at(i.x + dx, i.y + dy, i.z + dz) * wgt
            } } }
            return out
        }
    }
}
