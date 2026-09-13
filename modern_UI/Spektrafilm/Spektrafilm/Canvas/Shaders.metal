//  Shaders.metal — the canvas: Layer 2 as a compute pass, the output
//  transform, a display quad, and the histogram.
//
//  Colour rules (UI-GUIDELINE §4, RFC-018 §2.4): **ProPhoto RGB is the working
//  space.** The image textures hold the *working* space's encoded values — the
//  engine applied `output_cctf_encoding` to its ProPhoto output, and the
//  decoder's preview is rendered into ROMM too — and Layer 2 grades in them.
//  The only place a rendering space is left is `outputTransform`, below, which
//  converts once per destination: the canvas runs it with Display P3 (the
//  layer's own colour space, so ColorSync still does exactly one display
//  transform), and export runs it with the recipe's space.
//
//  Layer 2 works on encoded values on purpose — it is an adjustment to a scan
//  — except `exposure`, which is done in a pseudo-linear domain so that "one
//  stop" means one stop. It pivots its tone regions on `midGrey`, the encoded
//  value of the frame's actual mid-grey in *this* space (Decision D1), rather
//  than on the literal 0.5 that was only ever right by accident.

#include <metal_stdlib>
using namespace metal;

struct Layer2Uniforms {           // must match Adjustments.swift
    float3 wbGain;     float exposureGain;
    float3 cbMaster;   float contrast;
    float3 cbShadows;  float brightness;
    float3 cbMidtones; float saturation;
    float3 cbHighlights; float highlights;
    float4 cbLum;
    float shadows; float blackPoint; float whitePoint;
    float vignetteAmount; float vignetteMidpoint;
    // The encoded value of mid-grey (linear 0.18) **in the space the values
    // are in**. RFC-018 Decision D1: every tone pivot below used to be the
    // literal 0.5, which is a pivot on mid-grey only in a space whose curve
    // happens to put it there. See `tonePosition`.
    float midGrey;
    uint curvesActive; uint enabled; uint _pad;
};

struct GeometryUniform {           // must match Geometry.Uniform in Geometry.swift
    float2 centre;                // crop centre, normalised to the source
    float2 halfExtent;            // crop half-size, normalised
    float2 cosSin;                // the straighten angle
    float2 pixelRatio;            // (w/h, h/w) — the rotation is rigid in pixels
    uint quarterTurns;
    uint flips;                   // bit 0 horizontal, bit 1 vertical
    uint active;
    uint pad;
};

struct CanvasUniforms {           // must match Renderer.swift
    float2 viewportSize;          // in device pixels
    float2 imageSize;             // the *output* size in logical pixels
    float2 offset;                // output origin in device pixels
    float scale;                  // device pixels per output logical pixel
    float surroundGray;           // encoded value of the ground
    float magnification;          // device pixels per *source texture* pixel
    GeometryUniform geometry;
    uint editingCrop;             // show the whole frame, dim outside the crop
    uint checker;                 // draw a soft focus frame (unused)
    uint compare;                 // 0 off, 1 split, 2 before-only
    float compareSplit;           // split position, 0…1 across the *output*
    float2 pivot;                 // crop tool's edit-space pivot, source-normalised
};

//  Output uv → source uv. A transliteration of
//  `Geometry.sourcePoint(forOutput:imageSize:)`; `GeometryTests` pins the
//  pairs both must produce, because a divergence here is a picture that is
//  subtly the wrong part of the frame and nothing says so.
static inline float2 geometryMap(float2 uv, constant GeometryUniform &g) {
    if (g.active == 0) return uv;
    float2 u = uv;
    if (g.flips & 1u) u.x = 1.0 - u.x;
    if (g.flips & 2u) u.y = 1.0 - u.y;
    switch (g.quarterTurns) {
        case 1: u = float2(u.y, 1.0 - u.x); break;
        case 2: u = float2(1.0 - u.x, 1.0 - u.y); break;
        case 3: u = float2(1.0 - u.y, u.x); break;
        default: break;
    }
    // Crop-local, in units where one unit of x and one of y are the same
    // number of source pixels — otherwise the rotation shears on a
    // non-square frame.
    float px = (u.x - 0.5) * 2.0 * g.halfExtent.x;
    float py = (u.y - 0.5) * 2.0 * g.halfExtent.y * g.pixelRatio.y;
    float rx = px * g.cosSin.x - py * g.cosSin.y;
    float ry = px * g.cosSin.y + py * g.cosSin.x;
    return float2(g.centre.x + rx, g.centre.y + ry * g.pixelRatio.x);
}

