// Core tests: no game or GUI needed. Build target: re7mp_tests
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <regex>
#include <sstream>
#include <thread>
#include <tuple>

#include "bot_logic.hpp"
#include "bridge.hpp"
#include "character.hpp"
#include "engine.hpp"
#include "game_locator.hpp"
#include "json_mini.hpp"
#include "packet.hpp"
#include "save_resign.hpp"
#include "save_sync.hpp"
#include "story_sync.hpp"
#include "updater.hpp"
#include "version.hpp"
#include "zip_extract.hpp"

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
    // The built-in clips and settings: written to reframework/data/re7mp/defaults.json, replaced when the release has a newer one, left alone when equal.
    auto d1 = install_defaults(game, "{\"format\":1,\"clips\":{}}");
    CHECK(d1.ok && d1.changed);
    CHECK(read_text(game / "reframework" / "data" / "re7mp" / "defaults.json") == "{\"format\":1,\"clips\":{}}");
    auto d2 = install_defaults(game, "{\"format\":1,\"clips\":{}}");
    CHECK(d2.ok && !d2.changed);
    auto d3 = install_defaults(game, "{\"format\":1,\"clips\":{\"idle\":{}}}");
    CHECK(d3.ok && d3.changed && d3.message.find("Updated") == 0);
    CHECK(read_text(game / "reframework" / "data" / "re7mp" / "defaults.json") == "{\"format\":1,\"clips\":{\"idle\":{}}}");
    // the player's own files next to it are never touched
    write_text(game / "reframework" / "data" / "re7mp" / "clips" / "idle.json", "mine");
    write_text(game / "reframework" / "data" / "re7mp_settings.json", "mine too");
    install_defaults(game, "{\"format\":1}");
    CHECK(read_text(game / "reframework" / "data" / "re7mp" / "clips" / "idle.json") == "mine");
    CHECK(read_text(game / "reframework" / "data" / "re7mp_settings.json") == "mine too");
    // and the script install still works after the refactor, with the folder missing
    const fs::path game2 = tmp / "game2";
    CHECK(install_lua(game2 / "nope" / "x", "a").ok);
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
    CHECK(b.publish_remote(rp, 4, "Ann \"The Boss\" \\o/", "tcp"));
    auto t = read_text(d / "re7mp_in.json");
    double v;
    std::string name;
    CHECK(json_num(t, "seq", v) && v == 5 && json_num(t, "z", v) && v == 3 && json_num(t, "qy", v) && v == 0.5 &&
          json_num(t, "flags", v) && v == 29);
    CHECK(json_str(t, "name", name) && name == "Ann \\\"The Boss\\\" \\\\o/");
    std::string tr;
    CHECK(json_str(t, "transport", tr) && tr == "tcp");
    // The exe's release number and protocol version go to the script with every remote pose.
    std::string exe_ver;
    CHECK(json_str(t, "exe", exe_ver) && exe_ver == kReleaseVersion);
    CHECK(json_num(t, "proto", v) && static_cast<int>(v) == static_cast<int>(kProtocolVersion));
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
    auto in_flags = [&] {  // (the bot's pose bits come and go on a timer: the ready check does not look at them)
        double v = -1;
        json_num(in_json(), "flags", v);
        return static_cast<int>(v) & ~static_cast<int>(kFlagPoseMask);
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
    ca.transport = Transport::TcpHost;
    cb.transport = Transport::TcpJoin;
    ca.listen_port = 28931;
    ca.name = "Alice";
    cb.peer_host = "127.0.0.1";
    cb.peer_port = 28931;
    cb.name = "Bob";
    std::string err;
    CHECK(a.start(ca, err));
    // B starts late: A's event must be kept (and resent) until B has connected and acked it.
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
    bad.transport = Transport::TcpJoin;  // joining without the host's address
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

// ---- (9.13) the loopback bot answers gifts and drops, and can go down and be revived ----
static void test_bot_logic_units() {
    CHECK(bot_answer_gift("Herb|2") == "g|Herb|2|ok|the loopback bot took it");
    CHECK(bot_answer_gift("Herb|0").empty() && bot_answer_gift("Herb").empty() && bot_answer_gift("He rb|1").empty() &&
          bot_answer_gift("Herb|1000").empty() && bot_answer_gift("Herb|1|2").empty() && bot_answer_gift("|1").empty() &&
          bot_answer_gift("Herb|-1").empty() && bot_answer_gift("Herb|1x").empty());
    CHECK(bot_answer_drop("Coin|1|1.00|0.00|-2.50") == "d|Coin|1|ok|the loopback bot sees it on the ground");
    CHECK(bot_answer_drop("Coin|1|x|0|0").empty() && bot_answer_drop("Coin|1|1|2").empty() && bot_answer_drop("Coin|0|1|2|3").empty() &&
          bot_answer_drop("Co in|1|1|2|3").empty() && bot_answer_drop("Coin|1|1|2|nan").empty());
    BotEvent e;
    CHECK(bot_parse_event("e|heal|Herb|1.00|1.60|-0.50", e) && e.kind == "heal" && e.arg == "Herb" && e.x == 1.0 && e.y == 1.6 &&
          e.z == -0.5 && bot_is_healing(e));
    CHECK(bot_parse_event("e|use|RemedyM|0|0|0", e) && bot_is_healing(e));
    CHECK(bot_parse_event("e|revive|Herb|0|0|0", e) && bot_is_healing(e));
    CHECK(bot_parse_event("e|down||1|2|3", e) && e.arg.empty() && !bot_is_healing(e));
    CHECK(!bot_parse_event("h|600|1000|0", e) && !bot_parse_event("e|heal|Herb|1|2", e) && !bot_parse_event("e|he4l|Herb|1|2|3", e) &&
          !bot_parse_event("e||Herb|1|2|3", e) && !bot_parse_event("e|heal|Herb|1|nan|3", e) && !bot_parse_event("x|heal|Herb|1|2|3", e));
    CHECK(bot_event_text("down", 1.0, 2.0, 3.0) == "e|down||1.00|2.00|3.00");
    CHECK(bot_event_text("up", -1.5, 0.0, 10.25) == "e|up||-1.50|0.00|10.25");
    CHECK(bot_health_text(true) == "h|1|1000|1" && bot_health_text(false) == "h|1000|1000|0");
    CHECK(bot_command("down") == 1 && bot_command("up") == 0 && bot_command("sideways") == -1 && bot_command("") == -1);
    CHECK(std::fabs(bot_distance(0, 0, 0, 3, 4, 0) - 5.0) < 1e-9);
    // (9.33) the bot can say which character it is: "char:ethan|mia|clancy" sets it, "char:none" takes it back, nothing else counts
    {
        std::string ck = "stale";
        CHECK(bot_character_command("char:clancy", ck) == 1 && ck == "clancy");
        CHECK(bot_character_command("char:pete", ck) == 1 && ck == "pete" && bot_character_command("char:andre", ck) == 1 && ck == "andre");  // 9.37
        CHECK(bot_character_command("char:mia", ck) == 1 && ck == "mia");
        CHECK(bot_character_command("char:ethan", ck) == 1 && ck == "ethan");
        CHECK(bot_character_command("char:none", ck) == 2 && ck.empty());
        CHECK(bot_character_command("char:", ck) == 0 && ck.empty());
        CHECK(bot_character_command("char:jack", ck) == 0 && ck.empty());
        CHECK(bot_character_command("char:Clancy", ck) == 0);
        CHECK(bot_character_command("down", ck) == 0 && bot_character_command("up", ck) == 0 && bot_character_command("", ck) == 0);
        CHECK(bot_character_command("char:clancy|x", ck) == 0 && bot_character_command("xchar:clancy", ck) == 0);
        CHECK(bot_command("char:clancy") == -1 && bot_command("char:none") == -1);  // a character command is not a down / up command
        CHECK(bot_character_text("clancy", 1.0, 2.5, -3.0) == "e|char|clancy|1.00|2.50|-3.00");
        BotEvent ce;
        CHECK(bot_parse_event(bot_character_text("mia", 0.0, 0.0, 0.0), ce) && ce.kind == "char" && ce.arg == "mia" && !bot_is_healing(ce) && bot_ff_damage(ce) == 0);
    }
    // the script's revive radius is 3 m since 9.14; the bot allows the same slack (x1.25) the script does
    CHECK(kBotReviveRadius == 3.75 && bot_heal_reaches(3.0) && bot_heal_reaches(3.75) && !bot_heal_reaches(3.76) && !bot_heal_reaches(5.0));
    // (9.33) friendly fire on the bot: the damage of an "ff" event (1..600), what is left, and the health report
    CHECK(bot_parse_event("e|ff|100|1.00|2.00|3.00", e) && e.kind == "ff" && bot_ff_damage(e) == 100 && !bot_is_healing(e));
    CHECK(bot_parse_event("e|ff|1|0|0|0", e) && bot_ff_damage(e) == 1);
    CHECK(bot_parse_event("e|ff|600|0|0|0", e) && bot_ff_damage(e) == 600);
    CHECK(bot_parse_event("e|ff|601|0|0|0", e) && bot_ff_damage(e) == 0);
    CHECK(bot_parse_event("e|ff|0|0|0|0", e) && bot_ff_damage(e) == 0);
    CHECK(bot_parse_event("e|ff|abc|0|0|0", e) && bot_ff_damage(e) == 0);
    CHECK(bot_parse_event("e|ff||0|0|0", e) && bot_ff_damage(e) == 0);
    CHECK(bot_parse_event("e|heal|100|0|0|0", e) && bot_ff_damage(e) == 0);  // only an "ff" event is a hit
    CHECK(bot_apply_damage(1000, 100) == 900 && bot_apply_damage(900, 899) == 1 && bot_apply_damage(900, 900) == 1 &&
          bot_apply_damage(5, 600) == 1 && bot_apply_damage(1, 1) == 1);
    CHECK(bot_health_text_hp(900) == "h|900|1000|0" && bot_health_text_hp(1000) == bot_health_text(false));
}

static bool any_with_prefix(const std::vector<std::string>& v, const std::string& prefix) {
    for (const auto& s : v) {
        if (s.compare(0, prefix.size(), prefix) == 0) return true;
    }
    return false;
}
static int count_with_prefix(const std::vector<std::string>& v, const std::string& prefix) {
    int n = 0;
    for (const auto& s : v) {
        if (s.compare(0, prefix.size(), prefix) == 0) ++n;
    }
    return n;
}

static void test_bot_gifts_and_down(const fs::path& tmp) {
    const fs::path dir = tmp / "bot913";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.transport = Transport::TcpHost;
    cfg.listen_port = 28983;
    cfg.name = "Tester";
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 8200); });
    std::this_thread::sleep_for(milliseconds(900));
    auto bot_at = [&](double& x, double& y, double& z) {
        const std::string t = read_text(dir / "re7mp_in.json");
        return json_num(t, "x", x) && json_num(t, "y", y) && json_num(t, "z", z);
    };
    // a gift and a drop are answered; a damaged one is not
    MsgList sent = {{1, 5, "Herb|2"}, {2, 6, "Coin|1|1.00|0.00|2.00"}, {3, 5, "garbage"}};
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(600));
    auto answers = inbox_payloads(dir, 10);
    CHECK(answers.size() == 2 && answers[0] == "g|Herb|2|ok|the loopback bot took it" && any_with_prefix(answers, "d|Coin|1|ok|"));
    // it goes down: it says so, and stays where it fell
    sent.push_back({4, 11, "down"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(700));
    auto health = inbox_payloads(dir, 7);
    CHECK(any_with_prefix(health, "e|down||") && any_with_prefix(health, "h|1|1000|1"));
    double x1 = 0, y1 = 0, z1 = 0, x2 = 0, y2 = 0, z2 = 0;
    CHECK(bot_at(x1, y1, z1));
    std::this_thread::sleep_for(milliseconds(400));
    CHECK(bot_at(x2, y2, z2) && x1 == x2 && y1 == y2 && z1 == z2);
    // a heal from far away does nothing; one next to it gets it up, and it walks again
    sent.push_back({5, 7, "e|heal|Herb|0.00|0.00|0.00"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(!any_with_prefix(inbox_payloads(dir, 7), "e|up||"));
    char heal[120];
    std::snprintf(heal, sizeof(heal), "e|heal|Herb|%.2f|%.2f|%.2f", x2 + 1.0, y2, z2);
    sent.push_back({6, 7, heal});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(700));
    health = inbox_payloads(dir, 7);
    CHECK(count_with_prefix(health, "e|up||") == 1 && any_with_prefix(health, "h|1000|1000|0"));
    CHECK(bot_at(x1, y1, z1));
    std::this_thread::sleep_for(milliseconds(300));
    CHECK(bot_at(x2, y2, z2) && (x1 != x2 || z1 != z2));
    // told to go down and then to get up
    sent.push_back({7, 11, "down"});
    sent.push_back({8, 11, "sideways"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(count_with_prefix(inbox_payloads(dir, 7), "e|down||") == 2);
    sent.push_back({9, 11, "up"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(count_with_prefix(inbox_payloads(dir, 7), "e|up||") == 2);
    g.join();
    e.stop();
}

// (9.33) the loopback bot takes friendly fire: each hit takes health off and is reported at once; at 1 it goes down; a heal next to it gets it up
static void test_bot_friendly_fire(const fs::path& tmp) {
    const fs::path dir = tmp / "bot933ff";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.transport = Transport::TcpHost;
    cfg.listen_port = 28985;
    cfg.name = "Tester";
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 9000); });
    std::this_thread::sleep_for(milliseconds(900));
    auto bot_at = [&](double& x, double& y, double& z) {
        const std::string t = read_text(dir / "re7mp_in.json");
        return json_num(t, "x", x) && json_num(t, "y", y) && json_num(t, "z", z);
    };
    MsgList sent = {{1, 7, "e|ff|100|0.00|0.00|0.00"}};
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(600));
    auto health = inbox_payloads(dir, 7);
    CHECK(any_with_prefix(health, "h|900|1000|0"));
    // damaged or out-of-range numbers do nothing
    sent.push_back({2, 7, "e|ff|0|0.00|0.00|0.00"});
    sent.push_back({3, 7, "e|ff|601|0.00|0.00|0.00"});
    sent.push_back({4, 7, "e|ff|abc|0.00|0.00|0.00"});
    sent.push_back({5, 7, "e|ff|250|0.00|0.00|0.00"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(600));
    health = inbox_payloads(dir, 7);
    CHECK(any_with_prefix(health, "h|650|1000|0") && !any_with_prefix(health, "h|900|1000|0|x"));
    CHECK(count_with_prefix(health, "h|650|1000|0") == 1);
    CHECK(!any_with_prefix(health, "e|down||"));
    // "up" heals a bot that was shot but is standing
    sent.push_back({6, 11, "up"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(500));
    health = inbox_payloads(dir, 7);
    CHECK(any_with_prefix(health, "h|1000|1000|0") && !any_with_prefix(health, "e|up||"));
    // a hit that would take everything leaves 1 and puts it down, where it stands
    sent.push_back({7, 7, "e|ff|600|0.00|0.00|0.00"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(300));
    sent.push_back({8, 7, "e|ff|600|0.00|0.00|0.00"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(700));
    health = inbox_payloads(dir, 7);
    CHECK(count_with_prefix(health, "e|down||") == 1 && any_with_prefix(health, "h|1|1000|1"));
    double x1 = 0, y1 = 0, z1 = 0, x2 = 0, y2 = 0, z2 = 0;
    CHECK(bot_at(x1, y1, z1));
    // a hit while down changes nothing: no second "down", no new health number (the earlier ones are still in the ring,
    // each once), and the last report is still "1 of 1000, down"
    sent.push_back({9, 7, "e|ff|100|0.00|0.00|0.00"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(600));
    health = inbox_payloads(dir, 7);
    CHECK(count_with_prefix(health, "e|down||") == 1);
    CHECK(count_with_prefix(health, "h|900|1000|0") == 1 && count_with_prefix(health, "h|400|1000|0") == 1);
    std::string last_h;
    for (const auto& m : health) {
        if (m.compare(0, 2, "h|") == 0) last_h = m;
    }
    CHECK(last_h == "h|1|1000|1");
    CHECK(bot_at(x2, y2, z2) && x1 == x2 && y1 == y2 && z1 == z2);
    // a heal next to it gets it up at full health
    char heal[120];
    std::snprintf(heal, sizeof(heal), "e|heal|Herb|%.2f|%.2f|%.2f", x2 + 1.0, y2, z2);
    sent.push_back({10, 7, heal});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(700));
    health = inbox_payloads(dir, 7);
    CHECK(count_with_prefix(health, "e|up||") == 1 && any_with_prefix(health, "h|1000|1000|0"));
    g.join();
    e.stop();
}

// (9.33) The loopback bot says which character it is, when it is told to (so the body made from Mia's or Clancy's files can be tried alone).
static void test_bot_character(const fs::path& tmp) {
    const fs::path dir = tmp / "bot933char";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.transport = Transport::TcpHost;
    cfg.listen_port = 28989;
    cfg.name = "Tester";
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 9000); });
    std::this_thread::sleep_for(milliseconds(900));
    // it said nothing about a character before it was told to
    auto health = inbox_payloads(dir, 7);
    CHECK(!any_with_prefix(health, "e|char|"));
    MsgList sent = {{1, 11, "char:clancy"}};
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(700));
    health = inbox_payloads(dir, 7);
    CHECK(count_with_prefix(health, "e|char|clancy|") == 1);
    // the same command again changes nothing (the script repeats it now and then): no second report this soon
    sent.push_back({2, 11, "char:clancy"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(600));
    health = inbox_payloads(dir, 7);
    CHECK(count_with_prefix(health, "e|char|clancy|") == 1);
    // another character goes out at once
    sent.push_back({3, 11, "char:mia"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(700));
    health = inbox_payloads(dir, 7);
    CHECK(count_with_prefix(health, "e|char|mia|") == 1 && count_with_prefix(health, "e|char|clancy|") == 1);
    // a key that is none of the three is ignored: the bot is still Mia
    sent.push_back({4, 11, "char:jack"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(500));
    health = inbox_payloads(dir, 7);
    CHECK(!any_with_prefix(health, "e|char|jack|") && count_with_prefix(health, "e|char|mia|") == 1);
    // a character command does not make it go down (it is not a down / up command)
    CHECK(!any_with_prefix(health, "e|down||") && !any_with_prefix(health, "h|1|1000|1"));
    g.join();
    e.stop();
}

// (9.38) The loopback bot does what the script's drop-down says: copy me, or one state at a time.
static void test_bot_act(const fs::path& tmp) {
    // the commands and what each state shows
    BotAct a = BotAct::Timer;
    CHECK(bot_act_command("state:copy", a) && a == BotAct::Copy);
    CHECK(bot_act_command("state:crouchwalk", a) && a == BotAct::CrouchWalk);
    CHECK(bot_act_command("state:timer", a) && a == BotAct::Timer);
    CHECK(!bot_act_command("state:dance", a) && a == BotAct::Timer);  // unknown: nothing changes
    CHECK(!bot_act_command("down", a) && !bot_act_command("char:mia", a) && !bot_act_command("state:", a) && a == BotAct::Timer);
    for (int i = 0; i <= static_cast<int>(BotAct::Shoot); ++i) {  // every key reads back as itself
        BotAct b = BotAct::Timer;
        CHECK(bot_act_command(std::string("state:") + bot_act_key(static_cast<BotAct>(i)), b) && b == static_cast<BotAct>(i));
    }
    std::string ck;
    CHECK(bot_command("state:copy") == -1 && bot_character_command("state:copy", ck) == 0);  // not a down / up or character command
    CHECK(bot_act_flags(BotAct::Idle, 1.0f) == 0 && bot_act_flags(BotAct::Walk, 1.0f) == 0 && bot_act_flags(BotAct::Copy, 1.0f) == 0);
    CHECK(bot_act_flags(BotAct::Crouch, 1.0f) == kFlagPoseCrouch && bot_act_flags(BotAct::CrouchWalk, 1.0f) == kFlagPoseCrouch);
    CHECK(bot_act_flags(BotAct::Guard, 1.0f) == kFlagPoseGuard && bot_act_flags(BotAct::Heal, 1.0f) == kFlagPoseHeal);
    CHECK(bot_act_flags(BotAct::Gun, 1.0f) == kFlagGun && bot_act_flags(BotAct::GunRun, 1.0f) == kFlagGun);
    CHECK(bot_act_flags(BotAct::Aim, 1.0f) == (kFlagGun | kFlagAim));
    CHECK(bot_act_flags(BotAct::Shoot, 0.1f) == (kFlagGun | kFlagAim | kFlagShoot) && bot_act_flags(BotAct::Shoot, 0.6f) == (kFlagGun | kFlagAim) &&
          bot_act_flags(BotAct::Shoot, 1.6f) == (kFlagGun | kFlagAim | kFlagShoot));  // a shot every 1.5 s, the bit up for 0.4 s of it
    CHECK(bot_act_speed(BotAct::Idle) == 0.0f && bot_act_speed(BotAct::Walk) < 2.4f && bot_act_speed(BotAct::Walk) > 0.3f && bot_act_speed(BotAct::Run) > 2.4f);
    CHECK(bot_act_speed(BotAct::Crouch) == 0.0f && bot_act_speed(BotAct::CrouchWalk) > 0.3f && bot_act_speed(BotAct::GunRun) == bot_act_speed(BotAct::Run));
    CHECK(kFlagGun == 1024 && kFlagAim == 2048 && kFlagShoot == 4096 && (kFlagGunMask & kFlagPoseMask) == 0);  // (the script uses the same numbers)

    // in the engine
    const fs::path dir = tmp / "botact";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.transport = Transport::TcpHost;
    cfg.listen_port = 28991;
    cfg.name = "Tester";
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::atomic<int> gflags{0};
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 9500, &gflags); });
    auto bot = [&](double& x, double& z, int& f) {
        double vx = 0, vz = 0, vf = -1;
        const auto t = read_text(dir / "re7mp_in.json");
        json_num(t, "x", vx);
        json_num(t, "z", vz);
        json_num(t, "flags", vf);
        x = vx;
        z = vz;
        f = static_cast<int>(vf);
    };
    double bx = 0, bz = 0;
    int bf = 0;
    std::this_thread::sleep_for(milliseconds(700));
    // copy: it stands kCopyOffsetX from you (you are at x ~ 100.x, z 200) and shows what you show, nothing else
    MsgList sent = {{1, 11, "state:copy"}};
    write_msgs(dir, sent);
    gflags = kFlagPoseGuard | kFlagGun | kFlagAim;
    std::this_thread::sleep_for(milliseconds(700));
    bot(bx, bz, bf);
    auto s = e.status();
    CHECK(std::fabs(bx - (s.lx + kCopyOffsetX)) < 0.6 && std::fabs(bz - 200.0) < 0.05);
    CHECK((bf & (kFlagPoseMask | kFlagGunMask)) == (kFlagPoseGuard | kFlagGun | kFlagAim));
    gflags = kFlagPoseCrouch;
    std::this_thread::sleep_for(milliseconds(400));
    bot(bx, bz, bf);
    CHECK((bf & (kFlagPoseMask | kFlagGunMask)) == kFlagPoseCrouch);  // it follows what you do, as you do it
    gflags = 0;
    std::this_thread::sleep_for(milliseconds(400));
    bot(bx, bz, bf);
    CHECK((bf & (kFlagPoseMask | kFlagGunMask)) == 0);
    // a state: block, standing still (the flags are its own, whatever you do)
    gflags = kFlagPoseHeal;
    sent.push_back({2, 11, "state:guard"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(500));
    bot(bx, bz, bf);
    const double gx = bx, gz = bz;
    CHECK((bf & (kFlagPoseMask | kFlagGunMask)) == kFlagPoseGuard);
    std::this_thread::sleep_for(milliseconds(500));
    bot(bx, bz, bf);
    CHECK(std::fabs(bx - gx) < 1e-3 && std::fabs(bz - gz) < 1e-3);  // it stands
    // aim, then shoot: the shot bit comes and goes
    sent.push_back({3, 11, "state:aim"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(400));
    bot(bx, bz, bf);
    CHECK((bf & kFlagGunMask) == (kFlagGun | kFlagAim));
    sent.push_back({4, 11, "state:shoot"});
    write_msgs(dir, sent);
    bool saw_shot = false, saw_no_shot = false;
    const auto until = std::chrono::steady_clock::now() + milliseconds(3200);
    while (std::chrono::steady_clock::now() < until) {
        bot(bx, bz, bf);
        if (bf & kFlagShoot) saw_shot = true; else saw_no_shot = true;
        CHECK((bf & (kFlagGun | kFlagAim)) == (kFlagGun | kFlagAim));
        std::this_thread::sleep_for(milliseconds(40));
    }
    CHECK(saw_shot && saw_no_shot);
    // walk: it circles at about the walking pace (3 m round a fixed spot), run: faster
    auto pace = [&](double ms) {
        double x0, z0, x1, z1;
        int f0, f1;
        bot(x0, z0, f0);
        std::this_thread::sleep_for(milliseconds(static_cast<int>(ms)));
        bot(x1, z1, f1);
        return std::hypot(x1 - x0, z1 - z0) / (ms / 1000.0);
    };
    sent.push_back({5, 11, "state:walk"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(400));
    const double vw = pace(400);
    CHECK(vw > 0.8 && vw < 2.0);
    sent.push_back({6, 11, "state:run"});
    write_msgs(dir, sent);
    std::this_thread::sleep_for(milliseconds(400));
    const double vr = pace(400);
    CHECK(vr > 3.0 && vr < 6.0);
    std::printf("  bot states: walk %.2f m/s, run %.2f m/s\n", vw, vr);
    // back to the timer: the old behaviour (with the exe's default start of 4 s the loop has begun by now or not: only the 'no copy' is checked)
    sent.push_back({7, 11, "state:timer"});
    write_msgs(dir, sent);
    gflags = kFlagGun;
    std::this_thread::sleep_for(milliseconds(500));
    bot(bx, bz, bf);
    CHECK((bf & kFlagGun) == 0);  // your gun bit is not copied any more
    g.join();
    e.stop();
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

static void test_follow_bot(const fs::path& tmp) {
    // (9.37) the pure step: put next to you at first, a walk when close, a run (never faster than 5 m/s) when far, stops 2 m away, never walks through you
    BotFollow f;
    CHECK(bot_follow_step(f, 100.0f, 200.0f, 0.1f) == 0.0f && f.valid && std::fabs(f.x - 102.5f) < 1e-4 && std::fabs(f.z - 200.0f) < 1e-4);
    const float w = bot_follow_step(f, 100.0f, 200.0f, 0.1f);  // 2.5 m away: over the stop distance by 0.5 m -> 1.3 + 0.45 = 1.75 m/s
    CHECK(std::fabs(w - 0.175f) < 1e-4 && std::fabs(f.x - 102.325f) < 1e-3);
    BotFollow g2;
    g2.valid = true; g2.x = 110.0f; g2.z = 200.0f;
    float min_d = 99.0f;
    for (int i = 0; i < 200; ++i) {
        bot_follow_step(g2, 100.0f, 200.0f, 0.1f);
        const float d = std::sqrt((g2.x - 100.0f) * (g2.x - 100.0f) + (g2.z - 200.0f) * (g2.z - 200.0f));
        if (d < min_d) min_d = d;
    }
    CHECK(min_d >= kFollowStop - 1e-3f && std::fabs(g2.x - (100.0f + kFollowStop)) < 1e-2);  // it arrived and stands there
    CHECK(bot_follow_step(g2, 100.0f, 200.0f, 0.1f) == 0.0f);
    BotFollow far_;
    far_.valid = true; far_.x = 130.0f; far_.z = 200.0f;  // 30 m away: capped at 5 m/s
    CHECK(std::fabs(bot_follow_step(far_, 100.0f, 200.0f, 0.1f) - 0.5f) < 1e-4);
    CHECK(std::fabs(bot_follow_step(far_, 100.0f, 200.0f, 5.0f) - 1.25f) < 1e-4);  // a long frame counts as 0.25 s
    CHECK(bot_follow_step(far_, 100.0f, 200.0f, -1.0f) == 0.0f);
    BotFollow gone;
    gone.valid = true; gone.x = 300.0f; gone.z = 200.0f;  // 200 m away (you went through a door into another area): put next to you
    CHECK(bot_follow_step(gone, 100.0f, 200.0f, 0.1f) == 0.0f && std::fabs(gone.x - 102.5f) < 1e-4);
    // in the engine: it ends up about 2 m from you and stays there; "Move bot to me" puts it next to you again
    const fs::path dir = tmp / "follow";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.listen_port = 28953;
    cfg.bot_mode = BotMode::Follow;
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::atomic<int> flags{0};
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 2600, &flags); });
    auto bot_xz = [&] {
        double x = 0, z = 0;
        auto t = read_text(dir / "re7mp_in.json");
        json_num(t, "x", x);
        json_num(t, "z", z);
        return std::make_pair(x, z);
    };
    std::this_thread::sleep_for(milliseconds(1100));
    auto p1 = bot_xz();
    auto s = e.status();
    const double d1 = std::hypot(p1.first - s.lx, p1.second - 200.0);
    std::printf("  follow: bot at (%.2f, %.2f), you at x=%.2f: %.2f m apart\n", p1.first, p1.second, s.lx, d1);
    CHECK(d1 > 1.8 && d1 < 2.7 && std::fabs(p1.second - 200.0) < 0.05);
    e.teleport_bot_here();
    std::this_thread::sleep_for(milliseconds(300));
    auto p2 = bot_xz();
    s = e.status();
    CHECK(std::hypot(p2.first - s.lx, p2.second - 200.0) < 3.0 && p2.first > p1.first - 0.5);
    e.set_bot_mode(BotMode::Orbit);  // back to circling: it moves around you again
    std::this_thread::sleep_for(milliseconds(300));
    auto p3 = bot_xz();
    std::this_thread::sleep_for(milliseconds(400));
    auto p4 = bot_xz();
    CHECK(std::fabs(p3.first - p4.first) + std::fabs(p3.second - p4.second) > 0.1);
    g.join();
    e.stop();
}

static void test_bot_pose_schedule() {
    // The pure schedule: nothing before the first time, then block 3.5 s, walk, crouch 3 s, walk, heal 3.6 s, walk, round again.
    CHECK(bot_pose_flags(0.0f, 4.0f) == 0 && bot_pose_flags(3.9f, 4.0f) == 0);
    CHECK(bot_pose_flags(4.0f, 4.0f) == kFlagPoseGuard && bot_pose_flags(7.4f, 4.0f) == kFlagPoseGuard);
    CHECK(bot_pose_flags(7.6f, 4.0f) == 0 && bot_pose_flags(8.4f, 4.0f) == 0);
    CHECK(bot_pose_flags(8.6f, 4.0f) == kFlagPoseCrouch && bot_pose_flags(11.4f, 4.0f) == kFlagPoseCrouch);
    CHECK(bot_pose_flags(11.6f, 4.0f) == 0 && bot_pose_flags(12.4f, 4.0f) == 0);
    CHECK(bot_pose_flags(12.6f, 4.0f) == kFlagPoseHeal && bot_pose_flags(16.0f, 4.0f) == kFlagPoseHeal);
    CHECK(bot_pose_flags(16.2f, 4.0f) == 0 && bot_pose_flags(19.9f, 4.0f) == 0);
    CHECK(bot_pose_flags(20.1f, 4.0f) == kFlagPoseGuard && bot_pose_flags(24.7f, 4.0f) == kFlagPoseCrouch &&
          bot_pose_flags(28.6f, 4.0f) == kFlagPoseHeal);                                                   // the loop repeats
    CHECK(bot_pose_flags(5.0f, -1.0f) == 0 && bot_pose_flags(500.0f, -1.0f) == 0);                          // negative = never
    for (float s = 0; s < 120.0f; s += 0.05f) {  // never two bits at once, never anything outside the three pose bits
        const uint16_t f = bot_pose_flags(s, 2.0f);
        CHECK(f == 0 || f == kFlagPoseGuard || f == kFlagPoseHeal || f == kFlagPoseCrouch);
    }
    CHECK(kFlagPoseCrouch == 256 && kFlagPoseMask == (64 | 128 | 256));  // (the Lua script uses the same numbers)
    CHECK((kFlagPoseMask & (kFlagReady | kFlagDiffMask | kFlagSeesReady | kFlagGo | kFlagNoPose)) == 0);  // no clash with the other bits
}

static void test_bot_poses(const fs::path& tmp) {
    // The loopback bot blocks, crouches, then heals, so the stand-in's poses can be watched alone. The first block starts at once.
    const fs::path dir = tmp / "botposes";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.listen_port = 28971;
    cfg.bot_pose_first_s = 0.0f;
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 13500); });
    bool saw_guard = false, saw_heal = false, saw_crouch = false, both = false, in_order = false;
    int ready_bits = 0;
    const auto until = std::chrono::steady_clock::now() + milliseconds(13000);
    while (std::chrono::steady_clock::now() < until) {
        double v = -1;
        json_num(read_text(dir / "re7mp_in.json"), "flags", v);
        const int f = static_cast<int>(v);
        if (f > 0) {
            const int bits = f & kFlagPoseMask;
            if (bits != 0 && (bits & (bits - 1)) != 0) both = true;  // two pose bits in one packet
            if (f & kFlagPoseGuard) saw_guard = true;
            if (f & kFlagPoseCrouch) saw_crouch = true;
            if ((f & kFlagPoseHeal) && saw_crouch && saw_guard) in_order = true;
            if (f & kFlagPoseHeal) saw_heal = true;
            ready_bits |= f & ~static_cast<int>(kFlagPoseMask);
        }
        std::this_thread::sleep_for(milliseconds(50));
    }
    g.join();
    e.stop();
    std::printf("  bot poses: guard=%d crouch=%d heal=%d\n", saw_guard, saw_crouch, saw_heal);
    CHECK(saw_guard && saw_crouch && saw_heal && in_order);  // block, then crouch, then heal
    CHECK(!both);
    CHECK(ready_bits == 0);  // it never claims to be ready: only pose bits were set

    // Switched off: the same run with a negative start shows no pose bits at all.
    const fs::path dir2 = tmp / "botposes_off";
    Engine e2;
    Config c2 = cfg;
    c2.data_dir = dir2;
    c2.listen_port = 28973;
    c2.bot_pose_first_s = -1.0f;
    CHECK(e2.start(c2, err));
    fs::create_directories(dir2);
    std::thread g2([&] { fake_game(dir2, 100.0, 200.0, 2500); });
    bool any = false;
    const auto until2 = std::chrono::steady_clock::now() + milliseconds(2300);
    while (std::chrono::steady_clock::now() < until2) {
        double v = -1;
        json_num(read_text(dir2 / "re7mp_in.json"), "flags", v);
        if (v > 0 && (static_cast<int>(v) & kFlagPoseMask)) any = true;
        std::this_thread::sleep_for(milliseconds(50));
    }
    g2.join();
    e2.stop();
    CHECK(!any);
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
    CHECK(count_lines(log, "TCP: connected to the host") == 1);
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
    ca.transport = Transport::TcpHost;
    cb.transport = Transport::TcpJoin;
    ca.listen_port = 28961;
    cb.peer_host = "127.0.0.1";
    cb.peer_port = 28961;
    std::string err;
    CHECK(a.start(ca, err));
    std::this_thread::sleep_for(milliseconds(200));
    write_msgs(ca.data_dir, {{1, 7, "sent before B existed"}});
    std::this_thread::sleep_for(milliseconds(1000));
    CHECK(b.start(cb, err));  // B appears late: A keeps the message until B has connected and acked it
    std::this_thread::sleep_for(milliseconds(1200));
    auto got = inbox_payloads(cb.data_dir, 7);
    CHECK(got.size() == 1 && got[0] == "sent before B existed");  // delivered exactly once despite resends
    auto loga = a.drain_log();
    CHECK(count_lines(loga, "never confirmed") == 0);
    a.stop();
    b.stop();
}

