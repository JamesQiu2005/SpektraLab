// Device-local transfer and lifetime gates. These compare bytes and independent
// expected ranges, including untouched guards and retained buffers.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::BufferRef;
using spk::gpu::Gpu;

bool require(bool condition, const char* message, std::string& error) {
    if (!condition) error = message;
    return condition;
}

bool check_ranges(Gpu* gpu, std::string& error) {
    // Include NaN, infinity and signed zero bit patterns: copies must preserve
    // bits, without treating the transfer as a floating-point calculation.
    const std::vector<uint32_t> input = {0, 0x80000000u, 0x7fc12345u, 0x7f800000u,
        0xff800000u, 0xffffffffu, 0x01234567u, 0x89abcdefu, 0xdeadbeefu, 23, 41, 67};
    constexpr uint32_t sentinel = 0xa55aa55au;
    std::vector<uint32_t> host_input = input, expected(17, sentinel), got;
    const size_t src_bytes = input.size() * sizeof(uint32_t);
    const size_t dst_bytes = expected.size() * sizeof(uint32_t);
    auto src = gpu->upload_persistent(host_input.data(), src_bytes, error);
    auto dst = gpu->upload_persistent(expected.data(), dst_bytes, error);
    if (!src || !dst) return false;
    std::fill(host_input.begin(), host_input.end(), sentinel);
    if (!read_test_buffer(gpu, src, got, error) ||
        !require(got == input, "upload retained or changed the caller's memory", error)) return false;

    if (!gpu->copy(dst.get(), 3 * 4, src.get(), 2 * 4, 5 * 4, error)) return false;
    std::copy_n(input.begin() + 2, 5, expected.begin() + 3);
    // Both source and destination end exactly on the last valid byte.
    if (!gpu->copy(dst.get(), dst_bytes - 4, src.get(), src_bytes - 4, 4, error)) return false;
    expected.back() = input.back();
    if (!read_test_buffer(gpu, dst, got, error) ||
        !require(got == expected, "offset copy changed its payload or surrounding guards", error)) return false;

    std::array<uint32_t, 7> slice;
    slice.fill(sentinel);
    if (!gpu->read(dst.get(), 3 * 4, slice.data() + 1, 5 * 4, error) ||
        !require(slice.front() == sentinel && slice.back() == sentinel &&
                 std::equal(slice.begin() + 1, slice.end() - 1, input.begin() + 2),
                 "offset read changed the host guards or returned the wrong range", error)) return false;

    // Disjoint ranges of one buffer are valid, in both address directions.
    if (!gpu->copy(dst.get(), 10 * 4, dst.get(), 3 * 4, 3 * 4, error)) return false;
    std::copy_n(expected.begin() + 3, 3, expected.begin() + 10);
    if (!gpu->copy(dst.get(), 0, dst.get(), 10 * 4, 3 * 4, error)) return false;
    std::copy_n(expected.begin() + 10, 3, expected.begin());
    if (!gpu->copy(dst.get(), 4, dst.get(), 4, dst_bytes - 4, error) ||
        !gpu->copy(dst.get(), dst_bytes, src.get(), src_bytes, 0, error) ||
        !gpu->read(dst.get(), dst_bytes, nullptr, 0, error) ||
        !read_test_buffer(gpu, dst, got, error) ||
        !require(got == expected, "disjoint, identical, or zero-length copy is incorrect", error)) return false;

    const auto slice_before_rejections = slice;
    size_t rejected = 0;
    auto reject = [&](const char* label, auto operation) {
        std::string diagnostic;
        if (operation(diagnostic) || diagnostic.empty()) {
            error = std::string("invalid transfer accepted or missing diagnostic: ") + label;
            return false;
        }
        ++rejected;
        return true;
    };
    const size_t huge_aligned = std::numeric_limits<size_t>::max() & ~size_t(3);
    if (!reject("null copy destination", [&](auto& e) { return gpu->copy(nullptr, 0, src.get(), 0, 4, e); }) ||
        !reject("null copy source", [&](auto& e) { return gpu->copy(dst.get(), 0, nullptr, 0, 4, e); }) ||
        !reject("destination offset alignment", [&](auto& e) { return gpu->copy(dst.get(), 2, src.get(), 0, 4, e); }) ||
        !reject("source offset alignment", [&](auto& e) { return gpu->copy(dst.get(), 0, src.get(), 2, 4, e); }) ||
        !reject("copy length alignment", [&](auto& e) { return gpu->copy(dst.get(), 0, src.get(), 0, 2, e); }) ||
        !reject("destination overrun", [&](auto& e) { return gpu->copy(dst.get(), dst_bytes, src.get(), 0, 4, e); }) ||
        !reject("source overrun", [&](auto& e) { return gpu->copy(dst.get(), 0, src.get(), src_bytes, 4, e); }) ||
        !reject("overflowing offset", [&](auto& e) { return gpu->copy(dst.get(), huge_aligned, src.get(), 0, 4, e); }) ||
        !reject("overflowing length", [&](auto& e) { return gpu->copy(dst.get(), 4, src.get(), 4, huge_aligned, e); }) ||
        !reject("forward overlap", [&](auto& e) { return gpu->copy(dst.get(), 4, dst.get(), 0, 8, e); }) ||
        !reject("backward overlap", [&](auto& e) { return gpu->copy(dst.get(), 0, dst.get(), 4, 8, e); }) ||
        !reject("zero copy null source", [&](auto& e) { return gpu->copy(dst.get(), 0, nullptr, 0, 0, e); }) ||
        !reject("zero copy invalid range", [&](auto& e) { return gpu->copy(dst.get(), dst_bytes + 4, src.get(), 0, 0, e); }) ||
        !reject("zero copy invalid alignment", [&](auto& e) { return gpu->copy(dst.get(), 2, src.get(), 0, 0, e); }) ||
        !reject("null read source", [&](auto& e) { return gpu->read(nullptr, 0, slice.data(), 4, e); }) ||
        !reject("null read destination", [&](auto& e) { return gpu->read(src.get(), 0, nullptr, 4, e); }) ||
        !reject("read offset alignment", [&](auto& e) { return gpu->read(src.get(), 2, slice.data(), 4, e); }) ||
        !reject("read length alignment", [&](auto& e) { return gpu->read(src.get(), 0, slice.data(), 2, e); }) ||
        !reject("read overrun", [&](auto& e) { return gpu->read(src.get(), src_bytes, slice.data(), 4, e); }) ||
        !reject("read overflowing offset", [&](auto& e) { return gpu->read(src.get(), huge_aligned, slice.data(), 4, e); }) ||
        !reject("read overflowing length", [&](auto& e) { return gpu->read(src.get(), 4, slice.data(), huge_aligned, e); }) ||
        !reject("zero read invalid range", [&](auto& e) { return gpu->read(src.get(), src_bytes + 4, nullptr, 0, e); }) ||
        !reject("zero read null source", [&](auto& e) { return gpu->read(nullptr, 0, nullptr, 0, e); })) return false;
    if (!require(slice == slice_before_rejections, "rejected read modified the host destination", error) ||
        !read_test_buffer(gpu, dst, got, error) ||
        !require(got == expected, "rejected copy modified the destination", error) ||
        !read_test_buffer(gpu, src, got, error) ||
        !require(got == input, "copy or rejected read modified the source", error)) return false;
    std::printf("transfer ranges: upload/read, guards, aliases, zero length, %zu rejected invalid requests\n", rejected);
    return true;
}

