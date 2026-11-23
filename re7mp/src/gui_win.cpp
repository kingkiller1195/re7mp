// re7mp.exe: the GUI. Finds your RE7 folder, installs the embedded Lua script, runs the
// networking engine, and shows live status. Win32 only, no third-party dependencies.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <deque>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "engine.hpp"
#include "character.hpp"
#include "story_sync.hpp"
#include "enemy_sync.hpp"  // 10.19: the "Sync enemies and the Molded" box
#include "alpha_channel.hpp"  // (10.24) the alpha channel: where it is, what its windows say, the file the script reads
#include "future_ui.hpp"      // (10.25) the two "coming later" boxes (BioRand 7, VR) and the size of the bigger window
#include "game_locator.hpp"
#include "http_win.hpp"
#include "installer.hpp"
#include "packet.hpp"
#include "save_sync.hpp"
#include "steam_dyn.hpp"
#include "updater.hpp"
#include "version.hpp"

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
// Visual styles (modern-looking buttons) need the common controls v6 manifest.
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

namespace fs = std::filesystem;
using namespace re7mp;

namespace {

constexpr int kLuaResourceId = 101;       // must match app.rc
constexpr int kDefaultsResourceId = 102;  // the built-in clips and settings (re7mp/defaults.json), see app.rc
constexpr int kModelsResourceId = 103;    // (10.13) the full character models (a zip, made by tools/pack_models.py), see app.rc
constexpr int kIconResourceId = 1;        // (10.13) the program's icon, see app.rc
constexpr UINT_PTR kTimerId = 1;

enum : int {
    IDC_GAMEDIR = 1001,
    IDC_BROWSE = 1002,
    IDC_DETECT = 1003,
    IDC_MODE_LOOP = 1004,  // IDC_MODE_LOOP and IDC_MODE_NET must stay consecutive (radio group)
    IDC_MODE_NET = 1005,
    IDC_PORT = 1006,
    IDC_PEER = 1007,
    IDC_START = 1008,
    IDC_INSTALL = 1009,
    IDC_LBL_PEER = 1010,
    IDC_ST_HOOK = 1011,
    IDC_ST_PEER = 1012,
    IDC_ST_LOCAL = 1013,
    IDC_ST_REMOTE = 1014,
    IDC_ST_PKTS = 1015,
    IDC_LOG = 1016,
    IDC_NAME = 1017,
    IDC_TR_HOST = 1019,  // IDC_TR_HOST, IDC_TR_JOIN must stay consecutive (radio group); 1018 was the UDP radio, removed in 9.7
    IDC_TR_JOIN = 1020,
    IDC_TR_STEAM = 1021,  // (10.10) "Steam invites": the third of the group (HOST, JOIN, STEAM are consecutive)
    IDC_BOT_TELE = 1023,
    IDC_OPEN_DATA = 1024,
    IDC_SAVEDIR = 1025,
    IDC_SAVE_DETECT = 1026,
    IDC_SAVE_SHARE = 1027,
    IDC_ST_SAVE = 1028,
    IDC_UPD_ST = 1029,
    IDC_UPD_BTN = 1030,
    IDC_UPD_AUTO = 1033,
    IDC_PLAYAS = 1034,  // 9.31: the "Play as" drop-down
    IDC_STORY = 1035,   // 9.33: the "Sync story cutscenes (experimental)" box
    // (10.26) IDs 1022, 1036 and 1037 were the friend's follows / stays put / beside you radios: gone, the script's F5 key picks follow or stay now
    IDC_STEAM_ID = 1038,    // (10.10) Steam invites: the friend's Steam ID or invite line
    IDC_STEAM_PICK = 1039,  // ... "Pick a friend..."
    IDC_STEAM_COPY = 1040,  // ... "Copy my invite"
    IDC_STEAM_LBL = 1041,
    IDC_CONN_NOTE = 1042,   // the note right of the Connection radios (it says something else for Steam)
    IDC_PORT_LBL = 1043,
    IDC_ENEMY = 1044,       // 10.19: the "Sync enemies and the Molded" box (ticked unless the ini says otherwise)
    IDC_ALPHA_BTN = 1045,   // (10.24) "Join the alpha..." / "Leave the alpha..."
    IDC_FUT_BIORAND = 1046,  // (10.25) "BioRand 7 randomizer" in the top strip: NOT IMPLEMENTED, only saved (re7mp.ini, biorand=)
    IDC_FUT_VR = 1047,       // (10.25) "VR support" in the top strip: NOT IMPLEMENTED, only saved (re7mp.ini, vr=)
};

struct App {
    HINSTANCE inst = nullptr;
    HWND hwnd = nullptr;
    HWND gamedir = nullptr, peer = nullptr, port = nullptr, start = nullptr, log = nullptr, name = nullptr;
    HWND savedir = nullptr, st_save = nullptr;
    HWND upd_st = nullptr;
    HWND lbl_peer = nullptr;
    HWND lbl_port = nullptr, steam_lbl = nullptr, steam_id = nullptr, steam_pick = nullptr, steam_copy = nullptr, conn_note = nullptr;  // (10.10)
    HWND playas = nullptr;  // 9.31: character drop-down
    HWND playas_label = nullptr, playas_note = nullptr;  // 10.5: its two texts change with the mode
    bool playas_friend = false;                          // 10.5: true while the drop-down is the friend's look (Ethan's friend mode)
    std::string play_as_own = "auto", friend_as = "auto";  // 10.5: what each mode last had picked (the shown one is read from the drop-down)
    HWND st_hook = nullptr, st_peer = nullptr, st_local = nullptr, st_remote = nullptr, st_pkts = nullptr;
    HFONT font = nullptr;
    int dpi = 96;
    Engine engine;
    bool ui_running = false;
    Mode running_mode = Mode::Loopback;
    std::wstring shown[12];  // last text shown in each status label / button, to avoid flicker
};
App g;

int S(int v) { return MulDiv(v, g.dpi, 96); }

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
    return w;
}

std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), &s[0], n, nullptr, nullptr);
    return s;
}

std::wstring get_text(HWND h) {
    int n = GetWindowTextLengthW(h);
    std::wstring w(static_cast<size_t>(n) + 1, L'\0');
    GetWindowTextW(h, &w[0], n + 1);
    w.resize(static_cast<size_t>(n));
    return w;
}

