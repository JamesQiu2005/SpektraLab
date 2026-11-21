// SPDX-License-Identifier: GPL-2.0-or-later
// Develop Camera: bakes the viewfinder's film LUTs with Develop's engine (its public C API, spk_engine.h).
//
// One 33^3 LUT per film, sRGB-encoded scene light in, the engine's sRGB print (or scan) out, exactly as the
// engine develops it, no softening: the viewfinder asks Camera2 for a plain sRGB tone curve, so its frames are
// encoded scene light, the same light the RAW path gives the engine. Auto exposure is off (the camera's meter
// sets exposure, as on a film camera), so the viewfinder and the developed shot agree.
// Nothing that spreads light between pixels (grain, halation, glare, diffusion, blurs): the app shows those
// approximately and the engine adds them for real. Each entry is developed as its own PATCH x PATCH square and
// read at its centre, out of reach of the scanner's sharpening (method of sonyalpha-film tools/develop/bake.py).
//
// File <id>.lut: "DCL1", uint32 N (33), then N^3 entries of uint16 R, G, B (0-65535, the engine's RGBA16
// codes), red fastest then green then blue (.cube order), little-endian.
//
//   bake <resources> <jobs.tsv> <out dir> [film id ...]       bake (all, or the ids given)
//   bake <resources> <jobs.tsv> <out dir> --check <film id>   compare one baked LUT with a direct develop
#include "spektralab/spk_engine.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {
constexpr uint32_t N = 33;
constexpr uint32_t PATCH = 7;

struct Job {
    std::string id, paper, pack;
    bool scan = false;
};

std::vector<Job> read_jobs(const char* path) {
    std::vector<Job> jobs;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        std::stringstream ss(line);
        Job j;
        std::string scan;
        std::getline(ss, j.id, '\t');
        std::getline(ss, j.paper, '\t');
        std::getline(ss, scan, '\t');
        std::getline(ss, j.pack, '\t');
        j.scan = scan == "1";
        jobs.push_back(j);
    }
    return jobs;
}

std::string params_for(const Job& j) {
    std::string p = "{\"product_defaults\": true,"
        "\"input_color_space\": \"sRGB\", \"input_cctf_decoding\": true,"
        "\"output_color_space\": \"sRGB\", \"output_cctf_encoding\": true,"
        "\"grain_active\": false, \"grain_sublayers_active\": false, \"halation_active\": false,"
        "\"glare_active\": false, \"diffusion_filter_active\": false, \"lens_blur_um\": 0.0,"
        "\"scanner_lens_blur\": 0.0, \"film_format_mm\": 300.0, \"overscan_active\": false,"
        "\"date_imprint_active\": false, \"scene_latitude_active\": false, \"contrast_mask_active\": false,"
        "\"auto_exposure\": false, \"exposure_compensation_ev\": 0.0,"
        "\"film_stock\": \"" + j.id + "\",";
    if (j.scan) {
        p += "\"scan_film\": true}";
    } else {
        p += "\"scan_film\": false, \"print_stock\": \"" + j.paper + "\"";
        if (j.pack != "-") {
            double m = 0, y = 0, e = 1;
            std::sscanf(j.pack.c_str(), "%lf %lf %lf", &m, &y, &e);
            char buf[160];
            std::snprintf(buf, sizeof buf, ", \"c_filter_neutral\": 0.0, \"m_filter_neutral\": %.17g,"
                          " \"y_filter_neutral\": %.17g, \"print_exposure\": %.17g", m, y, e);
            p += buf;
        }
        p += "}";
    }
    return p;
}

// Develops an image; rgba16 rows (row_stride_px) into out (w*h*3 uint16). Returns false with a message.
bool develop(spk_engine* engine, const Job& j, const std::vector<float>& px, uint32_t w, uint32_t h,
             std::vector<uint16_t>& out, std::string& err) {
    const spk_image image{px.data(), w, h, 3};
    char* reply = nullptr;
    const std::string params = params_for(j);
    spk_session* s = spk_open(engine, &image, params.c_str(), &reply);
    if (!s) { err = std::string("open: ") + spk_last_error(engine); return false; }
    spk_string_free(reply);
    spk_result r{};
    const spk_status st = spk_render(s, "full", &r);
    if (st != SPK_OK) {
        err = std::string("render: ") + spk_last_error(engine);
        spk_session_release(s);
        return false;
    }
    if (r.width != w || r.height != h) {
        err = "render size changed";
        spk_result_free(&r);
        spk_session_release(s);
        return false;
    }
    out.resize(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x)
            for (int c = 0; c < 3; ++c) out[(size_t(y) * w + x) * 3 + c] = r.rgba16[(size_t(y) * r.row_stride_px + x) * 4 + c];
    spk_result_free(&r);
    spk_session_release(s);
    return true;
}

