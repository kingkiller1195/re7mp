-- Checks of build 10.26 (release 0.11 unchanged) for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1026_file) with that file's helpers in one table.
--   RE7MP_ONLY_1026=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What the build changed in the SCRIPT (all of it AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   F. Ethan's friend follows you or stays put with ONE KEY, F5 (the follows / stays put / beside you radios are gone from re7mp.exe, and "beside you" is gone):
--      the script sends kind 11 "mode:follow" / "mode:stay" (at once when the key is pressed, again every 10 s), and a corner of the screen says which it is
--      and which key flips it. F7 stays the item "Give" key. Nothing happens for a real player.
--   V. the version: release 0.11 (unchanged), build 10.26

local H = ...
local check, new_environment, build_world, load_script, host_role_files = H.check, H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, log_has, bump_remote = H.run_frames, H.run_ui, H.ui_has, H.log_has, H.bump_remote
local texts_have, messages_of_kind = H.texts_have, H.messages_of_kind

local function live(env, secs)
    for _ = 1, math.floor(secs / 0.05 + 0.5) do
        run_frames(env, 0.05)
        bump_remote(env)
    end
end

local function world(name)
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    if name then env.files["re7mp_in.json"].name = name end
    live(env, 1.5)
    return env
end

-- the "mode:" messages sent so far, oldest first (the ring holds 32 messages: these tests send a few)
local function modes_sent(env)
    local out = {}
    for _, p in ipairs(messages_of_kind(env, 11)) do
        if p:find("^mode:") then out[#out + 1] = p end
    end
    return out
end

-- press and release a key (frames in between, so the edge is seen)
local function tap(env, key, hold_secs)
    env.keys[key] = true
    live(env, hold_secs or 0.15)
    env.keys[key] = false
    live(env, 0.15)
end

local F5, F7 = 0x74, 0x76

-- =============================================================================================
-- F. F5: follow / stay
-- =============================================================================================
do
    local env = world("Ethan's friend")
    env.texts = {}
    live(env, 0.5)
    check(texts_have(env, "Ethan's friend follows you  (F5 = stay put)"), "(10.26) the corner says the friend follows you and that F5 makes it stay put")
    check(not texts_have(env, "stays put"), "(10.26) ...and not both")
    local m = modes_sent(env)
    check(#m >= 1 and m[#m] == "mode:follow", "(10.26) the exe is told 'mode:follow' at the start (it starts out following anyway): " .. table.concat(m, ","))

    tap(env, F5)
    env.texts = {}
    live(env, 0.5)
    check(texts_have(env, "Ethan's friend stays put  (F5 = follow you)"), "(10.26) F5: the corner now says it stays put and that F5 makes it follow you")
    m = modes_sent(env)
    check(m[#m] == "mode:stay", "(10.26) ...and the exe is told 'mode:stay' at once: " .. tostring(m[#m]))
    check(log_has(env, "Ethan's friend: now stays put"), "(10.26) ...and the log says so")

    -- one press is one change, however long the key is held
    local before = #modes_sent(env)
    tap(env, F5, 1.0)
    env.texts = {}
    live(env, 0.3)
    check(texts_have(env, "follows you  (F5 = stay put)") and not texts_have(env, "stays put  (F5"), "(10.26) a key held for 1 s is ONE press: back to following")
    m = modes_sent(env)
    check(m[#m] == "mode:follow" and #m - before <= 2, "(10.26) ...'mode:follow' is sent (once, not every frame): " .. (#m - before) .. " more messages")

    -- repeated every 10 s (an exe that was started later, or missed one, gets the current choice); not every frame
    tap(env, F5)
    local n0 = #modes_sent(env)
    live(env, 4.0)
    check(#modes_sent(env) == n0, "(10.26) the choice is not sent again within 4 s")
    live(env, 8.0)
    m = modes_sent(env)
    check(#m > n0 and m[#m] == "mode:stay", "(10.26) ...but is repeated after 10 s ('mode:stay'): " .. (#m - n0) .. " more")

    -- F7 is still the item "Give" key: it does not touch the friend
    tap(env, F7)
    env.texts = {}
    live(env, 0.3)
    check(texts_have(env, "stays put  (F5 = follow you)"), "(10.26) F7 (the Give key) does not change what the friend does")
end

-- a real player: no friend, so no corner text, no message, and the key does nothing
do
    local env = world("Bob")
    env.texts = {}
    tap(env, F5)
    live(env, 0.5)
    check(not texts_have(env, "F5 ="), "(10.26) with a real player there is no friend text in the corner")
    check(#modes_sent(env) == 0 and #messages_of_kind(env, 11) == 0, "(10.26) ...and nothing is sent to a real player")
end

-- =============================================================================================
-- V. the version
-- =============================================================================================
do
    local env = world("Ethan's friend")
    env.ui_press["Clear the debug log"] = true
    run_ui(env)
    live(env, 0.6)
    local d = env.files["re7mp/debug.json"]
    check(d and d.release == "0.11" and d.build == "10.27" and d.script == "re7mp v10.27", "(10.26) the debug file says release 0.11 (unchanged), build 10.27: " .. tostring(d and d.build))
    -- the alpha number: a normal release says 0 (ALPHA = "0"); an alpha release says its number, and the debug file of a tester says so
    check(d and d.alpha == 0, "(10.26) a normal release: the debug file says alpha 0: " .. tostring(d and d.alpha))
end

-- the script's own labels, as re7mp.exe reads them (updater.cpp: script_release / script_build / script_alpha read the first 16 KB of the file)
do
    local f = io.open((arg and arg[0] or ""):match("^(.*)/[^/]*$") .. "/../lua/re7mp.lua", "rb")
    local head = f and f:read(16384) or ""
    if f then f:close() end
    check(head:find('RELEASE = "0.11"', 1, true) and head:find('BUILD = "10.27"', 1, true) and head:find('\n    ALPHA = "0",', 1, true),
        "(10.26) the labels re7mp.exe reads are in the first 16 KB of the script: RELEASE 0.11, BUILD 10.27, ALPHA 0 (a normal release)")
end
