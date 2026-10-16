// White balance at decode for the Windows desktop host (desktop/
// raw_white_balance.hpp), without a RAW file: the settings rows and their
// decode identity, the presets, the box sampler, and the neutral picker on a
// synthetic camera -- a grey card under a known illuminant, decoded at the
// wrong white balance, picked, and decoded again at the answer.
//
// The synthetic camera is LibRaw's own model of one: cam_xyz (here Sony
// ILCE-7M4's Adobe matrix, LibRaw's colordata table, /10000), rgb_cam its
// row-normalised pseudoinverse against sRGB as cam_xyz_coeff builds it, and
// the decoded value camera_to_output . (multipliers ⊙ camera response).
#include "desktop/preview_host.hpp"
#include "desktop/raw_white_balance.hpp"
#include "../host/white_balance.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>

using namespace spk::desktop;

namespace {

int checks = 0;
void check(bool condition, const std::string& message) {
    ++checks;
    if (!condition) throw std::runtime_error(message);
}

using M3 = std::array<double, 9>;
using V3 = std::array<double, 3>;

V3 apply(const M3& m, const V3& v) {
    return {m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
            m[6] * v[0] + m[7] * v[1] + m[8] * v[2]};
}
M3 multiply(const M3& a, const M3& b) {
    M3 out{};
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            for (int k = 0; k < 3; ++k) out[r * 3 + c] += a[r * 3 + k] * b[k * 3 + c];
    return out;
}
M3 inverse(const M3& m) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    return {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det, (f * g - d * i) / det,
            (a * i - c * g) / det, (c * d - a * f) / det, (d * h - e * g) / det, (b * g - a * h) / det,
            (a * e - b * d) / det};
}

// LibRaw's tables (src/tables/colorconst.cpp): sRGB -> XYZ (D65) and
// sRGB -> ProPhoto, which convert_to_rgb applies after rgb_cam.
constexpr M3 kXyzRgb{0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750,
                     0.0193339, 0.1191920, 0.9503041};
constexpr M3 kProphotoRgb{0.529317, 0.330092, 0.140588, 0.098368, 0.873465, 0.028169,
                          0.016879, 0.117663, 0.865457};
constexpr M3 kSonyA7IV{0.7460, -0.2365, -0.0588, -0.5687, 1.3442, 0.2474, -0.0624, 0.1156, 0.6584};

struct Camera {
    M3 xyz_to_camera = kSonyA7IV;
    M3 to_output{};
    Camera() {
        // cam_xyz_coeff: cam_rgb = cam_xyz . xyz_rgb, rows normalised to sum
        // 1, rgb_cam its inverse; out_cam = prophoto_rgb . rgb_cam.
        M3 cam_rgb = multiply(xyz_to_camera, kXyzRgb);
        for (int r = 0; r < 3; ++r) {
            const double sum = cam_rgb[r * 3] + cam_rgb[r * 3 + 1] + cam_rgb[r * 3 + 2];
            for (int c = 0; c < 3; ++c) cam_rgb[r * 3 + c] /= sum;
        }
        to_output = multiply(kProphotoRgb, inverse(cam_rgb));
    }
    // The camera's response to a grey card under the illuminant (Y = 1).
    V3 grey(double kelvin, double tint) const {
        double x, y;
        spkhost::temperature_tint_to_xy(kelvin, tint, x, y);
        return apply(xyz_to_camera, {x / y, 1.0, (1.0 - x - y) / y});
    }
    std::array<float, 4> multipliers(double kelvin, double tint) const {
        std::array<float, 4> mul{};
        std::string error;
        check(spkhost::multipliers_for(xyz_to_camera, kelvin, tint, mul, error), "multipliers: " + error);
        return mul;
    }
    // What the decoder writes for a camera response at these multipliers.
    V3 decode(const V3& camera, const std::array<float, 4>& mul) const {
        return apply(to_output, {camera[0] * mul[0], camera[1] * mul[1], camera[2] * mul[2]});
    }
};

double chroma(const V3& rgb) { return std::max(std::abs(rgb[0] / rgb[1] - 1.0), std::abs(rgb[2] / rgb[1] - 1.0)); }

