//  watermark_base_selftest.swift — 水印's 底片 pass (`Sources/Engine/WatermarkBase.swift`), on this Mac: the rules
//  it holds. Built and run by
//  `tools/watermark_base_selftest.sh` (`gate.py selftest --only watermark_base_selftest`), which also builds **2.4.0's
//  own stamp** (`DevelopStamp` as release 8e5ce17b wrote it, renamed `DevelopStamp240`) beside today's.
//
//  - **The stamp**: every edit without a 底片 mark — none, 成片 marks only, a 底片 mark switched off or clear, a 底片
//    mark with the film off, a pair's or a double's — is stamped exactly as 2.4.0 stamped it, on a spread of wires,
//    decodes, cuts, turns, pieces and lenses: every kept develop of a 2.4.0 library stays valid. A 底片 mark is in the
//    stamp: moved, resized, faded, its file replaced — another stamp; a 成片 mark moved beside it — the same.
//  - **The level**: the mark's white is 0.184 · 2^(K − E) whatever E is (Film Exposure, and the meter's reading where
//    it is on); K is +3.0 EV, +4.5 under the Digital Intermediate (the measurements: WatermarkBase.swift's header); a
//    metered develop is opened with the meter off at Film Exposure plus the reading; the source's word follows what
//    the white is laid by.
//  - **The geometry**: the 底片 canvas on the decode (`basePlacing`), held against an independent drawing — the mark
//    laid on the picture the engine makes, and the same laid on the decode then carried through the engine's own cut
//    (its quarter turns and flips by index arithmetic here, not `Geometry`) and the host's turn (vImage, as
//    `EngineHost.turned` turns) — for the engine's cut and the host's (a film edge's, an export's), every quarter turn
//    after; a 600 px decode and a 3,000 px one place it at the same place and relative size. Lens correction is inside
//    the decode (`FrameDecoder`), before the pass: the pass reads nothing of it, so the same decode size places the same.
//  - **The pass**: an opaque white texel is exactly `white` in ProPhoto (sRGB white is ProPhoto white), 40 % opacity is
//    40 % of the way, nothing off the marks' boxes moves, the fourth channel never; the paths that carry marks.
//  - **The price**: none for an edit without; a kept decode's copy on the page's and a card's; no second source on a
//    full-size job's.
//
//  `--self-test` runs the same checks with one rule broken at a time and requires each run to fail (AGENTS.md: a check
//  that cannot fire is not a check).

import Accelerate
import CoreGraphics
import Foundation
import ImageIO

struct Rules {
    var name = "the app's"
    /// The stamp's word for an edit's 底片 marks.
    var word: (FrameEdit, Bool) -> String = { WatermarkComposite.Base.word($0, isComposite: $1) }
    /// The stamp.
    var stamp: (_ wire: [String: ParamValue], _ cut: Geometry?, _ turns: Int, _ decode: DecodeSettings, _ raw: Bool, _ edge: Int,
                _ piece: String?, _ lens: String, _ base: String) -> String = { w, c, t, d, r, e, p, l, b in
        DevelopStamp.of(wire: w, cut: c, turns: t, decode: d, isRAW: r, longEdge: e, engine: "engine 1|abc", piece: p, lens: l, base: b)
    }
    var white: (Double, Double) -> Double = { WatermarkComposite.baseWhite(exposureEV: $0, whiteEV: $1) }
    var placing: (CGSize, Geometry, Int) -> WatermarkComposite.Placing = { WatermarkComposite.basePlacing(decoded: $0, engineCut: $1, turnsAfter: $2) }
    var metered: ([String: ParamValue], Double?) -> [String: ParamValue] = { WatermarkComposite.metered($0, reading: $1) }

