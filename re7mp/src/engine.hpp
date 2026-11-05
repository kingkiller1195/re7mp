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
    Network,   // talk to a real peer over UDP
    Loopback,  // a built-in fake Player 2 (reached over real UDP on 127.0.0.1) orbits you
};

struct Config {
    std::filesystem::path data_dir;  // <RE7 folder>/reframework/data
    Mode mode = Mode::Loopback;
    uint16_t listen_port = 27015;  // loopback mode also uses listen_port + 1
    std::string peer_host;         // network mode only
    uint16_t peer_port = 27015;
    std::string name = "Player";  // shown above you on the other player's screen
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

    Status status() const;
    std::vector<std::string> drain_log();  // returns and clears pending log lines

private:
    void run();
    void log(const std::string& msg);

    Config cfg_;
    std::unique_ptr<UdpTransport> net_;
    std::unique_ptr<UdpTransport> fake_;  // loopback mode only: the simulated Player 2
    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> running_{false};
    std::atomic<bool> name_dirty_{true};
    std::string name_;
    mutable std::mutex mu_;
    Status status_;
    std::vector<std::string> log_;
};

}  // namespace re7mp
