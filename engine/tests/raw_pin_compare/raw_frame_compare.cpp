// raw_frame_compare <a.spkf32> <b.spkf32>
//
// Compares two frames raw_decode_dump wrote and prints one JSON object:
// both headers, whether size and LibRaw flip agree, and the absolute
// difference over the samples compared: max, mean, the share of samples that
// differ at all and by more than one 16-bit code, the 99.9th percentile (from
// a fixed histogram in 1/65535 steps), and the per-channel means of each side.
// Values are in the decoder's linear [0,1] scale, so 1/65535 is one code of
// LibRaw's 16-bit output.
//
// Same size: every sample. Different size with b at least as large as a in
// both directions (a pin that crops less of the sensor): the offset of a
// inside b is found first (the smallest mean difference over a sparse grid,
// every offset tried), then a's interior -- a band of kAlignBorder pixels
// left out, where the demosaic of a cropped frame sees an edge the larger
// one does not -- is compared with the same pixels of b ("aligned": {...}).
// No judgement is made here; raw_pin_compare.sh holds the expectation.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <string>
#include <vector>

namespace {
constexpr std::uint32_t kAlignBorder = 8;

struct Frame {
    std::map<std::string, std::string> header;
    std::uint32_t width = 0, height = 0;
    std::ifstream data;
};

bool open_frame(const char* path, Frame& f) {
    f.data.open(path, std::ios::binary);
    if (!f.data) return false;
    std::string line;
    if (!std::getline(f.data, line) || line != "SPKF32 1") return false;
    while (std::getline(f.data, line) && !line.empty()) {
        const auto space = line.find(' ');
        f.header[line.substr(0, space)] = space == std::string::npos ? "" : line.substr(space + 1);
    }
    f.width = static_cast<std::uint32_t>(std::stoul(f.header["width"]));
    f.height = static_cast<std::uint32_t>(std::stoul(f.header["height"]));
    return true;
}

bool read_all(Frame& f, std::vector<float>& out) {
    out.resize(std::size_t(f.width) * f.height * 3);
    f.data.read(reinterpret_cast<char*>(out.data()), std::streamsize(out.size() * sizeof(float)));
    return bool(f.data);
}

std::string quote(const std::string& s) {
    std::string out = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    return out + "\"";
}

void print_header(const char* key, const Frame& f) {
    std::printf("\"%s\":{", key);
    bool first = true;
    for (const auto& [k, v] : f.header) {
        std::printf("%s%s:%s", first ? "" : ",", quote(k).c_str(), quote(v).c_str());
        first = false;
    }
    std::printf("}");
}

struct Stats {
    static constexpr std::size_t kBins = 65536 * 2;  // 0 .. 2.0 in 1/65535 steps; the last bin collects the rest
    std::vector<std::uint64_t> histogram = std::vector<std::uint64_t>(kBins + 1, 0);
    std::array<double, 3> sum_a{}, sum_b{};
    double max_abs = 0.0, sum_abs = 0.0;
    std::uint64_t differ = 0, differ_code = 0, nonfinite = 0, total = 0;

    void add(double x, double y, std::size_t channel) {
        if (!std::isfinite(x) || !std::isfinite(y)) {
            ++nonfinite;
            return;
        }
        sum_a[channel] += x;
        sum_b[channel] += y;
        const double d = std::fabs(x - y);
        max_abs = std::max(max_abs, d);
        sum_abs += d;
        if (d > 0.0) ++differ;
        if (d > 1.5 / 65535.0) ++differ_code;
        ++histogram[std::min<std::size_t>(kBins, static_cast<std::size_t>(d * 65535.0))];
        ++total;
    }

