#include "installer.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iterator>
#include <sstream>

#include "game_locator.hpp"
#include "packet.hpp"  // crc32
#include "zip_extract.hpp"

namespace fs = std::filesystem;

namespace re7mp {

namespace {

std::string lower_s(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

bool read_bytes(const fs::path& p, std::vector<uint8_t>& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

std::string text_of(const std::vector<uint8_t>& b) { return std::string(b.begin(), b.end()); }

// Writes next to the destination first and renames, so a failure never leaves half a file.
bool write_file_atomic(const fs::path& dest, const std::vector<uint8_t>& data) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    fs::path tmp = dest;
    tmp += ".re7mp-new";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
        f.close();
        if (!f) {
            fs::remove(tmp, ec);
            return false;
        }
    }
    fs::rename(tmp, dest, ec);
    if (ec) {
        std::error_code ec2;
        fs::remove(tmp, ec2);
        return false;
    }
    return true;
}

fs::path script_path(const fs::path& game_dir) { return game_dir / "reframework" / "autorun" / "re7mp.lua"; }

std::string build_note(const std::string& label) { return label.empty() ? std::string() : " (build " + label + ")"; }

}  // namespace

// ------------------------------------------------------------------ REFramework

RefwCheck check_reframework(const fs::path& game_dir) {
    RefwCheck c;
    c.wanted = kReframeworkTag;
    const RefwState st = reframework_state(game_dir);
    switch (st.kind) {
        case RefwState::Kind::Missing:
            c.verdict = RefwVerdict::Missing;
            c.text = "REFramework is not installed in this folder (the mod needs it).";
            break;
        case RefwState::Kind::InstalledByUs:
            c.found = st.tag;
            if (st.tag == c.wanted) {
                c.verdict = RefwVerdict::Correct;
                c.text = "REFramework " + st.tag + " is installed: the version this mod is tested with.";
            } else {
                c.verdict = RefwVerdict::OtherVersion;
                c.text = "REFramework " + st.tag + " is installed, but this mod is tested with " + c.wanted + ".";
            }
            break;
        case RefwState::Kind::InstalledOther:
            c.verdict = RefwVerdict::Unknown;
            c.text = "A dinput8.dll is in this folder that this program did not install (another REFramework version, or a different "
                     "mod loader), so its version can't be checked. The mod is tested with REFramework " + c.wanted + ".";
            break;
    }
    return c;
}

// ------------------------------------------------------------------ the full character models

namespace {

bool is_model_file(const std::string& name) {  // "pl2001.mesh.220128762" / "pl2001.mdf2.21"
    const size_t d1 = name.rfind('.');
    if (d1 == std::string::npos || d1 + 1 >= name.size()) return false;
    for (size_t i = d1 + 1; i < name.size(); ++i) {
        if (!std::isdigit(static_cast<unsigned char>(name[i]))) return false;
    }
    if (d1 == 0) return false;
    const size_t d2 = name.rfind('.', d1 - 1);
    if (d2 == std::string::npos) return false;
    const std::string kind = lower_s(name.substr(d2 + 1, d1 - d2 - 1));
    return kind == "mesh" || kind == "mdf2";
}

// "x/y/natives/stm/character/..." -> "natives/stm/character/..." ("" when there is no natives folder in the name).
std::string from_natives(const std::string& rel) {
    const std::string l = lower_s(rel);
    size_t pos = 0;
    while (true) {
        const size_t i = l.find("natives/", pos);
        if (i == std::string::npos) return {};
        if (i == 0 || l[i - 1] == '/') return rel.substr(i);
        pos = i + 1;
    }
}

std::vector<std::string> split_path(const std::string& s) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == '/') {
            out.push_back(cur);
            cur.clear();
        } else {
            cur += c;
        }
    }
    out.push_back(cur);
    return out;
}

bool zip_has_natives(const std::vector<uint8_t>& zip) {
    std::vector<ZipEntry> es;
    std::string err;
    if (!zip_list(zip, es, err)) return false;
    for (const auto& e : es) {
        if (!e.is_dir && !from_natives(zip_safe_name(e.name)).empty()) return true;
    }
    return false;
}

constexpr uint64_t kMaxModelFile = 128ull * 1024 * 1024;
constexpr uint64_t kMaxModelTotal = 1024ull * 1024 * 1024;

}  // namespace

