//  WatermarkComposite.swift — 水印 drawn into pictures (PRD-8 §4.3, §4.5; RFC-067 §4): the 成片 pass. The 底片 pass
//  (`base`, `blendScene`, the white at +2.5 EV) is stage 2's and is not here — until it lands a 底片 mark is drawn as a
//  成片 one (`WatermarkRules.drawnAsFull`, the one seam).
//
//  **成片, over the finished picture, last**: a photograph's marks over the picture as every surface makes it — after
//  the engine (with its film edge and date), the output transform, Layer 2 and its 成片 mask layers, and Edit's crop; before
//  the output's container and its HDR map (RFC-067 §4.3). One pass, in the edit's order (first = bottom), normal
//  source-over, premultiplied, **on the encoded values in the picture's own colour space and depth** (chosen so
//  overlay, composite and every file agree: SwiftUI's overlay and Core Graphics composite the same way):
//  Core Graphics draws each mark's sRGB pixels into a 16-bit context in the picture's space once (ColorSync converts the
//  colour), and a loop samples it bilinearly through the inverse transform, touching only the mark's box.
//
//  - **Placed only by `WatermarkGeometry.frame(of:canvas:aspect:)`**, the overlay's arithmetic. The canvas is the
//    finished picture cut by Edit's crop (`Placing`). An export draws on its cut picture; a page, a tile and the zoom's
//    part draw on the picture *before* the view cuts it, through the cut's own map (`Geometry.outputToSourceTransform`),
//    so the mark lands where the cut puts it.
//  - **What is drawn is `WatermarkRules.finished`**: a single photograph's marks that are on and not clear; none on a
//    pair or a double — the panel, the page and every exporter read the one rule.
//  - **A mark's pixels are the library's** (`WatermarkPixels`, the app's `WatermarkStore`): fetched at the width drawn
//    (`bitmap(_:width:)`, Lanczos, once). A placement whose mark has been deleted draws nothing.
//  - **In place** where the picture's maker owns its memory (`PictureMemory`: the output transform's buffer, Layer 2's
//    pass and its export, the host's turn); else one copy, and `laid` / `finishedSaying` say which.
//  - **HDR** (RFC-046; the app's one HDR structure, `HDRRendition`). The SDR picture carries the marks; its gain is held
//    to none under them in proportion to their cover: an export's 8-bit map codes × (1 − α) (`unboost`), and a page's
//    log2 gain plane × (1 − α) before its display pass (`holdPlane`, reached through `noted` from `HDRRendition.prepare`),
//    so a white logo is SDR white on the canvas and in the file, and never glows.
//
//  Any thread. No UIKit, no Metal, no engine: `tools/watermark_render_selftest.swift` runs it on a Mac.

import CoreGraphics
import Foundation
import simd

enum WatermarkComposite {
    // MARK: - the library a renderer reads

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: WatermarkPixels?

    /// The app's mark library, set once by the app's model; nil (a check): no mark draws. Read from any thread.
    static var library: WatermarkPixels? {
        get { lock.lock(); defer { lock.unlock() }; return shared }
        set { lock.lock(); shared = newValue; lock.unlock() }
    }

    // MARK: - what is drawn

    /// A photograph's 成片 marks, as a renderer takes them: captured where the edit is read (the main actor), drawn
    /// anywhere. Never empty: a photograph with none to draw has no `Marks`.
    struct Marks: Equatable, Hashable, Sendable {
        /// In z-order, first = bottom; each on 成片.
        var placements: [WatermarkPlacement]

        init?(_ placements: [WatermarkPlacement]) {
            guard !placements.isEmpty else { return nil }
            self.placements = placements
        }

        /// The edit's marks drawn over the finished picture (`WatermarkRules.finished`); nil when there is none.
        static func full(_ edit: FrameEdit, isComposite: Bool) -> Marks? {
            Marks(WatermarkRules.finished(edit, isComposite: isComposite))
        }