bool check_compute_transfers(Gpu* gpu, std::string& error) {
    constexpr uint32_t count = 257;
    std::vector<float> input(count), factor(count, 2), got;
    for (uint32_t i = 0; i < count; ++i) input[i] = float(int(i) - 128) / 8;
    const size_t bytes = input.size() * sizeof(float);
    auto source = gpu->upload(input.data(), bytes, error);
    auto weights = gpu->upload(factor.data(), bytes, error);
    auto calculated = gpu->alloc(bytes, error);
    auto copied = gpu->alloc(bytes, error);
    if (!source || !weights || !calculated || !copied) return false;
    const uint32_t n[1] = {count};
    if (!gpu->dispatch("spk_mul", {Arg::buf(source), Arg::buf(weights), Arg::inline_bytes(n, 1),
                                   Arg::buf(calculated)}, count, error) ||
        !gpu->copy(copied.get(), 0, calculated.get(), 0, bytes, error) ||
        !gpu->dispatch("spk_mul", {Arg::buf(copied), Arg::buf(weights), Arg::inline_bytes(n, 1),
                                   Arg::buf(calculated)}, count, error) ||
        !read_test_buffer(gpu, calculated, got, error)) return false;
    for (uint32_t i = 0; i < count; ++i)
        if (!require(got[i] == input[i] * 4, "compute/copy/compute/read dependency failed", error)) return false;
    std::puts("transfer dependencies: upload -> compute -> copy -> compute -> read passed");
    return true;
}