//  Edit space → source, while the crop tool is up: the frame stays level on
//  screen and the photograph turns under it, which is a rotation about the
//  pivot. A transliteration of `Geometry.sourcePoint(forEdit:pivot:imageSize:)`
//  and rigid in pixels the same way `geometryMap` is. It is NOT a second
//  `geometryMap` — that one is crop → output and the exported file goes
//  through it unchanged; this one is the editing view only.
static inline float2 editToSource(float2 e, constant CanvasUniforms &u) {
    float dx = e.x - u.pivot.x;
    float dy = (e.y - u.pivot.y) * u.geometry.pixelRatio.y;   // width-fractions
    float rx = dx * u.geometry.cosSin.x - dy * u.geometry.cosSin.y;
    float ry = dx * u.geometry.cosSin.y + dy * u.geometry.cosSin.x;
    return float2(u.pivot.x + rx, u.pivot.y + ry * u.geometry.pixelRatio.x);
}

/// Whether a *source* uv is inside the oriented crop. The inverse rotation of
/// the map above, used only while the crop is being edited.
static inline bool insideCrop(float2 suv, constant GeometryUniform &g) {
    float dx = suv.x - g.centre.x;
    float dy = (suv.y - g.centre.y) * g.pixelRatio.y;
    float lx =  dx * g.cosSin.x + dy * g.cosSin.y;
    float ly = -dx * g.cosSin.y + dy * g.cosSin.x;
    return abs(lx) <= g.halfExtent.x && abs(ly) <= g.halfExtent.y * g.pixelRatio.y;
}

static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// Where an encoded value sits between "black" and "white", with **mid-grey at
/// 0.5** rather than wherever the encoding happens to put it.
///
/// RFC-018 Decision D1. Every tone region below is a weight that peaks at an
/// end and crosses over in the middle, and "the middle" used to be the literal
/// 0.5. That is true of an sRGB-like curve by coincidence (linear 0.18 encodes
/// to 0.4614 there, close enough that nobody noticed) and false of ROMM γ1.8,
/// where it encodes to 0.3857 — so moving the working space to ProPhoto would
/// have silently re-pivoted every tone slider three-quarters of a stop up.
///
/// The map is piecewise linear: each half keeps its own straight line from its
/// own end to 0.5. So it is exact at both ends, crosses at mid-grey, and — the
/// property that makes this a re-pivot rather than a retune — **at
/// `midGrey == 0.5` it is the identity**, reproducing today's arithmetic bit
/// for bit.
static inline float tonePosition(float l, float midGrey) {
    float m = saturate(midGrey);
    // 0.5 guards a caller that hands over a degenerate mid-grey (a neutral
    // 1×1 probe, an unset uniform): fall back to the old pivot rather than
    // dividing by zero and painting the frame black.
    if (m <= 0.0 || m >= 1.0) m = 0.5;
    return (l <= m) ? 0.5 * l / m : 0.5 + 0.5 * (l - m) / (1.0 - m);
}

static inline float curveLookup(texture2d<float> table, sampler s, float x, int row) {
    return table.sample(s, float2(x, (float(row) + 0.5) / 5.0)).r;
}


//  ── masks (蒙版) ────────────────────────────────────────────────────────────
//
//  A mask is a region plus its own tone adjustments (`Model/Mask.swift`).
//  Every component except `brush` is closed-form, so coverage is computed per
//  pixel from parameters at whatever resolution the canvas happens to be
//  showing: a radial gradient is exact at 400 % zoom and costs no memory at
//  any tier. Only `brush` reads a texture, and a mask with no brush in it
//  binds none.
//
//  Distances are aspect-corrected into "long-edge units" so an ellipse is an
//  ellipse on a 3:2 frame and a gradient's feather is the same width whether
//  it runs across the frame or down it.

