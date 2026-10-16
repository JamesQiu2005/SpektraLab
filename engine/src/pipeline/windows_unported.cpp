// Off-path adapters for upstream effects that still depend on Apple services.
// Mac build.sh globs pipeline/*.cpp, so the whole translation unit is guarded.
#ifndef __APPLE__
#include "pipeline.hpp"
#include "windows_unported.hpp"

namespace spk {

// overscan.cpp (the film edge and the date back) compiles everywhere now; its
// raster is overscan_raster_portable.cpp off Apple. Overscan itself stays
// refused by windows_unported.hpp until its canvas kernels are ported.

bool Pipeline::contrast_mask_wanted() const { return params_.print_render.contrast_mask.active; }

void Pipeline::release_contrast_mask() {
    mask_on_ = false;
    mask_coef_ = gpu::BufferRef{};
    band_row0_ = 0;
}

bool Pipeline::prepare_contrast_mask(const Image&, std::string& error, std::vector<float>* delta) {
    release_contrast_mask();
    if (delta) delta->clear();
    if (!contrast_mask_wanted()) return true;
    error = windows_unported_error(WindowsFeature::ContrastMask, true);
    return false;
}

bool Pipeline::contrast_mask_field(const Image& cmy, std::vector<float>& delta, uint32_t& gw,
                                   uint32_t& gh, std::string& error) {
    gw = gh = 0;
    return prepare_contrast_mask(cmy, error, &delta);
}

bool Pipeline::node_contrast_mask_epilogue(const Image&, Image&, std::string& error) {
    error = windows_unported_error(WindowsFeature::ContrastMask, true);
    return false;
}

}  // namespace spk
#endif  // !__APPLE__
