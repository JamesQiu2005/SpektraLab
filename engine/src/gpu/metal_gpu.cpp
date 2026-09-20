// metal_gpu.cpp -- the Metal backend, through vendored metal-cpp.
//
// metal-cpp and not Objective-C++ (`.mm`), for the reason RFC-014 §2.2 gives:
// a `.mm` file is Apple-only by construction, which defeats the portability
// argument that chose C++ over Swift in the first place. metal-cpp is a
// *source* dependency vendored into the repo, not an install one, so it does
// not violate §0's "nothing to install".
//
// Ownership, stated once and then relied on everywhere: Swift owns the
// `MTLDevice` and the drawable; the engine owns everything it allocates and
// frees it in `end_frame` or in its destructor. No buffer is freed by the side
// that did not allocate it.
#include "gpu.hpp"

#include <Metal/Metal.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace spk::gpu {

// `Buffer` is opaque to every caller; here it is a Metal buffer plus the size
// the arena tracks it by.
struct Buffer {
    MTL::Buffer* mtl = nullptr;
    size_t bytes = 0;
    // 0 means "in the pool, free to reuse". Every `BufferRef` holds one count.
    int refs = 0;
    // Free *and* idle. A buffer is free when its last handle drops and idle
    // when the command buffer that last named it has completed; only both
    // together make it safe to hand out again.
    bool reusable = false;
    bool persistent = false;
};

namespace {

constexpr size_t kThreadgroup = 256;
// A small constant goes in as `setBytes`, which avoids an allocation and a
// residency entry. 4 kB is Metal's documented limit for it.
constexpr size_t kInlineLimit = 4096;

class MetalGpu final : public Gpu {
public:
    MetalGpu(MTL::Device* device, bool owns_device, MTL::Library* library, MTL::CommandQueue* queue)
        : device_(device), owns_device_(owns_device), library_(library), queue_(queue) {}

    ~MetalGpu() override {
        for (Buffer* b : pool_) { if (b->mtl) b->mtl->release(); delete b; }
        for (auto& kv : pipelines_) kv.second->release();
        if (command_buffer_) command_buffer_->release();
        if (queue_) queue_->release();
        if (library_) library_->release();
        if (device_ && owns_device_) device_->release();
    }

    std::string device_name() const override {
        return device_->name() ? device_->name()->utf8String() : "unknown";
    }

    bool check_math_mode(std::string& detail) override {
        // `a * b - a * b`: exactly 0 under fast math, and the rounding error
        // of `a*b` when the compiler is allowed to contract one product into
        // an fma but not to reassociate. Compared against the host's own
        // `fma(a, b, -(a*b))` rather than merely against zero, so a future
        // toolchain that stops contracting under safe math reports a mismatch
        // instead of a false pass.
        constexpr size_t n = 64;
        float in[2 * n];
        for (size_t i = 0; i < n; ++i) {
            in[2 * i] = 0.1f + 0.37f * float(i);
            in[2 * i + 1] = in[2 * i] * 0.5f + 1.0f;
        }
        begin_frame();
        std::string error;
        BufferRef src = upload(in, sizeof in, error);
        BufferRef dst = alloc(n * sizeof(float), error);
        if (!src || !dst) { detail = "math probe could not allocate: " + error; end_frame(); return false; }
        if (!dispatch("spk_math_probe", {Arg::buf(src), Arg::buf(dst)}, n, error) || !flush(error)) {
            detail = "math probe failed to run: " + error;
            end_frame();
            return false;
        }
        const float* got = static_cast<const float*>(contents(dst.get()));
        size_t zeros = 0, mismatched = 0;
        for (size_t i = 0; i < n; ++i) {
            const float a = in[2 * i], b = in[2 * i + 1];
            const float want = std::fma(a, b, -(a * b));
            if (got[i] == 0.0f) ++zeros;
            else if (got[i] != want) ++mismatched;
        }
        end_frame();
        if (zeros == n) {
            detail = "the Metal library was compiled with fast math: `a*b - a*b` came back "
                     "exactly zero for all 64 probes. Rebuild with "
                     "-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise "
                     "(RFC-014 §5.1 trap 1: fast math drifts exp and fma contraction by up to "
                     "1.1e-5, which is past the float32 bar and silent).";
            return false;
        }
        if (mismatched > 0) {
            detail = "the fast-math probe returned " + std::to_string(mismatched) +
                     " of 64 values that match neither zero nor the host's fma error term. "
                     "The toolchain's contraction behaviour has changed; re-derive the probe "
                     "in shaders/util.metal before trusting parity.";
            return false;
        }
        detail = "safe (probe: fma contraction present, no reassociation)";
        return true;
    }

