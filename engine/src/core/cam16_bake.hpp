// Versioned native-endian float64 setup artifact. A metadata mismatch (including
// architecture-dependent math) safely falls back to computing the table.
// Revision must change whenever CAM16 inverse, gamut test, or search semantics change.
#pragma once
#include "cam16.hpp"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>

namespace spk::cam16_bake {
using Bytes = std::vector<unsigned char>;

inline uint64_t hash(const void* data, size_t size) {
    const auto* bytes = static_cast<const unsigned char*>(data);
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < size; ++i) h = (h ^ bytes[i]) * 1099511628211ULL;
    return h;
}

template<class T> inline void append(Bytes& bytes, const T& value) {
    const auto* p = reinterpret_cast<const unsigned char*>(&value);
    bytes.insert(bytes.end(), p, p + sizeof(T));
}

inline Bytes prefix(const std::string& cs, const Cam16Setup& setup) {
    Bytes bytes;
    for (char c : std::string("SPKCAM16BAKE")) append(bytes, c);
    append(bytes, uint64_t(1)); // format + algorithm revision
    append(bytes, uint64_t(cs.size()));
    bytes.insert(bytes.end(), cs.begin(), cs.end());
    for (double v : {setup.n, setup.F_L, setup.N_bb, setup.N_cb, setup.z, setup.A_w,
                     setup.c, setup.N_c, setup.white_Jp, kCam16LA, kCam16Yb, kCam16F,
                     kCam16c, kCam16Nc, 150.0, 1e-6}) append(bytes, v);
    for (double v : setup.D_rgb) append(bytes, v);
    for (const auto& row : setup.m_to_xyz.m) for (double v : row) append(bytes, v);
    for (const auto& row : setup.m_to_rgb.m) for (double v : row) append(bytes, v);
    append(bytes, uint64_t(kCmaxNL));
    append(bytes, uint64_t(kCmaxNH));
    append(bytes, uint64_t(kCmaxNBisect));
    for (double v : setup.l_grid) append(bytes, v);
    for (double v : setup.h_grid) append(bytes, v);
    return bytes;
}

inline std::filesystem::path path(const char* dir, const std::string& cs) {
    char name[32];
    std::snprintf(name, sizeof(name), "%016llx.cam16", static_cast<unsigned long long>(hash(cs.data(), cs.size())));
    return std::filesystem::path(dir) / name;
}

inline bool read(const char* dir, const std::string& cs, Cam16Setup& setup) {
    const auto expected = prefix(cs, setup);
    const size_t count = kCmaxNL * kCmaxNH, size = count * sizeof(double);
    std::ifstream file(path(dir, cs), std::ios::binary | std::ios::ate);
    if (!file || file.tellg() != std::streamoff(expected.size() + sizeof(uint64_t) + size)) return false;
    file.seekg(0);
    Bytes header(expected.size());
    uint64_t checksum = 0;
    Vec table(count);
    file.read(reinterpret_cast<char*>(header.data()), header.size());
    file.read(reinterpret_cast<char*>(&checksum), sizeof(checksum));
    file.read(reinterpret_cast<char*>(table.data()), size);
    if (!file || header != expected || checksum != hash(table.data(), size)) return false;
    for (double v : table) if (!std::isfinite(v) || v < 0.0 || v > 150.0) return false;
    setup.c_max_table = std::move(table);
    return true;
}

inline bool write(const char* dir, const std::string& cs, const Cam16Setup& setup) {
    if (setup.c_max_table.size() != kCmaxNL * kCmaxNH) return false;
    auto bytes = prefix(cs, setup);
    const size_t size = setup.c_max_table.size() * sizeof(double);
    append(bytes, hash(setup.c_max_table.data(), size));
    const auto* p = reinterpret_cast<const unsigned char*>(setup.c_max_table.data());
    bytes.insert(bytes.end(), p, p + size);
    std::ofstream file(path(dir, cs), std::ios::binary | std::ios::trunc);
    file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    return bool(file);
}
} // namespace spk::cam16_bake
