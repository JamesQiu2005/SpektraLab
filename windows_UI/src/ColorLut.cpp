#include "ColorLut.hpp"

#include <QColorTransform>
#include <QFloat16>
#include <QRgbaFloat>
#include <algorithm>
#include <cmath>
#include <vector>

namespace spk::color {

namespace {

bool insideGamut(float v) { return v >= -kGamutToleranceLinear && v <= 1.0f + kGamutToleranceLinear; }

bool matrixRgb(const QColorSpace& space) {
    return space.isValid() && space.colorModel() == QColorSpace::ColorModel::Rgb &&
           space.transformModel() == QColorSpace::TransformModel::ThreeComponentMatrix;
}

// One axis of a linear-filtering, clamp-to-edge sampler at value x in [0, 1]:
// texel space is coordinate * N - 0.5, the texels either side are blended by
// the fractional part, and indices outside the texture clamp to its edge.
struct Tap {
    int low, high;
    float weight;
};
Tap tap(float x, int n, int weightBits, bool truncate) {
    const float texelSpace = lutCoordinate(std::clamp(x, 0.0f, 1.0f), n) * float(n) - 0.5f;
    const float base = std::floor(texelSpace);
    float fraction = texelSpace - base;
    if (weightBits > 0) {
        const float steps = float(1 << weightBits);
        fraction = (truncate ? std::floor(fraction * steps) : std::round(fraction * steps)) / steps;
    }
    return {std::clamp(int(base), 0, n - 1), std::clamp(int(base) + 1, 0, n - 1), fraction};
}

float stored(float v, bool half) { return half ? float(qfloat16(v)) : v; }

float sampleCurve(const std::vector<float>& curve, int size, int channel, float x, const LutSampling& sampling) {
    const Tap t = tap(x, size, sampling.weightBits, sampling.truncateWeights);
    const float a = stored(curve[std::size_t(t.low) * 4 + channel], sampling.halfCurves);
    const float b = stored(curve[std::size_t(t.high) * 4 + channel], sampling.halfCurves);
    return a + (b - a) * t.weight;
}

std::array<float, 4> sampleTable(const ColorLut& lut, const float input[3], const LutSampling& sampling) {
    const int n = lut.size;
    const int bits = sampling.exactTableFilter ? 0 : sampling.weightBits;
    const Tap taps[3] = {tap(input[0], n, bits, sampling.truncateWeights), tap(input[1], n, bits, sampling.truncateWeights),
                         tap(input[2], n, bits, sampling.truncateWeights)};
    std::array<float, 4> result{};
    for (int corner = 0; corner < 8; ++corner) {
        const bool hr = corner & 1, hg = corner & 2, hb = corner & 4;
        const float w = (hr ? taps[0].weight : 1.0f - taps[0].weight) * (hg ? taps[1].weight : 1.0f - taps[1].weight) *
                        (hb ? taps[2].weight : 1.0f - taps[2].weight);
        if (w == 0.0f) continue;
        const int ri = hr ? taps[0].high : taps[0].low, gi = hg ? taps[1].high : taps[1].low,
                  bi = hb ? taps[2].high : taps[2].low;
        const float* node = &lut.rgba[(std::size_t(bi * n + gi) * n + ri) * 4];
        for (int channel = 0; channel < 4; ++channel) result[channel] += w * stored(node[channel], sampling.halfTable);
    }
    return result;
}

} // namespace

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

bool curvesApply(const QColorSpace& source, const QColorSpace& target) { return matrixRgb(source) && matrixRgb(target); }

std::shared_ptr<ColorLut> buildLut(const QColorSpace& source, const QColorSpace& target, const std::atomic<bool>* cancel) {
    return curvesApply(source, target) ? buildCurvedLut(source, target, kLinearTableSize, kCurveSize, cancel)
                                       : buildEncodedLut(source, target, kEncodedTableSize, cancel);
}

std::shared_ptr<ColorLut> buildEncodedLut(const QColorSpace& source, const QColorSpace& target, int size,
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
                    inGamut = insideGamut(linear.r) && insideGamut(linear.g) && insideGamut(linear.b);
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

std::shared_ptr<ColorLut> buildCurvedLut(const QColorSpace& source, const QColorSpace& target, int tableSize,
                                         int curveSize, const std::atomic<bool>* cancel) {
    // The three pieces of Qt's own source -> target transform: each space's
    // curves against the same space in linear light, and the matrix (with
    // Bradford adaptation) between the two linear spaces.
    const QColorSpace sourceLinear = source.withTransferFunction(QColorSpace::TransferFunction::Linear);
    const QColorSpace targetLinear = target.withTransferFunction(QColorSpace::TransferFunction::Linear);
    const QColorTransform decode = source.transformationToColorSpace(sourceLinear);
    const QColorTransform matrix = sourceLinear.transformationToColorSpace(targetLinear);
    const QColorTransform encode = targetLinear.transformationToColorSpace(target);

    auto lut = std::make_shared<ColorLut>();
    lut->key = nextLutKey();
    lut->curveSize = curveSize;
    lut->shaper.resize(std::size_t(curveSize) * 4);
    lut->output.resize(std::size_t(curveSize) * 4);
    const float curveLast = float(curveSize - 1);
    for (int i = 0; i < curveSize; ++i) {
        const float x = float(i) / curveLast;
        const QRgbaFloat32 linear = decode.map(QRgbaFloat32{x, x, x, 1.0f});
        // The output curve is indexed by sqrt(u): entry i holds the encoding
        // of u = x^2, where a display curve (about u^(1/2.2)) is nearly linear.
        const float u = x * x;
        const QRgbaFloat32 encoded = encode.map(QRgbaFloat32{u, u, u, 1.0f});
        float* s = &lut->shaper[std::size_t(i) * 4];
        float* o = &lut->output[std::size_t(i) * 4];
        s[0] = linear.r, s[1] = linear.g, s[2] = linear.b, s[3] = 1.0f;
        o[0] = encoded.r, o[1] = encoded.g, o[2] = encoded.b, o[3] = 1.0f;
    }

    // Linear in, linear out: an affine map, which trilinear filtering
    // reproduces at any size. Out-of-gamut nodes stay unclamped (a linear
    // curve extends past [0, 1] in Qt) and are flagged in alpha.
    lut->size = tableSize;
    lut->rgba.resize(std::size_t(tableSize) * tableSize * tableSize * 4);
    const float last = float(tableSize - 1);
    float* out = lut->rgba.data();
    for (int b = 0; b < tableSize; ++b) {
        if (cancel && cancel->load(std::memory_order_relaxed)) return nullptr;
        for (int g = 0; g < tableSize; ++g) {
            for (int r = 0; r < tableSize; ++r) {
                const QRgbaFloat32 v = matrix.map(QRgbaFloat32{float(r) / last, float(g) / last, float(b) / last, 1.0f});
                *out++ = v.r;
                *out++ = v.g;
                *out++ = v.b;
                *out++ = insideGamut(v.r) && insideGamut(v.g) && insideGamut(v.b) ? 1.0f : 0.0f;
            }
        }
    }
    return lut;
}

bool isNearIdentity(const ColorLut& lut, float tolerance) {
    if (lut.isIdentity()) return true;
    for (std::size_t i = 3; i < lut.rgba.size(); i += 4)
        if (lut.rgba[i] != 1.0f) return false;
    // Without curves the nodes are the answer; with them, ask the whole chain
    // at the same 65^3 encoded values.
    const int n = lut.hasCurves() ? kEncodedTableSize : lut.size;
    const float last = float(n - 1);
    for (int b = 0; b < n; ++b)
        for (int g = 0; g < n; ++g)
            for (int r = 0; r < n; ++r) {
                const float in[3] = {float(r) / last, float(g) / last, float(b) / last};
                const std::array<float, 4> out = lut.hasCurves()
                    ? sampleLut(lut, in[0], in[1], in[2])
                    : std::array<float, 4>{lut.rgba[(std::size_t(b * n + g) * n + r) * 4],
                                           lut.rgba[(std::size_t(b * n + g) * n + r) * 4 + 1],
                                           lut.rgba[(std::size_t(b * n + g) * n + r) * 4 + 2], 1.0f};
                for (int c = 0; c < 3; ++c)
                    if (std::abs(out[c] - in[c]) > tolerance) return false;
            }
    return true;
}

std::array<float, 4> sampleLut(const ColorLut& lut, float r, float g, float b, LutSampling sampling) {
    if (lut.isIdentity()) return {r, g, b, 1.0f};
    const float input[3] = {r, g, b};
    if (!lut.hasCurves()) return sampleTable(lut, input, sampling);
    float shaped[3];
    for (int c = 0; c < 3; ++c) shaped[c] = sampleCurve(lut.shaper, lut.curveSize, c, input[c], sampling);
    std::array<float, 4> result = sampleTable(lut, shaped, sampling);
    for (int c = 0; c < 3; ++c)
        result[c] = sampleCurve(lut.output, lut.curveSize, c, std::sqrt(std::clamp(result[c], 0.0f, 1.0f)), sampling);
    return result;
}

void sampleProof(const ColorLut& lut, const ProofTransform& proof, const float* encoded, std::size_t count, float* rgba,
                 LutSampling sampling) {
    if (count == 0 || !proof.evaluate) return;
    std::vector<float> in(count * 3), linear(count * 3);
    std::vector<std::uint8_t> outside(count);
    for (std::size_t i = 0; i < count * 3; ++i) in[i] = std::clamp(encoded[i], 0.0f, 1.0f);
    proof.evaluate(in.data(), count, linear.data(), outside.data());
    for (std::size_t i = 0; i < count; ++i) {
        float c[3];
        bool clipped = false;
        for (int k = 0; k < 3; ++k) {
            const float l = linear[i * 3 + k];
            // NaN fails both comparisons: counted clipped, shown black.
            if (!(l >= -kProofClipTolerance && l <= 1.0f + kProofClipTolerance)) clipped = true;
            c[k] = l > 0.0f ? (l < 1.0f ? l : 1.0f) : 0.0f;
        }
        std::array<float, 4> out{};
        if (lut.isIdentity()) {
            for (int k = 0; k < 3; ++k) out[k] = proof.encodeTarget ? proof.encodeTarget(c[k]) : c[k];
        } else if (lut.hasCurves()) {
            // Past the shaper: the table takes the recipe space's linear light.
            out = sampleTable(lut, c, sampling);
            for (int k = 0; k < 3; ++k)
                out[k] = sampleCurve(lut.output, lut.curveSize, k, std::sqrt(std::clamp(out[k], 0.0f, 1.0f)), sampling);
        } else {
            float e[3];
            for (int k = 0; k < 3; ++k) e[k] = proof.encodeTarget ? proof.encodeTarget(c[k]) : c[k];
            out = sampleTable(lut, e, sampling);
        }
        for (int k = 0; k < 3; ++k) rgba[i * 4 + k] = std::clamp(out[k], 0.0f, 1.0f);
        rgba[i * 4 + 3] = outside[i] || clipped ? 0.0f : 1.0f;
    }
}

} // namespace spk::color
