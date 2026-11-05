#pragma once
// Transport abstraction. Game-side code only talks to ITransport, so a Steam
// networking backend can be added later without touching the rest.
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

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
};

// Plain UDP. Symmetric: both sides bind a local port and send to the other.
class UdpTransport : public ITransport {
public:
    // Returns nullptr and fills `err` on failure.
    static std::unique_ptr<UdpTransport> create(uint16_t local_port, const std::string& peer_host,
                                                uint16_t peer_port, std::string& err);
    ~UdpTransport() override;

    bool send(const void* data, size_t len) override;
    int recv(void* buf, size_t cap, int timeout_ms) override;

private:
    UdpTransport() = default;
    uintptr_t sock_ = static_cast<uintptr_t>(-1);  // SOCKET on Windows, fd elsewhere
    uint32_t peer_ip_be_ = 0;                      // network byte order
    uint16_t peer_port_ = 0;                       // host byte order
    bool wsa_started_ = false;
};

}  // namespace re7mp
