// re7mp_cli: headless front end for the engine (handy for debugging and scripts).
//   re7mp_cli --data-dir <game>/reframework/data --loopback
//   re7mp_cli --data-dir <game>/reframework/data --peer <host:port> [--listen <port>]
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

#include "engine.hpp"

namespace {
std::atomic<bool> g_run{true};
void on_signal(int) { g_run = false; }
}  // namespace

int main(int argc, char** argv) {
    re7mp::Config cfg;
    cfg.mode = re7mp::Mode::Network;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        const bool has_next = i + 1 < argc;
        if (a == "--loopback") {
            cfg.mode = re7mp::Mode::Loopback;
        } else if (a == "--name" && has_next) {
            cfg.name = argv[++i];
        } else if (a == "--data-dir" && has_next) {
            cfg.data_dir = argv[++i];
        } else if (a == "--listen" && has_next) {
            cfg.listen_port = static_cast<uint16_t>(std::atoi(argv[++i]));
        } else if (a == "--peer" && has_next) {
            const std::string v = argv[++i];
            const auto colon = v.rfind(':');
            cfg.peer_host = colon == std::string::npos ? v : v.substr(0, colon);
            if (colon != std::string::npos) cfg.peer_port = static_cast<uint16_t>(std::atoi(v.substr(colon + 1).c_str()));
        } else {
            std::fprintf(stderr, "usage: re7mp_cli --data-dir <dir> (--loopback | --peer <host:port>) [--listen <port>] [--name <name>]\n");
            return 2;
        }
    }
    if (cfg.data_dir.empty()) {
        std::fprintf(stderr, "--data-dir is required\n");
        return 2;
    }
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    re7mp::Engine engine;
    std::string err;
    if (!engine.start(cfg, err)) {
        std::fprintf(stderr, "error: %s\n", err.c_str());
        return 1;
    }
    while (g_run && engine.running()) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        for (const auto& line : engine.drain_log()) std::printf("%s\n", line.c_str());
        const auto s = engine.status();
        std::printf("hooked=%d peer=%d sent=%llu recv=%llu local=(%.2f,%.2f,%.2f) remote=(%.2f,%.2f,%.2f)\n", s.game_hooked,
                    s.peer_active, static_cast<unsigned long long>(s.sent), static_cast<unsigned long long>(s.received),
                    s.lx, s.ly, s.lz, s.rx, s.ry, s.rz);
        std::fflush(stdout);
    }
    engine.stop();
    for (const auto& line : engine.drain_log()) std::printf("%s\n", line.c_str());
    return 0;
}
