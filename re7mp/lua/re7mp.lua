-- RE7 multiplayer prototype, Lua side (script v6).
-- re7mp.exe installs this to <RE7>/reframework/autorun/re7mp.lua and talks to it through
-- JSON files in reframework/data. Edit the copy in the project (lua/re7mp.lua) and rebuild;
-- the exe overwrites the installed copy.
--
-- What it does:
--   * sends your camera position + rotation to the other player (via re7mp.exe)
--   * draws the other player as a shaded 3D body (plus an optional debug skeleton) with a name tag,
--     facing where they look
--   * "Start together": a ready check. Both players say they're ready on the same difficulty,
--     and only then does the game go on. When RE7's New Game is detected (app.GameManager.newGameRequest)
--     that request is BLOCKED until the other player is ready too, then replayed on the agreed
--     difficulty. The "I'm ready" / "Join" buttons in the panel do the same with a countdown.
--   * "Chat and pings": a reliable message channel to the other player (more uses to come, e.g. items).
--   * "Find item hooks (tracer)": logs which game methods fire when you pick up or drop items.
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
    HIDE_AFTER_NEW_GAME = 150, -- seconds the other player stays hidden after a new game starts (opening cutscene)
    HIDE_NEAR_DISTANCE = 0.8,  -- also hide them while they are this close to your camera (e.g. same cutscene camera)
    BODY_ALPHA = 215,         -- 0-255; the body is an overlay and shows through walls, so it is a little see-through
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
    show_figure = true,      -- master switch for drawing the other player
    show_body = true,        -- the shaded 3D body
    show_skeleton = false,   -- the line skeleton (debug)
    auto_hide = true,        -- hide the other player after a new game starts
    hidden_until = 0,        -- os.clock() time until which the other player is hidden
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
    show_skeleton = false,   -- keep drawing the body/skeleton even while a clone is active
}

local probe = {
    lines = {},
    type_name = "app.ItemManager",
}

-- Everything said here also goes to reframework/data/re7mp_debug.json, so it can simply be sent as a file.
local dbg = { lines = {}, dirty = false, last_flush = 0 }

