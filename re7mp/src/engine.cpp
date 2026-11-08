#include "engine.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <deque>
#include <random>
#include <set>

#include <fstream>
#include <memory>

#include "bot_logic.hpp"
#include "bridge.hpp"
#include "packet.hpp"
#include "save_sync.hpp"

namespace re7mp {

namespace {
constexpr float kOrbitRadius = 3.0f;  // metres: the loopback bot circles you at this distance
constexpr float kOrbitSpeed = 0.8f;   // radians per second
constexpr const char* kLoopbackName = "Loopback Bot";
constexpr int kBotReadyDelayMs = 1500;  // how long the loopback bot takes to "press ready" after you
constexpr size_t kMaxPendingMessages = 64;
constexpr size_t kInboxSize = 64;
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

struct PendingMessage {
    uint32_t id = 0;
    uint16_t kind = 0;
    std::string payload;
    Clock::time_point first, last;
};

std::string timestamp_now() {
    std::time_t tt = std::time(nullptr);
    std::tm tmv{};
#ifdef _WIN32
    localtime_s(&tmv, &tt);
#else
    localtime_r(&tt, &tmv);
#endif
    char b[32];
    std::strftime(b, sizeof(b), "%Y-%m-%d %H:%M", &tmv);
    return b;
}

struct OutFile {
    uint32_t id = 0;
    std::vector<uint8_t> data;
    uint32_t crc = 0;
    int slot = 0;
    std::string label;
    size_t offset = 0;
    bool begun = false;
    Clock::time_point started;
};

struct InFile {
    bool active = false;
    uint32_t id = 0, total = 0, crc = 0;
    int slot = 0;
    std::string label;
    std::vector<uint8_t> data;
};

bool read_whole_file(const std::filesystem::path& p, std::vector<uint8_t>& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

bool send_message_packet(ITransport& t, uint32_t session, uint32_t id, uint16_t kind, const std::string& payload) {
    uint8_t buf[sizeof(MessageFixed) + kMaxPayloadBytes];
    const size_t n = encode_message(buf, session, id, kind, payload);
    return n > 0 && t.send(buf, n);
}
}  // namespace

Engine::~Engine() { stop(); }

void Engine::set_name(const std::string& name) {
    const std::string clean = sanitize_name(name);
    std::lock_guard<std::mutex> g(mu_);
    name_ = clean;
    name_dirty_ = true;
}

void Engine::set_bot_mode(BotMode mode) {
    bot_mode_ = static_cast<int>(mode);
    if (mode == BotMode::Stationary) bot_teleport_ = true;
}

void Engine::teleport_bot_here() { bot_teleport_ = true; }

bool Engine::start(const Config& cfg, std::string& err) {
    stop();
    cfg_ = cfg;

    std::error_code ec;
    std::filesystem::create_directories(cfg_.data_dir, ec);
    if (ec) {
        err = "could not create " + cfg_.data_dir.u8string() + ": " + ec.message();
        return false;
    }

    if (cfg_.mode == Mode::Loopback) {
        if (cfg_.listen_port == 0 || cfg_.listen_port >= 65535) {
            err = "port must be between 1 and 65534";
            return false;
        }
        const auto fake_port = static_cast<uint16_t>(cfg_.listen_port + 1);
        {  // the bot hosts, we join, both over 127.0.0.1
            auto b = TcpTransport::create(TcpTransport::Role::Host, fake_port, "127.0.0.1", 0, err);
            if (!b) return false;
            auto a = TcpTransport::create(TcpTransport::Role::Join, 0, "127.0.0.1", fake_port, err);
            if (!a) return false;
            net_ = std::move(a);
            fake_ = std::move(b);
        }
    } else {
        if (cfg_.transport == Transport::TcpHost) {
            auto a = TcpTransport::create(TcpTransport::Role::Host, cfg_.listen_port, cfg_.peer_host, cfg_.peer_port, err);
            if (!a) return false;
            net_ = std::move(a);
        } else {
            if (cfg_.peer_host.empty()) {
                err = "enter the host's address (ip:port)";
                return false;
            }
            auto a = TcpTransport::create(TcpTransport::Role::Join, 0, cfg_.peer_host, cfg_.peer_port, err);
            if (!a) return false;
            net_ = std::move(a);
        }
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
    bot_mode_ = static_cast<int>(cfg_.bot_mode);
    bot_teleport_ = cfg_.bot_mode == BotMode::Stationary;
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
    uint32_t send_seq = 0, fake_seq = 0, event_seq = 0, msg_seq = 0, fake_msg_id = 0;
    uint32_t state_seq = 0, fake_state_seq = 0, remote_state_seq = 0, remote_state_session = 0;
    bool have_state_pkt = false;
    Clock::time_point fake_last_state{};
    bool bot_enemy_anchored = false;  // loopback: where the standing pretend enemy was put (8 m from where you first were)
    float bot_enx = 0, bot_eny = 0, bot_enz = 0;

    Status st;
    st.running = true;

    bool have_remote_pkt = false;
    uint32_t remote_session = 0, remote_seq = 0;
    bool have_event = false;
    uint32_t event_session = 0, event_id = 0;
    PendingEvent pending;
    std::deque<PendingMessage> pending_msgs;
    std::set<uint32_t> seen_msg_ids;
    std::deque<uint32_t> seen_msg_order;
    uint32_t seen_msg_session = 0;
    bool have_msg_session = false;
    std::deque<InMessage> inbox;
    uint64_t inbox_n = 0;
    bool inbox_dirty = false;
    bool hooked = false, peer_active = false;
    uint16_t local_flags = 0, remote_flags = 0;
    // loopback bot state
    bool bot_seen_ready = false, bot_ready = false, bot_go = false;
    bool bot_anchor_valid = false;
    float bot_ax = 0, bot_ay = 0, bot_az = 0;
    Clock::time_point bot_ready_since{};
    // (9.13) the bot can be told to go down: it stays where it fell, says so every second, and a heal within reach gets it up
    bool bot_down = false, bot_fall_valid = false;
    int bot_say = 0;  // 1 = tell the player it went down, 2 = tell it it got up
    float bot_fx = 0, bot_fy = 0, bot_fz = 0;
    Clock::time_point bot_health_at{};
    Clock::time_point last_local{}, last_remote{}, last_name_sent{}, fake_last_name{};
    const auto t0 = Clock::now();
    std::vector<uint8_t> bufv(20480);  // big enough for a file chunk

    // --- co-op save sharing state ---
    const char* role_name = cfg_.mode == Mode::Loopback || cfg_.transport == Transport::TcpHost ? "host" : "join";
    CoopManifest manifest(cfg_.data_dir / "re7mp_coop_saves.json");
    std::unique_ptr<SaveWatcher> watcher;
    bool save_sync_on = false;
    std::string last_save_event = "Save sharing is off.";
    std::unique_ptr<OutFile> out_file;
    std::deque<std::filesystem::path> save_queue;
    InFile in_file;
    uint32_t file_seq = 0;
    Clock::time_point last_save_poll{}, last_any{};
    std::deque<std::vector<uint8_t>> bot_frames;  // loopback bot: a received save being echoed back
    InFile bot_in;
    if (cfg_.save_sync) {
        std::error_code sec;
        if (cfg_.save_dir.empty() || !std::filesystem::is_directory(cfg_.save_dir, sec)) {
            last_save_event = "Save sharing is off: the save folder was not found.";
        } else {
            save_sync_on = true;
            manifest.load();
            watcher = std::make_unique<SaveWatcher>(cfg_.save_dir, cfg_.save_stable_ms);
            watcher->baseline();
            last_save_event = "Save sharing is on. Saves you make while connected are sent to the other player.";
            {   // which folder, and what is in it: with two Steam accounts the wrong one is easy to pick
                const auto slots = list_occupied(cfg_.save_dir);
                log("Watching " + cfg_.save_dir.u8string() + ": " + std::to_string(slots.size()) +
                    " manual save(s) (the Load screen's rows 1, 2, 3 ...). The Autosave is never shared.");
            }
        }
        log(last_save_event);
    }
    auto publish_saves = [&]() {
        manifest.save(last_save_event, save_sync_on,
                      save_sync_on ? list_occupied(cfg_.save_dir) : std::vector<int>{},
                      save_sync_on ? cfg_.save_dir.u8string() : std::string());
    };
    Clock::time_point last_prune = Clock::now();
    std::map<int, std::filesystem::file_time_type> verify_seen;  // file times of the received copies, to notice a rewrite
    if (save_sync_on && manifest.prune(cfg_.save_dir, true) > 0) log("Forgot co-op saves whose slot changed while this tool was closed.");
    publish_saves();
    st.last_save_event = last_save_event;

    log(std::string("re7mp.exe v") + kReleaseVersion + " (protocol " + std::to_string(static_cast<int>(kProtocolVersion)) + ")");
    if (cfg_.mode == Mode::Loopback) {
        log("Started in loopback mode over TCP: a fake player will appear once the game is running.");
    } else if (cfg_.transport == Transport::TcpHost) {
        log("Started: hosting on TCP " + std::to_string(cfg_.listen_port) + ", waiting for the other player.");
    } else {
        log("Started: connecting over TCP to " + cfg_.peer_host + ":" + std::to_string(cfg_.peer_port));
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

        // 1b. One-shot event from the Lua script -> peer, resent until acked.
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

        // 1c. Reliable messages (chat, pings, item events...) from the Lua script -> peer, resent until acked.
        std::vector<LocalMessage> lms;
        if (bridge.poll_messages(lms)) {
            for (auto& lm : lms) {
                if (pending_msgs.size() >= kMaxPendingMessages) {
                    log("Too many unconfirmed messages: dropping the oldest.");
                    pending_msgs.pop_front();
                }
                PendingMessage pm;
                pm.id = ++msg_seq;
                pm.kind = lm.kind;
                pm.payload = std::move(lm.payload);
                pm.first = pm.last = now;
                send_message_packet(*net_, session, pm.id, pm.kind, pm.payload);
                pending_msgs.push_back(std::move(pm));
                ++st.messages_sent;
            }
        }
        for (auto it = pending_msgs.begin(); it != pending_msgs.end();) {
            if (now - it->first > seconds(15)) {
                log("A message (kind " + std::to_string(it->kind) + ") was never confirmed by the other player.");
                it = pending_msgs.erase(it);
            } else {
                if (now - it->last >= milliseconds(250)) {
                    it->last = now;
                    send_message_packet(*net_, session, it->id, it->kind, it->payload);
                }
                ++it;
            }
        }

        // 1f. Enemy snapshot from the Lua script (the host's game writes it) -> peer. Latest wins, never resent.
        LocalState lst;
        if (bridge.poll_state(lst)) {
            const auto sp = encode_state(session, ++state_seq, lst.payload);
            if (!sp.empty() && net_->send(sp.data(), sp.size())) ++st.states_sent;
        }

        // 1e. Co-op saves: notice a finished save, send it in pieces, and pump a transfer already under way.
        const bool reachable = last_any != Clock::time_point{} && now - last_any < seconds(6);
        if (save_sync_on) {
            if (now - last_save_poll >= milliseconds(500)) {
                last_save_poll = now;
                for (auto& p : watcher->poll(now)) {
                    // Only saves made while connected are shared; single-player saves stay private.
                    if (reachable) {
                        if (std::find(save_queue.begin(), save_queue.end(), p) == save_queue.end()) save_queue.push_back(p);
                    } else if (manifest.remove_slot(parse_slot(p.filename().u8string()))) {
                        // A co-op slot saved over while nobody was connected is a single-player save now.
                        log("Slot " + p.filename().u8string() + " was saved over while disconnected: no longer marked CO-OP.");
                        publish_saves();
                    }
                }
                if (now - last_prune >= seconds(5)) {  // a save deleted in the game's own menu
                    last_prune = now;
                    bool changed = manifest.prune(cfg_.save_dir, false) > 0;
                    std::vector<int> dropped;  // a received copy somebody wrote over (the game, Steam Cloud, the player)
                    if (manifest.verify_received(cfg_.save_dir, verify_seen, dropped) > 0) {
                        for (int sl : dropped) {
                            last_save_event = "Slot " + std::to_string(sl) + " no longer holds the save that was received: something wrote the file again, so it is no longer marked CO-OP.";
                            log(last_save_event);
                        }
                        changed = true;
                    }
                    if (changed) publish_saves();
                }
            }
            if (!out_file && !save_queue.empty() && reachable) {
                const std::filesystem::path p = save_queue.front();
                save_queue.pop_front();
                std::vector<uint8_t> data;
                if (!read_whole_file(p, data) || data.empty() || data.size() > kMaxFileBytes) {
                    log("Could not read " + p.filename().u8string() + " to share it.");
                } else {
                    const uint32_t crc = crc32(data.data(), data.size());
                    if (!manifest.has_crc(crc)) {  // not one we installed ourselves
                        std::string nm;
                        {
                            std::lock_guard<std::mutex> g(mu_);
                            nm = name_;
                        }
                        out_file = std::make_unique<OutFile>();
                        out_file->id = ++file_seq;
                        out_file->crc = crc;
                        out_file->slot = parse_slot(p.filename().u8string());
                        out_file->label = "CO-OP " + (nm.empty() ? std::string("Player") : nm) + " " + timestamp_now();
                        out_file->data = std::move(data);
                        out_file->started = now;
                        log("Sending your save (" + p.filename().u8string() + ", " +
                            std::to_string(out_file->data.size() / 1024) + " KB) to the other player...");
                    }
                }
            }
            if (out_file) {
                OutFile& o = *out_file;
                if (!reachable) {  // the link dropped: start this transfer over once it is back
                    o.begun = false;
                    o.offset = 0;
                } else {
                    bool ok = true;
                    if (!o.begun) {
                        const auto b = encode_file_begin(session, o.id, static_cast<uint32_t>(o.data.size()), o.crc,
                                                         static_cast<uint16_t>(o.slot), o.label);
                        ok = net_->send(b.data(), b.size());
                        o.begun = ok;
                    }
                    while (ok && o.begun && o.offset < o.data.size()) {
                        const size_t n = std::min(kFileChunkBytes, o.data.size() - o.offset);
                        const auto c = encode_file_chunk(session, o.id, static_cast<uint32_t>(o.offset),
                                                         o.data.data() + o.offset, n);
                        if (net_->send(c.data(), c.size())) o.offset += n;
                        else ok = false;  // buffer full: carry on next loop
                    }
                    if (o.begun && o.offset >= o.data.size()) {
                        const auto e = make_file_end(session, o.id);
                        if (net_->send(&e, sizeof(e))) {
                            ++st.saves_sent;
                            {
                                CoopEntry se;  // our own save, now shared: remember who with
                                se.slot = o.slot;
                                se.label = o.label;
                                se.role = "sent";
                                se.partner = st.remote_name.empty() ? std::string("Player") : st.remote_name;
                                {
                                    std::lock_guard<std::mutex> g(mu_);
                                    se.from = name_;
                                }
                                se.when = timestamp_now();
                                se.crc = o.crc;
                                se.size = o.data.size();
                                manifest.upsert(se);
                            }
                            last_save_event = "Sent your save to the other player (" + o.label + ").";
                            log(last_save_event);
                            publish_saves();
                            out_file.reset();
                        }
                    }
                }
                if (out_file && now - out_file->started > seconds(180)) {
                    log("Gave up sending the save (the connection was too slow or down).");
                    out_file.reset();
                }
            }
        }

        // 1d. Our name, repeated in case the peer restarted. Faster until we've heard theirs.
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

        uint8_t* buf = bufv.data();
        const size_t kBuf = bufv.size();

        // 2. Loopback only: the fake player answers with a pose, plays the ready check, acks and echoes messages.
        if (fake_) {
            const float t = std::chrono::duration<float>(now - t0).count();
            if (now - fake_last_name >= seconds(2)) {
                fake_last_name = now;
                const auto np = make_name(fake_session, kLoopbackName);
                fake_->send(&np, sizeof(np));
            }
            std::string unused;
            while (fake_->take_status(unused)) {}
            const auto mode = static_cast<BotMode>(bot_mode_.load());
            for (int i = 0; i < 16; ++i) {
                const int n = fake_->recv(buf, kBuf, 0);
                if (n <= 0) break;
                PositionPacket in;
                EventPacket ev;
                uint32_t m_session = 0, m_id = 0;
                uint16_t m_kind = 0;
                std::string m_payload;
                if (decode_position(buf, static_cast<size_t>(n), in)) {
                    // Where the bot stands: circling you, or parked where you were when it was told to teleport.
                    if (bot_teleport_.exchange(false) || (mode == BotMode::Stationary && !bot_anchor_valid)) {
                        bot_ax = in.x;
                        bot_ay = in.y;
                        bot_az = in.z;
                        bot_anchor_valid = true;
                    }
                    float bx, by, bz;
                    if (mode == BotMode::Stationary) {
                        bx = bot_ax;
                        by = bot_ay;
                        bz = bot_az;
                    } else {
                        bx = in.x + kOrbitRadius * std::cos(kOrbitSpeed * t);
                        by = in.y;
                        bz = in.z + kOrbitRadius * std::sin(kOrbitSpeed * t);
                    }
                    if (bot_down) {  // down: it stays where it fell
                        if (!bot_fall_valid) {
                            bot_fx = bx;
                            bot_fy = by;
                            bot_fz = bz;
                            bot_fall_valid = true;
                        }
                        bx = bot_fx;
                        by = bot_fy;
                        bz = bot_fz;
                    }

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
                    bflags |= bot_pose_flags(t, cfg_.bot_pose_first_s);  // blocks, crouches and heals on a timer (see packet.hpp)
                    if (bot_down) bflags = static_cast<uint16_t>(bflags & ~kFlagPoseMask);  // nobody blocks or heals while down

                    // It copies YOUR rotation, so it doesn't depend on any axis guess: its look-line
                    // should point the same way you are looking.
                    const auto out = make_position(fake_session, ++fake_seq, bx, by, bz, in.qx, in.qy, in.qz, in.qw,
                                                   bflags);
                    fake_->send(&out, sizeof(out));

                    // (9.13) what a player who has gone down (or got up) tells the other script
                    if (bot_say == 1) {
                        send_message_packet(*fake_, fake_session, ++fake_msg_id, kMsgHealth, bot_event_text("down", bx, by, bz));
                        bot_health_at = Clock::time_point{};  // and the health report goes out at once
                        bot_say = 0;
                    } else if (bot_say == 2) {
                        send_message_packet(*fake_, fake_session, ++fake_msg_id, kMsgHealth, bot_event_text("up", bx, by, bz));
                        send_message_packet(*fake_, fake_session, ++fake_msg_id, kMsgHealth, bot_health_text(false));
                        bot_say = 0;
                    }
                    if (bot_down && now - bot_health_at >= seconds(1)) {  // (the script ignores a report older than 10 s)
                        bot_health_at = now;
                        send_message_packet(*fake_, fake_session, ++fake_msg_id, kMsgHealth, bot_health_text(true));
                    }

                    // Two pretend enemies, so the enemy ghosts can be tried without a second player: one circles
                    // the bot, one stands still 8 m from where you first were. Same text format the Lua script
                    // writes (see bridge.hpp).
                    if (!bot_enemy_anchored) {
                        bot_enemy_anchored = true;
                        bot_enx = in.x + 8.0f;
                        bot_eny = in.y;
                        bot_enz = in.z;
                    }
                    if (now - fake_last_state >= milliseconds(100)) {
                        fake_last_state = now;
                        const float ex = bx + 6.0f * std::cos(0.5f * t), ez = bz + 6.0f * std::sin(0.5f * t);
                        char eb[256];
                        std::snprintf(eb, sizeof(eb),
                                      "Em9999,%.2f,%.2f,%.2f,0,0,0,1,100,1,0,0,0;Em9998,%.2f,%.2f,%.2f,0,0,0,1,40,1,0,0,0",
                                      ex, by, ez, bot_enx, bot_eny, bot_enz);
                        const auto sp = encode_state(fake_session, ++fake_state_seq, eb);
                        if (!sp.empty()) fake_->send(sp.data(), sp.size());
                    }
                } else if (peek_type(buf, static_cast<size_t>(n)) == static_cast<int>(PacketType::FileBegin) ||
                           peek_type(buf, static_cast<size_t>(n)) == static_cast<int>(PacketType::FileChunk) ||
                           peek_type(buf, static_cast<size_t>(n)) == static_cast<int>(PacketType::FileEnd)) {
                    // The bot takes a save you send it and sends a copy back as "its" co-op save, so the whole
                    // save-sharing path can be tried alone. Small saves only.
                    uint32_t fid = 0, ftotal = 0, fcrc = 0, foff = 0;
                    uint16_t fslot = 0;
                    std::string flabel;
                    const uint8_t* fbytes = nullptr;
                    size_t fn = 0;
                    if (decode_file_begin(buf, static_cast<size_t>(n), fid, ftotal, fcrc, fslot, flabel)) {
                        bot_in = InFile{};
                        bot_in.active = ftotal <= 262144;
                        bot_in.id = fid;
                        bot_in.total = ftotal;
                        bot_in.crc = fcrc;
                        bot_in.slot = fslot;
                    } else if (decode_file_chunk(buf, static_cast<size_t>(n), fid, foff, fbytes, fn)) {
                        if (bot_in.active && fid == bot_in.id && foff == bot_in.data.size()) {
                            bot_in.data.insert(bot_in.data.end(), fbytes, fbytes + fn);
                        }
                    } else if (decode_file_end(buf, static_cast<size_t>(n), fid) && bot_in.active && fid == bot_in.id &&
                               bot_in.data.size() == bot_in.total) {
                        const uint32_t out_id = 1000 + fid;
                        bot_frames.push_back(encode_file_begin(fake_session, out_id, bot_in.total, bot_in.crc,
                                                               static_cast<uint16_t>(bot_in.slot),
                                                               std::string("CO-OP ") + kLoopbackName + " " + timestamp_now()));
                        for (size_t off = 0; off < bot_in.data.size(); off += kFileChunkBytes) {
                            const size_t cn = std::min(kFileChunkBytes, bot_in.data.size() - off);
                            bot_frames.push_back(encode_file_chunk(fake_session, out_id, static_cast<uint32_t>(off),
                                                                   bot_in.data.data() + off, cn));
                        }
                        const auto fe = make_file_end(fake_session, out_id);
                        bot_frames.emplace_back(reinterpret_cast<const uint8_t*>(&fe),
                                                reinterpret_cast<const uint8_t*>(&fe) + sizeof(fe));
                        bot_in = InFile{};
                    }
                } else if (decode_event(buf, static_cast<size_t>(n), ev)) {
                    const auto ack = make_ack(fake_session, ev.id);
                    fake_->send(&ack, sizeof(ack));
                } else if (decode_message(buf, static_cast<size_t>(n), m_session, m_id, m_kind, m_payload)) {
                    const auto ack = make_message_ack(fake_session, m_id);
                    fake_->send(&ack, sizeof(ack));
                    // Echo chat, and answer a ping with a ping at the same spot, so the in-game UI can be
                    // tried without a second player.
                    if (m_kind == 1) {
                        std::string reply = "echo: " + m_payload;
                        if (reply.size() > 180) reply.resize(180);
                        while (!reply.empty() && !valid_utf8(reply)) reply.pop_back();
                        send_message_packet(*fake_, fake_session, ++fake_msg_id, 1, reply);
                    } else if (m_kind == 2) {
                        send_message_packet(*fake_, fake_session, ++fake_msg_id, 2, m_payload);
                    } else if (m_kind == kMsgGive || m_kind == kMsgDrop) {
                        // (9.13) answer like a receiving script does, or the sender never takes the item out of its inventory
                        const std::string answer = m_kind == kMsgGive ? bot_answer_gift(m_payload) : bot_answer_drop(m_payload);
                        if (!answer.empty()) {
                            send_message_packet(*fake_, fake_session, ++fake_msg_id, kMsgGiveAnswer, answer);
                            log(std::string("Loopback bot answered ") + (m_kind == kMsgGive ? "a gift" : "a drop") + ": " + answer);
                        }
                    } else if (m_kind == kMsgBotCommand) {
                        const int cmd = bot_command(m_payload);
                        if (cmd == 1 && !bot_down) {
                            bot_down = true;
                            bot_fall_valid = false;
                            bot_say = 1;
                            log("Loopback bot: told to go down.");
                        } else if (cmd == 0 && bot_down) {
                            bot_down = false;
                            bot_say = 2;
                            log("Loopback bot: told to get up.");
                        }
                    } else if (m_kind == kMsgHealth && bot_down) {
                        BotEvent be;
                        if (bot_parse_event(m_payload, be) && bot_is_healing(be) && bot_fall_valid) {
                            const double d = bot_distance(be.x, be.y, be.z, bot_fx, bot_fy, bot_fz);
                            char note[160];
                            if (bot_heal_reaches(d)) {
                                bot_down = false;
                                bot_say = 2;
                                std::snprintf(note, sizeof(note), "Loopback bot: got up (a %s %.1f m away).", be.kind.c_str(), d);
                            } else {
                                std::snprintf(note, sizeof(note), "Loopback bot: still down (a %s %.1f m away, it takes %.0f m).",
                                              be.kind.c_str(), d, kBotReviveRadius);
                            }
                            log(note);
                        }
                    }
                }
            }
        }

        if (fake_) {
            while (!bot_frames.empty() && fake_->send(bot_frames.front().data(), bot_frames.front().size())) {
                bot_frames.pop_front();
            }
        }

        // 3. Peer -> pose/name/events/messages for the Lua script.
        const int n = net_->recv(buf, kBuf, 3);
        {
            std::string tmsg;
            while (net_->take_status(tmsg)) log(tmsg);
        }
        if (n < 0) {
            log("Network error while receiving; stopping.");
            break;
        }
        if (n > 0) {
            const auto len = static_cast<size_t>(n);
            if (peek_type(buf, len) >= 0) {
                last_any = Clock::now();
                st.foreign_protocol = 0;
            } else {
                // One of ours, but another protocol version: say so instead of silently ignoring it.
                const int fv = peek_foreign_version(buf, len);
                if (fv >= 0) {
                    if (st.foreign_protocol != fv) {
                        log("The other player's re7mp.exe uses protocol " + std::to_string(fv) + ", yours uses " +
                            std::to_string(static_cast<int>(kProtocolVersion)) + " (release v" + kReleaseVersion +
                            "). You both need the same version of re7mp.exe and the script.");
                    }
                    st.foreign_protocol = fv;
                }
            }
            PositionPacket pos;
            EventPacket ev;
            AckPacket ack;
            std::string nm;
            uint32_t m_session = 0, m_id = 0;
            uint16_t m_kind = 0;
            std::string m_payload;
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
                            bridge.publish_remote(rp, st.received, st.remote_name, "tcp", role_name);
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
                case static_cast<int>(PacketType::Message):
                    if (decode_message(buf, len, m_session, m_id, m_kind, m_payload)) {
                        const auto reply = make_message_ack(session, m_id);  // always ack, even duplicates
                        net_->send(&reply, sizeof(reply));
                        if (!have_msg_session || m_session != seen_msg_session) {
                            seen_msg_ids.clear();
                            seen_msg_order.clear();
                            seen_msg_session = m_session;
                            have_msg_session = true;
                        }
                        if (seen_msg_ids.insert(m_id).second) {  // first time we see this one
                            seen_msg_order.push_back(m_id);
                            if (seen_msg_order.size() > 256) {
                                seen_msg_ids.erase(seen_msg_order.front());
                                seen_msg_order.pop_front();
                            }
                            InMessage im;
                            im.n = ++inbox_n;
                            im.id = m_id;
                            im.kind = m_kind;
                            im.payload = m_payload;
                            inbox.push_back(std::move(im));
                            if (inbox.size() > kInboxSize) inbox.pop_front();
                            inbox_dirty = true;
                            ++st.messages_received;
                        }
                    }
                    break;
                case static_cast<int>(PacketType::MessageAck):
                    if (decode_message_ack(buf, len, ack)) {
                        for (auto it = pending_msgs.begin(); it != pending_msgs.end(); ++it) {
                            if (it->id == ack.id) {
                                pending_msgs.erase(it);
                                break;
                            }
                        }
                    }
                    break;
                case static_cast<int>(PacketType::State): {
                    uint32_t s_session = 0, s_seq = 0;
                    std::string s_payload;
                    if (decode_state(buf, len, s_session, s_seq, s_payload)) {
                        const bool newer = !have_state_pkt || s_session != remote_state_session ||
                                           static_cast<int32_t>(s_seq - remote_state_seq) > 0;
                        if (newer) {
                            have_state_pkt = true;
                            remote_state_session = s_session;
                            remote_state_seq = s_seq;
                            ++st.states_received;
                            bridge.publish_state(s_seq, st.states_received, s_payload);
                        }
                    }
                    break;
                }
                case static_cast<int>(PacketType::FileBegin): {
                    uint32_t fid = 0, ftotal = 0, fcrc = 0;
                    uint16_t fslot = 0;
                    std::string flabel;
                    if (!save_sync_on) break;  // we are not sharing saves: ignore
                    if (decode_file_begin(buf, len, fid, ftotal, fcrc, fslot, flabel)) {
                        in_file = InFile{};
                        in_file.active = true;
                        in_file.id = fid;
                        in_file.total = ftotal;
                        in_file.crc = fcrc;
                        in_file.slot = fslot;
                        in_file.label = flabel;
                        in_file.data.reserve(ftotal);
                    }
                    break;
                }
                case static_cast<int>(PacketType::FileChunk): {
                    uint32_t fid = 0, foff = 0;
                    const uint8_t* fbytes = nullptr;
                    size_t fn = 0;
                    if (!save_sync_on || !in_file.active) break;
                    if (decode_file_chunk(buf, len, fid, foff, fbytes, fn) && fid == in_file.id) {
                        if (foff == in_file.data.size() && in_file.data.size() + fn <= in_file.total) {
                            in_file.data.insert(in_file.data.end(), fbytes, fbytes + fn);
                        } else {
                            log("A received save arrived out of order; dropping it.");
                            in_file.active = false;
                        }
                    }
                    break;
                }
                case static_cast<int>(PacketType::FileEnd): {
                    uint32_t fid = 0;
                    if (!save_sync_on || !in_file.active) break;
                    if (decode_file_end(buf, len, fid) && fid == in_file.id) {
                        InFile f = std::move(in_file);
                        in_file = InFile{};
                        if (f.data.size() != f.total || crc32(f.data.data(), f.data.size()) != f.crc) {
                            last_save_event = "A save from the other player arrived damaged and was discarded.";
                            log(last_save_event);
                        } else {
                            const std::string from = st.remote_name.empty() ? "the other player" : st.remote_name;
                            const int slot = pick_slot(cfg_.save_dir, f.slot, manifest);
                            const bool was_received_slot = slot >= 1 && manifest.is_received_slot(slot);
                            std::error_code sec_ec;
                            if (slot < 0) {
                                last_save_event = "No free save slot for the co-op save from " + from + ".";
                                log(last_save_event);
                            } else if (!write_save_file(cfg_.save_dir, slot, f.data)) {
                                last_save_event = "Could not write the co-op save from " + from + " to the save folder.";
                                log(last_save_event);
                            } else {
                                const std::filesystem::path file = cfg_.save_dir / slot_filename(slot);
                                watcher->ignore_current(file);
                                // Read it back: what is on disk must be what arrived (nothing else may hold or rewrite the file).
                                std::vector<uint8_t> back;
                                if (!read_whole_file(file, back) || back.size() != f.data.size() ||
                                    crc32(back.data(), back.size()) != f.crc) {
                                    last_save_event = "The co-op save from " + from + " was written to " + slot_filename(slot) +
                                                      " but reading it back gave other data: it is NOT marked CO-OP. (Is something else using that file?)";
                                    log(last_save_event);
                                } else {
                                    const bool replaced_ours = was_received_slot;
                                    CoopEntry e;
                                    e.slot = slot;
                                    e.label = f.label;
                                    e.from = from;
                                    e.partner = from;
                                    e.role = "received";
                                    e.when = timestamp_now();
                                    e.crc = f.crc;
                                    e.size = f.data.size();
                                    e.from_slot = f.slot;
                                    if (f.slot >= 1 && slot == f.slot) {
                                        e.why = replaced_ours ? "it replaced the earlier copy from " + from + " in that slot"
                                                              : "the same slot number as on " + from + "'s PC (it was free here)";
                                    } else if (f.slot >= 1) {
                                        e.why = "slot " + std::to_string(f.slot) + " here holds a save of your own, so it went into the lowest free slot";
                                    } else {
                                        e.why = "it went into the lowest free slot";
                                    }
                                    manifest.upsert(e);
                                    verify_seen[slot] = std::filesystem::last_write_time(file, sec_ec);
                                    ++st.saves_received;
                                    last_save_event = "Co-op save from " + from + " installed in slot " + std::to_string(slot) + " (" +
                                                      slot_filename(slot) + ", checked: the file holds what arrived; " + e.why + "): " + f.label;
                                    log(last_save_event);
                                }
                            }
                        }
                        publish_saves();
                    }
                    break;
                }
                default: break;  // not ours, or a different protocol version
            }
        }

        // Hand received messages to the Lua script (retried if Lua happened to have the file open).
        if (inbox_dirty) {
            const std::vector<InMessage> snapshot(inbox.begin(), inbox.end());
            if (bridge.publish_messages(session, snapshot)) inbox_dirty = false;
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
        st.last_save_event = last_save_event;
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
