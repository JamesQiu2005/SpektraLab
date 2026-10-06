// The bundled Tauri resource directory can carry a \\?\ prefix. Win32 stops
// translating forward slashes there, while the engine appends resource names
// with '/'. Check both mapped constants and stream readers without a GPU.
#include "blob.hpp"
#include "file_path.hpp"
#include "print_lut.hpp"
#include "profile.hpp"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
namespace {

void require(bool value, const std::string& error) {
    if (!value) throw std::runtime_error(error);
}

std::string utf8(const fs::path& path) {
    const auto bytes = path.u8string();
    return std::string(bytes.begin(), bytes.end());
}

fs::path extended(const fs::path& path) {
    const auto wide = fs::absolute(path).make_preferred().native();
    if (wide.starts_with(L"\\\\?\\")) return path;
    if (wide.starts_with(L"\\\\")) return fs::path(L"\\\\?\\UNC\\" + wide.substr(2));
    return fs::path(L"\\\\?\\" + wide);
}

struct Scratch {
    fs::path root;
    std::vector<fs::path> files, dirs;
    explicit Scratch(const fs::path& parent) {
        fs::create_directories(parent);
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
        root = extended(parent / ("run-" + std::to_string(stamp)));
        mkdir(root);
    }
    void mkdir(const fs::path& path) {
        require(fs::create_directory(path), "scratch directory already exists");
        dirs.push_back(path);
    }
    void stage(const fs::path& source, const fs::path& destination) {
        mkdir(destination / "profiles");
        for (const auto* name : {"spektrafilm_constants.bin", "print_luts.json",
                                 "profiles/kodak_portra_400.json"}) {
            const auto relative = fs::path(name).make_preferred();
            const auto target = destination / relative;
            require(fs::copy_file(source / relative, target), "cannot stage resource");
            files.push_back(target);
        }
        mkdir(destination / "vulkan");
        // Stream the same binary header as a shader load; no Vulkan runtime.
        const auto shader = destination / "vulkan" / "probe.spv";
        files.push_back(shader);
        std::ofstream out(shader, std::ios::binary);
        const uint32_t header[] = {0x07230203u, 0x00010000u, 0u, 1u, 0u};
        require(bool(out.write(reinterpret_cast<const char*>(header), sizeof(header))),
                "cannot stage shader header");
    }
    ~Scratch() {
        // Delete only this test's recorded files and empty directories.
        std::error_code ignored;
        for (auto it = files.rbegin(); it != files.rend(); ++it) fs::remove(*it, ignored);
        for (auto it = dirs.rbegin(); it != dirs.rend(); ++it) fs::remove(*it, ignored);
    }
};

int failures = 0;
template<class Check> void test(const std::string& name, Check check) {
    try {
        check();
        std::cout << "PASS " << name << '\n';
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "FAIL " << name << ": " << error.what() << '\n';
    }
}

void read_resources(const std::string& directory, const std::string& name) {
    // Keep the engine's actual forward-slash joins, including after \\?\.
    test(name + " / mapped constants", [&] {
        spk::Blob blob;
        std::string error;
        require(blob.open(directory + "/spektrafilm_constants.bin", error), error);
        require(blob.has("print_lut/kodak_portra_endura"), "constants were not read");
    });
    test(name + " / profile", [&] {
        spk::Profile profile;
        std::string error;
        require(spk::load_profile(directory, "kodak_portra_400", profile, error), error);
        require(profile.info.stock == "kodak_portra_400", "profile was not read");
    });
    test(name + " / LUT index", [&] {
        spk::PrintLutLibrary library;
        std::string error;
        require(library.init(directory, error), error);
        // init alone accepts a missing file: require a known shipped entry.
        require(library.has("kodak_portra_endura"), "LUT index was not read");
    });
    test(name + " / shader stream", [&] {
        std::ifstream input(spk::file_path(directory + "/vulkan/probe.spv"), std::ios::binary);
        uint32_t magic = 0;
        require(bool(input.read(reinterpret_cast<char*>(&magic), sizeof(magic))),
                "shader stream did not open/read");
        require(magic == 0x07230203u, "shader header changed");
    });
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: spk_resource_paths <engine/resources> <scratch parent>\n";
        return 2;
    }
    try {
        const auto source = fs::path(std::u8string(argv[1], argv[1] + std::char_traits<char>::length(argv[1])));
        Scratch scratch(fs::path(std::u8string(argv[2], argv[2] + std::char_traits<char>::length(argv[2]))));
        const auto plain = scratch.root / "plain";
        scratch.mkdir(plain);
        scratch.stage(source, plain);
        const auto unicode = scratch.root / fs::path(u8"\u4e2d\u6587\u8d44\u6e90\u6587\u4ef6\u5939");
        scratch.mkdir(unicode);
        scratch.stage(source, unicode);
        auto long_path = unicode;
        while (long_path.native().size() < 300) {
            long_path /= "long-resource-component-0123456789";
            scratch.mkdir(long_path);
        }
        scratch.stage(source, long_path);

        // All scratch paths are extended absolute paths; remove the prefix
        // only for the short ordinary-path control cases.
        for (const auto& item : std::vector<std::pair<fs::path, std::string>>{
                 {plain, "ASCII"}, {unicode, "Unicode"}}) {
            const auto full = utf8(item.first);
            auto ordinary = full.starts_with("\\\\?\\UNC\\") ? "\\\\" + full.substr(8) : full.substr(4);
            read_resources(ordinary, item.second + " ordinary");
            std::replace(ordinary.begin(), ordinary.end(), '\\', '/');
            read_resources(ordinary, item.second + " ordinary forward");
            read_resources(utf8(item.first), item.second + " extended");
            auto mixed = utf8(item.first);
            mixed[mixed.rfind('\\')] = '/';
            read_resources(mixed, item.second + " extended mixed");
        }
        read_resources(utf8(long_path), "long Unicode extended (>300 characters)");
        test("extended UNC lexical normalization (no network share required)", [] {
            const auto path = utf8(fs::path(u8"\\\\?\\UNC\\server/share/\u4e2d\u6587/file.bin"));
            require(spk::file_path(path).native() ==
                    L"\\\\?\\UNC\\server\\share\\\u4e2d\u6587\\file.bin", "UNC prefix/separators changed");
        });
        test("malformed UTF-8 rejected by mapped reader", [] {
            spk::Blob blob;
            std::string error;
            require(!blob.open(std::string("bad-\xc0\xaf.bin"), error), "invalid UTF-8 accepted");
            require(error.starts_with("invalid UTF-8 path:"), "strict UTF-8 error lost");
        });
        std::cout << "Resource path failures: " << failures << '\n';
        return failures ? 1 : 0;
    } catch (const std::exception& error) {
        std::cerr << "Fixture setup failed: " << error.what() << '\n';
        return 2;
    }
}
