// The date back (RFC-031 §8) end to end on the Windows Vulkan engine, through
// the exported C ABI only. A synthetic frame is opened with
// `date_imprint_active` and rendered at the full tier; against the same frame
// without the date, the imprint must change pixels, change them only where the
// date is placed, push the print toward red (the back's light exposes the
// red- and green-sensitive layers from behind; the yellow filter stops blue),
// and render the same bits every time. Spatial effects that would carry the
// mark across the frame are off (halation, couplers' diffusion, lens and
// scanner blur, grain, glare); the scanner's unsharp mask stays on, which is
// why the expected box has a millimetre's margin.
//
// The `data` style prints shooting data between frames, on the film's
// rebate. Without overscan there is no rebate, so it prints nothing -- the
// render must equal the undated one -- and a date's `data_text` is dropped
// the same way.
#include "spektrafilm/spk_engine.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool ok, const std::string& what) {
    if (!ok) throw std::runtime_error(what);
}

struct EngineDeleter { void operator()(spk_engine* e) const { spk_engine_destroy(e); } };
struct SessionDeleter { void operator()(spk_session* s) const { spk_session_release(s); } };
using Engine = std::unique_ptr<spk_engine, EngineDeleter>;
using Session = std::unique_ptr<spk_session, SessionDeleter>;

// The fixture's colour setup (tests/fixtures/windows/abi_probe_params.json),
// with the spatial and stochastic effects off.
const char* kBase =
    "\"film_stock\":\"kodak_portra_400\",\"print_stock\":\"kodak_portra_endura\","
    "\"input_color_space\":\"ProPhoto RGB\",\"input_cctf_decoding\":false,"
    "\"output_color_space\":\"ProPhoto RGB\",\"output_cctf_encoding\":true,"
    "\"grain_active\":false,\"glare_active\":false,\"halation_active\":false,"
    "\"dir_couplers_active\":false,\"lens_blur_um\":0,\"scanner_lens_blur\":0,\"auto_exposure\":false";

struct Frame {
    uint32_t w, h;
    std::vector<float> rgb;
};

Frame synthetic(uint32_t w, uint32_t h) {
    Frame f{w, h, std::vector<float>(size_t(w) * h * 3)};
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x) {
            const float u = float(x) / float(w - 1), v = float(y) / float(h - 1);
            float* p = &f.rgb[(size_t(y) * w + x) * 3];
            p[0] = 0.04f + 0.30f * u;                       // a mid-toned gradient, a little warm
            p[1] = 0.05f + 0.22f * (0.5f * u + 0.5f * v);
            p[2] = 0.06f + 0.18f * v;
        }
    return f;
}

std::vector<uint16_t> take(spk_result& r, uint32_t w, uint32_t h) {
    require(r.rgba16 && r.width == w && r.height == h && r.row_stride_px >= w, "render returned the wrong size");
    std::vector<uint16_t> out(size_t(w) * h * 4);
    for (uint32_t y = 0; y < h; ++y)
        std::copy_n(r.rgba16 + size_t(y) * r.row_stride_px * 4, size_t(w) * 4, out.data() + size_t(y) * w * 4);
    spk_result_free(&r);
    return out;
}

std::vector<uint16_t> render(spk_session* s, spk_engine* e, uint32_t w, uint32_t h) {
    spk_result r{};
    const spk_status st = spk_render(s, "full", &r);
    require(st == SPK_OK, std::string("render failed: ") + spk_last_error(e));
    return take(r, w, h);
}

Session open(spk_engine* e, const Frame& f, const std::string& extra) {
    const std::string delta = "{" + std::string(kBase) + extra + "}";
    const spk_image img{f.rgb.data(), f.w, f.h, 3};
    Session s(spk_open(e, &img, delta.c_str(), nullptr));
    require(bool(s), "open refused " + delta + ": " + spk_last_error(e));
    return s;
}

// 8-bit BMP of a render, for looking at; only with an output directory.
void write_bmp(const std::string& path, const std::vector<uint16_t>& px, uint32_t w, uint32_t h) {
    const uint32_t row = (w * 3 + 3) & ~3u, size = 54 + row * h;
    std::vector<unsigned char> b(size, 0);
    auto le32 = [&](size_t o, uint32_t v) { for (int k = 0; k < 4; ++k) b[o + size_t(k)] = (unsigned char)(v >> (8 * k)); };
    b[0] = 'B'; b[1] = 'M'; le32(2, size); le32(10, 54); le32(14, 40); le32(18, w); le32(22, h);
    b[26] = 1; b[28] = 24; le32(34, row * h);
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x)
            for (int c = 0; c < 3; ++c)
                b[54 + size_t(h - 1 - y) * row + x * 3 + size_t(2 - c)] = (unsigned char)(px[(size_t(y) * w + x) * 4 + size_t(c)] >> 8);
    std::ofstream(path, std::ios::binary).write(reinterpret_cast<const char*>(b.data()), std::streamsize(b.size()));
}

