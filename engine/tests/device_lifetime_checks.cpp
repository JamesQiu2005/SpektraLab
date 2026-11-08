// The app supplies its own MTLDevice. The engine must release the reference it
// retains, while preserving the caller's reference, on every teardown.
#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <spektralab/spk_engine.h>
#include <cstdio>
#include <string>
#include <vector>
#include "gpu/gpu.hpp"
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    auto pool = NS::TransferPtr(NS::AutoreleasePool::alloc()->init());
    auto device = NS::TransferPtr(MTL::CreateSystemDefaultDevice());
    if (!device) return 2;
    auto cycle = [&]() {
        auto inner = NS::TransferPtr(NS::AutoreleasePool::alloc()->init());
        spk_engine* engine = spk_engine_create(argv[1], device.get());
        if (!engine) { std::fprintf(stderr, "%s\n", spk_last_error(nullptr)); return false; }
        spk_engine_destroy(engine);
        return true;
    };
    for (int i = 0; i < 4; ++i) if (!cycle()) return 2;
    const auto before = device->retainCount();
    for (int i = 0; i < 32; ++i) if (!cycle()) return 2;
    const auto after = device->retainCount();
    std::printf("borrowed device: before=%lu after=%lu delta=%ld over 32 engines\n",
                before, after, long(after) - long(before));
    std::string error;
    auto* gpu = spk::gpu::Gpu::create_metal(device.get(), std::string(argv[1]) + "/spektralab.metallib", error);
    if (!gpu) return 2;
    auto external = NS::TransferPtr(device->newBuffer(4096, MTL::ResourceStorageModeShared));
    const auto external_refs = external->retainCount();
    // The Catalyst app lends its decoded planes instead of uploading copies.
    // Those bytes belong to the host and must never enter or leave our ledger.
    auto owned = gpu->alloc_persistent(1024, error);
    const auto ledger_before = gpu->pool_stats();
    bool borrowed_ok = true;
    for (int i = 0; i < 32; ++i) {
        {
            auto borrowed = gpu->borrow(external.get(), 4096, error);
            if (!borrowed) return 2;
            auto retained = borrowed;
            borrowed_ok = borrowed_ok && gpu->pool_stats().persistent_bytes == ledger_before.persistent_bytes;
        }
        const auto ledger = gpu->pool_stats();
        borrowed_ok = borrowed_ok && ledger.persistent_bytes == ledger_before.persistent_bytes &&
                      ledger.persistent_buffers == ledger_before.persistent_buffers &&
                      ledger.live_bytes == ledger_before.live_bytes && external->retainCount() == external_refs;
    }
    owned = {};
    borrowed_ok = borrowed_ok && gpu->pool_stats().persistent_bytes == 0 && gpu->pool_stats().persistent_buffers == 0;
    std::printf("borrowed buffer: ledger and caller retain count %s over 32 borrows\n", borrowed_ok ? "unchanged" : "FAILED");
    std::vector<float> large(2048, 1.0f);
    // An uploaded >4 KiB inline argument, followed by an invalid one, must be
    // safely released even when the caller tears down without flushing.
    bool accepted = gpu->dispatch("spk_affine3", {spk::gpu::Arg::inline_bytes(large.data(), large.size()), {}}, 1, error);
    delete gpu;
    std::printf("unsubmitted rejected dispatch: %s\n", error.c_str());
    return before == after && borrowed_ok && !accepted && error.find("argument 1 is empty") != std::string::npos ? 0 : 1;
}
