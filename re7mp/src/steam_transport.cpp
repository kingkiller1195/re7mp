#include "steam_transport.hpp"

#include <algorithm>
#include <cstring>
#include <thread>

namespace re7mp {

namespace {
const char* relay_words(int s) {
    if (s == 100) return "ready";
    if (s == 3) return "connecting";
    if (s == 2) return "waiting for a network configuration";
    if (s == 1) return "waiting";
    if (s == 0) return "not started";
    return "not available";
}
}  // namespace

std::unique_ptr<SteamTransport> SteamTransport::create(std::unique_ptr<ISteamApi> api, uint64_t peer_id, std::string& err) {
    if (!api) {
        err = "Steam is not available in this build";
        return nullptr;
    }
    if (peer_id < kSteamIdIndividualMin || peer_id > kSteamIdIndividualMax) {
        err = "enter the other player's Steam ID (17 digits, starting 7656119...), or paste their invite line";
        return nullptr;
    }
    if (!api->init(err)) {
        if (err.empty()) err = "Steam could not be started";
        return nullptr;
    }
    const uint64_t self = api->self_id();
    if (self == 0) {
        err = "Steam started but says nobody is signed in";
        return nullptr;
    }
    if (self == peer_id) {
        err = "that is your own Steam ID: enter the OTHER player's";
        return nullptr;
    }
    std::unique_ptr<SteamTransport> t(new SteamTransport());
    t->api_ = std::move(api);
    t->self_ = self;
    t->peer_ = peer_id;
    t->last_rx_ = t->last_accept_ = t->last_relay_check_ = t->started_ = t->last_tx_ = t->last_session_check_ = t->last_stuck_ = t->now_();
    t->api_->accept_session(peer_id);
    const std::string app = t->api_->app_text();
    t->say("Steam: signed in as " + t->api_->self_name() + " (Steam ID " + std::to_string(self) + (app.empty() ? "" : ", " + app) + "); waiting for " +
           std::to_string(peer_id) + " over Steam's relay (" + (steam_i_host(self, peer_id) ? "you host" : "they host") + ", the lower Steam ID hosts).");
    t->send_hello(t->started_);  // the session starts now, not when the game first writes something
    return t;
}

SteamTransport::~SteamTransport() {
    if (api_ && peer_) api_->close_session(peer_);  // the next Start begins a clean session
}

bool SteamTransport::raw_send(const void* data, size_t len) {
    const int r = api_->send(peer_, data, len, true);
    if (r != last_send_result_) {
        last_send_result_ = r;
        if (r != 1) say("Steam: sending failed (Steam's answer " + std::to_string(r) + "); it is tried again with the next packet.");
    }
    if (r != 1) {
        ++send_failures_;
        return false;
    }
    last_tx_ = now_();
    return true;
}

// A hello is 8 bytes: "S7HI" and a counter. It is eaten here (it never reaches the engine) but it counts as hearing the other player.
void SteamTransport::send_hello(Clock::time_point now) {
    uint8_t h[8] = {'S', '7', 'H', 'I', 0, 0, 0, 0};
    const uint32_t n = ++hello_seq_;
    std::memcpy(h + 4, &n, sizeof(n));
    last_tx_ = now;
    if (raw_send(h, sizeof(h))) ++hellos_sent_;
}

// What Steam says about the session with the friend, logged when it changes: this is what separates "the other side never answered" from "Steam gave
// up on the route" from "we never started a session at all".
void SteamTransport::poll_session(Clock::time_point now) {
    if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_session_check_).count() < kSessionPollMs) return;
    last_session_check_ = now;
    const SteamSessionInfo si = api_->session_info(peer_);
    if (!si.known) return;
    if (si.state == session_state_seen_ && si.end_reason == session_reason_seen_ && si.pop_relay == session_relay_seen_) return;
    session_state_seen_ = si.state;
    session_reason_seen_ = si.end_reason;
    session_relay_seen_ = si.pop_relay;
    std::string t = std::string("Steam: the session with the other player is ") + session_state_words(si.state);
    if (si.state == 3 || si.state == 2) {
        const std::string pr = pop_text(si.pop_remote), pl = pop_text(si.pop_relay);
        if (!pl.empty()) t += ", through the " + pl + " relay";
        else if (si.state == 3) t += ", on a direct path";
        if (!pr.empty()) t += " (their side: " + pr + ")";
    }
    if (si.end_reason != 0) t += " [reason " + std::to_string(si.end_reason) + (si.end_debug.empty() ? "" : ": " + si.end_debug) + "]";
    t += ".";
    say(t);
}

