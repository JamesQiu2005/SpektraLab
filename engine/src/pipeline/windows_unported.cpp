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
    error = windows_unported_error(WindowsFeature::Overscan, true);
    return false;
}

// Main added spk_overscan_geometry after the Windows port's root (61bfc49);
// the clean textual merge left this undefined and the non-Apple engine did
// not link. Overscan is refused here, so there is never a layout to report.
std::string Pipeline::overscan_geometry_json() const { return "{\"valid\":false}"; }

bool Pipeline::node_overscan(const Image& in, Image& out, std::string& error) {
    if (params_.film_render.overscan.active || params_.film_render.date_imprint.active) {
        error = windows_unported_error(params_.film_render.overscan.active ? WindowsFeature::Overscan
                                                                           : WindowsFeature::DateImprint, true);
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

}  // namespace spk
#endif  // !__APPLE__
