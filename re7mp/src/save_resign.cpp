#include "save_resign.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <map>

namespace fs = std::filesystem;

namespace re7mp {

namespace {

uint32_t rol32(uint32_t x, int r) { return (x << r) | (x >> (32 - r)); }

uint32_t load_le32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

void store_le32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
    p[2] = static_cast<uint8_t>(v >> 16);
    p[3] = static_cast<uint8_t>(v >> 24);
}

// "DSSS", 2, 3, 3: the container header every AutoStrong save starts with.
constexpr uint8_t kContainerHead[16] = {'D', 'S', 'S', 'S', 2, 0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0};
// "DSSSDSSS": what data-header block 0 reads when the file is not encrypted.
constexpr uint8_t kPlainBlock0[8] = {'D', 'S', 'S', 'S', 'D', 'S', 'S', 'S'};

constexpr size_t kBlock0 = 16, kBlock1 = 24;  // byte offsets of the format block and the account block

bool has_head(const uint8_t* head, size_t n) { return n >= kAutostrongHeadBytes && std::memcmp(head, kContainerHead, sizeof(kContainerHead)) == 0; }

std::string lower_ext(const fs::path& p) {
    std::string e = p.extension().u8string();
    for (auto& c : e) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return e;
}

}  // namespace

uint32_t murmur3_words(const uint8_t* bytes, size_t word_count, uint32_t seed) {
    constexpr uint32_t c0 = 0x1B873593, c1 = 0xCC9E2D51, c2 = 0x052250EC, c3 = 0xC2B2AE35, c4 = 0x85EBCA6B;
    for (size_t i = 0; i < word_count; ++i) {
        const uint32_t e = load_le32(bytes + 4 * i);
        seed = 5u * (rol32((c0 * rol32(c1 * e, 15)) ^ seed, 13) - c2);
    }
    // (The length is always a whole number of words here, so the format's byte-tail step never runs.)
    const uint32_t basis = static_cast<uint32_t>(word_count * 4) ^ seed;
    const uint32_t hi = (basis >> 16) & 0xFFFFu;
    const uint32_t a = c4 * (basis ^ hi);
    const uint32_t b = c3 * (a ^ (a >> 13));
    return b ^ (b >> 16);
}

ContainerKind classify_container(const uint8_t* head, size_t n) {
    if (!has_head(head, n)) return ContainerKind::Other;
    return std::memcmp(head + kBlock0, kPlainBlock0, 8) == 0 ? ContainerKind::Plain : ContainerKind::Encrypted;
}

bool read_account_mark(const uint8_t* head, size_t n, AccountMark& out) {
    if (classify_container(head, n) != ContainerKind::Encrypted) return false;
    std::memcpy(out.format.data(), head + kBlock0, 8);
    std::memcpy(out.account.data(), head + kBlock1, 8);
    return true;
}

bool autostrong_signature_ok(const std::vector<uint8_t>& data) {
    if (data.size() < kAutostrongMinBytes || data.size() % 4 != 0) return false;
    const size_t words = data.size() / 4;
    return murmur3_words(data.data(), words - 1, kAutostrongSeed) == load_le32(data.data() + data.size() - 4);
}

void autostrong_sign(std::vector<uint8_t>& data) {
    if (data.size() < kAutostrongMinBytes || data.size() % 4 != 0) return;
    store_le32(data.data() + data.size() - 4, murmur3_words(data.data(), data.size() / 4 - 1, kAutostrongSeed));
}

