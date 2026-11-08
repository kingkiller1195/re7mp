# RE7 multiplayer prototype

One exe (`re7mp.exe`, a small GUI) and one Lua file (`lua/re7mp.lua`, embedded in the exe and
installed for you). Each player sees the other as a shaded 3D body with a name tag, facing the direction they
are looking, and the two games can talk to each other (new-game sync, chat, pings, item pickups, handing items to
each other, and the host's enemies shown on the joiner's screen).

    RE7 + REFramework (re7mp.lua)  <--files in reframework/data-->  re7mp.exe  <--TCP-->  other player's re7mp.exe

**Both players must run the same version.** This one is **release 0.8** (wire protocol v6), so an older
`re7mp.exe` on either side is ignored: both of you need the new exe, and the same script.

## Releases and the version check

- **Release number** (what you publish on GitHub): `0.7` is the published release (0.6 and 0.5 before it), this build is **`0.8`**. It stays 0.8 until you say to move it.
  It lives in two places that must agree: `src/version.hpp` (`kReleaseVersion`, used by the exe) and `RELEASE = "0.8"` near the top of `lua/re7mp.lua`.
  A test fails if they differ, so you can't ship half a bump.
- **Build label** (`v9.22`, `BUILD` in the script) is my internal change counter between releases. Ignore it unless you are reporting a bug.
- **Where you see it:** the `re7mp.exe` window title (`RE7 Multiplayer v0.8`) and its first log line, the top of the in-game panel
  (`RE7 Multiplayer v0.8`, and under it `Release v0.8   (script build 9.22, re7mp.exe v0.8)`), and the debug file (`release`, `build`, `exe`, `exe_protocol`, `other_player_version`).
- **The check.** When the other player appears, each script tells the other `release / build / exe version`, and again every 20 s.
  The panel (in red) and the log say so if:
  - the other player is on a different release: *"Bob is on release v0.5 but you are on v0.8: update so you both run the same version"*;
  - their script sends no version at all for 8 s (an older script): *"Bob's script is older than release v0.8"* (never said for the loopback bot);
  - your `re7mp.exe` and your script are from different releases (for example you updated the script but not the exe).
  Separately, if the other player's `re7mp.exe` speaks a different **protocol** (an old exe), the exe can't read their packets at all; its "Other player" row then says
  *INCOMPATIBLE* with both protocol numbers, instead of just showing nothing.
- Nothing is blocked: a mismatch is a warning, not a refusal to connect, since two nearby releases may well work together.


**What changed in each build:** see `CHANGELOG.md`. The newest is v9.22 (script and exe; release stays 0.8).

## Updating, and installing REFramework (re7mp.exe)

Two new rows at the bottom of the window, **Updates** and **REFramework**.

**Updates.**
- When re7mp.exe opens it asks GitHub (`api.github.com`, over HTTPS) for the newest release of `kingkiller1195/re7mp`. If it is newer than the exe you are running, the
  button changes to *Update to v0.8*; click it, read what's new, say Yes, and re7mp.exe downloads the new version, swaps itself (the old file stays as `re7mp.exe.old` until the
  next start), and restarts with your settings. Press Start afterwards: it installs the Lua script that came inside the new exe. The check can be switched off with the
  checkbox; *Check now* does it by hand. The only thing sent is an ordinary web request (GitHub sees your IP address) with the user agent `re7mp/0.8`.
- **How a release has to look.** The version is read from the release **title** (`v0.5`), because your tags are `beta5` and so on; a tag is only used if it looks like a
  version (`v0.6`). Attach **`re7mp.exe`** to the release (or a zip that contains it). If the release has no exe, the update stops with a message pointing at the releases page. GitHub's
  automatic "Source code" archives are not used.
- **Your internal/debug builds stay private.** Only published releases are offered, never drafts, and never releases marked *pre-release*. Playtesters you give builds to can
  see pre-releases too by adding `include_prerelease=1` under `[re7mp]` in `re7mp.ini` (next to the exe); it is not in the window, so normal players don't see it. A
  build with a newer number than the newest release (an internal 0.8 before 0.8 is published) is never "updated" back.
- Safety: only `https://` links on github.com and its download hosts are followed; the download must look like a Windows program (and be at least 64 KB); if anything fails
  the running exe is put back exactly as it was. There is no signature check beyond GitHub's HTTPS: whoever can publish on your GitHub account can publish an update.

**REFramework.**
- The window shows whether `dinput8.dll` is in your RE7 folder and whether this program put it there. *Install* downloads
  `https://github.com/praydog/REFramework/releases/download/v1.5.9.1/RE7.zip` (the release you named: `kReframeworkTag` in `src/updater.hpp`; change it only after trying a newer one).
  When you press Start or *Install Lua script* in a folder without REFramework it also asks once whether to install it.
- **It installs everything in RE7.zip**: `dinput8.dll`, the VR files and the `reframework` folder, and makes sure `reframework\autorun` and `reframework\data` exist (the Lua script goes in
  `autorun`). Before anything is written the whole zip is unpacked and checksummed in memory; a damaged download changes nothing.
- It never overwrites a file that is already inside your `reframework` folder (your scripts, your settings). An existing `dinput8.dll` (another REFramework version, or a different mod loader)
  is only replaced after you say yes, and is kept as `dinput8.dll.bak`. The game has to be closed. Installing again when nothing changed says so.
- REFramework's own release notes say that if you don't use VR you should extract only `dinput8.dll`, because the other files can crash the game. This tool installs the whole package
  because VR is planned; if a game crashes after installing, put `reframework_files=dll` under `[re7mp]` in `re7mp.ini`, click *Reinstall*, and only `dinput8.dll` is installed.
- Zip names are checked (`..`, absolute paths, drive letters and odd characters are refused) so a zip can't write outside the game folder.

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
   - **TCP: I host / TCP: I join** (the only choice since 9.7): reliable and ordered.
     One player hosts (listens on the port; the address box is optional and, if filled in, only that IP may connect),
     the other joins the host's `ip:port`. The joiner retries every second and reconnects by itself if the link drops.
     Position updates arrive a little later when the network is lossy (TCP waits to resend), which is the trade-off for never losing data.
     With a VPN such as Tailscale, ZeroTier or Radmin no port forwarding is needed: join the host's VPN address and port.
5. **Share saves (TCP)** is ticked by default when the Steam save folder is found (untick it to keep saves private); check the **Save folder** (it is detected from Steam:
   `...\userdata\<your id>\418370\remote\win64_save`). See "Co-op saves" below.
6. Click **Start** (it installs/updates the Lua script), start RE7, load a save. Press Insert for the "RE7 Multiplayer" panel.

