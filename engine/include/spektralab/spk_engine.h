/*  spk_engine.h -- the whole surface of the SpektraLab engine, a C++/Metal
 *  implementation derived from spektrafilm by Andrea Volpato (GPL-3.0-or-later).
 *
 *  RFC-014 §2.1. A hand-written C ABI, not Swift's C++ interop, for three
 *  reasons that all still hold on Xcode 26.6 / Swift 6.3:
 *
 *    - It is ABI-stable. C++ name mangling, std:: layouts and Swift's
 *      interop rules all move between toolchains; this does not.
 *    - It is drivable from three languages. Swift links it, the C++ tests
 *      call it, and `ctypes` loads the *shipping* dylib -- which is what
 *      keeps the numba parity oracle pointed at the code that ships rather
 *      than at a copy of it (RFC-014 §3).
 *    - It forces the boundary to stay narrow. Direct interop makes it easy
 *      to leak a std::vector<Node> across the line and rebuild the transport
 *      problem in a new form.
 *
 *  Three rules hold everywhere below:
 *
 *  1. **Nothing throws.** Every entry point is noexcept. Failure is a
 *     negative `spk_status` plus a message from `spk_last_error`. A C++
 *     exception unwinding into Swift is undefined behaviour.
 *  2. **Ownership never crosses.** The caller owns the device, the input
 *     pixels and the strings it passes in. The engine owns everything it
 *     allocates and frees it in the matching `_release`/`_free`. No buffer
 *     is freed by the side that did not allocate it.
 *  3. **Parameters are JSON.** They are small, the schema already exists
 *     (`service/schema.py`), and a struct-per-parameter surface would break
 *     every time a slider is added -- the thing contract §1 exists to
 *     prevent.
 */
#ifndef SPEKTRALAB_SPK_ENGINE_H
#define SPEKTRALAB_SPK_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- versions ---------------------------------------------------------
 * These are the same two numbers `service/capabilities` reports, and they
 * mean the same thing: the frontend refuses a transport it does not speak
 * and warns on a schema it does not speak (contract §2). Keeping the values
 * identical to the Python service is deliberate -- the wire did not change
 * when the engine did.
 */
#define SPK_TRANSPORT_VERSION 1
#define SPK_SCHEMA_VERSION    1

typedef int32_t spk_status;
enum {
    SPK_OK                 =  0,
    SPK_ERR_INVALID_ARG    = -1,   /* a null pointer, a bad tier, a bad enum   */
    SPK_ERR_USER           = -2,   /* the caller asked for something wrong     */
    SPK_ERR_RESOURCE       = -3,   /* out of memory, image too large           */
    SPK_ERR_UNSUPPORTED    = -4,   /* a configuration this build cannot render */
    SPK_ERR_GPU            = -5,   /* device, library or dispatch failed       */
    SPK_ERR_IO             = -6,   /* a resource file is missing or corrupt    */
    SPK_ERR_CANCELLED      = -7,
    SPK_ERR_INTERNAL       = -8    /* a bug here, not out there                */
};

typedef struct spk_engine  spk_engine;
typedef struct spk_session spk_session;

/* A caller-owned, tightly packed float32 image. `data` stays valid for the
 * duration of the call it is passed to; the engine copies what it keeps. */
typedef struct {
    const float* data;
    uint32_t     width;
    uint32_t     height;
    uint32_t     channels;   /* 3 or 4; a 4th channel is dropped at the door */
} spk_image;

/* Metal path only. The same image, already in GPU-visible memory: `buffer` is an
 * `id<MTLBuffer>` **on the engine's own device**, holding tightly packed
 * float32 pixels, top row first. Borrowed exactly as `spk_image.data` is --
 * valid for the duration of the call, not retained after it -- so the
 * caller may reuse or free it the moment the call returns.
 *
 * It exists so a caller that renders its frame into shared memory does not
 * pay a host copy the engine would immediately repeat: `spk_open` copies the
 * pixels into a Metal buffer before its first kernel, which at 45 MP is
 * 727 MB and ~235 ms. Refused, with a message, when the buffer belongs to
 * another device or is shorter than `width * height * channels * 4` bytes.
 * The first Vulkan backend refuses this entry point; use `spk_open` there. */
