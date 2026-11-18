// spkraw-host -- the Mac app's optional RAW decoder: LibRaw in a process of its own.
//
// One process per request, in the shape of the library helper (vendor/spklib): the app runs
// `Contents/Helpers/spkraw-host <command> ...`, reads one JSON object from stdout and the exit
// status, and for a decode reads the pixels from the file it named. Nothing is kept between runs,
// so LibRaw's memory goes back to the system with the process and a crash on a damaged file is an
// error reply in the app (exit status != 0), not a crash of the app. The protocol is
// engine/raw-helper/README.md; build-mac.sh builds it.
//
// The decode is the Windows/Linux line's (engine/src/io/raw_decoder.cpp, `compatible16` unless
// asked for `headroom`) and the white balance its host's (engine/host/white_balance.cpp): the
// same pinned LibRaw, the same numbers, on every platform that offers LibRaw.
//
//   spkraw-host version
//   spkraw-host probe   <raw>
//   spkraw-host decode  <raw> <out.f32> [--mode compatible16|headroom] [--temperature K --tint T]
//                                       [--rgba] [--scale s]
//   spkraw-host neutral            (a JSON object on stdin: the decode's `calibration` + "rgb")
//
// A decode writes width x height x 3 float32 (native byte order: the helper runs on the machine
// that reads it), packed, top row first, orientation applied, linear ProPhoto RGB (ROMM, D50) --
// exactly what the engine's linear input takes. `compatible16` is in [0, 1] (times `--scale`).
// `--rgba` adds an alpha of 1 to every pixel: Core Image's RGBAf, which the app maps as it is.
#include "io/raw_camera.hpp"
#include "io/raw_decoder.hpp"
#include "white_balance.hpp"
#include "core/json.hpp"

#include <libraw/libraw.h>

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <unistd.h>

