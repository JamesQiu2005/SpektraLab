// engine.cpp -- the C ABI, and the session behind it.
//
// A port of `service/engine.RenderEngine` and `service/session.RenderSession`,
// with the transport deleted. What that deletion removes, concretely:
//
//   * a 364 MB uncompressed TIFF crossing the boundary on every `open`, in
//     each direction;
//   * `_write_rgba16`, which was 10 ms of a 30.6 ms reprint -- a third of it;
//   * JSON-RPC framing, a workspace directory, and every filename in it.
//
// What it keeps, deliberately: the method surface, the tier names, the
// reply shapes and the two version numbers. The frontend asks the same
// questions and gets the same answers (contract §2), which is what makes this
// a deletion rather than a rewrite.
//
// One thing the in-process boundary lets go of. The Python engine holds an LRU
// over whole sessions (RFC-013 §2) because the wire has no way to express a
// session's lifetime -- a session id is a string and the client may come back
// to it at any time. Here a session *is* a pointer the caller holds, so the
// caller's own retention is the cache, and `spk_session_release` is when it
// ends. The `session_cache` field stays in `capabilities` so the frontend's
// status bar keeps working; it reports the sessions currently open.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#endif

#include "spektrafilm/spk_engine.h"
#include "file_path.hpp"

#include "blob.hpp"
#include "colour.hpp"
#include "image.hpp"
#include "json.hpp"
#include "latitude_fit.hpp"
#include "params.hpp"
#include "pipeline.hpp"
#include "print_lut.hpp"
#include "setup_cache.hpp"
#ifndef __APPLE__
#include "windows_unported.hpp"
#include "view_process.hpp"
#endif

using namespace spk;