// ---- enemy snapshots (state blobs) -----------------------------------------------------------

// What the Lua script does: write the latest enemy snapshot.
static void write_state(const fs::path& dir, uint64_t seq, const std::string& payload) {
    write_text(dir / "re7mp_state_out.json", "{\"seq\":" + std::to_string(seq) + ",\"p\":" + json_quote(payload) + "}");
}
// What the Lua script reads: the blob (and its count) currently in re7mp_state_in.json.
static bool read_state(const fs::path& dir, std::string& payload, double* n = nullptr) {
    mini::Value v;
    if (!mini::parse(read_text(dir / "re7mp_state_in.json"), v)) return false;
    const mini::Value* p = v.get("p");
    if (!p) return false;
    payload = p->str;
    if (n) {
        const mini::Value* c = v.get("n");
        *n = c ? c->num : 0;
    }
    return true;
}

static uint16_t& kind_dummy_ref() {
    static uint16_t k = 0;
    return k;
}

static void test_state_packets(const fs::path& tmp) {
    const std::string blob = "Em2000,1.50,0.00,-2.25,0,0.7,0,0.7,820,1,3,12,45.5;Em6100,3.00,0.00,4.00,0,0,0,1,-1,1,0,0,0";
    auto pkt = encode_state(11, 5, blob);
    uint32_t sess = 0, seq = 0;
    std::string out;
    CHECK(pkt.size() == sizeof(StateFixed) + blob.size() && sizeof(StateFixed) == 18);
    CHECK(decode_state(pkt.data(), pkt.size(), sess, seq, out) && sess == 11 && seq == 5 && out == blob);
    CHECK(peek_type(pkt.data(), pkt.size()) == static_cast<int>(PacketType::State));
    CHECK(!decode_state(pkt.data(), pkt.size() - 1, sess, seq, out));    // truncated
    CHECK(!decode_state(pkt.data(), pkt.size() + 1, sess, seq, out));    // trailing byte
    CHECK(encode_state(1, 1, "").empty());                               // nothing to send
    CHECK(encode_state(1, 1, std::string(kMaxStatePayload, 'x')).size() == sizeof(StateFixed) + kMaxStatePayload);
    CHECK(encode_state(1, 1, std::string(kMaxStatePayload + 1, 'x')).empty());  // too long
    CHECK(encode_state(1, 1, std::string("a\nb")).empty());              // control character
    CHECK(encode_state(1, 1, std::string("\xff\xfe")).empty());          // not UTF-8
    auto bad = pkt;
    bad[sizeof(Header) + 4] = 0;  // length 0 in the header
    bad[sizeof(Header) + 5] = 0;
    CHECK(!decode_state(bad.data(), bad.size(), sess, seq, out));
    CHECK(!decode_message(pkt.data(), pkt.size(), sess, seq, kind_dummy_ref(), out));  // a state packet is not a message

    // The bridge: Lua writes the snapshot, the engine polls it once per change and publishes received ones.
    const fs::path d = tmp / "state_bridge";
    fs::create_directories(d);
    FileBridge b(d);
    LocalState ls;
    CHECK(!b.poll_state(ls));  // no file yet
    write_state(d, 1, blob);
    CHECK(b.poll_state(ls) && ls.lua_seq == 1 && ls.payload == blob);
    CHECK(!b.poll_state(ls));  // unchanged
    write_state(d, 2, "Em3000,0,0,0,0,0,0,1,-1,1,0,0,0");
    CHECK(b.poll_state(ls) && ls.lua_seq == 2);
    write_text(d / "re7mp_state_out.json", "{\"seq\":3,\"p\":\"half writ");  // caught mid-write: retried
    CHECK(!b.poll_state(ls));
    write_state(d, 3, "x,y\nz");  // control character in the payload: refused
    CHECK(!b.poll_state(ls));
    write_state(d, 4, "ok");
    CHECK(b.poll_state(ls) && ls.lua_seq == 4);
    CHECK(b.publish_state(77, 3, "quote\" and \\ slash"));
    std::string got;
    double n = 0;
    CHECK(read_state(d, got, &n) && got == "quote\" and \\ slash" && n == 3);
    b.clear_stale();
    CHECK(!fs::exists(d / "re7mp_state_in.json") && !fs::exists(d / "re7mp_state_out.json"));
}