namespace {

using spk::Json;
constexpr int kProtocol = 1;

Json num(double v) { return Json(std::isfinite(v) ? v : 0.0); }
Json str(const std::string& s) { return Json(s); }
template <class Seq> Json array_of(const Seq& seq) {
    Json a = Json::array();
    for (auto v : seq) a.push(num(double(v)));
    return a;
}
std::string trimmed(const char* s, size_t n) {
    std::string out(s, strnlen(s, n));
    while (!out.empty() && out.back() == ' ') out.pop_back();
    return out;
}

int reply(const Json& j, int status = 0) {
    std::cout << j.dump() << "\n";
    std::cout.flush();
    return status;
}
int fail(const std::string& code, const std::string& message) {
    Json j = Json::object();
    j.set("ok", Json(false));
    j.set("error", str(code));
    j.set("message", str(message));
    return reply(j, 2);
}

// LibRaw's flip: 0 none, 3 180 degrees, 5 90 counter-clockwise, 6 90 clockwise.
int exif_orientation(int flip) {
    switch (flip) { case 3: return 3; case 5: return 8; case 6: return 6; default: return 1; }
}

Json camera_json(const LibRaw& raw) {
    const auto& id = raw.imgdata.idata;
    const auto& other = raw.imgdata.other;
    Json j = Json::object();
    j.set("make", str(trimmed(id.make, sizeof id.make)));
    j.set("model", str(trimmed(id.model, sizeof id.model)));
    std::string lens = trimmed(raw.imgdata.lens.Lens, sizeof raw.imgdata.lens.Lens);
    if (lens.empty()) lens = trimmed(raw.imgdata.lens.makernotes.Lens, sizeof raw.imgdata.lens.makernotes.Lens);
    j.set("lens", str(lens));
    j.set("iso", num(other.iso_speed));
    j.set("shutter_s", num(other.shutter));
    j.set("aperture", num(other.aperture));
    j.set("focal_mm", num(other.focal_len));
    j.set("colors", num(id.colors));
    j.set("orientation", num(exif_orientation(raw.imgdata.sizes.flip)));
    double t = 0, tint = 0;
    if (spkhost::as_shot_temperature_tint(raw, t, tint)) {
        Json wb = Json::object();
        wb.set("temperature", num(t));
        wb.set("tint", num(tint));
        j.set("as_shot", wb);
    }
    return j;
}

int cmd_version() {
    Json j = Json::object();
    j.set("ok", Json(true));
    j.set("protocol", num(kProtocol));
    j.set("libraw", str(LibRaw::version()));
    j.set("cameras", num(LibRaw::cameraCount()));
    return reply(j);
}

int cmd_probe(const char* path) {
    auto raw = std::make_unique<spk::io::detail::CameraLibRaw>();
    const int status = raw->open_file(path);
    if (status != LIBRAW_SUCCESS) return fail("unsupported", std::string("RAW open: ") + LibRaw::strerror(status));
    std::uint32_t w = raw->imgdata.sizes.width, h = raw->imgdata.sizes.height;
    if (raw->imgdata.sizes.flip == 5 || raw->imgdata.sizes.flip == 6) std::swap(w, h);
    Json j = Json::object();
    j.set("ok", Json(true));
    j.set("width", num(w));
    j.set("height", num(h));
    j.set("camera", camera_json(*raw));
    const auto& s = raw->imgdata.sizes;
    Json sizes = Json::object();
    sizes.set("raw", array_of(std::array<double, 2>{double(s.raw_width), double(s.raw_height)}));
    sizes.set("visible", array_of(std::array<double, 2>{double(s.width), double(s.height)}));
    sizes.set("margins", array_of(std::array<double, 2>{double(s.left_margin), double(s.top_margin)}));
    Json crops = Json::array();
    for (const auto& c : s.raw_inset_crops)
        crops.push(array_of(std::array<double, 4>{double(c.cleft), double(c.ctop), double(c.cwidth), double(c.cheight)}));
    sizes.set("inset_crops", crops);
    j.set("sizes", sizes);
    return reply(j);
}

int cmd_decode(int argc, char** argv) {
    if (argc < 4) return fail("bad_request", "decode <raw> <out.f32> [--mode m] [--temperature K --tint T]");
    const char* path = argv[2];
    const char* out_path = argv[3];
    std::string mode = "compatible16";
    std::optional<double> temperature;
    double tint = 0.0, scale = 1.0;
    bool rgba = false, camera_crop = false;
    for (int i = 4; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--rgba") { rgba = true; continue; }
        if (a == "--crop") {
            if (i + 1 >= argc || std::strcmp(argv[i + 1], "camera") != 0) return fail("bad_request", "--crop takes camera");
            camera_crop = true; ++i; continue;
        }
        if (i + 1 >= argc) return fail("bad_request", "missing value after " + a);
        const char* v = argv[++i];
        char* end = nullptr;
        if (a == "--mode") mode = v;
        else if (a == "--temperature") { temperature = std::strtod(v, &end); if (*end) return fail("bad_request", "bad --temperature"); }
        else if (a == "--tint") { tint = std::strtod(v, &end); if (*end) return fail("bad_request", "bad --tint"); }
        else if (a == "--scale") {
            scale = std::strtod(v, &end);
            if (*end || !std::isfinite(scale) || scale <= 0) return fail("bad_request", "bad --scale");
        }
        else return fail("bad_request", "unknown option " + a);
    }
    if (mode != "compatible16" && mode != "headroom") return fail("bad_request", "--mode must be compatible16 or headroom");

    // The camera facts, from an open without an unpack (cheap), for the reply.
    auto meta = std::make_unique<spk::io::detail::CameraLibRaw>();
    int status = meta->open_file(path);
    if (status != LIBRAW_SUCCESS) return fail("unsupported", std::string("RAW open: ") + LibRaw::strerror(status));
    std::array<float, 4> mul{};
    if (temperature) {
        std::string error;
        if (!std::isfinite(*temperature) || !std::isfinite(tint) ||
            !spkhost::multipliers_for(*meta, *temperature, tint, mul, error))
            return fail("unsupported", error.empty() ? "invalid white balance" : error);
    }
    Json camera = camera_json(*meta);
    const libraw_image_sizes_t sizes = meta->imgdata.sizes;
    meta.reset();

    spk::io::DecodedRaw decoded;
    std::string error;
    const bool ok = mode == "headroom"
        ? spk::io::decode_raw_headroom(path, temperature ? &mul : nullptr, decoded, error)
        : spk::io::decode_raw_compatible(path, temperature ? &mul : nullptr, decoded, error);
    if (!ok) return fail("decode_failed", error);

    // The camera's own crop (`--crop camera`): LibRaw's first inset crop (a DNG's DefaultCrop, the maker's recommended
    // area), which is the frame other decoders show -- Core Image's among them -- without the few rows and columns
    // round the edge of the sensor's visible area. Its rectangle is in the unturned sensor's coordinates (margins
    // included), and the output is turned by `flip` as dcraw turns it: bit 4 swaps rows and columns, then bit 2
    // reverses the source's rows and bit 1 its columns. A frame whose output is not the visible area turned (a
    // non-square pixel's resize) or whose crop is not inside it is left whole, and the reply says so.
    Json crop_reply = Json::object();
    crop_reply.set("applied", Json(false));
    if (camera_crop) {
        const auto& c = sizes.raw_inset_crops[0];
        const long W = sizes.width, H = sizes.height;
        const long x0 = long(c.cleft) - sizes.left_margin, y0 = long(c.ctop) - sizes.top_margin;
        const long cw = c.cwidth, ch = c.cheight;
        const int flip = sizes.flip;
        const bool turned = flip & 4;
        const long ow = turned ? H : W, oh = turned ? W : H;
        const bool fits = c.cleft != 0xFFFF && cw > 0 && ch > 0 && x0 >= 0 && y0 >= 0 && x0 + cw <= W && y0 + ch <= H;
        if (fits && long(decoded.width) == ow && long(decoded.height) == oh) {
            // The source rectangle's rows (y) and columns (x), each reversed where `flip` reverses it.
            const long sy = (flip & 2) ? H - y0 - ch : y0, sx = (flip & 1) ? W - x0 - cw : x0;
            const long left = turned ? sy : sx, top = turned ? sx : sy;
            const long nw = turned ? ch : cw, nh = turned ? cw : ch;
            std::vector<float> cropped(size_t(nw) * size_t(nh) * 3);
            for (long r = 0; r < nh; ++r)
                std::memcpy(&cropped[size_t(r) * nw * 3], &decoded.rgb[(size_t(top + r) * ow + left) * 3], size_t(nw) * 3 * sizeof(float));
            decoded.rgb.swap(cropped);
            decoded.width = std::uint32_t(nw);
            decoded.height = std::uint32_t(nh);
            crop_reply.set("applied", Json(true));
            crop_reply.set("rect", array_of(std::array<double, 4>{double(left), double(top), double(nw), double(nh)}));
        }
    }

    // The layout the app asked for, in place: RGBA needs one more float a pixel, filled from the end.
    std::vector<float>& rgb = decoded.rgb;
    if (rgba) {
        const size_t pixels = rgb.size() / 3;
        rgb.resize(pixels * 4);
        for (size_t p = pixels; p-- > 0;) {
            rgb[p * 4 + 3] = 1.0f;
            rgb[p * 4 + 2] = float(rgb[p * 3 + 2] * scale);
            rgb[p * 4 + 1] = float(rgb[p * 3 + 1] * scale);
            rgb[p * 4 + 0] = float(rgb[p * 3 + 0] * scale);
        }
    } else if (scale != 1.0) {
        for (float& v : rgb) v = float(v * scale);
    }

    // A file the app named and has not created: never write through someone else's file.
    const int fd = ::open(out_path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return fail("io", std::string("cannot create the output: ") + std::strerror(errno));
    const char* bytes = reinterpret_cast<const char*>(rgb.data());
    size_t left = rgb.size() * sizeof(float);
    while (left > 0) {
        const ssize_t n = ::write(fd, bytes, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ::close(fd); ::unlink(out_path); return fail("io", std::string("write: ") + std::strerror(errno)); }
        bytes += n; left -= size_t(n);
    }
    if (::close(fd) != 0) { ::unlink(out_path); return fail("io", "close failed"); }

    const auto& m = decoded.metadata;
    Json calibration = Json::object();   // what `neutral` needs back
    calibration.set("colour_channels", num(m.colour_channels));
    calibration.set("camera_to_output", array_of(m.camera_to_output));
    calibration.set("camera_from_xyz", array_of(m.camera_from_xyz));
    calibration.set("post_scale_pre_mul", array_of(m.post_scale_pre_mul));
    calibration.set("white_balance_exposure_restore", num(m.white_balance_exposure_restore));
    Json timings = Json::object();
    timings.set("total_ms", num(decoded.timings.total_ms));
    timings.set("unpack_ms", num(decoded.timings.unpack_ms));
    timings.set("process_ms", num(decoded.timings.process_ms));

    Json j = Json::object();
    j.set("ok", Json(true));
    j.set("width", num(decoded.width));
    j.set("height", num(decoded.height));
    j.set("mode", str(mode));
    j.set("channels", num(rgba ? 4 : 3));
    j.set("crop", crop_reply);
    j.set("scale", num(scale));
    j.set("libraw", str(m.libraw_version));
    j.set("decoder", str(m.decoder_name));
    j.set("camera", camera);
    j.set("white_level", num(m.white_level));
    j.set("black_level", num(m.black));
    j.set("calibration", calibration);
    j.set("timings", timings);
    return reply(j);
}

bool fill(const Json& a, float* out, size_t n) {
    if (!a.is_array() || a.items().size() != n) return false;
    for (size_t i = 0; i < n; ++i) {
        if (!a.items()[i].is_number()) return false;
        out[i] = float(a.items()[i].as_double());
    }
    return true;
}

int cmd_neutral() {
    std::stringstream ss;
    ss << std::cin.rdbuf();
    Json in;
    std::string error;
    if (!Json::parse(ss.str(), in, error)) return fail("bad_request", "stdin is not JSON: " + error);
    const Json& c = in.at("calibration");
    spk::io::RawMetadata m;
    float rgbf[3];
    m.colour_channels = c.at("colour_channels").as_int();
    m.white_balance_exposure_restore = c.at("white_balance_exposure_restore").as_double(1.0);
    if (!fill(c.at("camera_to_output"), m.camera_to_output.data(), 12) ||
        !fill(c.at("camera_from_xyz"), m.camera_from_xyz.data(), 9) ||
        !fill(c.at("post_scale_pre_mul"), m.post_scale_pre_mul.data(), 4) ||
        !fill(in.at("rgb"), rgbf, 3))
        return fail("bad_request", "neutral wants {calibration: <a decode's>, rgb: [r, g, b]}");
    const std::array<double, 3> rgb{rgbf[0], rgbf[1], rgbf[2]};
    double t = 0, g = 0;
    if (!spkhost::neutral_temperature_tint(m, rgb, t, g, error)) return fail("unsupported", error);
    Json j = Json::object();
    j.set("ok", Json(true));
    j.set("temperature", num(t));
    j.set("tint", num(g));
    return reply(j);
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const std::string cmd = argc > 1 ? argv[1] : "";
        if (cmd == "version") return cmd_version();
        if (cmd == "probe" && argc == 3) return cmd_probe(argv[2]);
        if (cmd == "decode") return cmd_decode(argc, argv);
        if (cmd == "neutral") return cmd_neutral();
        return fail("bad_request", "usage: spkraw-host version | probe <raw> | decode <raw> <out.f32> [...] | neutral");
    } catch (const std::exception& e) {
        return fail("internal", e.what());
    } catch (...) {
        return fail("internal", "unknown exception");
    }
}
