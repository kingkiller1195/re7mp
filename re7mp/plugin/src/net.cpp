#include "net.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <mutex>
#include <random>
#include <thread>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
using sock_t = SOCKET;
using sock_len_t = int;
static constexpr sock_t kBadSock = INVALID_SOCKET;
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
static void sock_close(sock_t s) { closesocket(s); }
static bool sock_would_block() { return WSAGetLastError() == WSAEWOULDBLOCK; }
static bool sock_is_connreset() { return WSAGetLastError() == WSAECONNRESET; }
static bool sock_set_nonblock(sock_t s) {
    u_long m = 1;
    return ioctlsocket(s, FIONBIO, &m) == 0;
}
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
using sock_t = int;
using sock_len_t = socklen_t;
static constexpr sock_t kBadSock = -1;
static void sock_close(sock_t s) { ::close(s); }
static bool sock_would_block() { return errno == EWOULDBLOCK || errno == EAGAIN; }
static bool sock_is_connreset() { return errno == ECONNREFUSED || errno == ECONNRESET; }
static bool sock_set_nonblock(sock_t s) {
    int f = fcntl(s, F_GETFL, 0);
    return f >= 0 && fcntl(s, F_SETFL, f | O_NONBLOCK) == 0;
}
#endif

namespace mp {
namespace {

// ---- wire format ---------------------------------------------------------
// Every packet: magic u16 | protocol u8 | type u8 | body...   (little endian)
constexpr uint16_t kMagic = 0x3752;  // 'R7'
constexpr uint8_t kProto = 1;

enum Type : uint8_t {
    T_HELLO = 1,    // client->host: flags u8, nameLen u8, name
    T_WELCOME = 2,  // host->client: yourId u8, maxPlayers u8, hostFlags u8, nameLen u8, name
    T_DENY = 3,     // host->client: reason u8 (1 = full, 2 = version mismatch)
    T_POSE = 4,     // playerId u8, seq u16, flags u8, 21 x f32
    T_REL = 5,      // seq u16, kind u8, from u8, len u16, data
    T_ACK = 6,      // cumulative: highest in-order reliable seq received, u16
    T_PING = 7,     // stamp u32
    T_PONG = 8,     // stamp u32
    T_BYE = 9,
};

enum RelKind : uint8_t {
    R_JOIN = 1,   // from = player id, data = flags u8 + name
    R_LEAVE = 2,  // from = player id
    R_CHAT = 3,   // from = player id, data = utf8 text
    R_USER = 4,   // from = player id, data = userKind u8 + payload
};

constexpr int kPoseIntervalMs = 33;
constexpr int kPingIntervalMs = 1000;
constexpr int kResendIntervalMs = 200;
constexpr int kTimeoutMs = 8000;
constexpr int kConnectTimeoutMs = 10000;
constexpr int kHelloIntervalMs = 250;
constexpr size_t kMaxPending = 64;
constexpr size_t kMaxNameBytes = 24;

int64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

struct W {
    std::vector<uint8_t> b;
    void u8(uint8_t v) { b.push_back(v); }
    void u16(uint16_t v) { u8(v & 0xff); u8(v >> 8); }
    void u32(uint32_t v) { u16(v & 0xffff); u16(v >> 16); }
    void f32(float f) { uint32_t u; std::memcpy(&u, &f, 4); u32(u); }
    void bytes(const void* p, size_t n) {
        auto* c = static_cast<const uint8_t*>(p);
        b.insert(b.end(), c, c + n);
    }
};

struct R {
    const uint8_t* p;
    size_t n;
    size_t i = 0;
    bool ok = true;
    bool need(size_t k) {
        if (i + k > n) { ok = false; return false; }
        return true;
    }
    uint8_t u8() { return need(1) ? p[i++] : 0; }
    uint16_t u16() { uint16_t lo = u8(); uint16_t hi = u8(); return lo | (hi << 8); }
    uint32_t u32() { uint32_t lo = u16(); uint32_t hi = u16(); return lo | (hi << 16); }
    float f32() { uint32_t u = u32(); float f; std::memcpy(&f, &u, 4); return f; }
    std::string str(size_t k) {
        if (!need(k)) return {};
        std::string s(reinterpret_cast<const char*>(p + i), k);
        i += k;
        return s;
    }
    std::string rest() { return str(n - i); }
};

// a is "newer than" b in wrap-around u16 space
bool seq_newer(uint16_t a, uint16_t b) { return static_cast<int16_t>(a - b) > 0; }
bool seq_le(uint16_t a, uint16_t b) { return static_cast<int16_t>(a - b) <= 0; }

std::string sanitize_name(std::string s) {
    std::string out;
    for (unsigned char c : s) {
        if (c >= 32 && c != 127) out.push_back(static_cast<char>(c));
        if (out.size() >= kMaxNameBytes) break;
    }
    if (out.empty()) out = "Player";
    return out;
}

bool same_addr(const sockaddr_in& a, const sockaddr_in& b) {
    return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port;
}

struct Pending {
    uint16_t seq;
    std::vector<uint8_t> packet;
    int64_t last_sent;
};

struct Peer {
    sockaddr_in addr{};
    uint8_t id = 0;
    std::string name;
    uint8_t flags = 0;
    int64_t last_rx = 0;
    uint16_t next_seq = 1;
    std::deque<Pending> pending;
    uint16_t expected_seq = 1;
};

}  // namespace

// ---- Session::Impl -------------------------------------------------------
struct Session::Impl {
    mutable std::mutex mu;
    std::thread th;
    std::atomic<bool> quit{false};