namespace {

#ifndef __APPLE__
constexpr const char* kRenderCore = "native-vulkan";
#else
constexpr const char* kRenderCore = "native-metal";
#endif

// API-SPEC §6's three tiers, by long edge in pixels. `live` targets the
// interaction budget for a print-side slider drag; `preview` is deliberately
// large enough to read grain and halation, which are invisible at contact
// sheet scale.
struct Tier {
    const char* name;
    uint32_t long_edge;   // 0 = the frame's own resolution
};
constexpr Tier kTiers[] = {{"live", 1600}, {"preview", 3400}, {"full", 0}};

// RFC-015 P.1: the auto-exposure meter's own resolution. Each tier used to
// meter its own image, so an export was exposed differently from the canvas
// the user approved (up to +0.069 EV of print luminance on real RAWs). The
// session meters once, on the frame downscaled to this long edge and taken
// through decode_input and geometry, and every tier applies that EV. Its own
// constant, so a tier change cannot move auto exposure; when the live tier is
// the same size its image is reused.
constexpr uint32_t kMeterLongEdge = 1600;
// The wire fields upstream of the auto-exposure node: the only ones that can
// change what it meters, so the only ones that re-meter. The film, exposure
// compensation and the method itself leave the cached meter valid.
// `parity_exposure.py` (c5) walks the whole schema to catch a missing one.
constexpr const char* kMeterKeyFields[] = {
    "input_color_space", "input_cctf_decoding",
    "geometry_crop_x", "geometry_crop_y", "geometry_crop_w", "geometry_crop_h",
    "geometry_rotation_deg", "geometry_quarter_turns", "geometry_flip_h", "geometry_flip_v",
};

// The hard cap on a frame's size, as a **pixel count** rather than a
// megapixel figure, because that is what memory scales with: the decoded
// frame, the engine's own copy of it and the three tier images are all linear
// in pixels, and a 3:1 panorama is three times a 1:1 frame at the same
// megapixels.
//
// 14204 x 10652 is the Phase One IQ4 150, and the user set it as the wall:
// "nobody will feed it anything larger". It was 60 MP before, which was a
// number inherited from the Python service (`spektrafilm/service/engine.py`,
// `MAX_MP`, added 2026-08-25) with nothing behind it — and it excluded a
// camera that shipped in 2022 (the A7R V decodes to 60.22 MP).
constexpr uint32_t kMaxFramePixels = 14204u * 10652u;   // 151,301,008 px

const Tier* find_tier(const char* name) {
    if (!name) return nullptr;
    for (const Tier& t : kTiers) if (std::strcmp(t.name, name) == 0) return &t;
    return nullptr;
}

// The `live` tier's long edge is a **session setting** (`io.preview_long_edge`)
// rather than the number in the table above: the app calls it the preview
// resolution and lets the user choose it. The table keeps the default, so a
// caller that never sends the field renders exactly what it always did, and
// the tier's *name* stays what the wire addresses (CONTRACT §1.2.3) -- only
// its size moves.
uint32_t tier_long_edge(const Params& params, const Tier& tier) {
    if (tier.long_edge == 0) return 0;   // `full`: the frame's own resolution
    if (std::strcmp(tier.name, "live") != 0) return tier.long_edge;
    return params.io.preview_long_edge > 0 ? static_cast<uint32_t>(params.io.preview_long_edge)
                                           : tier.long_edge;
}

std::string read_text_file(const std::string& path) {
    std::ifstream in(file_path(path), std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// A per-thread error slot, so `spk_last_error` is meaningful when two threads
// render different tiers at once -- which the engine supports and the Python
// service's numba path never could.
thread_local std::string g_error;

char* dup_json(const Json& j) {
    const std::string text = j.dump();
    char* out = static_cast<char*>(std::malloc(text.size() + 1));
    if (out) std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}

uint32_t next_id() {
    static std::atomic<uint32_t> counter{1};
    return counter.fetch_add(1);
}

}  // namespace

// ---------------------------------------------------------------------------
// the session
// ---------------------------------------------------------------------------

/// The open-delta key that selects the product's defaults rather than the
/// reference's. Deliberately **not** a `params_schema` row: it picks a set of
/// defaults, it is an open-time decision, and adding a 42nd wire field would
/// put `parity_schema` in the position of reporting a divergence from the
/// Python oracle that is not one.
constexpr const char* kProductDefaultsKey = "product_defaults";

/// What "the product's defaults" means, in one place both `spk_open` and
/// `spk_set_params`'s stock rebuild call.
///
/// Today it is one field. It is a function anyway because the rebuild path has
/// to re-apply every one of them after `init_params` has reset the tree, and a
/// second field added to one site and not the other would show up as a print
/// that changes brightness the first time the user picks a different paper.
static void apply_product_defaults(Params& params, bool product_defaults) {
    if (!product_defaults) return;
    // SpektraLab has no "Print auto compensation" switch, so Camera Exp. Comp.
    // has to move the finished print rather than only the negative's placement
    // on the film curve.
    params.enlarger.print_exposure_compensation = false;
}

struct spk_session {
    spk_engine* engine = nullptr;
    std::string session_id;

    // The source frame at its own resolution, **on the device**. A tier is
    // built from it lazily and a stock change re-renders from it, so it has to
    // be kept -- but keeping it on the host meant a full-frame copy at `open`
    // and a second upload per tier. At 24 MP that was 384 MB of each.
    //
    // `spk_open` is documented not to retain the caller's pointer, so exactly
    // one copy is unavoidable; this makes that copy the upload.
    Image source;

#ifndef __APPLE__
    // No image buffer is retained here. The file owns the exact byte copy,
    // and the indices preserve source/full-tier aliases on restoration.
    struct ResidencySnapshot {
        struct Plane { size_t bytes = 0; };
        struct Slot {
            size_t plane = size_t(-1);
            uint32_t h = 0, w = 0, c = 3;
        };
        struct TierSlots { Slot image, negative, view_print; };
        std::unique_ptr<std::FILE, decltype(&std::fclose)> file{nullptr, &std::fclose};
        std::vector<Plane> planes;
        Slot source;
        std::unordered_map<std::string, TierSlots> tiers;
    };
    std::unique_ptr<ResidencySnapshot> residency;
#endif

    Params params;
    std::unique_ptr<Pipeline> pipeline;

    // SpektraLab deliberately does not expose the reference GUI's
    // `print_exposure_compensation` switch. Its Camera Exp. Comp. therefore
    // has to move the finished print's brightness, rather than only moving
    // the negative on the film curve.
    //
    // The caller asks for it **by name**, with `product_defaults` in the open
    // delta (`kProductDefaultsKey`). It used to be inferred from whether the
    // delta happened to carry `preview_long_edge`, which was true of the app
    // and false of the parity clients — so it worked, but the product's colour
    // behaviour hung on the presence of an unrelated field. Moving the preview
    // resolution out of the open delta, which is an ordinary thing for a
    // frontend to do, would have silently restored the reference's
    // compensation and changed every print's brightness with nothing failing.
    bool product_defaults = false;

    // Per tier: the downscaled source, the cached negative, and the result.
    struct TierState {
        Image image;      // the source at this tier
        /// The long edge `image` was built at. Part of the cache key, because
        /// `io.preview_long_edge` is a session setting: a tier map keyed by
        /// name alone would hand back a 1600 px image after the user asked
        /// for 2560 and render the wrong size without failing.
        uint32_t image_long_edge = 0;
        Image negative;   // Tap.CMY_FILM
        bool has_negative = false;
#ifndef __APPLE__
        // Encoded RGBA16 on device (c=2 uint32 words/pixel). Kept until a
        // material parameter changes; view edits never redraw film grain.
        Image view_print;
#endif
        /// RFC-032 §27: the frame `negative`'s film canvas was laid out for,
        /// so a reprint can lay it out again. Zero without overscan.
        uint32_t overscan_frame_w = 0, overscan_frame_h = 0;
        std::optional<double> applied_ev;   // what the node applied to `negative`
    };
    std::unordered_map<std::string, TierState> tiers;

    // The frame's one auto-exposure meter, all seven methods (RFC-015 P.1),
    // valid while the upstream fields in `key` are unchanged.
    struct Meter {
        bool valid = false;
        std::string key;
        ExposureEvs evs;
    } meter;

    // RFC-023: the medium probe and the scene statistic behind
    // `spk_scene_latitude`, each kept until something it read changes. The
    // medium is a render of a neutral ramp (§8.1), so it is worth keeping;
    // the scene is one read-back of the meter's frame.
    struct SceneLatitude {
        std::string medium_key, scene_key;
        slm::Medium medium;
        slm::SceneStats scene;
    } scene_latitude;

    // RFC-024: the last field `spk_contrast_mask_field` returned. The caller's
    // pointer is into this, valid until the next call on the session.
    std::vector<float> mask_field;

    std::mutex lock;
    Progress progress;
};

// ---------------------------------------------------------------------------
// the engine
// ---------------------------------------------------------------------------

struct spk_engine {
    std::string resources_dir;
    Blob blob;
    Colour colour;
    gpu::Gpu* gpu = nullptr;
    Json neutral_filters;
    // The eight baked print+scan LUTs, loaded lazily and kept: `print_lut.hpp`
    // for what they are and what they deliberately leave out.
    PrintLutLibrary print_luts;
    // One device copy per stock, alongside the host table. Flipping between
    // stocks is the whole point of this path, so re-uploading 431 kB on every
    // flip would be paying for the thing the LUT exists to avoid.
    std::unordered_map<std::string, gpu::BufferRef> print_lut_buffers;
    // The C_max tables `spk_output_transform` hands out, one per destination
    // colour space, as the float32 the caller's kernel reads.
    //
    // Kept here rather than in the `SetupCache` because the cache holds them
    // in float64 -- the bisection needs it -- and because the ABI promises a
    // pointer that stays good for the engine's lifetime. `unordered_map` is
    // node-based, so a pointer into a value survives every later insert; the
    // same property `print_lut_buffers` relies on.
    std::unordered_map<std::string, std::vector<float>> cam16_cmax_f32;
    // Shared by every pipeline this engine builds, which is the point: a
    // slider outside LIVE_MUTABLE rebuilds the pipeline, and neither of these
    // depends on what the slider changed.
    SetupCache setup_cache;
    std::string math_mode;
    std::string cached_capabilities;
    std::string cached_schema;
    std::string cached_memory_report;
    std::vector<spk_session*> sessions;
    // RFC-020 §3.1: the frame the pool's buffers were made for. A pool is a
    // set of planes of *some* frame, and this is what says whether the frame
    // being opened is that one. Guarded by `lock`, like `sessions`.
    bool pool_frame_valid = false;
    uint32_t pool_frame_w = 0, pool_frame_h = 0;
    std::mutex lock;

    ~spk_engine() {
        // Before `delete gpu`, and that ordering is the whole of this
        // destructor. A `BufferRef` releases through the `Gpu` it was
        // allocated from, and members are destroyed *after* the destructor
        // body -- so leaving the cached LUT tables to be cleaned up
        // implicitly called `release` on a deleted backend. It segfaulted at
        // process exit, after every parity case had already passed and been
        // printed, which is exactly the shape of failure a harness does not
        // see.
        print_lut_buffers.clear();
        delete gpu;
    }

    Json capabilities_json() {
        Json backend = Json::object();
        backend.set("spectral", Json(std::string("native")));
        backend.set("gpu", Json(gpu ? gpu->device_name() : std::string("none")));
        backend.set("gpu_available", Json(gpu != nullptr));
        backend.set("working_precision", Json(std::string("float32")));
        // Contract §6 / RFC-014 §5.1 trap 6: what the engine *loaded*, not
        // what the process could reach. `render_core` was a probe of
        // availability, and that hid a session silently demoted to the CPU
        // while capabilities still said metal.
        backend.set("render_core", Json(std::string(kRenderCore)));
        backend.set("host", Json(std::string("native")));
        backend.set("math_mode", Json(math_mode));
#ifndef __APPLE__
        // These upstream effects still require kernels or Apple services that
        // have not been ported. Defaults stay usable; explicit requests fail.
        Json unported = Json::array();
        for (const char* feature : {"contrast_mask"})
            unported.push(Json(std::string(feature)));
        backend.set("unsupported_features", std::move(unported));
#endif
        // Concurrent entry is safe: there is no numba here, and renders on
        // different tiers hold different locks.
        backend.set("concurrent", Json(true));
        Json cache = Json::object();
        cache.set("entries", Json(double(sessions.size())));
        cache.set("max_entries", Json(double(0)));
        cache.set("enabled", Json(false));
        // The setup cache is what decides whether a non-live slider costs
        // 7 ms or 250, so its hit rate belongs next to the session count
        // rather than in a log.
        const SetupCache::Stats s = setup_cache.stats();
        cache.set("hits", Json(double(s.hits)));
        cache.set("misses", Json(double(s.misses)));
        cache.set("setup_tc_luts", Json(double(s.lut_entries)));
        cache.set("setup_cam16", Json(double(s.cam16_entries)));
        backend.set("session_cache", std::move(cache));

        Json out = Json::object();
        out.set("version", Json(std::string(spk_build_info())));
        out.set("engine", Json(std::string("spektrafilm.native")));
        out.set("max_mp", Json(double(kMaxFramePixels) / 1e6));
        out.set("max_pixels", Json(double(kMaxFramePixels)));
        out.set("max_texture_dimension_2d", Json(double(gpu ? gpu->max_texture_dimension_2d() : 0)));
        // The `live` row here is the **default**: capabilities is answered by
        // the engine, before any session exists, and the live tier's size is
        // settable per session (`io.preview_long_edge`). A caller that wants
        // the size it is actually rendering at reads `preview_long_edge` back
        // from `params`, which is what the app does.
        Json tiers = Json::object();
        for (const Tier& t : kTiers) {
            if (t.long_edge) tiers.set(t.name, Json(double(t.long_edge)));
            else tiers.set(t.name, Json());
        }
        out.set("tiers", std::move(tiers));
        out.set("transport_version", Json(double(SPK_TRANSPORT_VERSION)));
        out.set("schema_version", Json(double(SPK_SCHEMA_VERSION)));
        out.set("backend", std::move(backend));
        return out;
    }

    // RFC-020 §3.3. The shape is in the header, next to the entry point, and
    // the one thing worth repeating here is the relationship the caller has to
    // get right: the per-session rows are a breakdown *of* `persistent.bytes`.
    // RFC-019 P6's whole question is what the gap between the arena and the
    // process is, and a report that can be read two ways would answer it two
    // ways.
    Json memory_report_json() {
        const gpu::PoolStats pool = gpu ? gpu->pool_stats() : gpu::PoolStats{};

        Json pool_json = Json::object();
        pool_json.set("total_bytes", Json(double(pool.total_bytes)));
        pool_json.set("live_bytes", Json(double(pool.live_bytes)));
        pool_json.set("free_bytes", Json(double(pool.free_bytes)));
        pool_json.set("pending_bytes", Json(double(pool.pending_bytes)));
        pool_json.set("buffers", Json(double(pool.buffers)));
        pool_json.set("live_buffers", Json(double(pool.live_buffers)));
        pool_json.set("free_buffers", Json(double(pool.free_buffers)));
        pool_json.set("pending_buffers", Json(double(pool.pending_buffers)));
        // The size a `warn` pressure event would keep (RFC-020 §3.2), so a
        // reader can tell "the pool is idle" from "the pool is as big as this
        // frame ever gets".
        pool_json.set("frame_high_water_bytes", Json(double(pool.frame_high_water_bytes)));

        // RFC-020 §3's audit, for `engine/tests/pool_invariants.py`: what the
        // pool handed out, and the three counters that must stay zero. They
        // are properties argued in comments in `metal_gpu.cpp`; a comment
        // cannot fail and these can, which is the whole reason they exist.
        Json audit = Json::object();
        audit.set("allocations", Json(double(pool.audit.allocations)));
        audit.set("reuses", Json(double(pool.audit.reuses)));
        audit.set("persistent_allocations", Json(double(pool.audit.persistent_allocations)));
        audit.set("reuse_bytes_requested", Json(double(pool.audit.reuse_bytes_requested)));
        audit.set("reuse_bytes_taken", Json(double(pool.audit.reuse_bytes_taken)));
        audit.set("reuse_max_taken", Json(double(pool.audit.reuse_max_taken)));
        audit.set("reuse_max_taken_for_request", Json(double(pool.audit.reuse_max_taken_for_request)));
        audit.set("pending_held", Json(double(pool.audit.pending_held)));
        audit.set("live_underflows", Json(double(pool.audit.live_underflows)));
        audit.set("over_releases", Json(double(pool.audit.over_releases)));
        audit.set("reclaim_while_encoding", Json(double(pool.audit.reclaim_while_encoding)));
        pool_json.set("audit", std::move(audit));

        // The per-session part of `persistent`: the source every tier reads
        // from and the cached negative every reprint returns. These are the
        // two holdings RFC-020 §1 names as living inside a session, and the
        // ones a frame switch is supposed to give back.
        Json session_rows = Json::array();
        size_t source_bytes = 0, negative_bytes = 0;
        size_t view_bytes = 0, suspended_bytes = 0;
        int negative_count = 0;
        for (spk_session* s : sessions) {
            size_t source = 0;
            if (gpu && s->source.buf) source = gpu->size_bytes(s->source.buf.get());
            size_t negatives = 0;
            size_t views = 0;
            int count = 0;
            for (const auto& kv : s->tiers) {
#ifndef __APPLE__
                if (gpu && kv.second.view_print.buf) views += gpu->size_bytes(kv.second.view_print.buf.get());
#endif
                if (!kv.second.has_negative || !kv.second.negative.buf || !gpu) continue;
                negatives += gpu->size_bytes(kv.second.negative.buf.get());
                ++count;
            }
            source_bytes += source;
            negative_bytes += negatives;
            view_bytes += views;
            negative_count += count;
            Json row = Json::object();
            row.set("session_id", Json(s->session_id));
            row.set("source_bytes", Json(double(source)));
            row.set("cached_negative_bytes", Json(double(negatives)));
            row.set("cached_view_bytes", Json(double(views)));
#ifndef __APPLE__
            size_t on_disk = 0;
            if (s->residency) for (const auto& plane : s->residency->planes) on_disk += plane.bytes;
            row.set("residency_suspended", Json(bool(s->residency)));
            row.set("suspended_bytes", Json(double(on_disk)));
            suspended_bytes += on_disk;
#endif
            // A session caches a negative per tier it has rendered, so this
            // is 0, 1 or 3 -- and 3 is three full planes, which is worth
            // seeing next to the byte count rather than dividing by it.
            row.set("negatives", Json(double(count)));
            session_rows.push(std::move(row));
        }

        Json persistent = Json::object();
        persistent.set("bytes", Json(double(pool.persistent_bytes)));
        persistent.set("buffers", Json(double(pool.persistent_buffers)));
        // A subset of `bytes`, not more of it: the planes whose pages live
        // in a file (RFC-020 §4.7) and are charged about a tenth as much to
        // the process's footprint. A consumer weighing the engine's holdings
        // against a footprint may want to weigh these differently.
        persistent.set("file_backed_bytes", Json(double(pool.file_backed_bytes)));
        persistent.set("file_backed_buffers", Json(double(pool.file_backed_buffers)));
        persistent.set("source_bytes", Json(double(source_bytes)));
        persistent.set("cached_negative_bytes", Json(double(negative_bytes)));
        persistent.set("cached_view_bytes", Json(double(view_bytes)));
        persistent.set("negatives", Json(double(negative_count)));
        persistent.set("sessions", std::move(session_rows));

        Json pressure = Json::object();
        pressure.set("monitor", Json(pool.pressure_monitor));
        pressure.set("warn_events", Json(double(pool.pressure_warn_events)));
        pressure.set("critical_events", Json(double(pool.pressure_critical_events)));
        // The one-shot flag, *not* taken here: `spk_render` takes it, so a
        // report cannot steal the event from the render it belongs to.
        pressure.set("critical_pending", Json(pool.pressure_critical_pending));
        // RFC-020 §3.1's idle form, next to the reactive one it complements:
        // the threshold it is armed at (0 = off) and how many times it has
        // given the pool back.
        pressure.set("idle_trim_seconds", Json(pool.idle_trim_seconds));
        pressure.set("idle_trims", Json(double(pool.idle_trims)));

        Json out = Json::object();
        out.set("total_bytes", Json(double(pool.total_bytes + pool.persistent_bytes)));
        // Temporary-file bytes, not GPU allocations and not additive to total.
        out.set("suspended_bytes", Json(double(suspended_bytes)));
        out.set("pool", std::move(pool_json));
        out.set("persistent", std::move(persistent));
        out.set("pressure", std::move(pressure));
        return out;
    }
};

namespace {

// The tier downscale: `utils/preview.resize_for_preview` on device, i.e.
// skimage's anti-aliased `resize(order=1)` with its exact parameters -- a
// separable Gaussian prefilter with sigma = max(0, (factor - 1) / 2) per axis,
// truncate 4.0, ndimage 'mirror' edges, then bilinear at (i + 0.5) * factor -
// 0.5. It is a port and not a different downscale: its output feeds the film
// simulation.
bool downscale(gpu::Gpu* gpu, const Image& src, uint32_t max_size, Image& out, std::string& error) {
    const uint32_t longest = std::max(src.h, src.w);
    if (max_size == 0 || longest <= max_size) { out = src; return true; }
    const double scale = double(max_size) / double(longest);
    const uint32_t oh = std::max(1u, uint32_t(double(src.h) * scale));
    const uint32_t ow = std::max(1u, uint32_t(double(src.w) * scale));
    const double factors[2] = {double(src.h) / double(oh), double(src.w) / double(ow)};

    Image cur = src;
    for (int axis = 0; axis < 2; ++axis) {
        const double sigma = std::max(0.0, (factors[axis] - 1.0) / 2.0);
        Vec weights;
        const size_t radius = gaussian_kernel_1d(sigma, 4.0, weights);
        if (radius == 0) continue;
        std::vector<float> table(3 * weights.size());
        for (int c = 0; c < 3; ++c)
            for (size_t i = 0; i < weights.size(); ++i)
                table[size_t(c) * weights.size() + i] = float(weights[i]);
        gpu::BufferRef w = gpu->upload(table.data(), table.size() * sizeof(float), error);
        const float ones[3] = {1.0f, 1.0f, 1.0f};
        gpu::BufferRef wt = gpu->upload(ones, sizeof ones, error);
        Image next;
        next.h = cur.h; next.w = cur.w; next.c = 3;
        next.buf = gpu->alloc(cur.bytes(), error);
        if (!w || !wt || !next.buf) return false;
        // accumulate = 1 with acc = the input and weight 1 makes the pass
        // `acc + 1 * conv`, which is not what is wanted -- so the prefilter
        // uses accumulate = 0 and runs one axis at a time.
        const uint32_t meta[6] = {cur.h, cur.w, uint32_t(radius), uint32_t(axis), 0u, 1u};
        if (!gpu->dispatch("spk_sep_fir_acc",
                           {gpu::Arg::buf(cur.buf), gpu::Arg::buf(w), gpu::Arg::buf(cur.buf),
                            gpu::Arg::buf(wt), gpu::Arg::inline_bytes(meta, 6), gpu::Arg::buf(next.buf)},
                           cur.pixels(), error)) return false;
        cur = next;
    }
    out.h = oh; out.w = ow; out.c = 3;
    out.buf = gpu->alloc(out.bytes(), error);
    if (!out.buf) return false;
    const uint32_t meta[4] = {cur.h, cur.w, oh, ow};
    return gpu->dispatch("spk_zoom_bilinear_mirror",
                         {gpu::Arg::buf(cur.buf), gpu::Arg::inline_bytes(meta, 4), gpu::Arg::buf(out.buf)},
                         out.pixels(), error);
}

}  // namespace

// ---------------------------------------------------------------------------
// the C ABI
// ---------------------------------------------------------------------------

extern "C" {

const char* spk_build_info(void) {
    // The build stamp is what a bug report quotes, so it names the three
    // things that decide whether two builds render the same picture: the
    // engine's own version, the compiler date, and the backend math probe.
#ifndef __APPLE__
    static const std::string info =
        std::string("spektrafilm-native 0.1.0 (") + __DATE__ " " __TIME__ ", math=probed)";
#else
    static const std::string info =
        std::string("spektrafilm-native 0.1.0 (") + __DATE__ " " __TIME__ ", math=safe)";
#endif
    return info.c_str();
}

const char* spk_last_error(spk_engine* engine) {
    (void)engine;
    return g_error.c_str();
}

void spk_string_free(char* s) { std::free(s); }

spk_engine* spk_engine_create(const char* resources_dir, void* device) {
    g_error.clear();
    if (!resources_dir) { g_error = "resources_dir is null"; return nullptr; }
    auto engine = std::make_unique<spk_engine>();
    engine->resources_dir = resources_dir;

    std::string error;
    if (!engine->blob.open(engine->resources_dir + "/spektrafilm_constants.bin", error)) {
        g_error = error;
        return nullptr;
    }
    if (!engine->colour.init(engine->blob, error)) { g_error = error; return nullptr; }

    const std::string filters_text = read_text_file(engine->resources_dir + "/neutral_print_filters.json");
    if (!filters_text.empty()) {
        std::string parse_error;
        if (!Json::parse(filters_text, engine->neutral_filters, parse_error)) {
            g_error = "neutral_print_filters.json: " + parse_error;
            return nullptr;
        }
    }

    if (!engine->print_luts.init(engine->resources_dir, error)) { g_error = error; return nullptr; }

#ifndef __APPLE__
    if (device) { g_error = "Windows device-buffer input is not implemented yet; pass null"; return nullptr; }
    engine->gpu = gpu::Gpu::create_vulkan(engine->resources_dir + "/vulkan", error);
#else
    engine->gpu = gpu::Gpu::create_metal(device, engine->resources_dir + "/spektrafilm.metallib", error);
#endif
    if (!engine->gpu) { g_error = error; return nullptr; }

    // RFC-014 §5.1 trap 1, checked rather than trusted. A build flag is the
    // kind of guard that stops being read; this asks the GPU what it actually
    // compiled, and refuses to start if the answer is fast math.
    std::string detail;
    if (!engine->gpu->check_math_mode(detail)) { g_error = detail; return nullptr; }
    engine->math_mode = detail;

    engine->cached_capabilities = engine->capabilities_json().dump();
    engine->cached_schema = transport_schema().dump();
    return engine.release();
}

void spk_engine_destroy(spk_engine* engine) {
    if (!engine) return;
    {
        std::lock_guard<std::mutex> guard(engine->lock);
        for (spk_session* s : engine->sessions) delete s;
        engine->sessions.clear();
    }
    delete engine;
}

const char* spk_capabilities(spk_engine* engine) {
    if (!engine) return "";
    std::lock_guard<std::mutex> guard(engine->lock);
    // Recomputed rather than served from the cache, because the session count
    // it reports changes -- the status bar reads it to tell "switching frames
    // is slow" from "the cache evicts on every switch".
    engine->cached_capabilities = engine->capabilities_json().dump();
    return engine->cached_capabilities.c_str();
}

const char* spk_params_schema(spk_engine* engine) {
    return engine ? engine->cached_schema.c_str() : "";
}

const char* spk_memory_report(spk_engine* engine) {
    if (!engine) return "";
    // The same lifetime as `spk_capabilities`, and for the same reason: the
    // numbers move, so a cached string would be a report about a moment the
    // caller did not ask about.
    std::lock_guard<std::mutex> guard(engine->lock);
    engine->cached_memory_report = engine->memory_report_json().dump();
    return engine->cached_memory_report.c_str();
}

spk_status spk_warm_up(spk_engine* engine, const char* film_stock, const char* print_stock,
                       char** out_json) {
    if (!engine) { g_error = "engine is null"; return SPK_ERR_INVALID_ARG; }
    g_error.clear();
    const auto started = std::chrono::steady_clock::now();

    // RFC-013 §3: pay the fixed per-stock-pair setup while the boot window is
    // up. On this engine there is no interpreter to hide, so what is left is
    // the real work -- the tc_lut contraction and the 46,080-cell C_max
    // bisection -- and it is the same work `open` would otherwise do on the
    // frame the user is waiting for.
    Json steps = Json::array();
    auto step = [&](const char* name, bool ok, double ms, const std::string& detail) {
        Json entry = Json::object();
        entry.set("name", Json(std::string(name)));
        entry.set("ok", Json(ok));
        entry.set("ms", Json(std::round(ms * 100.0) / 100.0));
        if (!detail.empty()) entry.set("error", Json(detail));
        steps.push(std::move(entry));
    };

    const std::string film = film_stock && *film_stock ? film_stock : "kodak_portra_400";
    const std::string print = print_stock && *print_stock ? print_stock : "kodak_portra_endura";

    Params params;
    std::string error;
    auto t0 = std::chrono::steady_clock::now();
    bool ok = init_params(engine->resources_dir, film, print, engine->neutral_filters, params, error);
    step("profiles", ok, std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - t0).count(), ok ? "" : error);

    if (ok) {
        params.settings.working_precision = "float32";
        t0 = std::chrono::steady_clock::now();
        Pipeline pipeline(engine->gpu, &engine->colour, &engine->blob, &engine->setup_cache);
        const bool built = pipeline.build(params, error);
        step("pipeline", built, std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count(), built ? "" : error);
        ok = built;

        if (built) {
            // Run a small frame all the way through, so every kernel's
            // The compute pipeline exists before the user's first frame
            // needs it.
            //
            // Measured, because the obvious claim for this is wrong: it does
            // *not* take 300 ms off the first reprint. Over seven runs the
            // median first reprint is 83 ms cold and 80 ms warmed. What it
            // removes is the tail -- worst case 160 ms cold against 86 ms
            // warmed -- because a pipeline state built on first use lands on
            // the frame the user is waiting for rather than on the boot
            // window. Worth 4 ms of warm-up for that alone; not worth
            // claiming more than it does.
            t0 = std::chrono::steady_clock::now();
            engine->gpu->begin_frame();
            std::string warm_error;
            // A small frame, but told it came from a *live-tier* one. The two
            // are decoupled on purpose: every blur's sigma is in micrometres
            // divided by the pixel pitch, so a 32 px frame that really was
            // 32 px has a pitch of 1093 um and every blur collapses to a
            // no-op -- warming nothing, in 3.7 ms. At the live tier's pitch
            // the halation and DIR-coupler tails cross into the IIR kernel,
            // which is the one a real frame actually pays for.
            constexpr uint32_t kEdge = 64;
            constexpr uint32_t kLiveLongEdge = 1600;
            std::vector<float> pixels(size_t(kEdge) * kEdge * 3, 0.18f);
            Image seed;
            seed.h = kEdge;
            seed.w = kEdge;
            seed.c = 3;
            seed.buf = engine->gpu->upload(pixels.data(), pixels.size() * sizeof(float), warm_error);
            bool warmed = static_cast<bool>(seed.buf);
            Image negative, rgb;
            if (warmed) {
                pipeline.set_source_long_edge(kLiveLongEdge, kLiveLongEdge);
                warmed = pipeline.run_film(seed, negative, nullptr, warm_error) &&
                         pipeline.run_print(negative, rgb, nullptr, warm_error) &&
                         engine->gpu->flush(warm_error);
            }
            engine->gpu->end_frame();
            step("kernels", warmed, std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count(), warmed ? "" : warm_error);
        }
    }

    Json out = Json::object();
    out.set("film_stock", Json(film));
    out.set("print_stock", Json(print));
    out.set("already_warm", Json(false));
    out.set("render_core", Json(std::string(kRenderCore)));
    out.set("total_ms", Json(std::round(std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count() * 100.0) / 100.0));
    out.set("steps", std::move(steps));
    if (out_json) *out_json = dup_json(out);
    // A warm-up step that fails is not fatal: the work is simply paid again
    // inside `open`, and the boot window reports it.
    return SPK_OK;
}

namespace {

// Where `open`'s pixels are: a host array (`spk_open`) or a buffer already on
// the device (`spk_open_device`). Exactly one of the two pointers is set.
struct FrameIn {
    const float* host = nullptr;
    void* device = nullptr;
    uint32_t width = 0, height = 0, channels = 0;
};

// Everything the two entry points share. They differ only in how the frame
// reaches the device, and that is one branch below -- not two copies of the
// params and pipeline setup that could drift apart, which is the shape of
// the `spk_render`/`spk_reprint` bug the session harness now pins.
spk_session* open_frame(spk_engine* engine, const FrameIn& frame, const char* params_delta_json,
                        char** out_json) {
    g_error.clear();
    if (frame.channels != 3 && frame.channels != 4) {
        g_error = "input image must have 3 or 4 channels";
        return nullptr;
    }
    if (frame.width == 0 || frame.height == 0) { g_error = "input image is empty"; return nullptr; }
    const uint64_t pixels = uint64_t(frame.width) * uint64_t(frame.height);
    if (pixels > kMaxFramePixels) {
        g_error = "frame is too large: " + std::to_string(pixels) + " px (" +
                  std::to_string(frame.width) + " x " + std::to_string(frame.height) +
                  "), above this build's limit of " + std::to_string(kMaxFramePixels) +
                  " px — the largest frame it renders is a Phase One IQ4 150 (14204 x 10652)";
        return nullptr;
    }
    // And the long edge against the device's own texture limit. The pixel cap
    // above does not imply this one: a 20000 x 7000 panorama is 140 MP and
    // would still be a texture the GPU cannot make, so the frame would render
    // and then have nowhere to be drawn.
    const uint32_t max_edge = engine->gpu ? engine->gpu->max_texture_dimension_2d() : 0;
    const uint32_t long_edge = std::max(frame.width, frame.height);
    if (max_edge && long_edge > max_edge) {
        g_error = "frame is too large for this GPU: its " + std::to_string(long_edge) +
                  " px long edge is above the device's " + std::to_string(max_edge) +
                  " px texture limit";
        return nullptr;
    }

    // RFC-020 §3.1: the frame switch, which is one of the only two occasions
    // the pool gives anything back.
    //
    // A pooled buffer is a plane of *some* frame's render, and the pool has no
    // way to know which; the engine does, so the decision is here and the
    // mechanism is `Gpu::trim_pool`. Either the engine has no session open at
    // all -- so nothing anyone is looking at could be using those buffers --
    // or the frame being opened is a different size from the one they were
    // made for. A 102 MP pool has no business surviving into a 24 MP frame,
    // and §1.2 measured the price of the re-fault as small: what is expensive
    // is not faulting pages back in, it is crossing into the compressor.
    //
    // Deliberately **not** at `end_frame`. Within a session the same sizes
    // come back immediately and the pool is exactly the right structure to
    // hold them; the change is that "keep it" stops meaning "keep it forever".
    {
        bool trim = false;
        {
            std::lock_guard<std::mutex> guard(engine->lock);
            const bool previous_session_gone = engine->pool_frame_valid && engine->sessions.empty();
            const bool frame_changed = !engine->pool_frame_valid ||
                                       engine->pool_frame_w != frame.width ||
                                       engine->pool_frame_h != frame.height;
            trim = previous_session_gone || frame_changed;
            engine->pool_frame_valid = true;
            engine->pool_frame_w = frame.width;
            engine->pool_frame_h = frame.height;
        }
        // Outside the lock: this releases GPU buffers, which is not work to
        // hold the session list across.
        if (trim && engine->gpu) engine->gpu->trim_pool(0);
    }

    Json delta = Json::object();
    bool product_defaults = false;
    if (params_delta_json && *params_delta_json) {
        std::string parse_error;
        if (!Json::parse(params_delta_json, delta, parse_error)) {
            g_error = "params_delta: " + parse_error;
            return nullptr;
        }
        // Taken out before validation, because it is not a render parameter
        // and must not become one: it selects a *set of defaults*, it has no
        // schema row, no layer and no range, and `params_schema` stays the 41
        // fields the wire has always had (which is what `parity_schema`
        // checks, field for field, against the Python oracle).
        if (delta.has(kProductDefaultsKey)) {
            const Json& value = delta.at(kProductDefaultsKey);
            if (!value.is_bool()) {
                g_error = std::string(kProductDefaultsKey) + " must be a boolean";
                return nullptr;
            }
            product_defaults = value.as_bool();
            Json rest = Json::object();
            for (const auto& kv : delta.fields())
                if (kv.first != kProductDefaultsKey) rest.set(kv.first, kv.second);
            delta = std::move(rest);
        }
        std::string message, param;
        if (!validate_delta(delta, message, param)) { g_error = message; return nullptr; }
    }

    auto session = std::make_unique<spk_session>();
    session->engine = engine;
    session->session_id = "s" + std::to_string(next_id());

    std::string film = "kodak_portra_400", print = "kodak_portra_endura";
    if (delta.has("film_stock")) film = delta.at("film_stock").as_string();
    if (delta.has("print_stock")) print = delta.at("print_stock").as_string();

    std::string error;
    if (!init_params(engine->resources_dir, film, print, engine->neutral_filters,
                     session->params, error)) { g_error = error; return nullptr; }
    session->product_defaults = product_defaults;
    // The project convention, applied before the delta so an explicit
    // `output_color_space` still wins: ProPhoto RGB in, **ProPhoto RGB out**.
    //
    // RFC-018 §5.1. The render's output is the *working space*, not a display
    // space: the app grades in it and converts once, per destination, in its
    // own output transform. Naming a display space here was the narrowest
    // space coming first, and it is why every grading move used to be clipped
    // at Display P3's cube face before the user ever saw it.
    //
    // A caller that overrides `output_color_space` owns the consequences: the
    // app's transform reads the session's *resolved* space out of this reply's
    // `params.io` and converts from whatever it finds there.
    session->params.io.output_color_space = "ProPhoto RGB";
    session->params.io.output_cctf_encoding = true;
    apply_delta(session->params, delta);
    // After the delta, and in the same order as the stock rebuild in
    // `spk_set_params`, so the two cannot disagree about precedence. Nothing
    // in a delta can reach this field today — it has no schema row — but
    // "the product defaults win" is the rule, and it should be the rule in
    // both places rather than an accident of ordering in one.
    apply_product_defaults(session->params, session->product_defaults);
    session->params.settings.working_precision = "float32";
    if (!digest(session->params, engine->neutral_filters, error)) { g_error = error; return nullptr; }

    // Uploaded as handed over, alpha and all; `spk_take_rgb` drops the fourth
    // channel on device below. Stripping it on the host would be a full-frame
    // CPU pass -- 543 MB of loads and stores at 45 MP.
    //
    // A device frame always goes through `spk_take_rgb`, even at three
    // channels: the kernel is the copy, and the caller's buffer is only
    // borrowed for this call, so the session must not keep it as its source.
    {
        engine->gpu->begin_frame();
        Image uploaded;
        uploaded.h = frame.height;
        uploaded.w = frame.width;
        uploaded.c = frame.channels;
        const size_t bytes = uploaded.elements() * sizeof(float);
        std::string upload_error;
        if (frame.host && frame.channels == 3) {
            // RFC-020 §4.7: the session's source, in a file rather than in
            // this process's ledger -- 1.362 GB of `phys_footprint` against
            // 0.137 for the same 1.22 GB plane, measured. See
            // `alloc_file_backed`.
            uploaded.buf = engine->gpu->upload_file_backed(frame.host, bytes, upload_error);
            session->source = uploaded;
        } else {
            // The host copy is the 235 ms `spk_open_device` exists to avoid
            // (727 MB at 45 MP); the borrow is no copy at all.
            uploaded.buf = frame.host ? engine->gpu->upload(frame.host, bytes, upload_error)
                                      : engine->gpu->borrow(frame.device, bytes, upload_error);
            Image rgb;
            rgb.h = uploaded.h;
            rgb.w = uploaded.w;
            rgb.c = 3;
            // Written by `spk_take_rgb` below rather than by the host, and
            // file-backed for the same reason as the branch above: it is
            // `session->source`.
            if (uploaded.buf) rgb.buf = engine->gpu->alloc_file_backed(rgb.bytes(), upload_error);
            const uint32_t meta[2] = {uint32_t(uploaded.pixels()), uploaded.c};
            if (!uploaded.buf || !rgb.buf ||
                !engine->gpu->dispatch("spk_take_rgb",
                                       {gpu::Arg::buf(uploaded.buf), gpu::Arg::inline_bytes(meta, 2),
                                        gpu::Arg::buf(rgb.buf)},
                                       uploaded.pixels(), upload_error) ||
                !engine->gpu->flush(upload_error)) {
                engine->gpu->end_frame();
                g_error = upload_error;
                return nullptr;
            }
            session->source = rgb;
        }
        engine->gpu->end_frame();
        if (!session->source.buf) { g_error = upload_error; return nullptr; }
    }

    session->pipeline = std::make_unique<Pipeline>(engine->gpu, &engine->colour, &engine->blob,
                                                  &engine->setup_cache);
    if (!session->pipeline->build(session->params, error)) { g_error = error; return nullptr; }

    Json meta = Json::object();
    meta.set("width", Json(double(frame.width)));
    meta.set("height", Json(double(frame.height)));
    meta.set("megapixels", Json(std::round(double(frame.width) * double(frame.height) / 1e4) / 100.0));
    meta.set("source", Json(std::string("<in-process>")));

    // `detected_input` is the service's file sniffing, and the engine no
    // longer opens files: the caller decoded the frame and knows its encoding,
    // so it reports what it passed in. Kept in the reply because the frontend
    // reads it (contract §2's additive fields).
    Json detected = Json::object();
    detected.set("input_color_space", Json(session->params.io.input_color_space));
    detected.set("input_cctf_decoding", Json(session->params.io.input_cctf_decoding));
    detected.set("input_color_space_source", Json(std::string("caller")));

    Json out = Json::object();
    out.set("session_id", Json(session->session_id));
    out.set("meta", std::move(meta));
    out.set("detected_input", std::move(detected));
    out.set("params", read_params(session->params));
    out.set("capabilities", engine->capabilities_json());
    if (out_json) *out_json = dup_json(out);

    spk_session* raw = session.release();
    {
        std::lock_guard<std::mutex> guard(engine->lock);
        engine->sessions.push_back(raw);
    }
    return raw;
}

}  // namespace

spk_session* spk_open(spk_engine* engine, const spk_image* input, const char* params_delta_json,
                      char** out_json) {
    if (!engine || !input || !input->data) { g_error = "engine or image is null"; return nullptr; }
    FrameIn frame;
    frame.host = input->data;
    frame.width = input->width;
    frame.height = input->height;
    frame.channels = input->channels;
    return open_frame(engine, frame, params_delta_json, out_json);
}

spk_session* spk_open_device(spk_engine* engine, const spk_device_image* input,
                             const char* params_delta_json, char** out_json) {
    if (!engine || !input || !input->buffer) { g_error = "engine or buffer is null"; return nullptr; }
    FrameIn frame;
    frame.device = input->buffer;
    frame.width = input->width;
    frame.height = input->height;
    frame.channels = input->channels;
    return open_frame(engine, frame, params_delta_json, out_json);
}

namespace {

// The source at a tier's resolution, built on first use. `open` needs the live
// tier and nothing else; the preview tier is needed only if the user zooms
// past 100 %, and building both eagerly put two full-resolution anti-aliased
// downscales of a 45 MP frame inside every open.
bool tier_image(spk_session* session, const Tier& tier, Image& out, std::string& error) {
    const uint32_t edge = tier_long_edge(session->params, tier);
    spk_session::TierState& state = session->tiers[tier.name];
    if (state.image.valid() && state.image_long_edge == edge) { out = state.image; return true; }
    gpu::Gpu* gpu = session->engine->gpu;
    // Already on the device, three channels, from `spk_open`.
    const Image& full = session->source;
    Image scaled;
    if (!downscale(gpu, full, edge, scaled, error)) return false;
    if (scaled.buf.get() == full.buf.get()) {
        // At or below the tier: share the source itself. It is already
        // persistent, and another copy of a 45 MP frame is 543 MB.
        state.image = full;
    } else {
        // The downscale ran in the frame arena; copy the result into a
        // persistent buffer, because a tier image outlives the render that
        // built it and every subsequent render reads it.
        if (!gpu->flush(error)) return false;
        Image kept;
        kept.h = scaled.h; kept.w = scaled.w; kept.c = 3;
        kept.buf = gpu->alloc_persistent(scaled.bytes(), error);
        if (!kept.buf || !gpu->copy(kept.buf.get(), 0, scaled.buf.get(), 0,
                                    scaled.bytes(), error)) return false;
        state.image = kept;
    }
    state.image_long_edge = edge;
    out = state.image;
    return true;
}

// `static`, because this sits inside the `extern "C"` block with the entry
// points and a C-linkage function returning a `std::string` is a warning (and
// nothing outside this file calls it).
static std::string meter_key(const Params& params) {
    const Json values = read_params(params);
    std::string key;
    for (const char* name : kMeterKeyFields) key += values.at(name).dump() + ";";
    return key;
}

// The frame at the meter's own resolution: what the meter reads, and what
// Scene Latitude's scene statistic reads (RFC-023 §9.1 -- the same sample, so
// its `E = 0` is the meter's).
bool meter_frame(spk_session* session, Image& small, std::string& error) {
    // Reusing the live tier's image is free only while that tier happens to be
    // the meter's own size. With the preview resolution settable that is a
    // runtime question rather than a constant one, so off 1600 this costs one
    // extra downscale of the frame -- once per frame, not once per edit, and
    // `meter_key` already stops it re-firing for a film, exposure or method
    // change. See the note in `params.hpp`: the meter must not follow the
    // preview size, which is the whole reason it has its own constant.
    return tier_long_edge(session->params, kTiers[0]) == kMeterLongEdge
        ? tier_image(session, kTiers[0], small, error)
        : downscale(session->engine->gpu, session->source, kMeterLongEdge, small, error);
}

// The session's meter, computed on demand -- whichever render or solve needs
// it first -- and kept until an upstream field changes. Needs an open frame.
bool ensure_meter(spk_session* session, std::string& error) {
    const std::string key = meter_key(session->params);
    if (session->meter.valid && session->meter.key == key) return true;
    Image small;
    ExposureEvs evs;
    if (!meter_frame(session, small, error) ||
        !session->pipeline->measure_meter_evs(small, evs, error)) return false;
    session->meter.valid = true;
    session->meter.key = key;
    session->meter.evs = evs;
    return true;
}

// RFC-020 §4: which execution path a session is on. A *different entry point*
// rather than a flag inside the single-pass one (P3) -- the un-striped path
// stays exactly what ships, which is what makes §6's hash comparison mean
// anything -- and one call site each, so the graph cannot drift between them.
// Opt-in observation only: these plane multipliers are hypotheses calibrated
// on the Windows 102 MP fixture, not admission limits or memory guarantees.
// Frame high-water is cumulative; never label it a stage-local peak.
struct MemoryEstimateTrace {
    static constexpr unsigned kObserveOnly = 99;
    spk_session* session;
    const char* stage;
    const char* cache;
    const Image& image;
    unsigned planes;
    bool enabled = false;
    bool success = false;
    uint64_t observation = 0;
    size_t output_payload_bytes = 0;
    gpu::PoolStats before{};
    MemoryEstimateTrace(spk_session* s, const char* label, const char* hit,
                        const Image& input, unsigned count) noexcept
        : session(s), stage(label), cache(hit), image(input), planes(count) {
        const char* flag = std::getenv("SPEKTRAFILM_MEMORY_ESTIMATE");
        enabled = flag && std::strcmp(flag, "1") == 0;
        if (!enabled) return;
        try { before = session->engine->gpu->pool_stats(); emit("begin");
              observation = session->engine->gpu->begin_memory_observation(); }
        catch (...) { enabled = false; }
    }
    ~MemoryEstimateTrace() noexcept {
        if (enabled) { try {
            if (observation) measured = session->engine->gpu->end_memory_observation(observation);
            emit("end");
        } catch (...) {} }
    }
    gpu::Gpu::MemoryObservation measured{};
    void emit(const char* event) {
        const auto now = session->engine->gpu->pool_stats();
        const auto& p = session->params;
        Json j = Json::object();
        j.set("event", Json(std::string(event)));
        j.set("stage", Json(std::string(stage)));
        j.set("cache", Json(std::string(cache)));
        j.set("model", Json(std::string("empirical-planes-v2-observe-only")));
        j.set("width", Json(double(image.w))); j.set("height", Json(double(image.h)));
        const double plane = double(image.w) * double(image.h) * 3.0 * sizeof(float);
        const bool supported = planes == 0 ||
            (planes != kObserveOnly && std::strcmp(kRenderCore, "native-vulkan") == 0 &&
             !p.settings.striped && !p.film_render.overscan.active);
        j.set("estimate_available", Json(supported));
        if (supported) {
            const double scratch = plane * planes;
            j.set("estimated_additional_live_bytes", Json(scratch));
            j.set("estimated_pool_live_peak_bytes", Json(double(before.live_bytes) + scratch));
            j.set("estimated_new_allocation_bytes", Json(std::max(0.0, scratch - double(before.free_bytes))));
        }
        j.set("grain", Json(p.film_render.grain.active));
        j.set("halation", Json(p.film_render.halation.active));
        j.set("glare", Json(p.print_render.glare.active));
        j.set("striped", Json(p.settings.striped));
        j.set("overscan", Json(p.film_render.overscan.active));
        j.set("pool_live_bytes", Json(double(now.live_bytes)));
        j.set("pool_free_bytes", Json(double(now.free_bytes)));
        j.set("persistent_bytes", Json(double(now.persistent_bytes)));
        j.set("observed_frame_high_water_bytes", Json(double(now.frame_high_water_bytes)));
        j.set("frame_high_water_before_bytes", Json(double(before.frame_high_water_bytes)));
        if (std::strcmp(event, "end") == 0) {
            j.set("success", Json(success));
            if (planes == kObserveOnly) j.set("output_payload_bytes", Json(double(output_payload_bytes)));
            j.set("stage_peak_available", Json(observation != 0));
            if (observation) {
                j.set("observed_stage_live_peak_bytes", Json(double(measured.live_peak)));
                j.set("observed_stage_requested_live_peak_bytes", Json(double(measured.requested_live_peak)));
                j.set("requested_bytes_at_capacity_peak", Json(double(measured.requested_at_live_peak)));
                j.set("observed_stage_resident_peak_bytes", Json(double(measured.resident_peak)));
            }
        }
#ifdef _WIN32
        MEMORYSTATUSEX status{}; status.dwLength = sizeof(status);
        if (GlobalMemoryStatusEx(&status)) {
            j.set("system_commit_available_bytes", Json(double(status.ullAvailPageFile)));
            j.set("system_physical_available_bytes", Json(double(status.ullAvailPhys)));
        }
#endif
        // Staging, driver memory, readback and file encoding are not covered.
        std::fprintf(stderr, "memory_estimate %s\n", j.dump().c_str());
    }
};

bool run_film_for(spk_session* session, const Image& source, Image& negative,
                  Progress* progress, std::string& error) {
    MemoryEstimateTrace trace(session, "film", "miss", source, 5);
    if (session->params.settings.striped) {
        return trace.success = session->pipeline->run_film_striped(source, negative, progress, error);
    }
    return trace.success = session->pipeline->run_film(source, negative, progress, error);
}

bool run_print_for(spk_session* session, const Image& negative, Image& rgb,
                   Progress* progress, std::string& error) {
    // Conservative cross-size model: IIR glare can still need four RGB planes;
    // consuming the default FIR field lowers that path to three. Pool
    // oversizing and small-frame fixed costs remain outside this model.
    MemoryEstimateTrace trace(session, "print", "miss", negative,
                              session->params.print_render.glare.active ? 4 : 3);
    if (session->params.settings.striped) {
        return trace.success = session->pipeline->run_print_striped(negative, rgb, progress, error);
    }
    return trace.success = session->pipeline->run_print(negative, rgb, progress, error);
}

bool negative_for(spk_session* session, const Tier& tier, Progress* progress, Image& out,
                  std::string& error) {
    spk_session::TierState& state = session->tiers[tier.name];
    if (state.has_negative) {
        MemoryEstimateTrace trace(session, "film", "hit", state.negative, 0);
        trace.success = true;
        if (progress) progress->auto_exposure_ev = state.applied_ev;
        out = state.negative;
        return true;
    }
    Image source;
    if (!tier_image(session, tier, source, error)) return false;
    // Every tier's node applies the frame's one EV (RFC-015 P.1).
    if (!ensure_meter(session, error)) return false;
    const CameraParams& camera = session->params.camera;
    session->pipeline->set_auto_exposure_ev(
        camera.auto_exposure ? std::optional<double>(session->meter.evs.of(camera.auto_exposure_method))
                             : std::nullopt);
    Image negative;
    if (!run_film_for(session, source, negative, progress, error)) return false;
    state.applied_ev = session->pipeline->last_auto_exposure_ev();
    session->pipeline->overscan_frame(state.overscan_frame_w, state.overscan_frame_h);
    if (progress) progress->auto_exposure_ev = state.applied_ev;
    // The negative is what every subsequent slider drag reprints from, so it
    // has to outlive the frame arena. Keeping it also makes a reprint
    // grain-consistent for free: the realisation is baked in and is
    // never redrawn.
    gpu::Gpu* gpu = session->engine->gpu;
    if (!gpu->flush(error)) return false;
    Image kept;
    kept.h = negative.h; kept.w = negative.w; kept.c = 3;
    // The cached negative is the other holding RFC-020 §4.7 names: every
    // reprint reads it, it lives as long as the session, and at the full
    // tier it is the second 1.22 GB plane.
    if (gpu->try_promote_persistent(negative.buf.get(), negative.bytes())) {
        // Vulkan can keep this exclusive, exact-size result without a second
        // plane. Other backends retain their file-backed copy semantics.
        kept = std::move(negative);
    } else {
        kept.buf = gpu->alloc_file_backed(negative.bytes(), error);
        if (!kept.buf || !gpu->copy(kept.buf.get(), 0, negative.buf.get(), 0,
                                    negative.bytes(), error)) return false;
    }
    state.negative = std::move(kept);
    state.has_negative = true;
    out = state.negative;
    return true;
}

// The rgba16 result: a fresh buffer with texture-aligned rows, a texture over
// it, and the only reference handed to the caller. RFC-014 §2.2's zero copy,
// and the deletion of `_write_rgba16` -- 10 ms of a 30.6 ms reprint, and a
// 364 MB file at the full tier.
//
// A *fresh* buffer, not a pooled one, and not one kept per tier. The frontend
// keeps the last eight frames' live textures resident so switching frames is
// instant; a buffer the engine reused on the next render of the same tier
// would turn those cached textures into a different photograph without
// anything changing hands. So each render allocates, and the texture's own
// reference to the buffer is what keeps the pixels alive for exactly as long
// as the caller is looking at them.
bool materialise(spk_session* session, const Image& rgb, spk_result* out, std::string& error) {
    gpu::Gpu* gpu = session->engine->gpu;
    // LUT previews and normalized DI also arrive here without run_print.
    // Bound their idle scratch before allocating the persistent packed result.
    if (!gpu->trim_idle_for_phase(rgb.bytes(), rgb.bytes(), error)) return false;
    const uint32_t align = gpu->texture_row_alignment_px();
    const uint32_t stride = ((rgb.w + align - 1) / align) * align;
    const size_t bytes = size_t(stride) * rgb.h * 4 * sizeof(uint16_t);
    gpu::BufferRef buffer = gpu->alloc_persistent(bytes, error);
    if (!buffer) return false;

    const uint32_t meta[3] = {uint32_t(rgb.pixels()), rgb.w, stride};
    bool ok = gpu->dispatch("spk_to_rgba16",
                            {gpu::Arg::buf(rgb.buf), gpu::Arg::inline_bytes(meta, 3),
                             gpu::Arg::buf(buffer)},
                            rgb.pixels(), error) && gpu->flush(error);
    if (ok) {
        out->width = rgb.w;
        out->height = rgb.h;
        out->row_stride_px = stride;
        out->texture = gpu->texture(buffer.get(), rgb.w, rgb.h, stride, error);
        ok = out->texture != nullptr;
#ifndef __APPLE__
        // The headless Vulkan result owns a separate CPU copy. The dispatch
        // buffer is released when this function returns.
        if (ok) out->rgba16 = static_cast<const uint16_t*>(out->texture);
#else
        // Metal textures retain shared storage; this view stays valid for
        // exactly the texture's lifetime without a host readback.
        if (ok) out->rgba16 = static_cast<const uint16_t*>(gpu->contents(buffer.get()));
#endif
    }
    // Drop the engine's reference either way. On success the texture still
    // holds one, so the buffer lives; on failure it dies here.
    return ok;
}

spk_status render_tier(spk_session* session, const char* tier_name, bool use_reprint,
                       spk_result* out) {
    if (!session || !out) { g_error = "session or result is null"; return SPK_ERR_INVALID_ARG; }
    const Tier* tier = find_tier(tier_name);
    if (!tier) {
        g_error = std::string("unknown tier '") + (tier_name ? tier_name : "(null)") +
                  "'; expected live, preview or full";
        return SPK_ERR_INVALID_ARG;
    }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    std::memset(out, 0, sizeof *out);

    gpu::Gpu* gpu = session->engine->gpu;
    const auto started = std::chrono::steady_clock::now();
    session->progress = Progress{};
    session->progress.progress_id = "p" + std::to_string(next_id());
    // Opt-in, because turning it on serialises every node. See Progress.
    session->progress.detailed = std::getenv("SPEKTRAFILM_NODE_TIMINGS") != nullptr;

#ifndef __APPLE__
    // A legacy explicit render requests a new print, so no later desktop
    // view may reuse the result from before that request.
    session->tiers[tier->name].view_print = Image{};
#endif

    gpu->begin_frame();
    // RFC-020 §3.2, after the frame marker so that an event arriving as this
    // render starts belongs to it. One-shot: the flag describes *this* render,
    // not a state every later one also inherits.
    session->progress.memory_pressure_critical = gpu->take_critical_pressure();
    std::string error;
    const bool had_negative = session->tiers[tier->name].has_negative;
    if (!use_reprint && had_negative) {
        // `spk_render` is the `preview_render(layer: "shoot")` path: it exists
        // to force the film side to run. Without this it returned the cached
        // negative and was identical to `spk_reprint` in everything but the
        // flag it reported -- which happened to look right, because a
        // shoot-layer `set_params` drops the negative before this is reached.
        session->tiers[tier->name].negative = Image{};
        session->tiers[tier->name].has_negative = false;
    }
    Image negative, rgb;
    // Before anything runs, and from the tier image rather than from whatever
    // the pipeline last saw: a print-layer rebuild hands us a fresh pipeline
    // that has never rendered a frame, and the negative it is about to reprint
    // may be one the *previous* pipeline made.
    Image tier_source;
    bool ok = tier_image(session, *tier, tier_source, error);
    if (ok) session->pipeline->set_source_shape(tier_source.w, tier_source.h, session->source.w, session->source.h);
    if (ok) ok = negative_for(session, *tier, &session->progress, negative, error);
    // After the negative, which a film run lays out for itself: this is for
    // the cached one, whose layout the pipeline may never have made (a
    // print-layer rebuild) or may have replaced with another tier's.
    if (ok) {
        const spk_session::TierState& state = session->tiers[tier->name];
        ok = session->pipeline->set_overscan_frame(state.overscan_frame_w, state.overscan_frame_h, error);
    }
    if (ok) ok = run_print_for(session, negative, rgb, &session->progress, error);
    if (ok) ok = materialise(session, rgb, out, error);
    gpu->end_frame();

    if (!ok) {
        g_error = error;
        return error == "render cancelled" ? SPK_ERR_CANCELLED : SPK_ERR_GPU;
    }
    out->elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out->reprint = use_reprint && had_negative ? 1 : 0;
    out->negative_was_cached = use_reprint && had_negative ? 1 : 0;
    std::snprintf(out->progress_id, sizeof out->progress_id, "%s",
                  session->progress.progress_id.c_str());
    session->progress.done = true;
    return SPK_OK;
}

}  // namespace

spk_status spk_reprint(spk_session* session, const char* tier, spk_result* out) {
    return render_tier(session, tier, /*use_reprint=*/true, out);
}

spk_status spk_render(spk_session* session, const char* tier, spk_result* out) {
    return render_tier(session, tier, /*use_reprint=*/false, out);
}

}  // extern "C"

#ifndef __APPLE__
namespace {
constexpr size_t kResidencyChunkBytes = 8u * 1024u * 1024u;

std::FILE* residency_file(std::string& error) {
#if defined(_WIN32)
    // CRT tmpfile() can choose the drive root on Windows. Use the user's
    // Unicode temp directory and an exclusive, kernel-delete-on-close file.
    std::vector<wchar_t> temp(32768);
    const DWORD n = GetTempPathW(DWORD(temp.size()), temp.data());
    if (!n || n >= temp.size()) {
        error = "residency: cannot locate temporary directory"; return nullptr;
    }
    static std::atomic<uint64_t> serial{0};
    for (unsigned attempt = 0; attempt < 32; ++attempt) {
        const auto name = std::wstring(temp.data(), n) + L"spektralab-residency-" +
            std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()) +
            L"-" + std::to_wstring(++serial) + L".tmp";
        HANDLE handle = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE | DELETE,
            FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, CREATE_NEW,
            FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (handle == INVALID_HANDLE_VALUE) {
            const auto code = GetLastError();
            if (code == ERROR_FILE_EXISTS || code == ERROR_ALREADY_EXISTS) continue;
            error = "residency: cannot create temporary file (Windows " + std::to_string(code) + ")";
            return nullptr;
        }
        const int fd = _open_osfhandle(reinterpret_cast<intptr_t>(handle), _O_RDWR | _O_BINARY);
        if (fd < 0) { CloseHandle(handle); error = "residency: cannot open temporary stream"; return nullptr; }
        auto* file = _fdopen(fd, "w+b");
        if (!file) { _close(fd); error = "residency: cannot wrap temporary stream"; }
        return file;
    }
    error = "residency: cannot create a unique temporary file"; return nullptr;
#else
    auto* file = std::tmpfile();
    if (!file) error = "residency: cannot create temporary file: " + std::string(std::strerror(errno));
    return file;
#endif
}

// Explicit test-only fault injection exercises rollback after allocation and
// I/O, rather than merely failing to open a file. Never enabled by app settings.
bool residency_fault(const char* point) {
    const char* value = std::getenv("SPK_TEST_RESIDENCY_FAILURE");
    return value && std::strcmp(value, point) == 0;
}
}

