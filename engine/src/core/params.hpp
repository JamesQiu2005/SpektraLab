// params.hpp -- the parameter tree, the transport schema, and delta application.
//
// Two things live here, and keeping them together is deliberate.
//
// `Params` is the port of `runtime/params_schema.RuntimePhotoParams`: the
// whole tree the pipeline reads, with the same defaults. `digest()` is
// `params_builder.digest_params` -- the stock-specific overrides, the halation
// preset, and the debug switches -- and it must run before a pipeline is built,
// exactly as it does today.
//
// The `Schema` half is the port of `service/schema.py`: the **declared,
// versioned subset** that crosses the wire. It is not a serialisation of
// whatever fields the tree happens to have. Every entry carries its layer, and
// that is the whole point: a `shoot`-layer change invalidates the cached
// negative and forces a film-side re-render, a `print`-layer change does not.
// Getting a field's layer wrong is a correctness bug, not a metadata one --
// it would let a shoot-side edit silently reuse a stale negative.
//
// The field table below is the same 45 rows, in the same order, with the same
// names, types, layers and ranges as `service/schema.py::_FIELDS`.
// `engine/tests/parity_schema.py` diffs the two, so a row added on one side
// and not the other is a test failure rather than a slider that does nothing.
#pragma once
#include <string>
#include <vector>

#include "json.hpp"
#include "profile.hpp"

