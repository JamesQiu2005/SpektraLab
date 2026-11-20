// lens_correct.hpp -- lens correction at decode, from lensfun's database (Linux).
//
// The Mac decodes through Core Image, which reads the maker's own correction
// data; LibRaw has none. lensfun (LGPL-3, its database CC BY-SA 3.0) is a local
// library and a folder of XML files: no network. A photo taken through a manual
// lens records no lens at all, so the lens is the user's choice (`LensChoice`);
// without one, the EXIF lens is looked up.
#pragma once
#include <string>
#include <vector>

#include "image_io.hpp"

namespace spkhost {

// A lens the database does not have (a user's own lens): its maker's name
// is the user's, its numbers set by eye. Each is lensfun's own model, so it is
// corrected exactly as a profile is:
//   distortion  POLY3 k1, r_d = r_u (1 - k1 + k1 r_u^2): < 0 barrel, > 0 pincushion;
//   vignetting  PA k1, the corners' light over the centre's 1 + k1 r^2: < 0 dark corners;
//   tca_r/tca_b LINEAR, red's / blue's magnification against green, 1 = none.
struct CustomLens {
    double distortion = 0, vignetting = 0, tca_r = 1, tca_b = 1;
};

struct LensChoice {
    bool custom = false;        // the numbers below, not the database
    CustomLens numbers;
    std::string maker, model;   // empty: the EXIF lens (a custom lens: its name)
    double focal_mm = 0;        // 0: the EXIF focal length, or a prime's own
    double aperture = 0;        // 0: the EXIF f-number; none: no vignetting correction
    double distance_m = 10;     // focus distance: vignetting only, weakly
};

struct LensEntry {
    std::string maker, model;
    double min_focal = 0, max_focal = 0, min_aperture = 0;
    std::vector<std::string> mounts;
    bool distortion = false, tca = false, vignetting = false;
};

struct LensApplied {
    std::string maker, model;
    double focal_mm = 0, aperture = 0, crop_factor = 1;
    bool distortion = false, tca = false, vignetting = false;
};

// Whether this build has lensfun.
bool lens_correction_available();

// Every lens in the database, sorted by maker then model; `crop_factor` is the
// camera's (1 when the camera is not in the database).
bool lens_list(const std::string& cam_make, const std::string& cam_model, std::vector<LensEntry>& out,
               double& crop_factor, bool& camera_known, std::string& error);

// Corrects `img` (linear RGB, row-major, orientation applied) in place:
// vignetting, then distortion and lateral CA in one resample, scaled so no
// empty corner shows. `exif_*` stand in for what the choice leaves at 0.
bool lens_correct(FloatImage& img, const std::string& cam_make, const std::string& cam_model,
                  const LensChoice& choice, const std::string& exif_lens, double exif_focal,
                  double exif_aperture, LensApplied& applied, std::string& error);

}  // namespace spkhost