bool spk::view::suspended(spk_session* session) {
    if (!session) return false;
    std::lock_guard<std::mutex> guard(session->lock);
    return bool(session->residency);
}

bool spk::view::suspend(spk_session* session, std::string& error) {
    if (!session) { error = "residency: session is null"; return false; }
    std::lock_guard<std::mutex> guard(session->lock);
    if (session->residency) return true;
    try {
        using Snapshot = spk_session::ResidencySnapshot;
        auto snapshot = std::make_unique<Snapshot>();
        auto* gpu = session->engine->gpu;
        if (!gpu->flush(error)) return false;
        std::vector<gpu::Buffer*> buffers;
        std::unordered_map<gpu::Buffer*, size_t> indices;
        const auto capture = [&](const Image& image) {
            Snapshot::Slot slot; slot.h = image.h; slot.w = image.w; slot.c = image.c;
            if (image.buf) {
                auto [it, added] = indices.emplace(image.buf.get(), buffers.size());
                slot.plane = it->second;
                if (added) {
                    buffers.push_back(image.buf.get());
                    snapshot->planes.push_back({gpu->size_bytes(image.buf.get())});
                }
            }
            return slot;
        };
        snapshot->source = capture(session->source);
        for (const auto& [name, tier] : session->tiers)
            snapshot->tiers.emplace(name, Snapshot::TierSlots{
                capture(tier.image), capture(tier.negative), capture(tier.view_print)});
        snapshot->file.reset(residency_file(error));
        if (!snapshot->file) return false;
        std::vector<uint8_t> chunk(kResidencyChunkBytes);
        bool wrote = false;
        for (size_t p = 0; p < buffers.size(); ++p) {
            const size_t size = snapshot->planes[p].bytes;
            for (size_t offset = 0; offset < size;) {
                const size_t n = std::min(chunk.size(), size - offset);
                if (!gpu->read(buffers[p], offset, chunk.data(), n, error)) return false;
                if ((wrote && residency_fault("write")) ||
                    std::fwrite(chunk.data(), 1, n, snapshot->file.get()) != n) {
                    error = "residency: failed to write temporary image; GPU data retained"; return false;
                }
                wrote = true; offset += n;
            }
        }
        if (std::fflush(snapshot->file.get()) != 0) {
            error = "residency: failed to flush temporary image; GPU data retained"; return false;
        }
        // The complete disk snapshot is recoverable before any original
        // handle is dropped. Shapes, cache flags and pipeline state survive.
        session->source.buf.reset();
        for (auto& [name, tier] : session->tiers) {
            tier.image.buf.reset(); tier.negative.buf.reset(); tier.view_print.buf.reset();
        }
        session->residency = std::move(snapshot);
        return true;
    } catch (const std::exception& e) {
        error = std::string("residency: suspend failed: ") + e.what(); return false;
    }
}

