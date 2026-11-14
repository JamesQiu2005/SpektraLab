// Explicit boundaries for effects added upstream after the first Windows port.
// Included only by Windows call sites; macOS retains its upstream behavior.
#pragma once
#include "params.hpp"

namespace spk {

inline const char* windows_unported_error(bool di, bool latitude, bool mask,
                                         bool overscan, bool date, bool scan_hdr = false) {
    if (di) return "digital intermediate is not implemented by the Windows Vulkan backend yet";
    if (latitude) return "scene latitude mapping is not implemented by the Windows Vulkan backend yet";
    if (mask) return "contrast mask is not implemented by the Windows Vulkan backend yet";
    if (overscan) return "overscan is not implemented by the Windows Vulkan backend yet";
    if (date) return "date imprint is not implemented by the Windows Vulkan backend yet";
    // `scan_hdr` (2026-11-06): `spk_scan_hdr_expand` is Metal only.
    if (scan_hdr) return "scan_hdr is not implemented by the Windows Vulkan backend yet";
    return nullptr;
}

inline const char* windows_unported_error(const Params& p) {
    // RFC-052 §6.4: `spk_set_scene_layers` is refused here, so no session can
    // hold a set a stamp could name.
    if (!p.camera.scene_layers.empty()) return "scene layers are not implemented by the Windows Vulkan backend yet";
    return windows_unported_error(p.io.digital_intermediate, p.camera.scene_latitude.active,
                                  p.print_render.contrast_mask.active,
                                  p.film_render.overscan.active, p.film_render.date_imprint.active,
                                  p.io.scan_film && (p.io.scan_hdr_stretch || p.io.scan_hdr_headroom > 1.0));
}

// Validate an already schema-checked delta before it mutates the session.
// A valid Windows session cannot already have any of these flags enabled.
inline const char* windows_unported_delta_error(const Json& delta) {
    if (!delta.at("scene_layers").as_string().empty())
        return "scene layers are not implemented by the Windows Vulkan backend yet";
    return windows_unported_error(delta.at("digital_intermediate").as_bool(),
                                  delta.at("scene_latitude_active").as_bool(),
                                  delta.at("contrast_mask_active").as_bool(),
                                  delta.at("overscan_active").as_bool(),
                                  delta.at("date_imprint_active").as_bool(),
                                  // Conservative: the delta alone does not say the film is a
                                  // slide scanned, so any request for the variant is refused.
                                  delta.at("scan_hdr_stretch").as_bool() ||
                                      delta.at("scan_hdr_headroom").as_double(0.0) > 1.0);
}

}  // namespace spk
