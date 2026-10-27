// Compatibility boundary retained for Windows callers. All five original
// pipeline features now have native implementations. An image host may still
// disclose its own presentation/export limits (notably the Cineon DI view).
#pragma once
#include "params.hpp"

namespace spk {

inline const char* windows_unported_error(bool /*di*/, bool /*latitude*/, bool /*mask*/,
                                         bool /*overscan*/, bool /*date*/) {
    return nullptr;
}

inline const char* windows_unported_error(const Params& p) {
    return windows_unported_error(p.io.digital_intermediate, p.camera.scene_latitude.active,
                                  p.print_render.contrast_mask.active,
                                  p.film_render.overscan.active, p.film_render.date_imprint.active);
}

// Validate an already schema-checked delta before it mutates the session.
inline const char* windows_unported_delta_error(const Json& delta) {
    return windows_unported_error(delta.at("digital_intermediate").as_bool(),
                                  delta.at("scene_latitude_active").as_bool(),
                                  delta.at("contrast_mask_active").as_bool(),
                                  delta.at("overscan_active").as_bool(),
                                  delta.at("date_imprint_active").as_bool());
}

}  // namespace spk