fs::path find_model_pack(const std::vector<fs::path>& dirs) {
    struct Cand {
        fs::path path;
        fs::file_time_type when;
    };
    std::vector<Cand> cands;
    const std::string want = lower_s(kModelsName);
    for (const auto& d : dirs) {
        std::error_code ec;
        if (d.empty() || !fs::is_directory(d, ec)) continue;
        for (fs::directory_iterator it(d, ec), end; !ec && it != end; it.increment(ec)) {
            std::error_code e2;
            if (!it->is_regular_file(e2)) continue;
            const std::string name = lower_s(it->path().filename().u8string());
            if (name.compare(0, want.size(), want) != 0 || name.size() < 4 || name.compare(name.size() - 4, 4, ".zip") != 0) continue;
            Cand c;
            c.path = it->path();
            c.when = fs::last_write_time(it->path(), e2);
            cands.push_back(std::move(c));
        }
    }
    std::sort(cands.begin(), cands.end(), [](const Cand& a, const Cand& b) { return a.when > b.when; });
    for (const auto& c : cands) {  // newest first; a browser's half-written download does not open
        std::vector<uint8_t> zip;
        if (read_bytes(c.path, zip) && zip_has_natives(zip)) return c.path;
    }
    return {};
}

namespace {

struct PackFile {
    std::string rel;  // "natives/stm/character/..." (forward slashes)
    std::vector<uint8_t> data;
};

// Puts the files where they belong: meshes and materials under natives/stm/{character,ch8,ch9} go to natives/stm/coop/...
// so the player's own first-person body is not replaced; everything else (the textures) keeps its path. Files that are
// already exactly this are left alone.
ModelPackResult place_pack_files(const fs::path& game_dir, const std::vector<PackFile>& files) {
    ModelPackResult r;
    if (files.empty()) {
        r.message = "That pack has no natives folder, so nothing was installed from it.";
        return r;
    }
    for (const auto& f : files) {
        std::vector<std::string> parts = split_path(f.rel);
        bool model = false;
        const bool model_folder = parts.size() >= 4 && lower_s(parts[1]) == "stm" &&
                                  (lower_s(parts[2]) == "character" || lower_s(parts[2]) == "ch8" || lower_s(parts[2]) == "ch9");
        if (model_folder && is_model_file(parts.back())) {
            parts.insert(parts.begin() + 2, "coop");  // natives/stm/coop/character/...
            model = true;
        }
        std::string rel;
        for (size_t i = 0; i < parts.size(); ++i) rel += (i ? "/" : "") + parts[i];
        const fs::path dest = game_dir / fs::path(rel);
        std::vector<uint8_t> cur;
        if (read_bytes(dest, cur) && cur.size() == f.data.size() && crc32(cur.data(), cur.size()) == crc32(f.data.data(), f.data.size())) {
            ++r.unchanged;
            if (model) ++r.models_moved;
            continue;
        }
        if (!write_file_atomic(dest, f.data)) {
            r.message = "Could not write " + dest.u8string() + ". Is RE7 still running?";
            return r;
        }
        ++r.written;
        if (model) ++r.models_moved;
    }
    r.ok = true;
    std::ostringstream m;
    m << "Full character models: " << r.written << " file" << (r.written == 1 ? "" : "s") << " written, " << r.unchanged << " already in place; "
      << r.models_moved << " model files are under natives\\stm\\coop (your own first-person view stays normal).";
    r.message = m.str();
    return r;
}

}  // namespace

fs::path find_model_folder(const std::vector<fs::path>& dirs) {
    for (const auto& d : dirs) {
        std::error_code ec;
        const fs::path f = d / "modpack" / "third-person-full-models";
        if (!d.empty() && fs::is_directory(f / "natives", ec)) return f;
    }
    return {};
}

