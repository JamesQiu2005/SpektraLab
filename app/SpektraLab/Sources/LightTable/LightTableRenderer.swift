//  LightTableRenderer.swift — the light table drawn with Metal: the pad, the films, their shadows, the loupe.
//
//  The website's draw (`table.js`' `draw`, `lay`, `sync`, `picture`) over the shaders in
//  `LightTableShaders`. One scene, three targets:
//
//      the view's drawable ◀── pad, then each film's shadow and the film, bottom to top ── the loupe's lens
//      the loupe's target  ◀── the same scene, the loupe's camera, mips sharper (bias −1)
//      a picture to share  ◀── the same scene at rest, a camera over the whole table, read back
//
//  - **Millimetres seen straight down**, an orthographic camera: a table point goes to clip space
//    as `(w − c) · k`, `c` the point in the middle of the target and `k` its millimetres to clip.
//    The view's camera is `LightTableViewport`'s; the loupe's spans `2 · LENS_PAD · R / (s · MAG)`
//    millimetres round the point it magnifies, so it shows what the view shows, three times closer.
//  - **Blending is three.js' premultiplied blending**, as the website's materials ask for it: a
//    film is *multiplied* onto what is under it (`DST_COLOR, ONE_MINUS_SRC_ALPHA` for colour, the
//    target's alpha kept), so the light — and the films below — show through its base; a shadow
//    and the lens are laid over (`ONE, ONE_MINUS_SRC_ALPHA`).
//  - **Private textures only, read back by a blit.** The the operating system simulator's Metal has no shared
//    texture to read back (`Engine/Layer2Renderer.swift`), so every texture here is private:
//    pictures arrive in a shared *buffer* and are blitted in (`texture(from:)`), and the share
//    picture is rendered to a private target and blitted out to a shared buffer that a `CGImage`
//    is made over without a copy. The same path on a host and in the simulator.
//  - **Nothing is drawn that has not changed**: the view asks (`LightTableView`), the renderer only
//    draws what it is handed.

import CoreGraphics
import CoreText
import Foundation
import Metal
import UIKit