bool check_pool_lifetimes(Gpu* gpu, std::string& error) {
    if (!gpu->flush(error)) return false;
    gpu->trim_pool(0);
    if (!require(gpu->pool_stats().total_bytes == 0, "initial trim left idle pooled buffers", error)) return false;
    constexpr size_t count = 263;
    const size_t bytes = count * sizeof(uint32_t);
    std::vector<uint32_t> expected(count), got;
    for (size_t i = 0; i < count; ++i) expected[i] = 0x9e3779b9u * uint32_t(i + 1);
    auto original = gpu->upload(expected.data(), bytes, error);
    if (!original) return false;
    BufferRef retained = original;
    original.reset();
    auto temporary = gpu->alloc_zeroed(bytes, error);
    if (!temporary || !require(temporary.get() != retained.get(), "pool reused a retained buffer", error) ||
        !read_test_buffer(gpu, temporary, got, error) ||
        !require(std::all_of(got.begin(), got.end(), [](uint32_t v) { return v == 0; }),
                 "alloc_zeroed did not clear the device allocation", error)) return false;
    auto* reusable = temporary.get();
    temporary.reset();
    const auto before_reuse = gpu->pool_stats();
    temporary = gpu->alloc_zeroed(bytes, error);
    const auto after_reuse = gpu->pool_stats();
    if (!temporary || !require(temporary.get() == reusable &&
        after_reuse.audit.reuses == before_reuse.audit.reuses + 1 &&
        after_reuse.audit.allocations == before_reuse.audit.allocations,
        "pool did not reuse an idle compatible buffer", error)) return false;
    if (!gpu->copy(temporary.get(), 0, retained.get(), 0, bytes, error)) return false;
    temporary.reset();
    temporary = gpu->alloc_zeroed(bytes, error);
    if (!temporary || !read_test_buffer(gpu, temporary, got, error) ||
        !require(std::all_of(got.begin(), got.end(), [](uint32_t v) { return v == 0; }),
                 "reused alloc_zeroed exposed the previous contents", error)) return false;
    temporary.reset();
    auto persistent = gpu->upload_persistent(expected.data(), bytes, error);
    if (!persistent || !require(gpu->trim_pool(0) > 0, "trim did not free the idle buffer", error) ||
        !require(gpu->pool_stats().total_bytes == gpu->size_bytes(retained.get()),
                 "trim removed a retained buffer or kept idle buffers", error) ||
        !read_test_buffer(gpu, retained, got, error) ||
        !require(got == expected, "retained buffer changed during reuse or trim", error) ||
        !read_test_buffer(gpu, persistent, got, error) ||
        !require(got == expected, "trim changed a persistent buffer", error)) return false;
    retained.reset();
    if (!require(gpu->trim_pool(0) > 0 && gpu->pool_stats().total_bytes == 0,
                 "final release and trim failed", error)) return false;
    const auto persistent_before = gpu->pool_stats();
    persistent.reset();
    const auto final = gpu->pool_stats();
    if (!require(final.persistent_buffers + 1 == persistent_before.persistent_buffers &&
                 final.persistent_bytes + bytes == persistent_before.persistent_bytes,
                 "persistent allocation did not release independently of the pool", error)) return false;
    std::puts("transfer lifetimes: zero fill, pool reuse, retained stability, trim, persistent release passed");
    return true;
}