ModelPackResult install_model_folder(const fs::path& game_dir, const fs::path& folder) {
    ModelPackResult r;
    std::vector<PackFile> files;
    uint64_t total = 0;
    std::error_code ec;
    const fs::path natives = folder / "natives";
    if (!fs::is_directory(natives, ec)) {
        r.message = "The models folder has no natives folder: " + folder.u8string();
        return r;
    }
    for (fs::recursive_directory_iterator it(natives, ec), end; !ec && it != end; it.increment(ec)) {
        std::error_code e2;
        if (!it->is_regular_file(e2)) continue;
        PackFile f;
        f.rel = "natives/" + fs::relative(it->path(), natives, e2).generic_u8string();
        if (e2 || zip_safe_name(f.rel).empty()) continue;  // never anything that could leave the game folder
        const uint64_t size = fs::file_size(it->path(), e2);
        total += size;
        if (e2 || size > kMaxModelFile || total > kMaxModelTotal) {
            r.message = "The models folder is bigger than expected, so it was not installed.";
            return r;
        }
        if (!read_bytes(it->path(), f.data)) {
            r.message = "Could not read " + it->path().u8string() + ".";
            return r;
        }
        files.push_back(std::move(f));
    }
    return place_pack_files(game_dir, files);
}

ModelPackResult install_model_pack(const fs::path& game_dir, const std::vector<uint8_t>& zip) {
    ModelPackResult r;
    std::vector<ZipEntry> entries;
    std::string err;
    if (!zip_list(zip, entries, err)) {
        r.message = "The models download is not a usable zip: " + err;
        return r;
    }
    std::vector<PackFile> files;
    uint64_t total = 0;
    for (const auto& z : entries) {
        if (z.is_dir) continue;
        const std::string sub = from_natives(zip_safe_name(z.name));
        if (sub.empty()) continue;  // modinfo.ini, the screenshot
        PackFile f;
        f.rel = sub;
        total += z.size;
        if (total > kMaxModelTotal) {
            r.message = "The models download is far bigger than expected, so it was not installed.";
            return r;
        }
        if (!zip_read(zip, z, f.data, kMaxModelFile, err)) {
            r.message = "The models download is damaged: " + err;
            return r;
        }
        files.push_back(std::move(f));
    }
    return place_pack_files(game_dir, files);
}

bool enable_loose_file_loader(const fs::path& game_dir, std::string& note) {
    const fs::path cfg = game_dir / "re2_fw_config.txt";
    std::vector<uint8_t> cur;
    const bool existed = read_bytes(cfg, cur);
    std::string text = text_of(cur);
    const std::string key = "LooseFileLoader_Enabled=";
    std::string out;
    bool found = false, changed = false;
    size_t pos = 0;
    while (pos < text.size()) {
        size_t nl = text.find('\n', pos);
        const size_t end = nl == std::string::npos ? text.size() : nl;
        std::string line = text.substr(pos, end - pos);
        std::string body = line, tail;
        if (!body.empty() && body.back() == '\r') {
            body.pop_back();
            tail = "\r";
        }
        if (body.compare(0, key.size(), key) == 0) {
            found = true;
            if (body != key + "true") {
                body = key + "true";
                changed = true;
            }
        }
        out += body + tail + (nl == std::string::npos ? "" : "\n");
        pos = nl == std::string::npos ? text.size() : nl + 1;
    }
    if (!found) {
        const std::string nl = text.find("\r\n") != std::string::npos ? "\r\n" : "\n";
        if (!out.empty() && out.back() != '\n') out += nl;
        out += key + "true" + nl;
        changed = true;
    }
    if (!changed) {
        note = "REFramework's Loose File Loader is already on.";
        return true;
    }
    if (!write_file_atomic(cfg, std::vector<uint8_t>(out.begin(), out.end()))) {
        note = "Could not write " + cfg.u8string() + " to switch on REFramework's Loose File Loader.";
        return false;
    }
    note = existed ? "Switched on REFramework's Loose File Loader." : "Created re2_fw_config.txt with REFramework's Loose File Loader on.";
    return true;
}

// 10.1: the script has no way to look into natives\\stm, so the program leaves it a note in reframework\\data\\re7mp\\modpack.json: the
// full character models are in place under natives\\stm\\coop, so the other player's body can be made from them.
static bool write_models_flag(const fs::path& game_dir) {
    const std::string text = std::string("{\"models\": \"coop\", \"pack\": \"") + kModelsName + "\", \"author\": \"AfroJackX\", \"page\": \"" +
                             kModelsPage + "\"}\n";
    return write_file_atomic(game_dir / "reframework" / "data" / "re7mp" / "modpack.json", std::vector<uint8_t>(text.begin(), text.end()));
}

