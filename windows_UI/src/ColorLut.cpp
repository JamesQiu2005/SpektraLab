#include "ColorLut.hpp"

#include <QColorTransform>
#include <QFloat16>
#include <QRgbaFloat>
#include <algorithm>
#include <cmath>

namespace spk::color {

quint64 nextLutKey() {
    static std::atomic<quint64> counter{0};
    return ++counter;
}

bool sameEncoding(const QColorSpace& source, const QColorSpace& target) {
    if (!source.isValid() || !target.isValid()) return false;
    if (source == target) return true;
    // Two descriptions of one space (a named space and the same primaries and
    // curve read back from ICC bytes) compare unequal but transform as identity.
    return source.transformationToColorSpace(target).isIdentity();
}

std::shared_ptr<ColorLut> buildLut(const QColorSpace& source, const QColorSpace& target, int size,
                                   const std::atomic<bool>* cancel) {
    auto lut = std::make_shared<ColorLut>();
    lut->size = size;
    lut->rgba.resize(std::size_t(size) * size * size * 4);
    lut->key = nextLutKey();
    // QColorTransform::map(QRgbaFloat32) does not clamp for a parametric
    // display curve: out-of-gamut colours come back below 0 or above 1, so the
    // shader can clamp after interpolating. A display whose curves are tables
    // comes back clamped to [0, 1] (the colour-core test measures both); its
    // nodes at the gamut boundary are then interpolated already clipped.
    const QColorTransform toTarget = source.transformationToColorSpace(target);
    const bool judgeGamut = target.transformModel() == QColorSpace::TransformModel::ThreeComponentMatrix;
    // The same transform ending in the target's linear light. Judging the
    // encoded value instead would flag noise: a pure power curve turns a
    // -1e-6 linear rounding error into -0.002 encoded.
    const QColorTransform toLinear = judgeGamut
        ? source.transformationToColorSpace(target.withTransferFunction(QColorSpace::TransferFunction::Linear))
        : QColorTransform();
    const auto inside = [](float v) { return v >= -kGamutToleranceLinear && v <= 1.0f + kGamutToleranceLinear; };
    const float last = float(size - 1);
    float* out = lut->rgba.data();
    for (int b = 0; b < size; ++b) {
        if (cancel && cancel->load(std::memory_order_relaxed)) return nullptr;
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                const QRgbaFloat32 in{float(r) / last, float(g) / last, float(b) / last, 1.0f};
                const QRgbaFloat32 mapped = toTarget.map(in);
                bool inGamut = true;
                if (judgeGamut) {
                    const QRgbaFloat32 linear = toLinear.map(in);
                    inGamut = inside(linear.r) && inside(linear.g) && inside(linear.b);
                }
                *out++ = mapped.r;
                *out++ = mapped.g;
                *out++ = mapped.b;
                *out++ = inGamut ? 1.0f : 0.0f;
            }
        }
    }
    return lut;
}

bool isNearIdentity(const ColorLut& lut, float tolerance) {
    if (lut.isIdentity()) return true;
    const int n = lut.size;
    const float last = float(n - 1);
    const float* node = lut.rgba.data();
    for (int b = 0; b < n; ++b)
        for (int g = 0; g < n; ++g)
            for (int r = 0; r < n; ++r, node += 4) {
                if (std::abs(node[0] - float(r) / last) > tolerance || std::abs(node[1] - float(g) / last) > tolerance ||
                    std::abs(node[2] - float(b) / last) > tolerance || node[3] != 1.0f)
                    return false;
            }
    return true;
}

std::array<float, 4> sampleLut(const ColorLut& lut, float r, float g, float b, LutSampling sampling) {
    if (lut.isIdentity()) return {r, g, b, 1.0f};
    const int n = lut.size;
    const float input[3] = {r, g, b};
    int low[3], high[3];
    float weight[3];
    for (int axis = 0; axis < 3; ++axis) {
        const float u = lutCoordinate(std::clamp(input[axis], 0.0f, 1.0f), n);
        // A linear-filtering sampler: texel space is u * N - 0.5, the two
        // texels either side are blended by the fractional part, and indices
        // outside the texture clamp to its edge.
        const float x = u * float(n) - 0.5f;
        const float base = std::floor(x);
        float fraction = x - base;
        if (sampling.weightBits > 0) {
            const float steps = float(1 << sampling.weightBits);
            fraction = std::round(fraction * steps) / steps;
        }
        low[axis] = std::clamp(int(base), 0, n - 1);
        high[axis] = std::clamp(int(base) + 1, 0, n - 1);
        weight[axis] = fraction;
    }
    const auto texel = [&](int ri, int gi, int bi, int channel) {
        float v = lut.rgba[(std::size_t(bi * n + gi) * n + ri) * 4 + channel];
        return sampling.halfTexels ? float(qfloat16(v)) : v;
    };
    std::array<float, 4> result{};
    for (int corner = 0; corner < 8; ++corner) {
        const bool hr = corner & 1, hg = corner & 2, hb = corner & 4;
        const float w = (hr ? weight[0] : 1.0f - weight[0]) * (hg ? weight[1] : 1.0f - weight[1]) *
                        (hb ? weight[2] : 1.0f - weight[2]);
        if (w == 0.0f) continue;
        const int ri = hr ? high[0] : low[0], gi = hg ? high[1] : low[1], bi = hb ? high[2] : low[2];
        for (int channel = 0; channel < 4; ++channel) result[channel] += w * texel(ri, gi, bi, channel);
    }
    return result;
}

} // namespace spk::color
