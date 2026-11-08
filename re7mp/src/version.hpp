#pragma once
// The public release number: what you tell people ("v0.8"). It appears in the exe's title bar and log, in the in-game
// panel, in the debug file, and the two players' scripts exchange it so a mismatch is flagged.
// It is kept in two places: here and in lua/re7mp.lua (CFG.RELEASE). The tests fail if they differ.
// It stays the same between releases; it changes only when the project owner decides to publish a new version.
// (The "v9.x" labels in the README's changelog are internal build labels, not release numbers.)
namespace re7mp {
constexpr const char* kReleaseVersion = "0.8";
}  // namespace re7mp