struct MaskComponentUniform {     // must match MaskComponentUniform in Mask.swift
    uint kind;                    // 0 linear · 1 radial · 2 luminance · 3 colour · 4 brush
    uint subtract;
    uint inverted;
    uint pad0;
    float2 a;
    float2 b;
    float2 radii;
    float2 cosSin;
    float4 range;                 // low, high, softness, tolerance
    float4 color;
    float feather;
    float3 pad1;
};

struct MaskUniform {              // must match MaskUniform in Mask.swift
    Layer2Uniforms adjustments;
    MaskComponentUniform components[6];
    uint componentCount;
    uint inverted;
    float amount;
    int rasterSlice;              // −1 when the mask has no brush component
};

/// Normalised uv → long-edge units, so x and y are the same physical
/// distance. `aspect` is width ÷ height.
static inline float2 toLongEdge(float2 uv, float aspect) {
    return aspect >= 1.0 ? float2(uv.x, uv.y / aspect) : float2(uv.x * aspect, uv.y);
}

static inline float linearCoverage(float2 uv, constant MaskComponentUniform &c, float aspect) {
    float2 p = toLongEdge(uv, aspect);
    float2 a = toLongEdge(c.a, aspect), b = toLongEdge(c.b, aspect);
    float2 axis = b - a;
    float len2 = max(dot(axis, axis), 1e-9);
    float t = dot(p - a, axis) / len2;
    return smoothstep(0.0, 1.0, saturate(t));
}

static inline float radialCoverage(float2 uv, constant MaskComponentUniform &c, float aspect) {
    float2 d = toLongEdge(uv, aspect) - toLongEdge(c.a, aspect);
    // Into the ellipse's own frame, then normalise by its semi-axes: `r` is
    // 1 exactly on the boundary whatever the rotation and the aspect.
    float2 e = float2( d.x * c.cosSin.x + d.y * c.cosSin.y,
                      -d.x * c.cosSin.y + d.y * c.cosSin.x) / c.radii;
    float r = length(e);
    // Feather 0 is a hard edge; 1 falls off from the centre.
    float inner = 1.0 - saturate(c.feather);
    return 1.0 - smoothstep(inner, 1.0, r);
}

static inline float luminanceCoverage(float3 rgb, constant MaskComponentUniform &c) {
    float l = luma(rgb);
    float soft = c.range.z;
    return smoothstep(c.range.x - soft, c.range.x + soft, l) *
           (1.0 - smoothstep(c.range.y - soft, c.range.y + soft, l));
}

static inline float colorCoverage(float3 rgb, constant MaskComponentUniform &c) {
    // Distance in a cheap chroma space: the two opponent axes plus a much
    // lighter weight on luminance, so "this green" selects the green in the
    // shade as well as the green in the sun.
    float3 t = c.color.rgb;
    float2 ca = float2(rgb.r - rgb.g, rgb.b - (rgb.r + rgb.g) * 0.5);
    float2 cb = float2(t.r - t.g, t.b - (t.r + t.g) * 0.5);
    float d = length(ca - cb) + abs(luma(rgb) - luma(t)) * 0.25;
    return 1.0 - smoothstep(c.range.w * 0.5, c.range.w, d);
}

/// One mask's coverage at a pixel, before `amount`. Components union when
/// they add and cut when they subtract, which is what makes "the sky, minus
/// the trees" one mask rather than two.
static inline float maskCoverage(constant MaskUniform &m, float2 uv, float3 rgb, float aspect,
                                 texture2d_array<float> rasters, sampler s)
{
    float total = 0.0;
    for (uint i = 0; i < m.componentCount && i < 6; ++i) {
        constant MaskComponentUniform &c = m.components[i];
        float cc = 0.0;
        switch (c.kind) {
            case 0: cc = linearCoverage(uv, c, aspect); break;
            case 1: cc = radialCoverage(uv, c, aspect); break;
            case 2: cc = luminanceCoverage(rgb, c); break;
            case 3: cc = colorCoverage(rgb, c); break;
            case 4: cc = (m.rasterSlice >= 0) ? rasters.sample(s, uv, uint(m.rasterSlice)).r : 0.0; break;
            default: break;
        }
        if (c.inverted != 0) cc = 1.0 - cc;
        // The first component is additive whatever its flag says; there is
        // nothing to subtract from yet. `Mask.swift` packs it that way, and
        // this is the same rule stated where it is used.
        if (i > 0 && c.subtract != 0) total = min(total, 1.0 - cc);
        else                          total = max(total, cc);
    }
    if (m.inverted != 0) total = 1.0 - total;
    return saturate(total) * m.amount;
}

