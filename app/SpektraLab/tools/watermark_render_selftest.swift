//  watermark_render_selftest.swift — 水印's 成片 composite (`Sources/Engine/WatermarkComposite.swift`), on this Mac, with: the
//  page's HDR, a log2 gain plane held under the marks (`holdPlane`); the overlay's own
//  drawing (Core Graphics through the frame's transform, as the canvas's overlay is laid) held against the composite's
//  pass on the three placements; a pair's and a double's marks never drawn; a 底片 mark drawn as 成片 only with
//  the film off (its base pass is tools/watermark_base_selftest.swift's).
//
//      python3 tools/gate.py selftest --only watermark_render_selftest   # the checks, then their own check
//
//  RFC-067 §6 (Render), PRD-8 §8: the composite of three placements — a corner, one turned 37°, one at 40 %
//  opacity — against a reference written here from the placements' frames alone (its own inverse map, its own
//  bilinear sample of the mark, its own sRGB → Display P3 / Adobe RGB conversion and source-over): within one
//  8-bit level wherever a pixel is two or more pixels from a mark's edge. Then the z-order, a deleted mark,
//  the colour spaces, Edit's crop (plain, turned, straightened: the export's cut against the composite of the
//  cut picture, and the page's picture — marks laid through the crop before the cut — against the export's),
//  in place (no copy of a picture the pipeline made over its own memory), and HDR: the gain map's codes 0
//  (gain 1.0) under an opaque mark and untouched away from it, scaled by 1 − α under 40 %; a page's linear
//  HDR picture back at its SDR under an opaque mark.
//
//  The marks are the app's own library (`WatermarkStore`, in a folder of the check's), so the pixels drawn are
//  the ones the store resamples. AGENTS.md: a check that cannot fire is not a check — `--self-test` runs the
//  same checks with one rule broken at a time (through the pixels a renderer is handed and the steps it is
//  given, never the app's code) and requires each run to fail.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - the rules under test

/// What the checks run; a broken one is put in its place.
struct Rules {
    var name = "the app's"
    /// The pixels a renderer is handed (a broken one lies about them).
    var pixels: (WatermarkStore) -> WatermarkPixels = { $0 }
    /// The placements as the renderer takes them.
    var placements: ([WatermarkPlacement]) -> [WatermarkPlacement] = { $0 }
    var unboosts = true
    var holdsHDRWhite = true

    static var broken: [Rules] {
        [
            Rules(name: "the z-order reversed", placements: { $0.reversed() }),
            Rules(name: "the opacity ignored", placements: { $0.map { var p = $0; p.opacity = 1; return p } }),
            Rules(name: "the mark's sRGB taken as the picture's own space", pixels: { Liar($0, lie: .retag) }),
            Rules(name: "the mark drawn upside down", pixels: { Liar($0, lie: .flip) }),
            Rules(name: "a deleted mark drawn", pixels: { Liar($0, lie: .undelete) }),
            Rules(name: "the gain map left as it was", unboosts: false),
            Rules(name: "the HDR picture's gain kept under the mark", holdsHDRWhite: false),
            Rules(name: "a mark's eye ignored", placements: { $0.map { var p = $0; p.on = true; return p } }),
            Rules(name: "the fill dropped", placements: { $0.map { var p = $0; p.fill = nil; return p } }),
        ]
    }
}

/// A renderer's pixels that lie in one way.
final class Liar: WatermarkPixels {
    enum Lie { case retag, flip, undelete }
    let store: WatermarkStore, lie: Lie
    init(_ store: WatermarkStore, lie: Lie) { self.store = store; self.lie = lie }
    func info(_ id: UUID) -> WatermarkMark? {
        if let i = store.info(id) { return i }
        return lie == .undelete ? store.info(Fixture.anyMark) : nil
    }
    func bitmap(_ id: UUID, width: Int?) -> CGImage? {
        guard let real = store.bitmap(store.info(id) == nil && lie == .undelete ? Fixture.anyMark : id, width: width) else { return nil }
        switch lie {
        case .undelete: return real
        case .retag: return real.copy(colorSpace: Fixture.target ?? real.colorSpace!)
        case .flip:
            let ctx = CGContext(data: nil, width: real.width, height: real.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: real.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(real.height)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(real, in: CGRect(x: 0, y: 0, width: real.width, height: real.height))
            return ctx.makeImage()
        }
    }
}

// MARK: - fixtures

enum Fixture {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    /// The space the picture under test is in (the retagging liar's lie).
    nonisolated(unsafe) static var target: CGColorSpace?
    nonisolated(unsafe) static var anyMark = UUID()

