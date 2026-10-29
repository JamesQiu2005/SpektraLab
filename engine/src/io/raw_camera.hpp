#pragma once
#include <libraw/libraw.h>
#include <cstring>

namespace spk::io::detail {
// LibRaw 0.22.2 lacks this model. Values verified against RawSpeed's
// data/cameras.xml, FUJIFILM GFX100RF (both compressed and uncompressed):
// https://github.com/darktable-org/rawspeed/blob/develop/data/cameras.xml
// Its XYZ-to-camera matrix is exactly LibRaw's existing GFX 100 II entry.
// Reuse that coefficient lookup only; preserve the actual model, decoder,
// sensor geometry, black/white levels and all normal LibRaw processing.
class CameraLibRaw : public LibRaw {
public:
    CameraLibRaw() : LibRaw(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK) {}
protected:
    int adobe_coeff(unsigned make, const char* model, int internal_only = 0) override {
        if (make != LIBRAW_CAMERAMAKER_Fujifilm || !model ||
            (std::strcmp(model, "GFX100RF") && std::strcmp(model, "GFX 100RF")))
            return LibRaw::adobe_coeff(make, model, internal_only);
        if (imgdata.idata.colors != 3 || imgdata.idata.dng_version)
            return LibRaw::adobe_coeff(make, model, internal_only);
        return LibRaw::adobe_coeff(make, "GFX 100 II", internal_only);
    }
};
} // namespace spk::io::detail
