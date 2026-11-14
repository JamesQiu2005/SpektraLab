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
#include <array>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "blob.hpp"
#include "blur.hpp"
#include "cam16.hpp"
#include "colour.hpp"
#include "curves.hpp"
#include "diffusion_psf.hpp"
#include "digital_intermediate.hpp"
#include "hanatos.hpp"
#include "image.hpp"
#include "negative_hue.hpp"
#include "params.hpp"
#include "printing.hpp"
#include "scan_hdr.hpp"
#include "strip.hpp"
#include "setup_cache.hpp"
#include "spectral.hpp"

namespace spk {

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
// `SPEKTRALAB_NODE_TIMINGS=1` to ask for it.
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
        /// Band runs in this segment, and the crossings they cost: **two per
        /// run** -- one slice into it, one assembly out of it. A run has both
        /// ends in a plane even when it starts at the segment's input or ends
        /// at its output, which is the part that has been dropped twice now,
        /// once in each direction (`couplers -> grain` counted as a copy when
        /// both are whole, then print's entry and final assembly counted as
        /// neither).
        ///
        /// Counted **per run, not per strip**: the number under discussion is
        /// the number of places a plane and a band meet, and it does not grow
        /// with the plan's length. The `log_e_film` field a film crossing
        /// carries when it is live is a *separate* fact -- it is the second
        /// plane §4.4 does not know about -- and is deliberately not folded in
        /// here, because a count that mixes the two is the count that keeps
        /// slipping.
        uint32_t runs = 0;
        uint32_t crossings = 0;
        /// The stages this segment executed, in order, each with its kind.
        /// Reported so the *plan* and the *execution* can be held together:
        /// with the kinds visible, a caller can check that every strip pass
        /// belongs to a band-able run and that the runs are where the chain
        /// says they are. It is not a drift check between two orderings --
        /// there is only one, the stage table, walked by both paths.
        struct StageRun {
            std::string name;
            /// The table's class for this stage: a property of the code, the
            /// same on every run of every frame.
            std::string stage_class;
            /// What this run resolved to. False for a `Neighbourhood` stage
            /// whose demand came back `carried`, or whose halo was wider than
            /// the plane -- and that distinction is the difference between "the
            /// mode saved nothing because the code cannot" and "because these
            /// parameters cannot", which is what a user's report needs.
            bool band_able = false;
            /// **Why**, in one word, because `band_able == false` cannot tell
            /// two very different things apart:
            ///
            ///   * `"banded"` -- ran once per strip, with `halo` rows of
            ///     context;
            ///   * `"swept"` -- a neighbourhood stage whose recurrence is over
            ///     the plane (some active channel is IIR), so it runs whole and
            ///     is **already minimal**: class R removed its transposes for
            ///     every render, mode or no mode. Not a saving the mode is
            ///     missing;
            ///   * `"whole"` -- cannot be striped at all: `geometry`, `boost`,
            ///     and the nodes this RFC has not reached.
            ///
            /// The third is a gap and the second is not, and a reader deciding
            /// whether the mode is doing its job needs to know which.
            std::string resolution;
            /// The context this stage actually executed with, in rows each
            /// side: **the run's halo**, which is the sum of the run's stages'
            /// demands and not any single stage's. Reported per stage rather
            /// than per run because a run has no name of its own, and because
            /// a reader checking the sum against a stage's own radius is
            /// checking the one thing that can be silently too small.
            uint32_t halo = 0;
            /// For a `"swept"` stage: the rows its sweeps covered, in the order
            /// the sweeps ran, and how many launches that took. **Filled by the
            /// blurs that launched them, never copied from the executor's
            /// plan** -- the plan is about bands and a swept pass makes none --
            /// so a reader can see what the stage did rather than what it was
            /// handed.
            std::vector<StripSpan> swept;
            uint32_t launches = 0;
        };
        std::vector<StageRun> stages;
    };
    std::vector<StripRun> strips;
    // RFC-020 §3.2: a critical memory-pressure event had arrived when this
    // render started. It changes nothing -- a render already encoded cannot be
    // made smaller, which is what §4's striped mode is for -- so it is read,
    // reported by `spk_progress`, and no more.
    bool memory_pressure_critical = false;
    // The render's time with the Mac awake (`elapsed_ms` counts sleep too),
    // and what the GPU did for it (`Gpu::FrameStats`). Together they tell a
    // render the system held up from one that was slow: a batch log had a
    // 7 s render take 1,010 s and could say nothing more (2026-10-19).
    double awake_ms = 0;
    gpu::Gpu::FrameStats gpu;
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

