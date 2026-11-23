#include <algorithm>
#include <cstring>
#include <thread>

#include "transport.hpp"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
static inline int last_error() { return WSAGetLastError(); }
static inline void close_raw(uintptr_t s) { closesocket(static_cast<SOCKET>(s)); }
static inline bool set_nonblocking(uintptr_t s) {
    u_long mode = 1;
    return ioctlsocket(static_cast<SOCKET>(s), FIONBIO, &mode) == 0;
}
static inline bool err_would_block(int e) { return e == WSAEWOULDBLOCK; }
static inline bool err_in_progress(int e) { return e == WSAEWOULDBLOCK; }
constexpr int kSendFlags = 0;
using RawSock = SOCKET;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
static inline int last_error() { return errno; }
static inline void close_raw(uintptr_t s) { close(static_cast<int>(s)); }
static inline bool set_nonblocking(uintptr_t s) {
    const int fd = static_cast<int>(s);
    const int fl = fcntl(fd, F_GETFL, 0);
    return fl >= 0 && fcntl(fd, F_SETFL, fl | O_NONBLOCK) == 0;
}
static inline bool err_would_block(int e) { return e == EWOULDBLOCK || e == EAGAIN; }
static inline bool err_in_progress(int e) { return e == EINPROGRESS; }
#ifdef MSG_NOSIGNAL
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;
#endif
using RawSock = int;
#endif

namespace re7mp {

namespace {
using Clock = std::chrono::steady_clock;

RawSock raw(uintptr_t s) { return static_cast<RawSock>(s); }

bool resolve_ipv4(const std::string& host, uint32_t& ip_be) {
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) return false;
    ip_be = reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr.s_addr;
    freeaddrinfo(res);
    return true;
}

std::string ip_text(uint32_t ip_be) {
    in_addr a{};
    a.s_addr = ip_be;
    char buf[INET_ADDRSTRLEN] = {0};
    if (!inet_ntop(AF_INET, &a, buf, sizeof(buf))) return "?";
    return buf;
}

// The OS error as the log shows it: the number (what to search for) and, for the usual ones, what it means.
std::string describe_error(int e) {
    std::string text;
#ifdef _WIN32
    switch (e) {
        case WSAECONNRESET: text = "the other side reset the connection"; break;
        case WSAECONNABORTED: text = "the connection was aborted"; break;
        case WSAETIMEDOUT: text = "timed out"; break;
        case WSAECONNREFUSED: text = "refused"; break;
        case WSAENETUNREACH: case WSAEHOSTUNREACH: text = "no route to the other side"; break;
        case WSAENETDOWN: case WSAENETRESET: text = "the network went down"; break;
        default: break;
    }
#else
    switch (e) {
        case ECONNRESET: text = "the other side reset the connection"; break;
        case ECONNABORTED: text = "the connection was aborted"; break;
        case ETIMEDOUT: text = "timed out"; break;
        case ECONNREFUSED: text = "refused"; break;
        case ENETUNREACH: case EHOSTUNREACH: text = "no route to the other side"; break;
        case EPIPE: text = "the other side closed the connection"; break;
        default: break;
    }
#endif
    return "error " + std::to_string(e) + (text.empty() ? "" : ": " + text);
}

void tune(uintptr_t s) {
    set_nonblocking(s);
    int one = 1;
    setsockopt(raw(s), IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof(one));
}
}  // namespace

std::unique_ptr<TcpTransport> TcpTransport::create(Role role, uint16_t local_port, const std::string& peer_host,
                                                   uint16_t peer_port, std::string& err) {
    std::unique_ptr<TcpTransport> t(new TcpTransport());
    t->role_ = role;
    t->peer_port_ = peer_port;

#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        err = "WSAStartup failed";
        return nullptr;
    }
    t->wsa_started_ = true;
#endif

    if (!peer_host.empty()) {
        if (!resolve_ipv4(peer_host, t->peer_ip_be_)) {
            err = "could not resolve '" + peer_host + "'";
            return nullptr;
        }
        t->have_peer_ = true;
    }

    if (role == Role::Host) {
        const auto s = static_cast<uintptr_t>(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
        if (static_cast<RawSock>(s) == static_cast<RawSock>(kNoSock)) {
            err = "socket() failed, error " + std::to_string(last_error());
            return nullptr;
        }
        t->listen_ = s;
#ifndef _WIN32
        int one = 1;
        setsockopt(raw(s), SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));  // quick restart after a crash
#endif
        sockaddr_in local{};
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = htonl(INADDR_ANY);
        local.sin_port = htons(local_port);
        if (bind(raw(s), reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0 || listen(raw(s), 1) != 0) {
            err = "could not listen on TCP port " + std::to_string(local_port) + ", error " +
                  std::to_string(last_error());
            return nullptr;
        }
        set_nonblocking(s);
    } else {
        if (!t->have_peer_) {
            err = "enter the host's address (ip:port)";
            return nullptr;
        }
        t->next_connect_ = Clock::now();
    }
    return t;
}

