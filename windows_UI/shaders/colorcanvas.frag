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
// PROOF 1 (with LUT_MODE 0, 1 or 2) is the soft proof (ProofTransform.hpp):
// the export's transform per pixel -- the source curve off, the engine's 3x3,
// CAM16-UCS gamut compression into the recipe's space, the file's clamp --
// then the display LUT *for the recipe space*: past its shaper with curves
// (the table takes the recipe space's linear light), at the recipe space's
// encoded value without; the identity shows that encoded value. Then the gamut
// warning over every pixel the export could not keep.
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
    // offset 272: the soft proof's gamut warning. rgb is a *display* value,
    // written over a flagged pixel after the LUT and the dither, never
    // through the LUT (AGENTS.md trap 27); a = 1 while the warning is on.
    vec4 warning;
    // offset 288: the export transform's numbers (spkhost::Output-
    // TransformParameters, all from spk_output_transform): three row-major
    // 3x3s as vec4 rows, CAM16's 22 constants, the curves' modes and the
    // C_max table's size. Unused outside the PROOF variants.
    vec4 proofMatrix[3];   // 288: source linear -> target linear
    vec4 proofToXyz[3];    // 336: target RGB -> XYZ (adapted)
    vec4 proofToRgb[3];    // 384: XYZ -> target RGB
    vec4 proofK[6];        // 432: k[0..21]
    vec4 proofModes;       // 528: source cctf, target cctf, CAM16 on, lightness on
    vec4 proofTable;       // 544: C_max rows (L), columns (h), identity, 0
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

#if PROOF
// C_max(J', h'): one float per texel, columns h, rows L; only fetched.
layout(binding = 5) uniform sampler2D cmaxTexture;

// engine/host/output.cpp's transfer functions, numbered as the macOS shader
// numbers them: 0 sRGB (and Display P3), 1 ProPhoto, 2 Adobe RGB (1998),
// 3 BT.709/2020, else the identity.
float spow(float v, float p)
{
    return sign(v) * pow(abs(v), p);
}
float cctfDecode(float v, int mode)
{
    if (mode == 0) return (0.040449936 >= v) ? v / 12.92 : spow((v + 0.055) / 1.055, 2.4);
    if (mode == 1) return (v < 16.0 / 512.0) ? v / 16.0 : pow(v, 1.8);
    if (mode == 2) return pow(v, 563.0 / 256.0);
    if (mode == 3) {
        float bp = 1.099 * pow(0.018, 0.45) - 0.099;
        return (bp > v) ? v / 4.5 : spow((v + 0.099) / 1.099, 1.0 / 0.45);
    }
    return v;
}
float cctfEncode(float v, int mode)
{
    if (mode == 0) return (v <= 0.0031308) ? 12.92 * v : 1.055 * spow(v, 1.0 / 2.4) - 0.055;
    if (mode == 1) return (v < 1.0 / 512.0) ? v * 16.0 : pow(v, 1.0 / 1.8);
    if (mode == 2) return pow(v, 256.0 / 563.0);
    if (mode == 3) return (0.018 > v) ? v * 4.5 : 1.099 * spow(v, 0.45) - 0.099;
    return v;
}

float cmaxAt(int h, int l)
{
    return texelFetch(cmaxTexture, ivec2(h, l), 0).r;
}

