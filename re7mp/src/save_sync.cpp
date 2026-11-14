#include "save_sync.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <sstream>

#include "json_mini.hpp"
#include "packet.hpp"  // crc32

namespace fs = std::filesystem;

namespace re7mp {

int parse_slot(const std::string& filename) {
    std::string f;
    for (char c : filename) f += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    // "data" + 3 digits + "slot" + ".bin"
    if (f.size() != 15 || f.compare(0, 4, "data") != 0 || f.compare(7, 4, "slot") != 0 || f.compare(11, 4, ".bin") != 0) return -1;
    int n = 0;
    for (int i = 4; i < 7; ++i) {
        if (!std::isdigit(static_cast<unsigned char>(f[static_cast<size_t>(i)]))) return -1;
        n = n * 10 + (f[static_cast<size_t>(i)] - '0');
    }
    return n >= 1 ? n : -1;
}

std::string slot_filename(int slot) {
    char buf[24];
    std::snprintf(buf, sizeof(buf), "data%03dSlot.bin", slot);
    return buf;
}

std::vector<fs::path> find_save_dirs(const fs::path& steam_root) {
    struct Cand {
        fs::path dir;
        fs::file_time_type newest = fs::file_time_type::min();  // not {}: that is far in the future on some libraries
    };
    std::vector<Cand> found;
    std::error_code ec;
    for (const auto& user : fs::directory_iterator(steam_root / "userdata", ec)) {
        const fs::path dir = user.path() / "418370" / "remote" / "win64_save";
        std::error_code e2;
        if (!fs::is_directory(dir, e2)) continue;
        Cand c;
        c.dir = dir;
        for (const auto& f : fs::directory_iterator(dir, e2)) {
            std::error_code e3;
            const auto t = fs::last_write_time(f.path(), e3);
            if (!e3 && t > c.newest) c.newest = t;
        }
        found.push_back(c);
    }
    std::sort(found.begin(), found.end(), [](const Cand& a, const Cand& b) { return a.newest > b.newest; });
    std::vector<fs::path> out;
    for (auto& c : found) out.push_back(c.dir);
    return out;
}

// ---- which Steam account's folder (9.42) -----------------------------------------------------

namespace {
// 1..4294967295 from digits only (at most 10); 0 for anything else.
uint32_t parse_id32(const std::string& t) {
    if (t.empty() || t.size() > 10) return 0;
    uint64_t v = 0;
    for (char c : t) {
        if (c < '0' || c > '9') return 0;
        v = v * 10 + static_cast<uint64_t>(c - '0');
    }
    return v >= 1 && v <= 0xFFFFFFFFull ? static_cast<uint32_t>(v) : 0;
}
bool same_name_ci(const std::string& a, const char* b) {
    const std::string bb(b);
    if (a.size() != bb.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(a[i])) != std::tolower(static_cast<unsigned char>(bb[i]))) return false;
    }
    return true;
}
fs::path save_dir_of(const fs::path& steam_root, uint32_t account) {
    return steam_root / "userdata" / std::to_string(account) / "418370" / "remote" / "win64_save";
}
}  // namespace

uint32_t account_of_save_dir(const fs::path& dir_in) {
    fs::path dir = dir_in;
    if (!dir.has_filename()) dir = dir.parent_path();  // a trailing separator
    if (!same_name_ci(dir.filename().u8string(), "win64_save")) return 0;
    dir = dir.parent_path();
    if (!same_name_ci(dir.filename().u8string(), "remote")) return 0;
    dir = dir.parent_path();
    if (dir.filename().u8string() != "418370") return 0;
    dir = dir.parent_path();
    return parse_id32(dir.filename().u8string());
}

