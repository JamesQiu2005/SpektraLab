// Error-path contract; real RAW decoding and pixel parity belong to the
// native/rawpy fixture comparison and are not claimed by this test.
#include "io/raw_decoder.hpp"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <system_error>

namespace {

struct ScratchDirectory {
    std::filesystem::path path;
    ScratchDirectory() {
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
        for (int attempt = 0; attempt < 100; ++attempt) {
            const auto candidate = std::filesystem::temp_directory_path() /
                ("spektralab-raw-errors-" + std::to_string(stamp) + "-" + std::to_string(attempt));
            if (std::filesystem::create_directory(candidate)) {
                path = candidate;
                return;
            }
        }
        throw std::runtime_error("cannot create scratch directory");
    }
    ~ScratchDirectory() {
        // Only remove paths created by this test, without recursive deletion.
        std::error_code ignored;
        std::filesystem::remove(path / std::filesystem::path(u8"损坏 RAW 文件.dng"), ignored);
        std::filesystem::remove(path / "truncated.dng", ignored);
        std::filesystem::remove(path, ignored);
    }
};

void check_rejected(const std::filesystem::path& path, const char* label) {
    for(auto decode : {&spk::io::decode_raw_compatible, &spk::io::decode_raw_headroom}) {
    spk::io::DecodedRaw prior;
    prior.width = 7;
    prior.height = 11;
    prior.rgb = {-0.25f, 0.5f, 4.0f};
    prior.metadata.libraw_version = "previous successful result";
    prior.metadata.black_pattern = {5, 6};
    prior.timings.total_ms = 123.5;
    std::string error = "stale error";
    if (decode(path, prior, error))
        throw std::runtime_error(std::string(label) + ": invalid source accepted");
    if (error.empty() || error == "stale error")
        throw std::runtime_error(std::string(label) + ": failed decode omitted its error");
    if (prior.width != 7 || prior.height != 11 ||
        prior.rgb != std::vector<float>({-0.25f, 0.5f, 4.0f}) ||
        prior.metadata.libraw_version != "previous successful result" ||
        prior.metadata.black_pattern != std::vector<std::uint32_t>({5, 6}) ||
        prior.timings.total_ms != 123.5)
        throw std::runtime_error(std::string(label) + ": failed decode changed previous output");
    }
}

void write_fixture(const std::filesystem::path& path, const char* data, std::streamsize size) {
    std::ofstream file(path, std::ios::binary);
    if (!file || !file.write(data, size) || !file.flush())
        throw std::runtime_error("cannot write invalid RAW fixture");
}

}  // namespace

int main() {
    try {
        ScratchDirectory scratch;
        const auto junk = scratch.path / std::filesystem::path(u8"损坏 RAW 文件.dng");
        constexpr char junk_bytes[] = "this is not a RAW image or a TIFF container";
        write_fixture(junk, junk_bytes, sizeof(junk_bytes));
        const auto truncated = scratch.path / "truncated.dng";
        constexpr char tiff_header[] = {'I', 'I', 42, 0, 8, 0, 0, 0, 12, 0};
        write_fixture(truncated, tiff_header, sizeof(tiff_header));

        check_rejected({}, "empty path");
        check_rejected(scratch.path / "missing.nef", "missing RAW");
        check_rejected(scratch.path, "directory");
        check_rejected(junk, "invalid RAW with Unicode filename");
        check_rejected(truncated, "truncated TIFF directory");
        std::cout << "RAW decoder error contract: 10 cases passed (5 per mode)\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << exception.what() << '\n';
        return 1;
    }
}