fs::path exe_dir() {
    wchar_t buf[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
    return fs::path(std::wstring(buf, n)).parent_path();
}

void log_line(const std::string& s) {
    std::wstring w = widen(s) + L"\r\n";
    int len = GetWindowTextLengthW(g.log);
    if (len > 60000) {
        SetWindowTextW(g.log, L"");
        len = 0;
    }
    SendMessageW(g.log, EM_SETSEL, static_cast<WPARAM>(len), static_cast<LPARAM>(len));
    SendMessageW(g.log, EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(w.c_str()));
}

void set_status(int idx, HWND h, const std::wstring& text) {
    if (g.shown[idx] == text) return;
    g.shown[idx] = text;
    SetWindowTextW(h, text.c_str());
}

// ---------------------------------------------------------------- settings (re7mp.ini next to the exe)

std::wstring ini_path() { return (exe_dir() / L"re7mp.ini").wstring(); }

bool network_mode_selected() { return IsDlgButtonChecked(g.hwnd, IDC_MODE_NET) == BST_CHECKED; }

bool steam_selected() { return IsDlgButtonChecked(g.hwnd, IDC_TR_STEAM) == BST_CHECKED; }

// The TCP choice. (Steam is told apart by steam_selected(): which of the two Steam roles it is follows from the two Steam IDs, see do_start.)
Transport selected_transport() {
    if (IsDlgButtonChecked(g.hwnd, IDC_TR_HOST) == BST_CHECKED) return Transport::TcpHost;
    if (IsDlgButtonChecked(g.hwnd, IDC_TR_JOIN) == BST_CHECKED) return Transport::TcpJoin;
    return Transport::TcpHost;
}

// (10.26) selected_bot_mode() and check_bot_radio() are gone with the radios: the friend starts out following you and the script's F5 key (in the game)
// switches it between following and staying put (kind 11 "mode:follow" / "mode:stay").


// 9.31: the character picked in the "Play as" drop-down ("auto", "ethan", "mia", "clancy").
std::string selected_character() {
    const LRESULT i = SendMessageW(g.playas, CB_GETCURSEL, 0, 0);
    const auto& list = character_choices();
    return (i >= 0 && static_cast<size_t>(i) < list.size()) ? list[static_cast<size_t>(i)].key : "auto";
}

// 10.5: ONE drop-down, TWO meanings. In network mode it is what the OTHER player sees you as (re7mp_char.json, as before). In "Ethan's friend" mode it
// is what the FRIEND looks like and your own character is left alone. Each mode keeps its own pick (play_as / friend_as in the ini).
void fill_playas(bool for_friend) {
    SendMessageW(g.playas, CB_RESETCONTENT, 0, 0);
    for (const auto& c : character_choices()) {
        const std::wstring label = (for_friend && std::string(c.key) == "auto") ? std::wstring(L"Default (the script's own body)") : widen(c.label);
        SendMessageW(g.playas, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
    }
    SetWindowTextW(g.playas_label, for_friend ? L"Appear as:" : L"Play as:");
    SetWindowTextW(g.playas_note, for_friend ? L"(what Ethan's friend looks like; you stay as the game has you)" : L"(the other player sees you as this)");
}

void show_playas_for_mode(bool first_time) {
    if (g.playas == nullptr || g.playas_label == nullptr || g.playas_note == nullptr) return;
    const bool for_friend = !network_mode_selected();
    if (!first_time && for_friend == g.playas_friend) return;
    if (!first_time) (g.playas_friend ? g.friend_as : g.play_as_own) = selected_character();  // keep the pick of the mode being left
    g.playas_friend = for_friend;
    fill_playas(for_friend);
    const int idx = character_index(for_friend ? g.friend_as : g.play_as_own);
    SendMessageW(g.playas, CB_SETCURSEL, static_cast<WPARAM>(idx < 0 ? 0 : idx), 0);
}

// What the friend should look like for the engine ("" = it says nothing).
std::string friend_look_key() {
    const std::string k = g.playas_friend ? selected_character() : g.friend_as;
    return k == "auto" ? std::string() : k;
}

// (10.24) The alpha channel's two settings (re7mp.ini: channel=stable|alpha, and alpha_repo=owner/name, which beats kAlphaRepo). Plain globals, read by
// load_ini() and written by save_ini(), so nothing can write the file before the choice was read. `note` is a line for the log when the ini asked for
// something this build cannot do. Only the GUI thread touches it (the network threads get copies).
struct AlphaSetting {
    bool on = false;
    std::string repo;  // "" = no alpha is linked in this build (the button only previews its warning)
    std::string note;
};
AlphaSetting g_alpha;

// (10.13) The Steam app id the link runs as (re7mp.ini, steam_app_id): 480 (Spacewar) unless the file says otherwise. 418370 would make the exe look like a
// second copy of the game itself to Steam.
int steam_app_id() {
    const int v = static_cast<int>(GetPrivateProfileIntW(L"re7mp", L"steam_app_id", kSteamAppIdDefault, ini_path().c_str()));
    return v > 0 ? v : kSteamAppIdDefault;
}

void save_ini() {
    const std::wstring p = ini_path();
    WritePrivateProfileStringW(L"re7mp", L"game_dir", get_text(g.gamedir).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"mode", network_mode_selected() ? L"network" : L"loopback", p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"listen", get_text(g.port).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"peer", get_text(g.peer).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"name", get_text(g.name).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"save_dir", get_text(g.savedir).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"share_saves_on",
                               IsDlgButtonChecked(g.hwnd, IDC_SAVE_SHARE) == BST_CHECKED ? L"1" : L"0", p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"check_updates",
                               IsDlgButtonChecked(g.hwnd, IDC_UPD_AUTO) == BST_CHECKED ? L"1" : L"0", p.c_str());
    const Transport tr = selected_transport();
    WritePrivateProfileStringW(L"re7mp", L"transport", steam_selected() ? L"steam" : (tr == Transport::TcpJoin ? L"tcp-join" : L"tcp-host"), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"steam_peer", get_text(g.steam_id).c_str(), p.c_str());  // (10.10)
    WritePrivateProfileStringW(L"re7mp", L"steam_app_id", std::to_wstring(steam_app_id()).c_str(), p.c_str());  // (10.13) written so it can be found and changed
    WritePrivateProfileStringW(L"re7mp", L"bot", nullptr, p.c_str());  // (10.26) the old "bot=" line (follow / stationary / beside) is not used any more: take it out
    WritePrivateProfileStringW(L"re7mp", L"play_as", widen(g.playas_friend ? g.play_as_own : selected_character()).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"friend_as", widen(g.playas_friend ? selected_character() : g.friend_as).c_str(), p.c_str());  // 10.5
    WritePrivateProfileStringW(L"re7mp", L"story_sync", IsDlgButtonChecked(g.hwnd, IDC_STORY) == BST_CHECKED ? L"1" : L"0", p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"enemy_sync", IsDlgButtonChecked(g.hwnd, IDC_ENEMY) == BST_CHECKED ? L"1" : L"0", p.c_str());  // 10.19
    WritePrivateProfileStringW(L"re7mp", L"channel", g_alpha.on ? L"alpha" : L"stable", p.c_str());  // (10.24)
    // (10.25) the two "coming later" boxes: saved and nothing else (future_ui.hpp). Only the program reads these two lines.
    WritePrivateProfileStringW(L"re7mp", L"biorand", IsDlgButtonChecked(g.hwnd, IDC_FUT_BIORAND) == BST_CHECKED ? L"1" : L"0", p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"vr", IsDlgButtonChecked(g.hwnd, IDC_FUT_VR) == BST_CHECKED ? L"1" : L"0", p.c_str());
}

void load_ini() {
    const std::wstring p = ini_path();
    wchar_t buf[1024];
    GetPrivateProfileStringW(L"re7mp", L"game_dir", L"", buf, 1024, p.c_str());
    SetWindowTextW(g.gamedir, buf);
    GetPrivateProfileStringW(L"re7mp", L"listen", L"27015", buf, 1024, p.c_str());
    SetWindowTextW(g.port, buf);
    GetPrivateProfileStringW(L"re7mp", L"peer", L"", buf, 1024, p.c_str());
    SetWindowTextW(g.peer, buf);
    GetPrivateProfileStringW(L"re7mp", L"name", L"Player", buf, 1024, p.c_str());
    SetWindowTextW(g.name, buf);
    GetPrivateProfileStringW(L"re7mp", L"save_dir", L"", buf, 1024, p.c_str());
    SetWindowTextW(g.savedir, buf);
    // Save sharing is ON unless it was switched off (9.22). The key is new, so an old ini that only says "0" because that used to be the
    // default does not keep it off. WM_CREATE switches it off again when no Steam save folder can be found.
    GetPrivateProfileStringW(L"re7mp", L"share_saves_on", L"1", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_SAVE_SHARE, lstrcmpiW(buf, L"0") == 0 ? BST_UNCHECKED : BST_CHECKED);
    GetPrivateProfileStringW(L"re7mp", L"check_updates", L"1", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_UPD_AUTO, lstrcmpiW(buf, L"0") == 0 ? BST_UNCHECKED : BST_CHECKED);
    GetPrivateProfileStringW(L"re7mp", L"mode", L"loopback", buf, 1024, p.c_str());
    CheckRadioButton(g.hwnd, IDC_MODE_LOOP, IDC_MODE_NET, lstrcmpiW(buf, L"network") == 0 ? IDC_MODE_NET : IDC_MODE_LOOP);
    GetPrivateProfileStringW(L"re7mp", L"transport", L"tcp-host", buf, 1024, p.c_str());
    // an old re7mp.ini may still say "udp": that choice is gone, so it becomes "I host"
    CheckRadioButton(g.hwnd, IDC_TR_HOST, IDC_TR_STEAM,
                     lstrcmpiW(buf, L"steam") == 0 ? IDC_TR_STEAM : (lstrcmpiW(buf, L"tcp-join") == 0 ? IDC_TR_JOIN : IDC_TR_HOST));  // 10.10: "steam" is new
    GetPrivateProfileStringW(L"re7mp", L"steam_peer", L"", buf, 1024, p.c_str());
    SetWindowTextW(g.steam_id, buf);
    // (10.26) an old ini's "bot=" (follow / stationary / beside / orbit) is ignored: the friend always starts out following you
    GetPrivateProfileStringW(L"re7mp", L"play_as", L"auto", buf, 1024, p.c_str());
    g.play_as_own = narrow(buf);  // an unknown word in the ini means "auto" (character_index says -1)
    GetPrivateProfileStringW(L"re7mp", L"friend_as", L"auto", buf, 1024, p.c_str());
    g.friend_as = narrow(buf);
    show_playas_for_mode(true);  // the drop-down shows the pick of the mode that is selected
    // 9.33: experimental, so it starts OFF; only an ini that says "1" turns it on
    GetPrivateProfileStringW(L"re7mp", L"story_sync", L"0", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_STORY, lstrcmpiW(buf, L"1") == 0 ? BST_CHECKED : BST_UNCHECKED);
    // 10.19: enemy and Molded sync starts ON; only an ini that says "0" turns it off
    GetPrivateProfileStringW(L"re7mp", L"enemy_sync", L"1", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_ENEMY, lstrcmpiW(buf, L"0") == 0 ? BST_UNCHECKED : BST_CHECKED);
    // (10.25) the two "coming later" boxes start OFF; only an ini that says yes (future_flag_on) ticks one. Nothing else reads them.
    GetPrivateProfileStringW(L"re7mp", L"biorand", L"0", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_FUT_BIORAND, future_flag_on(narrow(buf)) ? BST_CHECKED : BST_UNCHECKED);
    GetPrivateProfileStringW(L"re7mp", L"vr", L"0", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_FUT_VR, future_flag_on(narrow(buf)) ? BST_CHECKED : BST_UNCHECKED);
    // (10.24) the alpha channel: everyone starts on the normal releases; only an ini that says "alpha" (the Join button writes it) is on the alpha.
    GetPrivateProfileStringW(L"re7mp", L"channel", L"stable", buf, 1024, p.c_str());
    g_alpha.on = lstrcmpiW(buf, L"alpha") == 0;
    GetPrivateProfileStringW(L"re7mp", L"alpha_repo", L"", buf, 1024, p.c_str());
    g_alpha.repo = narrow(buf);
    g_alpha.note.clear();
    if (g_alpha.repo.empty()) g_alpha.repo = alpha_default_repo();  // (10.25) the link set in alpha_channel.hpp (the same repository as the normal releases)
    if (!g_alpha.repo.empty() && !valid_repo_name(g_alpha.repo)) {
        g_alpha.note = "re7mp.ini: alpha_repo=" + g_alpha.repo + " is not a GitHub repository name (owner/name): the alpha is not used.";
        g_alpha.repo.clear();
    }
    if (g_alpha.on && g_alpha.repo.empty()) {
        g_alpha.on = false;
        if (g_alpha.note.empty()) g_alpha.note = "re7mp.ini says channel=alpha but this build has no alpha linked: staying on the normal releases.";
    }
}

// ---------------------------------------------------------------- finding the game

std::optional<fs::path> find_running_re7() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return std::nullopt;
    std::optional<fs::path> result;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            if (lstrcmpiW(pe.szExeFile, L"re7.exe") != 0) continue;
            HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
            if (!h) continue;
            wchar_t buf[MAX_PATH * 2];
            DWORD n = static_cast<DWORD>(sizeof(buf) / sizeof(buf[0]));
            if (QueryFullProcessImageNameW(h, 0, buf, &n)) result = fs::path(std::wstring(buf, n)).parent_path();
            CloseHandle(h);
            if (result) break;
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return result;
}

std::optional<fs::path> find_re7_via_steam() {
    std::vector<fs::path> roots;
    wchar_t buf[MAX_PATH * 2];
    DWORD size = sizeof(buf);  // bytes
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath", RRF_RT_REG_SZ, nullptr, buf, &size) ==
        ERROR_SUCCESS) {
        roots.emplace_back(std::wstring(buf));
    }
    roots.emplace_back(L"C:\\Program Files (x86)\\Steam");
    for (const auto& r : roots) {
        if (auto p = find_re7_in_steam(r)) return p;
    }
    return std::nullopt;
}

// (9.42) The Steam account that is signed in right now: a registry value Steam keeps up to date (0 when Steam is not running or nobody is
// signed in). A plain read; nothing is sent to Steam and nothing of Steam's is changed.
uint32_t steam_active_user() {
    DWORD v = 0;
    DWORD size = sizeof(v);  // bytes
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", L"ActiveUser", RRF_RT_REG_DWORD, nullptr, &v,
                     &size) == ERROR_SUCCESS) {
        return static_cast<uint32_t>(v);
    }
    return 0;
}

// The RE7 save folder of the account Steam is signed in as (else the last one that signed in, else the one with the newest save).
SaveDirChoice choose_save_dir_via_steam() {
    std::vector<fs::path> roots;
    wchar_t buf[MAX_PATH * 2];
    DWORD size = sizeof(buf);  // bytes
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath", RRF_RT_REG_SZ, nullptr, buf, &size) ==
        ERROR_SUCCESS) {
        roots.emplace_back(std::wstring(buf));
    }
    roots.emplace_back(L"C:\\Program Files (x86)\\Steam");
    const uint32_t active = steam_active_user();
    SaveDirChoice first_miss;
    for (const auto& r : roots) {
        SaveDirChoice c = choose_save_dir(r, active);
        if (c.how != DirHow::None) return c;
        if (first_miss.why.empty()) first_miss = c;
    }
    return first_miss;
}