// engine/host/output.cpp cam16ucs_into (the macOS shader's cam16ucsInto)
// line for line, in float: into the target's gamut, rolling rather than
// cutting. `outside`: the chroma was past what the target holds (d > 1,
// before the knee).
vec3 cam16ucsInto(vec3 rgb, out bool outside)
{
    float F_L = proofK[0].x, N_bb = proofK[0].y, N_cb = proofK[0].z, n_ = proofK[0].w;
    float z = proofK[1].x, A_w = proofK[1].y, c_ = proofK[1].z, N_c = proofK[1].w;
    float L_grid0 = proofK[2].x, L_grid1 = proofK[2].y, h_grid0 = proofK[2].z, h_step = proofK[2].w;
    float threshold = proofK[3].x, limit = proofK[3].y, power_ = proofK[3].z;
    float lc_threshold = proofK[3].w, lc_limit = proofK[4].x, lc_power = proofK[4].y, L_white = proofK[4].z;
    float D0 = proofK[4].w, D1 = proofK[5].x, D2 = proofK[5].y;
    float e_c = pow(1.64 - pow(0.29, n_), 0.73);
    float inv_FL4 = pow(F_L, 0.25);

    vec3 xyz = vec3(dot(proofToXyz[0].xyz, rgb), dot(proofToXyz[1].xyz, rgb), dot(proofToXyz[2].xyz, rgb)) * 100.0;
    float X = xyz.x, Y = xyz.y, Z = xyz.z;
    float R = 0.401288 * X + 0.650173 * Y - 0.051461 * Z;
    float G = -0.250268 * X + 1.204414 * Y + 0.045854 * Z;
    float B = -0.002079 * X + 0.048952 * Y + 0.953127 * Z;

    float Rc = D0 * R, Gc = D1 * G, Bc = D2 * B;
    float sR = Rc >= 0.0 ? 1.0 : -1.0, sG = Gc >= 0.0 ? 1.0 : -1.0, sB = Bc >= 0.0 ? 1.0 : -1.0;
    float fR = pow(F_L * abs(Rc) / 100.0, 0.42);
    float fG = pow(F_L * abs(Gc) / 100.0, 0.42);
    float fB = pow(F_L * abs(Bc) / 100.0, 0.42);
    float Ra = 400.0 * sR * fR / (27.13 + fR) + 0.1;
    float Ga = 400.0 * sG * fG / (27.13 + fG) + 0.1;
    float Ba = 400.0 * sB * fB / (27.13 + fB) + 0.1;

    float a = Ra - 12.0 * Ga / 11.0 + Ba / 11.0;
    float bb = (Ra + Ga - 2.0 * Ba) / 9.0;
    float hrad = atan(bb, a);
    float e_t = 0.25 * (cos(hrad + 2.0) + 3.8);

    float A = (2.0 * Ra + Ga + Ba / 20.0 - 0.305) * N_bb;
    float Aratio = A / A_w;
    float sJ = Aratio >= 0.0 ? 1.0 : -1.0;
    float J = 100.0 * sJ * pow(abs(Aratio), c_ * z);

    float den = Ra + Ga + 21.0 * Ba / 20.0;
    float t = 0.0;
    if (den != 0.0) t = (50000.0 / 13.0 * N_c * N_cb * e_t * sqrt(a * a + bb * bb)) / den;
    float sq = sqrt(abs(J) / 100.0);
    float C = (t > 0.0) ? pow(t, 0.9) * sq * e_c : 0.0;
    float M = C * inv_FL4;

    float Mp = (1.0 / 0.0228) * log(1.0 + 0.0228 * M);
    float Jp = 1.7 * J / (1.0 + 0.007 * J);

    if (proofModes.w > 0.5) {
        float Ln = Jp / L_white;
        if (Ln > lc_threshold) {
            float lsc = lc_limit - lc_threshold;
            float lx = (Ln - lc_threshold) / lsc;
            float ly = lx / pow(1.0 + pow(lx, lc_power), 1.0 / lc_power);
            Ln = lc_threshold + lsc * ly;
        }
        Jp = Ln * L_white;
    }

    int nL = int(proofTable.x + 0.5), nh = int(proofTable.y + 0.5);
    float Lc = min(max(Jp, L_grid0), L_grid1);
    float Li = (Lc - L_grid0) / (L_grid1 - L_grid0) * float(nL - 1);
    int l0 = clamp(int(floor(Li)), 0, nL - 2);
    float lf = Li - float(l0);
    float hi_ = (hrad - h_grid0) / h_step;
    float hfl = floor(hi_);
    int h0 = int(hfl - float(nh) * floor(hfl / float(nh)));
    h0 = clamp(h0, 0, nh - 1);
    int h1 = (h0 + 1) % nh;
    float hf = hi_ - hfl;
    float c00 = cmaxAt(h0, l0), c01 = cmaxAt(h1, l0);
    float c10 = cmaxAt(h0, l0 + 1), c11 = cmaxAt(h1, l0 + 1);
    float Cmax = (1.0 - lf) * ((1.0 - hf) * c00 + hf * c01) + lf * ((1.0 - hf) * c10 + hf * c11);
    float safe = Cmax > 1e-9 ? Cmax : 1e-9;

    float d = Mp / safe;
    outside = d > 1.0;
    if (d > threshold) {
        float sc = limit - threshold;
        float xk = (d - threshold) / sc;
        float yk = xk / pow(1.0 + pow(xk, power_), 1.0 / power_);
        d = threshold + sc * yk;
    }
    float Mp_new = d * safe;

    float M_new = (exp(Mp_new * 0.0228) - 1.0) / 0.0228;
    float J_new = Jp / (1.7 - 0.007 * Jp);
    float C_new = M_new / inv_FL4;

    float sJ2 = J_new >= 0.0 ? 1.0 : -1.0;
    float A2 = A_w * sJ2 * pow(abs(J_new) / 100.0, 1.0 / (c_ * z));
    float sq2 = sqrt(abs(J_new) / 100.0);
    float t2 = (sq2 > 0.0 && C_new > 0.0) ? pow(C_new / (sq2 * e_c), 1.0 / 0.9) : 0.0;
    float ca = cos(hrad), sa = sin(hrad);
    float p2 = A2 / N_bb + 0.305;
    float p3 = 21.0 / 20.0;
    float a2, b2;
    if (t2 == 0.0) { a2 = 0.0; b2 = 0.0; }
    else {
        float p1 = ((50000.0 / 13.0) * N_c * N_cb * e_t) / t2;
        if (abs(sa) >= abs(ca)) {
            float p4 = p1 / sa;
            b2 = (p2 * (2.0 + p3) * (460.0 / 1403.0)) /
                 (p4 + (2.0 + p3) * (220.0 / 1403.0) * (ca / sa) - (27.0 / 1403.0) + p3 * (6300.0 / 1403.0));
            a2 = b2 * (ca / sa);
        } else {
            float p5 = p1 / ca;
            a2 = (p2 * (2.0 + p3) * (460.0 / 1403.0)) /
                 (p5 + (2.0 + p3) * (220.0 / 1403.0) - ((27.0 / 1403.0) - p3 * (6300.0 / 1403.0)) * (sa / ca));
            b2 = a2 * (sa / ca);
        }
    }
    float Ra2 = (460.0 * p2 + 451.0 * a2 + 288.0 * b2) / 1403.0;
    float Ga2 = (460.0 * p2 - 891.0 * a2 - 261.0 * b2) / 1403.0;
    float Ba2 = (460.0 * p2 - 220.0 * a2 - 6300.0 * b2) / 1403.0;

    vec3 va = vec3(Ra2, Ga2, Ba2) - 0.1;
    vec3 base = vec3(abs(va.x) < 400.0 ? (27.13 * abs(va.x)) / (400.0 - abs(va.x)) : 0.0,
                     abs(va.y) < 400.0 ? (27.13 * abs(va.y)) / (400.0 - abs(va.y)) : 0.0,
                     abs(va.z) < 400.0 ? (27.13 * abs(va.z)) / (400.0 - abs(va.z)) : 0.0);
    vec3 sv = vec3(va.x >= 0.0 ? 1.0 : -1.0, va.y >= 0.0 ? 1.0 : -1.0, va.z >= 0.0 ? 1.0 : -1.0);
    float Rf = (100.0 / F_L) * sv.x * pow(base.x, 1.0 / 0.42) / D0;
    float Gf = (100.0 / F_L) * sv.y * pow(base.y, 1.0 / 0.42) / D1;
    float Bf = (100.0 / F_L) * sv.z * pow(base.z, 1.0 / 0.42) / D2;

    vec3 xyzNew = vec3(1.86206786 * Rf - 1.01125463 * Gf + 0.14918677 * Bf,
                       0.38752654 * Rf + 0.62144744 * Gf - 0.00897398 * Bf,
                       -0.01584150 * Rf - 0.03412294 * Gf + 1.04996444 * Bf) / 100.0;
    return vec3(dot(proofToRgb[0].xyz, xyzNew), dot(proofToRgb[1].xyz, xyzNew), dot(proofToRgb[2].xyz, xyzNew));
}

