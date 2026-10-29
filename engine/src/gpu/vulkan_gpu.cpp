// vulkan_gpu.cpp -- synchronous Vulkan compute with explicit host transfers.
//
// Compute planes remain device-local; independent reusable host buffers stage
// uploads and readbacks in bounded chunks. Every submission completes before returning, so no
// pooled or staging buffer can be reused while the device still reads it.
// Command batching and native texture export are subsequent steps.
//
// Built everywhere but Apple (Windows and Linux), and on macOS only for parity
// tests (SPEKTRALAB_VULKAN_ON_APPLE, MoltenVK). The Vulkan loader is not
// linked: volk (engine/third_party/volk) opens libvulkan.so.1 / vulkan-1.dll
// at run time, so the binary needs no SDK import library and a machine with
// no Vulkan driver gets an error message rather than a loader failure.
#if !defined(__APPLE__) || defined(SPK_VULKAN_BACKEND)
#include "gpu.hpp"
#include "file_path.hpp"

#include "volk.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace spk::gpu {

struct Buffer {
    VkBuffer handle = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    void* mapped = nullptr;
    size_t bytes = 0;
    size_t requested_bytes = 0; // Current borrower size; bytes is pool capacity.
    VkDeviceSize allocation_bytes = 0;
    uint32_t memory_type = UINT32_MAX;
    VkMemoryPropertyFlags memory_flags = 0;
    int refs = 1;
    bool persistent = false;
};

namespace {

constexpr uint32_t kWorkgroup = 256;

std::string vk_error(const char* operation, VkResult result) {
    return std::string(operation) + " failed (VkResult " + std::to_string(int(result)) + ")";
}

struct KernelSpec { const char* name; uint32_t bindings; uint32_t workgroup; };
constexpr KernelSpec kKernels[] = {
    {"spk_math_probe", 2, 1},
    // The portable error-free product, in its own kernel so that neither probe
    // has to change the other's output layout. local_size_x = 1, as
    // spk_math_probe's is; the count is the dispatch's `n`.
    {"spk_split_probe", 2, 1},
    {"spk_take_rgb", 3, kWorkgroup},
    {"spk_matmul3", 4, kWorkgroup},
    {"spk_stride_sample", 3, kWorkgroup},
    {"spk_affine3", 5, kWorkgroup},
    {"spk_tc_b", 5, kWorkgroup},
    {"spk_lut2d_cubic", 5, kWorkgroup},
    {"spk_sep_fir_acc", 6, kWorkgroup},
    {"spk_iir_df_acc", 7, kWorkgroup},
    {"spk_lincomb3", 6, kWorkgroup},
    {"spk_log10_guarded", 4, kWorkgroup},
    {"spk_curves", 6, kWorkgroup},
    {"spk_couplers_correction", 7, kWorkgroup},
    {"spk_spectral_epilogue", 7, kWorkgroup},
    {"spk_print_exposure", 4, kWorkgroup},
    {"spk_cam16ucs_compress", 7, kWorkgroup},
    {"spk_cctf_encode_matrix", 4, kWorkgroup},
    {"spk_to_rgba16", 3, kWorkgroup},
    {"spk_view_grade", 5, kWorkgroup},
    {"spk_view_grade_float", 5, kWorkgroup},
    {"spk_view_grade_di", 6, kWorkgroup},
    {"spk_view_geometry", 4, kWorkgroup},
    {"spk_view_pack", 4, kWorkgroup},
    {"spk_view_cam16", 8, kWorkgroup},
    {"spk_grain_layers", 8, kWorkgroup},
    {"spk_grain_layer_one", 8, kWorkgroup},
    {"spk_grain_simple", 5, kWorkgroup},
    {"spk_lognormal_field", 3, kWorkgroup},
    {"spk_rng_probe", 4, kWorkgroup},
    {"spk_mul", 4, kWorkgroup},
    {"spk_glare_add", 5, kWorkgroup},
    {"spk_reduce_max", 3, kWorkgroup},
    {"spk_boost", 4, kWorkgroup},
    {"spk_highlight_headroom", 4, kWorkgroup},
    {"spk_bw_correct", 4, kWorkgroup},
    {"spk_edr", 5, kWorkgroup},
    {"spk_cctf_decode", 3, kWorkgroup},
    {"spk_zoom_bilinear_mirror", 3, kWorkgroup},
    {"spk_geometry_resample_df", 4, kWorkgroup},
    {"spk_lut3d_trilinear", 6, kWorkgroup},
    {"spk_di_normalise", 5, kWorkgroup},
    {"spk_di_encode", 4, kWorkgroup},
    {"spk_scene_latitude", 4, kWorkgroup},
    {"spk_overscan_canvas", 4, kWorkgroup},
    {"spk_overscan_add_mask", 4, kWorkgroup},
    {"spk_overscan_film_present", 4, kWorkgroup},
    {"spk_overscan_light", 4, kWorkgroup},
    {"spk_view_pair", 6, kWorkgroup},
};

const KernelSpec* find_kernel(const char* name) {
    if (!name) return nullptr;
    for (const auto& spec : kKernels) if (std::strcmp(spec.name, name) == 0) return &spec;
    return nullptr;
}

struct ComputePipeline {
    VkDescriptorSetLayout descriptors = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
};

class VulkanGpu final : public Gpu {
public:
    explicit VulkanGpu(std::string shader_dir) : shader_dir_(std::move(shader_dir)) {
        const char* timing = std::getenv("SPEKTRAFILM_TRANSFER_TIMINGS");
        transfer_timings_ = timing && *timing && std::strcmp(timing, "0") != 0;
    }

    ~VulkanGpu() override {
        if (device_) {
            vkDeviceWaitIdle(device_);
            destroy_buffer(&upload_staging_);
            destroy_buffer(&read_staging_);
            for (Buffer* b : buffers_) { destroy_buffer(b); delete b; }
            for (const auto& [name, p] : pipelines_) {
                (void)name;
                if (p.pipeline) vkDestroyPipeline(device_, p.pipeline, nullptr);
                if (p.layout) vkDestroyPipelineLayout(device_, p.layout, nullptr);
                if (p.descriptors) vkDestroyDescriptorSetLayout(device_, p.descriptors, nullptr);
            }
            if (command_pool_) vkDestroyCommandPool(device_, command_pool_, nullptr);
            vkDestroyDevice(device_, nullptr);
        }
        if (instance_) vkDestroyInstance(instance_, nullptr);
    }

