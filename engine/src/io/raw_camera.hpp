#pragma once
#include <libraw/libraw.h>
#include <cstring>

namespace spk::io::detail {
// Reuse coefficient lookups for models absent from LibRaw 0.22.2.
// Keep the actual model and all other camera identification intact.
class CameraLibRaw : public LibRaw {
public:
    CameraLibRaw() : LibRaw(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK) {}
protected:
    int adobe_coeff(unsigned make, const char* model, int internal_only = 0) override {
        if (make != LIBRAW_CAMERAMAKER_Fujifilm || !model ||
            imgdata.idata.colors != 3 || imgdata.idata.dng_version)
            return LibRaw::adobe_coeff(make, model, internal_only);

        // RawSpeed's cameras.xml gives both GFX100RF modes the GFX 100 II matrix.
        // https://github.com/darktable-org/rawspeed/blob/develop/data/cameras.xml
        if (!std::strcmp(model, "GFX100RF") || !std::strcmp(model, "GFX 100RF"))
            return LibRaw::adobe_coeff(make, "GFX 100 II", internal_only);
        // LibRaw 202611's X-E5 entry has the same matrix and level overrides as X-H2.
        // https://github.com/LibRaw/LibRaw/blob/a9a14b1970d188c25dade81f8326ff00a6e33649/src/tables/colordata.cpp
        if (!std::strcmp(model, "X-E5"))
            return LibRaw::adobe_coeff(make, "X-H2", internal_only);
        return LibRaw::adobe_coeff(make, model, internal_only);
    }
};
} // namespace spk::io::detail