namespace spk {

struct GrainParams {
    bool active = true;
    bool sublayers_active = true;
    double particle_area_um2 = 0.2;
    double particle_scale[3] = {1.6, 1.6, 3.2};
    double particle_scale_layers[3] = {2.0, 1.0, 0.5};
    double density_min[3] = {0.03, 0.03, 0.03};
    double uniformity[3] = {0.97, 0.99, 0.97};
    double blur = 0.65;
    double blur_dye_clouds_um = 1.0;
    double micro_structure[2] = {0.2, 30.0};
    int n_sub_layers = 1;
};

struct HalationParams {
    bool active = true;
    double scatter_amount = 1.0;
    double scatter_spatial_scale = 1.0;
    double halation_amount = 1.0;
    double halation_spatial_scale = 1.0;
    double scatter_core_um[3] = {2.2, 2.0, 1.6};
    double scatter_tail_um[3] = {9.3, 9.7, 9.1};
    double scatter_tail_weight[3] = {0.78, 0.65, 0.67};
    double boost_ev = 0.0;
    double boost_range = 0.3;
    double protect_ev = 4.0;
    double halation_strength[3] = {0.05, 0.015, 0.0};
    double halation_first_sigma_um[3] = {65.0, 65.0, 65.0};
    int halation_n_bounces = 3;
    double halation_bounce_decay = 0.5;
    bool halation_renormalize = true;
};

struct DirCouplersParams {
    bool active = true;
    double amount = 1.0;
    double inhibition_samelayer = 1.0;
    double inhibition_interlayer = 1.0;
    double gamma_samelayer_rgb[3] = {0.341, 0.324, 0.273};
    double gamma_interlayer_r_to_gb[2] = {0.355, 0.305};
    double gamma_interlayer_g_to_rb[2] = {0.154, 0.358};
    double gamma_interlayer_b_to_rg[2] = {0.171, 0.225};
    double diffusion_size_um = 20.0;
    double diffusion_tail_um = 200.0;
    double diffusion_tail_weight = 0.06;
};

struct GlareParams {
    bool active = true;
    double percent = 0.03;
    double roughness = 0.7;
    /// **Pixels at the full tier**, and scaled from there at every other tier
    /// (`node_glare`): the blur is the same *fraction of the frame* wherever it
    /// runs, so the export is exactly what it always was and the canvas — the
    /// preview of that export — is what moves to match.
    ///
    /// **Anchored on the output, not on the film, and that is deliberate.** A
    /// tier is not a second scan of the same negative; it is the same scan
    /// previewed at another size, so the honest reference is the scan the user
    /// is comparing against. Expressing this in micrometres of film (divided by
    /// the frame's pitch) was tried first and rejected: a µm constant only
    /// reproduces today's blur at the one resolution it is anchored to —
    /// measured, the unsharp going 0.7 px to 0.5087 on a 6000 px frame and to
    /// 0.1017 on a 1200 px one.
    double blur = 0.5;
};

struct DiffusionFilterParams {
    bool active = false;
    std::string filter_family = "black_pro_mist";
    double strength = 0.5;
    double spatial_scale = 1.0;
    double halo_warmth = 0.0;
    double core_intensity = 1.0, core_size = 1.0;
    double halo_intensity = 1.0, halo_size = 1.0;
    double bloom_intensity = 1.0, bloom_size = 1.0;
};

struct PrintCurvesMorphParams {
    bool active = false;
    double gamma_factor = 1.0;
    double gamma_factor_fast = 1.0, gamma_factor_slow = 1.0;
    double gamma_factor_red = 1.0, gamma_factor_green = 1.0, gamma_factor_blue = 1.0;
    double developer_exhaustion = 0.0;
};

struct FilmRenderParams {
    double density_curve_gamma = 1.0;
    GrainParams grain;
    HalationParams halation;
    DirCouplersParams dir_couplers;
    GlareParams glare;
};

// RFC-024: the virtual contrast mask, a neutral spatial gain on the
// enlarger's image exposure before pre-flash and paper development. Off by
// default, and `active = false` leaves the print path's nodes and kernels
// exactly as they were -- the bypass is structural, not a unity gain.
//
// Units are the RFC's: stops of paper exposure relative to the negative's own
// mid-grey through the same enlarger. `highlights` / `shadows` are named for
// the *final print* (RFC-024 §5.1): print highlights are the low projected
// exposures a dense negative gives, and they are raised; print shadows are the
// high ones, and they are lowered. Each is the change the curve makes to a
// base exposure `kContrastMaskReach` stops beyond its knee, so 0 disables that
// branch exactly.
//
// The defaults are placeholders, not recommendations: every control is the
// user's to set, and none is calibrated (RFC-024 §12.5).
struct ContrastMaskParams {
    bool active = false;
    double highlights = 0.0;   ///< stops raised, print-highlight side
    double shadows = 0.0;      ///< stops lowered, print-shadow side
    double core = 1.0;         ///< half-width of the identity core, stops
    double scale = 0.03;       ///< base extractor's sigma, fraction of the long edge
    /// The base extractor, by name. Only "gaussian" (the classic unsharp mask)
    /// is a product scheme: the self-guided filter behaved like the per-pixel
    /// arm at its fixed threshold (RFC-024 §12.4), so it is reachable only
    /// through `SPEKTRAFILM_MASK_GUIDED` for research.
    std::string scheme = "gaussian";
};

bool is_known_contrast_mask_scheme(const std::string& scheme);

struct PrintRenderParams {
    GlareParams glare;
    ContrastMaskParams contrast_mask;
    PrintCurvesMorphParams density_curves_morph;
    // Print-layer EDR master toggle. It defaults off so the legacy print
    // path remains byte-identical until the user opts in.
    bool edr_enabled = false;
};

// RFC-023's Scene Latitude Mapping: a pointwise gain before spectral
// upsampling that compresses the scene's two ends onto the medium while an
// identity core stays exactly untouched. The axis is stops relative to the
// metered mid-grey, measured after auto-exposure and before Exp. Comp.
// (RFC-023 §5.1, §15.4). These are the **resolved** knees and rooms: the UI's
// pull-backs are solved into them at commit time (`spk_scene_latitude`) and
// never travel on the wire, so a paper change cannot re-render an old edit
// (§8.3). A side whose room is 0 is off, exactly.
struct SceneLatitudeParams {
    bool active = false;
    std::string norm = "power";     ///< power | y | max -- the scalar the gain is computed on
    double highlight_knee = 2.0;    ///< K_h, stops
    double highlight_room = 0.0;    ///< H_h, stops; 0 = the highlight side is off
    double shadow_knee = -2.0;      ///< K_s, stops
    double shadow_room = 0.0;       ///< H_s, stops; 0 = the shadow side is off
    double rolloff = 2.0;           ///< m, the roll-off order (§5.5)
    double max_lift = 4.0;          ///< L_max, stops: the smooth bound on the shadow lift (§15.5)
};

bool is_known_scene_latitude_norm(const std::string& norm);

struct CameraParams {
    double exposure_compensation_ev = 0.0;
    bool auto_exposure = true;
    /// Which exposure intent the meter follows (RFC-015 §2.3). The default is
    /// the reference's own, and it stays: three of the seven names are the
    /// legacy meters, whose arithmetic the parity harnesses pin.
    std::string auto_exposure_method = "center_weighted";
    double lens_blur_um = 0.0;
    double film_format_mm = 35.0;
    double filter_uv[3] = {0.0, 410.0, 8.0};
    double filter_ir[3] = {0.0, 675.0, 15.0};
    DiffusionFilterParams diffusion_filter;
    SceneLatitudeParams scene_latitude;
};

struct EnlargerParams {
    std::string illuminant = "TH-KG3";
    double print_exposure = 1.0;
    bool print_exposure_compensation = true;
    bool normalize_print_exposure = true;
    double y_filter_shift = 0.0, m_filter_shift = 0.0;
    double y_filter_neutral = 55.0, m_filter_neutral = 65.0, c_filter_neutral = 0.0;
    double lens_blur = 0.0;
    DiffusionFilterParams diffusion_filter;
    double preflash_exposure = 0.0;
    double preflash_y_filter_shift = 0.0, preflash_m_filter_shift = 0.0;
};

struct ScannerParams {
    /// **Pixels**, and it stays that way here: `scanner_lens_blur` is on the
    /// wire (range 0…20, print layer), so its unit is the contract's to
    /// change, not this file's. The app never sends it, so nothing in the
    /// product moves either way. See the note on the pixel-unit item.
    double lens_blur = 0.0;
    bool white_correction = false, black_correction = false;
    double white_level = 0.98, black_level = 0.01;
    /// `{sigma, amount}`: the sigma is **pixels at the full tier**, scaled
    /// from there at every other tier exactly like the glare blur above, and
    /// the amount is the unitless gain it always was. See `GlareParams::blur`
    /// for why the reference is the output and not the film.
    double unsharp_mask[2] = {0.7, 0.7};
};

struct GeometryParams {
    double crop_x = 0.0, crop_y = 0.0, crop_w = 1.0, crop_h = 1.0;
    double rotation_deg = 0.0;
    int quarter_turns = 0;
    bool flip_h = false, flip_v = false;

