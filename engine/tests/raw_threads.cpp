// Thread policy and restoration, plus an optional real-RAW exact comparison.
// No Vulkan device is involved. Usage: spk_raw_threads [RAW [dump-directory]].
#include "io/raw_decoder.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>

#if SPEKTRALAB_RAW_OPENMP
#include <omp.h>
#endif

namespace {
void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}

void set_threads(const char* value) {
#ifdef _WIN32
    _putenv_s("SPEKTRALAB_RAW_THREADS", value ? value : "");
#else
    if (value) setenv("SPEKTRALAB_RAW_THREADS", value, 1);
    else unsetenv("SPEKTRALAB_RAW_THREADS");
#endif
}

struct EnvironmentRestore {
    std::optional<std::string> saved;
    EnvironmentRestore() {
        if (const char* value = std::getenv("SPEKTRALAB_RAW_THREADS")) saved = value;
    }
    ~EnvironmentRestore() { set_threads(saved ? saved->c_str() : nullptr); }
};

void thread_contract() {
    set_threads(nullptr);
    const unsigned available = std::max(1u, std::thread::hardware_concurrency());
    require(spk::io::raw_worker_limit() ==
            (spk::io::raw_openmp_enabled() ? std::min(8u, available) : 1u), "default worker limit");
    set_threads("99999");
    require(spk::io::raw_worker_limit() ==
            (spk::io::raw_openmp_enabled() ? available : 1u), "override must be bounded by hardware");
    for (const char* bad : {"0", "-1", "two", "2junk", "4294967296", " 2"}) {
        set_threads(bad);
        bool rejected = false;
        try { (void)spk::io::raw_worker_limit(); }
        catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "invalid worker override accepted");
    }
    set_threads("2");
    std::exception_ptr failure;
    std::thread worker([&] {
        try {
#if SPEKTRALAB_RAW_OPENMP
            omp_set_num_threads(3);
            omp_set_dynamic(1);
#if _OPENMP >= 200805
            omp_set_max_active_levels(2);
            const int old_levels = omp_get_max_active_levels();
#endif
            const int old_nested = omp_get_nested();
#endif
            {
                spk::io::RawDecodeThreadScope scope;
                require(scope.workers() == (spk::io::raw_openmp_enabled() ? std::min(2u, available) : 1u),
                        "scope did not set the decoding worker's limit");
#if SPEKTRALAB_RAW_OPENMP
                require(omp_get_max_threads() == int(scope.workers()) && !omp_get_dynamic() && !omp_get_nested(),
                        "OpenMP policy not applied to worker");
#endif
            }
            spk::io::DecodedRaw unchanged;
            unchanged.width = 19;
            std::string error;
            require(!spk::io::decode_raw_compatible({}, unchanged, error) && unchanged.width == 19,
                    "failed decode changed its output");
#if SPEKTRALAB_RAW_OPENMP
            require(omp_get_max_threads() == 3 && omp_get_dynamic() == 1 && omp_get_nested() == old_nested,
                    "OpenMP policy leaked out of a scope or failed decode");
#if _OPENMP >= 200805
            require(omp_get_max_active_levels() == old_levels, "OpenMP active nesting limit changed");
#endif
#endif
        } catch (...) { failure = std::current_exception(); }
    });
    worker.join();
    if (failure) std::rethrow_exception(failure);
}

void same_metadata(const spk::io::RawMetadata& a, const spk::io::RawMetadata& b) {
    require(a.camera_whitebalance == b.camera_whitebalance && a.post_scale_pre_mul == b.post_scale_pre_mul &&
            a.rgb_cam == b.rgb_cam && a.camera_to_output == b.camera_to_output && a.raw_flip == b.raw_flip &&
            a.black_level_per_channel == b.black_level_per_channel && a.black_pattern == b.black_pattern &&
            a.white_level == b.white_level && a.process_warnings == b.process_warnings &&
            a.white_balance_exposure_restore == b.white_balance_exposure_restore,
            "thread count changed RAW colour metadata");
}

void real_raw(const std::filesystem::path& path, const std::filesystem::path& dumps) {
    for (const std::string mode : {"compatible16", "headroom", "custom_wb", "headroom_custom_wb"}) {
        spk::io::DecodedRaw baseline;
        std::set<unsigned> tested;
        for (unsigned requested : {1u, 2u, 4u, 8u}) {
            set_threads(std::to_string(requested).c_str());
            if (!tested.insert(spk::io::raw_worker_limit()).second) continue;
            spk::io::DecodedRaw frame;
            std::string error;
            const std::array<float, 4> wb{2.0f, 1.0f, 1.5f, 1.0f};
            const bool ok = mode.starts_with("headroom")
                ? spk::io::decode_raw_headroom(path, mode == "headroom_custom_wb" ? &wb : nullptr, frame, error)
                : spk::io::decode_raw_compatible(path, mode == "custom_wb" ? &wb : nullptr, frame, error);
            if (!ok) throw std::runtime_error(error);
            const auto& t = frame.timings;
            require(t.openmp_enabled == spk::io::raw_openmp_enabled() && t.workers == spk::io::raw_worker_limit(),
                    "decode omitted its threading diagnostics");
            std::cout << "{\"mode\":\"" << mode << "\",\"workers\":" << t.workers
                      << ",\"openmp\":" << (t.openmp_enabled ? "true" : "false")
                      << ",\"width\":" << frame.width << ",\"height\":" << frame.height
                      << ",\"open_ms\":" << t.open_ms << ",\"unpack_ms\":" << t.unpack_ms
                      << ",\"process_ms\":" << t.process_ms << ",\"convert_ms\":" << t.convert_ms
                      << ",\"total_ms\":" << t.total_ms << "}\n";
            if (baseline.rgb.empty()) {
                if (!dumps.empty()) {
                    std::filesystem::create_directories(dumps);
                    std::ofstream out(dumps / (mode + ".f32"), std::ios::binary);
                    out.write(reinterpret_cast<const char*>(frame.rgb.data()), std::streamsize(frame.rgb.size() * sizeof(float)));
                    if (!out) throw std::runtime_error("cannot save RAW comparison buffer");
                }
                baseline = std::move(frame);
            } else {
                require(frame.width == baseline.width && frame.height == baseline.height &&
                        frame.rgb.size() == baseline.rgb.size(), "thread count changed RAW dimensions");
                require(std::memcmp(frame.rgb.data(), baseline.rgb.data(), frame.rgb.size() * sizeof(float)) == 0,
                        "thread count changed RAW pixels");
                same_metadata(frame.metadata, baseline.metadata);
            }
        }
    }
}
}

int main(int argc, char** argv) {
    try {
        EnvironmentRestore restore;
        thread_contract();
        if (argc > 1) real_raw(std::filesystem::path(reinterpret_cast<const char8_t*>(argv[1])),
                              argc > 2 ? std::filesystem::path(reinterpret_cast<const char8_t*>(argv[2])) : std::filesystem::path{});
        std::cout << "RAW thread policy and exact comparisons passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
