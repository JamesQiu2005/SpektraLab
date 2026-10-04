// scene_latitude.cpp -- RFC-023's Scene Latitude Mapping, the pipeline half.
//
// Kept out of `pipeline.cpp` for the same reason `contrast_mask.cpp` is: the
// film chain there gained one guarded call in `film_scale_and_expose`, and
// with the feature off nothing in this file runs -- the render is the same
// dispatches with the same arguments as before.
//
// The node sits after auto-exposure and before `upsample`, so its `E = 0` is
// the metered mid-grey and Exp. Comp. is applied after it by `node_exposure`,
// unchanged (§5.1, §15.4: Exp. Comp. has a second consumer in the enlarger,
// so Scene Latitude does not carry it).
#include <algorithm>
#include <cmath>

#include "pipeline.hpp"
#include "latitude_fit.hpp"
#include "timer.hpp"

namespace spk {

bool Pipeline::scene_latitude_wanted() const {
    const SceneLatitudeParams& s = params_.camera.scene_latitude;
    // The print LUT bake renders a neutral chain; a scene transform has no
    // place in a table that stands for the paper.
    const bool first = s.active && (s.highlight_room > 0.0 || s.shadow_room > 0.0);
    const bool second = s.split > 0.0 && s.b_active && (s.b_highlight_room > 0.0 || s.b_shadow_room > 0.0);
    return (first || second) && !params_.debug.lut_mode;
}

namespace {

float norm_id(const std::string& norm) { return norm == "y" ? 1.0f : norm == "max" ? 2.0f : 0.0f; }

}  // namespace

bool Pipeline::node_scene_latitude(const Image& in, Image& out, std::string& error) {
    Timer t(this, "filming.expose.scene_latitude");
    const SceneLatitudeParams& s = params_.camera.scene_latitude;
    // A side that is off is a room of zero, which the kernel skips. On a
    // half-frame pair the second frame's curve applies from `split` along the
    // piece's long edge.
    const bool second = s.split > 0.0 && s.b_active;
    // A strip of RFC-020's executor is part of the piece: full-width, and wider
    // than it is tall on a piece held upright, so read by its own shape the
    // second curve fell across the picture instead of along it. The split is
    // measured along the frame: the plane's height and the strip's first row
    // are the executor's (`strip_plane_h_`, `band_row0_`; both 0 when it is not
    // running, which leaves a whole render as it was, to the bit).
    const uint32_t fw = in.w;
    const uint32_t fh = strip_plane_h_ ? strip_plane_h_ : in.h;
    const uint32_t row0 = band_row0_;
    const float p[19] = {
        float(s.highlight_knee), float(s.active ? s.highlight_room : 0.0),
        float(s.shadow_knee), float(s.active ? s.shadow_room : 0.0),
        float(s.rolloff), float(s.max_lift), norm_id(s.norm),
        float(rgb_to_xyz_ae_.m[1][0]), float(rgb_to_xyz_ae_.m[1][1]), float(rgb_to_xyz_ae_.m[1][2]),
        float(slm::kMidgray),
        float(fw), float(fh), float(s.split),
        float(s.b_highlight_knee), float(second ? s.b_highlight_room : 0.0),
        float(s.b_shadow_knee), float(second ? s.b_shadow_room : 0.0),
        float(row0)};
    gpu::BufferRef p_buf = gpu_->upload(p, sizeof p, error);
    if (!p_buf || !alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.pixels())};
    return gpu_->dispatch("spk_scene_latitude",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(p_buf), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

bool Pipeline::scene_latitude_sample(const Image& in, double ev, std::vector<double>& E,
                                     std::string& error, const double* region) {
    // The node's own upstream nodes, as `measure_meter_evs` runs them: the
    // sample sees what the node would, decoded, cropped and turned.
    const uint32_t saved_long_edge = source_long_edge_;
    Progress* const saved_progress = progress_;
    progress_ = nullptr;
    Image cast, decoded, framed;
    const bool ok = node_input_cast(in, cast, error) &&
                    node_decode_input(cast, decoded, error) &&
                    node_geometry(decoded, framed, error);
    source_long_edge_ = saved_long_edge;
    progress_ = saved_progress;
    if (!ok) return false;
    std::vector<float> host;
    if (!read_back(framed, host, error)) return false;

    // The auto-exposure gain as the node applies it (narrowed to float32 first),
    // then the node's norm. A pixel whose norm is not positive and finite takes
    // k = 1 in the node, so it is not on the curve's axis at all and is left
    // out of the statistic rather than parked at the floor.
    const double gain = double(float(std::pow(2.0, ev)));
    const std::string& norm = params_.camera.scene_latitude.norm;
    const double yr = rgb_to_xyz_ae_.m[1][0], yg = rgb_to_xyz_ae_.m[1][1], yb = rgb_to_xyz_ae_.m[1][2];
    const size_t count = host.size() / 3;
    E.clear();
    E.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        // A region (x0, y0, x1, y1, normalised to the frame): one frame of a
        // pair, measured by itself.
        if (region && framed.w > 0 && framed.h > 0) {
            const double x = (double(i % framed.w) + 0.5) / framed.w, y = (double(i / framed.w) + 0.5) / framed.h;
            if (x < region[0] || x >= region[2] || y < region[1] || y >= region[3]) continue;
        }
        const double r = std::max(double(host[3 * i]) * gain, 0.0);
        const double g = std::max(double(host[3 * i + 1]) * gain, 0.0);
        const double b = std::max(double(host[3 * i + 2]) * gain, 0.0);
        double v;
        if (norm == "y") v = yr * r + yg * g + yb * b;
        else if (norm == "max") v = std::max(r, std::max(g, b));
        else {
            const double s2 = r * r + g * g + b * b;
            v = s2 > 0.0 ? (r * r * r + g * g * g + b * b * b) / s2 : 0.0;
        }
        if (!(v > 0.0) || !std::isfinite(v)) continue;
        E.push_back(std::clamp(std::log2(v / slm::kMidgray), -slm::kDomainStops, slm::kDomainStops));
    }
    return true;
}

}  // namespace spk
