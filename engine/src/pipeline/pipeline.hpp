// pipeline.hpp -- the render graph.
//
// A port of `runtime/pipeline.SimulationPipeline` plus the three stage objects
// and the node bodies `backends/metal/nodes.py` binds to them. The node order,
// the identity-pruning conditions and the labels are the reference's, because
// the labels are what per-node timings and a bisection over a regression are
// reported in.
//
// Two structural differences from the Python side, both deliberate:
//
// **No tap dictionary.** The Python topology is a general graph over named
// taps because it must support entering and leaving at any of them. Three
// entry/exit pairs are actually used -- RGB_IN -> CMY_FILM for the negative,
// CMY_FILM -> RGB_OUT for a reprint, RGB_IN -> RGB_OUT for a full render --
// so this exposes those three as `run_film` and `run_print` and keeps the
// order in code. Nothing is lost: the pruning decisions and the timings are
// the same.
//
// **Blur sigmas are computed per run, not per build.** The reference derives
// `lens_sigma` from `pixel_size_um` while building the topology, and
// `pixel_size_um` does not exist until the first render -- so
// `camera.lens_blur_um` is pruned unconditionally and has never done anything
// (verified: max |out(0) - out(50 um)| == 0.0 exactly). Here the pitch is a
// per-run argument, so the parameter works. That is a knowing divergence and
// the render-parity harness reports it as one.
#pragma once
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "blob.hpp"
#include "blur.hpp"
#include "cam16.hpp"
#include "colour.hpp"
#include "curves.hpp"
#include "hanatos.hpp"
#include "image.hpp"
#include "params.hpp"
#include "printing.hpp"
#include "setup_cache.hpp"
#include "spectral.hpp"

