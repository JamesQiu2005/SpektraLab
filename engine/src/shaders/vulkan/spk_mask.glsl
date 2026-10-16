// The half of contrast_mask.metal both mask kernels share: the enlarger's
// image-only exposure, RFC-024's `x`, and the bounded curve. Both kernels
// bind the same five buffers first, in Metal's order, so they are declared
// here once; each kernel declares its own from binding 5 on.
//
// `p` is contrast_mask.metal's parameter block:
//   0..2  the enlarger's setup gain (image exposure only)
//   3..5  1 / A_ref
//   6..8  the pre-flash offset (epilogue only)
//   9 k_lo  10 h_lo  11 lo_on    -- the print-highlight branch
//   12 k_hi 13 h_hi  14 hi_on    -- the print-shadow branch
//   15 the gain limit, stops
#ifndef SPK_MASK_GLSL
#define SPK_MASK_GLSL

layout(set = 0, binding = 0, std430) readonly buffer Input { float value[]; } cmy;
layout(set = 0, binding = 1, std430) readonly buffer Characteristic { float value[]; } chd;
layout(set = 0, binding = 2, std430) readonly buffer Base { float value[]; } base_data;
layout(set = 0, binding = 3, std430) readonly buffer Integral { float value[]; } ixs;
layout(set = 0, binding = 4, std430) readonly buffer Params { float value[]; } p;

// vulkan_gpu.cpp folds a dispatch past maxComputeWorkGroupCount[0] (65535 on
// lavapipe and Intel) into rows of workgroups; this is the 1D index it means.
uint spk_global_index() {
    return gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
}

// Metal's kMaskLog2Floor: 2^-20 below mid-grey, ~6 densities under it. A
// numerical guard, not a signal.
const float kMaskLog2Floor = -20.0;

// spk_spectral_epilogue's integral, image exposure only, times the setup gain.
vec3 mask_image_exposure(uint i, uint nl) {
    float c0 = cmy.value[3u * i], c1 = cmy.value[3u * i + 1u], c2 = cmy.value[3u * i + 2u];
    float a0 = 0.0, a1 = 0.0, a2 = 0.0;
    for (uint l = 0u; l < nl; ++l) {
        float d = c0 * chd.value[3u * l] + c1 * chd.value[3u * l + 1u] + c2 * chd.value[3u * l + 2u]
                + base_data.value[l];
        float t = exp2(-d * 3.321928094887362);
        a0 += t * ixs.value[3u * l]; a1 += t * ixs.value[3u * l + 1u]; a2 += t * ixs.value[3u * l + 2u];
    }
    return vec3(a0 * p.value[0], a1 * p.value[1], a2 * p.value[2]);
}

// Metal writes `max(log2(max(r, 0)), floor)` and relies on its NaN-tolerant
// max and on log2(0) = -inf. SPIR-V leaves Log2 undefined at 0 and lets FMax
// return either operand of a NaN, so the same cases are explicit branches: a
// zero, negative or NaN ratio lands on the floor, as it does on Metal. On the
// RTX 3070 the literal transcription also passed the gate (its log2(0) is
// -inf and its max drops the NaN); the branches are for drivers that differ.
float mask_x(vec3 a) {
    float s = 0.0;
    for (uint c = 0u; c < 3u; ++c) {
        float r = a[c] * p.value[3u + c];
        float l = kMaskLog2Floor;
        if (r > 0.0) {
            l = log2(r);
            if (l < kMaskLog2Floor) l = kMaskLog2Floor;   // a flushed denormal's -inf too
        }
        s += l;
    }
    return s * (1.0 / 3.0);   // folds to the same float as Metal's 1.0f / 3.0f
}

// RFC-023's m = 2 branch, `D * H / sqrt(H^2 + D^2)`: slope 1 at the knee,
// asymptote H.
float mask_g(float d, float h) { return d * h * inversesqrt(h * h + d * d); }

// delta = f(b) - b, bounded. Exactly 0.0 inside the core and on a disabled
// branch, so the gain there is exp2(0) = 1. A NaN base fails both comparisons
// and gets 0 as well, on either backend.
float mask_delta(float b) {
    float delta = 0.0;
    if (p.value[11] != 0.0 && b < p.value[9]) {
        float d = p.value[9] - b;
        delta = d - mask_g(d, p.value[10]);
    } else if (p.value[14] != 0.0 && b > p.value[12]) {
        float d = b - p.value[12];
        delta = mask_g(d, p.value[13]) - d;
    }
    float lim = p.value[15];
    return delta * lim * inversesqrt(lim * lim + delta * delta);
}

#endif