// Silent for kStuckHintMs: say what is known and what to check (again every minute, five times at most).
void SteamTransport::tell_stuck(Clock::time_point now) {
    const auto since = std::chrono::duration_cast<std::chrono::milliseconds>(now - started_).count();
    if (have_rx_ || since < kStuckHintMs) return;
    if (stuck_told_ > 0 && std::chrono::duration_cast<std::chrono::milliseconds>(now - last_stuck_).count() < 60000) return;
    if (stuck_told_ >= 5) return;
    ++stuck_told_;
    last_stuck_ = now;
    const SteamSessionInfo si = api_->session_info(peer_);
    std::string t = "Steam: nothing has come from " + std::to_string(peer_) + " after " + std::to_string(since / 1000) + " s (" + std::to_string(hellos_sent_) +
                    " hellos sent, " + std::to_string(send_failures_) + " refused by Steam";
    if (si.known) t += std::string("; the session is ") + session_state_words(si.state);
    t += "). Check that the other player has pressed Start with YOUR Steam ID (" + std::to_string(self_) +
         "), that Steam is running and signed in on both PCs (different accounts), and that both of you run this same build.";
    if (si.known && si.state == 0) t += " Steam has no session at all: the first send did not start one.";
    if (si.known && (si.state == 1 || si.state == 2)) t += " Steam is still trying to reach them: their copy of the exe probably has not started the link yet, or Steam's request is not reaching it.";
    say(t);
}

void SteamTransport::pump() {
    const auto now = now_();
    api_->run_callbacks();

    std::vector<SteamMessage> msgs;
    api_->receive(msgs, 64);
    for (auto& m : msgs) {
        if (m.from != peer_) {
            ++strays_;
            if (!stray_told_) {
                stray_told_ = true;
                say("Steam: a message from " + std::to_string(m.from) + " was ignored (you are connected to " + std::to_string(peer_) + " only).");
            }
            continue;
        }
        have_rx_ = true;
        last_rx_ = now;
        const bool was_connected = connected_;
        if (!connected_) {
            connected_ = true;
            say(ever_connected_ ? "Steam: the other player is back (through Steam's relay)." : "Steam: connected to the other player through Steam's relay.");
            ever_connected_ = true;
        }
        if (is_hello(m.data)) {  // a hello: it only says "I am here" (and a hello gets one back, so the sender is heard even if it sends nothing else)
            ++hellos_seen_;
            if (!was_connected) send_hello(now);  // the first one (or the first after a loss) is answered at once
            continue;
        }
        inbox_.push_back(std::move(m.data));
    }

    if (connected_ && std::chrono::duration_cast<std::chrono::milliseconds>(now - last_rx_).count() > kLostAfterMs) {
        connected_ = false;
        say("Steam: nothing from the other player for " + std::to_string(kLostAfterMs / 1000) + " s (they may have stopped, or closed the game). Waiting.");
    }

    // The relay's state, when it changes (checked about twice a second).
    if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_relay_check_).count() >= 500) {
        last_relay_check_ = now;
        const int rs = api_->relay_status();
        if (rs != relay_seen_) {
            relay_seen_ = rs;
            say(std::string("Steam: the relay network is ") + relay_words(rs) + " (" + std::to_string(rs) + ").");
        }
    }

    // A friend who started later: until something has arrived, the session is accepted again every couple of seconds.
    if (!have_rx_ && std::chrono::duration_cast<std::chrono::milliseconds>(now - last_accept_).count() >= kAcceptEveryMs) {
        last_accept_ = now;
        api_->accept_session(peer_);
    }

    // (10.13) Hellos: every second while the friend is not heard (never yet, or lost), then only when nothing else has been sent for a while.
    const auto since_tx = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_tx_).count();
    if (since_tx >= (connected_ ? kKeepAliveMs : kHelloEveryMs)) send_hello(now);

    poll_session(now);
    tell_stuck(now);
}

bool SteamTransport::send(const void* data, size_t len) {
    if (!api_ || len == 0) return false;
    return raw_send(data, len);
}

int SteamTransport::recv(void* buf, size_t cap, int timeout_ms) {
    if (!api_) return -1;
    const auto start = Clock::now();  // (the wait is real time; only the link's own timers use the clock tests can move)
    for (;;) {
        pump();
        while (!inbox_.empty()) {
            std::vector<uint8_t> d = std::move(inbox_.front());
            inbox_.pop_front();
            if (d.empty() || d.size() > cap) continue;  // nothing in it, or too big for the caller: dropped
            std::memcpy(buf, d.data(), d.size());
            return static_cast<int>(d.size());
        }
        if (timeout_ms <= 0) return 0;
        const auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
        if (waited >= timeout_ms) return 0;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

bool SteamTransport::take_status(std::string& msg) {
    if (status_.empty()) return false;
    msg = std::move(status_.front());
    status_.pop_front();
    return true;
}

}  // namespace re7mp
