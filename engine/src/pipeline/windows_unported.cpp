// Off-path adapters for upstream effects that still depend on Apple services.
// Mac build.sh globs pipeline/*.cpp, so the whole translation unit is guarded.
#ifndef __APPLE__
#include "pipeline.hpp"
#include "windows_unported.hpp"

namespace spk {

bool Pipeline::overscan_wanted() const { return params_.film_render.overscan.active; }

double Pipeline::overscan_gate_long_mm() const { return params_.camera.film_format_mm; }

void Pipeline::overscan_frame(uint32_t& frame_w, uint32_t& frame_h) const {
    frame_w = frame_h = 0;
}

bool Pipeline::set_overscan_frame(uint32_t, uint32_t, std::string& error) {
    if (!overscan_wanted()) return true;
    error = windows_unported_error(false, false, false, true, false);
    return false;
}

// Main added spk_overscan_geometry after the Windows port's root (unpublished-revision);
// the clean textual merge left this undefined and the non-Apple engine did
// not link. Overscan is refused here, so there is never a layout to report.
std::string Pipeline::overscan_geometry_json() const { return "{\"valid\":false}"; }

// API-SPEC §21.5-§21.6: the lens pass (`lens.cpp`) dispatches Metal kernels
// only, so it is refused here rather than run on kernels Vulkan lacks.
bool Pipeline::film_lens_wanted() const {
    return params_.camera.diffusion_filter.active || params_.camera.lens_aberrations.active;
}

bool Pipeline::lens_source(const Params& params, const Image& src, bool, Image& out, std::string& error,
                           bool, const Image*) {
    params_ = params;
    out = src;
    if (!film_lens_wanted()) return true;
    error = "the lens (diffusion filter, aberrations) is not implemented by the Windows Vulkan backend yet";
    return false;
}

bool Pipeline::node_overscan(const Image& in, Image& out, std::string& error) {
    if (params_.film_render.leak.kind != "off") {   // API-SPEC §21.1: the overscan node's
        error = "light leaks are not implemented by the Windows Vulkan backend yet";
        return false;
    }
    if (params_.film_render.overscan.active || params_.film_render.date_imprint.active) {
        error = windows_unported_error(false, false, false, params_.film_render.overscan.active,
                                        params_.film_render.date_imprint.active);
        return false;
    }
    out = in;
    return true;
}

bool Pipeline::node_overscan_film_present(const Image& in, Image& out, std::string& error) {
    return node_overscan(in, out, error);
}

bool Pipeline::node_overscan_light(const Image& in, Image& out, std::string& error) {
    return node_overscan(in, out, error);
}

// RFC-052 §6.4: the 场景 layers' kernel is Metal only. `windows_unported_error`
// refuses a stamp at build; this is the node's own backstop.
bool Pipeline::node_scene_layers(const Image&, Image&, std::string& error) {
    error = "scene layers are not implemented by the Windows Vulkan backend yet";
    return false;
}

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
    error = windows_unported_error(false, false, true, false, false);
    return false;
}

bool Pipeline::contrast_mask_field(const Image& cmy, std::vector<float>& delta, uint32_t& gw,
                                   uint32_t& gh, std::string& error) {
    gw = gh = 0;
    return prepare_contrast_mask(cmy, error, &delta);
}

bool Pipeline::node_contrast_mask_epilogue(const Image&, Image&, std::string& error) {
    error = windows_unported_error(false, false, true, false, false);
    return false;
}

}  // namespace spk
#endif  // !__APPLE__
