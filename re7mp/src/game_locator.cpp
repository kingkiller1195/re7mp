#include "game_locator.hpp"

#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace re7mp {

namespace {
std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return {};
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}
bool is_dir(const fs::path& p) {
    std::error_code ec;
    return fs::is_directory(p, ec);
}
bool is_file(const fs::path& p) {
    std::error_code ec;
    return fs::is_regular_file(p, ec);
}
}  // namespace

std::vector<std::string> vdf_tokens(const std::string& text) {
    std::vector<std::string> tokens;
    size_t i = 0;
    while (i < text.size()) {
        if (text[i] == '"') {
            std::string tok;
            ++i;
            while (i < text.size() && text[i] != '"') {
                if (text[i] == '\\' && i + 1 < text.size()) {
                    ++i;
                    const char c = text[i];
                    tok += (c == 'n') ? '\n' : (c == 't') ? '\t' : c;  // \\ -> \, \" -> "
                } else {
                    tok += text[i];
                }
                ++i;
            }
            ++i;  // closing quote
            tokens.push_back(tok);
        } else if (text[i] == '/' && i + 1 < text.size() && text[i + 1] == '/') {
            while (i < text.size() && text[i] != '\n') ++i;
        } else {
            ++i;
        }
    }
    return tokens;
}

std::vector<fs::path> parse_library_paths(const std::string& vdf) {
    std::vector<fs::path> out;
    const auto tokens = vdf_tokens(vdf);
    for (size_t i = 0; i + 1 < tokens.size(); ++i) {
        if (tokens[i] == "path" && !tokens[i + 1].empty()) out.emplace_back(tokens[i + 1]);
    }
    return out;
}

std::string parse_install_dir(const std::string& acf) {
    const auto tokens = vdf_tokens(acf);
    for (size_t i = 0; i + 1 < tokens.size(); ++i) {
        if (tokens[i] == "installdir") return tokens[i + 1];
    }
    return {};
}

std::optional<fs::path> find_re7_in_steam(const fs::path& steam_root) {
    std::vector<fs::path> libs{steam_root};
    for (auto& p : parse_library_paths(read_file(steam_root / "steamapps" / "libraryfolders.vdf"))) libs.push_back(p);

    for (const auto& lib : libs) {
        const fs::path apps = lib / "steamapps";
        const std::string dir =
            parse_install_dir(read_file(apps / (std::string("appmanifest_") + kRe7AppId + ".acf")));
        if (!dir.empty() && is_dir(apps / "common" / dir)) return apps / "common" / dir;
        // Fallback: the usual folder name, in case the manifest is missing.
        if (is_dir(apps / "common" / "RESIDENT EVIL 7 biohazard")) return apps / "common" / "RESIDENT EVIL 7 biohazard";
    }
    return std::nullopt;
}

bool looks_like_re7(const fs::path& dir) { return is_file(dir / "re7.exe"); }
bool refw_installed(const fs::path& dir) { return is_file(dir / "dinput8.dll"); }
fs::path data_dir_for(const fs::path& game_dir) { return game_dir / "reframework" / "data"; }

namespace {
// Creates the folder and writes the file unless it already holds exactly this text.
InstallResult install_text_file(const fs::path& file, const std::string& text, const char* what) {
    InstallResult r;
    std::error_code ec;
    fs::create_directories(file.parent_path(), ec);
    if (ec) {
        r.message = "could not create " + file.parent_path().u8string() + ": " + ec.message();
        return r;
    }
    const std::string existing = read_file(file);
    if (!existing.empty() && existing == text) {
        r.ok = true;
        r.message = std::string(what) + " is up to date.";
        return r;
    }
    std::ofstream out(file, std::ios::binary | std::ios::trunc);
    if (!out) {
        r.message = "could not write " + file.u8string();
        return r;
    }
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
    out.close();
    if (!out) {
        r.message = "error while writing " + file.u8string();
        return r;
    }
    r.ok = true;
    r.changed = true;
    r.message = (existing.empty() ? std::string("Installed the ") : std::string("Updated the ")) + what + " in " + file.u8string();
    return r;
}
}  // namespace

InstallResult install_lua(const fs::path& game_dir, const std::string& lua_text) {
    return install_text_file(game_dir / "reframework" / "autorun" / "re7mp.lua", lua_text, "Lua script");
}

InstallResult install_defaults(const fs::path& game_dir, const std::string& json_text) {
    return install_text_file(game_dir / "reframework" / "data" / "re7mp" / "defaults.json", json_text, "built-in clips and settings (defaults.json)");
}

}  // namespace re7mp