// Two engines over TCP: the host's snapshot reaches the joiner (latest wins).
static void test_state_over_tcp(const fs::path& tmp) {
    Engine host, join;
    Config ch, cj;
    ch.data_dir = tmp / "st_host";
    cj.data_dir = tmp / "st_join";
    ch.mode = cj.mode = Mode::Network;
    ch.transport = Transport::TcpHost;
    cj.transport = Transport::TcpJoin;
    ch.listen_port = 28981;
    cj.peer_host = "127.0.0.1";
    cj.peer_port = 28981;
    std::string err;
    CHECK(host.start(ch, err) && join.start(cj, err));
    std::thread g1([&] { fake_game(ch.data_dir, 0, 0, 2800, nullptr); });
    std::thread g2([&] { fake_game(cj.data_dir, 5, 5, 2800, nullptr); });
    std::this_thread::sleep_for(milliseconds(1300));  // connected
    const std::string a = "Em2000,1.00,0.00,2.00,0,0,0,1,500,1,0,0,0";
    const std::string b = "Em2000,1.50,0.00,2.50,0,0,0,1,480,1,0,0,0;Em3000,9.00,0.00,9.00,0,0,0,1,-1,1,0,0,0";
    write_state(ch.data_dir, 1, a);
    std::this_thread::sleep_for(milliseconds(300));
    std::string got;
    double n = 0;
    CHECK(read_state(cj.data_dir, got, &n) && got == a && n == 1);
    write_state(ch.data_dir, 2, b);
    std::this_thread::sleep_for(milliseconds(300));
    CHECK(read_state(cj.data_dir, got, &n) && got == b && n == 2);
    CHECK(!fs::exists(ch.data_dir / "re7mp_state_in.json"));  // the host received nothing, so nothing was published
    g1.join();
    g2.join();
    CHECK(host.status().states_sent == 2 && join.status().states_received == 2 && join.status().states_sent == 0);
    host.stop();
    join.stop();
}

// ---- saves -----------------------------------------------------------------------------------

static std::vector<uint8_t> random_bytes(size_t n, uint32_t seed) {
    std::vector<uint8_t> v(n);
    uint32_t x = seed * 2654435761u + 1;
    for (auto& b : v) {
        x = x * 1664525u + 1013904223u;
        b = static_cast<uint8_t>(x >> 24);
    }
    return v;
}
static void write_bytes(const fs::path& p, const std::vector<uint8_t>& v) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    f.write(reinterpret_cast<const char*>(v.data()), static_cast<std::streamsize>(v.size()));
}
static std::vector<uint8_t> read_bytes(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

static void test_file_packets() {
    CHECK(crc32("123456789", 9) == 0xCBF43926u);
    const auto data = random_bytes(5000, 1);
    auto b = encode_file_begin(7, 3, 5000, crc32(data.data(), data.size()), 12, "CO-OP Alice 2026-11-06 21:04");
    uint32_t id, total, crc;
    uint16_t slot;
    std::string label;
    CHECK(decode_file_begin(b.data(), b.size(), id, total, crc, slot, label) && id == 3 && total == 5000 && slot == 12 &&
          label == "CO-OP Alice 2026-11-06 21:04");
    CHECK(!decode_file_begin(b.data(), b.size() - 1, id, total, crc, slot, label));
    auto bad = encode_file_begin(7, 3, 0, 1, 1, "x");  // empty file
    CHECK(!decode_file_begin(bad.data(), bad.size(), id, total, crc, slot, label));
    bad = encode_file_begin(7, 3, static_cast<uint32_t>(kMaxFileBytes + 1), 1, 1, "x");  // too big
    CHECK(!decode_file_begin(bad.data(), bad.size(), id, total, crc, slot, label));
    bad = encode_file_begin(7, 3, 10, 1, 1, std::string("a\nb"));  // control character in the label
    CHECK(!decode_file_begin(bad.data(), bad.size(), id, total, crc, slot, label));
    auto c = encode_file_chunk(7, 3, 4096, data.data() + 4096, 904);
    uint32_t cid, off;
    const uint8_t* bytes;
    size_t n;
    CHECK(decode_file_chunk(c.data(), c.size(), cid, off, bytes, n) && cid == 3 && off == 4096 && n == 904 &&
          std::memcmp(bytes, data.data() + 4096, 904) == 0);
    CHECK(!decode_file_chunk(c.data(), c.size() + 1, cid, off, bytes, n));
    auto e = make_file_end(7, 3);
    CHECK(decode_file_end(&e, sizeof(e), cid) && cid == 3);
}

static void test_save_sync_units(const fs::path& tmp) {
    // RE7's real names (from a real save folder): manual saves are dataNNNSlot.bin, the Autosave is data000.bin
    CHECK(parse_slot("data001Slot.bin") == 1 && parse_slot("DATA012SLOT.BIN") == 12 && parse_slot("data011Slot.bin") == 11);
    CHECK(parse_slot("data000.bin") == -1 && parse_slot("data000Slot.bin") == -1);  // the Autosave is not a slot
    CHECK(parse_slot("data00-1.bin") == -1 && parse_slot("data00-92.bin") == -1 && parse_slot("data012.bin") == -1);  // system files, old guess
    CHECK(parse_slot("data99Slot.bin") == -1 && parse_slot("remotecache.vdf") == -1 && parse_slot("data012Slot.bin.tmp") == -1 &&
          parse_slot("data012Slot.bin.re7mp_tmp") == -1 && parse_slot("dataabcSlot.bin") == -1);
    CHECK(slot_filename(7) == "data007Slot.bin" && parse_slot(slot_filename(42)) == 42);

    // Finding the save folder: the account folder with the newest save wins.
    const fs::path steam = tmp / "SteamSaves";
    write_text(steam / "userdata" / "111" / "418370" / "remote" / "win64_save" / "data000.bin", "old");
    write_text(steam / "userdata" / "222" / "418370" / "remote" / "win64_save" / "data001Slot.bin", "x");
    fs::create_directories(steam / "userdata" / "333" / "730" / "remote");  // another game
    std::this_thread::sleep_for(milliseconds(30));
    write_text(steam / "userdata" / "222" / "418370" / "remote" / "win64_save" / "data002Slot.bin", "newest");
    auto dirs = find_save_dirs(steam);
    CHECK(dirs.size() == 2 && dirs[0] == steam / "userdata" / "222" / "418370" / "remote" / "win64_save");

    // Slot picking never lands on a single-player save.
    const fs::path d = tmp / "slots";
    fs::create_directories(d);
    CoopManifest m(tmp / "slots_manifest.json");
    CHECK(pick_slot(d, 5, m) == 1);                        // 9.22: an empty folder: slot 1, not the sender's number
    write_text(d / "data005Slot.bin", "mine");
    CHECK(pick_slot(d, 5, m) == 6);                        // one past the highest save, even though the sender's slot number is taken
    write_text(d / "data001Slot.bin", "mine too");
    CHECK(pick_slot(d, 5, m) == 6);
    write_text(d / "data014Slot.bin", "mine, far up");
    CHECK(pick_slot(d, 3, m) == 15);                       // the sender's slot 3 is free here, but the save goes after the highest one
    fs::remove(d / "data014Slot.bin");
    write_text(d / "data000.bin", "the autosave");         // never a slot to put a co-op save in, never listed
    CHECK(pick_slot(d, 0, m) == 6);                        // the sender's "slot 0" (an old exe sending its autosave) goes after the highest too
    CoopEntry e;
    e.slot = 6;
    e.from_slot = 5;
    e.label = "CO-OP Bob 2026-11-06 20:00";
    e.from = "Bob";
    e.crc = 1234;
    m.upsert(e);
    write_text(d / "data006Slot.bin", "the copy we installed");
    CHECK(pick_slot(d, 5, m) == 6);                        // the same save again (sender slot 5): it replaces the copy we installed
    CHECK(pick_slot(d, 4, m) == 7);                        // another save of theirs: a new slot, the old copy stays
    CHECK(m.is_coop_slot(6) && !m.is_coop_slot(1) && m.has_crc(1234) && !m.has_crc(1));
    CHECK(m.is_received_slot(6));
    // A save you made yourself and sent is co-op too, but an incoming save may not replace it.
    CoopEntry mine;
    mine.slot = 7;
    mine.label = "CO-OP Me 2026-11-07 12:00";
    mine.role = "sent";
    mine.partner = "Bob";
    mine.crc = 777;
    mine.size = 4;
    m.upsert(mine);
    write_text(d / "data007Slot.bin", "mine");
    CHECK(m.is_coop_slot(7) && !m.is_received_slot(7) && pick_slot(d, 7, m) != 7);
    CHECK(list_occupied(d) == (std::vector<int>{1, 5, 6, 7}));  // the autosave (data000.bin) is not listed
    CHECK(m.save("last \"event\"", true, list_occupied(d), "C:\\Steam\\userdata\\759758082\\418370\\remote\\win64_save"));
    {
        std::ifstream f(tmp / "slots_manifest.json", std::ios::binary);
        std::stringstream ss;
        ss << f.rdbuf();
        const std::string js = ss.str();
        CHECK(js.find("\"tag\":\"[CO-OP: sent to Bob]\"") != std::string::npos);  // what the Load screen shows for slot 7: YOUR save, sent to Bob
        CHECK(js.find("\"tag\":\"[CO-OP: Bob]\"") != std::string::npos);          // ...and for slot 6: the copy received from Bob
        CHECK(js.find("\"occupied\":[1,5,6,7]") != std::string::npos);
        CHECK(js.find("\"dir\":\"C:\\\\Steam\\\\userdata\\\\759758082") != std::string::npos);  // the watched folder, escaped
        CHECK(js.find("\"role\":\"sent\"") != std::string::npos && js.find("\"role\":\"received\"") != std::string::npos);
    }
    CoopManifest m2(tmp / "slots_manifest.json");
    m2.load();
    CHECK(m2.entries().size() == 2 && m2.entries()[0].label == "CO-OP Bob 2026-11-06 20:00" && m2.entries()[0].crc == 1234);
    CHECK(m2.entries()[1].role == "sent" && m2.entries()[1].partner == "Bob" && m2.entries()[1].slot == 7);
    CHECK(CoopManifest::tag_for(m2.entries()[0]) == "[CO-OP: Bob]" && CoopManifest::tag_for(m2.entries()[1]) == "[CO-OP: sent to Bob]");
    {   // where a received copy came from and why it is where it is survives a restart
        CoopEntry r;
        r.slot = 12;
        r.label = "CO-OP Bob 2026-11-08 03:00";
        r.from = r.partner = "Bob";
        r.crc = 99;
        r.from_slot = 10;
        r.why = "slot 10 here holds a save of your own, so it went into the lowest free slot";
        CoopManifest mw(tmp / "why_manifest.json");
        mw.upsert(r);
        CHECK(mw.save("x", true));
        CoopManifest mr(tmp / "why_manifest.json");
        mr.load();
        CHECK(mr.entries().size() == 1 && mr.entries()[0].from_slot == 10 && mr.entries()[0].why == r.why);
    }
    for (int i = 1; i <= kMaxSlot; ++i) {
        if (!fs::exists(d / slot_filename(i))) write_text(d / slot_filename(i), "x");
    }
    CHECK(pick_slot(d, 9, m2) == 6);                       // full, but a co-op slot (the copy we installed in 6) can still be replaced
    CoopManifest m3(tmp / "no_manifest.json");
    CHECK(pick_slot(d, 7, m3) == -1);                      // everything holds a single-player save

    // (9.32) The game lists 15 saves: nothing is ever put past slot 15, and a full folder replaces the OLDEST copy we installed.
    CHECK(kMaxSlot == 15);
    {
        const fs::path d15 = tmp / "slots15";
        fs::create_directories(d15);
        CoopManifest mm(tmp / "slots15_manifest.json");
        write_text(d15 / "data015Slot.bin", "mine, the last slot");
        write_text(d15 / "data016Slot.bin", "a file past 15 that an older build made");
        // the highest save is past 15: nothing is free "past the highest"; the lowest free slot is used, never 17
        SlotPick pk = pick_slot_ex(d15, 3, mm);
        CHECK(pk.slot == 1 && pk.how == SlotChoice::LowestFree);
        // a highest save of 14: slot 15 is one past it
        fs::remove(d15 / "data015Slot.bin");
        fs::remove(d15 / "data016Slot.bin");
        write_text(d15 / "data014Slot.bin", "mine");
        pk = pick_slot_ex(d15, 3, mm);
        CHECK(pk.slot == 15 && pk.how == SlotChoice::OnePastHighest);
        // slot 15 taken too: the lowest free slot (the Autosave is not one)
        write_text(d15 / "data015Slot.bin", "mine");
        write_text(d15 / "data000.bin", "autosave");
        pk = pick_slot_ex(d15, 3, mm);
        CHECK(pk.slot == 1 && pk.how == SlotChoice::LowestFree);
        // every slot taken and none of them a copy of ours: no slot, and never one past 15
        for (int i = 1; i <= kMaxSlot; ++i) {
            if (!fs::exists(d15 / slot_filename(i))) write_text(d15 / slot_filename(i), "mine");
        }
        pk = pick_slot_ex(d15, 3, mm);
        CHECK(pk.slot == -1 && pk.how == SlotChoice::None && pick_slot(d15, 3, mm) == -1);
        // three copies we installed (slots 9, 4, 11), received at different times: the oldest goes first, whatever its number
        auto copy = [&](int slot, const char* when, const char* from, int from_slot) {
            CoopEntry c;
            c.slot = slot;
            c.when = when;
            c.from = c.partner = from;
            c.from_slot = from_slot;
            c.role = "received";
            c.crc = static_cast<uint32_t>(100 + slot);
            mm.upsert(c);
        };
        copy(9, "2026-11-01 10:00", "Bob", 2);
        copy(4, "2026-11-05 10:00", "Bob", 3);
        copy(11, "2026-11-03 10:00", "Bob", 4);
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 9 && pk.how == SlotChoice::ReplacedOldestCopy && pk.replaced_when == "2026-11-01 10:00" && pk.replaced_from == "Bob");
        // the same save again still replaces ITS copy, not the oldest
        pk = pick_slot_ex(d15, 3, mm);
        CHECK(pk.slot == 4 && pk.how == SlotChoice::SameSave);
        // two copies of the same age: the lower slot goes first
        copy(11, "2026-11-01 10:00", "Bob", 4);
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 9 && pk.how == SlotChoice::ReplacedOldestCopy);
        copy(11, "2026-10-30 10:00", "Bob", 4);
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 11 && pk.how == SlotChoice::ReplacedOldestCopy && pk.replaced_when == "2026-10-30 10:00");
        copy(11, "2026-11-03 10:00", "Bob", 4);
        // a save of your own that was sent (role "sent") is never replaced, however old
        CoopEntry mine;
        mine.slot = 2;
        mine.when = "2026-01-01 00:00";
        mine.role = "sent";
        mine.partner = "Bob";
        mine.crc = 5;
        mm.upsert(mine);
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 9);
        // an entry whose file is gone is not a copy to replace: its slot is simply free
        fs::remove(d15 / slot_filename(9));
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 9 && pk.how == SlotChoice::LowestFree);
        write_text(d15 / slot_filename(9), "x");
        // free slots are used before any copy is replaced (before 9.32 the lowest copy was replaced even then)
        fs::remove(d15 / slot_filename(13));
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 13 && pk.how == SlotChoice::LowestFree);
        write_text(d15 / slot_filename(13), "x");
        // an entry past slot 15 (an older build) is not a candidate, however old
        CoopEntry past15;
        past15.slot = 40;
        past15.when = "2020-01-01 00:00";
        past15.role = "received";
        past15.from_slot = 7;  // (the sender's slot 7 as well: without the range check it would be taken as "the same save again")
        past15.crc = 9;
        mm.upsert(past15);
        write_text(d15 / slot_filename(40), "x");
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 9 && pk.how == SlotChoice::ReplacedOldestCopy);
        // an old manifest that has no date: its copy counts as the oldest
        copy(11, "", "Bob", 4);
        pk = pick_slot_ex(d15, 7, mm);
        CHECK(pk.slot == 11 && pk.how == SlotChoice::ReplacedOldestCopy && pk.replaced_when.empty());
        // a sender slot of 0 (an old exe sending its autosave) never matches a copy whose origin is not known (from_slot 0 in an old manifest)
        copy(6, "2026-11-09 10:00", "Bob", 0);
        pk = pick_slot_ex(d15, 0, mm);
        CHECK(pk.slot == 11 && pk.how == SlotChoice::ReplacedOldestCopy);
        // slot 15 can be the free one: 1..14 hold saves of your own and an older build left a file past 15, so "one past the highest" is out
        const fs::path d15b = tmp / "slots15b";
        fs::create_directories(d15b);
        CoopManifest m15b(tmp / "slots15b_manifest.json");
        for (int i = 1; i <= 14; ++i) write_text(d15b / slot_filename(i), "mine");
        write_text(d15b / "data016Slot.bin", "a file past 15 that an older build made");
        pk = pick_slot_ex(d15b, 3, m15b);
        CHECK(pk.slot == 15 && pk.how == SlotChoice::LowestFree);
    }

    // A manifest from an older version (no partner, no role) still loads: it is a received copy, from the sender.
    write_text(tmp / "old_manifest.json",
               "{\"enabled\":true,\"last\":\"\",\"entries\":[{\"slot\":4,\"label\":\"CO-OP Zed 2026-11-01 10:00\",\"from\":\"Zed\","
               "\"when\":\"x\",\"crc\":5,\"size\":9}]}");
    CoopManifest mo(tmp / "old_manifest.json");
    mo.load();
    CHECK(mo.entries().size() == 1 && mo.entries()[0].role == "received" && mo.entries()[0].partner == "Zed");

    // Pruning: a deleted save stops being co-op; a slot reused while we were away (other size or checksum) too.
    const fs::path pd = tmp / "prune";
    fs::create_directories(pd);
    write_text(pd / "data001Slot.bin", "aaaa");
    write_text(pd / "data002Slot.bin", "bbbbbb");
    write_text(pd / "data003Slot.bin", "cc");
    CoopManifest mp(tmp / "prune_manifest.json");
    auto entry_for = [](int slot, const std::string& body) {
        CoopEntry x;
        x.slot = slot;
        x.crc = crc32(body.data(), body.size());
        x.size = body.size();
        x.partner = "Bob";
        return x;
    };
    mp.upsert(entry_for(1, "aaaa"));
    mp.upsert(entry_for(2, "bbbbbb"));
    mp.upsert(entry_for(3, "cc"));
    CHECK(mp.prune(pd, true) == 0);                        // all three are as we left them
    fs::remove(pd / "data001Slot.bin");
    CHECK(mp.prune(pd, false) == 1 && !mp.is_coop_slot(1)); // deleted in the game's menu
    write_text(pd / "data002Slot.bin", "zzzzzz");              // same size, other content: only a content check sees it
    CHECK(mp.prune(pd, false) == 0 && mp.is_coop_slot(2));
    CHECK(mp.prune(pd, true) == 1 && !mp.is_coop_slot(2) && mp.is_coop_slot(3));
    CHECK(mp.remove_slot(3) && !mp.remove_slot(3));

    // Verifying received copies: a copy somebody wrote over (the game, Steam Cloud ...) stops being listed as CO-OP;
    // one that is unchanged, and the player's own sent saves, are left alone.
    {
        const fs::path vd = tmp / "verify";
        fs::create_directories(vd);
        write_text(vd / "data001Slot.bin", "from-bob-1");
        write_text(vd / "data002Slot.bin", "from-bob-2");
        write_text(vd / "data003Slot.bin", "mine-sent");
        CoopManifest mv(tmp / "verify_manifest.json");
        mv.upsert(entry_for(1, "from-bob-1"));
        mv.upsert(entry_for(2, "from-bob-2"));
        auto sent = entry_for(3, "mine-sent");
        sent.role = "sent";
        mv.upsert(sent);
        std::map<int, fs::file_time_type> seen;
        std::vector<int> dropped;
        CHECK(mv.verify_received(vd, seen, dropped) == 0 && dropped.empty() && seen.size() == 2);  // nothing changed (the sent save is not looked at)
        write_text(vd / "data002Slot.bin", "SOMETHING-ELSE");
        fs::last_write_time(vd / "data002Slot.bin", fs::file_time_type::clock::now() + std::chrono::seconds(5));
        write_text(vd / "data003Slot.bin", "i saved again");
        CHECK(mv.verify_received(vd, seen, dropped) == 1 && dropped == std::vector<int>{2} && !mv.is_coop_slot(2));
        CHECK(mv.is_received_slot(1) && mv.is_coop_slot(3));
        dropped.clear();
        CHECK(mv.verify_received(vd, seen, dropped) == 0);  // and it is not reported twice
    }

    // The watcher reports a save once it has been left alone, and only once.
    const fs::path w = tmp / "watched";
    write_text(w / "data001Slot.bin", "existing");
    SaveWatcher sw(w, 200);
    sw.baseline();
    auto t0 = SaveWatcher::Clock::now();
    CHECK(sw.poll(t0).empty());                            // baseline files are not reported
    write_text(w / "data002Slot.bin", "new");
    CHECK(sw.poll(t0 + milliseconds(10)).empty());         // just appeared
    CHECK(sw.poll(t0 + milliseconds(100)).empty());        // still settling
    auto ready = sw.poll(t0 + milliseconds(400));
    CHECK(ready.size() == 1 && ready[0].filename() == "data002Slot.bin");
    CHECK(sw.poll(t0 + milliseconds(900)).empty());        // reported once
    write_text(w / "data002Slot.bin", "rewritten, longer");
    CHECK(sw.poll(t0 + milliseconds(1000)).empty());       // changed again: wait
    CHECK(sw.poll(t0 + milliseconds(1300)).size() == 1);
    write_text(w / "data003Slot.bin", "ours");
    sw.ignore_current(w / "data003Slot.bin");
    CHECK(sw.poll(t0 + milliseconds(2000)).empty());       // files we wrote ourselves are ignored
    write_text(w / "data000.bin", "autosave written at a checkpoint");
    write_text(w / "data00-1.bin", "settings");
    CHECK(sw.poll(t0 + milliseconds(3000)).empty() && sw.poll(t0 + milliseconds(4000)).empty());  // the Autosave and system files are never shared
}

