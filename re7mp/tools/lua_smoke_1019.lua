-- Checks of build 10.19 for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1019_file) with that file's helpers in one table.
--   RE7MP_ONLY_1019=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What it covers (all of it is the game's behaviour AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   1. re7mp.exe's box "Sync enemies and the Molded" (re7mp_enemysync.json): applied once per seq, ticked = mode 3 + AI off + Molded copies, unticked = back
--   2. the garage car sync: gating (mode 3, the story step), who claims, the other player's forced get-in, the puppet (brain / state machine / interacts off), the car put where the
--      runner's is, the ghost at the second seat, damage mirrored once each, run-overs, the end (AfterExplosion + breakAll + get out), release, a joiner that runs the car
--   3. the actor probe (reads only)
--   4. (10.27, at the end) what the first real file showed: the story number through get_CastS32, the car's state when its Fsm field answers nothing, the windows asked one by one,
--      the action delegate, a state nobody listed, and the two probes' new limits (520 fields, 80 objects, the state trail)
local H = ...
local check, Obj, make_td, make_go, make_scene, vec = H.check, H.Obj, H.make_td, H.make_go, H.make_scene, H.vec
local new_environment, build_world, load_script, host_role_files = H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, texts_have, log_has = H.run_frames, H.run_ui, H.ui_has, H.texts_have, H.log_has
local messages_of_kind, bump_remote = H.messages_of_kind, H.bump_remote

local BOX_CAR = "Garage car sync (Jack's car; needs mode 3): whoever gets in first drives, the other player gets in too, and the other game's car follows (remembered)##carsync"
local BOX_RIDE = "The other player's own player gets in too (Interact_GetInto is fired for them)##carride"
local BOX_RUN = "A run-over: the runner's car hits my player when it drives over them (amount below, never lethal in one pass)##carrun"
local BOX_ACTORS = "Actor probe (reads only): list the scene's objects that run a script of their own like the garage car, to re7mp/actor_probe.json (not remembered)##actorprobe"
local BTN_OUT = "Get me out of the car##carout"
local BTN_LET = "Let go of the car now (everything back as the game has it)##carrelease"

local function live(env, secs)
    for _ = 1, math.floor(secs / 0.05 + 0.5) do
        run_frames(env, 0.05)
        bump_remote(env)
    end
end

local function health(env)
    for _ = 1, 24 do run_frames(env, 0.05) bump_remote(env) end -- (the other player's packets keep coming: a health read must not make them stale)
    env.ui_press["Clear the debug log"] = true
    run_ui(env)
    for _ = 1, 12 do run_frames(env, 0.05) bump_remote(env) end
    return env.files["re7mp/debug.json"].health
end

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

local function tick(env, label, on)
    env.check_override[label] = on
    run_ui(env)
    run_ui(env)
end

local function deliver(to, k, p)
    to.msg_n = (to.msg_n or 0) + 1
    to.inbox = to.inbox or {}
    to.inbox[#to.inbox + 1] = { n = to.msg_n, id = to.msg_n, k = k, p = p }
    to.files["re7mp_msg_in.json"] = { epoch = 1, msgs = to.inbox }
end

local function relay(from, to)
    local out = from.files["re7mp_msg_out.json"]
    for _, m in ipairs(out and out.msgs or {}) do
        if m.id > (from.relayed or 0) then
            from.relayed = m.id
            from.sent_log = from.sent_log or {}
            from.sent_log[#from.sent_log + 1] = tostring(m.k) .. ":" .. tostring(m.p)
            deliver(to, m.k, m.p)
        end
    end
    local s = from.files["re7mp_state_out.json"]
    if s and s.seq ~= from.relayed_state then
        from.relayed_state = s.seq
        to.files["re7mp_state_in.json"] = { seq = s.seq, n = s.seq, p = s.p }
    end
end

local function step(a, b, secs, each)
    for _ = 1, math.floor(secs / 0.05 + 0.5) do
        if each then each() end
        run_frames(a, 0.05)
        run_frames(b, 0.05)
        bump_remote(a)
        bump_remote(b)
        relay(a, b)
        relay(b, a)
    end
end

local function sent_has(env, prefix)
    for _, m in ipairs(env.sent_log or {}) do
        if m:find(prefix, 1, true) == 1 then return true end
    end
    return false
end

local function sent_count(env, prefix)
    local n = 0
    for _, m in ipairs(env.sent_log or {}) do
        if m:find(prefix, 1, true) == 1 then n = n + 1 end
    end
    return n
end

-- where each player stands: their own player object and camera, and where the other game sees them
local function stand(host, join, hx, hz, jx, jz)
    host.camera_pos, join.camera_pos = vec(hx, 1.6, hz), vec(jx, 1.6, jz)
    host.player.xf:call("set_Position", vec(hx, 0, hz))
    join.player.xf:call("set_Position", vec(jx, 0, jz))
    local a, b = host.files["re7mp_in.json"], join.files["re7mp_in.json"]
    a.x, a.y, a.z = jx, 1.6, jz
    b.x, b.y, b.z = hx, 1.6, hz
end

-- A fake story flow: c03_1_Main (hash 9fb77189) at rec.num
local function flow_setup(rec)
    return function(env)
        rec.num = rec.num or 900
        local flow_go = make_go("c03_1_MainFlow", vec(0, 0, 0), {})
        local ctrl = Obj.new("app.GameFlowActiveControl", {
            get_GameObject = function() return flow_go end,
            hasState = function(_, n) return n % 100 == 0 and n <= 1200 end,
            ["sendNo(System.Int32)"] = function() end,
        }, { FlowEndNo = 1200 })
        local entry = Obj.new("Entry", {}, { key = 0x9fb77189, value = ctrl })
        local dict = Obj.new("System.Collections.Generic.Dictionary", {}, { _entries = { get_elements = function() return { entry } end }, _count = 1 })
        local mgr = Obj.new("app.GameFlowFsmManager", {
            ["getProgressiveNo(System.UInt32)"] = function()
                local n = rec.num
                local m = { get_Value = function() return n end }
                -- (10.27) the real game's number holder (via.userdata.Variable) has get_CastS32 / get_S32 / get_U32 ... and no get_Value
                if rec.var_kind == "cast" then m = { get_CastS32 = function() return n end, get_S32 = function() return n end, get_U32 = function() return n end }
                elseif rec.var_kind == "s32" then m = { get_S32 = function() return n end }
                elseif rec.var_kind == "bad" then m = { get_CastS32 = function() return -1 end, get_S32 = function() return 0 / 0 end, get_CastF32 = function() return 1e12 end } end
                return Obj.new("via.userdata.Variable", m)
            end,
            ["setProgressiveNo(System.UInt32, System.Int32)"] = function() end,
        }, { Flows = dict })
        env.singletons["app.GameFlowFsmManager"] = mgr
    end
end

local TYRES = { "FrontLeft", "FrontRight", "RearLeft", "RearRight" }

-- A fake garage car: the brain (app.CarInGarage), the state machine, three interact children, Jack. rec is the test's handle on it.
local function car_setup(rec)
    return function(env)
        rec.state = rec.state or "WaitPlayerGetInto"
        rec.x, rec.z = rec.x or 5, rec.z or 3
        rec.win, rec.fc, rec.rc, rec.door, rec.speed = rec.win or 0, rec.fc or 0, rec.rc or 0, rec.door or false, rec.speed or 0
        rec.tyre, rec.enemy_driving = {}, rec.enemy_driving or false
        rec.log, rec.kid_on, rec.brain_on, rec.paused = {}, {}, true, false
        rec.get_in, rec.get_out, rec.broke_all, rec.set_state_to, rec.windows_broken, rec.tyres_blown = 0, 0, false, nil, {}, {}
        local fields = {}
        for _, t in ipairs(TYRES) do fields[#fields + 1] = { "Is" .. t .. "BlownOut", "System.Boolean" } end
        fields[#fields + 1] = { "DriveSpeed", "System.Single" }
        make_td("app.CarInGarage", { fields = fields })
        local fsm = Obj.new("via.fsm.Fsm", {
            ["getCurrentState(System.UInt32)"] = function() return rec.state end,
            set_Paused = function(_, v) rec.paused = v rec.log[#rec.log + 1] = "paused " .. tostring(v) end,
            ["setCurrentState(System.String)"] = function(_, name)
                rec.log[#rec.log + 1] = "state " .. name
                if rec.refuse_state then return end -- (a game that takes the call and does nothing)
                rec.set_state_to, rec.state = name, name
            end,
        })
        -- (10.27) the real game's Fsm field answered nothing while the component route worked: rec.dud_field_fsm makes the brain's "Fsm" field such an object
        local dud = Obj.new("via.fsm.Fsm", { ["getCurrentState(System.UInt32)"] = function() return "" end })
        dud.addr, fsm.addr = 0x7100, 0x7000
        local jack_go = env.jack -- the world's Jack (an enemy with its components), as the garage's Em3000, the only enemy of the scene
        jack_go.m.get_Name = function() return "Em3000" end
        jack_go.xf:call("set_Position", vec(rec.x + 2, 0, rec.z))
        env.scene = make_scene({ env.player, jack_go })
        rec.jack = jack_go
        local f = { Fsm = fsm, Enemy = Obj.new("app.Em3000", { get_GameObject = function() return jack_go end }) }
        local brain
        brain = Obj.new("app.CarInGarage", {
            get_GameObject = function() return rec.go end,
            set_Enabled = function(_, v) rec.brain_on = v rec.log[#rec.log + 1] = "brain " .. tostring(v) end,
            breakWindow = function(_, n) rec.windows_broken[#rec.windows_broken + 1] = n rec.log[#rec.log + 1] = "breakWindow " .. n end,
            breakFrontBody = function() rec.front_calls = (rec.front_calls or 0) + 1 rec.log[#rec.log + 1] = "breakFrontBody" end,
            breakRearBody = function() rec.rear_calls = (rec.rear_calls or 0) + 1 rec.log[#rec.log + 1] = "breakRearBody" end,
            breakOriginalLeftDoor = function() rec.door_calls = (rec.door_calls or 0) + 1 rec.log[#rec.log + 1] = "breakOriginalLeftDoor" end,
            breakAll = function() rec.broke_all = true rec.log[#rec.log + 1] = "breakAll" end,
            isWindowBroken = function(_, n) rec.win_calls = (rec.win_calls or 0) + 1 return (rec.win_bits or {})[n] == true end, -- (10.27)
        }, f)
        for _, t in ipairs(TYRES) do
            brain.m["blowOut" .. t] = function() rec.tyres_blown[#rec.tyres_blown + 1] = t rec.log[#rec.log + 1] = "blowOut" .. t end
        end
        -- the brain's flags are read live from rec
        brain.get_field = function(self, name)
            if name == "Fsm" then if rec.dud_field_fsm then return dud end return fsm end
            if name == "Enemy" then return f.Enemy end
            if name == "DriveSpeed" then return rec.speed end
            if name == "FlagWindowBroken" then
                if rec.no_win_field then error("fake: no field FlagWindowBroken") end -- (10.27) a car that has no such field: the windows are asked one by one
                return rec.win
            end
            if name == "CurrentAction" and rec.action_method then -- (10.27) a delegate that says which method it holds
                return Obj.new("app.CarInGarage.Action", { get_Method = function() return Obj.new("System.Reflection.MethodInfo", { get_Name = function() return rec.action_method end }) end })
            end
            if name == "CrashCountForFrontBody" then return rec.fc end
            if name == "CrashCountForRearBody" then return rec.rc end
            if name == "IsDoorBroken" then return rec.door end
            if name == "IsEnemyDriving" then return rec.enemy_driving end
            if name == "IsPlayerDriving" then return rec.state == "PlayerGetInto" or rec.state == "WaitEnemyGetPlayerOut" end
            if name == "IsCrashed" or name == "IsEnemyHijack" then return false end
            local which = name:match("^Is(%a+)BlownOut$")
            if which then return rec.tyre[which] == true end
            error("fake: no field " .. tostring(name))
        end
        local function kid(name, on_success)
            local comp = Obj.new("app.InteractSendFsm", {
                set_Enabled = function(_, v) rec.kid_on[name] = v rec.log[#rec.log + 1] = name .. " " .. tostring(v) end,
                successInteract = function() on_success() rec.log[#rec.log + 1] = name .. " fired" end,
            })
            return make_go(name, vec(rec.x, 0, rec.z), { comp })
        end
        local k1 = kid("Interact_GetInto", function() rec.get_in = rec.get_in + 1 if rec.state == "WaitPlayerGetInto" then rec.state = "PlayerGetInto" end end)
        local k2 = kid("Interact_Ignition", function() end)
        local k3 = kid("Interact_GetOut", function() rec.get_out = rec.get_out + 1 end)
        k1.xf._next, k2.xf._next = k2.xf, k3.xf
        rec.go = make_go("sm9104_EthanCar_Garage", vec(rec.x, 0, rec.z), { brain, fsm })
        rec.go.xf.m.get_Child = function() return k1.xf end
        rec.brain, rec.fsm = brain, fsm
        -- the scene answers findComponents for the brain
        local orig = env.scene.m["findComponents(System.Type)"]
        env.scene.m["findComponents(System.Type)"] = function(self, t)
            if t == "app.CarInGarage" then return { get_elements = function() return rec.absent and {} or { brain } end } end
            return orig(self, t)
        end
        local pos = rec.go.xf.m.get_Position
        rec.pos = function() return pos(rec.go.xf) end
    end
end

local function both(...)
    local fns = { ... }
    return function(env) for _, f in ipairs(fns) do f(env) end end
end

local function gc(env) return health(env).garage_car end

local function pair(hrec, jrec, hflow, jflow)
    local host = world("host", both(flow_setup(hflow), car_setup(hrec)))
    local join = world("join", both(flow_setup(jflow), car_setup(jrec)))
    stand(host, join, 4, 3, 3, 3)
    host.combo_override["Enemy sync"] = 3
    join.combo_override["Enemy sync"] = 3
    run_ui(host)
    run_ui(join)
    return host, join
end

-- =============================================================================================
-- 1. re7mp.exe's box
-- =============================================================================================
do
    local env = world("host")
    live(env, 5)
    local h = health(env)
    check(h.enemy_sync_tick and h.enemy_sync_tick.exe_box == nil and h.enemy_sync_tick.applied_times == 0, "(10.19) exe box: no file: nothing applied")
    check(h.enemy_sync_tick and h.enemy_sync_tick.enemy_mode_now == 3, "(10.19) exe box: ...and the enemy mode stays at the default (3 since 10.22; 2 before)")
    env.files["re7mp_enemysync.json"] = { enemy_sync = "yes", seq = 1 }
    live(env, 3)
    h = health(env)
    check(h.enemy_sync_tick.applied_times == 0, "(10.19) exe box: a value that is not true / false is not applied")
    env.files["re7mp_enemysync.json"] = { enemy_sync = true, seq = 1 }
    live(env, 3)
    h = health(env)
    local E = h.enemy_sync_tick
    check(E.exe_box == true and E.applied_times == 1 and E.enemy_mode_now == 3 and E.drive_ai_now == true, "(10.19) exe box: ticked: enemy mode 3 and the copies' AI off: " .. tostring(E.enemy_mode_now) .. " " .. tostring(E.drive_ai_now))
    check(E.molded_on_now == true, "(10.19) exe box: ...and the Molded copies on")
    check(log_has(env, "Sync enemies and the Molded"), "(10.19) exe box: ...and it is said in the log")
    env.combo_override["Enemy sync"] = 2
    run_ui(env)
    live(env, 5)
    h = health(env)
    check(h.enemy_sync_tick.applied_times == 1 and h.enemy_sync_tick.enemy_mode_now == 2, "(10.19) exe box: the same seq is not applied again (a later change in the panel stays): " .. tostring(h.enemy_sync_tick.enemy_mode_now))
    env.combo_override["Enemy sync"] = 3
    run_ui(env)
    live(env, 2)
    check(health(env).enemy_sync_tick.enemy_mode_now == 3, "(10.19) exe box: (the panel's mode is put back to 3 for the next check)")
    env.files["re7mp_enemysync.json"] = { enemy_sync = false, seq = 2 }
    live(env, 3)
    h = health(env)
    E = h.enemy_sync_tick
    check(E.exe_box == false and E.applied_times == 2 and E.enemy_mode_now == 2 and E.drive_ai_now == false and E.molded_on_now == false, "(10.19) exe box: a new seq with false: back to mode 2, AI on, no Molded copies")
    env.files["re7mp_enemysync.json"] = { enemy_sync = true, seq = 3 }
    live(env, 3)
    check(health(env).enemy_sync_tick.enemy_mode_now == 3, "(10.19) exe box: ticked again: mode 3 again")
    run_ui(env)
    check(ui_has(env, "re7mp.exe's 'Sync enemies and the Molded' box: ON"), "(10.19) exe box: the panel says what the box said")
    check(not log_has(env, "script error"), "(10.19) exe box: no script error")
end

-- =============================================================================================
-- 2. the garage car: gating
-- =============================================================================================
do
    local rec, flow = { state = "WaitPlayerGetInto" }, { num = 900 }
    local env = world("host", both(flow_setup(flow), car_setup(rec)), { enemy_mode2 = 2 }) -- (10.22: mode 3 is the default now; the gating of mode 2 is what this block checks, so it is chosen from the start)
    env.camera_pos = vec(4, 1.6, 3)
    env.player.xf:call("set_Position", vec(4, 0, 3))
    live(env, 6)
    local g = gc(env)
    check(g and g.on == true, "(10.19) garage car: on by default (the owner will not release before it is tried)")
    check(tostring(g.status):find("needs enemy sync mode 3", 1, true) ~= nil and g.car_found == false, "(10.19) garage car: mode 2: it waits and says why (and does not look for the car): " .. tostring(g.status))
    check(#messages_of_kind(env, 19) == 0 and #rec.log == 0, "(10.19) garage car: ...no message, and nothing done to the car")
    check(g.counts.looks == 0, "(10.19) garage car: ...no look at the scene")
    env.combo_override["Enemy sync"] = 3
    run_ui(env)
    flow.num = 300
    live(env, 6)
    g = gc(env)
    check(tostring(g.status):find("the story is at 300", 1, true) ~= nil and g.car_found == false, "(10.19) garage car: mode 3 but the story is before the fight (300): it waits: " .. tostring(g.status))
    flow.num = 900
    live(env, 6)
    g = gc(env)
    check(g.car_found == true and g.car_name == "sm9104_EthanCar_Garage", "(10.19) garage car: the story is at 900: the car is found: " .. tostring(g.car_name) .. " / " .. tostring(g.status))
    check(g.my_state == "WaitPlayerGetInto" and g.jack == "Em3000" and g.tyre_flags == 4, "(10.19) garage car: ...with its state, Jack's name (Em3000, not Em2000) and four tyre flags: " .. tostring(g.my_state) .. " " .. tostring(g.jack) .. " " .. tostring(g.tyre_flags))
    local kids = table.concat(g.interact_children or {}, ",")
    check(kids == "GetInto,GetOut,Ignition", "(10.19) garage car: ...and its three interact children: " .. kids)
    check(g.claim == nil and #messages_of_kind(env, 19) == 0, "(10.19) garage car: nobody got in: no claim, no message")
    tick(env, BOX_CAR, false)
    live(env, 2)
    check(tostring(gc(env).status) == "off", "(10.19) garage car: its box turns it off")
    env.files["re7mp/settings.json"] = nil
    check(not log_has(env, "script error"), "(10.19) garage car: gating: no script error")
end

-- =============================================================================================
-- 3. the host gets in first: claim, forced ride, puppet, position, ghost seat, damage, end
-- =============================================================================================
do
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900 }, { num = 900 })
    step(host, join, 5)
    check(gc(host).car_found == true and gc(join).car_found == true, "(10.19) ride: both games find their car")
    check(sent_count(host, "19:") == 0 and sent_count(join, "19:") == 0, "(10.19) ride: nobody has got in: no claim sent")
    hrec.state = "PlayerGetInto" -- the host's player gets in
    step(host, join, 1.5)
    local hg, jg = gc(host), gc(join)
    check(hg.claim and hg.claim.by == "me", "(10.19) ride: the host got in first: it claims the car")
    check(sent_has(host, "19:c|PlayerGetInto|1"), "(10.19) ride: ...told as 'c|state|seq': " .. table.concat(host.sent_log or {}, " ; "):sub(1, 140))
    check(jg.claim and jg.claim.by == "peer", "(10.19) ride: the joiner heard it: the other player runs the car")
    check(jrec.get_in == 1, "(10.19) ride: ...and the joiner's own Interact_GetInto was fired once: " .. tostring(jrec.get_in))
    check(jrec.state == "PlayerGetInto", "(10.19) ride: ...so the joiner's car is in the same state as the host's")
    hrec.state = "WaitEnemyGetPlayerOut"
    step(host, join, 1.5)
    jg = gc(join)
    check(jg.puppet == true and jg.ride_phase == "puppet", "(10.19) ride: the joiner's car became a puppet: " .. tostring(jg.puppet) .. " " .. tostring(jg.ride_phase))
    check(jrec.paused == true and jrec.brain_on == false, "(10.19) ride: ...its state machine paused and its brain off")
    check(jrec.kid_on.Interact_GetInto == false and jrec.kid_on.Interact_Ignition == false and jrec.kid_on.Interact_GetOut == false, "(10.19) ride: ...and the three interacts off")
    check(hrec.paused == false and hrec.brain_on == true, "(10.19) ride: the host's own car is untouched")
    check(jg.runner_state == "WaitEnemyGetPlayerOut", "(10.19) ride: the joiner sees the runner's state: " .. tostring(jg.runner_state))
    -- the host's car drives; the joiner's car follows it
    local sx, sz = hrec.x, hrec.z
    for i = 1, 40 do
        hrec.x, hrec.z = sx + i * 0.2, sz + i * 0.15
        hrec.go.xf:call("set_Position", vec(hrec.x, 0, hrec.z))
        step(host, join, 0.05)
    end
    step(host, join, 0.5)
    local jp, hp = jrec.pos(), hrec.pos()
    check(math.abs(jp.x - hp.x) < 1.0 and math.abs(jp.z - hp.z) < 1.0, string.format("(10.19) ride: the joiner's puppet car is where the host's is: host %.1f/%.1f, joiner %.1f/%.1f", hp.x, hp.z, jp.x, jp.z))
    check(math.abs(jp.x - sx) > 3, "(10.19) ride: ...and it moved there (not left at its start)")
    local ptext = host.files["re7mp_state_out.json"] and host.files["re7mp_state_out.json"].p or ""
    check(ptext:match("^T[%d%.]+;#car,") ~= nil, "(10.19) ride: the host's state text carries the car line FIRST (after the clock): " .. ptext:sub(1, 90))
    check(jg.counts.lines_read > 5 or gc(join).counts.lines_read > 5, "(10.19) ride: the joiner read the lines")
    do
        local jg2, hg2 = gc(join), gc(host)
        check(jg2.ghost_seat_last and math.abs(jg2.ghost_seat_last.moved_m - 0.7) < 0.05 and hg2.ghost_seat_last and math.abs(hg2.ghost_seat_last.moved_m - 0.7) < 0.05, "(10.19) ride: ...0.7 m to the car's right (the seat offset): " .. tostring(jg2.ghost_seat_last and jg2.ghost_seat_last.moved_m))
        local pp = join.player.xf:call("get_Position")
        check(math.abs(pp.x - jrec.pos().x) < 3 and math.abs(pp.z - jrec.pos().z) < 3 and jg2.counts.carried > 0, string.format("(10.19) ride: the rider is carried along with the car (player %.1f/%.1f, car %.1f/%.1f, carried %d)", pp.x, pp.z, jrec.pos().x, jrec.pos().z, jg2.counts.carried))
    end
    check(gc(join).counts.seat_shifted > 0 and gc(host).counts.seat_shifted > 0, "(10.19) ride: each ghost is drawn at the second seat (shifted " .. tostring(gc(host).counts.seat_shifted) .. " / " .. tostring(gc(join).counts.seat_shifted) .. ")")
    -- damage: windows 2 and 3, the front body, the door, a tyre: each mirrored ONCE
    hrec.win, hrec.fc, hrec.door = (1 << 2) | (1 << 3), 1, true
    hrec.tyre.FrontLeft = true
    step(host, join, 3)
    local w = table.concat(jrec.windows_broken, ",")
    check(w == "2,3" or w == "3,2", "(10.19) damage: windows 2 and 3 were broken in the joiner's game, once each: " .. w)
    check((jrec.front_calls or 0) == 1 and (jrec.door_calls or 0) == 1 and #jrec.tyres_blown == 1 and jrec.tyres_blown[1] == "FrontLeft", "(10.19) damage: ...the front body once, the door once, the tyre once: " .. tostring(jrec.front_calls) .. " " .. tostring(jrec.door_calls) .. " " .. table.concat(jrec.tyres_blown, ","))
    step(host, join, 3)
    check(#jrec.windows_broken == 2 and (jrec.front_calls or 0) == 1 and #jrec.tyres_blown == 1, "(10.19) damage: ...and not again later")
    hrec.rc = 2
    step(host, join, 3)
    check((jrec.rear_calls or 0) == 2, "(10.19) damage: two new rear crashes are two rear breaks: " .. tostring(jrec.rear_calls))
    check(not (jrec.broke_all) and jrec.set_state_to == nil, "(10.19) damage: nothing ends the fight by itself")
    -- the end
    hrec.state = "AfterExplosion"
    step(host, join, 3)
    check(sent_has(host, "19:x|exploded"), "(10.19) end: the runner tells the other game: " .. table.concat(host.sent_log or {}, " ; "):sub(-90))
    check(jrec.set_state_to == "AfterExplosion", "(10.19) end: the joiner's car is set to AfterExplosion")
    check(jrec.broke_all == true, "(10.19) end: ...breakAll() was called on it")
    check(jrec.get_out == 1, "(10.19) end: ...and the joiner's player got out (Interact_GetOut fired once): " .. tostring(jrec.get_out))
    check(jrec.paused == false and jrec.brain_on == true and jrec.kid_on.Interact_GetOut == true, "(10.19) end: ...everything the puppet switched off is back on")
    do
        local log = table.concat(jrec.log, ","):gsub("%s", "")
        local i_unpause, i_state = log:find("pausedfalse", 1, true), log:find("stateAfterExplosion", 1, true)
        check(i_unpause and i_state and i_unpause < i_state, "(10.19) end: ...and the car was given back (state machine running) BEFORE its state was set")
    end
    local order = table.concat(jrec.log, ","):gsub("%s", "")
    local i_state, i_break, i_out = order:find("stateAfterExplosion", 1, true), order:find("breakAll", 1, true), order:find("Interact_GetOutfired", 1, true)
    check(i_state and i_break and i_out and i_state < i_break and i_break < i_out, "(10.19) end: ...in that order: the state, then breakAll, then get out")
    jg = gc(join)
    check(jg.claim == nil and jg.puppet == false, "(10.19) end: the joiner has let go: " .. tostring(jg.claim and jg.claim.by))
    step(host, join, 5)
    check(gc(host).claim == nil, "(10.19) end: the runner lets go a few seconds after")
    local claims_at_end = sent_count(host, "19:c|") + sent_count(join, "19:c|")
    step(host, join, 8)
    check(sent_count(host, "19:c|") + sent_count(join, "19:c|") == claims_at_end, "(10.19) end: ...and no new claim bounces back afterwards (claims: " .. claims_at_end .. " before, " .. (sent_count(host, "19:c|") + sent_count(join, "19:c|")) .. " after)")
    check(gc(join).claim == nil, "(10.19) end: ...and the joiner does not take the car again (the cool-down)")
    local jf = join.files["re7mp/car_sync.json"] or join.files["re7mp_car_sync.json"]
    check(jf and jf.report and #jf.report.transitions >= 1, "(10.19) journal: the joiner's journal file has the state changes")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.19) ride: no script error in either game")
end

-- =============================================================================================
-- 4. the JOINER gets in first: it runs the car and Jack; the host follows
-- =============================================================================================
do
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900 }, { num = 900 })
    step(host, join, 4)
    jrec.state = "PlayerGetInto"
    step(host, join, 1.5)
    local hg, jg = gc(host), gc(join)
    check(jg.claim and jg.claim.by == "me" and hg.claim and hg.claim.by == "peer", "(10.19) joiner-run: the joiner got in first: it runs the car, the host follows")
    check(hrec.get_in == 1, "(10.19) joiner-run: ...the host's own player is put in too")
    check(jg.jack_follow == false and hg.jack_follow == true, "(10.19) joiner-run: ...the host's Jack follows the joiner's Jack (the joiner runs him)")
    jrec.state = "WaitEnemyGetPlayerOut"
    step(host, join, 1.5)
    check(gc(host).puppet == true and hrec.paused == true and hrec.brain_on == false, "(10.19) joiner-run: the host's car is the puppet")
    -- the joiner's car and Jack move; the host's car and Jack follow
    local sx = jrec.x
    local jackp = jrec.jack.xf:call("get_Position")
    for i = 1, 40 do
        jrec.go.xf:call("set_Position", vec(sx + i * 0.2, 0, jrec.z))
        jrec.jack.xf:call("set_Position", vec(jackp.x + i * 0.2, 0, jackp.z))
        step(host, join, 0.05)
    end
    step(host, join, 0.6)
    local hp, jp = hrec.pos(), jrec.pos()
    check(math.abs(hp.x - jp.x) < 1.0, string.format("(10.19) joiner-run: the host's puppet car is where the joiner's is: %.1f / %.1f", hp.x, jp.x))
    local hjp = hrec.jack.xf:call("get_Position")
    local jjp = jrec.jack.xf:call("get_Position")
    check(math.abs(hjp.x - jjp.x) < 1.5, string.format("(10.19) joiner-run: the host's Jack is where the joiner's Jack is: %.1f / %.1f", hjp.x, jjp.x))
    local htext = host.files["re7mp_state_out.json"] and host.files["re7mp_state_out.json"].p or ""
    check(htext:find("Em3000,", 1, true) == nil, "(10.19) joiner-run: the host does not send its own Jack while the joiner runs him: " .. htext:sub(1, 60))
    do -- a stray snapshot of the host's Jack arrives at the joiner (as an older host would send it): the joiner's Jack is not dragged onto it
        for i = 1, 40 do
            join.files["re7mp_state_in.json"] = { seq = 90000 + i, n = 90000 + i, p = string.format("T%.3f;Em3000,100,0,100,0,0,0,1,600,1,0,0,0", join.clock) }
            run_frames(join, 0.05)
            bump_remote(join)
        end
        check(jrec.jack.xf:call("get_Position").x < 50, "(10.19) joiner-run: the host's snapshot of Jack is ignored while the joiner runs him: x = " .. tostring(jrec.jack.xf:call("get_Position").x))
    end
    local jtext = join.files["re7mp_state_out.json"] and join.files["re7mp_state_out.json"].p or ""
    check(jtext:match("^T[%d%.]+;#car,") ~= nil and jtext:find(";Em3000,", 1, true) ~= nil, "(10.19) joiner-run: the joiner's file carries the car line and Jack: " .. jtext:sub(1, 80))
    jrec.state = "AfterExplosion"
    step(host, join, 3)
    check(hrec.set_state_to == "AfterExplosion" and hrec.broke_all == true and hrec.get_out == 1, "(10.19) joiner-run: the end plays on the host's car")
    step(host, join, 4)
    check(gc(host).jack_follow == false, "(10.19) joiner-run: the host's Jack is its own again")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.19) joiner-run: no script error")
end

-- =============================================================================================
-- 5. both get in at the same moment: the host wins
-- =============================================================================================
do
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900 }, { num = 900 })
    step(host, join, 4)
    -- both cars change state in the same frame, before either claim can arrive
    hrec.state, jrec.state = "PlayerGetInto", "PlayerGetInto"
    run_frames(host, 0.6)
    run_frames(join, 0.6)
    bump_remote(host)
    bump_remote(join)
    step(host, join, 3)
    local hg, jg = gc(host), gc(join)
    check(hg.claim and hg.claim.by == "me", "(10.19) tie: the host keeps the car")
    check(jg.claim and jg.claim.by == "peer", "(10.19) tie: the joiner gives it up and follows: " .. tostring(jg.claim and jg.claim.by))
    check(hg.counts.ties_won >= 1 and jg.counts.ties_lost >= 1, "(10.19) tie: ...counted on both sides")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.19) tie: no script error")
end

-- =============================================================================================
-- 6. a player who cannot get in watches from outside; run-overs; the button; release
-- =============================================================================================
do
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900 }, { num = 900 })
    tick(join, BOX_RIDE, false)
    step(host, join, 3)
    hrec.state = "PlayerGetInto"
    step(host, join, 4)
    check(jrec.get_in == 0, "(10.19) bystander: with the ride box off the joiner's Interact_GetInto is never fired")
    step(host, join, 13)
    local jg = gc(join)
    check(jg.ride_phase == "bystander" and jg.puppet == true, "(10.19) bystander: after the wait the joiner watches from outside and its car follows: " .. tostring(jg.ride_phase))
    check(jg.counts.bystander == 1, "(10.19) bystander: ...counted")
    -- run-over: the host's car is driven by Jack (flag bit) and goes over the joiner's player
    local dc
    for _, c in ipairs(join.player.m.get_Components().get_elements()) do if c._type == "app.PlayerDamageController" then dc = c end end
    local hits = {}
    dc.m.newFakeDamageInfo = function(_, dmg) return Obj.new("app.DamageInfo", {}, { dmg = dmg }) end
    dc.m.addManualDamage = function(_, info) hits[#hits + 1] = info.f.dmg end
    check(#hits == 0, "(10.19) run-over: nothing yet")
    hrec.enemy_driving, hrec.speed = true, 6
    hrec.state = "WaitEnemyGetPlayerOut"
    local jx, jz = 3, 3
    for i = 1, 60 do -- the car drives from far away to the joiner's player
        hrec.x, hrec.z = 12 - i * 0.15, 3
        hrec.go.xf:call("set_Position", vec(hrec.x, 0, hrec.z))
        step(host, join, 0.05)
    end
    step(host, join, 1)
    check(#hits == 1, "(10.19) run-over: the runner's car drove over the bystander: one hit: " .. #hits)
    check(hits[1] and hits[1] <= 250 and hits[1] > 0, "(10.19) run-over: ...of the set amount: " .. tostring(hits[1]))
    check(gc(join).counts.runovers == 1, "(10.19) run-over: ...counted")
    step(host, join, 0.5)
    check(#hits == 1, "(10.19) run-over: standing inside the car's footprint does not hit again at once")
    tick(join, BOX_RUN, false)
    hrec.x = 20
    hrec.go.xf:call("set_Position", vec(20, 0, 3))
    step(host, join, 2)
    for i = 1, 60 do
        hrec.x = 20 - i * 0.3
        hrec.go.xf:call("set_Position", vec(hrec.x, 0, 3))
        step(host, join, 0.05)
    end
    check(#hits == 1, "(10.19) run-over: its box off: no second hit")
    -- the "let go" button: everything back as the game has it
    join.ui_press[BTN_LET] = true
    run_ui(join)
    jg = gc(join)
    check(jg.puppet == false and jg.claim == nil, "(10.19) release: the button lets go: the car is the game's again")
    check(jrec.paused == false and jrec.brain_on == true and jrec.kid_on.Interact_GetInto == true, "(10.19) release: ...brain, state machine and interacts back on")
    -- the 'get me out' button
    jrec.get_out = 0
    join.ui_press[BTN_OUT] = true
    run_ui(join)
    check(jrec.get_out == 1, "(10.19) button: 'Get me out of the car' fires Interact_GetOut")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.19) bystander: no script error")
end

-- =============================================================================================
-- 6b. other ways a fight ends: the story moves on; a game that ignores the state; a runner that goes quiet
-- =============================================================================================
do -- the story moves on (c03_1_Main passes step 1100) while the car is still in its fight state: no wreck is played, the rider gets out and everything is given back
    local hrec, jrec, hflow = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }, { num = 900 }
    local host, join = pair(hrec, jrec, hflow, { num = 900 })
    step(host, join, 4)
    hrec.state = "PlayerGetInto"
    step(host, join, 5)
    check(gc(join).puppet == true, "(10.19) left: (the joiner's car follows)")
    hflow.num = 1100
    step(host, join, 3)
    check(sent_has(host, "19:x|left"), "(10.19) left: the runner tells the other game the fight is over without a wreck: " .. table.concat(host.sent_log or {}, " ; "):sub(-60))
    check(jrec.set_state_to == nil and jrec.broke_all == false, "(10.19) left: ...no AfterExplosion and no breakAll on the rider's car")
    check(jrec.get_out == 1 and jrec.paused == false and jrec.brain_on == true and gc(join).claim == nil, "(10.19) left: ...the rider gets out and the car is the game's again")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.19) left: no script error")
end

do -- a game that takes setCurrentState and does nothing: the car stays in its fight state, and must not be claimed again (the cool-down)
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto", refuse_state = true }
    local host, join = pair(hrec, jrec, { num = 900 }, { num = 900 })
    step(host, join, 4)
    hrec.state = "PlayerGetInto"
    step(host, join, 5)
    hrec.state = "AfterExplosion"
    step(host, join, 4)
    check(jrec.state ~= "AfterExplosion" and jrec.broke_all == true and gc(join).claim == nil, "(10.19) cool-down: the game ignored the state (my car is still in " .. tostring(jrec.state) .. ") and the fight is over here")
    step(host, join, 12)
    check(sent_count(join, "19:c|") == 0 and gc(join).claim == nil and gc(host).claim == nil, "(10.19) cool-down: the car in its old state is NOT claimed again (the joiner sent " .. sent_count(join, "19:c|") .. " claims)")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.19) cool-down: no script error")
end

do -- the runner goes quiet (its car messages stop, its packets still come): after 12 s the rider lets go of the puppet
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900 }, { num = 900 })
    step(host, join, 4)
    hrec.state = "PlayerGetInto"
    step(host, join, 5)
    check(gc(join).puppet == true and jrec.paused == true, "(10.19) quiet: (the joiner's car follows)")
    for _ = 1, 280 do run_frames(join, 0.05) bump_remote(join) end -- 14 s with nothing from the host's car
    local jg = gc(join)
    check(jg.counts.released >= 1 and jrec.paused == false and jrec.brain_on == true, "(10.19) quiet: a claim that goes quiet for 12 s is let go: the car is the game's again (released " .. tostring(jg.counts.released) .. ")")
    check(not log_has(join, "script error"), "(10.19) quiet: no script error")
end

-- =============================================================================================
-- 7. the matching of story steps stops while the car fight runs
-- =============================================================================================
do
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900 }, { num = 800 }) -- (the joiner is a step behind: the matching has something to do)
    step(host, join, 3)
    hrec.state = "PlayerGetInto"
    step(host, join, 1.5)
    deliver(join, 18, "n|0|9fb77189|900|800") -- the host's number reaches the joiner
    tick(join, "EXPERIMENTAL: match them: a part of mine that is BEHIND the other player's is taken forward one step at a time, never back; only in a quiet moment. Not remembered##matchon", true)
    step(host, join, 3)
    local after = health(join).story_match
    check(tostring(after.waiting_because or ""):find("garage car fight is on", 1, true) ~= nil, "(10.19) matching: while the car fight runs the matching waits and says so: " .. tostring(after.waiting_because) .. " / " .. tostring(after.status))
    check(not log_has(join, "script error"), "(10.19) matching: no script error")
end

-- =============================================================================================
-- 8. a crash marker switches the car sync off at the next start; the actor probe
-- =============================================================================================
do
    local rec, flow = { state = "WaitPlayerGetInto" }, { num = 900 }
    local env = new_environment()
    build_world(env)
    both(flow_setup(flow), car_setup(rec))(env)
    -- a marker left by a session that ended inside a car call (the file name is the script's own "lastcall")
    local probe = world("host")
    local name
    for k, v in pairs(probe.files) do if type(v) == "table" and v.stage == "clean" then name = k end end
    check(name ~= nil, "(10.19) crash marker: the script writes its marker file (found: " .. tostring(name) .. ")")
    if name then
        env.files[name] = { stage = "car", call = "firing Interact_GetInto for my player", clock = 1, time = os.time(), session = 1 }
        load_script(env)
        host_role_files(env, "host", "tcp")
        for _ = 1, 30 do run_frames(env, 0.05) bump_remote(env) end
        env.combo_override["Enemy sync"] = 3
        run_ui(env)
        live(env, 4)
        local g = gc(env)
        check(g.crash_marker == true and tostring(g.status):find("off", 1, true) ~= nil and g.on == false, "(10.19) crash marker: a session that ended inside a car call switches the car sync off: " .. tostring(g.status))
        check(log_has(env, "garage car"), "(10.19) crash marker: ...and says what it found")
        tick(env, BOX_CAR, true)
        live(env, 3)
        check(gc(env).on == true and gc(env).crash_marker == nil, "(10.19) crash marker: ticking the box again tries again")
    end
end

do -- the actor probe: reads only, off at every start
    local rec = { state = "WaitPlayerGetInto" }
    local env = world("host", both(flow_setup({ num = 900 }), car_setup(rec)))
    local gos = {}
    local mc = Obj.new("app.MovementController", {})
    local actor = make_go("sm9104_EthanCar_Garage", vec(1, 0, 1), { mc, Obj.new("via.fsm.Fsm", { ["getCurrentState(System.UInt32)"] = function() return "Idle" end }) })
    local enemy_go = make_go("Em4100", vec(2, 0, 2), { Obj.new("app.MovementController", {}) })
    local orig = env.scene.m["findComponents(System.Type)"]
    local looks = 0
    env.scene.m["findComponents(System.Type)"] = function(self, t)
        if t == "app.MovementController" then
            looks = looks + 1
            mc.m.get_GameObject = function() return actor end
            local mc2 = Obj.new("app.MovementController", { get_GameObject = function() return enemy_go end })
            return { get_elements = function() return { mc, mc2 } end }
        end
        if t == "via.physics.CharacterController" then return { get_elements = function() return {} end } end
        return orig(self, t)
    end
    live(env, 12)
    check(looks == 0 and env.files["re7mp/actor_probe.json"] == nil, "(10.19) actor probe: off at every start: no scene look, no file")
    tick(env, BOX_ACTORS, true)
    live(env, 12)
    local f = env.files["re7mp/actor_probe.json"]
    check(f and f.actors and #f.actors == 1 and f.actors[1].name == "sm9104_EthanCar_Garage", "(10.19) actor probe: lists the scene actor and leaves the enemy out: " .. tostring(f and f.actors and #f.actors))
    check(f and f.actors[1] and f.actors[1].fsm_state == "Idle", "(10.19) actor probe: ...with its state machine's state")
    check(looks > 0 and rec.log and #rec.log == 0, "(10.19) actor probe: ...and it changed nothing in the game")
    tick(env, BOX_ACTORS, false)
    local n = looks
    live(env, 12)
    check(looks == n, "(10.19) actor probe: its box turns it off")
    check(not log_has(env, "script error"), "(10.19) actor probe: no script error")
end

-- =============================================================================================
-- 9. defaults and the build label
-- =============================================================================================
do
    local env = world("host")
    local h = health(env)
    check(tostring(env.files["re7mp/debug.json"].build) == "10.27", "(10.20) the build label is now 10.27: " .. tostring(env.files["re7mp/debug.json"].build))
    check(h.garage_car and h.garage_car.on == true and h.actor_probe and h.actor_probe.on == false, "(10.19) the car sync is on by default and the actor probe is off")
    run_ui(env)
    check(ui_has(env, "my car:") and ui_has(env, "waiting"), "(10.19) the panel shows the car sync status line")
end

-- =============================================================================================
-- 10. (10.27) what the first real file showed
-- =============================================================================================
do -- 10a. the story number through the real number holder, and the state through the route that works
    local hrec, jrec = { state = "WaitPlayerGetInto", dud_field_fsm = true, action_method = "processPlayerWaitInCar" }, { state = "WaitPlayerGetInto" }
    local hflow, jflow = { num = 900, var_kind = "cast" }, { num = 900, var_kind = "s32" }
    local host, join = pair(hrec, jrec, hflow, jflow)
    step(host, join, 5)
    local sf = health(host).story_flow
    check(sf and sf.number_read_by == "get_CastS32" and sf.flows[1] and sf.flows[1].mine == 900, "(10.27) story number: read through get_CastS32 (the holder has no get_Value): " .. tostring(sf and sf.number_read_by) .. " / " .. tostring(sf and sf.flows[1] and sf.flows[1].mine))
    local sj = health(join).story_flow
    check(sj and sj.number_read_by == "get_S32" and sj.flows[1] and sj.flows[1].mine == 900, "(10.27) story number: ...and through get_S32 when that is all there is: " .. tostring(sj and sj.number_read_by))
    local g = gc(host)
    check(g.story_number == 900, "(10.27) story number: ...and the car module has it now (it printed 'story nil' in the 10.26 file): " .. tostring(g.story_number))
    check(g.car_found == true and g.my_state == "WaitPlayerGetInto", "(10.27) car state: the Fsm field answers an empty text, the other route answers: the state is read: '" .. tostring(g.my_state) .. "'")
    check(g.fsm and g.fsm.via == "component" and tostring(g.fsm.field_answer):find("no name", 1, true) ~= nil and g.fsm.empty_reads == 0,
        "(10.27) car state: ...and the file says which route worked and what the other one said: " .. tostring(g.fsm and g.fsm.via) .. " / " .. tostring(g.fsm and g.fsm.field_answer))
    check(g.counts.state_via_component > 0 and g.counts.state_via_field == 0, "(10.27) car state: ...counted by route")
    check(g.my_action == "processPlayerWaitInCar", "(10.27) car action: the action delegate says which method it holds: " .. tostring(g.my_action))
    hrec.state = "PlayerGetInto"
    step(host, join, 1.5)
    g = gc(host)
    check(g.claim and g.claim.by == "me", "(10.27) car state: ...so the claim happens when the player gets in (it never did in the 10.26 file)")
    local last = g.transitions[#g.transitions]
    check(last and last.to == "PlayerGetInto" and last.from == "WaitPlayerGetInto" and last.action == "processPlayerWaitInCar" and last.story == 900,
        "(10.27) car journal: the transition carries the action and the story number: " .. tostring(last and last.to) .. " / " .. tostring(last and last.action) .. " / " .. tostring(last and last.story))
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.27) car state: no script error")
end

do -- 10b. a number that is not a step number is not taken; a state that cannot be read on either route
    local hrec, hflow = { state = "" }, { num = 900, var_kind = "bad" }
    local host, join = pair(hrec, { state = "WaitPlayerGetInto" }, hflow, { num = 900 })
    step(host, join, 4)
    local sf = health(host).story_flow
    check(sf and sf.flows[1] and sf.flows[1].mine == nil and sf.number_read_by == nil, "(10.27) story number: -1, NaN and 1e12 are not step numbers: nothing is read: " .. tostring(sf and sf.flows[1] and sf.flows[1].mine))
    local g = gc(host)
    check(g.car_found == true and g.my_state == "" and g.fsm.via == nil and g.fsm.empty_reads > 0, "(10.27) car state: a state that comes back empty on both routes is '' and counted: " .. tostring(g.fsm and g.fsm.empty_reads))
    check(tostring(g.fsm.field_answer):find("no name", 1, true) ~= nil and tostring(g.fsm.component_answer):find("no name", 1, true) ~= nil, "(10.27) car state: ...with the reason of each route")
    check(g.claim == nil and not log_has(host, "script error"), "(10.27) car state: ...and nothing is claimed from it")
end

do -- 10c. the windows asked one by one when the car has no flag field
    local hrec, jrec = { state = "WaitPlayerGetInto", no_win_field = true, win_bits = {} }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900, var_kind = "cast" }, { num = 900 })
    step(host, join, 3)
    hrec.state = "PlayerGetInto"
    step(host, join, 1.5)
    hrec.state = "WaitEnemyGetPlayerOut"
    step(host, join, 1.5)
    check(gc(join).puppet == true, "(10.27) windows: (the joiner's car is a puppet)")
    hrec.win_bits = { [2] = true, [5] = true }
    step(host, join, 3)
    check((hrec.win_calls or 0) >= 6 and gc(host).counts.window_calls >= 6, "(10.27) windows: isWindowBroken is asked for the six windows: " .. tostring(hrec.win_calls))
    check(gc(join).runner and gc(join).runner.windows == ((1 << 2) | (1 << 5)), "(10.27) windows: ...and the other game gets the mask: " .. tostring(gc(join).runner and gc(join).runner.windows))
    local w = table.concat(jrec.windows_broken, ",")
    check(#jrec.windows_broken == 2 and w:find("2", 1, true) and w:find("5", 1, true), "(10.27) windows: ...and breaks windows 2 and 5 on its car, once each: " .. w)
end

do -- 10d. a state nobody listed: it does not start a fight, and it does not end one
    local hrec, jrec = { state = "WaitPlayerGetInto" }, { state = "WaitPlayerGetInto" }
    local host, join = pair(hrec, jrec, { num = 900, var_kind = "cast" }, { num = 900 })
    step(host, join, 4)
    hrec.state = "SomethingNew"
    step(host, join, 4)
    check(gc(host).claim == nil and #messages_of_kind(host, 19) == 0, "(10.27) unknown state: it starts nothing (an odd state at the start of the chapter must not pull the other player in)")
    hrec.state = "HitWall"
    step(host, join, 1.5)
    check(gc(host).claim and gc(host).claim.by == "me", "(10.27) unknown state: HitWall (seen in the real game) is a fight state: it claims")
    hrec.state = "SomethingNew"
    step(host, join, 14)
    check(gc(host).claim and gc(host).claim.by == "me" and gc(host).claim.ended == nil, "(10.27) unknown state: ...and a state nobody listed for 14 s does not end the fight (the 10.19 rule ended it after 10 s)")
    hrec.state = "WaitPlayerGetInto"
    step(host, join, 15)
    check(gc(host).claim == nil, "(10.27) unknown state: ...the car back at rest for 10 s does end it")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.27) unknown state: no script error")
end

do -- 10e. the car probe: a cap that lets the whole list through, the delegates described, the state read both ways, the two controllers
    local rec = { state = "WaitPlayerGetInto", dud_field_fsm = true, action_method = "processPlayerDrive" }
    local env = world("host", both(flow_setup({ num = 900, var_kind = "cast" }), car_setup(rec)))
    local big = {}
    for i = 1, 530 do big[i] = { "Field" .. i, "System.Single" } end
    for _, t in ipairs(TYRES) do big[#big + 1] = { "Is" .. t .. "BlownOut", "System.Boolean" } end
    make_td("app.CarInGarage", { fields = big, methods = { processPlayerDrive = { params = {}, ret = "System.Void" } } })
    make_td("app.CarDamageControllerInGarage", { fields = { { "Hp", "System.Int32" }, { "Armor", "System.Single" } } })
    make_td("app.CarInGarage.Action", { methods = { Invoke = { params = {}, ret = "System.Void" } } })
    local damage = Obj.new("app.CarDamageControllerInGarage", {}, { Hp = 77, Armor = 1.5 })
    local orig = rec.go.m["getComponent(System.Type)"]
    rec.go.m["getComponent(System.Type)"] = function(self, t)
        if t == "app.CarDamageControllerInGarage" then return damage end
        return orig(self, t)
    end
    tick(env, "Garage car probe (reads only): writes the type app.CarInGarage and, once the garage's car exists, 3 readings of it to re7mp/car_probe.json (not remembered)##carprobe", true)
    live(env, 20)
    local f = env.files["re7mp/car_probe.json"]
    check(f and f.types and #f.types == 4, "(10.27) car probe: four types are dumped (the car, its two controllers, the action delegate): " .. tostring(f and f.types and #f.types))
    local t1 = f and f.types and f.types[1]
    check(t1 and t1.fields_total == 520 and t1.cut == true, "(10.27) car probe: the car's list goes to 520 fields (it stopped at 220) and says when it was cut: " .. tostring(t1 and t1.fields_total) .. " " .. tostring(t1 and t1.cut))
    check(f and f.types[2] and f.types[2].found == true and f.types[2].fields_total == 2 and f.types[3] and f.types[3].found == false and f.types[4] and f.types[4].found == true and f.types[4].methods_total == 1,
        "(10.27) car probe: ...the damage controller's type is dumped, a type the game does not have (the strike controller here) is said so, and the delegate's type is listed")
    local r1 = f and f.readings and f.readings[1] and f.readings[1].instances and f.readings[1].instances[1]
    check(r1 and r1.current_action and r1.current_action.set == true, "(10.27) car probe: CurrentAction is described: " .. tostring(r1 and r1.current_action and r1.current_action.method))
    check(r1 and r1.current_action and r1.current_action.method == "processPlayerDrive" and r1.next_action and r1.next_action.set == false, "(10.27) car probe: ...with the method it holds, and NextAction (not there) as unset")
    check(r1 and r1.state and r1.state.field and r1.state.field.state == "" and r1.state.component and r1.state.component.state == "WaitPlayerGetInto" and r1.state.same_object == false,
        "(10.27) car probe: the state is read both ways and the two are told apart: field '" .. tostring(r1 and r1.state and r1.state.field and r1.state.field.state) .. "', component '" .. tostring(r1 and r1.state and r1.state.component and r1.state.component.state) .. "'")
    local c1 = r1 and r1.controllers and r1.controllers[1]
    local hp
    for _, fl in ipairs(c1 and c1.fields or {}) do if fl.name == "Hp" then hp = fl.value end end
    check(c1 and c1.type == "app.CarDamageControllerInGarage" and hp == 77 and r1.controllers[2] and r1.controllers[2].found == false, "(10.27) car probe: the damage controller's fields are read (Hp " .. tostring(hp) .. "), the strike controller (not on this car) is said missing")
    check(not log_has(env, "script error"), "(10.27) car probe: no script error")
end

do -- 10f. the actor probe: more than three objects of a type, and the order of a state machine's states
    local rec = { state = "WaitPlayerGetInto" }
    local env = world("host", both(flow_setup({ num = 900, var_kind = "cast" }), car_setup(rec)))
    local cur = { state = "WaitPlayerGetInto" }
    local actor = make_go("sm9104_EthanCar_Garage", vec(1, 0, 1), { Obj.new("app.MovementController", {}), Obj.new("via.fsm.Fsm", { ["getCurrentState(System.UInt32)"] = function() return cur.state end }) })
    local mcs = {}
    for i = 1, 6 do -- six enemies ahead of the car in the scene's list: the old limit of 3 never reached it
        local go = make_go("Em4" .. i .. "00", vec(i, 0, i), {})
        mcs[#mcs + 1] = Obj.new("app.MovementController", { get_GameObject = function() return go end })
    end
    mcs[#mcs + 1] = Obj.new("app.MovementController", { get_GameObject = function() return actor end })
    local orig = env.scene.m["findComponents(System.Type)"]
    env.scene.m["findComponents(System.Type)"] = function(self, t)
        if t == "app.MovementController" then return { get_elements = function() return mcs end } end
        if t == "via.physics.CharacterController" then return { get_elements = function() return {} end } end
        return orig(self, t)
    end
    tick(env, BOX_ACTORS, true)
    live(env, 6)
    cur.state = "PlayerGetInto"
    live(env, 6)
    cur.state = "HitWall"
    live(env, 12)
    local f = env.files["re7mp/actor_probe.json"]
    local a = f and f.actors and f.actors[1]
    check(a and a.name == "sm9104_EthanCar_Garage", "(10.27) actor probe: the car is found behind six enemies (the old limit was three objects of a type): " .. tostring(a and a.name))
    local order = {}
    for _, e in ipairs(a and a.fsm_trail or {}) do order[#order + 1] = e.state end
    check(table.concat(order, ",") == "WaitPlayerGetInto,PlayerGetInto,HitWall" and a.fsm_changes == 3 and a.fsm_state == "HitWall", "(10.27) actor probe: the states are kept in the order they came: " .. table.concat(order, ","))
    check(a and a.fsm_trail[1].at_s and a.fsm_trail[3].at_s >= a.fsm_trail[2].at_s and a.fsm_trail[2].at_s >= a.fsm_trail[1].at_s and a.fsm_trail[1].story == 900, "(10.27) actor probe: ...each with its second and the story number")
    check(not log_has(env, "script error"), "(10.27) actor probe: no script error")
end
