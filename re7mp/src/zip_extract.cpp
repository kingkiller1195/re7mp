#include "zip_extract.hpp"

#include <algorithm>
#include <cctype>

#include "packet.hpp"  // crc32

namespace re7mp {

namespace {

// ------------------------------------------------------------------ inflate
// Canonical-Huffman decoding one bit at a time (count of codes per length + symbols in code order). Slower than a
// table decoder but short enough to read in one go; a 20 MB DLL still unpacks in well under a second.

struct Bits {
    const uint8_t* p;
    size_t n;
    size_t pos = 0;
    uint32_t buf = 0;
    int cnt = 0;
    bool eof = false;

    uint32_t get(int need) {
        while (cnt < need) {
            if (pos >= n) {
                eof = true;
                return 0;
            }
            buf |= static_cast<uint32_t>(p[pos++]) << cnt;
            cnt += 8;
        }
        const uint32_t v = buf & ((1u << need) - 1u);
        buf >>= need;
        cnt -= need;
        return v;
    }
};

struct Huff {
    short count[16];
    short symbol[320];
};

// Returns 0 for a complete code, >0 for an incomplete one, <0 for an over-subscribed one.
int build(Huff& h, const short* length, int n) {
    for (int len = 0; len <= 15; ++len) h.count[len] = 0;
    for (int s = 0; s < n; ++s) ++h.count[length[s]];
    if (h.count[0] == n) return 0;  // no codes at all: complete as far as decoding goes (it just can't be used)
    int left = 1;
    for (int len = 1; len <= 15; ++len) {
        left <<= 1;
        left -= h.count[len];
        if (left < 0) return left;
    }
    short offs[16];
    offs[1] = 0;
    for (int len = 1; len < 15; ++len) offs[len + 1] = static_cast<short>(offs[len] + h.count[len]);
    for (int s = 0; s < n; ++s) {
        if (length[s] != 0) h.symbol[offs[length[s]]++] = static_cast<short>(s);
    }
    return left;
}

// Returns the symbol, or a negative number if the bits are not a valid code (or the input ran out).
int decode(Bits& b, const Huff& h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= 15; ++len) {
        code |= static_cast<int>(b.get(1));
        if (b.eof) return -1;
        const int count = h.count[len];
        if (code - count < first) return h.symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -2;
}

const short kLenBase[29] = {3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
                            31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
const short kLenExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const short kDistBase[30] = {1,   2,   3,   4,   5,   7,    9,    13,   17,   25,   33,   49,   65,    97,    129,
                             193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
const short kDistExtra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

bool codes(Bits& b, std::vector<uint8_t>& out, uint64_t max_out, const Huff& lencode, const Huff& distcode, std::string& err) {
    for (;;) {
        int sym = decode(b, lencode);
        if (sym < 0) {
            err = b.eof ? "the data ends too early" : "invalid compressed data (bad code)";
            return false;
        }
        if (sym < 256) {
            if (out.size() >= max_out) {
                err = "the data is larger than it says";
                return false;
            }
            out.push_back(static_cast<uint8_t>(sym));
        } else if (sym == 256) {
            return true;
        } else {
            sym -= 257;
            if (sym >= 29) {
                err = "invalid compressed data (bad length)";
                return false;
            }
            const int len = kLenBase[sym] + static_cast<int>(b.get(kLenExtra[sym]));
            const int ds = decode(b, distcode);
            if (ds < 0 || ds >= 30) {
                err = b.eof ? "the data ends too early" : "invalid compressed data (bad distance)";
                return false;
            }
            const size_t dist = static_cast<size_t>(kDistBase[ds]) + b.get(kDistExtra[ds]);
            if (b.eof) {
                err = "the data ends too early";
                return false;
            }
            if (dist > out.size()) {
                err = "invalid compressed data (distance too far back)";
                return false;
            }
            if (out.size() + static_cast<size_t>(len) > max_out) {
                err = "the data is larger than it says";
                return false;
            }
            for (int i = 0; i < len; ++i) out.push_back(out[out.size() - dist]);
        }
    }
}

bool stored_block(Bits& b, std::vector<uint8_t>& out, uint64_t max_out, std::string& err) {
    b.buf = 0;
    b.cnt = 0;  // skip to the byte boundary
    if (b.pos + 4 > b.n) {
        err = "the data ends too early";
        return false;
    }
    const unsigned len = b.p[b.pos] | (b.p[b.pos + 1] << 8);
    const unsigned nlen = b.p[b.pos + 2] | (b.p[b.pos + 3] << 8);
    b.pos += 4;
    if (len != (~nlen & 0xFFFFu)) {
        err = "invalid compressed data (stored block length)";
        return false;
    }
    if (b.pos + len > b.n) {
        err = "the data ends too early";
        return false;
    }
    if (out.size() + len > max_out) {
        err = "the data is larger than it says";
        return false;
    }
    out.insert(out.end(), b.p + b.pos, b.p + b.pos + len);
    b.pos += len;
    return true;
}

bool fixed_block(Bits& b, std::vector<uint8_t>& out, uint64_t max_out, std::string& err) {
    static Huff lencode, distcode;
    static bool ready = false;
    if (!ready) {
        short lengths[288];
        int s = 0;
        for (; s < 144; ++s) lengths[s] = 8;
        for (; s < 256; ++s) lengths[s] = 9;
        for (; s < 280; ++s) lengths[s] = 7;
        for (; s < 288; ++s) lengths[s] = 8;
        build(lencode, lengths, 288);
        for (s = 0; s < 30; ++s) lengths[s] = 5;
        build(distcode, lengths, 30);
        ready = true;
    }
    return codes(b, out, max_out, lencode, distcode, err);
}

bool dynamic_block(Bits& b, std::vector<uint8_t>& out, uint64_t max_out, std::string& err) {
    static const short order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    const int nlen = static_cast<int>(b.get(5)) + 257;
    const int ndist = static_cast<int>(b.get(5)) + 1;
    const int ncode = static_cast<int>(b.get(4)) + 4;
    if (b.eof) {
        err = "the data ends too early";
        return false;
    }
    if (nlen > 286 || ndist > 30) {
        err = "invalid compressed data (too many codes)";
        return false;
    }
    short lengths[320];
    int index = 0;
    for (; index < ncode; ++index) lengths[order[index]] = static_cast<short>(b.get(3));
    for (; index < 19; ++index) lengths[order[index]] = 0;
    Huff lencode, distcode;
    if (build(lencode, lengths, 19) != 0) {
        err = "invalid compressed data (code length codes)";
        return false;
    }
    index = 0;
    while (index < nlen + ndist) {
        int sym = decode(b, lencode);
        if (sym < 0) {
            err = b.eof ? "the data ends too early" : "invalid compressed data (code lengths)";
            return false;
        }
        if (sym < 16) {
            lengths[index++] = static_cast<short>(sym);
        } else {
            int len = 0, rep;
            if (sym == 16) {
                if (index == 0) {
                    err = "invalid compressed data (repeat with nothing before it)";
                    return false;
                }
                len = lengths[index - 1];
                rep = 3 + static_cast<int>(b.get(2));
            } else if (sym == 17) {
                rep = 3 + static_cast<int>(b.get(3));
            } else {
                rep = 11 + static_cast<int>(b.get(7));
            }
            if (index + rep > nlen + ndist) {
                err = "invalid compressed data (too many code lengths)";
                return false;
            }
            while (rep--) lengths[index++] = static_cast<short>(len);
        }
    }
    if (b.eof) {
        err = "the data ends too early";
        return false;
    }
    if (lengths[256] == 0) {
        err = "invalid compressed data (no end-of-block code)";
        return false;
    }
    int e = build(lencode, lengths, nlen);
    if (e < 0 || (e > 0 && nlen - lencode.count[0] != 1)) {
        err = "invalid compressed data (literal codes)";
        return false;
    }
    e = build(distcode, lengths + nlen, ndist);
    if (e < 0 || (e > 0 && ndist - distcode.count[0] != 1)) {
        err = "invalid compressed data (distance codes)";
        return false;
    }
    return codes(b, out, max_out, lencode, distcode, err);
}

uint16_t rd16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
uint32_t rd32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

}  // namespace

bool inflate_raw(const uint8_t* in, size_t n, std::vector<uint8_t>& out, uint64_t max_out, std::string& err) {
    Bits b{in, n};
    bool last = false;
    while (!last) {
        last = b.get(1) != 0;
        const uint32_t type = b.get(2);
        if (b.eof) {
            err = "the data ends too early";
            return false;
        }
        bool ok;
        if (type == 0) ok = stored_block(b, out, max_out, err);
        else if (type == 1) ok = fixed_block(b, out, max_out, err);
        else if (type == 2) ok = dynamic_block(b, out, max_out, err);
        else {
            err = "invalid compressed data (block type)";
            return false;
        }
        if (!ok) return false;
    }
    return true;
}

// ------------------------------------------------------------------ zip

bool zip_list(const std::vector<uint8_t>& zip, std::vector<ZipEntry>& entries, std::string& err) {
    entries.clear();
    const size_t n = zip.size();
    if (n < 22) {
        err = "this is not a zip file (too small)";
        return false;
    }
    // The end-of-central-directory record is at the very end, followed by at most a 64 KB comment.
    size_t eocd = std::string::npos;
    const size_t lowest = n > 22 + 65535 ? n - 22 - 65535 : 0;
    for (size_t i = n - 22 + 1; i > lowest;) {
        --i;
        if (rd32(&zip[i]) == 0x06054b50u) {
            eocd = i;
            break;
        }
    }
    if (eocd == std::string::npos) {
        err = "this is not a zip file (no directory at the end)";
        return false;
    }
    const uint8_t* e = &zip[eocd];
    const uint16_t disk = rd16(e + 4), cd_disk = rd16(e + 6), total = rd16(e + 10);
    const uint32_t cd_size = rd32(e + 12), cd_off = rd32(e + 16);
    if (disk != 0 || cd_disk != 0) {
        err = "multi-part zip files are not supported";
        return false;
    }
    if (total == 0xFFFF || cd_size == 0xFFFFFFFFu || cd_off == 0xFFFFFFFFu) {
        err = "zip64 files are not supported";
        return false;
    }
    if (static_cast<uint64_t>(cd_off) + cd_size > eocd) {
        err = "the zip directory is damaged";
        return false;
    }
    size_t pos = cd_off;
    for (unsigned i = 0; i < total; ++i) {
        if (pos + 46 > cd_off + static_cast<size_t>(cd_size) || rd32(&zip[pos]) != 0x02014b50u) {
            err = "the zip directory is damaged";
            return false;
        }
        const uint8_t* c = &zip[pos];
        ZipEntry z;
        const uint16_t flags = rd16(c + 8);
        z.method = rd16(c + 10);
        z.crc = rd32(c + 16);
        z.compressed_size = rd32(c + 20);
        z.size = rd32(c + 24);
        const uint16_t name_len = rd16(c + 28), extra_len = rd16(c + 30), comment_len = rd16(c + 32);
        z.local_offset = rd32(c + 42);
        if (pos + 46 + name_len + extra_len + comment_len > cd_off + static_cast<size_t>(cd_size)) {
            err = "the zip directory is damaged";
            return false;
        }
        z.name.assign(reinterpret_cast<const char*>(c + 46), name_len);
        z.is_dir = !z.name.empty() && (z.name.back() == '/' || z.name.back() == '\\');
        if ((flags & 1) != 0) {
            err = "encrypted zip entries are not supported";
            return false;
        }
        if (z.compressed_size == 0xFFFFFFFFu || z.size == 0xFFFFFFFFu || z.local_offset == 0xFFFFFFFFu) {
            err = "zip64 files are not supported";
            return false;
        }
        entries.push_back(std::move(z));
        pos += 46u + name_len + extra_len + comment_len;
    }
    return true;
}

bool zip_read(const std::vector<uint8_t>& zip, const ZipEntry& z, std::vector<uint8_t>& out, uint64_t max_size,
              std::string& err) {
    out.clear();
    if (z.size > max_size) {
        err = z.name + " is too large";
        return false;
    }
    const size_t off = z.local_offset;
    if (off + 30 > zip.size() || rd32(&zip[off]) != 0x04034b50u) {
        err = "the zip entry " + z.name + " is damaged (no local header)";
        return false;
    }
    const size_t data = off + 30 + rd16(&zip[off + 26]) + rd16(&zip[off + 28]);
    if (data > zip.size() || z.compressed_size > zip.size() - data) {
        err = "the zip entry " + z.name + " is damaged (data runs past the end)";
        return false;
    }
    if (z.method == 0) {
        if (z.compressed_size != z.size) {
            err = "the zip entry " + z.name + " is damaged (stored size differs)";
            return false;
        }
        out.assign(zip.begin() + static_cast<std::ptrdiff_t>(data), zip.begin() + static_cast<std::ptrdiff_t>(data + z.size));
    } else if (z.method == 8) {
        out.reserve(z.size);
        std::string ierr;
        if (!inflate_raw(&zip[data], z.compressed_size, out, z.size, ierr)) {
            err = "could not unpack " + z.name + ": " + ierr;
            out.clear();
            return false;
        }
    } else {
        err = "the zip entry " + z.name + " uses compression method " + std::to_string(z.method) + ", which is not supported";
        return false;
    }
    if (out.size() != z.size) {
        err = "the zip entry " + z.name + " unpacked to the wrong size";
        out.clear();
        return false;
    }
    if (crc32(out.data(), out.size()) != z.crc) {
        err = "the zip entry " + z.name + " is damaged (checksum mismatch)";
        out.clear();
        return false;
    }
    return true;
}

std::string zip_safe_name(const std::string& raw) {
    std::string s = raw;
    std::replace(s.begin(), s.end(), '\\', '/');
    if (s.empty() || s[0] == '/') return {};
    std::string out;
    size_t i = 0;
    while (i <= s.size()) {
        size_t j = s.find('/', i);
        if (j == std::string::npos) j = s.size();
        const std::string part = s.substr(i, j - i);
        i = j + 1;
        if (part.empty() || part == ".") continue;
        if (part == "..") return {};
        for (char ch : part) {
            if (static_cast<unsigned char>(ch) < 32 || ch == ':' || ch == '*' || ch == '?' || ch == '"' || ch == '<' ||
                ch == '>' || ch == '|') {
                return {};
            }
        }
        if (!out.empty()) out += '/';
        out += part;
    }
    return out;
}

bool zip_name_is(const std::string& entry_name, const std::string& want) {
    const std::string safe = zip_safe_name(entry_name);
    if (safe.empty()) return false;
    const size_t slash = safe.rfind('/');
    const std::string base = slash == std::string::npos ? safe : safe.substr(slash + 1);
    if (base.size() != want.size()) return false;
    for (size_t k = 0; k < base.size(); ++k) {
        if (std::tolower(static_cast<unsigned char>(base[k])) != std::tolower(static_cast<unsigned char>(want[k]))) return false;
    }
    return true;
}

}  // namespace re7mp
