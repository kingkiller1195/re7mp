// Test harness: loads the REAL plugin.cpp (the Lua bridge) into a REAL Lua 5.4 state, the same way
// REFramework would (initialize -> on_lua_state_created), then runs a Lua script against it.
// Extras for scripts: ARGS (command line), sleep_ms(ms), wall_clock() (seconds).
#include <chrono>
#include <cstdio>
#include <thread>

#include "../src/plugin.cpp"

extern "C" {
void luaL_openlibs(lua_State*);
lua_State* luaL_newstate(void);
}

static REFLuaStateCreatedCb g_created = nullptr;
static REFLuaStateDestroyedCb g_destroyed = nullptr;
static bool fake_created(REFLuaStateCreatedCb cb) { g_created = cb; return true; }
static bool fake_destroyed(REFLuaStateDestroyedCb cb) { g_destroyed = cb; return true; }
static void fake_log(const char* fmt, ...) { std::printf("[plugin log] %s\n", fmt); }

static int l_sleep_ms(lua_State* L) {
    std::this_thread::sleep_for(std::chrono::milliseconds(luaL_checkinteger(L, 1)));
    return 0;
}
static int l_wall_clock(lua_State* L) {
    using namespace std::chrono;
    lua_pushnumber(L, duration<double>(steady_clock::now().time_since_epoch()).count());
    return 1;
}

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: lua_harness script.lua [args...]\n"); return 2; }
    REFrameworkPluginVersion ver{};
    reframework_plugin_required_version(&ver);
    REFrameworkPluginFunctions fns{fake_created, fake_destroyed, fake_log};
    REFrameworkPluginInitializeParam param{nullptr, nullptr, &fns};
    if (!reframework_plugin_initialize(&param)) return 3;

    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    g_created(L);  // what REFramework does when it creates the script state

    lua_createtable(L, argc, 0);
    for (int i = 2; i < argc; i++) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 1); }
    lua_setglobal(L, "ARGS");
    lua_register(L, "sleep_ms", l_sleep_ms);
    lua_register(L, "wall_clock", l_wall_clock);

    int rc = 0;
    if (luaL_loadfilex(L, argv[1], nullptr) != LUA_OK || lua_pcallk(L, 0, 0, 0, 0, nullptr) != LUA_OK) {
        std::fprintf(stderr, "LUA ERROR: %s\n", lua_tolstring(L, -1, nullptr));
        rc = 1;
    }
    g_destroyed(L);  // what REFramework does on "Reset scripts"
    lua_close(L);
    return rc;
}
