#pragma once
// The canvas soft proof's engine half: the export's own transform out of the
// session's encoding into a recipe's colour space, as the ProofTransform.hpp
// numbers the canvas shader runs per pixel, and the CPU arithmetic its
// software path and the tests run.
//
// The macOS app proves an export on its export page (Export/SoftProof.swift:
// `Exporter.filePixels`, the same render and the same output transform as the
// file). The Windows canvas proof is that transform on the canvas's own
// pixels, live under every edit. Its numbers are the engine's, fetched once
// through exporting::exportTransform -- the very object exporting::convert
// runs for the file -- and copied out of the engine so they outlive the fetch
// (OutputTransform::own_tables).
#include "ProofTransform.hpp"
#include "desktop/preview_host.hpp"
#include <string>

namespace spk::desktop::proofing {

// The proof of a frame encoded `from` exported into engine space `to`, with
// `name` the destination as a person reads it. On the thread that owns
// `engine` (the controller's worker); the result is immutable and may be used
// on any thread. Throws std::runtime_error (an encoding the display cannot
// tag, a space the engine cannot convert to).
ProofTransformPtr makeProofTransform(spk_engine* engine, const OutputEncoding& from, const std::string& to,
                                     const QString& name);

}  // namespace spk::desktop::proofing
