// (10.9) INVITE TEXT. One short line that says how to reach a host: the Steam ID (for a Steam invite / Steam relay, later) and/or a direct
// address (ip:port, the way the exe connects today). It is what a Steam friend invite carries as its "connect" string (at most 255 characters
// there), and it can also be pasted into a chat by hand today. Both ways can be in the same line, so a joiner can try one and then the other
// ("if it does not work for one person it can work for another"): see the Steam invite plan in the project docs.
//
//     re7mp1;s=<SteamID64>;a=<host:port>;p=<wire protocol>;n=<name>
//
// Every field but `re7mp1` is optional (the line needs at least one of s and a); unknown fields are skipped (so a newer build's line still reads);
// the name is percent-encoded. Pure text: nothing here talks to Steam or to the network.
#pragma once
#include <cstdint>
#include <string>

namespace re7mp {

struct Invite {
    uint64_t steam_id = 0;   // 0 = none (direct only)
    std::string host;        // "" = none (Steam only); a name or an IPv4 / IPv6 address, without the port
    int port = 0;            // with host: 1..65535
    int protocol = 0;        // the host's wire protocol version (0 = not said)
    std::string name;        // the host's player name (<= 24 bytes)
    bool has_steam() const { return steam_id != 0; }
    bool has_direct() const { return !host.empty() && port > 0; }
};

constexpr size_t kInviteMaxChars = 200;      // inside Steam's 255-character connect string, with room
constexpr uint64_t kSteamIdIndividualMin = 76561197960265729ULL;  // account id 1 of the public universe
constexpr uint64_t kSteamIdIndividualMax = 76561202255233023ULL;  // account id 0xFFFFFFFF

inline bool invite_host_char_ok(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '-' || c == ':';
}

inline std::string invite_encode_name(const std::string& n) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : n.substr(0, 24)) {
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '_' || c == '.') {
            out += static_cast<char>(c);
        } else {
            out += '%';
            out += hex[c >> 4];
            out += hex[c & 15];
        }
    }
    return out;
}

inline bool invite_decode_name(const std::string& in, std::string& out) {
    out.clear();
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] != '%') {
            if (in[i] == ';' || static_cast<unsigned char>(in[i]) < 0x20) return false;
            out += in[i];
            continue;
        }
        if (i + 2 >= in.size()) return false;  // a '%' needs two hex digits after it
        auto hv = [](char h) -> int { return h >= '0' && h <= '9' ? h - '0' : h >= 'A' && h <= 'F' ? h - 'A' + 10 : h >= 'a' && h <= 'f' ? h - 'a' + 10 : -1; };
        const int a = hv(in[i + 1]), b = hv(in[i + 2]);
        if (a < 0 || b < 0) return false;
        const char c = static_cast<char>(a * 16 + b);
        if (static_cast<unsigned char>(c) < 0x20 || c == 0x7f) return false;
        out += c;
        i += 2;
        if (out.size() > 24) return false;
    }
    return out.size() <= 24;
}

// The line for an invite, or "" when it has neither a Steam ID nor a direct address (or a field is out of range).
inline std::string make_invite(const Invite& v) {
    if (!v.has_steam() && !v.has_direct()) return std::string();
    if (v.steam_id != 0 && (v.steam_id < kSteamIdIndividualMin || v.steam_id > kSteamIdIndividualMax)) return std::string();
    if (!v.host.empty() && (v.host.size() > 64 || v.port < 1 || v.port > 65535)) return std::string();
    for (char c : v.host) if (!invite_host_char_ok(c)) return std::string();
    std::string out = "re7mp1";
    if (v.steam_id != 0) out += ";s=" + std::to_string(v.steam_id);
    if (v.has_direct()) out += ";a=" + v.host + ":" + std::to_string(v.port);
    if (v.protocol > 0 && v.protocol < 256) out += ";p=" + std::to_string(v.protocol);
    if (!v.name.empty()) out += ";n=" + invite_encode_name(v.name);
    return out.size() <= kInviteMaxChars ? out : std::string();
}

// Reads an invite line (spaces around it are ignored). Returns false, with the reason in *why, when it is not one.
inline bool parse_invite(const std::string& text, Invite& out, std::string* why = nullptr) {
    auto fail = [&](const char* w) { if (why) *why = w; return false; };
    size_t b = 0, e = text.size();
    while (b < e && (text[b] == ' ' || text[b] == '\t' || text[b] == '\r' || text[b] == '\n')) ++b;
    while (e > b && (text[e - 1] == ' ' || text[e - 1] == '\t' || text[e - 1] == '\r' || text[e - 1] == '\n')) --e;
    const std::string t = text.substr(b, e - b);
    if (t.empty()) return fail("empty");
    if (t.size() > kInviteMaxChars) return fail("too long");
    if (t.compare(0, 6, "re7mp1") != 0 || (t.size() > 6 && t[6] != ';')) return fail("not an re7mp invite (it starts with re7mp1)");
    Invite v;
    size_t pos = 6;
    while (pos < t.size()) {
        ++pos;  // the ';'
        size_t end = t.find(';', pos);
        if (end == std::string::npos) end = t.size();
        const std::string f = t.substr(pos, end - pos);
        pos = end;
        if (f.size() < 2 || f[1] != '=') continue;  // an unknown or empty field is skipped
        const std::string val = f.substr(2);
        if (f[0] == 's') {
            if (val.empty() || val.size() > 20) return fail("bad Steam ID");
            uint64_t id = 0;
            for (char c : val) {
                if (c < '0' || c > '9') return fail("bad Steam ID");
                id = id * 10 + static_cast<uint64_t>(c - '0');
            }
            if (id < kSteamIdIndividualMin || id > kSteamIdIndividualMax) return fail("not a player's Steam ID");
            v.steam_id = id;
        } else if (f[0] == 'a') {
            const size_t colon = val.rfind(':');
            if (colon == std::string::npos || colon == 0 || colon + 1 >= val.size()) return fail("bad address (host:port)");
            const std::string host = val.substr(0, colon), port = val.substr(colon + 1);
            if (host.size() > 64) return fail("bad address (host:port)");
            for (char c : host) if (!invite_host_char_ok(c)) return fail("bad address (host:port)");
            if (port.size() > 5) return fail("bad port");
            int pn = 0;
            for (char c : port) {
                if (c < '0' || c > '9') return fail("bad port");
                pn = pn * 10 + (c - '0');
            }
            if (pn < 1 || pn > 65535) return fail("bad port");
            v.host = host;
            v.port = pn;
        } else if (f[0] == 'p') {
            int pn = 0;
            if (val.empty() || val.size() > 3) return fail("bad protocol");
            for (char c : val) {
                if (c < '0' || c > '9') return fail("bad protocol");
                pn = pn * 10 + (c - '0');
            }
            v.protocol = pn;
        } else if (f[0] == 'n') {
            if (!invite_decode_name(val, v.name)) return fail("bad name");
        }
    }
    if (!v.has_steam() && !v.has_direct()) return fail("it has neither a Steam ID nor an address");
    out = v;
    return true;
}

}  // namespace re7mp
