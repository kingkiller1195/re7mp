#pragma once
// (10.25) THE TOP OF THE WINDOW AND ITS SIZE, without the window: the two "coming later" boxes (BioRand 7 and VR) and the arithmetic of the bigger
// window. Everything here is plain text or plain numbers, so it is all tested (tests/core_tests.cpp, test_future_ui); gui_win.cpp only draws it.
//
//   * The two boxes do NOTHING yet. They are in the program so that it is ready for them: each one starts off, is saved in re7mp.ini (biorand=0|1,
//     vr=0|1) and shows a warning when it is ticked ("not implemented yet, we are only preparing"). Nothing is written for the script, the game never
//     hears of them, and nothing else in the program looks at them. When a feature is built, its box is the switch to hang it on.
//   * The window grew from 680 x 750 to kClientW x (870 at most). The old controls are the same controls: they moved down by kTopBand (the strip the
//     two boxes sit in) and the ones that used to reach the right edge got kExtraW wider. The log is the only part that can shrink: on a small or
//     heavily scaled screen it gets shorter (fit_log_height) so that the window does not run off the bottom of the screen.
#include <algorithm>
#include <cctype>
#include <string>

namespace re7mp {

// ---- the two "coming later" boxes ------------------------------------------------------------------

enum class FutureFeature { BioRand, Vr };

// The key in re7mp.ini ("biorand=1").
inline const char* future_ini_key(FutureFeature f) { return f == FutureFeature::Vr ? "vr" : "biorand"; }
inline const char* future_label(FutureFeature f) { return f == FutureFeature::Vr ? "VR support" : "BioRand 7 randomizer"; }

// What the ini says. The boxes START OFF: only an explicit yes ("1", "true", "yes", "on", any case) turns one on.
inline bool future_flag_on(const std::string& v) {
    std::string s;
    for (const char c : v) {
        if (!std::isspace(static_cast<unsigned char>(c))) s += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s == "1" || s == "true" || s == "yes" || s == "on";
}

inline std::string future_band_title() { return "Coming later:"; }

// The line that is always in the strip, under the two boxes.
inline std::string future_band_note() {
    return "NOT IMPLEMENTED YET - we are only preparing. These boxes only remember your choice for a later version: ticking one changes nothing in "
           "the game today.";
}

inline std::string future_tick_title(FutureFeature f) {
    return f == FutureFeature::Vr ? "RE7 Multiplayer - VR support (not implemented yet)" : "RE7 Multiplayer - BioRand 7 (not implemented yet)";
}

// The window that opens when a box is ticked (not when it is unticked).
inline std::string future_tick_text(FutureFeature f) {
    if (f == FutureFeature::Vr) {
        return "VR SUPPORT: NOT IMPLEMENTED YET\n\n"
               "We are only preparing the program for it. Ticking this box does nothing in the game today: it only saves your choice (re7mp.ini, "
               "vr=1) so that a later version can use it.\n\n"
               "Nothing about playing this mod in VR has been built or tried. If you run RE7 in VR with this mod anyway, do not expect it to work.\n\n"
               "Nothing was changed in your game.";
    }
    return "BIORAND 7 RANDOMIZER: NOT IMPLEMENTED YET\n\n"
           "We are only preparing the program for it. Ticking this box does nothing in the game today: it only saves your choice (re7mp.ini, "
           "biorand=1) so that a later version can use it.\n\n"
           "What we are preparing for, none of it working yet:\n"
           " - a place in this window for the BioRand 7 seed, and a way to get the randomized game from BioRand (re7.biorand.net) without leaving "
           "the program;\n"
           " - a check that you and the person you play with installed the SAME seed.\n\n"
           "BioRand 7 is the BioRand team's own project, not part of this mod. Playing a BioRand 7 seed together with this mod has not been tried, "
           "so do not expect it to work.\n\n"
           "Nothing was changed in your game.";
}

// The log line when a box is clicked.
inline std::string future_log_line(FutureFeature f, bool on) {
    return std::string(future_label(f)) + (on ? ": ticked. Saved only: it is NOT IMPLEMENTED YET, nothing changes in the game."
                                              : ": unticked.");
}

// The log line at the start when an ini has a box ticked from last time ("" when both are off): a report that says "it did nothing" has the reason.
inline std::string future_startup_line(bool biorand_on, bool vr_on) {
    if (!biorand_on && !vr_on) return "";
    std::string which = biorand_on ? future_label(FutureFeature::BioRand) : "";
    if (vr_on) which += std::string(which.empty() ? "" : " and ") + future_label(FutureFeature::Vr);
    return "Coming later: " + which + (biorand_on && vr_on ? " are" : " is") +
           " ticked (from last time). They are NOT IMPLEMENTED YET: nothing changes in the game.";
}

// ---- the size of the window ------------------------------------------------------------------------
// All in "logical" pixels (96 per inch): gui_win.cpp scales them with the screen's DPI, like every other number in the window.

namespace ui_layout {
constexpr int kOldClientW = 680;               // the width of the window before 10.25 (it was 680 x 750)
constexpr int kClientW = 760;                  // the new width
constexpr int kExtraW = kClientW - kOldClientW;  // how much wider the controls that used to reach the right edge are now
constexpr int kTopBand = 80;                   // the strip at the top: the two boxes, their warning line, a divider. The old layout starts under it.
constexpr int kLogTop = 588;                   // where the log starts inside the old layout (the log is the last thing in it)
constexpr int kLogWant = 190;                  // the log's height (it was 150)
constexpr int kLogMin = 70;                    // the shortest it is made to fit a small screen
constexpr int kBottom = 12;                    // the gap under the log

static_assert(kExtraW == 80, "the controls that reach the right edge are widened by exactly this much in gui_win.cpp");

constexpr int client_height(int log_h) { return kTopBand + kLogTop + log_h + kBottom; }

// The log's height for a screen whose usable height (what is left of the screen above the task bar, minus the window's title bar and borders) is
// `avail_client_h` logical pixels. <= 0 means "unknown": the wanted height. Never taller than wanted, never shorter than kLogMin.
inline int fit_log_height(int avail_client_h) {
    if (avail_client_h <= 0) return kLogWant;
    const int room = avail_client_h - (kTopBand + kLogTop + kBottom);
    return std::min(kLogWant, std::max(kLogMin, room));
}
}  // namespace ui_layout

}  // namespace re7mp
