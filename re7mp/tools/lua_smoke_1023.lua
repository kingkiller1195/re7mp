-- Checks of build 10.23 (release 0.11 unchanged) for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1023_file) with that file's helpers in one table.
--   RE7MP_ONLY_1023=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What the build changed, and what this file checks (all of it AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   V. the version: release 0.11 (unchanged), build 10.23
--   M. the menu: the "Enemies" section is a part of "Developer tools" (it was a tab of the main panel); nothing else moved; the joiner's one-line hint points to it
--   D. what the move must NOT do: with the section never drawn, the default (mode 3) is still in effect, and the exe's own box still sets the mode
--   G. the execution test (log + block) and Mia's hair physics are GONE: nothing of them in the script, the debug file, the settings or the files
-- (The Death section's execution checks, the hair-physics-is-gone world checks, the shipped defaults file and the version strings are in tools/lua_smoke.lua,
--  next to the older tests they change.)

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
    for i, l in ipairs(env.ui_nodes) do
        if l:sub(1, #prefix) == prefix then return l, i end
    end
    return nil
end
local function no_ui_errors(env, what)
    local bad
    for _, t in ipairs(env.ui_texts) do if t:find("UI error", 1, true) then bad = t break end end
    check(bad == nil, what .. ": no UI error" .. (bad and (" (" .. bad .. ")") or ""))
end

local DEV = "Developer tools (for the mod's author: you do not need these to play)"
local DEBUGFILES = "Debug files for the developer (send me reframework\\data\\re7mp\\debug.json)"
local TESTING = "Testing tools (dev build)"

-- =============================================================================================
-- V. the version
-- =============================================================================================
do
    local env = world("host")
    live(env, 3)
    health(env)
    local d = env.files["re7mp/debug.json"]
    check(d and d.release == "0.11" and d.build == "10.27" and d.script == "re7mp v10.27", "(10.23) the debug file says release 0.11 (unchanged), build 10.23: " .. tostring(d and d.release) .. " / " .. tostring(d and d.build))
    run_ui(env)
    check(ui_has(env, "Release v0.11   (script build 10.27"), "(10.23) the panel shows release v0.11 and build 10.23")
end

-- =============================================================================================
-- M. the menu: Enemies lives in Developer tools now
-- =============================================================================================
do
    for _, role in ipairs({ "host", "join" }) do
        local env = world(role)
        run_ui(env)
        local who = "(10.23 menu, " .. role .. ")"
        no_ui_errors(env, who)
        local n_en, i_en = node_index(env, "Enemies")
        local n_dev, i_dev = node_index(env, DEV)
        local _, i_dbg = node_index(env, DEBUGFILES)
        local _, i_test = node_index(env, TESTING)
        local _, i_items = node_index(env, "Items")
        local _, i_story = node_index(env, "Story sync (EXPERIMENTAL)")
        check(n_en == 1 and n_dev == 1, who .. " one Enemies section and one Developer tools section (" .. n_en .. ", " .. n_dev .. ")")
        check(i_dev and i_en and i_dev < i_en, who .. " Enemies comes after the start of Developer tools, so it is inside it (" .. tostring(i_dev) .. " < " .. tostring(i_en) .. ")")
        check(i_dbg and i_test and i_en and i_dbg < i_en and i_en < i_test, who .. " ...between the debug files section and the testing tools, both of which are its neighbours (" .. tostring(i_dbg) .. " < " .. tostring(i_en) .. " < " .. tostring(i_test) .. ")")
        check(i_items and i_story and i_story == i_items + 1, who .. " in the main panel Items is now followed straight by Story sync: no Enemies tab between them (" .. tostring(i_items) .. ", " .. tostring(i_story) .. ")")
        -- the sections of the main panel are all still there and in the order they had (only Enemies left it)
        local order = { "Death (what happens when you die)", "Health, downed and revive", "Items", "Story sync (EXPERIMENTAL)", "Who I am (character)", "Ethan's friend (an AI helper you play with alone: no network)",
            "Items: journal of pickups and inventory changes (for the item sync)", "Weapons (which one I hold, what it does, friendly fire)", "Enemy models (the host's enemies as their real models)",
            "Chat and pings", "Other player's body: which model, hair, how close", DEV }
        local last = 0
        for _, label in ipairs(order) do
            local n, i = node_index(env, label)
            check(n == 1 and i and i > last, who .. " section in its place: " .. label:sub(1, 50))
            last = i or last
        end
        -- the controls that were in the section are all still drawn (inside the developer section)
        check(env.seen_combos and env.seen_combos["Enemy sync"] ~= nil, who .. " the Enemy sync box is drawn (inside Developer tools)")
        check(env.seen_checks and env.seen_checks["Also switch off their AI (riskier; they stop fighting the host's positions)"] ~= nil
            and env.seen_checks["Boss health bar: show the host's health for a boss at the top of both screens, so the two numbers can be seen to match (remembered)##poolbar"] ~= nil,
            who .. " ...and so are the check boxes that go with mode 3 (the AI switch and the boss health bar)")
    end

    -- the joiner's one-line hint at the top of the panel points to the new place, and tells the truth about the mode
    local env = world("join")
    run_ui(env)
    check(ui_has(env, "Enemies: the host's game runs them and your own enemies are moved onto theirs (settings: Developer tools > Enemies)."), "(10.23 menu) a joiner on the default mode 3 is told that its own enemies are moved onto the host's, and where the settings are")
    check(not ui_has(env, "you see them as red ghosts"), "(10.23 menu) ...and not that it sees red ghosts")
    local env2 = world("join", { enemy_mode2 = 2 })
    run_ui(env2)
    check(ui_has(env2, "Enemies: the host's game runs them; you see them as red ghosts (settings: Developer tools > Enemies)."), "(10.23 menu) a joiner who chose ghosts only is told it sees red ghosts, and where the settings are")
    local envh = world("host")
    run_ui(envh)
    check(ui_has(envh, "Enemies: your game runs them (you are the host) and tells the other player where they are."), "(10.23 menu) the host's line is as it was")
    check(not ui_has(env, "(see the Enemies section)") and not ui_has(envh, "(see the Enemies section)"), "(10.23 menu) nothing points to an Enemies section of the main panel any more")

    -- with Developer tools shut (as it is when the real game starts) none of the Enemies controls is drawn, and no node of it is offered
    for _, role in ipairs({ "host", "join" }) do
        local e = world(role)
        local im = e.G.imgui
        local tn = im.tree_node
        im.tree_node = function(label)
            local r = tn(label)
            if tostring(label):sub(1, 15) == "Developer tools" then return false end
            return r
        end
        run_ui(e)
        local who = "(10.23 menu, " .. role .. ", Developer tools shut)"
        check(node_index(e, "Enemies") == 0 and any_node_starting(e, "Testing tools") == nil, who .. " the Enemies node is not even offered (and neither are the other developer sections)")
        check(e.seen_combos == nil or e.seen_combos["Enemy sync"] == nil, who .. " the Enemy sync box is not drawn")
        check(node_index(e, "Items") == 1 and node_index(e, "Story sync (EXPERIMENTAL)") == 1, who .. " the sections of the main panel are drawn as before")
        no_ui_errors(e, who)
    end
end

-- =============================================================================================
-- D. moving the section must not change what the sync does
-- =============================================================================================
do
    -- the panel is never opened (the controls are behind Developer tools now): the default mode 3 is in effect all the same
    local env = world("join")
    H.set_calls({})
    env.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,5.00,0.00,6.00,0,0.7071,0,0.7071,500,1,2,3,4.0" }
    for _ = 1, 40 do run_frames(env, 0.05) bump_remote(env) end
    check(calls_have("Em2000.set_Position 5.00 0.00 6.00"), "(10.23 enemies) the panel was never opened, and the joiner's own Em2000 is moved onto the host's all the same (mode 3 is the default)")
    check(env.seen_combos == nil or env.seen_combos["Enemy sync"] == nil, "(10.23 enemies) ...(the box was never drawn: it is the setting, not the box, that does it)")

    -- a saved choice is still read at the start, with the box never drawn
    local env2 = world("join", { enemy_mode2 = 2 })
    H.set_calls({})
    env2.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,5.00,0.00,6.00,0,0.7071,0,0.7071,500,1,2,3,4.0" }
    for _ = 1, 40 do run_frames(env2, 0.05) bump_remote(env2) end
    check(not calls_have("Em2000.set_Position"), "(10.23 enemies) a saved 'ghosts only' is in effect with the box never drawn: nothing of the joiner's own is moved")

    -- the host sends its enemies without the panel as well
    local envh = world("host")
    live(envh, 3)
    local out = envh.files["re7mp_state_out.json"]
    check(out and tostring(out.p):find("Em2000", 1, true) ~= nil, "(10.23 enemies) the host's snapshots hold its enemies with the panel never opened")
end

-- =============================================================================================
-- G. the execution test and Mia's hair physics are gone
-- =============================================================================================
do
    local fh = io.open(H.SCRIPT, "rb")
    check(fh ~= nil, "(10.23 gone) the script can be read: " .. tostring(H.SCRIPT))
    if fh then
        local text = fh:read("a")
        fh:close()
        check(not text:find("RE7.exec", 1, true) and not text:find("execution_test", 1, true) and not text:find("execution test:", 1, true) and not text:find("exec_catch", 1, true) and not text:find("can_catch", 1, true),
            "(10.23 gone) the script has no execution test (RE7.exec, execution_test, exec_catch, can_catch)")
        -- (app.PlayerGrappleEm3000 is still NAMED, in the list of player components the health finder looks at first; it is not hooked: lua_smoke.lua checks the hooks)
        check(not text:find("app.Em3000Grapple", 1, true) and not text:find("app.GameOverScreen", 1, true),
            "(10.23 gone) ...and the grab class and the game-over screen the log hooked are not named any more")
        check(not text:find("CFG.hair", 1, true) and not text:find("hairstate", 1, true) and not text:find("d.hair_physics", 1, true) and not text:find("hair_suspect", 1, true)
            and not text:find("Mia: hair physics", 1, true) and not text:find("Read her hair components", 1, true),
            "(10.23 gone) the script has no hair physics (CFG.hair, hairstate, hair_physics read, crash marker, box, button)")
        -- what must stay
        check(text:find("Executions end the game for BOTH players", 1, true) ~= nil and text:find("function death.looks_like_execution", 1, true) ~= nil,
            "(10.23 gone) the execution team-wipe is still there")
        check(text:find("err == \"skip\"", 1, true) ~= nil and text:find("H.item_blocked(name)", 1, true) ~= nil,
            "(10.23 gone) the 'skip' path of the hook helper stays: a downed player's healing-item block uses it")
        check(text:find("Hide hair parts (hair is cloth", 1, true) ~= nil and text:find("mia_head_parts", 1, true) ~= nil,
            "(10.23 gone) 'Hide hair parts' and Mia's head parts stay (they are not the hair physics)")
    end

    -- a world with an old settings file that has the removed hair key, and a crash marker of it
    local env = world("host", { hair_physics = true, item_sync = true }, function(e)
        e.files["re7mp/lastcall.json"] = { stage = "hair", call = "via.motion.Chain.set_Gravity", clock = 1, time = os.time(), session = "an-older-session" }
        e.files["re7mp/hairstate.json"] = { session = 12345, standing = true, skip = { "via.motion.Chain.set_Label" }, at = 1 }
    end)
    live(env, 6)
    local h = health(env)
    check(h.hair == nil and h.execution_test == nil, "(10.23 gone) the debug file has no hair and no execution_test section")
    check(h.execution_wipe ~= nil and h.doors ~= nil, "(10.23 gone) ...but the execution_wipe section (the team wipe) is still in it")
    check(not log_has(env, "previous session"), "(10.23 gone) an old crash marker of the hair physics is passed over without a word")
    check(not log_has(env, "script error") and not log_has(env, "UI error"), "(10.23 gone) ...and nothing breaks")
    local sv = env.files["re7mp/settings.json"] or {}
    live(env, 3)
    sv = env.files["re7mp/settings.json"] or {}
    check(sv.hair_physics == nil, "(10.23 gone) hair_physics is not written back to the settings file")
    local st = env.files["re7mp/hairstate.json"]
    check(st == nil or st.standing == true, "(10.23 gone) ...and hairstate.json is not touched (an old one just sits there)")
    run_ui(env)
    no_ui_errors(env, "(10.23 gone) the panel with the old files")
    local n_death = node_index(env, "Death (what happens when you die)")
    check(n_death == 1 and not ui_has(env, "Execution test"), "(10.23 gone) the Death section is drawn without the execution test")
end
