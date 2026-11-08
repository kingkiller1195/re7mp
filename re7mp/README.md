# RE7 multiplayer prototype

One exe (`re7mp.exe`, a small GUI) and one Lua file (`lua/re7mp.lua`, embedded in the exe and
installed for you). Each player sees the other as a shaded 3D body with a name tag, facing the direction they
are looking, and the two games can talk to each other (new-game sync, chat, pings, item pickups, handing items to
each other, and the host's enemies shown on the joiner's screen).

    RE7 + REFramework (re7mp.lua)  <--files in reframework/data-->  re7mp.exe  <--TCP-->  other player's re7mp.exe

**Both players must run the same version.** This one is **release 0.7** (wire protocol v6), so an older
`re7mp.exe` on either side is ignored: both of you need the new exe, and the same script.

## Releases and the version check

- **Release number** (what you publish on GitHub): `0.6` is the published beta (v0.5 before it), this build is **`0.7`**. It stays 0.7 until you say to move it.
  It lives in two places that must agree: `src/version.hpp` (`kReleaseVersion`, used by the exe) and `RELEASE = "0.7"` near the top of `lua/re7mp.lua`.
  A test fails if they differ, so you can't ship half a bump.
- **Build label** (`v9.15`, `BUILD` in the script) is my internal change counter between releases. Ignore it unless you are reporting a bug.
- **Where you see it:** the `re7mp.exe` window title (`RE7 Multiplayer v0.7`) and its first log line, the top of the in-game panel
  (`RE7 Multiplayer v0.7`, and under it `Release v0.7   (script build 9.15, re7mp.exe v0.7)`), and the debug file (`release`, `build`, `exe`, `exe_protocol`, `other_player_version`).
- **The check.** When the other player appears, each script tells the other `release / build / exe version`, and again every 20 s.
  The panel (in red) and the log say so if:
  - the other player is on a different release: *"Bob is on release v0.5 but you are on v0.7: update so you both run the same version"*;
  - their script sends no version at all for 8 s (an older script): *"Bob's script is older than release v0.7"* (never said for the loopback bot);
  - your `re7mp.exe` and your script are from different releases (for example you updated the script but not the exe).
  Separately, if the other player's `re7mp.exe` speaks a different **protocol** (an old exe), the exe can't read their packets at all; its "Other player" row then says
  *INCOMPATIBLE* with both protocol numbers, instead of just showing nothing.
- Nothing is blocked: a mismatch is a warning, not a refusal to connect, since two nearby releases may well work together.

## What changed in v9.15 (release 0.7; same protocol v6; **script only, nothing to rebuild**)

This build answers one report: **the game crashed when the F8 revive reached 3 seconds** (your 9.14 file ends 3 s after `reviving Loopback Bot: stay within 3 m for 3 s (the RemedyM is used when it is done)`), plus your decision that **F8 should cost no item, the time is the penalty**. Walking away mid-revive cancelling it worked. **Unverified in the game**, as before.

**F8 now uses no item and touches nothing in the game.** Press F8 (or the panel button) next to a downed player and stay within 3 m for 3 s (slider, 1 to 10 s). It checks only the two positions; at the end it tells the other player and that is all. The inventory is never read or changed, so a revive works with an empty inventory. It stops for free when they get up, you walk out of range, you go down yourself or you press Cancel (holding the key down starts one countdown, not one every 3 s). **Using a Herb / Chem Fluid / Remedy from the inventory menu is still immediate and costs the item**, so the two routes now differ the way you wanted: time versus a heal.

**About the crash.** The only game call at the 3-second mark in 9.14 was `Inventory.reduceItem("RemedyM", 1, true)` (your inventory had no Herb or Chem Fluid, so it picked the Remedy). That call is the same one that gifts use, which has worked in the game, so I can't prove it was the cause; what I know is that it was the only thing that happened at that moment and it is gone now. If the game still crashes at the end of an F8 revive, the cause is somewhere else: a crumb is written just before the final step (`revive: finishing the F8 revive of ...`) and the next start says **`previous session: The last session ended while the script was finishing an F8 revive`** if it died there. Tell me what that line says.

**What the revived player sees.** `Bob helped you up 1.1 m away` in the panel and the journal (instead of `Bob used a Herb`); the message carries no item name (`e|revive||x|y|z`; an older script on the other side would say "used a healing item", still getting you up). A heal event from the inventory route is unchanged. The same distance rule applies: 3 m, plus 25% slack for lag.

