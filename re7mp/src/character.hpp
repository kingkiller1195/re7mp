#pragma once
// "Play as" (9.31): the character a player picks in re7mp.exe. It is written to re7mp_char.json in the game's reframework/data folder:
//   {"character":"clancy","seq":1731310000123}
// The Lua script reads it every couple of seconds and applies it when "seq" is a number it has not seen yet, then tells the other player
// (event "char") so their game shows this player's body as that character. "auto" means "whoever the game has me as".
// The file is NOT deleted when the exe starts (clear_stale leaves it): it is the player's own standing choice.
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "json_mini.hpp"

namespace re7mp {

struct CharacterChoice {
    const char* key;    // what is written to the file (and what the script knows)
    const char* label;  // what the window shows
};

inline const std::vector<CharacterChoice>& character_choices() {
    static const std::vector<CharacterChoice> v = {
        {"auto", "Automatic (whoever the game puts me as)"},
        {"ethan", "Ethan Winters"},
        {"mia", "Mia Winters"},
        {"clancy", "Clancy Jarvis"},
        {"pete", "Pete Walken"},        // 9.37: enemy models the script can wear as a body (em9200, em6200)
        {"andre", "Andre Stickland"},
    };
    return v;
}

// Index in character_choices(), or -1 for a key that is none of them.
inline int character_index(const std::string& key) {
    const auto& v = character_choices();
    for (size_t i = 0; i < v.size(); ++i) {
        if (key == v[i].key) return static_cast<int>(i);
    }
    return -1;
}

inline bool character_valid(const std::string& key) { return character_index(key) >= 0; }

// A number that changes every time it is asked for (milliseconds since 1970): the script applies a choice when this changes.
inline uint64_t character_seq_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

inline std::filesystem::path character_file(const std::filesystem::path& data_dir) { return data_dir / "re7mp_char.json"; }

// Writes the choice (through a temporary file, so the script never reads half of it). False: bad key, or the folder can't be written.
inline bool write_character_choice(const std::filesystem::path& data_dir, const std::string& key, uint64_t seq) {
    if (!character_valid(key)) return false;
    std::error_code ec;
    std::filesystem::create_directories(data_dir, ec);
    const auto tmp = data_dir / "re7mp_char.tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        char buf[128];
        std::snprintf(buf, sizeof(buf), "{\"character\":\"%s\",\"seq\":%llu}\n", key.c_str(), static_cast<unsigned long long>(seq));
        f << buf;
        if (!f) return false;
    }
    std::filesystem::rename(tmp, character_file(data_dir), ec);  // fails if the script has the file open; the caller may try again
    return !ec;
}

// Reads the file. False: not there, damaged, or the key is not one of the known characters.
inline bool read_character_choice(const std::filesystem::path& data_dir, std::string& key, uint64_t& seq) {
    std::ifstream f(character_file(data_dir), std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    mini::Value v;
    if (!mini::parse(ss.str(), v) || v.type != mini::Value::Type::Obj) return false;
    const auto* c = v.get("character");
    if (!c || c->type != mini::Value::Type::Str || !character_valid(c->str)) return false;
    key = c->str;
    const auto* s = v.get("seq");
    seq = (s && s->type == mini::Value::Type::Num && s->num >= 0) ? static_cast<uint64_t>(s->num) : 0;
    return true;
}

// Makes the file say this key: nothing is written when it already does (so the script is not told again for nothing). True: the file now
// says it (written now, or it said so already).
inline bool sync_character_choice(const std::filesystem::path& data_dir, const std::string& key, bool* wrote = nullptr) {
    if (wrote) *wrote = false;
    if (!character_valid(key)) return false;
    std::string have;
    uint64_t seq = 0;
    if (read_character_choice(data_dir, have, seq) && have == key) return true;
    if (!write_character_choice(data_dir, key, character_seq_now())) return false;
    if (wrote) *wrote = true;
    return true;
}

}  // namespace re7mp
