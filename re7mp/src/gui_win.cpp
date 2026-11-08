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
#include "game_locator.hpp"
#include "http_win.hpp"
#include "packet.hpp"
#include "save_sync.hpp"
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

constexpr int kLuaResourceId = 101;  // must match app.rc
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
    IDC_BOT_ORBIT = 1021,  // IDC_BOT_ORBIT and IDC_BOT_STAT must stay consecutive
    IDC_BOT_STAT = 1022,
    IDC_BOT_TELE = 1023,
    IDC_OPEN_DATA = 1024,
    IDC_SAVEDIR = 1025,
    IDC_SAVE_DETECT = 1026,
    IDC_SAVE_SHARE = 1027,
    IDC_ST_SAVE = 1028,
    IDC_UPD_ST = 1029,
    IDC_UPD_BTN = 1030,
    IDC_REFW_ST = 1031,
    IDC_REFW_BTN = 1032,
    IDC_UPD_AUTO = 1033,
};

struct App {
    HINSTANCE inst = nullptr;
    HWND hwnd = nullptr;
    HWND gamedir = nullptr, peer = nullptr, port = nullptr, start = nullptr, log = nullptr, name = nullptr;
    HWND savedir = nullptr, st_save = nullptr;
    HWND upd_st = nullptr, refw_st = nullptr;
    HWND lbl_peer = nullptr;
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

Transport selected_transport() {
    if (IsDlgButtonChecked(g.hwnd, IDC_TR_HOST) == BST_CHECKED) return Transport::TcpHost;
    if (IsDlgButtonChecked(g.hwnd, IDC_TR_JOIN) == BST_CHECKED) return Transport::TcpJoin;
    return Transport::TcpHost;
}

BotMode selected_bot_mode() {
    return IsDlgButtonChecked(g.hwnd, IDC_BOT_STAT) == BST_CHECKED ? BotMode::Stationary : BotMode::Orbit;
}

void save_ini() {
    const std::wstring p = ini_path();
    WritePrivateProfileStringW(L"re7mp", L"game_dir", get_text(g.gamedir).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"mode", network_mode_selected() ? L"network" : L"loopback", p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"listen", get_text(g.port).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"peer", get_text(g.peer).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"name", get_text(g.name).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"save_dir", get_text(g.savedir).c_str(), p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"share_saves",
                               IsDlgButtonChecked(g.hwnd, IDC_SAVE_SHARE) == BST_CHECKED ? L"1" : L"0", p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"check_updates",
                               IsDlgButtonChecked(g.hwnd, IDC_UPD_AUTO) == BST_CHECKED ? L"1" : L"0", p.c_str());
    const Transport tr = selected_transport();
    WritePrivateProfileStringW(L"re7mp", L"transport", tr == Transport::TcpJoin ? L"tcp-join" : L"tcp-host", p.c_str());
    WritePrivateProfileStringW(L"re7mp", L"bot", selected_bot_mode() == BotMode::Stationary ? L"stationary" : L"orbit",
                               p.c_str());
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
    GetPrivateProfileStringW(L"re7mp", L"share_saves", L"0", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_SAVE_SHARE, lstrcmpiW(buf, L"1") == 0 ? BST_CHECKED : BST_UNCHECKED);
    GetPrivateProfileStringW(L"re7mp", L"check_updates", L"1", buf, 1024, p.c_str());
    CheckDlgButton(g.hwnd, IDC_UPD_AUTO, lstrcmpiW(buf, L"0") == 0 ? BST_UNCHECKED : BST_CHECKED);
    GetPrivateProfileStringW(L"re7mp", L"mode", L"loopback", buf, 1024, p.c_str());
    CheckRadioButton(g.hwnd, IDC_MODE_LOOP, IDC_MODE_NET, lstrcmpiW(buf, L"network") == 0 ? IDC_MODE_NET : IDC_MODE_LOOP);
    GetPrivateProfileStringW(L"re7mp", L"transport", L"tcp-host", buf, 1024, p.c_str());
    // an old re7mp.ini may still say "udp": that choice is gone, so it becomes "I host"
    CheckRadioButton(g.hwnd, IDC_TR_HOST, IDC_TR_JOIN, lstrcmpiW(buf, L"tcp-join") == 0 ? IDC_TR_JOIN : IDC_TR_HOST);
    GetPrivateProfileStringW(L"re7mp", L"bot", L"orbit", buf, 1024, p.c_str());
    CheckRadioButton(g.hwnd, IDC_BOT_ORBIT, IDC_BOT_STAT, lstrcmpiW(buf, L"stationary") == 0 ? IDC_BOT_STAT : IDC_BOT_ORBIT);
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

std::optional<fs::path> find_save_dir_via_steam() {
    std::vector<fs::path> roots;
    wchar_t buf[MAX_PATH * 2];
    DWORD size = sizeof(buf);  // bytes
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath", RRF_RT_REG_SZ, nullptr, buf, &size) ==
        ERROR_SUCCESS) {
        roots.emplace_back(std::wstring(buf));
    }
    roots.emplace_back(L"C:\\Program Files (x86)\\Steam");
    for (const auto& r : roots) {
        const auto dirs = find_save_dirs(r);
        if (!dirs.empty()) return dirs.front();
    }
    return std::nullopt;
}

bool detect_save_dir(bool quiet) {
    if (auto p = find_save_dir_via_steam()) {
        SetWindowTextW(g.savedir, p->wstring().c_str());
        log_line("Found your save folder: " + p->u8string());
        return true;
    }
    if (!quiet) log_line("Could not find the save folder (...\\userdata\\<id>\\418370\\remote\\win64_save). Type it in.");
    return false;
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

std::string load_lua_resource() {
    HRSRC res = FindResourceW(nullptr, MAKEINTRESOURCEW(kLuaResourceId), RT_RCDATA);
    if (!res) return {};
    HGLOBAL mem = LoadResource(nullptr, res);
    if (!mem) return {};
    const DWORD size = SizeofResource(nullptr, res);
    const char* data = static_cast<const char*>(LockResource(mem));
    if (!data) return {};
    return std::string(data, size);
}

bool game_dir_ok(fs::path& out) {
    const std::wstring t = get_text(g.gamedir);
    std::error_code ec;
    if (t.empty() || !fs::is_directory(fs::path(t), ec)) return false;
    out = fs::path(t);
    return true;
}

void start_refw_install(bool replace);
void do_stop();

bool install_script(const fs::path& game) {
    if (!looks_like_re7(game)) log_line("Warning: re7.exe was not found in that folder. Is it the RE7 install folder?");
    if (!refw_installed(game)) {
        log_line("Warning: REFramework (dinput8.dll) is not in that folder, so the Lua script won't run until it is installed.");
        static std::wstring asked_for;  // ask once per folder per run, not on every Start
        if (asked_for != game.wstring()) {
            asked_for = game.wstring();
            const std::wstring q = L"REFramework is not installed in this folder, and the mod needs it to run.\n\nDownload and install REFramework " +
                                   widen(kReframeworkTag) + L" now?";
            if (MessageBoxW(g.hwnd, q.c_str(), L"RE7 Multiplayer", MB_YESNO | MB_ICONQUESTION) == IDYES) start_refw_install(false);
        }
    }
    const std::string lua = load_lua_resource();
    if (lua.empty()) {
        log_line("This exe has no embedded Lua script. Copy lua\\re7mp.lua to reframework\\autorun manually.");
        return false;
    }
    const InstallResult r = install_lua(game, lua);
    log_line(r.message);
    return r.ok;
}

// ---------------------------------------------------------------- start / stop

void update_enabled() {
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
    EnableWindow(GetDlgItem(g.hwnd, IDC_INSTALL), idle);
    EnableWindow(g.port, idle);
    EnableWindow(g.savedir, idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_SAVE_DETECT), idle);
    EnableWindow(GetDlgItem(g.hwnd, IDC_SAVE_SHARE), idle);
    EnableWindow(g.peer, idle && net);
    EnableWindow(g.lbl_peer, idle && net);
    SetWindowTextW(g.lbl_peer, tr == Transport::TcpHost ? L"Only allow (ip, optional):" : L"Other player (ip:port):");
    // The loopback bot can be changed while it runs.
    EnableWindow(GetDlgItem(g.hwnd, IDC_BOT_ORBIT), !net);
    EnableWindow(GetDlgItem(g.hwnd, IDC_BOT_STAT), !net);
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
    fs::path game;
    if (!game_dir_ok(game)) {
        MessageBoxW(g.hwnd, L"Pick your RE7 folder first (Detect or Browse).", L"RE7 Multiplayer", MB_ICONINFORMATION);
        return;
    }
    const long port = std::wcstol(get_text(g.port).c_str(), nullptr, 10);
    if (port < 1 || port > 65534) {
        MessageBoxW(g.hwnd, L"The port must be between 1 and 65534.", L"RE7 Multiplayer", MB_ICONINFORMATION);
        return;
    }
    Config cfg;
    cfg.data_dir = data_dir_for(game);
    cfg.listen_port = static_cast<uint16_t>(port);
    cfg.mode = network_mode_selected() ? Mode::Network : Mode::Loopback;
    cfg.name = narrow(get_text(g.name));
    cfg.transport = selected_transport();
    cfg.bot_mode = selected_bot_mode();
    cfg.save_sync = IsDlgButtonChecked(g.hwnd, IDC_SAVE_SHARE) == BST_CHECKED;
    cfg.save_dir = fs::path(get_text(g.savedir));
    if (cfg.mode == Mode::Network) {
        const std::wstring peer_text = get_text(g.peer);
        const bool peer_optional = cfg.transport == Transport::TcpHost;  // a host may accept anyone
        if (!(peer_optional && peer_text.empty()) && !parse_peer(peer_text, cfg)) {
            MessageBoxW(g.hwnd, L"Enter the other player's address as ip:port, for example 203.0.113.5:27015.",
                        L"RE7 Multiplayer", MB_ICONINFORMATION);
            return;
        }
    }

    install_script(game);

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
    std::vector<uint8_t> exe;      // the downloaded program, waiting to be swapped in
    std::deque<std::string> log;   // lines for the log box (it can only be written from the GUI thread)
    bool include_prerelease = false;  // re7mp.ini: include_prerelease=1 (playtesters who were given that option)
    bool refw_dll_only = false;       // re7mp.ini: reframework_files=dll
    bool refw_busy = false;           // an install is running
    bool refw_state_busy = false;     // the folder is being looked at
    bool refw_known = false;
    RefwState refw_state;
    std::wstring refw_for;            // the folder refw_state describes
    std::string refw_progress;
};
Updates upd;

std::string user_agent() { return std::string("re7mp/") + kReleaseVersion; }

void start_update_check() {
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        if (upd.phase == Updates::Phase::Checking || upd.phase == Updates::Phase::Downloading ||
            upd.phase == Updates::Phase::Ready) {
            return;
        }
        upd.phase = Updates::Phase::Checking;
        upd.status = "Checking for updates...";
    }
    const bool pre = upd.include_prerelease;
    std::thread([pre] {
        auto http = make_winhttp_client(user_agent());
        const UpdateCheck c = check_for_update(*http, kReleaseVersion, pre);
        std::lock_guard<std::mutex> lk(upd.mu);
        upd.release = c.release;
        if (c.state == UpdateCheck::State::Available) {
            upd.phase = Updates::Phase::Available;
            upd.status = "Version " + c.release.version + " is available (you have " + kReleaseVersion + ").";
            upd.log.push_back("Update available: version " + c.release.version + ". Click the button in the Updates row to install it.");
        } else if (c.state == UpdateCheck::State::UpToDate) {
            upd.phase = Updates::Phase::UpToDate;
            upd.status = std::string("Up to date (v") + kReleaseVersion + ").";
        } else {
            upd.phase = Updates::Phase::Failed;
            upd.status = c.message;
            upd.log.push_back(c.message);
        }
    }).detach();
}