namespace spk {

/// One strip of a run: a full-width band of the plane the executor is cutting,
/// as `(y0, rows)` in that plane's own rows.
///
/// **The plan is over the plane the strips partition**, which is the plane
/// entering the striped segment -- the film side's, that is after `geometry`,
/// which is whole-frame in v1 and changes the dimensions. It is the frame's
/// own height only when geometry is a no-op, and calling it "the frame" loosely
/// is how a crop ends up off by its own offset.
struct StripSpan {
    uint32_t y0 = 0;
    uint32_t rows = 0;
};

/// A frame's dimensions, as a type rather than two loose `uint32_t`s.
///
/// `film_prefix` takes this rather than `(frame_h, frame_w)` for the reason
/// step 4 named and could not yet enforce: a signature of plain integers lets a
/// *band's* height be passed where the frame's belongs, with no compiler
/// complaint and no failing test until a micrometre-specified effect is quietly
/// wrong. The film's pitch is `frame_long_edge`'s inverse and every grain size,
/// blur radius and diffusion length downstream is measured through it.
struct FrameShape {
    uint32_t h = 0;
    uint32_t w = 0;
    uint32_t long_edge() const { return h > w ? h : w; }
};

/// A full-width band of a frame: what the executor hands a node that can be
/// striped (RFC-020 §4.2's classes P, I, F, R).
///
/// **Not an `Image`, and not convertible to one.** A whole-frame node takes
/// `const Image&` and therefore *cannot* be handed a band by accident, which is
/// §4.5's offset trap closed by the compiler rather than by a comment asking
/// for care. A striped node takes `const Strip&` and reads `y0` because there
/// is nothing else to read.
///
/// `plane` is the band's **own** buffer -- `rows()` tall and tightly packed,
/// with `plane.w` the *frame's* width, because a band is full-width by
/// construction. It is a real buffer and not a view because `image.hpp` is
/// explicit that an `Image` has no stride and no padding, and every kernel's
/// indexing depends on that; the executor pays a row copy at each crossing
/// between a whole-frame node and a striped one instead of teaching every
/// kernel an offset.
///
/// `frame_h` is the frame's, **never the band's** -- that is the whole reason
/// it is a member and not derived from `plane.h`.
struct Strip {
    Image plane;
    uint32_t y0 = 0;
    uint32_t frame_h = 0;
    uint32_t rows() const { return plane.h; }
};

// A render's progress and its cancellation flag. `cancel` is read between
// nodes, so a cancelled render unwinds at a node boundary rather than being
// abandoned mid-kernel.
//
// `node_ms` is **empty unless `detailed` is set**, and that is a correctness
// choice rather than a saving. Dispatches batch into one command buffer and
// only the final flush waits, so a wall-clock timer around a node body
// measures how long it took to *encode* -- which came out at 0.003 ms for a
// full-frame matmul, three orders of magnitude below the truth. Reporting
// those as per-node render times would put a plausible, wrong number in front
// of anyone bisecting a slow frame.
//
// With `detailed`, each node flushes before its timer stops, so the numbers
// are real GPU time and the batching is given up for the run. Set
// `SPEKTRAFILM_NODE_TIMINGS=1` to ask for it.
struct Progress {
    std::string progress_id;
    int total_nodes = 0;
    int fired = 0;
    std::string stage = "queued";
    bool cancelled = false;
    bool done = false;
    bool detailed = false;
    std::unordered_map<std::string, double> node_ms;
    // The EV the auto-exposure node applied to this render's negative;
    // empty with the meter off. `spk_progress` reports it (RFC-015 P.1), so a
    // harness can hold every tier to the same number.
    std::optional<double> auto_exposure_ev;
    // RFC-020 §4, step 4: one entry per segment the striped executor ran, with
    // the plan it built and the passes it executed. Both, because they can
    // disagree and that disagreement is a different bug from a wrong plan -- a
    // plan nothing runs is a plan nothing tested.
    //
    // Per segment rather than per render, because a `spk_render` runs two
    // (film then print) and one counter for both would make "the passes equal
    // the plan's length" unassertable, which is the whole reason it is
    // reported.
    //
    // **Not an answer to §10.4.** That question is whether strips should
    // change the *granularity a progress bar sees* (`fired`/`total_nodes`);
    // this is the plan the run used, reported for inspection. Nothing here
    // changes how often progress moves.
    struct StripRun {
        std::string stage;              // "film" or "print"
        std::vector<StripSpan> plan;
        /// Strip passes over a **band-able** run. Zero when the segment has
        /// none, which is honest rather than a failure: a stage that needs the
        /// whole plane is not run per strip, so there is no pass to count.
        uint32_t passes = 0;
        /// The stages this segment executed, in order. Reported so the two
        /// encodings of the chain order -- the straight-line calls in
        /// `film_segment` and this table -- can be held against each other.
        std::vector<std::string> stages;
    };
    std::vector<StripRun> strips;
    // RFC-020 §3.2: a critical memory-pressure event had arrived when this
    // render started. It changes nothing -- a render already encoded cannot be
    // made smaller, which is what §4's striped mode is for -- so it is read,
    // reported by `spk_progress`, and no more.
    bool memory_pressure_critical = false;
};

// RFC-015 §2.3: what each of the four exposure intents would choose, all from
// one sample. `solve` reports them together so a UI can show what each mode
// does without four round trips, and they are computed from one Y vector
// because the trim and the percentiles are shared.
struct ExposureEvs {
    double balanced = 0.0;
    double center = 0.0;
    double protect_highlights = 0.0;
    double protect_shadows = 0.0;
    // The three legacy meters, from the same sample (RFC-015 P.1): a session
    // caches all seven, so a method change does not re-meter.
    double center_weighted = 0.0;
    double average = 0.0;
    double median = 0.0;
    /// The EV for a method by its wire name.
    double of(const std::string& method) const;
};

// The two matrix conventions the transferred kernels use, named so they cannot
// be confused again (AGENTS.md trap 20). Defined in `pipeline.cpp` beside the
// comment that says why there are two; declared here because
// `spk_output_transform` marshals the same CAM16 block out over the ABI and
// must call the same helper rather than re-spell the orientation.
void row_major(const Mat3& m, double out[9]);
void transposed(const Mat3& m, double out[9]);

// The transfer-function modes, as `shaders/nodes.metal` numbers them: 0 sRGB
// (and Display P3), 1 ProPhoto RGB, 2 Adobe RGB (1998), 3 BT.709/BT.2020,
// 4 identity (the ACES spaces).
//
// One definition, called by `Pipeline::build` for the session's input and
// output spaces and by `spk_output_transform` for both ends of the transform
// the app runs. The kernels read this number and nothing else about the space,
// so two copies of this mapping would be two chances for a picture to be
// decoded with one curve and encoded with another.
uint32_t cctf_mode_for(const std::string& colour_space);

class Pipeline {
public:
    Pipeline(gpu::Gpu* gpu, const Colour* colour, const Blob* blob, SetupCache* cache)
        : gpu_(gpu), colour_(colour), blob_(blob), cache_(cache), blur_(gpu) {}
    // No destructor: every buffer it owns is a counted handle.

