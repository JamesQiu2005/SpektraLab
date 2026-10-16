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
};
struct Catalog { std::vector<Stock> films, papers; };

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
enum class SettingType { boolean, number, text };
enum class SettingLayer { shoot, print };
// The values a text row accepts: its own list, or a stock in the catalogue.
enum class SettingChoices { listed, films, papers };
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
// std::runtime_error naming the first bad one. Returns whether the film is a
// positive, which is scanned directly instead of printed.
bool validate_settings(const RenderSettings& settings, const Catalog& catalog);

// What the desktop asks spk_open to render into until the frontend converts
// from the working space itself (the engine's own default is ProPhoto RGB,
// RFC-018 §5.1). A request, not a fact: see OutputEncoding.
inline constexpr const char* kDisplayOutputColorSpace = "sRGB";

// The complete parameters spk_open receives: the host's fixed I/O policy,
// scan_film and every row. `output_color_space` is the space requested.
Json opening_params(const RenderSettings& settings, bool scan_film,
                    const std::string& output_color_space = kDisplayOutputColorSpace);

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
// Only the rows that differ, so an edit never invalidates more of the
// session than it changed. A film change also carries scan_film.
Json changed_params(const RenderSettings& before, const RenderSettings& after, bool scan_film);

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
    // Resolved from the selected film's catalog metadata, not a separate
    // user setting. Slide film is viewed directly without the paper stage.
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

    // New-file open is transactional: decode/open/render/display conversion
    // must all succeed before replacing the previous session and frame.
    FramePtr open_raw(const std::filesystem::path& source, DecodeMode mode,
                      const RenderSettings& settings = RenderSettings());
    // Only changed settings are sent. Print-side edits request spk_reprint;
    // the result's actual cache flag determines whether reuse occurred.
    // A failure never mutates the previously returned Frame.
    FramePtr render(const RenderSettings& settings);
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
