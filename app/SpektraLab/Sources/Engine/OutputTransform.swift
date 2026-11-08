//  OutputTransform.swift — the one conversion out of the working space.
//
//  The engine renders into its working space (ProPhoto RGB, encoded) and
//  leaves that space to its host: one conversion per destination, with the
//  engine's own numbers (`spk_output_transform`, RFC-018 §5.2) — Display P3
//  for a page, the recipe's space for a file.
//
//      working (ProPhoto, encoded)
//        → the working space's curve, off
//        → 3 × 3 linear, chromatically adapted
//        → CAM16-UCS gamut compression into the target
//        → the target's curve, on
//
//  **The kernel is the desktop app's** (`Canvas/Shaders.metal`,
//  `outputTransform`, the maintainer's; UPSTREAM.md), which is itself a port of
//  the engine's `nodes.metal` and `gamut.metal`. It is carried over statement
//  for statement: a second implementation of ProPhoto's linear toe or of
//  CAM16's inverse would be a second chance to get a breakpoint wrong, and the
//  disagreement would look like a grading decision. Handing the picture to
//  ColorSync instead (tagged ProPhoto, converted by the system) would clip
//  what this rolls off: a different picture.
//
//  Two things differ from the desktop's, neither in the arithmetic:
//
//  - **It is compiled here, at run time, with safe math** — from the source
//    below, through `MTLDevice.makeLibrary(source:)`. No `.metal` file may be
//    in this target (`gen_project.py`: an Xcode target compiles kernels with
//    fast math, and the engine's must never be), and a string keeps that rule
//    whole while the app has a kernel of its own.
//  - **It writes a buffer, not a texture**: tightly packed, in shared memory a
//    `CGImage` is then made over without a copy. The simulator's Metal has no
//    shared textures to read back. 16 bits a channel for a page and for a
//    16-bit file; **8 bits for a file that holds 8** (`Depth`), written by
//    the kernel itself from the same numbers — half the memory of a 16-bit
//    picture reduced afterwards, and one rounding, made here, where a
//    reduction left to the encoder is whatever the encoder does.
//
//  As the desktop does, the lightness stage of the compression is left off:
//  the engine has already run it once, before it encoded the working space
//  (`Pipeline::print_linear`), and a second pass compressed an export's
//  highlights. The chroma knee stays: this is the conversion into the
//  destination's gamut.
//
//  Every call is on the engine's queue.

#if SPK_ENGINE
import CoreGraphics
import Foundation
import Metal

final class OutputTransformer {
    /// Where a picture is going. The names are the engine's (`core/colour.cpp`).
    enum Target: String, Sendable {
        case displayP3 = "Display P3", sRGB = "sRGB", adobeRGB = "Adobe RGB (1998)", proPhoto = "ProPhoto RGB"

        /// The space a picture is tagged with: the profile its file carries.
        var colorSpace: CGColorSpace {
            switch self {
            case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
            case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            case .proPhoto: CGColorSpace(name: CGColorSpace.rommrgb)!
            }
        }
    }

    /// The bits a channel of the picture is written in.
    /// (A recipe's colour as a target is `Target(_:)`, below.)
    enum Depth: Int, Sendable {
        case eight = 8, sixteen = 16
        var bytesPerPixel: Int { rawValue / 2 }
        var kernel: String { self == .eight ? "spkOutputTransform8" : "spkOutputTransform" }
    }

    /// The export transform's CAM16 setting: the chroma knee, without the
    /// lightness stage the engine has already applied (the header).
    static let withoutLightness = #"{"lightness_compression_active": false}"#
    /// The session's working space. Read from the open reply on the desktop;
    /// this app never sends another (`ENGINE-WIRING.md` §4.2).
    static let workingSpace = "ProPhoto RGB"