typedef struct {
    void*    buffer;
    uint32_t width;
    uint32_t height;
    uint32_t channels;   /* 3 or 4; a 4th channel is dropped at the door */
} spk_device_image;

/* One rendered tier.
 *
 * **This struct is the one exception to rule 2 above**, and it is worth
 * reading before using it. On macOS, `texture` is an `id<MTLTexture>` over
 * the rendered pixels, returned **+1: the caller owns it**. In Swift that means
 * `takeRetainedValue()` and ARC; in C it means `spk_result_free` when done.
 *
 * The exception exists because the caller caches these. The frontend keeps the
 * last eight frames' live textures resident so switching frames is instant, so
 * a texture whose pixels the engine reuses on the next render of the same tier
 * would silently become a different photograph. Each render therefore gets its
 * own buffer, and handing over the only reference is what ties that buffer's
 * lifetime to the caller's use of it rather than to the engine's next frame.
 * The Windows headless path makes a separate CPU copy for the same lifetime.
 *
 * On the Windows headless Vulkan path, `texture` is an opaque handle owning a
 * CPU copy of the RGBA16 pixels. It is not a drawable VkImage. Release it with
 * `spk_result_free`, even if the session and engine have already been freed.
 *
 * `rgba16` points into the result handle's own memory, so it is valid for
 * exactly as long as `texture` is retained. It is there for callers that want
 * the pixels rather than something to draw -- the parity harness reads it, and it is the
 * same rows `service._write_rgba16` used to put in a file.
 */
typedef struct {
    const uint16_t* rgba16;
    void*           texture;
    uint32_t        width;
    uint32_t        height;
    /* Row pitch of `rgba16`, in pixels, which is `width` rounded up to the
     * device's linear-texture alignment. It is reported rather than left for
     * the caller to re-derive: the alignment is queried from the device
     * (`minimumLinearTextureAlignmentForPixelFormat`), not a constant, and a
     * caller that assumed 256 bytes read past the end of the buffer. */
    uint32_t        row_stride_px;
    double          elapsed_ms;
    int32_t         reprint;              /* 1 if the negative was reused   */
    int32_t         negative_was_cached;
    char            progress_id[40];
} spk_result;

/* --- engine ----------------------------------------------------------- */

/* `resources_dir` holds the baked engine resources and backend shaders.
 * On macOS, `device` is the caller's `MTLDevice` (retained by the engine);
 * pass NULL to create one. The first Windows Vulkan backend currently accepts
 * only NULL and loads SPIR-V from `resources_dir/vulkan`. */
spk_engine* spk_engine_create(const char* resources_dir, void* device);
void        spk_engine_destroy(spk_engine* engine);

/* JSON, engine-owned, valid until the next call on this engine:
 *   capabilities  -> the `capabilities` reply, verbatim
 *   params_schema -> the `params_schema` reply, verbatim
 * Both exist so the frontend keeps asking the same two questions it asked
 * the Python service, and gets the same two answers.
 */
const char* spk_capabilities(spk_engine* engine);
const char* spk_params_schema(spk_engine* engine);

