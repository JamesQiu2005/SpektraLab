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
        !check_pool_lifetimes(gpu.get(), error)) {
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