void rows_and_identity() {
    RenderSettings settings;
    const WhiteBalance initial = white_balance(settings);
    check(initial.as_shot() && initial.temperature == 5500.0 && initial.tint == 0.0,
          "a new photograph is not As Shot at macOS's 5500 K / 0 (Sidecar.swift:22-26)");
    for (const char* key : {"white_balance", "white_balance_temperature", "white_balance_tint"}) {
        const auto* row = find_setting(key);
        check(row && !row->wire && row->layer == SettingLayer::shoot, std::string("white balance row ") + key);
    }
    check(find_setting("white_balance_temperature")->low == 2000.0 &&
          find_setting("white_balance_temperature")->high == 50000.0 &&
          find_setting("white_balance_tint")->low == -150.0 && find_setting("white_balance_tint")->high == 150.0,
          "white balance ranges");
    // The presets are macOS's menu: every mode but Custom, in its order.
    const auto& presets = white_balance_presets();
    check(presets.size() == 6 && std::string(presets[0].id) == "as_shot" && presets[0].kelvin == 0.0 &&
              std::string(presets[1].id) == "daylight" && presets[1].kelvin == 5500.0 &&
              std::string(presets[2].id) == "cloudy" && presets[2].kelvin == 6500.0 &&
              std::string(presets[3].id) == "shade" && presets[3].kelvin == 7500.0 &&
              std::string(presets[4].id) == "tungsten" && presets[4].kelvin == 3200.0 &&
              std::string(presets[5].id) == "fluorescent" && presets[5].kelvin == 4000.0,
          "presets differ from DecodeSettings.WhiteBalance");
    for (const auto& preset : presets)
        check(check_setting(*find_setting("white_balance"), std::string(preset.id)).empty(), "a preset is not a row value");

    // Two settings decode alike when both follow the camera, or both name the
    // same pair -- a preset and Custom at its numbers are one decode.
    RenderSettings stale = settings;
    set_white_balance(stale, {"as_shot", 3100.0, 40.0});
    check(same_decode(settings, stale), "As Shot's ignored numbers made a new decode");
    RenderSettings daylight = settings, custom = settings, warmer = settings;
    set_white_balance(daylight, {"daylight", 5500.0, 0.0});
    set_white_balance(custom, {"custom", 5500.0, 0.0});
    set_white_balance(warmer, {"custom", 5600.0, 0.0});
    check(!same_decode(settings, daylight), "As Shot and a preset decoded alike");
    check(same_decode(daylight, custom), "a preset and Custom at its numbers decoded differently");
    check(!same_decode(custom, warmer), "a temperature change was not a new decode");
    RenderSettings tinted = custom;
    tinted.set("white_balance_tint", 5.0);
    check(!same_decode(custom, tinted), "a tint change was not a new decode");
    // Nothing else is the decode: a film, a paper, a placement or a mask.
    RenderSettings other = settings;
    other.film_stock = "kodak_ektar_100";
    other.set("contrast_mask_active", true);
    other.set("scene_latitude_highlight_pull_back", 1.0);
    check(same_decode(settings, other), "a non-decode setting asked for a decode");
    bool refused = false;
    try { set_white_balance(other, {"candlelight", 1900.0, 0.0}); } catch (const std::invalid_argument&) { refused = true; }
    check(refused, "an unknown white balance mode was accepted");
}

