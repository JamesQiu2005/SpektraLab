#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

namespace spk::io {

// Host-side export, outside the rendering C API. Pixels must already be
// encoded, bounded sRGB RGBA16 with opaque alpha; no transfer function or
// colour transform is performed here. Rows may include caller-owned padding.
// srgb_icc_path is an explicit trusted sRGB profile resource, never a guessed
// system path. The profile's bytes are embedded unchanged in the TIFF.
//
// Creates an uncompressed little-endian RGB16 classic TIFF with top-left
// orientation and square pixels. Existing paths are never overwritten.
// On failure only the file created by this call is removed, by its open
// Windows handle. An unsuccessful cleanup is included in the error.
bool write_srgb_tiff(const std::filesystem::path& destination, const uint16_t* rgba,
                     uint32_t width, uint32_t height, uint32_t row_stride_px,
                     const std::filesystem::path& srgb_icc_path, std::string& error);

// Internal Windows host variant for transactional output publication. On
// success native_handle receives the still-open, exclusive Windows HANDLE,
// with GENERIC_READ | GENERIC_WRITE | DELETE access. The caller owns it and
// must close it, or mark it for deletion by handle before closing on rollback.
// The handle is positioned at EOF. On failure native_handle is nullptr and
// cleanup follows write_srgb_tiff's contract. Pass an empty output slot.
bool write_srgb_tiff_held(const std::filesystem::path& destination, const uint16_t* rgba,
                          uint32_t width, uint32_t height, uint32_t row_stride_px,
                          const std::filesystem::path& srgb_icc_path,
                          void*& native_handle, std::string& error);

}  // namespace spk::io
