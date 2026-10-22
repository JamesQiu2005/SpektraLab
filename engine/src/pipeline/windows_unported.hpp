// Explicit boundaries for effects added upstream after the first Windows port.
// Included only by Windows call sites; macOS retains its upstream behavior.
#pragma once
#include "params.hpp"

namespace spk {

// Keep the upstream five-slot call sites; only the still-hidden contrast-mask
// experiment remains unsupported. Public features now have Vulkan paths.
inline const char* windows_unported_error(bool /*di*/, bool /*latitude*/, bool mask,
                                         bool /*overscan*/, bool /*date*/) {
    if (mask) return "contrast mask is not implemented by the Windows Vulkan backend yet";
    return nullptr;
}

inline const char* windows_unported_error(const Params& p) {
    return windows_unported_error(p.io.digital_intermediate, false,
                                  p.print_render.contrast_mask.active,
                                  p.film_render.overscan.active, p.film_render.date_imprint.active);
}

// Validate an already schema-checked delta before it mutates the session.
// A valid Windows session cannot already have contrast_mask_active enabled.
inline const char* windows_unported_delta_error(const Json& delta) {
    return windows_unported_error(delta.at("digital_intermediate").as_bool(),
                                  false,
                                  delta.at("contrast_mask_active").as_bool(),
                                  delta.at("overscan_active").as_bool(),
                                  delta.at("date_imprint_active").as_bool());
}

}  // namespace spk