struct Box { double x0, y0, x1, y1; };   // mm, picture axes (x right, y down)

struct Case {
    const char* name;
    bool portrait;
    std::string extra;                      // the date's fields
    bool prints;                            // false: must equal the undated render
    Box box;                                // where the date may change pixels (with prints)
};

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) { std::cerr << "usage: spk_date_back <resources> [bmp-dir]\n"; return 2; }
    const std::string dump = argc == 3 ? argv[2] : "";
    try {
        Engine engine(spk_engine_create(argv[1], nullptr));
        require(bool(engine), std::string("engine: ") + spk_last_error(nullptr));
        // The capabilities stop listing the date back and still list overscan.
        const std::string caps = spk_capabilities(engine.get());
        const size_t list = caps.find("\"unsupported_features\"");
        require(list != std::string::npos, "capabilities lost unsupported_features");
        const std::string unported = caps.substr(list, caps.find(']', list) - list);
        require(unported.find("\"date_imprint\"") == std::string::npos, "date_imprint is still advertised as unsupported");
        require(unported.find("\"overscan\"") != std::string::npos, "overscan is no longer advertised as unsupported");

        // The frame is 35 mm long (film_format_mm's default), so 1080 px is
        // 0.0324 mm a pixel and a 1.3 mm LCD digit is 40 px tall. Boxes follow
        // overscan.cpp's placement: in from the gate by inset_x = 3.0 and
        // inset_y = 2.4 mm, the LCD 1.3 mm tall, the dots 0.95, and the
        // text no longer than 12 mm, with a millimetre's margin all round.
        const double fw = 35.0, fh = 35.0 * 720.0 / 1080.0;
        const char* date = ",\"date_imprint_active\":true,\"date_imprint_text\":\"'26 10 16\"";
        const std::vector<Case> cases = {
            {"lcd, bottom right", false, std::string(date) + ",\"date_imprint_style\":\"lcd\"", true,
             {fw - 3.0 - 12.0 - 1.0, fh - 2.4 - 1.3 - 1.0, fw - 3.0 + 1.0, fh - 2.4 + 1.0}},
            {"dots, bottom right", false, std::string(date) + ",\"date_imprint_style\":\"dots\"", true,
             {fw - 3.0 - 12.0 - 1.0, fh - 2.4 - 0.95 - 1.0, fw - 3.0 + 1.0, fh - 2.4 + 1.0}},
            {"lcd, top left", false, std::string(date) + ",\"date_imprint_style\":\"lcd\",\"date_imprint_corner\":\"tl\"", true,
             {3.0 - 1.0, 2.4 - 1.0, 3.0 + 12.0 + 1.0, 2.4 + 1.3 + 1.0}},
            // A portrait full frame was shot with the camera turned: the back
            // turned with it, so the date runs down the picture's left edge,
            // reading along the film (x = across - t, y = s).
            {"lcd, portrait (camera turned)", true, std::string(date) + ",\"date_imprint_style\":\"lcd\"", true,
             {2.4 - 1.0, fw - 3.0 - 12.0 - 1.0, 2.4 + 1.3 + 1.0, fw - 3.0 + 1.0}},
            {"data, on the bare frame", false, std::string(date) + ",\"date_imprint_style\":\"data\"", false, {}},
        };

        const Frame land = synthetic(1080, 720), port = synthetic(720, 1080);
        Session base_land = open(engine.get(), land, "");
        const std::vector<uint16_t> undated_land = render(base_land.get(), engine.get(), 1080, 720);
        Session base_port = open(engine.get(), port, "");
        const std::vector<uint16_t> undated_port = render(base_port.get(), engine.get(), 720, 1080);
        if (!dump.empty()) write_bmp(dump + "/date_back_undated.bmp", undated_land, 1080, 720);

        std::vector<uint16_t> lcd_br;
        for (const Case& c : cases) {
            const Frame& f = c.portrait ? port : land;
            const std::vector<uint16_t>& undated = c.portrait ? undated_port : undated_land;
            // Determinism: a second render of the session and a fresh session.
            Session s = open(engine.get(), f, c.extra);
            const std::vector<uint16_t> first = render(s.get(), engine.get(), f.w, f.h);
            const std::vector<uint16_t> again = render(s.get(), engine.get(), f.w, f.h);
            Session fresh = open(engine.get(), f, c.extra);
            const std::vector<uint16_t> other = render(fresh.get(), engine.get(), f.w, f.h);
            require(first == again && first == other, std::string(c.name) + ": renders differ run to run");
            if (!dump.empty()) {
                std::string file = c.name;
                for (char& ch : file) if (!std::isalnum((unsigned char)ch)) ch = '_';
                write_bmp(dump + "/date_back_" + file + ".bmp", first, f.w, f.h);
            }
            if (!c.prints) {
                require(first == undated, std::string(c.name) + ": printed where there is no rebate");
                std::cout << c.name << ": no rebate, nothing printed (render identical to the undated one)\n";
                continue;
            }
            const double px = 35.0 / 1080.0;
            size_t changed = 0, outside = 0;
            uint32_t bx0 = f.w, by0 = f.h, bx1 = 0, by1 = 0;
            double d_red = 0.0, d_blue = 0.0;
            for (uint32_t y = 0; y < f.h; ++y)
                for (uint32_t x = 0; x < f.w; ++x) {
                    const size_t o = (size_t(y) * f.w + x) * 4;
                    if (first[o] == undated[o] && first[o + 1] == undated[o + 1] && first[o + 2] == undated[o + 2]) continue;
                    ++changed;
                    bx0 = std::min(bx0, x); by0 = std::min(by0, y); bx1 = std::max(bx1, x); by1 = std::max(by1, y);
                    d_red += double(first[o]) - double(undated[o]);
                    d_blue += double(first[o + 2]) - double(undated[o + 2]);
                    const double xm = (x + 0.5) * px, ym = (y + 0.5) * px;
                    if (xm < c.box.x0 || xm > c.box.x1 || ym < c.box.y0 || ym > c.box.y1) ++outside;
                }
            char buf[400];
            std::snprintf(buf, sizeof buf,
                          "%s: %zu pixels changed in x %u..%u, y %u..%u (%.2f..%.2f x %.2f..%.2f mm), %zu outside "
                          "the expected box; mean change red %+.0f, blue %+.0f (of 65535)",
                          c.name, changed, bx0, bx1, by0, by1, bx0 * px, (bx1 + 1) * px, by0 * px, (by1 + 1) * px,
                          outside, changed ? d_red / changed : 0.0, changed ? d_blue / changed : 0.0);
            std::cout << buf << '\n';
            require(changed >= 500, std::string(c.name) + ": the date changed almost nothing");
            require(outside == 0, std::string(c.name) + ": the date changed pixels outside where it is placed");
            require(d_red > 0.0 && d_red > d_blue, std::string(c.name) + ": the date did not print toward red");
            if (std::string(c.name) == "lcd, bottom right") lcd_br = first;
        }
        // The data line is the rebate's too: a date with `data_text` on the
        // bare frame renders exactly as the date alone.
        {
            Session s = open(engine.get(), land, std::string(date) + ",\"date_imprint_style\":\"lcd\","
                                                                     "\"date_imprint_data_text\":\"1/250 f8\"");
            require(render(s.get(), engine.get(), 1080, 720) == lcd_br, "data_text changed a bare frame's date");
        }
        // Switching the date on and off through set_params, as the app does.
        {
            const std::string on = "{" + std::string(date + 1) + ",\"date_imprint_style\":\"lcd\"}";
            // The status first: the message's spk_last_error must follow the call.
            const spk_status st = spk_set_params(base_land.get(), on.c_str(), nullptr);
            require(st == SPK_OK, std::string("set_params refused the date: ") + spk_last_error(engine.get()));
            require(render(base_land.get(), engine.get(), 1080, 720) == lcd_br, "the date via set_params renders differently");
            require(spk_set_params(base_land.get(), "{\"date_imprint_active\":false}", nullptr) == SPK_OK,
                    "could not switch the date off");
            require(render(base_land.get(), engine.get(), 1080, 720) == undated_land, "switching the date off left a mark");
        }
        std::cout << "date back: " << cases.size() << " placements, each deterministic across renders and sessions\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "date back: " << e.what() << '\n';
        return 1;
    }
}
