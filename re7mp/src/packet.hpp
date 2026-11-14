#pragma once
// Wire format (protocol v6). Little-endian, packed. Every packet starts with a Header.
//   Position  46 bytes  camera position + rotation (quaternion) + ready-check flags, sent ~25x/s
//   Name      45 bytes  display name, repeated every couple of seconds
//   Event     20 bytes  reliable-ish game event (new game + difficulty); resent until acked
//   EventAck  16 bytes
//   Message   20 bytes + payload (<= 200): reliable app messages (chat, pings, item events...); resent until acked
//   MessageAck 16 bytes
//   FileBegin / FileChunk / FileEnd: a file (a co-op save) sent in pieces over TCP; CRC-checked on arrival
//   State     18 bytes + payload (<= 3000): unreliable, latest-wins text blob (enemy snapshots), TCP only
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace re7mp {

constexpr uint32_t kMagic = 0x4D374552;  // bytes on the wire: 'R' 'E' '7' 'M'
constexpr uint8_t kProtocolVersion = 6;
constexpr size_t kMaxPayloadBytes = 200;
constexpr size_t kMaxStatePayload = 3000;  // an enemy snapshot: a few dozen bytes per enemy
constexpr size_t kMaxFileBytes = 16u * 1024u * 1024u;  // largest file we will send or accept
constexpr size_t kFileChunkBytes = 8192;
constexpr size_t kMaxLabelBytes = 64;
constexpr size_t kMaxNameBytes = 32;

// Ready-check state carried in every Position packet (state, not events, so a lost packet
// heals itself on the next one). Bits are plain values so the Lua side can use them too.
constexpr uint16_t kFlagReady = 1;      // "I want to start a new game"
constexpr uint16_t kFlagDiffMask = 6;   // bits 1-2: difficulty 0 Easy / 1 Normal / 2 Madhouse
constexpr uint16_t kFlagSeesReady = 8;  // "I can see that you are ready"
constexpr uint16_t kFlagGo = 16;        // "both ready, I'm going" (latched for a few seconds)
constexpr uint16_t kFlagNoPose = 32;    // position/rotation in this packet are not valid (no camera)
// Pose bits (9.7): what the sender's body is doing, so the other player's 3D stand-in can show it. The exe passes them
// through untouched; only the Lua script reads them. 512 and above are free.
constexpr uint16_t kFlagPoseGuard = 64;   // the player is blocking (arms up)
constexpr uint16_t kFlagPoseHeal = 128;   // the player is using a healing item
constexpr uint16_t kFlagPoseCrouch = 256; // the player is crouching (9.9; read from how far their eyes sit above their feet)
constexpr uint16_t kFlagPoseMask = kFlagPoseGuard | kFlagPoseHeal | kFlagPoseCrouch;
// Gun bits (9.28, the script's POSE_GUN / POSE_AIM / POSE_SHOOT): a gun is out, it is aimed, a shot was just fired. The exe passes them through;
// the loopback bot (9.38) shows and copies them.
constexpr uint16_t kFlagGun = 1024;
constexpr uint16_t kFlagAim = 2048;
constexpr uint16_t kFlagShoot = 4096;
constexpr uint16_t kFlagGunMask = kFlagGun | kFlagAim | kFlagShoot;
inline uint8_t flag_difficulty(uint16_t f) { return static_cast<uint8_t>((f & kFlagDiffMask) >> 1); }

// What the loopback bot does with its body (9.8, crouch added in 9.9), so the poses can be watched without a second player.
// A 16 s loop that starts `first_at` seconds after the engine did: block for 3.5 s, walk, crouch for 3 s, walk, heal for
// 3.6 s (the length measured in the game), walk. A negative first_at turns the poses off. Never two at once.
constexpr float kBotPoseLoop = 16.0f;
constexpr float kBotGuardSecs = 3.5f;
constexpr float kBotCrouchFrom = 4.5f;
constexpr float kBotCrouchSecs = 3.0f;
constexpr float kBotHealFrom = 8.5f;
constexpr float kBotHealSecs = 3.6f;
inline uint16_t bot_pose_flags(float seconds, float first_at) {
    if (first_at < 0.0f || seconds < first_at) return 0;
    const float t = std::fmod(seconds - first_at, kBotPoseLoop);
    if (t < kBotGuardSecs) return kFlagPoseGuard;
    if (t >= kBotCrouchFrom && t < kBotCrouchFrom + kBotCrouchSecs) return kFlagPoseCrouch;
    if (t >= kBotHealFrom && t < kBotHealFrom + kBotHealSecs) return kFlagPoseHeal;
    return 0;
}

enum class PacketType : uint8_t {
    Position = 1,
    Name = 2,
    Event = 3,
    EventAck = 4,
    Message = 5,
    MessageAck = 6,
    FileBegin = 7,
    FileChunk = 8,
    FileEnd = 9,
    State = 10,
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
struct FileBeginFixed {  // followed on the wire by `label_len` label bytes
    Header h;
    uint32_t file_id;
    uint32_t total;  // file size in bytes
    uint32_t crc;    // CRC-32 of the whole file
    uint16_t slot;   // save slot number the sender saved into
    uint8_t label_len;
};
struct FileChunkFixed {  // followed on the wire by `len` data bytes
    Header h;
    uint32_t file_id;
    uint32_t offset;
    uint16_t len;
};
struct FileEndPacket {
    Header h;
    uint32_t file_id;
};
struct MessageFixed {  // followed on the wire by `len` payload bytes
    Header h;
    uint32_t id;
    uint16_t kind;
    uint16_t len;
};
struct StateFixed {  // followed on the wire by `len` payload bytes
    Header h;
    uint32_t seq;
    uint16_t len;
};
#pragma pack(pop)

// (9.42) Exe-to-exe message kind: "acct|1|<Steam32 account id>" = "my PC's RE7 saves belong to this Steam account". Each re7mp.exe
// sends it once the other one is reachable (and again every minute) and CONSUMES the one it receives: it names both accounts in
// the manifest and the panel. An older exe hands it to its script, which has no handler for it and ignores it. No wire change.
constexpr uint16_t kMsgAccount = 65001;
inline std::string account_text(uint32_t account) { return "acct|1|" + std::to_string(account); }
// True for exactly "acct|1|<1..4294967295>" (digits only, no sign, no spaces, at most 10 of them).
inline bool parse_account_text(const std::string& s, uint32_t& out) {
    static const char kHead[] = "acct|1|";
    const size_t hn = sizeof(kHead) - 1;
    if (s.size() <= hn || s.size() > hn + 10 || s.compare(0, hn, kHead) != 0) return false;
    uint64_t v = 0;
    for (size_t i = hn; i < s.size(); ++i) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + static_cast<uint64_t>(s[i] - '0');
    }
    if (v == 0 || v > 0xFFFFFFFFull) return false;
    out = static_cast<uint32_t>(v);
    return true;
}

static_assert(sizeof(MessageFixed) == 20, "MessageFixed layout changed");
static_assert(sizeof(StateFixed) == 18, "StateFixed layout changed");
static_assert(sizeof(FileBeginFixed) == 27, "FileBeginFixed layout changed");
static_assert(sizeof(FileChunkFixed) == 22, "FileChunkFixed layout changed");
static_assert(sizeof(FileEndPacket) == 16, "FileEndPacket layout changed");
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
// If this datagram is one of ours (right magic) but from a different protocol version, returns that version; else -1.
// Lets the exe say "the other player's re7mp.exe is a different version" instead of silently ignoring it.
inline int peek_foreign_version(const void* data, size_t len) {
    if (len < sizeof(Header)) return -1;
    Header h;
    std::memcpy(&h, data, sizeof(h));
    if (h.magic != kMagic || h.version == kProtocolVersion) return -1;
    return h.version;
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

// ---- messages ------------------------------------------------------------------------------

// Payloads are short text (UTF-8, no control characters), so they can be passed through JSON files safely.
inline bool valid_text(const std::string& p, size_t max_bytes) {
    if (p.size() > max_bytes) return false;
    for (char ch : p) {
        const auto c = static_cast<unsigned char>(ch);
        if (c < 0x20 || c == 0x7F) return false;
    }
    return valid_utf8(p);
}
inline bool valid_payload(const std::string& p) { return valid_text(p, kMaxPayloadBytes); }
inline bool valid_state_payload(const std::string& p) { return valid_text(p, kMaxStatePayload); }

// Writes the packet into `out` (must hold sizeof(MessageFixed) + kMaxPayloadBytes). Returns its size, or 0 if
// the payload is not valid.
inline size_t encode_message(uint8_t* out, uint32_t session, uint32_t id, uint16_t kind, const std::string& payload) {
    if (!valid_payload(payload)) return 0;
    MessageFixed m{};
    m.h = make_header(PacketType::Message, session);
    m.id = id;
    m.kind = kind;
    m.len = static_cast<uint16_t>(payload.size());
    std::memcpy(out, &m, sizeof(m));
    std::memcpy(out + sizeof(m), payload.data(), payload.size());
    return sizeof(m) + payload.size();
}

inline bool decode_message(const void* data, size_t len, uint32_t& session, uint32_t& id, uint16_t& kind,
                           std::string& payload) {
    if (len < sizeof(MessageFixed) || peek_type(data, len) != static_cast<int>(PacketType::Message)) return false;
    MessageFixed m;
    std::memcpy(&m, data, sizeof(m));
    if (m.len > kMaxPayloadBytes || len != sizeof(m) + m.len) return false;
    payload.assign(static_cast<const char*>(data) + sizeof(m), m.len);
    if (!valid_payload(payload)) return false;
    session = m.h.session;
    id = m.id;
    kind = m.kind;
    return true;
}

inline AckPacket make_message_ack(uint32_t session, uint32_t id) {
    AckPacket p{};
    p.h = make_header(PacketType::MessageAck, session);
    p.id = id;
    return p;
}
inline bool decode_message_ack(const void* data, size_t len, AckPacket& out) {
    if (len != sizeof(AckPacket) || peek_type(data, len) != static_cast<int>(PacketType::MessageAck)) return false;
    std::memcpy(&out, data, sizeof(out));
    return true;
}

// ---- state blobs (enemy snapshots) ----------------------------------------------------------

// Unreliable and latest-wins: a lost snapshot is simply replaced by the next one. The engine does not look
// inside the text; the Lua scripts agree on its format. Returns an empty vector if the payload is not valid.
inline std::vector<uint8_t> encode_state(uint32_t session, uint32_t seq, const std::string& payload) {
    if (payload.empty() || !valid_state_payload(payload)) return {};
    StateFixed f{};
    f.h = make_header(PacketType::State, session);
    f.seq = seq;
    f.len = static_cast<uint16_t>(payload.size());
    std::vector<uint8_t> out(sizeof(f) + payload.size());
    std::memcpy(out.data(), &f, sizeof(f));
    std::memcpy(out.data() + sizeof(f), payload.data(), payload.size());
    return out;
}

inline bool decode_state(const void* data, size_t len, uint32_t& session, uint32_t& seq, std::string& payload) {
    if (len < sizeof(StateFixed) || peek_type(data, len) != static_cast<int>(PacketType::State)) return false;
    StateFixed f;
    std::memcpy(&f, data, sizeof(f));
    if (f.len == 0 || f.len > kMaxStatePayload || len != sizeof(f) + f.len) return false;
    payload.assign(static_cast<const char*>(data) + sizeof(f), f.len);
    if (!valid_state_payload(payload)) return false;
    session = f.h.session;
    seq = f.seq;
    return true;
}

// ---- files (co-op saves) -------------------------------------------------------------------

inline uint32_t crc32(const void* data, size_t len, uint32_t crc = 0) {
    static const std::array<uint32_t, 256> table = [] {
        std::array<uint32_t, 256> t{};
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            t[i] = c;
        }
        return t;
    }();
    crc = ~crc;
    const auto* p = static_cast<const uint8_t*>(data);
    for (size_t i = 0; i < len; ++i) crc = table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

inline bool valid_label(const std::string& l) {
    if (l.empty() || l.size() > kMaxLabelBytes) return false;
    for (char ch : l) {
        const auto c = static_cast<unsigned char>(ch);
        if (c < 0x20 || c == 0x7F) return false;
    }
    return valid_utf8(l);
}

inline std::vector<uint8_t> encode_file_begin(uint32_t session, uint32_t id, uint32_t total, uint32_t crc,
                                              uint16_t slot, const std::string& label) {
    FileBeginFixed f{};
    f.h = make_header(PacketType::FileBegin, session);
    f.file_id = id;
    f.total = total;
    f.crc = crc;
    f.slot = slot;
    f.label_len = static_cast<uint8_t>(label.size());
    std::vector<uint8_t> out(sizeof(f) + label.size());
    std::memcpy(out.data(), &f, sizeof(f));
    std::memcpy(out.data() + sizeof(f), label.data(), label.size());
    return out;
}

inline bool decode_file_begin(const void* data, size_t len, uint32_t& id, uint32_t& total, uint32_t& crc,
                              uint16_t& slot, std::string& label) {
    if (len < sizeof(FileBeginFixed) || peek_type(data, len) != static_cast<int>(PacketType::FileBegin)) return false;
    FileBeginFixed f;
    std::memcpy(&f, data, sizeof(f));
    if (len != sizeof(f) + f.label_len || f.total == 0 || f.total > kMaxFileBytes) return false;
    label.assign(static_cast<const char*>(data) + sizeof(f), f.label_len);
    if (!valid_label(label)) return false;
    id = f.file_id;
    total = f.total;
    crc = f.crc;
    slot = f.slot;
    return true;
}

inline std::vector<uint8_t> encode_file_chunk(uint32_t session, uint32_t id, uint32_t offset, const uint8_t* bytes,
                                              size_t n) {
    FileChunkFixed f{};
    f.h = make_header(PacketType::FileChunk, session);
    f.file_id = id;
    f.offset = offset;
    f.len = static_cast<uint16_t>(n);
    std::vector<uint8_t> out(sizeof(f) + n);
    std::memcpy(out.data(), &f, sizeof(f));
    std::memcpy(out.data() + sizeof(f), bytes, n);
    return out;
}

// On success `bytes` points into `data` (valid as long as `data` is).
inline bool decode_file_chunk(const void* data, size_t len, uint32_t& id, uint32_t& offset, const uint8_t*& bytes,
                              size_t& n) {
    if (len < sizeof(FileChunkFixed) || peek_type(data, len) != static_cast<int>(PacketType::FileChunk)) return false;
    FileChunkFixed f;
    std::memcpy(&f, data, sizeof(f));
    if (f.len == 0 || f.len > kFileChunkBytes || len != sizeof(f) + f.len) return false;
    id = f.file_id;
    offset = f.offset;
    bytes = static_cast<const uint8_t*>(data) + sizeof(f);
    n = f.len;
    return true;
}

inline FileEndPacket make_file_end(uint32_t session, uint32_t id) {
    FileEndPacket p{};
    p.h = make_header(PacketType::FileEnd, session);
    p.file_id = id;
    return p;
}
inline bool decode_file_end(const void* data, size_t len, uint32_t& id) {
    if (len != sizeof(FileEndPacket) || peek_type(data, len) != static_cast<int>(PacketType::FileEnd)) return false;
    FileEndPacket p;
    std::memcpy(&p, data, sizeof(p));
    id = p.file_id;
    return true;
}

}  // namespace re7mp
