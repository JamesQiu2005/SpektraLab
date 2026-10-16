// TIFF, JPEG and PNG at the door, through the real engine (AGENTS.md traps 11
// and 12): an encoded file must develop exactly like its linear equivalent.
//
// Every test of this repository used to feed linear input, so a transfer
// function forgotten, applied twice or applied after the meter would pass
// unseen (trap 11: three such bugs live at once behind 750 green tests). This
// is the invariance RFC-010 asks for -- same meaning, different
// representation, identical render -- with the representations made here:
//
//   * an 8-bit PNG with no profile (the macOS decoder's rule: sRGB),
//   * a baseline JPEG with no profile (sRGB),
//   * a 16-bit TIFF carrying the engine's own sRGB.icc,
//   * a 16-bit TIFF carrying a ROMM RGB gamma-1.8 profile written here,
//
// each against a float32 TIFF without a profile (linear ProPhoto, passed
// through untouched) holding what the encoded codes MEAN, computed here from
// published primaries, Bradford and the transfer function each file declares
// -- not from image_io's tables. The decode is checked directly (the
// DecodedRaw the host keeps) and through a full develop (auto exposure on,
// grain and glare off, the only stochastic stage being glare: trap 1).
//
// A control proves the comparison can fail: the PNG's codes handed over as if
// they were already linear -- the "forgot the transfer function" bug -- must
// develop measurably differently from the decoded PNG.
//
// Arguments: <engine resources> <new or reusable scratch directory>.
#include "desktop/preview_host.hpp"
#include "desktop/raw_white_balance.hpp"

#include "stb_image.h"
#include "stb_image_write.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace spk::desktop;

namespace {

int failures = 0, checks = 0;
void check(bool ok, const std::string& what) {
    ++checks;
    if (!ok) { ++failures; std::cerr << "FAIL: " << what << "\n"; }
}

using M3 = std::array<double, 9>;
M3 mul(const M3& a, const M3& b) {
    M3 r{};
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            for (int k = 0; k < 3; ++k) r[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j];
    return r;
}
M3 inverse(const M3& m) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    return {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det};
}
std::array<double, 3> xyz(double x, double y) { return {x / y, 1.0, (1 - x - y) / y}; }
// RGB -> XYZ from chromaticities (the normalised primary matrix).
M3 npm(const std::array<double, 8>& xy) {
    const auto r = xyz(xy[0], xy[1]), g = xyz(xy[2], xy[3]), b = xyz(xy[4], xy[5]), w = xyz(xy[6], xy[7]);
    const M3 p{r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]};
    const M3 pi = inverse(p);
    const double s0 = pi[0] * w[0] + pi[1] * w[1] + pi[2] * w[2];
    const double s1 = pi[3] * w[0] + pi[4] * w[1] + pi[5] * w[2];
    const double s2 = pi[6] * w[0] + pi[7] * w[1] + pi[8] * w[2];
    return {p[0] * s0, p[1] * s1, p[2] * s2, p[3] * s0, p[4] * s1, p[5] * s2, p[6] * s0, p[7] * s1, p[8] * s2};
}
// Bradford, white to white.
M3 bradford(std::array<double, 2> from, std::array<double, 2> to) {
    const M3 b{0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296};
    const auto ws = xyz(from[0], from[1]), wd = xyz(to[0], to[1]);
    std::array<double, 3> cs{}, cd{};
    for (int i = 0; i < 3; ++i) {
        cs[i] = b[i * 3] * ws[0] + b[i * 3 + 1] * ws[1] + b[i * 3 + 2] * ws[2];
        cd[i] = b[i * 3] * wd[0] + b[i * 3 + 1] * wd[1] + b[i * 3 + 2] * wd[2];
    }
    const M3 scale{cd[0] / cs[0], 0, 0, 0, cd[1] / cs[1], 0, 0, 0, cd[2] / cs[2]};
    return mul(inverse(b), mul(scale, b));
}
constexpr std::array<double, 8> kSrgb{0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290};
constexpr std::array<double, 8> kProPhoto{0.7347, 0.2653, 0.1596, 0.8404, 0.0366, 0.0001, 0.3457, 0.3585};
// Linear sRGB (D65) -> linear ProPhoto (D50), from the published numbers.
M3 srgbToProPhoto() {
    return mul(inverse(npm(kProPhoto)), mul(bradford({0.3127, 0.3290}, {0.3457, 0.3585}), npm(kSrgb)));
}
double srgbDecode(double v) { return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4); }
// The ROMM profile's curve as written below: u8Fixed8 461 = 1.80078125.
constexpr double kRommGamma = 461.0 / 256.0;

