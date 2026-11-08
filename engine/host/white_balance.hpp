// white_balance.hpp -- Temperature/Tint for RAW decode (PROTOCOL-REQUESTS R2).
//
// Kelvin and tint use the Adobe DNG SDK's definition (dng_temperature):
// Robertson's isotemperature lines in CIE 1960 uv, tint = -3000 x the signed
// distance from the Planckian locus along them (positive is magenta). That
// is the scale Lightroom, ACR and -- to the extent it is documented -- Core
// Image's CIRAWFilter use, so a value means roughly what it means on macOS.
//
// The camera side is LibRaw's own XYZ->camera matrix (`cam_xyz`, the
// DNG/Adobe ColorMatrix for D65), applied to the illuminant's XYZ: the
// neutral's camera response, whose reciprocal is the multiplier set. One
// matrix, not the DNG SDK's interpolation between two calibration
// illuminants, so far from D65 the mapping is an approximation; As Shot is
// computed the same way in reverse, which keeps "As Shot" -> custom with the
// same numbers a no-op (checked by host_smoke.py).
#pragma once

#include <array>
#include <string>

class LibRaw;

namespace spkhost {

void temperature_tint_to_xy(double temperature_k, double tint, double& x, double& y);
void xy_to_temperature_tint(double x, double y, double& temperature_k, double& tint);

// From an opened LibRaw: the as-shot illuminant, and multipliers for another.
bool as_shot_temperature_tint(const LibRaw& raw, double& temperature_k, double& tint);
bool multipliers_for(const LibRaw& raw, double temperature_k, double tint, std::array<float, 4>& mul,
                     std::string& error);

}  // namespace spkhost