TcpTransport::~TcpTransport() {
    if (conn_ != kNoSock) close_raw(conn_);
    if (connecting_ != kNoSock) close_raw(connecting_);
    if (listen_ != kNoSock) close_raw(listen_);
#ifdef _WIN32
    if (wsa_started_) WSACleanup();
#endif
}

bool TcpTransport::take_status(std::string& msg) {
    if (status_.empty()) return false;
    msg = status_.front();
    status_.pop_front();
    return true;
}

void TcpTransport::on_connected(uintptr_t s, const std::string& what) {
    if (conn_ != kNoSock) close_raw(conn_);
    conn_ = s;
    connecting_ = kNoSock;
    tune(s);
    in_.clear();
    out_.clear();
    in_off_ = 0;
    connected_at_ = Clock::now();
    // 10.19a: the joiner says which of its own addresses the host sees (the host's "Other player" box has to match it)
    std::string msg = what;
    if (role_ == Role::Join) {
        sockaddr_in me{};
        socklen_t len = sizeof(me);
        if (getsockname(raw(s), reinterpret_cast<sockaddr*>(&me), &len) == 0 && me.sin_addr.s_addr != 0) {
            if (!msg.empty() && msg.back() == '.') msg.pop_back();
            msg += " (the host sees you as " + ip_text(me.sin_addr.s_addr) + ").";
        }
    }
    status_.push_back(msg);
}

// The host turned a connection away because of its "Other player" box. It used to do this without a word, and the joiner only saw "connected", then a reset.
void TcpTransport::note_refused(uint32_t ip_be) {
    const auto now = Clock::now();
    if (ip_be == refused_ip_be_ && now - refused_at_ < std::chrono::seconds(30)) return;
    refused_ip_be_ = ip_be;
    refused_at_ = now;
    status_.push_back("TCP: turned away a connection from " + ip_text(ip_be) + ": the 'Other player' box allows only " + ip_text(peer_ip_be_) +
                      ". If " + ip_text(ip_be) + " is the other player, clear that box (it is optional) or type " + ip_text(ip_be) + " in it.");
}

void TcpTransport::disconnect(const std::string& why) {
    if (conn_ != kNoSock) close_raw(conn_);
    conn_ = kNoSock;
    in_.clear();
    out_.clear();
    in_off_ = 0;
    const auto now = Clock::now();
    next_connect_ = now + std::chrono::seconds(1);
    status_.push_back(role_ == Role::Join ? "TCP connection lost (" + why + "); reconnecting..."
                                          : "TCP connection lost (" + why + "); waiting for the other player...");
    if (role_ == Role::Join) {
        // A host that accepts and drops at once (the "Other player" box names another address, another program on that port, a firewall that resets after the handshake)
        // looks the same from here every time: say so after the second time, then every tenth.
        quick_drops_ = (now - connected_at_ < std::chrono::seconds(3)) ? quick_drops_ + 1 : 0;
        if (quick_drops_ == 2 || (quick_drops_ > 2 && (quick_drops_ - 2) % 10 == 0)) {
            status_.push_back(
                "TCP: the host takes the connection and drops it at once (" + std::to_string(quick_drops_) +
                " times). Check on the host: (1) the 'Other player' box in re7mp.exe is empty or holds the address shown above as 'the host sees you as'; (2) the host's "
                "re7mp.exe is running as 'TCP: I host' on this port and nothing else uses that port; (3) re7mp.exe is allowed through the host's firewall on the VPN network.");
        }
    }
}

void TcpTransport::begin_connect() {
    const auto s = static_cast<uintptr_t>(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
    if (static_cast<RawSock>(s) == static_cast<RawSock>(kNoSock)) {
        next_connect_ = Clock::now() + std::chrono::seconds(1);
        return;
    }
    set_nonblocking(s);
    sockaddr_in to{};
    to.sin_family = AF_INET;
    to.sin_addr.s_addr = peer_ip_be_;
    to.sin_port = htons(peer_port_);
    const int rc = connect(raw(s), reinterpret_cast<sockaddr*>(&to), sizeof(to));
    if (rc == 0) {
        on_connected(s, "TCP: connected to the host.");
    } else if (err_in_progress(last_error())) {
        connecting_ = s;
        connect_started_ = Clock::now();
    } else {
        close_raw(s);
        next_connect_ = Clock::now() + std::chrono::seconds(1);
    }
}

void TcpTransport::check_connect() {
    fd_set w, e;
    FD_ZERO(&w);
    FD_ZERO(&e);
    FD_SET(raw(connecting_), &w);
    FD_SET(raw(connecting_), &e);
    timeval tv{};
    const int r = select(static_cast<int>(raw(connecting_)) + 1, nullptr, &w, &e, &tv);
    bool failed = false;
    if (r > 0) {
        int so_err = 0;
        socklen_t len = sizeof(so_err);
        getsockopt(raw(connecting_), SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&so_err), &len);
        if (FD_ISSET(raw(connecting_), &w) && so_err == 0) {
            on_connected(connecting_, "TCP: connected to the host.");
            return;
        }
        failed = true;
    } else if (Clock::now() - connect_started_ > std::chrono::seconds(5)) {
        failed = true;
    }
    if (failed) {
        close_raw(connecting_);
        connecting_ = kNoSock;
        next_connect_ = Clock::now() + std::chrono::seconds(1);
    }
}

