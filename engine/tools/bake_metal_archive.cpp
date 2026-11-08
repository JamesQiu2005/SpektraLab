// Build-machine native pipelines, an optional accelerator beside the portable IR.
// Run after metallib compilation. The runtime validates each descriptor and
// compiles the IR on an archive miss (different GPU, OS, toolchain, or shader).
#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include <Metal/Metal.hpp>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: bake_metal_archive input.metallib output.metalar\n");
        return 2;
    }
    auto pool = NS::TransferPtr(NS::AutoreleasePool::alloc()->init());
    auto device = NS::TransferPtr(MTL::CreateSystemDefaultDevice());
    if (!device) { std::fprintf(stderr, "no Metal device for archive baking\n"); return 1; }
    NS::Error* error = nullptr;
    auto fail = [&] {
        std::fprintf(stderr, "archive: %s\n", error && error->localizedDescription()
            ? error->localizedDescription()->utf8String() : "could not compile function");
        return 1;
    };
    auto library = NS::TransferPtr(device->newLibrary(NS::String::string(argv[1], NS::UTF8StringEncoding), &error));
    if (!library) return fail();
    auto archive_desc = NS::TransferPtr(MTL::BinaryArchiveDescriptor::alloc()->init());
    auto archive = NS::TransferPtr(device->newBinaryArchive(archive_desc.get(), &error));
    if (!archive) return fail();
    auto names = library->functionNames();
    for (NS::UInteger i = 0; i < names->count(); ++i) {
        auto function = NS::TransferPtr(library->newFunction(names->object<NS::String>(i)));
        if (!function) return fail();
        auto desc = NS::TransferPtr(MTL::ComputePipelineDescriptor::alloc()->init());
        desc->setComputeFunction(function.get());
        if (!archive->addComputePipelineFunctions(desc.get(), &error)) return fail();
    }
    if (!archive->serializeToURL(NS::URL::fileURLWithPath(NS::String::string(argv[2], NS::UTF8StringEncoding)), &error)) return fail();
    std::printf("archive: %lu pipelines for %s\n", names->count(), device->name()->utf8String());
    return 0;
}
