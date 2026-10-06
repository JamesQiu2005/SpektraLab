// tiff_ifd.hpp -- a bounds-checked reader for TIFF-structured bytes: TIFF
// files, and the EXIF blocks inside JPEG (APP1) and PNG (eXIf).
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace spkhost {

class TiffBytes {
public:
    TiffBytes(const uint8_t* data, size_t size) : d_(data), n_(size) {}
    // Reads the header; false when the bytes are not classic TIFF.
    bool header(uint32_t& first_ifd);
    bool little() const { return little_; }
    uint16_t u16(size_t at) const;
    uint32_t u32(size_t at) const;
    bool in_range(size_t at, size_t len) const { return at <= n_ && len <= n_ - at; }
    const uint8_t* data() const { return d_; }
    size_t size() const { return n_; }

    struct Entry {
        uint16_t type = 0;
        uint32_t count = 0;
        size_t value_at = 0;   // where the value bytes start (inline or offset)
    };
    using Ifd = std::map<uint16_t, Entry>;
    // Reads one IFD at `at`; `next` receives the following IFD's offset.
    bool read_ifd(uint32_t at, Ifd& out, uint32_t* next = nullptr) const;

    static size_t type_size(uint16_t type);
    // Values of an entry as numbers (BYTE/SHORT/LONG/RATIONAL/SRATIONAL/FLOAT/DOUBLE...).
    bool numbers(const Ifd& ifd, uint16_t tag, std::vector<double>& out) const;
    bool number(const Ifd& ifd, uint16_t tag, double& out) const;
    bool text(const Ifd& ifd, uint16_t tag, std::string& out) const;
    bool bytes(const Ifd& ifd, uint16_t tag, std::vector<uint8_t>& out) const;

private:
    const uint8_t* d_;
    size_t n_;
    bool little_ = true;
};

struct Metadata;
// Fills make/model/lens/iso/shutter/aperture/focal/datetime/orientation from
// IFD0 and its EXIF sub-IFD. Absent fields are left as they were.
void read_exif_metadata(TiffBytes& tiff, uint32_t ifd0, Metadata& meta);

}  // namespace spkhost
