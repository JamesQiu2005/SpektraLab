// Windows desktop host. Rendering and image I/O stay behind their existing
// boundaries; the UI only receives immutable, independently owned frames.
#pragma once

#include "core/json.hpp"
#include "io/raw_decoder.hpp"
#include "spektrafilm/spk_engine.h"
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace spk::desktop {

enum class DecodeMode { compatible16, headroom };

struct Stock {
    std::string id, label;
    bool is_positive = false;
    // The rest of the profile's `info`, read as macOS's Tools/gen-catalog.py
    // reads it into StockCatalog.json: `use` "cine", `channel_model` "bw" (one
    // silver emulsion, or a silver paper), and `target_print`, the paper the
    // film was made for (empty for a slide, and for every paper).
    bool is_cine = false;
    bool is_monochrome = false;
    std::string target_print;
};
struct Catalog {
    std::vector<Stock> films, papers;
    // nullptr when the catalogue has no such stock.
    const Stock* film(std::string_view id) const;
    const Stock* paper(std::string_view id) const;
};

// --- the catalogue ------------------------------------------------------
//
// One entry per <resources>/profiles/*.json: spektrafilm's, and the product's
// own black-and-white films and silver paper (engine/resources_product/),
// which the build lays beside them as engine/build.sh does for macOS. Films
// and papers are each sorted by label. Throws std::runtime_error on a profile
// it cannot read.
Catalog read_catalog(const std::filesystem::path& resources);

// macOS StockCatalog.canPrint (StockCatalog.swift:133): silver film on silver
// paper, colour on colour. A stock the catalogue does not know rules nothing
// out.
bool can_print(const Catalog& catalog, std::string_view film, std::string_view paper);

// The paper a change of film lands on, by macOS Session.selectFilmStock
// (Session.swift:2988): the film's own paper whenever it names one the
// catalogue has, and otherwise `paper` -- unless that cannot print the film,
// when it is the film's paper or, failing that, `fallback`. A slide names
// none, so its paper is kept for the next negative.
std::string paper_for_film(const Catalog& catalog, std::string_view film, const std::string& paper,
                           const std::string& fallback);

// The film and paper lists as macOS groups them (StockCatalog.filmGroups and
// paperGroups): films "positive", "negative", then "blackAndWhite" when the
// catalogue has any; papers "still", then "cine". Within a group, stills
// before cine stocks and each by identifier, the macOS catalogue's order. An
// empty group is still returned; the pointers are into `catalog`.
struct StockGroup {
    std::string key;
    std::vector<const Stock*> stocks;
};
std::vector<StockGroup> film_groups(const Catalog& catalog);
std::vector<StockGroup> paper_groups(const Catalog& catalog);

// A film's own grain: what the Grain strength's 1 is in `grain_amount`, the
// amount at which the engine renders the RMS granularity the maker publishes.
// macOS FilmParams.ownGrain (Params.swift:593): the four black-and-white
// films' measured values, 1 for everything else.
double own_grain(std::string_view film);

// --- the settings table -------------------------------------------------
//
// One row per engine parameter a desktop frontend offers. The row is the only
// place the parameter's wire name, type, range, layer and defaults are
// declared: validation, the open parameters, the minimal edit delta, the
// Windows edit store and the Qt controller's generic accessors all iterate
// the table. Adding a control is one row in preview_host.cpp plus its QML.
//
// Type, layer and range mirror the row of the same name in core/params.cpp
// (a desktop range may be narrower, never wider); spk_desktop_preview_test
// holds the two tables together, and holds `absent` to the engine default.
// A product row (`wire` false) is the one exception: it names no engine
// field, and what it changes is written in wire_params.
enum class SettingType { boolean, number, text };
enum class SettingLayer { shoot, print };
// The values a text row accepts: its own list, a stock in the catalogue, or
// (`free`) any short line of printable text -- the Date Back's typed date.
enum class SettingChoices { listed, films, papers, free };
// The longest `free` text: a date back's line (the data face holds 22).
inline constexpr std::size_t kFreeTextMax = 32;
using SettingValue = std::variant<bool, double, std::string>;

struct SettingField {
    std::string key;    // wire name, and the edit store's key since version 2
    std::string label;  // English, for diagnostics
    SettingType type = SettingType::number;
    SettingLayer layer = SettingLayer::shoot;
    double low = 0.0, high = 0.0;  // closed range of a number row
    SettingChoices choices = SettingChoices::listed;
    std::vector<std::string> listed;
    // What a new photograph starts with. Where it differs from the engine's
    // own default it follows the macOS app, which is the product's reference.
    SettingValue initial;
    // What a saved edit that predates this row was rendered with: the row was
    // never sent, so the engine default applied. Loading such a record with
    // this value, not `initial`, keeps it looking the way it was made.
    SettingValue absent;
    // False for a product row: a choice macOS keeps beside the engine
    // parameters (Params.swift FilmParams.printEffects) that is never sent
    // itself and only decides what other rows send (wire_params). It is
    // stored, validated and saved like any row, and is no engine field.
    bool wire = true;
};

const std::vector<SettingField>& setting_fields();
const SettingField* find_setting(std::string_view key);  // nullptr when unknown
// Empty when `value` has the row's type, lies in its range and is one of its
// choices; otherwise the user-facing reason. Stocks are checked against
// `catalog` when one is given (a caller without one checks their syntax).
std::string check_setting(const SettingField& field, const SettingValue& value,
                          const Catalog* catalog = nullptr);

struct RenderSettings {
    // Named members for the rows C++ callers address directly (both desktop
    // frontends and the host tests). Their values still come from the table:
    // the constructor applies every row's `initial`. A row without a member
    // is stored by key and reached through get/set.
    std::string film_stock, print_stock;
    double print_exposure{};
    // Film exposure (wire `exposure_compensation_ev`) places the scene on the
    // characteristic curve. The enlarger compensates its mid-grey;
    // print_exposure controls brightness.
    double film_exposure_ev{};
    double film_format_mm{};
    bool grain_active{};
    double grain_amount{};
    bool halation_active{};
    double halation_amount{};
    bool glare_active{};
    double glare_amount{};
    double y_filter_shift{};
    double m_filter_shift{};

    RenderSettings();
    // By wire name. Both throw std::invalid_argument for an unknown key or a
    // value of the wrong type; neither checks the range (validate_settings
    // and check_setting do), so a caller can still build an invalid request.
    SettingValue get(std::string_view key) const;
    void set(std::string_view key, SettingValue value);

    bool operator==(const RenderSettings&) const = default;

private:
    // Every row without a named member, always present, so the defaulted
    // comparison sees each value exactly once.
    std::map<std::string, SettingValue, std::less<>> by_key_;
};

// Checks every row (the stocks against `catalog`) and throws
// std::runtime_error naming the first bad one. Returns whether the film is
// scanned instead of printed: a positive always is, and a negative when
// `scan_film` (macOS's "No Print Profile") is on.
bool validate_settings(const RenderSettings& settings, const Catalog& catalog);

// What the desktop asks spk_open to render into until the frontend converts
// from the working space itself (the engine's own default is ProPhoto RGB,
// RFC-018 §5.1). A request, not a fact: see OutputEncoding.
inline constexpr const char* kDisplayOutputColorSpace = "sRGB";


// --- Film Edge and Date Back (RFC-031/032) --------------------------------
//
// macOS keeps both as FilmEdgeSettings and DateBackSettings (Model/
// FilmEdge.swift). Their wire fields are rows of the table; what macOS keeps
// beside them that is no engine field is product rows -- the date's order,
// the shooting-data switch, where the printed text comes from and the user's
// own text, and whether the frame has been given its seeds. What the macOS
// session resolves for the engine (Session.resolvedFilmEdge, Session+
// FilmEdge.swift:257-268) -- the stock's edge print, the f-number, the date
// and the data as printed -- is not stored: wire_params resolves it from the
// frame (PhotoInfo), so a frame's record never carries another frame's date.

// One format of the Format menu (FilmEdgeFormat, FilmEdge.swift:9-81, and
// its words in FilmEdgeSection.swift:547-622), in the menu's order.
struct FilmFormat {
    std::string id;                  // overscan_format
    std::string title;               // the pill's: "135", "Half", "6x7"
    std::string group;               // "135" | "120" | "panoramic"
    double long_mm = 0, short_mm = 0;  // the gate, held level
    std::string gauge;               // the film it runs on: "135" | "120"
    bool perforated = false;
    std::string gate_label;          // "36 x 24", after the pill
    std::string ratio;               // the menu's second line: "3:2"
    double strip_cost = 0, filed_cost = 0;  // film pixels per picture pixel
    bool prints_in_margin = false;   // 120: the date back prints beside the frame
    bool has_date_back = false;      // what a date back prints on (no panoramic one)
};
const std::vector<FilmFormat>& film_formats();
const FilmFormat* film_format(std::string_view id);  // nullptr when unknown

// The photograph's geometry as the editor applies it after the engine
// (windows_UI FrameOutput: crop in the unturned source, straighten with zoom
// to fill, clockwise quarter turns, flips in the output axes). With a film
// edge the engine is handed the picture already cut by it: the engine takes
// the frame it is given as the gate (Session+FilmEdge.swift:5-18), so the
// crop becomes the framing in the gate and is part of the negative.
struct EngineCut {
    double x = 0, y = 0, w = 1, h = 1;  // normalised, top-left, in the source
    int quarter_turns = 0;              // clockwise, 0..3
    bool flip_h = false, flip_v = false;
    double straighten_deg = 0;          // -45..45
    bool identity() const;
    bool operator==(const EngineCut&) const = default;
};
// The cut picture's size from a width x height decode, as the editor rounds
// the crop (FrameOutput cropPixels), after the quarter turns.
void cut_size(const EngineCut& cut, std::uint32_t width, std::uint32_t height,
              std::uint32_t& out_width, std::uint32_t& out_height);

// What the host knows of the frame beyond its settings: its EXIF, its
// decoded size (0 x 0 before a decode) and the geometry it is shown with.
struct PhotoInfo {
    io::ShootingData shooting;
    std::uint32_t decode_width = 0, decode_height = 0;
    EngineCut geometry;
};

// The macOS rules, each with its source:
//  - the date back's camera: the film edge's format while it is on, else the
//    one Film Format describes when that is unambiguous -- 36 x 24, 24 x 18 or
//    56 x 41.5 mm, +-1 mm (Session.dateBackCamera, Session+FilmEdge.swift:542-562);
//    nullptr when it describes no camera that had a date back;
//  - a face prints when the camera carries it, and the data face, or any face
//    on 120, only with a film edge (DateBackSettings.prints, FilmEdge.swift:340);
//  - the date is drawn when on, printable, and in the frame or with a film
//    edge to print between (DateBackSettings.effective, FilmEdge.swift:353);
//  - the frame is cut for the engine with a film edge, or with the date
//    alone on a geometry that is not the identity (FilmParams.cutsFrame).
const FilmFormat* date_back_camera(const RenderSettings& settings, const PhotoInfo& photo);
bool date_back_prints(const RenderSettings& settings, const PhotoInfo& photo, std::string_view face);
bool date_back_effective(const RenderSettings& settings, const PhotoInfo& photo);
bool date_back_prints_data(const RenderSettings& settings, const PhotoInfo& photo);
bool cuts_frame(const RenderSettings& settings, const PhotoInfo& photo);
// The stock's edge print (Session.edgeText, Session+FilmEdge.swift:215-243).
std::string edge_text(const Catalog& catalog, std::string_view film, std::string_view gauge);
// The date as a date back writes it, "'26 10 1" (DateBackSettings.format), in
// `order` "japan" or "us"; "" without a date.
std::string date_text(const io::ShootingData& shooting, std::string_view order);
// The data face's line, "1/250 F5.6 A +0.3 24mm" (ShootingData.dataText).
std::string data_text(const io::ShootingData& shooting);
// What date_imprint_text carries: the user's typed text when the source is
// "typed", else the data line on the data face or the EXIF date.
std::string printed_date_text(const RenderSettings& settings, const io::ShootingData& shooting);

// The crop held by the gate (Session.gateRatio / gateFramed, Session+
// FilmEdge.swift:370-390): width over height of the crop in source pixels,
// the gate on its side for a landscape crop and upright for a portrait one.
double gate_ratio(const RenderSettings& settings, bool landscape);
// True when the cut's crop has the gate's shape within 2 % (the engine
// refuses past 5 %).
bool gate_shaped(const EngineCut& cut, const RenderSettings& settings, std::uint32_t width, std::uint32_t height);
// The crop reshaped to the gate about its centre, keeping its area, then
// fitted inside the frame (Geometry.constrained, Geometry.swift:592-610).
// `landscape` < 0 keeps the crop's own orientation; 0 / 1 force one.
EngineCut gate_framed(const EngineCut& cut, const RenderSettings& settings, std::uint32_t width,
                      std::uint32_t height, int landscape = -1);

// Settings Sync and the clipboard copy no Film Edge and no Date Back
// (SettingsClipboard.swift:75-76, "not copied until a group is decided"):
// every overscan_* and date_imprint_* row and their product rows stay the
// recipient's.
bool per_photo_setting(std::string_view key);
RenderSettings synced_settings(const RenderSettings& from, const RenderSettings& recipient);
// A new frame's seeds (Session.seedFilmEdge, Session+FilmEdge.swift:348-356):
// a frame seed of its own, stable for the file; the user's body; and its
// number on the roll, its place in the session (index % 99 + 1), or 0 -- the
// seed's draw -- for a frame opened on its own (index < 0).
std::uint32_t frame_seed_for(std::string_view path_utf8);
void seed_film_edge(RenderSettings& settings, std::string_view path_utf8, int index, int body_seed);
// What the settings put on the wire: every wire row, under the product's
// rules -- macOS FilmParams.wire (Params.swift:726-825):
//  - scan_film is on for a slide film whatever the row says;
//  - glare_active, preflash_exposure and contrast_mask_active are off while
//    print_effects is off (the Print section's Print Effects), their own
//    values kept;
//  - grain_sublayers_active is off on a black-and-white film;
//  - grain_amount is the row times the film's own grain (own_grain), within
//    the row's range;
//  - a black-and-white film on a silver paper also carries Multigrade filter
//    2 as the neutral pack, c/m/y_filter_neutral 0/0/68, because the engine's
//    filter table has no silver paper and would keep the last colour pair's.
//  - Film Edge and Date Back (FilmEdgeSettings.wire, DateBackSettings.wire,
//    FilmEdge.swift:194-214, 375-404): overscan_edge_text and
//    overscan_f_number are the stock's print and the EXIF aperture while the
//    film edge is on, else empty and 0; date_imprint_active is the date
//    drawn (date_back_effective); while it is, date_imprint_text and
//    date_imprint_data_text are the printed text and the data line, the film
//    edge's or Film Format's camera rides on overscan_format, and on a frame
//    the date alone cuts, film_format_mm and the date's size and insets
//    follow the cut (FilmParams.wireFilmFormatMM / dateScale). Seeds and the
//    frame number are integers on the wire.
// A stock the catalogue does not know is taken as a colour negative. Without
// `photo` the frame is an unknown 3:2 one with no EXIF.
Json wire_params(const RenderSettings& settings, const Catalog& catalog, const PhotoInfo* photo = nullptr);
// The complete parameters spk_open receives: the host's fixed I/O policy and
// wire_params. `output_color_space` is the space requested; `photo` is the
// frame's facts for wire_params (Film Edge, Date Back).
Json opening_params(const RenderSettings& settings, const Catalog& catalog,
                    const std::string& output_color_space = kDisplayOutputColorSpace,
                    const PhotoInfo* photo = nullptr);
// Only the wire values that differ, so an edit never invalidates more of the
// session than it changed. A film change also carries scan_film. A field that
// leaves the wire (the silver pack) is not sent: leaving a silver pair is a
// stock change, on which the engine reloads the colour pair's pack itself.
Json changed_params(const RenderSettings& before, const RenderSettings& after, const Catalog& catalog,
                    const PhotoInfo* photo = nullptr);

// How a session's RGBA16 code values are encoded: the output colour space
// spk_open *resolved* (its reply's params.output_color_space, RFC-018 §5.1)
// and whether the transfer function was applied. Anything that tags,
// converts or labels the pixels reads this rather than assuming the request
// (AGENTS.md trap 28).
struct OutputEncoding {
    std::string color_space;
    bool cctf_encoding = true;
    bool operator==(const OutputEncoding&) const = default;
    // Encoded sRGB, which the bundled sRGB.icc writers label correctly.
    bool is_encoded_srgb() const { return color_space == "sRGB" && cctf_encoding; }
};
// Reads the open reply. Throws std::runtime_error when the reply carries no
// string output_color_space or no boolean output_cctf_encoding under params.
OutputEncoding output_encoding(const Json& open_reply);

// Wall-clock calls, including CPU result readback in render_ms. total_ms is
// the complete host call, not a sum of nested measurements. Engine creation
// and TIFF export are separate operations. Re-renders have zero decode/open
// time unless a previous engine failure required reopening the retained input.
struct Timings {
    double decode_ms = 0.0, open_ms = 0.0, params_ms = 0.0;
    double render_ms = 0.0, engine_render_ms = 0.0;
    double display_ms = 0.0, total_ms = 0.0;
};

class PreviewHost;
class Frame final {
public:
    ~Frame();
    Frame(const Frame&) = delete;
    Frame& operator=(const Frame&) = delete;

    std::filesystem::path source;
    DecodeMode decode_mode = DecodeMode::compatible16;
    RenderSettings settings;
    // Resolved by validate_settings: a slide film is always viewed directly
    // without the paper stage, a negative when its scan_film row is on.
    bool scan_film = false;
    io::RawMetadata metadata;
    io::RawDecodeTimings decode_timings;
    Timings timings;
    // What pixels() means, as the session that rendered it reported.
    OutputEncoding encoding;
    // Top-down tightly packed BGRA8 copy of pixels(), rounded to 8 bits with
    // no colour transform, so it is in `encoding` too. Empty unless the host
    // was created with HostOptions::bgra8_display; pixels() always retains
    // the original full-size RGBA16.
    std::vector<std::uint8_t> bgra8;
    // Film Edge / Date Back: the geometry the frame was asked for, and whether
    // the engine was handed the picture cut by it (cuts_frame) -- then these
    // pixels already carry the crop, and the film around it, and the editor
    // applies no geometry of its own. `geometry` may differ from the one asked
    // for: a film edge holds the crop at the gate's shape (gate_framed).
    EngineCut geometry;
    bool cut = false;
    std::uint32_t decode_width = 0, decode_height = 0;   // the whole decode
    std::uint32_t picture_width = 0, picture_height = 0; // what the engine was handed
    // spk_overscan_geometry's reply for this render: {"valid": false} without
    // a film edge; else the canvas, its pitch and the gate quads, normalised.
    std::string overscan_geometry;
    // The whole decode, undeveloped, for framing a cut picture in the gate
    // (README §4: the guide over the undeveloped picture): top-down BGRA8
    // sRGB, long edge at most 2048. Shared between the frames of one decode;
    // null until a frame of it is cut.
    struct SourcePreview {
        std::uint32_t width = 0, height = 0;
        std::vector<std::uint8_t> bgra8;
    };
    std::shared_ptr<const SourcePreview> source_preview;

    const spk_result& pixels() const noexcept { return result_; }
    std::uint32_t width() const noexcept { return result_.width; }
    std::uint32_t height() const noexcept { return result_.height; }
    bool reprint() const noexcept { return result_.reprint != 0; }
    bool negative_was_cached() const noexcept { return result_.negative_was_cached != 0; }

private:
    Frame() = default;
    spk_result result_{};
    friend class PreviewHost;
};

using FramePtr = std::shared_ptr<const Frame>;

// Pure conversion, including row-pitch handling, used by the host and tested
// independently. Throws on invalid dimensions/pitch or non-opaque pixels.
// Rounding is (value + 128) / 257; no colour transform or tone mapping.
std::vector<std::uint8_t> rgba16_to_bgra8(const spk_result& result);

struct HostOptions {
    // Requested of every session this host opens; Frame::encoding records
    // what the engine resolved. Anything but sRGB is for tests until the
    // frontend converts out of the working space (export writes sRGB only).
    std::string output_color_space = kDisplayOutputColorSpace;
    // The GDI viewer draws Frame::bgra8. The Qt frontend publishes its own
    // half-float image from pixels() and turns this off: at 33 MP the copy
    // is 132 MB per frame nobody reads.
    bool bgra8_display = true;
};

// Construct, call and destroy on one serial worker thread. Public operations
// throw std::runtime_error on failure. The UI may concurrently read shared
// const Frames, which stay valid after this host and its engine are destroyed.
class PreviewHost final {
public:
    explicit PreviewHost(const std::filesystem::path& resources, HostOptions options = {});
    ~PreviewHost();
    PreviewHost(const PreviewHost&) = delete;
    PreviewHost& operator=(const PreviewHost&) = delete;

    const Catalog& catalog() const noexcept;
    double engine_create_ms() const noexcept;
    FramePtr current() const noexcept;
    // What current() was made from, for the analysis calls that never render
    // (spk_solve, spk_scene_latitude) and the neutral picker's sample: the
    // live session -- nullptr before the first open, and after a failed edit
    // until the next render reopens it -- and the decoded RAW it was opened
    // on. On this same worker thread only; neither may be retained.
    spk_session* session() const noexcept;
    const io::DecodedRaw& input() const noexcept;
    // The decode current() was developed from (linear ProPhoto, RAW
    // orientation applied): what the Qt frontend shows as the Original. Empty
    // before the first open; replaced only by a successful open_raw. Read on
    // the host's own thread, like every other call.
    const io::DecodedRaw& decoded() const noexcept;

    // New-file open is transactional: decode/open/render/display conversion
    // must all succeed before replacing the previous session and frame.
    // `geometry` is the photograph's; it reaches the engine only when the
    // settings cut the frame (cuts_frame), and then a changed one reopens the
    // session on the newly cut picture from the retained decode.
    FramePtr open_raw(const std::filesystem::path& source, DecodeMode mode,
                      const RenderSettings& settings = RenderSettings(), const EngineCut& geometry = EngineCut());
    // Only changed settings are sent. Print-side edits request spk_reprint;
    // the result's actual cache flag determines whether reuse occurred.
    // A failure never mutates the previously returned Frame. Settings that
    // decode differently (a white balance, raw_white_balance.hpp) are an
    // open_raw of the current source instead; a new cut (cuts_frame) reopens
    // the session from the retained decode.
    FramePtr render(const RenderSettings& settings, const EngineCut& geometry = EngineCut());
    // Exports exactly the supplied frame, even after a newer one was opened.
    // Existing files are never overwritten. Returns only after the writer
    // has completed and closed the file; errors retain its cleanup details.
    // The file is labelled with the bundled sRGB profile, so a frame not
    // encoded in sRGB is refused rather than mislabelled.
    void export_tiff(const Frame& frame, const std::filesystem::path& destination) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace spk::desktop