    State state = State::Idle;
    bool is_host = false;
    sock_t sock = kBadSock;
    bool wsa_started = false;

    uint8_t local_id = 0;
    uint8_t max_players = 4;
    std::string local_name = "Player";
    bool local_vr = false;
    float rtt = 0.f;

    std::vector<std::unique_ptr<Peer>> peers;  // host: all clients. client: [0] = server
    std::array<uint16_t, 256> last_pose_seq{};
    std::array<bool, 256> have_pose_seq{};

    bool have_pose = false;
    uint8_t pose_flags = 0;
    std::array<float, kPoseFloats> pose{};
    uint16_t pose_seq = 0;

    std::deque<Event> inbox;
    std::vector<uint8_t> rxbuf = std::vector<uint8_t>(2048);

    int64_t connect_start = 0, last_hello = 0, last_ping = 0, last_pose_send = 0;
    int loss_pct = 0;
    std::mt19937 rng{std::random_device{}()};
    bool fatal = false;

    // ---- plumbing ----
    bool open_socket(uint16_t bind_port, std::string& err) {
#ifdef _WIN32
        WSADATA d;
        if (WSAStartup(MAKEWORD(2, 2), &d) != 0) { err = "WSAStartup failed"; return false; }
        wsa_started = true;
#endif
        sock = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock == kBadSock) { err = "socket() failed"; close_socket(); return false; }
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        a.sin_port = htons(bind_port);
        if (::bind(sock, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
            err = "bind() failed - is the port already in use?";
            close_socket();
            return false;
        }
        if (!sock_set_nonblock(sock)) { err = "could not set non-blocking"; close_socket(); return false; }
#ifdef _WIN32
        // Without this, an ICMP "port unreachable" makes recvfrom() fail with WSAECONNRESET.
        DWORD ret = 0;
        BOOL off = FALSE;
        WSAIoctl(sock, SIO_UDP_CONNRESET, &off, sizeof(off), nullptr, 0, &ret, nullptr, nullptr);
#endif
        return true;
    }

    void close_socket() {
        if (sock != kBadSock) { sock_close(sock); sock = kBadSock; }
#ifdef _WIN32
        if (wsa_started) { WSACleanup(); wsa_started = false; }
#endif
    }

    void reset_session_state() {
        peers.clear();
        have_pose = false;
        pose_seq = 0;
        have_pose_seq.fill(false);
        last_pose_seq.fill(0);
        rtt = 0.f;
        fatal = false;
    }