std::string g_save_dir_why;  // why the last detection found nothing (shown when save sharing starts off)

bool detect_save_dir(bool quiet) {
    const SaveDirChoice c = choose_save_dir_via_steam();
    if (c.how != DirHow::None) {
        g_save_dir_why.clear();
        SetWindowTextW(g.savedir, c.dir.wstring().c_str());
        log_line("Found your save folder: " + c.dir.u8string());
        log_line("  Steam account " + std::to_string(c.account) + ": " + c.why + ".");
        return true;
    }
    g_save_dir_why = c.why;
    if (!quiet) log_line("Could not find the save folder (...\\userdata\\<id>\\418370\\remote\\win64_save): " + c.why + ". You can type it in.");
    return false;
}

// RE7 loads saves from the Steam account that is signed in. If the folder in the box (kept from an earlier run in re7mp.ini, or found before
// Steam switched accounts) is another account's userdata folder, replace it. A path that is not a userdata folder is never touched.
void fix_save_dir_for_active_account() {
    const SaveDirChoice c = choose_save_dir_via_steam();
    const DirCorrection fix = correct_save_dir(fs::path(get_text(g.savedir)), c);
    if (!fix.change) return;
    SetWindowTextW(g.savedir, c.dir.wstring().c_str());
    log_line("Save folder: " + fix.why + ": " + c.dir.u8string());
}

bool detect_game(bool quiet) {
    if (auto p = find_running_re7()) {
        SetWindowTextW(g.gamedir, p->wstring().c_str());
        log_line("Found RE7 (it is running): " + p->u8string());
        return true;
    }
    if (auto p = find_re7_via_steam()) {
        SetWindowTextW(g.gamedir, p->wstring().c_str());
        log_line("Found RE7 in your Steam library: " + p->u8string());
        return true;
    }
    if (!quiet) log_line("Could not find RE7 automatically. Use Browse to pick the folder that contains re7.exe.");
    return false;
}

void browse_game() {
    BROWSEINFOW bi{};
    bi.hwndOwner = g.hwnd;
    bi.lpszTitle = L"Select your Resident Evil 7 folder (the one containing re7.exe)";
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
    PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi);
    if (!pidl) return;
    wchar_t path[MAX_PATH];
    if (SHGetPathFromIDListW(pidl, path)) SetWindowTextW(g.gamedir, path);
    CoTaskMemFree(pidl);
}

// ---------------------------------------------------------------- Lua script install

std::string load_resource(int id) {
    HRSRC res = FindResourceW(nullptr, MAKEINTRESOURCEW(id), RT_RCDATA);
    if (!res) return {};
    HGLOBAL mem = LoadResource(nullptr, res);
    if (!mem) return {};
    const DWORD size = SizeofResource(nullptr, res);
    const char* data = static_cast<const char*>(LockResource(mem));
    if (!data) return {};
    return std::string(data, size);
}
std::string load_lua_resource() { return load_resource(kLuaResourceId); }
std::vector<uint8_t> load_resource_bytes(int id) {
    const std::string s = load_resource(id);
    return std::vector<uint8_t>(s.begin(), s.end());
}

bool game_dir_ok(fs::path& out) {
    const std::wstring t = get_text(g.gamedir);
    std::error_code ec;
    if (t.empty() || !fs::is_directory(fs::path(t), ec)) return false;
    out = fs::path(t);
    return true;
}

// ---------------------------------------------------------------- (10.10) Steam invites

constexpr UINT kMsgFriends = WM_APP + 2;
constexpr UINT kFriendMenuBase = 5000;

// Where steam_api64.dll may be: the RE7 folder first (the game's own, the one the other mod uses), then Steam's own folder.
std::vector<fs::path> steam_dll_dirs() {
    std::vector<fs::path> dirs;
    fs::path game;
    if (game_dir_ok(game)) dirs.push_back(game);
    wchar_t buf[MAX_PATH * 2];
    DWORD size = sizeof(buf);  // bytes
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath", RRF_RT_REG_SZ, nullptr, buf, &size) == ERROR_SUCCESS) dirs.emplace_back(std::wstring(buf));
    dirs.emplace_back(L"C:\\Program Files (x86)\\Steam");
    return dirs;
}

// The Steam ID of the account signed in to Steam right now (0 when Steam is not running).
uint64_t my_steam_id() { return steam64_from_account(steam_active_user()); }

void put_on_clipboard(const std::wstring& text) {
    if (!OpenClipboard(g.hwnd)) return;
    EmptyClipboard();
    const SIZE_T bytes = (text.size() + 1) * sizeof(wchar_t);
    if (HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
        if (void* p = GlobalLock(h)) {
            std::memcpy(p, text.c_str(), bytes);
            GlobalUnlock(h);
            if (SetClipboardData(CF_UNICODETEXT, h) == nullptr) GlobalFree(h);
        } else {
            GlobalFree(h);
        }
    }
    CloseClipboard();
}

// The line you send your friend (they paste it in their "Friend's ID" box): your Steam ID, your name, this version's protocol.
void copy_my_invite() {
    const uint64_t me = my_steam_id();
    if (me == 0) {
        MessageBoxW(g.hwnd, L"Steam does not seem to be running (or nobody is signed in). Start Steam first, then try again.", L"RE7 Multiplayer", MB_ICONINFORMATION);
        return;
    }
    Invite inv;
    inv.steam_id = me;
    inv.protocol = static_cast<int>(kProtocolVersion);
    inv.name = narrow(get_text(g.name));
    const std::string line = make_invite(inv);
    put_on_clipboard(widen(line));
    log_line("Copied your invite line (paste it to your friend; they put it in their \"Friend's ID\" box, and you put theirs in yours): " + line);
}

// The friends list is read on a short-lived thread (starting Steam's interface can take a moment) and shown as a menu when it is ready.
struct FriendsFetch {
    std::mutex mu;
    bool busy = false;
    std::vector<SteamFriendInfo> list;
    std::string err;
};
FriendsFetch g_friends;

void start_friends_fetch() {
    if (g.ui_running) return;  // a running link has the Steam interface open; asking again would shut that one down
    {
        std::lock_guard<std::mutex> lk(g_friends.mu);
        if (g_friends.busy) return;
        g_friends.busy = true;
    }
    log_line("Steam: reading your friends list...");
    const auto dirs = steam_dll_dirs();
    const HWND hw = g.hwnd;
    const int app = steam_app_id();
    std::thread([dirs, hw, app] {
        std::string err;
        auto list = steam_friends_once(dirs, err, app);
        {
            std::lock_guard<std::mutex> lk(g_friends.mu);
            g_friends.list = std::move(list);
            g_friends.err = err;
            g_friends.busy = false;
        }
        PostMessageW(hw, kMsgFriends, 0, 0);
    }).detach();
}

void show_friends_menu() {
    std::vector<SteamFriendInfo> list;
    std::string err;
    {
        std::lock_guard<std::mutex> lk(g_friends.mu);
        list = g_friends.list;
        err = g_friends.err;
    }
    if (list.empty()) {
        log_line("Steam: " + (err.empty() ? std::string("no friends were listed") : err));
        const std::wstring msg = L"Could not list your Steam friends: " + widen(err.empty() ? "none were listed" : err) +
                                 L"\n\nYou can still type your friend's Steam ID (17 digits) or paste their invite line.";
        MessageBoxW(g.hwnd, msg.c_str(), L"RE7 Multiplayer", MB_ICONINFORMATION);
        return;
    }
    log_line("Steam: " + std::to_string(list.size()) + " friend(s) listed" + (err.empty() ? std::string() : " (" + err + ")") + ".");
    HMENU menu = CreatePopupMenu();
    const size_t shown = list.size() < 60 ? list.size() : 60;
    for (size_t i = 0; i < shown; ++i) {
        std::wstring label = widen(list[i].name.empty() ? std::to_string(list[i].id) : list[i].name);
        label += list[i].in_re7 ? L"   (playing RE7 now)" : (list[i].online ? L"   (online)" : L"   (offline)");
        AppendMenuW(menu, MF_STRING, kFriendMenuBase + static_cast<UINT>(i), label.c_str());
    }
    RECT r{};
    GetWindowRect(g.steam_pick, &r);
    SetForegroundWindow(g.hwnd);
    const UINT cmd = static_cast<UINT>(TrackPopupMenu(menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN, r.left, r.bottom, 0, g.hwnd, nullptr));
    DestroyMenu(menu);
    if (cmd >= kFriendMenuBase && cmd < kFriendMenuBase + shown) {
        const SteamFriendInfo& f = list[cmd - kFriendMenuBase];
        SetWindowTextW(g.steam_id, widen(std::to_string(f.id)).c_str());
        log_line("Steam: friend " + f.name + " (" + std::to_string(f.id) + ") picked.");
    }
}

// Writes the choice for the script (re7mp_char.json) when a game folder is picked; tells the log what happened. quiet: no line when nothing changed.
void apply_character(bool quiet) {
    fs::path game;
    if (!game_dir_ok(game)) {
        if (!quiet) log_line("Pick your RE7 folder first; the character is written when you press Start.");
        return;
    }
    const std::string key = selected_character();
    bool wrote = false;
    if (!sync_character_choice(data_dir_for(game), key, &wrote)) {
        log_line("Play as: could not write " + std::string("re7mp_char.json") + " into the game's data folder.");
    } else if (wrote || !quiet) {
        const int i = character_index(key);
        log_line(std::string("Play as: ") + (i >= 0 ? character_choices()[static_cast<size_t>(i)].label : key.c_str()) +
                 (wrote ? " (the script in the game picks it up within a couple of seconds)." : " (already set)."));
    }
}

// 9.33: writes the "Sync story cutscenes" box for the script (re7mp_story.json) when a game folder is picked; tells the log what happened.
// quiet: no line when nothing changed. (The window code can't be built where this was written; the file it writes (story_sync.hpp) is tested.)
void apply_story_sync(bool quiet) {
    fs::path game;
    if (!game_dir_ok(game)) {
        if (!quiet) log_line("Pick your RE7 folder first; the story sync box is written when you press Start.");
        return;
    }
    const bool on = IsDlgButtonChecked(g.hwnd, IDC_STORY) == BST_CHECKED;
    bool wrote = false;
    if (!sync_story_sync(data_dir_for(game), on, &wrote)) {
        log_line("Sync story cutscenes: could not write re7mp_story.json into the game's data folder.");
    } else if (wrote || !quiet) {
        log_line(std::string("Sync story cutscenes (experimental): ") + (on ? "ON" : "off") +
                 (wrote ? " (the script in the game picks it up within a couple of seconds)." : " (already set).") +
                 (on ? " Both players need it ticked: whoever starts a cutscene brings the other one there and plays it for them too." : ""));
    }
}