// --- writers: what another program would hand us -----------------------------

void put16(std::vector<uint8_t>& b, uint16_t v) { b.push_back(uint8_t(v)); b.push_back(uint8_t(v >> 8)); }
void put32(std::vector<uint8_t>& b, uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back(uint8_t(v >> (8 * i))); }

// A baseline little-endian TIFF: RGB, one strip, uncompressed; `bits` 16 or
// 32 (float); `icc` embedded as tag 34675 when not empty.
void writeTiff(const fs::path& path, uint32_t w, uint32_t h, int bits, const std::vector<uint8_t>& pixels,
               const std::vector<uint8_t>& icc) {
    struct Entry { uint16_t tag, type; uint32_t count; std::vector<uint8_t> data; };
    auto shorts = [](uint16_t tag, std::vector<uint16_t> v) {
        Entry e{tag, 3, uint32_t(v.size()), {}};
        for (auto s : v) put16(e.data, s);
        return e;
    };
    auto longs = [](uint16_t tag, uint32_t v) { Entry e{tag, 4, 1, {}}; put32(e.data, v); return e; };
    const uint16_t b = uint16_t(bits);
    std::vector<Entry> entries{longs(256, w), longs(257, h), shorts(258, {b, b, b}), shorts(259, {1}),
                               shorts(262, {2}), longs(273, 0), shorts(277, {3}), longs(278, h),
                               longs(279, uint32_t(pixels.size())), shorts(284, {1}),
                               shorts(339, {uint16_t(bits == 32 ? 3 : 1), uint16_t(bits == 32 ? 3 : 1), uint16_t(bits == 32 ? 3 : 1)})};
    if (!icc.empty()) entries.push_back(Entry{34675, 7, uint32_t(icc.size()), icc});
    std::sort(entries.begin(), entries.end(), [](const Entry& x, const Entry& y) { return x.tag < y.tag; });
    const uint32_t ifd = 8, ifdSize = 2 + uint32_t(entries.size()) * 12 + 4;
    uint32_t extra = ifd + ifdSize;
    std::vector<uint8_t> outOfLine;
    std::vector<uint32_t> offsets(entries.size(), 0);
    for (std::size_t i = 0; i < entries.size(); ++i)
        if (entries[i].data.size() > 4) {
            offsets[i] = extra + uint32_t(outOfLine.size());
            outOfLine.insert(outOfLine.end(), entries[i].data.begin(), entries[i].data.end());
            if (outOfLine.size() % 2) outOfLine.push_back(0);
        }
    const uint32_t pixelOffset = extra + uint32_t(outOfLine.size());
    std::vector<uint8_t> file{'I', 'I'};
    put16(file, 42);
    put32(file, ifd);
    put16(file, uint16_t(entries.size()));
    for (std::size_t i = 0; i < entries.size(); ++i) {
        auto& e = entries[i];
        if (e.tag == 273) { e.data.clear(); put32(e.data, pixelOffset); }
        put16(file, e.tag); put16(file, e.type); put32(file, e.count);
        if (e.data.size() > 4) put32(file, offsets[i]);
        else { auto d = e.data; d.resize(4, 0); file.insert(file.end(), d.begin(), d.end()); }
    }
    put32(file, 0);
    file.insert(file.end(), outOfLine.begin(), outOfLine.end());
    file.insert(file.end(), pixels.begin(), pixels.end());
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(file.data()), std::streamsize(file.size()));
    if (!out) throw std::runtime_error("cannot write " + path.string());
}