// ------------------------------------------------------------------ the script and its data

bool install_script_files(const fs::path& game_dir, const ModFiles& files, std::vector<std::string>& lines, bool* changed) {
    if (changed) *changed = false;
    std::vector<uint8_t> old;
    const std::string before = read_bytes(script_path(game_dir), old) ? script_build(text_of(old)) : std::string();
    const std::string after = script_build(files.lua);
    const InstallResult r = install_lua(game_dir, files.lua);
    if (!r.ok) {
        lines.push_back("Could not install the Lua script: " + r.message);
        return false;
    }
    if (changed) *changed = r.changed;
    if (!r.changed) {
        lines.push_back("The Lua script is up to date" + build_note(after) + ".");
    } else if (before.empty() || before == after) {
        lines.push_back(r.message + build_note(after) + ".");
    } else {
        lines.push_back("The Lua script was updated: build " + before + " -> " + (after.empty() ? "the new one" : after) + " (" +
                        script_path(game_dir).u8string() + ").");
    }
    if (!files.defaults.empty()) {
        const InstallResult d = install_defaults(game_dir, files.defaults);
        lines.push_back(d.ok ? d.message : "Could not install the built-in clips and settings: " + d.message);
    } else {
        lines.push_back("This program carries no built-in clips (defaults.json): the other player's body stays in a T pose until your own recordings exist.");
    }
    return true;
}

bool refresh_existing_install(const fs::path& game_dir, const ModFiles& files, std::vector<std::string>& lines) {
    std::error_code ec;
    if (files.lua.empty() || !fs::is_regular_file(script_path(game_dir), ec)) return false;
    std::vector<std::string> mine;
    bool changed = false;
    const bool ok = install_script_files(game_dir, files, mine, &changed);
    bool any = !ok || changed;  // say nothing when everything was already current
    for (const auto& l : mine) {
        if (l.compare(0, 13, "Installed the") == 0 || l.compare(0, 11, "Updated the") == 0) any = true;
    }
    if (any) lines.insert(lines.end(), mine.begin(), mine.end());
    return ok && any;
}

// ------------------------------------------------------------------ the one install

