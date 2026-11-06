#pragma once
// File bridge between the REFramework Lua script and the engine. All files live in
// <RE7 folder>/reframework/data and are plain JSON.
//
//   re7mp_out.json      Lua -> engine   local pose+flags  {seq,x,y,z,qx,qy,qz,qw,flags}
//   re7mp_in.json       engine -> Lua   remote pose+name  {seq,x,y,z,qx,qy,qz,qw,flags,recv_count,name,transport}
//   re7mp_evt_out.json  Lua -> engine   event to send     {id,type,arg}
//   re7mp_evt_in.json   engine -> Lua   event received    {session,id,type,arg}
//   re7mp_msg_out.json  Lua -> engine   messages to send   {msgs:[{id,k,p}, ...]}   (ring of the last ~32)
//   re7mp_msg_in.json   engine -> Lua   messages received  {epoch,msgs:[{n,id,k,p}, ...]}  (ring of the last ~64)
//
// The Lua side writes in place (the reader tolerates half-written files); the engine side
// writes a temp file and renames it so Lua never sees a partial file.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>

#include "json_mini.hpp"
#include "packet.hpp"

namespace re7mp {

struct LocalPose {
    uint32_t lua_seq = 0;
    float x = 0, y = 0, z = 0;
    float qx = 0, qy = 0, qz = 0, qw = 1;
    uint16_t flags = 0;
};

struct RemotePose {
    uint32_t seq = 0;
    float x = 0, y = 0, z = 0;
    float qx = 0, qy = 0, qz = 0, qw = 1;
    uint16_t flags = 0;
};

struct LocalEvent {
    uint64_t lua_id = 0;
    uint8_t type = 0;
    uint8_t arg = 0;
};

struct LocalMessage {  // Lua -> engine
    uint64_t lua_id = 0;
    uint16_t kind = 0;
    std::string payload;
};

struct InMessage {  // engine -> Lua
    uint64_t n = 0;  // delivery number in this engine run; Lua processes each n once
    uint32_t id = 0;
    uint16_t kind = 0;
    std::string payload;
};

class FileBridge {
public:
    explicit FileBridge(std::filesystem::path data_dir)
        : dir_(std::move(data_dir)),
          pose_out_{dir_ / "re7mp_out.json"},
          evt_out_{dir_ / "re7mp_evt_out.json"},
          msg_out_{dir_ / "re7mp_msg_out.json"} {}

    // Deletes leftovers from a previous run so stale positions/events aren't replayed.
    void clear_stale() {
        std::error_code ec;
        for (const char* f : {"re7mp_out.json", "re7mp_in.json", "re7mp_evt_out.json", "re7mp_evt_in.json",
                              "re7mp_in.tmp", "re7mp_evt_in.tmp", "re7mp_msg_out.json", "re7mp_msg_in.json",
                              "re7mp_msg_in.tmp"}) {
            std::filesystem::remove(dir_ / f, ec);
        }
    }

    // True when the game wrote a new, valid pose since the last call.
    bool poll_pose(LocalPose& out) {
        std::string text;
        if (!read_changed(pose_out_, text)) return false;
        double seq, x, y, z;
        if (!find_number(text, "seq", seq) || !find_number(text, "x", x) || !find_number(text, "y", y) ||
            !find_number(text, "z", z)) {
            return false;  // probably caught Lua mid-write; retried next poll
        }
        accept(pose_out_);
        const auto s = static_cast<uint32_t>(seq);
        if (have_pose_seq_ && s == last_pose_seq_) return false;
        have_pose_seq_ = true;
        last_pose_seq_ = s;
        out.lua_seq = s;
        out.x = static_cast<float>(x);
        out.y = static_cast<float>(y);
        out.z = static_cast<float>(z);
        double qx, qy, qz, qw;  // rotation is optional so older scripts still work
        if (find_number(text, "qx", qx) && find_number(text, "qy", qy) && find_number(text, "qz", qz) &&
            find_number(text, "qw", qw)) {
            out.qx = static_cast<float>(qx);
            out.qy = static_cast<float>(qy);
            out.qz = static_cast<float>(qz);
            out.qw = static_cast<float>(qw);
        } else {
            out.qx = out.qy = out.qz = 0;
            out.qw = 1;
        }
        double fl;  // ready-check flags are optional too
        out.flags = (find_number(text, "flags", fl) && fl >= 0 && fl < 65536) ? static_cast<uint16_t>(fl) : 0;
        return true;
    }

    // True when the game asked to send a new event.
    bool poll_event(LocalEvent& out) {
        std::string text;
        if (!read_changed(evt_out_, text)) return false;
        double id, type, arg;
        if (!find_number(text, "id", id) || !find_number(text, "type", type) || !find_number(text, "arg", arg)) {
            return false;
        }
        accept(evt_out_);
        if (id < 0 || type < 0 || type > 255 || arg < 0 || arg > 255) return false;
        const auto uid = static_cast<uint64_t>(id);
        if (have_evt_id_ && uid == last_evt_id_) return false;
        have_evt_id_ = true;
        last_evt_id_ = uid;
        out.lua_id = uid;
        out.type = static_cast<uint8_t>(type);
        out.arg = static_cast<uint8_t>(arg);
        return true;
    }