void writeFloatTiff(const fs::path& path, uint32_t w, uint32_t h, const std::vector<float>& rgb) {
    std::vector<uint8_t> bytes(rgb.size() * 4);
    std::memcpy(bytes.data(), rgb.data(), bytes.size());
    writeTiff(path, w, h, 32, bytes, {});
}

void be32(std::vector<uint8_t>& b, std::size_t at, uint32_t v) {
    for (int i = 0; i < 4; ++i) b[at + i] = uint8_t(v >> (24 - 8 * i));
}
// A matrix/TRC ICC profile: ProPhoto's D50 colorants, a gamma-1.8 curve on
// each channel -- ROMM RGB as Photoshop and Capture One label it.
std::vector<uint8_t> rommProfile() {
    const double colorants[3][3] = {{0.7976749, 0.2880402, 0.0}, {0.1351917, 0.7118741, 0.0},
                                    {0.0313534, 0.0000857, 0.8252100}};
    std::vector<uint8_t> p(128, 0);
    std::memcpy(&p[12], "mntr", 4);
    std::memcpy(&p[16], "RGB ", 4);
    std::memcpy(&p[20], "XYZ ", 4);
    std::memcpy(&p[36], "acsp", 4);
    const char* sigs[6] = {"rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC"};
    const uint32_t tableAt = 128, count = 6, dataAt = tableAt + 4 + count * 12;
    p.resize(dataAt, 0);
    be32(p, 128, count);
    for (uint32_t i = 0; i < count; ++i) {
        std::vector<uint8_t> body;
        if (i < 3) {
            body = {'X', 'Y', 'Z', ' ', 0, 0, 0, 0};
            for (int r = 0; r < 3; ++r) {
                const int32_t v = int32_t(std::lround(colorants[i][r] * 65536.0));
                for (int k = 0; k < 4; ++k) body.push_back(uint8_t(uint32_t(v) >> (24 - 8 * k)));
            }
        } else {
            body = {'c', 'u', 'r', 'v', 0, 0, 0, 0, 0, 0, 0, 1, uint8_t(461 >> 8), uint8_t(461 & 0xFF)};
        }
        const uint32_t at = uint32_t(p.size());
        p.insert(p.end(), body.begin(), body.end());
        while (p.size() % 4) p.push_back(0);
        const std::size_t e = tableAt + 4 + i * 12;
        std::memcpy(&p[e], sigs[i], 4);
        be32(p, e + 4, at);
        be32(p, e + 8, uint32_t(body.size()));
    }
    be32(p, 0, uint32_t(p.size()));
    return p;
}

std::vector<uint8_t> readFile(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), {});
}

// --- the synthetic scene ------------------------------------------------------

constexpr uint32_t W = 160, H = 96;
// A neutral ramp across the top, colour patches below: values in [0, 1].
std::array<double, 3> scene(uint32_t x, uint32_t y) {
    const double u = double(x) / (W - 1), v = double(y) / (H - 1);
    if (y < H / 3) return {u, u, u};
    const double r = 0.5 + 0.45 * std::sin(6.2831853 * u), g = 0.5 + 0.45 * std::cos(6.2831853 * (u + v)),
                 b = 0.15 + 0.8 * v * (1 - 0.5 * u);
    return {std::clamp(r, 0.0, 1.0), std::clamp(g, 0.0, 1.0), std::clamp(b, 0.0, 1.0)};
}

// What sRGB codes mean in linear ProPhoto.
std::vector<float> srgbMeaning(const std::vector<double>& codes, double top) {
    const M3 m = srgbToProPhoto();
    std::vector<float> out(codes.size());
    for (std::size_t p = 0; p < codes.size(); p += 3) {
        const double l[3] = {srgbDecode(codes[p] / top), srgbDecode(codes[p + 1] / top), srgbDecode(codes[p + 2] / top)};
        for (int r = 0; r < 3; ++r) out[p + r] = float(m[r * 3] * l[0] + m[r * 3 + 1] * l[1] + m[r * 3 + 2] * l[2]);
    }
    return out;
}

