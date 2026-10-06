// Fixed, already-decoded pixels through the public C ABI. Link this driver to
// the test DLL: no private engine headers or C++ symbols cross that boundary.
#include "spektrafilm/spk_engine.h"

#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <locale>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
namespace fs = std::filesystem;

// Reports are ASCII JSON even if an OS error contains non-UTF-8 bytes. The
// engine fragments are embedded only after successful C API calls; user text
// stays quoted until spk_open has parsed and validated it.
std::string quote(const std::string& text) {
    constexpr char hex[] = "0123456789abcdef";
    std::string out = "\"";
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') { out += '\\'; out += char(c); }
        else if (c < 0x20 || c >= 0x80) {
            out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15];
        } else out += char(c);
    }
    return out + '"';
}

std::string fragment(const std::string& text) {
    if (text.empty()) return "null";
    // Non-ASCII bytes in an engine JSON fragment occur inside strings.
    // Escape them for the same byte-preserving diagnostic convention as quote.
    constexpr char hex[] = "0123456789abcdef";
    std::string out;
    for (unsigned char c : text) {
        if (c >= 0x80) { out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15]; }
        else out += char(c);
    }
    return out;
}

const char* boolean(bool value) { return value ? "true" : "false"; }

std::string number(double value) {
    if (!std::isfinite(value)) return "null";
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::setprecision(17) << value;
    return out.str();
}

double elapsed(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

uint32_t dimension(const char* text, const char* label) {
    if (!text || !*text) throw std::runtime_error(std::string(label) + " is empty");
    uint64_t value = 0;
    for (const char* p = text; *p; ++p) {
        if (*p < '0' || *p > '9')
            throw std::runtime_error(std::string(label) + " must be a positive integer");
        value = value * 10 + uint64_t(*p - '0');
        if (value > std::numeric_limits<uint32_t>::max())
            throw std::runtime_error(std::string(label) + " exceeds uint32");
    }
    if (!value) throw std::runtime_error(std::string(label) + " must be positive");
    return uint32_t(value);
}

fs::path normalized(const std::string& path) {
    return fs::weakly_canonical(fs::absolute(fs::path(path)));
}

bool same_path(const std::string& left, const std::string& right) {
    // equivalent also catches existing hard links; canonical handles symlinks.
    std::error_code error;
    if (fs::equivalent(fs::path(left), fs::path(right), error) && !error) return true;
    auto a = normalized(left).native(), b = normalized(right).native();
#ifdef _WIN32
    // A new output path has no filesystem object for equivalent to inspect.
    std::transform(a.begin(), a.end(), a.begin(), [](wchar_t c) { return std::towlower(c); });
    std::transform(b.begin(), b.end(), b.begin(), [](wchar_t c) { return std::towlower(c); });
#endif
    return a == b;
}

std::string read_params(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("cannot open params file: " + path);
    const auto size = file.tellg();
    if (size <= 0 || size > 1024 * 1024)
        throw std::runtime_error("params file must contain a JSON object of at most 1 MiB");
    std::string text(size_t(size), '\0');
    file.seekg(0);
    if (!file.read(text.data(), std::streamsize(text.size())))
        throw std::runtime_error("cannot read params file: " + path);
    if (text.find('\0') != std::string::npos)
        throw std::runtime_error("params file contains a NUL byte");
    if (text.find_first_not_of(" \t\r\n") == std::string::npos)
        throw std::runtime_error("params file is empty");
    return text;
}

std::vector<float> read_pixels(const std::string& path, uint64_t bytes) {
    static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559,
                  "fixture input requires IEEE-754 binary32");
    if (bytes > uint64_t(std::numeric_limits<size_t>::max()) ||
        bytes > uint64_t(std::numeric_limits<std::streamsize>::max()))
        throw std::runtime_error("input dimensions exceed this process's addressable file size");
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("cannot open pixel file: " + path);
    const auto size = file.tellg();
    if (size < 0 || uint64_t(size) != bytes)
        throw std::runtime_error("pixel file length must be exactly " + std::to_string(bytes) +
                                 " bytes (width * height * 3 * 4)");
    std::vector<float> pixels(size_t(bytes / sizeof(float)));
    file.seekg(0);
    if (!file.read(reinterpret_cast<char*>(pixels.data()), std::streamsize(bytes)))
        throw std::runtime_error("cannot read pixel file: " + path);
    for (size_t i = 0; i < pixels.size(); ++i) {
        if constexpr (std::endian::native != std::endian::little) {
            auto* value = reinterpret_cast<unsigned char*>(&pixels[i]);
            std::reverse(value, value + 4);
        }
        if (!std::isfinite(pixels[i]))
            throw std::runtime_error("input contains NaN or infinity at float index " +
                                     std::to_string(i));
    }
    return pixels;
}

