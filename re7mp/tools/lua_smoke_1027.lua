-- Checks of build 10.27 (release 0.11 unchanged) for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1027_file) with that file's helpers in one table.
--   RE7MP_ONLY_1027=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What the build changed in the SCRIPT (all of it AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   D. the frame dips of the 10.26 file:
--      1. the model scan walks the scene with a cheaper walk that finds the SAME objects as the old one (names, inherited matches, the 8-level limit)
--      2. the automatic model collection only scans at a calm moment (a menu, a scripted move, standing still), after two minutes anyway, never while saving
--      3. the save-slot watch and the debug-file write wait while the game is saving (and 1.5 s after); a stuck flag does not hold them for ever; the button's write goes ahead
--      4. the old "net send/read" part is four parts
--   C. the garage car and the story number: the checks are in tools/lua_smoke_1019.lua, section 10 (that file has the fake car): the number holder's real methods (get_CastS32),
--      the state read through whichever route answers, the windows asked one by one, the action delegate, a state nobody listed, the probes' new limits
--   V. the version: release 0.11 (unchanged), build 10.27

local H = ...
local check, Obj, make_go, make_scene, vec = H.check, H.Obj, H.make_go, H.make_scene, H.vec
local new_environment, build_world, load_script, host_role_files = H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, log_has, bump_remote, texts_have = H.run_frames, H.run_ui, H.ui_has, H.log_has, H.bump_remote, H.texts_have

local function live(env, secs, step)
    step = step or 0.05
    for _ = 1, math.floor(secs / step + 0.5) do
        run_frames(env, step, step)
        bump_remote(env)
    end
end

local DEBUG = "re7mp/debug.json"
local function force_debug(env)
    env.ui_press["Save the debug file now"] = true
    run_ui(env)
    live(env, 0.1)
    return env.files[DEBUG]
end

local function counting(env)
    local c = { loads = {}, dumps = {}, slots = 0 }
    local jl, jd = env.G.json.load_file, env.G.json.dump_file
    env.G.json.load_file = function(name, ...) c.loads[name] = (c.loads[name] or 0) + 1 return jl(name, ...) end
    env.G.json.dump_file = function(name, ...) c.dumps[name] = (c.dumps[name] or 0) + 1 return jd(name, ...) end
    return c
end

local function save_manager(env, c, game)
    env.saving = false
    env.singletons["app.SaveDataManager"] = Obj.new("app.SaveDataManager", {
        isExistData = function(_, n)
            c.slots = c.slots + 1
            for _, g in ipairs(game) do if g == n then return true end end
            return false
        end,
        get_NowSaving = function() return env.saving end,
    })
end

-- a game object with a mesh under Character/ (so the scan keeps it)
local function char_mesh(path)
    return Obj.new("via.render.Mesh", {
        getMesh = function() return Obj.new("via.render.MeshResource", { get_ResourcePath = function() return path end }) end,
        get_MaterialNum = function() return 1 end })
end
local serial = 0
local function node(name)
    serial = serial + 1
    return make_go(name, vec(serial, 1.0, 0), { char_mesh("Character/Test/n" .. serial .. ".mesh") })
end
local function adopt(parent, kids)
    parent.xf.m.get_Child = function() return kids[1] and kids[1].xf or nil end
    for i, k in ipairs(kids) do k.xf._next = kids[i + 1] and kids[i + 1].xf or nil end
end

----------------------------------------------------------------------------------------------
-- D1. the cheaper scan finds the same objects as the old one
----------------------------------------------------------------------------------------------
do
    -- the old rule, as it was written in 10.26 (CFG.mprobe.matches on the whole path)
    local words = {}
    for w in ("pl;em;mia;ethan;jack;marguerite;lucas;zoe;clancy;chara"):gmatch("[^;,%s]+") do words[#words + 1] = w end
    local function old_matches(path, name)
        local low = (tostring(path) .. "/" .. tostring(name)):lower()
        for _, w in ipairs(words) do
            if #w <= 2 then
                local pat = "^" .. (w:gsub("%p", "%%%0")) .. "%d"
                for seg in low:gmatch("[^/]+") do
                    if seg:find(pat) then return true end
                end
            elseif low:find(w, 1, true) then
                return true
            end
        end
        return false
    end

    -- a chain of objects, each the only child of the one before: { "a", { { "b", { { "c" } } } } }
    local function chain(names, i)
        i = i or 1
        if i == #names then return { names[i] } end
        return { names[i], { chain(names, i + 1) } }
    end
    -- the scene: { name, children } trees; every object has a Character/ mesh
    local tree = {
        { "Pl0000", { { "Body" }, { "Plants" } } },                -- a child of a match is a match, whatever its own name
        { "Plants", { { "Emitter" }, { "Mia_Door", { { "Handle" } } } } }, -- "pl" must be followed by a digit; "mia" matches anywhere in a name, and passes down
        { "Props", { { "Chair" } } },                              -- nothing
        { "Em3000" },
        { "Folder/Pl0001" },                                       -- a name with a "/" in it: a part of it starts with pl and a digit
        chain({ "Misc", "d1", "d2", "d3", "Zoe", "d5", "d6", "d7", "d8", "Jack" }), -- ten levels: "Zoe" at level 4 passes its match down; "Jack" is at level 9, past the 8-level limit
        { "Emission" },                                            -- "em" not followed by a digit
        { "xEm5000" },                                             -- "em" does not start the name
        { "The_Chara_Lead" },                                      -- "chara" anywhere in a name
    }
    local roots, expect, visited = {}, {}, 0
    local function build(spec, path, depth, inherited_ok)
        local go = node(spec[1])
        local p = path .. "/" .. spec[1]
        if depth <= 8 then
            visited = visited + 1
            if old_matches(p, spec[1]) then expect[#expect + 1] = spec[1] end
        end
        if spec[2] then
            local kids = {}
            for _, k in ipairs(spec[2]) do kids[#kids + 1] = build(k, p, depth + 1) end
            adopt(go, kids)
        end
        return go
    end
    for _, s in ipairs(tree) do roots[#roots + 1] = build(s, "", 0) end
    -- (a node deeper than 8 levels is not visited by either walk: "Jack" is at level 9)
    table.sort(expect)

    local env = new_environment()
    build_world(env)
    for _, r in ipairs(roots) do env.scene_objects[#env.scene_objects + 1] = r end
    env.scene = make_scene(env.scene_objects)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 2)
    env.keys[0x7A] = true -- F11
    live(env, 0.3)
    env.keys[0x7A] = false
    live(env, 0.3)
    local d = force_debug(env)
    local mp = d and d.health and d.health.model_probe
    local got = {}
    for _, e in ipairs(mp and mp.found or {}) do got[#got + 1] = e.name end
    table.sort(got)
    local seen_player = false
    local fake_roots = #env.scene_objects - #roots -- (the fake world's own objects: the camera and the like)
    -- the fake world has a few objects of its own (the player, the camera ...): keep only the names this test made
    local mine = {}
    local wanted = {}
    for _, n in ipairs(expect) do wanted[n] = true end
    local made = {}
    local function note(spec) made[spec[1]] = true for _, k in ipairs(spec[2] or {}) do note(k) end end
    for _, s in ipairs(tree) do note(s) end
    for _, n in ipairs(got) do if made[n] then mine[#mine + 1] = n end end
    check(#expect >= 12 and #mine == #expect, "(10.27) the cheaper scan lists as many objects as the old rule: " .. #mine .. " of " .. #expect)
    local same = true
    for i = 1, #expect do if mine[i] ~= expect[i] then same = false end end
    check(same, "(10.27) ...the same ones: " .. table.concat(mine, ",") .. " vs " .. table.concat(expect, ","))
    local has = {}
    for _, n in ipairs(mine) do has[n] = true end
    check(has["Body"] and has["Plants"] and has["Handle"] and has["d8"] and has["Folder/Pl0001"] and has["The_Chara_Lead"] and has["Em3000"],
        "(10.27) a child of a match is a match (Body, Handle, d8), and the other matches are there")
    check(not has["Emitter"] and not has["Emission"] and not has["xEm5000"] and not has["Chair"] and not has["Props"] and not has["Jack"] and not has["d1"],
        "(10.27) what the old rule left out stays out (Emitter, Emission, xEm5000, Chair), and so does a level-9 object (Jack)")
    check(mp and mp.scanned >= visited and mp.scanned <= visited + fake_roots + 10, "(10.27) ...and the scan looked at the same number of objects: " .. tostring(mp and mp.scanned) .. " vs " .. visited)
end

----------------------------------------------------------------------------------------------
-- D2. the automatic collection waits for a calm moment
----------------------------------------------------------------------------------------------
do
    local BOX = "Collect by itself every 20 s while this is ticked (a scan stops the game for about 0.1 s: it waits for a menu, a cutscene or standing still)"
    local function auto_world()
        local env = new_environment()
        build_world(env)
        local ch = node("Pl2000")
        env.scene_objects[#env.scene_objects + 1] = ch
        env.scene = make_scene(env.scene_objects)
        load_script(env)
        host_role_files(env, "host", "tcp")
        live(env, 2)
        env.check_override[BOX] = true
        run_ui(env)
        return env
    end
    local function running(env, secs) -- 2 m/s: more than 25 cm in half a second
        for _ = 1, math.floor(secs / 0.05) do
            env.camera_pos.x = env.camera_pos.x + 0.1
            run_frames(env, 0.05, 0.05)
            bump_remote(env)
        end
    end
    local function stats(env)
        local mc = force_debug(env).health.model_collection
        return mc.scan_cost, mc.auto_scans
    end

    -- (reading the debug file opens the REFramework menu for a moment, and a menu is a calm moment: so each situation gets a world of its own and the file is read ONCE, at the end)
    local envA = auto_world()
    running(envA, 60)
    local cost, auto = stats(envA)
    check(cost.scans_timed == 0, "(10.27) while you keep running the automatic mode does not scan (60 s: " .. tostring(cost.scans_timed) .. " scans)")
    check(auto.waiting and auto.waiting:find("calm moment", 1, true) and auto.waiting:find("moving", 1, true), "(10.27) ...and says why: " .. tostring(auto.waiting))

    local envB = auto_world()
    running(envB, 125)
    cost, auto = stats(envB)
    check(cost.scans_timed == 1 and auto.forced_after_waiting == 1 and auto.at_a_calm_moment == 0, "(10.27) after two minutes without a calm moment it scans once anyway: " .. tostring(cost.scans_timed) .. " scans, forced " .. tostring(auto.forced_after_waiting))
    check(cost.last_ms ~= nil and cost.max_ms ~= nil, "(10.27) the debug file says what a scan cost: " .. tostring(cost.last_ms) .. " ms")

    local envC = auto_world()
    live(envC, 25) -- standing still
    cost, auto = stats(envC)
    check(cost.scans_timed == 1 and auto.at_a_calm_moment == 1 and auto.forced_after_waiting == 0, "(10.27) standing still it scans on time (every 20 s): " .. tostring(cost.scans_timed) .. " scan, " .. tostring(auto.at_a_calm_moment) .. " at a calm moment")

    -- the game saves (a save lasts about 3 s; the guard lets go of a flag that stays true for 15 s): no scan until it is over and 1.5 s have passed
    local envD = auto_world()
    local c = counting(envD)
    save_manager(envD, c, { 0 })
    live(envD, 18) -- the next scan is due at 20 s, two seconds from now
    envD.saving = true
    live(envD, 12)
    check(select(1, stats(envD)).scans_timed == 0, "(10.27) no scan while the game is saving, though one is due (12 s)")
    envD.saving = false
    live(envD, 0.8)
    check(select(1, stats(envD)).scans_timed == 0, "(10.27) ...nor in the 1.5 s after it")
    live(envD, 2)
    check(select(1, stats(envD)).scans_timed == 1, "(10.27) ...then it scans")

    -- a menu is a calm moment even while running; the box unticked means no scan at all
    local env2 = auto_world()
    env2.check_override["Switch the body lab on"] = nil
    running(env2, 25)
    check(select(1, stats(env2)).scans_timed == 0, "(10.27) (control) running again: nothing")
    env2.ui_press["Clear the debug log"] = true
    for _ = 1, 30 do -- the REFramework menu stays open
        env2.ui_press["Clear the debug log"] = true
        run_ui(env2)
        env2.camera_pos.x = env2.camera_pos.x + 0.5
        run_frames(env2, 0.5, 0.05)
        bump_remote(env2)
    end
    check(select(1, stats(env2)).scans_timed >= 1, "(10.27) with the menu open it scans even though I am moving")
    env2.check_override[BOX] = false
    run_ui(env2)
    local before = select(1, stats(env2)).scans_timed
    live(env2, 60)
    check(select(1, stats(env2)).scans_timed == before, "(10.27) the box unticked: no scan by itself")
    -- F11 and the button scan at once, whatever the moment
    local env3 = auto_world()
    running(env3, 5)
    env3.keys[0x7A] = true
    live(env3, 0.3)
    env3.keys[0x7A] = false
    live(env3, 0.3)
    check(select(1, stats(env3)).scans_timed == 1, "(10.27) F11 scans at once while running")
end

----------------------------------------------------------------------------------------------
-- D3. the save-slot watch and the debug file wait for the game's save
----------------------------------------------------------------------------------------------
do
    local EXE = "re7mp_coop_saves.json"
    local env = new_environment()
    build_world(env)
    env.G.RE7MP_TEST_SAVES_S = nil -- (the harness keeps the old 1 s file read for the older checks; this build's rates are the ones under test)
    env.G.RE7MP_TEST_FLUSH_S = nil
    local c = counting(env)
    save_manager(env, c, { 0, 1, 2, 3 })
    env.files[EXE] = { enabled = true, last = "", occupied = {}, dir = "", entries = {} }
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 12)
    local n0 = c.slots
    check(n0 >= 21 * 2, "(10.27) (control) with a partner the slots are asked about every 5 s: " .. n0 .. " questions in 12 s")
    env.saving = true
    live(env, 1)
    local n1 = c.slots
    live(env, 8)
    check(c.slots == n1, "(10.27) the slots are NOT asked while the game is saving (8 s): " .. (c.slots - n1) .. " questions")
    env.saving = false
    live(env, 1.0)
    check(c.slots == n1, "(10.27) ...nor in the 1.5 s after it (1 s later): " .. (c.slots - n1))
    live(env, 1.0)
    check(c.slots >= n1 + 21, "(10.27) ...then the look that was due is made at once: " .. (c.slots - n1) .. " questions")
    local w = force_debug(env).health.perf.frame_gaps.saving_flag.waits
    check(w.slot_watch and w.slot_watch.times == 1 and w.slot_watch.longest_s >= 6, "(10.27) the debug file says it waited: " .. tostring(w.slot_watch and w.slot_watch.longest_s) .. " s")

    -- a flag that stays true (stuck, or a very long save) does not hold the watch for ever
    env.saving = true
    live(env, 1)
    local n2 = c.slots
    live(env, 12)
    check(c.slots == n2, "(10.27) (control) still waiting after 13 s of saving")
    live(env, 6)
    check(c.slots > n2, "(10.27) after 15 s of 'saving' the watch goes ahead anyway: " .. (c.slots - n2) .. " questions")
    env.saving = false
    live(env, 3)

    -- the debug file: written on its own schedule only when no save is on; the button's write goes ahead
    local dumps0 = c.dumps[DEBUG] or 0
    env.saving = true
    live(env, 1)
    local dumps1 = c.dumps[DEBUG] or 0
    for _ = 1, 14 do -- the REFramework menu open: the file is written every 2 s (something has to change for it to be dirty)
        env.ui_press["Clear the debug log"] = true
        run_ui(env)
        live(env, 0.5)
    end
    check((c.dumps[DEBUG] or 0) == dumps1, "(10.27) the debug file is not written while the game is saving (7 s with the menu open): " .. ((c.dumps[DEBUG] or 0) - dumps1) .. " writes")
    env.ui_press["Save the debug file now"] = true
    run_ui(env)
    live(env, 0.1)
    check((c.dumps[DEBUG] or 0) == dumps1 + 1, "(10.27) ...but the button's write goes ahead")
    env.saving = false
    for _ = 1, 8 do
        env.ui_press["Clear the debug log"] = true
        run_ui(env)
        live(env, 0.5)
    end
    check((c.dumps[DEBUG] or 0) > dumps1 + 1, "(10.27) ...and the file is written again a moment after the save: " .. ((c.dumps[DEBUG] or 0) - dumps1 - 1) .. " more writes")
    local w2 = env.files[DEBUG].health.perf.frame_gaps.saving_flag.waits
    check(w2.debug_write and w2.debug_write.times >= 1, "(10.27) the debug file says its write waited")

    -- a game whose saving flag cannot be read (the 10.20 fallback): nothing ever waits
    local env4 = new_environment()
    build_world(env4)
    env4.G.RE7MP_TEST_SAVES_S = nil
    local c4 = counting(env4)
    env4.singletons["app.SaveDataManager"] = Obj.new("app.SaveDataManager", {
        isExistData = function(_, n) c4.slots = c4.slots + 1 return n == 0 end,
        get_NowSaving = function() error("no such method") end,
    })
    env4.files[EXE] = { enabled = true, last = "", occupied = {}, dir = "", entries = {} }
    load_script(env4)
    host_role_files(env4, "host", "tcp")
    live(env4, 12)
    check(c4.slots >= 21 * 2, "(10.27) with no readable saving flag the watch is not held back: " .. c4.slots .. " questions in 12 s")
end

----------------------------------------------------------------------------------------------
-- D4. the network part is four parts now
----------------------------------------------------------------------------------------------
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 3)
    local parts = {}
    for _, p in ipairs(force_debug(env).health.perf.parts) do parts[p.part] = p end
    check(parts["net: pose gather"] and parts["net: pose file write"] and parts["net: pose file read"] and parts["net: inbox read"],
        "(10.27) 'net send/read' is four parts: gather, file write, file read, inbox read")
    check(parts["net send/read"] == nil, "(10.27) ...and the old one is gone")
end

----------------------------------------------------------------------------------------------
-- V. the version
----------------------------------------------------------------------------------------------
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 1)
    local d = force_debug(env)
    check(d.release == "0.11" and d.build == "10.27", "(10.27) release 0.11, build 10.27: " .. tostring(d.release) .. " / " .. tostring(d.build))
end
