#pragma once
// (10.24) THE ALPHA CHANNEL, without the window: everything re7mp.exe's "Join the alpha..." button decides or says that does not need Windows, so
// it is all tested (tests/core_tests.cpp, test_alpha_channel). The window code (gui_win.cpp) only asks, shows and starts threads.
//
//   * Where the alpha lives: kAlphaRepo below, "owner/name" of a GitHub repository. (10.25) It is LINKED to the main repository, the same one the normal
//     releases are in: an alpha is a release there, flagged "pre-release", and a normal release is a release that is not (GitHub's own "latest" skips
//     pre-releases, and the normal updater skips anything labelled alpha even when the flag was forgotten). re7mp.ini can override the link with
//     alpha_repo=owner/name, which is also how another source is tried without rebuilding the exe. With nothing linked (a build made with
//     -DRE7MP_ALPHA_REPO='""') the button still opens the warning window, as a preview that installs nothing.
//   * What an alpha release looks like (10.26): an ordinary GitHub release flagged PRE-RELEASE whose TITLE or TAG says "v<release> alpha <n>"
//     ("v0.11 alpha 3", "v0.11-alpha-3"). It is an IN-BETWEEN version: alpha n of release X sits between the release before X and X itself (older than the
//     normal X, newer than the earlier alphas of it), so the normal v0.13 and the normal v0.12 are both newer than "v0.12 alpha 10" (updater.hpp, compare_release;
//     kAlphaFollowsItsRelease turns the order round). The script
//     inside the release says the same: RELEASE = "0.11" and ALPHA = "3" (updater.cpp refuses a script that does not). The release carries the same
//     files as a normal one (re7mp.exe, or a zip with it, lua/re7mp.lua and data/re7mp/defaults.json). The release notes are "what's changed" in the window.
//   * A player on the alpha channel is offered the newest of ALL the releases, alpha or normal: an alpha tester on "v0.12 alpha 10" is offered the normal
//     v0.13 when it comes out, and "v0.12 alpha 11" before that (check_alpha).
//   * The normal updater never offers an alpha release (updater.cpp, pick_release), whatever its pre-release flag, so the alpha can live in the
//     same repository as the normal releases.
//   * Which channel the exe is on is written for the script to re7mp_channel.json (the same way as the other boxes) so that the script's panel
//     and debug file say it: a report from a tester then says which build and which channel it came from.
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "json_mini.hpp"
#include "updater.hpp"