        /// What the marks draw, as a word for a cache: every placement, and the file each names (its hash, or "gone"
        /// once deleted), so a mark replaced or deleted is another picture.
        func key(_ pixels: WatermarkPixels? = WatermarkComposite.library) -> String {
            var h: UInt64 = 0xcbf29ce484222325           // FNV-1a: a name, not a secret
            func eat(_ s: String) { for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
            for p in placements {
                eat("|\(p.id)|\(p.mark)|\(p.anchor.rawValue)|\(p.dx)|\(p.dy)|\(p.size)|\(p.rotation)|\(p.opacity)|")
                // 填充 only where there is one: a mark in its own colours names what it named before (a stamp, a copy).
                if let fill = p.fill { eat("fill \(fill)|") }
                eat(pixels?.info(p.mark)?.sha256 ?? "gone")
            }
            return String(format: "%016llx", h)
        }
    }

    /// Marks laid on a picture that is still to be cut by Edit's crop (`crop`, as the edit holds it): the page's
    /// picture, a tile's copy, the zoom's part. The crop's map follows the picture's size (`placing(picture:)`).
    struct Laid: Equatable, Hashable, Sendable {
        var marks: Marks
        var crop: Geometry

        init?(_ edit: FrameEdit, isComposite: Bool) {
            guard let m = Marks.full(edit, isComposite: isComposite) else { return nil }
            marks = m
            crop = isComposite ? .default : edit.printCrop
        }
        init(marks: Marks, crop: Geometry) { self.marks = marks; self.crop = crop }

        static func == (a: Laid, b: Laid) -> Bool { a.marks == b.marks && a.crop == b.crop }
        func hash(into h: inout Hasher) { h.combine(marks) }

        /// Where the canvas is on a picture of `picture` pixels (uncut).
        func placing(picture: CGSize) -> Placing { .through(crop: crop, picture: picture) }

        /// For a cache's name: the marks and the crop they are laid through, the crop's keys sorted
        /// (2026-11-14: an encoder's own order varies, and a name that moves made copies again forever).
        func key(_ pixels: WatermarkPixels? = WatermarkComposite.library) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let crop = (try? encoder.encode(self.crop)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            var h: UInt64 = 0xcbf29ce484222325
            for b in (marks.key(pixels) + "|" + crop).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return String(format: "%016llx", h)
        }
    }

    /// Where the marks' canvas lies on a picture: the canvas they are measured on (the finished picture cut by Edit's
    /// crop, in any unit), and the map from it (top-left origin, y down) to the picture's pixels (the same).
    struct Placing: Equatable, Sendable {
        var canvas: CGSize
        var toPicture: CGAffineTransform

        /// The picture is the canvas: an export's cut picture.
        static func whole(_ size: CGSize) -> Placing { Placing(canvas: size, toPicture: .identity) }

        /// The finished picture before Edit's crop, `picture` pixels: the canvas is its cut, laid back through the cut's
        /// map (`FinishedCut`'s own arithmetic).
        static func through(crop: Geometry, picture: CGSize) -> Placing {
            guard !crop.isIdentity else { return .whole(picture) }
            let g = crop.onFinished(picture)
            return Placing(canvas: g.outputSize(for: picture), toPicture: g.outputToSourceTransform(imageSize: picture))
        }

        /// The picture's pixels mapped on by `t` (a part of it at another scale: the zoom's detail).
        func then(_ t: CGAffineTransform) -> Placing { Placing(canvas: canvas, toPicture: toPicture.concatenating(t)) }

        /// The same canvas on a grid `factor` times as coarse (a gain map at 1/subsample).
        func scaled(by factor: CGFloat) -> Placing {
            Placing(canvas: canvas, toPicture: toPicture.concatenating(CGAffineTransform(scaleX: factor, y: factor)))
        }

        /// How many of the picture's pixels a unit of the canvas is.
        var pixelsPerUnit: CGFloat { sqrt(abs(toPicture.a * toPicture.d - toPicture.b * toPicture.c)) }
    }