// 10.19: writes the "Sync enemies and the Molded" box for the script (re7mp_enemysync.json) when a game folder is picked; tells the log what happened.
// quiet: no line when nothing changed. (The window code can't be built where this was written; the file it writes (enemy_sync.hpp) is tested.)
void apply_enemy_sync(bool quiet) {
    fs::path game;
    if (!game_dir_ok(game)) {
        if (!quiet) log_line("Pick your RE7 folder first; the enemy sync box is written when you press Start.");
        return;
    }
    const bool on = IsDlgButtonChecked(g.hwnd, IDC_ENEMY) == BST_CHECKED;
    bool wrote = false;
    if (!sync_enemy_sync(data_dir_for(game), on, &wrote)) {
        log_line("Sync enemies and the Molded: could not write re7mp_enemysync.json into the game's data folder.");
    } else if (wrote || !quiet) {
        log_line(std::string("Sync enemies and the Molded: ") + (on ? "ON" : "off") +
                 (wrote ? " (the script in the game picks it up within a couple of seconds)." : " (already set).") +
                 (on ? " Both players need it ticked: the host's enemies and Molded are shown in the joiner's game as copies the host runs." : ""));
    }
}

// (10.24) The build of this exe: the BUILD label of the script it carries ("10.24"); "" when that cannot be read.
const std::string& exe_build() {
    static const std::string b = script_build(load_lua_resource());
    return b;
}

// (10.26) Which alpha of its release this exe is: the ALPHA label of the script it carries ("3" for "v0.11 alpha 3"); 0 for a normal release, and when the
// label cannot be read. exe_name() is what it is called: "v0.11" or "v0.11 alpha 3".
int exe_alpha() {
    static const int a = script_alpha(load_lua_resource());
    return a;
}
std::string exe_name() { return release_name(kReleaseVersion, exe_alpha()); }

// (10.24) Writes re7mp_channel.json (which channel this exe is on, and its own build) for the script when a game folder is picked, so the script's panel and
// the debug file say it: a report from a tester then says which build and which channel it came from. quiet: no line unless it failed.
// (The window code can't be built where this was written; the file it writes (alpha_channel.hpp) is tested.)
void apply_channel(bool quiet) {
    fs::path game;
    if (!game_dir_ok(game)) {
        if (!quiet) log_line("Pick your RE7 folder first; the channel is written when you press Start.");
        return;
    }
    bool wrote = false;
    if (!sync_channel(data_dir_for(game), g_alpha.on ? Channel::Alpha : Channel::Stable, exe_build(), &wrote)) {
        log_line("Channel: could not write re7mp_channel.json into the game's data folder.");
    } else if (wrote && !quiet) {
        log_line(std::string("Channel: ") + (g_alpha.on ? "alpha" : "stable") + ", build " + exe_build() +
                 " (the script in the game picks it up within a few seconds).");
    }
}

void do_stop();
std::string user_agent();
bool setting_refw_dll_only();
void note_install_done();

// 9.45: everything this exe carries for the game folder (the script and the built-in clips and settings).
ModFiles embedded_mod_files() {
    ModFiles f;
    f.lua = load_lua_resource();
    f.defaults = load_resource(kDefaultsResourceId);
    f.models_zip = load_resource_bytes(kModelsResourceId);  // (10.13) AfroJackX's models travel inside the exe: nothing to download
    return f;
}

// Where the author's model download may be: your Downloads folder, and next to this program.
std::vector<fs::path> model_search_dirs() {
    std::vector<fs::path> dirs;
    wchar_t buf[MAX_PATH * 2];
    const DWORD n = GetEnvironmentVariableW(L"USERPROFILE", buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
    if (n > 0 && n < sizeof(buf) / sizeof(buf[0])) dirs.push_back(fs::path(std::wstring(buf, n)) / L"Downloads");
    dirs.push_back(exe_dir());
    return dirs;
}

// Keeps the window painting while a download runs on this thread (a button clicked meanwhile is refused by g_installing).
bool g_installing = false;
void pump_messages() {
    MSG m;
    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
        if (m.message == WM_QUIT) {
            PostQuitMessage(static_cast<int>(m.wParam));
            break;
        }
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
}

// The one install: REFramework at the tested version (asks first), the Lua script, the built-in clips and settings, and the full
// character models when the author's download is at hand. The logic is in installer.cpp (tested); this only asks, shows and logs.
bool install_script(const fs::path& game) {
    if (g_installing) return false;
    g_installing = true;
    log_line("Installing: checking REFramework, then the Lua script and what it needs...");
    InstallOptions opt;
    opt.ask = [](const std::string& title, const std::string& question) {
        return MessageBoxW(g.hwnd, widen(question).c_str(), widen(title).c_str(), MB_YESNO | MB_ICONQUESTION) == IDYES;
    };
    opt.refw_dll_only = setting_refw_dll_only();
    opt.model_dirs = model_search_dirs();
    opt.progress = [](uint64_t got, uint64_t total) {  // 10.8: no status row any more: a line in the log at every 10 %, and the window keeps answering
        static int last_step = -1;
        const int step = total != 0 ? static_cast<int>(got * 10 / total) : static_cast<int>(got / (1024 * 1024));
        if (step != last_step) {
            last_step = step;
            log_line(total != 0 ? "Downloading REFramework... " + std::to_string(got * 100 / total) + "%"
                                : "Downloading REFramework... " + std::to_string(got / 1024) + " KB");
        }
        pump_messages();
    };
    auto http = make_winhttp_client(user_agent());
    const InstallReport rep = install_mod(*http, game, embedded_mod_files(), opt);
    for (const auto& l : rep.lines) log_line(l);
    note_install_done();
    g_installing = false;
    return rep.ok;
}

// ---------------------------------------------------------------- start / stop

void update_enabled() {
    show_playas_for_mode(false);  // 10.5: the "Play as" drop-down is the friend's look in Ethan's friend mode
    const bool net = network_mode_selected();
    const Transport tr = selected_transport();
    const BOOL idle = g.ui_running ? FALSE : TRUE;
    EnableWindow(g.gamedir, idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_BROWSE), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_DETECT), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_MODE_LOOP), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_MODE_NET), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_TR_HOST), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_TR_JOIN), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_TR_STEAM), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_INSTALL), idle);
    EnableWindow(g.port, idle);
    EnableWindow(g.savedir, idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_SAVE_DETECT), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_SAVE_SHARE), idle);
    EnableWindow(g.peer, idle && net);
    EnableWindow(g.lbl_peer, idle && net);
    SetWindowTextW(g.lbl_peer, tr == Transport::TcpHost ? L"Only allow (ip, optional):" : L"Other player (ip:port):");
    {   // (10.10) the same row holds the Steam controls when "Steam invites" is the connection
        const bool steam = steam_selected();
        const int tcp_show = steam ? SW_HIDE : SW_SHOW, steam_show = steam ? SW_SHOW : SW_HIDE;
        ShowWindow(g.lbl_port, tcp_show);
        ShowWindow(g.port, tcp_show);
        ShowWindow(g.lbl_peer, tcp_show);
        ShowWindow(g.peer, tcp_show);
        ShowWindow(g.steam_lbl, steam_show);
        ShowWindow(g.steam_id, steam_show);
        ShowWindow(g.steam_pick, steam_show);
        ShowWindow(g.steam_copy, steam_show);
        EnableWindow(g.steam_id, idle && net);
        EnableWindow(g.steam_pick, idle && net);
        EnableWindow(g.steam_copy, net);
        if (steam) {
            const uint64_t me = my_steam_id();
            SetWindowTextW(g.conn_note, me ? (L"your Steam ID: " + widen(std::to_string(me))).c_str() : L"Steam is not running / not signed in");
        } else {
            SetWindowTextW(g.conn_note, L"(e.g. a Radmin VPN address)");
        }
    }
    // Ethan's friend can be moved to you while it runs.
    EnableWindow(GetDlgItem(g.hwnd, IDC_BOT_TELE), !net && g.ui_running);
    SetWindowTextW(g.start, g.ui_running ? L"Stop" : L"Start");
}

void set_running_ui(bool running) {
    g.ui_running = running;
    update_enabled();
}

bool parse_peer(const std::wstring& text, Config& cfg) {
    if (text.empty()) return false;
    const auto colon = text.rfind(L':');
    std::wstring host = colon == std::wstring::npos ? text : text.substr(0, colon);
    int port = colon == std::wstring::npos ? 27015 : static_cast<int>(std::wcstol(text.c_str() + colon + 1, nullptr, 10));
    if (host.empty() || port < 1 || port > 65535) return false;
    cfg.peer_host = narrow(host);
    cfg.peer_port = static_cast<uint16_t>(port);
    return true;
}

void do_start() {
    if (g_installing) return;
    fs::path game;
    if (!game_dir_ok(game)) {
        MessageBoxW(g.hwnd, L"Pick your RE7 folder first (Detect or Browse).", L"RE7 Multiplayer", MB_ICONINFORMATION);
        return;
    }
    long port = 27015;
    if (!steam_selected()) {  // (a Steam link has no port at all)
        port = std::wcstol(get_text(g.port).c_str(), nullptr, 10);
        if (port < 1 || port > 65534) {
            MessageBoxW(g.hwnd, L"The port must be between 1 and 65534.", L"RE7 Multiplayer", MB_ICONINFORMATION);
            return;
        }
    }
    {
        std::lock_guard<std::mutex> lk(g_friends.mu);
        if (g_friends.busy) {
            MessageBoxW(g.hwnd, L"Still reading your Steam friends list: try again in a few seconds.", L"RE7 Multiplayer", MB_ICONINFORMATION);
            return;
        }
    }
    fix_save_dir_for_active_account();  // Steam may have switched accounts since this window opened
    Config cfg;
    cfg.data_dir = data_dir_for(game);
    cfg.listen_port = static_cast<uint16_t>(port);
    cfg.mode = network_mode_selected() ? Mode::Network : Mode::Loopback;
    cfg.name = narrow(get_text(g.name));
    cfg.transport = selected_transport();
    cfg.bot_mode = BotMode::Follow;  // (10.26) it starts out following you; the script's F5 key switches follow / stay in the game
    cfg.bot_character = friend_look_key();  // 10.5: what Ethan's friend looks like
    cfg.save_sync = IsDlgButtonChecked(g.hwnd, IDC_SAVE_SHARE) == BST_CHECKED;
    cfg.save_dir = fs::path(get_text(g.savedir));
    if (cfg.mode == Mode::Network && steam_selected()) {   // (10.10) over Steam's relay: the other player's Steam ID, no port
        uint64_t theirs = 0;
        std::string why;
        if (!parse_steam_id_text(narrow(get_text(g.steam_id)), theirs, &why)) {
            const std::wstring msg = L"Enter your friend's Steam ID (17 digits), or paste their invite line, or use \"Pick a friend...\".\n\n(" + widen(why) + L")";
            MessageBoxW(g.hwnd, msg.c_str(), L"RE7 Multiplayer", MB_ICONINFORMATION);
            return;
        }
        const uint64_t me = my_steam_id();
        if (me == 0) {
            MessageBoxW(g.hwnd, L"Steam does not seem to be running (or nobody is signed in). Start Steam, then press Start again.", L"RE7 Multiplayer", MB_ICONINFORMATION);
            return;
        }
        if (me == theirs) {
            MessageBoxW(g.hwnd, L"That is your own Steam ID: enter your friend's.", L"RE7 Multiplayer", MB_ICONINFORMATION);
            return;
        }
        cfg.peer_steam_id = theirs;
        cfg.transport = steam_i_host(me, theirs) ? Transport::SteamHost : Transport::SteamJoin;  // the lower Steam ID hosts (the engine checks it again with Steam's own answer)
        const auto dirs = steam_dll_dirs();
        const int app = steam_app_id();
        cfg.steam_api = [dirs, app] { return make_steam_api_dynamic(dirs, app); };
        save_ini();
    } else if (cfg.mode == Mode::Network) {
        const std::wstring peer_text = get_text(g.peer);
        const bool peer_optional = cfg.transport == Transport::TcpHost;  // a host may accept anyone
        if (!(peer_optional && peer_text.empty()) && !parse_peer(peer_text, cfg)) {
            MessageBoxW(g.hwnd, L"Enter the other player's address as ip:port, for example 203.0.113.5:27015.",
                        L"RE7 Multiplayer", MB_ICONINFORMATION);
            return;
        }
    }

    // 10.1: Start no longer looks at the script. It is installed (and checked) by the Install button and after an update, nothing else.
    {
        std::error_code ec;
        if (!fs::exists(game / "reframework" / "autorun" / "re7mp.lua", ec))
            log_line("The Lua script is not installed in this RE7 folder yet: press \"Install / update mod\".");
    }
    if (cfg.mode == Mode::Network) apply_character(true);  // 9.31: the file the script reads says what "Play as" shows (10.5: in Ethan's friend mode the drop-down is the friend's look, not yours)
    apply_story_sync(true); // 9.33: ...and whether story sync is on
    apply_enemy_sync(true); // 10.19: ...and whether enemy and Molded sync is on
    apply_channel(true);    // (10.24) ...and which channel and build this exe is (the script says it in its panel and the debug file)

    std::string err;
    if (!g.engine.start(cfg, err)) {
        const std::wstring msg = L"Could not start: " + widen(err);
        MessageBoxW(g.hwnd, msg.c_str(), L"RE7 Multiplayer", MB_ICONERROR);
        return;
    }
    g.running_mode = cfg.mode;
    save_ini();
    set_running_ui(true);
}