    // Bake everything that does not depend on a pixel or on the frame's size.
    // Expensive: the tc_lut is a 192x192x81 contraction and the C_max table is
    // 46,080 bisections, which is why `warm_up` exists to pay it early.
    bool build(const Params& params, std::string& error);

    // The film's pixel pitch, from the frame this pipeline is about to render.
    //
    // It must be set before *any* run, not just before `run_film`, and that is
    // the whole reason it is a separate call. `set_params` replaces the
    // pipeline for anything outside `LIVE_MUTABLE`, but only a *shoot*-layer
    // change drops the cached negative -- so a print-layer rebuild
    // (`scanner_lens_blur`, `output_color_space`, the filter pack, twelve
    // fields in all) left a fresh pipeline reprinting a negative it had never
    // rendered, with no pitch and no way to get one.
    //
    // `frame_long_edge` is the frame's **own** long edge, and it is the
    // reference the output-pixel parameters are measured against: they are
    // pixels at the full tier, so a smaller tier gets the same *fraction of
    // the frame* (see `node_unsharp`). Both are set at every render, so a
    // rebuilt pipeline cannot miss either.
    void set_source_long_edge(uint32_t long_edge, uint32_t frame_long_edge);

    // `Tap.RGB_IN` -> `Tap.CMY_FILM`. `out` is the developed negative.
    bool run_film(const Image& in, Image& out, Progress* progress, std::string& error);
    // `Tap.CMY_FILM` -> `Tap.RGB_OUT`.
    bool run_print(const Image& cmy, Image& out, Progress* progress, std::string& error);

    // The reference's per-input meter: what `preprocess.auto_exposure` does
    // when no session EV was set (a standalone pipeline, `warm_up`), on a
    // 256 px stride sample (`small_preview`) or, with `stride` false, on the
    // whole input. A session meters with `measure_meter_evs` instead.
    bool measure_exposure_ev(const Image& in, double& ev, std::string& error, bool stride = true);

    // RFC-015 P.1: the session's one meter of the frame. `in` is the frame at
    // the meter's own resolution; this runs the node's own upstream nodes on
    // it (input_cast, decode_input, geometry), reads the whole image back and
    // returns all seven methods' EVs. Leaves the pipeline's pitch as it was.
    bool measure_meter_evs(const Image& in, ExposureEvs& out, std::string& error);

    // The EV the auto-exposure node applies instead of metering its own
    // input. The session sets it before every film render, so every tier is
    // exposed alike; empty (a standalone pipeline, `warm_up`) meters the
    // input as the reference does.
    void set_auto_exposure_ev(std::optional<double> ev) { injected_ev_ = ev; }
    // What the node applied in the last `run_film`; empty with the meter off.
    std::optional<double> last_auto_exposure_ev() const { return last_ae_ev_; }

    // The frame's own long edge, in pixels: the reference the output-pixel
    // parameters are expressed against.
    uint32_t frame_long_edge_ = 0;

    // --- RFC-020 §4: the striped execution (step 4: every node whole-frame) --

    /// One stage: a **contiguous run** of the chain that shares a class
    /// (§4.2). Stages exist because a class boundary is where the executor has
    /// to convert between a band and the plane -- and the run is contiguous
    /// because the chain's order is the reference's. Grouping by class across
    /// a whole-frame node would mean reordering nodes, which changes the
    /// picture: `lens_blur` and `halation` sit *between* `boost` and
    /// `expose_log` in the film chain, so the pointwise nodes are two stages
    /// and not one.
    /// What a stage reads and writes. **Not one image: the film chain is not
    /// a straight line.** `log_e_film` is produced by `film_log_and_curves`
    /// and read twice -- by `film_curves` inside that stage and by
    /// `film_couplers` afterwards -- so a stage cannot be a one-in-one-out
    /// function. Threading the struct also means a crossing between a band run
    /// and a whole-frame stage has to copy every *live* field, not just `cur`.
    struct Chain {
        Image cur;         // the running image: each stage's input and output
        Image log_e_film;  // film only: live from `log_and_curves` to `couplers`
    };

