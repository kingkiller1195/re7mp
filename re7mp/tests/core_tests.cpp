// Core tests: no game or GUI needed. Build target: re7mp_tests
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <regex>
#include <sstream>
#include <thread>

#include "bridge.hpp"
#include "engine.hpp"
#include "game_locator.hpp"
#include "packet.hpp"

namespace fs = std::filesystem;
using namespace re7mp;
using std::chrono::milliseconds;

static int g_failed = 0;
#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); \
            ++g_failed;                                                 \
        }                                                               \
    } while (0)

static void write_text(const fs::path& p, const std::string& s) {
    fs::create_directories(p.parent_path());
    std::ofstream(p, std::ios::binary | std::ios::trunc) << s;
}
static std::string read_text(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}
static bool json_num(const std::string& t, const char* key, double& out) {
    std::smatch m;
    std::regex re(std::string("\"") + key + "\"\\s*:\\s*(-?[0-9.]+)");
    if (!std::regex_search(t, m, re)) return false;
    out = std::stod(m[1].str());
    return true;
}
static bool json_str(const std::string& t, const char* key, std::string& out) {
    std::smatch m;
    std::regex re(std::string("\"") + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
    if (!std::regex_search(t, m, re)) return false;
    out = m[1].str();
    return true;
}
static int count_lines(const std::vector<std::string>& log, const std::string& needle) {
    int n = 0;
    for (auto& l : log) n += l.find(needle) != std::string::npos;
    return n;
}

// ---------------------------------------------------------------------------------------------

static void test_packets() {
    auto p = make_position(7, 9, 1.f, 2.f, 3.f, 0.f, 0.5f, 0.f, 0.8f, kFlagReady | (2 << 1) | kFlagSeesReady);
    PositionPacket q;
    CHECK(decode_position(&p, sizeof(p), q));
    CHECK(sizeof(p) == 46 && (q.flags & kFlagReady) && flag_difficulty(q.flags) == 2 && (q.flags & kFlagSeesReady) &&
          !(q.flags & kFlagGo));
    CHECK(q.h.session == 7 && q.seq == 9 && q.x == 1.f && q.z == 3.f && q.qy == 0.5f && q.qw == 0.8f);
    CHECK(!decode_position(&p, sizeof(p) - 1, q));
    auto bad = p;
    bad.h.magic = 0;
    CHECK(!decode_position(&bad, sizeof(bad), q));
    bad = p;
    bad.h.version = 2;  // old protocol
    CHECK(!decode_position(&bad, sizeof(bad), q));
    bad = p;
    bad.qw = std::nanf("");
    CHECK(!decode_position(&bad, sizeof(bad), q));
    CHECK(peek_type(&p, sizeof(p)) == static_cast<int>(PacketType::Position));
    CHECK(peek_type("hello", 5) == -1);

    // Names
    std::string out;
    auto np = make_name(1, "  Alice  ");
    CHECK(decode_name(&np, sizeof(np), out) && out == "Alice");
    np = make_name(1, "Zoë 🙂");
    CHECK(decode_name(&np, sizeof(np), out) && out == "Zoë 🙂");
    np = make_name(1, std::string("a\x01" "b\n"));
    CHECK(decode_name(&np, sizeof(np), out) && out == "ab");  // control characters stripped
    np = make_name(1, "");
    CHECK(!decode_name(&np, sizeof(np), out));  // empty names are rejected
    CHECK(sanitize_name("\xff\xfe") == "");     // invalid UTF-8
    const std::string longname(100, 'x');
    CHECK(sanitize_name(longname).size() == kMaxNameBytes);
    // Cutting a long name must not split a multi-byte character.
    std::string wide;
    for (int i = 0; i < 20; ++i) wide += "é";  // 2 bytes each
    const std::string cut = sanitize_name(wide);
    CHECK(cut.size() <= kMaxNameBytes && valid_utf8(cut) && !cut.empty());
    // A hand-crafted packet with a bad name is rejected.
    NamePacket evil{};
    evil.h = make_header(PacketType::Name, 1);
    evil.len = 3;
    std::memcpy(evil.name, "a\"\x01", 3);
    CHECK(!decode_name(&evil, sizeof(evil), out));

    // Events
    auto ev = make_event(5, 77, EventType::NewGame, 2);
    EventPacket e2;
    CHECK(decode_event(&ev, sizeof(ev), e2) && e2.id == 77 && e2.arg == 2 && e2.type == 1);
    auto ak = make_ack(5, 77);
    AckPacket a2;
    CHECK(decode_ack(&ak, sizeof(ak), a2) && a2.id == 77);
    CHECK(!decode_ack(&ev, sizeof(ev), a2));
}

static void test_locator(const fs::path& tmp) {
    auto toks = vdf_tokens("\"path\"\t\t\"D:\\\\SteamLibrary\" // comment\n\"x\" \"a\\\"b\"");
    CHECK(toks.size() == 4 && toks[1] == "D:\\SteamLibrary" && toks[3] == "a\"b");

    const fs::path steam = tmp / "Steam";
    const fs::path lib2 = tmp / "Games" / "SteamLibrary";
    write_text(steam / "steamapps" / "libraryfolders.vdf",
               "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"" + steam.string() +
                   "\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"" + lib2.string() + "\"\n\t}\n}\n");
    CHECK(parse_library_paths(read_text(steam / "steamapps" / "libraryfolders.vdf")).size() == 2);
    write_text(lib2 / "steamapps" / "appmanifest_418370.acf",
               "\"AppState\"\n{\n\t\"appid\"\t\t\"418370\"\n\t\"installdir\"\t\t\"RE7 Custom Dir\"\n}\n");
    fs::create_directories(lib2 / "steamapps" / "common" / "RE7 Custom Dir");
    auto found = find_re7_in_steam(steam);
    CHECK(found && *found == lib2 / "steamapps" / "common" / "RE7 Custom Dir");
    CHECK(!find_re7_in_steam(tmp / "nowhere"));
    const fs::path game = *found;
    CHECK(!looks_like_re7(game) && !refw_installed(game));
    write_text(game / "re7.exe", "x");
    write_text(game / "dinput8.dll", "x");
    CHECK(looks_like_re7(game) && refw_installed(game));
}

static void test_install(const fs::path& tmp) {
    const fs::path game = tmp / "game";
    fs::create_directories(game);
    auto r1 = install_lua(game, "-- v1\r\nprint(1)\r\n");
    CHECK(r1.ok && r1.changed);
    auto r2 = install_lua(game, "-- v1\r\nprint(1)\r\n");
    CHECK(r2.ok && !r2.changed);
    auto r3 = install_lua(game, "-- v2\n");
    CHECK(r3.ok && r3.changed);
    CHECK(read_text(game / "reframework" / "autorun" / "re7mp.lua") == "-- v2\n");
}

static void test_bridge(const fs::path& tmp) {
    const fs::path d = tmp / "bridge";
    FileBridge b(d);
    LocalPose p;
    CHECK(!b.poll_pose(p));  // no file yet
    write_text(d / "re7mp_out.json", "{\"seq\":1,\"x\":1.5");  // half-written
    CHECK(!b.poll_pose(p));
    // Pretty-printed JSON with integers, negatives and an exponent; no rotation => identity.
    write_text(d / "re7mp_out.json", "{\n  \"seq\": 2,\n  \"x\": -3,\n  \"y\": 0.5,\n  \"z\": 1e2\n}\n");
    CHECK(b.poll_pose(p));
    CHECK(p.lua_seq == 2 && p.x == -3.f && p.y == 0.5f && p.z == 100.f && p.qw == 1.f && p.qx == 0.f && p.flags == 0);
    CHECK(!b.poll_pose(p));  // unchanged
    write_text(d / "re7mp_out.json",
               "{\"seq\":3,\"x\":0,\"y\":0,\"z\":0,\"qx\":0,\"qy\":0.7071,\"qz\":0,\"qw\":0.7071,\"flags\":13}");
    CHECK(b.poll_pose(p) && std::fabs(p.qy - 0.7071f) < 1e-4f && std::fabs(p.qw - 0.7071f) < 1e-4f && p.flags == 13);

    // Events: a half-written file is ignored, then picked up once, and a repeat is ignored.
    LocalEvent e;
    write_text(d / "re7mp_evt_out.json", "{\"id\":170000000001,\"ty");
    CHECK(!b.poll_event(e));
    write_text(d / "re7mp_evt_out.json", "{\"id\":170000000001,\"type\":1,\"arg\":2}");
    CHECK(b.poll_event(e) && e.lua_id == 170000000001ULL && e.type == 1 && e.arg == 2);
    CHECK(!b.poll_event(e));
    write_text(d / "re7mp_evt_out.json", "{\"id\":170000000002,\"type\":1,\"arg\":0}");
    CHECK(b.poll_event(e) && e.lua_id == 170000000002ULL && e.arg == 0);

    // Publishing: names are JSON-escaped, files readable back.
    RemotePose rp;
    rp.seq = 5; rp.x = 1; rp.y = 2; rp.z = 3; rp.qy = 0.5f; rp.qw = 0.5f; rp.flags = 29;
    CHECK(b.publish_remote(rp, 4, "Ann \"The Boss\" \\o/"));
    auto t = read_text(d / "re7mp_in.json");
    double v;
    std::string name;
    CHECK(json_num(t, "seq", v) && v == 5 && json_num(t, "z", v) && v == 3 && json_num(t, "qy", v) && v == 0.5 &&
          json_num(t, "flags", v) && v == 29);
    CHECK(json_str(t, "name", name) && name == "Ann \\\"The Boss\\\" \\\\o/");
    CHECK(b.publish_event(99, 3, 1, 2));
    t = read_text(d / "re7mp_evt_in.json");
    CHECK(json_num(t, "session", v) && v == 99 && json_num(t, "id", v) && v == 3 && json_num(t, "arg", v) && v == 2);

    // Stale files are cleared at engine start.
    b.clear_stale();
    CHECK(!fs::exists(d / "re7mp_in.json") && !fs::exists(d / "re7mp_out.json") && !fs::exists(d / "re7mp_evt_in.json"));
}

// Plays the part of the Lua script: writes a moving pose with a fixed, non-trivial rotation
// (qy=0.6, qw=0.8) and the given ready-check flags, for `ms` milliseconds.
static void fake_game(const fs::path& dir, double x0, double z0, int ms, std::atomic<int>* flags = nullptr) {
    uint32_t seq = 0;
    const auto end = std::chrono::steady_clock::now() + milliseconds(ms);
    while (std::chrono::steady_clock::now() < end) {
        ++seq;
        char buf[240];
        std::snprintf(buf, sizeof(buf),
                      "{\"seq\":%u,\"x\":%.3f,\"y\":0.0,\"z\":%.3f,\"qx\":0,\"qy\":0.6,\"qz\":0,\"qw\":0.8,\"flags\":%d}", seq,
                      x0 + seq * 0.01, z0, flags ? flags->load() : 0);
        std::ofstream(dir / "re7mp_out.json", std::ios::binary | std::ios::trunc) << buf;
        std::this_thread::sleep_for(milliseconds(50));
    }
}
static void fake_event(const fs::path& dir, uint64_t id, int type, int arg) {
    char buf[120];
    std::snprintf(buf, sizeof(buf), "{\"id\":%llu,\"type\":%d,\"arg\":%d}", static_cast<unsigned long long>(id), type, arg);
    write_text(dir / "re7mp_evt_out.json", buf);
}

static void test_loopback(const fs::path& tmp) {
    const fs::path dir = tmp / "loop";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.listen_port = 28915;
    cfg.name = "Tester";
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::atomic<int> flags{0};
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 4600, &flags); });
    auto in_json = [&] { return read_text(dir / "re7mp_in.json"); };
    auto in_flags = [&] {
        double v = -1;
        json_num(in_json(), "flags", v);
        return static_cast<int>(v);
    };

    std::this_thread::sleep_for(milliseconds(800));
    fake_event(dir, 170000000001ULL, 1, 2);  // generic one-shot event channel (kept for future use)
    CHECK(in_flags() == 0);                  // nobody is ready yet

    // Ready check: we press ready on Madhouse (difficulty 2 => flag value 4).
    flags = kFlagReady | (2 << 1);
    std::this_thread::sleep_for(milliseconds(700));
    CHECK(!(in_flags() & kFlagReady) && (in_flags() & kFlagSeesReady));  // it sees us, hasn't pressed ready yet (1.5 s delay)
    std::this_thread::sleep_for(milliseconds(1400));
    int f = in_flags();
    std::printf("  bot flags after delay = %d\n", f);
    CHECK((f & kFlagReady) && flag_difficulty(static_cast<uint16_t>(f)) == 2 && (f & kFlagSeesReady) && !(f & kFlagGo));
    // We now see the bot is ready, so we say so; the bot then goes.
    flags = kFlagReady | (2 << 1) | kFlagSeesReady;
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(in_flags() & kFlagGo);
    // We go too (the Lua sets GO once both are ready and you can see them).
    flags = kFlagReady | (2 << 1) | kFlagSeesReady | kFlagGo;
    std::this_thread::sleep_for(milliseconds(300));
    // Cancelling clears everything.
    flags = 0;
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(in_flags() == 0);
    g.join();

    auto s = e.status();
    CHECK(s.running && s.game_hooked && s.peer_active);
    CHECK(s.sent > 10 && s.received > 10);
    CHECK(s.remote_name == "Loopback Bot");
    const double dx = s.rx - s.lx, dz = s.rz - s.lz;
    const double dist = std::sqrt(dx * dx + dz * dz);
    std::printf("  loopback: sent=%llu recv=%llu orbit distance=%.2f name=%s\n", (unsigned long long)s.sent,
                (unsigned long long)s.received, dist, s.remote_name.c_str());
    CHECK(dist > 2.5 && dist < 3.5);  // the fake player orbits at 3 m

    // The bot copies your rotation exactly.
    double qy, qw;
    CHECK(json_num(in_json(), "qy", qy) && json_num(in_json(), "qw", qw));
    CHECK(std::fabs(qy - 0.6) < 1e-3 && std::fabs(qw - 0.8) < 1e-3);

    auto log = e.drain_log();
    CHECK(count_lines(log, "Game hooked") >= 1 && count_lines(log, "Peer connected") >= 1);
    CHECK(count_lines(log, "Loopback Bot") >= 1);
    CHECK(count_lines(log, "Sent new-game request (Madhouse)") == 1);
    CHECK(count_lines(log, "received the request") == 1);
    CHECK(count_lines(log, "You are ready to start a new game (Madhouse)") == 1);
    CHECK(count_lines(log, "Loopback Bot is ready to start a new game (Madhouse)") == 1);
    CHECK(count_lines(log, "Both players are ready: going.") == 1);
    CHECK(count_lines(log, "You are no longer ready") == 1);
    e.stop();
    CHECK(!e.running());
    CHECK(e.start(cfg, err));  // restartable on the same ports
    e.stop();
}