uint32_t last_login_from_vdf(const std::string& t) {
    // Valve's text format: quoted strings and braces. "users" { "<steam64>" { ... "MostRecent" "1" ... } ... }
    struct Tok {
        char kind;  // 'q' quoted string, '{', '}'
        std::string text;
    };
    std::vector<Tok> toks;
    for (size_t i = 0; i < t.size() && toks.size() < 20000;) {
        const char c = t[i];
        if (c == '{' || c == '}') {
            toks.push_back({c, ""});
            ++i;
        } else if (c == '"') {
            std::string v;
            ++i;
            while (i < t.size() && t[i] != '"') {
                if (t[i] == '\\' && i + 1 < t.size()) ++i;
                v += t[i++];
            }
            ++i;  // closing quote
            toks.push_back({'q', v});
        } else if (c == '/' && i + 1 < t.size() && t[i + 1] == '/') {  // a comment to the end of the line
            while (i < t.size() && t[i] != '\n') ++i;
        } else {
            ++i;
        }
    }
    constexpr uint64_t kSteam64Base = 76561197960265728ull;  // the id of "account 0"; the account id is the 64-bit id minus this
    int depth = 0;
    std::string user;  // the key of the block at depth 2
    for (size_t i = 0; i < toks.size(); ++i) {
        const Tok& k = toks[i];
        if (k.kind == '{') {
            ++depth;
        } else if (k.kind == '}') {
            --depth;
        } else if (k.kind == 'q' && i + 1 < toks.size()) {
            const Tok& n = toks[i + 1];
            if (n.kind == '{') {
                if (depth == 1) user = k.text;  // "<steam64>" {   (inside "users")
            } else if (n.kind == 'q' && depth == 2 && same_name_ci(k.text, "MostRecent") && n.text == "1") {
                uint64_t v = 0;
                bool digits = !user.empty() && user.size() <= 20;
                for (char c : user) {
                    if (!digits) break;
                    if (c < '0' || c > '9') {
                        digits = false;
                        break;
                    }
                    v = v * 10 + static_cast<uint64_t>(c - '0');
                }
                if (digits && v > kSteam64Base && v - kSteam64Base <= 0xFFFFFFFFull) return static_cast<uint32_t>(v - kSteam64Base);
            }
            if (n.kind == 'q') ++i;  // a key and its value: step over the value
        }
    }
    return 0;
}

uint32_t steam_last_login(const fs::path& steam_root) {
    std::ifstream f(steam_root / "config" / "loginusers.vdf", std::ios::binary);
    if (!f) return 0;
    std::stringstream ss;
    ss << f.rdbuf();
    return last_login_from_vdf(ss.str());
}

SaveDirChoice choose_save_dir(const fs::path& steam_root, uint32_t active_id) {
    SaveDirChoice c;
    std::error_code ec;
    if (active_id != 0) {
        const fs::path d = save_dir_of(steam_root, active_id);
        if (fs::is_directory(d, ec)) {
            c.dir = d;
            c.account = active_id;
            c.how = DirHow::SteamRunning;
            c.why = "Steam is signed in as account " + std::to_string(active_id) + ", and RE7 loads saves from that account";
            return c;
        }
        c.why = "Steam is signed in as account " + std::to_string(active_id) +
                " but that account has no RE7 save folder yet: start RE7 once and get to the main menu, then detect again (watching another account's folder would be wrong)";
        return c;
    }
    const uint32_t last = steam_last_login(steam_root);
    if (last != 0) {
        const fs::path d = save_dir_of(steam_root, last);
        if (fs::is_directory(d, ec)) {
            c.dir = d;
            c.account = last;
            c.how = DirHow::LastLogin;
            c.why = "Steam is not running; account " + std::to_string(last) + " was the last one signed in (loginusers.vdf)";
            return c;
        }
    }
    const auto dirs = find_save_dirs(steam_root);
    if (!dirs.empty()) {
        c.dir = dirs.front();
        c.account = account_of_save_dir(c.dir);
        c.how = DirHow::NewestFiles;
        c.why = "Steam is not running and the last sign-in is not known: the folder with the newest save was taken"
                " (with two Steam accounts check that it is the right one)";
        return c;
    }
    c.why = "no RE7 save folder was found under " + (steam_root / "userdata").u8string();
    return c;
}

DirCorrection correct_save_dir(const fs::path& current, const SaveDirChoice& chosen) {
    DirCorrection r;
    if (chosen.how != DirHow::SteamRunning && chosen.how != DirHow::LastLogin) return r;
    if (chosen.dir.empty() || chosen.account == 0) return r;
    if (current.empty()) {
        r.change = true;
        r.why = "no save folder was set; using account " + std::to_string(chosen.account) + "'s";
        return r;
    }
    const uint32_t cur = account_of_save_dir(current);
    if (cur == 0 || cur == chosen.account) return r;  // not a userdata folder (typed on purpose), or already the right one
    r.change = true;
    r.why = "the folder in the box belongs to Steam account " + std::to_string(cur) + " but " + chosen.why +
            ", so the box was changed to account " + std::to_string(chosen.account) + "'s folder";
    return r;
}