    struct Stage {
        const char* name;
        /// Class P in step 5: a stage the executor may run once per strip.
        /// False means it needs the whole plane -- F/R's halos and carried
        /// recurrences, and (until step 6) the two I nodes, whose bodies hold
        /// their own blurs and so cannot be split by a stage boundary.
        bool band_able;
        bool (Pipeline::*run)(const Chain&, Chain&, std::string&);
    };
    static const Stage kFilmStages[];
    static const size_t kFilmStageCount;
    static const Stage kPrintStages[];
    static const size_t kPrintStageCount;

    // The stages, in chain order. Each one is a contiguous run of the nodes
    // the segment used to call inline, and the un-stripped path calls them in
    // this order exactly as it called the nodes -- which is what keeps the
    // two paths' sequences comparable, and the drift witnesses in
    // `strip_executor.py` exist because they are still two encodings of one
    // order.
    bool film_scale_and_expose(const Chain& in, Chain& out, std::string& error);
    bool film_blurs(const Chain& in, Chain& out, std::string& error);
    bool film_log_and_curves(const Chain& in, Chain& out, std::string& error);
    bool film_couplers(const Chain& in, Chain& out, std::string& error);
    bool film_grain(const Chain& in, Chain& out, std::string& error);
    bool print_spectral(const Chain& in, Chain& out, std::string& error);
    bool print_glare(const Chain& in, Chain& out, std::string& error);
    bool print_linear(const Chain& in, Chain& out, std::string& error);
    bool print_scan_finish(const Chain& in, Chain& out, std::string& error);
    bool print_output(const Chain& in, Chain& out, std::string& error);

    /// §7's **one policy call site**, called from exactly one place
    /// (`strip_plan`). RFC-020's body is constant: the caller's requested
    /// height, or the whole plane when it asked for none. RFC-021 replaces
    /// this body with one that derives the height from `budget_bytes` -- and
    /// because the budget is already a parameter, that is a new body and no
    /// new ABI field.
    ///
    /// `node_count` and `budget_bytes` are accepted and unused on purpose
    /// (§7: recorded in RFC-020, varied in RFC-021). Do not grow a second
    /// caller, and do not key anything on the height this returns.
    static uint32_t choose_strip_height(uint32_t plane_h, uint32_t node_count,
                                        size_t budget_bytes, uint32_t requested_rows);

    /// The plan itself: contiguous, full-width, covering `[0, plane_h)` once.
    /// Built by the executor before it runs, and reported through
    /// `Progress::strip_plan`, because a plan nothing asserts on is a plan
    /// that can be off by a row and still hash green -- with every node
    /// whole-frame the arithmetic cannot notice.
    std::vector<StripSpan> strip_plan(uint32_t plane_h) const;

    /// `run_film` / `run_print` with the striped executor in place of the
    /// single pass. What each pass actually *computes* is the same graph in
    /// step 4 (every node declares itself whole-frame), so a pass has no
    /// band-local work; that redundancy is what makes the seed hoist testable
    /// and it is a scaffold, not the shipping shape. §4.4's topology is
    /// strip-outer within segments, with whole-frame nodes materialised once
    /// per run at a segment boundary -- step 5's shape, not this one.
    bool run_film_striped(const Image& in, Image& out, Progress* progress, std::string& error);
    bool run_print_striped(const Image& cmy, Image& out, Progress* progress, std::string& error);

    // The film's pixel pitch for the frame most recently run through
    // `run_film`, in micrometres. Grain, halation and the DIR-coupler
    // diffusion are all specified in micrometres and converted with it.
    double pixel_size_um() const { return pixel_size_um_; }

    const Params& params() const { return params_; }
    // The live-mutable print fields (`print_exposure`, the filter shifts,
    // `preflash_exposure`) are written straight onto the baked copy; the print
    // side re-derives its cheap constants every run, exactly as the reference
    // does, because the service mutates them between renders.
    void apply_live_delta(const Json& delta) { apply_delta(params_, delta); }

    int node_count() const { return node_count_; }

private:
    struct Timer;