void start_update_download() {
    ReleaseInfo rel;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        if (upd.phase != Updates::Phase::Available) return;
        upd.phase = Updates::Phase::Downloading;
        upd.status = "Downloading version " + upd.release.version + "...";
        rel = upd.release;
    }
    std::thread([rel] {
        auto http = make_winhttp_client(user_agent());
        std::vector<uint8_t> exe;
        std::string err;
        const bool ok = fetch_new_exe(*http, rel, exe, err, [](uint64_t got, uint64_t total) {
            std::lock_guard<std::mutex> lk(upd.mu);
            upd.status = total != 0 ? "Downloading... " + std::to_string(got * 100 / total) + "%"
                                    : "Downloading... " + std::to_string(got / 1024) + " KB";
        });
        std::lock_guard<std::mutex> lk(upd.mu);
        if (ok) {
            upd.exe = std::move(exe);
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
    std::vector<uint8_t> exe;
    std::string version;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        exe = std::move(upd.exe);
        version = upd.release.version;
        upd.phase = Updates::Phase::Idle;  // so this runs once
    }
    if (g.ui_running) do_stop();
    wchar_t buf[MAX_PATH * 2];
    const DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
    const fs::path me(std::wstring(buf, n));
    std::string err;
    if (!swap_in_new_exe(me, exe, err)) {
        std::lock_guard<std::mutex> lk(upd.mu);
        upd.phase = Updates::Phase::Failed;
        upd.status = "Update failed: " + err;
        upd.log.push_back("Update failed: " + err);
        upd.log.push_back(std::string("You can download it yourself from ") + kReleasesPage);
        return;
    }
    log_line("Updated to version " + version + ". Restarting...");
    save_ini();  // so the new program starts with the same settings
    const HINSTANCE r = ShellExecuteW(g.hwnd, L"open", me.wstring().c_str(), L"--updated", me.parent_path().wstring().c_str(), SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(r) <= 32) {
        MessageBoxW(g.hwnd, L"re7mp.exe was updated. Please start it again.", L"RE7 Multiplayer", MB_ICONINFORMATION);
    }
    DestroyWindow(g.hwnd);
}

void start_refw_install(bool replace) {
    fs::path game;
    if (!game_dir_ok(game)) {
        log_line("Pick your RE7 folder first.");
        return;
    }
    if (find_running_re7()) {
        MessageBoxW(g.hwnd, L"Close Resident Evil 7 first: the game is using REFramework's files right now.", L"RE7 Multiplayer",
                    MB_ICONINFORMATION);
        return;
    }
    bool dll_only;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        if (upd.refw_busy) return;
        upd.refw_busy = true;
        upd.refw_progress = "Downloading REFramework...";
        dll_only = upd.refw_dll_only;
    }
    log_line(std::string("Installing REFramework ") + kReframeworkTag + " into " + game.u8string() + " ...");
    std::thread([game, replace, dll_only] {
        auto http = make_winhttp_client(user_agent());
        std::string msg;
        const bool ok = install_reframework(*http, game, kReframeworkTag, replace, dll_only, msg, [](uint64_t got, uint64_t total) {
            std::lock_guard<std::mutex> lk(upd.mu);
            upd.refw_progress = total != 0 ? "Downloading REFramework... " + std::to_string(got * 100 / total) + "%"
                                           : "Downloading REFramework... " + std::to_string(got / 1024) + " KB";
        });
        std::lock_guard<std::mutex> lk(upd.mu);
        upd.log.push_back(msg);
        if (ok) upd.log.push_back("REFramework is ready. Start the game once so it can create its settings, then load a save.");
        upd.refw_busy = false;
        upd.refw_for.clear();  // look at the folder again
    }).detach();
}