**Loopback bot.** *Orbits you* circles you at 3 m, walking. *Stays put* teleports the bot to where you are and keeps
it there while you walk around it; it still copies where your camera points, so you can inspect the body from all sides.
"Move bot to me" parks it at your current spot again. The bot also presses ready 1.5 s after you (to test new-game sync),
echoes chat messages and answers pings (to test those). Since 9.13 it also **confirms gifts and drops** (so giving it an item takes the
item out of your inventory), and it **can be told to go down and get up** from the panel's Health section, which lets you try a revive
alone: walk within 3 m and press F8 (stay put 3 s, no item) or use a Herb; a heal event within 3.75 m gets it up. While down it stays where it fell and shows `[downed]`.

Settings are remembered in `re7mp.ini` next to the exe. After changing `lua\re7mp.lua`, rebuild: the exe carries a copy and re-installs it on Start.

## The other player's body

A shaded 3D body: head with a visor on its front, torso, arms, legs and feet, each a box in world space, projected
with perspective, back-face culled and sorted far to near. It follows the other player's camera (position, where they
look including up/down, and a walk cycle driven by their speed). It is always drawn (no option since 9.22). The old line skeleton is still there as a **debug
skeleton** (checkbox in the panel). **Inventory pose (9.22):** while the other player has their inventory or item box open the body brings both hands up in front of the belt and leans a little (pose bit 512; preview it in the panel).