void TcpTransport::service() {
    if (role_ == Role::Host) {
        for (;;) {  // a new connection replaces an old one (the peer restarted or its link died silently)
            sockaddr_in from{};
            socklen_t len = sizeof(from);
            const auto s = static_cast<uintptr_t>(accept(raw(listen_), reinterpret_cast<sockaddr*>(&from), &len));
            if (static_cast<RawSock>(s) == static_cast<RawSock>(kNoSock)) break;
            if (have_peer_ && from.sin_addr.s_addr != peer_ip_be_) {
                close_raw(s);
                note_refused(from.sin_addr.s_addr);
                continue;
            }
            const bool replaced = conn_ != kNoSock;
            on_connected(s, (replaced ? "TCP: the other player reconnected" : "TCP: the other player connected") + std::string(" (from ") + ip_text(from.sin_addr.s_addr) + ").");
        }
    } else if (conn_ == kNoSock) {
        if (connecting_ == kNoSock && Clock::now() >= next_connect_) begin_connect();
        if (connecting_ != kNoSock) check_connect();
    }
    if (conn_ != kNoSock) flush();
}

void TcpTransport::flush() {
    while (conn_ != kNoSock && !out_.empty()) {
        const auto n = ::send(raw(conn_), reinterpret_cast<const char*>(out_.data()), static_cast<int>(out_.size()),
                              kSendFlags);
        if (n > 0) {
            out_.erase(out_.begin(), out_.begin() + n);
        } else if (n < 0 && !err_would_block(last_error())) {
            disconnect("send failed, " + describe_error(last_error()));
        } else {
            break;
        }
    }
}

bool TcpTransport::send(const void* data, size_t len) {
    if (conn_ == kNoSock || len == 0 || len > kMaxFrame) return false;
    if (out_.size() + 2 + len > kMaxOutBuffer) return false;  // the peer isn't keeping up; drop (state resends)
    out_.push_back(static_cast<uint8_t>(len & 0xFF));
    out_.push_back(static_cast<uint8_t>((len >> 8) & 0xFF));
    const auto* p = static_cast<const uint8_t*>(data);
    out_.insert(out_.end(), p, p + len);
    flush();
    return conn_ != kNoSock;
}

void TcpTransport::read_some() {
    uint8_t tmp[4096];
    const auto n = ::recv(raw(conn_), reinterpret_cast<char*>(tmp), static_cast<int>(sizeof(tmp)), 0);
    if (n > 0) {
        in_.insert(in_.end(), tmp, tmp + n);
    } else if (n == 0) {
        disconnect("closed by the other side");
    } else {
        const int e = last_error();
        if (!err_would_block(e)) disconnect("read failed, " + describe_error(e));
    }
}

bool TcpTransport::extract_frame(void* buf, size_t cap, int& n_out) {
    while (conn_ != kNoSock && in_.size() - in_off_ >= 2) {
        const size_t len = static_cast<size_t>(in_[in_off_]) | (static_cast<size_t>(in_[in_off_ + 1]) << 8);
        if (len == 0 || len > kMaxFrame) {
            disconnect("bad frame");
            return false;
        }
        if (in_.size() - in_off_ < 2 + len) break;
        const bool fits = len <= cap;
        if (fits) std::memcpy(buf, &in_[in_off_ + 2], len);
        in_off_ += 2 + len;
        if (in_off_ == in_.size() || in_off_ > 8192) {
            in_.erase(in_.begin(), in_.begin() + static_cast<std::ptrdiff_t>(in_off_));
            in_off_ = 0;
        }
        if (fits) {
            n_out = static_cast<int>(len);
            return true;
        }
    }
    return false;
}

int TcpTransport::recv(void* buf, size_t cap, int timeout_ms) {
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        service();
        int n = 0;
        if (extract_frame(buf, cap, n)) return n;

        // Wait for data in short slices. Even with a zero timeout we poll the socket once.
        const auto remain = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        const int slice = static_cast<int>(std::max<long long>(0, std::min<long long>(remain, 5)));

        fd_set r;
        FD_ZERO(&r);
        int maxfd = -1;
        if (conn_ != kNoSock) {
            FD_SET(raw(conn_), &r);
            maxfd = static_cast<int>(raw(conn_));
        } else if (role_ == Role::Host) {
            FD_SET(raw(listen_), &r);
            maxfd = static_cast<int>(raw(listen_));
        }
        if (maxfd < 0) {  // Join, waiting to (re)connect: service() polls the attempt
            if (slice > 0) std::this_thread::sleep_for(std::chrono::milliseconds(slice));
        } else {
            timeval tv{};
            tv.tv_usec = slice * 1000;
            const int ready = select(maxfd + 1, &r, nullptr, nullptr, &tv);
            if (ready > 0 && conn_ != kNoSock && FD_ISSET(raw(conn_), &r)) read_some();
        }
        if (extract_frame(buf, cap, n)) return n;
        if (Clock::now() >= deadline) return 0;
    }
}

}  // namespace re7mp