    // The meter's sample: the frame strided down, read back, and turned into
    // luminance by the auto-exposure Y row. Shared so the three legacy meters
    // and the four intents cannot disagree about what they are metering.
    bool exposure_sample_y(const Image& in, bool stride, std::vector<double>& Y,
                           uint32_t& sh, uint32_t& sw, std::string& error);
    // The three legacy meters. This arithmetic is the Python reference's and
    // does not change (RFC-015 §3) — the parity harnesses pin these three.
    static bool legacy_exposure_ev(const std::vector<double>& Y, uint32_t sh, uint32_t sw,
                                   const std::string& method, double& ev, std::string& error);
    // RFC-015 §2.3's four intents, from one sample.
    static ExposureEvs exposure_evs_from(const std::vector<double>& Y, uint32_t sh, uint32_t sw);

    /// The film side split at the one place the strips can cut it. The prefix
    /// is everything that must see the whole plane -- `geometry` changes the
    /// frame's dimensions, and the pitch it fixes is every micrometre-specified
    /// effect downstream's unit -- and the segment is what the strips cut,
    /// which is dimension-preserving throughout.
    ///
    /// `frame` is the frame's **own** shape, passed down rather than read off
    /// `cur` (§4.5 trap 1), and typed so that a band's height cannot be handed
    /// to it by mistake. In step 4 nothing can reach that line wrongly -- every
    /// node is handed a full plane, so `cur.h` *is* the frame height -- so the
    /// typing is plumbing, not a fix. **Plumbed and not yet verified**: step 5
    /// is where a band first reaches a node, and where a pitch taken from one
    /// would first bend every grain size and blur radius in the picture.
    bool film_prefix(const Image& in, const FrameShape& frame, Image& cur, std::string& error);
    bool film_segment(const Image& in, Image& out, std::string& error);
    /// The print side's split. Its prefix is the enlarger's live-mutable
    /// constants, which are host constants rather than pixels, and its segment
    /// is dimension-preserving from end to end -- so the strips cut the
    /// negative's own rows.
    bool print_prefix(std::string& error);
    bool print_segment(const Image& cmy, Image& out, std::string& error);

    // --- per-node bodies, in topology order -----------------------------
    bool node_input_cast(const Image& in, Image& out, std::string& error);
    bool node_decode_input(const Image& in, Image& out, std::string& error);
    bool node_geometry(const Image& in, Image& out, std::string& error);
    bool node_auto_exposure(const Image& in, Image& out, std::string& error);
    bool node_upsample(const Image& in, Image& out, std::string& error);
    bool node_exposure(const Image& in, Image& out, std::string& error);
    bool node_boost(const Image& in, Image& out, std::string& error);
    bool node_lens_blur(const Image& in, Image& out, std::string& error);
    bool node_halation(const Image& in, Image& out, std::string& error);
    bool node_expose_log(const Image& in, Image& out, std::string& error);
    bool node_film_curves(const Image& in, Image& out, std::string& error);
    bool node_dir_couplers(const Image& cmy, const Image& log_raw, Image& out, std::string& error);
    bool node_grain(const Image& in, Image& out, std::string& error);
    bool node_enlarger_spectral(const Image& in, Image& out, std::string& error);
    bool node_print_exposure(const Image& in, Image& out, std::string& error);
    bool node_print_curves(const Image& in, Image& out, std::string& error);
    bool node_scan_spectral(const Image& in, Image& out, std::string& error);
    bool node_bw_correction(const Image& in, Image& out, std::string& error);
    bool node_glare(const Image& in, Image& out, std::string& error);
    bool node_xyz_to_rgb(const Image& in, Image& out, std::string& error);
    bool node_edr(const Image& in, Image& out, std::string& error);
    bool node_gamut_compress(const Image& in, Image& out, std::string& error);
    bool node_scanner_blur(const Image& in, Image& out, std::string& error);
    bool node_unsharp(const Image& in, Image& out, std::string& error);
    bool node_cctf(const Image& in, Image& out, std::string& error);

    // --- helpers ---------------------------------------------------------
    bool alloc_like(const Image& img, Image& out, std::string& error);
    bool curve_interp(const Image& x, const gpu::BufferRef& xa, const gpu::BufferRef& inv,
                      const gpu::BufferRef& y, size_t k, Image& out, std::string& error);
    bool matmul3(const Image& x, const gpu::BufferRef& m, Image& out, std::string& error);
    bool spectral(const Image& cmy, const gpu::BufferRef& chd, const gpu::BufferRef& base,
                  const gpu::BufferRef& ixs, const double gain[3], const double offset[3],
                  bool log_out, size_t n_lambda, Image& out, std::string& error);
    bool lognormal_field(uint32_t h, uint32_t w, double mean, double std, uint32_t seed,
                         uint32_t stream0, bool per_channel, Image& out, std::string& error);
    bool device_max(const Image& img, double& out, std::string& error);
    bool read_back(const Image& img, std::vector<float>& out, std::string& error);
    uint32_t fresh_seed();

