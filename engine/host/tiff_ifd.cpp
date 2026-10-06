#include "tiff_ifd.hpp"

#include <cstring>

#include "image_io.hpp"

namespace spkhost {

bool TiffBytes::header(uint32_t& first_ifd) {
    if (n_ < 8) return false;
    if (d_[0] == 'I' && d_[1] == 'I') little_ = true;
    else if (d_[0] == 'M' && d_[1] == 'M') little_ = false;
    else return false;
    if (u16(2) != 42) return false;
    first_ifd = u32(4);
    return true;
}

uint16_t TiffBytes::u16(size_t at) const {
    if (!in_range(at, 2)) return 0;
    return little_ ? uint16_t(d_[at] | (d_[at + 1] << 8)) : uint16_t((d_[at] << 8) | d_[at + 1]);
}

uint32_t TiffBytes::u32(size_t at) const {
    if (!in_range(at, 4)) return 0;
    const uint32_t a = d_[at], b = d_[at + 1], c = d_[at + 2], e = d_[at + 3];
    return little_ ? (a | (b << 8) | (c << 16) | (e << 24)) : ((a << 24) | (b << 16) | (c << 8) | e);
}

size_t TiffBytes::type_size(uint16_t type) {
    switch (type) {
        case 1: case 2: case 6: case 7: return 1;
        case 3: case 8: return 2;
        case 4: case 9: case 11: case 13: return 4;
        case 5: case 10: case 12: return 8;
        default: return 0;
    }
}

bool TiffBytes::read_ifd(uint32_t at, Ifd& out, uint32_t* next) const {
    out.clear();
    if (!in_range(at, 2)) return false;
    const uint16_t count = u16(at);
    if (!in_range(at + 2, size_t(count) * 12 + 4)) return false;
    for (uint16_t i = 0; i < count; ++i) {
        const size_t e = at + 2 + size_t(i) * 12;
        Entry entry;
        const uint16_t tag = u16(e);
        entry.type = u16(e + 2);
        entry.count = u32(e + 4);
        const size_t unit = type_size(entry.type);
        if (!unit) continue;
        const uint64_t total = uint64_t(unit) * entry.count;
        if (total <= 4) entry.value_at = e + 8;
        else {
            entry.value_at = u32(e + 8);
            if (!in_range(entry.value_at, size_t(total))) continue;
        }
        out[tag] = entry;
    }
    if (next) *next = u32(at + 2 + size_t(count) * 12);
    return true;
}

bool TiffBytes::numbers(const Ifd& ifd, uint16_t tag, std::vector<double>& out) const {
    out.clear();
    auto it = ifd.find(tag);
    if (it == ifd.end()) return false;
    const Entry& e = it->second;
    const size_t unit = type_size(e.type);
    out.reserve(e.count);
    for (uint32_t i = 0; i < e.count; ++i) {
        const size_t at = e.value_at + size_t(i) * unit;
        switch (e.type) {
            case 1: case 7: out.push_back(d_[at]); break;
            case 6: out.push_back(int8_t(d_[at])); break;
            case 3: out.push_back(u16(at)); break;
            case 8: out.push_back(int16_t(u16(at))); break;
            case 4: case 13: out.push_back(u32(at)); break;
            case 9: out.push_back(int32_t(u32(at))); break;
            case 5: {
                const uint32_t num = u32(at), den = u32(at + 4);
                out.push_back(den ? double(num) / den : 0.0);
                break;
            }
            case 10: {
                const int32_t num = int32_t(u32(at)), den = int32_t(u32(at + 4));
                out.push_back(den ? double(num) / den : 0.0);
                break;
            }
            case 11: { uint32_t bits = u32(at); float f; std::memcpy(&f, &bits, 4); out.push_back(f); break; }
            case 12: {
                uint64_t lo = u32(at), hi = u32(at + 4);
                uint64_t bits = little_ ? (lo | (hi << 32)) : ((lo << 32) | hi);
                double v; std::memcpy(&v, &bits, 8); out.push_back(v);
                break;
            }
            default: return false;
        }
    }
    return !out.empty();
}

bool TiffBytes::number(const Ifd& ifd, uint16_t tag, double& out) const {
    std::vector<double> v;
    if (!numbers(ifd, tag, v)) return false;
    out = v[0];
    return true;
}

bool TiffBytes::text(const Ifd& ifd, uint16_t tag, std::string& out) const {
    auto it = ifd.find(tag);
    if (it == ifd.end() || (it->second.type != 2 && it->second.type != 7)) return false;
    const char* s = reinterpret_cast<const char*>(d_ + it->second.value_at);
    size_t len = 0;
    while (len < it->second.count && s[len]) ++len;
    out.assign(s, len);
    while (!out.empty() && (out.back() == ' ')) out.pop_back();
    return !out.empty();
}

bool TiffBytes::bytes(const Ifd& ifd, uint16_t tag, std::vector<uint8_t>& out) const {
    auto it = ifd.find(tag);
    if (it == ifd.end()) return false;
    const size_t len = type_size(it->second.type) * it->second.count;
    out.assign(d_ + it->second.value_at, d_ + it->second.value_at + len);
    return true;
}

void read_exif_metadata(TiffBytes& tiff, uint32_t ifd0, Metadata& meta) {
    TiffBytes::Ifd root;
    if (!tiff.read_ifd(ifd0, root)) return;
    std::string s;
    double v;
    if (tiff.text(root, 0x010F, s)) meta.make = s;
    if (tiff.text(root, 0x0110, s)) meta.model = s;
    if (tiff.number(root, 0x0112, v) && v >= 1 && v <= 8) meta.orientation = int(v);
    if (tiff.text(root, 0x0132, s) && meta.datetime_original.empty()) meta.datetime_original = s;
    double exif_at = 0;
    if (!tiff.number(root, 0x8769, exif_at)) return;
    TiffBytes::Ifd exif;
    if (!tiff.read_ifd(uint32_t(exif_at), exif)) return;
    if (tiff.number(exif, 0x829A, v) && v > 0) meta.shutter_s = v;
    if (tiff.number(exif, 0x829D, v) && v > 0) meta.aperture = v;
    if (tiff.number(exif, 0x8827, v) && v > 0) meta.iso = v;
    if (tiff.number(exif, 0x920A, v) && v > 0) meta.focal_mm = v;
    if (tiff.text(exif, 0x9003, s)) meta.datetime_original = s;
    if (tiff.text(exif, 0xA434, s)) meta.lens = s;
}

}  // namespace spkhost
