#include "image_writer.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace spk::io {
namespace {

uint32_t be32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

void le16(std::vector<uint8_t>& data, size_t at, uint16_t n) {
    data[at] = uint8_t(n); data[at + 1] = uint8_t(n >> 8);
}

void le32(std::vector<uint8_t>& data, size_t at, uint32_t n) {
    for (size_t i = 0; i < 4; ++i) data[at + i] = uint8_t(n >> (8 * i));
}

bool load_profile(const std::filesystem::path& path, std::vector<uint8_t>& bytes,
                  std::string& error) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) { error = "cannot open the explicit sRGB ICC resource"; return false; }
    const auto size = stream.tellg();
    if (size < 132 || size > 4 * 1024 * 1024) {
        error = "ICC resource must contain 132 bytes to 4 MiB"; return false;
    }
    bytes.resize(size_t(size));
    stream.seekg(0);
    if (!stream.read(reinterpret_cast<char*>(bytes.data()), std::streamsize(bytes.size()))) {
        error = "cannot read the complete sRGB ICC resource"; return false;
    }
    if (be32(bytes.data()) != bytes.size() || std::memcmp(bytes.data() + 36, "acsp", 4) ||
        std::memcmp(bytes.data() + 16, "RGB ", 4) || std::memcmp(bytes.data() + 20, "XYZ ", 4)) {
        error = "ICC resource is not a complete RGB-to-XYZ profile"; return false;
    }
    const uint32_t tags = be32(bytes.data() + 128);
    if (tags > (bytes.size() - 132) / 12) {
        error = "ICC tag table exceeds its resource"; return false;
    }
    for (uint32_t i = 0; i < tags; ++i) {
        const uint8_t* tag = bytes.data() + 132 + size_t(i) * 12;
        const uint32_t at = be32(tag + 4), length = be32(tag + 8);
        if (at < 128 || at > bytes.size() || length < 8 || length > bytes.size() - at) {
            error = "ICC tag payload exceeds its resource"; return false;
        }
    }
    // RGB/XYZ and structural validity alone do not prove the profile is sRGB.
    // The host selects the pinned, provenance-recorded sRGB resource.
    return true;
}

#ifdef _WIN32
class NewFile {
public:
    explicit NewFile(std::string& error) : error_(error) {}
    ~NewFile() {
        if (handle_ == INVALID_HANDLE_VALUE) return;
        if (!committed_) {
            // Delete the object whose handle this call owns. Reopening a path
            // to remove it could accidentally remove somebody else's file.
            FILE_DISPOSITION_INFO disposition{TRUE};
            if (!SetFileInformationByHandle(handle_, FileDispositionInfo, &disposition, sizeof disposition)) {
                // Destruction may be unwinding an allocation failure; keep
                // handle cleanup non-throwing even if the message cannot grow.
                const DWORD failure = GetLastError();
                try { error_ += "; partial TIFF cleanup failed (Windows error " + std::to_string(failure) + ")"; }
                catch (...) {}
            }
        }
        CloseHandle(handle_);
    }
    bool open(const std::filesystem::path& path) {
        handle_ = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE | DELETE, 0, nullptr, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle_ != INVALID_HANDLE_VALUE) return true;
        error_ = "cannot create TIFF without overwriting (Windows error " + std::to_string(GetLastError()) + ")";
        return false;
    }
    bool write(const uint8_t* data, size_t bytes) {
        while (bytes) {
            const DWORD requested = DWORD(std::min<size_t>(bytes, 1u << 20));
            DWORD written = 0;
            if (!WriteFile(handle_, data, requested, &written, nullptr) || written == 0) {
                error_ = "TIFF write failed (Windows error " + std::to_string(GetLastError()) + ")";
                return false;
            }
            data += written;
            bytes -= written;
        }
        return true;
    }
    bool commit() {
        if (!FlushFileBuffers(handle_)) {
            error_ = "TIFF flush failed (Windows error " + std::to_string(GetLastError()) + ")";
            return false;
        }
        committed_ = true;
        return true;
    }
    void* release() noexcept {
        const HANDLE handle = handle_;
        handle_ = INVALID_HANDLE_VALUE;
        return handle;
    }
private:
    HANDLE handle_ = INVALID_HANDLE_VALUE;
    bool committed_ = false;
    std::string& error_;
};
#endif

struct Field { uint16_t tag, type; uint32_t count, value; };