    /// One mark ready to draw: its pixels at the size drawn, and their map onto the picture.
    struct Drawn {
        let image: CGImage
        /// The mark's pixels (top-left origin, y down) → the picture's pixels (the same).
        let toPicture: CGAffineTransform
        let opacity: Double

        /// Its four corners on the picture.
        var corners: [CGPoint] {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            return [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)].map { $0.applying(toPicture) }
        }
        /// The whole pixels it touches, held inside `size`; nil where it is off the picture.
        func box(in size: CGSize) -> CGRect? {
            let c = corners, xs = c.map(\.x), ys = c.map(\.y)
            let r = CGRect(x: floor(xs.min()!) - 1, y: floor(ys.min()!) - 1,
                           width: ceil(xs.max()!) - floor(xs.min()!) + 2, height: ceil(ys.max()!) - floor(ys.min()!) + 2)
                .intersection(CGRect(origin: .zero, size: size))
            return r.isNull || r.width < 1 || r.height < 1 ? nil : r
        }
    }

    /// The marks on `placing`, in order, each with its pixels at the width it is drawn at. A deleted mark, or one whose
    /// file cannot be read, is left out.
    static func resolve(_ marks: Marks, on placing: Placing, pixels: WatermarkPixels?) -> [Drawn] {
        guard let pixels, placing.canvas.width > 0, placing.canvas.height > 0 else { return [] }
        let scale = placing.pixelsPerUnit
        var out: [Drawn] = []
        for p in marks.placements where p.opacity > 0 && p.on {
            guard let info = pixels.info(p.mark), info.w > 0, info.h > 0 else { continue }
            let f = WatermarkGeometry.frame(of: p, canvas: placing.canvas, aspect: Double(info.w) / Double(info.h))
            let width = max(1, Int((f.size.width * scale).rounded()))
            guard var image = pixels.bitmap(p.mark, width: width), image.width > 0, image.height > 0 else { continue }
            // 填充: the mark's alpha in one colour (`WatermarkFill`), for 成片 and 底片 alike.
            if p.fill != nil, let filled = WatermarkFill.filled(image, p.fill) { image = filled }
            let t = f.transform(markPixels: CGSize(width: image.width, height: image.height)).concatenating(placing.toPicture)
            out.append(Drawn(image: image, toPicture: t, opacity: min(1, max(0, p.opacity))))
        }
        return out
    }

    // MARK: - the pass

    /// A picture's memory as the blend writes it: red, green, blue in that order and a fourth channel — skipped, or
    /// premultiplied alpha — 8 bits a channel, or 16 little-endian (what the output transform, the turn, Layer 2 and the
    /// cut make). Any other layout is not this.
    struct Bitmap {
        let bytes: UnsafeMutableRawPointer
        let width: Int, height: Int, bytesPerRow: Int
        let sixteen: Bool
        let hasAlpha: Bool
        let space: CGColorSpace

        init?(bytes: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int, bitsPerComponent: Int, bitsPerPixel: Int,
              info: CGBitmapInfo, space: CGColorSpace?) {
            guard let space, space.model == .rgb, bitsPerComponent == 8 || bitsPerComponent == 16,
                  bitsPerPixel == bitsPerComponent * 4, !info.contains(.floatComponents), width > 0, height > 0 else { return nil }
            let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
            let order = info.rawValue & CGBitmapInfo.byteOrderMask.rawValue
            switch alpha {
            case .noneSkipLast?: hasAlpha = false
            case .premultipliedLast?: hasAlpha = true
            default: return nil
            }
            if bitsPerComponent == 16 {
                guard order == CGBitmapInfo.byteOrder16Little.rawValue else { return nil }
            } else {
                guard order == 0 || order == CGBitmapInfo.byteOrder32Big.rawValue else { return nil }
            }
            self.bytes = bytes; self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
            sixteen = bitsPerComponent == 16
            self.space = space
        }

        /// `image`'s layout over `bytes` (its own memory, or a rectangle of it).
        init?(over bytes: UnsafeMutableRawPointer, like image: CGImage, width: Int, height: Int) {
            self.init(bytes: bytes, width: width, height: height, bytesPerRow: image.bytesPerRow, bitsPerComponent: image.bitsPerComponent,
                      bitsPerPixel: image.bitsPerPixel, info: image.bitmapInfo, space: image.colorSpace)
        }

