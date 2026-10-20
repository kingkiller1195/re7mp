// RE7 Co-op - REFramework native plugin.
//
// REFramework's Lua environment is sandboxed (no sockets, no process spawning),
// so the network lives here and is exposed to Lua as the global table `mp_net`.
// All game logic stays in Lua (reframework/autorun/re7_mp/*.lua) so it can be
// hot-reloaded from the REFramework menu without restarting the game.
//
//   mp_net.host(port [, max_players=4 [, name]])  -> true | false, err
//   mp_net.join(ip, port [, name])                -> true | false, err
//   mp_net.stop()
//   mp_net.state()      -> "idle" | "hosting" | "connecting" | "connected"
//   mp_net.local_id()   -> integer (host is always 0)
//   mp_net.rtt()        -> milliseconds to the host (0 on the host)
//   mp_net.set_vr(bool)
//   mp_net.set_pose(flags, {21 numbers})   head(pos3,quat4) lhand(...) rhand(...)
//   mp_net.send_chat(text)                 -> bool
//   mp_net.send_user(kind, payload_string) -> bool   (kind 0..255; payload <= 900 bytes)
//   mp_net.poll()       -> array of event tables, see event_to_lua() below
//   mp_net.set_debug_loss(percent)
//
// IMPORTANT: this DLL statically links its own copy of Lua and operates on the
// lua_State REFramework hands us. Build it against the same Lua minor version
// REFramework embeds (check `print(_VERSION)` in the REFramework console).

#include <array>
#include <string>

extern "C" {
#include "lauxlib.h"
#include "lua.h"
}

#include <reframework/API.h>

#include "net.hpp"

namespace {

const REFrameworkPluginInitializeParam* g_param = nullptr;

// Deliberately leaked: the DLL can be unloaded during process teardown, and joining a
// thread from a static destructor under the loader lock is a classic deadlock. The Lua
// state-destroyed hook below calls stop() explicitly instead.
mp::Session& session() {
    static mp::Session* s = new mp::Session();
    return *s;
}

void set_int(lua_State* L, const char* k, lua_Integer v) {
    lua_pushinteger(L, v);
    lua_setfield(L, -2, k);
}
void set_str(lua_State* L, const char* k, const std::string& v) {
    lua_pushlstring(L, v.data(), v.size());
    lua_setfield(L, -2, k);
}

// Event table shapes:
//   {type="connected",    id=<my id>, text=<host name>}
//   {type="disconnected", text=<reason>}
//   {type="joined",       id=, text=<name>, flags=<bit0 = VR>}
//   {type="left",         id=}
//   {type="chat",         id=, text=}
//   {type="user",         id=, kind=, text=<payload>}
//   {type="pose",         id=, flags=, p={21 numbers}}
void event_to_lua(lua_State* L, const mp::Event& e) {
    lua_createtable(L, 0, 6);
    const char* type = "?";
    switch (e.type) {
        case mp::EventType::Connected: type = "connected"; break;
        case mp::EventType::Disconnected: type = "disconnected"; break;
        case mp::EventType::Joined: type = "joined"; break;
        case mp::EventType::Left: type = "left"; break;
        case mp::EventType::Chat: type = "chat"; break;
        case mp::EventType::User: type = "user"; break;
        case mp::EventType::Pose: type = "pose"; break;
    }
    lua_pushstring(L, type);
    lua_setfield(L, -2, "type");
    set_int(L, "id", e.id);
    switch (e.type) {
        case mp::EventType::Joined:
            set_int(L, "flags", e.flags);
            set_str(L, "text", e.text);
            break;
        case mp::EventType::User:
            set_int(L, "kind", e.kind);
            set_str(L, "text", e.text);
            break;
        case mp::EventType::Pose:
            set_int(L, "flags", e.flags);
            lua_createtable(L, mp::kPoseFloats, 0);
            for (int i = 0; i < mp::kPoseFloats; i++) {
                lua_pushnumber(L, static_cast<lua_Number>(e.pose[i]));
                lua_rawseti(L, -2, i + 1);
            }
            lua_setfield(L, -2, "p");
            break;
        default:
            if (!e.text.empty()) set_str(L, "text", e.text);
            break;
    }
}

// NOTE on error handling: luaL_check* may longjmp. Every function therefore does all of its
// argument checking *before* it creates any object with a destructor.

int l_host(lua_State* L) {
    lua_Integer port = luaL_checkinteger(L, 1);
    lua_Integer maxp = luaL_optinteger(L, 2, 4);
    const char* name = luaL_optstring(L, 3, "Player");
    if (port < 1 || port > 65535) return luaL_error(L, "port out of range");
    std::string err;
    bool ok = session().host(static_cast<uint16_t>(port), static_cast<uint8_t>(maxp), name, err);
    lua_pushboolean(L, ok);
    if (ok) return 1;
    lua_pushstring(L, err.c_str());
    return 2;
}

int l_join(lua_State* L) {
    const char* ip = luaL_checkstring(L, 1);
    lua_Integer port = luaL_checkinteger(L, 2);
    const char* name = luaL_optstring(L, 3, "Player");
    if (port < 1 || port > 65535) return luaL_error(L, "port out of range");
    std::string err;
    bool ok = session().join(ip, static_cast<uint16_t>(port), name, err);
    lua_pushboolean(L, ok);
    if (ok) return 1;
    lua_pushstring(L, err.c_str());
    return 2;
}

int l_stop(lua_State*) {
    session().stop();
    return 0;
}

int l_state(lua_State* L) {
    switch (session().state()) {
        case mp::State::Idle: lua_pushstring(L, "idle"); break;
        case mp::State::Hosting: lua_pushstring(L, "hosting"); break;
        case mp::State::Connecting: lua_pushstring(L, "connecting"); break;
        case mp::State::Connected: lua_pushstring(L, "connected"); break;
    }
    return 1;
}

int l_local_id(lua_State* L) {
    lua_pushinteger(L, session().local_id());
    return 1;
}

int l_rtt(lua_State* L) {
    lua_pushnumber(L, session().rtt_ms());
    return 1;
}

int l_set_vr(lua_State* L) {
    session().set_vr(lua_toboolean(L, 1) != 0);
    return 0;
}

int l_set_pose(lua_State* L) {
    lua_Integer flags = luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    std::array<float, mp::kPoseFloats> p{};
    for (int i = 0; i < mp::kPoseFloats; i++) {
        lua_rawgeti(L, 2, i + 1);
        p[i] = static_cast<float>(lua_tonumber(L, -1));  // missing entries read as 0
        lua_pop(L, 1);
    }
    session().set_local_pose(static_cast<uint8_t>(flags), p);
    return 0;
}

int l_send_chat(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);
    lua_pushboolean(L, session().send_chat(std::string(s, len)));
    return 1;
}

