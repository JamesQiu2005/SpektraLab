#include "minilab.hpp"
#include "file_path.hpp"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>

namespace spk {
namespace {
uint64_t hash(const void* data, size_t count) {
    const auto* bytes = static_cast<const unsigned char*>(data);
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < count; ++i) h = (h ^ bytes[i]) * 1099511628211ULL;
    return h;
}
std::string digest(const void* data, size_t count) {
    char result[17];
    std::snprintf(result, sizeof(result), "%016llx", static_cast<unsigned long long>(hash(data, count)));
    return result;
}
bool read_bytes(const std::string& path, std::vector<char>& bytes, size_t limit) {
    std::ifstream file(file_path(path), std::ios::binary | std::ios::ate);
    if (!file || file.tellg() < 0 || uint64_t(file.tellg()) > limit) return false;
    bytes.resize(size_t(file.tellg()));
    file.seekg(0);
    file.read(bytes.data(), bytes.size());
    return bool(file);
}
}

bool MinilabCatalog::init(const std::string& dir, std::string& error) {
    resources_dir_ = dir;
    std::vector<char> bytes;
    if (!read_bytes(dir + "/minilab/index.json", bytes, 1 << 20) ||
        !Json::parse(std::string(bytes.begin(), bytes.end()), index_, error) ||
        index_.at("version").as_int() != 1 || !index_.at("pairs").is_object()) {
        error = "minilab/index.json: missing or invalid v2 print catalog";
        return false;
    }
    return true;
}

bool MinilabCatalog::load(const std::string& film, const std::string& paper, const std::string& space,
                         MinilabTable& table, std::string& error) const {
    table = {};
    const Json& pair = index_.at("pairs").at(film + "|" + paper);
    if (pair.is_null()) return true;
    // The calibration's result is paper CMY, independent of the scan's output
    // RGB space. Use the qualified ProPhoto calibration for other destinations;
    // keep the separately qualified sRGB calibration exact where available.
    const Json& entry = pair.at(space == "sRGB" ? "sRGB" : "ProPhoto RGB");
    const std::string name = entry.at("file").as_string();
    if (name.empty() || name.find('/') != std::string::npos || name.find('\\') != std::string::npos ||
        name.find("..") != std::string::npos || entry.at("side").as_int() != 65) {
        error = "minilab: invalid catalog entry for " + film + " / " + paper;
        return false;
    }
    // Pin the raw profile files as well as the payload. Runtime controls still
    // operate on the negative; a different material needs a different bake.
    //
    // An alias profile (`derived_from`) carries no measured data of its own: its
    // JSON is a name change and an anti-halation switch. Hashing it alone would
    // let the inherited material move underneath a qualified table, so a catalog
    // entry may also declare `<role>_base_hash`, which pins the file's own
    // `derived_from` base. Entries without it keep the older, narrower check; an
    // entry that declares one on a profile that is not an alias is an error, not
    // a silently ignored field.
    struct Pin {
        const std::string& stock;
        const char* hash_key;
        const char* base_key;
    };
    const Pin pins[2] = {{film, "film_hash", "film_base_hash"},
                         {paper, "paper_hash", "paper_base_hash"}};
    for (const Pin& pin : pins) {
        std::vector<char> bytes;
        if (!read_bytes(resources_dir_ + "/profiles/" + pin.stock + ".json", bytes, 4 << 20) ||
            digest(bytes.data(), bytes.size()) != entry.at(pin.hash_key).as_string()) {
            error = "minilab: profile identity changed for " + pin.stock;
            return false;
        }
        const Json& want_base = entry.at(pin.base_key);
        if (!want_base.is_string()) continue;
        Json profile;
        std::string parse_error;
        if (!Json::parse(std::string(bytes.begin(), bytes.end()), profile, parse_error)) {
            error = "minilab: cannot read the base of profile " + pin.stock + " (" + parse_error + ")";
            return false;
        }
        const std::string base = profile.at("derived_from").as_string();
        if (base.empty()) {
            error = "minilab: " + pin.stock + " declares a base hash but is not a derived profile";
            return false;
        }
        std::vector<char> base_bytes;
        if (!read_bytes(resources_dir_ + "/profiles/" + base + ".json", base_bytes, 4 << 20) ||
            digest(base_bytes.data(), base_bytes.size()) != want_base.as_string()) {
            error = "minilab: inherited profile identity changed for " + pin.stock + " (" + base + ")";
            return false;
        }
    }
    std::vector<char> bytes;
    constexpr size_t expected = 28 + size_t(65) * 65 * 65 * 3 * sizeof(float);
    if (!read_bytes(resources_dir_ + "/minilab/" + name, bytes, expected) || bytes.size() != expected ||
        digest(bytes.data(), bytes.size()) != entry.at("hash").as_string()) {
        error = "minilab: missing, changed or corrupt table " + name;
        return false;
    }
    float hi[3];
    std::memcpy(&table.side, bytes.data(), 4);
    std::memcpy(table.lo, bytes.data() + 4, 12);
    std::memcpy(hi, bytes.data() + 16, 12);
    if (table.side != 65) { error = "minilab: wrong table dimensions"; return false; }
    for (int c = 0; c < 3; ++c) {
        if (!std::isfinite(table.lo[c]) || !std::isfinite(hi[c]) || !(hi[c] > table.lo[c])) {
            error = "minilab: invalid log-positive domain"; return false;
        }
        table.inv_span[c] = 1.0f / (hi[c] - table.lo[c]);
    }
    table.values.resize(size_t(table.side) * table.side * table.side * 3);
    std::memcpy(table.values.data(), bytes.data() + 28, table.values.size() * sizeof(float));
    for (float v : table.values) if (!std::isfinite(v)) { error = "minilab: nonfinite payload"; return false; }
    return true;
}
} // namespace spk