    // The black/white scanner references, and the two exposure corrections
    // that fall out of them (`runtime/services/color_reference.py`). All of it
    // is 1x1 spectral integrals on the host; none of it is per pixel.
    bool update_bw_references(std::string& error);
    void correction_line(double& m, double& q, double& midgray_corrected) const;

    // Enlarger-side constants that a live filter-shift edit invalidates, so
    // they are re-derived at the top of every `run_print`.
    bool refresh_print_constants(std::string& error);

    gpu::Gpu* gpu_;
    const Colour* colour_;
    const Blob* blob_;
    SetupCache* cache_;
    Blur blur_;
    Params params_;
    bool built_ = false;
    int node_count_ = 0;
    double pixel_size_um_ = 0.0;
    uint32_t source_long_edge_ = 0;
    Progress* progress_ = nullptr;
    std::optional<double> injected_ev_;
    std::optional<double> last_ae_ev_;

    // The run's seeds, drawn **once per run** rather than inside the nodes
    // (RFC-020 §4.3, trap 4). Under strips a per-node draw is a different
    // realisation per band, which is the one place a seam can appear: grain
    // and the glare field are the two nodes whose output is a random
    // realisation of the *frame*, not of a band.
    //
    // Drawn in the same order and under the same conditions as before, so the
    // un-striped path's sequence is unchanged and its picture is byte-identical
    // -- which the hash gate checks rather than assumes.
    uint32_t film_seed_ = 0;
    uint32_t print_seed_ = 0;

    // --- baked, persistent ----------------------------------------------
    struct Baked {
        gpu::BufferRef tc_lut;
        size_t tc_lut_side = 0;

        gpu::BufferRef film_curve_x, film_curve_inv, film_curve_y;
        size_t film_curve_k = 0;
        gpu::BufferRef coupler_curve_x, coupler_curve_inv, coupler_curve_y;
        gpu::BufferRef coupler_matrix, coupler_dmax, coupler_shift;

        gpu::BufferRef grain_xa, grain_inv, grain_ylay;
        gpu::BufferRef grain_streams;

        gpu::BufferRef print_curve_x, print_curve_inv, print_curve_y;
        size_t print_curve_k = 0;

        gpu::BufferRef scan_chd, scan_base, scan_ixs;
        gpu::BufferRef glare_illuminant;

        gpu::BufferRef tc_b_matrix;
        gpu::BufferRef xyz_to_rgb;
        gpu::BufferRef output_matrix;
        gpu::BufferRef edr_params;
        gpu::BufferRef edr_lut;

        gpu::BufferRef cam16_m2x, cam16_m2r, cam16_cmax, cam16_k;
        size_t cam16_nl = 0, cam16_nh = 0;
        bool cam16_lightness = false;
    } baked_;

    // --- derived on the host, refreshed per run --------------------------
    Vec film_sensitivity_;
    // The tc_lut and its matrix are kept on the host as well as on device:
    // the print exposure's midgray probe runs one pixel of grey through the
    // film model, and rebuilding a 192x192x81 contraction to do that on every
    // print run cost more than the render it was normalising.
    Vec tc_lut_host_;
    Mat3 tc_b_host_;
    PrintConstants print_constants_;
    Cam16Setup cam16_;
    Mat3 rgb_to_xyz_ae_;          // the auto-exposure meter's luminance row
    uint32_t output_cctf_mode_ = 4;
    uint32_t input_cctf_mode_ = 4;

    // print side, per run
    gpu::BufferRef print_chd_, print_base_, print_ixs_;
    double print_gain_[3] = {1, 1, 1};
    double print_offset_[3] = {0, 0, 0};
    double print_exposure_gain_[3] = {1, 1, 1};

    // black/white references
    bool bw_active_ = false;
    double y_black_ = 0.0, y_white_ = 1.0;
    double black_level_ = 0.0, white_level_ = 1.0;
    Vec log_raw_print_black_, log_raw_print_white_;
    bool have_print_references_ = false;

    uint64_t rng_state_ = 0x243F6A8885A308D3ull;
};

}  // namespace spk