void set_button_text(int slot, HWND h, const std::wstring& text) {
    if (g.shown[slot] == text) return;
    g.shown[slot] = text;
    SetWindowTextW(h, text.c_str());
}

void refresh_updates() {
    std::vector<std::string> lines;
    std::string status, refw_progress;
    Updates::Phase phase;
    std::string version;
    bool refw_busy, refw_known;
    RefwState refw_state;
    bool look = false;
    const std::wstring folder = get_text(g.gamedir);
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        while (!upd.log.empty()) {
            lines.push_back(std::move(upd.log.front()));
            upd.log.pop_front();
        }
        status = upd.status;
        phase = upd.phase;
        version = upd.release.version;
        refw_busy = upd.refw_busy;
        refw_known = upd.refw_known;
        refw_state = upd.refw_state;
        refw_progress = upd.refw_progress;
        if (!upd.refw_state_busy && !upd.refw_busy && folder != upd.refw_for) {
            upd.refw_state_busy = true;
            upd.refw_for = folder;
            look = true;
        }
    }
    for (const auto& l : lines) log_line(l);

    if (look) {  // the dll's checksum is read off the GUI thread
        fs::path game;
        const bool valid = game_dir_ok(game);
        if (!valid) {
            std::lock_guard<std::mutex> lk(upd.mu);
            upd.refw_known = false;
            upd.refw_state_busy = false;
        } else {
            std::thread([game] {
                const RefwState st = reframework_state(game);
                std::lock_guard<std::mutex> lk(upd.mu);
                upd.refw_state = st;
                upd.refw_known = true;
                upd.refw_state_busy = false;
            }).detach();
        }
    }

    set_status(6, g.upd_st, widen(status));
    std::wstring label = L"Check now";
    bool enable = true;
    switch (phase) {
        case Updates::Phase::Available: label = L"Update to v" + widen(version); break;
        case Updates::Phase::Checking: label = L"Checking..."; enable = false; break;
        case Updates::Phase::Downloading: label = L"Downloading..."; enable = false; break;
        case Updates::Phase::Ready: label = L"Restarting..."; enable = false; break;
        default: break;
    }
    set_button_text(7, GetDlgItem(g.hwnd, IDC_UPD_BTN), label);
    EnableWindow(GetDlgItem(g.hwnd, IDC_UPD_BTN), enable);

    std::wstring rtext, rlabel = L"Install";
    if (refw_busy) {
        rtext = widen(refw_progress);
        rlabel = L"Installing...";
    } else if (!refw_known) {
        rtext = L"Pick your RE7 folder first.";
    } else if (refw_state.kind == RefwState::Kind::Missing) {
        rtext = L"Not installed (the mod needs it). Click Install.";
    } else if (refw_state.kind == RefwState::Kind::InstalledByUs) {
        rtext = L"Installed: " + widen(refw_state.tag) + L" (by this program)";
        rlabel = L"Reinstall";
    } else {
        rtext = L"A dinput8.dll is already there (not put there by this program).";
        rlabel = L"Replace...";
    }
    set_status(8, g.refw_st, rtext);
    set_button_text(9, GetDlgItem(g.hwnd, IDC_REFW_BTN), rlabel);
    EnableWindow(GetDlgItem(g.hwnd, IDC_REFW_BTN), !refw_busy);

    if (phase == Updates::Phase::Ready) apply_update();
}