InstallReport install_mod(HttpClient& http, const fs::path& game_dir, const ModFiles& files, const InstallOptions& opt) {
    InstallReport rep;
    auto say = [&](std::string s) { rep.lines.push_back(std::move(s)); };

    std::error_code ec;
    if (!fs::is_directory(game_dir, ec)) {
        say("The RE7 folder does not exist: " + game_dir.u8string());
        return rep;
    }
    if (files.lua.empty()) {  // checked first, so REFramework is not downloaded for nothing
        say("This program has no Lua script to install. Copy lua\\re7mp.lua to reframework\\autorun manually.");
        return rep;
    }
    if (!looks_like_re7(game_dir)) say("Warning: re7.exe was not found in that folder. Is it the RE7 install folder?");

    // 1. REFramework: the right version, or ask.
    const RefwCheck c = check_reframework(game_dir);
    say(c.text);
    if (c.verdict == RefwVerdict::Correct) {
        rep.refw_ready = true;
    } else if (opt.prompt_refw && opt.ask) {
        std::string title = "REFramework " + c.wanted, question;
        if (c.verdict == RefwVerdict::Missing) {
            question = "REFramework is not installed in this folder, and the mod needs it to run.\n\nDownload and install REFramework " + c.wanted + " now?";
        } else if (c.verdict == RefwVerdict::OtherVersion) {
            question = "This folder has REFramework " + c.found + " (installed by this program). The mod is tested with " + c.wanted +
                       ".\n\nReplace it with " + c.wanted + "? The old file is kept as dinput8.dll.bak.";
        } else {
            question = "This folder has a dinput8.dll that this program did not install (another REFramework version, or a different mod loader), "
                       "so its version can't be checked. The mod is tested with REFramework " + c.wanted +
                       ".\n\nReplace it with " + c.wanted + "? The old file is kept as dinput8.dll.bak.";
        }
        if (opt.ask(title, question)) {
            std::string msg;
            const bool ok = install_reframework(http, game_dir, c.wanted, true, opt.refw_dll_only, msg, opt.progress);
            say(msg);
            if (ok) {
                rep.refw_ready = true;
                rep.refw_installed_now = true;
                say("REFramework is ready. Start the game once so it can create its settings, then load a save.");
            } else {
                say("REFramework was not installed, so the mod will not run until it is.");
            }
        } else if (c.verdict == RefwVerdict::Missing) {
            say("REFramework was not installed. The script is installed anyway, but the mod will not run until REFramework " + c.wanted + " is.");
        } else {
            say("Your dinput8.dll was left as it is. If the mod does not load, install REFramework " + c.wanted + " (the Install button next to REFramework).");
        }
    } else {
        say("REFramework was not changed here. Use the Install button next to REFramework to put in " + c.wanted + ".");
    }

    // 2. The script and its data.
    rep.lua_before = [&] {
        std::vector<uint8_t> old;
        return read_bytes(script_path(game_dir), old) ? script_build(text_of(old)) : std::string();
    }();
    rep.lua_after = script_build(files.lua);
    rep.ok = install_script_files(game_dir, files, rep.lines, &rep.lua_changed);
    if (!rep.ok) return rep;
    std::error_code e2;
    fs::create_directories(game_dir / "reframework" / "data", e2);

    // 3. The full character models: the pack inside this program (10.13), else the one beside it (modpack\\third-person-full-models), or the author's
    // own zip when it is in Downloads. Never needed for the mod to run.
    if (opt.install_models) {
        ModelPackResult m;
        bool tried = false;
        const fs::path folder = files.models_zip.empty() ? find_model_folder(opt.model_dirs) : fs::path();
        if (!files.models_zip.empty()) {  // (10.13) the pack inside this program
            tried = true;
            m = install_model_pack(game_dir, files.models_zip);
        } else if (!folder.empty()) {
            tried = true;
            m = install_model_folder(game_dir, folder);
        } else {
            const fs::path pack = find_model_pack(opt.model_dirs);
            std::vector<uint8_t> zip;
            if (!pack.empty() && read_bytes(pack, zip)) {
                tried = true;
                m = install_model_pack(game_dir, zip);
            }
        }
        if (tried) {
            say(m.message);
            if (m.ok) {
                std::string note;
                enable_loose_file_loader(game_dir, note);
                say(note);
                if (!write_models_flag(game_dir)) say("Could not write reframework\\data\\re7mp\\modpack.json: the script will not know the full models are installed.");
                rep.models_installed = true;
                say(std::string("Models by AfroJackX: \"") + kModelsName + "\" (Nexus Mods, RE7 mod 86). Thank you! Please endorse it: " + kModelsPage);
            }
        } else if (fs::exists(game_dir / fs::path(kModelsProbe), e2)) {
            say("Full character models: already set up.");
            write_models_flag(game_dir);
        } else {
            say(std::string("Full character models (optional): the pack was not found in the modpack folder next to this program, and the author's download \"") +
                kModelsName + " RT (2022)\" was not in your Downloads folder. To use them, copy the modpack folder that comes with re7mp next to re7mp.exe, or click Manual download at " +
                kModelsPage + ", leave the zip in Downloads, and press Install again. The mod runs without them.");
        }
    }
    return rep;
}

// ------------------------------------------------------------------ updating the program

UpdateApply apply_update_package(const fs::path& current_exe, const UpdatePackage& pkg, const fs::path& game_dir) {
    UpdateApply a;
    if (!swap_in_new_exe(current_exe, pkg.exe, a.err)) return a;  // nothing else is touched
    a.ok = true;
    if (pkg.lua.empty()) {
        a.lines.push_back("This release carries no script" + (pkg.note.empty() ? std::string() : " (" + pkg.note + ")") +
                          ": the new program installs its own copy when it starts.");
        return a;
    }
    std::error_code ec;
    if (game_dir.empty() || !fs::is_directory(game_dir, ec)) {
        a.lines.push_back("The new Lua script is installed when you press \"Install / update mod\" with your RE7 folder set.");
        return a;
    }
    ModFiles f;
    f.lua = pkg.lua;
    f.defaults = pkg.defaults;
    install_script_files(game_dir, f, a.lines, nullptr);
    return a;
}

}  // namespace re7mp
