// Fault-injected shader directories exercise real driver dispatch and the
// production acceptance gate; they are never included in runtime resources.
#include "gpu/gpu.hpp"
#include <cstdio>
#include <memory>
#include <string>
int main(int argc, char** argv) {
    if (argc != 4) return 2;
    std::string error, detail;
    std::unique_ptr<spk::gpu::Gpu> gpu(spk::gpu::Gpu::create_vulkan(argv[1], error));
    if (!gpu) { std::fprintf(stderr, "%s\n", error.c_str()); return 1; }
    const bool expected = std::string(argv[2]) == "pass";
    // Repeat to catch prematurely cached success after a failed split probe.
    for (int i = 0; i < 2; ++i) {
        if (gpu->check_math_mode(detail) != expected || detail.find(argv[3]) == std::string::npos) {
            std::fprintf(stderr, "unexpected gate: %s\n", detail.c_str()); return 1;
        }
    }
    if (!expected) {
        if (gpu->dispatch("spk_mul", {}, 1, error) || error != detail) {
            std::fprintf(stderr, "failed gate was bypassed: %s\n", error.c_str()); return 1;
        }
    }
    std::printf("%s: %s\n", gpu->device_name().c_str(), detail.c_str());
    return 0;
}
