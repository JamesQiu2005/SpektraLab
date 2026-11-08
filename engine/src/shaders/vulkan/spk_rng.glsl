// GLSL translation of the random primitives in spk_common.h. Keep the
// Philox counter/key layout, draw ordering, and exact Poisson sampler intact.
#ifndef SPK_RNG_GLSL
#define SPK_RNG_GLSL

uvec4 philox4x32_10(uvec4 ctr, uvec2 key) {
    for (int r = 0; r < 10; ++r) {
        uint hi0, lo0, hi1, lo1;
        umulExtended(0xD2511F53u, ctr.x, hi0, lo0);
        umulExtended(0xCD9E8D57u, ctr.z, hi1, lo1);
        ctr = uvec4(hi1 ^ ctr.y ^ key.x, lo1, hi0 ^ ctr.w ^ key.y, lo0);
        key.x += 0x9E3779B9u; key.y += 0xBB67AE85u;
    }
    return ctr;
}
float u01(uint x) { return (float(x >> 8) + 0.5) * (1.0 / 16777216.0); }

struct Rng { uvec4 ctr; uvec2 key; uvec4 buf; int n; };
Rng rng_init(uint pixel, uint stream, uint seed) {
    return Rng(uvec4(pixel, stream, 0u, 0u), uvec2(seed, 0u), uvec4(0u), 0);
}
float rng_next(inout Rng rng) {
    if (rng.n == 0) { rng.buf = philox4x32_10(rng.ctr, rng.key); rng.ctr.z += 1u; rng.n = 4; }
    uint v = rng.buf.x; rng.buf = rng.buf.yzwx; rng.n -= 1;
    return u01(v);
}
float rng_normal(inout Rng rng) {
    precise float u1 = rng_next(rng), u2 = rng_next(rng);
    return sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2);
}
float loggam(float x) {
    const float a0 = 8.333333333333333e-02, a1 = -2.777777777777778e-03, a2 = 7.936507936507937e-04,
                a3 = -5.952380952380952e-04, a4 = 8.417508417508418e-04;
    precise float x0 = x; int n = 0;
    if (x == 1.0 || x == 2.0) return 0.0;
    if (x <= 7.0) { n = int(7.0 - x); x0 = x + float(n); }
    precise float x2 = 1.0 / (x0 * x0);
    precise float gl0 = a4; gl0 = gl0 * x2 + a3; gl0 = gl0 * x2 + a2; gl0 = gl0 * x2 + a1; gl0 = gl0 * x2 + a0;
    precise float gl = gl0 / x0 + 0.5 * log(6.283185307179586) + (x0 - 0.5) * log(x0) - x0;
    if (x <= 7.0) for (int k = 1; k <= n; ++k) { gl -= log(x0 - 1.0); x0 -= 1.0; }
    return gl;
}
// Exact PTRS for mu >= 10 and sequential search below, matching Metal.
// A Gaussian approximation loses the density-dependent third moment.
float poisson(inout Rng rng, float mu) {
    if (mu >= 10.0) {
        precise float slam = sqrt(mu), loglam = log(mu);
        precise float b = 0.931 + 2.53 * slam, a = -0.059 + 0.02483 * b;
        precise float invalpha = 1.1239 + 1.1328 / (b - 3.4), vr = 0.9277 - 3.6224 / (b - 2.0);
        for (int it = 0; it < 64; ++it) {
            precise float U = rng_next(rng) - 0.5, V = rng_next(rng);
            precise float us = 0.5 - abs(U);
            precise float k = floor((2.0 * a / us + b) * U + mu + 0.43);
            if (us >= 0.07 && V <= vr) return k;
            if (k < 0.0 || (us < 0.013 && V > us)) continue;
            precise float log_accept = log(V) + log(invalpha) - log(a / (us * us) + b);
            precise float log_mass = -mu + k * loglam - loggam(k + 1.0);
            if (log_accept <= log_mass) return k;
        }
        return floor(mu);
    }
    precise float enlam = exp(-mu), X = 0.0, prod = 1.0;
    for (int it = 0; it < 512; ++it) {
        prod *= rng_next(rng);
        if (prod > enlam) X += 1.0; else return X;
    }
    return X;
}
float layer_draw(inout Rng rng, float d, float dmax, float n, float u) {
    precise float p = d / dmax;
    p = clamp(p, 1e-6, 1.0 - 1e-6);
    precise float sat = 1.0 - p * u * (1.0 - 1e-6);
    precise float rate = (n / sat) * p;
    precise float od = dmax / n;
    return poisson(rng, rate) * (od * sat);
}
#endif
