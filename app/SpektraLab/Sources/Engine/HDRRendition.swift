//  HDRRendition.swift — the app's one HDR picture: an SDR picture and its gain, as a screen with headroom shows it.
//
//  The owner, 2026-11-03: Enable HDR "appears to have done zero effect on the rendered canvas", and "one
//  unified HDR structure throughout the app should be coherent and sufficient". So there is one: a picture's HDR
//  is **its SDR pixels, unchanged, and a gain a pixel** from the frame's own film and paper curve (`HDRCurves`).
//  The export writes that gain as an ISO 21496-1 map beside the SDR file (`HDRGainMap`); a page draws it here.
//  Both run **these kernels**, so the screen shows what the file holds:
//
//      L'        = log2 Y − clamp(log2 Y − L, −τ, τ)                       (the clamped base)
//      log2 gain = Ks(L') + κ · clamp(ρ(L'), 0, ρmax) · (log2 Y − L')     (`HDRGrainGain`, the research's R + C)
//      out       = lin(sdr) · 2^(w · log2 gain)                           (the page's picture)
//
//  - **L, the local tone**: log2 Y under a Gaussian of σ = 2 × the picture's own grain width (measured,
//    `HDRGrainGain.sigma(for:)`), separable: a row pass into a Float strip, a column pass that makes the gain.
//    Never the pixel's own Y alone (1:1 put the curve's fine shape inside a grain speck: the owner's
//    "unnatural cutoffs"), never a block mean (¼: the grain "added back afterwards").
//  - **Read at 16 bits** (Display P3): the slope ×3 would make 8-bit steps visible at the curve's peak.
//  - **In strips** of `stripRows` rows with σ's reach of halo above and below, so the export's 48 MP map is
//    held as its 1 B/pixel codes and two strips (16 bits and a Float row pass), never a second picture.
//  - **w, the screen's share**: ISO 21496-1's weight as Photos applies a file's map, BaseHeadroom 0 and
//    AlternateHeadroom log2 H: `w = clamp(log2 headroom_now / log2 H, 0, 1)`. Never Apple's tone mapper.
//  - **Out** (the page's): half-float RGBA, linear extended Display P3, 1.0 = SDR white — `Image` shows it with
//    `.allowedDynamicRange(.high)` (`HDRImage`). 8 B a pixel kept (39 MB for a 4.9 MP canvas).
//
//  One at a time, app-wide (`gate`). No UIKit: the macOS checks compile it. The look and the page's picture
//  (`HDRLook`, `make`) are in HDRLook.swift.
//
//  For the Mac's canvas (2026-11-06, D6). The tables are handed in (the session's, `HDRSessionCurve`), never
//  looked up from a curve's name; and there is no offline build of the source: it is compiled at run time with safe
//  math and precise functions, as `Layer2Kernel` is (AGENTS.md: never fast math).

import CoreGraphics
import Foundation
import Metal

enum HDRRendition {
    enum Failure: Error, CustomStringConvertible {
        case gpu(String)
        var description: String { if case .gpu(let s) = self { "no HDR gain: \(s)" } else { "" } }
    }