    bool initialize(std::string& error) {
        // A diagnostic override can make chunk boundaries cheap to exercise,
        // but cannot turn staging back into an unbounded full-frame allocation.
        if (const char* cap = std::getenv("SPEKTRAFILM_VULKAN_STAGING_BYTES"); cap && *cap) {
            char* end = nullptr;
            const unsigned long long value = std::strtoull(cap, &end, 10);
            if (*cap < '0' || *cap > '9' || end == cap || *end || value < 4 ||
                value > kMaxStagingBytes || value % 4) {
                error = "SPEKTRAFILM_VULKAN_STAGING_BYTES must be a multiple of four between 4 and 67108864";
                return false;
            }
            staging_chunk_bytes_ = size_t(value);
        }
        // volkInitialize is idempotent; it only resolves the loader's entry.
        VkResult loader = volkInitialize();
        if (loader != VK_SUCCESS) {
            error = "no Vulkan loader found (libvulkan.so.1 / vulkan-1.dll); install a GPU driver "
                    "with Vulkan support, or Mesa's lavapipe for a CPU fallback";
            return false;
        }
#if defined(__APPLE__)
        // MoltenVK (macOS parity builds only, SPEKTRALAB_VULKAN_ON_APPLE):
        // it compiles MSL with fast math unless told otherwise, and fast math
        // is what RFC-014 trap 1 forbids -- the Metal engine refuses it too.
        // Set before the instance exists; a caller's explicit value wins.
        setenv("MVK_CONFIG_FAST_MATH_ENABLED", "0", 0);
#endif
        VkApplicationInfo app{};
        app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app.pApplicationName = "SpektraLab headless";
        app.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo create{};
        create.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create.pApplicationInfo = &app;
        // A portability driver (MoltenVK) is enumerated only when the instance
        // asks for it. Requested only when the loader offers the extension,
        // so Windows and Linux drivers see the same instance as before.
        std::vector<const char*> instance_extensions;
        {
            uint32_t n_ext = 0;
            if (vkEnumerateInstanceExtensionProperties(nullptr, &n_ext, nullptr) == VK_SUCCESS && n_ext) {
                std::vector<VkExtensionProperties> ext(n_ext);
                if (vkEnumerateInstanceExtensionProperties(nullptr, &n_ext, ext.data()) == VK_SUCCESS)
                    for (const auto& e : ext)
                        if (std::strcmp(e.extensionName, "VK_KHR_portability_enumeration") == 0) {
                            instance_extensions.push_back("VK_KHR_portability_enumeration");
                            create.flags |= 0x00000001;   // VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR
                        }
            }
        }
        create.enabledExtensionCount = uint32_t(instance_extensions.size());
        create.ppEnabledExtensionNames = instance_extensions.empty() ? nullptr : instance_extensions.data();
        VkResult result = vkCreateInstance(&create, nullptr, &instance_);
        if (result != VK_SUCCESS) { error = vk_error("vkCreateInstance", result); return false; }
        // Instance-level loading only: every device function then goes through
        // the loader's trampolines, which dispatch on the handle. That keeps
        // two engines (two VkDevices) in one process correct, which
        // volkLoadDevice's process-global table would not.
        volkLoadInstance(instance_);

        uint32_t count = 0;
        result = vkEnumeratePhysicalDevices(instance_, &count, nullptr);
        if (result != VK_SUCCESS || count == 0) {
            error = result == VK_SUCCESS ? "no Vulkan physical device" :
                                           vk_error("vkEnumeratePhysicalDevices", result);
            return false;
        }
        std::vector<VkPhysicalDevice> devices(count);
        result = vkEnumeratePhysicalDevices(instance_, &count, devices.data());
        if (result != VK_SUCCESS) { error = vk_error("vkEnumeratePhysicalDevices", result); return false; }

        // SPEKTRAFILM_VULKAN_DEVICE=<index> pins one physical device (the
        // host's --device flag sets it); otherwise a discrete GPU wins.
        int forced = -1;
        if (const char* pick = std::getenv("SPEKTRAFILM_VULKAN_DEVICE"); pick && *pick) {
            char* end = nullptr;
            const long v = std::strtol(pick, &end, 10);
            if (end == pick || *end || v < 0 || v >= long(devices.size())) {
                error = std::string("SPEKTRAFILM_VULKAN_DEVICE=") + pick + " is not a device index (0.." +
                        std::to_string(devices.size() - 1) + ")";
                return false;
            }
            forced = int(v);
        }
        int best_score = -1;
        for (size_t index = 0; index < devices.size(); ++index) {
            if (forced >= 0 && int(index) != forced) continue;
            VkPhysicalDevice candidate = devices[index];
            uint32_t families_count = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &families_count, nullptr);
            std::vector<VkQueueFamilyProperties> families(families_count);
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &families_count, families.data());
            VkPhysicalDeviceProperties properties{};
            vkGetPhysicalDeviceProperties(candidate, &properties);
            for (uint32_t i = 0; i < families_count; ++i) {
                if (!(families[i].queueFlags & VK_QUEUE_COMPUTE_BIT) || !families[i].queueCount) continue;
                const int score = properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ? 2 : 1;
                if (score > best_score) {
                    best_score = score;
                    physical_ = candidate;
                    queue_family_ = i;
                    properties_ = properties;
                }
                break;
            }
        }
        if (!physical_) { error = "no Vulkan compute queue"; return false; }
        storage_range_limit_ = properties_.limits.maxStorageBufferRange;
        if (properties_.limits.maxComputeWorkGroupInvocations < kWorkgroup ||
            properties_.limits.maxComputeWorkGroupSize[0] < kWorkgroup ||
            properties_.limits.maxPerStageDescriptorStorageBuffers < 8 ||
            properties_.limits.maxDescriptorSetStorageBuffers < 8) {
            error = "Vulkan device limits are below the current shader layout";
            return false;
        }
        vkGetPhysicalDeviceMemoryProperties(physical_, &memory_properties_);

        const float priority = 1.0f;
        VkDeviceQueueCreateInfo queue_create{};
        queue_create.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_create.queueFamilyIndex = queue_family_;
        queue_create.queueCount = 1;
        queue_create.pQueuePriorities = &priority;
        VkDeviceCreateInfo device_create{};
        device_create.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_create.queueCreateInfoCount = 1;
        device_create.pQueueCreateInfos = &queue_create;
        // The Vulkan spec requires a device that exposes
        // VK_KHR_portability_subset (MoltenVK) to have it enabled.
        const char* portability_subset = "VK_KHR_portability_subset";
        {
            uint32_t n_ext = 0;
            if (vkEnumerateDeviceExtensionProperties(physical_, nullptr, &n_ext, nullptr) == VK_SUCCESS && n_ext) {
                std::vector<VkExtensionProperties> ext(n_ext);
                if (vkEnumerateDeviceExtensionProperties(physical_, nullptr, &n_ext, ext.data()) == VK_SUCCESS)
                    for (const auto& e : ext)
                        if (std::strcmp(e.extensionName, portability_subset) == 0) {
                            device_create.enabledExtensionCount = 1;
                            device_create.ppEnabledExtensionNames = &portability_subset;
                        }
            }
        }
        result = vkCreateDevice(physical_, &device_create, nullptr, &device_);
        if (result != VK_SUCCESS) { error = vk_error("vkCreateDevice", result); return false; }
        vkGetDeviceQueue(device_, queue_family_, 0, &queue_);