// The grid: entry (r, g, b), red fastest, as a PATCH x PATCH square; N rows of N*N squares (row = blue).
std::vector<float> grid(uint32_t& w, uint32_t& h) {
    w = N * N * PATCH;
    h = N * PATCH;
    std::vector<float> px(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x) {
            const uint32_t b = y / PATCH, cell = x / PATCH, g = cell / N, r = cell % N;
            float* p = &px[(size_t(y) * w + x) * 3];
            p[0] = float(r) / float(N - 1); p[1] = float(g) / float(N - 1); p[2] = float(b) / float(N - 1);
        }
    return px;
}

bool bake(spk_engine* engine, const Job& j, const std::string& dir, std::string& err) {
    uint32_t w, h;
    const std::vector<float> px = grid(w, h);
    std::vector<uint16_t> dev;
    if (!develop(engine, j, px, w, h, dev, err)) return false;
    std::vector<uint16_t> lut(size_t(N) * N * N * 3);
    const uint32_t c = PATCH / 2;
    for (uint32_t b = 0; b < N; ++b)
        for (uint32_t g = 0; g < N; ++g)
            for (uint32_t r = 0; r < N; ++r) {
                const uint32_t x = (g * N + r) * PATCH + c, y = b * PATCH + c;
                for (int k = 0; k < 3; ++k)
                    lut[((size_t(b) * N + g) * N + r) * 3 + k] = dev[(size_t(y) * w + x) * 3 + k];
            }
    const std::string path = dir + "/" + j.id + ".lut";
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) { err = "cannot write " + path; return false; }
    const uint32_t n = N;
    std::fwrite("DCL1", 1, 4, f);
    std::fwrite(&n, 4, 1, f);
    std::fwrite(lut.data(), 2, lut.size(), f);
    std::fclose(f);
    return true;
}

bool load(const std::string& path, std::vector<uint16_t>& lut) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    char magic[4];
    uint32_t n = 0;
    bool ok = std::fread(magic, 1, 4, f) == 4 && std::memcmp(magic, "DCL1", 4) == 0 && std::fread(&n, 4, 1, f) == 1 && n == N;
    lut.resize(size_t(N) * N * N * 3);
    ok = ok && std::fread(lut.data(), 2, lut.size(), f) == lut.size();
    std::fclose(f);
    return ok;
}

// Trilinear lookup, as the viewfinder's GPU sampler does.
void apply(const std::vector<uint16_t>& lut, const float in[3], double out[3]) {
    double t[3];
    uint32_t i0[3], i1[3];
    for (int k = 0; k < 3; ++k) {
        const double v = std::fmin(1.0, std::fmax(0.0, double(in[k]))) * (N - 1);
        i0[k] = uint32_t(std::floor(v));
        if (i0[k] > N - 2) i0[k] = N - 2;
        i1[k] = i0[k] + 1;
        t[k] = v - i0[k];
    }
    for (int c = 0; c < 3; ++c) {
        double acc = 0.0;
        for (int corner = 0; corner < 8; ++corner) {
            const uint32_t r = corner & 1 ? i1[0] : i0[0], g = corner & 2 ? i1[1] : i0[1], b = corner & 4 ? i1[2] : i0[2];
            const double wgt = (corner & 1 ? t[0] : 1 - t[0]) * (corner & 2 ? t[1] : 1 - t[1]) * (corner & 4 ? t[2] : 1 - t[2]);
            acc += wgt * lut[((size_t(b) * N + g) * N + r) * 3 + c];
        }
        out[c] = acc;
    }
}