// RFC-052 §6: the scene layers a session holds (`spk_set_scene_layers`), as the
// node reads them. Immutable once made -- the session swaps in a new set, it
// never edits one -- so the pipeline can hold the same set by a counted pointer
// across a rebuild without a copy of eight planes.
struct SceneLayerSet {
    static constexpr uint32_t kMaxLayers = 8;
    struct Layer {
        gpu::BufferRef plane;     // the host's id<MTLBuffer>, borrowed and retained: 16-bit unorm, row-major, top row first
        uint32_t width = 0, height = 0;
        double log_gain[3] = {0, 0, 0};   // gᵢ, natural log of a gain on the cone responses, at full coverage
        double coverage = 0.0;            // onᵢ · opacityᵢ
    };
    std::vector<Layer> layers;
    double frame_to_source[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};   // row-major, column vectors (x, y, 1)
    std::string stamp;
    // Any layer with a colour delta: a gain that is not the same on the three
    // cones, at a coverage above 0. Without one the node is a scalar gain, the
    // same operation as Film Exposure (§6.1), and no matrix runs.
    bool colour = false;
    size_t plane_bytes = 0;
};

// RFC-052 §6.1's `C = M_CAT16 · M_(working RGB → XYZ)`, for the working space
// `colour_space` (the frame's, `io.input_color_space`, at the node). One
// definition: the node uploads it and `spk_set_scene_layers` replies with it,
// so a host computing a colour gain in cone space asks the engine for the cone
// space rather than keeping its own copy of it (trap 28).
bool scene_layer_cone_matrix(const Colour& colour, const std::string& colour_space, Mat3& out,
                             std::string& error);

// RFC-052 §6.4's refusal, in one place for the session and the node: "" when a
// render whose wire says `scene_layers = wire` may run on `held` (a wire of ""
// runs on anything: the node is not dispatched), else the message naming both.
std::string scene_layers_mismatch(const std::string& wire, const SceneLayerSet* held);

// RFC-032 §27: every random and geometric choice of one overscan render,
// drawn once per run from the seeds (`overscan.cpp`). Film millimetres: `s`
// along the film, `t` across, `t = 0` at the first long edge.
struct OverscanLayout {
    bool valid = false;
    std::string format;
    double px = 0.0;                      // mm per pixel (the frame's pitch)
    uint32_t frame_w = 0, frame_h = 0;
    uint32_t canvas_w = 0, canvas_h = 0;
    bool vertical = false;                // the film runs along the image's y axis
    double gate_s0 = 0, gate_t0 = 0, gate_along = 0, gate_across = 0;
    double pair_adv = 0;                  // > 0: a half-frame pair, the same gate again this far along
    double corner = 0, penumbra = 0;
    double wob_a[4][3] = {{0}}, wob_ph[4][3] = {{0}};
    double film_w = 0;
    double A[4] = {1, 0, 0, 1};           // canvas mm (about its centre) -> film mm
    double cu = 0, cv = 0, cs = 0, ct = 0;
    double scan_rot = 0;
    bool perforated = false;
    double perf_pitch = 0, perf_w = 0, perf_h = 0, perf_edge = 0, perf_r = 0, perf_phase = 0;
    double fog_amp = 0, fog_width = 0.5, fog_period = 8.0;
    uint32_t fog_seed = 0;
    struct Leak { double s = 0; int side = 0; double amp = 0, sig_s = 1, sig_t = 1; };
    std::vector<Leak> leaks;
    double fog_rgb[3] = {1, 1, 1}, date_rgb[3] = {1, 1, 0}, edge_rgb[3] = {1, 1, 0};
    double hole_cmy[3] = {0, 0, 0};
    double flare_amp = 0, flare_width = 0.05;
    // RFC-032 §29: the gate's own shape -- corner radii (s-,t-), (s+,t-),
    // (s+,t+), (s-,t+); convex quads added to (+1) or cut from (-1) the
    // opening, film mm; the machined edge's roughness.
    std::string gate_family;
    double gate_r[4] = {0, 0, 0, 0};
    struct Quad { double pts[8] = {0}; double round = 0; double sign = 1; };
    std::vector<Quad> quads;
    double rough_amp = 0, rough_period = 0.15;
    uint32_t rough_seed = 0;
    double top_recess = 0;                // how far the t- side's middle sits back from its ears (shouldered)
    bool holes_light = false;
    bool carrier_open = false;            // past the film's long edges: the scan's light, not a black carrier
    bool carrier_none = false;            // no carrier: the canvas ends at the film's edge
    double light_rgb[3] = {1, 1, 1};      // the backlight through the scan, linear output RGB
    double light_fall = 0, light_dir = 0; // the light panel's falloff across the canvas
    uint32_t perf_seed = 0;               // per-hole punch tolerances, burrs, wall slant
    // RFC-032 §31: the base's thickness at a perforation's cut wall
    double wall_t = 0.13;                 // base thickness, mm
    double wall_tilt[2] = {0, 0};         // the scan's viewing tilt, tan(angle) along (s, t)
    double wall_parallax = 0;             // 1 / the scan's viewing distance, 1/mm
    double base_rgb[3] = {1, 1, 1};       // the base's transmittance colour, linear output RGB
    double wall_glow = 0;                 // black holes: the wall's rim brightness
    double wall_scatter = 0.02;           // light scattered in the base widens the wall, mm
    // API-SPEC §21.3 (2026-11-09): `perforated` keeps meaning "a 135 layout"
    // (its fog, its edge print, its gate radii); `holes` is whether the film
    // has perforations at all -- a 135 layout, or 120 cut from 65 mm cine
    // film (`ks65`). The kernels read `holes`.
    bool holes = false;
    double perf_dt = 0;                   // both rows shifted across the film (ks65: the slitter's offset), mm
    // API-SPEC §21.4: the lens's cos^n falloff over the picture; 0 = none.
    double falloff = 0, falloff_f = 50, falloff_n = 4;
    // API-SPEC §21.1: the camera's light leak as this frame shows it. kind 0 =
    // none (off, or this frame does not show it); 1 band, 2 wash, 3 spot.
    struct BigLeak {
        int kind = 0;
        double amp = 0;                   // raw exposure at the peak, before the across-film profile
        double sc = 0, st = 0;            // band centre / wash's leaking end / spot centre (s), spot centre (t)
        int edge = 0;                     // the bright long edge: 0 at t = 0, 1 at t = film_w
        double sig_a = 1, sig_b = 1;      // band: the soft side's and the sharp side's sigma, mm
        double dir = 1;                   // band: the soft side's direction along s; wash: into the frame
        double tilt = 0;                  // tan of the band's tilt off square
        double front = 0;                 // the share of front light (the core's)
        double lambda = 30;               // the decay across the film from the bright edge, mm
        double len = 10;                  // wash: decay length; spot: radius, mm
        double core = 1;                  // band: the front light's sigma, mm
    } leak;
    double leak_rear_rgb[3] = {1, 0, 0}, leak_front_rgb[3] = {1, 1, 1};
    // API-SPEC §21.4: Fujifilm's edge stripes (X-Tra 400, Pro 400H; every 135-gauge format).
    bool stripes = false;
    double stripe_g_rgb[3] = {0, 1, 0}, stripe_r_rgb[3] = {1, 0, 0};
};