        VkCommandPoolCreateInfo pool_create{};
        pool_create.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_create.queueFamilyIndex = queue_family_;
        pool_create.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        result = vkCreateCommandPool(device_, &pool_create, nullptr, &command_pool_);
        if (result != VK_SUCCESS) { error = vk_error("vkCreateCommandPool", result); return false; }
        return true;
    }

    std::string device_name() const override { return properties_.deviceName; }

    bool check_math_mode(std::string& detail) override {
        if (!math_checked_) {
            math_checked_ = true;
            if (!probe_math_mode(math_detail_)) fused_fma_ = -1;
        }
        detail = math_detail_;
        return fused_fma_ >= 0;
    }

    bool probe_math_mode(std::string& detail) {
        // Normal, bounded inputs: binary64 represents every product exactly.
        // Keep the original lanes and add signs, exponent ranges and exact
        // products. This is a startup diagnostic, not proof for all inputs.
        constexpr size_t n = 256;
        float input[2 * n];
        for (size_t i = 0; i < n; ++i) {
            if (i < 64) {
                input[2 * i] = 0.1f + 0.37f * float(i);
                input[2 * i + 1] = input[2 * i] * 0.5f + 1.0f;
            } else {
                input[2 * i] = std::ldexp((i & 1 ? -1.0f : 1.0f) * (1.0f + float(i) / 1024.0f), int(i % 81) - 40);
                input[2 * i + 1] = std::ldexp((i & 2 ? -1.0f : 1.0f) * (1.0f + float(i * 13) / 4096.0f), int((i * 7) % 81) - 40);
            }
        }
        auto enabled = [](const char* name) {
            const char* value = std::getenv(name);
            return value && std::strcmp(value, "1") == 0;
        };
        const bool strict = enabled("SPEKTRAFILM_VULKAN_STRICT_FMA");
        const bool force_split = enabled("SPEKTRAFILM_VULKAN_FORCE_SPLIT") && !strict;
        std::string error, fallback_reason = "forced split for validation";
        if (!force_split) {
            BufferRef src = upload(input, sizeof input, error);
            BufferRef dst = alloc(n * sizeof(float), error);
            if (!src || !dst || !dispatch("spk_math_probe", {Arg::buf(src), Arg::buf(dst)}, n, error)) {
                detail = "Vulkan math probe failed: " + error;
                return false;
            }
            float got[n];
            if (!read(dst.get(), 0, got, sizeof got, error)) {
                detail = "Vulkan math probe readback failed: " + error;
                return false;
            }
            bool exact = true;
            for (size_t i = 0; i < n; ++i) {
                // Do not use host fmaf: legacy MinGW implementations can give
                // the wrong residual. No tolerance is applied to this gate.
                static_assert(std::numeric_limits<float>::digits == 24);
                static_assert(std::numeric_limits<double>::digits >= 48);
                const float a = input[2 * i], b = input[2 * i + 1];
                const float rounded = a * b;
                const float want = float(double(a) * double(b) - double(rounded));
                if (got[i] == want) continue;
                char values[112];
                std::snprintf(values, sizeof values, " (got %.9g, want %.9g)", double(got[i]), double(want));
                fallback_reason = "fma residual differs at index " + std::to_string(i) + values;
                exact = false;
                break;
            }
            if (exact) {
                fused_fma_ = 1;
                detail = "Vulkan probe passed (precise product + fused fma; full shader parity pending)";
                return true;
            }
            if (strict) {
                detail = fallback_reason + " (SPEKTRAFILM_VULKAN_STRICT_FMA=1)";
                return false;
            }
        }
        // GLSL.std.450 Fma need not give a single-rounded residual. Measure
        // the existing Dekker alternative on this device instead of relaxing
        // the acceptance tolerance or whitelisting a GPU vendor/type.
        BufferRef src = upload(input, sizeof input, error);
        BufferRef dst = alloc(2 * n * sizeof(float), error);
        if (!src || !dst || !dispatch("spk_split_probe", {Arg::buf(src), Arg::buf(dst)}, n, error)) {
            detail = fallback_reason + "; Vulkan split-product probe failed: " + error;
            return false;
        }
        float got[2 * n];
        if (!read(dst.get(), 0, got, sizeof got, error)) {
            detail = "Vulkan split-product probe readback failed: " + error;
            return false;
        }
        for (size_t i = 0; i < n; ++i) {
            const float a = input[2 * i], b = input[2 * i + 1];
            const float rounded = a * b;
            const float residual = float(double(a) * double(b) - double(rounded));
            // Check both words, not just their sum: consumers rely on a
            // rounded high word and its residual, not an arbitrary pair.
            if (got[2 * i] != rounded || got[2 * i + 1] != residual) {
                detail = fallback_reason + "; Vulkan split-product probe is not exact at index " + std::to_string(i);
                return false;
            }
        }
        fused_fma_ = 0;  // commit the choice only after validation succeeds
        detail = "Vulkan probe passed (exact Dekker split product; " + fallback_reason + "; full shader parity pending)";
        if (properties_.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) probe_cpu_storage_range(detail);
        return true;
    }

    // lavapipe advertises maxStorageBufferRange = 128 MiB, which refuses any
    // frame above ~11 MP (a 3-channel float plane of 4284 x 2844 is 146 MB),
    // and the CPU device is the fallback for a machine with no GPU at all.
    // llvmpipe addresses an SSBO with 32-bit offsets, so on a CPU device only
    // the range is *measured* rather than trusted: a dispatch over a buffer
    // 16 MiB past the advertised limit must read and write distinct values on
    // both sides of it. Only then is the limit raised to 4 GiB - 4, and the
    // math_mode string says so. Any GPU keeps its advertised limit, and
    // SPEKTRAFILM_VULKAN_STRICT_LIMITS=1 keeps it here too.
    void probe_cpu_storage_range(std::string& detail) {
        if (const char* strict = std::getenv("SPEKTRAFILM_VULKAN_STRICT_LIMITS"); strict && *strict == '1') return;
        const VkDeviceSize advertised = properties_.limits.maxStorageBufferRange;
        if (advertised >= 0xFFFFFFF0ull) return;
        // spk_take_rgb over n RGBA pixels: it reads 16n bytes and writes 12n,
        // both past the advertised range, with one thread per pixel (n stays
        // under the 65535-workgroup dispatch limit).
        const size_t n = size_t(advertised / 12) + (size_t(1) << 20);
        if ((n + 255) / 256 > properties_.limits.maxComputeWorkGroupCount[0]) return;
        std::vector<float> input(n * 4);
        auto pattern = [](size_t i) { return float(uint32_t(i * 2654435761u) >> 8); };
        for (size_t i = 0; i < input.size(); ++i) input[i] = pattern(i);
        std::string error;
        bool ok = false;
        {
            BufferRef in = upload(input.data(), input.size() * 4, error);
            BufferRef out = alloc(n * 12, error);
            const uint32_t meta[2] = {uint32_t(n), 4u};
            if (in && out) {
                storage_range_limit_ = VkDeviceSize(n) * 16;   // this one dispatch only
                const bool ran = dispatch("spk_take_rgb", {Arg::buf(in), Arg::inline_bytes(meta, 2), Arg::buf(out)},
                                          n, error);
                storage_range_limit_ = advertised;
                std::vector<float> got(n * 3);
                if (ran && read(out.get(), 0, got.data(), n * 12, error)) {
                    ok = true;
                    for (size_t i = 0; ok && i < n; ++i)
                        for (size_t c = 0; c < 3; ++c)
                            if (got[3 * i + c] != pattern(4 * i + c)) { ok = false; break; }
                }
            }
        }
        // The probe's buffers would otherwise sit in the pool and be handed,
        // at their full size, to the next small allocation.
        trim_pool(0);
        if (!ok) return;
        storage_range_limit_ = 0xFFFFFFFCull;
        detail += "; storage buffers past the advertised " + std::to_string(advertised >> 20) +
                  " MiB maxStorageBufferRange verified by probe on this CPU device";
    }

    void begin_frame() override {
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        frame_high_water_ = 0;
    }
    void end_frame() override {}

    BufferRef alloc(size_t bytes, std::string& error) override { return allocate(bytes, false, error); }
    BufferRef alloc_zeroed(size_t bytes, std::string& error) override {
        if (bytes % 4) { error = "Vulkan zero-fill size must be 4-byte aligned"; return {}; }
        BufferRef out = alloc(bytes, error);
        if (!out) return {};
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        const auto start = diagnostic_start();
        if (!submit_sync([&](VkCommandBuffer command) {
                device_barrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT);
                vkCmdFillBuffer(command, out.get()->handle, 0, VkDeviceSize(bytes), 0);
                transfer_written(command);
            }, "Vulkan zero fill", error)) return {};
        transfer_timing("fill", bytes, start);
        return out;
    }
    BufferRef upload(const void* data, size_t bytes, std::string& error) override {
        return upload_bytes(data, bytes, false, error);
    }
    BufferRef upload_f32(const double* data, size_t count, std::string& error) override {
        return upload_narrowed(data, count, false, error);
    }
    BufferRef upload_u32(const uint32_t* data, size_t count, std::string& error) override {
        if (count > std::numeric_limits<size_t>::max() / sizeof(uint32_t)) {
            error = "Vulkan upload count overflows byte size"; return {};
        }
        return upload(data, count * sizeof(uint32_t), error);
    }

    BufferRef alloc_persistent(size_t bytes, std::string& error) override {
        return allocate(bytes, true, error);
    }
    BufferRef upload_persistent(const void* data, size_t bytes, std::string& error) override {
        return upload_bytes(data, bytes, true, error);
    }
    BufferRef upload_persistent_f32(const double* data, size_t count, std::string& error) override {
        return upload_narrowed(data, count, true, error);
    }
    BufferRef upload_persistent_u32(const uint32_t* data, size_t count, std::string& error) override {
        if (count > std::numeric_limits<size_t>::max() / sizeof(uint32_t)) {
            error = "Vulkan upload count overflows byte size"; return {};
        }
        return upload_persistent(data, count * sizeof(uint32_t), error);
    }
    bool try_promote_persistent(Buffer* b, size_t bytes) override {
        // Same order as trim_pool: finish any synchronous queue submission
        // before changing how the buffer is reclaimed. Membership is checked
        // before dereferencing a pointer that might belong to another backend.
        std::lock_guard<std::mutex> dispatch_lock(dispatch_mutex_);
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        if (!b || std::find(buffers_.begin(), buffers_.end(), b) == buffers_.end()) return false;
        if (b->persistent || b->refs != 1 || b->bytes != bytes || b->requested_bytes != bytes)
            return false;
        // Keep the allocation in buffers_ and keep its one reference. Statistics
        // partition this list by persistent, and release already destroys the
        // last persistent reference. No allocation/reuse audit event occurred.
        b->persistent = true;
        return true;
    }
    // File-backed host pages are a Metal-specific optimisation. This first
    // Vulkan path preserves ownership with ordinary persistent buffers.
    BufferRef alloc_file_backed(size_t bytes, std::string& error) override {
        return alloc_persistent(bytes, error);
    }
    BufferRef upload_file_backed(const void* data, size_t bytes, std::string& error) override {
        return upload_persistent(data, bytes, error);
    }
    BufferRef borrow(void*, size_t, std::string& error) override {
        error = "Vulkan device-buffer input is not implemented; use spk_open with host pixels";
        return {};
    }

    void retain(Buffer* b) override {
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        if (b) ++b->refs;
    }
    void release(Buffer* b) override {
        if (!b) return;
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        if (b->refs <= 0) { ++audit_.over_releases; return; }
        if (--b->refs == 0 && b->persistent) {
            buffers_.erase(std::remove(buffers_.begin(), buffers_.end(), b), buffers_.end());
            destroy_buffer(b);
            delete b;
        }
    }
    void* contents(Buffer* b) override { return b ? b->mapped : nullptr; }
    size_t size_bytes(Buffer* b) const override { return b ? b->bytes : 0; }

    bool copy(Buffer* dst, size_t dst_offset, Buffer* src, size_t src_offset,
              size_t bytes, std::string& error) override {
        if (!validate_copy(dst, dst_offset, src, src_offset, bytes, error)) return false;
        if (!bytes || (dst == src && dst_offset == src_offset)) return true;
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        const auto start = diagnostic_start();
        if (!submit_sync([&](VkCommandBuffer command) {
                device_barrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                               VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT);
                VkBufferCopy range{VkDeviceSize(src_offset), VkDeviceSize(dst_offset), VkDeviceSize(bytes)};
                vkCmdCopyBuffer(command, src->handle, dst->handle, 1, &range);
                transfer_written(command);
            }, "Vulkan device copy", error)) return false;
        transfer_timing("copy", bytes, start);
        return true;
    }

    bool read(Buffer* src, size_t src_offset, void* dst, size_t bytes,
              std::string& error) override {
        if (!validate_read(src, src_offset, dst, bytes, error)) return false;
        if (!bytes) return true;
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        const auto start = diagnostic_start();
        if (!ensure_staging(read_staging_, std::min(bytes, staging_chunk_bytes_), true, error)) return false;
        for (size_t offset = 0; offset < bytes;) {
            const size_t chunk = std::min(bytes - offset, staging_chunk_bytes_);
            if (!submit_sync([&](VkCommandBuffer command) {
                device_barrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                               VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT);
                VkBufferCopy range{VkDeviceSize(src_offset + offset), 0, VkDeviceSize(chunk)};
                vkCmdCopyBuffer(command, src->handle, read_staging_.handle, 1, &range);
                VkBufferMemoryBarrier barrier{};
                barrier.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
                barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
                barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                barrier.buffer = read_staging_.handle;
                barrier.offset = 0;
                barrier.size = VkDeviceSize(chunk);
                vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                     VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1, &barrier, 0, nullptr);
            }, "Vulkan host readback", error) ||
                !mapped_range(read_staging_, chunk, false, error)) return false;
            std::memcpy(static_cast<unsigned char*>(dst) + offset, read_staging_.mapped, chunk);
            offset += chunk;
        }
        transfer_timing("read", bytes, start);
        return true;
    }

    bool dispatch(const char* kernel, const std::vector<Arg>& args,
                  size_t n_threads, std::string& error) override {
        if (n_threads == 0) return true;
        // Probe kernels must not recurse into the startup gate. A rejected
        // device stays rejected, including low-level callers that dispatch
        // without first calling check_math_mode themselves.
        if (kernel && std::strcmp(kernel, "spk_math_probe") != 0 &&
            std::strcmp(kernel, "spk_split_probe") != 0 && !check_math_mode(error)) return false;
        const KernelSpec* spec = find_kernel(kernel);
        if (!spec) { error = std::string("Vulkan kernel not ported: ") + (kernel ? kernel : "(null)"); return false; }
        if (args.size() != spec->bindings) {
            error = std::string(kernel) + ": wrong argument count";
            return false;
        }
        // One workgroup row while it fits (bit-identical to a plain 1D
        // dispatch); past maxComputeWorkGroupCount[0] -- 65535 on lavapipe and
        // Intel, the spec minimum, i.e. 16.7 M threads, less than a 24 MP
        // frame -- the groups fold into rows, and every kernel recovers the 1D
        // index with spk_global_index(). The surplus threads of the last row
        // fail the same bounds check the last partial workgroup always did.
        const size_t groups = (n_threads + spec->workgroup - 1) / spec->workgroup;
        const size_t max_x = properties_.limits.maxComputeWorkGroupCount[0];
        const size_t groups_x = std::min(groups, max_x);
        const size_t groups_y = (groups + groups_x - 1) / groups_x;
        if (groups_y > properties_.limits.maxComputeWorkGroupCount[1]) {
            error = "Vulkan dispatch exceeds maxComputeWorkGroupCount";
            return false;
        }
        // Inline uploads submit transfers too. Resolve them before taking the
        // non-recursive queue/command-pool lock; their BufferRefs stay live
        // through completion of the dispatch below.
        std::vector<BufferRef> inline_buffers;
        std::vector<VkDescriptorBufferInfo> infos(args.size());
        for (size_t i = 0; i < args.size(); ++i) {
            Buffer* b = args[i].buffer;
            if (!b && args[i].bytes && args[i].size) {
                inline_buffers.push_back(upload(args[i].bytes, args[i].size, error));
                if (!inline_buffers.back()) return false;
                b = inline_buffers.back().get();
            }
            if (!b) { error = std::string(kernel) + ": empty argument " + std::to_string(i); return false; }
            if (b->bytes > storage_range_limit_) {
                error = std::string(kernel) + ": buffer exceeds maxStorageBufferRange";
                return false;
            }
            infos[i] = {b->handle, 0, VkDeviceSize(b->bytes)};
        }

        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        ComputePipeline* pipeline = get_pipeline(*spec, error);
        if (!pipeline) return false;

        VkDescriptorPoolSize pool_size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, spec->bindings};
        VkDescriptorPoolCreateInfo pool_create{};
        pool_create.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_create.maxSets = 1;
        pool_create.poolSizeCount = 1;
        pool_create.pPoolSizes = &pool_size;
        VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
        VkResult result = vkCreateDescriptorPool(device_, &pool_create, nullptr, &descriptor_pool);
        if (result != VK_SUCCESS) { error = vk_error("vkCreateDescriptorPool", result); return false; }
        VkDescriptorSetAllocateInfo set_alloc{};
        set_alloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        set_alloc.descriptorPool = descriptor_pool;
        set_alloc.descriptorSetCount = 1;
        set_alloc.pSetLayouts = &pipeline->descriptors;
        VkDescriptorSet set = VK_NULL_HANDLE;
        result = vkAllocateDescriptorSets(device_, &set_alloc, &set);
        if (result != VK_SUCCESS) {
            error = vk_error("vkAllocateDescriptorSets", result);
            vkDestroyDescriptorPool(device_, descriptor_pool, nullptr);
            return false;
        }
        std::vector<VkWriteDescriptorSet> writes(args.size());
        for (uint32_t i = 0; i < args.size(); ++i) {
            writes[i] = {};
            writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[i].dstSet = set;
            writes[i].dstBinding = i;
            writes[i].descriptorCount = 1;
            writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[i].pBufferInfo = &infos[i];
        }
        vkUpdateDescriptorSets(device_, uint32_t(writes.size()), writes.data(), 0, nullptr);

        const bool submitted = submit_sync([&](VkCommandBuffer command) {
                device_barrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                               VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT);
                vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline->pipeline);
                vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline->layout,
                                        0, 1, &set, 0, nullptr);
                vkCmdDispatch(command, uint32_t(groups_x), uint32_t(groups_y), 1);
            }, "Vulkan compute dispatch", error);
        vkDestroyDescriptorPool(device_, descriptor_pool, nullptr);
        return submitted;
    }

    bool flush(std::string&) override { return true; }  // dispatch is synchronous for this milestone
    void* texture(Buffer* buffer, uint32_t width, uint32_t height,
                  uint32_t row_stride_px, std::string& error) override {
        if (!buffer || width == 0 || height == 0 || row_stride_px < width ||
            size_t(row_stride_px) * height * 4u * sizeof(uint16_t) != buffer->bytes) {
            error = "invalid Vulkan result buffer";
            return nullptr;
        }
        // A headless result is a separate CPU-owned RGBA16 copy. It remains
        // valid after the engine and VkDevice are destroyed, just as a Metal
        // texture keeps its own result alive after the render's buffers go.
        void* pixels = std::malloc(buffer->bytes);
        if (!pixels) { error = "cannot allocate Vulkan result pixels"; return nullptr; }
        if (!read(buffer, 0, pixels, buffer->bytes, error)) {
            std::free(pixels);
            return nullptr;
        }
        return pixels;
    }
    void release_texture(void* pixels) override { std::free(pixels); }
    uint32_t texture_row_alignment_px() const override { return 1; }
    uint32_t max_texture_dimension_2d() const override {
        return properties_.limits.maxImageDimension2D;
    }

    uint64_t begin_memory_observation() override {
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        const uint64_t token = ++observation_serial_;
        observations_.emplace(token, MemoryObservation{});
        update_high_water();
        return token;
    }
    MemoryObservation end_memory_observation(uint64_t token) override {
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        const auto it = observations_.find(token);
        if (it == observations_.end()) return {};
        const auto result = it->second;
        observations_.erase(it);
        return result;
    }
    PoolStats pool_stats() const override {
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        PoolStats out;
        out.audit = audit_;
        out.frame_high_water_bytes = frame_high_water_;
        for (const Buffer* b : buffers_) {
            if (b->persistent) {
                out.persistent_bytes += b->bytes;
                ++out.persistent_buffers;
            } else {
                out.total_bytes += b->bytes;
                ++out.buffers;
                if (b->refs) { out.live_bytes += b->bytes; ++out.live_buffers; }
                else { out.free_bytes += b->bytes; ++out.free_buffers; }
            }
        }
        return out;
    }
    size_t trim_pool(size_t keep_bytes) override {
        // Match transfer/dispatch lock order. Every queue submission is
        // synchronous, so owning this lock also makes staging safe to destroy.
        std::lock_guard<std::mutex> dispatch_lock(dispatch_mutex_);
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        size_t total = 0, freed = 0;
        for (const Buffer* b : buffers_) if (!b->persistent) total += b->bytes;
        std::vector<Buffer*> free;
        for (Buffer* b : buffers_) if (!b->persistent && b->refs == 0) free.push_back(b);
        std::sort(free.begin(), free.end(), [](Buffer* a, Buffer* b) { return a->bytes > b->bytes; });
        for (Buffer* b : free) {
            if (total <= keep_bytes) break;
            total -= b->bytes;
            freed += b->bytes;
            buffers_.erase(std::remove(buffers_.begin(), buffers_.end(), b), buffers_.end());
            destroy_buffer(b);
            delete b;
        }
        if (keep_bytes == 0) {
            const VkDeviceSize staging_freed = upload_staging_.allocation_bytes + read_staging_.allocation_bytes;
            destroy_buffer(&upload_staging_);
            destroy_buffer(&read_staging_);
            if (transfer_timings_ && staging_freed)
                std::fprintf(stderr, "{\"vulkan_staging_trim\":true,\"freed_bytes\":%llu,"
                    "\"upload_staging_bytes\":0,\"read_staging_bytes\":0}\n",
                    static_cast<unsigned long long>(staging_freed));
        }
        return freed;
    }
    size_t trim_pool_incompatible(size_t bytes, size_t min_bytes) override {
        if (bytes <= min_bytes) return 0;
        // Match trim_pool's lock order; every submission completes before the
        // dispatch lock is released. Staging and persistent storage stay put.
        std::lock_guard<std::mutex> dispatch_lock(dispatch_mutex_);
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        size_t freed = 0;
        for (auto it = buffers_.begin(); it != buffers_.end();) {
            Buffer* b = *it;
            if (!b->persistent && b->refs == 0 && b->bytes >= min_bytes && b->bytes < bytes) {
                freed += b->bytes;
                destroy_buffer(b);
                delete b;
                it = buffers_.erase(it);
            } else ++it;
        }
        return freed;
    }
    bool take_critical_pressure() override { return false; }