/* What this engine holds, in bytes. Engine-owned and valid until the next
 * call on this engine, exactly as the two above.
 *
 * RFC-020 §3.3. `pool` is the render buffer pool, and its total splits into
 * `live_bytes` (a node or an Image is holding it), `free_bytes` (reusable by
 * the next allocation right now) and `pending_bytes` (freed, but an encoded
 * command buffer still names it). `persistent` is everything allocated
 * outside the pool: a session's source and its cached negatives, the baked
 * tables, a render's rgba16 result.
 *
 * **`persistent.source_bytes`, `persistent.cached_negative_bytes` and
 * `persistent.file_backed_bytes` are a breakdown *of* `persistent.bytes`, not
 * additions to it**, and `persistent.sessions` is that breakdown per open
 * session. So the engine's whole holding is
 * `pool.total_bytes + persistent.bytes`, which is the top-level
 * `total_bytes`; registering a per-session entry and a pool entry means
 * splitting `persistent.sessions`, not adding it to the pool.
 *
 * `file_backed_bytes` is the part of the holding whose pages live in a file
 * rather than in the process's ledger (RFC-020 §4.7) -- the source and the
 * cached negatives. It is reported separately because a consumer weighing the
 * engine against a footprint should weigh it differently: measured, a 1.22 GB
 * plane costs 1,362 MB of `phys_footprint` as an ordinary buffer and 137 MB
 * this way.
 *
 * It does not include the caller's own memory -- the frame passed to
 * `spk_open_device`, or a Core Image decode -- which the caller accounts for
 * (RFC-019 `DecodeResidency`).
 *
 * Cheap enough for a UI timer: a sum over a few dozen handles under one lock,
 * with no Metal object walked or queried. Cannot fail.
 */
const char* spk_memory_report(spk_engine* engine);

/* Give the render pool back now, down to `keep_bytes` (0: all of it), and
 * return the bytes freed.
 *
 * The same `trim_pool` the memory-pressure source and the idle timer call
 * (RFC-020 §3.1, §3.2), for a host whose own reading of the machine says so
 * before either of them would: macOS memory pressure is reactive, and the
 * idle timer waits 60 s that back-to-back jobs never give it. Only buffers no
 * node or Image holds go (`refs == 0`), the largest first, so it is safe
 * beside a render on another thread -- which then allocates again what it
 * needs. Sessions, their sources and cached negatives, and the baked tables
 * are untouched: no picture changes. Cannot fail; a null engine frees 0.
 */
size_t spk_trim_pool(spk_engine* engine, size_t keep_bytes);

/* Pay the fixed per-stock-pair setup before the user is looking (RFC-013 §3).
 * Idempotent. `out_json` receives the `warm_up` reply. */
spk_status spk_warm_up(spk_engine* engine, const char* film_stock,
                       const char* print_stock, char** out_json);

/* --- session ---------------------------------------------------------- */

/* Open one frame. `params_delta_json` may be NULL. `out_json` receives the
 * `open` reply (session id, meta, detected input, resolved params). */
spk_session* spk_open(spk_engine* engine, const spk_image* input,
                      const char* params_delta_json, char** out_json);

/* `spk_open` with the pixels already on the device (see `spk_device_image`).
 * Same reply, same session, same source: the two differ only in how the
 * frame reaches the GPU, and share every line after that. */
spk_session* spk_open_device(spk_engine* engine, const spk_device_image* input,
                             const char* params_delta_json, char** out_json);

/* `out_json` receives `{"invalidated": ..., "params": {...}}`. */
spk_status spk_set_params(spk_session* session, const char* params_delta_json,
                          char** out_json);
spk_status spk_get_params(spk_session* session, char** out_json);

/* `target` is "exposure", "filter_pack" or "both". */
spk_status spk_solve(spk_session* session, const char* target, char** out_json);

/* RFC-024's mask, as a picture: the delta in stops (positive raises the
 * print's highlights, negative lowers its shadows) at each cell of the
 * analysis grid, row-major, `grid_w` x `grid_h` in the frame's own aspect --
 * after the gain bound, exactly what the next print of `tier` would apply.
 * Needs the tier's negative (render the tier first). With the mask off it
 * returns SPK_OK, a NULL field and a 0 x 0 grid. The floats are
 * engine-owned and valid until the next call on this session. */
