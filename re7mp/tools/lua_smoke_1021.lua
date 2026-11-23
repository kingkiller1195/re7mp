-- Checks of build 10.21 for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1021_file) with that file's helpers in one table.
--   RE7MP_ONLY_1021=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What it covers (all of it is the game's behaviour AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   K. kills both ways (message kind 21): the joiner's copy of an enemy dying first asks the host to kill its own; the host's answers, refusals and guards
--   L. Molded limb and head removal (message kind 22): the lost parts of a Molded read on one side and applied on the other, and the probe of the game's own lost-parts types
-- (The stand-in removal and the per-gun damage are checked in tools/lua_smoke.lua, next to the 9.31 tests they change.)
-- The helpers below are copied from lua_smoke_1015.lua (the fake Molded world, the fake driven enemy, the cutscene switch).

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

local BOX_KILL = "Share kills: when my copy of the host's enemy dies here first, the host's dies too (the host applies it). The host's own deaths already kill mine. Never a boss, never during a cutscene (remembered)##killsync"
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
local function game_state(env)
    local st = { n = 0, playing = true }
    local gm = Obj.new("app.GameManager", {}, { _CurrentChapter = 4, ["<IsSceneLoading>k__BackingField"] = false, RequestChapterJump = false, RequestPlayerChange = false,
        _GameEventMan = Obj.new("app.GameEventManager", {}, { RunningEventControllers = Obj.new("System.Collections.Generic.List`1<app.GameEventController>", { get_Count = function() return st.n end }) }) })
    env.singletons["app.GameManager"] = gm
    env.singletons["app.MenuManager"] = Obj.new("app.MenuManager", { isPlayingEvent = function() return st.playing end })
    st.gm = gm
    return st
end

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
    -- (10.21) the lost-parts controller of a Molded: what the game offers is NOT known, so the fake offers several shapes (opts.limb_shape): "full" = a yes/no method per part
    -- (isLostParts) and two ways to make one (requestLostParts, then lostParts), plus decoys the script must not touch; "no_read" = no yes/no method; "no_apply" = no way to make one;
    -- "work" = no yes/no method, but a list of LostPartsWork objects, each with its part and an IsLost flag
    local LT = "app.MoldedActionController.LostPartsUnit.Type"
    do
        local shape = opts.limb_shape
        if shape then
            local ms = {
                getLostPartsCount = { params = {}, ret = "System.Int32" },
                setLostPartsEnable = { params = { "System.Boolean" }, ret = "System.Void" },
                isLostAll = { params = {}, ret = "System.Boolean" },
                getLostPartsName = { params = { LT }, ret = "System.String" },
            }
            if shape == "full" or shape == "no_apply" then ms.isLostParts = { params = { LT }, ret = "System.Boolean" } end
            if shape ~= "no_apply" then
                ms.requestLostParts = { params = { LT }, ret = "System.Void" }
                if shape == "full" or shape == "no_read" then ms.lostParts = { params = { LT }, ret = "System.Void" } end
            end
            local def = { methods = ms }
            if shape == "work" then def.fields = { { "LostWork", "System.Collections.Generic.List`1<app.MoldedActionController.LostPartsWork>" }, { "Speed", "System.Single" } } end
            make_td("app.Em4000ActionController", def)
            make_td("app.MoldedActionController.LostPartsWork", { fields = { { "_Type", LT }, { "_IsLost", "System.Boolean" } } })
        end
    end
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
        if opts.limb_shape and spec.limbs ~= false then
            local lim = spec.limbs or {}
            B.lost, B.lost_at, B.requests, B.shape = {}, {}, {}, opts.limb_shape
            local function is_lost(part) return B.lost[part] == true or (B.lost_at[part] ~= nil and env.clock >= B.lost_at[part]) end
            local m, f = {}, {}
            if B.shape == "work" then
                B.work = {}
                for part = 0, 6 do B.work[part + 1] = Obj.new("app.MoldedActionController.LostPartsWork", {}, { _Type = part, _IsLost = false }) end
                f.LostWork = Obj.new("System.Collections.Generic.List`1", { get_Count = function() return 7 end, get_Item = function(_, i) return B.work[7 - i] end }) -- (reversed: the part comes from the object's own type field, not from its place in the list)
                f.Speed = 1.0
            end
            function B.lose(part) B.lost[part] = true if B.work then B.work[part + 1].f._IsLost = true end end
            m.getLostPartsCount = function() W.limb_decoy = (W.limb_decoy or 0) + 1 return 0 end
            m.setLostPartsEnable = function() W.limb_decoy = (W.limb_decoy or 0) + 1 end
            m.isLostAll = function() W.limb_decoy = (W.limb_decoy or 0) + 1 return false end
            m.getLostPartsName = function() W.limb_decoy = (W.limb_decoy or 0) + 1 return "x" end
            m.isLostParts = function(_, part) W.limb_reads = (W.limb_reads or 0) + 1 if lim.read_error then error("fake: isLostParts refused") end return is_lost(part) end
            m.requestLostParts = function(_, part)
                B.requests[#B.requests + 1] = "requestLostParts:" .. part
                if lim.never or lim.first_dead then return end
                B.lost_at[part] = env.clock + (lim.delay or 0)
                if B.work then B.work[part + 1].f._IsLost = true end
            end
            m.lostParts = function(_, part)
                B.requests[#B.requests + 1] = "lostParts:" .. part
                if lim.never then return end
                B.lost_at[part] = env.clock + (lim.delay or 0)
            end
            comps[#comps + 1] = Obj.new("app.Em4000ActionController", m, f)
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

-- =============================================================================================
-- K. kills both ways (message kind 21)
-- =============================================================================================
local function asks(env) local out = {} for _, m in ipairs(messages_of_kind(env, 21)) do if m:sub(1, 2) == "k|" then out[#out + 1] = m end end return out end
local function answers(env) local out = {} for _, m in ipairs(messages_of_kind(env, 21)) do if m:sub(1, 2) == "a|" then out[#out + 1] = m end end return out end
local function ks(env) return health(env).kill_sync end
local function say_a(env, text) push_msgs(env, { { 21, text } }) end

do -- a Molded copy dies here (my own shot) while the host's is alive: the host is asked, after a short wait, again and again until answered, four times at most
    local env, W = molded_world("join", specs3(), {})
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 3)
    check(copy_names(molded_report(env)) == NAME_A, "(10.21) kill: the Molded copy is up: " .. copy_names(molded_report(env)))
    check(#asks(env) == 0, "(10.21) kill: a copy that is alive asks nothing")
    local warps0 = #W.warps
    W.bodies[1].dead = true -- the game says my copy is dead
    mlive(env, 0.5)
    check(#asks(env) == 0, "(10.21) kill: not at once (the host's own death may be one snapshot away): " .. #asks(env))
    mlive(env, 1.0)
    local a = asks(env)
    check(#a == 1 and a[1] == "k|" .. NAME_A .. "|10.0|10.0", "(10.21) kill: after 0.7 s dead it asks the host once, with the host's own place: " .. tostring(a[1]))
    local w1 = #W.warps
    mlive(env, 1.0)
    check(#W.warps == w1, "(10.21) kill: a body that died here is no longer moved onto the host's (" .. (#W.warps - w1) .. " moves in a second)")
    mlive(env, 1.7) -- (4.2 s after the body died: the first ask went out at about 1.0 s, so the second, 2.5 s later, is out and the third is not)
    check(#asks(env) == 2, "(10.21) kill: no answer: asked again after 2.5 s (" .. #asks(env) .. ")")
    mlive(env, 12)
    check(#asks(env) == 4, "(10.21) kill: ...four times in all, then it stops (" .. #asks(env) .. ")")
    check(copy_names(molded_report(env)) == NAME_A, "(10.21) kill: ...and the body stays the copy of it (no other body is taken for the same Molded)")
    local k = ks(env)
    check(k.counts.asked == 1 and k.counts.resent == 3 and k.counts.gave_up == 1, "(10.21) kill: the debug file counts it: asked " .. tostring(k.counts.asked) .. ", again " .. tostring(k.counts.resent) .. ", gave up " .. tostring(k.counts.gave_up))
    check(k.copies_watched[1] and k.copies_watched[1].copy == NAME_A and k.copies_watched[1].seen_alive == true and k.copies_watched[1].final ~= nil, "(10.21) kill: ...and lists the copy with why it stopped: " .. tostring(k.copies_watched[1] and k.copies_watched[1].final))
    check(log_has(env, "kill sync: " .. NAME_A .. " died here while the host's is alive"), "(10.21) kill: the journal says what was asked")
end

do -- the host answers ok: no more asking
    local env, W = molded_world("join", specs3(), {})
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 3)
    W.bodies[1].dead = true
    mlive(env, 1.6)
    check(#asks(env) == 1, "(10.21) kill/answer: asked once")
    say_a(env, "a|" .. NAME_A .. "|ok|addManualDamage")
    mlive(env, 8)
    check(#asks(env) == 1, "(10.21) kill/answer: 'ok' from the host ends the asking (" .. #asks(env) .. ")")
    check(ks(env).counts.ok == 1, "(10.21) kill/answer: ...and is counted")
    -- the host's snapshot then says dead: the copy is finished as always (it is dead already: done at once)
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 0, flags = 0 }) })
    mlive(env, 3)
    check(copy_names(molded_report(env)) == "", "(10.21) kill/answer: ...and when the host's snapshot says dead the copy is let go of the list: " .. copy_names(molded_report(env)))
end

do -- the host refuses: "not now" is asked again, a plain refusal is final
    local env, W = molded_world("join", specs3(), {})
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 3)
    W.bodies[1].dead = true
    mlive(env, 1.6)
    say_a(env, "a|" .. NAME_A .. "|no|not now: a cutscene is playing")
    mlive(env, 3.2)
    check(#asks(env) == 2, "(10.21) kill/refusal: 'not now' (a cutscene on the host) is asked again after 2.5 s (" .. #asks(env) .. ")")
    say_a(env, "a|" .. NAME_A .. "|no|a boss: the game's script decides")
    mlive(env, 8)
    check(#asks(env) == 2, "(10.21) kill/refusal: any other refusal is final (" .. #asks(env) .. ")")
    check(ks(env).counts.refused == 2, "(10.21) kill/refusal: ...both counted")
end

do -- the host's own death comes first (or at the same time): nothing is asked
    local env, W = molded_world("join", specs3(), {})
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 3)
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 0, flags = 0 }) })
    W.bodies[1].dead = true
    mlive(env, 4)
    check(#asks(env) == 0, "(10.21) kill/host first: the host's enemy is already dead: nothing is asked (" .. #asks(env) .. ")")
end

do -- a body that is DEAD AT FIRST SIGHT (an older save, another body) is not a kill of mine
    local sp = specs3()
    sp[1].dead = true
    local env, W = molded_world("join", sp, {})
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 5)
    check(#asks(env) == 0, "(10.21) kill/born dead: a copy that was dead when first looked at asks nothing (" .. #asks(env) .. ")")
    check(ks(env).counts.born_dead == 1, "(10.21) kill/born dead: ...and the debug file counts it")
end

do -- the quiet check: nothing is asked while a cutscene plays, it is asked once the cutscene is over (and a few seconds more)
    local env, W = molded_world("join", specs3(), {})
    local gs = game_state(env)
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 3)
    gs.n = 1
    W.bodies[1].dead = true
    mlive(env, 4)
    check(#asks(env) == 0, "(10.21) kill/quiet: during a cutscene nothing is asked (" .. #asks(env) .. ")")
    check(ks(env).counts.not_quiet >= 1, "(10.21) kill/quiet: ...and the debug file counts the held asks")
    gs.n = 0
    mlive(env, 7)
    check(#asks(env) >= 1, "(10.21) kill/quiet: after the cutscene (and its few quiet seconds) it is asked (" .. #asks(env) .. ")")
end

do -- the box off (remembered), and a session that ended inside a kill
    local env, W = molded_world("join", specs3(), { settings = { kill_sync = false } })
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 3)
    W.bodies[1].dead = true
    mlive(env, 5)
    check(#asks(env) == 0 and ks(env).on == false, "(10.21) kill/box: with kill_sync false in the settings nothing is asked")
    local env2, W2 = molded_world("join", specs3(), { before_load = function(e) e.files["re7mp/lastcall.json"] = { stage = "kill", call = "killing Em4000_x for the joiner", time = 1700000000, session = 1, clock = 1 } end })
    mfeed(env2, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env2, 3)
    W2.bodies[1].dead = true
    mlive(env2, 5)
    check(log_has(env2, "previous session: The last session ended while the script was killing an enemy"), "(10.21) kill/crash: a marker from a session that ended inside a kill is reported at the start")
    check(#asks(env2) == 0 and ks(env2).crash_marker ~= nil, "(10.21) kill/crash: ...and kill sharing is off this time (nothing asked)")
    env2.check_override[BOX_KILL] = true
    run_ui(env2)
    W2.bodies[1].dead = false -- (a body that dies while the feature is off is dead at first sight when it is back on: asks nothing; so the body lives again, is seen alive, and dies once more)
    mlive(env2, 2)
    W2.bodies[1].dead = true
    mlive(env2, 3.5)
    check(#asks(env2) >= 1 and ks(env2).crash_marker == nil, "(10.21) kill/crash: ticking the box again clears the marker and asks (" .. #asks(env2) .. ")")
    env2.check_override[BOX_KILL] = false
    run_ui(env2)
    mlive(env2, 3)
    check(env2.files["re7mp/settings.json"] and env2.files["re7mp/settings.json"].kill_sync == false, "(10.21) kill/box: unticking is remembered as kill_sync = false")
end

do -- an ordinary enemy mode 3 moved (not a Molded): the same, with a boss left alone
    local rec = { name = "Em4100" }
    local env = joiner(rec)
    host_says(env, 500, 1000)
    live(env, 2)
    check(#asks(env) == 0, "(10.21) kill/ordinary: alive: nothing asked")
    rec.dead = true
    for _ = 1, 3 do host_says(env, 500, 1000) live(env, 1) end
    local a = asks(env)
    check(#a >= 1 and a[1] == "k|Em4100|5.0|6.0", "(10.21) kill/ordinary: my Em4100 died, the host's lives: asked with the host's place: " .. tostring(a[1]))
    local envb = joiner({})
    host_says(envb, 500, 1000)
    live(envb, 2)
    envb.pool_rec.dead = true
    for _ = 1, 4 do host_says(envb, 500, 1000) live(envb, 1) end
    check(#asks(envb) == 0, "(10.21) kill/boss: Mia (Em2000) died here: NOTHING is asked of the host (" .. #asks(envb) .. ")")
    check(ks(envb).counts.bosses_skipped == 1 and log_has(envb, "it is a boss: nothing is asked of the host"), "(10.21) kill/boss: ...counted, and the journal says why")
end

-- HOST side: "k|name|x|z" from the joiner
local function host_ask(rec, settings, preset)
    local env = world("host", pool_setup(rec), settings)
    if preset then preset(env) end
    live(env, 1)
    return env
end

do -- the host kills its own: one finishing blow, answered ok
    local rec = { name = "Em4100", dies_on = 1 }
    local env = host_ask(rec)
    check(rec.dead == false and #rec.hits == 0, "(10.21) kill/host: alive and unhurt to begin with")
    say_a(env, "k|Em4100|5.00|6.00")
    live(env, 0.6)
    check(#rec.hits == 1 and rec.hits[1] == 4280 and rec.dead == true, "(10.21) kill/host: one hit far above its health (820 x 4 + 1000 = 4280) and it is dead: " .. tostring(rec.hits[1]))
    local an = answers(env)
    check(#an == 1 and an[1] == "a|Em4100|ok|addManualDamage", "(10.21) kill/host: answered ok, naming how: " .. tostring(an[1]))
    check(crumbed(env, "killing Em4100 for the joiner"), "(10.21) kill/host: the crash crumb was written first")
    check(ks(env).counts.host_killed == 1, "(10.21) kill/host: counted")
end

do -- it will not die: three hits, answered no
    local rec = { name = "Em4100", dies_on = 99 }
    local env = host_ask(rec)
    say_a(env, "k|Em4100|5.00|6.00")
    live(env, 0.6)
    local an = answers(env)
    check(#rec.hits == 3 and #an == 1 and an[1]:find("^a|Em4100|no|would not die after 3 hits"), "(10.21) kill/host: it would not die: three hits, then 'no': " .. #rec.hits .. " / " .. tostring(an[1]))
    check(ks(env).counts.host_failed == 1, "(10.21) kill/host: ...counted as failed")
end

do -- a boss is never killed for the joiner
    local rec = { dies_on = 1 }
    local env = host_ask(rec)
    say_a(env, "k|Em2000|5.00|6.00")
    live(env, 0.6)
    local an = answers(env)
    check(#rec.hits == 0 and #an == 1 and an[1]:find("^a|Em2000|no|a boss"), "(10.21) kill/host: Mia (Em2000) is a boss: no hit, answered no: " .. #rec.hits .. " / " .. tostring(an[1]))
end

do -- an enemy that is dead here already: answered ok, nothing hit
    local rec = { name = "Em4100", dies_on = 1 }
    local env = host_ask(rec)
    rec.dead = true
    say_a(env, "k|Em4100|5.00|6.00")
    live(env, 0.6)
    local an = answers(env)
    check(#rec.hits == 0 and #an == 1 and an[1] == "a|Em4100|ok|already dead", "(10.21) kill/host: already dead here: 'ok, already dead', nothing hit: " .. tostring(an[1]))
end

do -- a cutscene on the host: refused with 'not now', killed once it is over
    local rec = { name = "Em4100", dies_on = 1 }
    local gs
    local env = host_ask(rec, nil, function(e) gs = game_state(e) end)
    gs.n = 1
    live(env, 0.5)
    say_a(env, "k|Em4100|5.00|6.00")
    live(env, 0.6)
    local an = answers(env)
    check(#rec.hits == 0 and an[1] and an[1]:find("^a|Em4100|no|not now: a cutscene is playing"), "(10.21) kill/host: a cutscene plays here: refused 'not now', no hit: " .. tostring(an[1]))
    gs.n = 0
    live(env, 5)
    say_a(env, "k|Em4100|5.00|6.00")
    live(env, 0.6)
    check(#rec.hits == 1 and rec.dead == true, "(10.21) kill/host: ...and after the cutscene it is killed (" .. #rec.hits .. " hits)")
end

do -- "hits from the other player" off on the host: nothing is killed for the joiner either
    local rec = { name = "Em4100", dies_on = 1 }
    local env = host_ask(rec, { hit_accept = false })
    say_a(env, "k|Em4100|5.00|6.00")
    live(env, 0.6)
    check(#rec.hits == 0 and answers(env)[1] and answers(env)[1]:find("hits from the other player are switched off", 1, true), "(10.21) kill/host: hits from the other player off here: refused, no hit: " .. tostring(answers(env)[1]))
end

do -- the host's last session ended inside a kill: no kill this time
    local rec = { name = "Em4100", dies_on = 1 }
    local env = world("host", function(e)
        pool_setup(rec)(e)
        e.files["re7mp/lastcall.json"] = { stage = "kill", call = "killing Em4100 for the joiner", time = 1700000000, session = 1, clock = 1 }
    end)
    live(env, 1)
    say_a(env, "k|Em4100|5.00|6.00")
    live(env, 0.6)
    check(#rec.hits == 0 and answers(env)[1] and answers(env)[1]:find("the last session ended inside a kill", 1, true), "(10.21) kill/host: a crash marker from a kill: refused, no hit: " .. tostring(answers(env)[1]))
end

do -- the host's enemy is dead at the same moment as my copy (the pool finished my copy): nothing is asked
    local rec = { name = "Em4100", dies_on = 1 }
    local env = joiner(rec)
    host_says(env, 500, 1000)
    live(env, 2)
    for _ = 1, 3 do host_says(env, 0, 1000, 0) live(env, 1) end -- (flags 0: the host's enemy is dead)
    check(rec.dead == true and #asks(env) == 0, "(10.21) kill/host dead: the host's enemy is dead and my copy was finished by the pool: nothing is asked (" .. #asks(env) .. " asks, copy dead: " .. tostring(rec.dead) .. ")")
end

do -- no such enemy, a malformed message, more than six a second, the box off here, a joiner receiving it
    local rec = { name = "Em4100", dies_on = 1 }
    local env = host_ask(rec)
    say_a(env, "k|Em4300|5.00|6.00")
    live(env, 0.4)
    check(answers(env)[1] and answers(env)[1]:find("^a|Em4300|no|no enemy called Em4300 here"), "(10.21) kill/host: no such enemy: " .. tostring(answers(env)[1]))
    say_a(env, "k|Em4100|oops")
    live(env, 0.4)
    check(#answers(env) == 1 and #rec.hits == 0, "(10.21) kill/host: a malformed ask is ignored, no answer, no hit")
    local rec4 = { name = "Em4100", dies_on = 1 }
    local env4 = host_ask(rec4)
    local msgs = {}
    for i = 1, 8 do msgs[i] = { 21, "k|Em4100|5.00|6.00" } end
    push_msgs(env4, msgs)
    live(env4, 0.6)
    local refused_rate = 0
    for _, m in ipairs(answers(env4)) do if m:find("more than 6 a second", 1, true) then refused_rate = refused_rate + 1 end end
    check(refused_rate == 2 and #answers(env4) == 8, "(10.21) kill/host: eight asks in a moment: six are handled, two refused for the rate (" .. refused_rate .. " of " .. #answers(env4) .. " answers)")
    local rec2 = { name = "Em4100", dies_on = 1 }
    local env2 = host_ask(rec2, { kill_sync = false })
    say_a(env2, "k|Em4100|5.00|6.00")
    live(env2, 0.6)
    check(#rec2.hits == 0 and answers(env2)[1] and answers(env2)[1]:find("kill sharing is off here", 1, true), "(10.21) kill/host: with the box off here nothing is killed: " .. tostring(answers(env2)[1]))
    local rec3 = { name = "Em4100", dies_on = 1 }
    local env3 = joiner(rec3)
    say_a(env3, "k|Em4100|5.00|6.00")
    live(env3, 0.6)
    check(#rec3.hits == 0 and answers(env3)[1] and answers(env3)[1]:find("I am not the host", 1, true), "(10.21) kill/host: a joiner that is asked answers 'I am not the host' and hits nothing: " .. tostring(answers(env3)[1]))
end

-- =============================================================================================
-- L. Molded limbs and heads both ways (message kind 22)
-- =============================================================================================
local function limb_msgs(env) local out = {} for _, m in ipairs(messages_of_kind(env, 22)) do if m:sub(1, 2) == "l|" then out[#out + 1] = m end end return out end
local function lb(env) return health(env).limb_sync end
local function limb_says(env, text) push_msgs(env, { { 22, text } }) end
local BOX_LIMB = "Share Molded limbs and heads: a head, arm or leg lost on one side is removed on the other's copy. PARTLY GUESSWORK: it only acts through a game method it can recognise, and writes re7mp/limb_probe.json with what the game offers (remembered)##limbsync"
local function limb_world(shape, lim, opts)
    local sp = specs3()
    sp[1].limbs = lim or {}
    opts = opts or {}
    opts.limb_shape = shape or "full"
    local env, W = molded_world(opts.role or "join", sp, opts)
    if (opts.role or "join") == "join" then
        mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
        mlive(env, 3)
    else
        mlive(env, 4)
    end
    return env, W
end

do -- JOINER, the yes/no method: a part lost on my copy is told once, cumulative, and again every 10 s; the decoy methods are never called
    local env, W = limb_world("full")
    check(copy_names(molded_report(env)) == NAME_A, "(10.21) limb: the copy is up: " .. copy_names(molded_report(env)))
    check(#limb_msgs(env) == 0, "(10.21) limb: nothing lost: nothing sent (" .. #limb_msgs(env) .. ")")
    W.bodies[1].lose(0) -- the head
    mlive(env, 1.2)
    local m = limb_msgs(env)
    check(#m == 1 and m[1] == "l|" .. NAME_A .. "|1", "(10.21) limb: the head lost here is sent as bit 1: " .. tostring(m[1]))
    W.bodies[1].lose(2) -- the right arm
    mlive(env, 1.2)
    m = limb_msgs(env)
    check(#m == 2 and m[2] == "l|" .. NAME_A .. "|5", "(10.21) limb: then the right arm: the message is the whole mask (head + right arm = 5): " .. tostring(m[2]))
    mlive(env, 4)
    check(#limb_msgs(env) == 2, "(10.21) limb: nothing new: nothing more is sent within 10 s (" .. #limb_msgs(env) .. ")")
    mlive(env, 9)
    m = limb_msgs(env)
    check(#m == 3 and m[3] == "l|" .. NAME_A .. "|5", "(10.21) limb: after 10 s the same mask is announced once more (so a copy that was not there yet gets it): " .. tostring(m[3]))
    check((W.limb_decoy or 0) == 0, "(10.21) limb: the decoy methods (no part parameter / not a yes/no) are never called (" .. tostring(W.limb_decoy) .. ")")
    local d = lb(env)
    check(d.on == true and d.counts.sent == 2 and d.counts.resent == 1 and d.counts.read_ok > 10, "(10.21) limb: the debug file counts: sent " .. tostring(d.counts.sent) .. ", again " .. tostring(d.counts.resent) .. ", readings " .. tostring(d.counts.read_ok))
    check(d.found[1] and d.found[1].type == "app.Em4000ActionController" and d.found[1].first_is_lost == "isLostParts" and d.found[1].first_make_lost == "requestLostParts" and d.found[1].make_lost_candidates == 2, "(10.21) limb: ...and which methods it found: " .. tostring(d.found[1] and d.found[1].first_is_lost) .. " / " .. tostring(d.found[1] and d.found[1].first_make_lost))
    check(d.bodies[1] and d.bodies[1].lost_here == "Head+RightArm" and d.bodies[1].told_other == "Head+RightArm" and d.bodies[1].told_by_other == "none", "(10.21) limb: ...and per body what is lost, told, heard: " .. tostring(d.bodies[1] and d.bodies[1].lost_here))
    -- how often it reads: five calls per scan, two scans a second
    local r0 = W.limb_reads or 0
    mlive(env, 10)
    check((W.limb_reads or 0) - r0 <= 120, "(10.21) limb: reading costs about 5 calls every half second for one body (" .. ((W.limb_reads or 0) - r0) .. " in 10 s)")
end

do -- JOINER, the other player's loss: removed here with the first candidate, checked, no echo back
    local env, W = limb_world("full", { delay = 0.6 })
    limb_says(env, "l|" .. NAME_A .. "|3") -- head + left arm
    mlive(env, 1.0)
    check(#W.bodies[1].requests >= 2 and W.bodies[1].requests[1] == "requestLostParts:0" and W.bodies[1].requests[2] == "requestLostParts:1", "(10.21) limb/apply: the head and the left arm are asked for with requestLostParts: " .. table.concat(W.bodies[1].requests, ","))
    mlive(env, 3)
    check(#W.bodies[1].requests == 2, "(10.21) limb/apply: each only once: it reads as lost after the wait and is left alone (" .. #W.bodies[1].requests .. " calls)")
    local d = lb(env)
    check(d.counts.applied == 2 and d.counts.apply_failed == 0, "(10.21) limb/apply: counted as removed and checked: " .. tostring(d.counts.applied))
    check(next(d.waiting_for_a_body) == nil and d.counts.pending_gave_up == 0, "(10.21) limb/apply: ...and nothing is left waiting")
    check(#limb_msgs(env) == 0, "(10.21) limb/apply: no echo: what the other player told is not told back (" .. #limb_msgs(env) .. ")")
    check(d.bodies[1].lost_here == "Head+LeftArm" and d.bodies[1].told_by_other == "Head+LeftArm" and d.bodies[1].told_other == "none", "(10.21) limb/apply: the debug file: " .. tostring(d.bodies[1].lost_here))
    check(log_has(env, "Head of " .. NAME_A .. " removed with requestLostParts"), "(10.21) limb/apply: the journal says which method worked")
    check(crumbed(env, "removing Head of " .. NAME_A .. " with requestLostParts") and crumbed(env, "limb done"), "(10.21) limb/apply: the crash crumb was written before the call and cleared after it")
    do -- the first reading of a controller's method is named by a crumb too, and cleared at once (a stale "limb" crumb would blame this code for an unrelated crash)
        local first_i, clean_i
        for i, c in ipairs(env.crumb_log or {}) do
            if first_i == nil and c:find("limb: first reading of lost parts: app.Em4000ActionController.isLostParts", 1, true) then first_i = i end
            if first_i and clean_i == nil and i > first_i and c:find("clean: limb first reading done", 1, true) then clean_i = i end
        end
        check(first_i ~= nil and clean_i == first_i + 1, "(10.21) limb/apply: the first reading is named by a crash crumb and the crumb is cleared right after it (" .. tostring(first_i) .. " / " .. tostring(clean_i) .. ")")
    end
    limb_says(env, "l|" .. NAME_A .. "|3")
    mlive(env, 2)
    check(#W.bodies[1].requests == 2, "(10.21) limb/apply: the same message again (the 10 s announce) changes nothing (" .. #W.bodies[1].requests .. " calls)")
    W.bodies[1].lose(4) -- and my own shot takes a leg: that IS new
    mlive(env, 1.2)
    local m = limb_msgs(env)
    check(#m == 1 and m[1] == "l|" .. NAME_A .. "|16", "(10.21) limb/apply: a part lost here afterwards is told, and only that one (right leg = 16): " .. tostring(m[1]))
end

do -- the first candidate does nothing: after 1.5 s the second is tried; the failed one is in the debug file
    local env, W = limb_world("full", { first_dead = true, delay = 0.1 })
    limb_says(env, "l|" .. NAME_A .. "|1")
    mlive(env, 1.0)
    check(#W.bodies[1].requests == 1 and W.bodies[1].requests[1] == "requestLostParts:0", "(10.21) limb/fallback: requestLostParts first")
    mlive(env, 1.2)
    check(#W.bodies[1].requests == 2 and W.bodies[1].requests[2] == "lostParts:0", "(10.21) limb/fallback: it did not read as lost after 1.5 s: lostParts next: " .. table.concat(W.bodies[1].requests, ","))
    mlive(env, 3)
    local d = lb(env)
    check(d.counts.applied == 1 and log_has(env, "Head of " .. NAME_A .. " removed with lostParts"), "(10.21) limb/fallback: removed with the second, checked (" .. tostring(d.counts.applied) .. ")")
    check(d.found[1].apply_errors.requestLostParts and d.found[1].apply_errors.requestLostParts:find("did not read as lost"), "(10.21) limb/fallback: the debug file says why the first was dropped: " .. tostring(d.found[1].apply_errors.requestLostParts))
    check(#W.bodies[1].requests == 2, "(10.21) limb/fallback: and nothing is called again (" .. #W.bodies[1].requests .. ")")
end

do -- no candidate works: each is tried once, then it stops and says so
    local env, W = limb_world("full", { never = true })
    limb_says(env, "l|" .. NAME_A .. "|2")
    mlive(env, 8)
    check(#W.bodies[1].requests == 2, "(10.21) limb/never: each of the two candidates once, no hammering (" .. table.concat(W.bodies[1].requests, ",") .. ")")
    local d = lb(env)
    check(d.counts.apply_failed == 1 and d.counts.applied == 0, "(10.21) limb/never: counted as failed (" .. tostring(d.counts.apply_failed) .. ")")
    check(log_has(env, "LeftArm of " .. NAME_A .. " could not be removed here: none of the candidates made the part read as lost"), "(10.21) limb/never: the journal says so")
    check(d.bodies[1].removing[1] and d.bodies[1].removing[1]:find("^LeftArm: failed"), "(10.21) limb/never: ...and the body's row: " .. tostring(d.bodies[1].removing[1]))
end

do -- no yes/no method: nothing can be read, so nothing is sent and nothing is removed; the probe file still says what the game offers
    local env, W = limb_world("no_read", {})
    W.bodies[1].lose(1)
    limb_says(env, "l|" .. NAME_A .. "|1")
    mlive(env, 9)
    check(#limb_msgs(env) == 0 and #W.bodies[1].requests == 0, "(10.21) limb/no read: nothing sent, nothing removed (" .. #limb_msgs(env) .. " / " .. #W.bodies[1].requests .. ")")
    local d = lb(env)
    check(d.bodies[1] and d.bodies[1].lost_here == "cannot be read" and tostring(d.bodies[1].read_how):find("no way found"), "(10.21) limb/no read: the debug file says it cannot be read: " .. tostring(d.bodies[1] and d.bodies[1].lost_here))
    check(d.found[1].is_lost_methods == 0 and d.found[1].make_lost_candidates == 2, "(10.21) limb/no read: ...but lists the 'make it lost' candidates it saw (" .. tostring(d.found[1].make_lost_candidates) .. ")")
    local f = env.files["re7mp/limb_probe.json"]
    check(f ~= nil and #f.types == 17, "(10.21) limb/probe: the probe file has the 17 type definitions (" .. tostring(f and #f.types) .. ")")
    local row
    for _, t in ipairs(f and f.types or {}) do if t.type == "app.Em4000ActionController" then row = t end end
    check(row and row.found == true and #row.methods >= 6, "(10.21) limb/probe: ...the controller's members are listed (" .. tostring(row and #row.methods) .. ")")
    local missing = 0
    for _, t in ipairs(f and f.types or {}) do if t.found == false then missing = missing + 1 end end
    check(missing == 15, "(10.21) limb/probe: ...the 15 types this fake game does not have are marked found = false (" .. missing .. ")")
    check(f.bodies["Em4000@join"] and f.bodies["Em4000@join"].controllers[1] and f.bodies["Em4000@join"].controllers[1].type == "app.Em4000ActionController", "(10.21) limb/probe: the first Molded body's controller is described")
    check(f.what_was_found[1].type == "app.Em4000ActionController" and #f.what_was_found[1].apply_methods == 2, "(10.21) limb/probe: ...and what was found by shape")
end

do -- no way to make a part lost: sent yes (the other side may have one), removed no; the debug file says so
    local env, W = limb_world("no_apply", {})
    W.bodies[1].lose(3)
    mlive(env, 1.2)
    check(#limb_msgs(env) == 1 and limb_msgs(env)[1] == "l|" .. NAME_A .. "|8", "(10.21) limb/no apply: a left leg lost here is still told (mask 8)")
    limb_says(env, "l|" .. NAME_A .. "|1")
    mlive(env, 3)
    local d = lb(env)
    check(d.counts.apply_failed == 1 and d.counts.no_apply_method == 1 and log_has(env, "no method takes a part type and has Lost in its name"), "(10.21) limb/no apply: the head cannot be removed here and the journal says why")
end

do -- the Body and the Blade are not limbs: lost here, they are not read and not sent
    local env, W = limb_world("full")
    W.bodies[1].lose(5)
    W.bodies[1].lose(6)
    mlive(env, 3)
    check(#limb_msgs(env) == 0, "(10.21) limb/body: Body and Blade lost here: nothing is sent (" .. #limb_msgs(env) .. ")")
    local r0 = W.limb_reads or 0
    mlive(env, 1)
    check((W.limb_reads or 0) - r0 <= 10 and (W.limb_reads or 0) - r0 >= 5, "(10.21) limb/body: only five parts are asked per reading (" .. ((W.limb_reads or 0) - r0) .. " in a second)")
end

do -- the other shape: a list of LostPartsWork objects with an IsLost flag is read; the part comes from the object's own type field
    local env, W = limb_world("work", {})
    W.bodies[1].lose(1)
    W.bodies[1].lose(3)
    mlive(env, 1.2)
    check(#limb_msgs(env) == 1 and limb_msgs(env)[1] == "l|" .. NAME_A .. "|10", "(10.21) limb/work: read from the list: left arm + left leg = 10: " .. tostring(limb_msgs(env)[1]))
    local d = lb(env)
    check(tostring(d.bodies[1].read_how):find("collection LostWork", 1, true), "(10.21) limb/work: the debug file names the field it read: " .. tostring(d.bodies[1].read_how))
    limb_says(env, "l|" .. NAME_A .. "|4")
    mlive(env, 3)
    check(W.bodies[1].requests[1] == "requestLostParts:2" and d.counts ~= nil, "(10.21) limb/work: the right arm is removed with requestLostParts (" .. table.concat(W.bodies[1].requests, ",") .. ")")
    local f = env.files["re7mp/limb_probe.json"]
    local c = f and f.bodies["Em4000@join"] and f.bodies["Em4000@join"].controllers[1]
    check(c and c.collections[1] and c.collections[1].field == "LostWork" and #c.collections[1].elements == 7, "(10.21) limb/work: the probe file shows the list's elements for the next step (" .. tostring(c and c.collections[1] and #c.collections[1].elements) .. ")")
end

do -- during a cutscene nothing is sent and nothing is removed; after it (and its quiet seconds) both happen
    local env, W = limb_world("full", { delay = 0.1 })
    local gs = game_state(env)
    gs.n = 1
    W.bodies[1].lose(0)
    limb_says(env, "l|" .. NAME_A .. "|2")
    mlive(env, 4)
    check(#limb_msgs(env) == 0 and #W.bodies[1].requests == 0, "(10.21) limb/quiet: during a cutscene nothing is sent or removed (" .. #limb_msgs(env) .. " / " .. #W.bodies[1].requests .. ")")
    gs.n = 0
    mlive(env, 9)
    check(#limb_msgs(env) >= 1 and #W.bodies[1].requests >= 1, "(10.21) limb/quiet: afterwards both happen (" .. #limb_msgs(env) .. " / " .. #W.bodies[1].requests .. ")")
end

do -- the other player's loss arrives BEFORE this game has the copy: it waits, and is applied when the copy is taken; or is given up after 30 s
    local sp = specs3()
    sp[1].limbs = { delay = 0.1 }
    local env, W = molded_world("join", sp, { limb_shape = "full" })
    limb_says(env, "l|" .. NAME_A .. "|1")
    mlive(env, 3)
    local dw = lb(env)
    check(#W.bodies[1].requests == 0 and next(dw.waiting_for_a_body) ~= nil, "(10.21) limb/wait: no copy yet: the message is kept (" .. #W.bodies[1].requests .. " calls)")
    mfeed(env, { ment(NAME_A, 10, 10, { hp = 150 }) })
    mlive(env, 6)
    local dw2 = lb(env)
    check(#W.bodies[1].requests == 1 and dw2.counts.applied == 1, "(10.21) limb/wait: the copy is taken: the head is removed (" .. #W.bodies[1].requests .. " calls, applied " .. tostring(dw2.counts.applied) .. ")")
    check(#limb_msgs(env) == 0, "(10.21) limb/wait: ...and it is not told back (" .. #limb_msgs(env) .. ")")
    local env2, W2 = molded_world("join", specs3(), { limb_shape = "full" })
    limb_says(env2, "l|Em4000_999999999999|1")
    mlive(env2, 33)
    local dg = lb(env2)
    check(dg.counts.pending_gave_up == 1 and next(dg.waiting_for_a_body) == nil, "(10.21) limb/wait: a loss for a body that never comes is given up after 30 s (" .. tostring(dg.counts.pending_gave_up) .. ")")
end

do -- messages that are not for a Molded, malformed ones, more than 20 a second, the box off
    local env, W = limb_world("full", { delay = 0.1 })
    push_msgs(env, { { 22, "l|Em2000|1" }, { 22, "l|Em4000_x|zz" }, { 22, "garbage" }, { 22, "l|Em4300_3fa91c2e9b4d|1" } }) -- (one push: each push replaces the inbox)
    mlive(env, 3)
    local d0 = lb(env)
    check(#W.bodies[1].requests == 0 and next(d0.waiting_for_a_body) == nil, "(10.21) limb/refuse: Mia, a malformed message, garbage and a non-Molded name are all ignored (" .. #W.bodies[1].requests .. " calls)")
    check(d0.counts.refused == 4, "(10.21) limb/refuse: ...and counted (" .. tostring(d0.counts.refused) .. ")")
    local msgs = {}
    for i = 1, 25 do msgs[i] = { 22, "l|" .. NAME_A .. "|1" } end
    push_msgs(env, msgs)
    mlive(env, 0.3)
    local d1 = lb(env)
    check(d1.counts.heard == 20 and d1.counts.refused == 9, "(10.21) limb/refuse: 25 in a moment: 20 taken, 5 refused (" .. tostring(d1.counts.heard) .. " heard, " .. tostring(d1.counts.refused) .. " refused in all)")
    local env2, W2 = limb_world("full", {}, { settings = { limb_sync = false } })
    W2.bodies[1].lose(0)
    limb_says(env2, "l|" .. NAME_A .. "|2")
    mlive(env2, 5)
    local d2 = lb(env2)
    check(#limb_msgs(env2) == 0 and #W2.bodies[1].requests == 0 and (W2.limb_reads or 0) == 0 and d2.on == false, "(10.21) limb/box: with limb_sync false: no reading, no message, no call (" .. tostring(W2.limb_reads) .. " readings)")
    check(d2.counts.heard == 0 and d2.counts.refused == 1 and next(d2.waiting_for_a_body) == nil, "(10.21) limb/box: ...and what the other player says is refused, not kept (heard " .. tostring(d2.counts.heard) .. ", refused " .. tostring(d2.counts.refused) .. ")")
    env2.check_override[BOX_LIMB] = true
    run_ui(env2)
    mlive(env2, 3)
    check(#limb_msgs(env2) >= 1, "(10.21) limb/box: ticking the box starts it")
    env2.check_override[BOX_LIMB] = false
    run_ui(env2)
    mlive(env2, 2)
    check(env2.files["re7mp/settings.json"] and env2.files["re7mp/settings.json"].limb_sync == false, "(10.21) limb/box: unticking is remembered as limb_sync = false")
end

do -- a session that ended inside a limb call: reported, off this time, ticking the box clears it
    local env, W = limb_world("full", {}, { before_load = function(e) e.files["re7mp/lastcall.json"] = { stage = "limb", call = "removing Head of Em4000_x with requestLostParts", time = 1700000000, session = 1, clock = 1 } end })
    W.bodies[1].lose(0)
    mlive(env, 3)
    check(log_has(env, "previous session: The last session ended while the script was reading or applying the lost parts"), "(10.21) limb/crash: reported at the start")
    local dc = lb(env)
    check(#limb_msgs(env) == 0 and (W.limb_reads or 0) == 0 and dc.crash_marker ~= nil, "(10.21) limb/crash: off this time: no reading, nothing sent (" .. tostring(W.limb_reads) .. ")")
    env.check_override[BOX_LIMB] = true
    run_ui(env)
    mlive(env, 3)
    local dc2 = lb(env)
    check(#limb_msgs(env) >= 1 and dc2.crash_marker == nil, "(10.21) limb/crash: ticking the box clears the marker and works (" .. #limb_msgs(env) .. ")")
end

do -- a body that is dead is not read or sent for; and a read that fails for every part does not crash anything
    local env, W = limb_world("full", {})
    W.bodies[1].lose(0)
    W.bodies[1].dead = true
    mlive(env, 3)
    check(#limb_msgs(env) == 0, "(10.21) limb/dead: a dead body: nothing sent (" .. #limb_msgs(env) .. ")")
    local env2, W2 = limb_world("full", { read_error = true })
    mlive(env2, 4)
    local de = lb(env2)
    check(#limb_msgs(env2) == 0 and de.bodies[1] and de.bodies[1].lost_here == "cannot be read" and de.counts.errors == 0, "(10.21) limb/error: a game method that raises: 'cannot be read', no error counted, nothing sent")
end

do -- THE HOST: its own Molded (a root of this game): a part lost here is told to the joiner; the joiner's loss is removed here
    local env, W = limb_world("full", { delay = 0.1 }, { role = "host" })
    W.bodies[1].lose(0)
    mlive(env, 2)
    local m = limb_msgs(env)
    check(#m == 1 and m[1] == "l|" .. NAME_A .. "|1", "(10.21) limb/host: a head lost on the host's own Molded is told (" .. tostring(m[1]) .. ")")
    limb_says(env, "l|" .. NAME_A .. "|6")
    mlive(env, 4)
    local dh = lb(env)
    check(#W.bodies[1].requests == 2 and dh.counts.applied == 2, "(10.21) limb/host: the joiner's arms are removed on the host's body (" .. table.concat(W.bodies[1].requests, ",") .. ")")
    check(#limb_msgs(env) == 1, "(10.21) limb/host: no echo (" .. #limb_msgs(env) .. ")")
    local envd, Wd = limb_world("full", {}, { role = "host" })
    Wd.bodies[1].lose(2)
    Wd.bodies[1].dead = true
    mlive(envd, 3)
    check(#limb_msgs(envd) == 0, "(10.21) limb/host: a dead body of the host's: nothing is sent for it (" .. #limb_msgs(envd) .. ")")
    local envh, Wh = limb_world("full", { delay = 0.1 }, { role = "host", settings = { hit_accept = false } })
    limb_says(envh, "l|" .. NAME_A .. "|6")
    mlive(envh, 4)
    local dh2 = lb(envh)
    check(#Wh.bodies[1].requests == 0 and dh2.counts.refused == 1, "(10.21) limb/host: with 'hits from the other player' off here, the joiner's loss is refused (" .. #Wh.bodies[1].requests .. " calls, refused " .. tostring(dh2.counts.refused) .. ")")
end
