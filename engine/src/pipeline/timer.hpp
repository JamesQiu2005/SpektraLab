// timer.hpp -- `Pipeline::Timer`, shared by the translation units that hold
// nodes (`pipeline.cpp`, `scene_latitude.cpp`). Internal: include after
// `pipeline.hpp`.
#pragma once
#include <chrono>
#include <string>

#include "pipeline.hpp"

namespace spk {

// A node's timing, recorded under the reference's label so a per-node
// regression is attributable to the same name on both engines.
struct Pipeline::Timer {
    Timer(Pipeline* p, const char* label) : p_(p), label_(label) {
        if (p_->progress_) {
            p_->progress_->stage = label_;
            if (p_->progress_->detailed) start_ = std::chrono::steady_clock::now();
        }
    }
    ~Timer() {
        if (!p_->progress_) return;
        if (p_->progress_->detailed) {
            // Wait for the work this node encoded, so the number is GPU time
            // and not encode time. Costs the batching for the whole run.
            std::string error;
            p_->gpu_->flush(error);
            const double ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start_).count();
            p_->progress_->node_ms[label_] += ms;
        }
        p_->progress_->fired += 1;
    }
    Pipeline* p_;
    const char* label_;
    std::chrono::steady_clock::time_point start_;
};

}  // namespace spk
