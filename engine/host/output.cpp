#include "output.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <thread>

#include "image_io.hpp"
#include "json.hpp"
#include "platform.hpp"
#include "stb_image_write.h"

extern "C" unsigned char* stbi_zlib_compress(unsigned char* data, int data_len, int* out_len, int quality);

namespace spkhost {

std::string engine_space_name(const std::string& wire) {
    std::string w;
    for (char c : wire) w.push_back(char(std::tolower(static_cast<unsigned char>(c))));
    if (w == "srgb") return "sRGB";
    if (w == "display-p3" || w == "display p3" || w == "p3") return "Display P3";
    if (w == "prophoto" || w == "prophoto rgb" || w == "romm") return "ProPhoto RGB";
    return {};
}

// The transfer functions, as `Canvas/Shaders.metal` numbers them: 0 sRGB
// (and Display P3), 1 ProPhoto, 2 Adobe RGB (1998), 3 BT.709/2020, 4 identity.
static inline float spow(float v, float p) {
    const float s = v < 0.0f ? -1.0f : (v > 0.0f ? 1.0f : 0.0f);
    return s * std::pow(std::fabs(v), p);
}

float cctf_decode_mode(float v, uint32_t mode) {
    switch (mode) {
        case 0: return (0.040449936f >= v) ? v / 12.92f : spow((v + 0.055f) / 1.055f, 2.4f);
        case 1: return (v < 16.0f * (1.0f / 512.0f)) ? v / 16.0f : std::pow(v, 1.8f);
        case 2: return std::pow(v, 563.0f / 256.0f);
        case 3: {
            const float alpha = 1.099f, beta = 0.018f;
            const float bp = alpha * std::pow(beta, 0.45f) - (alpha - 1.0f);
            return (bp > v) ? v / 4.5f : spow((v + (alpha - 1.0f)) / alpha, 1.0f / 0.45f);
        }
        default: return v;
    }
}

float cctf_encode_mode(float v, uint32_t mode) {
    switch (mode) {
        case 0: return (v <= 0.0031308f) ? 12.92f * v : 1.055f * spow(v, 1.0f / 2.4f) - 0.055f;
        case 1: return (v < 1.0f / 512.0f) ? v * 16.0f : std::pow(v, 1.0f / 1.8f);
        case 2: return std::pow(v, 256.0f / 563.0f);
        case 3: {
            const float alpha = 1.099f, beta = 0.018f;
            return (beta > v) ? v * 4.5f : alpha * spow(v, 0.45f) - (alpha - 1.0f);
        }
        default: return v;
    }
}

bool OutputTransform::fetch(spk_engine* engine, const std::string& src, const std::string& dst,
                            std::string& error) {
    src_ = src;
    dst_ = dst;
    char* json = nullptr;
    const float* cmax = nullptr;
    uint32_t count = 0;
    if (spk_output_transform(engine, src.c_str(), dst.c_str(), nullptr, &json, &cmax, &count) != SPK_OK) {
        error = spk_last_error(engine);
        return false;
    }
    spk::Json reply;
    const bool parsed = spk::Json::parse(json, reply, error);
    spk_string_free(json);
    if (!parsed) return false;
    src_mode_ = uint32_t(reply.at("source_cctf_mode").as_int());
    dst_mode_ = uint32_t(reply.at("target_cctf_mode").as_int());
    const auto& m = reply.at("matrix").items();
    for (size_t i = 0; i < 9 && i < m.size(); ++i) matrix_[i] = float(m[i].as_double());
    const spk::Json& g = reply.at("gamut_compress");
    cam16_ = g.at("algorithm").as_string() == "cam16ucs";
    lightness_ = g.at("lightness_compression_active").as_bool();
    for (size_t i = 0; i < 9; ++i) {
        m2x_[i] = float(g.at("m_to_xyz").items()[i].as_double());
        m2r_[i] = float(g.at("m_to_rgb").items()[i].as_double());
    }
    for (size_t i = 0; i < 22; ++i) k_[i] = float(g.at("k").items()[i].as_double());
    nl_ = uint32_t(g.at("cmax_rows").as_int());
    nh_ = uint32_t(g.at("cmax_cols").as_int());
    cmax_ = cmax;
    if (size_t(nl_) * nh_ != count) { error = "output transform: C_max table size mismatch"; return false; }
    // Same space in and out: the engine already compressed into it, so the
    // pixels pass through untouched (only quantisation can change them).
    identity_ = src == dst;
    return true;
}

// `Canvas/Shaders.metal` cam16ucsInto / `shaders/gamut.metal`, line for line.
static inline void cam16ucs_into(float rgb[3], const std::array<float, 9>& m2x, const std::array<float, 9>& m2r,
                                 const std::array<float, 22>& k, const float* cmax, uint32_t nL, uint32_t nh,
                                 bool lc_active) {
    using std::pow; using std::fabs; using std::sqrt; using std::log; using std::exp;
    const float F_L = k[0], N_bb = k[1], N_cb = k[2], n_ = k[3], z = k[4], A_w = k[5], c_ = k[6], N_c = k[7];
    const float L_grid0 = k[8], L_grid1 = k[9], h_grid0 = k[10], h_step = k[11];
    const float threshold = k[12], limit = k[13], power_ = k[14];
    const float lc_threshold = k[15], lc_limit = k[16], lc_power = k[17], L_white = k[18];
    const float D0 = k[19], D1 = k[20], D2 = k[21];
    const float e_c = pow(1.64f - pow(0.29f, n_), 0.73f);
    const float inv_FL4 = pow(F_L, 0.25f);

    const float r = rgb[0], g = rgb[1], b_ = rgb[2];
    float X = m2x[0] * r + m2x[1] * g + m2x[2] * b_;
    float Y = m2x[3] * r + m2x[4] * g + m2x[5] * b_;
    float Z = m2x[6] * r + m2x[7] * g + m2x[8] * b_;
    X *= 100.0f; Y *= 100.0f; Z *= 100.0f;

    const float R = 0.401288f * X + 0.650173f * Y - 0.051461f * Z;
    const float G = -0.250268f * X + 1.204414f * Y + 0.045854f * Z;
    const float B = -0.002079f * X + 0.048952f * Y + 0.953127f * Z;

    const float Rc = D0 * R, Gc = D1 * G, Bc = D2 * B;
    const float sR = Rc >= 0.0f ? 1.0f : -1.0f, sG = Gc >= 0.0f ? 1.0f : -1.0f, sB = Bc >= 0.0f ? 1.0f : -1.0f;
    const float fR = pow(F_L * fabs(Rc) / 100.0f, 0.42f);
    const float fG = pow(F_L * fabs(Gc) / 100.0f, 0.42f);
    const float fB = pow(F_L * fabs(Bc) / 100.0f, 0.42f);
    const float Ra = 400.0f * sR * fR / (27.13f + fR) + 0.1f;
    const float Ga = 400.0f * sG * fG / (27.13f + fG) + 0.1f;
    const float Ba = 400.0f * sB * fB / (27.13f + fB) + 0.1f;

    const float a = Ra - 12.0f * Ga / 11.0f + Ba / 11.0f;
    const float bb = (Ra + Ga - 2.0f * Ba) / 9.0f;
    const float hrad = std::atan2(bb, a);
    const float e_t = 0.25f * (std::cos(hrad + 2.0f) + 3.8f);

    const float A = (2.0f * Ra + Ga + Ba / 20.0f - 0.305f) * N_bb;
    const float Aratio = A / A_w;
    const float sJ = Aratio >= 0.0f ? 1.0f : -1.0f;
    const float J = 100.0f * sJ * pow(fabs(Aratio), c_ * z);

    const float den = Ra + Ga + 21.0f * Ba / 20.0f;
    float t = 0.0f;
    if (den != 0.0f) t = (50000.0f / 13.0f * N_c * N_cb * e_t * sqrt(a * a + bb * bb)) / den;
    const float sq = sqrt(fabs(J) / 100.0f);
    const float C = (t > 0.0f) ? pow(t, 0.9f) * sq * e_c : 0.0f;
    const float M = C * inv_FL4;

    const float Mp = (1.0f / 0.0228f) * log(1.0f + 0.0228f * M);
    float Jp = 1.7f * J / (1.0f + 0.007f * J);

    if (lc_active) {
        float Ln = Jp / L_white;
        if (Ln > lc_threshold) {
            const float lsc = lc_limit - lc_threshold;
            const float lx = (Ln - lc_threshold) / lsc;
            const float ly = lx / pow(1.0f + pow(lx, lc_power), 1.0f / lc_power);
            Ln = lc_threshold + lsc * ly;
        }
        Jp = Ln * L_white;
    }

    const float Lc = std::min(std::max(Jp, L_grid0), L_grid1);
    const float Li = (Lc - L_grid0) / (L_grid1 - L_grid0) * float(nL - 1u);
    int l0 = int(std::floor(Li));
    l0 = std::min(std::max(l0, 0), int(nL) - 2);
    const float lf = Li - float(l0);
    const float hi_ = (hrad - h_grid0) / h_step;
    const float hfl = std::floor(hi_);
    const int nhi = int(nh);
    const int h0 = (int(hfl) % nhi + nhi) % nhi;
    const int h1 = (h0 + 1) % nhi;
    const float hf = hi_ - hfl;
    const float c00 = cmax[l0 * nhi + h0], c01 = cmax[l0 * nhi + h1];
    const float c10 = cmax[(l0 + 1) * nhi + h0], c11 = cmax[(l0 + 1) * nhi + h1];
    const float Cmax = (1.0f - lf) * ((1.0f - hf) * c00 + hf * c01) + lf * ((1.0f - hf) * c10 + hf * c11);
    const float safe = Cmax > 1e-9f ? Cmax : 1e-9f;

    float d = Mp / safe;
    if (d > threshold) {
        const float sc = limit - threshold;
        const float xk = (d - threshold) / sc;
        const float yk = xk / pow(1.0f + pow(xk, power_), 1.0f / power_);
        d = threshold + sc * yk;
    }
    const float Mp_new = d * safe;

    const float M_new = (exp(Mp_new * 0.0228f) - 1.0f) / 0.0228f;
    const float J_new = Jp / (1.7f - 0.007f * Jp);
    const float C_new = M_new / inv_FL4;

    const float sJ2 = J_new >= 0.0f ? 1.0f : -1.0f;
    const float A2 = A_w * sJ2 * pow(fabs(J_new) / 100.0f, 1.0f / (c_ * z));
    const float sq2 = sqrt(fabs(J_new) / 100.0f);
    const float t2 = (sq2 > 0.0f && C_new > 0.0f) ? pow(C_new / (sq2 * e_c), 1.0f / 0.9f) : 0.0f;
    const float ca = std::cos(hrad), sa = std::sin(hrad);
    const float p2 = A2 / N_bb + 0.305f;
    const float p3 = 21.0f / 20.0f;
    float a2, b2;
    if (t2 == 0.0f) { a2 = 0.0f; b2 = 0.0f; }
    else {
        const float p1 = ((50000.0f / 13.0f) * N_c * N_cb * e_t) / t2;
        if (fabs(sa) >= fabs(ca)) {
            const float p4 = p1 / sa;
            b2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                 (p4 + (2.0f + p3) * (220.0f / 1403.0f) * (ca / sa) - (27.0f / 1403.0f) + p3 * (6300.0f / 1403.0f));
            a2 = b2 * (ca / sa);
        } else {
            const float p5 = p1 / ca;
            a2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                 (p5 + (2.0f + p3) * (220.0f / 1403.0f) - ((27.0f / 1403.0f) - p3 * (6300.0f / 1403.0f)) * (sa / ca));
            b2 = a2 * (sa / ca);
        }
    }
    const float Ra2 = (460.0f * p2 + 451.0f * a2 + 288.0f * b2) / 1403.0f;
    const float Ga2 = (460.0f * p2 - 891.0f * a2 - 261.0f * b2) / 1403.0f;
    const float Ba2 = (460.0f * p2 - 220.0f * a2 - 6300.0f * b2) / 1403.0f;

    auto inverse = [&](float va, float Dc) {
        const float vm = va - 0.1f;
        const float sv = vm >= 0.0f ? 1.0f : -1.0f;
        const float base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
        return (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / Dc;
    };
    const float Rf = inverse(Ra2, D0), Gf = inverse(Ga2, D1), Bf = inverse(Ba2, D2);

    float Xn = 1.86206786f * Rf - 1.01125463f * Gf + 0.14918677f * Bf;
    float Yn = 0.38752654f * Rf + 0.62144744f * Gf - 0.00897398f * Bf;
    float Zn = -0.01584150f * Rf - 0.03412294f * Gf + 1.04996444f * Bf;
    Xn /= 100.0f; Yn /= 100.0f; Zn /= 100.0f;

    rgb[0] = m2r[0] * Xn + m2r[1] * Yn + m2r[2] * Zn;
    rgb[1] = m2r[3] * Xn + m2r[4] * Yn + m2r[5] * Zn;
    rgb[2] = m2r[6] * Xn + m2r[7] * Yn + m2r[8] * Zn;
}

template <typename F>
static void parallel(uint32_t rows, F&& body) {
    const unsigned threads = std::min<unsigned>(hardware_threads(), std::max<uint32_t>(1, rows / 8));
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

void OutputTransform::to_linear(const uint16_t* rgba16, uint32_t w, uint32_t h, uint32_t stride,
                                std::vector<float>& rgb) const {
    rgb.resize(size_t(w) * h * 3);
    // One decode per code value: the source is 16-bit.
    std::vector<float> decode(65536);
    for (uint32_t i = 0; i < 65536; ++i) decode[i] = cctf_decode_mode(float(i) / 65535.0f, src_mode_);
    parallel(h, [&](uint32_t y0, uint32_t y1) {
        for (uint32_t y = y0; y < y1; ++y) {
            const uint16_t* row = rgba16 + size_t(y) * stride * 4;
            float* out = &rgb[size_t(y) * w * 3];
            for (uint32_t x = 0; x < w; ++x) {
                float v[3] = {decode[row[x * 4]], decode[row[x * 4 + 1]], decode[row[x * 4 + 2]]};
                float lin[3];
                if (identity_) {
                    lin[0] = v[0]; lin[1] = v[1]; lin[2] = v[2];
                } else {
                    for (int i = 0; i < 3; ++i)
                        lin[i] = matrix_[i * 3] * v[0] + matrix_[i * 3 + 1] * v[1] + matrix_[i * 3 + 2] * v[2];
                    if (cam16_) cam16ucs_into(lin, m2x_, m2r_, k_, cmax_, nl_, nh_, lightness_);
                }
                out[x * 3] = lin[0]; out[x * 3 + 1] = lin[1]; out[x * 3 + 2] = lin[2];
            }
        }
    });
}

void OutputTransform::encode_rgba8(const std::vector<float>& rgb, std::vector<uint8_t>& rgba) const {
    const size_t n = rgb.size() / 3;
    rgba.resize(n * 4);
    const uint32_t rows = uint32_t((n + 4095) / 4096);
    parallel(rows, [&](uint32_t r0, uint32_t r1) {
        for (size_t p = size_t(r0) * 4096; p < std::min(n, size_t(r1) * 4096); ++p) {
            for (int c = 0; c < 3; ++c) {
                const float e = cctf_encode_mode(rgb[p * 3 + c], dst_mode_);
                rgba[p * 4 + c] = uint8_t(std::lround(std::clamp(e, 0.0f, 1.0f) * 255.0f));
            }
            rgba[p * 4 + 3] = 255;
        }
    });
}

void OutputTransform::encode_rgba16(const std::vector<float>& rgb, std::vector<uint16_t>& rgba) const {
    const size_t n = rgb.size() / 3;
    rgba.resize(n * 4);
    const uint32_t rows = uint32_t((n + 4095) / 4096);
    parallel(rows, [&](uint32_t r0, uint32_t r1) {
        for (size_t p = size_t(r0) * 4096; p < std::min(n, size_t(r1) * 4096); ++p) {
            for (int c = 0; c < 3; ++c) {
                const float e = cctf_encode_mode(rgb[p * 3 + c], dst_mode_);
                rgba[p * 4 + c] = uint16_t(std::lround(std::clamp(e, 0.0f, 1.0f) * 65535.0f));
            }
            rgba[p * 4 + 3] = 65535;
        }
    });
}

// --- ICC ---------------------------------------------------------------------

static void put32(std::vector<uint8_t>& b, uint32_t v) {
    b.push_back(uint8_t(v >> 24)); b.push_back(uint8_t(v >> 16)); b.push_back(uint8_t(v >> 8)); b.push_back(uint8_t(v));
}
static void put16(std::vector<uint8_t>& b, uint16_t v) { b.push_back(uint8_t(v >> 8)); b.push_back(uint8_t(v)); }
static void puts15(std::vector<uint8_t>& b, double v) { put32(b, uint32_t(int32_t(std::lround(v * 65536.0)))); }
static void pad4(std::vector<uint8_t>& b) { while (b.size() % 4) b.push_back(0); }

// A v2 matrix/TRC display profile: D50 colorants (Bradford-adapted, as every
// such profile carries them), one shared 1024-entry curve.
static std::vector<uint8_t> make_icc(const std::string& description, const std::array<double, 9>& to_xyz_d50,
                                     uint32_t cctf_mode) {
    struct Tag { char sig[5]; std::vector<uint8_t> data; };
    std::vector<Tag> tags;
    {   // desc
        std::vector<uint8_t> d;
        d.insert(d.end(), {'d', 'e', 's', 'c', 0, 0, 0, 0});
        put32(d, uint32_t(description.size() + 1));
        d.insert(d.end(), description.begin(), description.end());
        d.push_back(0);
        put32(d, 0); put32(d, 0);   // unicode language, count
        put16(d, 0); d.push_back(0); d.insert(d.end(), 67, 0);   // scriptcode
        tags.push_back({"desc", d});
    }
    {
        const std::string text = "No copyright, use freely";
        std::vector<uint8_t> d = {'t', 'e', 'x', 't', 0, 0, 0, 0};
        d.insert(d.end(), text.begin(), text.end());
        d.push_back(0);
        tags.push_back({"cprt", d});
    }
    auto xyz = [](double x, double y, double z) {
        std::vector<uint8_t> d = {'X', 'Y', 'Z', ' ', 0, 0, 0, 0};
        puts15(d, x); puts15(d, y); puts15(d, z);
        return d;
    };
    tags.push_back({"wtpt", xyz(0.9642, 1.0, 0.8249)});
    tags.push_back({"rXYZ", xyz(to_xyz_d50[0], to_xyz_d50[3], to_xyz_d50[6])});
    tags.push_back({"gXYZ", xyz(to_xyz_d50[1], to_xyz_d50[4], to_xyz_d50[7])});
    tags.push_back({"bXYZ", xyz(to_xyz_d50[2], to_xyz_d50[5], to_xyz_d50[8])});
    std::vector<uint8_t> curve = {'c', 'u', 'r', 'v', 0, 0, 0, 0};
    const uint32_t n = 1024;
    put32(curve, n);
    for (uint32_t i = 0; i < n; ++i) {
        const float lin = cctf_decode_mode(float(i) / (n - 1), cctf_mode);
        put16(curve, uint16_t(std::lround(std::clamp(lin, 0.0f, 1.0f) * 65535.0f)));
    }
    tags.push_back({"rTRC", curve});
    tags.push_back({"gTRC", curve});
    tags.push_back({"bTRC", curve});

    std::vector<uint8_t> body;   // tag data region
    std::vector<std::array<uint32_t, 2>> places;
    const uint32_t table = 128 + 4 + uint32_t(tags.size()) * 12;
    uint32_t shared_curve = 0;
    for (const Tag& t : tags) {
        const bool is_curve = std::strcmp(t.sig, "gTRC") == 0 || std::strcmp(t.sig, "bTRC") == 0;
        if (is_curve) { places.push_back({shared_curve, uint32_t(t.data.size())}); continue; }
        const uint32_t at = table + uint32_t(body.size());
        if (std::strcmp(t.sig, "rTRC") == 0) shared_curve = at;
        body.insert(body.end(), t.data.begin(), t.data.end());
        pad4(body);
        places.push_back({at, uint32_t(t.data.size())});
    }
    std::vector<uint8_t> p;
    put32(p, table + uint32_t(body.size()));
    put32(p, 0);                         // CMM
    put32(p, 0x02100000);                // v2.1
    p.insert(p.end(), {'m', 'n', 't', 'r', 'R', 'G', 'B', ' ', 'X', 'Y', 'Z', ' '});
    std::time_t now = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &now);
#else
    gmtime_r(&now, &tm);
#endif
    put16(p, uint16_t(tm.tm_year + 1900)); put16(p, uint16_t(tm.tm_mon + 1)); put16(p, uint16_t(tm.tm_mday));
    put16(p, uint16_t(tm.tm_hour)); put16(p, uint16_t(tm.tm_min)); put16(p, uint16_t(tm.tm_sec));
    p.insert(p.end(), {'a', 'c', 's', 'p'});
    put32(p, 0); put32(p, 0); put32(p, 0); put32(p, 0);   // platform, flags, manufacturer, model
    put32(p, 0); put32(p, 0);                              // attributes
    put32(p, 0);                                           // intent: perceptual
    puts15(p, 0.9642); puts15(p, 1.0); puts15(p, 0.8249);  // PCS illuminant
    put32(p, 0);                                           // creator
    p.resize(128, 0);
    put32(p, uint32_t(tags.size()));
    for (size_t i = 0; i < tags.size(); ++i) {
        p.insert(p.end(), tags[i].sig, tags[i].sig + 4);
        put32(p, places[i][0]);
        put32(p, places[i][1]);
    }
    p.insert(p.end(), body.begin(), body.end());
    return p;
}

bool icc_for(const std::string& space, const std::filesystem::path& resources, std::vector<uint8_t>& icc,
             std::string& error) {
    if (space == "sRGB") return read_file(resources / "io" / "sRGB.icc", icc, error);
    if (space == "Display P3") { icc = make_icc("Display P3", display_p3_space().to_xyz_d50, 0); return true; }
    if (space == "ProPhoto RGB") { icc = make_icc("ProPhoto RGB (ROMM)", linear_prophoto_space().to_xyz_d50, 1); return true; }
    error = "no ICC profile for '" + space + "'";
    return false;
}

// --- writers -------------------------------------------------------------------

bool encode_tiff(const void* rgb, uint32_t w, uint32_t h, uint32_t bits, const std::vector<uint8_t>& icc,
                 std::vector<uint8_t>& out, std::string& error) {
    if (bits != 8 && bits != 16) { error = "TIFF bits must be 8 or 16"; return false; }
    const uint64_t row_bytes = uint64_t(w) * 3 * (bits / 8);
    const uint64_t image_bytes = row_bytes * h;
    if (image_bytes > 0xF0000000ull) { error = "image too large for a classic TIFF"; return false; }
    const uint32_t rows_per_strip = uint32_t(std::max<uint64_t>(1, std::min<uint64_t>(h, (1u << 20) / std::max<uint64_t>(1, row_bytes))));
    const uint32_t strips = (h + rows_per_strip - 1) / rows_per_strip;

    out.clear();
    auto u16 = [&](uint16_t v) { out.push_back(uint8_t(v)); out.push_back(uint8_t(v >> 8)); };
    auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) out.push_back(uint8_t(v >> (8 * i))); };
    auto set32 = [&](size_t at, uint32_t v) { for (int i = 0; i < 4; ++i) out[at + i] = uint8_t(v >> (8 * i)); };
    out.insert(out.end(), {'I', 'I', 42, 0});
    u32(8);
    struct E { uint16_t tag, type; uint32_t count; uint32_t value; std::vector<uint8_t> extra; };
    std::vector<E> e;
    auto le32 = [](std::vector<uint32_t> v) { std::vector<uint8_t> b; for (uint32_t x : v) for (int i = 0; i < 4; ++i) b.push_back(uint8_t(x >> (8 * i))); return b; };
    std::vector<uint8_t> bps = {uint8_t(bits), 0, uint8_t(bits), 0, uint8_t(bits), 0};
    e.push_back({256, 4, 1, w, {}});
    e.push_back({257, 4, 1, h, {}});
    e.push_back({258, 3, 3, 0, bps});
    e.push_back({259, 3, 1, 1, {}});
    e.push_back({262, 3, 1, 2, {}});
    e.push_back({273, 4, strips, 0, std::vector<uint8_t>(size_t(strips) * 4)});   // filled below
    e.push_back({274, 3, 1, 1, {}});
    e.push_back({277, 3, 1, 3, {}});
    e.push_back({278, 4, 1, rows_per_strip, {}});
    std::vector<uint32_t> counts(strips);
    for (uint32_t s = 0; s < strips; ++s) counts[s] = uint32_t(row_bytes * std::min(rows_per_strip, h - s * rows_per_strip));
    e.push_back({279, 4, strips, 0, le32(counts)});
    e.push_back({282, 5, 1, 0, le32({72, 1})});
    e.push_back({283, 5, 1, 0, le32({72, 1})});
    e.push_back({284, 3, 1, 1, {}});
    e.push_back({296, 3, 1, 2, {}});
    const std::string software = "SpektraLab";
    e.push_back({305, 2, uint32_t(software.size() + 1), 0, std::vector<uint8_t>(software.begin(), software.end())});
    e.back().extra.push_back(0);
    if (!icc.empty()) e.push_back({34675, 7, uint32_t(icc.size()), 0, icc});
    // single values of <= 4 bytes go inline
    const size_t ifd_at = 8;
    const size_t ifd_size = 2 + e.size() * 12 + 4;
    size_t extra_at = ifd_at + ifd_size;
    std::vector<size_t> extra_offsets(e.size());
    for (size_t i = 0; i < e.size(); ++i) {
        if (e[i].extra.size() > 4) {
            extra_offsets[i] = extra_at;
            extra_at += e[i].extra.size() + (e[i].extra.size() & 1);
        }
    }
    const size_t pixel_at = (extra_at + 15) & ~size_t(15);
    // strip offsets
    {
        std::vector<uint32_t> offs(strips);
        for (uint32_t s = 0; s < strips; ++s) offs[s] = uint32_t(pixel_at + uint64_t(s) * rows_per_strip * row_bytes);
        e[5].extra = le32(offs);
        if (strips == 1) { e[5].value = offs[0]; e[5].extra.clear(); }
        if (strips == 1) { e[9].value = counts[0]; e[9].extra.clear(); }
    }
    u16(uint16_t(e.size()));
    for (size_t i = 0; i < e.size(); ++i) {
        u16(e[i].tag); u16(e[i].type); u32(e[i].count);
        if (e[i].extra.size() > 4) u32(uint32_t(extra_offsets[i]));
        else if (!e[i].extra.empty()) {
            std::vector<uint8_t> v = e[i].extra;
            v.resize(4, 0);
            out.insert(out.end(), v.begin(), v.end());
        } else if (e[i].type == 3) { u16(uint16_t(e[i].value)); u16(0); }
        else u32(e[i].value);
    }
    u32(0);
    for (size_t i = 0; i < e.size(); ++i) {
        if (e[i].extra.size() > 4) {
            if (out.size() != extra_offsets[i]) { error = "internal TIFF layout error"; return false; }
            out.insert(out.end(), e[i].extra.begin(), e[i].extra.end());
            if (e[i].extra.size() & 1) out.push_back(0);
        }
    }
    out.resize(pixel_at, 0);
    (void)set32;
    const size_t start = out.size();
    out.resize(start + size_t(image_bytes));
    if (bits == 8) std::memcpy(&out[start], rgb, size_t(image_bytes));
    else {
        const uint16_t* s = static_cast<const uint16_t*>(rgb);
        for (size_t i = 0; i < size_t(image_bytes) / 2; ++i) {
            out[start + 2 * i] = uint8_t(s[i]);
            out[start + 2 * i + 1] = uint8_t(s[i] >> 8);
        }
    }
    return true;
}

