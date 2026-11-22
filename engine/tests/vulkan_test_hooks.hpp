// Test-only entry points exported by the engine's Vulkan backend.
//
// Declared here, next to the tests that use them, rather than in a public
// header: the engine never calls these, and a shipping build pays a few unused
// symbols for exercising error paths without provoking a GPU
// reset on the developer's machine.
#pragma once

#include <cstdint>
#include <string>

#include "gpu/gpu.hpp"

namespace spk::gpu {

// Marks the Vulkan backend's device lost exactly as a real
// VK_ERROR_DEVICE_LOST would, without touching the live VkDevice. Returns
// false when `gpu` is not the Vulkan backend.
bool test_latch_device_lost(Gpu* gpu, std::string& error);

// Set byte limits on a test-owned Vulkan backend before issuing allocations.
bool test_set_buffer_limits(Gpu* gpu, uint64_t buffer_bytes, uint64_t allocation_bytes);

}  // namespace spk::gpu
