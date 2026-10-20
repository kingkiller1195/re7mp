# RE7 Co-op (REFramework) — multiplayer foundation, VR-ready

A multiplayer layer for Resident Evil 7 built on [REFramework](https://github.com/praydog/REFramework).
Players see each other in the world (skeleton avatars, nameplates, distance), chat, quick-chat and drop
shared markers. It also ships the reliable-event channel you need to synchronise world state (doors,
items, enemies) — that part is yours to build on top; see **What this is / isn't**.

```
 REFramework (dinput8.dll)
   ├─ reframework/plugins/re7_mp.dll        C++  UDP transport on its own thread, exposed to Lua as `mp_net`
   └─ reframework/autorun/re7_mp.lua        Lua  game integration (hot-reloadable from the REFramework menu)
        └─ re7_mp/{tracking,pose,session,avatars,ui,config,mathx}.lua
```

Why two halves: REFramework's Lua is sandboxed (no sockets), so networking has to be a native plugin.
The network thread is independent of the game's frame rate, so loading screens and VR frame pacing
can't starve keep-alives.

## What this is / isn't

**Works today (flat screen):** host/join, up to 8 players, 30 Hz pose sync with smoothing, nameplates,
chat (menu + F7/F8/F9 quick-chat), F6 shared markers, join/leave announcements, disconnect/timeout handling,
reliable ordered user events with a handler registry.

**Not included — and it's the hard 90% of a co-op mod:** shared world state. Each player's RE7 is still its
own single-player game; they only *see* each other. Everyone must be at the same story point/room
(same save). Doors, pickups, enemy AI/damage, cutscenes and saves are not synchronised. The hook for building
that is `session.on_user(kind, fn)` / `session.send_user(kind, payload)` (reliable, ordered, relayed by the host).
Start with host-authoritative state for one thing (e.g. door open/close) and grow from there.

## Install (players)

1. Install the **RE7** build of REFramework (put `dinput8.dll` in the game folder; for VR extract the full zip).
2. Copy `game/reframework/` into the game folder (merges with the existing `reframework/`), and put the built
   `re7_mp.dll` in `reframework/plugins/`.
3. In game press **Insert** → **RE7 Co-op**. One player clicks **Host**, the others type the host's IPv4 address and click **Join**.

Networking: UDP, default port **7777**. Over the internet the host must forward that port, or everyone can use a
virtual LAN (Tailscale / ZeroTier / Radmin) and skip port-forwarding. IPv4 numeric addresses only.

## Build the plugin (Windows, Visual Studio 2022 or newer + CMake)

```
git clone https://github.com/praydog/REFramework
xcopy /E /I REFramework\include\reframework  re7-coop\plugin\third_party\reframework
cd re7-coop\plugin
cmake -B build -A x64
cmake --build build --config Release          # -> build\Release\re7_mp.dll
```

**Lua version must match REFramework's.** The DLL links its own Lua and operates on REFramework's `lua_State`.
Run `print(_VERSION)` in the REFramework script console and, if it isn't 5.4, build with e.g. `-DLUA_TAG=v5.3.6`.
A mismatch can crash the game when `mp_net` is first used, so check this first if the game dies as the plugin loads.

## Hotkeys

| Key | Action |
|---|---|
| F6 | Drop a marker 3 m ahead of where you look (visible to everyone for 60 s) |
| F7 / F8 / F9 | "Help!" / "Over here!" / "Wait for me!" |

(Quick-chat and markers exist because typing is impractical in VR and on a controller.)

## VR: how it's prepared, and what's left

Already done:
- **The wire pose is VR-shaped.** Every pose packet carries head + left hand + right hand (world space) and
  flags (`VR`, `HANDS_VALID`). Flat players simply don't claim real hands and receivers synthesise them.
- **One file owns the flat/VR difference:** `tracking.lua`. Network, session and avatars never ask which mode you're in.
- **VR hand capture is written** (controller poses re-expressed relative to the HMD and re-applied to the head,
  so it doesn't depend on how REFramework maps tracking space to game space), fully `pcall`-guarded so it fails
  closed to "no hands".
- Mixed lobbies work by design: a VR player and a flat player see each other correctly.

Left to do (in order):
1. **Verify `tracking.lua`'s VR branch on hardware.** It uses REFramework's `vrmod` Lua object (`is_hmd_active`,
   `is_using_controllers`, `get_left/right_controller_index`, `get_transform`). Method names and the matrix
   convention (`TODO(VR)` comments) were written from the documented API but **not run on a headset**.
2. **A world-space avatar backend** (`avatars.lua`, skeleton at the bottom). The current `overlay` backend is an ImGui
   2D overlay: fine on a monitor, **invisible inside a headset**. VR players need real GameObjects (prefab/mesh) driven
   by `p.cur.head / lhand / rhand`, which the pipeline already supplies smoothed and in world space.
3. VR-friendly UI (the REFramework menu is a desktop window; hotkeys cover the basics meanwhile).

## Writing world sync on top

```lua
local session = require("re7_mp/session")
local KIND_DOOR = 16                                   -- 16..255 are yours

session.on_user(KIND_DOOR, function(from_id, payload)  -- runs on every other machine
    local door_id, open = payload:match("^(%d+),(%d)$")
    -- find the door and set its state here
end)

session.send_user(KIND_DOOR, "42,1")                   -- reliable, ordered, relayed by the host
```
Payload is an opaque string ≤ 900 bytes. Clients can only talk through the host (star topology), which gives you a
natural place to make the host authoritative.

## Protocol (v1, little-endian, UDP)

`magic 0x3752 | proto u8 | type u8 | body`. Types: HELLO, WELCOME, DENY, POSE (unreliable, 92 B, 30 Hz, newest wins
via wrap-safe sequence numbers), REL (reliable, ordered, go-back-N resend, cumulative ACK), PING/PONG (1 Hz, 8 s timeout), BYE.
Host is id 0 and relays. Clients can only originate chat/user events; the host stamps the real sender id.
There is no encryption or authentication — play with people you trust.

## Tests

`plugin/tests/run_all.sh` (Linux/WSL, needs g++ and `liblua5.4`) runs four stages:
1. Transport loopback: handshake, roster, pose relay, chat/user events, **ordered exactly-once delivery under 30% packet loss**, leave, id reuse, server-full (ASan+UBSan).
2. The same under ThreadSanitizer.
3. Lua modules (math, pose, config, tracking incl. the VR hand math) in a real Lua 5.4 runtime.
4. **Two-process end-to-end:** two instances each load the real `re7_mp.lua` and the real `plugin.cpp` bridge into a real Lua state and play a session over real UDP (menu buttons, hotkeys, chat, markers, avatar drawing, disconnect, script reset).

### Verification status (be aware of this)

| Piece | Status |
|---|---|
| Transport, protocol, reliability | Tested (stages 1–2) |
| `plugin.cpp` Lua bridge | Tested against real Lua 5.4.6 with test-only header stubs (stage 3–4); **not yet compiled with the real Lua headers / MSVC / REFramework's `API.h`** |
| Lua mod logic | Tested against a **mock** of REFramework's API (shapes taken from its docs/behaviour) |
| Inside RE7 itself | **Not run** — no game available here. Expect to adjust: camera access in `tracking.lua`, `draw.*`/`imgui.*` call details, RE7-specific quirks |
| VR | Hand math unit-tested with fake matrices; **not run on a headset** |

## Layout

```
plugin/src/net.{hpp,cpp}        transport (portable; Winsock on Windows)
plugin/src/plugin.cpp           REFramework plugin entry + Lua bridge (mp_net)
plugin/CMakeLists.txt           builds re7_mp.dll (Windows) + tests (anywhere)
plugin/tests/                   loopback, Lua harness, mock REFramework, e2e
game/reframework/autorun/       re7_mp.lua + re7_mp/*.lua
```