    void send_raw(const sockaddr_in& to, const void* p, size_t n) {
        if (sock == kBadSock) return;
        ::sendto(sock, static_cast<const char*>(p), static_cast<int>(n), 0,
                 reinterpret_cast<const sockaddr*>(&to), sizeof(to));
    }
    void send_vec(const sockaddr_in& to, const std::vector<uint8_t>& v) { send_raw(to, v.data(), v.size()); }

    static W header(Type t) {
        W w;
        w.u16(kMagic);
        w.u8(kProto);
        w.u8(t);
        return w;
    }

    void push_event(Event e) {
        if (e.type == EventType::Pose) {
            for (auto& old : inbox) {
                if (old.type == EventType::Pose && old.id == e.id) { old = std::move(e); return; }
            }
        }
        if (inbox.size() > 2048) inbox.pop_front();
        inbox.push_back(std::move(e));
    }

    Peer* find_peer(const sockaddr_in& a) {
        for (auto& p : peers) if (same_addr(p->addr, a)) return p.get();
        return nullptr;
    }

    // ---- reliable channel ----
    void send_rel(Peer& p, uint8_t kind, uint8_t from, const std::string& data) {
        if (p.pending.size() >= kMaxPending) return;  // peer is not acking; drop rather than grow forever
        W w = header(T_REL);
        uint16_t seq = p.next_seq++;
        if (p.next_seq == 0) p.next_seq = 1;  // keep 0 reserved for "nothing acked yet"
        w.u16(seq);
        w.u8(kind);
        w.u8(from);
        w.u16(static_cast<uint16_t>(data.size()));
        w.bytes(data.data(), data.size());
        p.pending.push_back({seq, w.b, now_ms()});
        send_vec(p.addr, w.b);
    }

    void send_ack(Peer& p) {
        W w = header(T_ACK);
        uint16_t last = static_cast<uint16_t>(p.expected_seq - 1);
        w.u16(last);
        send_vec(p.addr, w.b);
    }

    void on_ack(Peer& p, R& r) {
        uint16_t ack = r.u16();
        if (!r.ok) return;
        while (!p.pending.empty() && seq_le(p.pending.front().seq, ack)) p.pending.pop_front();
    }

    void on_rel(Peer& p, R& r) {
        uint16_t seq = r.u16();
        uint8_t kind = r.u8();
        uint8_t from = r.u8();
        uint16_t len = r.u16();
        std::string data = r.str(len);
        if (!r.ok) return;
        if (seq == p.expected_seq) {
            p.expected_seq++;
            if (p.expected_seq == 0) p.expected_seq = 1;
            deliver(p, kind, from, data);
        }
        send_ack(p);  // duplicates and gaps just re-ack the last in-order packet
    }

    void deliver(Peer& src, uint8_t kind, uint8_t from, const std::string& data) {
        if (is_host) {
            // Clients may only send chat/user events; `from` is whatever they claim, so use their real id.
            if (kind != R_CHAT && kind != R_USER) return;
            if (kind == R_CHAT && data.size() > kMaxChatBytes) return;
            if (kind == R_USER && (data.empty() || data.size() > kMaxUserBytes + 1)) return;
            emit_text_event(kind, src.id, data);
            for (auto& q : peers) if (q.get() != &src) send_rel(*q, kind, src.id, data);
            return;
        }
        switch (kind) {
            case R_JOIN: {
                have_pose_seq[from] = false;  // id may be reused by a new player
                Event e;
                e.type = EventType::Joined;
                e.id = from;
                e.flags = data.empty() ? 0 : static_cast<uint8_t>(data[0]);
                e.text = data.size() > 1 ? data.substr(1) : std::string();
                push_event(std::move(e));
                break;
            }
            case R_LEAVE: {
                have_pose_seq[from] = false;
                Event e;
                e.type = EventType::Left;
                e.id = from;
                push_event(std::move(e));
                break;
            }
            case R_CHAT:
            case R_USER:
                emit_text_event(kind, from, data);
                break;
            default: break;
        }
    }

