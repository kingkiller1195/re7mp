#pragma once
// Co-op save sharing: watch the save folder, send a finished save to the other player, and install a
// received save into a free slot without ever touching a single-player save.
// Portable (std::filesystem only) so it can be tested anywhere.
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace re7mp {

// RE7 (PC, Steam) keeps its saves in <steam>/userdata/<id>/418370/remote/win64_save:
//   data000.bin        the Autosave (the Load screen's "Autosave" row; never shared, never overwritten)
//   dataNNNSlot.bin    manual save N, the number the Load screen prints on the row (data001Slot.bin ... data011Slot.bin)
//   data00-1.bin ...   system / settings files (ignored)
// (Found by looking at a real save folder: this tool used to assume dataNNN.bin and so only ever saw the Autosave.)
// "data012Slot.bin" -> 12; anything else (including the Autosave and the system files) -> -1.
int parse_slot(const std::string& filename);
std::string slot_filename(int slot);  // 12 -> "data012Slot.bin"
constexpr int kMaxSlot = 99;          // manual slots 1..kMaxSlot

// Every <steam>/userdata/<id>/418370/remote/win64_save that exists, most recently used first.
std::vector<std::filesystem::path> find_save_dirs(const std::filesystem::path& steam_root);

struct CoopEntry {
    int slot = 0;
    std::string label;  // e.g. "CO-OP Alice 2026-11-06 21:04": what makes it recognizable as a co-op save
    std::string from;   // who saved it
    std::string partner;  // the other player this save was shared with (the last one); empty in old manifests = `from`
    std::string role = "received";  // "received": we installed it. "sent": our own save, sent to `partner`
    std::string when;   // when we received / sent it
    uint32_t crc = 0;
    uint64_t size = 0;
    int from_slot = 0;  // received: the slot the save had on the sender's PC (0 = not known)
    std::string why;    // received: in words, why it went into `slot` (shown in the panel: "your slot 10 holds a save of yours, so ...")
};

// The list of saves this tool installed (so they can be told apart from single-player saves), kept in
// <data dir>/re7mp_coop_saves.json. The Lua panel reads the same file.
class CoopManifest {
public:
    explicit CoopManifest(std::filesystem::path path) : path_(std::move(path)) {}
    void load();
    // `occupied` (slots that hold a save file) is published too: the Lua script uses it to tell which row of the Load list is which slot.
    // `dir` (the folder being watched) is published too, so the panel can say which Steam account's saves these are.
    bool save(const std::string& last_event, bool enabled, const std::vector<int>& occupied = {}, const std::string& dir = "") const;
    bool is_coop_slot(int slot) const;      // received OR sent: the slot belongs to a co-op session
    bool is_received_slot(int slot) const;  // a copy we installed: the only kind an incoming save may replace
    // The label the Load screen shows for an entry: "[CO-OP: Bob]" for a save received from Bob, "[CO-OP: sent to Bob]" for
    // one of your own that was sent to him (so his name is never written on a save that is not his).
    static std::string tag_for(const CoopEntry& e);
    bool has_crc(uint32_t crc) const;
    void upsert(const CoopEntry& e);  // replaces the entry for the same slot
    bool remove_slot(int slot);       // the slot was overwritten privately: it is a single-player save again
    // Drops entries whose save file is gone. With check_content also those whose file has a different size or checksum
    // (the slot was reused while this tool was not running). Returns how many were dropped.
    int prune(const std::filesystem::path& save_dir, bool check_content);
    // Received copies only: if the file's time changed since `seen` last had it, its checksum is compared with the one we
    // installed; a copy that is no longer what we wrote (the game, Steam Cloud, the player...) is dropped from the list and its slot
    // returned in `dropped`. `seen` remembers the file times between calls. Returns how many were dropped.
    int verify_received(const std::filesystem::path& save_dir, std::map<int, std::filesystem::file_time_type>& seen,
                        std::vector<int>& dropped);
    const std::vector<CoopEntry>& entries() const { return entries_; }

private:
    std::filesystem::path path_;
    std::vector<CoopEntry> entries_;
};

// Manual slot numbers that currently hold a save file, ascending (the Autosave is not a slot).
std::vector<int> list_occupied(const std::filesystem::path& save_dir);

// Where to put a received save: the sender's slot if it is free (or already holds a co-op save from us),
// otherwise the lowest free slot. Returns -1 if every slot 1..kMaxSlot holds a single-player save.
int pick_slot(const std::filesystem::path& save_dir, int preferred, const CoopManifest& manifest);

// Notices when a save file has been written and left alone for a moment (so we don't send half a file).
class SaveWatcher {
public:
    using Clock = std::chrono::steady_clock;
    SaveWatcher(std::filesystem::path dir, int stable_ms) : dir_(std::move(dir)), stable_ms_(stable_ms) {}

    void baseline();  // what exists now counts as already seen; nothing is reported for it
    std::vector<std::filesystem::path> poll(Clock::time_point now);  // each change is reported once
    void ignore_current(const std::filesystem::path& file);          // after we wrote it ourselves

private:
    struct Info {
        std::filesystem::file_time_type mtime{};
        std::uintmax_t size = 0;
        Clock::time_point changed_at{};
        bool reported = false;
    };
    std::filesystem::path dir_;
    int stable_ms_;
    std::map<std::string, Info> files_;
};

// Writes `data` to <save_dir>/dataNNNSlot.bin via a temp file + rename. Returns false on failure.
bool write_save_file(const std::filesystem::path& save_dir, int slot, const std::vector<uint8_t>& data);

}  // namespace re7mp
