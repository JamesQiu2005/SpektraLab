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

// For the memory-pressure source (§3.2) and nothing else. Dispatch is in
// libSystem, so this adds a header and no link step; the `_f` variants below
// are the C function-pointer API, which is what keeps this a `.cpp` rather
// than a `.mm` (see the file header).
#include <dispatch/dispatch.h>

#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdlib>
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
    // Persistent *and* backed by a file rather than by this process's ledger,
    // so `release` knows to keep `file_backed_bytes_` honest (RFC-020 §4.7).
    bool file_backed = false;
    // Queued in `pending_` and not yet reclaimed. A second `release` for the
    // same buffer would otherwise queue it twice, and the duplicate is what
    // turns a caller's mistake into a use-after-free: `trim_pool` frees the
    // buffer through one entry and leaves the other naming freed memory, for
    // the next `reclaim` to write through. Found by forcing a double release
    // to prove the audit can fire -- it crashed instead of reporting.
    //
    // **Why this branch and not the one §3.4 declined.** `reclaim` could have
    // grown a branch for `refs > 0` buffers and it deliberately did not,
    // because that one would have *absorbed* the evidence that the accounting
    // is wrong: the state it would handle is the state that indicts the
    // caller. This one is the reverse. The duplicate does not hide the
    // mistake, it is what makes the mistake lethal, so refusing it turns an
    // unobservable use-after-free into a counted refusal -- which is the only
    // reason `over_releases` can fire and be read at all, rather than the
    // process dying before anyone can look at the counter. If this is ever
    // removed, remove the counter with it.
    bool in_pending = false;
};

namespace {

constexpr size_t kThreadgroup = 256;
// How long the engine waits, with no frame in flight, before giving the pool
// back (RFC-020 §3.1's idle form). One constant and no adaptation: RFC-020 §7
// leaves policy to RFC-021, and this has to stay a swap for it rather than a
// thing with opinions. Chosen from the measurement in
// `engine/tests/idle_trim.py` rather than from taste; the comment on
// `maybe_trim_idle` carries the number it was chosen against.
constexpr double kIdleTrimSeconds = 60.0;
// A small constant goes in as `setBytes`, which avoids an allocation and a
// residency entry. 4 kB is Metal's documented limit for it.
constexpr size_t kInlineLimit = 4096;

class MetalGpu final : public Gpu {
public:
    MetalGpu(MTL::Device* device, bool owns_device, MTL::Library* library, MTL::CommandQueue* queue)
        : device_(device), owns_device_(owns_device), library_(library), queue_(queue) {}

    ~MetalGpu() override {
        // First, so no handler can be running (or start) while the pool below
        // is being torn down.
        stop_monitors();
        for (Buffer* b : pool_) { if (b->mtl) b->mtl->release(); delete b; }
        for (auto& kv : pipelines_) kv.second->release();
        if (command_buffer_) command_buffer_->release();
        if (queue_) queue_->release();
        if (library_) library_->release();
        if (device_ && owns_device_) device_->release();
    }

    // The pressure source (§3.2) and the idle timer (§3.1). Called by
    // `create_metal` once the object exists, because both sources' context is
    // `this` and neither may fire at an object whose constructor has not
    // returned. Public only for that reason -- `MetalGpu` is file-local and
    // nothing else constructs one.
    //
    // Best-effort: if either object cannot be made, the engine renders exactly
    // as it did before and `pool_stats().pressure_monitor` says so. Nothing
    // about a render may depend on this existing.
    void start_monitors() {
        pressure_queue_ = dispatch_queue_create("com.spektrafilm.engine.memorypressure", nullptr);
        if (!pressure_queue_) return;
        pressure_source_ = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
            DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, pressure_queue_);
        if (!pressure_source_) {
            dispatch_release(pressure_queue_);
            pressure_queue_ = nullptr;
            return;
        }
        dispatch_set_context(pressure_source_, this);
        dispatch_source_set_event_handler_f(pressure_source_, &MetalGpu::pressure_event);
        dispatch_activate(pressure_source_);
        // Read once, here, where nothing can race with it (see the seam's
        // comment further down).
        const char* mode = std::getenv("SPEKTRAFILM_TEST_PRESSURE");
        if (mode && std::strcmp(mode, "critical") == 0) {
            test_pressure_flags_ = DISPATCH_MEMORYPRESSURE_CRITICAL;
        } else if (mode && std::strcmp(mode, "warn") == 0) {
            test_pressure_flags_ = DISPATCH_MEMORYPRESSURE_WARN;
        }

