#include "image_io.hpp"

#include <algorithm>
#include <bit>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <memory>
#include <thread>

#include <libraw/libraw.h>

#include "io/raw_decoder.hpp"
#include "platform.hpp"
#include "stb_image.h"
#include "tiff_ifd.hpp"

namespace spkhost {

namespace fs = std::filesystem;

// ---------------------------------------------------------------------------
// small utilities

template <typename F>
static void parallel_rows(uint32_t rows, F&& body) {
    const unsigned threads = std::min<unsigned>(hardware_threads(), std::max<uint32_t>(1, rows / 16));
    if (threads <= 1) { body(0u, rows); return; }
    std::vector<std::thread> pool;
    const uint32_t step = (rows + threads - 1) / threads;
    for (unsigned t = 0; t < threads; ++t) {
        const uint32_t y0 = t * step, y1 = std::min(rows, y0 + step);
        if (y0 >= y1) break;
        pool.emplace_back([&body, y0, y1] { body(y0, y1); });
    }
    for (auto& th : pool) th.join();
}

const char* kind_name(FileKind kind) {
    switch (kind) {
        case FileKind::Raw: return "raw";
        case FileKind::Tiff: return "tiff";
        case FileKind::Jpeg: return "jpeg";
        case FileKind::Png: return "png";
        default: return "unknown";
    }
}

static std::string lower_ext(const fs::path& path) {
    std::string e = path_utf8(path.extension());
    for (char& c : e) c = char(std::tolower(static_cast<unsigned char>(c)));
    return e;
}

FileKind sniff_kind(const fs::path& path) {
    static const char* raw_exts[] = {".arw", ".nef", ".nrw", ".cr2", ".cr3", ".crw", ".raf", ".dng",
                                     ".orf", ".rw2", ".pef", ".srw", ".3fr", ".iiq", ".erf", ".mos",
                                     ".mrw", ".x3f", ".raw", ".rwl", ".srf", ".sr2", ".kdc", ".dcr",
                                     ".mef", ".fff", ".gpr"};
    const std::string ext = lower_ext(path);
    for (const char* r : raw_exts) if (ext == r) return FileKind::Raw;
    std::FILE* f = open_file(path, "rb");
    if (!f) return FileKind::Unknown;
    uint8_t m[8] = {};
    const size_t n = std::fread(m, 1, 8, f);
    std::fclose(f);
    if (n >= 3 && m[0] == 0xFF && m[1] == 0xD8 && m[2] == 0xFF) return FileKind::Jpeg;
    if (n >= 8 && std::memcmp(m, "\x89PNG\r\n\x1a\n", 8) == 0) return FileKind::Png;
    if (n >= 4 && ((m[0] == 'I' && m[1] == 'I' && m[2] == 42 && m[3] == 0) ||
                   (m[0] == 'M' && m[1] == 'M' && m[2] == 0 && m[3] == 42)))
        return FileKind::Tiff;
    return FileKind::Unknown;
}

template <typename T>
void apply_orientation(std::vector<T>& px, uint32_t& w, uint32_t& h, uint32_t ch, int o) {
    if (o <= 1 || o > 8) return;
    const bool swap = o >= 5;
    const uint32_t ow = swap ? h : w, oh = swap ? w : h;
    std::vector<T> out(px.size());
    for (uint32_t y = 0; y < oh; ++y) {
        for (uint32_t x = 0; x < ow; ++x) {
            uint32_t sx = x, sy = y;
            switch (o) {
                case 2: sx = w - 1 - x; sy = y; break;
                case 3: sx = w - 1 - x; sy = h - 1 - y; break;
                case 4: sx = x; sy = h - 1 - y; break;
                case 5: sx = y; sy = x; break;
                case 6: sx = y; sy = h - 1 - x; break;
                case 7: sx = w - 1 - y; sy = h - 1 - x; break;
                case 8: sx = w - 1 - y; sy = x; break;
            }
            std::memcpy(&out[(size_t(y) * ow + x) * ch], &px[(size_t(sy) * w + sx) * ch], sizeof(T) * ch);
        }
    }
    px.swap(out);
    w = ow;
    h = oh;
}
template void apply_orientation<float>(std::vector<float>&, uint32_t&, uint32_t&, uint32_t, int);
template void apply_orientation<uint8_t>(std::vector<uint8_t>&, uint32_t&, uint32_t&, uint32_t, int);

void resize_area(const float* src, uint32_t sw, uint32_t sh, uint32_t ch, uint32_t dw, uint32_t dh,
                 std::vector<float>& dst) {
    // Separable box filter with fractional coverage at the edges: horizontal
    // first into a temporary, then vertical.
    struct Tap { uint32_t i; float w; };
    auto weights = [](uint32_t s, uint32_t d) {
        std::vector<std::vector<Tap>> taps(d);
        const double scale = double(s) / d;
        for (uint32_t o = 0; o < d; ++o) {
            const double a = o * scale, b = (o + 1) * scale;
            double sum = 0;
            for (uint32_t i = uint32_t(a); i < std::min<double>(s, std::ceil(b)); ++i) {
                const double cover = std::min<double>(b, i + 1) - std::max<double>(a, i);
                if (cover > 0) { taps[o].push_back({i, float(cover)}); sum += cover; }
            }
            for (auto& t : taps[o]) t.w = float(t.w / sum);
        }
        return taps;
    };
    const auto tx = weights(sw, dw), ty = weights(sh, dh);
    std::vector<float> mid(size_t(dw) * sh * ch);
    parallel_rows(sh, [&](uint32_t y0, uint32_t y1) {
        for (uint32_t y = y0; y < y1; ++y)
            for (uint32_t x = 0; x < dw; ++x)
                for (uint32_t c = 0; c < ch; ++c) {
                    float acc = 0;
                    for (const Tap& t : tx[x]) acc += t.w * src[(size_t(y) * sw + t.i) * ch + c];
                    mid[(size_t(y) * dw + x) * ch + c] = acc;
                }
    });
    dst.assign(size_t(dw) * dh * ch, 0.0f);
    parallel_rows(dh, [&](uint32_t y0, uint32_t y1) {
        for (uint32_t y = y0; y < y1; ++y)
            for (const Tap& t : ty[y]) {
                const float* row = &mid[size_t(t.i) * dw * ch];
                float* out = &dst[size_t(y) * dw * ch];
                for (size_t i = 0; i < size_t(dw) * ch; ++i) out[i] += t.w * row[i];
            }
    });
}

// ---------------------------------------------------------------------------
// colour spaces

double Trc::decode(double v) const {
    switch (kind) {
        case Kind::Gamma:
            return v < 0 ? -std::pow(-v, gamma) : std::pow(v, gamma);
        case Kind::Table: {
            if (table.empty()) return v;
            if (table.size() == 1) return table[0];
            const double x = std::clamp(v, 0.0, 1.0) * double(table.size() - 1);
            const size_t i = std::min<size_t>(size_t(x), table.size() - 2);
            const double f = x - double(i);
            return table[i] * (1 - f) + table[i + 1] * f;
        }
        case Kind::Para: {
            const double g = p[0], a = p[1], b = p[2], c = p[3], d = p[4], e = p[5], f = p[6];
            auto pw = [](double base, double ex) { return base <= 0 ? 0.0 : std::pow(base, ex); };
            switch (para_type) {
                case 0: return v < 0 ? -std::pow(-v, g) : std::pow(v, g);
                case 1: return v >= -b / a ? pw(a * v + b, g) : 0.0;
                case 2: return v >= -b / a ? pw(a * v + b, g) + c : c;
                case 3: return v >= d ? pw(a * v + b, g) : c * v;
                case 4: return v >= d ? pw(a * v + b, g) + e : c * v + f;
                default: return v;
            }
        }
    }
    return v;
}

static Trc para_srgb() {
    Trc t;
    t.kind = Trc::Kind::Para;
    t.para_type = 3;
    t.p = {2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045, 0, 0};
    return t;
}

RgbSpace srgb_space() {
    // The D50 (Bradford-adapted) colorants every sRGB ICC profile carries.
    RgbSpace s;
    s.to_xyz_d50 = {0.4360747, 0.3850649, 0.1430804,
                    0.2225045, 0.7168786, 0.0606169,
                    0.0139322, 0.0971045, 0.7141733};
    s.trc = {para_srgb(), para_srgb(), para_srgb()};
    s.description = "sRGB (assumed)";
    return s;
}

RgbSpace display_p3_space() {
    RgbSpace s;
    s.to_xyz_d50 = {0.5151215, 0.2919769, 0.1571045,
                    0.2411957, 0.6922455, 0.0665588,
                    -0.0010529, 0.0418854, 0.7840729};
    s.trc = {para_srgb(), para_srgb(), para_srgb()};
    s.description = "Display P3";
    return s;
}

RgbSpace linear_prophoto_space() {
    RgbSpace s;
    s.to_xyz_d50 = {0.7976749, 0.1351917, 0.0313534,
                    0.2880402, 0.7118741, 0.0000857,
                    0.0, 0.0, 0.8252100};
    Trc lin;
    lin.kind = Trc::Kind::Gamma;
    lin.gamma = 1.0;
    s.trc = {lin, lin, lin};
    s.description = "linear ProPhoto RGB (assumed)";
    return s;
}

static std::array<double, 9> invert3(const std::array<double, 9>& m) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    return {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det};
}

