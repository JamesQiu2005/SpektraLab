#pragma once
// The display LUT of ColorPipeline.hpp: building it from Qt's colour transform,
// and a CPU model of how the canvas shader samples it. The model is what the
// tests hold the LUT to, so it is also the specification the GPU side follows:
// the texel-centre coordinate, trilinear filtering with clamp-to-edge, and
// clamping only after interpolation.
#include "ColorPipeline.hpp"
#include <QColorSpace>
#include <array>
#include <atomic>
#include <memory>

namespace spk::color {

// 65 nodes put one on every multiple of 1/64, so 0, 0.25, 0.5 and 1 are
// sampled exactly; 65^3 RGBA floats are 4.4 MB.
inline constexpr int kLutSize = 65;

// A node counts as clipped (alpha 0) when a display-linear channel leaves
// [0, 1] by more than this. Qt maps in float, so a colour exactly on the
// gamut boundary lands within ~1e-6 of it; 1e-5 linear is still under 1.4
// 8-bit counts on a pure gamma 2.2 curve near black, where it is steepest.
inline constexpr float kGamutToleranceLinear = 1e-5f;

// A built LUT this close to the identity at every node, with nothing clipped,
// is drawn as the identity instead: 1e-4 is 0.03 of an 8-bit count and 0.1 of
// a 10-bit one. Qt already treats an sRGB curve stored as a 1024-entry table
// as sRGB (measured); this catches what it compares exactly, such as primaries
// a profiler rounded differently. Either way is correct: it only saves the
// canvas a lookup.
inline constexpr float kNearIdentityTolerance = 1e-4f;

// Unique per built LUT, never 0 (ColorLut::key).
quint64 nextLutKey();

// True when pixels encoded in `source` are already correct on `target`.
bool sameEncoding(const QColorSpace& source, const QColorSpace& target);

// Samples source -> target (relative colorimetric with Qt's Bradford
// adaptation; Qt has no other intent) at every node of the header's grid.
// RGB are left unclamped so the shader can clamp after interpolating; alpha
// is 0 where the node is outside the target gamut. Gamut is judged in the
// target's linear light, so it is computed only for matrix/TRC targets; an
// A2B/B2A (ElementListProcessing) target gets alpha 1, "not computed".
// `cancel` is polled per slice; a cancelled build returns nullptr.
std::shared_ptr<ColorLut> buildLut(const QColorSpace& source, const QColorSpace& target,
                                   int size = kLutSize, const std::atomic<bool>* cancel = nullptr);

bool isNearIdentity(const ColorLut& lut, float tolerance = kNearIdentityTolerance);

// The texture coordinate the canvas samples for encoded value c in [0, 1]:
// node i of N sits at the centre of texel i, so c = i / (N - 1) must map to
// (i + 0.5) / N.
inline float lutCoordinate(float c, int n) { return c * float(n - 1) / float(n) + 0.5f / float(n); }

// How the hardware may differ from exact float filtering. D3D11 and Vulkan
// only promise 8 bits of sub-texel precision for the filter weights, and the
// canvas may store the LUT as half floats; the tests measure both.
struct LutSampling {
    int weightBits = 0;      // 0: exact float weights
    bool halfTexels = false; // round every node to binary16 first
};

// What the canvas shader computes for one source pixel: input clamped to
// [0, 1], lutCoordinate, then what a linear-filtering, clamp-to-edge sampler
// does with that coordinate. RGB come back unclamped (the shader clamps them
// next) and alpha interpolated. An identity LUT returns the input.
std::array<float, 4> sampleLut(const ColorLut& lut, float r, float g, float b, LutSampling sampling = {});

} // namespace spk::color
