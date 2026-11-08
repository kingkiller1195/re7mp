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
                   *from_slot = e.get("from_slot"), *why = e.get("why");
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
             ",\"from_slot\":" + std::to_string(e.from_slot) + ",\"why\":\"" + esc(e.why) + "\"}";
    }
    s += "],\"occupied\":[";
    for (size_t i = 0; i < occupied.size(); ++i) s += (i ? "," : "") + std::to_string(occupied[i]);
    s += "],\"dir\":\"" + esc(dir) + "\"}\n";
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

int pick_slot(const fs::path& save_dir, int preferred, const CoopManifest& manifest) {
    auto usable = [&](int slot) {
        if (slot < 1 || slot > kMaxSlot) return false;  // slot 0 is not a slot: it is the Autosave
        std::error_code ec;
        const bool exists = fs::exists(save_dir / slot_filename(slot), ec);
        return !exists || manifest.is_received_slot(slot);  // never a single-player save, nor one you made yourself
    };
    if (usable(preferred)) return preferred;
    for (int s = 1; s <= kMaxSlot; ++s) {
        if (usable(s)) return s;
    }
    return -1;
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