int l_send_user(lua_State* L) {
    lua_Integer kind = luaL_checkinteger(L, 1);
    size_t len = 0;
    const char* s = luaL_checklstring(L, 2, &len);
    if (kind < 0 || kind > 255) return luaL_error(L, "kind must be 0..255");
    lua_pushboolean(L, session().send_user(static_cast<uint8_t>(kind), std::string(s, len)));
    return 1;
}

int l_poll(lua_State* L) {
    auto events = session().drain();
    lua_createtable(L, static_cast<int>(events.size()), 0);
    lua_Integer i = 1;
    for (const auto& e : events) {
        event_to_lua(L, e);
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

int l_set_debug_loss(lua_State* L) {
    session().set_debug_loss(static_cast<int>(luaL_checkinteger(L, 1)));
    return 0;
}

const luaL_Reg kFuncs[] = {
    {"host", l_host},
    {"join", l_join},
    {"stop", l_stop},
    {"state", l_state},
    {"local_id", l_local_id},
    {"rtt", l_rtt},
    {"set_vr", l_set_vr},
    {"set_pose", l_set_pose},
    {"send_chat", l_send_chat},
    {"send_user", l_send_user},
    {"poll", l_poll},
    {"set_debug_loss", l_set_debug_loss},
    {nullptr, nullptr},
};

void on_lua_state_created(lua_State* L) {
    lua_newtable(L);
    luaL_setfuncs(L, kFuncs, 0);
    lua_pushstring(L, "re7_mp-net 0.1 (protocol 1)");
    lua_setfield(L, -2, "version");
    lua_setglobal(L, "mp_net");
}

// REFramework destroys the Lua state on "Reset scripts". Drop the connection with it so a
// reloaded script never talks to a session it no longer knows about.
void on_lua_state_destroyed(lua_State*) {
    session().stop();
}

}  // namespace

extern "C" {

__declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
    version->game_name = nullptr;  // not pinned to one game; the Lua side is what is RE7-specific
}

__declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    g_param = param;
    param->functions->on_lua_state_created(on_lua_state_created);
    param->functions->on_lua_state_destroyed(on_lua_state_destroyed);
    param->functions->log_info("[re7_mp] network plugin loaded (mp_net available to Lua)");
    return true;
}

}  // extern "C"
