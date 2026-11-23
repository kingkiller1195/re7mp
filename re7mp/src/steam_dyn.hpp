// (10.10) STEAM on Windows: the ISteamApi (steam_api.hpp) implemented with LoadLibrary on a steam_api64.dll and Valve's "flat" C interface.
// Only the Windows exe uses this; the tests use a mock and the Linux command-line build has no Steam.
// (10.13) One Steam connection for the whole exe, started once and kept (the friends menu and the link used to start and shut Steam down in turn), and
// the app id it runs as is a parameter: 480 (Spacewar, the id every Steam program without its own uses) by default. As 418370 the exe and the game were
// the same "program" to Steam on the same account, and a request from the other player could be handed to the game, which ignores it.
#pragma once
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#include "steam_api.hpp"

namespace re7mp {

constexpr int kSteamAppIdDefault = 480;      // Spacewar: free for every Steam account
constexpr int kSteamAppIdRe7 = 418370;       // Resident Evil 7 (what a friend who is playing it shows as)

// `dirs` are the folders to look for steam_api64.dll in, best first (the RE7 folder, then Steam's own folder). Nothing is loaded until init().
std::unique_ptr<ISteamApi> make_steam_api_dynamic(const std::vector<std::filesystem::path>& dirs, int app_id = kSteamAppIdDefault);

// The friends list for the window's "Pick a Steam friend" menu. Uses the exe's one Steam connection (started here if it is not yet). Empty (with `err`)
// when Steam cannot be reached. (Used only when no transport is running; while one is, its own interface is asked.)
std::vector<SteamFriendInfo> steam_friends_once(const std::vector<std::filesystem::path>& dirs, std::string& err, int app_id = kSteamAppIdDefault);

}  // namespace re7mp
