// Compensated float-pair arithmetic. The sum/product/add/mul routines are
// the proven geometry_resample_df implementation, including CPU-Vulkan FMA
// detection. div/sqrt retain the same low-word discipline for log-axis nodes.
#ifndef SPK_FLOAT_PAIR_GLSL
#define SPK_FLOAT_PAIR_GLSL
layout(constant_id = 0) const bool SPK_FUSED_FMA = true;
vec2 spk_df_sum(float a, float b) {
    precise float s = a + b;
    precise float bb = s - a;
    precise float e = (a - (s - bb)) + (b - bb);
    return vec2(s, e);
}

vec2 spk_df_quick_sum(float a, float b) {
    precise float s = a + b;
    precise float e = b - (s - a);
    return vec2(s, e);
}

vec2 spk_df_prod(float a, float b) {
    precise float p = a * b;
    if (SPK_FUSED_FMA) {
        precise float e = fma(a, b, -p);
        return vec2(p, e);
    }
    // A device that does not fuse fma (lavapipe) would return e == 0 above
    // and lose the low word. Veltkamp/Dekker splitting gives the same exact
    // error term with plain products, so both paths produce identical pairs.
    precise float ca = 4097.0 * a;
    precise float ahi = ca - (ca - a);
    precise float alo = a - ahi;
    precise float cb = 4097.0 * b;
    precise float bhi = cb - (cb - b);
    precise float blo = b - bhi;
    precise float e = ((ahi * bhi - p) + ahi * blo + alo * bhi) + alo * blo;
    return vec2(p, e);
}

vec2 spk_df_add(vec2 a, vec2 b) {
    vec2 s = spk_df_sum(a.x, b.x);
    vec2 t = spk_df_sum(a.y, b.y);
    precise float lo = s.y + t.x;
    s = spk_df_quick_sum(s.x, lo);
    precise float final_lo = s.y + t.y;
    return spk_df_quick_sum(s.x, final_lo);
}

vec2 spk_df_sub(vec2 a, vec2 b) { return spk_df_add(a, -b); }

vec2 spk_df_mul(vec2 a, vec2 b) {
    vec2 p = spk_df_prod(a.x, b.x);
    precise float cross_terms = a.x * b.y + a.y * b.x;
    precise float lo = p.y + cross_terms;
    return spk_df_quick_sum(p.x, lo);
}

vec2 spk_df_mul_f(vec2 a, float b) {
    vec2 p = spk_df_prod(a.x, b);
    precise float lo = p.y + a.y * b;
    return spk_df_quick_sum(p.x, lo);
}

vec2 spk_df_div(vec2 a, vec2 b) {
    precise float q = a.x / b.x;
    vec2 r = spk_df_add(a, -spk_df_mul(vec2(q, 0), b));
    return spk_df_sum(q, (r.x + r.y) / b.x);
}
vec2 spk_df_sqrt(vec2 a) {
    if (a.x == 0.0 && a.y == 0.0) return vec2(0);
    precise float r = sqrt(a.x);
    vec2 e = spk_df_add(a, -spk_df_mul(vec2(r, 0), vec2(r, 0)));
    return spk_df_sum(r, (e.x + e.y) / (2.0*r));
}
#endif
