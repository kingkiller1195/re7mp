// Spins up a host and two clients in one process over 127.0.0.1 and checks the
// whole protocol: handshake, roster, pose relay, reliable chat/user events
// (including under packet loss), leave notifications, and "server full".
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <thread>

#include "../src/net.hpp"

using namespace mp;

static int g_fail = 0;
#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::printf("  FAIL line %d: %s\n", __LINE__, #cond);                \
            g_fail++;                                                            \
        }                                                                        \
    } while (0)

struct Peer {
    explicit Peer(const char* l) : label(l) {}
    const char* label;
    Session s;
    std::vector<Event> log;
    void pump() {
        for (auto& e : s.drain()) log.push_back(std::move(e));
    }
    int count(EventType t, int id = -1) const {
        int n = 0;
        for (auto& e : log) if (e.type == t && (id < 0 || e.id == id)) n++;
        return n;
    }
    const Event* last(EventType t, int id = -1) const {
        for (auto it = log.rbegin(); it != log.rend(); ++it)
            if (it->type == t && (id < 0 || it->id == id)) return &*it;
        return nullptr;
    }
};

static bool wait_for(std::vector<Peer*> peers, const std::function<bool()>& pred, int timeout_ms = 4000) {
    auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < end) {
        for (auto* p : peers) p->pump();
        if (pred()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    for (auto* p : peers) p->pump();
    return pred();
}

static std::array<float, kPoseFloats> make_pose(float base) {
    std::array<float, kPoseFloats> p{};
    for (int i = 0; i < kPoseFloats; i++) p[i] = base + i * 0.5f;
    return p;
}

int main() {
    const uint16_t port = static_cast<uint16_t>(47000 + (std::rand() % 2000));
    Peer host{"host"}, a{"alice"}, b{"bob"};
    std::string err;
    std::vector<Peer*> all{&host, &a, &b};

    std::puts("[1] handshake + roster");
    CHECK(host.s.host(port, 3, "Host", err));
    a.s.set_vr(true);
    CHECK(a.s.join("127.0.0.1", port, "Alice", err));
    CHECK(wait_for(all, [&] { return a.count(EventType::Connected) == 1; }));
    CHECK(b.s.join("127.0.0.1", port, "Bob", err));
    CHECK(wait_for(all, [&] { return b.count(EventType::Connected) == 1; }));
    CHECK(a.s.local_id() == 1);
    CHECK(b.s.local_id() == 2);
    CHECK(wait_for(all, [&] {
        return host.count(EventType::Joined) == 2 && a.count(EventType::Joined) == 2 && b.count(EventType::Joined) == 2;
    }));
    // Alice was told about the host (0) and Bob (2); Bob about the host (0) and Alice (1).
    CHECK(a.last(EventType::Joined, 0) && a.last(EventType::Joined, 0)->text == "Host");
    CHECK(a.last(EventType::Joined, 2) && a.last(EventType::Joined, 2)->text == "Bob");
    CHECK(b.last(EventType::Joined, 1) && b.last(EventType::Joined, 1)->text == "Alice");
    CHECK(b.last(EventType::Joined, 1)->flags & 1);  // Alice announced VR

    std::puts("[2] pose relay (client -> host -> other client, and host -> clients)");
    a.s.set_local_pose(kPoseVR | kPoseHandsValid | kPoseInGame, make_pose(10.f));
    host.s.set_local_pose(kPoseInGame, make_pose(100.f));
    CHECK(wait_for(all, [&] {
        return host.last(EventType::Pose, 1) && b.last(EventType::Pose, 1) && a.last(EventType::Pose, 0) &&
               b.last(EventType::Pose, 0);
    }));
    if (b.last(EventType::Pose, 1)) {
        CHECK(b.last(EventType::Pose, 1)->pose == make_pose(10.f));
        CHECK(b.last(EventType::Pose, 1)->flags == (kPoseVR | kPoseHandsValid | kPoseInGame));
    }
    if (a.last(EventType::Pose, 0)) CHECK(a.last(EventType::Pose, 0)->pose == make_pose(100.f));
    CHECK(a.count(EventType::Pose, 1) == 0);  // never echoed back to the sender

    std::puts("[3] reliable chat + user events");
    CHECK(a.s.send_chat("hello from alice"));
    CHECK(wait_for(all, [&] { return host.count(EventType::Chat) == 1 && b.count(EventType::Chat) == 1; }));
    CHECK(b.last(EventType::Chat)->id == 1 && b.last(EventType::Chat)->text == "hello from alice");
    CHECK(host.s.send_user(7, "{\"door\":12}"));
    CHECK(wait_for(all, [&] { return a.count(EventType::User) == 1 && b.count(EventType::User) == 1; }));
    CHECK(a.last(EventType::User)->kind == 7 && a.last(EventType::User)->text == "{\"door\":12}");
    CHECK(a.last(EventType::User)->id == 0);

    std::puts("[4] reliable delivery under 30% packet loss (ordered, exactly once)");
    for (auto* p : all) p->s.set_debug_loss(30);
    const int N = 25;
    size_t chat_before = b.count(EventType::Chat);
    for (int i = 0; i < N; i++) CHECK(a.s.send_chat("msg " + std::to_string(i)));
    CHECK(wait_for(all, [&] { return b.count(EventType::Chat) >= static_cast<int>(chat_before) + N; }, 15000));
    {
        int next = 0;
        bool ordered = true;
        size_t seen = 0;
        for (auto& e : b.log) {
            if (e.type != EventType::Chat || e.text.rfind("msg ", 0) != 0) continue;
            seen++;
            if (e.text != "msg " + std::to_string(next++)) ordered = false;
        }
        CHECK(ordered);
        CHECK(seen == static_cast<size_t>(N));
    }
    for (auto* p : all) p->s.set_debug_loss(0);

    std::puts("[5] leave notification");
    b.s.stop();
    CHECK(wait_for(all, [&] { return host.count(EventType::Left, 2) == 1 && a.count(EventType::Left, 2) == 1; }));

    std::puts("[6] id reuse + fresh pose sequence");
    Peer c{"carol"};
    CHECK(c.s.join("127.0.0.1", port, "Carol", err));
    all.push_back(&c);
    CHECK(wait_for(all, [&] { return c.count(EventType::Connected) == 1; }));
    CHECK(c.s.local_id() == 2);  // freed id handed out again
    c.s.set_local_pose(kPoseInGame, make_pose(55.f));
    CHECK(wait_for(all, [&] { return a.last(EventType::Pose, 2) != nullptr; }));
    if (a.last(EventType::Pose, 2)) CHECK(a.last(EventType::Pose, 2)->pose == make_pose(55.f));

    std::puts("[7] server full");
    Peer d{"dave"};
    CHECK(d.s.join("127.0.0.1", port, "Dave", err));
    all.push_back(&d);
    CHECK(wait_for(all, [&] { return d.count(EventType::Disconnected) == 1; }));
    CHECK(d.last(EventType::Disconnected)->text == "server is full");
    CHECK(d.s.state() == State::Idle);

    std::puts("[8] host shutdown notifies clients");
    host.s.stop();
    CHECK(wait_for(all, [&] { return a.count(EventType::Disconnected) == 1 && c.count(EventType::Disconnected) == 1; }));

    std::puts("[9] bad input is rejected cleanly");
    Session bad;
    CHECK(!bad.join("not-an-ip", 1234, "x", err));
    CHECK(!bad.send_chat("nobody listening"));

    if (g_fail == 0) std::puts("\nALL TESTS PASSED");
    else std::printf("\n%d CHECK(S) FAILED\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