/// Steps 1–6 of Layer 2: white balance, exposure, contrast, brightness,
/// highlights/shadows, black/white point, saturation and colour balance.
///
/// A function rather than the body of the kernel because **a mask runs the
/// same arithmetic on the same values** — a mask is a local Layer 2, so "+1
/// stop" has to mean the same thing whichever slider it came from. Curves and
/// the vignette stay in the kernel: a curve is a global statement about a
/// tone scale and a vignette is a lens, and neither means anything applied to
/// a region.
static inline float3 layer2Tone(float3 c, constant Layer2Uniforms &u) {
    // 1. white balance (scan-side gains on encoded values)
    c *= u.wbGain;
    // 2. exposure in a pseudo-linear domain, then contrast and brightness
    if (u.exposureGain != 1.0) {
        c = pow(max(c, 0.0), 2.2) * u.exposureGain;
        c = pow(c, 1.0 / 2.2);
    }
    if (u.contrast != 0.0) {
        float k = 1.0 + u.contrast * 1.2;
        c = (c - u.midGrey) * k + u.midGrey;      // D1: pivot on mid-grey
    }
    if (u.brightness != 0.0) {
        c = pow(max(c, 0.0), 1.0 / (1.0 + u.brightness * 0.8));
    }
    // 3. highlights / shadows — tone-region masks on luma, measured from
    // mid-grey rather than from 0.5 (D1)
    float l = tonePosition(luma(c), u.midGrey);
    if (u.shadows != 0.0) {
        float w = (1.0 - l); w = w * w;
        c += u.shadows * 0.25 * w * (1.0 - c);
    }
    if (u.highlights != 0.0) {
        float w = l * l;
        c += u.highlights * 0.25 * w * (u.highlights > 0 ? (1.0 - c) : c);
    }
    // 4. black / white point (the scanner's job)
    c = (c - u.blackPoint) / max(1.0 - u.blackPoint - u.whitePoint, 0.05);
    // 5. saturation
    l = luma(c);
    c = l + (c - l) * u.saturation;
    // 6. colour balance — master + three zones, split at mid-grey rather than
    // at 0.5 (D1). `l` above is the raw luma saturation needs; the zones get
    // their own position.
    {
        float ls = saturate(tonePosition(l, u.midGrey));
        float wS = (1.0 - ls) * (1.0 - ls);
        float wH = ls * ls;
        float wM = max(1.0 - wS - wH, 0.0);
        c += u.cbMaster + u.cbShadows * wS + u.cbMidtones * wM + u.cbHighlights * wH;
        c *= 1.0 + u.cbLum.x + u.cbLum.y * wS + u.cbLum.z * wM + u.cbLum.w * wH;
    }
    return c;
}

