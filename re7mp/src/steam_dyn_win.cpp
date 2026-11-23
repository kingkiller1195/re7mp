// (10.10) STEAM on Windows: see steam_dyn.hpp. Every function comes from the game's own steam_api64.dll by name (GetProcAddress), so a missing one is
// reported by name in the log instead of the exe failing to start, and the exe has no link-time dependency on Steam at all.
//
// The calls and structure layouts are the ones the other mod (Molded Together, CoopNet.cs) uses against the same DLL:
//   SteamNetworkingIdentity = 136 bytes, filled by SteamAPI_SteamNetworkingIdentity_SetSteamID64.
//   SteamNetworkingMessage_t: void* m_pData at 0, int m_cbSize at 8, the sender's SteamNetworkingIdentity at 16; freed with ..._t_Release.
//   FriendGameInfo_t starts with the CGameID; its low 24 bits are the app id (418370 = Resident Evil 7).
//   SteamNetConnectionInfo_t (696 bytes): m_idPOPRemote at 168, m_idPOPRelay at 172, m_eState at 176, m_eEndReason at 180, m_szEndDebug (128) at 184.
//
// (10.13) ONE Steam connection per exe run (struct Core below): started the first time anything needs Steam and never shut down until the exe ends. The
// friends menu and the link used to start and shut Steam down in turn (SteamAPI_Shutdown + FreeLibrary), and the app id was always the game's (418370),
// so to Steam the exe and the running game were two copies of the same program on one account: a session request from the other player could be handed
// to the game's own Steam connection, which never answers it ("relay ready (100)" and nothing else). The default is now Spacewar's 480.
#ifdef _WIN32
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <mutex>

#include "steam_dyn.hpp"

namespace re7mp {
namespace {

constexpr int kChannel = 7;  // the exe's own channel: the other mod uses another one, so the two cannot read each other's packets
constexpr int kSendNoNagle = 1;
constexpr int kSendReliable = 8;
constexpr int kSendAutoRestart = 32;
constexpr int kIdentitySize = 136;
constexpr int kInfoBuffer = 1024;        // SteamNetConnectionInfo_t is 696 bytes; a newer SDK may grow it, so ask for room
constexpr int kFriendFlagImmediate = 4;  // regular friends
constexpr int kMaxFriends = 400;

using Ptr = void*;
using Fn_Ptr = Ptr(__cdecl*)();
using Fn_Void = void(__cdecl*)();
using Fn_Bool = bool(__cdecl*)();
using Fn_InitFlat = int(__cdecl*)(char* errMsg);  // ESteamAPIInitResult (0 = OK); errMsg is 1024 bytes

const char* app_name(int id) {
    if (id == kSteamAppIdDefault) return "Spacewar";
    if (id == kSteamAppIdRe7) return "Resident Evil 7";
    return "custom";
}

// The one Steam connection of this process. Every SteamDyn (the link, the friends menu) is a thin handle onto it; calls are serialised with `mu`
// because the friends menu runs on its own thread while the link runs on the engine thread.
struct Core {
    std::mutex mu;
    std::string path, missing;
    HMODULE lib = nullptr;
    bool inited = false, ready = false;
    int app_id = 0;
    uint64_t self = 0;
    Fn_Void run = nullptr;
    Ptr msgs = nullptr, utils = nullptr, user = nullptr, friends = nullptr;
    uint64_t(__cdecl* f_get_id)(Ptr) = nullptr;
    const char*(__cdecl* f_persona)(Ptr) = nullptr;
    const char*(__cdecl* f_fname)(Ptr, uint64_t) = nullptr;
    int(__cdecl* f_fcount)(Ptr, int) = nullptr;
    uint64_t(__cdecl* f_fbyidx)(Ptr, int, int) = nullptr;
    int(__cdecl* f_fstate)(Ptr, uint64_t) = nullptr;
    bool(__cdecl* f_fgame)(Ptr, uint64_t, Ptr) = nullptr;
    void(__cdecl* f_reqinfo)(Ptr, uint64_t, bool) = nullptr;
    void(__cdecl* f_relay_init)(Ptr) = nullptr;
    int(__cdecl* f_relay_get)(Ptr, Ptr) = nullptr;
    void(__cdecl* f_id_clear)(Ptr) = nullptr;
    void(__cdecl* f_id_set)(Ptr, uint64_t) = nullptr;
    uint64_t(__cdecl* f_id_get)(Ptr) = nullptr;
    int(__cdecl* f_send)(Ptr, Ptr, const void*, uint32_t, int, int) = nullptr;
    int(__cdecl* f_recv)(Ptr, int, Ptr*, int) = nullptr;
    bool(__cdecl* f_accept)(Ptr, Ptr) = nullptr;
    void(__cdecl* f_release)(Ptr) = nullptr;
    // (10.13) optional: the session's own state and its closing. A DLL without them still carries data; the log just says less.
    int(__cdecl* f_sess_info)(Ptr, Ptr, Ptr, Ptr) = nullptr;
    bool(__cdecl* f_sess_close)(Ptr, Ptr) = nullptr;

