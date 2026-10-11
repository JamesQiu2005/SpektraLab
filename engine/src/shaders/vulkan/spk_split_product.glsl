// Error-free product for bounded normal inputs, without relying on fma.
// Keep these operations precise: reassociation loses the low word.
vec2 spk_split_product(float a, float b) {
    precise float p = a * b;
    precise float ca = 4097.0 * a;
    precise float ahi = ca - (ca - a);
    precise float alo = a - ahi;
    precise float cb = 4097.0 * b;
    precise float bhi = cb - (cb - b);
    precise float blo = b - bhi;
    precise float e = ((ahi * bhi - p) + ahi * blo + alo * bhi) + alo * blo;
    return vec2(p, e);
}
