// Native host TIFF tests use an independent tag reader and Windows' colour
// profile validator. They do not need a Vulkan device or a Python runtime.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <icm.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#include "io/image_writer.hpp"

namespace fs = std::filesystem;

namespace {
void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

struct HeldFile {
    void* value = nullptr;
    ~HeldFile() {
        if (value) {
            FILE_DISPOSITION_INFO disposition{TRUE};
            SetFileInformationByHandle(value, FileDispositionInfo, &disposition, sizeof disposition);
            CloseHandle(value);
        }
    }
    void close() {
        check(value && CloseHandle(value), "cannot close transferred TIFF handle");
        value = nullptr;
    }
};

void check_exclusive(const fs::path& path) {
    const HANDLE other = CreateFileW(path.c_str(), GENERIC_READ,
                                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                     nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    const DWORD error = GetLastError();
    if (other != INVALID_HANDLE_VALUE) CloseHandle(other);
    check(other == INVALID_HANDLE_VALUE && error == ERROR_SHARING_VIOLATION,
          "transferred TIFF handle is not exclusive");
}

std::vector<uint8_t> read_file(const fs::path& path) {
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    check(bool(in), "test cannot open file");
    const auto length = in.tellg();
    check(length >= 0 && length <= 8 * 1024 * 1024, "test file size is invalid");
    std::vector<uint8_t> bytes(size_t(length), uint8_t{0});
    in.seekg(0);
    check(bool(in.read(reinterpret_cast<char*>(bytes.data()), std::streamsize(bytes.size()))),
          "test cannot read file");
    return bytes;
}

uint16_t u16(const std::vector<uint8_t>& bytes, size_t at) {
    check(at <= bytes.size() && 2 <= bytes.size() - at, "TIFF short is out of range");
    return uint16_t(bytes[at]) | (uint16_t(bytes[at + 1]) << 8);
}

uint32_t u32(const std::vector<uint8_t>& bytes, size_t at) {
    return uint32_t(u16(bytes, at)) | (uint32_t(u16(bytes, at + 2)) << 16);
}

struct Tag { uint16_t type; uint32_t count; size_t payload; };

std::map<uint16_t, Tag> read_tags(const std::vector<uint8_t>& bytes) {
    check(bytes.size() >= 8 && bytes[0] == 'I' && bytes[1] == 'I' && u16(bytes, 2) == 42,
          "not a little-endian classic TIFF");
    const uint32_t ifd = u32(bytes, 4);
    const uint16_t count = u16(bytes, ifd);
    std::map<uint16_t, Tag> tags;
    uint16_t previous = 0;
    for (uint16_t i = 0; i < count; ++i) {
        const size_t at = size_t(ifd) + 2 + size_t(i) * 12;
        const uint16_t key = u16(bytes, at), type = u16(bytes, at + 2);
        const uint32_t length = u32(bytes, at + 4);
        check(key > previous, "TIFF tags are duplicate or unordered");
        previous = key;
        const uint32_t unit = type == 3 ? 2 : type == 4 ? 4 : type == 5 ? 8 :
                              (type == 2 || type == 7) ? 1 : 0;
        check(unit != 0, "unexpected TIFF field type");
        const uint64_t extent = uint64_t(length) * unit;
        const size_t payload = extent <= 4 ? at + 8 : u32(bytes, at + 8);
        check(payload <= bytes.size() && extent <= bytes.size() - payload, "TIFF field is out of range");
        tags.emplace(key, Tag{type, length, payload});
    }
    check(u32(bytes, size_t(ifd) + 2 + size_t(count) * 12) == 0, "unexpected second TIFF page");
    return tags;
}

uint32_t integer(const std::vector<uint8_t>& bytes, const Tag& tag, uint32_t i = 0) {
    check(i < tag.count, "test indexed beyond TIFF field");
    if (tag.type == 3) return u16(bytes, tag.payload + size_t(i) * 2);
    check(tag.type == 4, "TIFF field has noninteger type");
    return u32(bytes, tag.payload + size_t(i) * 4);
}

void validate_icc(const std::vector<uint8_t>& profile) {
    HMODULE module = LoadLibraryW(L"mscms.dll");
    check(module != nullptr, "Windows colour management is unavailable");
    auto open = reinterpret_cast<decltype(&OpenColorProfileW)>(GetProcAddress(module, "OpenColorProfileW"));
    auto valid = reinterpret_cast<decltype(&IsColorProfileValid)>(GetProcAddress(module, "IsColorProfileValid"));
    auto close = reinterpret_cast<decltype(&CloseColorProfile)>(GetProcAddress(module, "CloseColorProfile"));
    if (!open || !valid || !close) { FreeLibrary(module); throw std::runtime_error("missing Windows ICC validation API"); }
    PROFILE value{PROFILE_MEMBUFFER, const_cast<uint8_t*>(profile.data()), DWORD(profile.size())};
    HPROFILE handle = open(&value, PROFILE_READ, FILE_SHARE_READ, OPEN_EXISTING);
    BOOL is_valid = FALSE;
    const bool okay = handle && valid(handle, &is_valid) && is_valid;
    if (handle) close(handle);
    FreeLibrary(module);
    check(okay, "Windows rejected the embedded ICC profile");
}

std::vector<uint16_t> image(uint32_t width, uint32_t height, uint32_t stride) {
    // Padding deliberately has non-opaque alpha and must never be exported.
    std::vector<uint16_t> pixels(size_t(stride) * height * 4, 0);
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        for (uint32_t c = 0; c < 3; ++c)
            pixels[(size_t(y) * stride + x) * 4 + c] = uint16_t(53 * y + 257 * x + 1013 * c);
        pixels[(size_t(y) * stride + x) * 4 + 3] = 65535;
    }
    pixels[0] = 0; pixels[1] = 65535;
    return pixels;
}

void decode_and_compare(const fs::path& path, const std::vector<uint16_t>& expected,
                        uint32_t width, uint32_t height, uint32_t stride,
                        const std::vector<uint8_t>& expected_profile) {
    const auto bytes = read_file(path);
    const auto tags = read_tags(bytes);
    auto value = [&](uint16_t key) { return integer(bytes, tags.at(key)); };
    check(value(256) == width && value(257) == height, "TIFF dimensions changed");
    check(value(259) == 1 && value(262) == 2 && value(274) == 1 && value(277) == 3 && value(284) == 1,
          "TIFF compression/photometric/orientation/sample layout differs");
    check(tags.at(258).count == 3 && tags.at(339).count == 3, "missing RGB sample metadata");
    for (uint32_t c = 0; c < 3; ++c)
        check(integer(bytes, tags.at(258), c) == 16 && integer(bytes, tags.at(339), c) == 1,
              "TIFF samples are not unsigned RGB16");
    check(value(296) == 1, "TIFF assigns an unrequested physical resolution");
    for (uint16_t key : {uint16_t(282), uint16_t(283)})
        check(u32(bytes, tags.at(key).payload) == 1 && u32(bytes, tags.at(key).payload + 4) == 1,
              "TIFF pixels are not square");
    const Tag& icc = tags.at(34675);
    check(icc.type == 7 && icc.count == expected_profile.size(), "TIFF ICC type/length differs");
    std::vector<uint8_t> embedded(bytes.begin() + icc.payload, bytes.begin() + icc.payload + icc.count);
    check(embedded == expected_profile, "TIFF changed embedded ICC bytes");
    validate_icc(embedded);
    const uint32_t rows_per_strip = value(278), strips = (height - 1) / rows_per_strip + 1;
    check(tags.at(273).count == strips && tags.at(279).count == strips, "TIFF strip table count differs");
    uint64_t previous_end = 0;
    for (uint32_t strip = 0; strip < strips; ++strip) {
        const uint32_t offset = integer(bytes, tags.at(273), strip);
        const uint32_t count = integer(bytes, tags.at(279), strip);
        const uint32_t y0 = strip * rows_per_strip, rows = std::min(rows_per_strip, height - y0);
        check(count == uint64_t(rows) * width * 6 && offset >= previous_end &&
              uint64_t(offset) + count <= bytes.size(), "TIFF strip overlaps or has an invalid extent");
        for (uint32_t row = 0; row < rows; ++row) for (uint32_t x = 0; x < width; ++x)
            for (uint32_t c = 0; c < 3; ++c)
                check(u16(bytes, offset + (size_t(row) * width + x) * 6 + c * 2) ==
                      expected[(size_t(y0 + row) * stride + x) * 4 + c],
                      "TIFF sample changed, channel swapped, or padded row leaked");
        previous_end = uint64_t(offset) + count;
    }
    check(previous_end == bytes.size(), "TIFF image extent does not reach the file end");
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: image_writer_test <sRGB.icc> <output-root>\n"); return 2; }
    try {
        const fs::path profile_path(reinterpret_cast<const char8_t*>(argv[1]));
        const auto profile = read_file(profile_path);
        const fs::path output_root(reinterpret_cast<const char8_t*>(argv[2]));
        fs::create_directories(output_root);
        const fs::path output = output_root / (L"\u8272\u5f69-test-" + std::to_wstring(GetCurrentProcessId()) +
                                               L"-" + std::to_wstring(GetTickCount64()));
        check(fs::create_directory(output), "test output already exists");
        std::string error;
        for (const auto& shape : {std::array<uint32_t, 3>{3, 2, 5}, {257, 129, 263}}) {
            const uint32_t width = shape[0], height = shape[1], stride = shape[2];
            const auto pixels = image(width, height, stride);
            const fs::path path = output / (L"\u6d4b\u8bd5-" + std::to_wstring(height) + L".tiff");
            if (!spk::io::write_srgb_tiff(path, pixels.data(), width, height, stride, profile_path, error))
                throw std::runtime_error(error);
            decode_and_compare(path, pixels, width, height, stride, profile);
            const auto saved = read_file(path);
            check(!spk::io::write_srgb_tiff(path, pixels.data(), width, height, stride, profile_path, error),
                  "writer overwrote an existing destination");
            check(read_file(path) == saved, "overwrite rejection changed an existing file");
        }
        {
            const auto held_pixels = image(3, 2, 5);
            const fs::path held_path = output / L"held.tiff";
            HeldFile held;
            if (!spk::io::write_srgb_tiff_held(held_path, held_pixels.data(), 3, 2, 5,
                                             profile_path, held.value, error))
                throw std::runtime_error(error);
            check(held.value && held.value != INVALID_HANDLE_VALUE, "missing transferred TIFF handle");
            check_exclusive(held_path);
            LARGE_INTEGER begin{}, position{}, length{};
            check(GetFileSizeEx(held.value, &length) &&
                  SetFilePointerEx(held.value, begin, &position, FILE_CURRENT) &&
                  length.QuadPart == position.QuadPart, "transferred TIFF handle is not at EOF");
            std::array<uint8_t, 8> header{};
            DWORD count = 0;
            check(SetFilePointerEx(held.value, begin, nullptr, FILE_BEGIN) &&
                  ReadFile(held.value, header.data(), DWORD(header.size()), &count, nullptr) &&
                  count == header.size() && header[0] == 'I' && header[1] == 'I',
                  "transferred TIFF handle does not permit reading");
            check(SetFilePointerEx(held.value, begin, nullptr, FILE_BEGIN) &&
                  WriteFile(held.value, header.data(), DWORD(header.size()), &count, nullptr) &&
                  count == header.size() && FlushFileBuffers(held.value),
                  "transferred TIFF handle does not permit writing");
            held.close();
            decode_and_compare(held_path, held_pixels, 3, 2, 5, profile);
            const auto saved = read_file(held_path);
            check(!spk::io::write_srgb_tiff_held(held_path, held_pixels.data(), 3, 2, 5,
                                               profile_path, held.value, error) && !held.value,
                  "held writer overwrote a destination or leaked a failure handle");
            check(read_file(held_path) == saved, "held overwrite rejection changed a file");
            const fs::path rollback_path = output / L"held-rollback.tiff";
            if (!spk::io::write_srgb_tiff_held(rollback_path, held_pixels.data(), 3, 2, 5,
                                             profile_path, held.value, error))
                throw std::runtime_error(error);
            check_exclusive(rollback_path);
            FILE_DISPOSITION_INFO disposition{TRUE};
            check(SetFileInformationByHandle(held.value, FileDispositionInfo,
                                              &disposition, sizeof disposition),
                  "transferred TIFF handle does not permit rollback deletion");
            held.close();
            check(!fs::exists(rollback_path), "rollback by transferred handle left a TIFF");
        }
        auto pixels = image(7, 65, 9);
        pixels[(size_t(64) * 9) * 4 + 3] = 123;
        const fs::path partial = output / L"partial.tiff";
        check(!spk::io::write_srgb_tiff(partial, pixels.data(), 7, 65, 9, profile_path, error),
              "writer silently dropped non-opaque alpha");
        check(!fs::exists(partial), "failure after first written strip left a partial TIFF");
        {
            HeldFile failed;
            const fs::path held_partial = output / L"held-partial.tiff";
            check(!spk::io::write_srgb_tiff_held(held_partial, pixels.data(), 7, 65, 9,
                                               profile_path, failed.value, error) && !failed.value,
                  "held failure returned an owned handle");
            check(!fs::exists(held_partial), "held failure left a partial TIFF");
        }
        pixels[(size_t(64) * 9) * 4 + 3] = 65535;
        if (!spk::io::write_srgb_tiff(partial, pixels.data(), 7, 65, 9, profile_path, error))
            throw std::runtime_error(error);
        decode_and_compare(partial, pixels, 7, 65, 9, profile);
        check(!spk::io::write_srgb_tiff(output / L"bad-stride.tif", pixels.data(), 7, 65, 6, profile_path, error),
              "invalid row stride accepted");
        check(!spk::io::write_srgb_tiff(output / L"empty.tif", pixels.data(), 0, 65, 9, profile_path, error),
              "zero width accepted");
        check(!spk::io::write_srgb_tiff(output / L"overflow.tif", pixels.data(), UINT32_MAX, UINT32_MAX,
                                      UINT32_MAX, profile_path, error), "overflow-sized image accepted");
        auto invalid_profile = profile;
        std::memcpy(invalid_profile.data() + 16, "CMYK", 4);
        const fs::path bad_icc = output / L"invalid.icc";
        std::ofstream bad(bad_icc, std::ios::binary);
        bad.write(reinterpret_cast<const char*>(invalid_profile.data()), std::streamsize(invalid_profile.size()));
        bad.close();
        check(!spk::io::write_srgb_tiff(output / L"bad-profile.tif", pixels.data(), 7, 65, 9, bad_icc, error),
              "non-RGB ICC accepted");
        for (const wchar_t* name : {L"bad-stride.tif", L"empty.tif", L"overflow.tif", L"bad-profile.tif"})
            check(!fs::exists(output / name), "invalid input left an output file");
        std::printf("TIFF writer passed: RGB16 exact decode, strips/stride/Unicode, valid embedded ICC, exclusive handle transfer/read/write/rollback, no overwrite, partial cleanup, invalid inputs\n");
        std::printf("test output: %s\n", reinterpret_cast<const char*>(output.u8string().c_str()));
        return 0;
    } catch (const std::exception& exc) {
        std::fprintf(stderr, "TIFF writer test: %s\n", exc.what());
        return 1;
    }
}