class Pipeline {
public:
    Pipeline(gpu::Gpu* gpu, const Colour* colour, const Blob* blob, SetupCache* cache)
        : gpu_(gpu), colour_(colour), blob_(blob), cache_(cache), blur_(gpu) {}
    // No destructor: every buffer it owns is a counted handle.

    // Bake everything that does not depend on a pixel or on the frame's size.
    // Expensive: the tc_lut is a 192x192x81 contraction and the C_max table is
    // 46,080 bisections, which is why `warm_up` exists to pay it early.
    bool build(const Params& params, std::string& error);

    // RFC-032 §27: the film canvas's layout for the frame a negative was made
    // from, set before a print run that may not follow this pipeline's own
    // film run -- a reprint after a print-layer rebuild, or of another tier's
    // negative. The layout is drawn from the seeds, the frame's size and the
    // pitch, so making it again is making the same one. `overscan_frame` is
    // the frame the last film run laid out (zero without overscan), which is
    // what the caller keeps beside the negative. Call the setter after
    // `set_source_long_edge`.
    void overscan_frame(uint32_t& frame_w, uint32_t& frame_h) const;
    std::string overscan_geometry_json() const;
    bool set_overscan_frame(uint32_t frame_w, uint32_t frame_h, std::string& error);
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
    // Fixed cut immediately before grain; restored storage is moved into the
    // chain, so the caller cannot accidentally retain it through downstream work.
    bool run_film_checkpoint(const Image& in, Image& out, Image* restored,
                             std::optional<double> cached_ev,
                             const std::function<void(const Image&, double)>& observe,
                             Progress* progress, std::string& error);

    // `Tap.CMY_FILM` -> `Tap.RGB_OUT`.
    bool run_print(const Image& cmy, Image& out, Progress* progress, std::string& error);
    // **The output encode can ride in the caller's last pass.** A render that goes straight to the
    // 16-bit canvas buffer wrote the encoded float frame only to read it once and quantise it
    // (4.8 ms at 45 MP). With this set, `run_print` (not the striped one's bands) returns the
    // frame linear and marks the encode pending; the caller takes it with `take_pending_encode`
    // and runs `spk_cctf_to_rgba16`, which is the encode and the quantisation in one kernel, the
    // same bits. A caller that wants the float frame leaves this off, which is the default.
    void set_defer_encode(bool on) { defer_encode_ = on; }
    bool take_pending_encode(gpu::BufferRef& matrix, uint32_t& mode);

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

    // RFC-024: the mask this print would apply, as the delta in stops at each
    // cell of its analysis grid (`gw` x `gh`, row-major, the frame's own
    // aspect). Empty with the mask off. Runs the analysis only -- no print --
    // and leaves the pipeline's print state as it was.
    bool contrast_mask_field(const Image& cmy, std::vector<float>& delta, uint32_t& gw,
                             uint32_t& gh, std::string& error);

