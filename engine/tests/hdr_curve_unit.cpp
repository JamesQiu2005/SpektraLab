// hdr_curve_unit -- family A (`core/hdr_curves.cpp`) on synthetic media, where the entry point cannot
// reach (PRD/HDR-PORT-PLAN-2026-11-06 D1; engine/build.sh tests builds it; no arguments; exit 1 on a
// failure). `hdr_curve_checks.py` holds the model to the research's model2.py on every real pair; this holds
// the three places a medium unlike any real pair broke it (the 2026-11-06 review):
//
//   1. the knee stays inside its bracket: a medium already under 0.8 gamma0 at the last sample at or
//      below EV 0, with an equal slope on both sides, made model.py's crossing extrapolate without
//      limit (a knee of 1e7 EV here; numpy inf at an exact tie);
//   2. a mid-grey on the white plateau has no gamma: gamma0 1e-7 used to pass the exact `> 0` test and
//      return a curve with a knee read off float noise;
//   3. `top` is log2 H: below H 1.0001 `derive` clamps at log2 1.0001, so such an H is refused rather
//      than reported with a top that is not its own.
#include "hdr_curves.hpp"

#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace {

int failures = 0;
void check(bool ok, const std::string& what) {
    std::printf("%s %s\n", ok ? "  ok   " : "  FAIL ", what.c_str());
    failures += !ok;
}

struct Ramp { std::vector<double> ev, y; };
// 128 samples over -12 ... +12 EV, as `spk_scene_latitude`'s reply carries the medium.
Ramp ramp(const std::function<double(double)>& log2_y) {
    Ramp r;
    for (int i = 0; i < 128; ++i) {
        const double e = -12.0 + 24.0 * double(i) / 127.0;
        r.ev.push_back(e);
        r.y.push_back(std::exp2(log2_y(e)));
    }
    return r;
}

}  // namespace

int main() {
    using namespace spk;
    std::string error;

    // 1. Slope 1 up to -0.5 EV, then 0.45 (+1e-9 per EV, so the two samples about 0 differ by a hair)
    //    to +3, then the white plateau at Y 0.53. gamma0 = 0.5875, so 0.8 gamma0 = 0.47 is crossed at
    //    -0.5 EV, before mid-grey: both samples of the bracket (-0.094, +0.094) are already under it.
    {
        const Ramp r = ramp([](double e) {
            const double s = 0.45 + 1e-9 * e;
            if (e < -0.5) return -2.5 + (e + 0.5);
            if (e < 3.0) return -2.5 + s * (e + 0.5);
            return -2.5 + (0.45 + 3e-9) * 3.5;
        });
        HdrFamilyA a;
        const bool ok = hdr_family_a(r.ev, r.y, 4.0, nullptr, a, error);
        double e0 = 0, e1 = 0;
        for (size_t i = 1; i < r.ev.size(); ++i)
            if (r.ev[i] > 0.0) { e0 = r.ev[i - 1]; e1 = r.ev[i]; break; }
        check(ok, "a medium whose slope falls before mid-grey still has a curve" + (ok ? "" : ": " + error));
        char line[200];
        std::snprintf(line, sizeof line, "its knee is inside the bracket [%+.4f, %+.4f]: %.6g EV", e0, e1, a.knee_ev);
        check(ok && std::isfinite(a.knee_ev) && a.knee_ev >= e0 && a.knee_ev <= e1, line);
        check(ok && std::isfinite(a.delta) && std::fabs(a.delta) < 24.0, "and its delta is a number of stops");
    }

    // 2. Mid-grey on a plateau: a toe of slope 1 up to -3 EV, then 1e-7 per EV, bending down by 1e-9.
    {
        const Ramp r = ramp([](double e) {
            if (e < -3.0) return -1.0 + (e + 3.0);
            return -1.0 + 1e-7 * (e + 3.0) - 1e-9 * (e + 3.0) * (e + 3.0);
        });
        HdrFamilyA a;
        const bool ok = hdr_family_a(r.ev, r.y, 4.0, nullptr, a, error);
        char line[200];
        std::snprintf(line, sizeof line, "a mid-grey on the plateau (gamma0 ~1e-7) is refused: %s",
                      ok ? ("accepted, knee " + std::to_string(a.knee_ev) + " EV").c_str() : error.c_str());
        check(!ok, line);
    }

    // 3. top is log2 H for every H the model accepts.
    const Ramp normal = ramp([](double e) { return -0.2 - 6.0 / (1.0 + std::exp((e - 0.5) * 0.8)); });
    for (const double h : {1.00005, kHdrMinHeadroom, 2.0, 4.0, 16.0}) {
        HdrFamilyA a;
        const bool ok = hdr_family_a(normal.ev, normal.y, h, nullptr, a, error);
        char line[200];
        if (!ok) {
            std::snprintf(line, sizeof line, "H %.5f refused (%s)", h, error.c_str());
            check(h < kHdrMinHeadroom, line);
            continue;
        }
        const HdrTables t = hdr_derive_tables(a.curve);
        std::snprintf(line, sizeof line, "H %.5f: top %.9g = log2 H %.9g = the last sample %.9g", h, t.top,
                      std::log2(h), a.curve.log2_gain.back());
        check(t.top == std::log2(h) && a.curve.log2_gain.back() == std::log2(h), line);
    }

    std::printf("\nhdr curve unit: %d failed\n", failures);
    return failures ? 1 : 0;
}