bool write_srgb_tiff_impl(const std::filesystem::path& destination, const uint16_t* rgba,
                          uint32_t width, uint32_t height, uint32_t row_stride_px,
                          const std::filesystem::path& srgb_icc_path,
                          void** native_handle, std::string& error) {
    error.clear();
#ifndef _WIN32
    error = "the native TIFF file writer currently requires Windows";
    return false;
#else
    try {
        if (!rgba || !width || !height || row_stride_px < width || destination.empty()) {
            error = "invalid TIFF image pointer, dimensions, row stride, or destination"; return false;
        }
        const uint64_t pixels = uint64_t(width) * height;
        if (uint64_t(row_stride_px) * height > std::numeric_limits<size_t>::max() / 8 ||
            pixels > std::numeric_limits<uint32_t>::max() / 6) {
            error = "image exceeds the addressable input or classic TIFF 4 GiB limit"; return false;
        }
        const uint64_t image_bytes = pixels * 6;
        std::vector<uint8_t> profile;
        if (!load_profile(srgb_icc_path, profile, error)) return false;

        constexpr uint16_t field_count = 17;
        const uint32_t rows_per_strip = std::min(height, 64u);
        const uint32_t strip_count = (height - 1) / rows_per_strip + 1;
        std::vector<uint8_t> header(8 + 2 + size_t(field_count) * 12 + 4, 0);
        auto payload = [&](size_t bytes) -> uint32_t {
            while (header.size() % 4) header.push_back(0);
            const uint32_t offset = uint32_t(header.size());
            if (bytes > std::numeric_limits<uint32_t>::max() - header.size())
                throw std::length_error("TIFF metadata exceeds 32-bit offsets");
            header.resize(header.size() + bytes, 0);
            return offset;
        };
        const uint32_t bits = payload(6);
        const uint32_t samples = payload(6);
        for (size_t i = 0; i < 3; ++i) { le16(header, bits + 2 * i, 16); le16(header, samples + 2 * i, 1); }
        const uint32_t resolution = payload(8);
        le32(header, resolution, 1); le32(header, resolution + 4, 1);
        constexpr char software[] = "SpektraLab Windows host";
        const uint32_t software_at = payload(sizeof software);
        std::memcpy(header.data() + software_at, software, sizeof software);
        const uint32_t icc_at = payload(profile.size());
        std::memcpy(header.data() + icc_at, profile.data(), profile.size());
        const uint32_t offsets_at = strip_count > 1 ? payload(size_t(strip_count) * 4) : 0;
        const uint32_t counts_at = strip_count > 1 ? payload(size_t(strip_count) * 4) : 0;
        while (header.size() % 4) header.push_back(0);
        const uint64_t file_bytes = header.size() + image_bytes;
        if (file_bytes > std::numeric_limits<uint32_t>::max()) {
            error = "image and metadata exceed the classic TIFF 4 GiB limit"; return false;
        }
        const uint32_t pixel_start = uint32_t(header.size());
        for (uint32_t strip = 0; strip < strip_count; ++strip) {
            const uint32_t y = strip * rows_per_strip;
            const uint32_t rows = std::min(rows_per_strip, height - y);
            if (strip_count > 1) {
                le32(header, offsets_at + size_t(strip) * 4, uint32_t(pixel_start + uint64_t(y) * width * 6));
                le32(header, counts_at + size_t(strip) * 4, uint32_t(uint64_t(rows) * width * 6));
            }
        }
        const std::array<Field, field_count> fields = {{
            {256, 4, 1, width}, {257, 4, 1, height}, {258, 3, 3, bits},
            {259, 3, 1, 1}, {262, 3, 1, 2},
            {273, 4, strip_count, strip_count > 1 ? offsets_at : pixel_start},
            {274, 3, 1, 1}, {277, 3, 1, 3}, {278, 4, 1, rows_per_strip},
            {279, 4, strip_count, strip_count > 1 ? counts_at : uint32_t(image_bytes)},
            {282, 5, 1, resolution}, {283, 5, 1, resolution}, {284, 3, 1, 1},
            {296, 3, 1, 1}, {305, 2, sizeof software, software_at}, {339, 3, 3, samples},
            {34675, 7, uint32_t(profile.size()), icc_at}
        }};
        header[0] = header[1] = 'I';
        le16(header, 2, 42); le32(header, 4, 8); le16(header, 8, field_count);
        for (size_t i = 0; i < fields.size(); ++i) {
            const Field& field = fields[i];
            const size_t at = 10 + i * 12;
            le16(header, at, field.tag); le16(header, at + 2, field.type);
            le32(header, at + 4, field.count); le32(header, at + 8, field.value);
        }
        std::vector<uint8_t> strip_pixels(size_t(width) * rows_per_strip * 6);
        NewFile file(error);
        if (!file.open(destination) || !file.write(header.data(), header.size())) return false;
        for (uint32_t y = 0; y < height;) {
            const uint32_t rows = std::min(rows_per_strip, height - y);
            size_t at = 0;
            for (uint32_t row = 0; row < rows; ++row) {
                const uint16_t* src = rgba + (size_t(y) + row) * row_stride_px * 4;
                for (uint32_t x = 0; x < width; ++x) {
                    if (src[size_t(x) * 4 + 3] != 65535) {
                        error = "RGB TIFF export requires opaque alpha"; return false;
                    }
                    for (size_t channel = 0; channel < 3; ++channel) {
                        le16(strip_pixels, at, src[size_t(x) * 4 + channel]);
                        at += 2;
                    }
                }
            }
            if (!file.write(strip_pixels.data(), at)) return false;
            y += rows;
        }
        if (!file.commit()) return false;
        if (native_handle) *native_handle = file.release();
        return true;
    } catch (const std::exception& exc) {
        error = std::string("TIFF export failed: ") + exc.what() +
                (error.empty() ? "" : "; " + error);
        return false;
    }
#endif
}

}  // namespace

bool write_srgb_tiff(const std::filesystem::path& destination, const uint16_t* rgba,
                     uint32_t width, uint32_t height, uint32_t row_stride_px,
                     const std::filesystem::path& srgb_icc_path, std::string& error) {
    return write_srgb_tiff_impl(destination, rgba, width, height, row_stride_px,
                               srgb_icc_path, nullptr, error);
}

bool write_srgb_tiff_held(const std::filesystem::path& destination, const uint16_t* rgba,
                          uint32_t width, uint32_t height, uint32_t row_stride_px,
                          const std::filesystem::path& srgb_icc_path,
                          void*& native_handle, std::string& error) {
    native_handle = nullptr;
    return write_srgb_tiff_impl(destination, rgba, width, height, row_stride_px,
                               srgb_icc_path, &native_handle, error);
}

}  // namespace spk::io
