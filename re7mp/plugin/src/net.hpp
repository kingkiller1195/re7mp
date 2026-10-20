// RE7 Co-op: transport layer.
//
// Star topology: one host (player id 0) relays everything between up to
// kMaxPlayersLimit-1 clients. Plain UDP, IPv4, one background thread, so game
// frame hitches (loading screens, VR frame pacing) never starve keep-alives.
//
// Two channels:
//   * unreliable  - poses (head + both hands), sent at ~30 Hz, newest wins
//   * reliable    - join/leave/chat/user events, ordered, go-back-N resend
//
// This header has no dependency on Lua or REFramework so it can be unit-tested
// on its own (see tests/loopback_test.cpp).
#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mp {

// 3 tracked points x (pos xyz + quat xyzw) = head, left hand, right hand.
constexpr int kPoseFloats = 21;
constexpr int kMaxPlayersLimit = 8;
constexpr size_t kMaxChatBytes = 256;
constexpr size_t kMaxUserBytes = 900;  // keeps every packet under a safe MTU

// Pose flag bits (sent with every pose packet).
enum PoseFlags : uint8_t {
    kPoseVR         = 1 << 0,  // sender is playing in VR (HMD active)
    kPoseHandsValid = 1 << 1,  // hand transforms are real tracked data
    kPoseCrouched   = 1 << 2,
    kPoseInGame     = 1 << 3,  // sender has a live player (not in a menu/loading)
};

enum class State { Idle, Hosting, Connecting, Connected };

enum class EventType {
    Connected,     // client: handshake finished. id = my id, text = host name
    Disconnected,  // client: lost/denied/closed. text = reason
    Joined,        // id, text = name, flags = join flags (bit0 = VR)
    Left,          // id
    Chat,          // id, text
    User,          // id, kind, text = opaque payload (Lua serialises it)
    Pose,          // id, flags, pose
};

struct Event {
    EventType type{};
    uint8_t id = 0;
    uint8_t kind = 0;
    uint8_t flags = 0;
    std::string text;
    std::array<float, kPoseFloats> pose{};
};

class Session {
public:
    Session();
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    // Start listening. Host is always player id 0.
    bool host(uint16_t port, uint8_t max_players, const std::string& name, std::string& err);
    // Start connecting (async: watch for EventType::Connected / Disconnected).
    bool join(const std::string& ip, uint16_t port, const std::string& name, std::string& err);
    // Safe to call at any time, any number of times.
    void stop();

    State state() const;
    uint8_t local_id() const;
    float rtt_ms() const;  // client -> host round trip, 0 on host

    void set_vr(bool vr);  // announced to others in the handshake
    // Latest local pose; the network thread sends it at its own cadence.
    void set_local_pose(uint8_t flags, const std::array<float, kPoseFloats>& pose);

    bool send_chat(const std::string& text);
    bool send_user(uint8_t kind, const std::string& payload);

    // Events since the last call. Pose events are coalesced to the newest per player.
    std::vector<Event> drain();

    // Testing aid: drop this percentage of incoming packets.
    void set_debug_loss(int percent);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace mp