spk_status spk_contrast_mask_field(spk_session* session, const char* tier, const float** out_delta,
                                   uint32_t* out_grid_w, uint32_t* out_grid_h);

/* RFC-023's Scene Latitude: measure, suggest and solve -- never render.
 * `request_json` may be NULL or an object with any of `highlight_pull_back`,
 * `shadow_pull_back` (stops; 0 turns a side off; absent = the suggestion),
 * `rolloff`, `max_lift`, `norm` (absent = the session's), `margin`
 * (default 0.25), `shadow_percentile` (0.1 or 1) and `highlight_percentile`
 * (99.9 or 99) -- which robust extreme each side is fitted to. `out_json` receives the measured medium, the scene
 * statistic, the suggested pull-backs and the solved fit, whose
 * `params_delta` -- present only when the fit is valid -- is what a client
 * sends to `spk_set_params` to commit it (API-SPEC §12).
 * Windows supports this analysis, but currently refuses enabling the mapping;
 * see `backend.unsupported_features` in capabilities. */
spk_status spk_scene_latitude(spk_session* session, const char* request_json, char** out_json);

/* Enable HDR's gain curve, the session's own (PRD/HDR-PORT-PLAN-2026-11-06 D1,
 * API-SPEC §19.2): family A -- the medium's shoulder moved right and up by the
 * headroom past its knee -- computed from the medium `spk_scene_latitude`
 * measures for this session (the same cached probe, its 128-point
 * `medium.ramp_ev` / `ramp_y`), so it follows the film, the paper, minilab and
 * the enlarger. It runs on the medium's own axis, not the reply's: in the
 * product Exp. Comp. only moves the frame along the medium, so it leaves the
 * table unchanged (a pixel of one SDR Y gets one gain). Never renders a frame;
 * no curve data ships.
 *
 * `request_json` may be NULL or an object with only these keys:
 *   `headroom`      H, in [1.0001, 16]; default 4 (A_H4: two stops over SDR white)
 *   `clip_ev`       the frame's clip, in stops on `medium.ramp_ev`'s axis (the
 *                   metered mid-grey, before Exp. Comp.); when given, the
 *                   expanded ramp eases into a plateau there (0.75 EV, C1)
 *   `include_ramp`  also return the model's ramps (561 points), for a check
 * Any other key is SPK_ERR_USER. `out_json` (caller-freed, `spk_string_free`):
 * `version`, `headroom`, `domain_log2_y` [-12, 0], `log2_gain` (256, monotone,
 * 0 below the knee, last = log2 H exactly), `ks` and `rho` (256 each: the
 * grain-aware tables; rho is the raw slope, the kernel clamps it to
 * [0, rho_max]), `top` (log2 H), `kappa`, `rho_max`, and the diagnostics
 * `knee_ev`, `knee_log2_y`, `delta`, `y_white`, `gamma0`, `eased`, `clip_ev`
 * (null when not given), `exposure_ev`, `medium_shift_ev` (the medium's own
 * axis is the reply's + this: Exp. Comp. in the product, 0 where the enlarger
 * re-times), `scan`; `ramp` {ev, log2_y, log2_y_hdr} with `include_ramp`.
 * Every EV in the reply (`knee_ev`, `clip_ev`, `ramp.ev`) is on the request's
 * axis, `medium.ramp_ev`'s.
 *
 * Refused, with no curve: a Digital Intermediate session (Cineon codes, no
 * print), `extended_dynamic_range` on a print (the curve is measured without
 * it), a medium the probe cannot read (SPK_ERR_GPU, as `spk_scene_latitude`),
 * and a medium family A cannot model -- no knee past mid-grey, no gamma at
 * mid-grey (gamma0 under 0.1), a white at or above display white
 * (SPK_ERR_USER). Kept per
 * session per (medium, Exp. Comp., headroom, clip_ev). Takes the session's
 * lock, as every session call does. */
spk_status spk_session_hdr_curve(spk_session* session, const char* request_json, char** out_json);