static void test_network(const fs::path& tmp) {
    Engine a, b;
    Config ca, cb;
    ca.data_dir = tmp / "na";
    cb.data_dir = tmp / "nb";
    ca.mode = cb.mode = Mode::Network;
    ca.listen_port = 28931;
    ca.peer_host = "127.0.0.1";
    ca.peer_port = 28932;
    ca.name = "Alice";
    cb.listen_port = 28932;
    cb.peer_host = "127.0.0.1";
    cb.peer_port = 28931;
    cb.name = "Bob";
    std::string err;
    CHECK(a.start(ca, err));
    // B starts late: A's event must be retransmitted until B is there to ack it.
    std::atomic<int> fa{0}, fb{0};
    std::thread g1([&] { fake_game(ca.data_dir, 10.0, 10.0, 2500, &fa); });
    std::this_thread::sleep_for(milliseconds(300));
    fake_event(ca.data_dir, 170000000005ULL, 1, 1);  // new game, Normal
    std::this_thread::sleep_for(milliseconds(900));
    CHECK(b.start(cb, err));
    std::thread g2([&] { fake_game(cb.data_dir, -50.0, 70.0, 1500, &fb); });
    fa = kFlagReady | (1 << 1);                    // A is ready on Normal
    fb = kFlagReady | (1 << 1) | kFlagSeesReady;  // B is ready and can see that A is
    std::this_thread::sleep_for(milliseconds(500));
    {
        double v = -1;
        json_num(read_text(cb.data_dir / "re7mp_in.json"), "flags", v);
        CHECK(static_cast<int>(v) == (kFlagReady | (1 << 1)));  // B sees exactly A's flags
        json_num(read_text(ca.data_dir / "re7mp_in.json"), "flags", v);
        CHECK(static_cast<int>(v) == (kFlagReady | (1 << 1) | kFlagSeesReady));
    }
    g1.join();
    g2.join();

    auto sa = a.status(), sb = b.status();
    std::printf("  network: A(%s) sees B(%s) at x=%.2f z=%.2f; B sees A at x=%.2f z=%.2f\n", sa.remote_name.c_str(),
                sb.remote_name.c_str(), sa.rx, sa.rz, sb.rx, sb.rz);
    CHECK(sa.peer_active && sb.peer_active);
    CHECK(sa.remote_name == "Bob" && sb.remote_name == "Alice");
    CHECK(std::fabs(sa.rx - (-50.0)) < 2 && std::fabs(sa.rz - 70.0) < 0.1);
    CHECK(std::fabs(sb.rx - 10.0) < 2 && std::fabs(sb.rz - 10.0) < 0.1);

    // B received the event exactly once even though A sent it several times.
    auto logb = b.drain_log();
    CHECK(count_lines(logb, "started a new game (Normal)") == 1);
    auto loga = a.drain_log();
    CHECK(count_lines(loga, "received the request") == 1);
    double v;
    auto t = read_text(cb.data_dir / "re7mp_evt_in.json");
    CHECK(json_num(t, "arg", v) && v == 1 && json_num(t, "type", v) && v == 1);
    auto pose = read_text(cb.data_dir / "re7mp_in.json");
    std::string nm;
    CHECK(json_str(pose, "name", nm) && nm == "Alice");

    // Renaming while running reaches the other side.
    a.set_name("Alicia");
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(b.status().remote_name == "Alicia");
    a.stop();
    b.stop();

    // Bad config is reported, not crashed on.
    Config bad;
    bad.data_dir = tmp / "bad";
    bad.mode = Mode::Network;
    Engine c;
    CHECK(!c.start(bad, err) && !err.empty());
}

int main() {
    const fs::path tmp = fs::temp_directory_path() / "re7mp_test_data";
    fs::remove_all(tmp);
    fs::create_directories(tmp);
    test_packets();
    test_locator(tmp);
    test_install(tmp);
    test_bridge(tmp);
    test_loopback(tmp);
    test_network(tmp);
    fs::remove_all(tmp);
    std::printf(g_failed ? "%d check(s) FAILED\n" : "all checks passed\n", g_failed);
    return g_failed ? 1 : 0;
}
