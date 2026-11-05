#include "engine.hpp"

#include <chrono>
#include <cmath>
#include <ctime>
#include <random>

#include "bridge.hpp"
#include "packet.hpp"

namespace re7mp {

namespace {
constexpr float kOrbitRadius = 3.0f;  // metres: the loopback Player 2 circles you at this distance
constexpr float kOrbitSpeed = 0.8f;   // radians per second
constexpr const char* kLoopbackName = "Loopback Bot";
constexpr int kBotReadyDelayMs = 1500;  // how long the loopback bot takes to "press ready" after you
using Clock = std::chrono::steady_clock;
using std::chrono::milliseconds;
using std::chrono::seconds;

const char* difficulty_name(uint8_t d) {
    switch (d) {
        case 0: return "Easy";
        case 1: return "Normal";
        case 2: return "Madhouse";
        default: return "unknown difficulty";
    }
}

struct PendingEvent {
    bool active = false;
    uint32_t id = 0;
    uint8_t type = 0, arg = 0;
    Clock::time_point first, last;
};
}  // namespace

Engine::~Engine() { stop(); }

void Engine::set_name(const std::string& name) {
    const std::string clean = sanitize_name(name);
    std::lock_guard<std::mutex> g(mu_);
    name_ = clean;
    name_dirty_ = true;
}

bool Engine::start(const Config& cfg, std::string& err) {
    stop();
    cfg_ = cfg;

    std::error_code ec;
    std::filesystem::create_directories(cfg_.data_dir, ec);
    if (ec) {
        err = "could not create " + cfg_.data_dir.string() + ": " + ec.message();
        return false;
    }

    if (cfg_.mode == Mode::Loopback) {
        if (cfg_.listen_port == 0 || cfg_.listen_port >= 65535) {
            err = "port must be between 1 and 65534";
            return false;
        }
        const auto fake_port = static_cast<uint16_t>(cfg_.listen_port + 1);
        net_ = UdpTransport::create(cfg_.listen_port, "127.0.0.1", fake_port, err);
        if (!net_) return false;
        fake_ = UdpTransport::create(fake_port, "127.0.0.1", cfg_.listen_port, err);
        if (!fake_) {
            net_.reset();
            return false;
        }
    } else {
        if (cfg_.peer_host.empty()) {
            err = "enter the other player's address (ip:port)";
            return false;
        }
        net_ = UdpTransport::create(cfg_.listen_port, cfg_.peer_host, cfg_.peer_port, err);
        if (!net_) return false;
    }

    FileBridge(cfg_.data_dir).clear_stale();
    {
        std::lock_guard<std::mutex> g(mu_);
        status_ = Status{};
        status_.running = true;
        log_.clear();
        name_ = sanitize_name(cfg_.name);
        name_dirty_ = true;
    }
    stop_ = false;
    running_ = true;
    thread_ = std::thread(&Engine::run, this);
    return true;
}

void Engine::stop() {
    stop_ = true;
    if (thread_.joinable()) thread_.join();
    running_ = false;
    net_.reset();
    fake_.reset();
    std::lock_guard<std::mutex> g(mu_);
    status_.running = false;
}

Status Engine::status() const {
    std::lock_guard<std::mutex> g(mu_);
    return status_;
}

std::vector<std::string> Engine::drain_log() {
    std::lock_guard<std::mutex> g(mu_);
    std::vector<std::string> out;
    out.swap(log_);
    return out;
}

void Engine::log(const std::string& msg) {
    std::time_t tt = std::time(nullptr);
    std::tm tmv{};
#ifdef _WIN32
    localtime_s(&tmv, &tt);
#else
    localtime_r(&tt, &tmv);
#endif
    char ts[16];
    std::strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
    std::lock_guard<std::mutex> g(mu_);
    if (log_.size() > 500) log_.erase(log_.begin(), log_.begin() + 250);
    log_.push_back(std::string(ts) + "  " + msg);
}

void Engine::run() {
    FileBridge bridge(cfg_.data_dir);
    std::random_device rd;
    const uint32_t session = rd();
    const uint32_t fake_session = rd();
    uint32_t send_seq = 0, fake_seq = 0, event_seq = 0;

    Status st;
    st.running = true;

    bool have_remote_pkt = false;
    uint32_t remote_session = 0, remote_seq = 0;
    bool have_event = false;
    uint32_t event_session = 0, event_id = 0;
    PendingEvent pending;
    bool hooked = false, peer_active = false;
    uint16_t local_flags = 0, remote_flags = 0;
    // loopback bot's ready-check state
    bool bot_seen_ready = false, bot_ready = false, bot_go = false;
    Clock::time_point bot_ready_since{};
    Clock::time_point last_local{}, last_remote{}, last_name_sent{}, fake_last_name{};
    const auto t0 = Clock::now();

    if (cfg_.mode == Mode::Loopback) {
        log("Started in loopback mode: a fake Player 2 will orbit you once the game is running.");
    } else {
        log("Started: listening on UDP " + std::to_string(cfg_.listen_port) + ", peer " + cfg_.peer_host + ":" +
            std::to_string(cfg_.peer_port));
    }

    while (!stop_) {
        const auto now = Clock::now();

        // 1. Pose from the Lua script -> peer.
        LocalPose lp;
        if (bridge.poll_pose(lp)) {
            st.have_local = true;
            st.lx = lp.x;
            st.ly = lp.y;
            st.lz = lp.z;
            last_local = now;
            const auto pkt =
                make_position(session, ++send_seq, lp.x, lp.y, lp.z, lp.qx, lp.qy, lp.qz, lp.qw, lp.flags);
            if (net_->send(&pkt, sizeof(pkt))) ++st.sent;
            if ((lp.flags ^ local_flags) & (kFlagReady | kFlagGo | kFlagDiffMask)) {
                if ((lp.flags & kFlagGo) && !(local_flags & kFlagGo)) {
                    log("Both players are ready: going.");
                } else if ((lp.flags & kFlagReady) && !(local_flags & kFlagReady)) {
                    log(std::string("You are ready to start a new game (") + difficulty_name(flag_difficulty(lp.flags)) +
                        ").");
                } else if (!(lp.flags & kFlagReady) && (local_flags & kFlagReady)) {
                    log("You are no longer ready.");
                }
            }
            local_flags = lp.flags;
        }

        // 1b. Event from the Lua script (e.g. "I started a new game on Madhouse") -> peer, resent until acked.
        LocalEvent le;
        if (bridge.poll_event(le)) {
            pending.active = true;
            pending.id = ++event_seq;
            pending.type = le.type;
            pending.arg = le.arg;
            pending.first = pending.last = now;
            const auto ep = make_event(session, pending.id, static_cast<EventType>(pending.type), pending.arg);
            net_->send(&ep, sizeof(ep));
            if (le.type == static_cast<uint8_t>(EventType::NewGame)) {
                log(std::string("Sent new-game request (") + difficulty_name(le.arg) + ") to the other player.");
            } else {
                log("Sent event " + std::to_string(le.type) + " to the other player.");
            }
        }
        if (pending.active) {
            if (now - pending.first > seconds(10)) {
                pending.active = false;
                log("The other player never confirmed that request (is their game running re7mp?).");
            } else if (now - pending.last >= milliseconds(250)) {
                pending.last = now;
                const auto ep = make_event(session, pending.id, static_cast<EventType>(pending.type), pending.arg);
                net_->send(&ep, sizeof(ep));
            }
        }

        // 1c. Our name, repeated because UDP can drop it. Faster until we've heard theirs.
        const auto name_every = st.remote_name.empty() ? milliseconds(250) : milliseconds(2000);
        if (name_dirty_.exchange(false) || now - last_name_sent >= name_every) {
            last_name_sent = now;
            std::string nm;
            {
                std::lock_guard<std::mutex> g(mu_);
                nm = name_;
            }
            if (!nm.empty()) {
                const auto np = make_name(session, nm);
                net_->send(&np, sizeof(np));
            }
        }

        uint8_t buf[512];

        // 2. Loopback only: the fake Player 2 answers with a pose orbiting yours, facing you.
        if (fake_) {
            const float t = std::chrono::duration<float>(now - t0).count();
            if (now - fake_last_name >= seconds(2)) {
                fake_last_name = now;
                const auto np = make_name(fake_session, kLoopbackName);
                fake_->send(&np, sizeof(np));
            }
            for (int i = 0; i < 16; ++i) {
                const int n = fake_->recv(buf, sizeof(buf), 0);
                if (n <= 0) break;
                PositionPacket in;
                EventPacket ev;
                if (decode_position(buf, static_cast<size_t>(n), in)) {
                    const float ox = kOrbitRadius * std::cos(kOrbitSpeed * t);
                    const float oz = kOrbitRadius * std::sin(kOrbitSpeed * t);

                    // The bot "presses ready" a moment after you do, copies your difficulty, and goes once
                    // you can see it is ready. Lets the whole ready check be tested alone.
                    const bool you_ready = (in.flags & kFlagReady) != 0;
                    if (you_ready && !bot_seen_ready) bot_ready_since = now;
                    bot_seen_ready = you_ready;
                    bot_ready = you_ready && (now - bot_ready_since) >= milliseconds(kBotReadyDelayMs);
                    if (!you_ready) bot_go = false;
                    if (bot_ready && (in.flags & kFlagSeesReady)) bot_go = true;
                    uint16_t bflags = 0;
                    if (bot_ready) bflags |= static_cast<uint16_t>(kFlagReady | (in.flags & kFlagDiffMask));
                    if (you_ready) bflags |= kFlagSeesReady;
                    if (bot_go) bflags |= kFlagGo;

                    // It copies YOUR rotation. That avoids guessing the game's axis conventions: its
                    // look-line should point the same way you are looking.
                    const auto out = make_position(fake_session, ++fake_seq, in.x + ox, in.y, in.z + oz, in.qx, in.qy,
                                                   in.qz, in.qw, bflags);
                    fake_->send(&out, sizeof(out));
                } else if (decode_event(buf, static_cast<size_t>(n), ev)) {
                    const auto ack = make_ack(fake_session, ev.id);
                    fake_->send(&ack, sizeof(ack));
                }
            }
        }

        // 3. Peer -> pose/name/events for the Lua script.
        const int n = net_->recv(buf, sizeof(buf), 3);
        if (n < 0) {
            log("Network error while receiving; stopping.");
            break;
        }
        if (n > 0) {
            const auto len = static_cast<size_t>(n);
            PositionPacket pos;
            EventPacket ev;
            AckPacket ack;
            std::string nm;
            switch (peek_type(buf, len)) {
                case static_cast<int>(PacketType::Position):
                    if (decode_position(buf, len, pos)) {
                        const bool newer = !have_remote_pkt || pos.h.session != remote_session ||
                                           static_cast<int32_t>(pos.seq - remote_seq) > 0;
                        if (newer) {
                            have_remote_pkt = true;
                            remote_session = pos.h.session;
                            remote_seq = pos.seq;
                            ++st.received;
                            st.have_remote = true;
                            st.rx = pos.x;
                            st.ry = pos.y;
                            st.rz = pos.z;
                            last_remote = Clock::now();
                            RemotePose rp;
                            rp.seq = pos.seq;
                            rp.x = pos.x; rp.y = pos.y; rp.z = pos.z;
                            rp.qx = pos.qx; rp.qy = pos.qy; rp.qz = pos.qz; rp.qw = pos.qw;
                            rp.flags = pos.flags;
                            if ((pos.flags ^ remote_flags) & (kFlagReady | kFlagDiffMask)) {
                                const std::string who = st.remote_name.empty() ? "The other player" : st.remote_name;
                                if (pos.flags & kFlagReady) {
                                    log(who + " is ready to start a new game (" +
                                        difficulty_name(flag_difficulty(pos.flags)) + ").");
                                } else if (remote_flags & kFlagReady) {
                                    log(who + " is no longer ready.");
                                }
                            }
                            remote_flags = pos.flags;
                            bridge.publish_remote(rp, st.received, st.remote_name);
                        }
                    }
                    break;
                case static_cast<int>(PacketType::Name):
                    if (decode_name(buf, len, nm) && nm != st.remote_name) {
                        st.remote_name = nm;
                        name_dirty_ = true;  // they probably haven't heard ours yet: answer right away
                        log("The other player is called \"" + nm + "\".");
                    }
                    break;
                case static_cast<int>(PacketType::Event):
                    if (decode_event(buf, len, ev)) {
                        const auto reply = make_ack(session, ev.id);  // always ack, even duplicates
                        net_->send(&reply, sizeof(reply));
                        const bool fresh = !have_event || ev.h.session != event_session ||
                                           static_cast<int32_t>(ev.id - event_id) > 0;
                        if (fresh) {
                            have_event = true;
                            event_session = ev.h.session;
                            event_id = ev.id;
                            bridge.publish_event(ev.h.session, ev.id, ev.type, ev.arg);
                            const std::string who = st.remote_name.empty() ? "The other player" : st.remote_name;
                            if (ev.type == static_cast<uint8_t>(EventType::NewGame)) {
                                log(who + " started a new game (" + difficulty_name(ev.arg) + ").");
                            } else {
                                log("Received event " + std::to_string(ev.type) + " from " + who + ".");
                            }
                        }
                    }
                    break;
                case static_cast<int>(PacketType::EventAck):
                    if (decode_ack(buf, len, ack) && pending.active && ack.id == pending.id) {
                        pending.active = false;
                        log("The other player received the request.");
                    }
                    break;
                default: break;  // not ours, or a different protocol version
            }
        }

        // 4. Connection state, with a log line whenever it changes.
        const auto t = Clock::now();
        const bool now_hooked = st.have_local && (t - last_local) < milliseconds(1500);
        const bool now_peer = st.have_remote && (t - last_remote) < seconds(3);
        if (now_hooked != hooked) {
            hooked = now_hooked;
            log(hooked ? "Game hooked: the Lua script is sending positions."
                       : "Game stopped sending positions (menu, loading screen, or the game closed).");
        }
        if (now_peer != peer_active) {
            peer_active = now_peer;
            log(peer_active ? "Peer connected: receiving positions." : "Peer went quiet.");
        }
        st.game_hooked = hooked;
        st.peer_active = peer_active;
        {
            std::lock_guard<std::mutex> g(mu_);
            status_ = st;
        }
    }

    st.running = false;
    st.game_hooked = false;
    st.peer_active = false;
    {
        std::lock_guard<std::mutex> g(mu_);
        status_ = st;
    }
    running_ = false;
}

}  // namespace re7mp