void neutral_picker() {
    const Camera camera;
    // A grey card lit at 3400 K, +12 tint, decoded at the camera's 5200 K.
    const V3 card = camera.grey(3400.0, 12.0);
    const auto shot = camera.multipliers(5200.0, 0.0);
    const V3 off = camera.decode(card, shot);
    check(chroma(off) > 0.2, "the synthetic card is already neutral at the wrong white balance");

    double kelvin = 0, tint = 0;
    std::string error;
    check(neutral_white_balance(camera.xyz_to_camera, camera.to_output, {shot[0], shot[1], shot[2]}, off, kelvin, tint,
                                error), "pick: " + error);
    std::printf("neutral picker: card lit at 3400 K / +12, picked %.3f K / %+.4f\n", kelvin, tint);
    check(std::abs(kelvin - 3400.0) < 1.0 && std::abs(tint - 12.0) < 0.05,
          "the picker did not recover the card's illuminant");
    // Decoded again at the answer, the card is grey.
    const V3 picked = camera.decode(card, camera.multipliers(kelvin, tint));
    std::printf("neutral picker: card chroma %.3g at the camera's white balance, %.3g after the pick\n", chroma(off),
                chroma(picked));
    check(chroma(picked) < 1e-4, "the picked white balance does not neutralise the card");

    // The same through a decode's metadata, the way the controller calls it:
    // the multipliers the decode applied are LibRaw's normalised pre_mul.
    spk::io::RawMetadata metadata;
    metadata.colors = 3;
    metadata.xyz_to_camera = camera.xyz_to_camera;
    M3 rgb_cam = multiply(inverse(kProphotoRgb), camera.to_output);
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) metadata.rgb_cam[r * 4 + c] = float(rgb_cam[r * 3 + c]);
    const float lo = std::min({shot[0], shot[1], shot[2]});
    metadata.post_scale_pre_mul = {shot[0] / lo, shot[1] / lo, shot[2] / lo, shot[1] / lo};
    double k2 = 0, t2 = 0;
    check(neutral_white_balance(metadata, off, k2, t2, error), "pick through metadata: " + error);
    check(std::abs(k2 - kelvin) < 0.5 && std::abs(t2 - tint) < 0.02,
          "the metadata path disagrees with the matrices it holds");
    // The camera's own white balance reads back as the illuminant it was set
    // for: As Shot -> custom at the same numbers is the same picture.
    metadata.camera_whitebalance = {shot[0] * 2.0f, shot[1] * 2.0f, shot[2] * 2.0f, shot[1] * 2.0f};
    double as_shot_k = 0, as_shot_tint = 0;
    check(as_shot_white_balance(metadata, as_shot_k, as_shot_tint) && std::abs(as_shot_k - 5200.0) < 1.0 &&
              std::abs(as_shot_tint) < 0.05, "As Shot does not read back the camera's illuminant");
    metadata.colors = 4;
    check(!as_shot_white_balance(metadata, as_shot_k, as_shot_tint) &&
              !neutral_white_balance(metadata, off, k2, t2, error), "a four-colour camera's white balance was moved");
    // A patch no white balance can neutralise is refused, not guessed.
    const V3 impossible = camera.decode({1.0, -0.2, 1.0}, shot);
    check(!neutral_white_balance(camera.xyz_to_camera, camera.to_output, {shot[0], shot[1], shot[2]}, impossible,
                                 k2, t2, error) && !error.empty(), "a negative camera response was neutralised");
}

void sampler() {
    spk::io::DecodedRaw decoded;
    decoded.width = 10;
    decoded.height = 8;
    decoded.rgb.assign(10 * 8 * 3, 0.25f);
    const auto at = [&](int x, int y) { return decoded.rgb.data() + (std::size_t(y) * 10 + x) * 3; };
    // A 3 x 3 patch around (6, 2): (0.5, 0.4, 0.3).
    for (int y = 1; y <= 3; ++y)
        for (int x = 5; x <= 7; ++x) {
            at(x, y)[0] = 0.5f; at(x, y)[1] = 0.4f; at(x, y)[2] = 0.3f;
        }
    std::array<double, 3> rgb{};
    std::string error;
    // x = 6.5 / 10, y = 2.5 / 8 is the centre of pixel (6, 2).
    check(sample_decoded(decoded, 0.65, 0.3125, 1, rgb, error) && std::abs(rgb[0] - 0.5) < 1e-7 &&
              std::abs(rgb[1] - 0.4) < 1e-7 && std::abs(rgb[2] - 0.3) < 1e-7, "box mean around a point");
    // Clipped at the frame's corner: 2 x 2 of the background.
    check(sample_decoded(decoded, 0.0, 0.0, 1, rgb, error) && std::abs(rgb[1] - 0.25) < 1e-7, "box at the corner");
    at(6, 2)[1] = 1.0f;  // compatible16's clip
    check(!sample_decoded(decoded, 0.65, 0.3125, 1, rgb, error) && !error.empty(), "a clipped sample was used");
    decoded.metadata.headroom_enabled = true;  // headroom has no ceiling
    check(sample_decoded(decoded, 0.65, 0.3125, 1, rgb, error), "a headroom value above 1 was refused");
    at(1, 7)[2] = 0.75f;
    check(sample_decoded(decoded, 0.15, 0.9375, 0, rgb, error) && std::abs(rgb[2] - 0.75) < 1e-7 &&
              std::abs(rgb[0] - 0.25) < 1e-7, "radius 0 samples the one pixel");
    at(1, 7)[0] = 0.0f;
    check(!sample_decoded(decoded, 0.15, 0.9375, 0, rgb, error), "a black sample was used");
}

