// (10.10) The Steam relay transport: the same ITransport the TCP one is, over ISteamNetworkingMessages (see steam_api.hpp for how and why).
// (10.13) It no longer waits for the game to say something: each side sends a tiny hello at once and every second until it hears the other (then a
// quiet keepalive), because "relay ready (100)" only says Steam's network is up. The session with the friend only exists once somebody SENDS, and the
// engine sends nothing until the Lua script writes a pose. The log also carries the session's own state, so a failure says where it stopped.
// Datagrams go out as RELIABLE messages (retransmitted and kept in order, like the TCP link the rest of the engine was written for), addressed to the
// friend's SteamID64. Only that friend's messages are taken; anyone else's are counted and dropped.
#pragma once
#include <chrono>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "steam_api.hpp"
#include "transport.hpp"

namespace re7mp {

class SteamTransport : public ITransport {
public:
    using Clock = std::chrono::steady_clock;

    // Starts Steam (api->init), refuses a peer that is not a player's Steam ID or is the player itself, and accepts the peer's session.
    // nullptr, with the reason in err, when it cannot.
    static std::unique_ptr<SteamTransport> create(std::unique_ptr<ISteamApi> api, uint64_t peer_id, std::string& err);

    ~SteamTransport() override;

    bool send(const void* data, size_t len) override;
    int recv(void* buf, size_t cap, int timeout_ms) override;
    bool take_status(std::string& msg) override;

    bool connected() const { return connected_; }
    uint64_t peer_id() const { return peer_; }
    uint64_t self_id() const { return self_; }
    uint64_t strays() const { return strays_; }        // messages from anyone but the friend (dropped)
    uint64_t send_failures() const { return send_failures_; }
    int relay_status() const { return relay_seen_; }
    uint64_t hellos_sent() const { return hellos_sent_; }
    uint64_t hellos_seen() const { return hellos_seen_; }
    bool is_hello(const std::vector<uint8_t>& d) const { return d.size() == 8 && std::memcmp(d.data(), "S7HI", 4) == 0; }

    // Tests drive time themselves.
    void set_clock_for_tests(std::function<Clock::time_point()> now) { now_ = std::move(now); }

    static constexpr int kLostAfterMs = 10000;   // nothing from the friend for this long = the link is called lost
    static constexpr int kAcceptEveryMs = 2000;  // until the first message: the session is accepted again this often (a friend who started later)
    static constexpr int kHelloEveryMs = 1000;   // (10.13) until the first message: a hello this often
    static constexpr int kKeepAliveMs = 4000;    // (10.13) afterwards, when nothing else has been sent for this long
    static constexpr int kSessionPollMs = 500;   // (10.13) how often the session's state is looked at (logged when it changes)
    static constexpr int kStuckHintMs = 20000;   // (10.13) silent for this long: the log says what Steam says about the session and what to check

private:
    SteamTransport() = default;
    void pump();
    void say(const std::string& s) { status_.push_back(s); }
    bool raw_send(const void* data, size_t len);  // the send + its one-line complaint when Steam refuses
    void send_hello(Clock::time_point now);
    void poll_session(Clock::time_point now);
    void tell_stuck(Clock::time_point now);

    std::unique_ptr<ISteamApi> api_;
    uint64_t peer_ = 0, self_ = 0;
    std::string peer_name_;
    std::deque<std::vector<uint8_t>> inbox_;
    std::deque<std::string> status_;
    bool connected_ = false, ever_connected_ = false;
    int relay_seen_ = -1000;
    uint64_t strays_ = 0, send_failures_ = 0;
    int last_send_result_ = 1;
    bool stray_told_ = false;
    std::function<Clock::time_point()> now_ = [] { return Clock::now(); };
    Clock::time_point last_rx_{}, last_accept_{}, last_relay_check_{};
    Clock::time_point started_{}, last_tx_{}, last_session_check_{}, last_stuck_{};
    bool have_rx_ = false;
    uint64_t hellos_sent_ = 0, hellos_seen_ = 0;
    uint32_t hello_seq_ = 0;
    int session_state_seen_ = -1, session_reason_seen_ = 0;
    uint32_t session_relay_seen_ = 0;
    int stuck_told_ = 0;
};

}  // namespace re7mp
