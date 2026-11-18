#pragma once
#include <libraw/libraw.h>

namespace spk::io::detail {
// The one LibRaw subclass every decode path starts from.
//
// Until 2026-11-17 this also overrode adobe_coeff() to lend the Fujifilm
// GFX100RF the GFX 100 II matrix and the X-E5 the X-H2 one, because LibRaw
// 0.22.2 had neither body. The pinned master snapshot carries both entries
// with exactly those coefficients (colordata.cpp "GFX 100RF", "X-E5") and
// normalises "GFX100RF" to "GFX 100RF" itself; the override was removed with
// the pixel comparison in RAW-SUPPORT-20261117.md (GFX100RF: bit-identical
// compatible16 and headroom frames). tests/raw_camera.cpp now holds the
// upstream table to those values, so a pin that loses them fails there.
class CameraLibRaw : public LibRaw {
public:
    CameraLibRaw() : LibRaw(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK) {}
};
} // namespace spk::io::detail