// A smooth test image (no detail for the scanner's sharpening to act on): hue across, value down, plus a
// saturation sweep in the bottom third. sRGB-encoded, as the viewfinder's frames are.
std::vector<float> test_image(uint32_t w, uint32_t h) {
    std::vector<float> px(size_t(w) * h * 3);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x) {
            const double u = double(x) / (w - 1), v = double(y) / (h - 1);
            const double hue = u * 6.0, val = v < 0.66 ? 0.05 + 0.95 * (v / 0.66) : 0.75;
            const double sat = v < 0.66 ? 0.6 : 1.0 - (v - 0.66) / 0.34;
            const int sector = int(hue) % 6;
            const double f = hue - std::floor(hue), p = val * (1 - sat), q = val * (1 - sat * f), t = val * (1 - sat * (1 - f));
            double r, g, b;
            switch (sector) {
                case 0: r = val; g = t; b = p; break;
                case 1: r = q; g = val; b = p; break;
                case 2: r = p; g = val; b = t; break;
                case 3: r = p; g = q; b = val; break;
                case 4: r = t; g = p; b = val; break;
                default: r = val; g = p; b = q; break;
            }
            float* o = &px[(size_t(y) * w + x) * 3];
            o[0] = float(r); o[1] = float(g); o[2] = float(b);
        }
    return px;
}

int check(spk_engine* engine, const Job& j, const std::string& dir) {
    std::vector<uint16_t> lut;
    if (!load(dir + "/" + j.id + ".lut", lut)) { std::printf("%s: no baked LUT to check\n", j.id.c_str()); return 1; }
    const uint32_t w = 768, h = 512;
    const std::vector<float> px = test_image(w, h);
    std::vector<uint16_t> dev;
    std::string err;
    if (!develop(engine, j, px, w, h, dev, err)) { std::printf("%s: %s\n", j.id.c_str(), err.c_str()); return 1; }
    // Compare away from the image's edges (the scanner's sharpening and edge handling).
    // The test image has one hard edge (value and saturation jump at 66 % height): rows near it are reported
    // apart, since the scanner's sharpening changes a direct develop there and cannot change a LUT.
    const uint32_t edge = uint32_t(0.66 * (h - 1));
    std::vector<double> diffs;
    double sum = 0.0, edge_max = 0.0, mx = 0.0;
    uint32_t mx_x = 0, mx_y = 0;
    for (uint32_t y = 8; y < h - 8; ++y)
        for (uint32_t x = 8; x < w - 8; ++x) {
            double o[3];
            apply(lut, &px[(size_t(y) * w + x) * 3], o);
            const bool near_edge = y + 8 >= edge && y <= edge + 8;
            for (int c = 0; c < 3; ++c) {
                const double d = std::fabs(o[c] - dev[(size_t(y) * w + x) * 3 + c]) / 257.0;   // 8-bit codes
                if (near_edge) { edge_max = std::fmax(edge_max, d); continue; }
                if (d > mx) { mx = d; mx_x = x; mx_y = y; }
                diffs.push_back(d);
                sum += d;
            }
        }
    std::vector<double> sorted = diffs;
    std::sort(sorted.begin(), sorted.end());
    std::printf("%s: LUT vs direct develop, 8-bit codes: mean %.3f  p99 %.2f  max %.2f at (%u, %u)"
                "  [hard edge rows: max %.2f]\n", j.id.c_str(), sum / diffs.size(),
                sorted[size_t(sorted.size() * 0.99)], mx, mx_x, mx_y, edge_max);
    return 0;
}
}  // namespace


int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s <resources> <jobs.tsv> <out dir> [--check id | id ...]\n", argv[0]);
        return 2;
    }
    const std::vector<Job> jobs = read_jobs(argv[2]);
    const std::string dir = argv[3];
    spk_engine* engine = spk_engine_create(argv[1], nullptr);
    if (!engine) { std::fprintf(stderr, "engine_create failed\n"); return 1; }
    int rc = 0;
    if (argc >= 6 && std::string(argv[4]) == "--check") {
        for (const Job& j : jobs) if (j.id == argv[5]) rc = check(engine, j, dir);
    } else {
        std::vector<std::string> only(argv + 4, argv + argc);
        size_t done = 0;
        for (const Job& j : jobs) {
            if (!only.empty() && std::find(only.begin(), only.end(), j.id) == only.end()) continue;
            std::string err;
            if (bake(engine, j, dir, err)) {
                ++done;
                std::printf("%3zu %-38s %s\n", done, j.id.c_str(), j.scan ? "scanned" : j.paper.c_str());
            } else {
                std::printf("FAILED %s: %s\n", j.id.c_str(), err.c_str());
                rc = 1;
            }
            std::fflush(stdout);
        }
    }
    spk_engine_destroy(engine);
    return rc;
}
