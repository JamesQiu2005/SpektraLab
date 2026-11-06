// Test-only entry points exported by the engine's Vulkan backend.
//
// Declared here, next to the tests that use them, rather than in a public
// header: the engine never calls these, and a shipping build pays one unused
// symbol for being able to test the fail-fast policy without provoking a GPU
// reset on the developer's machine.
#pragma once

#include <string>

#include "gpu/gpu.hpp"

namespace spk::gpu {

// Marks the Vulkan backend's device lost exactly as a real
// VK_ERROR_DEVICE_LOST would, without touching the live VkDevice. Returns
// false when `gpu` is not the Vulkan backend.
bool test_latch_device_lost(Gpu* gpu, std::string& error);

}  // namespace spk::gpu