struct EngineDeleter { void operator()(spk_engine* value) const { spk_engine_destroy(value); } };
struct SessionDeleter { void operator()(spk_session* value) const { spk_session_release(value); } };
struct StringDeleter { void operator()(char* value) const { spk_string_free(value); } };
using Engine = std::unique_ptr<spk_engine, EngineDeleter>;
using Session = std::unique_ptr<spk_session, SessionDeleter>;

struct Result {
    spk_result value{};
    ~Result() { spk_result_free(&value); }
};

std::vector<uint16_t> packed(const spk_result& result) {
    if (!result.rgba16 || !result.texture || !result.width || !result.height ||
        result.row_stride_px < result.width)
        throw std::runtime_error("engine returned invalid result pixels, dimensions or row pitch");
    const uint64_t values = uint64_t(result.width) * result.height * 4;
    const uint64_t pitched_values = uint64_t(result.row_stride_px) * result.height * 4;
    if (values > std::numeric_limits<size_t>::max() / sizeof(uint16_t) ||
        pitched_values > std::numeric_limits<size_t>::max() / sizeof(uint16_t))
        throw std::runtime_error("engine result dimensions overflow addressable memory");
    std::vector<uint16_t> out(static_cast<size_t>(values));
    for (uint32_t y = 0; y < result.height; ++y)
        std::copy_n(result.rgba16 + size_t(y) * result.row_stride_px * 4,
                    size_t(result.width) * 4, out.data() + size_t(y) * result.width * 4);
    return out;
}

struct Comparison {
    bool compared = false, bit_exact = false;
    uint64_t differing_values = 0;
    uint32_t max_abs_u16 = 0;
};

Comparison compare(const std::vector<uint16_t>& a, const std::vector<uint16_t>& b) {
    Comparison out;
    out.compared = true;
    if (a.size() != b.size()) { out.differing_values = std::max(a.size(), b.size()); return out; }
    for (size_t i = 0; i < a.size(); ++i) {
        const uint32_t delta = uint32_t(std::abs(int(a[i]) - int(b[i])));
        if (delta) ++out.differing_values;
        out.max_abs_u16 = std::max(out.max_abs_u16, delta);
    }
    out.bit_exact = out.differing_values == 0;
    return out;
}

std::string comparison_json(const Comparison& value) {
    return "{\"compared\":" + std::string(boolean(value.compared)) +
           ",\"bit_exact\":" + boolean(value.bit_exact) +
           ",\"differing_values\":" + std::to_string(value.differing_values) +
           ",\"max_abs_u16\":" + std::to_string(value.max_abs_u16) + '}';
}

struct RenderLog {
    std::string method, error, progress_id;
    spk_status status = SPK_ERR_INTERNAL;
    double wall_ms = 0, engine_ms = 0;
    uint32_t width = 0, height = 0, row_stride_px = 0;
    int32_t reprint = 0, negative_was_cached = 0;
};

