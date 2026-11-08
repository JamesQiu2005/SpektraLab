#include "white_balance.hpp"

#include <algorithm>
#include <cmath>

#include <libraw/libraw.h>

namespace spkhost {
namespace {

struct Ruvt { double r, u, v, t; };
// Robertson (1968), as tabulated in the DNG SDK: mired, u, v, isotherm slope.
constexpr Ruvt kTable[31] = {
    {0, 0.18006, 0.26352, -0.24341},   {10, 0.18066, 0.26589, -0.25479},
    {20, 0.18133, 0.26846, -0.26876},  {30, 0.18208, 0.27119, -0.28539},
    {40, 0.18293, 0.27407, -0.30470},  {50, 0.18388, 0.27709, -0.32675},
    {60, 0.18494, 0.28021, -0.35156},  {70, 0.18611, 0.28342, -0.37915},
    {80, 0.18740, 0.28668, -0.40955},  {90, 0.18880, 0.28997, -0.44278},
    {100, 0.19032, 0.29326, -0.47888}, {125, 0.19462, 0.30141, -0.58204},
    {150, 0.19962, 0.30921, -0.70471}, {175, 0.20525, 0.31647, -0.84901},
    {200, 0.21142, 0.32312, -1.0182},  {225, 0.21807, 0.32909, -1.2168},
    {250, 0.22511, 0.33439, -1.4512},  {275, 0.23247, 0.33904, -1.7298},
    {300, 0.24010, 0.34308, -2.0637},  {325, 0.24702, 0.34655, -2.4681},
    {350, 0.25591, 0.34951, -2.9641},  {375, 0.26400, 0.35200, -3.5814},
    {400, 0.27218, 0.35407, -4.3633},  {425, 0.28039, 0.35577, -5.3762},
    {450, 0.28863, 0.35714, -6.7262},  {475, 0.29685, 0.35823, -8.5955},
    {500, 0.30505, 0.35907, -11.324},  {525, 0.31320, 0.35968, -15.628},
    {550, 0.32129, 0.36011, -23.325},  {575, 0.32931, 0.36038, -40.770},
    {600, 0.33724, 0.36051, -116.45},
};
constexpr double kTintScale = -3000.0;

bool invert3(const double m[9], double out[9]) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (!std::isfinite(det) || std::fabs(det) < 1e-12) return false;
    const double r[9] = {(e * i - f * h), (c * h - b * i), (b * f - c * e),
                         (f * g - d * i), (a * i - c * g), (c * d - a * f),
                         (d * h - e * g), (b * g - a * h), (a * e - b * d)};
    for (int k = 0; k < 9; ++k) out[k] = r[k] / det;
    return true;
}

bool camera_matrix(const LibRaw& raw, double m[9]) {
    if (raw.imgdata.idata.colors != 3) return false;
    double sum = 0;
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) {
            m[r * 3 + c] = raw.imgdata.color.cam_xyz[r][c];
            sum += std::fabs(m[r * 3 + c]);
        }
    return sum > 0 && std::isfinite(sum);
}

}  // namespace

void temperature_tint_to_xy(double temperature, double tint, double& x, double& y) {
    const double r = 1.0e6 / std::clamp(temperature, 1700.0, 50000.0);
    const double offset = tint * (1.0 / kTintScale);
    for (int i = 0; i < 30; ++i) {
        if (r < kTable[i + 1].r || i == 29) {
            const double f = (kTable[i + 1].r - r) / (kTable[i + 1].r - kTable[i].r);
            double u = kTable[i].u * f + kTable[i + 1].u * (1.0 - f);
            double v = kTable[i].v * f + kTable[i + 1].v * (1.0 - f);
            double uu1 = 1.0, vv1 = kTable[i].t, uu2 = 1.0, vv2 = kTable[i + 1].t;
            const double len1 = std::sqrt(1.0 + vv1 * vv1), len2 = std::sqrt(1.0 + vv2 * vv2);
            uu1 /= len1; vv1 /= len1; uu2 /= len2; vv2 /= len2;
            double uu3 = uu1 * f + uu2 * (1.0 - f), vv3 = vv1 * f + vv2 * (1.0 - f);
            const double len3 = std::sqrt(uu3 * uu3 + vv3 * vv3);
            uu3 /= len3; vv3 /= len3;
            u += uu3 * offset;
            v += vv3 * offset;
            x = 1.5 * u / (u - 4.0 * v + 2.0);
            y = v / (u - 4.0 * v + 2.0);
            return;
        }
    }
}