void do_stop() {
    g.engine.stop();
    for (const auto& l : g.engine.drain_log()) log_line(l);
    set_running_ui(false);
    log_line("Stopped.");
}

// ---------------------------------------------------------------- updates and REFramework
// Network work runs on short-lived threads and reports through `upd`; the GUI's 200 ms timer shows it (refresh_updates).

struct Updates {
    std::mutex mu;
    enum class Phase { Idle, Checking, UpToDate, Available, Downloading, Ready, Failed } phase = Phase::Idle;
    std::string status = "Not checked yet.";
    ReleaseInfo release;
    UpdatePackage pkg;             // the downloaded program and its script, waiting to be swapped in
    std::deque<std::string> log;   // lines for the log box (it can only be written from the GUI thread)
    bool include_prerelease = false;  // re7mp.ini: include_prerelease=1 (playtesters who were given that option)
    bool refw_dll_only = false;       // re7mp.ini: reframework_files=dll
    bool refw_busy = false;           // an install is running
    bool refw_state_busy = false;     // the folder is being looked at
    bool refw_known = false;
    RefwState refw_state;
    std::wstring refw_for;            // the folder refw_state describes
    std::string refw_progress;
    // (10.24) the alpha channel (the setting itself is g_alpha)
    bool auto_download = false;       // the player said yes in the alpha window: download as soon as the running check has found the build
    bool back_to_stable = false;      // the running check is the one for leaving the alpha: the newest normal release counts whatever its number
    enum class Peek { Idle, Looking, Done } peek = Peek::Idle;  // the look at the newest alpha build that the "join" window needs
    UpdateCheck peeked;
    std::string peek_status;          // what the status row said before the look (it says "Looking..." meanwhile)
};
Updates upd;

std::string user_agent() { return std::string("re7mp/") + kReleaseVersion; }
bool setting_refw_dll_only() { return upd.refw_dll_only; }
void note_install_done() {  // so the REFramework row looks at the folder again
    std::lock_guard<std::mutex> lk(upd.mu);
    upd.refw_for.clear();
}

// "v0.11 alpha 3" or "version 0.11": what the status row and the log call a release.
std::string update_name(const ReleaseInfo& r) { return r.alpha ? release_label(r) : "version " + r.version; }

// (10.24) back_to_stable: leaving the alpha: the newest NORMAL release is wanted, whatever its number (this build is an alpha of the same release).
// auto_download: the player already said yes in a window (join / leave): the download starts as soon as this check has found the release.
// On the alpha channel (g_alpha.on) the check looks for alpha builds at the alpha source instead.
void start_update_check(bool back_to_stable = false, bool auto_download = false) {
    const bool alpha = g_alpha.on && !back_to_stable;
    const std::string repo = g_alpha.repo;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        if (upd.phase == Updates::Phase::Checking || upd.phase == Updates::Phase::Downloading ||
            upd.phase == Updates::Phase::Ready || upd.peek == Updates::Peek::Looking) {
            return;
        }
        upd.phase = Updates::Phase::Checking;
        upd.back_to_stable = back_to_stable;
        upd.auto_download = auto_download;
        upd.status = alpha ? "Checking for alpha builds..." : "Checking for updates...";
    }
    const bool pre = upd.include_prerelease;
    const int my_alpha = exe_alpha();
    const std::string my_name = exe_name();
    std::thread([pre, alpha, back_to_stable, repo, my_alpha, my_name] {
        auto http = make_winhttp_client(user_agent());
        const UpdateCheck c = alpha ? check_alpha(*http, repo, kReleaseVersion, my_alpha)
                                    : (back_to_stable ? check_back_to_stable(*http, pre) : check_for_update(*http, kReleaseVersion, pre));
        std::lock_guard<std::mutex> lk(upd.mu);
        upd.release = c.release;
        if (c.state == UpdateCheck::State::Available) {
            upd.phase = Updates::Phase::Available;
            if (alpha) {  // (10.26) the newest of the alpha and normal releases; c.message says which and what this exe is ("v0.12 alpha 3 is available (you have v0.11).")
                upd.status = c.message;
                upd.log.push_back(c.message +
                                  (upd.auto_download ? std::string(" Downloading it now.") : std::string(" Click the button in the Updates row to install it.")));
            } else if (back_to_stable) {
                upd.status = "The newest normal release is version " + c.release.version + ".";
            } else {
                upd.status = "Version " + c.release.version + " is available (you have " + kReleaseVersion + ").";
                upd.log.push_back("Update available: version " + c.release.version + ". Click the button in the Updates row to install it.");
            }
        } else if (c.state == UpdateCheck::State::UpToDate) {
            upd.phase = Updates::Phase::UpToDate;
            upd.status = alpha ? "Up to date (" + my_name + ")." : std::string("Up to date (v") + kReleaseVersion + ").";
            upd.auto_download = false;
        } else {
            upd.phase = Updates::Phase::Failed;
            upd.status = c.message;
            upd.log.push_back(c.message);
            upd.auto_download = false;
        }
    }).detach();
}

void start_update_download() {
    ReleaseInfo rel;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        if (upd.phase != Updates::Phase::Available) return;
        upd.phase = Updates::Phase::Downloading;
        upd.status = "Downloading " + update_name(upd.release) + "...";
        rel = upd.release;
    }
    std::thread([rel] {
        auto http = make_winhttp_client(user_agent());
        UpdatePackage pkg;
        std::string err;
        const bool ok = fetch_update_package(*http, rel, pkg, err, [](uint64_t got, uint64_t total) {
            std::lock_guard<std::mutex> lk(upd.mu);
            upd.status = total != 0 ? "Downloading... " + std::to_string(got * 100 / total) + "%"
                                    : "Downloading... " + std::to_string(got / 1024) + " KB";
        });
        std::lock_guard<std::mutex> lk(upd.mu);
        if (ok) {
            upd.pkg = std::move(pkg);
            upd.phase = Updates::Phase::Ready;
            upd.status = "Downloaded. Restarting...";
        } else {
            upd.phase = Updates::Phase::Failed;
            upd.status = "Update failed: " + err;
            upd.log.push_back("Update failed: " + err);
            upd.log.push_back(std::string("You can download it yourself from ") + kReleasesPage);
        }
    }).detach();
}

// On the GUI thread, once the download is ready: swap the program, start the new one, close this one.
void apply_update() {
    UpdatePackage pkg;
    std::string version;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        pkg = std::move(upd.pkg);
        version = update_name(upd.release);
        upd.phase = Updates::Phase::Idle;  // so this runs once
    }
    if (g.ui_running) do_stop();
    wchar_t buf[MAX_PATH * 2];
    const DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
    const fs::path me(std::wstring(buf, n));
    // 9.45: the program is swapped and the script that came with it is installed into the game folder in the same step.
    fs::path game;
    if (!game_dir_ok(game)) game.clear();
    const UpdateApply applied = apply_update_package(me, pkg, game);
    if (!applied.ok) {
        std::lock_guard<std::mutex> lk(upd.mu);
        upd.phase = Updates::Phase::Failed;
        upd.status = "Update failed: " + applied.err;
        upd.log.push_back("Update failed: " + applied.err);
        upd.log.push_back(std::string("You can download it yourself from ") + kReleasesPage);
        return;
    }
    for (const auto& l : applied.lines) log_line(l);
    log_line("Updated to " + version + ". Restarting...");
    save_ini();  // so the new program starts with the same settings
    const HINSTANCE r = ShellExecuteW(g.hwnd, L"open", me.wstring().c_str(), L"--updated", me.parent_path().wstring().c_str(), SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(r) <= 32) {
        MessageBoxW(g.hwnd, L"re7mp.exe was updated. Please start it again.", L"RE7 Multiplayer", MB_ICONINFORMATION);
    }
    DestroyWindow(g.hwnd);
}

void set_button_text(int slot, HWND h, const std::wstring& text) {
    if (g.shown[slot] == text) return;
    g.shown[slot] = text;
    SetWindowTextW(h, text.c_str());
}

// (10.24) Joins or leaves the alpha channel: remembers it (re7mp.ini), tells the script (re7mp_channel.json) and the log. Nothing is downloaded here.
void set_alpha(bool on) {
    g_alpha.on = on;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        if (upd.phase != Updates::Phase::Checking && upd.phase != Updates::Phase::Downloading && upd.phase != Updates::Phase::Ready) {
            upd.phase = Updates::Phase::Idle;  // what the last check found belongs to the other channel
        }
        upd.back_to_stable = false;
        upd.status = on ? "Alpha channel: on (" + exe_name() + ", build " + exe_build() + ")." : "Not checked yet.";
    }
    save_ini();
    apply_channel(true);
    log_line(on ? "Alpha channel: ON. \"Check now\" looks for alpha builds at github.com/" + g_alpha.repo + " from now on."
                : "Alpha channel: off. \"Check now\" looks at the normal releases again.");
}

