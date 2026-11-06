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
#include <tuple>

#include "bridge.hpp"
#include "engine.hpp"
#include "game_locator.hpp"
#include "json_mini.hpp"
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


// ---- messages / parser / transports ----------------------------------------------------------

using MsgList = std::vector<std::tuple<uint64_t, int, std::string>>;
static std::string json_quote(const std::string& s) {
    std::string o = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        o += c;
    }
    return o + "\"";
}
// What the Lua script does: write the ring of recent messages (id, kind, payload).
static void write_msgs(const fs::path& dir, const MsgList& list) {
    std::string t = "{\"msgs\":[";
    bool first = true;
    for (auto& [id, kind, payload] : list) {
        if (!first) t += ",";
        first = false;
        t += "{\"id\":" + std::to_string(id) + ",\"k\":" + std::to_string(kind) + ",\"p\":" + json_quote(payload) + "}";
    }
    t += "]}";
    write_text(dir / "re7mp_msg_out.json", t);
}
// What the Lua script reads: the payloads of messages of one kind currently in the inbox.
static std::vector<std::string> inbox_payloads(const fs::path& dir, int kind) {
    std::vector<std::string> out;
    mini::Value v;
    if (!mini::parse(read_text(dir / "re7mp_msg_in.json"), v)) return out;
    const mini::Value* msgs = v.get("msgs");
    if (!msgs) return out;
    for (auto& m : msgs->arr) {
        const mini::Value* k = m.get("k");
        const mini::Value* p = m.get("p");
        if (k && p && static_cast<int>(k->num) == kind) out.push_back(p->str);
    }
    return out;
}
static size_t inbox_size(const fs::path& dir) {
    mini::Value v;
    if (!mini::parse(read_text(dir / "re7mp_msg_in.json"), v)) return 0;
    const mini::Value* msgs = v.get("msgs");
    return msgs ? msgs->arr.size() : 0;
}

static void test_json_mini() {
    mini::Value v;
    CHECK(mini::parse("{\"a\":[1,2.5,-3e2,true,false,null],\"s\":\"x\\\"y\\\\z\\n\\u00e9\\ud83d\\ude42\",\"o\":{}}", v));
    const auto* a = v.get("a");
    CHECK(a && a->arr.size() == 6 && a->arr[1].num == 2.5 && a->arr[2].num == -300 && a->arr[3].b && !a->arr[4].b);
    const auto* sv = v.get("s");
    CHECK(sv && sv->str == "x\"y\\z\n\xC3\xA9\xF0\x9F\x99\x82");
    CHECK(mini::parse("  [ ]  ", v) && v.type == mini::Value::Type::Arr);
    CHECK(!mini::parse("{\"a\":1", v));            // half-written
    CHECK(!mini::parse("{\"a\":1} x", v));         // trailing garbage
    CHECK(!mini::parse("{\"a\" 1}", v));
    CHECK(!mini::parse("\"unterminated", v));
    CHECK(!mini::parse("[1,,2]", v));
    std::string deep(40, '[');
    CHECK(!mini::parse(deep, v));                  // depth limit, no stack blowup
}

static void test_message_packets() {
    uint8_t buf[sizeof(MessageFixed) + kMaxPayloadBytes];
    const size_t n = encode_message(buf, 7, 42, 3, "hello \xC3\xA9");
    CHECK(n == sizeof(MessageFixed) + 8);
    uint32_t s, id;
    uint16_t k;
    std::string p;
    CHECK(decode_message(buf, n, s, id, k, p) && s == 7 && id == 42 && k == 3 && p == "hello \xC3\xA9");
    CHECK(!decode_message(buf, n - 1, s, id, k, p));   // truncated
    CHECK(!decode_message(buf, n + 1, s, id, k, p));   // trailing byte
    CHECK(encode_message(buf, 1, 1, 1, std::string(kMaxPayloadBytes + 1, 'x')) == 0);  // too long
    CHECK(encode_message(buf, 1, 1, 1, std::string("a\nb")) == 0);                     // control character
    CHECK(encode_message(buf, 1, 1, 1, std::string("\xff")) == 0);                     // invalid UTF-8
    CHECK(encode_message(buf, 1, 1, 1, std::string(kMaxPayloadBytes, 'x')) == sizeof(MessageFixed) + kMaxPayloadBytes);
    auto ak = make_message_ack(1, 9);
    AckPacket a2;
    CHECK(decode_message_ack(&ak, sizeof(ak), a2) && a2.id == 9);
    CHECK(!decode_ack(&ak, sizeof(ak), a2));  // not an event ack
}