static std::string slurp_log(Engine& e, std::vector<std::string>& keep) {
    for (auto& l : e.drain_log()) keep.push_back(l);
    std::string all;
    for (auto& l : keep) all += l + "\n";
    return all;
}

static void test_save_transfer(const fs::path& tmp) {
    const fs::path sa = tmp / "saves_a", sb = tmp / "saves_b";
    fs::create_directories(sa);
    fs::create_directories(sb);
    const auto b_single = random_bytes(2000, 99);
    write_bytes(sb / "data003Slot.bin", b_single);  // the other player's own single-player save in slot 3

    Config ca, cb;
    ca.data_dir = tmp / "st_a";
    cb.data_dir = tmp / "st_b";
    ca.mode = cb.mode = Mode::Network;
    ca.transport = Transport::TcpHost;
    cb.transport = Transport::TcpJoin;
    ca.listen_port = 28981;
    cb.peer_host = "127.0.0.1";
    cb.peer_port = 28981;
    ca.name = "Alice";
    cb.name = "Bob";
    ca.save_sync = cb.save_sync = true;
    ca.save_dir = sa;
    cb.save_dir = sb;
    ca.save_stable_ms = cb.save_stable_ms = 300;
    Engine a, b;
    std::string err;
    CHECK(a.start(ca, err) && b.start(cb, err));
    std::vector<std::string> loga, logb;
    std::this_thread::sleep_for(milliseconds(1800));  // connect, exchange names

    // Alice saves into slot 3 (Bob's slot 3 is a single-player save, so it must land elsewhere).
    const auto big = random_bytes(300 * 1024, 1);
    write_bytes(sa / "data000.bin", random_bytes(4096, 77));  // Alice's autosave changes too: it must stay home
    write_bytes(sa / "data003Slot.bin", std::vector<uint8_t>(big.begin(), big.begin() + 1000));  // half-written first
    std::this_thread::sleep_for(milliseconds(150));
    write_bytes(sa / "data003Slot.bin", big);
    std::this_thread::sleep_for(milliseconds(2600));
    CHECK(read_bytes(sb / "data003Slot.bin") == b_single);   // Bob's own save untouched
    CHECK(fs::exists(sb / "data004Slot.bin") && read_bytes(sb / "data004Slot.bin") == big);  // the co-op copy, one past Bob's highest save (3)
    CHECK(!fs::exists(sb / "data000.bin"));                  // Alice's autosave was not sent and Bob has no autosave of it
    CoopManifest mb(cb.data_dir / "re7mp_coop_saves.json");
    mb.load();
    CHECK(mb.entries().size() == 1 && mb.entries()[0].slot == 4 && mb.entries()[0].from == "Alice" &&
          mb.entries()[0].label.rfind("CO-OP Alice ", 0) == 0);
    CHECK(mb.entries()[0].role == "received" && mb.entries()[0].partner == "Alice");
    // ...and it says where the save came from and why it went there: one past the highest save Bob has
    CHECK(mb.entries()[0].from_slot == 3 && mb.entries()[0].why.find("one past your highest save") != std::string::npos);
    CHECK(b.status().last_save_event.find("installed in slot 4") != std::string::npos &&
          b.status().last_save_event.find("one past your highest save") != std::string::npos);
    {   // The saver's own copy is marked too, with the name of the player it was shared with.
        CoopManifest ma(ca.data_dir / "re7mp_coop_saves.json");
        ma.load();
        CHECK(ma.entries().size() == 1 && ma.entries()[0].slot == 3 && ma.entries()[0].role == "sent" &&
              ma.entries()[0].partner == "Bob" && ma.is_coop_slot(3) && !ma.is_received_slot(3));
    }
    CHECK(fs::exists(sa / "data003Slot.bin") && !fs::exists(sa / "data004Slot.bin"));  // nothing echoed back to Alice
    CHECK(b.status().saves_received == 1 && a.status().saves_sent == 1);
    std::printf("  save sharing: Alice's slot 3 became Bob's slot 4 (%s)\n", mb.entries().empty() ? "?" : mb.entries()[0].label.c_str());

    // A second save goes one past the highest again (Bob has 3 and 4, so 5); sending the same save again replaces that copy.
    const auto s5 = random_bytes(50 * 1024, 5);
    write_bytes(sa / "data005Slot.bin", s5);
    std::this_thread::sleep_for(milliseconds(2000));
    CHECK(read_bytes(sb / "data005Slot.bin") == s5);
    const auto s5b = random_bytes(60 * 1024, 6);
    write_bytes(sa / "data005Slot.bin", s5b);
    std::this_thread::sleep_for(milliseconds(2000));
    CHECK(read_bytes(sb / "data005Slot.bin") == s5b);

    // And the other direction; the copies Bob received are not sent back.
    const auto s7 = random_bytes(40 * 1024, 7);
    write_bytes(sb / "data007Slot.bin", s7);
    std::this_thread::sleep_for(milliseconds(2000));
    CHECK(fs::exists(sa / "data006Slot.bin") && read_bytes(sa / "data006Slot.bin") == s7);  // one past Alice's highest (5)
    CHECK(!fs::exists(sa / "data007Slot.bin") && !fs::exists(sa / "data001Slot.bin"));

    // A save made while the other player is not connected stays private.
    b.stop();
    std::this_thread::sleep_for(milliseconds(8000));  // long enough for "reachable" to lapse
    write_bytes(sa / "data009Slot.bin", random_bytes(10 * 1024, 9));
    write_bytes(sa / "data003Slot.bin", random_bytes(5 * 1024, 13));  // a co-op slot saved over privately
    std::this_thread::sleep_for(milliseconds(1500));
    {
        CoopManifest ma(ca.data_dir / "re7mp_coop_saves.json");
        ma.load();
        CHECK(!ma.is_coop_slot(3) && ma.is_coop_slot(5) && !ma.is_coop_slot(9));  // slot 3 is single-player again
    }
    CHECK(b.start(cb, err));
    std::this_thread::sleep_for(milliseconds(4000));
    CHECK(!fs::exists(sb / "data009Slot.bin"));
    fs::remove(sa / "data005Slot.bin");  // deleted in the game's menu: no longer listed as co-op

    // A multi-megabyte save.
    const auto huge = random_bytes(3 * 1024 * 1024, 11);
    write_bytes(sa / "data011Slot.bin", huge);
    std::this_thread::sleep_for(milliseconds(4500));
    CHECK(fs::exists(sb / "data008Slot.bin") && read_bytes(sb / "data008Slot.bin") == huge);  // one past Bob's highest (7)
    std::this_thread::sleep_for(milliseconds(2500));
    {
        CoopManifest ma(ca.data_dir / "re7mp_coop_saves.json");
        ma.load();
        CHECK(!ma.is_coop_slot(5) && ma.is_coop_slot(11) && ma.entries().size() == 2);  // slot 7's copy from Bob is listed too
    }
    slurp_log(a, loga);
    slurp_log(b, logb);
    a.stop();
    b.stop();
}

// ---- re-signing a save for another Steam account (since the exe after 9.24) ------------------------------------------------

// A stand-in for an RE7 save: the real container header, a data header whose blocks are what the real ones look like (block 0 is the
// real RE7 one from a real save), a random body, and a correct signature at the end.
static const uint8_t kReal_RE7_Block0[8] = {0x68, 0x59, 0xbc, 0xd6, 0x73, 0xdd, 0x94, 0x74};  // the first data-header block of a real RE7 save
static std::vector<uint8_t> make_fake_save(const AccountMark& m, size_t body, uint32_t seed) {
    std::vector<uint8_t> v = {'D', 'S', 'S', 'S', 2, 0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0};
    v.insert(v.end(), m.format.begin(), m.format.end());
    v.insert(v.end(), m.account.begin(), m.account.end());
    const auto rest = random_bytes(16 + body, seed);  // blocks 2 and 3, then the body
    v.insert(v.end(), rest.begin(), rest.end());
    v.insert(v.end(), 4, 0);  // the signature
    autostrong_sign(v);
    return v;
}
static AccountMark mark_of(const std::vector<uint8_t>& v) {
    AccountMark m;
    CHECK(read_account_mark(v.data(), v.size(), m));
    return m;
}