bool spk::view::resume(spk_session* session, std::string& error) {
    if (!session) { error = "residency: session is null"; return false; }
    std::lock_guard<std::mutex> guard(session->lock);
    if (!session->residency) return true;
    try {
        auto& snapshot = *session->residency;
        // Hosts resume before mutating a session. Refuse an invalid caller
        // rather than resurrecting caches belonging to a different snapshot.
        if (snapshot.tiers.size() != session->tiers.size()) {
            error = "residency: suspended session was modified"; return false;
        }
        for (const auto& [name, slots] : snapshot.tiers)
            if (session->tiers.find(name) == session->tiers.end()) {
                error = "residency: suspended tier was removed"; return false;
            }
        std::clearerr(snapshot.file.get());
        if (std::fseek(snapshot.file.get(), 0, SEEK_SET) != 0) {
            error = "residency: cannot rewind temporary image"; return false;
        }
        auto* gpu = session->engine->gpu;
        std::vector<gpu::BufferRef> restored;
        restored.reserve(snapshot.planes.size());
        std::vector<uint8_t> chunk(kResidencyChunkBytes);
        bool read = false;
        for (const auto& plane : snapshot.planes) {
            auto destination = gpu->alloc_persistent(plane.bytes, error);
            if (!destination) return false;
            for (size_t offset = 0; offset < plane.bytes;) {
                const size_t n = std::min(chunk.size(), plane.bytes - offset);
                if ((read && residency_fault("read")) ||
                    std::fread(chunk.data(), 1, n, snapshot.file.get()) != n) {
                    error = "residency: failed to read temporary image; disk snapshot retained"; return false;
                }
                // The upload staging is bounded. A persistent chunk avoids
                // borrowing an oversized free render plane from the pool.
                auto upload = gpu->upload_persistent(chunk.data(), n, error);
                if (!upload || !gpu->copy(destination.get(), offset, upload.get(), 0, n, error)) return false;
                read = true; offset += n;
            }
            restored.push_back(std::move(destination));
        }
        const auto install = [&](Image& image, const spk_session::ResidencySnapshot::Slot& slot) {
            image.h = slot.h; image.w = slot.w; image.c = slot.c;
            image.buf = slot.plane == size_t(-1) ? gpu::BufferRef{} : restored[slot.plane];
        };
        // Commit only after every allocation and read succeeded. Until here,
        // RAII releases any partial GPU restoration and the file stays valid.
        install(session->source, snapshot.source);
        for (const auto& [name, slots] : snapshot.tiers) {
            auto& tier = session->tiers.at(name);
            install(tier.image, slots.image); install(tier.negative, slots.negative);
            install(tier.view_print, slots.view_print);
        }
        session->residency.reset();
        return true;
    } catch (const std::exception& e) {
        error = std::string("residency: resume failed: ") + e.what(); return false;
    }
}

bool spk::view::render_source(spk_session* session, uint32_t long_edge, const std::string& display,
                              Result& result, std::string& error) {
    if (!session || (display != "sRGB" && display != "Display P3") || long_edge > 65536) {
        error = "source: invalid session, size or display space"; return false;
    }
    if (!resume(session, error)) return false;
    std::lock_guard<std::mutex> guard(session->lock);
    if (session->params.io.input_color_space != "ProPhoto RGB" || session->params.io.input_cctf_decoding) {
        error = "source: expected the desktop linear ProPhoto input"; return false;
    }
    auto* gpu = session->engine->gpu;
    gpu->begin_frame();
    struct EndFrame { gpu::Gpu* gpu; ~EndFrame() { gpu->end_frame(); } } end{gpu};
    const auto start = std::chrono::steady_clock::now();
    Image source;
    if (!downscale(gpu, session->source, long_edge, source, error) || !gpu->flush(error)) return false;
    Mat3 matrix;
    if (!session->engine->colour.matrix_RGB_to_RGB("ProPhoto RGB", display, "CAT02", matrix, error)) return false;
    double row[9]; matrix.to_row_major(row); float column[9];
    for (size_t r = 0; r < 3; ++r) for (size_t c = 0; c < 3; ++c) column[r * 3 + c] = float(row[c * 3 + r]);
    auto encoded = gpu->alloc(source.bytes(), error);
    if (!encoded) return false;
    uint32_t meta[] = {uint32_t(source.pixels()), 0}; // sRGB/P3 share the sRGB OETF
    if (!gpu->dispatch("spk_cctf_encode_matrix", {gpu::Arg::buf(source.buf), gpu::Arg::inline_bytes(column, 9),
            gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(encoded)}, source.pixels(), error) || !gpu->flush(error)) return false;
    auto packed = gpu->alloc(source.pixels() * 4, error);
    auto stats = gpu->alloc_zeroed(12, error);
    if (!packed || !stats) return false;
    uint32_t packing[] = {uint32_t(source.pixels()), 4, 8, 4, 0};
    if (!gpu->dispatch("spk_view_pack", {gpu::Arg::buf(encoded), gpu::Arg::inline_bytes(packing, 5),
            gpu::Arg::buf(packed), gpu::Arg::buf(stats)}, source.pixels(), error) || !gpu->flush(error)) return false;
    Result next;
    next.post_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    const auto read = std::chrono::steady_clock::now();
    next.pixels.resize(source.pixels() * 4);
    if (!gpu->read(packed.get(), 0, next.pixels.data(), next.pixels.size(), error)) return false;
    next.readback_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - read).count();
    next.width = source.w; next.height = source.h;
    next.source_width = session->source.w; next.source_height = session->source.h;
    result = std::move(next); return true;
}

