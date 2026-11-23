// (10.10) STEAM: the small interface the Steam relay transport talks to, and the pure helpers around Steam IDs.
//
// How the other mod (Molded Together, plugins/source/CoopNet.cs) does it: its plugin runs INSIDE the game, so it only asks the game's own, already
// initialised steam_api64.dll for the interfaces and sends with ISteamNetworkingMessages: no connect step, the peer is addressed by its SteamID64, Valve's
// relay (or a direct P2P path) carries it, nobody forwards a port. Reliable messages (flag 8) are retransmitted and kept in order; AutoRestartBrokenSession
// (32) revives a broken session; NoNagle (1) sends at once. The receiving side has to ACCEPT the session (AcceptSessionWithUser): the other mod does that in
// advance for the one friend whose SteamID it was given. The relay is ready when GetRelayNetworkStatus says 100 (InitRelayNetworkAccess starts it).
//
// re7mp.exe is a separate process, so the exe must initialise Steam itself (SteamAPI_Init, with the app id 418370 in the environment) and keep
// SteamAPI_RunCallbacks going. Whether a second process can do that while RE7 runs is not documented by Valve; the exe says what happened in its log
// ("Steam: ..." lines), and falls back to the direct TCP connection, which is still there.
//
// (10.13) What the link did when it said "ready (100)" and nothing came: the log now carries the session's own state (Steam's
// ESteamNetworkingConnectionState and its end reason), a hello from each side so the session starts without the game running, and the
// Steam app id the exe uses (480 by default: a second process that calls itself Resident Evil 7 shares that app's pipe with the game, and Steam
// may hand the other player's session request to the game, which ignores it). See steam_dyn_win.cpp.
//
// ISteamApi is what the transport needs, nothing more. steam_dyn_win.cpp implements it with LoadLibrary on the game's own steam_api64.dll; the tests
// use a mock that behaves like Steam (a session must be accepted before its messages arrive).
#pragma once
#include <cstdint>
#include <string>
#include <vector>

#include "invite.hpp"

namespace re7mp {

constexpr uint64_t kSteamId64Base = 76561197960265728ULL;  // SteamID64 = this + the 32-bit account id (a normal player's account)

inline uint64_t steam64_from_account(uint32_t account) { return account == 0 ? 0 : kSteamId64Base + account; }
inline uint32_t account_from_steam64(uint64_t id) {
    return (id >= kSteamIdIndividualMin && id <= kSteamIdIndividualMax) ? static_cast<uint32_t>(id - kSteamId64Base) : 0;
}

struct SteamFriendInfo {
    uint64_t id = 0;
    std::string name;
    bool online = false;
    bool in_re7 = false;  // Steam says this friend is playing Resident Evil 7 (app 418370) right now
};

struct SteamMessage {
    uint64_t from = 0;
    std::vector<uint8_t> data;
};

// What Steam says about the session with one user (ISteamNetworkingMessages::GetSessionConnectionInfo).
struct SteamSessionInfo {
    bool known = false;       // false: the call is not available (an old steam_api64.dll) or Steam gave no answer
    int state = 0;            // 0 no session, 1 connecting, 2 finding a route, 3 connected, 4 closed by the other side, 5 problem detected here
    int end_reason = 0;       // ESteamNetConnectionEnd (1000s = local, 2000s = remote, 4000s = misc)
    std::string end_debug;    // Steam's own words for it
    uint32_t pop_remote = 0;  // the other side's relay data centre, 4 letters packed in an int ('fra', 'ams' ...); 0 = unknown
    uint32_t pop_relay = 0;   // the relay carrying the session; 0 = a direct path (or not yet)
};

inline const char* session_state_words(int s) {
    switch (s) {
        case 0: return "no session yet";
        case 1: return "connecting (waiting for the other side to answer)";
        case 2: return "finding a route";
        case 3: return "connected";
        case 4: return "closed by the other side";
        case 5: return "failed here";
        default: return "unknown state";
    }
}

// A relay data centre id is up to four letters packed into an int ("fra" = 0x667261).
inline std::string pop_text(uint32_t pop) {
    std::string t;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const char c = static_cast<char>((pop >> shift) & 0xFF);
        if (c >= 'a' && c <= 'z') t += c;
        else if (c >= 'A' && c <= 'Z') t += c;
        else if (c >= '0' && c <= '9') t += c;
    }
    return t;
}

class ISteamApi {
public:
    virtual ~ISteamApi() = default;

