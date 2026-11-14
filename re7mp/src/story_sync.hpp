#pragma once
// "Sync story cutscenes" (9.33, EXPERIMENTAL): the box under "Share saves" in re7mp.exe. It is written to re7mp_story.json in the game's
// reframework/data folder:
//   {"story_sync":true,"seq":1731310000123}
// The Lua script reads it every couple of seconds and applies it when "seq" is a number it has not seen yet. Ticked, it turns on story sync
// (each player is told which cutscene the other one starts), FORCE (that cutscene is played in this game too) and BOTH moves (the joiner is
// brought to the host's place and the host to the joiner's), so whoever hits a cutscene first, the other player gets it too. Unticked, all of
// it is off. The file is NOT deleted when the exe starts: it is the player's own standing choice, and Start writes it again from the box
// (nothing is written when it already says the same, so the script is not told again for nothing).
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "json_mini.hpp"

namespace re7mp {

inline std::filesystem::path story_sync_file(const std::filesystem::path& data_dir) { return data_dir / "re7mp_story.json"; }

// A number that changes every time it is asked for (milliseconds since 1970).
inline uint64_t story_sync_seq_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

// Writes the choice (through a temporary file, so the script never reads half of it). False: the folder can't be written.
inline bool write_story_sync(const std::filesystem::path& data_dir, bool on, uint64_t seq) {
    std::error_code ec;
    std::filesystem::create_directories(data_dir, ec);
    const auto tmp = data_dir / "re7mp_story.tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        char buf[96];
        std::snprintf(buf, sizeof(buf), "{\"story_sync\":%s,\"seq\":%llu}\n", on ? "true" : "false", static_cast<unsigned long long>(seq));
        f << buf;
        if (!f) return false;
    }
    std::filesystem::rename(tmp, story_sync_file(data_dir), ec);  // fails if the script has the file open; the caller may try again
    return !ec;
}

// Reads the file. False: not there, damaged, or "story_sync" is not true / false.
inline bool read_story_sync(const std::filesystem::path& data_dir, bool& on, uint64_t& seq) {
    std::ifstream f(story_sync_file(data_dir), std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    mini::Value v;
    if (!mini::parse(ss.str(), v) || v.type != mini::Value::Type::Obj) return false;
    const auto* b = v.get("story_sync");
    if (!b || b->type != mini::Value::Type::Bool) return false;
    on = b->b;
    const auto* s = v.get("seq");
    seq = (s && s->type == mini::Value::Type::Num && s->num >= 0) ? static_cast<uint64_t>(s->num) : 0;
    return true;
}

// Makes the file say this: nothing is written when it already does. The number written is never one the file already had (a clock that went
// back, or two writes in the same millisecond, would otherwise leave the script with nothing new to apply). True: the file now says it.
inline bool sync_story_sync(const std::filesystem::path& data_dir, bool on, bool* wrote = nullptr) {
    if (wrote) *wrote = false;
    bool have = false;
    uint64_t old_seq = 0;
    const bool had = read_story_sync(data_dir, have, old_seq);
    if (had && have == on) return true;
    uint64_t seq = story_sync_seq_now();
    if (had && seq <= old_seq) seq = old_seq + 1;
    if (!write_story_sync(data_dir, on, seq)) return false;
    if (wrote) *wrote = true;
    return true;
}

}  // namespace re7mp
