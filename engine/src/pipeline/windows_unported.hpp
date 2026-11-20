// Explicit boundaries for effects added upstream after the first Windows port.
// Included only by Windows call sites; macOS retains its upstream behavior.
#pragma once
#include "params.hpp"

namespace spk {

inline const char* windows_unported_error(bool di, bool latitude, bool mask,
                                         bool overscan, bool date, bool scan_hdr = false) {
    // The Digital Intermediate renders on Vulkan since spk_di_encode was ported (spk_di_encode.comp,
    // tests/gpu_vulkan_di_encode.cpp); the flag stays in the signature for its callers.
    (void)di;
    // Scene latitude mapping renders on Vulkan since spk_scene_latitude was ported.
    (void)latitude;
    // The contrast mask renders on Vulkan since spk_mask_reduce/spk_mask_epilogue were ported.
    (void)mask;
    // The film edge and the date back render on Vulkan since overscan.metal's kernels were ported
    // (spk_overscan_*.comp) and their imprints are drawn without CoreText (edge_raster.cpp). edge_raster
    // finds its faces in the Linux font folders only, so Windows keeps refusing them until it has fonts.
#ifdef _WIN32
    if (overscan) return "the film edge is not implemented by the Windows Vulkan backend yet (no edge fonts)";
    if (date) return "the date imprint is not implemented by the Windows Vulkan backend yet (no edge fonts)";
#else
    (void)overscan;
    (void)date;
#endif
    // `scan_hdr` renders on Vulkan since spk_scan_hdr_expand was ported (spk_scan_hdr_expand.comp).
    (void)scan_hdr;
    return nullptr;
}

inline const char* windows_unported_error(const Params& p) {
    // RFC-052's scene layers render on Vulkan since spk_scene_layers was ported.
    return windows_unported_error(p.io.digital_intermediate, p.camera.scene_latitude.active,
                                  p.print_render.contrast_mask.active,
                                  p.film_render.overscan.active, p.film_render.date_imprint.active,
                                  p.io.scan_film && (p.io.scan_hdr_stretch || p.io.scan_hdr_headroom > 1.0));
}

// Validate an already schema-checked delta before it mutates the session.
// A valid Windows session cannot already have any of these flags enabled.
inline const char* windows_unported_delta_error(const Json& delta) {
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
