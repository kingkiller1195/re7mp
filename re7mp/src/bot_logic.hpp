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

#include "packet.hpp"

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

// (9.33) FRIENDLY FIRE on the bot. The script's shot test sends "e|ff|100|x|y|z" (the damage) when a shot crosses the other player; a real
// player's script takes it off its health. Nothing used to answer for the bot, so friendly fire could not be tried alone ("sent 10, taken 0").
// Now the bot has a health of its own: a hit takes that much off, never below 1 (the script's own rule for a player), and the new health goes
// back as a health report; at 1 it goes down like a bot that was told to, and a heal next to it (or "up") gets it up at full health again.
constexpr int kBotFfMax = 600;  // the script's cap on one hit (CFG.ff.MAX)

// The damage of a friendly-fire event, 1..kBotFfMax, or 0 when this is not one (or the number is damaged).
inline int bot_ff_damage(const BotEvent& e) {
    int n = 0;
    if (e.kind != "ff" || !bot_parse_count(e.arg, 1, kBotFfMax, n)) return 0;
    return n;
}

// The health after a hit: never below 1.
inline int bot_apply_damage(int hp, int dmg) {
    const int left = hp - dmg;
    return left < 1 ? 1 : left;
}

// "h|hp|max|0" for a bot that is up with `hp` health.
inline std::string bot_health_text_hp(int hp) {
    char b[64];
    std::snprintf(b, sizeof(b), "h|%d|%d|0", hp, kBotHealthMax);
    return b;
}

// What kind 11 asks for: 1 = go down, 0 = get up, -1 = anything else.
inline int bot_command(const std::string& payload) {
    if (payload == "down") return 1;
    if (payload == "up") return 0;
    return -1;
}

// (9.33) The loopback bot can say which character it is (the script's "char" event, the one a real player's script sends every 10 s), so the
// body that is made from a character's files (Mia, Clancy, Pete, Andre) can be tried without a second player. Kind 11 with "char:ethan", "char:mia" or
// "char:clancy" (also "char:pete", "char:andre": 9.37) sets it; "char:none" takes it back (the bot says nothing again, as it always did).
// Returns 1 and the key (set it), 2 (take it back), or 0 (not a character command, or a key that is none of the three).
inline int bot_character_command(const std::string& payload, std::string& key) {
    key.clear();
    if (payload.compare(0, 5, "char:") != 0) return 0;
    const std::string k = payload.substr(5);
    if (k == "none") return 2;
    if (k == "ethan" || k == "mia" || k == "clancy" || k == "pete" || k == "andre") {
        key = k;
        return 1;
    }
    return 0;
}

// (9.37) The loopback bot that FOLLOWS you: it walks after you at a pace that grows with the gap (a walk when it is close, a run when it is far),
// stops kFollowStop metres away, and is put next to you when you are far away (a new area, a teleport). Pure, so the tests can walk it.
constexpr float kFollowStop = 2.0f;        // metres: it stops this far from you
constexpr float kFollowSnap = 40.0f;       // metres: further than this and it is put next to you instead of running
constexpr float kFollowMaxSpeed = 5.0f;    // metres per second
constexpr float kFollowMinSpeed = 1.3f;    // a walk
struct BotFollow {
    bool valid = false;
    float x = 0, z = 0;
};
inline float bot_follow_speed(float over_stop) {
    const float v = kFollowMinSpeed + 0.9f * over_stop;
    return v > kFollowMaxSpeed ? kFollowMaxSpeed : v;
}
// One step toward (px, pz) for dt seconds. Returns how far it walked (0: it stands, or it was just put next to you).
inline float bot_follow_step(BotFollow& f, float px, float pz, float dt) {
    if (!(dt > 0.0f)) dt = 0.0f;
    if (dt > 0.25f) dt = 0.25f;
    if (f.valid) {
        const float dx0 = px - f.x, dz0 = pz - f.z;
        if (std::sqrt(dx0 * dx0 + dz0 * dz0) > kFollowSnap) f.valid = false;
    }
    if (!f.valid) {
        f.x = px + kFollowStop + 0.5f;
        f.z = pz;
        f.valid = true;
        return 0.0f;
    }
    const float dx = px - f.x, dz = pz - f.z;
    const float d = std::sqrt(dx * dx + dz * dz);
    if (d <= kFollowStop) return 0.0f;
    const float over = d - kFollowStop;
    float step = bot_follow_speed(over) * dt;
    if (step > over) step = over;
    f.x += dx / d * step;
    f.z += dz / d * step;
    return step;
}

