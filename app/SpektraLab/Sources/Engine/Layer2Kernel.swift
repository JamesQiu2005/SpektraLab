//  Layer2Kernel.swift — Layer 2's kernels, as a string compiled at run time with safe math.
//
//  **The arithmetic is the desktop's** (`Canvas/Shaders.metal`, `layer2Tone` and
//  the `layer2` kernel, desktop `df355fa`, the maintainer's; UPSTREAM.md),
//  statement for statement, with four differences, none of them a grade:
//
//  - **The values are Display P3's, and the pivot is P3's mid-grey.** The
//    host adjusts the develop as the page shows it and the library keeps it
//    (`DevelopedPicture`: Display P3, the sRGB curve), so `midGrey` is that
//    encoding's 0.4614 (`Layer2Uniforms.displayMidGrey`), where the desktop's
//    canvas holds ProPhoto and pivots on 0.3857.
//  - **A step whose control is at zero is not run.** The desktop runs
//    saturation at 1 and the colour balance at zero, which are the identity in
//    arithmetic and not quite in float (`l + (c − l)` is not always `c`): here
//    a neutral control leaves its input to the bit.
//  - **The curve table is read at its own entries**: entry `i` is the curve at
//    `i / 255`, and a value between two entries is the line between them, in
//    exact float. The desktop samples a 256-wide texture with a linear filter,
//    which reads entry `i` at `(i + 0.5) / 256` — half an entry off — at the
//    filter's own precision.
//  - **Nothing is clamped on the way out.** The pass is unclamped float from
//    end to end, as the desktop's is up to its last `saturate`; the container
//    it is written into is what limits it (16 bits a channel here).
//
//  No `.metal` file may be in the app's target (`gen_project.py`; AGENTS.md
//  engine trap 2: an Xcode target may compile with fast math). So this is a
//  string, compiled once per device with `mathMode = .safe` (`library`), and
//  the same string serves the live display, the edited copies the library
//  shows, and — with the output transform beside it — every export
//  (`Layer2Export.swift`): the same maths at every size.

import Foundation
import Metal

enum Layer2Kernel {
    enum Failure: Error, CustomStringConvertible {
        case noDevice
        case compile(String)
        var description: String {
            switch self {
            case .noDevice: "no Metal device"
            case .compile(let why): "the Layer 2 kernels did not compile: \(why)"
            }
        }
    }