void on_update_button() {
    Updates::Phase phase;
    ReleaseInfo rel;
    {
        std::lock_guard<std::mutex> lk(upd.mu);
        phase = upd.phase;
        rel = upd.release;
    }
    if (phase == Updates::Phase::Available) {
        std::string notes = rel.notes;
        if (notes.size() > 700) notes = notes.substr(0, 700) + "...";
        const std::wstring q = L"Version " + widen(rel.version) + L" is available (you have " + widen(kReleaseVersion) +
                               L").\n\nWhat's new:\n" + widen(notes) +
                               L"\n\nDownload it and restart now? Your settings are kept. The other player needs the same version.";
        if (MessageBoxW(g.hwnd, q.c_str(), L"RE7 Multiplayer", MB_YESNO | MB_ICONQUESTION) == IDYES) start_update_download();
    } else if (phase == Updates::Phase::Idle || phase == Updates::Phase::UpToDate || phase == Updates::Phase::Failed) {
        start_update_check();
    }
}

void on_refw_button() {
    fs::path game;
    if (!game_dir_ok(game)) {
        log_line("Pick your RE7 folder first.");
        return;
    }
    bool replace = false;
    if (refw_installed(game)) {
        RefwState st;
        {
            std::lock_guard<std::mutex> lk(upd.mu);
            st = upd.refw_state;
        }
        if (st.kind != RefwState::Kind::InstalledByUs) {
            const std::wstring q = L"There is already a dinput8.dll in this folder (another REFramework version, or a different mod loader).\n\nReplace it with REFramework " +
                                   widen(kReframeworkTag) + L"? The old file is kept as dinput8.dll.bak.";
            if (MessageBoxW(g.hwnd, q.c_str(), L"RE7 Multiplayer", MB_YESNO | MB_ICONQUESTION) != IDYES) return;
        }
        replace = true;
    }
    start_refw_install(replace);
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
        if (loop) peer = st.peer_active ? L"Loopback player is active (orbiting you)" : L"Waiting for your first position";
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

HWND make(const wchar_t* cls, const wchar_t* text, DWORD style, DWORD ex, int x, int y, int w, int h, int id) {
    return CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, S(x), S(y), S(w), S(h), g.hwnd,
                           reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), g.inst, nullptr);
}

