// SPDX-License-Identifier: GPL-3.0-or-later
#include "raw_develop.hpp"

#include <algorithm>
#include <cmath>

namespace {
// Camera2's CFA arrangements: which colour sits at (x & 1, y & 1). 0 R, 1 G, 2 B.
int cfa_colour(int cfa, int x, int y) {
    static const int kLayout[4][4] = {  // [cfa][(y&1)*2 + (x&1)]
        {0, 1, 1, 2},   // RGGB
        {1, 0, 2, 1},   // GRBG
        {1, 2, 0, 1},   // GBRG
        {2, 1, 1, 0},   // BGGR
    };
    return kLayout[cfa & 3][(y & 1) * 2 + (x & 1)];
}
}  // namespace

std::vector<float> raw_to_prophoto(const RawInput& in, int& ow, int& oh, std::string& error) {
    const uint8_t* base = in.base;
    const int w = in.w, h = in.h, rowStride = in.rowStride, cfa = in.cfa, gw = in.gw, gh = in.gh;
    const std::vector<float>& black = in.black;
    const float white = in.white;
    const std::vector<float>& neutral = in.neutral;
    const std::vector<float>& fwd = in.fwd;
    const std::vector<float>& shading = in.shading;
    const std::vector<float>& dist = in.dist;
    const std::vector<float>& intr = in.intr;
    const float cropAspect = in.cropAspect;
    const int maxPixels = in.maxPixels;
    const float targetMedian = in.targetMedian;
    if (!base || w < 8 || h < 8) { error = "no RAW data"; return {}; }
    if (black.size() != 4 || neutral.size() != 3 || fwd.size() != 9) { error = "incomplete RAW metadata"; return {}; }
    // White balance gains from the as-shot neutral, the smallest at 1.
    float g[3];
    for (int c = 0; c < 3; ++c) g[c] = neutral[c] > 1e-6f ? 1.0f / neutral[c] : 1.0f;
    const float gmin = std::min({g[0], g[1], g[2]}), gmax = std::max({g[0], g[1], g[2]}) / gmin;
    for (float& v : g) v /= gmin;
    const bool shade = shading.size() == size_t(gw) * gh * 4 && gw > 1 && gh > 1;

    // 1. The mosaic: black subtracted, scaled to white, lens shading and white balance applied. Saturated sites
    //    go to the brightest white so clipped highlights stay neutral.
    std::vector<float> m(size_t(w) * h);
    for (int y = 0; y < h; ++y) {
        const auto* row = reinterpret_cast<const uint16_t*>(base + size_t(y) * rowStride);
        const float sy = float(y) / float(h - 1) * float(gh - 1);
        const int y0 = std::min(int(sy), gh - 2);
        const float fy = sy - float(y0);
        for (int x = 0; x < w; ++x) {
            const int col = cfa_colour(cfa, x, y);
            const float b = black[(y & 1) * 2 + (x & 1)];
            float v = (float(row[x]) - b) / std::max(1.0f, white - b);
            if (v >= 0.98f) { m[size_t(y) * w + x] = gmax; continue; }
            if (shade) {
                const int ch = col == 0 ? 0 : col == 2 ? 3 : ((y & 1) == 0 ? 1 : 2);
                const float sx = float(x) / float(w - 1) * float(gw - 1);
                const int x0 = std::min(int(sx), gw - 2);
                const float fx = sx - float(x0);
                auto at = [&](int gx, int gy) { return shading[(size_t(gy) * gw + gx) * 4 + ch]; };
                const float s = (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) +
                                (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy;
                v *= s;
            }
            m[size_t(y) * w + x] = std::max(0.0f, v) * g[col];
        }
    }

    // 2. Demosaic (Malvar, He and Cutler 2004), into camera RGB.
    auto M = [&](int x, int y) {
        x = x < 0 ? -x : (x >= w ? 2 * w - 2 - x : x);
        y = y < 0 ? -y : (y >= h ? 2 * h - 2 - y : y);
        return m[size_t(y) * w + x];
    };
    std::vector<float> rgb(size_t(w) * h * 3);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const float c = M(x, y);
            const int col = cfa_colour(cfa, x, y);
            float out[3];
            out[col] = c;
            if (col == 1) {
                // Green site: red and blue, from its row and its column.
                const float horiz = (5 * c + 4 * (M(x - 1, y) + M(x + 1, y)) - (M(x - 2, y) + M(x + 2, y)) -
                                     (M(x - 1, y - 1) + M(x + 1, y - 1) + M(x - 1, y + 1) + M(x + 1, y + 1)) +
                                     0.5f * (M(x, y - 2) + M(x, y + 2))) / 8;
                const float vert = (5 * c + 4 * (M(x, y - 1) + M(x, y + 1)) - (M(x, y - 2) + M(x, y + 2)) -
                                    (M(x - 1, y - 1) + M(x + 1, y - 1) + M(x - 1, y + 1) + M(x + 1, y + 1)) +
                                    0.5f * (M(x - 2, y) + M(x + 2, y))) / 8;
                const int rowColour = cfa_colour(cfa, x + 1, y);   // the non-green colour in this row
                if (rowColour == 0) { out[0] = horiz; out[2] = vert; } else { out[2] = horiz; out[0] = vert; }
            } else {
                const float green = (4 * c + 2 * (M(x - 1, y) + M(x + 1, y) + M(x, y - 1) + M(x, y + 1)) -
                                     (M(x - 2, y) + M(x + 2, y) + M(x, y - 2) + M(x, y + 2))) / 8;
                const float other = (6 * c + 2 * (M(x - 1, y - 1) + M(x + 1, y - 1) + M(x - 1, y + 1) + M(x + 1, y + 1)) -
                                     1.5f * (M(x - 2, y) + M(x + 2, y) + M(x, y - 2) + M(x, y + 2))) / 8;
                out[1] = green;
                out[col == 0 ? 2 : 0] = other;
            }
            float* d = &rgb[(size_t(y) * w + x) * 3];
            d[0] = std::max(0.0f, out[0]); d[1] = std::max(0.0f, out[1]); d[2] = std::max(0.0f, out[2]);
        }
    }
    std::vector<float>().swap(m);

    // 3. Camera RGB -> XYZ D50 (forward matrix) -> linear ProPhoto (D50), one matrix.
    static const float kXyzToProPhoto[9] = {1.3459433f, -0.2556075f, -0.0511118f, -0.5445989f, 1.5081673f, 0.0205351f,
                                            0.0f, 0.0f, 1.2118128f};
    float k[9];
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            k[r * 3 + c] = kXyzToProPhoto[r * 3] * fwd[c] + kXyzToProPhoto[r * 3 + 1] * fwd[3 + c] + kXyzToProPhoto[r * 3 + 2] * fwd[6 + c];

    // 4. The frame: the crop for the format, straightened (Camera2's lens model), scaled to the GPU's limit.
    int cw = w, ch = h;
    if (cropAspect > 0) {
        if (float(w) / float(h) > cropAspect) cw = int(std::lround(h * cropAspect)); else ch = int(std::lround(w / cropAspect));
    }
    const bool straighten = dist.size() == 5 && intr.size() == 5 && intr[0] > 0 && intr[1] > 0;
    // Where an output point samples the sensor once the lens is straightened (Camera2's LENS_DISTORTION model).
    auto lens = [&](float sx, float sy, float& ox, float& oy) {
        if (!straighten) { ox = sx; oy = sy; return; }
        const float fx = intr[0], fy = intr[1], cx = intr[2], cy = intr[3], s = intr[4];
        const float yi = (sy - cy) / fy, xi = (sx - cx - s * yi) / fx;
        const float r2 = xi * xi + yi * yi;
        const float radial = 1 + dist[0] * r2 + dist[1] * r2 * r2 + dist[2] * r2 * r2 * r2;
        const float xc = xi * radial + dist[3] * 2 * xi * yi + dist[4] * (r2 + 2 * xi * xi);
        const float yc = yi * radial + dist[3] * (r2 + 2 * yi * yi) + dist[4] * 2 * xi * yi;
        ox = fx * xc + s * yc + cx;
        oy = fy * yc + cy;
    };
    // The trim: the smallest that keeps every edge point of the straightened frame on the sensor (no repeated edge
    // pixels), plus 1.2 % so the sensor's outermost, noisiest pixels (most lens-shading gain) are left out too.
    float margin = 0.0f;
    for (; margin < 0.2f; margin += 0.0025f) {
        const float bw = cw * (1 - margin), bh = ch * (1 - margin), bx = (w - bw) / 2, by = (h - bh) / 2;
        bool inside = true;
        for (int i = 0; i <= 64 && inside; ++i) {
            const float f = i / 64.0f;
            const float pts[4][2] = {{bx + f * bw, by}, {bx + f * bw, by + bh}, {bx, by + f * bh}, {bx + bw, by + f * bh}};
            for (const auto& pt : pts) {
                float ox, oy;
                lens(pt[0], pt[1], ox, oy);
                if (ox < 1.0f || oy < 1.0f || ox > w - 2.0f || oy > h - 2.0f) { inside = false; break; }
            }
        }
        if (inside) break;
    }
    margin = std::min(0.25f, margin + 0.012f);
    const float srcW = cw * (1 - margin), srcH = ch * (1 - margin);
    double scale = std::min(1.0, std::sqrt(double(maxPixels) / (double(srcW) * srcH)));
    ow = std::max(1, int(srcW * scale)); oh = std::max(1, int(srcH * scale));
    const float x0 = (w - srcW) / 2, y0 = (h - srcH) / 2, step = srcW / ow;
    std::vector<float> outpx(size_t(ow) * oh * 3);
    auto sample = [&](float sx, float sy, float* d) {
        sx = std::clamp(sx, 0.0f, float(w - 1.001f));
        sy = std::clamp(sy, 0.0f, float(h - 1.001f));
        const int ix = int(sx), iy = int(sy);
        const float fx = sx - ix, fy = sy - iy;
        const float* a = &rgb[(size_t(iy) * w + ix) * 3];
        const float* b = a + 3;
        const float* c = a + size_t(w) * 3;
        const float* e = c + 3;
        for (int i = 0; i < 3; ++i)
            d[i] = (a[i] * (1 - fx) + b[i] * fx) * (1 - fy) + (c[i] * (1 - fx) + e[i] * fx) * fy;
    };
    for (int v = 0; v < oh; ++v) {
        for (int u = 0; u < ow; ++u) {
            float sx, sy;
            lens(x0 + (u + 0.5f) * step, y0 + (v + 0.5f) * step, sx, sy);
            float cam[3];
            sample(sx, sy, cam);
            float* d = &outpx[(size_t(v) * ow + u) * 3];
            for (int r = 0; r < 3; ++r) d[r] = std::max(0.0f, k[r * 3] * cam[0] + k[r * 3 + 1] * cam[1] + k[r * 3 + 2] * cam[2]);
        }
    }
    std::vector<float>().swap(rgb);

    // 5. Exposure: the film meter's brightness (see RawInput), or a target median.
    if ((in.gain > 0 && in.previewMedian > 0) || targetMedian > 0) {
        std::vector<float> lum;
        lum.reserve(size_t(ow) * oh / 64 + 1);
        for (size_t i = 0; i < size_t(ow) * oh; i += 61) {
            const float* d = &outpx[i * 3];
            lum.push_back(0.2880f * d[0] + 0.7119f * d[1] + 0.0001f * d[2]);   // ProPhoto Y
        }
        std::nth_element(lum.begin(), lum.begin() + lum.size() / 2, lum.end());
        const float med = lum[lum.size() / 2];
        if (med > 1e-6f) {
            const float want = in.gain > 0 && in.previewMedian > 0 ? in.gain * in.previewMedian / med : targetMedian / med;
            const float gain = std::clamp(want, 1.0f / 16, 64.0f);
            for (float& x : outpx) x *= gain;
        }
    }
    return outpx;
}

void prophoto_to_srgb8(const float* px, int w, int h, uint8_t* rgba, int strideBytes) {
    static const float m[9] = {2.0343589f, -0.7272876f, -0.3070713f, -0.2288214f, 1.2317270f, -0.0029056f,
                               -0.0085555f, -0.1532861f, 1.1618416f};
    for (int y = 0; y < h; ++y) {
        uint8_t* row = rgba + size_t(y) * strideBytes;
        for (int x = 0; x < w; ++x) {
            const float* p = &px[(size_t(y) * w + x) * 3];
            for (int c = 0; c < 3; ++c) {
                float v = m[c * 3] * p[0] + m[c * 3 + 1] * p[1] + m[c * 3 + 2] * p[2];
                v = std::clamp(v, 0.0f, 1.0f);
                v = v <= 0.0031308f ? 12.92f * v : 1.055f * std::pow(v, 1.0f / 2.4f) - 0.055f;
                row[4 * x + c] = uint8_t(v * 255.0f + 0.5f);
            }
            row[4 * x + 3] = 255;
        }
    }
}