kernel void layer2(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   texture2d<float> curves [[texture(2)]],
                   texture2d_array<float> maskRasters [[texture(3)]],
                   constant Layer2Uniforms &u [[buffer(0)]],
                   constant MaskUniform *masks [[buffer(1)]],
                   constant uint &maskCount [[buffer(2)]],
                   constant int &maskOverlay [[buffer(3)]],
                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;
    if (u.enabled == 0 && maskCount == 0) { dst.write(float4(c, 1), gid); return; }

    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler maskSampler(filter::linear, address::clamp_to_edge, mip_filter::none);

    float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float aspect = size.x / max(size.y, 1.0);

    // Coverage is computed against the image *before* the global adjustments,
    // so a luminance-range or colour-range mask selects what the photograph
    // has in it rather than what the exposure slider just did to it. Move a
    // global slider and the region a "highlights" mask covers stays put,
    // which is the behaviour that makes the two independently adjustable.
    float3 masked = c;

    if (u.enabled != 0) {
        c = layer2Tone(c, u);
        // 7. curves — luma, then RGB master, then per channel
        if (u.curvesActive != 0) {
            c = saturate(c);
            float ly = luma(c);
            float ly2 = curveLookup(curves, lin, ly, 1);
            c *= (ly > 1e-4) ? (ly2 / ly) : 1.0;
            c = saturate(c);
            c = float3(curveLookup(curves, lin, c.r, 0), curveLookup(curves, lin, c.g, 0), curveLookup(curves, lin, c.b, 0));
            c = float3(curveLookup(curves, lin, c.r, 2), curveLookup(curves, lin, c.g, 3), curveLookup(curves, lin, c.b, 4));
        }
    }

    // 8. masks — local Layer 2. Applied after the global pass, the way every
    // comparable editor orders them: a mask is a correction to the picture
    // you have, not to the one you started with.
    float shown = 0.0;
    for (uint i = 0; i < maskCount && i < 8; ++i) {
        float cover = maskCoverage(masks[i], uv, masked, aspect, maskRasters, maskSampler);
        if (cover > 0.0005) {
            c = mix(c, layer2Tone(c, masks[i].adjustments), cover);
        }
        // Only the selected mask tints. Showing every mask's coverage at
        // once is a red picture and tells you nothing about the one you are
        // editing.
        if (int(i) == maskOverlay) shown = cover;
    }

    // 9. vignette — radial, in encoded space
    if (u.enabled != 0 && u.vignetteAmount != 0.0) {
        float2 p = uv - 0.5;
        float d = length(p * 2.0);          // 0 centre … ~1.41 corner
        float fall = smoothstep(u.vignetteMidpoint * 1.2, 1.5, d);
        c *= 1.0 + u.vignetteAmount * fall * 0.9;
    }

    // The red overlay, drawn last so it is not itself adjusted. Every editor
    // uses red and every editor's users turn it off, so it is a toggle — and
    // it tints only the mask at `maskOverlay`, the selected one. −1 is off.
    //
    // The tint is in the **working space's** encoding, which is not the
    // numbers the interface was drawn with. `(0.85, 0.15, 0.15)` is an
    // sRGB-encoded red — the one every editor's mask uses — and it is written
    // into a picture whose space is ROMM γ1.8 now. Read as γ1.8 those numbers
    // are a deeper red, because the curve is flatter: sRGB-decode(0.85) is
    // 0.69198 and sRGB-decode(0.15) is 0.019607, which ROMM re-encodes to
    // **0.81507** and **0.11255**. Left alone, the mask overlay would have
    // darkened with the ground.
    if (maskOverlay >= 0 && shown > 0.0005) {
        c = mix(c, float3(0.81507, 0.11255, 0.11255), shown * 0.45);
    }

    dst.write(float4(saturate(c), 1), gid);
}

//  Export's geometry pass. Deliberately the *same* `geometryMap` the canvas
//  uses rather than a CoreGraphics transform beside it: two implementations
//  of a rotation are two chances to disagree about a sign, and the way that
//  failure presents is an exported file that is subtly the wrong part of the
//  frame, which nothing checks.
kernel void geometryResample(texture2d<float, access::sample> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant GeometryUniform &g [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::none);
    float2 ouv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(float4(src.sample(lin, geometryMap(ouv, g)).rgb, 1), gid);
}

struct QuadOut { float4 position [[position]]; float2 uv; };

vertex QuadOut canvasVertex(uint vid [[vertex_id]]) {
    // Two triangles covering clip space; uv has (0,0) at top-left.
    float2 pos[6] = { {-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1} };
    QuadOut o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = float2(pos[vid].x * 0.5 + 0.5, 0.5 - pos[vid].y * 0.5);
    return o;
}