    // Messages the game wants to send, oldest first. Returns true if there are new ones.
    bool poll_messages(std::vector<LocalMessage>& out) {
        out.clear();
        std::string text;
        if (!read_changed(msg_out_, text)) return false;
        mini::Value root;
        if (!mini::parse(text, root) || root.type != mini::Value::Type::Obj) return false;  // half-written: retry
        accept(msg_out_);
        const mini::Value* msgs = root.get("msgs");
        if (!msgs || msgs->type != mini::Value::Type::Arr) return false;
        uint64_t max_id = last_msg_id_;
        for (const auto& m : msgs->arr) {
            if (m.type != mini::Value::Type::Obj) continue;
            const mini::Value* id = m.get("id");
            const mini::Value* k = m.get("k");
            const mini::Value* p = m.get("p");
            if (!id || id->type != mini::Value::Type::Num || id->num < 1) continue;
            const auto uid = static_cast<uint64_t>(id->num);
            if (uid <= last_msg_id_) continue;  // already handled
            if (uid > max_id) max_id = uid;
            if (!k || k->type != mini::Value::Type::Num || k->num < 0 || k->num > 65535) continue;
            if (!p || p->type != mini::Value::Type::Str || !valid_payload(p->str)) continue;
            LocalMessage lm;
            lm.lua_id = uid;
            lm.kind = static_cast<uint16_t>(k->num);
            lm.payload = p->str;
            out.push_back(std::move(lm));
        }
        last_msg_id_ = max_id;
        std::sort(out.begin(), out.end(), [](const LocalMessage& a, const LocalMessage& b) { return a.lua_id < b.lua_id; });
        return !out.empty();
    }

    bool publish_messages(uint32_t epoch, const std::vector<InMessage>& msgs) {
        std::string s = "{\"epoch\":" + std::to_string(epoch) + ",\"msgs\":[";
        for (size_t i = 0; i < msgs.size(); ++i) {
            if (i) s += ",";
            s += "{\"n\":" + std::to_string(msgs[i].n) + ",\"id\":" + std::to_string(msgs[i].id) +
                 ",\"k\":" + std::to_string(msgs[i].kind) + ",\"p\":\"" + json_escape(msgs[i].payload) + "\"}";
        }
        s += "]}\n";
        return write_atomic("re7mp_msg_in.tmp", "re7mp_msg_in.json", s.c_str());
    }

    bool publish_remote(const RemotePose& p, uint64_t recv_count, const std::string& name,
                        const char* transport = "udp") {
        char buf[640];
        std::snprintf(buf, sizeof(buf),
                      "{\"seq\":%u,\"x\":%.4f,\"y\":%.4f,\"z\":%.4f,\"qx\":%.5f,\"qy\":%.5f,\"qz\":%.5f,\"qw\":%.5f,"
                      "\"flags\":%u,\"recv_count\":%llu,\"name\":\"%s\",\"transport\":\"%s\"}\n",
                      p.seq, p.x, p.y, p.z, p.qx, p.qy, p.qz, p.qw, static_cast<unsigned>(p.flags),
                      static_cast<unsigned long long>(recv_count),
                      json_escape(name).c_str(), transport);
        return write_atomic("re7mp_in.tmp", "re7mp_in.json", buf);
    }

    bool publish_event(uint32_t session, uint32_t id, uint8_t type, uint8_t arg) {
        char buf[160];
        std::snprintf(buf, sizeof(buf), "{\"session\":%u,\"id\":%u,\"type\":%u,\"arg\":%u}\n", session, id,
                      static_cast<unsigned>(type), static_cast<unsigned>(arg));
        return write_atomic("re7mp_evt_in.tmp", "re7mp_evt_in.json", buf);
    }

private:
    struct Watch {
        std::filesystem::path path;
        std::filesystem::file_time_type mtime{}, seen_mtime{};
        std::uintmax_t size = 0, seen_size = 0;
        bool have = false;
    };

    // Reads the file if it changed since the last accepted read.
    static bool read_changed(Watch& w, std::string& text) {
        std::error_code ec;
        const auto mtime = std::filesystem::last_write_time(w.path, ec);
        if (ec) return false;
        const auto size = std::filesystem::file_size(w.path, ec);
        if (ec) return false;
        if (w.have && mtime == w.mtime && size == w.size) return false;
        std::ifstream f(w.path, std::ios::binary);
        if (!f) return false;
        std::stringstream ss;
        ss << f.rdbuf();
        text = ss.str();
        w.seen_mtime = mtime;
        w.seen_size = size;
        return true;
    }
    static void accept(Watch& w) {
        w.mtime = w.seen_mtime;
        w.size = w.seen_size;
        w.have = true;
    }

    static bool find_number(const std::string& text, const char* key, double& out) {
        const std::string pattern =
            std::string("\"") + key + "\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)";
        std::smatch m;
        if (!std::regex_search(text, m, std::regex(pattern))) return false;
        try {
            out = std::stod(m[1].str());
        } catch (...) {
            return false;
        }
        return true;
    }

    static std::string json_escape(const std::string& s) {
        std::string o;
        for (char c : s) {
            if (c == '"' || c == '\\') o += '\\';
            o += c;
        }
        return o;
    }

    bool write_atomic(const char* tmp_name, const char* final_name, const char* text) {
        const auto tmp = dir_ / tmp_name;
        {
            std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
            if (!f) return false;
            f << text;
        }
        std::error_code ec;
        std::filesystem::rename(tmp, dir_ / final_name, ec);  // fails if Lua has it open; next call retries
        return !ec;
    }

    std::filesystem::path dir_;
    Watch pose_out_, evt_out_, msg_out_;
    bool have_pose_seq_ = false, have_evt_id_ = false;
    uint32_t last_pose_seq_ = 0;
    uint64_t last_evt_id_ = 0;
    uint64_t last_msg_id_ = 0;
};

}  // namespace re7mp
