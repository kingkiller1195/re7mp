-- Checks of build 10.15 for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1015_file) with that file's helpers in one table.
--   RE7MP_ONLY_1015=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What it covers (all of it is the game's behaviour AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   1. one health pool: the host's enemy health goes along as a 14th field, the joiner's own copy of the enemy takes it (lowered at once, raised only after a wait, never to 0,
--      the same SHARE when the maxima differ), is finished when the host's dies, and the boss bar shows the host's number on both screens
--   2. the other player's weapon on their body: what the sender finds in my hand, the message, what the receiver accepts, the copy that is made, hung on the hand and taken down
--   3. the Molded: spawn points found, unique wire names, asleep / dead flags; (opt-in) copies in the joiner's game
local H = ...
local check, Obj, make_td, make_go, make_scene, vec = H.check, H.Obj, H.make_td, H.make_go, H.make_scene, H.vec
local new_environment, build_world, load_script, host_role_files = H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, texts_have, log_has, calls_have = H.run_frames, H.run_ui, H.ui_has, H.texts_have, H.log_has, H.calls_have
local messages_of_kind, push_msgs, bump_remote = H.messages_of_kind, H.push_msgs, H.bump_remote

-- the panel's boxes (the label is the whole text, as the fake imgui sees it)
local BOX_BAR = "Boss health bar: show the host's health for a boss at the top of both screens, so the two numbers can be seen to match (remembered)##poolbar"
local BOX_POOL = "One health pool (mode 3): my copy of the host's enemy takes the host's health, and dies when theirs does; never for a boss unless the next box is ticked, never during a cutscene or a load (remembered)##poolfollow"
local BOX_BOSS = "EXPERIMENTAL: the pool also writes the host's health into my copy of a BOSS (Mia, Jack ...; lowered only, never during a cutscene, never a damage call; not remembered: off at every start)##poolbosses"
local BOX_MOLD = "EXPERIMENTAL: bring out the host's Molded in my game too and move those real bodies onto theirs (not remembered; the game may close: it is switched off after a crash)##moldedcopies"
local BOX_WMESH = "Weapon: show the weapon in their hand (a copy of its model, made from the game's files and hung on the body's right-hand joint; the knife needs half a second; switched off after a crash; remembered)##wmesh"

local function comp_of(go, typename)
    for _, c in ipairs(go.m.get_Components().get_elements()) do
        if c._type == typename then return c end
    end
    return nil
end

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

-- a world of the stand-in game; setup(env) runs after the world is built and before the script is loaded
local function world(role, setup, settings)
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