    // RFC-023 §9.1: the scene on Scene Latitude's own axis -- stops of the
    // node's norm relative to the metered mid-grey -- for every pixel of `in`
    // (the frame at the meter's resolution) after the node's upstream nodes
    // and the auto-exposure gain `ev`. Leaves the pipeline's pitch as it was,
    // as `measure_meter_evs` does. `channels`, when given, also gets each of
    // R, G and B by itself in stops about the same mid-grey (RFC-035 §5.2),
    // over the same pixels, each leaving out its own non-positive values.
    //
    // RFC-051: `curved`, when given, also gets the same pixels after the scene
    // transform the render applies before the film (`node_scene_latitude`,
    // then `node_scene_curve`, each where it is wanted), on the same axis.
    // `present` is false, and the rows empty, when neither is wanted.
    struct SceneSample {
        bool present = false;
        std::vector<double> E;
        std::array<std::vector<double>, 3> channels;
    };
    bool scene_latitude_sample(const Image& in, double ev, std::vector<double>& E,
                               std::string& error, const double* region = nullptr,
                               std::array<std::vector<double>, 3>* channels = nullptr,
                               SceneSample* curved = nullptr);

    // The EV the auto-exposure node applies instead of metering its own
    // input. The session sets it before every film render, so every tier is
    // exposed alike; empty (a standalone pipeline, `warm_up`) meters the
    // input as the reference does.
    void set_auto_exposure_ev(std::optional<double> ev) { injected_ev_ = ev; }
    // RFC-052 §6: the session's scene layers, handed before every film render
    // as the EV above is (a rebuild makes a pipeline that has never seen
    // them). Null, or a set whose stamp is not the wire's, refuses a render
    // whose `camera.scene_layers` is not "".
    void set_scene_layers(std::shared_ptr<const SceneLayerSet> set) { scene_layers_ = std::move(set); }
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

    // **A step 6 consequence, written down where the crossings are.** At the
    // `film_log_and_curves -> film_couplers` crossing, `cur` *and* `log_e_film`
    // must be planes at the same moment, so that boundary holds one more full
    // plane than §4.4's memory table accounts for -- its nine-plane count was
    // built from a straight-line reading of the graph, and §4.2's table reads
    // every node as one-in-one-out, which only `node_dir_couplers` is not. At
    // 102 MP that is 1.22 GB at a crossing the estimate does not know about.
    // Step 5 does not care (everything is whole-frame); step 6's measurement is
    // where to look for it.
    //
    /// A stage's demand is its blurs' demand: `Blur::Demand` is the type the
    /// FIR/IIR rule produces, and re-spelling it here would be a second place
    /// the crossover lives.
    ///
    /// **It is resolved from this run's parameters rather than read from the
    /// table**, because F and R are not node properties: they are the two
    /// branches of one blur call, chosen per channel by sigma (`sigma < 3.0` is
    /// FIR, `>= 3` the YvV IIR). Halation's three channels routinely straddle
    /// the crossover, so "is this stage band-able" is a question about the run,
    /// and a table cannot answer it: the same `film_blurs` is strippable at
    /// `lens_blur_um = 4` and whole-frame at `lens_blur_um = 40`.
    ///
    /// A `carried` demand is the escape hatch doing its job (§4.6): the stage
    /// declares itself whole-frame for this run and the mode simply saves less.
    /// That is exact rather than approximate, and it stays exact until step 6's
    /// R half replaces it with the carried state.
    enum class StageClass {
        /// Band-able with no boundary maths at all: RFC-020's class P, and
        /// class I once §4.5's global-row offset is plumbed through to the
        /// kernels (step 6's second half).
        Pointwise,
        /// Band-able when `demand` says every active channel takes the FIR
        /// branch, with `demand.halo` rows of context. Otherwise whole-frame.
        Neighbourhood,
        /// Never band-able: `geometry` (a rotated source rect), `boost` (an
        /// image-global reduction), and every node this RFC has not striped.
        Whole,
    };

    struct Stage {
        const char* name;
        /// **The class is a property of the code and does not vary between
        /// runs.** `demand` below is what varies, and the two must stay
        /// distinguishable: a stage wrongly marked here can otherwise hide
        /// behind "it resolved to whole for that run", which a reader cannot
        /// tell apart from a legitimate IIR resolution. So `spk_progress`
        /// reports both -- this, pinned by the harness, and the resolved
        /// `band_able`, which explains the run.
        StageClass klass;
        bool (Pipeline::*run)(const Chain&, Chain&, std::string&);
        /// Non-null exactly for `Neighbourhood` stages. Called once per run,
        /// before any strip executes, because the answer decides the plan's
        /// crossings -- a demand consulted mid-run would be a crossing chosen
        /// after the copy it governs.
        Blur::Demand (Pipeline::*demand)() const;
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
    bool film_boost(const Chain& in, Chain& out, std::string& error);
    bool film_overscan(const Chain& in, Chain& out, std::string& error);
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

