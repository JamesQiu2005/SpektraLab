// Offline setup generator; no Python reference or GPU needed.
#include "core/blob.hpp"
#include "core/colour.hpp"
#include "core/cam16_bake.hpp"
#include <cstdio>

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: bake_cam16 resources_dir output_dir\n");
        return 2;
    }
    spk::Blob blob;
    spk::Colour colour;
    std::string error;
    if (!blob.open(std::string(argv[1]) + "/spektralab_constants.bin", error) || !colour.init(blob, error)) {
        std::fprintf(stderr, "%s\n", error.c_str());
        return 1;
    }
    std::filesystem::create_directories(argv[2]);
    for (const char* cs : {"sRGB", "ProPhoto RGB", "Display P3", "Adobe RGB (1998)", "ITU-R BT.2020", "ACEScg"}) {
        spk::Cam16Setup setup;
        if (!spk::cam16_setup_for(colour, cs, setup, error) || !spk::cam16_bake::write(argv[2], cs, setup)) {
            std::fprintf(stderr, "could not bake %s: %s\n", cs, error.c_str());
            return 1;
        }
        std::printf("%s %s\n", cs, spk::cam16_bake::path(argv[2], cs).c_str());
    }
}