/* RFC-052 §6.4 (API-SPEC §23): the 场景 layers -- a local amount of Film
 * Exposure (and of a filter on the light) before the film. One layer:
 *
 *   plane      an `id<MTLBuffer>` **on the engine's own device**: the layer's
 *              folded mask in source space S, 16-bit unorm (0 = none, 65535 =
 *              full), `width * height` uint16, row-major, top row first, no
 *              row padding. Texel (i, j)'s centre is S = ((i + 0.5) / width,
 *              (j + 0.5) / height). Retained by the session until the next call
 *              or its release; **the host never writes into a plane it has
 *              handed over** (make a new buffer for a changed mask).
 *   log_gain   g, the natural log of a gain on the three cone responses of
 *              `C = M_CAT16 · M_(working RGB -> XYZ)` (the reply's
 *              `rgb_to_cone`), at full coverage. An exposure of e stops alone is
 *              e·ln2·(1, 1, 1); with every layer's three equal the node is a
 *              scalar gain 2^(Σ k e) and runs no matrix.
 *   coverage   on · opacity, in [0, 1]; the layer's k(x) = coverage · mask(x).
 */
typedef struct spk_scene_layer {
    void*    plane;
    uint32_t width, height;
    float    log_gain[3];
    float    coverage;
} spk_scene_layer;

/* Hand the session its scene layers: `count` 0...8 (0 clears them).
 * `frame_to_source` is the handed frame's normalised coordinates -> S,
 * row-major 3 x 3 acting on the column (x, y, 1), origin top-left, x right,
 * y down, (0, 0)-(1, 1) the frame's corners (pixel edges); NULL is the
 * identity, which it is unless the host cut the frame itself (`HostCut`). The
 * engine composes it with its own cut (`io.geometry`, inverted) per pixel.
 * `stamp` (NULL = "") names this set: a render whose wire field
 * `scene_layers` is not "" and is not this stamp is refused with
 * SPK_ERR_USER, both named. Drops every tier's cached negative -- not the
 * decoded source, not the lens's kept copy, not the meter. `out_json`
 * (caller-freed, may be NULL): `stamp`, `count`, `colour`, `plane_bytes`,
 * `working_space`, `rgb_to_cone` and `cone_to_rgb` (row-major, out[i] =
 * Σ_j m[3i + j] x[j]), `frame_to_source`. The planes' bytes are the host's and
 * are not in `spk_memory_report`. The CMake targets (Windows, Linux) refuse it
 * with SPK_ERR_UNSUPPORTED. */
spk_status spk_set_scene_layers(spk_session* session, const spk_scene_layer* layers, uint32_t count,
                                const float frame_to_source[9], const char* stamp, char** out_json);

/* RFC-032: where the gates are on the film canvas the session's last render
 * laid out (API-SPEC §13). `out_json`: `{"valid": false}` with overscan off or
 * before a render; else `canvas_w`, `canvas_h`, `mm_per_px`, `vertical`,
 * `format`, `gate_mm`, `penumbra_mm` and `gates` -- one quad per gate (two for
 * a pair), eight numbers each: its corners normalised to the canvas, in the
 * film's order (s0,t0), (s1,t0), (s1,t1), (s0,t1). Normalised, so the same
 * quads hold at every tier. Never renders. */
spk_status spk_overscan_geometry(spk_session* session, char** out_json);

/* Tiers are the three API-SPEC §6 names: "live", "preview", "full". */
spk_status spk_reprint(spk_session* session, const char* tier, spk_result* out);
spk_status spk_render(spk_session* session, const char* tier, spk_result* out);