static void test_save_resign(const fs::path& tmp) {
    const fs::path data = fs::path(RE7MP_TEST_DATA);
    const auto enc = read_bytes(data / "autostrong_test_encrypted.bin");
    const auto dec = read_bytes(data / "autostrong_test_decrypted.bin");
    CHECK(enc.size() == 212 && dec.size() == 212);

    // The signature code reproduces the signatures the original tool wrote (two real files, plus - checked by hand when this was
    // written - two real RE7 saves of 4-5 MB).
    CHECK(autostrong_signature_ok(enc) && autostrong_signature_ok(dec));
    {
        auto bad = enc;
        bad[100] ^= 1;
        CHECK(!autostrong_signature_ok(bad));
        autostrong_sign(bad);
        CHECK(autostrong_signature_ok(bad) && bad != enc);
        bad[100] ^= 1;
        autostrong_sign(bad);
        CHECK(bad == enc);  // sign(original) gives back the original bytes, signature included
    }
    CHECK(classify_container(enc.data(), enc.size()) == ContainerKind::Encrypted);
    CHECK(classify_container(dec.data(), dec.size()) == ContainerKind::Plain);
    CHECK(classify_container(random_bytes(500, 1).data(), 500) == ContainerKind::Other && classify_container(enc.data(), 20) == ContainerKind::Other);
    AccountMark none;
    CHECK(!read_account_mark(dec.data(), dec.size(), none));

    // Re-signing with the file's own mark changes nothing; with another account's mark it changes exactly the account block and the
    // signature, and going back gives the original file byte for byte.
    const AccountMark mine = mark_of(enc);
    {
        auto same = enc;
        const auto r = resign_save(same, mine);
        CHECK(r.kind == ResignKind::AlreadyYours && same == enc && r.install());
        AccountMark other = mine;
        for (auto& b : other.account) b ^= 0x5a;
        auto moved = enc;
        const auto r2 = resign_save(moved, other);
        CHECK(r2.kind == ResignKind::Resigned && r2.install() && autostrong_signature_ok(moved) && mark_of(moved) == other);
        size_t diff = 0;
        for (size_t i = 0; i < enc.size(); ++i) diff += enc[i] != moved[i];
        CHECK(diff > 0 && diff <= 12);  // 8 account bytes + 4 signature bytes at most
        CHECK(std::equal(enc.begin(), enc.begin() + 24, moved.begin()) && std::equal(enc.begin() + 32, enc.end() - 4, moved.begin() + 32));
        auto back = moved;
        CHECK(resign_save(back, mine).kind == ResignKind::Resigned && back == enc);
        // a different key (another game): not installed
        AccountMark alien = mine;
        alien.format[0] ^= 1;
        auto x = enc;
        CHECK(resign_save(x, alien).kind == ResignKind::OtherKey && !resign_save(x, alien).install() && x == enc);
        // damaged: not installed, not changed
        auto d = enc;
        d[150] ^= 0x40;
        const auto dd = d;
        CHECK(resign_save(d, other).kind == ResignKind::Damaged && d == dd);
        // things that are not RE7 saves pass through
        auto rnd = random_bytes(3000, 4);
        const auto rnd0 = rnd;
        CHECK(resign_save(rnd, other).kind == ResignKind::NotApplicable && rnd == rnd0 && resign_save(rnd, other).install());
        auto pl = dec;
        CHECK(resign_save(pl, other).kind == ResignKind::NotApplicable && pl == dec);
        std::vector<uint8_t> tiny = {'D', 'S', 'S', 'S'};
        CHECK(resign_save(tiny, other).kind == ResignKind::NotApplicable);
    }

    // Learning this PC's account from the save folder.
    AccountMark A, B;
    std::memcpy(A.format.data(), kReal_RE7_Block0, 8);
    B.format = A.format;
    const uint8_t acc_a[8] = {0x8f, 0xfd, 0xa0, 0xbc, 0x2b, 0x0e, 0x21, 0xa2}, acc_b[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    std::memcpy(A.account.data(), acc_a, 8);
    std::memcpy(B.account.data(), acc_b, 8);
    const fs::path d1 = tmp / "mark_dir";
    fs::create_directories(d1);
    CoopManifest empty(tmp / "mark_manifest.json");
    AccountMark got;
    int files = 0, total = 0;
    CHECK(find_own_mark(d1, empty, got, files, total) == MarkSearch::None);                    // nothing there
    CHECK(find_own_mark(d1 / "nonexistent", empty, got, files, total) == MarkSearch::None);   // no such folder
    write_bytes(d1 / "data003Slot.bin", random_bytes(5000, 8));                               // not a container
    write_bytes(d1 / "notes.txt", make_fake_save(B, 100, 1));                                 // not a .bin
    write_bytes(d1 / "data005Slot.bin", dec);                                                 // plain: no account to learn from
    CHECK(find_own_mark(d1, empty, got, files, total) == MarkSearch::None && total == 0);
    write_bytes(d1 / "data00-1.bin", make_fake_save(A, 200, 2));
    CHECK(find_own_mark(d1, empty, got, files, total) == MarkSearch::Found && got == A && files == 1 && total == 1);
    write_bytes(d1 / "data000.bin", make_fake_save(A, 5000, 3));
    write_bytes(d1 / "data001Slot.bin", make_fake_save(B, 300, 4));  // e.g. a save copied in by hand
    CHECK(find_own_mark(d1, empty, got, files, total) == MarkSearch::Found && got == A && files == 2 && total == 3);  // the majority wins
    fs::remove(d1 / "data000.bin");
    CHECK(find_own_mark(d1, empty, got, files, total) == MarkSearch::Disagree);  // 1 against 1: not guessed
    {   // a copy this tool installed is not evidence: with slot 1 marked as received, only A remains
        CoopManifest m(tmp / "mark_manifest2.json");
        CoopEntry e;
        e.slot = 1;
        e.role = "received";
        m.upsert(e);
        CHECK(find_own_mark(d1, m, got, files, total) == MarkSearch::Found && got == A && files == 1 && total == 1);
        // the whole job, from the folder
        auto theirs = make_fake_save(B, 4000, 9);
        const auto body_before = std::vector<uint8_t>(theirs.begin() + 48, theirs.end() - 4);
        const auto r = resign_for_this_pc(theirs, d1, m);
        CHECK(r.kind == ResignKind::Resigned && mark_of(theirs) == A && autostrong_signature_ok(theirs) &&
              std::vector<uint8_t>(theirs.begin() + 48, theirs.end() - 4) == body_before &&
              r.detail.find("learned from 1 of your 1") != std::string::npos);
        auto mine_already = make_fake_save(A, 400, 10);
        CHECK(resign_for_this_pc(mine_already, d1, m).kind == ResignKind::AlreadyYours);
        auto rnd = random_bytes(2000, 11);
        CHECK(resign_for_this_pc(rnd, d1, m).kind == ResignKind::NotApplicable);
    }
    {   // nothing to learn from: a file that needs re-signing is refused, anything else passes
        const fs::path d2 = tmp / "mark_dir_empty";
        fs::create_directories(d2);
        auto theirs = make_fake_save(B, 400, 12);
        const auto before = theirs;
        const auto r = resign_for_this_pc(theirs, d2, empty);
        CHECK(r.kind == ResignKind::NoOwnSave && !r.install() && theirs == before && r.detail.find("main menu") != std::string::npos);
        auto rnd = random_bytes(2000, 13);
        CHECK(resign_for_this_pc(rnd, d2, empty).kind == ResignKind::NotApplicable);
        const auto amb = resign_for_this_pc(theirs, d1, empty);  // d1 has A and B once each
        CHECK(amb.kind == ResignKind::Ambiguous && !amb.install() && theirs == before);
    }
}

// End to end over TCP: Alice's save names Alice's Steam account; Bob's game must be handed one that names Bob's.
static void test_save_transfer_resign(const fs::path& tmp) {
    AccountMark A, B;
    std::memcpy(A.format.data(), kReal_RE7_Block0, 8);
    B.format = A.format;
    for (int i = 0; i < 8; ++i) {
        A.account[static_cast<size_t>(i)] = static_cast<uint8_t>(0x10 + i);
        B.account[static_cast<size_t>(i)] = static_cast<uint8_t>(0xB0 + i);
    }
    const fs::path sa = tmp / "rs_a", sb = tmp / "rs_b";
    fs::create_directories(sa);
    fs::create_directories(sb);
    write_bytes(sa / "data00-1.bin", make_fake_save(A, 500, 21));  // Alice's own files: her account
    write_bytes(sa / "data001Slot.bin", make_fake_save(A, 20000, 22));
    write_bytes(sb / "data00-1.bin", make_fake_save(B, 500, 23));  // Bob's: his
    write_bytes(sb / "data001Slot.bin", make_fake_save(B, 30000, 24));

    Config ca, cb;
    ca.data_dir = tmp / "rs_st_a";
    cb.data_dir = tmp / "rs_st_b";
    ca.mode = cb.mode = Mode::Network;
    ca.transport = Transport::TcpHost;
    cb.transport = Transport::TcpJoin;
    ca.listen_port = 28979;
    cb.peer_host = "127.0.0.1";
    cb.peer_port = 28979;
    ca.name = "Alice";
    cb.name = "Bob";
    ca.save_sync = cb.save_sync = true;
    ca.save_dir = sa;
    cb.save_dir = sb;
    ca.save_stable_ms = cb.save_stable_ms = 300;
    Engine a, b;
    std::string err;
    CHECK(a.start(ca, err) && b.start(cb, err));
    std::this_thread::sleep_for(milliseconds(1800));

    // Alice saves into slot 2 (an 800 KB "save"): Bob gets it in slot 2 (one past his highest, 1) naming BOB, body byte for byte hers.
    const auto alice_save = make_fake_save(A, 800 * 1024, 31);
    write_bytes(sa / "data002Slot.bin", alice_save);
    std::this_thread::sleep_for(milliseconds(3200));
    const fs::path got = sb / "data002Slot.bin";
    CHECK(fs::exists(got));
    const auto installed = read_bytes(got);
    CHECK(installed.size() == alice_save.size() && autostrong_signature_ok(installed) && mark_of(installed) == B);
    CHECK(installed != alice_save);
    CHECK(std::equal(alice_save.begin() + 32, alice_save.end() - 4, installed.begin() + 32));  // everything but the account block and the signature
    CHECK(mark_of(read_bytes(sb / "data001Slot.bin")) == B);  // Bob's own saves were not touched
    CoopManifest mb(cb.data_dir / "re7mp_coop_saves.json");
    mb.load();
    CHECK(mb.entries().size() == 1 && mb.entries()[0].slot == 2 && mb.entries()[0].crc == crc32(installed.data(), installed.size()) &&
          mb.entries()[0].size == installed.size());  // the manifest describes what is on disk, not what was sent
    CHECK(!mb.entries().empty() && mb.entries()[0].why.find("re-signed for your Steam account") != std::string::npos);
    CHECK(b.status().last_save_event.find("re-signed for your Steam account") != std::string::npos && b.status().saves_received == 1);
    CHECK(fs::exists(sa / "data002Slot.bin") && read_bytes(sa / "data002Slot.bin") == alice_save);  // Alice's own file is untouched
    std::this_thread::sleep_for(milliseconds(6500));  // the 5-second re-check must still accept the re-signed copy
    mb.load();
    CHECK(mb.entries().size() == 1 && b.status().last_save_event.find("no longer holds") == std::string::npos);

    // A file that is not an RE7 container still goes through unchanged (the plain-bytes behaviour of the older tests).
    const auto plain = random_bytes(40 * 1024, 41);
    write_bytes(sa / "data003Slot.bin", plain);
    std::this_thread::sleep_for(milliseconds(2600));
    CHECK(fs::exists(sb / "data003Slot.bin") && read_bytes(sb / "data003Slot.bin") == plain);
    a.stop();
    b.stop();

    // Bob with no save of his own: the incoming save is refused, with the way out in the message, and nothing is written.
    const fs::path sc = tmp / "rs_c";
    fs::create_directories(sc);
    Config cc = cb;
    cc.data_dir = tmp / "rs_st_c";
    cc.save_dir = sc;
    Engine a2, c;
    ca.data_dir = tmp / "rs_st_a2";
    CHECK(a2.start(ca, err) && c.start(cc, err));
    std::this_thread::sleep_for(milliseconds(1800));
    write_bytes(sa / "data004Slot.bin", make_fake_save(A, 60 * 1024, 51));
    std::this_thread::sleep_for(milliseconds(2800));
    CHECK(c.status().saves_received == 0 && c.status().last_save_event.find("NOT installed") != std::string::npos &&
          c.status().last_save_event.find("main menu") != std::string::npos);
    int n_files = 0;
    for (const auto& e : fs::directory_iterator(sc)) { (void)e; ++n_files; }
    CHECK(n_files == 0);
    a2.stop();
    c.stop();
    std::printf("  save re-signing: Alice's save arrived naming Bob's account, body untouched\n");
}

// (9.42) Which Steam account's folder, and the exe-to-exe account message.
static void test_save_accounts(const fs::path& tmp) {
    // --- the account message text ---
    {
        uint32_t a = 0;
        CHECK(account_text(759758082u) == "acct|1|759758082");
        CHECK(parse_account_text("acct|1|759758082", a) && a == 759758082u);
        CHECK(parse_account_text("acct|1|4294967295", a) && a == 4294967295u);
        CHECK(parse_account_text("acct|1|1", a) && a == 1u);
        const char* bad[] = {"", "acct|1|", "acct|1|0", "acct|1|4294967296", "acct|1|-5", "acct|1|12 34", "acct|1|12a", "acct|2|5", "acct|1|00000000001",
                             "ACCT|1|5", "acct|1|+5", "acct||5", "x|acct|1|5"};
        for (const char* b : bad) {
            uint32_t out = 77;
            CHECK(!parse_account_text(b, out) && out == 77);  // a refused text leaves the output alone
        }
    }
    // --- the account id out of a folder path ---
    {
        const fs::path root = "C:/Program Files (x86)/Steam";
        CHECK(account_of_save_dir(root / "userdata" / "759758082" / "418370" / "remote" / "win64_save") == 759758082u);
        CHECK(account_of_save_dir(fs::path("/a/userdata/1055164497/418370/remote/win64_save/")) == 1055164497u);  // trailing separator
        CHECK(account_of_save_dir(fs::path("/a/userdata/5/418370/remote/WIN64_SAVE")) == 5u);                  // Windows is not case sensitive
        CHECK(account_of_save_dir(fs::path("/a/userdata/759758082/418370/remote")) == 0);                      // not the save folder itself
        CHECK(account_of_save_dir(fs::path("/a/userdata/759758082/883710/remote/win64_save")) == 0);            // another game
        CHECK(account_of_save_dir(fs::path("/a/userdata/abc/418370/remote/win64_save")) == 0);                  // not a number
        CHECK(account_of_save_dir(fs::path("/a/userdata/0/418370/remote/win64_save")) == 0);                    // 0 is "nobody"
        CHECK(account_of_save_dir(fs::path("/a/userdata/99999999999/418370/remote/win64_save")) == 0);          // does not fit 32 bits
        CHECK(account_of_save_dir(fs::path("D:/my saves")) == 0 && account_of_save_dir(fs::path()) == 0);
    }
    // --- loginusers.vdf ---
    {
        constexpr uint64_t kBase = 76561197960265728ull;
        const std::string id_a = std::to_string(kBase + 759758082ull), id_b = std::to_string(kBase + 1055164497ull);
        const std::string vdf = "\"users\"\r\n{\r\n\t\"" + id_b + "\"\r\n\t{\r\n\t\t\"AccountName\"\t\t\"old\"\r\n\t\t\"PersonaName\"\t\t\"Old \\\"one\\\"\"\r\n"
                                "\t\t\"MostRecent\"\t\t\"0\"\r\n\t\t\"Timestamp\"\t\t\"1600000000\"\r\n\t}\r\n\t\"" + id_a +
                                "\"\r\n\t{\r\n\t\t\"AccountName\"\t\t\"new\"\r\n\t\t\"MostRecent\"\t\t\"1\"\r\n\t}\r\n}\r\n";
        CHECK(last_login_from_vdf(vdf) == 759758082u);
        std::string flipped = vdf;  // the other way round: B most recent
        flipped.replace(flipped.find("\"MostRecent\"\t\t\"0\""), 17, "\"MostRecent\"\t\t\"1\"");
        flipped.replace(flipped.rfind("\"MostRecent\"\t\t\"1\""), 17, "\"MostRecent\"\t\t\"0\"");
        CHECK(last_login_from_vdf(flipped) == 1055164497u);
        CHECK(last_login_from_vdf("") == 0 && last_login_from_vdf("garbage { \"x\" ") == 0 && last_login_from_vdf("\"users\" { }") == 0);
        CHECK(last_login_from_vdf("\"users\" { \"" + id_a + "\" { \"MostRecent\" \"0\" } }") == 0);   // nobody marked
        CHECK(last_login_from_vdf("\"users\" { \"12345\" { \"MostRecent\" \"1\" } }") == 0);           // not a 64-bit Steam id
        CHECK(last_login_from_vdf("\"MostRecent\" \"1\"") == 0);                                       // not inside a user block
        CHECK(last_login_from_vdf("// a comment\n\"users\" { \"" + id_a + "\" { \"MostRecent\" \"1\" } }") == 759758082u);
    }
    // --- choosing the folder with two accounts on the PC ---
    const fs::path steam = tmp / "acct_steam";
    const fs::path dir_new = steam / "userdata" / "759758082" / "418370" / "remote" / "win64_save";  // the account in use
    const fs::path dir_old = steam / "userdata" / "1055164497" / "418370" / "remote" / "win64_save"; // the old account, with the NEWER file
    fs::create_directories(dir_new);
    fs::create_directories(dir_old);
    write_bytes(dir_new / "data001Slot.bin", random_bytes(100, 1));
    std::this_thread::sleep_for(milliseconds(50));
    write_bytes(dir_old / "data001Slot.bin", random_bytes(100, 2));  // written last: the old rule ("newest file wins") picks THIS one
    {
        const auto old_rule = find_save_dirs(steam);
        CHECK(!old_rule.empty() && old_rule.front() == dir_old);
        auto c = choose_save_dir(steam, 759758082u);
        CHECK(c.how == DirHow::SteamRunning && c.dir == dir_new && c.account == 759758082u && c.why.find("759758082") != std::string::npos);
        c = choose_save_dir(steam, 1055164497u);
        CHECK(c.how == DirHow::SteamRunning && c.dir == dir_old && c.account == 1055164497u);
        c = choose_save_dir(steam, 424242u);  // signed in, but never ran RE7: no guessing at another account's folder
        CHECK(c.how == DirHow::None && c.dir.empty() && c.why.find("424242") != std::string::npos && c.why.find("main menu") != std::string::npos);
        c = choose_save_dir(steam, 0);  // Steam not running, nothing says who was last: the old rule, and it says so
        CHECK(c.how == DirHow::NewestFiles && c.dir == dir_old && c.account == 1055164497u && c.why.find("newest") != std::string::npos);
        constexpr uint64_t kBase = 76561197960265728ull;
        write_text(steam / "config" / "loginusers.vdf",
                   "\"users\"\n{\n\t\"" + std::to_string(kBase + 759758082ull) + "\"\n\t{\n\t\t\"MostRecent\"\t\t\"1\"\n\t}\n\t\"" +
                       std::to_string(kBase + 1055164497ull) + "\"\n\t{\n\t\t\"MostRecent\"\t\t\"0\"\n\t}\n}\n");
        CHECK(steam_last_login(steam) == 759758082u);
        c = choose_save_dir(steam, 0);  // Steam not running, but the last sign-in is known
        CHECK(c.how == DirHow::LastLogin && c.dir == dir_new && c.account == 759758082u);
        c = choose_save_dir(steam, 1055164497u);  // running wins over the file
        CHECK(c.how == DirHow::SteamRunning && c.dir == dir_old);
        CHECK(choose_save_dir(tmp / "acct_no_steam", 759758082u).how == DirHow::None);
        CHECK(choose_save_dir(tmp / "acct_no_steam", 0).how == DirHow::None);
        CHECK(steam_last_login(tmp / "acct_no_steam") == 0);
    }
    // --- replacing the folder kept in the box ---
    {
        const auto right = choose_save_dir(steam, 759758082u);
        auto fix = correct_save_dir(dir_old, right);  // the old path kept in re7mp.ini
        CHECK(fix.change && fix.why.find("1055164497") != std::string::npos && fix.why.find("759758082") != std::string::npos);
        CHECK(correct_save_dir(fs::path(), right).change);                 // an empty box
        CHECK(!correct_save_dir(dir_new, right).change);                   // already the right one
        CHECK(!correct_save_dir(fs::path("D:/my saves"), right).change);   // typed on purpose: never touched
        SaveDirChoice guess;
        guess.how = DirHow::NewestFiles;
        guess.dir = dir_old;
        guess.account = 1055164497u;
        CHECK(!correct_save_dir(dir_new, guess).change);                   // a guess never overrides what is in the box
        CHECK(!correct_save_dir(dir_old, SaveDirChoice{}).change);         // nothing chosen: nothing changed
        SaveDirChoice last = right;
        last.how = DirHow::LastLogin;
        CHECK(correct_save_dir(dir_old, last).change);                     // the last sign-in counts too
    }
    // --- the manifest names both accounts and keeps the one in each entry ---
    {
        const fs::path mp = tmp / "acct_manifest.json";
        CoopManifest m(mp);
        CoopEntry e;
        e.slot = 4;
        e.label = "CO-OP Bob 2026-11-14 10:00";
        e.from = "Bob";
        e.partner = "Bob";
        e.role = "received";
        e.crc = 1234;
        e.size = 99;
        e.partner_account = 1055164497u;
        m.upsert(e);
        m.set_accounts(759758082u, 1055164497u);
        CHECK(m.save("ok", true, {1, 4}, "x"));
        const std::string txt = read_text(mp);
        double v = 0;
        CHECK(json_num(txt, "account", v) && v == 759758082.0);
        CHECK(txt.find("\"partner_account\":1055164497,\"why\"") != std::string::npos);  // the entry's own
        CHECK(txt.find("\"dir\":\"x\",\"account\":759758082,\"partner_account\":1055164497}") != std::string::npos);  // the manifest's
        CoopManifest back(mp);
        back.load();
        CHECK(back.entries().size() == 1 && back.entries()[0].partner_account == 1055164497u);
        CoopManifest fresh(tmp / "acct_manifest2.json");  // nobody told yet: 0, which the panel reads as "not known"
        fresh.save("ok", true);
        CHECK(json_num(read_text(tmp / "acct_manifest2.json"), "account", v) && v == 0.0);
        write_text(mp, "{\"enabled\":true,\"last\":\"\",\"entries\":[{\"slot\":2,\"label\":\"x\",\"crc\":5}],\"occupied\":[],\"dir\":\"\"}");  // a 9.41 file
        CoopManifest old(mp);
        old.load();
        CHECK(old.entries().size() == 1 && old.entries()[0].partner_account == 0);
    }
    // --- two re7mp.exe tell each other their account; the script never sees the message ---
    {
        AccountMark A, B;
        std::memcpy(A.format.data(), kReal_RE7_Block0, 8);
        B.format = A.format;
        for (int i = 0; i < 8; ++i) {
            A.account[static_cast<size_t>(i)] = static_cast<uint8_t>(0x10 + i);
            B.account[static_cast<size_t>(i)] = static_cast<uint8_t>(0xB0 + i);
        }
        const fs::path sa = tmp / "acct_a" / "userdata" / "111111" / "418370" / "remote" / "win64_save";
        const fs::path sb = tmp / "acct_b" / "userdata" / "222222" / "418370" / "remote" / "win64_save";
        fs::create_directories(sa);
        fs::create_directories(sb);
        write_bytes(sa / "data00-1.bin", make_fake_save(A, 500, 61));
        write_bytes(sb / "data00-1.bin", make_fake_save(B, 500, 62));
        Config ca, cb;
        ca.data_dir = tmp / "acct_st_a";
        cb.data_dir = tmp / "acct_st_b";
        ca.mode = cb.mode = Mode::Network;
        ca.transport = Transport::TcpHost;
        cb.transport = Transport::TcpJoin;
        ca.listen_port = 28961;
        cb.peer_host = "127.0.0.1";
        cb.peer_port = 28961;
        ca.name = "Alice";
        cb.name = "Bob";
        ca.save_sync = cb.save_sync = true;
        ca.save_dir = sa;
        cb.save_dir = sb;
        ca.save_stable_ms = cb.save_stable_ms = 300;
        Engine a, b;
        std::string err;
        CHECK(a.start(ca, err) && b.start(cb, err));
        for (int i = 0; i < 100 && !(a.status().peer_account != 0 && b.status().peer_account != 0); ++i) std::this_thread::sleep_for(milliseconds(100));
        CHECK(a.status().my_account == 111111u && b.status().my_account == 222222u);
        CHECK(a.status().peer_account == 222222u && b.status().peer_account == 111111u);
        std::this_thread::sleep_for(milliseconds(300));
        double v = 0;
        CHECK(json_num(read_text(ca.data_dir / "re7mp_coop_saves.json"), "account", v) && v == 111111.0);
        CHECK(json_num(read_text(ca.data_dir / "re7mp_coop_saves.json"), "partner_account", v) && v == 222222.0);
        CHECK(inbox_size(ca.data_dir) == 0 && inbox_size(cb.data_dir) == 0);  // exe to exe: nothing reached either script
        CHECK(a.status().messages_received == 0 && b.status().messages_received == 0);
        // A save made now carries the accounts into the manifests: Bob's received copy names Alice's account, Alice's sent one Bob's.
        write_bytes(sa / "data001Slot.bin", make_fake_save(A, 30000, 63));
        for (int i = 0; i < 80 && b.status().saves_received == 0; ++i) std::this_thread::sleep_for(milliseconds(100));
        std::this_thread::sleep_for(milliseconds(400));
        CoopManifest ma(ca.data_dir / "re7mp_coop_saves.json"), mb(cb.data_dir / "re7mp_coop_saves.json");
        ma.load();
        mb.load();
        CHECK(mb.entries().size() == 1 && mb.entries()[0].role == "received" && mb.entries()[0].partner_account == 111111u);
        CHECK(ma.entries().size() == 1 && ma.entries()[0].role == "sent" && ma.entries()[0].partner_account == 222222u);
        auto log = a.drain_log();
        CHECK(count_lines(log, "Steam account 111111") >= 1 && count_lines(log, "other player's PC uses Steam account 222222") == 1);
        CHECK(count_lines(log, "never confirmed") == 0);
        a.stop();
        b.stop();
    }
    // --- a folder that is not a userdata path: nothing is sent, and what arrives is still taken ---
    {
        const fs::path sa = tmp / "acct_c" / "userdata" / "333333" / "418370" / "remote" / "win64_save";
        const fs::path sb = tmp / "acct_d_plain";
        fs::create_directories(sa);
        fs::create_directories(sb);
        Config ca, cb;
        ca.data_dir = tmp / "acct_st_c";
        cb.data_dir = tmp / "acct_st_d";
        ca.mode = cb.mode = Mode::Network;
        ca.transport = Transport::TcpHost;
        cb.transport = Transport::TcpJoin;
        ca.listen_port = 28962;
        cb.peer_host = "127.0.0.1";
        cb.peer_port = 28962;
        ca.name = "Carol";
        cb.name = "Dan";
        ca.save_sync = cb.save_sync = true;
        ca.save_dir = sa;
        cb.save_dir = sb;
        Engine a, b;
        std::string err;
        CHECK(a.start(ca, err) && b.start(cb, err));
        for (int i = 0; i < 100 && b.status().peer_account == 0; ++i) std::this_thread::sleep_for(milliseconds(100));
        std::this_thread::sleep_for(milliseconds(500));
        CHECK(a.status().my_account == 333333u && b.status().my_account == 0);
        CHECK(b.status().peer_account == 333333u);  // Dan hears Carol's account
        CHECK(a.status().peer_account == 0);        // Dan's folder has no account in its path, so he says nothing
        const auto log = b.drain_log();
        CHECK(count_lines(log, "not a standard userdata") == 1);
        a.stop();
        b.stop();
    }
    // --- the loopback bot answers like a real player's exe: same PC, same account ---
    {
        const fs::path sl = tmp / "acct_l" / "userdata" / "444444" / "418370" / "remote" / "win64_save";
        fs::create_directories(sl);
        Config cl;
        cl.data_dir = tmp / "acct_st_l";
        cl.mode = Mode::Loopback;
        cl.transport = Transport::TcpHost;
        cl.listen_port = 28963;
        cl.save_sync = true;
        cl.save_dir = sl;
        cl.name = "Me";
        Engine l;
        std::string err;
        CHECK(l.start(cl, err));
        for (int i = 0; i < 100 && l.status().peer_account == 0; ++i) std::this_thread::sleep_for(milliseconds(100));
        CHECK(l.status().my_account == 444444u && l.status().peer_account == 444444u);
        CHECK(count_lines(l.drain_log(), "the same as this PC's") == 1);
        l.stop();
    }
    std::printf("  steam accounts: folder by account, both ids swapped between two exes, manifest names them\n");
}

// (9.32) The game lists only 15 saves. A co-op save that arrives while all 15 slots hold a file replaces the OLDEST co-op copy that was
// installed here (and says so); when all 15 hold saves of your own it is not installed, and the message says why. Nothing is put past slot 15.
static void test_save_slots_full(const fs::path& tmp) {
    const fs::path sa = tmp / "full_a", sb = tmp / "full_b", sc = tmp / "full_c";
    fs::create_directories(sa);
    fs::create_directories(sb);
    fs::create_directories(sc);
    Config ca, cb;
    ca.data_dir = tmp / "full_st_a";
    cb.data_dir = tmp / "full_st_b";
    ca.mode = cb.mode = Mode::Network;
    ca.transport = Transport::TcpHost;
    cb.transport = Transport::TcpJoin;
    ca.listen_port = 28977;
    cb.peer_host = "127.0.0.1";
    cb.peer_port = 28977;
    ca.name = "Alice";
    cb.name = "Bob";
    ca.save_sync = cb.save_sync = true;
    ca.save_dir = sa;
    cb.save_dir = sb;
    ca.save_stable_ms = cb.save_stable_ms = 300;

    // Bob has all 15 slots taken. 2 and 9 are copies of saves of Zed's that were installed here (2 the older); 14 is a save of his own that he
    // sent to Zed long ago (never replaced, however old); the rest are saves of his own.
    std::vector<std::vector<uint8_t>> bob(static_cast<size_t>(kMaxSlot) + 1);
    for (int i = 1; i <= kMaxSlot; ++i) {
        bob[static_cast<size_t>(i)] = random_bytes(2000 + static_cast<size_t>(i), 700 + static_cast<uint32_t>(i));
        write_bytes(sb / slot_filename(i), bob[static_cast<size_t>(i)]);
    }
    fs::create_directories(cb.data_dir);
    {
        CoopManifest pre(cb.data_dir / "re7mp_coop_saves.json");
        auto add = [&](int slot, const char* when, const char* role, int from_slot) {
            CoopEntry c;
            c.slot = slot;
            c.when = when;
            c.label = std::string("CO-OP Zed ") + when;
            c.from = c.partner = "Zed";
            c.role = role;
            c.from_slot = from_slot;
            c.crc = crc32(bob[static_cast<size_t>(slot)].data(), bob[static_cast<size_t>(slot)].size());
            c.size = bob[static_cast<size_t>(slot)].size();
            pre.upsert(c);
        };
        add(9, "2020-03-01 10:00", "received", 1);
        add(2, "2019-10-15 08:00", "received", 3);
        add(14, "2018-01-01 00:00", "sent", 0);
        CHECK(pre.save("", true));
    }
    Engine a, b;
    std::string err;
    CHECK(a.start(ca, err) && b.start(cb, err));
    std::this_thread::sleep_for(milliseconds(1800));

    const auto first = random_bytes(50 * 1024, 71);
    write_bytes(sa / "data005Slot.bin", first);
    std::this_thread::sleep_for(milliseconds(3000));
    CHECK(read_bytes(sb / "data002Slot.bin") == first);  // the oldest co-op copy (2) was replaced
    bool untouched = true;
    for (int i = 1; i <= kMaxSlot; ++i) {
        if (i != 2 && read_bytes(sb / slot_filename(i)) != bob[static_cast<size_t>(i)]) untouched = false;
    }
    CHECK(untouched);                                        // ...and nothing else was touched: not the newer copy (9), not the one he sent (14), none of his own
    CHECK(!fs::exists(sb / "data016Slot.bin"));              // nothing past the 15th
    {
        CoopManifest mb(cb.data_dir / "re7mp_coop_saves.json");
        mb.load();
        const CoopEntry* got = nullptr;
        for (const auto& e : mb.entries()) {
            if (e.slot == 2) got = &e;
        }
        CHECK(mb.entries().size() == 3 && got != nullptr && got->from == "Alice" && got->role == "received" && got->from_slot == 5);
        CHECK(got != nullptr && got->why.find("all 15 save slots were taken, so it replaced your oldest co-op copy (from Zed, received 2019-10-15 08:00)") != std::string::npos);
        CHECK(mb.is_coop_slot(14) && !mb.is_received_slot(14) && mb.is_received_slot(9));
    }
    CHECK(b.status().last_save_event.find("installed in slot 2") != std::string::npos &&
          b.status().last_save_event.find("replaced your oldest co-op copy") != std::string::npos && b.status().saves_received == 1);

    // The next save goes the same way: the oldest copy now is slot 9 (the one in slot 2 is new).
    const auto second = random_bytes(40 * 1024, 72);
    write_bytes(sa / "data006Slot.bin", second);
    std::this_thread::sleep_for(milliseconds(3000));
    CHECK(read_bytes(sb / "data009Slot.bin") == second && read_bytes(sb / "data002Slot.bin") == first);
    CHECK(!fs::exists(sb / "data016Slot.bin") && read_bytes(sb / "data014Slot.bin") == bob[14]);
    a.stop();
    b.stop();

    // All 15 slots hold saves of Bob's own: no co-op copy that could be replaced, so the save is not installed and the message says what to do.
    std::vector<std::vector<uint8_t>> own(static_cast<size_t>(kMaxSlot) + 1);
    for (int i = 1; i <= kMaxSlot; ++i) {
        own[static_cast<size_t>(i)] = random_bytes(1500 + static_cast<size_t>(i), 900 + static_cast<uint32_t>(i));
        write_bytes(sc / slot_filename(i), own[static_cast<size_t>(i)]);
    }
    Config cc = cb;
    cc.data_dir = tmp / "full_st_c";
    cc.save_dir = sc;
    Config ca2 = ca;
    ca2.data_dir = tmp / "full_st_a2";
    Engine a2, c;
    std::this_thread::sleep_for(milliseconds(500));
    CHECK(a2.start(ca2, err) && c.start(cc, err));
    std::this_thread::sleep_for(milliseconds(1800));
    write_bytes(sa / "data007Slot.bin", random_bytes(30 * 1024, 73));
    std::this_thread::sleep_for(milliseconds(3000));
    CHECK(c.status().saves_received == 0);
    CHECK(c.status().last_save_event.find("No save slot for the co-op save from Alice") != std::string::npos &&
          c.status().last_save_event.find("all of them hold saves of your own") != std::string::npos &&
          c.status().last_save_event.find("Delete one in the game") != std::string::npos);
    bool own_untouched = true;
    int n_files = 0;
    for (int i = 1; i <= kMaxSlot; ++i) {
        if (read_bytes(sc / slot_filename(i)) != own[static_cast<size_t>(i)]) own_untouched = false;
    }
    for (const auto& e : fs::directory_iterator(sc)) { (void)e; ++n_files; }
    CHECK(own_untouched && n_files == kMaxSlot);             // his own saves are never overwritten, and nothing was added
    a2.stop();
    c.stop();
    std::printf("  full save folder: the oldest co-op copy is replaced; with 15 saves of his own nothing is installed\n");
}

static void test_save_loopback_echo(const fs::path& tmp) {
    std::string err;
    // Loopback over TCP: the bot sends your save back as its own co-op save.
    const fs::path saves = tmp / "lb_saves";
    fs::create_directories(saves);
    write_bytes(saves / "data002Slot.bin", random_bytes(1000, 2));  // an existing single-player save
    Config cl;
    cl.data_dir = tmp / "lb_data";
    cl.mode = Mode::Loopback;
    cl.transport = Transport::TcpHost;
    cl.listen_port = 28995;
    cl.save_sync = true;
    cl.save_dir = saves;
    cl.save_stable_ms = 300;
    cl.name = "Me";
    Engine l;
    CHECK(l.start(cl, err));
    // A save is only sent while the other player is there ("Saves you make while connected"). The bot appears about 2 s after the start, so
    // writing at a fixed 1.5 s raced it and failed about half the time: wait until its name has arrived.
    for (int i = 0; i < 100 && l.status().remote_name.empty(); ++i) std::this_thread::sleep_for(milliseconds(100));
    CHECK(l.status().remote_name == "Loopback Bot");
    std::this_thread::sleep_for(milliseconds(500));
    const auto mine = random_bytes(100 * 1024, 3);
    write_bytes(saves / "data002Slot.bin", mine);
    for (int i = 0; i < 100 && !(fs::exists(saves / "data003Slot.bin") && read_bytes(saves / "data003Slot.bin") == mine); ++i) {
        std::this_thread::sleep_for(milliseconds(100));  // up to 10 s: a slow or busy machine is fine
    }
    std::this_thread::sleep_for(milliseconds(300));
    CHECK(fs::exists(saves / "data003Slot.bin") && read_bytes(saves / "data003Slot.bin") == mine);
    CoopManifest ml(cl.data_dir / "re7mp_coop_saves.json");
    ml.load();
    CHECK(ml.entries().size() == 2);  // the copy in slot 3 from the bot (one past your highest), and your own slot 2, shared with the bot
    for (const auto& le : ml.entries()) {
        if (le.slot == 3) CHECK(le.role == "received" && le.partner == "Loopback Bot" && le.label.rfind("CO-OP Loopback Bot ", 0) == 0);
        else CHECK(le.slot == 2 && le.role == "sent" && le.partner == "Loopback Bot");
    }
    l.stop();
}

// Loopback over TCP: the bot plays the host and sends two pretend enemies, one circling it, one standing still.
static void test_loopback_enemies(const fs::path& tmp) {
    const fs::path dir = tmp / "lb_enemies";
    Engine e;
    Config cfg;
    cfg.data_dir = dir;
    cfg.mode = Mode::Loopback;
    cfg.transport = Transport::TcpHost;
    cfg.listen_port = 28987;
    std::string err;
    CHECK(e.start(cfg, err));
    fs::create_directories(dir);
    std::thread g([&] { fake_game(dir, 100.0, 200.0, 2600, nullptr); });
    std::this_thread::sleep_for(milliseconds(1200));
    std::string first, second;
    double n1 = 0, n2 = 0;
    CHECK(read_state(dir, first, &n1));
    std::this_thread::sleep_for(milliseconds(700));
    CHECK(read_state(dir, second, &n2));
    g.join();
    CHECK(n2 > n1 && n1 >= 1);  // snapshots keep arriving
    // two entries, "Em3000" (Jack's id, circling the bot; 9.35) and "Em9998" (8 m from where you first were, standing still), 13 fields each
    auto fields = [](const std::string& blob) {
        std::vector<std::vector<std::string>> rows;
        std::stringstream ss(blob);
        std::string entry;
        while (std::getline(ss, entry, ';')) {
            std::vector<std::string> f;
            std::stringstream es(entry);
            std::string x;
            while (std::getline(es, x, ',')) f.push_back(x);
            rows.push_back(f);
        }
        return rows;
    };
    const auto r1 = fields(first), r2 = fields(second);
    CHECK(r1.size() == 2 && r2.size() == 2 && r1[0].size() == 13 && r1[0][0] == "Em3000" && r1[1][0] == "Em9998");
    if (r1.size() == 2 && r2.size() == 2) {
        CHECK(r1[1][1] == r2[1][1] && r1[1][3] == r2[1][3]);   // the standing one has not moved
        CHECK(r1[0][1] != r2[0][1] || r1[0][3] != r2[0][3]);   // the orbiting one has
        CHECK(std::fabs(std::stod(r1[1][1]) - 108.0) < 1.0);  // 8 m along x from where the fake game first stood (x=100)
    }
    CHECK(e.status().states_received >= 2 && e.status().states_sent == 0);
    e.stop();
}


// ---- versions --------------------------------------------------------------------------------

// A datagram from a re7mp.exe with another protocol version, built the way the real one would be (same header).
static std::vector<uint8_t> packet_with_version(uint8_t version) {
    PositionPacket p = make_position(1234, 1, 1, 2, 3, 0, 0, 0, 1, 0);
    p.h.version = version;
    const auto* b = reinterpret_cast<const uint8_t*>(&p);
    return std::vector<uint8_t>(b, b + sizeof(p));
}

static void test_versions(const fs::path& tmp) {
    // The release number: "0.<n>", and the same in the Lua script as in src/version.hpp.
    CHECK(std::regex_match(std::string(kReleaseVersion), std::regex("[0-9]+\\.[0-9]+(\\.[0-9]+)?")));
    const std::string lua = read_text(RE7MP_LUA_PATH);
    std::smatch m;
    CHECK(std::regex_search(lua, m, std::regex("RELEASE = \"([0-9.]+)\"")));
    CHECK(m.size() > 1 && m[1].str() == kReleaseVersion);

    // Foreign-version detection: ours is not "foreign", another protocol version is, garbage is neither.
    const auto ours = packet_with_version(kProtocolVersion);
    const auto old5 = packet_with_version(5);
    const auto new9 = packet_with_version(9);
    CHECK(peek_foreign_version(ours.data(), ours.size()) == -1 && peek_type(ours.data(), ours.size()) >= 0);
    CHECK(peek_foreign_version(old5.data(), old5.size()) == 5 && peek_type(old5.data(), old5.size()) == -1);
    CHECK(peek_foreign_version(new9.data(), new9.size()) == 9);
    CHECK(peek_foreign_version("hello world, this is not ours", 29) == -1);
    CHECK(peek_foreign_version(ours.data(), 4) == -1);

    // An engine receiving a packet from another protocol version reports it, and clears it when a good packet arrives.
    Engine e;
    Config c;
    c.data_dir = tmp / "ver";
    c.mode = Mode::Network;
    c.transport = Transport::TcpHost;
    c.listen_port = 28967;
    c.name = "Eve";
    std::string err;
    CHECK(e.start(c, err));
    std::string uerr;
    auto tcp = TcpTransport::create(TcpTransport::Role::Join, 0, "127.0.0.1", 28967, uerr);
    CHECK(tcp != nullptr);
    if (tcp) {
        uint8_t rb[512];
        for (int i = 0; i < 150 && !tcp->connected(); ++i) tcp->recv(rb, sizeof(rb), 20);  // the client connects while we poll it
        CHECK(tcp->connected());
        for (int i = 0; i < 20; ++i) {
            tcp->send(old5.data(), old5.size());
            tcp->recv(rb, sizeof(rb), 25);
        }
        CHECK(e.status().foreign_protocol == 5);
        CHECK(count_lines(e.drain_log(), "protocol 5, yours uses") == 1);  // said once, not for every packet
        for (int i = 0; i < 20; ++i) {
            tcp->send(ours.data(), ours.size());
            tcp->recv(rb, sizeof(rb), 25);
        }
        CHECK(e.status().foreign_protocol == 0);
    }
    e.stop();
}


// ============================================================================================
// Zip unpacking, the update check, the exe swap and the REFramework installer
// ============================================================================================
static std::vector<uint8_t> test_text_block(int n) {  // mirrors text_block() in tools/make_zip_fixtures.py
    std::string s;
    for (int i = 0; i < n; ++i) s += "The quick brown fox jumps over " + std::to_string(i) + " lazy dogs\n";
    return std::vector<uint8_t>(s.begin(), s.end());
}
static std::vector<uint8_t> test_fake_exe(size_t n, uint32_t seed) {  // mirrors fake_exe()
    auto v = random_bytes(n - 2, seed);
    v.insert(v.begin(), {'M', 'Z'});
    return v;
}
static std::vector<uint8_t> bytes_of(const std::string& s) { return std::vector<uint8_t>(s.begin(), s.end()); }
static std::vector<uint8_t> repeat_bytes(const std::string& s, int times) {
    std::string out;
    for (int i = 0; i < times; ++i) out += s;
    return bytes_of(out);
}

static const ZipEntry* find_entry(const std::vector<ZipEntry>& es, const std::string& name) {
    for (const auto& e : es) {
        if (e.name == name) return &e;
    }
    return nullptr;
}

static void test_zip_extract() {
    const fs::path data = fs::path(RE7MP_TEST_DATA);
    const auto zip = read_bytes(data / "sample.zip");
    std::vector<ZipEntry> es;
    std::string err;
    CHECK(zip_list(zip, es, err));
    CHECK(es.size() == 11);

    struct Want {
        const char* name;
        std::vector<uint8_t> bytes;
    };
    const Want wants[] = {
        {"hello.txt", bytes_of("Hello, zip!\n")},
        {"big_text.txt", test_text_block(3000)},
        {"random.bin", random_bytes(40000, 5)},
        {"stored.txt", repeat_bytes("stored, not deflated\n", 50)},
        {"empty.txt", {}},
        {"dir/nested.txt", repeat_bytes("nested\n", 100)},
        {"fast.bin", [] {
             auto v = test_text_block(500);
             const auto r = random_bytes(3000, 8);
             v.insert(v.end(), r.begin(), r.end());
             return v;
         }()},
    };
    for (const auto& w : wants) {
        const ZipEntry* e = find_entry(es, w.name);
        std::vector<uint8_t> got;
        std::string e2;
        CHECK(e != nullptr);
        if (!e) continue;
        const bool ok = zip_read(zip, *e, got, 1 << 20, e2);
        if (!ok) std::printf("    %s: %s\n", w.name, e2.c_str());
        CHECK(ok && got == w.bytes);
    }
    const ZipEntry* big = find_entry(es, "big_text.txt");
    CHECK(big && big->method == 8 && big->compressed_size < big->size / 4);      // really compressed (dynamic Huffman)
    CHECK(find_entry(es, "stored.txt")->method == 0);                             // really stored
    CHECK(find_entry(es, "dir/") && find_entry(es, "dir/")->is_dir);

    // Too large for the cap, and a wrong size claim.
    std::vector<uint8_t> out;
    CHECK(!zip_read(zip, *big, out, 1000, err) && err.find("too large") != std::string::npos);

    // A damaged copy is caught by the checksum; garbage and truncated files are refused politely.
    {
        const auto bad = read_bytes(data / "damaged.zip");
        std::vector<ZipEntry> bes;
        CHECK(zip_list(bad, bes, err));
        const ZipEntry* r = find_entry(bes, "random.bin");
        CHECK(r && !zip_read(bad, *r, out, 1 << 20, err) && err.find("checksum") != std::string::npos);
        CHECK(zip_read(bad, *find_entry(bes, "hello.txt"), out, 1 << 20, err));  // the other entries are fine
    }
    CHECK(!zip_list(bytes_of("not a zip at all, just some text that is long enough"), es, err));
    CHECK(!zip_list(std::vector<uint8_t>(zip.begin(), zip.begin() + 1000), es, err));
    CHECK(!zip_list({}, es, err));

    // Unsafe names are recognised; ordinary ones are normalised.
    CHECK(zip_safe_name("../escape.txt").empty() && zip_safe_name("a/../../b").empty() && zip_safe_name("/abs.txt").empty() &&
          zip_safe_name("C:/drive.txt").empty() && zip_safe_name("").empty() && zip_safe_name("a/b?.txt").empty());
    CHECK(zip_safe_name("back\\slash.txt") == "back/slash.txt" && zip_safe_name("dir//x/./y.dll") == "dir/x/y.dll" &&
          zip_safe_name("reframework/autorun/a.lua") == "reframework/autorun/a.lua");
    CHECK(zip_name_is("Some/Folder/DINPUT8.DLL", "dinput8.dll") && !zip_name_is("dinput8.dll.bak", "dinput8.dll") &&
          !zip_name_is("../dinput8.dll", "dinput8.dll"));

    // Raw inflate edge cases: an empty stream, a truncated one, and an output cap.
    const uint8_t fixed_empty[] = {0x03, 0x00};  // final fixed block with only the end code
    std::vector<uint8_t> ie;
    CHECK(inflate_raw(fixed_empty, 2, ie, 10, err) && ie.empty());
    CHECK(!inflate_raw(fixed_empty, 1, ie, 10, err));
    const uint8_t stored_abc[] = {0x01, 0x03, 0x00, 0xFC, 0xFF, 'a', 'b', 'c'};
    ie.clear();
    CHECK(inflate_raw(stored_abc, sizeof(stored_abc), ie, 10, err) && ie == bytes_of("abc"));
    ie.clear();
    CHECK(!inflate_raw(stored_abc, sizeof(stored_abc), ie, 2, err));  // larger than allowed
}

// A fake network: url -> body, with a list of what was asked for.
struct FakeHttp : HttpClient {
    std::map<std::string, std::vector<uint8_t>> pages;
    std::vector<std::string> asked;
    bool get(const std::string& url, std::vector<uint8_t>& body, std::string& err, const Progress& progress) override {
        asked.push_back(url);
        const auto it = pages.find(url);
        if (it == pages.end()) {
            err = "HTTP 404 (not found)";
            return false;
        }
        body = it->second;
        if (progress) progress(body.size(), body.size());
        return true;
    }
};

static const char* kReleasesJson = R"([
 {"tag_name":"beta6","name":"v0.6","draft":false,"prerelease":true,"html_url":"https://github.com/kingkiller1195/re7mp/releases/tag/beta6","body":"Playtest build",
  "assets":[{"name":"re7mp.exe","size":120000,"browser_download_url":"https://github.com/kingkiller1195/re7mp/releases/download/beta6/re7mp.exe"}]},
 {"tag_name":"beta7","name":"v0.7","draft":true,"prerelease":false,"html_url":"x","body":"unpublished draft","assets":[]},
 {"tag_name":"beta5","name":"v0.5","draft":false,"prerelease":false,"html_url":"https://github.com/kingkiller1195/re7mp/releases/tag/beta5","body":"This has the new Item sync beta",
  "assets":[{"name":"re7mp.zip","size":90396,"browser_download_url":"https://github.com/kingkiller1195/re7mp/releases/download/beta5/re7mp.zip"}]},
 {"tag_name":"Beta","name":"v0.1","draft":false,"prerelease":false,"html_url":"y","body":"Unstable","assets":[]},
 {"tag_name":"mystery","name":"no version here","draft":false,"prerelease":false,"html_url":"z","body":"","assets":[]}
])";