local function say(msg)
    local text = "[re7mp] " .. tostring(msg)
    if log and log.info then
        pcall(log.info, text)
    else
        print(text)
    end
    dbg.lines[#dbg.lines + 1] = string.format("%.1f  %s", os.clock(), tostring(msg))
    if #dbg.lines > 3200 then
        local keep = {}
        for i = 401, #dbg.lines do keep[#keep + 1] = dbg.lines[i] end
        dbg.lines = keep
    end
    dbg.dirty = true
end

local function flush_debug(now)
    if dbg.dirty and now - dbg.last_flush >= 2 then
        dbg.dirty = false
        dbg.last_flush = now
        pcall(json.dump_file, "re7mp_debug.json", { script = "re7mp v6", lines = dbg.lines })
    end
end

-- Hide the other player for a while (opening cutscene after a new game), or show them again with 0.
local function hide_remote(seconds, why)
    state.hidden_until = os.clock() + seconds
    if seconds > 0 then say("other player hidden for " .. tostring(seconds) .. " s (" .. tostring(why) .. ")") end
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
    if state.auto_hide then hide_remote(CFG.HIDE_AFTER_NEW_GAME, "new game pressed") end
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
            if state.auto_hide then hide_remote(CFG.HIDE_AFTER_NEW_GAME, "new game starting") end

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
-- Drawing: a 3D body made of shaded boxes, plus a line skeleton for debugging.
-- Both are projected onto the screen as an overlay, so they show through walls (no depth test against
-- the level). That is expected until the other player gets a real in-game avatar.
----------------------------------------------------------------------------------------------
local function project(p)
    local sp = draw.world_to_screen(Vector3f.new(p[1], p[2], p[3]))
    -- Never hand NaN or huge coordinates to the renderer.
    if sp and sp.x == sp.x and sp.y == sp.y and math.abs(sp.x) < 20000 and math.abs(sp.y) < 20000 then return sp end
    return nil
end

local function line3(a, b, color)
    local sa, sb = project(a), project(b)
    if sa and sb then draw.line(sa.x, sa.y, sb.x, sb.y, color) end
end

local function vadd(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function vsub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function vscale(a, k) return { a[1] * k, a[2] * k, a[3] * k } end
local function vdot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function vcross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function vnorm(a)
    local l = math.sqrt(vdot(a, a))
    if l < 1e-6 then return { 0, 1, 0 } end
    return { a[1] / l, a[2] / l, a[3] / l }
end

-- Packed as 0xAABBGGRR, which is what the draw functions take (green looks the same either way).
local function rgba(r, g, b, a)
    return math.floor(a) * 16777216 + math.floor(b) * 65536 + math.floor(g) * 256 + math.floor(r)
end

-- Joint positions for the current pose. `pos` is the camera (eyes), fwd the look direction.
local function compute_joints(pos, fwd, amp, phase)
    local hx, hz = fwd[1], fwd[3]
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl < 1e-3 then hx, hz = 0, 1 else hx, hz = hx / hl, hz / hl end
    local rx, rz = hz, -hx -- "right" on the ground plane
    local H = CFG.EYE_HEIGHT
    local ox, oy, oz = pos.x, pos.y - H, pos.z -- point on the floor below the camera
    local function J(r, u, f) -- right / up / forward offsets from the feet -> world point
        return { ox + rx * r + hx * f, oy + u, oz + rz * r + hz * f }
    end
    local j = {
        frame = { right = { rx, 0, rz }, fwd = { hx, 0, hz }, up = { 0, 1, 0 } },
        head = { pos.x, pos.y, pos.z },
        neck = J(0, H - 0.18, 0),
        pelvis = J(0, H * 0.56, 0),
        shoulder = {}, hip = {}, elbow = {}, hand = {}, knee = {}, foot = {},
    }
    for _, k in ipairs({ 1, -1 }) do
        local ph = phase + (k > 0 and 0 or math.pi) -- legs and arms swing in opposition
        local stride = amp * 0.32 * math.sin(ph)
        local lift = amp * 0.14 * math.max(0, math.cos(ph))
        j.shoulder[k] = J(k * 0.2, H - 0.28, 0)
        j.hip[k] = J(k * 0.1, H * 0.56, 0)
        j.knee[k] = J(k * 0.1, H * 0.28 + lift * 0.5, stride * 0.6 + amp * 0.05)
        j.foot[k] = J(k * 0.1, lift, stride)
        j.elbow[k] = J(k * 0.23, H * 0.72, -stride * 0.5)
        j.hand[k] = J(k * 0.23, H * 0.55, -stride)
    end
    return j
end

-- Debug skeleton: just lines between the joints, plus the look direction.
local function draw_skeleton(j, fwd3, color)
    line3(j.neck, j.head, color)
    line3(j.neck, j.pelvis, color)
    line3(j.shoulder[1], j.shoulder[-1], color)
    line3(j.hip[1], j.hip[-1], color)
    for _, k in ipairs({ 1, -1 }) do
        line3(j.shoulder[k], j.elbow[k], color)
        line3(j.elbow[k], j.hand[k], color)
        line3(j.hip[k], j.knee[k], color)
        line3(j.knee[k], j.foot[k], color)
    end
    line3(j.head, vadd(j.head, vscale(fwd3, 0.45)), 0xFFFFFFFF)
end

-- ---- 3D body: oriented boxes, back-face culled, sorted far to near, flat shaded ----
local PERIM = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
local function corner_index(s1, s2, s3)
    return (s1 > 0 and 4 or 0) + (s2 > 0 and 2 or 0) + (s3 > 0 and 1 or 0) + 1
end
local FACES = {} -- each face: which axis it is perpendicular to, which side, and its 4 corner indices
for axis = 1, 3 do
    local a2, a3 = (axis % 3) + 1, ((axis + 1) % 3) + 1
    for _, sign in ipairs({ 1, -1 }) do
        local idx = {}
        for _, pq in ipairs(PERIM) do
            local sgn = { 0, 0, 0 }
            sgn[axis], sgn[a2], sgn[a3] = sign, pq[1], pq[2]
            idx[#idx + 1] = corner_index(sgn[1], sgn[2], sgn[3])
        end
        FACES[#FACES + 1] = { axis = axis, sign = sign, idx = idx }
    end
end
local LIGHT = vnorm({ 0.35, 0.85, 0.4 })

local function make_box(center, ax, ay, az, hx, hy, hz)
    local corners = {}
    for _, s1 in ipairs({ -1, 1 }) do
        for _, s2 in ipairs({ -1, 1 }) do
            for _, s3 in ipairs({ -1, 1 }) do
                local c = vadd(center, vadd(vscale(ax, s1 * hx), vadd(vscale(ay, s2 * hy), vscale(az, s3 * hz))))
                corners[corner_index(s1, s2, s3)] = c
            end
        end
    end
    return { center = center, axes = { ax, ay, az }, half = { hx, hy, hz }, corners = corners }
end

-- A thick bar from a to b (arms, legs); `side` is a hint for which way its width points.
local function limb_box(a, b, half_width, side)
    local d = vsub(b, a)
    local len = math.sqrt(vdot(d, d))
    local ay = vnorm(d)
    local ax = vnorm(vsub(side, vscale(ay, vdot(side, ay))))
    local az = vcross(ax, ay)
    return make_box(vscale(vadd(a, b), 0.5), ax, ay, az, half_width, math.max(len / 2, 0.01), half_width)
end

local function draw_box(box, cam, base, alpha, outline)
    local projected = {}
    local function P(i)
        local v = projected[i]
        if v == nil then
            v = project(box.corners[i]) or false
            projected[i] = v
        end
        return v
    end
    for _, f in ipairs(FACES) do
        local n = vscale(box.axes[f.axis], f.sign)
        local face_center = vadd(box.center, vscale(n, box.half[f.axis]))
        if vdot(n, vsub(cam, face_center)) > 0 then -- the face points at the camera
            local a, b, c, d = P(f.idx[1]), P(f.idx[2]), P(f.idx[3]), P(f.idx[4])
            if a and b and c and d then
                if draw.filled_quad then
                    local br = 0.40 + 0.60 * math.max(0, vdot(n, LIGHT))
                    draw.filled_quad(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y,
                        rgba(base[1] * br, base[2] * br, base[3] * br, alpha))
                end
                draw.line(a.x, a.y, b.x, b.y, outline)
                draw.line(b.x, b.y, c.x, c.y, outline)
                draw.line(c.x, c.y, d.x, d.y, outline)
                draw.line(d.x, d.y, a.x, a.y, outline)
            end
        end
    end
end

local function draw_body(j, fwd3, cam, tint)
    local R, F, U = j.frame.right, j.frame.fwd, j.frame.up
    local function tinted(r, g, b) return { r * tint[1] / 255, g * tint[2] / 255, b * tint[3] / 255 } end
    local skin, shirt, trousers, shoe = tinted(240, 240, 240), tinted(200, 230, 210), tinted(150, 170, 200), tinted(110, 110, 110)
    local visor = tinted(255, 255, 255)
    local parts = {}
    local function add(box, color) parts[#parts + 1] = { box = box, color = color } end

    -- torso
    local torso_len = math.sqrt(vdot(vsub(j.neck, j.pelvis), vsub(j.neck, j.pelvis)))
    add(make_box(vscale(vadd(j.neck, j.pelvis), 0.5), R, U, F, 0.2, torso_len / 2 + 0.03, 0.11), shirt)

    -- head, turned and tilted to the look direction, with a bright visor on its front
    local right = vnorm(vcross({ 0, 1, 0 }, fwd3))
    if math.abs(fwd3[2]) > 0.97 then right = R end
    local up = vcross(fwd3, right)
    local hc = vsub(j.head, vscale(fwd3, 0.05))
    add(make_box(hc, right, up, fwd3, 0.095, 0.12, 0.11), skin)
    add(make_box(vadd(vadd(hc, vscale(fwd3, 0.105)), vscale(up, 0.015)), right, up, fwd3, 0.07, 0.03, 0.012), visor)

    -- arms, legs, feet
    for _, k in ipairs({ 1, -1 }) do
        add(limb_box(j.shoulder[k], j.elbow[k], 0.055, R), shirt)
        add(limb_box(j.elbow[k], j.hand[k], 0.05, R), skin)
        add(limb_box(j.hip[k], j.knee[k], 0.085, R), trousers)
        add(limb_box(j.knee[k], j.foot[k], 0.065, R), trousers)
        add(make_box(vadd(vadd(j.foot[k], vscale(F, 0.07)), vscale(U, 0.035)), R, U, F, 0.06, 0.04, 0.13), shoe)
    end

    -- far to near, so nearer parts cover farther ones
    for _, p in ipairs(parts) do
        local d = vsub(p.box.center, cam)
        p.d2 = vdot(d, d)
    end
    table.sort(parts, function(a, b) return a.d2 > b.d2 end)
    local outline = rgba(10, 30, 15, 200)
    for _, p in ipairs(parts) do draw_box(p.box, cam, p.color, CFG.BODY_ALPHA, outline) end
end

local function draw_tag(pos, label, color)
    local tag = project({ pos.x, pos.y + 0.32, pos.z })
    if tag then draw.text(label, tag.x - #label * 3.5, tag.y - 14, color) end
end

-- Why the other player is not being drawn right now, or nil if they should be.
local function remote_hidden(now)
    if now < state.hidden_until then return "hidden after the new game (" .. math.ceil(state.hidden_until - now) .. " s)" end
    local lp, rp = state.local_pos, state.render_pos
    if lp and rp then
        local dx, dy, dz = rp.x - lp.x, rp.y - lp.y, rp.z - lp.z
        if dx * dx + dy * dy + dz * dz < CFG.HIDE_NEAR_DISTANCE ^ 2 then return "too close to your camera" end
    end
    return nil
end

local function draw_remote(now)
    if not state.show_figure or not state.remote or not state.render_pos then return end
    if avatar.obj and not avatar.show_skeleton then return end -- a cloned model is standing in
    if remote_hidden(now) then return end
    local stale = (now - state.remote_changed_at) > CFG.STALE_AFTER
    local color = stale and 0xFF888888 or 0xFF00FF00
    local label = state.remote_name or CFG.DEFAULT_NAME
    if stale then label = label .. " (no signal)" end
    local amp = math.max(0, math.min(1, (state.speed - 0.15) / 1.8))
    local pos, fwd = state.render_pos, state.render_fwd
    local j = compute_joints(pos, fwd, amp, state.walk_phase)
    if state.show_body and state.local_pos then
        local cam = { state.local_pos.x, state.local_pos.y, state.local_pos.z }
        draw_body(j, fwd, cam, stale and { 150, 150, 150 } or { 90, 255, 130 })
    end
    if state.show_skeleton then draw_skeleton(j, fwd, color) end
    draw_tag(pos, label, color)
end

----------------------------------------------------------------------------------------------
-- Messages: a reliable channel to the other player (chat, pings; item events will use it too).
-- Messages go through re7mp.exe, which resends them until the other side confirms and delivers each
-- one once. Kinds: 1 = chat text, 2 = ping "x;y;z".
----------------------------------------------------------------------------------------------
local MSG_OUT_FILE = "re7mp_msg_out.json"
local MSG_IN_FILE = "re7mp_msg_in.json"

local netmsg = {
    outbox = {},   -- ring of our most recent messages: { id, k, p }
    next_id = math.floor(os.time and os.time() or (os.clock() * 1000)) * 1000,
    dirty = false,
    last_flush = 0,
    handlers = {}, -- kind -> function(payload)
    epoch = nil,   -- which engine run the inbox belongs to
    last_n = 0,    -- last inbox entry we handled
}

local function net_on(kind, handler)
    netmsg.handlers[kind] = handler
end

local function net_send(kind, payload)
    payload = tostring(payload):gsub("%c", " ")
    if #payload > 180 then payload = payload:sub(1, 180) end
    pcall(function() -- never leave half of a multi-byte character at the end
        while #payload > 0 and not utf8.len(payload) do payload = payload:sub(1, -2) end
    end)
    netmsg.next_id = netmsg.next_id + 1
    netmsg.outbox[#netmsg.outbox + 1] = { id = netmsg.next_id, k = kind, p = payload }
    while #netmsg.outbox > 32 do table.remove(netmsg.outbox, 1) end
    netmsg.dirty = true
end

local function flush_messages(now)
    if netmsg.dirty and now - netmsg.last_flush >= 0.05 then
        netmsg.dirty = false
        netmsg.last_flush = now
        json.dump_file(MSG_OUT_FILE, { msgs = netmsg.outbox })
    end
end

-- Remember what is already in the inbox so old messages are not replayed after a script reload.
local function prime_messages()
    local d = json.load_file(MSG_IN_FILE)
    if type(d) ~= "table" or type(d.msgs) ~= "table" then return end
    netmsg.epoch = d.epoch
    for _, m in ipairs(d.msgs) do
        if type(m) == "table" and type(m.n) == "number" and m.n > netmsg.last_n then netmsg.last_n = m.n end
    end
end

local function read_messages()
    local d = json.load_file(MSG_IN_FILE)
    if type(d) ~= "table" or type(d.msgs) ~= "table" then return end
    if d.epoch ~= netmsg.epoch then -- the engine restarted: its numbering starts again
        netmsg.epoch = d.epoch
        netmsg.last_n = 0
    end
    for _, m in ipairs(d.msgs) do
        if type(m) == "table" and type(m.n) == "number" and m.n > netmsg.last_n then
            netmsg.last_n = m.n
            local handler = netmsg.handlers[m.k]
            if handler then
                local ok, err = pcall(handler, tostring(m.p or ""))
                if not ok then say("message handler error: " .. tostring(err)) end
            end
        end
    end
end

-- Chat
local chat = { lines = {}, input = "" }

local function chat_add(who, text)
    chat.lines[#chat.lines + 1] = { who = who, text = text, at = os.clock() }
    while #chat.lines > 40 do table.remove(chat.lines, 1) end
end

local function chat_send(text)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    net_send(1, text)
    chat_add("You", text)
end

net_on(1, function(payload)
    chat_add(state.remote_name or CFG.DEFAULT_NAME, payload)
end)

-- Pings: "look here" markers at a world position
local pings = {}

net_on(2, function(payload)
    local x, y, z = payload:match("^(-?[%d%.]+);(-?[%d%.]+);(-?[%d%.]+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return end
    pings[#pings + 1] = { x = x, y = y, z = z, who = state.remote_name or CFG.DEFAULT_NAME, at = os.clock() }
    while #pings > 8 do table.remove(pings, 1) end
end)

local function ping_here()
    local p = state.local_pos
    if not p then return end
    net_send(2, string.format("%.2f;%.2f;%.2f", p.x, p.y, p.z))
    chat_add("You", "(pinged your position)")
end

-- On-screen chat and ping markers
local function draw_hud(now)
    local y = 64
    for i = math.max(1, #chat.lines - 5), #chat.lines do
        local l = chat.lines[i]
        if now - l.at < 12 then
            pcall(draw.text, l.who .. ": " .. l.text, 24, y, 0xFFFFFFFF)
            y = y + 16
        end
    end
    for i = #pings, 1, -1 do
        local p = pings[i]
        if now - p.at > 12 then
            table.remove(pings, i)
        else
            local sp = project({ p.x, p.y, p.z })
            if sp then
                local c = 0xFF00D7FF
                local r = 9
                draw.line(sp.x, sp.y - r, sp.x + r, sp.y, c)
                draw.line(sp.x + r, sp.y, sp.x, sp.y + r, c)
                draw.line(sp.x, sp.y + r, sp.x - r, sp.y, c)
                draw.line(sp.x - r, sp.y, sp.x, sp.y - r, c)
                local lp = state.local_pos
                local dist = 0
                if lp then dist = math.sqrt((p.x - lp.x) ^ 2 + (p.y - lp.y) ^ 2 + (p.z - lp.z) ^ 2) end
                draw.text(string.format("%s (%.0f m)", p.who, dist), sp.x + 14, sp.y - 8, c)
            end
        end
    end
end

----------------------------------------------------------------------------------------------
-- Probe: lists a type's methods (with signatures) so the adapter can be extended
----------------------------------------------------------------------------------------------
local PROBE_CANDIDATES = {
    "app.GameManager", "app.SaveDataManager", "app.ItemManager",
    "app.Inventory", "app.Item", "app.ItemData", "app.SupplyBoxData",
    "app.EnemyManager", "app.EventManager", "app.MapManager", "app.GimmickManager",
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

local function probe_type(name, list_all, keywords, limit)
    keywords = keywords or PROBE_KEYWORDS
    limit = limit or 80
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
            if match and shown < limit then
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
-- Tracer: hooks every method of a type (rate limited) and logs the calls with their arguments, so you can
-- see which methods fire when you pick up or drop an item. Hooks last until the scripts are reloaded.
----------------------------------------------------------------------------------------------
local tracer = {
    enabled = true,
    type_name = "app.ItemManager",
    filter = "",
    include_getters = false,
    hooked = {},
    hook_count = 0,
    rate = {},
    lines = {},
}

local function tracer_add(text)
    tracer.lines[#tracer.lines + 1] = text
    while #tracer.lines > 60 do table.remove(tracer.lines, 1) end
    say("[trace] " .. text)
end

-- Reference types are read as objects; value types (numbers, enums, structs) are only shown as raw numbers,
-- because treating a plain number as an object pointer could crash the game.
local function describe_arg(pt, args, idx)
    local ok, text = pcall(function()
        local n = pt.name
        if pt.ref then
            local o = sdk.to_managed_object(args[idx])
            if o == nil then return "null" end
            if n == "System.String" then
                local ok2, str = pcall(function() return o:call("ToString()") end)
                if ok2 and type(str) == "string" then return "\"" .. str .. "\"" end
                return "<string>"
            end
            if n == "via.GameObject" then
                local ok3, nm = pcall(function() return o:call("get_Name") end)
                if ok3 then return "GameObject(" .. tostring(nm) .. ")" end
            end
            return "<" .. n .. ">"
        end
        if n == "System.Boolean" then return tostring(sdk.to_int64(args[idx]) % 256 ~= 0) end
        if n == "System.Single" then return string.format("%.3f", sdk.to_float(args[idx])) end
        local v = sdk.to_int64(args[idx])
        if n == "System.Int32" or n:find("^app%.") then
            v = v % 4294967296
            if v >= 2147483648 then v = v - 4294967296 end
        end
        return tostring(v)
    end)
    return ok and text or ("?" .. tostring(text))
end

local function trace_method(type_name, m)
    local mname = m:get_name()
    local ptypes, names = {}, {}
    pcall(function()
        for i, t in ipairs(m:get_param_types() or {}) do
            local okv, isval = pcall(function() return t:is_value_type() end)
            ptypes[i] = { name = t:get_full_name(), ref = okv and isval == false }
            names[i] = ptypes[i].name
        end
    end)
    local is_static = false
    pcall(function() is_static = m:is_static() == true end)
    local key = type_name .. "." .. mname .. "(" .. table.concat(names, ",") .. ")"
    if tracer.hooked[key] then return false end
    tracer.hooked[key] = true

    local CALL_ORIGINAL = sdk.PreHookResult and sdk.PreHookResult.CALL_ORIGINAL
    sdk.hook(m, function(args)
        pcall(function()
            if not tracer.enabled then return end
            local now = os.clock()
            local e = tracer.rate[key] or { t = 0, n = 0, dropped = 0 }
            tracer.rate[key] = e
            if now - e.t > 1 then
                if e.dropped > 0 then
                    tracer_add(type_name .. "." .. mname .. ": " .. e.dropped .. " more calls in the last second")
                end
                e.t, e.n, e.dropped = now, 0, 0
            end
            e.n = e.n + 1
            if e.n > 3 then
                e.dropped = e.dropped + 1
                return
            end
            local parts = {}
            for i, pt in ipairs(ptypes) do parts[i] = describe_arg(pt, args, i + (is_static and 1 or 2)) end
            tracer_add(string.format("%s.%s(%s)", type_name, mname, table.concat(parts, ", ")))
        end)
        return CALL_ORIGINAL
    end, function(retval) return retval end)
    return true
end

local function trace_type(type_name, filter, include_getters)
    local ok, err = pcall(function()
        local td = sdk.find_type_definition(type_name)
        if not td then
            tracer_add(type_name .. ": not found")
            return
        end
        local added, skipped = 0, 0
        local f = (filter or ""):lower()
        for _, m in ipairs(td:get_methods() or {}) do
            local name = m:get_name()
            local low = name:lower()
            local skip = low:find("update", 1, true) ~= nil or name == ".ctor" or name == "doAwake"
                or (not include_getters and low:sub(1, 4) == "get_")
                or (f ~= "" and not low:find(f, 1, true))
            if not skip and tracer.hook_count < 150 and trace_method(type_name, m) then
                added = added + 1
                tracer.hook_count = tracer.hook_count + 1
            else
                skipped = skipped + 1
            end
        end
        tracer_add(string.format("%s: tracing %d methods (%d skipped)", type_name, added, skipped))
    end)
    if not ok then tracer_add(type_name .. ": error " .. tostring(err)) end
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
    local hidden = remote_hidden(os.clock()) ~= nil
    local ok, err = pcall(function()
        local yaw = math.atan(fwd[1], fwd[3]) + CFG.MODEL_YAW_OFFSET
        local y = hidden and -10000 or (pos.y - CFG.EYE_HEIGHT) -- "hidden" = parked far below the world
        avatar.xf:call("set_Position", Vector3f.new(pos.x, y, pos.z))
        avatar.xf:call("set_EulerAngle", Vector3f.new(0, yaw, 0))
    end)
    if not ok then
        avatar.error = tostring(err)
        say("avatar update failed, removing the clone: " .. avatar.error)
        remove_clone()
    end
end

----------------------------------------------------------------------------------------------
-- "Send me this": one-click collectors. Everything is saved to reframework/data/re7mp_debug.json.
----------------------------------------------------------------------------------------------
local COLLECT_TYPES = {
    "app.Inventory", "app.Item", "app.ItemData", "app.ItemManager", "app.SupplyBoxData",
    "app.EnemyManager", "app.EventManager", "app.PlayerManager", "app.CharacterManager", "app.MapManager",
}

local function collect_info()
    probe.lines = {}
    say("=== collect: new-game method signatures ===")
    probe_signatures()
    for _, n in ipairs(COLLECT_TYPES) do
        say("=== collect: " .. n .. " ===")
        probe_type(n, true, nil, 250)
    end
    say("=== collect: done ===")
end

-- Lists GameObjects that look like enemies: a component whose type name contains "enemy" or "em" + digits,
-- or a name like em1234. Run it in a room where an enemy is visible.
local function scan_enemies()
    say("=== enemy scan ===")
    local found, seen = 0, 0
    local ok, err = pcall(each_gameobject, function(go, path)
        seen = seen + 1
        local name_hit = path:lower():find("/em%d%d%d%d") ~= nil
        local okc, comps = pcall(component_names, go)
        local comp_hit = false
        if okc then
            for _, c in ipairs(comps) do
                local low = c:lower()
                if low:find("enemy", 1, true) or low:find("^app%.em") then comp_hit = true end
            end
        end
        if (name_hit or comp_hit) and found < 80 then
            found = found + 1
            local pos = ""
            pcall(function()
                local p = go:call("get_Transform"):call("get_Position")
                pos = string.format("  at %.1f, %.1f, %.1f", p.x, p.y, p.z)
            end)
            say(path .. "  [" .. (okc and table.concat(comps, ", ") or "?") .. "]" .. pos)
        end
    end, 15000)
    if not ok then say("enemy scan error: " .. tostring(err)) end
    say(string.format("=== enemy scan done: %d candidates among %d objects ===", found, seen))
end

----------------------------------------------------------------------------------------------
-- Main loop and UI
----------------------------------------------------------------------------------------------
prime_messages()
local ok_hook, installed = pcall(RE7.install_new_game_hook, on_local_new_game)
lobby.hook_installed = ok_hook and installed == true

-- Never leave the game frozen if the scripts are reloaded while we're holding it.
if re.on_script_reset then re.on_script_reset(function() release_game() remove_clone() end) end

re.on_frame(function()
    local now = os.clock()
    local dt = math.min(now - state.last_frame, 0.1)
    state.last_frame = now

    if now - state.last_send >= CFG.SEND_INTERVAL then send_local(now) end
    if now - state.last_read >= CFG.READ_INTERVAL then
        read_remote(now)
        pcall(read_messages)
    end
    flush_messages(now)
    flush_debug(now)
    update_remote(now, dt)
    update_lobby(now)
    update_avatar()

    local ok, err = pcall(draw_remote, now)
    if not ok then state.last_error = tostring(err) end
    pcall(draw_hud, now)

    if lobby.phase ~= "idle" or now < lobby.message_until then
        pcall(draw.text, lobby.message, 24, 24, 0xFF00FFFF)
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("RE7 Multiplayer") then return end

    local changed, v = imgui.checkbox("Show other player", state.show_figure)
    if changed then state.show_figure = v end
    local cb, vb = imgui.checkbox("3D body", state.show_body)
    if cb then state.show_body = vb end
    local cs, vs = imgui.checkbox("Debug skeleton (lines)", state.show_skeleton)
    if cs then state.show_skeleton = vs end
    local ch, vh = imgui.checkbox("Hide them for a while after a new game (cutscenes)", state.auto_hide)
    if ch then state.auto_hide = vh end
    local why = remote_hidden(os.clock())
    if why then
        imgui.text("Other player not drawn: " .. why)
        if os.clock() < state.hidden_until and imgui.button("Show them now") then state.hidden_until = 0 end
    elseif imgui.button("Hide them for 60 s") then
        hide_remote(60, "manual")
    end

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

    if imgui.tree_node("Send me this (debug info)") then
        local ok, err = pcall(function()
            imgui.text("Everything below is saved to reframework\\data\\re7mp_debug.json.")
            imgui.text("In re7mp.exe click 'Open data folder' and send me that file.")
            if imgui.button("1. Collect game info") then collect_info() end
            if imgui.button("2. Start tracing items (then pick up and drop an item)") then
                for _, n in ipairs({ "app.ItemManager", "app.Inventory", "app.Item" }) do trace_type(n, "", false) end
            end
            if imgui.button("3. Scan for enemies (stand where one is visible)") then scan_enemies() end
            imgui.text(string.format("Debug log: %d lines", #dbg.lines))
            if imgui.button("Clear the debug log") then dbg.lines = {} dbg.dirty = true end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Chat and pings") then
        local ok, err = pcall(function()
            local c, text = imgui.input_text("Message", chat.input)
            if c then chat.input = text end
            if imgui.button("Send") then
                chat_send(chat.input)
                chat.input = ""
            end
            if imgui.button("Ping my position") then ping_here() end
            imgui.text("The other player sees your message and a marker at your position for 12 seconds.")
            for i = math.max(1, #chat.lines - 8), #chat.lines do
                imgui.text(chat.lines[i].who .. ": " .. chat.lines[i].text)
            end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Find item hooks (tracer)") then
        local ok, err = pcall(function()
            imgui.text("Logs which methods fire (with arguments) while you pick up, drop or use items.")
            imgui.text("Hooks stay until the scripts are reloaded; calls are rate limited.")
            local ce, ve = imgui.checkbox("Tracing on", tracer.enabled)
            if ce then tracer.enabled = ve end
            if imgui.button("Trace app.ItemManager") then trace_type("app.ItemManager", "", false) end
            local c1, v1 = imgui.input_text("Type to trace", tracer.type_name)
            if c1 then tracer.type_name = v1 end
            local c2, v2 = imgui.input_text("Only methods containing", tracer.filter)
            if c2 then tracer.filter = v2 end
            local c3, v3 = imgui.checkbox("Include get_ methods (noisy)", tracer.include_getters)
            if c3 then tracer.include_getters = v3 end
            if imgui.button("Trace that type") then trace_type(tracer.type_name, tracer.filter, tracer.include_getters) end
            imgui.text("Hooked methods: " .. tostring(tracer.hook_count))
            for i = math.max(1, #tracer.lines - 20), #tracer.lines do imgui.text(tracer.lines[i]) end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Avatar (experimental)") then
        local ok, err = pcall(function()
            imgui.text(avatar.obj and "A cloned model is standing in for the body."
                or "Drawing the 3D body. Scan for a model, then clone it.")
            local c1, v1 = imgui.input_text("Scan filter", avatar.filter)
            if c1 then avatar.filter = v1 end
            if imgui.button("Scan scene") then scan_scene(avatar.filter) end
            for i = 1, math.min(#avatar.lines, 30) do imgui.text(avatar.lines[i]) end
            local c2, v2 = imgui.input_text("Object to clone", avatar.source_name)
            if c2 then avatar.source_name = v2 end
            if imgui.button("Clone and follow") then spawn_clone(avatar.source_name) end
            if avatar.obj and imgui.button("Remove clone") then remove_clone() end
            local c3, v3 = imgui.checkbox("Also draw the body/skeleton", avatar.show_skeleton)
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

say("script v6 loaded")
