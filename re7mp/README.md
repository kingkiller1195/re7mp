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

## Start together (new game sync)

Goal: both players start a new game on the same difficulty, at the same time.

**How it works.** The script hooks `app.GameManager.newGameRequest()` (no arguments, per your signature probe).
When a player starts a new game with the other player connected, the request is **blocked** and that player
becomes "ready" on their current difficulty (`get_gameDifficulty`). When both are ready on the same
difficulty, both see a 3-2-1, then the blocked request is replayed on both sides: the script calls
`set_gameDifficulty(...)` and then `newGameRequest()` itself. With nobody connected, nothing is blocked and
the game starts normally.

Ready state travels inside every position packet, so lost packets heal themselves, a player only goes once
the other side's packet shows they've seen this player's ready, and "go" is held for 5 s so neither side is
left waiting. Cancel (panel), a 2-minute timeout or a script reload drop the blocked request, so you just
press New Game again.

**Ways to start together** (Insert > RE7 Multiplayer > Start together):

- Both players press **New Game** in the game menu.
- One player presses New Game; the other sees "X is ready on Madhouse" on screen and clicks **Join**
  (or enables **Auto-join**, off by default because it starts a new game immediately).
- Neither uses the menu: both pick a difficulty and click **I'm ready** (at the title screen). After the
  countdown the script starts the game for you (untick "start the new game for me" to be told to press New Game instead).

Different difficulties never start; the panel offers "Use their difficulty". The difficulty enum
(`app.GameManager.Difficulty`) is read at runtime and matched by name onto Easy/Normal/Madhouse; the mapping
and the `GameMode` values are logged to the console on load, so please check those once.

**Testing it alone (loopback).** Run `re7mp.exe` in Loopback mode and start RE7. At the title screen press
New Game. Expected: your game waits ("Ready on ..., waiting for Loopback Bot"), the bot presses ready 1.5 s later,
you get "Both ready! Starting in 3...", then the new game begins. The exe's log shows the same steps.

**What I couldn't verify, and what to send me.** I don't know whether calling `newGameRequest()` is *enough*
to start a game, or whether the menu also calls `newGameInitParam(bool)` and `SaveDataManager.newGameInit()`
(or `newGameRequest_Chapter7()` for another start path) around it. The script logs every one of these calls
(Start together > "Log new-game calls", also in the REFramework console). If the game doesn't start after the
countdown, or the New Game button never triggers the wait, start a new game normally once and send me
the logged lines (names, order, argument values).

If the freeze fallback is used (checkbox, or if this REFramework can't skip a call), the game speed is set near
zero instead of blocking the request. That relies on `via.Application.set_GlobalSpeed`.

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
- `src/cli_main.cpp` (`re7mp_cli`): headless engine; `tests/core_tests.cpp` (`re7mp_tests`); `tools/fake_game.py`, `tools/lobby_sim.py` (ready-check simulation)

## What has and hasn't been tested

Tested (on Linux): packets and name sanitising, the bridge, Steam folder parsing, Lua install, loopback
(the bot copying your rotation, plus the full ready check: ready, confirm, go, cancel), two engines over UDP
exchanging pose, names, renames and ready flags, and the one-shot event channel with retransmission.

Not tested: the GUI (only syntax-checked against stand-in headers), and the Lua. I had no Lua interpreter,
only a bracket-balance and use-before-define check. I did model the ready-check state machine in Python
(`tools/lobby_sim.py`, 1,000+ scenarios with 0-30% packet loss and 30-150 ms lag: both players start exactly
once, within 0.6 s of each other, never before both are ready; cancels and mismatches behave). That checks the
logic, not the Lua. New and unverified in the game itself: the `sdk.hook` calls (including skipping the original
request), reading the difficulty enum, `newGameRequest()` being enough to start a game, the freeze fallback,
the scene scanner and the clone call. If the panel shows "UI error", or the
game doesn't unfreeze, use Cancel (it always releases) and tell me what the console says.
The skeleton is procedural, driven by camera position and rotation, with no real body model yet.
Positions are only comparable while both players are in the same loaded area.