namespace re7mp {

// (10.25) THE LINK: "owner/name" of the repository the alpha builds are published in = the one the normal releases are in (updater.hpp). EMPTY would mean not
// linked. To point somewhere else change the line below (or build with -DRE7MP_ALPHA_REPO='"owner/name"') and rebuild.
#ifndef RE7MP_ALPHA_REPO
#define RE7MP_ALPHA_REPO "kingkiller1195/re7mp"
#endif
// The link lives in the program as this ONE text and kAlphaRepo is read out of it, so the program cannot carry the link without carrying the text.
// tools/pack_alpha.py looks for "re7mp-alpha-link=<owner/name>" in a re7mp.exe before it packs an alpha. (The repository's name alone would prove nothing:
// the normal updater's own web addresses contain it, so an exe built before the link was set has it too.)
constexpr char kAlphaLinkMark[] = "re7mp-alpha-link=" RE7MP_ALPHA_REPO;
constexpr size_t kAlphaLinkPrefixLen = sizeof("re7mp-alpha-link=") - 1;
constexpr const char* kAlphaRepo = kAlphaLinkMark + kAlphaLinkPrefixLen;

// The repository this build links the alpha to ("" = none). It reads the text through a volatile pointer, which stops the compiler from folding the
// repository's name into the code and dropping the text: whatever the optimizer does, a program that asks for the link has the whole text in it.
inline std::string alpha_default_repo() {
    static const char* volatile keep = kAlphaLinkMark;
    return std::string(keep + kAlphaLinkPrefixLen);
}

enum class Channel { Stable, Alpha };
inline const char* channel_word(Channel c) { return c == Channel::Alpha ? "alpha" : "stable"; }

// ---- the source ------------------------------------------------------------------------------------

namespace alpha_detail {
inline bool part_ok(const std::string& s, size_t max_len, bool dots_and_underscores) {
    if (s.empty() || s.size() > max_len) return false;
    for (const char ch : s) {
        const unsigned char c = static_cast<unsigned char>(ch);
        if (!(std::isalnum(c) || c == '-' || (dots_and_underscores && (c == '_' || c == '.')))) return false;
    }
    return true;
}
}  // namespace alpha_detail

// "owner/name" the way GitHub writes it: the owner letters, digits and hyphens (39 at most), the name also dots and underscores (100 at most).
// Nothing else gets into an address that is asked for.
inline bool valid_repo_name(const std::string& repo) {
    const size_t slash = repo.find('/');
    if (slash == std::string::npos || repo.find('/', slash + 1) != std::string::npos) return false;
    const std::string owner = repo.substr(0, slash), name = repo.substr(slash + 1);
    if (!alpha_detail::part_ok(owner, 39, false) || !alpha_detail::part_ok(name, 100, true)) return false;
    return name != "." && name != ".." && name.find("..") == std::string::npos && owner[0] != '-';
}

inline std::string alpha_api_url(const std::string& repo) { return "https://api.github.com/repos/" + repo + "/releases?per_page=20"; }
inline std::string alpha_releases_page(const std::string& repo) { return "https://github.com/" + repo + "/releases"; }

// ---- what a release is called ---------------------------------------------------------------------

// "v0.11 alpha 3" or "v0.11" for an ordinary release (updater.hpp, release_name). An alpha whose number cannot be read: "v0.11 alpha (no number)".
inline std::string release_label(const ReleaseInfo& r) {
    if (r.alpha && r.alpha_no <= 0) return (r.version.empty() ? std::string() : "v" + r.version + " ") + "alpha (no number)";
    return release_name(r.version, r.alpha ? r.alpha_no : 0);
}

// ---- looking for the newest alpha ------------------------------------------------------------------

// The newest build for a player on the alpha channel: of ALL the releases of `repo` that can be put in order (normal releases that are not flagged
// pre-release, and alpha releases that say a release number and an alpha number), the one that is newest by compare_release, and whether it is newer than
// this exe (`current_version` = its release number, `current_alpha` = its alpha number, 0 for a normal release). Nothing is downloaded. Failed has a
// plain-English message: a bad source name, no network, GitHub's complaint, or no release at all.
inline UpdateCheck check_alpha(HttpClient& http, const std::string& repo, const std::string& current_version, int current_alpha) {
    UpdateCheck r;
    if (!valid_repo_name(repo)) {
        r.message = "The alpha source \"" + repo + "\" is not a GitHub repository name (it should look like owner/name).";
        return r;
    }
    std::vector<uint8_t> body;
    std::string err;
    if (!http.get(alpha_api_url(repo), body, err, nullptr)) {
        r.message = "Could not look for alpha builds: " + err;
        return r;
    }
    std::vector<ReleaseInfo> all;
    if (!parse_release_list(std::string(body.begin(), body.end()), all, err)) {
        r.message = "Could not look for alpha builds: " + err;
        return r;
    }
    const ReleaseInfo* best = nullptr;
    size_t usable_alphas = 0, unnamed = 0;
    for (const auto& x : all) {
        if (x.alpha) {
            if (x.alpha_no <= 0 || x.version.empty()) {  // "alpha 10.24", "Alpha 3" with no release number: it cannot be put in order
                ++unnamed;
                continue;
            }
            ++usable_alphas;
        } else if (x.prerelease || x.version.empty()) {
            continue;  // a normal release is only counted when it is a real release (not a pre-release that is not an alpha) with a number
        }
        if (!best || compare_release(x.version, x.alpha ? x.alpha_no : 0, best->version, best->alpha ? best->alpha_no : 0) > 0) best = &x;
    }
    const std::string skipped = unnamed == 0 ? std::string()
                                             : " (" + std::to_string(unnamed) + (unnamed == 1 ? " alpha release was skipped" : " alpha releases were skipped") +
                                                   ": its name has no release number and alpha number, like \"v0.11 alpha 3\")";
    if (!best || usable_alphas == 0) {  // no alpha at all: the channel has nothing of its own to say (a normal release alone is not "an alpha build")
        r.message = "No alpha build is published at github.com/" + repo + " yet (" + std::to_string(all.size()) +
                    " releases looked at; an alpha release is named like \"v0.11 alpha 3\")." + skipped;
        return r;
    }
    r.release = *best;
    const std::string mine = release_name(current_version, current_alpha);
    const std::string theirs = release_label(*best);
    if (compare_release(best->version, best->alpha ? best->alpha_no : 0, current_version, current_alpha) > 0) {
        r.state = UpdateCheck::State::Available;
        r.message = theirs + " is available (you have " + mine + ")." + skipped;
    } else {
        r.state = UpdateCheck::State::UpToDate;
        r.message = "You have the newest build (" + mine + ")." + skipped;
    }
    return r;
}

// Leaving the alpha for the normal release: the newest normal release is offered whatever its number, because the build that is running is an
// alpha, and with kAlphaFollowsItsRelease set to true it would be NEWER than the normal release of its own number. Leaving is a choice
// the player made, so it is not held back by that. (check_for_update with a current version of "0" does exactly that.)
inline UpdateCheck check_back_to_stable(HttpClient& http, bool include_prerelease) {
    UpdateCheck r = check_for_update(http, "0", include_prerelease);
    if (r.state == UpdateCheck::State::Available) r.message = "The newest normal release is " + r.release.version + ".";
    return r;
}

// ---- what the windows say --------------------------------------------------------------------------

// The first `max_len` bytes of release notes: no carriage returns, cut at the end of a line when one is near, never inside a UTF-8 character.
inline std::string shorten_notes(const std::string& notes, size_t max_len) {
    std::string n;
    for (const char c : notes) {
        if (c != '\r') n += c;
    }
    size_t a = 0;
    while (a < n.size() && std::isspace(static_cast<unsigned char>(n[a]))) ++a;
    n.erase(0, a);
    while (!n.empty() && std::isspace(static_cast<unsigned char>(n.back()))) n.pop_back();
    if (n.size() <= max_len) return n;
    size_t cut = max_len;
    while (cut > 0 && (static_cast<unsigned char>(n[cut]) & 0xC0) == 0x80) --cut;
    const size_t nl = n.rfind('\n', cut);
    if (nl != std::string::npos && nl > max_len * 3 / 4) cut = nl;
    std::string out = n.substr(0, cut);
    while (!out.empty() && std::isspace(static_cast<unsigned char>(out.back()))) out.pop_back();
    return out + "\n...(the rest is on the releases page)";
}

// The warning, the same in the real window and in the preview.
inline std::string alpha_warning_points() {
    return "WARNING: expect things to be EVEN MORE BROKEN, or FIXED, compared with the normal release.\n"
           " - Something that works in the normal release can break here: crashes, games that drift apart, features that do nothing."
           " Something that is broken in the normal release can also be fixed here long before the normal release has the fix.\n"
           " - Back up your RE7 save files first.\n"
           " - You and the person you play with need the SAME alpha (the same \"alpha <number>\" of the same release), or your games will not line up.\n"
           " - When something goes wrong, press \"Open data folder\" and send debug.json with what you were doing (from both players if you can)."
           " It records which build you were on.\n"
           " - You can leave at any time: this button turns into \"Leave the alpha...\".";
}

// The window that asks whether to join (the newest build is known: an alpha, or a normal release when no alpha is newer than it). Yes = join, and
// download it when it is newer than this exe (`current_version` / `current_alpha`, as for check_alpha).
inline std::string alpha_join_text(const std::string& repo, const ReleaseInfo& newest, const std::string& current_version, int current_alpha) {
    std::string t = "JOIN THE ALPHA?\n\n"
                    "The alpha is the public test branch: new work lands here first, as it is written, so people can try it before it becomes a normal release.\n\n";
    t += "WHAT'S CHANGED  (" + release_label(newest) + "):\n";
    const std::string notes = shorten_notes(newest.notes, 700);
    t += notes.empty() ? std::string("(this alpha release has no notes)") : notes;
    t += "\n\n" + alpha_warning_points() + "\n\nSource: github.com/" + repo + "\n";
    if (!newest.alpha) t += "(No alpha is newer than the normal release " + release_label(newest) + " yet.)\n";
    const std::string mine = release_name(current_version, current_alpha);
    if (compare_release(newest.version, newest.alpha ? newest.alpha_no : 0, current_version, current_alpha) > 0) {
        t += "Join the alpha and download " + release_label(newest) + " now? (you have " + mine + ")";
    } else {
        t += "Join the alpha? (you already have the newest build, " + mine + ")";
    }
    return t;
}

// The window of a build that has no alpha linked yet: the same warning, as a preview. Nothing is installed.
inline std::string alpha_preview_text() {
    return "THE ALPHA IS NOT OPEN YET\n\n"
           "This button joins the alpha: the public test branch, where new work lands first, as it is written, so people can try it before it becomes a normal release.\n\n"
           "When it is open, a window like this one shows what has changed in the newest alpha (named like \"v0.12 alpha 3\") and asks you to confirm. It warns you:\n\n" +
           alpha_warning_points() + "\n\nNothing is installed and nothing changes now.";
}

inline std::string alpha_leave_text() {
    return "LEAVE THE ALPHA?\n\n"
           " - Yes: go back to the normal release now. The newest normal release is downloaded and put in place of this alpha, and re7mp restarts (your settings are kept).\n"
           " - No: stay on this alpha, but stop looking for alpha builds. The next normal release will replace it.\n"
           " - Cancel: stay in the alpha.";
}

// ---- telling the script (re7mp_channel.json) -------------------------------------------------------
// {"channel":"alpha","exe_build":"10.24","seq":1731310000123}  in the game's reframework/data folder, written the way the other boxes are written
// (enemy_sync.hpp). The script only reads it and says it; it changes nothing in the game. The file is kept when the exe closes: it is the player's
// standing choice. Nothing is written when it already says the same, so the number only moves when something changed.

inline std::filesystem::path channel_file(const std::filesystem::path& data_dir) { return data_dir / "re7mp_channel.json"; }

// A build label as the file carries it: letters, digits, dots and hyphens, at most 24.
inline std::string clean_build_label(const std::string& b) {
    std::string out;
    for (const char c : b) {
        if (std::isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '-') out += c;
        if (out.size() >= 24) break;
    }
    return out;
}

inline bool write_channel(const std::filesystem::path& data_dir, Channel ch, const std::string& exe_build, uint64_t seq) {
    std::error_code ec;
    std::filesystem::create_directories(data_dir, ec);
    const auto tmp = data_dir / "re7mp_channel.tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        char buf[160];
        std::snprintf(buf, sizeof(buf), "{\"channel\":\"%s\",\"exe_build\":\"%s\",\"seq\":%llu}\n", channel_word(ch),
                      clean_build_label(exe_build).c_str(), static_cast<unsigned long long>(seq));
        f << buf;
        if (!f) return false;
    }
    std::filesystem::rename(tmp, channel_file(data_dir), ec);
    return !ec;
}