    // The frame markers no longer reclaim anything -- reference counting does
    // that, continuously, which is the point. They remain as the place to hang
    // per-frame bookkeeping, and as an assertion: anything still referenced at
    // `end_frame` is a leak by a caller that kept a handle.
    void begin_frame() override {
        // A new frame's live high-water starts where the frame starts: what
        // some *other* frame still holds is not this one's to keep (RFC-020
        // §3.2).
        std::lock_guard<std::mutex> guard(pool_lock_);
        frame_high_water_ = live_bytes_;
    }

    void end_frame() override {
        // The pool itself is kept. Not because re-faulting it is expensive --
        // RFC-020 §1.2 measured that and it is not: minor faults barely move
        // between the trimmed and untrimmed builds, and the same measurement
        // shows what *is* expensive, which is residency past the compressor
        // threshold (1,377,634 system compressions during one 28 GB render,
        // against 0 at 19 GB). Within a session, editing one frame, every
        // size the pool holds comes straight back, and handing buffers to the
        // OS between nodes would buy the faults without the residency.
        //
        // What changes is where "keep it" ends: on a frame switch (§3.1) and
        // on memory pressure (§3.2), both of which mean the next render is
        // not the one these buffers were made for.
    }

    void retain(Buffer* buffer) override {
        if (!buffer) return;
        std::lock_guard<std::mutex> guard(pool_lock_);
        // The `refs == 0` arm is the counter's definition rather than a
        // reachable case -- nothing copies a handle to a buffer that has
        // none (see `reclaim`). Kept so `live_bytes_` follows the count
        // wherever the count goes, instead of following it only where it
        // happens to go today.
        if (buffer->refs == 0) add_live_locked(buffer->bytes);
        ++buffer->refs;
    }

    void release(Buffer* buffer) override {
        if (!buffer) return;
        std::lock_guard<std::mutex> guard(pool_lock_);
        // `was_live` rather than a plain decrement, because `refs` is clamped
        // below: an over-release took it to -1 and this line put it back to
        // 0, and the counter must not follow it down there.
        const bool was_live = buffer->refs > 0;
        if (--buffer->refs > 0) return;
        buffer->refs = 0;
        if (was_live) sub_live_locked(buffer->bytes);
        if (buffer->persistent) {
            persistent_bytes_ -= buffer->bytes;
            --persistent_buffers_;
            // A one-off size nothing else would want: give it back to the OS.
            if (buffer->mtl) buffer->mtl->release();
            delete buffer;
            return;
        }
        // **Not** reusable yet. The last handle going away means no *future*
        // dispatch names this buffer; it says nothing about the dispatches
        // already encoded into the open command buffer, which have not run.
        // Handing it to the next `alloc` here let a later kernel overwrite a
        // buffer an earlier one had not read yet -- 25 of 27 render-parity
        // cases, with no crash and no error. It becomes reusable at `flush`,
        // which is also where the reference evaluates (AGENTS.md trap 5).
        pending_.push_back(buffer);
    }