-- the fake Jack (Em2000) gets the calls the health pool uses: get_maxHealth, setHealth(Single, Single), the damage call, and a death flag the test controls
local function pool_setup(rec)
    return function(env)
        local dc = comp_of(env.jack, "app.Em2000.Em2000DamageController")
        local st = comp_of(env.jack, "app.Em2000Status")
        env.pool_name = rec.name or "Em2000" -- (10.16) an ordinary enemy (Em4100) for the checks of the ordinary pool; the boss rules use Em2000
        if rec.name then env.jack.m.get_Name = function() return rec.name end end
        rec.dc, rec.st, rec.hi = dc, st, dc.f.HealthInfo
        rec.set, rec.hits, rec.dead = {}, {}, false
        rec.max = rec.max or 1000
        dc.m.get_maxHealth = function() return rec.max end
        dc.m["setHealth(System.Single, System.Single)"] = function(_, hp, mx)
            if rec.set_fails then error("fake: setHealth refused") end
            rec.set[#rec.set + 1] = { hp, mx }
            rec.hi.f._CurrentHealth = hp
        end
        dc.m.newFakeDamageInfo = function(_, dmg) return Obj.new("app.DamageInfo", {}, { dmg = dmg }) end
        dc.m.addManualDamage = function(_, info)
            rec.hits[#rec.hits + 1] = info.f.dmg
            if rec.dies_on and #rec.hits >= rec.dies_on then
                rec.dead = true
                rec.hi.f._CurrentHealth = 0
            end
            return Obj.new("app.DamageRecord", {})
        end
        st.m.get_IsDead = function() return rec.dead end
        env.pool_rec = rec
    end
end

-- the host's snapshot of Jack, as the joiner reads it from the exe's file (the 14th field is the maximum, left out for an older host)
local function host_says(env, hp, max, flags, x, z)
    env.snap_n = (env.snap_n or 500) + 1
    env.files["re7mp_state_in.json"] = { seq = env.snap_n, n = env.snap_n,
        p = string.format("%s,%.2f,0.00,%.2f,0,0.7071,0,0.7071,%d,%d,2,3,4.0%s", env.pool_name or "Em2000", x or 5, z or 6, hp, flags or 1, max and (",%d"):format(max) or "") }
end

local function joiner(rec, settings)
    local env = world("join", pool_setup(rec), settings)
    env.combo_override["Enemy sync"] = 3
    run_ui(env)
    if rec.bosses then env.check_override[BOX_BOSS] = true run_ui(env) end
    return env
end

-- =============================================================================================
-- 1a. the host's snapshot: the maximum health is a 14th field (only where the game gave one)
-- =============================================================================================
do
    local rec = {}
    local env = world("host", pool_setup(rec))
    local d = env.files["re7mp_state_out.json"]
    check(d ~= nil and type(d.p) == "string", "(10.15) wire: the host wrote a snapshot")
    local by, longest = {}, 0
    for e in ((d and d.p) or ""):gmatch("[^;]+") do
        if not e:match("^T[%d%.]+$") then
            local f = {}
            for x in e:gmatch("[^,]+") do f[#f + 1] = x end
            by[f[1]] = f
            longest = math.max(longest, #e)
        end
    end
    check(by.Em2000 and #by.Em2000 == 14 and tonumber(by.Em2000[14]) == 1000, "(10.15) wire: Jack's entry has 14 fields, the last is his maximum health: " .. tostring(by.Em2000 and by.Em2000[14]))
    check(by.Em2000 and tonumber(by.Em2000[9]) == 820, "(10.15) wire: ...and field 9 is still his health: " .. tostring(by.Em2000 and by.Em2000[9]))
    check(by.Em3100 and #by.Em3100 == 13, "(10.15) wire: an enemy with no DamageController sends 13 fields (no maximum to send): " .. tostring(by.Em3100 and #by.Em3100))
    check(by.Em6100 and #by.Em6100 == 13, "(10.15) wire: ...as does one with no health at all")
    check(longest < 130 and #d.p < 3000, "(10.15) wire: an entry is still short (" .. longest .. " characters) and the whole snapshot small (" .. #d.p .. ")")
    -- the maximum changes (another difficulty, a phase): it is read again every two seconds
    rec.max = 1500
    live(env, 2.6)
    local d2 = env.files["re7mp_state_out.json"]
    local mx = tostring(d2.p):match("Em2000,[^;]*,(%d+);") or tostring(d2.p):match("Em2000,[^;]*,(%d+)$")
    check(tonumber(mx) == 1500, "(10.15) wire: a changed maximum goes out within two seconds: " .. tostring(mx))
    -- a DamageController that errors for the maximum: no 14th field, nothing breaks
    rec.dc.m.get_maxHealth = function() error("fake: no maximum") end
    live(env, 2.6)
    local d3 = env.files["re7mp_state_out.json"]
    local f3 = {}
    for x in (tostring(d3.p):match("(Em2000[^;]*)") or ""):gmatch("[^,]+") do f3[#f3 + 1] = x end
    check(#f3 == 13, "(10.15) wire: when the game stops answering for the maximum the field is left out (" .. #f3 .. " fields)")
    check(not log_has(env, "script error") and not log_has(env, "snapshot failed"), "(10.15) wire: ...without an error")
end

-- =============================================================================================
-- 1b. the joiner reads it: a 14-field entry shows "HP 400/1000", an older host's 13 fields still work
-- =============================================================================================
do
    local rec = {}
    local env = world("join", pool_setup(rec))
    host_says(env, 400, 1000)
    live(env, 0.6)
    check(texts_have(env, "Em2000  HP 400/1000"), "(10.15) wire: the joiner's ghost label shows the host's health and maximum")
    env.texts = {}
    host_says(env, 350, nil)
    live(env, 0.6)
    check(texts_have(env, "Em2000  HP 350") and not texts_have(env, "HP 350/"), "(10.15) wire: an older host (13 fields) still works, with no maximum shown")
    host_says(env, 350, 0)
    env.texts = {}
    live(env, 0.6)
    check(texts_have(env, "Em2000  HP 350") and not texts_have(env, "HP 350/"), "(10.15) wire: a maximum of 0 is no maximum")
    -- an entry with a damaged 14th field is still taken (13 good ones), and a nonsense one does not break the others
    env.files["re7mp_state_in.json"] = { seq = 900, n = 900, p = "Em2000,5.00,0.00,6.00,0,0,0,1,300,1,2,3,4.0,abc;Em3100,1,0,1,0,0,0,1,200,1,2,3,4.0,99999999999" }
    env.texts = {}
    live(env, 0.6)
    check(texts_have(env, "Em2000  HP 300") and texts_have(env, "Em3100  HP 200"), "(10.15) wire: a 14th field that is not a number (or absurd) does not drop the entry")
end

-- =============================================================================================
-- 1c. the joiner's own copy (mode 3) takes the host's health
-- =============================================================================================
do
    local rec = { name = "Em4100" }
    local env = joiner(rec)
    check(rec.hi.f._CurrentHealth == 820, "(10.15) pool: setup: my own Jack starts at 820")
    host_says(env, 400, 1000)
    live(env, 1.8)
    check(rec.hi.f._CurrentHealth == 400, "(10.15) pool: the host's Jack has 400, so my Jack is lowered to 400: " .. tostring(rec.hi.f._CurrentHealth))
    check(#rec.set == 1 and rec.set[1][1] == 400 and rec.set[1][2] == 1000, "(10.15) pool: ...with setHealth(400, 1000), one call: " .. #rec.set)
    check(log_has(env, "health pool: Em4100 lowered 820 -> 400 (the host's 400 of 1000) by setHealth"), "(10.15) pool: ...and the journal says what was done")
    -- in step: nothing more is written, however long it goes on
    live(env, 2)
    check(#rec.set == 1, "(10.15) pool: while the numbers agree nothing is written (" .. #rec.set .. " writes)")
    -- the host's goes down: mine follows at once
    host_says(env, 300, 1000)
    live(env, 0.6)
    check(rec.hi.f._CurrentHealth == 300, "(10.15) pool: the host's Jack loses health, mine follows within half a second: " .. tostring(rec.hi.f._CurrentHealth))
    -- the host's is HIGHER than mine (my own shot landed a moment before their answer): the host's number is put back only after 1.5 s
    host_says(env, 700, 1000)
    live(env, 0.9)
    check(rec.hi.f._CurrentHealth == 300, "(10.15) pool: a copy that is lower than the host's is NOT raised at once (a hit just sent is not undone): " .. tostring(rec.hi.f._CurrentHealth))
    live(env, 1.4)
    check(rec.hi.f._CurrentHealth == 700, "(10.15) pool: ...but after 1.5 s the difference has stood, and it is raised: " .. tostring(rec.hi.f._CurrentHealth))
    -- a difference inside the tolerance is left alone
    local before = #rec.set
    host_says(env, 701, 1000)
    live(env, 2)
    check(#rec.set == before, "(10.15) pool: one point of difference is left alone")
    -- the host's is alive with 0 health (or less than 1): mine goes to 1, never to 0 (0 marks an enemy dead without the death)
    host_says(env, 0, 1000)
    live(env, 0.6)
    check(rec.hi.f._CurrentHealth == 1, "(10.15) pool: a host health under 1 puts mine to 1, never 0: " .. tostring(rec.hi.f._CurrentHealth))
    local zero = false
    for _, c in ipairs(rec.set) do if c[1] < 1 then zero = true end end
    check(not zero, "(10.15) pool: setHealth was never called with a number under 1")
    -- the host's health unreadable (-1): mine is left alone
    local n0 = #rec.set
    host_says(env, -1, 1000)
    live(env, 1)
    check(#rec.set == n0 and rec.hi.f._CurrentHealth == 1, "(10.15) pool: a host health of -1 (not readable there) changes nothing here")
    -- two difficulties: the same SHARE of the pool, not the same number (host 1000 of 2000 = half; my maximum is 1000 -> 500)
    host_says(env, 900, 1800) -- (10.16: 2000 and more is a boss maximum, and a boss is never scaled)
    live(env, 2.2)
    check(math.abs(rec.hi.f._CurrentHealth - 500) <= 1, "(10.15) pool: the host's 900 of 1800 is half, so mine (maximum 1000) is set to 500: " .. tostring(rec.hi.f._CurrentHealth))
    check(rec.set[#rec.set][2] == 1000, "(10.15) pool: ...with MY maximum")
    -- a host number above my maximum (no host maximum sent) is capped at my maximum
    host_says(env, 5000, nil)
    live(env, 2.2)
    check(rec.hi.f._CurrentHealth <= 1000 and rec.hi.f._CurrentHealth >= 999, "(10.15) pool: a host number above my own maximum is capped at it: " .. tostring(rec.hi.f._CurrentHealth))
    -- a dead copy is not brought back by a living host number
    rec.dead = true
    rec.hi.f._CurrentHealth = 0
    local n1 = #rec.set
    host_says(env, 900, 1000)
    live(env, 3)
    check(#rec.set == n1 and rec.hi.f._CurrentHealth == 0, "(10.15) pool: my copy is dead already: the host's number does not bring it back")
    rec.dead = false
    -- the report
    local hh = health(env)
    local bp = hh.boss_pool
    check(bp and bp.follow_on == true and bp.counts.lowered >= 3 and bp.counts.raised >= 2 and bp.counts.same >= 1 and bp.counts.scaled >= 1, "(10.15) pool: the debug file counts lowered / raised / in step / scaled: "
        .. tostring(bp and bp.counts.lowered) .. "/" .. tostring(bp and bp.counts.raised) .. "/" .. tostring(bp and bp.counts.same) .. "/" .. tostring(bp and bp.counts.scaled))
    check(bp and bp.copies and bp.copies[1] and bp.copies[1].name == "Em4100" and bp.last ~= nil and bp.about ~= nil, "(10.15) pool: ...and lists the copy and the last thing done")
    check(not log_has(env, "script error"), "(10.15) pool: no script error")
end

-- =============================================================================================
-- 1d. how it is written: setHealth first, then the health object, then the field; nothing works three times: left alone
-- =============================================================================================
do
    local rec = { name = "Em4100" }
    local env = joiner(rec)
    rec.dc.m["setHealth(System.Single, System.Single)"] = nil -- a game with no such overload
    host_says(env, 400, 1000)
    live(env, 1.8)
    check(rec.hi.f._CurrentHealth == 400, "(10.15) pool: with no setHealth the health field is written instead: " .. tostring(rec.hi.f._CurrentHealth))
    check(log_has(env, "by health field"), "(10.15) pool: ...and the journal says which way worked")
    -- the health object's own setter comes before the field
    local rec2 = { name = "Em4100" }
    local env2 = joiner(rec2)
    rec2.dc.m["setHealth(System.Single, System.Single)"] = nil
    local hi2 = rec2.hi
    local via_object = 0
    rec2.dc.m.getHealthInfo = function() return Obj.new("app.HealthInfo", { set_health = function(_, v) via_object = via_object + 1 hi2.f._CurrentHealth = v end }) end
    host_says(env2, 450, 1000)
    live(env2, 1.8)
    check(via_object == 1 and hi2.f._CurrentHealth == 450, "(10.15) pool: getHealthInfo():set_health is the second way: " .. via_object)
    -- nothing works: three failed writes and it is left alone (and says so once)
    local rec3 = { name = "Em4100" }
    local env3 = joiner(rec3)
    rec3.dc.m["setHealth(System.Single, System.Single)"] = nil
    local comp = rec3.hi
    comp.set_field = function() error("fake: read-only") end
    host_says(env3, 400, 1000)
    live(env3, 4)
    check(log_has(env3, "nothing could write its health three times; left alone from now on"), "(10.15) pool: when no way of writing works it gives up after three tries and says so")
    local hh = health(env3)
    check(hh.boss_pool.counts.errors == 3 and hh.boss_pool.copies[1].gave_up == true, "(10.15) pool: ...the errors are counted (" .. tostring(hh.boss_pool.counts.errors) .. ") and the copy is marked")
end

-- =============================================================================================
-- 1e. the host's enemy dies: my copy is finished with one big hit, up to three times, and only when it is where I put it
-- =============================================================================================
do
    local rec = { dies_on = 2, name = "Em4100" }
    local env = joiner(rec)
    host_says(env, 400, 1000)
    live(env, 1.8)
    check(#rec.hits == 0, "(10.15) pool: no hit while the host's Jack is alive")
    host_says(env, 0, 1000, 0)
    live(env, 0.7)
    check(#rec.hits == 0, "(10.15) pool: the host's Jack has just died: one second is waited before mine is hit")
    live(env, 0.8)
    check(#rec.hits == 1 and rec.hits[1] >= 3000, "(10.15) pool: then mine takes one hit far above its health (" .. tostring(rec.hits[1]) .. ")")
    live(env, 0.7)
    check(#rec.hits == 2, "(10.15) pool: ...it did not die, so a second hit follows 0.6 s later (" .. #rec.hits .. ")")
    live(env, 3)
    check(#rec.hits == 2 and rec.dead, "(10.15) pool: ...it died, and nothing more is done to it (" .. #rec.hits .. " hits)")
    local hh = health(env)
    check(hh.boss_pool.counts.killed == 1 and hh.boss_pool.counts.kill_tries == 2 and hh.boss_pool.copies[1].finished == true,
        "(10.15) pool: the debug file counts the kill (killed " .. tostring(hh.boss_pool.counts.killed) .. ", tries " .. tostring(hh.boss_pool.counts.kill_tries) .. ")")

    -- mine will not die: three hits, then given up
    local rec2 = { name = "Em4100" }
    local env2 = joiner(rec2)
    host_says(env2, 400, 1000)
    live(env2, 1.8)
    host_says(env2, 0, 1000, 0)
    live(env2, 6)
    check(#rec2.hits == 3, "(10.15) pool: a copy that will not die gets three hits and no more (" .. #rec2.hits .. ")")
    check(log_has(env2, "mine would not die after 3 hits"), "(10.15) pool: ...and the journal says so")
    check(health(env2).boss_pool.counts.kill_failed == 1, "(10.15) pool: ...and counts it")

    -- the copy is not where I put it (it is some other enemy of the same name): left alone
    local rec3 = { name = "Em4100" }
    local env3 = joiner(rec3)
    host_says(env3, 400, 1000)
    live(env3, 1.8)
    env3.jack.xf.m.get_Position = function() return vec(60, 0, 60) end
    host_says(env3, 0, 1000, 0)
    live(env3, 4)
    check(#rec3.hits == 0, "(10.15) pool: a copy far from where I put it is never hit")
    check(log_has(env3, "mine is not where I put it; left alone") and health(env3).boss_pool.counts.finish_far == 1, "(10.15) pool: ...and it says why")

    -- the host's was dead before I ever put mine on it: mine is not touched (another enemy of that name)
    local rec4 = { name = "Em4100" }
    local env4 = joiner(rec4)
    host_says(env4, 0, 1000, 0)
    live(env4, 5)
    check(#rec4.hits == 0 and #rec4.set == 0, "(10.15) pool: a host enemy that was dead from the start does not make me hit mine")

    -- a parked / asleep host enemy (flags 3) is not 'dead'
    local rec5 = { name = "Em4100" }
    local env5 = joiner(rec5)
    host_says(env5, 400, 1000)
    live(env5, 1.8)
    host_says(env5, 400, 1000, 2)
    live(env5, 5)
    check(#rec5.hits == 0, "(10.15) pool: a parked host enemy is not finished")
end

-- =============================================================================================
-- 1f. when it does nothing: mode 2 (ghosts only), the box unticked, a host that is silent
-- =============================================================================================
do
    local rec = { name = "Em4100" }
    local env = world("join", pool_setup(rec))
    env.combo_override["Enemy sync"] = 2 -- (10.22: mode 3 is the default now; this check is about mode 2)
    run_ui(env)
    host_says(env, 300, 1000)
    live(env, 3)
    check(#rec.set == 0 and #rec.hits == 0 and rec.hi.f._CurrentHealth == 820, "(10.15) pool: in mode 2 (ghosts) my own enemies' health is never touched")
    local rec2 = { name = "Em4100" }
    local env2 = joiner(rec2)
    env2.check_override[BOX_POOL] = false
    run_ui(env2)
    host_says(env2, 300, 1000)
    live(env2, 3)
    check(#rec2.set == 0 and rec2.hi.f._CurrentHealth == 820, "(10.15) pool: with the box unticked nothing is written")
    host_says(env2, 0, 1000, 0)
    live(env2, 4)
    check(#rec2.hits == 0, "(10.15) pool: ...and nothing is finished")
    env2.check_override[BOX_POOL] = true
    run_ui(env2)
    host_says(env2, 300, 1000)
    live(env2, 2)
    check(rec2.hi.f._CurrentHealth == 300 or #rec2.set >= 1, "(10.15) pool: ticked again, it works again (" .. tostring(rec2.hi.f._CurrentHealth) .. ")")
    -- the host goes quiet for more than 3 s: my enemies are let go and nothing is written
    local n = #rec2.set
    rec2.hi.f._CurrentHealth = 900 -- (so that a write WOULD be due if the old number were still believed: the host's last said 300)
    env2.clock = env2.clock + 10
    live(env2, 1)
    check(#rec2.set == n and rec2.hi.f._CurrentHealth == 900, "(10.15) pool: no new data from the host for more than 3 s: nothing is written")
    -- the HOST never writes health into its own enemies for this
    local rec3 = { name = "Em4100" }
    local env3 = world("host", pool_setup(rec3))
    live(env3, 4)
    check(#rec3.set == 0 and #rec3.hits == 0, "(10.15) pool: the host's own enemies are never written to")
end

-- =============================================================================================
-- 1g. the boss bar: the host's reading at the top of both screens
-- =============================================================================================
do
    local rec = {}
    local env = world("host", pool_setup(rec))
    live(env, 0.5)
    check(texts_have(env, "820 / 1000   (82%)") or texts_have(env, "820 / 1000"), "(10.15) bar: the host's screen shows Jack's health and maximum: " .. tostring(env.texts[#env.texts]))
    local fill, back
    for _, r in ipairs(env.rect_list or {}) do
        if r.c == 0xFF3030E0 then fill = r end
        if r.c == 0xC0101010 then back = r end
    end
    check(fill and back and fill.w == 295 and back.w == 362 and fill.h == 10, "(10.15) bar: a backdrop and a fill of 82% of 360 pixels (295) are drawn: " .. tostring(fill and fill.w))
    check(back and back.y == 73 and math.abs((back.x + 181) - 960) <= 1, "(10.15) bar: ...centred at the top of the screen")
    local hh = health(env)
    check(hh.boss_pool.bar_rows_now >= 1 and hh.boss_pool.bar_rects_drawn >= 1, "(10.15) bar: the debug file counts the bar")
    -- Jack loses health: the number follows
    rec.hi.f._CurrentHealth = 410
    env.texts = {}
    live(env, 0.5)
    check(texts_have(env, "410 / 1000") and texts_have(env, "(41%)"), "(10.15) bar: the host's bar follows his health (410, 41%)")
    -- he is dead: no bar
    rec.dead = true
    rec.hi.f._CurrentHealth = 0
    env.texts = {}
    live(env, 1.5)
    check(not texts_have(env, "/ 1000"), "(10.15) bar: a dead boss has no bar")
    rec.dead = false
    rec.hi.f._CurrentHealth = 500
    -- off
    env.check_override[BOX_BAR] = false
    run_ui(env)
    env.texts, env.rect_list = {}, {}
    live(env, 0.8)
    check(not texts_have(env, "/ 1000") and #env.rect_list == 0, "(10.15) bar: unticked, nothing is drawn")
    env.check_override[BOX_BAR] = true
    run_ui(env)
    live(env, 0.8)
    check(texts_have(env, "/ 1000"), "(10.15) bar: ticked again, it is back")

    -- the joiner: the same number, from the host's snapshot
    local rj = {}
    local envj = world("join", pool_setup(rj))
    host_says(envj, 400, 1000)
    envj.texts, envj.rect_list = {}, {}
    live(envj, 0.8)
    check(texts_have(envj, "400 / 1000   (40%)"), "(10.15) bar: the joiner's screen shows the host's 400 / 1000 (40%)")
    local jfill
    for _, r in ipairs(envj.rect_list or {}) do if r.c == 0xFF3030E0 then jfill = r end end
    check(jfill and jfill.w == 144, "(10.15) bar: ...with a fill of 40% (144 pixels): " .. tostring(jfill and jfill.w))
    -- the same bar in the joiner's mode 3 (my own copy follows, the bar is still the HOST's number)
    local rj3 = {}
    local envj3 = joiner(rj3)
    host_says(envj3, 250, 1000)
    envj3.texts = {}
    live(envj3, 1.8)
    check(texts_have(envj3, "250 / 1000   (25%)"), "(10.15) bar: in mode 3 the bar is still the host's number")
    -- an older host (no maximum): the number alone, no bar
    envj3.rect_list, envj3.texts = {}, {}
    host_says(envj3, 250, nil)
    live(envj3, 0.8)
    check(#envj3.rect_list == 0 and texts_have(envj3, "   250"), "(10.15) bar: with no maximum from the host the number is shown without a fill")
    -- an enemy that is not a boss (a Molded of 200) has no bar; one with a maximum of 2000 or more has
    envj3.texts, envj3.rect_list = {}, {}
    envj3.files["re7mp_state_in.json"] = { seq = 3000, n = 3000, p = "Em4000,3.00,0.00,3.00,0,0,0,1,100,1,2,3,4.0,200" }
    live(envj3, 0.8)
    check(not texts_have(envj3, "100 / 200"), "(10.15) bar: an ordinary Molded (maximum 200) gets no bar")
    envj3.files["re7mp_state_in.json"] = { seq = 3001, n = 3001, p = "Em4000,3.00,0.00,3.00,0,0,0,1,2400,1,2,3,4.0,3000" }
    live(envj3, 0.8)
    check(texts_have(envj3, "2400 / 3000"), "(10.15) bar: anything with a maximum of 2000 or more is a boss")
    -- far away (70 m): no bar; the nearest two of several only
    envj3.texts = {}
    envj3.files["re7mp_state_in.json"] = { seq = 3002, n = 3002, p = "Em2000,500.00,0.00,500.00,0,0,0,1,400,1,2,3,4.0,1000" }
    live(envj3, 0.8)
    check(not texts_have(envj3, "400 / 1000"), "(10.15) bar: a boss more than 70 m away has no bar")
    envj3.texts = {}
    envj3.files["re7mp_state_in.json"] = { seq = 3003, n = 3003, p = "Em2000,5.00,0.00,6.00,0,0,0,1,400,1,2,3,4.0,1000;Em3000,8.00,0.00,8.00,0,0,0,1,500,1,2,3,4.0,1000;Em3100,12.00,0.00,12.00,0,0,0,1,600,1,2,3,4.0,1000" }
    live(envj3, 0.8)
    local shown, seen = 0, {}
    for _, t in ipairs(envj3.texts) do
        if t:find("/ 1000", 1, true) and not seen[t] then seen[t] = true shown = shown + 1 end
    end
    check(shown == 2 and texts_have(envj3, "400 / 1000") and texts_have(envj3, "500 / 1000") and not texts_have(envj3, "600 / 1000"), "(10.15) bar: of three bosses only the nearest two get a bar (" .. shown .. ")")
    -- the host has been silent for more than 3 s: the bar goes
    envj3.clock = envj3.clock + 10
    envj3.texts = {}
    run_frames(envj3, 0.2)
    check(not texts_have(envj3, "/ 1000"), "(10.15) bar: the host's data is old: no bar")
end

-- =============================================================================================
-- 1h. the settings: remembered, saved, reset to the defaults
-- =============================================================================================
do
    local env = world("join", nil, { pool_follow = false, pool_bar = false, weapon_models = false })
    run_ui(env)
    check(env.seen_checks[BOX_POOL] == false and env.seen_checks[BOX_BAR] == false, "(10.15) settings: a saved 'off' for the pool and the bar is loaded")
    local env2 = world("join", nil, { pool_follow = "yes", pool_bar = 3 })
    run_ui(env2)
    check(env2.seen_checks[BOX_POOL] == true and env2.seen_checks[BOX_BAR] == true, "(10.15) settings: a value that is not true / false is ignored (both stay on)")
    local env3 = world("join")
    run_ui(env3)
    check(env3.seen_checks[BOX_POOL] == true and env3.seen_checks[BOX_BAR] == true and env3.seen_checks[BOX_MOLD] == false, "(10.15) settings: new, the pool and the bar are on and the Molded copies are off")
    env3.check_override[BOX_POOL] = false
    run_ui(env3)
    live(env3, 3)
    run_ui(env3)
    local st = env3.files["re7mp/settings.json"]
    check(st and st.pool_follow == false and st.pool_bar == true, "(10.15) settings: unticking the pool is saved (pool_follow = false)")
    check(st and st.molded_copies == nil, "(10.15) settings: the experimental Molded switch is never saved")
end

-- =============================================================================================
-- 1i. (10.16) the boss rules and the quiet check (the 20 Nov crash after the Mia fight): nothing is written to a boss unless the box says so; then lowered only, never while the
--     maxima differ, never a damage call; and nothing while a cutscene plays or the game loads
-- =============================================================================================
-- a GameManager with the loading flags and the list of running events, and a MenuManager that says whether an event is playing
local function game_state(env)
    local st = { n = 0, playing = true }
    local gm = Obj.new("app.GameManager", {}, { _CurrentChapter = 4, ["<IsSceneLoading>k__BackingField"] = false, RequestChapterJump = false, RequestPlayerChange = false,
        _GameEventMan = Obj.new("app.GameEventManager", {}, { RunningEventControllers = Obj.new("System.Collections.Generic.List`1<app.GameEventController>", { get_Count = function() return st.n end }) }) })
    env.singletons["app.GameManager"] = gm
    env.singletons["app.MenuManager"] = Obj.new("app.MenuManager", { isPlayingEvent = function() return st.playing end })
    st.gm = gm
    return st
end

do -- a boss (Em2000), the box off (the default): nothing is written, nothing is hit, the bar still shows
    local rec = {}
    local env = joiner(rec)
    host_says(env, 400, 1000)
    live(env, 2.5)
    check(#rec.set == 0 and rec.hi.f._CurrentHealth == 820, "(10.16) boss: by default a boss's health is NOT written (host 400, mine stays " .. tostring(rec.hi.f._CurrentHealth) .. ")")
    check(texts_have(env, "400 / 1000"), "(10.16) boss: ...the bar still shows the host's number")
    host_says(env, 0, 1000, 0)
    live(env, 5)
    check(#rec.hits == 0, "(10.16) boss: the host's boss is dead: still no damage call on mine (" .. #rec.hits .. " hits)")
    local bp = health(env).boss_pool
    check(bp.counts.boss_not_written >= 1 and bp.counts.boss_finish_skipped == 1 and bp.bosses_written == false, "(10.16) boss: the debug file counts it (not written " .. tostring(bp.counts.boss_not_written) .. ", finish skipped " .. tostring(bp.counts.boss_finish_skipped) .. ")")
    check(log_has(env, "the host's boss is dead; mine is left to the game's own story (no damage call on a boss)"), "(10.16) boss: ...and the journal says why mine was left alone")
end

do -- a boss, the box ticked: lowered only, never raised, never while the maxima differ, never hit
    local rec = { bosses = true }
    local env = joiner(rec)
    host_says(env, 400, 1000)
    live(env, 2)
    check(rec.hi.f._CurrentHealth == 400 and #rec.set == 1, "(10.16) boss: with the box ticked the host's 400 is written (lowered): " .. tostring(rec.hi.f._CurrentHealth))
    host_says(env, 700, 1000)
    live(env, 4)
    check(rec.hi.f._CurrentHealth == 400 and #rec.set == 1, "(10.16) boss: a boss is never RAISED (host 700, mine stays 400, " .. #rec.set .. " writes)")
    host_says(env, 300, 2000) -- (the Mia file: the host said 2000, my copy had 1000 of its own: different phases, not two difficulties)
    live(env, 3)
    check(rec.hi.f._CurrentHealth == 400 and #rec.set == 1, "(10.16) boss: the maxima differ (host 2000, mine 1000): nothing is written, and nothing is scaled (" .. tostring(rec.hi.f._CurrentHealth) .. ")")
    host_says(env, 0, 1000, 0)
    live(env, 5)
    check(#rec.hits == 0, "(10.16) boss: the host's boss dies: no damage call (" .. #rec.hits .. ")")
    local bp = health(env).boss_pool
    check(bp.counts.boss_raise_skipped >= 1 and bp.counts.boss_max_differs >= 1 and bp.counts.boss_finish_skipped == 1 and bp.bosses_written == true,
        "(10.16) boss: the counts: raise skipped " .. tostring(bp.counts.boss_raise_skipped) .. ", maxima differ " .. tostring(bp.counts.boss_max_differs) .. ", finish skipped " .. tostring(bp.counts.boss_finish_skipped))
    check(log_has(env, "health pool: Em2000 lowered 820 -> 400"), "(10.16) boss: ...and the lowering is in the journal")
    check(not log_has(env, "script error"), "(10.16) boss: no script error")
end

do -- (10.16) an event that has just started (the story hook sees it before the cutscene list does): nothing is written for 4 s
    local STORY_BOX = "Story sync: tell the other player when I start a cutscene, and show theirs (hooks app.GameManager.requestEvent). Not remembered"
    local rec = { name = "Em4100" }
    local env = joiner(rec)
    game_state(env)
    env.check_override[STORY_BOX] = true
    run_ui(env)
    local function hold(hp, secs)
        for _ = 1, math.floor(secs / 0.5 + 0.5) do host_says(env, hp, 1000) live(env, 0.5) end
    end
    live(env, 0.6)
    hold(400, 2)
    check(rec.hi.f._CurrentHealth == 400 and env.hooks["app.GameManager.requestEvent"] ~= nil, "(10.16) quiet (event): setup: the story hook is on and 400 was written")
    local idobj = Obj.new("System.String", { ["ToString()"] = function() return "c02e01_00" end })
    local xf = Obj.new("via.Transform", { get_Position = function() return vec(1, 0, 1) end })
    env.hooks["app.GameManager.requestEvent"]({ 0, Obj.new("app.GameManager", {}), idobj, xf })
    live(env, 0.3)
    local before = #rec.set
    hold(250, 2.5)
    check(#rec.set == before and rec.hi.f._CurrentHealth == 400, "(10.16) quiet (event): an event just started (no cutscene in the list yet): nothing is written for a while (" .. (#rec.set - before) .. " writes)")
    check(health(env).guard.counts.event_started >= 1, "(10.16) quiet (event): ...and the debug file counts it")
    hold(250, 3)
    check(rec.hi.f._CurrentHealth == 250, "(10.16) quiet (event): 5 s later it is written: " .. tostring(rec.hi.f._CurrentHealth))
end

do -- (10.16) an ordinary enemy: the host's dies DURING a cutscene: the finishing hit waits for a quiet moment
    local rec = { name = "Em4100" }
    local env = joiner(rec)
    local gs = game_state(env)
    local function hold(hp, secs, flags)
        for _ = 1, math.floor(secs / 0.5 + 0.5) do host_says(env, hp, 1000, flags) live(env, 0.5) end
    end
    live(env, 0.6)
    hold(400, 2)
    gs.n = 1
    live(env, 0.6)
    hold(0, 4, 0)
    check(#rec.hits == 0, "(10.16) quiet (finish): the host's enemy died during a cutscene: no damage call on mine (" .. #rec.hits .. " hits)")
    check(health(env).boss_pool.counts.held_not_quiet >= 1, "(10.16) quiet (finish): ...and the debug file counts the wait")
    gs.n = 0
    hold(0, 3, 0)
    check(#rec.hits == 0, "(10.16) quiet (finish): 3 s after the cutscene it is still too early (" .. #rec.hits .. ")")
    hold(0, 4, 0)
    check(#rec.hits >= 1, "(10.16) quiet (finish): then mine is finished (" .. #rec.hits .. " hits)")
end

for _, who in ipairs({ { "Em2000", true, "a boss" }, { "Em4100", false, "an ordinary enemy" } }) do -- the quiet check: a cutscene, a background event, a load
    local rec = { name = who[1] ~= "Em2000" and who[1] or nil, bosses = who[2] }
    local env = joiner(rec)
    local gs = game_state(env)
    local function hold(hp, secs)
        for _ = 1, math.floor(secs / 0.5 + 0.5) do host_says(env, hp, 1000) live(env, 0.5) end
    end
    live(env, 0.6)
    hold(400, 2)
    check(rec.hi.f._CurrentHealth == 400, "(10.16) quiet (" .. who[3] .. "): nothing running: written as before (" .. tostring(rec.hi.f._CurrentHealth) .. ")")
    local rd = health(env).guard
    check(rd and rd.source:find("RunningEventControllers.Count = 0", 1, true) and rd.counts.read_ok >= 1, "(10.16) quiet: the debug file says what it read: " .. tostring(rd and rd.source))
    -- a cutscene starts (c01e04_00): nothing is written however the host's number moves
    gs.n = 1
    live(env, 0.6)
    local before = #rec.set
    hold(250, 4)
    check(#rec.set == before and rec.hi.f._CurrentHealth == 400, "(10.16) quiet (" .. who[3] .. "): while a cutscene plays nothing is written (" .. (#rec.set - before) .. " writes)")
    check(health(env).boss_pool.counts.held_not_quiet >= 1, "(10.16) quiet: ...and the debug file counts what it held back")
    -- it ends: 4 s more are waited, then the number is brought in step
    gs.n = 0
    hold(250, 2)
    check(#rec.set == before, "(10.16) quiet (" .. who[3] .. "): 2 s after the cutscene is still too early")
    hold(250, 4)
    check(rec.hi.f._CurrentHealth == 250, "(10.16) quiet (" .. who[3] .. "): then it is written: " .. tostring(rec.hi.f._CurrentHealth))
    -- a background event (the game says no event is playing): not a cutscene
    gs.n, gs.playing = 1, false
    live(env, 0.6)
    hold(200, 2)
    check(rec.hi.f._CurrentHealth == 200, "(10.16) quiet (" .. who[3] .. "): a running event with isPlayingEvent false (a background event) does not stop it: " .. tostring(rec.hi.f._CurrentHealth))
    gs.n, gs.playing = 0, true
    -- a load: nothing while it lasts and for a second after
    gs.gm.f["<IsSceneLoading>k__BackingField"] = true
    live(env, 0.3)
    local b2 = #rec.set
    hold(100, 3)
    check(#rec.set == b2 and rec.hi.f._CurrentHealth == 200, "(10.16) quiet (" .. who[3] .. "): while the game loads nothing is written")
    gs.gm.f["<IsSceneLoading>k__BackingField"] = false
    hold(100, 3)
    check(rec.hi.f._CurrentHealth == 100, "(10.16) quiet (" .. who[3] .. "): after the load it is written: " .. tostring(rec.hi.f._CurrentHealth))
end

do -- the game's fields unreadable (no manager): fail open, and the debug file says so
    local rec = {}
    local env = joiner(rec)
    host_says(env, 400, 1000)
    live(env, 2)
    local rd = health(env).guard
    check(rd and rd.source:find("unreadable", 1, true) and rd.counts.read_failed >= 1, "(10.16) quiet: with no readable event list the file says 'unreadable': " .. tostring(rd and rd.source))
end

do -- the HOST: a hit on a boss is refused while a cutscene plays, applied after it
    local rec = {}
    local env = world("host", pool_setup(rec))
    local gs = game_state(env)
    live(env, 3)
    gs.n = 1
    live(env, 0.6)
    push_msgs(env, { { 9, "x|Em2000|40|-1.80|0.00|1.80" } })
    live(env, 0.5)
    local answers = messages_of_kind(env, 9)
    check(#rec.hits == 0 and answers[#answers] == "a|Em2000|refused|-1|-1", "(10.16) host: a hit on a boss during a cutscene is refused, no damage call (" .. #rec.hits .. "): " .. tostring(answers[#answers]))
    check(health(env).boss_pool.counts.host_boss_hits_refused >= 1, "(10.16) host: ...and counted")
    gs.n = 0
    live(env, 6)
    push_msgs(env, { { 9, "x|Em2000|40|-1.80|0.00|1.80" } })
    live(env, 0.5)
    check(#rec.hits >= 1, "(10.16) host: after the cutscene the same hit is applied (" .. #rec.hits .. ")")
end

-- =============================================================================================
-- 2. the other player's weapon on their body
-- =============================================================================================
local HANDGUN_MESH, HANDGUN_MDF = "Weapon/wp1210_Handgun/wp1210_Handgun", "Weapon/wp1210_Handgun/wp1210"
local KNIFE_MESH, KNIFE_MDF = "Weapon/wp1190_Knife/wp1190_Knife", "Weapon/wp1190_Knife/wp1190"
local AXE_MESH = "Weapon/wp0040_axe/wp0040_axe"

local function holder_of(path) return Obj.new("via.render.MeshResourceHolder", { get_ResourcePath = function() return path end }) end

-- One child of my player as the game has them: a game object with a mesh component, drawn or not, and where it sits in the hand
local function weapon_child(name, mesh, mdf, opts)
    opts = opts or {}
    local mc = Obj.new("via.render.Mesh", { getMesh = function() return holder_of(mesh .. ".mesh") end, get_Material = function() return holder_of(mdf .. ".mdf2") end })
    local comps = { mc }
    if opts.item then comps[#comps + 1] = Obj.new("app.Item", {}) end
    local go = make_go(name, vec(0, 0, 0), comps)
    go.drawn = opts.drawn ~= false
    go.m.get_DrawSelf = function() return go.drawn end
    go.xf.m.get_LocalPosition = function() return vec(opts.px or 0.05, opts.py or -0.02, opts.pz or 0.1) end
    go.xf.m.get_LocalRotation = function() return { w = opts.qw or 0.7071, x = 0, y = opts.qy or 0.7071, z = 0 } end
    go.xf.m.get_ParentJoint = function() return opts.joint or "R_Wep" end
    return go
end

-- hang these under the player (all at depth 1, as the debug files show)
local function give_children(env, kids)
    local p = env.player
    for i, k in ipairs(kids) do k.xf._next = kids[i + 1] and kids[i + 1].xf or nil end
    p.xf.m.get_Child = function() return kids[1] and kids[1].xf or nil end
    env.kids = kids
end

local function w17(env) return messages_of_kind(env, 17) end

do -- the sender
    local handgun = weapon_child("wp1210_Handgun_Item", HANDGUN_MESH, HANDGUN_MDF)
    local knife = weapon_child("wp1190_Knife_Item", KNIFE_MESH, KNIFE_MDF, { drawn = false, px = 0.1, py = 0, pz = 0.02 })
    handgun.drawn = false
    local light = weapon_child("wp0030_Light_Event", "Weapon/wp0030/light", "Weapon/wp0030/light", { drawn = true })
    local shadow = weapon_child("ShadowHand", "Character/Player/pl0000/pl0020/pl0020", "Character/Player/pl0000/pl0020/pl0020", { drawn = true })
    local herb = weapon_child("sm1800_HerbA_Item", "Item/sm1800/sm1800", "Item/sm1800/sm1800", { drawn = false, item = true })
    local env = world("host", function(e) give_children(e, { knife, shadow, light, handgun, herb }) end)
    live(env, 1.2)
    check(#w17(env) == 0, "(10.15) weapon: nothing in my hand (the light and the shadow hand are not weapons): nothing is sent")
    check(env.sent17 == nil, "(10.15) weapon: setup")
    local hh = health(env).weapon_models
    check(hh and hh.on == true and hh.counts.scans >= 1 and hh.counts.none >= 1 and hh.counts.sent == 0 and hh.why_not ~= nil, "(10.15) weapon: the debug file says it looked and found nothing: " .. tostring(hh and hh.why_not))

    -- the handgun comes out
    handgun.drawn = true
    live(env, 1.2)
    local m = w17(env)
    check(#m == 1, "(10.15) weapon: a weapon in the hand is sent once (" .. #m .. " messages)")
    check(m[1] == "w|" .. HANDGUN_MESH .. "|" .. HANDGUN_MDF .. "|0.050|-0.020|0.100|0.7071|0.0000|0.7071|0.0000|R_Wep",
        "(10.15) weapon: the message is the mesh, the material, the grip and the joint, extensions off: " .. tostring(m[1]))
    check(#m[1] <= 180, "(10.15) weapon: ...and short enough (" .. #m[1] .. ")")
    check(log_has(env, "weapon model: I hold wp1210_Handgun_Item (" .. HANDGUN_MESH .. "|" .. HANDGUN_MDF .. "), sent"), "(10.15) weapon: ...and the journal says what I hold")
    -- the same weapon: no new message until the keepalive
    live(env, 6)
    check(#w17(env) == 1, "(10.15) weapon: the same weapon is not sent again within 8 s (" .. #w17(env) .. ")")
    live(env, 2.5)
    check(#w17(env) == 2 and w17(env)[2] == m[1], "(10.15) weapon: ...but is repeated every 8 s for a game that joined late (" .. #w17(env) .. ")")
    -- a gun coming out leaves the knife drawn for a moment: the gun wins at once
    knife.drawn = true
    live(env, 1.2)
    check(#w17(env) == 2, "(10.15) weapon: the knife drawn next to the gun changes nothing")
    -- the gun goes away, the knife stays: it counts only after half a second
    handgun.drawn = false
    live(env, 0.3)
    check(#w17(env) == 2, "(10.15) weapon: a knife alone is not sent in the first 0.3 s (a gun coming out leaves it drawn): " .. #w17(env))
    live(env, 1.5)
    local mk = w17(env)
    check(#mk == 3 and mk[3]:find("^w|" .. KNIFE_MESH .. "|" .. KNIFE_MDF .. "|0.100|0.000|0.020|"), "(10.15) weapon: ...then it is sent: " .. tostring(mk[3]))
    -- a knife that is only there for 0.2 s while a gun is drawn does not make a message
    -- nothing in the hand any more: "w|-" once, and then nothing (not every 8 s)
    knife.drawn = false
    live(env, 1.2)
    local mn = w17(env)
    check(#mn == 4 and mn[4] == "w|-", "(10.15) weapon: an empty hand is told once: " .. tostring(mn[4]))
    live(env, 20)
    check(#w17(env) == 4, "(10.15) weapon: ...and not again (" .. #w17(env) .. " messages in all)")
    -- (10.16) the heal bottle (an app.Item that is not a wpNNNN and whose model is not a Weapon/ file) is drawn: it is NOT sent any more (the 10.15 file sent a puzzle prop as a weapon)
    herb.drawn = true
    live(env, 1.2)
    local mh = w17(env)
    check(#mh == 4, "(10.16) weapon: a drawn item such as the heal bottle (Item/ model) is not sent: " .. #mh .. " messages")
    check(health(env).weapon_models.counts.not_a_weapon >= 1, "(10.16) weapon: ...and the debug file counts it as not a weapon")
    herb.drawn = false
    live(env, 1.2)
    -- a path the wire can't carry (too long, a space): not sent, and the debug file says why
    local far = weapon_child("wp0040_axe_Item", string.rep("A", 95), "Weapon/wp0040_axe/wp0040", { drawn = true })
    handgun.drawn = false
    give_children(env, { knife, shadow, light, handgun, herb, far })
    live(env, 1.5)
    local n_before = #w17(env)
    check(n_before == 4 and w17(env)[4] == "w|-", "(10.15) weapon: setup: the empty hand after the item was told")
    local hz = health(env).weapon_models
    check(hz and hz.why_not and hz.why_not:find("a path the wire can't carry", 1, true) and hz.counts.bad_path >= 1, "(10.15) weapon: a mesh path that is too long is not sent, and says why: " .. tostring(hz and hz.why_not))
    -- the space
    local spaced = weapon_child("wp0040_axe_Item", "Weapon/my axe/wp0040", "Weapon/wp0040_axe/wp0040", { drawn = true })
    give_children(env, { knife, shadow, light, handgun, herb, spaced })
    live(env, 1.5)
    check(#w17(env) == n_before, "(10.15) weapon: a path with a space is not sent either")
    -- the second player is gone (no data from them for a while): nothing is read
    give_children(env, { knife, shadow, light, handgun, herb })
    handgun.drawn = true
    local scans0 = health(env).weapon_models.counts.scans
    for _ = 1, 100 do run_frames(env, 0.05) end -- (no bump_remote: the other player has gone quiet)
    local scans1 = env.files["re7mp/debug.json"].health.weapon_models.counts.scans
    check(scans1 - scans0 <= 3, "(10.15) weapon: with the other player gone the weapon is not looked for (" .. scans0 .. " -> " .. scans1 .. ")")
end

do -- alone, switched off, and a crash marker: no scan, no message
    local handgun = weapon_child("wp1210_Handgun_Item", HANDGUN_MESH, HANDGUN_MDF)
    local env = world("host", function(e) give_children(e, { handgun }) end, { weapon_models = false })
    live(env, 2)
    check(#w17(env) == 0, "(10.15) weapon: switched off (weapon_models = false): nothing is sent")
    run_ui(env)
    check(env.seen_checks[BOX_WMESH] == false or env.seen_checks[BOX_WMESH] == nil, "(10.15) weapon: ...and the box shows it off")
    local env2 = world("host", function(e)
        give_children(e, { handgun })
        e.files["re7mp/lastcall.json"] = { stage = "wmesh", call = "parent Weapon/x|Weapon/y on R_Wep", time = 1700000000, session = 1, clock = 1 }
    end)
    live(env2, 2)
    check(#w17(env2) == 0, "(10.15) weapon: the last session ended inside it: it is off this time, nothing is sent")
    check(log_has(env2, "putting the other player's weapon model on their body") and log_has(env2, "The weapon model is switched off this time"), "(10.15) weapon: ...and the journal says so")
    local rep = health(env2).weapon_models
    check(rep and rep.crash_marker == true and rep.status:find("the last session ended inside it", 1, true), "(10.15) weapon: ...and so does the debug file: " .. tostring(rep and rep.status))
end

do -- the receiver's message check
    local env = world("join")
    local function say17(p) push_msgs(env, { { 17, p } }) live(env, 0.3) end
    local function rep() return health(env).weapon_models end
    local GOOD = "w|" .. HANDGUN_MESH .. "|" .. HANDGUN_MDF .. "|0.050|-0.020|0.100|0.7071|0.0000|0.7071|0.0000|R_Wep"
    say17(GOOD)
    local r = rep()
    check(r.they_hold and r.they_hold.mesh == HANDGUN_MESH and r.they_hold.material == HANDGUN_MDF and r.they_hold.joint == "R_Wep", "(10.15) weapon: a good message is taken: " .. tostring(r.they_hold and r.they_hold.mesh))
    check(r.they_hold.grip == "0.050 -0.020 0.100 0.7071 0.0000 0.7071 0.0000 R_Wep" and r.counts.received == 1 and r.counts.rejected == 0, "(10.15) weapon: ...with its grip: " .. tostring(r.they_hold.grip))
    local function rejected_by(p, why)
        local before = rep().counts.rejected
        say17(p)
        local after = rep()
        check(after.counts.rejected == before + 1 and after.they_hold and after.they_hold.mesh == HANDGUN_MESH, "(10.15) weapon: rejected, and the weapon I have stays: " .. why)
    end
    rejected_by("w|../../etc/passwd|=|0|0|0|1|0|0|0|R_Wep", "a path with ..")
    rejected_by("w|/Weapon/x|=|0|0|0|1|0|0|0|R_Wep", "a path that starts with /")
    rejected_by("w|Weapon//x|=|0|0|0|1|0|0|0|R_Wep", "a path with //")
    rejected_by("w|Weapon/my axe/x|=|0|0|0|1|0|0|0|R_Wep", "a path with a space")
    rejected_by("w|Weapon/x;rm|=|0|0|0|1|0|0|0|R_Wep", "a path with a semicolon")
    rejected_by("w|" .. string.rep("a", 91) .. "|=|0|0|0|1|0|0|0|R_Wep", "a path of 91 characters")
    rejected_by("w|ab|=|0|0|0|1|0|0|0|R_Wep", "a path of 2 characters")
    rejected_by("w|Weapon/x|Weapon/y|4.5|0|0|1|0|0|0|R_Wep", "a position 4.5 m from the joint")
    rejected_by("w|Weapon/x|Weapon/y|0|0|0|0|0|0|0|R_Wep", "a rotation of nothing (all zeros)")
    rejected_by("w|Weapon/x|Weapon/y|0|0|0|1|0|0|0|R Wep", "a joint with a space")
    rejected_by("w|Weapon/x|Weapon/y|0|0|0|1|0|0|0|" .. string.rep("J", 25), "a joint name of 25 characters")
    rejected_by("w|Weapon/x|Weapon/y|0|0|0|1|0|0|R_Wep", "a message with a field missing")
    rejected_by("w|Weapon/x|Weapon/y|0|0|0|1|0|0|abc|R_Wep", "a number that is not one")
    rejected_by("w|Weapon/x|Weapon/y|1e9|0|0|1|0|0|0|R_Wep", "an exponent")
    rejected_by("x|Weapon/x|=|0|0|0|1|0|0|0|R_Wep", "a message that is not 'w|'")
    -- the rotation is made a unit: (2, 0, 0, 0) is the same as (1, 0, 0, 0)
    say17("w|Weapon/x|=|0.1|0.2|0.3|2|0|0|0|R_Hand")
    r = rep()
    check(r.they_hold.mesh == "Weapon/x" and r.they_hold.material == "Weapon/x" and r.they_hold.grip == "0.100 0.200 0.300 1.0000 0.0000 0.0000 0.0000 R_Hand", "(10.15) weapon: '=' is the mesh's name, and the rotation is made a unit: " .. tostring(r.they_hold.grip))
    -- nothing in their hand
    say17("w|-")
    check(rep().they_hold == nil, "(10.15) weapon: 'w|-' means nothing in their hand")
    check(not log_has(env, "script error"), "(10.15) weapon: no script error")
end

-- ---------------------------------------------------------------------------------------------
-- the receiver's copy: a world with a made body (the body lab makes it, as in the 9.23 checks) and a game that makes objects
-- ---------------------------------------------------------------------------------------------
local JOINTS = { "root", "Hip", "Spine", "Chest", "Neck", "Head", "R_Shoulder", "R_UpperArm", "R_Elbow", "R_Wrist", "R_Hand", "R_Wep", "L_Shoulder", "L_Hand", "L_Wep" }

local function body_world(opts)
    opts = opts or {}
    local env = new_environment()
    build_world(env)
    local JOINTS = opts.joints or JOINTS
    if opts.before_load then opts.before_load(env) end
    local rec = { made = {}, destroyed = {}, weapons = {}, mesh_ready = false, order = {}, opts = opts }
    local function src_mesh(path)
        local h, mh = holder_of(path), holder_of((path:gsub("%.mesh$", ".mdf2")))
        return Obj.new("via.render.Mesh", { getMesh = function() return h end, get_Material = function() return mh end,
            get_Enabled = function() return true end, get_MaterialNum = function() return 2 end })
    end
    local function joint_objs(names)
        local out = {}
        for i, n in ipairs(names) do out[i] = Obj.new("via.Joint", { get_Name = function() return n end, get_Parent = function() return nil end }) end
        return out
    end
    local function with_joints(go, names)
        local js = joint_objs(names)
        go.xf.m.get_Joints = function() return { get_elements = function() return js end } end
        return go
    end
    local root = with_joints(make_go("Pl0000_Chapter1", vec(-48.2, 4.88, 118.93), { src_mesh("Character/Player/pl0000/pl0001/pl0001.mesh") }), JOINTS)
    env.scene_objects[#env.scene_objects + 1] = root
    H.get_types()["via.GameObject"] = { get_full_name = function() return "via.GameObject" end, get_fields = function() return {} end,
        get_parent_type = function() return nil end, get_methods = function() return {} end,
        get_method = function(_, mname)
            if mname == "create(System.String)" then
                return { call = function(_, obj, name)
                    if opts.create_fails and name == "re7mp_weapon" then return nil end
                    local go
                    if name == "re7mp_weapon" then
                        go = make_go(name, vec(0, 0, 0), {})
                        local w = { go = go, name = name, draw_self = nil, parent = nil, joint = nil, same = nil, calls = {} }
                        rec.weapons[#rec.weapons + 1] = w
                        go.w = w
                        go.m.set_DrawSelf = function(_, v) w.draw_self = v w.calls[#w.calls + 1] = "set_DrawSelf " .. tostring(v) rec.order[#rec.order + 1] = "draw:" .. tostring(v) end
                        go.m.createComponent = function(_, t)
                            if opts.no_component then error("fake: createComponent refused") end
                            local st = {}
                            local mc = Obj.new("via.render.Mesh", {
                                setMesh = function(_, h) st.mesh = h end, getMesh = function() return st.mesh end,
                                set_Material = function(_, h) st.mat = h end, get_Material = function() return st.mat end,
                                get_MeshReady = function() return rec.mesh_ready end,
                                set_DrawDefault = function(_, v) st.draw_default = v end, set_Enabled = function(_, v) st.enabled = v end })
                            w.mc, w.st = mc, st
                            return mc
                        end
                        go.xf.m.set_Parent = function(_, p) w.parent = p rec.order[#rec.order + 1] = p and "parent" or "unparent" end
                        go.xf.m.set_SameJointsConstraint = function(_, v) w.same = v end
                        go.xf.m.set_ParentJoint = function(_, j)
                            if opts.joint_fails then error("fake: set_ParentJoint refused") end
                            w.joint = j
                            rec.order[#rec.order + 1] = "joint"
                        end
                        go.xf.m.get_ParentJoint = function() return w.joint end
                        go.xf.m.set_LocalPosition = function(_, v) w.lpos = v end
                        go.xf.m.set_LocalRotation = function(_, q) w.lrot = q end
                    else
                        go = with_joints(make_go(name, vec(0, 0, 0), {}), JOINTS)
                        go.m.createComponent = function(_, t)
                            local st = {}
                            local mc = Obj.new("via.render.Mesh", {
                                setMesh = function(_, h) st.mesh = h end, getMesh = function() return st.mesh end,
                                set_Material = function(_, h) st.mat = h end, get_Material = function() return st.mat end,
                                get_MeshReady = function() return true end, get_Enabled = function() return true end,
                                get_DrawDefault = function() return true end, get_HasJoint = function() return true end, get_MaterialNum = function() return 2 end })
                            go.mc = mc
                            return mc
                        end
                        go.xf.m.getJointByName = function() return nil end
                        go.xf.m.set_Parent = function() end
                        go.xf.m.set_LocalScale = function() end
                        go.xf.m.set_LocalPosition = function() end
                        go.xf.m.set_SameJointsConstraint = function() end
                    end
                    rec.made[#rec.made + 1] = go
                    return go
                end }
            elseif mname == "destroy(via.GameObject)" then
                return { call = function(_, obj, go)
                    local nm = go.m.get_Name()
                    rec.destroyed[#rec.destroyed + 1] = nm
                    rec.order[#rec.order + 1] = "destroy:" .. nm
                    if go.w then go.w.destroyed = true end
                end }
            end
        end }
    env.scene = make_scene(env.scene_objects)
    -- (the real-body switch is on so that the panel of the other player's body, with the weapon box, is drawn; the lab makes the body the checks use)
    env.files["re7mp/settings.json"] = opts.settings or { real_body = true, real_body_set = true }
    load_script(env)
    host_role_files(env, opts.role or "join", "tcp")
    for _ = 1, 40 do run_frames(env, 0.05) bump_remote(env) end
    run_ui(env)
    rec.phase = function(nm) nm = nm or "UpdateBehavior" if env.phase_cbs["pre:" .. nm] then env.phase_cbs["pre:" .. nm]() end end
    env.check_override["Switch the body lab on"] = true
    run_ui(env)
    rec.phase()
    env.ui_press["2. Make the body (a new object with Ethan's body mesh, beside you)"] = true
    run_ui(env)
    rec.phase()
    rec.body = rec.made[1]
    return env, rec, root
end

local function weapon_copies(rec, live_only)
    local out = {}
    for _, w in ipairs(rec.weapons) do
        if not (live_only and w.destroyed) then out[#out + 1] = w end
    end
    return out
end

-- run frames and game phases together (the weapon is made in the game phase, never in the render frame)
local function tick(env, rec, secs)
    for _ = 1, math.floor(secs / 0.05 + 0.5) do
        run_frames(env, 0.05)
        bump_remote(env)
        rec.phase()
    end
end

local GOOD = "w|" .. HANDGUN_MESH .. "|" .. HANDGUN_MDF .. "|0.050|-0.020|0.100|0.7071|0.0000|0.7071|0.0000|R_Wep"
local AXE = "w|" .. AXE_MESH .. "|=|0.000|0.000|0.050|1.0000|0.0000|0.0000|0.0000|R_Wep"

do
    local env, rec = body_world()
    check(rec.body and rec.body.m.get_Name() == "re7mp_body", "(10.15) copy: setup: the body is made")
    check(env.seen_checks[BOX_WMESH] == true, "(10.15) copy: the weapon box is in the panel of the other player's body and starts ticked: " .. tostring(env.seen_checks[BOX_WMESH]))
    -- (the debug file is rewritten every 2 s: two looks, so that the second one has the state of the game phase work done just before)
    local wm = function() health(env) return health(env).weapon_models end
    check(#rec.weapons == 0, "(10.15) copy: with nothing sent there is no copy")
    -- the other player's handgun arrives
    push_msgs(env, { { 17, GOOD } })
    run_frames(env, 0.3)
    check(#rec.weapons == 0, "(10.15) copy: a message alone makes nothing (the copy is made in the game phase)")
    rec.phase("LockScene")
    check(#rec.weapons == 0, "(10.15) copy: ...and not in the other phase")
    rec.phase()
    check(#rec.weapons == 1 and rec.weapons[1].name == "re7mp_weapon", "(10.15) copy: in the game phase ONE object is made")
    local w = rec.weapons[1]
    check(w and w.mc and w.st.mesh and w.st.mat, "(10.15) copy: ...with a mesh component that was given the mesh and the material")
    check(env.resources and env.resources.made[1] == "via.render.MeshResource " .. HANDGUN_MESH .. ".mesh" and env.resources.made[2] == "via.render.MeshMaterialResource " .. HANDGUN_MDF .. ".mdf2",
        "(10.15) copy: ...from the two files by path: " .. tostring(env.resources and env.resources.made[1]) .. " / " .. tostring(env.resources and env.resources.made[2]))
    check(w.draw_self == false and w.parent == nil, "(10.15) copy: while the mesh loads it is hidden and not on the body (draw " .. tostring(w.draw_self) .. ")")
    check(env.crumb_log and (function() for _, c in ipairs(env.crumb_log) do if c:find("wmesh: make " .. HANDGUN_MESH, 1, true) then return true end end end)(), "(10.15) copy: the crash marker had the step before the game call")
    for _ = 1, 5 do rec.phase() end
    check(w.parent == nil and #rec.weapons == 1, "(10.15) copy: still loading: not parented, and no second copy is made")
    local r1 = wm()
    check(r1.status == "loading " .. HANDGUN_MESH .. "|" .. HANDGUN_MDF and r1.copy and r1.copy.parented == false, "(10.15) copy: the debug file says it is loading: " .. tostring(r1.status))
    -- the mesh is loaded
    rec.mesh_ready = true
    rec.phase()
    check(w.parent == rec.body.xf, "(10.15) copy: loaded: it is hung on the other player's body")
    check(w.joint == "R_Wep" and w.same == false, "(10.15) copy: ...on the joint R_Wep, with SameJointsConstraint off")
    check(w.lpos and math.abs(w.lpos.x - 0.05) < 1e-6 and math.abs(w.lpos.y + 0.02) < 1e-6 and math.abs(w.lpos.z - 0.1) < 1e-6, "(10.15) copy: ...with the local position of the sender's grip")
    check(w.lrot and math.abs(w.lrot.w - 0.7071) < 1e-3 and math.abs(w.lrot.y - 0.7071) < 1e-3, "(10.15) copy: ...and its local rotation (a quaternion w, x, y, z)")
    check(w.draw_self == true and w.st.draw_default == true and w.st.enabled == true, "(10.15) copy: ...and only then drawn")
    local order = table.concat(rec.order, ",")
    check(order:find("draw:false,parent,joint,draw:true", 1, true), "(10.15) copy: the order is hidden, parent, joint, drawn: " .. order)
    check(env.crumb_log[#env.crumb_log]:find("clean: weapon model: on the hand", 1, true), "(10.15) copy: ...and the crash marker says clean afterwards: " .. tostring(env.crumb_log[#env.crumb_log]))
    local r2 = wm()
    check(r2.status == "on the hand: " .. HANDGUN_MESH .. "|" .. HANDGUN_MDF and r2.copy and r2.copy.parented == true and r2.copy.joint == "R_Wep" and r2.counts.made == 1 and r2.counts.parented == 1,
        "(10.15) copy: the debug file says it is on the hand: " .. tostring(r2.status))
    -- the same message again (the 8 s keepalive): nothing changes
    local n_made = #rec.made
    for _ = 1, 3 do
        push_msgs(env, { { 17, GOOD } })
        tick(env, rec, 1)
    end
    check(#rec.made == n_made and #rec.destroyed == 0, "(10.15) copy: the same weapon again changes nothing")
    -- the grip changes a little (the sender's numbers moved): it is put again, at most once a second
    push_msgs(env, { { 17, "w|" .. HANDGUN_MESH .. "|" .. HANDGUN_MDF .. "|0.060|-0.020|0.100|0.7071|0.0000|0.7071|0.0000|R_Wep" } })
    tick(env, rec, 1.5)
    check(math.abs(w.lpos.x - 0.06) < 1e-6 and #rec.made == n_made, "(10.15) copy: a new grip is applied to the same copy")
    check(wm().counts.regrip == 1, "(10.15) copy: ...and counted")
    -- a different weapon: the old copy goes first (detached, hidden, destroyed), then the new one is made
    push_msgs(env, { { 17, AXE } })
    run_frames(env, 0.3)
    rec.phase()
    check(w.parent == nil and w.draw_self == false and w.destroyed == true, "(10.15) copy: another weapon: the old copy is detached, hidden and destroyed")
    check(#rec.weapons == 1 or #rec.weapons == 2, "(10.15) copy: setup (" .. #rec.weapons .. " copies so far)")
    tick(env, rec, 2.5)
    local copies = weapon_copies(rec, true)
    check(#copies == 1 and copies[1] ~= w, "(10.15) copy: ...and ONE new copy is made for the axe")
    check(copies[1] and copies[1].parent == rec.body.xf and copies[1].lpos and math.abs(copies[1].lpos.z - 0.05) < 1e-6, "(10.15) copy: ...hung on the hand, with the axe's grip")
    check(env.resources.made[#env.resources.made]:find("wp0040_axe.mdf2", 1, true) or env.resources.made[#env.resources.made - 1]:find("wp0040_axe.mesh", 1, true), "(10.15) copy: ...from the axe's files ('=' meant the material file has the mesh's name)")
    -- nothing in their hand
    push_msgs(env, { { 17, "w|-" } })
    tick(env, rec, 0.5)
    check(#weapon_copies(rec, true) == 0, "(10.15) copy: 'w|-': the copy is taken down: none left")
    check(wm().status == "nothing in their hand", "(10.15) copy: ...and the status says nothing in their hand: " .. tostring(wm().status))
    -- the weapon comes back: a copy is made again (after the 2 s between makes)
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 3)
    check(#weapon_copies(rec, true) == 1 and weapon_copies(rec, true)[1].parent == rec.body.xf, "(10.15) copy: the weapon comes back: a new copy is on the hand")
    -- no message for 30 s: the copy goes
    tick(env, rec, 31)
    check(#weapon_copies(rec, true) == 0, "(10.15) copy: no word from them for 30 s: the copy is taken down")
    check(wm().counts.expired == 1, "(10.15) copy: ...and the debug file counts it")
    check(not log_has(env, "script error"), "(10.15) copy: no script error")
end

do -- the body goes away: the copy goes first
    local env, rec = body_world()
    rec.mesh_ready = true
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 1.5)
    local w = rec.weapons[1]
    check(w and w.parent == rec.body.xf and w.draw_self == true, "(10.15) copy: setup: on the hand at once when the mesh is ready")
    env.ui_press["4. Remove the body"] = true
    run_ui(env)
    rec.phase()
    local order = table.concat(rec.order, ",")
    check(w.destroyed == true and order:find("unparent,draw:false,destroy:re7mp_weapon", 1, true), "(10.15) copy: removing the body takes the copy down first: " .. order)
    local i_weapon, i_body = order:find("destroy:re7mp_weapon", 1, true), order:find("destroy:re7mp_body", 1, true)
    check(i_weapon and i_body and i_weapon < i_body, "(10.15) copy: ...before the body is destroyed")
    check(#weapon_copies(rec, true) == 0, "(10.15) copy: ...and none is left")
    -- a new body: a new copy (the copy is never kept from the old body)
    env.ui_press["2. Make the body (a new object with Ethan's body mesh, beside you)"] = true
    run_ui(env)
    rec.phase()
    tick(env, rec, 3)
    local c2 = weapon_copies(rec, true)
    check(#c2 == 1 and c2[1] ~= w and c2[1].parent == rec.made[#rec.made - 1].xf or (#c2 == 1 and c2[1] ~= w and c2[1].parent ~= nil), "(10.15) copy: a new body gets a new copy")
end

do -- the scene changes: the game took the objects, so they are let go and nothing is destroyed
    local env, rec = body_world()
    rec.mesh_ready = true
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 1.5)
    local w = rec.weapons[1]
    local d0 = #rec.destroyed
    env.scene = make_scene(env.scene_objects) -- a new scene object
    rec.phase()
    check(#rec.destroyed == d0, "(10.15) copy: a scene change destroys nothing (the game took the objects with the scene)")
    local r = health(env).weapon_models
    check(r.counts.forgotten == 1 and r.copy == nil, "(10.15) copy: ...the copy is let go and counted (forgotten " .. tostring(r.counts.forgotten) .. ")")
    tick(env, rec, 3)
    local bodies = {}
    for _, g in ipairs(rec.made) do if g.m.get_Name() == "re7mp_body" then bodies[#bodies + 1] = g end end
    check(#bodies == 2 and #rec.weapons == 2 and rec.weapons[2].parent == bodies[2].xf and rec.weapons[2].draw_self == true,
        "(10.15) copy: ...the body is made again in the new scene and the weapon is put on THAT body (" .. #bodies .. " bodies, " .. #rec.weapons .. " copies)")
    check(w.destroyed ~= true and #rec.destroyed == d0, "(10.15) copy: ...and the old copy was never touched again")
end


-- ---------------------------------------------------------------------------------------------
-- what goes wrong, and what the script does about it
-- ---------------------------------------------------------------------------------------------
-- as tick(), and the other player's keepalive (the sender repeats its message every 8 s)
local function keep(env, rec, secs, msg)
    local left = secs
    while left > 0 do
        push_msgs(env, { { 17, msg } })
        local step = math.min(5, left)
        tick(env, rec, step)
        left = left - step
    end
end

do -- the mesh never loads: 10 s, hidden and detached, three tries, then left alone; another weapon starts fresh
    local env, rec = body_world()
    keep(env, rec, 10.5, GOOD)
    check(#rec.weapons == 2 and rec.weapons[1].parent == nil and rec.weapons[1].draw_self == false, "(10.15) copy: a mesh that is not loaded after 10 s: the first copy was never put on the body, and is hidden (" .. #rec.weapons .. " copies)")
    check(rec.weapons[1].destroyed ~= true, "(10.15) copy: ...and NOT destroyed while its mesh is still loading (destroying a loading mesh could crash the game)")
    check(log_has(env, "the mesh did not load in 10 s (try 1 of 3)"), "(10.15) copy: ...and the journal says which try it was")
    keep(env, rec, 25, GOOD)
    check(#rec.weapons == 3, "(10.15) copy: three tries are made in all (" .. #rec.weapons .. " objects)")
    local r = health(env).weapon_models
    check(r.counts.timeouts == 3 and r.counts.kept_loading == 3 and r.status:find("^gave up on"), "(10.15) copy: then it gives up and says so: " .. tostring(r.status))
    check(r.failed_tries and r.failed_tries[HANDGUN_MESH .. "|" .. HANDGUN_MDF] == 3, "(10.15) copy: ...the failed tries are listed per weapon")
    keep(env, rec, 20, GOOD)
    check(#rec.weapons == 3, "(10.15) copy: no fourth try")
    -- a different weapon has its own tries, and works once the mesh is ready
    rec.mesh_ready = true
    push_msgs(env, { { 17, AXE } })
    tick(env, rec, 3)
    check(#rec.weapons == 4 and rec.weapons[4].parent == rec.body.xf and rec.weapons[4].draw_self == true, "(10.15) copy: another weapon is tried afresh and is put on the hand")
    check(not log_has(env, "script error"), "(10.15) copy: no script error")
end

do -- a file the game does not have
    local env, rec = body_world({ before_load = function(e) end })
    env.resources = { made = {}, refuse = { [HANDGUN_MESH .. ".mesh"] = true } }
    keep(env, rec, 12, GOOD)
    check(#rec.weapons == 0, "(10.15) copy: a mesh file the game cannot find: no object is made")
    local r = health(env).weapon_models
    check(r.counts.load_failed >= 2 and r.failed_tries[HANDGUN_MESH .. "|" .. HANDGUN_MDF] >= 2, "(10.15) copy: ...the failures are counted (" .. tostring(r.counts.load_failed) .. ")")
    check(log_has(env, "a file would not load (the game found no such resource)"), "(10.15) copy: ...with the game's reason")
    keep(env, rec, 12, GOOD)
    r = health(env).weapon_models
    check(r.status:find("^gave up on") and r.failed_tries[HANDGUN_MESH .. "|" .. HANDGUN_MDF] == 3, "(10.15) copy: three failures: given up: " .. tostring(r.status))
    -- the other weapon is fine
    push_msgs(env, { { 17, AXE } })
    rec.mesh_ready = true
    tick(env, rec, 3)
    check(#weapon_copies(rec, true) == 1, "(10.15) copy: a weapon whose files do load still works after that")
end

do -- the last session ended in the loader: loading by path is off, and so no weapon is made
    local env, rec = body_world({ before_load = function(e) e.files["re7mp/lastcall.json"] = { stage = "loader", call = "mesh x", time = 1700000000, session = 1, clock = 1 } end })
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 8)
    check(#rec.weapons == 0 and log_has(env, "loading model files by path is switched off"), "(10.15) copy: with loading by path switched off (a crash in the loader) no copy is made, and it says why")
end

do -- the game will not make an object / a component
    local env, rec = body_world({ create_fails = true })
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 12)
    check(#rec.weapons == 0 and log_has(env, "no object (the game answered nothing)"), "(10.15) copy: a create that answers nothing: reported, nothing left behind")
    local env2, rec2 = body_world({ no_component = true })
    push_msgs(env2, { { 17, GOOD } })
    tick(env2, rec2, 3)
    check(#rec2.weapons >= 1 and rec2.weapons[1].destroyed == true and rec2.weapons[1].draw_self == false, "(10.15) copy: a component the game refuses: the half-made object is hidden and destroyed")
    check(log_has(env2, "no mesh component"), "(10.15) copy: ...and the journal says so")
end

do -- no joint to hang it on
    local env, rec = body_world({ joints = { "root", "Hip", "Spine", "Chest", "Neck", "Head", "R_Shoulder", "R_UpperArm", "R_Elbow", "L_Hand", "L_Wep", "L_Shoulder" } })
    rec.mesh_ready = true
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 3)
    check(#rec.weapons == 1 and rec.weapons[1].parent == nil and rec.weapons[1].destroyed == true, "(10.15) copy: a body with no right-hand joint: the copy is never parented, and is taken down")
    check(log_has(env, "the body has none of R_Wep, R_Wep, R_Hand, R_Wrist (hand-like joints it has: L_Hand L_Wep)"), "(10.15) copy: ...the journal names the joints the body does have that look like hands")
    tick(env, rec, 10)
    check(#rec.weapons == 1, "(10.15) copy: ...and it does not try again for that weapon (the body will not grow a joint)")
    check(health(env).weapon_models.counts.no_joint == 1, "(10.15) copy: ...counted once")
    -- another joint does for it: the sender's joint, else R_Hand, else R_Wrist
    local env2, rec2 = body_world({ joints = { "root", "Hip", "Spine", "Chest", "Neck", "Head", "R_Shoulder", "R_UpperArm", "R_Elbow", "R_Wrist", "R_Hand", "L_Hand" } })
    rec2.mesh_ready = true
    push_msgs(env2, { { 17, GOOD } })
    tick(env2, rec2, 3)
    check(rec2.weapons[1] and rec2.weapons[1].joint == "R_Hand", "(10.15) copy: no R_Wep: it goes on R_Hand")
    push_msgs(env2, { { 17, "w|" .. AXE_MESH .. "|=|0|0|0|1|0|0|0|R_Wrist" } })
    tick(env2, rec2, 3)
    local c = weapon_copies(rec2, true)
    check(#c == 1 and c[1].joint == "R_Wrist", "(10.15) copy: the sender's own joint is used when this body has it (R_Wrist)")
end

do -- the game refuses the parenting: hidden, detached, destroyed, three tries
    local env, rec = body_world({ joint_fails = true })
    rec.mesh_ready = true
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 12)
    check(#rec.weapons == 3, "(10.15) copy: a parenting the game refuses: three tries (" .. #rec.weapons .. ")")
    local all_gone = true
    for _, w in ipairs(rec.weapons) do
        if not (w.destroyed and w.draw_self == false and w.parent == nil) then all_gone = false end
    end
    check(all_gone, "(10.15) copy: ...and every failed copy is detached, hidden and destroyed")
    check(log_has(env, "parenting failed") and env.crumb_log[#env.crumb_log]:find("clean", 1, true), "(10.15) copy: ...with the crash marker cleaned")
end

do -- switched off with a copy up; and the crash marker of a session that ended inside the weapon work
    local env, rec = body_world()
    rec.mesh_ready = true
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 2)
    check(#weapon_copies(rec, true) == 1, "(10.15) copy: setup: a copy is up")
    env.check_override[BOX_WMESH] = false
    run_ui(env)
    tick(env, rec, 0.5)
    check(#weapon_copies(rec, true) == 0 and rec.weapons[1].destroyed == true, "(10.15) copy: the box unticked: the copy is taken down")
    check(health(env).weapon_models.status == "off", "(10.15) copy: ...and the status says off")
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 5)
    check(#rec.weapons == 1, "(10.15) copy: ...and no new copy is made while it is off")
    env.check_override[BOX_WMESH] = true
    run_ui(env)
    tick(env, rec, 3)
    check(#weapon_copies(rec, true) == 1, "(10.15) copy: ticked again: a copy is made again")
    run_ui(env)
    run_frames(env, 3)
    check(env.files["re7mp/settings.json"].weapon_models == true, "(10.15) copy: ...and the box is saved (weapon_models)")
end

do -- a crash marker at the start: the box is ticked by hand to try again
    local env, rec = body_world({ before_load = function(e) e.files["re7mp/lastcall.json"] = { stage = "wmesh", call = "parent X on R_Wep", time = 1700000000, session = 1, clock = 1 } end })
    rec.mesh_ready = true
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 4)
    check(#rec.weapons == 0, "(10.15) copy: the last session ended inside the weapon work: no copy is made")
    env.check_override[BOX_WMESH] = false
    run_ui(env)
    env.check_override[BOX_WMESH] = true
    run_ui(env)
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 3)
    check(#weapon_copies(rec, true) == 1, "(10.15) copy: ...ticking the box again (by hand) tries again")
    check(health(env).weapon_models.crash_marker == nil, "(10.15) copy: ...and the marker is forgiven")
end

do -- the other player's body is gone and comes back (the lab removes it; here: the weapon message arrives with no body at all)
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "join", "tcp")
    for _ = 1, 20 do run_frames(env, 0.05) bump_remote(env) end
    push_msgs(env, { { 17, GOOD } })
    live(env, 2)
    local r = health(env).weapon_models
    check(r.they_hold and r.they_hold.mesh == HANDGUN_MESH and r.copy == nil, "(10.15) copy: with no body of the other player the message is kept and nothing is made")
end

do -- (10.16) the sender waits for a quiet moment; the chainsaw of the Jack fight is never sent
    local handgun = weapon_child("wp1210_Handgun_Item", HANDGUN_MESH, HANDGUN_MDF)
    handgun.drawn = false
    local saw = weapon_child("wp0060_ChainSaw_Item", "Weapon/wp0060_ChainSaw/wp0060_ChainSaw", "Weapon/wp0060_ChainSaw/wp0060", { drawn = false })
    local env = world("host", function(e) give_children(e, { handgun, saw }) end)
    local gs = game_state(env)
    live(env, 1.2)
    gs.n = 1 -- a cutscene
    live(env, 0.6)
    handgun.drawn = true
    live(env, 3)
    check(#w17(env) == 0, "(10.16) weapon: during a cutscene the player's children are not walked and nothing is sent (" .. #w17(env) .. ")")
    local hz = health(env).weapon_models
    check(hz.counts.scans_held_not_quiet >= 1 and tostring(hz.why_not):find("^waiting: a cutscene is playing"), "(10.16) weapon: ...and the debug file says it is waiting: " .. tostring(hz.why_not))
    gs.n = 0
    live(env, 2.5)
    check(#w17(env) == 0, "(10.16) weapon: 2.5 s after the cutscene it is still waiting (" .. #w17(env) .. ")")
    live(env, 3)
    check(#w17(env) == 1, "(10.16) weapon: then the weapon is sent (" .. #w17(env) .. ")")
    handgun.drawn = false
    live(env, 1.5)
    check(#w17(env) == 2 and w17(env)[2] == "w|-", "(10.16) weapon: setup: the empty hand is told")
    saw.drawn = true
    live(env, 3)
    check(#w17(env) == 2, "(10.16) weapon: the chainsaw (wp0060) is never sent (" .. #w17(env) .. " messages)")
    local hs = health(env).weapon_models
    check(hs.counts.skipped_named >= 1 and tostring(hs.skipped_last):find("chainsaw", 1, true), "(10.16) weapon: ...and the file says it was skipped on purpose: " .. tostring(hs.skipped_last))
end

do -- (10.16) the receiver waits, lets go during a load, refuses the chainsaw, and makes at most 12 copies a minute
    local env, rec = body_world()
    local gs = game_state(env)
    rec.mesh_ready = true
    gs.n = 1
    tick(env, rec, 0.6) -- (the script looks at the game's events four times a second: the cutscene has to be seen first)
    push_msgs(env, { { 17, GOOD } })
    tick(env, rec, 3)
    check(#rec.weapons == 0 and tostring(health(env).weapon_models.status):find("^waiting: a cutscene is playing"), "(10.16) copy: during a cutscene no copy is made, and it says it is waiting: " .. tostring(health(env).weapon_models.status))
    gs.n = 0
    tick(env, rec, 3)
    check(#rec.weapons == 0, "(10.16) copy: 3 s after the cutscene it is still too early")
    tick(env, rec, 3)
    check(#rec.weapons == 1 and rec.weapons[1].parent == rec.body.xf, "(10.16) copy: then it is made and put on the hand (" .. #rec.weapons .. ")")
    push_msgs(env, { { 17, "w|Weapon/wp0060_ChainSaw/wp0060_ChainSaw|=|0.000|0.000|0.050|1.0000|0.0000|0.0000|0.0000|R_Wep" } })
    tick(env, rec, 2)
    local r = health(env).weapon_models
    check(r.they_hold and r.they_hold.mesh == HANDGUN_MESH and r.counts.skipped_named >= 1 and #rec.weapons == 1, "(10.16) copy: the chainsaw on the wire is ignored: they still hold the handgun here")
    gs.gm.f["<IsSceneLoading>k__BackingField"] = true
    tick(env, rec, 1.5)
    r = health(env).weapon_models
    check(r.counts.forgotten >= 1 and rec.weapons[1].destroyed ~= true and r.copy == nil, "(10.16) copy: while the game loads the copy is let go and never touched (forgotten " .. tostring(r.counts.forgotten) .. ")")
    check(not log_has(env, "script error"), "(10.16) copy: no script error")
end

do -- at most MAKES_PER_MIN copies in a minute
    local env, rec = body_world()
    rec.mesh_ready = true
    for i = 1, 16 do
        push_msgs(env, { { 17, (i % 2 == 1) and GOOD or AXE } })
        tick(env, rec, 2.5)
    end
    local r = health(env).weapon_models
    check(#rec.weapons <= 12 and r.counts.churn_held >= 1, "(10.16) copy: a weapon that flips in and out of the hand makes at most 12 copies in a minute (" .. #rec.weapons .. " made, " .. tostring(r.counts.churn_held) .. " held back)")
end

-- =============================================================================================
-- 2c. (10.16) the garage car probe: reads the type app.CarInGarage and three readings of its object; changes nothing
-- =============================================================================================
do
    local BOX_CAR = "Garage car probe (reads only): writes the type app.CarInGarage and, once the garage's car exists, 3 readings of it to re7mp/car_probe.json (not remembered)##carprobe"
    local writes, looks, cars = 0, 0, {}
    local car_pos = { x = 1.5, y = 0.2, z = -7.25 }
    local car_go = Obj.new("via.GameObject", {
        get_Name = function() return "CarInGarage_Ethan" end,
        get_Transform = function() return Obj.new("via.Transform", { get_Position = function() return vec(car_pos.x, car_pos.y, car_pos.z) end }) end,
        get_Components = function() return { get_elements = function() return { Obj.new("app.CarInGarage", {}), Obj.new("via.render.Mesh", {}) } end } end,
    })
    local car = Obj.new("app.CarInGarage", { get_GameObject = function() return car_go end }, { Speed = 0.0, Gear = 1, Driver = Obj.new("app.CharacterBase", {}), Seat = vec(0.1, 0.2, 0.3), Label = "garage car" })
    car.set_field = function() writes = writes + 1 end
    local env = world("host")
    env.combo_override["Enemy sync"] = 2 -- (10.22: mode 3 is the default now and the garage car sync (mode 3) looks for the car too: the probe's own looks are counted in mode 2)
    run_ui(env)
    make_td("app.CarInGarage", {
        fields = { { "Speed", "System.Single" }, { "Gear", "System.Int32" }, { "Driver", "app.CharacterBase" }, { "Seat", "via.vec3" }, { "Label", "System.String" }, { "Count", "System.Int32", static = true } },
        methods = { SetSpeed = { params = { "System.Single" }, ret = "System.Void" }, get_IsDriven = { params = {}, ret = "System.Boolean" } },
    })
    local TY = H.get_types()
    local orig = env.scene.m["findComponents(System.Type)"]
    env.scene.m["findComponents(System.Type)"] = function(self, t)
        if t == "app.CarInGarage" then looks = looks + 1 return { get_elements = function() return cars end } end
        return orig(self, t)
    end
    live(env, 6)
    check(looks == 0 and env.files["re7mp/car_probe.json"] == nil, "(10.16) car probe: off at every start: no scene look, no file (" .. looks .. " looks)")
    check(health(env).car_probe and health(env).car_probe.on == false, "(10.16) car probe: ...and the debug file says it is off")
    env.check_override[BOX_CAR] = true
    run_ui(env)
    local f = env.files["re7mp/car_probe.json"]
    local t = f and f.types and f.types[1]
    check(t and t.found == true and t.type == "app.CarInGarage" and t.fields_total == 6 and t.methods_total == 2, "(10.16) car probe: the box ticked: the type is written at once (found " .. tostring(t and t.found) .. ", fields " .. tostring(t and t.fields_total) .. ", methods " .. tostring(t and t.methods_total) .. ")")
    local fld = {}
    for _, x in ipairs(t and t.fields or {}) do fld[x.name] = x end
    check(fld.Speed and fld.Speed.type == "System.Single" and fld.Driver and fld.Driver.type == "app.CharacterBase" and fld.Count and fld.Count.static == true, "(10.16) car probe: ...every field with its type, and static ones marked")
    local mth = {}
    for _, x in ipairs(t and t.methods or {}) do mth[x.name] = x end
    check(mth.SetSpeed and mth.SetSpeed.params == 1 and mth.get_IsDriven and mth.get_IsDriven.returns == "System.Boolean", "(10.16) car probe: ...every method with its parameter count and return type")
    check(#(f and f.readings or {}) == 0 and tostring(health(env).car_probe.status):find("waiting for a CarInGarage object", 1, true), "(10.16) car probe: no object yet (not in the garage): it waits: " .. tostring(health(env).car_probe.status))
    live(env, 7)
    check(#(env.files["re7mp/car_probe.json"].readings) == 0 and looks >= 2 and looks <= 6, "(10.16) car probe: while it waits it looks about every 2 s, not every frame (" .. looks .. " looks in 7 s)")
    -- the garage: the car exists
    cars[1] = car
    live(env, 2.5)
    f = env.files["re7mp/car_probe.json"]
    local r1 = f.readings[1] and f.readings[1].instances[1]
    check(r1 and r1.game_object == "CarInGarage_Ethan" and r1.position == "1.500 0.200 -7.250", "(10.16) car probe: the object appears: reading 1 has its game object and position (" .. tostring(r1 and r1.game_object) .. " " .. tostring(r1 and r1.position) .. ")")
    local cmp = {}
    for _, c in ipairs(r1 and r1.components or {}) do cmp[c] = true end
    check(cmp["app.CarInGarage"] and cmp["via.render.Mesh"], "(10.16) car probe: ...and the component types on that game object")
    local rf = {}
    for _, x in ipairs(r1 and r1.fields or {}) do rf[x.name] = x end
    check(rf.Speed and rf.Speed.value == 0 and rf.Gear and rf.Gear.value == 1 and rf.Label and rf.Label.value == "garage car" and rf.Seat and rf.Seat.value == "0.100 0.200 0.300", "(10.16) car probe: ...the plain fields with their values (numbers, text, vectors)")
    check(rf.Driver and rf.Driver.set == true and rf.Driver.value == nil, "(10.16) car probe: ...an object field only says that it is set, never reads into it")
    -- the car drives
    car.f.Speed = 3.5
    car_pos.x = 9.5
    live(env, 5.5)
    check(#env.files["re7mp/car_probe.json"].readings == 2, "(10.16) car probe: a second reading 5 s after the first (" .. #env.files["re7mp/car_probe.json"].readings .. ")")
    live(env, 10.5)
    f = env.files["re7mp/car_probe.json"]
    check(#f.readings == 3, "(10.16) car probe: and a third after 15 s (" .. #f.readings .. ")")
    local ch = {}
    for _, x in ipairs(f.changed_between_first_and_last or {}) do ch[x.name] = x end
    check(ch.Speed and ch.Speed.first == 0 and ch.Speed.last == 3.5 and ch["(game object position)"] and ch.Gear == nil and ch.Label == nil, "(10.16) car probe: it lists which fields changed between the first and last reading (Speed, the position) and not the ones that did not")
    local before = looks
    live(env, 8)
    check(looks == before, "(10.16) car probe: after three readings it stops looking (" .. (looks - before) .. " more looks)")
    local hp = health(env).car_probe
    check(hp.readings == 3 and hp.type_found == true and hp.fields == 6 and hp.methods == 2 and hp.counts.writes >= 4 and tostring(hp.status):find("^done"), "(10.16) car probe: the debug file: " .. tostring(hp.status))
    check(writes == 0, "(10.16) car probe: it never wrote a field of the game (" .. writes .. " writes)")
    check(not log_has(env, "script error"), "(10.16) car probe: no script error")
    env.check_override[BOX_CAR] = false
    run_ui(env)
    check(health(env).car_probe.on == false and health(env).car_probe.status == "off", "(10.16) car probe: unticked: off")
    TY["app.CarInGarage"] = nil
    -- a game with no such type
    local env2 = world("host")
    env2.check_override[BOX_CAR] = true
    run_ui(env2)
    live(env2, 5)
    local f2 = env2.files["re7mp/car_probe.json"]
    check(f2 and f2.types[1].found == false and #f2.readings == 0 and tostring(health(env2).car_probe.status):find("has no type app.CarInGarage", 1, true), "(10.16) car probe: a game with no such type: it says so and reads nothing")
end

-- =============================================================================================
-- 3. the Molded: spawn points to unique names (always on), and the opt-in copies in the joiner's game
-- =============================================================================================
-- A fake Molded body (Em4000) in the pool, and its spawn point (app.EnemySpawnInfo: MyGUID, EnemyInstance, IsSpawned).
-- spec: guid = { mData1, mData2 }, pos, awake (default true), pooled (default true), nobody (a spawn point with no body), dead, hp, max, spawned (IsSpawned)
local function molded_world(role, specs, opts)
    opts = opts or {}
    local env = new_environment()
    build_world(env)
    local W = { bodies = {}, points = {}, warps = {}, changes = {}, asked = {}, think = {}, fsm = {}, hits = {}, dmgs = {}, draws = {}, specs = specs }
    -- the game's loading flags (the script holds everything still while one is true)
    W.gm = Obj.new("app.GameManager", {}, { _CurrentChapter = 0, ["<IsSceneLoading>k__BackingField"] = false, RequestChapterJump = false, RequestPlayerChange = false })
    env.singletons["app.GameManager"] = W.gm
    make_td("app.Em4000Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
    make_td("app.Em4000.Em4000DamageController", { fields = { { "HealthInfo", "app.HealthInfo" } } })
    local layer_def = { overloads = { changeMotion = { { params = { "System.UInt32", "System.UInt32", "System.Single", "System.Single", "via.motion.InterpolationMode", "via.motion.InterpolationCurve" },
        call = function(_, layer, bank, mid, frame, blend, mode, curve)
            if W.change_fails then error("fake: changeMotion refused") end
            W.changes[#W.changes + 1] = string.format("%d/%d@%.1f", bank, mid, frame)
            layer.bank, layer.mid, layer.frame = bank, mid, frame
        end } } } }
    make_td("via.motion.TreeLayer", layer_def)
    make_td("via.motion.MotionInfo")
    W.pool = make_go("MoldedPool", vec(0, 0, 0), {})
    local function new_body(spec, i)
        local hi = Obj.new("app.HealthInfo", {}, { _CurrentHealth = spec.hp or 200, _MaxHealth = spec.max or 200 })
        local B = { spec = spec, hi = hi, pooled = spec.pooled ~= false, update = spec.awake ~= false, update_self = spec.awake ~= false, draw_self = spec.awake ~= false, dead = spec.dead == true,
            hits = 0, fsm_on = true, think_off = false }
        local dc = Obj.new("app.Em4000.Em4000DamageController", {
            get_isDead = function() return B.dead end, get_maxHealth = function() return hi.f._MaxHealth end,
            newFakeDamageInfo = function(_, dmg) W.dmgs[#W.dmgs + 1] = dmg return Obj.new("app.DamageInfo", {}, { dmg = dmg }) end,
            addManualDamage = function(_, info)
                B.hits = B.hits + 1
                W.hits[#W.hits + 1] = i
                if spec.dies_on and B.hits >= spec.dies_on then B.dead = true hi.f._CurrentHealth = 0 end
                return Obj.new("app.DamageRecord", {})
            end }, { HealthInfo = hi })
        local layer = Obj.new("via.motion.TreeLayer", {
            get_MotionBankID = function() return B.layer.bank end, get_MotionID = function() return B.layer.mid end,
            get_Frame = function() W.frame_reads = (W.frame_reads or 0) + 1 return B.layer.frame end,
            set_Frame = function(_, f) B.layer.frame = f end })
        layer.bank, layer.mid, layer.frame = 0, 0, 0
        B.layer = layer
        local motion = Obj.new("via.motion.Motion", { getLayer = function() return layer end,
            ["getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)"] = function(_, bank, mid) return not (spec.missing_clips and spec.missing_clips[bank .. "/" .. mid]) end })
        local fsm = Obj.new("via.motion.MotionFsm", { set_Enabled = function(_, on) B.fsm_on = on W.fsm[#W.fsm + 1] = i .. ":" .. tostring(on) end })
        local order = Obj.new("app.Em4000Order", {
            requestThinkOff = function(_, who) B.think_off = true W.think[#W.think + 1] = i .. ":off:" .. tostring(who) end,
            requestThinkOn = function(_, who) B.think_off = false W.think[#W.think + 1] = i .. ":on:" .. tostring(who) end })
        local comps = { Obj.new("app.Em4000Status", {}, { ["<isStarted>k__BackingField"] = true }), dc, motion, fsm, order }
        if not spec.no_movement then
            local mc = Obj.new("app.MovementController", { ["warp(via.vec3, via.Quaternion)"] = function(_, p, q)
                if spec.warp_fails then error("fake: warp refused") end
                W.warps[#W.warps + 1] = { i = i, x = p.x, y = p.y, z = p.z, qw = q.w, qy = q.y }
                B.go.xf.m.set_Position(B.go.xf, p)
            end })
            comps[#comps + 1] = mc
        end
        local mesh = Obj.new("via.render.Mesh", { get_Enabled = function() return B.mesh_on ~= false end, set_Enabled = function(_, v) B.mesh_on = v end,
            get_DrawDefault = function() return true end, set_DrawDefault = function() end })
        comps[#comps + 1] = mesh
        local go = make_go("Em4000", spec.pos or vec(10, 0, 10), comps)
        B.go = go
        go.m.get_Update = function() return B.update end
        go.m.get_UpdateSelf = function() return B.update_self end
        go.m.set_UpdateSelf = function(_, v) B.update_self, B.update = v, v W.draws[#W.draws + 1] = i .. ":update:" .. tostring(v) end
        go.m.get_DrawSelf = function() return B.draw_self end
        go.m.set_DrawSelf = function(_, v) B.draw_self = v W.draws[#W.draws + 1] = i .. ":draw:" .. tostring(v) end
        go.xf.m.get_Parent = function() return B.pooled and W.pool.xf or nil end
        go.xf.m.set_Parent = function(_, p) B.pooled = p ~= nil W.draws[#W.draws + 1] = i .. ":parent:" .. (p and "pool" or "none") end
        go.m.set_Update = nil
        W.bodies[i] = B
        return B
    end
    W.new_body = new_body
    for i, spec in ipairs(specs) do
        local guid = Obj.new("System.Guid", {}, { mData1 = spec.guid[1], mData2 = spec.guid[2] })
        local fields = { MyGUID = guid, IsSpawned = spec.spawned == true }
        if not spec.nobody then fields.EnemyInstance = new_body(spec, i).go end
        local sp = Obj.new("app.EnemySpawnInfo", {}, fields)
        W.points[i] = sp
    end
    H.weapons_by_type["app.EnemySpawnInfo"] = W.points -- (a table shared by every world: each block that follows sets its own, or clears it)
    env.singletons["app.EnemyGeneratorManager"] = Obj.new("app.EnemyGeneratorManager", {
        -- the three-argument form raised c0000005 for the other mod: this fake only notes that it was called (the script must never call it)
        ["requestSpawn(app.EnemySpawnInfo, System.Boolean, System.Int32)"] = function() W.three_arg = true end,
        ["requestSpawn(app.EnemySpawnInfo, System.Int32)"] = function(_, s, n)
            local idx
            for i, p in ipairs(W.points) do if p == s then idx = i end end
            W.asked[#W.asked + 1] = { point = idx, arg = n }
            local spec = W.specs[idx]
            if spec and spec.spawn_on_ask and s.f.EnemyInstance == nil then
                s.f.EnemyInstance = new_body({ guid = spec.guid, pos = spec.pos, awake = true, pooled = true, hp = spec.hp, max = spec.max, dies_on = spec.dies_on }, idx).go
                s.f.IsSpawned = true
            end
        end })
    env.scene = make_scene(env.scene_objects)
    if opts.settings then env.files["re7mp/settings.json"] = opts.settings end
    if opts.before_load then opts.before_load(env, W) end
    load_script(env)
    host_role_files(env, role, "tcp")
    -- a MotionInfo the script can hand to getMotionInfo (the fake game makes no such object by itself)
    local real_create = env.G.sdk.create_instance
    env.G.sdk.create_instance = function(name, simplified)
        if name == "via.motion.MotionInfo" then local i = Obj.new(name, {}) i.add_ref = function(self) return self end return i end
        return real_create(name, simplified)
    end
    for _ = 1, 30 do run_frames(env, 0.05) bump_remote(env) end
    if role == "join" then
        env.combo_override["Enemy sync"] = opts.mode or 3
        run_ui(env)
        if opts.on ~= false then
            env.check_override[BOX_MOLD] = true
            run_ui(env)
        end
    end
    return env, W
end

-- what the host says, to a joiner: the entries (a full wire entry each), re-sent four times a second with a new sequence number so the data stays fresh
local function ment(name, x, z, o)
    o = o or {}
    return string.format("%s,%.2f,%.2f,%.2f,0,0.7071,0,0.7071,%d,%d,%d,%d,%.1f,%d", name, x, o.y or 0, z, o.hp or 150, o.flags or 1, o.bank or 7, o.motion or 123, o.frame or 12.5, o.max or 200)
end
local function mfeed(env, list)
    env.mfeed = list
    env.snap_n = (env.snap_n or 500) + 1
    env.files["re7mp_state_in.json"] = { seq = env.snap_n, n = env.snap_n, p = table.concat(list, ";") }
end
local function mlive(env, secs)
    for i = 1, math.floor(secs / 0.05 + 0.5) do
        if env.mfeed and i % 4 == 1 then mfeed(env, env.mfeed) end
        run_frames(env, 0.05)
        bump_remote(env)
    end
end

local ID_A, ID_B, ID_C = "3fa91c2e9b4d", "111111112222", "333333334444"
local function specs3()
    return {
        { guid = { 0x3fa91c2e, 0x9b4d }, pos = vec(10, 0, 10), hp = 150, max = 200 },
        { guid = { 0x11111111, 0x2222 }, pos = vec(12, 0, 10), hp = 200, max = 200 },
        { guid = { 0x33333333, 0x4444 }, pos = vec(14, 0, 10), awake = false },
        { guid = { 0x55555555, 0x6666 }, nobody = true },
        { guid = { 0, 0 }, pos = vec(16, 0, 10) },
    }
end

local function entries_of(env)
    local d = env.files["re7mp_state_out.json"]
    local by = {}
    for e in ((d and d.p) or ""):gmatch("[^;]+") do
        if not e:match("^T[%d%.]+$") then
            local f = {}
            for x in e:gmatch("[^,]+") do f[#f + 1] = x end
            by[f[1]] = f
        end
    end
    return by, d
end

do -- the host: the spawn points name the Molded that are out
    local env, W = molded_world("host", specs3())
    live(env, 1.2)
    local by = entries_of(env)
    check(by["Em4000_" .. ID_A] and by["Em4000_" .. ID_B], "(10.15) Molded: the two bodies the spawn points say are out are sent, named <Em4000>_<12 hex characters of the GUID>")
    check(by["Em4000_" .. ID_A] and tonumber(by["Em4000_" .. ID_A][2]) == 10 and tonumber(by["Em4000_" .. ID_A][9]) == 150 and tonumber(by["Em4000_" .. ID_A][14]) == 200 and tonumber(by["Em4000_" .. ID_A][10]) == 1,
        "(10.15) Molded: ...with their place, health, maximum and 'alive' flag")
    check(by["Em4000_" .. ID_C] == nil and by.Em4000 == nil, "(10.15) Molded: a body the game put to sleep (UpdateSelf off) is not sent, and no body is sent under the plain name")
    local n = 0
    for name in pairs(by) do if name:match("^Em4000_") then n = n + 1 end end
    check(n == 2, "(10.15) Molded: a spawn point with no body, and one with an empty GUID, send nothing (" .. n .. " Molded)")
    for name in pairs(by) do check(name:match("^[%w_]+$") ~= nil and #name <= 24, "(10.15) Molded: the wire name is plain letters, digits and _ : " .. name) end
    check(by.Em2000 and by.Em3100 and by.Em6100, "(10.15) Molded: the enemies of the scene root keep their own names")
    -- it wakes up: it is sent from then on
    W.bodies[3].update, W.bodies[3].update_self = true, true
    live(env, 1.5)
    by = entries_of(env)
    check(by["Em4000_" .. ID_C] ~= nil, "(10.15) Molded: the sleeping body that wakes up is sent from then on")
    -- it falls asleep again (no player near its zone): it is not sent
    W.bodies[3].update, W.bodies[3].update_self = false, false
    live(env, 1.5)
    check(entries_of(env)["Em4000_" .. ID_C] == nil, "(10.15) Molded: ...and not sent once it sleeps again")
    -- a Molded dies: the 'alive' bit is cleared (its Status has no get_IsDead, the DamageController says get_isDead)
    W.bodies[2].dead = true
    live(env, 1.5)
    by = entries_of(env)
    check(by["Em4000_" .. ID_B] and tonumber(by["Em4000_" .. ID_B][10]) % 2 == 0, "(10.15) Molded: a dead Molded is sent with the alive bit cleared (flags " .. tostring(by["Em4000_" .. ID_B] and by["Em4000_" .. ID_B][10]) .. ")")
    check(by["Em4000_" .. ID_A] and tonumber(by["Em4000_" .. ID_A][10]) % 2 == 1, "(10.15) Molded: ...and the living one is not")
    -- the debug file
    local hh = health(env)
    local ms = hh.molded_spawn_points
    check(ms and ms.on == true and ms.counts.points == 4 and ms.counts.with_body >= 2 and ms.counts.asleep_skipped >= 1, "(10.15) Molded: the debug file counts spawn points (4 with a GUID), bodies out and sleepers: "
        .. tostring(ms and ms.counts.points) .. "/" .. tostring(ms and ms.counts.with_body) .. "/" .. tostring(ms and ms.counts.asleep_skipped))
    local seen = {}
    for _, nme in ipairs(ms and ms.names_seen or {}) do seen[nme] = true end
    check(seen["Em4000_" .. ID_A] and seen["Em4000_" .. ID_B], "(10.15) Molded: ...and lists the names it gave")
    check(log_has(env, "molded: Em4000_" .. ID_A .. " is out (spawn point " .. ID_A .. ")"), "(10.15) Molded: ...and the journal says when one is out")
    check(hh.molded_copies and hh.molded_copies.on == false and hh.molded_copies.last == "off", "(10.15) Molded: the copies are off")
    -- the list of spawn points cannot be read (a game with no such call): the last list stays
    H.weapons_by_type["app.EnemySpawnInfo"] = nil
    live(env, 3)
    check(entries_of(env)["Em4000_" .. ID_A] ~= nil, "(10.15) Molded: when the spawn points can't be read this time the list of the last scan is kept")
    check(health(env).molded_spawn_points.counts.unreadable >= 1 and health(env).molded_spawn_points.points_error ~= nil, "(10.15) Molded: ...and the failure is counted and explained")
    check(not log_has(env, "script error"), "(10.15) Molded: no script error")
end

do -- no more than 14 bodies from the spawn points in a scan
    local specs = {}
    for i = 1, 20 do specs[i] = { guid = { 0x1000 + i, 0x2000 + i }, pos = vec(10 + i, 0, 10) } end
    local env, W = molded_world("host", specs)
    live(env, 1.5)
    local by = entries_of(env)
    local n = 0
    for name in pairs(by) do if name:match("^Em4000_") then n = n + 1 end end
    check(n == 14, "(10.15) Molded: at most 14 bodies from the spawn points are sent (" .. n .. ")")
    check(health(env).molded_spawn_points.counts.capped >= 6, "(10.15) Molded: ...and the ones left out are counted")
end

do -- two objects with one name at the top of the scene: told apart, and both sent
    H.weapons_by_type["app.EnemySpawnInfo"] = nil -- (no spawn points in this one)
    local env = new_environment()
    build_world(env)
    local function motion(bank) return Obj.new("via.motion.Motion", { getLayer = function() return Obj.new("via.motion.TreeLayer", { get_MotionBankID = function() return bank end, get_MotionID = function() return 5 end, get_Frame = function() return 1 end }) end }) end
    local live_one = make_go("Em2100", vec(30, 0, 30), { Obj.new("app.Em3100Status", { get_IsDead = function() return false end }, { ["<isStarted>k__BackingField"] = true }), motion(3) })
    local parked_one = make_go("Em2100", vec(31, -7, 31), { motion(0) })
    env.scene_objects[#env.scene_objects + 1] = live_one
    env.scene_objects[#env.scene_objects + 1] = parked_one
    env.scene = make_scene(env.scene_objects)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 2.2)
    local by = entries_of(env)
    local names = {}
    for name in pairs(by) do if name:match("^Em2100") then names[#names + 1] = name end end
    check(#names == 2 and names[1] ~= names[2] and names[1]:match("^Em2100_%x+$") and names[2]:match("^Em2100_%x+$"), "(10.15) Molded: two objects both named Em2100 are sent under two names (" .. table.concat(names, ", ") .. ")")
    check(by.Em2000 ~= nil, "(10.15) Molded: ...and a name that is used once is left as it is")
    check(health(env).molded_spawn_points.counts.renamed_duplicates >= 2, "(10.15) Molded: ...the renames are counted")
end

do -- the joiner reads those names
    local rec = {}
    local env = world("join", pool_setup(rec))
    env.files["re7mp_state_in.json"] = { seq = 701, n = 701, p = "Em4000_" .. ID_A .. ",10.00,0.00,10.00,0,0,0,1,150,1,7,123,12.5,200" }
    env.texts = {}
    live(env, 0.6)
    check(texts_have(env, "Em4000  HP 150/200"), "(10.15) Molded: the joiner draws a Molded by its model's name (Em4000), not the long wire name")
    local hh = health(env)
    check(not log_has(env, "script error"), "(10.15) Molded: no script error on the joiner")
end

-- ---------------------------------------------------------------------------------------------
-- 3b. the copies in the joiner's own game (EXPERIMENTAL, opt-in)
-- ---------------------------------------------------------------------------------------------
local function pos_of(B) local p = B.go.xf:call("get_Position") return p.x, p.y, p.z end
local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.06) end
local function any_has(list, text) for _, s in ipairs(list) do if tostring(s):find(text, 1, true) then return true end end return false end
local function crumbed(env, text) return any_has(env.crumb_log or {}, text) end
-- the debug file's molded_copies, rebuilt while the host keeps talking (health() alone is 1.8 s of silence: three of those and the host's data is stale and every copy is let go)
local function molded_report(env)
    mlive(env, 1.2)
    env.ui_press["Clear the debug log"] = true
    run_ui(env)
    mlive(env, 0.6)
    return env.files["re7mp/debug.json"].health.molded_copies
end
local function copy_names(r) local t = {} for _, c in ipairs(r.copies or {}) do t[#t + 1] = c.name end table.sort(t) return table.concat(t, ",") end
local NAME_A, NAME_B, NAME_C = "Em4000_" .. ID_A, "Em4000_" .. ID_B, "Em4000_" .. ID_C
local ID_D = "555555556666"

do -- OFF (the default): nothing is touched, whatever the host sends; and the old mode-3 driver leaves a pooled Molded alone as well
    local env, W = molded_world("join", specs3(), { on = false })
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3.5)
    local B = W.bodies[1]
    local x, _, z = pos_of(B)
    check(#W.warps == 0 and #W.fsm == 0 and #W.think == 0 and #W.draws == 0 and #W.changes == 0,
        "(10.15) copies: off: no call was made on any body (warps " .. #W.warps .. ", fsm " .. #W.fsm .. ", think " .. #W.think .. ", draws " .. #W.draws .. ", clips " .. #W.changes .. ")")
    check(B.pooled and B.fsm_on and near(x, 10) and near(z, 10), "(10.15) copies: off: the body is still in its pool, its AI on, and where it was (mode 3's own driver leaves a pooled Molded alone)")
    local r = molded_report(env)
    check(r.on == false and r.counts.taken == 0 and #r.copies == 0, "(10.15) copies: off: the debug file says off, nothing taken")
    check(not log_has(env, "script error"), "(10.15) copies: off: no script error")
end

do -- ON: a body that is out already is taken, moved onto the host's, with the host's clip; and let go when the host stops sending it
    local env, W = molded_world("join", specs3())
    mfeed(env, { ment(NAME_A, 20, 30, { bank = 7, motion = 123, frame = 12.5 }) })
    mlive(env, 3.5)
    local B = W.bodies[1]
    check(B.pooled == false and any_has(W.draws, "1:parent:none"), "(10.15) copies: the body is taken out of its pool (set_Parent(nil))")
    check(B.fsm_on == false and B.think_off == true and any_has(W.think, "1:off:"), "(10.15) copies: ...its own AI is off (MotionFsm disabled, EnemyOrder.requestThinkOff)")
    check(not any_has(W.draws, "1:update:") and not any_has(W.draws, "1:draw:"), "(10.15) copies: ...an awake body is not woken (nothing to switch on)")
    local last = W.warps[#W.warps]
    check(#W.warps >= 8 and last and last.i == 1 and near(last.x, 20) and near(last.z, 30), "(10.15) copies: ...and warped onto the host's place (" .. #W.warps .. " warps, last at "
        .. tostring(last and last.x) .. ", " .. tostring(last and last.z) .. ")")
    local w_n = #W.warps
    local skipped = molded_report(env).counts.warps_skipped
    check(w_n < 30 and skipped > 20, "(10.15) copies: ...a Molded that stands still is put there again four times a second, not on every frame (" .. w_n .. " warps in 3.5 s, " .. tostring(skipped) .. " left out)")
    check(last and near(last.qy, 0.7071, 0.01) and near(last.qw, 0.7071, 0.01), "(10.15) copies: ...facing the way the host's faces (a quarter turn about Y)")
    local x, _, z = pos_of(B)
    check(near(x, 20) and near(z, 30), "(10.15) copies: ...the body stands at 20, 30")
    check(#W.changes >= 1 and W.changes[1]:match("^7/123@1[2-9]%.") ~= nil, "(10.15) copies: ...and plays the host's clip on layer 0 (bank 7, motion 123): " .. tostring(W.changes[1]))
    check(not W.three_arg and #W.asked == 0, "(10.15) copies: ...nothing was asked of the spawner for a body that was out already")
    local o = W.bodies[2]
    check(o.pooled and o.fsm_on and not any_has(W.think, "2:"), "(10.15) copies: ...the other bodies are not touched")
    -- the debug file
    local r = molded_report(env)
    local c1 = r.copies[1]
    check(r.on == true and r.counts.taken == 1 and #r.copies == 1 and c1 and c1.name == NAME_A and c1.spawn == ID_A and c1.out_of_pool == true and c1.ai_off == true and c1.woke == false and c1.clip == "7/123",
        "(10.15) copies: the debug file lists the copy (spawn point, out of its pool, AI off, clip 7/123): on=" .. tostring(r.on) .. " taken=" .. tostring(r.counts.taken) .. " n=" .. #r.copies .. " name=" .. tostring(c1 and c1.name)
        .. " out=" .. tostring(c1 and c1.out_of_pool) .. " ai=" .. tostring(c1 and c1.ai_off) .. " woke=" .. tostring(c1 and c1.woke) .. " clip=" .. tostring(c1 and c1.clip))
    check(log_has(env, "molded copies: " .. NAME_A .. ": this game's body of spawn point " .. ID_A .. " is a copy of the host's now (out of its pool)"), "(10.15) copies: ...and the journal says it")
    check(crumbed(env, "molded: taking " .. NAME_A) and crumbed(env, "clean: molded body taken") and crumbed(env, "molded: moving copies of the host's Molded"),
        "(10.15) copies: the crash marker has the steps (taking, moving copies) and 'clean' after the take")
    -- the mesh is switched on again by itself (the Molded wait hidden; the game's own AI would have shown it)
    B.mesh_on = false
    mlive(env, 1.3)
    check(B.mesh_on == true, "(10.15) copies: a mesh the game switched off is switched on again within a second")
    -- the host's clip changes: the copy plays the new one
    mfeed(env, { ment(NAME_A, 20, 30, { bank = 7, motion = 200, frame = 3 }) })
    mlive(env, 1)
    check(#W.changes >= 2 and W.changes[#W.changes]:match("^7/200@") ~= nil, "(10.15) copies: the host's next clip is played too (" .. tostring(W.changes[#W.changes]) .. ")")
    -- the host moves: so does the copy
    mfeed(env, { ment(NAME_A, 25, 35, { bank = 7, motion = 200, frame = 3 }) })
    mlive(env, 2)
    local x2, _, z2 = pos_of(B)
    check(near(x2, 25, 0.1) and near(z2, 35, 0.1), "(10.15) copies: ...the host's Molded walks to 25, 35: so does the copy (" .. string.format("%.2f, %.2f", x2, z2) .. ")")
    -- the label stays (its box is the part that is not drawn: the real body is there)
    env.texts = {}
    mlive(env, 0.5)
    check(texts_have(env, "Em4000  HP 150/200"), "(10.15) copies: the ghost's label (name, host's health) is still drawn over the real body")
    env.lines = 0
    mlive(env, 1)
    local with_copy = env.lines
    -- a second Molded comes out on the host
    mfeed(env, { ment(NAME_A, 25, 35, { bank = 7, motion = 200, frame = 3 }), ment(NAME_B, 30, 40, { hp = 200, bank = 7, motion = 5 }) })
    mlive(env, 2.5)
    local B2 = W.bodies[2]
    local bx, _, bz = pos_of(B2)
    check(B2.fsm_on == false and B2.pooled == false and near(bx, 30, 0.1) and near(bz, 40, 0.1), "(10.15) copies: a second Molded gets its own copy, on its own spawn point's body")
    local cn = copy_names(molded_report(env)) local both = { NAME_A, NAME_B } table.sort(both) check(cn == table.concat(both, ","), "(10.15) copies: ...two copies are listed (" .. cn .. ")")
    -- the host stops sending the first (it fell asleep there, or went away): its copy is let go
    mfeed(env, { ment(NAME_B, 30, 40, { hp = 200, bank = 7, motion = 5 }) })
    mlive(env, 1)
    check(B.fsm_on == true and B.think_off == false and any_has(W.think, "1:on:"), "(10.15) copies: the host stops sending the first: its AI is back (MotionFsm on, requestThinkOn)")
    check(B.pooled == false and not any_has(W.draws, "1:update:false"), "(10.15) copies: ...a body the game had awake stays awake (not put to sleep, not put back in the pool)")
    check(log_has(env, "molded copies: " .. NAME_A .. ": let go (the host no longer sends it)"), "(10.15) copies: ...and the journal says why")
    check(B2.fsm_on == false, "(10.15) copies: ...the second copy goes on")
    -- the host's second is parked / asleep over there (flags 3: alive + parked): let go as well
    mfeed(env, { ment(NAME_B, 30, 40, { hp = 200, flags = 3 }) })
    mlive(env, 1)
    check(B2.fsm_on == true and #molded_report(env).copies == 0, "(10.15) copies: a Molded the host says is parked is let go")
    check(crumbed(env, "clean: molded: no copy left"), "(10.15) copies: ...and with no copy left the crash marker says clean")
    -- the box comes back, now that nothing is up: the same entry is drawn as a box again (more lines)
    mfeed(env, { ment(NAME_B, 30, 40, { hp = 200, flags = 3 }), ment("Em2100", 5, 5) })
    mlive(env, 0.5)
    env.lines = 0
    mlive(env, 1)
    check(env.lines > with_copy, "(10.15) copies: a Molded with no copy is drawn as a box (" .. env.lines .. " lines) and one with a copy is not (" .. with_copy .. ")")
    check(not log_has(env, "script error"), "(10.15) copies: no script error")
end

do -- the box unticked: every copy is let go at once, the panel box is not remembered
    local env, W = molded_world("join", specs3())
    mfeed(env, { ment(NAME_A, 20, 30), ment(NAME_B, 30, 40) })
    mlive(env, 3)
    check(not W.bodies[1].fsm_on and not W.bodies[2].fsm_on, "(10.15) copies: setup: both bodies are copies")
    env.check_override[BOX_MOLD] = false
    run_ui(env)
    mlive(env, 0.3)
    check(W.bodies[1].fsm_on and W.bodies[2].fsm_on and #molded_report(env).copies == 0, "(10.15) copies: the box unticked: both are let go, their AI back")
    check(log_has(env, "molded copies: switched off in the panel") and log_has(env, ": let go (switched off)"), "(10.15) copies: ...and the journal says so")
    mlive(env, 3)
    check(#molded_report(env).copies == 0, "(10.15) copies: ...and none is taken again while it is off")
    run_ui(env)
    run_frames(env, 3)
    local saved = env.files["re7mp/settings.json"] or {}
    local leaked = false
    for k in pairs(saved) do if tostring(k):lower():find("molded", 1, true) then leaked = true end end
    check(not leaked, "(10.15) copies: the switch is not saved in the settings (it starts off every time)")
end

do -- a sleeping body (the game put it to sleep: no player near its zone): woken, drawn, taken out of its pool; and put back to sleep when let go
    local env, W = molded_world("join", specs3())
    mfeed(env, { ment(NAME_C, 40, 50) })
    mlive(env, 3)
    local B = W.bodies[3]
    check(B.update_self == true and B.draw_self == true and any_has(W.draws, "3:update:true") and any_has(W.draws, "3:draw:true"), "(10.15) copies: a sleeping body is woken (UpdateSelf and DrawSelf on)")
    check(B.pooled == false and B.fsm_on == false and B.think_off, "(10.15) copies: ...taken out of its pool, its AI off")
    local x, _, z = pos_of(B)
    check(near(x, 40) and near(z, 50), "(10.15) copies: ...and moved onto the host's place")
    local c = molded_report(env).copies[1]
    check(c and c.woke == true and c.out_of_pool == true, "(10.15) copies: the debug file says it was woken")
    mfeed(env, { ment("Em2100", 5, 5) })
    mlive(env, 1)
    check(B.update_self == false and B.draw_self == false and B.pooled == true and B.fsm_on == true and B.think_off == false,
        "(10.15) copies: let go: a body I woke goes back to sleep, back into its pool, its AI on")
    local r = molded_report(env)
    check(r.counts.woke == 1 and r.counts.slept == 1 and r.counts.unpooled == 1 and r.counts.repooled == 1, "(10.15) copies: ...woke / slept / unpooled / repooled are counted")
end

do -- a spawn point with no body: the game is asked to bring its Molded out (2-argument call only), and the body that comes out is taken
    local specs = { { guid = { 0x55555555, 0x6666 }, nobody = true, spawn_on_ask = true, pos = vec(10, 0, 10) } }
    local env, W = molded_world("join", specs)
    mfeed(env, { ment("Em4000_" .. ID_D, 22, 33) })
    mlive(env, 5)
    check(#W.asked >= 1 and W.asked[1].point == 1 and W.asked[1].arg == 0, "(10.15) copies: the spawn point is asked to bring its Molded out: requestSpawn(spawnInfo, 0)")
    check(W.three_arg == nil, "(10.15) copies: ...never the three-argument form (it raised c0000005 for the other mod)")
    local B = W.bodies[1]
    check(B and B.fsm_on == false and B.pooled == false, "(10.15) copies: ...and the body that came out is taken")
    local last = W.warps[#W.warps]
    check(last and near(last.x, 22) and near(last.z, 33), "(10.15) copies: ...and moved onto the host's place")
    check(log_has(env, "spawn point " .. ID_D .. ": asking the game to bring its Molded out here"), "(10.15) copies: the journal says it asked")
    local r = molded_report(env)
    check(r.counts.asked >= 1 and r.counts.taken == 1 and next(r.waiting_for_spawn) == nil, "(10.15) copies: ...asked " .. tostring(r.counts.asked) .. " time(s), taken, nothing left waiting")
end

do -- asked for 20 s, never answered: given up, and not asked again for 30 s
    local specs = { { guid = { 0x55555555, 0x6666 }, nobody = true } }
    local env, W = molded_world("join", specs)
    mfeed(env, { ment("Em4000_" .. ID_D, 22, 33) })
    mlive(env, 12)
    local n12 = #W.asked
    check(n12 >= 4 and n12 <= 7, "(10.15) copies: a spawn point that gives no body is asked every 2 s (" .. n12 .. " asks in 12 s)")
    check(molded_report(env).waiting_for_spawn[1] == ID_D, "(10.15) copies: ...and is listed as waiting")
    mlive(env, 14)
    local n26 = #W.asked
    check(n26 >= 8 and n26 <= 12 and #molded_report(env).waiting_for_spawn == 0, "(10.15) copies: ...for 20 s in all (" .. n26 .. " asks), then given up")
    mlive(env, 8)
    check(#W.asked == n26, "(10.15) copies: ...and it is not asked again for 30 s")
    mlive(env, 30)
    check(#W.asked > n26, "(10.15) copies: ...then it is asked again (" .. #W.asked .. " asks)")
end

do -- IsSpawned says yes and there is no body: IsSpawned is put back to false and the spawner asked once more (what the other mod found)
    local specs = { { guid = { 0x55555555, 0x6666 }, nobody = true, spawned = true, spawn_on_ask = true, pos = vec(10, 0, 10) } }
    local env, W = molded_world("join", specs)
    mfeed(env, { ment("Em4000_" .. ID_D, 22, 33) })
    mlive(env, 5)
    check(log_has(env, "spawn point " .. ID_D .. ": marked spawned with no body here, asked again"), "(10.15) copies: a spawn point marked spawned with no body: reset and asked again")
    check(molded_report(env).counts.resets == 1 and #W.asked == 1 and W.bodies[1] and W.bodies[1].fsm_on == false, "(10.15) copies: ...once (resets " .. tostring(molded_report(env).counts.resets) .. ", asks " .. #W.asked .. "), and the body that came is taken")
end

do -- the game gives the spawn point another body: the old copy is let go, the new body is taken; a body that is gone: let go and asked for
    local env, W = molded_world("join", specs3())
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    local old = W.bodies[1]
    check(old.fsm_on == false, "(10.15) copies: setup: the first body is a copy")
    local nb = W.new_body({ guid = { 0x3fa91c2e, 0x9b4d }, pos = vec(50, 0, 50) }, 6)
    W.points[1].f.EnemyInstance = nb.go
    mlive(env, 3.5)
    check(old.fsm_on == true and nb.fsm_on == false and nb.pooled == false, "(10.15) copies: the spawn point has another body: the old one is let go, the new one is taken")
    local last = W.warps[#W.warps]
    check(last and last.i == 6 and near(last.x, 20) and near(last.z, 30), "(10.15) copies: ...and the new one is moved onto the host's place")
    local r = molded_report(env)
    check(r.counts.swapped == 1 and r.counts.taken == 2 and #r.copies == 1 and log_has(env, "its spawn point has another body now"), "(10.15) copies: ...counted as a swap and the journal says why")
    W.points[1].f.EnemyInstance = nil
    mlive(env, 3.5)
    r = molded_report(env)
    check(#r.copies == 0 and nb.fsm_on == true and r.waiting_for_spawn[1] == ID_A, "(10.15) copies: the body is gone from the spawn point: the copy is let go and the spawn point is waited on")
end

do -- the host's Molded dies: my copy gets one hit far above its health (the game scales damage), up to 3 times, and is not brought out again
    local specs = specs3()
    specs[1].dies_on = 2
    local env, W = molded_world("join", specs)
    mfeed(env, { ment(NAME_A, 20, 30, { hp = 150 }) })
    mlive(env, 3)
    check(W.bodies[1].fsm_on == false, "(10.15) copies: setup: a copy is up")
    mfeed(env, { ment(NAME_A, 20, 30, { hp = 0, flags = 0 }) })
    mlive(env, 1)
    check(#W.hits == 2 and W.dmgs[1] == 1600, "(10.15) copies: the host's Molded is dead: my copy takes hits of 4 x its health + 1000 (" .. #W.hits .. " hits, first " .. tostring(W.dmgs[1]) .. ") until it dies")
    check(W.bodies[1].dead == true and #molded_report(env).copies == 0, "(10.15) copies: ...it dies, and is not a copy any more")
    check(log_has(env, NAME_A .. ": the host's Molded is dead; this game's copy was killed"), "(10.15) copies: ...the journal says it was killed")
    check(molded_report(env).counts.killed == 1 and molded_report(env).counts.kill_failed == 0, "(10.15) copies: ...counted as killed")
    -- it comes back alive in the host's list (the same spawn point): not brought out again in this scene
    mfeed(env, { ment(NAME_A, 20, 30, { hp = 150 }) })
    mlive(env, 3)
    check(molded_report(env).counts.taken == 1 and #molded_report(env).copies == 0, "(10.15) copies: a Molded that died here is not taken again in this scene")
end

do -- it will not die: three hits, then it is left (and says so); one that is dead already needs no hit
    local specs = specs3()
    specs[1].dies_on = 99
    local env, W = molded_world("join", specs)
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    mfeed(env, { ment(NAME_A, 20, 30, { hp = 0, flags = 0 }) })
    mlive(env, 1)
    check(#W.hits == 3 and molded_report(env).counts.kill_failed == 1 and log_has(env, NAME_A .. ": the host's Molded is dead; this game's copy could not be killed (3 hits)"),
        "(10.15) copies: a copy that will not die gets 3 hits, then it is left, and the journal says so (" .. #W.hits .. " hits)")
    local specs2 = specs3()
    local env2, W2 = molded_world("join", specs2)
    mfeed(env2, { ment(NAME_A, 20, 30) })
    mlive(env2, 3)
    W2.bodies[1].dead = true
    mfeed(env2, { ment(NAME_A, 20, 30, { hp = 0, flags = 0 }) })
    mlive(env2, 1)
    check(#W2.hits == 0 and molded_report(env2).counts.killed == 1, "(10.15) copies: a copy that is dead here already is not hit again, and counts as done")
end

do -- no data from the host for 3 s: every copy is let go; when it comes back they are taken again
    local env, W = molded_world("join", specs3())
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    env.mfeed = nil
    run_frames(env, 4)
    check(W.bodies[1].fsm_on == true and #molded_report(env).copies == 0, "(10.15) copies: the host goes quiet for 4 s: the copy is let go (its AI back)")
    check(log_has(env, ": let go (no data from the host)"), "(10.15) copies: ...and the journal says why")
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    check(W.bodies[1].fsm_on == false and molded_report(env).counts.taken == 2, "(10.15) copies: the host speaks again: the body is taken again")
end

do -- the scene changes: the game took the old bodies down, so nothing is called on them; the loading gate does the same
    local env, W = molded_world("join", specs3())
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    local t0, f0 = #W.think, #W.fsm
    H.weapons_by_type["app.EnemySpawnInfo"] = {} -- (the new scene has no spawn points yet)
    env.scene = make_scene(env.scene_objects)
    mlive(env, 0.3)
    local r = molded_report(env)
    check(r.counts.forgotten == 1 and #r.copies == 0, "(10.15) copies: the scene changes: the copy is forgotten (counted)")
    check(#W.think == t0 and #W.fsm == f0, "(10.15) copies: ...with no call on the old body at all (its AI is not 'given back' to an object the game has taken down)")
    check(log_has(env, "1 copy(ies) forgotten (the scene changed)"), "(10.15) copies: ...the journal says why")
    local env2, W2 = molded_world("join", specs3())
    mfeed(env2, { ment(NAME_A, 20, 30) })
    mlive(env2, 3)
    local t1, f1 = #W2.think, #W2.fsm
    W2.gm.f["<IsSceneLoading>k__BackingField"] = true
    mlive(env2, 0.5)
    local r2 = molded_report(env2)
    check(r2.counts.forgotten == 1 and #W2.think == t1 and #W2.fsm == f1 and log_has(env2, "forgotten (the game is loading)"), "(10.15) copies: the game starts loading a scene: the copy is forgotten, no call on the body")
    mlive(env2, 3)
    check(#molded_report(env2).copies == 0 and r2.counts.taken == 1, "(10.15) copies: ...and nothing is taken while the game loads")
    W2.gm.f["<IsSceneLoading>k__BackingField"] = false
    mlive(env2, 4)
    check(#molded_report(env2).copies == 1, "(10.15) copies: ...and the body is taken again once it has loaded")
end

do -- a body that cannot be moved is no copy: let go after 5 failures, not tried again for 60 s
    local specs = specs3()
    specs[1].warp_fails = true
    local env, W = molded_world("join", specs)
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    check(W.bodies[1].fsm_on == true and W.bodies[1].think_off == false, "(10.15) copies: a body that refuses the warp is let go (its AI back)")
    local r = molded_report(env)
    check(r.counts.warp_errors == 5 and r.counts.refused == 1 and r.counts.taken == 1, "(10.15) copies: ...after exactly 5 failed warps in a row (" .. tostring(r.counts.warp_errors) .. "), counted")
    check(log_has(env, "let go (its position could not be set 5 times in a row)"), "(10.15) copies: ...the journal says why")
    mlive(env, 30)
    check(molded_report(env).counts.taken == 1, "(10.15) copies: ...and it is not taken again within 60 s")
    W.bodies[1].spec.warp_fails = nil
    mlive(env, 35)
    check(molded_report(env).counts.taken == 2 and W.bodies[1].fsm_on == false, "(10.15) copies: ...after that it is tried again (and works now)")
    local specs2 = specs3()
    specs2[1].no_movement = true
    local env2, W2 = molded_world("join", specs2)
    mfeed(env2, { ment(NAME_A, 20, 30) })
    mlive(env2, 3)
    check(W2.bodies[1].fsm_on == true and molded_report(env2).counts.refused == 1, "(10.15) copies: a body with no MovementController is let go the same way")
end

do -- the clip is not in this body's banks / the clip call fails: no flood of calls
    local specs = specs3()
    specs[1].missing_clips = { ["7/123"] = true }
    local env, W = molded_world("join", specs)
    mfeed(env, { ment(NAME_A, 20, 30, { bank = 7, motion = 123 }) })
    mlive(env, 3)
    local r = molded_report(env)
    check(#W.changes == 0 and r.counts.plays_missing >= 2 and r.counts.plays_missing <= 8, "(10.15) copies: a clip the body has not loaded is not played, and looked for twice a second at most (" .. tostring(r.counts.plays_missing) .. " looks in 3 s)")
    check(near(select(1, pos_of(W.bodies[1])), 20) and W.bodies[1].fsm_on == false, "(10.15) copies: ...the copy is still moved onto the host's place")
    W.bodies[1].spec.missing_clips = nil
    mlive(env, 1)
    check(#W.changes == 1 and W.changes[1]:match("^7/123@") ~= nil, "(10.15) copies: ...and it is played as soon as the bank is there")
    local env2, W2 = molded_world("join", specs3())
    W2.change_fails = true
    mfeed(env2, { ment(NAME_A, 20, 30, { bank = 7, motion = 123 }) })
    mlive(env2, 4)
    local r2 = molded_report(env2)
    check(r2.counts.play_errors >= 2 and r2.counts.play_errors <= 6 and #W2.warps >= 8, "(10.15) copies: a clip call that fails is retried once a second, not every frame (" .. tostring(r2.counts.play_errors) .. " failures in 4 s); the copy is still moved")
    W2.change_fails = nil
    mlive(env2, 1.5)
    check(#W2.changes == 1, "(10.15) copies: ...and played when the call works again")
end

do -- no more than 8 copies
    local specs, list = {}, {}
    for i = 1, 12 do
        specs[i] = { guid = { 0x2000 + i, 0x3000 + i }, pos = vec(10 + i, 0, 10) }
        list[i] = ment(string.format("Em4000_%08x%04x", 0x2000 + i, 0x3000 + i), 20 + i, 30)
    end
    local env, W = molded_world("join", specs)
    mfeed(env, list)
    mlive(env, 4)
    local up = 0
    for _, B in ipairs(W.bodies) do if B.fsm_on == false then up = up + 1 end end
    check(up == 8 and molded_report(env).counts.taken == 8, "(10.15) copies: twelve Molded from the host, at most 8 copies are made (" .. up .. ")")
end

do -- the other modes: copies work in mode 2 (ghosts only), and mode 1 (off) lets them go
    local env, W = molded_world("join", specs3(), { mode = 2 })
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    check(W.bodies[1].fsm_on == false and #W.warps > 4, "(10.15) copies: they work in mode 2 as well (the host's ghosts, no other driving)")
    env.combo_override["Enemy sync"] = 1
    run_ui(env)
    mlive(env, 0.5)
    check(W.bodies[1].fsm_on == true and #molded_report(env).copies == 0 and log_has(env, ": let go (the enemy data is off)"), "(10.15) copies: ...and with the enemy sync off they are let go")
end

do -- the ghost model is not made for a Molded that has a body here
    local env, W = molded_world("join", specs3(), { on = false, settings = { pup_on2 = true } }) -- (10.21: the models are off by default; this world ticks the box)
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 2)
    local pup = health(env).enemy_models
    local function wants(p, name) for _, n in ipairs(p and p.wanted or {}) do if n == name then return true end end return false end
    check(pup ~= nil and pup.wanted ~= nil, "(10.15) copies: the debug file lists the enemy models wanted")
    local before = wants(pup, NAME_A)
    env.check_override[BOX_MOLD] = true
    run_ui(env)
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    check(wants(pup, NAME_A) == before, "(10.15) copies: (the list read before the copy)")
    local pup2 = health(env).enemy_models
    check(not wants(pup2, NAME_A), "(10.15) copies: with a copy of it in this game the ghost model is not made for it" .. (before and "" or " (it was not wanted before either: models may be off in this world)"))
end

do -- the last session ended inside the Molded work: the player is told; ticking the box again tries again
    local env, W = molded_world("join", specs3(), { on = false, before_load = function(e) e.files["re7mp/lastcall.json"] = { stage = "molded", call = "taking Em4000_x", time = 1700000000, session = 1, clock = 1 } end })
    check(log_has(env, "previous session: The last session ended while the script was moving a copy of the host's Molded in this game"), "(10.15) copies: a marker from a session that ended inside the Molded work is reported at the start")
    check(molded_report(env).previous_session_ended_inside_it == true, "(10.15) copies: ...and the debug file says so")
    env.check_override[BOX_MOLD] = true
    run_ui(env)
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    check(W.bodies[1].fsm_on == false and molded_report(env).previous_session_ended_inside_it == false, "(10.15) copies: ...ticking the box again (by hand) tries again, and the marker is forgiven")
end

do -- a Molded that walks is warped on every frame; one that stands still four times a second; the frame is looked at once a second
    local env, W = molded_world("join", specs3())
    mfeed(env, { ment(NAME_A, 20, 30) })
    mlive(env, 3)
    local w0, f0 = #W.warps, W.frame_reads or 0
    mlive(env, 4)
    local still, frames_read = #W.warps - w0, (W.frame_reads or 0) - f0
    check(still >= 12 and still <= 22, "(10.15) copies: standing still: " .. still .. " warps in 4 s (four a second)")
    check(frames_read >= 3 and frames_read <= 6, "(10.15) copies: the clip's frame is looked at once a second, not on every frame (" .. frames_read .. " reads in 4 s)")
    local x, w1 = 20, #W.warps
    for _ = 1, 20 do
        x = x + 0.5
        mfeed(env, { ment(NAME_A, x, 30) })
        mlive(env, 0.2)
    end
    local walking = #W.warps - w1
    check(walking >= 60, "(10.15) copies: walking at 2.5 m/s the copy is warped on (nearly) every frame (" .. walking .. " warps in 4 s, 80 frames)")
    local px = select(1, pos_of(W.bodies[1]))
    check(px > 28 and px < 31, "(10.15) copies: ...and it keeps up (at x " .. string.format("%.1f", px) .. " when the host's is at " .. x .. ")")
end

do -- the message inbox is read about ten times a second while it is quiet, and as often as the pose file for two seconds after a message
    local env = new_environment()
    build_world(env)
    env.G.RE7MP_TEST_QUIET_S = nil -- (the older checks keep the inbox at every pose read; this one has the real rate)
    load_script(env)
    host_role_files(env, "join", "tcp")
    local reads = 0
    local real_load = env.G.json.load_file
    env.G.json.load_file = function(name) if name == "re7mp_msg_in.json" then reads = reads + 1 end return real_load(name) end
    for _ = 1, 40 do run_frames(env, 0.05) bump_remote(env) end
    reads = 0
    for _ = 1, 100 do run_frames(env, 0.05) bump_remote(env) end
    check(reads >= 40 and reads <= 60, "(10.15) inbox: quiet: about ten reads a second at 20 frames a second (" .. reads .. " reads in 5 s; every frame would be 100)")
    push_msgs(env, { { 1, "poll test one" } })
    local heard
    for i = 1, 8 do
        run_frames(env, 0.05)
        bump_remote(env)
        if texts_have(env, "poll test one") then heard = i break end
    end
    check(heard ~= nil and heard <= 3, "(10.15) inbox: the first message after a quiet time is handled within 0.15 s (frame " .. tostring(heard) .. ")")
    reads = 0
    push_msgs(env, { { 1, "poll test two" } })
    local heard2
    for i = 1, 30 do
        run_frames(env, 0.05)
        bump_remote(env)
        if not heard2 and texts_have(env, "poll test two") then heard2 = i end
    end
    check(heard2 ~= nil and heard2 <= 2, "(10.15) inbox: right after a message the next one is handled on the next frame or two (frame " .. tostring(heard2) .. ")")
    check(reads >= 25, "(10.15) inbox: ...the inbox is read on (nearly) every pose read for two seconds after a message (" .. reads .. " reads in 1.5 s)")
    for _ = 1, 60 do run_frames(env, 0.05) bump_remote(env) end -- (the two seconds are over)
    reads = 0
    for _ = 1, 100 do run_frames(env, 0.05) bump_remote(env) end
    check(reads >= 40 and reads <= 60, "(10.15) inbox: ...and quiet again after that (" .. reads .. " reads in 5 s)")
    local rp = health(env).bridge_reads.message_inbox_poll
    check(rp and rp.quiet_s == 0.1 and rp.active_s == 2 and rp.reads > 100 and rp.reads_left_out > 100, "(10.15) inbox: the debug file says how often it reads and how many reads were left out (" .. tostring(rp and rp.reads) .. " / " .. tostring(rp and rp.reads_left_out) .. ")")
    check(not log_has(env, "script error") and not log_has(env, "message handler error"), "(10.15) inbox: no error")
end

do -- the host's side with the copies ticked (a joiner that is also a host is not a thing, but the switch must do nothing there)
    local env, W = molded_world("host", specs3())
    check(not W.three_arg and #W.warps == 0 and #W.asked == 0 and #W.think == 0, "(10.15) copies: on the host nothing is warped, asked or switched off")
end

H.weapons_by_type["app.EnemySpawnInfo"] = nil

-- =============================================================================================
-- RE7MP_PROFILE=1 RE7MP_ONLY_1015=1 luarun tools/lua_smoke.lua lua/re7mp.lua
-- How much the script asks of the (fake) game, per second at 60 frames a second, in four steady states. The number of calls into the game and of file reads and writes is what
-- costs in the real game, so this is where an optimisation is looked for. It checks nothing; it prints.
-- =============================================================================================
if os.getenv("RE7MP_PROFILE") then
    local function counted(label, env, secs, per_frame, no_bump)
        local counts, total, files = {}, 0, {}
        local real = { call = Obj.call, get = Obj.get_field, set = Obj.set_field, addr = Obj.get_address, td = Obj.get_type_definition }
        local sites = {}
        local by_line = os.getenv("RE7MP_PROFILE_LINES") ~= nil
        local function bump(k)
            counts[k] = (counts[k] or 0) + 1
            total = total + 1
            if by_line then -- which line of the script asked (the first stack level that is not this test file)
                for lv = 3, 9 do
                    local info = debug.getinfo(lv, "Sl")
                    if not info then break end
                    if not info.short_src:find("lua_smoke", 1, true) and info.short_src ~= "[C]" then
                        local key = info.short_src:match("[^/]*$") .. ":" .. info.currentline
                        sites[key] = (sites[key] or 0) + 1
                        break
                    end
                end
            end
        end
        Obj.call = function(self, name, ...) bump(self._type .. ":" .. tostring(name)) return real.call(self, name, ...) end
        Obj.get_field = function(self, name) bump(self._type .. ".field:" .. tostring(name)) return real.get(self, name) end
        Obj.set_field = function(self, name, v) bump(self._type .. ".set_field:" .. tostring(name)) return real.set(self, name, v) end
        Obj.get_address = function(self) bump("get_address") return real.addr(self) end
        Obj.get_type_definition = function(self) bump("get_type_definition") return real.td(self) end
        local G = env.G
        local sdk_real = {}
        for k, v in pairs(G.sdk) do
            if type(v) == "function" then
                sdk_real[k] = v
                G.sdk[k] = function(...) bump("sdk." .. k) return v(...) end
            end
        end
        local jl, jd = G.json.load_file, G.json.dump_file
        G.json.load_file = function(n) files["read  " .. n] = (files["read  " .. n] or 0) + 1 return jl(n) end
        G.json.dump_file = function(n, t) files["write " .. n] = (files["write " .. n] or 0) + 1 return jd(n, t) end
        local t0 = os.clock()
        local frames = math.floor(secs * 60 + 0.5)
        for i = 1, frames do
            if per_frame then per_frame(i) end
            run_frames(env, 1 / 60, 1 / 60)
            if not no_bump then bump_remote(env) end
        end
        local cpu = os.clock() - t0
        Obj.call, Obj.get_field, Obj.set_field, Obj.get_address, Obj.get_type_definition = real.call, real.get, real.set, real.addr, real.td
        for k, v in pairs(sdk_real) do G.sdk[k] = v end
        G.json.load_file, G.json.dump_file = jl, jd
        local rows = {}
        for k, n in pairs(counts) do rows[#rows + 1] = { k = k, n = n } end
        table.sort(rows, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
        print(string.format("\n== %s: %.0f game calls a second (%d frames in %.2f s of the machine's time, so %.2f ms a frame in the stand-in)", label, total / secs, frames, cpu, cpu / frames * 1000))
        for i = 1, math.min(#rows, tonumber(os.getenv("RE7MP_PROFILE_ROWS") or 18)) do print(string.format("   %7.1f /s  %s", rows[i].n / secs, rows[i].k)) end
        if by_line then
            local srows = {}
            for k, n in pairs(sites) do srows[#srows + 1] = { k = k, n = n } end
            table.sort(srows, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
            print("   -- by line of the script:")
            for i = 1, math.min(#srows, 22) do print(string.format("   %7.1f /s  %s", srows[i].n / secs, srows[i].k)) end
        end
        local fl = {}
        for k, n in pairs(files) do fl[#fl + 1] = string.format("%s x%.1f/s", k, n / secs) end
        table.sort(fl)
        for _, l in ipairs(fl) do print("   file: " .. l) end
        return total / secs
    end
    local function busy_specs()
        local s = {}
        for i = 1, 6 do s[i] = { guid = { 0x4000 + i, 0x5000 + i }, pos = vec(8 + i * 2, 0, 12) } end
        return s
    end
    -- the host: 6 Molded from spawn points + the world's own three enemies, the other player connected
    local envh, Wh = molded_world("host", busy_specs())
    run_frames(envh, 3, 1 / 60)
    counted("HOST with the other player connected (9 enemies)", envh, 10, nil)
    local payload = envh.files["re7mp_state_out.json"] and envh.files["re7mp_state_out.json"].p or ""
    -- the host with nobody connected: the enemy work stops
    local envn = molded_world("host", busy_specs())
    run_frames(envn, 12, 1 / 60) -- (no more messages from the other game: the peer times out)
    counted("HOST with nobody connected", envn, 6, nil, true)
    -- the joiner, copies off (mode 3), and with the copies on
    local function feed_from_host(env)
        return function(i)
            if i % 4 == 1 then
                local rest = payload:gsub("^T[%d%.]+;?", "")
                env.snap_n = (env.snap_n or 500) + 1
                env.files["re7mp_state_in.json"] = { seq = env.snap_n, n = env.snap_n, p = string.format("T%.3f;%s", env.clock, rest) }
            end
        end
    end
    local envj = molded_world("join", busy_specs(), { on = false })
    run_frames(envj, 3, 1 / 60)
    counted("JOINER, mode 3, Molded copies off (9 enemies from the host)", envj, 10, feed_from_host(envj))
    local envc = molded_world("join", busy_specs(), { on = true })
    run_frames(envc, 3, 1 / 60)
    counted("JOINER, mode 3, Molded copies ON (9 enemies from the host)", envc, 10, feed_from_host(envc))
end