    bool is_identity() const {
        return crop_x == 0.0 && crop_y == 0.0 && crop_w == 1.0 && crop_h == 1.0 &&
               rotation_deg == 0.0 && (quarter_turns % 4) == 0 && !flip_h && !flip_v;
    }
};

// One struct for both specs, but *not* one set of defaults: the input side is
// `InputGamutCompressSpec(active=True, algorithm="xy")` and the output side is
// `OutputGamutCompressSpec(algorithm="cam16ucs", lightness_compression=
// (0.7, 1.0, 2.2))`. Sharing the struct and forgetting that cost a build that
// refused every default configuration with "output gamut compression 'xy' is
// not implemented" -- so the two are constructed by name below.
struct GamutCompressSpec {
    bool active = true;
    std::string algorithm = "xy";              // input: "xy"; output: "cam16ucs" | "off"
    double knee[3] = {0.0, 1.0, 6.0};
    bool lightness_compression_active = false;
    double lightness_compression[3] = {0.7, 1.0, 2.2};

    static GamutCompressSpec input_default() { return GamutCompressSpec{}; }
    static GamutCompressSpec output_default() {
        GamutCompressSpec s;
        s.active = true;
        s.algorithm = "cam16ucs";
        s.lightness_compression_active = true;
        return s;
    }
};

struct IOParams {
    std::string input_color_space = "ProPhoto RGB";
    bool input_cctf_decoding = false;
    /// **The working space** since RFC-018 §5.1. The engine renders into it,
    /// the app grades in it, and the conversion to a display or an export
    /// space happens once, at the end, in the app's own output transform
    /// (`spk_output_transform`).
    ///
    /// It used to read `"sRGB"` while `spk_open` hardcoded Display P3 — a
    /// header and a behaviour that disagreed, which is RFC-018 §4.2. The two
    /// agree now, and the *resolved* space (this default or an explicit
    /// `io.output_color_space` in the delta) is echoed in the `open` reply so
    /// the frontend reads it rather than assuming it.
    std::string output_color_space = "ProPhoto RGB";
    bool output_cctf_encoding = true;
    GamutCompressSpec input_gamut_compress = GamutCompressSpec::input_default();
    GamutCompressSpec output_gamut_compress = GamutCompressSpec::output_default();
    bool crop = false;
    double crop_center[2] = {0.5, 0.5};
    double crop_size[2] = {0.1, 0.1};
    GeometryParams geometry;
    double upscale_factor = 1.0;
    bool scan_film = false;
    /// The long edge of the `live` tier, i.e. the size every interactive edit
    /// renders at — the app's **preview resolution**, and a user setting.
    /// `engine.cpp` resolves the `live` row of its tier table from here, so
    /// the tier's *size* is data while its *name* stays what the wire
    /// addresses (CONTRACT §1.2.3).
    ///
    /// **The default is the old constant, 1600, and that is what makes this
    /// additive**: a caller that never sends the field renders exactly what it
    /// always rendered, so no parity number moves. What it deliberately does
    /// not do is move auto exposure — `kMeterLongEdge` is its own constant,
    /// and the only place the two meet is the meter's reuse of the live tier
    /// image, which happens only while this field equals it.
    int preview_long_edge = 1600;
};

struct SettingsParams {
    std::string rgb_to_raw_method = "hanatos2025";
    bool apply_hanatos2025_adaptation_window = true;
    bool apply_hanatos2025_adaptation_surface = false;
    double spectral_gaussian_blur = 0.0;
    bool use_enlarger_lut = false;
    bool use_scanner_lut = false;
    int lut_resolution = 17;
    std::string grain_sampler = "stochastic";
    std::string working_precision = "float32";
    int preview_max_size = 640;
    bool preview_mode = false;
    bool neutral_print_filters_from_database = true;

