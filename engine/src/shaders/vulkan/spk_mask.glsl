// spk_mask.glsl -- contrast_mask.metal's shared helpers (RFC-024's virtual contrast mask), for
// spk_mask_reduce.comp and spk_mask_epilogue.comp. Expression for expression; Metal's fmax (NaN -> 0)
// and rsqrt spelled out. Expects the including kernel to declare the `cmy`, `chd`, `base_data`,
// `ixs` and `p` buffers. p: 0..2 the enlarger's setup gain, 3..5 1 / A_ref, 6..8 the pre-flash
// offset, 9 k_lo 10 h_lo 11 lo_on, 12 k_hi 13 h_hi 14 hi_on, 15 the gain limit (stops).

const float kMaskLog2Floor = -20.0;

float mask_max0(float x) { return (isnan(x) || x < 0.0) ? 0.0 : x; }

vec3 mask_image_exposure(uint i, uint nl) {
    float c0 = cmy.value[3u * i], c1 = cmy.value[3u * i + 1u], c2 = cmy.value[3u * i + 2u];
    float a0 = 0.0, a1 = 0.0, a2 = 0.0;
    for (uint l = 0u; l < nl; ++l) {
        float d = c0 * chd.value[3u * l] + c1 * chd.value[3u * l + 1u] + c2 * chd.value[3u * l + 2u] + base_data.value[l];
        float t = exp2(-d * 3.321928094887362);
        a0 += t * ixs.value[3u * l]; a1 += t * ixs.value[3u * l + 1u]; a2 += t * ixs.value[3u * l + 2u];
    }
    return vec3(a0 * p.value[0], a1 * p.value[1], a2 * p.value[2]);
}

float mask_x(vec3 a) {
    float s = 0.0;
    for (uint c = 0u; c < 3u; ++c) {
        float r = mask_max0(a[c] * p.value[3u + c]);
        s += max(log2(r), kMaskLog2Floor);   // log2(0) = -inf, then the floor
    }
    return s * (1.0 / 3.0);
}

// RFC-023's m = 2 branch, D * H / sqrt(H^2 + D^2).
float mask_g(float d, float h) { return d * h * inversesqrt(h * h + d * d); }

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
