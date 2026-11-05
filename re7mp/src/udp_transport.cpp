#include "transport.hpp"

#include <cstring>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
static inline int last_error() { return WSAGetLastError(); }
static inline void close_sock(uintptr_t s) { closesocket(static_cast<SOCKET>(s)); }
static const uintptr_t kBadSock = static_cast<uintptr_t>(INVALID_SOCKET);
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
static inline int last_error() { return errno; }
static inline void close_sock(uintptr_t s) { close(static_cast<int>(s)); }
static const uintptr_t kBadSock = static_cast<uintptr_t>(-1);
#endif

namespace re7mp {

std::unique_ptr<UdpTransport> UdpTransport::create(uint16_t local_port, const std::string& peer_host,
                                                   uint16_t peer_port, std::string& err) {
    std::unique_ptr<UdpTransport> t(new UdpTransport());

#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        err = "WSAStartup failed";
        return nullptr;
    }
    t->wsa_started_ = true;
#endif

    // Resolve the peer (IPv4 only for now).
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    addrinfo* res = nullptr;
    if (getaddrinfo(peer_host.c_str(), nullptr, &hints, &res) != 0 || !res) {
        err = "could not resolve peer host '" + peer_host + "'";
        return nullptr;
    }
    t->peer_ip_be_ = reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr.s_addr;
    freeaddrinfo(res);
    t->peer_port_ = peer_port;

    auto s = static_cast<uintptr_t>(socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP));
    if (s == kBadSock) {
        err = "socket() failed, error " + std::to_string(last_error());
        return nullptr;
    }
    t->sock_ = s;

#ifdef _WIN32
    // Windows reports ICMP "port unreachable" as a recvfrom error on UDP sockets,
    // which would break receiving whenever the peer isn't up yet. Turn that off.
    DWORD bytes = 0;
    BOOL new_behavior = FALSE;
    WSAIoctl(static_cast<SOCKET>(s), SIO_UDP_CONNRESET, &new_behavior, sizeof(new_behavior), nullptr, 0,
             &bytes, nullptr, nullptr);
#endif

    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons(local_port);
    if (bind(static_cast<decltype(socket(0, 0, 0))>(s), reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0) {
        err = "bind() to UDP port " + std::to_string(local_port) + " failed, error " + std::to_string(last_error());
        return nullptr;
    }
    return t;
}

UdpTransport::~UdpTransport() {
    if (sock_ != kBadSock) close_sock(sock_);
#ifdef _WIN32
    if (wsa_started_) WSACleanup();
#endif
}

bool UdpTransport::send(const void* data, size_t len) {
    sockaddr_in to{};
    to.sin_family = AF_INET;
    to.sin_addr.s_addr = peer_ip_be_;
    to.sin_port = htons(peer_port_);
    auto n = sendto(static_cast<decltype(socket(0, 0, 0))>(sock_), reinterpret_cast<const char*>(data),
                    static_cast<int>(len), 0, reinterpret_cast<sockaddr*>(&to), sizeof(to));
    return n == static_cast<decltype(n)>(len);
}

int UdpTransport::recv(void* buf, size_t cap, int timeout_ms) {
    auto fd = static_cast<decltype(socket(0, 0, 0))>(sock_);
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    timeval tv{};
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    int ready = select(static_cast<int>(fd) + 1, &rfds, nullptr, nullptr, &tv);
#ifndef _WIN32
    if (ready < 0 && errno == EINTR) return 0;  // interrupted by a signal (e.g. Ctrl+C)
#endif
    if (ready < 0) return -1;
    if (ready == 0) return 0;

    sockaddr_in from{};
    socklen_t from_len = sizeof(from);
    auto n = recvfrom(fd, reinterpret_cast<char*>(buf), static_cast<int>(cap), 0,
                      reinterpret_cast<sockaddr*>(&from), &from_len);
    if (n < 0) return 0;  // transient errors are treated as "nothing this time"
    // Only accept datagrams from the configured peer's IP address.
    if (from.sin_addr.s_addr != peer_ip_be_) return 0;
    return static_cast<int>(n);
}

}  // namespace re7mp