struct Report {
    std::string resources, input, params_path, output, report_path;
    std::string stage = "arguments", error, build_info, capabilities, params, open_reply;
    bool success = false, params_valid = false, output_written = false;
    uint32_t width = 0, height = 0, out_width = 0, out_height = 0, out_stride = 0;
    uint64_t input_bytes = 0, output_bytes = 0;
    double create_ms = 0, open_ms = 0, total_ms = 0;
    std::vector<RenderLog> renders;
    Comparison repeatability, reprint_comparison;
    bool reprint_attempted = false, session_lifetime = false, engine_lifetime = false;
    bool free_cleared = false;
};

std::string compiler() {
#if defined(__clang__)
    return std::string("clang ") + __clang_version__;
#elif defined(__GNUC__)
    return std::string("gcc ") + __VERSION__;
#elif defined(_MSC_VER)
    return "msvc " + std::to_string(_MSC_VER);
#else
    return "unknown";
#endif
}

std::string report_json(const Report& r) {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << "{\n\"format_version\":1,\"success\":" << boolean(r.success)
        << ",\"stage\":" << quote(r.stage) << ",\"error\":" << quote(r.error)
        << ",\n\"environment\":{\"platform\":"
#ifdef _WIN32
        << "\"windows\""
#elif defined(__APPLE__)
        << "\"macos\""
#else
        << "\"other\""
#endif
        << ",\"compiler\":" << quote(compiler())
        << ",\"pointer_bits\":" << sizeof(void*) * 8
        << ",\"build_info\":" << quote(r.build_info)
        << ",\"transport_version\":" << SPK_TRANSPORT_VERSION
        << ",\"schema_version\":" << SPK_SCHEMA_VERSION << '}'
        << ",\n\"resources_dir\":" << quote(r.resources)
        << ",\"capabilities\":" << fragment(r.capabilities)
        << ",\n\"input\":{\"path\":" << quote(r.input)
        << ",\"width\":" << r.width << ",\"height\":" << r.height
        << ",\"channels\":3,\"format\":\"float32_le_rgb\",\"row_order\":\"top_down\""
        << ",\"color_space\":\"ProPhoto RGB\",\"transfer\":\"linear\""
        << ",\"byte_count\":" << r.input_bytes << '}'
        << ",\n\"params_path\":" << quote(r.params_path)
        << ",\"params_delta_text\":" << quote(r.params)
        << ",\"params_delta\":" << (r.params_valid ? fragment(r.params) : "null")
        << ",\"open_reply\":" << fragment(r.open_reply)
        << ",\n\"output\":{\"path\":" << quote(r.output)
        << ",\"written\":" << boolean(r.output_written)
        << ",\"width\":" << r.out_width << ",\"height\":" << r.out_height
        << ",\"row_stride_px\":" << r.out_stride
        << ",\"packed_row_stride_px\":" << r.out_width
        << ",\"byte_count\":" << r.output_bytes
        << ",\"format\":\"uint16_le_rgba\",\"row_order\":\"top_down\"}"
        << ",\n\"timings\":{\"engine_create_wall_ms\":" << number(r.create_ms)
        << ",\"open_wall_ms\":" << number(r.open_ms)
        << ",\"total_wall_ms\":" << number(r.total_ms) << '}'
        << ",\n\"renders\":[";
    for (size_t i = 0; i < r.renders.size(); ++i) {
        const auto& render = r.renders[i];
        if (i) out << ',';
        out << "{\"method\":" << quote(render.method) << ",\"tier\":\"full\""
            << ",\"status\":" << render.status << ",\"error\":" << quote(render.error)
            << ",\"wall_ms\":" << number(render.wall_ms)
            << ",\"engine_ms\":" << number(render.engine_ms)
            << ",\"width\":" << render.width << ",\"height\":" << render.height
            << ",\"row_stride_px\":" << render.row_stride_px
            << ",\"reprint\":" << render.reprint
            << ",\"negative_was_cached\":" << render.negative_was_cached
            << ",\"progress_id\":" << quote(render.progress_id) << '}';
    }
    out << "],\n\"repeatability\":" << comparison_json(r.repeatability)
        << ",\"reprint\":{\"attempted\":" << boolean(r.reprint_attempted)
        << ",\"comparison\":" << comparison_json(r.reprint_comparison) << '}'
        << ",\n\"result_lifetime\":{\"readable_after_session_release\":" << boolean(r.session_lifetime)
        << ",\"readable_after_engine_destroy\":" << boolean(r.engine_lifetime)
        << ",\"free_cleared\":" << boolean(r.free_cleared) << "}\n}\n";
    return out.str();
}

