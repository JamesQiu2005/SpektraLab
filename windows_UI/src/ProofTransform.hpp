#pragma once
// The soft proof: what an export recipe's colour space would make of the
// picture, shown on the display -- the macOS export page's proof
// (Export/SoftProof.swift: the export's own output transform, per pixel),
// brought to the canvas.
//
// The canvas runs the export's transform per pixel, in its fragment shader
// (shaders/colorcanvas.frag, PROOF variants; ColorCanvasNode's CPU path for
// the software backend), as the macOS canvas shader runs `outputTransform`:
// the source curve off, the engine's CAT02-adapted 3x3, CAM16-UCS gamut
// compression into the recipe's space, the file's clamp -- then the window's
// display LUT for the recipe space (ColorPipeline::lut(target)). Every number
// is the engine's (spk_output_transform through exporting::exportTransform,
// SoftProof.hpp); nothing here derives one.
//
// Why per pixel and not a LUT over the source: the gamut map is far from
// smooth where it works hardest -- near black, the hue of a saturated colour
// swings with the smallest change, and colours rolled onto the destination's
// boundary follow its cusps -- and a 65^3 table of it measured 15-33 counts
// from the export (spk_qt_soft_proof_test --sweep: 0.6-4.8 % of the probes
// over one count, the error only roughly halving from 33^3 to 65^3). The
// macOS proof is per pixel too.
//
// The gamut warning's flag is per pixel as well: the export could not keep
// the colour -- its chroma lay outside the destination before the knee
// (d > 1, the macOS shader's `outside`, the number its export page reports),
// or a channel stayed outside [0, 1] after the gamut map (what the file clips).
#include <QColorSpace>
#include <QMetaType>
#include <QString>
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

// A linear channel outside [0, 1] by more than this after the gamut map is
// clipped by the file: the bound exporting::convert counts as clipped.
inline constexpr float kProofClipTolerance = 1e-4f;

// spkhost::OutputTransformParameters, owned: what the shader's uniforms and
// the C_max texture carry.
struct ProofKernel {
    std::uint32_t sourceMode = 0, targetMode = 0;  // the engine's cctf modes
    bool identity = false;                          // decode only
    std::array<float, 9> matrix{1, 0, 0, 0, 1, 0, 0, 0, 1};  // row-major
    bool cam16 = false, lightness = false;
    std::array<float, 9> toXyz{}, toRgb{};          // row-major
    std::array<float, 22> k{};
    std::uint32_t cmaxRows = 0, cmaxCols = 0;
    std::vector<float> cmax;                        // rows * cols
};

struct ProofTransform {
    QString name;          // the destination as a person reads it, e.g. "sRGB"
    QColorSpace source;    // the encoding the transform reads (the frame's)
    QColorSpace target;    // the encoding the file's pixels are in (its ICC)
    bool identity = false; // target is source: the proof is the display LUT
    quint64 key = 0;       // unique per transform
    ProofKernel kernel;
    // The kernel on the CPU (the engine's own per-pixel arithmetic): `count`
    // interleaved encoded source RGB triples -> linear target RGB,
    // unclamped, and per pixel 1 where the chroma lay outside (d > 1). Const
    // and thread-safe.
    std::function<void(const float* encoded, std::size_t count, float* linear, std::uint8_t* outside)> evaluate;
    // The target's encode (its cctf), linear -> encoded.
    std::function<float(float)> encodeTarget;
};
using ProofTransformPtr = std::shared_ptr<const ProofTransform>;
Q_DECLARE_METATYPE(ProofTransformPtr)