/* --- the baked print+scan LUTs ----------------------------------------
 *
 * Three methods that used to live in Python and be refused here by name
 * (ARCHITECTURE §8.8). What they share is one asset: the eight print-preview
 * LUTs `scripts/bake_all_print_luts.py` baked and validated, now inside
 * `spektralab_constants.bin` with their metadata in `print_luts.json`.
 *
 * Neither method includes `scanning.glare`, and that is the design rather
 * than a gap: glare is a spatial, stochastic veiling field and cannot be
 * represented in a pointwise table. It costs mean abs 0.00085 -> 0.00177
 * against a production render (HANDOFF-PRINT-LUT §2). A finished print still
 * goes through `spk_reprint`, which has glare.
 */

/* Which print stocks have a shipped LUT, as the `print_luts.json` index
 * verbatim: an object keyed by stock, each with `paired_film`,
 * `declared_pairing`, `lut_size`, `output_color_space` and
 * `output_cctf_encoding`. Engine-owned; "{}" when none are bundled. */
const char* spk_print_lut_catalog(spk_engine* engine);

/* One stock's table, as tightly packed float32 in (S, S, S, 3) row-major
 * order -- the `.cube` writer's input, and the only thing on this surface
 * that is neither JSON nor a texture.
 *
 * Engine-owned and valid for the engine's lifetime: the table is loaded from
 * the blob on first use and cached, so the pointer stays good and must not be
 * freed. `*out_size` is S. */
spk_status spk_print_lut_table(spk_engine* engine, const char* print_stock,
                               const float** out_table, uint32_t* out_size);

/* Flip between print stocks by table lookup instead of by re-rendering the
 * print+scan chain: the session's cached negative for `tier`, through the
 * trilinear kernel. Measured at 45 MP, warm, against a reprint of the same
 * tier: 2.0 ms against 9 at live, 9.5 against 34 at preview, 47 against 167
 * at full.
 *
 * `out` is a texture exactly as `spk_reprint` leaves one, and is owned by the
 * caller the same way. `out_json` receives `apply_ms`, `tier`, `paired_film`,
 * `declared_pairing`, and a `warning` when the session's film is not the one
 * the LUT was baked against -- the table is coupled to the negative's dye
 * spectra as well as to the paper, so a mismatched film is an approximation
 * with unmeasured error (PRD §7.3). */
spk_status spk_preview_stock_lut(spk_session* session, const char* print_stock,
                                 const char* tier, spk_result* out, char** out_json);

/* **Not the product's Digital Intermediate** (that is
 * `spk_render_digital_intermediate`, RFC-028): the app retired the "DI package"
 * that used this on 2026-09-29. It stays as the engine's tap on the developed
 * negative, which `parity_lut.py`, RFC-022's solver and RFC-028's probe read.
 *
 * The full-tier negative normalised to [0, 1]
 * by the LUT's own per-channel density axes, so the `.cube` the caller writes
 * from `spk_print_lut_table` has domain 0..1 and needs no DOMAIN_MIN/MAX
 * support in whatever opens it.
 *
 * `print_stock` may be NULL, meaning the session's own. `out_json` carries
 * `print_stock`, `paired_film`, `declared_pairing` and the same mismatch
 * `warning`. Layer 2 does not apply to this image and must not be baked into
 * it: it is pre-print by definition. */
spk_status spk_export_di(spk_session* session, const char* print_stock,
                         spk_result* out, char** out_json);

/* RFC-028: the frame's **Digital Intermediate**, full tier, whatever paper the
 * session shows. The session's negative (cached when warm) is read in printing
 * density with the film base removed per wavelength, reversed on the film's
 * own neutral curve, and encoded as Kodak Cineon log in the session's working
 * primaries: code = (685 + 300 log10(L(1-b) + b)) / 1023, b = 10^((95-685)/300),
 * film base on code 95. `out` is a texture as `spk_reprint` leaves one. The
 * session's own pipeline and its cached prints are not touched. A slide film
 * has none: SPK_ERR_USER. `out_json` carries `encoding`, `primaries` and the
 * paper whose sensitivity defines the printing density. */
spk_status spk_render_digital_intermediate(spk_session* session, spk_result* out, char** out_json);

