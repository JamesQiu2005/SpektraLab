// Original contrast_mask.metal exposure, coordinate and curve equations.
float spk_mask_log10(float v) { return log(v)*0.4342944819032518; }
const float kMaskLog2Floor = -20.0f;

vec3 mask_image_exposure(uint i, uint nl) {
    float c0 = cmy_data.value[3u * i], c1 = cmy_data.value[3u * i + 1u], c2 = cmy_data.value[3u * i + 2u];
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    for (uint l = 0u; l < nl; ++l) {
        float d = c0 * chd_data.value[3u * l] + c1 * chd_data.value[3u * l + 1u] + c2 * chd_data.value[3u * l + 2u] + base_data.value[l];
        float t = exp2(-d * 3.321928094887362f);
        a0 += t * ixs_data.value[3u * l]; a1 += t * ixs_data.value[3u * l + 1u]; a2 += t * ixs_data.value[3u * l + 2u];
    }
    return vec3(a0 * param_data.value[0], a1 * param_data.value[1], a2 * param_data.value[2]);
}

float mask_x(vec3 a) {
    float s = 0.0f;
    for (uint c = 0u; c < 3u; ++c) {
        float r = max(a[c] * param_data.value[3u + c], 0.0f);
        s += max(log2(r), kMaskLog2Floor);   // log2(0) = -inf, then the floor
    }
    return s * (1.0f / 3.0f);
}

// RFC-023's m = 2 branch, `D * H / sqrt(H^2 + D^2)`: slope 1 at the knee,
// asymptote H.
float mask_g(float d, float h) { return d * h * inversesqrt(h * h + d * d); }

// delta = f(b) - b, bounded. Exactly 0.0 inside the core and on a disabled
// branch, so the gain there is exp2(0) = 1.
float mask_delta(float b) {
    float delta = 0.0f;
    if (param_data.value[11] != 0.0f && b < param_data.value[9]) {
        float d = param_data.value[9] - b;
        delta = d - mask_g(d, param_data.value[10]);
    } else if (param_data.value[14] != 0.0f && b > param_data.value[12]) {
        float d = b - param_data.value[12];
        delta = mask_g(d, param_data.value[13]) - d;
    }
    // The same smooth-min bounds the gain itself (RFC-023 §15's fix for an
    // unbounded shadow gain): |delta| < limit for any base.
    float lim = param_data.value[15];
    return delta * lim * inversesqrt(lim * lim + delta * delta);
}

// The analysis: one thread per grid cell, the mean of `x` over the cell's
// pixels. The cells partition the frame (`[cx*W/gw, (cx+1)*W/gw)`), so every
// pixel is counted exactly once whatever the tier's size.