// (10.24) The window that asks whether to join, with what has changed in the newest alpha build and the warning. `c` is what the look at the alpha
// source found. Yes: join, and download the build when it is newer than this exe. Nothing changes unless the player says yes.
void show_alpha_window(const UpdateCheck& c) {
    if (c.state == UpdateCheck::State::Failed) {
        log_line(c.message);
        const std::wstring m = widen(c.message) + L"\n\nNothing was changed.";
        MessageBoxW(g.hwnd, m.c_str(), L"RE7 Multiplayer - the alpha", MB_OK | MB_ICONWARNING);
        return;
    }
    const std::wstring q = widen(alpha_join_text(g_alpha.repo, c.release, kReleaseVersion, exe_alpha()));
    if (MessageBoxW(g.hwnd, q.c_str(), L"RE7 Multiplayer - join the alpha?", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES) {
        log_line("The alpha: you stayed on the normal releases.");
        return;
    }
    set_alpha(true);
    if (c.state == UpdateCheck::State::Available) {
        start_update_check(false, true);  // the alpha source is asked again (it is one small request), then the build is downloaded without asking twice
    } else {
        std::lock_guard<std::mutex> lk(upd.mu);
        upd.phase = Updates::Phase::UpToDate;
        upd.status = "Up to date (" + exe_name() + ").";
    }
}

void refresh_updates() {
    std::vector<std::string> lines;
    std::string status;
    Updates::Phase phase;
    Updates::Peek peek;
    std::string version, rel_label;
    bool back = false, go_download = false, peek_done = false;
    UpdateCheck peeked;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        while (!upd.log.empty()) {
            lines.push_back(std::move(upd.log.front()));
            upd.log.pop_front();
        }
        if (upd.peek == Updates::Peek::Done) {  // (10.24) the look at the newest alpha build is over: its window is shown below, outside the lock
            peek_done = true;
            peeked = upd.peeked;
            upd.peek = Updates::Peek::Idle;
            upd.status = upd.peek_status;
        }
        status = upd.status;
        phase = upd.phase;
        peek = upd.peek;
        version = upd.release.version;
        rel_label = release_label(upd.release);
        back = upd.back_to_stable;
        if (phase == Updates::Phase::Available && upd.auto_download) {  // (10.24) the player already said yes (join / leave window)
            upd.auto_download = false;
            go_download = true;
        }
    }
    for (const auto& l : lines) log_line(l);

    set_status(6, g.upd_st, widen(status));
    std::wstring label = L"Check now";
    bool enable = true;
    switch (phase) {
        case Updates::Phase::Available:
            label = back ? L"Back to v" + widen(version) : L"Update to " + widen(rel_label);  // (10.26) "Update to v0.13" / "Update to v0.12 alpha 3"
            break;
        case Updates::Phase::Checking: label = L"Checking..."; enable = false; break;
        case Updates::Phase::Downloading: label = L"Downloading..."; enable = false; break;
        case Updates::Phase::Ready: label = L"Restarting..."; enable = false; break;
        default: break;
    }
    if (peek == Updates::Peek::Looking) {
        label = L"Looking...";
        enable = false;
    }
    set_button_text(7, GetDlgItem(g.hwnd, IDC_UPD_BTN), label);
    EnableWindow(GetDlgItem(g.hwnd, IDC_UPD_BTN), enable);
    // (10.24) the alpha button waits while anything is running, like the update button
    set_button_text(8, GetDlgItem(g.hwnd, IDC_ALPHA_BTN), g_alpha.on ? L"Leave the alpha..." : L"Join the alpha...");
    EnableWindow(GetDlgItem(g.hwnd, IDC_ALPHA_BTN), enable);

    if (go_download) start_update_download();
    if (peek_done) show_alpha_window(peeked);
    if (phase == Updates::Phase::Ready) apply_update();
}

void on_update_button() {
    Updates::Phase phase;
    ReleaseInfo rel;
    bool back;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        phase = upd.phase;
        rel = upd.release;
        back = upd.back_to_stable;
    }
    if (phase == Updates::Phase::Available) {
        const std::string notes = shorten_notes(rel.notes, 700);
        std::wstring q;
        if (back) {  // (10.24) leaving the alpha
            q = L"The newest normal release is version " + widen(rel.version) + L".\n\nInstall it in place of this build and restart now? Your settings are kept.";
        } else if (rel.alpha) {  // (10.24) an alpha build (10.26: named "v0.12 alpha 3")
            q = widen(release_label(rel)) + L" is available (you have " + widen(exe_name()) + L").\n\nWhat's new:\n" + widen(notes) +
                L"\n\nDownload it and restart now? Your settings are kept. The other player needs the same alpha.";
        } else {
            q = L"Version " + widen(rel.version) + L" is available (you have " + widen(exe_name()) + L").\n\nWhat's new:\n" + widen(notes) +
                L"\n\nDownload it and restart now? Your settings are kept. The other player needs the same version.";
        }
        if (MessageBoxW(g.hwnd, q.c_str(), L"RE7 Multiplayer", MB_YESNO | MB_ICONQUESTION) == IDYES) start_update_download();
    } else if (phase == Updates::Phase::Idle || phase == Updates::Phase::UpToDate || phase == Updates::Phase::Failed) {
        start_update_check();
    }
}

// (10.24) The join window needs the notes of the newest alpha build, so the alpha source is looked at first (on a thread, like every network step);
// the timer (refresh_updates) shows the window when the look is over.
void start_alpha_peek() {
    const std::string repo = g_alpha.repo;
    const int my_alpha = exe_alpha();
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        if (upd.peek != Updates::Peek::Idle) return;
        upd.peek = Updates::Peek::Looking;
        upd.peek_status = upd.status;
        upd.status = "Looking up the newest alpha...";
    }
    std::thread([repo, my_alpha] {
        auto http = make_winhttp_client(user_agent());
        const UpdateCheck c = check_alpha(*http, repo, kReleaseVersion, my_alpha);
        std::lock_guard<std::mutex> lk(upd.mu);
        upd.peeked = c;
        upd.peek = Updates::Peek::Done;
    }).detach();
}

// (10.24) "Join the alpha..." / "Leave the alpha...". Nothing is installed or changed unless the player says yes in the window that follows.
void on_alpha_button() {
    bool busy;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        busy = upd.phase == Updates::Phase::Checking || upd.phase == Updates::Phase::Downloading || upd.phase == Updates::Phase::Ready ||
               upd.peek != Updates::Peek::Idle;
    }
    if (busy) {
        log_line("The alpha: wait for the update that is running to finish first.");
        return;
    }
    if (g_alpha.on) {  // leave: Yes = back to the newest normal release now, No = just stop looking for alpha builds
        const std::wstring q = widen(alpha_leave_text());
        const int a = MessageBoxW(g.hwnd, q.c_str(), L"RE7 Multiplayer - leave the alpha?", MB_YESNOCANCEL | MB_ICONQUESTION | MB_DEFBUTTON3);
        if (a == IDCANCEL) return;
        set_alpha(false);
        if (a == IDYES) {
            log_line("Leaving the alpha: looking for the newest normal release to put in place of this build...");
            start_update_check(true, true);
        }
    } else if (g_alpha.repo.empty()) {  // no alpha is linked in this build: the same warning as a preview, nothing is installed
        const std::wstring q = widen(alpha_preview_text());
        MessageBoxW(g.hwnd, q.c_str(), L"RE7 Multiplayer - the alpha", MB_OK | MB_ICONINFORMATION);
    } else {
        start_alpha_peek();
    }
}

// (10.25) One of the two "coming later" boxes was clicked (the box has already changed itself). It is saved; when it was just ticked the warning is shown
// ("not implemented yet, we are only preparing"). Nothing else happens: the script, the game and the other player never hear of it.
void on_future_box(FutureFeature f) {
    const bool on = IsDlgButtonChecked(g.hwnd, f == FutureFeature::Vr ? IDC_FUT_VR : IDC_FUT_BIORAND) == BST_CHECKED;
    save_ini();
    log_line(future_log_line(f, on));
    if (on) {
        const std::wstring text = widen(future_tick_text(f)), title = widen(future_tick_title(f));
        MessageBoxW(g.hwnd, text.c_str(), title.c_str(), MB_OK | MB_ICONWARNING);
    }
}

// ---------------------------------------------------------------- live status

void refresh_status() {
    const Status st = g.engine.status();
    for (const auto& l : g.engine.drain_log()) log_line(l);
    if (g.ui_running && !st.running) {
        set_running_ui(false);
        log_line("The networking engine stopped.");
    }

    const bool loop = g.running_mode == Mode::Loopback;
    std::wstring hook = L"Not running";
    std::wstring peer = L"-";
    if (st.running) {
        hook = st.game_hooked ? L"Connected: the Lua script is sending positions"
                              : L"Waiting for RE7 and the Lua script (start the game and load a save)";
        if (loop) peer = st.peer_active ? L"Ethan's friend is with you" : L"Waiting for your first position";
        else peer = st.peer_active ? L"Connected" : L"Waiting for the other player";
        if (st.peer_active && !st.remote_name.empty()) peer += L": " + widen(st.remote_name);
        if (st.foreign_protocol != 0) {
            peer = L"INCOMPATIBLE: the other player's re7mp.exe is a different version (protocol " +
                   std::to_wstring(st.foreign_protocol) + L", yours is " + std::to_wstring(static_cast<int>(kProtocolVersion)) +
                   L"). Both of you need v" + widen(kReleaseVersion);
        }
    }
    wchar_t buf[160];
    std::wstring local = L"-", remote = L"-";
    if (st.have_local) {
        swprintf_s(buf, L"%.2f, %.2f, %.2f", st.lx, st.ly, st.lz);
        local = buf;
    }
    if (st.have_remote) {
        swprintf_s(buf, L"%.2f, %.2f, %.2f", st.rx, st.ry, st.rz);
        remote = buf;
    }
    swprintf_s(buf, L"Sent %llu   Received %llu     Messages: %llu out, %llu in", static_cast<unsigned long long>(st.sent),
               static_cast<unsigned long long>(st.received), static_cast<unsigned long long>(st.messages_sent),
               static_cast<unsigned long long>(st.messages_received));
    set_status(0, g.st_hook, hook);
    set_status(1, g.st_peer, peer);
    set_status(2, g.st_local, local);
    set_status(3, g.st_remote, remote);
    set_status(4, g.st_pkts, buf);
    set_status(5, g.st_save, widen(st.last_save_event.empty() ? "-" : st.last_save_event));
    refresh_updates();
}

// ---------------------------------------------------------------- window