/* --- the output transform (RFC-018 §5.2) ------------------------------
 *
 * A session renders into the **working space** (`params.io.output_color_space`,
 * ProPhoto RGB by default). Leaving that space is the caller's job, one
 * conversion per destination, and this is the data it does it with: the
 * chromatically adapted linear matrix, the two transfer-function modes as
 * `shaders/nodes.metal` numbers them, and the CAM16-UCS setup for `dst_cs` --
 * the same one `Pipeline::build` bakes, from the same setup cache.
 *
 * It is a *fetch*, not a render. Nothing here touches pixels; the transform
 * itself runs in whatever kernel the caller has, and every number in it comes
 * from this engine's own colour data rather than from a second colour library
 * on the other side of the boundary.
 *
 * `gamut_compress_json` may be NULL, meaning the default a session gets
 * (`GamutCompressSpec::output_default()`: cam16ucs, lightness compression on,
 * the standard knee). An object overrides it:
 *
 *   {"algorithm": "cam16ucs" | "off",
 *    "knee": [threshold, limit, power],
 *    "lightness_compression_active": bool,
 *    "lightness_compression": [threshold, limit, power]}
 *
 * and the reply's `gamut_compress` block carries `lightness_compression_active`
 * back, because the kernel needs it: with the compression off, `k[15..17]` are
 * neutralised but a kernel that merely *read* them, without the gate, would not
 * be applying an identity.
 *
 * `algorithm: "off"` is legal and means the caller skips the compression step;
 * the JSON still carries the tables, because a caller that flips the setting
 * without a round trip should not have to come back for them.
 *
 * `out_json` is caller-freed with `spk_string_free`. `out_cmax` points into
 * the engine's own setup cache and is valid for the engine's lifetime; it is
 * not freed by the caller, exactly as `spk_print_lut_table`'s table is not.
 * `*out_cmax_count` is `rows * cols`.
 *
 * A `src_cs` or `dst_cs` this build does not know -- or knows without a
 * transfer function or a whitepoint -- fails with `SPK_ERR_USER` and a message
 * naming it. **It does not fall back**: falling back is how a picture ends up
 * in a space nobody asked for.
 */
spk_status spk_output_transform(spk_engine* engine,
                                const char* src_cs, const char* dst_cs,
                                const char* gamut_compress_json,
                                char** out_json,
                                const float** out_cmax, uint32_t* out_cmax_count);

/* Release a result's texture (and with it the pixels `rgba16` points at).
 * Do **not** call it after taking ownership of `texture` in a language with
 * its own reference counting -- Swift's `takeRetainedValue()` already did. */
void spk_result_free(spk_result* result);
void spk_session_release(spk_session* session);

/* --- cancellation ------------------------------------------------------
 * `spk_cancel` is safe to call from another thread while a render is in
 * flight; the render unwinds at the next node boundary and returns
 * SPK_ERR_CANCELLED.
 */
void spk_cancel(spk_session* session, const char* progress_id);
spk_status spk_progress(spk_session* session, const char* progress_id, char** out_json);

/* --- strings and errors ------------------------------------------------ */

/* Frees a `char*` an `out_json` produced. Never call it on the return of
 * `spk_capabilities` / `spk_params_schema` / `spk_last_error`, which the
 * engine owns. */
void spk_string_free(char* s);

/* The last failure on this engine, on this thread. Never NULL; "" when
 * nothing has failed. Valid until the next failed call on this thread. */
const char* spk_last_error(spk_engine* engine);

/* Build identity, for `capabilities.backend` and for a human reading a bug
 * report: version, git-ish build stamp, the Metal math mode the kernels were
 * compiled with, and whether the fast-math probe agreed with it. */
const char* spk_build_info(void);

#ifdef __cplusplus
}  /* extern "C" */
#endif
#endif /* SPEKTRALAB_SPK_ENGINE_H */