RenderLog render(spk_session* session, spk_engine* engine, bool reprint, Result& result) {
    RenderLog log;
    log.method = reprint ? "reprint" : "render";
    const auto started = Clock::now();
    log.status = reprint ? spk_reprint(session, "full", &result.value)
                         : spk_render(session, "full", &result.value);
    log.wall_ms = elapsed(started);
    if (log.status != SPK_OK) log.error = spk_last_error(engine);
    const auto& value = result.value;
    log.engine_ms = value.elapsed_ms;
    log.width = value.width; log.height = value.height; log.row_stride_px = value.row_stride_px;
    log.reprint = value.reprint; log.negative_was_cached = value.negative_was_cached;
    log.progress_id.assign(value.progress_id,
                          std::find(value.progress_id, value.progress_id + sizeof value.progress_id, '\0'));
    return log;
}

void write_pixels(const std::string& path, const std::vector<uint16_t>& pixels) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) throw std::runtime_error("cannot open output file: " + path);
    if constexpr (std::endian::native == std::endian::little) {
        file.write(reinterpret_cast<const char*>(pixels.data()),
                   std::streamsize(pixels.size() * sizeof(uint16_t)));
    } else {
        for (uint16_t value : pixels) { file.put(char(value & 255)); file.put(char(value >> 8)); }
    }
    file.close();
    if (!file) throw std::runtime_error("cannot write output file: " + path);
}