        // The idle timer, on the same queue: a serial queue is what makes the
        // two handlers mutually exclusive without a lock of their own, and it
        // is what `stop_monitors` drains once for both.
        const double idle_s = idle_trim_seconds();
        if (idle_s > 0.0) {
            idle_source_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, pressure_queue_);
            if (idle_source_) {
                // Tick at a quarter of the threshold, capped, so the trim
                // lands within a quarter of it of the moment it is due and a
                // timer that is going to sit there for a minute does not wake
                // the CPU more than it has to. The leeway is for coalescing,
                // which is what a leeway is for; it delays the trim by at most
                // that much and the threshold is not a promise to be exact.
                const double tick_s = std::max(0.25, std::min(idle_s / 4.0, 5.0));
                const uint64_t tick_ns = uint64_t(tick_s * 1e9);
                dispatch_source_set_timer(idle_source_,
                                          dispatch_time(DISPATCH_TIME_NOW, int64_t(tick_ns)),
                                          tick_ns, tick_ns / 4);
                dispatch_set_context(idle_source_, this);
                dispatch_source_set_event_handler_f(idle_source_, &MetalGpu::idle_tick);
                dispatch_activate(idle_source_);
            }
        }
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
        // A frame in flight, counted rather than flagged: two renders on two
        // threads are legal, and a bool would have the first one to finish
        // say the engine is idle while the second is still running. The idle
        // timer reads this and never trims a pool a render is using.
        frames_in_flight_.fetch_add(1, std::memory_order_relaxed);
        last_activity_ns_.store(steady_ns(), std::memory_order_relaxed);
        // Before the reset, and outside the lock (the handler takes it): a
        // `warn` arriving here trims to the *previous* frame's peak, which is
        // the right reading for an event that lands between frames -- the next
        // render is that frame.
        fire_test_pressure_if_asked();
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
        // What changes is where "keep it" ends: on a frame switch (§3.1), on
        // memory pressure (§3.2) and after the idling that means nobody is
        // editing this frame any more -- each of which means the next render
        // is not the one these buffers were made for.
        last_activity_ns_.store(steady_ns(), std::memory_order_relaxed);
        frames_in_flight_.fetch_sub(1, std::memory_order_relaxed);
        fire_test_pressure_if_asked();
    }

    void retain(Buffer* buffer) override {
        if (!buffer) return;
        std::lock_guard<std::mutex> guard(pool_lock_);
        // The `refs == 0` arm is the counter's definition rather than a
        // reachable case -- nothing copies a handle to a buffer that has
        // none (see `reclaim`). Kept so `live_bytes_` follows the count
        // wherever the count goes, instead of following it only where it
        // happens to go today.
        // **And a persistent buffer is not a pool buffer here either.** Its
        // bytes are counted in `persistent_bytes_` by `alloc_persistent` and
        // belong to no pool sum; letting one in here would leave it in
        // `live_bytes_` for good, because `release` now correctly declines to
        // subtract it.
        if (!buffer->persistent && buffer->refs == 0) add_live_locked(buffer->bytes);
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
        // **A persistent buffer is not a pool buffer.** `live_bytes_` is the
        // pool's running sum -- `alloc_persistent` counts its bytes in
        // `persistent_bytes_` and nowhere else -- so subtracting one here made
        // the two sums disagree by a whole plane's worth. This is what the wrap
        // was: the session's source plane, subtracted by a `release` that no
        // `add` had ever matched.
        if (was_live && !buffer->persistent) sub_live_locked(buffer->bytes);
        else if (!was_live) ++audit_.over_releases;   // a release of a buffer nobody holds
        if (buffer->persistent) {
            persistent_bytes_ -= buffer->bytes;
            --persistent_buffers_;
            if (buffer->file_backed) {
                file_backed_bytes_ -= buffer->bytes;
                --file_backed_buffers_;
            }
            // A one-off size nothing else would want: give it back to the OS.
            if (buffer->mtl) buffer->mtl->release();
            delete buffer;
            return;
        }
        // Already queued: this release is one too many for a buffer nobody
        // holds any more, and pushing it again is the difference between an
        // anomaly the audit can report and a use-after-free in `trim_pool`.
        // Counted, reported, and not pushed.
        if (buffer->in_pending) {
            ++audit_.over_releases;
            return;
        }
        // **Not** reusable yet. The last handle going away means no *future*
        // dispatch names this buffer; it says nothing about the dispatches
        // already encoded into the open command buffer, which have not run.
        // Handing it to the next `alloc` here let a later kernel overwrite a
        // buffer an earlier one had not read yet -- 25 of 27 render-parity
        // cases, with no crash and no error. It becomes reusable at `flush`,
        // which is also where the reference evaluates (AGENTS.md trap 5).
        buffer->in_pending = true;
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
        ++audit_.allocations;
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
        ++audit_.persistent_allocations;
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

    // --- RFC-020 §4.7: planes whose pages live in a file -------------------

    // What `alloc_file_backed` is for, in one place.
    //
    // `phys_footprint` is what jetsam reads, and a `StorageModeShared`
    // MTLBuffer's pages are charged to it in full. A file-backed mapping's
    // are not: measured at 11664 x 8750 x 3ch x f32 (1.22 GB), 1.362 GB
    // against 0.137 GB -- ten times less -- with `mincore` reporting the
    // mapping fully resident and the GPU reading it at 1.00x. So a session's
    // source and its cached negatives, the two holdings RFC-020 §1 names as
    // living inside a session, cost the process about a tenth of what they
    // did, and the ~2.4 GB they add to a 102 MP peak mostly stops being
    // charged.
    //
    // Two things this design decided rather than inherited, both from
    // `rfc/probes/`:
    //
    //  * **No `msync`.** The benefit holds for *dirty* file-backed pages, so
    //    nothing forces a write-back and the kernel does it lazily, under
    //    pressure, if at all. `msync` costs 218-536 ms per plane and buys
    //    nothing.
    //  * **The file is unlinked before the first byte is written.** A named
    //    file would have to be cleaned up by something, and the something
    //    would have to survive a crash -- the same problem the app's disk
    //    cache needed a budget for. Measured (`/tmp/mmap_lifetime.swift`,
    //    three processes): named and unlinked are *identical*, 0.137 GB
    //    against the anonymous control's 1.362 GB. So the name exists for the
    //    duration of one `mkstemp` call and the inode is all that is kept. A
    //    process that dies while a plane is mapped leaves nothing behind: the
    //    kernel drops the inode with the last mapping. The residue of a crash
    //    *inside* `mkstemp` is one zero-length file in the user's temp
    //    directory, because `ftruncate` has not run yet.
    //
    // What is **not** measured, and must not be claimed: what a render pays
    // when the kernel has evicted these pages and has to fault them back.
    // `madvise(MADV_DONTNEED)` does not drop residency for a `MAP_SHARED`
    // mapping on macOS and a real squeeze is not something to induce on a
    // working machine, so that path stays inferred. RFC-020 §4.7 carries the
    // same qualification.
    static std::string scratch_dir() {
        // A test seam, the same shape as `SPEKTRAFILM_TEST_PRESSURE`: it is
        // the only way to reach the "no plane file can be made" branch, and a
        // branch no test reaches is a branch nobody has run. Unset, the
        // process's own scratch directory is used and this costs one
        // `getenv` per plane.
        const char* chosen = std::getenv("SPEKTRAFILM_PLANE_DIR");
        if (chosen && *chosen) return std::string(chosen);
        // `confstr` rather than `TMPDIR`: the environment is the caller's to
        // change and this is not. A path that does not fit is not a path.
        char buf[PATH_MAX];
        const size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, buf, sizeof buf);
        if (n > 0 && n <= sizeof buf) return std::string(buf);
        const char* fallback = std::getenv("TMPDIR");
        return (fallback && *fallback) ? std::string(fallback) : std::string("/tmp");
    }

    BufferRef alloc_file_backed(size_t bytes, std::string& error) override {
        if (bytes == 0) { error = "zero-length allocation"; return {}; }
        // Metal requires a page-aligned pointer, which `mmap` gives, and a
        // length that is a multiple of the page, which it does not: 16 kB
        // pages here, so a 1,223,000,000-byte plane maps 1,223,008,256. What
        // the pool and the report call the buffer stays the requested size.
        const size_t page = static_cast<size_t>(getpagesize());
        const size_t mapped = (bytes + page - 1) / page * page;

        std::string path = scratch_dir() + "/spektrafilm-plane-XXXXXX";
        const int fd = mkstemp(path.data());
        if (fd < 0) {
            // An optimisation that cannot run is not a reason to fail an open.
            // Visible rather than silent: `file_backed_bytes` does not grow.
            return alloc_persistent(bytes, error);
        }
        unlink(path.data());   // before a byte is written; the fd keeps the inode
        if (ftruncate(fd, static_cast<off_t>(mapped)) != 0) {
            error = "could not size a plane file: " + std::string(std::strerror(errno));
            close(fd);
            return {};
        }
        void* base = mmap(nullptr, mapped, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (base == MAP_FAILED) {
            error = "could not map a " + std::to_string(bytes) + "-byte plane: " +
                    std::string(std::strerror(errno));
            close(fd);
            return {};
        }
        close(fd);   // the mapping holds the inode; nothing needs the descriptor

        // The deallocator is the whole reason this is safe rather than lucky.
        // Metal calls it when the last reference to the buffer is gone --
        // including the references its own command buffers take -- so the
        // unmap happens exactly when nothing can reach the pages, not when
        // this process's last handle drops. That is the one moment
        // `munmap` may run, and the API is the only thing that knows it.
        // Non-capturing, so clang emits it as a constant and there is no
        // block to copy.
        MTL::Buffer* mtl = device_->newBuffer(base, mapped, MTL::ResourceStorageModeShared,
                                             ^(void* p, NS::UInteger length) { munmap(p, length); });
        if (!mtl) {
            // `newBuffer` did not take the deallocator's ownership, so this
            // mapping is still ours to drop.
            munmap(base, mapped);
            error = "out of GPU memory mapping " + std::to_string(bytes) + " bytes";
            return {};
        }
        Buffer* b = new Buffer{mtl, bytes, 1, false, true, /*file_backed=*/true};
        std::lock_guard<std::mutex> guard(pool_lock_);
        persistent_bytes_ += bytes;
        file_backed_bytes_ += bytes;
        ++persistent_buffers_;
        ++file_backed_buffers_;
        ++audit_.persistent_allocations;
        return BufferRef(this, b);
    }

    BufferRef upload_file_backed(const void* data, size_t bytes, std::string& error) override {
        BufferRef b = alloc_file_backed(bytes, error);
        if (b) std::memcpy(contents(b.get()), data, bytes);
        return b;
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
        // back to the pool once the work has run -- and it has run, or this
        // line is not reached.
        //
        // **Before `reclaim`, not when this function returns** (RFC-020
        // §3.4). As a destructor it ran after `reclaim()` had swept
        // `pending_`, so every buffer released here landed in an already-
        // swept `pending_` and waited for the *next* flush to become
        // reusable: one whole flush of the pool's largest, longest-lived
        // buffers spent dead. Nothing decides when `flush` is called, so
        // that is a wait with no bound on it. The destructor arm is kept for
        // the early returns that deliberately skip `reclaim` on failure, and
        // `clear()` twice in a row is a no-op.
        struct ReleaseInflight {
            std::vector<BufferRef>* v;
            ~ReleaseInflight() { v->clear(); }
            void now() { v->clear(); }
        } inflight{&inflight_};
        if (!command_buffer_) { inflight.now(); reclaim(); return true; }
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
        inflight.now();
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
        s.file_backed_bytes = file_backed_bytes_;
        s.file_backed_buffers = file_backed_buffers_;
        s.pressure_warn_events = pressure_warn_.load(std::memory_order_relaxed);
        s.pressure_critical_events = pressure_critical_.load(std::memory_order_relaxed);
        s.pressure_critical_pending = critical_pending_.load(std::memory_order_relaxed);
        s.pressure_monitor = pressure_source_ != nullptr;
        s.idle_trim_seconds = idle_source_ ? idle_trim_seconds() : 0.0;
        s.idle_trims = idle_trims_.load(std::memory_order_relaxed);
        s.audit = audit_;
        return s;
    }

    // --- RFC-020 §3.1, §3.2: giving it back --------------------------------

    size_t trim_pool(size_t keep_bytes) override {
        std::lock_guard<std::mutex> guard(pool_lock_);
        size_t total = 0;
        for (const Buffer* b : pool_) total += b->bytes;
        if (total <= keep_bytes) return 0;
        size_t freed = 0;

        // Largest first. A render's pool is a handful of same-sized
        // full-frame planes plus small constant uploads, so taking the big
        // ones back is the whole of the effect and the small ones are not
        // worth an allocation each to recreate.
        std::vector<Buffer*> candidates;
        for (Buffer* b : pool_) if (b->refs == 0) candidates.push_back(b);
        std::sort(candidates.begin(), candidates.end(),
                  [](const Buffer* a, const Buffer* b) { return a->bytes > b->bytes; });

        for (Buffer* b : candidates) {
            if (total <= keep_bytes) break;
            total -= b->bytes;
            // `pool_` is where `b` came from. `pending_` may or may not name
            // it: a buffer at `refs == 0` that is not yet reusable is exactly
            // the one `release` queued, and leaving it there would be a
            // dangling pointer for the next `reclaim` to write through.
            pool_.erase(std::find(pool_.begin(), pool_.end(), b));
            auto queued = std::find(pending_.begin(), pending_.end(), b);
            if (queued != pending_.end()) pending_.erase(queued);
            if (b->mtl) b->mtl->release();
            delete b;
            freed += b->bytes;
        }
        return freed;
    }

    bool take_critical_pressure() override {
        // One atomic exchange, not a load and then a store: two renders on two
        // threads must not both report the same event as their own.
        return critical_pending_.exchange(false, std::memory_order_relaxed);
    }

private:
    // --- RFC-020 §3.1, the idle form: nobody is editing any more ----------

    // The other half of "not at `end_frame`". The pool is kept between renders
    // seconds apart because the same sizes come straight back; that reasoning
    // stops holding when the seconds become minutes, and the process is then
    // sitting on ~11 GB of dead capacity at 102 MP with nothing to show for
    // it. §3.2's pressure source does not cover this case: macOS memory
    // pressure is reactive, so on a machine with nothing else running it
    // never fires, and by the time it does the compressor is already
    // involved. This is the proactive form of the same decision.
    //
    // The cost of being wrong is bounded and measured -- see `idle_keep_bytes`
    // for why the target is zero and `engine/tests/idle_trim.py` for what the
    // next render pays.
    void maybe_trim_idle() {
        // The two constraints this file keeps re-learning, both structural:
        // never mid-render (a render's own pool is what it would be freeing,
        // and the buffers it is about to reuse are exactly the ones that would
        // go), and never inside `pool_lock_` -- `trim_pool` takes it, and this
        // handler holds nothing.
        if (frames_in_flight_.load(std::memory_order_relaxed) > 0) return;
        const int64_t last = last_activity_ns_.load(std::memory_order_relaxed);
        if (last == 0) return;   // no frame has ever run; nothing to give back
        const double idle_s =
            double(steady_ns() - last) / 1e9;
        if (idle_s < idle_trim_seconds()) return;
        if (trim_pool(idle_keep_bytes()) > 0) {
            idle_trims_.fetch_add(1, std::memory_order_relaxed);
        }
    }

    // **The one policy function**, so that a later RFC can replace this body
    // and nothing else (RFC-020 §7's rule about a single call site).
    //
    // Zero, and not the frame's live high-water, for the reason §3.1 gives for
    // not trimming at all between renders: keeping a size is a bet that the
    // same size comes back. Between renders that bet is good -- the user is
    // mid-edit. After a minute of nothing it is a bet on a user who may have
    // gone to lunch, and the whole point of an idle trim is to stop paying for
    // that bet. The high-water case is not lost either: that is what §3.2's
    // `warn` level is for, and it fires when the *system* says memory is
    // short rather than when the clock does.
    static size_t idle_keep_bytes() { return 0; }

    // Seconds, from the seam or from the constant, **read once** -- a
    // function-local static is initialized under the language's own lock and
    // every later read happens after it, which is the ordering the timer
    // handler needs and a plain member would not have. Latched, so like
    // `SPEKTRAFILM_TEST_PRESSURE` the variable has to be set before the engine
    // is created.
    //
    // A value of **0 means off** -- no timer at all, which is the control
    // `idle_trim.py` runs against and the switch a user could be given. A
    // value that does not parse is *not* off: a typo must not quietly disable
    // a behaviour, so it falls back to the shipped number.
    static double idle_trim_seconds() {
        static const double seconds = [] {
            const char* text = std::getenv("SPEKTRAFILM_IDLE_TRIM_SECONDS");
            if (!text || !*text) return kIdleTrimSeconds;
            char* end = nullptr;
            const double parsed = std::strtod(text, &end);
            if (end && *end == '\0' && parsed >= 0.0) return parsed;
            return kIdleTrimSeconds;
        }();
        return seconds;
    }

    static int64_t steady_ns() {
        return std::chrono::duration_cast<std::chrono::nanoseconds>(
                   std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    // --- RFC-020 §3.2: memory pressure ------------------------------------

    // `start_pressure_monitor` is up with the constructor: it needs to be
    // public for `create_metal`, and the queue and source it makes are its
    // only collaborators here.
    //
    // Undone in the destructor, in this order, because the handler touches
    // `*this`. Cancel stops *new* deliveries, the synchronous no-op drains one
    // that is already running (the queue is serial and FIFO, so it runs after
    // it), and only then is the source released. Without the drain there is a
    // window where a handler is between `dispatch_source_get_data` and
    // `pool_lock_` on a deleted object.
    void stop_monitors() {
        if (pressure_source_) dispatch_source_cancel(pressure_source_);
        if (idle_source_) dispatch_source_cancel(idle_source_);
        // One drain for both: the queue is serial, so a synchronous no-op
        // submitted now runs after any handler already running or queued, and
        // after a cancel no new one can be delivered.
        if (pressure_queue_ && (pressure_source_ || idle_source_)) {
            dispatch_sync_f(pressure_queue_, nullptr, &MetalGpu::noop);
        }
        if (pressure_source_) { dispatch_release(pressure_source_); pressure_source_ = nullptr; }
        if (idle_source_) { dispatch_release(idle_source_); idle_source_ = nullptr; }
        if (pressure_queue_) {
            dispatch_release(pressure_queue_);
            pressure_queue_ = nullptr;
        }
    }

    static void idle_tick(void* context) {
        static_cast<MetalGpu*>(context)->maybe_trim_idle();
    }

    static void pressure_event(void* context) {
        auto* self = static_cast<MetalGpu*>(context);
        self->handle_pressure(dispatch_source_get_data(self->pressure_source_));
    }

    static void noop(void*) {}

    // The seam's trampoline, on the same queue as the real one.
    static void test_pressure_event(void* context) {
        auto* self = static_cast<MetalGpu*>(context);
        self->handle_pressure(self->test_pressure_flags_);
    }

    // The handler body, taking the same `DISPATCH_MEMORYPRESSURE_*` flags the
    // source delivers, so the test seam below drives this and not a copy of it.
    //
    // Two constraints that are the ordinary shape of this file's bugs, both
    // structural rather than checked here: it runs on a dispatch queue while
    // a render may be running on another thread, so it must take `pool_lock_`
    // rather than being called with it held (it never is -- `trim_pool` is
    // what takes it, and this is not called from under it), and it must never
    // free a buffer with `refs > 0`, which is `trim_pool`'s own rule.
    void handle_pressure(unsigned long flags) {
        if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) {
            pressure_critical_.fetch_add(1, std::memory_order_relaxed);
            critical_pending_.store(true, std::memory_order_relaxed);
            // Everything the frame is not holding. Nothing else happens with
            // the flag: §4's striped mode is what would make a render already
            // encoded smaller, and it does not exist yet (RFC-020 §3.2).
            trim_pool(0);
            return;
        }
        if (flags & DISPATCH_MEMORYPRESSURE_WARN) {
            pressure_warn_.fetch_add(1, std::memory_order_relaxed);
            // Keep enough for the frame that is running -- its own live
            // high-water, which is what a render of this size needs -- and
            // give back the rest, which is a bigger frame's leftovers. Between
            // frames the value is the last frame's peak, which is the right
            // reading for the same reason: the next render is that frame.
            size_t keep = 0;
            {
                std::lock_guard<std::mutex> guard(pool_lock_);
                keep = frame_high_water_;
            }
            trim_pool(keep);
        }
    }

    // The test seam, and the reason it exists: a real memory-pressure event
    // cannot be induced without squeezing the whole machine (RFC-020 §4.7
    // declines to do that on a working one), so the path from the queue to the
    // trim would otherwise ship unexercised and a harness could only assert
    // that the numbers did not change.
    //
    // `SPEKTRAFILM_TEST_PRESSURE=warn|critical` delivers that event at each
    // frame boundary, through the real handler on the real queue -- the queue,
    // the handler, the trim, the flag and the counters are all the shipping
    // ones; what is synthetic is the kernel's decision to send it. Unset, this
    // costs one integer test per boundary and does nothing. The same shape as
    // `SPEKTRAFILM_NODE_TIMINGS`.
    //
    // Both boundaries, for two different things a harness has to see: at the
    // start, so the render about to run takes the flag and reports it; at the
    // end, so the trim's effect can be measured at a moment when no render is
    // in flight to grow the pool again.
    //
    // Synchronous on purpose: a harness has to be able to observe the effect
    // after the call rather than at a moment it does not control. `sync` still
    // runs the handler *on the queue*, which is the property that matters.
    // Called with `pool_lock_` released -- the handler takes it.
    void fire_test_pressure_if_asked() {
        if (!test_pressure_flags_ || !pressure_queue_) return;
        dispatch_sync_f(pressure_queue_, this, &MetalGpu::test_pressure_event);
    }

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
        if (best) {
            ++audit_.reuses;
            audit_.reuse_bytes_requested += bytes;
            audit_.reuse_bytes_taken += best->bytes;
            if (best->bytes > audit_.reuse_max_taken) {
                audit_.reuse_max_taken = best->bytes;
                audit_.reuse_max_taken_for_request = bytes;
            }
            best->refs = 1; best->reusable = false; add_live_locked(best->bytes);
        }
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
    // **Clamped, and counted.** `live_bytes_` is a running sum of pool buffers
    // at `refs > 0`, and a subtraction larger than it means that sum and the
    // reference counts have come apart -- which used to wrap the `size_t` to
    // `2^64 - 1` and, because `frame_high_water_` follows it, hand the
    // memory-pressure handler a trim target of eighteen exabytes. Clamping
    // keeps the number usable and `live_underflows` says the arithmetic is
    // wrong, rather than the size of the universe being the answer.
    void sub_live_locked(size_t bytes) {
        if (bytes > live_bytes_) {
            ++audit_.live_underflows;
            live_bytes_ = 0;
            return;
        }
        live_bytes_ -= bytes;
    }

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
    // The `refs == 0` filter is a **comment and not a branch** on purpose
    // (RFC-020 §3.4): the state it excludes cannot be reached, and a branch
    // nothing reaches is where a real defect hides (AGENTS.md,
    // guards-that-cannot-fire). The argument, in full, because the next
    // reader is the one who has to re-establish it:
    //
    //   `pending_` is pushed to in exactly one place, `release`, at the
    //   moment the count reaches zero. `refs` rises in exactly one place,
    //   `retain`, and `retain` is called from `BufferRef`'s copy constructor
    //   and copy assignment -- both of which need a live `BufferRef` to copy,
    //   and a buffer at `refs == 0` is by definition one whose last handle
    //   has been destroyed. So nothing can re-retain a buffer between the
    //   `release` that queued it and the `reclaim` that sweeps it, and the
    //   filter never has anything to filter.
    //
    // If that argument is ever wrong, the failure it guards is the worse of
    // the two: marking a live buffer reusable hands it to the next `alloc`
    // while a kernel is still reading it -- the 25-of-27 render-parity bug
    // the comment in `release` records, silent corruption rather than a
    // leak. So the guard stays, and the state it excludes being unreachable
    // is what is written down rather than what is assumed.
    void reclaim() {
        std::lock_guard<std::mutex> guard(pool_lock_);
        // Becoming reusable is only safe once the work that named these has
        // completed, which is the only thing `reclaim` is ever called after.
        // Counted rather than assumed: this is the ordering `flush` keeps.
        if (command_buffer_) ++audit_.reclaim_while_encoding;
        for (Buffer* b : pending_) {
            b->in_pending = false;
            if (b->refs == 0) b->reusable = true;
            else ++audit_.pending_held;
        }
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
    size_t file_backed_bytes_ = 0;      // a subset of the two above
    size_t file_backed_buffers_ = 0;

    // RFC-020 §3.2. Atomic because the handler runs on `pressure_queue_`
    // while a render runs on the caller's thread.
    std::atomic<uint64_t> pressure_warn_{0};
    std::atomic<uint64_t> pressure_critical_{0};
    std::atomic<bool> critical_pending_{false};
    dispatch_queue_t pressure_queue_ = nullptr;
    dispatch_source_t pressure_source_ = nullptr;
    unsigned long test_pressure_flags_ = 0;

    // RFC-020 §3.1's idle form. The timer fires on `pressure_queue_`, and
    // what it reads to decide is these two: how many frames are in flight (a
    // render's pool is not the timer's to take) and when the last one touched
    // the engine. Both are written by the render's thread and read by the
    // handler's.
    std::atomic<int> frames_in_flight_{0};
    std::atomic<int64_t> last_activity_ns_{0};
    std::atomic<uint64_t> idle_trims_{0};
    dispatch_source_t idle_source_ = nullptr;

    // Every field of this is written under `pool_lock_` and read under it, so
    // it needs no atomics of its own -- `pool_stats` copies it whole.
    PoolAudit audit_;
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
    auto* gpu = new MetalGpu(device, owns, library, queue);
    // After construction, and best-effort: the source's context is the object,
    // and a source that cannot be made leaves pressure unmonitored rather than
    // failing the engine. `MetalGpu`'s own destructor undoes it.
    gpu->start_monitors();
    return gpu;
}

}  // namespace spk::gpu
