//  Layer2Renderer.swift — Layer 2 run on a picture: the page's, a tile's copy, a check's.
//
//  Not a job and not the engine (design/v5 §3.1): a pointwise pass on the GPU
//  over a picture that is already developed, which is why it can follow a
//  finger. Everything is a buffer — no texture — because the simulator's Metal
//  has no shared texture to read back and no linear texture over a shared
//  buffer, and a buffer is what a `CGImage` is made over without a copy:
//
//      a CGImage ──draw──▶ RGBA16 Display P3, in a shared buffer   (`source`, once a picture)
//                └─ spkLayer2 ─▶ RGBA16 Display P3, in a shared buffer ──▶ a CGImage over it (`image`)
//
//  The picture is drawn into the buffer through Core Graphics, which takes it
//  into Display P3 from whatever it was (a develop already is; a demo JPEG is
//  sRGB) and to the size asked for, once. The pass then writes the next
//  buffer, and the image is made over that buffer: no copy on the way out.
//  An image's buffer goes back to its pool when the image is released
//  (`Layer2Pool`), never before — a buffer still drawn from is not written.
//
//  Platform-neutral (Metal and Core Graphics): `tools/layer2_selftest.swift`
//  runs it on this Mac's GPU.

import CoreGraphics
import Foundation
import Metal

/// A picture as the pass reads it: RGBA, 16 bits a channel, Display P3, tightly packed.
final class Layer2Source: @unchecked Sendable {
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    var bytes: Int { width * height * 8 }
    init(buffer: MTLBuffer, width: Int, height: Int) {
        self.buffer = buffer; self.width = width; self.height = height
    }
}

/// What one pass took: the GPU's own time, and from the call to the picture.
struct Layer2Timing: Equatable, Sendable {
    var width: Int
    var height: Int
    var gpuMilliseconds: Double
    var wallMilliseconds: Double
}

/// The histogram of the picture as shown (the desktop's: R, G, B, luma; 256 bins each).
struct Layer2Histogram: Equatable, Sendable {
    enum Channel: Int, CaseIterable, Sendable { case red = 0, green, blue, luma }
    /// 1,024 counts: red, then green, blue, luma.
    var counts: [UInt32]
    /// The same over the tallest bin, the two at each end left out of the
    /// scaling (clipped black and white would flatten the rest): 0…1.
    var bins: [Float]

    init(counts: [UInt32]) {
        self.counts = counts
        var top: Float = 1
        for (i, v) in counts.enumerated() where i % 256 > 1 && i % 256 < 254 { top = max(top, Float(v)) }
        bins = counts.map { min(1, Float($0) / top) }
    }

    /// One channel's 256 bins, 0…1.
    subscript(channel: Channel) -> ArraySlice<Float> { bins[(channel.rawValue * 256)..<(channel.rawValue * 256 + 256)] }

    /// The samples it counted.
    var samples: Int { counts.prefix(256).reduce(0) { $0 + Int($1) } }
}

/// A buffer an image is drawn from, and the pool it goes back to when the image is gone.
private final class HeldBuffer {
    let buffer: MTLBuffer
    let pool: Layer2Pool?
    init(_ buffer: MTLBuffer, _ pool: Layer2Pool?) { self.buffer = buffer; self.pool = pool }
}

/// The output buffers of the live display, reused once the image over one is gone.
///
/// RAM first: one buffer is kept for the next pass beside the one the page is
/// drawing from — at the preview's own size each is 35 MB (2,400 × 1,800 at
/// 16 bits) — and a buffer of another size (the canvas zoomed in or out) is
/// let go rather than kept for a size that may not come back.
final class Layer2Pool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [MTLBuffer] = []
    private let keep = 1

    func take(_ device: MTLDevice, bytes: Int) -> MTLBuffer? {
        lock.lock()
        free.removeAll { $0.length != bytes }
        if !free.isEmpty {
            let b = free.removeLast(); lock.unlock(); return b
        }
        lock.unlock()
        return device.makeBuffer(length: bytes, options: .storageModeShared)
    }

    func giveBack(_ buffer: MTLBuffer) {
        lock.lock()
        free.append(buffer)
        if free.count > keep { free.removeFirst(free.count - keep) }
        lock.unlock()
    }

    /// Everything kept goes: the page has closed, or memory is short.
    func drain() { lock.lock(); free.removeAll(); lock.unlock() }
}

