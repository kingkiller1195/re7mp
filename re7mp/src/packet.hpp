#pragma once
// Wire format (protocol v2). Little-endian, packed. Every packet starts with a Header.
//   Position  46 bytes  camera position + rotation (quaternion) + ready-check flags, sent ~25x/s
//   Name      45 bytes  display name, repeated every couple of seconds (UDP can drop it)
//   Event     20 bytes  reliable-ish game event (new game + difficulty); resent until acked
//   EventAck  16 bytes
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace re7mp {

constexpr uint32_t kMagic = 0x4D374552;  // bytes on the wire: 'R' 'E' '7' 'M'
constexpr uint8_t kProtocolVersion = 3;
constexpr size_t kMaxNameBytes = 32;

// Ready-check state carried in every Position packet (state, not events, so a lost packet
// heals itself on the next one). Bits are plain values so the Lua side can use them too.
constexpr uint16_t kFlagReady = 1;      // "I want to start a new game"
constexpr uint16_t kFlagDiffMask = 6;   // bits 1-2: difficulty 0 Easy / 1 Normal / 2 Madhouse
constexpr uint16_t kFlagSeesReady = 8;  // "I can see that you are ready"
constexpr uint16_t kFlagGo = 16;        // "both ready, I'm going" (latched for a few seconds)
constexpr uint16_t kFlagNoPose = 32;    // position/rotation in this packet are not valid (no camera)
inline uint8_t flag_difficulty(uint16_t f) { return static_cast<uint8_t>((f & kFlagDiffMask) >> 1); }

enum class PacketType : uint8_t {
    Position = 1,
    Name = 2,
    Event = 3,
    EventAck = 4,
};

enum class EventType : uint8_t {
    NewGame = 1,  // arg = difficulty: 0 Easy, 1 Normal, 2 Madhouse
};

#pragma pack(push, 1)
struct Header {
    uint32_t magic;
    uint8_t version;
    uint8_t type;
    uint16_t reserved;
    uint32_t session;  // random per run; lets receivers reset their sequence tracking
};
struct PositionPacket {
    Header h;
    uint32_t seq;
    float x, y, z;
    float qx, qy, qz, qw;
    uint16_t flags;
};
struct NamePacket {
    Header h;
    uint8_t len;
    char name[kMaxNameBytes];
};
struct EventPacket {
    Header h;
    uint32_t id;
    uint8_t type;
    uint8_t arg;
    uint16_t reserved;
};
struct AckPacket {
    Header h;
    uint32_t id;
};
#pragma pack(pop)

static_assert(sizeof(Header) == 12, "Header layout changed");
static_assert(sizeof(PositionPacket) == 46, "PositionPacket layout changed");
static_assert(sizeof(NamePacket) == 45, "NamePacket layout changed");
static_assert(sizeof(EventPacket) == 20, "EventPacket layout changed");
static_assert(sizeof(AckPacket) == 16, "AckPacket layout changed");

inline Header make_header(PacketType t, uint32_t session) {
    Header h{};
    h.magic = kMagic;
    h.version = kProtocolVersion;
    h.type = static_cast<uint8_t>(t);
    h.session = session;
    return h;
}

// Returns the packet type, or -1 if the datagram isn't one of ours (bad size/magic/version).
inline int peek_type(const void* data, size_t len) {
    if (len < sizeof(Header)) return -1;
    Header h;
    std::memcpy(&h, data, sizeof(h));
    if (h.magic != kMagic || h.version != kProtocolVersion) return -1;
    return h.type;
}
inline uint32_t peek_session(const void* data) {
    Header h;
    std::memcpy(&h, data, sizeof(h));
    return h.session;
}

// ---- names ---------------------------------------------------------------------------------

inline bool valid_utf8(const std::string& s) {
    size_t i = 0;
    while (i < s.size()) {
        const auto c = static_cast<unsigned char>(s[i]);
        size_t n;
        uint32_t cp;
        if (c < 0x80) { n = 1; cp = c; }
        else if ((c & 0xE0) == 0xC0) { n = 2; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { n = 3; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { n = 4; cp = c & 0x07; }
        else return false;
        if (i + n > s.size()) return false;
        for (size_t k = 1; k < n; ++k) {
            const auto cc = static_cast<unsigned char>(s[i + k]);
            if ((cc & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (cc & 0x3F);
        }
        if ((n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) || (n == 4 && cp < 0x10000)) return false;  // overlong
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += n;
    }
    return true;
}

// Strips control characters and outer spaces, cuts to kMaxNameBytes on a character boundary,
// and returns "" if the result isn't valid UTF-8.
inline std::string sanitize_name(const std::string& in) {
    std::string s;
    for (char ch : in) {
        const auto c = static_cast<unsigned char>(ch);
        if (c >= 0x20 && c != 0x7F) s += ch;
    }
    const auto b = s.find_first_not_of(' ');
    if (b == std::string::npos) return {};
    s = s.substr(b, s.find_last_not_of(' ') - b + 1);
    if (s.size() > kMaxNameBytes) {
        size_t cut = kMaxNameBytes;
        while (cut > 0 && (static_cast<unsigned char>(s[cut]) & 0xC0) == 0x80) --cut;
        s.resize(cut);
    }
    return valid_utf8(s) ? s : std::string();
}

// ---- encode / decode -----------------------------------------------------------------------

inline PositionPacket make_position(uint32_t session, uint32_t seq, float x, float y, float z, float qx = 0,
                                    float qy = 0, float qz = 0, float qw = 1, uint16_t flags = 0) {
    PositionPacket p{};
    p.h = make_header(PacketType::Position, session);
    p.seq = seq;
    p.x = x; p.y = y; p.z = z;
    p.qx = qx; p.qy = qy; p.qz = qz; p.qw = qw;
    p.flags = flags;
    return p;
}

inline bool decode_position(const void* data, size_t len, PositionPacket& out) {
    if (len != sizeof(PositionPacket) || peek_type(data, len) != static_cast<int>(PacketType::Position)) return false;
    std::memcpy(&out, data, sizeof(out));
    const float v[7] = {out.x, out.y, out.z, out.qx, out.qy, out.qz, out.qw};
    for (float f : v) {
        if (!std::isfinite(f)) return false;
    }
    return true;
}

inline NamePacket make_name(uint32_t session, const std::string& name) {
    NamePacket p{};
    p.h = make_header(PacketType::Name, session);
    const std::string n = sanitize_name(name);
    p.len = static_cast<uint8_t>(n.size());
    std::memcpy(p.name, n.data(), n.size());
    return p;
}

// Returns false for malformed or empty names.
inline bool decode_name(const void* data, size_t len, std::string& out) {
    if (len != sizeof(NamePacket) || peek_type(data, len) != static_cast<int>(PacketType::Name)) return false;
    NamePacket p;
    std::memcpy(&p, data, sizeof(p));
    if (p.len == 0 || p.len > kMaxNameBytes) return false;
    const std::string raw(p.name, p.len);
    out = sanitize_name(raw);
    return !out.empty() && out == raw;  // reject anything sanitising would have altered
}

inline EventPacket make_event(uint32_t session, uint32_t id, EventType type, uint8_t arg) {
    EventPacket p{};
    p.h = make_header(PacketType::Event, session);
    p.id = id;
    p.type = static_cast<uint8_t>(type);
    p.arg = arg;
    return p;
}
inline bool decode_event(const void* data, size_t len, EventPacket& out) {
    if (len != sizeof(EventPacket) || peek_type(data, len) != static_cast<int>(PacketType::Event)) return false;
    std::memcpy(&out, data, sizeof(out));
    return true;
}
inline AckPacket make_ack(uint32_t session, uint32_t id) {
    AckPacket p{};
    p.h = make_header(PacketType::EventAck, session);
    p.id = id;
    return p;
}
inline bool decode_ack(const void* data, size_t len, AckPacket& out) {
    if (len != sizeof(AckPacket) || peek_type(data, len) != static_cast<int>(PacketType::EventAck)) return false;
    std::memcpy(&out, data, sizeof(out));
    return true;
}

}  // namespace re7mp