        /// A bitmap context's own memory.
        init?(_ ctx: CGContext) {
            guard let data = ctx.data else { return nil }
            self.init(bytes: data, width: ctx.width, height: ctx.height, bytesPerRow: ctx.bytesPerRow, bitsPerComponent: ctx.bitsPerComponent,
                      bitsPerPixel: ctx.bitsPerPixel, info: ctx.bitmapInfo, space: ctx.colorSpace)
        }
    }

    /// A mark's pixels in the picture's space: premultiplied RGBA, 16 bits, made once by Core Graphics at their own
    /// size (no resample: ColorSync's conversion alone), read by `sample`.
    private struct Texels {
        let ctx: CGContext
        let px: UnsafeMutablePointer<UInt16>
        let w: Int, h: Int, row: Int

        init?(_ mark: CGImage, in space: CGColorSpace) {
            w = mark.width; h = mark.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                  let data = ctx.data else { return nil }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(mark, in: CGRect(x: 0, y: 0, width: w, height: h))
            self.ctx = ctx
            px = data.assumingMemoryBound(to: UInt16.self)
            row = ctx.bytesPerRow / 2
        }

        /// Bilinear at (`x`, `y`) in the mark's pixels (a pixel's centre at +0.5), clear outside the mark: so its sides
        /// come out a pixel soft, as an antialiased edge does. 0…1, premultiplied.
        @inline(__always) func sample(_ x: Double, _ y: Double) -> SIMD4<Float> {
            let fx = x - 0.5, fy = y - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            guard x0 >= -1, y0 >= -1, x0 < w, y0 < h else { return .zero }
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            @inline(__always) func at(_ i: Int, _ j: Int) -> SIMD4<Float> {
                guard i >= 0, j >= 0, i < w, j < h else { return .zero }
                let p = px + j * row + i * 4
                return SIMD4(Float(UInt16(littleEndian: p[0])), Float(UInt16(littleEndian: p[1])),
                             Float(UInt16(littleEndian: p[2])), Float(UInt16(littleEndian: p[3])))
            }
            let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
            let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
            return (top * (1 - ty) + bottom * ty) / 65535
        }
    }

    /// **The pass**: each mark in order, source-over, premultiplied, into `b` where it lies — each picture pixel's centre
    /// taken back onto the mark (the inverse of `Drawn.toPicture`) and the mark sampled there, in the picture's own space.
    static func blend(_ drawn: [Drawn], into b: Bitmap) {
        let size = CGSize(width: b.width, height: b.height)
        for d in drawn {
            guard let box = d.box(in: size), let tex = Texels(d.image, in: b.space) else { continue }
            let inv = d.toPicture.inverted()
            let op = Float(d.opacity)
            let x0 = Int(box.minX), x1 = Int(box.maxX), y0 = Int(box.minY), y1 = Int(box.maxY)
            for y in y0..<y1 {
                let cy = Double(y) + 0.5, cx = Double(x0) + 0.5
                var mx = Double(inv.a) * cx + Double(inv.c) * cy + Double(inv.tx)
                var my = Double(inv.b) * cx + Double(inv.d) * cy + Double(inv.ty)
                let row = b.bytes + y * b.bytesPerRow
                for x in x0..<x1 {
                    let s = tex.sample(mx, my) * op
                    mx += Double(inv.a); my += Double(inv.b)
                    guard s.w > 0 else { continue }
                    let keep = 1 - s.w
                    if b.sixteen {
                        let p = (row + x * 8).assumingMemoryBound(to: UInt16.self)
                        for c in 0..<(b.hasAlpha ? 4 : 3) {
                            let dst = Float(UInt16(littleEndian: p[c])) / 65535
                            p[c] = UInt16((min(1, max(0, s[c] + dst * keep)) * 65535).rounded()).littleEndian
                        }
                    } else {
                        let p = (row + x * 4).assumingMemoryBound(to: UInt8.self)
                        for c in 0..<(b.hasAlpha ? 4 : 3) {
                            let dst = Float(p[c]) / 255
                            p[c] = UInt8((min(1, max(0, s[c] + dst * keep)) * 255).rounded())
                        }
                    }
                }
            }
        }
    }

