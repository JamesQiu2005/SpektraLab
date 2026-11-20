#include "platform.hpp"

#include <atomic>
#include <thread>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <process.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#else
#include <cerrno>
#include <unistd.h>
#endif

namespace spkhost {

#ifdef _WIN32
static std::filesystem::path extended_windows_path(std::filesystem::path path) {
    if (path.native().size() < MAX_PATH) return path;
    path.make_preferred();
    const auto& wide = path.native();
    if (wide.starts_with(LR"(\\?\)") || wide.starts_with(LR"(\\.\)")) return path;
    // Win32 skips dot-segment and slash normalization after the prefix.
    const bool unc = wide.starts_with(LR"(\\)");
    if (!unc && !path.is_absolute()) return path;
    const DWORD capacity = GetFullPathNameW(wide.c_str(), 0, nullptr, nullptr);
    if (!capacity) return path;
    std::wstring normal(capacity, L'\0');
    const DWORD length = GetFullPathNameW(wide.c_str(), capacity, normal.data(), nullptr);
    if (!length || length >= capacity) return path;
    normal.resize(length);
    return unc ? std::filesystem::path(LR"(\\?\UNC\)" + normal.substr(2))
               : std::filesystem::path(LR"(\\?\)" + normal);
}
#endif

std::filesystem::path utf8_path(const std::string& utf8) {
    std::u8string u(utf8.begin(), utf8.end());
#ifdef _WIN32
    return extended_windows_path(std::filesystem::path(u));
#else
    return std::filesystem::path(u);
#endif
}

std::string path_utf8(const std::filesystem::path& path) {
    std::u8string u = path.u8string();
#ifdef _WIN32
    // Keep the implementation's Win32 namespace spelling off the wire.
    if (u.starts_with(u8R"(\\?\UNC\)")) {
        u = u8R"(\\)" + u.substr(8);
    } else if (u.starts_with(u8R"(\\?\)") && u.size() >= 7 && u[5] == u8':' && u[6] == u8'\\') {
        u.erase(0, 4);
    }
#endif
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
    return write_file_atomic(path, [&](std::FILE* f, std::string&) {
        return bytes.empty() || std::fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
    }, overwrite, error);
}

bool write_file_atomic(const std::filesystem::path& path,
                       const std::function<bool(std::FILE*, std::string&)>& writer,
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
    auto partial = dir / utf8_path("." + path_utf8(path.filename()) + ".partial-" +
                                    std::to_string(process_id()) + "-" +
                                    std::to_string(counter++));
#ifdef _WIN32
    partial = extended_windows_path(std::move(partial));
#endif
    std::FILE* f = open_file(partial, "wb");
    if (!f) { error = "cannot create " + path_utf8(partial); return false; }
    bool wrote = false;
    try { wrote = writer(f, error) && !std::ferror(f); }
    catch (...) { std::fclose(f); fs::remove(partial, ec); throw; }
    const bool closed = std::fclose(f) == 0;
    if (!wrote || !closed) {
        fs::remove(partial, ec);
        if (error.empty()) error = "write failed: " + path_utf8(partial);
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

std::vector<std::string> utf8_args(int argc, char** argv) {
    std::vector<std::string> out;
#ifdef _WIN32
    (void)argc; (void)argv;
    int n = 0;
    LPWSTR* wide = CommandLineToArgvW(GetCommandLineW(), &n);
    for (int i = 0; wide && i < n; ++i) {
        const int len = WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, nullptr, 0, nullptr, nullptr);
        std::string s(len > 0 ? size_t(len - 1) : 0, '\0');
        if (len > 1) WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, s.data(), len, nullptr, nullptr);
        out.push_back(std::move(s));
    }
    if (wide) LocalFree(wide);
#else
    for (int i = 0; i < argc; ++i) out.emplace_back(argv[i]);
#endif
    return out;
}

std::filesystem::path executable_dir(const char* argv0) {
#ifdef _WIN32
    (void)argv0;
    std::wstring buffer(32768, L'\0');
    const DWORD len = GetModuleFileNameW(nullptr, buffer.data(), DWORD(buffer.size()));
    buffer.resize(len);
    return std::filesystem::path(buffer).parent_path();
#else
    std::error_code ec;
    std::filesystem::path self = std::filesystem::read_symlink("/proc/self/exe", ec);
    if (ec) self = std::filesystem::canonical(argv0, ec);
    return self.parent_path();
#endif
}

void set_env(const char* name, const std::string& value) {
#ifdef _WIN32
    _putenv_s(name, value.c_str());
#else
    setenv(name, value.c_str(), 1);
#endif
}

}  // namespace spkhost