fragment float4 canvasFragment(QuadOut in [[stage_in]],
                               texture2d<float> image [[texture(0)]],
                               texture2d<float> before [[texture(1)]],
                               constant CanvasUniforms &u [[buffer(0)]])
{
    // Below 100 % the image is minified: linear. At or above 100 % every
    // image pixel covers whole device pixels: nearest, so a 400 % view shows
    // the actual pixels (and grain) instead of a smear. The test is on
    // `magnification` — device pixels per *source texture* pixel — not on
    // `scale`, because with a crop applied those are no longer the same
    // number and a 12 % crop would otherwise pick nearest at 40 % zoom.
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::none);
    constexpr sampler near(filter::nearest, address::clamp_to_edge, mip_filter::none);
    float2 px = in.uv * u.viewportSize;                    // device pixel, top-left origin
    float2 ip = (px - u.offset) / u.scale;                 // output logical pixel
    float2 ouv = ip / u.imageSize;                         // 0…1 across the output
    float3 ground = float3(u.surroundGray);
    // While the crop is being edited the canvas shows the whole frame, the
    // way Capture One's crop tool does: you cannot judge a crop against
    // pixels you cannot see. There the sample goes through the edit-space
    // rotation instead of `geometryMap`, and the ground test is on the
    // **source** uv: in edit space the photograph is a rotated rectangle
    // whose corners stick out of the W×H box, and clipping to that box would
    // cut them off. Output mode is the branch below, unchanged.
    float2 suv;
    if (u.editingCrop != 0) {
        suv = editToSource(ouv, u);
        if (suv.x < 0.0 || suv.y < 0.0 || suv.x > 1.0 || suv.y > 1.0) {
            return float4(ground, 1);
        }
    } else {
        if (ouv.x < 0.0 || ouv.y < 0.0 || ouv.x > 1.0 || ouv.y > 1.0) {
            return float4(ground, 1);
        }
        suv = geometryMap(ouv, u.geometry);
        if (suv.x < 0.0 || suv.y < 0.0 || suv.x > 1.0 || suv.y > 1.0) {
            return float4(ground, 1);
        }
    }
    //  Before/after. The split is measured across the **output** — the
    //  picture — not across the viewport, so the line stays on the same part
    //  of the frame when the view is panned or zoomed. That is Capture One's
    //  behaviour and it is the one that survives a zoom: a viewport-anchored
    //  line slides across the subject as soon as you move, which makes the
    //  comparison meaningless at anything but fit.
    //
    //  `before` is the decoded frame — the same texture Space shows — and it
    //  is sampled through the *same* `suv`, so the crop, the straighten and
    //  the flips apply to both halves and the two sides line up pixel for
    //  pixel. Comparing an uncropped before against a cropped after would be
    //  comparing two different pictures.
    bool useBefore = (u.compare == 2u) ||
                     (u.compare == 1u && ouv.x < u.compareSplit);
    float3 c;
    if (useBefore) {
        c = (u.magnification >= 1.0) ? before.sample(near, suv).rgb : before.sample(lin, suv).rgb;
    } else {
        c = (u.magnification >= 1.0) ? image.sample(near, suv).rgb : image.sample(lin, suv).rgb;
    }
    if (u.editingCrop != 0 && u.geometry.active != 0 && !insideCrop(suv, u.geometry)) {
        c = mix(c, ground, 0.6);
    }
    return float4(c, 1);
}

// 4 rows × 256 bins: R, G, B, luma. Sampled on a stride so a 2 MP frame costs
// ~130k reads; plenty for a 256-bin plot.
kernel void histogram(texture2d<float, access::read> src [[texture(0)]],
                      device atomic_uint *bins [[buffer(0)]],
                      constant uint &stride [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]])
{
    uint2 p = gid * stride;
    if (p.x >= src.get_width() || p.y >= src.get_height()) return;
    float3 c = saturate(src.read(p).rgb);
    uint r = uint(c.r * 255.0 + 0.5), g = uint(c.g * 255.0 + 0.5), b = uint(c.b * 255.0 + 0.5);
    uint y = uint(saturate(luma(c)) * 255.0 + 0.5);
    atomic_fetch_add_explicit(&bins[r], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[256 + g], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[512 + b], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[768 + y], 1u, memory_order_relaxed);
}

