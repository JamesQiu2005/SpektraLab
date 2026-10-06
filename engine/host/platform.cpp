#include "platform.hpp"

#include <atomic>
#include <thread>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <process.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <cerrno>
#include <unistd.h>
#endif

namespace spkhost {

std::filesystem::path utf8_path(const std::string& utf8) {
    std::u8string u(utf8.begin(), utf8.end());
    return std::filesystem::path(u);
}

std::string path_utf8(const std::filesystem::path& path) {
    const std::u8string u = path.u8string();
    return std::string(u.begin(), u.end());
}

void set_binary_stdio() {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
}

std::FILE* open_file(const std::filesystem::path& path, const char* mode) {
#ifdef _WIN32
    std::wstring wmode(mode, mode + std::char_traits<char>::length(mode));
    return _wfopen(path.c_str(), wmode.c_str());
#else
    return std::fopen(path.c_str(), mode);
#endif
}

bool read_file(const std::filesystem::path& path, std::vector<uint8_t>& out, std::string& error) {
    std::FILE* f = open_file(path, "rb");
    if (!f) { error = "cannot open " + path_utf8(path); return false; }
    out.clear();
    uint8_t chunk[1 << 16];
    size_t n;
    while ((n = std::fread(chunk, 1, sizeof chunk, f)) > 0) out.insert(out.end(), chunk, chunk + n);
    const bool bad = std::ferror(f) != 0;
    std::fclose(f);
    if (bad) { error = "read failed: " + path_utf8(path); return false; }
    return true;
}

static int process_id() {
#ifdef _WIN32
    return _getpid();
#else
    return int(getpid());
#endif
}

bool write_file_atomic(const std::filesystem::path& path, const std::vector<uint8_t>& bytes,
                       bool overwrite, std::string& error) {
    namespace fs = std::filesystem;
    static std::atomic<unsigned> counter{0};
    std::error_code ec;
    if (!overwrite && fs::exists(path, ec)) {
        error = "destination exists: " + path_utf8(path);
        return false;
    }
    const fs::path dir = path.has_parent_path() ? path.parent_path() : fs::path(".");
    if (!fs::is_directory(dir, ec)) {
        error = "destination folder does not exist: " + path_utf8(dir);
        return false;
    }
    const fs::path partial = dir / utf8_path("." + path_utf8(path.filename()) + ".partial-" +
                                             std::to_string(process_id()) + "-" +
                                             std::to_string(counter++));
    std::FILE* f = open_file(partial, "wb");
    if (!f) { error = "cannot create " + path_utf8(partial); return false; }
    const bool wrote = bytes.empty() || std::fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
    const bool closed = std::fclose(f) == 0;
    if (!wrote || !closed) {
        fs::remove(partial, ec);
        error = "write failed: " + path_utf8(partial);
        return false;
    }
#ifdef _WIN32
    const DWORD flags = MOVEFILE_WRITE_THROUGH | (overwrite ? MOVEFILE_REPLACE_EXISTING : 0);
    if (!MoveFileExW(partial.c_str(), path.c_str(), flags)) {
        fs::remove(partial, ec);
        error = "rename into place failed (" + std::to_string(GetLastError()) + "): " + path_utf8(path);
        return false;
    }
#else
    if (!overwrite) {
        // link(2) refuses an existing name atomically; rename would replace it.
        // Some filesystems (FAT, exFAT, some FUSE) have no hard links; there
        // the existence check above and a rename are the best available.
        if (::link(partial.c_str(), path.c_str()) != 0) {
            const int err = errno;
            if (err == EEXIST) {
                fs::remove(partial, ec);
                error = "destination exists: " + path_utf8(path);
                return false;
            }
            fs::rename(partial, path, ec);
            if (ec) {
                fs::remove(partial, ec);
                error = "rename into place failed: " + path_utf8(path);
                return false;
            }
            return true;
        }
        fs::remove(partial, ec);
    } else {
        fs::rename(partial, path, ec);
        if (ec) {
            fs::remove(partial, ec);
            error = "rename into place failed: " + path_utf8(path);
            return false;
        }
    }
#endif
    return true;
}

unsigned hardware_threads() {
    const unsigned n = std::thread::hardware_concurrency();
    return n ? n : 4;
}

}  // namespace spkhost
