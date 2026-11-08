#include "disk_checkpoint.hpp"
#ifdef __APPLE__
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace spk {
namespace {
constexpr size_t kBudget = size_t(1024) << 20;
struct Header {
    uint64_t magic = 0x53504b5052454731ULL; // SPKPREG1: pre-grain, float32, v1
    uint64_t bytes = 0;
    uint32_t width = 0, height = 0;
};
double elapsed(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}
bool fault(const char* name) {
    const char* v = std::getenv("SPK_CHECKPOINT_TEST_FAULT");
    return v && std::strcmp(v, name) == 0;
}
bool force_admission_for_test() {
    const char* v = std::getenv("SPK_CHECKPOINT_TEST_FORCE_ADMISSION");
    return v && std::strcmp(v, "1") == 0;
}
void trace(const char* event, size_t bytes, double ms) {
    if (std::getenv("SPK_CHECKPOINT_TRACE"))
        std::fprintf(stderr, "[checkpoint] %s bytes=%zu io_ms=%.3f\n", event, bytes, ms);
}
bool transfer(int fd, void* memory, size_t size, off_t offset, bool write) {
    auto* bytes = static_cast<char*>(memory);
    size_t done = 0;
    while (done < size) {
        const size_t chunk = std::min(size_t(8) << 20, size - done);
        const ssize_t n = write ? pwrite(fd, bytes + done, chunk, offset + off_t(done))
                                : pread(fd, bytes + done, chunk, offset + off_t(done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        done += size_t(n);
    }
    return true;
}
}
DiskCheckpoint& DiskCheckpoint::shared() { static DiskCheckpoint slot; return slot; }
DiskCheckpoint::~DiskCheckpoint() { clear(); }
void DiskCheckpoint::clear() {
    if (file_) std::fclose(file_);
    file_ = nullptr;
    owner_.clear(); key_.clear(); info_ = {}; bytes_ = 0; write_ms_ = 0;
}
void DiskCheckpoint::release(const std::string& owner) {
    std::lock_guard<std::mutex> guard(lock_);
    if (owner_ == owner) clear();
}
bool DiskCheckpoint::restore(const std::string& owner, const std::string& key, gpu::Gpu* gpu,
                             Image& out, CheckpointInfo& info) {
    std::lock_guard<std::mutex> guard(lock_);
    if (!file_ || owner_ != owner) return false;
    if (key_ != key) { clear(); return false; }
    const auto start = std::chrono::steady_clock::now();
    Header expected; expected.bytes = bytes_; expected.width = info_.w; expected.height = info_.h;
    Header actual{};
    struct stat st{};
    const int fd = fileno(file_);
    if (fault("short")) ftruncate(fd, 0);
    if (fstat(fd, &st) != 0 || uint64_t(st.st_size) != sizeof(Header) + bytes_ ||
        !transfer(fd, &actual, sizeof(actual), 0, false) ||
        std::memcmp(&actual, &expected, sizeof(actual)) != 0) {
        clear(); trace("invalid", 0, elapsed(start)); return false;
    }
    Image candidate; candidate.w = info_.w; candidate.h = info_.h; candidate.c = 3;
    std::string ignored;
    candidate.buf = gpu->alloc(bytes_, ignored);
    if (!candidate.buf || !gpu->contents(candidate.buf.get()) || fault("read") ||
        !transfer(fd, gpu->contents(candidate.buf.get()), bytes_, sizeof(Header), false)) {
        clear(); trace("read-failed", 0, elapsed(start)); return false;
    }
    info = info_;
    out = std::move(candidate);
    const double read_ms = elapsed(start);
    trace("hit", bytes_, read_ms);
    // Admit only if one reuse pays the measured write + read cost. The current
    // restored image remains valid even if a slow device retires the slot here.
    if (!force_admission_for_test() && write_ms_ + read_ms >= info_.prefix_ms) {
        trace("retired-slow", bytes_, read_ms + write_ms_);
        clear();
    }
    return true;
}
bool DiskCheckpoint::save(const std::string& owner, const std::string& key, gpu::Gpu* gpu,
                          const Image& image, const CheckpointInfo& info) {
    // Probe only after an actual grain edit, never on the cold first render.
    // Skip trivial prefixes; measured write/read costs decide admission.
    const size_t bytes = image.bytes();
    if (!bytes || bytes > kBudget - sizeof(Header) || (!force_admission_for_test() && info.prefix_ms < 20.0)) return false;
    std::string ignored;
    if (!gpu->flush(ignored) || !gpu->contents(image.buf.get())) return false;
    std::lock_guard<std::mutex> guard(lock_);
    clear(); // never two files, even while replacing a different session's slot
    const auto start = std::chrono::steady_clock::now();
    FILE* candidate = fault("write") ? nullptr : std::tmpfile();
    if (!candidate) return false;
    const int fd = fileno(candidate);
    Header header; header.bytes = bytes; header.width = image.w; header.height = image.h;
    const bool ok = fcntl(fd, F_NOCACHE, 1) != -1 &&
        transfer(fd, &header, sizeof(header), 0, true) &&
        transfer(fd, gpu->contents(image.buf.get()), bytes, sizeof(header), true) && fsync(fd) == 0;
    const double write_ms = elapsed(start);
    if (!ok || (!force_admission_for_test() && write_ms * 2.0 >= info.prefix_ms)) {
        std::fclose(candidate);
        trace(ok ? "declined-slow" : "write-failed", bytes, write_ms);
        return false;
    }
    file_ = candidate; owner_ = owner; key_ = key; info_ = info;
    bytes_ = bytes; write_ms_ = write_ms;
    trace("saved", bytes, write_ms);
    return true;
}
} // namespace spk
#endif