struct Diff { double max = 0, mean = 0; };
Diff compare(const std::vector<float>& a, const std::vector<float>& b) {
    Diff d;
    if (a.size() != b.size() || a.empty()) return {1e9, 1e9};
    for (std::size_t i = 0; i < a.size(); ++i) {
        const double e = std::abs(double(a[i]) - b[i]);
        d.max = std::max(d.max, e);
        d.mean += e;
    }
    d.mean /= double(a.size());
    return d;
}
std::vector<float> printed(const FramePtr& frame) {
    const auto& px = frame->pixels();
    std::vector<float> out;
    out.reserve(std::size_t(px.width) * px.height * 3);
    for (uint32_t y = 0; y < px.height; ++y)
        for (uint32_t x = 0; x < px.width; ++x)
            for (int c = 0; c < 3; ++c)
                out.push_back(float(px.rgba16[(std::size_t(y) * px.row_stride_px + x) * 4 + c] / 65535.0));
    return out;
}

struct Developed { std::vector<float> decode, print; std::string decoder; };
Developed develop(PreviewHost& host, const fs::path& file) {
    RenderSettings s;
    s.set("grain_active", false);
    s.set("glare_active", false);
    const auto frame = host.open_raw(file, DecodeMode::compatible16, s);
    return {host.decoded().rgb, printed(frame), frame->metadata.decoder_name};
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: spk_qt_flat_input_test <engine resources> <scratch directory>\n";
        return 2;
    }
    const fs::path resources = argv[1], scratch = argv[2];
    try {
        fs::create_directories(scratch);
        // 8-bit codes of the scene (as sRGB-encoded values) and 16-bit codes
        // of it under ROMM's gamma, rounded as a writer would.
        std::vector<uint8_t> codes8(std::size_t(W) * H * 3);
        std::vector<uint16_t> romm16(codes8.size()), srgb16(codes8.size());
        for (uint32_t y = 0; y < H; ++y)
            for (uint32_t x = 0; x < W; ++x) {
                const auto s = scene(x, y);
                for (int c = 0; c < 3; ++c) {
                    const std::size_t i = (std::size_t(y) * W + x) * 3 + c;
                    codes8[i] = uint8_t(std::lround(s[c] * 255));
                    srgb16[i] = uint16_t(std::lround(s[c] * 65535));
                    romm16[i] = uint16_t(std::lround(std::pow(s[c], 1.0 / kRommGamma) * 65535));
                }
            }
        const auto png = scratch / "encoded-srgb-8.png", jpg = scratch / "encoded-srgb-8.jpg";
        const auto tifSrgb = scratch / "encoded-srgb-icc-16.tif", tifRomm = scratch / "encoded-romm-icc-16.tif";
        check(stbi_write_png(png.string().c_str(), int(W), int(H), 3, codes8.data(), int(W * 3)) != 0, "write PNG");
        check(stbi_write_jpg(jpg.string().c_str(), int(W), int(H), 3, codes8.data(), 92) != 0, "write JPEG");
        const auto srgbIcc = readFile(resources / "io" / "sRGB.icc");
        check(srgbIcc.size() > 128, "the engine's sRGB.icc is readable");
        auto bytes16 = [](const std::vector<uint16_t>& v) {
            std::vector<uint8_t> b(v.size() * 2);
            std::memcpy(b.data(), v.data(), b.size());
            return b;
        };
        writeTiff(tifSrgb, W, H, 16, bytes16(srgb16), srgbIcc);
        writeTiff(tifRomm, W, H, 16, bytes16(romm16), rommProfile());

        // What each file means, linear ProPhoto, from the codes it holds.
        std::vector<double> c8(codes8.begin(), codes8.end()), c16(srgb16.begin(), srgb16.end());
        int jw = 0, jh = 0, jc = 0;
        std::unique_ptr<stbi_uc, void (*)(void*)> jpeg(stbi_load(jpg.string().c_str(), &jw, &jh, &jc, 3), stbi_image_free);
        check(jpeg && jw == int(W) && jh == int(H), "the JPEG reads back");
        std::vector<double> cj(jpeg ? std::vector<double>(jpeg.get(), jpeg.get() + c8.size()) : c8);
        std::vector<float> rommMeaning(romm16.size());
        for (std::size_t i = 0; i < romm16.size(); ++i) rommMeaning[i] = float(std::pow(romm16[i] / 65535.0, kRommGamma));

        struct Case { const char* name; fs::path encoded; std::vector<float> meaning; const char* decoder; double decodeBar; };
        std::vector<Case> cases{
            {"PNG 8-bit, no profile (sRGB)", png, srgbMeaning(c8, 255), "PNG, sRGB (assumed)", 4e-4},
            {"JPEG, no profile (sRGB)", jpg, srgbMeaning(cj, 255), "JPEG, sRGB (assumed)", 4e-4},
            // The profile's colorants and curve parameters are s15Fixed16
            // numbers: 3.9e-4 measured against the published primaries.
            {"TIFF 16-bit, sRGB.icc", tifSrgb, srgbMeaning(c16, 65535), "TIFF, ", 6e-4},
            {"TIFF 16-bit, ROMM gamma 1.8", tifRomm, rommMeaning, "TIFF, ", 1e-4},
        };
        check(flat_file(png) && flat_file(jpg) && flat_file(tifSrgb) && !flat_file(scratch / "x.nef"),
              "flat files are told from RAWs");

        PreviewHost host(resources);
        Developed pngPrint;
        for (std::size_t k = 0; k < cases.size(); ++k) {
            auto& c = cases[k];
            const auto linear = scratch / ("linear-equivalent-" + std::to_string(k) + ".tif");
            writeFloatTiff(linear, W, H, c.meaning);
            const auto encoded = develop(host, c.encoded);
            const auto reference = develop(host, linear);
            if (k == 0) pngPrint = encoded;
            const auto door = compare(encoded.decode, c.meaning);
            const auto plain = compare(reference.decode, c.meaning);
            const auto print = compare(encoded.print, reference.print);
            std::cout << c.name << ": decode max " << door.max << ", linear passthrough max " << plain.max
                      << ", print max " << print.max << " mean " << print.mean << " [" << encoded.decoder << "]\n";
            check(plain.max < 1e-6, std::string(c.name) + ": the untagged float TIFF reaches the engine untouched");
            check(door.max < c.decodeBar, std::string(c.name) + ": decoded at the door to what its codes mean");
            check(print.max < 4e-3 && print.mean < 4e-4, std::string(c.name) + ": develops like its linear equivalent");
            check(encoded.decoder.rfind(c.decoder, 0) == 0, std::string(c.name) + ": the decoder says what it read (" +
                                                               encoded.decoder + ")");
        }

        // The control: the PNG's codes handed to the engine as though linear
        // (a transfer function forgotten at the door) develop differently --
        // so the bars above can see the bug they exist for.
        std::vector<float> undecoded(c8.size());
        for (std::size_t i = 0; i < c8.size(); ++i) undecoded[i] = float(c8[i] / 255.0);
        const auto wrong = scratch / "control-codes-as-linear.tif";
        writeFloatTiff(wrong, W, H, undecoded);
        const auto control = compare(develop(host, wrong).print, pngPrint.print);
        std::cout << "control (codes as linear): print max " << control.max << " mean " << control.mean << "\n";
        check(control.mean > 0.02, "control: a forgotten transfer function is visible to this comparison");
    } catch (const std::exception& e) {
        std::cerr << "FAIL: " << e.what() << "\n";
        return 1;
    }
    std::cout << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
