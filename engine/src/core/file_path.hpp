// file_path.hpp -- the engine's paths are UTF-8 (the C ABI says so).
//
// On POSIX a std::string is already what the filesystem takes, so this is the
// identity and the Apple build is unchanged. On Windows a narrow std::string
// handed to std::ifstream is read in the ANSI code page, which cannot name an
// install folder under a non-ASCII user name; going through char8_t makes it
// a wide path, which libstdc++ (MinGW) and MSVC both open with _wfopen.
#pragma once
#include <string>
#ifdef _WIN32
#include <filesystem>
#endif

namespace spk {

#ifdef _WIN32
inline std::filesystem::path file_path(const std::string& utf8) {
    auto path = std::filesystem::path(std::u8string(utf8.begin(), utf8.end()));
    // A Tauri resource directory may carry the verbatim \\?\ prefix.
    // Win32 does not translate '/' in that namespace; normalise separators
    // after callers append resource filenames, preserving long paths/UNC.
    path.make_preferred();
    return path;
}
#else
inline const std::string& file_path(const std::string& utf8) { return utf8; }
#endif

}  // namespace spk
