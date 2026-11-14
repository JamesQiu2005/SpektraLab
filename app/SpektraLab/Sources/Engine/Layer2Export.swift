//  Layer2Export.swift — Edit's Light, Curve and Colour, baked into an export.
//
//  design/v5 §3.5: every export bakes the layer, and the preview and the
//  export are the same maths at two sizes. The page adjusts its develop —
//  the engine's render taken into Display P3 by the output transform, 16 bits
//  a channel — so an export does exactly that to its full render, and only
//  then goes on to the recipe's space:
//
//      the engine's render (ProPhoto, encoded)
//        → Display P3, by the output transform, held to 16 bits   = the page's picture
//        → Layer 2, the page's pass (`Layer2Kernel.functions`)    = what the page shows
//        → the recipe's space, by the output transform from Display P3, at the file's depth
//
//  For a Display P3 recipe — the one the app starts with — the third step is
//  none: the file is what the page shows, at the file's size, to the last
//  rounding. For another space it is one transform more, with the engine's
//  own numbers (`spk_output_transform`, from "Display P3"). **What this costs
//  a wide recipe**: an edited frame is the picture as the page shows it, so a
//  ProPhoto or Adobe RGB file of it holds no colour outside Display P3's (the
//  first step's gamut compression has rolled them in). An unedited frame is
//  unchanged: it never comes here (`EngineHost.deliver`).
//
//  **No plane is added.** The three steps are one kernel, pixel by pixel,
//  from the engine's result straight into the file's buffer, which the plain
//  transform writes anyway: a 48 MP export holds what it held before, and the
//  pass's own memory is two uniform blocks, two C_max tables and the curve
//  table (well under a megabyte).
//
//  Compiled at run time with safe math, from the output transform's own
//  source and Layer 2's (`OutputTransformer.source`, `Layer2Kernel.functions`):
//  no `.metal` file in this target. Every call is on the engine's queue.
//
//  **With 成片 layers** (PRD-E, RFC-052 §7; `Layer2Local`) the same three steps run in `spkLayer2OutLocal` /
//  `spkLayer2Out8Local`: the pass is `l2LocalApply`, its mask read at the pixel's place on the engine's result —
//  before the host's quarter turns, as the vignette's `uv` is — through `FinishedLayers.matrix(turnsAfter:)`. The
//  layers' planes are the job's only addition: 16 bits a texel at L_c = min(4096, the source's long edge), at most
//  eight (22 MB each for a 3:2 frame), the same buffers the page reads (`MaskBaker`'s store). With none, today's two
//  kernels, untouched.

#if SPK_ENGINE
import CoreGraphics
import Foundation
import Metal

