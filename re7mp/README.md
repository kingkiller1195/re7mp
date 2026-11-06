# RE7 multiplayer prototype

One exe (`re7mp.exe`, a small GUI) and one Lua file (`lua/re7mp.lua`, embedded in the exe and
installed for you). Each player sees the other as a shaded 3D body with a name tag, facing the direction they
are looking, and the two games can talk to each other (new-game sync, chat, pings, and soon items).

    RE7 + REFramework (re7mp.lua)  <--files in reframework/data-->  re7mp.exe  <--UDP-->  other player's re7mp.exe

**Both players must run the same version** (the packet format changed again in this one; older builds are ignored).

## Build (Visual Studio 2026)

1. File > Open > Folder... and pick this folder (VS reads `CMakeLists.txt`).
2. Choose the `x64-Release` configuration, then Build > Build All.
3. Run `re7mp.exe` (usually under `out\build\x64-Release\`; the Output window shows the path).
   It's a static build, so you can send the exe to a friend as is.

## Use

1. Run `re7mp.exe`. It finds your RE7 folder itself (a running RE7, then your Steam libraries); otherwise use Browse.
2. Type **your name**. It's sent to the other player and shown above their view of you; you can change it while running.
3. Pick a mode:
   - **Loopback test**: a fake player ("Loopback Bot") appears next to you. Needs no network.
   - **Network**: enter the other player's `ip:port` (they enter yours).
4. Pick the **connection**:
   - **UDP (fast)**: the default. Both sides enter each other's address; UDP port 27015 must be reachable
     (LAN, VPN, or port forward).
   - **TCP: I host / TCP: I join**: reliable and ordered, for when UDP sync misbehaves (loss, odd NATs). One player
     hosts (listens on the port; the address box is optional and, if filled in, only that IP may connect), the other
     joins the host's `ip:port`. The joiner retries every second and reconnects by itself if the link drops.
     Position updates arrive a little later than with UDP when the network is lossy (TCP waits to resend), which is
     the trade-off for never losing data. Both players must pick the same family (both UDP, or one host + one join).
5. Click **Start** (it installs/updates the Lua script), start RE7, load a save. Press Insert for the "RE7 Multiplayer" panel.

**Loopback bot.** *Orbits you* circles you at 3 m, walking. *Stays put* teleports the bot to where you are and keeps
it there while you walk around it; it still copies where your camera points, so you can inspect the body from all sides.
"Move bot to me" parks it at your current spot again. The bot also presses ready 1.5 s after you (to test new-game sync),
echoes chat messages and answers pings (to test those).

Settings are remembered in `re7mp.ini` next to the exe. After changing `lua\re7mp.lua`, rebuild: the exe carries a copy and re-installs it on Start.

## The other player's body

A shaded 3D body: head with a visor on its front, torso, arms, legs and feet, each a box in world space, projected
with perspective, back-face culled and sorted far to near. It follows the other player's camera (position, where they
look including up/down, and a walk cycle driven by their speed). The old line skeleton is still there as a **debug
skeleton** (checkboxes in the panel).

It is an overlay, so **it draws through walls** (no depth test against the level) and is slightly see-through to
show that. Fixing that needs a real in-game avatar. Accuracy is limited to what we send: camera position and rotation.
Crouching, aiming and holding items are not sent yet.

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

## Interactivity: messages, chat, pings, and finding item hooks

**Reliable messages.** Besides the position stream there is now a reliable message channel: the Lua script queues a
short text message (kind + payload up to 200 bytes), `re7mp.exe` resends it until the other side confirms, the other side
receives each message exactly once and hands it to its Lua script. This is the pipe item pickups, drops and other events
will use. Two uses already ride on it:

- **Chat**: Insert > RE7 Multiplayer > Chat and pings > type, Send. Messages show on screen for 12 s.
- **Ping**: "Ping my position" puts a marker at your position on the other player's screen for 12 s, with your name and distance.
  (In loopback mode the bot echoes your chat and returns your ping, so you can try it alone.)

**Item sync: where it stands.** From your `app.ItemManager` probe: `createItemInstance`, `createDropItemInstance`,
`setItemGotFlag`, `applyDifficultyItemNumRate`, `hasItemInInventory` and others exist, but none of them is obviously
"the player picked this up", and the inventory type (`app.Inventory`) hasn't been probed. So I need to see what the
game does when you pick something up. That is what "Send me this" is for (next section). With that I can hook the
pickup, send "player X picked up item Y at position P" over the message channel, and on the other side remove or mark the
matching item in the world (matched by item id + position, since both games load the same level), plus the
inventory/give/drop events. Items placed by the difficulty (`applyDifficultyItemNumRate`) and "who gets the item" rules
(shared vs both get it) need a decision from you.

## "Send me this": collecting debug info (three clicks, then send one file)

Everything the script logs is also written to **`<RE7>\reframework\data\re7mp_debug.json`**. In `re7mp.exe` click
**Open data folder** to find it. In the game press Insert > RE7 Multiplayer > **Send me this (debug info)**:

1. **Collect game info.** One click, nothing to do in the game. Lists the methods (with their argument types) of the
   item, inventory, enemy, event and player manager types that exist. (Types that don't exist are just reported as not found.)
2. **Start tracing items.** Then, in the game: pick up one item, drop one, use or combine one. Each call the game
   makes while you do that is logged with its arguments.
3. **Scan for enemies.** Stand where an enemy is visible (any enemy; the first Jack or Molded encounter is fine) and click.
   Lists enemy-looking objects with their position and components.

Then send me `re7mp_debug.json`. You don't need to understand the contents.

## Hiding the other player

- **After a new game** the other player is hidden for 150 s (`HIDE_AFTER_NEW_GAME` at the top of the Lua), so the
  opening cutscene doesn't show a body in the same spot as the cutscene camera. It starts when New Game is pressed
  and again when the synced start happens. The panel shows the countdown and a "Show them now" button; the option
  can be switched off.
- **Too close:** the body is also not drawn while it is within 0.8 m of your camera (`HIDE_NEAR_DISTANCE`).
- Other cutscenes later in the game are not detected yet. That needs a "cutscene is playing" signal from the game;
  "Collect game info" includes `app.EventManager` for exactly that. Until then, use "Hide them for 60 s" or untick "Show other player".

## If the game crashes: "Fatal D3D error (6)"

That message comes from the game's own DX12 renderer (`renderdevicedx12.cpp`) when the graphics device fails. I can't
tell from the message alone whether our mod has anything to do with it. Reports for the same error in other RE Engine
games (RE2, RE4, Monster Hunter Rise) mostly blame running out of video memory, system memory / a too-small Windows
page file, or the graphics driver; those are forum posts, not an official fix, and they aren't RE7-specific. Things to
try on the crashing PC, roughly in order:

1. **Find out if the mod is involved:** play the same stretch with `reframework\autorun\re7mp.lua` removed (close
   re7mp.exe first, or it reinstalls it), and, if it still happens, with REFramework (`dinput8.dll`) removed too. Note
   whether the crash happens during loading screens, cutscenes or a new game start.
2. **Lower VRAM use:** in the RE7 settings keep the memory bar out of the red/orange (lower textures, shadows,
   disable ray tracing if it's on). Try the DirectX 11 option in the launcher if RE7 offers it on that install.
3. **Drivers and overlays:** a clean graphics-driver install; no GPU overclock/undervolt; close Discord, GeForce, RTSS /
   Afterburner overlays. Make sure the Windows page file isn't tiny (system-managed is fine).
4. **Windows Event Viewer** > Windows Logs > System: look at the time of the crash for "Display" / driver-reset entries.
5. Send me the REFramework log (a file in the RE7 folder ending in `_framework_log.txt`) and `re7mp_debug.json` after a crash.

In case the mod contributes: this version never gives the renderer NaN or absurd screen coordinates, and the body
draws only a few dozen shapes per frame, so it should be negligible. The game-freeze fallback is off by default.

## Enemy sync: what I need

Plan (host-authoritative, see the design notes): one player's game runs the enemies, the other's shows them as puppets.
To start I need:

1. The output of **Collect game info** and **Scan for enemies** (above), taken in a spot with an enemy in view. They tell
   me how enemies are named, which components hold their AI, health and animation, and which manager owns them.
2. A decision: **who is the host?** Options: whoever pressed New Game first / whoever is the TCP host / a checkbox in the
   exe ("My game runs the enemies"). My suggestion is the checkbox, so you choose and can swap.
3. A **first test scene**: one enemy in one area (e.g. the first encounter you can reach quickly after a save) so I can
   build positions + rotation + health first, then animation, then damage and spawn/despawn.
4. A **save near it** is handy but not required: just tell me where it is.

## Design notes: death and enemies (not built yet)

Things to decide and find out before building:

- **Death.** What should happen when one player dies? Options: (a) shared fate: both get the game over screen;
  (b) the other player keeps playing and the dead player waits / respawns at the last checkpoint or save;
  (c) a downed state with revive. We need the hook for "player died / game over" (the earlier probe showed rank and
  damage methods on `app.GameManager`, e.g. `addRankPointPlDamage`; the player health/damage types are still to be
  found with the tracer). Death would be a reliable message (kind "death"), applied by the other side per the rule you pick.
- **Enemies.** RE7's AI is not deterministic, so two games running their own copy of the same enemy will drift apart. The
  workable design is host-authoritative: one player (the host) runs the AI; the other game shows puppets. For each enemy
  we'd send a network id (matched by name + spawn position), position, rotation, animation/state and health about
  10 times a second, and the joiner's game disables that enemy's AI components and applies the received state. Damage
  the joiner deals is sent to the host as "enemy N took X damage"; the host applies it. The hard parts are scripted
  events, Jack's/Marguerite's special behaviour, and spawning/despawning in sync. Start with plain enemies in one area.
  Needed first: how to enumerate enemies (probe `app.EnemyManager` and use the tracer) and which components hold AI,
  health and animation.
- **Transport.** Enemy snapshots are state, so they go over the unreliable position-style channel (UDP), while
  spawn/despawn/damage/death go over the reliable message channel. TCP mode makes everything reliable, at the cost of latency.

## Layout

- `src/gui_win.cpp`: the GUI (plain Win32), game detection, Lua install
- `src/engine.*`: networking thread, names, ready-check flags, reliable message channel, one-shot events, loopback bot (orbit / stationary)
- `src/packet.hpp`: wire format v4 (position + rotation + ready flags, name, event, message, acks) and name sanitising
- `src/bridge.hpp`, `src/json_mini.hpp`: the JSON file bridge to the Lua script and its small JSON parser
- `src/game_locator.*`: Steam library parsing, Lua installer
- `src/transport.hpp`, `src/udp_transport.cpp`, `src/tcp_transport.cpp`: transport interface, UDP, and framed TCP with host/join and auto-reconnect (a Steam backend would slot in here)
- `lua/re7mp.lua`: in-game script (pose sending, smoothing, 3D body + debug skeleton, ready check + block/freeze, RE7 adapter, chat/pings, tracer, probe and avatar tools)
- `src/cli_main.cpp` (`re7mp_cli`): headless engine; `tests/core_tests.cpp` (`re7mp_tests`); `tools/fake_game.py`, `tools/lobby_sim.py` (ready-check simulation)

## What has and hasn't been tested

Tested (on Linux): packets and name sanitising, the JSON parser, the bridge, Steam folder parsing, Lua install,
loopback (orbiting and stationary bot, teleport, rotation copying, the full ready check), UDP and TCP between two
engines (names, pose, flags, reliable messages both ways, resend and exactly-once delivery when the peer starts late,
TCP reconnect after the host restarts, the host's address restriction), and chat/ping echo through the bot.
I also modelled the new-game ready-check state machine in Python (`tools/lobby_sim.py`, 1,000+ scenarios with packet
loss and lag) and checked the 3D body's face ordering and back-face culling logic in Python.

Not tested: the GUI (only syntax-checked against stand-in headers), the Windows socket code (the TCP and UDP code
has Windows branches that I could only read, not run), and the Lua (no interpreter here: only bracket-balance,
use-before-define and unknown-function checks). In the game itself, unverified: `draw.filled_quad` (the body falls back
to outlines if it's missing), the tracer's hooks and argument decoding, the message files through `json.dump_file`,
chat/ping drawing, and everything under Avatar.