    // Loads Steam's library and gets the interfaces; starts the relay network. false (with the reason in err) when that cannot be done.
    virtual bool init(std::string& err) = 0;
    // Has to be called often (Steam's relay and sessions make no progress without it).
    virtual void run_callbacks() = 0;
    virtual uint64_t self_id() = 0;
    virtual std::string self_name() = 0;
    // ESteamNetworkingAvailability: 100 = ready, 3 = attempting, 0 = not started yet, below 0 = failed.
    virtual int relay_status() = 0;
    // The friends this account has (regular friends), online ones first.
    virtual std::vector<SteamFriendInfo> friends() = 0;
    // Agrees to talk to this user (their messages are delivered only after this).
    virtual bool accept_session(uint64_t peer) = 0;
    // Sends one message to the user (any size up to 512 KB). Returns Steam's EResult: 1 = OK.
    virtual int send(uint64_t peer, const void* data, size_t len, bool reliable) = 0;
    // Takes what arrived since the last call (at most max messages).
    virtual void receive(std::vector<SteamMessage>& out, int max) = 0;
    // (10.13) The state of the session with this user, for the log. (known = false when Steam cannot say.)
    virtual SteamSessionInfo session_info(uint64_t peer) {
        (void)peer;
        return SteamSessionInfo{};
    }
    // (10.13) Ends the session with this user when the link is stopped (so the next Start begins a clean one).
    virtual void close_session(uint64_t peer) { (void)peer; }
    // (10.13) Which Steam app this process is running as, in words for the log ("app id 480 (Spacewar)").
    virtual std::string app_text() { return std::string(); }
};

// A Steam ID as people write it: the 17-digit SteamID64, a profile address (steamcommunity.com/profiles/<id>), an invite line (re7mp1;s=...), or the
// short account number a Steam log shows (up to 10 digits). `why` says what was wrong. 0 in `out` is never returned on success.
inline bool parse_steam_id_text(const std::string& text, uint64_t& out, std::string* why = nullptr) {
    auto fail = [&](const char* w) {
        if (why) *why = w;
        return false;
    };
    size_t b = 0, e = text.size();
    while (b < e && (text[b] == ' ' || text[b] == '\t' || text[b] == '\r' || text[b] == '\n')) ++b;
    while (e > b && (text[e - 1] == ' ' || text[e - 1] == '\t' || text[e - 1] == '\r' || text[e - 1] == '\n')) --e;
    const std::string t = text.substr(b, e - b);
    if (t.empty()) return fail("empty");
    if (t.compare(0, 6, "re7mp1") == 0) {
        Invite inv;
        std::string w;
        if (!parse_invite(t, inv, &w)) return fail("that is not a good invite line");
        if (!inv.has_steam()) return fail("that invite line has no Steam ID (it is a direct-connection invite)");
        out = inv.steam_id;
        return true;
    }
    std::string digits;
    const size_t p = t.find("/profiles/");
    if (p != std::string::npos) {
        for (size_t i = p + 10; i < t.size() && t[i] >= '0' && t[i] <= '9'; ++i) digits += t[i];
    } else {
        for (char c : t) {
            if (c < '0' || c > '9') return fail("a Steam ID is only digits (17 of them), or paste the invite line");
            digits += c;
        }
    }
    if (digits.empty() || digits.size() > 20) return fail("that is not a Steam ID");
    uint64_t v = 0;
    for (char c : digits) v = v * 10 + static_cast<uint64_t>(c - '0');
    if (v >= 1 && v <= 0xFFFFFFFFULL && digits.size() <= 10) v = steam64_from_account(static_cast<uint32_t>(v));  // a short account number
    if (v < kSteamIdIndividualMin || v > kSteamIdIndividualMax) return fail("that is not a player's Steam ID (it starts with 7656119...)");
    out = v;
    return true;
}

// Both players know each other's Steam ID, so both can work out who hosts without asking: the lower Steam ID hosts (the other mod's rule).
inline bool steam_i_host(uint64_t mine, uint64_t theirs) { return mine < theirs; }

// The player name Steam shows for an account, read from Steam's config\loginusers.vdf ("AccountName" and "PersonaName" under the SteamID64). "" when
// the file has no such account. Pure text work: the file is read by the caller.
inline std::string parse_loginusers_persona(const std::string& vdf, uint64_t steam64) {
    const std::string key = "\"" + std::to_string(steam64) + "\"";
    size_t p = vdf.find(key);
    if (p == std::string::npos) return std::string();
    const size_t open = vdf.find('{', p);
    if (open == std::string::npos) return std::string();
    const size_t close = vdf.find('}', open);
    const std::string block = vdf.substr(open, close == std::string::npos ? std::string::npos : close - open);
    for (const char* field : {"\"PersonaName\"", "\"AccountName\""}) {
        const size_t f = block.find(field);
        if (f == std::string::npos) continue;
        const size_t q1 = block.find('"', f + std::string(field).size());
        if (q1 == std::string::npos) continue;
        const size_t q2 = block.find('"', q1 + 1);
        if (q2 == std::string::npos || q2 == q1 + 1) continue;
        std::string v = block.substr(q1 + 1, q2 - q1 - 1);
        if (v.size() > 32) v.resize(32);
        return v;
    }
    return std::string();
}

}  // namespace re7mp