bool spk::view::sample_source(spk_session* session, double x, double y, SourceSample& result, std::string& error) {
    if (!session || !std::isfinite(x) || !std::isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) {
        error = "neutral pick: invalid normalized source coordinates"; return false;
    }
    if (!resume(session, error)) return false;
    std::lock_guard<std::mutex> guard(session->lock);
    const auto& image = session->source;
    if (!image.valid() || image.c != 3) { error = "neutral pick: no decoded RGB source"; return false; }
    auto* gpu = session->engine->gpu;
    if (!gpu->flush(error)) return false;
    const int cx = std::min(int(image.w) - 1, int(x * image.w));
    const int cy = std::min(int(image.h) - 1, int(y * image.h));
    const int x0 = std::max(0, cx - 2), x1 = std::min(int(image.w) - 1, cx + 2);
    const int y0 = std::max(0, cy - 2), y1 = std::min(int(image.h) - 1, cy + 2);
    SourceSample next;
    next.minimum.fill(std::numeric_limits<double>::infinity());
    next.maximum.fill(-std::numeric_limits<double>::infinity());
    for (int row = y0; row <= y1; ++row) {
        std::array<float, 15> values{};
        if (!gpu->read(image.buf.get(), (size_t(row) * image.w + x0) * 3 * sizeof(float),
                       values.data(), size_t(x1 - x0 + 1) * 3 * sizeof(float), error)) return false;
        for (int px = 0; px <= x1 - x0; ++px) {
            for (int c = 0; c < 3; ++c) {
                double v = values[size_t(px) * 3 + c];
                if (!std::isfinite(v)) { error = "neutral pick: source contains a non-finite value"; return false; }
                next.mean[c] += v; next.minimum[c] = std::min(next.minimum[c], v); next.maximum[c] = std::max(next.maximum[c], v);
            }
            ++next.samples;
        }
    }
    for (double& v : next.mean) v /= next.samples;
    result = next; return true;
}

// One shipped view table per engine. Match Mac's binary16 texture values;
// interpolation and grading remain float32 and share one UNORM16 boundary.
static bool di_view_table(spk_engine* engine, gpu::BufferRef& table, std::string& error) {
    constexpr const char* key = "@di-view-prophoto-65";
    auto found = engine->print_lut_buffers.find(key);
    if (found != engine->print_lut_buffers.end()) { table = found->second; return true; }
    std::ifstream input(file_path(engine->resources_dir + "/DI/SpektraLab DI view, Cineon to ProPhoto RGB.cube"));
    if (!input) { error = "DI view LUT is missing from engine resources"; return false; }
    std::vector<float> values; values.reserve(65 * 65 * 65 * 3);
    std::string line; int size = 0;
    while (std::getline(input, line)) {
        std::istringstream row(line); std::string token; row >> token;
        if (token == "LUT_3D_SIZE") { row >> size; continue; }
        if (token.empty() || (token[0] != '-' && token[0] != '.' && (token[0] < '0' || token[0] > '9'))) continue;
        row.clear(); row.str(line);
        float v[3]; std::string extra;
        if (!(row >> v[0] >> v[1] >> v[2]) || (row >> extra)) { error = "DI view LUT has an invalid row"; return false; }
        for (float x : v) {
            if (!std::isfinite(x) || x < 0 || x > 1) { error = "DI view LUT has an invalid value"; return false; }
            int exponent = 0; std::frexp(x, &exponent);
            const float step = std::ldexp(1.0f, std::max(-24, exponent - 11));
            const float scaled = x / step, lo = std::floor(scaled), fraction = scaled - lo;
            values.push_back((lo + (fraction > .5f || (fraction == .5f && std::fmod(lo, 2.f) != 0) ? 1.f : 0.f)) * step);
        }
    }
    if (size != 65 || values.size() != 65 * 65 * 65 * 3) { error = "DI view LUT has an invalid grid"; return false; }
    table = engine->gpu->upload_persistent(values.data(), values.size() * sizeof(float), error);
    if (!table) return false;
    engine->print_lut_buffers[key] = table;
    return true;
}

// Mac Session.pairLayered: one negative, independent print trims and grades,
// then a single feathered composite. The session's frozen film state is never
// rewritten, and no intermediate image crosses the CPU boundary.
static bool pair_layers(spk_session* session, const Tier& tier, const Image& source,
                        const spk::view::Request& request, const gpu::BufferRef& di_lut,
                        Image& print, bool& layered, double& print_ms, double& post_ms,
                        std::string& error) {
    using namespace spk;
    layered = false;
    if (request.pair.is_null() || request.cineon) return true;
    try {
        if (!request.pair.is_object()) throw std::runtime_error("pair must be an object");
        struct Layer { bool printed = false, graded = false; Json delta = Json::object(), grade; } layers[2];
        const char* names[] = {"left", "right"};
        const char* keys[] = {"print_exposure", "y_filter_shift", "m_filter_shift", "preflash_exposure"};
        const double film[] = {session->params.enlarger.print_exposure, session->params.enlarger.y_filter_shift,
                               session->params.enlarger.m_filter_shift, session->params.enlarger.preflash_exposure};
        Json restore = Json::object(); for (int i=0;i<4;++i) restore.set(keys[i], Json(film[i]));
        auto number = [&](const Json& obj, const char* name, double lo, double hi) {
            if (!obj.has(name)) return 0.0;
            const auto& n = obj.at(name); const double value = n.as_double();
            if (!n.is_number() || !std::isfinite(value) || value<lo || value>hi)
                throw std::runtime_error(std::string("invalid pair ")+name);
            return value;
        };
        for (int side=0;side<2;++side) {
            const auto& hole = request.pair.at(names[side]);
            if (hole.is_null()) continue;
            if (!hole.is_object()) throw std::runtime_error("pair hole must be an object or null");
            auto& layer=layers[side]; layer.grade=request.adjustments;
            if (hole.has("adjustments") && !hole.at("adjustments").is_null()) {
                if (!hole.at("adjustments").is_object()) throw std::runtime_error("pair adjustments must be an object");
                layer.grade=hole.at("adjustments"); layer.graded=layer.grade.dump()!=request.adjustments.dump();
            }
            const auto& trim=hole.at("print");
            if (!trim.is_null()) {
                if (!trim.is_object()) throw std::runtime_error("pair print must be an object");
                const double values[]={std::clamp(std::pow(2.0,-number(trim,"brightnessStops",-20,20)),.05,20.0),
                    number(trim,"yFilterShift",-1,1),number(trim,"mFilterShift",-1,1),
                    request.pair.at("printEffects").as_bool(true)?number(trim,"preflashExposure",0,1):0.0};
                for(int i=0;i<4;++i) { layer.delta.set(keys[i],Json(values[i])); layer.printed|=values[i]!=film[i]; }
            }
            layered|=layer.printed||layer.graded;
        }
        if (!layered) return true;
        std::array<std::array<float,4>,2> rects{};
        auto& state=session->tiers[tier.name];
        session->pipeline->set_source_shape(source.w,source.h,session->source.w,session->source.h);
        if(!session->pipeline->set_overscan_frame(state.overscan_frame_w,state.overscan_frame_h,error))return false;
        Json gates=request.pair.at("gates");
        if(session->params.film_render.overscan.active) {
            Json layout;
            if(!Json::parse(session->pipeline->overscan_geometry_json(),layout,error))return false;
            gates=layout.at("gates");
        }
        if(!gates.is_array()||gates.items().size()!=2)throw std::runtime_error("pair layers require two gates");
        for(size_t side=0;side<2;++side) {
            const auto& gate=gates.items()[side];
            if(!gate.is_array()||(gate.items().size()!=4&&gate.items().size()!=8))throw std::runtime_error("invalid pair gate");
            double x0=1,y0=1,x1=0,y1=0;
            for(size_t k=0;k<gate.items().size();k+=2) {
                const auto& x=gate.items()[k];const auto& y=gate.items()[k+1];
                if(!x.is_number()||!y.is_number()||!std::isfinite(x.as_double())||!std::isfinite(y.as_double()))
                    throw std::runtime_error("invalid pair gate coordinate");
                x0=std::min(x0,x.as_double());x1=std::max(x1,x.as_double());
                y0=std::min(y0,y.as_double());y1=std::max(y1,y.as_double());
            }
            if(x0<0||y0<0||x1>1||y1>1||x0>=x1||y0>=y1)throw std::runtime_error("pair gate lies outside canvas");
            rects[side]={float(x0*print.w),float(y0*print.h),float(x1*print.w),float(y1*print.h)};
        }
        const size_t axis=request.pair.at("turned").as_bool()?1:0;
        if(rects[1][axis]<rects[0][axis])std::swap(rects[0],rects[1]);
        auto* gpu=session->engine->gpu;
        Json identity=Json::object();identity.set("source_color_space",Json(std::string("ProPhoto RGB")));
        identity.set("target_color_space",Json(std::string("ProPhoto RGB")));
        view::Request q; q.rgba16=true; q.target_space="ProPhoto RGB";
        auto grade=[&](const Image& input,const Json& adjustments,Image& output) {
            q.adjustments=adjustments; view::Result timing;
            const bool ok=view::process(gpu,input,q,identity,nullptr,0,timing,error,di_lut,di_lut?65:0,&output);
            post_ms+=timing.post_ms; return ok;
        };
        Image base, images[2];
        if(!grade(print,request.adjustments,base))return false;
        for(int side=0;side<2;++side) {
            const auto& layer=layers[side];
            if(!layer.printed&&!layer.graded){images[side]=base;continue;}
            Image input=print;
            if(layer.printed) {
                const auto started=std::chrono::steady_clock::now();
                Image negative,rgb;
                if(!negative_for(session,tier,&session->progress,negative,error))return false;
                struct RestorePrint { Pipeline* pipeline; const Json& values; ~RestorePrint(){pipeline->apply_live_delta(values);} } reset{session->pipeline.get(),restore};
                session->pipeline->apply_live_delta(layer.delta);
                if(!run_print_for(session,negative,rgb,&session->progress,error))return false;
                input.w=rgb.w;input.h=rgb.h;input.c=2;input.buf=gpu->alloc(input.bytes(),error);
                if(!input.buf)return false;
                uint32_t m[]={uint32_t(rgb.pixels()),rgb.w,rgb.w};
                if(!gpu->dispatch("spk_to_rgba16",{gpu::Arg::buf(rgb.buf),gpu::Arg::inline_bytes(m,3),gpu::Arg::buf(input.buf)},rgb.pixels(),error)||!gpu->flush(error))return false;
                print_ms+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
            }
            if(!grade(input,layer.grade,images[side]))return false;
        }
        const auto started=std::chrono::steady_clock::now();
        Image composite;composite.w=base.w;composite.h=base.h;composite.c=2;composite.buf=gpu->alloc(base.bytes(),error);
        if(!composite.buf)return false;
        const uint32_t meta[]={uint32_t(base.pixels()),base.w,(layers[0].printed||layers[0].graded)?1u:0u,(layers[1].printed||layers[1].graded)?1u:0u};
        if(!gpu->dispatch("spk_view_pair",{gpu::Arg::buf(base.buf),gpu::Arg::buf(images[0].buf),gpu::Arg::buf(images[1].buf),
            gpu::Arg::inline_bytes(meta,4),gpu::Arg::inline_bytes(rects[0].data(),8),gpu::Arg::buf(composite.buf)},base.pixels(),error)||!gpu->flush(error))return false;
        post_ms+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
        print=std::move(composite);return true;
    } catch(const std::exception& e){error=std::string("view: ")+e.what();return false;}
}

bool spk::view::render(spk_session* session, const Request& request, Result& result,
                       std::string& error) {
    result = Result{};
    if (!session) { error = "view: session is null"; return false; }
    if (!resume(session, error)) return false;
    const Tier* tier = find_tier(request.tier.c_str());
    if (!tier) { error = "view: unknown tier"; return false; }
    if (request.target_space != "sRGB" && request.target_space != "Display P3" && request.target_space != "ProPhoto RGB" &&
        request.target_space != "Adobe RGB (1998)" && request.target_space != "ITU-R BT.2020") {
        error = "view: unknown target space"; return false;
    }
    std::lock_guard<std::mutex> guard(session->lock);
    if (request.no_film && request.cineon) { error = "view: no_film cannot write a Digital Intermediate"; return false; }
    const bool no_film = request.no_film;
    if (no_film && (!request.pair.is_null() || session->params.film_render.overscan.pair)) {
        error = "view: no_film is unavailable for a half-frame pair"; return false;
    }
    if (no_film && (session->params.io.input_color_space != "ProPhoto RGB" || session->params.io.input_cctf_decoding)) {
        error = "view: no_film requires the desktop linear ProPhoto source"; return false;
    }
    if (session->params.io.output_color_space != "ProPhoto RGB" || !session->params.io.output_cctf_encoding) {
        error = "view: the desktop postprocess requires encoded ProPhoto RGB"; return false;
    }
    auto* gpu = session->engine->gpu;
    gpu->begin_frame();
    struct EndFrame { gpu::Gpu* gpu; ~EndFrame() { gpu->end_frame(); } } end{gpu};
    session->progress = Progress{};
    session->progress.progress_id = "p" + std::to_string(next_id());
    session->progress.detailed = std::getenv("SPEKTRAFILM_NODE_TIMINGS") != nullptr;
    session->progress.memory_pressure_critical = gpu->take_critical_pressure();
    if (session->progress.memory_pressure_critical)
        for (auto& kv : session->tiers) kv.second.view_print = Image{};
    auto started = std::chrono::steady_clock::now();
    // tier_image may replace the tier state if preview_long_edge changed.
    Image source;
    if (!tier_image(session, *tier, source, error)) return false;
    auto& state = session->tiers[tier->name];
    uint32_t full_w = 0, full_h = 0;
    if (no_film) { full_w = session->source.w; full_h = session->source.h; }
    else if (!session->pipeline->full_output_size(session->source.w, session->source.h, full_w, full_h, error)) return false;
    result.print_cached = !no_film && !request.cineon && state.view_print.valid();
    Image packed_print;
    if (no_film) {
        // Film geometry, exposure and randomness do not own the decode. Encode
        // it as float RGB: premature RGBA16 packing would clip RAW highlights
        // before a negative Post-Dev exposure could recover them. process()
        // shares the same grade/geometry/output path and its normal boundary.
        packed_print.w = source.w; packed_print.h = source.h; packed_print.c = 3;
        packed_print.buf = gpu->alloc(source.bytes(), error);
        if (!packed_print.buf) return false;
        const float identity[] = {1,0,0,0,1,0,0,0,1};
        const uint32_t meta[] = {uint32_t(source.pixels()), 1}; // ProPhoto OETF
        if (!gpu->dispatch("spk_cctf_encode_matrix", {gpu::Arg::buf(source.buf), gpu::Arg::inline_bytes(identity, 9),
                gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(packed_print.buf)}, source.pixels(), error) || !gpu->flush(error)) return false;
    } else if (!result.print_cached) {
        session->pipeline->set_source_shape(source.w, source.h, session->source.w, session->source.h);
        Image negative, rgb;
        if (!negative_for(session, *tier, &session->progress, negative, error)) return false;
        if (request.cineon) {
            if (session->params.film.info.is_positive()) { error = "a slide film has no Digital Intermediate"; return false; }
            Params params = session->params; params.io.digital_intermediate = true; params.io.scan_film = false;
            Pipeline pipeline(gpu, &session->engine->colour, &session->engine->blob, &session->engine->setup_cache);
            if (!pipeline.build(params, error)) return false;
            pipeline.set_source_shape(source.w, source.h, session->source.w, session->source.h);
            if (!pipeline.set_overscan_frame(state.overscan_frame_w, state.overscan_frame_h, error) ||
                !(params.settings.striped ? pipeline.run_print_striped(negative, rgb, &session->progress, error)
                                          : pipeline.run_print(negative, rgb, &session->progress, error))) return false;
        } else if (!session->pipeline->set_overscan_frame(state.overscan_frame_w, state.overscan_frame_h, error) ||
                   !run_print_for(session, negative, rgb, &session->progress, error)) return false;
        Image packed; packed.w = rgb.w; packed.h = rgb.h; packed.c = 2;
        packed.buf = gpu->alloc_persistent(packed.bytes(), error);
        if (!packed.buf) return false;
        uint32_t meta[] = {uint32_t(rgb.pixels()), rgb.w, rgb.w};
        if (!gpu->dispatch("spk_to_rgba16", {gpu::Arg::buf(rgb.buf), gpu::Arg::inline_bytes(meta, 3), gpu::Arg::buf(packed.buf)},
                           rgb.pixels(), error) || !gpu->flush(error)) return false;
        packed_print = std::move(packed);
        if (!request.cineon) state.view_print = packed_print;
    } else {
        packed_print = state.view_print;
        MemoryEstimateTrace trace(session, "print", "hit", packed_print, 0);
        trace.success = true;
        session->progress.auto_exposure_ev = state.applied_ev;
    }
    result.print_ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
    Json transform = Json::object(); const float* cmax = nullptr; uint32_t count = 0;
    auto display_transform = [&](const std::string& src, const std::string& dst, Json& transform)->bool {
        const Colour& colour = session->engine->colour;

        for (const auto& space : {src, dst}) {
            const Colour::Colourspace* definition = nullptr;
            if (!colour.colourspace(space, definition, error)) return false;
            if (!colour.known_cctf(space)) {
                error = "view: no transfer function baked for colour space '" + space + "'"; return false;
            }
            if (definition->whitepoint[1] == 0.0) {
                error = "view: no whitepoint baked for colour space '" + space + "'"; return false;
            }
        }
        Mat3 matrix;
        if (!colour.matrix_RGB_to_RGB(src, dst, "CAT02", matrix, error)) return false;
        double row[9]; matrix.to_row_major(row);
        Json numbers = Json::array();
        for (double v : row) numbers.push(Json(v));
        transform.set("source_color_space", Json(src));
        transform.set("target_color_space", Json(dst));
        transform.set("source_cctf_mode", Json(double(cctf_mode_for(src))));
        transform.set("target_cctf_mode", Json(double(cctf_mode_for(dst))));
        transform.set("matrix", std::move(numbers));
        Json compress = Json::object(); compress.set("algorithm", Json("off"));
        transform.set("gamut_compress", std::move(compress));
        return true;
    };
    gpu::BufferRef di_lut;
    const bool di_view = !no_film && session->params.io.digital_intermediate && !session->params.io.scan_film &&
                         !session->params.film.info.is_positive();
    if ((request.cineon || di_view) && !di_view_table(session->engine, di_lut, error)) return false;
    if (request.cineon) {
        // The intermediate is where grading starts. Geometry is retained;
        // Post-Dev and display/output RGB transforms never touch its codes.
        Request raw = request; raw.adjustments = Json::object(); raw.adjustments.set("enabled", Json(false));
        raw.export_intent = false; raw.proof_long_edge = 0; raw.rgba16 = true; raw.output_channels = 4;
        raw.target_space = "ProPhoto RGB";
        Json identity = Json::object(); identity.set("source_color_space", Json("ProPhoto RGB"));
        identity.set("target_color_space", Json("ProPhoto RGB"));
        Image file_codes;
        if (!process(gpu, packed_print, raw, identity, nullptr, 0, result, error, {}, 0, &file_codes)) return false;
        packed_print = Image{};
        raw.geometry = Json::object(); raw.long_edge = 0;
        if (!request.proof_long_edge) {
            raw.output_channels = 3;
            Result codes;
            if (!process(gpu, file_codes, raw, identity, nullptr, 0, codes, error)) return false;
            result.pixels = std::move(codes.pixels); result.post_ms += codes.post_ms; result.readback_ms += codes.readback_ms;
        }
        Request preview = raw; preview.rgba16 = false;
        preview.long_edge = request.proof_long_edge ? request.proof_long_edge : 2048;
        preview.target_space = request.proof_long_edge ? request.proof_display : "sRGB";
        preview.output_channels = request.proof_long_edge ? 4 : 3;
        Json display;
        if (!display_transform("ProPhoto RGB", preview.target_space, display)) return false;
        Result shown;
        if (!process(gpu, file_codes, preview, display, nullptr, 0, shown, error, di_lut, 65)) return false;
        result.post_ms += shown.post_ms; result.readback_ms += shown.readback_ms;
        if (request.proof_long_edge) {
            result.pixels = std::move(shown.pixels); result.width = shown.width; result.height = shown.height;
        } else {
            result.preview_rgb = std::move(shown.pixels); result.preview_width = shown.width; result.preview_height = shown.height;
        }
        result.source_width = full_w; result.source_height = full_h;
        session->progress.done = true; return true;
    }
    bool pair_layered = false; double pair_print_ms = 0, pair_post_ms = 0;
    if (!no_film && !pair_layers(session, *tier, source, request, di_lut, packed_print, pair_layered,
                     pair_print_ms, pair_post_ms, error)) return false;
    if (request.export_intent) {
        char* text = nullptr;
        // The film print already applied the working-space lightness shoulder.
        // Mac keeps only the target chroma knee at this file boundary.
        if (spk_output_transform(session->engine, "ProPhoto RGB", request.target_space.c_str(), "{\"lightness_compression_active\":false}",
                                 &text, &cmax, &count) != SPK_OK) {
            error = spk_last_error(session->engine); return false;
        }
        bool parsed = Json::parse(text, transform, error); spk_string_free(text);
        if (!parsed) return false;
    } else if (!display_transform("ProPhoto RGB", request.target_space, transform)) return false;
    if (request.proof_long_edge) {
        if (!request.export_intent || (request.proof_display != "sRGB" && request.proof_display != "Display P3")) {
            error = "view: invalid proof display request"; return false;
        }
        Json display = Json::object();
        if (!display_transform(request.target_space, request.proof_display, display)) return false;
        transform.set("proof", std::move(display));
    }
    Request final_request = request;
    if (pair_layered) final_request.adjustments.set("enabled", Json(false));
    const gpu::BufferRef final_lut = pair_layered ? gpu::BufferRef{} : di_lut;
    {
        // Output shape/packing differ from the input: observe first, do not
        // apply the RGB scratch model to output conversion or CPU readback.
        MemoryEstimateTrace trace(session, request.export_intent ? "output-export" : "output-view",
                                  "miss", packed_print, MemoryEstimateTrace::kObserveOnly);
        trace.success = process(gpu, packed_print, final_request, transform, cmax, count, result, error, final_lut, final_lut ? 65 : 0);
        trace.output_payload_bytes = result.pixels.size();
        if (!trace.success) return false;
    }
    result.print_ms += pair_print_ms; result.post_ms += pair_post_ms;
    result.source_width = full_w; result.source_height = full_h;
    session->progress.done = true;
    return true;
}
#endif