BOOL CALLBACK set_font_proc(HWND child, LPARAM) {
    SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(g.font), TRUE);
    return TRUE;
}

void create_controls() {
    const DWORD tab = WS_TABSTOP;
    make(L"STATIC", L"RE7 folder:", 0, 0, 12, 16, 80, 20, -1);
    g.gamedir = make(L"EDIT", L"", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 96, 12, 296, 24, IDC_GAMEDIR);
    make(L"BUTTON", L"Browse...", BS_PUSHBUTTON | tab, 0, 400, 11, 80, 26, IDC_BROWSE);
    make(L"BUTTON", L"Detect", BS_PUSHBUTTON | tab, 0, 486, 11, 82, 26, IDC_DETECT);

    make(L"STATIC", L"Mode:", 0, 0, 12, 52, 80, 20, -1);
    make(L"BUTTON", L"Loopback test (fake player)", BS_AUTORADIOBUTTON | WS_GROUP | tab, 0, 96, 50, 220, 22,
         IDC_MODE_LOOP);
    make(L"BUTTON", L"Network (real peer)", BS_AUTORADIOBUTTON, 0, 330, 50, 238, 22, IDC_MODE_NET);

    make(L"STATIC", L"Connection:", 0, 0, 12, 84, 80, 20, -1);
    make(L"BUTTON", L"TCP: I host", BS_AUTORADIOBUTTON | WS_GROUP | tab, 0, 96, 82, 100, 22, IDC_TR_HOST);
    make(L"BUTTON", L"TCP: I join", BS_AUTORADIOBUTTON, 0, 202, 82, 100, 22, IDC_TR_JOIN);
    make(L"STATIC", L"(e.g. a Tailscale address)", 0, 0, 310, 86, 258, 20, -1);

    make(L"STATIC", L"Port:", 0, 0, 12, 118, 84, 20, -1);
    g.port = make(L"EDIT", L"27015", ES_AUTOHSCROLL | ES_NUMBER | tab, WS_EX_CLIENTEDGE, 96, 114, 70, 24, IDC_PORT);
    g.lbl_peer = make(L"STATIC", L"Other player (ip:port):", 0, 0, 176, 118, 156, 20, IDC_LBL_PEER);
    g.peer = make(L"EDIT", L"", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 334, 114, 234, 24, IDC_PEER);

    make(L"STATIC", L"Your name:", 0, 0, 12, 152, 80, 20, -1);
    g.name = make(L"EDIT", L"Player", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 96, 148, 200, 24, IDC_NAME);
    SendMessageW(g.name, EM_SETLIMITTEXT, 24, 0);
    make(L"STATIC", L"(shown above you on the other player's screen)", 0, 0, 304, 152, 264, 20, -1);

    make(L"STATIC", L"Save folder:", 0, 0, 12, 190, 80, 20, -1);
    g.savedir = make(L"EDIT", L"", ES_AUTOHSCROLL | tab, WS_EX_CLIENTEDGE, 96, 186, 244, 24, IDC_SAVEDIR);
    make(L"BUTTON", L"Detect", BS_PUSHBUTTON | tab, 0, 346, 185, 70, 26, IDC_SAVE_DETECT);
    make(L"BUTTON", L"Share saves", BS_AUTOCHECKBOX | tab, 0, 424, 188, 144, 22, IDC_SAVE_SHARE);

    make(L"STATIC", L"Loopback bot:", 0, 0, 12, 226, 84, 20, -1);
    make(L"BUTTON", L"Orbits you", BS_AUTORADIOBUTTON | WS_GROUP | tab, 0, 96, 224, 100, 22, IDC_BOT_ORBIT);
    make(L"BUTTON", L"Stays put", BS_AUTORADIOBUTTON, 0, 206, 224, 100, 22, IDC_BOT_STAT);
    make(L"BUTTON", L"Move bot to me", BS_PUSHBUTTON | tab, 0, 316, 222, 140, 26, IDC_BOT_TELE);

    g.start = make(L"BUTTON", L"Start", BS_DEFPUSHBUTTON | tab, 0, 12, 262, 120, 32, IDC_START);
    make(L"BUTTON", L"Install Lua script", BS_PUSHBUTTON | tab, 0, 140, 262, 150, 32, IDC_INSTALL);
    make(L"BUTTON", L"Open data folder", BS_PUSHBUTTON | tab, 0, 298, 262, 150, 32, IDC_OPEN_DATA);

    make(L"STATIC", L"Game hook:", 0, 0, 12, 310, 90, 20, -1);
    g.st_hook = make(L"STATIC", L"Not running", 0, 0, 110, 310, 458, 20, IDC_ST_HOOK);
    make(L"STATIC", L"Other player:", 0, 0, 12, 334, 90, 20, -1);
    g.st_peer = make(L"STATIC", L"-", 0, 0, 110, 334, 458, 20, IDC_ST_PEER);
    make(L"STATIC", L"Your position:", 0, 0, 12, 358, 90, 20, -1);
    g.st_local = make(L"STATIC", L"-", 0, 0, 110, 358, 458, 20, IDC_ST_LOCAL);
    make(L"STATIC", L"Their position:", 0, 0, 12, 382, 90, 20, -1);
    g.st_remote = make(L"STATIC", L"-", 0, 0, 110, 382, 458, 20, IDC_ST_REMOTE);
    make(L"STATIC", L"Packets:", 0, 0, 12, 406, 90, 20, -1);
    g.st_pkts = make(L"STATIC", L"-", 0, 0, 110, 406, 458, 20, IDC_ST_PKTS);
    make(L"STATIC", L"Co-op saves:", 0, 0, 12, 430, 90, 20, -1);
    g.st_save = make(L"STATIC", L"-", 0, 0, 110, 430, 458, 20, IDC_ST_SAVE);

    make(L"STATIC", L"Updates:", 0, 0, 12, 458, 90, 20, -1);
    g.upd_st = make(L"STATIC", L"Not checked yet.", 0, 0, 110, 458, 340, 20, IDC_UPD_ST);
    make(L"BUTTON", L"Check now", BS_PUSHBUTTON | tab, 0, 456, 454, 112, 26, IDC_UPD_BTN);
    make(L"STATIC", L"REFramework:", 0, 0, 12, 486, 94, 20, -1);
    g.refw_st = make(L"STATIC", L"-", 0, 0, 110, 486, 340, 20, IDC_REFW_ST);
    make(L"BUTTON", L"Install", BS_PUSHBUTTON | tab, 0, 456, 482, 112, 26, IDC_REFW_BTN);
    make(L"BUTTON", L"Check for updates when this opens", BS_AUTOCHECKBOX | tab, 0, 110, 512, 300, 22, IDC_UPD_AUTO);

    g.log = make(L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL, WS_EX_CLIENTEDGE, 12, 542, 556,
                 150, IDC_LOG);
    SendMessageW(g.log, EM_SETLIMITTEXT, 200000, 0);

    EnumChildWindows(g.hwnd, set_font_proc, 0);
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_CREATE: {
            g.hwnd = hwnd;
            create_controls();
            load_ini();
            fs::path existing;
            if (!game_dir_ok(existing)) detect_game(true);
            if (get_text(g.savedir).empty()) detect_save_dir(true);
            fs::path game;
            if (game_dir_ok(game)) {
                log_line("RE7 folder: " + game.u8string());
            } else {
                log_line("Click Detect (or Browse) to point this at your RE7 folder.");
            }
            log_line(std::string("RE7 Multiplayer v") + kReleaseVersion + " (protocol " +
                     std::to_string(static_cast<int>(kProtocolVersion)) + ")");
            {
                wchar_t me[MAX_PATH * 2];
                const DWORD len = GetModuleFileNameW(nullptr, me, static_cast<DWORD>(sizeof(me) / sizeof(me[0])));
                cleanup_old_exe(fs::path(std::wstring(me, len)));  // the previous version, left by the last update
                if (wcsstr(GetCommandLineW(), L"--updated") != nullptr) {
                    log_line(std::string("Updated: this is now version ") + kReleaseVersion + ". Press Start to install the matching Lua script.");
                }
                wchar_t opt[16];
                GetPrivateProfileStringW(L"re7mp", L"include_prerelease", L"0", opt, 16, ini_path().c_str());
                upd.include_prerelease = lstrcmpiW(opt, L"1") == 0;  // for playtesters only: not offered in the window
                GetPrivateProfileStringW(L"re7mp", L"reframework_files", L"all", opt, 16, ini_path().c_str());
                upd.refw_dll_only = lstrcmpiW(opt, L"dll") == 0;     // "dll" = only dinput8.dll, not the whole package
            }
            if (IsDlgButtonChecked(g.hwnd, IDC_UPD_AUTO) == BST_CHECKED) start_update_check();
            log_line("Tip: Loopback mode needs no second player. Start it, run RE7, load a save, and a figure should orbit you and face you.");
            update_enabled();
            SetTimer(hwnd, kTimerId, 200, nullptr);
            return 0;
        }
        case WM_COMMAND: {
            const int id = LOWORD(wp);
            switch (id) {
                case IDC_BROWSE: browse_game(); break;
                case IDC_DETECT: detect_game(false); break;
                case IDC_MODE_LOOP:
                case IDC_MODE_NET:
                case IDC_TR_HOST:
                case IDC_TR_JOIN: update_enabled(); break;
                case IDC_BOT_ORBIT:
                case IDC_BOT_STAT:
                    if (g.ui_running) g.engine.set_bot_mode(selected_bot_mode());
                    break;
                case IDC_BOT_TELE:
                    if (g.ui_running) g.engine.teleport_bot_here();
                    break;
                case IDC_NAME:
                    if (HIWORD(wp) == EN_CHANGE && g.ui_running) g.engine.set_name(narrow(get_text(g.name)));
                    break;
                case IDC_SAVE_DETECT: detect_save_dir(false); break;
                case IDC_UPD_BTN: on_update_button(); break;
                case IDC_REFW_BTN: on_refw_button(); break;
                case IDC_OPEN_DATA: {  // where re7mp_debug.json (the file to send to the developer) lives
                    fs::path game;
                    if (game_dir_ok(game)) {
                        const fs::path data = data_dir_for(game);
                        std::error_code ec;
                        fs::create_directories(data, ec);
                        ShellExecuteW(g.hwnd, L"open", data.wstring().c_str(), nullptr, nullptr, SW_SHOWNORMAL);
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
    wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(static_cast<INT_PTR>(COLOR_BTNFACE + 1));
    wc.lpszClassName = L"RE7MPWindow";
    RegisterClassExW(&wc);

    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r{0, 0, S(580), S(704)};
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