bool check_persistent_promotion(Gpu* gpu, const std::string& shader_dir, std::string& error) {
    if (!gpu->flush(error)) return false;
    gpu->trim_pool(0);
    const auto baseline = gpu->pool_stats();
    if (!require(baseline.total_bytes == 0, "promotion test started with pooled buffers", error)) return false;
    constexpr size_t count = 263;
    constexpr size_t bytes = count * sizeof(uint32_t);
    std::vector<uint32_t> expected(count), got;
    for (size_t i = 0; i < count; ++i) expected[i] = 0x9e3779b9u * uint32_t(i + 7);
    auto original = gpu->upload(expected.data(), bytes, error);
    if (!original) return false;
    auto* identity = original.get();
    const auto before = gpu->pool_stats();
    {
        BufferRef alias = original;
        if (!require(!gpu->try_promote_persistent(original.get(), bytes),
                     "promotion accepted a writable alias", error)) return false;
    }
    if (!require(!gpu->try_promote_persistent(nullptr, bytes) &&
                 !gpu->try_promote_persistent(original.get(), bytes - 4),
                 "promotion accepted null or a mismatched logical size", error)) return false;
    {
        std::unique_ptr<Gpu> foreign_gpu(Gpu::create_vulkan(shader_dir, error));
        if (!foreign_gpu) return false;
        auto foreign = foreign_gpu->upload(expected.data(), bytes, error);
        if (!foreign || !require(!gpu->try_promote_persistent(foreign.get(), bytes),
                                "promotion accepted another device's buffer", error) ||
            !read_test_buffer(foreign_gpu.get(), foreign, got, error) ||
            !require(got == expected && foreign_gpu->pool_stats().persistent_bytes == 0,
                     "rejected foreign promotion changed data or ownership", error)) return false;
    }
    const auto rejected = gpu->pool_stats();
    if (!require(rejected.total_bytes == before.total_bytes && rejected.live_bytes == before.live_bytes &&
                 rejected.persistent_bytes == before.persistent_bytes,
                 "rejected promotion changed pool accounting", error) ||
        !read_test_buffer(gpu, original, got, error) ||
        !require(got == expected, "rejected promotion changed the source", error) ||
        !gpu->flush(error)) return false;
    if (!require(gpu->try_promote_persistent(original.get(), bytes),
                 "exclusive exact-size temporary could not become persistent", error)) return false;
    const auto promoted = gpu->pool_stats();
    if (!require(original.get() == identity &&
                 promoted.total_bytes + bytes == before.total_bytes &&
                 promoted.live_bytes + bytes == before.live_bytes &&
                 promoted.buffers + 1 == before.buffers &&
                 promoted.live_buffers + 1 == before.live_buffers &&
                 promoted.persistent_bytes == before.persistent_bytes + bytes &&
                 promoted.persistent_buffers == before.persistent_buffers + 1 &&
                 promoted.frame_high_water_bytes == before.frame_high_water_bytes &&
                 promoted.audit.allocations == before.audit.allocations &&
                 promoted.audit.persistent_allocations == before.audit.persistent_allocations &&
                 promoted.audit.reuses == before.audit.reuses,
                 "promotion copied storage or changed allocation/high-water semantics", error) ||
        !require(!gpu->try_promote_persistent(original.get(), bytes),
                 "promotion accepted an already persistent buffer", error)) return false;
    auto scratch = gpu->alloc_zeroed(bytes, error);
    if (!scratch || !require(scratch.get() != identity, "pool reused a promoted plane", error)) return false;
    scratch.reset();
    if (!require(gpu->trim_pool(0) > 0 && gpu->pool_stats().total_bytes == 0,
                 "trim retained scratch or removed the wrong buffer after promotion", error) ||
        !read_test_buffer(gpu, original, got, error) ||
        !require(got == expected, "scratch writes or trim changed the promoted plane", error)) return false;
    BufferRef cached = std::move(original);
    if (!require(!original && cached.get() == identity, "moving the promoted handle changed ownership", error)) return false;
    BufferRef retained = cached;
    cached.reset();
    if (!read_test_buffer(gpu, retained, got, error) ||
        !require(got == expected && gpu->pool_stats().persistent_bytes == baseline.persistent_bytes + bytes,
                 "promoted plane did not survive its original handle", error)) return false;
    retained.reset();
    const auto released = gpu->pool_stats();
    if (!require(released.persistent_bytes == baseline.persistent_bytes &&
                 released.persistent_buffers == baseline.persistent_buffers && released.total_bytes == 0 &&
                 released.audit.over_releases == baseline.audit.over_releases &&
                 released.audit.live_underflows == baseline.audit.live_underflows,
                 "final promoted release did not restore the ownership ledger", error)) return false;

    // Capacity and current borrower size are separate checks: neither a small
    // view of a larger block nor a claim of the larger size may pin that block.
    auto larger = gpu->alloc(bytes * 2, error);
    if (!larger) return false;
    auto* reusable = larger.get();
    larger.reset();
    auto smaller = gpu->upload(expected.data(), bytes, error);
    if (!smaller || !require(smaller.get() == reusable && gpu->size_bytes(smaller.get()) == bytes * 2,
                            "oversized promotion fixture did not reuse the larger block", error) ||
        !require(!gpu->try_promote_persistent(smaller.get(), bytes) &&
                 !gpu->try_promote_persistent(smaller.get(), bytes * 2),
                 "promotion ignored capacity or current borrower size", error)) return false;
    got.resize(count);
    if (!gpu->read(smaller.get(), 0, got.data(), bytes, error) ||
        !require(got == expected, "rejected oversized promotion changed live pixels", error)) return false;
    smaller.reset();
    if (!require(!gpu->try_promote_persistent(reusable, bytes * 2),
                 "promotion accepted an unowned idle buffer", error)) return false;
    gpu->trim_pool(0);
    const auto final = gpu->pool_stats();
    if (!require(final.total_bytes == 0 && final.persistent_bytes == baseline.persistent_bytes &&
                 final.persistent_buffers == baseline.persistent_buffers,
                 "rejected promotion leaked a pool or persistent buffer", error)) return false;
    std::puts("transfer promotion: identity, aliases, device ownership, trim, lifetime and exact sizes passed");
    return true;
}

constexpr std::array<uint32_t, 8> trim_sentinel = {
    0, 0x80000000u, 0x7fc12345u, 0x7f800000u,
    0xff800000u, 0xffffffffu, 0x01234567u, 0x89abcdefu};

bool write_trim_sentinel(Gpu* gpu, const BufferRef& buffer, const BufferRef& source, std::string& error) {
    const size_t bytes = sizeof(trim_sentinel);
    return gpu->copy(buffer.get(), 0, source.get(), 0, bytes, error) &&
           gpu->copy(buffer.get(), gpu->size_bytes(buffer.get()) - bytes, source.get(), 0, bytes, error);
}

bool check_trim_sentinel(Gpu* gpu, const BufferRef& buffer, std::string& error) {
    std::array<uint32_t, trim_sentinel.size()> head{}, tail{};
    return gpu->read(buffer.get(), 0, head.data(), sizeof(head), error) &&
           gpu->read(buffer.get(), gpu->size_bytes(buffer.get()) - sizeof(tail), tail.data(), sizeof(tail), error) &&
           require(head == trim_sentinel && tail == trim_sentinel,
                   "pool trim or reuse changed a retained buffer's sentinel bytes", error);
}

