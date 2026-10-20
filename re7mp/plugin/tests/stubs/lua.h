/* TEST-ONLY minimal Lua 5.4 declarations (ABI-identical prototypes) so plugin.cpp can be built and run
 * on a machine that has liblua5.4.so but no Lua headers. The real build uses the real headers. */
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct lua_State lua_State;
typedef long long lua_Integer;
typedef double lua_Number;
typedef intptr_t lua_KContext;
typedef int (*lua_CFunction)(lua_State*);
typedef int (*lua_KFunction)(lua_State*, int, lua_KContext);
#define LUA_TTABLE 5
#define LUA_OK 0
#define LUA_MULTRET (-1)
int lua_gettop(lua_State*);
void lua_settop(lua_State*, int);
void lua_createtable(lua_State*, int, int);
void lua_setfield(lua_State*, int, const char*);
int lua_getfield(lua_State*, int, const char*);
void lua_pushinteger(lua_State*, lua_Integer);
void lua_pushnumber(lua_State*, lua_Number);
const char* lua_pushlstring(lua_State*, const char*, size_t);
const char* lua_pushstring(lua_State*, const char*);
void lua_pushboolean(lua_State*, int);
void lua_pushnil(lua_State*);
void lua_pushcclosure(lua_State*, lua_CFunction, int);
int lua_toboolean(lua_State*, int);
lua_Number lua_tonumberx(lua_State*, int, int*);
const char* lua_tolstring(lua_State*, int, size_t*);
void lua_rawseti(lua_State*, int, lua_Integer);
int lua_rawgeti(lua_State*, int, lua_Integer);
void lua_setglobal(lua_State*, const char*);
int lua_getglobal(lua_State*, const char*);
int lua_pcallk(lua_State*, int, int, int, lua_KContext, lua_KFunction);
void lua_close(lua_State*);
#define lua_pop(L, n) lua_settop(L, -(n)-1)
#define lua_newtable(L) lua_createtable(L, 0, 0)
#define lua_tonumber(L, i) lua_tonumberx(L, (i), NULL)
#define lua_tostring(L, i) lua_tolstring(L, (i), NULL)
#define lua_pcall(L, n, r, f) lua_pcallk(L, (n), (r), (f), 0, NULL)
#define lua_pushcfunction(L, f) lua_pushcclosure(L, (f), 0)
#define lua_register(L, n, f) (lua_pushcfunction(L, (f)), lua_setglobal(L, (n)))