**Not changed (still open):** everything from 9.14 that I could not test (the three `addItem` forms, the dropped item's visibility, the item manager adoption) because the crash ended the session first.

**What I need from you next (loopback is enough):** (1) F8 on the downed bot, staying put, and once walking away halfway; (2) the receive buttons in *Items: give and drop* (Herb, HandgunBullet), then (3) a discard, then send `re7mp_debug.json` (`health.items.last_add`, `last_drop`, the `drop:` / `add:` lines). If the game crashes, send the file from the next start.

Internal build label is now 9.15; the release stays **0.7**. Tests: 1002 Lua checks (F8 never touches the inventory, works with an empty inventory, the receiving side's "helped you up", the slack, the new crumb and its report on the next start); the new code was checked by mutation (9 new breakages, all caught). One C++ test (`test_save_loopback_echo`) failed about half the time on a slower machine: it saved 1.5 s after start but the loopback bot only appears after about 2 s, and a save made before the other player is there is by design not sent. The test now waits for the bot; the exe itself is unchanged.

## What changed in v9.14 (release 0.7; same protocol v6; **update the script; rebuild the exe only if you want the bot's new reach**: the exe change is just the loopback bot's revive distance)

This build answers your 9.13 notes and file: revive works but should be 3 m and F8 should not be instant; **a dropped item did not show up for the person who dropped it** (the other side saw it); **the game crashed while I tried to give you a Herb and bullets, and nothing arrived** (an earlier version at least delivered the bullets). I read your 9.13 debug file first. **Nothing below has run in the real game**; it runs against my mock. Where a fix is a guess it says so, and the next file will show whether it was right.

**1. Revive distance is 3 m (was 4).** Both for using a Herb from the inventory next to someone and for F8. The panel slider "Revive distance (m)" still goes from 1 to 10. A saved distance of exactly 4 (the old default) is not kept, so you get the new 3; if you had picked another number it is kept. The player who is down still accepts a heal from up to 25% further than the distance (3.75 m) to allow for lag; the loopback bot uses the same 3.75 m.

**2. F8 is a countdown, not an instant revive.** *(9.15: it also uses no item any more, see above; the next sentences describe 9.14.)* Press F8 (or the panel button) next to a downed player: you must stay within the distance for **3 seconds** (slider "F8 revive: seconds to stay within that distance", 1 to 10 s) and only then is the Herb / Chem Fluid taken from your inventory and the other player told. The screen shows `Reviving Bob... 1.2 / 3 s`; the panel shows the same with a **Cancel the revive** button. It stops at no cost if they get up on their own, you walk out of range, you go down yourself, the Herb is gone (checked twice a second), or you press Cancel. Pressing F8 again while it counts does nothing, and holding the key down starts one countdown, not a new one every 3 s. **Using a Herb from the inventory menu on someone is still immediate**, as you wanted: that is the costlier, riskier way (you open the menu next to them), F8 is the safe one that now takes time. The debug file's `health.revive` has `radius`, `hold`, `started`, `done`, `cancelled`.

**3. Items: what the 9.13 file showed, and what I changed.** Unverified in the game.
- **A copy of the item manager that knows nothing replaced the good one.** At the end of your file the scene component and the singleton both know the items, but the copy *in use* was "the one the game's own `createItemInstance` call used", which answers nothing for `findItemData`. It took over as soon as the game created an item, and the third gift (HandgunBullet x5 at 305.8 s) failed with "createItemInstance gave nothing". Now a copy handed over by the game is only used if it knows items, and a copy that works is never replaced.
- **`addItem` was called wrongly and its answer ignored.** It is `app.Inventory.addItem(Item, GameObject, Boolean, List)` and it answers an `app.Inventory.AddItemResult`; the old call passed no list and said "done" whatever came back, so an item could be "delivered" without ever being in the inventory: your file says `gave you HandgunBullet x5 (in the inventory)` and `Herb x1 (in the inventory)`, and you saw neither. Now three forms are tried in turn (the 2-parameter one, the 4-parameter one without a list, the 4-parameter one with a new empty list), what each answered is written down, and **the gift only counts as delivered when the inventory really holds more of that item than before**. If none works the item is put on the ground instead and the sender is told so.
- **The crash.** I cannot see the crash itself, so this is a suspect: the creation calls were also being tried with the object an inventory entry carries as "owner" (that is an item's own object, `sm1852_AntisepticSolutionMedium_Item` in the file), which is not something the game's creation code expects. Only the player object is passed now. And a crumb (`re7mp_lastcall.json`) is written before every item call, so **if the game crashes again, the next start says which call it was** (`previous session: The last session ended while the script was handling an item: ...`). A stale crumb from an old hook install was also blamed for no reason in your file; those are cleared now.
- **The dropped item that nobody could see.** The game makes a dropped item at its *owner* (a drawer, in its own use); here the owner is you, so the item was probably created inside you, or as a child of you, or hidden. Now the object is let go of the player, put 0.8 m in front of you (just above the floor), switched to drawn and updating, and read back; **if it is still hidden afterwards the drop is reported as failed instead of "ok"**. The journal gets a `drop:` line saying what the object was and what it became, and `health.items.last_drop` keeps it. This applies to your own discard and to what you receive.

**Confirmed by your file:** the Discard button runs `app.InventoryMenu.discardItem` (`menu_discard_calls: 1`, `reduceNum_calls: 0`), the hook saw it and queued the drop (`discard: HandgunBullet x20 will be put on the ground`), and the item manager in use at that moment knew the items (`created` and reported dropped at 208.1 s). So detection and creation worked; what was wrong was where the object ended up (see the last bullet above).

**Not changed (still open):** finishers; Jack frozen on the host's screen after the dinner cutscene; the heal animation id; the "keep every version" co-op option; the co-op save data issue (waiting for a file with two real players); door/event replay.

**What I need from you next (loopback is enough):** (1) in *Items: give and drop* use **Test: receive 1 Herb** and **Test: receive 5 HandgunBullet** (and give the bot something from the inventory list); (2) discard an item and say whether it appears on the ground for you; (3) make the bot go down, stand within 3 m, press F8 and stay put; try walking away halfway; (4) send `re7mp_debug.json`. In it I'm looking for `health.items.last_add` (which form of `addItem` worked, and what each answered), `add_item_result_names`, `last_drop` and the `drop:` / `add:` journal lines, and `health.revive`. **If the game crashes, send me the debug file from the next start** (it has the "previous session" line).

Internal build label is now 9.14; the public release number stays **0.7**. Tests: 996 Lua checks (55 new: item manager adoption, the three `addItem` forms and the landing check, the drop's parent / visibility / placement, the crumbs, the 3 m distance, the countdown and each way it stops, the saved settings) and the C++ suite (the bot's 3.75 m reach). The new Lua code was checked by mutation (50 deliberate breakages; the 16 that first went unnoticed got their own tests, and all are caught now).

## What changed in v9.13 (release 0.7; same protocol v6; **rebuild the exe AND update the script**: the exe's loopback bot changed, the script changed for everything else. For two real players only the script matters; the exe change is only the bot)

This build answers your notes from the 9.12 file: going down works but you want the status shown, the loopback bot did not confirm gifts, you want to test a revive alone, and **discard still deletes the item instead of dropping it**. I only have your debug file and the loopback bot to go on, so every item below says what is **unverified in the real game**.

**1. Going down: the lock works, nothing to change.** Your file: the gun refusals fired 2946 times, the position pin put you back 55 times, the game re-opens the gates inside `updateActionTrack` (the hook there is what closes them). The knife still works while you are down because it is not one of the gun's calls; I kept it that way on purpose, since your partner can defend you and clear the way for a revive. I did remove two hooks that did nothing and were very hot (`update` and `lateUpdate` on the sequence manager: 2.4 million and 68 thousand calls in one session, all muted); the lock keeps the 8 useful sequence-manager hooks, the 3 gun hooks and the move getter.

**2. `[downed]` after the name.** `Bob [downed]` (red) over the other player's head, the same place and style as `[crouching]`, `[healing]` and `[blocking]`. The pose labels are not drawn while they are down. (The panel's Health section still says `DOWN` next to their health numbers.)

**3. The loopback bot answers gifts and drops, and can go down.** `re7mp.exe` (C++): the bot now answers a gift with the confirmation your script waits for (`Loopback Bot has Herb x1 (the loopback bot took it)`), so the item now leaves your inventory when you give it to the bot; a drop is answered too. A new message kind, 11, tells the bot to go down or get up (only the bot understands it; a real player's script ignores it). In the panel (Health and downed, only when the other player is the Loopback Bot): **Loopback bot: make it go down** and **make it get up**. While down the bot stays where it fell, shows `[downed]` and says so every second. To revive it: walk within 4 m and press **F8** (takes a Herb / Chem Fluid from your inventory) or use a Herb in the inventory next to it (any heal event within 5 m gets it up). The bot says it got up when it does. A downed bot does not move or do poses.

**4. Discard: what I found and what I changed. Unverified in the game.** I could not tell from the 9.12 file why discard only deleted: the journal had no discard line at all. Two things stood out, and 9.13 fixes both plus makes the next file explain itself:
- **The item manager the script used was an empty shell.** `findItemData("Herb")`, the name list and every create call answered nil, which is why *nothing the script creates ever appears* (gifts you receive, drops on discard, drops from the other player) while "grow the stack you already have" works. The real manager is a component on the object `SystemObject` (older traces show it called there). The script now collects every copy it can find (components in the scene, the one on `SystemObject`, the singleton, the one the game's own creation call used), asks each whether it knows an item, uses the first that does, and tries again later (15 s, 30 s ... up to 2 min) while none does. `health.items.item_manager` says which copy is in use and whether any knew an item; the journal says `item manager: using ...` once; the probe lists every copy.
- **Discard is also hooked at the menu.** `app.InventoryMenu.discardItem(item) -> Boolean` is in the game's method list: it carries the item with the call and says whether the discard happened, so it needs no "highlighted item". It is hooked as well as `reduceNum`, and the two agree (one drop per discard). Every discard-like call writes a `discard:` journal line (25 at most): what it saw and why it was or wasn't treated as a discard. `health.items.discard` counts the calls.
If discard still deletes, the next file will say which part failed: no `discard:` lines and `menu_discard_calls: 0` means the Discard button runs neither call; a line saying it will be put on the ground followed by a failed creation means the item manager still can't create objects.

**5. Smaller fixes from the file.** `app.Inventory.getExtendLevelState` is a static call in this game, so the hook that remembered the inventory from it threw on every call and flooded the log; it is guarded now. Any hook that fails logs at most 3 errors.

**Not changed (still open):** finishers; Jack frozen on the host's screen after the dinner cutscene; the heal animation id; the "keep every version" co-op option; the co-op save data issue (waiting for a file with two real players); button 9; door/event replay.

**What I need from you next (loopback is enough):** (1) give the bot an item from the inventory list: the item should leave your inventory and the log should say the bot took it; (2) press **make it go down**, check the `[downed]` tag, stand within 4 m and press F8 (or use a Herb), and check it gets up; (3) discard an item in the inventory, then send `re7mp_debug.json`: I'm looking for the `discard:` journal lines, `health.items.discard` and `health.items.item_manager`; (4) say whether a dropped item appeared on the ground this time.

Internal build label is now 9.13; the public release number stays **0.7**. Tests: 941 Lua checks (44 new: the item manager choice, the SystemObject and late-manager searches, discard before and after, the journal caps, the bot buttons, the bot's exact messages and the `[downed]` label) and the C++ suite (the bot's gift and drop answers, going down, the frozen position, the health report, the far and near heal). The new Lua code was also checked by mutation (deliberately breaking it and seeing a test fail).

## What changed in v9.12 (release 0.7; same protocol v6; **rebuild the exe AND update the script on BOTH computers**: the exe's save code changed this time)

This build answers your 0.6 notes ("going down still lets you move and shoot", "saves are sent and labelled correctly but don't contain the right save data"), your screenshot of the false version warning, and your 0.7 notes ("receiving via dropping and going to the inventory still doesn't work", `createIteminstance failed: nil`, "firing the gun 3 times ... doesn't find anything for the gun"). I read both debug files (builds 9.9 and 9.11) first; what they showed is in `re7-findings.md`. **None of this has run in the real game**; it runs against my mock. Where a fix is a guess, it says so, and it writes down what it did so the next file can tell us.

**1. The false "version is mismatched" warning.** Not caused by changing the number halfway through. The script reads `re7mp_in.json` to learn the exe's release, but the exe only writes that file while the other player's packets arrive, so the file left behind by an older exe was read as "the exe you are running now". The warning was also latched, so it never went away. Now the exe's release only counts after the file has been seen to **change**; the warning clears as soon as the exe reports the matching release; and the first version message to the other player waits (at most 2 s) until the exe's release is known, so it no longer goes out with `?`.

**2. Going down: the lock is rebuilt around what your 0.6 file showed.** The file: `app.PlayerSequenceManager.IsAimAccepted` and `IsAttackAccepted` were open again at `post:UpdateBehavior` in 706 of 5241 frames and nowhere else, i.e. **the game re-opens them inside its own update**, after my once-a-frame write. The type has no method called `update`, but it has `updateActionTrack`, `updateMovementTrack`, `updateDeadTrack`, `updateJogTrack`, `updateTurnTrack`, `updateCodexTrack`, `updateLaserSightTrack`, `onMotionUpdated`, and getters such as `get_isMoveAccepted`. Now, when you go down:
- the two gates are closed again **right after each of those update methods** (hooked the first time you go down, not at start-up), as well as at the frame callbacks as before;
- **the gun's own `tryAttack`, `tryAimStart` and `trySemiAimStart` are refused** (skipped, and the answer is "no") while you are down;
- **`get_isMoveAccepted` says no** while you are down, and if the game moves you anyway you are **put back where you fell** (sideways only; a jump of more than 4 m is the game moving you, e.g. a cutscene, and becomes the new place);
- a hook that fires more than 6000 times a second is muted (so a wrong guess about which method is hot cannot cost frames), and every part has its own tick box in the panel and its own line saying what it did.
The debug file's `health.weapon_lock` now has `hooks` (installed, not found, fired while down, muted), `gun` (installed, calls refused), `move` (how often the move gate was asked, how often it said no, how often you were put back and at which point in the frame) and the existing per-place leak counts. **If something still works while down, this tells me where.** What I cannot know: whether the game reads the gates through these exact methods (it may inline them), whether the position pin fires at a point after the game moved you, and whether skipping a gun call leaves the gun in a bad state. If any of the three misbehaves, untick that one box.

**3. Gifts and drops.** The 0.7 file: `createItemInstance` and `createDropItemInstance` both **returned nil without an error**, and 9.11 treated "no error" as "it worked", which is why it said "dropped at your feet" when nothing appeared. Now:
- **only an object that really came back counts.** nil is a failure with a reason, and the answer to the sender says so;
- the item is created with each plausible owner (the player object, then the owner an inventory entry carries) and each plausible name form (plain, managed string); the first that returns an object wins and `health.items.create_worked_with` says which;
- if creation still fails, the gift **grows a stack you already have** (`getStackNum` / `getMaxStackNum` / `setStackNum`, only if the whole amount fits, and read back to check). `Herb` into a Herb stack works that way; a new kind of item cannot;
- when creation fails the script writes a **probe** into the journal (once a minute): what `findItemData` returns for the name, its fields, whether the game lists the name in `get_ItemDataIDNames`, and a sample of the names. That is the data I need if the owner/name variants are not the answer;
- **a gift now leaves your inventory only after the other game says "ok".** Before this, the item was taken at once and a failure handed it back (if it could); now nothing is taken until they confirm. If they cannot take it, you keep it. If nobody answers in 10 s, it stays with you. A gift is never lost; the worst case is that you hear "no" and keep it.
- the panel and `health.items` count what was sent, received, dropped, bumped and failed.
Both players need 9.12 for the confirmation: a 9.11 receiver does answer, so it works across 9.11 and 9.12; a 9.10 receiver does not answer, so you keep the item and are told after 10 s (note that their older script may have added it as well).

**4. Shots from the gun's own call.** The 0.7 file: the shot learner watched 15 s and found no number that dropped by one per shot, so the damage-to-host's-enemies feature had no signal. The type is `app.PlayerGun`, and it has `shoot` and `shootStart`. Now the joiner hooks those two (pre-hook only notes the time; the ray test runs in the next frame) and one call counts as one shot. The learner also counts those calls and says, e.g., `the gun's own shoot call ran 3 times while you fired: shots are taken from it`. It is on by default for a joiner in enemy mode; a panel tick box turns it off, and the panel line shows `shoot calls seen: N, used as shots: M`. `enemy_hits.gun_hook` in the file has the same. If `shoot` fires for something that is not a shot (a dry fire), you will see calls > shots; send the file.

**5. Co-op saves: I do not know yet, so the build now records everything.** In 9.11 I wrote that the behaviour you saw was "as built". That explained which slot a save goes into, not why the data is wrong, and **I withdraw it as an answer**. Your report: Andre saves in slot 10, where you have a save of your own; the label and his name appear, but the data in the slot does not change and no new slot has the data. By design the receiver puts that save in the lowest free slot instead (it never overwrites a save of your own). Possible causes I can see from here, none confirmed: the label was attached to the wrong row (your own slot 10), the game does not list a file that was written while it was running, the exe was watching a different Steam account's folder, Steam Cloud put the old file back, or the slot is beyond what the Load screen shows. What the build does about it:
- after writing a received save the exe **reads the file back and checks its size and checksum**; if it does not match, the save is **not** marked CO-OP and the message says so;
- every 5 s it checks the received copies again; if something wrote the file since (the game, Steam Cloud), it says `Slot N no longer holds the save that was received` and drops the label;
- each received entry records **why it went where it went**: `same slot number as on Bob's PC (it was free here)`, `it replaced the earlier copy from Bob in that slot`, `slot 10 here holds a save of your own, so it went into the lowest free slot`. The panel's Co-op saves list shows `Bob's slot 10 -> your slot 3: why`;
- the script asks the game itself (`SaveDataManager.isExistData`) whether it lists that slot, and the panel says either `the game lists this slot: Load Game shows it as slot N` or `THE GAME DOES NOT LIST THIS SLOT`. That line is the most important one: if it says "does not list", the file is there but the game does not see it (restart the game, or Steam Cloud is interfering);
- a save **you made and sent** is labelled `[CO-OP: sent to Bob]`, never with his name as if it were his;
- `health.coop_saves` in the debug file has all of it (folder, entries with from-slot and why, whether the game lists each slot, label status).
**What I need:** have Andre save once while you are connected; then open the panel's Co-op saves section and tell me what it says for that save (the slot numbers, the why, and whether the game lists it), look at the Load screen, and send the debug file and `re7mp.exe`'s log.

**6. The journal no longer fills with method lists.** The 0.7 file's journal was almost all indented lines of the method dump; the journal now leaves out any line that starts with a space (the debug file's `lines` still has them).

**Not changed (still open):** finishers; Jack frozen on the host's screen after the dinner cutscene; the heal animation id; the "keep every version" co-op option; hands 16/17 as an inventory pose; button 9; door/event replay.

**What I need from you next:** send the debug file right after (1) going down and trying to move, aim and fire, (2) a give of a Herb when the receiver has a Herb stack, and one of an item they do not have, (3) a discard-drop, (4) firing the gun three times as a joiner in enemy mode, (5) a co-op save made by the other player. The sections to look at: `health.weapon_lock` (`hooks`, `gun`, `move`), `health.items`, `enemy_hits.gun_hook`, `health.coop_saves`, and the journal lines starting `give probe` and `weapon lock:`.

Internal build label is now 9.12; the public release number stays **0.7**. Tests: 897 Lua checks (108 new: the stale exe file, the warning clearing, the version message waiting for the exe; the lock hooks installing only after going down and only for the boxes ticked, the gates closing after each update method, the gun calls refused and answered "no", the move gate, the position pin and its tolerance, a teleport as the new place, the hot-hook mute and every per-place count in the file; the two-phase gift (nothing taken before "ok", taken after, kept after "fail", kept after the 10 s timeout, the guard against the health module seeing the removal); creation variants, nil as a failure, the stack fallback with its full-stack and read-back cases, the probe lines and their rate limit; the shoot/shootStart hook for a joiner and not for the host, the learner counting hook shots; the journal leaving out indented lines; the sent tag, the game-lists-this-slot lines and the `coop_saves` block) and the C++ suite (new: provenance and `why` kept in the manifest, tags for received/sent saves, the read-back check, the re-check that drops a label when the file changed, and an end-to-end case with a slot held by a save of your own).  The mutation file now has 175 mutations. For this build I wrote 60 new ones for the new code (each breaks one rule on purpose and a test must fail): 39 of the first 58 were caught at once; 19 were not. For 17 of those I added tests (the move and gun boxes unticked after the hooks exist, the gate-hook box off, the position put back only at the end-of-frame places, a stack that does not change when asked to, the probe's one-minute limit and its 12-entry list, an answer about a gift not settling a drop, a gift counted as sent, a Herb given away not being read as a heal, the exe never telling its release, the gun hook for the damage switch and the hook box, the game's slot list being asked again) and they are caught now; 2 cannot change what the script does (the position pin can only be reached through the function that already checks you are down; the gun's skip flag is cleared before every call anyway). Two more were added later: the probe never being written again (caught) and a second host check on the gun hook (cannot change anything: `receiving_enemies()` already excludes the host). I also re-ran 30 older mutations that touch changed code: 24 are caught; 4 no longer apply (their code was replaced by what the new mutations cover); 2 are not caught: Q18 (only a counter changes, the hit itself is refused when hits are off) and Q29 (the shot learner waiting a second before it decides; an old gap I have left).


## What changed in v9.11 (release 0.7; same protocol v6; **update the script on BOTH computers; the exe's code is unchanged (a rebuilt exe carries the new script)**)

This build answers your 0.6 debug file (`96ca23bd-re7mp_debug.json`, build 9.9) and your list of notes, plus "items are taken from the inventory but cannot be given to the other player or dropped at their feet". I read the file first; what it showed is in `re7-findings.md`. Short version of what is in it and what I did about each thing. **None of this has run in the real game**; it runs against my mock and the real GUI names from your file.

**1. Give and drop: the receiver now answers, and nothing is lost.** The file cannot say why items did not arrive: the give/drop lines had been pushed out of the log by the tracer's lines before the file was written. What I could see: the script only looked for a player object called `Pl0000` (Ethan). Mia is `Pl2000`, so in her chapters the receiving side could not find a player object or an inventory, and a gift had nowhere to go. Changes:
- The receiver finds the player object by pattern (`Pl` and four digits) and, if there are several, takes the one nearest the camera.
- It tries to put the gift in the inventory, then on the ground at its feet. If the player object is not there yet (a loading screen), the gift waits and is retried for about 4 s.
- It then **tells the sender what happened** (a new message, kind 10): `Bob has Herb x1 (in the inventory)`, `... (on the ground (inventory full))`, or `Bob could not take Herb x1 (reason): it is back in your inventory`. A gift that could be neither added nor dropped is **handed back to the sender**, so nothing is lost. Drops get an answer too.
- If the sender hears nothing for 10 s it says so: `no answer from Bob about Herb x1: if it did not arrive, their script is probably older than build 9.11`. **So both of you need 9.11 for the answers; a 9.10 receiver still receives gifts, you just will not be told.**
- New: the **journal** (below).

**2. The debug file now has a journal.** `events` holds the last 600 lines of everything *except* the tracer's lines (give, drop, death, menu, wall, player-object messages). Before, a trace flushed them out within a minute. `lines` is as before.

**3. The other player no longer vanishes behind the map or the tape.** Cause, from the file: the old rule called any GUI with "menu" in its path a menu, and about 40 harmless ones sit under `SystemObject/MenuManager/`. `MapMaskGUI` was seen hidden, then showing, and stayed showing after the tape, so the stand-in was hidden for 81,953 frames. Now:
- the real menu names from your file are listed (`InventoryMenu`, `PauseMenuGUI`, `QuickEquipMenu`, `SaveMenuGUI`, `FileMenu`, `DetailSearchGUI`, the map `ui5000`/`ui5001`, `VideoCameraUI` (the tape) and so on); other names count only if the last part has a menu word (inventory, pause, option, notes, save ...) and nothing from the skip list (mask, fade, movie, logo, icon, guide, reticle, hud, tips, loading ...);
- a GUI that was never seen hidden is not a menu (an always-on one cannot hide you for ever);
- a GUI that stays open while you walk 3 m for 6 s is not a menu and is ignored from then on (the journal says `menu: X is not a menu`, and the debug file lists `ignored_as_not_menus`); the tape player is excepted, since you do walk about in the tape;
- the debug file lists all GUIs it watches, what it saw of each and whether it counts.
The hide itself still follows the tick box; the watching now also runs with the box unticked, because the heal pose needs it (next point).

**4. The heal pose is not taken from the inventory screen.** The file: hands action 16/17 appeared 347 times and 799 packets carried the heal bit while `heals_seen` was 0, i.e. you were only looking at the inventory. That matches your note. Now no heal bit is sent while a menu is open, nor for a pose that was already running when the menu closed (it has to end first). The debug file counts these as `heal_ignored_because_a_menu_was_open`. 16/17 is an inventory-looking animation, so it could become its own pose later. **And** when the other player uses a healing item (the `Bob used a Remedy` event that you did see arrive), the stand-in now plays the heal pose for 2.4 s, whatever the hands animation says. I still do not know the animation id of a real heal.

**5. Crouch uses the game's own flag.** The file: `PlayerMovement.IsCrouch` was true for 12 % of readings and `CrouchRate` was 1 in exactly those; my camera-height guess said "crouched" for half of all readings. `IsCrouch` is now what is sent; the camera height is only the fallback when the field cannot be read. (The panel says `you are sending CROUCH` as before.)

**6. The wall test is rebuilt.** The file: it never started. 96 rays, no layer of 32 saw the floor, so it could not have hidden anyone on your machine, and on your friend's it hid them for a different reason that I cannot see. Now it tries three ways of casting a ray (options cleared and all hits; options left alone; all hit kinds on and no filter) on every layer and keeps the first that finds the floor; ignores anything it hits that is a player object (`Pl####`); starts the ray 0.3 m from the camera and stops it 0.12 m short of the target; **retries** (45 s after finding no layer, a minute after the physics calls fail, up to 5 times) instead of giving up for good; and **calibrates again** if the other player stays "behind a wall" for 30 s while you walk 8 m. The panel says `(way 2)` or `(way 3)` when it needed another way. The debug file has `things_the_rays_hit` (a count by object name, so I can see what a "floor" really is), `way_used`, `floor_hit_layers_by_way`, `retries`, `recalibrations` and the physics method names with their parameter types.

**7. Death: more ways to notice it, and a journal of which one fired.** Nothing in the file shows a death, so this is a guess: besides `setGamemode`, the script now also watches game-over / death methods of `app.GameManager` and of the player's damage controller **by name** (never getters; at most 8; a flag being cleared is ignored; a hook that fires more than 50 times is dropped as too busy). Each firing goes into the journal (`death hook fired: ...`), so after a finisher the next file shows which call it really was. The line `death detection also watches: ...` at start-up lists what was hooked.

**Not fixed (I do not have the answer yet, and did not want to guess):**
- *Finishers do not "go down" in mode 4, and the host does not kill both on a finisher in Mia's attic.* A scripted kill probably bypasses the health hold. Point 7 should show which call it is.
- *Jack frozen on the host's screen after the dinner cutscene.* Probably his AI is not running yet at that point. The joiner only shows where the host's snapshot says.
- *"Co-op save overwrites my save".* **(Withdrawn in 9.12: this explained which slot is used, not why the data was wrong. See v9.12, point 5.)** As built: the first copy of a partner's co-op save goes into a free slot, later saves from the same partner update **that** copy in place (labelled with his name and the co-op marker). Your note says he "saves in that slot", so he was saving over his own earlier received copy. A "keep every version" option is easy to add if you want it.
- *"No changes show until the main house, otherwise fully functional".* I take that as good news; point 1 and the Mia fix may be why the early chapters were quiet.
- *Guest-house animations not working.* Probably the same cause as Mia's player object (point 1); the next file will say (`health.poses.reads` and the `player object:` lines in the journal).

**What I need from you next:** play a bit with the new script on both computers and send the debug file **right after** (1) a give and a drop (it will say what happened on both sides now), (2) a finisher or a death, (3) a Mia chapter, if you get there, (4) the tape. Also tell me whether `walls:` says `working` or `unavailable` in the panel.

Internal build label is now 9.11; the public release number stays **0.7**. Tests: 789 Lua checks (95 new in this build: the journal and its cap; the receiver's answer for a gift that went into the inventory, onto the ground, or could go nowhere, and for a drop; a player object that is missing at first and turns up, and one that never does; the sender's answers (ok, fail with the gift handed back, a different item, no answer after 10 s, a late answer, a drop that could not be shown); Pl2000 with a Pl0000 far away, and Pl2000 alone; MapMaskGUI, a fade GUI and an always-on GUI with a menu name staying drawn; PauseMenuGUI and Gui_Menu hiding; a menu-like name that stays open while you walk being dropped, the tape player and a real menu with a jumping camera being kept; 51 of the 99 real GUI names of your 0.6 file, with their parents, sorted into menus and not-menus; hands 16 with the inventory open, after it closes, and a real heal with the menu closed; the crouch flag against the camera; the death hooks (set and cleared flag, a second signal within 30 s, the player's damage controller, the 50-firing cap, shared fate off); the wall test with hits on your own body, the other two ways of casting, a collider at the camera, no floor found then found, physics failing then working, the physics singleton missing then there, and re-calibration (and the three cases where it must not happen); and the stand-in lifting its heal pose for the other player's item use) and the C++ suite (unchanged, `all checks passed`). The mutation file now has 115 mutations. For this build I wrote 37 new ones for the new code: 35 were caught at once and the two that were not (the wall test not looking for the physics singleton again, and the test ray starting inside the camera) each got a test and are now caught. I also re-ran the 29 older pose, crouch, lock and wall mutations that this build's changes touch: 28 are caught and one cannot change what the script does (a failed physics test leaving the stand-in hidden for a single frame; the next test clears it). The other ~50 older mutations (the enemy-hit code, the recorder, the enemy health fallback) cover code that this build did not change and were not re-run.


## What changed in v9.10 (release 0.7; same protocol v6; **rebuild the exe AND update the script**)

You ran the debug on story items and enemies (about 3,000 lines up to the main house), could see the host's enemies as red boxes, and asked for the next step: **doing damage to them**. This build is that, plus the release number moving to **0.7** (the exe changes only its version number; nothing else in it).

**How a hit travels.** The joiner's bullets cannot hurt the host's enemies on their own: on the joiner's screen those enemies are only red boxes, so the shots fly through them. So:

1. *JOINER, when a shot is fired.* A ray from the camera is tested against the red boxes (the box you see, plus 0.12 m of slack so a shot at the edge counts). The nearest box in the line of fire within 80 m is the target. Boxes that are dead, parked or placeholder objects (the grey ones) and boxes behind you are never hit. If the wall test from 9.9 is working (`walls: working` in the panel), a ray from the camera to the hit point that meets level geometry means "behind a wall" and nothing is sent; a box whose near face is closer than 0.8 m is never counted as behind a wall. If the wall test is not working the hit is sent anyway and the panel says `(walls not checked)`.
2. *Message.* `x|Em2000|30|x|y|z` (enemy name, damage, where the joiner saw it) goes to the host through the generic message channel as **kind 9**, so the exe needs no change. A floating `-30` appears at the box.
3. *HOST, on receiving it.* The hit is applied to the host's real enemy of that name (the nearest one if there are several), refusing anything that is not a live enemy. The host tries, in this order, until one works:
   1. `DamageController.newFakeDamageInfo(damage, attacker, enemy)` then `addManualDamage(info)`. This is the game's own damage path (both are in your enemy scan), so the enemy should flinch and can die the normal way, as if the host had shot it;
   2. `addHitDamage(info)`;
   3. `getHealthInfo():set_health(health - damage)` (the number only: no flinch, death may not play);
   4. writing the health field directly (the last resort).
4. *Answer.* The host sends back `a|Em2000|how|before|after`. The joiner shows the new health on the red box at once (and keeps it for 0.6 s, so a snapshot that left the host just before the hit landed cannot flick the number back); after that the host's own snapshots are the truth again.

**Safety on the host.** At most **10 hits a second** are applied; damage is clamped to 1..500; a hit on an enemy that is already dead changes nothing; a hit on a parked or placeholder object is refused; a damaged message is ignored; the **joiner never applies a hit to its own game**. A tick box on the host (*HOST: apply the other player's hits to my enemies*) switches the whole thing off and the hit is refused with the reason in the answer.

**Which shot counts: the shot signal.** Nobody knows which field of the gun means "a bullet was fired", so the script learns it instead of guessing:
- Press **Learn the shot signal (then fire three shots)** in the Enemies section. For 15 s it watches the whole-number fields of the weapon components (`app.WeaponGun`, `app.PlayerGun`) and keeps the field that **went down by exactly one, three to six times** (fields that fall by two, fall every frame, or fall only twice are not it; the one closest to three drops wins, and ties go to names that sound like ammo, then alphabetically). It waits 1.5 s after the third drop in case a field keeps counting, so a clock that looks like three shots at first is ruled out. Nothing is hooked, so this cannot crash the game.
- It is remembered in the settings (`shot_signal`), and a damaged entry in the file is ignored.
- Once learned, every drop of 1 to 3 in that field sends a hit. A rise (a reload or picking up ammo) does nothing, and neither does a big fall (swapping weapons). Two drops less than 0.12 s apart are one shot.
- **Until it is learned, the button *Test: hit the red box I am aiming at* does the same as a shot.** Try the whole path with that button first; it does not depend on any guess about the gun.

**The panel** (Insert > RE7 Multiplayer > Enemies (experimental), under the enemy list): the two tick boxes, *Damage per hit* (1 to 300, default 30, saved), the test button, the learn button, `Shot detection:` (what was learned or why not), `Shots tested ... hits sent ... host answered ...`, the last shot in words (for example `shot (test button): hit Em2000 at 5.7 m, sent 30 damage (walls not checked)`), and on the host `received / applied / refused / failed` and what the last hit did (`Em2000: 30 damage by addManualDamage, health 9300 -> 9270`). The host's log also says `enemy hit: ...` for every hit.

**The debug file** has `health.enemy_hits`: both switches, the damage, all the counters, the last text on each side, the last 12 hits the host applied (name, how, before, after), the learned signal and how many shots it saw, what the learner saw (`learner.candidates`: every field that went down by one, and how many times), how many weapon components were found, and the whole-number fields of the first weapon (so if the learner finds nothing, I can see what the gun has).

**What this does not do (yet).**
- The damage is the same fixed number for every shot: no headshots, no difference between the pistol and the shotgun, and the joiner's real bullet still flies on and hits whatever is behind the box. (Use *Damage per hit* to match your weapon.)
- Only the nearest box in line is hit; no spread, no grenades or knife.
- The enemy is identified by its name (`Em2000`). Two enemies with the same name are told apart only by the position that is sent (the nearest to it).
- The joiner's own screen does not play a hit reaction or a death for the red box; it only shows the health going down, and the box disappears when the host's enemy dies.
- If the host's enemy is *not started* (parked), the hit is refused.

**Untested in the real game.** The calls come from your enemy scan (`newFakeDamageInfo(float, GameObject, GameObject)`, `addManualDamage`, `addHitDamage`, `setHealth`, `HealthInfo.set_health`) and have only run against my mock: whether `newFakeDamageInfo` wants the player object as the attacker, and whether the enemy then flinches and dies properly, is what the first real test will show. The host's answer names which of the four ways worked.

**What I need from you next (in this order):**
1. This needs the real thing, with the other player as the host (Loopback's pretend enemies are not objects in anyone's game, so a real host would refuse them: it only tests the sending half). As joiner, aim at a red box and press **Test: hit the red box I am aiming at**. Does `-30` appear, does the box's `HP` go down, does the enemy on the host's screen flinch?
2. Look at the host's panel line `Em####: 30 damage by ...`. Which way worked (`addManualDamage` is the one I hope for)? If it says `failed`, send the debug file (`health.enemy_hits.host_history`).
3. Then press **Learn the shot signal** and fire three shots at anything (the weapon you will use; the three shots should be single shots, not a burst). Does the panel say `learned: ...`? If it says no field went down by exactly one, send the debug file: `health.enemy_hits.learner` and `first_weapon_number_fields` list what the gun has.
4. With the signal learned, shoot a red box for real. Then shoot with a wall in between: nothing should be sent (`behind a wall`).
5. Kill one. Does the host's enemy die with its normal animation, and does the red box disappear on your side? Then send the file.

**Also in your 17:18 message (nothing built yet; send the debug file when you can).** I wrote down what I think is wrong, so the file can confirm it:
- *Guest house animations not working.* Most likely a different chapter means the objects the pose reader found at the start (the player, hands and gun components) are no longer the live ones. Next step: look them up again when the scene changes, and say in the debug file when the reader gave up.
- *Walls hid you from your friend (60 fps against your 180).* Probably the wall test: the layers are chosen once at the start and the physics test switches itself off for good after eight failed calls; a different map or a slower frame rate can leave it wrong. Next step: re-calibrate on a scene change, never give up for good, log what the blocking ray hit, drop layers that hit your own body, and base the "hidden for two tests in a row" rule on time instead of ticks.
- *The tape (derelict house footage) broke both hide functions.* The video screen is likely a full-screen GUI that the menu scan treats as a menu (it is hidden, then visible), and the camera is not the player's eyes, which the wall test uses. Your clue about a name like `imguimask` fits the first: a mask/fade GUI. Next step: skip mask/fade/video/tape names and require a top-level full-screen GUI before it counts as a menu.
- *Enemy executions do not trigger the death sync.* The death sync listens to the game-over state change; an execution probably ends the game on another path (the game-over GUI, a flag, or an event request). Button 8's trace across an execution would show which.

Internal build label is now 9.10; the public release number is **0.7**. Tests: 694 Lua checks (new in this build: the line of fire with slack, behind the camera, dead and parked boxes, the nearer of two boxes, a wall in the way and a box too close for the wall test, the damage slider and its saved value, the switches on both sides, the host applying a hit through each of the four ways, the limits (500, 1, ten a second, a dead target, a parked target, a damaged message, the joiner never applying), the answer reaching the red box and not being flicked back by an older snapshot, and the shot-signal learner with a clock, a field that falls by two, one that falls only twice and a slow clock that keeps counting as decoys, a reload, a pickup, a weapon swap, two drops in one pull, a saved signal, a damaged saved signal, a weapon with nothing to learn and the 15 s time-out) and the C++ suite (unchanged apart from the version number; `all checks passed`). The mutation run now has 80 mutations; 76 make a test fail. The four that do not cannot change what the script does: a failed physics test leaving the stand-in hidden for a single frame (9.9), the joiner-side clamp of the damage number (the slider and the settings file already keep it in range), the shot-signal poll ignoring the joiner switch (the shot itself checks the switch), and the learner not waiting for a clock to prove itself over the first second (the 1.5 s wait does that). Two of this build's tests came from the mutations: a decoy field that would win by its name when the learner counts every drop, and the case of a slow clock that looks like three shots at first.


## What changed in v9.9 (release 0.6; same protocol v6; **rebuild the exe AND update the script**)

Everything here comes from your file `80b0cd26-re7mp_debug.json` and your message: heal was not sent but the loopback worked, you could still shoot when down, and you asked for crouching, for the other player not showing through walls or menus, and mentioned the enemy scan.

**1. Heal (and block) are now sent while you are down.** Your file shows the heal reader worked (it counted heal readings: the hands action was 16/17 while you healed). What went wrong was 9.8's rule "a downed player sends no pose": healing is what gets you up, so it was exactly the heal that was swallowed. The rule is gone; the bits are sent whatever your health is. The loopback bot is never down, which is why it worked.

**2. The weapon lock, rebuilt (EXPERIMENTAL; still writes to the game).** The file settled why 9.8 did nothing: the lock wrote `IsAimAccepted` / `IsAttackAccepted` = `false` 3,566 times and the game put them back `true` 3,560 times. The game recomputes those two flags every frame, after the script's once-a-frame write. So 9.9 closes them at several places in the frame:
- before and after each of the game's update phases (`UpdateHID`, `UpdateBehavior`, `LateUpdateBehavior`, `UpdatePhysics`, `UpdateMotion`, `UpdateGUI`, `BeginRendering`, `EndRendering`), and
- optionally (tick box, on by default) **right after `PlayerSequenceManager`'s own update methods**, with a hook that is only installed the first time you go down. An upright player never has a hook on it and nothing is ever written.
- The debug file (`health.weapon_lock.places`) says for every place how often the gate was found open again, i.e. where the game puts it back. `health.weapon_lock.sequence_manager_methods` and `other_methods` list the methods of the sequence manager and the gun (to find the real shot if the gates are not it). If you can still shoot while down, send the file: that is the one thing I need to see.
- The gates are given back when you are up (not in the middle of a block). Blocking is left alone.

**3. Crouching.**
- *Signal.* I could not know which game field means "crouching", so the script measures it: the camera's height above the player object (`Pl0000`, whose origin is the feet). The standing height is the highest camera height of the last two minutes; **crouching starts when the eyes are 0.22 m below it and ends when they are within 0.12 m** (so head bob and steps are not a crouch). A camera that is not near the player's eyes (0.5 to 2.6 m: a cutscene) never counts.
- *Wire.* Flag bit **256** (`POSE_CROUCH`) in the same flags field; the exe passes it through. Bits 512 and up are still free.
- *Stand-in.* Their eyes sit 0.5 m lower, the hips drop, the knees bend, the torso leans forward, the arms hang from the lowered shoulders, and the tag says `[crouching]`. The *Stand-in pose preview* menu has *Crouch*, and the cycle is now block, heal, crouch, stand.
- *Debug file.* `health.crouch.game_fields` lists every field of the player's components whose name hints at crouching or a stance, with how often it agreed with the camera-height crouch (as a percentage). A field near 100 % is the game's own flag, and the next build can use it instead of the height. `health.poses` has the hands/gun action ids that were seen and how many packets carried each pose bit.
- *Loopback bot.* The 16 s loop is now: block 3.5 s, rest, **crouch 4.5 s to 7.5 s into the loop**, rest, heal from 8.5 s for 3.6 s, rest. It starts 4 s after the exe starts, as before.

**4. Not seeing the other player through walls or menus.** The stand-in is an overlay drawn on top of the game, which is why it showed through walls and the GUI. Two checks, both with a tick box and both falling back to "draw as before" when they cannot work:
- **Walls and doors (tick box *Hide them behind walls and doors*, on).** Ten times a second the script casts rays from your eyes to four points on their body (eyes, chest, hips, feet) with `via.physics`. They are hidden only after two tests in a row find every ray blocked, so one odd frame does not make them blink. They are never hidden closer than 1.2 m. The collision layers are found automatically at the start: the script casts a ray at the floor on each of the 32 layers (four a tick, so the game does not hitch) and uses the first three that hit it. If the physics calls fail eight times in a row, or no layer finds the floor, the test switches itself off and the panel says why (`walls: unavailable (...)`). The panel's `walls:` line shows `working (collision layers 3, 5)` or the reason. **Untested in the game**: the exact function names and layers are what I could not confirm, and the debug file (`health.occlusion`) has the layers tried, the rays cast and the last error.
- **Menus (tick box *Hide them while a game menu is open (EXPERIMENTAL)*, on).** While the other player is in view the script lists the game's GUI objects every 5 to 20 s and checks six of them per frame, round and round; one counts as a menu only if it has been seen both hidden and visible (so an always-on HUD or logo is not a menu), and its name looks like a menu (inventory, pause, map, item box, save, option and the like). While one is open the stand-in is not drawn. I do not know the names your game's menus really use, so this is a guess; `health.menus` in the debug file lists the GUIs it considered and which one hid them. If the stand-in still shows over the inventory or the pause screen, send the file and I will add the real name.

**5. Enemy data.** Your scan listed `get_health()` and `get_maxHealth()` on the base `app.DamageController`, plus `app.HealthInfo.get_health` / `set_health` and the fields `Health` / `MaxHealth`.
- If the health object (`HealthInfo`) cannot be found on an enemy, the script now falls back to `DamageController.get_health()`. The log line says which was used (`health of Em2000 is read from ...get_health()`).
- An enemy that has no health object yet when first seen (not started) is looked at again up to **6 times, 3 s apart**, and the success is logged when it comes. Before this it was given up on at once and stayed at -1.
- **A real inefficiency found while testing this:** the host rebuilds its list of enemies every second, and the health search (listing every component and every field of each enemy) was being run again for every enemy every time. What was learned about an enemy is now carried to the next scan (matched by the object's address) and thrown away after three failed reads, so a respawned enemy at the same address is looked at again. Fewer calls into the game, the same numbers.

**What I need from you next:**
1. Loopback: watch the bot **block, crouch and heal** (the first block about 4 s after the exe starts). Tell me how the crouch looks (how low, the lean).
2. Stand so a wall or door is between you and the bot, and look at the panel's `walls:` line. If it says `working`, do they disappear behind the wall and come back? If it says `unavailable`, send the file.
3. Go down **with a gun** and try to shoot, then send `re7mp_debug.json` (`health.weapon_lock.places`).
4. Crouch yourself for a few seconds, then send the file (`health.crouch.game_fields` and your own `Poses:` line, which should say `CROUCH`).
5. Open the inventory and the pause menu while the other player (or the bot) is on screen: do they vanish? If not, the file's `health.menus` has what I need.
6. Heal while down: the other player's stand-in should now heal too.

Internal build label is now 9.9; the public release number stays 0.6. Tests: 613 Lua checks (new: heal while down, the lock at several places and the hook, crouch from camera height with hysteresis, the stand-in's crouch pose, the walls with a fake physics system, menus, the enemy health fallback, retry and carry-over) and the C++ suite (new: the bot's crouch). Every new behaviour was checked to fail when its code is removed (50 mutations on the Lua side, 49 of them make a test fail; the 50th, a failed physics test leaving the stand-in hidden for a single frame, cannot be told apart from the intended behaviour, because the very next tick shows them again). Four of the first run's gaps were closed by stronger tests: a 0.10 m camera dip must never show as a crouch even for one frame, the lock must not touch the gate after a revive even before the next frame tidies up, and a respawned enemy at the same address must be looked at again. The C++ suite passes (`all checks passed`), including the bot's crouch window.

## What changed in v9.8 (release 0.6; same protocol v6; **rebuild the exe AND update the script**)

Your file `81de51cd-re7mp_debug.json` had two guided recordings (no gun, then with a gun) and a trace of the garage fight to the main hall. Everything below comes from it.

**1. The block and heal poses now follow the real signals.** I read both recordings; these held in all four blocks and both heals, with and without a gun:

| What | Real signal | Values seen |
|---|---|---|
| **Block** | `app.PlayerSequenceManager.IsGuardCancelAccepted` | `false` at rest, `true` from the start of the raise until the lowering starts. It does not move while healing. Same with and without a gun. |
| Block (fallbacks if that field can't be read) | `app.PlayerHands.<actionID>k__BackingField` 35 (raise), 36 (hold), 37 (lower), idle 34; with a gun `app.PlayerGun.<actionID>k__BackingField` 107 (raise), 108 (hold), 109 (lower) | |
| **Heal** | `app.PlayerHands.<actionID>k__BackingField` = 16 then 17 for the whole animation (about 3.6 s) | idle is 34 without a gun and 0 with one. With a gun the gun lowers first (about 3 s), then 16/17, then it comes back up. |

- The block bit is sent while the guard flag is on; the heal bit while the hands action is 16 or 17 (plus a 0.5 s tail so it doesn't flicker). Twenty plain field reads a second, nothing hooked, nothing written.
- **`Inventory.reduceItem` fires at the END of the heal animation** (health rises right after), so it is no trigger for the pose. It is still the trigger for the heal event (revive, "healed +500"). The 9.7 version showed the pose after the item was gone: fixed.
- A downed player sends no pose. (**Wrong; fixed in 9.9**: healing is what gets you up, so the heal was swallowed.)
- The recorder's old pick, `isBothHands`, is true while blocking **and** while healing, so it is not a block signal. 9.7 switched it on by itself. In 9.8 the recorder ranks any field that also fires while healing last ("[also does this while healing: not a block signal]"), never switches a learned signal on by itself, and **a settings file from 9.7 that had it on starts with it off** (the panel checkbox is still there as an optional extra).
- The recorder's report now checks the built-in signals against what you did ("BUILT-IN BLOCK SIGNAL ... WORKS" or "CHECK THIS"), gives the heal animation's start and end, and names the item (9.7 said "no healing item was used" because the heal code had already consumed it). The guided heal step ends 6 s after the last sign of the heal instead of 8 s after the item.

**2. The loopback bot blocks and heals too.** `re7mp.exe` (C++): in loopback mode the bot runs a 16 s loop - block for 3.5 s, walk, heal for 3.6 s, walk - starting 4 s after the exe starts, in both orbit and stationary mode. Run the exe in *Loopback test* mode, look at the bot, and its stand-in blocks and heals with no second player. (`Config::bot_pose_first_s`; a negative value turns it off.) Pose bits are 64 and 128 as before; the exe still passes flags through untouched.

**3. A downed player can't use a held weapon (EXPERIMENTAL; this one WRITES to the game). (9.9: your file showed the game undoing this write every frame; see v9.9 for the rebuild.)** From the recordings, `app.PlayerSequenceManager.IsAimAccepted` and `IsAttackAccepted` are `true` normally and the game itself sets them `false` while you block. While you are down (death mode 4, and only then) the script writes both to `false` every frame (from the frame loop, so there may be a short gap if the game rewrites them later in the same frame), and sets them back to `true` when you are up (not in the middle of a block, where the game restores them when the block ends). Blocking is left alone.
- **Untested in the game.** What I don't know: whether the game rewrites those two flags every frame (the panel counts how often it did), whether a gun that is already raised keeps its aim animation, and whether closing them stops the shot itself. The panel shows `weapon lock: HOLDING ... (N writes, game wrote it back M times, K failed writes)`; the same numbers are in the debug file under `health.weapon_lock`. If a downed player can still shoot, send the file.
- Tick box *A downed player can't aim or shoot until revived* (on by default) turns it off. Without `app.PlayerSequenceManager` on the player the panel says the weapon is NOT locked and nothing is written. If the game ever does something odd after a revive (can't aim), untick the box and tell me.

**4. Your trace of the garage fight to the main hall answers the event/door questions** (details and plan in "Plan: cutscenes and game events" below): cutscenes are started by `app.GameManager.requestEvent("c03e03_00", ...)` with a readable id; interaction events by `app.InteractEventAction.startInteract("InteractAction_PlayerGetInto", ...)`; doors by `app.InteractObjectBase.successInteract()` then `app.DoorPush.setInteract(Pl0000, ...)` and `playAutoOpen` / `playLittleOpen` / `playOpened` on the door's object; the loading door by `app.GameFlowActiveControl.requestChapterJump()`. The file runs from the fight to the main hall door with no crash that I can see in it. **Nothing is synced yet**; this build only records the finding.

**What I need from you next:**
1. Loopback bot: watch the stand-in block and heal (about 4 s after the exe starts, then every 16 s). Tell me what looks wrong in the poses (arm height, hand placement, timing).
2. In the game with a second player (or the loopback bot): go down in death mode 4 **with a gun in your hand** and try to aim and shoot. Then send `re7mp_debug.json`: `health.weapon_lock` tells me whether the game fights the lock.
3. Same two people, normal play: block and heal in front of the other player and check their stand-in follows you (the panel's *Poses:* line shows what you are sending).
4. Door sync is next. To choose the first door I need: one trace where **two players** stand near a normal door and one opens it (to see the order), and a note of whether the door the loading screen follows (the main hall doors) should be held back until both players are there (my plan: yes).

Internal build label is now 9.8; the public release number stays 0.6. Tests: 536 Lua checks and the C++ suite (new: the bot pose schedule and a live check that the bot's flags carry the bits, and that they never clash with the ready-check bits). Every new behaviour was checked to fail when its code is removed (26 mutations on the Lua side, including the `and/or` slip that made `false` read as "unreadable", the lock writing the wrong value, never giving the gates back, releasing in the middle of a block, and a downed player showing a pose); one C++ check, the exact 16 s schedule, is a plain value test.

## What changed in v9.7 (release 0.6; same protocol v6; **rebuild the exe AND update the script**)

You asked what I need next for the block and heal animations of the stand-in body, and said you play TCP only (Tailscale) and want every later feature on TCP.

**1. UDP is gone.** `src/udp_transport.cpp`, the UDP radio button, the CLI's UDP option and the UDP branches in `engine.cpp` are deleted, and the tests now run on TCP only (the C++ suite passes).
The connection choices are **TCP: I host** and **TCP: I join**; an old `re7mp.ini` that says `udp` opens as *I host*. Nothing in the protocol changed (still v6), so the exe and the script still agree with each other.
Over Tailscale / ZeroTier / Radmin you need no port forwarding: the host listens on the port, the other player joins the host's VPN address and port. If UDP is ever needed again it can be put back as a transport (`transport.hpp` is still the interface).

**2. The stand-in can block and heal.** Two new bits ride along in the flags field of every position packet (64 = blocking, 128 = healing). They sit above the ready-check bits and the exe passes the flags through unchanged, so there is no new protocol.
- *Healing*: (9.7 used the item-use signal for 2.4 s; **9.8 replaced this with the real animation, see v9.8**). The other player's stand-in lays the left forearm across the chest and brings a small green item to it with a pressing motion, and its tag says `[healing]`.
- *Blocking* is shown as both forearms up in front of the face, and its tag says `[blocking]`. (9.7: what tells the script you are blocking was not known; **9.8 found it, see v9.8**).
- The legs settle to a standing stance during a pose, and the pose eases in and out (about a tenth of a second). If the other player's packets stop for 2 s the pose fades instead of freezing.
- **Panel: *Stand-in pose preview*** (Off / Block / Heal / Block-heal-stand cycle) shows each pose on the stand-in whatever the other player does, so you can judge the shapes alone with the loopback bot. The panel also says what you are sending and how far into each pose their stand-in is.
- These are placeholders for animation, drawn with the same boxes as the walking body. They get replaced when a real model (Ethan, Zoe, Mia) can be driven.

**3. Button 11, "Record my player": no hooks at all.** The block and heal traces (buttons 8 and 9) hook game methods, and a hook is what the door trace crashed on. Button 11 only *reads*: ten times a second it reads the plain fields (numbers, flags, enums, text) of the player's `app.Player*` components and of the objects they hold (one level down), and a few values of the animation layers (frame, motion id, bank id, node/state numbers), and writes down each change. The guided script:
1. Press **11. Record my player, guided**, close the menu (Insert), and follow the prompts on screen: *stand still* (everything that changes by itself in these 4 s is noise and is muted from then on), *hold block*, *let go*, *hold block again*, *let go*, *use a Herb / Chem Fluid*, wait for the animation to end (F6 = done), *stand still*.
2. At the end the log has a **report**: the **block candidates** (fields that switched on in both holds, back off after, and stayed quiet while you stood still; flags first), and for the heal every field that changed after the item was used with the times, marking the ones that went away again (the animation) and the animation ids.
3. (9.7 switched the best candidate on by itself; **9.8 does not**: the built-in signal is used, and the best candidate is kept only as an optional extra with a checkbox and a Forget button.)
*Free mode* is for anything else: press F6 each time you start something and the log gets numbered marks between the changes.
Safety: it installs no hooks; the animation values are the only calls into the game, limited to getters with no arguments and a plain return type whose name looks like motion / frame / node / bank / state / speed (never ones with owner, component, transform ...), and a breadcrumb is written before the first call of each (and before the first read of each object), so if the game ever stops, the next start says where (`re7mp_lastcall.json`, shown under button 9 and in the debug file). It samples about 10 times a second, caps itself at 1,600 values and 900 listed changes, and reads nothing unless you pressed the button (or switched the learned block signal on, which reads that one field ten times a second).

**What I need from you next:**
1. In the game: **button 11, guided**, then send `re7mp_debug.json`. If you can, run it twice (once standing, once with a gun held), and tell me which button you hold to block.
2. Look at the **pose preview** (Block, Heal) with the loopback bot and tell me what looks wrong (arm positions, timing). The shapes are easy to change.
3. Optional, still wanted from 9.6: button 9 with one `9+` option ticked at a time (and the `re7mp_lastcall.json` message if the game stops), and the Load screen scan (button 10) with *Share saves* ticked and the Save folder ending in your own account number.

Internal build label is now 9.7; the public release number stays 0.6. Tests: 488 Lua checks (the new ones: pose bits out and in, label and geometry per pose, fade on no signal, the preview, the guided recording end to end against a fake player with noise, a latch and a flag inside a held object, the getter allow-list, the saved signal and a damaged one, F6, free mode, the no-player case, the crash breadcrumb) and the C++ suite on TCP only. Each new behaviour was checked to fail when its code is removed (13 mutations; one check, "a candidate must return to its start", is implied by the one before it and is not separately tested).

## What changed in v9.6 (release 0.6; same protocol v6; **rebuild the exe AND update the script**)

Two things in your last file (`ea9ceace-re7mp_debug.json`) and one thing I found by looking at your Steam save folder.

**1. RE7's save files are not called what the exe thought.** I looked at your `...\userdata\<id>\418370\remote\win64_save` folders:

| File | What it is |
|---|---|
| `data000.bin` | the **Autosave** (the Load screen's "Autosave" row) |
| `data001Slot.bin`, `data002Slot.bin` ... `data011Slot.bin` | **manual saves**; the Load screen row numbered N is `dataNNNSlot.bin` (file times match the rows to within 2 s) |
| `data00-1.bin`, `data00-3.bin` ... | system / settings files |

The exe only recognised `dataNNN.bin`, so it had only ever seen the Autosave: that is why every scan showed `save files ... 0` (`occupied=[0]`) and why sharing a save could not have worked. Fixed:

- The exe now watches and writes `dataNNNSlot.bin` (slots 1 to 99). **The Autosave and the system files are never read, shared or overwritten.** A received save goes into the same slot number if it is free, otherwise the lowest free manual slot (1 upward).
- It still never overwrites one of your own single-player saves. Nothing of yours was touched by the old version either (the Autosave file time equals the Autosave row's time).
- The Load-screen question from 9.5 is settled: row N is `dataNNNSlot.bin`, so the **"Save numbering" box is gone** and the labeler no longer guesses. An old `label_numbering` in your settings file is ignored.
- `re7mp_coop_saves.json` now also carries `dir`, the folder the exe is watching.

**You have two Steam accounts on that PC** (`759758082`, the one you play on, saves 1 to 11, and `1055164497`, old saves 1 to 9, 13 and 14). The exe's *Detect* picks the folder with the newest file, which may not be the one the game uses.
The script now checks: before it writes a label it asks the game which slots exist (`SaveDataManager.isExistData(n)`, true for 0 = Autosave and 1 to 11 on your account) and compares that with the exe's list.
If they disagree by more than one slot it writes nothing and the panel says, for example, *"The game has saves in slots 1-11 but re7mp.exe is watching a folder with slots 1-9, 13-14 (Steam account 1055164497) ... set 'Save folder' in re7mp.exe"*.
If the game can't be asked, it labels anyway and says the check was skipped. **Check the Save folder box in re7mp.exe ends in your own account number before relying on sharing.**

**2. The game crashed while tracing a door closing.** Button 9 in 9.5 hooked 77 `DoorPush`, 15 `InteractObjectBase`, 13 `GameManager` and 75 `SaveDataManager` methods at once, and the game stopped about five seconds later as a door closed.
**I can't tell which hook did it from the file**: the debug file is only written every two seconds, so its last line (`playAutoClose`, then `callSE(8)`) is up to two seconds before the crash. What I did instead of guessing:

- **Button 9 is back to the 22 event classes that never crashed (9.4).** The door, story-flag and save classes are three options under it, **off by default and hand-picked** (`9+ also trace ...`). Tick **one**, press 9, and tell me whether the game survived.
  - *Doors*: `setInteract`, `playAutoOpen`, `playLittleOpen`, `playOpened`, `playAutoClose`, `playClosed`, `closeDoorCore`, `lockDoor`, `lockDoorCore` (+ `unlockDoor`, `openDoor`, `closeDoor` if they exist) and `InteractObjectBase.successInteract`.
  - *Story flags*: the `GameManager` setters, chapter jumps and `requestEvent`. *Saves*: `saveFileGameSaveData`, `loadFileAutoRequest` and two likely siblings.
- **A crash breadcrumb.** `reframework\data\re7mp_lastcall.json` is rewritten around every traced call (and before every hook is installed). The next time the script starts it reads it back, writes a line in the debug file and shows it under button 9:
  *"The last session ended while the trace was reading the arguments of app.DoorPush.X ... If the game crashed, that call is the suspect"* (or *installing its hook on ...*, or *... had finished*, which means the game itself or a call that isn't traced).
  If the game did not crash, ignore the line (a normal script reset writes "clean" and says nothing).
- **Never touched any more:** methods that fire hundreds to thousands of times a second (`set_timelineKickers` 13066/s, `waitFsmExecuteCheck` 3219/s, `isMotionJack` 1250/s, `existNear` 588/s, `notifyInKnockArea` 355/s), and methods that run while an object is being taken apart (`doOnDestroy`, `finalize`, `dispose`; `releaseComponents`/`gatherComponents` are simply not on the door list).
- **Object arguments past the registers are never opened.** A hook only sees the first two parameters in registers; later ones read as garbage (that was the `1962800054277` where an EaseType should be). The old code still treated a late *object* argument as a pointer and called into it, which can crash the game. Now it prints `<System.String: not readable>`, and late numbers/flags carry a `?`.
- `setFsmGlobalBoolValue` / `setFsmGlobalIntValue` are logged only when their arguments change (the UI flags `CanOpenMap`, `CanChangeWeapon`, `CanOpenInventory` are set 537 times a second).

**What the file did show about doors** (all from 9.5, before the crash): opening a door runs `InteractObjectBase.successInteract` on `InteractDoor_*`, then `DoorPush.setInteract(Pl0000, true, false)`, then `playLittleOpen` or `playAutoOpen(side)`, `playOpened`,
and closing runs `playAutoClose` (then `closeDoorCore` / `playClosed` / `lockDoor` when an area unloads). `GameManager.setFsmGlobalBoolValue` only showed UI permission flags in those five seconds. `SaveDataManager` was never called.

**3. UDP (a question; answered in 9.7: it was removed).** UDP was still there in 9.6. It is the default transport, the loopback bot's transport, and the only mode where neither player has to forward a port (both sides send to each other's address and port at the same time).
Enemy sync and save sharing are already TCP-only. Removing it deletes `src/udp_transport.cpp`, the radio button, about 16 branches in `engine.cpp`, the CLI option and its tests, but it also removes the no-port-forwarding route (players would use TCP with a forwarded port or a VPN such as Tailscale / ZeroTier / Radmin) and changes the default.
The natural moment is the protocol bump for 2.0, after one release that marks it "legacy".

Internal build label is now 9.6; the public release number stays 0.6. Tests: 393 Lua checks and the C++ suite (the save-file names, the Autosave being left alone, the wrong-account check, the breadcrumb, the opt-in trace, the unreadable-argument guard; each new test was checked to fail when its fix is removed).

## What changed in v9.5 (release 0.6; same protocol v6; Lua only, update the script)

Your debug file (`764d7c5f-re7mp_debug.json`) answered most of the open questions about the Load screen. It also showed what the first event trace was missing.
**Lua only; the exe is unchanged. Nothing here has been tried in the game yet.**

**What the file showed**

- **The Load screen is `SystemObject/MenuManager/SaveMenuGUI` (component `app.SaveMenu`).** Its list is `c_saveslot > c_itemscroll` (a `ScrollList`) with nine
  `SelectItem` rows (`item8` ... `item1` and `selectitem`). Every row has `m_objective` ("Get 3 dog heads and open the door to the yard"), `m_time`, `m_difficulty`,
  `m_place`, `m_chapter`, `m_day` and **`m_number`**, which is the slot number the game prints: `"1"` ... `"8"`, and `"Autosave"` on `selectitem`.
- **Why the 9.4 scan said "no list of identical rows found":** the matcher compared the rows' own names (`item1`, `item2` ...), so no two rows looked alike. Fixed.
- **The list is recycled.** One scan (early in the session) showed the rows holding slots 3 to 11, a later one slots 1 to 8 and Autosave: the game re-uses nine row
  controls for all your saves and rewrites them as you scroll. So rows can't be matched to files by position or count (9.4's approach); only by the number on the row.
- **The scan said 0 save files**, so `re7mp.exe` was not listing the folder when you ran it (Share saves off or no save folder set). The labeler needs that list.
- **No real door calls are in the file.** The trace did not watch `app.DoorPush`, the class the game's own save data uses for doors (`DoorPushSaveDataDicList`). The 8
  `DoorEventAction` objects in the scene are monsters' doors (`/Em8000/DoorAction` ...) and never fired. What did fire: `InteractEventAction.gatherEventSettings` on the phone,
  a ladder and `NarrowArea` as you walked up to them, a burst of `GameEventSetting.doStart` / `TimeLineKicker.start` when a save loaded, then `FadeControl` fade out/in and
  `ChapterLoadTempManager.releaseChapter1Folder/3Folder` (the chapter swap).
- **Hooks that cost frames for nothing:** `GameEventController.set_eventSetting/set_eventRoot` fire about 16,000 times a second and `ItemManager.findItemDataInternal` 284 times a second. They are no longer hooked.
- **Item data:** item ids are plain names (`HandgunBullet`, `RemedyM`, `Knife`, `BurnerBullet`, `EyeDrops`, `RemedyL`). Picking up bullets calls `applyDifficultyItemNumRate("HandgunBullet", 5)`,
  which scales the count by difficulty (worth remembering for item sync).
- **Game data worth knowing:** `GameManager` has the game's own story-flag setters (`setFsmGlobalBoolValue(String, Boolean)`, `setFsmGlobalIntValue`, `addFsmGlobalIntValue`, and Guid versions),
  `chapterJumpRequest(String, Boolean, String)` and `requestEvent(String, Transform, ...)` (starts a cutscene by name). Those are the natural hooks for syncing story progress and cutscenes,
  and the next trace watches the setters. `SaveDataManager` has `saveFileGameSaveData(app.SaveData, Int32, SaveFileDetail)`, `loadFileAutoRequest(Int32, ...)` and `isExistData(Int32)`: the slot number is a plain integer there.

**What 9.5 does**

- **The Load labeler is rewritten for that layout.** It finds the nine rows, reads each row's `m_number`, and puts `[CO-OP: Bob]` in front of `m_objective` of the rows whose slot is a co-op save.
  The `Autosave` row is never labelled. Because the game rewrites rows as you scroll, the labels are checked ten times a second and put back (and removed from a recycled row that now shows a
  single-player save). A menu that is not showing is not walked, and the GUI is looked up once, not every second.
- *(Settled in 9.6: row N is `dataNNNSlot.bin`; the numbering box was removed.)* **One thing is still a guess: is row "3" the file `data003.bin` or `data002.bin`?** The labeler works it out from your files when only one numbering fits every visible row, says when it had to assume
  `row N is dataN`, and writes nothing when neither fits. If the labels land on the wrong saves, change *Save numbering* in the panel (this replaces the old *Reverse the order* box).
  Button 10 now prints, for every row, the number, the file it maps to and whether that is a co-op save, plus `isExistData(n)` for n = 0 to 40, so the next file settles it.
- *(Changed in 9.6: these classes are now opt-in and hand-picked, because this version crashed the game.)* **Button 9 (event trace) now watches** `app.DoorPush` (every call), `app.InteractObjectBase` (open/close/push/lock/interact/execute), the story-flag setters and chapter-jump / requestEvent calls on `GameManager`,
  and the `saveFile*` / `loadFile*` calls of `SaveDataManager`. To capture a door: press 9, open and close two doors, take a key item, then send the file.
- **Downed mode: two fixes from the same file.** (1) After the other player dies while you are down (team wipe) the script kills you; the health hold used to write 1 back about ten times a second for six
  seconds against that. It now lets go for 20 s. (2) A rise of 1 health is no longer reported as "your health rose by 1 (no healing item was used)" (65 lines of that in the file).
- Internal build label is now 9.5; the public release number stays 0.6.

**What I need next:** run button 10 again on the Load Game screen **with re7mp.exe running and Share saves ticked** (so the file list is not empty), and a trace (button 9) with two doors opened and closed.

## What changed in v9.4 (release 0.6; same protocol v6; rebuild the exe AND update the script)

You asked for every co-op save to be clearly labelled in the game's Load menu, in front of the objective text ("Collect the three dog heads"),
on both PCs, with the name of the player it was last shared with.

- **Both sides now know which saves are co-op.** Before, only the saves you *received* were recorded. Now the saves you made while connected and
  sent are recorded too, each with the other player's name (`partner`, updated each time the slot is shared again). A save you made yourself is never replaced by an
  incoming one. A slot you later save over while nobody is connected, or delete in the game's menu, stops being marked.
  `re7mp_coop_saves.json` now has `partner`, `role` (`sent`/`received`) and `tag` (`[CO-OP: Bob]`) per save, plus `occupied`, the slot numbers that have a save file.
- **Load menu labels (experimental, off by default).** Tick *Label co-op saves in the Load screen* in the *Co-op saves* panel. The script looks for the Load list
  (a GUI named like save/load/slot), finds the list of identical rows, and puts `[CO-OP: Bob]` in front of the longest text of each co-op row.
  *(Superseded by v9.5 above: this first version guessed the screen's shape, matched rows to files by count and order, and never found the list on the real screen.)*
- **Button 10, Load screen scan** (open the Load Game screen, then press): records every GUI, the controls and texts of the one that looks like the Load screen, the list it
  found, which of a few candidate types exist (with their methods and fields), and your save files and co-op slots. If the labels don't appear, send me that file and I'll
  write the exact version.
- **Updates and REFramework in re7mp.exe** (exe only, no protocol change): the window checks your GitHub releases and has an *Install REFramework* button. See
  "Updating, and installing REFramework" below.
- Internal build label is now 9.4; the public release number stays 0.6.

## What changed in v9.3 (Lua only; same protocol v6, both players should update the script)

You confirmed giving items works (Knife, RemedyM, HandgunBullet, ShotgunBullet to the bot). This version starts on health, the downed
idea and cutscene/event sync. **Everything new here is untested in the real game**; each part says how it will tell you if a guess was wrong.

- **Player health.** The script finds your health (an `app.HealthInfo` on the player's DamageController, the same class the enemies use),
  sends it to the other player and shows `HP 65%` over their head and in the panel (*Health and downed*). The panel and the debug file say where
  it was read from, or that nothing was found.
- **Heal events.** A heal is a rise in health. When it follows a Herb / Chem Fluid / Remedy being used (a hook on `Inventory.reduceItem`),
  the other player is told `<name> used a Herb`. Blocking is not synced yet: I don't know which call the game makes when you guard. Button 8 finds out.
- **Downed and revive (death mode 4, experimental).** A hit that would kill you leaves you at 1 health, "down" where you fell; you can't heal
  yourself; the other player gets you up by using a Herb / Chem Fluid / Remedy within 3 m (or pressing **F8** and staying put for 3 s, which costs no item: the wait is the cost).
  You get up **where you are** with 30% health: because the game never saw you die, it never reloads a checkpoint. Details and limits below.
- **Button 8** (player details and trace) and **button 9** (cutscene / event trace and dump): the data for block/guard, the player's death path and for syncing cutscenes and game events (plan below).
- **Receive tests.** The loopback bot never gives anything back, so the receiving half of Give/Drop could not be tried alone. *Items: give and drop* now has three
  "Test:" buttons that run the real receive code on yourself.
- **Inventory screen not redrawing after a give:** button 7 now also lists the refresh-like methods of `app.InventoryMenu`, `app.InventorySystem` and `app.InventoryManager`, so I can find the call that redraws it.
- The debug file now has a `health` summary at the top.

## What changed in v9.2 (Lua only; same protocol v6)

- **Item names.** v9.1 could see the pointed-at item but not read its name, so Give and the inventory list did nothing. The script now tries, in order: the id getters as text, an id getter that returns an object with a text field, text fields on the item, the item's save data, and the GameObject's name; and the inventory list also accepts a name or count carried by the list entry itself. The panel says which attempt returned what, and if nothing works the full diagnostics are written to `re7mp_debug.json` **by themselves** (no button needed).
- **Tracer:** every traced call now says which GameObject it was on (`[on Em3100]`), so a damage call says whom it hit.
- The script was at Lua's limit of 200 local variables in one chunk; groups of constants moved into tables/blocks. If a future edit hits "too many local variables" the script will not load at all, so tests run it.

## What changed in v9.1 (Lua only; same protocol v6, so the exe from v9 still works, but both players should update the script)

- **Stray enemy box fixed:** parked and placeholder `Em####` objects (Em8000, Em6190, Em3300 in your dump) are no longer drawn or moved. Tick *Also draw parked / placeholder objects in grey* to see what they are.
- **Health:** read from the `HealthInfo` object inside the enemy's DamageController (the Status components have no HP field). Dead enemies disappear.
- **Items:** the panel now lists your inventory with **Give 1 / Give all** buttons per item, so giving no longer depends on the cursor hook that never fired in your test. Button 7 works even when nothing is pointed at and dumps the inventory list.
- **Damage trace (button 6):** finds each live enemy's own damage and health types and prints damage records with their numbers.
- **Other player's hide distance:** default 0.4 m (was 0.8 m), with a slider in the panel; remembered.

## Updating, and installing REFramework (re7mp.exe)

Two new rows at the bottom of the window, **Updates** and **REFramework**.

**Updates.**
- When re7mp.exe opens it asks GitHub (`api.github.com`, over HTTPS) for the newest release of `kingkiller1195/re7mp`. If it is newer than the exe you are running, the
  button changes to *Update to v0.7*; click it, read what's new, say Yes, and re7mp.exe downloads the new version, swaps itself (the old file stays as `re7mp.exe.old` until the
  next start), and restarts with your settings. Press Start afterwards: it installs the Lua script that came inside the new exe. The check can be switched off with the
  checkbox; *Check now* does it by hand. The only thing sent is an ordinary web request (GitHub sees your IP address) with the user agent `re7mp/0.7`.
- **How a release has to look.** The version is read from the release **title** (`v0.5`), because your tags are `beta5` and so on; a tag is only used if it looks like a
  version (`v0.6`). Attach **`re7mp.exe`** to the release (or a zip that contains it). If the release has no exe, the update stops with a message pointing at the releases page. GitHub's
  automatic "Source code" archives are not used.
- **Your internal/debug builds stay private.** Only published releases are offered, never drafts, and never releases marked *pre-release*. Playtesters you give builds to can
  see pre-releases too by adding `include_prerelease=1` under `[re7mp]` in `re7mp.ini` (next to the exe); it is not in the window, so normal players don't see it. A
  build with a newer number than the newest release (an internal 0.7 before 0.7 is published) is never "updated" back.
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
5. Optional: **Share saves (TCP)**: tick it and check the **Save folder** (it is detected from Steam:
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
look including up/down, and a walk cycle driven by their speed). The old line skeleton is still there as a **debug
skeleton** (checkboxes in the panel).

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

## Items: give and drop (giving confirmed in the game; receiving and drop-on-discard not yet; see v9.14 for the latest fixes)

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
  and again when the synced start happens. The panel shows the countdown and a "Show them now" button; the option
  can be switched off.
- **Too close:** the body is also not drawn while it is closer than a set distance to your camera. The default is
  **0.4 m** (it was 0.8 m before v9.1), and there is a slider, "Hide them when closer than (m)", at the top of the panel;
  the value you pick is remembered (`hide_near` in `re7mp_settings.json`).
- **Game menus (9.9, reworked in 9.11):** not drawn over the inventory, pause, map, save, tape player and similar screens; a GUI with a name like `MapMaskGUI` is not a menu, and one that stays "open" while you walk is dropped (see "What changed in v9.11"). Tick box in the panel.
- **Walls and doors (9.9, rebuilt in 9.11):** not drawn while a solid wall is between you (a ray test from your camera to four points of their body). The panel line `walls:` says `working`, `unavailable` or `switched off`. Tick box in the panel.
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

- **Independent (nothing happens)**: the default.
- **Shared fate: both players die**: when one player dies, the other dies too. This is what is built.
- **Downed and revive (experimental)**: see "Health, downed and revive" below.
- "Dead player waits for the other" is in the list but not built; it acts like Independent.

How it works, and what is a guess: the script reads the `app.GameManager.GameMode` enum and picks the member whose name
contains *gameover*, *game_over*, *dead* or *death*. When the game switches to that mode the player has died, and the
other player's game is put into the same mode with `setGamemode`. Both halves rest on that guess: the enum may have no
such member (the panel then says so and lists nothing to trigger), or setting the mode may not run the normal death
sequence. The default is Independent so a wrong guess can't kill anyone by surprise. The panel has two test buttons
(send a death message; pretend the other player died, which can kill *you*). Every `setGamemode` call is also logged by
name, so one real death will show the actual mode names. Step 4 in "Send me this" logs everything `app.GameManager` does
while you die.

## Health, downed and revive (v9.3, experimental)

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

## Plan: cutscenes and game events (nothing synced yet; the tracing has now answered the first questions)

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

Tick **Share saves (TCP)** in `re7mp.exe`. The Save folder box must be the one for **the Steam account you play on**
(`...\userdata\<your account number>\418370\remote\win64_save`). Only manual saves (`data001Slot.bin` ... , the Load screen's rows 1, 2, 3 ...) are shared; the Autosave (`data000.bin`) never is. While connected:

1. When one player saves, re7mp.exe notices the new save file once it has sat untouched for a moment (so it never sends
   half a file), and sends it to the other player over TCP, in pieces, with a checksum.
2. The receiver installs it **into a free slot: the same slot number if that is free, otherwise the lowest free
   slot. It never overwrites one of your own single-player saves**; it only ever replaces an earlier co-op save it
   installed itself.
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
and out, malformed ones do nothing, the settings file and debug collectors write what they should (1002 checks as of 9.15, including the Load screen labels against a copy of your real SaveMenuGUI scan (`tests/data/save_menu_scan.txt`), the release number and version check, odd item names and an unreadable inventory entry, your parked-enemy case, the HealthInfo path, the inventory list, the item-name-as-managed-string
case, the hide-distance slider, and for v9.3 the player health read, the health/heal/down/up messages, the lethal-hit hold, no self-heal while down, revive by a
partner's heal or F8 and its distance check, both-down and team-wipe, reload and loading-screen cases, the collectors and the receive self-tests). That
proves the script's own logic. It cannot prove the real game accepts the calls.
I also modelled the new-game ready-check state machine in Python (`tools/lobby_sim.py`, 1,000+ scenarios with packet
loss and lag) and checked the 3D body's face ordering and back-face culling logic in Python.

Reported working in-game (by you): the debug logging, the probe panel, the New Game sync, and giving items (the removal and the message; the game's inventory screen only
redraws when reopened). Item pickup sync, death sync, the host role, save sharing, enemy sync, the receiving half of give/drop, player health, the downed mode and everything in v9.3, v9.4, v9.5 and v9.6 (including the Load menu labels and the new save file names) are untested in the game. The stand-in poses and button 11 (v9.7) were run in the game (the recordings came from them), and so were the real block and heal signals (v9.8: your 15:07 file shows the block was recognised and the loopback poses worked). The heal while down, the rebuilt weapon lock and its hook, the crouch, the wall test, the menu test and the enemy health fallback (v9.9) were played with your 0.6 file as the result: the wall test never got going, the menu test pinned on `MapMaskGUI`, the crouch guess was wrong half the time and the heal bit was sent from the inventory screen; v9.11 is the answer to each of those and, like the joiner's damage to the host's enemies with the shot-signal learner (v9.10), is untested in the game. The same holds for everything in v9.12 (the rebuilt weapon lock with its gun and movement hooks, the position pin, the two-phase gift with the stack fallback, the gun-call shot signal, the co-op save checks, the version-file fix): it passes against my mock, and that is all that is known.

Tested for the updater: version comparison (0.10 > 0.9), reading titles and tags like yours (`beta5` / `v0.5`), choosing the newest release while skipping drafts and pre-releases,
GitHub error and rate-limit answers, refusing non-GitHub links, fetching the exe directly or out of a zip, refusing a file that is not a program, swapping the exe and putting it back on failure,
the unzip (stored, fixed and dynamic Huffman blocks, a damaged entry, truncated and non-zip files, `../` and drive-letter names), and the REFramework install (clean folder, repeat install,
a foreign `dinput8.dll` with and without permission, your own files kept, dll-only, damaged or loader-less zips changing nothing). **Not run for real:** the WinHTTP download (a fake network stands in), the
buttons and rows in the window, and the swap-and-restart on Windows; I also could not see your releases' asset names (the page only said "3 assets"), so the rules above guess `re7mp.exe` or a zip containing it.

Not tested by me: the GUI (only syntax-checked against stand-in headers), the Windows socket code (the TCP code
has Windows branches that I could only read, not run), and, in the real game, the Lua (it only ran against my mock). In the game itself, unverified: `draw.filled_quad` (the body falls back
to outlines if it's missing), the tracer's hooks and argument decoding, the message files through `json.dump_file`,
chat/ping drawing, and everything under Avatar.
