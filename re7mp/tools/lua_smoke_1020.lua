-- Checks of build 10.20 for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1020_file) with that file's helpers in one table.
--   RE7MP_ONLY_1020=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What it covers (all of it is the game's behaviour AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   1. the frame-gap recorder: a wait the game makes between two frames is listed with a small script share, a hitch inside the script with a large one and the part that made it
--   2. the game's saving flag (get_NowSaving), looked at on every frame; given up after five bad answers
--   3. how often the script looks at things around the saves: re7mp.exe's file, the game's save slots (cached, to slot 20, only fast while somebody is connected), one scan for the debug file
--   4. the save slots of a partner that appears: a save made BEFORE they came is not "played with them", one made after is
--   5. the message inbox in active mode (about ten reads a second, not every pose read) and that a message still arrives within about a tenth of a second
--   6. the debug file in play: every 30 s (every 2 s while the REFramework menu is open)
local H = ...
local check, Obj = H.check, H.Obj
local new_environment, build_world, load_script, host_role_files = H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, bump_remote = H.run_frames, H.run_ui, H.ui_has, H.bump_remote

local STEP = 0.0167 -- 60 frames a second

-- Frames at 60 a second; the other player's packets keep coming when `peer` (so they never go stale).
local function live(env, secs, peer)
    for i = 1, math.floor(secs / STEP + 0.5) do
        run_frames(env, STEP, STEP)
        if peer and env.files["re7mp_in.json"] and i % 3 == 0 then bump_remote(env) end
    end
end

-- Counts the files the script reads and writes (the script looks `json.load_file` / `json.dump_file` up on every call, so wrapping the fields is enough).
local function counting(env)
    local c = { loads = {}, dumps = {}, slots = 0 }
    local jl, jd = env.G.json.load_file, env.G.json.dump_file
    env.G.json.load_file = function(name, ...) c.loads[name] = (c.loads[name] or 0) + 1 return jl(name, ...) end
    env.G.json.dump_file = function(name, ...) c.dumps[name] = (c.dumps[name] or 0) + 1 return jd(name, ...) end
    return c
end

-- A game that answers isExistData for `game` (a list of slots) and get_NowSaving from env.saving; counts the questions.
local function save_manager(env, c, game, cost)
    env.saving = false
    env.singletons["app.SaveDataManager"] = Obj.new("app.SaveDataManager", {
        isExistData = function(_, n)
            c.slots = c.slots + 1
            if cost then env.clock = env.clock + cost end -- (a game that is slow to answer: every question takes this long)
            for _, g in ipairs(game) do if g == n then return true end end
            return false
        end,
        get_NowSaving = function() return env.saving end,
    })
end

local function make(opts)
    opts = opts or {}
    local env = new_environment()
    build_world(env)
    for k, v in pairs(opts.globals or {}) do env.G[k] = v end
    if opts.pre then opts.pre(env) end
    load_script(env)
    return env
end

local function force_debug(env)
    env.ui_press["Save the debug file now"] = true
    run_ui(env)
    live(env, 0.1, true)
    return env.files["re7mp/debug.json"]
end

----------------------------------------------------------------------------------------------
-- 1. the frame-gap recorder
----------------------------------------------------------------------------------------------
do
    local env = make()
    host_role_files(env, "host", "tcp")
    live(env, 2, true)
    local g0 = force_debug(env).health.perf.frame_gaps
    check(type(g0) == "table" and g0.frames_seen > 60, "(10.20) the debug file has health.perf.frame_gaps and has seen frames: " .. tostring(g0 and g0.frames_seen))
    check(g0.gaps_over["50ms"] == 0 and g0.gaps_over["100ms"] == 0 and #g0.recent == 0, "(10.20) at 60 frames a second no gap is listed")

    -- the game stops for 0.4 s between two frames (an autosave, a stream): the script did nothing in it
    env.clock = env.clock + 0.4
    live(env, 0.2, true)
    local g1 = force_debug(env).health.perf.frame_gaps
    local rec = g1.worst[1]
    check(rec ~= nil and rec.gap_ms >= 400 and rec.gap_ms < 450, "(10.20) a 0.4 s wait between two frames is listed as a gap of about 400 ms: " .. tostring(rec and rec.gap_ms))
    check(rec and rec.ours_ms < 40 and rec.other_ms > 350, "(10.20) ...with a small script share (ours_ms " .. tostring(rec and rec.ours_ms) .. ") and a large other_ms (" .. tostring(rec and rec.other_ms) .. ")")
    check(g1.gaps_over["100ms"] == 1 and g1.gaps_over["250ms"] == 1 and g1.gaps_over["500ms"] == 0, "(10.20) the counts by size: one over 100 ms and 250 ms, none over 500 ms")
    check(g1.over_100ms_mostly_not_the_script == 1 and g1.over_100ms_mostly_the_script == 0, "(10.20) ...and it is counted as not the script's")
    check(rec and rec.saving == nil and rec.loading == nil, "(10.20) no save and no loading is claimed when none was on")

    -- the script stops for 0.25 s inside its own work (the pose file write is slow once)
    local slow = true
    local jd = env.G.json.dump_file
    env.G.json.dump_file = function(name, ...)
        if slow and name == "re7mp_out.json" then slow = false env.clock = env.clock + 0.25 end
        return jd(name, ...)
    end
    live(env, 0.3, true)
    local g2 = force_debug(env).health.perf.frame_gaps
    local mine
    for _, r in ipairs(g2.recent) do if r.ours_ms and r.ours_ms >= 200 then mine = r end end
    check(mine ~= nil and mine.gap_ms >= 250, "(10.20) a hitch inside the script is listed with a large script share: " .. tostring(mine and mine.ours_ms))
    check(mine and mine.ours_top == "net: pose file write", "(10.20, part renamed in 10.27: net send/read became four) ...and names the part that made it (net: pose file write): " .. tostring(mine and mine.ours_top))
    check(g2.over_100ms_mostly_the_script == 1 and g2.over_100ms_mostly_not_the_script == 1, "(10.20) ...and counted as the script's, the earlier one still as not")
    check(#g2.recent == 2 and g2.recent[1].gap_ms >= 400 and g2.worst[1].gap_ms >= 400, "(10.20) recent is in time order, worst has the biggest first")

    -- loading and menu tags
    env.singletons["app.GameManager"] = Obj.new("app.GameManager", {}, { ["<IsSceneLoading>k__BackingField"] = true })
    live(env, 0.1, true)
    env.clock = env.clock + 0.2
    live(env, 0.1, true)
    local g3 = force_debug(env).health.perf.frame_gaps
    local tagged
    for _, r in ipairs(g3.recent) do if r.loading then tagged = r end end
    check(tagged ~= nil, "(10.20) a gap while the game says it is loading is tagged loading")

    -- forty more, of growing size: recent keeps the newest 30 in time order, worst keeps the 12 biggest, biggest first
    for i = 1, 40 do
        env.clock = env.clock + 0.07 + i * 0.01
        live(env, 0.05, true)
    end
    local g4 = force_debug(env).health.perf.frame_gaps
    check(#g4.recent == 30 and g4.recent[30].gap_ms > g4.recent[1].gap_ms and g4.recent[1].at < g4.recent[30].at, "(10.20) recent keeps the newest 30, oldest first: " .. #g4.recent)
    local sorted = #g4.worst == 12
    for i = 2, #g4.worst do if g4.worst[i - 1].gap_ms < g4.worst[i].gap_ms then sorted = false end end
    check(sorted and g4.worst[1].gap_ms >= 470 and g4.worst[1].gap_ms < 520, "(10.20) worst keeps the 12 biggest, biggest first: " .. tostring(g4.worst[1] and g4.worst[1].gap_ms))
    check(g4.gaps_over["50ms"] >= 43 and g4.gaps_over["500ms"] >= 0, "(10.20) every gap is counted even when the lists are trimmed: " .. tostring(g4.gaps_over["50ms"]))
end

----------------------------------------------------------------------------------------------
-- 2. the saving flag
----------------------------------------------------------------------------------------------
do
    local c
    local env = make({ pre = function(e) c = counting(e) save_manager(e, c, { 0, 1, 2 }) end })
    host_role_files(env, "host", "tcp")
    live(env, 1, true)
    local f0 = force_debug(env).health.perf.frame_gaps.saving_flag
    check(f0.supported == true and f0.polls > 40 and f0.times_began == 0 and f0.now == false, "(10.20) the flag is read on every frame and is false: polls " .. tostring(f0.polls))
    env.saving = true
    live(env, 0.1, true)
    env.clock = env.clock + 0.3 -- the game is slow while it saves
    live(env, 0.05, true)
    env.saving = false
    live(env, 0.5, true)
    local g = force_debug(env).health.perf.frame_gaps
    local f1 = g.saving_flag
    check(f1.times_began == 1 and f1.now == false and #f1.events == 2 and f1.events[1].what == "saving began" and f1.events[2].what == "saving ended", "(10.20) a save is listed as began / ended")
    check(f1.events[2].secs ~= nil and f1.events[2].secs >= 0.3 and f1.events[2].secs < 1, "(10.20) ...with how long it lasted: " .. tostring(f1.events[2].secs))
    local rec
    for _, r in ipairs(g.recent) do if r.saving then rec = r end end
    check(rec ~= nil and rec.gap_ms >= 300 and rec.saving_began_s_ago ~= nil, "(10.20) the gap that came with the save says saving was on")

    -- a game whose flag does not answer true / false: given up after five answers
    local calls = 0
    local env2 = make({ pre = function(e) e.singletons["app.SaveDataManager"] = Obj.new("app.SaveDataManager", { get_NowSaving = function() calls = calls + 1 error("no such method") end }) end })
    host_role_files(env2, "host", "tcp")
    live(env2, 3, true)
    local f2 = force_debug(env2).health.perf.frame_gaps.saving_flag
    check(f2.supported == false and f2.errors == 5 and calls == 5, "(10.20) a flag that never answers is asked five times and then left alone: calls " .. calls)

    -- no SaveDataManager at all (the title screen): nothing is counted as an error
    local env3 = make()
    host_role_files(env3, "host", "tcp")
    live(env3, 2, true)
    local f3 = force_debug(env3).health.perf.frame_gaps.saving_flag
    check(f3.errors == 0 and f3.polls == 0 and f3.supported == nil, "(10.20) no save manager yet: no polls, no errors")
end

----------------------------------------------------------------------------------------------
-- 3. how often the script looks at the saves
----------------------------------------------------------------------------------------------
do
    local EXE = "re7mp_coop_saves.json"
    -- (the harness sets RE7MP_TEST_SAVES_S for the older checks; the script reads it when it loads, so it is cleared before load_script)
    local function world_real(partner, shared)
        local c
        local env = new_environment()
        build_world(env)
        env.G.RE7MP_TEST_SAVES_S = nil
        c = counting(env)
        save_manager(env, c, { 0, 1, 2, 3 })
        env.files[EXE] = { enabled = shared == true, last = "", occupied = {}, dir = "", entries = {} }
        load_script(env)
        if partner then host_role_files(env, "host", "tcp") end
        return env, c
    end

    -- nobody connected, nothing shared: a slow look
    local env, c = world_real(false, false)
    live(env, 60, false)
    check(c.loads[EXE] >= 3 and c.loads[EXE] <= 6, "(10.20) idle: re7mp.exe's save file is read every 15 s, not every second: " .. tostring(c.loads[EXE]) .. " reads in 60 s")
    check(c.slots <= 4 * 21, "(10.20) idle: the game's slots are asked at most a few times in 60 s (to slot 20 only: 21 questions a time): " .. c.slots)
    local sc = force_debug(env).health.coop_saves.slot_scans
    check(sc.scans >= 1 and sc.calls == sc.scans * 21 and sc.served_from_cache >= 0, "(10.20) the debug file says how many scans and questions: " .. tostring(sc.scans) .. " / " .. tostring(sc.calls))

    -- a scan that takes 30 ms or more (a disk that is busy) is listed with when it happened
    do
        local envs = new_environment()
        build_world(envs)
        envs.G.RE7MP_TEST_SAVES_S = nil
        save_manager(envs, counting(envs), { 0, 1, 2, 3 }, 0.002) -- 21 questions of 2 ms: 42 ms
        envs.files[EXE] = { enabled = false, last = "", occupied = {}, dir = "", entries = {} }
        load_script(envs)
        live(envs, 3, false)
        local st = force_debug(envs).health.coop_saves.slot_scans
        check(#st.slow >= 1 and st.slow[1].ms >= 40 and st.slow[1].slots == 21 and st.max_ms >= 40, "(10.20) a slow scan is listed (when, how long, how many slots): " .. tostring(st.slow[1] and st.slow[1].ms))
    end

    -- somebody connected: a look every 5 s
    local envp, cp = world_real(true, true)
    live(envp, 60, true)
    check(cp.loads[EXE] >= 10 and cp.loads[EXE] <= 14, "(10.20) with a partner: the file is read every 5 s: " .. tostring(cp.loads[EXE]))
    check(cp.slots >= 10 * 21 and cp.slots <= 15 * 21, "(10.20) with a partner: the slots are scanned every 5 s: " .. cp.slots .. " questions in 60 s (before: 61 every 5 s and again for each debug file)")

    -- the REFramework menu open: the file every 2 s (somebody is looking at the panel)
    local envu, cu = world_real(false, false)
    live(envu, 5, false)
    local before = cu.loads[EXE]
    for _ = 1, 20 do
        run_ui(envu)
        live(envu, 0.5, false)
    end
    local reads = cu.loads[EXE] - before
    check(reads >= 4 and reads <= 7, "(10.20) with the menu open the file is read every 2 s: " .. reads .. " reads in 10 s")

    -- the debug file builds no scan of its own when the last one is young: sixty debug files, a handful of scans
    local envd, cd = world_real(false, false)
    envd.G.RE7MP_TEST_FLUSH_S = nil
    live(envd, 2, false)
    local scans0 = cd.slots
    for _ = 1, 20 do force_debug(envd) end
    check(cd.slots - scans0 <= 21, "(10.20) twenty forced debug files cost at most one more scan: " .. (cd.slots - scans0) .. " questions")
end

----------------------------------------------------------------------------------------------
-- 4. a partner that appears: the picture of the slots is taken then
----------------------------------------------------------------------------------------------
do
    local game = { 0, 1, 2, 3 }
    local env = new_environment()
    build_world(env)
    env.G.RE7MP_TEST_SAVES_S = nil
    local c = counting(env)
    save_manager(env, c, game)
    env.files["re7mp_coop_saves.json"] = { enabled = true, last = "", occupied = { 1, 2, 3 }, dir = "", entries = {} }
    load_script(env)
    live(env, 20, false) -- alone: a slow look
    game[#game + 1] = 4 -- I save in slot 4 while nobody is here
    live(env, 10, false)
    host_role_files(env, "host", "tcp") -- Bob comes
    live(env, 25, true)
    check(env.files["re7mp/coop_played.json"] == nil, "(10.20) a save made before the partner came is not 'played with' them")
    game[#game + 1] = 5 -- a save with Bob here
    live(env, 4, true)
    check(env.files["re7mp/coop_played.json"] == nil, "(10.20) ...a save with Bob here is not marked at once (the exe needs time to list it)")
    live(env, 20, true)
    local pf = env.files["re7mp/coop_played.json"]
    check(pf and #pf.slots == 1 and pf.slots[1].slot == 5 and pf.slots[1].partner == "Bob", "(10.20) ...but is, a few seconds later, with Bob's name")

    -- Bob leaves in the middle of the wait: the mark still comes (the look stays quick while one is waiting)
    local game2 = { 0, 1, 2, 3 }
    local env2 = new_environment()
    build_world(env2)
    env2.G.RE7MP_TEST_SAVES_S = nil
    save_manager(env2, counting(env2), game2)
    env2.files["re7mp_coop_saves.json"] = { enabled = true, last = "", occupied = { 1, 2, 3 }, dir = "", entries = {} }
    load_script(env2)
    host_role_files(env2, "host", "tcp")
    live(env2, 12, true)
    game2[#game2 + 1] = 4
    live(env2, 5.5, true) -- seen by the next look, now waiting its 6 s
    live(env2, 14, false) -- Bob has gone quiet
    local pf2 = env2.files["re7mp/coop_played.json"]
    check(pf2 and #pf2.slots == 1 and pf2.slots[1].slot == 4, "(10.20) a save seen while Bob was here is still marked when he leaves during the wait")
end

----------------------------------------------------------------------------------------------
-- 5. the message inbox in active mode
----------------------------------------------------------------------------------------------
do
    local env = new_environment()
    build_world(env)
    env.G.RE7MP_TEST_ACTIVE_GAP, env.G.RE7MP_TEST_ACTIVE_S, env.G.RE7MP_TEST_QUIET_S = nil, nil, nil
    local c = counting(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 5, true)
    local n = 0
    local function deliver(text)
        n = n + 1
        env.msg_n = (env.msg_n or 0) + 1
        env.inbox = env.inbox or {}
        env.inbox[#env.inbox + 1] = { n = env.msg_n, id = env.msg_n, k = 1, p = text }
        while #env.inbox > 32 do table.remove(env.inbox, 1) end
        env.files["re7mp_msg_in.json"] = { epoch = 1, msgs = env.inbox }
    end
    local before = c.loads["re7mp_msg_in.json"] or 0
    for i = 1, 33 do -- a message every 0.3 s for 10 s: the inbox is active all the time (the host's case)
        deliver("hello " .. i)
        live(env, 0.3, true)
    end
    local reads = (c.loads["re7mp_msg_in.json"] or 0) - before
    check(reads >= 60 and reads <= 140, "(10.20) a busy inbox is read about ten times a second, not on every pose read: " .. reads .. " reads in 10 s (before: about 280)")
    -- a message still arrives within about a tenth of a second
    deliver("latency-check")
    live(env, 0.15, true)
    run_ui(env)
    check(ui_has(env, "latency-check"), "(10.20) a message is handled within 0.15 s")
    -- everything that was sent arrived once
    local seen = 0
    for _, t in ipairs(env.ui_texts) do if tostring(t):find("hello ", 1, true) then seen = seen + 1 end end
    check(seen >= 1, "(10.20) the messages before it were handled too")
    local h = force_debug(env).health.bridge_reads.message_inbox_poll
    check(h.active_gap_s == 0.07 and h.active_s == 1 and h.quiet_s == 0.1, "(10.20) the debug file says the inbox rates: " .. tostring(h.active_gap_s) .. " / " .. tostring(h.active_s))
end

----------------------------------------------------------------------------------------------
-- 6. the debug file in play
----------------------------------------------------------------------------------------------
do
    local env = new_environment()
    build_world(env)
    env.G.RE7MP_TEST_FLUSH_S = nil
    local c = counting(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 100, true)
    local writes = c.dumps["re7mp/debug.json"] or 0
    check(writes >= 2 and writes <= 5, "(10.20) while playing the debug file is written about every 30 s: " .. writes .. " writes in 100 s (before: every 15 s)")
    local df = env.files["re7mp/debug.json"].health.perf.debug_file
    check(df.play_s == 30 and df.menu_s == 2, "(10.20) the debug file says its rates: play " .. tostring(df.play_s) .. " s, menu " .. tostring(df.menu_s) .. " s")
    local before = writes
    for _ = 1, 20 do
        env.ui_press["Clear the debug log"] = true -- (a quiet fake game logs nothing, and the file is only written when something changed)
        run_ui(env)
        live(env, 0.5, true)
    end
    check((c.dumps["re7mp/debug.json"] or 0) - before >= 3, "(10.20) with the REFramework menu open it is still written every 2 s: " .. ((c.dumps["re7mp/debug.json"] or 0) - before) .. " writes in 10 s")
end

----------------------------------------------------------------------------------------------
-- 7. the game-phase tick in laps (the parts of it are named, and they are not counted twice in the script's share of a gap)
----------------------------------------------------------------------------------------------
do
    local env = make()
    host_role_files(env, "host", "tcp")
    live(env, 1, true)
    env.check_override["Switch the body lab on"] = true -- (this is what hooks the game phases; in the real game something else usually already has)
    run_ui(env)
    local cb = env.phase_cbs["pre:UpdateBehavior"]
    check(cb ~= nil, "(10.20) the game-phase callback is registered once the body lab is on")
    if cb then
        for _ = 1, 30 do
            cb()
            run_frames(env, STEP, STEP)
        end
        local h = force_debug(env).health.perf
        local names = {}
        for _, p in ipairs(h.parts) do names[p.part] = p end
        check(names["phase: body guard + apply"] ~= nil and names["phase: enemy models"] ~= nil and names["phase: weapon mesh"] ~= nil,
            "(10.20) the tick is timed in laps: guard + apply, enemy models, weapon mesh ...")
        check(names["game-phase tick (UpdateBehavior)"] ~= nil and names["game-phase tick (UpdateBehavior)"].calls >= 30, "(10.20) ...next to the whole tick, as before")
        check(names["phase: enemy models"] ~= nil and names["phase: enemy models"].calls >= 30, "(10.20) every tick adds one lap per part: " .. tostring(names["phase: enemy models"] and names["phase: enemy models"].calls))
        check(names["enemy host: scene scan (once a second)"] ~= nil and names["enemy host: snapshots + file"] ~= nil, "(10.20) the enemy host's scene scan and its snapshots are timed apart")
    end
end