    /// One destination's uniform block and its C_max table. Internal for the
    /// export's Layer 2 pass, which runs this transform inside its own kernel
    /// (`Layer2Export.swift`).
    struct Setup {
        var uniforms: [UInt8]
        var cmax: MTLBuffer
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var library: MTLLibrary?
    private var pipelines: [Depth: MTLComputePipelineState] = [:]
    private var setups: [Target: Setup] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw EngineError.failed("no command queue for the output transform") }
        self.queue = queue
    }

    /// The picture in `target`, as a `CGImage` over the bytes the kernel
    /// wrote: 16 bits a channel, or 8 for a file that holds 8. `fetch` asks
    /// the engine for a destination's numbers, once per destination.
    func image(_ pixels: RenderedPixels, to target: Target, depth: Depth = .sixteen,
               fetch: (String, String, String?) throws -> SpkEngine.OutputTransformData) throws -> CGImage {
        if setups[target] == nil {
            setups[target] = try setup(fetch(Self.workingSpace, target.rawValue, Self.withoutLightness))
        }
        guard let setup = setups[target] else { throw EngineError.failed("no output transform for \(target.rawValue)") }
        return try image(texture: pixels.texture, width: pixels.size.width, height: pixels.size.height,
                         setup: setup, space: target.colorSpace, depth: depth)
    }

    /// The kernel on any 16-bit picture with any pair of spaces' numbers (`setup`): a page's own picture
    /// from the working space, or a page's Display P3 picture proofed into a smaller space (`GamutProof`).
    func image(texture: MTLTexture, width w: Int, height h: Int, setup: Setup, space: CGColorSpace,
               depth: Depth = .sixteen) throws -> CGImage {
        guard w > 0, h > 0 else { throw EngineError.failed("an empty picture") }
        let pipeline = try state(depth)
        let bytes = w * h * depth.bytesPerPixel
        guard bytes <= device.maxBufferLength, let out = device.makeBuffer(length: bytes, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw EngineError.resource("no \(bytes >> 20) MB buffer for the picture")
        }
        var uniforms = setup.uniforms
        // The last two words of the block: the picture's width, and a spare.
        withUnsafeBytes(of: UInt32(w)) { uniforms.replaceSubrange((uniforms.count - 8)..<(uniforms.count - 4), with: $0) }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(uniforms, length: uniforms.count, index: 0)
        encoder.setBuffer(setup.cmax, offset: 0, index: 1)
        encoder.setBuffer(out, offset: 0, index: 2)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw EngineError.failed("the output transform failed: \(error.localizedDescription)") }

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
                                  bytesPerRow: w * depth.bytesPerPixel,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw EngineError.failed("the picture could not be made")
        }
        return image
    }

    // MARK: the kernel, and its numbers

    private func state(_ depth: Depth) throws -> MTLComputePipelineState {
        if let pipeline = pipelines[depth] { return pipeline }
        if library == nil {
            let options = MTLCompileOptions()
            // Safe math, as the engine's own kernels are compiled: no reassociation, no contraction
            // the source does not ask for, and the library's precise functions.
            if #available(iOS 18.0, macCatalyst 18.0, *) {
                options.mathMode = .safe
                options.mathFloatingPointFunctions = .precise
            } else {
                options.fastMathEnabled = false
            }
            library = try device.makeLibrary(source: Self.source, options: options)
        }
        guard let function = library?.makeFunction(name: depth.kernel) else {
            throw EngineError.failed("the output transform's kernel is missing")
        }
        let made = try device.makeComputePipelineState(function: function)
        pipelines[depth] = made
        return made
    }

    /// The uniform block, byte for byte as the kernel's struct lays it out:
    /// 49 floats, then 8 unsigned words.
    func setup(_ d: SpkEngine.OutputTransformData) throws -> Setup {
        guard d.matrix.count == 9, d.toXYZ.count == 9, d.toRGB.count == 9, d.k.count == 22,
              d.cmax.count == d.cmaxRows * d.cmaxColumns,
              let cmax = device.makeBuffer(bytes: d.cmax, length: d.cmax.count * MemoryLayout<Float>.size,
                                           options: .storageModeShared) else {
            throw EngineError.failed("the output transform's numbers did not fit")
        }
        var bytes: [UInt8] = []
        for f in d.matrix + d.toXYZ + d.toRGB + d.k { withUnsafeBytes(of: f) { bytes.append(contentsOf: $0) } }
        let words: [UInt32] = [d.sourceCctfMode, d.targetCctfMode, d.compresses ? 1 : 0, d.compressesLightness ? 1 : 0,
                               UInt32(d.cmaxRows), UInt32(d.cmaxColumns), 0, 0]
        for u in words { withUnsafeBytes(of: u) { bytes.append(contentsOf: $0) } }
        return Setup(uniforms: bytes, cmax: cmax)
    }

    /// The desktop's `outputTransform` (`Canvas/Shaders.metal`), with its
    /// output a buffer of 16-bit values. The transfer functions and the CAM16
    /// body are not to be tidied: each oddity is the reference's own, kept so
    /// that this is the measured kernel and not a cousin of it.
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct OutputTransformUniforms {
        float matrix[9];        // source linear RGB -> target linear RGB, row-major
        float cam16M2X[9];      // the target's RGB <-> XYZ pair with adaptation
        float cam16M2R[9];
        float cam16K[22];       // the 22 scalars the CAM16 body reads
        uint  sourceCctfMode;   // as the engine's kernels number the curves
        uint  targetCctfMode;
        uint  cam16Active;      // 0: the compression step is skipped
        uint  cam16Lightness;   // the lightness compression's own gate
        uint  cmaxNL;
        uint  cmaxNH;
        uint  width;            // the picture's width: the output's row length
        uint  _pad;
    };

    // Signed power: |v|**p with v's sign kept, where the reference uses it.
    inline float spow(float v, float p) {
        float s = v < 0.0f ? -1.0f : (v > 0.0f ? 1.0f : 0.0f);
        return s * pow(fabs(v), p);
    }

    // 0 sRGB (and Display P3), 1 ProPhoto RGB, 2 Adobe RGB (1998), 3 BT.709/BT.2020, 4 identity.
    // The breakpoints are the reference's exact ones, not the spec's printed roundings.
    static inline float cctf_decode_mode(float v, uint mode) {
        switch (mode) {
            case 0u: return (0.040449936f >= v) ? v / 12.92f : spow((v + 0.055f) / 1.055f, 2.4f);
            case 1u: return (v < 16.0f * (1.0f / 512.0f)) ? v / 16.0f : pow(v, 1.8f);
            case 2u: return pow(v, 563.0f / 256.0f);
            case 3u: {
                const float alpha = 1.099f, beta = 0.018f;
                const float bp = alpha * pow(beta, 0.45f) - (alpha - 1.0f);
                return (bp > v) ? v / 4.5f : spow((v + (alpha - 1.0f)) / alpha, 1.0f / 0.45f);
            }
            default: return v;
        }
    }

    static inline float cctf_encode_mode(float v, uint mode) {
        switch (mode) {
            case 0u: return (v <= 0.0031308f) ? 12.92f * v : 1.055f * spow(v, 1.0f / 2.4f) - 0.055f;
            case 1u: return (v < 1.0f / 512.0f) ? v * 16.0f : pow(v, 1.0f / 1.8f);
            case 2u: return pow(v, 256.0f / 563.0f);
            case 3u: {
                const float alpha = 1.099f, beta = 0.018f;
                return (beta > v) ? v * 4.5f : alpha * spow(v, 0.45f) - (alpha - 1.0f);
            }
            default: return v;
        }
    }

    // CAM16-UCS gamut compression into the target, per pixel, in linear RGB: the engine's
    // `gamut.metal`, its buffer reads become the uniform and `cmax` reads here. Three of the
    // reference's traps are reproduced deliberately: the sign-preserving power for J, the
    // 460/1403 family of normalisation factors in the inverse (a, b) solve, and a hue index
    // wrapped the way Python's `%` wraps it.
    static inline float3 cam16ucsInto(float3 rgb, constant OutputTransformUniforms &u, device const float *cmax) {
        const uint nL = u.cmaxNL, nh = u.cmaxNH, lc_active = u.cam16Lightness;
        const float F_L = u.cam16K[0], N_bb = u.cam16K[1], N_cb = u.cam16K[2], n_ = u.cam16K[3],
                    z = u.cam16K[4], A_w = u.cam16K[5], c_ = u.cam16K[6], N_c = u.cam16K[7];
        const float L_grid0 = u.cam16K[8], L_grid1 = u.cam16K[9], h_grid0 = u.cam16K[10], h_step = u.cam16K[11];
        const float threshold = u.cam16K[12], limit = u.cam16K[13], power_ = u.cam16K[14];
        const float lc_threshold = u.cam16K[15], lc_limit = u.cam16K[16], lc_power = u.cam16K[17], L_white = u.cam16K[18];
        const float D0 = u.cam16K[19], D1 = u.cam16K[20], D2 = u.cam16K[21];
        const float e_c = pow(1.64f - pow(0.29f, n_), 0.73f);
        const float inv_FL4 = pow(F_L, 0.25f);

        float r = rgb.x, g = rgb.y, b_ = rgb.z;
        float X = u.cam16M2X[0] * r + u.cam16M2X[1] * g + u.cam16M2X[2] * b_;
        float Y = u.cam16M2X[3] * r + u.cam16M2X[4] * g + u.cam16M2X[5] * b_;
        float Z = u.cam16M2X[6] * r + u.cam16M2X[7] * g + u.cam16M2X[8] * b_;
        X *= 100.0f; Y *= 100.0f; Z *= 100.0f;

        float R = 0.401288f * X + 0.650173f * Y - 0.051461f * Z;
        float G = -0.250268f * X + 1.204414f * Y + 0.045854f * Z;
        float B = -0.002079f * X + 0.048952f * Y + 0.953127f * Z;

        float Rc = D0 * R, Gc = D1 * G, Bc = D2 * B;
        float sR = Rc >= 0.0f ? 1.0f : -1.0f, sG = Gc >= 0.0f ? 1.0f : -1.0f, sB = Bc >= 0.0f ? 1.0f : -1.0f;
        float fR = pow(F_L * fabs(Rc) / 100.0f, 0.42f);
        float fG = pow(F_L * fabs(Gc) / 100.0f, 0.42f);
        float fB = pow(F_L * fabs(Bc) / 100.0f, 0.42f);
        float Ra = 400.0f * sR * fR / (27.13f + fR) + 0.1f;
        float Ga = 400.0f * sG * fG / (27.13f + fG) + 0.1f;
        float Ba = 400.0f * sB * fB / (27.13f + fB) + 0.1f;

        float a = Ra - 12.0f * Ga / 11.0f + Ba / 11.0f;
        float bb = (Ra + Ga - 2.0f * Ba) / 9.0f;
        float hrad = atan2(bb, a);
        float e_t = 0.25f * (cos(hrad + 2.0f) + 3.8f);

        float A = (2.0f * Ra + Ga + Ba / 20.0f - 0.305f) * N_bb;
        float Aratio = A / A_w;
        float sJ = Aratio >= 0.0f ? 1.0f : -1.0f;
        float J = 100.0f * sJ * pow(fabs(Aratio), c_ * z);

        float den = Ra + Ga + 21.0f * Ba / 20.0f;
        float t = 0.0f;
        if (den != 0.0f) t = (50000.0f / 13.0f * N_c * N_cb * e_t * sqrt(a * a + bb * bb)) / den;
        float sq = sqrt(fabs(J) / 100.0f);
        float C = (t > 0.0f) ? pow(t, 0.9f) * sq * e_c : 0.0f;
        float M = C * inv_FL4;

        float Mp = (1.0f / 0.0228f) * log(1.0f + 0.0228f * M);
        float Jp = 1.7f * J / (1.0f + 0.007f * J);

        if (lc_active != 0u) {
            float Ln = Jp / L_white;
            if (Ln > lc_threshold) {
                float lsc = lc_limit - lc_threshold;
                float lx = (Ln - lc_threshold) / lsc;
                float ly = lx / pow(1.0f + pow(lx, lc_power), 1.0f / lc_power);
                Ln = lc_threshold + lsc * ly;
            }
            Jp = Ln * L_white;
        }

        float Lc = min(max(Jp, L_grid0), L_grid1);
        float Li = (Lc - L_grid0) / (L_grid1 - L_grid0) * (float)(nL - 1u);
        int l0 = (int)floor(Li); l0 = min(max(l0, 0), (int)nL - 2);
        float lf = Li - (float)l0;
        float hi_ = (hrad - h_grid0) / h_step;
        float hfl = floor(hi_);
        int nhi = (int)nh;
        int h0 = ((int)hfl % nhi + nhi) % nhi;     // Python-style modulo
        int h1 = (h0 + 1) % nhi;
        float hf = hi_ - hfl;
        float c00 = cmax[l0 * nhi + h0], c01 = cmax[l0 * nhi + h1];
        float c10 = cmax[(l0 + 1) * nhi + h0], c11 = cmax[(l0 + 1) * nhi + h1];
        float Cmax = (1.0f - lf) * ((1.0f - hf) * c00 + hf * c01) + lf * ((1.0f - hf) * c10 + hf * c11);
        float safe = Cmax > 1e-9f ? Cmax : 1e-9f;

        float d = Mp / safe;
        if (d > threshold) {
            float sc = limit - threshold;
            float xk = (d - threshold) / sc;
            float yk = xk / pow(1.0f + pow(xk, power_), 1.0f / power_);
            d = threshold + sc * yk;
        }
        float Mp_new = d * safe;

        float M_new = (exp(Mp_new * 0.0228f) - 1.0f) / 0.0228f;
        float J_new = Jp / (1.7f - 0.007f * Jp);
        float C_new = M_new / inv_FL4;

        float sJ2 = J_new >= 0.0f ? 1.0f : -1.0f;
        float A2 = A_w * sJ2 * pow(fabs(J_new) / 100.0f, 1.0f / (c_ * z));
        float sq2 = sqrt(fabs(J_new) / 100.0f);
        float t2 = (sq2 > 0.0f && C_new > 0.0f) ? pow(C_new / (sq2 * e_c), 1.0f / 0.9f) : 0.0f;
        float ca = cos(hrad), sa = sin(hrad);
        float p2 = A2 / N_bb + 0.305f;
        const float p3 = 21.0f / 20.0f;
        float a2, b2;
        if (t2 == 0.0f) { a2 = 0.0f; b2 = 0.0f; }
        else {
            float p1 = ((50000.0f / 13.0f) * N_c * N_cb * e_t) / t2;
            if (fabs(sa) >= fabs(ca)) {
                float p4 = p1 / sa;
                b2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                     (p4 + (2.0f + p3) * (220.0f / 1403.0f) * (ca / sa) - (27.0f / 1403.0f) + p3 * (6300.0f / 1403.0f));
                a2 = b2 * (ca / sa);
            } else {
                float p5 = p1 / ca;
                a2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                     (p5 + (2.0f + p3) * (220.0f / 1403.0f) - ((27.0f / 1403.0f) - p3 * (6300.0f / 1403.0f)) * (sa / ca));
                b2 = a2 * (sa / ca);
            }
        }
        float Ra2 = (460.0f * p2 + 451.0f * a2 + 288.0f * b2) / 1403.0f;
        float Ga2 = (460.0f * p2 - 891.0f * a2 - 261.0f * b2) / 1403.0f;
        float Ba2 = (460.0f * p2 - 220.0f * a2 - 6300.0f * b2) / 1403.0f;

        float vm, sv, base_;
        vm = Ra2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
        base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
        float Rf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D0;
        vm = Ga2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
        base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
        float Gf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D1;
        vm = Ba2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
        base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
        float Bf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D2;

        float Xn = 1.86206786f * Rf - 1.01125463f * Gf + 0.14918677f * Bf;
        float Yn = 0.38752654f * Rf + 0.62144744f * Gf - 0.00897398f * Bf;
        float Zn = -0.01584150f * Rf - 0.03412294f * Gf + 1.04996444f * Bf;
        Xn /= 100.0f; Yn /= 100.0f; Zn /= 100.0f;

        return float3(u.cam16M2R[0] * Xn + u.cam16M2R[1] * Yn + u.cam16M2R[2] * Zn,
                      u.cam16M2R[3] * Xn + u.cam16M2R[4] * Yn + u.cam16M2R[5] * Zn,
                      u.cam16M2R[6] * Xn + u.cam16M2R[7] * Yn + u.cam16M2R[8] * Zn);
    }

    // What a 16-bit container holds of an encoded value: its limits, and a number where there
    // was none (a NaN is not a colour; it is written as black rather than as whatever the cast gives).
    static inline ushort to16(float v) {
        if (!(v == v)) return (ushort)0;
        return (ushort)(clamp(v, 0.0f, 1.0f) * 65535.0f + 0.5f);
    }

    // The same of an 8-bit container. One rounding, to the nearest of its 256 values.
    static inline uchar to8(float v) {
        if (!(v == v)) return (uchar)0;
        return (uchar)(clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f);
    }

    // One pixel, out of the working space and into the target's own encoding: the four steps,
    // for both containers.
    static inline float3 spkTransformed(float3 c, constant OutputTransformUniforms &u, device const float *cmax) {
        // 1. the working space's own curve, off
        float3 v = float3(cctf_decode_mode(c.r, u.sourceCctfMode),
                          cctf_decode_mode(c.g, u.sourceCctfMode),
                          cctf_decode_mode(c.b, u.sourceCctfMode));
        // 2. into the target, linearly, chromatically adapted
        float3 lin = float3(u.matrix[0] * v.x + u.matrix[1] * v.y + u.matrix[2] * v.z,
                            u.matrix[3] * v.x + u.matrix[4] * v.y + u.matrix[5] * v.z,
                            u.matrix[6] * v.x + u.matrix[7] * v.y + u.matrix[8] * v.z);
        // 3. CAM16-UCS into the target's gamut, rolling rather than cutting
        if (u.cam16Active != 0u) lin = cam16ucsInto(lin, u, cmax);
        // 4. the target's curve, on
        return float3(cctf_encode_mode(lin.x, u.targetCctfMode),
                      cctf_encode_mode(lin.y, u.targetCctfMode),
                      cctf_encode_mode(lin.z, u.targetCctfMode));
    }

    kernel void spkOutputTransform(texture2d<float, access::read> src [[texture(0)]],
                                   constant OutputTransformUniforms &u [[buffer(0)]],
                                   device const float *cmax [[buffer(1)]],
                                   device ushort *dst [[buffer(2)]],
                                   uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.width || gid.x >= src.get_width() || gid.y >= src.get_height()) return;
        float3 e = spkTransformed(src.read(gid).rgb, u, cmax);
        uint i = (gid.y * u.width + gid.x) * 4u;
        dst[i]      = to16(e.x);
        dst[i + 1u] = to16(e.y);
        dst[i + 2u] = to16(e.z);
        dst[i + 3u] = (ushort)65535;
    }

    kernel void spkOutputTransform8(texture2d<float, access::read> src [[texture(0)]],
                                    constant OutputTransformUniforms &u [[buffer(0)]],
                                    device const float *cmax [[buffer(1)]],
                                    device uchar *dst [[buffer(2)]],
                                    uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.width || gid.x >= src.get_width() || gid.y >= src.get_height()) return;
        float3 e = spkTransformed(src.read(gid).rgb, u, cmax);
        uint i = (gid.y * u.width + gid.x) * 4u;
        dst[i]      = to8(e.x);
        dst[i + 1u] = to8(e.y);
        dst[i + 2u] = to8(e.z);
        dst[i + 3u] = (uchar)255;
    }
    """#
}
extension OutputTransformer.Target {
    /// The space a recipe names. By the engine's own name for it, so a recipe
    /// and its file cannot come to mean two spaces.
    init(_ colour: ExportRecipe.Colour) {
        switch colour {
        case .sRGB: self = .sRGB
        case .adobeRGB: self = .adobeRGB
        case .displayP3: self = .displayP3
        case .proPhoto: self = .proPhoto
        }
    }
}
#endif
