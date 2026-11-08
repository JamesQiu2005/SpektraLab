// One private, lossless pre-grain SSD slot for the entire process. No mapped
// checkpoint, retained GPU plane, per-session file collection or runtime path.
#pragma once
#ifdef __APPLE__
#include "image.hpp"
#include <cstdio>
#include <mutex>
#include <optional>
#include <string>

namespace spk {
struct CheckpointInfo {
    uint32_t w = 0, h = 0, frame_w = 0, frame_h = 0;
    std::optional<double> exposure;
    double prefix_ms = 0;
};
class DiskCheckpoint {
public:
    static DiskCheckpoint& shared();
    ~DiskCheckpoint();
    void release(const std::string& owner);
    bool restore(const std::string& owner, const std::string& key, gpu::Gpu* gpu,
                 Image& out, CheckpointInfo& info);
    bool save(const std::string& owner, const std::string& key, gpu::Gpu* gpu,
              const Image& image, const CheckpointInfo& info);
private:
    void clear(); // caller holds lock_
    std::mutex lock_;
    FILE* file_ = nullptr;
    std::string owner_, key_;
    CheckpointInfo info_;
    size_t bytes_ = 0;
    double write_ms_ = 0;
};
} // namespace spk
#endif
