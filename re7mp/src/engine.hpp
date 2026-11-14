#pragma once
// The networking engine: reads the local position the Lua script writes, sends it to the
// peer, and publishes the peer's position back. Runs on its own thread. No GUI code here,
// so it is shared by the GUI exe, the CLI, and the tests.
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "transport.hpp"

namespace re7mp {

enum class Mode {
    Network,   // talk to a real peer over TCP
    Loopback,  // a built-in fake Player 2 (reached over real TCP on 127.0.0.1) orbits you
};

// TCP only (UDP was removed in 9.7: nobody used it; players connect over a VPN (Radmin VPN is the recommended one) or a forwarded port).
enum class Transport {
    TcpHost,  // wait for the other player to connect (the default)
    TcpJoin,  // connect to the other player (who hosts)
};

enum class BotMode {
    Orbit,       // the loopback bot circles you
    Stationary,  // the loopback bot teleports to you, stays put, and keeps copying where your camera points
    Follow,      // (9.37) the loopback bot walks after you (a walk when close, a run when far) and stops about 2 m away
};

struct Config {
    std::filesystem::path data_dir;  // <RE7 folder>/reframework/data
    Mode mode = Mode::Loopback;
    uint16_t listen_port = 27015;  // loopback mode also uses listen_port + 1
    std::string peer_host;         // network mode only
    uint16_t peer_port = 27015;
    std::string name = "Player";  // shown above you on the other player's screen
    Transport transport = Transport::TcpHost;
    BotMode bot_mode = BotMode::Orbit;  // loopback mode only
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
    std::atomic<bool> bot_teleport_{false};
    std::string name_;
    mutable std::mutex mu_;
    Status status_;
    std::vector<std::string> log_;
};

}  // namespace re7mp
