// spk_lens.glsl -- helpers shared by the lens kernels (lens.metal on Vulkan).
//
// GLSL cannot pass a storage buffer to a function, so the loads and stores
// over a buffer's float array are macros, and a function that reads a named
// buffer is stamped out per buffer (SPK_GRID_UP_FN).
//
// **The fp16 levels.** lens.metal keeps the diffusion filter's pyramid levels
// and the combine's tile in `half`. Here they are fp32 buffers whose every
// value is rounded to fp16 first (`spk_q16`, round to nearest even, as Metal's
// float-to-half conversion): the same numbers, twice the memory (lens.cpp
// `kLevelBytes`), and no dependency on a device's 16-bit storage feature.

// vulkan_gpu.cpp folds a dispatch past maxComputeWorkGroupCount[0] (65535 on
// lavapipe and Intel) into rows of workgroups; this is the 1D index it means.
uint spk_global_index() {
    return gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
}

#define SPK_LD3(A, S) vec3((A)[3u * (S)], (A)[3u * (S) + 1u], (A)[3u * (S) + 2u])
#define SPK_ST3(A, S, V) { const uint s_ = 3u * (S); const vec3 v_ = (V); (A)[s_] = v_.x; (A)[s_ + 1u] = v_.y; (A)[s_ + 2u] = v_.z; }

// A float rounded to the nearest fp16 value (ties to even), returned as a
// float: Metal's `half(x)` read back by `float(...)`. Overflow (|x| >= 65520)
// is infinity, fp16 subnormals keep their 2^-24 quantum, NaN and inf pass.
float spk_q16(float x) {
    const uint u = floatBitsToUint(x);
    const uint sgn = u & 0x80000000u;
    uint a = u & 0x7fffffffu;
    if (a >= 0x7f800000u) return x;
    if (a >= 0x477ff000u) return uintBitsToFloat(sgn | 0x7f800000u);
    if (a < 0x38800000u) {   // below fp16's smallest normal, 2^-14
        const float r = roundEven(uintBitsToFloat(a) * 16777216.0) * (1.0 / 16777216.0);
        return uintBitsToFloat(floatBitsToUint(r) | sgn);
    }
    a += 0x00000fffu + ((a >> 13) & 1u);
    a &= 0xffffe000u;
    return uintBitsToFloat(sgn | a);
}
vec3 spk_q16v(vec3 v) { return vec3(spk_q16(v.x), spk_q16(v.y), spk_q16(v.z)); }

// Bilinear on a plane-anchored grid of factor f (lens.metal `grid_up`),
// stamped out for one buffer's float array.
#define SPK_GRID_UP_FN(NAME, ARR)                                                                  \
    vec3 NAME(int LH, int LW, int I0, uint f, float x, float Y) {                                  \
        float ff = float(f), c = 0.5 * float(f - 1u);                                              \
        float u = (x - c) / ff, v = (Y - c) / ff;                                                  \
        float uf = floor(u), vf = floor(v);                                                        \
        float fx = u - uf, fy = v - vf;                                                            \
        int j0 = clamp(int(uf), 0, LW - 1), j1 = clamp(int(uf) + 1, 0, LW - 1);                    \
        int i0 = clamp(int(vf) - I0, 0, LH - 1), i1 = clamp(int(vf) + 1 - I0, 0, LH - 1);          \
        vec3 v00 = SPK_LD3(ARR, uint(i0) * uint(LW) + uint(j0));                                   \
        vec3 v01 = SPK_LD3(ARR, uint(i0) * uint(LW) + uint(j1));                                   \
        vec3 v10 = SPK_LD3(ARR, uint(i1) * uint(LW) + uint(j0));                                   \
        vec3 v11 = SPK_LD3(ARR, uint(i1) * uint(LW) + uint(j1));                                   \
        return (1.0 - fy) * ((1.0 - fx) * v00 + fx * v01) + fy * ((1.0 - fx) * v10 + fx * v11);    \
    }

// node_boost's lift on the light the filter scatters (lens.metal
// `scatter_source`), stamped out for the buffer holding bp: {on, x0, 1/max, a, scale}.
#define SPK_SCATTER_SOURCE_FN(NAME, BP)                                                            \
    vec3 NAME(vec3 v) {                                                                            \
        if (BP[0] == 0.0) return v;                                                                \
        vec3 o;                                                                                    \
        for (int c = 0; c < 3; ++c) {                                                              \
            float x = v[c];                                                                        \
            if (x <= BP[1]) { o[c] = x; continue; }                                                \
            float dx = (x - BP[1]) * BP[2];                                                        \
            o[c] = x + BP[4] * (exp(BP[3] * dx) - BP[3] * dx - 1.0);                               \
        }                                                                                          \
        return o;                                                                                  \
    }
