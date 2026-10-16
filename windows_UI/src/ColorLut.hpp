#pragma once
// The display LUT of ColorPipeline.hpp: building it from Qt's colour transform,
// and a CPU model of how the canvas shader samples it. The model is what the
// tests hold the LUT to, so it is also the specification the GPU side follows:
// the texel-centre coordinate, linear filtering with clamp-to-edge, and
// clamping only after interpolation.
//
// Two forms. A matrix/TRC source onto a matrix/TRC display gets curves: the
// shaper decodes the source to linear light, the table is the 3x3 between the
// two linear spaces, the output curve encodes for the display. A table over
// encoded values could not follow a pure power curve near zero (7.2 counts on
// this machine's Adobe RGB display); this form is exact up to sampling. A
// LUT-based (A2B/B2A) display, which has no 3x3 to factor out, keeps one
// 65^3 table from encoded source to encoded display.
#include "ColorPipeline.hpp"
#include <QColorSpace>
#include <array>
#include <atomic>
#include <memory>

namespace spk::color {

// The encoded-domain table: 65 nodes put one on every multiple of 1/64, so 0,
// 0.25, 0.5 and 1 are sampled exactly; 65^3 RGBA floats are 4.4 MB.
inline constexpr int kEncodedTableSize = 65;

// The linear-domain table (with curves). With float weights any size is
// exact -- trilinear filtering reproduces a 3x3 -- and spk_qt_color_core
// --sweep measures at most 0.02 counts down to 9 nodes. The size sets two
// other things. One is the gamut flag's resolution: 1.2 % of ProPhoto colours
// misflagged at 65, 2.4 % at 33, 4.3 % at 17 (the encoded table: 0.8 %). The
// other is the damage if a canvas filters the table on 8-bit hardware weights
// after all: on a replica of this machine's display profile, with rounded
// weights, 1.9 counts at 65 and 3.1 at 33.
inline constexpr int kLinearTableSize = 65;

// Entries per curve. Worst case over the sweep's displays with exact
// filtering: 0.007 counts at 4096, 0.018 at 1024, 0.058 at 256; under the
// recommended sampling (float32, the curves on truncated 8-bit hardware
// weights) 0.03, 0.03 and 0.11. Two float32 curves of 4096 entries are 128 KB.
inline constexpr int kCurveSize = 4096;

// A node counts as clipped (alpha 0) when a display-linear channel leaves
// [0, 1] by more than this. Qt maps in float, so a colour exactly on the
// gamut boundary lands within ~1e-7 of it (measured); 1e-5 linear is still
// under 1.4 8-bit counts on a pure gamma 2.2 curve near black.
inline constexpr float kGamutToleranceLinear = 1e-5f;

// A built LUT this close to the identity everywhere, with nothing clipped,
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

// True when both are RGB matrix/TRC spaces: decode -> 3x3 -> encode is then
// the whole transform, and buildLut gives curves.
bool curvesApply(const QColorSpace& source, const QColorSpace& target);

// The transform source -> target (relative colorimetric with Qt's Bradford
// adaptation; Qt has no other intent), in the form curvesApply picks. Table
// RGB are left unclamped so the shader can clamp after interpolating; alpha
// is 0 where the node is outside the target gamut, judged in the target's
// linear light (alpha 1, "not computed", for an A2B/B2A target). `cancel` is
// polled per slice; a cancelled build returns nullptr.
std::shared_ptr<ColorLut> buildLut(const QColorSpace& source, const QColorSpace& target,
                                   const std::atomic<bool>* cancel = nullptr);

// The two forms explicitly, for the tests and the sweep.
std::shared_ptr<ColorLut> buildEncodedLut(const QColorSpace& source, const QColorSpace& target,
                                          int size = kEncodedTableSize, const std::atomic<bool>* cancel = nullptr);
// Requires curvesApply(source, target).
std::shared_ptr<ColorLut> buildCurvedLut(const QColorSpace& source, const QColorSpace& target,
                                         int tableSize = kLinearTableSize, int curveSize = kCurveSize,
                                         const std::atomic<bool>* cancel = nullptr);

bool isNearIdentity(const ColorLut& lut, float tolerance = kNearIdentityTolerance);

// The texture coordinate the canvas samples for a value x in [0, 1], for the
// table and for both curves alike: entry i of N sits at the centre of texel
// i, so x = i / (N - 1) must map to (i + 0.5) / N.
inline float lutCoordinate(float x, int n) { return x * float(n - 1) / float(n) + 0.5f / float(n); }

// How the canvas may differ from exact float filtering. D3D11 and Vulkan only
// promise 8 bits of sub-texel precision for hardware filter weights (NVIDIA
// documents 8 fractional bits; whether it rounds or truncates is not
// documented, so both are modelled), and entries may be uploaded as halves.
// The linear-light stages are the sensitive ones: their errors are a fixed
// amount of light, which a matrix with cancelling terms and then the
// display's encoding magnify wherever an output channel is near zero. So the
// canvas should store everything as float32 and filter the table with float
// weights (eight fetches) -- exactTableFilter; hardware filtering is fine for
// the curves. spk_qt_color_core measures each departure on its own.
struct LutSampling {
    int weightBits = 0;            // hardware weight precision; 0: exact float weights
    bool truncateWeights = false;  // with weightBits: truncate instead of round
    bool exactTableFilter = false; // the table filtered with float weights; weightBits then applies to the curves only
    bool halfCurves = false;       // curve entries rounded to binary16
    bool halfTable = false;        // table entries rounded to binary16
};

// What the canvas shader computes for one source pixel. Without curves: the
// input clamped to [0, 1], then the table; RGB come back unclamped (the
// shader clamps them next). With curves, per channel: shaper(clamp(x)), the
// table, clamp to [0, 1], output(sqrt(.)). Alpha is the table's, interpolated.
// An identity LUT returns the input.
std::array<float, 4> sampleLut(const ColorLut& lut, float r, float g, float b, LutSampling sampling = {});

} // namespace spk::color