//  ── the output transform (RFC-018 §5.3) ─────────────────────────────────────
//
//  The single place a rendering space is left. The canvas runs it with
//  target = Display P3; export and the soft proof run it with the recipe's
//  space, which is what makes the proof a proof.
//
//      working (ProPhoto, encoded)
//        → decode ROMM TRC
//        → 3×3 linear, chromatically adapted
//        → CAM16-UCS gamut compression into the TARGET
//        → encode the target's TRC
//        → target (encoded)
//
//  Every number it reads comes from the engine over `spk_output_transform`,
//  and nothing here is a second colour library: the transfer functions below
//  are **ported from `engine/src/shaders/nodes.metal`** and the CAM16 body from
//  `engine/src/shaders/gamut.metal`. A second implementation of ROMM's linear
//  toe, or of CAM16's inverse, would be a second chance to get a breakpoint
//  wrong and nothing would say so.

struct OutputTransformUniforms {   // must match ColourManagement.swift
    // Source linear RGB → target linear RGB, **row-major**: out[i] = Σ_j m[3i+j]·x[j].
    // Written down because the engine's own kernels do not agree about this
    // and getting it wrong reads as a grading decision, not as a bug
    // (AGENTS.md trap 20).
    float matrix[9];
    // The CAM16 setup for the *target*: its RGB↔XYZ pair with adaptation, and
    // the 22 scalars `spk_cam16ucs_compress` reads out of `k`.
    float cam16M2X[9];
    float cam16M2R[9];
    float cam16K[22];
    uint  sourceCctfMode;    // as `nodes.metal` numbers the curves
    uint  targetCctfMode;
    uint  cam16Active;       // 0 → the compression step is skipped entirely
    uint  cam16Lightness;    // the lightness compression's own gate (k[15..17])
    uint  cmaxNL;            // 64
    uint  cmaxNH;            // 720
    uint  _pad0;
    uint  _pad1;
};

// Signed power, `colour.algebra.spow`: |v|**p with v's sign kept, so a
// negative code value does not become NaN. The transfer functions below use it
// wherever the reference does and nowhere else -- ProPhoto's and Adobe's
// curves are bare `**` in colour, and matching that includes matching where
// they produce NaN.
inline float spow(float v, float p) {
    float s = v < 0.0f ? -1.0f : (v > 0.0f ? 1.0f : 0.0f);
    return s * pow(fabs(v), p);
}

// The transfer functions, as one function over a mode. Mode order matches
// `core/colour.cpp`'s `Cctf` enum: 0 sRGB (and Display P3), 1 ProPhoto RGB,
// 2 Adobe RGB (1998), 3 BT.709/BT.2020, 4 identity (the ACES spaces).
//
// The breakpoints are the reference's exact ones, not the spec's printed
// roundings: the sRGB decode turns at the *encoded* value of 0.0031308
// (0.040449936), and the BT inverse at the encoded value of beta rather than
// 4.5*beta. At exactly 0.04045 the two choices take different branches.
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

