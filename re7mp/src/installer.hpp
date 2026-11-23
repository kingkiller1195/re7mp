#pragma once
// One install, start to finish (9.45). install_mod() checks the REFramework in the game folder against the version this
// mod is tested with, asks before installing it, then puts the Lua script, the built-in clips and settings and (when the
// pack is at hand) the full character models where they belong. The updater uses the same pieces, so a new
// program always brings its own script. Everything here is portable code behind HttpClient and an `ask` callback, so it
// is tested without Windows; the window only calls it and prints `lines`.
#include <filesystem>
#include <functional>
#include <string>
#include <cstdint>
#include <vector>

#include "updater.hpp"

namespace re7mp {

// What a program (or a downloaded update) carries for the game folder.
struct ModFiles {
    std::string lua;       // -> reframework/autorun/re7mp.lua
    std::string defaults;  // -> reframework/data/re7mp/defaults.json (may be empty)
    std::vector<uint8_t> models_zip;  // (10.13) the full character models, packed in the exe (resource 103); empty = none carried
};

// ---- REFramework ----------------------------------------------------------------------------------

enum class RefwVerdict {
    Correct,       // installed by this program, at the version the mod is tested with
    Missing,       // no dinput8.dll
    OtherVersion,  // installed by this program, at another version
    Unknown,       // a dinput8.dll this program did not install: its version can't be told
};

struct RefwCheck {
    RefwVerdict verdict = RefwVerdict::Missing;
    std::string found;   // the tag we installed, for OtherVersion
    std::string wanted;  // kReframeworkTag
    std::string text;    // one plain-English line for the log
};

RefwCheck check_reframework(const std::filesystem::path& game_dir);

// ---- the full character models (Nexus RE7 mod 86 by AfroJackX) -------------------------------------
// The mod's Permissions page lets others use its assets without permission or credit (not in anything sold or earning
// donation points, and not converted to other games), but not upload the file itself to other sites. So the assets
// ship inside re7mp's own folder (modpack/third-person-full-models/natives/...), with credit to the author anyway, and
// the installer also accepts the author's zip from Downloads. They are never used for RE8 or any other game.
// (10.13) The exe carries the pack itself (ModFiles::models_zip, built by tools/pack_models.py), so a player downloads nothing: the order is the
// embedded pack, then a modpack folder beside the program, then the author's zip in Downloads.

constexpr const char* kModelsName = "Third Person Full Model Placeholders";
constexpr const char* kModelsPage = "https://www.nexusmods.com/residentevil7/mods/86?tab=files";
constexpr const char* kModelsProbe = "natives/stm/coop/character/player/pl2000/pl2001/pl2001.mesh.220128762";

// <dir>/modpack/third-person-full-models for the first dir that has it (with a natives folder inside). Empty if none.
std::filesystem::path find_model_folder(const std::vector<std::filesystem::path>& dirs);

// The newest zip in `dirs` whose name starts with kModelsName and that has a natives folder. Empty path if none.
std::filesystem::path find_model_pack(const std::vector<std::filesystem::path>& dirs);

struct ModelPackResult {
    bool ok = false;
    int written = 0;        // files put in place
    int unchanged = 0;      // files that were already exactly this
    int models_moved = 0;   // meshes and materials placed under natives/stm/coop
    std::string message;
};

// The same placement from a folder that holds a natives folder (the pack shipped with re7mp).
ModelPackResult install_model_folder(const std::filesystem::path& game_dir, const std::filesystem::path& folder);

// Unpacks the zip in memory (every checksum verified) and writes its natives files into the game folder. Meshes and
// materials (.mesh, .mdf2) under natives/stm/character, ch8 and ch9 go under natives/stm/coop, so the player's own
// first-person body is not replaced (the same layout the other developer's installer uses). Textures stay at their own
// paths. Names that could escape the game folder are skipped.
ModelPackResult install_model_pack(const std::filesystem::path& game_dir, const std::vector<uint8_t>& zip);

// REFramework only reads loose files when its Loose File Loader is on (re2_fw_config.txt). Returns false when the file
// could not be written. `note` says what was done.
bool enable_loose_file_loader(const std::filesystem::path& game_dir, std::string& note);

// ---- the one install ------------------------------------------------------------------------------

struct InstallOptions {
    // Asked when REFramework is missing or not the tested version. true = install it now. Left empty, or when
    // prompt_refw is false, nothing is downloaded: the check is only reported.
    std::function<bool(const std::string& title, const std::string& question)> ask;
    bool prompt_refw = true;
    bool refw_dll_only = false;  // re7mp.ini: reframework_files=dll
    bool install_models = true;  // use the pack in the program, a shipped folder, or the author's zip, when found
    std::vector<std::filesystem::path> model_dirs;  // where to look (next to the program, Downloads)
    Progress progress;                              // REFramework download
};

struct InstallReport {
    bool ok = false;                // the script is in place (also when REFramework still has to be installed)
    bool refw_ready = false;        // REFramework at the tested version is there afterwards
    bool refw_installed_now = false;
    bool lua_changed = false;
    std::string lua_before, lua_after;  // build labels ("9.44" -> "9.45")
    bool models_installed = false;
    std::vector<std::string> lines;     // for the log, in order
};

InstallReport install_mod(HttpClient& http, const std::filesystem::path& game_dir, const ModFiles& files,
                          const InstallOptions& opt);

// Writes the script and the defaults, reporting what changed ("build 9.44 -> 9.45"). Returns false only when the script
// could not be written.
bool install_script_files(const std::filesystem::path& game_dir, const ModFiles& files, std::vector<std::string>& lines,
                          bool* changed = nullptr);

// When a script is already installed, brings it (and the defaults) up to date quietly. Nothing is installed for the first time
// and nothing is downloaded. Returns true when something was written. (10.1: the window no longer calls this at start-up or on
// Start: the script is checked only by the Install button and after an update.)
bool refresh_existing_install(const std::filesystem::path& game_dir, const ModFiles& files, std::vector<std::string>& lines);

// ---- updating the program -------------------------------------------------------------------------

struct UpdateApply {
    bool ok = false;
    std::string err;
    std::vector<std::string> lines;
};

// Swaps in the new program and then installs the script that came with it into `game_dir` (skipped when it is empty or
// the package has no script). If the swap fails nothing else is touched, so the script and the program never disagree.
UpdateApply apply_update_package(const std::filesystem::path& current_exe, const UpdatePackage& pkg,
                                 const std::filesystem::path& game_dir);

}  // namespace re7mp