    static var broken: [Rules] {
        [
            Rules(name: "成片 marks in the stamp's word", word: { e, c in
                WatermarkComposite.Marks(e.watermarks.filter(\.on)).map { $0.key() } ?? "" }),
            Rules(name: "a mark's eye ignored by the base", word: { e, c in
                var on = e; on.watermarks = on.watermarks.map { var p = $0; p.on = true; return p }
                return WatermarkComposite.Base.word(on, isComposite: c) }),
            Rules(name: "the base's word always in the stamp", stamp: { w, c, t, d, r, e, p, l, b in
                DevelopStamp.of(wire: w, cut: c, turns: t, decode: d, isRAW: r, longEdge: e, engine: "engine 1|abc", piece: p, lens: l,
                                base: b.isEmpty ? "-" : b) }),
            Rules(name: "the white not following the exposure", white: { _, k in WatermarkComposite.baseWhite(exposureEV: 0, whiteEV: k) }),
            Rules(name: "the host's turn after left out", placing: { d, g, _ in WatermarkComposite.basePlacing(decoded: d, engineCut: g, turnsAfter: 0) }),
            Rules(name: "the engine's cut left out", placing: { d, _, t in WatermarkComposite.basePlacing(decoded: d, engineCut: .default, turnsAfter: t) }),
            Rules(name: "the meter left on under a mark", metered: { w, _ in w }),
        ]
    }
}

final class Checks {
    let rules: Rules, quiet: Bool
    var passed = 0, failed = 0
    init(_ rules: Rules, quiet: Bool) { self.rules = rules; self.quiet = quiet }
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failed += 1; if !quiet { print("  FAILED: \(what())") } }
    }
}

enum Fixture {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// 64 × 32: an opaque white plate inset 4 px with a red square in its top-left — so a flip or a turn shows — clear
    /// round it.
    static func markPNG() -> Data {
        let w = 64, h = 32
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            guard x >= 4, x < w - 4, y >= 4, y < h - 4 else { continue }
            let red = x < 20 && y < 16
            px[i] = 255; px[i + 1] = red ? 0 : 255; px[i + 2] = red ? 0 : 255; px[i + 3] = 255
        } }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

/// A float RGBA scene, `w` × `h`, a smooth ground with a fourth channel of 0.5.
struct Scene {
    let w: Int, h: Int
    var px: [Float]
    init(_ w: Int, _ h: Int, ground: Bool = true) {
        self.w = w; self.h = h
        px = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let g: Float = ground ? 0.05 + 0.2 * Float(x) / Float(w) : 0
            px[i] = g; px[i + 1] = g * 0.9; px[i + 2] = g * 0.8; px[i + 3] = 0.5
        } }
    }
    func at(_ x: Int, _ y: Int) -> SIMD4<Float> { let i = (y * w + x) * 4; return SIMD4(px[i], px[i + 1], px[i + 2], px[i + 3]) }

    mutating func lay(_ marks: WatermarkComposite.Marks, placing: WatermarkComposite.Placing, white: Double, pixels: WatermarkPixels) {
        let (w, h) = (self.w, self.h)
        px.withUnsafeMutableBufferPointer {
            _ = WatermarkComposite.base(marks, into: $0.baseAddress!, width: w, height: h, channels: 4, placing: placing, white: white, pixels: pixels)
        }
    }

    /// The engine's cut by index (lossless: a full crop, quarter turns and flips only): each output pixel's centre taken
    /// back the engine's way — the flips undone, then the turns — to the source pixel under it. Not `Geometry`.
    func engineCut(turns: Int, flipH: Bool, flipV: Bool) -> Scene {
        let k = ((turns % 4) + 4) % 4
        let ow = k % 2 == 0 ? w : h, oh = k % 2 == 0 ? h : w
        var out = Scene(ow, oh, ground: false)
        for y in 0..<oh { for x in 0..<ow {
            var u = x, v = y
            if flipH { u = ow - 1 - u }
            if flipV { v = oh - 1 - v }
            let (sx, sy): (Int, Int)
            switch k {
            case 1: (sx, sy) = (v, h - 1 - u)            // out (u, v) of a clockwise turn ← source (v, H−1−u)
            case 2: (sx, sy) = (w - 1 - u, h - 1 - v)
            case 3: (sx, sy) = (w - 1 - v, u)
            default: (sx, sy) = (u, v)
            }
            let i = (y * ow + x) * 4, j = (sy * w + sx) * 4
            for c in 0..<4 { out.px[i + c] = px[j + c] }
        } }
        return out
    }

    /// The host's turn after (`EngineHost.turned`'s vImage, clockwise `k`).
    func turned(_ k: Int) -> Scene {
        let k = ((k % 4) + 4) % 4
        guard k != 0 else { return self }
        let ow = k % 2 == 0 ? w : h, oh = k % 2 == 0 ? h : w
        var out = Scene(ow, oh, ground: false)
        var src = px
        src.withUnsafeMutableBytes { s in
            out.px.withUnsafeMutableBytes { o in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 16)
                var b = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: ow * 16)
                _ = vImageRotate90_ARGBFFFF(&a, &b, UInt8((4 - k) % 4), [0, 0, 0, 0], vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }
}