// The export transform on one encoded source colour: the recipe space's
// linear light, clamped as the file is; `flag` 0 where the export could not
// keep the colour (outside, or clipped by more than kProofClipTolerance).
vec3 proofLinear(vec3 e, out float flag)
{
    int src = int(proofModes.x + 0.5);
    vec3 v = vec3(cctfDecode(e.r, src), cctfDecode(e.g, src), cctfDecode(e.b, src));
    vec3 lin = v;
    bool outside = false;
    if (proofTable.z < 0.5) {
        lin = vec3(dot(proofMatrix[0].xyz, v), dot(proofMatrix[1].xyz, v), dot(proofMatrix[2].xyz, v));
        if (proofModes.z > 0.5) lin = cam16ucsInto(lin, outside);
    }
    bool clipped = !(lin.r >= -1e-4 && lin.r <= 1.0001 && lin.g >= -1e-4 && lin.g <= 1.0001 &&
                     lin.b >= -1e-4 && lin.b <= 1.0001);
    flag = (outside || clipped) ? 0.0 : 1.0;
    // NaN fails both comparisons and lands on black, as the CPU path's.
    return vec3(lin.r > 0.0 ? min(lin.r, 1.0) : 0.0, lin.g > 0.0 ? min(lin.g, 1.0) : 0.0,
                lin.b > 0.0 ? min(lin.b, 1.0) : 0.0);
}