    BufferRef alloc(size_t bytes, std::string& error) override {
        if (bytes == 0) { error = "zero-length allocation"; return {}; }
        {
            // Reuse the smallest free buffer that fits, so a chain of
            // same-sized full-frame nodes recycles two or three buffers
            // rather than one per node.
            std::lock_guard<std::mutex> guard(pool_lock_);
            if (Buffer* best = take_reusable_locked(bytes)) return BufferRef(this, best);
        }
        // Nothing reusable fits. A long stretch with no flush in it can leave
        // most of the pool dead but not yet reclaimable: `release` puts a
        // buffer in `pending_` instead of marking it reusable, and only
        // `flush` -> `reclaim` promotes it. At 102 MP a full-frame buffer is
        // 1.22 GB, and the grain and diffusion stages
        // (`spk_grain_layer_one`, `spk_sep_fir_acc`, `spk_couplers_correction`)
        // run long enough with no flush in them to strand 13 GB of pending
        // buffers -- 19 of them, 13.1 GB -- while genuine concurrent liveness
        // is 11.0 GB. `alloc` then faults in 8 more at 1.22 GB each, for a
        // 28.9 GB peak on a 24 GB machine. Reference counting made the pool
        // reusable *across* flushes (AGENTS.md trap 5); nothing bounded a
        // stretch containing none. So before taking a fresh buffer, ask whether
        // a pending one would have served the request, and if so make it
        // genuine by flushing.
        //
        // Three things are load-bearing here:
        //
        //  1. **The lock is released before `flush`.** `flush` ends in
        //     `reclaim`, which takes `pool_lock_`; calling it from inside the
        //     `lock_guard` scope above would deadlock on a non-recursive
        //     mutex. That is why the scan and the flush are in separate scopes.
        //  2. **The 16 MB floor** keeps the flush off small constant uploads,
        //     where the submit-and-wait round trip costs more than the buffer.
        //  3. **`flush` contains `waitUntilCompleted`**, so this puts a
        //     synchronisation point inside `alloc`. The engine is fully
        //     synchronous today, which makes it free -- but it is a real
        //     barrier, and anyone who later overlaps encode with execute has
        //     to reckon with it here rather than discover it as a mystery
        //     stall in the profile.
        //
        // One more consequence, latent rather than live: this can end and
        // commit the *open* encoder, so a caller that took an encoder pointer
        // before calling in must not hold it across the call. `dispatch` is
        // the only caller that does, on the >4 KB inline-argument path, and no
        // kernel in the tree passes an inline argument within three orders of
        // magnitude of the 16 MB floor -- so it cannot fire today. A future
        // kernel with a multi-megabyte constant would have to bind its
        // arguments before taking the encoder.
        if (bytes >= (16u << 20)) {
            bool worth = false;
            {
                std::lock_guard<std::mutex> guard(pool_lock_);
                worth = pending_would_serve_locked(bytes);
            }
            if (worth) {
                // A failed flush falls through to a fresh buffer rather than
                // failing the render: the next real dispatch reports the same
                // failure with a better message anyway.
                std::string ignored;
                if (flush(ignored)) {
                    std::lock_guard<std::mutex> guard(pool_lock_);
                    if (Buffer* best = take_reusable_locked(bytes)) return BufferRef(this, best);
                }
            }
        }
        MTL::Buffer* mtl = device_->newBuffer(bytes, MTL::ResourceStorageModeShared);
        if (!mtl) {
            error = "out of GPU memory allocating " + std::to_string(bytes) + " bytes";
            return {};
        }
        Buffer* b = new Buffer{mtl, bytes, 1, false, false};
        std::lock_guard<std::mutex> guard(pool_lock_);
        pool_.push_back(b);
        add_live_locked(b->bytes);
        return BufferRef(this, b);
    }

    BufferRef alloc_zeroed(size_t bytes, std::string& error) override {
        BufferRef b = alloc(bytes, error);
        if (b) std::memset(b.get()->mtl->contents(), 0, bytes);
        return b;
    }