/// The two-point word's 2.4.0 twin, to call it alike.
func stamp240(_ w: [String: ParamValue], _ c: Geometry?, _ t: Int, _ d: DecodeSettings, _ r: Bool, _ e: Int, _ p: String?, _ l: String) -> String {
    DevelopStamp240.of(wire: w, cut: c, turns: t, decode: d, isRAW: r, longEdge: e, engine: "engine 1|abc", piece: p, lens: l)
}

@MainActor
func run(_ rules: Rules, quiet: Bool) -> Checks {
    let c = Checks(rules, quiet: quiet)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wm-base-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = WatermarkStore(folder: folder.appendingPathComponent("marks"), caches: folder.appendingPathComponent("caches"))
    guard case .success(.new(let mark)) = store.addNow(Fixture.markPNG(), name: "plate") else {
        c.expect(false, "the library takes the check's mark"); return c
    }
    WatermarkComposite.library = store
    defer { WatermarkComposite.library = nil }
    let place = WatermarkPlacement(mark: mark.id, stage: .base, anchor: .tl, dx: 0.3, dy: 0.25, size: 0.3)
    let full = WatermarkPlacement(mark: mark.id, stage: .full, anchor: .br, dx: 0.2, dy: 0.2, size: 0.25)

    // MARK: the stamp
    do {
        var base = FrameEdit(); base.watermarks = [place]
        var fullOnly = FrameEdit(); fullOnly.watermarks = [full]
        var eyeOff = FrameEdit(); eyeOff.watermarks = [{ var p = place; p.on = false; return p }()]
        var clear = FrameEdit(); clear.watermarks = [{ var p = place; p.opacity = 0; return p }()]
        var filmOff = base; filmOff.filmOff = FrameEdit.FilmOff(filmEdgeActive: false, dateBackActive: false)
        let markless: [(String, FrameEdit, Bool)] = [("no mark", FrameEdit(), false), ("成片 marks only", fullOnly, false),
                                                     ("a 底片 mark switched off", eyeOff, false), ("a 底片 mark at 0 %", clear, false),
                                                     ("a 底片 mark, the film off", filmOff, false), ("a pair's 底片 mark", base, true)]
        var wires: [[String: ParamValue]] = []
        var w0 = FilmParams.default.fullDelta
        for f in Geometry.default.wire { w0[f.name] = f.value }
        w0["product_defaults"] = .bool(true)
        wires.append(w0)
        var w1 = w0; w1["preview_long_edge"] = .double(2400); w1["exposure_compensation_ev"] = .double(0.7); wires.append(w1)
        var w2 = w0; w2["film_stock"] = .string("kodak_tri_x_400"); w2["scene_curve"] = .string(""); wires.append(w2)
        var w3 = w0; w3["overscan_active"] = .bool(true); w3["scene_layers"] = .string("ab12"); wires.append(w3)
        var raw = DecodeSettings(); raw.lensCorrection = true
        var cut = Geometry.default; cut.crop = CropRect(x: 0.1, y: 0, width: 0.8, height: 1); cut.quarterTurns = 1
        var all = 0, same = 0
        for (name, edit, composite) in markless {
            let word = rules.word(edit, composite)
            c.expect(word.isEmpty, "\(name): no word in the stamp (\(word))")
            for wire in wires {
                for (decode, isRAW) in [(DecodeSettings(), false), (raw, true)] {
                    for (g, t) in [(nil, 0), (cut, 2)] as [(Geometry?, Int)] {
                        for (piece, lens) in [(nil, ""), ("piece|a|b", "sony 1")] as [(String?, String)] {
                            all += 1
                            if rules.stamp(wire, g, t, decode, isRAW, 2400, piece, lens, word) == stamp240(wire, g, t, decode, isRAW, 2400, piece, lens) {
                                same += 1
                            }
                        }
                    }
                }
            }
        }
        c.expect(all > 0 && same == all, "every markless edit is stamped as 2.4.0 stamped it: \(same) of \(all)")
        let w = wires[1]
        func st(_ e: FrameEdit) -> String { rules.stamp(w, nil, 0, DecodeSettings(), false, 2400, nil, "", rules.word(e, false)) }
        let before = st(base)
        c.expect(before != stamp240(w, nil, 0, DecodeSettings(), false, 2400, nil, ""), "a 底片 mark is in the stamp")
        var moved = base; moved.watermarks[0].dx += 0.01
        var sized = base; sized.watermarks[0].size *= 1.1
        var faded = base; faded.watermarks[0].opacity = 0.5
        var turned = base; turned.watermarks[0].rotation = 0.2
        var plusFull = base; plusFull.watermarks.append(full)
        var fullMoved = plusFull; fullMoved.watermarks[1].dx += 0.1
        c.expect(st(moved) != before && st(sized) != before && st(faded) != before && st(turned) != before,
                 "a 底片 mark moved, sized, faded or turned is another stamp")
        c.expect(st(plusFull) == before && st(fullMoved) == before, "a 成片 mark beside it, and moved, leaves the stamp as it was")
        // Its file replaced: the word names the file's hash.
        guard case .success(.new(let other)) = store.addNow({ () -> Data in
            var d = Fixture.markPNG(); d.append(contentsOf: [0]); return d }(), name: "other") else { c.expect(false, "a second mark"); return c }
        var swapped = base; swapped.watermarks[0].mark = other.id
        c.expect(st(swapped) != before, "another file under the same placement is another stamp")
    }

    // MARK: the level
    do {
        for k in [3.0, 4.5] {
            let at0 = rules.white(0, k)
            var worst = 0.0
            for e in stride(from: -3.0, through: 3.0, by: 0.5) { worst = max(worst, abs(rules.white(e, k) * pow(2, e) - at0)) }
            c.expect(abs(at0 - 0.184 * pow(2, k)) < 1e-12 && worst < 1e-12,
                     "the white is middle grey +\(k) EV over whatever Film Exposure and the meter expose (worst \(worst))")
        }
        var wire = FilmParams.default.fullDelta
        c.expect(WatermarkComposite.whiteEV(wire: wire) == 3.0, "a print's white is +3.0 EV")
        wire["digital_intermediate"] = .bool(true)
        c.expect(WatermarkComposite.whiteEV(wire: wire) == 4.5, "the Digital Intermediate's is +4.5 EV")
        wire["scan_film"] = .bool(true)
        c.expect(WatermarkComposite.whiteEV(wire: wire) == 3.0, "a scan is no DI: +3.0 EV")
        var m = FilmParams.default.fullDelta
        m["exposure_compensation_ev"] = .double(0.5)
        c.expect(WatermarkComposite.exposureEV(wire: m, meter: 1.25) == 0.5, "the meter off: Film Exposure alone")
        c.expect(rules.metered(m, 1.25) == m, "the meter off: the wire as it is")
        m["auto_exposure"] = .bool(true)
        c.expect(WatermarkComposite.exposureEV(wire: m, meter: 1.25) == 1.75, "the meter on: Film Exposure and its reading")
        let opened = rules.metered(m, 1.25)
        c.expect(opened["auto_exposure"] == .bool(false) && opened["exposure_compensation_ev"] == .double(1.75),
                 "a metered develop under a mark: the meter off at Film Exposure plus the reading (the engine's meter never reads the mark)")
        c.expect(rules.metered(m, nil) == m, "no reading: the wire as it is")
        let alone = WatermarkComposite.meterWire(m)
        c.expect(alone["exposure_compensation_ev"] == .double(0) && alone["overscan_active"] == .bool(false) && alone["preview_long_edge"] == nil,
                 "the meter reads the clean frame alone: no exposure of its own, no film edge")
        var e = FrameEdit(); e.watermarks = [place]
        if let b = WatermarkComposite.Base(e, isComposite: false) {
            var m2 = m; m2["exposure_compensation_ev"] = .double(0.6)
            var m3 = m; m3["auto_exposure_method"] = .string("protect_highlights")
            var m4 = m; m4["print_exposure"] = .double(1.3)
            c.expect(b.sourceWord(wire: m2) != b.sourceWord(wire: m) && b.sourceWord(wire: m3) != b.sourceWord(wire: m),
                     "the source's word follows Film Exposure and the meter under a mark")
            c.expect(b.sourceWord(wire: m4) == b.sourceWord(wire: m), "a print's change leaves the source as it was (a reprint)")
        } else { c.expect(false, "a 底片 mark makes a base") }
    }

    // MARK: the geometry
    do {
        guard let marks = WatermarkComposite.Marks([place]) else { c.expect(false, "marks"); return c }
        let white = 1.04
        for (w, h) in [(240, 160), (160, 240)] {
            for turns in 0..<4 {
                for (fh, fv) in [(false, false), (true, false), (false, true)] {
                    for after in [0, 1, 2, 3] {
                        var cut = Geometry.default
                        cut.quarterTurns = turns; cut.flipH = fh; cut.flipV = fv
                        var decode = Scene(w, h)
                        decode.lay(marks, placing: rules.placing(CGSize(width: w, height: h), cut, after), white: white, pixels: store)
                        let made = decode.engineCut(turns: turns, flipH: fh, flipV: fv).turned(after)
                        var direct = Scene(w, h).engineCut(turns: turns, flipH: fh, flipV: fv).turned(after)
                        direct.lay(marks, placing: .whole(CGSize(width: direct.w, height: direct.h)), white: white, pixels: store)
                        var worst: Float = 0
                        if made.w == direct.w && made.h == direct.h {
                            for i in 0..<made.px.count { worst = max(worst, abs(made.px[i] - direct.px[i])) }
                        } else { worst = .infinity }
                        c.expect(worst < 1e-4, "\(w)x\(h), the engine's cut \(turns) turns flip \(fh ? "H" : fv ? "V" : "-"), the host's turn \(after): the mark where the picture shows it (worst \(worst))")
                    }
                }
            }
        }
        // The engine's crop and straighten: the mark's centre on the decode is the picture's point there.
        var crop = Geometry.default
        crop.crop = CropRect(x: 0.12, y: 0.2, width: 0.6, height: 0.55); crop.angle = 4
        let size = CGSize(width: 900, height: 600)
        let p = rules.placing(size, crop, 0)
        let f = WatermarkGeometry.frame(of: place, canvas: p.canvas, aspect: 2)
        let got = f.center.applying(p.toPicture)
        let n = crop.sourcePoint(forOutput: CGPoint(x: f.center.x / p.canvas.width, y: f.center.y / p.canvas.height), imageSize: size)
        c.expect(abs(got.x - n.x * size.width) < 0.01 && abs(got.y - n.y * size.height) < 0.01 && p.canvas == crop.outputSize(for: size),
                 "a crop and a straighten: the mark's centre on the decode is the picture's (\(got) against \(n.x * size.width), \(n.y * size.height))")
        // A preview's decode and a 3,000 px one place it at the same place and the same share of the picture.
        func centroid(_ s: Scene) -> (x: Double, y: Double, n: Double) {
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<s.h { for x in 0..<s.w where s.at(x, y).x > 0.5 { sx += Double(x) + 0.5; sy += Double(y) + 0.5; n += 1 } }
            return (sx / max(n, 1) / Double(s.w), sy / max(n, 1) / Double(s.h), n / Double(s.w * s.h))
        }
        var small = Scene(600, 400), big = Scene(3000, 2000)
        small.lay(marks, placing: rules.placing(CGSize(width: 600, height: 400), crop, 1), white: white, pixels: store)
        big.lay(marks, placing: rules.placing(CGSize(width: 3000, height: 2000), crop, 1), white: white, pixels: store)
        let a = centroid(small), b = centroid(big)
        c.expect(abs(a.x - b.x) < 1.0 / 600 && abs(a.y - b.y) < 1.0 / 400 && abs(a.n - b.n) / max(b.n, 1e-9) < 0.03,
                 "a preview's decode and a 3,000 px one: the same place (\(a.x), \(a.y) / \(b.x), \(b.y)) and share (\(a.n) / \(b.n))")
    }

    // MARK: the two canvases (叠加于's conversion, the overlay's place for a 底片 mark)
    do {
        // A film's canvas 60 × 40 mm, the picture's box 36 × 24 at (12, 8) tilted 1.5°, Edit's crop a plain cut.
        var printCrop = Geometry.default
        printCrop.crop = CropRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)
        let cv = WatermarkCanvases.of(finished: CGSize(width: 60, height: 40),
                                     film: (box: CGRect(x: 12, y: 8, width: 36, height: 24), tilt: 1.5, centre: CGPoint(x: 30, y: 20)),
                                     printCrop: printCrop)
        c.expect(cv.base == CGSize(width: 36, height: 24) && abs(cv.full.width - 48) < 1e-9 && abs(cv.full.height - 36) < 1e-9,
                 "the 底片 canvas is the picture's box; the 成片 one the film cut by Edit's crop (\(cv.base), \(cv.full))")
        // The box's centre is the film's centre: on the cut canvas, the crop moved it by (6, 2).
        let centre = CGPoint(x: 18, y: 12).applying(cv.baseToFull)
        c.expect(abs(centre.x - 24) < 1e-9 && abs(centre.y - 18) < 1e-9, "the picture's centre lands where the film's is on the cut (\(centre))")
        let p = WatermarkPlacement(mark: mark.id, stage: .full, anchor: .tl, dx: 0.4, dy: 0.35, size: 0.2, rotation: 0.3)
        let down = WatermarkGeometry.switched(p, to: .base, canvases: cv, aspect: 2)
        let back = WatermarkGeometry.switched(down, to: .full, canvases: cv, aspect: 2)
        let f0 = WatermarkGeometry.frame(of: p, canvas: cv.full, aspect: 2)
        let f1 = WatermarkGeometry.frame(of: down, canvas: cv.base, aspect: 2).through(cv.baseToFull)
        let f2 = WatermarkGeometry.frame(of: back, canvas: cv.full, aspect: 2)
        c.expect(hypot(f1.center.x - f0.center.x, f1.center.y - f0.center.y) < 1e-6 && abs(f1.size.width - f0.size.width) < 1e-6
                 && abs(f1.rotation - f0.rotation) < 1e-9, "成片 → 底片: the mark keeps its place, width and turn on screen")
        c.expect(hypot(f2.center.x - f0.center.x, f2.center.y - f0.center.y) < 1e-6 && down.stage == .base && back.stage == .full,
                 "and back again")
        let edge = WatermarkPlacement(mark: mark.id, stage: .full, anchor: .tl, dx: 0.02, dy: 0.02, size: 0.1)
        let held = WatermarkGeometry.switched(edge, to: .base, canvases: cv, aspect: 2)
        let hc = WatermarkGeometry.frame(of: held, canvas: cv.base, aspect: 2).center
        c.expect(hc.x >= 0 && hc.y >= 0 && hc.x <= cv.base.width && hc.y <= cv.base.height,
                 "on the film's rebate, outside the picture: held in (\(hc))")
    }

    // MARK: the pass
    do {
        let opaque = WatermarkPlacement(mark: mark.id, stage: .base, anchor: .tl, dx: 0.5, dy: 0.5, size: 0.6)
        var faded = opaque; faded.opacity = 0.4
        let white = 1.9
        var s = Scene(400, 400), t = Scene(400, 400)
        let ground = Scene(400, 400)
        s.lay(WatermarkComposite.Marks([opaque])!, placing: .whole(CGSize(width: 400, height: 400)), white: white, pixels: store)
        t.lay(WatermarkComposite.Marks([faded])!, placing: .whole(CGSize(width: 400, height: 400)), white: white, pixels: store)
        // The plate's white (away from its red square): the mark's frame on the canvas, its (0.75, 0.6).
        let f = WatermarkGeometry.frame(of: opaque, canvas: CGSize(width: 400, height: 400), aspect: 2)
        let q = CGPoint(x: 0.75, y: 0.6).applying(f.transform)
        let x = Int(q.x), y = Int(q.y)
        let o = s.at(x, y), g = ground.at(x, y), h = t.at(x, y)
        c.expect(abs(o.x - Float(white)) < 1e-3 && abs(o.y - Float(white)) < 1e-3 && abs(o.z - Float(white)) < 1e-3,
                 "an opaque white texel is the white, neutral, in ProPhoto (\(o))")
        let want = g + (SIMD4<Float>(repeating: Float(white)) - g) * 0.4
        c.expect(abs(h.x - want.x) < 2e-3 && abs(h.y - want.y) < 2e-3, "40 % opacity is 40 % of the way (\(h) against \(want))")
        var moved = 0, alpha = 0
        let box = f.bounds.insetBy(dx: -2, dy: -2)
        for yy in 0..<400 { for xx in 0..<400 {
            if s.at(xx, yy).w != 0.5 { alpha += 1 }
            if !box.contains(CGPoint(x: xx, y: yy)) && s.at(xx, yy) != ground.at(xx, yy) { moved += 1 }
        } }
        c.expect(moved == 0 && alpha == 0, "nothing off the mark's box moved (\(moved)), nor the fourth channel (\(alpha))")
        // The red square is the mark's own top-left: red in ProPhoto is more red than green.
        let r = CGPoint(x: 0.2, y: 0.3).applying(f.transform)
        let red = s.at(Int(r.x), Int(r.y))
        c.expect(red.x > red.y * 1.5, "the mark's colour, linearised and in ProPhoto: its red square is red (\(red))")
    }

    // MARK: the price
    do {
        var e = FrameEdit(); e.watermarks = [place]
        let canvas = PixelSize(width: 2400, height: 1600)
        let inPlace = WatermarkComposite.held(e, isComposite: false, canvas: canvas)
        let copying = WatermarkComposite.held(e, isComposite: false, canvas: canvas, copies: canvas)
        c.expect(WatermarkComposite.held(FrameEdit(), isComposite: false, canvas: canvas) == 0, "no mark: nothing priced")
        c.expect(inPlace > 0 && inPlace < UInt64(canvas.width * canvas.height * 16 / 4),
                 "in place: the marks and the table, far under a second source (\(inPlace >> 10) KB)")
        c.expect(copying - inPlace == UInt64(canvas.width * canvas.height * 16), "a kept decode's copy priced as one source")
        var job = RenderJob(frameID: UUID(), kind: .canvasDevelop, tier: .live, canvas: canvas)
        let plain = CostModel().estimate(job, mode: .whole).peakBytes
        job = job.marked(copying)
        c.expect(CostModel().estimate(job, mode: .whole).peakBytes - plain == copying && job.composed(nil).watermarkBytes == copying,
                 "the job's peak grows by what its pass holds")
    }
    return c
}

@main
struct WatermarkBaseSelftest {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for rule in Rules.broken {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("watermark base self-test: \(caught) of \(Rules.broken.count) broken rules caught")
            exit(caught == Rules.broken.count ? 0 : 1)
        }
        let c = run(Rules(), quiet: false)
        print("watermark base checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