static uint32_t crc32(const uint8_t* d, size_t n, uint32_t crc = 0) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    crc = ~crc;
    for (size_t i = 0; i < n; ++i) crc = table[(crc ^ d[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

static void sink(void* context, void* data, int size) {
    auto* v = static_cast<std::vector<uint8_t>*>(context);
    v->insert(v->end(), static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + size);
}

bool encode_png8(const uint8_t* rgb, uint32_t w, uint32_t h, const std::vector<uint8_t>& icc,
                 std::vector<uint8_t>& out, std::string& error) {
    std::vector<uint8_t> png;
    if (!stbi_write_png_to_func(sink, &png, int(w), int(h), 3, rgb, int(w * 3)) || png.size() < 33) {
        error = "PNG encode failed";
        return false;
    }
    out.clear();
    out.insert(out.end(), png.begin(), png.begin() + 33);   // signature + IHDR
    if (!icc.empty()) {
        int zlen = 0;
        unsigned char* z = stbi_zlib_compress(const_cast<unsigned char*>(icc.data()), int(icc.size()), &zlen, 8);
        if (!z) { error = "PNG ICC compression failed"; return false; }
        std::vector<uint8_t> chunk = {'i', 'C', 'C', 'P'};
        const char* name = "ICC Profile";
        chunk.insert(chunk.end(), name, name + std::strlen(name));
        chunk.push_back(0);
        chunk.push_back(0);
        chunk.insert(chunk.end(), z, z + zlen);
        std::free(z);
        put32(out, uint32_t(chunk.size() - 4));
        out.insert(out.end(), chunk.begin(), chunk.end());
        put32(out, crc32(chunk.data(), chunk.size()));
    }
    out.insert(out.end(), png.begin() + 33, png.end());
    return true;
}

bool encode_jpeg(const uint8_t* rgb, uint32_t w, uint32_t h, int quality, const std::vector<uint8_t>& icc,
                 std::vector<uint8_t>& out, std::string& error) {
    std::vector<uint8_t> jpg;
    if (!stbi_write_jpg_to_func(sink, &jpg, int(w), int(h), 3, rgb, std::clamp(quality, 1, 100)) || jpg.size() < 4) {
        error = "JPEG encode failed";
        return false;
    }
    out.assign(jpg.begin(), jpg.begin() + 2);   // SOI
    const size_t max_chunk = 65519;
    const size_t chunks = (icc.size() + max_chunk - 1) / max_chunk;
    for (size_t c = 0; c < chunks; ++c) {
        const size_t at = c * max_chunk, n = std::min(max_chunk, icc.size() - at);
        out.push_back(0xFF); out.push_back(0xE2);
        put16(out, uint16_t(n + 16));
        const char* sig = "ICC_PROFILE";
        out.insert(out.end(), sig, sig + 12);   // includes the NUL
        out.push_back(uint8_t(c + 1)); out.push_back(uint8_t(chunks));
        out.insert(out.end(), icc.begin() + at, icc.begin() + at + n);
    }
    out.insert(out.end(), jpg.begin() + 2, jpg.end());
    return true;
}

std::string cube_text(const float* table, uint32_t size, const std::string& title) {
    std::string out;
    out.reserve(size_t(size) * size * size * 30 + 128);
    out += "TITLE \"" + title + "\"\nLUT_3D_SIZE " + std::to_string(size) + "\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n";
    char line[96];
    for (uint32_t b = 0; b < size; ++b)
        for (uint32_t g = 0; g < size; ++g)
            for (uint32_t r = 0; r < size; ++r) {
                const float* v = table + ((size_t(r) * size + g) * size + b) * 3;
                std::snprintf(line, sizeof line, "%.6f %.6f %.6f\n", double(v[0]), double(v[1]), double(v[2]));
                out += line;
            }
    return out;
}

}  // namespace spkhost