bool check_trim_cleanup(Gpu* gpu, const spk::gpu::PoolStats& baseline, std::string& error) {
    if (!gpu->flush(error)) return false;
    gpu->trim_pool(0);
    const auto final = gpu->pool_stats();
    return require(final.total_bytes == 0 && final.persistent_bytes == baseline.persistent_bytes &&
                   final.persistent_buffers == baseline.persistent_buffers,
                   "trim fixture leaked a pooled or persistent buffer", error) &&
           require(final.audit.pending_held == 0 && final.audit.over_releases == 0 &&
                   final.audit.reclaim_while_encoding == 0 && final.audit.live_underflows == 0,
                   "trim fixture violated counted-buffer ownership", error);
}

bool check_incompatible_trim(Gpu* gpu, std::string& error) {
    constexpr size_t mib = size_t(1) << 20;
    constexpr size_t floor = 64 * mib, small_bytes = floor - 4, next_bytes = 96 * mib;
    if (!gpu->flush(error)) return false;
    gpu->trim_pool(0);
    const auto baseline = gpu->pool_stats();
    if (!require(baseline.total_bytes == 0, "incompatible trim fixture started with pooled buffers", error)) return false;
    {
        // Allocate together so the fixture cannot reuse its own idle planes.
        // The GPU holds less than 481 MiB; CPU transfers touch only 32-byte ends.
        auto source = gpu->upload_persistent(trim_sentinel.data(), sizeof(trim_sentinel), error);
        auto persistent = gpu->alloc_persistent(floor, error);
        auto live = gpu->alloc(floor, error);
        auto small = gpu->alloc(small_bytes, error);
        auto undersized = gpu->alloc(floor, error);
        auto matching = gpu->alloc(next_bytes, error);
        auto larger = gpu->alloc(128 * mib, error);
        if (!source || !persistent || !live || !small || !undersized || !matching || !larger) return false;
        for (const auto* buffer : {&persistent, &live, &small, &matching, &larger})
            if (!write_trim_sentinel(gpu, *buffer, source, error)) return false;
        BufferRef alias = live;
        auto* small_identity = small.get();
        auto* matching_identity = matching.get();
        auto* larger_identity = larger.get();
        small.reset(); undersized.reset(); matching.reset(); larger.reset();
        if (!gpu->flush(error)) return false;
        const auto before = gpu->pool_stats();
        if (!require(before.live_bytes == floor && before.free_bytes == small_bytes + floor + next_bytes + 128 * mib,
                     "incompatible trim fixture did not have distinct expected capacities", error) ||
            !require(gpu->trim_pool_incompatible(floor) == 0 && gpu->pool_stats().total_bytes == before.total_bytes,
                     "incompatible trim removed a small or already sufficient buffer", error)) return false;

        const size_t freed = gpu->trim_pool_incompatible(next_bytes);
        const auto after = gpu->pool_stats();
        if (!require(freed == floor && after.total_bytes + freed == before.total_bytes &&
                     after.free_bytes + freed == before.free_bytes && after.free_buffers + 1 == before.free_buffers &&
                     after.live_bytes == before.live_bytes && after.live_buffers == before.live_buffers &&
                     after.persistent_bytes == before.persistent_bytes && after.persistent_buffers == before.persistent_buffers,
                     "incompatible trim did not remove only the idle 64 MiB plane", error) ||
            !require(after.audit.allocations == before.audit.allocations && after.audit.reuses == before.audit.reuses &&
                     after.audit.persistent_allocations == before.audit.persistent_allocations,
                     "incompatible trim changed allocation traffic", error) ||
            !check_trim_sentinel(gpu, alias, error) || !check_trim_sentinel(gpu, persistent, error)) return false;
        live.reset();
        if (!require(gpu->trim_pool_incompatible(next_bytes) == 0 && gpu->pool_stats().total_bytes == after.total_bytes,
                     "repeated incompatible trim removed a retained alias or compatible capacity", error) ||
            !check_trim_sentinel(gpu, alias, error)) return false;

        matching = gpu->alloc(next_bytes, error);
        larger = gpu->alloc(128 * mib, error);
        small = gpu->alloc(small_bytes, error);
        const auto reused = gpu->pool_stats();
        if (!matching || !larger || !small ||
            !require(matching.get() == matching_identity && larger.get() == larger_identity && small.get() == small_identity,
                     "incompatible trim discarded matching, larger, or protected small capacity", error) ||
            !require(reused.audit.allocations == after.audit.allocations && reused.audit.reuses == after.audit.reuses + 3,
                     "retained capacities required fresh allocations after incompatible trim", error) ||
            !check_trim_sentinel(gpu, matching, error) || !check_trim_sentinel(gpu, larger, error) ||
            !check_trim_sentinel(gpu, small, error) || !check_trim_sentinel(gpu, persistent, error)) return false;
    }
    if (!check_trim_cleanup(gpu, baseline, error)) return false;
    std::puts("transfer incompatible trim: threshold, capacity selection, small-cache reuse, aliases and persistent bytes passed");
    return true;
}

