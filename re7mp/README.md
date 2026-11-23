# RE7 multiplayer prototype

One exe (`re7mp.exe`, a small GUI) and one Lua file (`lua/re7mp.lua`, embedded in the exe and
installed for you). Each player sees the other as a shaded 3D body with a name tag, facing the direction they
are looking, and the two games can talk to each other (new-game sync, chat, pings, item pickups, handing items to
each other, and the host's enemies shown on the joiner's screen).

    RE7 + REFramework (re7mp.lua)  <--files in reframework/data-->  re7mp.exe  <--TCP-->  other player's re7mp.exe

**Licence:** MIT, see `LICENSE`. Code taken from other projects keeps its own notice in `THIRD_PARTY_NOTICES.md`.

**Both players must run the same version.** This one is **release 0.11** (wire protocol v6), so an older
`re7mp.exe` on either side is ignored: both of you need the new exe, and the same script.

## Releases and the version check

- **Release number** (what you publish on GitHub): `0.8` is the published release (0.7, 0.6 and 0.5 before it), this build is **`0.9`**. It stays 0.9 until you say to move it.
  It lives in two places that must agree: `src/version.hpp` (`kReleaseVersion`, used by the exe) and `RELEASE = "0.9"` near the top of `lua/re7mp.lua`.
  A test fails if they differ, so you can't ship half a bump.
- **Build label** (`v9.28`, `BUILD` in the script) is my internal change counter between releases. Ignore it unless you are reporting a bug.
- **Where you see it:** the `re7mp.exe` window title (`RE7 Multiplayer v0.9`) and its first log line, the top of the in-game panel
  (`RE7 Multiplayer v0.9`, and under it `Release v0.9   (script build 9.37, re7mp.exe v0.9)`), and the debug file (`release`, `build`, `exe`, `exe_protocol`, `other_player_version`).
- **The check.** When the other player appears, each script tells the other `release / build / exe version`, and again every 20 s.
  The panel (in red) and the log say so if:
  - the other player is on a different release: *"Bob is on release v0.5 but you are on v0.9: update so you both run the same version"*;
  - their script sends no version at all for 8 s (an older script): *"Bob's script is older than release v0.9"* (never said for the loopback bot);
  - your `re7mp.exe` and your script are from different releases (for example you updated the script but not the exe).
  Separately, if the other player's `re7mp.exe` speaks a different **protocol** (an old exe), the exe can't read their packets at all; its "Other player" row then says
  *INCOMPATIBLE* with both protocol numbers, instead of just showing nothing.
- Nothing is blocked: a mismatch is a warning, not a refusal to connect, since two nearby releases may well work together.
- **A dev build is crowded on purpose (9.27).** The panel has many sections for testing and collecting data. When you tell me you are about to release, or that the next version is the release candidate, I tidy the panel for other players: test and probe sections folded away or removed, the everyday ones first. Until you say so I keep adding to it.


**What changed in each build:** see `CHANGELOG.md`. The newest entries are v10.27 (release 0.11 unchanged; script only, rebuild re7mp.exe so it carries it: the frame dips of the 10.26 file (the automatic model collection waits for a calm moment, the save-slot watch and the debug write wait for the game's saves), the garage car's blind spots (its state is read through the route that answers, the story number through the number holder's real methods, the car and actor probes see more)), v10.26 (release 0.11 unchanged; script and exe: Ethan's friend follows you or stays put with the **F5** key in the game, the follow / stay / beside radios are gone from re7mp.exe, and alpha releases are numbered "v0.11 alpha 3" and ordered in between the normal releases), v10.25 (release 0.11 unchanged; exe only: a bigger window, two "coming later" boxes for BioRand 7 and VR that do nothing yet, and the alpha linked to the main repository; the script only changed its build label), v10.24 (release 0.11 unchanged; script and exe: the "Join the alpha..." button in re7mp.exe, its warning window, and the channel and exe build said in the debug file and the panel), v10.23 (release 0.11 unchanged; script only: the Enemies section moved into Developer tools, and the execution test and Mia's hair physics are gone), v10.22 (release 0.11, the hotfix; script and exe: the cutscene recorder and the spawn log are gone, the door sync is always on and has no section, Enemy sync mode 3 is the default without the "experimental" label, and the two item sections are one), v10.21 (script only: the T-posed stand-in of the host's enemies is off by default and never drawn over a body your own game already has; damage by gun is on by default; a kill of the host's enemy on either side kills it for both; Molded heads and limbs, partly guesswork with a probe file), v10.20 (script only: the frame-gap recorder that says whether a hitch is the script's or the game's, the game's saving flag, finer timing parts, and far fewer looks at the saves, the message inbox and the debug file), v10.19a (re7mp.exe only: the TCP log says why a connection was turned away or dropped, for the Radmin "connected, then read failed" case), v10.19 (script AND exe: a box in re7mp.exe, ticked by default, that turns on enemy sync mode 3 with the copies' AI off and the Molded copies; the garage car fight is shared: whoever gets in first drives, the other player gets in too and their car follows, with damage, run-overs and the end; and a read-only actor probe), v10.18 (script only: the game's story-point numbers are read and compared with the other player's, with an experimental step-by-step matching of a part that is behind; a read-only log of who each enemy is targeting; and an experimental hand-over of an enemy to the player it goes for, so that player's own game runs its AI), v10.17 (script only: Ethan's cutscene animations play on the other body (the actor-tagged entries of an event's `..._pl0000.motlist` were refused before), and the host searches longer for an enemy's cutscene / gimmick banks and records what the enemy's Motion holds), v10.16 (script only: crash defences after the Mia and Jack fights: a boss's health is no longer written or hit by the pool unless a new box says so, nothing is written, made or hit during a cutscene, a load or the 4 s after, the chainsaw and non-weapons are not sent as weapon models, copies are limited to 12 a minute; and a read-only garage car probe that writes the type `app.CarInGarage`), v10.15 (script only: the other player's weapon is shown in their hand, one health pool and a boss bar on both screens, the Molded named by their spawn points and an opt-in copy of them on the joiner, the message inbox read less often while quiet), v10.14 (script only: scripted moves (the van door, a ladder, kicks) and the banks the game adds are shared and played from the move's own motion list, a second small action on a third layer, their block played by the arms so the legs keep walking), v10.13 (new exe and script: Steam sends hellos and logs the session's state and runs as app 480, AfroJackX's models and the icon are inside the exe, cutscene markers (`Pos_...`) are looked up and checked before FORCE, the main body's missing materials are waited for 5 s instead of 14), v10.12 (new exe and script: the joiner plays the host's enemies back on a timeline, the host sends 15 snapshots a second with few enemies, a running bit so run is no longer shown as walk, crawling and lying put the body on the sender's floor, key items and weapons are never put on the ground (the crash) and the EntranceHallKey is shared, the exe's "never confirmed" clock only runs while the other player is reachable, doors open fully and glide, Ethan's hands settle fix), v10.11 (script only: the scene walk every 10 s that caused a frame dip is gone, Mia's left hand is shown again), v10.10 (new exe and script: the Steam invites choice in the exe, the friend's feet measured so its crouch stands on the floor, the floor read from the player object, a 300 ms shot gap, Mia's left arm, Joe's hands, one model check per body, small actions such as touching a door shared), v10.9 (new exe and script: the friend shoots within 5 m of you and blocks within 1 m, its crouch no longer floats, Mia's chest layer kept, Joe borrows Ethan's hands, Pete gets 30 s for his mesh, fewer door angle messages, a bigger exe window, the Steam invite plan and invite line), v10.8 (new exe and script: Ethan's friend fights with its own weapons and ammo, crouches with you, heals itself and takes hits; Clancy's head and hands no longer take his body's material file; the crouch stands 0.20 m higher; a crouched block and the inventory use the saved clips; the REFramework row is gone from the exe window), v10.7 (script only: Ethan's friend acts for itself (own pose, faces the way it moves, blocks near enemies, stands on your trail); crouch / crouch walk / inventory motions; the menu is cleaned up; Clancy's pack body is no longer thrown out because of a hand), v10.6 (script only: Ethan's friend gets you up when you are down (it stays within 3 m for 3 s) and heals you from its own inventory when your health is at or below a level you set (default 40 %)), v10.5 (new exe and script: the loopback bot is Ethan's friend, Orbit is gone and it follows you, the exe's "Appear as" picks the friend's look and not yours, weapons and ammo are shared with it and its own inventory is kept in `re7mp/friend.json`), v10.4 (script only: blocks and other clips on the game's overlay layers are shared, a rig check and no arms-out pose while the clips are listed, faster retries and model checks, Mia's pack head layered, Chris, Zoe and Joe Baker from the pack, a switch for the VR hands layer of bodies that have their own hands), v10.3 (script only: the note about discarding items is at the top of the screen), v10.2 (script only: the other player's body plays the game's own clips from the motion bank, with a self-test and the recorded clips as the fallback), v10.1 (release 0.10: the other player's character from the full models with a fallback, a check 4 s after a switch or a load-in that rebuilds a broken body and tells you only if it stays broken, a motion bank detector for Ethan, the loopback bot's radios fixed, Start no longer checks the script, the REFramework build in the debug file), v9.45 (new exe: one install function that checks the REFramework version, asks, and installs the script and its data; the updater brings the matching script; the full character models ship in `modpack` and are set up with credit), v9.44 (script only: item sync shares only consumables and weapons, never key items like the fuse and the bolt cutters, and a weapon goes to whoever picks it up first), v9.43 (script only: a spawn log that records when Mia spawns, which spawn / load methods the game calls around it, which files she is made of, what my copy of her lacks, and which characters and enemies carry hair physics), v9.42 (script and exe: the save folder is the signed-in Steam account's, a stale folder is replaced, and the two exes tell each other which Steam account they use, so both are named in the log, the manifest, the panel and the debug file), v9.41 (script only: a table of every animation bank and clip the game shows on an enemy, and, in a new experimental box, the joiner plays the host's clip on its own enemy and fetches animation banks its game lacks, the second piece brought over from the other developer's co-op mod), v9.40 (script only: doors are shared with the other player, the first piece brought over from the other developer's co-op mod; plus a loading gate that keeps door calls away from a scene that is loading), v9.39 (script only: FORCE is its own box and switches itself off at the first refusal, because every forced cutscene start in the 9.38 log threw an exception inside the game and probably left Mia frozen; Clancy's hands no longer get another character's material file, with per-part buttons to try the next material file and keep the one that looks right; a slow part is made again once; the crouch stands 8 cm higher; the model check keeps the last reading of every body), v9.38 (script and exe: the loopback bot copies you and has a state drop-down, the cutscene recorder is unlinked from cutscenes with a Record now button, a move for a cutscene the game refuses is taken back, hands with no materials try other material files, click-to-select wording), v9.37 (script and exe: Pete Walken and Andre Stickland as characters, a loopback bot that follows you, parts that did not load are made again by themselves, the model check looks at fresh models every 2 s, the F3 animation probe records speed and distance so the file can say idle, walk or attack), v9.36 (script only: the debug file is no longer written for every item-trail line (the hitching), a frame-time recorder, file-made enemies get their heads once the body has loaded, an every-5-seconds model check that fixes a missing head or untextured model, a loopback enemy picker with a table of which models work and which are still to collect, an inventory note about discarding), v9.35 (script plus the exe's loopback bot: the tape watcher removed, the item journal and the object scan shipped off, models from files shipped on but never Ethan, who is copied from the scene while the new-game timer runs, Mia's playable body with the corrupted Mia's head and chain hair, experimental hair physics, giving the last item shipped on, the bot's circling enemy is Jack), v9.34 (script only: the enemy animations probe, button 12, is also on **F3** now, with a line on screen while it watches), v9.33 (script plus the exe: one **Sync story cutscenes (experimental)** box so that whoever hits a cutscene first brings the other player there and plays it for them too, with a watch-only list; the drop route is the default and the old item-creation route is gone; Mia's head layers; the loopback bot takes friendly fire and can be Ethan, Mia or Clancy; a button that lists the enemies' `.motlist` animation files; **Reset to defaults** at the top of the panel; the release defaults rebuilt; the log spam found in your framework log removed), v9.32 (script plus the exe's 15-save limit: Ethan's body from the scene first, a safer by-path body for Clancy, the held weapon looked for in four places, giving only within 3 m, Mia's own face, an experimental FORCE box that plays the other player's cutscene here too, the recorder stopping on gameplay and F10, the 15-slot save rule, a pickup hook on every `addItem` overload with a both-players-get-it box, an experimental ground-only item route, item data in the debug file), v9.31 (script plus a small exe change: the host's enemies are drawn as their real models with the red box as the fallback, models can be loaded from their files (an experiment), Clancy and Mia as characters with a selector in the exe and the panel, which weapon is held with your gun damage table and optional friendly fire, a journal of pickups and inventory changes for the item sync), v9.30 (script, plus a new `defaults.json` and an exe change: the inventory is found again when the game replaces it (the main house after the dinner), a new install ships with your clips and settings so the body is not a T pose, the mod's own files moved into `reframework\data\re7mp\`, heal items cannot be used while downed, the gun pose is let go, the crouch is lifted, a watcher for the VHS tapes with Clancy and the model ids from the file-list thread, the panel regrouped with the developer tools folded away, the Avatar and Probe RE7 types panels removed, Radmin VPN recommended), v9.29 (script only: one **Real body** box at the top of the panel that makes the Ethan / Mia copy, adds its parts, sizes it, makes it follow and plays the clips by itself, hides the green man while it runs and falls back to it on any failure; the rest pose of a copy is written down for the Mia calibration), v9.28 (script only: face-me and invincibility for testing, body size and part toggles for the copied model, gun poses with a guided gun recording, a cutscene-animation probe, the host can follow the joiner to a cutscene and the event methods are written down, host-side co-op save labels, a model list of 250), v9.27 (script only: executions end the game for both players, the ping can show you where the other player is, a panel for collecting model data, a note that the green man becomes the debug model, effect volumes named VFX no longer count as walls, the body lab and the clip recorder find Ethan in the main house; THIRD_PARTY_NOTICES.md added), v9.26 (script: what the v0.8 test with a friend showed: damage worked out per enemy, one move per cutscene, red boxes hidden behind walls, a clearer message when a count can't be read, a probe for what the "walls" are), v9.25 (script: the host's enemies take the damage you mean them to; the body lab can copy an enemy's mesh) and, in the same package, the exe change after v9.24 (re-signing received co-op saves); release 0.9; rebuild the exe **and** update the script on both computers.

## Updating, and installing REFramework (re7mp.exe)

Two new rows at the bottom of the window, **Updates** and **REFramework**.

**Updates.**
- When re7mp.exe opens it asks GitHub (`api.github.com`, over HTTPS) for the newest release of `kingkiller1195/re7mp`. If it is newer than the exe you are running, the
  button changes to *Update to v0.9*; click it, read what's new, say Yes, and re7mp.exe downloads the new version, swaps itself (the old file stays as `re7mp.exe.old` until the
  next start), and restarts with your settings. **The script follows the program:** the update also installs the matching `re7mp.lua` and `defaults.json` into your RE7 folder (taken from the same release), and the new exe then checks REFramework and the script once by itself when it starts. The check can be switched off with the
  checkbox; *Check now* does it by hand. The only thing sent is an ordinary web request (GitHub sees your IP address) with the user agent `re7mp/0.9`.
- **How a release has to look.** The version is read from the release **title** (`v0.5`), because your tags are `beta5` and so on; a tag is only used if it looks like a
  version (`v0.6`). Attach **`re7mp.exe`** to the release (or a zip that contains it). If the release has no exe, the update stops with a message pointing at the releases page. GitHub's
  automatic "Source code" archives are not used.
- **Your internal/debug builds stay private.** Only published releases are offered, never drafts, and never releases marked *pre-release*. Playtesters you give builds to can
  see pre-releases too by adding `include_prerelease=1` under `[re7mp]` in `re7mp.ini` (next to the exe); it is not in the window, so normal players don't see it. A
  build with a newer number than the newest release (an internal 0.9 before 0.9 is published) is never "updated" back.
- **The alpha (10.24; linked in 10.25).** The button "Join the alpha..." (Updates row, right of the check box) is in every build; everybody starts on the normal releases. With an alpha linked it
  looks up the newest alpha build, shows what has changed and a warning (*even more broken, or fixed*), and only on Yes switches `channel=alpha` in `re7mp.ini` and installs it. On the
  alpha, "Check now" and the check at start look for alpha builds; "Leave the alpha..." goes back to the normal releases. (10.26) An alpha release is a GitHub release, flagged *pre-release*, whose title or tag
  says `v<release> alpha <n>` (`v0.11 alpha 3`, tag `v0.11-alpha-3`); the normal updater never offers one. Alphas are **in-between versions**: alpha n of a release X sits between the release before X and X itself (newer than the earlier alphas, older than the normal X), so the normal v0.13 is newer than `v0.12 alpha 10` and so is the normal v0.12; a player on the alpha is offered the newest of ALL the releases (alpha or normal), and a player on the normal releases never sees an alpha. The script says which alpha it is (`ALPHA = "3"`, `"0"` for a normal release) and re7mp.exe reads that from its own copy. It is linked (10.25) to the SAME repository as the normal releases, `kingkiller1195/re7mp` (`RE7MP_ALPHA_REPO` in `src/alpha_channel.hpp`; `alpha_repo=owner/name` in `re7mp.ini` beats it): an alpha is a release there that says `alpha <n>` and is flagged *pre-release*; the normal (stable) release is the one that is not. Until the first alpha is published the button says that none is, and changes nothing. `tools/pack_alpha.py` packs a release (and refuses an exe built without the link); `tools/test_pack_alpha.py` checks that. See CHANGELOG.md, v10.24, v10.25 and v10.26.