static void test_update_check() {
    // Versions are compared as numbers; tags like "beta5" are not versions, the title is.
    CHECK(compare_versions("0.10", "0.9") > 0 && compare_versions("0.9", "0.10") < 0 && compare_versions("0.6", "0.6.0") == 0 &&
          compare_versions("1.0", "0.99") > 0 && compare_versions("0.6", "0.6") == 0 && compare_versions("2", "10") < 0);
    CHECK(release_version("v0.5", "beta5") == "0.5" && release_version("Beta", "Beta").empty() &&
          release_version("", "v0.6") == "0.6" && release_version("Version 0.7 beta", "x") == "0.7" &&
          release_version("", "beta5").empty() && release_version("Release 12", "").empty() &&
          release_version("v2", "") == "2" && release_version("", "0.6.1-rc1") == "0.6.1" && release_version("x", "0.6x").empty());

    // Picking from the release list: drafts never, pre-releases only on request, newest version wins (not newest position).
    ReleaseInfo r;
    std::string err;
    CHECK(pick_release(kReleasesJson, false, r, err) && r.version == "0.5" && r.tag == "beta5" && r.assets.size() == 1 &&
          r.assets[0].name == "re7mp.zip" && r.notes.find("Item sync") != std::string::npos);
    CHECK(pick_release(kReleasesJson, true, r, err) && r.version == "0.6" && r.prerelease && r.assets[0].name == "re7mp.exe");
    CHECK(pick_release(R"({"tag_name":"beta5","name":"v0.5","assets":[]})", false, r, err) && r.version == "0.5");  // "latest" returns one object
    CHECK(!pick_release(R"({"message":"Not Found"})", false, r, err) && err.find("Not Found") != std::string::npos);
    CHECK(!pick_release(R"({"message":"API rate limit exceeded for 1.2.3.4."})", false, r, err) && err.find("rate limit") != std::string::npos);
    CHECK(!pick_release("[]", false, r, err) && !pick_release("this is not json", false, r, err));

    // Only github links are followed.
    CHECK(url_is_github("https://github.com/a/b/releases/download/x/re7mp.exe") &&
          url_is_github("https://objects.githubusercontent.com/github-production-release-asset/abc") &&
          url_is_github("https://api.github.com/repos/a/b") && url_is_github("https://release-assets.githubusercontent.com/x?y=1"));
    CHECK(!url_is_github("http://github.com/x") && !url_is_github("https://evilgithub.com/x") && !url_is_github("https://github.com.evil.io/x") &&
          !url_is_github("https://github.com@evil.io/x") && !url_is_github("https://evil.io/github.com") && !url_is_github("ftp://github.com/x") &&
          !url_is_github("https://githubusercontent.com.evil.io/x"));

    // Which file of a release is the program.
    ReleaseInfo a;
    ReleaseAsset ch;
    a.assets = {{"notes.txt", "u1", 1}, {"re7mp-windows.zip", "u2", 1}, {"RE7MP.EXE", "u3", 1}};
    CHECK(choose_asset(a, ch) == AssetKind::Exe && ch.url == "u3");                 // an exe beats a zip
    a.assets = {{"source.zip", "u1", 1}, {"re7mp_v0.7.exe", "u2", 1}};
    CHECK(choose_asset(a, ch) == AssetKind::Exe && ch.url == "u2");
    a.assets = {{"re7mp-src.zip", "u1", 1}, {"re7mp.zip", "u2", 1}};
    CHECK(choose_asset(a, ch) == AssetKind::Zip && ch.url == "u2");
    a.assets = {{"notes.txt", "u1", 1}};
    CHECK(choose_asset(a, ch) == AssetKind::None);

    // The whole check, against a fake GitHub.
    FakeHttp http;
    http.pages[kReleasesApiLatest] = bytes_of(R"({"tag_name":"beta5","name":"v0.5","assets":[]})");
    http.pages[kReleasesApiList] = bytes_of(kReleasesJson);
    auto c = check_for_update(http, "0.4", false);
    CHECK(c.state == UpdateCheck::State::Available && c.release.version == "0.5" && c.message.find("0.5") != std::string::npos);
    c = check_for_update(http, "0.5", false);
    CHECK(c.state == UpdateCheck::State::UpToDate);
    c = check_for_update(http, "0.6", false);  // a newer internal build than the newest release: nothing to offer
    CHECK(c.state == UpdateCheck::State::UpToDate);
    c = check_for_update(http, "0.5", true);   // a playtester who opted in sees the pre-release
    CHECK(c.state == UpdateCheck::State::Available && c.release.version == "0.6" && http.asked.back() == kReleasesApiList);
    http.pages.clear();
    c = check_for_update(http, "0.5", false);
    CHECK(c.state == UpdateCheck::State::Failed && c.message.find("Could not check") != std::string::npos);
    http.pages[kReleasesApiLatest] = bytes_of("<html>captive portal</html>");
    CHECK(check_for_update(http, "0.5", false).state == UpdateCheck::State::Failed);
}