/// CAM16-UCS gamut compression into the target, per pixel, in linear RGB.
///
/// Ported from `engine/src/shaders/gamut.metal`, whose buffer reads become the
/// uniform and `cmax` reads below. Three of the reference's traps are
/// reproduced deliberately:
///   * the sign-preserving power for J (a negative achromatic response gives a
///     negative J, and pipeline output legitimately reaches -0.20);
///   * the 460/1403 family of normalisation factors in the inverse (a, b)
///     solve, whose omission cost dE2000 max 33;
///   * numba's `%` on a negative hue index follows Python (non-negative) and
///     MSL's follows C, so the wrap is spelled out.
///
/// One number here is knowingly not the same as its host-side counterpart. The
/// inverse cone matrix below is the *published* eight-digit CAM16 inverse;
/// `core/cam16.cpp` derives `inv(MATRIX_16)` numerically, as colour-science
/// does, and the two differ by ~1e-9 relative. That is two orders of magnitude
/// below float32 storage epsilon, so it cannot move a pixel -- and this body
/// is the one RFC-011 measured, so it is transferred rather than improved. The
/// host needs the derived one because the C_max bisection is in float64 and
/// 1e-9 there flips gamut decisions; see that file.
///
/// `moved` is set when the knee acted on this pixel — `d > threshold`, the same
/// branch the reference takes — and is `stats[0]`. `outside` is set when the
/// pixel's chroma exceeded what the destination's cube can hold at that
/// lightness and hue (`d > 1`), and is `stats[2]`.
///
/// **Those are not the same question, and at the session's default knee the
/// first one is nearly meaningless.** `GamutCompressSpec::output_default` is
/// `knee = (0.0, 1.0, 6.0)`, which the reference's own docstring calls "a
/// gentle, always-on roll-off" — threshold 0 means every pixel with any chroma
/// at all takes the branch, so `stats[0]` reads ~100% on any photograph. It is
/// reported because RFC-018 §5.3 defines it that way; `stats[2]` is the number
/// that answers "could the destination hold this picture", which is what §6's
/// warning is about.
static inline float3 cam16ucsInto(float3 rgb, constant OutputTransformUniforms &u,
                                  device const float *cmax, thread bool &moved,
                                  thread bool &outside) {
    const uint nL = u.cmaxNL, nh = u.cmaxNH, lc_active = u.cam16Lightness;
    // scalar constants
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
    moved = d > threshold;
    // Before the knee, because after it every pixel is inside by construction
    // — the knee's limit is 1. This is "the container could not hold it".
    outside = d > 1.0f;
    if (moved) {
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

kernel void outputTransform(texture2d<float, access::read>  src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant OutputTransformUniforms &u [[buffer(0)]],
                            device const float *cmax [[buffer(1)]],
                            device atomic_uint *stats [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;

    // 1. the working space's own curve, off
    float3 v = float3(cctf_decode_mode(c.r, u.sourceCctfMode),
                      cctf_decode_mode(c.g, u.sourceCctfMode),
                      cctf_decode_mode(c.b, u.sourceCctfMode));
    // 2. into the target, linearly, chromatically adapted
    float3 lin = float3(u.matrix[0] * v.x + u.matrix[1] * v.y + u.matrix[2] * v.z,
                        u.matrix[3] * v.x + u.matrix[4] * v.y + u.matrix[5] * v.z,
                        u.matrix[6] * v.x + u.matrix[7] * v.y + u.matrix[8] * v.z);
    // 3. CAM16-UCS into the target's gamut, rolling rather than cutting
    bool moved = false, outside = false;
    if (u.cam16Active != 0u) lin = cam16ucsInto(lin, u, cmax, moved, outside);
    // 4. the target's curve, on
    float3 enc = float3(cctf_encode_mode(lin.x, u.targetCctfMode),
                        cctf_encode_mode(lin.y, u.targetCctfMode),
                        cctf_encode_mode(lin.z, u.targetCctfMode));

    // The three numbers the export page's warning and RFC-018 §7's measurement
    // are made of. Each costs one atomic on a branch most pixels do not take.
    //
    //   stats[0]  the knee acted on this pixel  (RFC-018 §5.3's `d > threshold`)
    //   stats[1]  still on the container's limits after encoding
    //   stats[2]  the destination could not hold it (`d > 1`, before the knee)
    //
    // `stats[1]` is at or past 0 or 1, not merely near them: the texture is
    // unorm, so those are the pixels whose detail the container has actually
    // taken. A NaN is counted by neither comparison and so by neither total,
    // which is the honest reading — it is not at a limit, it is not a number.
    if (moved) atomic_fetch_add_explicit(&stats[0], 1u, memory_order_relaxed);
    if (any(enc <= 0.0f) || any(enc >= 1.0f)) atomic_fetch_add_explicit(&stats[1], 1u, memory_order_relaxed);
    if (outside) atomic_fetch_add_explicit(&stats[2], 1u, memory_order_relaxed);

    dst.write(float4(enc, 1.0f), gid);
}
