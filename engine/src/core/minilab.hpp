// Pair-specific log-positive -> paper-density tables. This is a print transform,
// not a replacement for the measured film or paper material data.
#pragma once
#include "json.hpp"
#include <cstdint>
#include <string>
#include <vector>

namespace spk {
struct MinilabTable {
    uint32_t side = 0;
    float lo[3]{}, inv_span[3]{};
    std::vector<float> values;
};

class MinilabCatalog {
public:
    bool init(const std::string& resources_dir, std::string& error);
    // Unsupported pairs remain on their existing optical path. A listed pair
    // with missing/corrupt resources is an error, never an optical substitution.
    bool load(const std::string& film, const std::string& paper, const std::string& space,
              MinilabTable& table, std::string& error) const;
private:
    std::string resources_dir_;
    Json index_;
};
} // namespace spk
