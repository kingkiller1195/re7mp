#pragma once
// "Sync enemies and the Molded" (10.19): the box under "Sync story cutscenes" in re7mp.exe. It is written to re7mp_enemysync.json in the game's
// reframework/data folder:
//   {"enemy_sync":true,"seq":1731310000123}
// The Lua script reads it every couple of seconds and applies it when "seq" is a number it has not seen yet. Ticked (the default), it turns on
// enemy sync mode 3 (the joiner's enemies are put onto the host's, their own AI switched off) and the copies of the host's Molded in the joiner's
// game; the garage car sync needs it. Unticked, both are off. The file is NOT deleted when the exe starts: it is the player's own standing choice,
// and Start writes it again from the box (nothing is written when it already says the same, so the script is not told again for nothing).
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "json_mini.hpp"

namespace re7mp {

inline std::filesystem::path enemy_sync_file(const std::filesystem::path& data_dir) { return data_dir / "re7mp_enemysync.json"; }

// A number that changes every time it is asked for (milliseconds since 1970).
inline uint64_t enemy_sync_seq_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

// Writes the choice (through a temporary file, so the script never reads half of it). False: the folder can't be written.
inline bool write_enemy_sync(const std::filesystem::path& data_dir, bool on, uint64_t seq) {
    std::error_code ec;
    std::filesystem::create_directories(data_dir, ec);
    const auto tmp = data_dir / "re7mp_enemysync.tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        char buf[96];
        std::snprintf(buf, sizeof(buf), "{\"enemy_sync\":%s,\"seq\":%llu}\n", on ? "true" : "false", static_cast<unsigned long long>(seq));
        f << buf;
        if (!f) return false;
    }
    std::filesystem::rename(tmp, enemy_sync_file(data_dir), ec);  // fails if the script has the file open; the caller may try again
    return !ec;
}

// Reads the file. False: not there, damaged, or "enemy_sync" is not true / false.
inline bool read_enemy_sync(const std::filesystem::path& data_dir, bool& on, uint64_t& seq) {
    std::ifstream f(enemy_sync_file(data_dir), std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    mini::Value v;
    if (!mini::parse(ss.str(), v) || v.type != mini::Value::Type::Obj) return false;
    const auto* b = v.get("enemy_sync");
    if (!b || b->type != mini::Value::Type::Bool) return false;
    on = b->b;
    const auto* s = v.get("seq");
    seq = (s && s->type == mini::Value::Type::Num && s->num >= 0) ? static_cast<uint64_t>(s->num) : 0;
    return true;
}

// Makes the file say this: nothing is written when it already does. The number written is never one the file already had (a clock that went
// back, or two writes in the same millisecond, would otherwise leave the script with nothing new to apply). True: the file now says it.
inline bool sync_enemy_sync(const std::filesystem::path& data_dir, bool on, bool* wrote = nullptr) {
    if (wrote) *wrote = false;
    bool have = false;
    uint64_t old_seq = 0;
    const bool had = read_enemy_sync(data_dir, have, old_seq);
    if (had && have == on) return true;
    uint64_t seq = enemy_sync_seq_now();
    if (had && seq <= old_seq) seq = old_seq + 1;
    if (!write_enemy_sync(data_dir, on, seq)) return false;
    if (wrote) *wrote = true;
    return true;
}

}  // namespace re7mp
