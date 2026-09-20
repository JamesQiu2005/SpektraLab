// gpu.hpp -- the GPU layer, behind an interface narrow enough to swap.
//
// This is the abstraction the MSL-only decision (RFC-014 §6 step 1) was taken
// *with*: the kernels stay MSL and are not cross-compiled, but nothing above
// this header names Metal. A Vulkan backend would implement `Gpu` and supply
// its own SPIR-V for the same kernel names; the pipeline, the node bodies and
// the C ABI would not change.
//
// It is deliberately not a general compute abstraction. Five verbs cover every
// dispatch in the engine, because the render graph is a chain of full-frame
// kernels over tightly packed float32:
//
//     alloc / upload      get memory, put constants in it
//     dispatch            run a named kernel over N threads
//     flush               commit the batch and wait
//     read                bring a buffer's contents back to the host
//     texture             hand the canvas the pixels without copying them
//
// Two properties of this design are load-bearing rather than incidental.
//
// **Dispatches batch.** `dispatch` encodes into an open command buffer and
// returns; nothing is submitted until `flush`. A 21-node render is therefore
// one submission, not 21 -- which is what makes the per-node cost the kernel
// and not the round trip. The pipeline calls `flush` only where it must: a
// host read, a reduction it needs the value of, or the end of a render.
//
// **Buffers are reference-counted, into a pool.** `alloc` hands back a
// `BufferRef`; when the last handle to it goes out of scope the buffer returns
// to the pool and the *next* `alloc` of a compatible size reuses it.
//
// The first version of this reclaimed only at the end of a frame, and that was
// wrong in a way that only showed at full resolution. A render's peak
// footprint became the sum of every intermediate rather than the two or three
// that are live at once: 24 MP held ~11 buffers of 288 MB, one command buffer
// referenced all 3.2 GB simultaneously, and the render took **6.4 s instead of
// 0.8** -- a number that looks exactly like a CPU fallback and is not one. The
// pool itself is still kept across renders, because the alternative is a page
// fault per buffer (RFC-011: a trivial pointwise node then costs 16 ms instead
// of 4 at 45 MP).
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace spk::gpu {

// Opaque device memory. On Apple silicon this is shared storage, so
// `contents()` is a pointer into the same pages the GPU reads -- no staging,
// no copy.
struct Buffer;

class Gpu;

// A counted handle on a pooled buffer. Copy it and the buffer stays; drop the
// last one and it goes back to the pool, ready for the next node.
//
// This is what makes a linear node chain (`cur = next`) return each stage's
// memory as soon as the stage after it has run, without any node having to
// know which of its inputs is dead.
class BufferRef {
public:
    BufferRef() = default;
    BufferRef(Gpu* gpu, Buffer* buffer) : gpu_(gpu), buffer_(buffer) {}
    BufferRef(const BufferRef& other);
    BufferRef(BufferRef&& other) noexcept : gpu_(other.gpu_), buffer_(other.buffer_) {
        other.gpu_ = nullptr;
        other.buffer_ = nullptr;
    }
    BufferRef& operator=(const BufferRef& other);
    BufferRef& operator=(BufferRef&& other) noexcept;
    ~BufferRef();

    Buffer* get() const { return buffer_; }
    explicit operator bool() const { return buffer_ != nullptr; }
    void reset();

private:
    Gpu* gpu_ = nullptr;
    Buffer* buffer_ = nullptr;
};

// The pool's audit, for `engine/tests/pool_invariants.py` (RFC-020 §3).
//
// Counters rather than branches, and placed where a violation could actually
// arise rather than where it is vacuous by construction. `take_reusable_locked`
// selects on `refs == 0`, so re-checking that there would be checking the
// predicate; what *can* go wrong is upstream of it -- a buffer queued for
// reuse while a handle still exists, or made reusable while a command buffer
// that names it is still open. Those are the three that must stay zero.
struct PoolAudit {
    // Traffic. `reuses` are hand-outs served from the free set, `allocations`
    // are buffers made fresh; the two together are every buffer a node ever
    // got. `persistent_allocations` are the planes and tables that are never
    // pooled and must never be a reuse: the session's source and its cached
    // negatives.
    uint64_t allocations = 0;
    uint64_t reuses = 0;
    uint64_t persistent_allocations = 0;
    // The size relationship on a reuse, for pinning the policy as it is
    // rather than as someone might prefer it. `reuse_taken` is the buffer
    // handed over and `reuse_requested` what was asked for; by design there is
    // no upper bound, so a small request can take a full-frame plane when that
    // is what the pool holds -- and `max_taken_for_request` names the request
    // that took the largest one, so the ratio is a fact about an actual
    // hand-out rather than a statistic.
    uint64_t reuse_bytes_requested = 0;
    uint64_t reuse_bytes_taken = 0;
    size_t reuse_max_taken = 0;
    size_t reuse_max_taken_for_request = 0;
    // **These three must stay zero**, and each is a property argued in a
    // comment somewhere above. A comment cannot fail; these can.
    //   `pending_held`       a buffer queued for reuse while a handle exists
    //                        -- §3.4's defect two, which was established
    //                        unreachable by argument. This is how that
    //                        argument gets a runtime witness.
    //   `over_releases`      a release of a buffer nobody holds: the count
    //                        going below zero and being clamped back.
    //   `reclaim_while_encoding`  buffers made reusable while a command buffer
    //                        that may name them is open and unrun.
    //   `live_underflows`    a subtraction larger than `live_bytes_`, which is
    //                        the pool counter and the reference counts having
    //                        come apart. Clamped rather than wrapped, so the
    //                        anomaly lands here instead of in
    //                        `frame_high_water_bytes`, where it used to reach
    //                        the pressure handler as a trim target of eighteen
    //                        exabytes -- found 2026-09-20 by a two-session
    //                        sequence in `iir_peak.py`, and traced to
    //                        `release` subtracting a *persistent* buffer that
    //                        no `add` had ever counted.
    //
    //                        **It shipped in 1.0.2.** `be7705e` (the report)
    //                        and `a9021ff` (the handler) are both ancestors of
    //                        `spektralab-v1.0.2`, so on those installs the
    //                        warn-level trim has been sized from a wrapped sum
    //                        since the first frame switch of a session. Critical
    //                        still trims, nothing crashes and nothing renders
    //                        differently; the feature just stops doing anything.
    //                        Nothing in the suite saw it in two days, because
    //                        every accounting probe opened one session per
    //                        engine -- the one dimension nobody varied.
    uint64_t pending_held = 0;
    uint64_t over_releases = 0;
    uint64_t reclaim_while_encoding = 0;
    uint64_t live_underflows = 0;
};

// What the engine holds, for `spk_memory_report` (RFC-020 §3.3).
//
// Bytes are the sizes a buffer was **made** at, not the sizes callers asked
// for: `alloc` reuses the smallest free buffer that fits, so those differ, and
// the one the process pays for is the former.
//
// The three pool numbers partition `total_bytes` and are the whole reason this
// is a `free`/`pending` split rather than one "free" number: a buffer whose
// last handle has dropped is not necessarily one the next `alloc` may take
// (see the comment in `release`), so "how much could be given back right now"
// and "how much is dead but still named by an unrun command buffer" are
// different questions with different answers.
struct PoolStats {
    size_t total_bytes = 0;      // every pooled buffer: live + free + pending
    size_t live_bytes = 0;       // refs > 0 -- a node, an Image, or `inflight_`
    size_t free_bytes = 0;       // refs == 0 and reusable: the next alloc may take it
    size_t pending_bytes = 0;    // refs == 0, waiting on a command buffer
    size_t buffers = 0;
    size_t live_buffers = 0;
    size_t free_buffers = 0;
    size_t pending_buffers = 0;
    // The peak `live_bytes` reached inside the current frame. RFC-020 §3.2's
    // `warn` trim keeps the pool at this size: enough for the frame that is
    // running, and no more.
    size_t frame_high_water_bytes = 0;
    // Allocations *outside* the pool: a session's source and its cached
    // negatives, the baked tables, a render's rgba16 result. Not additive
    // with the pool numbers above -- these are not pooled buffers.
    size_t persistent_bytes = 0;
    size_t persistent_buffers = 0;
    // The part of `persistent` whose pages live in a file rather than in the
    // process's ledger (RFC-020 §4.7): **a subset of `persistent_bytes`, not
    // more of it**, and the same relationship `source_bytes` has. A consumer
    // weighing the engine's footprint may want to weigh these differently --
    // measured, the same 1.22 GB plane costs 1.362 GB of `phys_footprint` as
    // an ordinary shared buffer here (the control) and 0.137 GB this way.
    size_t file_backed_bytes = 0;
    size_t file_backed_buffers = 0;
    // RFC-020 §3.2. Cumulative, so a 2 s timer sees an event it slept through;
    // `critical_pending` is the one-shot flag the next `spk_render` takes.
    uint64_t pressure_warn_events = 0;
    uint64_t pressure_critical_events = 0;
    bool pressure_critical_pending = false;
    // Whether a memory-pressure source is registered at all. False on a
    // platform or a process where the source could not be created, in which
    // case the counters above stay zero because nothing would set them.
    bool pressure_monitor = false;
    // RFC-020 §3.1's idle form: the threshold it runs at (0 = the timer is
    // not armed), and how many times it has actually given something back.
    // Counted on the bytes freed rather than on the tick, because after the
    // threshold the timer keeps ticking and a trim of an empty pool is not an
    // event -- without that, an idle hour reads as hundreds of trims.
    double idle_trim_seconds = 0.0;
    uint64_t idle_trims = 0;
    PoolAudit audit;
};

// One dispatch's arguments, in buffer-index order. A small constant may be
// passed inline (`bytes`) instead of allocated; the backend decides how.
struct Arg {
    Buffer* buffer = nullptr;
    const void* bytes = nullptr;
    size_t size = 0;

    static Arg buf(Buffer* b) { return Arg{b, nullptr, 0}; }
    static Arg buf(const BufferRef& b) { return Arg{b.get(), nullptr, 0}; }
    template <typename T>
    static Arg inline_bytes(const T* p, size_t count) { return Arg{nullptr, p, count * sizeof(T)}; }
};

class Gpu {
public:
    virtual ~Gpu() = default;

    // `device` is the caller's `MTLDevice` (an `id<MTLDevice>`) or null to
    // create one. The engine retains what it is given for its lifetime, and
    // renders into textures that device can draw -- RFC-014 §2.2's whole
    // point, and the deletion of a 364 MB round trip in each direction.
    static Gpu* create_metal(void* device, const std::string& metallib_path, std::string& error);

    virtual std::string device_name() const = 0;

    // The fast-math probe. Returns false, with a message, when the kernels in
    // the loaded library were compiled with fast math -- which drifts `exp`
    // and fma contraction by up to 1.1e-5, past the float32 bar, silently
    // (RFC-014 §5.1 trap 1). Checked at engine creation, not trusted.
    virtual bool check_math_mode(std::string& detail) = 0;

    // Frame arena. `alloc` and `upload` return memory that lives until
    // `end_frame`; `begin_frame` resets the arena and reuses what it can.
    virtual void begin_frame() = 0;
    virtual void end_frame() = 0;

    // Counted. The buffer returns to the pool when the last handle drops.
    virtual BufferRef alloc(size_t bytes, std::string& error) = 0;
    virtual BufferRef alloc_zeroed(size_t bytes, std::string& error) = 0;
    virtual BufferRef upload(const void* data, size_t bytes, std::string& error) = 0;

    // Used only by `BufferRef`.
    virtual void retain(Buffer* buffer) = 0;
    virtual void release(Buffer* buffer) = 0;
    // float64 host data narrowed to float32 on the way in -- every constant
    // the setup maths produces arrives this way, and doing the narrowing here
    // means no caller keeps a float32 shadow copy.
    virtual BufferRef upload_f32(const double* data, size_t count, std::string& error) = 0;
    virtual BufferRef upload_u32(const uint32_t* data, size_t count, std::string& error) = 0;

    // The baked constants, and the results that outlive a render. Same
    // counted handle, different reclamation: a pooled buffer goes back to the
    // pool at zero references and one of these is *destroyed*, because its
    // size (a 192x192x3 LUT, a 64x720 table, a tier's rgba16) is not one a
    // later node would want.
    //
    // One lifetime model rather than two. The first version had
    // `release_persistent` alongside the pool and it was the seam every
    // ownership bug landed on.
    virtual BufferRef alloc_persistent(size_t bytes, std::string& error) = 0;
    virtual BufferRef upload_persistent(const void* data, size_t bytes, std::string& error) = 0;
    virtual BufferRef upload_persistent_f32(const double* data, size_t count, std::string& error) = 0;
    virtual BufferRef upload_persistent_u32(const uint32_t* data, size_t count, std::string& error) = 0;

    // A persistent allocation whose pages live in a **file** rather than in
    // the process's ledger (RFC-020 §4.7). Same lifetime as the pair below --
    // it is one of them, with different memory behind it -- and never pooled,
    // because a full-frame plane is not a size any node should be handed.
    //
    // The point is `phys_footprint`, the number jetsam reads. Measured at the
    // 102 MP plane size, the same 1.22 GB plane costs **1.362 GB** as an
    // ordinary shared buffer and **0.137 GB** this way -- ten times less --
    // while the pages are genuinely resident and the GPU reads them at the
    // same speed (rfc/probes/, and `files_are_light` in `metal_gpu.cpp` for
    // where the file goes and what happens to it).
    //
    // Falls back to an ordinary persistent allocation if the file cannot be
    // made, because this is an optimisation and an open that fails for it
    // would be the optimisation breaking the product. The fallback is visible
    // rather than silent: `pool_stats().file_backed_bytes` does not grow.
    virtual BufferRef alloc_file_backed(size_t bytes, std::string& error) = 0;
    virtual BufferRef upload_file_backed(const void* data, size_t bytes, std::string& error) = 0;

    // A caller's `id<MTLBuffer>`, wrapped without a copy. Retained while a
    // handle exists and released -- never pooled -- when the last one drops,
    // which is the persistent lifetime above with somebody else's memory in
    // it. Refused if the buffer belongs to another device or holds fewer
    // than `bytes`.
    //
    // For `spk_open_device` only, and only for the length of that call: the
    // frame goes through `spk_take_rgb` into the engine's own buffer and the
    // borrow ends when the call returns. Nothing may keep the handle, because
    // the caller reuses or frees the memory the moment it gets control back.
    virtual BufferRef borrow(void* mtl_buffer, size_t bytes, std::string& error) = 0;

    virtual void* contents(Buffer* b) = 0;
    virtual size_t size_bytes(Buffer* b) const = 0;

    virtual bool dispatch(const char* kernel, const std::vector<Arg>& args,
                          size_t n_threads, std::string& error) = 0;
    virtual bool flush(std::string& error) = 0;

    // A texture over `b`'s memory, RGBA16Unorm, `width` x `height`, rows
    // `row_stride_px` pixels apart. Zero copy, and returned **+1: the caller
    // owns it**.
    //
    // It is not arena-owned, and that is deliberate rather than an oversight
    // corrected: a render's result outlives the render, because the frontend
    // caches it. A Metal texture over a buffer retains that buffer, so
    // handing over the only reference is also what keeps the pixels alive
    // exactly as long as someone is looking at them.
    virtual void* texture(Buffer* b, uint32_t width, uint32_t height,
                          uint32_t row_stride_px, std::string& error) = 0;
    virtual void release_texture(void* texture) = 0;
    // `spk_result_free` gets a result, not an engine, and a texture handed out
    // +1 must be releasable without one.
    static void release_texture_static(void* texture);
    // The row alignment `texture` requires, in pixels of RGBA16.
    virtual uint32_t texture_row_alignment_px() const = 0;
    // The largest 2D texture side this device will make. 16384 on Apple
    // silicon today, but it is the device's answer rather than a constant:
    // the app draws the print and the original on `MTLTexture`s, so a frame
    // wider than this renders and then cannot be shown.
    virtual uint32_t max_texture_dimension_2d() const = 0;

    // --- RFC-020: what the engine holds, and giving it back ---------------

    // The pool's holdings, and the persistent allocations made outside it.
    //
    // Cheap by construction, because a UI timer reads it: one pass over a
    // couple of dozen handles under `pool_lock_`, summing sizes that were
    // fixed when each buffer was made. No Metal object is walked, retained or
    // asked anything, and nothing here can fail.
    virtual PoolStats pool_stats() const = 0;

    // Give memory back. Frees every pooled buffer with `refs == 0` -- in
    // descending size order, until the pool's total is at or below
    // `keep_bytes` (`0` means all of them) -- and removes it from the pool,
    // releasing the Metal buffer with it.
    //
    // **Never** a buffer with `refs > 0`: a live handle is a node mid-render
    // or a buffer `dispatch` is holding for a just-encoded kernel. The two
    // callers are a frame switch (RFC-020 §3.1, `keep_bytes == 0`) and the
    // memory-pressure handler (§3.2: the frame's live high-water for `warn`,
    // everything for `critical`).
    //
    // Unlike `alloc`, this is not on any render path and takes no encoder:
    // `pool_lock_` is taken here, so a caller holding it must not call this.
    //
    // Returns the bytes actually freed, so a caller can tell a trim that gave
    // something back from one that found an empty pool -- which is what the
    // idle timer's counter means, and what stops a tick that does nothing
    // from reading as an event.
    virtual size_t trim_pool(size_t keep_bytes) = 0;

    // Whether a **critical** memory-pressure event has arrived since the last
    // call, clearing the flag. One-shot on purpose (RFC-020 §3.2): the next
    // `spk_render` reads it, so `spk_progress` can say the render ran under
    // pressure, and every later render is not told about an event that
    // predates it. Warnings are not taken, only counted -- they are the same
    // kind of event at a lower level, and a counter answers the question a
    // report asks of them.
    virtual bool take_critical_pressure() = 0;
};

// --- BufferRef, once Gpu is complete ---------------------------------------

inline BufferRef::BufferRef(const BufferRef& other) : gpu_(other.gpu_), buffer_(other.buffer_) {
    if (gpu_ && buffer_) gpu_->retain(buffer_);
}

inline BufferRef& BufferRef::operator=(const BufferRef& other) {
    if (this == &other) return *this;
    if (other.gpu_ && other.buffer_) other.gpu_->retain(other.buffer_);
    reset();
    gpu_ = other.gpu_;
    buffer_ = other.buffer_;
    return *this;
}

inline BufferRef& BufferRef::operator=(BufferRef&& other) noexcept {
    if (this == &other) return *this;
    reset();
    gpu_ = other.gpu_;
    buffer_ = other.buffer_;
    other.gpu_ = nullptr;
    other.buffer_ = nullptr;
    return *this;
}

inline BufferRef::~BufferRef() { reset(); }

inline void BufferRef::reset() {
    if (gpu_ && buffer_) gpu_->release(buffer_);
    gpu_ = nullptr;
    buffer_ = nullptr;
}

}  // namespace spk::gpu
