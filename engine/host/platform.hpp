// platform.hpp -- the few things the host does differently on Windows.
//
// Every path on the wire is UTF-8 (HOST-PROTOCOL.md §1). On Windows a
// std::filesystem::path built from a narrow string would be read in the ANSI
// code page, so a photograph in a folder named in Chinese would not open;
// `utf8_path` goes through char8_t, which the standard defines as UTF-8, and
// every file below is opened through that path (wide Win32 APIs underneath).
#pragma once

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

namespace spkhost {

std::filesystem::path utf8_path(const std::string& utf8);
std::string path_utf8(const std::filesystem::path& path);

// stdin/stdout in binary mode (Windows translates \n otherwise).
void set_binary_stdio();

// fopen on a path, wide on Windows.
std::FILE* open_file(const std::filesystem::path& path, const char* mode);

bool read_file(const std::filesystem::path& path, std::vector<uint8_t>& out, std::string& error);

// Writes `bytes` to a hidden sibling `.<name>.partial-<pid>-<n>` and renames
// it into place, so a file lands whole or not at all (ARCHITECTURE §7.8).
// Refuses an existing destination unless `overwrite`.
bool write_file_atomic(const std::filesystem::path& path, const std::vector<uint8_t>& bytes,
                       bool overwrite, std::string& error);

unsigned hardware_threads();

}  // namespace spkhost