// (10.25) g_yoff: every y that make() is given is moved down by this much. The old layout (all the numbers below were written for it) is created with
// g_yoff = ui_layout::kTopBand, which makes room for the strip at the top; the strip itself is created with 0. g_log_h is the log's height in logical
// pixels (ui_layout::fit_log_height says it, from the screen, before the window is made).
int g_yoff = 0;
int g_log_h = ui_layout::kLogWant;

HWND make(const wchar_t* cls, const wchar_t* text, DWORD style, DWORD ex, int x, int y, int w, int h, int id) {
    return CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, S(x), S(y + g_yoff), S(w), S(h), g.hwnd,
                           reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), g.inst, nullptr);
}

BOOL CALLBACK set_font_proc(HWND child, LPARAM) {
    SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(g.font), TRUE);
    return TRUE;
}

void create_controls() {
    using ui_layout::kExtraW;  // (10.25) the controls that used to reach the right edge (x + w = 668) are this much wider; each one says so below
    const DWORD tab = WS_TABSTOP;
    g_yoff = ui_layout::kTopBand;  // (10.25) the old layout starts under the strip at the top (the strip is made at the end of this function)
    make(L"STATIC", L"RE7 folder:", 0, 0, 12, 16, 80, 20, -1);
    g.gamedir = make(L"EDIT", L"", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 96, 12, 296, 24, IDC_GAMEDIR);
    make(L"BUTTON", L"Browse...", BS_PUSHBUTTON | tab, 0, 400, 11, 80, 26, IDC_BROWSE);
    make(L"BUTTON", L"Detect", BS_PUSHBUTTON | tab, 0, 486, 11, 82, 26, IDC_DETECT);

    make(L"STATIC", L"Mode:", 0, 0, 12, 52, 80, 20, -1);
    make(L"BUTTON", L"Ethan's friend (play alone)", BS_AUTORADIOBUTTON | WS_GROUP | tab, 0, 96, 50, 220, 22,
         IDC_MODE_LOOP);
    make(L"BUTTON", L"Network (real peer)", BS_AUTORADIOBUTTON, 0, 330, 50, 238, 22, IDC_MODE_NET);

    make(L"STATIC", L"Connection:", 0, 0, 12, 84, 80, 20, -1);
    make(L"BUTTON", L"TCP: I host", BS_AUTORADIOBUTTON | WS_GROUP | tab, 0, 96, 82, 100, 22, IDC_TR_HOST);
    make(L"BUTTON", L"TCP: I join", BS_AUTORADIOBUTTON, 0, 202, 82, 100, 22, IDC_TR_JOIN);
    make(L"BUTTON", L"Steam invites", BS_AUTORADIOBUTTON, 0, 308, 82, 112, 22, IDC_TR_STEAM);  // 10.10
    g.conn_note = make(L"STATIC", L"(e.g. a Radmin VPN address)", 0, 0, 426, 86, 242 + kExtraW, 20, IDC_CONN_NOTE);

    // 10.10: Steam invites uses this row instead of Port / Other player (update_enabled shows one set and hides the other)
    g.steam_lbl = make(L"STATIC", L"Friend's ID:", 0, 0, 12, 118, 84, 20, IDC_STEAM_LBL);
    g.steam_id = make(L"EDIT", L"", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 96, 114, 236 + kExtraW, 24, IDC_STEAM_ID);
    g.steam_pick = make(L"BUTTON", L"Pick a friend...", BS_PUSHBUTTON | tab, 0, 338 + kExtraW, 113, 124, 26, IDC_STEAM_PICK);
    g.steam_copy = make(L"BUTTON", L"Copy my invite", BS_PUSHBUTTON | tab, 0, 468 + kExtraW, 113, 200, 26, IDC_STEAM_COPY);
    g.lbl_port = make(L"STATIC", L"Port:", 0, 0, 12, 118, 84, 20, IDC_PORT_LBL);
    g.port = make(L"EDIT", L"27015", ES_AUTOHSCROLL | ES_NUMBER | tab, WS_EX_CLIENTEDGE, 96, 114, 70, 24, IDC_PORT);
    g.lbl_peer = make(L"STATIC", L"Other player (ip:port):", 0, 0, 176, 118, 156, 20, IDC_LBL_PEER);
    g.peer = make(L"EDIT", L"", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 334, 114, 334 + kExtraW, 24, IDC_PEER);

    make(L"STATIC", L"Your name:", 0, 0, 12, 152, 80, 20, -1);
    g.name = make(L"EDIT", L"Player", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 96, 148, 200, 24, IDC_NAME);
    SendMessageW(g.name, EM_SETLIMITTEXT, 24, 0);
    make(L"STATIC", L"(shown above you on the other player's screen)", 0, 0, 304, 152, 364 + kExtraW, 20, -1);

    make(L"STATIC", L"Save folder:", 0, 0, 12, 190, 80, 20, -1);
    g.savedir = make(L"EDIT", L"", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 96, 186, 244, 24, IDC_SAVEDIR);
    make(L"BUTTON", L"Detect", BS_PUSHBUTTON | tab, 0, 346, 185, 70, 26, IDC_SAVE_DETECT);
    make(L"BUTTON", L"Share saves", BS_AUTOCHECKBOX | tab, 0, 424, 188, 144, 22, IDC_SAVE_SHARE);

    // 9.33: story sync (EXPERIMENTAL): one box for story sync, FORCE and both moves; written to re7mp_story.json for the script. Starts off.
    make(L"BUTTON", L"Sync story cutscenes (experimental): a cutscene plays for both of you", BS_AUTOCHECKBOX | tab, 0, 96, 212, 572 + kExtraW, 22, IDC_STORY);
    // 10.19: enemies and the Molded (the host runs them, the joiner's copies are put onto the host's); written to re7mp_enemysync.json for the script. Starts ON.
    make(L"BUTTON", L"Sync enemies and the Molded (the host runs them; the garage car needs it)", BS_AUTOCHECKBOX | tab, 0, 96, 233, 572 + kExtraW, 17, IDC_ENEMY);

    // (10.26) The follows / stays put / beside you radios are gone: that choice is the F5 key in the game now (the script shows "F5 ..." in a corner of the
    // screen and tells this program). What stays here is the button, moved up next to the label, and a one-line note where the radios were.
    make(L"STATIC", L"Ethan's friend:", 0, 0, 12, 252, 84, 20, -1);
    make(L"BUTTON", L"Move friend to me", BS_PUSHBUTTON | tab, 0, 96, 248, 136, 26, IDC_BOT_TELE);
    make(L"STATIC", L"In the game, F5 switches it between following you and staying put.", 0, 0, 242, 252, 418 + kExtraW, 20, -1);

    // 9.31: which character this player is shown as to the other player (re7mp_char.json, read by the script). Unbuilt/untested in the real
    // game: the window code cannot be compiled where this was written; the file writing it uses (character.hpp) is tested.
    g.playas_label = make(L"STATIC", L"Play as:", 0, 0, 12, 290, 80, 20, -1);
    g.playas = make(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | tab, 0, 96, 286, 250, 160, IDC_PLAYAS);
    for (const auto& c : character_choices()) SendMessageW(g.playas, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(widen(c.label).c_str()));
    SendMessageW(g.playas, CB_SETCURSEL, 0, 0);
    g.playas_note = make(L"STATIC", L"(the other player sees you as this)", 0, 0, 354, 282, 314 + kExtraW, 36, -1);  // 10.5: both texts change with the mode (show_playas_for_mode)

    g.start = make(L"BUTTON", L"Start", BS_DEFPUSHBUTTON | tab, 0, 12, 322, 120, 32, IDC_START);
    make(L"BUTTON", L"Install / update mod", BS_PUSHBUTTON | tab, 0, 140, 322, 150, 32, IDC_INSTALL);
    make(L"BUTTON", L"Open data folder", BS_PUSHBUTTON | tab, 0, 298, 322, 150, 32, IDC_OPEN_DATA);

    make(L"STATIC", L"Game hook:", 0, 0, 12, 370, 90, 20, -1);
    g.st_hook = make(L"STATIC", L"Not running", 0, 0, 110, 370, 558 + kExtraW, 20, IDC_ST_HOOK);
    make(L"STATIC", L"Other player:", 0, 0, 12, 394, 90, 20, -1);
    g.st_peer = make(L"STATIC", L"-", 0, 0, 110, 394, 558 + kExtraW, 20, IDC_ST_PEER);
    make(L"STATIC", L"Your position:", 0, 0, 12, 418, 90, 20, -1);
    g.st_local = make(L"STATIC", L"-", 0, 0, 110, 418, 558 + kExtraW, 20, IDC_ST_LOCAL);
    make(L"STATIC", L"Their position:", 0, 0, 12, 442, 90, 20, -1);
    g.st_remote = make(L"STATIC", L"-", 0, 0, 110, 442, 558 + kExtraW, 20, IDC_ST_REMOTE);
    make(L"STATIC", L"Packets:", 0, 0, 12, 466, 90, 20, -1);
    g.st_pkts = make(L"STATIC", L"-", 0, 0, 110, 466, 558 + kExtraW, 20, IDC_ST_PKTS);
    make(L"STATIC", L"Co-op saves:", 0, 0, 12, 490, 90, 20, -1);
    g.st_save = make(L"STATIC", L"-", 0, 0, 110, 490, 558 + kExtraW, 36, IDC_ST_SAVE);  // 10.9: two lines high (a long save message wrapped and was cut off)

    make(L"STATIC", L"Updates:", 0, 0, 12, 530, 90, 20, -1);
    g.upd_st = make(L"STATIC", L"Not checked yet.", 0, 0, 110, 530, 440 + kExtraW, 20, IDC_UPD_ST);
    make(L"BUTTON", L"Check now", BS_PUSHBUTTON | tab, 0, 556 + kExtraW, 526, 112, 26, IDC_UPD_BTN);
    // 10.8: the "REFramework:" row (its status and its own Install button) is gone: "Install / update mod" above does the same and asks first
    make(L"BUTTON", L"Check for updates when this opens", BS_AUTOCHECKBOX | tab, 0, 110, 558, 300, 22, IDC_UPD_AUTO);
    // (10.24) the alpha channel: everyone starts on the normal releases; this button joins the alpha (after a warning window) or leaves it
    make(L"BUTTON", L"Join the alpha...", BS_PUSHBUTTON | tab, 0, 416 + kExtraW, 555, 252, 26, IDC_ALPHA_BTN);

    g.log = make(L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL, WS_EX_CLIENTEDGE, 12, 588, 656 + kExtraW,
                 g_log_h, IDC_LOG);  // (10.25) wider, and taller unless the screen is small (fit_log_height)
    SendMessageW(g.log, EM_SETLIMITTEXT, 200000, 0);

    // (10.25) THE TOP STRIP (y = 0 to kTopBand, so g_yoff is 0 for it): two boxes for features that are only being PREPARED, and the line that says so.
    // They do nothing: load_ini ticks them from re7mp.ini, a click saves them and shows the warning (on_future_box). Made last, so Tab still starts in
    // the old controls and the boxes come at the end of the tab order.
    g_yoff = 0;
    make(L"STATIC", widen(future_band_title()).c_str(), 0, 0, 12, 11, 90, 20, -1);
    make(L"BUTTON", widen(future_label(FutureFeature::BioRand)).c_str(), BS_AUTOCHECKBOX | tab, 0, 104, 8, 250, 22, IDC_FUT_BIORAND);
    make(L"BUTTON", widen(future_label(FutureFeature::Vr)).c_str(), BS_AUTOCHECKBOX | tab, 0, 364, 8, 170, 22, IDC_FUT_VR);
    make(L"STATIC", widen(future_band_note()).c_str(), 0, 0, 12, 36, ui_layout::kClientW - 24, 34, -1);  // two lines
    make(L"STATIC", L"", SS_ETCHEDHORZ, 0, 12, 74, ui_layout::kClientW - 24, 2, -1);                    // the divider under the strip
    g_yoff = ui_layout::kTopBand;

    EnumChildWindows(g.hwnd, set_font_proc, 0);
}

