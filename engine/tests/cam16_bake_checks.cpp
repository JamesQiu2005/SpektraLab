// Optional setup artifacts must be exact, and every bad artifact must be a miss.
#include "core/blob.hpp"
#include "core/colour.hpp"
#include "core/cam16_bake.hpp"
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <unistd.h>

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    spk::Blob blob;
    spk::Colour colour;
    std::string error;
    const std::string resources = argv[1];
    if (!blob.open(resources + "/spektralab_constants.bin", error) || !colour.init(blob, error)) return 1;
    char pattern[] = "/private/tmp/spk-cam16-check-XXXXXX";
    const char* dir = mkdtemp(pattern);
    if (!dir) return 1;
    struct Cleanup { const char* dir; ~Cleanup() { std::filesystem::remove_all(dir); } } cleanup{dir};
    int failures = 0;
    auto check = [&](bool ok, const char* what) {
        std::printf("%s %s\n", ok ? "ok" : "FAIL", what);
        failures += !ok;
    };
    for (const char* cs : {"sRGB", "ProPhoto RGB", "Display P3", "Adobe RGB (1998)", "ITU-R BT.2020", "ACEScg"}) {
        spk::Cam16Setup computed;
        if (!spk::cam16_setup_for(colour, cs, computed, error)) return 1;
        auto loaded = computed;
        loaded.c_max_table.clear();
        check(spk::cam16_bake::read((resources + "/cam16").c_str(), cs, loaded), cs);
        check(loaded.c_max_table == computed.c_max_table, "baked float64 cells equal computed fallback");
        loaded.c_max_table.clear();
        check(!spk::cam16_bake::read(dir, cs, loaded), "missing is a miss");
        check(spk::cam16_bake::write(dir, cs, computed), "write fixture");
        auto path = spk::cam16_bake::path(dir, cs);
        loaded.white_Jp += .1;
        check(!spk::cam16_bake::read(dir, cs, loaded), "changed setup metadata is a miss");
        loaded = computed;
        {
            std::fstream file(path, std::ios::binary | std::ios::in | std::ios::out);
            file.seekp(-1, std::ios::end);
            char byte = 0x7f; file.write(&byte, 1);
        }
        check(!spk::cam16_bake::read(dir, cs, loaded), "corrupt payload is a miss");
        spk::cam16_bake::write(dir, cs, computed);
        std::filesystem::resize_file(path, 32);
        check(!spk::cam16_bake::read(dir, cs, loaded), "truncated payload is a miss");
        auto invalid = computed;
        invalid.c_max_table[0] = std::numeric_limits<double>::quiet_NaN();
        spk::cam16_bake::write(dir, cs, invalid); // correct checksum, invalid value
        check(!spk::cam16_bake::read(dir, cs, loaded), "nonfinite table is a miss despite valid checksum");
        spk::Cam16Setup fallback;
        check(spk::cam16_setup_for(colour, cs, fallback, error, dir) &&
              fallback.c_max_table == computed.c_max_table, "invalid artifact computes exact fallback");
    }
    return failures ? 1 : 0;
}
