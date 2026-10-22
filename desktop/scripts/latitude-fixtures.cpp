// Regenerate shared/fixtures/latitude-fit.json with the engine's CPU oracle:
// g++ -std=c++20 -I ../engine/src/core scripts/latitude-fixtures.cpp
//     ../engine/src/core/latitude_fit.cpp -o <temporary executable>
// <temporary executable> > src/shared/fixtures/latitude-fit.json
#include "latitude_fit.hpp"
#include <array>
#include <iomanip>
#include <iostream>
int main() {
    std::cout << std::setprecision(17) << "[\n";
    bool comma = false;
    // Wide, narrow, within-medium, no-window and asymmetric scenes.
    for (auto at : {std::array{7., 4., -8., -5.}, std::array{3., 2., -3., -2.},
                    std::array{1., 4., -2., -5.}, std::array{20., 1., -20., -2.},
                    std::array{8., 3., -5., -4.}})
    for (double m : {1., 2., 4.}) for (double L : {2., 4., 8.})
    for (double h : {0., .125, 1., 3.01, 5., 8.}) for (double s : {0., .125, 1., 3.01, 4., 8.}) {
        spk::slm::Medium medium; medium.valid = true;
        medium.highlight_ev = at[1]; medium.shadow_ev = at[3];
        spk::slm::SceneStats scene; scene.p999 = at[0]; scene.p01 = at[2];
        spk::SceneLatitudeParams base; base.rolloff = m; base.max_lift = L;
        auto fit = spk::slm::fit(medium, scene, h, s, base);
        if (comma) std::cout << ",\n"; comma = true;
        std::cout << "{\"at\":[" << at[0] << ',' << at[1] << ',' << at[2] << ',' << at[3]
                  << "],\"rolloff\":" << m << ",\"maxLift\":" << L << ",\"h\":" << h << ",\"s\":" << s;
        if (!fit.valid()) std::cout << ",\"issue\":[\"" << fit.issues[0].code << "\",\"" << fit.issues[0].side << "\"]";
        else std::cout << ",\"curve\":[" << fit.params.highlight_knee << ',' << fit.params.highlight_room << ','
                       << fit.params.shadow_knee << ',' << fit.params.shadow_room << ']';
        std::cout << '}';
    }
    std::cout << "\n]\n";
}