static void test_bridge_messages(const fs::path& tmp) {
    const fs::path d = tmp / "bridge_msgs";
    FileBridge b(d);
    std::vector<LocalMessage> v;
    CHECK(!b.poll_messages(v));
    write_text(d / "re7mp_msg_out.json", "{\"msgs\":[{\"id\":5,\"k\":1,\"p\":\"he");  // half-written
    CHECK(!b.poll_messages(v));
    write_msgs(d, {{5, 1, "hello \"quoted\" \\ ok"}, {6, 2, "1.0;2.0;3.0"}});
    CHECK(b.poll_messages(v) && v.size() == 2 && v[0].lua_id == 5 && v[0].payload == "hello \"quoted\" \\ ok" &&
          v[1].kind == 2);
    CHECK(!b.poll_messages(v));  // unchanged
    // The ring still contains the old ones; only the new one comes back.
    write_msgs(d, {{5, 1, "hello \"quoted\" \\ ok"}, {6, 2, "1.0;2.0;3.0"}, {7, 1, "third"}});
    CHECK(b.poll_messages(v) && v.size() == 1 && v[0].lua_id == 7 && v[0].payload == "third");
    // A bad payload is skipped, not retried forever.
    write_text(d / "re7mp_msg_out.json", "{\"msgs\":[{\"id\":8,\"k\":1,\"p\":\"a\\u0001b\"},{\"id\":9,\"k\":1,\"p\":\"fine\"}]}");
    CHECK(b.poll_messages(v) && v.size() == 1 && v[0].payload == "fine");
    std::vector<InMessage> in;
    InMessage m;
    m.n = 1; m.id = 10; m.kind = 1; m.payload = "he said \"hi\"";
    in.push_back(m);
    CHECK(b.publish_messages(77, in));
    mini::Value jv;
    CHECK(mini::parse(read_text(d / "re7mp_msg_in.json"), jv) && jv.get("epoch")->num == 77 &&
          jv.get("msgs")->arr.size() == 1 && jv.get("msgs")->arr[0].get("p")->str == "he said \"hi\"");
}

static void test_stationary_bot(const fs::path& tmp) {
    const fs::path dir = tmp / "stationary";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.listen_port = 28951;
    cfg.bot_mode = BotMode::Stationary;
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::atomic<int> flags{0};
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 3200, &flags); });
    auto in_xz = [&] {
        double x = 0, z = 0;
        auto t = read_text(dir / "re7mp_in.json");
        json_num(t, "x", x);
        json_num(t, "z", z);
        return std::make_pair(x, z);
    };
    std::this_thread::sleep_for(milliseconds(700));
    auto p1 = in_xz();
    std::this_thread::sleep_for(milliseconds(900));
    auto p2 = in_xz();
    auto s = e.status();
    std::printf("  stationary: bot at (%.2f, %.2f) then (%.2f, %.2f); you at x=%.2f\n", p1.first, p1.second, p2.first,
                p2.second, s.lx);
    CHECK(std::fabs(p1.first - p2.first) < 1e-3 && std::fabs(p1.second - p2.second) < 1e-3);  // it did not move
    CHECK(std::fabs(p1.second - 200.0) < 0.01 && p1.first > 99.9 && p1.first < 100.5);        // parked where you were
    double qy;
    CHECK(json_num(read_text(dir / "re7mp_in.json"), "qy", qy) && std::fabs(qy - 0.6) < 1e-3);  // still copies rotation
    // "Move bot to me" teleports it to where you are now.
    e.teleport_bot_here();
    std::this_thread::sleep_for(milliseconds(400));
    auto p3 = in_xz();
    s = e.status();
    CHECK(std::fabs(p3.first - s.lx) < 0.3 && p3.first > p2.first);
    // Switching back to orbit moves it again; switching to stationary parks it again.
    e.set_bot_mode(BotMode::Orbit);
    std::this_thread::sleep_for(milliseconds(300));
    auto p4 = in_xz();
    std::this_thread::sleep_for(milliseconds(400));
    auto p5 = in_xz();
    CHECK(std::fabs(p4.first - p5.first) + std::fabs(p4.second - p5.second) > 0.1);
    g.join();
    e.stop();
}