bool check_incompatible_trim_floor(Gpu* gpu, std::string& error) {
    constexpr size_t mib = size_t(1) << 20;
    constexpr size_t floor = 4 * mib, small_bytes = floor - 4, next_bytes = 16 * mib;
    if (!gpu->flush(error)) return false;
    gpu->trim_pool(0);
    const auto baseline = gpu->pool_stats();
    if (!require(baseline.total_bytes == 0, "custom trim fixture started with pooled buffers", error)) return false;
    {
        // Less than 69 MiB, with distinct blocks across the new 4 MiB boundary.
        auto source = gpu->upload_persistent(trim_sentinel.data(), sizeof(trim_sentinel), error);
        auto persistent = gpu->alloc_persistent(8 * mib, error);
        auto live = gpu->alloc(8 * mib, error);
        auto small = gpu->alloc(small_bytes, error);
        auto boundary = gpu->alloc(floor, error);
        auto middle = gpu->alloc(8 * mib, error);
        auto matching = gpu->alloc(next_bytes, error);
        auto larger = gpu->alloc(20 * mib, error);
        if (!source || !persistent || !live || !small || !boundary || !middle || !matching || !larger) return false;
        for (const auto* buffer : {&persistent, &live, &small, &matching, &larger})
            if (!write_trim_sentinel(gpu, *buffer, source, error)) return false;
        BufferRef alias = live;
        auto* small_identity = small.get();
        auto* matching_identity = matching.get();
        auto* larger_identity = larger.get();
        live.reset(); small.reset(); boundary.reset(); middle.reset(); matching.reset(); larger.reset();
        if (!gpu->flush(error)) return false;
        const auto before = gpu->pool_stats();
        if (!require(before.live_bytes == 8 * mib && before.free_bytes == small_bytes + 48 * mib,
                     "custom trim fixture did not have distinct expected capacities", error) ||
            !require(gpu->trim_pool_incompatible(next_bytes) == 0 &&
                     gpu->pool_stats().total_bytes == before.total_bytes,
                     "default incompatible trim stopped protecting blocks below 64 MiB", error) ||
            !require(gpu->trim_pool_incompatible(floor, floor) == 0 &&
                     gpu->pool_stats().total_bytes == before.total_bytes,
                     "custom trim removed a block when no capacity could be incompatible", error)) return false;

        const size_t freed = gpu->trim_pool_incompatible(next_bytes, floor);
        const auto after = gpu->pool_stats();
        if (!require(freed == 12 * mib && after.total_bytes == before.total_bytes - freed &&
                     after.free_bytes == small_bytes + 36 * mib && after.free_buffers == 3 &&
                     after.live_bytes == 8 * mib && after.live_buffers == 1 &&
                     after.persistent_bytes == before.persistent_bytes &&
                     after.persistent_buffers == before.persistent_buffers,
                     "custom incompatible trim must free only idle 4 MiB and 8 MiB blocks", error) ||
            !require(after.audit.allocations == before.audit.allocations && after.audit.reuses == before.audit.reuses &&
                     after.audit.persistent_allocations == before.audit.persistent_allocations,
                     "custom trim changed allocation traffic", error) ||
            !check_trim_sentinel(gpu, alias, error) || !check_trim_sentinel(gpu, persistent, error) ||
            !require(gpu->trim_pool_incompatible(next_bytes, floor) == 0 &&
                     gpu->pool_stats().total_bytes == after.total_bytes,
                     "repeated custom trim removed protected capacity", error)) return false;

        matching = gpu->alloc(next_bytes, error);
        larger = gpu->alloc(20 * mib, error);
        small = gpu->alloc(small_bytes, error);
        const auto reused = gpu->pool_stats();
        if (!matching || !larger || !small ||
            !require(matching.get() == matching_identity && larger.get() == larger_identity && small.get() == small_identity,
                     "custom trim discarded matching, larger, or below-threshold capacity", error) ||
            !require(reused.audit.allocations == after.audit.allocations && reused.audit.reuses == after.audit.reuses + 3,
                     "custom trim forced retained capacities to be reallocated", error) ||
            !check_trim_sentinel(gpu, matching, error) || !check_trim_sentinel(gpu, larger, error) ||
            !check_trim_sentinel(gpu, small, error) || !check_trim_sentinel(gpu, alias, error) ||
            !check_trim_sentinel(gpu, persistent, error)) return false;
    }
    if (!check_trim_cleanup(gpu, baseline, error)) return false;
    std::puts("transfer custom trim: 4 MiB boundary, default protection, compatible reuse and retained aliases passed");
    return true;
}