    /// What a band read actually took: the strip it is *for*, and the rows it
    /// actually holds, which are the strip's plus `halo` each side **clamped to
    /// the plane**. One type rather than loose `uint32_t`s for §4.5's reason --
    /// this pair has to agree with itself at the write-back, and a pair of
    /// integers is exactly the shape that lets them drift one apart.
    struct BandRead {
        StripSpan span;      ///< the strip this band is for
        uint32_t y0 = 0;     ///< the band's first row, in the plane
        uint32_t rows = 0;   ///< rows the band holds, after clamping
        uint32_t offset() const { return span.y0 - y0; }
    };

    /// Copy a band's rows out of a whole plane, into a band-sized buffer.
    /// The copy is the price of `image.hpp`'s no-stride contract, paid once per
    /// live field at each crossing where the kind changes.
    ///
    /// `halo` is the run's context, in rows, and it is **clamped at the plane's
    /// own edges**. That clamping is what makes the existing FIR kernel exact
    /// on a band without changing a line of it: an interior band's kept rows
    /// never reflect inside the band's own support, and an edge band's buffer
    /// edge *is* the plane's edge, where the kernel's `reflect_index` over the
    /// band's smaller `nlim` lands on the same source row as the full plane's
    /// would. Nothing here approximates anything.
    bool band_from(const Image& plane, const StripSpan& span, uint32_t halo, BandRead& read,
                   Image& out, std::string& error);
    /// And back: the strip's rows -- not the band's, which are the strip's plus
    /// the halo -- into the plane at the band's own offset.
    bool band_into(const Image& band, const BandRead& read, Image& plane, std::string& error);

    /// Walk a stage table over a plan: a band-able run once per strip, a plane
    /// stage once for the frame, and the **crossings derived from the kinds**
    /// rather than listed beside the chain -- so `choose_strip_height` stays the
    /// only place a size is chosen, which is what §7 owes RFC-021.
    bool run_stages_striped(const Stage* stages, size_t count, Chain& chain,
                            const std::vector<StripSpan>& plan, Progress::StripRun& report,
                            std::string& error);

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

    /// The film seed of the last film run (a cached negative's realisation),
    /// for `spk_progress`'s `film_seed`.
    uint32_t film_seed() const { return film_seed_; }
    /// `scan_hdr` (2026-11-06): the slide's HDR scan
    /// this pipeline was built with -- inactive for today's scan, which is
    /// every other build.
    const ScanHdrModel& scan_hdr() const { return scan_hdr_; }

    // --- API-SPEC §21.5-§21.6: the lens (`lens.cpp`) ------------------------------------
    //
    // The diffusion filter and the lens aberrations, as a pass on the source
    // before the chain (the owner, 2026-11-10): `lens_source` lenses a tier's
    // source image -- in linear light, the axis at its centre, the pitch the
    // format's at its long edge -- into `out` (file-backed when asked: the
    // full tier's copy, as the session's source is). `out` is `src` itself
    // while the lens is off or does nothing at this pitch. `exact`: the filter
    // by the exact (slow) path, the tests' reference.
    bool film_lens_wanted() const;
    /// Sets this pipeline's params to `params`: call it on a pipeline of its own.
    /// `reuse`: the previous setting's copy of this source, written over when
    /// it is the frame's size (a slider's drag: no new pages).
    bool lens_source(const Params& params, const Image& src, bool file_backed, Image& out, std::string& error,
                     bool exact = false, const Image* reuse = nullptr);
    /// The test seam (`spk_lens_probe`, not in a hardened build): `lens_source`
    /// on a linear image at `pixel_um` per px, its chunks `chunk_rows` tall (0:
    /// its own); `fit_info` (4 doubles, may be null) gets the pyramid's levels
    /// and its LSF fit's rms per channel.
    bool lens_probe(const Params& params, double pixel_um, const Image& in, bool exact, uint32_t chunk_rows,
                    Image& out, double* fit_info, std::string& error, const Image* reuse = nullptr);

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

    // --- what a neighbourhood stage needs from a boundary ----------------
    // One demand per `Neighbourhood` stage, computed from **the same parameter
    // arithmetic the node bodies use**. The sigmas are factored out just below
    // so that a node and its own demand cannot disagree about what will run: a
    // halo a row short is a seam in the picture, and a `carried` that disagrees
    // with the branch the kernel takes is a different picture, and neither has
    // a second place to come from.
    Blur::Demand film_blurs_demand() const;
    Blur::Demand film_couplers_demand() const;
    Blur::Demand print_scan_finish_demand() const;
    /// The class as it appears in `spk_progress` -- "pointwise",
    /// "neighbourhood", "whole". One spelling, next to the enum, so a reader
    /// and a harness cannot disagree about which string means which value.
    static const char* class_name(StageClass klass);