static std::array<double, 9> mul3(const std::array<double, 9>& x, const std::array<double, 9>& y) {
    std::array<double, 9> r{};
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            for (int k = 0; k < 3; ++k) r[i * 3 + j] += x[i * 3 + k] * y[k * 3 + j];
    return r;
}

static uint32_t be32(const uint8_t* p) { return (uint32_t(p[0]) << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
static uint16_t be16(const uint8_t* p) { return uint16_t((p[0] << 8) | p[1]); }
static double s15f16(const uint8_t* p) { return int32_t(be32(p)) / 65536.0; }

bool parse_icc(const std::vector<uint8_t>& icc, RgbSpace& out, std::string& error) {
    if (icc.size() < 132) { error = "ICC profile too short"; return false; }
    if (std::memcmp(&icc[16], "RGB ", 4) != 0) { error = "ICC profile is not RGB"; return false; }
    const uint32_t count = be32(&icc[128]);
    if (size_t(count) * 12 + 132 > icc.size()) { error = "ICC tag table truncated"; return false; }
    auto tag = [&](const char* sig, size_t& off, size_t& len) {
        for (uint32_t i = 0; i < count; ++i) {
            const uint8_t* e = &icc[132 + size_t(i) * 12];
            if (std::memcmp(e, sig, 4) == 0) {
                off = be32(e + 4);
                len = be32(e + 8);
                return off <= icc.size() && len <= icc.size() - off;
            }
        }
        return false;
    };
    RgbSpace s;
    const char* xyz[3] = {"rXYZ", "gXYZ", "bXYZ"};
    for (int c = 0; c < 3; ++c) {
        size_t off, len;
        if (!tag(xyz[c], off, len) || len < 20 || std::memcmp(&icc[off], "XYZ ", 4) != 0) {
            error = "ICC profile has no matrix colorants (LUT-based profiles are not supported)";
            return false;
        }
        for (int r = 0; r < 3; ++r) s.to_xyz_d50[r * 3 + c] = s15f16(&icc[off + 8 + r * 4]);
    }
    const char* trcs[3] = {"rTRC", "gTRC", "bTRC"};
    for (int c = 0; c < 3; ++c) {
        size_t off, len;
        if (!tag(trcs[c], off, len) || len < 12) { error = "ICC profile has no TRC"; return false; }
        const uint8_t* t = &icc[off];
        Trc trc;
        if (std::memcmp(t, "curv", 4) == 0) {
            const uint32_t n = be32(t + 8);
            if (12 + size_t(n) * 2 > len) { error = "ICC curv truncated"; return false; }
            if (n == 0) { trc.kind = Trc::Kind::Gamma; trc.gamma = 1.0; }
            else if (n == 1) { trc.kind = Trc::Kind::Gamma; trc.gamma = be16(t + 12) / 256.0; }
            else {
                trc.kind = Trc::Kind::Table;
                trc.table.resize(n);
                for (uint32_t i = 0; i < n; ++i) trc.table[i] = be16(t + 12 + i * 2) / 65535.0;
            }
        } else if (std::memcmp(t, "para", 4) == 0) {
            trc.kind = Trc::Kind::Para;
            trc.para_type = be16(t + 8);
            static const int params_for[] = {1, 3, 4, 5, 7};
            if (trc.para_type > 4) { error = "ICC para type unknown"; return false; }
            const int np = params_for[trc.para_type];
            if (12 + size_t(np) * 4 > len) { error = "ICC para truncated"; return false; }
            for (int i = 0; i < np; ++i) trc.p[i] = s15f16(t + 12 + i * 4);
        } else {
            error = "ICC TRC type not supported";
            return false;
        }
        s.trc[c] = std::move(trc);
    }
    size_t off, len;
    if (tag("desc", off, len) && len > 12) {
        const uint8_t* t = &icc[off];
        if (std::memcmp(t, "desc", 4) == 0) {
            const uint32_t n = be32(t + 8);
            if (12 + size_t(n) <= len)
                s.description.assign(reinterpret_cast<const char*>(t + 12), strnlen(reinterpret_cast<const char*>(t + 12), n));
        } else if (std::memcmp(t, "mluc", 4) == 0 && len >= 28) {
            const uint32_t slen = be32(t + 20), soff = be32(t + 24);
            if (soff + size_t(slen) <= len)
                for (uint32_t i = 0; i + 1 < slen; i += 2) {
                    const uint16_t ch = be16(t + soff + i);
                    if (ch < 128) s.description.push_back(char(ch));
                }
        }
    }
    out = std::move(s);
    return true;
}

// Encoded -> linear ProPhoto via PCS XYZ (D50). `lut_size` > 0 means the
// samples are integer codes 0..lut_size-1 stored as floats; then each curve
// is evaluated once per code rather than once per sample.
static void encoded_to_linear_prophoto(const RgbSpace& space, std::vector<float>& rgb, uint32_t codes) {
    const std::array<double, 9> m = mul3(invert3(linear_prophoto_space().to_xyz_d50), space.to_xyz_d50);
    std::array<std::vector<float>, 3> lut;
    if (codes) {
        for (int c = 0; c < 3; ++c) {
            lut[c].resize(codes);
            for (uint32_t i = 0; i < codes; ++i) lut[c][i] = float(space.trc[c].decode(double(i) / (codes - 1)));
        }
    }
    const size_t pixels = rgb.size() / 3;
    const size_t chunk = 1 << 16;
    const size_t chunks = (pixels + chunk - 1) / chunk;
    parallel_rows(uint32_t(chunks), [&](uint32_t c0, uint32_t c1) {
        for (size_t p = size_t(c0) * chunk; p < std::min(pixels, size_t(c1) * chunk); ++p) {
            float* v = &rgb[p * 3];
            double l[3];
            for (int c = 0; c < 3; ++c) {
                if (codes) {
                    const uint32_t code = uint32_t(std::clamp(v[c], 0.0f, float(codes - 1)) + 0.5f);
                    l[c] = lut[c][code];
                } else {
                    l[c] = space.trc[c].decode(v[c]);
                }
            }
            for (int r = 0; r < 3; ++r) v[r] = float(m[r * 3] * l[0] + m[r * 3 + 1] * l[1] + m[r * 3 + 2] * l[2]);
        }
    });
}

void to_linear_prophoto(const RgbSpace& space, std::vector<float>& rgb) {
    encoded_to_linear_prophoto(space, rgb, 0);
}

// ---------------------------------------------------------------------------
// raster decode: samples as floats (integer codes, or real floats)

struct Raster {
    uint32_t width = 0, height = 0;
    std::vector<float> rgb;   // 3 channels
    uint32_t codes = 0;       // 256 / 65536 for integer sources, 0 for float
    std::vector<uint8_t> icc;
    Metadata meta;
};

// ---- TIFF

static bool lzw_decode(const uint8_t* src, size_t n, std::vector<uint8_t>& out, size_t expect) {
    out.clear();
    out.reserve(expect);
    std::vector<uint16_t> prefix(4096);
    std::vector<uint8_t> suffix(4096), first(4096);
    std::vector<uint16_t> length(4096);
    for (int i = 0; i < 256; ++i) { prefix[i] = 0xFFFF; suffix[i] = uint8_t(i); first[i] = uint8_t(i); length[i] = 1; }
    size_t bitpos = 0;
    int width = 9;
    uint32_t next = 258;
    int old = -1;
    std::vector<uint8_t> stack(4096);
    auto read = [&]() -> int {
        if ((bitpos + width) > n * 8) return 257;
        uint32_t v = 0;
        for (int i = 0; i < width; ++i, ++bitpos) v = (v << 1) | ((src[bitpos >> 3] >> (7 - (bitpos & 7))) & 1);
        return int(v);
    };
    auto emit = [&](int code) {
        int len = length[code];
        int c = code;
        for (int i = len - 1; i >= 0; --i) { stack[i] = suffix[c]; c = prefix[c]; }
        out.insert(out.end(), stack.begin(), stack.begin() + len);
    };
    while (out.size() < expect) {
        int code = read();
        if (code == 257) break;
        if (code == 256) {
            width = 9; next = 258; old = -1;
            code = read();
            if (code == 257) break;
            if (code > 255) return false;
            emit(code);
            old = code;
            continue;
        }
        if (old < 0) {
            if (code > 255) return false;
            emit(code);
            old = code;
            continue;
        }
        if (code < int(next)) {
            emit(code);
            if (next < 4096) {
                prefix[next] = uint16_t(old); suffix[next] = first[code]; first[next] = first[old];
                length[next] = uint16_t(length[old] + 1); ++next;
            }
        } else if (code == int(next) && next < 4096) {
            prefix[next] = uint16_t(old); suffix[next] = first[old]; first[next] = first[old];
            length[next] = uint16_t(length[old] + 1); ++next;
            emit(code);
        } else {
            return false;
        }
        old = code;
        if (next + 1 >= (1u << width) && width < 12) ++width;
    }
    return true;
}

static bool packbits_decode(const uint8_t* src, size_t n, std::vector<uint8_t>& out, size_t expect) {
    out.clear();
    size_t i = 0;
    while (i < n && out.size() < expect) {
        const int8_t h = int8_t(src[i++]);
        if (h >= 0) {
            const size_t len = size_t(h) + 1;
            if (i + len > n) return false;
            out.insert(out.end(), src + i, src + i + len);
            i += len;
        } else if (h != -128) {
            if (i >= n) return false;
            out.insert(out.end(), size_t(1 - h), src[i++]);
        }
    }
    return true;
}

static bool decode_tiff(const std::vector<uint8_t>& file, Raster& out, bool header_only, std::string& error) {
    TiffBytes t(file.data(), file.size());
    uint32_t ifd0;
    if (!t.header(ifd0)) { error = "not a classic TIFF (BigTIFF is not supported)"; return false; }
    TiffBytes::Ifd ifd;
    if (!t.read_ifd(ifd0, ifd)) { error = "TIFF IFD0 unreadable"; return false; }
    read_exif_metadata(t, ifd0, out.meta);
    double v;
    if (!t.number(ifd, 256, v)) { error = "TIFF has no width"; return false; }
    const uint32_t w = uint32_t(v);
    if (!t.number(ifd, 257, v)) { error = "TIFF has no height"; return false; }
    const uint32_t h = uint32_t(v);
    out.width = w; out.height = h;
    t.bytes(ifd, 34675, out.icc);
    if (header_only) return true;

    std::vector<double> bps_v;
    t.numbers(ifd, 258, bps_v);
    const uint32_t bps = bps_v.empty() ? 1 : uint32_t(bps_v[0]);
    const uint32_t spp = t.number(ifd, 277, v) ? uint32_t(v) : 1;
    const uint32_t compression = t.number(ifd, 259, v) ? uint32_t(v) : 1;
    const uint32_t photometric = t.number(ifd, 262, v) ? uint32_t(v) : 2;
    const uint32_t planar = t.number(ifd, 284, v) ? uint32_t(v) : 1;
    const uint32_t predictor = t.number(ifd, 317, v) ? uint32_t(v) : 1;
    const uint32_t sample_format = t.number(ifd, 339, v) ? uint32_t(v) : 1;
    if (!(bps == 8 || bps == 16 || (bps == 32 && sample_format == 3))) {
        error = "TIFF " + std::to_string(bps) + "-bit samples are not supported (8, 16 or 32-bit float)";
        return false;
    }
    if (sample_format != 1 && !(sample_format == 3 && bps == 32)) { error = "TIFF sample format not supported"; return false; }
    if (!((photometric == 2 && spp >= 3) || ((photometric == 1 || photometric == 0) && spp >= 1))) {
        error = "TIFF photometric interpretation " + std::to_string(photometric) + " not supported (RGB or grey)";
        return false;
    }
    if (!(compression == 1 || compression == 5 || compression == 8 || compression == 32946 || compression == 32773)) {
        error = "TIFF compression " + std::to_string(compression) + " not supported (none, LZW, deflate, PackBits)";
        return false;
    }
    if (predictor != 1 && predictor != 2) { error = "TIFF predictor " + std::to_string(predictor) + " not supported"; return false; }
    if (uint64_t(w) * h > 400'000'000ull) { error = "TIFF too large"; return false; }

    const bool tiled = ifd.count(322) != 0;
    uint32_t bw = w, bh = h;
    std::vector<double> offsets, counts;
    if (tiled) {
        if (!t.number(ifd, 322, v)) return false;
        bw = uint32_t(v);
        if (!t.number(ifd, 323, v)) { error = "TIFF tile length missing"; return false; }
        bh = uint32_t(v);
        t.numbers(ifd, 324, offsets);
        t.numbers(ifd, 325, counts);
    } else {
        bh = t.number(ifd, 278, v) ? std::min<uint32_t>(uint32_t(v), h) : h;
        t.numbers(ifd, 273, offsets);
        t.numbers(ifd, 279, counts);
    }
    if (bw == 0 || bh == 0 || offsets.empty() || offsets.size() != counts.size()) { error = "TIFF strips/tiles malformed"; return false; }
    const uint32_t bytes_per = bps / 8;
    const uint32_t per_block_spp = planar == 2 ? 1 : spp;
    const uint32_t across = (w + bw - 1) / bw, down = (h + bh - 1) / bh;
    const uint32_t planes = planar == 2 ? spp : 1;
    if (offsets.size() < size_t(across) * down * planes) { error = "TIFF has too few strips/tiles"; return false; }

    const uint32_t channels_out = 3;
    out.rgb.assign(size_t(w) * h * channels_out, 0.0f);
    out.codes = bps == 8 ? 256 : bps == 16 ? 65536 : 0;
    std::vector<uint8_t> block;
    const size_t row_bytes = size_t(bw) * per_block_spp * bytes_per;
    for (uint32_t plane = 0; plane < planes; ++plane) {
        for (uint32_t by = 0; by < down; ++by) {
            for (uint32_t bx = 0; bx < across; ++bx) {
                const size_t index = size_t(plane) * across * down + size_t(by) * across + bx;
                const size_t off = size_t(offsets[index]), cnt = size_t(counts[index]);
                if (!t.in_range(off, cnt)) { error = "TIFF strip outside file"; return false; }
                const uint32_t rows = tiled ? bh : std::min(bh, h - by * bh);
                const size_t expect = row_bytes * rows;
                const uint8_t* src = file.data() + off;
                bool ok = true;
                switch (compression) {
                    case 1: block.assign(src, src + std::min(cnt, expect)); break;
                    case 5: ok = lzw_decode(src, cnt, block, expect); break;
                    case 32773: ok = packbits_decode(src, cnt, block, expect); break;
                    default: {
                        int got = 0;
                        char* data = stbi_zlib_decode_malloc_guesssize(reinterpret_cast<const char*>(src), int(cnt), int(expect), &got);
                        ok = data != nullptr;
                        if (ok) { block.assign(data, data + got); }
                        std::free(data);
                    }
                }
                if (!ok) { error = "TIFF strip decompression failed"; return false; }
                if (block.size() < expect) block.resize(expect, 0);
                // to native samples
                const bool swap = (t.little() != (std::endian::native == std::endian::little));
                if (bytes_per > 1 && swap) {
                    for (size_t i = 0; i + bytes_per <= block.size(); i += bytes_per)
                        std::reverse(block.begin() + i, block.begin() + i + bytes_per);
                }
                if (predictor == 2) {
                    for (uint32_t r = 0; r < rows; ++r) {
                        uint8_t* row = block.data() + r * row_bytes;
                        if (bps == 8) {
                            for (size_t i = per_block_spp; i < size_t(bw) * per_block_spp; ++i) row[i] = uint8_t(row[i] + row[i - per_block_spp]);
                        } else if (bps == 16) {
                            uint16_t* r16 = reinterpret_cast<uint16_t*>(row);
                            for (size_t i = per_block_spp; i < size_t(bw) * per_block_spp; ++i) r16[i] = uint16_t(r16[i] + r16[i - per_block_spp]);
                        }
                    }
                }
                for (uint32_t r = 0; r < rows; ++r) {
                    const uint32_t y = by * bh + r;
                    if (y >= h) break;
                    const uint8_t* row = block.data() + r * row_bytes;
                    for (uint32_t c = 0; c < bw; ++c) {
                        const uint32_t x = bx * bw + c;
                        if (x >= w) break;
                        float* dst = &out.rgb[(size_t(y) * w + x) * 3];
                        auto sample = [&](uint32_t s) -> float {
                            const size_t at = (size_t(c) * per_block_spp + s) * bytes_per;
                            if (bps == 8) return row[at];
                            if (bps == 16) { uint16_t u; std::memcpy(&u, row + at, 2); return u; }
                            float f; std::memcpy(&f, row + at, 4); return f;
                        };
                        if (planar == 2) {
                            if (photometric == 2) { if (plane < 3) dst[plane] = sample(0); }
                            else if (plane == 0) dst[0] = dst[1] = dst[2] = sample(0);
                        } else if (photometric == 2) {
                            dst[0] = sample(0); dst[1] = sample(1); dst[2] = sample(2);
                        } else {
                            dst[0] = dst[1] = dst[2] = sample(0);
                        }
                    }
                }
            }
        }
    }
    if (photometric == 0) {
        const float top = out.codes ? float(out.codes - 1) : 1.0f;
        for (float& s : out.rgb) s = top - s;
    }
    return true;
}

// ---- JPEG and PNG

static void jpeg_segments(const std::vector<uint8_t>& f, std::vector<uint8_t>& icc, Metadata& meta) {
    std::vector<std::pair<int, std::vector<uint8_t>>> icc_parts;
    size_t i = 2;
    while (i + 4 <= f.size()) {
        if (f[i] != 0xFF) break;
        const uint8_t marker = f[i + 1];
        if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) { i += 2; continue; }
        if (marker == 0xDA || marker == 0xD9) break;
        const size_t len = (size_t(f[i + 2]) << 8) | f[i + 3];
        if (len < 2 || i + 2 + len > f.size()) break;
        const uint8_t* body = &f[i + 4];
        const size_t blen = len - 2;
        if (marker == 0xE1 && blen > 6 && std::memcmp(body, "Exif\0\0", 6) == 0) {
            TiffBytes t(body + 6, blen - 6);
            uint32_t ifd0;
            if (t.header(ifd0)) read_exif_metadata(t, ifd0, meta);
        } else if (marker == 0xE2 && blen > 14 && std::memcmp(body, "ICC_PROFILE\0", 12) == 0) {
            icc_parts.push_back({body[12], std::vector<uint8_t>(body + 14, body + blen)});
        }
        i += 2 + len;
    }
    std::sort(icc_parts.begin(), icc_parts.end(), [](auto& a, auto& b) { return a.first < b.first; });
    icc.clear();
    for (auto& p : icc_parts) icc.insert(icc.end(), p.second.begin(), p.second.end());
}

static void png_chunks(const std::vector<uint8_t>& f, std::vector<uint8_t>& icc, Metadata& meta) {
    size_t i = 8;
    while (i + 12 <= f.size()) {
        const uint32_t len = be32(&f[i]);
        if (i + 12 + size_t(len) > f.size()) break;
        const uint8_t* type = &f[i + 4];
        const uint8_t* body = &f[i + 8];
        if (std::memcmp(type, "iCCP", 4) == 0) {
            size_t name = 0;
            while (name < len && body[name]) ++name;
            if (name + 2 < len) {
                int got = 0;
                char* data = stbi_zlib_decode_malloc(reinterpret_cast<const char*>(body + name + 2), int(len - name - 2), &got);
                if (data) { icc.assign(data, data + got); std::free(data); }
            }
        } else if (std::memcmp(type, "eXIf", 4) == 0) {
            TiffBytes t(body, len);
            uint32_t ifd0;
            if (t.header(ifd0)) read_exif_metadata(t, ifd0, meta);
        } else if (std::memcmp(type, "IDAT", 4) == 0) {
            // eXIf may follow IDAT in some writers; keep scanning
        }
        i += 12 + len;
    }
}

static bool decode_stb(const std::vector<uint8_t>& f, FileKind kind, Raster& out, bool header_only, std::string& error) {
    if (kind == FileKind::Jpeg) jpeg_segments(f, out.icc, out.meta);
    else png_chunks(f, out.icc, out.meta);
    int w = 0, h = 0, comp = 0;
    if (!stbi_info_from_memory(f.data(), int(f.size()), &w, &h, &comp)) {
        error = std::string("image header unreadable: ") + stbi_failure_reason();
        return false;
    }
    out.width = uint32_t(w);
    out.height = uint32_t(h);
    if (header_only) return true;
    const bool deep = stbi_is_16_bit_from_memory(f.data(), int(f.size()));
    out.rgb.resize(size_t(w) * h * 3);
    if (deep) {
        std::unique_ptr<stbi_us, void (*)(void*)> px(stbi_load_16_from_memory(f.data(), int(f.size()), &w, &h, &comp, 3), stbi_image_free);
        if (!px) { error = std::string("decode failed: ") + stbi_failure_reason(); return false; }
        for (size_t i = 0; i < out.rgb.size(); ++i) out.rgb[i] = px.get()[i];
        out.codes = 65536;
    } else {
        std::unique_ptr<stbi_uc, void (*)(void*)> px(stbi_load_from_memory(f.data(), int(f.size()), &w, &h, &comp, 3), stbi_image_free);
        if (!px) { error = std::string("decode failed: ") + stbi_failure_reason(); return false; }
        for (size_t i = 0; i < out.rgb.size(); ++i) out.rgb[i] = px.get()[i];
        out.codes = 256;
    }
    return true;
}

static bool read_raster(const fs::path& path, FileKind kind, Raster& out, bool header_only, std::string& error) {
    std::vector<uint8_t> file;
    if (!read_file(path, file, error)) return false;
    if (kind == FileKind::Tiff) return decode_tiff(file, out, header_only, error);
    return decode_stb(file, kind, out, header_only, error);
}

static RgbSpace raster_space(const Raster& r, std::string* note) {
    if (!r.icc.empty()) {
        RgbSpace s;
        std::string why;
        if (parse_icc(r.icc, s, why)) return s;
        if (note) *note = "embedded ICC profile ignored (" + why + "); assumed sRGB";
        return srgb_space();
    }
    // An untagged deep TIFF is linear ProPhoto (the macOS decoder's rule).
    if (r.codes != 256) return linear_prophoto_space();
    return srgb_space();
}

// ---- RAW

static std::string trimmed(const char* s, size_t n) {
    std::string out(s, strnlen(s, n));
    while (!out.empty() && out.back() == ' ') out.pop_back();
    return out;
}

static int flip_to_orientation(int flip) {
    switch (flip) {
        case 3: return 3;
        case 5: return 8;
        case 6: return 6;
        default: return 1;
    }
}

static void raw_metadata(LibRaw& raw, Metadata& meta) {
    const auto& id = raw.imgdata.idata;
    const auto& other = raw.imgdata.other;
    meta.make = trimmed(id.make, sizeof id.make);
    meta.model = trimmed(id.model, sizeof id.model);
    std::string lens = trimmed(raw.imgdata.lens.Lens, sizeof raw.imgdata.lens.Lens);
    if (lens.empty()) lens = trimmed(raw.imgdata.lens.makernotes.Lens, sizeof raw.imgdata.lens.makernotes.Lens);
    meta.lens = lens;
    if (other.iso_speed > 0) meta.iso = other.iso_speed;
    if (other.shutter > 0) meta.shutter_s = other.shutter;
    if (other.aperture > 0) meta.aperture = other.aperture;
    if (other.focal_len > 0) meta.focal_mm = other.focal_len;
    if (other.timestamp > 0) {
        // LibRaw parsed the EXIF local time with mktime; localtime undoes it.
        std::time_t ts = other.timestamp;
        std::tm tm{};
#ifdef _WIN32
        localtime_s(&tm, &ts);
#else
        localtime_r(&ts, &tm);
#endif
        char buf[32];
        std::strftime(buf, sizeof buf, "%Y:%m:%d %H:%M:%S", &tm);
        meta.datetime_original = buf;
    }
    meta.orientation = flip_to_orientation(raw.imgdata.sizes.flip);
}

static bool raw_open(LibRaw& raw, const fs::path& path, std::string& error) {
    const int status = raw.open_file(path.c_str());
    if (status != LIBRAW_SUCCESS) {
        error = std::string("RAW open: ") + LibRaw::strerror(status);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// public entry points

static void oriented_size(uint32_t& w, uint32_t& h, int orientation) {
    if (orientation >= 5) std::swap(w, h);
}

bool probe_file(const fs::path& path, Probe& out, std::string& error) {
    out = Probe{};
    std::error_code ec;
    if (!fs::is_regular_file(path, ec)) { error = "not found: " + path_utf8(path); return false; }
    out.kind = sniff_kind(path);
    if (out.kind == FileKind::Unknown) { error = "unrecognised file type: " + path_utf8(path); return false; }
    if (out.kind == FileKind::Raw) {
        auto raw = std::make_unique<LibRaw>(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK);
        if (!raw_open(*raw, path, error)) return false;
        raw_metadata(*raw, out.metadata);
        out.width = raw->imgdata.sizes.width;
        out.height = raw->imgdata.sizes.height;
        oriented_size(out.width, out.height, out.metadata.orientation);
        return true;
    }
    Raster r;
    if (!read_raster(path, out.kind, r, true, error)) return false;
    out.metadata = r.meta;
    out.width = r.width;
    out.height = r.height;
    oriented_size(out.width, out.height, out.metadata.orientation);
    return true;
}

bool decode_linear_prophoto(const fs::path& path, const DecodeOptions& options, FloatImage& out,
                            Probe& probe, std::string& error) {
    if (!probe_file(path, probe, error)) return false;
    if (probe.kind == FileKind::Raw) {
        spk::io::DecodedRaw decoded;
        const bool ok = options.raw_mode == "headroom" ? spk::io::decode_raw_headroom(path, decoded, error)
                                                       : spk::io::decode_raw_compatible(path, decoded, error);
        if (!ok) return false;
        out.width = decoded.width;
        out.height = decoded.height;
        out.rgb = std::move(decoded.rgb);   // LibRaw already applied the flip
        return true;
    }
    Raster r;
    if (!read_raster(path, probe.kind, r, false, error)) return false;
    std::string note;
    const RgbSpace space = raster_space(r, &note);
    encoded_to_linear_prophoto(space, r.rgb, r.codes);
    uint32_t w = r.width, h = r.height;
    apply_orientation(r.rgb, w, h, 3, r.meta.orientation);
    out.width = w;
    out.height = h;
    out.rgb = std::move(r.rgb);
    return true;
}

static void to_rgba8_srgb(const RgbSpace& space, const std::vector<float>& rgb, uint32_t codes, std::vector<uint8_t>& rgba) {
    // source encoded -> linear -> XYZ D50 -> linear sRGB (D50-adapted) -> sRGB.
    const RgbSpace srgb = srgb_space();
    const std::array<double, 9> m = mul3(invert3(srgb.to_xyz_d50), space.to_xyz_d50);
    const size_t pixels = rgb.size() / 3;
    rgba.resize(pixels * 4);
    for (size_t p = 0; p < pixels; ++p) {
        double l[3];
        for (int c = 0; c < 3; ++c) {
            const double v = codes ? rgb[p * 3 + c] / double(codes - 1) : rgb[p * 3 + c];
            l[c] = space.trc[c].decode(v);
        }
        for (int r = 0; r < 3; ++r) {
            double s = m[r * 3] * l[0] + m[r * 3 + 1] * l[1] + m[r * 3 + 2] * l[2];
            s = std::clamp(s, 0.0, 1.0);
            s = s <= 0.0031308 ? 12.92 * s : 1.055 * std::pow(s, 1 / 2.4) - 0.055;
            rgba[p * 4 + r] = uint8_t(std::lround(s * 255));
        }
        rgba[p * 4 + 3] = 255;
    }
}

static void fit_long_edge(uint32_t w, uint32_t h, uint32_t long_edge, uint32_t& dw, uint32_t& dh) {
    dw = w; dh = h;
    const uint32_t l = std::max(w, h);
    if (long_edge == 0 || l <= long_edge) return;
    const double s = double(long_edge) / l;
    dw = std::max(1u, uint32_t(std::lround(w * s)));
    dh = std::max(1u, uint32_t(std::lround(h * s)));
}

static void shrink_rgb(std::vector<float>& rgb, uint32_t& w, uint32_t& h, uint32_t long_edge) {
    uint32_t dw, dh;
    fit_long_edge(w, h, long_edge, dw, dh);
    if (dw == w && dh == h) return;
    std::vector<float> out;
    resize_area(rgb.data(), w, h, 3, dw, dh, out);
    rgb.swap(out);
    w = dw; h = dh;
}

bool thumbnail(const fs::path& path, uint32_t long_edge, Rgba8& out, std::string& source, std::string& error) {
    Probe probe;
    if (!probe_file(path, probe, error)) return false;
    if (probe.kind == FileKind::Raw) {
        auto raw = std::make_unique<LibRaw>(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK);
        if (!raw_open(*raw, path, error)) return false;
        const int orientation = flip_to_orientation(raw->imgdata.sizes.flip);
        std::vector<float> rgb;
        uint32_t w = 0, h = 0;
        if (raw->unpack_thumb() == LIBRAW_SUCCESS) {
            const auto& th = raw->imgdata.thumbnail;
            if (th.tformat == LIBRAW_THUMBNAIL_JPEG && th.thumb) {
                int iw, ih, comp;
                std::unique_ptr<stbi_uc, void (*)(void*)> px(
                    stbi_load_from_memory(reinterpret_cast<const stbi_uc*>(th.thumb), int(th.tlength), &iw, &ih, &comp, 3),
                    stbi_image_free);
                if (px) {
                    w = uint32_t(iw); h = uint32_t(ih);
                    rgb.assign(px.get(), px.get() + size_t(w) * h * 3);
                }
            } else if (th.tformat == LIBRAW_THUMBNAIL_BITMAP && th.thumb && th.tcolors == 3 &&
                       th.tlength >= unsigned(th.twidth) * th.theight * 3) {
                w = th.twidth; h = th.theight;
                rgb.assign(reinterpret_cast<const uint8_t*>(th.thumb),
                           reinterpret_cast<const uint8_t*>(th.thumb) + size_t(w) * h * 3);
            }
        }
        if (!rgb.empty()) {
            source = "embedded";
            shrink_rgb(rgb, w, h, long_edge);
            std::vector<uint8_t> rgba(size_t(w) * h * 4);
            for (size_t p = 0; p < size_t(w) * h; ++p) {
                for (int c = 0; c < 3; ++c) rgba[p * 4 + c] = uint8_t(std::clamp(std::lround(rgb[p * 3 + c]), 0L, 255L));
                rgba[p * 4 + 3] = 255;
            }
            apply_orientation(rgba, w, h, 4, orientation);
            out.width = w; out.height = h; out.rgba = std::move(rgba);
            return true;
        }
        // No usable embedded preview: a half-size sRGB decode.
        raw = std::make_unique<LibRaw>(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK);
        if (!raw_open(*raw, path, error)) return false;
        auto& p = raw->imgdata.params;
        p.half_size = 1;
        p.output_color = 1;
        p.output_bps = 8;
        p.use_camera_wb = 1;
        p.gamm[0] = 1 / 2.4;
        p.gamm[1] = 12.92;
        if (raw->unpack() != LIBRAW_SUCCESS || raw->dcraw_process() != LIBRAW_SUCCESS) {
            error = "RAW thumbnail: decode failed";
            return false;
        }
        int status = 0;
        libraw_processed_image_t* img = raw->dcraw_make_mem_image(&status);
        if (!img || img->bits != 8 || img->colors != 3) {
            if (img) LibRaw::dcraw_clear_mem(img);
            error = "RAW thumbnail: unexpected bitmap";
            return false;
        }
        w = img->width; h = img->height;   // already oriented by LibRaw
        rgb.assign(img->data, img->data + size_t(w) * h * 3);
        LibRaw::dcraw_clear_mem(img);
        source = "half-size decode";
        shrink_rgb(rgb, w, h, long_edge);
        out.width = w; out.height = h;
        out.rgba.resize(size_t(w) * h * 4);
        for (size_t i = 0; i < size_t(w) * h; ++i) {
            for (int c = 0; c < 3; ++c) out.rgba[i * 4 + c] = uint8_t(std::clamp(std::lround(rgb[i * 3 + c]), 0L, 255L));
            out.rgba[i * 4 + 3] = 255;
        }
        return true;
    }
    Raster r;
    if (!read_raster(path, probe.kind, r, false, error)) return false;
    const RgbSpace space = raster_space(r, nullptr);
    uint32_t w = r.width, h = r.height;
    shrink_rgb(r.rgb, w, h, long_edge);
    std::vector<uint8_t> rgba;
    to_rgba8_srgb(space, r.rgb, r.codes, rgba);
    apply_orientation(rgba, w, h, 4, r.meta.orientation);
    out.width = w; out.height = h; out.rgba = std::move(rgba);
    source = "decode";
    return true;
}

}  // namespace spkhost