void xy_to_temperature_tint(double x, double y, double& temperature, double& tint) {
    const double u = 2.0 * x / (1.5 - x + 6.0 * y);
    const double v = 3.0 * y / (1.5 - x + 6.0 * y);
    double last_dt = 0, last_du = 0, last_dv = 0;
    temperature = 0;
    tint = 0;
    for (int i = 1; i <= 30; ++i) {
        double du = 1.0, dv = kTable[i].t;
        const double len = std::sqrt(1.0 + dv * dv);
        du /= len; dv /= len;
        double uu = u - kTable[i].u, vv = v - kTable[i].v;
        double dt = -uu * dv + vv * du;
        if (dt <= 0.0 || i == 30) {
            if (dt > 0.0) dt = 0.0;
            dt = -dt;
            const double f = i == 1 ? 0.0 : dt / (last_dt + dt);
            temperature = 1.0e6 / (kTable[i - 1].r * f + kTable[i].r * (1.0 - f));
            uu = u - (kTable[i - 1].u * f + kTable[i].u * (1.0 - f));
            vv = v - (kTable[i - 1].v * f + kTable[i].v * (1.0 - f));
            du = du * (1.0 - f) + last_du * f;
            dv = dv * (1.0 - f) + last_dv * f;
            const double l2 = std::sqrt(du * du + dv * dv);
            du /= l2; dv /= l2;
            tint = (uu * du + vv * dv) * kTintScale;
            return;
        }
        last_dt = dt; last_du = du; last_dv = dv;
    }
}

bool as_shot_temperature_tint(const LibRaw& raw, double& temperature, double& tint) {
    double m[9], inv[9];
    if (!camera_matrix(raw, m) || !invert3(m, inv)) return false;
    const float* mul = raw.imgdata.color.cam_mul;
    if (!(mul[0] > 0 && mul[1] > 0 && mul[2] > 0)) return false;
    const double neutral[3] = {1.0 / mul[0], 1.0 / mul[1], 1.0 / mul[2]};
    double xyz[3];
    for (int r = 0; r < 3; ++r) xyz[r] = inv[r * 3] * neutral[0] + inv[r * 3 + 1] * neutral[1] + inv[r * 3 + 2] * neutral[2];
    const double s = xyz[0] + xyz[1] + xyz[2];
    if (!(s > 0)) return false;
    xy_to_temperature_tint(xyz[0] / s, xyz[1] / s, temperature, tint);
    return std::isfinite(temperature) && std::isfinite(tint);
}

bool multipliers_for(const LibRaw& raw, double temperature, double tint, std::array<float, 4>& mul,
                     std::string& error) {
    double m[9];
    if (!camera_matrix(raw, m)) {
        error = "this camera has no three-colour XYZ matrix in LibRaw; white balance cannot be set";
        return false;
    }
    double x, y;
    temperature_tint_to_xy(temperature, tint, x, y);
    const double xyz[3] = {x / y, 1.0, (1.0 - x - y) / y};
    double n[3];
    for (int r = 0; r < 3; ++r) n[r] = m[r * 3] * xyz[0] + m[r * 3 + 1] * xyz[1] + m[r * 3 + 2] * xyz[2];
    if (!(n[0] > 0 && n[1] > 0 && n[2] > 0)) {
        error = "white balance outside what this camera can neutralise";
        return false;
    }
    mul = {float(n[1] / n[0]), 1.0f, float(n[1] / n[2]), 1.0f};
    return true;
}

}  // namespace spkhost
