-- Checks of build 10.22 (release 0.11, the hotfix) for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1022_file) with that file's helpers in one table.
--   RE7MP_ONLY_1022=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What the hotfix changed, and what this file checks (all of it AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   V. the version: release 0.11, build 10.22
--   M. the menu: one "Items" tab (the pickups and give / drop in it), no "Doors" tab, "Enemies" without "(experimental)", and no cutscene recorder or spawn log sections
--   G. the cutscene recorder and the spawn log are GONE: no section in the debug file, no hooks, no files, old settings keys and an old crash marker are ignored
--   E. Enemy sync mode 3 (ghosts, and my own enemies moved onto the host's) is the default, remembered under enemy_mode2; the old key enemy_mode is not read
-- (The door switch, the shipped defaults file and the version strings are checked in tools/lua_smoke.lua, next to the older tests they change.)

local H = ...
local check, Obj, make_td, make_go, make_scene, vec = H.check, H.Obj, H.make_td, H.make_go, H.make_scene, H.vec
local new_environment, build_world, load_script, host_role_files = H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, texts_have, log_has, calls_have = H.run_frames, H.run_ui, H.ui_has, H.texts_have, H.log_has, H.calls_have
local messages_of_kind, push_msgs, bump_remote = H.messages_of_kind, H.push_msgs, H.bump_remote

local function live(env, secs)
    for _ = 1, math.floor(secs / 0.05 + 0.5) do
        run_frames(env, 0.05)
        bump_remote(env)
    end
end

local function health(env)
    run_frames(env, 1.2)
    env.ui_press["Clear the debug log"] = true
    run_ui(env)
    run_frames(env, 0.6)
    return env.files["re7mp/debug.json"].health
end

-- a world of the stand-in game; settings (a table) is the player's settings file as it was before the start
local function world(role, settings, setup)
    local env = new_environment()
    build_world(env)
    if setup then setup(env) end
    if settings then env.files["re7mp/settings.json"] = settings end
    load_script(env)
    host_role_files(env, role, "tcp")
    for _ = 1, 30 do
        run_frames(env, 0.05)
        bump_remote(env)
    end
    return env
end

local function node_index(env, label)
    local n, first = 0, nil
    for i, l in ipairs(env.ui_nodes) do
        if l == label then n = n + 1 first = first or i end
    end
    return n, first
end
local function any_node_starting(env, prefix)
    for _, l in ipairs(env.ui_nodes) do
        if l:sub(1, #prefix) == prefix then return l end
    end
    return nil
end
local function text_index(env, prefix)
    for i, t in ipairs(env.ui_texts) do
        if t:sub(1, #prefix) == prefix then return i end
    end
    return nil
end
local function no_ui_errors(env, what)
    local bad
    for _, t in ipairs(env.ui_texts) do if t:find("UI error", 1, true) then bad = t break end end
    check(bad == nil, what .. ": no UI error" .. (bad and (" (" .. bad .. ")") or ""))
end
local function file_names_like(env, pat)
    local out = {}
    for k in pairs(env.files) do if tostring(k):find(pat) then out[#out + 1] = k end end
    table.sort(out)
    return out
end

-- =============================================================================================
-- V. the version
-- =============================================================================================
do
    local env = world("host")
    live(env, 3)
    health(env)
    local d = env.files["re7mp/debug.json"]
    check(d and d.release == "0.11" and d.build == "10.27" and d.script == "re7mp v10.27", "(10.22) the debug file says release 0.11, build 10.22: " .. tostring(d and d.release) .. " / " .. tostring(d and d.build) .. " / " .. tostring(d and d.script))
    run_ui(env)
    check(ui_has(env, "Release v0.11   (script build 10.27"), "(10.22) the panel shows release v0.11 and build 10.23 (the release number did not change)")
    check(node_index(env, "RE7 Multiplayer v0.11") == 1, "(10.22) the top of the panel is titled v0.11")
end

-- =============================================================================================
-- M. the menu
-- =============================================================================================
do
    for _, role in ipairs({ "host", "join" }) do
        local env = world(role)
        run_ui(env)
        local who = "(10.22 menu, " .. role .. ")"
        no_ui_errors(env, who)
        local n_items, i_items = node_index(env, "Items")
        local n_en, i_en = node_index(env, "Enemies")
        check(n_items == 1, who .. " one tab called Items (" .. n_items .. ")")
        check(node_index(env, "Items: sync pickups") == 0 and node_index(env, "Items: give and drop") == 0, who .. " ...and the two old tabs are gone")
        check(n_en == 1 and node_index(env, "Enemies (experimental)") == 0, who .. " the enemies tab is called Enemies, with no '(experimental)'")
        check(i_items and i_en and i_items < i_en, who .. " Items comes where the pickups tab was: before Enemies (" .. tostring(i_items) .. " < " .. tostring(i_en) .. ")")
        check(node_index(env, "Doors (shared with the other player)") == 0 and any_node_starting(env, "Doors") == nil, who .. " no Doors tab")
        check(any_node_starting(env, "Cutscene probe") == nil and any_node_starting(env, "Spawn log") == nil, who .. " no cutscene recorder and no spawn log section")
        -- what is meant to stay in the developer section is still there
        for _, keep in ipairs({ "Developer tools (for the mod's author: you do not need these to play)", "Testing tools (dev build)", "Debug model (the green man), poses and hiding",
                "Animation clips (experiment: record Ethan's joints, play them on the body)", "Real body (experiment: a second Ethan of my own)",
                "Story sync (EXPERIMENTAL)", "Health, downed and revive", "Who I am (character)", "Chat and pings", "Weapons (which one I hold, what it does, friendly fire)",
                "Enemy models (the host's enemies as their real models)", "Other player's body: which model, hair, how close" }) do
            check(node_index(env, keep) == 1, who .. " still there: " .. keep)
        end
        -- both halves are in the one tab, the pickups first
        local ip, ig = text_index(env, "PICKUPS:"), text_index(env, "GIVE AND DROP:")
        check(ip and ig and ip < ig, who .. " the tab holds the pickups part and then the give and drop part (" .. tostring(ip) .. " < " .. tostring(ig) .. ")")
        check(ui_has(env, "Not synced yet: drawer/container items, crafting, ammo use."), who .. " ...the pickups part is drawn to its end")
        check(ui_has(env, "Receive tests (they run the real receive code on yourself, since Ethan's friend can't give):"), who .. " ...and so is the give and drop part")
        for _, box in ipairs({ "Sync item pickups", "Discard drops the item on the ground (the other player sees it too)",
                "Share only consumables and weapons (heals, ammo, throwables, materials, weapons). Key items, files and maps stay in each game" }) do
            check(env.seen_checks and env.seen_checks[box] ~= nil, who .. " the box is drawn: " .. box:sub(1, 60))
        end
        check(env.seen_checks["Share doors with the other player (open, close, unlock and push; remembered)"] == nil, who .. " the box that switched the doors off is not drawn")
    end

    -- the controls of both halves work from the one tab, and are remembered
    local env = world("host")
    env.check_override["Sync item pickups"] = false
    env.check_override["Discard drops the item on the ground (the other player sees it too)"] = false
    run_ui(env)
    live(env, 2.5)
    local sv = env.files["re7mp/settings.json"] or {}
    check(sv.item_sync == false, "(10.22 menu) the pickups box works from the Items tab and is remembered: " .. tostring(sv.item_sync))
    check(sv.drop_on_discard == false, "(10.22 menu) the discard box (the give and drop half) works from the Items tab and is remembered: " .. tostring(sv.drop_on_discard))
    env.check_override["Sync item pickups"] = true
    env.check_override["Discard drops the item on the ground (the other player sees it too)"] = true
    run_ui(env)
    live(env, 2.5)
    sv = env.files["re7mp/settings.json"] or {}
    check(sv.item_sync == true and sv.drop_on_discard == true, "(10.22 menu) ...and ticking them again is remembered too")
    env.ui_press["Refresh the list"] = true
    env.ui_press["Test: receive 1 Herb as if Player 2 gave it"] = true
    run_ui(env)
    no_ui_errors(env, "(10.22 menu) the buttons of the give half")
end

-- =============================================================================================
-- M2. every tree node that was opened is closed once (the real ImGui crashes the game on a TreePop that does not match: the fake one never notices, so it is counted here)
-- =============================================================================================
do
    for _, role in ipairs({ "host", "join" }) do
        for _, open_them in ipairs({ true, false }) do
            local env = world(role)
            local im = env.G.imgui
            local tn, tp = im.tree_node, im.tree_pop
            local depth, lowest, opened = 0, 0, 0
            im.tree_node = function(label)
                tn(label)
                if open_them then depth = depth + 1 opened = opened + 1 end
                return open_them
            end
            im.tree_pop = function()
                depth = depth - 1
                if depth < lowest then lowest = depth end
                return tp()
            end
            run_ui(env)
            run_ui(env)
            local who = "(10.22 tree, " .. role .. ", sections " .. (open_them and "open" or "closed") .. ")"
            check(depth == 0 and lowest == 0, who .. " every node that was opened was closed once, never more (depth " .. depth .. ", lowest " .. lowest .. ", " .. opened .. " opened)")
            if open_them then check(opened > 20, who .. " ...and the sections were really drawn (" .. opened .. " opened in two passes)") end
            no_ui_errors(env, who)
        end
    end
end

-- =============================================================================================
-- G. the cutscene recorder and the spawn log are gone
-- =============================================================================================
do
    -- the script text: nothing of them is left to call
    local fh = io.open(H.SCRIPT, "rb")
    check(fh ~= nil, "(10.22 gone) the script can be read: " .. tostring(H.SCRIPT))
    if fh then
        local text = fh:read("a")
        fh:close()
        check(not text:find("CFG.slog", 1, true) and not text:find("spawnlog", 1, true) and not text:find("spawn_log", 1, true), "(10.22 gone) the script has no spawn log (CFG.slog, spawnlog, spawn_log)")
        check(not text:find("CFG%.cs[%.%s=,)%]]") and not text:find("cutscene_probe", 1, true) and not text:find("cutscene_link", 1, true), "(10.22 gone) the script has no cutscene recorder (CFG.cs, cutscene_probe, cutscene_link)")
        check(not text:find("door_sync", 1, true) or not text:find('d.door_sync', 1, true), "(10.22 gone) the settings loader does not read door_sync")
        check(not text:find("Doors (shared with the other player)", 1, true) and not text:find("Enemies (experimental)", 1, true), "(10.22 gone) neither the Doors tab nor the '(experimental)' enemies tab is in the script")
    end

    -- an old settings file that still has every key of the removed things, and an old crash marker of the spawn log
    local old = { cutscene_probe = true, cutscene_secs = 12, cutscene_link = true, cutscene_stop_loco = false, cutscene_loco_grace = 6,
        spawn_log = true, spawn_focus = "mia;pl2000", door_sync = false, enemy_mode = 1, item_sync = true }
    local env = world("host", old, function(e)
        e.files["re7mp/lastcall.json"] = { stage = "spawnlog", call = "read via.motion.Chain", clock = 1, time = os.time(), session = "an-older-session" }
    end)
    live(env, 12)
    local h = health(env)
    check(h.spawn_log == nil and h.cutscenes == nil, "(10.22 gone) the debug file has no spawn_log and no cutscenes section")
    check(h.doors ~= nil, "(10.22 gone) ...but the doors section stays (the sync is always on, and its report is how a door is looked into)")
    check(env.hooks["app.GameManager.requestEvent"] == nil, "(10.22 gone) an old 'cutscene_probe = true' hooks nothing")
    check(#file_names_like(env, "^re7mp/spawn") == 0 and #file_names_like(env, "^re7mp/cutscenes") == 0 and #file_names_like(env, "cs_") == 0 and #file_names_like(env, "spawnlog") == 0,
        "(10.22 gone) no spawn log or cutscene file is written: " .. table.concat(file_names_like(env, "spawn"), ","))
    check(not log_has(env, "previous session"), "(10.22 gone) a crash marker of the removed spawn log is ignored without a word")
    check(not log_has(env, "script error") and not log_has(env, "UI error"), "(10.22 gone) ...and nothing breaks")
    local sv = env.files["re7mp/settings.json"] or {}
    check(sv.cutscene_probe == nil and sv.cutscene_secs == nil and sv.cutscene_link == nil and sv.spawn_log == nil and sv.spawn_focus == nil and sv.door_sync == nil and sv.enemy_mode == nil,
        "(10.22 gone) the settings file is written without the keys of the removed things")
    check(sv.enemy_mode2 == 3, "(10.22 gone) ...and the old enemy_mode = 1 was not read: the default 3 is saved under enemy_mode2 (" .. tostring(sv.enemy_mode2) .. ")")
    run_ui(env)
    no_ui_errors(env, "(10.22 gone) the panel with an old settings file")

    -- the doors: always on (the whole door scenario is in tools/lua_smoke.lua); here only that the old "off" is not in effect
    local dr = h.doors
    check(dr and dr.on == true, "(10.22 gone) doors: on although the old file said door_sync = false")
end

-- =============================================================================================
-- E. Enemy sync mode 3 is the default
-- =============================================================================================
do
    local MODE3 = "Ghosts, and move my own enemies onto the host's"
    -- a joiner that chose nothing: its own Jack is moved onto the host's
    local env = world("join")
    run_ui(env)
    local cb = env.seen_combos and env.seen_combos["Enemy sync"]
    check(cb and cb.idx == 3, "(10.22 mode) a new joiner starts in mode 3: " .. tostring(cb and cb.idx))
    check(cb and cb.items and #cb.items == 3 and cb.items[1] == "Off" and cb.items[2] == "Show the host's enemies as red ghosts" and cb.items[3] == MODE3, "(10.22 mode) the three modes, the third without a label of its own")
    local plain = true
    for _, it in ipairs(cb and cb.items or {}) do if tostring(it):lower():find("experimental", 1, true) then plain = false end end
    check(plain, "(10.22 mode) no mode says 'experimental'")
    check(not ui_has(env, "EXPERIMENTAL: this moves your own enemies"), "(10.22 mode) ...and the panel no longer warns about it")
    H.set_calls({})
    env.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,5.00,0.00,6.00,0,0.7071,0,0.7071,500,1,2,3,4.0" }
    for _ = 1, 40 do run_frames(env, 0.05) bump_remote(env) end
    check(calls_have("Em2000.set_Position 5.00 0.00 6.00"), "(10.22 mode) with nothing chosen the joiner's own Em2000 is moved onto the host's")
    live(env, 2.5)
    check(env.files["re7mp/settings.json"] and env.files["re7mp/settings.json"].enemy_mode2 == 3 and env.files["re7mp/settings.json"].enemy_mode == nil,
        "(10.22 mode) ...and 3 is remembered under enemy_mode2 (the old key is not written)")

    -- a player who chose ghosts only keeps it
    local env2 = world("join", { enemy_mode2 = 2 })
    run_ui(env2)
    check(env2.seen_combos["Enemy sync"].idx == 2, "(10.22 mode) a saved enemy_mode2 = 2 is kept (ghosts only)")
    H.set_calls({})
    env2.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,5.00,0.00,6.00,0,0.7071,0,0.7071,500,1,2,3,4.0" }
    for _ = 1, 40 do run_frames(env2, 0.05) bump_remote(env2) end
    check(not calls_have("Em2000.set_Position"), "(10.22 mode) ...and in mode 2 nothing of the joiner's own is moved")

    -- ... and a saved 3 is kept (it used to be thrown away at every start)
    local env3 = world("join", { enemy_mode2 = 3 })
    run_ui(env3)
    check(env3.seen_combos["Enemy sync"].idx == 3, "(10.22 mode) a saved enemy_mode2 = 3 is kept")
    -- off is a choice too
    local env4 = world("join", { enemy_mode2 = 1 })
    run_ui(env4)
    check(env4.seen_combos["Enemy sync"].idx == 1, "(10.22 mode) a saved enemy_mode2 = 1 (off) is kept")
    -- the 0.10 file: the default 2 that was saved with everything else must NOT keep anybody on ghosts
    local env5 = world("join", { enemy_mode = 2, enemy_drive_ai = false })
    run_ui(env5)
    check(env5.seen_combos["Enemy sync"].idx == 3, "(10.22 mode) the old key enemy_mode = 2 (the 0.10 default, saved for everybody) is not read: mode 3")
    -- damaged values are ignored
    local env6 = world("join", { enemy_mode2 = "three" })
    run_ui(env6)
    check(env6.seen_combos["Enemy sync"].idx == 3, "(10.22 mode) a damaged enemy_mode2 is ignored: mode 3")
    local env7 = world("join", { enemy_mode2 = 9 })
    run_ui(env7)
    check(env7.seen_combos["Enemy sync"].idx == 3, "(10.22 mode) an enemy_mode2 outside 1 to 3 is ignored: mode 3")

    -- the panel still changes it, and the choice is remembered
    local env8 = world("host")
    env8.combo_override["Enemy sync"] = 2
    run_ui(env8)
    live(env8, 2.5)
    check(env8.files["re7mp/settings.json"].enemy_mode2 == 2, "(10.22 mode) choosing ghosts only in the panel is remembered")

    -- the host: mode 3 by default, and it still sends its enemies
    local envh = world("host")
    run_ui(envh)
    check(envh.seen_combos["Enemy sync"].idx == 3, "(10.22 mode) the host starts in mode 3 as well")
    live(envh, 3)
    local out = envh.files["re7mp_state_out.json"]
    check(out and tostring(out.p):find("Em2000", 1, true) ~= nil, "(10.22 mode) ...and its snapshots hold its enemies: " .. tostring(out and tostring(out.p):sub(1, 60)))

    -- a joiner with nothing received (no host talking) moves nothing and says nothing wrong
    local env9 = world("join")
    H.set_calls({})
    live(env9, 3)
    check(not calls_have("set_Position"), "(10.22 mode) no host data, no moving about")
    run_ui(env9)
    no_ui_errors(env9, "(10.22 mode) mode 3 with nothing received")
end