    /// Safe math, as the engine's kernels and the output transform are compiled.
    static func options() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        if #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        } else {
            options.fastMathEnabled = false
        }
        return options
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var libraries: [ObjectIdentifier: MTLLibrary] = [:]

    /// The kernels on `device`, compiled once and kept. `source` is for a
    /// check that compiles a broken copy; the app passes nothing.
    static func library(_ device: MTLDevice, source: String = Layer2Kernel.source) throws -> MTLLibrary {
        let shared = source == Layer2Kernel.source
        let key = ObjectIdentifier(device)
        if shared {
            lock.lock()
            if let made = libraries[key] { lock.unlock(); return made }
            lock.unlock()
        }
        let made: MTLLibrary
        do { made = try device.makeLibrary(source: source, options: options()) } catch {
            throw Failure.compile("\(error)")
        }
        if shared {
            lock.lock(); libraries[key] = made; lock.unlock()
        }
        return made
    }

    /// The block, the helpers and the pass itself — everything a kernel that
    /// applies Layer 2 needs. `Layer2Export` puts this after the output
    /// transform's own source; every name here starts `l2`, so the two do not meet.
    static let functions = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Layer2Uniforms {           // must match Layer2Uniforms in Adjustments.swift
        float3 wbGain;     float exposureGain;
        float3 cbMaster;   float contrast;
        float3 cbShadows;  float brightness;
        float3 cbMidtones; float saturation;
        float3 cbHighlights; float highlights;
        float4 cbLum;
        float shadows; float blackPoint; float whitePoint;
        float vignetteAmount; float vignetteMidpoint;
        // The encoded value of mid-grey (linear 0.18) in the space the values are in:
        // Display P3's sRGB curve in the working space (Adjustments.swift, `displayMidGrey`).
        float midGrey;
        uint curvesActive; uint enabled;
        // The additional colour steps (vibrance, HSL, the channel mixer): Adjustments.swift.
        float vibrance; uint hslActive; uint mixerActive; float pad;
        float4 hslHue0; float4 hslHue1;   // red orange yellow green | aqua blue purple magenta: radians
        float4 hslSat0; float4 hslSat1;   // -1...1
        float4 hslLum0; float4 hslLum1;   // -1...1
        float3 mixR; float3 mixG; float3 mixB;
    };

    static inline float l2Luma(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

    // Where an encoded value sits between black and white, with mid-grey at 0.5: piecewise
    // linear, exact at both ends, and the identity at midGrey == 0.5 (the desktop's tonePosition).
    static inline float l2TonePosition(float l, float midGrey) {
        float m = saturate(midGrey);
        if (m <= 0.0f || m >= 1.0f) m = 0.5f;
        return (l <= m) ? 0.5f * l / m : 0.5f + 0.5f * (l - m) / (1.0f - m);
    }

    // The colour of `d`, a pixel less its luma, as a point on the plane round the grey axis:
    // x towards red, y towards green-over-blue. Red is at 0 degrees, yellow 60, green 120,
    // cyan 180, blue 240, magenta 300 -- the circle HSL's eight colours are placed on.
    static inline float2 l2Chroma(float3 d) {
        return float2(d.r - 0.5f * (d.g + d.b), 0.8660254f * (d.g - d.b));
    }

    // The way back: the pixel less its luma whose colour is `p`, with no luma of its own.
    static inline float3 l2FromChroma(float2 p) {
        float q = p.y / 0.8660254f;                              // g - b
        float s = -2.0f * 0.2126f * p.x - (0.7152f - 0.0722f) * q; // g + b, so that the luma is zero
        return float3(p.x + 0.5f * s, 0.5f * (s + q), 0.5f * (s - q));
    }

    // 5b. Vibrance: saturation that spares what is already saturated (and takes less from it).
    static inline float3 l2Vibrance(float3 c, float v) {
        float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
        float sat = mx > 1e-4f ? saturate((mx - mn) / mx) : 0.0f;
        float l = l2Luma(c);
        return l + (c - l) * max(1.0f + v * (1.0f - sat), 0.0f);
    }

    // 5c. HSL: the pixel's colour, between two of the eight, turned, scaled and lightened by both.
    static inline float3 l2Hsl(float3 c, constant Layer2Uniforms &u) {
        float l = l2Luma(c);
        float3 d = c - l;
        float2 p = l2Chroma(d);
        float chroma = length(p);
        if (chroma < 1e-6f) return c;
        float h = atan2(p.y, p.x) * 57.29577951f;
        if (h < 0.0f) h += 360.0f;
        const float centres[9] = { 0.0f, 30.0f, 60.0f, 120.0f, 180.0f, 240.0f, 270.0f, 300.0f, 360.0f };
        float hue[8] = { u.hslHue0.x, u.hslHue0.y, u.hslHue0.z, u.hslHue0.w, u.hslHue1.x, u.hslHue1.y, u.hslHue1.z, u.hslHue1.w };
        float sat[8] = { u.hslSat0.x, u.hslSat0.y, u.hslSat0.z, u.hslSat0.w, u.hslSat1.x, u.hslSat1.y, u.hslSat1.z, u.hslSat1.w };
        float lum[8] = { u.hslLum0.x, u.hslLum0.y, u.hslLum0.z, u.hslLum0.w, u.hslLum1.x, u.hslLum1.y, u.hslLum1.z, u.hslLum1.w };
        uint i = 0u;
        while (i < 7u && h >= centres[i + 1u]) i++;
        uint j = (i + 1u) % 8u;
        float t = saturate((h - centres[i]) / (centres[i + 1u] - centres[i]));
        t = t * t * (3.0f - 2.0f * t);
        float turn = mix(hue[i], hue[j], t), scale = max(1.0f + mix(sat[i], sat[j], t), 0.0f);
        float lift = mix(lum[i], lum[j], t);
        float cs = cos(turn), sn = sin(turn);
        float2 q = float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs) * scale;
        c = l + l2FromChroma(q);
        // Luminance moves a colour, not a grey: in full from a fifth of a primary's chroma.
        return c * (1.0f + 0.5f * lift * smoothstep(0.0f, 0.2f, chroma));
    }

    // Steps 1-6: white balance, exposure, contrast, brightness, highlights/shadows,
    // black/white point, saturation and colour balance (the desktop's layer2Tone), with the
    // the vibrance, HSL and channel mixer between saturation and the colour balance.
    static inline float3 l2Tone(float3 c, constant Layer2Uniforms &u) {
        // 1. white balance (scan-side gains on encoded values)
        c *= u.wbGain;
        // 2. exposure in a pseudo-linear domain, then contrast and brightness
        if (u.exposureGain != 1.0f) {
            c = pow(max(c, 0.0f), 2.2f) * u.exposureGain;
            c = pow(c, 1.0f / 2.2f);
        }
        if (u.contrast != 0.0f) {
            float k = 1.0f + u.contrast * 1.2f;
            c = (c - u.midGrey) * k + u.midGrey;      // pivot on mid-grey
        }
        if (u.brightness != 0.0f) {
            c = pow(max(c, 0.0f), 1.0f / (1.0f + u.brightness * 0.8f));
        }
        // 3. highlights / shadows: tone-region masks on luma, measured from mid-grey
        float l = l2TonePosition(l2Luma(c), u.midGrey);
        if (u.shadows != 0.0f) {
            float w = (1.0f - l); w = w * w;
            c += u.shadows * 0.25f * w * (1.0f - c);
        }
        if (u.highlights != 0.0f) {
            float w = l * l;
            c += u.highlights * 0.25f * w * (u.highlights > 0.0f ? (1.0f - c) : c);
        }
        // 4. black / white point (the scanner's job)
        c = (c - u.blackPoint) / max(1.0f - u.blackPoint - u.whitePoint, 0.05f);
        // 5. saturation, about the luma it leaves alone
        l = l2Luma(c);
        if (u.saturation != 1.0f) {
            c = l + (c - l) * u.saturation;
        }
        // 5b-5d. the additional colour controls: vibrance, HSL, the channel mixer; each not run at zero, and
        // the luma the colour balance splits on is read again only after one of them ran
        bool moved = false;
        if (u.vibrance != 0.0f) { c = l2Vibrance(c, u.vibrance); moved = true; }
        if (u.hslActive != 0u) { c = l2Hsl(c, u); moved = true; }
        if (u.mixerActive != 0u) { c = float3(dot(u.mixR, c), dot(u.mixG, c), dot(u.mixB, c)); moved = true; }
        if (moved) l = l2Luma(c);
        // 6. colour balance: master + three zones, split at mid-grey
        if (any(u.cbMaster != 0.0f) || any(u.cbShadows != 0.0f) || any(u.cbMidtones != 0.0f)
            || any(u.cbHighlights != 0.0f) || any(u.cbLum != 0.0f)) {
            float ls = saturate(l2TonePosition(l, u.midGrey));
            float wS = (1.0f - ls) * (1.0f - ls);
            float wH = ls * ls;
            float wM = max(1.0f - wS - wH, 0.0f);
            c += u.cbMaster + u.cbShadows * wS + u.cbMidtones * wM + u.cbHighlights * wH;
            c *= 1.0f + u.cbLum.x + u.cbLum.y * wS + u.cbLum.z * wM + u.cbLum.w * wH;
        }
        return c;
    }

    // A row of the five-row table (rgb, luma, r, g, b; 256 entries each) at x: entry i is the
    // curve at i / 255, and between two entries the line between them.
    static inline float l2Curve(device const float *table, float x, uint row) {
        float v = clamp(x, 0.0f, 1.0f) * 255.0f;
        uint i = min(uint(v), 254u);
        float f = v - float(i);
        device const float *r = table + row * 256u;
        return mix(r[i], r[i + 1u], f);
    }

    // The whole pass on one pixel: the tone, the curves (luma, then RGB, then each channel),
    // the vignette. `uv` is the pixel's place in the whole picture, 0...1 on each side.
    static inline float3 l2Apply(float3 c, float2 uv, constant Layer2Uniforms &u, device const float *curves) {
        if (u.enabled == 0u) return c;
        c = l2Tone(c, u);
        if (u.curvesActive != 0u) {
            c = saturate(c);
            float ly = l2Luma(c);
            float ly2 = l2Curve(curves, ly, 1u);
            c *= (ly > 1e-4f) ? (ly2 / ly) : 1.0f;
            c = saturate(c);
            c = float3(l2Curve(curves, c.r, 0u), l2Curve(curves, c.g, 0u), l2Curve(curves, c.b, 0u));
            c = float3(l2Curve(curves, c.r, 2u), l2Curve(curves, c.g, 3u), l2Curve(curves, c.b, 4u));
        }
        // the vignette: radial, in encoded space
        if (u.vignetteAmount != 0.0f) {
            float2 p = uv - 0.5f;
            float d = length(p * 2.0f);          // 0 centre ... ~1.41 corner
            float fall = smoothstep(u.vignetteMidpoint * 1.2f, 1.5f, d);
            c *= 1.0f + u.vignetteAmount * fall * 0.9f;
        }
        return c;
    }

    static inline ushort l2To16(float v) {
        if (!(v == v)) return (ushort)0;
        return (ushort)(clamp(v, 0.0f, 1.0f) * 65535.0f + 0.5f);
    }
    """#

    /// The host's own kernels: the pass from a picture to a picture (the page,
    /// the edited copies), the same with float out (the checks), and the
    /// histogram of the picture as shown.
    static let kernels = #"""
    struct Layer2Size { uint width; uint height; uint stride; uint applies; };

    // A picture in, a picture out: RGBA, 16 bits a channel, tightly packed, Display P3 encoded.
    kernel void spkLayer2(device const ushort *src [[buffer(0)]],
                          device ushort *dst [[buffer(1)]],
                          constant Layer2Uniforms &u [[buffer(2)]],
                          device const float *curves [[buffer(3)]],
                          constant Layer2Size &size [[buffer(4)]],
                          uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.width || gid.y >= size.height) return;
        uint i = (gid.y * size.width + gid.x) * 4u;
        float3 c = float3(src[i], src[i + 1u], src[i + 2u]) / 65535.0f;
        float2 uv = (float2(gid) + 0.5f) / float2(size.width, size.height);
        c = l2Apply(c, uv, u, curves);
        dst[i]      = l2To16(c.x);
        dst[i + 1u] = l2To16(c.y);
        dst[i + 2u] = l2To16(c.z);
        dst[i + 3u] = (ushort)65535;
    }

    // The same, unclamped float out: what the pass makes before any container holds it.
    kernel void spkLayer2Float(device const ushort *src [[buffer(0)]],
                               device float4 *dst [[buffer(1)]],
                               constant Layer2Uniforms &u [[buffer(2)]],
                               device const float *curves [[buffer(3)]],
                               constant Layer2Size &size [[buffer(4)]],
                               uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.width || gid.y >= size.height) return;
        uint p = gid.y * size.width + gid.x;
        float3 c = float3(src[p * 4u], src[p * 4u + 1u], src[p * 4u + 2u]) / 65535.0f;
        float2 uv = (float2(gid) + 0.5f) / float2(size.width, size.height);
        dst[p] = float4(l2Apply(c, uv, u, curves), 1.0f);
    }

    // 4 rows x 256 bins: R, G, B, luma (the desktop's layout), of the picture as shown: the pass
    // applied where `applies`, then what a screen can show of it. One pixel in `stride` each way.
    kernel void spkLayer2Histogram(device const ushort *src [[buffer(0)]],
                                   device atomic_uint *bins [[buffer(1)]],
                                   constant Layer2Uniforms &u [[buffer(2)]],
                                   device const float *curves [[buffer(3)]],
                                   constant Layer2Size &size [[buffer(4)]],
                                   uint2 gid [[thread_position_in_grid]])
    {
        uint2 p = gid * size.stride;
        if (p.x >= size.width || p.y >= size.height) return;
        uint i = (p.y * size.width + p.x) * 4u;
        float3 c = float3(src[i], src[i + 1u], src[i + 2u]) / 65535.0f;
        if (size.applies != 0u) {
            float2 uv = (float2(p) + 0.5f) / float2(size.width, size.height);
            c = l2Apply(c, uv, u, curves);
        }
        c = saturate(c);
        uint r = uint(c.r * 255.0f + 0.5f), g = uint(c.g * 255.0f + 0.5f), b = uint(c.b * 255.0f + 0.5f);
        uint y = uint(saturate(l2Luma(c)) * 255.0f + 0.5f);
        atomic_fetch_add_explicit(&bins[r], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[256u + g], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[512u + b], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[768u + y], 1u, memory_order_relaxed);
    }
    """#

    static let source = functions + "\n" + kernels
}
