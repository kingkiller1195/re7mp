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
    bool alpha = false;  // (10.26) an ALPHA release: its title or tag has the word "alpha" ("v0.11 alpha 3", "v0.11-alpha-3")
    int alpha_no = 0;    // (10.26) its alpha number (3 for "v0.11 alpha 3"); 0 when none can be read: such a release is never offered
    bool prerelease = false;
    std::vector<ReleaseAsset> assets;
};

// (10.26) ALPHA NUMBERS. An alpha release is named "v<release> alpha <n>" ("v0.11 alpha 3"), in the title or the tag ("v0.11-alpha-3"), and is flagged
// pre-release on GitHub. It counts as an IN-BETWEEN version: alpha n of release X sits between the release before X and X itself (it leads UP TO X; since 10.26
// part 2, see kAlphaFollowsItsRelease), so the normal v0.13 is newer than "v0.12 alpha 10", "v0.12 alpha 10" is newer than "v0.12 alpha 9" and older than v0.12
// (see compare_release).
// (Until 10.25 an alpha was named by the dotted build, "alpha 10.24"; none was ever published, so that form is gone. The build is still in the script.)
// has_alpha_word: the word "alpha" is in the text, numbered or not (not inside a longer word: "alphabet", "kalpha" do not count). Such a release is never
// offered to a player on the normal releases, whatever else is wrong with its name.
bool has_alpha_word(const std::string& text);
// The alpha number after the word: "v0.11 alpha 3", "v0.11-alpha-3", "Alpha: build 3", "alpha3", "ALPHA #3", "alpha v3", "alpha b3" all say 3. 0 when the
// word has no WHOLE number after it ("v0.3 alpha", "alpha 10.24" (the old dotted build form), "alpha 0", "alpha 100000") or there is no word.
int alpha_number_in(const std::string& text);
// The same text without the label ("v0.11 alpha 3" -> "v0.11 "), so a release number written beside it can still be read. The whole number goes with
// it, dots and all, so "Alpha 10.24 (v0.11)" is release 0.11, not release 10.24.
std::string without_alpha_label(const std::string& text);

// The ORDER. Releases are compared by release number first; for the same number the alphas come BEFORE the normal release (v0.12 alpha 10 is older than
// v0.12, newer than v0.12 alpha 9 and than v0.11) while kAlphaFollowsItsRelease is false. That is the setting since 10.26 part 2 (the owner said v0.11 is not
// public yet): a tester on "v0.11 alpha 5" is offered the normal v0.11 when it comes out. true turns it round (the alphas FOLLOW their release: alpha 1 of
// v0.12 is newer than v0.12, and a tester on it is NOT offered v0.12 itself). One switch, nothing else changes. alpha 0 means a normal release.
constexpr bool kAlphaFollowsItsRelease = false;
int compare_release(const std::string& version_a, int alpha_a, const std::string& version_b, int alpha_b);
// "v0.11" or "v0.11 alpha 3": what a release is called in the windows and the log (an alpha with no readable number: "v0.11 alpha (no number)").
std::string release_name(const std::string& version, int alpha);

// Reads the GitHub API answer (one release or a list) into every release that is not a draft, in the order GitHub gave them.
// `version` is "" when no release number can be read; `alpha` / `alpha_no` are set for alpha releases (the alpha release's release number is read from
// what is left of its title and tag once the label is out of them).
// False with a plain-English err when the answer is not a release list (e.g. {"message":"Not Found"}).
bool parse_release_list(const std::string& json, std::vector<ReleaseInfo>& out, std::string& err);

// Reads the GitHub API answer (one release or a list) and returns the newest by version. Drafts are never offered;
// pre-releases only with include_prerelease. Releases whose version can't be read are skipped. (10.24) An ALPHA release
// (see has_alpha_word) is never offered here, whatever its version or its pre-release flag: it belongs to the alpha channel.
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

// ---- the script that goes with an exe (9.45) -------------------------------------------------------------

// The labels a script carries: `BUILD = "9.45"` (the internal build) and `RELEASE = "0.9"` (the public release). "" if absent.
// (10.26) `ALPHA = "3"`: which alpha of its release this is (0 = a normal release). script_alpha is 0 when the label is absent or is not a whole number.
std::string script_build(const std::string& lua);
std::string script_release(const std::string& lua);
int script_alpha(const std::string& lua);

// Everything a release carries for the game folder: the program, and (when the release has them) the Lua script and the
// built-in clips and settings that were built together with it.
struct UpdatePackage {
    std::vector<uint8_t> exe;
    std::string lua;       // reframework/autorun/re7mp.lua, "" when the release has none (or it is not this release's)
    std::string defaults;  // reframework/data/re7mp/defaults.json
    std::string note;      // why `lua` is empty, when the release should have had one
};

// Like fetch_new_exe, and also takes the script and defaults from the same release: `lua/re7mp.lua` and
// `data/re7mp/defaults.json` inside the release zip, or release files named re7mp.lua and defaults.json. A script whose
// RELEASE label is not the release's version is not used (the program is still fetched; `note` says why). (10.26) For an ALPHA release
// (r.alpha) the script's ALPHA label has to be the release's alpha number too (the RELEASE label is the alpha's release number, as for any release).
bool fetch_update_package(HttpClient& http, const ReleaseInfo& r, UpdatePackage& pkg, std::string& err,
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