static void test_loopback_messages_and_tcp(const fs::path& tmp, Transport transport, uint16_t port, const char* label) {
    const fs::path dir = tmp / (std::string("lbm_") + label);
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.transport = transport;
    cfg.listen_port = port;
    cfg.name = "Tester";
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::atomic<int> flags{0};
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 2600, &flags); });
    std::this_thread::sleep_for(milliseconds(900));  // TCP needs a moment to connect
    write_msgs(dir, {{1, 1, "hello bot"}});
    std::this_thread::sleep_for(milliseconds(500));
    auto chat = inbox_payloads(dir, 1);
    CHECK(chat.size() == 1 && chat[0] == "echo: hello bot");
    write_msgs(dir, {{1, 1, "hello bot"}, {2, 2, "10.00;1.50;-4.25"}});
    std::this_thread::sleep_for(milliseconds(500));
    auto pings = inbox_payloads(dir, 2);
    CHECK(pings.size() == 1 && pings[0] == "10.00;1.50;-4.25");
    CHECK(inbox_payloads(dir, 1).size() == 1);  // the first message was not sent a second time
    CHECK(inbox_size(dir) == 2);
    g.join();
    auto s = e.status();
    std::printf("  %s loopback: sent=%llu recv=%llu msgs sent=%llu recv=%llu\n", label, (unsigned long long)s.sent,
                (unsigned long long)s.received, (unsigned long long)s.messages_sent,
                (unsigned long long)s.messages_received);
    CHECK(s.game_hooked && s.peer_active && s.remote_name == "Loopback Bot");
    CHECK(s.messages_sent == 2 && s.messages_received == 2);
    auto log = e.drain_log();
    CHECK(count_lines(log, "never confirmed") == 0);
    if (transport != Transport::Udp) CHECK(count_lines(log, "TCP: connected to the host") == 1);
    e.stop();
}