// (9.38) What the loopback bot DOES with its body, picked in the script's drop-down (kind 11, "state:<key>"). Timer is how it always was (the exe's
// radio decides where it walks, and it blocks / crouches / heals on a 16 s loop); Copy does what you do (your pose and gun bits, your rotation, and it
// stands kCopyOffsetX metres beside you, so it moves exactly as fast as you); the rest show one state, so each animation can be looked at as long as
// wanted: the ones with a speed circle around a fixed spot at that speed, the others stand still where they are.
enum class BotAct : int { Timer = 0, Copy, Idle, Walk, Run, Crouch, CrouchWalk, Guard, Heal, Gun, GunWalk, GunRun, Aim, Shoot };
constexpr float kCopyOffsetX = 1.6f;      // metres: the Copy bot stands this far from you (along the world x axis)
constexpr float kBotWalkSpeed = 1.4f;     // metres per second (the script calls anything under 2.4 a walk)
constexpr float kBotRunSpeed = 4.5f;      // ... and from 2.4 a run
constexpr float kBotCrouchWalkSpeed = 0.9f;
constexpr float kBotShootEvery = 1.5f;    // Shoot: a shot every this many seconds, the "just fired" bit up for kBotShootBit of them
constexpr float kBotShootBit = 0.4f;
inline const char* bot_act_key(BotAct a) {
    switch (a) {
        case BotAct::Timer: return "timer";
        case BotAct::Copy: return "copy";
        case BotAct::Idle: return "idle";
        case BotAct::Walk: return "walk";
        case BotAct::Run: return "run";
        case BotAct::Crouch: return "crouch";
        case BotAct::CrouchWalk: return "crouchwalk";
        case BotAct::Guard: return "guard";
        case BotAct::Heal: return "heal";
        case BotAct::Gun: return "gun";
        case BotAct::GunWalk: return "gunwalk";
        case BotAct::GunRun: return "gunrun";
        case BotAct::Aim: return "aim";
        case BotAct::Shoot: return "shoot";
    }
    return "timer";
}
// "state:<key>": true and the state when the payload is one; false for anything else (the bot keeps what it does).
inline bool bot_act_command(const std::string& payload, BotAct& act) {
    if (payload.compare(0, 6, "state:") != 0) return false;
    const std::string k = payload.substr(6);
    for (int i = 0; i <= static_cast<int>(BotAct::Shoot); ++i) {
        if (k == bot_act_key(static_cast<BotAct>(i))) {
            act = static_cast<BotAct>(i);
            return true;
        }
    }
    return false;
}
// The pose / gun bits a state shows (not Timer and Copy: those come from elsewhere). `t` is seconds, for the flicker of the shot bit.
inline uint16_t bot_act_flags(BotAct a, float t) {
    switch (a) {
        case BotAct::Crouch:
        case BotAct::CrouchWalk: return kFlagPoseCrouch;
        case BotAct::Guard: return kFlagPoseGuard;
        case BotAct::Heal: return kFlagPoseHeal;
        case BotAct::Gun:
        case BotAct::GunWalk:
        case BotAct::GunRun: return kFlagGun;
        case BotAct::Aim: return static_cast<uint16_t>(kFlagGun | kFlagAim);
        case BotAct::Shoot: {
            const float ph = std::fmod(t < 0.0f ? 0.0f : t, kBotShootEvery);
            return static_cast<uint16_t>(kFlagGun | kFlagAim | (ph < kBotShootBit ? kFlagShoot : 0));
        }
        default: return 0;
    }
}
// How fast a state walks around (metres per second); 0 = it stands.
inline float bot_act_speed(BotAct a) {
    switch (a) {
        case BotAct::Walk:
        case BotAct::GunWalk: return kBotWalkSpeed;
        case BotAct::Run:
        case BotAct::GunRun: return kBotRunSpeed;
        case BotAct::CrouchWalk: return kBotCrouchWalkSpeed;
        default: return 0.0f;
    }
}

// "e|char|clancy|x|y|z": what the script's own "char" event looks like (its argument is the key).
inline std::string bot_character_text(const std::string& key, double x, double y, double z) {
    char b[160];
    std::snprintf(b, sizeof(b), "e|char|%s|%.2f|%.2f|%.2f", key.c_str(), x, y, z);
    return b;
}

}  // namespace re7mp