final class Layer2Export {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// For its uniform blocks: the same bytes the plain transform runs with.
    private let transformer: OutputTransformer
    private var library: MTLLibrary?
    private var pipelines: [OutputTransformer.Depth: MTLComputePipelineState] = [:]
    private var localLibrary: MTLLibrary?
    private var localPipelines: [OutputTransformer.Depth: MTLComputePipelineState] = [:]
    private var setups: [String: OutputTransformer.Setup] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw EngineError.failed("no command queue for Layer 2's export") }
        self.queue = queue
        transformer = try OutputTransformer(device: device)
    }

    /// The export's picture with `adjustments`, in `target` at `depth`: a
    /// `CGImage` over the bytes the kernel wrote, as `OutputTransformer.image` makes it.
    /// `local` is the file's 成片 layers for this surface (the engine's result before the host's turns): nil, today's.
    func image(_ pixels: RenderedPixels, to target: OutputTransformer.Target, depth: OutputTransformer.Depth,
               adjustments: Adjustments, local: Layer2LocalPass? = nil,
               fetch: (String, String, String?) throws -> SpkEngine.OutputTransformData) throws -> CGImage {
        let w = pixels.size.width, h = pixels.size.height
        guard w > 0, h > 0 else { throw EngineError.failed("an empty picture") }
        let pipeline = try local == nil ? state(depth) : localState(depth)
        let page = try setup(OutputTransformer.workingSpace, OutputTransformer.Target.displayP3.rawValue, fetch)
        let direct = target == .displayP3
        let file = direct ? page : try setup(OutputTransformer.Target.displayP3.rawValue, target.rawValue, fetch)
        let bytes = w * h * depth.bytesPerPixel
        let tables = adjustments.curves.tables()
        guard bytes <= device.maxBufferLength, let out = device.makeBuffer(length: bytes, options: .storageModeShared),
              let curves = device.makeBuffer(bytes: tables, length: tables.count * 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw EngineError.resource("no \(bytes >> 20) MB buffer for the picture")
        }
        func widthed(_ block: [UInt8]) -> [UInt8] {
            // The last two words of the block: the picture's width, and a spare.
            var b = block
            withUnsafeBytes(of: UInt32(w)) { b.replaceSubrange((b.count - 8)..<(b.count - 4), with: $0) }
            return b
        }
        let toPage = widthed(page.uniforms), toFile = widthed(file.uniforms)
        var u = adjustments.uniforms()
        var straight: UInt32 = direct ? 1 : 0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(pixels.texture, index: 0)
        encoder.setBytes(toPage, length: toPage.count, index: 0)
        encoder.setBuffer(page.cmax, offset: 0, index: 1)
        encoder.setBuffer(out, offset: 0, index: 2)
        encoder.setBytes(toFile, length: toFile.count, index: 3)
        encoder.setBuffer(file.cmax, offset: 0, index: 4)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 5)
        encoder.setBuffer(curves, offset: 0, index: 6)
        encoder.setBytes(&straight, length: 4, index: 7)
        local?.bind(encoder, at: 8)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw EngineError.failed("Layer 2's export pass failed: \(error.localizedDescription)") }

        // The image holds the buffer for as long as it lives; nothing is copied.
        let held = Unmanaged.passRetained(out as AnyObject)
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: out.contents(), size: bytes,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
                                            }) else {
            held.release()
            throw EngineError.failed("no data provider for the picture")
        }
        let order = depth == .sixteen ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        let info = CGBitmapInfo(rawValue: order | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let image = CGImage(width: w, height: h, bitsPerComponent: depth.rawValue, bitsPerPixel: depth.rawValue * 4,
                                  bytesPerRow: w * depth.bytesPerPixel, space: target.colorSpace, bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw EngineError.failed("the picture could not be made")
        }
        return image
    }

    private func setup(_ source: String, _ target: String,
                       _ fetch: (String, String, String?) throws -> SpkEngine.OutputTransformData) throws -> OutputTransformer.Setup {
        let key = source + "→" + target
        if let made = setups[key] { return made }
        let made = try transformer.setup(fetch(source, target, OutputTransformer.withoutLightness))
        setups[key] = made
        return made
    }

    private func state(_ depth: OutputTransformer.Depth) throws -> MTLComputePipelineState {
        if let pipeline = pipelines[depth] { return pipeline }
        if library == nil {
            do {
                library = try device.makeLibrary(source: OutputTransformer.source + "\n" + Layer2Kernel.functions + "\n" + Self.kernels,
                                                 options: Layer2Kernel.options())
            } catch {
                throw EngineError.failed("Layer 2's export kernels did not compile: \(error)")
            }
        }
        guard let function = library?.makeFunction(name: depth == .eight ? "spkLayer2Out8" : "spkLayer2Out") else {
            throw EngineError.failed("Layer 2's export kernel is missing")
        }
        let made = try device.makeComputePipelineState(function: function)
        pipelines[depth] = made
        return made
    }

    private func localState(_ depth: OutputTransformer.Depth) throws -> MTLComputePipelineState {
        if let pipeline = localPipelines[depth] { return pipeline }
        if localLibrary == nil {
            do {
                localLibrary = try device.makeLibrary(source: OutputTransformer.source + "\n" + Layer2Kernel.functions + "\n" + Layer2Local.functions
                                                      + "\n" + Self.kernels + "\n" + Self.localKernels, options: Layer2Kernel.options())
            } catch {
                throw EngineError.failed("Layer 2's local export kernels did not compile: \(error)")
            }
        }
        guard let function = localLibrary?.makeFunction(name: depth == .eight ? "spkLayer2Out8Local" : "spkLayer2OutLocal") else {
            throw EngineError.failed("Layer 2's local export kernel is missing")
        }
        let made = try device.makeComputePipelineState(function: function)
        localPipelines[depth] = made
        return made
    }

    /// The three steps, one pixel at a time; the output transform's helpers
    /// (`spkTransformed`, `to16`, `to8`) are its own source's, compiled beside.
    static let kernels = #"""
    // The page's picture (Display P3, held to 16 bits), with Layer 2, in the file's space.
    static inline float3 l2Exported(float3 working, uint2 gid, uint2 size,
                                    constant OutputTransformUniforms &toPage, device const float *cmaxPage,
                                    constant OutputTransformUniforms &toFile, device const float *cmaxFile,
                                    constant Layer2Uniforms &u, device const float *curves, uint direct) {
        float3 p = spkTransformed(working, toPage, cmaxPage);
        p = select(p, float3(0.0f), isnan(p));
        p = floor(saturate(p) * 65535.0f + 0.5f) / 65535.0f;
        float2 uv = (float2(gid) + 0.5f) / float2(size);
        p = l2Apply(p, uv, u, curves);
        return direct != 0u ? p : spkTransformed(p, toFile, cmaxFile);
    }

    kernel void spkLayer2Out(texture2d<float, access::read> src [[texture(0)]],
                             constant OutputTransformUniforms &toPage [[buffer(0)]],
                             device const float *cmaxPage [[buffer(1)]],
                             device ushort *dst [[buffer(2)]],
                             constant OutputTransformUniforms &toFile [[buffer(3)]],
                             device const float *cmaxFile [[buffer(4)]],
                             constant Layer2Uniforms &u [[buffer(5)]],
                             device const float *curves [[buffer(6)]],
                             constant uint &direct [[buffer(7)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        uint2 size = uint2(src.get_width(), src.get_height());
        if (gid.x >= toPage.width || gid.x >= size.x || gid.y >= size.y) return;
        float3 e = l2Exported(src.read(gid).rgb, gid, size, toPage, cmaxPage, toFile, cmaxFile, u, curves, direct);
        uint i = (gid.y * toPage.width + gid.x) * 4u;
        dst[i]      = to16(e.x);
        dst[i + 1u] = to16(e.y);
        dst[i + 2u] = to16(e.z);
        dst[i + 3u] = (ushort)65535;
    }

    kernel void spkLayer2Out8(texture2d<float, access::read> src [[texture(0)]],
                              constant OutputTransformUniforms &toPage [[buffer(0)]],
                              device const float *cmaxPage [[buffer(1)]],
                              device uchar *dst [[buffer(2)]],
                              constant OutputTransformUniforms &toFile [[buffer(3)]],
                              device const float *cmaxFile [[buffer(4)]],
                              constant Layer2Uniforms &u [[buffer(5)]],
                              device const float *curves [[buffer(6)]],
                              constant uint &direct [[buffer(7)]],
                              uint2 gid [[thread_position_in_grid]])
    {
        uint2 size = uint2(src.get_width(), src.get_height());
        if (gid.x >= toPage.width || gid.x >= size.x || gid.y >= size.y) return;
        float3 e = l2Exported(src.read(gid).rgb, gid, size, toPage, cmaxPage, toFile, cmaxFile, u, curves, direct);
        uint i = (gid.y * toPage.width + gid.x) * 4u;
        dst[i]      = to8(e.x);
        dst[i + 1u] = to8(e.y);
        dst[i + 2u] = to8(e.z);
        dst[i + 3u] = (uchar)255;
    }
    """#

    /// The same with the 成片 layers (`Layer2Local`): the block at 8, the planes at 9–16; the mask read at the
    /// pixel's place on the engine's result, the vignette's `uv`.
    static let localKernels = #"""
    static inline float3 l2ExportedLocal(float3 working, uint2 gid, uint2 size,
                                         constant OutputTransformUniforms &toPage, device const float *cmaxPage,
                                         constant OutputTransformUniforms &toFile, device const float *cmaxFile,
                                         constant Layer2Uniforms &u, device const float *curves, uint direct,
                                         constant Layer2LocalBlock &L,
                                         device const ushort *m0, device const ushort *m1, device const ushort *m2,
                                         device const ushort *m3, device const ushort *m4, device const ushort *m5,
                                         device const ushort *m6, device const ushort *m7) {
        float3 p = spkTransformed(working, toPage, cmaxPage);
        p = select(p, float3(0.0f), isnan(p));
        p = floor(saturate(p) * 65535.0f + 0.5f) / 65535.0f;
        float2 uv = (float2(gid) + 0.5f) / float2(size);
        p = l2LocalApply(p, uv, uv, u, curves, L, m0, m1, m2, m3, m4, m5, m6, m7);
        return direct != 0u ? p : spkTransformed(p, toFile, cmaxFile);
    }

    kernel void spkLayer2OutLocal(texture2d<float, access::read> src [[texture(0)]],
                                  constant OutputTransformUniforms &toPage [[buffer(0)]],
                                  device const float *cmaxPage [[buffer(1)]],
                                  device ushort *dst [[buffer(2)]],
                                  constant OutputTransformUniforms &toFile [[buffer(3)]],
                                  device const float *cmaxFile [[buffer(4)]],
                                  constant Layer2Uniforms &u [[buffer(5)]],
                                  device const float *curves [[buffer(6)]],
                                  constant uint &direct [[buffer(7)]],
                                  constant Layer2LocalBlock &L [[buffer(8)]],
                                  L2_PLANE_PARAMS(9, 10, 11, 12, 13, 14, 15, 16),
                                  uint2 gid [[thread_position_in_grid]])
    {
        uint2 size = uint2(src.get_width(), src.get_height());
        if (gid.x >= toPage.width || gid.x >= size.x || gid.y >= size.y) return;
        float3 e = l2ExportedLocal(src.read(gid).rgb, gid, size, toPage, cmaxPage, toFile, cmaxFile, u, curves, direct, L, L2_PLANES);
        uint i = (gid.y * toPage.width + gid.x) * 4u;
        dst[i]      = to16(e.x);
        dst[i + 1u] = to16(e.y);
        dst[i + 2u] = to16(e.z);
        dst[i + 3u] = (ushort)65535;
    }

    kernel void spkLayer2Out8Local(texture2d<float, access::read> src [[texture(0)]],
                                   constant OutputTransformUniforms &toPage [[buffer(0)]],
                                   device const float *cmaxPage [[buffer(1)]],
                                   device uchar *dst [[buffer(2)]],
                                   constant OutputTransformUniforms &toFile [[buffer(3)]],
                                   device const float *cmaxFile [[buffer(4)]],
                                   constant Layer2Uniforms &u [[buffer(5)]],
                                   device const float *curves [[buffer(6)]],
                                   constant uint &direct [[buffer(7)]],
                                   constant Layer2LocalBlock &L [[buffer(8)]],
                                   L2_PLANE_PARAMS(9, 10, 11, 12, 13, 14, 15, 16),
                                   uint2 gid [[thread_position_in_grid]])
    {
        uint2 size = uint2(src.get_width(), src.get_height());
        if (gid.x >= toPage.width || gid.x >= size.x || gid.y >= size.y) return;
        float3 e = l2ExportedLocal(src.read(gid).rgb, gid, size, toPage, cmaxPage, toFile, cmaxFile, u, curves, direct, L, L2_PLANES);
        uint i = (gid.y * toPage.width + gid.x) * 4u;
        dst[i]      = to8(e.x);
        dst[i + 1u] = to8(e.y);
        dst[i + 2u] = to8(e.z);
        dst[i + 3u] = (uchar)255;
    }
    """#
}
#endif