    void emit_text_event(uint8_t kind, uint8_t from, const std::string& data) {
        Event e;
        e.id = from;
        if (kind == R_CHAT) {
            e.type = EventType::Chat;
            e.text = data;
        } else {
            e.type = EventType::User;
            if (data.empty()) return;
            e.kind = static_cast<uint8_t>(data[0]);
            e.text = data.substr(1);
        }
        push_event(std::move(e));
    }

    // ---- host side ----
    void host_broadcast_rel(uint8_t kind, uint8_t from, const std::string& data, const Peer* except) {
        for (auto& q : peers) if (q.get() != except) send_rel(*q, kind, from, data);
    }

    std::string join_blob(uint8_t flags, const std::string& name) {
        std::string s;
        s.push_back(static_cast<char>(flags));
        s += name;
        return s;
    }

    void send_welcome(Peer& p) {
        W w = header(T_WELCOME);
        w.u8(p.id);
        w.u8(max_players);
        w.u8(local_vr ? 1 : 0);
        w.u8(static_cast<uint8_t>(local_name.size()));
        w.bytes(local_name.data(), local_name.size());
        send_vec(p.addr, w.b);
    }

    void send_deny(const sockaddr_in& to, uint8_t reason) {
        W w = header(T_DENY);
        w.u8(reason);
        send_vec(to, w.b);
    }

    void host_on_hello(R& r, const sockaddr_in& from, Peer* existing, int64_t t) {
        uint8_t flags = r.u8();
        uint8_t nlen = r.u8();
        std::string name = r.str(nlen);
        if (!r.ok) return;
        if (existing) {  // HELLO retransmit: our WELCOME was probably lost
            existing->last_rx = t;
            send_welcome(*existing);
            return;
        }
        if (peers.size() + 1 >= max_players) { send_deny(from, 1); return; }

        std::array<bool, 256> used{};
        used[0] = true;
        for (auto& p : peers) used[p->id] = true;
        uint8_t id = 1;
        while (id < max_players && used[id]) id++;
        if (id >= max_players) { send_deny(from, 1); return; }

        auto np = std::make_unique<Peer>();
        np->addr = from;
        np->id = id;
        np->name = sanitize_name(name);
        np->flags = flags & kPoseVR;
        np->last_rx = t;
        Peer& ref = *np;
        peers.push_back(std::move(np));
        have_pose_seq[id] = false;

        send_welcome(ref);

        Event e;
        e.type = EventType::Joined;
        e.id = id;
        e.flags = ref.flags;
        e.text = ref.name;
        push_event(std::move(e));

        // Roster for the newcomer: host first, then everyone already here.
        send_rel(ref, R_JOIN, 0, join_blob(local_vr ? 1 : 0, local_name));
        for (auto& q : peers) {
            if (q.get() == &ref) continue;
            send_rel(ref, R_JOIN, q->id, join_blob(q->flags, q->name));
        }
        // Tell everyone else about the newcomer.
        host_broadcast_rel(R_JOIN, id, join_blob(ref.flags, ref.name), &ref);
    }

    void host_remove_peer(Peer* target) {
        uint8_t id = target->id;
        auto it = std::find_if(peers.begin(), peers.end(), [&](auto& p) { return p.get() == target; });
        if (it == peers.end()) return;
        peers.erase(it);
        have_pose_seq[id] = false;
        Event e;
        e.type = EventType::Left;
        e.id = id;
        push_event(std::move(e));
        host_broadcast_rel(R_LEAVE, id, "", nullptr);
    }