    void print() const {
        const std::uint64_t target = static_cast<std::uint64_t>(std::ceil(double(total) * 0.999));
        std::uint64_t running = 0;
        std::size_t p999 = 0;
        for (; p999 <= kBins; ++p999) {
            running += histogram[p999];
            if (running >= target) break;
        }
        const double per_channel = total ? double(total) / 3.0 : 1.0;
        std::printf("\"samples\":%llu,\"nonfinite\":%llu,\"max_abs\":%.9g,\"mean_abs\":%.9g,"
                    "\"share_differ\":%.9g,\"share_differ_over_1_code\":%.9g,\"p999_abs_codes\":%zu,"
                    "\"mean_a\":[%.9g,%.9g,%.9g],\"mean_b\":[%.9g,%.9g,%.9g]",
                    static_cast<unsigned long long>(total), static_cast<unsigned long long>(nonfinite), max_abs,
                    total ? sum_abs / double(total) : 0.0, total ? double(differ) / double(total) : 0.0,
                    total ? double(differ_code) / double(total) : 0.0, p999,
                    sum_a[0] / per_channel, sum_a[1] / per_channel, sum_a[2] / per_channel,
                    sum_b[0] / per_channel, sum_b[1] / per_channel, sum_b[2] / per_channel);
    }
};
}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: raw_frame_compare <a> <b>\n";
        return 2;
    }
    Frame a, b;
    if (!open_frame(argv[1], a) || !open_frame(argv[2], b)) {
        std::cerr << "not a raw_decode_dump frame\n";
        return 2;
    }
    const bool same_size = a.width == b.width && a.height == b.height;
    const bool same_flip = a.header["flip"] == b.header["flip"];
    std::printf("{");
    print_header("a", a);
    std::printf(",");
    print_header("b", b);
    std::printf(",\"same_size\":%s,\"same_flip\":%s", same_size ? "true" : "false", same_flip ? "true" : "false");
    if (same_size) {
        Stats stats;
        std::vector<float> ca(1 << 20), cb(1 << 20);
        const std::uint64_t samples = std::uint64_t(a.width) * a.height * 3;
        std::uint64_t done = 0;
        while (done < samples) {
            const std::size_t n = static_cast<std::size_t>(std::min<std::uint64_t>(ca.size(), samples - done));
            a.data.read(reinterpret_cast<char*>(ca.data()), std::streamsize(n * sizeof(float)));
            b.data.read(reinterpret_cast<char*>(cb.data()), std::streamsize(n * sizeof(float)));
            if (!a.data || !b.data) {
                std::cerr << "truncated frame\n";
                return 2;
            }
            for (std::size_t i = 0; i < n; ++i) stats.add(ca[i], cb[i], static_cast<std::size_t>((done + i) % 3));
            done += n;
        }
        std::printf(",");
        stats.print();
        std::printf("}\n");
        return 0;
    }
    if (b.width < a.width || b.height < a.height || a.width <= 2 * kAlignBorder || a.height <= 2 * kAlignBorder) {
        std::printf("}\n");
        return 0;
    }
    std::vector<float> fa, fb;
    if (!read_all(a, fa) || !read_all(b, fb)) {
        std::cerr << "truncated frame\n";
        return 2;
    }
    const auto at = [](const std::vector<float>& f, std::uint32_t w, std::uint32_t x, std::uint32_t y, unsigned c) {
        return double(f[(std::size_t(y) * w + x) * 3 + c]);
    };
    // Every offset, scored on a 64 x 64 grid of a's interior.
    std::uint32_t best_dx = 0, best_dy = 0;
    double best = std::numeric_limits<double>::infinity();
    for (std::uint32_t dy = 0; dy <= b.height - a.height; ++dy) {
        for (std::uint32_t dx = 0; dx <= b.width - a.width; ++dx) {
            double score = 0.0;
            for (unsigned gy = 0; gy < 64; ++gy) {
                const std::uint32_t y = kAlignBorder + gy * (a.height - 2 * kAlignBorder) / 64;
                for (unsigned gx = 0; gx < 64; ++gx) {
                    const std::uint32_t x = kAlignBorder + gx * (a.width - 2 * kAlignBorder) / 64;
                    for (unsigned c = 0; c < 3; ++c)
                        score += std::fabs(at(fa, a.width, x, y, c) - at(fb, b.width, x + dx, y + dy, c));
                }
            }
            if (score < best) {
                best = score;
                best_dx = dx;
                best_dy = dy;
            }
        }
    }
    Stats stats;
    for (std::uint32_t y = kAlignBorder; y < a.height - kAlignBorder; ++y)
        for (std::uint32_t x = kAlignBorder; x < a.width - kAlignBorder; ++x)
            for (unsigned c = 0; c < 3; ++c)
                stats.add(at(fa, a.width, x, y, c), at(fb, b.width, x + best_dx, y + best_dy, c), c);
    std::printf(",\"aligned\":{\"offset_x\":%u,\"offset_y\":%u,\"border\":%u,", best_dx, best_dy, kAlignBorder);
    stats.print();
    std::printf("}}\n");
    return 0;
}