bool check_phase_trim(Gpu* gpu, std::string& error) {
    constexpr size_t mib = size_t(1) << 20, floor = 64 * mib, live_bytes = 96 * mib;
    if (!gpu->flush(error)) return false;
    gpu->trim_pool(0);
    const auto baseline = gpu->pool_stats();
    if (!require(baseline.total_bytes == 0, "phase trim fixture started with pooled buffers", error)) return false;
    {
        auto source = gpu->upload_persistent(trim_sentinel.data(), sizeof(trim_sentinel), error);
        auto persistent = gpu->alloc_persistent(floor, error);
        auto live = gpu->alloc(live_bytes, error);
        auto free64 = gpu->alloc(floor, error);
        auto free96 = gpu->alloc(96 * mib, error);
        auto free128 = gpu->alloc(128 * mib, error);
        if (!source || !persistent || !live || !free64 || !free96 || !free128) return false;
        for (const auto* buffer : {&persistent, &live, &free64})
            if (!write_trim_sentinel(gpu, *buffer, source, error)) return false;
        BufferRef alias = live;
        auto* free64_identity = free64.get();
        free64.reset(); free96.reset(); free128.reset();
        const auto before = gpu->pool_stats();
        if (!require(before.live_bytes == live_bytes && before.free_bytes == 288 * mib,
                     "phase trim fixture did not have distinct expected capacities", error) ||
            !gpu->trim_idle_for_phase(floor - 1, 0, error)) return false;
        const auto small = gpu->pool_stats();
        if (!require(small.total_bytes == before.total_bytes && small.free_bytes == before.free_bytes &&
                     small.live_bytes == before.live_bytes && small.persistent_bytes == before.persistent_bytes &&
                     small.audit.allocations == before.audit.allocations && small.audit.reuses == before.audit.reuses,
                     "small-image phase trim changed the pool", error)) return false;

        // keep_free is a free budget, not a total budget: the 96 MiB live plane
        // must be added once, despite having two handles. Only 128 MiB is freed.
        constexpr size_t keep_free = 160 * mib;
        if (!gpu->trim_idle_for_phase(floor, keep_free, error)) return false;
        const auto kept = gpu->pool_stats();
        if (!require(kept.total_bytes == live_bytes + keep_free && kept.free_bytes == keep_free &&
                     kept.live_bytes == live_bytes && kept.live_buffers == 1 && kept.free_buffers == 2 &&
                     kept.persistent_bytes == before.persistent_bytes && kept.persistent_buffers == before.persistent_buffers,
                     "phase trim did not preserve the requested free budget plus live storage", error) ||
            !require(kept.audit.allocations == before.audit.allocations && kept.audit.reuses == before.audit.reuses &&
                     kept.audit.persistent_allocations == before.audit.persistent_allocations,
                     "phase trim changed allocation traffic", error) ||
            !check_trim_sentinel(gpu, alias, error) || !check_trim_sentinel(gpu, persistent, error) ||
            !gpu->trim_idle_for_phase(floor, keep_free, error) ||
            !require(gpu->pool_stats().total_bytes == kept.total_bytes, "phase trim is not idempotent", error)) return false;

        live.reset();
        if (!gpu->trim_idle_for_phase(128 * mib, 0, error)) return false;
        const auto minimum = gpu->pool_stats();
        if (!require(minimum.free_bytes == floor && minimum.total_bytes == live_bytes + floor &&
                     minimum.live_bytes == live_bytes && minimum.persistent_bytes == before.persistent_bytes,
                     "phase trim failed to retain the 64 MiB minimum free budget", error) ||
            !check_trim_sentinel(gpu, alias, error) || !check_trim_sentinel(gpu, persistent, error)) return false;
        free64 = gpu->alloc(floor, error);
        const auto reused = gpu->pool_stats();
        if (!free64 || !require(free64.get() == free64_identity &&
                               reused.audit.allocations == before.audit.allocations &&
                               reused.audit.reuses == before.audit.reuses + 1,
                               "phase trim discarded the reusable minimum-budget plane", error) ||
            !check_trim_sentinel(gpu, free64, error)) return false;
    }
    if (!check_trim_cleanup(gpu, baseline, error)) return false;
    std::puts("transfer phase trim: small-image no-op, free budget, minimum retention, reuse and ownership passed");
    return true;
}

class StagingOverride {
public:
    explicit StagingOverride(const char* value) {
        const char* previous = std::getenv(name);
        present_ = previous != nullptr;
        if (previous) previous_ = previous;
        set(value);
    }
    ~StagingOverride() { set(present_ ? previous_.c_str() : nullptr); }
private:
    static constexpr const char* name = "SPEKTRAFILM_VULKAN_STAGING_BYTES";
    static void set(const char* value) {
#ifdef _WIN32
        _putenv_s(name, value ? value : "");
#else
        if (value) setenv(name, value, 1);
        else unsetenv(name);
#endif
    }
    std::string previous_;
    bool present_ = false;
};