    /// Draws `drawn` into `ctx`: through its own memory where it is a `Bitmap` (the pass), else by Core Graphics itself.
    /// `ctx`'s CTM is left as it is.
    static func draw(_ drawn: [Drawn], in ctx: CGContext) {
        guard !drawn.isEmpty else { return }
        if let b = Bitmap(ctx) { blend(drawn, into: b); return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.normal)
        ctx.interpolationQuality = .high
        for d in drawn {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(d.opacity))
            ctx.concatenate(d.toPicture)
            ctx.translateBy(x: 0, y: CGFloat(d.image.height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(d.image, in: CGRect(x: 0, y: 0, width: d.image.width, height: d.image.height))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: - 成片: the entry points

    /// **`image` with `marks` over it**, drawn into the picture's own memory where its maker said it may be
    /// (`PictureMemory`) and returned as it is; else into one copy. `placing` nil: the picture is the canvas. Nothing to
    /// draw returns `image` untouched.
    static func full(_ image: CGImage, marks: Marks?, placing: Placing? = nil, pixels: WatermarkPixels? = library) -> CGImage {
        laid(image, marks: marks, placing: placing, pixels: pixels).image
    }

    /// `full`, and whether the marks went into the picture's own memory (false: a copy, or nothing drawn). Returned, not
    /// kept: the composite runs on any thread at once (the review of stage 1: a static the log read was a data race).
    static func laid(_ image: CGImage, marks: Marks?, placing: Placing? = nil,
                     pixels: WatermarkPixels? = library) -> (image: CGImage, inPlace: Bool) {
        guard let marks else { return (image, false) }
        let size = CGSize(width: image.width, height: image.height)
        let drawn = resolve(marks, on: placing ?? .whole(size), pixels: pixels)
        guard !drawn.isEmpty else { return (image, false) }
        if let own = PictureMemory.bytes(of: image), let b = Bitmap(over: own, like: image, width: image.width, height: image.height) {
            withExtendedLifetime(image) { blend(drawn, into: b) }
            return (image, true)
        }
        return (copy(image, drawn: drawn) ?? image, false)
    }

    /// A new picture: `image` with `marks` over it, `image` untouched. Nil when nothing would be drawn.
    static func copy(_ image: CGImage, marks: Marks?, placing: Placing? = nil, pixels: WatermarkPixels? = library) -> CGImage? {
        guard let marks else { return nil }
        let drawn = resolve(marks, on: placing ?? .whole(CGSize(width: image.width, height: image.height)), pixels: pixels)
        guard !drawn.isEmpty else { return nil }
        return copy(image, drawn: drawn)
    }

    /// **An export's finished picture**: `image` (turned: everything before the cut) through Edit's crop `crop` — already
    /// fitted to it (`Geometry.onFinished`), nil for none — with `marks` over the cut, which is the marks' canvas. At
    /// most the one picture the cut itself makes (`FinishedCut`).
    static func finished(_ image: CGImage, crop: Geometry?, marks: Marks?, pixels: WatermarkPixels? = library) throws -> CGImage {
        try finishedSaying(image, crop: crop, marks: marks, pixels: pixels).image
    }

    /// `finished`, and whether the marks were drawn without a copy of the picture made for them (into its own memory,
    /// or into the drawing the cut makes anyway): the log's word.
    static func finishedSaying(_ image: CGImage, crop: Geometry?, marks: Marks?,
                               pixels: WatermarkPixels? = library) throws -> (image: CGImage, inPlace: Bool) {
        guard let crop, !crop.isIdentity else { return laid(image, marks: marks, pixels: pixels) }
        guard let marks else { return (try FinishedCut.image(image, by: crop), false) }
        if let rect = FinishedCut.plainCut(of: image, by: crop) {
            // A plain cut is the picture's own pixels: the marks go into its rectangle first, then it is cut.
            let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
            if let own = PictureMemory.bytes(of: image),
               let b = Bitmap(over: own + y * image.bytesPerRow + x * image.bitsPerPixel / 8, like: image, width: w, height: h) {
                withExtendedLifetime(image) {
                    blend(resolve(marks, on: .whole(CGSize(width: w, height: h)), pixels: pixels), into: b)
                }
                return (try FinishedCut.image(image, by: crop), true)
            }
            return laid(try FinishedCut.image(image, by: crop), marks: marks, pixels: pixels)
        }
        // A turned or straightened cut is drawn: the marks go into that drawing before it is made a picture.
        let made = try FinishedCut.image(image, by: crop) { ctx, size in
            draw(resolve(marks, on: .whole(size), pixels: pixels), in: ctx)
        }
        return (made, true)
    }

    // MARK: - HDR

    /// How much of each pixel of a `width` × `height` grid the marks cover (0…255), over the box they touch: nil when
    /// they touch none. The marks' own alpha × opacity, combined as source-over combines them.
    static func coverage(_ drawn: [Drawn], width: Int, height: Int) -> (box: CGRect, alpha: [UInt8])? {
        let size = CGSize(width: width, height: height)
        let boxes = drawn.compactMap { $0.box(in: size) }
        guard var box = boxes.first else { return nil }
        for b in boxes.dropFirst() { box = box.union(b) }
        let bw = Int(box.width), bh = Int(box.height)
        guard let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data,
              let b = Bitmap(ctx) else { return nil }
        let shifted = drawn.map { Drawn(image: $0.image, toPicture: $0.toPicture.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY)),
                                        opacity: $0.opacity) }
        blend(shifted, into: b)
        let px = data.assumingMemoryBound(to: UInt8.self)
        var alpha = [UInt8](repeating: 0, count: bw * bh)
        for i in 0..<(bw * bh) { alpha[i] = px[i * 4 + 3] }
        return (box, alpha)
    }

    /// **A gain map held to no boost under the marks** (RFC-067 §4.3): each code — log2 gain over log2 H, 8 bits,
    /// row-major, `width` a row, one a `subsample` × `subsample` block of the picture — scaled by (1 − α), α the marks'
    /// cover of that block. Code 0 is gain 1.0: an opaque mark is the SDR it is. Nothing else moves.
    static func unboost(_ codes: inout Data, width: Int, height: Int, subsample: Int, drawn: [Drawn]) {
        guard !drawn.isEmpty, width > 0, height > 0, codes.count >= width * height else { return }
        let f = 1 / CGFloat(max(1, subsample))
        let onMap = drawn.map { Drawn(image: $0.image, toPicture: $0.toPicture.concatenating(CGAffineTransform(scaleX: f, y: f)), opacity: $0.opacity) }
        guard let cover = coverage(onMap, width: width, height: height) else { return }
        let x0 = Int(cover.box.minX), y0 = Int(cover.box.minY), bw = Int(cover.box.width), bh = Int(cover.box.height)
        codes.withUnsafeMutableBytes { raw in
            let c = raw.bindMemory(to: UInt8.self)
            for y in 0..<bh {
                for x in 0..<bw {
                    let a = Int(cover.alpha[y * bw + x])
                    guard a > 0 else { continue }
                    let i = (y0 + y) * width + x0 + x
                    c[i] = UInt8((Double(c[i]) * Double(255 - a) / 255).rounded())
                }
            }
        }
    }

    /// The same for marks laid by `placing` on the map's picture.
    static func unboost(_ codes: inout Data, width: Int, height: Int, subsample: Int, marks: Marks?, placing: Placing,
                        pixels: WatermarkPixels? = library) {
        guard let marks else { return }
        unboost(&codes, width: width, height: height, subsample: subsample, drawn: resolve(marks, on: placing, pixels: pixels))
    }

    /// **A page's log2 gain held to none under the marks** (the page's HDR, `HDRRendition.prepare`): the plane's
    /// value × (1 − α), so its display pass gives `lin(sdr) · g^(w(1 − α))` — exactly what the export's base and held map
    /// show. `plane` is `width` × `height` Floats.
    static func holdPlane(_ plane: UnsafeMutablePointer<Float>, width: Int, height: Int, drawn: [Drawn]) {
        guard let cover = coverage(drawn, width: width, height: height) else { return }
        let x0 = Int(cover.box.minX), y0 = Int(cover.box.minY), bw = Int(cover.box.width), bh = Int(cover.box.height)
        for y in 0..<bh {
            for x in 0..<bw {
                let a = Float(cover.alpha[y * bw + x]) / 255
                guard a > 0 else { continue }
                plane[(y0 + y) * width + x0 + x] *= 1 - a
            }
        }
    }

    // MARK: - the page's pictures, noted for their HDR

    private final class Note {
        weak var image: CGImage?
        let placing: Placing
        let marks: Marks
        init(_ image: CGImage, _ placing: Placing, _ marks: Marks) { self.image = image; self.placing = placing; self.marks = marks }
    }
    nonisolated(unsafe) private static var notes: [Note] = []

    /// A picture a page draws that carries marks (Layer 2's pass, the zoom's part): noted, so its HDR holds them at SDR
    /// white (`noted`, `HDRRendition.prepare`). Held weakly; a few.
    static func note(_ image: CGImage, marks: Marks, placing: Placing) {
        lock.lock(); defer { lock.unlock() }
        notes.removeAll { $0.image == nil || $0.image === image }
        notes.append(Note(image, placing, marks))
        if notes.count > 8 { notes.removeFirst(notes.count - 8) }
    }

    /// The marks a noted picture carries, and where; nil for any other picture.
    static func noted(_ image: CGImage) -> (marks: Marks, placing: Placing)? {
        lock.lock(); defer { lock.unlock() }
        guard let n = notes.first(where: { $0.image === image }) else { return nil }
        return (n.marks, n.placing)
    }

    /// `image` with `laid` drawn over it — in place where its maker owns its memory (Layer 2's pass) — and noted for its
    /// HDR. `placing` nil: the picture is uncut, as the page draws it. Nil `laid`: `image` as it is.
    static func onPage(_ image: CGImage, laid: Laid?, placing: Placing? = nil) -> CGImage {
        guard let laid else { return image }
        let p = placing ?? laid.placing(picture: CGSize(width: image.width, height: image.height))
        let made = full(image, marks: laid.marks, placing: p)
        note(made, marks: laid.marks, placing: p)
        return made
    }

    /// The hold a page's HDR takes under the marks a picture carries (`HDRRendition.heldUnderMarks`): nil for a picture
    /// with none.
    static func planeHold(for sdr: CGImage) -> ((UnsafeMutablePointer<Float>, Int, Int) -> Void)? {
        guard let n = noted(sdr) else { return nil }
        let drawn = resolve(n.marks, on: n.placing, pixels: library)
        guard !drawn.isEmpty else { return nil }
        return { plane, w, h in
            guard w == sdr.width, h == sdr.height else { return }
            holdPlane(plane, width: w, height: h, drawn: drawn)
        }
    }

    // MARK: - one copy

    /// One copy: the picture, at its own depth and in its own space, and the marks over it.
    private static func copy(_ image: CGImage, drawn: [Drawn]) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let bits = image.bitsPerComponent == 16 ? 16 : 8
        // The blend's own layout first (RGBX, as the pipeline's pictures are), so the pass draws it; the picture's next.
        let layouts: [UInt32] = [
            bits == 16 ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue,
            image.bitmapInfo.rawValue,
            CGImageAlphaInfo.premultipliedLast.rawValue,
        ]
        for layout in layouts {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bits, bytesPerRow: 0,
                                      space: space, bitmapInfo: layout) else { continue }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            draw(drawn, in: ctx)
            return ctx.makeImage()
        }
        return nil
    }
}