static void test_fetch_and_swap(const fs::path& tmp) {
    const fs::path data = fs::path(RE7MP_TEST_DATA);
    FakeHttp http;
    const std::string base = "https://github.com/kingkiller1195/re7mp/releases/download/beta6/";
    ReleaseInfo r;
    std::vector<uint8_t> exe;
    std::string err;

    // A plain exe asset.
    const auto the_exe = test_fake_exe(120000, 41);
    http.pages[base + "re7mp.exe"] = the_exe;
    r.assets = {{"re7mp.exe", base + "re7mp.exe", the_exe.size()}};
    CHECK(fetch_new_exe(http, r, exe, err, nullptr) && exe == the_exe);

    // A zip with re7mp.exe inside a folder.
    http.pages[base + "re7mp.zip"] = read_bytes(data / "release.zip");
    r.assets = {{"re7mp.zip", base + "re7mp.zip", 1}};
    CHECK(fetch_new_exe(http, r, exe, err, nullptr) && exe == test_fake_exe(90000, 31));

    // Things that must be refused.
    http.pages[base + "no.zip"] = read_bytes(data / "release_noexe.zip");
    r.assets = {{"no.zip", base + "no.zip", 1}};
    CHECK(!fetch_new_exe(http, r, exe, err, nullptr) && err.find("does not contain re7mp.exe") != std::string::npos);
    http.pages[base + "bad.exe"] = bytes_of(std::string(200000, 'x'));
    r.assets = {{"re7mp.exe", base + "bad.exe", 1}};
    CHECK(!fetch_new_exe(http, r, exe, err, nullptr) && err.find("Windows program") != std::string::npos && exe.empty());
    http.pages["https://evil.example/re7mp.exe"] = the_exe;
    r.assets = {{"re7mp.exe", "https://evil.example/re7mp.exe", 1}};
    CHECK(!fetch_new_exe(http, r, exe, err, nullptr) && err.find("not on github.com") != std::string::npos);
    r.assets = {{"notes.txt", base + "notes.txt", 1}};
    CHECK(!fetch_new_exe(http, r, exe, err, nullptr) && err.find("no re7mp.exe") != std::string::npos);
    r.assets = {{"re7mp.exe", base + "missing.exe", 1}};
    CHECK(!fetch_new_exe(http, r, exe, err, nullptr) && err.find("404") != std::string::npos);

    // Swapping the program: the old one is kept as .old, a second update replaces that, a failure leaves things as they were.
    const fs::path dir = tmp / "swap";
    fs::create_directories(dir);
    const fs::path cur = dir / "re7mp.exe";
    write_bytes(cur, test_fake_exe(70000, 1));
    CHECK(swap_in_new_exe(cur, test_fake_exe(70000, 2), err));
    CHECK(read_bytes(cur) == test_fake_exe(70000, 2) && read_bytes(dir / "re7mp.exe.old") == test_fake_exe(70000, 1) && !fs::exists(dir / "re7mp.exe.new"));
    CHECK(swap_in_new_exe(cur, test_fake_exe(70000, 3), err));
    CHECK(read_bytes(cur) == test_fake_exe(70000, 3) && read_bytes(dir / "re7mp.exe.old") == test_fake_exe(70000, 2));
    cleanup_old_exe(cur);
    CHECK(fs::exists(cur) && !fs::exists(dir / "re7mp.exe.old"));
    CHECK(!swap_in_new_exe(dir / "nothere" / "re7mp.exe", test_fake_exe(70000, 4), err) && !fs::exists(dir / "nothere"));
    fs::remove(cur);
    CHECK(!swap_in_new_exe(cur, test_fake_exe(70000, 5), err) && !fs::exists(cur) && !fs::exists(dir / "re7mp.exe.new"));  // no program to move aside
}