bool check_chunked_transfers(const std::string& shader_dir, std::string& error) {
    for (const char* invalid : {"0", "3", "65537", "67108868", "-4", "4garbage",
                                "184467440737095516160"}) {
        StagingOverride override(invalid);
        std::string why;
        std::unique_ptr<Gpu> rejected(Gpu::create_vulkan(shader_dir, why));
        if (!require(!rejected && why.find("SPEKTRAFILM_VULKAN_STAGING_BYTES") != std::string::npos,
                     "invalid staging cap was accepted or not diagnosed", error)) return false;
    }
    // Deliberately not a power of two: complete device words need not end on
    // a nonCoherentAtomSize boundary; mapped_range must round safely itself.
    constexpr size_t cap = 1024 * 1024 + 4;
    StagingOverride override("1048580");
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(shader_dir, error));
    if (!gpu) return false;
    // Two complete chunks and a short last one. The offset read crosses both
    // boundaries and writes to an intentionally unaligned CPU byte address.
    const size_t count = (2 * cap) / sizeof(uint32_t) + 13;
    std::vector<uint32_t> input(count), got;
    for (size_t i = 0; i < count; ++i) input[i] = uint32_t(i) * 0x9e3779b9u ^ uint32_t(i >> 3);
    auto src = gpu->upload_persistent(input.data(), input.size() * 4, error);
    if (!src || !read_test_buffer(gpu.get(), src, got, error) ||
        !require(got == input, "chunked upload/read changed input bytes", error)) return false;
    constexpr size_t source_offset = 12;
    const size_t slice_bytes = 2 * cap + 4;
    std::vector<uint8_t> slice(slice_bytes + 2, 0xa5);
    if (!gpu->read(src.get(), source_offset, slice.data() + 1, slice_bytes, error) ||
        !require(slice.front() == 0xa5 && slice.back() == 0xa5 &&
                 std::memcmp(slice.data() + 1,
                    reinterpret_cast<const uint8_t*>(input.data()) + source_offset, slice_bytes) == 0,
                 "chunked offset read changed payload or host guards", error)) return false;
    const auto before_rejected = slice;
    std::string diagnostic;
    if (!require(!gpu->read(src.get(), source_offset, slice.data() + 1, input.size() * 4, diagnostic) &&
                 !diagnostic.empty() && slice == before_rejected,
                 "invalid multi-chunk read changed its destination", error)) return false;

    std::vector<double> wide(count);
    std::vector<float> expected(count);
    for (size_t i = 0; i < count; ++i) {
        wide[i] = (double(i) - double(count) / 2) / 31.0;
        expected[i] = float(wide[i]);
    }
    // The conversion still happens once in float32, including signed zero and
    // non-finite values on both sides of a chunk boundary.
    for (size_t i : {size_t(0), cap / 4 - 1, cap / 4, 2 * cap / 4, count - 1}) {
        wide[i] = i % 2 ? -0.0 : std::numeric_limits<double>::infinity();
        expected[i] = float(wide[i]);
    }
    auto narrowed = gpu->upload_persistent_f32(wide.data(), count, error);
    std::vector<float> actual;
    if (!narrowed || !read_test_buffer(gpu.get(), narrowed, actual, error) ||
        !require(actual.size() == expected.size() &&
                 std::memcmp(actual.data(), expected.data(), expected.size() * 4) == 0,
                 "chunked double-to-float upload changed converted bytes", error)) return false;

    // Trimming releases staging even with retained device buffers. The next
    // transfer must rebuild staging without disturbing either live input.
    gpu->trim_pool(0);
    if (!read_test_buffer(gpu.get(), src, got, error) ||
        !require(got == input, "trim changed a retained multi-chunk buffer", error)) return false;
    auto zeroed = gpu->alloc_zeroed(input.size() * 4, error);
    if (!zeroed || !gpu->copy(zeroed.get(), 0, src.get(), 0, input.size() * 4, error) ||
        !read_test_buffer(gpu.get(), zeroed, got, error) ||
        !require(got == input, "device copy after staging trim changed bytes", error)) return false;
    std::puts("transfer chunks: bounded upload/read, offset guards, narrowed float upload, trim recovery passed");
    return true;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_transfer <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    if (!check_ranges(gpu.get(), error) || !check_compute_transfers(gpu.get(), error) ||
        !check_pool_lifetimes(gpu.get(), error) ||
        !check_persistent_promotion(gpu.get(), std::string(argv[1]) + "/vulkan", error) ||
        !check_incompatible_trim(gpu.get(), error) || !check_incompatible_trim_floor(gpu.get(), error) ||
        !check_phase_trim(gpu.get(), error)) {
        std::fprintf(stderr, "transfer: %s\n", error.c_str());
        return 1;
    }
    gpu.reset();
    if (!check_chunked_transfers(std::string(argv[1]) + "/vulkan", error)) {
        std::fprintf(stderr, "transfer: %s\n", error.c_str());
        return 1;
    }
    return 0;
}