MarkSearch find_own_mark(const fs::path& dir, const CoopManifest& manifest, AccountMark& out, int& files, int& total) {
    files = 0;
    total = 0;
    struct Tally {
        AccountMark mark;
        int count = 0;
    };
    std::vector<Tally> tallies;
    std::error_code ec;
    for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
        std::error_code e2;
        if (!it->is_regular_file(e2) || lower_ext(it->path()) != ".bin") continue;
        const int slot = parse_slot(it->path().filename().u8string());
        if (slot >= 1 && manifest.is_received_slot(slot)) continue;  // a copy we installed: not evidence of whose PC this is
        std::ifstream f(it->path(), std::ios::binary);
        uint8_t head[kAutostrongHeadBytes];
        if (!f.read(reinterpret_cast<char*>(head), sizeof(head))) continue;
        AccountMark m;
        if (!read_account_mark(head, sizeof(head), m)) continue;
        ++total;
        auto t = std::find_if(tallies.begin(), tallies.end(), [&](const Tally& x) { return x.mark == m; });
        if (t == tallies.end()) {
            tallies.push_back({m, 1});
        } else {
            ++t->count;
        }
    }
    if (tallies.empty()) return MarkSearch::None;
    std::sort(tallies.begin(), tallies.end(), [](const Tally& a, const Tally& b) { return a.count > b.count; });
    if (tallies.size() > 1 && tallies[0].count == tallies[1].count) return MarkSearch::Disagree;
    out = tallies[0].mark;
    files = tallies[0].count;
    return MarkSearch::Found;
}

ResignResult resign_save(std::vector<uint8_t>& data, const AccountMark& mine) {
    ResignResult r;
    if (data.size() < kAutostrongMinBytes || data.size() % 4 != 0 ||
        classify_container(data.data(), kAutostrongHeadBytes) != ContainerKind::Encrypted) {
        r.kind = ResignKind::NotApplicable;
        r.detail = "not an encrypted RE7 save container, installed as it is";
        return r;
    }
    if (!autostrong_signature_ok(data)) {
        r.kind = ResignKind::Damaged;
        r.detail = "its signature (the last 4 bytes) does not match the file: it is damaged, or not a save this tool understands";
        return r;
    }
    AccountMark theirs;
    read_account_mark(data.data(), kAutostrongHeadBytes, theirs);
    if (!(theirs.format == mine.format)) {
        r.kind = ResignKind::OtherKey;
        r.detail = "it is encrypted with a different key than your own saves (another game, or another version of it)";
        return r;
    }
    if (theirs.account == mine.account) {
        r.kind = ResignKind::AlreadyYours;
        r.detail = "it already carries your account";
        return r;
    }
    std::memcpy(data.data() + kBlock1, mine.account.data(), 8);
    autostrong_sign(data);
    r.kind = ResignKind::Resigned;
    r.detail = "re-signed for your Steam account (the account block and the signature were replaced; the save itself is untouched)";
    return r;
}

ResignResult resign_for_this_pc(std::vector<uint8_t>& data, const fs::path& save_dir, const CoopManifest& manifest) {
    ResignResult r;
    if (data.size() < kAutostrongMinBytes || data.size() % 4 != 0 ||
        classify_container(data.data(), kAutostrongHeadBytes) != ContainerKind::Encrypted) {
        return resign_save(data, AccountMark{});  // NotApplicable: no folder scan needed
    }
    AccountMark mine;
    int agree = 0, total = 0;
    const MarkSearch ms = find_own_mark(save_dir, manifest, mine, agree, total);
    if (ms == MarkSearch::None) {
        r.kind = ResignKind::NoOwnSave;
        r.detail = "your save folder has no save of your own to learn your Steam account from, so it cannot be made to load on this PC. "
                   "Start RE7 once, reach the main menu and make a save of your own, then ask them to save again";
        return r;
    }
    if (ms == MarkSearch::Disagree) {
        r.kind = ResignKind::Ambiguous;
        r.detail = "the saves in your folder name different Steam accounts and no account has a majority (were saves from another PC copied in?), "
                   "so it is not known which one is yours";
        return r;
    }
    r = resign_save(data, mine);
    if (r.kind == ResignKind::Resigned) {
        r.detail += "; learned from " + std::to_string(agree) + " of your " + std::to_string(total) + " save file(s) in the folder";
    }
    return r;
}

}  // namespace re7mp