inline bool read_channel(const std::filesystem::path& data_dir, Channel& ch, std::string& exe_build, uint64_t& seq) {
    std::ifstream f(channel_file(data_dir), std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    mini::Value v;
    if (!mini::parse(ss.str(), v) || v.type != mini::Value::Type::Obj) return false;
    const auto* c = v.get("channel");
    if (!c || c->type != mini::Value::Type::Str || (c->str != "alpha" && c->str != "stable")) return false;
    ch = c->str == "alpha" ? Channel::Alpha : Channel::Stable;
    const auto* b = v.get("exe_build");
    exe_build = (b && b->type == mini::Value::Type::Str) ? b->str : std::string();
    const auto* s = v.get("seq");
    seq = (s && s->type == mini::Value::Type::Num && s->num >= 0) ? static_cast<uint64_t>(s->num) : 0;
    return true;
}

// Makes the file say this. True: it does now. *wrote: whether anything was written (false when it already said the same).
inline bool sync_channel(const std::filesystem::path& data_dir, Channel ch, const std::string& exe_build, bool* wrote = nullptr) {
    if (wrote) *wrote = false;
    Channel have = Channel::Stable;
    std::string have_build;
    uint64_t old_seq = 0;
    const bool had = read_channel(data_dir, have, have_build, old_seq);
    if (had && have == ch && have_build == clean_build_label(exe_build)) return true;
    uint64_t seq = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
    if (had && seq <= old_seq) seq = old_seq + 1;
    if (!write_channel(data_dir, ch, exe_build, seq)) return false;
    if (wrote) *wrote = true;
    return true;
}

}  // namespace re7mp