static void test_tcp_network(const fs::path& tmp) {
    Engine host, join;
    Config ch, cj;
    ch.data_dir = tmp / "tcp_host";
    cj.data_dir = tmp / "tcp_join";
    ch.mode = cj.mode = Mode::Network;
    ch.transport = Transport::TcpHost;
    cj.transport = Transport::TcpJoin;
    ch.listen_port = 28941;
    cj.peer_host = "127.0.0.1";
    cj.peer_port = 28941;
    ch.name = "Hosty";
    cj.name = "Joiny";
    std::string err;
    CHECK(host.start(ch, err));
    std::atomic<int> fa{0}, fb{kFlagReady | (2 << 1)};
    std::thread g1([&] { fake_game(ch.data_dir, 10.0, 10.0, 3800, &fa); });
    std::thread g2([&] { fake_game(cj.data_dir, -50.0, 70.0, 3800, &fb); });
    std::this_thread::sleep_for(milliseconds(400));
    CHECK(join.start(cj, err));  // the joiner starts after the host and connects on its own
    std::this_thread::sleep_for(milliseconds(1800));
    auto sh = host.status(), sj = join.status();
    std::printf("  tcp: host sees %s at x=%.2f, joiner sees %s at x=%.2f\n", sh.remote_name.c_str(), sh.rx,
                sj.remote_name.c_str(), sj.rx);
    CHECK(sh.peer_active && sj.peer_active && sh.remote_name == "Joiny" && sj.remote_name == "Hosty");
    CHECK(std::fabs(sh.rx - (-50.0)) < 2 && std::fabs(sj.rx - 10.0) < 2);
    double v = -1;
    json_num(read_text(ch.data_dir / "re7mp_in.json"), "flags", v);
    CHECK(static_cast<int>(v) == (kFlagReady | (2 << 1)));  // ready flags cross over TCP too

    // Reliable messages both ways.
    write_msgs(ch.data_dir, {{1, 1, "from host"}});
    write_msgs(cj.data_dir, {{1, 1, "from joiner"}});
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(inbox_payloads(join.status().running ? cj.data_dir : cj.data_dir, 1) == std::vector<std::string>{"from host"});
    CHECK(inbox_payloads(ch.data_dir, 1) == std::vector<std::string>{"from joiner"});

    // The host goes away and comes back: the joiner reconnects by itself.
    host.stop();
    std::this_thread::sleep_for(milliseconds(300));
    CHECK(host.start(ch, err));
    std::this_thread::sleep_for(milliseconds(2200));
    sh = host.status();
    sj = join.status();
    CHECK(sh.peer_active && sj.peer_active);
    auto logj = join.drain_log();
    CHECK(count_lines(logj, "TCP connection lost") >= 1 && count_lines(logj, "TCP: connected to the host") >= 2);
    g1.join();
    g2.join();
    host.stop();
    join.stop();

    // A host that only allows one address ignores everyone else.
    Config restricted = ch;
    restricted.data_dir = tmp / "tcp_restricted";
    restricted.peer_host = "127.0.0.2";  // not who will connect (we connect from 127.0.0.1)
    restricted.listen_port = 28943;
    Config c3 = cj;
    c3.data_dir = tmp / "tcp_restricted_join";
    c3.peer_port = 28943;
    Engine r, j3;
    CHECK(r.start(restricted, err) && j3.start(c3, err));
    std::thread g3([&] { fake_game(restricted.data_dir, 0, 0, 1500, nullptr); });
    std::thread g4([&] { fake_game(c3.data_dir, 5, 5, 1500, nullptr); });
    g3.join();
    g4.join();
    CHECK(!r.status().peer_active && !j3.status().peer_active);
    r.stop();
    j3.stop();
}

static void test_message_retransmission(const fs::path& tmp) {
    Engine a, b;
    Config ca, cb;
    ca.data_dir = tmp / "mr_a";
    cb.data_dir = tmp / "mr_b";
    ca.mode = cb.mode = Mode::Network;
    ca.listen_port = 28961;
    ca.peer_host = "127.0.0.1";
    ca.peer_port = 28962;
    cb.listen_port = 28962;
    cb.peer_host = "127.0.0.1";
    cb.peer_port = 28961;
    std::string err;
    CHECK(a.start(ca, err));
    std::this_thread::sleep_for(milliseconds(200));
    write_msgs(ca.data_dir, {{1, 7, "sent before B existed"}});
    std::this_thread::sleep_for(milliseconds(1000));
    CHECK(b.start(cb, err));  // B appears late: A keeps resending until B acks
    std::this_thread::sleep_for(milliseconds(1200));
    auto got = inbox_payloads(cb.data_dir, 7);
    CHECK(got.size() == 1 && got[0] == "sent before B existed");  // delivered exactly once despite resends
    auto loga = a.drain_log();
    CHECK(count_lines(loga, "never confirmed") == 0);
    a.stop();
    b.stop();
}

int main() {
    const fs::path tmp = fs::temp_directory_path() / "re7mp_test_data";
    fs::remove_all(tmp);
    fs::create_directories(tmp);
    test_packets();
    test_json_mini();
    test_message_packets();
    test_locator(tmp);
    test_install(tmp);
    test_bridge(tmp);
    test_bridge_messages(tmp);
    test_loopback(tmp);
    test_network(tmp);
    test_stationary_bot(tmp);
    test_loopback_messages_and_tcp(tmp, Transport::Udp, 28971, "udp");
    test_loopback_messages_and_tcp(tmp, Transport::TcpHost, 28975, "tcp");
    test_tcp_network(tmp);
    test_message_retransmission(tmp);
    fs::remove_all(tmp);
    std::printf(g_failed ? "%d check(s) FAILED\n" : "all checks passed\n", g_failed);
    return g_failed ? 1 : 0;
}
