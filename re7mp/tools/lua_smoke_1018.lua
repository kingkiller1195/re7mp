-- Checks of build 10.18 for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1018_file) with that file's helpers in one table.
--   RE7MP_ONLY_1018=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What it covers (all of it is the game's behaviour AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   1. story points: the probe reads every flow's number (the Variable object the game answers with), tells the other player the changes, finds the steps; matching takes a part
--      that is BEHIND forward one step at a time, never back, not after a fall here, stops when the game ignores a step (or only writes the number when the box says so)
--   2. the enemy targeting log (reads only)
--   3. the enemy hand-over: offered when the joiner is clearly nearer, taken by the joiner, the host's body follows (position, health), hits are passed on, taken back,
--      death, refusal, bosses stay with the host, the box off puts everything back
local H = ...
local check, Obj, make_td, make_go, make_scene, vec = H.check, H.Obj, H.make_td, H.make_go, H.make_scene, H.vec
local new_environment, build_world, load_script, host_role_files = H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, texts_have, log_has = H.run_frames, H.run_ui, H.ui_has, H.texts_have, H.log_has
local messages_of_kind, bump_remote = H.messages_of_kind, H.bump_remote

local BOX_FLOW = "Story points: read the game's step numbers and tell the other player (reads only; debug file: story_flow, re7mp/flow_probe.json)##flowprobe"
local BOX_MATCH = "EXPERIMENTAL: match them: a part of mine that is BEHIND the other player's is taken forward one step at a time, never back; only in a quiet moment. Not remembered##matchon"
local BTN_ONCE = "Catch up once (one pass now, then it stops)##matchonce"
local BOX_WRITE = "When the game ignores a step twice, only write the number (skips what the step would do; may leave a gimmick unplayed). Not remembered##matchwrite"
local BOX_TGT = "Enemy targeting log (reads only): who the nearest enemies are going for and how far each is from you and from the other player (debug file: enemy_targets)##tgtlog"
local BOX_OWN = "EXPERIMENTAL, BOTH players tick it (mode 3 on both): the enemy goes to the player who is clearly nearer, and that player's game runs it (its AI targets them for real). Bosses and Molded stay with the host. Not remembered##handover"
local BOX_AI = "Also switch off their AI (riskier; they stop fighting the host's positions)"

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

-- =============================================================================================
-- 1. story points
-- =============================================================================================
-- a fake story flow: one part (c03_2_Main, hash 2c60d2ac, steps every 100 up to 800); the number comes back as a via.userdata.Variable; sendNo sets it unless rec.ignore
local function flow_setup(rec)
    return function(env)
        rec.num = rec.num or 500
        rec.sent, rec.written = {}, {}
        local flow_go = make_go("c03_2_MainFlow", vec(0, 0, 0), {})
        local ctrl = Obj.new("app.GameFlowActiveControl", {
            get_GameObject = function() return flow_go end,
            hasState = function(_, n) return n % 100 == 0 and n <= 800 end,
            ["sendNo(System.Int32)"] = function(_, n)
                rec.sent[#rec.sent + 1] = { n = n, at = env.clock }
                if not rec.ignore then rec.num = n end
            end,
        }, { FlowEndNo = 800 })
        local entry = Obj.new("Entry", {}, { key = 0x2c60d2ac, value = ctrl })
        local dict = Obj.new("System.Collections.Generic.Dictionary", {}, { _entries = { get_elements = function() return { entry } end }, _count = 1 })
        local mgr = Obj.new("app.GameFlowFsmManager", {
            ["getProgressiveNo(System.UInt32)"] = function() local n = rec.num return Obj.new("via.userdata.Variable", { get_Value = function() return n end }) end,
            ["setProgressiveNo(System.UInt32, System.Int32)"] = function(_, h, n) rec.written[#rec.written + 1] = n rec.num = n end,
        }, { Flows = dict })
        env.singletons["app.GameFlowFsmManager"] = mgr
    end
end

local function their(env, kind, num, prev)
    local d = env.files["re7mp_msg_in.json"]
    env.msg_n = (env.msg_n or 0) + 1
    local list = (d and d.msgs) or {}
    list[#list + 1] = { n = env.msg_n, id = env.msg_n, k = 18, p = string.format("%s|0|2c60d2ac|%d|%d", kind, num, prev or -1) }
    env.files["re7mp_msg_in.json"] = { epoch = 1, msgs = list }
end

do
    local rec = {}
    local env = world("host", flow_setup(rec))
    live(env, 3)
    local h = health(env)
    local sf = h.story_flow
    check(sf and sf.on == true and sf.counts.read_ok > 0, "(10.18) flow: the probe reads the flows without being asked (it only reads)")
    check(sf and sf.flows[1] and sf.flows[1].hash == "2c60d2ac" and sf.flows[1].mine == 500, "(10.18) flow: the part's number is read through the Variable the game answers with: " .. tostring(sf and sf.flows[1] and sf.flows[1].mine))
    check(sf and sf.number_read_via == "getProgressiveNo(System.UInt32)" and sf.number_read_by == "get_Value", "(10.18) flow: ...and the way it was read is written down: " .. tostring(sf and sf.number_read_via) .. " / " .. tostring(sf and sf.number_read_by))
    check(sf and sf.flows[1].part == "c03_2_MainFlow" and sf.flows[1].end_no == 800, "(10.18) flow: the part's object name and end number are read")
    local pf = env.files["re7mp/flow_probe.json"] or env.files["re7mp_flow_probe.json"]
    check(pf and pf.flows and pf.flows[1] and pf.flows[1].number == 500, "(10.18) flow: the probe file is written with the numbers")
    check(#rec.sent == 0 and #rec.written == 0, "(10.18) flow: the probe alone never touches the game (no step sent, no number written)")
    -- a change is told to the other player ("n|chapter|hash|number|before"), a fall as "r|..."
    rec.num = 600
    live(env, 2.2)
    local m = messages_of_kind(env, 18)
    local rose = false
    for _, p in ipairs(m) do if p == "n|0|2c60d2ac|600|500" then rose = true end end
    check(rose, "(10.18) flow: a step forward is told to the other player: " .. table.concat(m, " ; "):sub(1, 120))
    rec.num = 400
    live(env, 2.2)
    local fell = false
    for _, p in ipairs(messages_of_kind(env, 18)) do if p == "r|0|2c60d2ac|400" then fell = true end end
    check(fell, "(10.18) flow: a fall is told as a rewind")
    -- the steps of the part are found by asking hasState (40 questions a second at most)
    live(env, 40)
    h = health(env)
    check(h.story_flow.flows[1].steps == 9, "(10.18) flow: the part's steps are found (0, 100 ... 800 = 9): " .. tostring(h.story_flow.flows[1].steps))
    -- the other player's numbers are shown next to mine
    their(env, "n", 700, 600)
    live(env, 1.5)
    h = health(env)
    check(h.story_flow.flows[1].theirs == 700, "(10.18) flow: the other player's number is kept: " .. tostring(h.story_flow.flows[1].theirs))
    run_ui(env)
    check(ui_has(env, "mine 400, Bob 700") and ui_has(env, "(behind)"), "(10.18) flow: the panel shows mine next to theirs and says which is behind")
    check(#rec.sent == 0, "(10.18) flow: with the matching box off nothing is sent however far behind it is")
    check(not log_has(env, "script error"), "(10.18) flow: no script error")
end

do -- matching
    local rec = { num = 500 }
    local env = world("host", flow_setup(rec))
    live(env, 2)
    their(env, "n", 600, 500)
    their(env, "n", 700, 600)
    live(env, 1.5)
    tick(env, BOX_MATCH, true)
    live(env, 7)
    check(#rec.sent == 2 and rec.sent[1].n == 600 and rec.sent[2].n == 700, "(10.18) match: a part that is behind goes forward through the steps the other player went through, in order: "
        .. (function() local t = {} for _, s in ipairs(rec.sent) do t[#t + 1] = s.n end return table.concat(t, ",") end)())
    check(#rec.sent == 2 and rec.sent[2].at - rec.sent[1].at >= 1.4, "(10.18) match: ...one step at a time, at least 1.5 s apart")
    local h = health(env)
    check(h.story_match.status:find("in step", 1, true) ~= nil and rec.num == 700, "(10.18) match: ...and says it is in step: " .. tostring(h.story_match.status))
    -- never back: the other player's number is lower than mine
    their(env, "r", 650, -1)
    live(env, 4)
    check(#rec.sent == 2, "(10.18) match: a number that is lower than mine is never matched (no step back)")
    -- a fall here (a checkpoint reload) is not pulled forward again until the other player's number moves
    rec.num = 300
    live(env, 5)
    check(#rec.sent == 2, "(10.18) match: after a fall here nothing is pulled forward while the other player's number stands still (" .. #rec.sent .. " sends)")
    their(env, "n", 800, 700)
    live(env, 4)
    check(#rec.sent >= 3 and rec.sent[3].n > 300 and rec.sent[3].n <= 800 and rec.num > 300, "(10.18) match: ...but when their number moves it is, up from 300 (first step " .. tostring(rec.sent[3] and rec.sent[3].n) .. ")")
    check(not log_has(env, "script error"), "(10.18) match: no script error")
end

do -- a game that ignores sendNo: asked twice, then left alone; the second box writes the number instead
    local rec = { num = 500, ignore = true }
    local env = world("host", flow_setup(rec))
    live(env, 2)
    their(env, "n", 600, 500)
    live(env, 1.5)
    tick(env, BOX_MATCH, true)
    live(env, 12)
    check(#rec.sent == 2 and rec.num == 500, "(10.18) match: a step the game ignores is asked for twice and then left alone (" .. #rec.sent .. " sends)")
    local h = health(env)
    check(h.story_match.stuck and h.story_match.stuck["2c60d2ac"] == 600 and h.story_match.counts.stuck == 1, "(10.18) match: ...and the part is listed as stuck")
    local rec2 = { num = 500, ignore = true }
    local env2 = world("host", flow_setup(rec2))
    live(env2, 2)
    their(env2, "n", 600, 500)
    live(env2, 1.5)
    tick(env2, BOX_WRITE, true)
    tick(env2, BOX_MATCH, true)
    live(env2, 12)
    check(#rec2.written == 1 and rec2.written[1] == 600 and rec2.num == 600, "(10.18) match: with the second box ticked only the number is written, once: " .. #rec2.written)
    -- "Catch up once": one pass with the matching box off, then it stops
    local rec3 = { num = 500 }
    local env3 = world("host", flow_setup(rec3))
    live(env3, 2)
    their(env3, "n", 600, 500)
    their(env3, "n", 700, 600)
    live(env3, 1.5)
    env3.ui_press[BTN_ONCE] = true
    run_ui(env3)
    live(env3, 7)
    check(#rec3.sent == 2 and rec3.num == 700, "(10.18) match: the 'Catch up once' button does one pass with the box off: " .. #rec3.sent)
    their(env3, "n", 800, 700)
    live(env3, 6)
    check(#rec3.sent == 2, "(10.18) match: ...and then it stops (the next number is not matched)")
end

-- =============================================================================================
-- 2/3. enemies: a fake ordinary enemy (Em4100) built on the world's Jack, with a think component the tests can read and a target the tests can set
-- =============================================================================================
local function enemy_setup(rec)
    return function(env)
        local go = env.jack
        env.scene = make_scene({ env.player, go }) -- (only this enemy: the others of the world are not part of these checks)
        local dc = comp_of(go, "app.Em2000.Em2000DamageController")
        local st = comp_of(go, "app.Em2000Status")
        local think = comp_of(go, "app.Em2000Think")
        go.m.get_Name = function() return rec.name or "Em4100" end
        rec.go, rec.dc, rec.st, rec.hi, rec.think = go, dc, st, dc.f.HealthInfo, think
        rec.set, rec.hits, rec.dead, rec.think_log = {}, {}, false, {}
        rec.max = rec.max or 1000
        dc.m.get_maxHealth = function() return rec.max end
        dc.m["setHealth(System.Single, System.Single)"] = function(_, hp, mx) rec.set[#rec.set + 1] = { hp, mx } rec.hi.f._CurrentHealth = hp end
        dc.m.newFakeDamageInfo = function(_, dmg) return Obj.new("app.DamageInfo", {}, { dmg = dmg }) end
        dc.m.addManualDamage = function(_, info)
            rec.hits[#rec.hits + 1] = info.f.dmg
            if rec.real_damage then rec.hi.f._CurrentHealth = math.max(1, rec.hi.f._CurrentHealth - info.f.dmg) end
            if rec.dies_on and #rec.hits >= rec.dies_on then rec.dead = true rec.hi.f._CurrentHealth = 0 end
            return Obj.new("app.DamageRecord", {})
        end
        st.m.get_IsDead = function() return rec.dead end
        think.m.set_Enabled = function(_, on) rec.think_on = on rec.think_log[#rec.think_log + 1] = on end
        think.m.get_Target = function() return rec.target end
        go.xf:call("set_Position", vec(rec.x or 20, 0, rec.z or 0))
    end
end

local function pos_of(rec)
    local p = rec.go.xf:call("get_Position")
    return p.x, p.z
end

-- 2. the targeting log
do
    local rec = { x = 20, z = 0 }
    local env = world("host", enemy_setup(rec))
    env.camera_pos = vec(0, 1.6, 0)
    env.files["re7mp_in.json"].x, env.files["re7mp_in.json"].z = 18, 0
    live(env, 2.5)
    local h = health(env)
    local t = h.enemy_targets and h.enemy_targets.enemies and h.enemy_targets.enemies.Em4100
    check(h.enemy_targets and h.enemy_targets.on == true, "(10.18) targets: the log is on at every start (it only reads)")
    check(t and t.reads > 0 and t.targeting_nobody == t.reads, "(10.18) targets: an enemy whose AI has no target is logged as going for nobody: " .. tostring(t and t.targeting_nobody) .. "/" .. tostring(t and t.reads))
    check(t and t.nearer_them > 0 and t.nearer_me == 0 and t.last_m_from_me and t.last_m_from_me > 19 and t.last_m_from_them < 3, "(10.18) targets: ...with its distance from me (20 m) and from the other player (2 m)")
    check(t and t.hand_over_would_choose_the_joiner > 0, "(10.18) targets: ...and counts that the hand-over rule WOULD give it to the joiner (it is given nothing: the box is off)")
    check(#messages_of_kind(env, 20) == 0 and rec.think_on == nil, "(10.18) targets: reading only: no message, no AI switched")
    rec.target = env.player
    live(env, 2.5)
    h = health(env)
    t = h.enemy_targets.enemies.Em4100
    check(t.targeting_me > 0 and t.last == "me", "(10.18) targets: when the AI's target is my player it is logged as going for me: " .. tostring(t.targeting_me))
    rec.think.m.get_Target = function() error("fake: unreadable") end
    rec.think.m.get_field = nil
    live(env, 2.5)
    h = health(env)
    check(h.enemy_targets.enemies.Em4100.unreadable > 0 or h.enemy_targets.counts.unreadable > 0, "(10.18) targets: a target that cannot be read is counted, not an error")
    tick(env, BOX_TGT, false)
    live(env, 1.5)
    local reads = health(env).enemy_targets.enemies.Em4100.reads
    live(env, 3)
    check(health(env).enemy_targets.enemies.Em4100.reads == reads, "(10.18) targets: the box turns the log off")
    check(not log_has(env, "script error"), "(10.18) targets: no script error")
end

-- 3. the hand-over: a host and a joiner, two games side by side. Messages and the state file are carried across by hand, as re7mp.exe does.
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

local function step(a, b, secs)
    for _ = 1, math.floor(secs / 0.05 + 0.5) do
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

-- positions: where each player stands (their own camera, and where the other game sees them)
local function stand(host, join, hx, hz, jx, jz)
    host.camera_pos = vec(hx, 1.6, hz)
    join.camera_pos = vec(jx, 1.6, jz)
    local a, b = host.files["re7mp_in.json"], join.files["re7mp_in.json"]
    a.x, a.y, a.z = jx, 1.6, jz
    b.x, b.y, b.z = hx, 1.6, hz
end

local function pair(hrec, jrec, opts)
    opts = opts or {}
    local host = world("host", enemy_setup(hrec))
    local join = world("join", enemy_setup(jrec))
    if opts.far then stand(host, join, 19, 0, -30, 0) else stand(host, join, 0, 0, 18, 0) end
    host.combo_override["Enemy sync"] = 3
    join.combo_override["Enemy sync"] = 3
    run_ui(host)
    run_ui(join)
    join.check_override[BOX_AI] = true
    run_ui(join)
    if not opts.host_off then tick(host, BOX_OWN, true) end
    if not opts.join_off then tick(join, BOX_OWN, true) end
    return host, join
end

do
    local hrec, jrec = { x = 20, z = 0, real_damage = true }, { x = 20, z = 0, real_damage = true }
    local host, join = pair(hrec, jrec, { far = true })
    step(host, join, 1.5)
    check(jrec.think_on == false, "(10.18) hand-over: (set-up) mode 3 with the AI switched off: the joiner's copy is being moved onto the host's, its AI off")
    check(hrec.think_on == nil and #(host.sent_log or {}) >= 0 and not sent_has(host, "20:o|"), "(10.18) hand-over: (set-up) nothing is offered or touched on the host while the host is the nearer player")
    stand(host, join, 0, 0, 18, 0)
    step(host, join, 4)
    local hh, jh = health(host).enemy_handover, health(join).enemy_handover
    check(hh and hh.on == true and jh and jh.on == true, "(10.18) hand-over: both boxes are ticked")
    check(sent_has(host, "20:o|Em4100|20.00|0.00"), "(10.18) hand-over: the host offered the enemy the joiner is clearly nearer to: " .. table.concat(host.sent_log or {}, " ; "):sub(1, 160))
    check(sent_has(join, "20:a|Em4100|ok"), "(10.18) hand-over: the joiner answered ok (its copy was where the host's is, alive, awake)")
    check(hh.counts.offered == 1 and hh.counts.accepted == 1 and hh.run_by_the_joiner.Em4100 ~= nil, "(10.18) hand-over: the host lists it as run by the joiner")
    check(jh.run_by_me_for_the_host.Em4100 ~= nil and jh.counts.accepted == 1, "(10.18) hand-over: the joiner lists it as run for the host")
    -- (10.21) the joiner runs this enemy, so a kill ask for it ("k|name|x|z", kind 21) is refused and the host's body is left alone
    local hits_before = #hrec.hits
    deliver(host, 21, "k|Em4100|20.00|0.00")
    step(host, join, 0.6)
    check(sent_has(host, "21:a|Em4100|no|the joiner runs it (the hand-over)") and #hrec.hits == hits_before and hrec.dead == false, "(10.21) hand-over: a kill ask for an enemy the joiner runs is refused, the host's body is not hit: " .. table.concat(host.sent_log or {}, " ; "):sub(-140))
    check(hrec.think_on == false, "(10.18) hand-over: the host's own AI components of that body are switched off")
    check(jrec.think_on == true, "(10.18) hand-over: the joiner's copy has its AI back on (it runs the enemy now)")
    local d = host.files["re7mp_state_out.json"]
    check(d and not tostring(d.p):find("Em4100,", 1, true), "(10.18) hand-over: the host no longer sends that enemy's snapshot")
    local j = join.files["re7mp_state_out.json"]
    check(j and tostring(j.p):find("Em4100,20.00", 1, true) and tostring(j.p):match("^T[%d%.]+;") ~= nil, "(10.18) hand-over: the joiner sends its enemy's state in the host's own text (T<clock>;Em4100,x,y,z...): " .. tostring(j and j.p):sub(1, 70))
    -- the joiner's enemy walks: the host's body follows
    jrec.go.xf:call("set_Position", vec(25, 0, 3))
    step(host, join, 1.5)
    local x, z = pos_of(hrec)
    check(math.abs(x - 25) < 0.5 and math.abs(z - 3) < 0.5, "(10.18) hand-over: the host's body follows the joiner's enemy: " .. string.format("%.2f, %.2f", x, z))
    -- the joiner's enemy is hurt (its own player shot it): the host's body takes the same number
    jrec.hi.f._CurrentHealth = 300
    step(host, join, 2)
    check(hrec.hi.f._CurrentHealth == 300 and #hrec.set >= 1, "(10.18) hand-over: the owner's health is the pool: the host's body goes to 300 too: " .. tostring(hrec.hi.f._CurrentHealth))
    check(health(host).enemy_handover.counts.hits_forwarded == 0, "(10.18) hand-over: ...and that is not taken for a hit the host landed")
    -- the host's player shoots the body: the hit is passed on and lands on the joiner's enemy
    hrec.hi.f._CurrentHealth = 200
    step(host, join, 2.5)
    check(sent_has(host, "20:h|Em4100|100"), "(10.18) hand-over: a drop of 100 that the pool did not write is passed on as a hit: " .. table.concat(host.sent_log or {}, " ; "):sub(-120))
    check(#jrec.hits == 1 and jrec.hits[1] == 100, "(10.18) hand-over: ...and the joiner's enemy takes it through the game's own damage call: " .. #jrec.hits)
    check(hrec.hi.f._CurrentHealth == 200 and jrec.hi.f._CurrentHealth == 200, "(10.18) hand-over: ...so both numbers end at 200 (not raised back): " .. tostring(hrec.hi.f._CurrentHealth) .. " / " .. tostring(jrec.hi.f._CurrentHealth))
    -- the host's player is at the enemy and the joiner is far: it goes back to the host
    stand(host, join, 24, 2, 10, 0)
    step(host, join, 3)
    hh, jh = health(host).enemy_handover, health(join).enemy_handover
    check(sent_has(host, "20:r|Em4100"), "(10.18) hand-over: when the host is clearly nearer again it takes the enemy back")
    check(hrec.think_on == true, "(10.18) hand-over: ...its AI components are switched on again")
    check(next(hh.run_by_the_joiner) == nil and next(jh.run_by_me_for_the_host) == nil, "(10.18) hand-over: ...nothing is listed as run by the joiner any more, on either side")
    local d2 = host.files["re7mp_state_out.json"]
    check(d2 and tostring(d2.p):find("Em4100,", 1, true) ~= nil, "(10.18) hand-over: ...and the host sends its snapshots of it again")
    check(jrec.think_on == false, "(10.18) hand-over: ...and the joiner's copy is moved onto the host's again, its AI off")
    -- it stays with the host for a while, even when the joiner is nearer again
    stand(host, join, 0, 0, 24, 2)
    local offered = hh.counts.offered
    step(host, join, 5)
    check(health(host).enemy_handover.counts.offered == offered, "(10.18) hand-over: after a take-back it stays with the host for 30 s (no new offer in 5 s)")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.18) hand-over: no script error on either side")
end

do -- the joiner's enemy dies
    local hrec, jrec = { x = 20, z = 0, dies_on = 1 }, { x = 20, z = 0 }
    local host, join = pair(hrec, jrec)
    step(host, join, 5.5)
    check(hrec.think_on == false, "(10.18) death: (set-up) the host's body is a puppet")
    jrec.dead = true
    jrec.hi.f._CurrentHealth = 0
    step(host, join, 4)
    check(hrec.dead == true and #hrec.hits >= 1, "(10.18) death: the joiner's enemy is dead, so the host's body is finished with the game's damage call: " .. #hrec.hits)
    local hh = health(host).enemy_handover
    check(next(hh.run_by_the_joiner) == nil and hh.why_taken_back["it died"] == 1, "(10.18) death: ...and it is no longer listed: " .. tostring(next(hh.why_taken_back)))
    check(hrec.think_on == false and not sent_has(host, "20:r|Em4100"), "(10.18) death: ...a dead body's AI is not switched on again, and the joiner is not told to take it back")
end

do -- a joiner who has not ticked the box, a boss, and the box switched off
    local hrec, jrec = { x = 20, z = 0 }, { x = 20, z = 0 }
    local host, join = pair(hrec, jrec, { join_off = true })
    step(host, join, 6)
    check(sent_has(join, "20:a|Em4100|no|my box is off"), "(10.18) refuse: a joiner whose box is off says so")
    local hh = health(host).enemy_handover
    check(hrec.think_on == nil and hh.counts.accepted == 0 and hh.counts.refused == 1, "(10.18) refuse: ...nothing is switched on the host: " .. tostring(hh.counts.refused))
    step(host, join, 10)
    check(health(host).enemy_handover.counts.offered == 1, "(10.18) refuse: ...and the host does not ask again soon (a pause of 60 s)")

    local brec, bjrec = { x = 20, z = 0, name = "Em2000" }, { x = 20, z = 0, name = "Em2000" }
    local bh, bj = pair(brec, bjrec)
    step(bh, bj, 6)
    local bhh = health(bh).enemy_handover
    check(bhh.counts.offered == 0 and bhh.counts.skipped_boss > 0 and brec.think_on == nil, "(10.18) boss: a boss (Em2000) is never offered, however near the joiner is: " .. tostring(bhh.counts.offered))

    local crec, cjrec = { x = 20, z = 0 }, { x = 20, z = 0 }
    local ch, cj = pair(crec, cjrec)
    step(ch, cj, 5.5)
    check(crec.think_on == false, "(10.18) box off: (set-up) the host's body is a puppet")
    tick(ch, BOX_OWN, false)
    step(ch, cj, 1)
    check(crec.think_on == true and next(health(ch).enemy_handover.run_by_the_joiner) == nil, "(10.18) box off: switching the host's box off puts the AI back at once")
    check(next(health(cj).enemy_handover.run_by_me_for_the_host) == nil, "(10.18) box off: ...and the joiner lets go of it (its copy is moved onto the host's again)")
end

do -- no state from the joiner for 3 s: the host takes it back
    local hrec, jrec = { x = 20, z = 0 }, { x = 20, z = 0 }
    local host, join = pair(hrec, jrec)
    step(host, join, 5.5)
    check(hrec.think_on == false, "(10.18) stale: (set-up) the host's body is a puppet")
    -- the joiner's game goes quiet (no more states, no messages): only the host runs
    for _ = 1, 100 do
        run_frames(host, 0.05)
        bump_remote(host)
    end
    local hh = health(host).enemy_handover
    check(next(hh.run_by_the_joiner) == nil and hrec.think_on == true, "(10.18) stale: with no state for 3 s the host takes the enemy back and its AI is on again")
    local key
    for k in pairs(hh.why_taken_back) do key = k end
    check(key and key:find("no state from the joiner", 1, true), "(10.18) stale: ...and the reason is written down: " .. tostring(key))
end

do -- the margin: a joiner that is only a little nearer does not get the enemy (no flapping between two players standing about equally near)
    local hrec, jrec = { x = 20, z = 0 }, { x = 20, z = 0 }
    local host, join = pair(hrec, jrec)
    stand(host, join, 15, 0, 17, 0) -- the host is 5 m from it, the joiner 3 m: not 3 m nearer
    step(host, join, 4)
    check(health(host).enemy_handover.counts.offered == 0 and hrec.think_on == nil, "(10.18) margin: a joiner only 2 m nearer is not given the enemy")
    stand(host, join, 15, 0, 19, 0) -- now 5 m against 1 m
    step(host, join, 3.5)
    check(health(host).enemy_handover.counts.offered == 1, "(10.18) margin: ...but one that is clearly nearer (4 m) is")
    check(not log_has(host, "script error") and not log_has(join, "script error"), "(10.18) margin: no script error")
end
