// Device-lost fail-fast gate.
//
// A real loss needs a Windows TDR or a driver fault, which no test can ask for.
// So the latch is injected instead, and what this checks is the policy that
// follows it: after the first loss, every request that would do work must fail
// with the one stored diagnosis, and must do so before it allocates a buffer,
// grows or fills staging memory, or submits a command. The pool accounting is
// the witness -- it cannot stay byte-identical if any of that happened.
//
// Cleanup is the deliberate exception: release() and trim_pool() still run,
// because a session has to be able to free what it holds and the Vulkan
// specification defines those calls on a lost device.
#include "gpu/gpu.hpp"
#include "vulkan_test_hooks.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

using spk::gpu::Arg;
using spk::gpu::BufferRef;
using spk::gpu::Gpu;

bool require(bool condition, const char* message, std::string& error) {
    if (!condition) error = message;
    return condition;
}

// The pool counters that a refused request must leave alone: a buffer made,
// reused, or a queued allocation would move at least one of them.
struct Snapshot {
    size_t buffers = 0;
    size_t total_bytes = 0;
    size_t live_bytes = 0;
    uint64_t allocations = 0;
    uint64_t reuses = 0;
};

Snapshot take(Gpu* gpu) {
    const auto stats = gpu->pool_stats();
    Snapshot out;
    out.buffers = stats.buffers;
    out.total_bytes = stats.total_bytes;
    out.live_bytes = stats.live_bytes;
    out.allocations = stats.audit.allocations;
    out.reuses = stats.audit.reuses;
    return out;
}

bool same_pool(const Snapshot& a, const Snapshot& b) {
    return a.buffers == b.buffers && a.total_bytes == b.total_bytes &&
           a.live_bytes == b.live_bytes && a.allocations == b.allocations &&
           a.reuses == b.reuses;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: spk_vulkan_device_lost <resources>\n");
        return 2;
    }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) {
        std::fprintf(stderr, "Vulkan device: %s\n", error.c_str());
        return 1;
    }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());

    constexpr size_t bytes = 64 * 1024;
    std::vector<uint32_t> payload(bytes / sizeof(uint32_t), 0x5a5a5a5au);
    auto source = gpu->upload(payload.data(), bytes, error);
    auto target = gpu->alloc(bytes, error);
    if (!source || !target || !gpu->flush(error)) {
        std::fprintf(stderr, "device-lost fixture: %s\n", error.c_str());
        return 1;
    }

    const Snapshot before = take(gpu.get());
    if (!spk::gpu::test_latch_device_lost(gpu.get(), error)) {
        std::fprintf(stderr, "device-lost injection: %s\n", error.c_str());
        return 1;
    }

    // Every later request fails, and each one repeats the latched diagnosis
    // rather than inventing a new one. `first` is that diagnosis.
    std::string first;
    size_t refused = 0;
    auto refuses = [&](const char* label, auto&& operation) {
        std::string diagnostic;
        if (operation(diagnostic)) {
            error = std::string("accepted after the device was lost: ") + label;
            return false;
        }
        if (diagnostic.empty()) {
            error = std::string("failed without a diagnosis: ") + label;
            return false;
        }
        if (first.empty()) {
            first = diagnostic;
        } else if (diagnostic != first) {
            error = std::string("diagnosis drifted at ") + label + ": " + diagnostic;
            return false;
        }
        ++refused;
        return true;
    };

    // The four families the reviewer named: allocation, upload preparation,
    // readback preparation, and command submission.
    if (!refuses("alloc", [&](std::string& e) { return bool(gpu->alloc(bytes, e)); }) ||
        !refuses("alloc_zeroed", [&](std::string& e) { return bool(gpu->alloc_zeroed(bytes, e)); }) ||
        !refuses("alloc_persistent", [&](std::string& e) { return bool(gpu->alloc_persistent(bytes, e)); }) ||
        !refuses("upload", [&](std::string& e) { return bool(gpu->upload(payload.data(), bytes, e)); }) ||
        !refuses("upload_persistent",
                 [&](std::string& e) { return bool(gpu->upload_persistent(payload.data(), bytes, e)); }) ||
        !refuses("upload_f32", [&](std::string& e) {
            std::vector<double> narrow(bytes / sizeof(float), 0.5);
            return bool(gpu->upload_f32(narrow.data(), narrow.size(), e));
        }) ||
        !refuses("copy", [&](std::string& e) {
            return gpu->copy(target.get(), 0, source.get(), 0, bytes, e);
        }) ||
        !refuses("dispatch", [&](std::string& e) {
            const uint32_t n[1] = {1};
            return gpu->dispatch("spk_mul",
                {Arg::buf(source), Arg::buf(source), Arg::inline_bytes(n, 1), Arg::buf(target)},
                1, e);
        }) ||
        !refuses("flush", [&](std::string& e) { return gpu->flush(e); })) {
        std::fprintf(stderr, "device-lost fail-fast: %s\n", error.c_str());
        return 1;
    }

    // Readback has a host range to protect as well: a refused read must not
    // copy one byte into the caller's buffer.
    std::vector<uint32_t> host(bytes / sizeof(uint32_t), 0xa5a5a5a5u);
    const auto host_before = host;
    if (!refuses("read", [&](std::string& e) { return gpu->read(source.get(), 0, host.data(), bytes, e); }) ||
        !require(host == host_before, "a refused read wrote into the caller's buffer", error)) {
        std::fprintf(stderr, "device-lost readback: %s\n", error.c_str());
        return 1;
    }
    if (!require(first.find("device was lost") != std::string::npos,
                 "the latched diagnosis does not name the lost device", error)) {
        std::fprintf(stderr, "device-lost diagnosis: %s\n", error.c_str());
        return 1;
    }

    // None of that touched the pool: no buffer was created, reused or queued.
    const Snapshot after = take(gpu.get());
    if (!require(same_pool(before, after),
                 "a refused request allocated, reused, or released a buffer", error)) {
        std::fprintf(stderr, "device-lost pool: %s (buffers %zu -> %zu, total %zu -> %zu)\n",
                     error.c_str(), before.buffers, after.buffers, before.total_bytes,
                     after.total_bytes);
        return 1;
    }

    // Cleanup stays available: the session can still free what it holds, and
    // the device is never asked to render again.
    source.reset();
    target.reset();
    const size_t freed = gpu->trim_pool(0);
    const Snapshot released = take(gpu.get());
    if (!require(freed >= bytes && released.buffers == 0 && released.total_bytes == 0,
                 "cleanup after a lost device did not free the pool", error)) {
        std::fprintf(stderr, "device-lost cleanup: %s\n", error.c_str());
        return 1;
    }

    std::printf("device lost: %zu requests refused with one latched diagnosis, "
                "%zu buffers and %zu bytes came back on cleanup\n",
                refused, after.buffers, freed);
    return 0;
}