    BufferRef upload(const void* data, size_t bytes, std::string& error) override {
        BufferRef b = alloc(bytes, error);
        if (b) std::memcpy(b.get()->mtl->contents(), data, bytes);
        return b;
    }

    BufferRef upload_f32(const double* data, size_t count, std::string& error) override {
        BufferRef b = alloc(count * sizeof(float), error);
        if (!b) return {};
        float* dst = static_cast<float*>(b.get()->mtl->contents());
        for (size_t i = 0; i < count; ++i) dst[i] = float(data[i]);
        return b;
    }

    BufferRef upload_u32(const uint32_t* data, size_t count, std::string& error) override {
        return upload(data, count * sizeof(uint32_t), error);
    }

    BufferRef alloc_persistent(size_t bytes, std::string& error) override {
        if (bytes == 0) { error = "zero-length allocation"; return {}; }
        MTL::Buffer* mtl = device_->newBuffer(bytes, MTL::ResourceStorageModeShared);
        if (!mtl) { error = "out of GPU memory allocating " + std::to_string(bytes) + " bytes"; return {}; }
        Buffer* b = new Buffer{mtl, bytes, 1, false, true};
        // Counted, not pooled: this is what `spk_memory_report`'s `persistent`
        // block is, and it is where the session's source and cached negatives
        // live (RFC-020 §3.3).
        std::lock_guard<std::mutex> guard(pool_lock_);
        persistent_bytes_ += bytes;
        ++persistent_buffers_;
        return BufferRef(this, b);
    }

    BufferRef upload_persistent(const void* data, size_t bytes, std::string& error) override {
        BufferRef b = alloc_persistent(bytes, error);
        if (b) std::memcpy(b.get()->mtl->contents(), data, bytes);
        return b;
    }

    BufferRef upload_persistent_f32(const double* data, size_t count, std::string& error) override {
        BufferRef b = alloc_persistent(count * sizeof(float), error);
        if (!b) return {};
        float* dst = static_cast<float*>(b.get()->mtl->contents());
        for (size_t i = 0; i < count; ++i) dst[i] = float(data[i]);
        return b;
    }

    BufferRef upload_persistent_u32(const uint32_t* data, size_t count, std::string& error) override {
        return upload_persistent(data, count * sizeof(uint32_t), error);
    }

    BufferRef borrow(void* mtl_buffer, size_t bytes, std::string& error) override {
        auto* mtl = static_cast<MTL::Buffer*>(mtl_buffer);
        if (!mtl) { error = "no buffer to borrow"; return {}; }
        // A buffer from another device is not an error Metal reports: it is
        // a GPU fault at the first dispatch that names it.
        if (mtl->device() != device_) {
            error = "the frame's MTLBuffer belongs to a different MTLDevice than the engine's";
            return {};
        }
        if (mtl->length() < bytes) {
            error = "the frame's MTLBuffer holds " + std::to_string(mtl->length()) +
                    " bytes; the image needs " + std::to_string(bytes);
            return {};
        }
        mtl->retain();
        // `persistent`, so the last release gives the retain back and deletes
        // the wrapper rather than putting the caller's memory in the pool.
        //
        // Deliberately **not** in `persistent_bytes_`: the pixels are the
        // caller's and the caller already accounts for them (RFC-019's
        // `DecodeResidency`, 90 B/px against a measured 85). The engine
        // holding the only *other* reference to them for the length of one
        // call is not a holding of its own, and counting it would double the
        // decode in every report.
        return BufferRef(this, new Buffer{mtl, bytes, 1, false, true});
    }

    void* contents(Buffer* b) override { return b->mtl->contents(); }
    size_t size_bytes(Buffer* b) const override { return b->bytes; }

