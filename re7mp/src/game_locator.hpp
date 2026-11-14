#pragma once
// Finding the RE7 install and putting the Lua script in the right place. Pure
// std::filesystem so it can be tested anywhere; the Windows-only parts (registry,
// running-process lookup) live in the GUI file.
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace re7mp {

constexpr const char* kRe7AppId = "418370";

// Splits Valve KeyValues text (libraryfolders.vdf, appmanifest_*.acf) into its quoted strings.
std::vector<std::string> vdf_tokens(const std::string& text);
std::vector<std::filesystem::path> parse_library_paths(const std::string& libraryfolders_vdf);
std::string parse_install_dir(const std::string& appmanifest_acf);

// Looks through a Steam install and all its library folders for RE7.
std::optional<std::filesystem::path> find_re7_in_steam(const std::filesystem::path& steam_root);

bool looks_like_re7(const std::filesystem::path& dir);   // contains re7.exe
bool refw_installed(const std::filesystem::path& dir);   // contains dinput8.dll
std::filesystem::path data_dir_for(const std::filesystem::path& game_dir);

struct InstallResult {
    bool ok = false;
    bool changed = false;
    std::string message;
};

// Writes <game>/reframework/autorun/re7mp.lua if it is missing or different.
InstallResult install_lua(const std::filesystem::path& game_dir, const std::string& lua_text);

// Writes <game>/reframework/data/re7mp/defaults.json if it is missing or different: the clips and settings a NEW install starts with
// (the script reads it and never writes it; a player's own recordings and settings are other files and always win over it).
InstallResult install_defaults(const std::filesystem::path& game_dir, const std::string& json_text);

}  // namespace re7mp
