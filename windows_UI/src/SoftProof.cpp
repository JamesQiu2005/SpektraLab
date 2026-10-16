#include "SoftProof.hpp"
#include "FrameImage.hpp"
#include "RecipeExport.hpp"
#include <atomic>
#include <stdexcept>

namespace spk::desktop::proofing {
namespace {
quint64 nextKey() { static std::atomic<quint64> counter{0}; return ++counter; }
}

ProofTransformPtr makeProofTransform(spk_engine* engine, const OutputEncoding& from, const std::string& to,
                                     const QString& name) {
    if(!from.cctf_encoding)
        throw std::runtime_error("The soft proof needs an encoded frame; this one is linear " + from.color_space);
    auto proof = std::make_shared<ProofTransform>();
    proof->name = name;
    proof->source = display::colorSpace(from);
    proof->target = display::colorSpace({to, true});
    // The same space: the file is the frame's own codes (exporting::convert's
    // identity), so the proof is the display LUT (ColorPipeline::proofLut);
    // the transform below is then the engine's decode alone.
    proof->identity = from.color_space == to;
    proof->key = nextKey();
    auto transform = std::make_shared<spkhost::OutputTransform>(exporting::exportTransform(from.color_space, to, engine));
    transform->own_tables();
    // The shader's copy of the numbers, and the CPU path's arithmetic: the
    // same object exporting::convert runs for the file.
    const auto p = transform->parameters();
    auto& k = proof->kernel;
    k.sourceMode = p.source_mode; k.targetMode = p.target_mode; k.identity = p.identity;
    k.matrix = p.matrix; k.cam16 = p.cam16; k.lightness = p.lightness;
    k.toXyz = p.m_to_xyz; k.toRgb = p.m_to_rgb; k.k = p.k;
    k.cmaxRows = p.cmax_rows; k.cmaxCols = p.cmax_cols;
    if(p.cmax) k.cmax.assign(p.cmax, p.cmax + std::size_t(p.cmax_rows) * p.cmax_cols);
    proof->evaluate = [transform](const float* encoded, std::size_t count, float* linear, std::uint8_t* outside) {
        transform->transform_encoded(encoded, count, linear, outside);
    };
    const std::uint32_t mode = p.target_mode;
    proof->encodeTarget = [mode](float v) { return spkhost::cctf_encode_mode(v, mode); };
    return proof;
}

}  // namespace spk::desktop::proofing