    bool dispatch(const char* kernel, const std::vector<Arg>& args,
                  size_t n_threads, std::string& error) override {
        if (n_threads == 0) return true;
        MTL::ComputePipelineState* pso = pipeline(kernel, error);
        if (!pso) return false;
        MTL::ComputeCommandEncoder* enc = encoder(error);
        if (!enc) return false;
        enc->setComputePipelineState(pso);
        for (size_t i = 0; i < args.size(); ++i) {
            const Arg& a = args[i];
            if (a.buffer) enc->setBuffer(a.buffer->mtl, 0, NS::UInteger(i));
            else if (a.bytes && a.size <= kInlineLimit) enc->setBytes(a.bytes, a.size, NS::UInteger(i));
            else if (a.bytes) {
                // Larger than `setBytes` allows. The handle lives until the
                // end of this dispatch call, which is long enough: the encoder
                // has already taken its own reference on the MTLBuffer.
                BufferRef tmp = upload(a.bytes, a.size, error);
                if (!tmp) return false;
                enc->setBuffer(tmp.get()->mtl, 0, NS::UInteger(i));
                inflight_.push_back(std::move(tmp));
            } else { error = std::string(kernel) + ": argument " + std::to_string(i) + " is empty"; return false; }
        }
        const size_t width = std::min<size_t>(pso->maxTotalThreadsPerThreadgroup(), kThreadgroup);
        enc->dispatchThreads(MTL::Size(n_threads, 1, 1), MTL::Size(width, 1, 1));
        return true;
    }

    bool flush(std::string& error) override {
        // Anything held only for an encoded-but-unsubmitted dispatch can go
        // back to the pool once the work has run.
        struct Clear { std::vector<BufferRef>* v; ~Clear() { v->clear(); } } clear{&inflight_};
        if (!command_buffer_) { reclaim(); return true; }
        if (encoder_) { encoder_->endEncoding(); encoder_ = nullptr; }
        command_buffer_->commit();
        command_buffer_->waitUntilCompleted();
        const MTL::CommandBufferStatus status = command_buffer_->status();
        if (status == MTL::CommandBufferStatusError) {
            NS::Error* err = command_buffer_->error();
            error = std::string("GPU command buffer failed: ") +
                    (err && err->localizedDescription() ? err->localizedDescription()->utf8String() : "unknown");
            command_buffer_->release();
            command_buffer_ = nullptr;
            return false;
        }
        command_buffer_->release();
        command_buffer_ = nullptr;
        reclaim();
        return true;
    }

    void* texture(Buffer* b, uint32_t width, uint32_t height,
                  uint32_t row_stride_px, std::string& error) override {
        MTL::TextureDescriptor* desc = MTL::TextureDescriptor::alloc()->init();
        desc->setTextureType(MTL::TextureType2D);
        desc->setPixelFormat(MTL::PixelFormatRGBA16Unorm);
        desc->setWidth(width);
        desc->setHeight(height);
        desc->setUsage(MTL::TextureUsageShaderRead);
        desc->setStorageMode(MTL::StorageModeShared);
        MTL::Texture* tex = b->mtl->newTexture(desc, 0, size_t(row_stride_px) * 8);
        desc->release();
        if (!tex) { error = "could not create a texture over the result buffer"; return nullptr; }
        // `newTexture` is already +1 and the texture retains `b->mtl`, so the
        // caller now holds the only reference it needs. Not tracked here.
        return tex;
    }

    void release_texture(void* texture) override {
        if (texture) static_cast<MTL::Texture*>(texture)->release();
    }

    uint32_t texture_row_alignment_px() const override {
        // `minimumLinearTextureAlignmentForPixelFormat` is in bytes; RGBA16 is
        // 8 bytes per pixel. Asking the device beats hardcoding 256 B, which
        // is right on today's Macs and is not a promise.
        const NS::UInteger bytes = device_->minimumLinearTextureAlignmentForPixelFormat(
            MTL::PixelFormatRGBA16Unorm);
        const uint32_t px = uint32_t(std::max<NS::UInteger>(bytes, 8) / 8);
        return px == 0 ? 1 : px;
    }

