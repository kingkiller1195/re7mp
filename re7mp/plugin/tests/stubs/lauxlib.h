/* TEST-ONLY, see lua.h */
#pragma once
#include "lua.h"
typedef struct luaL_Reg { const char* name; lua_CFunction func; } luaL_Reg;
lua_Integer luaL_checkinteger(lua_State*, int);
lua_Integer luaL_optinteger(lua_State*, int, lua_Integer);
const char* luaL_checklstring(lua_State*, int, size_t*);
const char* luaL_optlstring(lua_State*, int, const char*, size_t*);
void luaL_checktype(lua_State*, int, int);
int luaL_error(lua_State*, const char*, ...);
void luaL_setfuncs(lua_State*, const luaL_Reg*, int);
lua_State* luaL_newstate(void);
void luaL_openlibs(lua_State*);
int luaL_loadfilex(lua_State*, const char*, const char*);
#define luaL_checkstring(L, n) luaL_checklstring(L, (n), NULL)
#define luaL_optstring(L, n, d) luaL_optlstring(L, (n), (d), NULL)
#define luaL_loadfile(L, f) luaL_loadfilex(L, (f), NULL)
