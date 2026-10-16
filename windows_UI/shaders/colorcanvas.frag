#version 440
// The picture of a FrameCanvas through the display LUT (ColorPipeline.hpp).
// Built once per variant (windows_UI/CMakeLists.txt):
//   LUT_MODE 0  no lookup (the identity LUT), with the dither a deep frame
//               gets and the inherited opacity;
//   LUT_MODE 1  the LUT as a 3D texture, filtered by the sampler;
//   LUT_MODE 2  the LUT as a 2D atlas (N slices of N x N side by side along x)
//               for an RHI without 3D textures: bilinear within a slice, the
//               mix between the two nearest blue slices done here;
//   LUT_MODE 3  a bare texture read: an 8-bit frame under the identity at full
//               opacity, which must render exactly as Qt's texture node did.
// CURVES 1 (with LUT_MODE 1 or 2) adds the contract's 1-D curves around the
// table: shaper per channel, table, output curve indexed by sqrt.
// The frame is sampled first and the LUT applied per screen pixel, so the
// canvas filtering happens in the source encoding, as the contract says.
// Frame textures hold premultiplied alpha (ColorCanvasNode.cpp).
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float lutScale;        // (N - 1) / N
    float lutOffset;       // 0.5 / N
    float lutSize;         // N
    float ditherAmplitude; // 0, or one 8-bit output step (1/255)
    float curveScale;      // (M - 1) / M, M = curve entries
    float curveOffset;     // 0.5 / M
};

layout(binding = 1) uniform sampler2D frameTexture;
#if LUT_MODE == 1
layout(binding = 2) uniform sampler3D lutTexture;
#elif LUT_MODE == 2
layout(binding = 2) uniform sampler2D lutTexture;
#endif
#if CURVES
// M x 2: the shaper in row 0, the output curve in row 1, read at row centres.
layout(binding = 3) uniform sampler2D curveTexture;

// Each channel through its own curve, at texel centres like the table. The
// sampler's filtering is fine here: with 4096 entries even an 8-bit weight
// is within 1e-6 of the exact position.
vec3 curve(vec3 x, float row)
{
    vec3 c = x * curveScale + curveOffset;
    return vec3(texture(curveTexture, vec2(c.r, row)).r,
                texture(curveTexture, vec2(c.g, row)).g,
                texture(curveTexture, vec2(c.b, row)).b);
}

vec3 node(ivec3 i)
{
#if LUT_MODE == 1
    return texelFetch(lutTexture, i, 0).rgb;
#else
    return texelFetch(lutTexture, ivec2(i.b * int(lutSize) + i.r, i.g), 0).rgb;
#endif
}

// With curves the table works on the shaper's output, linear light, where
// the shadows fall inside the first cell. A sampler's filter weights carry
// only the 8 fractional bits D3D11 promises, 1/256 of a cell: measured on
// WARP, the gamma-2.2 round trip lost (2, 0, 10) to black. So the eight
// nodes are fetched and interpolated in float.
vec3 lookupExact(vec3 c)
{
    vec3 p = c * (lutSize - 1.0);
    vec3 cell = min(floor(p), vec3(lutSize - 2.0));
    vec3 f = p - cell;
    ivec3 i = ivec3(cell);
    vec3 c00 = mix(node(i), node(i + ivec3(1, 0, 0)), f.r);
    vec3 c10 = mix(node(i + ivec3(0, 1, 0)), node(i + ivec3(1, 1, 0)), f.r);
    vec3 c01 = mix(node(i + ivec3(0, 0, 1)), node(i + ivec3(1, 0, 1)), f.r);
    vec3 c11 = mix(node(i + ivec3(0, 1, 1)), node(i + ivec3(1, 1, 1)), f.r);
    return mix(mix(c00, c10, f.g), mix(c01, c11, f.g), f.b);
}
#endif

#if LUT_MODE == 1 || LUT_MODE == 2
// Node i of the LUT sits at the centre of texel i: an input c in [0,1] is
// addressed at c * (N - 1) / N + 0.5 / N, so 0 and 1 land on the first and
// last nodes instead of half a texel outside them. It matters doubly for the
// 3D texture: the scene graph's sampler repeats along the third axis, so
// blue = 0 addressed at 0 would average the first and last slices (measured:
// a channel swap turned black into 128 without the offset).
vec3 lookup(vec3 c)
{
#if LUT_MODE == 1
    return texture(lutTexture, c * lutScale + lutOffset).rgb;
#else
    float slice = c.b * (lutSize - 1.0);
    float b0 = min(floor(slice), lutSize - 2.0);
    float x = c.r * lutScale + lutOffset;
    float y = c.g * lutScale + lutOffset;
    vec3 near = texture(lutTexture, vec2((b0 + x) / lutSize, y)).rgb;
    vec3 far = texture(lutTexture, vec2((b0 + 1.0 + x) / lutSize, y)).rgb;
    return mix(near, far, slice - b0);
#endif
}
#endif

#if LUT_MODE != 3
// Wang's integer hash. Integer arithmetic gives the same dither pattern on
// every backend; the CPU path (ColorCanvasNode.cpp) uses the same function.
uint wang(uint h)
{
    h = (h ^ 61u) ^ (h >> 16u);
    h *= 9u;
    h ^= h >> 4u;
    h *= 0x27d4eb2du;
    h ^= h >> 15u;
    return h;
}

// Difference of two uniform variates: triangular on (-1, 1).
float triangular(uint h)
{
    return (float(h & 0xffffu) - float(h >> 16u)) / 65536.0;
}
#endif

void main()
{
#if LUT_MODE == 3
    fragColor = texture(frameTexture, vTexCoord);
#else
    vec4 c = texture(frameTexture, vTexCoord);
    vec3 rgb = clamp(c.a > 0.0 ? c.rgb / c.a : vec3(0.0), 0.0, 1.0);
#if CURVES
    // The shaper's output is clamped like any table input.
    rgb = clamp(curve(rgb, 0.25), 0.0, 1.0);
    rgb = clamp(lookupExact(rgb), 0.0, 1.0);
    rgb = clamp(curve(sqrt(rgb), 0.75), 0.0, 1.0);
#elif LUT_MODE != 0
    rgb = clamp(lookup(rgb), 0.0, 1.0);
#endif
    if (ditherAmplitude > 0.0) {
        uint h = wang(uint(gl_FragCoord.x) ^ wang(uint(gl_FragCoord.y)));
        uint hg = wang(h);
        uint hb = wang(hg);
        rgb += vec3(triangular(h), triangular(hg), triangular(hb)) * ditherAmplitude;
    }
    fragColor = vec4(rgb * c.a, c.a) * qt_Opacity;
#endif
}
