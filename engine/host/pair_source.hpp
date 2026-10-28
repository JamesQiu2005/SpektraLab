#pragma once
#include "image_io.hpp"
#include "json.hpp"
#include <functional>
#include <list>
#include <map>
#include <memory>

namespace spkhost {
// A pair is a source recipe: render each hole in linear ProPhoto, quantize to
// binary16 as PairComposer.render does, then apply its exposure into one strip.
// Cached and uncached paths share that boundary. Only the current decode is
// float32; reusable hole pictures have a strict count and byte budget.
class PairSource {
public:
    using Decode = std::function<bool(const std::filesystem::path&, const spk::Json&, FloatImage&, Probe&, std::string&)>;
    using Meter = std::function<double(const FloatImage&, const std::string&)>;
    using Checkpoint = std::function<void()>;
    struct Description {
        uint32_t width = 0, height = 0, hole_width = 0, hole_height = 0, advance = 0;
        std::array<Probe, 2> probes;
        std::array<std::optional<spk::io::RawMetadata>, 2> raw_metadata;
        std::array<double, 2> gains{1., 1.};
        std::array<bool, 2> available{};
        std::array<std::string, 2> errors;
        std::array<std::string, 2> meter_keys;
        spk::Json gates = spk::Json::array();
    };
    static Description describe(const spk::Json& pair);
    static spk::Json carry_meter_readings(const spk::Json& pair, const spk::Json& params, const spk::Json& prior);
    static std::string signature(const spk::Json& pair, const spk::Json& params, const spk::Json& prior = {});
    bool compose(const spk::Json& pair, const spk::Json& params, FloatImage& out,
                 Description& description, std::array<std::optional<double>, 2>& metered,
                 const Decode& decode, const Meter& meter, const Checkpoint& checkpoint, std::string& error,
                 uint32_t max_edge = 0);
    size_t cached_bytes() const;
    void clear() { images_.clear(); meters_.clear(); }
private:
    struct Picture {
        uint32_t width, height;
        std::vector<uint16_t> rgb;
        Probe probe;
        std::optional<spk::io::RawMetadata> raw_metadata;
    };
    struct Entry { std::string key; std::shared_ptr<Picture> picture; };
    std::list<Entry> images_;
    std::map<std::string, double> meters_;
};
}
