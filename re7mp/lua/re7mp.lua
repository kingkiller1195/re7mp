-- RE7 multiplayer prototype, Lua side (release 0.7, build v9.15).
-- re7mp.exe installs this to <RE7>/reframework/autorun/re7mp.lua and talks to it through
-- JSON files in reframework/data. Edit the copy in the project (lua/re7mp.lua) and rebuild;
-- the exe overwrites the installed copy.
--
-- What it does:
--   * sends your camera position + rotation to the other player (via re7mp.exe)
--   * draws the other player as a shaded 3D body (plus an optional debug skeleton) with a name tag,
--     facing where they look, and shows when they block or use a healing item (9.7)
--   * "Start together": a ready check. Both players say they're ready on the same difficulty,
--     and only then does the game go on. When RE7's New Game is detected (app.GameManager.newGameRequest)
--     that request is BLOCKED until the other player is ready too, then replayed on the agreed
--     difficulty. The "I'm ready" / "Join" buttons in the panel do the same with a countdown.
--   * "Death": choose what happens when a player dies (shared fate: both die). "Co-op saves": shows what
--     re7mp.exe shared. Settings are remembered in re7mp_settings.json.
--   * "Item sync": an item one player picks up from the world disappears for the other player.
--   * "Items: give and drop": hand the highlighted inventory item to the other player (F7), and/or make the
--     inventory's Discard drop the item on the ground where the other player sees it too.
--   * "Enemies" (EXPERIMENTAL, TCP only): the host sends its enemies' positions; the joiner sees red ghosts.
--   * "Chat and pings": a reliable message channel to the other player (more uses to come, e.g. items).
--   * "Find item hooks (tracer)": logs which game methods fire when you pick up or drop items.
--   * "Avatar (experimental)": scan the scene and try cloning an in-game model instead of the skeleton.
--
-- NOTE: untested in-game apart from the position/figure part (the new-game hooks, ready check,
-- freeze and avatar cloning are all new and unverified). Errors show in the REFramework
-- console and in the "RE7 Multiplayer" panel (Insert key).

local FILES = { -- the bridge files in reframework/data (one table instead of seven locals: Lua allows 200 per chunk)
    OUT_FILE = "re7mp_out.json",
    IN_FILE = "re7mp_in.json",
    MSG_OUT_FILE = "re7mp_msg_out.json",
    MSG_IN_FILE = "re7mp_msg_in.json",
    STATE_OUT_FILE = "re7mp_state_out.json",
    STATE_IN_FILE = "re7mp_state_in.json",
    SETTINGS_FILE = "re7mp_settings.json",
}
local CFG = {
    RELEASE = "0.7",          -- the public release number; must equal kReleaseVersion in src/version.hpp (a test checks). Only changes when the owner says.
    BUILD = "9.15",            -- internal build label (the changelog's v9.x), shown in the panel and debug file
    ver = {},                 -- release / version-check state (see "Version check" below)
    lm = {},                  -- Load screen labels (see "Load screen labels" below)
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
    HIDE_NEAR_DISTANCE = 0.4,  -- also hide them while they are this close to your camera (slider in the panel; saved)
    BODY_ALPHA = 215,         -- 0-255; the body is an overlay and shows through walls, so it is a little see-through
    READY_TIMEOUT = 120,      -- give up waiting for the other player after this many seconds
    GO_LATCH = 5,             -- keep saying "going" this long so the other side can't miss it
    COUNTDOWN = 3,            -- seconds of countdown after both are ready (manual mode)
    HOLD_SPEED = 0.001,       -- game speed while frozen (near zero rather than exactly zero)
    MODEL_YAW_OFFSET = 0,     -- radians; turn a cloned model if it faces the wrong way (3.14159 = turn around)
    -- Pose bits (9.7) in the same flags field: what the other player's body is doing. They sit above the ready-check
    -- bits and re7mp.exe passes the flags through unchanged, so no new protocol version was needed.
    POSE_GUARD = 64,          -- "I am blocking"
    POSE_HEAL = 128,          -- "I am using a healing item"
    POSE_CROUCH = 256,        -- "I am crouching" (9.9; the eyes are well below their standing height)
    CROUCH_DROP = 0.5,        -- the stand-in's body: how far the eyes sink in a full crouch (metres)
    CROUCH_ENTER = 0.22,      -- measured: the eyes this far below the standing height = crouching ...
    CROUCH_EXIT = 0.12,       -- ... and back up to this = standing again
    HEAL_POSE_TAIL = 0.5,     -- the heal pose is kept this long after the game's heal animation ends (hands action 16/17), so it does not flicker
    POSE_SAMPLE = 0.05,       -- how often my block / heal signals are read (seconds)
    POSE_BLEND = 9.0,         -- how fast the stand-in moves into and out of a pose (higher = snappier)
}

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
    transport = nil,         -- "tcp", as reported by re7mp.exe (UDP was removed in 9.7)
    role = nil,              -- "host" (your game will run the enemies) or "join"
    pose = { guard = 0, heal = 0, crouch = 0, t = 0 }, -- how far the stand-in is into each pose, 0..1 (smoothed)
    pose_preview = 1,        -- panel: 1 off, 2 guard, 3 heal, 4 cycle, 5 crouch (shows the poses on the stand-in without the other player doing them)
    pose_source = nil,       -- set by the health module: function(now) -> guard, heal, crouch (what MY body is doing)
    local_pose = { guard = false, heal = false, crouch = false }, -- what I am sending (panel)
    occlude = true,          -- hide the stand-in while a wall or door is between you and them (9.9)
    menu_hide = true,        -- hide the stand-in while a game menu (inventory, pause, map ...) is open (9.9, experimental)
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
local dbg = { lines = {}, pinned = {}, events = {}, pin = false, dirty = false, last_flush = 0 }

local function say(msg)
    local text = "[re7mp] " .. tostring(msg)
    if log and log.info then
        pcall(log.info, text)
    else
        print(text)
    end
    local line = string.format("%.1f  %s", os.clock(), tostring(msg))
    if dbg.pin and #dbg.pinned < 6000 then dbg.pinned[#dbg.pinned + 1] = line end -- survives the flood of trace lines
    -- (9.11) the journal: everything except the tracer's lines, kept apart so a trace cannot push give/drop/death/menu lines out of the file
    -- (9.12) ...nor the indented lines of the collectors (a method list of 400 lines pushed the whole journal out of the 0.7 file)
    if not tostring(msg):find("^%[trace%]") and not tostring(msg):find("^%s") then
        dbg.events[#dbg.events + 1] = line
        if #dbg.events > 600 then table.remove(dbg.events, 1) end
    end
    dbg.lines[#dbg.lines + 1] = line
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
        local extra
        if dbg.extra then
            local okx, v = pcall(dbg.extra)
            if okx then extra = v end
        end
        pcall(json.dump_file, "re7mp_debug.json", { script = "re7mp v" .. CFG.BUILD, release = CFG.RELEASE, build = CFG.BUILD,
            exe = state.exe_version, exe_protocol = state.exe_proto, other_player_version = CFG.ver.summary,
            health = extra, events = dbg.events, pinned = dbg.pinned, lines = dbg.lines })
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
    mode_map_built = false,
    mode_names = {},         -- GameMode value -> member name
    death_value = nil,       -- the GameMode member that looks like game over / death, if any
    death_name = nil,
    replaying_mode = false,  -- true while WE call setGamemode, so our hook ignores it
    on_gamemode = nil,       -- set by the death sync below: function(value)
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

-- Reads the GameMode enum so values can be shown by name, and finds the member that means game over / death
-- (a name containing gameover, game_over, dead or death). Logged to the console and the debug file.
local function build_mode_map()
    if RE7.mode_map_built then return end
    RE7.mode_map_built = true
    local ok, err = pcall(function()
        local td = sdk.find_type_definition("app.GameManager.GameMode")
        if not td then
            say("GameMode enum not found")
            return
        end
        local parts = {}
        for _, f in ipairs(td:get_fields()) do
            if f:is_static() then
                local v = f:get_data(nil)
                if type(v) == "number" then
                    local name = f:get_name()
                    RE7.mode_names[v] = name
                    parts[#parts + 1] = name .. "=" .. tostring(v)
                    local low = name:lower()
                    if RE7.death_value == nil and (low:find("gameover", 1, true) or low:find("game_over", 1, true)
                        or low:find("dead", 1, true) or low:find("death", 1, true)) then
                        RE7.death_value, RE7.death_name = v, name
                    end
                end
            end
        end
        say("GameMode values: " .. table.concat(parts, ", "))
        if RE7.death_value ~= nil then
            say("death detection uses GameMode." .. RE7.death_name .. " = " .. tostring(RE7.death_value))
        else
            say("death detection: no game-over-like member in GameMode, so deaths can't be detected yet")
        end
    end)
    if not ok then say("could not read the GameMode enum: " .. tostring(err)) end
end

-- Puts the local game into its game-over mode, as if the player had died. Returns true, or false plus a message.
function RE7.kill_local_player()
    build_mode_map()
    if RE7.death_value == nil then return false, "no game-over-like value in the GameMode enum" end
    local gm = game_manager()
    if not gm then return false, "app.GameManager not found" end
    RE7.replaying_mode = true
    local ok, err = pcall(function() gm:call("setGamemode", RE7.death_value) end)
    RE7.replaying_mode = false
    if not ok then return false, tostring(err) end
    return true
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
        build_mode_map()
        local ok, v = pcall(sdk.to_int64, args[3])
        local value = ok and v and (v % 4294967296) or nil
        trace("setGamemode(" .. (value and (RE7.mode_names[value] or tostring(value)) or "?") .. ")")
        if value and not RE7.replaying_mode and RE7.on_gamemode then RE7.on_gamemode(value) end
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
    -- what my body is doing (block / heal) rides along in the same field
    local lp = state.local_pose
    lp.guard, lp.heal, lp.crouch = false, false, false
    if state.pose_source then
        local okp, g, h, c = pcall(state.pose_source, now)
        if okp then
            lp.guard, lp.heal, lp.crouch = g == true, h == true, c == true
            if lp.guard then f = f + CFG.POSE_GUARD end
            if lp.heal then f = f + CFG.POSE_HEAL end
            if lp.crouch then f = f + CFG.POSE_CROUCH end
        end
    end
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
    json.dump_file(FILES.OUT_FILE, {
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
    local data = json.load_file(FILES.IN_FILE)
    if type(data) ~= "table" or data.seq == nil or data.x == nil then return end
    if type(data.name) == "string" and data.name ~= "" then state.remote_name = data.name end
    state.remote_count = data.recv_count or state.remote_count
    state.remote_flags = tonumber(data.flags) or 0
    if type(data.transport) == "string" then state.transport = data.transport end
    if type(data.role) == "string" then state.role = data.role end
    -- re7mp.exe's release number. The file is only written while packets arrive, so the one found when the script loads may be
    -- the leftover of an exe that is not running (or is an older release): it counts once it has been seen to CHANGE.
    if state.exe_file_seq == nil then
        state.exe_file_seq = data.seq
    elseif data.seq ~= state.exe_file_seq or state.exe_version then
        if type(data.exe) == "string" then state.exe_version = data.exe end
        if tonumber(data.proto) then state.exe_proto = tonumber(data.proto) end
    end
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

    -- Poses: what their flags say (or the panel's preview), eased in and out so the body does not snap.
    local P = state.pose
    local rf = remote_flags_now(now)
    -- (9.11) "Bob used a Remedy" also lifts the heal pose for 2.4 s: the hands animation is not a reliable sign of a heal
    -- (hands 16 / 17 play when the inventory is looked at too), the item use itself is
    local tg, th, tc = has(rf, CFG.POSE_GUARD) and 1 or 0, (has(rf, CFG.POSE_HEAL) or now < (state.remote_heal_until or 0)) and 1 or 0,
        has(rf, CFG.POSE_CROUCH) and 1 or 0
    local pv = state.pose_preview
    if pv == 2 then
        tg, th, tc = 1, 0, 0
    elseif pv == 3 then
        tg, th, tc = 0, 1, 0
    elseif pv == 5 then
        tg, th, tc = 0, 0, 1
    elseif pv == 4 then -- cycle: block 2.5 s, heal 2.5 s, crouch 2.5 s, stand 1.5 s
        local c = now % 9.0
        tg, th, tc = (c < 2.5) and 1 or 0, (c >= 2.5 and c < 5) and 1 or 0, (c >= 5 and c < 7.5) and 1 or 0
    end
    local pa = 1 - math.exp(-CFG.POSE_BLEND * dt)
    P.guard = P.guard + (tg - P.guard) * pa
    P.heal = P.heal + (th - P.heal) * pa
    P.crouch = (P.crouch or 0) + (tc - (P.crouch or 0)) * pa
    P.t = now
    if state.occ then pcall(state.occ.update, now) end
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
local function lerp3(a, b, w) return { a[1] + (b[1] - a[1]) * w, a[2] + (b[2] - a[2]) * w, a[3] + (b[3] - a[3]) * w } end

local function compute_joints(pos, fwd, amp, phase, pz)
    local hx, hz = fwd[1], fwd[3]
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl < 1e-3 then hx, hz = 0, 1 else hx, hz = hx / hl, hz / hl end
    local rx, rz = hz, -hx -- "right" on the ground plane
    local H0 = CFG.EYE_HEIGHT
    local cr = pz and pz.crouch or 0 -- 9.9: 0 standing .. 1 fully crouched
    if cr < 0 then cr = 0 elseif cr > 1 then cr = 1 end
    local H = H0 - CFG.CROUCH_DROP * cr -- where their eyes are above the floor right now
    local lean = 0.10 * cr              -- the crouching body leans forward
    local ox, oy, oz = pos.x, pos.y - H, pos.z -- point on the floor below the camera
    local function J(r, u, f) -- right / up / forward offsets from the feet -> world point
        return { ox + rx * r + hx * f, oy + u, oz + rz * r + hz * f }
    end
    local j = {
        frame = { right = { rx, 0, rz }, fwd = { hx, 0, hz }, up = { 0, 1, 0 } },
        head = { pos.x, pos.y, pos.z },
        neck = J(0, H - 0.18, lean),
        pelvis = J(0, H0 * 0.56 - 0.40 * cr, -0.05 * cr),
        shoulder = {}, hip = {}, elbow = {}, hand = {}, knee = {}, foot = {},
    }
    local sh_u = H - 0.28
    local drop_e, drop_h = H0 - 0.28 - H0 * 0.72, H0 - 0.28 - H0 * 0.55 -- elbow / hand hang this far below the shoulder
    amp = amp * (1 - 0.5 * cr) -- a crouch-walk is shorter strides
    for _, k in ipairs({ 1, -1 }) do
        local ph = phase + (k > 0 and 0 or math.pi) -- legs and arms swing in opposition
        local stride = amp * 0.32 * math.sin(ph)
        local lift = amp * 0.14 * math.max(0, math.cos(ph))
        j.shoulder[k] = J(k * 0.2, sh_u, lean * 0.8)
        j.hip[k] = J(k * 0.1, H0 * 0.56 - 0.40 * cr, -0.05 * cr)
        j.knee[k] = J(k * 0.1, H0 * 0.28 + lift * 0.5, stride * 0.6 + amp * 0.05)
        j.foot[k] = J(k * 0.1, lift, stride)
        j.elbow[k] = J(k * 0.23, sh_u - drop_e, lean * 0.8 - stride * 0.5)
        j.hand[k] = J(k * 0.23, sh_u - drop_h, lean * 0.8 - stride)
    end

    -- Poses (9.7). A pose pulls the arms to a target and settles the legs; the weights come from state.pose.
    --   guard: both forearms up in front of the face, elbows down and forward (a boxer's cover)
    --   heal:  the left forearm lies across the chest and the right hand brings the item to it, with a small pressing motion
    -- These are stand-ins for the real animations: the shapes are guesses until button 11's recording says what the game does.
    local g, h = pz and pz.guard or 0, pz and pz.heal or 0
    if g > 0.01 or h > 0.01 then
        local stand = math.max(g, h)
        for _, k in ipairs({ 1, -1 }) do
            -- legs settle to a standing stance (a slight bend for the guard)
            j.knee[k] = lerp3(j.knee[k], J(k * 0.1, H * 0.28, 0.05 + g * 0.06), stand)
            j.foot[k] = lerp3(j.foot[k], J(k * 0.1 + k * g * 0.04, 0, g * 0.05), stand)
            if g > 0.01 then
                local w = g * (1 - h)
                j.elbow[k] = lerp3(j.elbow[k], J(k * 0.19, H - 0.50, 0.17), w)
                j.hand[k] = lerp3(j.hand[k], J(k * 0.08, H - 0.10, 0.30), w)
            end
            if h > 0.01 then
                local press = 0.03 * math.sin((pz.t or 0) * 10)
                if k < 0 then -- left arm: forearm across the chest
                    j.elbow[k] = lerp3(j.elbow[k], J(-0.20, H - 0.52, 0.12), h)
                    j.hand[k] = lerp3(j.hand[k], J(0.05, H - 0.47, 0.26), h)
                else -- right arm: brings the item to the left forearm
                    j.elbow[k] = lerp3(j.elbow[k], J(0.22, H - 0.50, 0.15), h)
                    j.hand[k] = lerp3(j.hand[k], J(0.02, H - 0.40 + press, 0.29), h)
                end
            end
        end
        if h > 0.5 then j.item = j.hand[1] end -- the thing in their right hand
    end

    -- Crouch (9.9): both legs fold into a squat. The knee is the point of a two-bone leg (thigh = shin = H0*0.28) that
    -- bends forward, so the bones keep their length; blended in by how far into the crouch they are, over whatever the legs
    -- were doing (walking, or settled for a block / heal).
    if cr > 0.01 then
        local L = H0 * 0.28
        local hu, hf, ff = H0 * 0.56 - 0.40 * cr, -0.05 * cr, 0.06 * cr
        local wf, wu = ff - hf, -hu
        local d = math.sqrt(wf * wf + wu * wu)
        local half = math.min(d / 2, L)
        local off = math.sqrt(math.max(L * L - half * half, 0))
        local kf, ku = (hf + ff) / 2 + (hu / d) * off, hu / 2 + (wf / d) * off
        for _, k in ipairs({ 1, -1 }) do
            j.knee[k] = lerp3(j.knee[k], J(k * 0.1, ku, kf), cr)
            j.foot[k] = lerp3(j.foot[k], J(k * 0.1, 0, ff), cr)
        end
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
    local ty = vnorm(vsub(j.neck, j.pelvis)) -- (tilts forward when they crouch)
    local tz = vcross(R, ty)
    add(make_box(vscale(vadd(j.neck, j.pelvis), 0.5), R, ty, tz, 0.2, torso_len / 2 + 0.03, 0.11), shirt)

    -- head, turned and tilted to the look direction, with a bright visor on its front
    local right = vnorm(vcross({ 0, 1, 0 }, fwd3))
    if math.abs(fwd3[2]) > 0.97 then right = R end
    local up = vcross(fwd3, right)
    local hc = vsub(j.head, vscale(fwd3, 0.05))
    add(make_box(hc, right, up, fwd3, 0.095, 0.12, 0.11), skin)
    add(make_box(vadd(vadd(hc, vscale(fwd3, 0.105)), vscale(up, 0.015)), right, up, fwd3, 0.07, 0.03, 0.012), visor)

    -- a healing item in the right hand while they heal
    if j.item then add(make_box(vadd(j.item, vscale(F, 0.03)), R, U, F, 0.025, 0.045, 0.025), tinted(120, 255, 120)) end

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

----------------------------------------------------------------------------------------------
-- Walls (9.9). The stand-in is drawn on top of the picture, so it showed through walls and doors. This asks the game's physics
-- (a ray from your camera to four points of their body) whether something solid is in the way, and does not draw them while
-- all four points are covered. Nothing here is a hook: it only asks. If the physics calls do not work in this game, the
-- status says why, the stand-in stays visible as before, and the debug file lists what the game offers.
-- A real model (the "cloned model" route) is hidden by the game's own depth test, so this only applies to the overlay.
-- Which collision layer finds the level is not known, so the first time it casts a ray straight down in front of you for each
-- layer 0..31 and keeps (at most three of) the layers that hit the floor.
----------------------------------------------------------------------------------------------
state.occ = {
    status = "not tried yet", ready = false, setup_done = false, dead = false, dead_at = nil, blocked = false,
    layers = {}, variant = 1, calibrated = false, calib_round = 0, retry_at = 0, retries = 0, recalibrations = 0,
    steps = nil, cal_i = 0, floor_hits = { {}, {}, {} }, hit_names = {}, hit_names_n = 0,
    rays = 0, checks = 0, blocked_checks = 0, errors = 0, last_err = nil, check_at = -10, streak = 0, api = {}, methods = {},
    blocked_since = nil, blocked_from = nil,
}

function state.occ.setup()
    local O = state.occ
    O.setup_done = true
    local ok, err = pcall(function()
        O.physics = sdk.get_native_singleton("via.physics.System")
        O.ptype = sdk.find_type_definition("via.physics.System")
        if not O.physics or not O.ptype then error("via.physics.System was not found") end
        O.query = sdk.create_instance("via.physics.CastRayQuery")
        O.result = sdk.create_instance("via.physics.CastRayResult")
        if not O.query or not O.result then error("CastRayQuery / CastRayResult could not be created") end
        pcall(function() O.query:add_ref() end)
        pcall(function() O.result:add_ref() end)
    end)
    for _, tn in ipairs({ "via.physics.System", "via.physics.CastRayQuery", "via.physics.CastRayResult" }) do
        pcall(function()
            local names = {}
            for _, m in ipairs(sdk.find_type_definition(tn):get_methods() or {}) do
                if #names < 70 then
                    local nm = m:get_name()
                    -- (9.11) with the parameter types, so the two setRay and the three castRay can be told apart
                    if tn ~= "via.physics.System" or nm:find("^castRay") then
                        pcall(function()
                            local ps = {}
                            for _, pt in ipairs(m:get_param_types() or {}) do ps[#ps + 1] = pt:get_full_name() end
                            nm = nm .. "(" .. table.concat(ps, ", ") .. ")"
                        end)
                    end
                    names[#names + 1] = nm
                end
            end
            O.methods[tn] = names
        end)
    end
    if ok then
        O.ready = true
        O.status = "ray test ready: finding the collision layer"
    else
        O.dead, O.dead_at = true, os.clock()
        O.status = "unavailable (" .. tostring(err) .. "): the stand-in is not hidden behind walls"
    end
end

-- (9.11) The first debug file (build 9.9) showed no layer hit the floor, 96 rays in all. So the calibration now tries three ways
-- of casting (1: options cleared then all hits on; 2: the options left alone; 3: all hit kinds on and the filter left alone)
-- on every layer, and keeps the first way that finds the floor.
function state.occ.new_round()
    local O = state.occ
    O.steps, O.cal_i, O.floor_hits = {}, 0, { {}, {}, {} }
    for v = 1, 2 do
        for l = 0, 31 do O.steps[#O.steps + 1] = { v, l } end
    end
    O.steps[#O.steps + 1] = { 3, 0 }
end

-- Casts one ray; true = something solid is on it, false = clear, nil = the call failed.
-- A hit on the player's own body (Pl0000 ...) does not count: the ray starts next to the camera.
function state.occ.cast(layer, ax, ay, az, bx, by, bz, variant)
    local O = state.occ
    variant = variant or O.variant or 1
    local q, r = O.query, O.result
    local ok, res = pcall(function()
        q:call("setRay(via.vec3, via.vec3)", Vector3f.new(ax, ay, az), Vector3f.new(bx, by, bz))
        if variant == 1 then
            O.api.clear = pcall(q.call, q, "clearOptions")
            pcall(q.call, q, "enableAllHits")
            pcall(q.call, q, "enableNearSort")
        elseif variant == 3 then
            for _, m in ipairs({ "enableAllHits", "enableNearSort", "enableFrontFacingTriangleHits", "enableBackFacingTriangleHits",
                "enableInsideHits" }) do
                pcall(q.call, q, m)
            end
        end
        if variant ~= 3 then
            O.api.filter = pcall(function()
                local fi = q:call("get_FilterInfo")
                fi:call("set_Group", 0)
                fi:call("set_MaskBits", 4294967295)
                fi:call("set_Layer", layer)
                q:call("set_FilterInfo", fi)
            end)
        end
        sdk.call_native_func(O.physics, O.ptype, "castRay(via.physics.CastRayQuery, via.physics.CastRayResult)", q, r)
        local n = tonumber(r:call("get_NumContactPoints")) or 0
        if n == 0 then return false end
        local solid = false
        for i = 0, math.min(n, 4) - 1 do
            local name
            pcall(function() name = r:call("getContactCollidable", i):call("get_GameObject"):call("get_Name") end)
            if type(name) == "string" then
                if O.hit_names[name] == nil and O.hit_names_n < 40 then
                    O.hit_names_n = O.hit_names_n + 1
                    O.hit_names[name] = 0
                end
                if O.hit_names[name] then O.hit_names[name] = O.hit_names[name] + 1 end
            end
            if not (type(name) == "string" and name:match("^Pl%d%d%d%d") ~= nil) then solid = true end
        end
        return solid
    end)
    O.rays = O.rays + 1
    if not ok then
        O.errors = O.errors + 1
        O.last_err = tostring(res)
        O.err_run = (O.err_run or 0) + 1
        if O.err_run >= 8 then
            O.dead, O.dead_at, O.blocked = true, os.clock(), false
            O.status = "unavailable (" .. O.last_err .. "): the stand-in is not hidden behind walls"
        end
        return nil
    end
    O.err_run = 0
    return res
end

function state.occ.update(now)
    local O = state.occ
    if not state.occlude then
        O.blocked, O.status = false, "switched off"
        return
    end
    local lp, rp = state.local_pos, state.render_pos
    if O.dead and O.dead_at and now - O.dead_at > 60 and O.retries < 5 then -- (9.11) not for good: a new scene may work
        O.dead, O.dead_at, O.err_run, O.retries = false, nil, 0, O.retries + 1
        if not O.ready then O.setup_done = false end -- (the singleton / types were missing: look for them again too)
        O.status = "ray test ready: trying again"
    end
    if not lp or not rp or not state.remote or O.dead then
        O.blocked = false
        return
    end
    if now - O.check_at < 0.1 then return end -- ten tests a second are plenty
    O.check_at = now
    if not O.setup_done then O.setup() end
    if not O.ready or O.dead then
        O.blocked = false
        return
    end
    local dx, dy, dz = rp.x - lp.x, rp.y - lp.y, rp.z - lp.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist < 1.2 then -- right next to you: nothing can be between you
        O.blocked, O.streak, O.blocked_since = false, 0, nil
        return
    end
    local hl = math.sqrt(dx * dx + dz * dz)
    if hl < 0.5 then hl = 1 end
    if not O.calibrated then
        O.blocked = false
        if now < O.retry_at then return end
        if not O.steps then O.new_round() end
        -- a few rays per test so the game does not hitch: from 0.8 m toward them, 0.2 m up, 4.2 m straight down
        local sx, sz = lp.x + dx / hl * 0.8, lp.z + dz / hl * 0.8
        local n = 0
        while O.cal_i < #O.steps and n < 4 do
            n = n + 1
            local st = O.steps[O.cal_i + 1]
            local hit = O.cast(st[2], sx, lp.y + 0.2, sz, sx, lp.y - 4.0, sz, st[1])
            if hit == nil then return end
            O.cal_i = O.cal_i + 1
            if hit then
                local fh = O.floor_hits[st[1]]
                fh[#fh + 1] = st[2]
            end
        end
        if O.cal_i >= #O.steps then
            O.calib_round = O.calib_round + 1
            local pv
            for v = 1, 3 do
                if #O.floor_hits[v] > 0 then pv = v break end
            end
            if pv then
                local picked = {}
                for _, l in ipairs(O.floor_hits[pv]) do
                    if #picked < 3 then picked[#picked + 1] = l end
                end
                O.layers, O.variant, O.calibrated = picked, pv, true
                O.status = "working (collision layers " .. table.concat(picked, ", ") .. ")" .. (pv ~= 1 and (", way " .. pv) or "")
            else
                O.steps = nil -- the next try starts from scratch (maybe there was no floor under that spot)
                O.retry_at = now + 45
                O.status = "unavailable (no collision layer found the floor): the stand-in is not hidden behind walls (trying again in 45 s)"
            end
        end
        return
    end
    -- four points of their body, eyes down to the feet
    local crouch = (state.pose and state.pose.crouch) or 0
    local he = CFG.EYE_HEIGHT - CFG.CROUCH_DROP * crouch
    local offsets = { 0.05, he * 0.40, he * 0.75, math.max(he - 0.2, 0.3) }
    local clear = false
    for _, off in ipairs(offsets) do
        local tx, ty, tz = rp.x, rp.y - off, rp.z
        local vx, vy, vz = tx - lp.x, ty - lp.y, tz - lp.z
        local vl = math.sqrt(vx * vx + vy * vy + vz * vz)
        if vl < 0.7 then
            clear = true
            break
        end
        vx, vy, vz = vx / vl, vy / vl, vz / vl
        local ax, ay, az = lp.x + vx * 0.3, lp.y + vy * 0.3, lp.z + vz * 0.3 -- start outside your own body
        local bx, by, bz = tx - vx * 0.12, ty - vy * 0.12, tz - vz * 0.12   -- and stop short of the floor / wall behind them
        local covered = false
        for _, layer in ipairs(O.layers) do
            if O.cast(layer, ax, ay, az, bx, by, bz, O.variant) == true then
                covered = true
                break
            end
        end
        if not covered then
            clear = true
            break
        end
    end
    O.checks = O.checks + 1
    if clear then
        O.streak = 0
        O.blocked = false
    else
        O.streak = O.streak + 1
        O.blocked_checks = O.blocked_checks + 1
        if O.streak >= 2 then O.blocked = true end -- (twice in a row: one odd frame does not make them blink)
    end
    -- (9.11) a wall does not follow you: "behind a wall" for 30 s while you walk 8 m means the layers are wrong. Calibrate again.
    if O.blocked then
        if not O.blocked_since then O.blocked_since, O.blocked_from = now, { lp.x, lp.z } end
        local mx, mz = lp.x - O.blocked_from[1], lp.z - O.blocked_from[2]
        if now - O.blocked_since > 30 and mx * mx + mz * mz > 64 then
            O.calibrated, O.layers, O.steps, O.blocked, O.streak, O.blocked_since = false, {}, nil, false, 0, nil
            O.recalibrations = O.recalibrations + 1
            O.status = "ray test ready: they stayed 'behind a wall' while you walked, calibrating again"
            say("walls: calibrating again (they stayed behind a wall while I walked 8 m)")
        end
    else
        O.blocked_since = nil
    end
end

function state.occ.report()
    local O = state.occ
    local fh = {}
    for v = 1, 3 do fh[tostring(v)] = O.floor_hits[v] end
    local names = {}
    for nm, c in pairs(O.hit_names) do names[#names + 1] = { name = nm, hits = c } end
    table.sort(names, function(a, b) return a.hits > b.hits end)
    while #names > 15 do table.remove(names) end
    return { status = O.status, ready = O.ready, calibrated = O.calibrated, layers = O.layers, way_used = O.variant,
        floor_hit_layers_by_way = fh, calibration_rounds = O.calib_round, retries = O.retries, recalibrations = O.recalibrations,
        rays = O.rays, checks = O.checks, blocked_checks = O.blocked_checks, errors = O.errors, last_error = O.last_err,
        api_ok = O.api, hidden_now = O.blocked, things_the_rays_hit = names, methods = O.methods }
end

-- Why the OVERLAY (not a cloned model) should not be drawn right now, or nil.
state.overlay_hidden = function(now)
    local why = remote_hidden(now)
    if why then return why end
    local M = CFG.menu
    if state.menu_hide and M and M.open then return "a game menu is open (" .. tostring(M.which) .. ")" end
    if state.occlude and state.occ.blocked then return "behind a wall or door" end
    return nil
end

local function draw_remote(now)
    if not state.show_figure or not state.remote or not state.render_pos then return end
    if avatar.obj and not avatar.show_skeleton then return end -- a cloned model is standing in
    if state.overlay_hidden(now) then return end
    local stale = (now - state.remote_changed_at) > CFG.STALE_AFTER
    local color = stale and 0xFF888888 or 0xFF00FF00
    local label = state.remote_name or CFG.DEFAULT_NAME
    if stale then label = label .. " (no signal)" end
    local is_down = false
    if state.tag_extra and not stale then -- health module: " HP 65%" or " [downed]"
        local okx, extra, xcolor, down = pcall(state.tag_extra)
        if okx and type(extra) == "string" then
            label = label .. extra
            if xcolor then color = xcolor end
            is_down = down == true
        end
    end
    local amp = math.max(0, math.min(1, (state.speed - 0.15) / 1.8))
    local pos, fwd = state.render_pos, state.render_fwd
    local P = state.pose
    if not stale and not is_down then -- (nobody is "healing" or "blocking" while down: the tag says [downed])
        if P.heal > 0.5 then
            label = label .. " [healing]"
        elseif P.guard > 0.5 then
            label = label .. " [blocking]"
        elseif (P.crouch or 0) > 0.5 then
            label = label .. " [crouching]"
        end
    end
    amp = amp * (1 - 0.85 * math.max(P.guard, P.heal)) -- no walking legs while they block or heal
    local j = compute_joints(pos, fwd, amp, state.walk_phase, P)
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
        json.dump_file(FILES.MSG_OUT_FILE, { msgs = netmsg.outbox })
    end
end

-- Remember what is already in the inbox so old messages are not replayed after a script reload.
local function prime_messages()
    local d = json.load_file(FILES.MSG_IN_FILE)
    if type(d) ~= "table" or type(d.msgs) ~= "table" then return end
    netmsg.epoch = d.epoch
    for _, m in ipairs(d.msgs) do
        if type(m) == "table" and type(m.n) == "number" and m.n > netmsg.last_n then netmsg.last_n = m.n end
    end
end

local function read_messages()
    local d = json.load_file(FILES.MSG_IN_FILE)
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
local function field_label(name)
    return (name:gsub("^<(.-)>k__BackingField$", "%1"))
end

-- Methods the 2026-11 item trace showed firing thousands of times a second (every frame, per item).
local TRACE_SKIP = {
    set_weapon = true, set_ItemSlotManager = true, set_ItemData = true, itemMegusuriDisp = true,
    getTotalStackNum = true, getItemDataId = true, hasWeaponInQuickslot = true, isDisplayShotGun = true,
    set_ItemBoxData = true,
    -- called every frame (a debug file measured 16000 and 284 calls a second): hooking them only costs frames
    set_eventSetting = true, set_eventRoot = true, findItemDataInternal = true,
    findCombineDataByResultItem = true, findCombineDataBySourceItem = true,
    -- measured in the 9.5 door trace: 13066, 3219, 1250, 588 and 355 calls a second. Hooking them only costs frames.
    set_timelineKickers = true, waitFsmExecuteCheck = true, isMotionJack = true, existNear = true, notifyInKnockArea = true,
}
-- Called hundreds of times a second with the same arguments (the UI flags CanOpenMap, CanOpenInventory ... are set every
-- frame): a call is only logged when its arguments differ from the call before.
local TRACE_CHANGED = { setFsmGlobalBoolValue = true, setFsmGlobalIntValue = true }
-- Object arguments of these types are written out field by field (numbers, flags, text only), so a traced
-- damage call shows how much damage, from which weapon, to which part.
local TRACE_EXPAND = {
    ["app.DamageController.DamageRecord"] = true,
    ["app.Collision.HitController.DamageInfo"] = true,
    ["app.HealthInfo"] = true,
}

local function compact_fields(o, limit)
    local parts = {}
    pcall(function()
        local t = o:get_type_definition()
        while t and #parts < limit do
            local tn = t:get_full_name()
            if tn:find("^System%.") or tn:find("^via%.Component") then break end
            for _, f in ipairs(t:get_fields() or {}) do
                if #parts >= limit then break end
                if not f:is_static() then
                    local ok, v = pcall(function() return o:get_field(f:get_name()) end)
                    if ok and (type(v) == "number" or type(v) == "boolean") then
                        parts[#parts + 1] = field_label(f:get_name()) .. "=" .. tostring(v)
                    elseif ok and type(v) == "string" then
                        parts[#parts + 1] = field_label(f:get_name()) .. "=\"" .. v:sub(1, 30) .. "\""
                    end
                end
            end
            t = t:get_parent_type()
        end
    end)
    return table.concat(parts, " ")
end

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

-- Breadcrumb for crashes. The debug file is only written every two seconds, so the last traced calls before a crash are
-- never in it. This tiny file is rewritten around every traced call instead:
--   "hooking X"  the game stopped while the hook on X was being installed (the hook is the suspect)
--   "enter X"    the game stopped while this script was reading X's arguments (the script is the suspect)
--   "done X"     the game stopped after the script had finished with X (the game itself, or a call that is not traced)
-- The next session reads it back and says what it found (tracer.report_previous).
tracer.CRUMB_FILE = "re7mp_lastcall.json"
tracer.session = os.time()
tracer.crumb_t, tracer.crumb_n = 0, 0
function tracer.crumb(stage, key)
    local now = os.clock()
    if now - tracer.crumb_t >= 1 then tracer.crumb_t, tracer.crumb_n = now, 0 end
    tracer.crumb_n = tracer.crumb_n + 1
    if tracer.crumb_n > 400 then return end -- a burst (a chapter loading): at most 400 writes a second
    pcall(json.dump_file, tracer.CRUMB_FILE, { stage = stage, call = key, clock = now, time = os.time(), session = tracer.session })
end

function tracer.report_previous()
    local ok, d = pcall(json.load_file, tracer.CRUMB_FILE)
    if not ok or type(d) ~= "table" or d.session == tracer.session or type(d.call) ~= "string" then return end
    local age = type(d.time) == "number" and math.max(0, os.time() - d.time) or nil
    local when = age and string.format(" (%d min ago)", math.floor(age / 60)) or ""
    local text
    if d.stage == "hooking" then
        text = "The last session ended while the trace was installing its hook on " .. d.call .. when .. ". If the game crashed, that hook is the suspect."
    elseif d.stage == "enter" then
        text = "The last session ended while the trace was reading the arguments of " .. d.call .. when .. ". If the game crashed, that call is the suspect."
    elseif d.stage == "done" then
        text = "The last traced call of the last session was " .. d.call .. when .. " and it had finished. If the game crashed, it was in the game or in a call that is not traced."
    elseif d.stage == "recorder" then
        text = "The last session ended while the recorder (button 11) was at: " .. d.call .. when .. ". If the game crashed, that is the suspect: tell me."
    elseif d.stage == "give" then
        text = "The last session ended while the script was handling an item: " .. d.call .. when .. ". If the game crashed, that call is the suspect: tell me."
    elseif d.stage == "revive" then
        text = "The last session ended while the script was finishing an F8 revive: " .. d.call .. when .. ". If the game crashed, that is the suspect: tell me."
    else
        return -- "clean": the scripts were reset normally
    end
    tracer.previous = text
    say("previous session: " .. text)
end

-- Reference types are read as objects; value types (numbers, enums, structs) are only shown as raw numbers,
-- because treating a plain number as an object pointer could crash the game.
local function describe_arg(pt, args, idx)
    local ok, text = pcall(function()
        local n = pt.name
        -- args[1] is the thread, args[2] the object, args[3] and args[4] the first two parameters (a float uses up its slot).
        -- Anything after that is not in a register: it reads as garbage (a 1962800054277 where an EaseType should be), and
        -- treating garbage as an object pointer can crash the game, so a late object is never opened.
        local late = idx > 4
        if pt.ref and late then return "<" .. n .. ": not readable>" end
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
            if TRACE_EXPAND[n] then return "<" .. n .. " " .. compact_fields(o, 16) .. ">" end
            return "<" .. n .. ">"
        end
        if n == "System.Boolean" then return tostring(sdk.to_int64(args[idx]) % 256 ~= 0) .. (late and "?" or "") end
        -- floats travel in a floating-point register, not in args: reading them gave garbage (3e27) in the 2026-11 trace
        if n == "System.Single" then return "<float: can't be read in a hook>" end
        local v = sdk.to_int64(args[idx])
        if n == "System.Int32" or n:find("^app%.") then
            v = v % 4294967296
            if v >= 2147483648 then v = v - 4294967296 end
        end
        return tostring(v) .. (late and "?" or "") -- a "?" marks a value from past the registers: not trustworthy
    end)
    return ok and text or ("<" .. tostring(pt.name) .. ">") -- can't read it: show its type instead
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
    if tracer.hooked[key] then return false, "already" end
    tracer.hooked[key] = true

    local CALL_ORIGINAL = sdk.PreHookResult and sdk.PreHookResult.CALL_ORIGINAL
    local changed_only = TRACE_CHANGED[mname] == true
    local function render(args)
        local parts = {}
        for i, pt in ipairs(ptypes) do parts[i] = describe_arg(pt, args, i + (is_static and 1 or 2)) end
        return parts
    end
    sdk.hook(m, function(args)
        pcall(function()
            if not tracer.enabled then return end
            local now = os.clock()
            local e = tracer.rate[key] or { t = 0, n = 0, dropped = 0, muted = false }
            tracer.rate[key] = e
            if e.muted then return end
            local parts
            if changed_only then -- read the arguments first: only a call that differs from the one before is counted
                if not e.crumbed then
                    e.crumbed = true
                    tracer.crumb("enter", key)
                end
                parts = render(args)
                local shown = table.concat(parts, ", ")
                if shown == e.last_shown then return end
                e.last_shown = shown
            end
            if now - e.t > 1 then
                if e.dropped > 200 then -- fires every frame: say so once and stop logging it
                    e.muted = true
                    tracer_add(type_name .. "." .. mname .. ": fires " .. e.dropped .. "+ times a second, muted")
                    return
                elseif e.dropped > 0 then
                    tracer_add(type_name .. "." .. mname .. ": " .. e.dropped .. " more calls in the last second")
                end
                e.t, e.n, e.dropped = now, 0, 0
            end
            e.n = e.n + 1
            if e.n > 3 then
                e.dropped = e.dropped + 1
                return
            end
            tracer.crumb("enter", key)
            if not e.sig_logged then -- the full signature, once, so unreadable arguments can be identified
                e.sig_logged = true
                tracer_add("signature: " .. key)
            end
            parts = parts or render(args)
            -- which GameObject the call is on (for components: "[on Em3100]"), so a damage call says whom it hit
            local owner = ""
            if not is_static then
                pcall(function()
                    local so = sdk.to_managed_object(args[2])
                    local go = so and so:call("get_GameObject")
                    local nm = go and go:call("get_Name")
                    if type(nm) == "string" then owner = "  [on " .. nm .. "]" end
                end)
                -- plain objects have no GameObject: the health module can still say "this is the player's HealthInfo"
                if owner == "" and tracer.owner_hint then
                    local okh, hint = pcall(tracer.owner_hint, args)
                    if okh and type(hint) == "string" then owner = hint end
                end
            end
            tracer_add(string.format("%s.%s(%s)%s", type_name, mname, table.concat(parts, ", "), owner))
            tracer.crumb("done", key)
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
        local added, skipped, already = 0, 0, 0
        -- filter: one piece of text, or a list of words (a method matches if its name contains any of them)
        -- a word starting with "=" is an exact method name (any other word matches part of a name)
        local words, exact, has_exact = {}, {}, false
        if type(filter) == "table" then
            for _, w in ipairs(filter) do
                if w:sub(1, 1) == "=" then
                    exact[w:sub(2):lower()] = true
                    has_exact = true
                else
                    words[#words + 1] = w:lower()
                end
            end
        elseif filter and filter ~= "" then
            words[1] = filter:lower()
        end
        for _, m in ipairs(td:get_methods() or {}) do
            local name = m:get_name()
            local low = name:lower()
            local wanted = #words == 0 and not has_exact
            if exact[low] then wanted = true end
            for _, w in ipairs(words) do
                if low:find(w, 1, true) then wanted = true break end
            end
            local skip = low:find("update", 1, true) ~= nil or name == ".ctor" or name == ".cctor" or name == "doAwake"
                or low == "doondestroy" or low == "finalize" or low == "dispose" -- objects being taken apart: never touched
                or TRACE_SKIP[name] == true
                or (not include_getters and low:sub(1, 4) == "get_")
                or not wanted
            local hooked, why = false, nil
            if not skip and tracer.hook_count < 600 then
                tracer.crumb("hooking", type_name .. "." .. name)
                hooked, why = trace_method(type_name, m)
            end
            if hooked then
                added = added + 1
                tracer.hook_count = tracer.hook_count + 1
            elseif why == "already" then
                already = already + 1
            else
                skipped = skipped + 1
            end
        end
        tracer_add(string.format("%s: tracing %d new methods (%d were already traced, %d skipped)", type_name, added, already, skipped))
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
    "app.GameManager", "app.SaveDataManager", "app.Inventory", "app.Item", "app.ItemData", "app.ItemManager", "app.SupplyBoxData",
    "app.EnemyManager", "app.EventManager", "app.PlayerManager", "app.CharacterManager", "app.MapManager",
}

local function pinned(fn)
    dbg.pin = true
    local ok, err = pcall(fn)
    dbg.pin = false
    if not ok then say("collector error: " .. tostring(err)) end
end

local function collect_info()
    pinned(function()
        probe.lines = {}
        say("=== collect: new-game method signatures ===")
        probe_signatures()
        for _, n in ipairs(COLLECT_TYPES) do
            say("=== collect: " .. n .. " ===")
            probe_type(n, true, nil, 250)
        end
        say("=== collect: done ===")
    end)
end

-- Lists GameObjects that look like enemies (a component type containing "enemy" or starting with app.Em, or a
-- name like em1234), then every component type present in the scene with a count. The second list shows what
-- the game calls its characters even if the first guess misses.
local function scan_enemies()
    pinned(function()
        say("=== enemy scan ===")
        local found, seen = 0, 0
        local census = {}
        local ok, err = pcall(each_gameobject, function(go, path)
            seen = seen + 1
            local name_hit = path:lower():find("/em%d%d%d%d") ~= nil
            local okc, comps = pcall(component_names, go)
            local comp_hit = false
            if okc then
                for _, c in ipairs(comps) do
                    census[c] = (census[c] or 0) + 1
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
        end, 20000)
        if not ok then say("enemy scan error: " .. tostring(err)) end
        say(string.format("=== enemy scan done: %d candidates among %d objects ===", found, seen))
        say("=== component types in the scene (name x count) ===")
        local names = {}
        for n in pairs(census) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            if n:find("^app%.") then say(n .. " x" .. census[n]) end
        end
        say("=== component census done ===")
    end)
end

----------------------------------------------------------------------------------------------
-- Item sync, version 1: an item one player picks up from the world disappears for the other player.
--
-- Based on the item trace: picking something up runs app.Inventory.addItem(app.Item, ...) on the item that
-- lies in the world, and the game then removes that item with app.Item.disableFromScene(). Crafting and
-- restoring an inventory also call addItem, but on items created under the player object "Pl0000", which
-- is how those are told apart from world pickups. The message carries the item's id, its object name and its
-- position; the other game finds the object with that name near that position and removes it the same way.
-- Not synced yet: items that come out of drawers/containers, ammo use, "both players get the item".
----------------------------------------------------------------------------------------------
-- (9.11) Ethan is Pl0000 but Mia's chapters have Pl2000 (the first debug file lists both): any Pl followed by four digits is a player.
local function is_player_name(n) return type(n) == "string" and n:match("^Pl%d%d%d%d$") ~= nil end

local ITEM_MSG = 3
local items = {
    enabled = true,
    sent = 0, received = 0, removed = 0, missed = 0,
    suppress_until = 0,
    last = "No item events yet.",
    hooked = false,
}

local function item_note(text)
    items.last = text
    say("item sync: " .. text)
end

-- Is this GameObject the player or one of its children (an inventory item rather than a world item)?
local function is_under_player(go)
    local node = go
    for _ = 1, 10 do
        if not node then return false end
        if is_player_name(node:call("get_Name")) then return true end
        local xf = node:call("get_Transform")
        local parent = xf and xf:call("get_Parent")
        node = parent and parent:call("get_GameObject") or nil
    end
    return false
end

-- Runs just before the game adds an item to the inventory.
local function on_item_added(args)
    if not items.enabled or os.clock() < items.suppress_until then return end
    local item = sdk.to_managed_object(args[3])
    if not item then return end
    local go = item:call("get_GameObject")
    if not go or is_under_player(go) then return end -- crafting or restoring the inventory, not a pickup
    local id = tostring(item:call("getItemDataId"))
    local name = tostring(go:call("get_Name"))
    local p = go:call("get_Transform"):call("get_Position")
    if name:find("|", 1, true) or id:find("|", 1, true) then return end
    net_send(ITEM_MSG, string.format("%s|%s|%.2f|%.2f|%.2f", id, name, p.x, p.y, p.z))
    items.sent = items.sent + 1
    item_note(string.format("you picked up %s (%s) at %.1f, %.1f, %.1f", id, name, p.x, p.y, p.z))
end

local function remove_world_item(id, name, x, y, z)
    local best, best_d2
    local ok, err = pcall(each_gameobject, function(go)
        local okn, n = pcall(function() return go:call("get_Name") end)
        if not (okn and n == name) then return end
        local okp, p = pcall(function() return go:call("get_Transform"):call("get_Position") end)
        if not (okp and p) then return end
        local d2 = (p.x - x) ^ 2 + (p.y - y) ^ 2 + (p.z - z) ^ 2
        if d2 < 0.75 ^ 2 and (best_d2 == nil or d2 < best_d2) then
            best, best_d2 = go, d2
            if d2 < 0.05 ^ 2 then return true end -- an exact match: stop searching
        end
    end, 30000)
    if not ok then
        item_note("search failed: " .. tostring(err))
        return
    end
    if not best then
        items.missed = items.missed + 1
        item_note(string.format("%s picked up %s (%s) but I can't find it near %.1f, %.1f, %.1f",
            state.remote_name or CFG.DEFAULT_NAME, id, name, x, y, z))
        return
    end
    items.suppress_until = os.clock() + 1
    local removed, how = pcall(function()
        local comp = best:call("getComponent(System.Type)", sdk.typeof("app.Item"))
        if not comp then error("no app.Item component") end
        comp:call("disableFromScene") -- what the game itself calls on a picked-up world item
    end), "disableFromScene"
    if not removed then
        how = "destroy"
        removed = pcall(function() best:call("destroy", best) end)
    end
    if removed then
        items.removed = items.removed + 1
        item_note(string.format("%s took %s: removed it here (%s)", state.remote_name or CFG.DEFAULT_NAME, id, how))
    else
        items.missed = items.missed + 1
        item_note(string.format("%s took %s: found it but could not remove it", state.remote_name or CFG.DEFAULT_NAME, id))
    end
end

net_on(ITEM_MSG, function(payload)
    local id, name, x, y, z = payload:match("^([^|]*)|([^|]*)|(-?[%d%.]+)|(-?[%d%.]+)|(-?[%d%.]+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (id and name and x and y and z) then return end
    items.received = items.received + 1
    if items.enabled then remove_world_item(id, name, x, y, z) end
end)

local function install_item_hooks()
    local td = sdk.find_type_definition("app.Inventory")
    local m = td and td:get_method("addItem")
    if not m then
        say("item sync: app.Inventory.addItem not found, item sync is off")
        return false
    end
    local CALL_ORIGINAL = sdk.PreHookResult and sdk.PreHookResult.CALL_ORIGINAL
    sdk.hook(m, function(args)
        local ok, err = pcall(on_item_added, args)
        if not ok then say("item sync hook error: " .. tostring(err)) end
        return CALL_ORIGINAL
    end, function(retval) return retval end)
    return true
end

----------------------------------------------------------------------------------------------
-- Finding the game's managers and calling it with strings.
-- RE7's managers are not always reachable as singletons, so the hooks below also remember the instances
-- they see. Everything here is wrapped in pcall by its callers: a failure is reported, never thrown.
----------------------------------------------------------------------------------------------
local mgr = { item_manager = nil, inventory = nil, player = nil, player_checked = 0 }

local function managed_string(s)
    local ok, ms = pcall(function() return sdk.create_managed_string(s) end)
    if ok and ms ~= nil then return ms end
    return s
end

-- obj:call(method, ...) where some arguments are Lua strings: tries plain strings first, then managed ones.
-- Returns true plus the result, or false plus the error text.
local function call_str(obj, method, ...)
    local n = select("#", ...)
    local args = { ... }
    local ok, res = pcall(function() return obj:call(method, table.unpack(args, 1, n)) end)
    if ok then return true, res end
    local conv = {}
    for i = 1, n do
        local a = args[i]
        conv[i] = type(a) == "string" and managed_string(a) or a
    end
    local ok2, res2 = pcall(function() return obj:call(method, table.unpack(conv, 1, n)) end)
    if ok2 then return true, res2 end
    return false, tostring(res2)
end

local function hook_method(type_name, method_name, pre, post)
    local td = sdk.find_type_definition(type_name)
    local m = td and td:get_method(method_name)
    if not m then
        say("hook: " .. type_name .. "." .. method_name .. " not found")
        return false
    end
    local CALL_ORIGINAL = sdk.PreHookResult and sdk.PreHookResult.CALL_ORIGINAL
    local errors = 0
    sdk.hook(m, function(args)
        local ok, err = pcall(pre, args)
        if not ok then
            errors = errors + 1
            if errors <= 3 then say("hook error in " .. method_name .. ": " .. tostring(err)) end -- (9.13: three times, not for ever)
        end
        return CALL_ORIGINAL
    end, function(retval)
        if post then
            local ok, err = pcall(post, retval)
            if not ok then
                errors = errors + 1
                if errors <= 3 then say("hook error after " .. method_name .. ": " .. tostring(err)) end
            end
        end
        return retval
    end)
    return true
end

local function find_named_object(name, max_nodes)
    local found
    pcall(each_gameobject, function(go)
        local ok, n = pcall(function() return go:call("get_Name") end)
        if ok and n == name then
            found = go
            return true
        end
    end, max_nodes)
    return found
end

-- (9.13) WHICH copy of the item manager? In the 0.7 and 0.8 files the one sdk.get_managed_singleton gives was an empty shell:
-- findItemData("Herb"), get_ItemDataIDNames and every create call answered nil, so no item could be created or dropped. The
-- game's real manager sits on the object "SystemObject" (the older traces show findItemDataInternal "[on SystemObject]"). So the
-- copies are collected (components in the scene, the one on SystemObject, the singleton) and the first that knows an item wins.
function mgr.im_knows(c)
    for _, id in ipairs({ "Herb", "HandgunBullet", "Knife" }) do
        local ok, d = pcall(function() return c:call("findItemData", id) end)
        if ok and d ~= nil then return true end
    end
    return false
end

function mgr.im_candidates(walk)
    local out = {}
    local function add(how, obj)
        if obj ~= nil then out[#out + 1] = { how = how, obj = obj } end
    end
    local scene = scene_object()
    if scene then
        pcall(function()
            local arr = scene:call("findComponents(System.Type)", sdk.typeof("app.ItemManager"))
            for i, c in ipairs(arr:get_elements() or {}) do
                if i > 4 then break end
                add("a component found in the scene", c)
            end
        end)
    end
    if walk and #out == 0 then
        pcall(function()
            local go = find_named_object("SystemObject", 4000)
            if go then add("the component on SystemObject", go:call("getComponent(System.Type)", sdk.typeof("app.ItemManager"))) end
        end)
    end
    local ok, s = pcall(sdk.get_managed_singleton, "app.ItemManager")
    if ok then add("the managed singleton", s) end
    -- (9.14) The game's own copy is a candidate only if it knows items: in the 9.13 file it did not (findItemData -> nil), it
    -- replaced the good copy at the next craft, and every creation after that failed.
    if mgr.captured_im and mgr.im_knows(mgr.captured_im) then add("the one the game's own createItemInstance call used", mgr.captured_im) end
    return out
end

local function item_manager()
    local now = os.clock()
    if mgr.item_manager and mgr.item_manager_ok then return mgr.item_manager end
    if mgr.item_manager and now < (mgr.item_manager_next or 0) then return mgr.item_manager end
    -- (until one that knows items turns up the search repeats, further and further apart: a walk of the scene is not free)
    mgr.item_manager_wait = math.min((mgr.item_manager_wait or 7.5) * 2, 120)
    mgr.item_manager_next = now + mgr.item_manager_wait
    local list, best, first = {}, nil, nil
    for _, c in ipairs(mgr.im_candidates(true)) do
        local knows = mgr.im_knows(c.obj)
        list[#list + 1] = { how = c.how, knows_items = knows }
        if knows and not best then best = c end
        first = first or c
    end
    mgr.item_manager_list = list
    local pick = best or first
    if pick then
        local key = pick.how .. tostring(best ~= nil)
        mgr.item_manager, mgr.item_manager_how, mgr.item_manager_ok = pick.obj, pick.how, best ~= nil
        if mgr.item_manager_said ~= key then
            mgr.item_manager_said = key
            say(string.format("item manager: using %s (%s); %d copies looked at", pick.how,
                best and "it knows the items" or "NONE of the copies knows an item, so creating items will fail", #list))
        end
    end
    return mgr.item_manager
end

-- The player's GameObject (Pl0000 for Ethan, Pl2000 for Mia ...): remembered from hooks, or searched for (at most every 3
-- seconds). When there are several, the one nearest the camera is the one being played. A single one is looked for again
-- only once a minute (the scan walks the whole scene), several every 5 seconds.
local function player_object()
    local now = os.clock()
    if mgr.player then
        local ok, n = pcall(function() return mgr.player:call("get_Name") end)
        if ok and is_player_name(n) then
            if now - (mgr.player_scan_at or -1000) < (mgr.player_multi and 5 or 60) then return mgr.player end
        else
            mgr.player = nil
        end
    end
    if now - mgr.player_checked < 3 then return mgr.player end
    mgr.player_checked = now
    local cands = {}
    pcall(each_gameobject, function(go)
        local okn, n = pcall(function() return go:call("get_Name") end)
        if okn and is_player_name(n) then cands[#cands + 1] = go end
    end, 20000)
    mgr.player_scan_at, mgr.player_multi, mgr.player_cands = now, #cands > 1, #cands
    local best
    if #cands == 1 then
        best = cands[1]
    elseif #cands > 1 then
        local cam, bd = state.local_pos, nil
        if not cam then -- (no camera position yet: take the first for now and look again in a second)
            mgr.player_scan_at, mgr.player_checked = now - 4, now - 2
        end
        for _, go in ipairs(cands) do
            local okp, p = pcall(function() return go:call("get_Transform"):call("get_Position") end)
            local d = (okp and p and cam) and ((p.x - cam.x) ^ 2 + (p.y - cam.y) ^ 2 + (p.z - cam.z) ^ 2) or 1e18
            if bd == nil or d < bd then best, bd = go, d end
        end
    end
    if best then
        local okn, n = pcall(function() return best:call("get_Name") end)
        n = okn and n or nil
        if n ~= mgr.player_name then say("player object: " .. tostring(n) .. " (" .. #cands .. " found)") end
        mgr.player_name = n
        mgr.player = best
    end
    return mgr.player
end

local function inventory_object()
    if mgr.inventory then return mgr.inventory end
    local p = player_object()
    if p then
        local ok, comp = pcall(function() return p:call("getComponent(System.Type)", sdk.typeof("app.Inventory")) end)
        if ok and comp then mgr.inventory = comp end
    end
    if not mgr.inventory then
        local ok, inv = pcall(sdk.get_managed_singleton, "app.Inventory")
        if ok and inv then mgr.inventory = inv end
    end
    return mgr.inventory
end

local function peer_present(now)
    return state.remote ~= nil and (now or os.clock()) - state.remote_changed_at < CFG.STALE_AFTER
end

-- Compact text for a value read from a field, for the debug file.
local function dump_value(v)
    local t = type(v)
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "string" then return "\"" .. v:sub(1, 60) .. "\"" end
    if t == "nil" then return "nil" end
    if t == "userdata" then
        local ok, s = pcall(function()
            if v.x ~= nil and v.y ~= nil and v.z ~= nil then return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z) end
            local td = v:get_type_definition()
            return td and ("<" .. td:get_full_name() .. ">") or tostring(v)
        end)
        return ok and s or "<object>"
    end
    return "<" .. t .. ">"
end

-- Writes every instance field of a component (and of its app.* parent types) with its current value.
local function dump_fields(obj, indent, limit)
    local shown = 0
    local ok, err = pcall(function()
        local t = obj:get_type_definition()
        while t and shown < limit do
            local tname = t:get_full_name()
            if tname:find("^System%.") or tname:find("^via%.Component") or tname:find("^via%.Behavior") then break end
            for _, f in ipairs(t:get_fields() or {}) do
                if shown >= limit then break end
                if not f:is_static() then
                    shown = shown + 1
                    local fname = f:get_name()
                    local ft = f:get_type()
                    local okv, v = pcall(function() return obj:get_field(fname) end)
                    say(string.format("%s%s : %s = %s", indent, fname, ft and ft:get_full_name() or "?",
                        okv and dump_value(v) or "(unreadable)"))
                end
            end
            t = t:get_parent_type()
        end
    end)
    if not ok then say(indent .. "(field dump failed: " .. tostring(err) .. ")") end
end

-- Fields of obj (with parents) whose declared type is type_name: returns { {name, value}, ... }.
local function fields_of_type(obj, type_name)
    local out = {}
    pcall(function()
        local t = obj:get_type_definition()
        while t do
            local tn = t:get_full_name()
            if tn:find("^System%.") or tn:find("^via%.Component") or tn:find("^via%.Behavior") then break end
            for _, f in ipairs(t:get_fields() or {}) do
                local ft = f:get_type()
                if not f:is_static() and ft and ft:get_full_name() == type_name then
                    local okv, v = pcall(function() return obj:get_field(f:get_name()) end)
                    if okv and v ~= nil then out[#out + 1] = { f:get_name(), v } end
                end
            end
            t = t:get_parent_type()
        end
    end)
    return out
end

----------------------------------------------------------------------------------------------
-- Item transfer. Two ways to hand things to the other player:
--   A. "Give": a hotkey (F7) or the panel button hands over the item highlighted in the inventory. It leaves
--      your inventory (app.Inventory.reduceItem) and is created in theirs (createItemInstance + addItem, the
--      same calls the game makes when you craft). If their inventory is full, or the direct add fails, it
--      appears on the ground at their feet instead, so nothing is ever lost.
--   B. "Discard drops it": discarding in the inventory runs app.Item.reduceNum(count, player) (seen in the
--      item trace). With this option on, the item is also spawned on the ground at your feet
--      (app.ItemManager.createDropItemInstance, what drawers use) and the other player sees it appear
--      at the same spot. Picking it up is then ordinary item sync.
-- Messages: 5 = give "id|count", 6 = world drop "id|count|x|y|z".
-- All of this is built from the trace, not yet tried in the game: the panel says which path was used.
----------------------------------------------------------------------------------------------
local GIVE_MSG, DROP_MSG, GIVE_ACK_MSG = 5, 6, 10
local dump_focused_item -- defined further down (the debug collectors)
local give = {
    drop_on_discard = true,
    hint = true,
    hotkey = 0x76, -- F7
    key_was_down = false,
    focus = nil,   -- the item highlighted in the inventory: { item, id, count, at }
    pending_drop = nil,
    hover_seen = 0,
    want_dump = nil, auto_dump_at = -1e9, -- set when something unreadable should be written to the debug file by itself
    inv_list = nil, inv_note = nil, inv_at = -10, inv_dirty = false,
    hooked = false,
    sent = 0, received = 0, dropped = 0, failed = 0,
    out = {},    -- (9.11) what I sent and have no answer for yet: { kind = "g"/"d", id, n, at }
    inbox = {},  -- (9.11) gifts that arrived while the game could not take them yet (no player object): { id, n, tries, next_at }
    last = "Nothing given or dropped yet.",
}

local function give_note(text)
    give.last = text
    say("give: " .. text)
    chat_add("Items", text)
end

-- A string coming back from the game may be a Lua string or a managed System.String object.
local function as_text(v)
    if type(v) == "string" then return v end
    if v == nil or type(v) == "number" or type(v) == "boolean" then return nil end
    local ok, t = pcall(function() return v:call("ToString()") end)
    if ok and type(t) == "string" then return t end
    return nil
end

give.id_getters = { "getItemDataId", "get_ItemDataId", "getItemId", "get_ItemId", "getName", "get_Name", "getItemName", "get_ItemName" }
give.count_getters = { "getTotalStackNum", "get_StackNum", "getStackNum", "get_Num", "getNum" }

-- Item names are letters, digits and underscores ("Herb", "ChemicalS", "CylinderKey"). The same check guards the
-- network messages, so anything else is refused.
local function plausible_id(t)
    return type(t) == "string" and #t >= 2 and #t <= 40 and t:match("^[%w_]+$") ~= nil and t:match("^%d+$") == nil
end

-- Text fields of obj that look like an item name, id-ish field names first: { {field, text}, ... }
local function id_strings(obj)
    local out = {}
    for _, f in ipairs(fields_of_type(obj, "System.String")) do
        local t = as_text(f[2])
        if plausible_id(t) then
            local low = f[1]:lower()
            out[#out + 1] = { f[1], t, (low:find("id", 1, true) or low:find("name", 1, true)) and 1 or 2 }
        end
    end
    table.sort(out, function(a, b) return a[3] < b[3] end)
    return out
end

-- Learns an item's name. The 2026-11 test showed getItemDataId on its own is not enough (the pointed-at item was
-- seen but its name came back unusable), so this tries, in order: the id getters (as text, or as an object with a
-- text field), text fields on the item, the item's save data, and the GameObject's name.
-- Returns id, where-it-came-from; or nil, nil, a note on what each attempt returned.
local function resolve_item_id(item)
    local notes = {}
    local function note(t) notes[#notes + 1] = t end
    for _, g in ipairs(give.id_getters) do
        local ok, v = pcall(function() return item:call(g) end)
        if not ok then
            note(g .. ": no such method")
        elseif v == nil then
            note(g .. ": nil")
        else
            local t = as_text(v)
            if plausible_id(t) then return t, g end
            if type(v) == "number" then
                note(g .. ": the number " .. tostring(v))
            elseif type(v) == "string" then
                note(g .. ": text \"" .. v:sub(1, 30) .. "\" (not usable)")
            else
                local inner = id_strings(v)
                if inner[1] then return inner[1][2], g .. "." .. inner[1][1] end
                note(g .. ": an object " .. dump_value(v) .. " with no name inside")
            end
        end
    end
    local own = id_strings(item)
    if own[1] then return own[1][2], "item field " .. own[1][1] end
    local oks, sd = pcall(function() return item:call("getItemSaveData") end)
    if oks and sd ~= nil and type(sd) ~= "number" and type(sd) ~= "string" then
        local inner = id_strings(sd)
        if inner[1] then return inner[1][2], "getItemSaveData." .. inner[1][1] end
        note("getItemSaveData: an object with no name inside")
    end
    local okg, go = pcall(function() return item:call("get_GameObject") end)
    if okg and go ~= nil then
        local okn, nm = pcall(function() return go:call("get_Name") end)
        nm = okn and as_text(nm) or nil
        if nm then nm = nm:gsub("%(Clone%)$", ""):gsub("^%s+", ""):gsub("%s+$", "") end
        if plausible_id(nm) then return nm, "GameObject name" end
        note("GameObject name: " .. tostring(nm))
    end
    return nil, nil, table.concat(notes, "; ")
end

local function item_id_of(item)
    return resolve_item_id(item)
end

-- count, known. known is false when no getter answered and the count is just assumed to be 1.
local function item_count_of(item)
    for _, getter in ipairs(give.count_getters) do
        local ok, n = pcall(function() return item:call(getter) end)
        if ok and type(n) == "number" and n >= 1 and n < 100000 then return math.floor(n), true end
    end
    return 1, false
end

-- Runs when the game asks whether the highlighted item can be used/discarded (the inventory menu does this
-- when the cursor lands on an item), so `this` is the item under the cursor. The item is remembered even if
-- its name can't be read; then the diagnostics are written to the debug file by themselves.
local function on_item_focus(args)
    local item = sdk.to_managed_object(args[2])
    if not item then return end
    give.hover_seen = (give.hover_seen or 0) + 1
    local id, src, why = item_id_of(item)
    local count, known = item_count_of(item)
    give.focus = { item = item, id = id, src = src, why = why, count = count, count_known = known, at = os.clock() }
    if not id and os.clock() - give.auto_dump_at > 120 then give.want_dump = "the pointed-at item's name could not be read" end
end

-- Everything in the inventory: { { item, id, count }, ... }. The inventory object has a List of
-- app.Inventory.ItemInfo (field _ItemList, seen in your dump); each entry holds an app.Item.
local function list_elements(list)
    local out = {}
    local okc, n = pcall(function() return list:call("get_Count") end)
    if okc and type(n) == "number" then
        for i = 0, math.min(n, 200) - 1 do
            local ok, v = pcall(function() return list:call("get_Item", i) end)
            if ok and v ~= nil then out[#out + 1] = v end
        end
        if #out > 0 then return out end
    end
    local oka, arr = pcall(function() return list:get_field("_items") end)
    if oka and arr then
        local oke, els = pcall(function() return arr:get_elements() end)
        if oke and els then
            for _, v in ipairs(els) do
                if v ~= nil then out[#out + 1] = v end
            end
        end
    end
    return out
end

local function item_of_info(info)
    local ok, tn = pcall(function() return info:get_type_definition():get_full_name() end)
    if ok and tn == "app.Item" then return info end
    for _, f in ipairs(fields_of_type(info, "app.Item")) do return f[2] end
    for _, m in ipairs({ "get_Item", "getItem" }) do
        local okc, v = pcall(function() return info:call(m) end)
        if okc and v ~= nil and type(v) ~= "number" then return v end
    end
    return nil
end

-- Number fields of an inventory entry that look like a stack size (used if the item has no count getter).
local function entry_count(info)
    for _, f in ipairs(fields_of_type(info, "System.Int32")) do
        local low = f[1]:lower()
        if (low:find("num", 1, true) or low:find("count", 1, true) or low:find("stack", 1, true)) and type(f[2]) == "number"
            and f[2] >= 1 and f[2] < 100000 then
            return math.floor(f[2])
        end
    end
    return nil
end

local function inventory_items()
    local inv = inventory_object()
    if not inv then return nil, "inventory object not found" end
    local ok, list = pcall(function() return inv:get_field("_ItemList") end)
    if not ok or list == nil then return nil, "the inventory has no _ItemList" end
    local entries = list_elements(list)
    local out, noitem, noid, first_why = {}, 0, 0, nil
    for _, info in ipairs(entries) do
        local item = item_of_info(info)
        local id, src, why, count, known
        if item then
            id, src, why = item_id_of(item)
            count, known = item_count_of(item)
        else
            noitem = noitem + 1
        end
        if not id then
            local own = id_strings(info) -- the entry itself may carry the name
            if own[1] then id, src = own[1][2], "entry field " .. own[1][1] end
        end
        if id then
            if not known then count = entry_count(info) or count or 1 end
            out[#out + 1] = { item = item, id = id, count = count or 1, src = src }
        elseif item then
            noid = noid + 1
            first_why = first_why or why
        end
        if #out >= 40 then break end
    end
    local note
    if #entries == 0 then
        note = "the list is empty"
    elseif noitem + noid > 0 then
        note = string.format("%d of %d entries unreadable: %d without an app.Item, %d whose name I can't read%s", noitem + noid,
            #entries, noitem, noid, first_why and (" [" .. first_why .. "]") or "")
        if #out == 0 and os.clock() - give.auto_dump_at > 120 then give.want_dump = "the inventory list could not be read" end
    end
    return out, note
end

local function raw_int(v)
    v = sdk.to_int64(v) % 4294967296
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

-- (9.13) The journal says what every discard-like call was taken for (25 lines at most): the 0.8 file had a discard that dropped
-- nothing and left no line at all, so it was impossible to tell which condition had failed.
function give.discard_note(msg)
    give.discard_lines = (give.discard_lines or 0) + 1
    if give.discard_lines <= 25 then say("discard: " .. msg) end
end

-- A drop to be spawned a moment later, after the game has finished the discard. Once per discard: two hooks see the same one.
function give.queue_drop(id, n, now, how)
    local q = give.dropq
    if q and q.id == id and now - q.at < 3 then
        give.discard_note(string.format("%s: %s x%d is already queued for the ground", how, id, n))
        return
    end
    give.dropq = { id = id, at = now }
    give.pending_drop = { id = id, n = n, at = now }
    give.discard_note(string.format("%s: %s x%d will be put on the ground", how, id, n))
end

-- Runs just before app.Item.reduceNum(count, player): the inventory's Discard (also used when something is consumed).
local function on_item_reduce(args)
    local now = os.clock()
    give.reduce_seen = (give.reduce_seen or 0) + 1
    local item = sdk.to_managed_object(args[2])
    local who = sdk.to_managed_object(args[4])
    local id = item and item_id_of(item)
    local n = raw_int(args[3])
    local function skip(why) give.discard_note(string.format("reduceNum(%s x%s) is not a discard I drop: %s", tostring(id), tostring(n), why)) end
    if not give.drop_on_discard then return skip("'Discard drops the item' is switched off") end
    local f = give.focus
    if not f or not f.id or now - f.at > 30 then return skip("the inventory menu was not used in the last 30 s") end
    if not item or not who then return skip("the item or the player could not be read") end
    if not is_player_name(who:call("get_Name")) then return skip("the second argument is not the player") end
    mgr.player = who
    if not id or id ~= f.id or n < 1 or n > 999 then return skip("it is not the item the menu was on (" .. tostring(f.id) .. ") or the count is odd") end
    give.queue_drop(id, n, now, "reduceNum")
end

-- (9.13) The inventory menu's own discard, app.InventoryMenu.discardItem(app.Item) -> Boolean (it is in the file's method list):
-- the item comes with the call, no "highlighted item" is needed, and the answer says whether it was discarded.
function give.on_discard_item(args)
    local item = sdk.to_managed_object(args[3])
    local id = item and item_id_of(item)
    local n = item and item_count_of(item) or 1
    give.discard_calls = (give.discard_calls or 0) + 1
    give.discarding = { id = id, n = n, at = os.clock() }
end

function give.after_discard_item(retval)
    local d = give.discarding
    give.discarding = nil
    if not d then return end
    local okv, v = pcall(sdk.to_int64, retval)
    local yes = okv and type(v) == "number" and v % 256 ~= 0
    if not yes then return give.discard_note(string.format("the menu's discardItem(%s) answered no: nothing dropped", tostring(d.id))) end
    if not give.drop_on_discard then return give.discard_note("the menu discarded " .. tostring(d.id) .. "; 'Discard drops the item' is switched off") end
    if not d.id then return give.discard_note("the menu discarded an item whose name I can't read: nothing dropped") end
    give.queue_drop(d.id, math.max(1, math.min(d.n or 1, 999)), os.clock(), "discardItem")
end

local function remember_item_manager(args)
    local im = sdk.to_managed_object(args[2])
    if im then
        mgr.captured_im = im
        -- (9.14) Taken over only when the copy in use does not know the items and this one does. This hook runs for every item
        -- the game creates, so a copy that knows the items is never replaced, and nothing is asked of it once one is in use.
        if not mgr.item_manager_ok and mgr.im_knows(im) then
            mgr.item_manager, mgr.item_manager_how, mgr.item_manager_ok = im, "the one the game's own createItemInstance call used", true
        end
    end
    local p = sdk.to_managed_object(args[3])
    if p and is_player_name(p:call("get_Name")) then mgr.player = p end
end

local function remember_inventory(args)
    -- getExtendLevelState is a static call in this game: args[2] is its number, not an inventory (that error filled the journal)
    if mgr.inv_hook_dead then return end
    local ok, inv = pcall(sdk.to_managed_object, args[2])
    if not ok or not inv then
        mgr.inv_hook_dead = true
        return
    end
    mgr.inventory = inv
end

local function install_give_hooks()
    local n = 0
    if hook_method("app.Item", "isCanDiscard", on_item_focus) then n = n + 1 end
    if hook_method("app.Item", "reduceNum", on_item_reduce) then n = n + 1 end
    if hook_method("app.ItemManager", "createItemInstance", remember_item_manager) then n = n + 1 end
    if hook_method("app.Inventory", "getExtendLevelState", remember_inventory) then n = n + 1 end
    if hook_method("app.InventoryMenu", "discardItem", give.on_discard_item, give.after_discard_item) then give.discard_hooked = true end
    return n >= 2
end

local function game_object_of(obj)
    if obj == nil then return nil end
    local go
    pcall(function()
        local td = obj:get_type_definition()
        if td and td:get_full_name() == "via.GameObject" then
            go = obj
        else
            go = obj:call("get_GameObject")
        end
    end)
    return go
end

-- (9.12) The game's creation calls answered nothing in the real file ("createItemInstance failed: nil", and a "drop" that was
-- reported but never appeared: the call had not failed, it had returned nil, which was taken for success). So: every way the
-- call might be meant is tried (the player object, then the owner the inventory's own entries carry; the name as a plain Lua
-- string, then as a managed string), the first one that returns an object wins and is remembered, and when none does the
-- answer says what was tried. Nothing is ever reported as done unless an object came back.
give.create_log = {}   -- the last attempts, for the debug file
local function item_owner_candidates()
    local out = {}
    local player = player_object()
    local pname
    if player then
        pname = as_text(player:call("get_Name"))
        out[#out + 1] = { name = "player", go = player }
    end
    -- (9.14) Only the player. 9.12 and 9.13 also tried "the owner an inventory entry carries", which is an item's own object
    -- (sm1852_AntisepticSolutionMedium_Item in the file): handing that to the game's creation code is the likely crash.
    return out
end

-- Calls im:method(owner, id [, extra]) the ways described above. Returns the object, or nil plus the text of what was tried.
local function create_item_object(method, id, extra)
    local im = item_manager()
    if not im then return nil, "ItemManager not found" end
    local owners = item_owner_candidates()
    if #owners == 0 then return nil, "player object (Pl0000) not found" end
    local tried = {}
    for _, ow in ipairs(owners) do
        for _, form in ipairs({ "plain", "managed" }) do
            local sid = form == "plain" and id or managed_string(id)
            local ok, res = pcall(function()
                if extra ~= nil then return im:call(method, ow.go, sid, extra) end
                return im:call(method, ow.go, sid)
            end)
            local how = ow.name .. ", " .. form .. " name"
            if ok and res ~= nil then
                give.create_how = method .. ": " .. how
                return res
            end
            tried[#tried + 1] = how .. (ok and ": nothing came back" or (": " .. tostring(res):sub(1, 50)))
        end
    end
    local text = method .. " gave nothing (" .. table.concat(tried, "; ") .. ")"
    give.create_log[#give.create_log + 1] = string.format("%.0f  %s %s: %s", os.clock(), method, id, text)
    if #give.create_log > 12 then table.remove(give.create_log, 1) end
    return nil, text
end

-- What the game says about this item name, once a minute at most, into the debug file: is the name known, what does its item
-- data hold (maybe the prefab to create it from). Read-only.
local function item_probe(id, why)
    local now = os.clock()
    if now - (give.probe_at or -1e9) < 60 then return end
    give.probe_at = now
    local im = item_manager()
    if not im then return end
    say("give probe (" .. tostring(why) .. "): item " .. id)
    for i, c in ipairs(mgr.im_candidates(true)) do -- (9.13) every copy of the manager the game has, and what each one knows
        local okf, d = pcall(function() return c.obj:call("findItemData", id) end)
        local okn, names = pcall(function() return c.obj:call("get_ItemDataIDNames") end)
        local cnt = okn and names ~= nil and #list_elements(names) or nil
        say(string.format("    give probe: copy %d, %s%s: findItemData -> %s, name list -> %s", i, c.how, c.obj == im and " (in use)" or "",
            okf and (d ~= nil and "an item" or "nil") or "error", cnt and (cnt .. " names") or "nil"))
    end
    local function try(label, f)
        local ok, v = pcall(f)
        say("    give probe: " .. label .. ": " .. (ok and (as_text(v) or tostring(v)) or ("error " .. tostring(v):sub(1, 80))))
        return ok and v or nil
    end
    local data = try("findItemData", function() return im:call("findItemData", id) end)
    if data ~= nil and type(data) ~= "number" and type(data) ~= "string" then pcall(dump_fields, data, "        ", 24) end
    local names = try("get_ItemDataIDNames", function() return im:call("get_ItemDataIDNames") end)
    if names ~= nil then
        local els = list_elements(names)
        local found, sample = false, {}
        for _, v in ipairs(els) do
            local t = as_text(v) or tostring(v)
            if t == id then found = true end
            if #sample < 12 then sample[#sample + 1] = t end
        end
        say(string.format("    give probe: the game lists %d item names, %s in it; first ones: %s", #els,
            found and ("'" .. id .. "' is") or ("'" .. id .. "' is NOT"), table.concat(sample, ", ")))
    end
end

-- Journal lines about adding an item to the inventory, 12 at most.
function give.add_note(msg)
    give.add_lines = (give.add_lines or 0) + 1
    if give.add_lines <= 12 then say("add: " .. msg) end
end

-- (9.14) Crumbs around the calls that make or place items: if the game crashes in one, the next session names it.
function give.crumb(what) pcall(tracer.crumb, "give", what) end
function give.clean() pcall(tracer.crumb, "clean", "item call finished") end

-- What a GameObject looks like to the engine: its name, parent, position, and whether it is drawn / updated. Read-only.
function give.go_info(go)
    local info = {}
    pcall(function() info.name = as_text(go:call("get_Name")) end)
    pcall(function()
        local xf = go:call("get_Transform")
        local p = xf:call("get_Position")
        info.x, info.y, info.z = p.x, p.y, p.z
        local par = xf:call("get_Parent")
        if par ~= nil then
            local pgo = par:call("get_GameObject")
            info.parent = pgo and as_text(pgo:call("get_Name")) or "?"
        end
    end)
    pcall(function() info.draw = go:call("get_DrawSelf") end)
    pcall(function() info.update = go:call("get_UpdateSelf") end)
    return info
end

function give.info_text(i)
    return string.format("%s parent=%s drawn=%s updating=%s at %s", tostring(i.name), tostring(i.parent), tostring(i.draw), tostring(i.update),
        i.x and string.format("(%.2f, %.2f, %.2f)", i.x, i.y, i.z) or "?")
end

-- Journal lines about the drop object, 12 at most: the 0.9 file had a drop that was "created" but never seen.
function give.drop_note(msg)
    give.drop_lines = (give.drop_lines or 0) + 1
    if give.drop_lines <= 12 then say("drop: " .. msg) end
end

-- Where the player stands and which way they face (the camera's pose is not the player's, so the player object is used).
function give.player_pose(player)
    local px, py, pz, fx, fz
    pcall(function()
        local xf = player:call("get_Transform")
        local p = xf:call("get_Position")
        px, py, pz = p.x, p.y, p.z
        local q = xf:call("get_Rotation")
        if q then
            fx = 2 * (q.x * q.z + q.w * q.y)
            fz = 1 - 2 * (q.x * q.x + q.y * q.y)
        end
    end)
    return px, py, pz, fx, fz
end

-- Puts an item on the ground (at x, y, z, or just in front of the player's feet if they are nil).
-- Returns true plus where it ended up, or nil plus the reason. Only an object that came back, and is drawn, counts as done.
local function spawn_world_item(id, n, x, y, z)
    if not item_manager() then return nil, "ItemManager not found" end
    local player = player_object()
    if not player then return nil, "player object (Pl0000) not found" end
    give.crumb(string.format("making %s x%d for the ground (createDropItemInstance)", id, n))
    local obj, why = create_item_object("createDropItemInstance", id, n)
    give.clean()
    if obj == nil then
        item_probe(id, "the item could not be put on the ground")
        return nil, why
    end
    local go = game_object_of(obj)
    if not go then return nil, "the dropped object has no GameObject" end
    give.crumb(string.format("placing the dropped %s", id))
    local before = give.go_info(go)
    local ppx, ppy, ppz, pfx, pfz = give.player_pose(player)
    local tx, ty, tz = x, y, z
    if tx == nil and ppx then
        -- (9.14) the game puts a dropped item where its owner is (a drawer, in its own use); the player is the owner here, so the
        -- item may sit inside the player, or be a child of the player and follow them. Put it down in front of the feet.
        local len = math.sqrt((pfx or 0) ^ 2 + (pfz or 0) ^ 2)
        local ox, oz = 0, 0
        if len > 0.01 then ox, oz = pfx / len * 0.8, pfz / len * 0.8 end
        tx, ty, tz = ppx + ox, ppy + 0.1, ppz + oz
    end
    pcall(function()
        local xf = go:call("get_Transform")
        if before.parent and is_player_name(before.parent) then pcall(function() xf:call("set_Parent", nil) end) end -- (let go of the player)
        if tx then xf:call("set_Position", Vector3f.new(tx, ty, tz)) end
    end)
    pcall(function() go:call("set_DrawSelf", true) end)
    pcall(function() go:call("set_UpdateSelf", true) end)
    local after = give.go_info(go)
    give.clean()
    give.drop_note(string.format("%s x%d: object was %s; now %s; player at %s", id, n, give.info_text(before), give.info_text(after),
        ppx and string.format("(%.2f, %.2f, %.2f)", ppx, ppy, ppz) or "?"))
    give.last_drop = { id = id, before = before, after = after }
    if after.draw == false then return nil, "the object that was made is hidden (not drawn), so nobody would see it" end
    return true, after.x or tx, after.y or ty, after.z or tz
end

local function new_go_list()
    local ok, l = pcall(function() return sdk.create_instance("System.Collections.Generic.List`1<via.GameObject>") end)
    if ok then return l end
    return nil
end

-- The last way in when the game won't create an item: if an item of that name is already in the inventory, its stack grows.
-- Only when the whole amount fits. Returns true, or false plus why.
local function bump_existing_stack(id, n)
    local list = inventory_items()
    for _, e in ipairs(list or {}) do
        if e.id == id and e.item then
            local okc, cur = pcall(function() return e.item:call("getStackNum") end)
            local okm, max = pcall(function() return e.item:call("getMaxStackNum") end)
            if okc and okm and type(cur) == "number" and type(max) == "number" then
                if cur + n <= max then
                    local oks = pcall(function() e.item:call("setStackNum", cur + n) end)
                    local okr, now = pcall(function() return e.item:call("getStackNum") end)
                    if oks and okr and now == cur + n then
                        give.bumped = (give.bumped or 0) + 1
                        return true
                    end
                    return false, "the stack of " .. id .. " would not change"
                end
                return false, "your stack of " .. id .. " is full (" .. cur .. "/" .. max .. ")"
            end
        end
    end
    return false, "no " .. id .. " in the inventory to add it to"
end

-- The name of an enum value ("app.Inventory.AddItemResult" and the like), read once from the type: { [value] = name }.
function give.enum_names(typename)
    give.enums = give.enums or {}
    if give.enums[typename] then return give.enums[typename] end
    local map = {}
    pcall(function()
        local td = sdk.find_type_definition(typename)
        for _, f in ipairs(td and td:get_fields() or {}) do
            if f:is_static() then
                local v = f:get_data(nil)
                if type(v) == "number" then map[v] = f:get_name() end
            end
        end
    end)
    give.enums[typename] = map
    return map
end

function give.result_text(v)
    if v == nil then return "nothing" end
    if type(v) == "number" then
        local nm = give.enum_names("app.Inventory.AddItemResult")[v]
        return nm and (nm .. "=" .. v) or tostring(v)
    end
    return as_text(v) or tostring(v)
end

-- How many of `id` the inventory holds now, and whether the list could be read at all.
function give.total_of(id)
    local list = inventory_items()
    if list == nil then return 0, false end
    local total = 0
    for _, e in ipairs(list) do
        if e.id == id then total = total + (e.count or 1) end
    end
    return total, true
end

-- Creates the item the way crafting does, then adds it. (9.14) The 9.13 file had "added" items that were never in the
-- inventory: the old code called addItem with a nil list, ignored what it answered (an app.Inventory.AddItemResult) and
-- said "done". Now each form of addItem is tried in turn (the game's own forms: with and without a list), what it answered is
-- written down, and the item only counts as delivered when the inventory really holds more of it than before.
-- Returns true plus how, or false plus why.
local function add_to_inventory(id, n)
    local im, player, inv = item_manager(), player_object(), inventory_object()
    if not im then return false, "ItemManager not found" end
    if not player then return false, "player object not found" end
    if not inv then return false, "inventory object not found" end
    give.crumb(string.format("making %s for the inventory (createItemInstance)", id))
    local created, why = create_item_object("createItemInstance", id)
    give.clean()
    if created == nil then
        item_probe(id, "the item could not be created")
        local okb, whyb = bump_existing_stack(id, n)
        if okb then return true, "added to the stack you already have" end
        return false, tostring(whyb) .. "; " .. tostring(why) -- (the answer to the other player is cut at 90 characters: the short reason first)
    end
    local item = created
    pcall(function()
        local td = created:get_type_definition()
        if td and td:get_full_name() == "via.GameObject" then
            item = created:call("getComponent(System.Type)", sdk.typeof("app.Item"))
        end
    end)
    if item == nil then return false, "the new object has no app.Item" end
    if n > 1 then pcall(function() item:call("setStackNum", n) end) end
    local okf, fit = pcall(function() return inv:call("isAddItem", item) end)
    local before = give.total_of(id)
    local forms = {
        { "addItem(item, player)", function() return inv:call("addItem(app.Item, via.GameObject)", item, player) end },
        { "addItem(item, player, false, no list)", function() return inv:call("addItem", item, player, false, nil) end },
        { "addItem(item, player, false, new list)", function()
            local l = new_go_list()
            if l == nil then error("no list could be made") end
            return inv:call("addItem", item, player, false, l)
        end },
    }
    local said = {}
    for _, form in ipairs(forms) do
        give.crumb(string.format("adding %s x%d to the inventory: %s", id, n, form[1]))
        local ok, res = pcall(form[2])
        give.clean()
        said[#said + 1] = form[1] .. " -> " .. (ok and give.result_text(res) or ("error: " .. tostring(res):sub(1, 40)))
        local after, readable = give.total_of(id)
        if readable and after > before then
            give.add_how = form[1]
            give.add_last = { id = id, form = form[1], answered = said[#said], isAddItem = okf and give.result_text(fit) or "error" }
            if #said > 1 then give.add_note("it took " .. #said .. " tries: " .. table.concat(said, "; ")) end
            return true
        elseif not readable and ok then
            give.add_how = form[1]
            return true, "added (the inventory can't be read to check)"
        end
    end
    give.add_last = { id = id, form = "none worked", answered = table.concat(said, "; "), isAddItem = okf and give.result_text(fit) or "error" }
    give.add_note(string.format("%s x%d was created but not added. isAddItem said %s. %s", id, n, okf and give.result_text(fit) or "error",
        table.concat(said, "; ")))
    -- isAddItem answered "no" (a boolean in a test, an enum whose name says "full" in the game): say so in plain words
    local fit_name = (okf and type(fit) == "number") and tostring(give.enum_names("app.Inventory.AddItemResult")[fit] or "") or ""
    if (okf and fit == false) or fit_name:lower():find("full", 1, true) then return false, "inventory full" end
    return false, "the game did not add it (" .. table.concat(said, "; "):sub(1, 70) .. ")"
end

-- Hands n of item `id` to the other player.
local function give_item(id, n)
    local now = os.clock()
    if not peer_present(now) then
        give.failed = give.failed + 1
        give_note("nobody to give to (the other player is not connected)")
        return false
    end
    if not id or n < 1 then return false end
    local inv = inventory_object()
    if not inv then
        give.failed = give.failed + 1
        give_note("can't find your inventory object, nothing was given")
        return false
    end
    -- (9.12) Nothing leaves your inventory yet: the other game answers first (give_ack) and the item is taken out when it says
    -- "ok". The versions before this took it at once, and an item the other game could not create was simply gone.
    net_send(GIVE_MSG, id .. "|" .. n)
    give.out[#give.out + 1] = { kind = "g", id = id, n = n, at = now }
    give.focus = nil -- the highlighted item just changed
    give_note(string.format("you offered %s x%d to %s: it leaves your inventory when they confirm they have it", id, n,
        state.remote_name or CFG.DEFAULT_NAME))
    return true
end

local function give_focused(all)
    local f = give.focus
    if not f then
        give_note("highlight an item in the inventory first (or use the list in the panel)")
        return
    end
    if not f.id then
        give_note("I can see the highlighted item but can't read its name: use the list in the panel, and press button 7")
        return
    end
    local n = all and f.count or 1
    give_item(f.id, math.min(n, f.count))
end

-- (9.11) The receiver tells the sender what happened ("g|id|n|ok|how" for a gift, "d|..." for a drop), so a gift that could
-- not be delivered is handed back instead of being lost, and the reason is on the sender's screen and in its journal.
local function give_ack(kind, id, n, ok, how)
    local text = tostring(how or ""):gsub("[|\r\n]", " ")
    net_send(GIVE_ACK_MSG, string.format("%s|%s|%d|%s|%s", kind, id, n, ok and "ok" or "fail", text:sub(1, 90)))
end

-- One try at putting a gift in my inventory, else on the ground at my feet. Returns done, ok, how.
-- A missing player object is only a "not yet": it is tried again for a few seconds (final = false).
local function give_try(id, n, final)
    local who = state.remote_name or CFG.DEFAULT_NAME
    items.suppress_until = os.clock() + 2 -- creating the item must not look like a world pickup
    local ok, why = add_to_inventory(id, n)
    if ok then
        local how = (type(why) == "string" and why ~= "") and why or "in the inventory"
        give_note(string.format("%s gave you %s x%d (%s)", who, id, n, how))
        return true, true, how
    end
    local okd, px = spawn_world_item(id, n)
    if okd then
        give_note(string.format("%s gave you %s x%d: %s, so it is on the ground at your feet", who, id, n, tostring(why)))
        return true, true, "on the ground (" .. tostring(why) .. ")"
    end
    if not final and (tostring(why):find("not found", 1, true) or tostring(px):find("not found", 1, true)) then return false end
    give.failed = give.failed + 1
    give_note(string.format("%s gave you %s x%d but I could not add it (%s) or drop it (%s)", who, id, n,
        tostring(why), tostring(px)))
    return true, false, tostring(why) .. "; " .. tostring(px)
end

net_on(GIVE_MSG, function(payload)
    local id, n = payload:match("^([%w_]+)|(%d+)$")
    n = tonumber(n)
    if not id or not n or n < 1 or n > 999 then return end
    give.received = give.received + 1
    local done, ok, how = give_try(id, n, false)
    if done then
        give_ack("g", id, n, ok, how)
    else
        give.inbox[#give.inbox + 1] = { id = id, n = n, tries = 1, next_at = os.clock() + 1 }
    end
end)

net_on(DROP_MSG, function(payload)
    local id, n, x, y, z = payload:match("^([%w_]+)|(%d+)|(-?[%d%.]+)|(-?[%d%.]+)|(-?[%d%.]+)$")
    n, x, y, z = tonumber(n), tonumber(x), tonumber(y), tonumber(z)
    if not (id and n and x and y and z) or n < 1 or n > 999 then return end
    give.received = give.received + 1
    local who = state.remote_name or CFG.DEFAULT_NAME
    local ok, px, py, pz = spawn_world_item(id, n, x, y, z)
    if ok then
        give_note(string.format("%s dropped %s x%d: it is on the ground here too", who, id, n))
        give_ack("d", id, n, true, "on the ground")
    else
        give.failed = give.failed + 1
        give_note(string.format("%s dropped %s x%d but I could not show it (%s)", who, id, n, tostring(px)))
        give_ack("d", id, n, false, tostring(px))
    end
end)

net_on(GIVE_ACK_MSG, function(payload)
    local kind, id, n, res, how = payload:match("^(%a)|([%w_]+)|(%d+)|(%a+)|(.*)$")
    n = tonumber(n)
    if not kind or not id or not n then return end
    local who = state.remote_name or CFG.DEFAULT_NAME
    for i, o in ipairs(give.out) do
        if o.kind == kind and o.id == id and o.n == n then
            table.remove(give.out, i)
            if res == "ok" and kind == "g" then
                -- they have it: now it leaves my inventory (the health module must not take this reduceItem for "you used a healing item")
                local inv = inventory_object()
                local okr, resr = false, nil
                if inv then
                    give.giving = true
                    okr, resr = call_str(inv, "reduceItem", id, n, true)
                    give.giving = false
                end
                if okr and resr ~= false then
                    give.sent = give.sent + 1
                    give_note(string.format("%s has %s x%d (%s): it left your inventory", who, id, n, how))
                else
                    give.failed = give.failed + 1
                    give_note(string.format("%s has %s x%d (%s) but the game would not take it out of your inventory: you both have it now", who, id, n, how))
                end
            elseif res == "ok" then
                give_note(string.format("%s has %s x%d (%s)", who, id, n, how))
            elseif kind == "g" then
                -- their game could not take it: it never left my inventory
                give.failed = give.failed + 1
                give_note(string.format("%s could not take %s x%d (%s): you keep it", who, id, n, how))
            else
                give.failed = give.failed + 1
                give_note(string.format("%s could not show the %s x%d you dropped (%s)", who, id, n, how))
            end
            return
        end
    end
end)

-- Every frame: the Give hotkey, and the delayed spawn after a discard.
local function give_update(now)
    -- (9.11) gifts waiting for the player object; and my own gifts and drops nobody has answered
    for i = #give.inbox, 1, -1 do
        local g = give.inbox[i]
        if now >= g.next_at then
            g.tries = g.tries + 1
            local done, ok, how = give_try(g.id, g.n, g.tries >= 5)
            if done then
                table.remove(give.inbox, i)
                give_ack("g", g.id, g.n, ok, how)
            else
                g.next_at = now + 1
            end
        end
    end
    for i = #give.out, 1, -1 do
        local o = give.out[i]
        if now - o.at > 10 then
            table.remove(give.out, i)
            give_note(string.format("no answer from %s about %s x%d: it stays in your inventory (if it did arrive they have a copy; their script may be older than build 9.12)",
                state.remote_name or CFG.DEFAULT_NAME, o.id, o.n))
        end
    end
    if give.want_dump and now - give.auto_dump_at >= 1 then
        local why = give.want_dump
        give.want_dump, give.auto_dump_at = nil, now
        say("give: writing item diagnostics to the debug file by itself (" .. why .. ")")
        dump_focused_item()
    end
    local okk, down = pcall(function() return reframework:is_key_down(give.hotkey) end)
    down = okk and down == true
    if down and not give.key_was_down then give_focused(false) end
    give.key_was_down = down

    local d = give.pending_drop
    if d and now - d.at >= 0.2 then
        give.pending_drop = nil
        local ok, px, py, pz = spawn_world_item(d.id, d.n)
        if ok then
            give.dropped = give.dropped + 1
            if px == nil and state.local_pos then
                local lp = state.local_pos
                px, py, pz = lp.x, lp.y - CFG.EYE_HEIGHT, lp.z
            end
            if px ~= nil and peer_present(now) then
                net_send(DROP_MSG, string.format("%s|%d|%.2f|%.2f|%.2f", d.id, d.n, px, py, pz))
                give.out[#give.out + 1] = { kind = "d", id = d.id, n = d.n, at = now }
            end
            give.last = string.format("you dropped %s x%d on the ground%s", d.id, d.n,
                peer_present(now) and " (the other player sees it too)" or "")
            say("give: " .. give.last)
        else
            give.failed = give.failed + 1
            give_note(string.format("could not drop %s x%d on the ground: %s", d.id, d.n, tostring(px)))
        end
    end
end

local function draw_give_hint(now)
    if not give.hint or not give.focus or not give.focus.id or not peer_present(now) then return end
    if now - give.focus.at > 6 then return end
    pcall(draw.text, string.format("[F7] give %s to %s", give.focus.id, state.remote_name or CFG.DEFAULT_NAME),
        24, 110, 0xFF00D7FF)
end

----------------------------------------------------------------------------------------------
-- Enemy sync, version 1 (EXPERIMENTAL). The TCP host's game is the authority.
--
-- The scene scan showed the enemies are root objects named Em#### (Em2000 ... Em6100), each with its own
-- Think/Status/Order components. Every 0.1 s the HOST reads those objects' position, rotation, health (if a
-- health field can be found) and animation ids, and sends them as one text blob through re7mp.exe
-- (TCP only, latest wins). The JOINER draws them as red ghosts. Optionally (EXPERIMENTAL) the joiner's own
-- enemies with the same names are moved onto the host's positions each frame.
-- Not built yet: damage dealt by the joiner reaching the host, enemy deaths, spawning, animation mirroring.
-- The "Enemy details" button in the debug section writes what is needed to build those.
-- Blob format (one entry per enemy, separated by ';'):  name,x,y,z,qx,qy,qz,qw,hp,flags,bank,motion,frame
----------------------------------------------------------------------------------------------
local ENEMY_MODES = {
    "Off",
    "Show the host's enemies as red ghosts",
    "Ghosts, and move my own enemies onto the host's (EXPERIMENTAL)",
}
local enemy = {
    mode = 2,
    drive_ai = false,   -- mode 3 only: also switch off my enemies' own AI components
    seq = 0, last_scan = 0, last_send = 0, last_read = 0,
    roots = {},         -- host: { name, go, xf }
    sent = 0, received = 0,
    last = "No enemy data yet.",
    remote = {},        -- joiner: name -> latest snapshot and the smoothed position being drawn
    remote_seq = nil,
    remote_at = 0,
    test_ghosts = false, -- draw the received enemies even if I am the host (loopback test)
    show_parked = false, -- draw parked / placeholder Em#### objects too (grey), to find out what they are
    driven = {},        -- joiner: name -> { go, xf, disabled = { component, ... } }
    local_roots = {}, local_scan = 0,
    hp_logged = {},
    -- what is carried from one scan's record of an enemy to the next (found by the health search; see find_enemy_roots)
    KEEP = { "dmg_comp", "status", "no_is_dead", "hp_checked", "hp_tries", "hp_retry_at", "hp_field", "hp_comp", "hp_call", "hp_where", "hp_fail" },
}

local function enemy_note(text)
    enemy.last = text
    say("enemy sync: " .. text)
end

-- Root objects named Em#### in the current scene (they sit at the top of the scene, so only the roots are visited).
local function find_enemy_roots()
    local out = {}
    local scene = scene_object()
    if not scene then return out end
    -- (9.9) the records are rebuilt on every scan, so what was learned about an enemy's health is carried over by the
    -- object's address; before this, the whole health search ran again for every enemy every second
    local old = {}
    for _, o in ipairs(enemy.roots or {}) do
        if o.addr then old[o.addr] = o end
    end
    local xf = scene:call("get_FirstTransform")
    local visited = 0
    while xf and visited < 6000 do
        visited = visited + 1
        local go = xf:call("get_GameObject")
        if go then
            local name = go:call("get_Name")
            if type(name) == "string" and name:match("^[Ee][Mm]%d%d%d%d$") then
                local rec = { name = name, go = go, xf = xf }
                local oka, addr = pcall(go.get_address, go)
                if oka and type(addr) == "number" then
                    rec.addr = addr
                    local prev = old[addr]
                    if prev and prev.name == name then
                        for _, k in ipairs(enemy.KEEP) do rec[k] = prev[k] end
                    end
                end
                out[#out + 1] = rec
            end
        end
        xf = xf:call("get_Next")
    end
    return out
end

-- Health: your 2026-11 enemy dump showed the Status components have no HP field. The health lives in an
-- app.HealthInfo object held by the enemy's DamageController (field "HealthInfo"; the same controller also
-- has <defaultMaxHealth> = 8000 / 10000). I have not seen HealthInfo's own fields yet, so this looks for the
-- most health-like number in it and logs what it found; "Enemy details" dumps the whole object.
local find_health -- assigned inside the block below (keeps the main chunk under Lua's 200-local limit)
do
local HP_BAD = { "max", "default", "rate", "ratio", "regen", "recover", "limit", "scale", "damage", "time", "anger", "stun", "rank" }

-- Lower is better; nil means "not a health number".
local function hp_score(name, inside_health)
    local n = field_label(name):lower()
    for _, bad in ipairs(HP_BAD) do
        if n:find(bad, 1, true) then return nil end
    end
    local healthy = n:find("health", 1, true) or n:find("hp", 1, true) or n:find("life", 1, true)
    if n:find("current", 1, true) and (healthy or inside_health) then return 1 end
    if healthy then return 2 end
    if inside_health and (n == "value" or n == "_value" or n == "now" or n == "_now" or n == "cur" or n == "_cur") then return 3 end
    return nil
end

-- Best numeric field of obj (and its app.* parents) by hp_score. Returns field name, score.
local function best_health_field(obj, inside_health)
    local best, best_score
    pcall(function()
        local t = obj:get_type_definition()
        while t do
            local tn = t:get_full_name()
            if tn:find("^System%.") or tn:find("^via%.Component") or tn:find("^via%.Behavior") then break end
            for _, f in ipairs(t:get_fields() or {}) do
                if not f:is_static() then
                    local ft = f:get_type()
                    local ftn = ft and ft:get_full_name() or ""
                    if ftn == "System.Single" or ftn == "System.Int32" or ftn == "System.Double" then
                        local sc = hp_score(f:get_name(), inside_health)
                        if sc and (not best_score or sc < best_score) then
                            local okv, v = pcall(function() return obj:get_field(f:get_name()) end)
                            if okv and type(v) == "number" then best, best_score = f:get_name(), sc end
                        end
                    end
                end
            end
            t = t:get_parent_type()
        end
    end)
    return best, best_score
end

-- Runs once per enemy object: finds its Status component and a health number.
find_health = function(e)
    e.hp_checked = true
    e.hp_tries = (e.hp_tries or 0) + 1
    e.hp_retry_at = os.clock() + 3 -- (9.9) an enemy that has not started yet has no HealthInfo: look again a few times
    pcall(function()
        local comps = e.go:call("get_Components")
        local best_sc
        local dmg_comp
        for _, c in ipairs(comps:get_elements()) do
            local full = c:get_type_definition():get_full_name()
            if full:find("^app%.Em%d+Status$") or full == "app.EnemyStatus" then
                e.status = e.status or c
                local fname, sc = best_health_field(c, false)
                if fname and (not best_sc or sc < best_sc) then e.hp_comp, e.hp_field, best_sc = c, fname, sc end
            end
            if full:find("DamageController$") then
                dmg_comp = dmg_comp or c
                e.dmg_comp = e.dmg_comp or c -- (9.10) the joiner's hits are applied through it
            end
            if full:find("DamageController$") or full:find("^app%.Em%d+Status$") then
                for _, hv in ipairs(fields_of_type(c, "app.HealthInfo")) do
                    local fname, sc = best_health_field(hv[2], true)
                    if fname and (not best_sc or sc < best_sc) then
                        e.hp_comp, e.hp_field, best_sc = hv[2], fname, sc
                        e.hp_where = full .. "." .. hv[1]
                    end
                end
            end
        end
        -- 9.9: every enemy's DamageController is an app.DamageController, which has get_health() / get_maxHealth() (your
        -- 2026-11 enemy scan listed them); it works for the enemies whose HealthInfo field could not be found
        if not e.hp_field and dmg_comp then
            local okh, hv = pcall(dmg_comp.call, dmg_comp, "get_health")
            if okh and type(hv) == "number" then
                e.hp_comp, e.hp_call = dmg_comp, "get_health"
                e.hp_where = dmg_comp:get_type_definition():get_full_name()
            end
        end
    end)
    local found = e.hp_field ~= nil or e.hp_call ~= nil
    local logged = enemy.hp_logged[e.name]
    if logged == nil or (logged == "none" and found) then
        enemy.hp_logged[e.name] = found and "found" or "none"
        say(found and ("enemy sync: health of " .. e.name .. " is read from " .. (e.hp_where and (e.hp_where .. ".") or "") .. (e.hp_field or (e.hp_call .. "()")))
            or ("enemy sync: no health field found for " .. e.name .. " (use 'Enemy details' to list its fields)"))
    end
end
enemy.best_health_field = best_health_field -- the player health module (below) looks for health the same way
end -- do

local function read_health(e)
    if not e.hp_checked then
        find_health(e)
    elseif not e.hp_field and not e.hp_call and (e.hp_tries or 0) < 6 and os.clock() >= (e.hp_retry_at or 0) then
        find_health(e)
    end
    local ok, v
    if e.hp_comp and e.hp_field then
        ok, v = pcall(function() return e.hp_comp:get_field(e.hp_field) end)
    elseif e.hp_comp and e.hp_call then
        ok, v = pcall(e.hp_comp.call, e.hp_comp, e.hp_call)
    else
        return -1
    end
    if ok and type(v) == "number" then
        e.hp_fail = 0
        return v
    end
    -- the object this was learned from has gone (a new enemy at the same address): after three misses look again
    e.hp_fail = (e.hp_fail or 0) + 1
    if e.hp_fail >= 3 then
        e.hp_comp, e.hp_field, e.hp_call, e.hp_where, e.status, e.dmg_comp = nil, nil, nil, nil, nil, nil
        e.hp_checked, e.hp_tries, e.hp_fail = false, 0, 0
    end
    return -1
end

-- Why an Em#### object should not be shown as a live enemy (flag bits 2, 4, 8 of the snapshot):
--   2  parked: its Status says isStarted = false, or no animation is playing (motion id 4294967295).
--      Em8000 (a Jack boss variant) sat like this at y = -7.8 in your dump.
--   4  no app.Em####Status component: a placeholder or cutscene prop, not something you can fight (Em6190, Em3300).
--   8  at the world origin (0, 0, 0): a placeholder that was never placed.
local function inactive_flags(e, motion, p)
    local f = 0
    if not e.status then f = f + 4 end
    local parked = motion == 4294967295
    if e.status then
        local ok, started = pcall(function() return e.status:get_field("<isStarted>k__BackingField") end)
        if ok and started == false then parked = true end
    end
    if parked then f = f + 2 end
    if math.abs(p.x) < 0.01 and math.abs(p.y) < 0.01 and math.abs(p.z) < 0.01 then f = f + 8 end
    return f
end

local function flags_reason(flags)
    local why = {}
    if math.floor(flags / 2) % 2 == 1 then why[#why + 1] = "parked" end
    if math.floor(flags / 4) % 2 == 1 then why[#why + 1] = "no Status component" end
    if math.floor(flags / 8) % 2 == 1 then why[#why + 1] = "at the origin" end
    return table.concat(why, ", ")
end

-- true when the game says the enemy is dead (Em2000Status / Em3000Status have get_IsDead)
local function enemy_is_dead(e)
    if not e.status or e.no_is_dead then return false end
    local ok, dead = pcall(function() return e.status:call("get_IsDead") end)
    if not ok then
        e.no_is_dead = true -- this Status type has no such method (only Em2000Status / Em3000Status were seen): stop asking
        return false
    end
    return dead == true
end

-- bank, motion id and frame of the first animation layer (diagnostic: sent along, not applied yet)
local function read_motion(e)
    local bank, motion, frame = 0, 0, 0
    pcall(function()
        local m = e.go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        local layer = m and m:call("getLayer", 0)
        if layer then
            bank = tonumber(layer:call("get_MotionBankID")) or 0
            motion = tonumber(layer:call("get_MotionID")) or 0
            frame = tonumber(layer:call("get_Frame")) or 0
        end
    end)
    return math.floor(bank), math.floor(motion), frame
end

local function snapshot_one(e)
    local p = e.xf:call("get_Position")
    local q = e.xf:call("get_Rotation")
    local hp = read_health(e)
    if hp ~= hp or hp > 1e9 or hp < -1e9 then hp = -1 end
    local bank, motion, frame = read_motion(e)
    if frame ~= frame or frame > 1e7 or frame < -1e7 then frame = 0 end
    local flags = inactive_flags(e, motion, p) + (enemy_is_dead(e) and 0 or 1) -- bit 0: alive
    e.last_flags = flags
    return string.format("%s,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d,%.1f", e.name, p.x, p.y, p.z,
        q.x, q.y, q.z, q.w, math.floor(hp), flags, bank, motion, frame)
end

-- HOST: scan once a second, send ten times a second.
local function enemy_host_update(now)
    if enemy.mode < 2 or state.role ~= "host" or state.transport ~= "tcp" then return end
    if not peer_present(now) then return end
    if now - enemy.last_scan >= 1.0 then
        enemy.last_scan = now
        local ok, roots = pcall(find_enemy_roots)
        if ok then enemy.roots = roots else enemy_note("scan failed: " .. tostring(roots)) end
    end
    if now - enemy.last_send < 0.1 then return end
    enemy.last_send = now
    local parts = {}
    for i = #enemy.roots, 1, -1 do
        local ok, text = pcall(snapshot_one, enemy.roots[i])
        if ok then
            parts[#parts + 1] = text
        else
            table.remove(enemy.roots, i) -- gone or unreadable: the next scan will find it again if it is real
        end
    end
    local payload = #parts > 0 and table.concat(parts, ";") or "-"
    if #payload > 2900 then
        local cut = payload:find(";[^;]*$")
        if cut then payload = payload:sub(1, cut - 1) end
    end
    enemy.seq = enemy.seq + 1
    enemy.sent = enemy.sent + 1
    json.dump_file(FILES.STATE_OUT_FILE, { seq = enemy.seq, p = payload })
end

local function finite(v)
    return type(v) == "number" and v == v and v > -1e7 and v < 1e7
end

-- JOINER: read the latest snapshot from re7mp.exe.
local function enemy_read(now)
    enemy.last_read = now
    local d = json.load_file(FILES.STATE_IN_FILE)
    if type(d) ~= "table" or d.seq == nil or type(d.p) ~= "string" then return end
    if d.seq == enemy.remote_seq then return end
    enemy.remote_seq = d.seq
    enemy.received = tonumber(d.n) or (enemy.received + 1)
    enemy.remote_at = now
    local seen, count = {}, 0
    if d.p ~= "-" then
        for entry in d.p:gmatch("[^;]+") do
            local f = {}
            for field in entry:gmatch("[^,]+") do f[#f + 1] = field end
            local name = f[1]
            local v = {}
            for i = 2, 13 do v[i] = tonumber(f[i]) end
            if name and #f >= 13 and name:match("^[%w_]+$") and finite(v[2]) and finite(v[3]) and finite(v[4]) then
                count = count + 1
                if count > 40 then break end
                local e = enemy.remote[name]
                if not e then
                    e = { rx = v[2], ry = v[3], rz = v[4] }
                    enemy.remote[name] = e
                end
                e.x, e.y, e.z = v[2], v[3], v[4]
                e.qx, e.qy, e.qz, e.qw = v[5] or 0, v[6] or 0, v[7] or 0, v[8] or 1
                local fl = math.floor(v[10] or 1)
                e.hp, e.alive = v[9] or -1, fl % 2 == 1
                -- (9.10) a snapshot sent just before the host applied our hit still carries the old health: for a moment the host's answer wins
                if e.ack_hp and now < (e.ack_until or 0) and e.hp > e.ack_hp then e.hp = e.ack_hp end
                e.inactive = fl >= 2 and flags_reason(fl) or nil -- parked / placeholder objects (see inactive_flags)
                e.bank, e.motion, e.frame = v[11] or 0, v[12] or 0, v[13] or 0
                seen[name] = true
            end
        end
    end
    for name in pairs(enemy.remote) do
        if not seen[name] then enemy.remote[name] = nil end
    end
    enemy.count = count
    enemy.last = string.format("%d enemies from the host", count)
end

local function receiving_enemies()
    return enemy.mode >= 2 and (state.role == "join" or enemy.test_ghosts)
end

local function enemy_release_all()
    for name, d in pairs(enemy.driven) do
        for _, comp in ipairs(d.disabled or {}) do pcall(function() comp:call("set_Enabled", true) end) end
        enemy.driven[name] = nil
    end
end

local start_driving
do
local DRIVE_OFF = {
    "^app%.Em%d+Think$", "^app%.Em%d+Order$", "^app%.Em%d+%.Em%d+ActionController$", "^app%.MovementController$",
    "^via%.physics%.CharacterController$", "^app%.CommandActionController$", "^app%.Command%.CommandUpdater$",
    "^app%.Command%.CommandRequester$",
}

start_driving = function(name, root)
    local d = { go = root.go, xf = root.xf, disabled = {} }
    if enemy.drive_ai then
        pcall(function()
            local comps = root.go:call("get_Components")
            for _, c in ipairs(comps:get_elements()) do
                local full = c:get_type_definition():get_full_name()
                for _, pat in ipairs(DRIVE_OFF) do
                    if full:find(pat) then
                        local ok = pcall(function() c:call("set_Enabled", false) end)
                        if ok then d.disabled[#d.disabled + 1] = c end
                        break
                    end
                end
            end
        end)
    end
    enemy.driven[name] = d
    say(string.format("enemy sync: now moving my %s onto the host's (%d components switched off)", name, #d.disabled))
end
end -- do

-- JOINER, every frame: smooth the received positions; in mode 3 also put my own matching enemies there.
local function enemy_update(now, dt)
    if enemy.mode < 2 or not receiving_enemies() then
        if next(enemy.driven) then enemy_release_all() end
        return
    end
    if now - enemy.last_read >= 0.05 then enemy_read(now) end
    local a = 1 - math.exp(-12 * dt)
    for _, e in pairs(enemy.remote) do
        if e.x then
            local dx, dz = e.x - e.rx, e.z - e.rz
            if dx * dx + dz * dz > 64 then
                e.rx, e.ry, e.rz = e.x, e.y, e.z
            else
                e.rx = e.rx + (e.x - e.rx) * a
                e.ry = e.ry + (e.y - e.ry) * a
                e.rz = e.rz + (e.z - e.rz) * a
            end
        end
    end
    if enemy.mode < 3 or now - enemy.remote_at > 3 then
        if next(enemy.driven) then enemy_release_all() end
        return
    end
    if now - enemy.local_scan >= 1.0 then
        enemy.local_scan = now
        local ok, roots = pcall(find_enemy_roots)
        if ok then enemy.local_roots = roots end
    end
    for _, root in ipairs(enemy.local_roots) do
        local e = enemy.remote[root.name]
        if e and e.alive and not e.inactive then
            if not enemy.driven[root.name] then start_driving(root.name, root) end
            local d = enemy.driven[root.name]
            local ok, err = pcall(function()
                d.xf:call("set_Position", Vector3f.new(e.rx, e.ry, e.rz))
                local f = rotate({ x = e.qx, y = e.qy, z = e.qz, w = e.qw }, { 0, 0, 1 })
                d.xf:call("set_EulerAngle", Vector3f.new(0, math.atan(f[1], f[3]), 0))
            end)
            if not ok then
                enemy.driven[root.name] = nil
                enemy_note("could not move " .. root.name .. ": " .. tostring(err))
            end
        end
    end
end

local function unit_quat(e)
    local l = math.sqrt(e.qx * e.qx + e.qy * e.qy + e.qz * e.qz + e.qw * e.qw)
    if l < 1e-6 then return { x = 0, y = 0, z = 0, w = 1 } end
    return { x = e.qx / l, y = e.qy / l, z = e.qz / l, w = e.qw / l }
end

local function draw_enemies(now)
    if not receiving_enemies() or now - enemy.remote_at > 3 then return end
    local lp = state.local_pos
    if not lp then return end
    local cam = { lp.x, lp.y, lp.z }
    for name, e in pairs(enemy.remote) do
        if e.x and e.alive and (not e.inactive or enemy.show_parked) then
            local q = unit_quat(e)
            local ax, ay, az = rotate(q, { 1, 0, 0 }), rotate(q, { 0, 1, 0 }), rotate(q, { 0, 0, 1 })
            local foot = { e.rx, e.ry, e.rz }
            local center = vadd(foot, vscale(ay, 0.95))
            if e.inactive then -- only drawn when "show parked" is on: grey, with the reason in the label
                draw_box(make_box(center, ax, ay, az, 0.32, 0.95, 0.22), cam, { 150, 150, 150 }, 90, rgba(50, 50, 50, 200))
            else
                draw_box(make_box(center, ax, ay, az, 0.32, 0.95, 0.22), cam, { 255, 70, 70 }, 140, rgba(90, 0, 0, 230))
            end
            -- a bright block on the front of the head shows which way it faces
            local nose = vadd(vadd(foot, vscale(ay, 1.65)), vscale(az, 0.2))
            draw_box(make_box(nose, ax, ay, az, 0.08, 0.05, 0.05), cam, { 255, 230, 120 }, 230, rgba(90, 60, 0, 230))
            local tag = project({ e.rx, e.ry + 2.05, e.rz })
            if tag then
                local label = e.hp and e.hp >= 0 and string.format("%s  HP %d", name, e.hp) or name
                if e.inactive then label = label .. "  (" .. e.inactive .. ")" end
                draw.text(label, tag.x - #label * 3.5, tag.y - 14, e.inactive and 0xFFB0B0B0 or 0xFF4040FF)
            end
        end
    end
end

----------------------------------------------------------------------------------------------
-- Damage dealt by the joiner (9.10). The joiner sees the host's enemies as red boxes, and its bullets pass through them.
-- JOINER: when a shot is fired (see "shot signal" below) a ray from the camera is tested against the red boxes (and against
--   walls, with the same physics test the stand-in uses); the nearest box hit sends message kind 9, "x|Em2000|30|x|y|z".
-- HOST: the message is applied to the host's real enemy through the game's own damage call, so the enemy flinches or dies as
--   if the host had shot it: app.DamageController.newFakeDamageInfo(damage, attacker, target) and addManualDamage(info)
--   (both are in the enemy scan), falling back to addHitDamage and then to lowering the health value directly. The host
--   answers "a|name|how|before|after" so the joiner's box shows the new health at once.
-- Shot signal: nobody knows which field of the gun means "a bullet was fired", so button "Learn the shot signal" watches the
--   whole-number fields of the weapon components (app.WeaponGun, app.PlayerGun) while you fire three shots, and keeps the
--   one that went down by exactly one three times. Nothing is hooked. Until it is learned, the test button (aim at a box
--   and press it) sends the same message, so the whole path can be tried without a shot signal.
----------------------------------------------------------------------------------------------
enemy.hit = {
    MSG = 9,
    on = true,        -- joiner: send hits
    accept = true,    -- host: apply hits from the other player
    damage = 30,      -- joiner: damage per hit (sent with the hit; the host clamps it to 1..500)
    sent = 0, acked = 0, received = 0, applied = 0, refused = 0, failed = 0,
    shots = 0, misses = 0, walled = 0, fire_at = -10,
    last = "No hits yet.", host_last = "-", marks = {}, recent = {}, history = {},
    signal = nil,     -- { type = "app.WeaponGun", field = "..." }: learned, saved in the settings
    objs = {}, objs_at = -10, prev = {}, poll_at = -10, signal_hits = 0,
    BOX = { hx = 0.32, hy = 0.95, hz = 0.22, pad = 0.12 }, -- the red box that is drawn, plus a little slack
    TYPES = { "app.WeaponGun", "app.PlayerGun" },
    learn = { on = false, status = "not learned yet", t0 = 0, shots = 0, events = {}, prev = {}, seen = {}, candidates = {} },
    -- (9.12) the gun's own shot methods (app.PlayerGun.shoot / shootStart: they run once per shot, not every frame). The 0.7 file
    -- showed no whole-number FIELD of the weapon components goes down when you fire (the loaded bullets are a property of
    -- PlayerGun), so the shot is taken from the game calling these.
    hook = { on = true, tried = false, installed = {}, missing = {}, counts = {}, pending = nil, error = nil, used = 0 },
}

do
local HIT = enemy.hit

local function clampn(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- The nearest alive red box on the line o + t*d (t in 0..maxd), or nil. The box is the one draw_enemies draws.
function HIT.aim(o, d, maxd)
    local B = HIT.BOX
    local best
    for name, e in pairs(enemy.remote) do
        if e.x and e.alive and not e.inactive and e.rx then
            local q = unit_quat(e)
            local ax, ay, az = rotate(q, { 1, 0, 0 }), rotate(q, { 0, 1, 0 }), rotate(q, { 0, 0, 1 })
            local cx, cy, cz = e.rx + ay[1] * B.hy, e.ry + ay[2] * B.hy, e.rz + ay[3] * B.hy
            local ox, oy, oz = o.x - cx, o.y - cy, o.z - cz
            local lo = { ox * ax[1] + oy * ax[2] + oz * ax[3], ox * ay[1] + oy * ay[2] + oz * ay[3], ox * az[1] + oy * az[2] + oz * az[3] }
            local ld = { d[1] * ax[1] + d[2] * ax[2] + d[3] * ax[3], d[1] * ay[1] + d[2] * ay[2] + d[3] * ay[3], d[1] * az[1] + d[2] * az[2] + d[3] * az[3] }
            local h = { B.hx + B.pad, B.hy + B.pad, B.hz + B.pad }
            local tmin, tmax, hit = 0, maxd, true
            for i = 1, 3 do
                if math.abs(ld[i]) < 1e-9 then
                    if math.abs(lo[i]) > h[i] then hit = false break end
                else
                    local t1, t2 = (-h[i] - lo[i]) / ld[i], (h[i] - lo[i]) / ld[i]
                    if t1 > t2 then t1, t2 = t2, t1 end
                    if t1 > tmin then tmin = t1 end
                    if t2 < tmax then tmax = t2 end
                    if tmin > tmax then hit = false break end
                end
            end
            if hit and (not best or tmin < best.t) then
                best = { name = name, e = e, t = tmin, x = o.x + d[1] * tmin, y = o.y + d[2] * tmin, z = o.z + d[3] * tmin }
            end
        end
    end
    return best
end

-- true = solid level geometry between the camera and the point, false = clear, nil = cannot tell (no working physics test)
function HIT.wall_between(o, px, py, pz)
    local O = state.occ
    if not O or O.dead or not state.occlude then return nil end
    if not O.setup_done then O.setup() end
    if not O.ready or O.dead or not O.calibrated or #O.layers == 0 then return nil end
    local dx, dy, dz = px - o.x, py - o.y, pz - o.z
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    if l < 0.8 then return false end
    dx, dy, dz = dx / l, dy / l, dz / l
    local any_ok = false
    for _, layer in ipairs(O.layers) do
        local r = O.cast(layer, o.x + dx * 0.3, o.y + dy * 0.3, o.z + dz * 0.3, px - dx * 0.1, py - dy * 0.1, pz - dz * 0.1)
        if r == true then return true end
        if r == false then any_ok = true end
    end
    if any_ok then return false end
    return nil
end

-- JOINER: one shot. why = "ammo" / "test button".
function HIT.fire(now, why)
    if not HIT.on then HIT.last = "hits are switched off" return end
    if not receiving_enemies() then HIT.last = "no enemies from the host to hit" return end
    if now - HIT.fire_at < 0.12 then return end
    HIT.fire_at = now
    HIT.shots = HIT.shots + 1
    local ok, pos, quat = pcall(get_local_pose)
    if not ok or not pos then HIT.last = "shot (" .. why .. "): no camera" return end
    local fx, fy, fz = forward_of(quat)
    local best = HIT.aim(pos, { fx, fy, fz }, 80)
    if not best then
        HIT.misses = HIT.misses + 1
        HIT.last = string.format("shot (%s): no red box in the line of fire", why)
        return
    end
    local walled = HIT.wall_between(pos, best.x, best.y, best.z)
    if walled == true then
        HIT.walled = HIT.walled + 1
        HIT.last = string.format("shot (%s): %s is behind a wall", why, best.name)
        return
    end
    local dmg = clampn(math.floor(HIT.damage + 0.5), 1, 500)
    local e = best.e
    net_send(HIT.MSG, string.format("x|%s|%d|%.2f|%.2f|%.2f", best.name, dmg, e.x, e.y, e.z))
    HIT.sent = HIT.sent + 1
    HIT.marks[#HIT.marks + 1] = { x = best.x, y = best.y, z = best.z, text = "-" .. dmg, at = now }
    while #HIT.marks > 8 do table.remove(HIT.marks, 1) end
    HIT.last = string.format("shot (%s): hit %s at %.1f m, sent %d damage%s", why, best.name, best.t, dmg,
        walled == nil and " (walls not checked)" or "")
end

-- HOST: apply damage to a real enemy. Returns ok, how, health before, health after.
function HIT.apply(e, dmg)
    local before = read_health(e)
    if enemy_is_dead(e) then return false, "already dead", before, before end
    local dc = e.dmg_comp
    local attacker = player_object()
    local how, why
    if dc then
        local ok, info = pcall(dc.call, dc, "newFakeDamageInfo", dmg + 0.0, attacker, e.go)
        if ok and info then
            local ok2, rec = pcall(dc.call, dc, "addManualDamage", info)
            if ok2 and rec ~= nil then
                how = "addManualDamage"
            else
                why = "addManualDamage: " .. tostring(ok2 and "returned nothing" or rec)
                local ok3, rec3 = pcall(dc.call, dc, "addHitDamage", info)
                if ok3 and rec3 ~= nil then how = "addHitDamage" else why = why .. "; addHitDamage: " .. tostring(ok3 and "returned nothing" or rec3) end
            end
        else
            why = "newFakeDamageInfo: " .. tostring(ok and "returned nothing" or info)
        end
    else
        why = "no DamageController found"
    end
    if not how then -- the game's damage call did not work: lower the number directly (no flinch, and death may not play)
        local target = math.max((before >= 0 and before or 0) - dmg, 0)
        local done = false
        if dc then
            done = pcall(function() dc:call("getHealthInfo"):call("set_health", target + 0.0) end)
            if done then how = "set_health" end
        end
        if not done and e.hp_comp and e.hp_field then
            done = pcall(function() e.hp_comp:set_field(e.hp_field, target + 0.0) end)
            if done then how = "health field" end
        end
        if not done then return false, why or "nothing worked", before, before end
    end
    return true, how, before, read_health(e)
end

-- HOST: a hit arrived from the other player.
function HIT.receive_hit(rest, now)
    HIT.received = HIT.received + 1
    local name, dmg, x, y, z = rest:match("^([%w_]+)|(%d+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)$")
    if not name then
        HIT.refused = HIT.refused + 1
        HIT.host_last = "a damaged hit message was ignored"
        return
    end
    local function refuse(reason)
        HIT.refused = HIT.refused + 1
        HIT.host_last = string.format("%s: refused (%s)", name, reason)
        net_send(HIT.MSG, string.format("a|%s|refused|-1|-1", name))
    end
    if state.role ~= "host" then return refuse("I am not the host") end
    if not HIT.accept then return refuse("hits from the other player are switched off") end
    for i = #HIT.recent, 1, -1 do
        if now - HIT.recent[i] > 1 then table.remove(HIT.recent, i) end
    end
    if #HIT.recent >= 10 then return refuse("more than 10 hits a second") end
    HIT.recent[#HIT.recent + 1] = now
    dmg = clampn(tonumber(dmg) or 1, 1, 500)
    if #enemy.roots == 0 then
        local okr, roots = pcall(find_enemy_roots)
        if okr then enemy.roots = roots end
    end
    local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
    local pick, pick_d
    for _, e in ipairs(enemy.roots) do
        if e.name == name then
            local okp, p = pcall(function() return e.xf:call("get_Position") end)
            local d = okp and p and ((p.x - px) ^ 2 + (p.y - py) ^ 2 + (p.z - pz) ^ 2) or 1e9
            if not pick or d < pick_d then pick, pick_d = e, d end
        end
    end
    if not pick then return refuse("no enemy called " .. name .. " here") end
    if (pick.last_flags or 1) >= 2 then return refuse(name .. " is not a live enemy (" .. flags_reason(pick.last_flags) .. ")") end
    local ok, okc, how, before, after = pcall(HIT.apply, pick, dmg)
    if not ok then okc, how, before, after = false, tostring(okc), -1, -1 end
    if okc then
        HIT.applied = HIT.applied + 1
        HIT.host_last = string.format("%s: %d damage by %s, health %s -> %s", name, dmg, how, tostring(before), tostring(after))
    else
        HIT.failed = HIT.failed + 1
        HIT.host_last = string.format("%s: could not damage (%s)", name, tostring(how))
    end
    HIT.history[#HIT.history + 1] = { name = name, damage = dmg, ok = okc, how = how, before = before, after = after }
    while #HIT.history > 12 do table.remove(HIT.history, 1) end
    say("enemy hit: " .. HIT.host_last)
    net_send(HIT.MSG, string.format("a|%s|%s|%d|%d", name, okc and how or "failed", math.floor(before or -1), math.floor(after or -1)))
end

-- JOINER: the host's answer.
function HIT.receive_ack(rest)
    local name, how, before, after = rest:match("^([%w_]+)|([^|]*)|([%-%d]+)|([%-%d]+)$")
    if not name then return end
    HIT.acked = HIT.acked + 1
    HIT.host_last = string.format("host: %s %s (health %s -> %s)", name, how, before, after)
    local e = enemy.remote[name]
    local hp = tonumber(after)
    if e and hp and hp >= 0 and how ~= "refused" and how ~= "failed" then
        e.hp, e.ack_hp, e.ack_until = hp, hp, os.clock() + 0.6
    end
end

net_on(HIT.MSG, function(payload)
    local kind, rest = tostring(payload):match("^(%a)|(.*)$")
    if kind == "x" then HIT.receive_hit(rest, os.clock()) elseif kind == "a" then HIT.receive_ack(rest) end
end)

-- ---- the shot signal ----
-- The whole-number fields of one component: { field name -> value }. (Counters of bullets are whole numbers.)
function HIT.number_fields(obj)
    local out, n = {}, 0
    pcall(function()
        local t = obj:get_type_definition()
        while t and n < 120 do
            local tn = t:get_full_name()
            if tn:find("^System%.") or tn:find("^via%.Component") or tn:find("^via%.Behavior") or tn:find("^via%.Object") then break end
            for _, f in ipairs(t:get_fields() or {}) do
                if not f:is_static() then
                    local nm = f:get_name()
                    local okv, v = pcall(function() return obj:get_field(nm) end)
                    if okv and type(v) == "number" and v == math.floor(v) and math.abs(v) < 1e6 then
                        out[nm] = v
                        n = n + 1
                    end
                end
            end
            t = t:get_parent_type()
        end
    end)
    return out
end

-- The weapon components in the scene: { { key, obj, type } }, looked up at most once a second.
function HIT.weapons(now)
    if now - HIT.objs_at < 1 then return HIT.objs end
    HIT.objs_at = now
    local list = {}
    local scene = scene_object()
    if scene then
        for _, tn in ipairs(HIT.TYPES) do
            local ok, arr = pcall(function() return scene:call("findComponents(System.Type)", sdk.typeof(tn)) end)
            if ok and arr then
                local oke, elems = pcall(function() return arr:get_elements() end)
                if oke then
                    for i, c in ipairs(elems) do
                        if i > 12 then break end
                        local oka, addr = pcall(c.get_address, c)
                        list[#list + 1] = { key = tn .. "@" .. (oka and tostring(addr) or tostring(i)), obj = c, type = tn }
                    end
                end
            end
        end
    end
    HIT.objs = list
    return list
end

function HIT.install_hook()
    local K = HIT.hook
    if K.tried or not K.on then return end
    K.tried = true
    local td = sdk.find_type_definition("app.PlayerGun")
    if not td then
        K.error = "app.PlayerGun not found"
        return
    end
    local CALL_ORIGINAL = sdk.PreHookResult and sdk.PreHookResult.CALL_ORIGINAL
    for _, name in ipairs({ "shoot", "shootStart" }) do
        local okm, m = pcall(function() return td:get_method(name) end)
        if okm and m then
            tracer.crumb("hooking", "app.PlayerGun." .. name)
            local ok = pcall(sdk.hook, m, function(args)
                K.counts[name] = (K.counts[name] or 0) + 1
                if K.on then K.pending = os.clock() end
                return CALL_ORIGINAL
            end, function(retval) return retval end)
            tracer.crumb("clean", "hook installed: app.PlayerGun." .. name)
            if ok then K.installed[#K.installed + 1] = name else K.missing[#K.missing + 1] = name end
        else
            K.missing[#K.missing + 1] = name
        end
    end
    say("shot signal: hooked the gun's " .. (#K.installed > 0 and table.concat(K.installed, ", ") or "nothing") .. (#K.missing > 0 and (" (not found: " .. table.concat(K.missing, ", ") .. ")") or ""))
end

function HIT.learn_start(now)
    local L = HIT.learn
    L.on, L.t0, L.shots, L.events, L.prev, L.candidates = true, now, 0, {}, {}, {}
    L.hook_shots = 0
    HIT.install_hook()
    L.status = "fire three shots now (15 s)"
    HIT.objs_at = -10
    say("shot signal: watching the weapon components; fire three shots")
end

function HIT.learn_finish(now, why)
    local L = HIT.learn
    L.on = false
    local best, best_n, best_score
    local keys = {}
    for tf in pairs(L.events) do keys[#keys + 1] = tf end
    table.sort(keys) -- the same answer every time when two fields tie
    for _, tf in ipairs(keys) do
        local ev = L.events[tf]
        local n = #ev
        L.candidates[#L.candidates + 1] = { field = tf, drops_of_one = n }
        if n >= 3 and n <= 6 then
            local nm = tf:lower()
            local score = -math.abs(n - 3) * 10 + ((nm:find("bullet") or nm:find("ammo") or nm:find("remain") or nm:find("mag") or nm:find("load") or nm:find("num") or nm:find("count")) and 1 or 0)
            if not best_score or score > best_score then best, best_n, best_score = tf, n, score end
        end
    end
    table.sort(L.candidates, function(a, b) return a.drops_of_one > b.drops_of_one end)
    while #L.candidates > 15 do table.remove(L.candidates) end
    if best then
        local tn, field = best:match("^(.-)|(.*)$")
        HIT.signal = { type = tn, field = field }
        L.status = string.format("learned: %s.%s went down by one %d times", tn, field, best_n)
        HIT.prev = {}
    elseif (L.hook_shots or 0) >= 1 then
        L.status = string.format("the gun's own shoot call ran %d times while you fired: shots are taken from it (no field needed)", L.hook_shots)
    else
        L.status = (why or "finished") .. ": no field went down by exactly one 3 to 6 times and the gun's shoot call did not run (" .. #L.candidates .. " candidates, see the debug file)"
    end
    say("shot signal: " .. L.status)
end

-- every frame (joiner): the learner, and the learned signal
function HIT.update(now)
    local L = HIT.learn
    if L.on then
        if now - L.t0 > 15 then
            HIT.learn_finish(now, "time is up")
        else
            if HIT.hook.pending then
                HIT.hook.pending = nil
                L.hook_shots = (L.hook_shots or 0) + 1
                if L.hook_shots >= 3 and now - L.t0 > 1 then L.done_at = L.done_at or (now + 1.0) end
            end
            for _, w in ipairs(HIT.weapons(now)) do
                local nums = HIT.number_fields(w.obj)
                local prev = L.prev[w.key]
                if prev then
                    for fname, v in pairs(nums) do
                        local pv = prev[fname]
                        if pv and pv - v == 1 then
                            local tf = w.type .. "|" .. fname
                            local ev = L.events[tf] or {}
                            if #ev == 0 or now - ev[#ev] > 0.1 then ev[#ev + 1] = now end
                            L.events[tf] = ev
                        end
                    end
                end
                L.prev[w.key] = nums
            end
            local most = L.hook_shots or 0
            for _, ev in pairs(L.events) do if #ev > most then most = #ev end end
            L.shots = most
            if most >= 3 and now - L.t0 > 1 then
                -- three drops seen: wait a moment for a fourth (a miscounted field would keep counting), then decide
                L.done_at = L.done_at or (now + 1.5)
                if now >= L.done_at then L.done_at = nil HIT.learn_finish(now, "three shots seen") end
            end
        end
        return
    end
    -- (9.12) a shot the game itself reported (the hook only notes the time; the ray test runs here, in the frame)
    if HIT.on and HIT.hook.on and not HIT.hook.tried and receiving_enemies() then HIT.install_hook() end
    local pend = HIT.hook.pending
    if pend then
        HIT.hook.pending = nil
        if HIT.on and receiving_enemies() and not (state.role == "host" and not enemy.test_ghosts) then
            HIT.hook.used = HIT.hook.used + 1
            HIT.fire(now, "the gun's shoot call")
        end
    end
    local sig = HIT.signal
    if not sig or not HIT.on or not receiving_enemies() or state.role == "host" and not enemy.test_ghosts then return end
    if now - HIT.poll_at < 0.04 then return end
    HIT.poll_at = now
    for _, w in ipairs(HIT.weapons(now)) do
        if w.type == sig.type then
            local ok, v = pcall(function() return w.obj:get_field(sig.field) end)
            if ok and type(v) == "number" then
                local pv = HIT.prev[w.key]
                HIT.prev[w.key] = v
                if pv and pv > v and pv - v <= 3 then
                    HIT.signal_hits = HIT.signal_hits + 1
                    HIT.fire(now, "ammo")
                end
            end
        end
    end
end

-- floating damage numbers
function HIT.draw(now)
    for i = #HIT.marks, 1, -1 do
        local m = HIT.marks[i]
        local age = now - m.at
        if age > 0.9 then
            table.remove(HIT.marks, i)
        else
            local sp = project({ m.x, m.y + age * 0.6, m.z })
            if sp then draw.text(m.text, sp.x - 10, sp.y - 6, 0xFF40FFFF) end
        end
    end
end

function HIT.report()
    local L = HIT.learn
    local first = HIT.objs[1]
    local nums = {}
    if first then
        for k in pairs(HIT.number_fields(first.obj)) do nums[#nums + 1] = k end
        table.sort(nums)
        while #nums > 40 do table.remove(nums) end
    end
    local kinds = {}
    for _, w in ipairs(HIT.objs) do kinds[w.type] = (kinds[w.type] or 0) + 1 end
    return { joiner_hits_on = HIT.on, host_accepts = HIT.accept, damage_per_hit = HIT.damage,
        shots_tested = HIT.shots, no_box_in_line = HIT.misses, behind_wall = HIT.walled, sent = HIT.sent, answered = HIT.acked,
        received = HIT.received, applied = HIT.applied, refused = HIT.refused, failed = HIT.failed,
        last = HIT.last, host_last = HIT.host_last, host_history = HIT.history,
        signal = HIT.signal, signal_shots = HIT.signal_hits,
        gun_hook = { on = HIT.hook.on, installed = HIT.hook.installed, not_found = HIT.hook.missing, calls = HIT.hook.counts,
            shots_used = HIT.hook.used, error = HIT.hook.error },
        learner = { status = L.status, candidates = L.candidates },
        weapon_components = kinds, first_weapon_number_fields = nums }
end
end -- do


-- ---- what to send me for the next step ----
local ENEMY_DBG = {}
ENEMY_DBG.key_types = {
    "app.Em2000Status", "app.Em3000Status", "app.EnemySave", "app.Em2000Think", "app.Em2000Order",
    "app.Em2000.Em2000DamageController", "app.Em3000.Em3000DamageController", "app.Collision.CalculateDamage",
    "app.EnemySceneSurveillance", "app.EnemyExistZone", "app.AI.MansionAISetController", "app.AI.Em3000MansionAISetInfo",
    "app.AI.MansionAI", "app.AI.AIWorldBlackBoard", "app.EnemyRankManager",
    "app.DamageController", "app.EnemyDamageController", "app.EnemyStatus", "app.Em3100Status", "app.Em3100DamageController",
}
-- Small types whose every method is listed (the health and damage records)
ENEMY_DBG.list_all = { "app.HealthInfo", "app.DamageController.DamageRecord", "app.Collision.HitController.DamageInfo" }
ENEMY_DBG.method_words = { "hp", "damage", "dead", "die", "kill", "life", "health", "alive", "spawn", "set", "create", "active", "hit" }
ENEMY_DBG.dump_components = {
    "^app%.Em%d+Status$", "^app%.EnemySave$", "^app%.Em%d+Think$", "^app%.Em%d+Order$", "^app%.Em%d+%.Em%d+DamageController$",
    "^app%.EnemyRankManager$", "^app%.Humanoid$", "^app%.MovementController$",
}

local function enemy_details()
    pinned(function()
        say("=== enemy details ===")
        local ok, roots = pcall(find_enemy_roots)
        if not ok then
            say("enemy details: scan failed: " .. tostring(roots))
            roots = {}
        end
        say(#roots .. " enemy root objects")
        for _, e in ipairs(roots) do
            pcall(function()
                local p = e.xf:call("get_Position")
                say(string.format("-- %s at %.2f, %.2f, %.2f", e.name, p.x, p.y, p.z))
                local bank, motion, frame = read_motion(e)
                say(string.format("   animation layer 0: bank %d, motion %d, frame %.1f", bank, motion, frame))
                if not e.hp_checked then find_health(e) end
                local fl = inactive_flags(e, motion, p)
                say(string.format("   Status component: %s; health read from: %s; looks like: %s",
                    e.status and "yes" or "NO", e.hp_field and ((e.hp_where and (e.hp_where .. ".") or "") .. e.hp_field) or "nothing found",
                    fl == 0 and "a live enemy" or flags_reason(fl)))
                for _, c in ipairs(e.go:call("get_Components"):get_elements()) do
                    local full = c:get_type_definition():get_full_name()
                    for _, pat in ipairs(ENEMY_DBG.dump_components) do
                        if full:find(pat) then
                            say("   component " .. full)
                            dump_fields(c, "      ", 90)
                            if full:find("DamageController$") or full:find("^app%.Em%d+Status$") then
                                for _, hv in ipairs(fields_of_type(c, "app.HealthInfo")) do
                                    say("      HealthInfo object in field " .. hv[1] .. ":")
                                    dump_fields(hv[2], "         ", 40)
                                end
                            end
                            break
                        end
                    end
                end
            end)
        end
        say("=== enemy methods (hp / damage / dead / spawn related) ===")
        for _, n in ipairs(ENEMY_DBG.key_types) do probe_type(n, false, ENEMY_DBG.method_words, 70) end
        for _, n in ipairs(ENEMY_DBG.list_all) do probe_type(n, true, nil, 60) end
        say("=== enemy details done ===")
    end)
end

-- Hooks the damage and health methods of the enemies that exist right now (their own Status / DamageController
-- types, whatever they are called) plus the shared base types, and writes the damage records as text.
local function trace_enemy_damage()
    local names, seen = {}, {}
    local function add(n)
        if not seen[n] then
            seen[n] = true
            names[#names + 1] = n
        end
    end
    for _, n in ipairs({ "app.DamageController", "app.EnemyDamageController", "app.EnemyStatus", "app.HealthInfo",
        "app.Collision.CalculateDamage" }) do
        add(n)
    end
    local ok, roots = pcall(find_enemy_roots)
    for _, r in ipairs(ok and roots or {}) do
        pcall(function()
            for _, c in ipairs(r.go:call("get_Components"):get_elements()) do
                local full = c:get_type_definition():get_full_name()
                if full:find("^app%.Em%d+Status$") or full:find("DamageController$") then add(full) end
            end
        end)
    end
    tracer_add("enemy damage trace: " .. #names .. " types: " .. table.concat(names, ", "))
    for _, n in ipairs(names) do trace_type(n, "", false) end
    tracer_add("now shoot an enemy once, then send the debug file")
end

-- What the game returns for an item's name and count (type and value of every getter I try).
local function dump_item_getters(item, indent)
    local rid, rsrc, rwhy = resolve_item_id(item)
    say(string.format("%sname resolved: %s", indent, rid and (rid .. "  (from " .. tostring(rsrc) .. ")") or ("NO. " .. tostring(rwhy))))
    for _, f in ipairs(fields_of_type(item, "System.String")) do
        say(string.format("%stext field %s = %s", indent, f[1], dump_value(f[2])))
    end
    local okg, go = pcall(function() return item:call("get_GameObject") end)
    if okg and go ~= nil then
        local okn, nm = pcall(function() return go:call("get_Name") end)
        say(string.format("%sGameObject name = %s", indent, okn and dump_value(nm) or "(unreadable)"))
    end
    local oks, sd = pcall(function() return item:call("getItemSaveData") end)
    if oks and sd ~= nil and type(sd) ~= "number" and type(sd) ~= "string" then
        say(indent .. "getItemSaveData -> " .. dump_value(sd))
        dump_fields(sd, indent .. "   ", 20)
    end
    for _, g in ipairs(give.id_getters) do
        local ok, v = pcall(function() return item:call(g) end)
        say(string.format("%s%s -> %s", indent, g, ok and (type(v) .. " " .. dump_value(v) .. (as_text(v) and (" text=" .. as_text(v)) or "")) or "(no such method / error)"))
    end
    for _, g in ipairs(give.count_getters) do
        local ok, v = pcall(function() return item:call(g) end)
        say(string.format("%s%s -> %s", indent, g, ok and (type(v) .. " " .. dump_value(v)) or "(no such method / error)"))
    end
end

-- The inventory list and the item the cursor is on, to learn how items are named and counted.
dump_focused_item = function()
    pinned(function()
        say("=== highlighted item ===")
        say(string.format("the pointing hook fired %d times", give.hover_seen or 0))
        local f = give.focus
        if not f then
            say("nothing pointed at yet: open the inventory and move the cursor onto an item first")
        else
            say(string.format("pointed-at item: id %s, count %d, seen %.1f s ago", tostring(f.id), f.count, os.clock() - f.at))
            dump_item_getters(f.item, "   ")
            dump_fields(f.item, "   ", 60)
        end
        local inv = inventory_object()
        say(inv and "inventory object found" or "inventory object NOT found")
        if inv then
            local okl, list = pcall(function() return inv:get_field("_ItemList") end)
            if okl and list then
                local entries = list_elements(list)
                say(string.format("_ItemList has %d entries", #entries))
                for i, info in ipairs(entries) do
                    if i > 4 then break end
                    say(string.format("   entry %d: %s", i, dump_value(info)))
                    dump_fields(info, "      ", 30)
                    local item = item_of_info(info)
                    say(string.format("   entry %d item: %s", i, item and dump_value(item) or "(no app.Item found in it)"))
                    if item then dump_item_getters(item, "      ") end
                end
                local items, note = inventory_items()
                say(string.format("readable items: %d%s", items and #items or 0, note and (" (" .. note .. ")") or ""))
                for _, it in ipairs(items or {}) do say(string.format("   %s x%d", it.id, it.count)) end
            else
                say("_ItemList not readable")
            end
        end
        say("player object " .. (player_object() and "found" or "NOT found") .. ", item manager "
            .. (item_manager() and "found" or "NOT found"))
        -- the game's inventory screen does not redraw after a give/receive: which methods could refresh it?
        for _, n in ipairs({ "app.InventoryMenu", "app.InventorySystem", "app.InventoryManager" }) do
            probe_type(n, false, { "refresh", "redraw", "setup", "reload", "reset", "rebuild", "create", "open", "list", "item", "dirty", "request" }, 60)
        end
        say("=== highlighted item done ===")
    end)
end

-- Player health and the "downed" experiment (the module that fills this table is further down, after the death code).
local pstat = {
    revive_radius = 3.0,    -- metres: how close the helper must be (to use a healing item on you / revive with F8). 9.14: 3 m (was 4): the Baker house halls are narrow
    revive_hold = 3.0,      -- seconds F8 has to be waited out inside that radius before the item is used (9.14)
    reviving = nil,         -- { since } while an F8 revive is counting down
    revive_stats = { started = 0, done = 0, cancelled = 0 },
    revive_pct = 30,        -- health you get back when revived, in percent of your maximum
    heal_words = { "herb", "chem", "remedy" }, -- an item whose name contains one of these counts as a healing item
    hotkey = 0x77,          -- F8: use a healing item on the downed player next to you
    key_was_down = false,
    hi = nil, field = nil, max_field = nil, where = nil, int_field = false, go_addr = nil, hi_addr = nil,
    hp = nil, max = nil, seen_max = 0,
    scanned_at = -10, read_at = 0, read_fail = 0, mute_until = 0,
    sent_hp = nil, sent_at = -10, peer_was = false, sent = 0, received = 0, send_state_at = -10,
    last_use = nil,         -- the last healing item the game consumed: { name, at }
    remote = nil,           -- what the other player told us: { hp, max, downed, at }
    downed = false, pending_down = false, clamped = 0, heals = 0, hurts = 0, revives = 0,
    writing = false, grace_until = 0, hooked = false, use_hooked = false,
    last = "No health events yet.",
}

----------------------------------------------------------------------------------------------
-- Death sync. "Shared fate": when one player dies the other dies too.
-- Death is detected when the game switches to its game-over GameMode (found by name in the enum, see
-- build_mode_map); the other game is put into the same mode. Both parts are untested guesses until a
-- real death has been tried, so the default is "Independent" and the choice is in the panel.
----------------------------------------------------------------------------------------------
local DEATH_MSG = 4
local DEATH_MODES = {
    "Independent (nothing happens)",
    "Shared fate: both players die",
    "Dead player waits for the other (not built yet)",
    "Downed and revive (EXPERIMENTAL: needs the other player)",
}
local death = { mode = 1, suppress_until = 0, last = "No deaths yet.", sent = 0, received = 0 }

local function apply_remote_death(who)
    death.received = death.received + 1
    if death.mode == 4 then -- downed mode: the other player really died, which only matters if I am down too (team wipe)
        if pstat.downed then
            death.last = who .. " died while you were down: you die too."
            chat_add("Death", death.last)
            death.suppress_until = os.clock() + 30
            pstat.no_hold_until = os.clock() + 20 -- a debug file showed the hold writing 1 back ten times a second for six seconds
            local ok, err = RE7.kill_local_player()
            if not ok then death.last = death.last .. " (could not kill you: " .. tostring(err) .. ")" end
        else
            death.last = who .. " died (you are not down, so nothing happens to you)."
            chat_add("Death", death.last)
        end
        return
    end
    if death.mode ~= 2 then
        death.last = who .. " died (shared fate is off, nothing happens)."
        chat_add("Death", death.last)
        return
    end
    local now = os.clock()
    if now < death.suppress_until then
        death.last = who .. " died (you are already dying)."
        return
    end
    death.suppress_until = now + 30 -- our own game-over must not bounce back
    local ok, err = RE7.kill_local_player()
    death.last = ok and (who .. " died: you die with them (shared fate).")
        or (who .. " died but I could not kill you: " .. tostring(err))
    chat_add("Death", death.last)
    say(death.last)
end

net_on(DEATH_MSG, function(payload)
    apply_remote_death(state.remote_name or CFG.DEFAULT_NAME)
end)

-- Called for every setGamemode(value) the game makes.
RE7.on_death_signal = function(source)
    if pstat.reset_down then pstat.reset_down("the game ended", true) end
    local now = os.clock()
    if now < death.suppress_until then return end
    say("death signal: " .. tostring(source))
    death.suppress_until = now + 30 -- the game-over screen can set the mode more than once
    if death.mode == 4 and now - state.remote_changed_at < CFG.STALE_AFTER then
        net_send(DEATH_MSG, "died")
        death.sent = death.sent + 1
        death.last = "You died for real (told the other player: they die too if they are down)."
        if pstat.clamped > 0 and not (pstat.remote and pstat.remote.downed) then
            death.last = death.last .. " NOTE: I held your health at 1 " .. pstat.clamped
                .. " time(s) and the game still ended: holding the health up is not enough, see button 8."
        end
    elseif death.mode == 2 and now - state.remote_changed_at < CFG.STALE_AFTER then
        net_send(DEATH_MSG, "died")
        death.sent = death.sent + 1
        death.last = "You died: told the other player (shared fate)."
    else
        death.last = "You died (nothing sent: " .. (death.mode == 2 and "nobody is connected" or "shared fate is off") .. ")."
    end
    chat_add("Death", death.last)
    say(death.last)
end

RE7.on_gamemode = function(value)
    say("game mode set to " .. tostring(value))
    if RE7.death_value == nil or value ~= RE7.death_value then return end
    RE7.on_death_signal("game mode " .. tostring(RE7.death_name))
end

-- (9.11) Other ways a death can start. Your notes say the finishers (Jack's grab, Mia in the attic) never reached the game-over
-- mode switch above. So any method of the game manager or of the player's damage controller that is named like a game over or
-- a death is watched too (never getters; at most 8 in all; one that fires more than 50 times is ignored as too busy), and
-- every firing goes into the journal, so the next file shows which call a finisher really makes.
RE7.death_hooks = {}
function RE7.install_death_extras()
    local want = {
        { "app.GameManager", { "setgameover", "requestgameover", "startgameover", "dogameover", "ongameover" } },
        { "app.PlayerDamageController", { "dodie", "ondie", "die", "dokill", "kill", "setdead", "dodead", "ondead", "setdie" } },
    }
    for _, w in ipairs(want) do
        local tn, prefixes = w[1], w[2]
        local td = sdk.find_type_definition(tn)
        local done = {}
        for _, m in ipairs(td and td:get_methods() or {}) do
            local name = m:get_name()
            local low = name:lower()
            if not done[name] and #RE7.death_hooks < 8 then
                for _, pre in ipairs(prefixes) do
                    if low:find("^" .. pre) then
                        done[name] = true
                        local fired = 0
                        if hook_method(tn, name, function(args)
                            fired = fired + 1
                            if fired > 50 then return end
                            if fired <= 5 then say(string.format("death hook fired: %s.%s (#%d)", tn, name, fired)) end
                            if tn == "app.GameManager" and low:find("flag", 1, true) then -- a flag being cleared is not a death
                                local okv, v = pcall(function() return sdk.to_int64(args[3]) end)
                                if okv and type(v) == "number" and v % 256 == 0 then return end
                            end
                            RE7.on_death_signal(name)
                        end) then
                            RE7.death_hooks[#RE7.death_hooks + 1] = tn .. "." .. name
                        end
                        break
                    end
                end
            end
        end
    end
    say("death detection also watches: " .. (#RE7.death_hooks > 0 and table.concat(RE7.death_hooks, ", ") or "nothing else was found"))
end

----------------------------------------------------------------------------------------------
-- Player health (v9.3): reads your health, tells the other player, and works out events from it.
--  * Your health is looked for in the components of the player object (Pl0000): an app.HealthInfo held by the
--    player's DamageController (the class the enemies use too: Health / MaxHealth). The panel and the debug
--    file say where it was found, or that it was not.
--  * Changes are sent as message kind 7: "h|hp|max|down" (at most twice a second, plus a heartbeat every 3 s).
--    The other player sees "HP 65%" over your head.
--  * A heal is a rise in health. When it follows a healing item being used (app.Inventory.reduceItem on a
--    Herb / Chem Fluid / Remedy) the other player is told "e|heal|Herb|x|y|z".
--  * Death mode 4, "Downed and revive" (EXPERIMENTAL, needs the other player connected): a hit that would take
--    your health to 0 is held at 1 instead (a hook after HealthInfo.set_health, plus a check ten times a
--    second). You are then "down" and cannot heal yourself; the other player gets you up by using a healing
--    item next to you (their own Herb / Chem Fluid use), or stays next to you for a few seconds with F8 (no item, the wait
--    is the cost). Because the game never
--    saw you die it never reloads a checkpoint, so you get up where you fell. If both of you are down, or the
--    hold does not work, the game ends as usual. Nothing here has been tried in the real game yet.
----------------------------------------------------------------------------------------------
do
local H = {}
H.PH_MSG = 7
H.BOT_MSG = 11 -- (9.13) a command only the loopback bot understands ("down" / "up"); a real player's script has no handler for it
H.CALL_ORIGINAL = sdk.PreHookResult and sdk.PreHookResult.CALL_ORIGINAL

H.PLAYER_WORDS = { "damage", "guard", "block", "heal", "recover", "health", "hp", "die", "dead", "death", "down", "dying",
    "revive", "knock", "kill", "faint", "life", "grapple", "caught", "stun", "parry", "shield", "defen", "hit", "avoid",
    "item", "use" }
-- components of Pl0000 looked at first (the rest of the app.Player* ones follow)
H.PLAYER_FIRST = { "app.PlayerDamageController", "app.PlayerStatus", "app.PlayerOrder", "app.PlayerStrikeController",
    "app.PlayerLArmDamage", "app.PlayerExternalRequestController", "app.PlayerGrappleEm2000", "app.PlayerGrappleEm3000",
    "app.PlayerItem", "app.PlayerEventActionManager", "app.PlayerSequenceManager", "app.PlayerBreathController",
    "app.PlayerCommandUpdater", "app.PlayerHands", "app.PlayerMelee" }
H.PLAYER_DUMP = { ["app.PlayerDamageController"] = true, ["app.PlayerStatus"] = true, ["app.PlayerOrder"] = true,
    ["app.PlayerLArmDamage"] = true, ["app.PlayerBreathController"] = true, ["app.PlayerStrikeController"] = true,
    ["app.PlayerExternalRequestController"] = true, ["app.PlayerCommandUpdater"] = true }
-- event / cutscene / flow classes from your component census, and the method names worth watching in them
H.EVENT_TYPES = { "app.GameEventManager", "app.GameEventController", "app.GameEventActionController", "app.GameEventAction",
    "app.GameEventSetting", "app.EventActionController", "app.SequenceController", "app.TimeLineContainer",
    "app.TimeLineKicker", "app.TimeLineKickerContainer", "app.TimeLinePlayStateControlManager", "app.TimeLineStateInfo",
    "app.GameFlowFsmManager", "app.GameFlowActiveControl", "app.ChapterLoadTempManager", "app.ChapterJumpData",
    "app.PlayerEventActionManager", "app.InteractEventAction", "app.DoorEventAction", "app.FadeControl",
    "app.NowLoadingScreen", "app.TriggerInAction" }
-- Opt-in extras (9.6). The 9.5 button 9 hooked 77 DoorPush, 15 InteractObjectBase, 13 GameManager and 75 SaveDataManager
-- methods at once and the game crashed a few seconds later while a door was closing; the log cannot say which hook did it.
-- So these are hand-picked, off by default and ticked one at a time. "=" in front of a name means exactly that method.
-- The player's doors are app.DoorPush (the 8 DoorEventActions in the scene are monsters' doors and never fired); the
-- names below are the ones the 9.5 trace saw fire for a door, plus a few likely ones that are simply skipped if absent.
H.EVENT_EXTRAS = {
    doors = { label = "doors (app.DoorPush and app.InteractObjectBase, hand-picked methods only)", types = {
        { "app.DoorPush", { "=setInteract", "=playAutoOpen", "=playLittleOpen", "=playOpened", "=playAutoClose", "=playClosed",
            "=closeDoorCore", "=lockDoor", "=lockDoorCore", "=unlockDoor", "=unlockDoorCore", "=openDoor", "=closeDoor" } },
        { "app.InteractObjectBase", { "=successInteract", "=failInteract", "=failedInteract" } } } },
    flags = { label = "story flags and chapter jumps (app.GameManager)", types = {
        { "app.GameManager", { "=setFsmGlobalBoolValue", "=setFsmGlobalIntValue", "=addFsmGlobalIntValue", "=chapterJumpRequest",
            "=nextChapterJumpRequest", "=requestEvent", "=setGameOverFlag", "=setTitleReturnFlag" } } } },
    saves = { label = "save and load calls (app.SaveDataManager)", types = {
        { "app.SaveDataManager", { "=saveFileGameSaveData", "=loadFileAutoRequest", "=loadFileGameSaveData", "=saveFileAutoRequest",
            "=newGameInit" } } } },
}
H.EXTRA_ORDER = { "doors", "flags", "saves" }
H.extra_on = { doors = false, flags = false, saves = false }
H.EVENT_WORDS = { "start", "end", "play", "stop", "begin", "finish", "trigger", "kick", "skip", "execute", "enter", "exit",
    "request", "unlock", "chapter", "load", "fade", "complete", "jump", "event", "cutscene", "demo", "movie", "scene" }

function H.note(text)
    pstat.last = text
    say("health: " .. text)
end

function H.who_is_there() return state.remote_name or CFG.DEFAULT_NAME end

function H.read_num(obj, field)
    local ok, v = pcall(function() return obj:get_field(field) end)
    if ok and type(v) == "number" then return v end
    return nil
end

function H.address_of(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    if ok and type(a) == "number" then return a end
    return nil
end

-- Numeric fields of obj and its app.* parents: { {name, type name}, ... }
function H.numeric_fields(obj)
    local out = {}
    pcall(function()
        local t = obj:get_type_definition()
        while t do
            local tn = t:get_full_name()
            if tn:find("^System%.") or tn:find("^via%.Component") or tn:find("^via%.Behavior") then break end
            for _, f in ipairs(t:get_fields() or {}) do
                if not f:is_static() then
                    local ft = f:get_type()
                    local ftn = ft and ft:get_full_name() or ""
                    if ftn == "System.Single" or ftn == "System.Int32" or ftn == "System.Double" then
                        out[#out + 1] = { f:get_name(), ftn }
                    end
                end
            end
            t = t:get_parent_type()
        end
    end)
    return out
end

-- The field next to the current health that holds the maximum ("MaxHealth", "_MaxHp"). The enemies'
-- "defaultMaxHealth" is not taken: it is a starting value, not the current maximum.
function H.find_max_field(obj, inside_health)
    local best, best_rank
    for _, f in ipairs(H.numeric_fields(obj)) do
        local n = field_label(f[1]):lower()
        if n:find("max", 1, true) and not n:find("default", 1, true) and not n:find("rate", 1, true) then
            local healthy = n:find("health", 1, true) or n:find("hp", 1, true) or n:find("life", 1, true)
            local rank = healthy and 1 or (inside_health and 2 or nil)
            if rank and (not best_rank or rank < best_rank) and H.read_num(obj, f[1]) then best, best_rank = f[1], rank end
        end
    end
    return best
end

-- Looks through the player object's components for the health number. Returns true if found.
function H.scan()
    pstat.scanned_at = os.clock()
    local go = player_object()
    if not go then return false end
    pstat.go_addr = H.address_of(go)
    local best
    pcall(function()
        for _, c in ipairs(go:call("get_Components"):get_elements()) do
            local full = c:get_type_definition():get_full_name()
            local bonus = full:find("DamageController$") and 0 or (full:find("Status$") and 5 or 10)
            for _, hv in ipairs(fields_of_type(c, "app.HealthInfo")) do
                local fname, sc = enemy.best_health_field(hv[2], true)
                if fname and (not best or sc + bonus < best.rank) then
                    best = { rank = sc + bonus, obj = hv[2], field = fname, inside = true, where = full .. "." .. hv[1] }
                end
            end
            local fname, sc = enemy.best_health_field(c, false)
            if fname and (not best or sc + bonus + 20 < best.rank) then
                best = { rank = sc + bonus + 20, obj = c, field = fname, inside = false, where = full }
            end
        end
    end)
    if not best then
        if not pstat.logged_fail then
            pstat.logged_fail = true
            say("health: no health found on the player object (button 8 in the debug section lists what it has)")
        end
        return false
    end
    pstat.logged_fail = nil
    if pstat.downed then H.reset_down("the player object was replaced (a reload?)") end
    pstat.alive_seen = false
    pstat.hi, pstat.field, pstat.where = best.obj, best.field, best.where
    pstat.hi_addr = H.address_of(best.obj)
    pstat.max_field = H.find_max_field(best.obj, best.inside)
    pstat.int_field = false
    for _, f in ipairs(H.numeric_fields(best.obj)) do
        if f[1] == best.field and f[2] == "System.Int32" then pstat.int_field = true end
    end
    pstat.read_fail = 0
    pstat.hp, pstat.max = nil, nil -- so the first reading is not mistaken for a heal
    pstat.mute_until = os.clock() + 1
    if pstat.logged_where ~= pstat.where then
        pstat.logged_where = pstat.where
        say(string.format("health: your health is read from %s.%s (maximum from %s)%s", pstat.where, pstat.field,
            pstat.max_field or "nothing: the highest value seen is used",
            pstat.hi_addr and "" or " (object address unreadable: the hold-at-1 hook cannot recognise it, only the per-frame check works)"))
    end
    return true
end

function H.read_health()
    local hp = H.read_num(pstat.hi, pstat.field)
    if hp == nil then return nil end
    local mx = pstat.max_field and H.read_num(pstat.hi, pstat.max_field) or nil
    if hp > pstat.seen_max then pstat.seen_max = hp end
    if mx and mx > pstat.seen_max then pstat.seen_max = mx end
    return hp, (mx and mx > 0) and mx or pstat.seen_max
end

function H.write_health(v)
    if not pstat.hi then return false end
    if pstat.int_field then v = math.floor(v + 0.5) else v = v + 0.0 end
    pstat.writing = true
    local ok = pcall(function() pstat.hi:set_field(pstat.field, v) end)
    pstat.writing = false
    if not ok then return false end
    pstat.hp = v
    return true
end

function H.send_state(now)
    if not peer_present(now) or pstat.hp == nil then return end
    pstat.sent_at, pstat.sent_hp = now, pstat.hp
    net_send(H.PH_MSG, string.format("h|%.0f|%.0f|%d", pstat.hp, pstat.max or 0, pstat.downed and 1 or 0))
    pstat.sent = pstat.sent + 1
end

function H.send_event(kind, arg)
    local lp = state.local_pos
    if not lp or not peer_present() then return end
    net_send(H.PH_MSG, string.format("e|%s|%s|%.2f|%.2f|%.2f", kind, arg or "", lp.x, lp.y, lp.z))
    pstat.sent = pstat.sent + 1
end

function H.is_heal_item(name)
    local low = name:lower()
    for _, w in ipairs(pstat.heal_words) do
        if low:find(w, 1, true) then return true end
    end
    return false
end

-- How far the other player is from you in metres (nil if unknown).
function H.remote_distance()
    local lp, r = state.local_pos, state.remote
    if not (lp and r and r.pos) then return nil end
    local p = r.pos
    return math.sqrt((p.x - lp.x) ^ 2 + (p.y - lp.y) ^ 2 + (p.z - lp.z) ^ 2)
end

-- Is holding your health at 1 allowed right now? Only in mode 4, only with the other player there, and not when they
-- are down already (then it is a wipe and the game ends as it normally would).
function H.clamp_active(now)
    now = now or os.clock()
    if death.mode ~= 4 or not peer_present(now) then return false end
    if now < (pstat.no_hold_until or 0) then return false end -- we are killing the player on purpose (team wipe): don't undo it
    local r = pstat.remote
    if r and r.downed and now - r.at < 10 then return false end
    return true
end

-- The game reloaded or ended without our help: forget that we were down (nothing to write, the new player is whole).
function H.reset_down(why, silent)
    if not pstat.downed then return end
    pstat.downed, pstat.pending_down = false, false
    H.note("down state cleared: " .. why)
    if not silent then H.send_event("up", "") end
end
pstat.reset_down = H.reset_down

function H.go_down(why)
    if pstat.downed then return end
    local now = os.clock()
    pstat.downed, pstat.pending_down = true, false
    pstat.down_at = now
    local who = H.who_is_there()
    H.note(string.format("you are DOWN (%s): %s has to use a Herb or Chem Fluid next to you", why, who))
    chat_add("Health", "You are down! " .. who .. " has to use a Herb or Chem Fluid next to you.")
    H.send_event("down", "")
    H.send_state(now)
end

function H.get_up(why)
    if not pstat.downed then return end
    local now = os.clock()
    pstat.downed, pstat.pending_down = false, false
    pstat.revives = pstat.revives + 1
    local target = math.max(2, (pstat.max or pstat.seen_max or 0) * pstat.revive_pct / 100)
    pstat.grace_until = now + 1.5
    H.write_health(target)
    H.note(string.format("you are back up (%s), health %.0f, right where you were", why, target))
    chat_add("Health", "You are back up.")
    H.send_event("up", "")
    H.send_state(now)
end

function H.on_heal(amount, now)
    pstat.heals = pstat.heals + 1
    local u = pstat.last_use
    if u and now - u.at < 4 then
        pstat.last_use = nil
        H.note(string.format("you healed +%.0f (%s)", amount, u.name))
        H.send_event("heal", u.name)
    else
        H.note(string.format("your health rose by %.0f (no healing item was used)", amount))
    end
end

-- The game consumed an item. A healing item is remembered; if the health then rises it is a heal. If your
-- health can't be read at all the use itself is reported.
function H.on_item_used(name)
    if not name or give.giving or not plausible_id(name) or not H.is_heal_item(name) then return end
    pstat.last_use = { name = name, at = os.clock() }
    local rec = H.rec
    if rec and rec.on and rec.ph and rec.ph.heal then -- the recorder's report must not depend on the heal code that consumes last_use
        rec.ph.item_name, rec.ph.item_at = name, pstat.last_use.at
    end
    if not pstat.hi then H.send_event("use", name) end
end

-- Is a revive possible right now? Returns the healing item entry plus the inventory, or nil plus the reason.
-- skip_items: only the cheap checks (somebody is down, close enough), for the every-frame check while counting down.
function pstat.revive_ready(now)
    local r = pstat.remote
    local who = H.who_is_there()
    if not (peer_present(now) and r and r.downed and now - r.at < 10) then return nil, "nobody is down right now" end
    local d = H.remote_distance()
    if d == nil or d > pstat.revive_radius then
        return nil, string.format("%s is down but %s: get within %.0f m", who, d and string.format("%.1f m away", d) or "I can't tell where they are",
            pstat.revive_radius)
    end
    return true
end

-- F8 / the panel button: start reviving the downed player next to you. (9.15) It uses NO item: the time is the price. You have to stay
-- within the revive distance for revive_hold seconds; walking off, going down yourself, them getting up or Cancel stops it. (9.14 took a
-- Herb / Chem Fluid / Remedy out of the inventory at the end and the game crashed right there, so the inventory is not touched at all
-- now.) Using a Herb from the inventory menu yourself (the other way to revive) is still immediate, and costs the Herb.
function pstat.revive_other()
    local now = os.clock()
    local who = H.who_is_there()
    if pstat.reviving then
        H.note(string.format("already reviving %s: %.1f of %.0f s", who, now - pstat.reviving.since, pstat.revive_hold))
        return false
    end
    local ok, why = pstat.revive_ready(now)
    if not ok then
        H.note(why)
        return false
    end
    pstat.reviving = { since = now }
    pstat.revive_stats.started = pstat.revive_stats.started + 1
    H.note(string.format("reviving %s: stay within %.0f m for %.0f s (no item is used, the wait is the cost)", who, pstat.revive_radius,
        pstat.revive_hold))
    return true
end

function pstat.revive_cancel(why)
    if not pstat.reviving then return end
    pstat.reviving = nil
    pstat.revive_stats.cancelled = pstat.revive_stats.cancelled + 1
    H.note("revive stopped: " .. tostring(why))
end

-- The end of the countdown: tell the other player (nothing is taken from the inventory). A crumb names this step if the game dies here.
function pstat.revive_finish()
    local who = H.who_is_there()
    pcall(tracer.crumb, "revive", "finishing the F8 revive of " .. tostring(who))
    H.send_event("revive", "")
    pstat.revive_stats.done = pstat.revive_stats.done + 1
    H.note(string.format("you helped %s up (%.0f s, no item used)", who, pstat.revive_hold))
    chat_add("Health", string.format("You helped %s up.", who))
    pcall(tracer.crumb, "clean", "F8 revive finished")
    return true
end

-- Every frame while an F8 revive is counting down: stops if they got up or you walked out of range or went down yourself; finishes when
-- the time is up. (Only your position and theirs are looked at: no game object is touched.)
function pstat.revive_tick(now)
    local rv = pstat.reviving
    if not rv then return end
    if pstat.downed then return pstat.revive_cancel("you are down yourself") end
    local ok, why = pstat.revive_ready(now)
    if not ok then return pstat.revive_cancel(why) end
    if now - rv.since >= pstat.revive_hold then
        pstat.reviving = nil
        pstat.revive_finish()
    end
end

net_on(H.PH_MSG, function(payload)
    local now = os.clock()
    local hp, mx, dn = payload:match("^h|(-?[%d%.]+)|(-?[%d%.]+)|([01])$")
    if hp then
        local r = pstat.remote or {}
        pstat.remote = r
        r.hp, r.max, r.at, r.downed = tonumber(hp), tonumber(mx), now, dn == "1"
        pstat.received = pstat.received + 1
        return
    end
    local kind, arg, x, y, z = payload:match("^e|(%a+)|([%w_%.%-]*)|(-?[%d%.]+)|(-?[%d%.]+)|(-?[%d%.]+)$")
    if not kind then return end
    pstat.received = pstat.received + 1
    local r = pstat.remote or {}
    pstat.remote = r
    r.at = now
    local who = H.who_is_there()
    if kind == "heal" or kind == "use" then state.remote_heal_until = now + 2.4 end
    if kind == "down" then
        r.downed = true
        chat_add("Health", string.format("%s is down! Get within %.0f m and use a Herb or Chem Fluid on them, or hold F8 next to them for %.0f s (no item needed).",
            who, pstat.revive_radius, pstat.revive_hold))
        H.note(who .. " is down")
    elseif kind == "up" then
        r.downed = false
        chat_add("Health", who .. " is back up.")
        H.note(who .. " is back up")
    elseif kind == "heal" or kind == "use" or kind == "revive" then
        local lp = state.local_pos
        local dist = lp and math.sqrt((tonumber(x) - lp.x) ^ 2 + (tonumber(y) - lp.y) ^ 2 + (tonumber(z) - lp.z) ^ 2) or nil
        local helped = (kind == "revive" and arg == "") -- (9.15) F8: they stayed next to you, no item
        local what = helped and "helped you up" or string.format("used a %s", arg ~= "" and arg or "healing item")
        if not pstat.downed then
            if not helped then chat_add("Health", string.format("%s used a %s.", who, arg ~= "" and arg or "healing item")) end
        elseif dist and dist <= pstat.revive_radius * 1.25 then -- a little slack for lag
            H.get_up(string.format("%s %s %.1f m away", who, what, dist))
        else
            H.note(string.format("%s %s but %s: they must be within %.0f m of you", who, what,
                dist and string.format("they were %.1f m away", dist) or "I can't tell how far", pstat.revive_radius))
        end
    end
end)

-- Called every frame.
function pstat.update(now)
    local present = peer_present(now)
    if present and not pstat.peer_was then pstat.sent_at = -10 end -- just connected: tell them at once
    pstat.peer_was = present

    local okk, down = pcall(function() return reframework:is_key_down(pstat.hotkey) end)
    down = okk and down == true
    if down and not pstat.key_was_down then pstat.revive_other() end
    pstat.key_was_down = down
    pstat.revive_tick(now)

    if now - pstat.read_at < 0.1 then return end
    pstat.read_at = now
    local go = player_object()
    if not go then return end
    if pstat.hi == nil or (pstat.go_addr and H.address_of(go) ~= pstat.go_addr) then
        if now - pstat.scanned_at < 3 or not H.scan() then return end
    end
    local hp, mx = H.read_health()
    if hp == nil then
        pstat.read_fail = pstat.read_fail + 1
        if pstat.read_fail >= 5 then pstat.hi = nil end -- the object went away (new game, load): look again
        return
    end
    pstat.read_fail = 0
    local prev = pstat.hp
    pstat.hp, pstat.max = hp, mx
    if hp > 1.5 then pstat.alive_seen = true end
    if prev and now > pstat.mute_until then
        local d = hp - prev
        if d > 1.5 then -- (a rise of 1 is the hold fighting the game, not a heal)
            H.on_heal(d, now)
        elseif d < -0.5 then
            pstat.hurts = pstat.hurts + 1
        end
    end

    if H.clamp_active(now) and now > pstat.mute_until and (pstat.pending_down or (hp <= 0.5 and pstat.alive_seen)) then
        if hp <= 0.5 and not pstat.downed then
            H.write_health(1)
            pstat.clamped = pstat.clamped + 1
        end
        H.go_down(pstat.pending_down and "a hit that would have killed you" or "your health reached 0")
    end

    if pstat.downed then
        if hp > 1.5 and now > pstat.grace_until and now >= (pstat.no_hold_until or 0) then -- no healing yourself while down
            H.write_health(1)
            if now - (pstat.block_note_at or 0) > 3 then
                pstat.block_note_at = now
                H.note("you can't heal yourself while down: only the other player can get you up")
            end
        end
        if present then
            pstat.alone_since = nil
        else
            pstat.alone_since = pstat.alone_since or now
            if now - pstat.alone_since > 10 then H.get_up("the other player is gone") end
        end
    end

    if present then
        local changed = pstat.sent_hp == nil or math.abs(hp - pstat.sent_hp) >= 1
        if (changed and now - pstat.sent_at >= 0.5) or now - pstat.sent_at >= 3 then H.send_state(now) end
    end
end

-- On screen: the red tint and text when you are down, and what the helper can do.
function pstat.draw(now)
    local who = H.who_is_there()
    if pstat.downed then
        pcall(function()
            local sz = imgui.get_display_size()
            draw.filled_rect(0, 0, sz.x, sz.y, 0x300000FF)
        end)
        pcall(draw.text, "YOU ARE DOWN: " .. who .. " has to use a Herb or Chem Fluid next to you", 24, 200, 0xFF3030FF)
    end
    local r = pstat.remote
    if r and r.downed and peer_present(now) and now - r.at < 10 then
        local d = H.remote_distance()
        if pstat.reviving then
            pcall(draw.text, string.format("Reviving %s... %.1f / %.0f s  (stay within %.0f m)", who,
                math.min(now - pstat.reviving.since, pstat.revive_hold), pstat.revive_hold, pstat.revive_radius), 24, 220, 0xFF00D7FF)
        elseif d and d <= pstat.revive_radius then
            pcall(draw.text, string.format("[F8] revive %s (stay put %.0f s, no item needed)", who, pstat.revive_hold), 24, 220, 0xFF00D7FF)
        else
            pcall(draw.text, string.format("%s is down%s: get within %.0f m", who, d and string.format(" (%.0f m away)", d) or "",
                pstat.revive_radius), 24, 220, 0xFF3030FF)
        end
    end
end

state.tag_extra = function()
    local r = pstat.remote
    if not r or os.clock() - r.at > 10 then return nil end
    if r.downed then return " [downed]", 0xFF3030FF, true end -- (9.13: in the same style as [healing] / [crouching])
    if r.hp and r.hp >= 0 and r.max and r.max > 0 then return string.format("  HP %d%%", math.floor(r.hp / r.max * 100 + 0.5)) end
    return nil
end

-- A summary of the health state goes into every debug file.
dbg.extra = function()
    return {
        read_from = pstat.hi and (pstat.where .. "." .. pstat.field) or "not found",
        max_from = pstat.max_field or "none",
        health = pstat.hp, max = pstat.max, downed = pstat.downed,
        death_mode = death.mode, held_at_1 = pstat.clamped, heals_seen = pstat.heals, hits_seen = pstat.hurts, revives = pstat.revives,
        revive = { radius = pstat.revive_radius, hold = pstat.revive_hold, started = pstat.revive_stats.started, done = pstat.revive_stats.done,
            cancelled = pstat.revive_stats.cancelled },
        hold_hook = pstat.hooked, use_hook = pstat.use_hooked, address_readable = pstat.hi_addr ~= nil,
        coop_saves = (function()
            local sv = CFG.saves -- (the co-op saves table is a local further down; this is the same table)
            if not sv then return nil end
            local out = { enabled = sv.enabled, last = sv.last, folder = sv.dir, occupied = sv.occupied, entries = {} }
            for _, e in ipairs(sv.entries) do
                if type(e) == "table" then
                    out.entries[#out.entries + 1] = { slot = e.slot, role = e.role, from = e.from, partner = e.partner, from_slot = e.from_slot,
                        why = e.why, size = e.size, crc = e.crc, tag = e.tag, game_lists_the_slot = sv.game_sees(tonumber(e.slot) or -1, os.clock()) }
                end
            end
            local okg, gset, glist = pcall(function() return CFG.lm.game_slots() end)
            out.game_says_slots_exist = okg and glist or nil
            out.label_status = CFG.lm.status
            out.labels_written = CFG.lm.written
            return out
        end)(),
        items = { create_worked_with = give.create_how, bumped_stacks = give.bumped or 0, failed_creations = give.create_log,
            sent_ok = give.sent, received = give.received, dropped = give.dropped, failed = give.failed,
            item_manager = { in_use = mgr.item_manager_how, knows_items = mgr.item_manager_ok, copies = mgr.item_manager_list },
            -- (9.14) what the game answered to the last addItem tries, and what the last dropped object looked like
            last_add = give.add_last, add_worked_with = give.add_how, last_drop = give.last_drop,
            add_item_result_names = (function() local o = {} for v, nm in pairs(give.enum_names("app.Inventory.AddItemResult")) do o[tostring(v)] = nm end return o end)(),
            discard = { menu_discard_hooked = give.discard_hooked, menu_discard_calls = give.discard_calls or 0,
                reduceNum_calls = give.reduce_seen or 0, focus_hook_calls = give.hover_seen or 0, switched_on = give.drop_on_discard } },
        weapon_lock = { on = H.LOCK.on, status = H.LOCK.status, writes = H.LOCK.writes, rewritten_by_game = H.LOCK.rewritten,
            failed = H.LOCK.fails, restored = H.LOCK.restored,
            -- 9.9: per place in the frame: how often the lock ran there, and how often it found the gate open again
            places = H.LOCK.phase, places_registered = H.LOCK.registered, hook_on = H.LOCK.hooks.on,
            hooked_after = H.LOCK.hooks.installed, hook_error = H.LOCK.hooks.error,
            sequence_manager_methods = H.LOCK.hooks.methods, other_methods = H.LOCK.hooks.dump,
            -- 9.12: what each part did while you were down (hooks: how often each fired; gun: calls refused; move: gate / put back)
            hooks = { installed = H.LOCK.hooks.installed, not_found = H.LOCK.hooks.missing, fired_while_down = H.LOCK.hooks.calls, muted = H.LOCK.hooks.muted },
            gun = { on = H.LOCK.guns.on, installed = H.LOCK.guns.installed, not_found = H.LOCK.guns.missing, refused = H.LOCK.guns.skipped, error = H.LOCK.guns.error },
            move = { on = H.LOCK.move.on, installed = H.LOCK.move.installed, not_found = H.LOCK.move.missing, error = H.LOCK.move.error,
                gate_asked_while_down = H.LOCK.move.getter_calls, gate_said_no = H.LOCK.move.blocked, put_back = H.LOCK.move.pinned,
                put_back_failed = H.LOCK.move.pin_fails, put_back_where = H.LOCK.move.pin_places, new_place_taken = H.LOCK.move.reanchored } },
        poses = { guard = H.POSE.guard, guard_from = H.POSE.guard_src, heal = H.POSE.heal, hands_action = H.POSE.hands_id,
            gun_action = H.POSE.gun_id, guard_cancel_flag = H.POSE.cancel, reads = H.POSE.reads, unreadable = H.POSE.fails,
            guard_readings = H.POSE.guard_reads, heal_readings = H.POSE.heal_reads,
            -- 9.9: how many position packets carried each bit, and what the action ids were (id -> readings)
            heal_ignored_because_a_menu_was_open = H.POSE.heal_blocked or 0, packets = H.POSE.sent.packets, packets_with_guard = H.POSE.sent.guard, packets_with_heal = H.POSE.sent.heal,
            packets_with_crouch = H.POSE.sent.crouch, hands_ids_seen = H.strkeys(H.POSE.hist_hands), gun_ids_seen = H.strkeys(H.POSE.hist_gun) },
        crouch = { now = H.POSE.crouch, from = H.POSE.crouch_src, eye_above_feet = H.POSE.eye, standing_eye = H.POSE.stand_eye,
            drop = H.POSE.eye_drop, readings_crouched = H.POSE.crouch_reads, game_fields = H.crouch_report() },
        occlusion = state.occ and state.occ.report and state.occ.report() or nil,
        enemy_hits = enemy.hit and enemy.hit.report and enemy.hit.report() or nil,
        menus = CFG.menu and CFG.menu.report and CFG.menu.report() or nil,
        other_player = pstat.remote and { hp = pstat.remote.hp, max = pstat.remote.max, downed = pstat.remote.downed } or nil,
        last = pstat.last,
    }
end

-- Marks calls on the player's own HealthInfo in the tracer's output.
tracer.owner_hint = function(args)
    if not pstat.hi_addr then return nil end
    local a = sdk.to_int64(args[2])
    if a == pstat.hi_addr then return "  [on the PLAYER's HealthInfo]" end
    return nil
end

----------------------------------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------------------------------
function pstat.install()
    pcall(function()
        local td = sdk.find_type_definition("app.HealthInfo")
        local m = td and td:get_method("set_health")
        if not m then
            say("health: app.HealthInfo.set_health not found (the check ten times a second still works)")
            return
        end
        sdk.hook(m, function(args)
            pstat.this = nil
            if pstat.hi_addr then
                local ok, a = pcall(sdk.to_int64, args[2])
                if ok then pstat.this = a end
            end
            return H.CALL_ORIGINAL
        end, function(retval)
            local a = pstat.this
            pstat.this = nil
            -- the hit has just lowered the health: if it would be lethal, put it back to 1 before the game looks
            if a ~= nil and a == pstat.hi_addr and pstat.hi and not pstat.writing and H.clamp_active() then
                local hp = H.read_num(pstat.hi, pstat.field)
                if hp and hp <= 0 then
                    H.write_health(1)
                    pstat.clamped = pstat.clamped + 1
                    if not pstat.downed then pstat.pending_down = true end -- (already down: just held at 1 again)
                end
            end
            return retval
        end)
        pstat.hooked = true
    end)
    pstat.use_hooked = hook_method("app.Inventory", "reduceItem", function(args)
        local name
        pcall(function() name = as_text(sdk.to_managed_object(args[3])) end)
        H.on_item_used(name)
    end)
end

----------------------------------------------------------------------------------------------
-- Debug collectors (buttons 8 and 9)
----------------------------------------------------------------------------------------------
function H.player_components()
    local out = {}
    local go = player_object()
    if not go then return out, nil end
    pcall(function()
        for _, c in ipairs(go:call("get_Components"):get_elements()) do
            out[#out + 1] = { full = c:get_type_definition():get_full_name(), obj = c }
        end
    end)
    return out, go
end

-- Button 8: what the player object has, where health was found, and a trace of the damage / guard / heal / death calls.
function pstat.details()
    pinned(function()
        say("=== player details ===")
        local comps, go = H.player_components()
        if not go then
            say("player object (Pl0000) NOT found: load into the game first")
            return
        end
        local names = {}
        for _, c in ipairs(comps) do names[#names + 1] = c.full end
        say("components on Pl0000: " .. table.concat(names, ", "))
        H.scan()
        if pstat.hi then
            say(string.format("health: %s.%s = %s, maximum %s (field %s)", pstat.where, pstat.field, tostring(H.read_num(pstat.hi, pstat.field)),
                tostring(pstat.max), tostring(pstat.max_field)))
            say("the object that holds it:")
            dump_fields(pstat.hi, "   ", 30)
        else
            say("NO health field found on Pl0000 (looked for an app.HealthInfo field and for health/hp/life numbers)")
        end
        say(string.format("hold-at-1 hook %s, item-use hook %s, object address %s", pstat.hooked and "installed" or "NOT installed",
            pstat.use_hooked and "installed" or "NOT installed", pstat.hi_addr and "readable" or "NOT readable"))
        for _, c in ipairs(comps) do
            if H.PLAYER_DUMP[c.full] then
                say("component " .. c.full .. ":")
                dump_fields(c.obj, "      ", 40)
            end
        end
        for _, c in ipairs(comps) do
            if H.PLAYER_DUMP[c.full] then probe_type(c.full, false, H.PLAYER_WORDS, 70) end
        end
        say("=== player details done ===")
    end)
    -- then trace the calls while you get hit, block, heal and (with a partner) go down
    local comps = H.player_components()
    local present, order = {}, {}
    for _, c in ipairs(comps) do present[c.full] = true end
    for _, n in ipairs(H.PLAYER_FIRST) do
        if present[n] then order[#order + 1] = n end
    end
    for _, c in ipairs(comps) do
        if c.full:find("^app%.Player") then
            local listed = false
            for _, n in ipairs(order) do if n == c.full then listed = true end end
            if not listed then order[#order + 1] = c.full end
        end
    end
    order[#order + 1] = "app.HealthInfo"
    for _, n in ipairs(order) do trace_type(n, H.PLAYER_WORDS, false) end
    trace_type("app.GameManager", { "gameover", "dead", "die", "death", "continue", "retry", "restart", "load", "chapter" }, false)
    tracer_add("player trace: " .. #order .. " types. Now get hit once, hold the block button, use a Herb, then send the debug file")
end

-- A few live instances of the event classes, with their fields, so the ids that identify an event are visible.
H.EVENT_DUMP = { "app.GameEventSetting", "app.GameEventAction", "app.GameEventActionController", "app.TimeLineKicker",
    "app.TimeLineContainer", "app.TriggerInAction", "app.InteractEventAction", "app.DoorEventAction", "app.ChapterJumpData",
    "app.SequenceController" }
H.EVENT_SINGLETONS = { "app.GameEventManager", "app.GameFlowFsmManager", "app.TimeLinePlayStateControlManager",
    "app.ChapterLoadTempManager", "app.SaveDataManager" }
function H.events_dump()
    pinned(function()
        say("=== event objects ===")
        local wanted, count, shown = {}, {}, {}
        for _, n in ipairs(H.EVENT_DUMP) do wanted[n] = true end
        local okw, errw = pcall(each_gameobject, function(go, path)
            local okc, comps = pcall(function() return go:call("get_Components"):get_elements() end)
            if not okc then return end
            for _, c in ipairs(comps) do
                local okt, full = pcall(function() return c:get_type_definition():get_full_name() end)
                if okt and wanted[full] then
                    count[full] = (count[full] or 0) + 1
                    if (shown[full] or 0) < 2 then
                        shown[full] = (shown[full] or 0) + 1
                        say(string.format("%s on %s", full, path))
                        dump_fields(c, "      ", 25)
                    end
                end
            end
        end, 20000)
        if not okw then say("event dump scan error: " .. tostring(errw)) end
        for _, n in ipairs(H.EVENT_DUMP) do say(string.format("%s: %d in the scene", n, count[n] or 0)) end
        for _, n in ipairs(H.EVENT_SINGLETONS) do
            local ok, obj = pcall(sdk.get_managed_singleton, n)
            if ok and obj then
                say(n .. " (singleton):")
                dump_fields(obj, "      ", 40)
            else
                say(n .. ": no singleton")
            end
        end
        say("=== event objects done ===")
    end)
end

-- Button 9: watch cutscene / event / flow classes while you play through one.
function pstat.events_trace()
    H.events_dump()
    for _, n in ipairs(H.EVENT_TYPES) do trace_type(n, H.EVENT_WORDS, false) end
    local extra = {}
    for _, k in ipairs(H.EXTRA_ORDER) do
        if H.extra_on[k] then
            extra[#extra + 1] = k
            for _, t in ipairs(H.EVENT_EXTRAS[k].types) do trace_type(t[1], t[2], false) end
        end
    end
    tracer_add("event trace: " .. #H.EVENT_TYPES .. " types" .. (#extra > 0 and (" + " .. table.concat(extra, ", ")) or "")
        .. ". Now walk into a cutscene, open a door, pick up a key item or load a chapter, then send the debug file")
end

-- The options under button 9 and what the breadcrumb said about the last session.
function pstat.extras_panel()
    for _, k in ipairs(H.EXTRA_ORDER) do
        local c, v = imgui.checkbox("    9+ also trace " .. H.EVENT_EXTRAS[k].label .. "##x" .. k, H.extra_on[k])
        if c then H.extra_on[k] = v end
    end
    imgui.text("    The 9+ options hook more of the game and may crash it: tick ONE, press 9, and tell me what happened.")
    if tracer.previous then imgui.text("    " .. tracer.previous) end
end

----------------------------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------------------------
function pstat.panel()
    local now = os.clock()
    local who = H.who_is_there()
    if pstat.hi then
        imgui.text(string.format("Your health: %.0f / %.0f   (read from %s.%s)", pstat.hp or 0, pstat.max or 0, pstat.where, pstat.field))
    else
        imgui.text("Your health: not found yet (load into the game; button 8 in the debug section lists what the player has)")
    end
    local r = pstat.remote
    if r and now - r.at < 10 and r.hp then
        imgui.text(string.format("%s: %.0f / %.0f%s", who, r.hp, r.max or 0, r.downed and "   DOWN" or ""))
    else
        imgui.text(who .. ": no health received yet")
    end
    if state.remote_name == "Loopback Bot" then -- (9.13) the pretend player can be told to go down, so a revive can be tried alone
        imgui.text(string.format("The loopback bot can go down: walk within %.0f m of it and press F8, then stay put for %.0f s (no item needed), or use a heal from the inventory next to it.",
            pstat.revive_radius, pstat.revive_hold))
        if imgui.button("Loopback bot: make it go down") then
            net_send(H.BOT_MSG, "down")
            H.note("told the loopback bot to go down")
        end
        if imgui.button("Loopback bot: make it get up") then
            net_send(H.BOT_MSG, "up")
            H.note("told the loopback bot to get up")
        end
    end
    imgui.text(pstat.last)
    imgui.text(string.format("Heals seen %d   hits taken %d   times held at 1: %d   revived %d   sent %d   received %d",
        pstat.heals, pstat.hurts, pstat.clamped, pstat.revives, pstat.sent, pstat.received))
    imgui.text(string.format("Hooks: hold-at-1 %s   item use %s", pstat.hooked and "on" or "off", pstat.use_hooked and "on" or "off"))
    if death.mode == 4 then
        imgui.text(H.clamp_active(now) and "Downed mode is ACTIVE: a lethal hit leaves you at 1 health and down."
            or "Downed mode is on but not active (needs the other player connected and not down).")
    else
        imgui.text("Downed mode is off. Choose \"Downed and revive\" under When a player dies (Death section).")
    end
    if pstat.downed then
        imgui.text("YOU ARE DOWN: waiting for " .. who .. " to use a Herb or Chem Fluid next to you.")
        if imgui.button("Test: get up now") then H.get_up("test button") end
    elseif imgui.button("Test: go down now (sets your health to 1)") then
        if death.mode ~= 4 then
            H.note("switch on \"Downed and revive\" in the Death section first")
        elseif not peer_present(now) then
            H.note("the other player has to be connected to go down")
        elseif not pstat.hi then
            H.note("your health can't be found, so I can't set it")
        else
            H.write_health(1)
            H.go_down("test button")
        end
    end
    if r and r.downed and imgui.button("Revive " .. who .. " (stay put until the countdown ends; no item needed)  [F8]") then pstat.revive_other() end
    if pstat.reviving then
        imgui.text(string.format("Reviving %s: %.1f / %.0f s", who, math.min(os.clock() - pstat.reviving.since, pstat.revive_hold), pstat.revive_hold))
        if imgui.button("Cancel the revive") then pstat.revive_cancel("you cancelled it") end
    end
    if imgui.button("Test: pretend " .. who .. " used a Herb right next to me") then
        local lp = state.local_pos or { x = 0, y = 0, z = 0 }
        netmsg.handlers[H.PH_MSG](string.format("e|heal|Herb|%.2f|%.2f|%.2f", lp.x, lp.y, lp.z))
    end
    local ok2, ch2, val2 = pcall(imgui.slider_float, "Revive distance (m)", pstat.revive_radius, 1, 10)
    if ok2 and ch2 and type(val2) == "number" then pstat.revive_radius = math.max(1, math.min(10, val2)) end
    local okh, chh, valh = pcall(imgui.slider_float, "F8 revive: seconds to stay within that distance", pstat.revive_hold, 1, 10)
    if okh and chh and type(valh) == "number" then pstat.revive_hold = math.max(1, math.min(10, math.floor(valh * 2 + 0.5) / 2)) end
    local ok3, ch3, val3 = pcall(imgui.slider_float, "Health after being revived (% of maximum)", pstat.revive_pct, 5, 100)
    if ok3 and ch3 and type(val3) == "number" then pstat.revive_pct = math.max(5, math.min(100, math.floor(val3 + 0.5))) end
    do
        local okc, cc, vc = pcall(imgui.checkbox, "A downed player can't aim or shoot until revived (EXPERIMENTAL)", H.LOCK.on)
        if okc and cc and type(vc) == "boolean" then H.LOCK.on = vc end
        imgui.text("    weapon lock: " .. H.LOCK.status)
        local okk, ck, vk = pcall(imgui.checkbox, "    also close it right after the sequence manager's own update (hooks it the first time you go down)", H.LOCK.hooks.on)
        if okk and ck and type(vk) == "boolean" then H.LOCK.hooks.on = vk end
        if H.LOCK.hooks.error then imgui.text("    hook: " .. H.LOCK.hooks.error) end
        local okg, cg, vg = pcall(imgui.checkbox, "    also refuse the gun's own attack and aim calls while down (hooks app.PlayerGun.tryAttack ...)", H.LOCK.guns.on)
        if okg and cg and type(vg) == "boolean" then H.LOCK.guns.on = vg end
        if H.LOCK.guns.error then imgui.text("    gun hook: " .. H.LOCK.guns.error) end
        local okv, cv, vv = pcall(imgui.checkbox, "    also stop a downed player moving (the move gate says no; if the game moves you anyway you are put back where you fell)", H.LOCK.move.on)
        if okv and cv and type(vv) == "boolean" then H.LOCK.move.on = vv end
        if H.LOCK.move.error then imgui.text("    move gate: " .. H.LOCK.move.error) end
    end
    imgui.text("Revive: the other player uses a Herb / Chem Fluid / Remedy within that distance (at once, costs the item), or stays next to you with F8 (takes the time below, costs nothing).")
    imgui.text("You stay where you fell: the game never sees you die, so it does not reload a checkpoint.")
    imgui.text("EXPERIMENTAL: if the game still ends when you are hit to 0, send me the debug file (button 8).")
end

----------------------------------------------------------------------------------------------
-- Poses from MY body. local_flags() asks this what to send. 9.8: the signals are the REAL ones, taken from two guided
-- recordings (button 11) done with and without a gun:
--   block: app.PlayerSequenceManager.IsGuardCancelAccepted is false at rest and true from the moment the raise starts until
--          the lowering starts (4 of 4 blocks, with and without a gun, and it does not move while healing).
--          Fallbacks if that field can't be read: PlayerHands.actionID 35 (raise) / 36 (hold), PlayerGun.actionID 107 / 108.
--   heal:  app.PlayerHands.<actionID>k__BackingField is 16 then 17 for the whole heal animation (about 3.6 s), with and
--          without a gun. (The game takes the item out of the inventory at the END of the animation, so reduceItem is no
--          trigger for the pose; it is still the trigger for the heal event.)
-- Only plain field reads (twenty a second at most): no hooks, nothing written.
----------------------------------------------------------------------------------------------
H.POSE = {
    HEAL_HANDS = { [16] = true, [17] = true },
    GUARD_HANDS = { [35] = true, [36] = true },
    GUARD_GUN = { [107] = true, [108] = true },
    next_at = -1, comps_at = -10, go_addr = nil, seq = nil, hands = nil, gun = nil,
    guard = false, heal = false, heal_raw = false, guard_src = "-", heal_until = 0,
    hands_id = nil, gun_id = nil, cancel = nil,
    reads = 0, fails = 0, fail_run = 0, guard_reads = 0, heal_reads = 0,
    -- 9.9: crouch. The signal is how far the camera sits above the player object (the feet): it drops about half a metre
    -- when you crouch. "Standing" is the highest value seen in the last two minutes, so nothing has to be calibrated.
    crouch = false, crouch_h = false, crouch_src = "-", eye = nil, stand_eye = nil, eye_drop = 0, crouch_reads = 0,
    eye_buckets = {}, comp_by_name = {}, cands = {}, cands_addr = nil,
    -- 9.9: what the hands / gun action ids do (id -> readings), so a heal that does not look like 16/17 shows up in the file
    hist_hands = {}, hist_gun = {}, hist_keys = 0,
    sent = { guard = 0, heal = 0, crouch = 0, packets = 0 }, -- position packets that carried each pose bit
}
pstat.pose = H.POSE -- (the panel, outside this block, reads it from here)

function H.pose_field(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj:get_field(name) end)
    if ok then return v end
    return nil
end

function H.pose_hist(tbl, id)
    if id == nil then return end
    local P = H.POSE
    if tbl[id] == nil then
        if P.hist_keys >= 80 then return end
        P.hist_keys = P.hist_keys + 1
        tbl[id] = 0
    end
    tbl[id] = tbl[id] + 1
end

-- How high the camera is above the player object, and from that whether they are crouching.
function H.pose_eye(go, now)
    local P = H.POSE
    local cam = state.local_pos
    P.eye = nil
    if not cam then return end
    local ok, y = pcall(function() return go:call("get_Transform"):call("get_Position").y end)
    if not ok or type(y) ~= "number" or y ~= y then return end
    local eye = cam.y - y
    if eye < 0.5 or eye > 2.6 then return end -- the camera is not on the player (a cutscene, a loading screen)
    P.eye = eye
    local bucket = math.floor(now / 10)
    local b = P.eye_buckets
    if b[bucket] == nil or eye > b[bucket] then b[bucket] = eye end
    local top
    for k, v in pairs(b) do
        if k < bucket - 12 then b[k] = nil elseif top == nil or v > top then top = v end
    end
    P.stand_eye = top or eye
    P.eye_drop = P.stand_eye - eye
    if P.crouch_h then
        if P.eye_drop < CFG.CROUCH_EXIT then P.crouch_h = false end
    elseif P.eye_drop > CFG.CROUCH_ENTER then
        P.crouch_h = true
    end
    P.crouch_reads = P.crouch_reads + (P.crouch_h and 1 or 0)
end

-- Once per player object: every field of every player component whose name hints at crouching or a stance. They are only
-- READ (and compared with the camera-height crouch), so the file can say which one is the game's own crouch flag.
function H.pose_scan_candidates(comps, addr)
    local P = H.POSE
    P.cands, P.cands_addr = {}, addr
    for _, c in ipairs(comps) do
        pcall(function()
            local t = c.obj:get_type_definition()
            while t and #P.cands < 14 do
                local tn = t:get_full_name()
                if tn:find("^System%.") or tn:find("^via%.Component") or tn:find("^via%.Behavior") then break end
                for _, f in ipairs(t:get_fields() or {}) do
                    if #P.cands >= 14 then break end
                    if not f:is_static() then
                        local fname = f:get_name()
                        local low = fname:lower()
                        if low:find("crouch", 1, true) or low:find("squat", 1, true) or low:find("sneak", 1, true)
                            or low:find("duck", 1, true) or low:find("stoop", 1, true) or low:find("stance", 1, true)
                            or low:find("posture", 1, true) then
                            local ft = f:get_type()
                            P.cands[#P.cands + 1] = { comp = c.full, name = fname, ftype = ft and ft:get_full_name() or "?",
                                n = 0, agree = 0, ntrue = 0, vals = {}, nvals = 0, last = nil }
                        end
                    end
                end
                t = t:get_parent_type()
            end
        end)
    end
end

-- Returns true when this call actually took a new reading (the recorder counts those).
function H.pose_read(now)
    local P = H.POSE
    local gap = P.fail_run >= 20 and 1.0 or CFG.POSE_SAMPLE -- an unreadable player: only look once a second
    if now - P.next_at < gap then return false end
    P.next_at = now
    local go = player_object()
    if not go then
        P.guard, P.heal, P.heal_raw, P.guard_src = false, false, false, "-"
        P.crouch, P.crouch_h, P.crouch_src, P.eye = false, false, "-", nil
        P.seq, P.hands, P.gun, P.go_addr = nil, nil, nil, nil
        P.hands_id, P.gun_id, P.cancel = nil, nil, nil
        return false
    end
    local addr = H.address_of(go)
    if addr ~= P.go_addr or now - P.comps_at > 3 then
        if addr ~= P.go_addr then
            P.seq, P.hands, P.gun = nil, nil, nil
            P.eye_buckets, P.stand_eye, P.crouch_h = {}, nil, false -- a new player object: measure the standing height again
        end
        P.go_addr, P.comps_at = addr, now
        local seq, hands, gun
        local comps = H.player_components()
        P.comp_by_name = {}
        for _, c in ipairs(comps) do
            P.comp_by_name[c.full] = c.obj
            if c.full == "app.PlayerSequenceManager" then seq = c.obj
            elseif c.full == "app.PlayerHands" then hands = c.obj
            elseif c.full == "app.PlayerGun" then gun = c.obj end
        end
        P.seq, P.hands, P.gun = seq, hands, gun
        if P.cands_addr ~= addr and #comps > 0 then pcall(H.pose_scan_candidates, comps, addr) end
    end
    P.reads = P.reads + 1

    local cancel = H.pose_field(P.seq, "IsGuardCancelAccepted")
    local hid = H.pose_field(P.hands, "<actionID>k__BackingField")
    local gid = H.pose_field(P.gun, "<actionID>k__BackingField")
    if type(cancel) == "boolean" then P.cancel = cancel else P.cancel = nil end -- (not `and/or`: false must stay false)
    P.hands_id = type(hid) == "number" and hid or nil
    P.gun_id = type(gid) == "number" and gid or nil
    H.pose_hist(P.hist_hands, P.hands_id)
    H.pose_hist(P.hist_gun, P.gun_id)
    if P.cancel == nil and P.hands_id == nil then
        P.fails, P.fail_run = P.fails + 1, P.fail_run + 1
    else
        P.fail_run = 0
    end

    local guard, src = false, "-"
    if P.cancel ~= nil then
        guard, src = P.cancel, "IsGuardCancelAccepted"
    elseif P.hands_id and P.GUARD_HANDS[P.hands_id] then
        guard, src = true, "PlayerHands.actionID"
    elseif P.gun_id and P.GUARD_GUN[P.gun_id] then
        guard, src = true, "PlayerGun.actionID"
    end
    P.guard, P.guard_src = guard, src
    P.heal_raw = P.hands_id ~= nil and P.HEAL_HANDS[P.hands_id] == true
    -- (9.11) hands 16/17 also play while you look at the inventory (your 9.9 notes: "healing animation shows when checking
    -- inventory"). Not a heal while a menu is open, nor for a pose that was already running behind one for half a second.
    if P.heal_raw then
        if CFG.menu and CFG.menu.shown_now == true then
            P.inv_since = P.inv_since or now
            if now - P.inv_since > 0.5 then P.inv_pose = true end
            P.heal_raw = false
            P.heal_blocked = (P.heal_blocked or 0) + 1
        elseif P.inv_pose then
            P.heal_raw = false
            P.heal_blocked = (P.heal_blocked or 0) + 1
        end
    else
        P.inv_since, P.inv_pose = nil, false
    end
    if P.heal_raw then P.heal_until = now + CFG.HEAL_POSE_TAIL end
    P.heal = now < P.heal_until
    if P.guard then P.guard_reads = P.guard_reads + 1 end
    if P.heal_raw then P.heal_reads = P.heal_reads + 1 end

    H.pose_eye(go, now)
    -- (9.11) the game has its own flag: app.PlayerMovement.IsCrouch. In the 9.9 file it was true for 12 % of the readings and
    -- CrouchRate was 1 in the same readings, while the camera-height guess said "crouched" for half of them.
    local isc = H.pose_field(P.comp_by_name["app.PlayerMovement"], "IsCrouch")
    if type(isc) == "boolean" then
        P.crouch, P.crouch_src = isc, "PlayerMovement.IsCrouch"
    else
        P.crouch = P.eye ~= nil and P.crouch_h == true
        P.crouch_src = P.eye ~= nil and "camera height" or "-"
    end
    if P.eye ~= nil then
        for _, c in ipairs(P.cands) do
            local v = H.pose_field(P.comp_by_name[c.comp], c.name)
            if v ~= nil then
                c.n, c.last = c.n + 1, v
                if type(v) == "boolean" then
                    if v then c.ntrue = c.ntrue + 1 end
                    if v == P.crouch_h then c.agree = c.agree + 1 end
                elseif type(v) == "number" then
                    local e = c.vals[v]
                    if e == nil and c.nvals < 8 then e = { n = 0, crouched = 0 }; c.vals[v] = e; c.nvals = c.nvals + 1 end
                    if e then
                        e.n = e.n + 1
                        if P.crouch_h then e.crouched = e.crouched + 1 end
                    end
                end
            end
        end
    end
    return true
end

state.pose_source = function(now)
    H.pose_read(now)
    local P = H.POSE
    local guard, heal = P.guard, P.heal
    if H.rec.use_signal and H.rec.signal and H.rec.guard_now(now) then guard = true end -- (an extra, learned signal the player ticked)
    -- 9.9: a downed player's body still does what it does (the 9.8 build hid it); the other player sees the truth.
    local crouch = P.crouch
    P.sent.packets = P.sent.packets + 1
    if guard then P.sent.guard = P.sent.guard + 1 end
    if heal then P.sent.heal = P.sent.heal + 1 end
    if crouch then P.sent.crouch = P.sent.crouch + 1 end
    return guard, heal, crouch
end

-- A table keyed by numbers, as one keyed by text (the debug file's JSON turns number keys into a list full of holes).
function H.strkeys(t)
    local out = {}
    for k, v in pairs(t) do out[tostring(k)] = v end
    return out
end

-- Fields that might be the game's own crouch flag, with how often each agreed with the camera-height crouch.
function H.crouch_report()
    local out = {}
    for _, c in ipairs(H.POSE.cands) do
        local e = { field = c.comp .. "." .. c.name, type = c.ftype, readings = c.n, last = c.last }
        if c.ftype == "System.Boolean" then
            e.true_readings = c.ntrue
            e.agrees_with_camera_height_percent = c.n > 0 and math.floor(c.agree / c.n * 100 + 0.5) or nil
        else
            local vals = {}
            for v, r in pairs(c.vals) do vals[tostring(v)] = { readings = r.n, while_camera_says_crouched = r.crouched } end
            e.values = vals
        end
        out[#out + 1] = e
    end
    return out
end

----------------------------------------------------------------------------------------------
-- Weapon lock and movement lock while down (9.8, rebuilt in 9.9 and again in 9.12). A downed player could still aim, shoot
-- and walk about. The recordings show the game's own gate for aiming and shooting: app.PlayerSequenceManager.IsAimAccepted
-- and IsAttackAccepted are TRUE normally and the game itself sets them FALSE while you block. While you are down (and only then)
-- this holds both at false and puts them back to true when you are up (not in the middle of a block, where the game puts them
-- back itself).
-- 9.8 wrote them once per frame; 9.9 at the start and end of each of the game's update phases. The real file (0.6) then said:
-- the game opens them again INSIDE its UpdateBehavior phase (found open after it 706 times in 5,241 frames, never anywhere
-- else), i.e. between our write before the phase and the moment the gun reads them. 9.12 therefore hooks the sequence
-- manager's own update methods that really exist (updateActionTrack, updateMovementTrack, onMotionUpdated ...: the file listed
-- them; there is no `update`, which is what 9.9 looked for) and closes the gates right after each. As a second line it refuses the
-- gun's own tryAttack / tryAimStart / trySemiAimStart while you are down. For movement it makes the sequence manager's
-- isMoveAccepted answer "no" and, if the game moves you anyway, puts you back where you fell (the report counts both).
-- Every route counts how often it fired and how often it found a gate open again, so the file says which of them works.
-- UNTESTED in the game: it WRITES two booleans of the player's sequence manager, skips a few gun calls and may set the player's
-- position. The checkboxes turn each part off.
----------------------------------------------------------------------------------------------
H.LOCK = {
    on = true, wrote = false, comp = nil, comp_at = -10, go_addr = nil, want = false,
    writes = 0, fails = 0, rewritten = 0, restored = 0, holds = 0, status = "idle",
    FIELDS = { "IsAimAccepted", "IsAttackAccepted" },
    PHASES = { "UpdateHID", "UpdateBehavior", "LateUpdateBehavior", "UpdatePhysics", "UpdateMotion", "UpdateGUI",
        "BeginRendering", "EndRendering" },
    -- where in the frame a downed player who has moved is put back (the movement itself happens somewhere in these)
    PIN_AT = { frame = true, ["post:UpdateBehavior"] = true, ["post:UpdatePhysics"] = true, ["post:LateUpdateBehavior"] = true,
        ["pre:BeginRendering"] = true },
    -- the sequence manager's own methods that exist (from the real file) and, as a fallback for other builds, the usual names
    -- (the generic update / lateUpdate / doUpdate names were in this list as a guess for other builds; get_method found an inherited
    -- one that fires for every object, 2.4 million calls in one session, so they are out. The real file showed the gates open
    -- again right after updateActionTrack, 1229 times, and nowhere else.)
    SEQ_AFTER = { "updateActionTrack", "updateMovementTrack", "updateDeadTrack", "updateJogTrack", "updateTurnTrack",
        "updateCodexTrack", "updateLaserSightTrack", "onMotionUpdated" },
    GUN_TRY = { "tryAttack", "tryAimStart", "trySemiAimStart" },
    HOT_PER_SECOND = 6000, -- a hook that fires more often than this is muted (it is on something much hotter than a per-frame method)
    phase = {}, phase_order = {}, registered = {},
    hooks = { on = true, tried = false, installed = {}, missing = {}, error = nil, methods = {}, dump = {}, calls = {}, muted = {}, win_at = 0, win = {} },
    guns = { on = true, tried = false, installed = {}, missing = {}, skipped = 0, error = nil },
    move = { on = true, tried = false, installed = {}, missing = {}, error = nil, getter_calls = 0, blocked = 0,
        pinned = 0, pin_fails = 0, reanchored = 0, anchor = nil, tolerance = 0.05, teleport = 4, pin_places = {}, fields = {}, xf = nil },
}

-- True if this hook is firing absurdly often (a second's worth over the limit): it is then ignored from now on.
function H.lock_hot(tag)
    local K = H.LOCK.hooks
    K.calls[tag] = (K.calls[tag] or 0) + 1
    if K.muted[tag] then return true end
    local now = os.clock()
    if now - K.win_at >= 1 then K.win_at, K.win = now, {} end
    K.win[tag] = (K.win[tag] or 0) + 1
    if K.win[tag] > H.LOCK.HOT_PER_SECOND then
        K.muted[tag] = true
        say("weapon lock: " .. tag .. " fires more than " .. H.LOCK.HOT_PER_SECOND .. " times a second: ignored from now on")
        return true
    end
    return false
end

-- A downed player who has moved from where they fell is put back (only sideways: gravity and stairs are left alone). A jump
-- of several metres is the game moving them (a cutscene, a new scene): that is the new place, not a walk.
function H.lock_pin(tag)
    local L = H.LOCK
    local M = L.move
    if not L.want or not M.on or not M.xf then return end
    local ok, p = pcall(function() return M.xf:call("get_Position") end)
    if not ok or not p then return end
    if not M.anchor then
        M.anchor = { x = p.x, y = p.y, z = p.z }
        return
    end
    local dx, dz = p.x - M.anchor.x, p.z - M.anchor.z
    local d = math.sqrt(dx * dx + dz * dz)
    if d > M.teleport then
        M.anchor = { x = p.x, y = p.y, z = p.z }
        M.reanchored = M.reanchored + 1
    elseif d > M.tolerance then
        local okp = pcall(function() M.xf:call("set_Position", Vector3f.new(M.anchor.x, p.y, M.anchor.z)) end)
        if okp then
            M.pinned = M.pinned + 1
            M.pin_places[tag] = (M.pin_places[tag] or 0) + 1
        else
            M.pin_fails = M.pin_fails + 1
        end
    end
end

-- Closes the gate if it is open. `tag` says where in the frame this happened (frame, pre:UpdateBehavior, hook:updateActionTrack ...).
function H.lock_close(tag)
    local L = H.LOCK
    if not L.want or not L.comp then return end
    local rec = L.phase[tag]
    if rec == nil then
        rec = { calls = 0, open = 0 }
        L.phase[tag] = rec
        L.phase_order[#L.phase_order + 1] = tag
    end
    rec.calls = rec.calls + 1
    for _, f in ipairs(L.FIELDS) do
        if H.pose_field(L.comp, f) == true then -- the game (or the start of the lock) has it on: take it away
            rec.open = rec.open + 1
            if L.wrote and tag == "frame" then L.rewritten = L.rewritten + 1 end -- we had it false at the last frame and the game put it back
            local ok = pcall(function() L.comp:set_field(f, false) end)
            if ok then
                L.writes = L.writes + 1
                L.wrote = true
            else
                L.fails = L.fails + 1
            end
        end
    end
    if L.PIN_AT[tag] then H.lock_pin(tag) end
end

-- Callbacks at the start and end of the game's update phases (a name the game does not have simply never fires).
function H.lock_register_phases()
    local L = H.LOCK
    for _, name in ipairs(L.PHASES) do
        if re.on_pre_application_entry then
            local ok = pcall(re.on_pre_application_entry, name, function() H.lock_close("pre:" .. name) end)
            if ok then L.registered[#L.registered + 1] = "pre:" .. name end
        end
        if re.on_application_entry then
            local ok = pcall(re.on_application_entry, name, function() H.lock_close("post:" .. name) end)
            if ok then L.registered[#L.registered + 1] = "post:" .. name end
        end
    end
end

-- Hooks one method by name: returns true if it was hooked. A crash while hooking is named by the next start's report.
function H.lock_hook(tn, td, name, pre, post)
    local okm, m = pcall(function() return td:get_method(name) end)
    if not okm or not m then return false end
    tracer.crumb("hooking", tn .. "." .. name)
    local okh = pcall(sdk.hook, m, pre or function() return H.CALL_ORIGINAL end, post or function(retval) return retval end)
    tracer.crumb("clean", "hook installed: " .. tn .. "." .. name) -- (9.14) otherwise this stayed as "the suspect" for ever: the 0.9 file's first line blamed a hook that had long been installed)
    return okh
end

function H.lock_methods_of(tn)
    local out, td = {}, sdk.find_type_definition(tn)
    if not td then return out, nil end
    pcall(function()
        for _, m in ipairs(td:get_methods() or {}) do
            if #out < 160 then out[#out + 1] = m:get_name() end
        end
    end)
    return out, td
end

-- The first time you go down (each part only if its box is ticked): list the methods of the player's sequence manager / gun /
-- weapon change (for the file) and install the hooks. A box ticked later installs its part then.
function H.lock_install_hooks()
    local L = H.LOCK
    local K, G, M = L.hooks, L.guns, L.move
    local td_seq
    if (K.on and not K.tried) or (M.on and not M.tried) then
        local names, td = H.lock_methods_of("app.PlayerSequenceManager")
        if #K.methods == 0 then K.methods = names end
        if next(K.dump) == nil then
            for _, tn in ipairs({ "app.PlayerGun", "app.PlayerWeaponChange", "app.PlayerReticleController", "app.PlayerHands" }) do
                K.dump[tn] = (H.lock_methods_of(tn))
            end
        end
        td_seq = td
    end
    -- 1. close the gates right after the sequence manager's own updates
    if K.on and not K.tried then
        K.tried = true
        for i, name in ipairs(td_seq and L.SEQ_AFTER or {}) do
            local tag = "hook:" .. name
            local ok = H.lock_hook("app.PlayerSequenceManager", td_seq, name, nil, function(retval)
                if L.want and K.on and not H.lock_hot(tag) then pcall(H.lock_close, tag) end
                return retval
            end)
            if ok then K.installed[#K.installed + 1] = name
            else K.missing[#K.missing + 1] = name end
        end
        if not td_seq then K.error = "app.PlayerSequenceManager type not found"
        elseif #K.installed == 0 then K.error = "no update method found on app.PlayerSequenceManager (see the method list)" end
        say("weapon lock: gates closed after " .. (#K.installed > 0 and table.concat(K.installed, ", ") or "nothing") .. " of the sequence manager")
    end
    -- 2. the gun's own "may I shoot / aim" calls answer no
    if G.on and not G.tried then
        G.tried = true
        local td = sdk.find_type_definition("app.PlayerGun")
        local skip = sdk.PreHookResult and sdk.PreHookResult.SKIP_ORIGINAL
        if not td then
            G.error = "app.PlayerGun type not found"
        elseif skip == nil then
            G.error = "this REFramework can't skip a call"
        else
            for _, name in ipairs(L.GUN_TRY) do
                local tag = "gun:" .. name
                local skipped_now = false
                local ok = H.lock_hook("app.PlayerGun", td, name, function(args)
                    skipped_now = false
                    if L.want and G.on and not H.lock_hot(tag) then
                        skipped_now = true
                        G.skipped = G.skipped + 1
                        return skip
                    end
                    return H.CALL_ORIGINAL
                end, function(retval)
                    if skipped_now then -- the game's own answer was never computed: say "no"
                        skipped_now = false
                        local okz, z = pcall(sdk.to_ptr, 0)
                        if okz and z ~= nil then return z end
                    end
                    return retval
                end)
                if ok then G.installed[#G.installed + 1] = name else G.missing[#G.missing + 1] = name end
            end
        end
        say("weapon lock: gun calls refused while down: " .. (#G.installed > 0 and table.concat(G.installed, ", ") or "nothing hooked"))
    end
    -- 3. the sequence manager says "you may not move"
    if M.on and not M.tried then
        M.tried = true
        if not td_seq then M.error = "app.PlayerSequenceManager type not found" end
        for _, name in ipairs(td_seq and { "get_isMoveAccepted" } or {}) do
            local tag = "move:" .. name
            local ok = H.lock_hook("app.PlayerSequenceManager", td_seq, name, nil, function(retval)
                if L.want and M.on and not H.lock_hot(tag) then
                    M.getter_calls = M.getter_calls + 1
                    local okz, z = pcall(sdk.to_ptr, 0)
                    if okz and z ~= nil then
                        M.blocked = M.blocked + 1
                        return z
                    end
                end
                return retval
            end)
            if ok then M.installed[#M.installed + 1] = name else M.missing[#M.missing + 1] = name end
        end
        say("weapon lock: movement gate: " .. (#M.installed > 0 and table.concat(M.installed, ", ") or "nothing hooked") .. " (you are also put back where you fell if you move)")
    end
end

function H.lock_leaks()
    local L = H.LOCK
    local out = {}
    for _, tag in ipairs(L.phase_order) do
        local r = L.phase[tag]
        if r.open > 0 then out[#out + 1] = string.format("%s %d/%d", tag, r.open, r.calls) end
    end
    return #out > 0 and table.concat(out, ", ") or "none"
end

function H.lock_update(now)
    local L = H.LOCK
    local want = L.on and pstat.downed == true
    if not want and not L.wrote then
        L.want = false
        L.move.anchor = nil
        L.status = L.on and "idle (you are not down)" or "switched off"
        return
    end
    local go = player_object()
    if not go then -- a reload: the new player starts whole, nothing of ours is left on it
        L.comp, L.go_addr, L.wrote, L.want = nil, nil, false, false
        L.move.anchor, L.move.xf = nil, nil
        L.status = "idle (no player object)"
        return
    end
    local addr = H.address_of(go)
    if addr ~= L.go_addr then
        L.comp, L.go_addr, L.comp_at, L.want = nil, addr, -10, false
        L.move.anchor, L.move.xf = nil, nil
    end
    if not L.move.xf then
        local okx, xf = pcall(function() return go:call("get_Transform") end)
        if okx and xf then L.move.xf = xf end
    end
    if not L.comp and now - L.comp_at > 1 then
        L.comp_at = now
        for _, c in ipairs(H.player_components()) do
            if c.full == "app.PlayerSequenceManager" then
                L.comp = c.obj
                break
            end
        end
    end
    if not L.comp then
        L.want = false
        L.status = "app.PlayerSequenceManager not found: the weapon is NOT locked"
        return
    end
    if want then
        L.want = true
        pcall(H.lock_install_hooks)
        H.lock_close("frame")
        L.holds = L.holds + 1
        local M = L.move
        L.status = string.format("HOLDING aim and attack off (%d writes, %d failed writes; the game opened them again before: %s)%s%s",
            L.writes, L.fails, H.lock_leaks(),
            L.guns.on and string.format("; gun calls refused: %d", L.guns.skipped) or "",
            M.on and string.format("; movement: gate said no %d times, put back %d times", M.blocked, M.pinned) or "")
    else -- up again: give the gate back, unless a block is in the middle of it (the game does that itself at the end of the block)
        L.want = false
        L.move.anchor = nil
        H.pose_read(now)
        local blocking = H.POSE.cancel == true
        if not blocking then
            for _, f in ipairs(L.FIELDS) do
                if H.pose_field(L.comp, f) == false then pcall(function() L.comp:set_field(f, true) end) end
            end
            L.restored = L.restored + 1
        end
        L.wrote = false
        L.status = blocking and "released (the block in progress ends it)" or "released: aim and attack are back"
        say("weapon lock: " .. L.status)
    end
end
pstat.lock_update = H.lock_update
pstat.lock = H.LOCK -- (the settings read and write the switches through this)
pcall(H.lock_register_phases)

----------------------------------------------------------------------------------------------
-- Button 11 (9.7): "Record my player". It NEVER hooks anything. Ten times a second it reads the fields of the player's
-- app.Player* components (and one level of the objects they hold) plus a few values of the animation layers, and writes
-- down every change. Steady noise (anything that changes while you stand still) is muted. The guided script has you
-- block twice and use a healing item; the report then lists the fields that flipped on both blocks and came back after
-- (the block signal) and everything that changed while you healed (the animation). The best block candidate is then used
-- to drive the stand-in's block pose, and everything is in the debug file for me to read.
-- Reading is done through the same get_field calls the dumps in buttons 7/8 use. The animation values are the only calls
-- of the game's own methods, limited to zero-argument getters with plain return types; a breadcrumb is written before the
-- first call of each, so a crash names its cause on the next start.
----------------------------------------------------------------------------------------------
H.rec = {
    on = false, mode = nil, steps = nil, step = 0, step_end = 0, hotkey = 0x75, key_was_down = false, -- F6
    last_sample = -10, prev = nil, last_n = 0, targets = {}, motions = {}, targets_at = -10,
    field_cache = {}, getter_cache = {}, getter_seen = {}, crumbed = {}, meta = {}, muted = {}, muted_n = 0,
    ph = nil, phases = {}, events = 0, marks = 0, samples = 0,
    signal = nil, use_signal = false, sig_obj = nil, sig_obj_at = -10, sig_at = -10, sig_val = false, sig_raw = nil,
    report = {},
}
local R = H.rec
pstat.rec = R
R.MAX_KEYS, R.MAX_SUBS, R.MAX_EVENTS, R.PER_KEY_LOG, R.SAMPLE_EVERY = 1600, 40, 900, 6, 0.1
R.PRIM = { ["System.Boolean"] = true, ["System.Int32"] = true, ["System.UInt32"] = true, ["System.Int16"] = true,
    ["System.UInt16"] = true, ["System.Int64"] = true, ["System.UInt64"] = true, ["System.Byte"] = true,
    ["System.SByte"] = true, ["System.Single"] = true, ["System.Double"] = true, ["System.String"] = true }
-- animation getters worth reading (zero arguments, plain return type), and names never to call
R.GETTER_WORDS = { "motion", "frame", "node", "bank", "id", "name", "state", "speed", "blend", "weight", "current", "mode",
    "status", "priority", "loop", "play", "end", "guard", "heal" }
R.GETTER_SKIP = { "instance", "resource", "component", "joint", "transform", "gameobject", "owner", "parent", "child", "handle",
    "pointer", "address", "delegate", "callback" }

R.GUIDED = {
    { key = "prep", secs = 6, quiet = true, text = "Starting. Close this menu (Insert) and stand still in the game." },
    { key = "idle", secs = 4, text = "Stand still. Press nothing." },
    { key = "block1", secs = 4, text = "HOLD the block button now and keep holding it." },
    { key = "rest1", secs = 3, text = "Let go. Stand still." },
    { key = "block2", secs = 4, text = "HOLD the block button again." },
    { key = "rest2", secs = 3, text = "Let go. Stand still." },
    { key = "heal", secs = 45, heal = true, text = "Use a Herb / Chem Fluid now: open the inventory, use it, close it, wait for the animation to end. [F6] = done." },
    { key = "rest3", secs = 3, text = "Last moment: stand still." },
}
R.FREE = {
    { key = "prep", secs = 6, quiet = true, text = "Starting. Close this menu (Insert) and stand still in the game." },
    { key = "idle", secs = 4, text = "Stand still for a moment (this learns what changes by itself)." },
    { key = "free", secs = 180, text = "Do it now. Press [F6] each time you START (it drops a numbered mark). Stop from the panel." },
}

function R.is_obj(v) return type(v) == "userdata" or type(v) == "table" end -- (managed objects are userdata in the game)

function R.say(msg)
    local old = dbg.pin
    dbg.pin = true
    say(msg)
    dbg.pin = old
end

function R.fmt(v)
    if type(v) == "number" then
        if v == math.floor(v) and math.abs(v) < 1e9 then return string.format("%d", v) end
        return string.format("%.4g", v)
    elseif type(v) == "string" then
        return '"' .. v:sub(1, 40) .. '"'
    end
    return tostring(v)
end

function R.differs(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) > 1e-4 end
    return a ~= b
end

-- "prim": read the value. "obj": an app.* object whose own plain fields are read too. nil: ignored (arrays, structs, ...).
function R.kind_of(ft)
    if not ft then return nil end
    local tn = ft:get_full_name()
    if R.PRIM[tn] then return "prim" end
    local isenum = false
    pcall(function() isenum = ft:is_a("System.Enum") == true end)
    if not isenum then
        pcall(function()
            local par = ft:get_parent_type()
            isenum = par ~= nil and par:get_full_name() == "System.Enum"
        end)
    end
    if isenum then return "prim" end
    if tn:find("^app%.") and not tn:find("[%[`<]") then
        local okv, isval = pcall(function() return ft:is_value_type() end)
        if okv and isval == false then return "obj" end
        if okv and isval == true then return "val" end -- an enum the checks above did not recognise, or a struct: only numbers / flags are kept
    end
    return nil
end

function R.type_fields(td)
    local tn = td:get_full_name()
    local list = R.field_cache[tn]
    if list then return list end
    tracer.crumb("recorder", "fields of " .. tn)
    list = {}
    pcall(function()
        local t = td
        while t and #list < 140 do
            local n = t:get_full_name()
            if n:find("^System%.") or n:find("^via%.Component") or n:find("^via%.Behavior") then break end
            for _, f in ipairs(t:get_fields() or {}) do
                if not f:is_static() and #list < 140 then
                    local kind = R.kind_of(f:get_type())
                    if kind then list[#list + 1] = { name = f:get_name(), kind = kind } end
                end
            end
            t = t:get_parent_type()
        end
    end)
    R.field_cache[tn] = list
    return list
end

-- Reads the plain fields of obj into cur[key]. `comp` is the component's type name, `parent` the field it was reached through.
function R.read_obj(obj, comp, parent, cur, budget)
    local where = parent and (comp .. "." .. parent) or comp
    if not R.crumbed[where] then
        R.crumbed[where] = true
        tracer.crumb("recorder", "reading " .. where) -- the first read of each object: a crash names it
    end
    local okt, td = pcall(function() return obj:get_type_definition() end)
    if not okt or not td then return end
    for _, f in ipairs(R.type_fields(td)) do
        if budget.n >= R.MAX_KEYS then return end
        local okv, v = pcall(function() return obj:get_field(f.name) end)
        if okv and v ~= nil then
            if f.kind == "prim" or f.kind == "val" then
                if f.kind == "prim" and R.is_obj(v) then v = as_text(v) end
                local tv = type(v)
                if tv == "number" or tv == "boolean" or (tv == "string" and f.kind == "prim") then
                    local key = parent and (comp .. "." .. parent .. "." .. f.name) or (comp .. "." .. f.name)
                    cur[key] = v
                    budget.n = budget.n + 1
                    if not R.meta[key] then R.meta[key] = { comp = comp, path = parent and { parent, f.name } or { f.name } } end
                end
            elseif f.kind == "obj" and not parent and R.is_obj(v) and budget.subs < R.MAX_SUBS then
                budget.subs = budget.subs + 1
                R.read_obj(v, comp, f.name, cur, budget)
            end
        end
    end
end

function R.getter_ok(low)
    for _, w in ipairs(R.GETTER_SKIP) do
        if low:find(w, 1, true) then return false end
    end
    for _, w in ipairs(R.GETTER_WORDS) do
        if low:find(w, 1, true) then return true end
    end
    return false
end

function R.layer_getters(td)
    local tn = td:get_full_name()
    local list = R.getter_cache[tn]
    if list then return list end
    list = {}
    pcall(function()
        for _, m in ipairs(td:get_methods() or {}) do
            local name = m:get_name()
            local low = name:lower()
            if #list < 40 and (low:find("^get") or low:find("^is") or low:find("^has")) and R.getter_ok(low) then
                local params = m:get_param_types() or {}
                local ret = m:get_return_type()
                if #params == 0 and ret and (R.PRIM[ret:get_full_name()] or R.kind_of(ret) == "prim") then list[#list + 1] = name end
            end
        end
    end)
    R.getter_cache[tn] = list
    return list
end

function R.read_getters(obj, prefix, cur)
    local okt, td = pcall(function() return obj:get_type_definition() end)
    if not okt or not td then return end
    local tn = td:get_full_name()
    for _, name in ipairs(R.layer_getters(td)) do
        local id = tn .. "." .. name
        if not R.getter_seen[id] then
            R.getter_seen[id] = true
            tracer.crumb("recorder", id) -- before the first call of each getter: a crash names it
        end
        local ok, v = pcall(function() return obj:call(name) end)
        if ok and v ~= nil then
            if R.is_obj(v) then v = as_text(v) end
            local tv = type(v)
            if tv == "number" or tv == "boolean" or tv == "string" then cur[prefix .. "." .. name] = v end
        end
    end
end

function R.read_motion(m, prefix, cur)
    local okc, cnt = pcall(function() return m:call("getLayerCount") end)
    if not okc or type(cnt) ~= "number" then return end
    for i = 0, math.min(cnt, 8) - 1 do
        local okl, layer = pcall(function() return m:call("getLayer", i) end)
        if okl and R.is_obj(layer) then R.read_getters(layer, prefix .. ".layer" .. i, cur) end
    end
end

function R.refresh_targets(now)
    R.targets_at = now
    local comps = H.player_components()
    local t, motions = {}, {}
    for _, c in ipairs(comps) do
        if c.full:find("^app%.Player") then
            t[#t + 1] = c
        elseif c.full == "via.motion.Motion" then
            motions[#motions + 1] = c.obj
        end
    end
    if #motions == 0 then
        for _, m in ipairs(R.child_motions or {}) do motions[#motions + 1] = m end
    end
    R.targets, R.motions = t, motions
end

-- The animation component may sit on a child object of Pl0000 instead of on Pl0000: look once, when a recording starts.
function R.find_child_motions()
    R.child_motions = {}
    local shown = 0
    pcall(each_gameobject, function(go, path)
        if path:find("/Pl0000", 1, true) and shown < 12 then
            shown = shown + 1
            local okc, names = pcall(component_names, go)
            R.say("   player object: " .. path .. "  [" .. (okc and table.concat(names, ", ") or "?") .. "]")
            pcall(function()
                for _, c in ipairs(go:call("get_Components"):get_elements()) do
                    if c:get_type_definition():get_full_name() == "via.motion.Motion" and #R.child_motions < 3 then
                        R.child_motions[#R.child_motions + 1] = c
                    end
                end
            end)
        end
    end, 20000)
end

function R.sample()
    local cur, budget = {}, { n = 0, subs = 0 }
    for _, c in ipairs(R.targets) do R.read_obj(c.obj, c.full, nil, cur, budget) end
    local nplain = budget.n
    for i, m in ipairs(R.motions) do R.read_motion(m, "motion" .. i, cur) end
    return cur, nplain
end

function R.begin_step(i, now)
    R.close_phase(now)
    R.step = i
    local st = R.steps[i]
    R.step_end = now + st.secs
    R.ph = { key = st.key, t0 = now, keys = {}, quiet = st.quiet, heal = st.heal }
    R.say(string.format("--- step %d/%d  %s: %s", i, #R.steps, st.key, st.text))
end

function R.close_phase(now)
    local ph = R.ph
    if not ph then return end
    ph.t1 = now
    R.phases[#R.phases + 1] = ph
    R.ph = nil
    if ph.key == "idle" then -- whatever changed by itself while you stood still is noise from here on
        local names = {}
        for key, rec in pairs(ph.keys) do
            if rec.n >= 2 then
                R.muted[key] = true
                R.muted_n = R.muted_n + 1
                names[#names + 1] = key
            end
        end
        table.sort(names)
        R.say(string.format("   idle: %d fields change by themselves and are ignored from now on%s", #names,
            #names > 0 and (": " .. table.concat(names, ", ", 1, math.min(#names, 25)) .. (#names > 25 and ", ..." or "")) or ""))
    elseif not ph.quiet then
        local busy = {}
        for key, rec in pairs(ph.keys) do
            if rec.n > R.PER_KEY_LOG and not R.muted[key] then busy[#busy + 1] = { key, rec } end
        end
        table.sort(busy, function(a, b) return a[1] < b[1] end)
        for i = 1, math.min(#busy, 20) do
            local key, rec = busy[i][1], busy[i][2]
            R.say(string.format("   %s changed %d times in total: %s -> %s", key, rec.n, R.fmt(rec.first_from), R.fmt(rec.last)))
        end
    end
end

function R.on_change(now, key, pv, v)
    local ph = R.ph
    if not ph or R.muted[key] then return end
    local rec = ph.keys[key]
    if not rec then
        rec = { n = 0, first_from = pv, first_to = v, last = v, t_first = now - ph.t0 }
        ph.keys[key] = rec
    end
    rec.n = rec.n + 1
    rec.last = v
    rec.t_last = now - ph.t0
    if ph.quiet or ph.key == "idle" then return end
    if rec.n <= R.PER_KEY_LOG and R.events < R.MAX_EVENTS then
        R.events = R.events + 1
        R.say(string.format("  +%.2f s  %s : %s -> %s", now - ph.t0, key, R.fmt(pv), R.fmt(v)))
        if R.events == R.MAX_EVENTS then R.say("  (too many changes: no more are listed, the summaries at the end of each step still count them)") end
    end
end

function R.mark(now)
    R.marks = R.marks + 1
    R.say(string.format("  MARK %d at +%.2f s of step %s", R.marks, R.ph and (now - R.ph.t0) or 0, R.ph and R.ph.key or "?"))
end

function R.key_pressed(now)
    if not R.on then return end
    R.mark(now)
    if R.mode == "guided" or R.steps[R.step].key == "prep" or R.steps[R.step].key == "idle" then
        if R.step < #R.steps then R.begin_step(R.step + 1, now) else R.stop("finished") end
    end
end

function R.start(mode)
    if R.on then return end
    R.report = {}
    local now = os.clock()
    if not player_object() then
        R.report = { "Load into the game first: your player object (Pl0000) was not found." }
        say("recorder: " .. R.report[1])
        return
    end
    R.on, R.mode = true, mode
    R.steps = mode == "free" and R.FREE or R.GUIDED
    R.prev, R.last_n, R.last_sample = nil, 0, -10
    R.muted, R.muted_n, R.phases, R.events, R.marks, R.samples = {}, 0, {}, 0, 0, 0
    R.ph, R.step = nil, 0
    R.say("=== recorder started (" .. mode .. ") ===")
    tracer.crumb("recorder", "start")
    R.find_child_motions()
    R.refresh_targets(now)
    local names = {}
    for _, c in ipairs(R.targets) do names[#names + 1] = c.full end
    R.say(string.format("   reading %d components: %s", #R.targets, table.concat(names, ", ")))
    R.say(string.format("   animation components found: %d", #R.motions))
    for i, m in ipairs(R.motions) do
        pcall(function()
            local okc, cnt = pcall(function() return m:call("getLayerCount") end)
            R.say(string.format("   motion%d: %s, getLayerCount -> %s", i, m:get_type_definition():get_full_name(), okc and tostring(cnt) or "failed"))
            if okc and type(cnt) == "number" and cnt > 0 then
                local layer = m:call("getLayer", 0)
                if R.is_obj(layer) then
                    local ln = layer:get_type_definition():get_full_name()
                    R.say("   layer type: " .. ln .. ", getters read: " .. table.concat(R.layer_getters(layer:get_type_definition()), ", "))
                    dbg.pin = true
                    probe_type(ln, false, { "frame", "motion", "node", "bank", "speed", "blend", "weight", "state" }, 60)
                    dbg.pin = false
                end
            end
        end)
        dbg.pin = true
        probe_type("via.motion.Motion", false, { "layer", "node", "motion", "bank" }, 50)
        dbg.pin = false
    end
    R.begin_step(1, now)
end

-- The report: block candidates, then what happened while healing.
function R.analyse()
    local lines = {}
    local function add(t) lines[#lines + 1] = t end
    local by = {}
    for _, p in ipairs(R.phases) do by[p.key] = p end
    add(string.format("recorder: %d samples, %d fields tracked, %d ignored as noise, %d changes listed", R.samples, R.last_n, R.muted_n, R.events))

    local b1, b2, r1, r2 = by.block1, by.block2, by.rest1, by.rest2
    if b1 and b2 and r1 and r2 then
        local cands = {}
        for key, a in pairs(b1.keys) do
            local b, ra, rb = b2.keys[key], r1.keys[key], r2.keys[key]
            local meta = R.meta[key]
            if b and ra and rb and meta and a.last ~= a.first_from and a.first_from == b.first_from and a.last == b.last
                and ra.last == a.first_from and rb.last == a.first_from then
                local kind = type(a.last) == "boolean" and 3
                    or ((type(a.last) == "number" and a.last == math.floor(a.last) and math.abs(a.last - a.first_from) <= 16) and 2)
                    or (type(a.last) == "string" and 2) or 0
                if kind > 0 then
                    -- a field that ALSO flips to the same value while healing is not a block signal (isBothHands was one)
                    local hk = by.heal and by.heal.keys[key]
                    local heal_too = hk ~= nil and (hk.first_to == a.last or hk.last == a.last)
                    cands[#cands + 1] = { key = key, off = a.first_from, on = a.last, kind = kind, heal_too = heal_too,
                        changes = a.n + b.n + ra.n + rb.n, meta = meta }
                end
            end
        end
        table.sort(cands, function(x, y)
            if x.heal_too ~= y.heal_too then return not x.heal_too end
            local sx, sy = x.kind * 10 - x.changes, y.kind * 10 - y.changes
            if sx ~= sy then return sx > sy end
            return x.key < y.key
        end)
        if #cands == 0 then
            add("BLOCK: no field switched on in both holds and back off after. Did the block really happen both times?")
            add("   (the lines above show what did change; send me the debug file)")
        else
            add("BLOCK candidates (on in both holds, off after, still while idle):")
            for i = 1, math.min(#cands, 10) do
                local c = cands[i]
                add(string.format("   %d. %s : %s -> %s  (%d changes)%s", i, c.key, R.fmt(c.off), R.fmt(c.on), c.changes,
                    c.heal_too and "  [also does this while healing: not a block signal]" or ""))
            end
            local best = cands[1]
            -- 9.8: the stand-in's block pose uses the built-in signal (see H.POSE). The best candidate is kept for the panel's
            -- checkbox as an EXTRA signal, never switched on by itself.
            R.signal = { comp = best.meta.comp, path = best.meta.path, on = best.on, off = best.off, text = best.key }
            R.use_signal = false
            add("The block pose uses the built-in signal (IsGuardCancelAccepted). #1 is only kept as an optional extra: tick it in the panel to add it.")
        end
    else
        add("BLOCK: the guided steps were not all done, so no block signal was worked out.")
    end

    -- the built-in signals checked against what you really did (so a different game version or setup shows up here)
    local function share(p)
        local pc = p and p.pose
        if not pc or pc.n == 0 then return nil, 0 end
        return pc.g, pc.n
    end
    do
        local g1, n1 = share(by.block1)
        local g2, n2 = share(by.block2)
        local gr1, nr1 = share(by.rest1)
        local gr2, nr2 = share(by.rest2)
        local gi, ni = share(by.idle)
        if n1 > 0 or n2 > 0 then
            local rest_on = (gr1 or 0) + (gr2 or 0)
            local ok = (g1 or 0) >= 3 and (g2 or 0) >= 3 and rest_on <= 16 and (gi or 0) == 0
            add(string.format("BUILT-IN BLOCK SIGNAL (%s): on in %d/%d readings of block 1, %d/%d of block 2; on in %d/%d while resting, %d/%d while idle: %s",
                H.POSE.guard_src, g1 or 0, n1, g2 or 0, n2, rest_on, nr1 + nr2, gi or 0, ni, ok and "WORKS" or "CHECK THIS (it did not follow your blocks)"))
        end
    end

    local hp = by.heal
    if hp then
        local pc = hp.pose
        if pc and pc.h > 0 then
            add(string.format("HEAL ANIMATION (PlayerHands.actionID 16/17): from +%.2f s to +%.2f s, %.1f s long.",
                pc.heal_first or 0, pc.heal_last or 0, (pc.heal_last or 0) - (pc.heal_first or 0)))
        else
            add("HEAL ANIMATION: PlayerHands.actionID never became 16/17 during that step, so the heal pose would not show. Did the character really use an item?")
        end
        if hp.item_name then
            add(string.format("   item: %s taken out of the inventory %.2f s into the step (%s the animation).", hp.item_name, hp.item_at - hp.t0,
                (pc and pc.heal_last and (hp.item_at - hp.t0) >= pc.heal_last - 0.5) and "at the end of" or "during"))
        else
            add("   no healing item left the inventory during that step (use a Herb, Chem Fluid or Remedy, not a different item).")
        end
        local list = {}
        for key, rec in pairs(hp.keys) do list[#list + 1] = { key = key, rec = rec } end
        table.sort(list, function(a, b)
            if a.rec.t_first ~= b.rec.t_first then return a.rec.t_first < b.rec.t_first end
            return a.key < b.key
        end)
        add(string.format("   %d fields changed during the heal (in time order, the ones that came back to where they started marked *):", #list))
        for i = 1, math.min(#list, 22) do
            local e = list[i]
            local back = not R.differs(e.rec.first_from, e.rec.last)
            add(string.format("   %s +%.2f..%.2f s  %s : %s -> %s%s  (%d)", back and "*" or " ", e.rec.t_first, e.rec.t_last or e.rec.t_first, e.key,
                R.fmt(e.rec.first_from), back and (R.fmt(e.rec.first_to) .. " -> ") or "", R.fmt(e.rec.last), e.rec.n))
        end
    end
    return lines
end

function R.stop(why)
    if not R.on then return end
    local now = os.clock()
    R.close_phase(now)
    R.on = false
    R.say("=== recorder " .. tostring(why or "stopped") .. " ===")
    local ok, lines = pcall(R.analyse)
    if ok then
        R.report = lines
        for _, l in ipairs(lines) do R.say(l) end
    else
        R.report = { "recorder: analysis failed: " .. tostring(lines) }
        R.say(R.report[1])
    end
    R.say("=== recorder done: send me the debug file ===")
    tracer.crumb("clean", "recorder finished")
end

-- Every frame: the F6 key, the steps, the ten-per-second reading.
function pstat.rec_update(now)
    local okk, down = pcall(function() return reframework:is_key_down(R.hotkey) end)
    down = okk and down == true
    if down and not R.key_was_down then R.key_pressed(now) end
    R.key_was_down = down
    if not R.on then return end

    local st = R.steps[R.step]
    if st then
        local ended = now >= R.step_end
        local P = H.POSE
        H.pose_read(now)
        if P.reads ~= R.pose_reads_seen then -- a new reading of my block / heal signals: count it against the step it happened in
            R.pose_reads_seen = P.reads
            local ph = R.ph
            if ph then
                local pc = ph.pose
                if not pc then
                    pc = { n = 0, g = 0, h = 0 }
                    ph.pose = pc
                end
                pc.n = pc.n + 1
                if P.guard then pc.g = pc.g + 1 end
                if P.heal_raw then
                    pc.h = pc.h + 1
                    pc.heal_first = pc.heal_first or (now - ph.t0)
                    pc.heal_last = now - ph.t0
                    ph.last_event_at = now
                    if not ph.anim_seen then
                        ph.anim_seen = true
                        R.say(string.format("  MARK heal animation started (PlayerHands.actionID %s) at +%.2f s", tostring(P.hands_id), now - ph.t0))
                    end
                elseif ph.anim_seen and not ph.anim_end_said then
                    ph.anim_end_said = true
                    R.say(string.format("  MARK heal animation over (PlayerHands.actionID %s) at +%.2f s", tostring(P.hands_id), now - ph.t0))
                end
            end
        end
        if st.heal and R.ph then
            local ph = R.ph
            if ph.item_name and not ph.item_said then
                ph.item_said = true
                R.say(string.format("  MARK item used: %s at +%.2f s (the game takes it at the END of the animation)", ph.item_name, ph.item_at - ph.t0))
            end
            if ph.item_at and (not ph.last_event_at or ph.item_at > ph.last_event_at) then ph.last_event_at = ph.item_at end
            -- the animation and the gun coming back up have had their time: 6 s after the last sign of the heal
            if ph.last_event_at and now >= ph.last_event_at + 6 then ended = true end
        end
        if ended then
            if R.step < #R.steps then R.begin_step(R.step + 1, now) else R.stop("finished") end
            if not R.on then return end
        end
    end

    if now - R.last_sample < R.SAMPLE_EVERY then return end
    R.last_sample = now
    if not player_object() then R.prev = nil return end
    if now - R.targets_at > 3 then R.refresh_targets(now) end
    local cur, nplain = R.sample()
    local n = 0
    for _ in pairs(cur) do n = n + 1 end
    R.samples = R.samples + 1
    if R.last_n > 0 and n < R.last_n * 0.5 then -- the player object was replaced (a loading screen): start over rather than log everything as changed
        R.prev = nil
        R.last_n = n
        R.refresh_targets(now)
        R.say("  (player objects changed at +" .. string.format("%.1f", R.ph and (now - R.ph.t0) or 0) .. " s: skipped a reading)")
        return
    end
    R.last_n = math.max(R.last_n, n)
    local prev = R.prev
    R.prev = cur
    if not prev then return end
    local changed = {}
    for key, v in pairs(cur) do
        local pv = prev[key]
        if pv ~= nil and R.differs(pv, v) then changed[#changed + 1] = key end
    end
    table.sort(changed)
    for _, key in ipairs(changed) do R.on_change(now, key, prev[key], cur[key]) end
end

function pstat.rec_draw(now)
    if not R.on then return end
    local st = R.steps[R.step]
    if not st then return end
    pcall(draw.text, string.format("RE7MP RECORDER (%s)  step %d/%d", R.mode, R.step, #R.steps), 24, 120, 0xFF3030FF)
    pcall(draw.text, st.text, 24, 140, 0xFF00FFFF)
    pcall(draw.text, string.format("%.0f s left   [F6] %s", math.max(0, R.step_end - now), R.mode == "free" and "mark" or "next step"), 24, 160, 0xFFFFFFFF)
end

-- ---- the learned block signal ----
function R.signal_text()
    local s = R.signal
    if not s then return "none" end
    return s.text or (s.comp .. "." .. table.concat(s.path, "."))
end

function R.signal_component(full, now)
    if R.sig_obj and R.sig_obj_full == full and now - R.sig_obj_at < 3 then return R.sig_obj end
    R.sig_obj_at = now
    R.sig_obj, R.sig_obj_full = nil, full
    for _, c in ipairs(H.player_components()) do
        if c.full == full then
            R.sig_obj = c.obj
            break
        end
    end
    return R.sig_obj
end

-- Is the learned block signal on right now? Read at most ten times a second.
function R.guard_now(now)
    local sig = R.signal
    if not sig then return false end
    if now - R.sig_at < 0.1 then return R.sig_val end
    R.sig_at = now
    local v = R.signal_component(sig.comp, now)
    if v ~= nil then
        for _, name in ipairs(sig.path) do
            local ok, nv = pcall(function() return v:get_field(name) end)
            if not ok or nv == nil then
                v = nil
                break
            end
            v = nv
        end
    end
    if R.is_obj(v) then v = as_text(v) end
    R.sig_raw = v
    R.sig_val = v ~= nil and v == sig.on
    return R.sig_val
end

function pstat.rec_panel()
    local now = os.clock()
    if R.on then
        local st = R.steps[R.step]
        imgui.text(string.format("    RECORDING (%s): step %d/%d  %s", R.mode, R.step, #R.steps, st and st.text or ""))
        if imgui.button("    11. " .. (R.mode == "free" and "Mark now" or "Next step") .. "   [F6]##recnext") then R.key_pressed(now) end
        if imgui.button("    11. Stop and write the report##recstop") then R.stop("stopped from the panel") end
    else
        if imgui.button("11. Record my player, guided (block twice, then use a Herb)") then R.start("guided") end
        if imgui.button("11. Record my player, free (you mark what you do with F6)") then R.start("free") end
        imgui.text("    Only reads fields and writes down what changed: no hooks, so it can't crash the game like tracing can.")
    end
    for i = math.max(1, #R.report - 30), #R.report do imgui.text("    " .. R.report[i]) end
    if R.signal then
        local c, v = imgui.checkbox("    Use the learned block signal for my block pose##recsig", R.use_signal)
        if c then R.use_signal = v end
        imgui.text(string.format("    signal: %s   now: %s", R.signal_text(), R.use_signal and (R.guard_now(now) and "ON" or "off") or "(not used)"))
        if imgui.button("    Forget the learned block signal##recforget") then R.signal, R.use_signal, R.sig_val = nil, false, false end
    end
end
end -- do

----------------------------------------------------------------------------------------------
-- Version check (release 0.7). Each script tells the other which release it is (message kind 8,
-- "v|release|build|exe|protocol") when the other player appears and every 20 s after. A different
-- release is flagged in the panel and the chat. A script older than this feature sends nothing, so
-- "no version after 8 s" means an older release. Also checks that re7mp.exe and this script agree.
----------------------------------------------------------------------------------------------
do
local V = CFG.ver
local VER_MSG = 8
V.remote = nil        -- { release, build, exe, proto, at } from the other player's script
V.summary = nil       -- one line for the panel and the debug file
V.problem = nil       -- text if something is wrong (shown in red)
V.sent_at, V.peer_was, V.seen_at = -100, false, nil

local function mine()
    return string.format("v|%s|%s|%s|%s", CFG.RELEASE, CFG.BUILD, state.exe_version or "?", tostring(state.exe_proto or "?"))
end

net_on(VER_MSG, function(payload)
    local rel, build, exe, proto = payload:match("^v|([%w%.%-]+)|([%w%.%-]+)|([%w%.%-%?]*)|([%w%?]*)$")
    if not rel then return end
    local first = V.remote == nil or V.remote.release ~= rel
    V.remote = { release = rel, build = build, exe = exe, proto = proto, at = os.clock() }
    local who = state.remote_name or CFG.DEFAULT_NAME
    V.summary = string.format("%s runs release v%s (script build %s, re7mp.exe v%s)", who, rel, build, exe)
    if rel ~= CFG.RELEASE then
        V.problem = string.format("%s is on release v%s but you are on v%s: update so you both run the same version", who, rel, CFG.RELEASE)
    else
        V.problem = nil
    end
    if first then
        say("version: " .. V.summary)
        if V.problem then chat_add("Version", V.problem) end
    end
end)

function V.update(now)
    local present = peer_present(now)
    if present and not V.peer_was then V.seen_at, V.intro_due = now, true end
    if not present then V.seen_at, V.intro_due = nil, false end
    V.peer_was = present
    -- (re)introduce ourselves when they appear, and every 20 s (their script may have been reloaded). The first time waits a
    -- moment (at most 2 s) until re7mp.exe's release is known, so the other player is not told "re7mp.exe v?".
    if present and V.intro_due and (state.exe_version or now - V.seen_at >= 2) then
        V.intro_due = false
        V.sent_at = now
        net_send(VER_MSG, mine())
    elseif present and not V.intro_due and now - V.sent_at >= 20 then
        V.sent_at = now
        net_send(VER_MSG, mine())
    end
    -- they never said which version they run: an older script (the loopback bot is not a script)
    local who = state.remote_name or CFG.DEFAULT_NAME
    if present and not V.remote and V.seen_at and now - V.seen_at > 8 and who ~= "Loopback Bot" then
        V.summary = who .. " runs a script older than release v" .. CFG.RELEASE .. " (it reports no version)"
        if not V.problem then
            V.problem = who .. "'s script is older than release v" .. CFG.RELEASE .. ": update so you both run the same version"
            say("version: " .. V.summary)
            chat_add("Version", V.problem)
        end
    end
    -- the exe and this script should be the same release (the exe installs its own copy of the script)
    -- (not latched: the warning goes away as soon as the exe reports the same release, e.g. after it was updated and started)
    if state.exe_version and state.exe_version ~= CFG.RELEASE then
        V.exe_problem = string.format("re7mp.exe is v%s but this script is v%s: use \"Install Lua script\" in the exe, or update both", state.exe_version, CFG.RELEASE)
        if V.exe_warned ~= state.exe_version then
            V.exe_warned = state.exe_version
            say("version: " .. V.exe_problem)
        end
    else
        V.exe_problem, V.exe_warned = nil, nil
    end
end

function V.panel()
    pcall(imgui.text, string.format("Release v%s   (script build %s%s)", CFG.RELEASE, CFG.BUILD,
        state.exe_version and (", re7mp.exe v" .. state.exe_version) or ""))
    local function warn(text)
        if not pcall(imgui.text_colored, text, 0xFF3030FF) then imgui.text(text) end
    end
    if V.exe_problem then warn(V.exe_problem) end
    if V.problem then warn(V.problem)
    elseif V.summary then imgui.text(V.summary) end
end
end -- do

----------------------------------------------------------------------------------------------
-- Co-op saves: re7mp.exe shares saves made while connected (TCP) and lists what it installed in
-- reframework/data/re7mp_coop_saves.json. This reads that file and announces new arrivals.
----------------------------------------------------------------------------------------------
local saves = { enabled = false, last = "", entries = {}, occupied = {}, dir = "", last_read = 0, notified = nil }
CFG.saves = saves

-- Does the game itself say a save exists in this slot (SaveDataManager.isExistData)? true / false / nil when it can't be asked.
-- Asked at most every 2 s: it is one call for each of 60 slots.
function saves.game_sees(slot, now)
    if now - (saves.seen_at or -10) > 2 then
        saves.seen_at = now
        local ok, set = pcall(function() return CFG.lm.game_slots() end)
        saves.seen = ok and set or nil
    end
    if saves.seen == nil then return nil end
    return saves.seen[slot] == true
end

local function read_saves(now)
    saves.last_read = now
    local d = json.load_file("re7mp_coop_saves.json")
    if type(d) ~= "table" then return end
    saves.enabled = d.enabled == true
    local last = tostring(d.last or "")
    if saves.notified == nil then
        saves.notified = last -- the first read is old news
    elseif last ~= saves.notified then
        saves.notified = last
        chat_add("Co-op saves", last)
    end
    saves.last = last
    saves.entries = type(d.entries) == "table" and d.entries or {}
    saves.occupied = type(d.occupied) == "table" and d.occupied or {}
    saves.dir = type(d.dir) == "string" and d.dir or ""
end

----------------------------------------------------------------------------------------------
-- Load screen labels (EXPERIMENTAL; the layout below was read from a real scan, the writing itself is untested in the game).
-- The Load list is a GUI (SystemObject/MenuManager/SaveMenuGUI, component app.SaveMenu) that the game fills in while it
-- runs, so its text can be changed from here. This puts [CO-OP: <name>] in front of the objective text (m_objective) of
-- every co-op save (the ones you sent AND the ones you received; <name> is the other player it was last shared with).
-- Each row of the list shows its slot number in m_number ("1", "2" ... or "Autosave") and the game re-uses nine row
-- controls for all your saves, rewriting them as you scroll, so rows are matched to save files by that number (never
-- by position) and the labels are put back ten times a second. Row N is the file dataNNNSlot.bin (found by looking at a
-- real save folder: the file times match the rows); the "Autosave" row is data000.bin, which is never shared, so it never
-- gets a label. Before writing anything the script asks the game which slots exist (SaveDataManager.isExistData) and
-- compares that with the folder re7mp.exe watches: if they differ, the exe is probably looking at another Steam account's
-- saves and nothing is written. Button 10 records what the screen is made of.
----------------------------------------------------------------------------------------------
do
local LM = CFG.lm
LM.enabled = false
LM.fast_at = -100
LM.status = "Off."
LM.written = 0              -- labels written this session
LM.last_scan, LM.guis_at = -100, -100
LM.guis = {}
LM.api = {}                 -- which GUI method names worked (for the debug file)

-- Calls the first method of `names` that works on obj and returns something.
function LM.try(obj, names)
    for _, n in ipairs(names) do
        local ok, v = pcall(obj.call, obj, n)
        if ok and v ~= nil then
            LM.api[names[1]] = n
            return v
        end
    end
    return nil
end

function LM.kids(ctl)
    local out = {}
    local c = LM.try(ctl, { "get_Child", "get_FirstChild" })
    while c ~= nil and #out < 300 do
        out[#out + 1] = c
        c = LM.try(c, { "get_Next", "get_NextSibling" })
    end
    return out
end

function LM.roots(gui)
    local r
    local view = LM.try(gui, { "get_View" })
    if view then r = LM.try(view, { "get_RootWindow", "get_Root", "get_Window", "get_FirstChild", "get_Child" }) end
    if r == nil then r = LM.try(gui, { "get_RootWindow", "get_Child" }) end
    if r == nil then return {} end
    local out = { r }
    local n = LM.try(r, { "get_Next" })
    while n ~= nil and #out < 20 do
        out[#out + 1] = n
        n = LM.try(n, { "get_Next" })
    end
    return out
end

-- Every control under the GUI as a flat list: { ctl, name, type, depth, parent (index), visible, text (Text controls only) }.
function LM.walk(gui, limit)
    local nodes = {}
    local function visit(ctl, depth, parent)
        if #nodes >= limit or depth > 14 then return end
        local okt, tn = pcall(function() return ctl:get_type_definition():get_full_name() end)
        local node = { ctl = ctl, name = as_text(LM.try(ctl, { "get_Name" })) or "", type = okt and tn or "?",
            depth = depth, parent = parent }
        if node.type:find("^via%.gui%.Text") then node.text = as_text(LM.try(ctl, { "get_Message" })) or "" end
        node.visible = LM.try(ctl, { "get_Visible" }) ~= false
        nodes[#nodes + 1] = node
        local idx = #nodes
        for _, k in ipairs(LM.kids(ctl)) do visit(k, depth + 1, idx) end
    end
    for _, r in ipairs(LM.roots(gui)) do visit(r, 0, 0) end
    return nodes
end

function LM.go_path(go)
    local names = {}
    pcall(function()
        names[1] = tostring(go:call("get_Name"))
        local xf = go:call("get_Transform")
        for _ = 1, 6 do
            xf = xf and xf:call("get_Parent")
            if not xf then break end
            table.insert(names, 1, tostring(xf:call("get_GameObject"):call("get_Name")))
        end
    end)
    return table.concat(names, "/")
end

-- Every via.gui.GUI component in the scene: { gui, path, comps }. findComponents is a single native call; the slow
-- walk of the whole scene is only the fallback for the manual scan (button 10).
function LM.all_guis(allow_slow)
    local out = {}
    local function add(c)
        local okg, go = pcall(c.call, c, "get_GameObject")
        if not okg or not go then return end
        local comps = {}
        pcall(function()
            for _, cc in ipairs(go:call("get_Components"):get_elements()) do
                comps[#comps + 1] = cc:get_type_definition():get_full_name()
            end
        end)
        out[#out + 1] = { gui = c, path = LM.go_path(go), comps = comps }
    end
    local scene = scene_object()
    if not scene then return out, "no scene" end
    for _, method in ipairs({ "findComponents(System.Type)", "findComponents" }) do
        local ok, arr = pcall(function() return scene:call(method, sdk.typeof("via.gui.GUI")) end)
        if ok and arr then
            local oke, elems = pcall(function() return arr:get_elements() end)
            if oke then
                for _, c in ipairs(elems) do add(c) end
                return out, "scene:" .. method
            end
        end
    end
    if not allow_slow then return out, "findComponents failed" end
    pcall(each_gameobject, function(go)
        local okc, comps = pcall(function() return go:call("get_Components"):get_elements() end)
        if not okc then return end
        for _, c in ipairs(comps) do
            local okt, tn = pcall(function() return c:get_type_definition():get_full_name() end)
            if okt and tn == "via.gui.GUI" then add(c) end
        end
    end, 20000)
    return out, "walked the scene"
end

function LM.looks_like_save_screen(g)
    local low = g.path:lower() .. " " .. table.concat(g.comps, " "):lower()
    return low:find("save", 1, true) ~= nil or low:find("load", 1, true) ~= nil or low:find("slot", 1, true) ~= nil
end

-- Finds the list: the control whose children are the most rows of one identical shape. A row's shape is its type
-- plus the name and type of everything below it; the row's own name is left out because the game numbers them
-- (item1, item2 ...). Returns { parent, rows = {node index...}, texts = {row -> text node indexes},
-- number = {row -> the text node with the slot number}, goal = {row -> the objective text node} }.
function LM.find_rows(nodes)
    local kids = {}
    for i, n in ipairs(nodes) do
        if n.parent > 0 then
            kids[n.parent] = kids[n.parent] or {}
            table.insert(kids[n.parent], i)
        end
    end
    local function shape(i)
        local parts = { nodes[i].type }
        local function go(j)
            parts[#parts + 1] = nodes[j].name .. ":" .. nodes[j].type
            for _, c in ipairs(kids[j] or {}) do go(c) end
        end
        for _, c in ipairs(kids[i] or {}) do go(c) end
        return table.concat(parts, ",")
    end
    local function texts(i, acc)
        local n = nodes[i]
        if n.text and n.text ~= "" and n.visible then acc[#acc + 1] = i end
        for _, c in ipairs(kids[i] or {}) do texts(c, acc) end
        return acc
    end
    -- the first node below row i whose name contains `word` (and is a text)
    local function named(i, word)
        local n = nodes[i]
        if n.text and n.name:lower():find(word, 1, true) then return i end
        for _, c in ipairs(kids[i] or {}) do
            local f = named(c, word)
            if f then return f end
        end
        return nil
    end
    local best
    for parent, ks in pairs(kids) do
        local groups = {}
        for _, c in ipairs(ks) do
            local sh = shape(c)
            groups[sh] = groups[sh] or {}
            table.insert(groups[sh], c)
        end
        for _, g in pairs(groups) do
            if #g >= 2 then
                local tx, any, numbered = {}, false, 0
                local number, goal = {}, {}
                for _, r in ipairs(g) do
                    tx[r] = texts(r, {})
                    if #tx[r] > 0 then any = true end
                    number[r], goal[r] = named(r, "number"), named(r, "objective")
                    if number[r] then numbered = numbered + 1 end
                end
                local score = #g + (numbered > 0 and 1000 or 0)
                if any and (not best or score > best.score or (score == best.score and parent < best.parent)) then
                    best = { parent = parent, rows = g, texts = tx, number = number, goal = goal, score = score }
                end
            end
        end
    end
    return best
end

local function tag_of(e)
    if type(e.tag) == "string" and e.tag ~= "" then return e.tag end
    -- (9.12) a save you made and sent says so: his name is never written on a save that is not his
    if e.role == "sent" then return "[CO-OP: sent to " .. tostring(e.partner or e.from or "Player") .. "]" end
    return "[CO-OP: " .. tostring(e.partner or e.from or "Player") .. "]"
end

-- The slot number the game prints on a row, or nil ("Autosave", empty, anything that is not a plain number).
function LM.row_number(text)
    return tonumber((text or ""):match("^%s*(%d+)%s*$"))
end

-- The manual slots the game itself says exist (SaveDataManager.isExistData: true for 0 = the Autosave and for each manual
-- save). Returns a set {slot = true} and a sorted list, or nil if the game can't be asked.
function LM.game_slots()
    local okm, sm = pcall(sdk.get_managed_singleton, "app.SaveDataManager")
    if not okm or not sm then return nil end
    local set, list, asked = {}, {}, false
    for i = 0, 60 do
        local ok, v = pcall(function() return sm:call("isExistData", i) end)
        if ok and v ~= nil then asked = true end
        if ok and v == true and i >= 1 then
            set[i] = true
            list[#list + 1] = i
        end
    end
    if not asked then return nil end
    return set, list
end

-- {1,2,3,5,6} -> "1-3, 5-6"
function LM.fmt_slots(list)
    if #list == 0 then return "none" end
    local parts, i = {}, 1
    while i <= #list do
        local j = i
        while list[j + 1] == list[j] + 1 do j = j + 1 end
        parts[#parts + 1] = (j > i) and (list[i] .. "-" .. list[j]) or tostring(list[i])
        i = j + 1
    end
    return table.concat(parts, ", ")
end

local function sorted_keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- The folder re7mp.exe watches should hold exactly the saves the game lists. One slot of difference is a save that was
-- just made (or just received) and not yet seen by the other side; more than that means another Steam account's folder.
-- Returns true and a note, or false and the message for the panel.
function LM.slot_check(game_set, exe_set)
    local only_game, only_exe = {}, {}
    for s in pairs(game_set) do if not exe_set[s] then only_game[#only_game + 1] = s end end
    for s in pairs(exe_set) do if not game_set[s] then only_exe[#only_exe + 1] = s end end
    table.sort(only_game)
    table.sort(only_exe)
    local diff = #only_game + #only_exe
    if diff == 0 then return true, "the game's saves match re7mp.exe's" end
    if diff == 1 then return true, "a save was just added or removed; re7mp.exe will catch up" end
    local who = (saves.dir or ""):match("userdata[/\\]([^/\\]+)")
    return false, string.format("The game has saves in slots %s but re7mp.exe is watching a folder with slots %s%s. That is probably another Steam account's folder: set 'Save folder' in re7mp.exe to the one for the account you play on (press Detect, or pick the folder by hand).",
        LM.fmt_slots(sorted_keys(game_set)), LM.fmt_slots(sorted_keys(exe_set)), who and (" (Steam account " .. who .. ")") or "")
end

-- Writes (or removes) the tag on one row. rec = { num = control with the slot number, goal = control with the objective }.
-- Returns true if it changed the text.
function LM.apply_row(rec, by_slot)
    local num_text = rec.num and as_text(LM.try(rec.num, { "get_Message" }))
    local cur = as_text(LM.try(rec.goal, { "get_Message" }))
    if cur == nil then return false end
    local n = LM.row_number(num_text)
    local e = n and by_slot[n]
    local plain = cur:match("^%[CO%-OP: [^%]]*%] (.*)$") or cur
    local want = e and (tag_of(e) .. " " .. plain) or plain
    if want == cur then return false end
    if pcall(rec.goal.call, rec.goal, "set_Message", want) then
        if e then LM.written = LM.written + 1 end
        return true
    end
    return false
end

-- Labels the rows of a freshly scanned list and remembers their controls so the next checks are cheap.
-- Returns true if the rows could be matched to save slots.
function LM.label_rows(nodes, best, by_slot)
    local occ_set, n_occ = {}, 0
    for _, s in ipairs(saves.occupied or {}) do
        if tonumber(s) then occ_set[math.floor(tonumber(s))] = true n_occ = n_occ + 1 end
    end
    if n_occ == 0 then
        LM.cache = nil
        LM.status = "The exe has not listed the save files yet (re7mp.exe needs 'Share saves' ticked)."
        return false
    end
    local recs, has_number = {}, false
    for _, row in ipairs(best.rows) do
        local ni, gi = best.number[row], best.goal[row]
        if not gi then -- no field called objective: the longest visible text of the row
            for _, ti in ipairs(best.texts[row]) do
                if not gi or #nodes[ti].text > #nodes[gi].text then gi = ti end
            end
        end
        if ni then has_number = true end
        if gi then
            recs[#recs + 1] = { num = ni and nodes[ni].ctl or nil, goal = nodes[gi].ctl }
        end
    end
    if not has_number then
        LM.cache = nil
        LM.status = "The list rows don't show a slot number, so I can't tell which row is which save: nothing labelled. Press button 10 and send me the file."
        return false
    end
    local note = "row N is dataNNNSlot.bin"
    local game_set = LM.game_slots()
    if game_set then
        local ok, why = LM.slot_check(game_set, occ_set)
        if not ok then
            LM.cache = nil
            LM.status = why .. " Nothing labelled."
            return false
        end
        note = note .. "; " .. why
    else
        note = note .. "; the game could not be asked which saves exist, so this is not checked"
    end
    LM.cache = { recs = recs, by_slot = by_slot, note = note, at = os.clock() }
    local wrote = 0
    for _, rec in ipairs(recs) do
        if LM.apply_row(rec, by_slot) then wrote = wrote + 1 end
    end
    LM.status = string.format("Load list found: %d rows, %s. %d label(s) written so far.", #recs, note, LM.written)
    return true
end

-- Between full scans: only the rows already found are looked at, ten times a second. The game rewrites a row's
-- text whenever the list scrolls (it re-uses nine row controls for all your saves), so the labels are put back at once.
function LM.refresh()
    local c = LM.cache
    if not c then return end
    for _, rec in ipairs(c.recs) do LM.apply_row(rec, c.by_slot) end
    LM.status = string.format("Load list found: %d rows, %s. %d label(s) written so far.", #c.recs, c.note, LM.written)
end

-- Is the GUI showing? (A closed menu is not walked: walking a hundred controls is a few thousand calls.)
function LM.is_open(gui)
    for _, r in ipairs(LM.roots(gui)) do
        if LM.try(r, { "get_Visible" }) ~= false then return true end
    end
    return false
end

function LM.update(now)
    if not LM.enabled then return end
    if LM.cache and now - LM.cache.at < 3 then -- a list was found a moment ago: just keep its labels in place
        if now - LM.fast_at < 0.1 then return end
        LM.fast_at = now
        if not pcall(LM.refresh) then LM.cache, LM.last_scan = nil, -100 end
        return
    end
    if now - LM.last_scan < 0.5 then return end
    LM.last_scan = now
    local by_slot, n = {}, 0
    for _, e in ipairs(saves.entries) do
        local slot = type(e) == "table" and tonumber(e.slot)
        if slot then
            by_slot[math.floor(slot)] = e
            n = n + 1
        end
    end
    if n == 0 then
        LM.cache = nil
        LM.status = "No co-op saves yet: nothing to label."
        return
    end
    if #LM.guis == 0 and now - LM.guis_at >= 5 then -- finding the GUIs is the costly part: once, then again only if none was found
        LM.guis_at = now
        local all, how = LM.all_guis(false)
        LM.how = how
        for _, g in ipairs(all) do
            if LM.looks_like_save_screen(g) then LM.guis[#LM.guis + 1] = g end
        end
    end
    if #LM.guis == 0 then
        if LM.how and LM.how:find("^scene:") then
            LM.status = "Waiting: no save/load screen is open."
        else
            LM.status = "Can't list the game's GUIs from here (" .. tostring(LM.how) .. "). Press button 10 and send me the file."
        end
        return
    end
    local unmatched = false
    for _, g in ipairs(LM.guis) do
        local ok, found = pcall(function()
            if not LM.is_open(g.gui) then return nil end
            local nodes = LM.walk(g.gui, 1500)
            local best = LM.find_rows(nodes)
            if not best then return nil end
            return LM.label_rows(nodes, best, by_slot) and "labelled" or "unmatched"
        end)
        if not ok then
            LM.guis, LM.guis_at, LM.cache = {}, -100, nil -- that GUI is gone; look again next time
            LM.status = "Waiting: the save/load screen went away."
            return
        end
        if found == "labelled" then return end
        if found == "unmatched" then unmatched = true end -- a list was found but not matched: label_rows said why
    end
    if not unmatched then
        LM.cache = nil
        LM.status = "Waiting: no save/load screen is open (open the Load Game screen; if it is open and nothing happens, press button 10 and send me the file)."
    end
end

-- Types behind the Load screen: app.SaveMenu is the component on SaveMenuGUI. (The game's own save code, app.SaveDataManager,
-- was listed by the first scans; its slot numbers are plain integers, see LM.game_slots.)
LM.TYPES = { "app.SaveMenu" }

function LM.list_type(name)
    local td = sdk.find_type_definition(name)
    if not td then
        say(name .. ": not found")
        return
    end
    say(name .. ": found")
    local n = 0
    for _, m in ipairs(td:get_methods() or {}) do
        n = n + 1
        if n <= 120 then say("    " .. m:get_name() .. method_signature(m)) end
    end
    local f = 0
    for _, fd in ipairs(td:get_fields() or {}) do
        f = f + 1
        if f <= 60 then
            local okf, line = pcall(function() return fd:get_name() .. " : " .. fd:get_type():get_full_name() end)
            say("    field " .. (okf and line or "?"))
        end
    end
end

-- Button 10: open the Load screen first, then press this.
function LM.dump()
    pinned(function()
        say("=== load screen scan ===")
        local occ = saves.occupied or {}
        say("manual saves in the folder re7mp.exe watches (dataNNNSlot.bin): " .. (#occ > 0 and table.concat(occ, ", ") or "none listed"))
        say("that folder: " .. ((saves.dir or "") ~= "" and saves.dir or "(not reported: update re7mp.exe)"))
        do
            local gset, glist = LM.game_slots()
            if gset then
                say("manual saves the game says exist (SaveDataManager.isExistData): " .. table.concat(glist, ", "))
                local exe_set = {}
                for _, x in ipairs(occ) do if tonumber(x) then exe_set[math.floor(tonumber(x))] = true end end
                local ok, why = LM.slot_check(gset, exe_set)
                say((ok and "check: " or "MISMATCH: ") .. why)
            else
                say("the game could not be asked which saves exist")
            end
        end
        for _, e in ipairs(saves.entries) do
            if type(e) == "table" then say(string.format("co-op slot %s  %s  %s", tostring(e.slot), tostring(e.role), tag_of(e))) end
        end
        local guis, how = LM.all_guis(true)
        say(string.format("%d via.gui.GUI components (%s)", #guis, how))
        for _, g in ipairs(guis) do
            say(string.format("  %s   [%s]%s", g.path, table.concat(g.comps, ", "), LM.looks_like_save_screen(g) and "   <- looks like a save/load screen" or ""))
        end
        for _, g in ipairs(guis) do
            if LM.looks_like_save_screen(g) then
                local ok, err = pcall(function()
                    local nodes = LM.walk(g.gui, 600)
                    say(string.format("controls of %s (%d shown):", g.path, #nodes))
                    for _, n in ipairs(nodes) do
                        say(string.format("%s%s : %s%s%s", string.rep("  ", n.depth + 1), n.name, n.type, n.visible and "" or " (hidden)",
                            n.text and ('  "' .. n.text:sub(1, 80) .. '"') or ""))
                    end
                    local best = LM.find_rows(nodes)
                    if best then
                        say(string.format("-> list found: %d identical rows under node %d (%s)", #best.rows, best.parent, nodes[best.parent].name))
                        local occ_set = {}
                        for _, s in ipairs(occ) do occ_set[math.floor(tonumber(s) or -1)] = true end
                        local by_slot = {}
                        for _, e in ipairs(saves.entries) do
                            if type(e) == "table" and tonumber(e.slot) then by_slot[math.floor(tonumber(e.slot))] = e end
                        end
                        for _, row in ipairs(best.rows) do
                            local ni, gi = best.number[row], best.goal[row]
                            local numtxt = ni and nodes[ni].text or "?"
                            local k = LM.row_number(numtxt)
                            local file
                            if k then
                                file = string.format("data%03dSlot.bin", k)
                            elseif numtxt == "Autosave" then
                                file = "data000.bin (the Autosave: never shared, never labelled)"
                            else
                                file = "no file"
                            end
                            say(string.format("   row %s%s: number \"%s\" -> %s%s   \"%s\"", nodes[row].name, nodes[row].visible and "" or " (hidden)",
                                numtxt, file,
                                (k and by_slot[k]) and ("  CO-OP " .. tag_of(by_slot[k])) or (k and occ_set[k] and "  single-player" or ""),
                                gi and nodes[gi].text:gsub("^%[CO%-OP: [^%]]*%] ", ""):sub(1, 40) or ""))
                        end
                    else
                        say("-> no list of identical rows found")
                    end
                end)
                if not ok then say("scan error: " .. tostring(err)) end
            end
        end
        local api = {}
        for k, v in pairs(LM.api) do api[#api + 1] = k .. " -> " .. v end
        table.sort(api)
        say("GUI methods that worked: " .. (#api > 0 and table.concat(api, "; ") or "none"))
        say("=== candidate types ===")
        for _, n in ipairs(LM.TYPES) do pcall(LM.list_type, n) end
        local okm, sm = pcall(sdk.get_managed_singleton, "app.SaveDataManager")
        if okm and sm then
            local have = {}
            for i = 0, 40 do
                local oke, v = pcall(function() return sm:call("isExistData", i) end)
                if oke and v == true then have[#have + 1] = i end
            end
            say("SaveDataManager.isExistData(n) is true for n = " .. (#have > 0 and table.concat(have, ", ") or "(none)"))
            say("app.SaveDataManager (singleton):")
            dump_fields(sm, "      ", 40)
        end
        say("=== load screen scan done ===")
    end)
end

function LM.panel()
    local c1, v1 = imgui.checkbox("Label co-op saves in the Load screen (experimental)", LM.enabled)
    if c1 then LM.enabled = v1 LM.last_scan, LM.cache = -100, nil if not v1 then LM.status = "Off." end end
    imgui.text(LM.status)
    if imgui.button("Scan the Load screen (open it first, then press)") then LM.dump() end
end
end -- do

----------------------------------------------------------------------------------------------
-- Settings: remembered in reframework/data/re7mp_settings.json
----------------------------------------------------------------------------------------------
local settings_saved_key, settings_last_check = nil, 0

local function settings_snapshot()
    return {
        death_mode = death.mode, item_sync = items.enabled, auto_hide = state.auto_hide,
        show_body = state.show_body, show_skeleton = state.show_skeleton, freeze_instead = lobby.freeze_instead,
        auto_join = lobby.auto_join, auto_start = lobby.auto_start,
        enemy_mode = enemy.mode, enemy_drive_ai = enemy.drive_ai,
        drop_on_discard = give.drop_on_discard, give_hint = give.hint,
        hide_near = math.floor(CFG.HIDE_NEAR_DISTANCE * 100 + 0.5) / 100, show_parked = enemy.show_parked,
        revive_radius = math.floor(pstat.revive_radius * 10 + 0.5) / 10, revive_pct = pstat.revive_pct,
        revive_hold = math.floor(pstat.revive_hold * 2 + 0.5) / 2,
        label_loadmenu = CFG.lm.enabled,
        guard_signal = pstat.rec and pstat.rec.signal or nil, use_guard_signal = pstat.rec and pstat.rec.use_signal or false,
        occlude = state.occlude, menu_hide = state.menu_hide,
        weapon_lock = pstat.lock and pstat.lock.on, lock_hook = pstat.lock and pstat.lock.hooks.on,
        lock_guns = pstat.lock and pstat.lock.guns.on, lock_move = pstat.lock and pstat.lock.move.on,
        hit_on = enemy.hit.on, hit_accept = enemy.hit.accept, hit_damage = enemy.hit.damage, shot_signal = enemy.hit.signal,
    }
end

local function settings_key(t)
    return table.concat({ tostring(t.death_mode), tostring(t.item_sync), tostring(t.auto_hide), tostring(t.show_body),
        tostring(t.show_skeleton), tostring(t.freeze_instead), tostring(t.auto_join), tostring(t.auto_start),
        tostring(t.enemy_mode), tostring(t.enemy_drive_ai), tostring(t.drop_on_discard), tostring(t.give_hint),
        tostring(t.hide_near), tostring(t.show_parked), tostring(t.revive_radius), tostring(t.revive_pct), tostring(t.revive_hold),
        tostring(t.label_loadmenu), pstat.rec and pstat.rec.signal_text() or "", tostring(t.use_guard_signal),
        tostring(t.occlude), tostring(t.menu_hide), tostring(t.weapon_lock), tostring(t.lock_hook), tostring(t.lock_guns), tostring(t.lock_move), tostring(t.hit_on), tostring(t.hit_accept),
        tostring(t.hit_damage), t.shot_signal and (tostring(t.shot_signal.type) .. "." .. tostring(t.shot_signal.field)) or "" }, "|")
end

local function load_settings()
    local d = json.load_file(FILES.SETTINGS_FILE)
    if type(d) ~= "table" then return end
    if type(d.death_mode) == "number" and d.death_mode >= 1 and d.death_mode <= #DEATH_MODES then
        death.mode = math.floor(d.death_mode)
    end
    if type(d.item_sync) == "boolean" then items.enabled = d.item_sync end
    if type(d.auto_hide) == "boolean" then state.auto_hide = d.auto_hide end
    if type(d.show_body) == "boolean" then state.show_body = d.show_body end
    if type(d.show_skeleton) == "boolean" then state.show_skeleton = d.show_skeleton end
    if type(d.freeze_instead) == "boolean" then lobby.freeze_instead = d.freeze_instead end
    if type(d.auto_join) == "boolean" then lobby.auto_join = d.auto_join end
    if type(d.auto_start) == "boolean" then lobby.auto_start = d.auto_start end
    if type(d.enemy_mode) == "number" and d.enemy_mode >= 1 and d.enemy_mode <= #ENEMY_MODES then
        enemy.mode = math.floor(d.enemy_mode)
        if enemy.mode == 3 then enemy.mode = 2 end -- the experimental mode is never switched on by itself
    end
    if type(d.enemy_drive_ai) == "boolean" then enemy.drive_ai = d.enemy_drive_ai end
    if type(d.drop_on_discard) == "boolean" then give.drop_on_discard = d.drop_on_discard end
    if type(d.give_hint) == "boolean" then give.hint = d.give_hint end
    if type(d.hide_near) == "number" and d.hide_near >= 0.05 and d.hide_near <= 3 then CFG.HIDE_NEAR_DISTANCE = d.hide_near end
    if type(d.show_parked) == "boolean" then enemy.show_parked = d.show_parked end
    -- (9.14: the default went from 4 m to 3 m; a saved 4.0 is the old default, not a choice, so it is not kept)
    if type(d.revive_radius) == "number" and d.revive_radius >= 1 and d.revive_radius <= 10 and d.revive_radius ~= 4 then pstat.revive_radius = d.revive_radius end
    if type(d.revive_hold) == "number" and d.revive_hold >= 1 and d.revive_hold <= 10 then pstat.revive_hold = d.revive_hold end
    if type(d.revive_pct) == "number" and d.revive_pct >= 5 and d.revive_pct <= 100 then pstat.revive_pct = math.floor(d.revive_pct) end
    if type(d.label_loadmenu) == "boolean" then CFG.lm.enabled = d.label_loadmenu end
    if type(d.occlude) == "boolean" then state.occlude = d.occlude end
    if type(d.menu_hide) == "boolean" then state.menu_hide = d.menu_hide end
    if pstat.lock and type(d.weapon_lock) == "boolean" then pstat.lock.on = d.weapon_lock end
    if pstat.lock and type(d.lock_hook) == "boolean" then pstat.lock.hooks.on = d.lock_hook end
    if pstat.lock and type(d.lock_guns) == "boolean" then pstat.lock.guns.on = d.lock_guns end
    if pstat.lock and type(d.lock_move) == "boolean" then pstat.lock.move.on = d.lock_move end
    if type(d.hit_on) == "boolean" then enemy.hit.on = d.hit_on end
    if type(d.hit_accept) == "boolean" then enemy.hit.accept = d.hit_accept end
    if type(d.hit_damage) == "number" and d.hit_damage >= 1 and d.hit_damage <= 500 then enemy.hit.damage = math.floor(d.hit_damage) end
    local ss = d.shot_signal
    if type(ss) == "table" and type(ss.type) == "string" and type(ss.field) == "string" and ss.type:match("^[%w_%.]+$") and #ss.field < 100 then
        enemy.hit.signal = { type = ss.type, field = ss.field }
    end
    -- the block signal button 11 learned (checked field by field: a damaged file must not break the script)
    local gs = d.guard_signal
    if type(gs) == "table" and type(gs.comp) == "string" and type(gs.path) == "table" and #gs.path >= 1 and #gs.path <= 3 then
        local okp = true
        for _, n in ipairs(gs.path) do if type(n) ~= "string" or n == "" then okp = false end end
        local tg = type(gs.on)
        if okp and (tg == "boolean" or tg == "number" or tg == "string") then
            pstat.rec.signal = { comp = gs.comp, path = gs.path, on = gs.on, off = gs.off, text = type(gs.text) == "string" and gs.text or nil }
            -- 9.8: a learned signal is only an optional extra now. A 9.7 settings file may have it switched ON with a bad pick
            -- (isBothHands also fires while healing), so it always starts off and the player ticks it if they want it.
            pstat.rec.use_signal = false
        end
    end
end

local function save_settings_if_changed(now)
    if now - settings_last_check < 1 then return end
    settings_last_check = now
    local snap = settings_snapshot()
    local key = settings_key(snap)
    if key ~= settings_saved_key then
        settings_saved_key = key
        pcall(json.dump_file, FILES.SETTINGS_FILE, snap)
    end
end

----------------------------------------------------------------------------------------------
-- Game menus (9.9, experimental). The stand-in is drawn over the game's own screens (inventory, pause, map ...). This keeps a
-- list of the game's GUI objects (found by the same call the Load screen labels use), checks a few of them every frame
-- whether they are showing, and says "a menu is open" when a GUI that has been seen HIDDEN at some point (so it is not part of
-- the always-on HUD) is showing and its name looks like a menu. The names are guesses until a file shows the real ones: the
-- debug file lists every GUI it watches with what it saw, and the panel names the one that hid the stand-in.
----------------------------------------------------------------------------------------------
CFG.menu = { guis = {}, by_path = {}, list_at = -100, scan_i = 1, open = false, which = nil, open_since = 0, clear_at = 0,
    how = "-", polls = 0, listings = 0, errors = 0, hidden_frames = 0, shown_now = false, ignored = {}, fast = {}, fast_at = 0,
    -- (9.11) the real menus, from the first debug file that listed the game's GUIs (the last part of the path, lower case).
    -- A name like "MapMaskGUI" is NOT a menu: after the tape it stayed "showing" for good and hid the other player for minutes.
    KNOWN = { inventorymenu = true, pausemenugui = true, quickequipmenu = true, savemenugui = true, filemenu = true,
        detailsearchgui = true, gui_menu = true, gui_option = true, ui5000 = true, ui5001 = true, objectivegui = true,
        tutorialgui = true, difficultyselectgui = true, titlescreen = true, choicemenu = true, optionmenu = true,
        optionkeybind = true, multisubmenu = true, videocameraui = true },
    STAY = { videocameraui = true }, -- the tape player may stay up while you walk about in the tape (see update)
    WORDS = { "inventory", "pause", "option", "config", "notes", "memo", "itembox", "item_box", "save", "load", "gameover", "result",
        "document", "tutorial", "help", "photo", "title", "combine", "detailsearch", "quickequip" },
    SKIP = { "mask", "fade", "movie", "logo", "cursor", "icon", "guide", "keyhelp", "reticle", "crosshair", "hud", "subtitle",
        "caption", "telop", "prompt", "interact", "pickup", "pick_up", "damage", "bullet", "ammo", "life", "health", "messagelabel",
        "genomecodex", "dummy", "weaponinfo", "loading", "staffroll", "porting", "onsale", "userid", "tips", "processing", "adjust" } }

function CFG.menu.looks_like_menu(path)
    local M = CFG.menu
    local low = path:lower()
    local last = low:match("([^/]+)$") or low
    if M.KNOWN[last] then return true end
    for _, w in ipairs(M.SKIP) do
        if low:find(w, 1, true) then return false end
    end
    for _, w in ipairs(M.WORDS) do
        if last:find(w, 1, true) then return true end
    end
    return false
end

function CFG.menu.poll(rec)
    local M = CFG.menu
    local ok, vis = pcall(CFG.lm.is_open, rec.gui)
    M.polls = M.polls + 1
    if ok then
        rec.vis = vis == true
        if rec.vis then rec.ever_visible = true else rec.ever_hidden = true end
    else
        M.errors = M.errors + 1
        rec.vis = false
    end
end

function CFG.menu.update(now)
    local M = CFG.menu
    -- (9.11) watched whenever the other player is there, also with the "hide them" box unticked: the heal pose needs to know
    -- whether the inventory is open (the hide itself still follows the box, see state.overlay_hidden)
    if not state.remote then
        M.open, M.which, M.shown_now = false, nil, false
        return
    end
    if now - M.list_at > (#M.guis == 0 and 5 or 20) then -- finding the GUIs is the costly part: now and then
        M.list_at = now
        M.listings = M.listings + 1
        local all, how = CFG.lm.all_guis(false)
        M.how = how
        local list, fast = {}, {}
        for _, g in ipairs(all) do
            local rec = M.by_path[g.path]
            if rec == nil then
                rec = { path = g.path, vis = nil, ever_hidden = false, ever_visible = false, menu = CFG.menu.looks_like_menu(g.path) }
                M.by_path[g.path] = rec
            end
            rec.gui = g.gui
            list[#list + 1] = rec
            if rec.menu and M.KNOWN[(g.path:lower():match("([^/]+)$") or "")] then fast[#fast + 1] = rec end
        end
        M.guis, M.fast = list, fast
        if M.scan_i > #M.guis then M.scan_i = 1 end
    end
    local n = #M.guis
    if n == 0 then return end
    for _ = 1, math.min(6, n) do -- a few GUIs per frame, round and round
        local rec = M.guis[M.scan_i]
        M.scan_i = M.scan_i % n + 1
        M.poll(rec)
    end
    if now - M.fast_at >= 0.05 then -- the real menus: twenty times a second
        M.fast_at = now
        for _, rec in ipairs(M.fast) do M.poll(rec) end
    end
    local found, which, wrec = false, nil, nil
    for _, rec in ipairs(M.guis) do
        if rec.vis and rec.ever_hidden and rec.menu and not rec.ignore then
            found, which, wrec = true, rec.path, rec
            break
        end
    end
    M.shown_now = found
    if found then
        local lp = state.local_pos
        if not M.open then
            M.open_since = now
            M.open_pos = lp and { x = lp.x, y = lp.y, z = lp.z } or nil
        end
        M.open, M.which, M.clear_at = true, which, now + 0.5
        -- (9.11) a game menu stops the game. If you have walked 3 m while one has been "open" for 6 s, it is not a menu
        -- (that was MapMaskGUI): it is ignored from now on.
        if lp and M.open_pos and now - M.open_since > 6 and not M.STAY[(which:lower():match("([^/]+)$") or "")] then
            local dx, dy, dz = lp.x - M.open_pos.x, lp.y - M.open_pos.y, lp.z - M.open_pos.z
            if dx * dx + dy * dy + dz * dz > 9 then
                wrec.ignore = true
                M.ignored[#M.ignored + 1] = which
                M.open, M.which, M.shown_now = false, nil, false
                say("menu: " .. which .. " is not a menu (you walked " .. string.format("%.0f", math.sqrt(dx * dx + dy * dy + dz * dz))
                    .. " m while it was showing): ignored from now on")
            end
        end
    elseif M.open and now > M.clear_at then
        M.open, M.which = false, nil
    end
    if M.open then M.hidden_frames = M.hidden_frames + 1 end
end

function CFG.menu.report()
    local M = CFG.menu
    local rows = {}
    for path, rec in pairs(M.by_path) do
        rows[#rows + 1] = { path = path, showing = rec.vis, seen_hidden = rec.ever_hidden, seen_showing = rec.ever_visible,
            counts_as_menu = rec.menu and not rec.ignore }
    end
    table.sort(rows, function(a, b) return a.path < b.path end)
    while #rows > 120 do table.remove(rows) end
    return { enabled = state.menu_hide, open_now = M.open, because_of = M.which, found_by = M.how, listings = M.listings,
        polls = M.polls, errors = M.errors, frames_hidden = M.hidden_frames, ignored_as_not_menus = M.ignored, guis_watched = rows }
end

----------------------------------------------------------------------------------------------
-- Main loop and UI
----------------------------------------------------------------------------------------------
load_settings()
pcall(tracer.report_previous)
settings_saved_key = settings_key(settings_snapshot())
prime_messages()
items.hooked = select(2, pcall(install_item_hooks)) == true
give.hooked = select(2, pcall(install_give_hooks)) == true
pcall(pstat.install)
pcall(RE7.install_death_extras)
local ok_hook, installed = pcall(RE7.install_new_game_hook, on_local_new_game)
lobby.hook_installed = ok_hook and installed == true

-- Never leave the game frozen if the scripts are reloaded while we're holding it.
if re.on_script_reset then re.on_script_reset(function() release_game() remove_clone() pcall(enemy_release_all) tracer.crumb("clean", "scripts reset") end) end

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
    if now - saves.last_read >= 1 then pcall(read_saves, now) end
    pcall(CFG.lm.update, now)
    save_settings_if_changed(now)
    update_remote(now, dt)
    pcall(CFG.menu.update, now)
    update_lobby(now)
    update_avatar()
    local oke, erre = pcall(function()
        enemy_host_update(now)
        enemy_update(now, dt)
        give_update(now)
        enemy.hit.update(now)
    end)
    if not oke and now - (state.enemy_err_at or 0) > 5 then
        state.enemy_err_at = now
        say("enemy/item update error: " .. tostring(erre))
    end
    pcall(CFG.ver.update, now)
    local okp, errp = pcall(pstat.update, now) -- on its own: an enemy error must not stop the health module, nor the reverse
    if not okp and now - (state.health_err_at or 0) > 5 then
        state.health_err_at = now
        say("health update error: " .. tostring(errp))
    end

    local okl, errl = pcall(pstat.lock_update, now) -- (9.8) the downed player's weapon lock; its own pcall for the same reason
    if not okl and now - (state.lock_err_at or 0) > 5 then
        state.lock_err_at = now
        say("weapon lock error: " .. tostring(errl))
    end

    local ok, err = pcall(draw_remote, now)
    if not ok then state.last_error = tostring(err) end
    local okr, errr = pcall(pstat.rec_update, now) -- button 11's recorder (reads only; nothing hooked)
    if not okr and now - (state.rec_err_at or 0) > 5 then
        state.rec_err_at = now
        say("recorder error: " .. tostring(errr))
    end
    pcall(pstat.rec_draw, now)
    pcall(draw_hud, now)
    pcall(pstat.draw, now)
    pcall(draw_enemies, now)
    pcall(enemy.hit.draw, now)
    pcall(draw_give_hint, now)

    if lobby.phase ~= "idle" or now < lobby.message_until then
        pcall(draw.text, lobby.message, 24, 24, 0xFF00FFFF)
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("RE7 Multiplayer v" .. CFG.RELEASE) then return end
    pcall(CFG.ver.panel)

    local changed, v = imgui.checkbox("Show other player", state.show_figure)
    if changed then state.show_figure = v end
    local cb, vb = imgui.checkbox("3D body", state.show_body)
    if cb then state.show_body = vb end
    local cs, vs = imgui.checkbox("Debug skeleton (lines)", state.show_skeleton)
    if cs then state.show_skeleton = vs end
    local ch, vh = imgui.checkbox("Hide them for a while after a new game (cutscenes)", state.auto_hide)
    if ch then state.auto_hide = vh end
    local okh, chd, vhd = pcall(imgui.slider_float, "Hide them when closer than (m)", CFG.HIDE_NEAR_DISTANCE, 0.1, 1.5)
    if okh and chd and type(vhd) == "number" then CFG.HIDE_NEAR_DISTANCE = math.max(0.05, math.min(3.0, vhd)) end
    do
        local cw, vw = imgui.checkbox("Hide them behind walls and doors", state.occlude)
        if cw then state.occlude = vw end
        local cm, vm = imgui.checkbox("Hide them while a game menu is open (EXPERIMENTAL)", state.menu_hide)
        if cm then state.menu_hide = vm end
        imgui.text("    walls: " .. tostring(state.occ.status))
    end
    local why = state.overlay_hidden(os.clock())
    if why then
        imgui.text("Other player not drawn: " .. why)
        if os.clock() < state.hidden_until and imgui.button("Show them now") then state.hidden_until = 0 end
    elseif imgui.button("Hide them for 60 s") then
        hide_remote(60, "manual")
    end

    local okpv, cpv, vpv = pcall(imgui.combo, "Stand-in pose preview", state.pose_preview,
        { "Off (what the other player is doing)", "Block", "Heal", "Block, heal, crouch, stand (cycle)", "Crouch" })
    if okpv and cpv and type(vpv) == "number" then state.pose_preview = math.max(1, math.min(5, math.floor(vpv))) end
    if state.pose_preview ~= 1 then imgui.text("Preview is ON: the stand-in shows that pose whatever the other player does.") end
    do
        local lpz, P = state.local_pose, state.pose
        local sending = (lpz.guard and "BLOCK " or "") .. (lpz.heal and "HEAL " or "") .. (lpz.crouch and "CROUCH " or "")
        imgui.text(string.format("Poses: you are sending %s  | their stand-in: block %d%%, heal %d%%, crouch %d%%",
            sending ~= "" and sending or "nothing", math.floor(P.guard * 100 + 0.5), math.floor(P.heal * 100 + 0.5),
            math.floor((P.crouch or 0) * 100 + 0.5)))
        local PO = pstat.pose or {}
        imgui.text(string.format("    hands action %s, gun action %s, block flag %s, eyes %s m above your feet (standing %s)",
            tostring(PO.hands_id), tostring(PO.gun_id), tostring(PO.cancel),
            PO.eye and string.format("%.2f", PO.eye) or "?", PO.stand_eye and string.format("%.2f", PO.stand_eye) or "?"))
    end

    local lp, r = state.local_pos, state.remote
    imgui.text(lp and string.format("You:    %.2f, %.2f, %.2f", lp.x, lp.y, lp.z) or "You:    (no camera yet)")
    if r then
        imgui.text(string.format("%s: %.2f, %.2f, %.2f   (%.1f m/s)",
            state.remote_name or CFG.DEFAULT_NAME, r.pos.x, r.pos.y, r.pos.z, state.speed))
    else
        imgui.text("Other player: (nothing received)")
    end
    imgui.text(string.format("Sent: %d   Received: %d   Connection: %s", state.seq, state.remote_count,
        state.transport == "tcp" and "TCP (reliable)" or "?"))
    if state.role == "host" then
        imgui.text("Enemies: your game runs them (you are the host) and tells the other player where they are.")
    elseif state.role == "join" then
        imgui.text("Enemies: the host's game runs them; you see them as red ghosts (see the Enemies section).")
    end
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
            if imgui.button("4. Watch for death (then let something kill you once)") then
                trace_type("app.GameManager", "", false)
            end
            if imgui.button("5. Enemy details (stand near Jack or any enemy)") then enemy_details() end
            if imgui.button("6. Enemy damage trace (press, then shoot an enemy once)") then trace_enemy_damage() end
            if imgui.button("7. Highlighted item details (open the inventory, point at an item)") then dump_focused_item() end
            if imgui.button("8. Player details and trace (press, then get hit, block, use a Herb)") then pstat.details() end
            if imgui.button("9. Cutscene / event trace (press, then trigger a cutscene, open a door)") then pstat.events_trace() end
            pstat.extras_panel()
            if imgui.button("10. Load screen scan (open the Load Game screen first, then press)") then CFG.lm.dump() end
            pstat.rec_panel()
            imgui.text(string.format("Debug log: %d lines", #dbg.lines))
            if imgui.button("Clear the debug log") then dbg.lines = {} dbg.dirty = true end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Death") then
        local ok, err = pcall(function()
            local c, idx = imgui.combo("When a player dies", death.mode, DEATH_MODES)
            if c then death.mode = idx end
            if death.mode == 3 then imgui.text("That option isn't built yet; it acts like Independent.") end
            if death.mode == 4 then
                imgui.text("EXPERIMENTAL. While the other player is connected, a hit that would kill you leaves you at 1 health,")
                imgui.text("down where you fell. They get you up with a Herb / Chem Fluid (or F8). Details: Health section.")
            end
            build_mode_map()
            imgui.text(RE7.death_value ~= nil
                and ("Your death is detected via GameMode." .. tostring(RE7.death_name))
                or "No game-over-like GameMode found, so deaths can't be detected yet (see the debug file).")
            imgui.text(death.last)
            imgui.text(string.format("Death messages: sent %d, received %d", death.sent, death.received))
            if imgui.button("Test: send a death message to the other player") then
                net_send(DEATH_MSG, "test")
                death.sent = death.sent + 1
            end
            if imgui.button("Test: act as if the other player died (can kill YOU)") then
                apply_remote_death(state.remote_name or CFG.DEFAULT_NAME)
            end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Health and downed (experimental)") then
        local ok, err = pcall(pstat.panel)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Co-op saves") then
        local ok, err = pcall(function()
            imgui.text(saves.enabled and "Save sharing: on (TCP)" or "Save sharing: off (tick 'Share saves' in re7mp.exe and use TCP)")
            imgui.text(saves.last ~= "" and saves.last or "Nothing shared yet.")
            imgui.text("Saves you make while connected are sent to the other player. A received save never replaces")
            imgui.text("one of your own: it goes into a free slot and is listed here as CO-OP. The saves you made and")
            imgui.text("sent are listed too, with the name of the player they were last shared with.")
            if #saves.entries > 0 then imgui.text("Co-op saves on this PC:") end
            local now_s = os.clock()
            for _, e in ipairs(saves.entries) do
                if type(e) == "table" then
                    imgui.text(string.format("  slot %03d   %s   (%s)   %s", tonumber(e.slot) or 0,
                        tostring(e.tag or "[CO-OP]"), e.role == "sent" and "you saved it" or "received", tostring(e.label)))
                    -- (9.12) where a received save came from, why it is in this slot, and whether the game itself lists the slot
                    if e.role ~= "sent" then
                        if type(e.why) == "string" and e.why ~= "" then
                            imgui.text(string.format("        %s's slot %s -> your slot %d: %s", tostring(e.from or "?"),
                                (tonumber(e.from_slot) or 0) > 0 and tostring(math.floor(e.from_slot)) or "?", tonumber(e.slot) or 0, e.why))
                        end
                        local sees = saves.game_sees(tonumber(e.slot) or -1, now_s)
                        if sees == false then
                            imgui.text("        THE GAME DOES NOT LIST THIS SLOT: the file is there but the game says no save exists in it. Open and close the Load screen, or restart the game; if it is still missing, send me the debug file (button 8).")
                        elseif sees == true then
                            imgui.text("        the game lists this slot: Load Game shows it as slot " .. tostring(math.floor(tonumber(e.slot) or 0)))
                        end
                    end
                end
            end
            imgui.text("")
            pcall(CFG.lm.panel)
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Item sync") then
        local ok, err = pcall(function()
            local c1, v1 = imgui.checkbox("Sync item pickups", items.enabled)
            if c1 then items.enabled = v1 end
            imgui.text("An item you pick up from the world disappears for the other player.")
            imgui.text(items.hooked and "Hook: on (app.Inventory.addItem)" or "Hook: off (see console)")
            imgui.text(string.format("Sent %d   received %d   removed here %d   not found %d",
                items.sent, items.received, items.removed, items.missed))
            imgui.text(items.last)
            imgui.text("Not synced yet: drawer/container items, crafting, ammo use, both-get-it.")
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Items: give and drop") then
        local ok, err = pcall(function()
            local who = state.remote_name or CFG.DEFAULT_NAME
            local now = os.clock()
            imgui.text("Give: pick an item from your inventory list below (works with the game paused or not).")
            imgui.text("Or open the game's inventory, point at an item and press F7 (gives 1).")
            if now - give.inv_at > 1.0 or give.inv_dirty then
                give.inv_at, give.inv_dirty = now, false
                give.inv_list, give.inv_note = inventory_items()
            end
            if imgui.button("Refresh the list") then give.inv_dirty = true end
            if give.inv_list == nil then
                imgui.text("Your inventory: can't read it (" .. tostring(give.inv_note) .. ")")
            else
                imgui.text(string.format("Your inventory: %d items%s", #give.inv_list,
                    give.inv_note and ("   (" .. give.inv_note .. ")") or ""))
                for i, it in ipairs(give.inv_list) do
                    imgui.text(string.format("   %s x%d", it.id, it.count))
                    if pcall(imgui.same_line) and imgui.button("Give 1##g" .. i) then
                        give_item(it.id, 1)
                        give.inv_dirty = true
                    end
                    if it.count > 1 and pcall(imgui.same_line) and imgui.button("Give all##a" .. i) then
                        give_item(it.id, it.count)
                        give.inv_dirty = true
                    end
                end
            end
            local f = give.focus
            if f and f.id then
                imgui.text(string.format("Pointed at in the game's inventory: %s x%d  (%.0f s ago)", f.id, f.count, now - f.at))
            elseif f then
                imgui.text("Pointed at an item in the game's inventory, but I can't read its name:")
                imgui.text("   " .. tostring(f.why or "?"))
            else
                imgui.text(string.format("Pointing at items in the game's inventory: not seen yet (hook fired %d times)", give.hover_seen or 0))
            end
            local c1, v1 = imgui.checkbox("Discard drops the item on the ground (the other player sees it too)", give.drop_on_discard)
            if c1 then give.drop_on_discard = v1 end
            local c2, v2 = imgui.checkbox("Show the [F7] give hint while the inventory is open", give.hint)
            if c2 then give.hint = v2 end
            imgui.text(give.hooked and "Hooks: on (Item.isCanDiscard, Item.reduceNum)" or "Hooks: not all installed (see the console)")
            imgui.text(string.format("Given %d   received %d   dropped %d   failed %d", give.sent, give.received, give.dropped, give.failed))
            imgui.text(give.last)
            imgui.text("A given item goes into their inventory; if that fails it lies at their feet instead. Don't give away")
            imgui.text("key items or your equipped weapon unless you mean to: this does not check.")
            if imgui.button("Write the item details to the debug file") then dump_focused_item() end
            imgui.text("Receiving can't be tried with the loopback bot, so these run the real receive code on yourself:")
            if imgui.button("Test: receive 1 Herb as if " .. who .. " gave it") then netmsg.handlers[GIVE_MSG]("Herb|1") end
            if imgui.button("Test: receive 5 HandgunBullet as if " .. who .. " gave them") then netmsg.handlers[GIVE_MSG]("HandgunBullet|5") end
            if imgui.button("Test: a Herb that " .. who .. " dropped appears at my feet") then
                local lp = state.local_pos or { x = 0, y = 0, z = 0 }
                netmsg.handlers[DROP_MSG](string.format("Herb|1|%.2f|%.2f|%.2f", lp.x, lp.y - CFG.EYE_HEIGHT, lp.z))
            end
        end)
        if not ok then imgui.text("UI error: " .. tostring(err)) end
        imgui.tree_pop()
    end

    if imgui.tree_node("Enemies (experimental)") then
        local ok, err = pcall(function()
            local c, idx = imgui.combo("Enemy sync", enemy.mode, ENEMY_MODES)
            if c then
                enemy.mode = idx
                if idx < 3 then enemy_release_all() end
            end
            if enemy.mode == 3 then
                imgui.text("EXPERIMENTAL: this moves your own enemies about. Use a throwaway save.")
                local c2, v2 = imgui.checkbox("Also switch off their AI (riskier; they stop fighting the host's positions)", enemy.drive_ai)
                if c2 then
                    enemy.drive_ai = v2
                    enemy_release_all()
                end
            end
            if state.transport ~= "tcp" then
                imgui.text("Enemy sync needs TCP. Choose TCP in re7mp.exe (one of you hosts, the other joins).")
            elseif state.role == "host" then
                imgui.text(string.format("You are the HOST: your game runs the enemies. Snapshots sent: %d", enemy.sent))
                local live = 0
                for _, r in ipairs(enemy.roots) do
                    if (r.last_flags or 1) < 2 then live = live + 1 end
                end
                imgui.text(string.format("Em#### objects in your scene: %d   (%d look like live enemies)", #enemy.roots, live))
                for i = 1, math.min(#enemy.roots, 10) do
                    local r = enemy.roots[i]
                    local why = r.last_flags and flags_reason(r.last_flags) or ""
                    imgui.text("   " .. r.name .. (why ~= "" and ("   not sent as live: " .. why) or ""))
                end
            else
                local driven = 0
                for _ in pairs(enemy.driven) do driven = driven + 1 end
                imgui.text(string.format("You JOIN: the host's game runs the enemies. Snapshots received: %d", enemy.received))
                imgui.text(string.format("Enemies from the host: %d   of mine being moved: %d", enemy.count or 0, driven))
            end
            local c3, v3 = imgui.checkbox("Draw received enemies even if I am the host (loopback test: the bot sends two)", enemy.test_ghosts)
            if c3 then enemy.test_ghosts = v3 end
            local c4, v4 = imgui.checkbox("Also draw parked / placeholder objects in grey (to see what a stray box was)", enemy.show_parked)
            if c4 then enemy.show_parked = v4 end
            imgui.text(enemy.last)
            do
                local H = enemy.hit
                imgui.text("Damage to the host's enemies (9.10):")
                local ch1, v1 = imgui.checkbox("JOINER: my shots hurt the host's enemies (a shot that points at a red box)", H.on)
                if ch1 then H.on = v1 end
                local ch2, v2 = imgui.checkbox("HOST: apply the other player's hits to my enemies", H.accept)
                if ch2 then H.accept = v2 end
                local okd, chd, vd = pcall(imgui.slider_float, "Damage per hit", H.damage, 1, 300)
                if okd and chd then H.damage = math.floor(vd + 0.5) end
                if imgui.button("Test: hit the red box I am aiming at") then H.fire(os.clock(), "test button") end
                if imgui.button(H.learn.on and "Learning the shot signal: fire three shots now ..." or "Learn the shot signal (then fire three shots)") then
                    if not H.learn.on then H.learn_start(os.clock()) end
                end
                local okh, chh, vh = pcall(imgui.checkbox, "JOINER: take my shots from the gun's own shoot call (hooks app.PlayerGun.shoot, once per shot)", H.hook.on)
                if okh and chh and type(vh) == "boolean" then H.hook.on = vh end
                imgui.text(string.format("Gun hook: %s   (shoot calls seen: %d, used as shots: %d)%s",
                    #H.hook.installed > 0 and table.concat(H.hook.installed, ", ") or (H.hook.tried and "not installed" or "installs when enemies arrive"),
                    (H.hook.counts.shoot or 0) + (H.hook.counts.shootStart or 0), H.hook.used, H.hook.error and (" " .. H.hook.error) or ""))
                imgui.text("Shot detection: " .. (H.signal and (H.signal.type .. "." .. H.signal.field) or "not learned yet") .. "   (" .. H.learn.status .. ")")
                imgui.text(string.format("Shots tested %d, no box in line %d, behind a wall %d, hits sent %d, host answered %d", H.shots, H.misses, H.walled, H.sent, H.acked))
                imgui.text(H.last)
                imgui.text(string.format("Host side: received %d, applied %d, refused %d, failed %d", H.received, H.applied, H.refused, H.failed))
                imgui.text(H.host_last)
            end
            imgui.text("Not built yet: enemy deaths shown on the joiner's own screen, spawning, animations.")
            if imgui.button("Write enemy details to the debug file") then enemy_details() end
            if imgui.button("Trace enemy damage (then shoot an enemy once)") then trace_enemy_damage() end
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

say("script v" .. CFG.BUILD .. " loaded")
