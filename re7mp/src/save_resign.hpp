#pragma once
// Making a save from another player's PC load on yours.
//
// RE7 (like the other RE Engine games of its time) wraps a save in an "AutoStrong" container whose header names the Steam
// account that wrote it; the game calls a save from another account "corrupted". Layout of the file (little-endian 32-bit
// words; found in AutostrongSharp by mi5hmash, MIT, and checked against real saves):
//
//     bytes  0..16   "DSSS", 2, 3, 3                      container header, never encrypted
//     bytes 16..48   the "data header", four 8-byte blocks, each encrypted on its own (no chaining):
//                      block 0  DSSS DSSS                  the same in every save of the game (it depends only on the game's key)
//                      block 1  Steam32 account id, 0      <- the ONLY part of the header that depends on the account
//                      block 2, 3  not understood; left alone by AutostrongSharp's "re-sign" too
//     bytes 48..N-4  the save itself, chained-encrypted starting at byte 64; does not depend on the account
//     last 4 bytes   Murmur3-32 of everything before it, seed 0xFFFFFFFF   <- the file's signature
//
// So "re-signing" for another account needs no key at all: take the account block (8 bytes) from any save the game itself wrote
// on THIS account, put it in place of the sender's, and recompute the signature. That is what this does. It is the same result as
// AutostrongSharp's "Re-sign" (which decrypts block 1, writes the new id, encrypts it again), as long as block 1's second word is
// the same in both files (it is 0 in every file looked at; the folder scan below insists that all of your own files agree).
#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "save_sync.hpp"

namespace re7mp {

constexpr size_t kAutostrongHeadBytes = 48;  // container header (16) + data header (32)
constexpr size_t kAutostrongMinBytes = kAutostrongHeadBytes + 4;
constexpr uint32_t kAutostrongSeed = 0xFFFFFFFFu;

// Murmur3 (32-bit) over `word_count` little-endian 32-bit words starting at `bytes`.
uint32_t murmur3_words(const uint8_t* bytes, size_t word_count, uint32_t seed);

enum class ContainerKind {
    Other,      // not an AutoStrong save (or too short): never touched
    Plain,      // an AutoStrong save that is not encrypted (a decrypted dump): never touched
    Encrypted,  // the kind the game writes
};
// `head` must hold at least the first 48 bytes of the file (n = how many you have).
ContainerKind classify_container(const uint8_t* head, size_t n);

// The two 8-byte blocks of the data header that identify (a) the game's key and (b) the account.
struct AccountMark {
    std::array<uint8_t, 8> format{};   // block 0: the same in every save written with the same key
    std::array<uint8_t, 8> account{};  // block 1: names the Steam account
    bool operator==(const AccountMark& o) const { return format == o.format && account == o.account; }
};
bool read_account_mark(const uint8_t* head, size_t n, AccountMark& out);  // Encrypted files only

// The signature at the end of the file.
bool autostrong_signature_ok(const std::vector<uint8_t>& data);
void autostrong_sign(std::vector<uint8_t>& data);  // recomputes and writes it

enum class MarkSearch {
    Found,     // `out` is this PC's account mark
    None,      // no save of the game's own in the folder: nothing to learn it from
    Disagree,  // the folder's saves name different accounts and no mark has a clear majority
};
// Learns this account's mark from the saves in `dir` that the game itself wrote: every .bin file of the right kind except the copies
// this tool installed (`manifest`: those carry another player's mark until re-signed, or yours after). The mark most files share wins;
// `files` is how many files carry it and `total` how many encrypted saves were looked at. Reads 48 bytes of each file, not the whole file.
MarkSearch find_own_mark(const std::filesystem::path& dir, const CoopManifest& manifest, AccountMark& out, int& files, int& total);

enum class ResignKind {
    NotApplicable,  // not an AutoStrong save at all: install it as it is
    AlreadyYours,   // it already names this account
    Resigned,       // changed to name this account (account block and signature)
    Damaged,        // it is one of ours but its signature does not match: do not install
    OtherKey,       // it is encrypted with a different key than your own saves (another game or version): do not install
    NoOwnSave,      // it needs re-signing but the folder holds no save of your own to learn your account from: do not install
    Ambiguous,      // the folder's saves name different accounts with no clear majority: do not install
};
struct ResignResult {
    ResignKind kind = ResignKind::NotApplicable;
    std::string detail;  // plain English, for the log and the panel
    bool install() const { return kind == ResignKind::NotApplicable || kind == ResignKind::AlreadyYours || kind == ResignKind::Resigned; }
};
// Changes `data` in place so it names the account in `mine`.
ResignResult resign_save(std::vector<uint8_t>& data, const AccountMark& mine);

// The whole job for one received save: learns this PC's account from `save_dir` (see find_own_mark) and re-signs `data` for it.
// Files that are not RE7 save containers pass through untouched (kind NotApplicable) whatever the folder holds.
ResignResult resign_for_this_pc(std::vector<uint8_t>& data, const std::filesystem::path& save_dir, const CoopManifest& manifest);

}  // namespace re7mp