    // ---- poses (both roles) ----
    // Returns true if a valid, fresh pose was parsed into `out`.
    bool parse_pose(R& r, Event& out, uint8_t& pid) {
        pid = r.u8();
        uint16_t seq = r.u16();
        uint8_t fl = r.u8();
        for (int i = 0; i < kPoseFloats; i++) {
            float f = r.f32();
            if (!std::isfinite(f)) return false;
            out.pose[i] = f;
        }
        if (!r.ok) return false;
        if (have_pose_seq[pid] && !seq_newer(seq, last_pose_seq[pid])) return false;  // old / duplicate
        have_pose_seq[pid] = true;
        last_pose_seq[pid] = seq;
        out.type = EventType::Pose;
        out.id = pid;
        out.flags = fl;
        return true;
    }

    void send_pose_packet(const sockaddr_in& to, uint8_t pid, uint16_t seq) {
        W w = header(T_POSE);
        w.u8(pid);
        w.u16(seq);
        w.u8(pose_flags);
        for (float f : pose) w.f32(f);
        send_vec(to, w.b);
    }

    // ---- packet dispatch ----
    void handle_packet(const uint8_t* data, size_t n, const sockaddr_in& from) {
        R r{data, n};
        uint16_t magic = r.u16();
        uint8_t ver = r.u8();
        uint8_t type = r.u8();
        if (!r.ok || magic != kMagic) return;
        int64_t t = now_ms();

        if (ver != kProto) {
            if (is_host && type == T_HELLO) send_deny(from, 2);
            return;
        }

        if (is_host) {
            Peer* p = find_peer(from);
            if (type == T_HELLO) { host_on_hello(r, from, p, t); return; }
            if (!p) return;
            p->last_rx = t;
            switch (type) {
                case T_POSE: {
                    Event e;
                    uint8_t pid;
                    if (!parse_pose(r, e, pid) || pid != p->id) return;
                    for (auto& q : peers) if (q.get() != p) send_raw(q->addr, data, n);  // relay verbatim
                    push_event(std::move(e));
                    break;
                }
                case T_REL: on_rel(*p, r); break;
                case T_ACK: on_ack(*p, r); break;
                case T_PING: { W w = header(T_PONG); w.u32(r.u32()); if (r.ok) send_vec(p->addr, w.b); break; }
                case T_PONG: break;
                case T_BYE: host_remove_peer(p); break;
                default: break;
            }
            return;
        }

        // client
        if (peers.empty() || !same_addr(peers[0]->addr, from)) return;
        Peer& srv = *peers[0];
        srv.last_rx = t;
        switch (type) {
            case T_WELCOME: {
                if (state != State::Connecting) return;
                uint8_t id = r.u8();
                uint8_t maxp = r.u8();
                uint8_t hflags = r.u8();
                uint8_t nlen = r.u8();
                std::string hname = r.str(nlen);
                if (!r.ok) return;
                (void)hflags;
                local_id = id;
                max_players = maxp;
                state = State::Connected;
                last_ping = t;
                Event e;
                e.type = EventType::Connected;
                e.id = id;
                e.text = sanitize_name(hname);
                push_event(std::move(e));
                break;
            }
            case T_DENY: {
                uint8_t reason = r.u8();
                Event e;
                e.type = EventType::Disconnected;
                e.text = reason == 1 ? "server is full" : reason == 2 ? "protocol version mismatch" : "denied";
                push_event(std::move(e));
                fatal = true;
                break;
            }
            case T_POSE: {
                if (state != State::Connected) return;
                Event e;
                uint8_t pid;
                if (!parse_pose(r, e, pid) || pid == local_id) return;
                push_event(std::move(e));
                break;
            }
            case T_REL: if (state == State::Connected) on_rel(srv, r); break;
            case T_ACK: on_ack(srv, r); break;
            case T_PING: { W w = header(T_PONG); w.u32(r.u32()); if (r.ok) send_vec(srv.addr, w.b); break; }
            case T_PONG: {
                uint32_t stamp = r.u32();
                if (r.ok) rtt = static_cast<float>(static_cast<uint32_t>(t) - stamp);
                break;
            }
            case T_BYE: {
                Event e;
                e.type = EventType::Disconnected;
                e.text = "host closed the session";
                push_event(std::move(e));
                fatal = true;
                break;
            }
            default: break;
        }
    }