    /// `hg_rows`: one thread a strip pixel (its halo rows too), the row pass of log2 Y. `hg_codes` / `hg_plane` /
    /// `hg_apply`: one thread an output pixel of the strip, the column pass → L, then the gain — as the file's
    /// 8-bit code, as Float log2 (the checks'), or applied to the pixel's linear light at the share `weight`.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct HGStrip { uint width; uint rows; uint halo; uint validLo; uint validHi; int radius;
                     float lo; float hi; float top; float kappa; float rhoMax; float weight; uint outRow0; float tau; };

    float3 hr_lin(float3 c) { return select(pow((c + .055) / 1.055, 2.4), c / 12.92, c <= .04045); }
    float hg_l2y(ushort4 p) {
      float3 l = hr_lin(float3(p.rgb) / 65535.);
      return log2(max(dot(l, float3(.2289746, .6917385, .0792869)), 1e-30));
    }

    kernel void hg_rows(device const ushort4 *src [[buffer(0)]], constant float *wts [[buffer(1)]],
                        constant HGStrip &p [[buffer(2)]], device float *tmp [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.width || gid.y >= p.rows + 2u * p.halo) return;
      uint y = clamp(gid.y, p.validLo, p.validHi);
      float a = 0.;
      for (int j = -p.radius; j <= p.radius; j++) {
        uint x = uint(clamp(int(gid.x) + j, 0, int(p.width) - 1));
        a += wts[abs(j)] * hg_l2y(src[y * p.width + x]);
      }
      tmp[gid.y * p.width + gid.x] = a;
    }

    float hg_gain(device const ushort4 *src, constant float *wts, constant float *ks, constant float *sl,
                  constant HGStrip &p, device const float *tmp, uint2 gid) {
      uint s = gid.y + p.halo;
      float L = 0.;
      for (int j = -p.radius; j <= p.radius; j++) {
        uint y = uint(clamp(int(s) + j, int(p.validLo), int(p.validHi)));
        L += wts[abs(j)] * tmp[y * p.width + gid.x];
      }
      float own = hg_l2y(src[s * p.width + gid.x]);
      L = own - clamp(own - L, -p.tau, p.tau);   // the clamped base: no further than τ from the pixel's own tone
      float u = clamp((L - p.lo) / (p.hi - p.lo), 0., 1.) * 255.;
      uint i0 = min(uint(floor(u)), 254u);
      float f = u - float(i0);
      float g = mix(ks[i0], ks[i0 + 1u], f);
      float rho = clamp(mix(sl[i0], sl[i0 + 1u], f), 0., p.rhoMax);
      return clamp(g + p.kappa * rho * (own - L), 0., p.top);
    }

    kernel void hg_codes(device const ushort4 *src [[buffer(0)]], constant float *wts [[buffer(1)]],
                         constant HGStrip &p [[buffer(2)]], device const float *tmp [[buffer(3)]],
                         constant float *ks [[buffer(4)]], constant float *sl [[buffer(5)]],
                         device uchar *out [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.width || gid.y >= p.rows) return;
      out[gid.y * p.width + gid.x] = uchar(round(hg_gain(src, wts, ks, sl, p, tmp, gid) / p.top * 255.));
    }

    kernel void hg_plane(device const ushort4 *src [[buffer(0)]], constant float *wts [[buffer(1)]],
                         constant HGStrip &p [[buffer(2)]], device const float *tmp [[buffer(3)]],
                         constant float *ks [[buffer(4)]], constant float *sl [[buffer(5)]],
                         device float *out [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.width || gid.y >= p.rows) return;
      out[gid.y * p.width + gid.x] = hg_gain(src, wts, ks, sl, p, tmp, gid);
    }

    kernel void hg_apply(device const ushort4 *src [[buffer(0)]], constant float *wts [[buffer(1)]],
                         constant HGStrip &p [[buffer(2)]], device const float *tmp [[buffer(3)]],
                         constant float *ks [[buffer(4)]], constant float *sl [[buffer(5)]],
                         device half4 *out [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.width || gid.y >= p.rows) return;
      float lg = hg_gain(src, wts, ks, sl, p, tmp, gid);
      float3 l = hr_lin(float3(src[(gid.y + p.halo) * p.width + gid.x].rgb) / 65535.);
      out[(p.outRow0 + gid.y) * p.width + gid.x] = half4(half3(l * exp2(p.weight * lg)), 1.h);
    }

    // The system's HDR form, made here: linear P3 lifted, to BT.2020, SDR white at 203 nits, PQ, 16 bits.
    kernel void hg_apply_pq(device const ushort4 *src [[buffer(0)]], constant float *wts [[buffer(1)]],
                            constant HGStrip &p [[buffer(2)]], device const float *tmp [[buffer(3)]],
                            constant float *ks [[buffer(4)]], constant float *sl [[buffer(5)]],
                            device ushort4 *out [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.width || gid.y >= p.rows) return;
      float lg = hg_gain(src, wts, ks, sl, p, tmp, gid);
      float3 l = hr_lin(float3(src[(gid.y + p.halo) * p.width + gid.x].rgb) / 65535.) * exp2(p.weight * lg);
      float3 r = float3(dot(l, float3(.7538330, .1985974, .0475696)), dot(l, float3(.0457438, .9417772, .0124789)),
                        dot(l, float3(-.0012105, .0176017, .9836088)));
      float3 y = pow(clamp(r * (203. / 10000.), 0., 1.), .1593017578125);
      float3 e = pow((.8359375 + 18.8515625 * y) / (1. + 18.6875 * y), 78.84375);
      out[(p.outRow0 + gid.y) * p.width + gid.x] = ushort4(ushort3(round(clamp(e, 0., 1.) * 65535.)), 65535);
    }

    // The display pass (PRD-B, 2026-11-09): the picture's gain already made (`hg_plane`, once a picture and a look),
    // applied at the screen's share. No blur, no table: what a screen or headroom change re-runs.
    struct HGShow { uint width; uint height; float weight; };
    kernel void hg_show_pq(device const ushort4 *src [[buffer(0)]], device const float *plane [[buffer(1)]],
                           constant HGShow &p [[buffer(2)]], device ushort4 *out [[buffer(3)]],
                           uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.width || gid.y >= p.height) return;
      uint i = gid.y * p.width + gid.x;
      float3 l = hr_lin(float3(src[i].rgb) / 65535.) * exp2(p.weight * plane[i]);
      float3 r = float3(dot(l, float3(.7538330, .1985974, .0475696)), dot(l, float3(.0457438, .9417772, .0124789)),
                        dot(l, float3(-.0012105, .0176017, .9836088)));
      float3 y = pow(clamp(r * (203. / 10000.), 0., 1.), .1593017578125);
      float3 e = pow((.8359375 + 18.8515625 * y) / (1. + 18.6875 * y), 78.84375);
      out[i] = ushort4(ushort3(round(clamp(e, 0., 1.) * 65535.)), 65535);
    }
    """

    private struct Strip { var width: UInt32; var rows: UInt32; var halo: UInt32; var validLo: UInt32; var validHi: UInt32
                           var radius: Int32; var lo: Float; var hi: Float; var top: Float; var kappa: Float; var rhoMax: Float
                           var weight: Float; var outRow0: UInt32; var tau: Float }

    /// The rows made at once.
    static let stripRows = 256
    /// A picture of at most this many pixels is made in one strip (a 4.9 MP canvas: +39 MB at 16 bits
    /// and +20 MB of row pass while it is made, as the page's picture itself is kept at 8 B a pixel).
    nonisolated(unsafe) static var wholeLimit = 6_000_000   // the checks set 0 to hold the strips to the one pass

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pipelines: [String: MTLComputePipelineState] = [:]
    nonisolated(unsafe) private static var queues: [UInt64: MTLCommandQueue] = [:]

    private static func pipeline(_ name: String, on device: MTLDevice) throws -> (MTLComputePipelineState, MTLCommandQueue) {
        lock.lock(); defer { lock.unlock() }
        let key = "\(device.registryID)/\(name)"
        if let p = pipelines[key], let q = queues[device.registryID] { return (p, q) }
        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            if #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) {
                options.mathMode = .safe
                options.mathFloatingPointFunctions = .precise
            } else {
                options.fastMathEnabled = false
            }
            library = try device.makeLibrary(source: source, options: options)
        } catch { throw Failure.gpu("\(error)") }
        guard let f = library.makeFunction(name: name) else { throw Failure.gpu("no \(name)") }
        let q: MTLCommandQueue
        if let made = queues[device.registryID] { q = made } else {
            guard let made = device.makeCommandQueue() else { throw Failure.gpu("no command queue") }
            q = made; queues[device.registryID] = made
        }
        do {
            let p = try device.makeComputePipelineState(function: f)
            pipelines[key] = p
            return (p, q)
        } catch { throw Failure.gpu("\(error)") }
    }

    /// The last run's times, for the session log's `hdr picture` line (draw, GPU, the grain's measure).
    nonisolated(unsafe) static var lastTimes: [String: Int] = [:]

    /// One gain at a time, app-wide: a page's pictures and an export's map never make theirs together.
    static let gate = NSLock()

    /// What the kernels write.
    enum Output {
        /// The file's 8-bit codes, `width` bytes a row (`HDRGainMap`).
        case codes(UnsafeMutableRawBufferPointer)
        /// log2 gain as Float (the checks').
        case plane(UnsafeMutableRawBufferPointer)
        /// The page's picture: half-float RGBA, linear, at the screen's share `weight`.
        case edr(MTLBuffer, weight: Double)
        /// The page's picture in UIKit's HDR form: 16-bit RGBX, BT.2020, PQ, SDR white at 203 nits.
        case pq(MTLBuffer, weight: Double)
    }

    /// The strips of `image` through `tables` at local-tone σ `sigma` (px) into `output`.
    static func run(_ image: CGImage, tables t: HDRGrainGain.Tables, sigma: Double, into output: Output,
                    device: MTLDevice) throws {
        let w = image.width, h = image.height
        // A page's picture in one pass (the whole picture is drawn once, not once a strip); an export's map in strips.
        let rows = w * h <= wholeLimit ? h : stripRows
        let radius = HDRGrainGain.radius(sigma), halo = radius
        let kernel: String
        switch output { case .codes: kernel = "hg_codes"; case .plane: kernel = "hg_plane"; case .edr: kernel = "hg_apply"; case .pq: kernel = "hg_apply_pq" }
        let (rowPass, queue) = try pipeline("hg_rows", on: device)
        let (gainPass, _) = try pipeline(kernel, on: device)
        let stripH = rows + 2 * halo
        let bytesOut: Int
        switch output { case .codes: bytesOut = 1; case .plane: bytesOut = 4; case .edr, .pq: bytesOut = 0 }
        guard let src = device.makeBuffer(length: w * stripH * 8, options: .storageModeShared),
              let tmp = device.makeBuffer(length: w * stripH * 4, options: .storageModePrivate),
              let ctx = CGContext(data: src.contents(), width: w, height: stripH, bitsPerComponent: 16, bytesPerRow: w * 8,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { throw Failure.gpu("no room for a \(w) × \(stripH) strip") }
        let out: MTLBuffer?
        if bytesOut > 0 {
            guard let made = device.makeBuffer(length: w * rows * bytesOut, options: .storageModeShared) else { throw Failure.gpu("no room for the map's strip") }
            out = made
        } else { out = nil }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        // The 1-D Gaussian's weights, 0 … radius, normalised so the 2-D product sums to 1.
        var wts = (0...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = wts[0] + 2 * wts.dropFirst().reduce(0, +)
        wts = wts.map { $0 / sum }
        var y0 = 0
        var drawS = 0.0, gpuS = 0.0
        defer { lastTimes["draw_ms"] = Int(drawS * 1000); lastTimes["gpu_ms"] = Int(gpuS * 1000) }
        while y0 < h {
            let t0 = Date()
            let n = min(rows, h - y0)
            let start = y0 - halo                        // the image row at the strip's row 0
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: stripH))
            // CoreGraphics' y is up: the strip's row 0 is the context's top row.
            ctx.draw(image, in: CGRect(x: 0, y: CGFloat(stripH - h + start), width: CGFloat(w), height: CGFloat(h)))
            drawS += Date().timeIntervalSince(t0)
            let t1 = Date()
            let validLo = max(0, -start), validHi = min(stripH - 1, h - 1 - start)
            var p = Strip(width: UInt32(w), rows: UInt32(n), halo: UInt32(halo), validLo: UInt32(validLo), validHi: UInt32(validHi),
                          radius: Int32(radius), lo: Float(t.lo), hi: Float(t.hi), top: Float(t.top),
                          kappa: Float(t.kappa), rhoMax: Float(t.rhoMax), weight: 0, outRow0: UInt32(y0),
                          tau: Float(t.tau))
            if case .edr(_, let weight) = output { p.weight = Float(min(1, max(0, weight))) }
            if case .pq(_, let weight) = output { p.weight = Float(min(1, max(0, weight))) }
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw Failure.gpu("no command buffer") }
            enc.setComputePipelineState(rowPass)
            enc.setBuffer(src, offset: 0, index: 0)
            wts.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.setBytes(&p, length: MemoryLayout<Strip>.stride, index: 2)
            enc.setBuffer(tmp, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: w, height: n + 2 * halo, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            enc.setComputePipelineState(gainPass)
            t.ks.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 4) }
            t.slope.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 5) }
            switch output {
            case .edr(let buffer, _), .pq(let buffer, _): enc.setBuffer(buffer, offset: 0, index: 6)
            default: enc.setBuffer(out, offset: 0, index: 6)
            }
            enc.dispatchThreads(MTLSize(width: w, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()          // the strip is drawn into again next
            if let error = cb.error { throw Failure.gpu("\(error)") }
            gpuS += Date().timeIntervalSince(t1)
            switch output {
            case .codes(let d), .plane(let d):
                guard d.count >= (y0 + n) * w * bytesOut, let base = d.baseAddress, let out else { throw Failure.gpu("no room for the map") }
                memcpy(base + y0 * w * bytesOut, out.contents(), n * w * bytesOut)
            case .edr, .pq: break
            }
            y0 += n
        }
    }

    /// The export's map at full size: 8-bit codes against H (the export's own, D8; `tables` the session's).
    static func codes(of image: CGImage, tables: HDRGrainGain.Tables, sigma: Double? = nil,
                      device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> Data {
        gate.lock(); defer { gate.unlock() }
        guard let device else { throw Failure.gpu("no Metal device") }
        var codes = Data(count: image.width * image.height)
        let s = sigma ?? HDRGrainGain.sigma(for: image)
        try codes.withUnsafeMutableBytes { try run(image, tables: tables, sigma: s, into: .codes($0), device: device) }
        return codes
    }

    // MARK: the display pass (PRD-B, 2026-11-09)

    /// A page picture made ready for its display pass: its pixels (16-bit Display P3, as the kernels read them) and
    /// its log2 gain (`hg_plane`, the export's kernel to the line), both on the GPU. Made once a picture and a look;
    /// the screen's share is applied by `show`, which is all a window moving to another screen, or the headroom
    /// changing, re-runs: never the engine, never the blur. 12 B a pixel kept (59 MB for a 4.9 MP canvas).
    final class Prepared: @unchecked Sendable {
        let width: Int, height: Int
        let headroom: Double
        fileprivate let src: MTLBuffer, plane: MTLBuffer
        fileprivate init(width: Int, height: Int, headroom: Double, src: MTLBuffer, plane: MTLBuffer) {
            self.width = width; self.height = height; self.headroom = headroom; self.src = src; self.plane = plane
        }
    }

    /// `image`'s gain under `look`, kept for its display passes.
    static func prepare(_ image: CGImage, look: HDRLook, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> Prepared {
        gate.lock(); defer { gate.unlock() }
        guard let device else { throw Failure.gpu("no Metal device") }
        let w = image.width, h = image.height
        guard w > 0, h > 0, let src = device.makeBuffer(length: w * h * 8, options: .storageModeShared),
              let plane = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let ctx = CGContext(data: src.contents(), width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { throw Failure.gpu("no room for a \(w) × \(h) picture") }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        try run(image, tables: look.tables, sigma: pageSigma(image, look),
                into: .plane(UnsafeMutableRawBufferPointer(start: plane.contents(), count: w * h * 4)), device: device)
        pageMakes &+= 1
        return Prepared(width: w, height: h, headroom: look.curve.headroom, src: src, plane: plane)
    }

    /// The display pass: `prepared` at the screen's share `weight` (0 … 1), in UIKit's HDR form (BT.2020 PQ, SDR white
    /// at 203 nits) marked with its peak H^w. **Not a roll-off**: ISO 21496-1's weight scales the curve's gain, the
    /// one stage that owns the highlights' roll-off (the engine's family-A shoulder and the kernels' clamped base);
    /// the peak never exceeds the headroom it was weighted for, so the compositor has nothing to clip or tone-map.
    static func show(_ prepared: Prepared, weight: Double, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> CGImage {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *), let space = hdrSpace else { throw Failure.gpu("no HDR colour space") }
        guard let device else { throw Failure.gpu("no Metal device") }
        let w = prepared.width, h = prepared.height
        guard let out = device.makeBuffer(length: w * h * 8, options: .storageModeShared) else { throw Failure.gpu("no room for the picture") }
        let (pass, queue) = try pipeline("hg_show_pq", on: device)
        struct Show { var width: UInt32; var height: UInt32; var weight: Float }
        var p = Show(width: UInt32(w), height: UInt32(h), weight: Float(min(1, max(0, weight))))
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw Failure.gpu("no command buffer") }
        enc.setComputePipelineState(pass)
        enc.setBuffer(prepared.src, offset: 0, index: 0)
        enc.setBuffer(prepared.plane, offset: 0, index: 1)
        enc.setBytes(&p, length: MemoryLayout<Show>.stride, index: 2)
        enc.setBuffer(out, offset: 0, index: 3)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw Failure.gpu("\(error)") }
        let held = Unmanaged.passRetained(out as AnyObject)
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: out.contents(), size: w * h * 8,
                                            releaseData: { info, _, _ in Unmanaged<AnyObject>.fromOpaque(info!).release() })
        else { held.release(); throw Failure.gpu("no data provider") }
        guard let made = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw Failure.gpu("no image") }
        let peak = pow(max(prepared.headroom, 1), min(1, max(0, weight)))
        return CGImageCreateCopyWithContentHeadroom(Float(peak), made) ?? made
    }

    /// log2 gain at full size as Float: the checks' measure.
    static func plane(of image: CGImage, tables: HDRGrainGain.Tables, sigma: Double? = nil,
                      device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> [Float] {
        gate.lock(); defer { gate.unlock() }
        guard let device else { throw Failure.gpu("no Metal device") }
        var values = [Float](repeating: 0, count: image.width * image.height)
        let s = sigma ?? HDRGrainGain.sigma(for: image)
        try values.withUnsafeMutableBytes { try run(image, tables: tables, sigma: s, into: .plane($0), device: device) }
        return values
    }

}
