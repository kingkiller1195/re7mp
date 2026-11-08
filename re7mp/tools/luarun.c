/* Minimal Lua 5.4 host (no headers needed): ./luarun script.lua [args...]
 * Only used to syntax-check and smoke-test lua/re7mp.lua away from the game.
 * Build: gcc -O1 -o luarun luarun.c /lib/x86_64-linux-gnu/liblua5.4.so.0 */
#include <stdio.h>
#include <stddef.h>
typedef struct lua_State lua_State;
extern lua_State *luaL_newstate(void);
extern void luaL_openlibs(lua_State *);
extern int luaL_loadfilex(lua_State *, const char *, const char *);
extern int lua_pcallk(lua_State *, int, int, int, long, void *);
extern const char *lua_tolstring(lua_State *, int, size_t *);
extern void lua_createtable(lua_State *, int, int);
extern void lua_rawseti(lua_State *, int, long long);
extern void lua_pushstring(lua_State *, const char *);
extern void lua_setglobal(lua_State *, const char *);
extern void lua_close(lua_State *);

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: luarun script.lua [args]\n"); return 2; }
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    lua_createtable(L, argc, 0);
    for (int i = 1; i < argc; ++i) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 1); }
    lua_setglobal(L, "arg");
    int rc = luaL_loadfilex(L, argv[1], NULL);
    if (rc == 0) rc = lua_pcallk(L, 0, 0, 0, 0, NULL);
    if (rc != 0) {
        const char *m = lua_tolstring(L, -1, NULL);
        fprintf(stderr, "%s\n", m ? m : "(error)");
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
