# RE7 multiplayer prototype

One exe (`re7mp.exe`, a small GUI) and one Lua file (`lua/re7mp.lua`, embedded in the exe and
installed for you). Each player sees the other as a stick-figure skeleton with a name tag,
facing the direction they are looking.

    RE7 + REFramework (re7mp.lua)  <--files in reframework/data-->  re7mp.exe  <--UDP-->  other player's re7mp.exe

**Both players must run the same version** (the packet format changed again in this one; older builds are ignored).

## Build (Visual Studio 2026)

1. File > Open > Folder... and pick this folder (VS reads `CMakeLists.txt`).
2. Choose the `x64-Release` configuration, then Build > Build All.
3. Run `re7mp.exe` (usually under `out\build\x64-Release\`; the Output window shows the path).
   It's a static build, so you can send the exe to a friend as is.

## Use

1. Run `re7mp.exe`. It finds your RE7 folder itself (a running RE7, then your Steam libraries); otherwise use Browse.
2. Type **your name**. It's sent to the other player and shown above your figure; you can change it while running.
3. Pick a mode:
   - **Loopback test**: a fake player ("Loopback Bot") orbits you at 3 m, walking and *facing you*. Needs no network.
   - **Network**: enter the other player's `ip:port` (they enter yours). UDP 27015 must be reachable (LAN, VPN, or port forward).
4. Click **Start** (it installs/updates the Lua script), start RE7, load a save. Press Insert for the "RE7 Multiplayer" panel.

Settings are remembered in `re7mp.ini` next to the exe. After changing `lua\re7mp.lua`, rebuild: the exe carries a copy and re-installs it on Start.

## Rotation

The camera's forward axis in RE7 turned out to be -Z (the figure was 180 degrees off with +Z), so
`FORWARD = { 0, 0, -1 }` is now the default at the top of `lua/re7mp.lua`.
The Loopback Bot copies *your* rotation, so it doesn't depend on any axis guess: its white look-line
should point the same way you are looking (you see its back when it is in front of you). If it points
back at you, flip `FORWARD` to `{ 0, 0, 1 }` and rebuild.

## Start together (hold until both are ready)

A ready check, so both players start a new game on the same difficulty at the same time.

1. Each player says "I'm ready" on a difficulty. Ready state travels inside every position packet, so a
   lost packet fixes itself on the next one.
2. When both are ready and the difficulties match, both go. A player only goes after the other side's packet
   shows they have seen *this* player's ready, and "go" is latched for 5 s, so neither side can be left waiting.
3. Mismatched difficulties don't start; the panel offers "Use their difficulty". Cancel, a 2-minute
   timeout and a script reload all unfreeze the game.

**Automatic (filled in from your probe).** The script hooks `app.GameManager.newGameRequest`. When you start a
new game with the other player connected, it reads your difficulty (`get_gameDifficulty`), freezes the game
(global game speed, the same mechanism as REFramework's timescale) and waits for them to be ready too,
then lets it continue. With nobody connected it does nothing and the game starts normally. The freeze is
optional (checkbox in the panel).

The difficulty enum's values are read from the game at runtime and matched by name (Assist/Easy, Normal,
Madhouse/Hard), and the mapping is logged to the console, so check it there once.

**Manual (always works).** Insert > RE7 Multiplayer > Start together > pick a difficulty > "I'm ready".
After both are ready you get a synchronized 3-2-1; the script also sets the game's difficulty
(`set_gameDifficulty`) and tells you to press New Game. In loopback mode the bot presses ready 1.5 s
after you, so you can try the whole thing alone.

**Still missing: actually starting the game for you.** `newGameRequest`, `newGameInitParam`,
`newGameRequest_Chapter7` and `SaveDataManager.newGameInit` have arguments I can't see, and calling them
with guessed arguments could crash the game, so the script doesn't. To finish this, in the panel:

1. Start together > leave "Log new-game calls" ticked, start a new game normally, and copy what appears in the
   REFramework console (it logs which of those methods fire, in what order, with raw argument values).
2. Probe RE7 types > "Show new-game method signatures" and copy the console output.

Send me both and I'll make "go" start the new game itself.

## Avatar: cloning a model instead of the skeleton (experimental)

Insert > RE7 Multiplayer > Avatar. The skeleton stays the default.

1. **Scan scene** lists GameObjects whose path contains the filter (default "player") with their components.
   Look for one with a mesh that is a full-body character.
2. Type its exact name into "Object to clone" and click **Clone and follow**. The clone is moved to the other
   player's position each frame, facing where they look. If it faces the wrong way, set `MODEL_YAW_OFFSET` in
   `lua/re7mp.lua` to 3.14159.
3. **List via.GameObject clone/create methods** shows which cloning methods exist if `clone` fails.

Caveats, so you aren't surprised: RE7 is first person, so I don't know that a full-body Ethan exists as a
loaded object during normal play (I believe you mostly see arms and hands); if the scan finds none, the same
tools can look for other humanoids that are loaded. A cloned model has no animation driving it, so
expect a static pose. Cloning the whole player object would also copy its controllers and camera, so clone a
mesh object, not the player root. None of this has been run. Send me the scan output and any errors.

## Layout

- `src/gui_win.cpp`: the GUI (plain Win32), game detection, Lua install
- `src/engine.*`: networking thread, names, ready-check flags, a generic reliable one-shot event channel (not used by the Lua yet), loopback bot
- `src/packet.hpp`: wire format v3 (position + rotation + ready flags, name, event, ack) and name sanitising
- `src/bridge.hpp`: the JSON file bridge to the Lua script
- `src/game_locator.*`: Steam library parsing, Lua installer
- `src/transport.hpp`, `src/udp_transport.cpp`: transport interface + UDP (a Steam backend would slot in here)
- `lua/re7mp.lua`: in-game script (pose sending, smoothing, skeleton drawing, ready check + freeze, RE7 adapter, probe and avatar tools)
- `src/cli_main.cpp` (`re7mp_cli`): headless engine; `tests/core_tests.cpp` (`re7mp_tests`); `tools/fake_game.py`

## What has and hasn't been tested

Tested (on Linux): packets and name sanitising, the bridge, Steam folder parsing, Lua install, loopback
(the bot copying your rotation, plus the full ready check: ready, confirm, go, cancel), two engines over UDP
exchanging pose, names, renames and ready flags, and the one-shot event channel with retransmission.

Not tested: the GUI (only syntax-checked against stand-in headers), and the Lua. I had no Lua interpreter,
only a bracket-balance and use-before-define check. New and unverified in this version: the
`sdk.hook` calls on `app.GameManager`, reading the difficulty enum, the freeze (`via.Application.get/set_GlobalSpeed`,
which I believe is how REFramework's timescale works), the scene scanner and the clone call. If the panel shows "UI error", or the
game doesn't unfreeze, use Cancel (it always releases) and tell me what the console says.
The skeleton is procedural, driven by camera position and rotation, with no real body model yet.
Positions are only comparable while both players are in the same loaded area.