    /// The blur plans the F nodes actually run, derived from this run's
    /// parameters. Each returns an empty list when its node's own guard would
    /// take the identity path, so a demand can never ask for context a stage
    /// will not use -- and, the other way, can never miss one it will.
    struct HalationBlurs {
        std::vector<Blur::Component> scatter;  ///< empty when the guard says no
        std::vector<Blur::Component> bounces;
    };
    HalationBlurs halation_blurs() const;
    std::vector<Blur::Component> dir_coupler_diffusion() const;
    /// The sigma `node_lens_blur` blurs with -- one number, three channels --
    /// and the ones the print side's two sharpening nodes use.
    double lens_blur_sigma() const;
    double scanner_blur_sigma() const;
    double unsharp_sigma() const;
    /// `source_long_edge_ / frame_long_edge_`: the full tier's long edge over
    /// this render's, which is what turns a parameter stated as a fraction of
    /// the frame into this frame's pixels.
    double tier_ratio() const;

    // --- per-node bodies, in topology order -----------------------------
    bool node_input_cast(const Image& in, Image& out, std::string& error);
    bool node_decode_input(const Image& in, Image& out, std::string& error);
    bool node_geometry(const Image& in, Image& out, std::string& error);
    bool node_auto_exposure(const Image& in, Image& out, std::string& error);
    bool node_upsample(const Image& in, Image& out, std::string& error);
    bool node_exposure(const Image& in, Image& out, std::string& error);
    bool node_upsample_expose(const Image& in, Image& out, std::string& error);   // the two, one kernel
    bool node_boost(const Image& in, Image& out, std::string& error);
    bool node_headroom(const Image& in, Image& out, std::string& error);
    // RFC-032 §27 / RFC-031 (`overscan.cpp`): the film canvas, its imprints,
    // and the no-film mask at the start of the print side. Not in the graph
    // while off.
    bool overscan_wanted() const;
    double overscan_gate_long_mm() const;
    bool overscan_layout(uint32_t frame_w, uint32_t frame_h, std::string& error);
    void overscan_params_block(std::vector<float>& P) const;
    bool node_overscan(const Image& in, Image& out, std::string& error);
    bool node_overscan_film_present(const Image& in, Image& out, std::string& error);
    bool node_overscan_light(const Image& in, Image& out, std::string& error);
    bool node_lens_blur(const Image& in, Image& out, std::string& error);
    // --- API-SPEC §21.5-§21.6: the lens pass (lens.cpp) --------------------------------
    /// Where the lens's axis is in the image a pass is handed (a chunk of the
    /// frame's rows, or all of it), pixel centres on the integers, and the pitch.
    struct LensGeom {
        double pcx = 0.0, pcy = 0.0;   ///< the source frame's centre
        double hd = 1.0;               ///< the source frame's half-diagonal, px
        double um_per_px = 0.0;        ///< micrometres on the film per px
        uint32_t row0 = 0;             ///< the frame row of the image's row 0
        uint32_t plane_h = 0;          ///< the frame's rows
    };
    /// The aberrations' field sizes in px at h = 1.
    struct LensFieldPx {
        double sfc = 0.0, sast = 0.0, coma = 0.0;
        double var_t1 = 0.0, var_r1 = 0.0;
        bool tangential = false, radial = false;
        int lmax = 0;
    };
    struct LensPyramid {
        Image lv[5];
        int I0[5] = {}, LH[5] = {}, LW[5] = {};
        int levels = 0;
    };
    /// A chunk of the frame's rows that `lens_aberrate_frame` hands a pass:
    /// the frame's size and the chunk's first row. The desktop has no
    /// RFC-035 band context, so the lens keeps its own (inactive = the image
    /// is the whole frame).
    struct LensChunk {
        bool active = false;
        uint32_t frame_w = 0, frame_h = 0, row0 = 0;
    };
    LensGeom lens_geom(const Image& in) const;
    double lens_pitch_um(uint32_t w, uint32_t h) const;
    bool diffusion_components(double um_per_px, double& p_s, std::vector<Blur::Component>& comps,
                              std::string& error) const;
    bool lens_glow(double um_per_px, double& w, double& sigma) const;
    bool lens_mixture_now(double um_per_px, double a[3], std::vector<Blur::Component>& comps,
                          std::string& error) const;
    bool lens_pyramid_fit(double um_per_px, uint32_t w, uint32_t h, double a_id[3],
                          diffusion::PyramidFit& fit, std::string& error) const;
    bool lens_scatter_source(const Image& E, float bp[5], std::string& error);
    bool lens_filter_fast(const Image& E, Image& out, std::string& error);
    bool lens_filter_exact(const Image& raw, Image& out, std::string& error);
    bool lens_glow_fast(const Image& X, Image& out, std::string& error);
    LensFieldPx lens_field_px(double um_per_px) const;
    bool lens_aberrations_wanted(double um_per_px) const;
    double lens_aberration_reach(double um_per_px, double hd) const;
    bool lens_pyramid(const Image& base, const LensGeom& G, int lmax, LensPyramid& P, std::string& error);
    bool lens_line(const LensPyramid& P, const LensGeom& G, const LensFieldPx& F, uint32_t mode, Image& out,
                   std::string& error);
    bool lens_aberrate(Image in, Image& out, std::string& error);
    bool lens_aberrate_frame(const Image& src, Image& out, std::string& error);
    uint32_t lens_chunk_rows() const;
    bool node_halation(const Image& in, Image& out, std::string& error);
    bool node_expose_log(const Image& in, Image& out, std::string& error);
    bool node_film_curves(const Image& in, Image& out, std::string& error);
    bool node_log_and_curves(const Image& in, Image& log, Image& cmy, std::string& error);   // the two, one kernel
    bool node_dir_couplers(const Image& cmy, const Image& log_raw, Image& out, std::string& error);
    bool node_grain(const Image& in, Image& out, std::string& error);
    /// The grain model itself; `node_grain` is this plus RFC-025's strength.
    bool grain_realise(const Image& in, Image& out, std::string& error);
    bool node_enlarger_spectral(const Image& in, Image& out, std::string& error);
    bool node_print_exposure(const Image& in, Image& out, std::string& error);
    bool node_print_curves(const Image& in, Image& out, std::string& error);

