#pragma once
// The networking engine: reads the local position the Lua script writes, sends it to the
// peer, and publishes the peer's position back. Runs on its own thread. No GUI code here,
// so it is shared by the GUI exe, the CLI, and the tests.
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "steam_api.hpp"
#include "transport.hpp"

namespace re7mp {

enum class Mode {
    Network,   // talk to a real peer over TCP
    Loopback,  // (10.5: shown as "Ethan's friend") a built-in helper player (reached over real TCP on 127.0.0.1) that walks with you; no network
};

// TCP (UDP was removed in 9.7: nobody used it; players connect over a VPN (Radmin VPN is the recommended one) or a forwarded port), and since 10.10 the
// Steam relay (no port at all: the two players name each other's Steam ID; the lower Steam ID is the host).
enum class Transport {
    TcpHost,    // wait for the other player to connect (the default)
    TcpJoin,    // connect to the other player (who hosts)
    SteamHost,  // (10.10) over Steam's relay, and this player has the lower Steam ID
    SteamJoin,  // (10.10) over Steam's relay, and the other player has the lower Steam ID
};

// (10.5) Orbit is gone: the friend is a helper, it walks with you. (The script's one-state animation tests, "walk", "run" ..., still circle a spot.)
// (10.26) "Beside you" is gone too, and the window no longer picks the mode at all: the script does, with the F5 key in the game (kind 11
// "mode:follow" / "mode:stay", see bot_mode_command). The exe starts the friend following you.
enum class BotMode {
    Follow,      // (9.37; the default since 10.5) the friend walks after you (a walk when close, a run when far) and stops about 2 m away
    Stationary,  // the friend stays put (10.26: told by the script, where it stands now; the old teleport-to-you start is for Config / set_bot_mode / the CLI)
};

struct Config {
    std::filesystem::path data_dir;  // <RE7 folder>/reframework/data
    Mode mode = Mode::Loopback;
    uint16_t listen_port = 27015;  // loopback mode also uses listen_port + 1
    std::string peer_host;         // network mode only
    uint16_t peer_port = 27015;
    std::string name = "Player";  // shown above you on the other player's screen
    Transport transport = Transport::TcpHost;
    uint64_t peer_steam_id = 0;                                       // (10.10) Steam transports: the other player's SteamID64
    std::function<std::unique_ptr<ISteamApi>()> steam_api;            // (10.10) makes the Steam interface (the exe: the game's own steam_api64.dll; the tests: a mock)
    BotMode bot_mode = BotMode::Follow;  // loopback mode only
    std::string bot_character;           // (10.5) the character the friend looks like (a key of bot_character_ok(): "ethan", "mia" ...); "" = it says nothing
    float bot_pose_first_s = 4.0f;      // loopback bot blocks, crouches and heals in a 16 s loop starting this many seconds in; < 0 = never
    // Co-op save sharing: saves made while connected are sent to the other player.
    bool save_sync = false;
    std::filesystem::path save_dir;  // ...\userdata\<id>\418370\remote\win64_save
    int save_stable_ms = 2500;       // a save must sit untouched this long before it is sent
};

struct Status {
    bool running = false;
    bool game_hooked = false;  // the Lua script wrote a position within the last ~1.5 s
    bool peer_active = false;  // a packet from the peer arrived within the last ~3 s
    bool have_local = false;
    bool have_remote = false;
    std::string remote_name;  // empty until the other player's name arrives
    float lx = 0, ly = 0, lz = 0;
    float rx = 0, ry = 0, rz = 0;
    uint64_t sent = 0;
    uint64_t received = 0;
    uint64_t messages_sent = 0;      // reliable messages queued by the game
    uint64_t messages_received = 0;  // reliable messages delivered to the game
    uint64_t saves_sent = 0;
    uint64_t saves_received = 0;
    uint64_t states_sent = 0;      // enemy snapshots sent (TCP only)
    uint64_t states_received = 0;  // enemy snapshots received
    std::string last_save_event;
    uint32_t my_account = 0;    // (9.42) Steam32 id of the account whose save folder is watched (0 = not known)
    uint32_t peer_account = 0;  // (9.42) the other player's, as their re7mp.exe told us (0 = not told yet)
    int foreign_protocol = 0;  // nonzero: packets are arriving from a re7mp.exe with this (different) protocol version
};

class Engine {
public:
    Engine() = default;
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    // Opens the sockets and starts the worker thread. On failure returns false and fills err.
    bool start(const Config& cfg, std::string& err);
    void stop();
    bool running() const { return running_.load(); }

    // Changes the name sent to the other player (works while running).
    void set_name(const std::string& name);

    // Loopback bot controls (work while running).
    void set_bot_mode(BotMode mode);
    void set_bot_character(const std::string& key);  // (10.5) what the friend looks like; "", "auto" or "none" = it says nothing again
    void teleport_bot_here();  // stationary bot: move it to where you are now

    Status status() const;
    std::vector<std::string> drain_log();  // returns and clears pending log lines

private:
    void run();
    void log(const std::string& msg);

    Config cfg_;
    std::unique_ptr<ITransport> net_;
    std::unique_ptr<ITransport> fake_;  // loopback mode only: the simulated Player 2
    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> running_{false};
    std::atomic<bool> name_dirty_{true};
    std::atomic<int> bot_mode_{0};
    std::atomic<uint32_t> bot_char_ver_{0};  // (10.5) goes up each time the window picks the friend's look
    std::string bot_char_want_;              // (guarded by mu_)
    std::atomic<bool> bot_teleport_{false};
    std::string name_;
    mutable std::mutex mu_;
    Status status_;
    std::vector<std::string> log_;
};

}  // namespace re7mp
