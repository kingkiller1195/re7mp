-- RE7 multiplayer prototype, Lua side (script v4).
-- re7mp.exe installs this to <RE7>/reframework/autorun/re7mp.lua and talks to it through
-- JSON files in reframework/data. Edit the copy in the project (lua/re7mp.lua) and rebuild;
-- the exe overwrites the installed copy.
--
-- What it does:
--   * sends your camera position + rotation to the other player (via re7mp.exe)
--   * draws the other player as a stick-figure skeleton with a name tag, facing where they look
--   * "Start together": a ready check. Both players say they're ready on the same difficulty,
--     and only then does the game go on. When RE7's New Game is detected (app.GameManager.newGameRequest)
--     that request is BLOCKED until the other player is ready too, then replayed on the agreed
--     difficulty. The "I'm ready" / "Join" buttons in the panel do the same with a countdown.
--   * "Avatar (experimental)": scan the scene and try cloning an in-game model instead of the skeleton.
--
-- NOTE: untested in-game apart from the position/figure part (the new-game hooks, ready check,
-- freeze and avatar cloning are all new and unverified). Errors show in the REFramework
-- console and in the "RE7 Multiplayer" panel (Insert key).

local CFG = {
    SEND_INTERVAL = 0.04,     -- seconds between pose updates (25 Hz)
    READ_INTERVAL = 0.03,
    STALE_AFTER = 2.0,        -- seconds without a new packet before the figure turns grey
    EYE_HEIGHT = 1.6,         -- camera height above the feet, in metres (sets the figure's size)
    -- "Forward" in the camera's local space. RE7's camera looks down -Z (the figure was 180 degrees
    -- off with +Z). In loopback mode the bot copies YOUR rotation, so its white look-line should
    -- point the same way you are looking; if it points back at you, flip this to { 0, 0, 1 }.
    FORWARD = { 0, 0, -1 },
    SMOOTHING = 14.0,         -- higher = snappier, lower = smoother
    TELEPORT_DISTANCE = 15.0, -- a jump bigger than this (metres) snaps instead of gliding
    DEFAULT_NAME = "Player 2",
    READY_TIMEOUT = 120,      -- give up waiting for the other player after this many seconds
    GO_LATCH = 5,             -- keep saying "going" this long so the other side can't miss it
    COUNTDOWN = 3,            -- seconds of countdown after both are ready (manual mode)
    HOLD_SPEED = 0.001,       -- game speed while frozen (near zero rather than exactly zero)
    MODEL_YAW_OFFSET = 0,     -- radians; turn a cloned model if it faces the wrong way (3.14159 = turn around)
}

local OUT_FILE = "re7mp_out.json"
local IN_FILE = "re7mp_in.json"
local DIFFICULTY = { [0] = "Easy", [1] = "Normal", [2] = "Madhouse" }

-- Flag bits carried in every position packet (must match src/packet.hpp).
local FLAG_READY = 1   -- bits 1-2 hold the difficulty (0..2) times 2
local FLAG_SEES = 8    -- "I can see that you are ready"
local FLAG_GO = 16     -- "both ready, I'm going"
local FLAG_NOPOSE = 32 -- this packet's position is not valid (no camera yet)

local state = {
    seq = 0,
    last_send = 0,
    last_read = 0,
    last_frame = os.clock(),
    local_pos = nil,
    remote = nil,            -- latest valid pose: { pos = {x,y,z}, quat = {x,y,z,w} }
    remote_seq = nil,
    remote_changed_at = 0,   -- last time ANY packet from them arrived (liveness)
    remote_count = 0,
    remote_name = nil,
    remote_flags = 0,
    prev_target = nil,
    prev_target_time = 0,
    render_pos = nil,        -- smoothed position actually drawn
    render_fwd = nil,        -- smoothed look direction { x, y, z }
    speed = 0,               -- smoothed horizontal speed in m/s
    walk_phase = 0,
    show_figure = true,
    last_error = nil,
}

local lobby = {
    phase = "idle",          -- idle | waiting | go | done
    difficulty = 1,
    hold_kind = nil,         -- nil | "block" (New Game request blocked) | "freeze" (game speed frozen)
    need_clear = false,      -- ignore the other player's ready state until they have cleared it once
    join_diff = nil,         -- difficulty the other player is ready on, while we are idle
    started_at = 0,
    go_at = 0,
    latch_until = 0,
    message = "Not ready.",
    message_until = 0,
    mismatch_diff = nil,     -- the other player's difficulty when it differs from ours
    freeze_instead = false,  -- freeze the game instead of blocking the New Game request
    auto_join = false,       -- start our own new game as soon as the other player is ready
    auto_start = true,       -- in manual mode, call newGameRequest ourselves after the countdown
    suppress_until = 0,
    hook_installed = false,
}

local held = { active = false, prev_speed = 1.0 }

local avatar = {
    obj = nil,               -- cloned GameObject, if any
    xf = nil,                -- its Transform
    error = nil,
    filter = "player",       -- scanner filter text
    source_name = "",        -- name of the GameObject to clone
    lines = {},              -- scanner output
    show_skeleton = false,   -- draw the skeleton even while a clone is active
}

local probe = {
    lines = {},
    type_name = "app.ItemManager",
}

local function say(msg)
    local text = "[re7mp] " .. tostring(msg)
    if log and log.info then
        pcall(log.info, text)
    else
        print(text)
    end
end

----------------------------------------------------------------------------------------------
-- RE7 adapter: the game-specific code. Filled in from the probe of app.GameManager:
--   get_gameDifficulty / set_gameDifficulty   read and set the difficulty
--   newGameRequest                            runs when a new game is requested (our trigger)
--   newGameInitParam, newGameRequest_Chapter7, setGamemode, SaveDataManager.newGameInit
--                                             only logged ("trace") for now; their arguments are unknown
-- Difficulty ids on the wire: 0 = Easy, 1 = Normal, 2 = Madhouse. The game's enum values are
-- read from the game at runtime (see build_difficulty_map) instead of being assumed.
----------------------------------------------------------------------------------------------
local RE7 = {
    captured_gm = nil,       -- app.GameManager instance seen by a hook (fallback if the singleton lookup fails)
    trace_on = true,
    trace_lines = {},
    replaying = false,       -- true while WE call newGameRequest, so our hook lets it through
    can_block = false,       -- can a pre-hook skip the original call? (set below)
    last_set_wire = nil,     -- last difficulty the game was set to, as 0/1/2
    map_built = false,
    to_game = {},            -- wire id -> the game's difficulty value
    from_game = {},          -- the game's difficulty value -> wire id
}

local function trace(text)
    if not RE7.trace_on then return end
    RE7.trace_lines[#RE7.trace_lines + 1] = string.format("%.1f  %s", os.clock(), text)
    if #RE7.trace_lines > 60 then table.remove(RE7.trace_lines, 1) end
    say("[trace] " .. text)
end

local function game_manager()
    local ok, gm = pcall(sdk.get_managed_singleton, "app.GameManager")
    if ok and gm then return gm end
    return RE7.captured_gm
end

-- Finds the game's difficulty enum (the return type of get_gameDifficulty) and maps its member
-- names (Easy/Assist..., Normal..., Madhouse...) onto 0/1/2. Falls back to 0/1/2 as-is.
-- The mapping it found is written to the console so it can be checked.
local function build_difficulty_map()
    if RE7.map_built then return end
    RE7.map_built = true
    for i = 0, 2 do
        RE7.to_game[i] = i
        RE7.from_game[i] = i
    end
    local ok, err = pcall(function()
        local td = sdk.find_type_definition("app.GameManager")
        local m = td and td:get_method("get_gameDifficulty")
        local rt = (m and m:get_return_type()) or sdk.find_type_definition("app.GameManager.Difficulty")
        if not rt then return end
        say("difficulty type: " .. tostring(rt:get_full_name()))
        local found = {}
        for _, f in ipairs(rt:get_fields()) do
            if f:is_static() then
                local value = f:get_data(nil)
                if type(value) == "number" then
                    local low = f:get_name():lower()
                    local wire
                    if low:find("assist") or low:find("easy") or low:find("casual") then wire = 0
                    elseif low:find("normal") or low:find("standard") then wire = 1
                    elseif low:find("mad") or low:find("hard") then wire = 2 end
                    say("  " .. f:get_name() .. " = " .. tostring(value)
                        .. (wire and (" -> " .. DIFFICULTY[wire]) or " (not mapped)"))
                    if wire ~= nil then found[wire] = value end
                end
            end
        end
        for wire, value in pairs(found) do
            RE7.to_game[wire] = value
            RE7.from_game[value] = wire
        end
    end)
    if not ok then say("could not read the difficulty enum, assuming 0/1/2: " .. tostring(err)) end
end

-- The difficulty currently selected in the game as 0/1/2, or nil if it can't be read.
function RE7.current_difficulty()
    build_difficulty_map()
    local gm = game_manager()
    if not gm then return nil end
    local ok, v = pcall(function() return gm:call("get_gameDifficulty") end)
    if ok and type(v) == "number" then
        local wire = RE7.from_game[v]
        if wire ~= nil then return wire end
        if v >= 0 and v <= 2 then return v end
    end
    return nil
end

local function wire_from_game(v)
    if type(v) ~= "number" then return nil end
    local wire = RE7.from_game[v]
    if wire ~= nil then return wire end
    if v >= 0 and v <= 2 then return v end
    return nil
end

local function log_enum(type_name)
    pcall(function()
        local td = sdk.find_type_definition(type_name)
        if not td then
            say(type_name .. ": type not found")
            return
        end
        local parts = {}
        for _, f in ipairs(td:get_fields()) do
            if f:is_static() then
                local value = f:get_data(nil)
                if type(value) == "number" then parts[#parts + 1] = f:get_name() .. "=" .. tostring(value) end
            end
        end
        say(type_name .. ": " .. table.concat(parts, ", "))
    end)
end

do
    local okp, skip_const = pcall(function() return sdk.PreHookResult.SKIP_ORIGINAL end)
    RE7.can_block = okp and skip_const ~= nil
end

-- Sets the game's difficulty. Returns true, or false plus a message.
function RE7.apply_difficulty(difficulty_id)
    build_difficulty_map()
    local gm = game_manager()
    if not gm then return false, "app.GameManager not found" end
    local value = RE7.to_game[difficulty_id] or difficulty_id
    local ok, err = pcall(function() gm:call("set_gameDifficulty", value) end)
    if not ok then return false, tostring(err) end
    return true
end

-- Starts a new game on the given difficulty: sets the difficulty, then calls newGameRequest() (it takes no
-- arguments, per the signature probe). Returns true, or false plus a message.
function RE7.start_new_game(difficulty_id)
    local ok, err = RE7.apply_difficulty(difficulty_id)
    if not ok then return false, err end
    local gm = game_manager()
    if not gm then return false, "app.GameManager not found" end
    RE7.replaying = true -- our own hook must let this call through
    local okc, errc = pcall(function() gm:call("newGameRequest") end)
    RE7.replaying = false
    if not okc then return false, tostring(errc) end
    return true
end

-- Hooks the new-game request. on_new_game(difficulty_id) is called when the player starts a new game; if it
-- returns true the original request is SKIPPED (blocked) and is replayed later by RE7.start_new_game.
-- The other new-game methods are only logged (Start together > "Log new-game calls").
function RE7.install_new_game_hook(on_new_game)
    build_difficulty_map()
    log_enum("app.GameManager.Difficulty")
    log_enum("app.GameManager.GameMode")
    local pre_result = sdk.PreHookResult
    local CALL_ORIGINAL = pre_result and pre_result.CALL_ORIGINAL
    local SKIP_ORIGINAL = pre_result and pre_result.SKIP_ORIGINAL
    local installed = 0

    -- handler(args) may return true to skip the original call (only honoured if the game supports it).
    local function hook(type_name, method_name, handler)
        local td = sdk.find_type_definition(type_name)
        local m = td and td:get_method(method_name)
        if not m then
            say("hook: " .. type_name .. "." .. method_name .. " not found")
            return
        end
        sdk.hook(m, function(args)
            local ok, skip = pcall(handler, args)
            if not ok then
                say("hook error in " .. method_name .. ": " .. tostring(skip))
                return CALL_ORIGINAL
            end
            if skip == true and SKIP_ORIGINAL ~= nil then return SKIP_ORIGINAL end
            return CALL_ORIGINAL
        end, function(retval) return retval end)
        installed = installed + 1
    end

    local function remember_this(args)
        local ok, obj = pcall(sdk.to_managed_object, args[2])
        if ok and obj then RE7.captured_gm = obj end
    end
    local function raw(args, i)
        local ok, v = pcall(sdk.to_int64, args[i])
        return ok and string.format("0x%x", v or 0) or "?"
    end
    local function raw_bool(args, i)
        local ok, v = pcall(sdk.to_int64, args[i])
        return ok and tostring((v or 0) % 256) or "?"
    end

    hook("app.GameManager", "set_gameDifficulty", function(args)
        remember_this(args)
        local ok, v = pcall(sdk.to_int64, args[3])
        if ok and v then RE7.last_set_wire = wire_from_game(v % 4294967296) end
        trace("set_gameDifficulty(" .. raw(args, 3) .. ")")
    end)
    hook("app.GameManager", "newGameRequest", function(args)
        remember_this(args)
        if RE7.replaying then
            trace("newGameRequest() [replayed by us]")
            return false
        end
        trace("newGameRequest()")
        return on_new_game(RE7.current_difficulty() or RE7.last_set_wire) == true
    end)
    hook("app.GameManager", "newGameRequest_Chapter7", function(args)
        trace("newGameRequest_Chapter7()")
    end)
    hook("app.GameManager", "newGameInitParam", function(args)
        trace("newGameInitParam(" .. raw_bool(args, 3) .. ")")
    end)
    hook("app.GameManager", "setGamemode", function(args)
        trace("setGamemode(" .. raw(args, 3) .. ")")
    end)
    hook("app.SaveDataManager", "newGameInit", function(args)
        trace("SaveDataManager.newGameInit()")
    end)
    return installed > 0
end

----------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------
local function has(flags, bit) -- is this power-of-two bit set?
    return math.floor(flags / bit) % 2 == 1
end

local function flags_diff(flags)
    return math.floor(flags / 2) % 4
end

local function normalize3(x, y, z)
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-6 then return 0, 0, 1 end
    return x / l, y / l, z / l
end

-- Rotates vector v = {x, y, z} by unit quaternion q = {x, y, z, w}.
local function rotate(q, v)
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    local tx = 2 * (qy * v[3] - qz * v[2])
    local ty = 2 * (qz * v[1] - qx * v[3])
    local tz = 2 * (qx * v[2] - qy * v[1])
    return {
        v[1] + qw * tx + (qy * tz - qz * ty),
        v[2] + qw * ty + (qz * tx - qx * tz),
        v[3] + qw * tz + (qx * ty - qy * tx),
    }
end

local function forward_of(q)
    local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    local u = { x = 0, y = 0, z = 0, w = 1 }
    if l > 1e-6 then u = { x = q.x / l, y = q.y / l, z = q.z / l, w = q.w / l } end
    local f = rotate(u, CFG.FORWARD)
    return normalize3(f[1], f[2], f[3])
end

-- The other player's flags, or 0 if we haven't heard from them lately.
local function remote_flags_now(now)
    if now - state.remote_changed_at > CFG.STALE_AFTER then return 0 end
    return state.remote_flags or 0
end

----------------------------------------------------------------------------------------------
-- Holding the game while we wait (global game speed, same mechanism as REFramework's timescale)
----------------------------------------------------------------------------------------------
local function hold_game()
    if held.active then return end
    local ok, err = pcall(function()
        local app = sdk.get_native_singleton("via.Application")
        local td = sdk.find_type_definition("via.Application")
        local cur = sdk.call_native_func(app, td, "get_GlobalSpeed")
        held.prev_speed = (type(cur) == "number" and cur > 0.05) and cur or 1.0
        sdk.call_native_func(app, td, "set_GlobalSpeed", CFG.HOLD_SPEED)
    end)
    if ok then
        held.active = true
    else
        lobby.hold_kind = nil
        say("could not freeze the game: " .. tostring(err))
    end
end

local function release_game()
    if not held.active then return end
    held.active = false
    local ok, err = pcall(function()
        local app = sdk.get_native_singleton("via.Application")
        local td = sdk.find_type_definition("via.Application")
        sdk.call_native_func(app, td, "set_GlobalSpeed", held.prev_speed)
    end)
    if not ok then say("could not unfreeze the game: " .. tostring(err)) end
end

----------------------------------------------------------------------------------------------
-- Ready check ("Start together")
----------------------------------------------------------------------------------------------
local function set_message(text, seconds)
    lobby.message = text
    lobby.message_until = os.clock() + (seconds or 8)
    say(text)
end

-- from_hook = true when the game itself asked for a new game (so we may block or freeze it).
local function start_ready(difficulty, from_hook)
    if lobby.phase ~= "idle" then return end
    local now = os.clock()
    lobby.phase = "waiting"
    lobby.difficulty = difficulty
    lobby.started_at = now
    lobby.mismatch_diff = nil
    lobby.hold_kind = nil
    if from_hook then
        if lobby.freeze_instead or not RE7.can_block then
            lobby.hold_kind = "freeze"
            hold_game() -- clears hold_kind again if the freeze fails
        else
            lobby.hold_kind = "block"
        end
    end
    set_message("Ready on " .. (DIFFICULTY[difficulty] or "?") .. ". Waiting for the other player...", 60)
end

local function cancel_ready(text)
    local was_blocking = lobby.hold_kind == "block"
    release_game()
    lobby.hold_kind = nil
    lobby.phase = "idle"
    lobby.latch_until = 0
    lobby.mismatch_diff = nil
    lobby.need_clear = true
    set_message(text or (was_blocking and "Cancelled. Press New Game again when you're ready." or "Cancelled."), 6)
end

-- Called by the RE7 adapter's hook when the game receives a new-game request. Returns true to make
-- the hook BLOCK that request until both players are ready.
local function on_local_new_game(difficulty_id)
    local now = os.clock()
    if now < lobby.suppress_until then return false end -- we started it ourselves
    if lobby.phase == "idle" and now - state.remote_changed_at > CFG.STALE_AFTER then
        say("New game started with nobody connected: not waiting for anyone.")
        return false
    end
    start_ready(difficulty_id or lobby.difficulty, true)
    -- Already waiting from the panel's "I'm ready" and the game now asks for a new game: block it too.
    if lobby.phase == "waiting" and lobby.hold_kind == nil and RE7.can_block and not lobby.freeze_instead then
        lobby.hold_kind = "block"
    end
    return lobby.hold_kind == "block"
end

-- The flags we send with every position packet.
local function local_flags(now)
    local f = 0
    local active = lobby.phase == "waiting" or lobby.phase == "go"
        or (lobby.phase == "done" and now < lobby.latch_until)
    if active then f = f + FLAG_READY + lobby.difficulty * 2 end
    if has(remote_flags_now(now), FLAG_READY) then f = f + FLAG_SEES end
    if lobby.phase == "go" or (lobby.phase == "done" and now < lobby.latch_until) then f = f + FLAG_GO end
    return f
end

local function update_lobby(now)
    local rf = remote_flags_now(now)
    local who = state.remote_name or CFG.DEFAULT_NAME
    local diff_name = DIFFICULTY[lobby.difficulty] or "?"

    if lobby.phase == "idle" then
        -- Don't react to a ready state left over from a game that just started or that we cancelled.
        if lobby.need_clear then
            if not has(rf, FLAG_READY) then lobby.need_clear = false end
            lobby.join_diff = nil
            return
        end
        if has(rf, FLAG_READY) then
            lobby.join_diff = flags_diff(rf)
            if lobby.auto_join then
                start_ready(lobby.join_diff, false)
            else
                lobby.message = string.format("%s is ready to start a new game on %s. Press New Game, or click Join in the Insert menu.",
                    who, DIFFICULTY[lobby.join_diff] or "?")
                lobby.message_until = now + 1
            end
        else
            lobby.join_diff = nil
        end

    elseif lobby.phase == "waiting" then
        if now - lobby.started_at > CFG.READY_TIMEOUT then
            cancel_ready("Timed out waiting for " .. who .. ".")
            return
        end
        if has(rf, FLAG_READY) then
            local theirs = flags_diff(rf)
            if theirs ~= lobby.difficulty then
                lobby.mismatch_diff = theirs
                lobby.message = string.format("%s picked %s but you picked %s. They must match.",
                    who, DIFFICULTY[theirs] or "?", diff_name)
            else
                lobby.mismatch_diff = nil
                if has(rf, FLAG_SEES) or has(rf, FLAG_GO) then
                    lobby.phase = "go"
                    lobby.go_at = now
                    lobby.latch_until = now + CFG.GO_LATCH
                else
                    lobby.message = "Both ready, confirming with " .. who .. "..."
                end
            end
        else
            lobby.mismatch_diff = nil
            lobby.message = "Ready on " .. diff_name .. ". Waiting for " .. who .. "..."
        end

    elseif lobby.phase == "go" then
        -- Everyone counts down together so the starts line up, whatever started the ready check.
        local left = CFG.COUNTDOWN - (now - lobby.go_at)
        if left > 0 then
            lobby.message = string.format("Both ready! Starting in %d...", math.ceil(left))
        else
            local kind = lobby.hold_kind
            lobby.hold_kind = nil
            lobby.phase = "done"
            lobby.need_clear = true
            lobby.suppress_until = now + 20 -- don't treat our own start as a new request

            if kind == "freeze" then
                release_game() -- the game's own request was never blocked: just let it carry on
                set_message("Both ready: continuing on " .. diff_name .. ".", 6)

            elseif kind == "block" then
                -- Replay the New Game request we blocked, on the agreed difficulty.
                local ok, res, err = pcall(RE7.start_new_game, lobby.difficulty)
                if ok and res == true then
                    set_message("Both ready: starting the new game on " .. diff_name .. ".", 8)
                else
                    set_message("Both ready on " .. diff_name .. ", but the new game could not be started ("
                        .. tostring(ok and err or res) .. "). Press New Game again.", 12)
                end

            elseif lobby.auto_start then -- started from the panel
                local ok, res, err = pcall(RE7.start_new_game, lobby.difficulty)
                if ok and res == true then
                    set_message("New game requested on " .. diff_name .. ". If nothing happens, press New Game.", 10)
                else
                    set_message("GO! Press New Game now (" .. diff_name .. "). " .. tostring(ok and err or res), 10)
                end

            else
                pcall(RE7.apply_difficulty, lobby.difficulty)
                set_message("GO! Difficulty set to " .. diff_name .. ". Press New Game now.", 10)
            end
        end

    elseif lobby.phase == "done" then
        if now >= lobby.latch_until then
            lobby.phase = "idle"
            lobby.need_clear = true
        end
    end
end

----------------------------------------------------------------------------------------------
-- Local player -> engine
----------------------------------------------------------------------------------------------
-- The camera is the player's eyes in first-person RE7, so it stands in for the player.
local function get_local_pose()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local go = cam:call("get_GameObject")
    if not go then return nil end
    local xf = go:call("get_Transform")
    if not xf then return nil end
    local p = xf:call("get_Position")
    if not p then return nil end
    local q = xf:call("get_Rotation")
    local quat = { x = 0, y = 0, z = 0, w = 1 }
    if q then quat = { x = q.x, y = q.y, z = q.z, w = q.w } end
    return { x = p.x, y = p.y, z = p.z }, quat
end

local function send_local(now)
    state.last_send = now
    local ok, pos, quat = pcall(get_local_pose)
    if not ok then
        state.last_error = tostring(pos)
        pos = nil
    end
    local flags = local_flags(now)
    if pos then
        state.local_pos = pos
    else
        -- No camera yet (menus, loading): still send the ready-check flags, but mark the pose invalid.
        flags = flags + FLAG_NOPOSE
        pos = state.local_pos or { x = 0, y = 0, z = 0 }
        quat = { x = 0, y = 0, z = 0, w = 1 }
    end
    state.seq = state.seq + 1
    json.dump_file(OUT_FILE, {
        seq = state.seq,
        x = pos.x, y = pos.y, z = pos.z,
        qx = quat.x, qy = quat.y, qz = quat.z, qw = quat.w,
        flags = flags,
    })
end

----------------------------------------------------------------------------------------------
-- Engine -> remote player state
----------------------------------------------------------------------------------------------
local function read_remote(now)
    state.last_read = now
    local data = json.load_file(IN_FILE)
    if type(data) ~= "table" or data.seq == nil or data.x == nil then return end
    if type(data.name) == "string" and data.name ~= "" then state.remote_name = data.name end
    state.remote_count = data.recv_count or state.remote_count
    state.remote_flags = tonumber(data.flags) or 0
    if data.seq == state.remote_seq then return end
    state.remote_seq = data.seq
    state.remote_changed_at = now
    if has(state.remote_flags, FLAG_NOPOSE) then return end -- they have no camera yet

    local target = { x = data.x, y = data.y, z = data.z }
    local quat = { x = data.qx or 0, y = data.qy or 0, z = data.qz or 0, w = data.qw or 1 }

    if state.prev_target then
        local dt = now - state.prev_target_time
        local dx, dz = target.x - state.prev_target.x, target.z - state.prev_target.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist > CFG.TELEPORT_DISTANCE then
            state.render_pos = nil -- snap instead of gliding across the map
            state.speed = 0
        elseif dt > 0.001 then
            state.speed = state.speed + (dist / dt - state.speed) * 0.3
        end
    end
    state.prev_target = target
    state.prev_target_time = now
    state.remote = { pos = target, quat = quat }
end

-- Smooths the 25 Hz network updates into per-frame motion and advances the walk cycle.
local function update_remote(now, dt)
    local r = state.remote
    if not r then return end
    local fx, fy, fz = forward_of(r.quat)
    if not state.render_pos then
        state.render_pos = { x = r.pos.x, y = r.pos.y, z = r.pos.z }
        state.render_fwd = { fx, fy, fz }
    else
        local a = 1 - math.exp(-CFG.SMOOTHING * dt)
        local p = state.render_pos
        p.x = p.x + (r.pos.x - p.x) * a
        p.y = p.y + (r.pos.y - p.y) * a
        p.z = p.z + (r.pos.z - p.z) * a
        local f = state.render_fwd
        local nx, ny, nz = normalize3(f[1] + (fx - f[1]) * a, f[2] + (fy - f[2]) * a, f[3] + (fz - f[3]) * a)
        state.render_fwd = { nx, ny, nz }
    end
    if now - state.remote_changed_at > 0.3 then
        state.speed = state.speed * math.exp(-5 * dt) -- no fresh data: wind the walk down
    end
    state.walk_phase = state.walk_phase + state.speed * dt * 4.2 -- ~1.5 m per full gait cycle
end

----------------------------------------------------------------------------------------------
-- Drawing: a procedural stick-figure skeleton (placeholder until a real model is spawned)
----------------------------------------------------------------------------------------------
local function project(p)
    return draw.world_to_screen(Vector3f.new(p[1], p[2], p[3]))
end

local function bone(a, b, color)
    local sa, sb = project(a), project(b)
    if sa and sb then draw.line(sa.x, sa.y, sb.x, sb.y, color) end
end

local function draw_figure(pos, fwd, amp, phase, label, color)
    -- Body orientation = look direction flattened onto the ground plane.
    local hx, hz = fwd[1], fwd[3]
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl < 1e-3 then hx, hz = 0, 1 else hx, hz = hx / hl, hz / hl end
    local rx, rz = hz, -hx -- "right" on the ground plane

    local H = CFG.EYE_HEIGHT
    local ox, oy, oz = pos.x, pos.y - H, pos.z -- point on the floor below the camera
    local function J(r, u, f) -- right / up / forward offsets from the feet -> world point
        return { ox + rx * r + hx * f, oy + u, oz + rz * r + hz * f }
    end

    local head = { pos.x, pos.y, pos.z }
    local neck = J(0, H - 0.18, 0)
    local pelvis = J(0, H * 0.56, 0)
    local shL, shR = J(0.2, H - 0.28, 0), J(-0.2, H - 0.28, 0)
    local hipL, hipR = J(0.1, H * 0.56, 0), J(-0.1, H * 0.56, 0)

    bone(neck, head, color)
    bone(neck, pelvis, color)
    bone(shL, shR, color)
    bone(hipL, hipR, color)

    for _, k in ipairs({ 1, -1 }) do
        local ph = phase + (k > 0 and 0 or math.pi) -- legs and arms swing in opposition
        local stride = amp * 0.32 * math.sin(ph)
        local lift = amp * 0.14 * math.max(0, math.cos(ph))
        local sh = k > 0 and shL or shR
        local hip = k > 0 and hipL or hipR
        local knee = J(k * 0.1, H * 0.28 + lift * 0.5, stride * 0.6 + amp * 0.05)
        local foot = J(k * 0.1, lift, stride)
        local elbow = J(k * 0.23, H * 0.72, -stride * 0.5)
        local hand = J(k * 0.23, H * 0.55, -stride)
        bone(sh, elbow, color)
        bone(elbow, hand, color)
        bone(hip, knee, color)
        bone(knee, foot, color)
    end

    -- Head: a small diamond around the camera position.
    local r = 0.11
    local top, bottom = { pos.x, pos.y + r, pos.z }, { pos.x, pos.y - r, pos.z }
    local left, right = J(-r, H, 0), J(r, H, 0)
    bone(top, left, color)
    bone(left, bottom, color)
    bone(bottom, right, color)
    bone(right, top, color)

    -- Look direction (includes up/down tilt), so you can see where they are aiming.
    local look = { pos.x + fwd[1] * 0.45, pos.y + fwd[2] * 0.45, pos.z + fwd[3] * 0.45 }
    bone(head, look, 0xFFFFFFFF)

    local tag = project({ pos.x, pos.y + 0.32, pos.z })
    if tag then draw.text(label, tag.x - #label * 3.5, tag.y - 14, color) end
end

local function draw_remote(now)
    if not state.show_figure or not state.remote or not state.render_pos then return end
    if avatar.obj and not avatar.show_skeleton then return end -- a cloned model is standing in
    local stale = (now - state.remote_changed_at) > CFG.STALE_AFTER
    local color = stale and 0xFF888888 or 0xFF00FF00
    local label = state.remote_name or CFG.DEFAULT_NAME
    if stale then label = label .. " (no signal)" end
    local amp = math.max(0, math.min(1, (state.speed - 0.15) / 1.8))
    draw_figure(state.render_pos, state.render_fwd, amp, state.walk_phase, label, color)
end

----------------------------------------------------------------------------------------------
-- Probe: lists a type's methods (with signatures) so the adapter can be extended
----------------------------------------------------------------------------------------------
local PROBE_CANDIDATES = {
    "app.GameManager", "app.SaveDataManager", "app.ItemManager",
    "app.EnemyManager", "app.EventManager", "app.MapManager", "app.GimmickManager", "app.InventoryManager",
}
local PROBE_KEYWORDS = { "difficult", "newgame", "new_game", "gamemode", "rank", "startgame", "gamestart" }
local NEW_GAME_METHODS = {
    { "app.GameManager", "newGameRequest" }, { "app.GameManager", "newGameInitParam" },
    { "app.GameManager", "newGameRequest_Chapter7" }, { "app.GameManager", "setGamemode" },
    { "app.GameManager", "set_gameDifficulty" }, { "app.GameManager", "get_gameDifficulty" },
    { "app.SaveDataManager", "newGameInit" },
}

local function probe_add(text)
    probe.lines[#probe.lines + 1] = text
    say(text)
end

local function method_signature(m)
    local ok, text = pcall(function()
        local params = {}
        for i, t in ipairs(m:get_param_types() or {}) do params[i] = t:get_full_name() end
        local ret = m:get_return_type()
        return "(" .. table.concat(params, ", ") .. ") -> " .. (ret and ret:get_full_name() or "?")
    end)
    return ok and text or ""
end

local function probe_type(name, list_all, keywords)
    keywords = keywords or PROBE_KEYWORDS
    local ok, err = pcall(function()
        local td = sdk.find_type_definition(name)
        if not td then
            probe_add(name .. ": not found")
            return
        end
        probe_add(name .. ": found")
        local shown = 0
        for _, m in ipairs(td:get_methods() or {}) do
            local mname = m:get_name()
            local match = list_all
            if not match then
                local low = mname:lower()
                for _, kw in ipairs(keywords) do
                    if low:find(kw, 1, true) then
                        match = true
                        break
                    end
                end
            end
            if match and shown < 80 then
                shown = shown + 1
                probe_add("    " .. mname .. method_signature(m))
            end
        end
        if shown == 0 then probe_add("    (no methods matched)") end
    end)
    if not ok then probe_add(name .. ": error " .. tostring(err)) end
end

local function probe_signatures()
    for _, entry in ipairs(NEW_GAME_METHODS) do
        local ok, err = pcall(function()
            local td = sdk.find_type_definition(entry[1])
            local m = td and td:get_method(entry[2])
            probe_add(entry[1] .. "." .. entry[2] .. (m and method_signature(m) or ": not found"))
        end)
        if not ok then probe_add(entry[2] .. ": error " .. tostring(err)) end
    end
end

----------------------------------------------------------------------------------------------
-- Avatar: clone an in-game model instead of drawing the skeleton (EXPERIMENTAL, unverified).
-- RE7 is first person, so a full-body Ethan may not even be loaded. The scanner shows what is.
----------------------------------------------------------------------------------------------
local function scene_object()
    return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

-- Walks every GameObject in the current scene. visit(go, path) may return true to stop early.
local function each_gameobject(visit, max_nodes)
    local scene = scene_object()
    if not scene then return end
    local count = 0
    local function walk(xf, path, depth)
        while xf and count < max_nodes do
            count = count + 1
            local go = xf:call("get_GameObject")
            local okn, name = pcall(function() return go and go:call("get_Name") end)
            local p = path .. "/" .. tostring(okn and name or "?")
            if go and visit(go, p) then return true end
            if depth < 8 then
                local child = xf:call("get_Child")
                if child and walk(child, p, depth + 1) then return true end
            end
            xf = xf:call("get_Next")
        end
        return false
    end
    walk(scene:call("get_FirstTransform"), "", 0)
end

local function component_names(go)
    local names = {}
    local comps = go:call("get_Components")
    if comps then
        for _, c in ipairs(comps:get_elements()) do
            local td = c:get_type_definition()
            names[#names + 1] = td and td:get_full_name():gsub("^via%.", "") or "?"
        end
    end
    return names
end

local function scan_scene(filter)
    avatar.lines = {}
    local f = filter:lower()
    local shown = 0
    local ok, err = pcall(each_gameobject, function(go, path)
        if shown < 60 and (f == "" or path:lower():find(f, 1, true)) then
            local okc, comps = pcall(component_names, go)
            shown = shown + 1
            local line = path .. "  [" .. (okc and table.concat(comps, ", ") or "?") .. "]"
            avatar.lines[#avatar.lines + 1] = line
            say(line)
        end
    end, 8000)
    if not ok then avatar.lines[#avatar.lines + 1] = "scan error: " .. tostring(err) end
    if shown == 0 then avatar.lines[#avatar.lines + 1] = "(nothing matched \"" .. filter .. "\")" end
end

local function remove_clone()
    if avatar.obj then
        pcall(function() avatar.obj:call("destroy", avatar.obj) end)
    end
    avatar.obj, avatar.xf = nil, nil
end

local function spawn_clone(name)
    remove_clone()
    avatar.error = nil
    local ok, err = pcall(function()
        local src
        each_gameobject(function(go)
            local okn, n = pcall(function() return go:call("get_Name") end)
            if okn and n == name then
                src = go
                return true
            end
        end, 20000)
        if not src then error("no GameObject named \"" .. name .. "\" in the current scene") end
        local clone = src:call("clone")
        if not clone then error("clone() returned nothing") end
        avatar.obj = clone
        avatar.xf = clone:call("get_Transform")
        say("cloned " .. name)
    end)
    if not ok then
        avatar.error = tostring(err)
        say("clone failed: " .. avatar.error)
    end
end

-- Puts the clone where the other player is, facing the way they look.
local function update_avatar()
    if not avatar.xf then return end
    local pos, fwd = state.render_pos, state.render_fwd
    if not pos or not fwd or not state.remote then return end
    local ok, err = pcall(function()
        local yaw = math.atan(fwd[1], fwd[3]) + CFG.MODEL_YAW_OFFSET
        avatar.xf:call("set_Position", Vector3f.new(pos.x, pos.y - CFG.EYE_HEIGHT, pos.z))
        avatar.xf:call("set_EulerAngle", Vector3f.new(0, yaw, 0))
    end)
    if not ok then
        avatar.error = tostring(err)
        say("avatar update failed, removing the clone: " .. avatar.error)
        remove_clone()
    end
end

----------------------------------------------------------------------------------------------
-- Main loop and UI
----------------------------------------------------------------------------------------------
local ok_hook, installed = pcall(RE7.install_new_game_hook, on_local_new_game)
lobby.hook_installed = ok_hook and installed == true

-- Never leave the game frozen if the scripts are reloaded while we're holding it.
if re.on_script_reset then re.on_script_reset(function() release_game() remove_clone() end) end

re.on_frame(function()
    local now = os.clock()
    local dt = math.min(now - state.last_frame, 0.1)
    state.last_frame = now

    if now - state.last_send >= CFG.SEND_INTERVAL then send_local(now) end
    if now - state.last_read >= CFG.READ_INTERVAL then read_remote(now) end
    update_remote(now, dt)
    update_lobby(now)
    update_avatar()

    local ok, err = pcall(draw_remote, now)
    if not ok then state.last_error = tostring(err) end

    if lobby.phase ~= "idle" or now < lobby.message_until then
        pcall(draw.text, lobby.message, 24, 24, 0xFF00FFFF)
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("RE7 Multiplayer") then return end

    local changed, v = imgui.checkbox("Show other player", state.show_figure)
    if changed then state.show_figure = v end

    local lp, r = state.local_pos, state.remote
    imgui.text(lp and string.format("You:    %.2f, %.2f, %.2f", lp.x, lp.y, lp.z) or "You:    (no camera yet)")
    if r then
        imgui.text(string.format("%s: %.2f, %.2f, %.2f   (%.1f m/s)",
            state.remote_name or CFG.DEFAULT_NAME, r.pos.x, r.pos.y, r.pos.z, state.speed))
    else
        imgui.text("Other player: (nothing received)")
    end
    imgui.text(string.format("Sent: %d   Received: %d", state.seq, state.remote_count))
    if state.last_error then imgui.text("Last error: " .. state.last_error) end

    if imgui.tree_node("Start together") then
        local ok, err = pcall(function()
            imgui.text(lobby.message)
            if lobby.phase == "idle" then
                if lobby.join_diff ~= nil and not lobby.need_clear then
                    local who = state.remote_name or CFG.DEFAULT_NAME
                    if imgui.button("Join " .. who .. " (" .. (DIFFICULTY[lobby.join_diff] or "?") .. ")") then
                        start_ready(lobby.join_diff, false)
                    end
                end
                local c, idx = imgui.combo("Difficulty", lobby.difficulty + 1, { "Easy", "Normal", "Madhouse" })
                if c then lobby.difficulty = idx - 1 end
                if imgui.button("I'm ready") then start_ready(lobby.difficulty, false) end
            else
                if imgui.button("Cancel") then cancel_ready("Cancelled.") end
                if lobby.mismatch_diff and lobby.phase == "waiting" then
                    if imgui.button("Use their difficulty (" .. (DIFFICULTY[lobby.mismatch_diff] or "?") .. ")") then
                        lobby.difficulty = lobby.mismatch_diff
                    end
                end
            end
            local c1, v1 = imgui.checkbox("Auto-join when the other player starts a new game", lobby.auto_join)
            if c1 then lobby.auto_join = v1 end
            local c4, v4 = imgui.checkbox("After the countdown, start the new game for me", lobby.auto_start)
            if c4 then lobby.auto_start = v4 end
            local c2, v2 = imgui.checkbox("Freeze the game instead of blocking the New Game request", lobby.freeze_instead)
            if c2 then lobby.freeze_instead = v2 end
            imgui.text(lobby.hook_installed
                and ("New Game detection: on (newGameRequest, " .. (RE7.can_block and "can block" or "cannot block, will freeze") .. ")")
                or "New Game detection: off (hook not installed, see console; use \"I'm ready\")")
            if lobby.hold_kind == "block" then imgui.text("The New Game request is blocked until both players are ready (Cancel drops it).") end
            if held.active then imgui.text("Game is frozen until both players are ready (Cancel releases it).") end
            local gd = RE7.current_difficulty()
            imgui.text("Game difficulty right now: " .. (gd ~= nil and DIFFICULTY[gd] or "unknown"))
            local c3, v3 = imgui.checkbox("Log new-game calls to the console", RE7.trace_on)
            if c3 then RE7.trace_on = v3 end
            for i = math.max(1, #RE7.trace_lines - 12), #RE7.trace_lines do imgui.text(RE7.trace_lines[i]) end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Avatar (experimental)") then
        local ok, err = pcall(function()
            imgui.text(avatar.obj and "A cloned model is standing in for the skeleton."
                or "Drawing the skeleton. Scan for a model, then clone it.")
            local c1, v1 = imgui.input_text("Scan filter", avatar.filter)
            if c1 then avatar.filter = v1 end
            if imgui.button("Scan scene") then scan_scene(avatar.filter) end
            for i = 1, math.min(#avatar.lines, 30) do imgui.text(avatar.lines[i]) end
            local c2, v2 = imgui.input_text("Object to clone", avatar.source_name)
            if c2 then avatar.source_name = v2 end
            if imgui.button("Clone and follow") then spawn_clone(avatar.source_name) end
            if avatar.obj and imgui.button("Remove clone") then remove_clone() end
            local c3, v3 = imgui.checkbox("Also draw the skeleton", avatar.show_skeleton)
            if c3 then avatar.show_skeleton = v3 end
            if imgui.button("List via.GameObject clone/create methods") then
                probe.lines = {}
                probe_type("via.GameObject", false, { "clone", "instantiate", "create" })
            end
            if avatar.error then imgui.text("Error: " .. avatar.error) end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Probe RE7 types") then
        local ok, err = pcall(function()
            imgui.text("Logs methods (with signatures) to the REFramework console.")
            if imgui.button("Show new-game method signatures") then
                probe.lines = {}
                probe_signatures()
            end
            if imgui.button("Probe candidate manager types") then
                probe.lines = {}
                for _, n in ipairs(PROBE_CANDIDATES) do probe_type(n, false) end
            end
            local c3, v3 = imgui.input_text("Type name", probe.type_name)
            if c3 then probe.type_name = v3 end
            if imgui.button("List all methods of that type") then
                probe.lines = {}
                probe_type(probe.type_name, true)
            end
            for i = math.max(1, #probe.lines - 40), #probe.lines do imgui.text(probe.lines[i]) end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

say("script v4 loaded")