    // RFC-023's Scene Latitude Mapping (`scene_latitude.cpp`): pointwise,
    // before `node_upsample`, and not dispatched at all while it is off.
    bool scene_latitude_wanted() const;
    bool node_scene_latitude(const Image& in, Image& out, std::string& error);
    // The Decode curve (`scene_latitude.cpp`, API-SPEC §17): pointwise, after
    // Scene Latitude and before `node_upsample`, on the same stop axis; not
    // dispatched while `camera.scene_curve` is "".
    bool scene_curve_wanted() const;
    bool node_scene_curve(const Image& in, Image& out, std::string& error);
    // RFC-052 §6's 场景 layers (`scene_layers.cpp`, API-SPEC §23): pointwise,
    // after Scene Latitude and before the Decode curve; not dispatched while
    // `camera.scene_layers` is "".
    bool scene_layers_wanted() const;
    bool node_scene_layers(const Image& in, Image& out, std::string& error);
    // The geometry node's constants for `g` on an `in_h` x `in_w` frame, as
    // `spk_geometry_resample_df` reads them: `consts` the eight (hi, lo)
    // pairs, `meta` {SH, SW, OH, OW, turns, flips}. One function, read by
    // `node_geometry` and by `node_scene_layers`, so the mask is mapped through
    // the cut by the arithmetic that cut the picture.
    static void geometry_constants(const GeometryParams& g, uint32_t in_h, uint32_t in_w, float consts[16],
                                   uint32_t meta[6]);

    // RFC-024's virtual contrast mask (`contrast_mask.cpp`). `prepare` runs
    // once per print run on the whole negative, after `print_prefix`; the
    // epilogue replaces `node_enlarger_spectral` in `print_spectral` only
    // while `mask_on_` is set, and is pointwise, so it bands.
    bool contrast_mask_wanted() const;
    bool prepare_contrast_mask(const Image& cmy, std::string& error,
                               std::vector<float>* delta_out = nullptr);
    void release_contrast_mask();
    bool node_contrast_mask_epilogue(const Image& in, Image& out, std::string& error);
    bool node_scan_spectral(const Image& in, Image& out, std::string& error);
    // RFC-028: the Digital Intermediate, in place of the whole paper and scan.
    bool node_digital_intermediate(const Image& in, Image& out, std::string& error);
    bool node_bw_correction(const Image& in, Image& out, std::string& error);
    bool node_glare(const Image& in, Image& out, std::string& error);
    bool node_xyz_gamut(const Image& in, Image& out, std::string& error);
    bool node_minilab(const Image& in, Image& out, std::string& error);
    // The print's hue, from the negative (core/negative_hue.hpp): every pair no table covers.
    bool node_negative_hue(const Image& negative, const Image& in, Image& out, std::string& error);
    bool node_xyz_to_rgb(const Image& in, Image& out, std::string& error);
    bool node_edr(const Image& in, Image& out, std::string& error);
    bool node_gamut_compress(const Image& in, Image& out, std::string& error);
    bool node_scan_hdr_scale(const Image& in, Image& out, std::string& error);
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

