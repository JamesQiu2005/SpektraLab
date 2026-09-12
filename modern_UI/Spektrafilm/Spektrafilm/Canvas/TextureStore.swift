//  TextureStore.swift — the buffer system behind a snappy canvas.
//
//  What is resident, and why:
//
//  | texture             | source                      | lifetime            |
//  |---------------------|-----------------------------|---------------------|
//  | source preview      | Core Image decode, P3       | per frame, LRU 8    |
//  | print (preview res) | service reprint, rgba16 raw | per frame, LRU 8    |
//  | full render         | service reprint, `full`     | one frame only      |
//  | stock LUT preview   | service preview_stock_lut   | transient           |
//  | adjusted            | Layer 2 kernel output       | one, re-run on edit |
//  | curve table         | CPU, 256×5 r32Float         | one                 |
//
//  Frame switches are instant because the last eight frames' preview-resolution
//  prints stay resident (a 2560 px rgba16 texture is ~35 MB; eight of each kind
//  is well under 400 MB). Returning to a frame shows its last print immediately,
//  flagged `soft` until the service's session catches up.
//
//  The full render is deliberately *not* kept per frame: at 45 MP one is
//  360 MB, so eight would be 2.9 GB. There is one slot, for the frame on
//  screen, and it is what the canvas settles on once an edit stops moving.
//
//  The slot is **stamped** with the parameters the service rendered it from,
//  so validity is data rather than timing. An undo, or a slider dragged back
//  to where it was, makes the resident render correct again and it is shown
//  instead of re-rendered. The rank the slot used to carry went with the zoom
//  ladder (2026-09-12): there is one full-resolution state now, not three
//  rungs to order.

import Foundation
import Metal

/// One resident native-resolution render: which frame it belongs to, which
/// parameters made it, and the texture.
struct FullRenderEntry: @unchecked Sendable {
    let url: URL
    let stamp: String
    let texture: MTLTexture
}

final class TextureStore: @unchecked Sendable {
    let device: MTLDevice
    private var sources: [URL: MTLTexture] = [:]
    private var prints: [URL: MTLTexture] = [:]
    /// The frame's print at its **own** resolution — what the canvas settles
    /// on once an edit stops moving. One slot, current frame only: a 45 MP
    /// rgba16 texture is 360 MB, so eight of them is not an option the way
    /// eight preview-resolution prints is. `stamp` is the Layer 1 parameters
    /// it was rendered from, which is what makes a lookup a cache hit rather
    /// than a coincidence.
    private var full: FullRenderEntry?
    private var order: [URL] = []
    private let capacity = 8
    private let lock = NSLock()

    init(device: MTLDevice) { self.device = device }

    func source(for url: URL) -> MTLTexture? { lock.withLock { sources[url] } }
    func print(for url: URL) -> MTLTexture? { lock.withLock { prints[url] } }

    /// The resident native-resolution render for `url`, if it was made from
    /// `stamp`.
    func fullRender(for url: URL, stamp: String) -> MTLTexture? {
        lock.withLock {
            guard let f = full, f.url == url, f.stamp == stamp else { return nil }
            return f.texture
        }
    }

    func setSource(_ t: MTLTexture, for url: URL) { lock.withLock { sources[url] = t; touch(url) } }
    func setPrint(_ t: MTLTexture?, for url: URL) { lock.withLock { prints[url] = t; touch(url) } }
    /// Take a native-resolution render into the slot.
    func setFullRender(_ t: MTLTexture, stamp: String, for url: URL) {
        lock.withLock { full = FullRenderEntry(url: url, stamp: stamp, texture: t) }
    }
    /// Free the slot. Called when a print lands that the resident render was
    /// not made from — the same parameters are handled by the lookup, which
    /// keeps a resident render an undo landed back on rather than re-rendering
    /// it. (The `unless:`-shaped variant that used to sit here was only ever
    /// called from the branch that had just failed that identical lookup.)
    func dropFullRender() { lock.withLock { full = nil } }
    func invalidatePrint(for url: URL) { lock.withLock { prints[url] = nil } }
    func removeAll() { lock.withLock { sources.removeAll(); prints.removeAll(); full = nil; order.removeAll() } }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > capacity {
            let old = order.removeFirst()
            sources[old] = nil
            prints[old] = nil
            if full?.url == old { full = nil }
        }
    }

    // MARK: uploads

    /// A raw 16-bit RGBA dump from the service (row 0 = top row), straight
    /// into an `rgba16Unorm` texture. No colour interpretation happens here:
    /// the values are already Display P3 encoded and the layer is P3.
    func uploadRGBA16(path: String, width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count >= width * height * 8 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        return tex
    }

    func makeWritable(width: Int, height: Int, format: MTLPixelFormat = .rgba16Unorm) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// 256 × 5 r32Float: rgb, luma, r, g, b tables.
    func makeCurveTable() -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: Curve.tableSize, height: 5, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    func upload(curves: CurveSet, into tex: MTLTexture) {
        var floats = curves.tables()
        floats.withUnsafeMutableBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, Curve.tableSize, 5), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: Curve.tableSize * 4)
        }
    }
}
