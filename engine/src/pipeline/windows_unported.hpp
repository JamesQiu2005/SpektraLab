// Explicit boundaries for effects added upstream after the first Windows port.
// Included only by Windows call sites; macOS retains its upstream behavior.
//
// One row per effect. The refusals (Pipeline::build, spk_update, the DI entry
// point) and the capabilities' `unsupported_features` list all read this one
// table, so a feature cannot be refused while advertised or the reverse. A
// port flips its row's `ported` in the same commit that lands the kernels.
#pragma once
#include "params.hpp"

namespace spk {

enum class WindowsFeature { DigitalIntermediate, SceneLatitude, ContrastMask, Overscan, DateImprint };

struct WindowsFeatureRow {
    WindowsFeature id;
    const char* capability;   // the name in capabilities.backend.unsupported_features
    const char* error;
    bool ported;
};

inline constexpr WindowsFeatureRow kWindowsFeatures[] = {
    {WindowsFeature::DigitalIntermediate, "digital_intermediate",
     "digital intermediate is not implemented by the Windows Vulkan backend yet", true},
    {WindowsFeature::SceneLatitude, "scene_latitude_mapping",
     "scene latitude mapping is not implemented by the Windows Vulkan backend yet", true},
    {WindowsFeature::ContrastMask, "contrast_mask",
     "contrast mask is not implemented by the Windows Vulkan backend yet", true},
    {WindowsFeature::Overscan, "overscan",
     "overscan is not implemented by the Windows Vulkan backend yet", false},
    {WindowsFeature::DateImprint, "date_imprint",
     "date imprint is not implemented by the Windows Vulkan backend yet", false},
};

inline const WindowsFeatureRow& windows_feature(WindowsFeature id) {
    for (const auto& row : kWindowsFeatures)
        if (row.id == id) return row;
    return kWindowsFeatures[0];  // unreachable: every enumerator has a row
}

// nullptr when the feature is ported or not requested.
inline const char* windows_unported_error(WindowsFeature id, bool requested) {
    const WindowsFeatureRow& row = windows_feature(id);
    return requested && !row.ported ? row.error : nullptr;
}

// What each feature's request looks like on the wire, from the values a
// session would hold. The latitude's second pair counts on its own:
// Pipeline::scene_latitude_wanted() runs the node for `split > 0 && b_active`
// even with the first pair off, and checking `active` alone let that through
// to a render that then failed for want of the kernel.
struct WindowsFeatureRequest {
    bool di, latitude, mask, overscan, date;
};

inline const char* windows_unported_error(const WindowsFeatureRequest& r) {
    if (const char* e = windows_unported_error(WindowsFeature::DigitalIntermediate, r.di)) return e;
    if (const char* e = windows_unported_error(WindowsFeature::SceneLatitude, r.latitude)) return e;
    if (const char* e = windows_unported_error(WindowsFeature::ContrastMask, r.mask)) return e;
    if (const char* e = windows_unported_error(WindowsFeature::Overscan, r.overscan)) return e;
    if (const char* e = windows_unported_error(WindowsFeature::DateImprint, r.date)) return e;
    return nullptr;
}

inline const char* windows_unported_error(const Params& p) {
    const SceneLatitudeParams& s = p.camera.scene_latitude;
    return windows_unported_error(WindowsFeatureRequest{
        p.io.digital_intermediate, s.active || (s.split > 0.0 && s.b_active),
        p.print_render.contrast_mask.active, p.film_render.overscan.active,
        p.film_render.date_imprint.active});
}

// Validate an already schema-checked delta before it mutates the session:
// each field is the delta's value when it carries one, else the session's.
inline const char* windows_unported_delta_error(const Json& delta, const Params& current) {
    const auto flag = [&](const char* key, bool now) { return delta.has(key) ? delta.at(key).as_bool(now) : now; };
    const auto number = [&](const char* key, double now) { return delta.has(key) ? delta.at(key).as_double(now) : now; };
    const SceneLatitudeParams& s = current.camera.scene_latitude;
    return windows_unported_error(WindowsFeatureRequest{
        flag("digital_intermediate", current.io.digital_intermediate),
        flag("scene_latitude_active", s.active) ||
            (number("scene_latitude_split", s.split) > 0.0 && flag("scene_latitude_b_active", s.b_active)),
        flag("contrast_mask_active", current.print_render.contrast_mask.active),
        flag("overscan_active", current.film_render.overscan.active),
        flag("date_imprint_active", current.film_render.date_imprint.active)});
}

}  // namespace spk