// The LUT methods' helpers, outside the C block: they take and return C++
// types, and a C-linkage function that returns a `Json` is a warning today
// and a collision the first time two translation units agree on a name.
namespace {

// One stock's table on the device, uploaded on first use and kept for the
// engine's lifetime. Persistent rather than pooled: 431 kB that every
// subsequent flip reads, in a pool sized for full-frame buffers.
bool lut_buffer_for(spk_engine* engine, const PrintLut& lut, gpu::BufferRef& out,
                    std::string& error) {
    auto it = engine->print_lut_buffers.find(lut.stock);
    if (it != engine->print_lut_buffers.end()) { out = it->second; return true; }
    gpu::BufferRef buffer = engine->gpu->upload_persistent(
        lut.table.data(), lut.table.size() * sizeof(float), error);
    if (!buffer) return false;
    engine->print_lut_buffers[lut.stock] = buffer;
    out = buffer;
    return true;
}

// The mismatch warning PRD §7.3 requires. The table is baked through a
// specific negative's dye spectra as well as through the paper, so a session
// on a different film is an approximation whose error nobody has measured --
// which is worth saying rather than silently answering.
Json film_mismatch_warning(const PrintLut& lut, const std::string& film) {
    if (lut.paired_film == film) return Json();
    return Json("LUT was baked against film '" + lut.paired_film + "' but the session uses '" +
                film + "'; the print+scan chain is coupled to the negative's dye spectra, so "
                "this is an approximation with unmeasured error");
}

// The half both LUT methods share: resolve the stock, take the session's
// negative for `tier`, and leave the table on the device ready to index.
const PrintLut* prepare_lut(spk_session* session, const char* print_stock, const Tier& tier,
                            Image& negative, gpu::BufferRef& table, std::string& error) {
    spk_engine* engine = session->engine;
    const std::string stock = (print_stock && *print_stock) ? print_stock
                                                            : session->params.print_stock;
    const PrintLut* lut = engine->print_luts.get(engine->blob, stock, error);
    if (!lut) return nullptr;
    if (!lut_buffer_for(engine, *lut, table, error)) return nullptr;

    Image tier_source;
    if (!tier_image(session, tier, tier_source, error)) return nullptr;
    // The same ordering `render_tier` uses, and for the same reason: the film
    // side needs the frame's pixel pitch, and a pipeline rebuilt by a
    // print-layer edit has never seen one.
    session->pipeline->set_source_shape(tier_source.w, tier_source.h, session->source.w, session->source.h);
    if (!negative_for(session, tier, &session->progress, negative, error)) return nullptr;
    return lut;
}

}  // namespace

extern "C" {

const char* spk_print_lut_catalog(spk_engine* engine) {
    if (!engine) return "{}";
    const std::string& catalog = engine->print_luts.catalog_json();
    return catalog.empty() ? "{}" : catalog.c_str();
}

spk_status spk_print_lut_table(spk_engine* engine, const char* print_stock,
                               const float** out_table, uint32_t* out_size) {
    if (!engine || !print_stock || !out_table || !out_size) {
        g_error = "engine, print_stock, out_table and out_size are all required";
        return SPK_ERR_INVALID_ARG;
    }
    g_error.clear();
    std::lock_guard<std::mutex> guard(engine->lock);
    std::string error;
    const PrintLut* lut = engine->print_luts.get(engine->blob, print_stock, error);
    if (!lut) { g_error = error; return SPK_ERR_USER; }
    *out_table = lut->table.data();
    *out_size = lut->size;
    return SPK_OK;
}

spk_status spk_output_transform(spk_engine* engine, const char* src_cs, const char* dst_cs,
                                const char* gamut_compress_json,
                                char** out_json, const float** out_cmax,
                                uint32_t* out_cmax_count) {
    if (!engine || !src_cs || !dst_cs || !out_json || !out_cmax || !out_cmax_count) {
        g_error = "engine, src_cs, dst_cs, out_json, out_cmax and out_cmax_count are all required";
        return SPK_ERR_INVALID_ARG;
    }
    g_error.clear();
    const std::string src(src_cs), dst(dst_cs);
    const Colour& colour = engine->colour;

    // Both ends must be spaces this build can actually render in. An unknown
    // name fails **here** and by name -- never by falling back, which is how a
    // picture ends up in a space nobody asked for. And it fails *before*
    // anything expensive: `colourspace` is a map lookup, while the C_max table
    // below is 46,080 bisections, so a typo costs nothing.
    const Colour::Colourspace* src_space = nullptr;
    const Colour::Colourspace* dst_space = nullptr;
    std::string error;
    if (!colour.colourspace(src, src_space, error)) { g_error = "source: " + error; return SPK_ERR_USER; }
    if (!colour.colourspace(dst, dst_space, error)) { g_error = "target: " + error; return SPK_ERR_USER; }
    // A transfer function the kernels can name. `cctf_mode_for` answers 4
    // ("identity") for anything it does not know, and an identity curve is
    // only *right* for the ACES spaces -- a space that is neither baked as a
    // CCTF nor one of them would come out silently un-encoded, so it is
    // refused rather than guessed at.
    if (!colour.known_cctf(src) || !colour.known_cctf(dst)) {
        const std::string& bad = colour.known_cctf(src) ? dst : src;
        g_error = "no transfer function baked for colour space '" + bad + "'";
        return SPK_ERR_USER;
    }
    // The whitepoint is what a chromatic adaptation is *between*. Every space
    // in today's blob carries one, so this does not fire on the shipped data;
    // it is here because the failure it would prevent is silent.
    // `Colourspace::whitepoint` defaults to (0, 0), so a space baked without
    // one does not fail at adaptation -- it divides by zero and returns a
    // matrix that renders a plausible, wrong picture.
    if (src_space->whitepoint[1] == 0.0 || dst_space->whitepoint[1] == 0.0) {
        const std::string& bad = src_space->whitepoint[1] == 0.0 ? src : dst;
        g_error = "no whitepoint baked for colour space '" + bad + "'";
        return SPK_ERR_USER;
    }

    // --- the gamut compression's own settings ------------------------------
    // `gamut_compress_json` is the caller's override and NULL means the spec
    // every session gets (`output_default()`: cam16ucs, lightness compression
    // on, the standard knee). No wire field can change it, so NULL is what a
    // session actually has; the override exists because the *app* decides when
    // to skip the step, and a caller that has already flipped it should not
    // have to come back for the tables.
    GamutCompressSpec og = GamutCompressSpec::output_default();
    if (gamut_compress_json && *gamut_compress_json) {
        Json spec = Json::object();
        if (!Json::parse(gamut_compress_json, spec, error)) {
            g_error = "gamut_compress: " + error;
            return SPK_ERR_INVALID_ARG;
        }
        if (spec.has("algorithm")) og.algorithm = spec.at("algorithm").as_string();
        if (spec.has("lightness_compression_active"))
            og.lightness_compression_active = spec.at("lightness_compression_active").as_bool();
        auto triple = [&](const char* key, double out[3]) {
            const Json& j = spec.at(key);
            if (!j.is_array() || j.items().size() != 3) return;
            for (size_t i = 0; i < 3; ++i) out[i] = j.items()[i].as_double();
        };
        triple("knee", og.knee);
        triple("lightness_compression", og.lightness_compression);
    }
    if (og.algorithm != "off" && og.algorithm != "cam16ucs") {
        g_error = "output gamut compression '" + og.algorithm + "' is not implemented "
                  "(only cam16ucs and off)";
        return SPK_ERR_USER;
    }

    // --- the linear matrix -------------------------------------------------
    // CAT02, the same transform the CAM16 setup and the scan's XYZ -> RGB use.
    // ProPhoto is D50 and every display and export space here is D65, so this
    // is where the picture's white actually moves.
    Mat3 matrix;
    if (!colour.matrix_RGB_to_RGB(src, dst, "CAT02", matrix, error)) { g_error = error; return SPK_ERR_USER; }
    // Plain row-major -- `out[i] = sum_j m[3i + j] * x[j]` -- and written down
    // as such because the app's kernel is the other side of a boundary the two
    // matrix conventions have already crossed wrongly once (AGENTS.md trap 20:
    // a transposed matrix here reads as a grading decision, not as a bug).
    double row[9];
    matrix.to_row_major(row);

    // --- CAM16-UCS into the destination ------------------------------------
    const Cam16Setup* cached = nullptr;
    if (!engine->setup_cache.cam16(colour, dst, cached, error)) { g_error = error; return SPK_ERR_USER; }
    double m2x[9], m2r[9];
    row_major(cached->m_to_xyz, m2x);   // `spk_cam16ucs_compress`'s convention
    row_major(cached->m_to_rgb, m2r);
    const double consts[22] = {
        cached->F_L, cached->N_bb, cached->N_cb, cached->n, cached->z, cached->A_w,
        cached->c, cached->N_c,
        cached->l_grid.front(), cached->l_grid.back(),
        cached->h_grid.front(), cached->h_grid[1] - cached->h_grid[0],
        og.knee[0], og.knee[1], og.knee[2],
        og.lightness_compression_active ? og.lightness_compression[0] : 0.0,
        og.lightness_compression_active ? og.lightness_compression[1] : 1.0,
        og.lightness_compression_active ? og.lightness_compression[2] : 1.0,
        cached->white_Jp, cached->D_rgb[0], cached->D_rgb[1], cached->D_rgb[2],
    };

    Json reply = Json::object();
    reply.set("source_color_space", Json(src));
    reply.set("target_color_space", Json(dst));
    reply.set("source_cctf_mode", Json(double(cctf_mode_for(src))));
    reply.set("target_cctf_mode", Json(double(cctf_mode_for(dst))));
    auto numbers = [](const double* v, size_t n) {
        Json a = Json::array();
        for (size_t i = 0; i < n; ++i) a.push(Json(v[i]));
        return a;
    };
    reply.set("matrix", numbers(row, 9));

    Json compress = Json::object();
    compress.set("algorithm", Json(og.algorithm));
    compress.set("m_to_xyz", numbers(m2x, 9));
    compress.set("m_to_rgb", numbers(m2r, 9));
    compress.set("k", numbers(consts, 22));
    compress.set("cmax_rows", Json(double(cached->l_grid.size())));
    compress.set("cmax_cols", Json(double(cached->h_grid.size())));
    // The lightness compression's gate, and it has to travel: when it is off,
    // `k[15..17]` are zeroed/neutralised above, but the kernel cannot infer
    // *that* from them -- a gate of 1 with those values is not an identity.
    compress.set("lightness_compression_active", Json(og.lightness_compression_active));
    reply.set("gamut_compress", std::move(compress));

    // --- the table, as float32 the caller can upload -----------------------
    // Engine-owned and kept for the engine's lifetime, exactly as
    // `spk_print_lut_table`'s table is: an `unordered_map` is node-based, so a
    // pointer to an existing value survives every later insert. The cache
    // holds doubles (the bisection needs them) and the kernel reads float32,
    // so the narrowing is done once, here, rather than per upload.
    std::lock_guard<std::mutex> guard(engine->lock);
    auto it = engine->cam16_cmax_f32.find(dst);
    if (it == engine->cam16_cmax_f32.end()) {
        std::vector<float> narrowed;
        narrowed.reserve(cached->c_max_table.size());
        for (double v : cached->c_max_table) narrowed.push_back(float(v));
        it = engine->cam16_cmax_f32.emplace(dst, std::move(narrowed)).first;
    }
    *out_cmax = it->second.data();
    *out_cmax_count = uint32_t(it->second.size());
    *out_json = dup_json(reply);
    return SPK_OK;
}

spk_status spk_preview_stock_lut(spk_session* session, const char* print_stock,
                                 const char* tier_name, spk_result* out, char** out_json) {
    if (!session || !out) { g_error = "session or result is null"; return SPK_ERR_INVALID_ARG; }
    const Tier* tier = find_tier(tier_name ? tier_name : "live");
    if (!tier) {
        g_error = std::string("unknown tier '") + tier_name + "'; expected live, preview or full";
        return SPK_ERR_INVALID_ARG;
    }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    std::memset(out, 0, sizeof *out);

    gpu::Gpu* gpu = session->engine->gpu;
    const auto started = std::chrono::steady_clock::now();
    session->progress = Progress{};
    session->progress.progress_id = "p" + std::to_string(next_id());

    gpu->begin_frame();
    std::string error;
    Image negative, rgb;
    gpu::BufferRef table;
    const PrintLut* lut = prepare_lut(session, print_stock, *tier, negative, table, error);
    bool ok = lut != nullptr;

    // The apply itself is timed on its own, because that is the number the
    // path exists for and the negative in front of it may or may not have
    // been cached. 24 ms at 45 MP; a cold negative is seconds.
    double apply_ms = 0.0;
    if (ok) {
        const auto apply_started = std::chrono::steady_clock::now();
        rgb.h = negative.h; rgb.w = negative.w; rgb.c = 3;
        rgb.buf = gpu->alloc(rgb.bytes(), error);
        ok = static_cast<bool>(rgb.buf);
        if (ok) {
            const uint32_t meta[2] = {uint32_t(rgb.pixels()), lut->size};
            ok = gpu->dispatch("spk_lut3d_trilinear",
                               {gpu::Arg::buf(negative.buf), gpu::Arg::buf(table),
                                gpu::Arg::inline_bytes(lut->lo, 3),
                                gpu::Arg::inline_bytes(lut->inv_span, 3),
                                gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(rgb.buf)},
                               rgb.pixels(), error) && gpu->flush(error);
        }
        apply_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - apply_started).count();
    }
    if (ok) ok = materialise(session, rgb, out, error);
    gpu->end_frame();
    if (!ok) {
        g_error = error;
        return lut ? SPK_ERR_GPU : SPK_ERR_USER;
    }

    out->elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    // Reported as a reprint because that is what it is -- the negative was
    // reused and only the print side was replaced.
    out->reprint = 1;
    out->negative_was_cached = 1;
    std::snprintf(out->progress_id, sizeof out->progress_id, "%s",
                  session->progress.progress_id.c_str());
    session->progress.done = true;

    if (out_json) {
        Json reply = Json::object();
        reply.set("print_stock", Json(lut->stock));
        reply.set("tier", Json(std::string(tier->name)));
        reply.set("apply_ms", Json(apply_ms));
        reply.set("apply_backend", Json(std::string(kRenderCore)));
        reply.set("lut_source", Json(std::string("shipped")));
        reply.set("paired_film", Json(lut->paired_film));
        reply.set("declared_pairing", Json(lut->declared_pairing));
        Json warning = film_mismatch_warning(*lut, session->params.film_stock);
        if (!warning.is_null()) reply.set("warning", std::move(warning));
        *out_json = dup_json(reply);
    }
    return SPK_OK;
}

