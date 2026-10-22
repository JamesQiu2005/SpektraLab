#pragma once
#include "image_io.hpp"
namespace spkhost {
// Configure once before decoding. Only the shipped database is loaded.
void lens_database(const std::filesystem::path& directory);
LensCorrectionInfo inspect_lens(const Probe& probe);
// Operates before upload, in sensor coordinates even on oriented images.
// At most one extra float RGB image, plus bounded row buffers per worker.
bool correct_lens(FloatImage& image, Probe& probe, std::string& error);
}