**Poses (v9.7, real signals since v9.8, crouch since v9.9).** When the other player blocks, uses a healing item (read from your game's block flag and hand action, see v9.8) or crouches (camera height, see v9.9), the body changes: forearms up at the face (`[blocking]`), the left forearm across the chest with a small green item brought to it
(`[healing]`), or lower with bent knees (`[crouching]`). The panel's *Stand-in pose preview* shows each one without the other player doing anything. They are placeholders until a real model can be driven; see v9.7 to v9.9 above. The loopback bot blocks, crouches and heals on a timer so you can watch all three.

It is an overlay drawn on top of the game, so it has no depth test against the level and is slightly see-through to
show that. Since 9.9 the script hides it when a wall or door is in the way and (experimentally) while a game menu is open (see v9.9); both are guesses at the game's physics layers and GUI names that the debug file will confirm or correct. A real in-game avatar would do this properly. Accuracy is limited to what we send: camera position and rotation.
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

## Model probe: finding Mia, Ethan and the enemy models (9.22)

Insert > RE7 Multiplayer > **Model probe (Mia, Ethan, enemies)**. One read-only button. It walks the scene and lists every object that carries a mesh and whose name contains one of the words in the box (default `pl;em;mia;ethan;jack;marguerite;lucas;zoe;chara`): the object name, mesh file, material count, joint count, distance from you and position, and, for the three nearest, the whole joint list with parents. Stand next to the character you want looked at (Mia in her cutscene, the headless Mia on the shipwreck, Ethan if he is on screen, an enemy), press it, then send the debug file (`health.model_probe`, and `model probe:` lines in the journal). Nothing is cloned, moved or hidden. The mesh and joint calls are guesses at the engine's method names; the entry says `mesh_note` when a call gave nothing. With that data I can pick Mia's model for the second player, map her skeleton onto the stand-in's and put an enemy model in for the red boxes.

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

- **Chat**: Insert > RE7 Multiplayer > Chat and pings > type, Send, or press one of the quick phrases (Wait for me, Come here, Help!, Found something, Going ahead). Messages show on screen for 12 s.
- **Ping**: **F9**, or "Ping my position" (also at the top of the panel; at most one per 1.5 s), puts a marker at your position on the other player's screen for 12 s, with your name and distance.
  (In loopback mode the bot echoes your chat and returns your ping, so you can try it alone.)

**Item sync, version 1 (new).** An item one player picks up from the world disappears for the other player.
Built from your item trace: picking something up runs `app.Inventory.addItem(app.Item, ...)` on the item lying in the
world, and the game then removes it with `app.Item.disableFromScene()`. Crafting and restoring the inventory also call
`addItem`, but on items created under the player object `Pl0000`, which is how they're told apart. The message carries the
item id, its object name and position; the other game finds the object with that name within 0.75 m and removes it the
same way. Panel: Insert > RE7 Multiplayer > Item sync (counters and the last event).

Try it: both players in the same room with a pickup visible (a handgun bullet box, a health item). One picks it up;
on the other screen it should vanish and the panel says "removed it here". If it says "can't find it", send me the
debug file (the object's name or position differs between the two games).

Not synced yet: items that come out of drawers and containers (`createDropItemInstance`: the container's own state isn't
synced, so the second player could open it and get the item again), crafting, ammo use, and "both players get the item"
(today only the picker gets it). Those need a decision from you plus more trace data.

## Items: give and drop (giving confirmed in the game; receiving into a stack you hold confirmed; creating items and drop-on-discard not, and creating is OFF by default since v9.16)

You asked for two ways to hand an item to the other player. Both are built, and you can use either. **Since 9.11 the receiver answers** (`Bob has Herb x1 (in the inventory)`, `... on the ground`, or `could not take ...: it is back in your inventory`, and a drop is answered too); a gift that cannot be placed is handed back, and a sender with no answer after 10 s is told the other script is probably older than 9.11. Both players need 9.11 for the answers. **Since 9.12 a gift leaves your inventory only after the receiver says `ok`** (nothing is taken first), "dropped at your feet" is only said when an object really appeared, and a gift whose item the game will not create can still grow a stack the receiver already has (see v9.12 above).

**A. Give (the "transfer item" idea).** I can't add a button *inside* the game's own inventory menu from a script, so
there are two ways to give from the REFramework panel instead (Insert > RE7 Multiplayer > *Items: give and drop*):
- **The inventory list (v9.1).** The panel lists everything in your inventory (`Herb x3`, `Gunpowder x2`, ...) with a
  **Give 1** and a **Give all** button on each line. The item leaves your inventory and appears in theirs. This reads the
  inventory object directly (the `_ItemList` field your dump showed), so it does not depend on pointing at anything.
- **Point and press F7.** Open the game's inventory, move the cursor onto an item, press **F7** to give 1. This relies on
  a hook that fires when the cursor lands on an item. In your first v9 test the hook never produced an item (button 7 said
  "nothing highlighted" every time), so treat F7 as unproven; the panel line "hook fired N times" tells you whether it fires.

**B. Discard drops it.** With *Discard drops the item on the ground* ticked (it is on by default), discarding an
item in the inventory also puts it on the ground at your feet, and the other player's game spawns the same item at the
same spot. Whoever walks over it picks it up through normal item sync, so it can go to either of you. This depends on
the same pointed-at hook as F7 (it needs to know which item you were on), so it may not work either until the hook is fixed.
You can switch B off; the normal discard (item just vanishes) is then untouched.

The list does not check what you give: handing over a key item or your equipped weapon works the same as a herb.

**Status after your v9.2 test:** giving works (the item leaves your inventory and the message goes out). The game's own inventory screen does not redraw
until you close and reopen it. The receiving half can't be tried with the loopback bot, so v9.3 adds three *Test:* buttons at the bottom of the
panel that run the real receive code on yourself (receive 1 Herb, receive 5 HandgunBullet, a dropped Herb appears at your feet). The line under the
buttons says whether it went into the inventory or onto the floor, and why.

How it is built, from your trace:
- *Take it out:* `app.Inventory.reduceItem(id, n, true)`, the call the trace showed for use/reload/key items.
- *Put it in:* `app.ItemManager.createItemInstance(Pl0000, id)` then `app.Inventory.addItem(item, Pl0000, false, nil)`, the
  same pair the trace showed for crafting. If that fails or the inventory is full, the item is spawned on the ground at the
  receiver's feet with `createDropItemInstance`, which drawers use. Nothing is ever lost: either it is in their
  inventory, on their floor, or your inventory still has it (the panel says which happened).
- *Discard detection:* the trace showed discard as `app.Item.reduceNum(n, Pl0000)`. After the game finishes it, the
  script spawns the item on the ground and sends a "drop" message with the item id, count and position.
- *Item names:* the game calls them `Herb`, `ChemicalS`, `RemedyM`, `CylinderKey`, `Gunpowder` (from your trace). The name
  getter (`getItemDataId`) is read as text, whether the game hands back a Lua string or a managed string object.

Messages: kind 5 = give (`id|count`), kind 6 = world drop (`id|count|x|y|z`), over the existing reliable channel; item
ids are checked (letters, digits, underscore) and counts are capped, so a bad message does nothing.

Things I still don't know, and the next test shows: whether the inventory list reads (the panel says "can't read it" and
why if not), whether `addItem` with `nil` for the last argument is accepted, and whether spawning with the player as parent
puts the item at your feet. The line under *Items: give and drop* names the path that was used or the error.

**Since 9.18:** a created item has a stack of 0, which is the best guess for the crash; gifts now set and verify the stack and the lab has a Lab 6 for it (see the v9.18 section at the top).

**Since 9.17, finding out why creating an item crashes the game:** with the creation box ticked, every item step is written at once to `reframework\data\re7mp_trail.json` (and the debug file), the steps are followed by "alive" lines for 4 s, and the panel has a five-button **item lab** that runs make / add / add-with-a-list / remove one step at a time. After a crash, start the game again and send the debug file: the first journal line names the last step. See the v9.17 section at the top. Safe mode (the default) never touches any of this.

## "Send me this": collecting debug info (three clicks, then send one file)

Everything the script logs is also written to **`<RE7>\reframework\data\re7mp_debug.json`**. In `re7mp.exe` click
**Open data folder** to find it. In the game press Insert > RE7 Multiplayer > **Send me this (debug info)**:

1. **Collect game info.** One click, nothing to do in the game. Lists the methods (with their argument types) of the
   item, inventory, enemy, event and player manager types that exist. (Types that don't exist are just reported as not found.)
2. **Start tracing items.** Then, in the game: pick up one item, drop one, use or combine one. Each call the game
   makes while you do that is logged with its arguments.
3. **Scan for enemies.** Stand where an enemy is visible (Jack, a Molded, anything) and click. It lists enemy-looking
   objects with their position and components, and then every component type in the scene with a count; the second list
   shows what the game calls its characters even if my guess misses.

4. **Watch for death.** Click it, then let something kill you once. It logs every call `app.GameManager` makes while you die
   (and every GameMode change, by name).

5. **Enemy details.** Stand near an enemy (Jack's garage fight, Mia, anything with an `Em####` name) and click. It lists
   every component on the enemies with their field names and values, now including the **HealthInfo** object (where your
   dump showed the health lives), whether each object looks like a live enemy or a parked/placeholder one, and the
   method lists of the health and damage types. This is what I need to build damage/death sync.
6. **Enemy damage trace.** Click, then shoot an enemy once or twice. Since v9.1 it finds the damage and health types of the
   enemies that exist right now (Jack, Marguerite, ... each have their own) instead of guessing two of them, and writes
   the damage records out with their numbers (damage, weapon, ...). Pressing it twice just says the methods were already traced.
7. **Item details.** Opens nothing in the game: it writes what the pointed-at item returns for its name and count (every
   getter I try, with the type it answered with), how many entries the inventory list has and what is inside the first four,
   and the list of readable items. It works even if nothing is pointed at; the old "nothing highlighted" message no longer
   stops it.

8. **Player details and trace.** Writes the player object's components, where health was found (and the object's fields), the fields of the
   damage/status components and the method names that look like damage, guard, heal, death or revive. Then it traces those calls: afterwards
   get hit once, **hold the block button for a moment**, use a Herb, and if you can, go down once (death mode 4 with the bot connected). Calls on the
   player's own health object are marked `[on the PLAYER's HealthInfo]`.
9. **Cutscene / event trace.** Traces the start/end/play/trigger/load-like methods of the event, timeline, flow and chapter classes in your component
   census (`GameEventManager`, `GameEventActionController`, `TimeLineKicker`, `GameFlowFsmManager`, `ChapterLoadTempManager`, `TriggerInAction`, ...) and
   writes the fields of a few live ones. Press it, then walk into a cutscene trigger, open a door, pick up a key item, go through a loading door.

10. **Load screen scan.** Open the Load Game screen first, then press (see v9.6).
11. **Record my player** (v9.7): the hook-free recording described under "What changed in v9.7": guided (block twice, use a Herb) or free (mark things with F6).
    Prefer it to button 8 when you only need to know *what the game changes* while you block or heal; button 8 still tells you which *methods* run.

Then send me `re7mp_debug.json`. You don't need to understand the contents. The results of steps 1 and 3 are kept in a
separate "pinned" part of the file, so tracing can't push them out (that happened in the first file you sent: tracing
flooded the log, and step 1 and 3 weren't in it).

The tracer now skips the methods that fire thousands of times a second, mutes any that still do, and logs each
method's full signature the first time it fires, so unreadable arguments show their type.

## Hiding the other player

- **After a new game** the other player is hidden for 150 s (`HIDE_AFTER_NEW_GAME` at the top of the Lua), so the
  opening cutscene doesn't show a body in the same spot as the cutscene camera. It starts when New Game is pressed
  and again when the synced start happens. Always on since 9.22; the panel shows the countdown and a "Show them now" button.
- **The debug skeleton is never hidden** while it is ticked (since 9.22), whatever else would hide them.
- **Too close:** the body is also not drawn while it is closer than a set distance to your camera. The default is
  **0.4 m** (it was 0.8 m before v9.1), and there is a slider, "Hide them when closer than (m)", at the top of the panel;
  the value you pick is remembered (`hide_near` in `re7mp_settings.json`).
- **Game menus (9.9, reworked in 9.11):** not drawn over the inventory, pause, map, save, tape player and similar screens; a GUI with a name like `MapMaskGUI` is not a menu, and one that stays "open" while you walk is dropped (see "What changed in v9.11"). Tick box in the panel.
- **Walls (9.9, rebuilt in 9.11; since 9.18 doors, door sensors, safe-room volumes and effects no longer count, since 9.19 enemies and area volumes don't either, and a "Probe the walls here" button shows which collision layers hit what; since 9.22 the panel names the last collider that hid them and a button says "that is not a wall" (remembered), names with `stair` do not count, checks run 4 times a second with two in a row needed both ways; since 9.20 a failed calibration is retried after 3 s, 6, 12 ... and at once after a 3 m walk):** not drawn while a solid wall is between you (a ray test from your camera to four points of their body). The panel line `walls:` says `working`, `unavailable` or `switched off`. Tick box in the panel.
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

## Enemies: the host runs them (new, experimental)

Your trace showed what enemies are: root objects named `Em####` (Em2000 = Jack in the garage fight, Em2100 = cutscene Jack,
Em3000 = main-house Jack, Em6100 = Mia), each with Think/Status/Order/DamageController/EnemySave components. Spawns come
from `app.AI.MansionAISetController` and `app.EnemySceneSurveillance`. So:

- **The TCP host's game runs the enemies.** Ten times a second the host reads each `Em####` object's position, rotation,
  health (if a health field can be found), alive flag and animation ids, and sends them as one small text blob through
  `re7mp.exe` (`re7mp_state_out.json` -> TCP, newest wins, so a slow link drops old snapshots instead of lagging).
  The joiner's exe writes the newest blob to `re7mp_state_in.json`.
- Both players need the new exe (protocol v6).
- **Insert > RE7 Multiplayer > Enemies (experimental)**, *Enemy sync*:
  1. *Off*.
  2. *Show the host's enemies as red ghosts* (default): the joiner sees a red box, a name and `HP n` where the host's
     enemies are. Nothing in the joiner's game is touched, so this one is safe.
  3. *Ghosts, and move my own enemies onto the host's (EXPERIMENTAL)*: the joiner's own `Em####` objects with the same
     names are moved onto the host's positions every frame. An optional checkbox also switches off their AI components.
     It is never switched on by itself after a restart. It can break fights, scripted events and saves: use a throwaway
     save. If the host goes quiet for 3 seconds, everything it moved is released.
- **Testing alone.** In Loopback mode over TCP, tick *Draw received enemies even if I am the host*: the bot then sends two
  pretend enemies (`Em9999` circling you at 6 m, `Em9998` standing 8 m from where you first were) and you should see
  both as ghosts. That proves the pipe, not RE7's enemies.

**Stray red boxes (fixed in v9.1).** Your dump showed that not every `Em####` root is an enemy in play: `Em8000` (a Jack
boss variant) sits parked at y = -7.8 with `isStarted = false` and no animation, `Em6190` has no components and sits at the
world origin, and `Em3300` animates but has no Status component (a cutscene prop). The v9 script drew all of them, so
one landed in a wall. Now the host flags such objects in the snapshot (parked / no Status component / at the origin) and the
joiner does not draw or move them. To see what a stray box was, tick *Also draw parked / placeholder objects in grey*:
they are drawn grey with the reason in the label, and the host's panel lists each object with why it is not sent as live.
(If you were testing in Loopback mode with the pretend-enemies box ticked, a box 8 m from where you started is `Em9998`
standing there on purpose.)

**Health.** Your dump showed the `Status` components have no HP field. Health is an `app.HealthInfo` object held by the
enemy's DamageController (`defaultMaxHealth` was 8000 / 10000). v9.1 looks inside HealthInfo for the most health-like
number and logs which field it chose; button 5 dumps the whole object so I can read it properly. Death is read from
`get_IsDead` on the Status where that exists (Em2000/Em3000 had it); a dead enemy's ghost disappears.

**What your damage trace showed (v9.1 file).** Each shot on an enemy runs the same chain: `Collision.CalculateDamage` ->
`EnemyDamageController.sumupDamage/calcDamageValue` -> `DamageController.addDamageCore(DamageInfo{Damage=100, Parts, Side, ...}, type)` ->
`calcDamage` / `adjustDamage` -> `HealthInfo.set_health(float)` -> `EnemyDamageController.doDamage(DamageRecord{CalculatedDamage=210, AddedDamage=210, ...})`.
So one shot did 210. Health is `HealthInfo.Health` / `MaxHealth` (Jack showed 9300 of 10000). The game also has
`DamageController.setHealth(float, float)`, `recoveryHealth(float)` and `addMaxHealth(float)`, and `isOneShotKill(DamageInfo)`.
Floats are not readable inside hooks (they came back as garbage), which is why health is read from the field instead. That was
enough to design "the joiner's shot reaches the host"; it is built in v9.10 (see above), without any hook: the host calls `newFakeDamageInfo` / `addManualDamage` itself. Also seen: all three enemy objects that had a Status were *parked* in that snapshot (`isStarted` false),
even Jack at 9300/10000, so an enemy keeps its health while it is not in play.

What is **not** built: enemy deaths shown on the joiner's own screen (the red box just disappears), spawns/despawns, mirroring animations
(the animation bank/motion/frame ids are sent and shown in the debug dump but not applied), and cutscene enemies.
The health field is found by looking for a `Status` component field with "hp" in its name (not "max"/"rate"); the console
says which field it chose or that none was found. Buttons 5 and 6 under "Send me this" are what I need to do the rest properly.

## Death: choose what happens when a player dies

Insert > RE7 Multiplayer > **Death**. The choice is remembered (`reframework\data\re7mp_settings.json`, which also
remembers the other panel checkboxes).

- **Independent (nothing happens)**: the default until 9.21.
- **Shared fate: both players die**: when one player dies, the other dies too. This is what is built.
- **Downed and revive**: the default since 9.22. It only acts while the other player is connected. See "Health, downed and revive" below.
- "Dead player waits for the other" is in the list but not built; it acts like Independent.
- **Execution test (9.18, experimental, two boxes below the death choice, off at every start):** logs what a grab or finisher calls and can block the game over to go down instead. See the v9.18 section at the top.

How it works, and what is a guess: the script reads the `app.GameManager.GameMode` enum and picks the member whose name
contains *gameover*, *game_over*, *dead* or *death*. When the game switches to that mode the player has died, and the
other player's game is put into the same mode with `setGamemode`. Both halves rest on that guess: the enum may have no
such member (the panel then says so and lists nothing to trigger), or setting the mode may not run the normal death
sequence. The default is Independent so a wrong guess can't kill anyone by surprise. The panel has two test buttons
(send a death message; pretend the other player died, which can kill *you*). Every `setGamemode` call is also logged by
name, so one real death will show the actual mode names. Step 4 in "Send me this" logs everything `app.GameManager` does
while you die.

## Health, downed and revive (v9.3)

Insert > RE7 Multiplayer > **Health and downed**. What is built, in layers, so each can be tested on its own:

1. **Health sync (all death modes).** Your health is read ten times a second and sent when it changes (at most twice a second, plus a heartbeat every
   3 s) as message kind 7 (`h|hp|max|down`). The other player sees `Name  HP 65%` over your head. If the panel says *not found*, send me the debug file
   (button 8): it lists everything on the player object.
2. **Events.** A rise in health shortly after a healing item was used becomes `e|heal|Herb|x|y|z`. A hit is counted, not sent.
   *Block/guard* is not an event: it is a pose (v9.8, `IsGuardCancelAccepted`) that rides along in the position flags.
3. **Down (death mode 4).** With the other player connected and not down, a hit that would take your health to 0 is put back to 1 by a hook right
   after `app.HealthInfo.set_health` (before the game decides you are dead), and by a check ten times a second as a second net. You are then **down**:
   red tint, text on screen, `[downed]` after your name over your head for them (`DOWN` before 9.13), and you can't heal yourself (any rise is undone, with a note in the panel).
4. **Revive.** The other player, within 3 m (slider), either **uses a Herb / Chem Fluid / Remedy** (the heal event above, immediate, costs the item) or presses **F8** and stays within range for 3 s (slider); that uses no item, the wait is the cost, and it works even at full health. You get up **where you are** with 30%
   of your maximum (slider). There is no checkpoint: the game never saw you die, so it never loads one.
5. **Wipe.** If you are down and the other player dies for real (or the reverse), the one who is down dies too. If one goes down while the other is down, the hold
   is off and the game ends as usual. If the other player leaves for 10 s, you get up. A reload or game over clears the down state.