vec3 proofEncode(vec3 lin)
{
    int dst = int(proofModes.y + 0.5);
    return clamp(vec3(cctfEncode(lin.r, dst), cctfEncode(lin.g, dst), cctfEncode(lin.b, dst)), 0.0, 1.0);
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
#if PROOF
    float flag;
    vec3 lin = proofLinear(clamp(rgb, 0.0, 1.0), flag);
#if CURVES
    // Past the shaper (the recipe space's decode): the table takes linear light.
    rgb = clamp(lookup(lin), 0.0, 1.0);
    rgb = clamp(curve(sqrt(rgb), 1), 0.0, 1.0);
#elif LUT_MODE != 0
    rgb = clamp(lookup(proofEncode(lin)), 0.0, 1.0);
#else
    rgb = proofEncode(lin);
#endif
#else
#if CURVES
    // The shaper's output is clamped like any table input.
    rgb = clamp(curve(rgb, 0), 0.0, 1.0);
    rgb = clamp(lookup(rgb), 0.0, 1.0);
    rgb = clamp(curve(sqrt(rgb), 1), 0.0, 1.0);
#elif LUT_MODE != 0
    rgb = clamp(lookup(rgb), 0.0, 1.0);
#endif
#endif
    if (ditherAmplitude > 0.0) {
        uint h = wang(uint(gl_FragCoord.x) ^ wang(uint(gl_FragCoord.y)));
        uint hg = wang(h);
        uint hb = wang(hg);
        rgb += vec3(triangular(h), triangular(hg), triangular(hb)) * ditherAmplitude;
    }
#if PROOF
    // A display value over what the export cannot keep, after the dither.
    if (warning.a > 0.0 && flag < 0.5)
        rgb = warning.rgb;
#endif
    fragColor = vec4(rgb * c.a, c.a) * qt_Opacity;
#endif
}
