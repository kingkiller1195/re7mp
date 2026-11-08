#pragma once
// Updates, without the GUI: finding the newest release of this mod on GitHub, fetching and swapping in the new
// re7mp.exe, and installing the REFramework build this mod is known to work with. The network is behind HttpClient
// (WinHTTP in the Windows exe, a fake in the tests), so everything else is ordinary portable code and is tested.
#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace re7mp {

// The mod's releases live here. Release TITLES carry the version ("v0.5"); the tags ("beta5") do not.
constexpr const char* kReleasesApiLatest = "https://api.github.com/repos/kingkiller1195/re7mp/releases/latest";
constexpr const char* kReleasesApiList = "https://api.github.com/repos/kingkiller1195/re7mp/releases?per_page=20";
constexpr const char* kReleasesPage = "https://github.com/kingkiller1195/re7mp/releases";

// The newest REFramework this mod is known to work with. Only change it after trying the new one.
constexpr const char* kReframeworkTag = "v1.5.9.1";
constexpr const char* kReframeworkAsset = "RE7.zip";  // the build for the current version of RE7
constexpr const char* kReframeworkDll = "dinput8.dll";  // the loader itself; the rest of the zip (VR files, the reframework folder) comes with it

using Progress = std::function<void(uint64_t got, uint64_t total)>;

class HttpClient {
public:
    virtual ~HttpClient() = default;
    // GET `url` (following redirects) into `body`. On failure returns false with a plain-English `err`.
    virtual bool get(const std::string& url, std::vector<uint8_t>& body, std::string& err, const Progress& progress) = 0;
};

// ---- versions -------------------------------------------------------------------------------------

// "0.10" > "0.9" (numbers, not text). Missing parts count as 0, so "0.6" == "0.6.0". Returns -1, 0 or 1.
int compare_versions(const std::string& a, const std::string& b);

// The version a release announces: from its title ("v0.5", "Version 0.7 beta") or, failing that, a tag that looks like a
// version ("v0.6", "0.6.1"). A tag like "beta5" is not a version. Returns "" if neither is.
std::string release_version(const std::string& title, const std::string& tag);

// ---- the mod's own releases -----------------------------------------------------------------------

struct ReleaseAsset {
    std::string name;
    std::string url;
    uint64_t size = 0;
};

struct ReleaseInfo {
    std::string tag, title, version, notes, page_url;
    bool prerelease = false;
    std::vector<ReleaseAsset> assets;
};

// Reads the GitHub API answer (one release or a list) and returns the newest by version. Drafts are never offered;
// pre-releases only with include_prerelease. Releases whose version can't be read are skipped.
bool pick_release(const std::string& json, bool include_prerelease, ReleaseInfo& out, std::string& err);

// Only https links to GitHub itself (github.com and its *.githubusercontent.com download hosts) are followed.
bool url_is_github(const std::string& url);

enum class AssetKind { None, Exe, Zip };
AssetKind choose_asset(const ReleaseInfo& r, ReleaseAsset& chosen);

struct UpdateCheck {
    enum class State { UpToDate, Available, Failed } state = State::Failed;
    ReleaseInfo release;  // the newest release found (also when up to date)
    std::string message;
};

UpdateCheck check_for_update(HttpClient& http, const std::string& current_version, bool include_prerelease);

// Downloads the release's re7mp.exe (directly, or out of a zip) and checks it looks like a Windows program.
bool fetch_new_exe(HttpClient& http, const ReleaseInfo& r, std::vector<uint8_t>& exe, std::string& err,
                   const Progress& progress);

// Replaces `current_exe` with `exe`: the running file is renamed to <name>.old (Windows allows renaming a running
// program, not overwriting it) and the new one takes its place. On any failure the old file is put back.
bool swap_in_new_exe(const std::filesystem::path& current_exe, const std::vector<uint8_t>& exe, std::string& err);
void cleanup_old_exe(const std::filesystem::path& current_exe);  // after a restart: removes <name>.old / <name>.new

// ---- REFramework ----------------------------------------------------------------------------------

struct RefwState {
    enum class Kind { Missing, InstalledByUs, InstalledOther } kind = Kind::Missing;
    std::string tag;  // for InstalledByUs
};

std::string reframework_url(const std::string& tag);
RefwState reframework_state(const std::filesystem::path& game_dir);

// Downloads RE7.zip of `tag` and installs EVERYTHING in it into the game folder (the VR files and the reframework
// folder included, which VR support will need), or with dll_only just dinput8.dll. Safety rules:
//  - the whole zip is unpacked and checksum-verified in memory before any file on disk is touched;
//  - dinput8.dll goes in last; an existing one is kept as dinput8.dll.bak (and only replaced when replace_existing is
//    true; otherwise nothing is touched and false is returned);
//  - files already inside the game's reframework folder (your scripts, settings) are never overwritten;
//  - names that could escape the game folder are skipped.
// The folders reframework/autorun and reframework/data are created, so the Lua script has somewhere to go.
bool install_reframework(HttpClient& http, const std::filesystem::path& game_dir, const std::string& tag,
                         bool replace_existing, bool dll_only, std::string& message, const Progress& progress);

}  // namespace re7mp