    uint32_t max_texture_dimension_2d() const override {
        // The largest texture side this device will make. It matters because
        // the app draws the print and the original on `MTLTexture`s, so a
        // frame whose long edge is past it renders and then cannot be shown.
        //
        // **Metal does not publish this.** There is `maxBufferLength` and
        // `maxThreadsPerThreadgroup`; there is no `maxTextureDimension` in the
        // SDK's `MTLDevice.h` at all (checked, not assumed — this first sent
        // that selector and the device answered `unrecognized selector`).
        // Neither can it be probed for: asking `newTexture` for a 32768-wide
        // descriptor is not a nil return but `MTLTextureDescriptor`'s own
        // assertion — "width (32768) greater than the maximum allowed size of
        // 16384" — which takes the process with it.
        //
        // So the family is asked instead, and 16384 is the answer for every
        // family that answers: Apple7 and up, and Mac2. That covers every
        // Metal-capable Mac. A device that answers none of them is older than
        // this build supports, and 16384 is still the safe reading there — the
        // only thing it can do is refuse a frame too big to be drawn.
        const bool known = device_->supportsFamily(MTL::GPUFamilyMac2) ||
                           device_->supportsFamily(MTL::GPUFamilyApple7);
        return known ? 16384u : 8192u;
    }

    // --- RFC-020 §3.3: what the pool holds --------------------------------

    PoolStats pool_stats() const override {
        std::lock_guard<std::mutex> guard(pool_lock_);
        PoolStats s;
        for (const Buffer* b : pool_) {
            s.total_bytes += b->bytes;
            if (b->refs > 0) { s.live_bytes += b->bytes; ++s.live_buffers; }
            else if (b->reusable) { s.free_bytes += b->bytes; ++s.free_buffers; }
            else { s.pending_bytes += b->bytes; ++s.pending_buffers; }
        }
        s.buffers = pool_.size();
        s.frame_high_water_bytes = frame_high_water_;
        s.persistent_bytes = persistent_bytes_;
        s.persistent_buffers = persistent_buffers_;
        return s;
    }

private:
    MTL::ComputePipelineState* pipeline(const char* name, std::string& error) {
        auto it = pipelines_.find(name);
        if (it != pipelines_.end()) return it->second;
        NS::String* fn_name = NS::String::string(name, NS::UTF8StringEncoding);
        MTL::Function* fn = library_->newFunction(fn_name);
        if (!fn) {
            error = std::string("no kernel '") + name + "' in spektrafilm.metallib";
            return nullptr;
        }
        NS::Error* err = nullptr;
        MTL::ComputePipelineState* pso = device_->newComputePipelineState(fn, &err);
        fn->release();
        if (!pso) {
            error = std::string("could not build a pipeline for '") + name + "': " +
                    (err && err->localizedDescription() ? err->localizedDescription()->utf8String() : "unknown");
            return nullptr;
        }
        pipelines_[name] = pso;
        return pso;
    }

    // Caller holds `pool_lock_`. The smallest free buffer that fits, taken
    // (its reference is handed to the caller).
    Buffer* take_reusable_locked(size_t bytes) {
        Buffer* best = nullptr;
        for (Buffer* b : pool_)
            if (b->refs == 0 && b->reusable && b->bytes >= bytes &&
                (!best || b->bytes < best->bytes)) best = b;
        if (best) { best->refs = 1; best->reusable = false; add_live_locked(best->bytes); }
        return best;
    }

