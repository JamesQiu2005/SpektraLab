// Independent scan lines: preserve each line's accumulation order while
// bounding host worker count. No process-wide thread pool or environment state.
#pragma once
#include <algorithm>
#include <cstdint>
#include <thread>
#include <utility>
#include <vector>

namespace spk {
template <class F>
void portable_for_each_line(uint32_t lines, F&& fn, uint32_t worker_limit = 0) {
    if (!lines) return;
    const uint32_t limit = worker_limit ? worker_limit :
        std::min(8u, std::max(1u, std::thread::hardware_concurrency()));
    const uint32_t workers = std::min(lines, limit);
    auto run = [&](uint32_t worker) {
        for (uint32_t line = worker; line < lines; line += workers) fn(line);
    };
    std::vector<std::jthread> threads;
    threads.reserve(workers - 1);
    for (uint32_t worker = 1; worker < workers; ++worker) threads.emplace_back(run, worker);
    run(0);
    // jthread joins before the caller can consume the completed output.
}
}  // namespace spk