final class Layer2Renderer: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case memory(String), gpu(String), picture(String)
        var description: String {
            switch self {
            case .memory(let s), .gpu(let s), .picture(let s): s
            }
        }
    }

    /// The app's own, on the system's GPU; nil where there is none.
    static let shared: Layer2Renderer? = try? Layer2Renderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pass: MTLComputePipelineState
    private let passFloat: MTLComputePipelineState
    private let histogramPass: MTLComputePipelineState
    /// The neutral curve table, for a pass whose curves are the identity.
    private let identityCurves: MTLBuffer

    /// `source` is for a check that compiles a broken copy of the kernels.
    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), source: String = Layer2Kernel.source) throws {
        guard let device else { throw Layer2Kernel.Failure.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.gpu("no command queue for Layer 2") }
        self.queue = queue
        let library = try Layer2Kernel.library(device, source: source)
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw Layer2Kernel.Failure.compile("\(name) is missing") }
            return try device.makeComputePipelineState(function: f)
        }
        pass = try state("spkLayer2")
        passFloat = try state("spkLayer2Float")
        histogramPass = try state("spkLayer2Histogram")
        let identity = CurveSet().tables()
        guard let curves = device.makeBuffer(bytes: identity, length: identity.count * 4, options: .storageModeShared) else {
            throw Failure.memory("no buffer for the curve table")
        }
        identityCurves = curves
    }

    // MARK: the picture in

    /// The size a picture of `width` × `height` is drawn at for a long edge of
    /// at most `maxPixel` (nil: its own); never enlarged.
    static func fitted(width: Int, height: Int, maxPixel: Int?) -> (Int, Int) {
        guard let maxPixel, maxPixel > 0, max(width, height) > maxPixel else { return (width, height) }
        let k = Double(maxPixel) / Double(max(width, height))
        return (max(1, Int((Double(width) * k).rounded())), max(1, Int((Double(height) * k).rounded())))
    }

    /// `image`, drawn into a source: Display P3, 16 bits a channel, with its
    /// long edge at most `maxPixel`.
    func source(_ image: CGImage, maxPixel: Int? = nil) throws -> Layer2Source {
        let (w, h) = Self.fitted(width: image.width, height: image.height, maxPixel: maxPixel)
        let buffer = try sourceBuffer(width: w, height: h)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = Self.context(buffer.contents(), width: w, height: h, space: space) else {
            throw Failure.picture("the picture could not be drawn for Layer 2")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Layer2Source(buffer: buffer, width: w, height: h)
    }

    /// A source of these pixels exactly (RGBA, 16 bits, row after row): for a check.
    func source(rgba16 pixels: [UInt16], width: Int, height: Int) throws -> Layer2Source {
        guard pixels.count == width * height * 4 else { throw Failure.picture("not \(width) x \(height) pixels") }
        let buffer = try sourceBuffer(width: width, height: height)
        pixels.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return Layer2Source(buffer: buffer, width: width, height: height)
    }

    private func sourceBuffer(width: Int, height: Int) throws -> MTLBuffer {
        let bytes = width * height * 8
        guard bytes > 0, bytes <= device.maxBufferLength,
              let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw Failure.memory("no \(bytes >> 20) MB buffer for a picture of \(width) x \(height)")
        }
        return buffer
    }

    /// A bitmap over `data`: RGBA, 16 bits a channel little-endian, the fourth
    /// unused — the layout the kernels read and write.
    private static func context(_ data: UnsafeMutableRawPointer, width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        for alpha in [CGImageAlphaInfo.noneSkipLast, .premultipliedLast] {
            let info = CGBitmapInfo.byteOrder16Little.rawValue | alpha.rawValue
            if let c = CGContext(data: data, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                                 space: space, bitmapInfo: info) { return c }
        }
        return nil
    }

    // MARK: the pass

    private struct Size { var width: UInt32; var height: UInt32; var stride: UInt32; var applies: UInt32 }

    private func curves(_ a: Adjustments) -> MTLBuffer? {
        guard !a.curves.isIdentity else { return identityCurves }
        let t = a.curves.tables()
        return device.makeBuffer(bytes: t, length: t.count * 4, options: .storageModeShared)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ state: MTLComputePipelineState, width: Int, height: Int) {
        let tw = state.threadExecutionWidth, th = max(1, state.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    private func run(_ commands: MTLCommandBuffer) throws -> Double {
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.gpu("the Layer 2 pass failed: \(error.localizedDescription)") }
        let gpu = commands.gpuEndTime - commands.gpuStartTime
        return gpu > 0 ? gpu * 1000 : 0
    }

    /// The pass into `out` (16 bits, the source's size). Returns the GPU's milliseconds.
    @discardableResult
    func apply(_ source: Layer2Source, _ a: Adjustments, into out: MTLBuffer) throws -> Double {
        guard out.length >= source.bytes, let curves = curves(a),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Failure.gpu("the Layer 2 pass could not be encoded")
        }
        var u = a.uniforms()
        var size = Size(width: UInt32(source.width), height: UInt32(source.height), stride: 1, applies: 1)
        encoder.setComputePipelineState(pass)
        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 2)
        encoder.setBuffer(curves, offset: 0, index: 3)
        encoder.setBytes(&size, length: MemoryLayout<Size>.stride, index: 4)
        dispatch(encoder, pass, width: source.width, height: source.height)
        encoder.endEncoding()
        return try run(commands)
    }

    /// The picture with `a`, as a `CGImage` over the bytes the kernel wrote:
    /// Display P3, 16 bits a channel. The buffer comes from `pool` and goes
    /// back to it when the image is released.
    func image(_ source: Layer2Source, _ a: Adjustments, pool: Layer2Pool? = nil) throws -> (CGImage, Layer2Timing) {
        let started = DispatchTime.now().uptimeNanoseconds
        let bytes = source.bytes
        guard let out = pool?.take(device, bytes: bytes) ?? device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw Failure.memory("no \(bytes >> 20) MB buffer for the adjusted picture")
        }
        let gpu = try apply(source, a, into: out)
        let image = try Self.image(over: out, width: source.width, height: source.height, pool: pool)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return (image, Layer2Timing(width: source.width, height: source.height, gpuMilliseconds: gpu, wallMilliseconds: wall))
    }

    /// A `CGImage` over `buffer` (RGBA16, Display P3), holding the buffer for
    /// as long as the image lives; it goes back to `pool` after.
    static func image(over buffer: MTLBuffer, width: Int, height: Int, pool: Layer2Pool?) throws -> CGImage {
        let held = Unmanaged.passRetained(HeldBuffer(buffer, pool))
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: buffer.contents(), size: width * height * 8,
                                            releaseData: { info, _, _ in
                                                guard let info else { return }
                                                let h = Unmanaged<HeldBuffer>.fromOpaque(info).takeRetainedValue()
                                                h.pool?.giveBack(h.buffer)
                                            }) else {
            held.release()
            throw Failure.picture("no data provider for the adjusted picture")
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw Failure.picture("the adjusted picture could not be made")
        }
        return image
    }

    /// The pass with float out, unclamped: four floats a pixel. For a check.
    func floats(_ source: Layer2Source, _ a: Adjustments) throws -> [Float] {
        let n = source.width * source.height * 4
        guard let out = device.makeBuffer(length: n * 4, options: .storageModeShared), let curves = curves(a),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Failure.gpu("the Layer 2 pass could not be encoded")
        }
        var u = a.uniforms()
        var size = Size(width: UInt32(source.width), height: UInt32(source.height), stride: 1, applies: 1)
        encoder.setComputePipelineState(passFloat)
        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 2)
        encoder.setBuffer(curves, offset: 0, index: 3)
        encoder.setBytes(&size, length: MemoryLayout<Size>.stride, index: 4)
        dispatch(encoder, passFloat, width: source.width, height: source.height)
        encoder.endEncoding()
        _ = try run(commands)
        return Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: Float.self, capacity: n), count: n))
    }

    // MARK: the histogram

    /// About two hundred thousand samples, whatever the picture's size: plenty
    /// for 256 bins, and the cost of a small picture (the desktop's stride).
    static func stride(width: Int, height: Int) -> Int {
        max(1, Int((Double(width * height) / 200_000).squareRoot()))
    }

    /// The histogram of `source` as shown with `a` (the pass applied where it
    /// is active). Returns the GPU's milliseconds beside it.
    func histogram(_ source: Layer2Source, _ a: Adjustments) throws -> (Layer2Histogram, Double) {
        guard let bins = device.makeBuffer(length: 1024 * 4, options: .storageModeShared), let curves = curves(a),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Failure.gpu("the histogram could not be encoded")
        }
        memset(bins.contents(), 0, 1024 * 4)
        let stride = Self.stride(width: source.width, height: source.height)
        var u = a.uniforms()
        var size = Size(width: UInt32(source.width), height: UInt32(source.height), stride: UInt32(stride),
                        applies: a.isActive ? 1 : 0)
        encoder.setComputePipelineState(histogramPass)
        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(bins, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 2)
        encoder.setBuffer(curves, offset: 0, index: 3)
        encoder.setBytes(&size, length: MemoryLayout<Size>.stride, index: 4)
        dispatch(encoder, histogramPass, width: (source.width + stride - 1) / stride, height: (source.height + stride - 1) / stride)
        encoder.endEncoding()
        let gpu = try run(commands)
        let counts = Array(UnsafeBufferPointer(start: bins.contents().bindMemory(to: UInt32.self, capacity: 1024), count: 1024))
        return (Layer2Histogram(counts: counts), gpu)
    }
}