**Honest list of what may not work:** (a) the hold is a guess: if the game decides death somewhere other than after `set_health`, you will still get the game-over
screen; the panel counts "times held at 1" and the death line then says *I held your health at 1 N times and the game still ended*. (b) The **grabs** (Jack
grabbing you, Marguerite's attacks that run as scripted sequences) end the game through their own sequence, not through damage; they will not be held.
(c) Down means "1 health and no self-heal", not yet "lying on the floor": I don't know how to make Ethan crawl or put the weapons away; button 8's trace of
`PlayerExternalRequestController`, `PlayerCommandUpdater` and friends should show it. (d) The `Inventory.reduceItem` hook assumes the item name contains
`herb`, `chem` or `remedy` (your trace showed `Herb`, `ChemicalS`, `RemedyM`). (e) A heal needs the user to be hurt: the game won't let you use a Herb at full health,
which is one reason F8 exists.

6. **No weapon while down (v9.8, experimental).** While you are down the script holds `PlayerSequenceManager.IsAimAccepted` and `IsAttackAccepted` at `false` (the gates the game itself closes during a block) and opens them again when you get up; a checkbox turns it off and the panel counts its writes and how often the game wrote the value back. See v9.8.

Not built: a bleed-out timer, a "dead player waits and respawns next to the other" mode (mode 3), showing a downed player lying down in the 3D body.

## Plan: cutscenes and game events (v9.16 added a first, switched-off step: telling the other player which cutscene started, and moving the joiner to the host; nothing is replayed yet)

### What your trace of the garage fight to the main hall showed (v9.8)

Hooks that fired, in the order of the story (times are seconds in the file; all of these were ticked in button 9 and none stopped the game):

| What happened | Calls seen | What identifies it |
|---|---|---|
| **Interaction events** (get in the car, start it, drive, Jack hits the car, Jack hijacks, crash, Jack gets out, Ethan gets up, ladder up, open a shelf) | `app.InteractObjectBase.successInteract()` on the interact child (`Interact_GetInto`, `Interact_Ignition`, ...), then `app.InteractEventAction.startInteract("InteractAction_PlayerGetInto", Transform)` on the object (`sm9104_EthanCar_Garage`), `GameEventAction.setupEventAction(GameObject(Pl0000), ...)` for each actor, `GameEventActionController.startEventActionTask / startInterp / startEventMotionTask`, and at the end `InteractEventAction.onEndHandler(GameObject(Pl0000), true)` | The **action name string** is readable: `InteractAction_PlayerGetInto`, `_PlayerStartEngine`, `_PlayerDrive`, `_EnemyHit`, `_EnemyHijack`, `_PlayerAndEnemyCrash`, `_EnemyGetOutAfterHijack`, `_PlayerGetUp`, `InteractAction_UpStart` (ladder), `InteractEventAction_OpenR` (shelf). Actors: `Pl0000`, `Em3000` (Jack), `sm9322_Steelframe01A_GarageGimmick`, `sm2242_EthanCarKey_Garage`. A forced stop is `GameEventActionController.endForceTask()` (the `_EnemyHit` ended that way at 622.4, with `onEndHandler(Em3000, false)`). |
| **Story cutscenes** | `app.GameManager.requestEvent("c03e03_00", Transform, EndDelegate, ...)` then `app.GameEventManager.requestEvent("c03e03_00", Transform, false)` on `c03_1_IngameManager`, `GameEventController.requestSetup`, `GameEventSetting.doStart` on `c03e03_00`, `TimeLineKicker.start` for the cameras. It chains: `GameEventAction.requestEvent("c03e03_01", Transform)` -> `GameEventManager.requestEventFromOtherEvent("c03e03_01", ...)`. It ends per actor with `GameEventController.onEndHandler(GameObject(Pl0000), true)`, then `GameFlowFsmManager.sendEventEnded(2679599497)` | The **event id string** (`c03e03_00`, `c03e03_01`: chapter 3, event 3, part 0 and 1). This is the one I'd sync: start the same id on the other PC. |
| **Story progress** | `GameFlowFsmManager.sendBattleEnded(2679599497)` (718.2, the fight is over), `GameFlowActiveControl.sendNo(1000)` on `c03_1_MainFlow` right after the fight (718.2) and `sendNo(1100)` after the cutscene (815.0), each with `GameFlowFsmManager.executeStartGimmick(2679599497, <that number>)` | A flow id (`2679599497`) and a step number (1000, 1100). Host-authoritative progress can send these. |
| **Checkpoints** | `app.SaveDataManager.saveFileAutoRequest(GameObject(1100_Autosave_JackBattleEnd), null, ...)` at 843.9 and `GameObject(1100_AutoSave_BeforeHall)` + `RestartDirection` at 908.4, each followed by ~50 `TriggerInAction.getTriggerInActionSaveData()` calls (the save collecting state; do not hook those) | The autosave trigger's name. |
| **Doors the player opens** | `InteractObjectBase.successInteract()` on `InteractDoor_1WayLock` / `InteractDoor_1WayOpen` / `InteractDoor_ItemOpen`, then `app.DoorPush.setInteract(GameObject(Pl0000), bool, bool)` on the door's own object, then `playLittleOpen(side, ...)` (the first push), `playAutoOpen(side)`, `playOpened(side, ...)`, `playAutoClose(...)`, `playClosed()` | The door object's name: `sm9180_Door07A_1WayDoor` (opened twice: once at 853.2 and again at 898.7), the main hall pair `sm9061_HallDoorH240W100L_ItemKeyLock` / `sm9062_HallDoorH240W100R_ItemKeyLock`. The side argument was 2 each time. |
| **Locked doors and keys** | `DoorPush.lockDoor` -> `closeDoorCore` -> `playClosed` -> `lockDoorCore` on MANY doors at once (846.2, 849.9, 899.0, 906.1, 909.6, 913.4), and `unlockDoorCore` on the key-locked ones (`sm2066_ShotgunDoorIron01A_TrapLock`; the main hall pair when the key item was used) | These come in bursts of many doors at once, around autosaves and story events (846.2 is two seconds after the first autosave and just after `GameEventSetting.doStart` on `sm9049_Gimmick_Locked` and `sm9049_UndeFloorDoor01A_CloseEvent`), and none of them has the player as an argument, so they are the game putting doors in their state, **not** the player opening anything. They must not be sent as player door events; if the story event itself is synced they happen on both PCs by themselves. |
| **The loading door** | The main hall pair: `InteractDoor_ItemOpen` -> `unlockDoorCore` x2 -> `playLittleOpen` x2 -> (914.3, within 0.1 s) `GameFlowActiveControl.eventEndProc()` -> **`app.GameFlowActiveControl.requestChapterJump()` on `c03_1_MainFlow`** -> `executeStartGimmick(2679599497, 1200)` -> `afterEndProc()` -> `GameFlowFsmManager.startGameFlow(true)` -> the next flow starts (`sendNo(100)` on `c03_2_MainFlow`, flow id 744542892) -> `playAutoOpen` x2 (915.4) -> `playOpened` x2 (917.7). Then `GameManager.chapterJumpRequest("Title", false, ...)` (920.2; probably you leaving to the title screen), `ChapterLoadTempManager.releaseChapter1Folder()` / `releaseChapter3Folder()` (920.5) and `GameManager.nextChapterJumpRequest()` (922.7, the end of the file) | `requestChapterJump` is the call that means "this door loads the next area"; the new area has its own flow id (`2679599497` -> `744542892`). |
| Hot or useless | `EnemyStatus.set_enemyStrikeController` ~11,600 times a second (the trace muted it), `TriggerInAction.getTriggerInActionSaveData` (autosave collection), `SequenceController.requestMessage` on `Em3000` (Jack's dialogue lines; 27 times, no text readable) | Never hook these. |

What this means for the plan below:
- **Interaction events (A):** the action name is the same on both PCs (`InteractAction_...`), and the actors are found by name. Rule stays "barrier, then fire on both".
- **Cutscenes (A):** `requestEvent` with the id is the clean start call. Sync = send the id, wait for the other player, call the same `GameEventManager.requestEvent(id, transform)` there. `requestEventFromOtherEvent` chains are the game's own and should not be sent twice.
- **Progress (C):** `GameFlowFsmManager.sendEventEnded / sendBattleEnded(flowId)` and `GameFlowActiveControl.sendNo(n)` are small numbers; the host can send them, the joiner follows.
- **Doors (B):** key on the door object's name plus position. Only the player-driven opens (`setInteract` with `Pl0000` followed by a `play*Open`) are sent; the story's `lockDoor` bursts are not. The loading door (`requestChapterJump`) needs the barrier.
- Still unknown: how the receiving PC should *replay* an open (calling `DoorPush.playAutoOpen(side)` on the matching object is the obvious guess, untested), and what `setInteract`'s two booleans mean (first `true` for `1WayLock`/`ItemOpen`, `false` for `1WayOpen`; so probably "from the locked side").


Your census showed the classes involved. Grouped by what they probably do:

| Group | Classes in your scene (count) |
|---|---|
| Event definitions | `GameEventManager`, `GameEventController`, `GameEventActionController` (17), `GameEventAction` (88), `GameEventSetting` (16), `EventActionController` (80) |
| Cutscene playback | `TimeLineContainer` (15), `TimeLineKicker` (85), `TimeLineKickerContainer` (14), `TimeLinePlayStateControlManager`, `TimeLineStateInfo`, `StampTimelineController`, `SequenceController` (17) |
| Triggers | `TriggerInAction` (94), `TriggerActionAreaHit` (9), `InteractEventAction` (15), `DoorEventAction` (8), `InteractDoor` (38), `MapDoor` (19) |
| Progress / chapters | `GameFlowFsmManager`, `GameFlowActiveControl` (5), `GameSubFlowActiveControl` (3), `ChapterJumpData` (35), `ChapterLoadTempManager`, `Cp3FlowLoadControl`, `UnlockChapter7/8/9`, `FadeControl`, `NowLoadingScreen` |
| World state that gets saved | `GimmickActiveControl` (247), `ForceFsmSave` (48), `OtherObjectSave` (63), `EnemySave` (16), `DisableSave` (10) |
| Player side | `PlayerEventActionManager`, `PlayerSequenceManager`, `PlayerCameraHijackIntegrator`, `PlayerExternalRequestController` |

Four kinds of things have to be synced, each with a different rule:

- **A. Story cutscenes (both players should see them).** One player walks into the trigger. Rule: **barrier, then fire on both**. The trigger is held (the same
  skip-the-original trick the New Game ready-check uses) until the other player is nearby / ready or a timeout runs out; then a message tells the other game to
  start the same event, and each player watches it from their own camera. Needs: the call that *starts* an event and an id that is the same on both PCs.
- **B. World state (doors opened, keys used, gimmicks, puzzle steps).** Mirror like item pickups: hook the call, send `id + new state`, apply the same call on the
  other side (match by GameObject path + position, the way item sync does). `GimmickActiveControl` (247) and the `*EventAction` classes are the candidates.
- **C. Progress (chapter jumps, flow state).** The **host is the authority**; the joiner follows (a chapter jump, or, if that fails, a shared save). Needs the
  `GameFlowFsmManager` / `ChapterJumpData` calls.
- **D. Anything that changes the world around an enemy** (a boss arena closing, Jack's garage fight) goes through the host's enemy channel and A.

In order: (1) **now**: button 9 shows which methods fire and on which objects, and which fields identify an event; (2) log-only mirror: each player's game announces
`Bob: event <id>` in the chat and nothing changes, which proves the ids match across two PCs; (3) B (doors/gimmicks), the lowest risk; (4) A with the barrier;
(5) C. What I need back: the debug file after button 9 while doing one cutscene, one door, one key item, and one loading door.

## Plan: player models, animations and (much later) the DLC

Your idea: once heal, shoot and block can be synced, show them on the current 3D body; later use the game's real character and enemy models, and
eventually the DLC characters. How I would build it, in order:

1. **Actions before animations.** Send what the player is *doing* (idle, walk, run, crouch, aim, shoot, reload, heal, block, down) rather than raw animation
   ids. The first-person arms use their own rig and motion bank; a full-body model has a different skeleton and different motions, so an arms animation
   cannot simply be replayed on a body. An action name can be mapped to whatever the receiving model has. Heal and down are already events (v9.3); shoot,
   reload, aim and block need the traces (button 8) to find their calls.
2. **Record the motion ids.** The player has `PlayerMotionController`, `PlayerLayerWeightController`, `PlayerMeshController` and `PlayerHands` in your census. A
   "watch my motion layers" button (bank / motion / frame per layer, with the time) while you shoot, reload, heal and block gives the action -> motion table. The
   enemy snapshot already carries bank / motion / frame; it is sent but not applied yet.
3. **The 3D body does the actions first.** Raise the arms to block, lift an arm to heal, lean to aim, lie down when down. Cheap, needs no assets, and makes
   the events visible while the real models are worked out.
4. **Real player model.** Either clone a full-body player mesh if the game has one loaded (the *Avatar* experiment is where that is tried; RE7 is first person, so it
   may not be loaded in normal play), or spawn one by name. Then play the mapped motion on it. Every asset comes from each player's own install: nothing is shipped or copied.
5. **Real enemy models.** The joiner's game must have the enemy loaded to show it. Where both players are in the same area it usually is, so mode 3 (moving your own
   copy onto the host's position) can be extended to also apply the host's motion (bank / motion / frame) with the AI switched off. Spawning enemies the joiner
   doesn't have is a separate, harder job (`EnemySpawnInfo`, 13 in your census, is where to look).
6. **DLC.** Each DLC character is probably a different player object, mesh and motion set, so the pose data needs a **character id** (sent once, like the name) and a
   table of character profiles: how to find that character's health, motions and model. The `GameMode` enum has `Extra00` and `Extra01`, which may be the extra
   modes; I would run the census / player details (buttons 3 and 8) inside each DLC to see. Both players would need to own the DLC.

Nothing in this list is built; it only shapes what the debug buttons collect next.

## Co-op saves: sharing a save with the other player

**Share saves (TCP)** is on by default in `re7mp.exe` (since 9.22) when the Steam save folder is found; if it is not found the box starts unticked. The Save folder box must be the one for **the Steam account you play on**
(`...\userdata\<your account number>\418370\remote\win64_save`). Only manual saves (`data001Slot.bin` ... , the Load screen's rows 1, 2, 3 ...) are shared; the Autosave (`data000.bin`) never is. While connected:

1. When one player saves, re7mp.exe notices the new save file once it has sat untouched for a moment (so it never sends
   half a file), and sends it to the other player over TCP, in pieces, with a checksum.
2. The receiver installs it **one slot past the highest save in the folder** (since 9.22; before that it took the sender's own slot number if free), so it cannot sit on a number your next save would use. **It never overwrites one of your own saves**; the only thing it replaces is the earlier copy it installed of the same save when the sender saves again. If the folder is full up to slot 99 it takes the lowest free slot.
3. **The recognizable label.** Every shared save gets a label like `CO-OP Alice 2026-11-06 21:04`. The save files themselves are
   binary, so the label can't be written into them. Instead it is kept in four places: a `CO-OP` notice on screen when one arrives,
   the "Co-op saves" part of the panel (slot number, `[CO-OP: name]`, whether you saved it or received it), `reframework\data\re7mp_coop_saves.json`,
   and, experimentally, **in the game's Load menu itself** (the script rewrites the objective text on screen, not the file; see v9.4 above).
   Saves you made and sent are listed too, labelled with the player you shared them with.
4. Only saves made while the other player is connected are shared. Single-player saves stay private. A save you
   *received* is not sent back.

**One thing that may stop this working, and a 5-minute test.** RE Engine saves may be tied to the Steam account that made
them, in which case the other player's game won't accept a copied file. I can't check that here. To find out
before relying on this: on both PCs turn Steam Cloud off for RE7 (Steam > RE7 > Properties > General), then copy
one `dataNNNSlot.bin` from player A's save folder into player B's save folder under a free number (for example `data009Slot.bin`), start RE7 on B, and look at
the Load screen. If the slot shows up and loads, sharing works as built. If it's missing or "corrupted", saves are
account-bound; tell me, and I'll look at re-encrypting them for the receiver (that needs both Steam IDs and is a bigger
piece of work). Also leave Steam Cloud off while sharing, or it may "restore" or overwrite files in that folder.

**Since 9.12** the exe reads each received file back and checks it, re-checks it every 5 s (a label is dropped if something wrote the file again), records why it chose the slot it did, and the panel says whether the game itself lists that slot (`the game lists this slot` / `THE GAME DOES NOT LIST THIS SLOT`). A save you sent is labelled `[CO-OP: sent to Bob]`. This was added because a 0.6 test showed the label and the partner's name on a slot whose data did not change; the cause is not known yet (see v9.12, point 5).

Testing it alone: use Loopback mode over TCP with Share saves ticked, then save in the game. The loopback bot sends your
save straight back as its own `CO-OP Loopback Bot ...` save, which shows up in a free slot. (This proves the transfer and the
slot/label handling, not the cross-account question above.)

## Enemies: the host runs them

Decided: **the TCP host's game runs the enemies**; the joiner's game shows them. The panel shows who is who ("your game runs
them" / "the other player's game runs them"). Nothing else is built yet: I still need the output of "Collect game info" and
"Scan for enemies" (above) to know how RE7's enemies are put together.

## Design notes: death and the rest of enemy sync (not built yet)

Things to decide and find out before building:

- **Death.** What should happen when one player dies? Options: (a) shared fate: both get the game over screen;
  (b) the other player keeps playing and the dead player waits / respawns at the last checkpoint or save;
  (c) a downed state with revive. Your idea: a downed player is revived when the other player **uses Chem Fluid or a Herb on or around
  them**; you then refined it: they get up **in the same spot**, not at a checkpoint. v9.3 builds a first version (see "Health, downed and
  revive"): the lethal hit is held at 1 health so the game never reloads anything. What is still open is making the downed player actually
  stay down (crawl / weapons away), the grab sequences, and a bleed-out timer.
- **Enemies.** RE7's AI is not deterministic, so two games running their own copy of the same enemy will drift apart. The
  workable design is host-authoritative: one player (the host) runs the AI; the other game shows puppets. For each enemy
  we'd send a network id (matched by name + spawn position), position, rotation, animation/state and health about
  10 times a second, and the joiner's game disables that enemy's AI components and applies the received state. Damage
  the joiner deals is sent to the host as "enemy N took X damage"; the host applies it. The hard parts are scripted
  events, Jack's/Marguerite's special behaviour, and spawning/despawning in sync. Start with plain enemies in one area.
  Now built: enumeration, position/rotation/health reading and the ghosts (see "Enemies"). Still needed: the real health
  and damage calls (buttons 5 and 6), then the joiner's damage going to the host, deaths, and spawns.
- **Transport.** Decided: enemy sync uses TCP only, so snapshots, spawn/despawn, damage and death are all reliable and
  ordered. The cost is some latency on a lossy link; if that turns out to hurt, snapshots could move to UDP later.

## Layout

- `src/gui_win.cpp`: the GUI (plain Win32), game detection, Lua install
- `src/engine.*`: networking thread, names, ready-check flags, reliable message channel, one-shot events, loopback bot (orbit / stationary)
- `src/packet.hpp`: wire format v6 (position + rotation + ready flags, name, event, message, acks, file transfer, enemy state) and name sanitising
- `src/version.hpp`: the release number (`kReleaseVersion`)
- `src/updater.hpp/.cpp`: release check, exe download and swap, REFramework installer (network behind an `HttpClient`, so it is tested with a fake); `src/zip_extract.*`: zip reader with its own inflate;
  `src/http_win.*`: the WinHTTP client (Windows only); `tools/make_zip_fixtures.py` writes `tests/data/*.zip`
- `src/bridge.hpp`, `src/json_mini.hpp`: the JSON file bridge to the Lua script and its small JSON parser
- `src/game_locator.*`: Steam library parsing, Lua installer
- `src/save_sync.*`: co-op saves: save-folder discovery, stable-file watcher, slot picking that never touches single-player saves, the co-op manifest
- `src/transport.hpp`, `src/tcp_transport.cpp`: transport interface and framed TCP with host/join and auto-reconnect (a Steam backend, or UDP again, would slot in here)
- `lua/re7mp.lua`: in-game script (pose sending, smoothing, 3D body + debug skeleton, ready check + block/freeze, RE7 adapter, chat/pings, item sync, item give/drop, enemy sync, death, tracer, probe and avatar tools)
- `src/cli_main.cpp` (`re7mp_cli`): headless engine; `tests/core_tests.cpp` (`re7mp_tests`); `tools/fake_game.py`, `tools/lobby_sim.py` (ready-check simulation); `tools/lua_smoke.lua` + `tools/luarun.c` (runs the Lua against a mock game, see below)

## What has and hasn't been tested

Tested (on Linux): packets and name sanitising, the JSON parser, the bridge, Steam folder parsing, Lua install,
loopback (orbiting and stationary bot, teleport, rotation copying, the full ready check), TCP between two
engines (names, pose, flags, reliable messages both ways, resend and exactly-once delivery when the peer starts late,
TCP reconnect after the host restarts, the host's address restriction), chat/ping echo through the bot, and save sharing
between two engines over TCP (a save lands in a free slot and never replaces a single-player one, the copy is not sent
back, both directions, saves made while disconnected stay private, a 3 MB save, and the loopback echo).
Also tested: the enemy-state packets (encode/decode, bad input, over TCP) and the loopback bot's two pretend enemies
arriving as `re7mp_state_in.json`. The Lua now runs under a real Lua 5.4 interpreter against a **mock** game
(`tools/lua_smoke.lua`: fake scene with `Em2000`/`Em6100` roots, fake inventory and item manager): it loads, the
enemy snapshot has the right fields and ignores non-enemy objects named like enemies, ghosts are drawn and follow
the host's list, mode 3 moves the right object and releases it when the host goes quiet, give and drop messages go in
and out, malformed ones do nothing, the settings file and debug collectors write what they should (1463 checks as of 9.22, including the Load screen labels against a copy of your real SaveMenuGUI scan (`tests/data/save_menu_scan.txt`), the release number and version check, odd item names and an unreadable inventory entry, your parked-enemy case, the HealthInfo path, the inventory list, the item-name-as-managed-string
case, the hide-distance slider, and for v9.3 the player health read, the health/heal/down/up messages, the lethal-hit hold, no self-heal while down, revive by a
partner's heal or F8 and its distance check, both-down and team-wipe, reload and loading-screen cases, the collectors and the receive self-tests). That
proves the script's own logic. It cannot prove the real game accepts the calls.
I also modelled the new-game ready-check state machine in Python (`tools/lobby_sim.py`, 1,000+ scenarios with packet
loss and lag) and checked the 3D body's face ordering and back-face culling logic in Python.

Reported working in-game (by you): the debug logging, the probe panel, the New Game sync, and giving items (the removal and the message; the game's inventory screen only
redraws when reopened). Item pickup sync, death sync, the host role, save sharing, enemy sync, the receiving half of give/drop, player health, the downed mode and everything in v9.3, v9.4, v9.5 and v9.6 (including the Load menu labels and the new save file names) are untested in the game. The stand-in poses and button 11 (v9.7) were run in the game (the recordings came from them), and so were the real block and heal signals (v9.8: your 15:07 file shows the block was recognised and the loopback poses worked). The heal while down, the rebuilt weapon lock and its hook, the crouch, the wall test, the menu test and the enemy health fallback (v9.9) were played with your 0.6 file as the result: the wall test never got going, the menu test pinned on `MapMaskGUI`, the crouch guess was wrong half the time and the heal bit was sent from the inventory screen; v9.11 is the answer to each of those and, like the joiner's damage to the host's enemies with the shot-signal learner (v9.10), is untested in the game. Since v9.16 the same holds for the safe-mode item receive, the optional item creation with its update-step mode, and the whole story sync (cutscene messages and the joiner move): they pass my mock only. The same holds for everything in v9.12 (the rebuilt weapon lock with its gun and movement hooks, the position pin, the two-phase gift with the stack fallback, the gun-call shot signal, the co-op save checks, the version-file fix): it passes against my mock, and that is all that is known.

Tested for the updater: version comparison (0.10 > 0.9), reading titles and tags like yours (`beta5` / `v0.5`), choosing the newest release while skipping drafts and pre-releases,
GitHub error and rate-limit answers, refusing non-GitHub links, fetching the exe directly or out of a zip, refusing a file that is not a program, swapping the exe and putting it back on failure,
the unzip (stored, fixed and dynamic Huffman blocks, a damaged entry, truncated and non-zip files, `../` and drive-letter names), and the REFramework install (clean folder, repeat install,
a foreign `dinput8.dll` with and without permission, your own files kept, dll-only, damaged or loader-less zips changing nothing). **Not run for real:** the WinHTTP download (a fake network stands in), the
buttons and rows in the window, and the swap-and-restart on Windows; I also could not see your releases' asset names (the page only said "3 assets"), so the rules above guess `re7mp.exe` or a zip containing it.

Not tested by me: the GUI (only syntax-checked against stand-in headers), the Windows socket code (the TCP code
has Windows branches that I could only read, not run), and, in the real game, the Lua (it only ran against my mock). In the game itself, unverified: `draw.filled_quad` (the body falls back
to outlines if it's missing), the tracer's hooks and argument decoding, the message files through `json.dump_file`,
chat/ping drawing, and everything under Avatar.