// ---- manifest ------------------------------------------------------------------------------

namespace {
std::string esc(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        o += c;
    }
    return o;
}
}  // namespace

void CoopManifest::load() {
    entries_.clear();
    std::ifstream f(path_, std::ios::binary);
    if (!f) return;
    std::stringstream ss;
    ss << f.rdbuf();
    mini::Value root;
    if (!mini::parse(ss.str(), root) || root.type != mini::Value::Type::Obj) return;
    const mini::Value* list = root.get("entries");
    if (!list || list->type != mini::Value::Type::Arr) return;
    for (const auto& e : list->arr) {
        if (e.type != mini::Value::Type::Obj) continue;
        const auto *slot = e.get("slot"), *label = e.get("label"), *from = e.get("from"), *when = e.get("when"),
                   *crc = e.get("crc"), *size = e.get("size"), *partner = e.get("partner"), *role = e.get("role"),
                   *from_slot = e.get("from_slot"), *why = e.get("why"), *p_acct = e.get("partner_account");
        if (!slot || !label || !crc) continue;
        CoopEntry c;
        c.slot = static_cast<int>(slot->num);
        c.label = label->str;
        c.from = from ? from->str : "";
        c.partner = partner && !partner->str.empty() ? partner->str : c.from;
        c.role = role && role->str == "sent" ? "sent" : "received";
        c.when = when ? when->str : "";
        c.crc = static_cast<uint32_t>(crc->num);
        c.size = size ? static_cast<uint64_t>(size->num) : 0;
        c.from_slot = from_slot ? static_cast<int>(from_slot->num) : 0;
        c.why = why ? why->str : "";
        c.partner_account = p_acct && p_acct->num >= 1 && p_acct->num <= 4294967295.0 ? static_cast<uint32_t>(p_acct->num) : 0;
        entries_.push_back(std::move(c));
    }
}

bool CoopManifest::save(const std::string& last_event, bool enabled, const std::vector<int>& occupied, const std::string& dir) const {
    std::string s = std::string("{\"enabled\":") + (enabled ? "true" : "false") + ",\"last\":\"" + esc(last_event) +
                    "\",\"entries\":[";
    for (size_t i = 0; i < entries_.size(); ++i) {
        const auto& e = entries_[i];
        if (i) s += ",";
        const std::string who = e.partner.empty() ? e.from : e.partner;
        s += "{\"slot\":" + std::to_string(e.slot) + ",\"label\":\"" + esc(e.label) + "\",\"from\":\"" + esc(e.from) +
             "\",\"partner\":\"" + esc(who) + "\",\"role\":\"" + e.role + "\",\"tag\":\"" + esc(tag_for(e)) +
             "\",\"when\":\"" + esc(e.when) + "\",\"crc\":" + std::to_string(e.crc) + ",\"size\":" + std::to_string(e.size) +
             ",\"from_slot\":" + std::to_string(e.from_slot) + ",\"partner_account\":" + std::to_string(e.partner_account) +
             ",\"why\":\"" + esc(e.why) + "\"}";
    }
    s += "],\"occupied\":[";
    for (size_t i = 0; i < occupied.size(); ++i) s += (i ? "," : "") + std::to_string(occupied[i]);
    s += "],\"dir\":\"" + esc(dir) + "\",\"account\":" + std::to_string(mine_) + ",\"partner_account\":" + std::to_string(partner_) + "}\n";
    std::error_code ec;
    fs::create_directories(path_.parent_path(), ec);
    fs::path tmp = path_;
    tmp += ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f << s;
    }
    fs::rename(tmp, path_, ec);
    return !ec;
}

std::string CoopManifest::tag_for(const CoopEntry& e) {
    const std::string who = e.partner.empty() ? (e.from.empty() ? std::string("Player") : e.from) : e.partner;
    return e.role == "sent" ? "[CO-OP: sent to " + who + "]" : "[CO-OP: " + who + "]";
}