    void recv_all() {
        for (int i = 0; i < 512; i++) {
            sockaddr_in from{};
            sock_len_t fl = sizeof(from);
            int n = static_cast<int>(::recvfrom(sock, reinterpret_cast<char*>(rxbuf.data()),
                                                static_cast<int>(rxbuf.size()), 0,
                                                reinterpret_cast<sockaddr*>(&from), &fl));
            if (n < 0) {
                if (sock_would_block()) break;
                if (sock_is_connreset()) continue;
                break;
            }
            if (loss_pct > 0 && static_cast<int>(rng() % 100) < loss_pct) continue;
            handle_packet(rxbuf.data(), static_cast<size_t>(n), from);
            if (fatal) return;
        }
    }

    void send_hello() {
        W w = header(T_HELLO);
        w.u8(local_vr ? 1 : 0);
        w.u8(static_cast<uint8_t>(local_name.size()));
        w.bytes(local_name.data(), local_name.size());
        send_vec(peers[0]->addr, w.b);
    }

    void tick(int64_t t) {
        if (!is_host && state == State::Connecting) {
            if (t - connect_start > kConnectTimeoutMs) {
                Event e;
                e.type = EventType::Disconnected;
                e.text = "connection timed out";
                push_event(std::move(e));
                fatal = true;
                return;
            }
            if (t - last_hello >= kHelloIntervalMs) { send_hello(); last_hello = t; }
            return;
        }

        // timeouts
        if (is_host) {
            std::vector<Peer*> dead;
            for (auto& p : peers) if (t - p->last_rx > kTimeoutMs) dead.push_back(p.get());
            for (Peer* p : dead) host_remove_peer(p);
        } else if (!peers.empty() && t - peers[0]->last_rx > kTimeoutMs) {
            Event e;
            e.type = EventType::Disconnected;
            e.text = "lost connection to host";
            push_event(std::move(e));
            fatal = true;
            return;
        }

        // reliable resend (go-back-N)
        for (auto& p : peers)
            for (auto& pd : p->pending)
                if (t - pd.last_sent >= kResendIntervalMs) { send_vec(p->addr, pd.packet); pd.last_sent = t; }

        // keep-alive / RTT
        if (t - last_ping >= kPingIntervalMs) {
            last_ping = t;
            for (auto& p : peers) {
                W w = header(T_PING);
                w.u32(static_cast<uint32_t>(t));
                send_vec(p->addr, w.b);
            }
        }

        // pose broadcast
        if (have_pose && t - last_pose_send >= kPoseIntervalMs) {
            last_pose_send = t;
            uint16_t seq = ++pose_seq;
            if (is_host) {
                for (auto& p : peers) send_pose_packet(p->addr, 0, seq);
            } else if (state == State::Connected && !peers.empty()) {
                send_pose_packet(peers[0]->addr, local_id, seq);
            }
        }
    }