    template <class F>
    F proc(const char* name, bool required) {
        F f = lib ? reinterpret_cast<F>(GetProcAddress(lib, name)) : nullptr;
        if (!f && required) {
            if (!missing.empty()) missing += ", ";
            missing += name;
        }
        return f;
    }
    static Ptr call(Fn_Ptr f) { return f ? f() : nullptr; }
    void make_identity(uint8_t* ident, uint64_t id) {
        std::memset(ident, 0, kIdentitySize);
        f_id_clear(ident);
        f_id_set(ident, id);
    }

    bool load(const std::vector<std::filesystem::path>& dirs, std::string& err) {
        if (lib) return true;
        std::string tried;
        for (const auto& d : dirs) {
            const std::filesystem::path p = d / L"steam_api64.dll";
            std::error_code ec;
            if (!std::filesystem::exists(p, ec)) continue;
            lib = LoadLibraryExW(p.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
            if (lib) {
                path = p.u8string();
                return true;
            }
            tried += (tried.empty() ? "" : "; ") + p.u8string() + " (Windows error " + std::to_string(GetLastError()) + ")";
        }
        err = tried.empty() ? "steam_api64.dll was not found (looked in the RE7 folder and Steam's folder): set the RE7 folder in the Install tab, or use the direct connection."
                            : "could not load steam_api64.dll: " + tried;
        return false;
    }
    void unload() {
        if (lib) FreeLibrary(lib);
        lib = nullptr;
        inited = ready = false;
        msgs = utils = user = friends = nullptr;
    }
    void abandon() {  // a start that failed half way: back to nothing, so the next try is a clean one
        if (inited) {
            if (auto sd = proc<Fn_Void>("SteamAPI_Shutdown", false)) sd();
        }
        unload();
    }

    // Starts Steam once. Called with `mu` held. A second call (any caller) finds it ready and returns at once.
    bool start(const std::vector<std::filesystem::path>& dirs, int want_app, std::string& err) {
        if (ready) return true;
        missing.clear();
        // The Steam interfaces ask which program this process is. It must be said BEFORE the DLL is loaded and started: both the process environment
        // and the C runtime's copy are set, since the DLL may read either.
        const std::string id = std::to_string(want_app);
        SetEnvironmentVariableA("SteamAppId", id.c_str());
        SetEnvironmentVariableA("SteamGameId", id.c_str());
        _putenv_s("SteamAppId", id.c_str());
        _putenv_s("SteamGameId", id.c_str());
        if (!load(dirs, err)) return false;
        char msg[1024] = {0};
        bool ok = false;
        if (auto init_flat = proc<Fn_InitFlat>("SteamAPI_InitFlat", false)) {
            const int r = init_flat(msg);
            ok = (r == 0);
            if (!ok) err = std::string("Steam did not start (answer ") + std::to_string(r) + "): " + (msg[0] ? msg : "no reason given");
        } else if (auto init = proc<Fn_Bool>("SteamAPI_Init", true)) {
            ok = init();
            if (!ok) err = "Steam did not start (SteamAPI_Init said no): is the Steam client running and signed in? Is it the same Windows user as the game?";
        } else {
            err = "steam_api64.dll has no SteamAPI_Init";
            unload();
            return false;
        }
        if (!ok) {
            unload();
            return false;
        }
        inited = true;
        app_id = want_app;
        run = proc<Fn_Void>("SteamAPI_RunCallbacks", true);
        auto acc = [&](const char* n) { return proc<Fn_Ptr>(n, true); };
        msgs = call(acc("SteamAPI_SteamNetworkingMessages_SteamAPI_v002"));
        utils = call(acc("SteamAPI_SteamNetworkingUtils_SteamAPI_v003"));
        user = call(acc("SteamAPI_SteamUser_v021"));
        friends = call(acc("SteamAPI_SteamFriends_v017"));
        if (!msgs || !utils || !user) {
            err = std::string("Steam started, but its interfaces are not available here (") + (!msgs ? "networking messages " : "") + (!utils ? "networking utils " : "") +
                  (!user ? "user " : "") + "missing): this steam_api64.dll is too old for the relay; the direct connection still works.";
            abandon();
            return false;
        }
        f_get_id = proc<uint64_t(__cdecl*)(Ptr)>("SteamAPI_ISteamUser_GetSteamID", true);
        f_persona = proc<const char*(__cdecl*)(Ptr)>("SteamAPI_ISteamFriends_GetPersonaName", false);
        f_fname = proc<const char*(__cdecl*)(Ptr, uint64_t)>("SteamAPI_ISteamFriends_GetFriendPersonaName", false);
        f_fcount = proc<int(__cdecl*)(Ptr, int)>("SteamAPI_ISteamFriends_GetFriendCount", false);
        f_fbyidx = proc<uint64_t(__cdecl*)(Ptr, int, int)>("SteamAPI_ISteamFriends_GetFriendByIndex", false);
        f_fstate = proc<int(__cdecl*)(Ptr, uint64_t)>("SteamAPI_ISteamFriends_GetFriendPersonaState", false);
        f_fgame = proc<bool(__cdecl*)(Ptr, uint64_t, Ptr)>("SteamAPI_ISteamFriends_GetFriendGamePlayed", false);
        f_reqinfo = proc<void(__cdecl*)(Ptr, uint64_t, bool)>("SteamAPI_ISteamFriends_RequestUserInformation", false);
        f_relay_init = proc<void(__cdecl*)(Ptr)>("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", true);
        f_relay_get = proc<int(__cdecl*)(Ptr, Ptr)>("SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus", true);
        f_id_clear = proc<void(__cdecl*)(Ptr)>("SteamAPI_SteamNetworkingIdentity_Clear", true);
        f_id_set = proc<void(__cdecl*)(Ptr, uint64_t)>("SteamAPI_SteamNetworkingIdentity_SetSteamID64", true);
        f_id_get = proc<uint64_t(__cdecl*)(Ptr)>("SteamAPI_SteamNetworkingIdentity_GetSteamID64", true);
        f_send = proc<int(__cdecl*)(Ptr, Ptr, const void*, uint32_t, int, int)>("SteamAPI_ISteamNetworkingMessages_SendMessageToUser", true);
        f_recv = proc<int(__cdecl*)(Ptr, int, Ptr*, int)>("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", true);
        f_accept = proc<bool(__cdecl*)(Ptr, Ptr)>("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", true);
        f_release = proc<void(__cdecl*)(Ptr)>("SteamAPI_SteamNetworkingMessage_t_Release", true);
        f_sess_info = proc<int(__cdecl*)(Ptr, Ptr, Ptr, Ptr)>("SteamAPI_ISteamNetworkingMessages_GetSessionConnectionInfo", false);
        f_sess_close = proc<bool(__cdecl*)(Ptr, Ptr)>("SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", false);
        if (!missing.empty()) {
            err = "steam_api64.dll lacks " + missing + ": it is too old for the relay; the direct connection still works.";
            abandon();
            return false;
        }
        self = f_get_id(user);
        if (f_relay_init) f_relay_init(utils);
        ready = true;
        return true;
    }
};

Core& core() {
    static Core* c = new Core();  // (never destroyed: Steam stays up until the exe ends, and nothing runs at exit that could touch a dead Steam)
    return *c;
}

class SteamDyn : public ISteamApi {
public:
    SteamDyn(std::vector<std::filesystem::path> dirs, int app_id) : dirs_(std::move(dirs)), app_id_(app_id) {}
    ~SteamDyn() override = default;  // (the Steam connection belongs to the process, not to this handle)

