// spk_trig.glsl -- atan2, sin and cos to float accuracy, independent of the driver.
//
// Vulkan's precision rules allow GLSL's built-ins far more error than Metal's precise mode: sin and
// cos 2^-11 absolute, atan 4096 ULP. A kernel whose result leans on them (the Digital
// Intermediate's hue window: hue -> rotate -> back to Oklab -> log encode) then disagrees with the
// Metal reference beyond the parity bar on some GPUs (Intel UHD 620: 8e-5 of a code value, where
// float32 arithmetic on the CPU agrees with double to 1e-7). These are the classic portable
// approximations, all well inside a float ULP or two:
//   atan:     Abramowitz & Stegun 4.4.49 (odd degree 15, |error| <= 2e-8 on [0, 1]), reflected;
//   sin, cos: Cody-Waite reduction by pi/2 in three parts, then Cephes sinf/cosf on [-pi/4, pi/4].

float spk_atan01(float z) {
    // z in [0, 1]
    precise float z2 = z * z;
    precise float p = -0.0040540580;
    p = p * z2 + 0.0218612288;
    p = p * z2 - 0.0559098861;
    p = p * z2 + 0.0964200441;
    p = p * z2 - 0.1390853351;
    p = p * z2 + 0.1994653599;
    p = p * z2 - 0.3332985605;
    p = p * z2 + 0.9999993329;
    return p * z;
}

float spk_atan2(float y, float x) {
    const float PI = 3.14159265358979323846;
    const float PI_2 = 1.57079632679489661923;
    float ax = abs(x), ay = abs(y);
    if (ax == 0.0 && ay == 0.0) return 0.0;   // no hue; callers weight it to zero (no chroma)
    float r = ay <= ax ? spk_atan01(ay / ax) : PI_2 - spk_atan01(ax / ay);
    if (x < 0.0) r = PI - r;
    return y < 0.0 ? -r : r;
}

// x reduced to [-pi/4, pi/4] and its quadrant.
float spk_reduce_pio2(float x, out int quadrant) {
    float j = floor(x * 0.63661977236758134308 + 0.5);   // round(x / (pi/2))
    quadrant = int(j) & 3;
    precise float r = ((x - j * 1.5703125) - j * 4.8375129699707031e-4) - j * 7.5497899548918821e-8;
    return r;
}

float spk_sin_poly(float x) {
    precise float z = x * x;
    return ((-1.9515295891e-4 * z + 8.3321608736e-3) * z - 1.6666654611e-1) * z * x + x;
}

float spk_cos_poly(float x) {
    precise float z = x * x;
    return ((2.443315711809948e-5 * z - 1.388731625493765e-3) * z + 4.166664568298827e-2) * z * z - 0.5 * z + 1.0;
}

float spk_sin(float x) {
    int q;
    float r = spk_reduce_pio2(x, q);
    float v = (q & 1) == 0 ? spk_sin_poly(r) : spk_cos_poly(r);
    return (q & 2) == 0 ? v : -v;
}

float spk_cos(float x) {
    int q;
    float r = spk_reduce_pio2(x, q);
    float v = (q & 1) == 0 ? spk_cos_poly(r) : spk_sin_poly(r);
    return ((q + 1) & 2) == 0 ? v : -v;
}
