#version 440
#extension GL_GOOGLE_include_directive : enable
// The picture of a FrameCanvas through the display LUT (ColorPipeline.hpp).
// Built once per variant (windows_UI/CMakeLists.txt):
//   LUT_MODE 0  no lookup (the identity LUT), with the dither a deep frame
//               gets and the inherited opacity;
//   LUT_MODE 1  the table as a 3D texture (N x N x N, blue the slice);
//   LUT_MODE 2  the table as a 2D atlas (N slices of N x N side by side along
//               x) for an RHI without 3D textures;
//   LUT_MODE 3  a bare texture read: an 8-bit frame under the identity at full
//               opacity, which must render exactly as Qt's texture node did.
// CURVES 1 (with LUT_MODE 1 or 2) adds the contract's 1-D curves around the
// table: shaper per channel, table, output curve indexed by sqrt.
// The frame is sampled first and the LUT applied per screen pixel, so the
// canvas filtering happens in the source encoding, as the contract says.
// Frame textures hold premultiplied alpha (ColorCanvasNode.cpp).
//
// Every variant but the bare copy grades the sample with Post-Dev (Layer 2,
// shaders/postdev.glsl) after unpremultiplying and before the LUT, as the
// Mac's layer2 pass runs before its display transform. An inactive grade
// (bypassed or identity: grade.switches.x == 0) returns the sample untouched,
// and the node never picks the copy for an active one. sourceU/sourceV map
// the tile's texture coordinate to the sample's place on the uncropped,
// unturned source, where the vignette is: su = dot(sourceU.xyz, (t, 1)).
#include "postdev.glsl"

layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float lutSize;         // N, table nodes per axis
    float ditherAmplitude; // 0, or one 8-bit output step (1/255)
    float curveSize;       // M, entries per curve
    vec4 sourceU;          // offset 80
    vec4 sourceV;          // offset 96
    PostDev grade;         // offset 112, 160 bytes: postdev::std140()
};

layout(binding = 1) uniform sampler2D frameTexture;
#if LUT_MODE != 3
// 256 x 5, postdev::curveTables(); only fetched.
layout(binding = 4) uniform sampler2D postdevCurves;
#endif
#if LUT_MODE == 1
layout(binding = 2) uniform sampler3D lutTexture;
#elif LUT_MODE == 2
layout(binding = 2) uniform sampler2D lutTexture;
#endif

#if LUT_MODE == 1 || LUT_MODE == 2
vec3 node(ivec3 i)
{
#if LUT_MODE == 1
    return texelFetch(lutTexture, i, 0).rgb;
#else
    return texelFetch(lutTexture, ivec2(i.b * int(lutSize) + i.r, i.g), 0).rgb;
#endif
}

// The table, trilinear between its eight nodes around c in [0,1] (node i at
// i / (N - 1)), with float weights. A sampler's filter weights carry only the
// 8 fractional bits D3D11 promises, 1/256 of a cell. With curves the table
// holds linear light, where that is a fixed amount of light that the output
// curve magnifies near black: measured on WARP, hardware filtering turned the
// gamma-2.2 round trip's (2, 0, 10) to black, and the colour core measured
// 1.9 to 3.1 counts on this machine's display profile.
vec3 lookup(vec3 c)
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

#if CURVES
// M x 2: the shaper in row 0, the output curve in row 1.
layout(binding = 3) uniform sampler2D curveTexture;

// One channel of a curve at x in [0,1] (entry i at i / (M - 1)), linear
// between the two entries around it, with a float weight. The sampler could
// filter the curves well enough (the colour core: 0.03 counts on 8-bit
// weights), but these are 32-bit float textures, which a D3D11 device need
// not be able to filter at all; fetching needs no filtering support.
float curveChannel(float x, int row, int channel)
{
    float p = x * (curveSize - 1.0);
    float entry = min(floor(p), curveSize - 2.0);
    int i = int(entry);
    float a = texelFetch(curveTexture, ivec2(i, row), 0)[channel];
    float b = texelFetch(curveTexture, ivec2(i + 1, row), 0)[channel];
    return mix(a, b, p - entry);
}

// Each channel through its own curve.
vec3 curve(vec3 x, int row)
{
    return vec3(curveChannel(x.r, row, 0), curveChannel(x.g, row, 1), curveChannel(x.b, row, 2));
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
    vec3 t = vec3(vTexCoord, 1.0);
    rgb = postdev(rgb, vec2(dot(sourceU.xyz, t), dot(sourceV.xyz, t)), grade, postdevCurves);
#if CURVES
    // The shaper's output is clamped like any table input.
    rgb = clamp(curve(rgb, 0), 0.0, 1.0);
    rgb = clamp(lookup(rgb), 0.0, 1.0);
    rgb = clamp(curve(sqrt(rgb), 1), 0.0, 1.0);
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
