#pragma once
// Transport abstraction. Game-side code only talks to ITransport, so a Steam
// networking backend can be added later without touching the rest.
#include <cstddef>
#include <chrono>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace re7mp {

class ITransport {
public:
    virtual ~ITransport() = default;

    // Send one datagram to the peer. Returns true if the whole datagram was sent.
    virtual bool send(const void* data, size_t len) = 0;

    // Wait up to timeout_ms for one datagram. Returns bytes received,
    // 0 if nothing usable arrived (timeout, or a datagram from an unexpected sender),
    // or -1 on a fatal error.
    virtual int recv(void* buf, size_t cap, int timeout_ms) = 0;

    // Connection-state messages worth showing the user (TCP: connected / lost). One per call.
    virtual bool take_status(std::string& msg) {
        (void)msg;
        return false;
    }
};

// TCP: reliable and ordered (the only transport since 9.7). The host needs a reachable port (Tailscale, or a forwarded one).
// Messages are framed with a 2-byte length so datagram-style send/recv keep working. One side Hosts (listens),
// the other Joins (connects, retrying every second and reconnecting if the link drops).
class TcpTransport : public ITransport {
public:
    enum class Role { Host, Join };

    // Host: listens on local_port; peer_host (optional) restricts who may connect.
    // Join: connects to peer_host:peer_port. Returns nullptr and fills `err` on failure.
    static std::unique_ptr<TcpTransport> create(Role role, uint16_t local_port, const std::string& peer_host,
                                                uint16_t peer_port, std::string& err);
    ~TcpTransport() override;

    bool send(const void* data, size_t len) override;
    int recv(void* buf, size_t cap, int timeout_ms) override;
    bool take_status(std::string& msg) override;
    bool connected() const { return conn_ != kNoSock; }

private:
    static constexpr uintptr_t kNoSock = static_cast<uintptr_t>(-1);
    static constexpr size_t kMaxFrame = 16384;
    static constexpr size_t kMaxOutBuffer = 262144;

    TcpTransport() = default;
    void service();
    void begin_connect();
    void check_connect();
    void on_connected(uintptr_t s, const std::string& what);
    void disconnect(const std::string& why);
    void flush();
    void read_some();
    bool extract_frame(void* buf, size_t cap, int& n_out);

    Role role_ = Role::Join;
    uintptr_t listen_ = kNoSock;      // Host
    uintptr_t conn_ = kNoSock;        // the live connection
    uintptr_t connecting_ = kNoSock;  // Join: a connect in progress
    uint32_t peer_ip_be_ = 0;
    uint16_t peer_port_ = 0;
    bool have_peer_ = false;
    std::vector<uint8_t> in_, out_;
    size_t in_off_ = 0;
    std::chrono::steady_clock::time_point next_connect_{}, connect_started_{};
    std::deque<std::string> status_;
    bool wsa_started_ = false;
};

}  // namespace re7mp