spk_status spk_export_di(spk_session* session, const char* print_stock, spk_result* out,
                         char** out_json) {
    if (!session || !out) { g_error = "session or result is null"; return SPK_ERR_INVALID_ARG; }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    std::memset(out, 0, sizeof *out);

    gpu::Gpu* gpu = session->engine->gpu;
    const auto started = std::chrono::steady_clock::now();
    session->progress = Progress{};
    session->progress.progress_id = "p" + std::to_string(next_id());

    gpu->begin_frame();
    std::string error;
    Image negative, di;
    gpu::BufferRef table;
    // Full tier: the DI file is the deliverable, not a preview.
    const PrintLut* lut = prepare_lut(session, print_stock, kTiers[2], negative, table, error);
    bool ok = lut != nullptr;
    if (ok) {
        di.h = negative.h; di.w = negative.w; di.c = 3;
        di.buf = gpu->alloc(di.bytes(), error);
        ok = static_cast<bool>(di.buf);
    }
    if (ok) {
        const uint32_t n = uint32_t(di.elements());
        ok = gpu->dispatch("spk_di_normalise",
                           {gpu::Arg::buf(negative.buf), gpu::Arg::inline_bytes(lut->lo, 3),
                            gpu::Arg::inline_bytes(lut->inv_span, 3),
                            gpu::Arg::inline_bytes(&n, 1), gpu::Arg::buf(di.buf)},
                           di.elements(), error) && gpu->flush(error);
    }
    if (ok) ok = materialise(session, di, out, error);
    gpu->end_frame();
    if (!ok) {
        g_error = error;
        return lut ? SPK_ERR_GPU : SPK_ERR_USER;
    }

    out->elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out->reprint = 1;
    out->negative_was_cached = 1;
    std::snprintf(out->progress_id, sizeof out->progress_id, "%s",
                  session->progress.progress_id.c_str());
    session->progress.done = true;

    if (out_json) {
        Json reply = Json::object();
        reply.set("print_stock", Json(lut->stock));
        reply.set("lut_size", Json(double(lut->size)));
        reply.set("paired_film", Json(lut->paired_film));
        reply.set("declared_pairing", Json(lut->declared_pairing));
        Json warning = film_mismatch_warning(*lut, session->params.film_stock);
        if (!warning.is_null()) reply.set("warning", std::move(warning));
        *out_json = dup_json(reply);
    }
    return SPK_OK;
}

spk_status spk_render_digital_intermediate(spk_session* session, spk_result* out, char** out_json) {
    if (!session || !out) { g_error = "session or result is null"; return SPK_ERR_INVALID_ARG; }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    std::memset(out, 0, sizeof *out);
    if (session->params.film.info.is_positive()) {
        g_error = "a slide film has no orange mask and no negative to reverse, so it has no "
                  "Digital Intermediate";
        return SPK_ERR_USER;
    }

    spk_engine* engine = session->engine;
    gpu::Gpu* gpu = engine->gpu;
    const auto started = std::chrono::steady_clock::now();
    session->progress = Progress{};
    session->progress.progress_id = "p" + std::to_string(next_id());

    // The session's own negative at full tier (cached when warm), through a
    // pipeline of its own with the DI switched on -- so the export does not
    // care which paper the canvas shows, and the session's pipeline and its
    // cached prints are untouched.
    Params params = session->params;
    params.io.digital_intermediate = true;
    params.io.scan_film = false;
    gpu->begin_frame();
    std::string error;
    Image tier_source, negative, rgb;
    Pipeline pipeline(gpu, &engine->colour, &engine->blob, &engine->setup_cache);
    bool ok = tier_image(session, kTiers[2], tier_source, error);
    if (ok) {
        session->pipeline->set_source_shape(tier_source.w, tier_source.h, session->source.w, session->source.h);
        ok = negative_for(session, kTiers[2], &session->progress, negative, error) &&
             pipeline.build(params, error);
        if (ok) {
            pipeline.set_source_shape(tier_source.w, tier_source.h, session->source.w, session->source.h);
            const spk_session::TierState& state = session->tiers[kTiers[2].name];
            ok = pipeline.set_overscan_frame(state.overscan_frame_w, state.overscan_frame_h, error);
        }
        if (ok) {
            ok = (params.settings.striped ? pipeline.run_print_striped(negative, rgb, nullptr, error)
                                          : pipeline.run_print(negative, rgb, nullptr, error)) &&
                 gpu->flush(error);
        }
    }
    if (ok) ok = materialise(session, rgb, out, error);
    gpu->end_frame();
    if (!ok) { g_error = error; return SPK_ERR_GPU; }

    out->elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out->reprint = 1;
    out->negative_was_cached = 1;
    std::snprintf(out->progress_id, sizeof out->progress_id, "%s",
                  session->progress.progress_id.c_str());
    session->progress.done = true;
    if (out_json) {
        Json reply = Json::object();
        reply.set("encoding", Json(std::string("cineon")));
        reply.set("primaries", Json(params.io.output_color_space));
        reply.set("printing_density_paper", Json(params.di_paper.info.stock));
        *out_json = dup_json(reply);
    }
    return SPK_OK;
}

spk_status spk_set_params(spk_session* session, const char* params_delta_json, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    g_error.clear();
    Json delta;
    std::string parse_error;
    if (!params_delta_json || !Json::parse(params_delta_json, delta, parse_error)) {
        g_error = "params_delta: " + parse_error;
        return SPK_ERR_USER;
    }
    std::string message, param;
    if (!validate_delta(delta, message, param)) { g_error = message; return SPK_ERR_USER; }

    std::lock_guard<std::mutex> guard(session->lock);
    spk_engine* engine = session->engine;
    const bool shoot = delta_touches_shoot(delta);
#ifndef __APPLE__
    // Reject before applying the delta, so a failed request cannot leave the
    // session's params ahead of its still-valid, previously built pipeline.
    if (const char* unported = windows_unported_delta_error(delta)) {
        g_error = unported;
        return SPK_ERR_USER;
    }
#endif
    const bool stock_change = delta.has("film_stock") || delta.has("print_stock");
    const bool rebuild = stock_change || delta_needs_rebuild(delta);
    // The live tier is the one piece of cached state a print-layer field can
    // invalidate: `preview_long_edge` changes both the size of its image and
    // the resolution its cached negative was made at. Taken before the delta
    // for the same reason the shoot flag is -- afterwards there is nothing to
    // compare against.
    const uint32_t live_edge_before = tier_long_edge(session->params, kTiers[0]);

    if (stock_change) {
        // A stock change rebuilds the parameter tree, because it needs a
        // profile load and a fresh digest. `settings` is carried across
        // deliberately: every field in it is a decision the *caller* made at
        // open, none is derived from a profile, and rebuilding it from
        // defaults is what silently replaced the GPU core with numba for the
        // rest of a session on the Python side.
        const SettingsParams settings = session->params.settings;
        Json current = read_params(session->params);
        for (const auto& kv : delta.fields()) current.set(kv.first, kv.second);
        Params fresh;
        std::string error;
        if (!init_params(engine->resources_dir,
                         current.at("film_stock").as_string(),
                         current.at("print_stock").as_string(),
                         engine->neutral_filters, fresh, error)) {
            g_error = error;
            return SPK_ERR_USER;
        }
        fresh.settings = settings;
        Json carry = Json::object();
        for (const auto& kv : current.fields())
            if (kv.first != "film_stock" && kv.first != "print_stock") carry.set(kv.first, kv.second);
        apply_delta(fresh, carry);
        // After `carry`, for the reason given at the call site in `open_frame`:
        // `init_params` has just reset the tree to the new stock's defaults,
        // and the product's defaults are not in `carry` because they have no
        // schema row to be read back through.
        apply_product_defaults(fresh, session->product_defaults);
        if (!digest(fresh, engine->neutral_filters, error)) { g_error = error; return SPK_ERR_USER; }
        session->params = fresh;
    } else {
        apply_delta(session->params, delta);
        // The one field whose meaning is a preset rather than a number: no
        // digest runs on this path, so the preset is re-read here.
        if (delta.has("antihalation_removed")) apply_halation_preset(session->params);
    }

    if (rebuild) {
        std::string error;
        auto pipeline = std::make_unique<Pipeline>(engine->gpu, &engine->colour, &engine->blob,
                                                   &engine->setup_cache);
        if (!pipeline->build(session->params, error)) { g_error = error; return SPK_ERR_USER; }
        session->pipeline = std::move(pipeline);
    } else {
        // The live path: written straight onto the pipeline's own copy, which
        // re-derives the enlarger's cheap constants on the next print run.
        session->pipeline->apply_live_delta(delta);
    }

    // `preview_long_edge` is print-layer, but it is not free: the live tier's
    // image and its negative were made at the old edge, and a tier map keyed
    // by name alone would hand them back as if they were the new size. Drop
    // the whole state -- the image is rebuilt on the next render, the negative
    // re-renders once, and `applied_ev` is reapplied with it.
    if (tier_long_edge(session->params, kTiers[0]) != live_edge_before) {
        session->tiers["live"] = spk_session::TierState{};
    }

    if (shoot || (stock_change && delta.has("film_stock"))) {
        for (auto& kv : session->tiers) {
            if (kv.second.has_negative) {
                // Dropping the handle is the whole of it: the buffer goes back
                // to the pool for the film side to reuse on the re-render.
                kv.second.negative = Image{};
                kv.second.has_negative = false;
            }
        }
    }

    Json out = Json::object();
    out.set("invalidated", Json(std::string(shoot ? "shoot" : "print")));
#ifndef __APPLE__
    if (!delta.fields().empty())
        for (auto& kv : session->tiers) kv.second.view_print = Image{};
#endif
    out.set("params", read_params(session->params));
    if (out_json) *out_json = dup_json(out);
    return SPK_OK;
}

spk_status spk_get_params(spk_session* session, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    std::lock_guard<std::mutex> guard(session->lock);
    if (out_json) *out_json = dup_json(read_params(session->params));
    return SPK_OK;
}

namespace {

// RFC-023 §8.1: the medium, measured by rendering a neutral ramp through the
// real pipeline at the session's own film, paper, enlarger and Exp. Comp. --
// never by composing profile metadata, which §15.2 measured under-predicting
// by ~30 %. What is switched off is what is stochastic, spatial across the
// ramp, or not part of the straight print: grain, halation, glare, the
// RFC-024 mask, EDR, the crop, and Scene Latitude itself. Auto-exposure is
// off because the ramp is already on the metered axis.
//
// **Glare is off although it is part of the print, and that is a measured
// trade.** It is the print's veil, and on Portra 400 + Portra Endura it moves
// the shadow boundary by 0.23 stop (-4.63 -> -4.86 EV) when the ramp is
// averaged over 16 rows. On this probe's ramp it is a stochastic field whose
// minimum sample became the "black" and put the boundary at -9.45 EV: a
// descriptor that moves between calls is worse than one that is 0.23 stop
// conservative. Halation moves neither boundary at all.
constexpr uint32_t kRampSamples = 1024, kRampRows = 8;
constexpr double kRampLo = -12.0, kRampHi = 12.0;

Params medium_probe_params(const Params& session) {
    Params p = session;
    p.camera.auto_exposure = false;
    p.camera.exposure_baseline_ev = 0.0;
    p.camera.scene_latitude.active = false;
    p.film_render.grain.active = false;
    p.film_render.grain.sublayers_active = false;
    p.film_render.halation.active = false;
    // The ramp is the medium, not a frame of film: no rebate, no date.
    p.film_render.overscan.active = false;
    p.film_render.date_imprint.active = false;
    p.print_render.glare.active = false;
    p.print_render.contrast_mask.active = false;
    p.print_render.edr_enabled = false;
    p.io.geometry = GeometryParams{};
    p.io.input_cctf_decoding = false;
    p.io.output_cctf_encoding = false;
    p.settings.striped = false;
    return p;
}

bool probe_medium(spk_session* session, slm::Medium& out, std::string& error) {
    const Params probe = medium_probe_params(session->params);
    spk_engine* engine = session->engine;
    Mat3 to_xyz;
    if (!engine->colour.matrix_RGB_to_XYZ(probe.io.output_color_space, nullptr, "CAT02", to_xyz, error))
        return false;

    std::vector<float> ramp(size_t(kRampSamples) * kRampRows * 3);
    out.ev.resize(kRampSamples);
    for (uint32_t j = 0; j < kRampSamples; ++j) {
        out.ev[j] = kRampLo + (kRampHi - kRampLo) * double(j) / double(kRampSamples - 1);
        const float v = float(slm::kMidgray * std::pow(2.0, out.ev[j]));
        for (uint32_t i = 0; i < kRampRows; ++i)
            for (int c = 0; c < 3; ++c) ramp[(size_t(i) * kRampSamples + j) * 3 + size_t(c)] = v;
    }

    Pipeline pipeline(engine->gpu, &engine->colour, &engine->blob, &engine->setup_cache);
    if (!pipeline.build(probe, error)) return false;
    pipeline.set_source_long_edge(kRampSamples, kRampSamples);
    gpu::Gpu* gpu = engine->gpu;
    Image in, negative, rgb;
    in.h = kRampRows; in.w = kRampSamples; in.c = 3;
    in.buf = gpu->upload(ramp.data(), ramp.size() * sizeof(float), error);
    if (!in.buf || !pipeline.run_film(in, negative, nullptr, error) ||
        !pipeline.run_print(negative, rgb, nullptr, error) || !gpu->flush(error)) return false;
    std::vector<float> pixels(rgb.elements());
    if (!gpu->read(rgb.buf.get(), 0, pixels.data(), rgb.bytes(), error)) return false;
    const float* px = pixels.data();
    // RFC-028: a Digital Intermediate writes Cineon log codes, not light. The
    // medium is then the DI itself -- the film's toe and the encoding's own
    // 10-bit ends -- so the codes are decoded before the luminance is taken.
    const bool di = probe.io.digital_intermediate && !probe.io.scan_film &&
                    !probe.film.info.is_positive();
    auto light = [&](float v) -> double {
        if (!di) return double(v);
        // The codes' own log scale, without Cineon's black offset: with it
        // the film base decodes to exactly 0, and a medium whose black is 0
        // has no boundary to read. This is the DI's range as the 10 bits hold
        // it -- base (code 95) to the top code.
        return std::pow(10.0, (double(v) * kDiCineonMax - kDiCineonWhite) / kDiCineonPerDecade);
    };
    out.y.assign(kRampSamples, 0.0);
    for (uint32_t i = 0; i < rgb.h; ++i)
        for (uint32_t j = 0; j < rgb.w && j < kRampSamples; ++j) {
            const float* q = px + (size_t(i) * rgb.w + j) * rgb.c;
            out.y[j] += (to_xyz.m[1][0] * light(q[0]) + to_xyz.m[1][1] * light(q[1]) +
                         to_xyz.m[1][2] * light(q[2])) / double(rgb.h);
        }
    return slm::read_boundaries(out, error);
}

Json side_json(const slm::Side& s) {
    Json j = Json::object();
    j.set("on", Json(s.on));
    j.set("pull_back", Json(s.pull_back));
    j.set("minimum_pull_back", Json(s.minimum));
    j.set("scene_extreme_ev", Json(s.extreme));
    j.set("medium_boundary_ev", Json(s.boundary));
    if (s.on) {
        j.set("knee", Json(s.knee));
        j.set("room", Json(s.room));
    }
    j.set("landing_ev", Json(s.landing));
    j.set("slope_at_extreme", Json(s.slope));
    return j;
}

}  // namespace

spk_status spk_contrast_mask_field(spk_session* session, const char* tier, const float** out_delta,
                                   uint32_t* out_grid_w, uint32_t* out_grid_h) {
    if (!session || !out_delta || !out_grid_w || !out_grid_h) {
        g_error = "session and outputs must not be null";
        return SPK_ERR_INVALID_ARG;
    }
    *out_delta = nullptr;
    *out_grid_w = *out_grid_h = 0;
    const std::string name = tier && *tier ? tier : "live";
    const Tier* t = nullptr;
    for (const Tier& k : kTiers) if (name == k.name) t = &k;
    if (!t) { g_error = "unknown tier '" + name + "'"; return SPK_ERR_INVALID_ARG; }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    // The field is analysed on the tier's cached negative, the same plane the
    // next reprint reads; it does not develop one.
    auto it = session->tiers.find(t->name);
    if (it == session->tiers.end() || !it->second.has_negative) {
        g_error = "tier '" + name + "' has no negative yet: render it first";
        return SPK_ERR_USER;
    }
    gpu::Gpu* gpu = session->engine->gpu;
    gpu->begin_frame();
    std::string error;
    uint32_t gw = 0, gh = 0;
    const bool ok = session->pipeline->contrast_mask_field(it->second.negative, session->mask_field,
                                                           gw, gh, error);
    gpu->end_frame();
    if (!ok) { g_error = error; return SPK_ERR_GPU; }
    *out_delta = session->mask_field.empty() ? nullptr : session->mask_field.data();
    *out_grid_w = gw;
    *out_grid_h = gh;
    return SPK_OK;
}