static void test_reframework_install(const fs::path& tmp) {
    const fs::path data = fs::path(RE7MP_TEST_DATA);
    const std::string url = reframework_url(kReframeworkTag);
    CHECK(url == std::string("https://github.com/praydog/REFramework/releases/download/") + kReframeworkTag + "/RE7.zip");
    FakeHttp http;
    http.pages[url] = read_bytes(data / "refw.zip");
    std::string msg;

    // A clean game folder: everything in the zip lands where it belongs, and nothing escapes the folder.
    const fs::path game = tmp / "refw_game";
    fs::create_directories(game);
    write_text(game / "re7.exe", "pretend game");
    CHECK(reframework_state(game).kind == RefwState::Kind::Missing);
    CHECK(install_reframework(http, game, kReframeworkTag, false, false, msg, nullptr));
    std::printf("  refw: %s\n", msg.c_str());
    CHECK(read_bytes(game / "dinput8.dll") == test_fake_exe(80000, 21) && read_bytes(game / "openvr_api.dll") == test_fake_exe(70000, 22));
    CHECK(fs::exists(game / "reframework" / "autorun" / "example.lua") && fs::exists(game / "reframework" / "data" / "readme.txt"));
    CHECK(!fs::exists(tmp / "outside.dll") && !fs::exists(tmp.parent_path() / "outside.dll") && msg.find("unsafe") != std::string::npos);
    CHECK(reframework_state(game).kind == RefwState::Kind::InstalledByUs && reframework_state(game).tag == kReframeworkTag);
    CHECK(msg.find("Installed REFramework") != std::string::npos && msg.find("3 files") == std::string::npos);

    // Doing it again changes nothing and says so; a script of yours in the reframework folder is never overwritten.
    write_text(game / "reframework" / "autorun" / "example.lua", "-- my own version\n");
    write_text(game / "reframework" / "autorun" / "re7mp.lua", "-- the mod's script\n");
    CHECK(install_reframework(http, game, kReframeworkTag, true, false, msg, nullptr));
    CHECK(msg.find("already installed and up to date") != std::string::npos || msg.find("left as they are") != std::string::npos);
    CHECK(read_bytes(game / "reframework" / "autorun" / "example.lua") == bytes_of("-- my own version\n"));
    CHECK(fs::exists(game / "reframework" / "autorun" / "re7mp.lua") && !fs::exists(game / "dinput8.dll.bak"));

    // Someone else's dinput8.dll: left alone unless you say replace, then kept as a backup.
    const fs::path game2 = tmp / "refw_game2";
    fs::create_directories(game2);
    write_bytes(game2 / "dinput8.dll", test_fake_exe(60000, 99));
    CHECK(reframework_state(game2).kind == RefwState::Kind::InstalledOther);
    http.asked.clear();
    CHECK(!install_reframework(http, game2, kReframeworkTag, false, false, msg, nullptr) && http.asked.empty());  // not even downloaded
    CHECK(read_bytes(game2 / "dinput8.dll") == test_fake_exe(60000, 99) && !fs::exists(game2 / "openvr_api.dll"));
    CHECK(install_reframework(http, game2, kReframeworkTag, true, false, msg, nullptr));
    CHECK(read_bytes(game2 / "dinput8.dll") == test_fake_exe(80000, 21) && read_bytes(game2 / "dinput8.dll.bak") == test_fake_exe(60000, 99));
    CHECK(msg.find("dinput8.dll.bak") != std::string::npos && reframework_state(game2).kind == RefwState::Kind::InstalledByUs);
    // A later manual change makes it "someone else's" again.
    write_bytes(game2 / "dinput8.dll", test_fake_exe(80001, 5));
    CHECK(reframework_state(game2).kind == RefwState::Kind::InstalledOther);

    // dll-only mode.
    const fs::path game3 = tmp / "refw_game3";
    fs::create_directories(game3);
    CHECK(install_reframework(http, game3, kReframeworkTag, false, true, msg, nullptr));
    CHECK(fs::exists(game3 / "dinput8.dll") && !fs::exists(game3 / "openvr_api.dll") && !fs::exists(game3 / "reframework" / "data" / "readme.txt"));
    CHECK(fs::is_directory(game3 / "reframework" / "autorun"));  // the script still has its folder

    // Failures change nothing: no download, a zip without the loader, a damaged download, a missing game folder.
    const fs::path game4 = tmp / "refw_game4";
    fs::create_directories(game4);
    http.pages.clear();
    CHECK(!install_reframework(http, game4, kReframeworkTag, false, false, msg, nullptr) && msg.find("Could not download") != std::string::npos);
    http.pages[url] = read_bytes(data / "refw_noloader.zip");
    CHECK(!install_reframework(http, game4, kReframeworkTag, false, false, msg, nullptr) && msg.find("dinput8.dll") != std::string::npos);
    http.pages[url] = read_bytes(data / "damaged.zip");
    CHECK(!install_reframework(http, game4, kReframeworkTag, false, false, msg, nullptr));
    http.pages[url] = bytes_of("<html>not a zip</html> and long enough to pass the size check");
    CHECK(!install_reframework(http, game4, kReframeworkTag, false, false, msg, nullptr));
    CHECK(fs::is_empty(game4));
    CHECK(!install_reframework(http, tmp / "no_such_folder", kReframeworkTag, false, false, msg, nullptr));
}


// 9.31: "Play as" (re7mp_char.json: the character chosen in the window, read by the Lua script)
static void test_character(const fs::path& tmp) {
    const fs::path dir = tmp / "char";
    fs::remove_all(dir);
    // the list: the keys the script knows (lua/re7mp.lua CFG.who.LIST + "auto"), in the order of the window's drop-down
    const auto& list = character_choices();
    CHECK(list.size() == 6);
    CHECK(std::string(list[0].key) == "auto" && std::string(list[1].key) == "ethan" && std::string(list[2].key) == "mia" &&
          std::string(list[3].key) == "clancy" && std::string(list[4].key) == "pete" && std::string(list[5].key) == "andre");  // 9.37: Pete, Andre
    CHECK(character_index("clancy") == 3 && character_index("andre") == 5 && character_valid("pete") && character_index("auto") == 0 && character_index("batman") == -1 && character_index("") == -1);
    CHECK(character_valid("mia") && !character_valid("Mia") && !character_valid("mia ") && !character_valid("../mia"));
    // nothing there yet
    std::string key;
    uint64_t seq = 99;
    CHECK(!read_character_choice(dir, key, seq));
    // a write creates the folder and the file, and reads back
    CHECK(write_character_choice(dir, "mia", 1234567));
    CHECK(fs::exists(dir / "re7mp_char.json") && !fs::exists(dir / "re7mp_char.tmp"));
    CHECK(read_character_choice(dir, key, seq) && key == "mia" && seq == 1234567);
    std::ifstream in(dir / "re7mp_char.json");
    std::stringstream ss;
    ss << in.rdbuf();
    CHECK(ss.str() == "{\"character\":\"mia\",\"seq\":1234567}\n");  // exactly what the script's json.load_file reads
    // a bad key is refused and the file is left as it was
    CHECK(!write_character_choice(dir, "batman", 5));
    CHECK(read_character_choice(dir, key, seq) && key == "mia" && seq == 1234567);
    // sync: nothing is written when it already says so (the script would be told again for nothing), a different key is
    bool wrote = true;
    CHECK(sync_character_choice(dir, "mia", &wrote) && !wrote);
    CHECK(read_character_choice(dir, key, seq) && seq == 1234567);
    CHECK(sync_character_choice(dir, "clancy", &wrote) && wrote);
    uint64_t seq2 = 0;
    CHECK(read_character_choice(dir, key, seq2) && key == "clancy" && seq2 != 1234567 && seq2 > 1700000000000ULL);
    CHECK(!sync_character_choice(dir, "batman", &wrote) && !wrote);
    // two writes in a row get different counters (the script applies a choice when the counter changes)
    CHECK(write_character_choice(dir, "ethan", character_seq_now()));
    uint64_t a = 0, b = 0;
    CHECK(read_character_choice(dir, key, a));
    std::this_thread::sleep_for(milliseconds(5));
    CHECK(write_character_choice(dir, "ethan", character_seq_now()));
    CHECK(read_character_choice(dir, key, b) && b > a);
    // damaged files are refused, not guessed at
    write_text(dir / "re7mp_char.json", "{\"character\":\"batman\",\"seq\":1}");
    CHECK(!read_character_choice(dir, key, seq));
    write_text(dir / "re7mp_char.json", "not json");
    CHECK(!read_character_choice(dir, key, seq));
    write_text(dir / "re7mp_char.json", "{\"character\":\"mia\"}");
    CHECK(read_character_choice(dir, key, seq) && key == "mia" && seq == 0);  // no counter: read as 0
    write_text(dir / "re7mp_char.json", "{\"character\":\"mia\",\"seq\":-5}");
    seq = 77;
    CHECK(read_character_choice(dir, key, seq) && key == "mia" && seq == 0);  // a negative counter is read as 0, not as a huge number
    // the rename fails (here the target is a folder, standing in for "the script has the file open"): the write says so and sync does not claim it
    {
        const fs::path blocked = tmp / "char_blocked";
        fs::remove_all(blocked);
        fs::create_directories(blocked / "re7mp_char.json" / "inside");
        CHECK(!write_character_choice(blocked, "mia", 1));
        bool w = true;
        CHECK(!sync_character_choice(blocked, "mia", &w) && !w);
        fs::remove_all(blocked);
    }
    // the engine's clean-up at start leaves the choice alone (it is the player's own standing choice)
    CHECK(write_character_choice(dir, "mia", 7));
    FileBridge(dir).clear_stale();
    CHECK(read_character_choice(dir, key, seq) && key == "mia" && seq == 7);
}

// 9.33: "Sync story cutscenes" (re7mp_story.json: the box in the window, read by the Lua script)
static void test_story_sync(const fs::path& tmp) {
    const fs::path dir = tmp / "story";
    fs::remove_all(dir);
    bool on = true;
    uint64_t seq = 99;
    CHECK(!read_story_sync(dir, on, seq));  // nothing there yet
    // a write creates the folder and the file, in the exact form the script's json.load_file reads
    CHECK(write_story_sync(dir, true, 1234567));
    CHECK(fs::exists(dir / "re7mp_story.json") && !fs::exists(dir / "re7mp_story.tmp"));
    CHECK(read_story_sync(dir, on, seq) && on && seq == 1234567);
    {
        std::ifstream in(dir / "re7mp_story.json");
        std::stringstream ss;
        ss << in.rdbuf();
        CHECK(ss.str() == "{\"story_sync\":true,\"seq\":1234567}\n");
    }
    CHECK(write_story_sync(dir, false, 1234568));
    CHECK(read_story_sync(dir, on, seq) && !on && seq == 1234568);
    {
        std::ifstream in(dir / "re7mp_story.json");
        std::stringstream ss;
        ss << in.rdbuf();
        CHECK(ss.str() == "{\"story_sync\":false,\"seq\":1234568}\n");
    }
    // sync: nothing is written when the file already says so (the script would be told again for nothing); a change gets a new number
    bool wrote = true;
    CHECK(sync_story_sync(dir, false, &wrote) && !wrote);
    CHECK(read_story_sync(dir, on, seq) && !on && seq == 1234568);
    CHECK(sync_story_sync(dir, true, &wrote) && wrote);
    uint64_t seq2 = 0;
    CHECK(read_story_sync(dir, on, seq2) && on && seq2 != 1234568 && seq2 > 1700000000000ULL);
    // a number that is not ahead of the old one (a clock that went back) is moved past it, so the script always sees something new
    CHECK(write_story_sync(dir, true, 99999999999999ULL));
    CHECK(sync_story_sync(dir, false, &wrote) && wrote);
    CHECK(read_story_sync(dir, on, seq) && !on && seq == 100000000000000ULL);
    // damaged files are refused, not guessed at
    write_text(dir / "re7mp_story.json", "{\"story_sync\":\"yes\",\"seq\":1}");
    CHECK(!read_story_sync(dir, on, seq));
    write_text(dir / "re7mp_story.json", "{\"story_sync\":1,\"seq\":1}");
    CHECK(!read_story_sync(dir, on, seq));
    write_text(dir / "re7mp_story.json", "not json");
    CHECK(!read_story_sync(dir, on, seq));
    write_text(dir / "re7mp_story.json", "{\"story_sync\":true}");
    CHECK(read_story_sync(dir, on, seq) && on && seq == 0);  // no counter: read as 0
    write_text(dir / "re7mp_story.json", "{\"story_sync\":true,\"seq\":-5}");
    seq = 77;
    CHECK(read_story_sync(dir, on, seq) && on && seq == 0);  // a negative counter is read as 0, not as a huge number
    // a file that can't be read does not stop sync from writing a good one
    write_text(dir / "re7mp_story.json", "not json");
    CHECK(sync_story_sync(dir, true, &wrote) && wrote);
    CHECK(read_story_sync(dir, on, seq) && on && seq > 1700000000000ULL);
    // the rename fails (the target is a folder, standing in for "the script has the file open"): the write says so and sync does not claim it
    {
        const fs::path blocked = tmp / "story_blocked";
        fs::remove_all(blocked);
        fs::create_directories(blocked / "re7mp_story.json" / "inside");
        CHECK(!write_story_sync(blocked, true, 1));
        bool w = true;
        CHECK(!sync_story_sync(blocked, true, &w) && !w);
        fs::remove_all(blocked);
    }
    // the engine's clean-up at start leaves the choice alone (it is the player's own standing choice)
    CHECK(write_story_sync(dir, true, 7));
    FileBridge(dir).clear_stale();
    CHECK(read_story_sync(dir, on, seq) && on && seq == 7);
}

int main() {
    const fs::path tmp = fs::temp_directory_path() / "re7mp_test_data";
    fs::remove_all(tmp);
    fs::create_directories(tmp);
    if (std::getenv("RE7MP_ONLY_RESIGN")) {  // quick run of the re-signing unit checks only (used for mutation testing)
        test_save_resign(tmp);
        fs::remove_all(tmp);
        std::printf(g_failed ? "%d check(s) FAILED\n" : "resign checks passed\n", g_failed);
        return g_failed ? 1 : 0;
    }
    if (std::getenv("RE7MP_ONLY_ACCOUNTS")) {  // quick run of the Steam-account checks only
        test_save_accounts(tmp);
        fs::remove_all(tmp);
        std::printf(g_failed ? "%d check(s) FAILED\n" : "account checks passed\n", g_failed);
        return g_failed ? 1 : 0;
    }
    if (std::getenv("RE7MP_ONLY_SLOTS")) {  // quick run of the save-slot checks only (used for mutation testing)
        test_save_sync_units(tmp);
        test_save_slots_full(tmp);
        fs::remove_all(tmp);
        std::printf(g_failed ? "%d check(s) FAILED\n" : "slot checks passed\n", g_failed);
        return g_failed ? 1 : 0;
    }
    test_packets();
    test_character(tmp);
    test_story_sync(tmp);
    test_json_mini();
    test_message_packets();
    test_locator(tmp);
    test_install(tmp);
    test_bridge(tmp);
    test_bridge_messages(tmp);
    test_loopback(tmp);
    test_network(tmp);
    test_stationary_bot(tmp);
    test_bot_pose_schedule();
    test_follow_bot(tmp);
    test_bot_poses(tmp);
    test_loopback_messages_and_tcp(tmp, Transport::TcpHost, 28975, "tcp");
    test_bot_logic_units();
    test_bot_gifts_and_down(tmp);
    test_bot_friendly_fire(tmp);
    test_bot_character(tmp);
    test_bot_act(tmp);
    test_tcp_network(tmp);
    test_message_retransmission(tmp);
    test_file_packets();
    test_save_sync_units(tmp);
    test_save_transfer(tmp);
    test_save_resign(tmp);
    test_save_transfer_resign(tmp);
    test_save_accounts(tmp);
    test_save_slots_full(tmp);
    test_save_loopback_echo(tmp);
    test_state_packets(tmp);
    test_state_over_tcp(tmp);
    test_loopback_enemies(tmp);
    test_versions(tmp);
    test_zip_extract();
    test_update_check();
    test_fetch_and_swap(tmp);
    test_reframework_install(tmp);
    fs::remove_all(tmp);
    std::printf(g_failed ? "%d check(s) FAILED\n" : "all checks passed\n", g_failed);
    return g_failed ? 1 : 0;
}
