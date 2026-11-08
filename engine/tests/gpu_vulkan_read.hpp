// Test readback helper. Keep the entire allocation, including every guard,
// visible to the existing assertions without relying on mapped GPU memory.
#pragma once
#include <cstdio>
#include <string>
#include <vector>
#include "gpu/gpu.hpp"

template <typename T>
bool read_test_buffer(spk::gpu::Gpu* gpu, const spk::gpu::BufferRef& buffer,
                      std::vector<T>& values, std::string& error) {
    const size_t bytes = gpu->size_bytes(buffer.get());
    if (!buffer || bytes % sizeof(T)) {
        error = "test readback has an invalid buffer or element size";
        std::fprintf(stderr, "readback: %s\n", error.c_str());
        return false;
    }
    values.resize(bytes / sizeof(T));
    if (!gpu->read(buffer.get(), 0, values.data(), bytes, error)) {
        std::fprintf(stderr, "readback: %s\n", error.c_str());
        return false;
    }
    return true;
}