    void run() {
        while (!quit.load()) {
            sock_t s;
            {
                std::lock_guard<std::mutex> lk(mu);
                s = sock;
            }
            if (s == kBadSock) break;
            fd_set rf;
            FD_ZERO(&rf);
            FD_SET(s, &rf);
            timeval tv{0, 4000};
            ::select(static_cast<int>(s) + 1, &rf, nullptr, nullptr, &tv);

            std::lock_guard<std::mutex> lk(mu);
            if (quit.load()) break;
            recv_all();
            if (!fatal) tick(now_ms());
            if (fatal) {
                // Leave `state` as Idle so the UI shows the session is over; stop() will tidy up the socket.
                state = State::Idle;
                break;
            }
        }
    }
};

// ---- Session ---------------------------------------------------------------
Session::Session() : impl_(std::make_unique<Impl>()) {}
Session::~Session() { stop(); }

bool Session::host(uint16_t port, uint8_t max_players, const std::string& name, std::string& err) {
    stop();
    Impl& s = *impl_;
    std::lock_guard<std::mutex> lk(s.mu);
    s.reset_session_state();
    s.is_host = true;
    s.local_id = 0;
    s.max_players = static_cast<uint8_t>(std::clamp<int>(max_players, 2, kMaxPlayersLimit));
    s.local_name = sanitize_name(name);
    if (!s.open_socket(port, err)) return false;
    s.state = State::Hosting;
    s.quit = false;
    s.last_ping = s.last_pose_send = now_ms();
    s.th = std::thread([&s] { s.run(); });
    return true;
}

bool Session::join(const std::string& ip, uint16_t port, const std::string& name, std::string& err) {
    stop();
    Impl& s = *impl_;
    std::lock_guard<std::mutex> lk(s.mu);
    s.reset_session_state();
    auto srv = std::make_unique<Peer>();
    srv->addr.sin_family = AF_INET;
    srv->addr.sin_port = htons(port);
    if (inet_pton(AF_INET, ip.c_str(), &srv->addr.sin_addr) != 1) {
        err = "invalid IPv4 address (hostnames are not resolved - use the numeric IP)";
        return false;
    }
    s.is_host = false;
    s.local_name = sanitize_name(name);
    if (!s.open_socket(0, err)) return false;
    srv->last_rx = now_ms();
    s.peers.push_back(std::move(srv));
    s.state = State::Connecting;
    s.quit = false;
    s.last_hello = 0;  // send the first HELLO immediately
    s.connect_start = now_ms();
    s.th = std::thread([&s] { s.run(); });
    return true;
}

void Session::stop() {
    Impl& s = *impl_;
    {
        std::lock_guard<std::mutex> lk(s.mu);
        if (s.sock != kBadSock) {
            W w = Impl::header(T_BYE);
            for (auto& p : s.peers) s.send_vec(p->addr, w.b);
        }
        s.quit = true;
    }
    if (s.th.joinable()) s.th.join();
    std::lock_guard<std::mutex> lk(s.mu);
    s.close_socket();
    s.peers.clear();
    s.state = State::Idle;
}

State Session::state() const {
    std::lock_guard<std::mutex> lk(impl_->mu);
    return impl_->state;
}
uint8_t Session::local_id() const {
    std::lock_guard<std::mutex> lk(impl_->mu);
    return impl_->local_id;
}
float Session::rtt_ms() const {
    std::lock_guard<std::mutex> lk(impl_->mu);
    return impl_->rtt;
}
void Session::set_vr(bool vr) {
    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->local_vr = vr;
}
void Session::set_local_pose(uint8_t flags, const std::array<float, kPoseFloats>& pose) {
    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->pose_flags = flags;
    impl_->pose = pose;
    impl_->have_pose = true;
}

bool Session::send_chat(const std::string& text) {
    if (text.empty() || text.size() > kMaxChatBytes) return false;
    std::lock_guard<std::mutex> lk(impl_->mu);
    Impl& s = *impl_;
    if (s.state != State::Hosting && s.state != State::Connected) return false;
    for (auto& p : s.peers) s.send_rel(*p, R_CHAT, s.local_id, text);
    return true;
}

bool Session::send_user(uint8_t kind, const std::string& payload) {
    if (payload.size() > kMaxUserBytes) return false;
    std::lock_guard<std::mutex> lk(impl_->mu);
    Impl& s = *impl_;
    if (s.state != State::Hosting && s.state != State::Connected) return false;
    std::string blob;
    blob.push_back(static_cast<char>(kind));
    blob += payload;
    for (auto& p : s.peers) s.send_rel(*p, R_USER, s.local_id, blob);
    return true;
}

std::vector<Event> Session::drain() {
    std::lock_guard<std::mutex> lk(impl_->mu);
    std::vector<Event> out(std::make_move_iterator(impl_->inbox.begin()),
                           std::make_move_iterator(impl_->inbox.end()));
    impl_->inbox.clear();
    return out;
}

void Session::set_debug_loss(int percent) {
    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->loss_pct = std::clamp(percent, 0, 90);
}

}  // namespace mp
