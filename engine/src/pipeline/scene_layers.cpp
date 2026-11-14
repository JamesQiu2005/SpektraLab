// scene_layers.cpp -- RFC-052 §6, the 场景 stage's node: the pipeline half of
// `spk_set_scene_layers` (API-SPEC §23).
//
// Kept out of `pipeline.cpp` for the reason `scene_latitude.cpp` is: the film
// chain gained one guarded call in `film_scale_and_expose`, and with no stamp
// on the wire nothing in this file runs -- the render is the same dispatches
// with the same arguments as the engine without the feature (§6.4, gate 2).
//
// Metal only. The CMake targets (Windows, Linux) refuse a stamp and the call
// with a named error (`windows_unported.*`, `engine.cpp`), as they refuse the
// lens.
#ifdef __APPLE__
#include <cmath>
#include <cstdlib>
#include <cstring>

#include "pipeline.hpp"
#include "timer.hpp"

namespace spk {

bool scene_layer_cone_matrix(const Colour& colour, const std::string& colour_space, Mat3& out,
                             std::string& error) {
    // The working space's own RGB -> XYZ, no adaptation (its own white, D50
    // for ProPhoto RGB), then the CAT16 matrix as the engine bakes it
    // (`colour/cat/CAT16`, the one `matrix_chromatic_adaptation` uses). A
    // gain of (1, 1, 1) in this space is the identity; a host computing the
    // gain of a white moved along the locus computes the two whites' cone
    // responses with *this* matrix (the reply carries it).
    Mat3 to_xyz, cat16;
    if (!colour.matrix_RGB_to_XYZ(colour_space, nullptr, "CAT16", to_xyz, error)) return false;
    if (!colour.cat_matrix("CAT16", cat16, error)) return false;
    out = cat16 * to_xyz;
    return true;
}

bool Pipeline::node_scene_layers(const Image& in, Image& out, std::string& error) {
    Timer t(this, "filming.expose.scene_layers");
    // §6.4: the check that can fire. The planes travel by a call and the stamp
    // by the wire; a develop whose wire names another set than the one held
    // would be kept under the new stamp with the old masks in it. The session
    // asks first (`render_tier`, `negative_for`); this is the node's own, for a
    // pipeline driven without one.
    error = scene_layers_mismatch(params_.camera.scene_layers, scene_layers_.get());
    if (!error.empty()) return false;
    const SceneLayerSet& set = *scene_layers_;
    // A named set with no layers, or none that reaches a pixel: nothing to
    // run, and nothing is (the frame is handed on, not copied).
    bool any = false;
    for (const SceneLayerSet::Layer& l : set.layers) any = any || l.coverage > 0.0;
    if (!any) { out = in; return true; }

    // The cut, as `node_geometry` made it of the frame it was handed, and the
    // frame this image is (a band of): the two must agree, or the mask would
    // be laid on a picture the cut did not make.
    if (geometry_in_h_ == 0 || geometry_in_w_ == 0) {
        error = "scene_layers: the frame's geometry was not recorded before the node";
        return false;
    }
    float g[16];
    uint32_t gm[6];
    geometry_constants(params_.io.geometry, geometry_in_h_, geometry_in_w_, g, gm);
#ifndef SPK_HARDENED
    // RFC-052 §3's self-test (`engine/tests/scene_layers_checks.cpp`, gate 4):
    // one term of the cut broken for the mask alone, so the edge check is
    // shown to see a mask that drifted off the picture. The frame's shape is
    // kept (a crop's size alone moves no pixel, so the scale terms are broken
    // in the constants themselves). Not in a hardened build.
    if (const char* term = std::getenv("SPK_SCENE_LAYERS_BREAK")) {
        const std::string b = term;
        GeometryParams geo = params_.io.geometry;
        if (b == "crop_x") geo.crop_x += 0.01;
        else if (b == "crop_y") geo.crop_y += 0.01;
        else if (b == "rotation") geo.rotation_deg += 0.5;
        else if (b == "turns") geo.quarter_turns += 2;
        else if (b == "flip_h") geo.flip_h = !geo.flip_h;
        else if (b == "flip_v") geo.flip_v = !geo.flip_v;
        uint32_t broken[6];
        geometry_constants(geo, geometry_in_h_, geometry_in_w_, g, broken);
        gm[4] = broken[4];
        gm[5] = broken[5];
        if (b == "scale_x") { g[0] *= 1.01f; g[1] *= 1.01f; }
        if (b == "scale_y") { g[2] *= 1.01f; g[3] *= 1.01f; }
    }
#endif
    const uint32_t frame_h = strip_plane_h_ ? strip_plane_h_ : in.h;
    if (gm[2] != frame_h || gm[3] != in.w || band_row0_ + in.h > frame_h) {
        error = "scene_layers: the image (" + std::to_string(in.w) + " x " + std::to_string(frame_h) +
                ") is not the frame the cut made (" + std::to_string(gm[3]) + " x " + std::to_string(gm[2]) + ")";
        return false;
    }

    float p[27 + 8 * SceneLayerSet::kMaxLayers] = {};
    for (int k = 0; k < 9; ++k) p[k] = float(set.frame_to_source[k]);
    if (set.colour) {
        Mat3 c;
        if (!scene_layer_cone_matrix(*colour_, params_.io.input_color_space, c, error)) return false;
        double cm[9], ci[9];
        row_major(c, cm);              // the kernel's out[i] = Σ_j m[3i + j] x[j] (trap 20)
        row_major(c.inverse(), ci);
        for (int k = 0; k < 9; ++k) { p[9 + k] = float(cm[k]); p[18 + k] = float(ci[k]); }
    }
    const uint32_t count = uint32_t(set.layers.size());
    for (uint32_t l = 0; l < count; ++l) {
        const SceneLayerSet::Layer& L = set.layers[l];
        float* q = p + 27 + 8 * l;
        q[0] = float(L.coverage);
        q[1] = float(L.log_gain[0] / std::log(2.0));   // e_i, the scalar path's stops
        q[2] = float(L.log_gain[0]); q[3] = float(L.log_gain[1]); q[4] = float(L.log_gain[2]);
        q[5] = float(L.width); q[6] = float(L.height);
    }
    const uint32_t meta[11] = {uint32_t(in.pixels()), in.w, band_row0_, gm[0], gm[1], gm[2], gm[3],
                               gm[4], gm[5], count, set.colour ? 1u : 0u};
    gpu::BufferRef g_buf = gpu_->upload(g, sizeof g, error);
    gpu::BufferRef p_buf = gpu_->upload(p, sizeof p, error);
    if (!g_buf || !p_buf || !alloc_like(in, out, error)) return false;
    std::vector<gpu::Arg> args = {gpu::Arg::buf(in.buf), gpu::Arg::buf(g_buf),
                                  gpu::Arg::inline_bytes(meta, 11), gpu::Arg::buf(p_buf)};
    // Eight plane slots; the ones past `count` name the first plane, which the
    // kernel never reads through them.
    for (uint32_t l = 0; l < SceneLayerSet::kMaxLayers; ++l)
        args.push_back(gpu::Arg::buf(set.layers[l < count ? l : 0].plane));
    args.push_back(gpu::Arg::buf(out.buf));
    return gpu_->dispatch("spk_scene_layers", args, in.pixels(), error);
}

}  // namespace spk
#endif  // __APPLE__
