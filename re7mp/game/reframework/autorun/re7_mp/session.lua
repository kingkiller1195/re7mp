-- Session state on the Lua side: who is connected, their smoothed poses, chat, shared markers,
-- and the extension point for synchronising world state (doors, items, ...).

local mathx = require("re7_mp/mathx")
local pose = require("re7_mp/pose")
local tracking = require("re7_mp/tracking")

local S = {
    state = "idle",      -- mirrors mp_net.state()
    my_id = nil,         -- host = 0
    my_name = "Player",
    host_name = nil,
    error = nil,         -- last start/connect error, for the UI
    players = {},        -- [id] = { id, name, flags, target, cur, last_rx }   (never includes me)
    chat = {},           -- { who, text, t }
    markers = {},        -- { owner, pos, expires }
    now = 0,
    local_flags = 0,
}

-- Reliable "user event" kinds. 0-15 are reserved for this mod; use 16..255 for your own world-sync
-- messages (door opened, item picked up, enemy killed ...). The payload is an opaque string <= 900
-- bytes - encode it however you like.
S.KIND_MARKER = 1

local handlers = {}
function S.on_user(kind, fn) handlers[kind] = fn end

local pose_arr = {}

-- ------------------------------------------------------------------ helpers
local function add_chat(who, text)
    S.chat[#S.chat + 1] = { who = who, text = text, t = S.now }
    while #S.chat > 50 do table.remove(S.chat, 1) end
end
S.add_chat = add_chat

function S.name_of(id)
    if id == S.my_id then return S.my_name end
    local p = S.players[id]
    return p and p.name or ("Player " .. tostring(id))
end

local function reset()
    S.players, S.chat, S.markers = {}, {}, {}
    S.my_id, S.host_name = nil, nil
end

local function get_player(id)
    local p = S.players[id]
    if not p then
        p = { id = id, name = "Player " .. id, flags = 0, last_rx = 0 }
        S.players[id] = p
    end
    return p
end

-- ------------------------------------------------------------------ start / stop
function S.start_host(cfg)
    reset()
    S.error = nil
    S.my_name = cfg.name
    mp_net.set_vr(tracking.vr_active())
    local ok, err = mp_net.host(cfg.port, cfg.max_players, cfg.name)
    if not ok then S.error = err; return false end
    S.my_id = 0
    add_chat("system", "Hosting on UDP port " .. cfg.port)
    return true
end

function S.start_join(cfg)
    reset()
    S.error = nil
    S.my_name = cfg.name
    mp_net.set_vr(tracking.vr_active())
    local ok, err = mp_net.join(cfg.last_ip, cfg.port, cfg.name)
    if not ok then S.error = err; return false end
    add_chat("system", "Connecting to " .. cfg.last_ip .. ":" .. cfg.port .. " ...")
    return true
end

function S.stop()
    mp_net.stop()
    reset()
    S.state = "idle"
end

-- ------------------------------------------------------------------ outgoing
function S.send_chat(text)
    if text == nil or text == "" then return false end
    if mp_net.send_chat(text) then
        add_chat(S.my_name, text)
        return true
    end
    return false
end

function S.send_user(kind, payload) return mp_net.send_user(kind, payload) end

function S.drop_marker(pos)
    local payload = string.format("%.2f,%.2f,%.2f", pos.x, pos.y, pos.z)
    if mp_net.send_user(S.KIND_MARKER, payload) then
        S.markers[#S.markers + 1] = { owner = S.my_id, pos = pos, expires = S.now + 60 }
    end
end

-- ------------------------------------------------------------------ incoming
S.on_user(S.KIND_MARKER, function(from, payload)
    local x, y, z = payload:match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
    if not x then return end
    S.markers[#S.markers + 1] = {
        owner = from, pos = mathx.v3(tonumber(x), tonumber(y), tonumber(z)), expires = S.now + 60,
    }
    while #S.markers > 32 do table.remove(S.markers, 1) end
end)

local function handle(ev)
    local t = ev.type
    if t == "connected" then
        S.my_id, S.host_name = ev.id, ev.text
        add_chat("system", "Connected to " .. tostring(ev.text) .. " (you are player " .. ev.id .. ")")
    elseif t == "disconnected" then
        add_chat("system", "Disconnected: " .. tostring(ev.text))
        S.players, S.markers, S.my_id = {}, {}, nil
    elseif t == "joined" then
        local p = get_player(ev.id)
        p.name, p.flags = ev.text, ev.flags or 0
        p.target, p.cur = nil, nil
        add_chat("system", p.name .. " joined" .. (pose.has(p.flags, pose.FLAG_VR) and " (VR)" or ""))
    elseif t == "left" then
        local p = S.players[ev.id]
        if p then add_chat("system", p.name .. " left") end
        S.players[ev.id] = nil
    elseif t == "chat" then
        add_chat(S.name_of(ev.id), ev.text)
    elseif t == "user" then
        local fn = handlers[ev.kind]
        if fn then
            local ok, err = pcall(fn, ev.id, ev.text)
            if not ok then log.error("[re7_mp] user handler " .. ev.kind .. ": " .. tostring(err)) end
        end
    elseif t == "pose" then
        local p = get_player(ev.id)
        p.flags = ev.flags
        p.target = pose.unpack(ev.p)
        p.last_rx = S.now
        if not p.cur then
            p.cur = pose.unpack(ev.p)
        elseif mathx.dist(p.cur.head.pos, p.target.head.pos) > 5.0 then
            p.cur = pose.unpack(ev.p)  -- teleport / area change: snap instead of gliding through walls
        end
    end
end

local function smooth(dt, rate)
    local k = 1 - math.exp(-dt * rate)
    for _, p in pairs(S.players) do
        if p.cur and p.target then
            for _, part in ipairs({ "head", "lhand", "rhand" }) do
                local c, tg = p.cur[part], p.target[part]
                c.pos = mathx.lerp(c.pos, tg.pos, k)
                c.rot = mathx.nlerp(c.rot, tg.rot, k)
            end
        end
    end
end

-- ------------------------------------------------------------------ per-frame
function S.update(now, dt, cfg)
    S.now = now
    S.state = mp_net.state()

    for _, ev in ipairs(mp_net.poll()) do handle(ev) end

    if S.state == "hosting" or S.state == "connected" then
        local flags, head = tracking.sample(pose_arr)
        S.head = head  -- local camera/HMD pose in world space (nil while loading)
        if flags then
            S.local_flags = flags
            mp_net.set_pose(flags, pose_arr)  -- the network thread sends it at ~30 Hz
        end
    end

    smooth(dt, cfg.pose_smoothing)

    for i = #S.markers, 1, -1 do
        if S.markers[i].expires < now then table.remove(S.markers, i) end
    end
end

function S.player_count()
    local n = 0
    for _ in pairs(S.players) do n = n + 1 end
    return n
end

return S