    // RFC-020 §3.1's... no: §4's striped execution, step 4. Three questions
    // that were one field in the first draft, and the split is not cosmetic:
    // a count cannot express "on" (a count is *policy*, and §7 puts policy in
    // `choose_strip_height` inside the engine -- an app picking a number would
    // be RFC-021 leaking into the client a release early), and a height is the
    // quantity RFC-021 actually chooses, because the same count means wildly
    // different working sets on a 24 MP and a 102 MP frame.
    //
    // All three are execution settings, not look settings: the picture is
    // bit-identical either way (§6's gate is the hash), so none of them may
    // invalidate a cached negative or a tier. They are `live` in the schema for
    // that reason -- written straight onto the running pipeline, read by the
    // next render, and no rebuild for a change that cannot move a pixel.
    bool striped = false;              ///< run the striped executor at all
    int strip_rows = 0;                ///< 0 = let `choose_strip_height` decide
    int strip_budget_bytes = 0;        ///< accepted, recorded, varies nothing yet (§7)
};

struct DebugParams {
    bool deactivate_spatial_effects = false;
    bool deactivate_stochastic_effects = false;
    bool lut_mode = false;
};

struct Params {
    Profile film, print;
    std::string film_stock = "kodak_portra_400";
    std::string print_stock = "kodak_portra_endura";
    FilmRenderParams film_render;
    PrintRenderParams print_render;
    CameraParams camera;
    EnlargerParams enlarger;
    ScannerParams scanner;
    IOParams io;
    SettingsParams settings;
    DebugParams debug;
};

// --- the wire schema ---------------------------------------------------

enum class FieldType { Float, Bool, Str, Int };
enum class Layer { Shoot, Print };

struct SchemaField {
    const char* name;
    const char* path;          // dotted, into Params, as service/schema.py spells it
    FieldType type;
    Layer layer;
    bool has_range;
    double lo, hi;
    bool live;                 // writable onto a live pipeline without a rebuild
};

const std::vector<SchemaField>& schema_fields();

// The `params_schema` reply, identical in shape to the Python service's.
Json transport_schema();

// `validate_delta` -- unknown field, wrong type, out of range. The message is
// the user-facing one; `param` names the offending field.
bool validate_delta(const Json& delta, std::string& error, std::string& param);

// The seven accepted `auto_exposure_method` names: RFC-015 §2.3's four intents
// plus the three legacy meters. The names are checked here rather than at
// render time because `set_params`/`open` is where a user error can still be
// reported as one — the meter used to be the first thing to notice, which
// meant an unknown name surfaced as a failed render long after the edit.
// The meter keeps its own check as a backstop for a `Params` built in code.
bool is_known_exposure_method(const std::string& method);

// True if the delta touches anything outside LIVE_MUTABLE, i.e. needs a
// pipeline rebuild rather than an in-place write.
bool delta_needs_rebuild(const Json& delta);
bool delta_touches_shoot(const Json& delta);

// Writes a validated delta onto a tree in place. Stock fields are skipped:
// they need a profile load and a rebuild, which is the caller's business.
void apply_delta(Params& params, const Json& delta);

// Current resolved values for every declared field -- the `params` block in
// every reply.
Json read_params(const Params& params);

// `params_builder.digest_params`: neutral filters from the database, the
// preview/lut/debug switches, then the stock-specific overrides and the
// halation preset. Must run before a pipeline is built.
bool digest(Params& params, const Json& neutral_filters, std::string& error);

// `init_params` + `digest`, with the profiles loaded from `resources_dir`.
bool init_params(const std::string& resources_dir, const std::string& film_stock,
                 const std::string& print_stock, const Json& neutral_filters,
                 Params& out, std::string& error);

}  // namespace spk