constexpr UINT kMsgStartup = WM_APP + 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case kMsgStartup: {
            apply_channel(true);  // (10.24) which channel and build this exe is, for the script (its panel and the debug file say it)
            // 10.1: only after an update does the new program run the whole install once (REFramework version, script, data, models).
            // Every other start leaves the game folder alone; the Install button does it when it is wanted.
            fs::path game;
            if (game_dir_ok(game) && !g.ui_running && wcsstr(GetCommandLineW(), L"--updated") != nullptr) install_script(game);
            return 0;
        }
        case WM_CREATE: {
            g.hwnd = hwnd;
            create_controls();
            load_ini();
            fs::path existing;
            if (!game_dir_ok(existing)) detect_game(true);
            fix_save_dir_for_active_account();
            if (get_text(g.savedir).empty()) detect_save_dir(true);
            if (get_text(g.savedir).empty()) {  // no Steam save folder found: nothing to share, so it starts off
                CheckDlgButton(g.hwnd, IDC_SAVE_SHARE, BST_UNCHECKED);
                log_line("Save sharing is off: no Steam save folder was found" + (g_save_dir_why.empty() ? std::string() : " (" + g_save_dir_why + ")") +
                         " (tick it after typing or detecting the folder).");
            }
            fs::path game;
            if (game_dir_ok(game)) {
                log_line("RE7 folder: " + game.u8string());
            } else {
                log_line("Click Detect (or Browse) to point this at your RE7 folder.");
            }
            log_line(std::string("RE7 Multiplayer v") + kReleaseVersion + " (protocol " +
                     std::to_string(static_cast<int>(kProtocolVersion)) + ")");
            if (!g_alpha.note.empty()) log_line(g_alpha.note);  // (10.24)
            if (g_alpha.on) log_line("Alpha channel: ON (" + exe_name() + ", build " + exe_build() + ", source github.com/" + g_alpha.repo + "). \"Leave the alpha...\" goes back to the normal releases.");
            {  // (10.25) a "coming later" box ticked from last time: said once, so "it did nothing" has its reason in the log
                const std::string fut = future_startup_line(IsDlgButtonChecked(g.hwnd, IDC_FUT_BIORAND) == BST_CHECKED, IsDlgButtonChecked(g.hwnd, IDC_FUT_VR) == BST_CHECKED);
                if (!fut.empty()) log_line(fut);
            }
            {
                wchar_t me[MAX_PATH * 2];
                const DWORD len = GetModuleFileNameW(nullptr, me, static_cast<DWORD>(sizeof(me) / sizeof(me[0])));
                cleanup_old_exe(fs::path(std::wstring(me, len)));  // the previous version, left by the last update
                if (wcsstr(GetCommandLineW(), L"--updated") != nullptr) {
                    log_line(std::string("Updated: this is now version ") + kReleaseVersion + ".");
                }
                PostMessageW(hwnd, kMsgStartup, 0, 0);  // 9.45: the script follows the program (see below)
                wchar_t opt[16];
                GetPrivateProfileStringW(L"re7mp", L"include_prerelease", L"0", opt, 16, ini_path().c_str());
                upd.include_prerelease = lstrcmpiW(opt, L"1") == 0;  // for playtesters only: not offered in the window
                GetPrivateProfileStringW(L"re7mp", L"reframework_files", L"all", opt, 16, ini_path().c_str());
                upd.refw_dll_only = lstrcmpiW(opt, L"dll") == 0;     // "dll" = only dinput8.dll, not the whole package
            }
            if (IsDlgButtonChecked(g.hwnd, IDC_UPD_AUTO) == BST_CHECKED) start_update_check();
            log_line("Tip: Ethan's friend needs no second player and no network. Start it, run RE7, load a save, and your friend should walk up to you; \"Appear as\" is what it looks like.");
            update_enabled();
            SetTimer(hwnd, kTimerId, 200, nullptr);
            return 0;
        }
        case kMsgFriends:
            show_friends_menu();
            return 0;
        case WM_COMMAND: {
            const int id = LOWORD(wp);
            switch (id) {
                case IDC_BROWSE: browse_game(); break;
                case IDC_DETECT: detect_game(false); break;
                case IDC_MODE_LOOP:
                case IDC_MODE_NET:
                case IDC_TR_HOST:
                case IDC_TR_JOIN:
                case IDC_TR_STEAM: update_enabled(); break;
                case IDC_STEAM_PICK: start_friends_fetch(); break;
                case IDC_STEAM_COPY: copy_my_invite(); break;
                case IDC_BOT_TELE:
                    if (g.ui_running) g.engine.teleport_bot_here();
                    break;
                case IDC_PLAYAS:
                    if (HIWORD(wp) == CBN_SELCHANGE) {
                        if (g.playas_friend) {  // 10.5: Ethan's friend mode: this is the friend's look (the engine says so in the log), not your character
                            if (g.ui_running) g.engine.set_bot_character(friend_look_key());
                        } else {
                            apply_character(false);
                        }
                        save_ini();
                    }
                    break;
                case IDC_STORY:
                    apply_story_sync(false);
                    save_ini();
                    break;
                case IDC_ENEMY:  // 10.19
                    apply_enemy_sync(false);
                    save_ini();
                    break;
                case IDC_NAME:
                    if (HIWORD(wp) == EN_CHANGE && g.ui_running) g.engine.set_name(narrow(get_text(g.name)));
                    break;
                case IDC_SAVE_DETECT: detect_save_dir(false); break;
                case IDC_UPD_BTN: on_update_button(); break;
                case IDC_ALPHA_BTN: on_alpha_button(); break;  // (10.24)
                case IDC_FUT_BIORAND: on_future_box(FutureFeature::BioRand); break;  // (10.25) saved only
                case IDC_FUT_VR: on_future_box(FutureFeature::Vr); break;            // (10.25) saved only
                case IDC_OPEN_DATA: {  // where debug.json (the file to send to the developer) lives
                    fs::path game;
                    if (game_dir_ok(game)) {
                        const fs::path data = data_dir_for(game);
                        std::error_code ec;
                        fs::create_directories(data, ec);
                        // 9.30: the script's own files (debug.json, settings.json ...) are in the re7mp folder inside it, once the game has made it
                        fs::path show = data / "re7mp";
                        if (!fs::is_directory(show, ec)) show = data;
                        ShellExecuteW(g.hwnd, L"open", show.wstring().c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                    } else {
                        log_line("Pick your RE7 folder first.");
                    }
                    break;
                }
                case IDC_INSTALL: {
                    fs::path game;
                    if (game_dir_ok(game)) install_script(game);
                    else log_line("Pick your RE7 folder first.");
                    break;
                }
                case IDC_START:
                    if (g.ui_running) do_stop();
                    else do_start();
                    break;
                default: break;
            }
            return 0;
        }
        case WM_TIMER:
            if (wp == kTimerId) refresh_status();
            return 0;
        case WM_CLOSE: {
            bool busy;
            {
                std::lock_guard<std::mutex> lk(upd.mu);
                busy = upd.refw_busy;
            }
            if (busy) {  // closing now would leave REFramework half installed
                MessageBoxW(hwnd, L"REFramework is still being installed. Please wait a few seconds and close again.",
                            L"RE7 Multiplayer", MB_ICONINFORMATION);
                return 0;
            }
            break;
        }
        case WM_DESTROY:
            KillTimer(hwnd, kTimerId);
            g.engine.stop();
            save_ini();
            PostQuitMessage(0);
            return 0;
        default: break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

}  // namespace

int WINAPI WinMain(HINSTANCE inst, HINSTANCE, LPSTR, int show) {
    SetProcessDPIAware();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);

    g.inst = inst;
    HDC dc = GetDC(nullptr);
    g.dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(nullptr, dc);

    NONCLIENTMETRICSW ncm{};
    ncm.cbSize = sizeof(ncm);
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
    g.font = CreateFontIndirectW(&ncm.lfMessageFont);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    // (10.13) the program's own icon (app.rc), at the sizes this window and the taskbar ask for; the stock one only if it is not in this build
    wc.hIcon = static_cast<HICON>(LoadImageW(inst, MAKEINTRESOURCEW(kIconResourceId), IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_DEFAULTCOLOR));
    wc.hIconSm = static_cast<HICON>(LoadImageW(inst, MAKEINTRESOURCEW(kIconResourceId), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
    if (!wc.hIcon) wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(static_cast<INT_PTR>(COLOR_BTNFACE + 1));
    wc.lpszClassName = L"RE7MPWindow";
    RegisterClassExW(&wc);

    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    // (10.25) The window is bigger (it was 680 x 750). Its height is the strip at the top + the old layout + the log; the log is the one part that can
    // shrink, so that on a small or heavily scaled screen the window still fits above the task bar (fit_log_height).
    {
        RECT work{0, 0, 0, 1080};
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        RECT frame{0, 0, 0, 0};
        AdjustWindowRectEx(&frame, style, FALSE, 0);  // what the title bar and borders add around a client area of nothing
        const int avail_px = (work.bottom - work.top) - (frame.bottom - frame.top);
        g_log_h = ui_layout::fit_log_height(MulDiv(avail_px, 96, g.dpi));
    }
    RECT r{0, 0, S(ui_layout::kClientW), S(ui_layout::client_height(g_log_h))};
    AdjustWindowRectEx(&r, style, FALSE, 0);
    const std::wstring title = L"RE7 Multiplayer v" + widen(kReleaseVersion);
    HWND hwnd = CreateWindowExW(0, L"RE7MPWindow", title.c_str(), style, CW_USEDEFAULT, CW_USEDEFAULT,
                                r.right - r.left, r.bottom - r.top, nullptr, nullptr, inst, nullptr);
    if (!hwnd) return 1;
    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);

    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(hwnd, &m)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
    return static_cast<int>(m.wParam);
}
