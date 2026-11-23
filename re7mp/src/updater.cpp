#include "updater.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <sstream>

#include "json_mini.hpp"
#include "packet.hpp"  // crc32
#include "zip_extract.hpp"

namespace fs = std::filesystem;

namespace re7mp {

namespace {

std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool ends_with(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::vector<long> numeric_parts(const std::string& v) {
    std::vector<long> out;
    size_t i = 0;
    while (i < v.size()) {
        size_t j = i;
        long n = 0;
        while (j < v.size() && std::isdigit(static_cast<unsigned char>(v[j]))) {
            n = n * 10 + (v[j] - '0');
            if (n > 1000000) n = 1000000;
            ++j;
        }
        out.push_back(n);
        while (j < v.size() && v[j] != '.') ++j;  // anything after the digits (a suffix) is ignored
        i = j + 1;
    }
    return out;
}

// Digits with dots starting at s[i]; "" if there are none.
std::string number_at(const std::string& s, size_t i) {
    size_t j = i;
    while (j < s.size() && std::isdigit(static_cast<unsigned char>(s[j]))) ++j;
    if (j == i) return {};
    while (j + 1 < s.size() && s[j] == '.' && std::isdigit(static_cast<unsigned char>(s[j + 1]))) {
        ++j;
        while (j < s.size() && std::isdigit(static_cast<unsigned char>(s[j]))) ++j;
    }
    return s.substr(i, j - i);
}

std::string version_in_title(const std::string& s) {
    for (size_t i = 0; i < s.size(); ++i) {
        if (i > 0 && std::isalnum(static_cast<unsigned char>(s[i - 1]))) continue;
        size_t j = i;
        bool has_v = false;
        if (s[j] == 'v' || s[j] == 'V') {
            has_v = true;
            ++j;
        }
        const std::string num = number_at(s, j);
        if (num.empty()) continue;
        if (has_v || num.find('.') != std::string::npos) return num;
    }
    return {};
}

std::string version_in_tag(const std::string& tag) {
    size_t i = 0;
    while (i < tag.size() && std::isspace(static_cast<unsigned char>(tag[i]))) ++i;
    if (i < tag.size() && (tag[i] == 'v' || tag[i] == 'V')) ++i;
    const std::string num = number_at(tag, i);
    if (num.empty()) return {};
    const size_t after = i + num.size();
    if (after < tag.size() && tag[after] != '-' && tag[after] != '+' && tag[after] != '_') return {};
    return num;
}

// (10.26) Finds the alpha label in `s`: the word "alpha" (not inside a longer word), some separators, an optional "build" / "b" / "v", more separators and
// a number token (digits, and dots between digits). begin / end: where the whole label sits in `s` (the number token included, whatever it is); number: the
// alpha number when the token is one whole number from 1 to 9999, else 0 ("alpha" alone, "alpha 10.24", "alpha 0"). False when there is no such word.
bool find_alpha_label(const std::string& s, size_t& begin, size_t& end, int& number) {
    const std::string low = lower(s);  // same length as s
    auto sep = [&](size_t i) {
        return i < low.size() && (low[i] == ' ' || low[i] == '-' || low[i] == '_' || low[i] == '.' || low[i] == ':' || low[i] == '#');
    };
    bool found = false;  // the first alpha word, kept in case no later one has a number
    for (size_t at = low.find("alpha"); at != std::string::npos; at = low.find("alpha", at + 1)) {
        if (at > 0 && std::isalnum(static_cast<unsigned char>(low[at - 1]))) continue;     // inside a longer word
        size_t i = at + 5;
        if (i < low.size() && std::isalpha(static_cast<unsigned char>(low[i]))) continue;  // "alphabet"
        while (sep(i)) ++i;
        for (const char* w : {"build", "b", "v"}) {  // "alpha build 3", "alpha v3", "alpha b3"
            const size_t n = std::char_traits<char>::length(w);
            if (low.compare(i, n, w) == 0 && i + n < low.size() && (sep(i + n) || std::isdigit(static_cast<unsigned char>(low[i + n])))) {
                i += n;
                while (sep(i)) ++i;
                break;
            }
        }
        const std::string num = number_at(low, i);
        int n = 0;
        if (!num.empty() && num.find('.') == std::string::npos && num.size() <= 4) {
            n = std::atoi(num.c_str());
            if (n < 1) n = 0;
        }
        if (n > 0 || !found) {
            begin = at;
            end = i + num.size();
            number = n;
            found = true;
        }
        if (n > 0) return true;
    }
    return found;
}

bool read_all(const fs::path& p, std::vector<uint8_t>& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

bool write_all(const fs::path& p, const std::vector<uint8_t>& data) {
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
    f.close();
    return static_cast<bool>(f);
}

// "dir/name" + ".bak" without going through the narrow code page (non-ASCII folders would break or throw on Windows).
fs::path with_suffix(const fs::path& p, const char* suffix) {
    fs::path r = p;
    r += suffix;
    return r;
}

bool looks_like_exe(const std::vector<uint8_t>& d) { return d.size() >= 64 * 1024 && d[0] == 'M' && d[1] == 'Z'; }

std::string as_string(const std::vector<uint8_t>& b) { return std::string(b.begin(), b.end()); }

constexpr uint64_t kMaxExe = 100ull * 1024 * 1024;
constexpr uint64_t kMaxRefwFile = 200ull * 1024 * 1024;
constexpr uint64_t kMaxRefwTotal = 400ull * 1024 * 1024;

}  // namespace

int compare_versions(const std::string& a, const std::string& b) {
    std::vector<long> x = numeric_parts(a), y = numeric_parts(b);
    const size_t n = std::max(x.size(), y.size());
    x.resize(n, 0);
    y.resize(n, 0);
    for (size_t i = 0; i < n; ++i) {
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
}

std::string release_version(const std::string& title, const std::string& tag) {
    std::string v = version_in_title(title);
    if (v.empty()) v = version_in_tag(tag);
    return v;
}

bool has_alpha_word(const std::string& text) {
    size_t b = 0, e = 0;
    int n = 0;
    return find_alpha_label(text, b, e, n);
}

int alpha_number_in(const std::string& text) {
    size_t b = 0, e = 0;
    int n = 0;
    return find_alpha_label(text, b, e, n) ? n : 0;
}

std::string without_alpha_label(const std::string& text) {
    size_t b = 0, e = 0;
    int n = 0;
    if (!find_alpha_label(text, b, e, n)) return text;
    return text.substr(0, b) + text.substr(e);
}

int compare_release(const std::string& version_a, int alpha_a, const std::string& version_b, int alpha_b) {
    const int c = compare_versions(version_a, version_b);
    if (c != 0) return c;
    // the same release number: a normal release (alpha 0) is below its alphas, or above them when the alphas lead up to it
    auto rank = [](int a) { return (!kAlphaFollowsItsRelease && a == 0) ? 1000000 : a; };
    const int x = rank(alpha_a), y = rank(alpha_b);
    return x < y ? -1 : (x > y ? 1 : 0);
}

std::string release_name(const std::string& version, int alpha) {
    const std::string v = version.empty() ? std::string() : "v" + version;
    if (alpha <= 0) return v;
    return (v.empty() ? std::string() : v + " ") + "alpha " + std::to_string(alpha);
}

bool url_is_github(const std::string& url) {
    const std::string pre = "https://";
    if (url.compare(0, pre.size(), pre) != 0) return false;
    size_t end = url.find_first_of("/?#", pre.size());
    std::string host = lower(url.substr(pre.size(), end == std::string::npos ? std::string::npos : end - pre.size()));
    if (host.empty() || host.find('@') != std::string::npos) return false;
    const size_t colon = host.find(':');
    if (colon != std::string::npos) {
        if (host.substr(colon) != ":443") return false;
        host.resize(colon);
    }
    return host == "github.com" || ends_with(host, ".github.com") || host == "githubusercontent.com" ||
           ends_with(host, ".githubusercontent.com");
}

bool parse_release_list(const std::string& json, std::vector<ReleaseInfo>& out, std::string& err) {
    out.clear();
    mini::Value root;
    if (!mini::parse(json, root)) {
        err = "GitHub's answer could not be read";
        return false;
    }
    std::vector<const mini::Value*> list;
    if (root.type == mini::Value::Type::Arr) {
        for (const auto& r : root.arr) list.push_back(&r);
    } else if (root.type == mini::Value::Type::Obj) {
        if (const auto* msg = root.get("message"); msg && msg->type == mini::Value::Type::Str && !root.get("tag_name")) {
            err = "GitHub says: " + msg->str;  // e.g. "Not Found", or the rate limit message
            return false;
        }
        list.push_back(&root);
    }
    for (const mini::Value* r : list) {
        if (r->type != mini::Value::Type::Obj) continue;
        auto str = [&](const char* k) {
            const auto* v = r->get(k);
            return v && v->type == mini::Value::Type::Str ? v->str : std::string();
        };
        auto flag = [&](const char* k) {
            const auto* v = r->get(k);
            return v && v->type == mini::Value::Type::Bool && v->b;
        };
        if (flag("draft")) continue;
        ReleaseInfo info;
        info.tag = str("tag_name");
        info.title = str("name");
        info.alpha = has_alpha_word(info.title) || has_alpha_word(info.tag);
        info.alpha_no = alpha_number_in(info.title);
        if (info.alpha_no == 0) info.alpha_no = alpha_number_in(info.tag);
        // An alpha release's release number is read from what is left of the title and the tag once the label is out of them ("Alpha 3 (v0.11)" is
        // release 0.11, not release 3); one that names no release has an empty version, and the alpha channel does not offer it (it cannot be put in order).
        info.version = !info.alpha ? release_version(info.title, info.tag)
                                   : release_version(without_alpha_label(info.title), without_alpha_label(info.tag));
        info.notes = str("body");
        info.page_url = str("html_url");
        info.prerelease = flag("prerelease");
        if (const auto* assets = r->get("assets"); assets && assets->type == mini::Value::Type::Arr) {
            for (const auto& a : assets->arr) {
                if (a.type != mini::Value::Type::Obj) continue;
                ReleaseAsset ra;
                if (const auto* n = a.get("name"); n && n->type == mini::Value::Type::Str) ra.name = n->str;
                if (const auto* u = a.get("browser_download_url"); u && u->type == mini::Value::Type::Str) ra.url = u->str;
                if (const auto* z = a.get("size"); z && z->type == mini::Value::Type::Num && z->num > 0) {
                    ra.size = static_cast<uint64_t>(z->num);
                }
                if (!ra.name.empty() && !ra.url.empty()) info.assets.push_back(std::move(ra));
            }
        }
        out.push_back(std::move(info));
    }
    return true;
}

bool pick_release(const std::string& json, bool include_prerelease, ReleaseInfo& out, std::string& err) {
    std::vector<ReleaseInfo> all;
    if (!parse_release_list(json, all, err)) return false;
    bool found = false;
    for (auto& info : all) {
        if (info.prerelease && !include_prerelease) continue;
        if (info.alpha) continue;  // (10.24) an alpha build is for the alpha channel only, never for a player on the normal releases (10.26: any release with the word alpha)
        if (info.version.empty()) continue;
        if (!found || compare_versions(info.version, out.version) > 0) {
            out = std::move(info);
            found = true;
        }
    }
    if (!found) {
        err = "no release with a version number was found";
        return false;
    }
    return true;
}

AssetKind choose_asset(const ReleaseInfo& r, ReleaseAsset& chosen) {
    for (const auto& a : r.assets) {  // 1. exactly re7mp.exe
        if (lower(a.name) == "re7mp.exe") {
            chosen = a;
            return AssetKind::Exe;
        }
    }
    for (const auto& a : r.assets) {  // 2. another .exe named re7mp...
        const std::string n = lower(a.name);
        if (ends_with(n, ".exe") && n.find("re7mp") != std::string::npos) {
            chosen = a;
            return AssetKind::Exe;
        }
    }
    for (const auto& a : r.assets) {  // 3. a zip that should contain it
        const std::string n = lower(a.name);
        if (ends_with(n, ".zip") && n.find("source") == std::string::npos && n.find("src") == std::string::npos) {
            chosen = a;
            return AssetKind::Zip;
        }
    }
    return AssetKind::None;
}

UpdateCheck check_for_update(HttpClient& http, const std::string& current_version, bool include_prerelease) {
    UpdateCheck r;
    std::vector<uint8_t> body;
    std::string err;
    if (!http.get(include_prerelease ? kReleasesApiList : kReleasesApiLatest, body, err, nullptr)) {
        r.message = "Could not check for updates: " + err;
        return r;
    }
    bool picked = pick_release(as_string(body), include_prerelease, r.release, err);
    if (!picked && !include_prerelease) {
        // (10.24) "latest" is one release, the newest that is not flagged pre-release. An alpha build published without that flag can be it, and
        // then it is not for this player: the list has the normal releases too. If that fails as well, the complaint of the first answer stands.
        std::vector<uint8_t> list_body;
        std::string list_err;
        picked = http.get(kReleasesApiList, list_body, list_err, nullptr) && pick_release(as_string(list_body), false, r.release, list_err);
    }
    if (!picked) {
        r.message = "Could not check for updates: " + err;
        return r;
    }
    if (compare_versions(r.release.version, current_version) > 0) {
        r.state = UpdateCheck::State::Available;
        r.message = "Version " + r.release.version + " is available (you have " + current_version + ").";
    } else {
        r.state = UpdateCheck::State::UpToDate;
        r.message = "You have the newest release (" + current_version + ").";
    }
    return r;
}

namespace {

// The shared part of fetch_new_exe and fetch_update_package. When the asset is a zip it is handed back in `zip_out`.
bool fetch_exe_impl(HttpClient& http, const ReleaseInfo& r, std::vector<uint8_t>& exe, std::vector<uint8_t>* zip_out,
                    std::string& err, const Progress& progress) {
    ReleaseAsset asset;
    const AssetKind kind = choose_asset(r, asset);
    if (kind == AssetKind::None) {
        err = "this release has no re7mp.exe (or a zip containing it) attached; download it from the releases page";
        return false;
    }
    if (!url_is_github(asset.url)) {
        err = "the download link is not on github.com, so it was not followed";
        return false;
    }
    std::vector<uint8_t> body;
    if (!http.get(asset.url, body, err, progress)) return false;
    if (kind == AssetKind::Exe) {
        exe = std::move(body);
    } else {
        std::vector<ZipEntry> entries;
        if (!zip_list(body, entries, err)) return false;
        const ZipEntry* best = nullptr;
        for (const auto& z : entries) {
            if (z.is_dir || !zip_name_is(z.name, "re7mp.exe")) continue;
            if (!best || zip_safe_name(z.name).size() < zip_safe_name(best->name).size()) best = &z;
        }
        if (!best) {
            err = asset.name + " does not contain re7mp.exe";
            return false;
        }
        if (!zip_read(body, *best, exe, kMaxExe, err)) return false;
        if (zip_out) *zip_out = std::move(body);
    }
    if (!looks_like_exe(exe)) {
        err = "the downloaded file does not look like a Windows program, so it was not installed";
        exe.clear();
        if (zip_out) zip_out->clear();
        return false;
    }
    return true;
}

constexpr uint64_t kMaxScriptFile = 16ull * 1024 * 1024;

// The text between the quotes after `key = "` where the key starts a word (so BUILD does not match PREBUILD).
std::string quoted_after(const std::string& text, const std::string& key) {
    const std::string pat = key + " = \"";
    size_t from = 0;
    while (true) {
        const size_t i = text.find(pat, from);
        if (i == std::string::npos) return {};
        const bool word_start = i == 0 || !(std::isalnum(static_cast<unsigned char>(text[i - 1])) || text[i - 1] == '_' || text[i - 1] == '.');
        if (word_start) {
            const size_t a = i + pat.size(), b = text.find('"', a);
            if (b == std::string::npos || b - a > 32) return {};
            return text.substr(a, b - a);
        }
        from = i + 1;
    }
}

}  // namespace

std::string script_build(const std::string& lua) { return quoted_after(lua.substr(0, 16384), "BUILD"); }
std::string script_release(const std::string& lua) { return quoted_after(lua.substr(0, 16384), "RELEASE"); }
int script_alpha(const std::string& lua) {
    const std::string a = quoted_after(lua.substr(0, 16384), "ALPHA");
    if (a.empty() || a.size() > 4) return 0;
    for (const char c : a) {
        if (!std::isdigit(static_cast<unsigned char>(c))) return 0;
    }
    return std::atoi(a.c_str());
}

bool fetch_new_exe(HttpClient& http, const ReleaseInfo& r, std::vector<uint8_t>& exe, std::string& err,
                   const Progress& progress) {
    return fetch_exe_impl(http, r, exe, nullptr, err, progress);
}

bool fetch_update_package(HttpClient& http, const ReleaseInfo& r, UpdatePackage& pkg, std::string& err,
                          const Progress& progress) {
    pkg = UpdatePackage{};
    std::vector<uint8_t> zip;
    if (!fetch_exe_impl(http, r, pkg.exe, &zip, err, progress)) return false;

    std::string lua, defaults;
    if (!zip.empty()) {  // the release is a zip: the script sits in its lua/ folder, the clips under data/re7mp/
        std::vector<ZipEntry> entries;
        std::string zerr;
        if (zip_list(zip, entries, zerr)) {
            const ZipEntry *lua_e = nullptr, *def_e = nullptr;
            for (const auto& z : entries) {
                if (z.is_dir) continue;
                const std::string n = lower(zip_safe_name(z.name));
                if (n.empty()) continue;
                if (n == "re7mp.lua" || ends_with(n, "/re7mp.lua")) {
                    if (!lua_e || n.size() < zip_safe_name(lua_e->name).size()) lua_e = &z;
                } else if (n == "data/re7mp/defaults.json" || ends_with(n, "/data/re7mp/defaults.json")) {
                    if (!def_e || n.size() < zip_safe_name(def_e->name).size()) def_e = &z;
                }
            }
            std::vector<uint8_t> b;
            if (lua_e && zip_read(zip, *lua_e, b, kMaxScriptFile, zerr)) lua = as_string(b);
            if (def_e && zip_read(zip, *def_e, b, kMaxScriptFile, zerr)) defaults = as_string(b);
        }
    } else {  // the release is the bare exe: look for the two files beside it
        for (const auto& a : r.assets) {
            const std::string n = lower(a.name);
            std::string* dest = n == "re7mp.lua" ? &lua : n == "defaults.json" ? &defaults : nullptr;
            if (!dest || !url_is_github(a.url)) continue;
            std::vector<uint8_t> b;
            std::string gerr;
            if (http.get(a.url, b, gerr, nullptr) && b.size() <= kMaxScriptFile) *dest = as_string(b);
        }
    }

    if (lua.empty()) {
        pkg.note = "this release has no re7mp.lua attached";
    } else if (lua.find('\0') != std::string::npos) {
        pkg.note = "the release's re7mp.lua is not a text file";
        lua.clear();
    } else if (r.alpha) {  // (10.26) an alpha release: the script's RELEASE label is the alpha's release number and its ALPHA label is the alpha's number
        if (script_release(lua).empty() || compare_versions(script_release(lua), r.version) != 0) {
            pkg.note = "the release's re7mp.lua says release \"" + script_release(lua) + "\" but the release is " + release_name(r.version, r.alpha_no);
            lua.clear();
        } else if (r.alpha_no <= 0 || script_alpha(lua) != r.alpha_no) {
            pkg.note = "the release's re7mp.lua says alpha " + std::to_string(script_alpha(lua)) + " but the release is " + release_name(r.version, r.alpha_no);
            lua.clear();
        }
    } else if (script_release(lua).empty() || compare_versions(script_release(lua), r.version) != 0) {
        pkg.note = "the release's re7mp.lua says release \"" + script_release(lua) + "\" but the release is " + r.version;
        lua.clear();
    }
    if (!lua.empty()) {
        pkg.lua = std::move(lua);
        pkg.defaults = std::move(defaults);
    }
    return true;
}

bool swap_in_new_exe(const fs::path& current_exe, const std::vector<uint8_t>& exe, std::string& err) {
    const fs::path fresh = with_suffix(current_exe, ".new"), old = with_suffix(current_exe, ".old");
    std::error_code ec;
    if (!write_all(fresh, exe)) {
        err = "could not write " + fresh.u8string() + " (is the folder write-protected? try running from a folder you own)";
        fs::remove(fresh, ec);
        return false;
    }
    fs::remove(old, ec);  // left over from the last update
    fs::rename(current_exe, old, ec);
    if (ec) {
        err = "could not move the running re7mp.exe aside: " + ec.message();
        fs::remove(fresh, ec);
        return false;
    }
    fs::rename(fresh, current_exe, ec);
    if (ec) {
        const std::string why = ec.message();
        std::error_code ec2;
        fs::rename(old, current_exe, ec2);  // put the working one back
        fs::remove(fresh, ec2);
        err = "could not move the new re7mp.exe into place: " + why;
        return false;
    }
    return true;
}

void cleanup_old_exe(const fs::path& current_exe) {
    std::error_code ec;
    fs::remove(with_suffix(current_exe, ".old"), ec);
    fs::remove(with_suffix(current_exe, ".new"), ec);
}

// ------------------------------------------------------------------ REFramework

namespace {

fs::path refw_record(const fs::path& game) { return game / "reframework" / "data" / "re7mp_reframework.json"; }

struct RefwRecord {
    std::string tag;
    uint32_t crc = 0;
    uint64_t size = 0;
    bool ok = false;
};

RefwRecord read_record(const fs::path& game) {
    RefwRecord r;
    std::vector<uint8_t> b;
    mini::Value v;
    if (!read_all(refw_record(game), b) || !mini::parse(as_string(b), v) || v.type != mini::Value::Type::Obj) return r;
    const auto *tag = v.get("tag"), *crc = v.get("crc"), *size = v.get("size");
    if (!tag || !crc || !size) return r;
    r.tag = tag->str;
    r.crc = static_cast<uint32_t>(crc->num);
    r.size = static_cast<uint64_t>(size->num);
    r.ok = true;
    return r;
}

std::string lower_path(const std::string& s) { return lower(s); }

}  // namespace

std::string reframework_url(const std::string& tag) {
    return std::string("https://github.com/praydog/REFramework/releases/download/") + tag + "/" + kReframeworkAsset;
}

RefwState reframework_state(const fs::path& game_dir) {
    RefwState st;
    const fs::path dll = game_dir / kReframeworkDll;
    std::error_code ec;
    if (!fs::exists(dll, ec)) return st;
    st.kind = RefwState::Kind::InstalledOther;
    const RefwRecord rec = read_record(game_dir);
    if (!rec.ok) return st;
    if (fs::file_size(dll, ec) != rec.size || ec) return st;
    std::vector<uint8_t> data;
    if (!read_all(dll, data) || crc32(data.data(), data.size()) != rec.crc) return st;
    st.kind = RefwState::Kind::InstalledByUs;
    st.tag = rec.tag;
    return st;
}

bool install_reframework(HttpClient& http, const fs::path& game_dir, const std::string& tag, bool replace_existing,
                         bool dll_only, std::string& message, const Progress& progress) {
    std::error_code ec;
    if (!fs::is_directory(game_dir, ec)) {
        message = "The RE7 folder does not exist.";
        return false;
    }
    const fs::path dll = game_dir / kReframeworkDll;
    const bool had_dll = fs::exists(dll, ec);
    if (had_dll && !replace_existing) {
        message = "There is already a dinput8.dll in the RE7 folder (REFramework, or another mod loader). Nothing was changed.";
        return false;
    }

    std::vector<uint8_t> body;
    std::string err;
    if (!http.get(reframework_url(tag), body, err, progress)) {
        message = "Could not download REFramework " + tag + ": " + err;
        return false;
    }
    std::vector<ZipEntry> entries;
    if (!zip_list(body, entries, err)) {
        message = "The REFramework download is not a usable zip: " + err;
        return false;
    }

    // 1. Unpack and verify everything in memory first.
    struct Item {
        std::string rel;
        std::vector<uint8_t> data;
    };
    std::vector<Item> items;
    Item dll_item;
    bool have_dll = false;
    uint64_t total = 0;
    int skipped = 0;
    for (const auto& z : entries) {
        if (z.is_dir) continue;
        const std::string rel = zip_safe_name(z.name);
        if (rel.empty()) {
            ++skipped;
            continue;
        }
        const bool is_dll = zip_name_is(z.name, kReframeworkDll);
        if (dll_only && !is_dll) continue;
        Item it;
        it.rel = rel;
        total += z.size;
        if (total > kMaxRefwTotal) {
            message = "The REFramework zip is far bigger than expected, so it was not installed.";
            return false;
        }
        if (!zip_read(body, z, it.data, kMaxRefwFile, err)) {
            message = "The REFramework download is damaged: " + err;
            return false;
        }
        if (is_dll) {
            if (have_dll && rel.size() >= dll_item.rel.size()) continue;  // the shallowest dinput8.dll wins
            it.rel = kReframeworkDll;  // always lands in the game folder itself
            dll_item = std::move(it);
            have_dll = true;
        } else {
            items.push_back(std::move(it));
        }
    }
    if (!have_dll || dll_item.data.size() < 64 * 1024 || dll_item.data[0] != 'M' || dll_item.data[1] != 'Z') {
        message = std::string("The REFramework zip has no usable ") + kReframeworkDll + ".";
        return false;
    }

    // 2. Write the other files first (so a failure leaves the old dinput8.dll alone), then the dll.
    int written = 0, kept = 0;
    std::vector<std::string> names;
    for (const auto& it : items) {
        const fs::path dest = game_dir / fs::path(it.rel);
        const bool in_reframework_folder = lower_path(it.rel).compare(0, 12, "reframework/") == 0;
        if (in_reframework_folder && fs::exists(dest, ec)) {
            ++kept;  // yours: scripts, settings, fonts you changed
            continue;
        }
        if (fs::exists(dest, ec)) {  // already exactly this file: nothing to do
            std::vector<uint8_t> cur;
            if (read_all(dest, cur) && cur.size() == it.data.size() && crc32(cur.data(), cur.size()) == crc32(it.data.data(), it.data.size())) {
                continue;
            }
        }
        fs::create_directories(dest.parent_path(), ec);
        const fs::path tmp = with_suffix(dest, ".re7mp-new");
        if (!write_all(tmp, it.data)) {
            fs::remove(tmp, ec);
            message = "Could not write " + dest.u8string() + ". Is RE7 still running?";
            return false;
        }
        fs::rename(tmp, dest, ec);
        if (ec) {
            std::error_code ec2;
            fs::remove(tmp, ec2);
            message = "Could not replace " + dest.u8string() + " (" + ec.message() + "). Is RE7 still running?";
            return false;
        }
        ++written;
        names.push_back(it.rel);
    }

    std::string backup_note;
    const uint32_t new_crc = crc32(dll_item.data.data(), dll_item.data.size());
    bool dll_changed = true;
    if (had_dll) {
        std::vector<uint8_t> cur;
        if (read_all(dll, cur) && cur.size() == dll_item.data.size() && crc32(cur.data(), cur.size()) == new_crc) dll_changed = false;
    }
    if (dll_changed) {
        const fs::path tmp = with_suffix(dll, ".re7mp-new");
        if (!write_all(tmp, dll_item.data)) {
            fs::remove(tmp, ec);
            message = "Could not write dinput8.dll. Is RE7 still running?";
            return false;
        }
        fs::path backup;
        if (had_dll) {
            backup = with_suffix(dll, ".bak");
            for (int n = 2; fs::exists(backup, ec) && n < 20; ++n) backup = with_suffix(dll, (".bak" + std::to_string(n)).c_str());
            fs::rename(dll, backup, ec);
            if (ec) {
                std::error_code ec2;
                fs::remove(tmp, ec2);
                message = "Could not move the old dinput8.dll aside (" + ec.message() + "). Close RE7 and try again.";
                return false;
            }
        }
        fs::rename(tmp, dll, ec);
        if (ec) {
            const std::string why = ec.message();
            std::error_code ec2;
            if (had_dll) fs::rename(backup, dll, ec2);  // put the old one back
            fs::remove(tmp, ec2);
            message = "Could not put dinput8.dll in place (" + why + ").";
            return false;
        }
        if (had_dll) backup_note = " Your previous dinput8.dll was kept as " + backup.filename().u8string() + ".";
        ++written;
        names.push_back(kReframeworkDll);
    }

    // 3. The folders the Lua script and REFramework's own data go in.
    fs::create_directories(game_dir / "reframework" / "autorun", ec);
    fs::create_directories(game_dir / "reframework" / "data", ec);

    // 4. Remember what we installed, so the next start can say "installed by this tool".
    {
        std::ostringstream js;
        js << "{\"tag\":\"" << tag << "\",\"crc\":" << new_crc << ",\"size\":" << dll_item.data.size() << "}\n";
        const std::string t = js.str();
        write_all(refw_record(game_dir), std::vector<uint8_t>(t.begin(), t.end()));
    }

    std::ostringstream m;
    if (!dll_changed && written == 0) {
        m << "REFramework " << tag << " was already installed and up to date.";
    } else {
        m << "Installed REFramework " << tag << ": " << written << " file" << (written == 1 ? "" : "s") << " (";
        for (size_t i = 0; i < names.size() && i < 6; ++i) m << (i ? ", " : "") << names[i];
        if (names.size() > 6) m << ", ...";
        m << ").";
        if (kept > 0) m << " " << kept << " existing file" << (kept == 1 ? "" : "s") << " in your reframework folder were left as they are.";
        m << backup_note;
    }
    if (skipped > 0) m << " (" << skipped << " entries with unsafe names were skipped.)";
    message = m.str();
    return true;
}

}  // namespace re7mp