    // A spectral integral's tables with the dead wavelengths taken out (`spectral_rows`).
    struct SpectralRows { gpu::BufferRef chd, base, ixs; uint32_t n = 0; };
    bool spectral_rows(const Vec& chd, const Vec& base, const Vec& ixs, SpectralRows& out, std::string& error);
    SpectralRows print_rows_, scan_rows_, di_rows_;
    gpu::BufferRef minilab_table_;
    uint32_t minilab_side_ = 0;
    float minilab_lo_[3]{}, minilab_inv_[3]{};
    bool minilab_active_ = false;
    // The enlarger's live controls on a minilab pair: the epilogue of `spk_minilab` (pipeline.cpp).
    bool minilab_enlarger(float ep[6], std::string& error);
    // core/negative_hue.hpp. Built with the pipeline; the filters' offsets are per print run.
    NegativeHue negative_hue_;
    bool negative_hue_active_ = false;
    gpu::BufferRef negative_hue_layers_, negative_hue_gamut_, negative_hue_map_;
    bool negative_hue_offsets(double out[3], std::string& error);
    bool negative_hue_params(float p[60], std::string& error);
    // The optical print as one pass, where nothing needs the planes between its nodes.
    bool print_fused_wanted() const;
    bool node_print_fused(const Image& in, Image& out, std::string& error);
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
    std::shared_ptr<const SceneLayerSet> scene_layers_;
    // The frame `node_geometry` was last handed (the tier's source, before the
    // cut): the scene layers' node maps its pixels back through the cut into it.
    uint32_t geometry_in_h_ = 0, geometry_in_w_ = 0;

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
    // `grain_seed` (`settings.film_seed`): the film seed a run draws -- the
    // wire's when it names one, else a fresh one. Both film-side draw sites
    // (`film_prefix` and the pre-grain checkpoint's restore) go through it, so
    // a restored develop and a fresh one carry the same grain under one seed.
    uint32_t draw_film_seed();

    // `scan_hdr` (core/scan_hdr.hpp): built with the film's curves, read by
    // the scan and by `spk_progress`.
    ScanHdrModel scan_hdr_;

    // RFC-032 §27: kept across a reprint of the cached negative, which the
    // print side's no-film mask must match pixel for pixel.
    Image factory_exposure_; // only alive from mark rasterization through film_blurs
    OverscanLayout overscan_;
    double frame_w_mm_ = 0.0, frame_h_mm_ = 0.0;

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
        gpu::BufferRef scan_hdr_table;   // {dk, s} x 3, only with `scan_hdr_` active
        gpu::BufferRef scan_hdr_scale;   // diag(output_scale), the HDR rendition's
        gpu::BufferRef glare_illuminant;

        gpu::BufferRef tc_b_matrix;
        gpu::BufferRef xyz_to_rgb;
        gpu::BufferRef output_matrix;
        gpu::BufferRef edr_params;
        gpu::BufferRef edr_lut;

        gpu::BufferRef cam16_m2x, cam16_m2r, cam16_cmax, cam16_k;
        size_t cam16_nl = 0, cam16_nh = 0;
        bool cam16_lightness = false;

        // RFC-028's Digital Intermediate
        gpu::BufferRef di_chd, di_zero_base, di_ixs;
        gpu::BufferRef di_curve_x, di_curve_inv, di_curve_y;
    } baked_;

    // RFC-028: on when the DI replaces the paper (negative film, no scan_film).
    bool di_active_ = false;
    DiConstants di_;

    // --- derived on the host, refreshed per run --------------------------
    Vec film_sensitivity_;
    Vec film_sensitivity_edge_;   // without the lens's colour filter (overscan.cpp)
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
    // The output encode, left to the caller's quantising pass (`set_defer_encode`).
    bool defer_encode_ = false;
    bool encode_pending_ = false;
    uint32_t input_cctf_mode_ = 4;

    // print side, per run
    gpu::BufferRef print_chd_, print_base_, print_ixs_;
    double print_gain_[3] = {1, 1, 1};
    double print_offset_[3] = {0, 0, 0};
    double print_exposure_gain_[3] = {1, 1, 1};

    // RFC-024, per print run: the prepared field and the parameter block both
    // mask kernels read. The coefficients are a frame-arena buffer, dropped at
    // the end of the run that made them.
    bool mask_on_ = false;
    gpu::BufferRef mask_coef_;
    uint32_t mask_gw_ = 0, mask_gh_ = 0, mask_frame_w_ = 0, mask_frame_h_ = 0;
    float mask_params_[16] = {};
    // The first row, in the plane, of the band a band-able stage is running
    // on; 0 on the un-striped path. Set by `run_stages_striped` -- the one
    // node that needs a frame coordinate reads it rather than every stage
    // growing a `Strip` argument.
    uint32_t band_row0_ = 0;
    // API-SPEC §21.5-§21.6: the pitch the lens pass is running at (lens.cpp).
    double lens_um_per_px_ = 0.0;
    // The rows its chunks take (0: its own 512); set only by `lens_probe`.
    uint32_t lens_chunk_rows_ = 0;
    // The chunk the lens's aberrations are running on (`lens_aberrate_frame`).
    LensChunk lens_chunk_;
    // The height of that plane, with it; 0 on the un-striped path. A pair's
    // Scene Placement reads it: where its second frame starts is a fraction of
    // the frame, not of the strip.
    uint32_t strip_plane_h_ = 0;

    // black/white references
    bool bw_active_ = false;
    double y_black_ = 0.0, y_white_ = 1.0;
    double black_level_ = 0.0, white_level_ = 1.0;
    Vec log_raw_print_black_, log_raw_print_white_;
    bool have_print_references_ = false;

    uint64_t rng_state_ = 0x243F6A8885A308D3ull;
};

}  // namespace spk
