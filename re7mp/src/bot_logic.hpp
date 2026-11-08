#pragma once
// What the loopback bot says back, so features that need a second player can be tried alone (9.13):
//  - a gift (message kind 5, "id|count") is answered with kind 10 ("g|id|count|ok|..."), like a receiving script does,
//    otherwise the sender's script waits for a confirmation that never comes and never takes the item out of the inventory;
//  - a drop (kind 6, "id|count|x|y|z") is answered the same way ("d|id|count|ok|...");
//  - the bot can be told to go down (kind 11, "down") and to get up ("up"); while down it stands where it fell and says so
//    every second (kind 7, "h|hp|max|1"), and a healing event (kind 7, "e|heal|Herb|x|y|z", also "use" and "revive") from
//    a player within reach gets it up again.
// Pure text functions, kept out of the engine so the tests can call them.
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace re7mp {

constexpr uint16_t kMsgGive = 5;
constexpr uint16_t kMsgDrop = 6;
constexpr uint16_t kMsgHealth = 7;
constexpr uint16_t kMsgGiveAnswer = 10;
constexpr uint16_t kMsgBotCommand = 11;  // only the loopback bot understands this one (a real player's script ignores it)

// How close a healer has to be to get a downed bot up: the script's revive radius (3 m since 9.14) plus the slack it gives for lag (x1.25).
constexpr double kBotReviveRadius = 3.75;
constexpr int kBotHealthMax = 1000;

inline std::vector<std::string> bot_split(const std::string& s, char sep) {
    std::vector<std::string> out;
    size_t from = 0;
    while (true) {
        const size_t at = s.find(sep, from);
        if (at == std::string::npos) {
            out.push_back(s.substr(from));
            return out;
        }
        out.push_back(s.substr(from, at - from));
        from = at + 1;
    }
}

inline bool bot_item_id_ok(const std::string& s) {
    if (s.empty() || s.size() > 48) return false;
    for (char c : s) {
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_')) return false;
    }
    return true;
}

inline bool bot_parse_count(const std::string& s, int lo, int hi, int& out) {
    if (s.empty() || s.size() > 6) return false;
    for (char c : s) {
        if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    }
    out = std::atoi(s.c_str());
    return out >= lo && out <= hi;
}

inline bool bot_parse_number(const std::string& s, double& out) {
    if (s.empty() || s.size() > 24) return false;
    char* end = nullptr;
    out = std::strtod(s.c_str(), &end);
    return end && *end == '\0' && std::isfinite(out);
}

// "Herb|2" -> "g|Herb|2|ok|..."; anything malformed gets no answer (like the script, which ignores it).
inline std::string bot_answer_gift(const std::string& payload) {
    const auto p = bot_split(payload, '|');
    int n = 0;
    if (p.size() != 2 || !bot_item_id_ok(p[0]) || !bot_parse_count(p[1], 1, 999, n)) return "";
    return "g|" + p[0] + "|" + std::to_string(n) + "|ok|the loopback bot took it";
}

// "Herb|1|1.00|0.00|2.00" -> "d|Herb|1|ok|..."
inline std::string bot_answer_drop(const std::string& payload) {
    const auto p = bot_split(payload, '|');
    int n = 0;
    double v = 0;
    if (p.size() != 5 || !bot_item_id_ok(p[0]) || !bot_parse_count(p[1], 1, 999, n)) return "";
    for (int i = 2; i < 5; ++i) {
        if (!bot_parse_number(p[static_cast<size_t>(i)], v)) return "";
    }
    return "d|" + p[0] + "|" + std::to_string(n) + "|ok|the loopback bot sees it on the ground";
}

struct BotEvent {
    std::string kind, arg;
    double x = 0, y = 0, z = 0;
};

// "e|heal|Herb|1.00|1.60|0.50" (the script's event message). Health reports ("h|...") are not events.
inline bool bot_parse_event(const std::string& payload, BotEvent& out) {
    const auto p = bot_split(payload, '|');
    if (p.size() != 6 || p[0] != "e" || p[1].empty()) return false;
    for (char c : p[1]) {
        if (!std::isalpha(static_cast<unsigned char>(c))) return false;
    }
    if (!bot_parse_number(p[3], out.x) || !bot_parse_number(p[4], out.y) || !bot_parse_number(p[5], out.z)) return false;
    out.kind = p[1];
    out.arg = p[2];
    return true;
}

inline bool bot_is_healing(const BotEvent& e) { return e.kind == "heal" || e.kind == "use" || e.kind == "revive"; }

// Does a heal this far from where the bot fell get it up?
inline bool bot_heal_reaches(double distance) { return distance <= kBotReviveRadius; }

inline double bot_distance(double ax, double ay, double az, double bx, double by, double bz) {
    const double dx = ax - bx, dy = ay - by, dz = az - bz;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

// The event messages the script understands: "e|down||x|y|z", "e|up||x|y|z".
inline std::string bot_event_text(const char* kind, double x, double y, double z) {
    char b[120];
    std::snprintf(b, sizeof(b), "e|%s||%.2f|%.2f|%.2f", kind, x, y, z);
    return b;
}

// "h|hp|max|down": 1 health and down, or full health and up.
inline std::string bot_health_text(bool down) {
    char b[64];
    std::snprintf(b, sizeof(b), "h|%d|%d|%d", down ? 1 : kBotHealthMax, kBotHealthMax, down ? 1 : 0);
    return b;
}

// What kind 11 asks for: 1 = go down, 0 = get up, -1 = anything else.
inline int bot_command(const std::string& payload) {
    if (payload == "down") return 1;
    if (payload == "up") return 0;
    return -1;
}

}  // namespace re7mp