private:
    using Clock = std::chrono::steady_clock;
    static constexpr size_t kMaxStagingBytes = size_t(64) * 1024 * 1024;

    Clock::time_point diagnostic_start() const {
        return transfer_timings_ ? Clock::now() : Clock::time_point{};
    }

    void transfer_timing(const char* operation, size_t bytes, Clock::time_point start) const {
        if (!transfer_timings_) return;
        const double ms = std::chrono::duration<double, std::milli>(Clock::now() - start).count();
        // Staging is owned by this backend, outside the existing compute-pool
        // ledger. Record its actual allocations separately rather than making
        // that public ledger silently double-count host and device storage.
        std::fprintf(stderr,
            "{\"vulkan_transfer\":\"%s\",\"bytes\":%zu,\"elapsed_ms\":%.6f,"
            "\"upload_staging_bytes\":%llu,\"read_staging_bytes\":%llu}\n",
            operation, bytes, ms,
            static_cast<unsigned long long>(upload_staging_.allocation_bytes),
            static_cast<unsigned long long>(read_staging_.allocation_bytes));
    }

    // Caller holds dispatch_mutex_: one queue and command pool, and synchronous
    // completion before any staging allocation or pooled buffer can be reused.
    template <typename Record>
    bool submit_sync(Record&& record, const char* operation, std::string& error) {
        VkCommandBufferAllocateInfo allocate_info{};
        allocate_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocate_info.commandPool = command_pool_;
        allocate_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocate_info.commandBufferCount = 1;
        VkCommandBuffer command = VK_NULL_HANDLE;
        VkResult result = vkAllocateCommandBuffers(device_, &allocate_info, &command);
        if (result == VK_SUCCESS) {
            VkCommandBufferBeginInfo begin{};
            begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            result = vkBeginCommandBuffer(command, &begin);
            if (result == VK_SUCCESS) {
                record(command);
                result = vkEndCommandBuffer(command);
            }
            if (result == VK_SUCCESS) {
                VkSubmitInfo submit{};
                submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
                submit.commandBufferCount = 1;
                submit.pCommandBuffers = &command;
                result = vkQueueSubmit(queue_, 1, &submit, VK_NULL_HANDLE);
                if (result == VK_SUCCESS) result = vkQueueWaitIdle(queue_);
            }
            vkFreeCommandBuffers(device_, command_pool_, 1, &command);
        }
        if (result != VK_SUCCESS) { error = vk_error(operation, result); return false; }
        return true;
    }

    static void device_barrier(VkCommandBuffer command, VkPipelineStageFlags destination_stage,
                               VkAccessFlags destination_access) {
        VkMemoryBarrier barrier{};
        barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        barrier.dstAccessMask = destination_access;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, destination_stage,
                             0, 1, &barrier, 0, nullptr, 0, nullptr);
    }

    static void transfer_written(VkCommandBuffer command) {
        VkMemoryBarrier barrier{};
        barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &barrier, 0, nullptr, 0, nullptr);
    }

    bool ensure_staging(Buffer& staging, size_t bytes, bool readback, std::string& error) {
        if (staging.handle && staging.bytes >= bytes) return true;
        // The preceding synchronous transfer is complete. Free the previous
        // block before growing, so growth does not temporarily double staging.
        destroy_buffer(&staging);
        Buffer replacement;
        replacement.bytes = bytes;
        if (!create_buffer(replacement, error, true, readback)) return false;
        staging = replacement;
        return true;
    }

    bool mapped_range(const Buffer& staging, size_t bytes, bool flush, std::string& error) {
        if (staging.memory_flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) return true;
        // The entire allocation is mapped at offset zero. Extend the range to
        // nonCoherentAtomSize, or to the allocation end (the allowed exception
        // to the size multiple). This also covers allocations shorter than one
        // atom without flushing or invalidating unmapped memory.
        const VkDeviceSize atom = properties_.limits.nonCoherentAtomSize;
        VkDeviceSize size = VkDeviceSize(bytes);
        const VkDeviceSize remainder = size % atom;
        if (remainder) size += std::min(atom - remainder, staging.allocation_bytes - size);
        VkMappedMemoryRange range{};
        range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = staging.memory;
        range.offset = 0;
        range.size = size;
        const VkResult result = flush ? vkFlushMappedMemoryRanges(device_, 1, &range)
                                      : vkInvalidateMappedMemoryRanges(device_, 1, &range);
        if (result != VK_SUCCESS) {
            error = vk_error(flush ? "vkFlushMappedMemoryRanges" : "vkInvalidateMappedMemoryRanges", result);
            return false;
        }
        return true;
    }

    BufferRef upload_bytes(const void* data, size_t bytes, bool persistent, std::string& error) {
        if (!data) { error = "Vulkan upload data is null"; return {}; }
        return upload_data(data, nullptr, bytes, persistent, error);
    }

    BufferRef upload_narrowed(const double* data, size_t count, bool persistent, std::string& error) {
        if (!data) { error = "Vulkan f32 upload data is null"; return {}; }
        if (count > std::numeric_limits<size_t>::max() / sizeof(float)) {
            error = "Vulkan upload count overflows byte size"; return {};
        }
        return upload_data(nullptr, data, count * sizeof(float), persistent, error);
    }

    BufferRef upload_data(const void* raw, const double* narrow, size_t bytes,
                          bool persistent, std::string& error) {
        if (bytes % 4) { error = "Vulkan upload size must be 4-byte aligned"; return {}; }
        const auto start = diagnostic_start();
        BufferRef out = allocate(bytes, persistent, error);
        if (!out) return {};
        std::lock_guard<std::mutex> lock(dispatch_mutex_);
        if (!ensure_staging(upload_staging_, std::min(bytes, staging_chunk_bytes_), false, error)) return {};
        for (size_t offset = 0; offset < bytes;) {
            const size_t chunk = std::min(bytes - offset, staging_chunk_bytes_);
            if (narrow) {
                float* dst = static_cast<float*>(upload_staging_.mapped);
                for (size_t i = 0; i < chunk / sizeof(float); ++i)
                    dst[i] = float(narrow[offset / sizeof(float) + i]);
            } else {
                std::memcpy(upload_staging_.mapped, static_cast<const unsigned char*>(raw) + offset, chunk);
            }
            if (!mapped_range(upload_staging_, chunk, true, error)) return {};
            if (!submit_sync([&](VkCommandBuffer command) {
                device_barrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT);
                VkBufferMemoryBarrier host{};
                host.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
                host.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT;
                host.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
                host.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                host.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                host.buffer = upload_staging_.handle;
                host.offset = 0;
                host.size = VkDeviceSize(chunk);
                vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT,
                                     VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 1, &host, 0, nullptr);
                VkBufferCopy range{0, VkDeviceSize(offset), VkDeviceSize(chunk)};
                vkCmdCopyBuffer(command, upload_staging_.handle, out.get()->handle, 1, &range);
                transfer_written(command);
            }, "Vulkan upload", error)) return {};
            offset += chunk;
        }
        transfer_timing("upload", bytes, start);
        return out;
    }

    BufferRef allocate(size_t bytes, bool persistent, std::string& error) {
        if (bytes == 0 || bytes > std::numeric_limits<VkDeviceSize>::max()) {
            error = "invalid Vulkan buffer size";
            return {};
        }
        std::lock_guard<std::mutex> lock(buffers_mutex_);
        if (!persistent) {
            // Do not retain a full-resolution plane for a small preview or
            // constant request. Dispatch completion makes zero-ref blocks idle.
            for (auto it = buffers_.begin(); it != buffers_.end();) {
                Buffer* b = *it;
                if (bytes >= (size_t(1) << 20) && !b->persistent && b->refs == 0 && b->bytes > bytes &&
                    b->bytes - bytes > std::max(bytes, size_t(64) << 20)) {
                    destroy_buffer(b); delete b; it = buffers_.erase(it);
                } else ++it;
            }
            Buffer* best = nullptr;
            for (Buffer* b : buffers_)
                if (!b->persistent && b->refs == 0 && b->bytes >= bytes &&
                    b->bytes - bytes <= std::max(bytes, size_t(64) << 20) &&
                    (!best || b->bytes < best->bytes)) best = b;
            if (best) {
                best->refs = 1;
                best->requested_bytes = bytes;
                ++audit_.reuses;
                audit_.reuse_bytes_requested += bytes;
                audit_.reuse_bytes_taken += best->bytes;
                if (best->bytes > audit_.reuse_max_taken) {
                    audit_.reuse_max_taken = best->bytes;
                    audit_.reuse_max_taken_for_request = bytes;
                }
                update_high_water();
                return BufferRef(this, best);
            }
        }
        auto b = std::make_unique<Buffer>();
        b->bytes = bytes;
        b->requested_bytes = bytes;
        b->persistent = persistent;
        bool memory_pressure = false;
        if (!create_buffer(*b, error, false, false, &memory_pressure)) {
            if (!memory_pressure) return {};
            // Already under buffers_mutex_. Synchronous submissions and zero
            // references make these blocks safe to reclaim. Keep live images,
            // persistent caches and transfer staging intact for recovery.
            size_t freed = 0;
            for (auto it = buffers_.begin(); it != buffers_.end();) {
                Buffer* idle = *it;
                if (!idle->persistent && idle->refs == 0) {
                    freed += idle->allocation_bytes;
                    destroy_buffer(idle);
                    delete idle;
                    it = buffers_.erase(it);
                } else ++it;
            }
            if (!freed) return {};
            if (std::getenv("SPEKTRAFILM_NODE_MEMORY"))
                std::fprintf(stderr, "allocation_reclaim requested=%zu freed=%zu\n", bytes, freed);
            error.clear();
            // One retry only; a genuine live working-set shortage still fails.
            if (!create_buffer(*b, error)) return {};
        }
        Buffer* raw = b.release();
        buffers_.push_back(raw);
        if (persistent) ++audit_.persistent_allocations;
        else ++audit_.allocations;
        update_high_water();
        return BufferRef(this, raw);
    }

    void update_high_water() {
        size_t live = 0, resident = 0, requested = 0;
        for (const Buffer* b : buffers_) {
            if (!b->persistent && b->refs) {
                live += b->bytes;
                requested += b->requested_bytes;
            }
            resident += b->allocation_bytes;
        }
        frame_high_water_ = std::max(frame_high_water_, live);
        for (auto& item : observations_) {
            if (live > item.second.live_peak) item.second.requested_at_live_peak = requested;
            item.second.requested_live_peak = std::max(item.second.requested_live_peak, requested);
            item.second.live_peak = std::max(item.second.live_peak, live);
            item.second.resident_peak = std::max(item.second.resident_peak, resident);
        }
    }

    bool create_buffer(Buffer& b, std::string& error, bool staging = false, bool readback = false,
                       bool* memory_pressure = nullptr) {
        if (memory_pressure) *memory_pressure = false;
        VkBufferCreateInfo create{};
        create.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        create.size = VkDeviceSize(b.bytes);
        create.usage = staging ? (readback ? VK_BUFFER_USAGE_TRANSFER_DST_BIT : VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
                               : (VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                                  VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        create.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        VkResult result = vkCreateBuffer(device_, &create, nullptr, &b.handle);
        if (result != VK_SUCCESS) { error = vk_error("vkCreateBuffer", result); return false; }
        VkMemoryRequirements requirements{};
        vkGetBufferMemoryRequirements(device_, b.handle, &requirements);
        uint32_t memory_index = UINT32_MAX;
        int best_score = -1;
        for (uint32_t i = 0; i < memory_properties_.memoryTypeCount; ++i) {
            const auto flags = memory_properties_.memoryTypes[i].propertyFlags;
            const auto required = staging ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
            if (!(requirements.memoryTypeBits & (1u << i)) || !(flags & required)) continue;
            // Compute planes stay on the device. Staging is chosen separately:
            // CPU readback needs cached host memory, not a CPU mapping of VRAM.
            int score = 0;
            if (staging) {
                if (readback && (flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT)) score += 8;
                if (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) score += 4;
                if (!(flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) score += 2;
            } else if (!(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
                score += 1;
            }
            if (score > best_score) {
                memory_index = i;
                best_score = score;
            }
        }
        if (memory_index == UINT32_MAX) {
            error = staging ? "no host-visible Vulkan staging memory type" : "no device-local Vulkan compute memory type";
            destroy_buffer(&b);
            return false;
        }
        VkMemoryAllocateInfo allocate_info{};
#ifdef _WIN32
        // Device allocations can also consume Windows commit. Leave room for
        // the editor and for error recovery; physical RAM alone is insufficient.
        MEMORYSTATUSEX status{}; status.dwLength = sizeof(status);
        uint64_t reserve = 3ull << 30;
        // Diagnostic override can only increase protection. Allows recovery
        // testing without actually exhausting the machine's memory.
        if (const char* value = std::getenv("SPEKTRAFILM_TEST_COMMIT_RESERVE_GIB")) {
            if (std::strlen(value) <= 2 && *value >= '0' && *value <= '9') {
                char* end = nullptr;
                const unsigned long gib = std::strtoul(value, &end, 10);
                if (end && !*end && gib >= 3 && gib <= 64) reserve = uint64_t(gib) << 30;
            }
        }
        if (GlobalMemoryStatusEx(&status) &&
            (status.ullAvailPageFile <= reserve ||
             requirements.size > status.ullAvailPageFile - reserve)) {
            error = "Insufficient system commit budget for Vulkan allocation; retain preview and retry after freeing resources";
            if (memory_pressure) *memory_pressure = true;
            destroy_buffer(&b);
            return false;
        }
#endif
        allocate_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocate_info.allocationSize = requirements.size;
        allocate_info.memoryTypeIndex = memory_index;
        b.memory_type = memory_index;
        b.memory_flags = memory_properties_.memoryTypes[memory_index].propertyFlags;
        b.allocation_bytes = requirements.size;
        result = vkAllocateMemory(device_, &allocate_info, nullptr, &b.memory);
        if (result == VK_SUCCESS) result = vkBindBufferMemory(device_, b.handle, b.memory, 0);
        if (result == VK_SUCCESS && staging)
            result = vkMapMemory(device_, b.memory, 0, VK_WHOLE_SIZE, 0, &b.mapped);
        if (result != VK_SUCCESS) {
            error = vk_error("Vulkan buffer memory", result);
            if (memory_pressure) *memory_pressure =
                result == VK_ERROR_OUT_OF_HOST_MEMORY || result == VK_ERROR_OUT_OF_DEVICE_MEMORY;
            destroy_buffer(&b);
            return false;
        }
        if (transfer_timings_) {
            std::fprintf(stderr,
                "{\"vulkan_allocation\":\"%s\",\"bytes\":%zu,\"allocation_bytes\":%llu,"
                "\"memory_type\":%u,\"memory_flags\":%u,\"heap\":%u}\n",
                staging ? (readback ? "read_staging" : "upload_staging") : "compute",
                b.bytes, static_cast<unsigned long long>(b.allocation_bytes), b.memory_type,
                uint32_t(b.memory_flags), memory_properties_.memoryTypes[memory_index].heapIndex);
        }
        return true;
    }

    void destroy_buffer(Buffer* b) {
        if (b->mapped) vkUnmapMemory(device_, b->memory);
        if (b->handle) vkDestroyBuffer(device_, b->handle, nullptr);
        if (b->memory) vkFreeMemory(device_, b->memory, nullptr);
        b->mapped = nullptr;
        b->handle = VK_NULL_HANDLE;
        b->memory = VK_NULL_HANDLE;
        b->allocation_bytes = 0;
        b->memory_type = UINT32_MAX;
        b->memory_flags = 0;
    }

    ComputePipeline* get_pipeline(const KernelSpec& spec, std::string& error) {
        auto found = pipelines_.find(spec.name);
        if (found != pipelines_.end()) return &found->second;
        const std::string path = shader_dir_ + "/" + spec.name + ".spv";
        std::ifstream in(file_path(path), std::ios::binary | std::ios::ate);
        if (!in) { error = "cannot open Vulkan shader " + path; return nullptr; }
        const std::streamsize size = in.tellg();
        if (size <= 0 || size % 4) { error = "invalid SPIR-V file " + path; return nullptr; }
        std::vector<uint32_t> code(size_t(size) / 4);
        in.seekg(0);
        if (!in.read(reinterpret_cast<char*>(code.data()), size)) {
            error = "cannot read Vulkan shader " + path;
            return nullptr;
        }
        VkShaderModuleCreateInfo shader_create{};
        shader_create.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        shader_create.codeSize = size_t(size);
        shader_create.pCode = code.data();
        VkShaderModule shader = VK_NULL_HANDLE;
        VkResult result = vkCreateShaderModule(device_, &shader_create, nullptr, &shader);
        if (result != VK_SUCCESS) { error = vk_error("vkCreateShaderModule", result); return nullptr; }

        ComputePipeline p;
        std::vector<VkDescriptorSetLayoutBinding> bindings(spec.bindings);
        for (uint32_t i = 0; i < spec.bindings; ++i) {
            bindings[i].binding = i;
            bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            bindings[i].descriptorCount = 1;
            bindings[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
        }
        VkDescriptorSetLayoutCreateInfo desc_create{};
        desc_create.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        desc_create.bindingCount = spec.bindings;
        desc_create.pBindings = bindings.data();
        result = vkCreateDescriptorSetLayout(device_, &desc_create, nullptr, &p.descriptors);
        if (result == VK_SUCCESS) {
            VkPipelineLayoutCreateInfo layout_create{};
            layout_create.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            layout_create.setLayoutCount = 1;
            layout_create.pSetLayouts = &p.descriptors;
            result = vkCreatePipelineLayout(device_, &layout_create, nullptr, &p.layout);
        }
        if (result == VK_SUCCESS) {
            VkPipelineShaderStageCreateInfo stage{};
            stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
            stage.module = shader;
            stage.pName = "main";
            // constant_id 0: SPK_FUSED_FMA. Kernels that do not declare it
            // ignore the entry (Vulkan spec, VkSpecializationMapEntry).
            const VkBool32 fused = fused_fma_ != 0;
            const VkSpecializationMapEntry entry{0, 0, sizeof(VkBool32)};
            VkSpecializationInfo special{1, &entry, sizeof fused, &fused};
            stage.pSpecializationInfo = &special;
            VkComputePipelineCreateInfo pipeline_create{};
            pipeline_create.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
            pipeline_create.stage = stage;
            pipeline_create.layout = p.layout;
            result = vkCreateComputePipelines(device_, VK_NULL_HANDLE, 1, &pipeline_create,
                                              nullptr, &p.pipeline);
        }
        vkDestroyShaderModule(device_, shader, nullptr);
        if (result != VK_SUCCESS) {
            error = vk_error("Vulkan compute pipeline", result);
            if (p.pipeline) vkDestroyPipeline(device_, p.pipeline, nullptr);
            if (p.layout) vkDestroyPipelineLayout(device_, p.layout, nullptr);
            if (p.descriptors) vkDestroyDescriptorSetLayout(device_, p.descriptors, nullptr);
            return nullptr;
        }
        return &pipelines_.emplace(spec.name, p).first->second;
    }

    std::string shader_dir_;
    VkInstance instance_ = VK_NULL_HANDLE;
    VkPhysicalDevice physical_ = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties properties_{};
    // maxStorageBufferRange, unless probe_cpu_storage_range measured more.
    VkDeviceSize storage_range_limit_ = 0;
    // -1 unvalidated/rejected, 1 validated fused fma, 0 validated split.
    int fused_fma_ = -1;
    bool math_checked_ = false;
    std::string math_detail_;
    VkPhysicalDeviceMemoryProperties memory_properties_{};
    VkDevice device_ = VK_NULL_HANDLE;
    VkQueue queue_ = VK_NULL_HANDLE;
    uint32_t queue_family_ = 0;
    VkCommandPool command_pool_ = VK_NULL_HANDLE;
    std::unordered_map<std::string, ComputePipeline> pipelines_;
    mutable std::mutex buffers_mutex_;
    std::mutex dispatch_mutex_;
    Buffer upload_staging_;
    Buffer read_staging_;
    size_t staging_chunk_bytes_ = kMaxStagingBytes;
    bool transfer_timings_ = false;
    std::vector<Buffer*> buffers_;
    PoolAudit audit_;
    size_t frame_high_water_ = 0;
    uint64_t observation_serial_ = 0;
    std::unordered_map<uint64_t, MemoryObservation> observations_;
};

}  // namespace

Gpu* Gpu::create_vulkan(const std::string& shader_dir, std::string& error) {
    auto gpu = std::make_unique<VulkanGpu>(shader_dir);
    if (!gpu->initialize(error)) return nullptr;
    return gpu.release();
}

void Gpu::release_texture_static(void* pixels) { std::free(pixels); }

}  // namespace spk::gpu
#endif  // !__APPLE__
