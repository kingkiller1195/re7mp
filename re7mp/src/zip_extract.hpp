#pragma once
// A small, strict ZIP reader with its own inflate (deflate decoder), so the updater can unpack a download without
// PowerShell, tar or any library. Portable (no OS calls), so it is tested on any machine.
//
// Supported: stored and deflated entries, classic (non-zip64), single-disk archives. Not supported, and refused with a
// message: encryption, zip64, other compression methods. Every entry's checksum and size are verified.
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace re7mp {

struct ZipEntry {
    std::string name;  // as stored (may be unsafe: pass it through zip_safe_name before using it as a path)
    uint32_t crc = 0;
    uint32_t compressed_size = 0;
    uint32_t size = 0;
    uint16_t method = 0;  // 0 stored, 8 deflate
    uint32_t local_offset = 0;
    bool is_dir = false;
};

// Decodes a raw deflate stream (RFC 1951). `max_out` stops a corrupt or malicious stream from filling memory.
bool inflate_raw(const uint8_t* in, size_t n, std::vector<uint8_t>& out, uint64_t max_out, std::string& err);

bool zip_list(const std::vector<uint8_t>& zip, std::vector<ZipEntry>& entries, std::string& err);

// Reads one entry's contents (inflating it) and checks its size and CRC-32. Refuses entries over `max_size`.
bool zip_read(const std::vector<uint8_t>& zip, const ZipEntry& entry, std::vector<uint8_t>& out, uint64_t max_size,
              std::string& err);

// "dir\\file.txt" -> "dir/file.txt". Returns "" for anything that could leave the destination folder or is not a plain
// relative path: absolute paths, drive letters, "..", empty names, control characters.
std::string zip_safe_name(const std::string& raw);

// The last path component of a (safe) zip name, compared case-insensitively against `want` ("dinput8.dll").
bool zip_name_is(const std::string& entry_name, const std::string& want);

}  // namespace re7mp