spk_status spk_overscan_geometry(spk_session* session, char** out_json) {
    if (!session || !out_json) { g_error = "session or out_json is null"; return SPK_ERR_INVALID_ARG; }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    Json reply;
    std::string parse_error;
    const std::string text = session->pipeline ? session->pipeline->overscan_geometry_json() : std::string("{\"valid\":false}");
    if (!Json::parse(text, reply, parse_error)) { g_error = "overscan geometry: " + parse_error; return SPK_ERR_INTERNAL; }
    *out_json = dup_json(reply);
    return SPK_OK;
}

spk_status spk_scene_latitude(spk_session* session, const char* request_json, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    Json request = Json::object();
    if (request_json && *request_json) {
        std::string parse_error;
        if (!Json::parse(request_json, request, parse_error) || !request.is_object()) {
            g_error = "scene latitude request: " + (parse_error.empty() ? "not an object" : parse_error);
            return SPK_ERR_INVALID_ARG;
        }
    }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();

    // The curve's own settings come from the request when given, else from the
    // session -- so a Fit can be asked "what if m were 3" without committing it.
    SceneLatitudeParams base = session->params.camera.scene_latitude;
    if (request.at("rolloff").is_number()) base.rolloff = request.at("rolloff").as_double();
    if (request.at("max_lift").is_number()) base.max_lift = request.at("max_lift").as_double();
    if (request.at("norm").is_string()) base.norm = request.at("norm").as_string();
    if (!(base.rolloff >= 1.0 && base.rolloff <= 4.0) || !(base.max_lift >= 0.25 && base.max_lift <= 12.0) ||
        !is_known_scene_latitude_norm(base.norm)) {
        g_error = "scene latitude request: rolloff must be in [1, 4], max_lift in [0.25, 12], "
                  "norm one of power, y, max";
        return SPK_ERR_USER;
    }
    const double margin = request.at("margin").as_double(0.25);
    slm::Extremes at;
    const double sp = request.at("shadow_percentile").as_double(0.1);
    const double hp = request.at("highlight_percentile").as_double(99.9);
    if ((sp != 0.1 && sp != 1.0) || (hp != 99.9 && hp != 99.0)) {
        g_error = "scene latitude request: shadow_percentile is 0.1 or 1, highlight_percentile 99.9 or 99";
        return SPK_ERR_USER;
    }
    at.shadow_p1 = sp == 1.0;
    at.highlight_p99 = hp == 99.0;

    gpu::Gpu* gpu = session->engine->gpu;
    gpu->begin_frame();
    std::string error;
    bool ok = true;

    // The medium: keyed on every wire field the probe reads, after the probe's
    // own overrides -- so a crop or a grain toggle does not re-probe, and a
    // paper, filter or Exp. Comp. change does.
    const std::string medium_key = read_params(medium_probe_params(session->params)).dump() +
                                   (session->product_defaults ? "|product" : "|reference") + "|" +
                                   spk_build_info();
    auto& cache = session->scene_latitude;
    if (cache.medium_key != medium_key || !cache.medium.valid) {
        ok = probe_medium(session, cache.medium, error);
        cache.medium_key = ok ? medium_key : std::string();
    }

    // The scene: the meter's frame, through the node's upstream nodes and the
    // session's one auto-exposure EV, on the requested norm.
    if (ok) ok = ensure_meter(session, error);
    if (ok) {
        const CameraParams& cam = session->params.camera;
        const double ev = cam.auto_exposure ? session->meter.evs.of(cam.auto_exposure_method) : cam.exposure_baseline_ev;
        char ev_text[64];
        std::snprintf(ev_text, sizeof ev_text, "%.17g", ev);
        // One frame of a pair: the scene is measured inside `region` only
        // (x0, y0, x1, y1, normalised to the frame the engine was handed).
        double region[4] = {0, 0, 1, 1};
        bool has_region = false;
        if (request.at("region").is_array() && request.at("region").items().size() == 4) {
            has_region = true;
            for (size_t k = 0; k < 4; ++k) region[k] = request.at("region").items()[k].as_double(k < 2 ? 0.0 : 1.0);
        }
        char region_text[160];
        std::snprintf(region_text, sizeof region_text, "|%.6f,%.6f,%.6f,%.6f", region[0], region[1], region[2], region[3]);
        const std::string scene_key = meter_key(session->params) + base.norm + "|" + ev_text +
                                      (has_region ? region_text : "");
        if (cache.scene_key != scene_key) {
            Image small;
            std::vector<double> E;
            ok = meter_frame(session, small, error);
            if (ok && base.norm == session->params.camera.scene_latitude.norm) {
                ok = session->pipeline->scene_latitude_sample(small, ev, E, error, has_region ? region : nullptr);
            } else if (ok) {
                // The sample reads the norm from its pipeline's params, so a
                // "what if" on another norm gets a pipeline of its own rather
                // than a rebuild of the session's.
                Params p = session->params;
                p.camera.scene_latitude.norm = base.norm;
                Pipeline sampler(gpu, &session->engine->colour, &session->engine->blob,
                                 &session->engine->setup_cache);
                ok = sampler.build(p, error) && sampler.scene_latitude_sample(small, ev, E, error, has_region ? region : nullptr);
            }
            if (ok) {
                cache.scene = slm::scene_stats(std::move(E));
                cache.scene_key = scene_key;
            }
        }
    }
    gpu->end_frame();
    if (!ok) { g_error = error; return SPK_ERR_GPU; }
    if (cache.scene.samples == 0) { g_error = "scene latitude: the frame has no positive pixels"; return SPK_ERR_USER; }

    const slm::Medium& medium = cache.medium;
    const slm::SceneStats& scene = cache.scene;
    const slm::Suggestion suggestion = slm::suggest(medium, scene, margin, base, at);
    const double nh = request.at("highlight_pull_back").is_number()
        ? request.at("highlight_pull_back").as_double() : suggestion.highlight_pull_back;
    const double ns = request.at("shadow_pull_back").is_number()
        ? request.at("shadow_pull_back").as_double() : suggestion.shadow_pull_back;
    const slm::Fit f = slm::fit(medium, scene, nh, ns, base, at);

    Json m = Json::object();
    m.set("shadow_ev", Json(medium.shadow_ev));
    m.set("highlight_ev", Json(medium.highlight_ev));
    m.set("latitude_stops", Json(medium.highlight_ev - medium.shadow_ev));
    m.set("y_black", Json(medium.y_black));
    m.set("y_white", Json(medium.y_white));
    Json ramp_ev = Json::array(), ramp_y = Json::array();
    for (size_t i = 0; i < medium.ev.size(); i += 8) {   // 128 points: enough to draw
        ramp_ev.push(Json(medium.ev[i]));
        ramp_y.push(Json(medium.y[i]));
    }
    m.set("ramp_ev", std::move(ramp_ev));
    m.set("ramp_y", std::move(ramp_y));

    Json sc = Json::object();
    sc.set("norm", Json(base.norm));
    sc.set("samples", Json(double(scene.samples)));
    sc.set("p0_1", Json(scene.p01));
    sc.set("p1", Json(scene.p1));
    sc.set("p50", Json(scene.p50));
    sc.set("p99", Json(scene.p99));
    sc.set("p99_9", Json(scene.p999));
    Json hist = Json::object(), bins = Json::array();
    hist.set("lo_ev", Json(slm::SceneStats::kLo));
    hist.set("hi_ev", Json(slm::SceneStats::kHi));
    for (double v : scene.histogram) bins.push(Json(v));
    hist.set("fractions", std::move(bins));
    // The same frame after the requested pull-backs (the UI's latitude graph),
    // on the same bins. Absent for a refused fit: there is no curve to show.
    if (f.valid()) {
        Json placed = Json::array();
        for (double v : slm::placed_histogram(scene, f.params)) placed.push(Json(v));
        hist.set("placed_fractions", std::move(placed));
    }
    sc.set("histogram", std::move(hist));

    Json sg = Json::object();
    sg.set("highlight_pull_back", Json(suggestion.highlight_pull_back));
    sg.set("shadow_pull_back", Json(suggestion.shadow_pull_back));
    sg.set("margin_used", Json(suggestion.margin_used));
    sg.set("valid", Json(suggestion.found));

    Json fj = Json::object();
    fj.set("valid", Json(f.valid()));
    Json issues = Json::array();
    for (const slm::FitIssue& is : f.issues) {
        Json e = Json::object();
        e.set("code", Json(is.code));
        e.set("side", Json(is.side));
        e.set("message", Json(is.message));
        issues.push(std::move(e));
    }
    fj.set("issues", std::move(issues));
    Json warnings = Json::array();
    for (const slm::FitIssue& is : f.warnings) {
        Json e = Json::object();
        e.set("code", Json(is.code));
        e.set("side", Json(is.side));
        e.set("message", Json(is.message));
        warnings.push(std::move(e));
    }
    fj.set("warnings", std::move(warnings));
    fj.set("highlight", side_json(f.highlight));
    fj.set("shadow", side_json(f.shadow));
    fj.set("core_stops", f.core ? Json(*f.core) : Json());
    // The delta to send with `spk_set_params` -- present only when valid, so
    // a client cannot commit a refused fit by accident.
    if (f.valid()) {
        Json delta = Json::object();
        const bool any = f.highlight.on || f.shadow.on;
        delta.set("scene_latitude_active", Json(any));
        delta.set("scene_latitude_norm", Json(f.params.norm));
        delta.set("scene_latitude_highlight_knee", Json(f.params.highlight_knee));
        delta.set("scene_latitude_highlight_room", Json(f.params.highlight_room));
        delta.set("scene_latitude_shadow_knee", Json(f.params.shadow_knee));
        delta.set("scene_latitude_shadow_room", Json(f.params.shadow_room));
        delta.set("scene_latitude_rolloff", Json(f.params.rolloff));
        delta.set("scene_latitude_max_lift", Json(f.params.max_lift));
        fj.set("params_delta", std::move(delta));
    }

    Json out = Json::object();
    out.set("medium", std::move(m));
    out.set("scene", std::move(sc));
    out.set("suggested", std::move(sg));
    out.set("fit", std::move(fj));
    if (out_json) *out_json = dup_json(out);
    return SPK_OK;
}

spk_status spk_solve(spk_session* session, const char* target, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    const std::string want = target && *target ? target : "both";
    if (want != "exposure" && want != "filter_pack" && want != "both") {
        g_error = "unknown solve target '" + want + "'";
        return SPK_ERR_USER;
    }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    Json solved = Json::object();
    // RFC-015 §3: the four intents' EVs, a *sibling* of `solved_params` rather
    // than a member of it. `solved_params` is decoded as a flat map of numbers
    // by the client, so an object in there would throw — and it would take the
    // develop's exposure solve down with it. Absent for `filter_pack`, which
    // does not meter.
    Json ev_by_method = Json::object();
    bool metered = false;

    if (want == "exposure" || want == "both") {
        // The session's one meter of the frame (RFC-015 P.1): the number
        // every tier's auto-exposure node applies, so the label, the canvas
        // and the export agree. `exposure_compensation_ev` is the session's
        // own method's; the four intents are what each would choose.
        gpu::Gpu* gpu = session->engine->gpu;
        gpu->begin_frame();
        std::string error;
        const bool ok = ensure_meter(session, error);
        gpu->end_frame();
        if (!ok) { g_error = error; return SPK_ERR_GPU; }
        const ExposureEvs& evs = session->meter.evs;
        solved.set("exposure_compensation_ev", Json(evs.of(session->params.camera.auto_exposure_method)));
        ev_by_method.set("balanced", Json(evs.balanced));
        ev_by_method.set("center", Json(evs.center));
        ev_by_method.set("protect_highlights", Json(evs.protect_highlights));
        ev_by_method.set("protect_shadows", Json(evs.protect_shadows));
        metered = true;
    }
    if (want == "filter_pack" || want == "both") {
        Params probe = session->params;
        probe.settings.neutral_print_filters_from_database = true;
        std::string error;
        if (!digest(probe, session->engine->neutral_filters, error)) {
            g_error = error;
            return SPK_ERR_INTERNAL;
        }
        solved.set("c_filter_neutral", Json(probe.enlarger.c_filter_neutral));
        solved.set("m_filter_neutral", Json(probe.enlarger.m_filter_neutral));
        solved.set("y_filter_neutral", Json(probe.enlarger.y_filter_neutral));
    }
    Json out = Json::object();
    out.set("solved_params", std::move(solved));
    if (metered) out.set("exposure_ev_by_method", std::move(ev_by_method));
    if (out_json) *out_json = dup_json(out);
    return SPK_OK;
}

void spk_cancel(spk_session* session, const char* progress_id) {
    if (!session) return;
    // Deliberately not under the session lock: the render holds that lock for
    // its whole duration, so taking it here would make cancellation wait for
    // the thing it is cancelling. `cancelled` is read between nodes.
    if (!progress_id || session->progress.progress_id == progress_id)
        session->progress.cancelled = true;
}

spk_status spk_progress(spk_session* session, const char* progress_id, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    const Progress& p = session->progress;
    if (progress_id && *progress_id && p.progress_id != progress_id) {
        g_error = std::string("unknown progress id '") + progress_id + "'";
        return SPK_ERR_USER;
    }
    Json times = Json::object();
    for (const auto& kv : p.node_ms) times.set(kv.first, Json(kv.second));
    Json out = Json::object();
    out.set("progress_id", Json(p.progress_id));
    out.set("stage", Json(p.stage));
    out.set("pct", Json(p.done ? 100.0
                               : (p.total_nodes ? 100.0 * double(p.fired) / double(p.total_nodes) : 0.0)));
    out.set("node_times", std::move(times));
    // RFC-015 P.1, additive: the EV the auto-exposure node applied to this
    // render's negative, null with the meter off.
    out.set("auto_exposure_ev", p.auto_exposure_ev ? Json(*p.auto_exposure_ev) : Json());
    // RFC-020 §3.2, additive: whether the system asked for memory back as this
    // render started. Reported and nothing else -- the mode that would act on
    // it (§4) does not exist yet.
    out.set("memory_pressure_critical", Json(p.memory_pressure_critical));
    // RFC-020 §4, step 4: the plan the executor built and the passes it ran.
    // Only present when the striped path ran, so nothing an existing consumer
    // reads changes. **Not an answer to §10.4** -- that is about whether
    // progress *granularity* follows the strips; this is inspection.
    if (!p.strips.empty()) {
        Json segments = Json::array();
        for (const Progress::StripRun& run : p.strips) {
            Json spans = Json::array();
            for (const StripSpan& span : run.plan) {
                Json row = Json::object();
                row.set("y0", Json(double(span.y0)));
                row.set("rows", Json(double(span.rows)));
                spans.push(std::move(row));
            }
            Json entry = Json::object();
            entry.set("stage", Json(run.stage));
            entry.set("passes", Json(double(run.passes)));
            entry.set("runs", Json(double(run.runs)));
            entry.set("crossings", Json(double(run.crossings)));
            entry.set("plan", std::move(spans));
            Json ran = Json::array();
            for (const Progress::StripRun::StageRun& st : run.stages) {
                Json e = Json::object();
                e.set("name", Json(st.name));
                // Two facts, and the pair is the point: `class` is a property
                // of the code (the table's entry, the same on every run), and
                // `band_able` is what **this run** resolved to. A stage wrongly
                // marked in the table and a stage legitimately sent whole-frame
                // by its parameters look identical in the second and not in the
                // first, which is why the harness pins one and reads the other.
                e.set("class", Json(st.stage_class));
                e.set("band_able", Json(st.band_able));
                e.set("resolution", Json(st.resolution));
                e.set("halo", Json(double(st.halo)));
                if (!st.swept.empty() || st.launches) {
                    // A `Swept` stage's own account of what it swept: the rows
                    // its sweeps covered, in launch order, and how many
                    // launches they cost. Filled by the sweeps, not by the
                    // executor, so it is evidence rather than echo.
                    Json bands = Json::array();
                    for (const StripSpan& b : st.swept) {
                        Json one = Json::object();
                        one.set("y0", Json(double(b.y0)));
                        one.set("rows", Json(double(b.rows)));
                        bands.push(std::move(one));
                    }
                    e.set("swept", std::move(bands));
                    e.set("launches", Json(double(st.launches)));
                }
                ran.push(std::move(e));
            }
            entry.set("stages", std::move(ran));
            segments.push(std::move(entry));
        }
        out.set("strip_segments", std::move(segments));
    }
    out.set("done", Json(p.done));
    out.set("cancelled", Json(p.cancelled));
    if (out_json) *out_json = dup_json(out);
    return SPK_OK;
}

void spk_result_free(spk_result* result) {
    if (!result || !result->texture) return;
    // The engine kept no reference to hand back, so this is the caller's own
    // +1 going away -- and with it the buffer `rgba16` pointed into.
    gpu::Gpu::release_texture_static(result->texture);
    result->texture = nullptr;
    result->rgba16 = nullptr;
}

void spk_session_release(spk_session* session) {
    if (!session) return;
    spk_engine* engine = session->engine;
    {
        std::lock_guard<std::mutex> guard(engine->lock);
        for (size_t i = 0; i < engine->sessions.size(); ++i)
            if (engine->sessions[i] == session) {
                engine->sessions.erase(engine->sessions.begin() + long(i));
                break;
            }
    }
    // Every buffer the session held is a counted handle, so destroying it is
    // all the releasing there is.
    delete session;
#ifndef __APPLE__
    // The discrete backend must not retain a multi-GB scratch arena after the
    // last photograph closes. Keep the check and trim under the same engine
    // lock as registration; retained C results own independent CPU memory.
    std::lock_guard<std::mutex> guard(engine->lock);
    if (engine->sessions.empty() && engine->gpu) {
        engine->gpu->trim_pool(0);
        engine->pool_frame_valid = false;
    }
#endif
}

}  // extern "C"

#ifndef __APPLE__
size_t spk::view::trim_idle_memory(spk_engine* engine) {
    if (!engine || !engine->gpu) return 0;
    return engine->gpu->trim_pool(0);
}
#endif
