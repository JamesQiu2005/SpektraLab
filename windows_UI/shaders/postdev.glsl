// postdev.glsl -- Post-Dev ("Layer 2") on the GPU: the macOS `layer2` kernel
// (Shaders.metal:270-403, without masks and the DI decode) as one function,
//
//     vec3 postdev(vec3 rgb, vec2 sourceUv, PostDev grade, sampler2D curves)
//
// for the canvas's fragment shader to call after it samples the frame and
// before the display LUT. The arithmetic is PostDev.cpp's Grade::pixel line for
// line; spk_qt_postdev_gpu renders this file through QRhi and holds it to the
// CPU path. Read PostDev.hpp's design note before wiring it in.
//
// Include it after `#version 440` (qsb: `#extension GL_GOOGLE_include_directive
// : enable` then `#include "postdev.glsl"`). It declares no resources and no
// block: the includer owns its bindings, because a Qt Quick material has one
// uniform buffer and Post-Dev must live inside it.
//   * `PostDev` below is a std140 struct of ten vec4 (160 bytes). Make it a
//     member of the uniform block at a 16-byte-aligned offset and fill it with
//     postdev::std140() (PostDev.hpp lists every float). Do not name the
//     member `postdev` -- that is the function.
//   * `curves` is a 2-D texture, 256 x 5, R32F (RGBA32F works too: only .r is
//     read), holding postdev::curveTables() row-major: rows rgb, luma, red,
//     green, blue. It is read with texelFetch, so it needs no filtering and
//     the weights are exact floats -- a sampler's carry 8 fractional bits on
//     D3D11, and a 32-bit float texture need not be filterable at all.
//   * `rgb` is the frame in its own encoding (ProPhoto for Mac parity; never
//     linearised, never display-encoded); `sourceUv` is the sample's place on
//     the uncropped, unturned source in [0,1], which is where the vignette is.
// The result is clamped to [0,1] unless the grade is inactive (bypassed or
// identity), in which case `rgb` comes back untouched, as from Grade::apply.

struct PostDev {
    vec4 wbExposure;   // white-balance gains r, g, b; exposure scale gain^(1/2.2)
    vec4 tone;         // contrast, brightness, saturation (1 = none), highlights
    vec4 range;        // shadows, black point, white point, mid-grey (encoded)
    vec4 cbMaster;     // colour-balance offset r, g, b; unused
    vec4 cbShadows;
    vec4 cbMidtones;
    vec4 cbHighlights;
    vec4 cbLum;        // luminance: master, shadows, midtones, highlights
    vec4 vignette;     // amount (-1..1), midpoint (0..1), unused, unused
    vec4 switches;     // active, curves active, exposure active, unused (0 or 1)
};

// Shaders.metal:119, Rec. 709 weights on the encoded values.
float postdevLuma(vec3 c)
{
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Shaders.metal:136-143: mid-grey at 0.5, each half its own straight line.
float postdevTonePosition(float l, float midGrey)
{
    float m = clamp(midGrey, 0.0, 1.0);
    if (m <= 0.0 || m >= 1.0) m = 0.5;
    return (l <= m) ? 0.5 * l / m : 0.5 + 0.5 * (l - m) / (1.0 - m);
}

// Steps 1-6, layer2Tone (Shaders.metal:270-313): the part a mask would share.
vec3 postdevTone(vec3 c, PostDev g)
{
    float midGrey = g.range.w;
    // 1. white balance (scan-side gains on encoded values)
    c *= g.wbExposure.rgb;
    // 2. exposure in a pseudo-linear domain: pow(pow(c, 2.2) * gain, 1/2.2)
    //    is c * gain^(1/2.2) for c >= 0, precomputed on the CPU.
    if (g.switches.z > 0.5) c = max(c, vec3(0.0)) * g.wbExposure.w;
    if (g.tone.x != 0.0) {
        float k = 1.0 + g.tone.x * 1.2;
        c = (c - midGrey) * k + midGrey;
    }
    if (g.tone.y != 0.0) c = pow(max(c, vec3(0.0)), vec3(1.0 / (1.0 + g.tone.y * 0.8)));
    // 3. highlights / shadows, measured from mid-grey
    float l = postdevTonePosition(postdevLuma(c), midGrey);
    if (g.range.x != 0.0) {
        float w = 1.0 - l;
        w = w * w;
        c += g.range.x * 0.25 * w * (1.0 - c);
    }
    if (g.tone.w != 0.0) {
        float w = l * l;
        c += g.tone.w * 0.25 * w * (g.tone.w > 0.0 ? (vec3(1.0) - c) : c);
    }
    // 4. black / white point
    c = (c - g.range.y) / max(1.0 - g.range.y - g.range.z, 0.05);
    // 5. saturation
    l = postdevLuma(c);
    c = l + (c - l) * g.tone.z;
    // 6. colour balance: master + three zones split at mid-grey
    float ls = clamp(postdevTonePosition(l, midGrey), 0.0, 1.0);
    float wS = (1.0 - ls) * (1.0 - ls);
    float wH = ls * ls;
    float wM = max(1.0 - wS - wH, 0.0);
    c += g.cbMaster.rgb + g.cbShadows.rgb * wS + g.cbMidtones.rgb * wM + g.cbHighlights.rgb * wH;
    c *= 1.0 + g.cbLum.x + g.cbLum.y * wS + g.cbLum.z * wM + g.cbLum.w * wH;
    return c;
}

// One curve row at x, as the Mac's linear clamp-to-edge sampler reads its
// 256-wide table (Shaders.metal:145-147): texel centres at (i + 0.5) / 256.
// postdev::curveLookup is the same arithmetic.
float postdevCurve(sampler2D curves, float x, int row)
{
    float p = clamp(x * 256.0 - 0.5, 0.0, 255.0);
    float i = min(floor(p), 254.0);
    float f = p - i;
    float a = texelFetch(curves, ivec2(int(i), row), 0).r;
    float b = texelFetch(curves, ivec2(int(i) + 1, row), 0).r;
    return a * (1.0 - f) + b * f;
}

vec3 postdev(vec3 rgb, vec2 sourceUv, PostDev g, sampler2D curves)
{
    if (g.switches.x < 0.5) return rgb;
    vec3 c = postdevTone(rgb, g);
    // 7. curves -- luma, then RGB master, then per channel
    if (g.switches.y > 0.5) {
        c = clamp(c, 0.0, 1.0);
        float ly = postdevLuma(c);
        float ly2 = postdevCurve(curves, ly, 1);
        c *= (ly > 1e-4) ? (ly2 / ly) : 1.0;
        c = clamp(c, 0.0, 1.0);
        c = vec3(postdevCurve(curves, c.r, 0), postdevCurve(curves, c.g, 0), postdevCurve(curves, c.b, 0));
        c = vec3(postdevCurve(curves, c.r, 2), postdevCurve(curves, c.g, 3), postdevCurve(curves, c.b, 4));
    }
    // 9. vignette -- radial about the source's centre, per axis
    if (g.vignette.x != 0.0) {
        float d = length((sourceUv - 0.5) * 2.0);
        float fall = smoothstep(g.vignette.y * 1.2, 1.5, d);
        c *= 1.0 + g.vignette.x * fall * 0.9;
    }
    return clamp(c, 0.0, 1.0);
}