// --raw <resources> <RAW>: the same through PreviewHost on a real file. A
// white balance re-decodes (a new negative, decode time spent) and nothing
// else does; As Shot restores the camera's multipliers exactly; and a picked
// point of the decoded frame is grey after the pick's own re-decode.
void raw_file(const std::filesystem::path& resources, const std::filesystem::path& raw) {
    PreviewHost host(resources);
    RenderSettings settings;
    settings.grain_active = false;
    const FramePtr shot = host.open_raw(raw, DecodeMode::compatible16, settings);
    double as_k = 0, as_tint = 0;
    check(as_shot_white_balance(shot->metadata, as_k, as_tint), "the RAW's camera has no white balance matrix");
    std::printf("raw: %ux%u, as shot %.1f K / %+.2f, decode %.0f ms (open %.1f ms)\n", shot->width(),
                shot->height(), as_k, as_tint, shot->timings.decode_ms, shot->decode_timings.open_ms);

    RenderSettings warm = settings;
    set_white_balance(warm, {"custom", 3200.0, 0.0});
    const FramePtr tungsten = host.render(warm);
    check(!tungsten->reprint() && !tungsten->negative_was_cached() && tungsten->timings.decode_ms > 0,
          "a white balance did not re-decode and develop a new negative");
    check(tungsten->metadata.post_scale_pre_mul != shot->metadata.post_scale_pre_mul,
          "the decoder applied the camera's multipliers for 3200 K");
    std::printf("raw: 3200 K re-decode %.0f ms (open incl. header read %.1f ms), render %.0f ms\n",
                tungsten->timings.decode_ms, tungsten->decode_timings.open_ms, tungsten->timings.render_ms);
    RenderSettings brighter = warm;
    brighter.print_exposure = 0.8;
    const FramePtr print = host.render(brighter);
    check(print->reprint() && print->negative_was_cached() && print->timings.decode_ms == 0,
          "a print edit after a white balance re-decoded");
    const FramePtr back = host.render(settings);
    check(back->metadata.post_scale_pre_mul == shot->metadata.post_scale_pre_mul && back->timings.decode_ms > 0,
          "As Shot did not restore the camera's multipliers");

    // Pick the frame's middle and decode at the answer: the patch is grey.
    std::array<double, 3> before{}, after{};
    std::string error;
    check(sample_decoded(host.input(), 0.5, 0.5, 4, before, error), "sample: " + error);
    double k = 0, t = 0;
    check(neutral_white_balance(back->metadata, before, k, t, error), "pick: " + error);
    RenderSettings picked = settings;
    set_white_balance(picked, {"custom", std::clamp(k, 2000.0, 50000.0), std::clamp(t, -150.0, 150.0)});
    const FramePtr neutral = host.render(picked);
    check(sample_decoded(host.input(), 0.5, 0.5, 4, after, error), "sample after: " + error);
    const auto chroma_of = [](const std::array<double, 3>& v) {
        return std::max(std::abs(v[0] / v[1] - 1.0), std::abs(v[2] / v[1] - 1.0));
    };
    std::printf("raw: picked %.1f K / %+.2f at the centre; its chroma %.4f before, %.4f after\n", k, t,
                chroma_of(before), chroma_of(after));
    check(chroma_of(after) < 0.01 && (chroma_of(before) < 0.02 || chroma_of(after) < chroma_of(before)),
          "the picked white balance did not neutralise the picked point");
    (void)neutral;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        rows_and_identity();
        neutral_picker();
        sampler();
        if (argc == 4 && std::string(argv[1]) == "--raw")
            raw_file(std::filesystem::path(reinterpret_cast<const char8_t*>(argv[2])),
                     std::filesystem::path(reinterpret_cast<const char8_t*>(argv[3])));
        else if (argc != 1)
            throw std::runtime_error("usage: spk_desktop_white_balance_test [--raw <resources> <RAW>]");
        std::printf("desktop white balance: %d checks passed\n", checks);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "desktop white balance FAILED after %d checks: %s\n", checks, error.what());
        return 1;
    }
}
