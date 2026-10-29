#pragma once
#include "view.hpp"
#include "image.hpp"

namespace spk::view {
// The engine owns both input and transform data. This routine never uploads an
// image: only uniforms, the curve LUT and small colour-management tables.
// Input is packed RGBA16 (c=2) or encoded working RGB float32 (c=3). The latter
// retains decoded-source headroom until Layer 2's normal output boundary.
bool process(gpu::Gpu* gpu, const Image& print, const Request& request,
             const Json& transform, const float* cmax, uint32_t cmax_count,
             Result& result, std::string& error,
             const gpu::BufferRef& di_lut = {}, uint32_t di_lut_size = 0,
             Image* device_output = nullptr);
}
