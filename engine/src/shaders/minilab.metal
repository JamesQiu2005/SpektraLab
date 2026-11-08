// The original spectral, curve and trilinear operations, kept in registers.
#include "spk_common.h"
kernel void spk_minilab(device const float* cmy [[buffer(0)]],
 device const float* chd [[buffer(1)]], device const float* base [[buffer(2)]],
 device const float* ixs [[buffer(3)]], device const float* ep [[buffer(4)]],
 device const uint* meta [[buffer(5)]], device const float* xa [[buffer(6)]],
 device const float* inv [[buffer(7)]], device const float* y [[buffer(8)]],
 device const float* lut [[buffer(9)]], device const float* lo [[buffer(10)]],
 device const float* inv_span [[buffer(11)]], device float* out [[buffer(12)]],
 uint3 pos [[thread_position_in_grid]]) {
 uint i=pos.x, gid=i, n=meta[0], nl=meta[1], mode=0u, K=meta[2], S=meta[3];
 if (i>=n) return;
    float c0 = cmy[3u * i], c1 = cmy[3u * i + 1u], c2 = cmy[3u * i + 2u];
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    for (uint l = 0u; l < nl; ++l) {
        float d = c0 * chd[3u * l] + c1 * chd[3u * l + 1u] + c2 * chd[3u * l + 2u] + base[l];
        float t = exp2(-d * 3.321928094887362f);
        a0 += t * ixs[3u * l]; a1 += t * ixs[3u * l + 1u]; a2 += t * ixs[3u * l + 2u];
    }
    // epilogue: v = a * gain + offset; mode 0 -> log10(max(v,0)+1e-10); mode 1 -> max(v,0)+1e-10
    float v0 = max(a0 * ep[0] + ep[3], 0.0f) + 1e-10f;
    float v1 = max(a1 * ep[1] + ep[4], 0.0f) + 1e-10f;
    float v2 = max(a2 * ep[2] + ep[5], 0.0f) + 1e-10f;
    if (mode == 0u) { v0 = log10(v0); v1 = log10(v1); v2 = log10(v2); }

 float positive[3];
 positive[0]=interp_channel(xa,inv,y,K,0u,v0);
 positive[1]=interp_channel(xa,inv,y,K,1u,v1);
 positive[2]=interp_channel(xa,inv,y,K,2u,v2);
 { // The original lookup's c0/c1/c2 names are deliberately unchanged.
    float fS = (float)(S - 1);
    float c0 = (positive[0] - lo[0]) * inv_span[0];
    float c1 = (positive[1] - lo[1]) * inv_span[1];
    float c2 = (positive[2] - lo[2]) * inv_span[2];
    c0 = clamp(c0, 0.0f, 1.0f) * fS;
    c1 = clamp(c1, 0.0f, 1.0f) * fS;
    c2 = clamp(c2, 0.0f, 1.0f) * fS;

    uint i0 = (uint)floor(c0); uint j0 = (uint)floor(c1); uint k0 = (uint)floor(c2);
    float fx = c0 - (float)i0, fy = c1 - (float)j0, fz = c2 - (float)k0;
    uint i1 = min(i0 + 1u, S - 1u);
    uint j1 = min(j0 + 1u, S - 1u);
    uint k1 = min(k0 + 1u, S - 1u);

    // Row-major (S, S, S, 3): index = ((i*S + j)*S + k)*3 + ch
    uint b00 = ((i0 * S + j0) * S) * 3u;
    uint b01 = ((i0 * S + j1) * S) * 3u;
    uint b10 = ((i1 * S + j0) * S) * 3u;
    uint b11 = ((i1 * S + j1) * S) * 3u;
    uint k0o = k0 * 3u, k1o = k1 * 3u;

    float w0 = 1.0f - fx, w1 = fx;
    float v0 = 1.0f - fy, v1 = fy;
    float u0 = 1.0f - fz, u1 = fz;

    for (uint ch = 0; ch < 3u; ++ch) {
        float c000 = lut[b00 + k0o + ch], c001 = lut[b00 + k1o + ch];
        float c010 = lut[b01 + k0o + ch], c011 = lut[b01 + k1o + ch];
        float c100 = lut[b10 + k0o + ch], c101 = lut[b10 + k1o + ch];
        float c110 = lut[b11 + k0o + ch], c111 = lut[b11 + k1o + ch];
        float c00 = c000 * u0 + c001 * u1;
        float c01 = c010 * u0 + c011 * u1;
        float c10 = c100 * u0 + c101 * u1;
        float c11 = c110 * u0 + c111 * u1;
        out[3*gid + ch] = (c00 * v0 + c01 * v1) * w0 + (c10 * v0 + c11 * v1) * w1;
    }
 }
}