    bool init(std::string& err) override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (c.ready) {
            if (c.app_id != app_id_) note_ = "this exe run started Steam as app id " + std::to_string(c.app_id) + "; restart it to use " + std::to_string(app_id_);
            return true;
        }
        return c.start(dirs_, app_id_, err);
    }

    void run_callbacks() override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (c.ready && c.run) c.run();
    }
    uint64_t self_id() override {
        Core& c = core();
        return c.ready ? c.self : 0;
    }
    std::string self_name() override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (!c.ready || !c.friends || !c.f_persona) return std::string();
        const char* n = c.f_persona(c.friends);
        return n ? n : "";
    }
    int relay_status() override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        return c.ready ? c.f_relay_get(c.utils, nullptr) : 0;
    }
    std::string app_text() override {
        Core& c = core();
        if (!c.ready) return std::string();
        std::string t = "app id " + std::to_string(c.app_id) + " (" + app_name(c.app_id) + ")";
        if (!note_.empty()) t += "; " + note_;
        return t;
    }

    std::vector<SteamFriendInfo> friends() override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        std::vector<SteamFriendInfo> online, offline;
        if (!c.ready || !c.friends || !c.f_fcount || !c.f_fbyidx) return online;
        alignas(8) uint8_t info[64] = {0};  // FriendGameInfo_t is 24 bytes
        const int n = c.f_fcount(c.friends, kFriendFlagImmediate);
        for (int i = 0; i < n && i < kMaxFriends; ++i) {
            const uint64_t id = c.f_fbyidx(c.friends, i, kFriendFlagImmediate);
            if (id == 0) continue;
            SteamFriendInfo f;
            f.id = id;
            const char* nm = c.f_fname ? c.f_fname(c.friends, id) : nullptr;
            f.name = nm ? nm : "";
            f.online = c.f_fstate ? c.f_fstate(c.friends, id) != 0 : false;
            if (f.online && c.f_fgame) {
                std::memset(info, 0, sizeof(info));
                if (c.f_fgame(c.friends, id, info)) {
                    uint64_t gid = 0;
                    std::memcpy(&gid, info, sizeof(gid));
                    f.in_re7 = (gid & 0xFFFFFFULL) == static_cast<uint64_t>(kSteamAppIdRe7);
                }
            }
            (f.online ? online : offline).push_back(std::move(f));
        }
        // In RE7 first, then the other online friends, then the offline ones.
        std::stable_sort(online.begin(), online.end(), [](const SteamFriendInfo& a, const SteamFriendInfo& b) { return a.in_re7 && !b.in_re7; });
        online.insert(online.end(), std::make_move_iterator(offline.begin()), std::make_move_iterator(offline.end()));
        return online;
    }

    bool accept_session(uint64_t peer) override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (!c.ready) return false;
        alignas(8) uint8_t ident[kIdentitySize];
        c.make_identity(ident, peer);
        if (c.friends && c.f_reqinfo) c.f_reqinfo(c.friends, peer, true);  // so the friend's name is known by the time it is shown
        return c.f_accept(c.msgs, ident);
    }

    int send(uint64_t peer, const void* data, size_t len, bool reliable) override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (!c.ready || len == 0 || len > 512 * 1024) return 0;
        alignas(8) uint8_t ident[kIdentitySize];
        c.make_identity(ident, peer);
        const int flags = (reliable ? kSendReliable : 0) | kSendNoNagle | kSendAutoRestart;
        return c.f_send(c.msgs, ident, data, static_cast<uint32_t>(len), flags, kChannel);
    }

    void receive(std::vector<SteamMessage>& out, int max) override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (!c.ready) return;
        Ptr arr[32];
        if (max > 32) max = 32;
        const int n = c.f_recv(c.msgs, kChannel, arr, max);
        for (int i = 0; i < n; ++i) {
            const uint8_t* m = static_cast<const uint8_t*>(arr[i]);
            Ptr data = nullptr;
            int size = 0;
            std::memcpy(&data, m, sizeof(data));
            std::memcpy(&size, m + 8, sizeof(size));
            SteamMessage sm;
            sm.from = c.f_id_get(const_cast<uint8_t*>(m) + 16);
            if (data && size > 0) sm.data.assign(static_cast<const uint8_t*>(data), static_cast<const uint8_t*>(data) + size);
            c.f_release(arr[i]);
            out.push_back(std::move(sm));
        }
    }

    SteamSessionInfo session_info(uint64_t peer) override {
        SteamSessionInfo si;
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (!c.ready || !c.f_sess_info) return si;
        alignas(8) uint8_t ident[kIdentitySize];
        c.make_identity(ident, peer);
        alignas(8) uint8_t info[kInfoBuffer];
        std::memset(info, 0, sizeof(info));
        const int state = c.f_sess_info(c.msgs, ident, info, nullptr);
        si.known = true;
        si.state = state;
        if (state != 0) {  // (with no session the structure is not filled in)
            std::memcpy(&si.pop_remote, info + 168, sizeof(si.pop_remote));
            std::memcpy(&si.pop_relay, info + 172, sizeof(si.pop_relay));
            std::memcpy(&si.end_reason, info + 180, sizeof(si.end_reason));
            info[184 + 127] = 0;
            si.end_debug = reinterpret_cast<const char*>(info + 184);
        }
        return si;
    }

    void close_session(uint64_t peer) override {
        Core& c = core();
        std::lock_guard<std::mutex> g(c.mu);
        if (!c.ready || !c.f_sess_close) return;
        alignas(8) uint8_t ident[kIdentitySize];
        c.make_identity(ident, peer);
        c.f_sess_close(c.msgs, ident);
    }

private:
    std::vector<std::filesystem::path> dirs_;
    int app_id_;
    std::string note_;
};

}  // namespace

std::unique_ptr<ISteamApi> make_steam_api_dynamic(const std::vector<std::filesystem::path>& dirs, int app_id) {
    return std::make_unique<SteamDyn>(dirs, app_id > 0 ? app_id : kSteamAppIdDefault);
}

std::vector<SteamFriendInfo> steam_friends_once(const std::vector<std::filesystem::path>& dirs, std::string& err, int app_id) {
    auto api = make_steam_api_dynamic(dirs, app_id);
    if (!api->init(err)) return {};
    api->run_callbacks();
    auto list = api->friends();
    if (list.empty()) err = "Steam lists no friends for this account (or it has not loaded them yet: try again in a few seconds)";
    return list;
}

}  // namespace re7mp
#endif  // _WIN32
