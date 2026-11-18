// lens_correct.cpp -- see lens_correct.hpp.
#include "lens_correct.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <thread>

#ifdef SPK_HAVE_LENSFUN
#include <lensfun.h>
#endif

namespace spkhost {

#ifndef SPK_HAVE_LENSFUN

bool lens_correction_available() { return false; }
bool lens_list(const std::string&, const std::string&, std::vector<LensEntry>&, double&, bool&, std::string& error) {
    error = "this build has no lens database (lensfun)";
    return false;
}
bool lens_correct(FloatImage&, const std::string&, const std::string&, const LensChoice&, const std::string&, double,
                  double, LensApplied&, std::string& error) {
    error = "this build has no lens database (lensfun)";
    return false;
}

#else

namespace {

// The database, loaded once and kept: about 1,300 lenses from /usr/share/lensfun.
std::mutex& db_lock() {
    static std::mutex m;
    return m;
}
lfDatabase* database(std::string& error) {
    static lfDatabase* db = nullptr;
    static bool tried = false;
    if (!tried) {
        tried = true;
        auto* d = new lfDatabase();
        // A snap carries its own database (core26's /usr/share has none); SPEKTRALAB_LENSFUN_DIR overrides.
        std::string dir;
        if (const char* env = std::getenv("SPEKTRALAB_LENSFUN_DIR"); env && *env) dir = env;
        else if (const char* snap = std::getenv("SNAP"); snap && *snap) dir = std::string(snap) + "/usr/share/lensfun/version_1";
        const bool ok = !dir.empty() ? d->LoadDirectory(dir.c_str()) : d->Load() == LF_NO_ERROR;
        if (!ok) {
            delete d;
        } else {
            db = d;
        }
    }
    if (!db) error = "the lens database (lensfun) could not be read";
    return db;
}

std::string ml(const lfMLstr s) {
    const char* v = s ? lf_mlstr_get(s) : nullptr;
    return v ? v : "";
}

const lfCamera* find_camera(lfDatabase* db, const std::string& make, const std::string& model) {
    if (make.empty() && model.empty()) return nullptr;
    const lfCamera** cams = db->FindCamerasExt(make.empty() ? nullptr : make.c_str(),
                                               model.empty() ? nullptr : model.c_str(), 0);
    const lfCamera* cam = cams ? cams[0] : nullptr;
    lf_free(cams);
    return cam;
}

// Bilinear, edges clamped (with automatic scaling no sample falls outside).
inline float sample(const FloatImage& img, int c, float x, float y) {
    const int W = int(img.width), H = int(img.height);
    x = std::clamp(x, 0.0f, float(W - 1));
    y = std::clamp(y, 0.0f, float(H - 1));
    const int x0 = int(x), y0 = int(y);
    const int x1 = std::min(x0 + 1, W - 1), y1 = std::min(y0 + 1, H - 1);
    const float fx = x - float(x0), fy = y - float(y0);
    const float* p = img.rgb.data();
    const float a = p[3 * (size_t(y0) * W + x0) + c], b = p[3 * (size_t(y0) * W + x1) + c];
    const float d = p[3 * (size_t(y1) * W + x0) + c], e = p[3 * (size_t(y1) * W + x1) + c];
    return (1 - fy) * ((1 - fx) * a + fx * b) + fy * ((1 - fx) * d + fx * e);
}

template <typename F>
void rows_parallel(uint32_t H, F&& fn) {
    const unsigned n = std::max(1u, std::min(8u, std::thread::hardware_concurrency()));
    std::vector<std::thread> pool;
    for (unsigned t = 0; t < n; ++t)
        pool.emplace_back([&, t] {
            for (uint32_t y = t; y < H; y += n) fn(y);
        });
    for (auto& th : pool) th.join();
}

}  // namespace

bool lens_correction_available() { return true; }

bool lens_list(const std::string& cam_make, const std::string& cam_model, std::vector<LensEntry>& out,
               double& crop_factor, bool& camera_known, std::string& error) {
    std::lock_guard<std::mutex> lock(db_lock());
    lfDatabase* db = database(error);
    if (!db) return false;
    const lfCamera* cam = find_camera(db, cam_make, cam_model);
    camera_known = cam != nullptr;
    crop_factor = cam && cam->CropFactor > 0 ? cam->CropFactor : 1.0;
    out.clear();
    const lfLens* const* lenses = db->GetLenses();
    for (size_t i = 0; lenses && lenses[i]; ++i) {
        const lfLens* l = lenses[i];
        LensEntry e;
        e.maker = ml(l->Maker);
        e.model = ml(l->Model);
        e.min_focal = l->MinFocal;
        e.max_focal = l->MaxFocal;
        e.min_aperture = l->MinAperture;
        for (char** m = l->Mounts; m && *m; ++m) e.mounts.emplace_back(*m);
        e.distortion = l->CalibDistortion && l->CalibDistortion[0];
        e.tca = l->CalibTCA && l->CalibTCA[0];
        e.vignetting = l->CalibVignetting && l->CalibVignetting[0];
        if (!e.model.empty()) out.push_back(std::move(e));
    }
    std::sort(out.begin(), out.end(), [](const LensEntry& a, const LensEntry& b) {
        return a.maker != b.maker ? a.maker < b.maker : a.model < b.model;
    });
    // The database lists a lens once per calibration set; one row each.
    out.erase(std::unique(out.begin(), out.end(),
                          [](const LensEntry& a, const LensEntry& b) { return a.maker == b.maker && a.model == b.model; }),
              out.end());
    return true;
}

bool lens_correct(FloatImage& img, const std::string& cam_make, const std::string& cam_model,
                  const LensChoice& choice, const std::string& exif_lens, double exif_focal, double exif_aperture,
                  LensApplied& applied, std::string& error) {
    if (img.width < 2 || img.height < 2) { error = "no image to correct"; return false; }
    std::unique_lock<std::mutex> lock(db_lock());
    lfDatabase* db = database(error);
    if (!db) return false;
    const lfCamera* cam = find_camera(db, cam_make, cam_model);
    const float crop = cam && cam->CropFactor > 0 ? cam->CropFactor : 1.0f;

    lfLens custom;
    const lfLens* lens = nullptr;
    double focal = choice.focal_mm > 0 ? choice.focal_mm : exif_focal;
    const double aperture = choice.aperture > 0 ? choice.aperture : exif_aperture;
    if (choice.custom) {
        // "My Lenses": lensfun's own models with the user's numbers, calibrated on this camera.
        if (!(focal > 0)) focal = 50;
        custom.SetMaker(choice.maker.empty() ? "Custom" : choice.maker.c_str());
        custom.SetModel(choice.model.empty() ? "Custom lens" : choice.model.c_str());
        custom.AddMount("Generic");
        custom.MinFocal = custom.MaxFocal = float(focal);
        custom.CropFactor = crop;
        custom.AspectRatio = float(std::max(img.width, img.height)) / float(std::min(img.width, img.height));
        custom.Type = LF_RECTILINEAR;
        if (choice.numbers.distortion != 0) {
            lfLensCalibDistortion d{LF_DIST_MODEL_POLY3, float(focal), {float(choice.numbers.distortion), 0, 0}};
            custom.AddCalibDistortion(&d);
        }
        if (choice.numbers.vignetting != 0) {
            lfLensCalibVignetting v{LF_VIGNETTING_MODEL_PA, float(focal), aperture > 0 ? float(aperture) : 8.0f,
                                    float(choice.distance_m), {float(choice.numbers.vignetting), 0, 0}};
            custom.AddCalibVignetting(&v);
        }
        if (choice.numbers.tca_r != 1 || choice.numbers.tca_b != 1) {
            lfLensCalibTCA t{LF_TCA_MODEL_LINEAR, float(focal), {float(choice.numbers.tca_r), float(choice.numbers.tca_b), 0, 0, 0, 0}};
            custom.AddCalibTCA(&t);
        }
        if (!custom.Check()) { error = "the custom lens's numbers are not usable"; return false; }
        lens = &custom;
    } else {
        const std::string want = choice.model.empty() ? exif_lens : choice.model;
        if (want.empty()) {
            error = "this photo records no lens: choose yours";
            return false;
        }
        const lfLens** found = db->FindLenses(choice.model.empty() ? cam : nullptr,
                                              choice.maker.empty() ? nullptr : choice.maker.c_str(), want.c_str(), 0);
        if (found) {
            // The exact name the picker showed, else lensfun's best match.
            for (size_t i = 0; found[i]; ++i)
                if (ml(found[i]->Model) == want && (choice.maker.empty() || ml(found[i]->Maker) == choice.maker)) {
                    lens = found[i];
                    break;
                }
            if (!lens) lens = found[0];
        }
        lf_free(found);
        if (!lens) {
            error = "no profile for the lens '" + want + "': choose it, or make it in My Lenses";
            return false;
        }
        if (!(focal > 0)) {
            if (lens->MinFocal > 0 && lens->MinFocal == lens->MaxFocal) focal = lens->MinFocal;
            else { error = "set the focal length this photo was taken at"; return false; }
        }
    }

    int flags = LF_MODIFY_DISTORTION | LF_MODIFY_TCA | LF_MODIFY_SCALE;
    // Vignetting depends on the f-number: no f-number, no vignetting correction (a custom lens has its own).
    if (aperture > 0 || choice.custom) flags |= LF_MODIFY_VIGNETTING;
    lfModifier mod(lens, crop, int(img.width), int(img.height));
    const int done = mod.Initialize(lens, LF_PF_F32, float(focal), aperture > 0 ? float(aperture) : 8.0f,
                                    float(choice.distance_m), 0.0f /* automatic: no empty corners */,
                                    lens->Type, flags, false);
    applied = LensApplied{};
    applied.maker = ml(lens->Maker);
    applied.model = ml(lens->Model);
    applied.focal_mm = focal;
    applied.aperture = aperture;
    applied.crop_factor = crop;
    applied.distortion = done & LF_MODIFY_DISTORTION;
    applied.tca = done & LF_MODIFY_TCA;
    applied.vignetting = done & LF_MODIFY_VIGNETTING;
    lock.unlock();   // the modifier is this call's own; the database is not touched again

    const uint32_t W = img.width, H = img.height;
    const int stride = int(W * 3 * sizeof(float));
    // 1. vignetting, on the image as taken
    if (applied.vignetting)
        rows_parallel(H, [&](uint32_t y) {
            mod.ApplyColorModification(img.rgb.data() + size_t(y) * W * 3, 0.0f, float(y), int(W), 1,
                                       LF_CR_3(RED, GREEN, BLUE), stride);
        });
    // 2. distortion, lateral CA and the scale: one resample, a position per channel
    if (done & (LF_MODIFY_DISTORTION | LF_MODIFY_TCA | LF_MODIFY_SCALE)) {
        std::vector<float> out(img.rgb.size());
        rows_parallel(H, [&](uint32_t y) {
            std::vector<float> pos(size_t(W) * 6);
            if (!mod.ApplySubpixelGeometryDistortion(0.0f, float(y), int(W), 1, pos.data())) {
                std::copy_n(img.rgb.data() + size_t(y) * W * 3, size_t(W) * 3, out.data() + size_t(y) * W * 3);
                return;
            }
            float* o = out.data() + size_t(y) * W * 3;
            for (uint32_t x = 0; x < W; ++x)
                for (int c = 0; c < 3; ++c) o[3 * x + c] = sample(img, c, pos[6 * x + 2 * c], pos[6 * x + 2 * c + 1]);
        });
        img.rgb.swap(out);
    }
    return true;
}

#endif  // SPK_HAVE_LENSFUN

}  // namespace spkhost