    /// A mark's PNG, `w` × `h`: saturated colour that moves smoothly across it, opaque in the middle and fading to
    /// clear over its outer sixth — a logo's soft edge with nothing sharp inside.
    static func markPNG(_ w: Int, _ h: Int, hue: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w), v = (Double(y) + 0.5) / Double(h)
                let edge = min(u, 1 - u, v, 1 - v) * 6
                let a = edge >= 1 ? 1.0 : edge * edge * (3 - 2 * edge)
                var rgb: (Double, Double, Double)
                switch hue {
                case 0: rgb = (0.92, 0.12 + 0.35 * u, 0.10 + 0.2 * v)        // red into orange
                case 1: rgb = (0.10 + 0.2 * v, 0.25 + 0.3 * u, 0.90)        // blue
                default: rgb = (0.95, 0.95, 0.95)                           // near white
                }
                let i = (y * w + x) * 4
                px[i] = UInt8((rgb.0 * a * 255).rounded()); px[i + 1] = UInt8((rgb.1 * a * 255).rounded())
                px[i + 2] = UInt8((rgb.2 * a * 255).rounded()); px[i + 3] = UInt8((a * 255).rounded())
            }
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// A picture as the export's pipeline makes one: over memory of its own (a direct provider), RGBX, 16 bits a
    /// channel little-endian (or 8), in `space`, a smooth ground.
    static func picture(_ w: Int, _ h: Int, space: CGColorSpace, bits: Int = 16) -> CGImage {
        let bpp = bits / 2, rowBytes = w * bpp
        let mem = malloc(rowBytes * h)!
        for y in 0..<h {
            for x in 0..<w {
                let r = 0.15 + 0.5 * Double(x) / Double(w), g = 0.3 + 0.4 * Double(y) / Double(h), b = 0.45
                if bits == 16 {
                    let p = (mem + y * rowBytes + x * 8).assumingMemoryBound(to: UInt16.self)
                    p[0] = UInt16(r * 65535).littleEndian; p[1] = UInt16(g * 65535).littleEndian; p[2] = UInt16(b * 65535).littleEndian; p[3] = 0
                } else {
                    let p = (mem + y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                    p[0] = UInt8(r * 255); p[1] = UInt8(g * 255); p[2] = UInt8(b * 255); p[3] = 0
                }
            }
        }
        let provider = CGDataProvider(dataInfo: nil, data: mem, size: rowBytes * h, releaseData: { _, d, _ in free(UnsafeMutableRawPointer(mutating: d)) })!
        let info = (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0) | CGImageAlphaInfo.noneSkipLast.rawValue
        let image = CGImage(width: w, height: h, bitsPerComponent: bits, bitsPerPixel: bits * 4, bytesPerRow: rowBytes, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                            intent: .defaultIntent)!
        // As the output transform says of its own buffer.
        PictureMemory.owns(image, bytes: mem)
        return image
    }
}

/// A picture's pixel, 0…1, read from its bytes.
struct Pixels {
    let data: CFData, image: CGImage
    init(_ image: CGImage) { self.image = image; data = image.dataProvider!.data! }
    func at(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let p = CFDataGetBytePtr(data)! + y * image.bytesPerRow + x * image.bitsPerPixel / 8
        if image.bitsPerComponent == 16 {
            let q = UnsafeRawPointer(p).assumingMemoryBound(to: UInt16.self)
            return SIMD3(Double(UInt16(littleEndian: q[0])), Double(UInt16(littleEndian: q[1])), Double(UInt16(littleEndian: q[2]))) / 65535
        }
        return SIMD3(Double(p[0]), Double(p[1]), Double(p[2])) / 255
    }
}

// MARK: - the reference: the placements' frames, and nothing of the composite

enum Reference {
    static func decode(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func encode(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    /// An sRGB colour (encoded) in `space` (encoded): through linear light, both D65.
    static func convert(_ c: SIMD3<Double>, to space: CGColorSpace) -> SIMD3<Double> {
        let l = SIMD3(decode(c.x), decode(c.y), decode(c.z))
        switch space.name {
        case CGColorSpace.displayP3:
            let m = SIMD3(0.8224621 * l.x + 0.1775380 * l.y,
                          0.0331941 * l.x + 0.9668058 * l.y,
                          0.0170827 * l.x + 0.0723974 * l.y + 0.9105199 * l.z)
            return SIMD3(encode(max(0, m.x)), encode(max(0, m.y)), encode(max(0, m.z)))
        case CGColorSpace.adobeRGB1998:
            let m = SIMD3(0.7151627 * l.x + 0.2848373 * l.y, l.y, 0.0411705 * l.y + 0.9588295 * l.z)
            let g = 1 / 2.19921875
            return SIMD3(pow(max(0, m.x), g), pow(max(0, m.y), g), pow(max(0, m.z), g))
        default:
            return c
        }
    }

    /// The mark's premultiplied pixel, bilinear, at (`bx`, `by`) in its pixels (centres at +0.5), as RGBA 0…1.
    static func sample(_ mark: CGImage, _ data: CFData, _ bx: Double, _ by: Double) -> SIMD4<Double> {
        let p = CFDataGetBytePtr(data)!
        func px(_ x: Int, _ y: Int) -> SIMD4<Double> {
            let cx = min(max(x, 0), mark.width - 1), cy = min(max(y, 0), mark.height - 1)
            let q = p + cy * mark.bytesPerRow + cx * 4
            return SIMD4(Double(q[0]), Double(q[1]), Double(q[2]), Double(q[3])) / 255
        }
        let x = bx - 0.5, y = by - 0.5, x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let top = px(x0, y0) * (1 - fx) + px(x0 + 1, y0) * fx, bottom = px(x0, y0 + 1) * (1 - fx) + px(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// One mark as drawn: its frame on the canvas, its pixels at the width the composite fetches.
    struct Mark { let frame: WatermarkFrame; let image: CGImage; let data: CFData }

    static func marks(_ placements: [WatermarkPlacement], canvas: CGSize, store: WatermarkStore) -> [Mark] {
        placements.compactMap { p in
            guard let info = store.info(p.mark) else { return nil }
            let f = WatermarkGeometry.frame(of: p, canvas: canvas, aspect: Double(info.w) / Double(info.h))
            guard let image = store.bitmap(p.mark, width: max(1, Int(f.size.width.rounded()))) else { return nil }
            return Mark(frame: f, image: image, data: image.dataProvider!.data!)
        }
    }

    /// Where a canvas point is in a mark's own square (u, v), and how far it is from the mark's edge, in canvas units
    /// (negative outside). Written from the frame's centre, size and turn alone.
    static func local(_ m: Mark, _ x: Double, _ y: Double) -> (u: Double, v: Double, edge: Double) {
        let dx = x - Double(m.frame.center.x), dy = y - Double(m.frame.center.y)
        let c = cos(m.frame.rotation), s = sin(m.frame.rotation)
        let lx = dx * c + dy * s, ly = -dx * s + dy * c
        let w = Double(m.frame.size.width), h = Double(m.frame.size.height)
        return (lx / w + 0.5, ly / h + 0.5, min(w / 2 - abs(lx), h / 2 - abs(ly)))
    }

    /// The picture's pixel (`x`, `y`) with the marks over it, in `space`; nil within two pixels of a mark's edge.
    static func pixel(_ ground: SIMD3<Double>, _ x: Int, _ y: Int, marks: [Mark], placements: [WatermarkPlacement],
                      space: CGColorSpace) -> SIMD3<Double>? {
        var out = ground
        for (m, p) in zip(marks, placements) {
            let l = local(m, Double(x) + 0.5, Double(y) + 0.5)
            if abs(l.edge) < 2 { return nil }
            guard l.edge > 0 else { continue }
            let s = sample(m.image, m.data, l.u * Double(m.image.width), l.v * Double(m.image.height))
            guard s.w > 0.002 else { continue }
            let colour = convert(SIMD3(s.x, s.y, s.z) / s.w, to: space)
            let a = s.w * p.opacity
            out = colour * a + out * (1 - a)
        }
        return out
    }
}

// MARK: - the checks

final class Checks {
    let rules: Rules
    let quiet: Bool
    var passed = 0, failed = 0
    init(_ rules: Rules, quiet: Bool) { self.rules = rules; self.quiet = quiet }
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failed += 1; if !quiet { print("  FAILED: \(what())") } }
    }
}

@MainActor
func run(_ rules: Rules, quiet: Bool) -> Checks {
    let c = Checks(rules, quiet: quiet)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wm-render-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = WatermarkStore(folder: folder.appendingPathComponent("marks"), caches: folder.appendingPathComponent("caches"))
    guard case .success(.new(let red)) = store.addNow(Fixture.markPNG(240, 120, hue: 0), name: "red"),
          case .success(.new(let blue)) = store.addNow(Fixture.markPNG(200, 200, hue: 1), name: "blue"),
          case .success(.new(let white)) = store.addNow(Fixture.markPNG(160, 80, hue: 2), name: "white"),
          case .success(.new(let gone)) = store.addNow(Fixture.markPNG(100, 101, hue: 1), name: "gone") else {
        c.expect(false, "the library takes the check's marks"); return c
    }
    store.delete(gone.id)
    Fixture.anyMark = blue.id
    let pixels = rules.pixels(store)
    let canvas = CGSize(width: 600, height: 400)

    // Three placements: a corner, a turn of 37°, 40 % opacity (RFC-067 §4.1's parity three).
    let three = [
        WatermarkPlacement(mark: red.id, anchor: .br, dx: 0.20, dy: 0.12, size: 0.30),
        WatermarkPlacement(mark: red.id, anchor: .tl, dx: 0.40, dy: 0.32, size: 0.35, rotation: 37 * .pi / 180),
        WatermarkPlacement(mark: blue.id, anchor: .tr, dx: 0.30, dy: 0.50, size: 0.25, opacity: 0.4),
    ]

    func compare(_ name: String, space: CGColorSpace, bits: Int, placements: [WatermarkPlacement]) {
        Fixture.target = space
        let picture = Fixture.picture(Int(canvas.width), Int(canvas.height), space: space, bits: bits)
        let ground = Fixture.picture(Int(canvas.width), Int(canvas.height), space: space, bits: bits)
        let marks = WatermarkComposite.Marks(rules.placements(placements).filter(\.on))
        let laid = WatermarkComposite.laid(picture, marks: marks, pixels: pixels)
        let made = laid.image
        c.expect(made === picture && laid.inPlace, "\(name): drawn in place, into the picture's own memory")
        let refMarks = Reference.marks(placements, canvas: canvas, store: store)
        let got = Pixels(made), was = Pixels(ground)
        var worst = 0.0, counted = 0, inside = 0, at = (0, 0)
        for y in 0..<Int(canvas.height) {
            for x in 0..<Int(canvas.width) {
                guard let want = Reference.pixel(was.at(x, y), x, y, marks: refMarks, placements: placements, space: space) else { continue }
                let d = got.at(x, y) - want
                let level = max(abs(d.x), abs(d.y), abs(d.z)) * 255
                if level > worst { worst = level; at = (x, y) }
                counted += 1
                if want != was.at(x, y) { inside += 1 }
            }
        }
        c.expect(inside > 2000, "\(name): the marks cover the picture (\(inside) pixels under them)")
        c.expect(worst <= 1.0, "\(name): within 1 level of the reference outside the marks' edges (worst \(String(format: "%.2f", worst)) at \(at), \(counted) pixels)")
    }
    compare("three marks on a 16-bit Display P3 picture", space: Fixture.p3, bits: 16, placements: three)
    compare("three marks on an 8-bit sRGB picture", space: Fixture.sRGB, bits: 8, placements: three)
    compare("three marks on a 16-bit Adobe RGB picture", space: Fixture.adobe, bits: 16, placements: three)

    // The z-order: first is bottom. Blue over red where they overlap.
    do {
        Fixture.target = Fixture.p3
        let pair = [WatermarkPlacement(mark: red.id, anchor: .tl, dx: 0.6, dy: 0.5, size: 0.5),
                    WatermarkPlacement(mark: blue.id, anchor: .tl, dx: 0.7, dy: 0.5, size: 0.3)]
        let made = WatermarkComposite.full(Fixture.picture(600, 400, space: Fixture.p3), marks: WatermarkComposite.Marks(rules.placements(pair)), pixels: pixels)
        let p = Pixels(made).at(280, 200)
        c.expect(p.z > 0.7 && p.x < 0.4, "the z-order: the second mark is over the first (\(p))")
    }

    // A deleted mark draws nothing; the picture is as it was, and so is one whose marks are all .base.
    do {
        let picture = Fixture.picture(600, 400, space: Fixture.p3), ground = Pixels(Fixture.picture(600, 400, space: Fixture.p3))
        let lost = [WatermarkPlacement(mark: gone.id, dx: 0.3, dy: 0.3, size: 0.4)]
        let made = WatermarkComposite.full(picture, marks: WatermarkComposite.Marks(lost), pixels: pixels)
        let p = Pixels(made)
        var same = true
        for y in stride(from: 0, to: 400, by: 7) { for x in stride(from: 0, to: 600, by: 7) where p.at(x, y) != ground.at(x, y) { same = false } }
        c.expect(same, "a placement whose mark was deleted draws nothing")
        // The one rule: a 底片 placement is laid into the source with the film on (not over the finished picture) and
        // drawn as 成片 with the film off (N9); none on a pair or a double; a mark switched off (the row's eye) not drawn.
        var base = three[0]; base.stage = .base
        var off = three[1]; off.on = false
        var edit = FrameEdit(); edit.watermarks = [base, off]
        c.expect(WatermarkComposite.Marks.full(edit, isComposite: false) == nil,
                 "a 底片 mark with the film on is not drawn over the finished picture; a mark switched off is not either")
        var filmOff = edit; filmOff.filmOff = FrameEdit.FilmOff(filmEdgeActive: false, dateBackActive: false)
        let drawn = WatermarkComposite.Marks.full(filmOff, isComposite: false)
        c.expect(drawn?.placements.count == 1 && drawn?.placements.first?.stage == .full && drawn?.placements.first?.id == base.id,
                 "with the film off a 底片 mark is drawn over the finished picture (N9); a mark switched off is not")
        c.expect(WatermarkComposite.Marks.full(edit, isComposite: true) == nil && WatermarkComposite.Laid(edit, isComposite: true) == nil,
                 "a pair or a double draws no mark, on the page and in the file")
        // The eye, through the rules under test: a mark off draws nothing over the picture.
        let hiddenPicture = Fixture.picture(600, 400, space: Fixture.p3)
        let eye = WatermarkComposite.Marks(rules.placements([off]).filter(\.on))
        let hiddenMade = WatermarkComposite.full(hiddenPicture, marks: eye, pixels: pixels)
        let hp = Pixels(hiddenMade)
        var hiddenSame = true
        for y in stride(from: 0, to: 400, by: 5) { for x in stride(from: 0, to: 600, by: 5) where hp.at(x, y) != ground.at(x, y) { hiddenSame = false } }
        c.expect(hiddenSame, "a mark whose eye is off draws nothing")
    }

    // **The overlay against the composite** (RFC-067 §4.1's parity, the three placements): the canvas's overlay
    // lays each mark's picture through the frame's transform and lets Core Graphics draw it; the composite samples it
    // itself. Held against each other on a picture Core Graphics draws into (a layout the pass does not take, so `draw`
    // falls to Core Graphics), within 2 levels away from the marks' edges — measured 1, and 2 at 37°.
    do {
        let marks = WatermarkComposite.Marks(rules.placements(three))!
        let picture = Fixture.picture(600, 400, space: Fixture.p3, bits: 8)
        let composite = WatermarkComposite.copy(picture, marks: marks, pixels: store)!
        let overlay = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: Fixture.p3,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        overlay.setBlendMode(.copy)
        overlay.draw(picture, in: CGRect(x: 0, y: 0, width: 600, height: 400))
        // As the canvas lays a mark (an image through its frame's transform, filtered bilinearly as Core Animation
        // filters a layer): Core Graphics' own drawing, never the composite's sampler.
        overlay.translateBy(x: 0, y: 400); overlay.scaleBy(x: 1, y: -1)
        overlay.interpolationQuality = .low
        overlay.setBlendMode(.normal)
        for d in WatermarkComposite.resolve(WatermarkComposite.Marks(three)!, on: .whole(canvas), pixels: store) {
            overlay.saveGState()
            overlay.setAlpha(CGFloat(d.opacity))
            overlay.concatenate(d.toPicture)
            overlay.translateBy(x: 0, y: CGFloat(d.image.height)); overlay.scaleBy(x: 1, y: -1)
            overlay.draw(d.image, in: CGRect(x: 0, y: 0, width: d.image.width, height: d.image.height))
            overlay.restoreGState()
        }
        let shown = overlay.makeImage()!
        let rgba = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: Fixture.p3,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        rgba.draw(shown, in: CGRect(x: 0, y: 0, width: 600, height: 400))
        let a = Pixels(composite), b = Pixels(rgba.makeImage()!)
        let refMarks = Reference.marks(three, canvas: canvas, store: store)
        var worst = 0.0, counted = 0, over = 0, under = 0, at = (0, 0)
        for y in 0..<400 { for x in 0..<600 {
            guard Reference.pixel(SIMD3(0, 0, 0), x, y, marks: refMarks, placements: three, space: Fixture.p3) != nil else { continue }
            let d = a.at(x, y) - b.at(x, y); let l = max(abs(d.x), abs(d.y), abs(d.z)) * 255
            if l > worst { worst = l; at = (x, y) }
            if l > 2 { over += 1 }
            if refMarks.contains(where: { Reference.local($0, Double(x) + 0.5, Double(y) + 0.5).edge > 0 }) { under += 1 }
            counted += 1
        } }
        if !quiet { print("  overlay against composite: worst \(String(format: "%.2f", worst)) levels at \(at); \(over) of \(under) pixels under the marks past 2 levels") }
        // Core Graphics' own filter is not the composite's bilinear tap (measured here: 591 of 24,688 pixels under the
        // three marks 3-5 levels apart, none further); a mark misplaced by a pixel, turned the other way or flipped is
        // tens of levels on thousands. The bar: under 3 % past 2 levels, none past 6. The overlay's geometry itself is
        // held to the composite's exactly below.
        c.expect(under > 20_000 && Double(over) <= Double(under) * 0.03 && worst <= 6,
                 "the overlay's drawing and the composite agree on the three placements (\(over) of \(under) past 2 levels, worst \(String(format: "%.2f", worst)))")
    }

    // Edit's crop: the export cuts, then draws on the cut; the page draws through the crop on the uncut picture.
    for (name, crop) in crops() {
        Fixture.target = Fixture.p3
        let marks = WatermarkComposite.Marks(rules.placements(three))
        let image = Fixture.picture(600, 400, space: Fixture.p3)
        let fitted = crop.onFinished(CGSize(width: 600, height: 400))
        guard let saying = try? WatermarkComposite.finishedSaying(image, crop: fitted, marks: marks, pixels: pixels),
              let plainCut = try? FinishedCut.image(Fixture.picture(600, 400, space: Fixture.p3), by: fitted) else {
            c.expect(false, "\(name): the export's finished picture is made"); continue
        }
        let export = saying.image
        let wasInPlace = saying.inPlace
        let cutThenMarked = WatermarkComposite.full(plainCut, marks: marks, pixels: pixels)
        let a = Pixels(export), b = Pixels(cutThenMarked)
        c.expect(export.width == plainCut.width && export.height == plainCut.height, "\(name): the file is the cut's size")
        var worst = 0.0
        for y in 0..<export.height { for x in 0..<export.width {
            let d = a.at(x, y) - b.at(x, y); worst = max(worst, max(abs(d.x), abs(d.y), abs(d.z)) * 255)
        } }
        c.expect(worst <= 1.0, "\(name): the export's marks are the cut picture's (worst \(String(format: "%.2f", worst)) levels)")
        if name.hasPrefix("plain") { c.expect(wasInPlace, "\(name): drawn into the picture before it is cut, no copy") }
        // The page: marks through the crop onto the uncut picture, then the view's cut.
        guard !name.hasPrefix("straightened") else { continue }
        let page = WatermarkComposite.full(Fixture.picture(600, 400, space: Fixture.p3), marks: marks,
                                           placing: .through(crop: crop, picture: CGSize(width: 600, height: 400)), pixels: pixels)
        guard let shown = try? FinishedCut.image(page, by: fitted) else { c.expect(false, "\(name): the page's cut"); continue }
        let s = Pixels(shown)
        let refMarks = Reference.marks(three, canvas: CGSize(width: export.width, height: export.height), store: store)
        var parity = 0.0
        for y in 0..<export.height { for x in 0..<export.width {
            guard Reference.pixel(SIMD3(0, 0, 0), x, y, marks: refMarks, placements: three, space: Fixture.p3) != nil else { continue }
            let d = s.at(x, y) - a.at(x, y); parity = max(parity, max(abs(d.x), abs(d.y), abs(d.z)) * 255)
        } }
        c.expect(parity <= 1.0, "\(name): the page's picture, cut by the view, is the export's (worst \(String(format: "%.2f", parity)) levels)")
    }

    // The overlay's geometry against the composite's (the canvas draws in points, at the page's scale; the file in
    // pixels): each mark's corners, the overlay's frame on a canvas of points × the scale, are the composite's drawn
    // corners on the picture, to a thousandth of a pixel.
    do {
        let points = CGSize(width: 300, height: 200), scale: CGFloat = 2
        for p in rules.placements(three) {
            guard let info = store.info(p.mark) else { continue }
            let f = WatermarkGeometry.frame(of: p, canvas: points, aspect: Double(info.w) / Double(info.h))
            let overlay = f.corners.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            guard let d = WatermarkComposite.resolve(WatermarkComposite.Marks([three.first { $0.id == p.id } ?? p])!, on: .whole(canvas),
                                                     pixels: store).first else { c.expect(false, "the composite draws the mark"); continue }
            let made = d.corners
            let off = zip(overlay, [made[0], made[1], made[2], made[3]]).map { hypot(Double($0.x - $1.x), Double($0.y - $1.y)) }.max() ?? 99
            c.expect(off < 1e-3, "the overlay's corners at its scale are the composite's (\(String(format: "%.4f", off)) px off)")
        }
    }

    // HDR: the map held to no boost under the marks, in proportion to their alpha.
    do {
        Fixture.target = Fixture.p3
        let opaque = [WatermarkPlacement(mark: white.id, anchor: .tl, dx: 0.5, dy: 0.4, size: 0.5),
                      WatermarkPlacement(mark: white.id, anchor: .br, dx: 0.45, dy: 0.3, size: 0.5, opacity: 0.4)]
        let marks = WatermarkComposite.Marks(rules.placements(opaque))
        for sub in [1, 4] {
            let mw = (600 + sub - 1) / sub, mh = (400 + sub - 1) / sub
            var codes = Data(repeating: 200, count: mw * mh)
            if rules.unboosts {
                WatermarkComposite.unboost(&codes, width: mw, height: mh, subsample: sub, marks: marks, placing: .whole(canvas), pixels: pixels)
            }
            func code(_ x: Double, _ y: Double) -> Int { Int(codes[Int(y / Double(sub)) * mw + Int(x / Double(sub))]) }
            // The first mark's centre (200, 160), its second's (600 - 180, 400 - 120); the far corner untouched.
            c.expect(code(200, 160) == 0, "1/\(sub) map: gain 1.0 (code 0) under an opaque mark (\(code(200, 160)))")
            c.expect(abs(code(420, 280) - 120) <= 2, "1/\(sub) map: 40 % opacity holds the gain at 60 % of its log (code \(code(420, 280)), 120 wanted)")
            c.expect(code(590, 10) == 200 && code(10, 390) == 200, "1/\(sub) map: untouched away from the marks")
        }
        // A page's HDR (`HDRRendition.prepare`'s log2 gain plane, here 2 stops everywhere), held under the
        // marks through the hook the app sets (`planeHold`, reached by the picture noted as carrying them).
        let sdr = WatermarkComposite.full(Fixture.picture(600, 400, space: Fixture.p3), marks: marks, pixels: pixels)
        var plane = [Float](repeating: 2, count: 600 * 400)
        if rules.holdsHDRWhite {
            WatermarkComposite.library = pixels
            WatermarkComposite.note(sdr, marks: marks!, placing: .whole(canvas))
            plane.withUnsafeMutableBufferPointer { WatermarkComposite.planeHold(for: sdr)?($0.baseAddress!, 600, 400) }
            WatermarkComposite.library = nil
        }
        func gain(_ x: Int, _ y: Int) -> Float { plane[y * 600 + x] }
        c.expect(abs(gain(200, 160)) < 0.01, "a page's HDR: no gain (log2 0) under an opaque mark (\(gain(200, 160)))")
        c.expect(abs(gain(420, 280) - 1.2) < 0.03, "a page's HDR: 60 % of its log2 gain under 40 % (\(gain(420, 280)), 1.2 wanted)")
        c.expect(gain(590, 10) == 2, "a page's HDR: untouched away from the marks")
        c.expect(WatermarkComposite.planeHold(for: Fixture.picture(600, 400, space: Fixture.p3)) == nil, "a picture with no mark is held by nothing")
    }

    // A cache's word for the marks: moves with a placement, and with a mark deleted.
    do {
        let m = WatermarkComposite.Marks(three)!
        var moved = three; moved[0].dx += 0.01
        c.expect(m.key(store) != WatermarkComposite.Marks(moved)!.key(store), "the marks' key moves with a placement")
        let before = m.key(store)
        // A copy's name is the laid marks' key: the same marks through the same crop give the same word every time
        // (an encoder's unsorted keys did not: Layer2Copies made and threw away a tile's copy forever).
        for (name, crop) in crops() {
            var edit = FrameEdit(); edit.watermarks = three; edit.printCrop = crop
            let laid = WatermarkComposite.Laid(edit, isComposite: false)!
            let words = Set((0..<300).map { _ in laid.key(store) })
            c.expect(words.count == 1, "the laid marks' key is one word through \(name) (\(words.count) seen)")
        }
        // 填充 (2026-11-16): a mark in its own colours names what 2.4.1's first build named (the formula as it
        // was, written out here); a fill is another word.
        func oldKey(_ ps: [WatermarkPlacement]) -> String {
            var h: UInt64 = 0xcbf29ce484222325
            func eat(_ s: String) { for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
            for p in ps {
                eat("|\(p.id)|\(p.mark)|\(p.anchor.rawValue)|\(p.dx)|\(p.dy)|\(p.size)|\(p.rotation)|\(p.opacity)|")
                eat(store.info(p.mark)?.sha256 ?? "gone")
            }
            return String(format: "%016llx", h)
        }
        c.expect(m.key(store) == oldKey(three), "原样: the marks' key is the word it was (old stamps and copies hold)")
        var filled = three; filled[0].fill = "#2F6FDE"
        c.expect(WatermarkComposite.Marks(filled)!.key(store) != m.key(store), "a fill is another word")
        store.delete(blue.id)
        c.expect(m.key(store) != before, "and with a mark deleted from the library")
    }

    // 填充: the mark's alpha in one colour — inside its opaque middle the fill itself (in the picture's space), its soft
    // edge the fill at the edge's cover, and nothing outside it.
    do {
        Fixture.target = Fixture.sRGB
        let placed = [WatermarkPlacement(mark: red.id, anchor: .tl, dx: 0.5, dy: 0.5, size: 0.5, fill: "#2F6FDE")]
        let ground = Pixels(Fixture.picture(600, 400, space: Fixture.sRGB, bits: 8))
        let made = Pixels(WatermarkComposite.full(Fixture.picture(600, 400, space: Fixture.sRGB, bits: 8),
                                                  marks: WatermarkComposite.Marks(rules.placements(placed)), pixels: pixels))
        let centre = made.at(200, 200)
        let want = SIMD3<Double>(0x2F, 0x6F, 0xDE) / 255
        let d = centre - want
        c.expect(max(abs(d.x), abs(d.y), abs(d.z)) * 255 <= 1.0, "填充: the mark's middle is the fill (\(centre * 255))")
        // Half way out its soft edge (its outer sixth fades to clear): between the fill and the ground.
        let f = WatermarkGeometry.frame(of: placed[0], canvas: CGSize(width: 600, height: 400), aspect: 2)
        let edgeX = Int(f.center.x - f.size.width / 2 + f.size.width / 24), y = Int(f.center.y)
        let e = made.at(edgeX, y), g = ground.at(edgeX, y)
        c.expect(e != want && e != g && e.z > g.z, "填充: its soft edge keeps the mark's cover (\(e * 255) over \(g * 255))")
        c.expect(made.at(10, 10) == ground.at(10, 10), "填充: nothing drawn outside the mark")
        let tinted = WatermarkFill.filled(store.bitmap(red.id, width: 240)!, "#FFFFFF")!
        let tp = Pixels(tinted)
        c.expect(tinted.width == 240 && tp.at(120, 60) == SIMD3(1, 1, 1), "填充: a white fill's opaque pixel is white")
        c.expect(WatermarkFill.filled(tinted, nil) == nil, "原样: no fill makes no picture")
    }
    return c
}

func crops() -> [(String, Geometry)] {
    var plain = Geometry(); plain.crop = CropRect(x: 0.1, y: 0.15, width: 0.7, height: 0.75)
    var turned = plain; turned.quarterTurns = 1
    var straightened = plain; straightened.angle = 4
    return [("plain crop", plain), ("turned crop", turned), ("straightened crop", straightened)]
}

@main
struct WatermarkRenderSelftest {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for rule in Rules.broken {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("watermark render self-test: \(caught) of \(Rules.broken.count) broken rules caught")
            exit(caught == Rules.broken.count ? 0 : 1)
        }
        let c = run(Rules(), quiet: false)
        print("watermark render checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