bool CoopManifest::is_coop_slot(int slot) const {
    return std::any_of(entries_.begin(), entries_.end(), [&](const CoopEntry& e) { return e.slot == slot; });
}

bool CoopManifest::is_received_slot(int slot) const {
    return std::any_of(entries_.begin(), entries_.end(), [&](const CoopEntry& e) { return e.slot == slot && e.role != "sent"; });
}

bool CoopManifest::remove_slot(int slot) {
    const auto it = std::remove_if(entries_.begin(), entries_.end(), [&](const CoopEntry& e) { return e.slot == slot; });
    const bool any = it != entries_.end();
    entries_.erase(it, entries_.end());
    return any;
}

static bool read_file_bytes(const fs::path& p, std::vector<uint8_t>& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

int CoopManifest::prune(const fs::path& save_dir, bool check_content) {
    int dropped = 0;
    for (size_t i = 0; i < entries_.size();) {
        const CoopEntry& e = entries_[i];
        const fs::path file = save_dir / slot_filename(e.slot);
        std::error_code ec;
        bool keep = fs::exists(file, ec);
        if (keep && check_content && e.size != 0) keep = fs::file_size(file, ec) == e.size && !ec;
        if (keep && check_content && e.crc != 0) {
            std::vector<uint8_t> data;
            keep = read_file_bytes(file, data) && crc32(data.data(), data.size()) == e.crc;
        }
        if (keep) {
            ++i;
        } else {
            entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
            ++dropped;
        }
    }
    return dropped;
}

int CoopManifest::verify_received(const fs::path& save_dir, std::map<int, fs::file_time_type>& seen, std::vector<int>& dropped) {
    int n = 0;
    for (size_t i = 0; i < entries_.size();) {
        const CoopEntry& e = entries_[i];
        bool keep = true;
        if (e.role != "sent") {
            const fs::path file = save_dir / slot_filename(e.slot);
            std::error_code ec;
            const auto mtime = fs::last_write_time(file, ec);
            if (!ec) {
                const auto it = seen.find(e.slot);
                if (it == seen.end() || it->second != mtime) {  // new to us, or written since the last look
                    seen[e.slot] = mtime;
                    std::vector<uint8_t> data;
                    keep = read_file_bytes(file, data) && crc32(data.data(), data.size()) == e.crc;
                }
            }  // (a file that is gone is prune()'s business)
        }
        if (keep) {
            ++i;
        } else {
            dropped.push_back(e.slot);
            entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
            ++n;
        }
    }
    return n;
}

std::vector<int> list_occupied(const fs::path& save_dir) {
    std::vector<int> out;
    std::error_code ec;
    for (const auto& f : fs::directory_iterator(save_dir, ec)) {
        const int slot = parse_slot(f.path().filename().u8string());
        if (slot >= 1) out.push_back(slot);
    }
    std::sort(out.begin(), out.end());
    return out;
}

bool CoopManifest::has_crc(uint32_t crc) const {
    return std::any_of(entries_.begin(), entries_.end(), [&](const CoopEntry& e) { return e.crc == crc; });
}

void CoopManifest::upsert(const CoopEntry& e) {
    for (auto& x : entries_) {
        if (x.slot == e.slot) {
            x = e;
            return;
        }
    }
    entries_.push_back(e);
}

SlotPick pick_slot_ex(const fs::path& save_dir, int preferred, const CoopManifest& manifest) {
    SlotPick out;
    auto in_range = [&](int slot) { return slot >= 1 && slot <= kMaxSlot; };  // slot 0 is not a slot: it is the Autosave
    auto exists = [&](int slot) {
        std::error_code ec;
        return fs::exists(save_dir / slot_filename(slot), ec);
    };
    // 1. The same save arriving again (the sender saved again in the same slot): it replaces the copy we installed earlier, so
    //    repeated sends do not pile up. Only a copy WE installed may be replaced, never a save of your own.
    if (preferred >= 1) {
        for (const auto& e : manifest.entries()) {
            if (e.role == "received" && e.from_slot == preferred && in_range(e.slot) && manifest.is_received_slot(e.slot)) {
                out.slot = e.slot;
                out.how = SlotChoice::SameSave;
                return out;
            }
        }
    }
    // 2. A new co-op save goes one past the highest save in the folder (9.22). It used to take the sender's own slot number, which
    //    could be a number your next save of your own would use. The Load screen lists the slots in order, so it appears last.
    const std::vector<int> occ = list_occupied(save_dir);
    const int top = occ.empty() ? 0 : occ.back();
    if (in_range(top + 1) && !exists(top + 1)) {
        out.slot = top + 1;
        out.how = SlotChoice::OnePastHighest;
        return out;
    }
    // 3. Nothing free past the highest save (or that would be past the 15th): the lowest slot that is free.
    for (int s = 1; s <= kMaxSlot; ++s) {
        if (!exists(s)) {
            out.slot = s;
            out.how = SlotChoice::LowestFree;
            return out;
        }
    }
    // 4. (9.32) All kMaxSlot slots hold a file: the OLDEST copy we installed is replaced (a copy can be sent again by the other player; a
    //    save of your own can not). Before 9.32 this took the lowest numbered copy, and a copy was even replaced while slots were free.
    const CoopEntry* oldest = nullptr;
    for (const auto& e : manifest.entries()) {
        if (!in_range(e.slot) || !manifest.is_received_slot(e.slot)) continue;  // (every slot 1..kMaxSlot holds a file here: step 3 found none free)
        if (!oldest || e.when < oldest->when || (e.when == oldest->when && e.slot < oldest->slot)) oldest = &e;
    }
    if (oldest) {
        out.slot = oldest->slot;
        out.how = SlotChoice::ReplacedOldestCopy;
        out.replaced_when = oldest->when;
        out.replaced_from = oldest->from;
    }
    return out;
}

int pick_slot(const fs::path& save_dir, int preferred, const CoopManifest& manifest) {
    return pick_slot_ex(save_dir, preferred, manifest).slot;
}

// ---- watcher -------------------------------------------------------------------------------

void SaveWatcher::baseline() {
    files_.clear();
    std::error_code ec;
    for (const auto& f : fs::directory_iterator(dir_, ec)) {
        if (parse_slot(f.path().filename().u8string()) < 0) continue;
        std::error_code e2;
        Info i;
        i.mtime = fs::last_write_time(f.path(), e2);
        i.size = fs::file_size(f.path(), e2);
        i.reported = true;
        files_[f.path().filename().u8string()] = i;
    }
}

void SaveWatcher::ignore_current(const fs::path& file) {
    std::error_code ec;
    Info i;
    i.mtime = fs::last_write_time(file, ec);
    i.size = fs::file_size(file, ec);
    i.reported = true;
    files_[file.filename().u8string()] = i;
}

std::vector<fs::path> SaveWatcher::poll(Clock::time_point now) {
    std::vector<fs::path> out;
    std::error_code ec;
    for (const auto& f : fs::directory_iterator(dir_, ec)) {
        const std::string name = f.path().filename().u8string();
        if (parse_slot(name) < 0) continue;
        std::error_code e2;
        const auto mtime = fs::last_write_time(f.path(), e2);
        const auto size = fs::file_size(f.path(), e2);
        if (e2) continue;
        auto it = files_.find(name);
        if (it == files_.end()) {
            Info i;
            i.mtime = mtime;
            i.size = size;
            i.changed_at = now;
            files_[name] = i;
            continue;
        }
        Info& i = it->second;
        if (i.mtime != mtime || i.size != size) {  // being written (or rewritten)
            i.mtime = mtime;
            i.size = size;
            i.changed_at = now;
            i.reported = false;
        } else if (!i.reported && now - i.changed_at >= std::chrono::milliseconds(stable_ms_)) {
            i.reported = true;
            out.push_back(f.path());
        }
    }
    return out;
}

bool write_save_file(const fs::path& save_dir, int slot, const std::vector<uint8_t>& data) {
    std::error_code ec;
    const fs::path final_path = save_dir / slot_filename(slot);
    const fs::path tmp = save_dir / (slot_filename(slot) + ".re7mp_tmp");
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
        if (!f) return false;
    }
    fs::rename(tmp, final_path, ec);
    return !ec;
}

}  // namespace re7mp
