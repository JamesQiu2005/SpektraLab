// Headless tests of the desktop host boundary. The default invocation is pure
// CPU conversion; optional integration uses the real engine and RAW fixture.
#include "desktop/preview_host.hpp"
#include "desktop/viewport.hpp"
#include "core/json.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using spk::Json;
using namespace spk::desktop;

namespace {

std::uint64_t checks = 0;

void check(bool condition, const char* message) {
    ++checks;
    if (!condition) throw std::runtime_error(message);
}

template<class F> std::string rejected(F&& function, const char* message) {
    try { function(); }
    catch (const std::exception& error) {
        check(*error.what() != '\0', "rejection omitted diagnostic");
        return error.what();
    }
    throw std::runtime_error(message);
}

std::string path_text(const fs::path& path) {
    const auto utf8 = path.u8string();
    return std::string(reinterpret_cast<const char*>(utf8.data()), utf8.size());
}

// Mutation fingerprint only, not a cryptographic provenance claim. The Python
// integration runner separately records SHA-256 of binaries, inputs and TIFF.
std::uint64_t fingerprint(const void* data, std::size_t size,
                          std::uint64_t hash = 14695981039346656037ull) {
    const auto* bytes = static_cast<const std::uint8_t*>(data);
    for (std::size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ull;
    }
    return hash;
}

std::string hex(std::uint64_t value) {
    std::ostringstream text;
    text << std::hex << std::setfill('0') << std::setw(16) << value;
    return text.str();
}

std::uint64_t frame_fingerprint(const Frame& frame) {
    const auto& pixels = frame.pixels();
    std::uint64_t hash = 14695981039346656037ull;
    for (std::uint32_t y = 0; y < pixels.height; ++y)
        hash = fingerprint(pixels.rgba16 + std::size_t(y) * pixels.row_stride_px * 4,
                           std::size_t(pixels.width) * 4 * sizeof(std::uint16_t), hash);
    return hash;
}

void conversion() {
    // Padding deliberately contains invalid alpha: only active pixels count.
    std::array<std::uint16_t, 40> source{};
    const std::array<std::array<std::uint16_t, 4>, 6> pixels{{
        {{65535, 0, 0, 65535}}, {{0, 65535, 0, 65535}}, {{0, 0, 65535, 65535}},
        {{65535, 65535, 65535, 65535}}, {{0, 0, 0, 65535}}, {{32768, 32768, 32768, 65535}}
    }};
    for (std::size_t i = 0; i < pixels.size(); ++i)
        std::copy(pixels[i].begin(), pixels[i].end(), source.begin() + (i / 3 * 5 + i % 3) * 4);
    spk_result image{};
    image.rgba16 = source.data(); image.width = 3; image.height = 2; image.row_stride_px = 5;
    const auto display = rgba16_to_bgra8(image);
    const std::vector<std::uint8_t> expected{
        0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255,
        255, 255, 255, 255, 0, 0, 0, 255, 128, 128, 128, 255};
    check(display == expected, "BGRA channel order, top-down rows or padded pitch differ");
    std::fill(source.begin(), source.end(), 99);
    check(display == expected, "display copy aliases caller-owned RGBA16");

    std::vector<std::uint16_t> ramp(65536 * 4);
    for (std::uint32_t value = 0; value < 65536; ++value) {
        ramp[value * 4] = static_cast<std::uint16_t>(value);
        ramp[value * 4 + 1] = static_cast<std::uint16_t>(65535 - value);
        ramp[value * 4 + 2] = static_cast<std::uint16_t>((value * 17) & 65535);
        ramp[value * 4 + 3] = 65535;
    }
    image.rgba16 = ramp.data(); image.width = 65536; image.height = 1; image.row_stride_px = 65536;
    const auto quantized = rgba16_to_bgra8(image);
    for (std::uint32_t value = 0; value < 65536; ++value) {
        for (unsigned channel = 0; channel < 3; ++channel) {
            const auto rounded = std::lround(double(ramp[value * 4 + 2 - channel]) * 255.0 / 65535.0);
            check(quantized[value * 4 + channel] == rounded, "16-to-8 nearest quantization differs");
        }
        check(quantized[value * 4 + 3] == 255, "display alpha is not opaque");
    }
    for (unsigned variant = 0; variant < 7; ++variant) {
        const std::uint16_t opaque[4]{0, 0, 0, 65535};
        const std::uint16_t translucent[4]{0, 0, 0, 65534};
        spk_result invalid{};
        invalid.rgba16 = opaque; invalid.width = invalid.height = invalid.row_stride_px = 1;
        switch (variant) {
        case 0: invalid.rgba16 = nullptr; break;
        case 1: invalid.width = 0; break;
        case 2: invalid.height = 0; break;
        case 3: invalid.row_stride_px = 0; break;
        case 4: invalid.rgba16 = translucent; break;
        case 5: invalid.width = invalid.height = invalid.row_stride_px = std::numeric_limits<std::uint32_t>::max(); break;
        case 6: invalid.height = invalid.row_stride_px = std::numeric_limits<std::uint32_t>::max(); break;
        }
        rejected([&] { rgba16_to_bgra8(invalid); }, "invalid BGRA conversion accepted");
    }
}

void viewport_geometry() {
    const auto portrait = viewport(4000, 6000, 1200, 800, true);
    check(portrait.width == 533 && portrait.height == 800 && portrait.x == 333 && portrait.y == 0 &&
          std::abs(portrait.scale - 800.0 / 6000.0) < 1e-12, "portrait fit geometry");
    const auto landscape = viewport(6000, 3000, 1200, 800, true);
    check(landscape.width == 1200 && landscape.height == 600 && landscape.x == 0 && landscape.y == 100 &&
          std::abs(landscape.scale - 0.2) < 1e-12, "landscape fit geometry");
    const auto fitted_pan = viewport(6000, 3000, 1200, 800, true, 1e300, -1e300);
    check(fitted_pan.x == landscape.x && fitted_pan.y == landscape.y, "fit mode retained stale pan");
    const auto actual = viewport(6000, 4000, 1200, 800, false);
    check(actual.width == 6000 && actual.height == 4000 && actual.x == -2400 && actual.y == -1600 &&
          actual.scale == 1, "100 percent is not one image pixel per physical canvas pixel");
    const auto small = viewport(400, 200, 1200, 800, false, 1e300, -1e300);
    check(small.width == 400 && small.height == 200 && small.x == 400 && small.y == 300 && small.scale == 1,
          "small 100-percent image moved or scaled");
    const auto bottom_right = viewport(6000, 4000, 1200, 800, false, 1e300, -1e300);
    check(bottom_right.x == 0 && bottom_right.y == -3200, "extreme positive/negative pan overflowed before clamping");
    const auto top_left = viewport(6000, 4000, 1200, 800, false, -1e300, 1e300);
    check(top_left.x == -4800 && top_left.y == 0, "extreme negative/positive pan overflowed before clamping");
    const auto fractional = viewport(6000, 4000, 1200, 800, false, 23.25, -31.25);
    check(fractional.x == -2377 && fractional.y == -1631, "fractional pan rounding");
    for (const auto shape : {std::array<int, 4>{0, 100, 200, 300}, {100, 0, 200, 300},
                             {100, 100, 0, 300}, {100, 100, 200, 0}, {-1, 100, 200, 300}}) {
        const auto empty = viewport(shape[0], shape[1], shape[2], shape[3], true);
        check(empty.x == 0 && empty.y == 0 && empty.width == 0 && empty.height == 0,
              "empty viewport produced drawable geometry");
    }
}

class TiffReader {
public:
    explicit TiffReader(const fs::path& path) : stream(path, std::ios::binary | std::ios::ate) {
        check(bool(stream), "cannot read exported TIFF");
        const auto size = stream.tellg();
        check(size >= 8, "TIFF too short");
        length = std::uint64_t(size);
    }
    std::vector<std::uint8_t> read(std::uint64_t at, std::size_t count) {
        check(at <= length && count <= length - at, "TIFF field outside file");
        std::vector<std::uint8_t> bytes(count);
        stream.seekg(std::streamoff(at));
        check(bool(stream.read(reinterpret_cast<char*>(bytes.data()), std::streamsize(count))), "TIFF read incomplete");
        return bytes;
    }
    std::uint64_t length = 0;
private:
    std::ifstream stream;
};

std::uint16_t little16(const std::vector<std::uint8_t>& bytes, std::size_t at) {
    check(at <= bytes.size() && bytes.size() - at >= 2, "TIFF short outside field");
    return std::uint16_t(bytes[at]) | std::uint16_t(bytes[at + 1]) << 8;
}
std::uint32_t little32(const std::vector<std::uint8_t>& bytes, std::size_t at) {
    return std::uint32_t(little16(bytes, at)) | std::uint32_t(little16(bytes, at + 2)) << 16;
}

void compare_tiff(const fs::path& path, const Frame& frame, const fs::path& profile_path) {
    TiffReader file(path);
    const auto header = file.read(0, 8);
    check(header[0] == 'I' && header[1] == 'I' && little16(header, 2) == 42, "not classic little-endian TIFF");
    const auto ifd_at = little32(header, 4);
    const auto tags_count = little16(file.read(ifd_at, 2), 0);
    const auto ifd = file.read(ifd_at + 2, std::size_t(tags_count) * 12 + 4);
    struct Tag { std::uint16_t type; std::uint32_t count; std::vector<std::uint8_t> bytes; };
    std::map<std::uint16_t, Tag> tags;
    for (unsigned i = 0; i < tags_count; ++i) {
        const auto at = std::size_t(i) * 12;
        const auto key = little16(ifd, at), type = little16(ifd, at + 2);
        const auto count = little32(ifd, at + 4);
        const std::size_t unit = type == 3 ? 2 : type == 4 ? 4 : type == 5 ? 8 : (type == 2 || type == 7) ? 1 : 0;
        check(unit != 0 && count <= 4 * 1024 * 1024 / unit, "unexpected TIFF field size/type");
        const auto extent = count * unit;
        const auto payload = extent <= 4 ? file.read(ifd_at + 2 + at + 8, extent)
                                         : file.read(little32(ifd, at + 8), extent);
        check(tags.emplace(key, Tag{type, count, payload}).second, "duplicate TIFF field");
    }
    check(little32(ifd, std::size_t(tags_count) * 12) == 0, "unexpected second TIFF image");
    const auto number = [&](std::uint16_t key, std::uint32_t index = 0) {
        const auto& tag = tags.at(key);
        check(index < tag.count, "TIFF field index out of range");
        if (tag.type == 3) return std::uint32_t(little16(tag.bytes, index * 2));
        check(tag.type == 4, "TIFF field is not an integer");
        return little32(tag.bytes, index * 4);
    };
    const auto& pixels = frame.pixels();
    check(number(256) == pixels.width && number(257) == pixels.height, "export dimensions differ from held frame");
    check(number(259) == 1 && number(262) == 2 && number(274) == 1 && number(277) == 3 && number(284) == 1,
          "TIFF compression/colour/orientation/channel layout invalid");
    for (unsigned c = 0; c < 3; ++c)
        check(number(258, c) == 16 && number(339, c) == 1, "export is not unsigned RGB16");
    const auto rows_per_strip = number(278);
    check(rows_per_strip > 0 && rows_per_strip <= 64, "unexpected TIFF strip height");
    const auto strip_count = (pixels.height - 1) / rows_per_strip + 1;
    check(tags.at(273).count == strip_count && tags.at(279).count == strip_count, "invalid TIFF strip tables");
    std::uint64_t previous_end = 0;
    for (std::uint32_t i = 0; i < strip_count; ++i) {
        const auto first_row = i * rows_per_strip;
        const auto rows = std::min(rows_per_strip, pixels.height - first_row);
        const auto offset = number(273, i), bytes = number(279, i);
        check(bytes == std::uint64_t(rows) * pixels.width * 6 && offset >= previous_end,
              "TIFF strip size/overlap invalid");
        const auto data = file.read(offset, bytes);
        for (std::uint32_t row = 0; row < rows; ++row) {
            const auto* expected = pixels.rgba16 + (std::size_t(first_row + row) * pixels.row_stride_px) * 4;
            const auto* actual = data.data() + std::size_t(row) * pixels.width * 6;
            for (std::uint32_t x = 0; x < pixels.width; ++x)
                for (unsigned c = 0; c < 3; ++c) {
                    const auto value = std::uint16_t(actual[x * 6 + c * 2]) |
                                       std::uint16_t(actual[x * 6 + c * 2 + 1]) << 8;
                    if (value != expected[x * 4 + c]) throw std::runtime_error("TIFF pixels differ from supplied held frame");
                }
        }
        previous_end = std::uint64_t(offset) + bytes;
    }
    check(previous_end == file.length, "TIFF pixel extent does not end at file end");
    TiffReader icc(profile_path);
    const auto& embedded = tags.at(34675);
    check(embedded.type == 7 && embedded.bytes == icc.read(0, std::size_t(icc.length)), "export changed pinned sRGB ICC");
}

Json frame_report(const Frame& frame) {
    Json entry = Json::object();
    entry.set("width", Json(double(frame.width()))); entry.set("height", Json(double(frame.height())));
    entry.set("film", Json(frame.settings.film_stock)); entry.set("paper", Json(frame.settings.print_stock));
    entry.set("print_exposure", Json(frame.settings.print_exposure));
    entry.set("reprint", Json(frame.reprint())); entry.set("negative_was_cached", Json(frame.negative_was_cached()));
    entry.set("headroom", Json(frame.metadata.headroom_enabled));
    Json timings = Json::object();
    timings.set("decode_ms", Json(frame.timings.decode_ms)); timings.set("open_ms", Json(frame.timings.open_ms));
    timings.set("params_ms", Json(frame.timings.params_ms)); timings.set("render_ms", Json(frame.timings.render_ms));
    timings.set("engine_render_ms", Json(frame.timings.engine_render_ms));
    timings.set("display_ms", Json(frame.timings.display_ms)); timings.set("total_ms", Json(frame.timings.total_ms));
    entry.set("timings", std::move(timings));
    return entry;
}

void integration(const fs::path& resources, const fs::path& arw,
                 const fs::path& nef, const fs::path& destination) {
    check(fs::create_directory(destination), "integration destination must be a new directory");
    Json report = Json::object();
    report.set("arw", Json(path_text(arw))); report.set("nef", Json(path_text(nef)));
    FramePtr first;
    std::uint64_t first_pixels = 0, first_display = 0;
    const auto exported = destination / fs::path(u8"已显示帧-原始16位.tif");
    {
        PreviewHost host(resources);
        check(!host.current(), "new host already has a frame");
        report.set("engine_create_ms", Json(host.engine_create_ms()));
        const auto& catalog = host.catalog();
        check(catalog.films.size() > 1 && !catalog.papers.empty(), "desktop catalog unavailable");
        rejected([&] { host.render({}); }, "render before open accepted");
        first = host.open_raw(arw, DecodeMode::compatible16);
        check(first && first == host.current(), "successful open did not publish its frame");
        check(first->width() == 4688 && first->height() == 7028, "full Sony ARW fixture dimensions differ");
        check(!first->reprint() && !first->negative_was_cached() && !first->metadata.headroom_enabled,
              "first compatible open has incorrect cache/mode flags");
        check(first->bgra8.size() == std::size_t(first->width()) * first->height() * 4,
              "display does not contain full-resolution pixels");
        first_pixels = frame_fingerprint(*first);
        first_display = fingerprint(first->bgra8.data(), first->bgra8.size());
        report.set("first_open", frame_report(*first));

        RenderSettings print_edit = first->settings;
        print_edit.print_exposure = 1.25;
        auto edited = host.render(print_edit);
        check(edited && edited != first && edited->reprint() && edited->negative_was_cached(),
              "print exposure edit did not reuse negative cache");
        check(edited->settings.print_exposure == 1.25 && edited->timings.decode_ms == 0 && edited->timings.open_ms == 0,
              "print edit changed settings incorrectly or reopened RAW");
        report.set("print_edit", frame_report(*edited));
        const auto nef_error = rejected([&] { host.open_raw(nef, DecodeMode::compatible16); }, "unsupported Nikon HE file opened");
        check(nef_error.find("Nikon HE/HE*") != std::string::npos, "Nikon failure lacks compression diagnosis");
        check(host.current() == edited, "failed Nikon open replaced prior frame");
        report.set("nef_failure", Json(nef_error));
        print_edit.print_exposure = 0.8;
        auto after_failure = host.render(print_edit);
        check(after_failure->reprint() && after_failure->negative_was_cached(), "Nikon open failure damaged reusable session");
        report.set("render_after_nef_failure", frame_report(*after_failure));

        for (unsigned variant = 0; variant < 4; ++variant) {
            auto invalid = print_edit;
            if (variant == 0) invalid.film_stock = "__missing_desktop_film__";
            if (variant == 1) invalid.print_stock = "__missing_desktop_paper__";
            if (variant == 2) invalid.print_exposure = 0;
            if (variant == 3) invalid.print_exposure = std::numeric_limits<double>::quiet_NaN();
            rejected([&] { host.render(invalid); }, "invalid render setting accepted");
            check(host.current() == after_failure, "invalid settings changed current frame");
        }
        auto film_edit = print_edit;
        const auto alternate = std::find_if(catalog.films.begin(), catalog.films.end(),
            [&](const Stock& stock) { return stock.id != film_edit.film_stock; });
        check(alternate != catalog.films.end(), "no alternate film for edit test");
        film_edit.film_stock = alternate->id;
        auto changed_film = host.render(film_edit);
        check(!changed_film->reprint() && !changed_film->negative_was_cached(), "film edit incorrectly reused old negative");
        check(changed_film->settings.film_stock == film_edit.film_stock, "film edit not reflected in frame");
        report.set("film_edit", frame_report(*changed_film));
        edited.reset(); after_failure.reset(); changed_film.reset();

        auto headroom = host.open_raw(arw, DecodeMode::headroom);
        check(headroom && headroom->metadata.headroom_enabled && headroom->decode_mode == DecodeMode::headroom &&
              headroom->width() == first->width() && headroom->height() == first->height(), "headroom reopen failed");
        report.set("headroom_open", frame_report(*headroom));
        check(frame_fingerprint(*first) == first_pixels &&
              fingerprint(first->bgra8.data(), first->bgra8.size()) == first_display,
              "later renders or opens modified previously displayed frame");
        // Export the original held stochastic result after newer frames exist.
        // Comparing two independently rendered stochastic images would be invalid.
        const auto export_start = std::chrono::steady_clock::now();
        host.export_tiff(*first, exported);
        report.set("export_ms", Json(std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - export_start).count()));
        compare_tiff(exported, *first, resources / "io/sRGB.icc");
        rejected([&] { host.export_tiff(*headroom, exported); }, "export overwrote existing TIFF");
        compare_tiff(exported, *first, resources / "io/sRGB.icc");
        check(host.current() == headroom, "export changed active frame");
    }
    check(frame_fingerprint(*first) == first_pixels &&
          fingerprint(first->bgra8.data(), first->bgra8.size()) == first_display,
          "display/result invalid after host and engine destruction");
    compare_tiff(exported, *first, resources / "io/sRGB.icc");
    first.reset();  // spk_result_free is intentionally exercised without engine.
    report.set("status", Json(std::string("passed")));
    report.set("checks", Json(double(checks)));
    report.set("held_rgba16_fnv1a64", Json(hex(first_pixels)));
    report.set("held_bgra8_fnv1a64", Json(hex(first_display)));
    report.set("exported_tiff", Json(path_text(exported)));
    report.set("pixel_comparison", Json(std::string("Every exported RGB16 sample equals the same held Frame; no second stochastic render used as oracle.")));
    report.set("limits", Json(std::string("Host integration only; no claim of visible-window, colour-managed monitor or interactive responsiveness verification.")));
    std::ofstream stream(destination / "integration.json", std::ios::binary);
    check(bool(stream << report.dump() << '\n') && bool(stream.flush()), "cannot write integration report");
}

}  // namespace

int main(int argc, char** argv) {
    try {
        conversion();
        viewport_geometry();
        if (argc != 1) {
            if (argc != 6 || std::string(argv[1]) != "--integration") {
                std::cerr << "usage: spk_desktop_preview_test [--integration <resources> <ARW> <NEF> <new-output-directory>]\n";
                return 2;
            }
            integration(fs::path(reinterpret_cast<const char8_t*>(argv[2])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[3])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[4])),
                        fs::path(reinterpret_cast<const char8_t*>(argv[5])));
        }
        std::cout << "Desktop preview boundary: " << checks << " checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
