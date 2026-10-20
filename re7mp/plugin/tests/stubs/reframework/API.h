/* TEST-ONLY stand-in for REFramework's include/reframework/API.h (only what plugin.cpp touches). */
#pragma once
#define REFRAMEWORK_PLUGIN_VERSION_MAJOR 1
#define REFRAMEWORK_PLUGIN_VERSION_MINOR 15
#define REFRAMEWORK_PLUGIN_VERSION_PATCH 0
typedef struct lua_State lua_State;
typedef struct { int major, minor, patch; const char* game_name; } REFrameworkPluginVersion;
typedef void (*REFLuaStateCreatedCb)(lua_State*);
typedef void (*REFLuaStateDestroyedCb)(lua_State*);
typedef struct {
    bool (*on_lua_state_created)(REFLuaStateCreatedCb);
    bool (*on_lua_state_destroyed)(REFLuaStateDestroyedCb);
    void (*log_info)(const char*, ...);
} REFrameworkPluginFunctions;
typedef struct {
    void* reframework_module;
    const REFrameworkPluginVersion* version;
    const REFrameworkPluginFunctions* functions;
} REFrameworkPluginInitializeParam;
