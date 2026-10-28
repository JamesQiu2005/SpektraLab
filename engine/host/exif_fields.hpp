#pragma once
#include <cstdint>
#include <map>
#include <vector>

namespace spkhost {
// Self-contained standard EXIF values in little-endian TIFF representation.
// Never retain source offsets, MakerNote, GPS, thumbnails or pixel dimensions.
struct ExifValue { uint16_t type = 0; uint32_t count = 0; std::vector<uint8_t> bytes; };
using ExifValues = std::map<uint16_t, ExifValue>;
inline bool portable_exif_tag(uint16_t tag) {
    switch (tag) {
    case 0x829A: case 0x829D: case 0x8827: case 0x9003: case 0x920A: case 0xA434:
    case 0x8822: case 0x8824: case 0x8828: case 0x8830: case 0x8831: case 0x8832: case 0x8833:
    case 0x9004: case 0x9010: case 0x9011: case 0x9012: case 0x9201: case 0x9202: case 0x9203:
    case 0x9204: case 0x9205: case 0x9206: case 0x9207: case 0x9208: case 0x9209:
    case 0x9286: case 0x9290: case 0x9291: case 0x9292:
    case 0xA000: case 0xA20B: case 0xA20E: case 0xA20F: case 0xA210: case 0xA214: case 0xA215:
    case 0xA217: case 0xA300: case 0xA301: case 0xA401: case 0xA402: case 0xA403: case 0xA404:
    case 0xA405: case 0xA406: case 0xA407: case 0xA408: case 0xA409: case 0xA40A: case 0xA40C:
    case 0xA420: case 0xA430: case 0xA431: case 0xA432: case 0xA433: case 0xA435:
        return true;
    default: return false;
    }
}
}