- Safety: only `https://` links on github.com and its download hosts are followed; the download must look like a Windows program (and be at least 64 KB); if anything fails
  the running exe is put back exactly as it was. There is no signature check beyond GitHub's HTTPS: whoever can publish on your GitHub account can publish an update.

**REFramework.**
- The window shows whether `dinput8.dll` is in your RE7 folder and whether this program put it there. *Install* downloads
  `https://github.com/praydog/REFramework/releases/download/v1.5.9.1/RE7.zip` (the release you named: `kReframeworkTag` in `src/updater.hpp`; change it only after trying a newer one).
  When you press *Install / update mod* in a folder without the tested REFramework it asks whether to install it (see 9.45 below; since 10.1 Start no longer does this). Which build to use: see "Which REFramework" under 10.1.
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
     **Recommended: Radmin VPN** (free, Windows, no router settings; tested with this mod). Both players install it and join the same Radmin network
     (one creates it, the other joins with its name and password); each then has a Radmin address of the form 26.x.x.x. The host picks *TCP: I host*, the joiner picks
     *TCP: I join* and types the host's Radmin address and the port (for example `26.12.34.56:27015`). If Windows asks whether `re7mp.exe` may use the network, allow it.
     Tailscale or ZeroTier work the same way (join the host's VPN address and port); with neither, the host has to forward the port on the router.
     **Connects, then drops one second later ("TCP: connected to the host", then "TCP connection lost (read failed)")?** The host's *Other player* box is filled in with an address that is not the one the
     joiner connects from, and the host turns the connection away. Clear that box (it is optional) or type the address in the joiner's log after "the host sees you as". Since 10.19a the host's log also says
     "TCP: turned away a connection from ...", and a drop shows the OS error number.
5. **Share saves (TCP)** is ticked by default when the Steam save folder is found (untick it to keep saves private); check the **Save folder** (it is detected from Steam:
   `...\userdata\<your id>\418370\remote\win64_save`). See "Co-op saves" below.
6. Click **Start** (it installs/updates the Lua script), start RE7, load a save. Press Insert for the "RE7 Multiplayer" panel.

**Loopback bot.** *Follows you* (9.37) walks after you, stops 2 m away, and is put next to you after a teleport or a new area (`--bot-follow` for the command line version). *Orbits you* circles you at 3 m, walking. *Stays put* teleports the bot to where you are and keeps **(10.26: the radios (follows, stays put, beside you) are gone from the window; F5 in the game switches follow / stay put, see "10.26" below.)**
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
Crouching is sent since 9.9; gun out, aiming and firing since 9.28; the held weapon's model is shown in their hand since 10.15 (see below); holding other items is not.

**The green man is the debug model (9.29).** While the **Real body** box (top of the panel, see "9.29" below) is running, the green man is not drawn; "Also show the debug model" brings it back next to the real body, and it comes back by itself whenever the real body is not up (box off, a step failed, no idle clip file, a new scene being rebuilt). The Real body box is **off by default** in 9.29 (`CFG.REAL_BODY_DEFAULT = false` at the top of the script) until it has been tested in the real game; flipping that one line makes it on for everyone who has not chosen for themselves, and from then on the green man is the debug model, off by default. The panel says the same under "Debug skeleton (lines)".

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

## Model probe: finding Mia, Ethan and the enemy models (9.22, reworked in 9.23)

Insert > RE7 Multiplayer > **Model probe (Mia, Ethan, enemies)**. Two read-only buttons; nothing is cloned, moved or hidden.

**Scan the characters here.** It walks the scene and lists every object that carries a mesh and whose name matches one of the words in the box (default `pl;em;mia;ethan;jack;marguerite;lucas;zoe;chara`). A word of one or two letters (`pl`, `em`) has to start the name of the object or of a parent and be followed by a digit (`Pl0000_Chapter1`, `Em2000`), so `Plants` and `Emitter` do not match; a longer word matches anywhere. The box **"Only meshes under Character/"** (ticked) leaves out everything whose mesh file is not under `Character/` (plants, props); the status line says how many were left out. Each entry has the object name, mesh file, material count, joint count, distance from you, position and path. The same mesh file is listed at most 3 times (`mesh_counts` has how many there were), and at most 90 entries are kept. **The whole joint list** (name, parent, and where each joint is in centimetres relative to the object, `joint_cm`) is written for the player's own model first (any mesh under `Character/Player`, nearest first), then for big character models (at least 40 joints), one per mesh file, up to 6 in all; when there is none of those, the three nearest. Stand next to the character you want looked at (Mia in her cutscene, the headless Mia on the shipwreck, Ethan, an enemy), press it, then send the debug file (`health.model_probe`, and `model probe:` lines in the journal). The mesh and joint calls are guesses at the engine's method names; an entry says `mesh_note` or `joint_note` when a call gave nothing.

**List the engine's model methods.** Writes the methods (with signatures) of `via.GameObject`, `via.Scene`, `via.Prefab`, `via.Folder`, `via.render.Mesh` (its creating/drawing methods and, since 9.23, all its setters), `via.render.MeshResource`, `via.motion.Motion` (and, since 9.24, its setters, `via.motion.TreeLayer` and the motion bank types), `via.motion.JointMap`, `via.Transform`, `via.Joint`, the mesh and material holders, `via.ResourceHolder` and `via.Component` that have to do with creating, copying, drawing and posing, to the debug file as `health.model_types` (a type this game does not have says `not found`). Making a second Ethan body of my own (not a copy of your player object, which would copy his controls too) can only be written against what the engine really has.

What the real files showed (start of the game, next to Ethan's car): Ethan is the object `Pl0000_Chapter1` (85 components: his controls, camera, inventory and so on) with the body mesh `Character/Player/pl0000/pl0001/pl0001.mesh` (158 joints, 2 materials, a complete skeleton: `root`, `Hip`, `Waist`, `Stomach`, `Chest`, `Neck`, `Head`, `Cam`, `R_`/`L_` `Shoulder`, `UpperArm`, `Forearm`, `Hand` with all the fingers, `Thigh`, `Shin`, `Foot`, `Toe`). His other drawn parts are children of that object, each with its own mesh and part of the same skeleton: `Pl0000HandL` (`pl0020`, 66 joints), `Pl0000HandR` (`pl0010`, 65), `Pl0000LowerBody` (`pl0002`, 20) and the codex (`pl0023`). His head (`pl0050`, 253 joints) and copies of the body, hands and lower body sit under `ShadowBody`; those are `enabled False`: they only cast his shadow, so he has no drawn head in the game. The game builds those copies as plain objects of a Transform and a `render.Mesh` (plus a `PlayerMeshTag`). Joints, at standing height in centimetres: hip 99, chest 129, neck 146, head 159, camera 160, thigh 90, shin 47, foot 7; shoulders 136, upper arms 140 (arm positions depend on the pose). The stand-in body's proportions (hips at 0.56 of the eye height, knees at 0.28) already agree with this.

## Collecting model data for me (9.27)

Insert > RE7 Multiplayer > **COLLECT MODEL DATA for me (F11; what to collect is listed here)**. It is a dev-build panel and is allowed to be crowded. It lists **what I need**, with a `[x]` when something that matches has been collected: Ethan, Mia (her cutscenes, the axe fight, the headless Mia on the shipwreck), Jack (the garage fight, any Em2000 cutscene), Marguerite, Lucas, Zoe, the Molded (stand near one of each kind: the smallest and the big ones), and every other enemy or character you meet (`Em####`, any new name).

How to use it: get 3 to 10 m from the character, look at them and press **F11** (or the button). It also works in cutscenes, where the menu cannot be used, as long as the character is a real object in the scene; a cutscene that is a pre-rendered video has nothing to collect. Type what is on screen in the **Note** box (for example "Mia, attic cutscene"): it is saved with the models, together with the newest cutscene id the story hook has seen in the last three minutes (that needs "Story sync" ticked). A second tick box collects by itself every 20 s (it can stutter a little each time). Each press shows its progress on screen for 6 s.

Everything adds up in **`reframework/data/re7mp/models.json`** (one entry per mesh path: the names it was seen under, the notes, its materials and, for up to 24 of them, the whole joint list; at most 70 models) and it is read again at the next start, so you can collect over several sessions. **Send me that one file** when you have a few models, not after every scene. "Clear everything collected" starts the file again. The debug file's `model_collection` says what was collected and what the last press did. Unverified in the real game.

**What the main-house file showed (9.27, read from the owner's file `b1b2982a`, build 9.26).** In the main house Ethan's object is plain `Pl0000` (the car, the forest and the guest house call it `Pl0000_Chapter1`). The body is the same mesh as before (`pl0001`, 158 joints, 2 materials); the **left hand is a different mesh**: `pl0021` (66 joints, 1 material) where the guest house has `pl0020`, because his hand has been cut off. The right hand (`pl0010`, 65), the lower body (`pl0002`, 20) and the codex hand (`pl0023`, 8) are unchanged, and the disabled shadow copies are there too (`ShadowHead` is `pl0050`, 253 joints). So the other player's Ethan cannot be one fixed set of meshes: the hand has to follow the story. The same scan also listed the parked enemy pool at one spot 27 m away (`Em2000` (the owner says his copy of it is Mia, and her height and hair agree; older text called it Jack from the garage fight, so the `Em####` names are not a stable identity), `Em3100`, `Em3200` with a 180-joint body, `Em3500`, the Molded `Em4000`, `Em5400` and the bug swarms `Em55xx`) with mesh paths and joint counts; their joint lists are what the F11 collection is for. Nothing was built from this yet except letting the lab find him under both names.

## Real body lab: a second Ethan of my own (9.23, experimental)

Insert > RE7 Multiplayer > **Real body (experiment: a second Ethan of my own)**. **Off until you tick "Switch the body lab on"**, and it can crash the game: every step is written to the black box (`re7mp/trail.json`, listed in the next debug file as `previous_item_trail`) before its engine call, so the next start names the step that died. Press the steps one at a time.

The idea: not a copy of the player object (that copies his controls, camera and inventory), but a new, empty object (`via.GameObject.create`) with a `render.Mesh` component (`createComponent`) that is given Ethan's own mesh and material holders, like the game's own shadow objects. Whether the game accepts this is exactly what this tests.

- **Run the steps in the game phase:** `UpdateBehavior` (default, the game's update step), `LockScene` or `UI frame` (the render frame). A step waits for that phase and is given up after 8 s if it does not come. If a step crashes in one, try another.
- **Object to copy (9.25).** Ethan (`Pl0000_Chapter1`) by default (9.27: in the main house his object is called plain `Pl0000`, so both names find him: `Pl0000_Chapter1` is tried first, then `Pl0000`; the recorder does the same). Type any scene object's name instead, for example an enemy `Em2000` (Jack), or press **Use the nearest enemy (Em####)**, which picks the closest root named `Em` plus four digits that looks active (placeholders at the world origin or without a Status component are only used when nothing else is there). Steps 1 to 3 then work on that object: an enemy's root has no mesh of its own, so its body is the drawn part below it with the most joints, and its other parts are the drawn parts with the same kind of mesh (`Character/Enemy/...`; weapons and shadow-only copies are left out). A copy of an enemy is stood beside **you**, not where the enemy is. The debug file's `health.body_lab.copying` says which object is being copied.
- **1. Look at Ethan's parts (read-only).** Names his object, mesh, material and joint counts, and the drawn parts under it (the shadow-only copies and the codex are left out). Nothing is created.
- **2. Make the body.** Creates the object `re7mp_body`, adds the mesh component, gives it his body mesh (`setMesh`, else `set_Mesh`) and material (`setMaterial`, else `set_Material`), reads them back, stands it 1 m to your right at his feet facing the way you face (in 9.23 it stood on your left; fixed in 9.24), and writes what the new component reports (mesh ready, joints, draw flags).
- **3. Add the hands and the lower body.** One child object per drawn part, parented to the body (`set_Parent`) with `set_SameJointsConstraint(true)`, so their joints should follow the body's.
- **It follows the other player** (the loopback bot does): the body stands at their feet and turns with them, every frame of the chosen phase. The shaded stand-in is still drawn as before.
- **Joint to turn / axis / angle / Hold that joint turned.** Takes a joint name (from the model probe's list, e.g. `R_UpperArm`), reads its local angles once and sets them plus the angle around the chosen axis every frame; unticking puts it back. This is the test of whether the game lets me pose the skeleton myself (the new object has no animation, so the joints should stay where I put them).
- **4. Remove the body.** Children first, then the body. A script reset does it too. If the scene changes (a load, a new area) the game takes the objects down itself, so the references are dropped without calling destroy.

The result is in the debug file as `health.body_lab` (the lines, errors, phase), and in the journal as `body lab:` lines. What I need back: which steps worked, whether you can see the body beside you (headless is expected), whether it follows, whether the joint turns, and, after a crash, the debug file of the next start.

## Damage to the host's enemies, and a better model than the red box (9.25)

**Why the damage was too small (your 2026-11-08 note).** The joiner's hit was 30 "damage" by default; the one real shot I have a trace of (v9.1) took **210** off Jack's 10000 health (the game's call said Damage 100, CalculatedDamage 210). So 30 was about a seventh of a real shot. Changes, all in the script:
- The default is **210**; the slider "Damage per hit" goes 1 to 600 and the limit per hit is 1500. A saved 30 from the old default is ignored, so you get the new default even if the settings file says 30.
- **The host measures what the game really took off** and corrects the next hits for it: when a hit is applied, the host reads the enemy's health before and after (after the game has had a moment to apply it), keeps the ratio of "taken off" to "asked for", and hands the next hits `asked / ratio`. The panel shows `the game's multiplier is x...` once it has measured. (If the game's own damage call already applies its multiplier, the ratio comes out near 1 and nothing changes.)
- The debug file's enemy-hit report says `effective_ratio`, `ratio_measured` and `ratio_last`.
- **Not verified in the real game.** What I still do not know: whether the host's damage call applies the game's multipliers at all, and whether a headshot or a weapon type should count differently (the joiner sends one number).

**The model.** The red box stays the fallback. The way to a real enemy model on the joiner is the body lab (above): copy the enemy's mesh onto an object of my own and see whether the game draws it. What this build adds is only the test: tick the body lab, stand near an enemy, press **Use the nearest enemy (Em####)**, then **1** (Look) and **2** (Make), and send the debug file. Two open questions it answers: does an enemy's mesh go onto my own object like Ethan's did, and is the mesh loaded on the joiner's computer at all (an enemy that is not in the joiner's scene may have no mesh to copy; then the mesh path would have to be sent and loaded by the joiner, which is the next step if this fails). Nothing draws an enemy model for the joiner yet.

**What the v0.8 test with a friend showed (9.26).** The host's file lists the 10 hits it applied. Eight were handed to `Em2000` at 30: seven of them took exactly 30 off (x1.00), the first took 39. Two were handed to `Em8000` at 110 (the joiner had moved its slider from 30 to 110) and took 77 and 77 off (x0.70). So the game's multiplier is not one number for everyone: since 9.26 the host keeps one per enemy name (the panel's `per enemy:` line and the debug file's `ratio_by_enemy` list them), and a new enemy starts from the last one measured until its own first hit is measured. On the joiner's side, of the 66 shots tested only 8 had a red box in the line of fire, 57 had none and 1 was behind a wall; the gun hook saw 63 shots and used all 63, so the shot signal itself works (the learner found nothing, which does not matter while the hook works). The default is 210 since 9.25. Not verified in the real game: the 9.25 and 9.26 numbers.

## Animation clips: recording Ethan's joints and playing them on the second body (9.24, experimental)

Insert > RE7 Multiplayer > **Animation clips (experiment: record Ethan's joints, play them on the body)**. Nothing happens until you tick **Switch the clip recorder on**. Recording only *reads* Ethan; it changes nothing in him.

The body lab (above) showed that a joint of my own body can be turned from the script. A clip is simply how Ethan's joints move: the **local angles of his joints, 20 times a second**, in thousandths of a radian, plus the hip's position (so a crouch drops the hips), his speed, and the game's own **motion ids** (bank / motion / frame of the first layers of his `Motion` component, 4 times a second) written next to them, so each label can be tied to the ids the game uses for it. Each take is kept under a label in `re7mp_clip_<label>.json` in the data folder, and a new take of the same label replaces the old one.

**Recording**
1. Tick the box, pick **What I am about to do** (`auto` files it by itself: the pose flags at the start, then how fast you moved: under 0.3 m/s idle, under 2.4 walk, faster run; or idle, walk, run, crouch, crouch_walk, guard, heal, inventory, aim, shoot, reload, melee, other). Write a **Note** if you like.
2. Do the thing in the game, press **F10**, keep doing it, and press **F10** again, or wait for the **Longest recording** (8 s by default, 2 to 20). A red `REC` line on the screen shows it is running.
3. The journal says what was saved: the file, the length, your speed, and how many joints turned by more than 0.05 rad, the most moving first (`moving` in the file and in the debug file). **That list is how we find out where Ethan's animation lives**: his first-person body may keep its legs and spine still and animate the arms on the hand objects instead, so the file also holds the arm and finger joints of `Pl0000HandL` and `Pl0000HandR` (box **Also record the two hand objects**; a bigger file, about 200 KB for 8 s).
Good takes: idle (stand, 6 s), walk (straight, 4 s), run, crouch (still), crouch_walk, guard (block), heal (use a herb or spray), inventory (open it and look), aim, shoot, reload, melee. Walking straight on level ground makes the best loops.

**Playing** (on the body from step 2 of the body lab)
- Tick **Play the clips on the body**. The clip is chosen from what the other player does: inventory (flag 512), heal (128), guard (64), crouch (256, with crouch_walk when moving), else idle / walk / run by their speed. A label without a clip falls back (crouch_walk to walk, crouch, heal, guard and inventory to idle, run to walk); the journal says `Play: idle (instead of heal)`. The **Play** list can force one clip.
- Between clips the pose is eased over a quarter of a second. A clip loops without a seam (its last quarter second is blended into its first). Walk, run and crouch_walk are played faster or slower in proportion to the other player's speed against the speed the clip was recorded at (from 0.6 to 1.6 times).
- The angles (and the hip's position, if the body accepts it) are written to the body's joints every tick of the game phase chosen in the panel (**Clips: run in the game phase**, the same choice as the lab's). The hands and the lower body follow through their same-joints constraint. If a write fails the playing stops with a line.
- **No network message is needed**: both players need the same clip files in the data folder (copy them over; the other player does not have to record anything).

In the debug file: `health.clips` (the clips that were read, each with length, speed, frame and joint counts, the joints that moved, the motion ids, the start flags, the joints that were not found, and the journal lines). Send the `re7mp_clip_*.json` files too if you want me to use the motion ids or the hand objects' data.

Unverified in the real game: all of it. Things I do not know: which joints really move on his first-person body; the order of the engine's Euler angles (each angle is blended on its own, and an angle that flips by more than 1.5 rad between two frames is not blended); whether the hip's position looks right with the body's own placement; whether the engine's constraint on the parts keeps the hands in step.

## 9.28: testing tools, body size and parts, gun poses, the cutscene probe (the probe was removed in 10.22)

All of this is tested with the mock game only and **unverified in the real game**.

**Testing tools (panel > "Testing tools (dev build)").** *Face me*: the other player's body (the loopback bot too) turns to look at you, sideways only, so you can see the model from the front. *Invincible*: any hit is undone at once by putting your health back to full; it does not stop an execution or an instant game over. Both are off at every start and not remembered.

**Body size and parts (Real body lab).** A size slider (0.50 to 1.50, remembered), a button **Match Ethan's height** (sets the size from the height of the Head joint of the copy against Ethan's, stand up straight first) and a **Show part** box for the main body and for each part (remembered by name), plus **Hide the hair parts**. The hair of a copied enemy is a separate mesh moved by cloth / chain physics components that belong to the original object; the copy has the mesh and the materials only, so it hangs rigid, and a material that was not loaded when the character was scanned is drawn as plain grey. The **cloth probe** writes the cloth-like components of the original's parts and their fields into the debug file (`health.body_lab`) so a later build can copy them; the physics is not copied yet. The playable Mia (`Pl2000`) is the better mesh to copy for her than `Em2000`.

**Running (10.12).** Bit 13 of the same flags (8192) says "I am running" (my own speed over 0.2 s steps against the middle of the recorded walk and run speeds, 3.28 / 2.88 m/s with the default clips; never while crouched). The receiver plays the run clip when it is set, or when its own estimate of their speed is above the bar. **Crawling / lying (10.12):** the `low` event carries the camera's height above the sender's own floor (cm) while it is under 0.9 m, and the other body is stood on that floor.

**Gun poses.** The flags carry three new bits: gun out (1024), aiming (2048), just fired (4096). *Just fired* is the gun's own `shoot` / `shootStart` call, kept 0.4 s. *Gun out* is `PlayerGun.actionID` not 0 until a recording teaches better. *Aiming* needs a recording. The other player's label shows `[gun out]`, `[aiming]`, `[shooting]` and the clip player picks `gun_idle`, `gun_walk`, `gun_run`, `gun_crouch`, `gun_aim` or `gun_shoot` (a missing clip falls back along the chain shoot > aim > idle with a gun > idle, run > walk). The stand-in itself has no gun arms.

**What to record for the gun (button 11, third button: "Record my player with a GUN").** You need a gun you can aim and fire (a mod menu is fine). Follow the prompts on screen: gun away (4 s), gun out, not aiming (5 s), hold aim (5 s), let go (4 s), hold aim again (5 s), let go (4 s), aim and fire three single shots then press **F6**, walk with the gun out (6 s), stand still (3 s). The report in the debug file lists the fields that changed exactly with the gun being out and with aiming; the best of each is used at once and saved with the settings (a box switches the learned signals off, a button forgets them). Then send me the debug file. For the arms, record clips with F10 (labels `gun_idle`, `gun_walk`, `gun_run`, `gun_crouch`, `gun_aim`, `gun_shoot`, `gun_reload`; "auto" files them from your own pose).

**The cutscene probe (panel > "Cutscene probe").** Tick the box and play. Each time the game starts a cutscene or event this records (25 s by default, slider 5 to 40) which animations play near you (every object with a Motion component within 40 m: its bank, id and frame, four looks) and Ethan's own joints. Files: `re7mp_cutscene_<id>.json` and `re7mp_clip_cs_<id>.json`. Send both and say what the scene was. One cutscene at a time; the same id again within 60 s is not recorded twice. Remembered. Nothing is changed in the game.

**Event triggers.** *Story sync* can now also move the **host** to the joiner's place when the joiner starts a cutscene (a separate box, off at every start). The game manager's event methods are written down (panel line and `health.story.request_event_signature`: `requestEvent`'s parameter types and every `app.GameManager` method with event, cutscene, timeline or demo in its name). Playing a cutscene on the other game is **not** built: it needs those arguments. See `re7-findings.md` for the plan.

**Co-op saves, host side.** A save you make while connected is labelled "[CO-OP with Bob]" on the Load screen even when you host (a slot that is new while someone is connected is written down in `re7mp/coop_played.json`). Saving over an existing slot cannot be told; use a new slot.

**Walls.** The game hides a real model behind walls itself; once the real body is shown, untick the two wall options. They stay for the green man. (9.29: with the Real body box running, the green man is not drawn at all, so the wall probes only matter for the name tag; they can stay ticked.)

## 10.27: the frame dips, the garage car's blind spots, the story number (unverified in the real game)

**Rebuild re7mp.exe (the exe's code did not change; it carries the new script and `defaults.json`). Release 0.11 is unchanged.** See `CHANGELOG.md` (v10.27) for what the files showed and the whole list.

- **Frame dips.** The hitch every 20 s was the automatic model collection (the "Collect by itself every 20 s" box): it now scans at a calm moment (a menu, a cutscene, or when you stand still for 1.5 s), after 2 minutes at the latest, and never while the game saves or loads. The 200 to 600 ms stalls were the save-slot watch and one debug-file write falling into the game's saves: both wait for the save now. The network part's 1.0 ms a frame is split into four timed parts (`net: pose gather`, `pose file write`, `pose file read`, `inbox read`) so the next file shows which one it is.
- **The garage car.** The car's state was read through a route that answered nothing in the real game, so no claim ever happened: both routes are tried now and `garage_car.fsm` says which one works. The story number (it said "nil") is read through the number holder's real methods (`get_CastS32`, `get_S32` ...): `story_flow.number_read_by` says which. Windows are asked one by one when the car has no flag number, `HitWall` counts as a fight state, and a state nobody listed no longer ends a fight after 10 s.
- **Probes.** The car probe lists 520 fields (it stopped at 220), describes `CurrentAction`, reads the state machine both ways and the car's two controllers. The actor probe sees up to 80 objects of a type (it was 3) and keeps the order of a state machine's states (`fsm_trail`).
- **What to send next:** a session in the garage with a friend: `re7mp/debug.json`, `car_sync.json`, `car_probe.json` (pressed once before the fight and once in it) and `actor_probe.json` (on for the whole fight), plus the debug file from a normal 10-minute run with the model collection ticked.

## 10.26: F5 follows / stays put, alpha numbers (unverified on Windows and in the real game)

**Rebuild re7mp.exe (script and exe; it carries the script and `defaults.json`). Release 0.11 is unchanged.** What a player sees, and what to look for:

- **Ethan's friend: one key.** Press **F5** in the game and the friend stays where it stands; press F5 again and it walks after you again. A line in the top right corner says which it is and what F5 does next ("Ethan's friend follows you (F5 = stay put)"). It shows only while the friend is the other player. **F7 is still the item "Give" key**: it was already taken, which is why this one is F5.
- **The window is clearer:** the "Follows you / Stays put / Beside you" radios are gone (and "Beside you" altogether, and `--bot-beside` in the command line version). What is left in that row is "Move friend to me" and a one-line note that F5 does the rest. An old `bot=` line in `re7mp.ini` is ignored (and removed the next time the window saves).
- **Alpha releases are numbered: "v0.12 alpha 3"** (a pre-release on GitHub). The sequence is: v0.11 stable, then v0.12 alpha 1, 2, 3 ..., then v0.12 stable, then v0.13 alpha 1 ... (an alpha is named for the release it is heading to). They are in-between versions: the normal v0.13 is newer than "v0.12 alpha 10", and so is the normal v0.12 (an alpha leads up to the release it is named for, so a tester on "v0.11 alpha 5" is offered v0.11 when it is published). The alpha channel offers the newest of all releases. The script's `ALPHA = "3"` says which alpha it is; `tools/pack_alpha.py` refuses a normal release (`ALPHA = "0"`) and an exe built with another number.
- **To publish an alpha** (after v0.11 stable is public; v0.11 itself is built with `ALPHA = "0"` and carries the "Join the alpha..." button): for the FIRST alpha of v0.12 set `RELEASE = "0.12"` in `lua/re7mp.lua` AND `kReleaseVersion = "0.12"` in `src/version.hpp` (they must be equal; a test and the packer check it, and an exe that disagrees would call itself "v0.11 alpha 1" and offer itself "v0.12 alpha 1" over and over), set `ALPHA = "1"`, rebuild re7mp.exe, run `python tools/pack_alpha.py --exe <your re7mp.exe>`, then follow `dist/alpha-0.12-1-release.txt` (title `v0.12 alpha 1`, tag `v0.12-alpha-1`, tick **pre-release**, leave "latest" unticked). Each next alpha: `ALPHA` one higher, rebuild, pack. For the v0.12 release itself put `ALPHA` back to `"0"` (RELEASE stays 0.12) and publish it as a normal release. A v0.12 alpha player meeting a v0.11 player sees the existing "is on release v0.11 but you are on v0.12: update" warning line, as for any two releases; two alpha testers on 0.12 only get the "another build" note.
- **The order, decided after you said v0.11 is not public yet:** alpha n of release X is OLDER than the normal X (the alphas lead up to it). The first reading I built was the opposite (alpha newer than the normal release), which would have left a tester on "v0.11 alpha 5" never offered the final v0.11. To get the other order back, set `kAlphaFollowsItsRelease` to `true` in `src/updater.hpp` and rebuild; the tests pass for both.

## 10.25: a bigger window, two "coming later" boxes, the alpha linked (unverified on Windows)

**Rebuild re7mp.exe (exe only; the script just says build 10.25). Release 0.11 is unchanged.** What a player sees, and what to look for:

- **A bigger window (760 x 870) with a strip at the top:** "Coming later:", two boxes, **BioRand 7 randomizer** and **VR support**, and the line *NOT IMPLEMENTED YET - we are only preparing*. Everything else is where it was, only 80 lower, and the fields that reached the right edge are wider.
- **The two boxes do nothing.** They start off and are saved as `biorand=` and `vr=` in `re7mp.ini`; ticking one shows a warning window (OK only). Nothing reaches the script, the game or the other player. They are the switches a later version will hang BioRand 7 and VR on.
- **The alpha is linked to `kingkiller1195/re7mp`**, the same repository as the normal releases. To publish an alpha: build re7mp.exe, run `python tools/pack_alpha.py --exe <your re7mp.exe>`, then on GitHub make a new release with the title and tag from `dist/alpha-10.25-release.txt`, attach the zip, tick **pre-release** and leave "latest" unticked. A normal release is a release that is not a pre-release.

## 10.24: the alpha channel (unverified on Windows and in the real game)

**Rebuild re7mp.exe: the exe carries the script, `defaults.json` and the new button.** What a player sees, and what to look for:

- **A second button in the Updates row: "Join the alpha..."**, right of "Check for updates when this opens". It is in every build; with no alpha linked it shows the warning as a preview (OK only).
- **With an alpha linked:** "Looking...", then a window "JOIN THE ALPHA?": what has changed in the newest alpha build, the warning (*even more broken, or fixed*), the source repository, Yes / No (No is the default). Yes saves `channel=alpha`, installs the build and restarts; the button then reads "Leave the alpha...".
- **In the game:** an alpha tester's panel has the line "ALPHA channel (re7mp.exe build ...)", and the debug file has `channel` and `exe_build`. When the other player runs another build of the same release, the panel says so.
- **For you:** `python tools/pack_alpha.py --exe <your re7mp.exe>` packs a release (it refuses an exe built from another script build, and refuses to pack at all until an alpha repository is linked and built into the exe: an alpha exe without it would send every tester back to the normal releases at its first start). "Link it" = the repository name in `src/alpha_channel.hpp`.

## 10.23: Enemies moved into Developer tools; the execution test and Mia's hair physics are gone (unverified in the real game)

**Update `re7mp.lua` and `defaults.json` (script only; rebuild re7mp.exe to carry them, or copy the two files by hand). Release 0.11 is unchanged, so players on 10.22 and 10.23 still connect.** See CHANGELOG.md for the full list. In short:

- **Enemies is in Developer tools now** (Developer tools > Enemies, closed until you open it). Same controls, same saved keys. The player's own switch for enemy sync is re7mp.exe's box "Sync enemies and the Molded" (ticked by default); the mode behind it is a setting, so moving the section changes no behaviour. Older sections of this file that say "panel: Enemies" mean Developer tools > Enemies from now on.
- **The execution test is gone** (the log of grab / finisher / game-over calls and the "block the game over" option). **Executions still end the game for BOTH players** (box in the Death section, on by default), decided from the health alone, with no hooks.
- **Mia's hair physics are gone** (the box, the status line, the probe button, `health.hair`, `hairstate.json`). Her head parts and "Hide hair parts" stay.

## 10.22: the 0.11 hotfix: defaults and a tidier menu (unverified in the real game)

**Rebuild re7mp.exe: the exe carries the script, `defaults.json` and the release number (now 0.11).** What a player sees, and what to look for:

- **Release v0.11 (build 10.22).** The panel title and the first line say so; both players need 0.11 or the panel warns about the mismatch.
- **Gone from the panel:** the *Cutscene probe* and the *Spawn log* sections (and the hooks and scene scan the spawn log used), and the *Doors* section.
- **Doors are always shared.** No box any more: when one of you unlocks, opens, closes or pushes a door, it happens in the other game (the debug file's `health.doors` still says what was sent and got).
- **Enemy sync starts on mode 3** ("Ghosts, and move my own enemies onto the host's"), without the experimental label or the warning line; the section is just *Enemies*. The choice is remembered under a new key, so **everybody starts on mode 3 once** (the old key held ghosts-only for everyone). Choosing ghosts only in the box still works and is remembered.
- **One *Items* section** with the pickups first and give and drop under it (same boxes, same saved keys).
- **Try it:** both players on 0.11; a door opened by one opens for the other; a Mia or Molded fight with nothing standing inside the real enemy; give an item and drop one from the one Items section. Send both debug files if anything is off.

## 10.21: no T-pose stand-ins, damage by gun, kills both ways, Molded limbs (unverified in the real game)

Script only: update `re7mp.lua` and `defaults.json`. Full list and limits: `CHANGELOG.md` (v10.21). Nothing here has been tried in the real game.

- **The stand-in model of the host's enemies (the T pose) is off by default** (*Enemy models* box, remembered under a new key, so an old saved "on" is ignored). It is also never made, and no red box is drawn, for an enemy that your own game already has a real body of: one mode 3 moved onto the host's, or a Molded copy. That was the Mia screenshot: the real Mia stood on the host's and the stand-in was drawn a second time inside her. `health.enemy_models.real_body_there_so_no_model` lists the skipped ones.
- **Damage by gun is on by default.** Your gun table times the scale 2.1 is what a shot at the host's enemy sends (an M19 shot 252, not 210); a gun that is not in the table sends the flat number and is counted. `health.enemy_hits.by_gun` shows what each gun sent. Melee and headshot multipliers are not synced.
- **A kill counts for both.** If your copy of the host's enemy dies here first, after 0.7 s the host is asked to kill its own (box *Share kills*, message kind 21). Never a boss, never during a cutscene or a load, four asks at most. `health.kill_sync` shows the asks and the host's answers.
- **Molded heads and limbs** (box *Share Molded limbs and heads*, message kind 22): a part lost on one side is removed on the other's copy, but only through a game method the script can recognise by its shape, because the game's own member names are not known yet. **Send me `re7mp/limb_probe.json`** (it lists the lost-parts classes' members) and the debug file's `health.limb_sync` (what it found, what it read, what happened to each removal). With no way to read the lost parts it sends and removes nothing.
- Two older crash-marker bugs fixed: a remembered "models on" no longer overrides a crash marker, and the loader's "off after a crash" is written to a settings file that already exists.

## 10.19: the garage car, the enemy box in the exe, the actor probe (unverified in the real game)

See `CHANGELOG.md` (v10.19) for the whole list and the limits. In a debug file: `health.garage_car`, `health.enemy_sync_tick`, `health.actor_probe`, and `re7mp/car_sync.json`, `re7mp/actor_probe.json`.

- **re7mp.exe: "Sync enemies and the Molded" (ticked by default).** Ticked = enemy mode 3, the copies' AI off, the host's Molded copied. The script applies the file once per change. **The exe must be rebuilt** for this box.
- **The garage car (panel: Enemies; on by default; needs mode 3).** The first player into Jack's car drives; the other player's game fires its own get-in so they ride too, and its car becomes a puppet that follows the driver's car. Jack follows the driver. Windows, body, door and tyres are mirrored once each; Jack running a player over costs them a guarded hit; the end (explosion) is played on both and the rider gets out. Buttons: "Get me out of the car", "Let go of the car now". Everything is written to `re7mp/car_sync.json`.
- **Actor probe (reads only; off at every start).** Lists scene objects that run their own script like the car (movement or character controller, not an enemy or a player) to `re7mp/actor_probe.json`.
- **Correction.** The garage Jack is `Em3000`, not `Em2000`.

## 10.18: story points, enemy targeting, the enemy hand-over (unverified in the real game)

See `CHANGELOG.md` (v10.18) for the whole list and the limits. In a debug file: `health.story_flow`, `health.story_match`, `health.enemy_targets`, `health.enemy_handover`, and `re7mp/flow_probe.json`.

- **Story points (panel: Story sync).** The game numbers the steps of each story part (`app.GameFlowFsmManager.Flows`, hash of "<part>_Main"). The probe (on at every start, reads only) shows my numbers next to the other player's and writes the game's own types to `re7mp/flow_probe.json`. *Matching* (a box, EXPERIMENTAL, off at every start) takes a part that is behind forward through the game's own `sendNo`, one step at a time, never back, only in a quiet moment; "Catch up once" does one pass; "only write the number" is the fallback when the game ignores a step.
- **Enemy targeting (panel: Enemies).** A read-only log of who each nearby enemy's AI is going for and how far it is from each player.
- **Enemy hand-over (panel: Enemies; EXPERIMENTAL; BOTH players tick the box; mode 3 on both).** An ordinary enemy (not a boss, not a Molded) goes to the player who is clearly nearer, and that player's own game runs its AI; the host's body follows and takes the owner's health; it goes back when the host is clearly nearer, a load starts, or the link goes quiet.

## 10.17: cutscene animations (unverified in the real game)

See `CHANGELOG.md` (v10.17). The 20 November debug files showed that a cutscene's animation lives in its own motion list (`Animation/Ingame/cXX/cXXeYY_ZZ/motlist/cXXeYY_ZZ_pl0000.motlist`): it was added to the other body as bank 30 without a failure, but its entry (`cXXeYY_ZZ_pl0000_000`) was refused because the rule only played names that start with `pl0000`. Now an entry that carries the actor's tag, ends in `_PL`, or comes from a list file ending in `_pl0000.motlist` plays as it is; a prop's or weapon's own clip still does not. For Mia (banks 1 and 3: the chapter-event and gimmick lists) the host retries the bank search later (six more tries, 20 s apart) and writes what her Motion holds into `health.enemy_clips.banks.<enemy>.<bank>.search`; no paths are copied from a sibling enemy. In a debug file: `health.motion_banks.scripted_moves` (`counts.own_other`, `lines`), `health.enemy_clips` (`counts.paths_found_late`, `banks`).

## 10.16: crash defences, the quiet check, the garage car probe (unverified in the real game)

See `CHANGELOG.md` (v10.16) for the whole list and the limits. Nothing here has been tried in the real game. The two crashes of 20 November (after the Mia fight, in the Jack fight) left no crash crumb in either debug file, so their cause is not proven; 10.16 removes what the files show the script doing at those moments. In a debug file: `health.guard`, `health.boss_pool`, `health.weapon_models`, `health.car_probe`.

- **Bosses are left alone by default.** The pool's follow of the host's health does not write to a boss (the bar still shows the host's number); a new box (EXPERIMENTAL, off at every start, not remembered) allows lowering only (never raising, never when the two maxima differ by more than 1 %), and there is never a damage call on a boss: when the host's boss dies, mine is left to the game's own story.
- **The quiet check.** Nothing is written, hit, made or changed while the game loads, an event has just started, a cutscene plays (event list non-empty AND `isPlayingEvent` not false) or one ended less than 4 s ago. It only reads; if the game will not say it lets things through and `health.guard.source` says "unreadable".
- **Weapon models.** Only `wp####` objects or `Weapon/` models; never the chainsaw (`wp0060`); not during a quiet-check hold; copies are let go (never destroyed) on a load; at most 12 copies a minute.
- **Garage car probe (reads only).** A box in the panel: writes `re7mp/car_probe.json` with the type definition of `app.CarInGarage` and, in the garage, three readings (now, +5 s, +15 s) of the object's plain fields, game object and components, and the fields that changed. Send that file after standing in the garage. Nothing is synced or written to the game.
- **If the game still closes:** send `lastcall.json` (reframework/data/re7mp), `re2_framework_log.txt` and `reframework_crash.dmp` from the PC that closed.

## 10.15: the weapon in their hand, one health pool, the Molded (unverified in the real game)

See `CHANGELOG.md` (v10.15) for the whole list, the limits and the bugs the checks found. Nothing here has been tried in the real game (the harness fakes the game's answers). In a debug file after a session with the other player: `health.weapon_models`, `health.boss_pool`, `health.molded_spawn_points`, `health.molded_copies`, `health.bridge_reads.message_inbox_poll` (and `health.perf`, to compare with the 10.13 file: 1.5 ms a frame on average).

- **The weapon in their hand (message kind 17).** The game that holds a weapon sends its mesh and material file, where it sits on its joint and the joint's name; the other game makes one mesh object from those files and hangs it on the other body's right-hand joint (`R_Wep`, else `R_Hand`, `R_Wrist`). One still mesh: no scope, flashlight, muzzle flash or moving parts, and the knife needs half a second in the hand. Panel box "Weapon: show the weapon in their hand" (remembered); a session that ended inside it switches it off at the next start (crash stage `wmesh`).
- **One health pool and a boss bar.** The host's number is the pool. In mode 3 the joiner's copy of an enemy takes the host's health (lower at once, raised only after 1.5 s so a shot that was just sent is not undone, never below 1) and is finished when the host's enemy dies; the maximum rides in the snapshot as a 14th field. A bar at the top of BOTH screens shows a boss's name, health and share. Two boxes in the panel (remembered).
- **The Molded.** The host names them from the game's spawn points (`Em4000_<12 hex digits of the point's GUID>`, the same in both games; sleeping bodies are not sent; at most 14), so they are no longer lost in their pool. A separate EXPERIMENTAL box on the joiner (off at every start, never saved) brings the same Molded out in the joiner's own game and moves those real bodies onto the host's, the way Molded Together does (at most 8; AI off; the host's clip played; killed when the host's dies; let go after 5 failed moves; crash stage `molded`).
- **Cheaper inbox.** The message inbox is read every 0.1 s while nothing arrives (about 10 reads a second instead of 33) and at the old rate for 2 s after a message.
- **Try it:** two players in the same area; one holds a gun (the other should see it in the hand); a boss or a Jack fight in mode 3 (both bars the same, the joiner's copy dies with the host's); the Molded box ticked on the joiner near some Molded. Send the debug file from both sides.

## 10.14: scripted moves, added banks, the second small action (unverified in the real game)

See `CHANGELOG.md` (v10.14). The van door, a ladder, the sheet metal and the body-bag kick play from their own motion list (the other game's list is added to the body as bank 30, message kind 16), the banks the game adds at run time are shared, a second small action plays on a third layer (`actb`) and a block is played by the arms. In a debug file: `health.motion_banks.scripted_moves` (what was sent, what was added, what was mapped to a character's clip and what could not be). The panel has a box "Scripted moves" (not remembered) that switches the sharing off.

## 10.13: Steam that starts itself, the models and the icon inside the exe, cutscene markers (unverified in the real game)

See `CHANGELOG.md` (v10.13) for the whole list. In a debug file: `health.story.markers` (per cutscene: the `Pos_<cutscene>_<actor>` markers each game found, what was missing or moved, how the wait ended; `all_pos_markers` is the story panel's button), `health.model_settle.body_materials_wait_s`. In the exe log: the lines starting `Steam:` (the app id the link runs as, the session's state, the relay, a hint after 20 s of silence).

- **Steam.** The link now sends a hello at once and every second until it hears the other player; "relay ready (100)" alone never started a session. The exe runs as Steam app 480 (Spacewar); `steam_app_id=` in `re7mp.ini` changes that (418370 is the game's own id and made the exe look like a second copy of the game). The Steam connection is started once per run.
- **Models and icon.** `re7mp.exe` carries AfroJackX's model pack (22 MB) and its icon. `tools/pack_models.py` rebuilds `modpack/third-person-full-models.zip` from `modpack/third-person-full-models`; `src/app.rc` embeds it. The tests check that the zip installs the very same files as the folder.
- **Cutscene markers.** See the changelog: looked up, told to the other player, checked before FORCE plays a cutscene, listed by a button.

## 10.12: enemy timeline, run bit, crawl floor, key-item drops (unverified in the real game)

See `CHANGELOG.md` (v10.12) for the whole list. The pieces to know about when reading a debug file: `health.enemy_timeline` (how the joiner plays the host's enemies back), `health.run_or_walk` (the run bit and the bars), `health.low_body` (crawling / lying and the floor the body is stood on), `health.items.ground.refused_not_consumable` (what the ground route refused) and `health.doors`.

## 10.11: the 10-second frame dip, Mia's left hand (unverified in the real game)

**Script only: update `re7mp.lua` and `defaults.json`** (the 10.10 exe stays). See CHANGELOG.md. In short:

- **The dip every 10 seconds** was the "Play as" module walking the whole scene for the player object; it now checks the remembered object against the camera first and walks only when it is lost or not where the camera is (`health.who.player_search` counts the walks).
- **Mia's left hand** is shown again (10.10 hid it; her left arm from the game's `pl2020` holds the codex and has no hand of its own).

## 10.10: Steam invites, the friend's feet on the floor, Mia's arms, Joe's hands, small actions (unverified in the real game)

**New script AND a new `re7mp.exe`: update both.** See CHANGELOG.md for the full list. In short:

- **Steam invites:** a third connection choice in the exe window beside "TCP: I host" / "TCP: I join". Enter your friend's Steam ID (or pick them from your Steam friends, or paste their invite line) and press Start: the two exes talk through Valve's relay, no port forwarding or VPN. **Copy my invite** gives you the line to send. The TCP choices still work. Not verified against the real Steam yet (see the plan in the project).
- **Ethan's friend:** its feet are measured and stood on the floor when it crouches (no more sinking), the floor under you is read from your player object, and it shoots no faster than every 300 ms (slider).
- **Models:** Mia's left arm is the game's `pl2020_hand` (arm and hand that go with her right arm), Joe borrows the hand files the other developer's mod tries and Ethan's hands as the last resort, and a model that was checked once is not checked again (the 4 to 6 s frame dips).
- **Small actions:** touching a door or wall, the codex and similar are shared and played on a second animation layer over the walk (switch in the panel).

## 10.9: shorter shooting and block distances, a crouch that does not float, Mia's chest, Joe's hands, the Steam invite plan (unverified in the real game)

**New script AND a new `re7mp.exe`: update both** (an old exe still runs with the new script; the window and the save log wording are in the new exe). See CHANGELOG.md for the full list. In short:

- **Ethan's friend** shoots enemies within **5 m of you** (slider 2 to 25 m), blocks only within **1 m** of an enemy (slider 0.5 to 5 m), gets down into a crouch at once, and no longer floats when it crouches: it has its **own crouch slider** (-2 to +0.6 m). The crouch slider for a real player's body goes down to -2 m as well.
- **After a game over** Ethan's friend gets up at full health and is put next to you once the reload has finished (new exe command `revive`; switch and a test button in the Ethan's friend box; an old exe only gets it up).
- **Mia's chest:** the `pl2000_VR` layer is hers (the chest), not VR hands, so the VR-hands rule leaves it (and Joe's leg layer) alone; the Face lines in the debug file list every layer with on/off.
- **Pete** gets 30 s for his mesh to stream in (it was 10 s) and a failed try is retried after 6 s. **Joe** borrows Ethan's hands (the guessed Joe hand files do not exist).
- **Doors:** angles go out every 0.35 s and only for a 5 degree move, the other game swings the door smoothly between them; the cost of the `setInteract` hook is counted in `health.doors`.
- **The exe window** is bigger so the text next to "Appear as:" is not cut off; the save line in the log says which Load screen row the file is.
- **Steam invite:** a plan is saved in the project (`claude/re7-steam-invite-plan.md`); this build only has the invite line format (`src/invite.hpp`), tested.

## 10.8: Ethan's friend fights, crouches with you; Clancy and the crouch fixed again (unverified in the real game)

**New `re7mp.exe` and a new script: update both** (an old exe runs with the new script, only the friend's exact self-heal needs the new one). See CHANGELOG.md for the full list. In short:

- **Ethan's friend fights.** It has its own weapons and ammo now (give them with F7 within 3 m: they leave your inventory), shoots the enemies near **you** (line of sight ignored) with damage by the gun it carries, takes the rounds out of its own inventory, says "I'm out of ammo!" when it is out, uses a healing item on itself below a health level (default 40 %), and takes damage when an enemy reaches it (simulated by distance: the game's AI does not know it exists). Everything is in the "Ethan's friend" box of the panel, with a debug section (`health.friend.fights`).
- **It crouches when you crouch.**
- **Clancy:** the head and the hands no longer take his body's material file (the black head and hands). A slow load gets a second look; the hands use the game's `em3010` / `em3020` files first.
- **Crouch height:** the body stands 0.20 m higher (was 0.08). The slider is in Developer tools > Real body and in the Ethan's friend box.
- **Crouched block and inventory** show the crouch with the arms of the saved clip; `health.game_motion.by_state` says what plays for each state and where it came from.
- **The exe window** has no separate REFramework row any more: "Install / update mod" does it.

## 10.7: Ethan's friend acts for itself, a cleaner menu, the pack for Clancy (unverified in the real game)

**Update `re7mp.lua` and `defaults.json`; no exe change.** See CHANGELOG.md for the full list. In short:

- **Ethan's friend acts for itself** ("Ethan's friend does: Acts for itself" is the default; "Copies me" is still in the list). Your crouch, gun and aim are not copied; it blocks when an enemy is within 5 m, shows the heal pose while it heals you, faces the way it last moved, and stands on the floor you walked on (a trail of your steps) instead of hanging at your height on stairs. It does not fight yet (10.8).
- **Crouch, crouch walk and inventory** are played on the other body from the recorded Ethan clips, and a crouched block shows the crouch.
- **Menu:** Start together, Co-op saves, Find item hooks and Model probe are gone from the menu (`"show_retired_panels": true` in `re7mp/settings.json` brings them back). The debug files for the developer are one compact box at the top of Developer tools.
- **Models:** Clancy comes from the pack again (a hand that does not load is left out instead of throwing the pack out); Joe's two guessed hand files are tried and dropped if they do not exist.

## 10.6: Ethan's friend helps you (unverified in the real game)

**Update `re7mp.lua`; no exe change.** See CHANGELOG.md for the full list. In short:

- **It gets you up.** When you are down and the friend stays within 3 m for 3 s (the revive sliders), you are up again. No item is used.
- **It heals you.** When your health is at or below the level (default 40 %, a slider from 10 to 80 % in the panel's "Ethan's friend" section) the friend uses a healing item it carries (give it a Herb or First Aid Med with F7, within 3 m) on you. The use takes 2.4 s and only then does the item leave its inventory. A Herb gives back about 25 % of your maximum health, a First Aid Med about 33 %, a Strong First Aid Med everything (estimates).
- The panel section says what it is doing and has the switches; the log and the debug file (`health.friend.helps`) say what it did. It does nothing for a real player on the network.

## 10.5: Ethan's friend (unverified in the real game)

**New re7mp.exe and a new script; see CHANGELOG.md for the full list.** The loopback bot is now **Ethan's friend**, an AI helper you play with alone (no network). In short:

- Start re7mp.exe in the "Ethan's friend (play alone)" mode. It **follows you** by default; (10.26) press **F5 in the game** to make it stay put and again to make it follow you (a line in the top right corner says which). The radios in the window and "Beside you" are gone; Orbit went in 10.5.
- In that mode the drop-down above Start is **"Appear as"**: it sets what the **friend** looks like (Ethan, Mia, Clancy, Pete, Andre, and Chris, Zoe or Joe when the model pack is installed). Your own character is not changed.
- **(Until 10.7) weapons and ammo were shared** (from 10.8 the friend has its own: see 10.8 above): the friend uses yours, so giving it a weapon or ammo is refused and you keep it. Anything else you give it (F7, within 3 m) is its own inventory, kept between sessions in `re7mp/friend.json` and listed in the panel's "Ethan's friend" section and in the debug file (`health.friend`).
- Not built yet in 10.5 (10.6 adds the revive and the heal): the friend does not shoot or hurt enemies and does not hand anything back.

## 10.4: layer clips (blocks), a rig check, the DLC characters and the VR hands layer (unverified in the real game)

**Update `re7mp.lua` on both computers; no exe change.** See CHANGELOG.md for the full list. In short:

- **Blocking and healing.** The game plays them on layers 1 and 2; layer 0 stays on Idle. The sender now reads those layers and sends the clip as a `mol` event; the other player's body plays it. `health.motion_banks.other_layers` lists every clip pair seen there.
- **Rig check and no arms-out pose.** The body's Motion is off until its first clip, each clip id is listed once, a body whose rig does not fit is left to the recorded clips. Retries and the model check are faster (3 s and 1 s; check every 3 s).
- **Mia, Chris, Zoe, Joe.** The pack's Mia head is layered (her own skin on, the corrupted one off). Chris, Zoe and Joe Baker (the pack's `pl1000`, `pl3400`, `pl9000`) are characters with the full models; the pack (`modpack.json`) is needed. Pick them in the in-game panel (the exe's list is unchanged).
- **VR hands layer.** A material named `..._VR` is switched off on a body with its own hands (Clancy); a new box in the layer section turns the rule off.
- If something is wrong send `debug.json` (`health.game_motion`, `health.motion_banks`, `health.model_pack`) and, for a look problem, `models.json` and a screenshot.

## 10.2: the game's own animations on the other player's body (unverified in the real game)

**Update `re7mp.lua` on both computers; no exe change.** See CHANGELOG.md for the full list. In short:

- **All animation from the motion bank.** The other player's body gets a `via.motion.Motion` component, given the bank asset and joint map of your own player's Motion, and layer 0 plays the game's clips: first the pair the other player's Ethan plays (the `mot` event, with their weapon set), else the clip of the right name for what they do (`Hands_Walk_Loop`, `Hands_Jog_Loop`, `Hands_StandDamage_Loop`, `Hands_WalkCrouch_Loop`), else a pair the detector learned. Anything the bank has no clip for is still played from the recorded clips, and a failure puts them all back.
- **Checked before it is trusted.** A self-test plays the walk clip for 2 s: the frame must advance and the joints must move. A failed step, a frozen layer or a crash inside it (next start) switches it off; the top left says so once. Nothing is said when it works.
- **The box** "Animate it with the game's own clips (the motion bank) instead of my recorded ones" in "Other player's body" (default ticked; remembered in `re7mp/game_motion.json`) and a line under it with what it is doing.
- **Debug file:** `health.game_motion`. If something looks wrong send it: it holds each step's result, the self-test numbers, the pair playing and every clip name of the bank.

## 10.1: release 0.10 (unverified in the real game)

**New re7mp.exe and a new script; see CHANGELOG.md for the full list.** In short:

- **Full character models as the other player's body.** With AfroJackX's pack installed (the exe writes `reframework\data\re7mp\modpack.json`), Clancy's, Mia's and (when the scene has no copy of him) Ethan's body and head are asked for as `coop/Character/Player/plXX00/plXX01/plXX01.mesh` (+ the `.mdf2` beside it; heads and extra parts from `plXX02` ...), hands the pack lacks from the game. A model that will not load: that character uses the game's own model for the rest of the session and the top left says so. Debug file: `model_pack`.
- **The check after a switch or a load-in.** 4 s after the other player's body is up: read it; fine = silence; broken = made again, looked at 2 s after the new body is up, again once more; still broken = one line at the top left. Debug file: `model_settle` (every look, rebuild and what was said).
- **Motion bank detector (Ethan).** Reads his layer-0 bank / clip pair, names it, labels it, keeps the table in `motion_banks.json`, sends `mot` events; the other player's body uses a fresh label for a reload or a melee swing. Debug file: `motion_banks` (pairs, names, labels, how often a name disagrees with what you were doing). Walking, running, crouching and aiming still come from the pose flags and the speed.
- **Loopback bot.** The radios (Orbits you / Stays put / Follows you / **Beside you**) now work with the "copies me" act; only a one-state act (walk, run ...) places the bot by itself. Command line: `--bot-beside`.
- **Start** no longer checks the script (Install / update mod does).

### Which REFramework (what the 2026-11-14 13:46 crash and the nightly builds show)

**What your game ran.** `re2_framework_log.txt` of that session: REFramework **v1.5.9 + 7 commits, commit 5bae470, built 5 March 2025**. That is the build inside the stable **v1.5.9.1** release's `RE7.zip` (the file this program's *Install* downloads: `kReframeworkTag` / `kReframeworkAsset` in `src/updater.hpp`). The session before (13 Nov 16:35) ran the **nightly 01433** build (commit d4611ae, built 21 Oct 2026, the one the other developer pins and tested); its log stops 1.3 s after the start (why is not in it), and the older 23 MB `dinput8.dll.bak` next to the current 13 MB `dinput8.dll` is that build.

**The crash.** An access violation (`c0000005`, address `DINPUT8.dll + 0x583ab0`, RCX = 0, a null pointer) inside REFramework's own code, 2 s after the Object Explorer's type list and enum dump had been printed (13:46:08 to 13:46:09) and at the first draw of the Object Explorer window. Every frame of the call stack is REFramework's own `DINPUT8.dll` code or the game's render thread; none is this script's. It cannot be proven from a 290 KB dump that the script played no part (it has 54+ hooks and Lua callbacks running in the same process), but nothing in the log points to it. The crash on 8 Nov (same build) was at a different place, in `re7.exe` called from a REFramework callback.

**Is the nightly worth trying?** What can be said from public information (the nightly's release notes list no changes at all; the commit list I could read ends at 16 Sep 2026, and the nightlies go up to at least 01439):
- Between the March 2025 build and the nightly: Lua fixes (string / number ambiguity, array element and string creation, unboxed value-type calls on static methods, a null-reference when invoking a value-type method), callbacks (`re.on_*` callbacks can remove themselves; `on_pre_gui_draw_element` now honours a `false` return), a fix for a signed displacement in the hook manager, a dependency update that may fix a hang / deadlock, dev-UI fixes (a collapsed Hooked Methods window, the config being saved every frame with Configuration open), `log.set_level`, and the **monolithic `REFramework.zip`** (one DLL for all RE Engine games; the per-game `RE7.zip` is gone, and non-RT builds of RE7 are not supported in it).
- **No commit title mentions RE7 or the Object Explorer**, so there is no sign that it fixes this crash. It might (the UI code changed), it might not.
- **What switching would cost in this project:** (1) the installer: another URL (`REFramework-nightly` release, asset `REFramework.zip`), install **only `dinput8.dll`** from it (the other developer's installer does exactly that, with a SHA-256 pin), no VR files, a new `kReframeworkTag`, and a way to tell the version of an installed `dinput8.dll` (today: "put there by this program" or unknown); the C++ tests use a fake RE7.zip and would need a fake nightly; (2) the script: nothing is known to break, but the changed Lua behaviours are in the areas the script uses most (calls with numbers and strings, arrays, value types, callbacks), and the script has only ever run on the 2025 build, so a full in-game pass is the only test; the debug file's new `reframework` block says which build a report came from.
- **Recommendation:** keep v1.5.9.1 as the pinned, documented build for now, and try the nightly on your own machine first (replace `dinput8.dll`, keep the old one as `dinput8.dll.bak`, play the usual test, send the debug file: it says which build it is). If the Object Explorer opens and nothing else gets worse, the installer pin is a small change (a few lines plus tests). Until then, do not open the Object Explorer with this mod loaded on the 2025 build; the mod does not need it.

## 9.45: one install, an updater that brings the script, the models from their author (unverified in the real game)

**New re7mp.exe.** The window code could not be built where this was written; the logic behind it (`src/installer.cpp`) is tested.

- **One function does the install.** *Install / update mod* (and, since 10.1, only it and the run after an update; Start does not) runs these steps: (1) check REFramework against `v1.5.9.1`; if it is missing, another version, or a `dinput8.dll` this program didn't put there, ask whether to install the right one (yes: download, verify, install, old dll kept as `dinput8.dll.bak`; no: carry on, the log says the mod will not run); (2) install `reframework\autorun\re7mp.lua` and `reframework\data\re7mp\defaults.json` and say what changed ("build 9.44 -> 9.45"); (3) set up the models if the author's zip is there. Everything is in the log box.
- **Updates carry the script.** A release should attach `re7mp.exe` and either a zip with `lua\re7mp.lua` and `data\re7mp\defaults.json` in it (the zip this project ships already has them) or the two files `re7mp.lua` and `defaults.json`. The script's `RELEASE` must equal the release's version.
- **Start-up.** After an update the new program runs the full install once. (9.45 also refreshed an existing install quietly on every start; 10.1 removed that: only the Install button and an update install the script.)
- **Full character models.** AfroJackX's "Third Person Full Model Placeholders RT (2022)" ([Nexus RE7 mod 86](https://www.nexusmods.com/residentevil7/mods/86), version 1.0) is packed into `re7mp.exe` itself since 10.13 (before that it shipped in `modpack\third-person-full-models`, a folder to keep next to re7mp.exe; the install still uses such a folder when the exe carries no pack). Its Permissions page allows using the assets without permission or credit (credit is given anyway, in the log and in `CREDITS.txt`), but not uploading the file itself, using them in anything sold or earning donation points, or converting them to other games, so they are only ever used for RE7 and re7mp stays free. *Install / update mod* puts the models under `natives\stm\coop` (your own first-person body is not replaced), the textures where they belong, and switches on REFramework's Loose File Loader. If the folder is missing it uses the author's zip from your Downloads instead. The pack has no animations (those come from the game's own motion banks). The script does not use the models yet. The Windows build copies `modpack` next to the exe after linking; a release zip should keep `modpack` beside `re7mp.exe`.

## 9.44: item sync shares only consumables and weapons (unverified in the real game)

**Update `re7mp.lua` on both computers; no exe change.** Item sync stays on, but a pickup is shared only if the game's own category for the item is a weapon, ammo, heal, material or throwable. Key items, files, maps and anything whose category can't be read stay in each game, so nobody can take the fuse or the bolt cutters out of the other's game. A weapon always goes to whoever picks it up first (even in "both players get it" mode), so one of you can have the double barrel and the other the second shotgun. The panel node "Items: sync pickups" has the new box "Share only consumables and weapons" (on; unticking it shares everything, with a warning). The receiving side checks the item lying in its own world too, so an older script on the other computer can't take a key item.

## 9.43: the spawn log (removed in 10.22)

Everything here is **unverified in the real game** (checked against a fake game with a fake Mia). **Update `re7mp.lua` on both computers; no exe change.** It only reads.

- **What it is:** panel node "Spawn log: Mia's spawn, the methods and files, hair physics". Tick "Spawn log on" (ships unticked, remembered), play to a place where Mia appears, wait 25 seconds, then send `re7mp/spawnlog.json` (and `re7mp/spawn_log.txt`, and the debug file).
- **Which methods:** the spawn / create / instantiate / load / request style methods of the game's manager classes are hooked (found by name, at most 140, a few a frame, three seconds after the box is ticked). The first two readable arguments of each call (a name, a file path, a prefab's path) go into a ring of the last 600 calls; a method that fires over 150 times a second is counted, not logged.
- **Which files:** every path the game was asked for is listed, hers marked (the words to watch are a box in the node; start `mia;pl2000;pl2100;em2000;em2200;em2300`). When a matching character appears the log keeps the 20 s of calls before it and 25 s after, the calls and files that mention her, and her inventory: every object under her, every component, mesh / material / animation-list files and every resource getter of her physics components with the numbers and flags they answer.
- **What is missing:** the same inventory of my copy of her (the lab body made from her, or her enemy model) and the difference: objects, component kinds (physics first), files, physics components. Press "Compare the last spawn with my copy" once a copy stands.
- **Hair physics on everyone:** every 5 s a census says which character or enemy carries `via.motion.Chain`, `via.dynamics.GpuCloth` and the other physics types, on which object, kept between sessions (`hair_physics` in `spawnlog.json`); the method list of each physics type is in the debug file.
- **Safety:** every hook and component read is announced in `lastcall.json` first; a session that ended inside one never makes that call again (`re7mp/spawnstate.json`; a button in the node forgets them). Unticked, nothing is hooked.

## 9.42: the save folder follows the Steam account (unverified in the real game)

Everything here is **unverified in the real game** (fake Steam folders, two exes on one PC). **Update `re7mp.lua` on both computers and rebuild the exe.**

- **The save folder is the signed-in account's.** RE7 loads saves from the account Steam is signed in as. The window reads that account from Steam's own registry value (a plain read; nothing goes through Steam, nothing of Steam's is changed), else the last sign-in in `loginusers.vdf`, else the folder with the newest save (the log says it was a guess). A signed-in account with no RE7 folder yet gets no folder (start RE7 once and reach the main menu).
- **A stale folder is replaced** at start-up and when you press Start, if it is another account's `userdata` folder; the log names both accounts. A path that is not a `userdata` folder is never touched.
- **The two exes tell each other their account** (exe-to-exe message kind 65001, `acct|1|<id>`; consumed by the receiving exe, ignored by an older one, no wire change). Both accounts are named in the log, the manifest (`account`, `partner_account`, and `partner_account` on each co-op save), the *Co-op saves* panel, the load-screen scan and the debug file.
- **Not covered:** a save still needs one file the game wrote on the receiver's account to copy the account block from (no key is needed or held); a re-signed save has never been loaded in the real game.

## 9.41: enemy clips and the bank fetch (unverified in the real game)

Everything here is **unverified in the real game** (mock checks; the exe is unchanged). **Update `re7mp.lua` on both computers.** The second piece taken from the other developer's co-op mod (MIT; `THIRD_PARTY_NOTICES.md`), written again for this script's messages and notes.

- **Table of enemy animations (always on).** Every bank and clip number the game shows on an enemy, how often, the largest frame, and each bank's `.motlist` path: `health.enemy_clips` in the debug file and `re7mp/enemy_clips.json` (kept between sessions). Play, then send that file: it is how the animation ids of enemies get known.
- **Play the host's clip (new box, off, remembered).** Panel > Enemies, *Enemy sync* mode 3, *Also switch off their AI*, then **EXPERIMENTAL: play the host's enemy animations on my enemies.** The joiner's own enemy plays the clip the host's enemy plays (its own animation controller is switched off and put back afterwards).
- **Bank fetch (message kind 14).** A clip my copy has not loaded is not played (the copy keeps its last move); the copy asks the host for the bank (`req|enemy|bank|chapter`), the host answers with the file's path (`bank|enemy|bank|overwrite|path|chapter`, or `none|...`), and the copy adds it and plays the clip. The host answers even with its own box unticked.
- **It lets go** when the box is unticked, the mode changes, the host goes quiet, its enemy dies, the game loads or an enemy is being saved (the controller goes back at once; clips pause 4 s). Three errors switch one enemy off for the session.
- **Not covered:** the model copies of enemies (the "Enemy models" boxes) still stand in their rest pose; grabs and executions.

## 9.40: doors shared with the other player (unverified in the real game)

Everything here is **unverified in the real game** (mock checks; the exe is unchanged). **Update `re7mp.lua` on both computers.** The first piece taken from the other developer's co-op mod (MIT; `THIRD_PARTY_NOTICES.md`), written again for this script's messages and notes.

- **Doors.** When one of you unlocks, opens, closes or pushes a door, the same happens to that door in the other game (message kind 13: `open|id|chapter`, `close|id|chapter`, `unlock|id|chapter`, `angle|id|degrees|side|chapter`; the id is the door's SaveGUID). A door that shuts by itself is not sent; the game of whoever opened a door closes it, and it waits while the other player stands in the doorway. A door that stays locked after the unlock is unlocked again; one that did not start opening is snapped open.
- **Loading gate.** While the game loads, jumps chapter or swaps the player, no door is touched; doors are read again afterwards. Unlocks that arrive meanwhile (or for an area that is not loaded) are kept.
- **Solo play costs nothing:** nobody connected, no door is looked at.
- **Panel (until 10.22; the box and the section are gone, the doors are always shared):** *Doors (shared with the other player)*: a box (remembered, on by default), the counts, the last messages and what became of them. **Debug file:** `health.doors` (counters, the last 40 messages with their result, the doors known, the loading gate, the cost of the scan).
- **Not covered:** the van door at the start (not a `DoorPush`), drawers, switches and one-off interactions (next pieces).

## 9.39: FORCE off by default, the hands' material file by eye, a higher crouch (unverified in the real game)

Everything here is **unverified in the real game** (mock checks; the exe is unchanged). **Update `re7mp.lua` on both computers.**

- **Story sync / FORCE.** re7mp.exe's *Sync story cutscenes* box turns on story sync and the moves only. **FORCE is a separate box in the panel** (*Story sync*), off at every start: all 3 times this script called `requestEvent` in the 9.38 log the game threw an `ArgumentNullException` inside it, which left the cutscene half started (Mia frozen in the basement). It switches itself off at the first refusal.
- **Hands.** The script no longer tries Ethan's or Mia's material file by itself. *Other player's body* lists each part made from a file with its material file; **Next material file** makes the body again with the next candidate, **Keep this material file** keeps the one that looks right, **Forget the kept material files** starts over.
- **Parts.** A part that has not loaded after 5 s is made again once (Mia's chain hair).
- **Crouch.** The other player's body stands 8 cm higher at a full crouch; slider in the body lab (*Crouch: stand the body this much higher*).
- **Debug file.** `health.model_check.last_read_of_each_body`, material names in each reading.

## 9.38: the bot copies you, the recorder unlinked from cutscenes, a refused cutscene move taken back, hands with another material file (unverified in the real game)

Everything here is **unverified in the real game** (mock checks and the C++ suite). **Update `re7mp.lua` on both computers and rebuild the exe.**

- **Loopback bot, "The loopback bot does".** Panel, *Who am I?* (when the other player is the bot). **Copies me** (the default): beside you, moving as you move, with your crouch / block / heal / gun / aim / shoot. Or one state at a time: timer (the old loop), idle, walk, run, crouch, crouch walk, block, heal, gun out (standing, walking, running), aim, shoot, down. Needs the new exe.
- **Cutscene probe.** New box **Linked to cutscenes** (off): unticked, a cutscene is only counted; **Record now** records by hand (F10 stops it). The 9.37 freeze was not the recorder: it was off.
- **Story sync.** A move for a cutscene the game then refuses to start (FORCE's answer false or an error) is taken back (box under FORCE, on). That is what the 9.37 log shows for the frozen Mia (moved into the basement, the game said no).
- **Hands.** A part with no materials gets the next material file after 10 s (its own name, the folder's name, `<parent>/<name>/<name>.mdf2`, Ethan's and Mia's folders); the one that works is kept (`model_status.json`, `material_files`).
- **Text.** *Click an item to select it, then press F7.*

## 9.37: Pete and Andre as characters, a bot that follows you, faster model repair, animation states (unverified in the real game)

Everything here is **unverified in the real game** (the mock checks and the C++ suite; the new window code in `gui_win.cpp` could not be compiled here). **Update `re7mp.lua` on both computers and rebuild the exe.**

- **Characters.** *Play as* (exe) and *Show me to the other player as* / *The loopback bot is* (panel) also list **Pete Walken** (em9200) and **Andre Stickland** (em6200); the other player's body is then made from their files (head part included). Never picked by *Automatic*.
- **Loopback bot, "Follows you".** Walks after you (1.3 m/s close, up to 5 m/s far), stops 2 m away, snaps next to you beyond 40 m. *Move bot to me* puts it next to you.
- **Model repair.** A part not loaded after 5 s is made again once; a model made in the last 30 s is checked every 2 s (grace 4 s); fix 1 remakes only the faulty parts; the model table records a problem only after the grace.
- **Animation probe (F3).** 45 s; each animation seen carries `avg_speed_m_s`, `moving_share`, `closest_m`, `avg_distance_m` and a `guess` (standing / walk / run / close and not moving). Stand still near an enemy, walk away, let it attack, press F3 again to stop and save.

## 9.36: the hitching, headless enemies, the model check and the loopback enemy picker (unverified in the real game)

Everything here is **unverified in the real game** (the mock checks and the C++ suite). **Update `re7mp.lua` on both computers; no exe change.**

- **Debug file writes.** At most every 30 s while playing (10.20; 15 s before), 2 s while a menu is open, longer after a slow write, never because of an item-trail line. *Send me this > Save the debug file now* writes it at once. `health.perf` has the frame-time recorder (parts of the frame, slowest frames, the cost of writing the file); since 10.20 `health.perf.frame_gaps` also times the wait BETWEEN frames, so a hitch the game makes (an autosave, a load) can be told from one the script makes, and `health.coop_saves.slot_scans` says how often and how long the game was asked about the save slots.
- **Enemy models from files** wait for the body's mesh to load (10 s at most), then get their head and parts; a part joins only when its mesh has loaded and its skeleton shares 4 joint names with the body.
- **Model check** (*Enemy models* panel): every 5 s, every 10 s with no enemy near on either screen (the loopback bot's do not count). It reads MeshReady, MaterialReady and every texture slot, adds missing parts, then makes the model again, then leaves it alone (2 fixes per enemy and scene). Result: `health.model_check`.
- **Loopback enemy picker** (*Send me this*, item 13): the bot's circling enemy is drawn as the model you pick. `health.model_table` and `re7mp/model_status.json` list, per model, meshes collected, files known, made / failed and why, and what the check found.
- **Inventory note** about discarding (follows the give-hint box).

## 9.35: Mia's head and hair, Ethan cloned from the scene, the tape watcher gone, new shipped defaults (unverified in the real game)

Everything here is **unverified in the real game** (3073 mock checks and the C++ suite; the window code only passed a syntax check). **Update the script on both computers and rebuild the exe** (the loopback bot's circling enemy is Jack now; the exe carries the script). Your own settings win key by key over the shipped defaults, so press **Reset to defaults** (top of the panel, two clicks) once to take the new ones.

**What to try.**
1. **Ethan** (a new game, or any scene he is in): the other player's body is a copy of the scene's own Ethan, built while the new-game timer is still counting down. In Mia's flashback or a tape he is not in the scene: nothing is drawn but the panel says why, and the scene is looked at every 1 to 10 s.
2. **Mia:** *Other player's body* > **Use Mia (Pl2000)** with the loopback bot set to Mia (or the other player playing her). Her playable body is made from her files, and the corrupted Mia's head and chain hair are put on it (from the scene when a corrupted Mia is in it, else from their files). Does she have a face, are the skin layers right (the boxes `Head layer: ...` are still there), is her hair on? If a part is taken away the debug file says why (`body_lab.mia_head_parts`: joint names shared with the body, and a log).
3. **Hair physics (removed in 10.23)** (experimental, unticked): only with a corrupted Mia in the scene. Tick it, press *Rebuild the body*. The panel line and `health.hair` say what was copied; **the interesting part is `health.hair.probes`** (what her hair components hold), whether or not it moves. If the game closes, send `lastcall.json` and `hairstate.json`: the next start has it off and skips the call that ended the session.
4. **Jack on the loopback bot:** Loopback mode with *Draw received enemies even if I am the host*: the circling pretend enemy is `Em3000`. With *Enemy models* on you should see his model (rest pose; animation is not done).
5. **Giving the last item** is on now: give your only herb; the other player gets it, you lose the entry. An inventory the script cannot read is refused.

**What changed.** Details in `CHANGELOG.md` (v9.35). Removed: the tape watcher. Shipped off: the item journal and its object scan (their hooks could add lag). Shipped on: loading models from files (Ethan is never made that way), giving the last item, the Mia layers from your screenshots (her skin on, the corrupted skin and the blend off, eyes, hair and tear on), the two side-lock hair meshes hidden. **Not done:** enemy animation playback, hair physics for the side locks (GpuCloth), a head for Clancy's playable body.

## 9.34: F3 for the enemy animations (unverified in the real game)

Script only (the exe's code is the same as 9.33, but it carries the script: rebuild it, or copy `lua/re7mp.lua` into the game's `reframework\autorun` folder on both computers). **Unverified in the real game:** it ran against the mock game only.

- **F3 does what button 12 did.** Stand near enemies with the menu shut and press **F3**: it lists their `.motlist` files and watches what they play for 30 s. Press F3 again to stop and save. The button in *Send me this* is still there (labelled `[F3]`).
- **A line at the top left** shows the watch ("ENEMY ANIMATIONS 12 / 30 s (F3 stops and saves)"), and for 8 s after each press or end what happened.
- **Send back** `re7mp\motlists.json` and `debug.json` as before. `health.enemy_motions.key_presses` in the debug file counts the F3 presses the script saw: 0 after you pressed F3 means the key never reached it.

## 9.33: story sync in one box, watch only, the drop route as the default, Mia's head layers, enemy animation files, a reset button (unverified in the real game)

Everything in this section is **unverified in the real game** (3007 mock checks, the C++ suite; the new window box only passed a syntax check because the Windows window cannot be built where I work). **Both the exe and the script changed: update both on both computers.**

**What to try with your friend (in this order).**
1. **Both:** new exe and new script. In `re7mp.exe` tick **Sync story cutscenes (experimental)** (under *Share saves*; it starts unticked and is remembered). In the panel, *Story sync* now says the exe's box is ON and its four boxes (story sync, FORCE, both moves) are ticked.
2. **Cutscenes:** whoever walks into a cutscene first (host or joiner), the other player is moved to that place and the cutscene is played for them too. Say what you each saw; send both debug files (`story`, `force`). The slow walk to the cutscene point is the game's own start of the event.
3. **Watch only:** for a cutscene you would rather the other player just *watch*, tick *Watch only: c0xxx_xx* in the panel (the cutscenes seen lately are listed; the choice is saved by id). The other player is still brought to the place, but the cutscene is not played for them. It counts when either player has it ticked.
4. **Items:** the ground route is the default now and the old create-an-item way is gone. Give a herb at 2 m; give a kind the other player does not hold (it lands at their feet, they pick it up with the game's own pickup); discard one. The 3 m rule is unchanged.
5. **Mia's head:** *Other player's body* with the loopback bot set to Mia (the new box "The loopback bot is") and *Real body* on. The scene's head is used again with the corrupted skin layers switched off and her own on; every layer has a box if it still looks wrong (the debug file lists what each layer was before and after).
6. **Enemy animations:** stand near some enemies, press **12. Enemy animations (.motlist)** in *Send me this* (9.34: or just **F3**, menu shut), fight or run for 30 s. Send `re7mp\motlists.json` and the debug file (`health.enemy_motions`).
7. **Friendly fire:** shoot the loopback bot: its health drops (never below 1), it goes down at 1, a heal next to it gets it up. The bot can now also be Clancy (his body comes from his files, so tick *Load models that are not in this scene from their files* in *Other player's body* first; it starts off now).
8. **Reset to defaults** is the first button at the top of the panel (two clicks).

**What to send back:** `debug.json`, `re7mp\motlists.json` (if you pressed button 12 or F3), and, if the game closes, `lastcall.json`, `trail.json`, `trail_history.json` and `re2_framework_log.txt` (the crash lines are at its end).

**What changed.** The details are in `CHANGELOG.md` (v9.33): the ground route is on by default and remembered; `createItemInstance` + `addItem` and the item lab are gone; the exe's box sets story sync, FORCE and both teleports together (through `re7mp_story.json`) and the top-left callouts are a debug option; Mia's own head (`pl2050`) drew black so the scene's head is used with its layers switched by name; the shipped `defaults.json` was rebuilt (testing leftovers are never shipped, *face me* is off, and **loading models from their files is off** until you tick its box: both engine crashes of 9.31 and 9.32 came in sessions that had loaded resources that way); two log-spam sources from your framework log were removed (the `getItemDataId` argument warnings and the repeated reads of an empty bridge file). The crash you reported while walking around is **not fixed** (it was Ethan's body when it happened): the framework log shows a game worker thread releasing an object whose type is already gone; no Lua frame is on the stack. Loading from files is the lead, not a proven cause.

## 9.32: bodies from the scene, the held weapon, the 3 m rule, Mia's face, forcing a cutscene, 15 saves, two new item routes (experimental: tried only in the mock game)

Everything in this section is **unverified in the real game** (3050 mock checks, the C++ suite, and about 190 deliberate breakages that the tests now all catch). The exe change is the save-slot limit; it is core code that builds and is tested on Linux, the window code did not change.

**Bodies.** In the main house Ethan's object is `Pl0000`, not `Pl0000_Chapter1`. The body lookup let the file loader answer before that second name was tried, so his body was made from his *file* (which the game refused: "fails at step mesh") while the real Ethan stood in the scene. A model that is in the scene is now always made from the scene, under both names; files come after. For a body made from files (Clancy's `pl3000`) the script keeps a reference to the resource, waits up to 10 s until the mesh is loaded and the joints exist, attaches **no parts** to it, reads its rest pose only then, and writes `reframework\data\re7mp\loadstate.json` while it stands: a session that ended with it set switches loading by path off at the next start (the journal says so). Debug: `loader`, `body_lab`.

**Marker arrow, 10 s.** The "find the other player" arrow pointed the wrong way (the sideways direction was mirrored) and lasted 15 s; fixed, and 10 s now.

**The held weapon, second try.** Your file showed every weapon's item state stays 2 whatever is in the hand, so the state is no signal. The script now asks four places and the first that gives one answer wins: the item state, the weapon item's own object (the **drawn** one), a `wp####` object drawn under my player, and a field of the player's gun components that points at one weapon. Each place's answer and every change are in `health.weapons` (`source`, `evidence`, `evidence_log`, `probes`). Reading only.

**Cutscene recorder.** While a cutscene is recorded the player's own animation is watched: idle, walk / run or stopping / starting for 1 s (after a grace of 4 s, a slider) ends the recording and cuts the gameplay off the clip. A "cutscene" that never leaves those animations is an **event trigger** (`cutscenes.event_triggers_seen`; its joint clip is not kept). **F10 stops any running recording**, the cutscene probe's too.

**Menus.** The quick-select wheel (`QuickEquipMenu`) hides the other player like a menu but no longer sends the Inventory pose.

**Giving, the 3 m rule.** An item changes hands only when the other player is within 3 m (the receiver allows 4 m for lag; a distance that can't be told refuses). The message says how far they were. A **downed player can still open the inventory and give**; healing while downed stays blocked. Debug: `items.range_rule`.

**Mia's own face.** The stand-in was the corrupted Mia (`Em2000`, head `em2050`); the playable Mia's head is `pl2050`. Box *Mia: use her own head ...* (panel *Other player's body*, ticked at the start; press *Rebuild the body* after changing it): her head is loaded from its file and joins the body when loaded; if it does not load in 10 s the scene's head is made instead, and after one failure it is not tried again this session. Debug: `body_lab.face` (the button *Read the heads in this scene* adds a scan of them: mesh, material file and material names).

**Forcing a cutscene (FORCE, EXPERIMENTAL, off, not remembered).** Panel *Story sync (EXPERIMENTAL)*: tick *Story sync* on both computers and *FORCE* on the one that should **play** the other player's cutscenes (so you can stand aside while they do the cutscene; the move box moves you *to* them, FORCE starts it *here*). The script calls the game's own `requestEvent(name, a transform, null, null)` with a new empty object of mine put where *their* game's transform stood. Limits: names like `c03e03_00` only; I must be within 30 m of where they started it; one at a time (25 s after any event started here, 20 s between two); the same one not within 60 s; not with a menu open, when downed or in a tape; never echoed back. A crash is remembered: `forcestate.json` + a breadcrumb stage `force`; the next start puts that cutscene on a not-played list (button *Forget the not-played list*). *FORCE test* plays the last cutscene *you* started again here. Debug: `story.force` (counts, the last call and answer, the not-played list, how often the game's own end callback is null). **Unknown:** whether the game starts a cutscene with a made-up transform and no end callback; and which area each player is in.

**Saves: 15 slots.** The game lists 15 saves. Nothing is put past slot 15 now; when all 15 hold a file the **oldest co-op copy** installed here is replaced. Your own saves and the ones you sent are never overwritten; with 15 saves of your own the co-op save is not installed and the status line says what to do. (Autosave sync: not done. "Overwrite my oldest own save": not built, say if you want it.)

**Items, three changes.** (1) The pickup hook is now on **every `addItem` overload** (9.31's was on the 2-parameter one; the game's pickup uses the 4-parameter one, so the file had no "you picked up" line). (2) Box *Both players get it*: a picked-up item stays on the other screen too (unticked: it vanishes there, the first to pick it up gets it). (3) **Ground-only route** (EXPERIMENTAL, off, not remembered): a gift of a kind I don't hold and a discard become a **drop on the ground** (`createDropItemInstance`; `addItem` is never called); the other player picks it up with the game's own pickup. Debug: `item_sync`, `items.ground` (what each of the last 8 drops was made of, its state, whether it was still there 2 s later). **Item data:** `health.item_data` has, per kind held, its count, biggest stack, state and the fields of the item and its save record, the field layout and method list of the item classes and the methods whose name says discard / drop / remove / pick / add ... on their own (read 15 s after the start and again when a new kind is held).

**What I'd like from you (send the debug file after each; also `loadstate.json`, `forcestate.json` and `lastcall.json` if the game closed):**
1. **Bodies:** Loopback with the Real body box on: does Ethan's body show in the main house and elsewhere? Then, if you dare, the Clancy / `pl3000` test again (`loader`, `body_lab`, `loadstate.json`, `lastcall.json`).
2. **Held weapon:** with the *Weapons* panel open draw each weapon in turn (pistol, shotgun, knife ...) and press *Weapon probe: write a long dump ...* after each; send the file (`weapons`).
3. **Marker:** the button *Where is <name>?* (or F9 in ping mode 2 or 3): is the arrow the right way round, and is it gone after 10 s?
4. **Mia:** in *Other player's body* press *Use Mia (Em2000)* and then *Rebuild the body* (with the face box ticked) and look at her face.
5. **3 m rule:** give a herb at 2 m (works), at 5 m (refused with the distance), and while downed (works).
6. **Items:** with the item data on, hold a mix (a key item, a herb, ammo, a weapon) and send the file after 30 s (`item_data`). Pick things up with each mode of *Both players get it* (`item_sync`). Then, on **both** computers, tick the ground-only route, give a kind you don't hold and discard one item: does it lie on the ground, can the other player pick it up (`items.ground`)?
7. **Cutscenes:** tick the cutscene probe, play a cutscene and then walk: does the recording stop? Does F10 stop it? Send `re7mp\cutscenes\` and `re7mp\clips\cs_*.json` too. **FORCE:** both tick *Story sync*, the one that should be pulled in also ticks FORCE; the other starts a cutscene while the first stands within 30 m; say what happened on each screen and send both files (`story`, `force`).
8. **Saves:** save a few times while connected and look at the Load screen; if you can, fill the folder to 15 files with at least one co-op copy and save once more (the exe's status line says which slot was replaced).
9. **The exe:** rebuild it (the slot limit) and press Start.

## 9.31: enemy models, Clancy and a character selector, the held weapon, friendly fire, the item journal (experimental: tried only in the mock game)

Everything in this section is **unverified in the real game**. The exe's new window code (the "Play as" box) was **not compiled** where I work; its logic (`src/character.hpp`) is built and tested, the window code is not.

**Enemy models.** The host's enemies are red boxes on the joiner's screen. Their names (`Em3000` ...) are your model ids, so the script now draws the real model for the nearest 6 living enemies within 70 m (panel *Enemy models*, on by default) and keeps the box as the fallback; the label reads `Em3000  HP 400  - Jack Baker` (your list of 36 ids is `CFG.ids`). They stand in the model's rest pose for now: **no walking, no attacks**. If the model can't be made the box stays and the panel says why. The shots still hit the box's volume.

**Loading a model from its file (the big unknown).** A model that is not in the current scene (Clancy's body, an enemy that is not near) is loaded from its file path with `sdk.create_resource`. The button *Test: load Clancy's body mesh from its file now* (panel *Who I am*) tries one. The debug file's `loader` section says `tried`, `loaded`, `failed` and why.

**Who I am.** The player object's name says who you play (`Pl0000_Chapter1` Ethan, `Pl2000` Mia's flashback, `Pl3000` Clancy at the tape). (The VHS watcher that triggered on this was removed in 9.35; the character choice stays.) The exe has a **Play as** box (Automatic, Ethan, Mia, Clancy, Pete, Andre; 9.37); it writes `reframework\data\re7mp_char.json` and the script applies it and tells the other player (event `char`), whose body is then drawn as that character (Real body box, and *Show the other player's body as the character they are*). The panel *Who I am (character)* has the same choice (the exe is not needed for it).

**The held weapon.** Panel *Weapons*: what I hold (a gun with its damage and stun, a knife, an axe or nothing) and what the other player holds (event `wpn`). **It assumes the item in the main-hand state (3) is the drawn weapon; that is a guess.** Every weapon-like item and its state is listed in the panel and the debug file (`health.weapons`) so a wrong guess shows.

**Gun damage and friendly fire.** Your table is in the script (22 guns). *Shots at the host's enemies do the held gun's damage x the scale* is off by default (scale 2.1). **Friendly fire** is off at every start and never remembered: tick it on **both** computers; a shot that crosses the other player (box 0.7 x 1.8 m, no wall in between) takes the gun's damage x its slider off their health, never below 1.

**Items: the journal.** Panel *Items: journal of pickups and inventory changes*, on by default, read-only. It writes down the game's own pickup calls and **every change of your inventory** (an entry added, removed, its count or state changed) with the call that came just before. A second box also writes down the objects within 5 m at a pickup and which one is gone 1.5 s later (12 pickups at most). Debug file: `health.pickups` and `health.inventory_changes`.

**What I'd like from you (send the debug file after each):**
1. **Item journal, the guest house start:** with the journal on, pick up a few different things one at a time (a key item, a herb, ammo when you already hold some, a new weapon), **drop** one, **use** a herb, **combine** two things, open the inventory and **put a gun in the main hand and then the knife**. Then tick the *objects around me at a pickup* box and pick up three more things (more than 3 s apart). Send `re7mp\debug.json`.
2. **Weapons:** with the weapons panel open, draw each weapon you have (and the knife, if the game lets you) one at a time; send the file. I need to see which item state the drawn one has.
3. **Enemy models:** host a game, join from the other computer, walk to Jack (or any enemy). Send the joiner's file (`enemy_models`, `loader`). The panel line for each enemy says `ready from ...` or why not.
4. **Loader test:** with Clancy not in the scene press *Test: load Clancy's body mesh from its file now* once and send the file (`loader`). If the game closes, send the files anyway: the next start switches the loader off and says so.
5. **Friendly fire:** both tick it; shoot each other once with the pistol; send both files (`friendly_fire`).
6. **Character:** pick Clancy in the panel (or the exe box once it builds) and look at the other player's screen.
7. **The exe:** build it and press Start; if the build fails, send me the compiler's error.

## 9.30: items, the built-in defaults, the tidy data folder (experimental: tried only in the mock game)

**Installing by hand.** The zip has a new file, `data\re7mp\defaults.json`. Copy it to `<RE7>\reframework\data\re7mp\defaults.json` (make the `re7mp` folder if it is not there). The rebuilt `re7mp.exe` does this itself when you press Start or *Install Lua script*. Without that file the other player's body stands in a T pose (no clips).

**What `defaults.json` holds.** The 16 clips (idle, walk, run, crouch, crouch_walk, guard, heal, inventory, melee, and the gun ones: gun_idle, gun_walk, gun_run, gun_crouch, gun_aim, gun_shoot, gun_reload) and the settings a first install starts with: your own settings file (43 keys), with the **Real body** box on, wall and menu hiding off (the game hides a real model itself) and the cutscene probe off. Anything it does not hold keeps the script's own default (the tape watcher and the downed item lock are on). The player's own files always win: a clip in `re7mp\clips\<label>.json` beats the built-in one, and a setting the player has chosen beats the shipped one key by key. `tools/build_defaults.py` builds the file from your own data folder (see its header). The clips in this one are the ones from the earlier package: your *My settings* folder had settings but no clips. *Developer tools > Animation clips > "Test: use only the built-in clips"* shows what a new install gets.

**The data folder.** The mod's own files are now in **`reframework\data\re7mp\`**: `settings.json`, `debug.json` (the file to send me), `models.json`, `trail.json` and `trail_history.json` (the item black box), `lastcall.json` (the crash breadcrumb), `coop_played.json`, `defaults.json`, and the folders `clips\`, `cutscenes\` and the rest-pose files. The six small files `re7mp_in.json`, `re7mp_out.json`, `re7mp_msg_in.json`, `re7mp_msg_out.json`, `re7mp_state_in.json`, `re7mp_state_out.json` and `re7mp_coop_saves.json` stay in `reframework\data` because `re7mp.exe` reads and writes them. At the first start the script writes and reads back `re7mp\folder_check.json`; if the game refuses the folder it keeps using the old flat names (the debug file's `data_folder.used` says which). A file an older build wrote under the flat name is still read when the folder has none. The old flat files are not deleted: you can delete them yourself once 9.30 has run. The *Open data folder* button of the exe opens the `re7mp` folder.

**Items.** The inventory the mod reads is no longer remembered once and trusted forever: after the dinner cutscene in the main house the game builds a new one and the old reference read nothing. Every 0.5 s the script checks that the one it holds is alive; when it is not (or it disagrees with another candidate every 3 s) it searches again: the player's own component, then the scene's, then the managed singleton, then what a hook saw. A failed search is tried at most once a second. Each re-find is written to the item black box. **Creating an item you hold none of is still off by default** (the earlier creation tests crashed the game; whether it works into a live inventory is not known). Giving what you already hold grows the stack and is the safe path. While you are **downed** (the other player can revive you), healing items are not spent: the `reduceItem` call is skipped (box *Block healing items while downed*, on by default); the use animation may still play.

**The other player's body.** No weapon is ever drawn on it: weapon pieces are skipped by name and mesh folder (empty hands); the gun *pose* is still shown. The gun pose is let go after 12 s without aiming or firing (slider in *Developer tools > Debug model*, 0 = never) and is not shown while `PlayerGun.actionID` is 0; the learned "gun out" signal from the first recordings (`PrevWeaponActionID`, which is 2 for the unarmed block) is no longer shipped. The crouch no longer sinks into the floor: the clips already lower the hips, so the body is lifted by `CFG.CROUCH_DROP` (0.5 m) while they crouch.

**VHS tapes, Clancy and the model list.** *(The tape watcher was REMOVED in 9.35; this is what it did.)* *VHS tapes* (panel): the script watches the tape player's screen (the GUI `VideoCameraUI`; it counts only after it has seen the screen hidden once). When you start or stop a tape the other player is told (`e|tape|start`, `e|tape|stop`, resent every 5 s while it plays), the models in view are collected while it plays (tagged "VHS tape"; this is how Clancy's model gets into `re7mp\models.json`), and the other player's body can be held back while they are in a tape and you are not (they are in another scene; box on by default). The model checklist now uses the ids from the *RE7 ultimate file list* thread: Ethan pl0000, **Clancy Jarvis pl3000** (pl3100 in the 21 card game), Mia pl2000/pl2100 and em2000/em2200/em2300, Jack em3000/em3700/em8000/em8100/em8500, Marguerite em3100/em3600/em3800, Lucas em3200/em3900, Zoe em3400/pl3400, the Molded em4000/em4100/em4200. Unverified in the real game.

**The panel.** Top level: the Real body box, show/hide, ping, and the groups *Start together*, *Co-op saves*, *Death*, *Health, downed and revive*, *Items* (two), *Enemies*, *Story sync*, *Chat and pings*, *Other player's body*, *Send me this*. Everything for testing is in one folded group, **Developer tools**. The green man is now only the debug model (off by default; the box is in *Other player's body*).

**Radmin VPN** is recommended in place of Tailscale (you tested it; less intrusive for casual games). Tailscale and ZeroTier still work the same way.

**Credit, for later.** The Nexus mod you linked (mods/8) is not used in this build. If a later build uses it, its author gets the credit; whether it works with the ray-traced version is not known.

## 9.29: the real body in one box (experimental)

All of this is tested with the mock game only (2152 checks) and **unverified in the real game**.

**The box.** At the top of the panel: **Real body: show the other player as a real in-game model (Ethan or Mia), made for me**. Ticking it does the steps of the Real body lab one after the other by itself, as soon as the other player (or the loopback bot) is there and you are in a game scene: (1) make the body object with the model's mesh and material, (2) add its parts (hands, lower body, hair ...), (3) for any model but Ethan's own, match its height to Ethan's (it waits while you crouch, because a crouching Ethan is lower), (4) make it follow the other player, (5) play the recorded clips on it. The panel shows the step it is on (`Real body: working - matching the body's height to Ethan's`) and, when it runs, `Real body: running (Pl0000_Chapter1 copy, 3 part(s), size 1.000; debug model hidden)`.

**What the green man does meanwhile.** It is not drawn while the real body runs ("Also show the debug model (the green man) next to it" brings it back to compare). The green man is drawn again whenever the real body is not really standing in: no `idle` clip file (the body would stand in its bind pose, so the panel says so and the green man stays; the file is looked for again every 5 s), the box off, a step failed, the lab's *It follows* or *Play the clips* box unticked, or a new scene took the body away and it is being made again.

**The model.** "Model to copy" is `Pl0000_Chapter1` (Ethan; `Pl0000` in the main house is found by the same name) or any scene object, e.g. `Em2000` for Mia. Typing a name does not rebuild; **Rebuild the body** does, or the **Use Ethan** / **Use Mia (Em2000)** buttons (which rebuild at once). The name is remembered. If the model is not in the scene yet (Mia is only there in some places) the box waits and looks again, slowly (after 3, 6, 12 and up to 30 s), and does not count it as a failure. **Hide hair parts** hides the parts whose name contains "hair" (cloth, which the copy does not have; remembered).

**If something fails.** Any step that errors, a mesh the game refuses, a game phase that never comes (three tries), or the clip player switching itself off: the body is taken down (destroyed, if the box made it), the green man is drawn instead, the panel says `Real body: failed - <step>`, and the lines under "Real body (experiment...)" and the debug file's `real_body` section say which step. **Try again** starts over. A failure is never retried by itself.

**A new scene.** The game takes the objects of the old scene down with it; the box notices, waits 2 s and makes the body again in the new scene (counted as `restarts` in the debug file).

**Unticking** the box takes down the body it made (parts first), stops the following and the clip player it started, and brings the green man back. A body you made by hand in the lab is used by the box if one exists, and is left alone when the box goes off.

**Remembered.** Whether the box is ticked is remembered only once *you* have ticked or unticked it, so a future default can reach everyone else. To make it the default for a release, set `REAL_BODY_DEFAULT = true` in `CFG` at the top of the script (the debug model is then off by default for everyone who has not chosen).

**"Show other player" off** now parks the real body under the world as well (it did only for the green man before).

**The rest pose (for calibrating Mia).** The clips are Ethan's joint angles by joint name. A model with a different rest pose (Mia's rig may differ) is pulled out of shape by them. When the body is made, the box writes down the **rest pose**: each of the 54 joints' local angles before any clip moves them, plus the hip position and the head height at size 1, to `re7mp_rest_<model>.json` (e.g. `re7mp_rest_Pl0000_Chapter1.json`, `re7mp_rest_Em2000.json`) and to the debug file's `real_body.rest_pose`. The Real body lab has a button **Read the rest pose** for the same. Tick the box once with Ethan and once with Em2000 and send both files: the difference is what a retarget needs. This build does not retarget yet.

## Avatar and "Probe RE7 types" (removed in 9.30)

Both panels and the code behind the avatar one are gone. `via.GameObject` has no `clone` in this game (since 9.23), and the **Real body** box makes a body from the model's own mesh instead.

## Interactivity: messages, chat, pings, and finding item hooks

**Reliable messages.** Besides the position stream there is now a reliable message channel: the Lua script queues a
short text message (kind + payload up to 200 bytes), `re7mp.exe` resends it until the other side confirms, the other side
receives each message exactly once and hands it to its Lua script. This is the pipe item pickups, drops and other events
will use. Two uses already ride on it:

- **Chat**: Insert > RE7 Multiplayer > Chat and pings > type, Send, or press one of the quick phrases (Wait for me, Come here, Help!, Found something, Going ahead). Messages show on screen for 12 s.
- **Ping**: **F9**, or "Ping my position" (also at the top of the panel; at most one per 1.5 s), puts a marker at your position on the other player's screen for 12 s, with your name and distance.
- **Where is the other player? (9.27, your note "a ping both players or the other player's position, to tell where they are if you lose them").** Panel > Chat and pings > **What F9 does** picks one of three: *my position to them* (the old ping), *their position on my screen* or *both* (the default). "Their position" sends nothing: the other player's position is already here. For 15 s you see a marker at them with their name and the distance if they are on screen, and an arrow at the edge of the screen that points the way if they are not. Both the chat line and the arrow say the distance, the direction as seen from where you are looking (*ahead, ahead right, right, behind right, behind, behind left, left, ahead left*) and the height (*1 floor above / below*, about 3 m per floor). There are buttons for each choice, a box **Keep showing where they are** (until unticked) and a stop button; the choice is remembered. With no position of the other player yet, it says so instead of showing something wrong. Unverified in the real game (the direction uses your camera, the distance does not).
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

## Items: give and drop (giving confirmed in the game; receiving into a stack you hold confirmed; **9.33: the old creating route is gone, the ground (drop) route is the default**; what follows is the history of how it grew)

**9.32:** giving now needs the other player within 3 m (a downed player may still open the inventory and give), the pickup hook sits on every `addItem` overload, a box chooses whether an item the other player picks up stays on your screen too, and an experimental **ground-only route** hands items over as drops on the ground without calling `addItem` at all; the debug file also carries `item_data` (stack sizes, item records, class methods). See the 9.32 section above.

You asked for two ways to hand an item to the other player. Both are built, and you can use either. **Since 9.11 the receiver answers** (`Bob has Herb x1 (in the inventory)`, `... on the ground`, or `could not take ...: it is back in your inventory`, and a drop is answered too); a gift that cannot be placed is handed back, and a sender with no answer after 10 s is told the other script is probably older than 9.11. Both players need 9.11 for the answers. **Since 9.12 a gift leaves your inventory only after the receiver says `ok`** (nothing is taken first), "dropped at your feet" is only said when an object really appeared, and a gift whose item the game will not create can still grow a stack the receiver already has (see v9.12 above).

**A. Give (the "transfer item" idea).** I can't add a button *inside* the game's own inventory menu from a script, so
there are two ways to give from the REFramework panel instead (Insert > RE7 Multiplayer > *Items*, the give and drop half; until 10.22 its own section *Items: give and drop*):
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
puts the item at your feet. The line under *Items* (give and drop) names the path that was used or the error.

**Since 9.18:** a created item has a stack of 0, which is the best guess for the crash; gifts now set and verify the stack and the lab has a Lab 6 for it (see the v9.18 section at the top).

**Since 9.17, finding out why creating an item crashes the game:** with the creation box ticked, every item step is written at once to `reframework\data\re7mp\trail.json` (and the debug file), the steps are followed by "alive" lines for 4 s, and the panel has a five-button **item lab** that runs make / add / add-with-a-list / remove one step at a time. After a crash, start the game again and send the debug file: the first journal line names the last step. See the v9.17 section at the top. Safe mode (the default) never touches any of this.

## "Send me this": collecting debug info (three clicks, then send one file)

Everything the script logs is also written to **`<RE7>\reframework\data\re7mp\debug.json`**. In `re7mp.exe` click
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

Then send me `re7mp/debug.json`. You don't need to understand the contents. The results of steps 1 and 3 are kept in a
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
  the value you pick is remembered (`hide_near` in `re7mp/settings.json`).
- **Game menus (9.9, reworked in 9.11):** not drawn over the inventory, pause, map, save, tape player and similar screens; a GUI with a name like `MapMaskGUI` is not a menu, and one that stays "open" while you walk is dropped (see "What changed in v9.11"). Tick box in the panel.
- **What the "walls" are (9.26 probe).** Most hits in the v0.8 files are on things named like rooms and areas (`Garden00` 400, `Cube_Collider` 199 and 352, `MainHouse1F` 188, `1F` 164, `B1` 147, `CowshedArea` 147, `c01_Corridor02_id3` 135, `hall_passage` 120 ...); 63 to 66 % of all wall tests said "behind a wall", and the file records 7 recalibrations on the joiner's computer and 2 on the host's. The name filter can only guess, so "Probe the walls here" now also records, for each named collider (80 at most), its type and the yes/no and number properties that type has (static, trigger, layer, group ...), its shape type, and the method names of each type (`layer_probe.collidables`, `layer_probe.collidable_methods`). That is what I need to find the property that tells a solid wall from an area volume. The rule itself has not changed.
- **Walls (9.9, rebuilt in 9.11; since 9.18 doors, door sensors, safe-room volumes and effects no longer count, since 9.19 enemies and area volumes don't either, and a "Probe the walls here" button shows which collision layers hit what; since 9.22 the panel names the last collider that hid them and a button says "that is not a wall" (remembered), names with `stair` do not count, since 9.27 names with `vfx` (effect volumes such as `VFX_c03_OldHouse`, which hid the other player 153 times in one file) do not count either, checks run 4 times a second with two in a row needed both ways; since 9.20 a failed calibration is retried after 3 s, 6, 12 ... and at once after a 3 m walk):** not drawn while a solid wall is between you (a ray test from your camera to four points of their body). The panel line `walls:` says `working`, `unavailable` or `switched off`. Tick box in the panel. **Other colliders that still count and are probably not walls** (names from the same file, not changed because I can't tell yet which are real: `c03_GardenArea1` and its `_id55A`/`_id55E`/`_ssr` variants 176 times, `Cube_Collider` 94, `MainHouse_underfloor_outside_1` 79, `Garden00` 52, `c03_MainHousOutsideSub01` 37, `125_sm0113_CallingPhone_PhoneMessage_100_TrailerHouse_FFS` 24): tell me which are not walls, or use the "that is not a wall" button on them.
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
5. Send me the REFramework log (a file in the RE7 folder ending in `_framework_log.txt`) and `re7mp/debug.json` after a crash.

In case the mod contributes: this version never gives the renderer NaN or absurd screen coordinates, and the body
draws only a few dozen shapes per frame, so it should be negligible. The game-freeze fallback is off by default.

## Enemies: the host runs them (new, experimental)

Your trace showed what enemies are: root objects named `Em####` (garage-fight trace said Em2000 = Jack, Em2100 = cutscene Jack,
Em3000 = main-house Jack, Em6100 = Mia; 10.19: the garage car's brain names its `Enemy` as Em3000, so the garage Jack is Em3000 and the trace's Em2000 was wrong; 9.28: the owner says the Em2000 model he copied in the main house is Mia, so these names are the game's pool names, not a fixed identity), each with Think/Status/Order/DamageController/EnemySave components. Spawns come
from `app.AI.MansionAISetController` and `app.EnemySceneSurveillance`. So:

- **The TCP host's game runs the enemies.** Ten times a second the host reads each `Em####` object's position, rotation,
  health (if a health field can be found), alive flag and animation ids, and sends them as one small text blob through
  `re7mp.exe` (`re7mp_state_out.json` -> TCP, newest wins, so a slow link drops old snapshots instead of lagging).
  The joiner's exe writes the newest blob to `re7mp_state_in.json`.
- Both players need the new exe (protocol v6).
- **Insert > RE7 Multiplayer > Enemies**, *Enemy sync*:
  1. *Off*.
  2. *Show the host's enemies as red ghosts*: the joiner sees a red box, a name and `HP n` where the host's
     enemies are. Nothing in the joiner's game is touched, so this one is safe.
  3. *Ghosts, and move my own enemies onto the host's* (**the default since 10.22**; 0.10 and before: ghosts only, and this mode was labelled experimental): the joiner's own `Em####` objects with the same
     names are moved onto the host's positions every frame. An optional checkbox also switches off their AI components.
     It is never switched on by itself after a restart. It can break fights, scripted events and saves: use a throwaway
     save. If the host goes quiet for 3 seconds, everything it moved is released.
- **How the joiner plays the host's enemies back (10.12).** Not by chasing the newest snapshot: every snapshot is a point on a timeline and each enemy is drawn a short,
  adaptive time behind the host (twice the measured snapshot gap plus a little: about 0.17 to 0.25 s), between two real positions, with its facing interpolated too. The host's
  clock rides in the snapshot (`T<seconds>` first; an older joiner skips it, an older host sends none and arrival times are used) and the host sends 15 snapshots a second
  with 8 enemies or fewer (10 with more). A warp of 8 m or more is shown at once. `health.enemy_timeline` in the debug file has the delay, the gap and the counts.
- **One health pool and the Molded (10.15).** The host's health number is the pool; in mode 3 the joiner's copy of an enemy takes it and dies with the host's, and a boss bar shows the same numbers on both screens (`health.boss_pool`); from 10.16 a boss's own copy is not written (and never hit) unless an EXPERIMENTAL box says so, and nothing is written during a cutscene or a load (see "10.16" below). The host names a Molded from the game's spawn points (`Em4000_<12 hex>`), and an experimental box on the joiner can bring those Molded out in its own game and move them onto the host's (`health.molded_spawn_points`, `health.molded_copies`; see "10.15" below).
- **Testing alone.** In Loopback mode over TCP, tick *Draw received enemies even if I am the host*: the bot then sends two
  pretend enemies (`Em3000`, Jack's id, circling you at 6 m since 9.35, and `Em9998` standing 8 m from where you first were) and you should see
  both as ghosts; with *Enemy models* on (and loading models from files on) Jack's circling ghost is his real model, in his rest pose (no animation yet). That proves the pipe, not RE7's enemies.

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

**Red boxes behind walls (9.26, your note "an enemy block option like with hide other player, same rules").** The joiner no longer draws a red box (label included) that has a wall in the way. Four times a second the nearest six boxes are tested from your camera to the chest, and to the head if the chest is covered, with the same physics test the other player and your shots use (`HIT.wall_between`); a change needs two tests in a row both ways, and if the test cannot run every box is drawn as before. Tick box in the Enemies section, on by default; it needs "Hide them behind walls" ticked (it is the same test, with the same calibration and the same false walls: see "Hiding the other player"). The debug file's `health.enemy_walls` says how many tests ran, how many found a wall and which boxes are hidden. Unverified in the real game.

What is **not** built: enemy deaths shown on the joiner's own screen (the red box just disappears), spawns/despawns, mirroring animations
(the animation bank/motion/frame ids are sent and shown in the debug dump but not applied), and cutscene enemies.
The health field is found by looking for a `Status` component field with "hp" in its name (not "max"/"rate"); the console
says which field it chose or that none was found. Buttons 5 and 6 under "Send me this" are what I need to do the rest properly.

## Death: choose what happens when a player dies

Insert > RE7 Multiplayer > **Death**. The choice is remembered (`reframework\data\re7mp\settings.json`, which also
remembers the other panel checkboxes).

- **Independent (nothing happens)**: the default until 9.21.
- **Shared fate: both players die**: when one player dies, the other dies too. This is what is built.
- **Downed and revive**: the default since 9.22. It only acts while the other player is connected. See "Health, downed and revive" below.
- "Dead player waits for the other" is in the list but not built; it acts like Independent.
- **Executions end the game for both players (9.27, your note "execution kills should down both players, causing game over, because I think it's hard coded").** Box under the death choice, on by default. The files from the v0.8 test show an execution's game over coming with health well above 1 (350 of 1100, 6 s after the grab), so the "hold at 1 health" of Downed and revive cannot stop it. When the game over of a player who is **not downed** looks like an execution, the script sends it as `exec` and the other player's game goes game over too (a team wipe), instead of one player alone being sent to the checkpoint. "Looks like an execution" is a guess: health above 1.5 at that moment, or a grab call (the calls the execution test logs) in the last 20 s. A normal death that the hold could not hold, with an old health value, could be mistaken for one. The panel shows how many were sent and received and how many ignored, and a button tests the receiving side. Unverified in the real game.
- **(Removed in 10.23.) Execution test (9.18, experimental, two boxes below the death choice, off at every start):** logs what a grab or finisher calls and can block the game over to go down instead. See the v9.18 section at the top. **What the v0.8 test showed:** a grab by an `Em3000` started (five `PlayerGrappleEm3000` calls at once) with health 650 of 1100, the game over came 6.0 s later at health 350, the block turned it into "down" and the host revived the friend 12.8 s after that. So the block and the revive worked once in the real game; whether the character felt stuck during those 13 s cannot be seen in the file.

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

**9.32:** the *FORCE* box (experimental, off) now **plays** the other player's cutscene in your game too, by calling the game's own `requestEvent` with a transform put where their game's was; limits and the crash memory are described in the 9.32 section above. Nothing else here is replayed yet.

**One move per cutscene (9.26).** The v0.8 test had the same cutscene id asked for again and again as the host walked: in the last 12 story events of the joiner's file `c03e21_02` is there 10 times, from spots up to 6 m apart, and the host's file counts 7 repeats (the joiner's file counts 9 moves, 18 not moved, 21 cutscenes seen). Some triggers fire again every time you cross them. The joiner is now moved to the host's place only once per cutscene id within 60 s (the journal says "I was already moved for c03e21_02 N s ago"), on top of the existing 15 s between moves, the 3 m "already there" rule and the 5 s same-id ignore on the sending side. Unverified in the real game; the notes about the ladder cutscene and a body "moved to the corner of the room" are not explained by anything in the files (see the findings file).

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
4. **Real player model.** Either clone a full-body player mesh if the game has one loaded (done since 9.29 by the Real body box, which copies the model's mesh and parts; the old Avatar experiment is gone), or spawn one by name. Then play the mapped motion on it. Every asset comes from each player's own install: nothing is shipped or copied.
5. **Real enemy models.** The joiner's game must have the enemy loaded to show it. Where both players are in the same area it usually is, so mode 3 (moving your own
   copy onto the host's position) can be extended to also apply the host's motion (bank / motion / frame) with the AI switched off. Spawning enemies the joiner
   doesn't have is a separate, harder job (`EnemySpawnInfo`, 13 in your census, is where to look).
6. **DLC.** Each DLC character is probably a different player object, mesh and motion set, so the pose data needs a **character id** (sent once, like the name) and a
   table of character profiles: how to find that character's health, motions and model. The `GameMode` enum has `Extra00` and `Extra01`, which may be the extra
   modes; I would run the census / player details (buttons 3 and 8) inside each DLC to see. Both players would need to own the DLC.

Since 9.24 steps 2 and 4 have a first, experimental form: the **Animation clips** recorder writes down Ethan's joint movements and the game's motion ids per action (see above), and the clip player replays them on the body lab's body. The rest of this list is not built; it only shapes what the debug buttons collect next.

## Co-op saves: sharing a save with the other player

**Share saves (TCP)** is on by default in `re7mp.exe` (since 9.22) when the Steam save folder is found; if it is not found the box starts unticked. The Save folder box must be the one for **the Steam account you play on**
(`...\userdata\<your account number>\418370\remote\win64_save`). Only manual saves (`data001Slot.bin` ... , the Load screen's rows 1, 2, 3 ...) are shared; the Autosave (`data000.bin`) never is. While connected:

1. When one player saves, re7mp.exe notices the new save file once it has sat untouched for a moment (so it never sends
   half a file), and sends it to the other player over TCP, in pieces, with a checksum.
2. The receiver installs it **one slot past the highest save in the folder** (since 9.22; before that it took the sender's own slot number if free), so it cannot sit on a number your next save would use. **It never overwrites one of your own saves**; the only thing it replaces is the earlier copy it installed of the same save when the sender saves again. **(9.32) The game lists 15 saves**, so nothing is put past slot 15: when one past the highest would be past 15 the lowest free slot is used, and when all 15 hold a file the **oldest co-op copy this tool installed** is replaced. Your own saves, and the ones you sent, are never replaced; if all 15 are saves of your own the co-op save is not installed and the status line says what to do (delete one in the game, ask them to save again). Autosave sync is not done.
3. **The recognizable label.** Every shared save gets a label like `CO-OP Alice 2026-11-06 21:04`. The save files themselves are
   binary, so the label can't be written into them. Instead it is kept in four places: a `CO-OP` notice on screen when one arrives,
   the "Co-op saves" part of the panel (slot number, `[CO-OP: name]`, whether you saved it or received it), `reframework\data\re7mp_coop_saves.json`,
   and, experimentally, **in the game's Load menu itself** (the script rewrites the objective text on screen, not the file; see v9.4 above).
   Saves you made and sent are listed too, labelled with the player you shared them with.
4. Only saves made while the other player is connected are shared. Single-player saves stay private. A save you
   *received* is not sent back.

**Saves from another Steam account (your 2026-11-08 note: "saves dont sync properly"). Fixed in the exe after 9.24; NOT yet tried in the real game.**
RE7 ties a save to the Steam account that wrote it, so a copied file is "Corrupted Save Data" for anyone else. This is why the Load screen showed the label and the other player's name but the data never changed. Reading AutostrongSharp's source
(mi5hmash, MIT) and your save showed that the account only appears in two places in the file (details in `src/save_resign.hpp`): one 8-byte block of the 48-byte header, and the checksum (Murmur3) in the last 4 bytes. The rest is the save itself
and does not depend on the account. So **no key is needed**: when a save arrives, `re7mp.exe` takes the account block from the saves the game itself wrote on *your* account (it looks at the first 48 bytes of each `.bin` in your save folder, ignores
copies it installed, and goes by the majority), puts it into the incoming file and recomputes the checksum. That is the same result as AutostrongSharp's "Re-sign". Nothing on the network changed: the sender's file is sent as it was, and only the receiver's exe has to be the new one.
- The status line and the manifest say `re-signed for your Steam account (...; learned from N of your M save file(s))`. The recorded checksum is the one of the file on disk, so the 5-second re-check still works.
- **It refuses, and says why, when it cannot do it properly:** your folder has no save of your own yet (start RE7 once, reach the main menu, make a save, ask them to save again); your folder's saves name different accounts with no majority (saves copied in by hand); the incoming file is damaged or encrypted with another key.
  Files that are not RE7 saves are installed unchanged, as before.
- **What I could not check, and the first suspect if the game still says "corrupted":** every save has its slot number stored *inside* the encrypted body, and this exe puts a received save into a *different* slot number than the sender's (by design, so it never lands on a save of yours). I do not know whether the game compares the
  two; changing the body needs the game's key, which I do not have. If a re-signed save still fails, tell me, and the slot rule changes (use the sender's slot number when it is free).
  Also assumed: the header block holds `account id, 0` and the 0 is the same in all your files (the folder scan insists that your own files agree).
- Checked: the checksum code reproduces the checksum in two real RE7 saves (yours, 4.3 MB, and the sample from AutostrongSharp, 5.5 MB) and in the two test files of the original tool (`tests/data/autostrong_test_*.bin`, MIT, see `tests/data/autostrong_README.txt`);
  unit tests build RE7-style files for two accounts and check the header block, body and checksum after re-signing, the majority rule, every refusal, and a TCP transfer between two engines; 22 deliberate breakages of the new code were caught.
- By hand, for saves that were copied in some other way: AutostrongSharp (source = the sender's Steam32 ID, target = yours, RE7 profile, "Resign All"; back up, Steam Cloud off).

**Credit and licence:** the layout of the save container comes from [AutostrongSharp](https://github.com/mi5hmash/AutostrongSharp) by mi5hmash (MIT). re7mp's re-signing is its own C++ code and uses no key; the AutostrongSharp licence text is in `THIRD_PARTY_NOTICES.md`, which stays in the package and in the repository next to the credit and the link.

**How to test it:** both PCs on the new exe and Steam Cloud off for RE7 (Steam > RE7 > Properties > General; otherwise it may "restore" or overwrite files in the folder). Player A saves at a typewriter while connected. Player B's exe log and panel should say `Co-op save from A installed in slot N ... re-signed for your Steam account`.
Then B opens the Load screen (a restart of the game may be needed to list a file written while it runs) and loads that slot. If it says corrupted or does not change, send the debug file and the exe's log.

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
- `src/engine.*`: networking thread, names, ready-check flags, reliable message channel, one-shot events, loopback bot (orbit / stationary / follow)
- `src/packet.hpp`: wire format v6 (position + rotation + ready flags, name, event, message, acks, file transfer, enemy state) and name sanitising
- `src/version.hpp`: the release number (`kReleaseVersion`)
- `src/updater.hpp/.cpp`: release check, exe download and swap, REFramework installer (network behind an `HttpClient`, so it is tested with a fake); `src/zip_extract.*`: zip reader with its own inflate;
  `src/http_win.*`: the WinHTTP client (Windows only); `tools/make_zip_fixtures.py` writes `tests/data/*.zip`
- `src/bridge.hpp`, `src/json_mini.hpp`: the JSON file bridge to the Lua script and its small JSON parser
- `src/character.hpp`: the exe's "Play as" choice (9.31): the list (Automatic, Ethan, Mia, Clancy, Pete, Andre; 9.37), `re7mp_char.json` written and read back, the counter that says a choice is new
- `src/game_locator.*`: Steam library parsing, Lua installer
- `src/save_resign.*`: makes a received save name your Steam account (account block + Murmur3 checksum; no key needed)
- `src/save_sync.*`: co-op saves: save-folder discovery, stable-file watcher, slot picking that never touches single-player saves and never goes past slot 15 (9.32: a full folder replaces the oldest co-op copy), the co-op manifest
- `src/transport.hpp`, `src/tcp_transport.cpp`: transport interface and framed TCP with host/join and auto-reconnect (a Steam backend, or UDP again, would slot in here)
- `lua/re7mp.lua`: in-game script (pose sending, smoothing, 3D body + debug skeleton, ready check + block/freeze, RE7 adapter, chat/pings, item sync, item give/drop, enemy sync, death, tracer, probe tools)
- `src/cli_main.cpp` (`re7mp_cli`): headless engine; `tests/core_tests.cpp` (`re7mp_tests`); `tools/fake_game.py`, `tools/lobby_sim.py` (ready-check simulation); `tools/lua_smoke.lua` + `tools/luarun.c` (runs the Lua against a mock game, see below)

## What has and hasn't been tested

Tested (on Linux): packets and name sanitising, the JSON parser, the bridge, Steam folder parsing, Lua install,
loopback (orbiting and stationary bot, teleport, rotation copying, the full ready check), TCP between two
engines (names, pose, flags, reliable messages both ways, resend and exactly-once delivery when the peer starts late,
TCP reconnect after the host restarts, the host's address restriction), chat/ping echo through the bot, and save sharing
between two engines over TCP (a save lands in a free slot and never replaces a single-player one, the copy is not sent
back, both directions, saves made while disconnected stay private, a 3 MB save, and the loopback echo).
Since the exe after 9.24 also: re-signing a received save for the receiver's Steam account (unit tests on RE7-style files, the real checksum on two real RE7 saves, and a TCP transfer between two engines). Not tried: the game loading such a save.
Also tested: the enemy-state packets (encode/decode, bad input, over TCP) and the loopback bot's two pretend enemies
arriving as `re7mp_state_in.json`. The Lua now runs under a real Lua 5.4 interpreter against a **mock** game
(`tools/lua_smoke.lua`: fake scene with `Em2000`/`Em6100` roots, fake inventory and item manager): it loads, the
enemy snapshot has the right fields and ignores non-enemy objects named like enemies, ghosts are drawn and follow
the host's list, mode 3 moves the right object and releases it when the host goes quiet, give and drop messages go in
and out, malformed ones do nothing, the settings file and debug collectors write what they should (3212 checks as of 9.37, 3204 as of 9.36, 3073 as of 9.35, 3018 as of 9.34, 3007 as of 9.33, 3050 as of 9.32, 2633 as of 9.31, 2313 as of 9.30, including the Load screen labels against a copy of your real SaveMenuGUI scan (`tests/data/save_menu_scan.txt`), the release number and version check, odd item names and an unreadable inventory entry, your parked-enemy case, the HealthInfo path, the inventory list, the item-name-as-managed-string
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
chat/ping drawing.