void run(Report& r, const char* width, const char* height) {
    // The report path is checked before any write, including the failure path.
    if (same_path(r.input, r.output) || same_path(r.params_path, r.output))
        throw std::runtime_error("output path must differ from both input files");
    r.width = dimension(width, "width"); r.height = dimension(height, "height");
    const uint64_t pixels = uint64_t(r.width) * r.height;
    if (pixels > std::numeric_limits<uint64_t>::max() / 12)
        throw std::runtime_error("input dimensions overflow byte count");
    r.input_bytes = pixels * 12;
    r.stage = "read_input";
    auto input = read_pixels(r.input, r.input_bytes);
    r.params = read_params(r.params_path);
    r.stage = "create_engine";
    r.build_info = spk_build_info();
    auto started = Clock::now();
    Engine engine(spk_engine_create(r.resources.c_str(), nullptr));
    r.create_ms = elapsed(started);
    if (!engine) throw std::runtime_error(spk_last_error(nullptr));
    r.capabilities = spk_capabilities(engine.get());
    r.stage = "open";
    spk_image image{input.data(), r.width, r.height, 3};
    char* reply = nullptr;
    started = Clock::now();
    Session session(spk_open(engine.get(), &image, r.params.c_str(), &reply));
    std::unique_ptr<char, StringDeleter> owned_reply(reply);
    r.open_ms = elapsed(started);
    if (!session) throw std::runtime_error(spk_last_error(engine.get()));
    r.params_valid = true;
    if (!reply) throw std::runtime_error("spk_open succeeded without its requested JSON reply");
    r.open_reply = reply;
    owned_reply.reset();
    // The C ABI promises to copy input at open: release the caller's storage
    // before rendering so the driver exercises that promise as well.
    std::vector<float>().swap(input);

    Result first, second, reprinted;
    r.stage = "render_first";
    r.renders.push_back(render(session.get(), engine.get(), false, first));
    if (r.renders.back().status != SPK_OK) throw std::runtime_error(r.renders.back().error);
    const auto first_pixels = packed(first.value);
    r.out_width = first.value.width; r.out_height = first.value.height;
    r.out_stride = first.value.row_stride_px;
    r.output_bytes = uint64_t(first_pixels.size()) * sizeof(uint16_t);
    r.stage = "render_second";
    r.renders.push_back(render(session.get(), engine.get(), false, second));
    if (r.renders.back().status != SPK_OK) throw std::runtime_error(r.renders.back().error);
    const auto second_pixels = packed(second.value);
    r.repeatability = compare(first_pixels, second_pixels);
    if (first.value.width != second.value.width || first.value.height != second.value.height)
        r.repeatability.bit_exact = false;

    r.stage = "reprint";
    r.reprint_attempted = true;
    r.renders.push_back(render(session.get(), engine.get(), true, reprinted));
    std::vector<uint16_t> reprint_pixels;
    if (r.renders.back().status == SPK_OK) {
        reprint_pixels = packed(reprinted.value);
        r.reprint_comparison = compare(second_pixels, reprint_pixels);
        if (second.value.width != reprinted.value.width || second.value.height != reprinted.value.height)
            r.reprint_comparison.bit_exact = false;
    }

    const auto unchanged = [&] {
        return packed(first.value) == first_pixels && packed(second.value) == second_pixels &&
               (reprint_pixels.empty() || packed(reprinted.value) == reprint_pixels);
    };
    r.stage = "result_lifetime";
    session.reset();
    r.session_lifetime = unchanged();
    engine.reset();
    r.engine_lifetime = unchanged();
    spk_result_free(&first.value); spk_result_free(&second.value); spk_result_free(&reprinted.value);
    r.free_cleared = !first.value.rgba16 && !first.value.texture &&
                     !second.value.rgba16 && !second.value.texture &&
                     !reprinted.value.rgba16 && !reprinted.value.texture;
    if (!r.session_lifetime || !r.engine_lifetime || !r.free_cleared)
        throw std::runtime_error("result ownership or release failed");
    if (!r.repeatability.bit_exact)
        throw std::runtime_error("the two full renders differ; fixed pixel comparisons require deterministic params");
    for (size_t i = 0; i < 2; ++i)
        if (r.renders[i].reprint || r.renders[i].negative_was_cached)
            throw std::runtime_error("spk_render reported reuse instead of recomputing the negative");
    r.stage = "write_output";
    write_pixels(r.output, first_pixels);
    r.output_written = true;
    r.stage = "complete";
    r.success = true;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 8) {
        std::cerr << "usage: spk_render_fixture <resources> <input.f32> <width> <height> "
                     "<params.json> <output.rgba16> <report.json>\n";
        return 2;
    }
    const auto started = Clock::now();
    Report report;
    report.resources = argv[1]; report.input = argv[2]; report.params_path = argv[5];
    report.output = argv[6]; report.report_path = argv[7];
    bool report_path_safe = false;
    try {
        if (same_path(report.report_path, report.input) ||
            same_path(report.report_path, report.params_path) ||
            same_path(report.report_path, report.output))
            throw std::runtime_error("report path must differ from the pixel, params and output paths");
        report_path_safe = true;
        run(report, argv[3], argv[4]);
    } catch (const std::exception& error) {
        report.success = false;
        report.error = error.what();
    } catch (...) {
        report.success = false;
        report.error = "unknown driver exception";
    }
    report.total_ms = elapsed(started);
    if (report_path_safe) {
        std::ofstream file(report.report_path, std::ios::binary | std::ios::trunc);
        file << report_json(report);
        file.close();
        if (!file) {
            std::cerr << "cannot write report file: " << report.report_path << '\n';
            return 1;
        }
    }
    if (!report.success) {
        std::cerr << report.stage << ": " << report.error << '\n';
        return 1;
    }
    std::cout << report.out_width << 'x' << report.out_height << " RGBA16; full renders bit-exact; "
              << "results survived session and engine release\n";
    return 0;
}