    // `live_bytes_` is the running sum of the pool buffers at `refs > 0`, and
    // `frame_high_water_` its peak within the current frame. Every arm that
    // changes `refs` goes through these two, so the number follows the count
    // rather than being re-derived from it (a walk of the pool would be just
    // as cheap, but `trim_pool` can then ask the question without one).
    //
    // Pool buffers only: a persistent allocation is not one of these, and
    // `pool_stats` reports it separately.
    void add_live_locked(size_t bytes) {
        live_bytes_ += bytes;
        if (live_bytes_ > frame_high_water_) frame_high_water_ = live_bytes_;
    }
    void sub_live_locked(size_t bytes) { live_bytes_ -= bytes; }

    // Caller holds `pool_lock_`. A buffer whose last handle has dropped but
    // which is not reusable yet, because the command buffer that names it has
    // not run. It would serve this request if it had.
    bool pending_would_serve_locked(size_t bytes) {
        for (Buffer* b : pending_)
            if (b->refs == 0 && b->bytes >= bytes) return true;
        return false;
    }

    // Everything freed since the last flush is now genuinely idle: the work
    // that referenced it has completed.
    //
    void reclaim() {
        std::lock_guard<std::mutex> guard(pool_lock_);
        for (Buffer* b : pending_) if (b->refs == 0) b->reusable = true;
        pending_.clear();
    }

    MTL::ComputeCommandEncoder* encoder(std::string& error) {
        if (!command_buffer_) {
            command_buffer_ = queue_->commandBuffer();
            if (!command_buffer_) { error = "could not open a command buffer"; return nullptr; }
            command_buffer_->retain();
            encoder_ = nullptr;
        }
        if (!encoder_) {
            encoder_ = command_buffer_->computeCommandEncoder();
            if (!encoder_) { error = "could not open a compute encoder"; return nullptr; }
        }
        return encoder_;
    }

    MTL::Device* device_ = nullptr;
    bool owns_device_ = false;
    MTL::Library* library_ = nullptr;
    MTL::CommandQueue* queue_ = nullptr;
    MTL::CommandBuffer* command_buffer_ = nullptr;
    MTL::ComputeCommandEncoder* encoder_ = nullptr;
    std::unordered_map<std::string, MTL::ComputePipelineState*> pipelines_;
    mutable std::mutex pool_lock_;
    std::vector<Buffer*> pool_;
    std::vector<Buffer*> pending_;
    // Buffers created to back an oversized inline argument, kept alive until
    // the command buffer that references them has completed.
    std::vector<BufferRef> inflight_;

    // RFC-020 §3.3. All four are maintained under `pool_lock_` in the two
    // helpers below, never re-derived here -- `pool_stats` re-derives them
    // anyway, so a drift would show up as a disagreement rather than as a
    // wrong number nobody can check.
    size_t live_bytes_ = 0;
    size_t frame_high_water_ = 0;
    size_t persistent_bytes_ = 0;
    size_t persistent_buffers_ = 0;

};

}  // namespace

void Gpu::release_texture_static(void* texture) {
    if (texture) static_cast<MTL::Texture*>(texture)->release();
}

Gpu* Gpu::create_metal(void* device_handle, const std::string& metallib_path, std::string& error) {
    MTL::Device* device = static_cast<MTL::Device*>(device_handle);
    const bool owns = device == nullptr;
    if (owns) device = MTL::CreateSystemDefaultDevice();
    if (!device) { error = "no Metal device"; return nullptr; }
    if (!owns) device->retain();   // the caller keeps its own reference

    NS::Error* err = nullptr;
    NS::String* path = NS::String::string(metallib_path.c_str(), NS::UTF8StringEncoding);
    MTL::Library* library = device->newLibrary(path, &err);
    if (!library) {
        error = "cannot load " + metallib_path + ": " +
                (err && err->localizedDescription() ? err->localizedDescription()->utf8String() : "unknown");
        device->release();
        return nullptr;
    }
    MTL::CommandQueue* queue = device->newCommandQueue();
    if (!queue) {
        error = "cannot create a Metal command queue";
        library->release();
        device->release();
        return nullptr;
    }
    return new MetalGpu(device, owns, library, queue);
}

}  // namespace spk::gpu