final class LightTableRenderer: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case gpu(String)
        var description: String { if case .gpu(let s) = self { s } else { "" } }
    }

    /// The app's own, on the system's GPU; nil where there is none.
    static let shared: LightTableRenderer? = try? LightTableRenderer()

    /// The format of every target: the view's drawable, the loupe's, the share picture's.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// The desk's colour behind everything, should a pixel ever be left (the website's clear colour).
    static let clear = MTLClearColor(red: 0.913, green: 0.913, blue: 0.922, alpha: 1)
    /// The dark desk's: the app's black (`Theme.background`).
    static let clearDark = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let padState: MTLRenderPipelineState
    private let shadowState: MTLRenderPipelineState
    private let stripState: MTLRenderPipelineState
    private let loupeState: MTLRenderPipelineState
    /// Trilinear and clamped: a film and the figures, mipmapped (`texture(bitmap, true)`).
    private let mipSampler: MTLSamplerState
    /// Linear and clamped: the loupe's target, which has no mips.
    private let linearSampler: MTLSamplerState
    /// The scale's figures, 1–29, six to a row, white on clear.
    private(set) var figures: MTLTexture?
    /// The loupe's target, kept at its size while the loupe is on, let go of with the table.
    private var loupeTarget: MTLTexture?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw Failure.gpu("no Metal device") }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.gpu("no command queue for the light table") }
        queue.label = "light table"
        self.queue = queue
        let library = try LightTableShaders.library(device)
        func state(_ vertex: String, _ fragment: String, _ blend: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = Self.pixelFormat
            blend(d.colorAttachments[0])
            return try device.makeRenderPipelineState(descriptor: d)
        }
        padState = try state("lt_vertex", "lt_pad") { $0.isBlendingEnabled = false }
        // NormalBlending, premultiplied: ONE, ONE_MINUS_SRC_ALPHA for colour and alpha.
        let normal: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = { a in
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        shadowState = try state("lt_vertex", "lt_shadow", normal)
        // MultiplyBlending, premultiplied: DST_COLOR, ONE_MINUS_SRC_ALPHA; ZERO, ONE (three.js r186).
        stripState = try state("lt_vertex", "lt_strip") { a in
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .destinationColor; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .zero; a.destinationAlphaBlendFactor = .one
        }
        loupeState = try state("lt_loupe_vertex", "lt_loupe", normal)

        let m = MTLSamplerDescriptor()
        m.minFilter = .linear; m.magFilter = .linear; m.mipFilter = .linear
        m.sAddressMode = .clampToEdge; m.tAddressMode = .clampToEdge
        guard let mip = device.makeSamplerState(descriptor: m) else { throw Failure.gpu("no sampler") }
        mipSampler = mip
        m.mipFilter = .notMipmapped
        guard let lin = device.makeSamplerState(descriptor: m) else { throw Failure.gpu("no sampler") }
        linearSampler = lin
        figures = makeFigures()
    }

    // MARK: what is drawn

    /// One film as it is drawn this moment.
    struct Film {
        var centre: CGPoint
        var angle: Double
        /// As drawn, the press's pop included, mm.
        var size: CGSize
        var presence: Double
        /// Already between lying and held, its alpha not yet times `presence`.
        var shadow: LightTable.Shadow
        var texture: MTLTexture?
    }

    /// The table this moment: the lit area's half size, the films bottom to top, and the lamp's
    /// reflection (table mm) and its strength.
    struct Scene {
        var half: CGSize
        var films: [Film]
        var sheen: SIMD3<Float>
        /// The desk under the pad: the app's black on the screen, with the lamp's light spilling
        /// onto it (design/lighttable, "The desk is the app's black"); the website's white when
        /// false -- the share picture, and the harness's stills held against the website's.
        var darkDesk = false
        /// An export's look (`LightTableExport`): x 0 the table as drawn; 1 the table alone on nothing
        /// under a window's shadow, whose sigma, drop and strength (mm) are y, z, w; 2 the sheet alone, flat.
        var look = SIMD4<Float>(0, 0, 0, 0)
    }

    /// A camera over the table: the point in the middle of the target, the target's size in
    /// millimetres, and the mip bias (the loupe's is sharper).
    struct Camera {
        var centre: CGPoint
        var spanMM: CGSize
        var bias: Float
    }

    /// The loupe as the view draws it: where the lens is on the screen and what it magnifies.
    struct Loupe {
        /// The lens's centre on the screen, points.
        var at: CGPoint
        /// The table point under it, mm.
        var looks: CGPoint
        /// Lens radius and rim, points, already grown with the fade.
        var radius: Double
        var rim: Double
        /// Its unscaled radius, which sizes the target and the area it shows.
        var targetRadius: Double
        var alpha: Double
    }

    // MARK: drawing

    private struct Quad { var place: SIMD4<Float>; var scale: SIMD4<Float>; var camera: SIMD4<Float> }
    private struct Strip { var sizeQuad: SIMD4<Float>; var sheen: SIMD4<Float>; var misc: SIMD4<Float> }
    private struct ShadowU { var sizeQuad: SIMD4<Float>; var shadow: SIMD4<Float> }
    private struct LoupeQ { var at: SIMD4<Float>; var view: SIMD4<Float> }

    /// The pad's films (`lay`): where each lies, so the scale's ink stays out from under it.
    private func padUniforms(_ scene: Scene) -> [SIMD4<Float>] {
        let n = LightTable.films
        var u = [SIMD4<Float>](repeating: .zero, count: 4 + 2 * n)
        u[3 + 2 * n] = scene.look
        u[0] = SIMD4(Float(scene.half.width), Float(scene.half.height), scene.darkDesk ? 1 : 0, 0)
        u[1] = SIMD4(Float(LightTable.rim), Float(LightTable.corner), Float(LightTable.corner + LightTable.rim), 0)
        var k = 0
        for f in scene.films where f.presence > 0.002 && k < n {
            u[2 + k] = SIMD4(Float(f.centre.x), Float(f.centre.y), Float(f.size.width / 2), Float(f.size.height / 2))
            u[2 + n + k] = SIMD4(Float(cos(f.angle)), Float(sin(f.angle)), Float(f.presence), 0)
            k += 1
        }
        u[2 + 2 * n] = SIMD4(Float(k), 0, 0, 0)
        return u
    }

    /// The scene through a camera, into an encoder whose target is already set.
    private func encode(_ scene: Scene, _ camera: Camera, _ enc: MTLRenderCommandEncoder) {
        let k = SIMD2(Float(2 / camera.spanMM.width), Float(2 / camera.spanMM.height))
        let cam = SIMD4(Float(camera.centre.x), Float(camera.centre.y), k.x, k.y)
        // the pad: well past the target on every side
        var pad = Quad(place: SIMD4(Float(camera.centre.x), Float(camera.centre.y), 1, 0),
                       scale: SIMD4(Float(camera.spanMM.width + 400), Float(camera.spanMM.height + 400), 0, 0), camera: cam)
        let padU = padUniforms(scene)
        enc.setRenderPipelineState(padState)
        enc.setVertexBytes(&pad, length: MemoryLayout<Quad>.stride, index: 0)
        padU.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.setFragmentTexture(figures, index: 0)
        enc.setFragmentSamplerState(mipSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        for f in scene.films where f.presence > 0.002 {
            guard let texture = f.texture else { continue }
            let w = f.size.width, h = f.size.height
            let c = cos(f.angle), s = sin(f.angle)
            // its shadow (`sync`): the room's light falls the same way however the film lies
            let sh = f.shadow
            let m = 2 * sh.blur + 2 + hypot(sh.x, sh.y)
            var sq = Quad(place: SIMD4(Float(f.centre.x), Float(f.centre.y), Float(c), Float(s)),
                          scale: SIMD4(Float(w + 2 * m), Float(h + 2 * m), 0, 0), camera: cam)
            var su = ShadowU(sizeQuad: SIMD4(Float(w), Float(h), Float(w + 2 * m), Float(h + 2 * m)),
                             shadow: SIMD4(Float(sh.x * c + sh.y * s), Float(-sh.x * s + sh.y * c), Float(sh.blur),
                                           Float(sh.alpha * f.presence)))
            enc.setRenderPipelineState(shadowState)
            enc.setVertexBytes(&sq, length: MemoryLayout<Quad>.stride, index: 0)
            enc.setFragmentBytes(&su, length: MemoryLayout<ShadowU>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // the film
            let qw = w + 2 * LightTable.pad, qh = h + 2 * LightTable.pad
            var fq = Quad(place: sq.place, scale: SIMD4(Float(qw), Float(qh), 0, 0), camera: cam)
            var fu = Strip(sizeQuad: SIMD4(Float(w), Float(h), Float(qw), Float(qh)),
                           sheen: SIMD4(scene.sheen.x, scene.sheen.y, scene.sheen.z, camera.bias),
                           misc: SIMD4(Float(f.presence), 0, 0, 0))
            enc.setRenderPipelineState(stripState)
            enc.setVertexBytes(&fq, length: MemoryLayout<Quad>.stride, index: 0)
            enc.setFragmentBytes(&fu, length: MemoryLayout<Strip>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(mipSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func pass(_ texture: MTLTexture, dark: Bool = false) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = texture
        d.colorAttachments[0].loadAction = .clear
        d.colorAttachments[0].clearColor = dark ? Self.clearDark : Self.clear
        d.colorAttachments[0].storeAction = .store
        return d
    }

    /// The view's picture (`draw`): the loupe's target first when the loupe shows, then the
    /// table, then the lens over it. `view` is the drawable's size in points and `scale` its pixels
    /// a point; `s` the view's points a millimetre.
    func draw(_ scene: Scene, centre: CGPoint, s: Double, view: CGSize, scale: Double, loupe: Loupe?,
              into drawable: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        var lensTexture: MTLTexture?
        if let loupe, loupe.alpha > 0.003 {
            let side = Int((2 * LightTable.lensPad * loupe.targetRadius * scale).rounded(.up))
            if let target = loupeTexture(side: side), let enc = cb.makeRenderCommandEncoder(descriptor: pass(target, dark: scene.darkDesk)) {
                enc.label = "loupe"
                let span = 2 * LightTable.lensPad * loupe.targetRadius / (s * LightTable.mag)
                encode(scene, Camera(centre: loupe.looks, spanMM: CGSize(width: span, height: span), bias: -1), enc)
                enc.endEncoding()
                lensTexture = target
            }
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass(drawable, dark: scene.darkDesk)) else { return }
        enc.label = "light table"
        encode(scene, Camera(centre: centre, spanMM: CGSize(width: view.width / s, height: view.height / s), bias: -0.35), enc)
        if let loupe, let lensTexture {
            var q = LoupeQ(at: SIMD4(Float(loupe.at.x), Float(loupe.at.y), Float(2 * (loupe.radius + loupe.rim + 36)), 0),
                           view: SIMD4(Float(view.width), Float(view.height), 0, 0))
            var u = SIMD4(Float(loupe.radius), Float(loupe.rim), Float(LightTable.lensPad), Float(loupe.alpha))
            enc.setRenderPipelineState(loupeState)
            enc.setVertexBytes(&q, length: MemoryLayout<LoupeQ>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setFragmentTexture(lensTexture, index: 0)
            enc.setFragmentSamplerState(linearSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    private func loupeTexture(side: Int) -> MTLTexture? {
        if let t = loupeTarget, t.width == side { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: max(side, 4), height: max(side, 4), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        loupeTarget = device.makeTexture(descriptor: d)
        loupeTarget?.label = "loupe"
        return loupeTarget
    }

    /// The loupe's bytes, while it is kept (`LightTableTextures` counts them with the films').
    var loupeBytes: Int { loupeTarget.map { $0.width * $0.height * 4 } ?? 0 }

    /// The table let go of: the loupe's target goes (the figures are 0.9 MB and stay with the renderer).
    func release() { loupeTarget = nil }

    // MARK: a picture of it

    /// The table's rect `x0…x1, y0…y1` (mm, y up) drawn at about `px` pixels across, read back
    /// (`picture`). The scene is the caller's: the pile at rest, the gloss where it rests when the
    /// page opens. Nil without the GPU. Display P3, 8 bits, opaque.
    func picture(_ scene: Scene, x0: Double, y0: Double, x1: Double, y1: Double, px: Double) -> CGImage? {
        let limit = Double(device.supportsFamily(.apple3) ? 16384 : 8192)
        let k = min(1, limit / max(px, px * (y1 - y0) / (x1 - x0)))
        let w = Int((px * k).rounded()), h = Int((px * k * (y1 - y0) / (x1 - x0)).rounded())
        guard w > 0, h > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass(target, dark: scene.darkDesk)) else { return nil }
        encode(scene, Camera(centre: CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2), spanMM: CGSize(width: x1 - x0, height: y1 - y0), bias: -0.35), enc)
        enc.endEncoding()
        return readBack(target, commandBuffer: cb)
    }

    /// One tile of an export (`LightTableExport`): the scene through `camera` into `target`, cleared
    /// to `clear` first. Encoded into `cb`, not committed.
    func encodeTile(_ scene: Scene, _ camera: Camera, into target: MTLTexture, clear: MTLClearColor, commandBuffer cb: MTLCommandBuffer) {
        let d = pass(target)
        d.colorAttachments[0].clearColor = clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: d) else { return }
        enc.label = "export tile"
        encode(scene, camera, enc)
        enc.endEncoding()
    }

    /// A private target's pixels blitted to a shared buffer once `cb`'s drawing is done, and a
    /// `CGImage` made over that buffer without a copy: the buffer is held until the image lets it
    /// go. Commits `cb` and waits for it. BGRA, opaque, Display P3.
    func readBack(_ target: MTLTexture, commandBuffer cb: MTLCommandBuffer) -> CGImage? {
        let w = target.width, h = target.height, rowBytes = w * 4
        guard let out = device.makeBuffer(length: rowBytes * h, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: out, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        let held = Unmanaged.passRetained(out as AnyObject)
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: out.contents(), size: rowBytes * h, releaseData: { info, _, _ in
            if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
        }) else { held.release(); return nil }
        // BGRA in memory, opaque: little-endian 32 bits, alpha first and skipped.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: textures

    /// A private, mipmapped texture made from pixels in a shared buffer (RGBA, 8 bits, tightly
    /// packed by `bytesPerRow`): blitted in, its mips made on the GPU. The command buffer is
    /// committed here and nothing waits for it — anything later on this queue reads the texture
    /// after it is written. `done` is called once the GPU has let go of the buffer.
    func texture(from buffer: MTLBuffer, width: Int, height: Int, bytesPerRow: Int, format: MTLPixelFormat = .rgba8Unorm,
                 mipmapped: Bool = true, debugName: String? = nil, done: (@Sendable () -> Void)? = nil) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: mipmapped)
        d.usage = [.shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder()
        else { return nil }
        t.label = debugName
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: t, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if mipmapped { blit.generateMipmaps(for: t) }
        blit.endEncoding()
        cb.addCompletedHandler { _ in _ = buffer; done?() }
        cb.commit()
        return t
    }

    /// The scale's numbers, 1 to 29 (`figuresTexture`): each set whole by the system face, weight
    /// 500, in a cell of its own with room round it, so no figure bleeds into the next at a
    /// distance; white on clear, the shader reading the coverage. 192 × 128 px a cell, six to a row;
    /// the figures are 60 % of the cell's height.
    private func makeFigures() -> MTLTexture? {
        let cw = 192, ch = 128, w = cw * 6, h = ch * 5
        guard let buffer = device.makeBuffer(length: w * h, options: .storageModeShared),
              let g = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        memset(buffer.contents(), 0, w * h)
        func zeroBounds(_ font: CTFont) -> CGRect {
            var chars: [UniChar] = Array("0".utf16), glyphs = [CGGlyph](repeating: 0, count: 1)
            CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
            return CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, nil, 1)
        }
        let probe = UIFont.systemFont(ofSize: 100, weight: .medium) as CTFont
        let b0 = zeroBounds(probe)
        let size = 100 * Double(ch) * 0.6 / Double(b0.maxY - b0.minY)
        let font = UIFont.systemFont(ofSize: size, weight: .medium) as CTFont
        let b = zeroBounds(font)
        // The canvas's baseline: the figure's middle at the cell's (`(ch + ascent − descent) / 2`).
        let base = (Double(ch) + Double(b.maxY) - Double(-b.minY)) / 2
        g.setFillColor(gray: 1, alpha: 1)
        for n in 1...29 {
            let text = NSAttributedString(string: String(n), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            let line = CTLineCreateWithAttributedString(text)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let x = Double(cw * ((n - 1) % 6)) + Double(cw) / 2 - width / 2
            let topY = Double(ch * ((n - 1) / 6)) + base          // from the top, as the canvas draws
            g.textPosition = CGPoint(x: x, y: Double(h) - topY)   // the context's y is up
            CTLineDraw(line, g)
        }
        // The context's first row is the picture's top row: what the shader's uv expects.
        return texture(from: buffer, width: w, height: h, bytesPerRow: w, format: .r8Unorm, mipmapped: true, debugName: "figures")
    }
}
